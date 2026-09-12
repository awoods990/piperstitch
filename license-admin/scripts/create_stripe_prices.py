"""One-time: creates the PiperStitch product and its single monthly
recurring Price in Stripe, and prints the price id to put in .env as
STRIPE_PRICE_MONTHLY. Uses whatever STRIPE_SECRET_KEY is set — run it once
with a test key while developing, and once more with the live key when
you go live (test and live objects are entirely separate in Stripe).

Safe to re-run: a second run simply creates another product/price; delete
extras in the Stripe Dashboard if you do."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import stripe  # noqa: E402

from app import config  # noqa: E402


def main() -> None:
    secret_key = config.STRIPE_SECRET_KEY
    if not secret_key:
        # No key in .env: ask for it here, hidden, so it never has to be
        # typed into a command line or a chat.
        import getpass

        secret_key = getpass.getpass("Stripe secret key (sk_test_… or sk_live_…): ").strip()
    if not secret_key.startswith("sk_"):
        print("That doesn't look like a Stripe secret key (they start with sk_test_ or sk_live_).", file=sys.stderr)
        sys.exit(1)
    stripe.api_key = secret_key
    mode = "TEST" if secret_key.startswith("sk_test_") else "LIVE"
    print(f"Creating PiperStitch product + monthly price in {mode} mode…")

    product = stripe.Product.create(
        name="PiperStitch",
        description="Automatic embroidery digitizing for Mac. Monthly subscription, cancel any time.",
    )
    price = stripe.Price.create(
        product=product.id,
        unit_amount=config.MONTHLY_PRICE_CENTS,
        currency=config.CURRENCY,
        recurring={"interval": "month"},
        nickname="PiperStitch monthly",
    )
    print("\nPut this line in .env:\n")
    print(f"STRIPE_PRICE_MONTHLY={price.id}")
    print(f"\n(product: {product.id}, ${config.MONTHLY_PRICE_CENTS / 100:.2f} {config.CURRENCY.upper()} / month)")


if __name__ == "__main__":
    main()
