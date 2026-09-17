"""The web edition's sign-in, trial and account operations -- what the
Swift web server (repo: server/) calls on a browser's behalf. The Mac
app's counterpart is activation.py; the two differ in one deliberate
way: a Mac gets its free trial from the install (the clock runs on the
Mac, no account needed), while a browser can't be trusted to keep a
trial clock, so here the trial belongs to the *account* and starts the
first time an email is verified. Everything downstream -- validity,
Stripe, comps, the admin -- is the same code and the same tables.

Never called by a browser directly: the routes in main.py require the
WEB_API_KEY shared secret, and the web server holds the session token in
an HttpOnly cookie of its own."""

from __future__ import annotations

import hashlib
import re
import hmac
import json
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional
from urllib.parse import quote

from . import config, db, email_sender, emails, promotions, stripe_client, subscriptions
from .activation import MAX_CODES_PER_HOUR, MAX_VERIFY_ATTEMPTS, ActivationError

# activation_codes rows are keyed by (email, device_id); every browser
# shares this one pseudo-device so the newest code always wins, exactly
# like a single Mac requesting twice.
WEB_DEVICE_ID = "web"
TRIAL_NOTE = "Web free trial"
MAX_PROJECTS = 200
MAX_PROJECT_BYTES = 6 * 1024 * 1024


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds").replace("+00:00", "Z")


def _expired(iso: str) -> bool:
    return datetime.fromisoformat(iso.replace("Z", "+00:00")) <= _now()


# ------------------------------------------------------------- sign-in ---


def request_code(*, email: str, app: str = "core", flow: str = "signin") -> dict:
    """Emails a code to any plausible address -- unlike the Mac's
    request_code, an unknown email is welcome here: verifying it is how
    the trial starts. Rate limits are shared with the Mac path."""
    email = email.strip().lower()
    if not email or "@" not in email or "." not in email.rsplit("@", 1)[-1]:
        raise ActivationError("invalid_email", "That doesn't look like an email address.")
    if db.count_recent_activation_codes(email, minutes=60) >= MAX_CODES_PER_HOUR:
        raise ActivationError("rate_limited", "Too many codes requested for this address — wait an hour, or use a code already in your inbox.")
    code = f"{secrets.randbelow(1_000_000):06d}"
    code_row_id = db.create_activation_code(email=email, code_hash=_hash(code), device_id=WEB_DEVICE_ID, ttl_minutes=config.ACTIVATION_CODE_TTL_MINUTES)
    # The email's link lands in whichever app asked; a free-trial sign-up
    # (flow="trial", from the app's guided setup) gets the sign-up email,
    # whose link returns to that setup step rather than the app.
    signup = app == "core" and flow == "trial"
    base = f"{config.PROOFS_APP_URL}/signin" if app == "proofs" else f"{config.WEB_APP_URL}/"
    sign_in_url = f"{base}?{'trial=1&' if signup else ''}email={quote(email)}&code={code}"
    try:
        email_sender.send_activation_code_email(to_email=email, code=code, device_name="the web", sign_in_url=sign_in_url, signup=signup)
    except email_sender.EmailSendError as e:
        db.delete_activation_code(code_row_id)
        raise ActivationError("email_failed", f"We couldn't send the code: {e}") from e
    return {"sent": True, "expires_in_minutes": config.ACTIVATION_CODE_TTL_MINUTES}


HANDOFF_TTL_SECONDS = 120


def create_handoff(*, token: str, target: str) -> str:
    """A one-time code that lets the other app sign this customer in
    without a second email code. Two minutes, single use."""
    if target not in ("core", "proofs"):
        raise ActivationError("invalid_target", "Unknown handoff target.")
    session = _session(token)
    code = secrets.token_urlsafe(32)
    db.create_handoff(customer_id=session["customer_id"], code_hash=_hash(code), target=target, ttl_seconds=HANDOFF_TTL_SECONDS)
    return code


