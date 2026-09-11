import re

import pytest

from app import activation, config, db, entitlement, subscriptions
from conftest import stripe_subscription


@pytest.fixture()
def subscriber(isolated_db, test_keypair):
    cid = db.upsert_customer(name="Jane", email="jane@example.com")
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=cid))
    return db.get_customer(cid)


def _code_from(fake_smtp) -> str:
    msg = fake_smtp.sent[-1]
    return re.search(r"(\d{6}) is your", msg["Subject"]).group(1)


def test_full_sign_in_flow(subscriber, fake_smtp):
    fake_smtp.sent.clear()
    result = activation.request_code(email="Jane@Example.com", device_id="mac-1", device_name="Jane's MacBook")
    assert result["sent"] is True
    code = _code_from(fake_smtp)

    signed = activation.verify_code(email="jane@example.com", code=code, device_id="mac-1", device_name="Jane's MacBook")
    parsed = entitlement.parse_and_verify(signed.entitlement_token)
    assert parsed.customer_id == subscriber["id"] and parsed.device_id == "mac-1" and parsed.status == "active"
    assert signed.validity.entitled

    # The device token now refreshes silently, no email involved.
    token, validity, who = activation.refresh(device_token=signed.device_token)
    assert token and validity.entitled and who["email"] == "jane@example.com"
    assert len(db.list_active_devices(subscriber["id"])) == 1

    # A code can't be reused.
    with pytest.raises(activation.ActivationError, match="expired"):
        activation.verify_code(email="jane@example.com", code=code, device_id="mac-1", device_name="")


def test_no_subscription_is_reported_not_emailed(isolated_db, test_keypair, fake_smtp):
    db.upsert_customer(name="Lead", email="lead@example.com")
    assert activation.request_code(email="lead@example.com", device_id="m", device_name="")["reason"] == "no_subscription"
    assert activation.request_code(email="nobody@example.com", device_id="m", device_name="")["reason"] == "no_subscription"
    assert fake_smtp.sent == []


def test_ended_subscription_is_reported(subscriber, fake_smtp):
    obj = stripe_subscription(customer_id=subscriber["id"], status="canceled", ended_at=1)
    subscriptions.sync_from_stripe(obj)
    assert activation.request_code(email="jane@example.com", device_id="m", device_name="")["reason"] == "subscription_ended"


def test_wrong_code_then_lockout(subscriber, fake_smtp):
    activation.request_code(email="jane@example.com", device_id="mac-1", device_name="")
    for _ in range(activation.MAX_VERIFY_ATTEMPTS):
        with pytest.raises(activation.ActivationError, match="isn't right"):
            activation.verify_code(email="jane@example.com", code="000000", device_id="mac-1", device_name="")
    with pytest.raises(activation.ActivationError, match="Too many"):
        activation.verify_code(email="jane@example.com", code=_code_from(fake_smtp), device_id="mac-1", device_name="")


def test_only_newest_code_works(subscriber, fake_smtp):
    activation.request_code(email="jane@example.com", device_id="mac-1", device_name="")
    first = _code_from(fake_smtp)
    activation.request_code(email="jane@example.com", device_id="mac-1", device_name="")
    second = _code_from(fake_smtp)
    if first != second:
        with pytest.raises(activation.ActivationError):
            activation.verify_code(email="jane@example.com", code=first, device_id="mac-1", device_name="")
    activation.verify_code(email="jane@example.com", code=second, device_id="mac-1", device_name="")


def test_rate_limit(subscriber):
    for _ in range(activation.MAX_CODES_PER_HOUR):
        activation.request_code(email="jane@example.com", device_id="mac-1", device_name="")
    with pytest.raises(activation.ActivationError, match="Too many codes"):
        activation.request_code(email="jane@example.com", device_id="mac-1", device_name="")


def _sign_in(fake_smtp, device_id, name=""):
    activation.request_code(email="jane@example.com", device_id=device_id, device_name=name)
    return activation.verify_code(email="jane@example.com", code=_code_from(fake_smtp), device_id=device_id, device_name=name)


def test_device_limit_and_revoke(subscriber, fake_smtp, monkeypatch):
    monkeypatch.setattr(config, "MAX_DEVICES", 2)
    a = _sign_in(fake_smtp, "mac-a", "Studio iMac")
    _sign_in(fake_smtp, "mac-b", "Laptop")
    activation.request_code(email="jane@example.com", device_id="mac-c", device_name="Third")
    with pytest.raises(activation.ActivationError) as exc:
        activation.verify_code(email="jane@example.com", code=_code_from(fake_smtp), device_id="mac-c", device_name="Third")
    assert exc.value.code == "device_limit"

    # Same Mac signing in again is not a third device.
    again = _sign_in(fake_smtp, "mac-a", "Studio iMac")
    assert len(db.list_active_devices(subscriber["id"])) == 2
    # ...and its old token is dead.
    with pytest.raises(activation.ActivationError, match="signed out"):
        activation.refresh(device_token=a.device_token)
    activation.refresh(device_token=again.device_token)

    # Revoking frees a slot.
    assert activation.sign_out(device_token=again.device_token)
    _sign_in(fake_smtp, "mac-c", "Third")


def test_refresh_after_subscription_ends_returns_no_token(subscriber, fake_smtp):
    signed = _sign_in(fake_smtp, "mac-1")
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=subscriber["id"], status="canceled", ended_at=1))
    token, validity, _ = activation.refresh(device_token=signed.device_token)
    assert token is None and not validity.entitled and validity.status == "ended"


def test_account_link_is_one_time_and_expires(subscriber, monkeypatch):
    url = activation.create_account_link(subscriber["id"])
    token = url.split("token=")[1]
    assert activation.resolve_account_link(token) == subscriber["id"]
    assert activation.resolve_account_link(token) is None
    assert activation.resolve_account_link("nope") is None
    monkeypatch.setattr(config, "ACCOUNT_LINK_TTL_MINUTES", -1)
    expired = activation.create_account_link(subscriber["id"]).split("token=")[1]
    assert activation.resolve_account_link(expired) is None
