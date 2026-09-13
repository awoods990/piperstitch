"""SQLite storage: customers, their subscriptions (mirrored from Stripe,
or granted manually), payments, signed-in devices, one-time sign-in codes,
and in-flight checkouts. Single admin, low volume by design — plain
sqlite3, no ORM, no migrations framework; if the schema ever needs to
change, add a new `CREATE TABLE IF NOT EXISTS` / guarded `ALTER TABLE`
in init_db the same way the Amerus License Admin does.

The subscriptions table is a *mirror* of Stripe, not the source of truth
for billing: Stripe charges the card and tells us what happened via
webhooks; this table is what the app's entitlement check reads so that a
sign-in never has to call Stripe's API on the request path. The one
exception is `source = 'manual'` rows — complimentary access granted by
the admin, which exist only here.
"""

from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta
from typing import Iterator, Optional

from . import config

# Stripe subscription statuses that entitle the customer to use the app
# right now. 'past_due' is included deliberately: Stripe is still retrying
# the card, and locking someone out mid-retry for a bank hiccup is the
# wrong call — the entitlement grace window (config.ENTITLEMENT_GRACE_DAYS)
# is what actually bounds how long a failed renewal keeps working.
ENTITLED_STATUSES = ("active", "trialing", "past_due", "comp")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS customers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    phone TEXT NOT NULL DEFAULT '',
    address TEXT NOT NULL DEFAULT '',
    consent_terms_version TEXT NOT NULL DEFAULT '',
    consent_accepted_at TEXT,
    source TEXT NOT NULL DEFAULT 'website_registration',  -- how this record was first created
    stripe_customer_id TEXT,            -- set the first time Stripe tells us about them
    notes TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    last_reminder_sent_at TEXT,
    downloaded_at TEXT                  -- set once the .dmg is actually fetched (get.php)
);

CREATE TABLE IF NOT EXISTS subscriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    stripe_subscription_id TEXT UNIQUE,  -- NULL for a manual comp
    stripe_customer_id TEXT,
    status TEXT NOT NULL,               -- Stripe's status verbatim, or 'comp'
    current_period_start TEXT,
    current_period_end TEXT,            -- ISO timestamp; access runs until this (+ grace)
    cancel_at_period_end INTEGER NOT NULL DEFAULT 0,
    canceled_at TEXT,
    ended_at TEXT,
    source TEXT NOT NULL,               -- 'stripe' | 'manual'
    amount_cents INTEGER,               -- the recurring price at last sync
    notes TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_subscriptions_customer ON subscriptions(customer_id);

CREATE TABLE IF NOT EXISTS subscription_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id INTEGER REFERENCES subscriptions(id),
    customer_id INTEGER REFERENCES customers(id),
    kind TEXT NOT NULL,                 -- 'created' | 'renewed' | 'payment_failed' | 'cancel_scheduled' | ...
    detail TEXT NOT NULL DEFAULT '',
    stripe_event_id TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_subscription_events_customer ON subscription_events(customer_id);

CREATE TABLE IF NOT EXISTS payments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER REFERENCES customers(id),
    subscription_id INTEGER REFERENCES subscriptions(id),
    stripe_invoice_id TEXT UNIQUE,
    stripe_payment_intent TEXT,
    amount_cents INTEGER NOT NULL,
    currency TEXT NOT NULL DEFAULT 'usd',
    status TEXT NOT NULL,               -- 'paid' | 'failed' | 'refunded'
    paid_at TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_payments_paid_at ON payments(paid_at);

CREATE TABLE IF NOT EXISTS checkout_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER REFERENCES customers(id),
    promotion_id INTEGER REFERENCES promotions(id),
    stripe_session_id TEXT NOT NULL UNIQUE,
    customer_name TEXT NOT NULL,
    customer_email TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',  -- 'pending' | 'completed' | 'failed'
    error TEXT,
    created_at TEXT NOT NULL,
    completed_at TEXT
);

