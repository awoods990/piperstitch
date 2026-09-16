"""Stripe integration — recurring monthly subscriptions, the opposite of
the Amerus License Admin's deliberately-one-time Checkout. PiperStitch's
pricing page promises a monthly plan that renews automatically until the
customer cancels, and a Stripe subscription is exactly that: Stripe owns
the card, the renewal schedule, dunning on a failed charge, and the
customer's own cancel/update-card UI (the Billing Portal). This service
never stores a card and never charges one itself — it only listens.

Everything a customer can do to their own billing happens on Stripe's
hosted pages (Checkout to start, the Billing Portal to manage); this
module just creates those sessions and verifies what Stripe sends back.
"""

from __future__ import annotations

from typing import Optional

import stripe

from . import config

stripe.api_key = config.STRIPE_SECRET_KEY


def create_subscription_checkout(*, customer_name: str, customer_email: str, customer_id: int, success_url: Optional[str] = None, cancel_url: Optional[str] = None,
                                 promotion: Optional[dict] = None, product: str = "core") -> "stripe.checkout.Session":
    """Starts a hosted Checkout for the one monthly Price. `customer_id`
    (our own database id) rides along in the subscription's metadata so
    every later webhook about it can be tied back to our record even if
    the email on the Stripe side is later changed.

    `promotion` (a promotions row, already validated) applies its Stripe
    promotion code to the session and tags the subscription with our
    promotion id, which is how the redemption is attributed afterwards.
    Codes are entered in our own app / pricing page and validated there,
    so Stripe's own code field stays off."""
    metadata = {"customer_id": str(customer_id), "customer_email": customer_email, "product": product}
    price = config.STRIPE_PRICE_PROOFS_MONTHLY if product == "proofs" else config.STRIPE_PRICE_MONTHLY
    if promotion is not None:
        metadata["promotion_id"] = str(promotion["id"])
        metadata["promo_code"] = promotion["code"]
    extra = {}
    if promotion is not None:
        extra["discounts"] = [{"promotion_code": promotion["stripe_promotion_code_id"]}]
        if float(promotion["percent_off"]) >= 100:
            # A fully free period should not demand a card up front.
            extra["payment_method_collection"] = "if_required"
    return stripe.checkout.Session.create(
        mode="subscription",
        line_items=[{"price": price, "quantity": 1}],
        customer_email=customer_email,
        allow_promotion_codes=False,
        success_url=success_url or f"{config.PUBLIC_BASE_URL}/subscribe/success?session_id={{CHECKOUT_SESSION_ID}}",
        cancel_url=cancel_url or f"{config.PUBLIC_BASE_URL}/subscribe/cancel",
        metadata={"customer_id": str(customer_id), "customer_name": customer_name, "customer_email": customer_email, "product": product},
        subscription_data={"metadata": metadata},
        **extra,
        # Stripe's Managed Payments (merchant-of-record mode, higher fees,
        # on by default for new accounts) is opted out of per session:
        # PiperStitch is the merchant, like Amerus. Turn this off if you
        # ever decide to let Stripe handle sales tax instead.
        managed_payments={"enabled": False},
    )


def create_billing_portal_session(*, stripe_customer_id: str, return_url: Optional[str] = None) -> "stripe.billing_portal.Session":
    """Stripe's own self-service page: update the card, see invoices,
    cancel. What the portal allows (e.g. whether cancel is immediate or at
    period end) is configured in the Stripe Dashboard under Settings →
    Billing → Customer portal, not here."""
    return stripe.billing_portal.Session.create(customer=stripe_customer_id, return_url=return_url or f"{config.PUBLIC_BASE_URL}/account")


def retrieve_subscription(stripe_subscription_id: str) -> "stripe.Subscription":
    return stripe.Subscription.retrieve(stripe_subscription_id)


def cancel_subscription(stripe_subscription_id: str, *, at_period_end: bool) -> "stripe.Subscription":
    """Admin-initiated cancel. At period end is the kind default — the
    customer keeps what they paid for. Immediate is for refunds/abuse."""
    if at_period_end:
        return stripe.Subscription.modify(stripe_subscription_id, cancel_at_period_end=True)
    return stripe.Subscription.cancel(stripe_subscription_id)


