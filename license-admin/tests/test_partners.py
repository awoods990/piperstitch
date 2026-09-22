"""Partner Program (docs: build spec §12): link attribution, the perks a
partner code delivers at trial start, and the rules around who may be
attributed. Stripe is mocked; time is driven through the cookie's own
timestamp."""

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app import config, db, promotions, referrals, stripe_client, subscriptions, web_access
from app.main import app
from conftest import stripe_subscription
from test_web_access import _code_from


@pytest.fixture(autouse=True)
def fake_stripe(monkeypatch):
    calls = {"created": []}
    def create(**kw): calls["created"].append(kw); return (f"coupon_{kw['code']}", f"promo_{kw['code']}")
    monkeypatch.setattr(stripe_client, "create_coupon_and_code", create)
    monkeypatch.setattr(stripe_client, "set_promotion_code_active", lambda pc, active: None)
    monkeypatch.setattr(stripe_client, "charge_fee_cents", lambda invoice: None)
    return calls


def partner(name="Kathleen", email="kathleen@example.com", code="KATHLEEN", status="active"):
    pid = db.create_promoter(name=name, email=email, default_share_pct=30)
    with db.connection() as conn:
        conn.execute("UPDATE promoters SET status = ?, tier = 'founding' WHERE id = ?", (status, pid))
    promo_id = promotions.create_promotion(code=code, kind="promoter", promoter_id=pid, percent_off=0, duration_months=None, share_pct=30, trial_days=30, proofs_extra=7, commission_months=24)
    return pid, promo_id


def sign_up(fake_smtp, email, *, promo_code="", ref_cookie=""):
    web_access.request_code(email=email)
    return web_access.verify_code(email=email, code=_code_from(fake_smtp), user_agent="pytest", promo_code=promo_code, ref_cookie=ref_cookie)


