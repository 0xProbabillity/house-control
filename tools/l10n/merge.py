#!/usr/bin/env python3
"""Merges translations into the String Catalogs.

    tools/l10n/merge.py <lang> translations.json

translations.json: [{"catalog": …, "key": …, "value": "…"}] or, for a count, a plural:
{"catalog": …, "key": …, "plural": {"one": "…", "other": "…"}} (the key's only number decides).
"catalog" is the path from the repository's root (ios/Resources/Localizable.xcstrings…); a
permission text both editions share goes to both InfoPlist catalogs. Keys that are not in the
catalog any more are reported and skipped. Taken from GlassDash.
"""
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def main():
    lang, path = sys.argv[1], sys.argv[2]
    items = json.load(open(path, encoding="utf-8"))
    by_cat = {}
    for it in items:
        by_cat.setdefault(it["catalog"], []).append(it)
    for cat, its in by_cat.items():
        file = os.path.join(ROOT, cat)
        data = json.load(open(file, encoding="utf-8"))
        missing = 0
        for it in its:
            entry = data["strings"].get(it["key"])
            if entry is None:
                missing += 1
                print(f"  not in {cat}: {it['key']!r}")
                continue
            locs = entry.setdefault("localizations", {})
            if it.get("plural"):
                locs[lang] = {"variations": {"plural": {k: unit(v) for k, v in it["plural"].items()}}}
            else:
                locs[lang] = unit(it["value"])
        with open(file, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
            f.write("\n")
        print(f"{cat}: {len(its) - missing} merged for {lang}, {missing} missing")


if __name__ == "__main__":
    main()
