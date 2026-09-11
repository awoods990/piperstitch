"""Signing a Mac in to a subscription, and the customer's self-service
magic link. Both are "prove you can read this email address" flows —
there is no password anywhere in PiperStitch's account model, because a
subscription that's already tied to an email doesn't need a second
secret for the customer to remember.

App sign-in (the replacement for pasting a license key):
  1. The app POSTs email + a stable per-Mac device_id to /api/app/activate/request.
     We email a six-digit code. Codes are stored hashed, expire in
     ACTIVATION_CODE_TTL_MINUTES, and only the newest one for that
     email+device is live.
  2. The app POSTs the code to /api/app/activate/verify. On success it
     receives a long-lived bearer *device token* (stored hashed here,
     kept in the Keychain there) plus its first signed entitlement.
  3. From then on the app POSTs the device token to /api/app/entitlement
     whenever it wants a fresh entitlement; no more emails.

Device limits are enforced at step 2: a Mac that's already signed in
just gets a new token, a new Mac beyond MAX_DEVICES is refused with a
message pointing at the account page, where old Macs can be signed out.
"""

from __future__ import annotations

import hashlib
import hmac
import secrets
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

from . import config, db, email_sender, subscriptions

MAX_CODES_PER_HOUR = 5
MAX_VERIFY_ATTEMPTS = 5


