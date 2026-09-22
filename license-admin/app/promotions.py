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
from datetime import datetime, timezone
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
    return payout_id


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
