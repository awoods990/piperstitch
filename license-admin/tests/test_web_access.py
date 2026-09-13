"""The web edition's sign-in: a verified email gets exactly one trial,
a Stripe subscription takes over from it, and projects belong to their
account. Mirrors test_activation.py's shape."""

import re
from datetime import datetime, timedelta, timezone

import pytest

from app import activation, config, db, subscriptions, web_access
from conftest import stripe_subscription


def _code_from(fake_smtp) -> str:
    return re.search(r"(\d{6}) is your", fake_smtp.sent[-1]["Subject"]).group(1)


def _sign_in(fake_smtp, email="new@example.com") -> web_access.WebSession:
    web_access.request_code(email=email)
    return web_access.verify_code(email=email, code=_code_from(fake_smtp), user_agent="pytest")


def test_unknown_email_gets_a_code_and_a_trial(isolated_db, test_keypair, fake_smtp):
    result = web_access.request_code(email="New@Example.com")
    assert result["sent"] is True
    session = web_access.verify_code(email="new@example.com", code=_code_from(fake_smtp))
    state = web_access.state(token=session.token)
    assert state["entitled"] is True and state["status"] == "trialing" and state["email"] == "new@example.com"
    ends = datetime.fromisoformat(state["period_end"].replace("Z", "+00:00"))
    assert timedelta(days=config.TRIAL_DAYS - 1) < ends - datetime.now(timezone.utc) <= timedelta(days=config.TRIAL_DAYS)
    assert db.get_customer_by_email("new@example.com")["source"] == "web_trial"


def test_trial_is_granted_only_once(isolated_db, test_keypair, fake_smtp):
    first = _sign_in(fake_smtp)
    sub = db.best_subscription_for_customer(first.customer_id)
    # Push the trial into the past, sign in again: no fresh trial.
    with db.connection() as conn:
        conn.execute("UPDATE subscriptions SET current_period_end = ? WHERE id = ?", ("2020-01-01T00:00:00Z", sub["id"]))
    web_access.sign_out(token=first.token)
    again = _sign_in(fake_smtp)
    state = web_access.state(token=again.token)
    assert state["entitled"] is False and state["status"] == "ended"
    assert db.count_projects(again.customer_id) == 0
    assert len([s for s in db.list_subscriptions(status="") if s["customer_id"] == again.customer_id]) == 1
    # And the stale trial row was closed out for the admin's sake.
    assert db.best_subscription_for_customer(again.customer_id)["status"] == "canceled"


def test_stripe_subscription_takes_over_from_trial(isolated_db, test_keypair, fake_smtp):
    session = _sign_in(fake_smtp)
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=session.customer_id, email="new@example.com"))
    state = web_access.state(token=session.token)
    assert state["status"] == "active" and state["entitled"] is True


def test_existing_mac_subscriber_signs_in_without_a_trial(isolated_db, test_keypair, fake_smtp):
    cid = db.upsert_customer(name="Jane", email="jane@example.com")
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=cid))
    session = _sign_in(fake_smtp, email="jane@example.com")
    assert session.customer_id == cid
    state = web_access.state(token=session.token)
    assert state["status"] == "active" and state["name"] == "Jane"
    assert all(s["status"] != "trialing" for s in db.list_subscriptions() if s["customer_id"] == cid)


def test_wrong_code_and_revoked_session(isolated_db, test_keypair, fake_smtp):
    web_access.request_code(email="x@example.com")
    with pytest.raises(activation.ActivationError) as e:
        web_access.verify_code(email="x@example.com", code="000000")
    assert e.value.code == "code_wrong"
    session = web_access.verify_code(email="x@example.com", code=_code_from(fake_smtp))
    assert web_access.sign_out(token=session.token) is True
    with pytest.raises(activation.ActivationError) as e:
        web_access.state(token=session.token)
    assert e.value.code == "session_revoked"


def test_projects_round_trip_and_isolation(isolated_db, test_keypair, fake_smtp):
    a = _sign_in(fake_smtp, email="a@example.com")
    b = _sign_in(fake_smtp, email="b@example.com")
    doc = {"schemaVersion": 1, "name": "Badge", "physicalWidthMM": 100, "physicalHeightMM": 80, "objects": [{"id": "1"}, {"id": "2"}]}
    saved = web_access.save_project(token=a.token, project_id="11111111-2222-3333-4444-555555555555", name="Badge", document=doc)
    assert saved["created"] is True
    saved = web_access.save_project(token=a.token, project_id="11111111-2222-3333-4444-555555555555", name="Badge v2", document=doc)
    assert saved["created"] is False
    listed = web_access.list_projects(token=a.token)
    assert len(listed) == 1 and listed[0]["name"] == "Badge v2" and listed[0]["object_count"] == 2 and listed[0]["width_mm"] == 100
    assert web_access.get_project(token=a.token, project_id=listed[0]["id"])["document"] == doc
    # Another account can't see it, overwrite it, or delete it.
    assert web_access.list_projects(token=b.token) == []
    assert web_access.get_project(token=b.token, project_id=listed[0]["id"]) is None
    with pytest.raises(activation.ActivationError):
        web_access.save_project(token=b.token, project_id=listed[0]["id"], name="stolen", document=doc)
    assert web_access.delete_project(token=b.token, project_id=listed[0]["id"]) is False
    assert web_access.delete_project(token=a.token, project_id=listed[0]["id"]) is True


