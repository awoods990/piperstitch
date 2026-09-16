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
        description="Automatic embroidery digitizing. Monthly subscription, cancel any time.",
        # "Software as a service (SaaS) - personal use". Required when the
        # account has Stripe's Managed Payments on (the default for new
        # accounts); harmless otherwise.
        tax_code="txcd_10103000",
    )
    price = stripe.Price.create(
        product=product.id,
        unit_amount=config.MONTHLY_PRICE_CENTS,
        currency=config.CURRENCY,
        recurring={"interval": "month"},
        nickname="PiperStitch monthly",
    )
    proofs_product = stripe.Product.create(
        name="PiperStitch Proofs",
        description="Customer proof approval for embroidery shops. Monthly subscription, cancel any time.",
        tax_code="txcd_10103000",
    )
    proofs_price = stripe.Price.create(
        product=proofs_product.id,
        unit_amount=config.PROOFS_MONTHLY_PRICE_CENTS,
        currency=config.CURRENCY,
        recurring={"interval": "month"},
        nickname="PiperStitch Proofs monthly",
    )
    print("\nPut these lines in .env:\n")
    print(f"STRIPE_PRICE_MONTHLY={price.id}")
    print(f"STRIPE_PRICE_PROOFS_MONTHLY={proofs_price.id}")
    print(f"\n(product: {product.id}, ${config.MONTHLY_PRICE_CENTS / 100:.2f} {config.CURRENCY.upper()} / month; "
          f"Proofs product: {proofs_product.id}, ${config.PROOFS_MONTHLY_PRICE_CENTS / 100:.2f} / month)")


if __name__ == "__main__":
    main()
