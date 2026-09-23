"""Partner Program (docs: build spec §12): link attribution, the perks a
partner code delivers at trial start, and the rules around who may be
attributed. Stripe is mocked; time is driven through the cookie's own
timestamp."""

import re
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


def _referred(promo_id, n, *, email_domain="ref.example"):
    """n referred customers, each with an active subscription that has paid once (long ago, so the rows are payable)."""
    out = []
    for i in range(n):
        cid = db.upsert_customer(name=f"R{i}", email=f"r{i}@{email_domain}")
        sub = stripe_subscription(sub_id=f"sub_{email_domain}_{i}", customer=f"cus_{email_domain}_{i}", customer_id=cid, email=f"r{i}@{email_domain}", amount=2400)
        sub["metadata"]["promotion_id"] = str(promo_id)
        subscriptions.sync_from_stripe(sub)
        subscriptions.record_invoice(_invoice(sub["id"], f"in_{email_domain}_{i}", datetime(2026, 1, 15, tzinfo=timezone.utc), customer=sub["customer"]), paid=True)
        out.append((cid, sub))
    return out


def _window(pid, start, end):
    with db.connection() as conn:
        conn.execute("UPDATE promoters SET bounty_window_start = ?, bounty_window_end = ? WHERE id = ?", (start, end, pid))


def test_bounty_fires_once_per_customer_on_first_payment_inside_the_window(isolated_db, test_keypair, fake_smtp):
    pid, promo_id = partner()
    _window(pid, "2026-01-01", "2026-04-30")     # 120 days from 1 Jan
    cid = db.upsert_customer(name="B", email="b@example.com")
    sub = stripe_subscription(sub_id="sub_b", customer="cus_b", customer_id=cid, email="b@example.com", amount=2400)
    sub["metadata"]["promotion_id"] = str(promo_id)
    subscriptions.sync_from_stripe(sub)
    # Trial started in the window; first payment on day 119 -> awarded (tests 15/16).
    subscriptions.record_invoice(_invoice("sub_b", "in_b1", datetime(2026, 4, 29, 12, tzinfo=timezone.utc), customer="cus_b"), paid=True)
    t = db.promoter_totals(pid)
    assert t["bounty_cents"] == 1500 and t["earned_cents"] == 720 + 1500
    assert db.redemption_for_customer(cid)["bounty_payout_id"] is not None
    # A second invoice from the same customer: no second bounty (test 17).
    subscriptions.record_invoice(_invoice("sub_b", "in_b2", datetime(2026, 5, 29, 12, tzinfo=timezone.utc), customer="cus_b"), paid=True)
    assert db.promoter_totals(pid)["bounty_cents"] == 1500
    # Another customer whose first payment lands on day 121 -> no bounty (test 15).
    cid2 = db.upsert_customer(name="C", email="c@example.com")
    sub2 = stripe_subscription(sub_id="sub_c", customer="cus_c", customer_id=cid2, email="c@example.com", amount=2400)
    sub2["metadata"]["promotion_id"] = str(promo_id)
    subscriptions.sync_from_stripe(sub2)
    subscriptions.record_invoice(_invoice("sub_c", "in_c1", datetime(2026, 5, 1, 12, tzinfo=timezone.utc), customer="cus_c"), paid=True)
    assert db.promoter_totals(pid)["bounty_cents"] == 1500
    # Two customers in the window -> two bounties.
    cid3 = db.upsert_customer(name="D", email="d@example.com")
    sub3 = stripe_subscription(sub_id="sub_d", customer="cus_d", customer_id=cid3, email="d@example.com", amount=2400)
    sub3["metadata"]["promotion_id"] = str(promo_id)
    subscriptions.sync_from_stripe(sub3)
    subscriptions.record_invoice(_invoice("sub_d", "in_d1", datetime(2026, 2, 1, 12, tzinfo=timezone.utc), customer="cus_d"), paid=True)
    assert db.promoter_totals(pid)["bounty_cents"] == 3000


def test_reinstatement_at_25_active_is_permanent_and_shows_as_established(isolated_db, test_keypair, fake_smtp):
    pid, promo_id = partner()
    _window(pid, "2025-01-01", "2025-04-30")     # window long closed
    referred = _referred(promo_id, 24)
    assert db.get_promoter(pid)["bounty_reinstated_at"] is None and db.promoter_totals(pid)["bounty_cents"] == 0
    fake_smtp.sent.clear()
    _referred(promo_id, 1, email_domain="last.example")
    p = db.get_promoter(pid)
    assert p["bounty_reinstated_at"] and p["tier"] == "founding"                      # test 18/19a: derived, not stored
    assert any("Established Partner" in (m["Subject"] or "") for m in fake_smtp.sent)
    assert db.get_promotion(promo_id)["share_pct"] == 30
    # The next conversion earns the bounty although the window is closed (test 18).
    cid = db.upsert_customer(name="N", email="n@example.com")
    sub = stripe_subscription(sub_id="sub_n", customer="cus_n", customer_id=cid, email="n@example.com", amount=2400)
    sub["metadata"]["promotion_id"] = str(promo_id)
    subscriptions.sync_from_stripe(sub)
    subscriptions.record_invoice(_invoice("sub_n", "in_n", datetime.now(timezone.utc) + timedelta(days=1), customer="cus_n"), paid=True)
    assert db.promoter_totals(pid)["bounty_cents"] == 1500
    # Active count falls to 23 -> the flag persists (test 19).
    for cid_, sub_ in referred[:3]:
        subscriptions.sync_from_stripe(dict(sub_, status="canceled", ended_at=int(datetime(2026, 7, 1, tzinfo=timezone.utc).timestamp())))
    assert db.count_active_referrals(pid) == 23 and db.get_promoter(pid)["bounty_reinstated_at"]


def test_refunds_and_early_cancellation_reverse_without_touching_the_original_rows(isolated_db, test_keypair, fake_smtp):
    pid, promo_id = partner()
    _window(pid, "2026-01-01", "2026-04-30")
    def convert(tag, first: datetime):
        cid = db.upsert_customer(name=tag, email=f"{tag}@example.com")
        sub = stripe_subscription(sub_id=f"sub_{tag}", customer=f"cus_{tag}", customer_id=cid, email=f"{tag}@example.com", amount=2400)
        sub["metadata"]["promotion_id"] = str(promo_id)
        subscriptions.sync_from_stripe(sub)
        subscriptions.record_invoice(_invoice(f"sub_{tag}", f"in_{tag}", first, customer=f"cus_{tag}"), paid=True)
        return cid, sub
    first = datetime(2026, 2, 1, 12, tzinfo=timezone.utc)
    # Full refund on day 45: recurring reversed in full AND the bounty (test 20).
    cid_a, _ = convert("a", first)
    subscriptions.record_refund({"id": "ch_a", "invoice": "in_a", "amount": 2400, "amount_refunded": 2400, "created": int((first + timedelta(days=45)).timestamp())}, stripe_event_id="evt_ra")
    rows = db.list_promo_payouts_for_customer(cid_a)
    kinds = sorted((r["kind"], r["share_cents"]) for r in rows)
    assert kinds == [("bounty", 1500), ("recurring", 720), ("reversal", -1500), ("reversal", -720)]
    assert all(r["share_cents"] > 0 for r in rows if r["kind"] != "reversal")          # originals untouched (test 24)
    assert all(r["reverses_payout_id"] for r in rows if r["kind"] == "reversal")
    # Replaying the refund event reverses nothing more (test 30's shape).
    subscriptions.record_refund({"id": "ch_a", "invoice": "in_a", "amount": 2400, "amount_refunded": 2400, "created": int((first + timedelta(days=45)).timestamp())}, stripe_event_id="evt_ra")
    assert len(db.list_promo_payouts_for_customer(cid_a)) == 4
    # Full refund on day 75: recurring reversed, bounty retained (test 21).
    cid_b, _ = convert("b", first)
    subscriptions.record_refund({"id": "ch_b", "invoice": "in_b", "amount": 2400, "amount_refunded": 2400, "created": int((first + timedelta(days=75)).timestamp())}, stripe_event_id="evt_rb")
    assert sorted((r["kind"], r["share_cents"]) for r in db.list_promo_payouts_for_customer(cid_b)) == [("bounty", 1500), ("recurring", 720), ("reversal", -720)]
    # 50% partial refund -> half the share back (test 22); a chargeback is the same as a refund (test 23).
    cid_c, _ = convert("c", first)
    subscriptions.record_refund({"id": "ch_c", "invoice": "in_c", "amount": 2400, "amount_refunded": 1200, "created": int((first + timedelta(days=80)).timestamp())}, stripe_event_id="evt_rc")
    assert [r["share_cents"] for r in db.list_promo_payouts_for_customer(cid_c) if r["kind"] == "reversal"] == [-360]
    cid_d, _ = convert("d", first)
    subscriptions.record_refund({"id": "ch_d", "invoice": "in_d", "amount": 2400, "created": int((first + timedelta(days=10)).timestamp())}, stripe_event_id="evt_dd", dispute=True)
    assert sorted((r["kind"], r["share_cents"]) for r in db.list_promo_payouts_for_customer(cid_d)) == [("bounty", 1500), ("recurring", 720), ("reversal", -1500), ("reversal", -720)]
    # Early cancellation (day 30): the bounty is clawed back; the clock is untouched (R4).
    cid_e, sub_e = convert("e", first)
    subscriptions.sync_from_stripe(dict(sub_e, status="canceled", ended_at=int((first + timedelta(days=30)).timestamp())))
    red = db.redemption_for_customer(cid_e)
    assert red["first_payment_at"] == "2026-02-01T12:00:00Z" and red["term_ends_at"] == "2028-02-01T12:00:00Z"
    assert sorted((r["kind"], r["share_cents"]) for r in db.list_promo_payouts_for_customer(cid_e)) == [("bounty", 1500), ("recurring", 720), ("reversal", -1500)]
    # The ledger nets correctly (test 24): 5 × (720 + 1500) − (1500+720) − 720 − 360 − (1500+720) − 1500
    t = db.promoter_totals(pid)
    assert t["earned_cents"] == 5 * 2220 - 2220 - 720 - 360 - 2220 - 1500 and t["reversed_cents"] == 2220 + 720 + 360 + 2220 + 1500
    assert t["owed_cents"] == t["earned_cents"] and t["payable_cents"] + t["held_cents"] == t["owed_cents"]