def redeem_handoff(*, code: str, user_agent: str = "") -> "WebSession":
    row = db.consume_handoff(_hash(code.strip()))
    if row is None:
        raise ActivationError("handoff_invalid", "That link has expired -- open the app again and try once more.")
    customer = db.get_customer(row["customer_id"])
    token = secrets.token_urlsafe(32)
    session_row_id = db.create_web_session(customer_id=customer["id"], token_hash=_hash(token), user_agent=user_agent)
    db.add_event(customer_id=customer["id"], subscription_id=None, kind="web_signed_in", detail=f"Signed in to {'PiperStitch Proofs' if row['target'] == 'proofs' else 'the web app'} from the other app.")
    return WebSession(token=token, customer_id=customer["id"], session_row_id=session_row_id)


@dataclass(frozen=True)
class WebSession:
    token: str
    customer_id: int
    session_row_id: int


def verify_code(*, email: str, code: str, user_agent: str = "") -> WebSession:
    email = email.strip().lower()
    row = db.latest_activation_code(email, WEB_DEVICE_ID)
    if row is None or _expired(row["expires_at"]):
        raise ActivationError("code_invalid", "That code has expired or was never sent — request a new one.")
    if row["attempts"] >= MAX_VERIFY_ATTEMPTS:
        raise ActivationError("code_invalid", "Too many wrong attempts — request a new code.")
    if not hmac.compare_digest(row["code_hash"], _hash(code.strip())):
        db.bump_activation_attempts(row["id"])
        raise ActivationError("code_wrong", "That code isn't right. Check the email and try again.")
    db.consume_activation_code(row["id"])

    customer = db.get_customer_by_email(email)
    if customer is None:
        # First contact. The name is a placeholder the customer can fix
        # at checkout; Stripe's name then flows back through the webhook.
        customer_id = db.upsert_customer(name=email.split("@", 1)[0].replace(".", " ").title(), email=email, source="web_trial")
        customer = db.get_customer(customer_id)
    _start_trial_if_first_visit(customer)
    _record_terms_acceptance(customer)

    token = secrets.token_urlsafe(32)
    session_row_id = db.create_web_session(customer_id=customer["id"], token_hash=_hash(token), user_agent=user_agent)
    db.add_event(customer_id=customer["id"], subscription_id=None, kind="web_signed_in", detail="Signed in on the web.")
    return WebSession(token=token, customer_id=customer["id"], session_row_id=session_row_id)


def _record_terms_acceptance(customer) -> None:
    """The sign-in form says "By continuing you accept the Terms and Privacy
    Policy" under both its buttons, so a verified code is the acceptance.
    Recorded once per Terms version: the first sign-in after a bump stamps
    the new version, later sign-ins leave that timestamp alone."""
    if customer["consent_terms_version"] == config.TERMS_VERSION:
        return
    db.record_terms_consent(customer["id"], config.TERMS_VERSION)
    db.add_event(customer_id=customer["id"], subscription_id=None, kind="terms_accepted", detail=f"Accepted Terms v{config.TERMS_VERSION} by signing in on the web.")


def _start_trial_if_first_visit(customer) -> Optional[int]:
    """One trial per email, ever: only an account with no subscription row
    of any kind (never trialed, never paid, never comped) gets one."""
    if db.best_subscription_for_customer(customer["id"]) is not None:
        return None
    now = _now()
    until = now + timedelta(days=config.TRIAL_DAYS)
    subscription_id = db.upsert_subscription(
        customer_id=customer["id"],
        stripe_subscription_id=None,
        stripe_customer_id=None,
        status="trialing",
        current_period_start=_iso(now),
        current_period_end=_iso(until),
        cancel_at_period_end=True,  # a trial never renews itself; it's replaced by a Stripe subscription
        canceled_at=None,
        ended_at=None,
        source="manual",
        amount_cents=0,
        notes=TRIAL_NOTE,
    )
    db.add_event(customer_id=customer["id"], subscription_id=subscription_id, kind="trial_started", detail=f"{config.TRIAL_DAYS}-day web trial through {_iso(until)[:10]}.")
    emails.enroll(customer["id"], "trial", start=now)
    return subscription_id


# --------------------------------------------------------------- state ---


def _session(token: str):
    row = db.get_web_session_by_token_hash(_hash(token))
    if row is None:
        raise ActivationError("session_revoked", "You were signed out. Sign in again to continue.")
    return row


