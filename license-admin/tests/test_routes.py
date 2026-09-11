"""End-to-end route tests via FastAPI's TestClient: the public subscribe
flow, the Stripe webhook, the app's JSON API, the customer account page,
and the admin pages — the whole request/response path."""

from __future__ import annotations

import re
from types import SimpleNamespace

import pytest
import stripe
from fastapi.testclient import TestClient

from app import activation, config, db, main, stripe_client, subscriptions
from conftest import stripe_invoice, stripe_subscription


@pytest.fixture()
def client(isolated_db, test_keypair, monkeypatch):
    monkeypatch.setattr(config, "INTAKE_API_KEY", "intake-secret")
    with TestClient(main.app) as c:
        yield c


@pytest.fixture()
def admin(client, admin_password_configured):
    client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
    return client


def _webhook(client, monkeypatch, event_type, obj, event_id="evt_1"):
    monkeypatch.setattr(stripe_client, "construct_webhook_event", lambda payload, sig: {"id": event_id, "type": event_type, "data": {"object": obj}})
    return client.post("/webhooks/stripe", content=b"{}", headers={"stripe-signature": "t=1,v1=fake"})


# ----------------------------------------------------------- subscribe ---


def test_subscribe_form_redirects_to_stripe(client, monkeypatch):
    created = {}

    def fake_create(**kwargs):
        created.update(kwargs)
        return SimpleNamespace(id="cs_test_1", url="https://checkout.stripe.com/c/pay/cs_test_1")

    monkeypatch.setattr(stripe.checkout.Session, "create", fake_create)
    r = client.post("/subscribe", data={"customer_name": "Jane", "customer_email": "Jane@Example.com"}, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"].startswith("https://checkout.stripe.com")
    assert created["mode"] == "subscription" and created["line_items"][0]["price"] == config.STRIPE_PRICE_MONTHLY
    customer = db.get_customer_by_email("jane@example.com")
    assert customer is not None and created["subscription_data"]["metadata"]["customer_id"] == str(customer["id"])
    assert db.get_checkout_session("cs_test_1")["status"] == "pending"


def test_api_checkout_json(client, monkeypatch):
    monkeypatch.setattr(stripe.checkout.Session, "create", lambda **kw: SimpleNamespace(id="cs_2", url="https://checkout.stripe.com/x"))
    r = client.post("/api/checkout", json={"customer_name": "Bob", "customer_email": "bob@example.com", "phone": "555"})
    assert r.status_code == 200 and r.json()["checkout_url"].startswith("https://checkout")
    assert db.get_customer_by_email("bob@example.com")["phone"] == "555"


def test_api_checkout_rejects_existing_active_subscriber(client, monkeypatch):
    cid = db.upsert_customer(name="Jane", email="jane@example.com")
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=cid))
    r = client.post("/api/checkout", json={"customer_name": "Jane", "customer_email": "jane@example.com"})
    assert r.status_code == 400 and "already has an active" in r.json()["error"]


def test_api_checkout_stripe_failure_is_502(client, monkeypatch):
    def boom(**kw):
        raise stripe.error.APIConnectionError("down")

    monkeypatch.setattr(stripe.checkout.Session, "create", boom)
    r = client.post("/api/checkout", json={"customer_name": "Bob", "customer_email": "bob@example.com"})
    assert r.status_code == 502


def test_api_checkout_bad_email_is_422(client):
    assert client.post("/api/checkout", json={"customer_name": "Bob", "customer_email": "nope"}).status_code == 422


def test_success_and_cancel_pages(client):
    db.upsert_customer(name="Jane", email="jane@example.com")
    db.create_checkout_session(stripe_session_id="cs_9", customer_name="Jane", customer_email="jane@example.com")
    assert "jane@example.com" in client.get("/subscribe/success?session_id=cs_9").text
    assert "No charge" in client.get("/subscribe/cancel").text


# -------------------------------------------------------------- intake ---


