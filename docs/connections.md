# Connecting real devices

House Control links the lamps and air conditioners of your floor plan to real devices on four platforms.
One home can mix them: Hue lamps, a Home Assistant air conditioner and a Smart Life plug side by side.
Everything you do not link stays simulated.

| Platform | Mac | iPhone | How it connects | What you need |
| --- | --- | --- | --- | --- |
| **Smart Life / Tuya** | ✓ | ✓ | Tuya's cloud, signed in with a QR code | The Smart Life or Tuya Smart app — see [smart-life.md](smart-life.md) |
| **Home Assistant** | ✓ | ✓ (from the Mac) | Your server's API, on your network | A long-lived access token |
| **Philips Hue** | ✓ | ✓ (from the Mac) | The Hue Bridge's own API, on your network | Press the bridge's button once |
| **Apple Home** | Linking only | ✓ | HomeKit, on the iPhone | Allow access to your Home data |

On the Mac all four are set up in the editor: right-click the menu bar icon → **Edit Home… → Connections**. Then
select a lamp or an AC on the plan, choose its device under **Real device**, and press **Save & apply**. Picking a
lamp fills in what it can do (dimming, white temperature, colour); picking an AC takes over its temperature range.

On the iPhone they are in **Settings**: Smart Life, Home Assistant and Philips Hue each have their own screen, and
**Settings → Devices** links the plan's lamps and ACs (or adds your devices to a room, already linked). No Mac is
needed. When a Mac is paired, the Home Assistant and Hue connections travel between the two over their encrypted
link, in whichever direction they were set up, so there is nothing to set up twice. Smart Life signs in on each
device separately: its session cannot be shared, Tuya renews it as it is used.

## Home Assistant

[Home Assistant](https://www.home-assistant.io) runs your home locally and speaks to thousands of brands —
Zigbee and Z-Wave sticks, Matter, Google Nest, Xiaomi, Aqara, IKEA, Sonoff, SmartThings, Daikin, Mitsubishi,
Tuya — so connecting it brings all of them in at once.

1. In Home Assistant, open your profile (your name at the bottom left) → **Security** → **Long-lived access
   tokens** → **Create token**. Name it "House Control" and copy it.
2. In House Control: **Connections → Home Assistant**. Servers on your network are found by themselves — press
   **Use**, or type the address (`http://homeassistant.local:8123`). Paste the token and press **Connect**.

| Home Assistant | In House Control |
| --- | --- |
| `light.*` | A lamp: on/off, brightness, white temperature and colour as its colour modes allow |
| `switch.*` | A lamp on a plug: on/off |
| `climate.*` | An air conditioner: power, target, the modes it has (`cool`, `heat`, `dry`, `fan_only`, `auto`/`heat_cool`), its fan speeds, swing, `eco` and `sleep` presets |
| `sensor.*` with `device_class: temperature` | A thermometer for an AC's room |

Areas become the room shown next to each device. House Control subscribes to Home Assistant's events, so a
lamp switched from a wall switch or an automation shows up in the panel within a second.

**Bring your Tuya devices in without a developer account:** in Home Assistant, **Settings → Devices & services →
Add integration → Tuya**, and sign in with the User Code and QR code from the Smart Life app — the same sign-in
House Control uses.

## Philips Hue

1. In House Control: **Connections → Philips Hue**. Bridges on your network are found by themselves (or type the
   address shown in the Hue app under **Settings → My Hue system**).
2. Press **Pair**, then the round button on top of the bridge within a minute.

Lamps, Hue Play bars, light strips and smart plugs appear with what each can do; the thermometers inside Hue
motion sensors can serve as an AC's room temperature. The bridge's event stream makes changes from the Hue app
show up at once. No Hue account or internet connection is involved.

The bridge's certificate is self-signed. House Control trusts it the first time and remembers its fingerprint,
so a different device answering at that address later is refused.

## Apple Home

Apple offers HomeKit to iPhone and iPad apps, and to Mac apps only through the Mac App Store. House Control is a
download, so on the Mac it can list Apple Home devices but not switch them:

1. Pair your iPhone with the Mac (right-click the menu bar icon → **Pair iPhone…**).
2. On the iPhone: **Settings → More connections → Apple Home → Connect**, and allow access to your Home data.
3. The iPhone sends the list of your lamps, outlets, air conditioners (heater-coolers and thermostats) and
   thermometers to the Mac. Link them in the editor like any other device.

The iPhone app then switches them, including Matter accessories added to Apple Home. On the Mac they show what
you set but stay simulated.

| HomeKit service | In House Control |
| --- | --- |
| Lightbulb | A lamp: on/off, brightness, colour temperature, hue and saturation |
| Outlet, Switch | A lamp on a plug |
| Heater Cooler | An AC: active, cool / heat / auto, the matching threshold, rotation speed as low / medium / high, swing |
| Thermostat | An AC: off / heat / cool / auto, target temperature |
| Temperature Sensor | A thermometer for an AC's room |

### Your Tuya devices in Apple Home

Smart Life devices are not HomeKit accessories, but there are three free ways to put them there:

- **Home Assistant's HomeKit Bridge** (recommended): add the Tuya integration as above, then
  **Add integration → HomeKit Bridge**, choose the domains (lights, switches, climate) and scan the code it
  shows with the Home app. Every Tuya device appears in Apple Home — and in House Control's iPhone app.
- **Homebridge** with a Tuya plugin, if you already run Homebridge.
- **Matter**: newer Tuya devices and hubs that support Matter can be added to Apple Home directly
  (**+ → Add Accessory** and scan their Matter code), and shared with other apps at the same time.

## Why not Google Home, Amazon Alexa or SmartThings — yet

- **Amazon Alexa** has no interface that lets another app switch the devices in your Alexa account; it only goes
  the other way (devices exposed *to* Alexa).
- **Google Home** offers its Home APIs to iPhone and Android apps only, behind a Google Cloud project, a Google
  sign-in and App Attest (which cannot run in the iOS Simulator), and an SDK that is downloaded after signing in to
  Google's developer site. Its new Home MCP server needs Google Home Premium Advanced and is US-only for now.
- **Samsung SmartThings** needs an OAuth app registered with Samsung; its personal tokens expire after 24 hours.

Until then, the practical route for any of them is Home Assistant: it has integrations for SmartThings and Google
Nest, and Matter devices from a Google or Amazon ecosystem can be shared with Home Assistant or Apple Home
(Matter "multi-admin": in the Google Home or Alexa app, open the device → **Linked Matter apps & services**).

## Trying it without hardware

`tools/lab` has pretend versions of all three new platforms — a Home Assistant full of demo devices, a Hue Bridge
emulator and a HomeKit bridge you can add to the Home app. See [tools/lab/README.md](../tools/lab/README.md).

## Privacy

Credentials stay on your devices. On the Mac they are in `~/Library/Application Support/HouseControl/` (readable only by you):
`homeassistant.json` (address and token), `hue.json` (bridge address, key and certificate fingerprint) and
`homekit-devices.json` (the device list your iPhone sent: names and HomeKit ids, no credentials).
On the iPhone they are in the Keychain. **Disconnect** deletes them, on both when they are paired. A Mac and its
paired iPhones exchange the Home Assistant and Hue connections over their encrypted link. Nothing goes through a server of ours — there is none.

When something does not react, **Reveal Device Log** in the menu bar icon's menu shows each command and the answer.
