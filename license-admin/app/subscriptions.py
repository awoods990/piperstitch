"""The one place that turns "what Stripe said" (or "what the admin
clicked") into a subscription record, and a subscription record into
"may this Mac run PiperStitch right now, and until when". The Stripe
webhook, the admin's comp/cancel buttons, and the app's entitlement
endpoint all converge here — the subscription-world counterpart of the
Amerus License Admin's issuance.py.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional

import stripe

from . import config, db, email_sender, emails, entitlement, finance, promotions

log = logging.getLogger("license_admin.subscriptions")


# --------------------------------------------------------------- helpers ---


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _aware(value: Optional[str]) -> Optional[datetime]:
    dt = db.parse_iso(value)
    return dt.replace(tzinfo=timezone.utc) if dt else None


def _to_iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _period_end_from_stripe(sub: dict) -> Optional[int]:
    """Stripe moved current_period_end from the subscription onto its
    items in the 2025-03-31 API version; accept either shape."""
    if sub.get("current_period_end") is not None:
        return sub["current_period_end"]
    items = (sub.get("items") or {}).get("data") or []
    return items[0].get("current_period_end") if items else None


def _period_start_from_stripe(sub: dict) -> Optional[int]:
    if sub.get("current_period_start") is not None:
        return sub["current_period_start"]
    items = (sub.get("items") or {}).get("data") or []
    return items[0].get("current_period_start") if items else None


def _amount_from_stripe(sub: dict) -> Optional[int]:
    items = (sub.get("items") or {}).get("data") or []
    if not items:
        return None
    price = items[0].get("price") or {}
    return price.get("unit_amount")


def _try_email(send, **kwargs) -> Optional[str]:
    """Email is best-effort everywhere in this module: a Stripe webhook
    must be acknowledged even if SMTP is down, and the subscription
    record must be updated regardless. Returns the error text, if any."""
    try:
        send(**kwargs)
        return None
    except email_sender.EmailSendError as e:
        log.error("Email send failed (%s): %s", send.__name__, e)
        return str(e)


# --------------------------------------------------- customer resolution ---


def resolve_customer_for_stripe(sub: dict, *, email_hint: str = "", name_hint: str = "") -> int:
    """Finds (or creates) our customer row for a Stripe subscription, in
    order of confidence: the customer_id we put in the subscription's
    metadata at checkout → the Stripe customer id we've seen before →
    the email. Creating one here is the safety net for a subscription
    started some way this service didn't initiate (e.g. a Payment Link
    made in the Stripe Dashboard)."""
    metadata = sub.get("metadata") or {}
    stripe_customer_id = sub.get("customer") if isinstance(sub.get("customer"), str) else (sub.get("customer") or {}).get("id")

    customer = None
    if metadata.get("customer_id", "").isdigit():
        customer = db.get_customer(int(metadata["customer_id"]))
    if customer is None and stripe_customer_id:
        customer = db.get_customer_by_stripe_id(stripe_customer_id)
    email = (email_hint or metadata.get("customer_email") or "").strip().lower()
    if customer is None and email:
        customer = db.get_customer_by_email(email)
    if customer is None:
        if not email and stripe_customer_id:
            try:
                remote = stripe.Customer.retrieve(stripe_customer_id)
                email = (remote.get("email") or "").strip().lower()
                name_hint = name_hint or (remote.get("name") or "")
            except stripe.error.StripeError as e:
                log.warning("Could not look up Stripe customer %s: %s", stripe_customer_id, e)
        if not email:
            raise ValueError(f"Stripe subscription {sub.get('id')} has no resolvable customer email.")
        customer_id = db.upsert_customer(name=name_hint or email, email=email, source="stripe")
        customer = db.get_customer(customer_id)

    if stripe_customer_id and customer["stripe_customer_id"] != stripe_customer_id:
        db.set_stripe_customer_id(customer["id"], stripe_customer_id)
    return customer["id"]


# ------------------------------------------------------ syncing from Stripe ---


@dataclass(frozen=True)
class SyncResult:
    subscription_id: int
    customer_id: int
    created: bool
    kinds: tuple[str, ...]  # event kinds recorded, for tests/logging


def sync_from_stripe(sub: dict, *, stripe_event_id: Optional[str] = None, email_hint: str = "", name_hint: str = "") -> SyncResult:
    """Mirrors one Stripe subscription object into the database and
    records what changed as timeline events. Idempotent: replaying the
    same object is a no-op beyond the upsert."""
    customer_id = resolve_customer_for_stripe(sub, email_hint=email_hint, name_hint=name_hint)
    stripe_customer_id = sub.get("customer") if isinstance(sub.get("customer"), str) else (sub.get("customer") or {}).get("id")
    previous = db.get_subscription_by_stripe_id(sub["id"])

    status = sub.get("status", "active")
    period_end = db.iso_from_timestamp(_period_end_from_stripe(sub))
    subscription_id = db.upsert_subscription(
        customer_id=customer_id,
        stripe_subscription_id=sub["id"],
        stripe_customer_id=stripe_customer_id,
        status=status,
        current_period_start=db.iso_from_timestamp(_period_start_from_stripe(sub)),
        current_period_end=period_end,
        cancel_at_period_end=bool(sub.get("cancel_at_period_end")),
        canceled_at=db.iso_from_timestamp(sub.get("canceled_at")),
        ended_at=db.iso_from_timestamp(sub.get("ended_at")),
        source="stripe",
        amount_cents=_amount_from_stripe(sub),
    )

    kinds: list[str] = []
    customer = db.get_customer(customer_id)
    if previous is None:
        kinds.append("created")
        db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="created", detail=f"Subscription started ({status}).", stripe_event_id=stripe_event_id)
        promotions.attribute_subscription(sub, subscription_id=subscription_id, customer_id=customer_id)
        if status in db.ENTITLED_STATUSES:
            _try_email(email_sender.send_welcome_email, to_email=customer["email"], customer_name=customer["name"])
            emails.skip_pending(customer_id, "trial", "subscribed")
            emails.enroll(customer_id, "subscriber")
    else:
        if period_end and previous["current_period_end"] and period_end > previous["current_period_end"] and status in ("active", "trialing"):
            kinds.append("renewed")
            db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="renewed", detail=f"Renewed through {period_end[:10]}.", stripe_event_id=stripe_event_id)
        if status != previous["status"]:
            kinds.append("status_changed")
            db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="status_changed", detail=f"{previous['status']} → {status}.", stripe_event_id=stripe_event_id)
            if status in ("canceled", "unpaid", "incomplete_expired"):
                db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="ended", detail="Access ended.", stripe_event_id=stripe_event_id)
                emails.skip_pending(customer_id, "subscriber", "subscription ended")
        now_cancelling = bool(sub.get("cancel_at_period_end"))
        if now_cancelling != bool(previous["cancel_at_period_end"]):
            if now_cancelling:
                kinds.append("cancel_scheduled")
                ends_on = (period_end or "")[:10]
                db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="cancel_scheduled", detail=f"Will end on {ends_on}.", stripe_event_id=stripe_event_id)
                _try_email(email_sender.send_cancellation_scheduled_email, to_email=customer["email"], customer_name=customer["name"], ends_on=ends_on, account_url=f"{config.PUBLIC_BASE_URL}/account")
            else:
                kinds.append("cancel_unscheduled")
                db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="cancel_unscheduled", detail="Cancellation reversed — subscription continues.", stripe_event_id=stripe_event_id)

    return SyncResult(subscription_id=subscription_id, customer_id=customer_id, created=previous is None, kinds=tuple(kinds))


def record_invoice(invoice: dict, *, paid: bool, stripe_event_id: Optional[str] = None) -> None:
    """invoice.paid / invoice.payment_failed. Ties the money to the
    customer and subscription, and on a failure emails a heads-up."""
    stripe_sub_id = invoice.get("subscription") if isinstance(invoice.get("subscription"), str) else (invoice.get("subscription") or {}).get("id")
    if not stripe_sub_id:
        # Newer API versions put it under parent.subscription_details.
        stripe_sub_id = ((invoice.get("parent") or {}).get("subscription_details") or {}).get("subscription")
    subscription = db.get_subscription_by_stripe_id(stripe_sub_id) if stripe_sub_id else None
    customer_id = subscription["customer_id"] if subscription else None
    if customer_id is None:
        stripe_customer_id = invoice.get("customer") if isinstance(invoice.get("customer"), str) else (invoice.get("customer") or {}).get("id")
        by_stripe = db.get_customer_by_stripe_id(stripe_customer_id) if stripe_customer_id else None
        by_email = db.get_customer_by_email(invoice.get("customer_email") or "") if invoice.get("customer_email") else None
        customer_id = (by_stripe or by_email or {"id": None})["id"]

    amount = invoice.get("amount_paid") if paid else invoice.get("amount_due")
    paid_at = db.iso_from_timestamp(((invoice.get("status_transitions") or {}).get("paid_at")) or invoice.get("created")) if paid else None
    payment_intent = invoice.get("payment_intent") if isinstance(invoice.get("payment_intent"), str) else None
    inserted = db.record_payment(
        customer_id=customer_id,
        subscription_id=subscription["id"] if subscription else None,
        stripe_invoice_id=invoice.get("id"),
        stripe_payment_intent=payment_intent,
        amount_cents=int(amount or 0),
        currency=invoice.get("currency") or config.CURRENCY,
        status="paid" if paid else "failed",
        paid_at=paid_at,
    )
    if inserted is None:
        return  # already recorded — Stripe retried, or we saw it via another event

    if paid:
        db.add_event(customer_id=customer_id, subscription_id=subscription["id"] if subscription else None, kind="payment", detail=f"Paid ${int(amount or 0) / 100:.2f}.", stripe_event_id=stripe_event_id)
        finance.record_fee_for_invoice(payment_id=inserted, invoice=invoice, gross_cents=int(amount or 0))
        promotions.record_share_for_payment(payment_id=inserted, subscription_row=subscription, customer_id=customer_id, gross_cents=int(amount or 0), invoice=invoice)
    else:
        db.add_event(customer_id=customer_id, subscription_id=subscription["id"] if subscription else None, kind="payment_failed", detail=f"Charge of ${int(amount or 0) / 100:.2f} failed.", stripe_event_id=stripe_event_id)
        if customer_id is not None:
            customer = db.get_customer(customer_id)
            _try_email(email_sender.send_payment_failed_email, to_email=customer["email"], customer_name=customer["name"], account_url=f"{config.PUBLIC_BASE_URL}/account")


# ------------------------------------------------------------ admin actions ---


def grant_comp(*, customer_id: int, months: int = 0, until: Optional[datetime] = None, note: str = "", send_email: bool = True) -> tuple[int, Optional[str]]:
    """Complimentary access with no Stripe involvement — a review copy, a
    support make-good, a friend. Returns (subscription_id, email_error)."""
    if until is None:
        until = _utcnow() + timedelta(days=30 * max(1, months))
    subscription_id = db.upsert_subscription(
        customer_id=customer_id,
        stripe_subscription_id=None,
        stripe_customer_id=None,
        status="comp",
        current_period_start=_to_iso(_utcnow()),
        current_period_end=_to_iso(until),
        cancel_at_period_end=True,  # a comp never renews itself
        canceled_at=None,
        ended_at=None,
        source="manual",
        amount_cents=0,
        notes=note,
    )
    db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="comp_granted", detail=f"Complimentary access through {_to_iso(until)[:10]}. {note}".strip())
    customer = db.get_customer(customer_id)
    error = None
    if send_email:
        error = _try_email(email_sender.send_comp_email, to_email=customer["email"], customer_name=customer["name"], until=_to_iso(until)[:10], note=note)
    return subscription_id, error


def cancel(subscription_row, *, at_period_end: bool) -> Optional[str]:
    """Admin-initiated cancel. For a Stripe subscription this asks Stripe,
    and the webhook echo updates our record (we also update it here so
    the admin sees the change immediately). Returns an error string, or
    None on success."""
    if subscription_row["source"] == "stripe" and subscription_row["stripe_subscription_id"]:
        try:
            updated = stripe_client_cancel(subscription_row["stripe_subscription_id"], at_period_end=at_period_end)
        except stripe.error.StripeError as e:
            return f"Stripe refused the cancellation: {e.user_message or e}"
        sync_from_stripe(dict(updated))
        return None
    # A comp: nothing on Stripe's side to cancel.
    now = _to_iso(_utcnow())
    if at_period_end:
        db.update_subscription_status(subscription_row["id"], status=subscription_row["status"], cancel_at_period_end=True)
        db.add_event(customer_id=subscription_row["customer_id"], subscription_id=subscription_row["id"], kind="cancel_scheduled", detail="Comp will not be extended.")
    else:
        db.update_subscription_status(subscription_row["id"], status="canceled", ended_at=now, canceled_at=now)
        db.add_event(customer_id=subscription_row["customer_id"], subscription_id=subscription_row["id"], kind="ended", detail="Complimentary access ended by admin.")
    return None


def reactivate(subscription_row) -> Optional[str]:
    if subscription_row["source"] == "stripe" and subscription_row["stripe_subscription_id"]:
        try:
            from . import stripe_client

            updated = stripe_client.reactivate_subscription(subscription_row["stripe_subscription_id"])
        except stripe.error.StripeError as e:
            return f"Stripe refused: {e.user_message or e}"
        sync_from_stripe(dict(updated))
        return None
    db.update_subscription_status(subscription_row["id"], status=subscription_row["status"], cancel_at_period_end=False)
    return None


def stripe_client_cancel(stripe_subscription_id: str, *, at_period_end: bool):
    from . import stripe_client

    return stripe_client.cancel_subscription(stripe_subscription_id, at_period_end=at_period_end)


def extend_comp(subscription_row, *, until: datetime) -> None:
    db.extend_subscription(subscription_row["id"], current_period_end=_to_iso(until))
    db.add_event(customer_id=subscription_row["customer_id"], subscription_id=subscription_row["id"], kind="comp_extended", detail=f"Extended through {_to_iso(until)[:10]}.")


# ----------------------------------------------------------- entitlement ---


@dataclass(frozen=True)
class Validity:
    entitled: bool
    status: str  # what the app should display: 'active' | 'trialing' | 'past_due' | 'comp' | 'none' | 'ended'
    valid_until: Optional[datetime]
    period_end: Optional[datetime]
    cancel_at_period_end: bool
    subscription_id: Optional[int]


def validity_for(customer_id: int, *, now: Optional[datetime] = None) -> Validity:
    """Decides, from the database alone (never a live Stripe call — the
    app's refresh must be cheap and must work while Stripe is having a
    bad day), whether this customer is entitled right now and how long
    the next token may last.

    The token's expiry is the earlier of: the paid period's end plus the
    grace window, and now plus the hard ceiling. So an active monthly
    subscriber gets a token good for ~30 days at most, refreshed silently
    every launch; a cancelled one gets nothing new once the period ends;
    a past-due one keeps working through the grace days while Stripe
    retries the card."""
    now = now or _utcnow()
    sub = db.best_subscription_for_customer(customer_id)
    if sub is None:
        return Validity(False, "none", None, None, False, None)

    period_end = _aware(sub["current_period_end"])
    cancelling = bool(sub["cancel_at_period_end"])
    if sub["status"] not in db.ENTITLED_STATUSES:
        return Validity(False, "ended", None, period_end, cancelling, sub["id"])

    ceiling = now + timedelta(days=config.ENTITLEMENT_MAX_DAYS)
    if period_end is None:
        valid_until = ceiling
    else:
        valid_until = min(period_end + timedelta(days=config.ENTITLEMENT_GRACE_DAYS), ceiling)
        if sub["status"] == "comp" or cancelling:
            # A comp, or a subscription the customer has chosen to end,
            # gets no grace beyond the date they were told access ends.
            valid_until = min(period_end, ceiling)
    if valid_until <= now:
        return Validity(False, "ended", None, period_end, cancelling, sub["id"])
    return Validity(True, sub["status"], valid_until, period_end, cancelling, sub["id"])


def issue_entitlement(*, customer_row, device_row, now: Optional[datetime] = None) -> tuple[Optional[str], Validity]:
    """Signs a token for one device if the customer is entitled. Returns
    (token or None, validity) — the route turns a None into a clear
    'subscription ended' response rather than an error."""
    validity = validity_for(customer_row["id"], now=now)
    if not validity.entitled or validity.valid_until is None:
        return None, validity
    token = entitlement.sign(
        config.PIPERSTITCH_LICENSE_PRIVATE_KEY,
        customer_id=customer_row["id"],
        device_id=device_row["device_id"],
        email=customer_row["email"],
        status=validity.status,
        expires_at=validity.valid_until,
        period_end=validity.period_end,
        cancel_at_period_end=validity.cancel_at_period_end,
        issued_at=now,
    )
    db.touch_device(device_row["id"], entitlement_until=_to_iso(validity.valid_until))
    return token, validity
