#!/usr/bin/env python3
"""A consistent copy of the database, for a cron service or a laptop.

    python scripts/backup.py /where/to/put/it

Written through SQLite's backup API, so it is safe while the service is
serving; a plain copy of a live WAL database is not. Keeps the last 14 by
default, so a scheduled job doesn't fill the disk.

The admin can also take one by hand: Security -> Download a backup.
"""
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import db  # noqa: E402

KEEP = 14

out_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "./backups")
out_dir.mkdir(parents=True, exist_ok=True)
stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d-%H%M")
target = out_dir / f"piperstitch-{stamp}.sqlite3"

size = db.backup_to(str(target))
print(f"Wrote {target} ({size / 1024 / 1024:.1f} MB)")

old = sorted(out_dir.glob("piperstitch-*.sqlite3"))[:-KEEP]
for path in old:
    path.unlink()
    print(f"Removed {path.name}")