def reactivate_subscription(stripe_subscription_id: str) -> "stripe.Subscription":
    """Undo a pending cancel-at-period-end before it takes effect."""
    return stripe.Subscription.modify(stripe_subscription_id, cancel_at_period_end=False)


def construct_webhook_event(payload: bytes, sig_header: Optional[str]) -> "stripe.Event":
    """Raises stripe.error.SignatureVerificationError (or ValueError on a
    malformed payload) for anything that doesn't verify — callers must
    never process a webhook body without going through this first."""
    if not sig_header:
        raise ValueError("Missing Stripe-Signature header")
    return stripe.Webhook.construct_event(payload, sig_header, config.STRIPE_WEBHOOK_SECRET)


# ---------------------------------------------------------------- promotions --
# Every discount the admin creates is a real Stripe coupon + promotion
# code, so invoices, receipts and the Stripe Dashboard all show it; the
# admin never has to open Stripe to run a promotion.


def create_coupon_and_code(*, code: str, name: str, percent_off: float, duration_months: Optional[int], max_redemptions: Optional[int], expires_at_ts: Optional[int]) -> tuple[str, str]:
    """Returns (coupon id, promotion code id)."""
    coupon_params: dict = {"name": name[:40], "percent_off": percent_off, "duration": "forever" if duration_months is None else ("once" if duration_months == 1 else "repeating")}
    if duration_months is not None and duration_months > 1:
        coupon_params["duration_in_months"] = duration_months
    coupon = stripe.Coupon.create(**coupon_params)
    pc_params: dict = {"coupon": coupon.id, "code": code}
    if max_redemptions:
        pc_params["max_redemptions"] = max_redemptions
    if expires_at_ts:
        pc_params["expires_at"] = expires_at_ts
    promotion_code = stripe.PromotionCode.create(**pc_params)
    return coupon.id, promotion_code.id


def set_promotion_code_active(stripe_promotion_code_id: str, active: bool) -> None:
    stripe.PromotionCode.modify(stripe_promotion_code_id, active=active)


def apply_coupon_to_subscription(stripe_subscription_id: str, stripe_coupon_id: str) -> "stripe.Subscription":
    """A discount for someone already subscribed: from the next invoice on."""
    return stripe.Subscription.modify(stripe_subscription_id, discounts=[{"coupon": stripe_coupon_id}])


def charge_fee_and_transaction(invoice: dict) -> tuple[Optional[int], Optional[str]]:
    """(fee, balance transaction id) for a paid invoice's charge, or
    (None, None) when the invoice carries no charge id or Stripe can't be
    reached."""
    charge_id = invoice.get("charge") if isinstance(invoice.get("charge"), str) else None
    if not charge_id:
        return None, None
    try:
        charge = stripe.Charge.retrieve(charge_id, expand=["balance_transaction"])
        bt = charge.get("balance_transaction")
        if not bt or bt.get("fee") is None:
            return None, None
        return int(bt["fee"]), bt.get("id")
    except stripe.error.StripeError:
        return None, None


def list_balance_transactions(*, since_ts: int, until_ts: int):
    """Every balance transaction in the window (charges, fees, refunds,
    payouts...), newest first, auto-paged."""
    return stripe.BalanceTransaction.list(created={"gte": since_ts, "lte": until_ts}, limit=100).auto_paging_iter()


def charge_fee_cents(invoice: dict) -> Optional[int]:
    """Stripe's actual processing fee for a paid invoice, from the charge's
    balance transaction -- None if the invoice carries no charge id (newer
    API versions) or Stripe can't be reached, in which case the caller
    estimates."""
    charge_id = invoice.get("charge") if isinstance(invoice.get("charge"), str) else None
    if not charge_id:
        return None
    try:
        charge = stripe.Charge.retrieve(charge_id, expand=["balance_transaction"])
        bt = charge.get("balance_transaction")
        return int(bt["fee"]) if bt and bt.get("fee") is not None else None
    except stripe.error.StripeError:
        return None
