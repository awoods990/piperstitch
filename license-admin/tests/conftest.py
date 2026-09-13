"""Every test runs against an isolated temp database, a disposable Ed25519
keypair, and a fake SMTP — never the real signing key, real Stripe, or
real email. Same posture as the Amerus License Admin's test suite."""

from __future__ import annotations

import base64
import smtplib
import sys
import time
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import auth, config, db, entitlement  # noqa: E402


class FakeSMTP:
    sent: list = []
    fail = False

    def __init__(self, host, port, timeout=None):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def starttls(self):
        pass

    def login(self, username, password):
        pass

    def send_message(self, msg):
        if FakeSMTP.fail:
            raise smtplib.SMTPException("simulated outage")
        FakeSMTP.sent.append(msg)


@pytest.fixture(autouse=True)
def fake_smtp(monkeypatch):
    FakeSMTP.sent = []
    FakeSMTP.fail = False
    monkeypatch.setattr(config, "SMTP_HOST", "smtp.example.com")
    monkeypatch.setattr(config, "SMTP_USE_SSL", False)
    monkeypatch.setattr(smtplib, "SMTP", FakeSMTP)
    return FakeSMTP


@pytest.fixture()
def test_keypair(monkeypatch):
    private_key = Ed25519PrivateKey.generate()
    private_b64 = base64.b64encode(private_key.private_bytes_raw()).decode()
    public_b64 = base64.b64encode(private_key.public_key().public_bytes_raw()).decode()
    monkeypatch.setattr(config, "PIPERSTITCH_LICENSE_PRIVATE_KEY", private_b64)
    monkeypatch.setattr(entitlement, "_PUBLIC_KEY_B64", public_b64)
    return private_b64, public_b64


@pytest.fixture()
def isolated_db(tmp_path, monkeypatch):
    db_path = tmp_path / "test.db"
    monkeypatch.setattr(config, "DATABASE_PATH", str(db_path))
    monkeypatch.setattr(config, "SCHEDULER_ENABLED", False)
    db.init_db()
    from app import emails
    emails.seed()
    return db_path


@pytest.fixture()
def admin_password_configured(monkeypatch):
    password = "correct horse battery staple"
    monkeypatch.setattr(config, "ADMIN_USERNAME", "admin")
    monkeypatch.setattr(config, "ADMIN_PASSWORD_HASH", auth.hash_password(password))
    auth._login_failures.clear()
    return password


def stripe_subscription(*, sub_id="sub_123", customer="cus_123", status="active", period_days=30, cancel_at_period_end=False, canceled_at=None, ended_at=None, customer_id=None, email="", amount=1900, period_end=None):
    """A minimal Stripe subscription object as the webhook would deliver it."""
    now = int(time.time())
    return {
        "id": sub_id,
        "object": "subscription",
        "customer": customer,
        "status": status,
        "current_period_start": now,
        "current_period_end": period_end if period_end is not None else now + period_days * 86400,
        "cancel_at_period_end": cancel_at_period_end,
        "canceled_at": canceled_at,
        "ended_at": ended_at,
        "items": {"data": [{"price": {"unit_amount": amount, "currency": "usd"}}]},
        "metadata": {k: v for k, v in (("customer_id", str(customer_id) if customer_id else ""), ("customer_email", email)) if v},
    }


def stripe_invoice(*, invoice_id="in_1", sub_id="sub_123", customer="cus_123", amount=1900, paid=True, email=""):
    now = int(time.time())
    return {
        "id": invoice_id,
        "object": "invoice",
        "subscription": sub_id,
        "customer": customer,
        "customer_email": email,
        "amount_paid": amount if paid else 0,
        "amount_due": amount,
        "currency": "usd",
        "payment_intent": "pi_1",
        "created": now,
        "status_transitions": {"paid_at": now if paid else None},
    }
