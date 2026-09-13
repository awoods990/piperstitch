"""Promotion codes: creation mirrors to Stripe (mocked), validation
rules, attribution from the subscription webhook, the promoter's share
per paid invoice, and the owed/paid ledger."""

from datetime import datetime, timedelta, timezone

import pytest

from app import db, promotions, stripe_client, subscriptions
from conftest import stripe_subscription


@pytest.fixture(autouse=True)
def fake_stripe(monkeypatch):
    """No network: coupon/code creation returns ids, toggles and coupon
    application are recorded, fees are unknown (so estimated)."""
    calls = {"created": [], "toggled": [], "applied": []}
    def create(**kw): calls["created"].append(kw); return (f"coupon_{kw['code']}", f"promo_{kw['code']}")
    monkeypatch.setattr(stripe_client, "create_coupon_and_code", create)
    monkeypatch.setattr(stripe_client, "set_promotion_code_active", lambda pc, active: calls["toggled"].append((pc, active)))
    monkeypatch.setattr(stripe_client, "apply_coupon_to_subscription", lambda sub, coupon: calls["applied"].append((sub, coupon)))
    monkeypatch.setattr(stripe_client, "charge_fee_cents", lambda invoice: None)
    return calls


def test_promoter_code_creates_stripe_objects_and_validates(isolated_db, test_keypair, fake_stripe):
    pid = db.create_promoter(name="Stitch Club", email="club@example.com", default_share_pct=25)
    promo_id = promotions.create_promotion(code="club 20", kind="promoter", promoter_id=pid, percent_off=20, duration_months=3, share_pct=25)
    promo = db.get_promotion(promo_id)
    assert promo["code"] == "CLUB20" and promo["stripe_coupon_id"] == "coupon_CLUB20" and promo["stripe_promotion_code_id"] == "promo_CLUB20"
    assert fake_stripe["created"][0]["duration_months"] == 3 and fake_stripe["created"][0]["percent_off"] == 20
    assert promotions.describe(promo) == "20% off your first 3 months"
    assert promotions.validate("club20", email="anyone@example.com")["id"] == promo_id
    with pytest.raises(promotions.PromoError) as e:
        promotions.validate("NOPE")
    assert e.value.code == "unknown"


def test_validation_rules(isolated_db, test_keypair, fake_stripe):
    with pytest.raises(promotions.PromoError):
        promotions.create_promotion(code="x", kind="direct", promoter_id=None, percent_off=50, duration_months=1)  # too short
    with pytest.raises(promotions.PromoError):
        promotions.create_promotion(code="TOOMUCH", kind="direct", promoter_id=None, percent_off=150, duration_months=1)
    with pytest.raises(promotions.PromoError):
        promotions.create_promotion(code="NOPROMOTER", kind="promoter", promoter_id=None, percent_off=10, duration_months=None)
    # restricted to emails, expiring, limited
    pid = promotions.create_promotion(code="VIP100", kind="direct", promoter_id=None, percent_off=100, duration_months=2, allowed_emails="a@x.com, B@Y.com", max_redemptions=1)
    assert promotions.validate("vip100", email="b@y.com")["id"] == pid
    with pytest.raises(promotions.PromoError) as e:
        promotions.validate("VIP100", email="c@z.com")
    assert e.value.code == "not_for_you"
    expired = promotions.create_promotion(code="OLD", kind="direct", promoter_id=None, percent_off=10, duration_months=1, expires_at=datetime.now(timezone.utc) - timedelta(days=1))
    with pytest.raises(promotions.PromoError) as e:
        promotions.validate("OLD")
    assert e.value.code == "expired"
    promotions.set_active(expired, False)
    assert fake_stripe["toggled"][-1] == ("promo_OLD", False)
    with pytest.raises(promotions.PromoError) as e:
        promotions.validate("OLD")
    assert e.value.code == "inactive"
    with pytest.raises(promotions.PromoError):
        promotions.create_promotion(code="VIP100", kind="direct", promoter_id=None, percent_off=5, duration_months=1)  # duplicate


