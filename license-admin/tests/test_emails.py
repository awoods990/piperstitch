"""Editable templates and the drip sequences: seeding, editing, trial
enrolment that stops on subscribe, the subscriber series, the win-back
after three quiet weeks, unsubscribe, and the admin's Send now."""

from datetime import datetime, timedelta, timezone

from app import db, emails, subscriptions, web_access
from conftest import stripe_subscription


def test_templates_seed_and_edits_survive_reseed(isolated_db, test_keypair, fake_smtp):
    assert db.get_email_template("welcome")["subject"].startswith("Welcome")
    db.update_email_template("welcome", subject="Hello {first_name}!", body="Custom body {app_url}", cta_label="", cta_url="", preheader="")
    emails.seed()
    row = db.get_email_template("welcome")
    assert row["subject"] == "Hello {first_name}!" and row["edited"] == 1
    fake_smtp.sent.clear()
    from app import email_sender
    email_sender.send_welcome_email(to_email="a@b.co", customer_name="Ada Lovelace")
    assert fake_smtp.sent[-1]["Subject"] == "Hello Ada!"
    db.reset_email_template("welcome"); emails.seed()
    assert db.get_email_template("welcome")["subject"].startswith("Welcome")


def test_trial_sequence_enrols_on_sign_in_and_stops_on_subscribe(isolated_db, test_keypair, fake_smtp):
    import re
    web_access.request_code(email="new@example.com")
    code = re.search(r"(\d{6}) is your", fake_smtp.sent[-1]["Subject"]).group(1)
    session = web_access.verify_code(email="new@example.com", code=code)
    deliveries = db.list_deliveries_for_customer(session.customer_id)
    assert [d["delay_days"] for d in deliveries] == [0, 1, 3, 5, 7, 10, 12, 14]
    # day 0 is due now; the rest are not
    fake_smtp.sent.clear()
    assert emails.process_due() == 1
    assert "first design" in fake_smtp.sent[-1]["Subject"] and "Unsubscribe" in fake_smtp.sent[-1].get_body(preferencelist=("plain",)).get_content()
    assert emails.process_due() == 0
    # four days later, days 1 and 3 go
    assert emails.process_due(now=datetime.now(timezone.utc) + timedelta(days=4, minutes=1)) == 2
    # subscribing skips the rest and starts the subscriber series
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=session.customer_id, email="new@example.com"))
    deliveries = db.list_deliveries_for_customer(session.customer_id)
    trial = [d for d in deliveries if d["sequence_key"] == "trial"]
    assert [d["status"] for d in trial] == ["sent", "sent", "sent", "skipped", "skipped", "skipped", "skipped", "skipped"]
    sub = [d for d in deliveries if d["sequence_key"] == "subscriber"]
    assert [d["delay_days"] for d in sub][:3] == [1, 15, 29] and all(d["status"] == "scheduled" for d in sub)
    # the customer's timeline recorded it
    kinds = [e["kind"] for e in db.list_events_for_customer(session.customer_id)]
    assert "sequence_enrolled" in kinds and "sequence_email" in kinds and "sequence_stopped" in kinds


def test_unsubscribe_and_admin_send_now(isolated_db, test_keypair, fake_smtp):
    cid = db.upsert_customer(name="Sam Smith", email="sam@example.com")
    emails.enroll(cid, "subscriber")
    d = db.list_deliveries_for_customer(cid)[0]
    fake_smtp.sent.clear()
    assert emails.send_delivery(d["id"], by="admin") is True
    assert fake_smtp.sent[-1]["Subject"] == "Welcome to the PiperStitch family" and "Hi Sam," in fake_smtp.sent[-1].get_body(preferencelist=("plain",)).get_content()
    assert db.get_delivery(d["id"])["sent_by"] == "admin"
    db.set_marketing_opt_out(cid, True)
    nxt = db.list_deliveries_for_customer(cid)[1]
    assert emails.send_delivery(nxt["id"], by="auto") is False and db.get_delivery(nxt["id"])["status"] == "skipped"
    # a paused sequence sends nothing automatically
    db.set_marketing_opt_out(cid, False)
    seq = db.get_sequence("subscriber"); db.set_sequence_active(seq["id"], False)
    assert emails.process_due(now=datetime.now(timezone.utc) + timedelta(days=400)) == 0


