"""The mailbox recruitment mail goes out of, owned by the admin.

Cold outreach does not belong on the same path as a customer's sign-in
code: Postmark's own terms allow only mail people asked for, and a single
complaint on a hundred cold sends is ten times their stated limit. So
recruitment can leave instead through a mailbox we own -- a Google
Workspace or Microsoft 365 account on the outreach domain -- and the rest
of the platform keeps using Postmark.

The settings live in the database rather than only in environment
variables so they can be changed, and tested, from the recruitment page
without a redeploy. The password is sealed with the same key that seals
partners' tax forms; environment variables remain as the fallback, so an
existing deployment keeps working untouched.

What this costs: a mailbox hands back no message id, so opens and clicks
stop being recorded for anything sent this way. Replies still reach the
platform as long as the reply-to stays pointed at Postmark's inbound
address -- which is why that field is here rather than assumed.
"""

from __future__ import annotations

import json
import smtplib
from typing import Optional

from . import config, db, documents

SETTING = "outreach_mailbox"
FIELDS = ("host", "port", "username", "from_email", "reply_to")


def _stored() -> Optional[dict]:
    raw = db.get_setting(SETTING)
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return None


def settings() -> dict:
    """What to send through: the admin's settings when they exist, the
    environment otherwise. The password is left sealed here; only
    `_password()` opens it, so it never rides along in a template."""
    saved = _stored()
    if saved:
        return {
            "host": saved.get("host", ""),
            "port": int(saved.get("port") or 587),
            "username": saved.get("username", ""),
            "from_email": saved.get("from_email", ""),
            "reply_to": saved.get("reply_to", ""),
            "source": "admin",
            "has_password": bool(saved.get("password")),
        }
    return {
        "host": config.PARTNER_OUTREACH_SMTP_HOST,
        "port": config.PARTNER_OUTREACH_SMTP_PORT,
        "username": config.PARTNER_OUTREACH_SMTP_USERNAME,
        "from_email": config.PARTNER_OUTREACH_FROM,
        "reply_to": config.PARTNER_OUTREACH_REPLY_TO,
        "source": "environment",
        "has_password": bool(config.PARTNER_OUTREACH_SMTP_PASSWORD),
    }


def _password() -> str:
    saved = _stored()
    if saved is None:
        return config.PARTNER_OUTREACH_SMTP_PASSWORD
    sealed = saved.get("password") or ""
    if not sealed:
        return ""
    try:
        return documents.open_(sealed).decode()
    except Exception:  # noqa: BLE001 - a key that no longer opens it must not crash a send
        return ""


def configured() -> bool:
    s = settings()
    return bool(s["host"] and s["username"] and s["from_email"] and (s["has_password"] or not s["host"]))


def save(*, host: str, port: int, username: str, password: str, from_email: str, reply_to: str) -> None:
    """A blank password keeps the one already stored: the form never shows
    it back, so an admin editing the reply-to should not have to retype a
    secret to avoid wiping it."""
    existing = _stored() or {}
    sealed = existing.get("password", "")
    if password:
        sealed = documents.seal(password.encode())
    db.set_setting(SETTING, json.dumps({
        "host": host.strip(), "port": int(port or 587), "username": username.strip(),
        "password": sealed, "from_email": from_email.strip(), "reply_to": reply_to.strip(),
    }))


def forget() -> None:
    """Back to Postmark, and to whatever the environment says."""
    db.set_setting(SETTING, "")


def connect() -> smtplib.SMTP:
    s = settings()
    if s["port"] == 465:
        smtp = smtplib.SMTP_SSL(s["host"], s["port"], timeout=20)
    else:
        smtp = smtplib.SMTP(s["host"], s["port"], timeout=20)
        smtp.starttls()
    smtp.login(s["username"], _password())
    return smtp


def check() -> str:
    """Open a connection and sign in, without sending anything. Returns ''
    when it worked, or what went wrong in words an admin can act on."""
    if not configured():
        return "Fill in the host, the username, the password and the sender first."
    try:
        with connect():
            return ""
    except smtplib.SMTPAuthenticationError:
        return ("The mailbox refused the sign-in. Google needs an App Password (and 2-Step Verification "
                "on the account); Microsoft 365 needs SMTP AUTH enabled for that mailbox.")
    except (smtplib.SMTPException, OSError) as e:
        return f"Couldn't reach {settings()['host']}: {e}"
