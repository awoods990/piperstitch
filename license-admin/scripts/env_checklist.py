#!/usr/bin/env python3
"""Lists every environment variable this service reads — names only,
never values — so the one thing no backup can hold for you can be kept
somewhere deliberate.

    python scripts/env_checklist.py            # what this service needs
    python scripts/env_checklist.py --set      # ...and which are set here

A perfect backup with none of these restores nothing: RESTORE.md explains
which can be reissued (Stripe, Postmark, the bucket) and which cannot
(the licence key, the document key).
"""
import os
import re
import sys
from pathlib import Path

CONFIG = Path(__file__).resolve().parent.parent / "app" / "config.py"
CANNOT_BE_REISSUED = {"PIPERSTITCH_LICENSE_PRIVATE_KEY", "DOCUMENT_ENCRYPTION_KEY"}
SECRET_ISH = re.compile(r"KEY|SECRET|TOKEN|PASSWORD|HASH")

source = CONFIG.read_text()
names = sorted(set(re.findall(r'os\.environ\.get\(\s*"([A-Z0-9_]+)"', source))
               | set(re.findall(r'_(?:int|bool)\(\s*"([A-Z0-9_]+)"', source)))
show_set = "--set" in sys.argv

print(f"{len(names)} variables read by this service.\n")
for name in names:
    marks = []
    if name in CANNOT_BE_REISSUED:
        marks.append("CANNOT BE REISSUED — keep a copy")
    elif SECRET_ISH.search(name):
        marks.append("secret")
    if show_set:
        marks.append("set here" if os.environ.get(name) else "not set here")
    print(f"  {name:34} {' · '.join(marks)}")

print("\nKeep the ones marked secret in a password manager, with the two marked")
print("CANNOT BE REISSUED first: without them, a restored backup is missing")
print("licence signing and partners' tax forms respectively.")
