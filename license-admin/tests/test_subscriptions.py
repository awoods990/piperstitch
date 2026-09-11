from datetime import datetime, timedelta, timezone

import pytest

from app import config, db, subscriptions
from conftest import stripe_invoice, stripe_subscription


@pytest.fixture()
def customer(isolated_db):
    cid = db.upsert_customer(name="Jane Stitcher", email="jane@example.com")
    return db.get_customer(cid)


def test_sync_creates_subscription_and_welcomes(customer, fake_smtp):
    result = subscriptions.sync_from_stripe(stripe_subscription(customer_id=customer["id"]))
    assert result.created and "created" in result.kinds
    sub = db.get_subscription(result.subscription_id)
    assert sub["status"] == "active" and sub["customer_id"] == customer["id"] and sub["amount_cents"] == 1900
    assert db.get_customer(customer["id"])["stripe_customer_id"] == "cus_123"
    assert len(fake_smtp.sent) == 1 and "Welcome" in fake_smtp.sent[0]["Subject"]


def test_sync_is_idempotent(customer, fake_smtp):
    obj = stripe_subscription(customer_id=customer["id"])
    first = subscriptions.sync_from_stripe(obj)
    second = subscriptions.sync_from_stripe(obj)
    assert first.subscription_id == second.subscription_id
    assert second.kinds == ()
    assert len(fake_smtp.sent) == 1
    assert len(db.list_subscriptions_for_customer(customer["id"])) == 1


def test_sync_resolves_customer_by_email_when_no_metadata(isolated_db):
    subscriptions.sync_from_stripe(stripe_subscription(email="new@example.com"), name_hint="New Person")
    c = db.get_customer_by_email("new@example.com")
    assert c is not None and c["source"] == "stripe" and c["name"] == "New Person"


def test_sync_resolves_customer_by_stripe_id(customer):
    db.set_stripe_customer_id(customer["id"], "cus_known")
    result = subscriptions.sync_from_stripe(stripe_subscription(customer="cus_known"))
    assert result.customer_id == customer["id"]


def test_sync_with_no_identity_raises(isolated_db, monkeypatch):
    import stripe

    monkeypatch.setattr(stripe.Customer, "retrieve", lambda cid: {"email": None})
    with pytest.raises(ValueError):
        subscriptions.sync_from_stripe(stripe_subscription())


def test_renewal_records_event(customer):
    obj = stripe_subscription(customer_id=customer["id"])
    subscriptions.sync_from_stripe(obj)
    obj["current_period_end"] += 30 * 86400
    result = subscriptions.sync_from_stripe(obj)
    assert "renewed" in result.kinds
    kinds = [e["kind"] for e in db.list_events_for_customer(customer["id"])]
    assert "renewed" in kinds


def test_cancel_scheduled_emails_and_reversal(customer, fake_smtp):
    obj = stripe_subscription(customer_id=customer["id"])
    subscriptions.sync_from_stripe(obj)
    obj["cancel_at_period_end"] = True
    result = subscriptions.sync_from_stripe(obj)
    assert "cancel_scheduled" in result.kinds
    assert any("scheduled to end" in m["Subject"] for m in fake_smtp.sent)
    obj["cancel_at_period_end"] = False
    assert "cancel_unscheduled" in subscriptions.sync_from_stripe(obj).kinds


def test_deleted_subscription_ends_access(customer):
    obj = stripe_subscription(customer_id=customer["id"])
    subscriptions.sync_from_stripe(obj)
    obj.update(status="canceled", ended_at=obj["current_period_start"], canceled_at=obj["current_period_start"])
    result = subscriptions.sync_from_stripe(obj)
    assert "status_changed" in result.kinds
    assert not subscriptions.validity_for(customer["id"]).entitled
    assert subscriptions.validity_for(customer["id"]).status == "ended"


def test_new_period_end_shape_is_accepted(customer):
    obj = stripe_subscription(customer_id=customer["id"])
    end = obj.pop("current_period_end")
    start = obj.pop("current_period_start")
    obj["items"]["data"][0]["current_period_end"] = end
    obj["items"]["data"][0]["current_period_start"] = start
    result = subscriptions.sync_from_stripe(obj)
    assert db.get_subscription(result.subscription_id)["current_period_end"] is not None


# ------------------------------------------------------------- validity ---


def test_validity_active_is_capped_by_ceiling_and_grace(customer, monkeypatch):
    monkeypatch.setattr(config, "ENTITLEMENT_GRACE_DAYS", 5)
    monkeypatch.setattr(config, "ENTITLEMENT_MAX_DAYS", 30)
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=customer["id"], period_days=10))
    now = datetime.now(timezone.utc)
    v = subscriptions.validity_for(customer["id"], now=now)
    assert v.entitled and v.status == "active"
    assert abs((v.valid_until - (now + timedelta(days=15))).total_seconds()) < 5

    subscriptions.sync_from_stripe(stripe_subscription(sub_id="sub_long", customer_id=customer["id"], period_days=300))
    v = subscriptions.validity_for(customer["id"], now=now)
    assert abs((v.valid_until - (now + timedelta(days=30))).total_seconds()) < 5