def test_intake_requires_api_key(client):
    body = {"name": "Lead", "email": "lead@example.com"}
    assert client.post("/api/customers", json=body).status_code == 401
    assert client.post("/api/customers", json=body, headers={"X-API-Key": "wrong"}).status_code == 401
    r = client.post("/api/customers", json=body, headers={"X-API-Key": "intake-secret"})
    assert r.status_code == 200 and db.get_customer_by_email("lead@example.com") is not None
    assert client.post("/api/download-confirmed", json={"email": "lead@example.com"}, headers={"X-API-Key": "intake-secret"}).json() == {"ok": True}
    assert db.get_customer_by_email("lead@example.com")["downloaded_at"] is not None


# ------------------------------------------------------------- webhook ---


def test_webhook_rejects_bad_signature(client, monkeypatch):
    def bad(payload, sig):
        raise stripe.error.SignatureVerificationError("bad", sig)

    monkeypatch.setattr(stripe_client, "construct_webhook_event", bad)
    assert client.post("/webhooks/stripe", content=b"{}", headers={"stripe-signature": "x"}).status_code == 400
    assert client.post("/webhooks/stripe", content=b"{}").status_code == 400


def test_webhook_checkout_completed_creates_subscription(client, monkeypatch, fake_smtp):
    cid = db.upsert_customer(name="Jane", email="jane@example.com")
    db.create_checkout_session(stripe_session_id="cs_1", customer_name="Jane", customer_email="jane@example.com", customer_id=cid)
    monkeypatch.setattr(stripe_client, "retrieve_subscription", lambda sid: stripe_subscription(sub_id=sid, customer_id=cid))
    session = {"id": "cs_1", "mode": "subscription", "subscription": "sub_abc", "metadata": {"customer_id": str(cid), "customer_email": "jane@example.com", "customer_name": "Jane"}}
    r = _webhook(client, monkeypatch, "checkout.session.completed", session)
    assert r.status_code == 200
    assert db.get_checkout_session("cs_1")["status"] == "completed"
    assert subscriptions.validity_for(cid).entitled
    assert any("Welcome" in m["Subject"] for m in fake_smtp.sent)

    # Stripe retries: same event id is a no-op.
    r = _webhook(client, monkeypatch, "checkout.session.completed", session)
    assert r.json().get("duplicate") is True


def test_webhook_subscription_lifecycle(client, monkeypatch):
    cid = db.upsert_customer(name="Jane", email="jane@example.com")
    obj = stripe_subscription(customer_id=cid)
    _webhook(client, monkeypatch, "customer.subscription.created", obj, event_id="evt_a")
    assert subscriptions.validity_for(cid).entitled
    _webhook(client, monkeypatch, "invoice.paid", stripe_invoice(), event_id="evt_b")
    assert db.subscriber_counts()["revenue_this_month_cents"] == 1900
    obj.update(status="canceled", ended_at=1)
    _webhook(client, monkeypatch, "customer.subscription.deleted", obj, event_id="evt_c")
    assert not subscriptions.validity_for(cid).entitled


def test_webhook_unresolvable_subscription_is_acked(client, monkeypatch):
    monkeypatch.setattr(stripe.Customer, "retrieve", lambda cid: {"email": None})
    r = _webhook(client, monkeypatch, "customer.subscription.created", stripe_subscription(), event_id="evt_x")
    assert r.status_code == 200 and db.stripe_event_already_processed("evt_x")


# -------------------------------------------------------------- app API ---


def _subscribed_customer():
    cid = db.upsert_customer(name="Jane", email="jane@example.com")
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=cid))
    return cid


def _code(fake_smtp):
    return re.search(r"(\d{6}) is your", fake_smtp.sent[-1]["Subject"]).group(1)


