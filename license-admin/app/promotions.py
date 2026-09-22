"""Promotion codes: referral codes for promoters (discount for their
audience, revenue share for them) and direct discounts the admin hands to
a person or group for a number of monthly cycles. The admin page is the
only control surface; each code becomes a Stripe coupon + promotion code
behind the scenes so billing is right without anyone opening Stripe.

Attribution: a code is validated and applied by us at checkout (never
typed on Stripe's page), the subscription is tagged with our promotion
id, and the subscription webhook records the redemption. Revenue share
is computed per paid invoice as the code's share percentage of the
invoice's gross ("30% of what they pay"); Stripe's fee is recorded on
the row for the books. What the admin has actually paid a promoter is a
separate ledger, so "owed" is always earned minus paid."""

from __future__ import annotations

import logging
import re
from datetime import datetime, timedelta, timezone
from typing import Optional

import stripe

from . import config, db, stripe_client

log = logging.getLogger("license_admin")

CODE_RE = re.compile(r"^[A-Z0-9][A-Z0-9-]{2,29}$")


class PromoError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds").replace("+00:00", "Z")


def normalize_code(code: str) -> str:
    return re.sub(r"\s+", "", (code or "")).upper()


# ------------------------------------------------------------- creating ---


def create_promotion(*, code: str, kind: str, promoter_id: Optional[int], percent_off: float, duration_months: Optional[int], share_pct: float = 0,
                     max_redemptions: Optional[int] = None, expires_at: Optional[datetime] = None, allowed_emails: str = "", notes: str = "",
                     trial_days: Optional[int] = None, proofs_extra: int = 0, commission_months: Optional[int] = None) -> int:
    """A code. With a discount it becomes a Stripe coupon + promotion code;
    with `percent_off == 0` (the partner offer: more product, not less
    money -- a longer trial and extra proofs, see the Partner Program
    spec §3.2/§9) Stripe is not involved at all, since Stripe refuses a
    0% coupon: the code is attribution plus perks, carried on the
    subscription's metadata alone."""
    code = normalize_code(code)
    if not CODE_RE.match(code):
        raise PromoError("invalid_code", "Codes are 3–30 letters, numbers or dashes.")
    if kind not in ("promoter", "direct"):
        raise PromoError("invalid_kind", "Kind must be promoter or direct.")
    if kind == "promoter" and not promoter_id:
        raise PromoError("no_promoter", "A promoter code needs a promoter.")
    if not (0 <= percent_off <= 100):
        raise PromoError("invalid_percent", "Discount must be between 0 and 100 percent (0 = no discount, perks only).")
    if percent_off == 0 and not (trial_days or proofs_extra):
        raise PromoError("no_offer", "A code with no discount needs a perk: a longer trial, extra proofs, or both.")
    if trial_days is not None and not (1 <= trial_days <= 365):
        raise PromoError("invalid_trial", "The trial is a number of days, 1 to 365.")
    if not (0 <= proofs_extra <= 100):
        raise PromoError("invalid_proofs", "Extra proofs is a number from 0 to 100.")
    if commission_months is not None and commission_months < 1:
        raise PromoError("invalid_term", "The commission term is a number of months (1 or more), or blank for no cap.")
    if duration_months is not None and duration_months < 1:
        raise PromoError("invalid_duration", "Duration is a number of monthly cycles (1 or more), or blank for every month.")
    if not (0 <= share_pct <= 100):
        raise PromoError("invalid_share", "Revenue share must be between 0 and 100 percent.")
    if kind == "direct":
        share_pct = 0
    if db.get_promotion_by_code(code):
        raise PromoError("duplicate_code", f"The code {code} already exists.")
    emails = ",".join(sorted({e.strip().lower() for e in re.split(r"[,\s]+", allowed_emails or "") if e.strip()}))
    promoter = db.get_promoter(promoter_id) if promoter_id else None
    name = f"PiperStitch {code}" + (f" ({promoter['name']})" if promoter else "")
    coupon_id = pc_id = None
    if percent_off > 0:
        try:
            coupon_id, pc_id = stripe_client.create_coupon_and_code(
                code=code, name=name, percent_off=percent_off, duration_months=duration_months, max_redemptions=max_redemptions,
                expires_at_ts=int(expires_at.timestamp()) if expires_at else None,
            )
        except stripe.error.StripeError as e:
            log.error("Stripe refused to create promotion %s: %s", code, e)
            raise PromoError("stripe", f"Stripe couldn't create the code: {getattr(e, 'user_message', None) or e}") from e
    return db.create_promotion(code=code, kind=kind, promoter_id=promoter_id, percent_off=percent_off, duration_months=duration_months if percent_off > 0 else None, share_pct=share_pct,
                               max_redemptions=max_redemptions, expires_at=_iso(expires_at) if expires_at else None, allowed_emails=emails,
                               stripe_coupon_id=coupon_id, stripe_promotion_code_id=pc_id, notes=notes,
                               trial_days=trial_days, proofs_extra=int(proofs_extra or 0), commission_months=commission_months)