CREATE TABLE IF NOT EXISTS devices (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    device_id TEXT NOT NULL,            -- the app's own stable per-Mac identifier
    device_name TEXT NOT NULL DEFAULT '',
    token_hash TEXT NOT NULL UNIQUE,    -- sha256 of the bearer token the app holds
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    last_entitlement_until TEXT,        -- expiry of the most recent token handed out
    revoked_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_devices_customer ON devices(customer_id);

CREATE TABLE IF NOT EXISTS activation_codes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL,
    code_hash TEXT NOT NULL,
    device_id TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    consumed_at TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_activation_codes_email ON activation_codes(email);

CREATE TABLE IF NOT EXISTS account_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TEXT NOT NULL,
    consumed_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS web_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    token_hash TEXT NOT NULL UNIQUE,    -- sha256 of the bearer token the web server holds in its cookie
    user_agent TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    revoked_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_web_sessions_customer ON web_sessions(customer_id);

CREATE TABLE IF NOT EXISTS projects (
    id TEXT PRIMARY KEY,                -- the web app's own id (uuid) so a save is idempotent
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    name TEXT NOT NULL,
    document TEXT NOT NULL,             -- the StitchDocument as JSON, exactly as the app holds it
    width_mm REAL NOT NULL DEFAULT 0,
    height_mm REAL NOT NULL DEFAULT 0,
    object_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_projects_customer ON projects(customer_id, updated_at);

CREATE TABLE IF NOT EXISTS promoters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,                 -- a person or an organization
    email TEXT NOT NULL DEFAULT '',
    organization TEXT NOT NULL DEFAULT '',
    default_share_pct REAL NOT NULL DEFAULT 0,   -- suggested revenue share for new codes
    notes TEXT NOT NULL DEFAULT '',
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS promotions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    code TEXT NOT NULL UNIQUE,          -- what the customer types; stored upper-case
    kind TEXT NOT NULL,                 -- 'promoter' (referral with revenue share) | 'direct' (a discount the admin hands out)
    promoter_id INTEGER REFERENCES promoters(id),
    percent_off REAL NOT NULL,          -- 1..100
    duration_months INTEGER,            -- NULL = every month forever; N = the first N billing cycles
    share_pct REAL NOT NULL DEFAULT 0,  -- promoter's share of net revenue, 0..100 (promoter kind only)
    max_redemptions INTEGER,            -- NULL = unlimited
    expires_at TEXT,                    -- ISO; NULL = never
    allowed_emails TEXT NOT NULL DEFAULT '',  -- comma-separated; empty = anyone
    stripe_coupon_id TEXT,
    stripe_promotion_code_id TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    notes TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_promotions_promoter ON promotions(promoter_id);

CREATE TABLE IF NOT EXISTS promo_redemptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    promotion_id INTEGER NOT NULL REFERENCES promotions(id),
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    subscription_id INTEGER REFERENCES subscriptions(id),
    stripe_subscription_id TEXT,
    redeemed_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_promo_redemptions_customer ON promo_redemptions(customer_id);
CREATE INDEX IF NOT EXISTS idx_promo_redemptions_promotion ON promo_redemptions(promotion_id);

CREATE TABLE IF NOT EXISTS promo_payouts (
    -- One row per paid invoice on a promoter-referred subscription: what
    -- the promoter earned from it. Owed = sum(share_cents) - promoter_payments.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    promoter_id INTEGER NOT NULL REFERENCES promoters(id),
    promotion_id INTEGER NOT NULL REFERENCES promotions(id),
    customer_id INTEGER REFERENCES customers(id),
    payment_id INTEGER REFERENCES payments(id),
    gross_cents INTEGER NOT NULL,
    fee_cents INTEGER NOT NULL,
    net_cents INTEGER NOT NULL,
    share_pct REAL NOT NULL,
    share_cents INTEGER NOT NULL,
    fee_source TEXT NOT NULL DEFAULT 'estimate',   -- 'stripe' | 'estimate'
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_promo_payouts_promoter ON promo_payouts(promoter_id);

CREATE TABLE IF NOT EXISTS promoter_payments (
    -- Money actually sent to a promoter, recorded by the admin.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    promoter_id INTEGER NOT NULL REFERENCES promoters(id),
    amount_cents INTEGER NOT NULL,
    paid_at TEXT NOT NULL,
    note TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS stripe_events (
    id TEXT PRIMARY KEY,                -- Stripe's evt_... id; Stripe retries, we don't double-apply
    type TEXT NOT NULL,
    processed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS published_updates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    version TEXT NOT NULL,
    notes TEXT NOT NULL DEFAULT '',
    download_url TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    published_at TEXT NOT NULL
);
"""


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(config.DATABASE_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db() -> None:
    with _connect() as conn:
        conn.executescript(_SCHEMA)
        # Columns added after a table first shipped: CREATE TABLE IF NOT
        # EXISTS leaves an existing table alone, so add them here.
        _add_column_if_missing(conn, "checkout_sessions", "promotion_id", "INTEGER REFERENCES promotions(id)")
        _add_column_if_missing(conn, "payments", "fee_cents", "INTEGER")            # Stripe's processing fee, when known
        _add_column_if_missing(conn, "payments", "balance_transaction_id", "TEXT")


def _add_column_if_missing(conn: sqlite3.Connection, table: str, column: str, definition: str) -> None:
    existing = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
    if column not in existing:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")


@contextmanager
def connection() -> Iterator[sqlite3.Connection]:
    conn = _connect()
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def _now() -> str:
    return datetime.utcnow().isoformat(timespec="seconds") + "Z"


def now_iso() -> str:
    return _now()


def iso_from_timestamp(ts: Optional[int]) -> Optional[str]:
    """Stripe reports times as Unix seconds; everything here is ISO UTC."""
    if ts is None:
        return None
    return datetime.utcfromtimestamp(int(ts)).isoformat(timespec="seconds") + "Z"


def parse_iso(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    return datetime.fromisoformat(value.rstrip("Z"))


# ------------------------------------------------------------------ customers --


def upsert_customer(
    *,
    name: str,
    email: str,
    phone: str = "",
    address: str = "",
    consent_terms_version: str = "",
    consent_accepted_at: Optional[str] = None,
    source: str = "website_registration",
) -> int:
    """Creates a customer on first contact (the website's download form,
    or a checkout started under a new email), or refreshes the details of
    one that already exists for this email — never a duplicate. Matching
    is by email alone, everywhere in this file. Blank incoming fields
    never blank out details already on file."""
    now = _now()
    email = email.strip().lower()
    with connection() as conn:
        existing = conn.execute("SELECT * FROM customers WHERE email = ?", (email,)).fetchone()
        if existing:
            conn.execute(
                "UPDATE customers SET name = ?, phone = ?, address = ?, consent_terms_version = ?, "
                "consent_accepted_at = COALESCE(?, consent_accepted_at), updated_at = ? WHERE id = ?",
                (
                    name.strip() or existing["name"],
                    phone.strip() or existing["phone"],
                    address.strip() or existing["address"],
                    consent_terms_version or existing["consent_terms_version"],
                    consent_accepted_at,
                    now,
                    existing["id"],
                ),
            )
            return existing["id"]
        cur = conn.execute(
            "INSERT INTO customers (name, email, phone, address, consent_terms_version, consent_accepted_at, source, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (name.strip(), email, phone.strip(), address.strip(), consent_terms_version, consent_accepted_at, source, now, now),
        )
        return cur.lastrowid


def get_customer(customer_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM customers WHERE id = ?", (customer_id,)).fetchone()


def get_customer_by_email(email: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM customers WHERE email = ?", (email.strip().lower(),)).fetchone()


def get_customer_by_stripe_id(stripe_customer_id: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM customers WHERE stripe_customer_id = ?", (stripe_customer_id,)).fetchone()


def set_stripe_customer_id(customer_id: int, stripe_customer_id: str) -> None:
    with connection() as conn:
        conn.execute("UPDATE customers SET stripe_customer_id = ?, updated_at = ? WHERE id = ?", (stripe_customer_id, _now(), customer_id))


def set_customer_notes(customer_id: int, notes: str) -> None:
    with connection() as conn:
        conn.execute("UPDATE customers SET notes = ?, updated_at = ? WHERE id = ?", (notes, _now(), customer_id))


# Every customer row plus a summary of their best subscription, so the
# list pages can show status without a query per row.
_CUSTOMERS_WITH_STATUS = """
SELECT customers.*,
       (SELECT status FROM subscriptions s WHERE s.customer_id = customers.id
          ORDER BY (s.status IN ('active','trialing','past_due','comp')) DESC, s.current_period_end DESC LIMIT 1) AS sub_status,
       (SELECT current_period_end FROM subscriptions s WHERE s.customer_id = customers.id
          ORDER BY (s.status IN ('active','trialing','past_due','comp')) DESC, s.current_period_end DESC LIMIT 1) AS sub_period_end,
       (SELECT COUNT(*) FROM subscriptions s WHERE s.customer_id = customers.id) AS subscription_count,
       (SELECT COUNT(*) FROM devices d WHERE d.customer_id = customers.id AND d.revoked_at IS NULL) AS device_count
FROM customers
"""


def list_customers(query: str = "", limit: int = 300) -> list[sqlite3.Row]:
    with connection() as conn:
        if query:
            like = f"%{query}%"
            return conn.execute(
                f"{_CUSTOMERS_WITH_STATUS} WHERE name LIKE ? OR email LIKE ? ORDER BY created_at DESC LIMIT ?", (like, like, limit)
            ).fetchall()
        return conn.execute(f"{_CUSTOMERS_WITH_STATUS} ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()


def delete_customer(customer_id: int) -> None:
    """Removes a lead/customer record and everything hanging off it. A
    Stripe subscription is NOT cancelled by this — that's a billing action
    the admin takes explicitly (see subscriptions.cancel) — so deleting a
    record with a live subscription is refused by the route, not here."""
    with connection() as conn:
        conn.execute("DELETE FROM devices WHERE customer_id = ?", (customer_id,))
        conn.execute("DELETE FROM account_links WHERE customer_id = ?", (customer_id,))
        conn.execute("DELETE FROM subscription_events WHERE customer_id = ?", (customer_id,))
        conn.execute("DELETE FROM payments WHERE customer_id = ?", (customer_id,))
        conn.execute("DELETE FROM subscriptions WHERE customer_id = ?", (customer_id,))
        conn.execute("UPDATE checkout_sessions SET customer_id = NULL WHERE customer_id = ?", (customer_id,))
        conn.execute("DELETE FROM customers WHERE id = ?", (customer_id,))


def record_terms_consent(customer_id: int, version: str) -> None:
    """Stamps acceptance of a Terms version at the moment it happened. The
    admin's customer page shows the pair; a later version overwrites it."""
    with connection() as conn:
        conn.execute("UPDATE customers SET consent_terms_version = ?, consent_accepted_at = ?, updated_at = ? WHERE id = ?", (version, _now(), _now(), customer_id))


def record_reminder_sent(customer_id: int) -> None:
    with connection() as conn:
        conn.execute("UPDATE customers SET last_reminder_sent_at = ? WHERE id = ?", (_now(), customer_id))


def mark_downloaded_by_email(email: str) -> Optional[int]:
    """Records the FIRST completed download for this person — never
    overwrites, so it stays the true first-download moment."""
    with connection() as conn:
        row = conn.execute("SELECT id, downloaded_at FROM customers WHERE email = ?", (email.strip().lower(),)).fetchone()
        if row is None:
            return None
        if row["downloaded_at"] is None:
            conn.execute("UPDATE customers SET downloaded_at = ? WHERE id = ?", (_now(), row["id"]))
        return row["id"]


def count_downloads() -> dict:
    month_start = datetime.utcnow().date().replace(day=1).isoformat()
    with connection() as conn:
        total = conn.execute("SELECT COUNT(*) FROM customers WHERE downloaded_at IS NOT NULL").fetchone()[0]
        this_month = conn.execute("SELECT COUNT(*) FROM customers WHERE downloaded_at >= ?", (month_start,)).fetchone()[0]
    return {"total": total, "this_month": this_month}


# ------------------------------------------------------- checkout sessions --


def create_checkout_session(*, stripe_session_id: str, customer_name: str, customer_email: str, customer_id: Optional[int] = None, promotion_id: Optional[int] = None) -> None:
    with connection() as conn:
        conn.execute(
            "INSERT INTO checkout_sessions (stripe_session_id, customer_name, customer_email, customer_id, promotion_id, status, created_at) VALUES (?, ?, ?, ?, ?, 'pending', ?)",
            (stripe_session_id, customer_name, customer_email.strip().lower(), customer_id, promotion_id, _now()),
        )


def get_checkout_session(stripe_session_id: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM checkout_sessions WHERE stripe_session_id = ?", (stripe_session_id,)).fetchone()


def mark_checkout_completed(stripe_session_id: str) -> None:
    with connection() as conn:
        conn.execute("UPDATE checkout_sessions SET status = 'completed', completed_at = ? WHERE stripe_session_id = ?", (_now(), stripe_session_id))


def mark_checkout_failed(stripe_session_id: str, error: str) -> None:
    with connection() as conn:
        conn.execute("UPDATE checkout_sessions SET status = 'failed', error = ? WHERE stripe_session_id = ?", (error, stripe_session_id))


def list_pending_checkouts(limit: int = 25) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM checkout_sessions WHERE status = 'pending' ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()


# ------------------------------------------------------------- subscriptions --


def upsert_subscription(
    *,
    customer_id: int,
    stripe_subscription_id: Optional[str],
    stripe_customer_id: Optional[str],
    status: str,
    current_period_start: Optional[str],
    current_period_end: Optional[str],
    cancel_at_period_end: bool,
    canceled_at: Optional[str],
    ended_at: Optional[str],
    source: str,
    amount_cents: Optional[int],
    notes: str = "",
) -> int:
    """Insert-or-update keyed on stripe_subscription_id. Manual comps
    (stripe_subscription_id NULL) are always inserted fresh — there is
    nothing to key them on, and two comps for one person just means two
    rows, of which the entitlement check picks the later-ending one."""
    now = _now()
    with connection() as conn:
        existing = None
        if stripe_subscription_id:
            existing = conn.execute("SELECT id FROM subscriptions WHERE stripe_subscription_id = ?", (stripe_subscription_id,)).fetchone()
        if existing:
            conn.execute(
                "UPDATE subscriptions SET customer_id = ?, stripe_customer_id = ?, status = ?, current_period_start = ?, current_period_end = ?, "
                "cancel_at_period_end = ?, canceled_at = ?, ended_at = ?, amount_cents = COALESCE(?, amount_cents), updated_at = ? WHERE id = ?",
                (customer_id, stripe_customer_id, status, current_period_start, current_period_end, int(cancel_at_period_end), canceled_at, ended_at, amount_cents, now, existing["id"]),
            )
            return existing["id"]
        cur = conn.execute(
            "INSERT INTO subscriptions (customer_id, stripe_subscription_id, stripe_customer_id, status, current_period_start, current_period_end, "
            "cancel_at_period_end, canceled_at, ended_at, source, amount_cents, notes, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (customer_id, stripe_subscription_id, stripe_customer_id, status, current_period_start, current_period_end, int(cancel_at_period_end), canceled_at, ended_at, source, amount_cents, notes, now, now),
        )
        return cur.lastrowid


def get_subscription(subscription_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM subscriptions WHERE id = ?", (subscription_id,)).fetchone()


def get_subscription_by_stripe_id(stripe_subscription_id: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM subscriptions WHERE stripe_subscription_id = ?", (stripe_subscription_id,)).fetchone()


def update_subscription_status(subscription_id: int, *, status: str, ended_at: Optional[str] = None, canceled_at: Optional[str] = None, cancel_at_period_end: Optional[bool] = None) -> None:
    with connection() as conn:
        conn.execute(
            "UPDATE subscriptions SET status = ?, ended_at = COALESCE(?, ended_at), canceled_at = COALESCE(?, canceled_at), "
            "cancel_at_period_end = COALESCE(?, cancel_at_period_end), updated_at = ? WHERE id = ?",
            (status, ended_at, canceled_at, None if cancel_at_period_end is None else int(cancel_at_period_end), _now(), subscription_id),
        )


def extend_subscription(subscription_id: int, *, current_period_end: str) -> None:
    with connection() as conn:
        conn.execute("UPDATE subscriptions SET current_period_end = ?, updated_at = ? WHERE id = ?", (current_period_end, _now(), subscription_id))


def list_subscriptions_for_customer(customer_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM subscriptions WHERE customer_id = ? ORDER BY created_at DESC", (customer_id,)).fetchall()


def best_subscription_for_customer(customer_id: int) -> Optional[sqlite3.Row]:
    """The subscription that decides this person's access: an entitled one
    with the latest period end if there is one, otherwise whichever ended
    most recently (so the account page can say *when* access lapsed)."""
    with connection() as conn:
        return conn.execute(
            "SELECT * FROM subscriptions WHERE customer_id = ? "
            "ORDER BY (status IN ('active','trialing','past_due','comp')) DESC, COALESCE(current_period_end, '') DESC, created_at DESC LIMIT 1",
            (customer_id,),
        ).fetchone()


_SUBSCRIPTIONS_WITH_CUSTOMER = (
    "SELECT subscriptions.*, customers.name AS customer_name, customers.email AS customer_email "
    "FROM subscriptions JOIN customers ON customers.id = subscriptions.customer_id"
)


def list_subscriptions(query: str = "", status: str = "", limit: int = 300) -> list[sqlite3.Row]:
    clauses, params = [], []
    if query:
        like = f"%{query}%"
        clauses.append("(customers.name LIKE ? OR customers.email LIKE ? OR subscriptions.stripe_subscription_id LIKE ?)")
        params += [like, like, like]
    if status == "entitled":
        clauses.append("subscriptions.status IN ('active','trialing','past_due','comp')")
    elif status == "cancelling":
        clauses.append("subscriptions.cancel_at_period_end = 1 AND subscriptions.status IN ('active','trialing','past_due')")
    elif status:
        clauses.append("subscriptions.status = ?")
        params.append(status)
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    with connection() as conn:
        return conn.execute(
            f"{_SUBSCRIPTIONS_WITH_CUSTOMER} {where} ORDER BY subscriptions.updated_at DESC LIMIT ?", (*params, limit)
        ).fetchall()


def all_subscriptions_for_export() -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(f"{_SUBSCRIPTIONS_WITH_CUSTOMER} ORDER BY subscriptions.created_at ASC").fetchall()


def add_event(*, customer_id: Optional[int], subscription_id: Optional[int], kind: str, detail: str = "", stripe_event_id: Optional[str] = None) -> int:
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO subscription_events (subscription_id, customer_id, kind, detail, stripe_event_id, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            (subscription_id, customer_id, kind, detail, stripe_event_id, _now()),
        )
        return cur.lastrowid


def list_events_for_customer(customer_id: int, limit: int = 100) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM subscription_events WHERE customer_id = ? ORDER BY created_at DESC, id DESC LIMIT ?", (customer_id, limit)).fetchall()


def recent_events(limit: int = 30) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(
            "SELECT subscription_events.*, customers.name AS customer_name, customers.email AS customer_email FROM subscription_events "
            "LEFT JOIN customers ON customers.id = subscription_events.customer_id ORDER BY subscription_events.created_at DESC, subscription_events.id DESC LIMIT ?",
            (limit,),
        ).fetchall()


# --------------------------------------------------------------- stripe events --


def stripe_event_already_processed(event_id: str) -> bool:
    with connection() as conn:
        return conn.execute("SELECT 1 FROM stripe_events WHERE id = ?", (event_id,)).fetchone() is not None


def record_stripe_event(event_id: str, event_type: str) -> None:
    with connection() as conn:
        conn.execute("INSERT OR IGNORE INTO stripe_events (id, type, processed_at) VALUES (?, ?, ?)", (event_id, event_type, _now()))


# ------------------------------------------------------------------ payments --


def record_payment(
    *,
    customer_id: Optional[int],
    subscription_id: Optional[int],
    stripe_invoice_id: Optional[str],
    stripe_payment_intent: Optional[str],
    amount_cents: int,
    currency: str,
    status: str,
    paid_at: Optional[str],
) -> Optional[int]:
    """Idempotent on stripe_invoice_id — Stripe retries webhooks, and the
    same invoice can also arrive via both invoice.paid and
    checkout.session.completed. Returns None if it was already recorded."""
    with connection() as conn:
        if stripe_invoice_id:
            existing = conn.execute("SELECT id, status FROM payments WHERE stripe_invoice_id = ?", (stripe_invoice_id,)).fetchone()
            if existing:
                if existing["status"] != status:
                    conn.execute("UPDATE payments SET status = ?, paid_at = COALESCE(?, paid_at) WHERE id = ?", (status, paid_at, existing["id"]))
                return None
        cur = conn.execute(
            "INSERT INTO payments (customer_id, subscription_id, stripe_invoice_id, stripe_payment_intent, amount_cents, currency, status, paid_at, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (customer_id, subscription_id, stripe_invoice_id, stripe_payment_intent, amount_cents, currency, status, paid_at, _now()),
        )
        return cur.lastrowid


def list_payments_for_customer(customer_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM payments WHERE customer_id = ? ORDER BY COALESCE(paid_at, created_at) DESC", (customer_id,)).fetchall()


def monthly_revenue(months: int = 12) -> list[dict]:
    """Paid invoices grouped by calendar month, most recent first, plus
    the count of subscriptions that started and ended in that month."""
    with connection() as conn:
        rows = conn.execute(
            "SELECT strftime('%Y-%m', paid_at) AS month, COUNT(*) AS payment_count, SUM(amount_cents) AS revenue_cents "
            "FROM payments WHERE status = 'paid' AND paid_at IS NOT NULL GROUP BY month ORDER BY month DESC LIMIT ?",
            (months,),
        ).fetchall()
        result = []
        for r in rows:
            month = r["month"]
            started = conn.execute(
                "SELECT COUNT(*) FROM subscriptions WHERE source = 'stripe' AND strftime('%Y-%m', created_at) = ?", (month,)
            ).fetchone()[0]
            ended = conn.execute(
                "SELECT COUNT(*) FROM subscriptions WHERE source = 'stripe' AND ended_at IS NOT NULL AND strftime('%Y-%m', ended_at) = ?", (month,)
            ).fetchone()[0]
            result.append({"month": month, "payment_count": r["payment_count"], "revenue_cents": r["revenue_cents"] or 0, "started": started, "ended": ended})
        return result


def subscriber_counts() -> dict:
    """The Dashboard's KPI tiles. MRR counts every paying (Stripe-sourced,
    entitled, not-yet-cancelled-at-period-end excluded? — no: a
    subscription cancelling at period end is still paying this month, so
    it counts) subscription at its recurring price. Comps are never
    revenue."""
    month_start = datetime.utcnow().date().replace(day=1).isoformat()
    with connection() as conn:
        row = conn.execute(
            "SELECT "
            "SUM(CASE WHEN status IN ('active','trialing','past_due') AND source = 'stripe' THEN 1 ELSE 0 END) AS paying, "
            "SUM(CASE WHEN status = 'comp' THEN 1 ELSE 0 END) AS comps, "
            "SUM(CASE WHEN status = 'past_due' THEN 1 ELSE 0 END) AS past_due, "
            "SUM(CASE WHEN cancel_at_period_end = 1 AND status IN ('active','trialing','past_due') THEN 1 ELSE 0 END) AS cancelling, "
            "SUM(CASE WHEN status IN ('active','trialing','past_due') AND source = 'stripe' THEN COALESCE(amount_cents, ?) ELSE 0 END) AS mrr_cents, "
            "SUM(CASE WHEN source = 'stripe' AND created_at >= ? THEN 1 ELSE 0 END) AS new_this_month, "
            "SUM(CASE WHEN source = 'stripe' AND ended_at IS NOT NULL AND ended_at >= ? THEN 1 ELSE 0 END) AS churned_this_month "
            "FROM subscriptions",
            (config.MONTHLY_PRICE_CENTS, month_start, month_start),
        ).fetchone()
        now_iso = _now()
        trials = conn.execute(
            "SELECT SUM(CASE WHEN current_period_end > ? THEN 1 ELSE 0 END) AS active, "
            "SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END) AS started_this_month "
            "FROM subscriptions WHERE source = 'manual' AND status = 'trialing'",
            (now_iso, month_start),
        ).fetchone()
        # Trial -> paid: customers with a web trial row who also have a Stripe subscription.
        converted = conn.execute(
            "SELECT COUNT(DISTINCT t.customer_id) FROM subscriptions t JOIN subscriptions p ON p.customer_id = t.customer_id "
            "WHERE t.source = 'manual' AND t.notes = 'Web free trial' AND p.source = 'stripe'"
        ).fetchone()[0]
        revenue = conn.execute("SELECT COALESCE(SUM(amount_cents), 0) FROM payments WHERE status = 'paid' AND paid_at >= ?", (month_start,)).fetchone()[0]
        failed = conn.execute("SELECT COUNT(*) FROM payments WHERE status = 'failed' AND created_at >= ?", (month_start,)).fetchone()[0]
    return {
        "paying": row["paying"] or 0,
        "comps": row["comps"] or 0,
        "past_due": row["past_due"] or 0,
        "cancelling": row["cancelling"] or 0,
        "mrr_cents": row["mrr_cents"] or 0,
        "new_this_month": row["new_this_month"] or 0,
        "churned_this_month": row["churned_this_month"] or 0,
        "revenue_this_month_cents": revenue or 0,
        "trials_active": trials["active"] or 0,
        "trials_started_this_month": trials["started_this_month"] or 0,
        "trials_converted": converted or 0,
        "failed_payments_this_month": failed or 0,
    }


# ------------------------------------------------------------------- devices --


def create_device(*, customer_id: int, device_id: str, device_name: str, token_hash: str) -> int:
    """A Mac signing in again (same device_id) replaces its old token
    rather than counting as a second device."""
    now = _now()
    with connection() as conn:
        existing = conn.execute("SELECT id FROM devices WHERE customer_id = ? AND device_id = ? AND revoked_at IS NULL", (customer_id, device_id)).fetchone()
        if existing:
            conn.execute(
                "UPDATE devices SET device_name = ?, token_hash = ?, last_seen_at = ? WHERE id = ?", (device_name, token_hash, now, existing["id"])
            )
            return existing["id"]
        cur = conn.execute(
            "INSERT INTO devices (customer_id, device_id, device_name, token_hash, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)",
            (customer_id, device_id, device_name, token_hash, now, now),
        )
        return cur.lastrowid


def get_device_by_token_hash(token_hash: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM devices WHERE token_hash = ? AND revoked_at IS NULL", (token_hash,)).fetchone()


def get_device(device_row_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM devices WHERE id = ?", (device_row_id,)).fetchone()


def touch_device(device_row_id: int, *, entitlement_until: Optional[str]) -> None:
    with connection() as conn:
        conn.execute("UPDATE devices SET last_seen_at = ?, last_entitlement_until = COALESCE(?, last_entitlement_until) WHERE id = ?", (_now(), entitlement_until, device_row_id))


def list_active_devices(customer_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM devices WHERE customer_id = ? AND revoked_at IS NULL ORDER BY last_seen_at DESC", (customer_id,)).fetchall()


def has_active_device(customer_id: int, device_id: str) -> bool:
    with connection() as conn:
        return conn.execute("SELECT 1 FROM devices WHERE customer_id = ? AND device_id = ? AND revoked_at IS NULL", (customer_id, device_id)).fetchone() is not None


def revoke_device(device_row_id: int) -> None:
    with connection() as conn:
        conn.execute("UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL", (_now(), device_row_id))


def revoke_all_devices(customer_id: int) -> int:
    with connection() as conn:
        cur = conn.execute("UPDATE devices SET revoked_at = ? WHERE customer_id = ? AND revoked_at IS NULL", (_now(), customer_id))
        return cur.rowcount


# ---------------------------------------------------------- activation codes --


def create_activation_code(*, email: str, code_hash: str, device_id: str, ttl_minutes: int) -> int:
    """Any earlier unconsumed code for the same email+device is voided
    first, so only the most recently emailed code ever works."""
    now = datetime.utcnow()
    expires = (now + timedelta(minutes=ttl_minutes)).isoformat(timespec="seconds") + "Z"
    with connection() as conn:
        conn.execute("UPDATE activation_codes SET consumed_at = ? WHERE email = ? AND device_id = ? AND consumed_at IS NULL", (_now(), email, device_id))
        cur = conn.execute(
            "INSERT INTO activation_codes (email, code_hash, device_id, expires_at, created_at) VALUES (?, ?, ?, ?, ?)",
            (email, code_hash, device_id, expires, _now()),
        )
        return cur.lastrowid


def delete_activation_code(code_row_id: int) -> None:
    """A code that could not be emailed never existed as far as the
    customer is concerned -- removing it keeps a broken mail setup from
    counting toward the per-hour limit and locking the address out."""
    with connection() as conn:
        conn.execute("DELETE FROM activation_codes WHERE id = ?", (code_row_id,))


def latest_activation_code(email: str, device_id: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(
            "SELECT * FROM activation_codes WHERE email = ? AND device_id = ? AND consumed_at IS NULL ORDER BY created_at DESC, id DESC LIMIT 1", (email, device_id)
        ).fetchone()


def bump_activation_attempts(code_row_id: int) -> int:
    with connection() as conn:
        conn.execute("UPDATE activation_codes SET attempts = attempts + 1 WHERE id = ?", (code_row_id,))
        return conn.execute("SELECT attempts FROM activation_codes WHERE id = ?", (code_row_id,)).fetchone()[0]


def consume_activation_code(code_row_id: int) -> None:
    with connection() as conn:
        conn.execute("UPDATE activation_codes SET consumed_at = ? WHERE id = ?", (_now(), code_row_id))


def count_recent_activation_codes(email: str, minutes: int = 60) -> int:
    since = (datetime.utcnow() - timedelta(minutes=minutes)).isoformat(timespec="seconds") + "Z"
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM activation_codes WHERE email = ? AND created_at >= ?", (email, since)).fetchone()[0]


# ------------------------------------------------------------- account links --


def create_account_link(*, customer_id: int, token_hash: str, ttl_minutes: int) -> int:
    expires = (datetime.utcnow() + timedelta(minutes=ttl_minutes)).isoformat(timespec="seconds") + "Z"
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO account_links (customer_id, token_hash, expires_at, created_at) VALUES (?, ?, ?, ?)", (customer_id, token_hash, expires, _now())
        )
        return cur.lastrowid


def get_account_link(token_hash: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM account_links WHERE token_hash = ?", (token_hash,)).fetchone()


# ---------------------------------------------------------- published updates --


def insert_published_update(*, version: str, notes: str, download_url: str, file_size: int, sha256: str) -> int:
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO published_updates (version, notes, download_url, file_size, sha256, published_at) VALUES (?, ?, ?, ?, ?, ?)",
            (version, notes, download_url, file_size, sha256, _now()),
        )
        return cur.lastrowid


def list_published_updates(limit: int = 25) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM published_updates ORDER BY published_at DESC LIMIT ?", (limit,)).fetchall()


def latest_published_update() -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM published_updates ORDER BY published_at DESC LIMIT 1").fetchone()


# --------------------------------------------------------- web sessions --
# The web edition's equivalent of `devices`: one row per signed-in
# browser, token stored hashed. No device limit -- a browser session is
# cheap to create and easy to end from the account page.


def create_web_session(*, customer_id: int, token_hash: str, user_agent: str) -> int:
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO web_sessions (customer_id, token_hash, user_agent, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?)",
            (customer_id, token_hash, user_agent[:200], _now(), _now()),
        )
        return cur.lastrowid


def get_web_session_by_token_hash(token_hash: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM web_sessions WHERE token_hash = ? AND revoked_at IS NULL", (token_hash,)).fetchone()


def get_web_session(session_row_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM web_sessions WHERE id = ?", (session_row_id,)).fetchone()


def touch_web_session(session_row_id: int) -> None:
    with connection() as conn:
        conn.execute("UPDATE web_sessions SET last_seen_at = ? WHERE id = ?", (_now(), session_row_id))


def revoke_web_session(session_row_id: int) -> None:
    with connection() as conn:
        conn.execute("UPDATE web_sessions SET revoked_at = ? WHERE id = ?", (_now(), session_row_id))


def list_active_web_sessions(customer_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM web_sessions WHERE customer_id = ? AND revoked_at IS NULL ORDER BY last_seen_at DESC", (customer_id,)).fetchall()


# -------------------------------------------------------------- projects --


def list_projects(customer_id: int) -> list[sqlite3.Row]:
    """Everything but the document itself -- a list is shown, not loaded."""
    with connection() as conn:
        return conn.execute(
            "SELECT id, customer_id, name, width_mm, height_mm, object_count, created_at, updated_at FROM projects WHERE customer_id = ? ORDER BY updated_at DESC",
            (customer_id,),
        ).fetchall()


def count_projects(customer_id: int) -> int:
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM projects WHERE customer_id = ?", (customer_id,)).fetchone()[0]


def get_project(customer_id: int, project_id: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM projects WHERE id = ? AND customer_id = ?", (project_id, customer_id)).fetchone()


def save_project(*, customer_id: int, project_id: str, name: str, document: str, width_mm: float, height_mm: float, object_count: int) -> bool:
    """Insert or replace. Returns True when created. A project id that
    belongs to another customer is simply not theirs to overwrite."""
    now = _now()
    with connection() as conn:
        existing = conn.execute("SELECT customer_id FROM projects WHERE id = ?", (project_id,)).fetchone()
        if existing is not None and existing["customer_id"] != customer_id:
            raise PermissionError("project belongs to another customer")
        if existing is None:
            conn.execute(
                "INSERT INTO projects (id, customer_id, name, document, width_mm, height_mm, object_count, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (project_id, customer_id, name, document, width_mm, height_mm, object_count, now, now),
            )
            return True
        conn.execute(
            "UPDATE projects SET name = ?, document = ?, width_mm = ?, height_mm = ?, object_count = ?, updated_at = ? WHERE id = ?",
            (name, document, width_mm, height_mm, object_count, now, project_id),
        )
        return False


def delete_project(customer_id: int, project_id: str) -> bool:
    with connection() as conn:
        cur = conn.execute("DELETE FROM projects WHERE id = ? AND customer_id = ?", (project_id, customer_id))
        return cur.rowcount > 0


# ------------------------------------------------------------ promotions --
# See promotions.py for the rules; these are just the rows.


def create_promoter(*, name: str, email: str = "", organization: str = "", default_share_pct: float = 0, notes: str = "") -> int:
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO promoters (name, email, organization, default_share_pct, notes, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (name.strip(), email.strip().lower(), organization.strip(), default_share_pct, notes.strip(), _now(), _now()),
        )
        return cur.lastrowid


def update_promoter(promoter_id: int, *, name: str, email: str, organization: str, default_share_pct: float, notes: str, active: bool) -> None:
    with connection() as conn:
        conn.execute(
            "UPDATE promoters SET name = ?, email = ?, organization = ?, default_share_pct = ?, notes = ?, active = ?, updated_at = ? WHERE id = ?",
            (name.strip(), email.strip().lower(), organization.strip(), default_share_pct, notes.strip(), 1 if active else 0, _now(), promoter_id),
        )


def get_promoter(promoter_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM promoters WHERE id = ?", (promoter_id,)).fetchone()


def list_promoters() -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM promoters ORDER BY active DESC, name COLLATE NOCASE").fetchall()


def create_promotion(*, code: str, kind: str, promoter_id: Optional[int], percent_off: float, duration_months: Optional[int], share_pct: float,
                     max_redemptions: Optional[int], expires_at: Optional[str], allowed_emails: str, stripe_coupon_id: Optional[str],
                     stripe_promotion_code_id: Optional[str], notes: str) -> int:
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO promotions (code, kind, promoter_id, percent_off, duration_months, share_pct, max_redemptions, expires_at, allowed_emails, "
            "stripe_coupon_id, stripe_promotion_code_id, notes, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (code, kind, promoter_id, percent_off, duration_months, share_pct, max_redemptions, expires_at, allowed_emails, stripe_coupon_id, stripe_promotion_code_id, notes.strip(), _now(), _now()),
        )
        return cur.lastrowid


def get_promotion(promotion_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM promotions WHERE id = ?", (promotion_id,)).fetchone()


def get_promotion_by_code(code: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM promotions WHERE code = ?", (code.strip().upper(),)).fetchone()


def get_promotion_by_stripe_promotion_code(stripe_promotion_code_id: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM promotions WHERE stripe_promotion_code_id = ?", (stripe_promotion_code_id,)).fetchone()


def set_promotion_active(promotion_id: int, active: bool) -> None:
    with connection() as conn:
        conn.execute("UPDATE promotions SET active = ?, updated_at = ? WHERE id = ?", (1 if active else 0, _now(), promotion_id))


_PROMOTIONS_WITH_STATS = (
    "SELECT promotions.*, promoters.name AS promoter_name, "
    "(SELECT COUNT(*) FROM promo_redemptions r WHERE r.promotion_id = promotions.id) AS redemption_count, "
    "(SELECT COALESCE(SUM(share_cents), 0) FROM promo_payouts p WHERE p.promotion_id = promotions.id) AS share_cents, "
    "(SELECT COALESCE(SUM(gross_cents), 0) FROM promo_payouts p WHERE p.promotion_id = promotions.id) AS gross_cents "
    "FROM promotions LEFT JOIN promoters ON promoters.id = promotions.promoter_id"
)


def list_promotions(promoter_id: Optional[int] = None) -> list[sqlite3.Row]:
    with connection() as conn:
        if promoter_id is not None:
            return conn.execute(_PROMOTIONS_WITH_STATS + " WHERE promotions.promoter_id = ? ORDER BY promotions.active DESC, promotions.created_at DESC", (promoter_id,)).fetchall()
        return conn.execute(_PROMOTIONS_WITH_STATS + " ORDER BY promotions.active DESC, promotions.created_at DESC").fetchall()


def count_redemptions(promotion_id: int) -> int:
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM promo_redemptions WHERE promotion_id = ?", (promotion_id,)).fetchone()[0]


def record_redemption(*, promotion_id: int, customer_id: int, subscription_id: Optional[int], stripe_subscription_id: Optional[str]) -> Optional[int]:
    """One redemption per customer per code -- a webhook replay or a
    re-sync must not count twice."""
    with connection() as conn:
        existing = conn.execute("SELECT id FROM promo_redemptions WHERE promotion_id = ? AND customer_id = ?", (promotion_id, customer_id)).fetchone()
        if existing:
            conn.execute("UPDATE promo_redemptions SET subscription_id = COALESCE(?, subscription_id), stripe_subscription_id = COALESCE(?, stripe_subscription_id) WHERE id = ?",
                         (subscription_id, stripe_subscription_id, existing["id"]))
            return None
        cur = conn.execute(
            "INSERT INTO promo_redemptions (promotion_id, customer_id, subscription_id, stripe_subscription_id, redeemed_at) VALUES (?, ?, ?, ?, ?)",
            (promotion_id, customer_id, subscription_id, stripe_subscription_id, _now()),
        )
        return cur.lastrowid


_REDEMPTIONS_WITH_CONTEXT = (
    "SELECT r.*, promotions.code, promotions.kind, promotions.percent_off, promotions.duration_months, promotions.share_pct, promotions.promoter_id, "
    "promoters.name AS promoter_name, customers.name AS customer_name, customers.email AS customer_email, subscriptions.status AS subscription_status "
    "FROM promo_redemptions r JOIN promotions ON promotions.id = r.promotion_id LEFT JOIN promoters ON promoters.id = promotions.promoter_id "
    "JOIN customers ON customers.id = r.customer_id LEFT JOIN subscriptions ON subscriptions.id = r.subscription_id"
)


def list_redemptions_for_customer(customer_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(_REDEMPTIONS_WITH_CONTEXT + " WHERE r.customer_id = ? ORDER BY r.redeemed_at DESC", (customer_id,)).fetchall()


def list_redemptions_for_promoter(promoter_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(_REDEMPTIONS_WITH_CONTEXT + " WHERE promotions.promoter_id = ? ORDER BY r.redeemed_at DESC", (promoter_id,)).fetchall()


def list_redemptions_for_promotion(promotion_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(_REDEMPTIONS_WITH_CONTEXT + " WHERE r.promotion_id = ? ORDER BY r.redeemed_at DESC", (promotion_id,)).fetchall()


def redemption_for_subscription(subscription_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(_REDEMPTIONS_WITH_CONTEXT + " WHERE r.subscription_id = ? ORDER BY r.redeemed_at DESC LIMIT 1", (subscription_id,)).fetchone()


def record_promo_payout(*, promoter_id: int, promotion_id: int, customer_id: Optional[int], payment_id: Optional[int], gross_cents: int, fee_cents: int,
                        net_cents: int, share_pct: float, share_cents: int, fee_source: str) -> Optional[int]:
    with connection() as conn:
        if payment_id is not None and conn.execute("SELECT 1 FROM promo_payouts WHERE payment_id = ?", (payment_id,)).fetchone():
            return None
        cur = conn.execute(
            "INSERT INTO promo_payouts (promoter_id, promotion_id, customer_id, payment_id, gross_cents, fee_cents, net_cents, share_pct, share_cents, fee_source, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (promoter_id, promotion_id, customer_id, payment_id, gross_cents, fee_cents, net_cents, share_pct, share_cents, fee_source, _now()),
        )
        return cur.lastrowid


def list_promo_payouts_for_promoter(promoter_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(
            "SELECT p.*, promotions.code, customers.email AS customer_email, customers.name AS customer_name FROM promo_payouts p "
            "JOIN promotions ON promotions.id = p.promotion_id LEFT JOIN customers ON customers.id = p.customer_id WHERE p.promoter_id = ? ORDER BY p.created_at DESC",
            (promoter_id,),
        ).fetchall()


def list_promo_payouts_for_customer(customer_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT p.*, promotions.code, promoters.name AS promoter_name FROM promo_payouts p JOIN promotions ON promotions.id = p.promotion_id "
                            "JOIN promoters ON promoters.id = p.promoter_id WHERE p.customer_id = ? ORDER BY p.created_at DESC", (customer_id,)).fetchall()


def record_promoter_payment(*, promoter_id: int, amount_cents: int, paid_at: str, note: str) -> int:
    with connection() as conn:
        cur = conn.execute("INSERT INTO promoter_payments (promoter_id, amount_cents, paid_at, note, created_at) VALUES (?, ?, ?, ?, ?)", (promoter_id, amount_cents, paid_at, note.strip(), _now()))
        return cur.lastrowid


def list_promoter_payments(promoter_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM promoter_payments WHERE promoter_id = ? ORDER BY paid_at DESC, id DESC", (promoter_id,)).fetchall()


def promoter_totals(promoter_id: int) -> dict:
    """The promoter's ledger in one row: what their codes brought in, what
    they earned, what they've been paid, what's owed."""
    with connection() as conn:
        p = conn.execute("SELECT COUNT(*) AS payouts, COALESCE(SUM(gross_cents), 0) AS gross, COALESCE(SUM(net_cents), 0) AS net, COALESCE(SUM(share_cents), 0) AS earned FROM promo_payouts WHERE promoter_id = ?", (promoter_id,)).fetchone()
        paid = conn.execute("SELECT COALESCE(SUM(amount_cents), 0) FROM promoter_payments WHERE promoter_id = ?", (promoter_id,)).fetchone()[0]
        referred = conn.execute("SELECT COUNT(DISTINCT r.customer_id) FROM promo_redemptions r JOIN promotions ON promotions.id = r.promotion_id WHERE promotions.promoter_id = ?", (promoter_id,)).fetchone()[0]
        active = conn.execute(
            "SELECT COUNT(DISTINCT r.customer_id) FROM promo_redemptions r JOIN promotions ON promotions.id = r.promotion_id JOIN subscriptions s ON s.id = r.subscription_id "
            "WHERE promotions.promoter_id = ? AND s.status IN ('active','trialing','past_due')", (promoter_id,)).fetchone()[0]
        codes = conn.execute("SELECT COUNT(*) FROM promotions WHERE promoter_id = ?", (promoter_id,)).fetchone()[0]
    return {"referred": referred, "active": active, "codes": codes, "payouts": p["payouts"], "gross_cents": p["gross"], "net_cents": p["net"],
            "earned_cents": p["earned"], "paid_cents": paid, "owed_cents": p["earned"] - paid}


def promotions_overview() -> dict:
    """The Promotions page's tiles."""
    month_start = datetime.utcnow().date().replace(day=1).isoformat()
    with connection() as conn:
        active_codes = conn.execute("SELECT COUNT(*) FROM promotions WHERE active = 1").fetchone()[0]
        redemptions = conn.execute("SELECT COUNT(*) AS total, SUM(CASE WHEN redeemed_at >= ? THEN 1 ELSE 0 END) AS this_month FROM promo_redemptions", (month_start,)).fetchone()
        earned = conn.execute("SELECT COALESCE(SUM(share_cents), 0) AS total, COALESCE(SUM(CASE WHEN created_at >= ? THEN share_cents ELSE 0 END), 0) AS this_month FROM promo_payouts", (month_start,)).fetchone()
        paid = conn.execute("SELECT COALESCE(SUM(amount_cents), 0) FROM promoter_payments").fetchone()[0]
        promoters = conn.execute("SELECT COUNT(*) FROM promoters WHERE active = 1").fetchone()[0]
    return {"active_codes": active_codes, "promoters": promoters, "redemptions": redemptions["total"] or 0, "redemptions_this_month": redemptions["this_month"] or 0,
            "earned_cents": earned["total"], "earned_this_month_cents": earned["this_month"], "paid_cents": paid, "owed_cents": earned["total"] - paid}