def test_app_sign_in_and_refresh(client, fake_smtp):
    cid = _subscribed_customer()
    fake_smtp.sent.clear()
    r = client.post("/api/app/activate/request", json={"email": "jane@example.com", "device_id": "mac-1", "device_name": "MacBook"})
    assert r.status_code == 200 and r.json()["sent"] is True
    r = client.post("/api/app/activate/verify", json={"email": "jane@example.com", "code": _code(fake_smtp), "device_id": "mac-1", "device_name": "MacBook"})
    assert r.status_code == 200
    body = r.json()
    assert body["entitlement"].startswith("PSE1.") and body["device_token"] and body["status"] == "active" and body["entitled"] is True
    assert body["email"] == "jane@example.com" and body["valid_until"].endswith("Z")

    r = client.post("/api/app/entitlement", json={"device_token": body["device_token"]})
    assert r.status_code == 200 and r.json()["entitlement"].startswith("PSE1.")

    r = client.post("/api/app/signout", json={"device_token": body["device_token"]})
    assert r.json() == {"ok": True}
    r = client.post("/api/app/entitlement", json={"device_token": body["device_token"]})
    assert r.status_code == 401 and r.json()["error"] == "device_revoked"


def test_app_no_subscription(client):
    r = client.post("/api/app/activate/request", json={"email": "nobody@example.com", "device_id": "m"})
    assert r.status_code == 200 and r.json() == {"sent": False, "reason": "no_subscription", "subscribe_url": f"{config.WEBSITE_BASE_URL}/pricing.html", "account_url": f"{config.PUBLIC_BASE_URL}/account"}


def test_app_wrong_code_and_ended_subscription(client, fake_smtp):
    cid = _subscribed_customer()
    client.post("/api/app/activate/request", json={"email": "jane@example.com", "device_id": "mac-1"})
    r = client.post("/api/app/activate/verify", json={"email": "jane@example.com", "code": "000000", "device_id": "mac-1"})
    assert r.status_code == 400 and r.json()["error"] == "code_wrong"
    good = _code(fake_smtp)
    signed = client.post("/api/app/activate/verify", json={"email": "jane@example.com", "code": good, "device_id": "mac-1"}).json()
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=cid, status="canceled", ended_at=1))
    r = client.post("/api/app/entitlement", json={"device_token": signed["device_token"]})
    assert r.status_code == 402 and r.json()["error"] == "subscription_ended" and r.json()["entitlement"] is None


def test_app_billing_portal(client, fake_smtp, monkeypatch):
    _subscribed_customer()
    client.post("/api/app/activate/request", json={"email": "jane@example.com", "device_id": "mac-1"})
    signed = client.post("/api/app/activate/verify", json={"email": "jane@example.com", "code": _code(fake_smtp), "device_id": "mac-1"}).json()
    monkeypatch.setattr(stripe.billing_portal.Session, "create", lambda **kw: SimpleNamespace(url="https://billing.stripe.com/p/1"))
    r = client.post("/api/app/billing-portal", json={"device_token": signed["device_token"]})
    assert r.json() == {"url": "https://billing.stripe.com/p/1"}


# ------------------------------------------------------- account page ---