def _expire_stale_trial(customer_id: int) -> None:
    """A trial row past its end still ranks as 'entitled status' in
    best_subscription_for_customer's ordering (harmless for validity,
    which checks the date, but noisy in the admin). Close it out."""
    sub = db.best_subscription_for_customer(customer_id)
    if sub is None or sub["status"] != "trialing" or sub["source"] != "manual" or sub["notes"] != TRIAL_NOTE:
        return
    if sub["current_period_end"] and _expired(sub["current_period_end"]):
        with db.connection() as conn:
            conn.execute("UPDATE subscriptions SET status = 'canceled', ended_at = ?, updated_at = ? WHERE id = ?", (db.now_iso(), db.now_iso(), sub["id"]))


def state(*, token: str) -> dict:
    """What the web server caches in its cookie: who this is and whether
    they may use the app right now. Cheap -- database only."""
    session = _session(token)
    db.touch_web_session(session["id"])
    db.touch_customer_activity(session["customer_id"])
    _expire_stale_trial(session["customer_id"])
    customer = db.get_customer(session["customer_id"])
    validity = subscriptions.validity_for(customer["id"])
    return {
        "customer_id": customer["id"],
        "email": customer["email"],
        "name": customer["name"],
        "status": validity.status,
        "entitled": validity.entitled,
        "valid_until": _iso(validity.valid_until) if validity.valid_until else None,
        "period_end": _iso(validity.period_end) if validity.period_end else None,
        "cancel_at_period_end": validity.cancel_at_period_end,
        "has_billing": bool(customer["stripe_customer_id"]),
        "price_cents": config.MONTHLY_PRICE_CENTS,
        "currency": config.CURRENCY,
        "trial_days": config.TRIAL_DAYS,
        # PiperStitch Proofs, the second product on this customer, so the
        # app can offer it and open it.
        "proofs": {**subscriptions.proofs_state(customer["id"]).as_dict(), "url": config.PROOFS_APP_URL},
    }


def sign_out(*, token: str) -> bool:
    row = db.get_web_session_by_token_hash(_hash(token))
    if row is None:
        return False
    db.revoke_web_session(row["id"])
    return True


# ------------------------------------------------------------- billing ---


def checkout_url(*, token: str, promo_code: str = "") -> str:
    """Starts Stripe Checkout for this account from inside the app. The
    trial-to-paid path is the normal one, so a trialing account is
    allowed through; an account already paying is sent to the portal. A
    promo code, if given, is validated here and applied to the session."""
    session = _session(token)
    customer = db.get_customer(session["customer_id"])
    validity = subscriptions.validity_for(customer["id"])
    if validity.entitled and validity.status in ("active", "past_due"):
        raise ActivationError("already_subscribed", "This account already has an active subscription — use Manage billing instead.")
    promotion = promotions.validate(promo_code, email=customer["email"]) if promo_code.strip() else None
    checkout = stripe_client.create_subscription_checkout(
        customer_name=customer["name"], customer_email=customer["email"], customer_id=customer["id"],
        success_url=f"{config.WEB_APP_URL}/?subscribed=1", cancel_url=f"{config.WEB_APP_URL}/?subscribed=0", promotion=promotion,
    )
    db.create_checkout_session(stripe_session_id=checkout.id, customer_name=customer["name"], customer_email=customer["email"], customer_id=customer["id"],
                               promotion_id=promotion["id"] if promotion else None)
    return checkout.url


def billing_portal_url(*, token: str) -> Optional[str]:
    session = _session(token)
    customer = db.get_customer(session["customer_id"])
    if not customer["stripe_customer_id"]:
        return None
    return stripe_client.create_billing_portal_session(stripe_customer_id=customer["stripe_customer_id"], return_url=f"{config.WEB_APP_URL}/").url


# ------------------------------------------------------------- proofs ---


def proofs_state(*, token: str) -> dict:
    session = _session(token)
    return subscriptions.proofs_state(session["customer_id"]).as_dict()


def proofs_use(*, token: str, proof_ref: str) -> dict:
    session = _session(token)
    if not proof_ref or len(proof_ref) > 64:
        raise ActivationError("invalid_proof", "That proof reference isn't valid.")
    return subscriptions.record_proof_use(session["customer_id"], f"{session['customer_id']}:{proof_ref}").as_dict()