def test_validity_cancelling_gets_no_grace(customer):
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=customer["id"], period_days=10, cancel_at_period_end=True))
    now = datetime.now(timezone.utc)
    v = subscriptions.validity_for(customer["id"], now=now)
    assert v.entitled and v.cancel_at_period_end
    assert abs((v.valid_until - (now + timedelta(days=10))).total_seconds()) < 5


def test_validity_past_due_within_grace_then_ends(customer, monkeypatch):
    monkeypatch.setattr(config, "ENTITLEMENT_GRACE_DAYS", 5)
    now = datetime.now(timezone.utc)
    ended = int((now - timedelta(days=2)).timestamp())
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=customer["id"], status="past_due", period_end=ended))
    assert subscriptions.validity_for(customer["id"], now=now).entitled
    assert not subscriptions.validity_for(customer["id"], now=now + timedelta(days=4)).entitled


def test_validity_none_without_subscription(customer):
    v = subscriptions.validity_for(customer["id"])
    assert not v.entitled and v.status == "none"


def test_comp_grant_and_extend(customer, fake_smtp):
    sub_id, err = subscriptions.grant_comp(customer_id=customer["id"], months=2, note="review copy")
    assert err is None
    v = subscriptions.validity_for(customer["id"])
    assert v.entitled and v.status == "comp"
    assert 55 <= (v.period_end - datetime.now(timezone.utc)).days <= 61
    assert any("complimentary" in m["Subject"].lower() for m in fake_smtp.sent)
    later = datetime.now(timezone.utc) + timedelta(days=400)
    subscriptions.extend_comp(db.get_subscription(sub_id), until=later)
    assert subscriptions.validity_for(customer["id"]).period_end.date() == later.date()


def test_comp_cancel_now(customer):
    sub_id, _ = subscriptions.grant_comp(customer_id=customer["id"], months=1, send_email=False)
    assert subscriptions.cancel(db.get_subscription(sub_id), at_period_end=False) is None
    assert not subscriptions.validity_for(customer["id"]).entitled


def test_stripe_cancel_goes_through_stripe(customer, monkeypatch):
    obj = stripe_subscription(customer_id=customer["id"])
    subscriptions.sync_from_stripe(obj)
    calls = []

    def fake_cancel(sid, *, at_period_end):
        calls.append((sid, at_period_end))
        obj["cancel_at_period_end"] = at_period_end
        if not at_period_end:
            obj["status"] = "canceled"
        return obj

    from app import stripe_client

    monkeypatch.setattr(stripe_client, "cancel_subscription", fake_cancel)
    sub = db.get_subscription_by_stripe_id("sub_123")
    assert subscriptions.cancel(sub, at_period_end=True) is None
    assert calls == [("sub_123", True)]
    assert db.get_subscription_by_stripe_id("sub_123")["cancel_at_period_end"] == 1


# ------------------------------------------------------------- invoices ---


def test_invoice_paid_records_payment_once(customer):
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=customer["id"]))
    subscriptions.record_invoice(stripe_invoice(), paid=True)
    subscriptions.record_invoice(stripe_invoice(), paid=True)
    payments = db.list_payments_for_customer(customer["id"])
    assert len(payments) == 1 and payments[0]["amount_cents"] == 1900 and payments[0]["status"] == "paid"
    assert db.monthly_revenue()[0]["revenue_cents"] == 1900
    assert db.subscriber_counts()["revenue_this_month_cents"] == 1900


def test_invoice_failed_emails_customer(customer, fake_smtp):
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=customer["id"]))
    fake_smtp.sent.clear()
    subscriptions.record_invoice(stripe_invoice(invoice_id="in_fail", paid=False), paid=False)
    assert len(fake_smtp.sent) == 1 and "didn't go through" in fake_smtp.sent[0]["Subject"]
    assert db.list_payments_for_customer(customer["id"])[0]["status"] == "failed"


def test_email_outage_never_blocks_sync(customer, fake_smtp):
    fake_smtp.fail = True
    result = subscriptions.sync_from_stripe(stripe_subscription(customer_id=customer["id"]))
    assert result.created and subscriptions.validity_for(customer["id"]).entitled


def test_subscriber_counts(customer):
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=customer["id"]))
    other = db.upsert_customer(name="Bob", email="bob@example.com")
    subscriptions.grant_comp(customer_id=other, months=1, send_email=False)
    counts = db.subscriber_counts()
    assert counts["paying"] == 1 and counts["comps"] == 1 and counts["mrr_cents"] == 1900 and counts["new_this_month"] == 1
