"""The Financials page's brain: monthly / quarterly / annual /
month-to-date profit-and-loss built from paid invoices (revenue),
Stripe's own fees and refunds (imported from Stripe's balance
transactions), promoter payouts (the ledger), and expenses the admin
enters -- one-off or recurring monthly bills like hosting and email,
which are materialized into each month automatically.

Railway, Postmark and GoDaddy don't publish invoices through an API in
dollars, so those are recurring entries the admin sets once and adjusts
when a bill differs; Stripe is imported exactly."""

from __future__ import annotations

import calendar
import logging
from datetime import date, datetime, timezone
from typing import Optional

import stripe

from . import config, db, stripe_client

log = logging.getLogger("license_admin")


# ------------------------------------------------------------- periods ---


def month_bounds(year: int, month: int) -> tuple[str, str]:
    last = calendar.monthrange(year, month)[1]
    return f"{year:04d}-{month:02d}-01", f"{year:04d}-{month:02d}-{last:02d}"


def quarter_bounds(year: int, quarter: int) -> tuple[str, str]:
    m1 = (quarter - 1) * 3 + 1
    return month_bounds(year, m1)[0], month_bounds(year, m1 + 2)[1]


def year_bounds(year: int) -> tuple[str, str]:
    return f"{year:04d}-01-01", f"{year:04d}-12-31"


def today() -> date:
    return datetime.now(timezone.utc).date()


def report(view: str, year: int) -> list[dict]:
    """Rows for the chosen view. 'mtd' is one row (1st of this month to
    today) with last month for comparison; 'monthly' is the 12 months of
    the year; 'quarterly' its 4 quarters; 'annual' every year with data."""
    materialize_recurring(through=today())
    rows: list[dict] = []
    t = today()
    if view == "mtd":
        start = f"{t.year:04d}-{t.month:02d}-01"
        row = db.period_financials(start, t.isoformat()); row["label"] = f"{t.strftime('%B %Y')} to date ({t.day} day{'s' if t.day != 1 else ''})"
        rows.append(row)
        py, pm = (t.year, t.month - 1) if t.month > 1 else (t.year - 1, 12)
        prev = db.period_financials(*month_bounds(py, pm)); prev["label"] = f"{date(py, pm, 1).strftime('%B %Y')} (full month)"
        rows.append(prev)
    elif view == "quarterly":
        for q in range(1, 5):
            row = db.period_financials(*quarter_bounds(year, q)); row["label"] = f"Q{q} {year}"; rows.append(row)
        total = db.period_financials(*year_bounds(year)); total["label"] = f"{year} total"; total["is_total"] = True; rows.append(total)
    elif view == "annual":
        first = _first_year() or t.year
        for y in range(first, t.year + 1):
            row = db.period_financials(*year_bounds(y)); row["label"] = str(y); rows.append(row)
    else:  # monthly
        for m in range(1, 13):
            row = db.period_financials(*month_bounds(year, m)); row["label"] = date(year, m, 1).strftime("%B %Y"); rows.append(row)
        total = db.period_financials(*year_bounds(year)); total["label"] = f"{year} total"; total["is_total"] = True; rows.append(total)
    return rows


def _first_year() -> Optional[int]:
    with db.connection() as conn:
        p = conn.execute("SELECT MIN(substr(paid_at, 1, 4)) FROM payments WHERE paid_at IS NOT NULL").fetchone()[0]
        e = conn.execute("SELECT MIN(substr(date, 1, 4)) FROM expenses").fetchone()[0]
    years = [int(v) for v in (p, e) if v]
    return min(years) if years else None


# ------------------------------------------------------- recurring bills ---


def materialize_recurring(*, through: date) -> int:
    """Creates this month's (and any missed months') expense rows for each
    active recurring bill. Idempotent via external_id rec:<id>:<YYYY-MM>."""
    created = 0
    for r in db.list_recurring_expenses():
        if not r["active"]:
            continue
        y, m = (int(x) for x in r["start_month"].split("-"))
        end_month = r["end_month"]
        while (y, m) <= (through.year, through.month):
            ym = f"{y:04d}-{m:02d}"
            if end_month and ym > end_month:
                break
            day = min(int(r["day_of_month"] or 1), calendar.monthrange(y, m)[1])
            billed = date(y, m, day)
            if billed <= through:
                if db.add_expense(date=billed.isoformat(), category=r["category"], vendor=r["vendor"], description=r["description"] or "Monthly",
                                  amount_cents=r["amount_cents"], source="recurring", external_id=f"rec:{r['id']}:{ym}", recurring_id=r["id"]) is not None:
                    created += 1
            y, m = (y, m + 1) if m < 12 else (y + 1, 1)
    return created


