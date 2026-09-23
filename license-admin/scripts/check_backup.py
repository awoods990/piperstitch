#!/usr/bin/env python3
"""Proves the off-platform backup actually works, end to end.

    python scripts/check_backup.py

It writes a small object, reads it back, compares it, lists the bucket
and deletes what it wrote — then says plainly what is right and what is
not. Run it after setting the four BACKUP_ variables; it is much quicker
than waiting until three in the morning to find out.
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import backups, config  # noqa: E402

REQUIRED = ("BACKUP_ENDPOINT", "BACKUP_BUCKET", "BACKUP_ACCESS_KEY", "BACKUP_SECRET_KEY")


def main() -> int:
    missing = [name for name in REQUIRED if not getattr(config, name)]
    if missing:
        print("Not configured yet. Missing:", ", ".join(missing))
        print("\nFor DigitalOcean Spaces these look like:")
        print("  BACKUP_ENDPOINT=https://nyc3.digitaloceanspaces.com")
        print("  BACKUP_BUCKET=piperstitch-backups")
        print("  BACKUP_REGION=nyc3            (the datacentre, not us-east-1)")
        print("  BACKUP_ACCESS_KEY / BACKUP_SECRET_KEY from Spaces Keys")
        return 1

    print(f"Endpoint : {config.BACKUP_ENDPOINT}")
    print(f"Bucket   : {config.BACKUP_BUCKET}")
    print(f"Region   : {config.BACKUP_REGION}")
    print(f"Style    : {'path' if config.BACKUP_PATH_STYLE else 'virtual-host'}")
    key = "healthcheck/round-trip.txt"
    payload = b"If you can read this, PiperStitch can write to this bucket and read back what it wrote."

    try:
        print("\nWriting...", end=" ", flush=True)
        backups.put(key, payload)
        print("ok")

        print("Reading back...", end=" ", flush=True)
        got = backups.get(key)
        if got != payload:
            print(f"MISMATCH — wrote {len(payload)} bytes, read {len(got)}")
            return 2
        print("ok, byte for byte")

        print("Listing...", end=" ", flush=True)
        keys = backups.listing("healthcheck/")
        print(f"ok ({len(keys)} object{'' if len(keys) == 1 else 's'} under healthcheck/)")

        print("Cleaning up...", end=" ", flush=True)
        backups.delete(key)
        print("ok")
    except Exception as e:  # noqa: BLE001 - the whole point is to explain the failure
        print(f"FAILED\n\n{type(e).__name__}: {e}\n")
        print("Most likely causes, in order:")
        print("  * the key has no write access to this bucket (Spaces keys are account-wide; check the bucket name)")
        print("  * BACKUP_REGION doesn't match the datacentre in the endpoint (nyc3, ams3, sgp1, fra1, sfo3, syd1)")
        print("  * the endpoint has the bucket name in it — it should not; the bucket goes in BACKUP_BUCKET")
        print("  * the bucket doesn't exist yet, or is spelled differently")
        return 3

    print("\nAll good. Nightly backups will land here, and each one is read back and checked.")
    print(f"Next: run a real one now with  python -c \"from app import backups; print(backups.run())\"")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
