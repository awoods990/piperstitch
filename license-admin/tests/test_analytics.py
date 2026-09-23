"""First-party analytics: counted on our own server, and counted in a way
that cannot be turned back into a person."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app import analytics, config, db, ratelimit
from app.main import app


@pytest.fixture()
def client(isolated_db, test_keypair):
    with TestClient(app) as c:
        yield c


def test_a_visitor_cannot_be_recovered_or_followed_past_midnight():
    a = analytics.visitor_hash(ip="203.0.113.9", user_agent="Firefox", day="2026-09-23")
    assert "203.0.113.9" not in a and len(a) == 20
    assert analytics.visitor_hash(ip="203.0.113.9", user_agent="Firefox", day="2026-09-23") == a      # same day, same person
    assert analytics.visitor_hash(ip="203.0.113.9", user_agent="Firefox", day="2026-09-24") != a      # tomorrow, a stranger
    assert analytics.visitor_hash(ip="203.0.113.10", user_agent="Firefox", day="2026-09-23") != a


def test_only_the_host_of_a_referrer_is_kept():
    assert analytics.referrer_host("https://www.youtube.com/watch?v=secret-video") == "youtube.com"
    assert analytics.referrer_host("https://duckduckgo.com/?q=what+someone+typed") == "duckduckgo.com"
    assert analytics.referrer_host("https://www.piperstitch.com/pricing.html") == ""      # our own pages are direct
    assert analytics.referrer_host("") == "" and analytics.referrer_host("not a url") == ""


def test_query_strings_are_dropped_from_the_path():
    assert analytics.clean_path("/pricing.html?email=someone@example.com") == "/pricing.html"
    assert analytics.clean_path("/partners/") == "/partners"
    assert analytics.clean_path("javascript:alert(1)") == "/"


def test_a_page_view_is_counted_and_shows_up_in_the_overview(client):
    for n in range(3):
        r = client.post("/api/track", json={"path": "/proofs.html", "referrer": "https://www.youtube.com/watch?v=abc",
                                            "source": "youtube", "medium": "video", "campaign": "cap-logo"},
                        headers={"x-forwarded-for": f"203.0.113.{n}", "user-agent": "Firefox"})
        assert r.status_code == 200 and r.json()["counted"] is True
    # The same person again is another view, not another visitor.
    client.post("/api/track", json={"path": "/pricing.html"}, headers={"x-forwarded-for": "203.0.113.0", "user-agent": "Firefox"})

    over = analytics.overview(30)
    assert over["totals"]["visitors"] == 3 and over["totals"]["views"] == 4
    assert [p["value"] for p in over["pages"]][0] == "/proofs.html"
    assert over["referrers"][0]["value"] == "youtube.com"
    assert over["campaigns"][0]["campaign"] == "cap-logo"


def test_do_not_track_is_honoured(client):
    for header in ({"dnt": "1"}, {"sec-gpc": "1"}):
        r = client.post("/api/track", json={"path": "/"}, headers={**header, "x-forwarded-for": "198.51.100.7"})
        assert r.status_code == 200 and r.json()["counted"] is False
    assert analytics.overview(30)["totals"]["views"] == 0


def test_the_beacon_cannot_be_used_to_fill_the_disk(client):
    limit = ratelimit.LIMITS["track"][0]
    counted = 0
    for n in range(limit + 20):
        if client.post("/api/track", json={"path": f"/p{n}"}, headers={"x-forwarded-for": "203.0.113.55"}).json()["counted"]:
            counted += 1
    assert counted == limit


def test_where_an_account_came_from_is_recorded_once_and_never_changed(isolated_db, test_keypair, fake_smtp):
    """The number the tracking exists for: which channel earned a signup."""
    from app import web_access
    from test_web_access import _code_from

    web_access.request_code(email="jane@example.com")
    web_access.verify_code(email="jane@example.com", code=_code_from(fake_smtp), user_agent="pytest",
                           source_name="youtube", medium="video", campaign="cap-logo", landing_page="/proofs.html")
    customer = db.get_customer_by_email("jane@example.com")
    assert customer["acq_source"] == "youtube" and customer["acq_campaign"] == "cap-logo"
    assert customer["source"] == "web_trial"          # the existing column still means what it meant

    # Coming back later through another link doesn't rewrite history.
    web_access.request_code(email="jane@example.com")
    web_access.verify_code(email="jane@example.com", code=_code_from(fake_smtp), user_agent="pytest", source_name="facebook", medium="social")
    assert db.get_customer_by_email("jane@example.com")["acq_source"] == "youtube"

    rows = db.signups_by_source(since="2000-01-01T00:00:00Z")
    assert rows[0]["source"] == "youtube" and rows[0]["signups"] == 1 and rows[0]["subscribed"] == 0


def test_the_admin_sees_the_funnel(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    from app import web_access
    from test_web_access import _code_from

    web_access.request_code(email="jane@example.com")
    web_access.verify_code(email="jane@example.com", code=_code_from(fake_smtp), user_agent="pytest", source_name="youtube", medium="video")
    with TestClient(app) as client:
        client.post("/api/track", json={"path": "/", "referrer": "https://youtube.com/x"}, headers={"x-forwarded-for": "203.0.113.1"})
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        page = client.get("/admin/analytics").text
        assert "Where the accounts came from" in page and "youtube" in page
        assert "Accounts started" in page and "Do&nbsp;Not&nbsp;Track is honoured" in page
        assert client.get("/admin/analytics?days=7").status_code == 200