def test_subscription_webhook_attributes_redemption_and_pays_promoter(isolated_db, test_keypair, fake_stripe):
    pid = db.create_promoter(name="Jane", default_share_pct=30)
    promo_id = promotions.create_promotion(code="JANE", kind="promoter", promoter_id=pid, percent_off=50, duration_months=1, share_pct=30)
    cid = db.upsert_customer(name="Cust", email="cust@example.com")
    sub = stripe_subscription(customer_id=cid, email="cust@example.com")
    sub["metadata"]["promotion_id"] = str(promo_id)   # what checkout stamps on the subscription
    result = subscriptions.sync_from_stripe(sub)
    reds = db.list_redemptions_for_customer(cid)
    assert len(reds) == 1 and reds[0]["code"] == "JANE" and reds[0]["subscription_id"] == result.subscription_id
    # replaying the webhook doesn't double-count
    subscriptions.sync_from_stripe(sub)
    assert db.count_redemptions(promo_id) == 1

    # a $9.50 invoice (50% off) -> estimated fee 2.9% + 30c = 58c -> net $8.92 -> 30% = $2.68
    invoice = {"id": "in_1", "subscription": sub["id"], "amount_paid": 950, "currency": "usd", "created": 1_800_000_000, "customer": "cus_123"}
    subscriptions.record_invoice(invoice, paid=True)
    totals = db.promoter_totals(pid)
    assert totals["gross_cents"] == 950 and totals["net_cents"] == 892 and totals["earned_cents"] == 268 and totals["owed_cents"] == 268
    # the same invoice again (Stripe retry) books nothing more
    subscriptions.record_invoice(invoice, paid=True)
    assert db.promoter_totals(pid)["earned_cents"] == 268
    # record a payout; owed drops
    db.record_promoter_payment(promoter_id=pid, amount_cents=200, paid_at="2026-09-13", note="PayPal")
    assert db.promoter_totals(pid)["owed_cents"] == 68
    overview = db.promotions_overview()
    assert overview["redemptions"] == 1 and overview["earned_cents"] == 268 and overview["owed_cents"] == 68
    # direct codes never generate a share
    direct = promotions.create_promotion(code="FRIEND", kind="direct", promoter_id=None, percent_off=100, duration_months=2)
    cid2 = db.upsert_customer(name="Two", email="two@example.com")
    sub2 = stripe_subscription(sub_id="sub_2", customer="cus_2", customer_id=cid2, email="two@example.com"); sub2["metadata"]["promotion_id"] = str(direct)
    subscriptions.sync_from_stripe(sub2)
    subscriptions.record_invoice({"id": "in_2", "subscription": "sub_2", "amount_paid": 0, "currency": "usd", "created": 1_800_000_000}, paid=True)
    assert db.promotions_overview()["earned_cents"] == 268
    assert promotions.cycles_remaining(db.list_redemptions_for_customer(cid2)[0]) == 2


def test_apply_to_existing_subscriber(isolated_db, test_keypair, fake_stripe):
    cid = db.upsert_customer(name="Sub", email="sub@example.com")
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=cid))
    promo_id = promotions.create_promotion(code="LOYAL", kind="direct", promoter_id=None, percent_off=25, duration_months=3)
    promotions.apply_to_existing_subscription(promotion_id=promo_id, subscription_row=db.best_subscription_for_customer(cid))
    assert fake_stripe["applied"] == [("sub_123", "coupon_LOYAL")]
    assert db.list_redemptions_for_customer(cid)[0]["code"] == "LOYAL"


def test_checkout_applies_a_validated_code(isolated_db, test_keypair, fake_stripe, monkeypatch):
    from fastapi.testclient import TestClient
    from app import config
    from app.main import app
    import app.main as main_mod
    promo_id = promotions.create_promotion(code="SITE10", kind="direct", promoter_id=None, percent_off=10, duration_months=1)
    captured = {}
    class FakeSession: id = "cs_test"; url = "https://checkout.stripe.com/c/pay/cs_test"
    def fake_checkout(**kw): captured.update(kw); return FakeSession()
    monkeypatch.setattr(main_mod.stripe_client, "create_subscription_checkout", fake_checkout)
    client = TestClient(app)
    r = client.post("/api/checkout", json={"customer_name": "A", "customer_email": "a@example.com", "promo_code": "site10"})
    assert r.status_code == 200 and captured["promotion"]["id"] == promo_id
    r = client.post("/api/checkout", json={"customer_name": "A", "customer_email": "a@example.com", "promo_code": "BOGUS"})
    assert r.status_code == 400 and "recognised" in r.json()["error"]
    r = client.post("/api/promo/validate", json={"code": "SITE10", "email": "a@example.com"})
    assert r.json()["valid"] is True and r.json()["description"] == "10% off your first month"


def test_init_db_migrates_an_older_database(tmp_path, monkeypatch):
    """A database created before promotions existed gains the new columns."""
    import sqlite3
    from app import config
    path = tmp_path / "old.db"
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE checkout_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER, stripe_session_id TEXT NOT NULL UNIQUE, customer_name TEXT NOT NULL, customer_email TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', error TEXT, created_at TEXT NOT NULL, completed_at TEXT)")
    conn.execute("CREATE TABLE payments (id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER, subscription_id INTEGER, stripe_invoice_id TEXT UNIQUE, stripe_payment_intent TEXT, amount_cents INTEGER NOT NULL, currency TEXT NOT NULL DEFAULT 'usd', status TEXT NOT NULL, paid_at TEXT, created_at TEXT NOT NULL)")
    conn.commit(); conn.close()
    monkeypatch.setattr(config, "DATABASE_PATH", str(path))
    db.init_db()
    db.create_checkout_session(stripe_session_id="cs_1", customer_name="A", customer_email="a@x.com", promotion_id=None)
    with db.connection() as c:
        assert "promotion_id" in {r[1] for r in c.execute("PRAGMA table_info(checkout_sessions)")}
        assert "fee_cents" in {r[1] for r in c.execute("PRAGMA table_info(payments)")}
    db.init_db()  # idempotent
