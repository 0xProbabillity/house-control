#!/usr/bin/env python3
"""Translation context for the String Catalogs (the iPhone/iPad app and its widgets).

For every key in the catalogs, finds where the English text appears in the Swift sources and
writes a JSON list for translators: the key, the developer comment, where it is used (a few lines
of code around it), and what each language has today. Usage:

    tools/l10n/context.py out.json [lang]

With `lang`, only keys that language has no translation for yet.
"""
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CATALOGS = ["ios/Resources/Localizable.xcstrings", "widgets/Resources/Localizable.xcstrings",
            "ios/Resources/AppStore/InfoPlist.xcstrings", "ios/Resources/SmartLife/InfoPlist.xcstrings"]
SOURCES = ["ios/Sources", "widgets/Sources"]


def swift_files():
    for top in SOURCES:
        for d, _, files in os.walk(os.path.join(ROOT, top)):
            for f in files:
                if f.endswith(".swift"):
                    yield os.path.join(d, f)


def literal_pattern(key):
    """The key as it is written in Swift: %@ / %lld … stand for \\(…) interpolations."""
    parts = re.split(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f|lf|u|llu)", key)
    esc = [re.escape(p.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")) for p in parts]
    return re.compile(r"\\\([^\n]*?\)".join(esc))


def main():
    out = sys.argv[1]
    lang = sys.argv[2] if len(sys.argv) > 2 else None
    sources = {p: open(p, encoding="utf-8").read().split("\n") for p in swift_files()}
    items = []
    for cat in CATALOGS:
        data = json.load(open(os.path.join(ROOT, cat), encoding="utf-8"))
        for key, entry in data["strings"].items():
            if entry.get("shouldTranslate") is False or not key.strip():
                continue
            locs = entry.get("localizations", {})
            if lang and lang in locs:
                continue
            uses = []
            en = locs.get("en", {})
            # A key of its own (`defaultValue:`): the English is in the catalog, the key in the code.
            english = en.get("stringUnit", {}).get("value") or \
                en.get("variations", {}).get("plural", {}).get("other", {}).get("stringUnit", {}).get("value")
            if not cat.endswith("InfoPlist.xcstrings"):
                pat = literal_pattern(key)
                for path, lines in sources.items():
                    for i, line in enumerate(lines):
                        if pat.search(line):
                            lo, hi = max(0, i - 2), min(len(lines), i + 2)
                            uses.append({"file": os.path.relpath(path, ROOT), "line": i + 1,
                                         "code": "\n".join(lines[lo:hi])})
                            if len(uses) >= 2:
                                break
                    if len(uses) >= 2:
                        break
            items.append({"catalog": cat, "key": key, "comment": entry.get("comment"),
                          "uses": [{"at": f"{u['file']}:{u['line']}", "code": u["code"]} for u in uses],
                          **({"english": english} if english and english != key else {}),
                          "existing": {l: v for l, v in locs.items() if l != "en"}})
    json.dump(items, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"{len(items)} strings → {out}")


if __name__ == "__main__":
    main()