def test_feedback_submission_is_stored_and_acknowledged_by_email(isolated_db, test_keypair, fake_smtp):
    from app import db as _db

    session = _sign_in(fake_smtp, email="feedback@example.com")
    fake_smtp.sent.clear()
    result = web_access.submit_feedback(
        token=session.token, note="The satin on the O looks wrong.", design_name="Logo", stitch_count=4200,
        original_image_base64="b3JpZ2luYWw=", original_image_type="image/png",
        digitized_image_base64="ZGlnaXRpemVk", digitized_image_type="image/png",
    )
    assert result["id"] > 0
    stored = _db.get_feedback(result["id"])
    assert stored["customer_email"] == "feedback@example.com" and stored["note"] == "The satin on the O looks wrong."
    assert stored["original_image_data"] == "b3JpZ2luYWw=" and stored["digitized_image_data"] == "ZGlnaXRpemVk"
    assert stored["reviewed_at"] is None
    assert len(fake_smtp.sent) == 1 and "Thanks for the feedback" in fake_smtp.sent[0]["Subject"]

    # An oversized image is rejected before anything is written.
    with pytest.raises(activation.ActivationError):
        web_access.submit_feedback(
            token=session.token, note="", design_name="Too big", stitch_count=0,
            original_image_base64=None, original_image_type="image/png",
            digitized_image_base64="x" * (web_access.MAX_FEEDBACK_IMAGE_BASE64_CHARS + 1), digitized_image_type="image/png",
        )


def test_web_routes_require_the_shared_key(isolated_db, test_keypair, fake_smtp, monkeypatch):
    from fastapi.testclient import TestClient
    from app.main import app
    monkeypatch.setattr(config, "WEB_API_KEY", "secret")
    client = TestClient(app)
    assert client.post("/api/web/signin/request", json={"email": "k@example.com"}).status_code == 401
    r = client.post("/api/web/signin/request", json={"email": "k@example.com"}, headers={"X-API-Key": "secret"})
    assert r.status_code == 200 and r.json()["sent"] is True
    r = client.post("/api/web/signin/verify", json={"email": "k@example.com", "code": _code_from(fake_smtp)}, headers={"X-API-Key": "secret"})
    assert r.status_code == 200 and r.json()["status"] == "trialing" and r.json()["token"]
    token = r.json()["token"]
    r = client.post("/api/web/projects/list", json={"token": token}, headers={"X-API-Key": "secret"})
    assert r.json() == {"projects": []}
    r = client.post("/api/web/billing-portal", json={"token": token}, headers={"X-API-Key": "secret"})
    assert r.status_code == 404 and r.json()["error"] == "no_billing"


def test_failed_sends_do_not_count_toward_the_rate_limit(isolated_db, test_keypair, fake_smtp):
    fake_smtp.fail = True
    for _ in range(activation.MAX_CODES_PER_HOUR + 2):
        with pytest.raises(activation.ActivationError) as e:
            web_access.request_code(email="broken@example.com")
        assert e.value.code == "email_failed"
    fake_smtp.fail = False
    assert web_access.request_code(email="broken@example.com")["sent"] is True


def test_web_sign_in_records_terms_acceptance_once_per_version(isolated_db, test_keypair, fake_smtp, monkeypatch):
    original_version = config.TERMS_VERSION
    session = _sign_in(fake_smtp)
    customer = db.get_customer(session.customer_id)
    assert customer["consent_terms_version"] == original_version
    first_stamp = customer["consent_accepted_at"]
    assert first_stamp
    # Signing in again under the same version leaves the original timestamp alone.
    web_access.sign_out(token=session.token)
    with db.connection() as conn:
        conn.execute("UPDATE customers SET consent_accepted_at = ? WHERE id = ?", ("2020-01-01T00:00:00Z", session.customer_id))
    _sign_in(fake_smtp)
    assert db.get_customer(session.customer_id)["consent_accepted_at"] == "2020-01-01T00:00:00Z"
    # A bumped Terms version is stamped on the next sign-in, with an event for the admin.
    monkeypatch.setattr(config, "TERMS_VERSION", "2030-01-01")
    _sign_in(fake_smtp)
    customer = db.get_customer(session.customer_id)
    assert customer["consent_terms_version"] == "2030-01-01" and customer["consent_accepted_at"] != "2020-01-01T00:00:00Z"
    accepted = [e["detail"] for e in db.list_events_for_customer(session.customer_id) if e["kind"] == "terms_accepted"]
    assert sorted(accepted) == sorted([f"Accepted Terms v{original_version} by signing in on the web.", "Accepted Terms v2030-01-01 by signing in on the web."])


def test_profile_name_and_send_file(isolated_db, test_keypair, fake_smtp):
    session = _sign_in(fake_smtp, email="sender@example.com")
    assert web_access.update_name(token=session.token, name="  Ashley W ")["name"] == "Ashley W"
    fake_smtp.sent.clear()
    web_access.send_file(token=session.token, to_email="Friend@Example.com", filename="badge.dst", data=b"LA:badge" + bytes(600), message="Here's the logo", design_name="badge")
    msg = fake_smtp.sent[-1]
    assert msg["To"] == "friend@example.com" and msg["Reply-To"] == "sender@example.com" and "Ashley W" in msg["Subject"]
    attachments = list(msg.iter_attachments())
    assert len(attachments) == 1 and attachments[0].get_filename() == "badge.dst" and attachments[0].get_payload(decode=True).startswith(b"LA:badge")
    assert "Here's the logo" in msg.get_body(preferencelist=("plain",)).get_content()
    with pytest.raises(activation.ActivationError) as e:
        web_access.send_file(token=session.token, to_email="friend@example.com", filename="virus.exe", data=b"x")
    assert e.value.code == "invalid_file"
    with pytest.raises(activation.ActivationError):
        web_access.send_file(token=session.token, to_email="nope", filename="a.pes", data=b"x")
    assert db.count_sent_files(session.customer_id) == 1