def test_account_magic_link_flow(client, fake_smtp, monkeypatch):
    cid = _subscribed_customer()
    fake_smtp.sent.clear()
    r = client.post("/account", data={"email": "jane@example.com"})
    assert r.status_code == 200 and "Check your email" in r.text
    url = re.search(r"http://[^\s]+(/account/open\?token=[^\s]+)", fake_smtp.sent[-1].get_body(preferencelist=("plain",)).get_content()).group(1)
    r = client.get(url, follow_redirects=False)  # path only: the absolute link carries PUBLIC_BASE_URL's host, not the test client's
    assert r.status_code == 303 and r.headers["location"] == "/account/manage"
    page = client.get("/account/manage")
    assert page.status_code == 200 and "next renewal" in page.text and "jane@example.com" in page.text

    # Unknown email gets the identical page and no email.
    fake_smtp.sent.clear()
    assert "Check your email" in client.post("/account", data={"email": "ghost@example.com"}).text
    assert fake_smtp.sent == []

    # Billing portal redirect.
    monkeypatch.setattr(stripe.billing_portal.Session, "create", lambda **kw: SimpleNamespace(url="https://billing.stripe.com/p/2"))
    r = client.post("/account/billing-portal", follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "https://billing.stripe.com/p/2"

    # Device revoke from the account page.
    activation.request_code(email="jane@example.com", device_id="mac-1", device_name="Laptop")
    signed = activation.verify_code(email="jane@example.com", code=_code(fake_smtp), device_id="mac-1", device_name="Laptop")
    device = db.list_active_devices(cid)[0]
    client.post(f"/account/devices/{device['id']}/revoke", follow_redirects=False)
    assert db.list_active_devices(cid) == []
    with pytest.raises(activation.ActivationError):
        activation.refresh(device_token=signed.device_token)

    client.post("/account/logout")
    assert client.get("/account/manage", follow_redirects=False).status_code == 303


def test_account_manage_requires_session(client):
    assert client.get("/account/manage", follow_redirects=False).headers["location"] == "/account"
    assert client.get("/account/open?token=bad").status_code == 400


# ---------------------------------------------------------------- admin ---


def test_admin_requires_login(client):
    for path in ("/admin", "/admin/subscribers", "/admin/registrations", "/admin/financials", "/admin/updates", "/admin/export.csv"):
        r = client.get(path, follow_redirects=False)
        assert r.status_code == 303 and r.headers["location"] == "/admin/login"


def test_admin_login_and_pages(admin, fake_smtp):
    cid = _subscribed_customer()
    assert "Paying subscribers" in admin.get("/admin").text
    assert "jane@example.com" in admin.get("/admin/subscribers").text
    assert "jane@example.com" in admin.get("/admin/subscribers?status=entitled&q=jane").text
    assert "jane@example.com" not in admin.get("/admin/subscribers?status=canceled").text
    assert "jane@example.com" in admin.get("/admin/registrations").text
    detail = admin.get(f"/admin/customers/{cid}")
    assert detail.status_code == 200 and "Entitled to use PiperStitch" in detail.text
    assert "Revenue by month" in admin.get("/admin/financials").text
    csv_text = admin.get("/admin/export.csv").text
    assert "jane@example.com" in csv_text and "sub_123" in csv_text
    assert "month,payments" in admin.get("/admin/financials.csv").text


def test_admin_wrong_password_and_lockout(client, admin_password_configured):
    assert client.post("/admin/login", data={"username": "admin", "password": "nope"}).status_code == 401
    for _ in range(10):
        client.post("/admin/login", data={"username": "admin", "password": "nope"})
    assert client.post("/admin/login", data={"username": "admin", "password": admin_password_configured}).status_code == 429


def test_admin_comp_grant_extend_cancel(admin, fake_smtp):
    cid = db.upsert_customer(name="Reviewer", email="rev@example.com")
    r = admin.post(f"/admin/customers/{cid}/comp", data={"months": "3", "note": "review copy", "send_email": "1"}, follow_redirects=False)
    assert r.status_code == 303 and "granted" in r.headers["location"]
    assert subscriptions.validity_for(cid).status == "comp"
    assert any("complimentary" in m["Subject"].lower() for m in fake_smtp.sent)
    sub = db.list_subscriptions_for_customer(cid)[0]
    admin.post(f"/admin/subscriptions/{sub['id']}/extend", data={"until": "2030-01-31"})
    assert db.get_subscription(sub["id"])["current_period_end"].startswith("2030-01-31")
    admin.post(f"/admin/subscriptions/{sub['id']}/cancel", data={"when": "now"})
    assert not subscriptions.validity_for(cid).entitled
    r = admin.post(f"/admin/customers/{cid}/comp", data={"months": "1", "until": "not-a-date"}, follow_redirects=False)
    assert "error=" in r.headers["location"]


def test_admin_stripe_cancel_and_reactivate(admin, monkeypatch):
    cid = _subscribed_customer()
    obj = stripe_subscription(customer_id=cid)

    def fake_modify(sid, **kw):
        obj.update(kw)
        return obj

    monkeypatch.setattr(stripe.Subscription, "modify", fake_modify)
    sub = db.get_subscription_by_stripe_id("sub_123")
    admin.post(f"/admin/subscriptions/{sub['id']}/cancel", data={"when": "period_end"})
    assert db.get_subscription(sub["id"])["cancel_at_period_end"] == 1
    admin.post(f"/admin/subscriptions/{sub['id']}/reactivate")
    assert db.get_subscription(sub["id"])["cancel_at_period_end"] == 0
    monkeypatch.setattr(stripe_client, "retrieve_subscription", lambda sid: obj)
    r = admin.post(f"/admin/subscriptions/{sub['id']}/sync", follow_redirects=False)
    assert "Synced" in r.headers["location"]


def test_admin_delete_refuses_live_subscriber(admin):
    cid = _subscribed_customer()
    r = admin.post(f"/admin/customers/{cid}/delete", follow_redirects=False)
    assert "cancel+it+first" in r.headers["location"] or "cancel%20it%20first" in r.headers["location"].replace("+", "%20")
    assert db.get_customer(cid) is not None
    lead = db.upsert_customer(name="Lead", email="lead@example.com")
    admin.post(f"/admin/customers/{lead}/delete")
    assert db.get_customer(lead) is None


def test_admin_emails(admin, fake_smtp):
    cid = _subscribed_customer()
    fake_smtp.sent.clear()
    admin.post(f"/admin/customers/{cid}/resend-welcome")
    admin.post(f"/admin/customers/{cid}/account-link")
    form = admin.get(f"/admin/customers/{cid}/email")
    assert "working for you" in form.text
    admin.post(f"/admin/customers/{cid}/email", data={"subject": "Hello", "body": "Hi there\n\n- one\n- two"})
    subjects = [m["Subject"] for m in fake_smtp.sent]
    assert subjects[0].startswith("Welcome") and "Manage your" in subjects[1] and subjects[2] == "Hello"
    assert db.get_customer(cid)["last_reminder_sent_at"] is not None
    fake_smtp.fail = True
    assert admin.post(f"/admin/customers/{cid}/email", data={"subject": "x", "body": "y"}).status_code == 502


def test_admin_device_revoke(admin, fake_smtp):
    cid = _subscribed_customer()
    activation.request_code(email="jane@example.com", device_id="mac-1", device_name="Laptop")
    activation.verify_code(email="jane@example.com", code=_code(fake_smtp), device_id="mac-1", device_name="Laptop")
    device = db.list_active_devices(cid)[0]
    r = admin.post(f"/admin/devices/{device['id']}/revoke", follow_redirects=False)
    assert r.status_code == 303 and db.list_active_devices(cid) == []


def test_admin_updates_page_unconfigured(admin, monkeypatch):
    monkeypatch.setattr(config, "WEBSITE_SFTP_HOST", "")
    assert "isn't configured" in admin.get("/admin/updates").text
    r = admin.post("/admin/updates", data={"version": "0.2.0"}, files={"build_file": ("x.dmg", b"123")}, follow_redirects=False)
    assert "configured" in r.headers["location"]


def test_admin_updates_publish(admin, monkeypatch):
    from app import website_publish

    monkeypatch.setattr(config, "WEBSITE_SFTP_HOST", "sftp.example.com")
    uploaded = {}
    monkeypatch.setattr(website_publish, "upload_build", lambda local, remote: uploaded.update(remote=remote))
    monkeypatch.setattr(website_publish, "write_feed_json", lambda **kw: uploaded.update(feed=kw))
    import httpx

    monkeypatch.setattr(httpx, "get", lambda url, timeout: SimpleNamespace(json=lambda: {"latest_version": "0.2.0"}))
    r = admin.post("/admin/updates", data={"version": "0.2.0", "notes": "Faster fills"}, files={"build_file": ("PiperStitch.dmg", b"binary")}, follow_redirects=False)
    assert "Published+0.2.0" in r.headers["location"] and "Verified" in r.headers["location"]
    assert uploaded["remote"] == "PiperStitch-0.2.0.dmg" and uploaded["feed"]["download_url"].endswith("/PiperStitch-0.2.0.dmg")
    assert db.latest_published_update()["version"] == "0.2.0"
    r = admin.post("/admin/updates", data={"version": "0.1.9"}, files={"build_file": ("x.dmg", b"1")}, follow_redirects=False)
    assert "not+newer" in r.headers["location"]