def set_active(promotion_id: int, active: bool) -> None:
    promo = db.get_promotion(promotion_id)
    if promo is None:
        return
    if promo["stripe_promotion_code_id"]:
        try:
            stripe_client.set_promotion_code_active(promo["stripe_promotion_code_id"], active)
        except stripe.error.StripeError as e:
            log.error("Stripe refused to toggle promotion %s: %s", promo["code"], e)
            raise PromoError("stripe", f"Stripe couldn't update the code: {getattr(e, 'user_message', None) or e}") from e
    db.set_promotion_active(promotion_id, active)


# ------------------------------------------------------------ validating ---


def validate(code: str, *, email: str = "") -> "db.sqlite3.Row":
    """The code a customer typed: the promotion row if it may be used
    right now by this email, else a PromoError with the message to show."""
    code = normalize_code(code)
    promo = db.get_promotion_by_code(code) if code else None
    if promo is None:
        raise PromoError("unknown", "That code isn't recognised.")
    if not promo["active"]:
        raise PromoError("inactive", "That code is no longer active.")
    if promo["expires_at"] and datetime.fromisoformat(promo["expires_at"].replace("Z", "+00:00")) <= _now():
        raise PromoError("expired", "That code has expired.")
    if promo["max_redemptions"] and db.count_redemptions(promo["id"]) >= promo["max_redemptions"]:
        raise PromoError("exhausted", "That code has been used as many times as it allows.")
    if promo["allowed_emails"]:
        allowed = set(promo["allowed_emails"].split(","))
        if email.strip().lower() not in allowed:
            raise PromoError("not_for_you", "That code isn't valid for this email address.")
    return promo


def perks(promo) -> list[str]:
    """The non-price perks a code carries, in plain words (empty for a
    plain discount)."""
    out = []
    keys = promo.keys() if hasattr(promo, "keys") else ()
    trial = promo["trial_days"] if "trial_days" in keys else None
    extra = promo["proofs_extra"] if "proofs_extra" in keys else 0
    if trial and trial != config.TRIAL_DAYS:
        out.append(f"{trial}-day free trial")
    if extra:
        out.append(f"{config.PROOFS_FREE_PROOFS + extra} proofs included")
    return out


def describe(promo) -> str:
    pct = float(promo["percent_off"] or 0)
    extras = perks(promo)
    if pct == 0:
        return " and ".join(extras) if extras else "no discount"
    months = promo["duration_months"]
    base = f"{pct:g}% off every month" if months is None else (f"{pct:g}% off your first month" if months == 1 else f"{pct:g}% off your first {months} months")
    return base + (", plus " + " and ".join(extras) if extras else "")


def payload(promo) -> dict:
    keys = promo.keys() if hasattr(promo, "keys") else ()
    return {"code": promo["code"], "percent_off": promo["percent_off"], "duration_months": promo["duration_months"], "description": describe(promo),
            "trial_days": promo["trial_days"] if "trial_days" in keys else None, "proofs_extra": promo["proofs_extra"] if "proofs_extra" in keys else 0}


# ----------------------------------------------------------- attributing ---


