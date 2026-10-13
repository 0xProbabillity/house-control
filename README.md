<p align="center">
  <img src="docs/icon.png" width="112" alt="House Control icon">
</p>

<h1 align="center">House Control</h1>

<p align="center">
  Your home as a live 3D model — in the Mac's menu bar, around its notch and on your iPhone —<br>
  controlling its lights and air conditioners, Smart Life / Tuya devices included.
</p>

<p align="center">
  <img src="docs/hero.png" alt="The panel, an air conditioner sheet and a colour light sheet">
</p>

## What it does

- **Lives in the menu bar.** Click the house icon and a panel drops down; click anywhere else and it is gone.
- **Your floor plan in 3D.** Rooms, walls, doors, windows and furniture are built from one JSON file.
  Lamps light the scene the way they light the room; an AC that is running blows visible air.
- **Lights.** Tap to toggle, drag across a tile to dim, open a light for brightness, white temperature and colour.
- **Air conditioners.** Power, target temperature, mode and fan speed, with the room temperature from a real sensor if you have one.
- **Scenes.** One tap sets every light and AC — "Cozy", "Movie", "Night", or your own.
- **A visual editor.** Draw the rooms, drop in furniture, place lamps and ACs, and link each one to a real device.
- **An island around the notch.** Rest the pointer on the MacBook's notch and a small live model of the home drops
  out of it, with scenes and every device one click away. See [The island](#the-island).
- **An iPhone app.** The same home in your pocket, kept in sync with the Mac over your own Wi-Fi.
  See [iPhone app](#iphone-app).
- **Works without any hardware.** Until you sign in, every device is simulated, so you can try everything first.

Both apps are a small native Swift shell (AppKit on the Mac, SwiftUI on the iPhone) around one
[Three.js](https://threejs.org) web UI, and share their device clients and sync as a Swift package.
No frameworks, no Electron, no server, no account of its own.

## Requirements

| | |
| --- | --- |
| macOS | 13 Ventura or newer |
| Xcode Command Line Tools | Swift 5.9 or newer — `xcode-select --install` |
| Node.js | 20.19+ or 22.12+ |
| For the iPhone app | Xcode 16 or newer, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), iOS 17+ |

## Build and run

```bash
git clone https://github.com/0xProbabillity/house-control.git
cd house-control
./scripts/build-app.sh
open build/HouseControl.app
```

The script builds the web UI with Vite, the native shell with SwiftPM, and assembles an ad-hoc signed
`build/HouseControl.app`. The first build downloads the npm packages; later builds take a few seconds.

To keep it, drag `build/HouseControl.app` into `/Applications`. To start it with your Mac, add it under
**System Settings → General → Login Items**.

There is no Dock icon and no main window: look for the house in the menu bar.

## Using it

| Do this | To get this |
| --- | --- |
| Click the menu bar icon | Open or close the panel |
| Right-click the menu bar icon | Edit Home, Load Floor Plan, Reveal Plan File, Reveal Device Log, Show Island, Pair iPhone, Reload, Quit |
| Click a lamp in the 3D view, or its tile | Toggle it |
| Drag sideways across a light tile | Dim it |
| Click the sliders icon on a light tile | Brightness, white temperature, colour |
| Click an AC, or its tile | Open its sheet: temperature, mode, fan speed |
| Click a room | Zoom in on it and list only its devices |
| Drag the 3D view / scroll over it | Rotate / zoom |
| `Esc` | Back, then close |

The menu bar icon shows how many lights are on and the target of the running AC, for example `6 · 23°`.

The gear button in the panel switches between your home and the two bundled demo plans, **Apartment** and **Studio**.

## The island

<p align="center">
  <img src="docs/island.png" width="820" alt="The island, open: a 3D model of the home, scenes and devices">
</p>

A black tab grows out of the MacBook's notch. On a display without a notch it is drawn in the middle of the menu bar.

| Do this | To get this |
| --- | --- |
| Look at it | How many lights are on, and the target of a running AC |
| Rest the pointer on it | It springs open: the 3D model, scenes, air conditioners and lights |
| Click a lamp in the model, or its chip | Toggle it; drag across a chip to dim |
| Click a room in the model | Zoom in on it |
| Move the pointer away | It closes |

When something changes elsewhere — a scene picked in the panel, a lamp switched from the phone — the island
peeks out for a moment to say what happened. It never takes the keyboard from the app you are working in.
**Show Island** in the menu bar icon's right-click menu turns it off.

## iPhone app

<p align="center">
  <img src="docs/iphone.png" width="820" alt="The iPhone app: home, an air conditioner, a colour light and settings">
</p>

The iPhone app is the panel made for a thumb: tap a lamp in the 3D view or its tile, drag across a tile to dim,
touch and hold a light for brightness and colour, pinch the model to zoom, swipe in from the left edge to go back.

Try it in the simulator:

```bash
./scripts/ios-sim.sh
```

To put it on a phone, write your Apple developer team into `ios/Config/Local.xcconfig`
(`DEVELOPMENT_TEAM = ABCDE12345`), run `cd ios && xcodegen generate`, open `ios/HouseControl.xcodeproj` and run it
on your device. `./scripts/build-ios.sh --upload` archives it and sends it to TestFlight; the script lists what it needs.

### Sync with the Mac

Your floor plan — rooms, furniture, lamps, scenes and the links to real devices — is drawn on the Mac and travels
to the phone by itself.

1. On the Mac: right-click the menu bar icon → **Pair iPhone…**. A QR code appears.
   macOS asks once whether House Control may find devices on your local network: allow it.
2. On the iPhone: **Settings** (the sliders button) → **Pair with Mac**, and point the camera at the code.
   Or press **Copy Pairing Link** on the Mac and paste it on the phone.

From then on, whenever both are on the same Wi-Fi and the app is open, the phone has what the Mac has:
**Save & apply** in the editor updates the phone a moment later.

Nothing goes through a server. The Mac advertises itself with Bonjour and the two talk over TLS with a
pre-shared key that only the QR code carries, so a device that never saw the code cannot connect.
**Reset Pairing…** in the pairing window issues a new key.

### Real devices on the iPhone

The phone signs in to Smart Life on its own: **Settings → Connect Smart Life**. The User Code is filled in from the
Mac if you are signed in there. The sign-in code has to be scanned by the Smart Life app, which is on the very phone
you are holding — so the paired Mac puts the code on its screen for you. Without a Mac, share the code to any other screen.

The session is kept in the iPhone's Keychain and never leaves the device.

## Make it your home

Right-click the icon and choose **Edit Home…**

<p align="center">
  <img src="docs/editor.png" width="820" alt="The floor plan editor">
</p>

- Drag rooms to move them and drag a corner to resize; everything snaps to 5 cm.
- Where two rooms touch, the wall between them appears by itself. Walls facing the camera are cut away.
- Add doors, windows, furniture, lamps and air conditioners from the list on the left.
- **Save & apply** writes the plan and reloads the panel.

The plan is a single JSON file, `~/Library/Application Support/HouseControl/plan.json`. You can write it by hand,
export it, or import someone else's: see [docs/floor-plan.md](docs/floor-plan.md) for every field.
The demo plans in [`web/public/plans`](web/public/plans) are good starting points.

## Connect real devices (Smart Life / Tuya)

You need the **Smart Life** (or **Tuya Smart**) phone app with your devices already added to it.
No Tuya developer account is required.

1. In the phone app open **Me → ⚙ Settings → Account and Security** and copy the **User Code** at the bottom.
2. In House Control: right-click the icon → **Edit Home… → Smart Life**. Enter the User Code and press **Show QR code**.
3. Scan the code with the phone app (the scanner on its Home tab) and confirm the login.
4. Your devices appear in the editor. Select a lamp or an AC on the plan, pick its device under
   **Smart Life device**, and press **Save & apply**.

From then on the panel controls the real device, and re-reads the state of your devices every 12 seconds while it is open.

More detail — what works with which device, infrared air conditioners, temperature sensors, the Tuya Cloud
alternative, and how to diagnose a device that does not react — is in [docs/smart-life.md](docs/smart-life.md).

## Privacy

House Control talks to Tuya's servers and to nothing else. There is no telemetry and no backend of its own.

Everything personal stays in `~/Library/Application Support/HouseControl/` on your Mac:

| File | Contents |
| --- | --- |
| `plan.json` | Your floor plan, including the IDs of the devices you linked |
| `settings.json` | Which plan is active |
| `smartlife.json` | The Smart Life session tokens. Readable only by you (mode `600`) |
| `tuya.json` | Tuya Cloud project credentials, only if you use that option. Mode `600` |
| `events.log` | Commands sent to real devices and the cloud's answers. No tokens |
| `sync.json` | The key your paired iPhones use. Only there once you paired one. Mode `600` |

None of these are part of this repository, and the build does not embed them in the app.
**Sign out** in the editor deletes `smartlife.json`. Deleting the folder resets the app to the demo plan.

On the iPhone the floor plan lives in the app's own folder, and the Smart Life session and the pairing key in the Keychain.

## Development

```
web/      the UI: Three.js scene, panel, island, editor (Vite, plain ES modules)
core/     what both apps share: Smart Life and Tuya clients, plan store, Mac ⇄ iPhone sync (SwiftPM, with tests)
macos/    the Mac shell: menu bar item, panel, island and editor windows (SwiftPM)
ios/      the iPhone shell: SwiftUI, generated into an Xcode project by XcodeGen
scripts/  build-app.sh, build-ios.sh and ios-sim.sh build the apps, make-icon.swift draws the icon
docs/     floor plan reference, Smart Life guide, screenshots
```

The shared package has unit tests, including the sync over a real TLS connection:

```bash
cd core && swift test
```

Work on the UI in a browser with hot reload — the native bridge is a no-op there and all devices are simulated:

```bash
cd web
npm install
npm run dev
```

Then open `http://localhost:5199/`. Add `?plan=studio` for the second demo plan, `?mode=editor` for the editor,
`?mode=island` for the island, `?platform=ios` for the iPhone layout, or `?device=living.ac` to start on a
device's sheet. Set `PORT` to use another port.

Environment variables understood by the app:

| Variable | Effect |
| --- | --- |
| `HOUSE_DEV_URL=http://localhost:5199/` | Load the UI from the dev server instead of the bundle |
| `HOUSE_WEB_DIR=/path/to/dist` | Load the UI from another folder |
| `HOUSE_DATA_DIR=/some/folder` | Keep plan, session and log there instead of Application Support, and do not persist panel state. Handy for a clean test run |
| `HOUSE_OPEN_ON_LAUNCH=1` | Open the panel at launch |
| `HOUSE_OPEN_EDITOR=1` | Open the editor at launch (`smartlife` opens it on the Smart Life section) |
| `HOUSE_OPEN_DEVICE=<id>` | Start the panel on that light's or AC's sheet |
| `HOUSE_PIN=1` | Keep the panel open when it loses focus |
| `HOUSE_DOCK=1` | Show a Dock icon, so UI automation tools can see the app |
| `HOUSE_ISLAND=0` | Run without the island (`1` forces it on) |
| `HOUSE_ISLAND_EXPANDED=1` | Keep the island open |
| `HOUSE_OPEN_PAIRING=1` | Open the Pair iPhone window at launch |
| `HOUSE_SNAPSHOT_DIR=/some/folder` | Write `panel.png` and `island.png` there a few seconds after launch |
| `HOUSE_RENDER_HIDDEN=1` | Keep drawing while the screen is locked, for unattended captures |

The iPhone app understands `HOUSE_DATA_DIR`, `HOUSE_OPEN_DEVICE` and `HOUSE_SCREEN=home|settings|pairing|smartlife|welcome`;
`scripts/ios-sim.sh` passes any `HOUSE_*` variable on to the simulator.

For example, a throw-away instance on the demo plan, pinned open:

```bash
HOUSE_DATA_DIR=/tmp/house-demo HOUSE_PIN=1 HOUSE_OPEN_ON_LAUNCH=1 build/HouseControl.app/Contents/MacOS/HouseControl
```

The binary has a few offline self-checks and one read-only diagnostic:

| Command | Prints |
| --- | --- |
| `HouseControl --selftest-mapper` | The Tuya commands built for typical light and AC actions |
| `HouseControl --selftest-infrared` | The key presses sent to an infrared AC, against a simulated cloud remote |
| `HouseControl --selftest-transport` | The Smart Life request envelope for fixed inputs, to compare with the reference SDK |
| `HouseControl --diagnose <device id>…` | What Smart Life reports for those devices. Reads only; sends nothing |

## Limitations

- Built from source: there is no signed, notarized Mac download, and the iPhone app is not on the App Store.
- The floor plan is edited on the Mac only. The iPhone receives it, and only while both are on the same network.
- Rooms are axis-aligned rectangles. An L-shaped room is two rooms.
- Smart Life is the only device backend. Devices are reached through Tuya's cloud, not over the local network,
  so they need an internet connection.
- Infrared air conditioners are one-way: the app shows what was last sent, not what the unit is doing.

## Acknowledgements and disclaimer

The Smart Life sign-in is a Swift port of Tuya's open-source
[`tuya-device-sharing-sdk`](https://github.com/tuya/tuya-device-sharing-sdk), the library behind the Tuya
integration in Home Assistant, and identifies itself to Tuya the same way. The 3D view is built with
[Three.js](https://threejs.org); the icons are from [Lucide](https://lucide.dev).

This project is not affiliated with or endorsed by Tuya, Smart Life or Home Assistant. It relies on an
interface Tuya can change at any time. Use it at your own risk.

## License

[MIT](LICENSE)
