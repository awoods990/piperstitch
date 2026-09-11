from datetime import datetime, timedelta, timezone

import pytest

from app import entitlement


def _sign(private, **overrides):
    now = datetime.now(timezone.utc)
    kwargs = dict(customer_id=7, device_id="mac-abc", email="a@b.co", status="active", expires_at=now + timedelta(days=20), period_end=now + timedelta(days=15), cancel_at_period_end=False, issued_at=now)
    kwargs.update(overrides)
    return entitlement.sign(private, **kwargs)


def test_round_trip(test_keypair):
    private, _ = test_keypair
    token = _sign(private)
    assert token.startswith("PSE1.")
    parsed = entitlement.parse_and_verify(token)
    assert parsed.customer_id == 7
    assert parsed.device_id == "mac-abc"
    assert parsed.email == "a@b.co"
    assert parsed.status == "active"
    assert parsed.period_end is not None and parsed.cancel_at_period_end is False
    assert (parsed.expires_at - parsed.issued_at).days == 20


def test_null_period_end_survives(test_keypair):
    private, _ = test_keypair
    parsed = entitlement.parse_and_verify(_sign(private, period_end=None, status="comp"))
    assert parsed.period_end is None and parsed.status == "comp"


def test_tampered_payload_is_rejected(test_keypair):
    private, _ = test_keypair
    token = _sign(private)
    prefix, payload, sig = token.split(".")
    import base64, json
    raw = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    raw["exp"] = "2099-01-01T00:00:00Z"
    forged = base64.urlsafe_b64encode(json.dumps(raw, separators=(",", ":"), sort_keys=True).encode()).decode().rstrip("=")
    with pytest.raises(entitlement.EntitlementError, match="isn't valid"):
        entitlement.parse_and_verify(f"{prefix}.{forged}.{sig}")


def test_wrong_key_is_rejected(test_keypair, monkeypatch):
    private, _ = test_keypair
    token = _sign(private)
    monkeypatch.setattr(entitlement, "_PUBLIC_KEY_B64", "OLvbWOM6exl9IL11JHluZkzrTVsQQZs7kB3eHpJJJDY=")
    with pytest.raises(entitlement.EntitlementError):
        entitlement.parse_and_verify(token)


@pytest.mark.parametrize("bad", ["", "garbage", "PSE1.abc", "XYZ.a.b", "PSE1.!!!.!!!"])
def test_malformed_tokens(test_keypair, bad):
    with pytest.raises(entitlement.EntitlementError):
        entitlement.parse_and_verify(bad)


def test_missing_private_key_is_a_plain_error(test_keypair):
    with pytest.raises(entitlement.EntitlementError, match="not configured"):
        _sign("")
    with pytest.raises(entitlement.EntitlementError, match="not a valid"):
        _sign("not base64!!")