class ActivationError(Exception):
    """Carries a machine-readable `code` for the app to branch on and a
    human message to show verbatim."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _expired(iso: str) -> bool:
    return db.parse_iso(iso).replace(tzinfo=timezone.utc) <= _now()


# -------------------------------------------------------------- app sign-in ---


def request_code(*, email: str, device_id: str, device_name: str) -> dict:
    """Returns {"sent": bool, "reason": ...}. Deliberately tells the app
    when there's no subscription for the address — the honest answer
    ("subscribe first") is far more useful to a real customer than the
    enumeration-resistant silence Amerus's public API uses, and the
    information leaked (whether an email subscribes to embroidery
    software) is not sensitive."""
    email = email.strip().lower()
    if not email or "@" not in email:
        raise ActivationError("invalid_email", "That doesn't look like an email address.")
    if not device_id.strip():
        raise ActivationError("invalid_device", "The app didn't identify this Mac.")

    customer = db.get_customer_by_email(email)
    validity = subscriptions.validity_for(customer["id"]) if customer else None
    if customer is None or validity is None or not validity.entitled:
        reason = "no_subscription" if (customer is None or (validity and validity.status == "none")) else "subscription_ended"
        return {"sent": False, "reason": reason}

    if db.count_recent_activation_codes(email, minutes=60) >= MAX_CODES_PER_HOUR:
        raise ActivationError("rate_limited", "Too many codes requested for this address — wait an hour, or use a code already in your inbox.")

    code = f"{secrets.randbelow(1_000_000):06d}"
    db.create_activation_code(email=email, code_hash=_hash(code), device_id=device_id.strip(), ttl_minutes=config.ACTIVATION_CODE_TTL_MINUTES)
    try:
        email_sender.send_activation_code_email(to_email=email, code=code, device_name=device_name.strip())
    except email_sender.EmailSendError as e:
        raise ActivationError("email_failed", f"We couldn't send the code: {e}") from e
    return {"sent": True, "reason": "ok", "expires_in_minutes": config.ACTIVATION_CODE_TTL_MINUTES}


@dataclass(frozen=True)
class SignInResult:
    device_token: str
    entitlement_token: str
    validity: subscriptions.Validity
    customer_id: int
    device_row_id: int


def verify_code(*, email: str, code: str, device_id: str, device_name: str) -> SignInResult:
    email = email.strip().lower()
    device_id = device_id.strip()
    row = db.latest_activation_code(email, device_id)
    if row is None or _expired(row["expires_at"]):
        raise ActivationError("code_invalid", "That code has expired or was never sent — request a new one.")
    if row["attempts"] >= MAX_VERIFY_ATTEMPTS:
        raise ActivationError("code_invalid", "Too many wrong attempts — request a new code.")
    if not hmac.compare_digest(row["code_hash"], _hash(code.strip())):
        db.bump_activation_attempts(row["id"])
        raise ActivationError("code_wrong", "That code isn't right. Check the email and try again.")

    customer = db.get_customer_by_email(email)
    if customer is None:
        raise ActivationError("no_subscription", "There's no PiperStitch subscription for this email.")

    # Device limit: a Mac already signed in just refreshes its token.
    if not db.has_active_device(customer["id"], device_id) and len(db.list_active_devices(customer["id"])) >= config.MAX_DEVICES:
        raise ActivationError(
            "device_limit",
            f"This subscription is already signed in on {config.MAX_DEVICES} Macs. Sign one out from your account page ({config.PUBLIC_BASE_URL}/account) and try again.",
        )

    db.consume_activation_code(row["id"])
    device_token = secrets.token_urlsafe(32)
    device_row_id = db.create_device(customer_id=customer["id"], device_id=device_id, device_name=device_name.strip()[:120], token_hash=_hash(device_token))
    device_row = db.get_device(device_row_id)
    token, validity = subscriptions.issue_entitlement(customer_row=customer, device_row=device_row)
    if token is None:
        raise ActivationError("subscription_ended", "This subscription has ended. Resubscribe from the account page to keep using PiperStitch.")
    db.add_event(customer_id=customer["id"], subscription_id=validity.subscription_id, kind="device_signed_in", detail=f"Signed in on {device_name.strip() or 'a Mac'}.")
    return SignInResult(device_token=device_token, entitlement_token=token, validity=validity, customer_id=customer["id"], device_row_id=device_row_id)


def refresh(*, device_token: str) -> tuple[Optional[str], subscriptions.Validity, dict]:
    """The silent background refresh. Returns (token or None, validity,
    customer_summary). A revoked device raises so the app signs itself
    out instead of retrying forever."""
    device = db.get_device_by_token_hash(_hash(device_token))
    if device is None:
        raise ActivationError("device_revoked", "This Mac was signed out of the subscription. Sign in again to continue.")
    customer = db.get_customer(device["customer_id"])
    token, validity = subscriptions.issue_entitlement(customer_row=customer, device_row=device)
    if token is None:
        db.touch_device(device["id"], entitlement_until=None)
    return token, validity, {"email": customer["email"], "name": customer["name"]}


def sign_out(*, device_token: str) -> bool:
    device = db.get_device_by_token_hash(_hash(device_token))
    if device is None:
        return False
    db.revoke_device(device["id"])
    db.add_event(customer_id=device["customer_id"], subscription_id=None, kind="device_signed_out", detail=f"Signed out {device['device_name'] or 'a Mac'}.")
    return True


def device_for_token(device_token: str):
    return db.get_device_by_token_hash(_hash(device_token))


# ---------------------------------------------------------- account links ---


def create_account_link(customer_id: int) -> str:
    """A one-time URL to the self-service account page, emailed to the
    customer. Stored hashed like everything else here."""
    token = secrets.token_urlsafe(32)
    db.create_account_link(customer_id=customer_id, token_hash=_hash(token), ttl_minutes=config.ACCOUNT_LINK_TTL_MINUTES)
    return f"{config.PUBLIC_BASE_URL}/account/open?token={token}"


def resolve_account_link(token: str) -> Optional[int]:
    """Customer id for a live, unused link — or None. Consumes it."""
    row = db.get_account_link(_hash(token))
    if row is None or row["consumed_at"] is not None or _expired(row["expires_at"]):
        return None
    with db.connection() as conn:
        conn.execute("UPDATE account_links SET consumed_at = ? WHERE id = ?", (db.now_iso(), row["id"]))
    return row["customer_id"]