def attribute_subscription(sub: dict, *, subscription_id: int, customer_id: int) -> Optional[int]:
    """Called when a Stripe subscription is first mirrored: if it was
    created through one of our codes, record the redemption. The
    promotion id rides in the subscription's metadata (set at checkout);
    the Stripe promotion-code id on the discount is the fallback."""
    metadata = sub.get("metadata") or {}
    promo = None
    if metadata.get("promotion_id"):
        try:
            promo = db.get_promotion(int(metadata["promotion_id"]))
        except (TypeError, ValueError):
            promo = None
    if promo is None:
        discount = sub.get("discount") or {}
        pc = discount.get("promotion_code")
        pc_id = pc if isinstance(pc, str) else (pc or {}).get("id")
        if pc_id:
            promo = db.get_promotion_by_stripe_promotion_code(pc_id)
    if promo is None:
        return None
    redemption_id = db.record_redemption(promotion_id=promo["id"], customer_id=customer_id, subscription_id=subscription_id, stripe_subscription_id=sub.get("id"))
    if redemption_id is not None:
        detail = f"Used code {promo['code']} ({describe(promo)})"
        if promo["promoter_id"]:
            promoter = db.get_promoter(promo["promoter_id"])
            detail += f" — referred by {promoter['name'] if promoter else 'a promoter'}"
        db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="promo_redeemed", detail=detail + ".")
    return redemption_id


def apply_to_existing_subscription(*, promotion_id: int, subscription_row) -> None:
    """The admin giving a current subscriber a discount from their next
    invoice on (a direct code, or a promoter code retroactively)."""
    promo = db.get_promotion(promotion_id)
    if promo is None or not promo["stripe_coupon_id"]:
        raise PromoError("unknown", "That promotion doesn't exist.")
    if subscription_row["source"] != "stripe" or not subscription_row["stripe_subscription_id"]:
        raise PromoError("not_stripe", "Only a Stripe subscription can take a discount — a trial or a comp is already free.")
    try:
        stripe_client.apply_coupon_to_subscription(subscription_row["stripe_subscription_id"], promo["stripe_coupon_id"])
    except stripe.error.StripeError as e:
        raise PromoError("stripe", f"Stripe couldn't apply the discount: {getattr(e, 'user_message', None) or e}") from e
    db.record_redemption(promotion_id=promo["id"], customer_id=subscription_row["customer_id"], subscription_id=subscription_row["id"], stripe_subscription_id=subscription_row["stripe_subscription_id"])
    db.add_event(customer_id=subscription_row["customer_id"], subscription_id=subscription_row["id"], kind="promo_applied", detail=f"Admin applied code {promo['code']} ({describe(promo)}) to the current subscription.")


# ------------------------------------------------------------ revenue share ---


def estimate_fee_cents(gross_cents: int) -> int:
    """Stripe's standard card rate when the actual fee isn't available."""
    return 0 if gross_cents <= 0 else round(gross_cents * config.STRIPE_FEE_PCT / 100) + config.STRIPE_FEE_FIXED_CENTS


def record_share_for_payment(*, payment_id: int, subscription_row, customer_id: Optional[int], gross_cents: int, invoice: Optional[dict] = None) -> Optional[int]:
    """After a paid invoice: if the *customer* came through a promoter's
    code, book the promoter's share. Attribution is per customer, not per
    subscription (R9): the app and Proofs are separate subscriptions and
    the Proofs one carries no promotion of its own, so looking the
    redemption up by subscription paid nothing on Proofs at all. The
    per-subscription lookup stays as the fallback for rows recorded
    before customer_id was reliable.

    The share is a percentage of the invoice's gross -- "30% of what they
    pay" (13.1) -- so proration, upgrades and price changes are right by
    construction. Stripe's fee is still recorded on the row for the books."""
    if subscription_row is None and customer_id is None:
        return None
    redemption = db.redemption_for_customer(customer_id) if customer_id is not None else None
    if (redemption is None or redemption["kind"] != "promoter") and subscription_row is not None:
        redemption = db.redemption_for_subscription(subscription_row["id"])
    if redemption is None or redemption["kind"] != "promoter" or not redemption["promoter_id"]:
        return None
    if redemption["promoter_status"] not in ("active", "approved"):
        log.info("No share for payment %s: promoter %s is %s", payment_id, redemption["promoter_id"], redemption["promoter_status"])
        return None
    paid_at = _invoice_paid_at(invoice)
    if not redemption["first_payment_at"]:
        # R3: the commission clock starts at the first successful payment,
        # written once; from here the attribution is locked (R8/R9).
        months = redemption["commission_months"]
        ends = _iso(_add_months(paid_at, int(months))) if months else None
        db.lock_attribution(redemption["id"], first_payment_at=_iso(paid_at), term_ends_at=ends)
        redemption = db.redemption_for_customer(customer_id) if customer_id is not None else db.redemption_for_subscription(subscription_row["id"])
        maybe_award_bounty(redemption, paid_at=paid_at)
    if redemption["term_ends_at"] and paid_at > datetime.fromisoformat(redemption["term_ends_at"].replace("Z", "+00:00")):
        # R3/R4: past the term. Invoices keep arriving and are simply ignored.
        return None
    share_pct = float(redemption["share_pct"] or 0)
    fee = stripe_client.charge_fee_cents(invoice) if invoice else None
    fee_source = "stripe" if fee is not None else "estimate"
    if fee is None:
        fee = estimate_fee_cents(gross_cents)
    net = max(0, gross_cents - fee)
    share = round(gross_cents * share_pct / 100)
    payout_id = db.record_promo_payout(promoter_id=redemption["promoter_id"], promotion_id=redemption["promotion_id"], customer_id=customer_id, payment_id=payment_id,
                                       gross_cents=gross_cents, fee_cents=fee, net_cents=net, share_pct=share_pct, share_cents=share, fee_source=fee_source)
    if payout_id is not None and customer_id is not None:
        db.add_event(customer_id=customer_id, subscription_id=subscription_row["id"] if subscription_row is not None else None, kind="promo_share",
                     detail=f"${share / 100:.2f} share to {redemption['promoter_name']} ({share_pct:g}% of ${gross_cents / 100:.2f}) for code {redemption['code']}.")
    recheck_reinstatement(redemption["promoter_id"])
    return payout_id


