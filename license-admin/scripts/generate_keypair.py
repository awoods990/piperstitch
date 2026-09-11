"""Generates a NEW Ed25519 entitlement-signing keypair. You should only
ever need this once — the real keypair already lives in
~/Documents/PiperStitch-Licensing/PRIVATE_KEY_DO_NOT_SHARE.txt and its
public half is baked into both app/entitlement.py here and the shipped
app's EntitlementVerifier.swift. Generating a new one means updating BOTH
of those and shipping a new app build, after which every previously
installed copy will reject tokens from the new key. See LICENSING.md."""

from __future__ import annotations

import base64

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def main() -> None:
    key = Ed25519PrivateKey.generate()
    priv = base64.b64encode(key.private_bytes_raw()).decode()
    pub = base64.b64encode(key.public_key().public_bytes_raw()).decode()
    print("PRIVATE_KEY_B64=" + priv + "   <- .env PIPERSTITCH_LICENSE_PRIVATE_KEY; never commit")
    print("PUBLIC_KEY_B64=" + pub + "   <- app/entitlement.py _PUBLIC_KEY_B64 AND EntitlementVerifier.swift")


if __name__ == "__main__":
    main()