def test_payable_waits_60_days_and_the_same_invoice_event_pays_once(isolated_db, test_keypair, fake_smtp):
    from fastapi.testclient import TestClient
    from app.main import app
    import app.main as main_mod
    pid, promo_id = partner()
    cid = db.upsert_customer(name="P", email="p@example.com")
    sub = stripe_subscription(sub_id="sub_p", customer="cus_p", customer_id=cid, email="p@example.com", amount=2400)
    sub["metadata"]["promotion_id"] = str(promo_id)
    subscriptions.sync_from_stripe(sub)
    invoice = _invoice("sub_p", "in_p", datetime.now(timezone.utc), customer="cus_p")
    # The webhook, the same event three times (test 30): one payout row.
    event = {"id": "evt_p1", "type": "invoice.paid", "data": {"object": invoice}}
    main_mod.stripe_client.construct_webhook_event = lambda payload, sig: event
    client = TestClient(app)
    for _ in range(3):
        assert client.post("/webhooks/stripe", content=b"{}", headers={"stripe-signature": "t"}).status_code == 200
    assert db.promoter_totals(pid)["payouts"] == 1
    # Booked today -> owed but held; after the clawback window -> payable (test 32's split).
    t = db.promoter_totals(pid)
    assert t["owed_cents"] == 720 and t["held_cents"] == 720 and t["payable_cents"] == 0
    later = (datetime.now(timezone.utc) + timedelta(days=61)).isoformat(timespec="seconds").replace("+00:00", "Z")
    t = db.promoter_totals(pid, now=later)
    assert t["payable_cents"] == 720 and t["held_cents"] == 0
    # An invalid signature: 400, nothing written (test 31).
    import stripe as stripe_lib
    def bad(payload, sig): raise stripe_lib.error.SignatureVerificationError("bad", sig)
    main_mod.stripe_client.construct_webhook_event = bad
    assert client.post("/webhooks/stripe", content=b"{}", headers={"stripe-signature": "x"}).status_code == 400