def proofs_checkout_url(*, token: str, success_url: str = "", cancel_url: str = "") -> str:
    """Stripe Checkout for the Proofs plan. Same customer record, its own
    subscription; the app's own plan is untouched either way."""
    session = _session(token)
    customer = db.get_customer(session["customer_id"])
    state = subscriptions.proofs_state(customer["id"])
    if state.subscribed and state.status in ("active", "past_due"):
        raise ActivationError("already_subscribed", "This account already has an active Proofs subscription — use Manage billing instead.")
    if not config.STRIPE_PRICE_PROOFS_MONTHLY:
        raise ActivationError("not_configured", "Proofs billing isn't set up on this server yet (STRIPE_PRICE_PROOFS_MONTHLY).")
    checkout = stripe_client.create_subscription_checkout(
        customer_name=customer["name"], customer_email=customer["email"], customer_id=customer["id"], product="proofs",
        success_url=success_url or f"{config.PROOFS_APP_URL}/settings?subscribed=1", cancel_url=cancel_url or f"{config.PROOFS_APP_URL}/settings?subscribed=0",
    )
    db.create_checkout_session(stripe_session_id=checkout.id, customer_name=customer["name"], customer_email=customer["email"], customer_id=customer["id"])
    return checkout.url


def proofs_billing_portal_url(*, token: str, return_url: str = "") -> Optional[str]:
    session = _session(token)
    customer = db.get_customer(session["customer_id"])
    if not customer["stripe_customer_id"]:
        return None
    return stripe_client.create_billing_portal_session(stripe_customer_id=customer["stripe_customer_id"], return_url=return_url or f"{config.PROOFS_APP_URL}/settings").url


# ------------------------------------------------------------ projects ---


def list_projects(*, token: str) -> list[dict]:
    session = _session(token)
    return [dict(row) for row in db.list_projects(session["customer_id"])]


def get_project(*, token: str, project_id: str) -> Optional[dict]:
    session = _session(token)
    row = db.get_project(session["customer_id"], project_id)
    if row is None:
        return None
    out = dict(row)
    out["document"] = json.loads(out["document"])
    return out


MAX_PREFERENCES_BYTES = 256 * 1024


def get_preferences(*, token: str) -> dict:
    session = _session(token)
    row = db.get_preferences(session["customer_id"])
    if row is None:
        return {"preferences": None, "updated_at": None}
    return {"preferences": json.loads(row["preferences"]), "updated_at": row["updated_at"]}


def save_preferences(*, token: str, preferences: dict) -> dict:
    session = _session(token)
    encoded = json.dumps(preferences, separators=(",", ":"))
    if len(encoded) > MAX_PREFERENCES_BYTES:
        raise ActivationError("preferences_too_large", "Those preferences are too large to save.")
    return {"updated_at": db.save_preferences(session["customer_id"], encoded)}


def save_project(*, token: str, project_id: str, name: str, document: dict) -> dict:
    session = _session(token)
    if not project_id or len(project_id) > 64 or not project_id.replace("-", "").isalnum():
        raise ActivationError("invalid_project", "That project id isn't valid.")
    encoded = json.dumps(document, separators=(",", ":"))
    if len(encoded) > MAX_PROJECT_BYTES:
        raise ActivationError("project_too_large", "This project is too large to save.")
    if db.get_project(session["customer_id"], project_id) is None and db.count_projects(session["customer_id"]) >= MAX_PROJECTS:
        raise ActivationError("project_limit", f"You've reached the limit of {MAX_PROJECTS} saved projects — delete one to save another.")
    try:
        created = db.save_project(
            customer_id=session["customer_id"], project_id=project_id, name=(name.strip() or "Untitled")[:120], document=encoded,
            width_mm=float(document.get("physicalWidthMM") or 0), height_mm=float(document.get("physicalHeightMM") or 0),
            object_count=len(document.get("objects") or []),
        )
    except PermissionError:
        raise ActivationError("invalid_project", "That project id isn't available.")
    return {"id": project_id, "created": created}


def delete_project(*, token: str, project_id: str) -> bool:
    session = _session(token)
    return db.delete_project(session["customer_id"], project_id)


# -------------------------------------------------------------- feedback ---

# Generous enough for a real screenshot-sized PNG (a few hundred KB to
# low single-digit MB) but not for someone trying to stuff arbitrary
# files through this the way MAX_PROJECT_BYTES guards project saves.
MAX_FEEDBACK_IMAGE_BASE64_CHARS = 8 * 1024 * 1024


