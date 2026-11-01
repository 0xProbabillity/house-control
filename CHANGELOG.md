# Changelog

What changed in each release of House Control. The Mac app is on
[Releases](https://github.com/0xProbabillity/house-control/releases); the iPhone app is on the App Store and TestFlight.

## 1.3.0 — in TestFlight

### Homes on several floors

- **Floors.** A house can have as many floors as it needs, each with its own name and ceiling height (a basement
  too). The 3D model shows one floor at a time, standing on the floors under it; buttons under the model switch
  floors, and picking a room, a lamp or an AC goes to its floor by itself. The panel lists devices floor by floor,
  starting with the one on show, and remembers which floor you last looked at.
- **Stairs**, as a piece of furniture that climbs to the floor above.
- A new demo, **House**, on two floors, in the plan menu, the iPhone's Settings and **New home**.
- Widgets draw the floor with the most lamps on. The phone's Devices screen names each room's floor.
- AI Access can read and build homes on several floors (`add_floor`, `"level"` on rooms, furniture and openings).
- A home on one floor looks and works as before; its plan file does not change.

### The floor plan editor

- **Floor tabs over the plan**, with **+ Floor**. A new floor copies the rooms of the one below (its windows and
  inner doors too), or starts as one room as big as it; the floor below shows faintly under the one being edited,
  with its stairs, so walls and landings line up. A floor's settings: name, ceiling height, order, remove.
- **Resize a room from any corner or side**, not only the bottom-right corner. Edges snap to the walls of the
  rooms around them (and of the floor below), with a guide line; hold ⌥ not to.
- **Doors and windows slide along the walls** and jump to the nearest one; drag the dots at their ends to make
  them wider. A new window goes on a far wall, where the 3D model shows it.
- **Split in two** divides a room, moves its lamps and ACs to the half they stand in and puts a door between.
- **Duplicate** (⌘D) and **turn** (R, ⇧R) on the Mac; buttons for both on the phone.
- **Zoom and move around on the Mac:** scroll, pinch or ⌘-scroll, drag the empty plan or hold Space; zoom
  buttons and ⌘0 to see the whole floor.
- **An add bar under the plan** (Mac): room, lamp, AC, door, window, stairs, furniture. On the phone, **Add** has
  windows, stairs and floors too.
- A list of shortcuts under Home settings.
- **Fixed:** in Chrome-based web views (Android) the editor did not fill its window.
- **Fixed (phone):** a sheet sliding away could still catch a tap.

## 1.2.0 — 2026-10-28

### iPhone

- **iPhone Duo.** Open, the app fills the inner display (not a phone-sized column in the middle of it): the home in 3D on one half, scenes, rooms and
  devices on the other. Half-folded like a book it breaks exactly at the fold; standing like a laptop, the model
  is on the upper half and the controls on the lower one. Held upright and flat, tiles go three to a row. Opening
  the phone plays the camera sweep and the lights coming on. See [iPhone Duo](README.md#iphone-duo).
- **The floor plan editor on a wide screen** keeps the plan on the left and the details of what is picked on the
  right; **Add** and **Items** open as cards in the middle.
- **Settings, connections and the welcome screen** keep a readable width on a wide screen. On a short screen (the
  Duo's outer one) the welcome screen tightens up, and scrolls where even that does not fit.

## 1.1.0 — 2026-10-22

### iPhone

- **Fixed: the app quit at the first touch on iOS 17.** It made its web view before it had a window; it now makes
  it when it first goes on screen.
- **Phone editor:** a tap on what is already selected brings up its details.
- **House Control in Control Center:** a button that opens the app, for Control Center, the Lock Screen and the
  Action button (iOS 18). It opens on the home in 3D and, made wide, says how the home is ("6 on · AC 23°"); tap it
  while editing Control Center to have it open the floor plan editor or settings instead. **Open House Control** is
  in Shortcuts too.

### Mac

- **Settings window** (⌘,): General (Open at Login, the island), Home (floor plans, the editor, plan files),
  Connections (Smart Life, Home Assistant, Hue and Apple Home, each a click away from its setup), iPhone (pairing
  and who is connected), AI Access and About. It is in the menu bar icon's right-click menu and the panel's gear
  menu too ([#6](https://github.com/0xProbabillity/house-control/issues/6)).
- **Open at Login**, in the menu bar icon's right-click menu and in the panel's gear menu: House Control starts with
  your Mac. It is the app's entry under System Settings → General → Login Items, so it can be switched off there too.
  Run from the disk image, the app asks to be moved to Applications first; moved there later, the login item follows it.

### 3D

- **Floor plans with many lamps no longer render black.** Every lamp that casts a shadow costs the 3D view a texture
  unit, and a real home with more than about 15 lamps ran out of them. Up to 8 lamps keep their shadow now (one per
  room first, ceiling lights and pendants before the rest); all of them still light their room. Thanks,
  [@wzpan](https://github.com/wzpan) ([#13](https://github.com/0xProbabillity/house-control/pull/13)).
- **An AC or heater low on the wall blows along the floor** instead of through it. Thanks,
  [@sidun-av](https://github.com/sidun-av) ([#10](https://github.com/0xProbabillity/house-control/pull/10)).

### Home Assistant

- **A thermostat that is on but not running shows as idle.** When the room is already warm (or cool) enough, Home
  Assistant reports `hvac_action: idle`; the 3D unit then stops blowing air and its tile and island chip are outlined
  with "Idle" instead of lit as if it were heating. Thanks, [@sidun-av](https://github.com/sidun-av)
  ([#14](https://github.com/0xProbabillity/house-control/pull/14)).

## 1.0.0 — 2026-10-15

### Widgets, controls and quick actions

- **Widgets** for the iPhone's Home Screen, Lock Screen and StandBy, and for the Mac's desktop: Home in 3D,
  Scenes, Light, Room, Climate and Home Status.
- **Control Center controls** on the iPhone: All Lights, a Light, a Scene and an Air Conditioner.
- **Quick actions** on the iPhone's app icon, chosen in Settings.
- Every widget is live: tap a lamp, a scene or an AC and it switches without opening the app. On the Mac the app in
  the menu bar carries it out; on the iPhone the widget talks to Home Assistant, Hue and Smart Life itself.
  See [docs/widgets.md](https://github.com/0xProbabillity/house-control/blob/main/docs/widgets.md).

### An iPhone app that needs no Mac

- **Floor plan editor on the phone:** the Mac's editor laid out for a finger — tap to select, drag what is selected,
  pan, pinch to zoom, details in a sheet from the bottom. **New home** starts from one room or a demo layout.
- **Home Assistant and Philips Hue** screens on the phone; servers and bridges on the Wi-Fi are found by themselves.
- **Devices:** link each lamp and AC to a real device from one searchable list, or add several devices to a room
  already linked.
- **Smart Life on a single phone:** save the sign-in code to Photos and scan it from the Smart Life app.
- **Sync both ways.** A paired Mac is optional. Plans edited on either side reach the other, and so do Home Assistant
  and Hue connections (the newest wins, a disconnect included). If both changed the plan while apart, the phone
  asks which one to keep.

### Two iPhone editions

- **App Store edition:** Home Assistant, Philips Hue and Apple Home.
- **Smart Life edition:** all of that plus Smart Life / Tuya, for TestFlight and your own phone.
- Smart Life now lives in its own module (`HouseSmartLife`), linked only by the Mac app and the Smart Life
  edition. The two editions are separate apps and can sit on one phone.

### Also

- **About** links (website, privacy policy, support, source) on the iPhone and in the Mac's menu.
- The editor only offers the platforms the app has.
- A privacy manifest for the widgets.
- From this release on, every Mac disk image carries a build provenance attestation:
  `gh attestation verify HouseControl-1.0.0.dmg --repo 0xProbabillity/house-control`
  ([#5](https://github.com/0xProbabillity/house-control/issues/5)).

### Fixed

- The iPhone never found Hue Bridges or Home Assistant servers on the network: iOS only browses the Bonjour types an
  app declares, and those two were missing.
- Widgets could jump back to an older state when the app started with widget taps still queued.

## 0.1.0 — 2026-10-14

The first public release: the home as a live 3D model in the Mac menu bar and on the iPhone, the island under the
notch, the floor plan editor, AI Access, and Smart Life, Home Assistant, Philips Hue and Apple Home.

This image was built while the repository was still private, so it has no build provenance attestation — only its
SHA-256 can be checked.
