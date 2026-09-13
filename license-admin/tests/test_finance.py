"""Financials: expenses, recurring bills materialized per month, Stripe
fee/refund import (mocked), and the P&L by month / quarter / year / MTD."""

from datetime import date

from app import db, finance, stripe_client, subscriptions
from conftest import stripe_subscription


def test_pnl_combines_revenue_fees_and_expenses(isolated_db, test_keypair, monkeypatch):
    monkeypatch.setattr(stripe_client, "charge_fee_and_transaction", lambda inv: (85, "txn_1"))
    monkeypatch.setattr(stripe_client, "charge_fee_cents", lambda inv: None)
    cid = db.upsert_customer(name="A", email="a@example.com")
    subscriptions.sync_from_stripe(stripe_subscription(customer_id=cid))
    subscriptions.record_invoice({"id": "in_1", "subscription": "sub_123", "amount_paid": 1900, "currency": "usd", "charge": "ch_1", "status_transitions": {"paid_at": 1_757_000_000}}, paid=True)  # 2025-09-04
    db.add_expense(date="2025-09-10", category="Hosting", vendor="Railway", description="", amount_cents=1200)
    db.add_expense(date="2025-10-02", category="Email", vendor="Postmark", description="", amount_cents=1500)
    sept = db.period_financials(*finance.month_bounds(2025, 9))
    assert sept["revenue_cents"] == 1900 and sept["stripe_fees_cents"] == 85 and sept["net_revenue_cents"] == 1815
    assert sept["expenses_by_category"] == {"Hosting": 1200} and sept["total_expenses_cents"] == 1285 and sept["net_cents"] == 615
    q3 = db.period_financials(*finance.quarter_bounds(2025, 3))
    assert q3["net_cents"] == 615
    year = db.period_financials(*finance.year_bounds(2025))
    assert year["total_expenses_cents"] == 2785 and year["net_cents"] == 1900 - 2785
    # the payment row carries the fee
    with db.connection() as c:
        assert c.execute("SELECT fee_cents FROM payments WHERE stripe_invoice_id = 'in_1'").fetchone()[0] == 85
    # webhook replay doesn't double the fee expense
    subscriptions.record_invoice({"id": "in_1", "subscription": "sub_123", "amount_paid": 1900, "currency": "usd", "charge": "ch_1"}, paid=True)
    assert db.period_financials(*finance.month_bounds(2025, 9))["stripe_fees_cents"] == 85


def test_recurring_bills_materialize_once_per_month(isolated_db, test_keypair):
    rid = db.add_recurring_expense(vendor="Railway", category="Hosting", description="Hobby", amount_cents=500, day_of_month=1, start_month="2026-07", end_month=None)
    assert finance.materialize_recurring(through=date(2026, 9, 13)) == 3  # Jul, Aug, Sep
    assert finance.materialize_recurring(through=date(2026, 9, 13)) == 0
    assert db.period_financials(*finance.quarter_bounds(2026, 3))["expenses_by_category"] == {"Hosting": 1500}
    # a bill dated on a day that hasn't come yet isn't booked early
    db.add_recurring_expense(vendor="Postmark", category="Email", description="", amount_cents=1500, day_of_month=20, start_month="2026-09", end_month=None)
    assert finance.materialize_recurring(through=date(2026, 9, 13)) == 0
    assert finance.materialize_recurring(through=date(2026, 9, 20)) == 1
    # end month respected, and turning it off stops it
    db.update_recurring_expense(rid, amount_cents=600, active=True, end_month="2026-10")
    assert finance.materialize_recurring(through=date(2026, 12, 1)) == 3  # Railway: Oct only (ends Oct); Postmark: Oct 20, Nov 20 (Dec 20 hasn't come)
    rows = finance.report("monthly", 2026)
    assert [r["label"] for r in rows][:2] == ["January 2026", "February 2026"] and rows[-1]["is_total"]


def test_stripe_import_books_fees_and_refunds_idempotently(isolated_db, test_keypair, monkeypatch):
    txns = [
        {"id": "txn_a", "type": "charge", "fee": 85, "amount": 1900, "created": 1_757_000_000, "source": "ch_1"},
        {"id": "txn_b", "type": "stripe_fee", "fee": 0, "amount": -250, "created": 1_757_100_000, "description": "Billing fee"},
        {"id": "txn_c", "type": "refund", "fee": -85, "amount": -1900, "created": 1_757_200_000, "source": "re_1"},
        {"id": "txn_d", "type": "payout", "fee": 0, "amount": -5000, "created": 1_757_300_000},
    ]
    monkeypatch.setattr(stripe_client, "list_balance_transactions", lambda **kw: iter(txns))
    counts = finance.import_stripe_fees(start=date(2025, 9, 1), end=date(2025, 9, 30))
    assert counts["fees"] == 2 and counts["fee_cents"] == 335 and counts["refunds"] == 1 and counts["skipped"] == 1
    sept = db.period_financials(*finance.month_bounds(2025, 9))
    assert sept["stripe_fees_cents"] == 335 and sept["refunds_cents"] == 1815
    counts = finance.import_stripe_fees(start=date(2025, 9, 1), end=date(2025, 9, 30))
    assert counts["fees"] == 0 and counts["refunds"] == 0
    assert db.delete_expense(db.list_expenses("2025-09-01", "2025-09-30")[0]["id"]) is False  # imported rows stay


def test_promoter_payout_is_an_expense(isolated_db, test_keypair):
    pid = db.create_promoter(name="Jane")
    db.record_promoter_payment(promoter_id=pid, amount_cents=2500, paid_at="2026-09-13", note="PayPal")
    sept = db.period_financials(*finance.month_bounds(2026, 9))
    assert sept["expenses_by_category"] == {"Promoter payouts": 2500}