def submit_feedback(*, token: str, note: str, design_name: str, stitch_count: int,
                     original_image_base64: Optional[str], original_image_type: str,
                     digitized_image_base64: str, digitized_image_type: str) -> dict:
    """"Send feedback" from the web editor: the original artwork and a
    picture of the digitized result, stored for review and immediately
    acknowledged by email (see send_feedback_received_email) -- actually
    *using* the feedback and telling the customer so is a separate admin
    action (main.py's /admin/feedback/{id}/review), since nobody has
    looked at it yet at submission time."""
    session = _session(token)
    customer = db.get_customer(session["customer_id"])
    if not digitized_image_base64 or len(digitized_image_base64) > MAX_FEEDBACK_IMAGE_BASE64_CHARS:
        raise ActivationError("invalid_feedback", "That image is missing or too large to send.")
    if original_image_base64 and len(original_image_base64) > MAX_FEEDBACK_IMAGE_BASE64_CHARS:
        raise ActivationError("invalid_feedback", "That image is missing or too large to send.")
    feedback_id = db.add_feedback(
        customer_id=customer["id"], customer_email=customer["email"], design_name=(design_name or "")[:200], stitch_count=max(0, int(stitch_count)),
        note=(note or "")[:4000],
        original_image_data=original_image_base64 or None, original_image_type=original_image_type or "image/png",
        digitized_image_data=digitized_image_base64, digitized_image_type=digitized_image_type or "image/png",
    )
    try:
        email_sender.send_feedback_received_email(to_email=customer["email"], customer_name=customer["name"])
    except email_sender.EmailSendError as e:
        log.warning("Feedback %s saved but the thank-you email failed: %s", feedback_id, e)
    return {"id": feedback_id}


# --------------------------------------------------------------- profile ---


def update_name(*, token: str, name: str) -> dict:
    session = _session(token)
    if not name.strip():
        raise ActivationError("invalid_name", "Enter your name.")
    db.update_customer_name(session["customer_id"], name)
    return state(token=token)


# ------------------------------------------------------------ send a file ---

MAX_SENDS_PER_DAY = 30
MAX_FILE_BYTES = 5 * 1024 * 1024
ALLOWED_EXTENSIONS = {"dst", "pes", "jef", "exp", "vp3"}


def send_file(*, token: str, to_email: str, filename: str, data: bytes, message: str = "", design_name: str = "") -> None:
    """The Send button: emails the finished machine file to someone on
    the customer's behalf, from our address with reply-to the customer.
    Capped per day so a signed-in account can't become a spam relay."""
    session = _session(token)
    customer = db.get_customer(session["customer_id"])
    to_email = to_email.strip().lower()
    if "@" not in to_email or "." not in to_email.rsplit("@", 1)[-1]:
        raise ActivationError("invalid_email", "That doesn't look like an email address.")
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if ext not in ALLOWED_EXTENSIONS:
        raise ActivationError("invalid_file", "Only embroidery files (DST, PES, JEF, EXP, VP3) can be sent.")
    if not data or len(data) > MAX_FILE_BYTES:
        raise ActivationError("invalid_file", "That file is empty or too large to email.")
    if db.count_sent_files(customer["id"]) >= MAX_SENDS_PER_DAY:
        raise ActivationError("rate_limited", f"You've sent {MAX_SENDS_PER_DAY} files today — that's the daily limit. Try again tomorrow, or download the file and attach it yourself.")
    safe_name = re.sub(r"[^A-Za-z0-9._ -]+", "_", filename)[:80]
    try:
        email_sender.send_file_email(to_email=to_email, sender_name=customer["name"], sender_email=customer["email"], filename=safe_name, data=data, message=message[:2000], design_name=design_name)
    except email_sender.EmailSendError as e:
        raise ActivationError("email_failed", f"We couldn't send it: {e}") from e
    db.record_sent_file(customer_id=customer["id"], to_email=to_email, filename=safe_name, size_bytes=len(data))
    db.add_event(customer_id=customer["id"], subscription_id=None, kind="file_sent", detail=f"Sent {safe_name} to {to_email}.")
