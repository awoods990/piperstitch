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


def product_from_stripe(sub: dict) -> str:
    """Which product a Stripe subscription is for: the metadata we set at
    checkout, else the price id, else the app."""
    metadata = sub.get("metadata") or {}
    if metadata.get("product") in ("core", "proofs"):
        return metadata["product"]
    items = (sub.get("items") or {}).get("data") or []
    for item in items:
        price = item.get("price") or {}
        price_id = price.get("id") if isinstance(price, dict) else price
        if price_id and price_id == config.STRIPE_PRICE_PROOFS_MONTHLY:
            return "proofs"
    return "core"


def _amount_from_stripe(sub: dict) -> Optional[int]:
    items = (sub.get("items") or {}).get("data") or []
    if not items:
        return None
    price = items[0].get("price") or {}
    return price.get("unit_amount")


def _try_sequences(fn, *args) -> None:
    """Sequence bookkeeping is best-effort for the same reason email is:
    a webhook or a proof send must succeed even if the drip tables are
    unhappy."""
    try:
        fn(*args)
    except Exception as e:  # noqa: BLE001
        log.exception("Sequence update failed (%s): %s", getattr(fn, "__name__", fn), e)


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
    product = product_from_stripe(sub)
    period_end = db.iso_from_timestamp(_period_end_from_stripe(sub))
    subscription_id = db.upsert_subscription(
        product=product,
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
        if status in db.ENTITLED_STATUSES and product == "proofs":
            _try_email(email_sender.send_proofs_welcome_email, to_email=customer["email"], customer_name=customer["name"])
            _try_sequences(emails.place_in_proofs_sequence, customer_id)
        elif status in db.ENTITLED_STATUSES:
            _try_email(email_sender.send_welcome_email, to_email=customer["email"], customer_name=customer["name"])
            emails.skip_pending(customer_id, "trial", "subscribed")
            emails.skip_pending(customer_id, "lapsed", "subscribed")
            emails.skip_pending(customer_id, "cancelled", "resubscribed")
            emails.enroll(customer_id, "subscriber")
            _try_sequences(emails.place_in_proofs_sequence, customer_id)
    else:
        if period_end and previous["current_period_end"] and period_end > previous["current_period_end"] and status in ("active", "trialing"):
            kinds.append("renewed")
            db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="renewed", detail=f"Renewed through {period_end[:10]}.", stripe_event_id=stripe_event_id)
        if status != previous["status"]:
            kinds.append("status_changed")
            db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="status_changed", detail=f"{previous['status']} → {status}.", stripe_event_id=stripe_event_id)
            if status in ("canceled", "unpaid", "incomplete_expired"):
                db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="ended", detail="Access ended.", stripe_event_id=stripe_event_id)
                if product == "core":
                    emails.skip_pending(customer_id, "subscriber", "subscription ended")
                ended_at = db.iso_from_timestamp(sub.get("ended_at") or sub.get("canceled_at"))
                promotions.on_subscription_ended(customer_id, at=_aware(ended_at) or _utcnow(), stripe_event_id=stripe_event_id or "")
            else:
                promotions.recheck_reinstatement((db.redemption_for_customer(customer_id) or {"promoter_id": None})["promoter_id"])
            _try_sequences(emails.place_in_proofs_sequence, customer_id)
        now_cancelling = bool(sub.get("cancel_at_period_end"))
        if now_cancelling != bool(previous["cancel_at_period_end"]):
            if now_cancelling:
                kinds.append("cancel_scheduled")
                ends_on = (period_end or "")[:10]
                db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="cancel_scheduled", detail=f"Will end on {ends_on}.", stripe_event_id=stripe_event_id)
                _try_email(email_sender.send_cancellation_scheduled_email, to_email=customer["email"], customer_name=customer["name"], ends_on=ends_on, account_url=f"{config.PUBLIC_BASE_URL}/account")
                if product == "core":
                    _try_sequences(emails.enroll, customer_id, "cancelled")
            else:
                kinds.append("cancel_unscheduled")
                db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="cancel_unscheduled", detail="Cancellation reversed — subscription continues.", stripe_event_id=stripe_event_id)
                if product == "core":
                    emails.skip_pending(customer_id, "cancelled", "cancellation reversed")

    return SyncResult(subscription_id=subscription_id, customer_id=customer_id, created=previous is None, kinds=tuple(kinds))


