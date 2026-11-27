# Connecting real devices

House Control links the lamps, plugs and air conditioners of your floor plan to real devices on five platforms.
One home can mix them: Hue lamps, a Home Assistant air conditioner, a Smart Life plug and a Homebridge accessory side
by side.
Everything you do not link stays simulated.

| Platform | Mac | iPhone | How it connects | What you need |
| --- | --- | --- | --- | --- |
| **Smart Life / Tuya** | ✓ | ✓ | Tuya's cloud, signed in with a QR code | The Smart Life or Tuya Smart app — see [smart-life.md](smart-life.md) |
| **Home Assistant** | ✓ | ✓ (from the Mac) | Your server's API, on your network | A long-lived access token |
| **Philips Hue** | ✓ | ✓ (from the Mac) | The Hue Bridge's own API, on your network | Press the bridge's button once |
| **Homebridge** | ✓ | ✓ (from the Mac) | The Homebridge UI's API, on your network | The user name and password of its web page |
| **Apple Home** | Linking only | ✓ | HomeKit, on the iPhone | Allow access to your Home data |

On the Mac all five are set up in the editor: right-click the menu bar icon → **Edit Home… → Connections**. Then
select a lamp or an AC on the plan, choose its device under **Real device**, and press **Save & apply**. Picking a
lamp fills in what it can do (dimming, white temperature, colour); picking an AC takes over its temperature range.

On the iPhone they are in **Settings**: Smart Life, Home Assistant, Philips Hue and Homebridge each have their own screen, and
**Settings → Devices** links the plan's lamps and ACs (or adds your devices to a room, already linked). No Mac is
needed. When a Mac is paired, the Home Assistant, Hue and Homebridge connections travel between the two over their encrypted
link, in whichever direction they were set up, so there is nothing to set up twice. Smart Life signs in on each
device separately: its session cannot be shared; Tuya renews it as it is used.

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

## Homebridge

[Homebridge](https://homebridge.io) brings devices that have no HomeKit support of their own into HomeKit, through
hundreds of plugins — Govee, Xiaomi, Nest, Sonoff, TP-Link, Tuya, Ring, Broadlink and many more. House Control
talks to the **Homebridge UI** (the web page you manage Homebridge with), so every accessory your plugins bring
can be linked, without adding it to Apple Home first, and the Mac switches them too.

1. In House Control: **Connections → Homebridge**. Homebridge servers on your network are found by themselves
   (their HomeKit bridge announces them) — press **Use**, or type the address of its web page
   (`homebridge.local:8581`; the port is 8581 unless you changed it).
2. Enter the user name and password you sign in to that web page with and press **Connect**. If the account has
   two-factor sign-in, House Control asks for the code.

Homebridge has to allow controlling accessories from its UI. Installs made with `hb-service` (the Raspberry Pi
image, the macOS and Linux installers, Docker) do by default; if it was switched off, House Control says so: in the
Homebridge UI open **Settings → Startup & Environment**, turn on **Enable UI Accessory Control (-I)** and restart
Homebridge.

| HomeKit service in Homebridge | In House Control |
| --- | --- |
| Lightbulb | A lamp: on/off, brightness, colour temperature, hue and saturation |
| Outlet, Switch | A lamp on a plug (show it as an outlet if you like, see below) |
| Heater Cooler | An AC: active, cool / heat / auto, the matching threshold, rotation speed as low / medium / high, swing |
| Thermostat | An AC: off / heat / cool / auto, target temperature |
| Temperature Sensor | A thermometer for an AC's room |

Homebridge's sessions last eight hours by default, so House Control keeps the user name and password and signs in
again when one runs out. An account with two-factor sign-in cannot be renewed without you: Settings and the editor
then say **Sign in again**. A separate Homebridge user without two-factor sign-in for House Control avoids that.
Changes made in the Homebridge UI, in Apple Home or by an automation arrive at once over the UI's live channel.

## Lamps and outlets

Most smart plugs power a lamp, so a plug is linked as a lamp that switches on and off, and looks like one. When it
powers something else — a kettle, a fan, a heater — select it in the editor and set **Shown as** to **Outlet**: it
then shows a socket in the panel, the widgets and the island, and sits on the nearest wall of its room in the 3D
model, with a ring that glows while it is on. **+ Outlet** in the editor's toolbar adds one directly. Devices whose
name says they are a socket ("Kettle plug", "Розетка") are added to a room as outlets by themselves.

## Apple Home

Apple offers HomeKit to iPhone and iPad apps, and to Mac apps only through the Mac App Store. House Control is a
download, so on the Mac it can list Apple Home devices but not switch them:

1. Pair your iPhone with the Mac (right-click the menu bar icon → **Pair Phone…**).
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
- **Homebridge** with a Tuya plugin, if you already run Homebridge (House Control can also link those devices
  straight from Homebridge, see above).
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

`tools/lab` has pretend versions of the platforms — a Home Assistant full of demo devices, a Hue Bridge emulator,
a real Homebridge with pretend lamps, plugs and ACs, and a HomeKit bridge you can add to the Home app.
See [tools/lab/README.md](../tools/lab/README.md).

## Privacy

Credentials stay on your devices. On the Mac they are in `~/Library/Application Support/HouseControl/` (readable only by you):
`homeassistant.json` (address and token), `hue.json` (bridge address, key and certificate fingerprint), `homebridge.json` (the Homebridge UI's address, user
name, password and session token) and
`homekit-devices.json` (the device list your iPhone sent: names and HomeKit ids, no credentials).
On the iPhone they are in the Keychain. **Disconnect** deletes them, on both when they are paired. A Mac and its
paired iPhones exchange the Home Assistant, Hue and Homebridge connections over their encrypted link. Nothing goes through a server of ours — there is none.

When something does not react, **Reveal Device Log** in the menu bar icon's menu shows each command and the answer.
