# Smart Life / Tuya devices

House Control controls the devices of a **Smart Life** or **Tuya Smart** account. Until you connect one,
every device in the plan is simulated.

## Signing in

You need the phone app with your devices already added to it. No Tuya developer account is required.

1. In the phone app: **Me → ⚙ Settings → Account and Security**. Copy the **User Code** at the bottom of the screen.
2. In House Control: right-click the menu bar icon → **Edit Home… → Connections → Smart Life**. Enter the User Code and press **Show QR code**.
3. Scan the code with the phone app (the scanner icon on its Home tab) and confirm.
4. The editor lists the devices of the account.

This is the sign-in the Tuya integration of Home Assistant uses. `SmartLifeService.swift` is a Swift port of
Tuya's open-source [`tuya-device-sharing-sdk`](https://github.com/tuya/tuya-device-sharing-sdk) and presents
the same client identifier to Tuya. Requests are AES-GCM encrypted and HMAC-SHA256 signed.

The session is stored in `~/Library/Application Support/HouseControl/smartlife.json`, readable only by your
user, and is refreshed automatically. **Sign out** in the editor deletes it.

## Linking devices to the plan

Select a lamp or an AC in the editor, choose its device under **Real device**, and press **Save & apply**.

- A lamp's sliders follow the plan: picking a device sets the capabilities it reports (`brightness`, `temp`,
  `color`); adjust them under **What it can do** if the device reports less than it can do. A smart plug has
  none and only switches.
- For an AC you can also pick a **thermometer** in the same room. The sheet then shows the measured room
  temperature instead of an estimate.

While the panel is open, the app reads the state of all linked devices every 12 seconds, so changes made in
the phone app or on a wall switch show up.

## What is supported

| Device | Works | How |
| --- | --- | --- |
| Smart plugs, switches | On / off | `switch_1`, `switch`, or the code named in `codes.switch` |
| Bulbs, LED strips | On / off, brightness, white temperature, colour | `switch_led`, `bright_value(_v2)`, `temp_value(_v2)`, `colour_data(_v2)` |
| Wi-Fi air conditioners | Power, temperature, mode, fan speed, sleep, eco | `switch`, `temp_set`, `mode`, `fan_speed_enum` / `windspeed`, `sleep`, `eco` |
| Infrared air conditioners | Power, temperature, mode, fan speed | `PowerOn`, `PowerOff`, `T`, `M`, `F` — see below |
| Temperature sensors | Room temperature for an AC | `temp_current`, `va_temperature` |

Value ranges come from each device's own specification, so bulbs with a 0–255 scale and bulbs with a
10–1000 scale behave the same.

An AC only shows the controls its device has a function for. Airflow direction, Sleep and Eco are simulated
extras of the demo; on a real AC they appear only when the device offers them.

## Infrared air conditioners

An AC driven by an infrared blaster ("universal remote") is not a device with a state of its own. Tuya keeps
a *virtual remote* in the cloud; every change is a key press that the blaster transmits, and the cloud works
out the infrared code from the state it remembers for that remote. That shapes how the app behaves:

- **One key at a time.** A change of mode and temperature is two transmissions, a second apart. Expect one
  beep per key.
- **Nothing is sent while the AC is off.** Change the fan speed of an AC that is off and it is sent along
  when you switch it on.
- **The state is assumed.** Infrared is one-way. The panel shows what was last sent from this app; it does
  not notice the physical remote, and it does not see changes made in the phone app.
- **A refused key is replayed.** If the cloud answers `2008` ("command or value not support") the state it
  remembers usually differs from the app's — for example it is in Auto or Dry mode, where many units have a
  fixed temperature. The app then re-sends its whole state (power, mode, temperature, fan) and tries once
  more. If the key is refused again, that remote really has no infrared code for the setting; the panel
  says so and returns to the previous value.
- **The numbering is the common one:** modes `0` cool, `1` heat, `2` auto, `3` fan, `4` dry; fan speeds
  `0` auto, `1` low, `2` medium, `3` high. A unit that lacks one of them refuses it.
- **No airflow, sleep or eco.** Tuya's infrared key set has no such keys, so the sheet does not show them.

## When a device does not react

**Reveal Device Log** in the menu bar icon's right-click menu opens `events.log`: every command sent to a
real device and what the cloud answered. That is the first place to look.

```
2026-01-12T21:14:03+02:00 kitchen.ac T=25 → command or value not support (code 2008)
2026-01-12T21:14:03+02:00 kitchen.ac target refused (2008): replaying fan, mode, on
2026-01-12T21:14:04+02:00 kitchen.ac PowerOn=PowerOn → ok
2026-01-12T21:14:05+02:00 kitchen.ac M=0 → ok
2026-01-12T21:14:06+02:00 kitchen.ac F=0 → ok
2026-01-12T21:14:07+02:00 kitchen.ac T=25 → ok
```

| Code | Meaning | What to do |
| --- | --- | --- |
| `2001` | The device is offline | Check its power and Wi-Fi in the phone app. A device paired only over Bluetooth cannot be reached through the cloud |
| `2008` | The device does not accept that command or value | For a lamp: remove the capability it does not have. For an infrared AC: see above |
| `1109` | Invalid parameter | Usually several infrared keys in one request; should not happen with this app |

To see exactly what the cloud knows about a device — its category, its functions and their ranges, its
current status — run the read-only diagnostic with its device ID (shown in the editor):

```bash
build/HouseControl.app/Contents/MacOS/HouseControl --diagnose <device id>
```

It sends nothing to the device.

## Alternative: a Tuya Cloud project

If you have a cloud project on [platform.tuya.com](https://platform.tuya.com) with your app account linked
to it (**Devices → Link App Account**), you can use its credentials instead: **Edit Home… → Smart Life →
Advanced**. Enter the Access ID, the Access Secret and the data center of the project.

The QR sign-in takes precedence when both are set. The cloud-project client (`TuyaService.swift`) covers the
same devices but has seen far less real-world use than the QR route.

## How it is put together

| File | Role |
| --- | --- |
| `SmartLifeService.swift` | QR login, token refresh, the encrypted request envelope, device list / status / specification / commands |
| `TuyaService.swift` | The Tuya Cloud project client, and `TuyaMapper`, which translates between the app's state and Tuya data points |
| `InfraredRemote.swift` | Key sequencing for infrared ACs |
| `AppDelegate.swift` | Queues commands per device, polls state, reports results to the panel |
| `web/src/store.js` | Coalesces changes into few commands and rolls back the ones a device refuses |
