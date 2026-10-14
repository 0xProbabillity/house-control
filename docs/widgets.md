# Widgets, controls and quick actions

House Control puts the home on the iPhone's Home Screen, Lock Screen and Control Center, and on the Mac's
desktop and Control Center. Every widget is live: tap a lamp, a scene or an air conditioner and it switches
without opening the app.

## What there is

| Widget | Sizes | What it does |
| --- | --- | --- |
| **Home** | small, medium, large · extra large on the Mac | The home as a small 3D model, every lamp glowing on the floor of its room in its own colour, ACs blowing on their walls. Medium adds scenes and the power button; large adds the climate strip and makes each lamp in the model a button; the Mac's extra large adds rooms. |
| **Scenes** | small, medium | Four scenes as big buttons; the active one is lit. |
| **Light** | small · Lock Screen (circle) | One lamp you choose, in its colour and brightness. Tap to switch. |
| **Room** | medium, large | Every lamp of one room. Large shows the room on its own in 3D, its AC and **All on / All off**. |
| **Climate** | small, medium · Lock Screen (circle, rectangle) | An AC's set-point on a dial with the room's temperature on it, power and − / +. |
| **Home Status** | Lock Screen (circle, rectangle, inline) | Lamps on, the AC, the active scene. |

Controls (iOS 18 and macOS 26): **All Lights** (toggle), **Light** (toggle, pick the lamp), **Scene** (button, pick the
scene) and **Air Conditioner** (toggle, pick the AC). On the iPhone they go into Control Center, onto the Lock
Screen and onto the Action button; on the Mac into Control Center and the menu bar.

Quick actions (iPhone): press and hold the app icon for up to four of your scenes, lamps and ACs.
Pick them in **Settings → Quick Actions**: add with **+**, drag to reorder, swipe to remove. Each home has its own set;
until you choose, the icon offers three scenes and **All Lights Off**.

The widgets follow the system's looks: full colour, the tinted and clear Home Screen, StandBy and the Lock Screen
(the model turns into a line drawing with the lamps that are on accented).

## How it works

```
panel page (web/src/widgets.js) ──"widgets"──▶ app ──▶ App Group: Widgets/home.json ──▶ widgets redraw
                                                  ▲
widget tap ─▶ AppIntent ─▶ HomeSnapshot.apply ─▶ home.json (at once) + actions.json ──Darwin notification──┘
```

- The panel page posts a **snapshot** after every change: rooms, lamps, ACs, furniture footprints and scenes with
  their state (`HomeSnapshot` in `core/Sources/HouseCore/HomeSnapshot.swift`). The app stores it in the App Group
  container (`SharedHome.swift`) and reloads the widgets, at most a couple of times a second.
- A tap runs an App Intent in the widget extension (`widgets/Sources/Intents.swift`). It applies the change to the
  snapshot with the same rules as the panel's store (scenes, clamping, "a white temperature drops the colour") so the
  widget redraws with the result at once, and queues the action.
- **Mac:** the app runs in the menu bar, takes the queue within milliseconds (a Darwin notification wakes it) and runs
  each action through the panel — the same path as a click there, so it reaches Smart Life, Home Assistant, Hue and
  the island. The widget waits for that and redraws with the real outcome.
- **iPhone:** the app is usually not running. The extension sends the change itself to Home Assistant, Hue and
  Smart Life, with the connections the app keeps in the Keychain group it shares with its widgets (the Smart Life
  session is re-read when the other process refreshed it). Apple Home cannot be reached from a widget: those actions
  wait in the queue and the app carries them out when it opens. The app then shows what the widgets did.
- An action the app still has to carry out is dropped after ten minutes (nobody expects a lamp to switch an hour
  later), and an action is only ever run for the home it was made in.
- Files are read and written under one `flock`, so the app and a widget never see half of each other's work.

## Code

| Where | What |
| --- | --- |
| `core/Sources/HouseCore/HomeSnapshot.swift` | The snapshot, `HomeAction`, the scene and toggle rules (tested in `WidgetTests.swift`) |
| `core/Sources/HouseCore/SharedHome.swift` | App Group files, the action queue, the lock, Darwin notifications |
| `core/Sources/HouseCore/WidgetBridge.swift` | The app's side: stores snapshots, hands queued actions to the panel |
| `web/src/widgets.js` | Builds the snapshot in the panel page and runs queued actions (`house.widget`) |
| `widgets/Sources/` | Widgets, controls, intents and the isometric model (`HouseModel.swift`), shared by iPhone and Mac |
| `widgets/project.yml` | The Mac's widget extension (built and embedded by `scripts/build-app.sh`) |
| `ios/project.yml` | The iPhone's widget extension (target `HouseWidgets`) |
| `ios/Sources/QuickActions.swift` | The icon's quick actions and their editor |

## Build and try

- **iPhone simulator:** `./scripts/ios-sim.sh`, then long-press the Home Screen → **Edit** → **Add Widget** →
  House Control. The script signs the simulator build with your Apple Development certificate when there is one:
  the simulator offers lamps, rooms and ACs to pick only for an app signed with a team.
- **Mac:** `CODESIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh`, open the app, then right-click the
  desktop → **Edit Widgets…** → House Control. `SKIP_WIDGETS=1` builds the app without them.
- **Stills of every widget**, without WidgetKit: `cd widgets && swift run render-widgets` (writes PNGs from
  `Resources/sample-home.json`; pass a snapshot to draw another home, `--size mac` for the desktop sizes).
  `node widgets/make-sample.mjs` regenerates the sample from the demo apartment.

## Signing and the App Group

- iPhone: `group.io.github.0xprobabillity.HouseControl` plus the Keychain group
  `$(AppIdentifierPrefix)io.github.0xprobabillity.HouseControl`. Automatic signing registers both for your team.
- Mac: `<TEAM>.io.github.0xprobabillity.HouseControl`, prefixed with the signing team so it needs no provisioning
  profile; `build-app.sh` reads the team from the certificate. The widget extension is sandboxed (WidgetKit requires
  it), the app is not.
- An ad-hoc signed build (the release disk image) has no team: the group is then the bare
  `io.github.0xprobabillity.HouseControl`. The app can write it; whether macOS lets an ad-hoc, sandboxed widget
  extension read it has not been tried yet. If the widgets show the demo apartment there, build the app with your own
  (free) Apple Development certificate.