# --------------------------------------------------- partner program ---

BOUNTY_CENTS = 15_00
REINSTATE_AT = 25
CLAWBACK_DAYS = 60


def maybe_award_bounty(redemption, *, paid_at: datetime) -> Optional[int]:
    """R5: $15 once per referred customer, on first successful payment,
    when that date is inside the partner's bounty window or the partner
    has been reinstated. Never on a trial."""
    if redemption["bounty_payout_id"] is not None or not redemption["promoter_id"]:
        return None
    p = db.get_promoter(redemption["promoter_id"])
    if p is None:
        return None
    day = paid_at.date().isoformat()
    in_window = bool(p["bounty_window_start"] and p["bounty_window_end"] and p["bounty_window_start"][:10] <= day <= p["bounty_window_end"][:10])
    reinstated = bool(p["bounty_reinstated_at"] and p["bounty_reinstated_at"] <= _iso(paid_at))
    if not (in_window or reinstated):
        return None
    payout_id = db.record_promo_payout(promoter_id=p["id"], promotion_id=redemption["promotion_id"], customer_id=redemption["customer_id"], payment_id=None,
                                       gross_cents=0, fee_cents=0, net_cents=0, share_pct=0, share_cents=BOUNTY_CENTS, fee_source="none",
                                       kind="bounty", note="Signup bounty" + (" (reinstated)" if reinstated and not in_window else ""))
    if payout_id is not None:
        db.set_bounty_payout(redemption["id"], payout_id)
        db.add_event(customer_id=redemption["customer_id"], subscription_id=None, kind="promo_bounty", detail=f"$15.00 signup bounty to {p['name']} for code {redemption['code']}.")
    return payout_id


def recheck_reinstatement(promoter_id: Optional[int]) -> bool:
    """R7: at 25 active referrals the bounty comes back, permanently."""
    if not promoter_id:
        return False
    p = db.get_promoter(promoter_id)
    if p is None or p["bounty_reinstated_at"]:
        return False
    if db.count_active_referrals(promoter_id) < REINSTATE_AT:
        return False
    if not db.set_bounty_reinstated(promoter_id, _iso(_now())):
        return False
    from . import email_sender
    if p["email"]:
        try:
            email_sender.send_partner_reinstated_email(to_email=p["email"], partner_name=p["name"])
        except email_sender.EmailSendError as e:
            log.error("Reinstatement email to %s failed: %s", p["email"], e)
    return True