def test_admin_can_set_partner_details_and_approval_opens_the_window(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    from fastapi.testclient import TestClient
    from app.main import app
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        pid = db.create_promoter(name="New Partner", email="np@example.com", default_share_pct=30)
        r = client.post(f"/admin/promoters/{pid}/partner", data={"status": "active", "tier": "founding", "payout_method": "paypal", "payout_email": "pay@example.com", "tax_form_type": "w9", "tax_form_received_at": "2026-09-01"}, follow_redirects=False)
        assert r.status_code == 303, r.text
        p = db.get_promoter(pid)
        assert p["status"] == "active" and p["tier"] == "founding" and p["approved_at"] and p["bounty_window_start"] and p["payout_email"] == "pay@example.com"
        start = datetime.fromisoformat(p["bounty_window_start"]).date(); end = datetime.fromisoformat(p["bounty_window_end"]).date()
        assert (end - start).days == 120
        # 'established' can't be stored as a tier.
        r = client.post(f"/admin/promoters/{pid}/partner", data={"status": "active", "tier": "established"}, follow_redirects=False)
        assert "earned" in r.headers["location"]


# ------------------------------------------------------ Phase 2: portal ---


def _body(msg) -> str:
    part = msg.get_body(preferencelist=("plain",))
    return part.get_content() if part else ""


def test_application_lands_in_the_queue_and_approval_creates_the_code_window_and_welcome(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    from app import partners
    with TestClient(app) as client:
        # The application sits behind the program-details gate, so applicants
        # have read the terms by the time they get here.
        assert "Show me the details" in client.post("/partners/apply", data={"name": "Kathleen Reyes", "email": "kathleen@example.com"}).text
        client.post("/partners/register", data={"name": "Kathleen Reyes", "email": "kathleen@example.com"})
        # Public application: needs the terms box; a bot filling the honeypot is quietly ignored.
        r = client.post("/partners/apply", data={"name": "Kathleen Reyes", "email": "kathleen@example.com", "platforms": "YouTube", "application": "I run a 40k embroidery channel and teach classes weekly."})
        assert r.status_code == 400 and "agree" in r.text
        r = client.post("/partners/apply", data={"name": "Kathleen Reyes", "email": "kathleen@example.com", "platforms": "YouTube", "application": "I run a 40k embroidery channel and teach classes weekly.", "agree": "1"})
        assert r.status_code == 200 and "we have it" in r.text
        p = db.get_promoter_by_email("kathleen@example.com")
        assert p["status"] == "applied" and p["applied_at"] and p["tier"] == "" and fake_smtp.sent[-1]["Subject"].startswith("We got your")
        # A second application from the same address is refused kindly.
        r = client.post("/partners/apply", data={"name": "Kat", "email": "kathleen@example.com", "application": "Trying again with the same email address here.", "agree": "1"})
        assert r.status_code == 400 and "already have an application" in r.text
        # Applied partners can sign in and see their application is pending, nothing else.
        client.post("/partners/portal", data={"email": "kathleen@example.com"})
        url = _body(fake_smtp.sent[-1]).split("/partners/portal/open?token=")[1].split()[0]
        r = client.get(f"/partners/portal/open?token={url}", follow_redirects=True)
        assert "Your application is in" in r.text and "Your link and code" not in r.text
        client.post("/partners/portal/logout")

        # Admin: the queue shows it; approval sets tier, rate, window and the first code, and sends the welcome.
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        r = client.get("/admin/partners")
        assert "Kathleen Reyes" in r.text and "40k embroidery channel" in r.text and f"/admin/partners/{p['id']}/review" in r.text
        # Approving happens on the review page, after reading what they sent.
        review = client.get(f"/admin/partners/{p['id']}/review").text
        assert "40k embroidery channel" in review and "Approve &amp; send the welcome" in review
        r = client.post(f"/admin/partners/{p['id']}/approve", data={"tier": "founding", "share_pct": "", "code": "kathleen", "window_days": "120"}, follow_redirects=False)
        assert r.status_code == 303 and "approved" in r.headers["location"]
        p = db.get_promoter(p["id"])
        assert p["status"] == "active" and p["tier"] == "founding" and p["approved_at"] and float(p["default_share_pct"]) == 30
        start = datetime.fromisoformat(p["bounty_window_start"]).date(); end = datetime.fromisoformat(p["bounty_window_end"]).date()
        assert (end - start).days == 120
        promo = db.get_promotion_by_code("KATHLEEN")
        assert promo["promoter_id"] == p["id"] and promo["percent_off"] == 0 and promo["share_pct"] == 30 and promo["trial_days"] == 30 and promo["proofs_extra"] == 7 and promo["commission_months"] == 24
        welcome = fake_smtp.sent[-1]
        assert welcome["Subject"].startswith("Welcome") and "/r/KATHLEEN" in _body(welcome) and "30%" in _body(welcome) and "/partners/portal/open?token=" in _body(welcome) and "Founding partner" in _body(welcome)
        assert partners.founding_seats_left() == partners.FOUNDING_LIMIT - 1


def test_decline_closes_the_application_and_tells_them(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    from app import partners
    pid = partners.apply(name="Maybe Later", email="maybe@example.com", organization="", platforms="", application="A small group with a few hundred followers, mostly friends.")
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        r = client.post(f"/admin/partners/{pid}/decline", data={"note": "Too small for the first cohort"}, follow_redirects=False)
        assert r.status_code == 303
    p = db.get_promoter(pid)
    assert p["status"] == "closed" and not p["active"] and "Too small" in p["notes"]
    assert fake_smtp.sent[-1]["Subject"] == "About your PiperStitch partner application"
    # Closed partners can't get a portal link; the page still says "check your email".
    with TestClient(app) as client:
        n = len(fake_smtp.sent)
        r = client.post("/partners/portal", data={"email": "maybe@example.com"})
        assert r.status_code == 200 and "Check your email" in r.text and len(fake_smtp.sent) == n


def test_portal_shows_link_code_window_earnings_and_referrals_without_identity(isolated_db, test_keypair, fake_smtp, monkeypatch):
    from app import partners
    pid, promo_id = partner()
    today = datetime.now(timezone.utc).date()
    db.update_partner_fields(pid, bounty_window_start=(today - timedelta(days=40)).isoformat(), bounty_window_end=(today + timedelta(days=100)).isoformat())
    # A referral who has paid twice (first payment ~35 days ago, inside the window), and one still on trial.
    session = sign_up(fake_smtp, "jane@example.com", promo_code="KATHLEEN")
    sub = stripe_subscription(sub_id="sub_j", customer="cus_j", customer_id=session.customer_id, email="jane@example.com", amount=2400)
    subscriptions.sync_from_stripe(sub)
    first = datetime.now(timezone.utc) - timedelta(days=35)
    sub_row = db.get_subscription_by_stripe_id("sub_j")
    for i, when in enumerate((first, first + timedelta(days=30))):
        payment_id = db.record_payment(customer_id=session.customer_id, subscription_id=sub_row["id"], stripe_invoice_id=f"in_{i}", stripe_payment_intent=None, amount_cents=2400, currency="usd",
                                       paid_at=when.isoformat(timespec="seconds").replace("+00:00", "Z"), status="paid")
        promotions.record_share_for_payment(payment_id=payment_id, subscription_row=sub_row, customer_id=session.customer_id, gross_cents=2400,
                                            invoice={"status_transitions": {"paid_at": int(when.timestamp())}})
    sign_up(fake_smtp, "trial@example.com", promo_code="KATHLEEN")

    with TestClient(app) as client:
        r = client.get("/partners/portal")
        assert "Email me a link" in r.text
        client.post("/partners/portal", data={"email": "kathleen@example.com"})
        token = _body(fake_smtp.sent[-1]).split("/partners/portal/open?token=")[1].split()[0]
        r = client.get(f"/partners/portal/open?token={token}", follow_redirects=True)
        assert r.status_code == 200
        t = r.text
        # 1. code and link, with a QR.
        assert "KATHLEEN" in t and config.WEBSITE_BASE_URL + "/r/KATHLEEN" in t and "/partners/portal/qr/KATHLEEN.svg" in t
        # 2. the window countdown.
        assert "100" in t and "left in your bounty window" in t
        # 3. earnings: two $7.20 shares + one $15 bounty = $29.40 earned; nothing payable yet (under 60 days).
        assert "$29.40" in t and "Payable now" in t
        # 4. referrals: month 2 of 24 for Jane, the trial one pending -- and no identity anywhere.
        assert "month 2 of 24" in t and "starts at first payment" in t
        assert "jane@example.com" not in t and "trial@example.com" not in t and "Jane" not in t
        # 5. statements for this month, downloadable; 6. the kit with the disclosure first.
        period = datetime.now(timezone.utc).strftime("%Y-%m")
        assert f"/partners/portal/statements/{period}.csv" in t
        csv_text = client.get(f"/partners/portal/statements/{period}.csv").text
        assert "recurring" in csv_text and "bounty" in csv_text and "jane" not in csv_text.lower()
        assert t.index("Disclose, every time") < t.index("Caption drafts") and "I get a commission if you subscribe through my link" in t
        qr = client.get("/partners/portal/qr/KATHLEEN.svg")
        assert qr.status_code == 200 and qr.headers["content-type"].startswith("image/svg+xml") and "<svg" in qr.text
        assert client.get("/partners/portal/qr/NOTMINE.svg").status_code == 404
        # The link was one-time.
        assert client.get(f"/partners/portal/open?token={token}", follow_redirects=False).status_code == 400
        client.post("/partners/portal/logout")
        assert "Email me a link" in client.get("/partners/portal").text


# ------------------------------------------------ Phase 3: payout runs ---


def _pay(session, sub_id, n, *, first_days_ago, amount=2400):
    """n monthly invoices for a referred customer, the first `first_days_ago` days back."""
    sub_row = db.get_subscription_by_stripe_id(sub_id)
    first = datetime.now(timezone.utc) - timedelta(days=first_days_ago)
    for i in range(n):
        when = first + timedelta(days=30 * i)
        payment_id = db.record_payment(customer_id=session.customer_id, subscription_id=sub_row["id"], stripe_invoice_id=f"in_{sub_id}_{i}", stripe_payment_intent=None,
                                       amount_cents=amount, currency="usd", status="paid", paid_at=when.isoformat(timespec="seconds").replace("+00:00", "Z"))
        promotions.record_share_for_payment(payment_id=payment_id, subscription_row=sub_row, customer_id=session.customer_id, gross_cents=amount,
                                            invoice={"status_transitions": {"paid_at": int(when.timestamp())}})


def _mature(promoter_id):
    """Backdate the ledger so everything has cleared the 60-day window."""
    with db.connection() as conn:
        conn.execute("UPDATE promo_payouts SET created_at = ? WHERE promoter_id = ?", ((datetime.utcnow() - timedelta(days=70)).isoformat(timespec="seconds") + "Z", promoter_id))


def test_payout_run_excludes_under_minimum_and_missing_tax_form_then_pays_the_rest(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    from app import partners
    # Kathleen: $57.60 matured (8 invoices), W-9 on file -> paid.
    k_id, _ = partner()
    db.update_partner_fields(k_id, payout_email="k@pay.example", tax_form_type="w9", tax_form_received_at="2026-09-01")
    s = sign_up(fake_smtp, "jane@example.com", promo_code="KATHLEEN")
    subscriptions.sync_from_stripe(stripe_subscription(sub_id="sub_j", customer="cus_j", customer_id=s.customer_id, email="jane@example.com", amount=2400))
    _pay(s, "sub_j", 8, first_days_ago=300)
    _mature(k_id)
    # Mia: $14.40 matured -> under the $50 minimum (test 32).
    m_id, _ = partner(name="Mia", email="mia@example.com", code="MIA")
    db.update_partner_fields(m_id, payout_email="m@pay.example", tax_form_type="w9", tax_form_received_at="2026-09-01")
    s2 = sign_up(fake_smtp, "bob@example.com", promo_code="MIA")
    subscriptions.sync_from_stripe(stripe_subscription(sub_id="sub_b", customer="cus_b", customer_id=s2.customer_id, email="bob@example.com", amount=2400))
    _pay(s2, "sub_b", 2, first_days_ago=300)
    _mature(m_id)
    # Noor: $72 matured but no tax form -> held (test 33).
    n_id, _ = partner(name="Noor", email="noor@example.com", code="NOOR")
    db.update_partner_fields(n_id, payout_email="n@pay.example")
    s3 = sign_up(fake_smtp, "cy@example.com", promo_code="NOOR")
    subscriptions.sync_from_stripe(stripe_subscription(sub_id="sub_c", customer="cus_c", customer_id=s3.customer_id, email="cy@example.com", amount=2400))
    _pay(s3, "sub_c", 10, first_days_ago=300)
    _mature(n_id)

    preview = {r["promoter"]["name"]: r for r in db.payout_run_preview()}
    assert preview["Kathleen"]["eligible"] and preview["Kathleen"]["totals"]["payable_cents"] == 5760
    assert not preview["Mia"]["eligible"] and "under the $50 minimum" in preview["Mia"]["reasons"]
    assert not preview["Noor"]["eligible"] and "no tax form on file" in preview["Noor"]["reasons"]

    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        page = client.get("/admin/partners/payouts").text
        assert "$57.60" in page and "under the $50 minimum" in page and "no tax form on file" in page
        fake_smtp.sent.clear()
        # Ticking everyone still only pays Kathleen: the exclusions are rules.
        r = client.post("/admin/partners/payouts", data={"promoter_ids": [str(k_id), str(m_id), str(n_id)], "paid_at": "2026-09-30", "note": ""}, follow_redirects=False)
        assert r.status_code == 303 and "Paid+1+partner" in r.headers["location"] and "Mia" in r.headers["location"] and "Noor" in r.headers["location"]
    assert db.promoter_totals(k_id)["paid_cents"] == 5760 and db.promoter_totals(k_id)["payable_cents"] == 0
    assert db.promoter_totals(m_id)["paid_cents"] == 0 and db.promoter_totals(n_id)["paid_cents"] == 0
    payment = db.list_promoter_payments(k_id)[0]
    assert payment["amount_cents"] == 5760 and payment["note"] == "Payout run 2026-09" and payment["paid_at"] == "2026-09-30"
    receipt = fake_smtp.sent[-1]
    assert receipt["To"] == "kathleen@example.com" and "$57.60" in receipt["Subject"]
    assert any(part.get_filename() == "piperstitch-partner-statement-2026-09.csv" for part in receipt.iter_attachments())
    # The 1099 report: Kathleen is US and under $600; the CSV lists her with 'no'.
    from app import partners as p
    report = {r["name"]: r for r in p.tax_report(2026)}
    assert report["Kathleen"]["paid_cents"] == 5760 and report["Kathleen"]["us"] and not report["Kathleen"]["nec_due"]
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        csv_text = client.get("/admin/partners/1099.csv?year=2026").text
        assert "Kathleen" in csv_text and ",57.60,1,no" in csv_text
        ledger = client.get("/admin/partners/ledger?promoter_id=%d&kind=recurring" % k_id).text
        assert "in_sub_j_0" in ledger and "$57.60" in ledger
        csv_text = client.get("/admin/partners/ledger?format=csv&kind=recurring&month=" + (datetime.utcnow() - timedelta(days=70)).strftime("%Y-%m")).text
        assert csv_text.count("\n") == 21 and "in_sub_c_9" in csv_text   # header + 8 + 2 + 10 rows


def test_1099_threshold_marks_us_partners_paid_600_or_more(isolated_db, test_keypair, fake_smtp):
    from app import partners
    k_id, _ = partner()
    db.update_partner_fields(k_id, tax_form_type="w9", tax_form_received_at="2026-01-05")
    db.record_promoter_payment(promoter_id=k_id, amount_cents=350_00, paid_at="2026-03-31", note="")
    db.record_promoter_payment(promoter_id=k_id, amount_cents=250_00, paid_at="2026-06-30", note="")
    db.record_promoter_payment(promoter_id=k_id, amount_cents=999_00, paid_at="2025-12-31", note="last year")
    f_id, _ = partner(name="Freya", email="freya@example.com", code="FREYA")
    db.update_partner_fields(f_id, tax_form_type="w8ben", tax_form_received_at="2026-01-05")
    db.record_promoter_payment(promoter_id=f_id, amount_cents=700_00, paid_at="2026-05-31", note="")
    report = {r["name"]: r for r in partners.tax_report(2026)}
    assert report["Kathleen"]["paid_cents"] == 600_00 and report["Kathleen"]["nec_due"]
    assert report["Freya"]["paid_cents"] == 700_00 and report["Freya"]["over_threshold"] and not report["Freya"]["nec_due"]
    csv_text = partners.tax_report_csv(2026)
    assert ",600.00,2,yes" in csv_text and ",700.00,1,non-US" in csv_text


def test_content_log_and_alerts(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    from app import partners
    k_id, promo_id = partner()
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        r = client.post(f"/admin/promoters/{k_id}/content", data={"url": "https://youtube.com/watch?v=abc", "platform": "YouTube", "posted_at": "2026-09-20", "disclosure": "", "note": "launch video"}, follow_redirects=False)
        assert r.status_code == 303
        row = db.list_partner_content(k_id)[0]
        assert row["disclosure_present"] is None and row["checked_at"] is None
        assert partners.alerts()["unchecked_content"] == 1
        assert "not checked" in client.get(f"/admin/promoters/{k_id}").text
        r = client.post(f"/admin/promoters/{k_id}/content/{row['id']}", data={"disclosure": "no", "note": "asked to add #ad"}, follow_redirects=False)
        row = db.get_partner_content(row["id"])
        assert row["disclosure_present"] == 0 and row["checked_at"] and row["note"] == "asked to add #ad"
        assert partners.alerts()["unchecked_content"] == 0
        r = client.post(f"/admin/promoters/{k_id}/content", data={"url": "javascript:alert(1)"}, follow_redirects=False)
        assert "should+start+with" in r.headers["location"] and len(db.list_partner_content(k_id)) == 1
    # Self-referral and inactive-promoter attributions surface as alerts.
    sign_up(fake_smtp, "kathleen@example.com", promo_code="KATHLEEN")
    with db.connection() as conn:
        conn.execute("UPDATE promoters SET status = 'suspended' WHERE id = ?", (k_id,))
    sign_up(fake_smtp, "someone@example.com", promo_code="KATHLEEN")
    kinds = sorted(e["kind"] for e in partners.alerts()["events"])
    assert kinds == ["promo_inactive_promoter", "promo_self_referral"]
    # A failed webhook is kept with its reason.
    db.record_stripe_event("evt_bad", "invoice.paid", result="no customer for cus_x")
    assert partners.alerts()["webhooks"][0]["result"] == "no customer for cus_x"
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        page = client.get("/admin/partners").text
        assert "Needs a look" in page and "self-referral" in page and "inactive promoter" in page and "evt_bad" in page


# ------------------------------------------- the program details gate ---


def test_a_recruits_link_opens_the_details_and_the_form_with_nothing_to_fill_in(isolated_db, test_keypair, fake_smtp):
    """What we email a recruit must land them inside, not at the gate."""
    from app import partners
    prospect_id = partners.register_prospect(name="Dev Patel", email="dev@example.com", source="recruit")
    partners.send_outreach_step(db.get_partner_prospect(prospect_id), 1)
    body = _body(fake_smtp.sent[-1])
    program_link = body.split("/partners/program?k=")[1].split()[0]
    with TestClient(app) as guest:
        r = guest.get(f"/partners/program?k={program_link}", follow_redirects=True)
        assert "30% of every invoice" in r.text and "Show me the details" not in r.text
        # The straight-to-the-form link works the same way, and knows them.
        apply_link = partners.apply_url(prospect_id).split("?k=")[1]
    with TestClient(app) as guest:
        r = guest.get(f"/partners/apply?k={apply_link}")
        assert "Show me the details" not in r.text and 'value="dev@example.com"' in r.text and 'value="Dev Patel"' in r.text
    # An old-style token (pipes) still opens, so links already sent keep working.
    legacy = f"{prospect_id}|{datetime.now(timezone.utc).date().isoformat()}"
    legacy = f"{legacy}|{partners._program_sign(legacy)}"
    with TestClient(app) as guest:
        assert "30% of every invoice" in guest.get(f"/partners/program?k={legacy}", follow_redirects=True).text


def test_program_details_are_gated_by_registration_and_by_a_link_we_send(isolated_db, test_keypair, fake_smtp):
    from app import partners
    with TestClient(app) as client:
        # Cold: the numbers are nowhere on the page, only the registration.
        r = client.get("/partners/program")
        assert r.status_code == 200 and "Show me the details" in r.text
        assert "30%" not in r.text and "$15" not in r.text and "Signup bounty" not in r.text
        assert '<meta name="robots" content="noindex, nofollow">' in r.text
        # The terms and the application are behind the same door.
        assert "Show me the details" in client.get("/partners/terms").text
        assert "Show me the details" in client.get("/partners/apply").text
        # A bad name is refused; the email is kept so they needn't retype it.
        r = client.post("/partners/register", data={"name": "", "email": "kath@example.com"})
        assert r.status_code == 400 and "tell us your name" in r.text and "kath@example.com" in r.text
        # Registering opens it at once and mails the same link.
        r = client.post("/partners/register", data={"name": "Kathleen Reyes", "email": "Kath@Example.com ", "organization": "StitchLab", "platforms": "YouTube"}, follow_redirects=True)
        assert r.status_code == 200 and "You&rsquo;re in" in r.text
        assert "30% of every invoice" in r.text and "$15 per signup" in r.text and "Move the sliders" in r.text
        assert 'value="Kathleen Reyes"' in r.text and 'value="kath@example.com"' in r.text and 'value="StitchLab"' in r.text
        assert "50 founding seat" in r.text
        prospect = db.get_partner_prospect_by_email("kath@example.com")
        assert prospect["source"] == "self" and prospect["views"] == 1 and prospect["applied_at"] is None
        assert "The PiperStitch Partner Program" in fake_smtp.sent[-1]["Subject"]
        link = _body(fake_smtp.sent[-1]).split("/partners/program?k=")[1].split()[0]
        # The terms and the application are open to them now, prefilled.
        terms = client.get("/partners/terms").text
        assert "5. SIGNUP BOUNTY" in terms and "16. GENERAL" in terms and "independent contractor" in terms
        assert 'value="kath@example.com"' in client.get("/partners/apply").text
        # Applying is recorded against the registration.
        client.post("/partners/apply", data={"name": "Kathleen Reyes", "email": "kath@example.com", "application": "A 40k-subscriber channel about machine embroidery.", "agree": "1"})
        assert db.get_partner_prospect_by_email("kath@example.com")["applied_at"]

    # A fresh browser: the link alone opens it, and keeps working.
    with TestClient(app) as other:
        assert "Show me the details" in other.get("/partners/program").text
        r = other.get(f"/partners/program?k={link}", follow_redirects=True)
        assert "30% of every invoice" in r.text
        assert "30% of every invoice" in other.get("/partners/program").text      # the session sticks
        assert db.get_partner_prospect_by_email("kath@example.com")["views"] == 3
    # Tampered, unsigned and stale links are refused.
    with TestClient(app) as other:
        pid = db.get_partner_prospect_by_email("kath@example.com")["id"]
        assert partners.resolve_program_token(link) == pid
        assert partners.resolve_program_token(link[:-1] + ("0" if link[-1] != "0" else "1")) is None
        assert partners.resolve_program_token(f"{pid}|2026-09-22|nonsense") is None
        stale = partners.program_token(pid, at=datetime.now(timezone.utc) - timedelta(days=partners.PROGRAM_TOKEN_DAYS + 1))
        assert partners.resolve_program_token(stale) is None
        assert "Show me the details" in other.get(f"/partners/program?k={stale}").text


def test_admin_can_send_the_details_and_sees_who_looked(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        r = client.post("/admin/partners/invite", data={"name": "Dev Patel", "email": "dev@example.com", "note": "Met at the trade show"}, follow_redirects=False)
        assert r.status_code == 303 and "Invitation+sent" in r.headers["location"]
        invite = fake_smtp.sent[-1]
        assert invite["Subject"] == "An invitation to the PiperStitch Partner Program"
        link = _body(invite).split("/partners/program?k=")[1].split()[0]
        p = db.get_partner_prospect_by_email("dev@example.com")
        assert p["source"] == "invite" and p["note"] == "Met at the trade show" and p["last_seen_at"] is None
        page = client.get("/admin/partners").text
        assert "Dev Patel" in page and "invited" in page and "not yet" in page and "/partners/program?k=" in page
    with TestClient(app) as guest:
        assert "30% of every invoice" in guest.get(f"/partners/program?k={link}", follow_redirects=True).text
    assert db.get_partner_prospect_by_email("dev@example.com")["last_seen_at"]


def test_verify_email_mode_withholds_the_page_until_the_link_is_clicked(isolated_db, test_keypair, fake_smtp, monkeypatch):
    monkeypatch.setattr(config, "PARTNER_PROGRAM_VERIFY_EMAIL", True)
    with TestClient(app) as client:
        r = client.post("/partners/register", data={"name": "Cautious Sam", "email": "sam@example.com"}, follow_redirects=True)
        assert "Check your email" in r.text and "30%" not in r.text
        assert "Show me the details" in client.get("/partners/program").text
        link = _body(fake_smtp.sent[-1]).split("/partners/program?k=")[1].split()[0]
        assert "30% of every invoice" in client.get(f"/partners/program?k={link}", follow_redirects=True).text


# ------------------------------- handles, codes, kit, feedback, welcome ---


def test_an_application_carries_social_handles_and_the_review_page_shows_them(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    with TestClient(app) as client:
        client.post("/partners/register", data={"name": "Kathleen Reyes", "email": "kathleen@example.com"})
        # Saying you post publicly without giving handles is caught.
        r = client.post("/partners/apply", data={"name": "Kathleen Reyes", "email": "kathleen@example.com", "application": "A 40k-subscriber channel about machine embroidery.",
                                                 "has_social": "1", "handles": "  ", "agree": "1"})
        assert r.status_code == 400 and "handles or links" in r.text
        client.post("/partners/apply", data={"name": "Kathleen Reyes", "email": "kathleen@example.com", "platforms": "YouTube, a Facebook group",
                                             "application": "A 40k-subscriber channel about machine embroidery.",
                                             "has_social": "1", "handles": "youtube.com/@kathleenstitches\nfacebook.com/groups/hoopers", "agree": "1"})
        p = db.get_promoter_by_email("kathleen@example.com")
        assert "youtube.com/@kathleenstitches" in p["handles"] and "facebook.com/groups/hoopers" in p["handles"]
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        review = client.get(f"/admin/partners/{p['id']}/review").text
        assert 'href="https://youtube.com/@kathleenstitches"' in review and "facebook.com/groups/hoopers" in review
        assert "40k-subscriber channel" in review and "what they post is the decision" in review.lower()
        # Someone who doesn't post publicly simply has none.
        client2 = TestClient(app)
        client2.post("/partners/register", data={"name": "Quiet Sam", "email": "sam@example.com"})
        client2.post("/partners/apply", data={"name": "Quiet Sam", "email": "sam@example.com", "application": "I teach two classes a week at the local shop.", "agree": "1"})
        assert db.get_promoter_by_email("sam@example.com")["handles"] == ""


def test_a_partner_can_ask_for_a_code_and_the_admin_approves_it_on_their_terms(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    from app import partners
    pid, first_code = partner()
    db.update_partner_fields(pid, tier="founding")
    with TestClient(app) as client:
        client.post("/partners/portal", data={"email": "kathleen@example.com"})
        token = _body(fake_smtp.sent[-1]).split("/partners/portal/open?token=")[1].split()[0]
        client.get(f"/partners/portal/open?token={token}")
        # The house rules: our own name is out, and so is a code someone already holds.
        r = client.post("/partners/portal/codes", data={"code": "piperstitch-deal", "reason": "YouTube"}, follow_redirects=False)
        assert "too+close+to+our+own+name" in r.headers["location"]
        r = client.post("/partners/portal/codes", data={"code": "KATHLEEN", "reason": "YouTube"}, follow_redirects=False)
        assert "already+taken" in r.headers["location"]
        r = client.post("/partners/portal/codes", data={"code": "kathleen-yt", "reason": "My YouTube channel"}, follow_redirects=False)
        assert "KATHLEEN-YT" in r.headers["location"]
        req = db.list_code_requests(promoter_id=pid)[0]
        assert req["requested_code"] == "KATHLEEN-YT" and req["status"] == "pending" and req["reason"] == "My YouTube channel"
        assert "with us" in client.get("/partners/portal").text

        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        assert "KATHLEEN-YT" in client.get("/admin/partners").text
        fake_smtp.sent.clear()
        r = client.post(f"/admin/partners/codes/{req['id']}", data={"decision": "approve", "code": "KATHLEEN-YT"}, follow_redirects=False)
        assert r.status_code == 303 and "live" in r.headers["location"]
    # The new code carries their rate and the same audience offer as their first.
    new = db.get_promotion_by_code("KATHLEEN-YT")
    old = db.get_promotion_by_code("KATHLEEN")
    assert new["promoter_id"] == pid and new["share_pct"] == old["share_pct"] and new["percent_off"] == 0
    assert new["trial_days"] == old["trial_days"] and new["proofs_extra"] == old["proofs_extra"] and new["commission_months"] == 24
    assert db.list_code_requests(promoter_id=pid)[0]["status"] == "approved"
    assert "KATHLEEN-YT" in fake_smtp.sent[-1]["Subject"] and "/r/KATHLEEN-YT" in _body(fake_smtp.sent[-1])

    # Declining needs a reason, and the partner is told it.
    with TestClient(app) as client:
        client.post("/partners/portal", data={"email": "kathleen@example.com"})
        token = _body(fake_smtp.sent[-1]).split("/partners/portal/open?token=")[1].split()[0]
        client.get(f"/partners/portal/open?token={token}")
        client.post("/partners/portal/codes", data={"code": "SEWFREE", "reason": "Instagram"})
        req = db.list_code_requests(promoter_id=pid, status="pending")[0]
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        r = client.post(f"/admin/partners/codes/{req['id']}", data={"decision": "decline", "note": ""}, follow_redirects=False)
        assert "Say+why" in r.headers["location"] and db.get_code_request(req["id"])["status"] == "pending"
        client.post(f"/admin/partners/codes/{req['id']}", data={"decision": "decline", "note": "It reads like a giveaway"})
    assert db.get_code_request(req["id"])["status"] == "declined"
    assert db.get_promotion_by_code("SEWFREE") is None
    assert "It reads like a giveaway" in _body(fake_smtp.sent[-1])


def test_partners_can_send_product_feedback_and_the_admin_sees_it(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    from app import partners
    pid, _ = partner()
    with TestClient(app) as client:
        client.post("/partners/portal", data={"email": "kathleen@example.com"})
        token = _body(fake_smtp.sent[-1]).split("/partners/portal/open?token=")[1].split()[0]
        page = client.get(f"/partners/portal/open?token={token}", follow_redirects=True).text
        assert "Tell us what to fix" in page and "changed this product more than any survey" in page
        r = client.post("/partners/portal/feedback", data={"topic": "Caps", "message": "too short"}, follow_redirects=False)
        assert "little+more" in r.headers["location"]
        fake_smtp.sent.clear()
        client.post("/partners/portal/feedback", data={"topic": "Caps", "message": "Three people this week asked why the cap centre line moves when they change hoops."})
        row = db.list_partner_feedback(promoter_id=pid)[0]
        assert row["topic"] == "Caps" and "centre line moves" in row["message"] and row["reviewed_at"] is None
        assert db.count_unreviewed_partner_feedback() == 1
        assert "Partner feedback from Kathleen" in fake_smtp.sent[-1]["Subject"]
        assert "centre line moves" in client.get("/partners/portal").text

        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        page = client.get("/admin/partners").text
        assert "centre line moves" in page and "unread note" in page
        client.post(f"/admin/partner-feedback/{row['id']}/reviewed")
        assert db.count_unreviewed_partner_feedback() == 0
        assert "unread note" not in client.get("/admin/partners").text


def test_the_kit_shows_the_videos_the_admin_publishes(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    pid, _ = partner()
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        assert client.post("/admin/partners/resources", data={"title": "Bad link", "url": "ftp://nope", "kind": "video"},
                           follow_redirects=False).headers["location"].count("should+start+with") == 1
        client.post("/admin/partners/resources", data={"title": "Digitizing a cap logo", "url": "https://youtu.be/abc123", "kind": "video",
                                                       "description": "Two minutes, start to finished file", "sort_order": "1"})
        client.post("/admin/partners/resources", data={"title": "Old cut", "url": "https://youtu.be/old", "kind": "video", "sort_order": "2"})
        mine = [r for r in db.list_partner_resources() if "youtu.be" in r["url"]]
        assert [r["title"] for r in mine] == ["Digitizing a cap logo", "Old cut"]       # our own films are seeded alongside
        client.post(f"/admin/partners/resources/{mine[1]['id']}", data={"title": "Old cut", "url": "https://youtu.be/old", "kind": "video", "sort_order": "2", "active": ""})
    with TestClient(app) as portal:
        portal.post("/partners/portal", data={"email": "kathleen@example.com"})
        token = _body(fake_smtp.sent[-1]).split("/partners/portal/open?token=")[1].split()[0]
        page = portal.get(f"/partners/portal/open?token={token}", follow_redirects=True).text
        assert "Videos and downloads" in page and "Digitizing a cap logo" in page and "youtu.be/abc123" in page
        assert "Old cut" not in page                      # unticked, so not shown to partners
        assert "The Partner Program, in two minutes" in page                # ...and ours sit alongside it


def test_the_welcome_email_reads_as_joining_the_team_and_explains_the_ftc(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    from app import partners
    pid = partners.apply(name="Kathleen Reyes", email="kathleen@example.com", organization="", platforms="YouTube", application="A 40k-subscriber embroidery channel.")
    assert "everything you need in it" in _body(fake_smtp.sent[-1]) or "partner package has everything" in _body(fake_smtp.sent[-1])
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        client.post(f"/admin/partners/{pid}/approve", data={"tier": "founding", "code": "KATHLEEN", "window_days": "120"})
    welcome = fake_smtp.sent[-1]
    body = _body(welcome)
    assert welcome["Subject"] == "Welcome to the PiperStitch team, Kathleen"
    assert "You're in" not in body and "Welcome to the PiperStitch team" in body
    assert "Federal Trade Commission (FTC)" in body
    assert "What does NOT count" in body and '"affiliate link" on its own' in body
    assert "feedback box in your portal" in body
    html = welcome.get_body(preferencelist=("html",)).get_content()
    assert "piper-congratulations.png" in html          # Piper's confetti, as the congratulations


# ----------------------- tax forms, kit announcements, recruitment (§8) ---


def test_a_partner_sends_their_tax_form_and_payout_details_and_payouts_wait_for_review(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    from app import partners
    pid, _ = partner()
    with TestClient(app) as client:
        client.post("/partners/portal", data={"email": "kathleen@example.com"})
        token = _body(fake_smtp.sent[-1]).split("/partners/portal/open?token=")[1].split()[0]
        page = client.get(f"/partners/portal/open?token={token}", follow_redirects=True).text
        assert "Getting paid" in page and "exactly as it appears on that PayPal account" in page and "W-9" in page
        # PayPal needs both the address and the name on the account.
        r = client.post("/partners/portal/payout", data={"method": "paypal", "payout_email": "not-an-email", "payout_name": "Kathleen Reyes"}, follow_redirects=False)
        assert "PayPal+account" in r.headers["location"]
        r = client.post("/partners/portal/payout", data={"method": "paypal", "payout_email": "pay@example.com", "payout_name": ""}, follow_redirects=False)
        assert "exactly+as+it+appears" in r.headers["location"]
        client.post("/partners/portal/payout", data={"method": "paypal", "payout_email": "Pay@Example.com", "payout_name": "Kathleen Reyes", "payout_country": "United States"})
        p = db.get_promoter(pid)
        assert p["payout_email"] == "pay@example.com" and p["payout_name"] == "Kathleen Reyes" and p["payout_country"] == "United States"

        # The form itself: type and size are checked.
        r = client.post("/partners/portal/tax-form", data={"kind": "w9"}, files={"document": ("form.exe", b"MZ", "application/x-msdownload")}, follow_redirects=False)
        assert "PDF" in r.headers["location"].replace("+", " ")
        r = client.post("/partners/portal/tax-form", data={"kind": "w9"}, files={"document": ("big.pdf", b"x" * (partners.MAX_DOCUMENT_BYTES + 1), "application/pdf")}, follow_redirects=False)
        assert "limit+is+8+MB" in r.headers["location"]
        client.post("/partners/portal/tax-form", data={"kind": "w9"}, files={"document": ("w9.pdf", b"%PDF-1.4 signed", "application/pdf")})
        doc = db.list_partner_documents(pid)[0]
        assert doc["kind"] == "w9" and doc["accepted_at"] is None and db.count_pending_partner_documents() == 1
        assert "with us" in client.get("/partners/portal").text

    # Uploading is not the same as accepted: the payout run still holds them.
    _fill_ledger(pid)
    row = {r["promoter"]["id"]: r for r in db.payout_run_preview()}[pid]
    assert not row["eligible"] and "tax form awaiting review" in row["reasons"]

    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        assert "tax form" in client.get("/admin/partners").text
        assert client.get(f"/admin/partner-documents/{doc['id']}").content == b"%PDF-1.4 signed"
        # Sending it back needs a reason, and tells them.
        r = client.post(f"/admin/partner-documents/{doc['id']}", data={"decision": "reject", "note": ""}, follow_redirects=False)
        assert "Say+what" in r.headers["location"]
        client.post(f"/admin/partner-documents/{doc['id']}", data={"decision": "reject", "note": "Page 2 isn't signed"})
        assert db.get_promoter(pid)["tax_form_received_at"] is None
        assert "Page 2 isn't signed" in _body(fake_smtp.sent[-1])
        # Accepting is what unblocks the money.
        client.post("/partners/portal", data={"email": "kathleen@example.com"})
        client.post(f"/admin/partner-documents/{doc['id']}", data={"decision": "accept"})
    p = db.get_promoter(pid)
    assert p["tax_form_received_at"] and p["tax_form_type"] == "w9"
    assert db.payout_run_preview() and {r["promoter"]["id"]: r for r in db.payout_run_preview()}[pid]["eligible"]


def _fill_ledger(promoter_id):
    """Enough matured commission on the partner to be payable."""
    with db.connection() as conn:
        promo = db.get_promotion_by_code("KATHLEEN")
        conn.execute("INSERT INTO promo_payouts (promoter_id, promotion_id, customer_id, payment_id, gross_cents, fee_cents, net_cents, share_pct, share_cents, kind, created_at) "
                     "VALUES (?, ?, NULL, NULL, 24000, 0, 24000, 30, 7200, 'recurring', ?)",
                     (promoter_id, promo["id"], (datetime.utcnow() - timedelta(days=70)).isoformat(timespec="seconds") + "Z"))


def test_a_new_kit_item_tells_every_partner_with_a_link_to_it(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    from app import partners
    a_id, _ = partner()
    b_id, _ = partner(name="Mia", email="mia@example.com", code="MIA")
    partner(name="Gone", email="gone@example.com", code="GONE", status="closed")
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        fake_smtp.sent.clear()
        client.post("/admin/partners/resources", data={"title": "Digitizing a cap logo", "url": "https://youtu.be/abc123", "kind": "video",
                                                       "description": "Two minutes, start to finished file", "sort_order": "1", "announce": "1"})
        assert fake_smtp.sent == []                       # queued, not sent in the request
        assert partners.announcements_check() == 2        # the scheduler does the sending
        told = {m["To"] for m in fake_smtp.sent}
        assert told == {"kathleen@example.com", "mia@example.com"}          # not the closed one
        note = fake_smtp.sent[-1]
        assert note["Subject"] == "New in your partner kit: Digitizing a cap logo"
        assert "https://youtu.be/abc123" in _body(note) and "Two minutes, start to finished file" in _body(note)
        item = db.list_partner_resources()[0]
        assert item["announced_at"]
        # Adding quietly is possible, and telling them later is a button.
        fake_smtp.sent.clear()
        client.post("/admin/partners/resources", data={"title": "Quiet one", "url": "https://youtu.be/quiet", "kind": "video", "sort_order": "2"})
        assert fake_smtp.sent == []
        quiet = [r for r in db.list_partner_resources() if r["title"] == "Quiet one"][0]
        assert quiet["announced_at"] is None
        client.post(f"/admin/partners/resources/{quiet['id']}/announce")
        assert fake_smtp.sent == [] and partners.announcements_check() == 2
        assert len(fake_smtp.sent) == 2 and db.get_partner_resource(quiet["id"])["announced_at"]
        assert partners.announcements_check() == 0        # and not again


def test_recruitment_runs_itself_from_a_pasted_list_and_tracks_everything(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    from app import partners
    partner(name="Already In", email="already@example.com", code="ALREADY")
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        r = client.post("/admin/partners/recruit", data={"people": "nonsense", "note": ""}, follow_redirects=False)
        assert "Nothing+to+send+to" in r.headers["location"]
        fake_smtp.sent.clear()
        r = client.post("/admin/partners/recruit", data={
            "people": "Kathleen Reyes <kathleen@example.com>\nDev Patel, dev@example.com\nAlready In, already@example.com\nrubbish",
            "note": "Speaks at the guild"}, follow_redirects=False)
        loc = r.headers["location"]
        assert "Started+2+approaches" in loc and "already%40example.com" in loc and "already+active" in loc and "Couldn%27t+read+1" in loc
    # The first email goes at once; the rest are queued.
    assert {m["To"] for m in fake_smtp.sent} == {"kathleen@example.com", "dev@example.com"}
    first = [m for m in fake_smtp.sent if m["To"] == "kathleen@example.com"][0]
    assert "Kathleen" in first["Subject"] and "/partners/program?k=" in _body(first) and "/partners/no-thanks?k=" in _body(first)
    # Cold mail: who we are and where we are, in both parts (CAN-SPAM).
    html = first.get_body(preferencelist=("html",)).get_content()
    for part in (_body(first), html):
        assert config.LEGAL_NAME in part and config.POSTAL_ADDRESS in part and config.REPLY_TO_EMAIL in part
    assert "/partners/no-thanks?k=" in html
    kath = db.get_partner_prospect_by_email("kathleen@example.com")
    assert kath["source"] == "recruit" and kath["outreach_status"] == "active" and kath["outreach_step"] == 1 and kath["note"] == "Speaks at the guild"
    assert db.list_outreach_log(kath["id"])[0]["status"] == "sent"

    # Nothing more is due yet; when it is, the next step goes.
    assert partners.outreach_check() == 0
    assert partners.outreach_check(now=datetime.now(timezone.utc) + timedelta(days=4)) == 2
    assert db.get_partner_prospect_by_email("kathleen@example.com")["outreach_step"] == 2

    # The link has to survive an email client: no characters that a mail
    # client would truncate the auto-link at, and it opens the details
    # with nothing to fill in again.
    link = _body(first).split("/partners/program?k=")[1].split()[0]
    assert "|" not in link and "%7C" not in link and " " not in link
    assert re.match(r"^[A-Za-z0-9._~-]+$", link), link
    with TestClient(app) as guest:
        assert "30% of every invoice" in guest.get(f"/partners/program?k={link}", follow_redirects=True).text
    kath = db.get_partner_prospect_by_email("kathleen@example.com")
    assert kath["views"] == 1 and kath["last_seen_at"]

    # Applying stops the sequence.
    with TestClient(app) as guest:
        guest.get(f"/partners/program?k={link}")
        guest.post("/partners/apply", data={"name": "Kathleen Reyes", "email": "kathleen@example.com", "application": "A 40k-subscriber embroidery channel.", "agree": "1"})
    kath = db.get_partner_prospect_by_email("kathleen@example.com")
    assert kath["applied_at"] and kath["outreach_status"] == "done"
    assert partners.outreach_check(now=datetime.now(timezone.utc) + timedelta(days=30)) == 1     # only Dev is left

    # One click says no, and we stop for good.
    dev = db.get_partner_prospect_by_email("dev@example.com")
    with TestClient(app) as guest:
        r = guest.get(f"/partners/no-thanks?k={partners.program_token(dev['id'])}")
        assert r.status_code == 200 and "we&rsquo;ll stop" in r.text
    dev = db.get_partner_prospect_by_email("dev@example.com")
    assert dev["outreach_status"] == "opted_out" and dev["opted_out_at"]
    assert partners.outreach_check(now=datetime.now(timezone.utc) + timedelta(days=60)) == 0
    # ...and a second attempt to recruit them is refused.
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        r = client.post("/admin/partners/recruit", data={"people": "Dev Patel, dev@example.com"}, follow_redirects=False)
        assert "asked+not+to+be+contacted" in r.headers["location"]
        page = client.get("/admin/partners").text
        assert "Recruit partners" in page and "Dev Patel" in page and "said no" in page


def test_the_partner_emails_are_editable_on_the_emails_page(isolated_db, test_keypair, fake_smtp, admin_password_configured):
    from app import partners
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        page = client.get("/admin/emails").text
        # Three groups: the customers' emails, the recruitment series in order, and the rest of the partner ones.
        assert "Customer emails" in page and "Partner recruitment series" in page and "Partner emails" in page
        for step in partners.OUTREACH_STEPS:
            assert f"/admin/emails/system/{step['key']}" in page
        assert "sent at once" in page and "+16 days" in page
        for key in ("partner_welcome", "partner_applied", "partner_kit_item", "partner_paid", "partner_code_ready"):
            assert f"/admin/emails/system/{key}" in page
        assert page.index("Partner recruitment series") < page.index("Partner emails")
        # ...and they edit like any other, keeping the edit through a reseed.
        r = client.get("/admin/emails/system/partner_outreach_1")
        assert r.status_code == 200 and "{opt_out_url}" in r.text
        client.post("/admin/emails/system/partner_outreach_1", data={
            "subject": "A word about PiperStitch, {first_name}", "body": "Hi {first_name},\n\nThe details: {url}\nNo thanks: {opt_out_url}",
            "cta_label": "See the details", "cta_url": "{url}", "preheader": "A word about PiperStitch."})
        assert db.get_email_template("partner_outreach_1")["edited"] == 1
        client.get("/admin/emails")                                     # reseeds; must not stamp on the edit
        assert db.get_email_template("partner_outreach_1")["subject"] == "A word about PiperStitch, {first_name}"
        assert "edited" in client.get("/admin/emails").text
    # The edited version is what goes out.
    prospect_id = partners.register_prospect(name="Dev Patel", email="dev@example.com", source="recruit")
    partners.send_outreach_step(db.get_partner_prospect(prospect_id), 1)
    assert fake_smtp.sent[-1]["Subject"] == "A word about PiperStitch, Dev"


def test_a_recruits_page_shows_the_sequence_resends_any_email_and_keeps_their_reply(isolated_db, test_keypair, fake_smtp, admin_password_configured, monkeypatch):
    from app import partners
    prospect_id = partners.register_prospect(name="Dev Patel", email="dev@example.com", source="recruit")
    db.set_prospect_outreach(prospect_id, outreach_status="active", outreach_next_at=db.now_iso())
    partners.send_outreach_step(db.get_partner_prospect(prospect_id), 1)
    with TestClient(app) as client:
        client.post("/admin/login", data={"username": "admin", "password": admin_password_configured})
        page = client.get(f"/admin/partners/recruit/{prospect_id}").text
        assert "Dev Patel" in page and "1 of 4" in page and "Where they are in the sequence" in page
        assert "sent" in page and "next" in page                     # step 1 sent, step 2 next
        # Resending step 1 doesn't disturb the schedule.
        before = db.get_partner_prospect(prospect_id)
        fake_smtp.sent.clear()
        client.post(f"/admin/partners/recruit/{prospect_id}/send/1")
        after = db.get_partner_prospect(prospect_id)
        assert len(fake_smtp.sent) == 1 and after["outreach_step"] == before["outreach_step"] == 1
        assert after["outreach_next_at"] == before["outreach_next_at"]
        # Sending a later one "and continuing from here" does move it on.
        client.post(f"/admin/partners/recruit/{prospect_id}/send/2", data={"advance": "1"})
        assert db.get_partner_prospect(prospect_id)["outreach_step"] == 2

        # A reply: saved, shown, and the sequence pauses.
        client.post(f"/admin/partners/recruit/{prospect_id}/reply", data={"subject": "Re: PiperStitch", "body": "Interested — can I try it on a customer's cap logo first?"})
        p = db.get_partner_prospect(prospect_id)
        assert p["outreach_status"] == "replied" and p["outreach_next_at"] is None
        assert partners.outreach_check(now=datetime.now(timezone.utc) + timedelta(days=30)) == 0
        page = client.get(f"/admin/partners/recruit/{prospect_id}").text
        assert "cap logo first" in page and "they wrote" in page and "held" in page
        assert "Dev Patel" in client.get("/admin/partners").text and "wrote back" in client.get("/admin/partners").text
        # Resuming picks up where it left off.
        client.post(f"/admin/partners/recruit/{prospect_id}/resume")
        assert db.get_partner_prospect(prospect_id)["outreach_status"] == "active"
        assert partners.outreach_check() == 1                        # step 3 goes

    # The inbound hook: off without a token, and only for people we wrote to.
    with TestClient(app) as client:
        assert client.post("/webhooks/inbound-email/anything", json={}).status_code == 404
        monkeypatch.setattr(config, "INBOUND_EMAIL_TOKEN", "hook-secret")
        assert client.post("/webhooks/inbound-email/wrong", json={}).status_code == 404
        r = client.post("/webhooks/inbound-email/hook-secret", json={
            "FromFull": {"Email": "Dev@Example.com"}, "Subject": "Re: PiperStitch", "StrippedTextReply": "Go on then, send the link again."})
        assert r.status_code == 200 and r.json()["matched"] is True
        r = client.post("/webhooks/inbound-email/hook-secret", json={"From": "Someone Else <nobody@example.com>", "TextBody": "unrelated"})
        assert r.json()["matched"] is False
    assert db.count_outreach_replies(prospect_id) == 2
    assert db.get_partner_prospect(prospect_id)["outreach_status"] == "replied"
    assert "Go on then" in [e["body"] for e in partners.recruit_timeline(db.get_partner_prospect(prospect_id))][-1]


def test_the_first_recruitment_email_leads_with_seeing_it_and_the_video_opens_without_a_form(isolated_db, test_keypair, fake_smtp):
    from app import partners
    prospect_id = partners.register_prospect(name="Dev Patel", email="dev@example.com", source="recruit")
    partners.send_outreach_step(db.get_partner_prospect(prospect_id), 1)
    note = fake_smtp.sent[-1]
    body = _body(note)
    # It opens on seeing and trying it, not on the money.
    assert "two minutes" in note["Subject"]
    assert body.index("/partners/video?k=") < body.index("/partners/program?k=")
    assert f"{config.WEB_APP_URL}/?trial=1" in body and "no card" in body
    assert "/partners/no-thanks?k=" in body
    # The film itself plays without registering, and counts as a look.
    link = body.split("/partners/video?k=")[1].split()[0]
    with TestClient(app) as guest:
        r = guest.get(f"/partners/video?k={link}")
        assert r.status_code == 200 and "Dev, here it is in two minutes" in r.text
        assert "Show me the details" not in r.text
        assert "/assets/video/piperstitch-partner-program.mp4" in r.text
        # ...and the details are one click on from there, still no form.
        assert "30% of every invoice" in guest.get("/partners/program", follow_redirects=True).text
    assert db.get_partner_prospect(prospect_id)["views"] >= 1


def test_the_films_are_in_every_partner_kit(isolated_db, test_keypair, fake_smtp):
    from app import partners
    partner()
    partners.seed_kit()
    partners.seed_kit()                                   # seeding twice must not double them
    videos = [r for r in db.list_partner_resources() if r["kind"] == "video"]
    assert len(videos) == 3 and all(r["url"].endswith(".mp4") for r in videos)
    assert [r["title"] for r in videos] == [v["title"] for v in partners.KIT_VIDEOS]
    with TestClient(app) as portal:
        portal.post("/partners/portal", data={"email": "kathleen@example.com"})
        token = _body(fake_smtp.sent[-1]).split("/partners/portal/open?token=")[1].split()[0]
        page = portal.get(f"/partners/portal/open?token={token}", follow_redirects=True).text
        assert "The Partner Program, in two minutes" in page and "piperstitch-animated-introduction.mp4" in page