# ------------------------------------------------------- Stripe import ---


def import_stripe_fees(*, start: date, end: date) -> dict:
    """Pulls Stripe's balance transactions for the dates and books every
    fee (on charges, on payouts, Stripe's own billing) and every refund
    as expenses, keyed by the transaction id so re-running never doubles.
    Also fills each payment's exact fee where the charge can be matched."""
    counts = {"fees": 0, "refunds": 0, "skipped": 0, "fee_cents": 0, "refund_cents": 0}
    since = int(datetime(start.year, start.month, start.day, tzinfo=timezone.utc).timestamp())
    until = int(datetime(end.year, end.month, end.day, 23, 59, 59, tzinfo=timezone.utc).timestamp())
    for txn in stripe_client.list_balance_transactions(since_ts=since, until_ts=until):
        when = datetime.fromtimestamp(txn["created"], tz=timezone.utc).date().isoformat()
        kind = txn.get("type")
        fee = int(txn.get("fee") or 0)
        if kind in ("charge", "payment") and fee > 0:
            new = db.add_expense(date=when, category="Stripe fees", vendor="Stripe", description=f"Processing fee on {txn.get('source') or txn['id']}", amount_cents=fee, source="stripe", external_id=txn["id"])
            if new is not None:
                counts["fees"] += 1; counts["fee_cents"] += fee
            _attach_fee_to_payment(txn, fee)
        elif kind == "stripe_fee":
            amount = abs(int(txn.get("amount") or 0))
            new = db.add_expense(date=when, category="Stripe fees", vendor="Stripe", description=txn.get("description") or "Stripe fee", amount_cents=amount, source="stripe", external_id=txn["id"])
            if new is not None:
                counts["fees"] += 1; counts["fee_cents"] += amount
        elif kind in ("refund", "payment_refund"):
            amount = abs(int(txn.get("amount") or 0))
            # Stripe returns the processing fee on a refund (fee is negative).
            new = db.add_expense(date=when, category="Refunds", vendor="Stripe", description=f"Refund {txn.get('source') or txn['id']}", amount_cents=amount + int(txn.get("fee") or 0), source="stripe", external_id=txn["id"])
            if new is not None:
                counts["refunds"] += 1; counts["refund_cents"] += amount
        else:
            counts["skipped"] += 1
    return counts


def _attach_fee_to_payment(txn: dict, fee: int) -> None:
    """Matches a charge's balance transaction to our payment row via the
    charge id we may have stored, so the customer page shows the net."""
    source = txn.get("source")
    if not isinstance(source, str):
        return
    with db.connection() as conn:
        row = conn.execute("SELECT id FROM payments WHERE balance_transaction_id = ? OR stripe_payment_intent = ?", (txn["id"], source)).fetchone()
    if row:
        db.set_payment_fee(row["id"], fee_cents=fee, balance_transaction_id=txn["id"])


def record_fee_for_invoice(*, payment_id: int, invoice: dict, gross_cents: int) -> None:
    """At invoice.paid time: book the fee immediately when Stripe gives us
    the charge; the periodic import catches anything it couldn't."""
    fee, bt_id = stripe_client.charge_fee_and_transaction(invoice)
    if fee is None:
        return
    db.set_payment_fee(payment_id, fee_cents=fee, balance_transaction_id=bt_id)
    if fee > 0:
        paid_at = invoice.get("status_transitions", {}).get("paid_at") or invoice.get("created")
        when = datetime.fromtimestamp(int(paid_at), tz=timezone.utc).date().isoformat() if paid_at else today().isoformat()
        db.add_expense(date=when, category="Stripe fees", vendor="Stripe", description=f"Processing fee on invoice {invoice.get('id')}", amount_cents=fee, source="stripe", external_id=bt_id or f"inv:{invoice.get('id')}")
