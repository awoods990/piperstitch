#!/usr/bin/env python3
"""Encrypts tax forms that were stored before DOCUMENT_ENCRYPTION_KEY was
set. Safe to run repeatedly: anything already encrypted is left alone.

    DOCUMENT_ENCRYPTION_KEY=... python scripts/encrypt_documents.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import db, documents  # noqa: E402

if not documents.enabled():
    raise SystemExit("DOCUMENT_ENCRYPTION_KEY is not set — nothing to do.")

done = skipped = 0
with db.connection() as conn:
    rows = conn.execute("SELECT id, data FROM partner_documents").fetchall()
    for row in rows:
        if documents.is_sealed(row["data"]):
            skipped += 1
            continue
        conn.execute("UPDATE partner_documents SET data = ? WHERE id = ?", (documents.seal(documents.open_(row["data"])), row["id"]))
        done += 1
print(f"Encrypted {done} document(s); {skipped} already were.")
