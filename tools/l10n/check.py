#!/usr/bin/env python3
"""Checks the String Catalogs' translations (the iPhone/iPad app and its widgets).

    tools/l10n/check.py [lang …]

For every translated string: the same format specifiers as the English (%@, %lld, %f…,
positional or not), nothing empty, and plural forms present; the English plural forms keep the
key's specifiers too. Also lists keys a language has no translation for, translations that are
much longer than the English for short keys (buttons and badges), to look at on screen, and
permission texts both editions have (InfoPlist, one catalog per edition) that are translated
differently in each. The web UI has its own check (tools/l10n/web-keys.mjs --check).
Taken from GlassDash (tools/l10n/check.py).
"""
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CATALOGS = ["ios/Resources/Localizable.xcstrings", "widgets/Resources/Localizable.xcstrings",
            "ios/Resources/AppStore/InfoPlist.xcstrings", "ios/Resources/SmartLife/InfoPlist.xcstrings"]
# The permission texts of the App Store and the Smart Life edition (see ios/project.yml).
EDITIONS = CATALOGS[2:]
LANGS = ["ja", "fr", "es", "de", "it", "el", "tr", "zh-Hant", "ru"]
SPEC = re.compile(r"%(?:(\d+)\$)?(lld|ld|llu|lu|d|u|@|(?:\.\d+)?l?f)")


def specs(s):
    """The specifiers in order of their argument: positional ones by number."""
    found = []
    for i, m in enumerate(SPEC.finditer(s.replace("%%", ""))):
        pos = int(m.group(1)) if m.group(1) else None
        kind = m.group(2)
        kind = "f" if kind.endswith("f") else "d" if kind in ("lld", "ld", "llu", "lu", "d", "u") else "@"
        found.append((pos, kind))
    if any(p for p, _ in found):
        return sorted((p, k) for p, k in found)
    return [(i + 1, k) for i, (_, k) in enumerate(found)]


def values(loc):
    if "stringUnit" in loc:
        yield None, loc["stringUnit"].get("value", "")
    for kind, forms in loc.get("variations", {}).items():
        for form, v in forms.items():
            yield f"{kind}.{form}", v.get("stringUnit", {}).get("value", "")


def source(key, entry):
    """The English: the key, or what the catalog's English says for it (of a plural, "other")."""
    en = entry.get("localizations", {}).get("en", {})
    if "stringUnit" in en:
        return en["stringUnit"].get("value", key)
    other = en.get("variations", {}).get("plural", {}).get("other")
    return other["stringUnit"]["value"] if other else key


def one_drops_number(form, got, want):
    # A plural's "one" form may say the number in words ("un", "eine") and drop it.
    return bool(form) and form.endswith(".one") and len(got) == len(want) - 1


def editions_agree(langs):
    """Keys both editions' InfoPlist catalogs have with the same English: the same translations."""
    problems = 0
    a, b = (json.load(open(os.path.join(ROOT, c), encoding="utf-8"))["strings"] for c in EDITIONS)
    for key in sorted(set(a) & set(b)):
        if source(key, a[key]) != source(key, b[key]):
            continue
        for lang in langs:
            x, y = (s[key].get("localizations", {}).get(lang) for s in (a, b))
            if x and y and x != y:
                print(f"DIFFERS  {lang} InfoPlist: {key!r} is translated differently in the two editions")
                problems += 1
    return problems


def main():
    langs = sys.argv[1:] or LANGS
    problems = 0
    for cat in CATALOGS:
        path = os.path.join(ROOT, cat)
        if not os.path.exists(path):
            continue
        name = "/".join(cat.split("/")[-2:]) if cat.endswith("InfoPlist.xcstrings") else cat.split("/")[0]
        data = json.load(open(path, encoding="utf-8"))
        for key, entry in data["strings"].items():
            if entry.get("shouldTranslate") is False or not key.strip():
                continue
            locs = entry.get("localizations", {})
            want = specs(key if cat.endswith("Localizable.xcstrings") else source(key, entry))
            # Info.plist keys are names (NSCameraUsageDescription): the English is the text.
            for form, v in values(locs.get("en", {})):
                got = specs(v)
                if not v.strip():
                    print(f"EMPTY    en{'/' + form if form else ''}: {key!r}")
                    problems += 1
                elif got != want and not one_drops_number(form, got, want):
                    print(f"SPECS    en{'/' + form if form else ''}: {key!r} → {v!r}")
                    problems += 1
            if not cat.endswith("Localizable.xcstrings"):
                want = specs(source(key, entry))
            for lang in langs:
                if lang not in locs:
                    print(f"MISSING  {lang} {name}: {key!r}")
                    problems += 1
                    continue
                for form, v in values(locs[lang]):
                    tag = f"{lang}{'/' + form if form else ''}"
                    if not v.strip():
                        print(f"EMPTY    {tag}: {key!r}")
                        problems += 1
                        continue
                    got = specs(v)
                    if got != want and not one_drops_number(form, got, want):
                        print(f"SPECS    {tag}: {key!r} → {v!r}")
                        problems += 1
                    # A Shortcuts summary's parameter (${screen}) stays as it is.
                    if sorted(re.findall(r"\$\{\w+\}", v)) != sorted(re.findall(r"\$\{\w+\}", key)):
                        print(f"PARAM    {tag}: {key!r} → {v!r}")
                        problems += 1
                    en = source(key, entry)
                    if len(en) <= 12 and len(v) > max(2.2 * len(en), len(en) + 10) and lang != "ja":
                        print(f"LONG     {tag}: {en!r} → {v!r}")
    problems += editions_agree(langs)
    print(f"{problems} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
