#!/usr/bin/env python3
"""i18n coverage: every _("...") msgid in code must exist (non-empty) in
locales/pt_BR.po and locales/es.po. Exit 1 with the missing list otherwise.
Usage: python3 tools/check_i18n.py (run from the plugin root)."""
import glob
import os
import re
import sys

PAT = re.compile(r'_\(\"((?:[^\"\\\\]|\\\\.)*)\"\)')
MSGID = re.compile(r'msgid \"((?:[^\"])*)\"')
EMPTY = re.compile(r'msgstr \"\"')


def main():
    ids = set()
    for path in glob.glob("**/*.lua", recursive=True):
        if path.startswith("tools/") or "/data/" in path:
            continue
        with open(path, encoding="utf-8", errors="replace") as f:
            ids.update(PAT.findall(f.read()))
    failed = False
    for lang in ("pt_BR", "es"):
        po_path = os.path.join("locales", lang + ".po")
        if not os.path.exists(po_path):
            print(f"{lang}.po: MISSING FILE")
            failed = True
            continue
        with open(po_path, encoding="utf-8") as f:
            content = f.read()
        found = set(MSGID.findall(content))
        missing = sorted(ids - found)
        if missing:
            print(f"{lang}.po: {len(missing)} missing msgids:")
            for m in missing:
                print(f"  {m!r}")
            failed = True
        if EMPTY.search(content):
            print(f"{lang}.po: has empty msgstr entries")
            failed = True
    print(f"checked {len(ids)} msgids")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
