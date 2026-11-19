#!/usr/bin/env python3
"""Puts the String Catalogs of the iPhone/iPad app and its widgets into the repository's layout
after Xcode refreshed them from the code (tools/l10n/export.sh runs it).

    tools/l10n/normalize.py [edition-snapshot-dir …]

Each snapshot folder holds `app.xcstrings` and `widgets.xcstrings` as one edition's export left
them. An export drops the untranslated keys the code of that edition does not use (Smart Life's
screens are not in the App Store edition), so the keys of every edition are put back together:
a key any edition uses is kept, without a "stale" mark. Then:

- English plural forms for the counts in PLURALS (the key is the "other" form),
- comments for keys that reach the code through a helper's argument (COMMENTS), where Xcode
  finds none,
- shouldTranslate false for the brand and for keys that are only placeholders,

and every catalog is written as merge.py writes it (indent 2, sorted keys, " : ").
"""
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APP = "ios/Resources/Localizable.xcstrings"
WIDGETS = "widgets/Resources/Localizable.xcstrings"
INFOPLISTS = ["ios/Resources/AppStore/InfoPlist.xcstrings", "ios/Resources/SmartLife/InfoPlist.xcstrings"]

# English "one" forms of the keys that count something.
PLURALS = {
    APP: {
        "%lld rooms": "%lld room",
        "%lld devices": "%lld device",
        "%lld real devices linked": "%lld real device linked",
        "Controlling %lld devices": "Controlling %lld device",
        "%lld accessories": "%lld accessory",
        "%lld devices in your floor plan are now the real thing.": "%lld device in your floor plan is now the real thing.",
        "%lld pieces of furniture": "%lld piece of furniture",
        "%lld devices pinned": "%lld device pinned",
    },
    WIDGETS: {
        "%lld lights on": "%lld light on",
    },
}

# Keys passed to a helper that takes a LocalizedStringKey: Xcode extracts them without a comment.
COMMENTS = {
    APP: {
        "Choose **Pair Phone…** (**Pair iPhone…** in older versions) — a code appears.":
            "Pairing step 2. Pair Phone… and Pair iPhone… are menu items of House Control on the computer; "
            "keep them as they are there (in English until the computer's app is translated)",
        "On your computer, right-click the House Control icon: in the menu bar on a Mac, in the taskbar's tray on a PC.":
            "Pairing step 1",
        "Point this iPhone at the code. Both devices need to be on the same Wi-Fi.": "Pairing step 3",
        "Point this iPad at the code. Both devices need to be on the same Wi-Fi.": "Pairing step 3",
        "Save the code to Photos (below).": "Smart Life sign-in, step 1",
        "In Smart Life tap **+** → **Scan**, then the **photo** icon, and pick the code.":
            "Smart Life sign-in, step 2; + and Scan are the Smart Life app's buttons",
        "Confirm the login and come back here.": "Smart Life sign-in, step 3",
        "Next room": "Scan: button under the camera that finishes this room and starts the next; short",
        "Done": "Button that finishes the screen or the scan",
        "Version": "Settings › About: the app's version",
        "Privacy": "Settings › About: next to it, what the app collects",
        "Room": "Add devices: picker of the room the devices go into",
        "Kind": "Scan: picker label, whether the pinned device is a lamp or an air conditioner",
        "Bridge": "Hue: section title over the paired Hue Bridge",
        "Server": "Home Assistant: section title over the connected server",
        "Pair": "Hue: button that starts pairing with a bridge",
        "Connect": "Button that connects House Control to a service (Home Assistant, Apple Home)",
        "Allow": "Settings › Apple Home: small button that opens iOS Settings to allow HomeKit",
        "Turn off": "Settings › Apple Home: small button; stops using HomeKit",
        "Shortcuts": "Settings: section title over Quick Actions (the app icon's menu), not the Shortcuts app",
        "Name": "Section title over the home's name field",
        "Start from": "New home: section title over the layouts to start from",
        "Save as": "Scan review: section title; save the scan as a new home or as another floor",
        "Close": "Button (and VoiceOver label of the × button) that closes the scan",
        "Discard": "Scan review: button that throws the scan away",
        "Replace": "Confirmation button: the new home replaces the one there now",
        "Bring back": "Earlier homes: button that makes the kept home the home again",
        "Beta": "VoiceOver: the BETA badge",
        "Decide later": "Alert button: keep both floor plans as they are for now",
        "Remove %@": "VoiceOver: removes a pinned device from the scan; the placeholder is its name",
        "Add %@": "VoiceOver: adds a quick action to the app icon; the placeholder is its name",
        "Preview: %@": "VoiceOver: the app icon's menu as it will look; the placeholder lists its items",
        "Floor name": "Scan review: label of the name of the floor being added",
        "Rooms": "Section title over the rooms of the scan",
        "Developer": "Settings: section title over the developer's links",
        "Earlier homes": "Settings: menu of the homes kept before something replaced them",
        "Screen": "Shortcuts: the screen House Control opens on",
        "Home": "Shortcuts: House Control opens on the home in 3D",
        "Floor Plan": "Shortcuts: House Control opens on the floor plan editor",
        "Settings": "House Control's own settings",
        "Opens in Safari": "VoiceOver hint of a link",
        "Unpair": "Button that ends the link to the paired computer",
    },
    WIDGETS: {
        "Scenes": "Widget: small caps caption over the scene buttons; also the widget's name",
        "Rooms": "Widget: small caps caption over the rooms",
        "No lamps in this home yet": "Widget without anything to show",
        "No room with lamps yet": "Widget without anything to show",
        "No air conditioner in this home": "Widget without anything to show",
        "On": "Shortcuts: name of an action's on/off parameter (whether to switch on)",
        "Open": "Control Center: the control's status before the app has run (it opens the app); also the name of its setting, which screen it opens",
        "Step": "Shortcuts: degrees an action changes the AC's set-point by",
        "Room": "A room of the home (widget and Shortcuts)",
        "Light": "A lamp (noun): widget name, Shortcuts",
        "Home": "The home in 3D (where the app opens); also the name of a home that has none",
        "Screen": "Shortcuts: the screen House Control opens on",
        "Floor Plan": "The floor plan editor (where the app opens)",
        "Settings": "House Control's own settings",
        "Climate": "Name of the widget for one air conditioner",
        "All Lights": "Name of the Control Center control that switches every lamp",
    },
}

