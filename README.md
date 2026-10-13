<p align="center">
  <img src="docs/icon.png" width="112" alt="House Control icon">
</p>

<h1 align="center">House Control</h1>

<p align="center">
  A macOS menu bar app that shows your home as a live 3D model<br>
  and controls its lights and air conditioners — Smart Life / Tuya devices included.
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
- **Works without any hardware.** Until you sign in, every device is simulated, so you can try everything first.

The app is a small native Swift shell (menu bar item, panel, editor window, device clients) around a
[Three.js](https://threejs.org) web UI. No frameworks, no Electron, no server, no account of its own.

## Requirements

| | |
| --- | --- |
| macOS | 13 Ventura or newer |
| Xcode Command Line Tools | Swift 5.9 or newer — `xcode-select --install` |
| Node.js | 20.19+ or 22.12+ |

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
| Right-click the menu bar icon | Edit Home, Load Floor Plan, Reveal Plan File, Reveal Device Log, Reload, Quit |
| Click a lamp in the 3D view, or its tile | Toggle it |
| Drag sideways across a light tile | Dim it |
| Click the sliders icon on a light tile | Brightness, white temperature, colour |
| Click an AC, or its tile | Open its sheet: temperature, mode, fan speed |
| Click a room | Zoom in on it and list only its devices |
| Drag the 3D view / scroll over it | Rotate / zoom |
| `Esc` | Back, then close |

The menu bar icon shows how many lights are on and the target of the running AC, for example `6 · 23°`.

The gear button in the panel switches between your home and the two bundled demo plans, **Apartment** and **Studio**.

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

None of these are part of this repository, and the build does not embed them in the app.
**Sign out** in the editor deletes `smartlife.json`. Deleting the folder resets the app to the demo plan.

## Development

```
web/      the UI: Three.js scene, panel, editor (Vite, plain ES modules)
macos/    the native shell: menu bar item, panel, editor window, Smart Life and Tuya clients (SwiftPM)
scripts/  build-app.sh assembles the .app, make-icon.swift draws the icon
docs/     floor plan reference, Smart Life guide, screenshots
```

Work on the UI in a browser with hot reload — the native bridge is a no-op there and all devices are simulated:

```bash
cd web
npm install
npm run dev
```

Then open `http://localhost:5199/`. Add `?plan=studio` for the second demo plan, `?mode=editor` for the editor,
or `?device=living.ac` to start on a device's sheet. Set `PORT` to use another port.

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

- macOS only, and built from source: there is no signed, notarized download.
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