def test_winback_after_three_quiet_weeks(isolated_db, test_keypair, fake_smtp):
    cid = db.upsert_customer(name="Quiet Q", email="quiet@example.com")
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=cid, email="quiet@example.com"))
    with db.connection() as c:
        c.execute("UPDATE customers SET last_active_at = ? WHERE id = ?", ("2026-08-01T00:00:00Z", cid))
    now = datetime(2026, 9, 13, tzinfo=timezone.utc)
    assert emails.winback_check(now=now) == 1
    fake_smtp.sent.clear()
    assert emails.process_due(now=now) >= 1
    assert any("missing you" in m["Subject"] for m in fake_smtp.sent)
    # not again within the cooldown
    assert emails.winback_check(now=now + timedelta(days=10)) == 0
    # but again after it
    assert emails.winback_check(now=now + timedelta(days=61)) == 1
    # an active subscriber isn't touched
    active = db.upsert_customer(name="Busy", email="busy@example.com")
    subscriptions.sync_from_stripe(stripe_subscription(sub_id="sub_b", customer="cus_b", customer_id=active, email="busy@example.com"))
    db.touch_customer_activity(active)
    assert emails.winback_check(now=datetime.now(timezone.utc)) == 0


def test_unsubscribe_link_is_signed(isolated_db, test_keypair, fake_smtp, monkeypatch):
    from fastapi.testclient import TestClient
    from app import config
    from app.main import app
    monkeypatch.setattr(config, "SESSION_SECRET", "s3cret")
    cid = db.upsert_customer(name="U", email="u@example.com")
    client = TestClient(app)
    assert "isn't valid" in client.get(f"/unsubscribe?c={cid}&t=wrong").text
    fake_smtp.sent.clear()
    page = client.get(f"/unsubscribe?c={cid}&t={emails.unsubscribe_token(cid)}").text
    assert "unsubscribed from tips" in page.lower() and "does not cancel" in page
    assert db.get_customer(cid)["marketing_opt_out"] == 1
    # a confirmation email that says the subscription is unchanged
    assert len(fake_smtp.sent) == 1 and "subscription is unchanged" in fake_smtp.sent[0]["Subject"]
    assert "does not cancel your PiperStitch subscription" in fake_smtp.sent[0].get_body(preferencelist=("plain",)).get_content()
    # clicking the link again doesn't send another
    client.get(f"/unsubscribe?c={cid}&t={emails.unsubscribe_token(cid)}")
    assert len(fake_smtp.sent) == 1


def test_backfill_enrols_existing_customers_without_a_burst(isolated_db, test_keypair, fake_smtp):
    # A trial that started 6 days ago, never enrolled (predates the feature)
    cid = db.upsert_customer(name="Old Trial", email="old@example.com")
    start = datetime.now(timezone.utc) - timedelta(days=6)
    db.upsert_subscription(customer_id=cid, stripe_subscription_id=None, stripe_customer_id=None, status="trialing",
                           current_period_start=start.isoformat(timespec="seconds").replace("+00:00", "Z"),
                           current_period_end=(start + timedelta(days=14)).isoformat(timespec="seconds").replace("+00:00", "Z"),
                           cancel_at_period_end=True, canceled_at=None, ended_at=None, source="manual", amount_cents=0, notes="Web free trial")
    counts = emails.backfill_existing_customers()
    assert counts["trial"] == 1
    statuses = [(d["delay_days"], d["status"]) for d in db.list_deliveries_for_customer(cid)]
    assert statuses == [(0, "skipped"), (1, "skipped"), (3, "skipped"), (5, "skipped"), (7, "scheduled"), (10, "scheduled"), (12, "scheduled"), (14, "scheduled")]
    fake_smtp.sent.clear()
    assert emails.process_due() == 0            # nothing bursts out today
    assert emails.backfill_existing_customers()["trial"] == 0   # idempotent
    # unsubscribing cancels what's left immediately
    from fastapi.testclient import TestClient
    from app import config
    from app.main import app
    import pytest as _p
    TestClient(app).get(f"/unsubscribe?c={cid}&t={emails.unsubscribe_token(cid)}")
    assert all(d["status"] == "skipped" for d in db.list_deliveries_for_customer(cid))
