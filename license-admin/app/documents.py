"""Encryption for the one thing here that could ruin somebody's year.

A W-9 carries a Social Security number. Stored as plain base64 it sits in
the database, in every volume snapshot, and in any copy of either — so
anyone who ever gets a copy of the file gets the number. With
DOCUMENT_ENCRYPTION_KEY set, the bytes are encrypted before they are
written and decrypted only when an admin opens the file.

AES-GCM from `cryptography`, which is already here for licence signing:
authenticated, so a tampered blob fails rather than decodes to rubbish.
The key belongs in the environment, not in the database it protects.

Without the key nothing breaks: documents are stored as they were, and
the admin says so. Existing plaintext rows keep working after the key is
set, and are encrypted the next time they're touched.
"""

from __future__ import annotations

import base64
import hashlib
import logging
import os

from . import config

log = logging.getLogger("license_admin.documents")

PREFIX = "enc:v1:"          # anything without this is plaintext base64 from before


def enabled() -> bool:
    return bool(config.DOCUMENT_ENCRYPTION_KEY)


def _key() -> bytes:
    """A 32-byte key from whatever the environment gives us: base64 of 32
    bytes ideally, any passphrase otherwise (hashed, so a short one is
    still the right length -- if not the right amount of entropy)."""
    raw = config.DOCUMENT_ENCRYPTION_KEY.strip()
    try:
        decoded = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
        if len(decoded) == 32:
            return decoded
    except Exception:  # noqa: BLE001 - it simply wasn't base64
        pass
    return hashlib.sha256(raw.encode()).digest()


def seal(raw: bytes) -> str:
    """Bytes in, a string for the database out."""
    if not enabled():
        return base64.b64encode(raw).decode()
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    nonce = os.urandom(12)
    sealed = AESGCM(_key()).encrypt(nonce, raw, None)
    return PREFIX + base64.b64encode(nonce + sealed).decode()


def open_(stored: str) -> bytes:
    """The database's string back to bytes, whichever way it was written."""
    if not stored.startswith(PREFIX):
        return base64.b64decode(stored)
    if not enabled():
        raise ValueError("This document is encrypted and DOCUMENT_ENCRYPTION_KEY is not set on this service.")
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    blob = base64.b64decode(stored[len(PREFIX):])
    return AESGCM(_key()).decrypt(blob[:12], blob[12:], None)


def is_sealed(stored: str) -> bool:
    return stored.startswith(PREFIX)
