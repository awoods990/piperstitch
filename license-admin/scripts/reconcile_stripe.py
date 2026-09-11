"""Nightly safety net: re-pulls every Stripe-sourced subscription from
Stripe and re-applies it, so a missed webhook (a deploy that was down for
an hour, a misconfigured endpoint) can't leave a customer locked out —
or unlocked — indefinitely. Idempotent; safe to run as often as you like.

    0 4 * * * cd /opt/piperstitch-admin && ./.venv/bin/python scripts/reconcile_stripe.py >> /var/log/piperstitch-reconcile.log 2>&1
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import stripe  # noqa: E402

from app import db, stripe_client, subscriptions  # noqa: E402


def main() -> None:
    db.init_db()
    rows = [r for r in db.list_subscriptions(limit=100000) if r["stripe_subscription_id"]]
    changed = 0
    for row in rows:
        try:
            remote = stripe_client.retrieve_subscription(row["stripe_subscription_id"])
            result = subscriptions.sync_from_stripe(dict(remote))
            if result.kinds:
                changed += 1
                print(f"{row['customer_email']}: {', '.join(result.kinds)}")
        except (stripe.error.StripeError, ValueError) as e:
            print(f"{row['customer_email']}: FAILED — {e}", file=sys.stderr)
    print(f"Checked {len(rows)} subscriptions, {changed} changed.")


if __name__ == "__main__":
    main()