def test_link_sets_a_signed_cookie_logs_the_click_and_shows_the_partners_page(isolated_db, test_keypair, fake_smtp):
    pid, promo_id = partner()
    client = TestClient(app)
    r = client.get("/r/kathleen", headers={"user-agent": "pytest", "x-forwarded-for": "203.0.113.9"})
    assert r.status_code == 200 and "Kathleen sent you" in r.text and "30-day free trial" in r.text and "10 proofs" in r.text and "KATHLEEN" in r.text
    cookie = r.cookies.get(referrals.COOKIE_NAME)
    assert cookie and referrals.resolve_cookie(cookie)["id"] == promo_id
    click = db.list_referral_clicks(promo_id)[0]
    assert click["ip_hash"] and "203.0.113.9" not in click["ip_hash"] and click["user_agent"] == "pytest" and db.count_referral_clicks(promo_id) == 1
    # ?to= sends the visitor on to a marketing page; anything unsafe is ignored.
    r = client.get("/r/KATHLEEN?to=/pricing.html", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == config.WEBSITE_BASE_URL + "/pricing.html" and r.cookies.get(referrals.COOKIE_NAME)
    r = client.get("/r/KATHLEEN?to=https://evil.example/x", follow_redirects=False)
    assert r.status_code == 200
    # Unknown code: home, no cookie.
    r = client.get("/r/NOBODY", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == config.WEBSITE_BASE_URL + "/" and not r.cookies.get(referrals.COOKIE_NAME)


def test_cookie_attributes_within_90_days_and_a_tampered_or_old_one_does_not(isolated_db, test_keypair, fake_smtp):
    pid, promo_id = partner()
    fresh = referrals.cookie_value(promo_id, at=datetime.now(timezone.utc) - timedelta(days=89))
    stale = referrals.cookie_value(promo_id, at=datetime.now(timezone.utc) - timedelta(days=91))
    assert referrals.resolve_cookie(fresh)["id"] == promo_id
    assert referrals.resolve_cookie(stale) is None
    tampered = fresh.rsplit("|", 1)[0] + "|" + "0" * 32
    assert referrals.resolve_cookie(tampered) is None
    assert referrals.resolve_cookie("garbage") is None and referrals.resolve_cookie("") is None
    # Signup with the fresh cookie (test 1): attributed via link, with the perks.
    s = sign_up(fake_smtp, "buyer@example.com", ref_cookie=fresh)
    red = db.redemption_for_customer(s.customer_id)
    assert red["code"] == "KATHLEEN" and red["attribution_source"] == "link" and not red["attribution_locked"]
    state = web_access.state(token=s.token)
    ends = datetime.fromisoformat(state["period_end"].replace("Z", "+00:00"))
    assert timedelta(days=29) < ends - datetime.now(timezone.utc) <= timedelta(days=30)          # 30-day trial (test 25)
    assert db.get_customer(s.customer_id)["proofs_free_extra"] == 7                             # 10 proofs (test 26)
    assert subscriptions.proofs_state(s.customer_id).free_granted == config.PROOFS_FREE_PROOFS + 7
    # Stale cookie: a plain signup.
    s2 = sign_up(fake_smtp, "late@example.com", ref_cookie=stale)
    assert db.redemption_for_customer(s2.customer_id) is None
    ends2 = datetime.fromisoformat(web_access.state(token=s2.token)["period_end"].replace("Z", "+00:00"))
    assert ends2 - datetime.now(timezone.utc) <= timedelta(days=config.TRIAL_DAYS)


def test_a_typed_code_beats_the_cookie_and_the_latest_touch_wins_until_first_payment(isolated_db, test_keypair, fake_smtp):
    pa, promo_a = partner("Ann", "ann@example.com", "ANN")
    pb, promo_b = partner("Ben", "ben@example.com", "BEN")
    # Cookie for A, code for B typed at signup -> B (test 2).
    s = sign_up(fake_smtp, "c@example.com", promo_code="ben", ref_cookie=referrals.cookie_value(promo_a))
    assert db.redemption_for_customer(s.customer_id)["code"] == "BEN"
    # Another touch before any payment moves it (test 4); re-applying doesn't stack proofs (test 27).
    db.set_proofs_free_extra(s.customer_id, 7)
    referrals.attribute_customer(s.customer_id, db.get_promotion(promo_a), source="link")
    assert db.redemption_for_customer(s.customer_id)["code"] == "ANN" and db.count_redemptions(promo_b) == 0
    assert db.get_customer(s.customer_id)["proofs_free_extra"] == 7
    # First payment locks it (test 5): a later touch changes nothing.
    sub = stripe_subscription(sub_id="sub_c", customer="cus_c", customer_id=s.customer_id, email="c@example.com", amount=2400)
    sub["metadata"]["promotion_id"] = str(promo_a)
    subscriptions.sync_from_stripe(sub)
    subscriptions.record_invoice({"id": "in_c", "subscription": "sub_c", "amount_paid": 2400, "currency": "usd", "created": 1_800_000_000, "customer": "cus_c"}, paid=True)
    red = db.redemption_for_customer(s.customer_id)
    assert red["attribution_locked"] and red["first_payment_at"] and red["code"] == "ANN"
    assert referrals.attribute_customer(s.customer_id, db.get_promotion(promo_b), source="code") is None
    assert db.redemption_for_customer(s.customer_id)["code"] == "ANN"
    assert db.promoter_totals(pa)["earned_cents"] == 720 and db.promoter_totals(pb)["earned_cents"] == 0


def test_self_referral_and_suspended_promoters_are_not_attributed(isolated_db, test_keypair, fake_smtp):
    pid, promo_id = partner()
    # The promoter's own email on their own code -> no redemption, an alert on the record (test 6).
    s = sign_up(fake_smtp, "kathleen@example.com", promo_code="KATHLEEN")
    assert db.redemption_for_customer(s.customer_id) is None
    assert any(e["kind"] == "promo_self_referral" for e in db.list_events_for_customer(s.customer_id))
    # A suspended promoter's code: valid to type, but not attributed (test 7); its link goes home.
    with db.connection() as conn:
        conn.execute("UPDATE promoters SET status = 'suspended' WHERE id = ?", (pid,))
    s2 = sign_up(fake_smtp, "fan@example.com", promo_code="KATHLEEN")
    assert db.redemption_for_customer(s2.customer_id) is None
    r = TestClient(app).get("/r/KATHLEEN", follow_redirects=False)
    assert r.status_code == 302 and not r.cookies.get(referrals.COOKIE_NAME)


def test_checkout_carries_the_trial_start_attribution_to_stripe(isolated_db, test_keypair, fake_smtp, monkeypatch):
    pid, promo_id = partner()
    s = sign_up(fake_smtp, "buyer@example.com", ref_cookie=referrals.cookie_value(promo_id))
    captured = {}
    class FakeSession: id = "cs_1"; url = "https://checkout.stripe.com/c/pay/cs_1"
    monkeypatch.setattr(stripe_client, "create_subscription_checkout", lambda **kw: (captured.update(kw), FakeSession())[1])
    web_access.checkout_url(token=s.token)          # no code typed at checkout
    assert captured["promotion"]["id"] == promo_id


def _invoice(sub_id, inv_id, when: datetime, amount=2400, customer="cus_t"):
    ts = int(when.timestamp())
    return {"id": inv_id, "subscription": sub_id, "amount_paid": amount, "currency": "usd", "created": ts, "customer": customer, "status_transitions": {"paid_at": ts}}


def test_commission_runs_24_months_from_first_payment_and_does_not_restart(isolated_db, test_keypair, fake_smtp):
    pid, promo_id = partner()
    cid = db.upsert_customer(name="T", email="t@example.com")
    sub = stripe_subscription(sub_id="sub_t", customer="cus_t", customer_id=cid, email="t@example.com", amount=2400)
    sub["metadata"]["promotion_id"] = str(promo_id)
    subscriptions.sync_from_stripe(sub)
    first = datetime(2026, 3, 1, 12, tzinfo=timezone.utc)
    subscriptions.record_invoice(_invoice("sub_t", "in_1", first), paid=True)
    red = db.redemption_for_customer(cid)
    assert red["first_payment_at"] == "2026-03-01T12:00:00Z" and red["term_ends_at"] == "2028-03-01T12:00:00Z"    # test 10
    subscriptions.record_invoice(_invoice("sub_t", "in_2", datetime(2028, 2, 28, 12, tzinfo=timezone.utc)), paid=True)   # accrues
    subscriptions.record_invoice(_invoice("sub_t", "in_3", datetime(2028, 3, 2, 12, tzinfo=timezone.utc)), paid=True)    # does not
    assert db.promoter_totals(pid)["payouts"] == 2 and db.promoter_totals(pid)["earned_cents"] == 1440
    # Cancel at month 8, resubscribe at month 14 (test 11): resumes, same end date, first_payment_at untouched.
    gone = dict(sub, status="canceled", ended_at=int(datetime(2026, 11, 1, tzinfo=timezone.utc).timestamp()))
    subscriptions.sync_from_stripe(gone)
    back = stripe_subscription(sub_id="sub_t2", customer="cus_t", customer_id=cid, email="t@example.com", amount=2400)
    subscriptions.sync_from_stripe(back)
    subscriptions.record_invoice(_invoice("sub_t2", "in_4", datetime(2027, 5, 1, 12, tzinfo=timezone.utc)), paid=True)
    subscriptions.record_invoice(_invoice("sub_t2", "in_5", datetime(2028, 4, 1, 12, tzinfo=timezone.utc)), paid=True)
    red = db.redemption_for_customer(cid)
    assert red["first_payment_at"] == "2026-03-01T12:00:00Z" and red["term_ends_at"] == "2028-03-01T12:00:00Z"
    assert db.promoter_totals(pid)["payouts"] == 3
    assert promotions.term_month(red, now=datetime(2026, 3, 15, tzinfo=timezone.utc)) == 1
    assert promotions.term_month(red, now=datetime(2028, 2, 15, tzinfo=timezone.utc)) == 24
    # A legacy code with no term is uncapped (test 12); a prorated invoice pays on its own amount (test 13).
    lp = db.create_promoter(name="Legacy", default_share_pct=20)
    legacy = promotions.create_promotion(code="LEGACY", kind="promoter", promoter_id=lp, percent_off=10, duration_months=None, share_pct=20)
    with db.connection() as conn: conn.execute("UPDATE promoters SET status = 'active' WHERE id = ?", (lp,))
    cid2 = db.upsert_customer(name="L", email="l@example.com")
    sub2 = stripe_subscription(sub_id="sub_l", customer="cus_l", customer_id=cid2, email="l@example.com", amount=2400)
    sub2["metadata"]["promotion_id"] = str(legacy)
    subscriptions.sync_from_stripe(sub2)
    subscriptions.record_invoice(_invoice("sub_l", "in_l1", datetime(2020, 1, 1, tzinfo=timezone.utc), customer="cus_l"), paid=True)
    subscriptions.record_invoice(_invoice("sub_l", "in_l2", datetime(2030, 1, 1, tzinfo=timezone.utc), amount=1370, customer="cus_l"), paid=True)   # prorated upgrade
    assert db.redemption_for_customer(cid2)["term_ends_at"] is None
    assert db.promoter_totals(lp)["payouts"] == 2 and db.promoter_totals(lp)["earned_cents"] == 480 + 274
    # Changing a promoter's default rate never touches an existing code's share (test 14).
    db.update_promoter(pid, name="Kathleen", email="kathleen@example.com", organization="", default_share_pct=10, notes="", active=True)
    assert db.get_promotion(promo_id)["share_pct"] == 30
