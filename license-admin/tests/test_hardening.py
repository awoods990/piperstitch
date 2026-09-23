"""The launch-readiness fixes: concurrency, the headers a browser expects,
who may post to us, and the limits on endpoints that email strangers."""

from __future__ import annotations

import threading

import pytest
from fastapi.testclient import TestClient

from app import config, db, ratelimit
from app.main import app


@pytest.fixture()
def client(isolated_db, test_keypair):
    with TestClient(app) as c:
        yield c


def test_the_database_runs_in_wal_so_a_reader_cannot_block_a_writer(isolated_db):
    with db.connection() as conn:
        assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
        assert conn.execute("PRAGMA busy_timeout").fetchone()[0] == 30000
    # Twenty threads writing at once: with the old rollback journal this is
    # where "database is locked" appeared.
    errors: list[str] = []

    def write(n: int) -> None:
        try:
            db.create_partner_prospect(name=f"Person {n}", email=f"p{n}@example.com")
        except Exception as e:  # noqa: BLE001 - the point is to see it
            errors.append(str(e))

    threads = [threading.Thread(target=write, args=(n,)) for n in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == []
    assert len(db.list_partner_prospects()) == 20


def test_every_response_carries_the_headers_a_browser_needs(client):
    r = client.get("/admin/login")
    assert r.headers["x-frame-options"] == "DENY"
    assert r.headers["x-content-type-options"] == "nosniff"
    assert "frame-ancestors 'none'" in r.headers["content-security-policy"]
    assert r.headers["referrer-policy"] == "strict-origin-when-cross-origin"


def test_the_admin_is_not_for_search_engines(client):
    r = client.get("/robots.txt")
    assert r.status_code == 200 and "Disallow: /" in r.text


def test_a_form_posted_from_somewhere_else_is_refused(client, admin_password_configured):
    client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
    pid = db.create_promoter(name="Kathleen", email="k@example.com", default_share_pct=30)
    # Our own pages carry an Origin of our own host, which the TestClient sends.
    assert client.post(f"/admin/promoters/{pid}/notes", data={"notes": "fine"}, follow_redirects=False).status_code in (303, 404)
    # Somebody else's page does not.
    r = client.post(f"/admin/promoters/{pid}/partner", data={"status": "closed"}, headers={"origin": "https://evil.example"}, follow_redirects=False)
    assert r.status_code == 403 and "didn't come from PiperStitch" in r.text
    assert db.get_promoter(pid)["status"] != "closed"
    # Stripe and the app's own API carry their own credentials, not cookies.
    r = client.post("/webhooks/stripe", content=b"{}", headers={"origin": "https://stripe.com", "stripe-signature": "nope"})
    assert r.status_code == 400          # rejected for the signature, not for the origin


def test_endpoints_that_email_strangers_are_limited_by_address_of_the_caller(client, fake_smtp):
    """Per-email limits stop someone pestering one person; this stops a
    script working through a list of ten thousand."""
    limit = ratelimit.LIMITS["email"][0]
    for n in range(limit):
        r = client.post("/partners/register", data={"name": f"Person {n}", "email": f"p{n}@example.com"}, follow_redirects=False)
        assert r.status_code == 303, n
    r = client.post("/partners/register", data={"name": "One too many", "email": "over@example.com"})
    assert r.status_code == 429 and "lot of emails from one place" in r.text
    assert db.get_partner_prospect_by_email("over@example.com") is None
    # A different caller is unaffected.
    r = client.post("/partners/register", data={"name": "Elsewhere", "email": "elsewhere@example.com"},
                    headers={"x-forwarded-for": "203.0.113.9"}, follow_redirects=False)
    assert r.status_code == 303


def test_the_total_across_mailing_endpoints_is_capped_too(client, fake_smtp):
    total = ratelimit.LIMITS["email_total"][0]
    paths = ["/account", "/partners/portal", "/partners/register"]     # 8 each, so the total is what bites
    sent = 0
    for n in range(total + 10):
        path = paths[n % len(paths)]
        data = {"email": f"a{n}@example.com"} | ({"name": f"Person {n}"} if path.endswith("register") else {})
        if client.post(path, data=data).status_code != 429:
            sent += 1
    assert sent == total


def test_the_caller_is_identified_by_the_forwarded_address_not_the_proxy(client):
    """Behind Railway every request arrives from one address; keying the
    admin's lockout on it would let anyone lock everybody out."""
    from starlette.requests import Request

    scope = {"type": "http", "headers": [(b"x-forwarded-for", b"203.0.113.9, 10.0.0.1")], "client": ("10.0.0.1", 1234)}
    assert ratelimit.client_ip(Request(scope)) == "203.0.113.9"
    scope = {"type": "http", "headers": [], "client": ("198.51.100.4", 1234)}
    assert ratelimit.client_ip(Request(scope)) == "198.51.100.4"


def test_a_recruits_reply_cannot_put_script_in_the_admin(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    """The reply subject is whatever a stranger typed into their mail
    client, and it lands on a page we look at while signed in."""
    from app import partners

    prospect_id = partners.register_prospect(name="Dev Patel", email="dev@example.com", source="recruit")
    partners.record_reply(db.get_partner_prospect(prospect_id), subject="<script>alert(1)</script>", body="<img src=x onerror=alert(2)>")
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        page = client.get(f"/admin/partners/recruit/{prospect_id}").text
    assert "<script>alert(1)</script>" not in page and "&lt;script&gt;alert(1)&lt;/script&gt;" in page
    assert "<img src=x" not in page and "&lt;img src=x onerror=alert(2)&gt;" in page   # shown as words, not run


def test_a_session_lapses_when_it_stops_being_used(isolated_db, test_keypair, fake_smtp):
    """A token used to be good until somebody revoked it by hand, which
    made a stolen one permanent."""
    from datetime import datetime, timedelta

    from app import web_access
    from test_web_access import _sign_in

    session = _sign_in(fake_smtp, "jane@example.com")
    row = db.get_web_session(session.session_row_id)
    assert row["expires_at"] and row["expires_at"] > db.now_iso()
    # Using it slides the expiry along.
    with db.connection() as conn:
        conn.execute("UPDATE web_sessions SET expires_at = ? WHERE id = ?",
                     ((datetime.utcnow() + timedelta(days=1)).isoformat(timespec="seconds") + "Z", session.session_row_id))
    web_access.state(token=session.token)
    assert db.get_web_session(session.session_row_id)["expires_at"] > (datetime.utcnow() + timedelta(days=80)).isoformat()
    # Left alone past its date, it stops working.
    with db.connection() as conn:
        conn.execute("UPDATE web_sessions SET expires_at = ? WHERE id = ?",
                     ((datetime.utcnow() - timedelta(minutes=1)).isoformat(timespec="seconds") + "Z", session.session_row_id))
    with pytest.raises(Exception) as e:
        web_access.state(token=session.token)
    assert "signed out" in str(e.value).lower()


def test_a_customer_can_take_a_copy_of_their_data_and_have_it_erased(isolated_db, test_keypair, fake_smtp, client):
    from test_web_access import _sign_in

    session = _sign_in(fake_smtp, "jane@example.com")
    cid = session.customer_id
    db.log_email(customer_id=cid, to_email="jane@example.com", kind="welcome", subject="Welcome", status="sent")
    db.create_activation_code(email="jane@example.com", code_hash="x", device_id="d", ttl_minutes=10)
    # Signed in on the account page.
    url = None
    from app import activation
    url = activation.create_account_link(cid)
    client.get(url.split(config.PUBLIC_BASE_URL)[-1], follow_redirects=False)

    export = client.get("/account/export.json")
    assert export.status_code == 200 and export.headers["content-disposition"].endswith('"piperstitch-my-data.json"')
    data = export.json()
    assert data["account"]["email"] == "jane@example.com" and "emails_we_sent" in data and data["exported_at"]

    # Deleting needs the word, and it means it.
    assert client.post("/account/delete", data={"confirm": "yes"}, follow_redirects=False).headers["location"].count("Type+DELETE") == 1
    assert db.get_customer(cid)["email"] == "jane@example.com"
    fake_smtp.sent.clear()
    r = client.post("/account/delete", data={"confirm": "delete"})
    assert r.status_code == 200 and "Deleted." in r.text
    gone = db.get_customer(cid)
    assert gone["email"].endswith("@piperstitch.invalid") and gone["name"] == "Deleted account" and gone["deleted_at"]
    assert db.list_active_web_sessions(cid) == [] and db.export_customer(cid)["emails_we_sent"] == []
    assert fake_smtp.sent[-1]["To"] == "jane@example.com" and "deleted" in fake_smtp.sent[-1]["Subject"]


def test_erasure_waits_until_the_subscription_is_cancelled(isolated_db, test_keypair, fake_smtp, client):
    from conftest import stripe_subscription
    from test_web_access import _sign_in
    from app import activation, subscriptions

    session = _sign_in(fake_smtp, "paying@example.com")
    subscriptions.sync_from_stripe(stripe_subscription(sub_id="sub_p", customer="cus_p", customer_id=session.customer_id, email="paying@example.com", amount=2400))
    client.get(activation.create_account_link(session.customer_id).split(config.PUBLIC_BASE_URL)[-1], follow_redirects=False)
    r = client.post("/account/delete", data={"confirm": "DELETE"}, follow_redirects=False)
    assert "Cancel+your+subscription+first" in r.headers["location"]
    assert db.get_customer(session.customer_id)["email"] == "paying@example.com"
