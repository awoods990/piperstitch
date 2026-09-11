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


def create_subscription_checkout(*, customer_name: str, customer_email: str, customer_id: int) -> "stripe.checkout.Session":
    """Starts a hosted Checkout for the one monthly Price. `customer_id`
    (our own database id) rides along in the subscription's metadata so
    every later webhook about it can be tied back to our record even if
    the email on the Stripe side is later changed."""
    return stripe.checkout.Session.create(
        mode="subscription",
        line_items=[{"price": config.STRIPE_PRICE_MONTHLY, "quantity": 1}],
        customer_email=customer_email,
        allow_promotion_codes=True,
        success_url=f"{config.PUBLIC_BASE_URL}/subscribe/success?session_id={{CHECKOUT_SESSION_ID}}",
        cancel_url=f"{config.PUBLIC_BASE_URL}/subscribe/cancel",
        metadata={"customer_id": str(customer_id), "customer_name": customer_name, "customer_email": customer_email},
        subscription_data={"metadata": {"customer_id": str(customer_id), "customer_email": customer_email}},
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