def reverse_for_refund(*, stripe_invoice_id: Optional[str], refunded_cents: int, at: datetime, reason: str, event_ref: str) -> list[int]:
    """R6: a refund or chargeback reverses the recurring share in
    proportion, and the bounty too when it lands within 60 days of the
    customer's first payment. New rows, negative amounts; the originals
    are never touched (R11). Returns the reversal row ids."""
    if not stripe_invoice_id:
        return []
    payment = db.get_payment_by_invoice(stripe_invoice_id)
    if payment is None:
        return []
    out = []
    for row in db.promo_payouts_for_payment(payment["id"]):
        if row["kind"] != "recurring" or row["gross_cents"] <= 0:
            continue
        portion = min(refunded_cents, row["gross_cents"]) / row["gross_cents"]
        already = db.reversed_cents_for(row["id"])
        amount = min(round(row["share_cents"] * portion), max(0, row["share_cents"] - already))
        if amount <= 0:
            continue
        rid = db.record_promo_payout(promoter_id=row["promoter_id"], promotion_id=row["promotion_id"], customer_id=row["customer_id"], payment_id=None,
                                     gross_cents=0, fee_cents=0, net_cents=0, share_pct=row["share_pct"], share_cents=-amount, fee_source="none",
                                     kind="reversal", reverses_payout_id=row["id"], note=f"{reason} {event_ref}".strip())
        if rid is not None:
            out.append(rid)
        if row["customer_id"] is not None:
            out += reverse_bounty_if_early(row["customer_id"], at=at, reason=reason, event_ref=event_ref)
    return out


def reverse_bounty_if_early(customer_id: int, *, at: datetime, reason: str, event_ref: str) -> list[int]:
    """The bounty comes back if the customer cancels, refunds or disputes
    within 60 days of first payment (R6)."""
    red = db.redemption_for_customer(customer_id)
    if red is None or red["bounty_payout_id"] is None or not red["first_payment_at"]:
        return []
    first = datetime.fromisoformat(red["first_payment_at"].replace("Z", "+00:00"))
    if at > first + timedelta(days=CLAWBACK_DAYS):
        return []
    bounty = db.get_promo_payout(red["bounty_payout_id"])
    if bounty is None or db.reversed_cents_for(bounty["id"]) >= bounty["share_cents"]:
        return []
    rid = db.record_promo_payout(promoter_id=bounty["promoter_id"], promotion_id=bounty["promotion_id"], customer_id=customer_id, payment_id=None,
                                 gross_cents=0, fee_cents=0, net_cents=0, share_pct=0, share_cents=-bounty["share_cents"], fee_source="none",
                                 kind="reversal", reverses_payout_id=bounty["id"], note=f"Bounty clawback: {reason}")
    return [rid] if rid is not None else []


def on_subscription_ended(customer_id: int, *, at: datetime, stripe_event_id: str = "") -> None:
    """customer.subscription.deleted: an early cancellation claws the
    bounty back; the promoter's active count is re-checked either way.
    first_payment_at and term_ends_at are never touched (R4)."""
    reverse_bounty_if_early(customer_id, at=at, reason="cancelled", event_ref=stripe_event_id)
    red = db.redemption_for_customer(customer_id)
    if red is not None:
        recheck_reinstatement(red["promoter_id"])


def _invoice_paid_at(invoice: Optional[dict]) -> datetime:
    if invoice:
        ts = ((invoice.get("status_transitions") or {}).get("paid_at")) or invoice.get("created")
        if ts:
            return datetime.fromtimestamp(int(ts), tz=timezone.utc)
    return _now()


def _add_months(dt: datetime, months: int) -> datetime:
    """The same day-of-month `months` later (clamped to the shorter month)."""
    import calendar
    y, m = dt.year + (dt.month - 1 + months) // 12, (dt.month - 1 + months) % 12 + 1
    return dt.replace(year=y, month=m, day=min(dt.day, calendar.monthrange(y, m)[1]))


def term_month(redemption, now: Optional[datetime] = None) -> Optional[int]:
    """Which month of the commission term a referral is in (1-based), or
    None before first payment. Month 24 arrives without surprise."""
    if not redemption["first_payment_at"]:
        return None
    start = datetime.fromisoformat(redemption["first_payment_at"].replace("Z", "+00:00"))
    now = now or _now()
    return max(1, (now.year - start.year) * 12 + (now.month - start.month) + 1 - (1 if now.day < start.day else 0))


def cycles_remaining(redemption) -> Optional[int]:
    """How many discounted monthly cycles are left on a redemption (None
    = the discount never ends). Counted from the redemption date."""
    months = redemption["duration_months"]
    if months is None:
        return None
    start = datetime.fromisoformat(redemption["redeemed_at"].replace("Z", "+00:00"))
    now = _now()
    elapsed = (now.year - start.year) * 12 + (now.month - start.month) - (1 if now.day < start.day else 0)
    return max(0, months - max(0, elapsed))