def record_refund(charge: dict, *, stripe_event_id: Optional[str] = None, dispute: bool = False) -> list[int]:
    """charge.refunded / charge.dispute.created: reverse the promoter's
    share for the refunded portion of that charge's invoice (R6)."""
    invoice_id = charge.get("invoice") if isinstance(charge.get("invoice"), str) else (charge.get("invoice") or {}).get("id")
    amount = int(charge.get("amount_refunded") or charge.get("amount") or 0) if not dispute else int(charge.get("amount") or 0)
    when = db.iso_from_timestamp(charge.get("created"))
    return promotions.reverse_for_refund(stripe_invoice_id=invoice_id, refunded_cents=amount, at=_aware(when) or _utcnow(),
                                         reason="chargeback" if dispute else "refund", event_ref=stripe_event_id or "")


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


def grant_comp(*, customer_id: int, months: int = 0, until: Optional[datetime] = None, note: str = "", send_email: bool = True,
               product: str = "core") -> tuple[int, Optional[str]]:
    """Complimentary access with no Stripe involvement — a review copy, a
    support make-good, a friend. Returns (subscription_id, email_error)."""
    if until is None:
        until = _utcnow() + timedelta(days=30 * max(1, months))
    subscription_id = db.upsert_subscription(
        product=product,
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
    label = "Complimentary PiperStitch Proofs" if product == "proofs" else "Complimentary access"
    db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="comp_granted", detail=f"{label} through {_to_iso(until)[:10]}. {note}".strip())
    customer = db.get_customer(customer_id)
    error = None
    if send_email and product == "core":
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


def validity_for(customer_id: int, *, now: Optional[datetime] = None, product: str = "core") -> Validity:
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
    sub = db.best_subscription_for_customer(customer_id, product)
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


# ------------------------------------------------------ PiperStitch Proofs ---


@dataclass(frozen=True)
class ProofsState:
    """What PiperStitch Proofs needs to know about a customer: whether
    they're subscribed, and if not, how many free proofs are left."""
    subscribed: bool
    status: str                 # active | trialing | past_due | comp | none | ended
    free_granted: int
    free_used: int
    period_end: Optional[datetime]
    cancel_at_period_end: bool
    has_billing: bool           # a Stripe customer exists, so the portal works

    @property
    def free_left(self) -> int:
        return max(0, self.free_granted - self.free_used)

    @property
    def can_send(self) -> bool:
        return self.subscribed or self.free_left > 0

    def as_dict(self) -> dict:
        return {"subscribed": self.subscribed, "status": self.status, "free_granted": self.free_granted, "free_used": self.free_used,
                "free_left": self.free_left, "can_send": self.can_send,
                "period_end": _to_iso(self.period_end) if self.period_end else None, "cancel_at_period_end": self.cancel_at_period_end,
                "has_billing": self.has_billing, "price_cents": config.PROOFS_MONTHLY_PRICE_CENTS}


def proofs_state(customer_id: int, *, now: Optional[datetime] = None) -> ProofsState:
    customer = db.get_customer(customer_id)
    validity = validity_for(customer_id, now=now, product="proofs")
    granted = config.PROOFS_FREE_PROOFS + int(customer["proofs_free_extra"] or 0)
    return ProofsState(subscribed=validity.entitled, status=validity.status, free_granted=granted, free_used=db.count_proofs_used(customer_id),
                       period_end=validity.period_end, cancel_at_period_end=validity.cancel_at_period_end, has_billing=bool(customer["stripe_customer_id"]))


def record_proof_use(customer_id: int, proof_ref: str) -> ProofsState:
    """Counts one sent proof against the free allowance (idempotent per
    proof). Subscribers aren't counted -- there's nothing to run down."""
    state = proofs_state(customer_id)
    if not state.subscribed:
        if not state.can_send:
            from .activation import ActivationError
            raise ActivationError("proofs_exhausted", f"All {state.free_granted} free proofs have been used -- subscribe to PiperStitch Proofs to keep sending.")
        if db.record_proof_use(customer_id, proof_ref):
            db.add_event(customer_id=customer_id, subscription_id=None, kind="proof_sent", detail=f"Free proof {state.free_used + 1} of {state.free_granted} sent (Proofs).")
            # A first proof moves them from "meet Proofs" to "trying Proofs";
            # the last included one gets the used-up note.
            _try_sequences(emails.place_in_proofs_sequence, customer_id)
            if state.free_used + 1 >= state.free_granted:
                customer = db.get_customer(customer_id)
                _try_email(_send_free_used_up, customer=customer)
    return proofs_state(customer_id)


def _send_free_used_up(*, customer) -> None:
    emails.send_system("proofs_free_used_up", to_email=customer["email"], customer_id=customer["id"], vars=emails.variables(customer))