# Never translated: the app's name, and keys that are only a placeholder.
KEEP = {"", "House Control", "%@", "%lld", "%@ %@", "%lld%%",
        "Home Assistant", "Philips Hue", "Apple Home", "Smart Life", "Hue Bridge"}
INFOPLIST_KEEP = {"CFBundleDisplayName", "CFBundleName"}


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
        f.write("\n")


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def united(cat, snapshots):
    """The catalog with the keys of every edition's export."""
    data = load(os.path.join(ROOT, cat))
    strings = data["strings"]
    live = set()
    for snap in snapshots:
        for key, entry in snap["strings"].items():
            if entry.get("extractionState") != "stale":
                live.add(key)
            if key not in strings:
                strings[key] = entry
            else:
                # Keep what the catalog has; take an edition's comment when it has none.
                if "comment" not in strings[key] and "comment" in entry:
                    strings[key]["comment"] = entry["comment"]
    for key in live:
        if strings[key].get("extractionState") == "stale":
            del strings[key]["extractionState"]
    return data


def fix(cat, data):
    strings = data["strings"]
    for key, one in PLURALS.get(cat, {}).items():
        if key not in strings:
            print(f"  {cat}: no key {key!r} for its English plural")
            continue
        strings[key].setdefault("localizations", {})["en"] = {
            "variations": {"plural": {"one": unit(one), "other": unit(key)}}}
    for key, comment in COMMENTS.get(cat, {}).items():
        if key in strings and not strings[key].get("comment"):
            strings[key]["comment"] = comment
    for key in KEEP:
        if key in strings:
            strings[key]["shouldTranslate"] = False


def main():
    snaps = sys.argv[1:]
    for cat, name in ((APP, "app.xcstrings"), (WIDGETS, "widgets.xcstrings")):
        found = [load(os.path.join(d, name)) for d in snaps if os.path.exists(os.path.join(d, name))]
        data = united(cat, found)
        fix(cat, data)
        save(os.path.join(ROOT, cat), data)
        print(f"{cat}: {len(data['strings'])} keys")
    for cat in INFOPLISTS:
        path = os.path.join(ROOT, cat)
        data = load(path)
        for key in INFOPLIST_KEEP & set(data["strings"]):
            data["strings"][key]["shouldTranslate"] = False
        save(path, data)
        print(f"{cat}: {len(data['strings'])} keys")


if __name__ == "__main__":
    main()
