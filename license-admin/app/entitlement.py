"""Entitlement tokens — the subscription-world replacement for Amerus's
license key.

Amerus mints one permanent Ed25519-signed key per purchase and the app
verifies it forever. PiperStitch is a monthly subscription, so what the
app holds instead is a short-lived *entitlement*: a signed statement
"customer N, on device D, may use PiperStitch until date X". The app
refreshes it silently whenever it has a network connection (see
Sources/StitchPilotCore/Licensing/ in the main repo); if it can't, the
one it already has keeps working until X. X is bounded by
config.ENTITLEMENT_MAX_DAYS so a cancelled subscription can't stay
unlocked indefinitely by going offline — see subscriptions.validity_for.

Wire format (must stay byte-for-byte in sync with the Swift verifier,
EntitlementVerifier.swift):

    PSE1.<base64url(payload JSON, no padding)>.<base64url(64-byte Ed25519 signature)>

The signature is over the exact payload bytes as encoded — the app
verifies first, then parses the JSON, and never trusts a field it
couldn't verify. The payload is deliberately plain JSON rather than the
packed binary Amerus uses: nobody ever types an entitlement by hand, so
its length doesn't matter, and JSON is trivially decodable on the Swift
side with no custom struct-packing to keep in sync.

Payload fields:
    v        1 — format version; anything else is rejected
    cid      customer id in this service's database
    dev      the device_id the app presented at sign-in (the app refuses
             a token minted for a different Mac)
    email    for display in the app's account panel only
    status   'active' | 'trialing' | 'past_due' | 'comp' — display only
    exp      ISO-8601 UTC — the app locks after this
    iat      ISO-8601 UTC — issued at
    period_end   ISO-8601 UTC or null — the billing period's real end,
             so the app can say "renews on ..." / "ends on ..."
    cancel_at_period_end   bool — so the app can say "ends" not "renews"

Like the Amerus License Admin's keygen.py, this module is handed the
PRIVATE key (config.PIPERSTITCH_LICENSE_PRIVATE_KEY): never log it, never
put it in an error message, never send it anywhere but the signing call.
"""

from __future__ import annotations

import base64
import binascii
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

TOKEN_PREFIX = "PSE1"
_VERSION = 1

# The public half of the keypair in ~/Documents/PiperStitch-Licensing/ —
# the same value baked into the shipped app's EntitlementVerifier.swift.
# Safe to keep here: it can confirm a token is genuine but can't mint one.
# Used only to self-check freshly-signed tokens before they leave.
_PUBLIC_KEY_B64 = "OLvbWOM6exl9IL11JHluZkzrTVsQQZs7kB3eHpJJJDY="


class EntitlementError(Exception):
    """Signing failed (bad/missing private key) or a token failed to
    verify — always a plain-language reason, never a raw crypto exception."""


@dataclass(frozen=True)
class Entitlement:
    customer_id: int
    device_id: str
    email: str
    status: str
    expires_at: datetime
    issued_at: datetime
    period_end: Optional[datetime]
    cancel_at_period_end: bool
    canonical: str


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _unb64url(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _parse_iso(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def _public_key() -> Ed25519PublicKey:
    return Ed25519PublicKey.from_public_bytes(base64.b64decode(_PUBLIC_KEY_B64))


def sign(
    private_key_b64: str,
    *,
    customer_id: int,
    device_id: str,
    email: str,
    status: str,
    expires_at: datetime,
    period_end: Optional[datetime],
    cancel_at_period_end: bool,
    issued_at: Optional[datetime] = None,
) -> str:
    """Mints a signed entitlement token. Raises EntitlementError (never a
    bare crypto exception) if the private key is missing or malformed."""
    if not private_key_b64:
        raise EntitlementError("PIPERSTITCH_LICENSE_PRIVATE_KEY is not configured — cannot sign an entitlement.")
    try:
        private_key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(private_key_b64))
    except (binascii.Error, ValueError) as e:
        raise EntitlementError("PIPERSTITCH_LICENSE_PRIVATE_KEY is not a valid private key.") from e

    issued_at = issued_at or datetime.now(timezone.utc)
    payload = {
        "v": _VERSION,
        "cid": int(customer_id),
        "dev": device_id,
        "email": email,
        "status": status,
        "exp": _iso(expires_at),
        "iat": _iso(issued_at),
        "period_end": _iso(period_end) if period_end else None,
        "cancel_at_period_end": bool(cancel_at_period_end),
    }
    payload_bytes = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    signature = private_key.sign(payload_bytes)
    token = f"{TOKEN_PREFIX}.{_b64url(payload_bytes)}.{_b64url(signature)}"

    # Self-check against the public key before the token leaves — a
    # mismatch here means the configured private key doesn't pair with
    # the public key baked into the shipped app, and every customer's
    # sign-in would silently fail. Far better to fail loudly here.
    parse_and_verify(token)
    return token


def parse_and_verify(token: str) -> Entitlement:
    """The same acceptance logic the app applies (EntitlementVerifier.swift):
    signature over the raw payload bytes first, then the fields."""
    parts = token.strip().split(".")
    if len(parts) != 3 or parts[0] != TOKEN_PREFIX:
        raise EntitlementError("That isn't a PiperStitch entitlement token.")
    try:
        payload_bytes = _unb64url(parts[1])
        signature = _unb64url(parts[2])
    except (binascii.Error, ValueError) as e:
        raise EntitlementError("That entitlement token is corrupted.") from e

    try:
        _public_key().verify(signature, payload_bytes)
    except InvalidSignature as e:
        raise EntitlementError("That entitlement token isn't valid.") from e

    try:
        payload = json.loads(payload_bytes)
        if payload.get("v") != _VERSION:
            raise EntitlementError("This entitlement was issued in a newer format than this service understands.")
        return Entitlement(
            customer_id=int(payload["cid"]),
            device_id=str(payload["dev"]),
            email=str(payload["email"]),
            status=str(payload["status"]),
            expires_at=_parse_iso(payload["exp"]),
            issued_at=_parse_iso(payload["iat"]),
            period_end=_parse_iso(payload["period_end"]) if payload.get("period_end") else None,
            cancel_at_period_end=bool(payload.get("cancel_at_period_end", False)),
            canonical=token.strip(),
        )
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as e:
        raise EntitlementError("That entitlement token is corrupted.") from e
