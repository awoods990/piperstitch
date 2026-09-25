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

import os
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
    marketing_opt_out INTEGER NOT NULL DEFAULT 0,
    last_active_at TEXT,                -- last web sign-in / app use, for "we miss you"
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

CREATE TABLE IF NOT EXISTS web_handoffs (
    -- One-time, two-minute codes that carry a signed-in customer from
    -- the app to PiperStitch Proofs (or back) without a second sign-in.
    -- Redeeming one issues a fresh web session for the other app.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    code_hash TEXT NOT NULL UNIQUE,
    target TEXT NOT NULL,               -- 'core' | 'proofs'
    expires_at TEXT NOT NULL,
    used_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS proofs_uses (
    -- One row per proof the customer has sent on the free plan of
    -- PiperStitch Proofs, keyed by the proof's own id so a retry never
    -- counts twice. The count against PROOFS_FREE_PROOFS is the trial.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    proof_ref TEXT NOT NULL UNIQUE,
    used_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_proofs_uses_customer ON proofs_uses(customer_id);

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
    thumbnail TEXT,                     -- a small data: URL so the picker can show the design, not just its name
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_projects_customer ON projects(customer_id, updated_at);

CREATE TABLE IF NOT EXISTS web_preferences (
    -- The web app's per-user preferences (default hoop, thread library,
    -- suppliers...) mirrored from the browser so they follow the account
    -- between browsers and so PiperStitch Proofs can offer the same
    -- hoops and threads. Opaque JSON: the app owns the shape.
    customer_id INTEGER PRIMARY KEY REFERENCES customers(id),
    preferences TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS feedback_submissions (
    -- A customer's "send this to PiperStitch" from the web editor: the
    -- original artwork and a rendered picture of the digitized result,
    -- so an admin can review where the engine did well or poorly and
    -- feed genuinely bad cases to Claude or another model for a closer
    -- look. Images are stored as base64 right in this row (not on disk)
    -- because this database is the one thing already on a durable
    -- volume -- a separate file store would risk losing them on a
    -- redeploy, see README/DEPLOY.md.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER REFERENCES customers(id),
    customer_email TEXT NOT NULL,
    design_name TEXT NOT NULL DEFAULT '',
    stitch_count INTEGER NOT NULL DEFAULT 0,
    note TEXT NOT NULL DEFAULT '',
    original_image_data TEXT,               -- base64; NULL when the import had no separate raster original
    original_image_type TEXT NOT NULL DEFAULT 'image/png',
    digitized_image_data TEXT NOT NULL,     -- base64 PNG of the rendered stitch preview
    digitized_image_type TEXT NOT NULL DEFAULT 'image/png',
    created_at TEXT NOT NULL,
    reviewed_at TEXT,
    reviewed_by TEXT
);
CREATE INDEX IF NOT EXISTS idx_feedback_created ON feedback_submissions(created_at);

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

CREATE TABLE IF NOT EXISTS referral_clicks (
    -- One row per click on a partner's link (/r/<CODE>). The IP is hashed,
    -- never stored raw; the signed cookie set alongside is what attributes
    -- a later signup (Partner Program §5.2).
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    promotion_id INTEGER NOT NULL REFERENCES promotions(id),
    clicked_at TEXT NOT NULL,
    ip_hash TEXT NOT NULL DEFAULT '',
    user_agent TEXT NOT NULL DEFAULT '',
    landing_path TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_referral_clicks_promo ON referral_clicks(promotion_id, clicked_at);

CREATE TABLE IF NOT EXISTS partner_content (
    -- FTC monitoring log (Partner Program §10.1): where a partner posted,
    -- and whether the disclosure was present when we checked.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    promoter_id INTEGER NOT NULL REFERENCES promoters(id),
    url TEXT NOT NULL,
    platform TEXT NOT NULL DEFAULT '',
    posted_at TEXT,
    disclosure_present INTEGER,           -- 1 yes, 0 no, NULL not yet checked
    checked_at TEXT,
    note TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_partner_content_promoter ON partner_content(promoter_id);

CREATE TABLE IF NOT EXISTS backup_runs (
    -- Every attempt to put a copy of this database somewhere that isn't
    -- Railway, so "are we backed up?" has an answer rather than a hope.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service TEXT NOT NULL,
    key TEXT NOT NULL DEFAULT '',
    size_bytes INTEGER NOT NULL DEFAULT 0,
    digest TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL,                    -- ok | failed | unconfigured
    detail TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_backup_runs ON backup_runs(service, created_at);

CREATE TABLE IF NOT EXISTS page_views (
    -- First-party analytics: enough to know which channel brings people
    -- and what they read, and nothing that identifies a person. The
    -- visitor hash is a one-way digest of address, browser and the day,
    -- salted -- it cannot be turned back into anyone, it cannot follow
    -- them past midnight, and there is no cookie.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    day TEXT NOT NULL,                       -- YYYY-MM-DD, the bucket everything is counted in
    path TEXT NOT NULL DEFAULT '/',
    referrer_host TEXT NOT NULL DEFAULT '',  -- the site they came from, never the full URL
    utm_source TEXT NOT NULL DEFAULT '',
    utm_medium TEXT NOT NULL DEFAULT '',
    utm_campaign TEXT NOT NULL DEFAULT '',
    visitor_hash TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_page_views_day ON page_views(day);
CREATE INDEX IF NOT EXISTS idx_page_views_visitor ON page_views(day, visitor_hash);

CREATE TABLE IF NOT EXISTS error_log (
    -- Anything that reached a customer as a 500, and anything the browser
    -- app crashed on. Grouped by fingerprint so a storm is one row with a
    -- count rather than ten thousand.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    fingerprint TEXT NOT NULL UNIQUE,
    source TEXT NOT NULL DEFAULT 'server',   -- server | browser
    kind TEXT NOT NULL DEFAULT '',           -- exception class, or the browser's error name
    message TEXT NOT NULL DEFAULT '',
    where_ TEXT NOT NULL DEFAULT '',         -- route, or the page it happened on
    detail TEXT NOT NULL DEFAULT '',         -- traceback / stack, trimmed
    count INTEGER NOT NULL DEFAULT 1,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    resolved_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_error_log_seen ON error_log(last_seen_at);

CREATE TABLE IF NOT EXISTS partner_documents (
    -- A partner's tax form (W-9 / W-8BEN). Held as base64 in this
    -- database for the same reason the feedback images are: it is the
    -- one thing on a durable volume. Nothing pays out until one of
    -- these is accepted.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    promoter_id INTEGER NOT NULL REFERENCES promoters(id),
    kind TEXT NOT NULL DEFAULT 'w9',          -- w9 | w8ben | other
    filename TEXT NOT NULL,
    content_type TEXT NOT NULL DEFAULT 'application/pdf',
    size_bytes INTEGER NOT NULL DEFAULT 0,
    data TEXT NOT NULL,                       -- base64
    uploaded_at TEXT NOT NULL,
    accepted_at TEXT,
    accepted_by TEXT,
    rejected_at TEXT,
    note TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_partner_documents_promoter ON partner_documents(promoter_id);

CREATE TABLE IF NOT EXISTS outreach_mailboxes (
    -- The mailboxes recruitment goes out of. More than one because Google
    -- and Microsoft both start reading a single mailbox as bulk somewhere
    -- above twenty a day, and because different approaches want different
    -- senders.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    label TEXT NOT NULL,
    host TEXT NOT NULL,
    port INTEGER NOT NULL DEFAULT 587,
    username TEXT NOT NULL,
    password TEXT NOT NULL DEFAULT '',        -- sealed, like a partner's tax form
    from_email TEXT NOT NULL,
    reply_to TEXT NOT NULL DEFAULT '',        -- where their answer goes: this mailbox, or back here
    daily_cap INTEGER NOT NULL DEFAULT 20,
    active INTEGER NOT NULL DEFAULT 1,
    last_ok_at TEXT,
    last_error TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS partner_outreach_log (
    -- Every recruitment email we sent, so the whole approach is on the
    -- record rather than in someone's sent folder.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    prospect_id INTEGER NOT NULL REFERENCES partner_prospects(id),
    step INTEGER NOT NULL,
    subject TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'sent',      -- sent | failed
    error TEXT NOT NULL DEFAULT '',
    message_id TEXT,                          -- Postmark's id, so an open can be tied to which email
    opened_at TEXT,                           -- first open; see the caveats in the admin
    open_count INTEGER NOT NULL DEFAULT 0,
    clicked_at TEXT,
    click_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_partner_outreach_prospect ON partner_outreach_log(prospect_id);
-- The message_id index is created after the migration below adds the
-- column: on a database that predates it, CREATE TABLE IF NOT EXISTS
-- leaves the old table alone and an index here would name a column that
-- does not exist yet.

CREATE TABLE IF NOT EXISTS partner_code_requests (
    -- A partner asking for another code (one per channel is the usual
    -- reason). We approve them when the code fits the house rules.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    promoter_id INTEGER NOT NULL REFERENCES promoters(id),
    requested_code TEXT NOT NULL,
    reason TEXT NOT NULL DEFAULT '',          -- which channel it is for
    status TEXT NOT NULL DEFAULT 'pending',   -- pending | approved | declined
    decided_at TEXT,
    decided_note TEXT NOT NULL DEFAULT '',
    promotion_id INTEGER REFERENCES promotions(id),
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_code_requests_promoter ON partner_code_requests(promoter_id, status);

CREATE TABLE IF NOT EXISTS partner_resources (
    -- The creative kit's own library: videos, graphics and anything else
    -- we want partners to have. Managed from the admin, shown in the
    -- portal.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    url TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'video',       -- video | graphic | document | link
    description TEXT NOT NULL DEFAULT '',
    sort_order INTEGER NOT NULL DEFAULT 0,
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS partner_feedback (
    -- What partners tell us about the product. They are using it daily
    -- on real work and talking to the people who aren't buying yet, so
    -- this is the most valuable post we get (spec §7: ask for it).
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    promoter_id INTEGER NOT NULL REFERENCES promoters(id),
    topic TEXT NOT NULL DEFAULT '',           -- what it is about, in their words
    message TEXT NOT NULL,
    created_at TEXT NOT NULL,
    reviewed_at TEXT,
    reviewed_by TEXT
);
CREATE INDEX IF NOT EXISTS idx_partner_feedback_created ON partner_feedback(created_at);

CREATE TABLE IF NOT EXISTS partner_prospects (
    -- Someone who asked to see the Partner Program details. The program
    -- page carries rates and payout terms, so it sits behind a short
    -- registration rather than in public (spec §7 gating).
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL DEFAULT '',
    email TEXT NOT NULL UNIQUE,
    organization TEXT NOT NULL DEFAULT '',
    platforms TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT 'self',     -- 'self' (registered on the site) | 'invite' (we sent them a link)
    slug TEXT UNIQUE,                        -- their name, for a short personal invite link: piperstitch.com/join/ada-lovelace
    note TEXT NOT NULL DEFAULT '',
    views INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    applied_at TEXT
);

CREATE TABLE IF NOT EXISTS partner_links (
    -- One-time sign-in links to the partner portal (the same magic-link
    -- pattern as account_links, keyed by promoter instead of customer).
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    promoter_id INTEGER NOT NULL REFERENCES promoters(id),
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TEXT NOT NULL,
    consumed_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS expenses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    date TEXT NOT NULL,                 -- YYYY-MM-DD
    category TEXT NOT NULL,             -- see EXPENSE_CATEGORIES
    vendor TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    amount_cents INTEGER NOT NULL,      -- positive = money out
    source TEXT NOT NULL DEFAULT 'manual',   -- 'manual' | 'stripe' | 'recurring'
    external_id TEXT UNIQUE,            -- Stripe balance transaction id, or rec:<id>:<YYYY-MM>; makes imports idempotent
    recurring_id INTEGER,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses(date);

CREATE TABLE IF NOT EXISTS recurring_expenses (
    -- A monthly bill (Railway, Postmark, the domain): materialized into
    -- expenses for each month it covers, so the report never forgets it.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vendor TEXT NOT NULL,
    category TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    amount_cents INTEGER NOT NULL,
    day_of_month INTEGER NOT NULL DEFAULT 1,
    start_month TEXT NOT NULL,          -- YYYY-MM
    end_month TEXT,                     -- YYYY-MM inclusive; NULL = ongoing
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sent_files (
    -- The web app's Send button: who sent what to whom. Also the rate limit.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    to_email TEXT NOT NULL,
    filename TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sent_files_customer ON sent_files(customer_id, created_at);

CREATE TABLE IF NOT EXISTS email_templates (
    -- Every email the system sends, editable in the admin. Seeded from
    -- emails.py's defaults; an edited row is never overwritten by a deploy.
    key TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    subject TEXT NOT NULL,
    body TEXT NOT NULL,                 -- plain text with {placeholders}; HTML is rendered from it
    cta_label TEXT NOT NULL DEFAULT '',
    cta_url TEXT NOT NULL DEFAULT '',
    preheader TEXT NOT NULL DEFAULT '',
    placeholders TEXT NOT NULL DEFAULT '',   -- comma-separated, for the editor's help text
    edited INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS email_sequences (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    key TEXT NOT NULL UNIQUE,           -- 'trial' | 'subscriber' | 'winback'
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sequence_steps (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sequence_id INTEGER NOT NULL REFERENCES email_sequences(id),
    delay_days INTEGER NOT NULL,        -- days after the customer entered the sequence
    name TEXT NOT NULL,                 -- what the admin sees in lists
    subject TEXT NOT NULL,
    body TEXT NOT NULL,
    cta_label TEXT NOT NULL DEFAULT '',
    cta_url TEXT NOT NULL DEFAULT '',
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sequence_steps_sequence ON sequence_steps(sequence_id, delay_days);

CREATE TABLE IF NOT EXISTS sequence_deliveries (
    -- One row per customer per step: when it's due, when it went, how.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    sequence_id INTEGER NOT NULL REFERENCES email_sequences(id),
    step_id INTEGER NOT NULL REFERENCES sequence_steps(id),
    scheduled_for TEXT NOT NULL,
    sent_at TEXT,
    status TEXT NOT NULL DEFAULT 'scheduled',   -- 'scheduled' | 'sent' | 'skipped' | 'failed'
    sent_by TEXT,                       -- 'auto' | 'admin'
    note TEXT NOT NULL DEFAULT '',      -- why skipped / the error
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sequence_deliveries_customer ON sequence_deliveries(customer_id);
CREATE INDEX IF NOT EXISTS idx_sequence_deliveries_due ON sequence_deliveries(status, scheduled_for);

CREATE TABLE IF NOT EXISTS email_log (
    -- Every email we sent a customer, system or sequence, for their record.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id INTEGER REFERENCES customers(id),
    to_email TEXT NOT NULL,
    kind TEXT NOT NULL,                 -- template key, or sequence:<key>
    subject TEXT NOT NULL,
    status TEXT NOT NULL,               -- 'sent' | 'failed'
    error TEXT NOT NULL DEFAULT '',
    sent_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_email_log_customer ON email_log(customer_id, sent_at);

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

-- One row per remembered fact that belongs to the business rather than to
-- a customer. Currently just the moment PiperStitch launched, which is
-- worth keeping in the database that gets backed up rather than in
-- somebody's memory.
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    set_at TEXT NOT NULL
);
"""


def _connect() -> sqlite3.Connection:
    """One connection per unit of work. WAL is what makes that safe under
    load: with the default rollback journal a reader blocks every writer,
    so two customers arriving at once is enough to raise "database is
    locked". WAL lets readers carry on while one writer commits, and the
    busy timeout makes the writers queue politely instead of failing.
    `synchronous` is left at SQLite's FULL: this database holds money, and
    an fsync per commit is cheap at our write rate."""
    conn = sqlite3.connect(config.DATABASE_PATH, timeout=30.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL")      # persists in the file; a no-op read after the first time
    conn.execute("PRAGMA busy_timeout = 30000")
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
        _add_column_if_missing(conn, "customers", "marketing_opt_out", "INTEGER NOT NULL DEFAULT 0")
        _add_column_if_missing(conn, "projects", "thumbnail", "TEXT")   # projects saved before this stay blank until next saved
        _add_column_if_missing(conn, "partner_prospects", "slug", "TEXT")
        _add_column_if_missing(conn, "partner_prospects", "mailbox_id", "INTEGER REFERENCES outreach_mailboxes(id)")
        _add_column_if_missing(conn, "partner_outreach_log", "mailbox_id", "INTEGER")
        for col, defn in (("message_id", "TEXT"), ("opened_at", "TEXT"), ("open_count", "INTEGER NOT NULL DEFAULT 0"),
                          ("clicked_at", "TEXT"), ("click_count", "INTEGER NOT NULL DEFAULT 0")):
            _add_column_if_missing(conn, "partner_outreach_log", col, defn)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_partner_outreach_message ON partner_outreach_log(message_id)")
        _add_column_if_missing(conn, "email_log", "message_id", "TEXT")
        conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_prospect_slug ON partner_prospects(slug) WHERE slug IS NOT NULL")
        _add_column_if_missing(conn, "customers", "last_active_at", "TEXT")   # last web sign-in / app use, for "we miss you"
        # Which product a subscription is for: the app ('core') or PiperStitch Proofs ('proofs').
        _add_column_if_missing(conn, "subscriptions", "product", "TEXT NOT NULL DEFAULT 'core'")
        _add_column_if_missing(conn, "customers", "proofs_free_extra", "INTEGER NOT NULL DEFAULT 0")   # extra free proofs an admin has granted
        # Partner Program (docs: PiperStitch Partner Program build spec, §4). Additive only.
        for column, definition in (
            ("status", "TEXT NOT NULL DEFAULT 'active'"),          # applied | approved | active | suspended | closed
            ("tier", "TEXT NOT NULL DEFAULT ''"),                  # founding (30%) | standard (25%) | '' ; 'established' is DERIVED (bounty_reinstated_at), never stored
            ("bounty_window_start", "TEXT"), ("bounty_window_end", "TEXT"), ("bounty_reinstated_at", "TEXT"),
            ("payout_method", "TEXT NOT NULL DEFAULT 'paypal'"), ("payout_email", "TEXT NOT NULL DEFAULT ''"),
            ("tax_form_type", "TEXT NOT NULL DEFAULT ''"), ("tax_form_received_at", "TEXT"),
            ("platforms", "TEXT NOT NULL DEFAULT ''"), ("application", "TEXT NOT NULL DEFAULT ''"),
            ("portal_token_hash", "TEXT NOT NULL DEFAULT ''"), ("applied_at", "TEXT"), ("approved_at", "TEXT"),
            ("handles", "TEXT NOT NULL DEFAULT ''"),               # channel links they gave us when applying
            ("payout_name", "TEXT NOT NULL DEFAULT ''"),           # the name on the PayPal account
            ("payout_country", "TEXT NOT NULL DEFAULT ''"),
        ):
            _add_column_if_missing(conn, "promoters", column, definition)
        _add_column_if_missing(conn, "promotions", "trial_days", "INTEGER")                          # NULL = config.TRIAL_DAYS
        _add_column_if_missing(conn, "promotions", "proofs_extra", "INTEGER NOT NULL DEFAULT 0")     # added to customers.proofs_free_extra (max, never stacked)
        _add_column_if_missing(conn, "promotions", "commission_months", "INTEGER")                   # NULL = uncapped (legacy); 24 for partners
        _add_column_if_missing(conn, "promo_redemptions", "first_payment_at", "TEXT")                 # immutable once written (R3)
        _add_column_if_missing(conn, "promo_redemptions", "term_ends_at", "TEXT")
        _add_column_if_missing(conn, "promo_redemptions", "bounty_payout_id", "INTEGER REFERENCES promo_payouts(id)")
        _add_column_if_missing(conn, "promo_redemptions", "attribution_source", "TEXT NOT NULL DEFAULT 'code'")   # code | link | manual
        _add_column_if_missing(conn, "promo_redemptions", "attribution_locked", "INTEGER NOT NULL DEFAULT 0")
        _add_column_if_missing(conn, "promo_payouts", "kind", "TEXT NOT NULL DEFAULT 'recurring'")   # recurring | bounty | reversal
        _add_column_if_missing(conn, "promo_payouts", "reverses_payout_id", "INTEGER REFERENCES promo_payouts(id)")
        _add_column_if_missing(conn, "promo_payouts", "note", "TEXT NOT NULL DEFAULT ''")
        _add_column_if_missing(conn, "stripe_events", "result", "TEXT NOT NULL DEFAULT ''")
        _add_column_if_missing(conn, "partner_resources", "announced_at", "TEXT")          # when partners were told about it
        _add_column_if_missing(conn, "partner_resources", "announce_queued_at", "TEXT")    # the scheduler sends it, not the request
        _add_column_if_missing(conn, "web_sessions", "expires_at", "TEXT")                 # sliding; NULL on rows that predate it
        _add_column_if_missing(conn, "customers", "deleted_at", "TEXT")                    # erased on request; the row stays for the books
        # Where this customer came from, captured once at signup. Named
        # apart from the existing `source`, which says how the *record*
        # was created ('web_trial', 'website_registration') and means
        # something quite different.
        for column in ("acq_source", "acq_medium", "acq_campaign", "acq_landing"):
            _add_column_if_missing(conn, "customers", column, "TEXT NOT NULL DEFAULT ''")
        _add_column_if_missing(conn, "partner_outreach_log", "direction", "TEXT NOT NULL DEFAULT 'out'")   # out = we wrote; in = they replied
        _add_column_if_missing(conn, "partner_outreach_log", "body", "TEXT NOT NULL DEFAULT ''")           # the reply itself
        for column, definition in (                                                        # recruitment (spec §8: bring partners in)
            ("outreach_step", "INTEGER NOT NULL DEFAULT 0"), ("outreach_next_at", "TEXT"),
            ("outreach_status", "TEXT NOT NULL DEFAULT ''"),   # '' = not being recruited; active | done | stopped | opted_out
            ("opted_out_at", "TEXT"),
        ):
            _add_column_if_missing(conn, "partner_prospects", column, definition)


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


# ------------------------------------------------------------------ settings --


def get_setting(key: str) -> Optional[str]:
    with connection() as conn:
        row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else None


def set_setting(key: str, value: str, *, only_once: bool = False) -> bool:
    """True when this call is the one that set it. `only_once` refuses to
    overwrite -- the launch moment happened once, and a second click on a
    button should not quietly rewrite history."""
    with connection() as conn:
        if only_once and conn.execute("SELECT 1 FROM settings WHERE key = ?", (key,)).fetchone():
            return False
        conn.execute("INSERT INTO settings (key, value, set_at) VALUES (?, ?, ?) "
                     "ON CONFLICT(key) DO UPDATE SET value = excluded.value, set_at = excluded.set_at",
                     (key, value, now_iso()))
    return True


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


def update_customer_name(customer_id: int, name: str) -> None:
    with connection() as conn:
        conn.execute("UPDATE customers SET name = ?, updated_at = ? WHERE id = ?", (name.strip()[:120], _now(), customer_id))


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
       (SELECT status FROM subscriptions s WHERE s.customer_id = customers.id AND s.product = 'core'
          ORDER BY (s.status IN ('active','trialing','past_due','comp')) DESC, s.current_period_end DESC LIMIT 1) AS sub_status,
       (SELECT current_period_end FROM subscriptions s WHERE s.customer_id = customers.id AND s.product = 'core'
          ORDER BY (s.status IN ('active','trialing','past_due','comp')) DESC, s.current_period_end DESC LIMIT 1) AS sub_period_end,
       (SELECT status FROM subscriptions s WHERE s.customer_id = customers.id AND s.product = 'proofs'
          ORDER BY (s.status IN ('active','trialing','past_due','comp')) DESC, s.current_period_end DESC LIMIT 1) AS proofs_status,
       (SELECT COUNT(*) FROM proofs_uses u WHERE u.customer_id = customers.id) AS proofs_used,
       (SELECT COUNT(*) FROM subscriptions s WHERE s.customer_id = customers.id AND s.product = 'core') AS subscription_count,
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


# Everything of a customer's that hangs off their id, for the two things
# a person is entitled to ask for: a copy, and an erasure.
_CUSTOMER_OWNED = [
    "devices", "account_links", "web_sessions", "web_handoffs", "projects", "web_preferences",
    "feedback_submissions", "sent_files", "sequence_deliveries", "email_log", "proofs_uses", "subscription_events", "promo_redemptions",
]


def export_customer(customer_id: int) -> dict:
    """Everything we hold about one person, as plain data. Stripe keeps
    its own copy of the billing side; this is ours."""
    with connection() as conn:
        customer = conn.execute("SELECT * FROM customers WHERE id = ?", (customer_id,)).fetchone()
        if customer is None:
            return {}
        out: dict = {"account": {k: customer[k] for k in customer.keys() if k != "id"},
                     "subscriptions": [], "payments": [], "activity": [], "projects": [], "sessions": [], "devices": [], "emails_we_sent": []}
        out["subscriptions"] = [dict(r) for r in conn.execute("SELECT * FROM subscriptions WHERE customer_id = ?", (customer_id,)).fetchall()]
        out["payments"] = [dict(r) for r in conn.execute("SELECT * FROM payments WHERE customer_id = ?", (customer_id,)).fetchall()]
        out["activity"] = [dict(r) for r in conn.execute("SELECT kind, detail, created_at FROM subscription_events WHERE customer_id = ? ORDER BY created_at", (customer_id,)).fetchall()]
        out["projects"] = [{"id": r["id"], "name": r["name"], "created_at": r["created_at"], "updated_at": r["updated_at"]}
                           for r in conn.execute("SELECT id, name, created_at, updated_at FROM projects WHERE customer_id = ?", (customer_id,)).fetchall()]
        out["sessions"] = [{"user_agent": r["user_agent"], "created_at": r["created_at"], "last_seen_at": r["last_seen_at"], "revoked_at": r["revoked_at"]}
                           for r in conn.execute("SELECT * FROM web_sessions WHERE customer_id = ?", (customer_id,)).fetchall()]
        out["devices"] = [{"device_name": r["device_name"], "created_at": r["created_at"], "revoked_at": r["revoked_at"]}
                          for r in conn.execute("SELECT * FROM devices WHERE customer_id = ?", (customer_id,)).fetchall()]
        out["emails_we_sent"] = [{"kind": r["kind"], "subject": r["subject"], "status": r["status"], "sent_at": r["sent_at"]}
                                 for r in conn.execute("SELECT * FROM email_log WHERE customer_id = ? ORDER BY sent_at", (customer_id,)).fetchall()]
    return out


def erase_customer(customer_id: int) -> dict:
    """Erasure that keeps the books straight: everything personal goes,
    and the rows an accountant needs -- what was paid, and the partner
    commission that arose from it -- stay with the person cut out of
    them. Stripe holds the authoritative billing record either way."""
    removed: dict[str, int] = {}
    with connection() as conn:
        for table in _CUSTOMER_OWNED:
            cur = conn.execute(f"DELETE FROM {table} WHERE customer_id = ?", (customer_id,))
            if cur.rowcount:
                removed[table] = cur.rowcount
        # Sign-in codes are keyed by address, not id.
        email = (conn.execute("SELECT email FROM customers WHERE id = ?", (customer_id,)).fetchone() or {"email": ""})["email"]
        if email:
            cur = conn.execute("DELETE FROM activation_codes WHERE email = ?", (email,))
            if cur.rowcount:
                removed["activation_codes"] = cur.rowcount
        conn.execute("UPDATE checkout_sessions SET customer_id = NULL, customer_name = '', customer_email = '' WHERE customer_id = ?", (customer_id,))
        conn.execute("UPDATE promo_payouts SET customer_id = NULL WHERE customer_id = ?", (customer_id,))
        conn.execute("UPDATE subscriptions SET notes = '' WHERE customer_id = ?", (customer_id,))
        conn.execute(
            "UPDATE customers SET name = 'Deleted account', email = ?, stripe_customer_id = stripe_customer_id, notes = '', marketing_opt_out = 1, deleted_at = ? WHERE id = ?",
            (f"deleted+{customer_id}@piperstitch.invalid", _now(), customer_id))
    return removed


# Tables that hold customers and what they did, as against the shop's own
# configuration (email templates and sequences, promoters and promotions,
# expenses, published updates), which a fresh start keeps.
CUSTOMER_DATA_TABLES = [
    "web_handoffs", "proofs_uses", "subscription_events", "payments", "checkout_sessions", "devices",
    "activation_codes", "account_links", "web_sessions", "projects", "web_preferences", "feedback_submissions",
    "promo_redemptions", "sent_files", "sequence_deliveries", "email_log", "stripe_events", "subscriptions", "customers",
]


def customer_data_counts() -> dict[str, int]:
    with connection() as conn:
        return {t: conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in CUSTOMER_DATA_TABLES}


def reset_customer_data() -> dict[str, int]:
    """Empties every customer table -- the clean start before going live,
    after testing against Stripe's sandbox. Configuration stays. Returns
    what was removed. Stripe is not touched: the test-mode customers and
    subscriptions live in the sandbox and are simply left behind."""
    counts = customer_data_counts()
    with connection() as conn:
        for table in CUSTOMER_DATA_TABLES:
            conn.execute(f"DELETE FROM {table}")
        # Promotions keep their definitions but forget test-mode redemptions
        # counted on them, if the table tracks a tally.
        cols = {row[1] for row in conn.execute("PRAGMA table_info(promotions)").fetchall()}
        for col in ("redemption_count", "times_redeemed", "uses"):
            if col in cols:
                conn.execute(f"UPDATE promotions SET {col} = 0")
        try:
            conn.execute("DELETE FROM sqlite_sequence WHERE name IN (%s)" % ",".join("?" * len(CUSTOMER_DATA_TABLES)), CUSTOMER_DATA_TABLES)
        except sqlite3.OperationalError:
            pass  # no AUTOINCREMENT tables
    with connection() as conn:
        conn.execute("VACUUM")
    return counts


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
    product: str = "core",
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
                "cancel_at_period_end = ?, canceled_at = ?, ended_at = ?, amount_cents = COALESCE(?, amount_cents), product = ?, updated_at = ? WHERE id = ?",
                (customer_id, stripe_customer_id, status, current_period_start, current_period_end, int(cancel_at_period_end), canceled_at, ended_at, amount_cents, product, now, existing["id"]),
            )
            return existing["id"]
        cur = conn.execute(
            "INSERT INTO subscriptions (customer_id, stripe_subscription_id, stripe_customer_id, status, current_period_start, current_period_end, "
            "cancel_at_period_end, canceled_at, ended_at, source, amount_cents, notes, product, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (customer_id, stripe_subscription_id, stripe_customer_id, status, current_period_start, current_period_end, int(cancel_at_period_end), canceled_at, ended_at, source, amount_cents, notes, product, now, now),
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


def best_subscription_for_customer(customer_id: int, product: str = "core") -> Optional[sqlite3.Row]:
    """The subscription that decides this person's access to `product`
    (the app by default; 'proofs' for PiperStitch Proofs): an entitled one
    with the latest period end if there is one, otherwise whichever ended
    most recently (so the account page can say *when* access lapsed)."""
    with connection() as conn:
        return conn.execute(
            "SELECT * FROM subscriptions WHERE customer_id = ? AND product = ? "
            "ORDER BY (status IN ('active','trialing','past_due','comp')) DESC, COALESCE(current_period_end, '') DESC, created_at DESC LIMIT 1",
            (customer_id, product),
        ).fetchone()


def count_proofs_used(customer_id: int) -> int:
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM proofs_uses WHERE customer_id = ?", (customer_id,)).fetchone()[0]


def record_proof_use(customer_id: int, proof_ref: str) -> bool:
    """True when this proof is newly counted; False when it was already."""
    with connection() as conn:
        try:
            conn.execute("INSERT INTO proofs_uses (customer_id, proof_ref, used_at) VALUES (?, ?, ?)", (customer_id, proof_ref, _now()))
            return True
        except sqlite3.IntegrityError:
            return False


def add_free_proofs(customer_id: int, count: int) -> None:
    with connection() as conn:
        conn.execute("UPDATE customers SET proofs_free_extra = proofs_free_extra + ?, updated_at = ? WHERE id = ?", (int(count), _now(), customer_id))


_SUBSCRIPTIONS_WITH_CUSTOMER = (
    "SELECT subscriptions.*, customers.name AS customer_name, customers.email AS customer_email "
    "FROM subscriptions JOIN customers ON customers.id = subscriptions.customer_id"
)


def list_subscriptions(query: str = "", status: str = "", limit: int = 300, product: str = "") -> list[sqlite3.Row]:
    clauses, params = [], []
    if product:
        clauses.append("subscriptions.product = ?")
        params.append(product)
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


def record_stripe_event(event_id: str, event_type: str, result: str = "") -> None:
    """`result` is empty when the event applied cleanly; otherwise the
    error, so the Partners page can list webhooks that need a look."""
    with connection() as conn:
        conn.execute("INSERT OR IGNORE INTO stripe_events (id, type, processed_at, result) VALUES (?, ?, ?, ?)", (event_id, event_type, _now(), (result or "")[:500]))


def list_failed_stripe_events(limit: int = 20) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM stripe_events WHERE result != '' ORDER BY processed_at DESC LIMIT ?", (limit,)).fetchall()


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
            "FROM subscriptions WHERE product = 'core'",
            (config.MONTHLY_PRICE_CENTS, month_start, month_start),
        ).fetchone()
        proofs_row = conn.execute(
            "SELECT "
            "SUM(CASE WHEN status IN ('active','trialing','past_due') AND source = 'stripe' THEN 1 ELSE 0 END) AS paying, "
            "SUM(CASE WHEN status = 'comp' THEN 1 ELSE 0 END) AS comps, "
            "SUM(CASE WHEN status IN ('active','trialing','past_due') AND source = 'stripe' THEN COALESCE(amount_cents, ?) ELSE 0 END) AS mrr_cents, "
            "SUM(CASE WHEN source = 'stripe' AND created_at >= ? THEN 1 ELSE 0 END) AS new_this_month "
            "FROM subscriptions WHERE product = 'proofs'",
            (config.PROOFS_MONTHLY_PRICE_CENTS, month_start),
        ).fetchone()
        proofs_trialists = conn.execute("SELECT COUNT(DISTINCT customer_id) FROM proofs_uses").fetchone()[0]
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
        "proofs_paying": proofs_row["paying"] or 0,
        "proofs_comps": proofs_row["comps"] or 0,
        "proofs_mrr_cents": proofs_row["mrr_cents"] or 0,
        "proofs_new_this_month": proofs_row["new_this_month"] or 0,
        "proofs_trialists": proofs_trialists or 0,
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


WEB_SESSION_DAYS = 90


def _session_expiry() -> str:
    return (datetime.utcnow() + timedelta(days=WEB_SESSION_DAYS)).isoformat(timespec="seconds") + "Z"


def create_web_session(*, customer_id: int, token_hash: str, user_agent: str) -> int:
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO web_sessions (customer_id, token_hash, user_agent, created_at, last_seen_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
            (customer_id, token_hash, user_agent[:200], _now(), _now(), _session_expiry()),
        )
        return cur.lastrowid


def create_handoff(*, customer_id: int, code_hash: str, target: str, ttl_seconds: int) -> int:
    with connection() as conn:
        expires = (datetime.utcnow() + timedelta(seconds=ttl_seconds)).isoformat(timespec="seconds") + "Z"
        cur = conn.execute("INSERT INTO web_handoffs (customer_id, code_hash, target, expires_at, created_at) VALUES (?, ?, ?, ?, ?)",
                           (customer_id, code_hash, target, expires, _now()))
        return cur.lastrowid


def consume_handoff(code_hash: str) -> Optional[sqlite3.Row]:
    """The handoff row if the code is live, marking it used; None otherwise."""
    with connection() as conn:
        row = conn.execute("SELECT * FROM web_handoffs WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?", (code_hash, _now())).fetchone()
        if row is None:
            return None
        conn.execute("UPDATE web_handoffs SET used_at = ? WHERE id = ?", (_now(), row["id"]))
        return row


def get_web_session_by_token_hash(token_hash: str) -> Optional[sqlite3.Row]:
    """A live session. Tokens used to be good for ever, which made a
    stolen one permanent; they now lapse WEB_SESSION_DAYS after their
    last use. Rows from before the column existed have no expiry and are
    given one the next time they're used."""
    with connection() as conn:
        return conn.execute("SELECT * FROM web_sessions WHERE token_hash = ? AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?)",
                            (token_hash, _now())).fetchone()


def get_web_session(session_row_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM web_sessions WHERE id = ?", (session_row_id,)).fetchone()


def touch_web_session(session_row_id: int) -> None:
    """Sliding: using the app keeps you signed in, quiet for three months
    signs you out."""
    with connection() as conn:
        conn.execute("UPDATE web_sessions SET last_seen_at = ?, expires_at = ? WHERE id = ?", (_now(), _session_expiry(), session_row_id))


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
            "SELECT id, customer_id, name, width_mm, height_mm, object_count, (thumbnail IS NOT NULL) AS has_thumbnail, created_at, updated_at "
            "FROM projects WHERE customer_id = ? ORDER BY updated_at DESC",
            (customer_id,),
        ).fetchall()


def get_project_thumbnail(customer_id: int, project_id: str) -> Optional[str]:
    """Fetched one at a time and never with the list: at 200 projects a
    picture each would make listing them a multi-megabyte download, and
    most are never looked at."""
    with connection() as conn:
        row = conn.execute("SELECT thumbnail FROM projects WHERE id = ? AND customer_id = ?", (project_id, customer_id)).fetchone()
    return row["thumbnail"] if row else None


def count_projects(customer_id: int) -> int:
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM projects WHERE customer_id = ?", (customer_id,)).fetchone()[0]


def get_project(customer_id: int, project_id: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM projects WHERE id = ? AND customer_id = ?", (project_id, customer_id)).fetchone()


def get_preferences(customer_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT preferences, updated_at FROM web_preferences WHERE customer_id = ?", (customer_id,)).fetchone()


def save_preferences(customer_id: int, preferences: str) -> str:
    now = _now()
    with connection() as conn:
        conn.execute(
            "INSERT INTO web_preferences (customer_id, preferences, updated_at) VALUES (?, ?, ?) "
            "ON CONFLICT(customer_id) DO UPDATE SET preferences = excluded.preferences, updated_at = excluded.updated_at",
            (customer_id, preferences, now),
        )
    return now


def save_project(*, customer_id: int, project_id: str, name: str, document: str, width_mm: float, height_mm: float, object_count: int,
                 thumbnail: Optional[str] = None) -> bool:
    """Insert or replace. Returns True when created. A project id that
    belongs to another customer is simply not theirs to overwrite.

    A thumbnail of None leaves whatever is already stored alone -- an
    older client that does not send one must not blank the picture."""
    now = _now()
    with connection() as conn:
        existing = conn.execute("SELECT customer_id FROM projects WHERE id = ?", (project_id,)).fetchone()
        if existing is not None and existing["customer_id"] != customer_id:
            raise PermissionError("project belongs to another customer")
        if existing is None:
            conn.execute(
                "INSERT INTO projects (id, customer_id, name, document, width_mm, height_mm, object_count, thumbnail, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (project_id, customer_id, name, document, width_mm, height_mm, object_count, thumbnail, now, now),
            )
            return True
        if thumbnail is None:
            conn.execute(
                "UPDATE projects SET name = ?, document = ?, width_mm = ?, height_mm = ?, object_count = ?, updated_at = ? WHERE id = ?",
                (name, document, width_mm, height_mm, object_count, now, project_id),
            )
        else:
            conn.execute(
                "UPDATE projects SET name = ?, document = ?, width_mm = ?, height_mm = ?, object_count = ?, thumbnail = ?, updated_at = ? WHERE id = ?",
                (name, document, width_mm, height_mm, object_count, thumbnail, now, project_id),
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


def update_partner_fields(promoter_id: int, **fields) -> None:
    """The Partner Program's own columns on a promoter (status, tier,
    bounty window, payout and tax details), whichever are given."""
    allowed = {"status", "tier", "bounty_window_start", "bounty_window_end", "bounty_reinstated_at", "payout_method", "payout_email",
               "payout_name", "payout_country", "tax_form_type", "tax_form_received_at", "platforms", "handles", "application",
               "portal_token_hash", "applied_at", "approved_at"}
    sets = {k: v for k, v in fields.items() if k in allowed}
    if not sets:
        return
    with connection() as conn:
        conn.execute("UPDATE promoters SET " + ", ".join(f"{k} = ?" for k in sets) + ", updated_at = ? WHERE id = ?", (*sets.values(), _now(), promoter_id))


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


def list_partners(status: Optional[str] = None) -> list[sqlite3.Row]:
    """Promoters in the Partner Program (a tier, or an application on
    file), with what the partner list shows (spec §8)."""
    sql = (
        "SELECT p.*, "
        "(SELECT COUNT(*) FROM promotions WHERE promotions.promoter_id = p.id) AS code_count, "
        "(SELECT COUNT(*) FROM referral_clicks c JOIN promotions ON promotions.id = c.promotion_id WHERE promotions.promoter_id = p.id) AS clicks, "
        "(SELECT COUNT(DISTINCT r.customer_id) FROM promo_redemptions r JOIN promotions ON promotions.id = r.promotion_id WHERE promotions.promoter_id = p.id) AS referrals "
        "FROM promoters p WHERE (p.tier != '' OR p.status != 'active' OR p.applied_at IS NOT NULL)"
    )
    args: tuple = ()
    if status:
        sql += " AND p.status = ?"; args = (status,)
    sql += " ORDER BY CASE p.status WHEN 'applied' THEN 0 WHEN 'approved' THEN 1 WHEN 'active' THEN 2 WHEN 'suspended' THEN 3 ELSE 4 END, p.applied_at DESC, p.name COLLATE NOCASE"
    with connection() as conn:
        return conn.execute(sql, args).fetchall()


def get_promoter_by_email(email: str) -> Optional[sqlite3.Row]:
    """A partner by the address they sign in with -- their contact email
    or their payout email."""
    e = (email or "").strip().lower()
    if not e:
        return None
    with connection() as conn:
        return conn.execute("SELECT * FROM promoters WHERE email = ? OR (payout_email != '' AND payout_email = ?) ORDER BY active DESC, id LIMIT 1", (e, e)).fetchone()


def create_partner_application(*, name: str, email: str, organization: str, platforms: str, application: str, handles: str = "") -> int:
    """A public application: a promoter in status 'applied' with no
    codes, waiting in the admin queue."""
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO promoters (name, email, organization, default_share_pct, notes, active, status, platforms, handles, application, applied_at, created_at, updated_at) "
            "VALUES (?, ?, ?, 0, '', 1, 'applied', ?, ?, ?, ?, ?, ?)",
            (name.strip(), email.strip().lower(), organization.strip(), platforms.strip(), handles.strip(), application.strip(), _now(), _now(), _now()),
        )
        return cur.lastrowid


# ------------------------------------------ code requests, kit, feedback --


def create_code_request(*, promoter_id: int, requested_code: str, reason: str) -> int:
    with connection() as conn:
        cur = conn.execute("INSERT INTO partner_code_requests (promoter_id, requested_code, reason, created_at) VALUES (?, ?, ?, ?)",
                           (promoter_id, requested_code.strip().upper(), reason.strip(), _now()))
        return cur.lastrowid


def get_code_request(request_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT r.*, promoters.name AS promoter_name, promoters.default_share_pct, promoters.tier FROM partner_code_requests r "
                            "JOIN promoters ON promoters.id = r.promoter_id WHERE r.id = ?", (request_id,)).fetchone()


def list_code_requests(*, promoter_id: Optional[int] = None, status: str = "") -> list[sqlite3.Row]:
    sql = ("SELECT r.*, promoters.name AS promoter_name, promoters.email AS promoter_email FROM partner_code_requests r "
           "JOIN promoters ON promoters.id = r.promoter_id WHERE 1 = 1")
    args: list = []
    if promoter_id:
        sql += " AND r.promoter_id = ?"; args.append(promoter_id)
    if status:
        sql += " AND r.status = ?"; args.append(status)
    sql += " ORDER BY r.created_at DESC"
    with connection() as conn:
        return conn.execute(sql, args).fetchall()


def decide_code_request(request_id: int, *, status: str, note: str = "", promotion_id: Optional[int] = None) -> None:
    with connection() as conn:
        conn.execute("UPDATE partner_code_requests SET status = ?, decided_at = ?, decided_note = ?, promotion_id = ? WHERE id = ?",
                     (status, _now(), note.strip(), promotion_id, request_id))


def count_pending_code_requests() -> int:
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM partner_code_requests WHERE status = 'pending'").fetchone()[0]


def add_partner_resource(*, title: str, url: str, kind: str, description: str, sort_order: int = 0) -> int:
    with connection() as conn:
        cur = conn.execute("INSERT INTO partner_resources (title, url, kind, description, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                           (title.strip(), url.strip(), kind, description.strip(), sort_order, _now()))
        return cur.lastrowid


def list_partner_resources(*, active_only: bool = False) -> list[sqlite3.Row]:
    with connection() as conn:
        sql = "SELECT * FROM partner_resources"
        if active_only:
            sql += " WHERE active = 1"
        return conn.execute(sql + " ORDER BY sort_order, id").fetchall()


def get_partner_resource(resource_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM partner_resources WHERE id = ?", (resource_id,)).fetchone()


def update_partner_resource(resource_id: int, *, title: str, url: str, kind: str, description: str, sort_order: int, active: bool) -> None:
    with connection() as conn:
        conn.execute("UPDATE partner_resources SET title = ?, url = ?, kind = ?, description = ?, sort_order = ?, active = ? WHERE id = ?",
                     (title.strip(), url.strip(), kind, description.strip(), sort_order, 1 if active else 0, resource_id))


def delete_partner_resource(resource_id: int) -> None:
    with connection() as conn:
        conn.execute("DELETE FROM partner_resources WHERE id = ?", (resource_id,))


def add_partner_feedback(*, promoter_id: int, topic: str, message: str) -> int:
    with connection() as conn:
        cur = conn.execute("INSERT INTO partner_feedback (promoter_id, topic, message, created_at) VALUES (?, ?, ?, ?)",
                           (promoter_id, topic.strip(), message.strip(), _now()))
        return cur.lastrowid


def list_partner_feedback(*, promoter_id: Optional[int] = None, limit: int = 100) -> list[sqlite3.Row]:
    sql = ("SELECT f.*, promoters.name AS promoter_name FROM partner_feedback f JOIN promoters ON promoters.id = f.promoter_id")
    args: list = []
    if promoter_id:
        sql += " WHERE f.promoter_id = ?"; args.append(promoter_id)
    sql += " ORDER BY f.created_at DESC LIMIT ?"; args.append(limit)
    with connection() as conn:
        return conn.execute(sql, args).fetchall()


def mark_partner_feedback_reviewed(feedback_id: int, by: str = "admin") -> None:
    with connection() as conn:
        conn.execute("UPDATE partner_feedback SET reviewed_at = ?, reviewed_by = ? WHERE id = ?", (_now(), by, feedback_id))


def count_unreviewed_partner_feedback() -> int:
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM partner_feedback WHERE reviewed_at IS NULL").fetchone()[0]


def create_partner_prospect(*, name: str, email: str, organization: str = "", platforms: str = "", source: str = "self", note: str = "") -> int:
    """Records who asked for the program details. Returning with the same
    address updates what they told us rather than making a second row."""
    email = (email or "").strip().lower()
    with connection() as conn:
        existing = conn.execute("SELECT id FROM partner_prospects WHERE email = ?", (email,)).fetchone()
        if existing:
            conn.execute(
                "UPDATE partner_prospects SET name = COALESCE(NULLIF(?, ''), name), organization = COALESCE(NULLIF(?, ''), organization), "
                "platforms = COALESCE(NULLIF(?, ''), platforms), note = COALESCE(NULLIF(?, ''), note) WHERE id = ?",
                (name.strip(), organization.strip(), platforms.strip(), note.strip(), existing["id"]))
            return existing["id"]
        cur = conn.execute(
            "INSERT INTO partner_prospects (name, email, organization, platforms, source, note, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (name.strip(), email, organization.strip(), platforms.strip(), source, note.strip(), _now()))
        return cur.lastrowid


def get_prospect_by_slug(slug: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM partner_prospects WHERE slug = ?", (slug,)).fetchone()


def set_prospect_slug(prospect_id: int, slug: str) -> None:
    with connection() as conn:
        conn.execute("UPDATE partner_prospects SET slug = ? WHERE id = ?", (slug, prospect_id))


def slug_taken(slug: str) -> bool:
    with connection() as conn:
        return conn.execute("SELECT 1 FROM partner_prospects WHERE slug = ?", (slug,)).fetchone() is not None


def get_partner_prospect(prospect_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM partner_prospects WHERE id = ?", (prospect_id,)).fetchone()


def get_partner_prospect_by_email(email: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM partner_prospects WHERE email = ?", ((email or "").strip().lower(),)).fetchone()


def touch_partner_prospect(prospect_id: int) -> None:
    with connection() as conn:
        conn.execute("UPDATE partner_prospects SET views = views + 1, last_seen_at = ? WHERE id = ?", (_now(), prospect_id))


def mark_prospect_applied(email: str) -> None:
    """They applied, so the recruitment sequence has done its job and
    stops -- nobody should be chased after saying yes."""
    with connection() as conn:
        conn.execute("UPDATE partner_prospects SET applied_at = COALESCE(applied_at, ?), outreach_status = CASE WHEN outreach_status = 'active' THEN 'done' ELSE outreach_status END, "
                     "outreach_next_at = NULL WHERE email = ?", (_now(), (email or "").strip().lower()))


def list_partner_prospects(limit: int = 200) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM partner_prospects ORDER BY COALESCE(last_seen_at, created_at) DESC LIMIT ?", (limit,)).fetchall()


def count_partner_prospects() -> dict:
    with connection() as conn:
        r = conn.execute("SELECT COUNT(*) AS total, SUM(CASE WHEN applied_at IS NOT NULL THEN 1 ELSE 0 END) AS applied, "
                         "SUM(CASE WHEN last_seen_at IS NULL THEN 1 ELSE 0 END) AS never_opened FROM partner_prospects").fetchone()
    return {"total": r["total"] or 0, "applied": r["applied"] or 0, "never_opened": r["never_opened"] or 0}


def backup_to(path: str) -> int:
    """A consistent copy of the database, taken through SQLite's own
    backup API so it is safe to run while the service is serving (a plain
    file copy of a live WAL database is not). Returns the size in bytes."""
    import sqlite3 as _sqlite3

    source = _connect()
    try:
        target = _sqlite3.connect(path)
        try:
            source.backup(target)
            target.execute("VACUUM")
        finally:
            target.close()
    finally:
        source.close()
    return os.path.getsize(path)


# ----------------------------------------------------------- backups --


def record_backup(*, service: str, key: str, size_bytes: int, digest: str, status: str, detail: str = "") -> int:
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO backup_runs (service, key, size_bytes, digest, status, detail, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (service, key, size_bytes, digest, status, detail[:2000], _now()))
        return cur.lastrowid


def last_backup(*, service: str, status: str = "") -> Optional[sqlite3.Row]:
    sql = "SELECT * FROM backup_runs WHERE service = ?"
    args: list = [service]
    if status:
        sql += " AND status = ?"; args.append(status)
    with connection() as conn:
        return conn.execute(sql + " ORDER BY created_at DESC LIMIT 1", args).fetchone()


def recent_backups(*, service: str = "", limit: int = 10) -> list[sqlite3.Row]:
    sql = "SELECT * FROM backup_runs"
    args: list = []
    if service:
        sql += " WHERE service = ?"; args.append(service)
    args.append(limit)
    with connection() as conn:
        return conn.execute(sql + " ORDER BY created_at DESC LIMIT ?", args).fetchall()


# --------------------------------------------------------- analytics --


def record_page_view(*, day: str, path: str, referrer_host: str, utm_source: str, utm_medium: str, utm_campaign: str, visitor_hash: str) -> None:
    with connection() as conn:
        conn.execute(
            "INSERT INTO page_views (day, path, referrer_host, utm_source, utm_medium, utm_campaign, visitor_hash, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (day, path[:200], referrer_host[:120], utm_source[:60], utm_medium[:60], utm_campaign[:80], visitor_hash, _now()))


def traffic_by_day(*, since: str) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(
            "SELECT day, COUNT(*) AS views, COUNT(DISTINCT visitor_hash) AS visitors FROM page_views WHERE day >= ? GROUP BY day ORDER BY day", (since,)).fetchall()


def traffic_totals(*, since: str) -> dict:
    with connection() as conn:
        r = conn.execute("SELECT COUNT(*) AS views, COUNT(DISTINCT visitor_hash) AS visitors FROM page_views WHERE day >= ?", (since,)).fetchone()
    return {"views": r["views"] or 0, "visitors": r["visitors"] or 0}


def _top(column: str, *, since: str, limit: int, where: str = "") -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(
            f"SELECT {column} AS value, COUNT(*) AS views, COUNT(DISTINCT visitor_hash) AS visitors FROM page_views "
            f"WHERE day >= ? {where} GROUP BY {column} ORDER BY visitors DESC, views DESC LIMIT ?", (since, limit)).fetchall()


def top_pages(*, since: str, limit: int = 12) -> list[sqlite3.Row]:
    return _top("path", since=since, limit=limit)


def top_referrers(*, since: str, limit: int = 12) -> list[sqlite3.Row]:
    return _top("referrer_host", since=since, limit=limit, where="AND referrer_host != ''")


def top_campaigns(*, since: str, limit: int = 12) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(
            "SELECT utm_source AS source, utm_medium AS medium, utm_campaign AS campaign, COUNT(*) AS views, COUNT(DISTINCT visitor_hash) AS visitors "
            "FROM page_views WHERE day >= ? AND utm_source != '' GROUP BY source, medium, campaign ORDER BY visitors DESC LIMIT ?", (since, limit)).fetchall()


def prune_page_views(*, before: str) -> int:
    """Kept for a season, not for ever: the counts are what matter and a
    row per view isn't worth holding once it has been read."""
    with connection() as conn:
        return conn.execute("DELETE FROM page_views WHERE day < ?", (before,)).rowcount


def set_customer_source(customer_id: int, *, source: str, medium: str, campaign: str, landing_page: str) -> None:
    """Written once, at signup: which channel earned this account. Later
    visits never overwrite it -- somebody who finds us through a video
    and returns a week later by typing the address was earned by the
    video."""
    if not any((source, medium, campaign, landing_page)):
        return
    with connection() as conn:
        conn.execute(
            "UPDATE customers SET acq_source = CASE WHEN acq_source = '' THEN ? ELSE acq_source END, "
            "acq_medium = CASE WHEN acq_medium = '' THEN ? ELSE acq_medium END, "
            "acq_campaign = CASE WHEN acq_campaign = '' THEN ? ELSE acq_campaign END, "
            "acq_landing = CASE WHEN acq_landing = '' THEN ? ELSE acq_landing END WHERE id = ?",
            (source[:60], medium[:60], campaign[:80], landing_page[:200], customer_id))


def signups_by_source(*, since: str) -> list[sqlite3.Row]:
    """The end of the funnel: who actually started, and who paid, by where
    they came from. This is the number the tracking exists for."""
    with connection() as conn:
        return conn.execute(
            "SELECT CASE WHEN customers.acq_source = '' THEN 'direct / unknown' ELSE customers.acq_source END AS source, "
            "customers.acq_medium AS medium, customers.acq_campaign AS campaign, COUNT(*) AS signups, "
            "SUM(CASE WHEN EXISTS (SELECT 1 FROM subscriptions s WHERE s.customer_id = customers.id AND s.source = 'stripe') THEN 1 ELSE 0 END) AS subscribed "
            "FROM customers WHERE customers.created_at >= ? AND customers.deleted_at IS NULL "
            "GROUP BY source, customers.acq_medium, customers.acq_campaign ORDER BY signups DESC", (since,)).fetchall()


# ------------------------------------------------------------- errors --


def record_error(*, fingerprint: str, source: str, kind: str, message: str, where: str, detail: str) -> bool:
    """Returns True the first time this fingerprint is seen, so the caller
    knows whether it is worth an email."""
    with connection() as conn:
        existing = conn.execute("SELECT id FROM error_log WHERE fingerprint = ?", (fingerprint,)).fetchone()
        if existing:
            conn.execute("UPDATE error_log SET count = count + 1, last_seen_at = ?, resolved_at = NULL WHERE id = ?", (_now(), existing["id"]))
            return False
        conn.execute(
            "INSERT INTO error_log (fingerprint, source, kind, message, where_, detail, first_seen_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (fingerprint, source, kind[:120], message[:500], where[:200], detail[:4000], _now(), _now()))
        return True


def list_errors(*, unresolved_only: bool = False, limit: int = 100) -> list[sqlite3.Row]:
    sql = "SELECT * FROM error_log"
    if unresolved_only:
        sql += " WHERE resolved_at IS NULL"
    with connection() as conn:
        return conn.execute(sql + " ORDER BY resolved_at IS NOT NULL, last_seen_at DESC LIMIT ?", (limit,)).fetchall()


def resolve_error(error_id: int) -> None:
    with connection() as conn:
        conn.execute("UPDATE error_log SET resolved_at = ? WHERE id = ?", (_now(), error_id))


def count_unresolved_errors() -> int:
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM error_log WHERE resolved_at IS NULL").fetchone()[0]


# ------------------------------------------------- documents (tax forms) --


def add_partner_document(*, promoter_id: int, kind: str, filename: str, content_type: str, data: str, size_bytes: int) -> int:
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO partner_documents (promoter_id, kind, filename, content_type, size_bytes, data, uploaded_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (promoter_id, kind, filename[:160], content_type, size_bytes, data, _now()))
        return cur.lastrowid


def get_partner_document(document_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT d.*, promoters.name AS promoter_name FROM partner_documents d JOIN promoters ON promoters.id = d.promoter_id WHERE d.id = ?", (document_id,)).fetchone()


def list_partner_documents(promoter_id: Optional[int] = None, *, pending_only: bool = False) -> list[sqlite3.Row]:
    """Without the file itself -- listing pages don't need megabytes."""
    sql = ("SELECT d.id, d.promoter_id, d.kind, d.filename, d.content_type, d.size_bytes, d.uploaded_at, d.accepted_at, d.accepted_by, d.rejected_at, d.note, "
           "promoters.name AS promoter_name FROM partner_documents d JOIN promoters ON promoters.id = d.promoter_id WHERE 1 = 1")
    args: list = []
    if promoter_id:
        sql += " AND d.promoter_id = ?"; args.append(promoter_id)
    if pending_only:
        sql += " AND d.accepted_at IS NULL AND d.rejected_at IS NULL"
    sql += " ORDER BY d.uploaded_at DESC"
    with connection() as conn:
        return conn.execute(sql, args).fetchall()


def list_partner_documents_with_data() -> list[sqlite3.Row]:
    """Only for asking which are encrypted; everything else uses the
    listing that leaves the bytes behind."""
    with connection() as conn:
        return conn.execute("SELECT id, data FROM partner_documents").fetchall()


def decide_partner_document(document_id: int, *, accepted: bool, by: str = "admin", note: str = "") -> None:
    with connection() as conn:
        if accepted:
            conn.execute("UPDATE partner_documents SET accepted_at = ?, accepted_by = ?, rejected_at = NULL, note = ? WHERE id = ?", (_now(), by, note.strip(), document_id))
        else:
            conn.execute("UPDATE partner_documents SET rejected_at = ?, accepted_at = NULL, note = ? WHERE id = ?", (_now(), note.strip(), document_id))


def count_pending_partner_documents() -> int:
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM partner_documents WHERE accepted_at IS NULL AND rejected_at IS NULL").fetchone()[0]


def has_document_awaiting_review(promoter_id: int) -> bool:
    with connection() as conn:
        return conn.execute("SELECT 1 FROM partner_documents WHERE promoter_id = ? AND accepted_at IS NULL AND rejected_at IS NULL LIMIT 1", (promoter_id,)).fetchone() is not None


# --------------------------------------------------- recruitment (§8) --


def set_prospect_outreach(prospect_id: int, **fields) -> None:
    allowed = {"outreach_step", "outreach_next_at", "outreach_status", "opted_out_at", "note", "source"}
    sets = {k: v for k, v in fields.items() if k in allowed}
    if not sets:
        return
    with connection() as conn:
        conn.execute("UPDATE partner_prospects SET " + ", ".join(f"{k} = ?" for k in sets) + " WHERE id = ?", (*sets.values(), prospect_id))


def due_outreach(now_iso: str, limit: int = 50) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(
            "SELECT * FROM partner_prospects WHERE outreach_status = 'active' AND applied_at IS NULL AND opted_out_at IS NULL "
            "AND outreach_next_at IS NOT NULL AND outreach_next_at <= ? ORDER BY outreach_next_at LIMIT ?", (now_iso, limit)).fetchall()


def list_recruits(limit: int = 300) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(
            "SELECT p.*, (SELECT COUNT(*) FROM partner_outreach_log l WHERE l.prospect_id = p.id AND l.status = 'sent' AND l.direction = 'out') AS sent_count, "
            "(SELECT MAX(created_at) FROM partner_outreach_log l WHERE l.prospect_id = p.id AND l.status = 'sent' AND l.direction = 'out') AS last_sent_at, "
            "(SELECT COUNT(*) FROM partner_outreach_log l WHERE l.prospect_id = p.id AND l.direction = 'in') AS reply_count "
            "FROM partner_prospects p WHERE p.outreach_status != '' ORDER BY COALESCE(p.applied_at, p.last_seen_at, p.created_at) DESC LIMIT ?", (limit,)).fetchall()


# ------------------------------------------------- outreach mailboxes --


def list_outreach_mailboxes(*, active_only: bool = False) -> list[sqlite3.Row]:
    sql = "SELECT * FROM outreach_mailboxes"
    if active_only:
        sql += " WHERE active = 1"
    with connection() as conn:
        return conn.execute(sql + " ORDER BY active DESC, label").fetchall()


def get_outreach_mailbox(mailbox_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM outreach_mailboxes WHERE id = ?", (mailbox_id,)).fetchone()


def add_outreach_mailbox(*, label: str, host: str, port: int, username: str, password: str,
                         from_email: str, reply_to: str = "", daily_cap: int = 20) -> int:
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO outreach_mailboxes (label, host, port, username, password, from_email, reply_to, daily_cap, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (label[:80], host, port, username, password, from_email, reply_to, daily_cap, _now()))
        return cur.lastrowid


def update_outreach_mailbox(mailbox_id: int, **fields) -> None:
    allowed = {"label", "host", "port", "username", "password", "from_email", "reply_to", "daily_cap", "active", "last_ok_at", "last_error"}
    sets = {k: v for k, v in fields.items() if k in allowed}
    if not sets:
        return
    with connection() as conn:
        conn.execute(f"UPDATE outreach_mailboxes SET {', '.join(f'{k} = ?' for k in sets)} WHERE id = ?",
                     (*sets.values(), mailbox_id))


def delete_outreach_mailbox(mailbox_id: int) -> None:
    """Prospects pointed at it fall back to the rotation rather than losing
    their place in the sequence."""
    with connection() as conn:
        conn.execute("UPDATE partner_prospects SET mailbox_id = NULL WHERE mailbox_id = ?", (mailbox_id,))
        conn.execute("DELETE FROM outreach_mailboxes WHERE id = ?", (mailbox_id,))


def set_prospect_mailbox(prospect_id: int, mailbox_id: Optional[int]) -> None:
    with connection() as conn:
        conn.execute("UPDATE partner_prospects SET mailbox_id = ? WHERE id = ?", (mailbox_id, prospect_id))


def outreach_sent_today(mailbox_id: int, *, day: str) -> int:
    """How many this mailbox has sent today, for the cap that keeps Google
    and Microsoft from reading it as bulk."""
    with connection() as conn:
        return conn.execute(
            "SELECT COUNT(*) FROM partner_outreach_log WHERE mailbox_id = ? AND status = 'sent' AND created_at >= ?",
            (mailbox_id, day)).fetchone()[0]


def mailbox_usage(day: str) -> dict:
    with connection() as conn:
        rows = conn.execute(
            "SELECT mailbox_id, COUNT(*) AS n FROM partner_outreach_log "
            "WHERE status = 'sent' AND created_at >= ? AND mailbox_id IS NOT NULL GROUP BY mailbox_id", (day,)).fetchall()
    return {r["mailbox_id"]: r["n"] for r in rows}


def record_email_event(message_id: str, *, kind: str, when: str) -> bool:
    """One open or click reported by Postmark. True when it matched a
    recruitment email we sent.

    Counted rather than merely flagged: a second open days later is the
    interesting one, and the first is often a mail client fetching images
    before a human has seen anything.
    """
    if not message_id:
        return False
    column, at = ("open_count", "opened_at") if kind == "open" else ("click_count", "clicked_at")
    with connection() as conn:
        cur = conn.execute(
            f"UPDATE partner_outreach_log SET {column} = {column} + 1, {at} = COALESCE({at}, ?) WHERE message_id = ?",
            (when, message_id))
        return cur.rowcount > 0


def outreach_engagement(prospect_id: int) -> dict:
    """Opens and clicks for one prospect, across every email we sent them."""
    with connection() as conn:
        row = conn.execute(
            "SELECT COALESCE(SUM(open_count), 0) AS opens, COALESCE(SUM(click_count), 0) AS clicks, "
            "MAX(opened_at) AS last_open, MAX(clicked_at) AS last_click "
            "FROM partner_outreach_log WHERE prospect_id = ? AND status = 'sent'", (prospect_id,)).fetchone()
    return {"opens": row["opens"], "clicks": row["clicks"], "last_open": row["last_open"], "last_click": row["last_click"]}


def log_outreach(*, prospect_id: int, step: int, subject: str, status: str = "sent", error: str = "", message_id: str = "",
                 mailbox_id: Optional[int] = None) -> int:
    with connection() as conn:
        cur = conn.execute("INSERT INTO partner_outreach_log (prospect_id, step, subject, status, error, message_id, mailbox_id, created_at) "
                           "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                           (prospect_id, step, subject[:200], status, error[:300], message_id or None, mailbox_id, _now()))
        return cur.lastrowid


def list_outreach_log(prospect_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM partner_outreach_log WHERE prospect_id = ? ORDER BY created_at, id", (prospect_id,)).fetchall()


def add_outreach_reply(*, prospect_id: int, subject: str, body: str) -> int:
    """What they wrote back, on the same timeline as what we sent."""
    with connection() as conn:
        cur = conn.execute("INSERT INTO partner_outreach_log (prospect_id, step, subject, status, direction, body, created_at) VALUES (?, 0, ?, 'received', 'in', ?, ?)",
                           (prospect_id, subject[:200], body.strip(), _now()))
        return cur.lastrowid


def count_outreach_replies(prospect_id: int) -> int:
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM partner_outreach_log WHERE prospect_id = ? AND direction = 'in'", (prospect_id,)).fetchone()[0]


def prospects_with_unanswered_replies(limit: int = 20) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(
            "SELECT p.*, l.created_at AS replied_at, l.body AS reply FROM partner_prospects p "
            "JOIN partner_outreach_log l ON l.prospect_id = p.id AND l.direction = 'in' "
            "WHERE p.outreach_status = 'replied' GROUP BY p.id ORDER BY l.created_at DESC LIMIT ?", (limit,)).fetchall()


def recruitment_counts() -> dict:
    with connection() as conn:
        r = conn.execute(
            "SELECT COUNT(*) AS total, SUM(CASE WHEN outreach_status = 'active' THEN 1 ELSE 0 END) AS active, "
            "SUM(CASE WHEN last_seen_at IS NOT NULL THEN 1 ELSE 0 END) AS opened, "
            "SUM(CASE WHEN applied_at IS NOT NULL THEN 1 ELSE 0 END) AS applied, "
            "SUM(CASE WHEN opted_out_at IS NOT NULL THEN 1 ELSE 0 END) AS opted_out FROM partner_prospects WHERE outreach_status != ''").fetchone()
    return {k: (r[k] or 0) for k in ("total", "active", "opened", "applied", "opted_out")}


def mark_resource_announced(resource_id: int) -> None:
    with connection() as conn:
        conn.execute("UPDATE partner_resources SET announced_at = ?, announce_queued_at = NULL WHERE id = ?", (_now(), resource_id))


def queue_resource_announcement(resource_id: int) -> None:
    with connection() as conn:
        conn.execute("UPDATE partner_resources SET announce_queued_at = ? WHERE id = ?", (_now(), resource_id))


def resources_awaiting_announcement() -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM partner_resources WHERE announce_queued_at IS NOT NULL ORDER BY announce_queued_at").fetchall()


def partners_to_notify() -> list[sqlite3.Row]:
    """Active partners with an address -- who hears about a new kit item."""
    with connection() as conn:
        return conn.execute("SELECT * FROM promoters WHERE active = 1 AND status IN ('active', 'approved') AND email != '' ORDER BY name COLLATE NOCASE").fetchall()


def create_partner_link(*, promoter_id: int, token_hash: str, ttl_minutes: int) -> int:
    expires = (datetime.utcnow() + timedelta(minutes=ttl_minutes)).isoformat(timespec="seconds") + "Z"
    with connection() as conn:
        cur = conn.execute("INSERT INTO partner_links (promoter_id, token_hash, expires_at, created_at) VALUES (?, ?, ?, ?)", (promoter_id, token_hash, expires, _now()))
        return cur.lastrowid


def consume_partner_link(token_hash: str) -> Optional[int]:
    """Promoter id for a live, unused portal link, or None. Consumes it."""
    with connection() as conn:
        row = conn.execute("SELECT * FROM partner_links WHERE token_hash = ?", (token_hash,)).fetchone()
        if row is None or row["consumed_at"] is not None or row["expires_at"] <= _now():
            return None
        conn.execute("UPDATE partner_links SET consumed_at = ? WHERE id = ?", (_now(), row["id"]))
        return row["promoter_id"]


def list_referrals_for_partner(promoter_id: int) -> list[sqlite3.Row]:
    """One row per referred customer for the portal (spec §7): dates,
    status and money only -- never who they are."""
    with connection() as conn:
        return conn.execute(
            "SELECT r.id, r.customer_id, r.redeemed_at, r.first_payment_at, r.term_ends_at, r.attribution_source, r.bounty_payout_id, promotions.code, promotions.commission_months, "
            "(SELECT s.status FROM subscriptions s WHERE s.customer_id = r.customer_id ORDER BY CASE s.status WHEN 'active' THEN 0 WHEN 'trialing' THEN 1 WHEN 'past_due' THEN 2 WHEN 'comp' THEN 3 ELSE 4 END LIMIT 1) AS subscription_status, "
            "(SELECT COALESCE(SUM(share_cents), 0) FROM promo_payouts pp WHERE pp.customer_id = r.customer_id AND pp.promoter_id = promotions.promoter_id) AS earned_cents "
            "FROM promo_redemptions r JOIN promotions ON promotions.id = r.promotion_id WHERE promotions.promoter_id = ? ORDER BY r.redeemed_at DESC",
            (promoter_id,)).fetchall()


def partner_code_stats(promoter_id: int) -> list[sqlite3.Row]:
    """Each of a partner's codes with its clicks and conversions."""
    with connection() as conn:
        return conn.execute(
            "SELECT promotions.*, (SELECT COUNT(*) FROM referral_clicks c WHERE c.promotion_id = promotions.id) AS clicks, "
            "(SELECT COUNT(*) FROM promo_redemptions r WHERE r.promotion_id = promotions.id) AS signups, "
            "(SELECT COUNT(*) FROM promo_redemptions r WHERE r.promotion_id = promotions.id AND r.first_payment_at IS NOT NULL) AS paid "
            "FROM promotions WHERE promoter_id = ? ORDER BY active DESC, created_at", (promoter_id,)).fetchall()


def partner_statement_periods(promoter_id: int) -> list[sqlite3.Row]:
    """Calendar months with ledger activity, newest first, with the month's
    net earned -- the portal's statements list."""
    with connection() as conn:
        return conn.execute(
            "SELECT substr(created_at, 1, 7) AS period, COUNT(*) AS rows, COALESCE(SUM(share_cents), 0) AS earned_cents, "
            "COALESCE(SUM(CASE WHEN kind = 'recurring' THEN gross_cents ELSE 0 END), 0) AS gross_cents "
            "FROM promo_payouts WHERE promoter_id = ? GROUP BY period ORDER BY period DESC", (promoter_id,)).fetchall()


def partner_statement_rows(promoter_id: int, period: str) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute(
            "SELECT p.*, promotions.code FROM promo_payouts p JOIN promotions ON promotions.id = p.promotion_id "
            "WHERE p.promoter_id = ? AND substr(p.created_at, 1, 7) = ? ORDER BY p.created_at, p.id", (promoter_id, period)).fetchall()


# ---------------------------------------------------- payout runs (§8, §10.2) --


PAYOUT_MINIMUM_CENTS = 50_00


def payout_run_preview(*, now: Optional[str] = None) -> list[dict]:
    """Every partner with anything owed, what's payable now, and whether
    this run may pay them: under the $50 minimum or no tax form on file
    is an automatic exclusion (spec §6.6, §10.2)."""
    rows = []
    with connection() as conn:
        ids = [r["id"] for r in conn.execute("SELECT id FROM promoters WHERE active = 1 AND status IN ('active','approved','suspended') ORDER BY name COLLATE NOCASE").fetchall()]
    for pid in ids:
        p = get_promoter(pid)
        totals = promoter_totals(pid, now=now)
        if totals["owed_cents"] <= 0:
            continue
        reasons = []
        if totals["payable_cents"] < PAYOUT_MINIMUM_CENTS:
            reasons.append("under the $50 minimum" if totals["payable_cents"] > 0 else "nothing payable yet")
        if not p["tax_form_received_at"]:
            reasons.append("tax form awaiting review" if has_document_awaiting_review(pid) else "no tax form on file")
        if not p["payout_email"] and p["payout_method"] == "paypal":
            reasons.append("no PayPal email")
        if p["status"] == "suspended":
            reasons.append("suspended")
        rows.append({"promoter": p, "totals": totals, "eligible": not reasons, "reasons": reasons})
    return rows


def payments_by_promoter_for_year(year: int) -> list[sqlite3.Row]:
    """What each partner was actually paid in a calendar year, with their
    tax details -- the 1099-NEC threshold report (§10.2)."""
    with connection() as conn:
        return conn.execute(
            "SELECT p.id, p.name, p.email, p.payout_email, p.tax_form_type, p.tax_form_received_at, p.tier, "
            "COALESCE(SUM(pp.amount_cents), 0) AS paid_cents, COUNT(pp.id) AS payments "
            "FROM promoters p JOIN promoter_payments pp ON pp.promoter_id = p.id WHERE substr(pp.paid_at, 1, 4) = ? "
            "GROUP BY p.id ORDER BY paid_cents DESC", (str(year),)).fetchall()


def list_ledger(*, promoter_id: Optional[int] = None, kind: str = "", month: str = "", limit: int = 2000) -> list[sqlite3.Row]:
    """The full promo_payouts ledger with the partner, the code and the
    source invoice, filterable (§8 ledger view)."""
    sql = ("SELECT pp.*, promoters.name AS promoter_name, promotions.code, payments.stripe_invoice_id, payments.paid_at AS invoice_paid_at, "
           "customers.email AS customer_email FROM promo_payouts pp JOIN promoters ON promoters.id = pp.promoter_id JOIN promotions ON promotions.id = pp.promotion_id "
           "LEFT JOIN payments ON payments.id = pp.payment_id LEFT JOIN customers ON customers.id = pp.customer_id WHERE 1 = 1")
    args: list = []
    if promoter_id:
        sql += " AND pp.promoter_id = ?"; args.append(promoter_id)
    if kind:
        sql += " AND pp.kind = ?"; args.append(kind)
    if month:
        sql += " AND substr(pp.created_at, 1, 7) = ?"; args.append(month)
    sql += " ORDER BY pp.created_at DESC, pp.id DESC LIMIT ?"; args.append(limit)
    with connection() as conn:
        return conn.execute(sql, args).fetchall()


# ------------------------------------------------ compliance log (§10.1) --


def add_partner_content(*, promoter_id: int, url: str, platform: str, posted_at: Optional[str], disclosure_present: Optional[bool], note: str) -> int:
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO partner_content (promoter_id, url, platform, posted_at, disclosure_present, checked_at, note, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (promoter_id, url.strip(), platform.strip(), posted_at or None, None if disclosure_present is None else (1 if disclosure_present else 0),
             _now() if disclosure_present is not None else None, note.strip(), _now()))
        return cur.lastrowid


def update_partner_content(content_id: int, *, disclosure_present: Optional[bool], note: str) -> None:
    with connection() as conn:
        conn.execute("UPDATE partner_content SET disclosure_present = ?, checked_at = ?, note = ? WHERE id = ?",
                     (None if disclosure_present is None else (1 if disclosure_present else 0), _now() if disclosure_present is not None else None, note.strip(), content_id))


def delete_partner_content(content_id: int) -> None:
    with connection() as conn:
        conn.execute("DELETE FROM partner_content WHERE id = ?", (content_id,))


def get_partner_content(content_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM partner_content WHERE id = ?", (content_id,)).fetchone()


def list_partner_content(promoter_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM partner_content WHERE promoter_id = ? ORDER BY COALESCE(posted_at, created_at) DESC, id DESC", (promoter_id,)).fetchall()


def count_unchecked_content() -> int:
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM partner_content WHERE disclosure_present IS NULL").fetchone()[0]


# --------------------------------------------------------------- alerts (§8) --


def partner_alert_events(limit: int = 30) -> list[sqlite3.Row]:
    """Self-referral attempts and attributions to inactive promoters,
    as the attribution path logged them."""
    with connection() as conn:
        return conn.execute(
            "SELECT e.*, customers.email AS customer_email FROM subscription_events e LEFT JOIN customers ON customers.id = e.customer_id "
            "WHERE e.kind IN ('promo_self_referral', 'promo_inactive_promoter') ORDER BY e.created_at DESC LIMIT ?", (limit,)).fetchall()


def conversion_spikes(*, days: int = 7, factor: float = 3.0, floor: int = 10) -> list[dict]:
    """Partners whose signups in the last `days` days are at least
    `floor` and more than `factor` times their weekly average over the
    prior 8 weeks -- worth a look before the bounties pay out."""
    now = datetime.utcnow()
    recent_from = (now - timedelta(days=days)).isoformat(timespec="seconds") + "Z"
    base_from = (now - timedelta(days=days + 56)).isoformat(timespec="seconds") + "Z"
    with connection() as conn:
        rows = conn.execute(
            "SELECT promoters.id, promoters.name, "
            "SUM(CASE WHEN r.redeemed_at >= ? THEN 1 ELSE 0 END) AS recent, "
            "SUM(CASE WHEN r.redeemed_at >= ? AND r.redeemed_at < ? THEN 1 ELSE 0 END) AS prior "
            "FROM promo_redemptions r JOIN promotions ON promotions.id = r.promotion_id JOIN promoters ON promoters.id = promotions.promoter_id "
            "WHERE r.redeemed_at >= ? GROUP BY promoters.id", (recent_from, base_from, recent_from, base_from)).fetchall()
    out = []
    for r in rows:
        weekly_avg = (r["prior"] or 0) / 8.0
        if r["recent"] >= floor and r["recent"] > factor * max(weekly_avg, 1.0):
            out.append({"id": r["id"], "name": r["name"], "recent": r["recent"], "weekly_avg": round(weekly_avg, 1), "days": days})
    return out


def count_partners_by_status() -> dict:
    with connection() as conn:
        rows = conn.execute("SELECT status, COUNT(*) AS n FROM promoters WHERE tier != '' OR status != 'active' OR applied_at IS NOT NULL GROUP BY status").fetchall()
    return {r["status"]: r["n"] for r in rows}


def count_founding_partners() -> int:
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM promoters WHERE tier = 'founding'").fetchone()[0]


def create_promotion(*, code: str, kind: str, promoter_id: Optional[int], percent_off: float, duration_months: Optional[int], share_pct: float,
                     max_redemptions: Optional[int], expires_at: Optional[str], allowed_emails: str, stripe_coupon_id: Optional[str],
                     stripe_promotion_code_id: Optional[str], notes: str, trial_days: Optional[int] = None, proofs_extra: int = 0,
                     commission_months: Optional[int] = None) -> int:
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO promotions (code, kind, promoter_id, percent_off, duration_months, share_pct, max_redemptions, expires_at, allowed_emails, "
            "stripe_coupon_id, stripe_promotion_code_id, notes, trial_days, proofs_extra, commission_months, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (code, kind, promoter_id, percent_off, duration_months, share_pct, max_redemptions, expires_at, allowed_emails, stripe_coupon_id, stripe_promotion_code_id, notes.strip(),
             trial_days, int(proofs_extra or 0), commission_months, _now(), _now()),
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
    "promotions.trial_days, promotions.proofs_extra, promotions.commission_months, promoters.status AS promoter_status, "
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


def attribute_customer(*, promotion_id: int, customer_id: int, subscription_id: Optional[int], source: str) -> Optional[int]:
    """A provisional redemption (Partner Program §5.3): one promotion per
    customer; while unlocked the latest touch replaces the earlier one;
    once first payment locks it nothing moves. Returns the redemption's
    id, or None when a locked attribution already stands."""
    with connection() as conn:
        rows = conn.execute("SELECT * FROM promo_redemptions WHERE customer_id = ? ORDER BY attribution_locked DESC, redeemed_at DESC", (customer_id,)).fetchall()
        locked = [r for r in rows if r["attribution_locked"]]
        if locked:
            if locked[0]["promotion_id"] == promotion_id:
                conn.execute("UPDATE promo_redemptions SET subscription_id = COALESCE(?, subscription_id) WHERE id = ?", (subscription_id, locked[0]["id"]))
                return locked[0]["id"]
            return None
        if rows:
            conn.execute("UPDATE promo_redemptions SET promotion_id = ?, subscription_id = COALESCE(?, subscription_id), attribution_source = ?, redeemed_at = ? WHERE id = ?",
                         (promotion_id, subscription_id, source, _now(), rows[0]["id"]))
            for extra in rows[1:]:
                conn.execute("DELETE FROM promo_redemptions WHERE id = ? AND attribution_locked = 0 AND first_payment_at IS NULL", (extra["id"],))
            return rows[0]["id"]
        cur = conn.execute(
            "INSERT INTO promo_redemptions (promotion_id, customer_id, subscription_id, stripe_subscription_id, redeemed_at, attribution_source) VALUES (?, ?, ?, NULL, ?, ?)",
            (promotion_id, customer_id, subscription_id, _now(), source),
        )
        return cur.lastrowid


def lock_attribution(redemption_id: int, *, first_payment_at: str, term_ends_at: Optional[str]) -> bool:
    """Writes the commission clock once (R3); False when it was already set."""
    with connection() as conn:
        cur = conn.execute("UPDATE promo_redemptions SET first_payment_at = ?, term_ends_at = ?, attribution_locked = 1 WHERE id = ? AND first_payment_at IS NULL",
                           (first_payment_at, term_ends_at, redemption_id))
        return cur.rowcount > 0


def set_proofs_free_extra(customer_id: int, count: int) -> None:
    with connection() as conn:
        conn.execute("UPDATE customers SET proofs_free_extra = ?, updated_at = ? WHERE id = ?", (int(count), _now(), customer_id))


def record_referral_click(*, promotion_id: int, ip_hash: str, user_agent: str, landing_path: str) -> int:
    with connection() as conn:
        cur = conn.execute("INSERT INTO referral_clicks (promotion_id, clicked_at, ip_hash, user_agent, landing_path) VALUES (?, ?, ?, ?, ?)",
                           (promotion_id, _now(), ip_hash, user_agent, landing_path))
        return cur.lastrowid


def list_referral_clicks(promotion_id: int, limit: int = 500) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM referral_clicks WHERE promotion_id = ? ORDER BY clicked_at DESC LIMIT ?", (promotion_id, limit)).fetchall()


def count_referral_clicks(promotion_id: int) -> int:
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM referral_clicks WHERE promotion_id = ?", (promotion_id,)).fetchone()[0]


def redemption_for_customer(customer_id: int) -> Optional[sqlite3.Row]:
    """The redemption that attributes this *customer* -- every subscription
    they hold (the app and Proofs are separate rows) earns on it. A
    promoter's code wins over a direct discount; otherwise the latest."""
    with connection() as conn:
        return conn.execute(_REDEMPTIONS_WITH_CONTEXT + " WHERE r.customer_id = ? ORDER BY (promotions.kind = 'promoter') DESC, r.redeemed_at DESC LIMIT 1", (customer_id,)).fetchone()


def record_promo_payout(*, promoter_id: int, promotion_id: int, customer_id: Optional[int], payment_id: Optional[int], gross_cents: int, fee_cents: int,
                        net_cents: int, share_pct: float, share_cents: int, fee_source: str, kind: str = "recurring",
                        reverses_payout_id: Optional[int] = None, note: str = "") -> Optional[int]:
    """One ledger row. Append-only (R11): a reversal is a new row with a
    negative share_cents pointing at the original. One *recurring* row per
    payment; one reversal per (original, note) so a replayed refund event
    can't reverse twice."""
    with connection() as conn:
        if kind == "recurring" and payment_id is not None and conn.execute("SELECT 1 FROM promo_payouts WHERE payment_id = ? AND kind = 'recurring'", (payment_id,)).fetchone():
            return None
        if kind == "reversal" and reverses_payout_id is not None and conn.execute(
                "SELECT 1 FROM promo_payouts WHERE reverses_payout_id = ? AND note = ?", (reverses_payout_id, note)).fetchone():
            return None
        cur = conn.execute(
            "INSERT INTO promo_payouts (promoter_id, promotion_id, customer_id, payment_id, gross_cents, fee_cents, net_cents, share_pct, share_cents, fee_source, kind, reverses_payout_id, note, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (promoter_id, promotion_id, customer_id, payment_id, gross_cents, fee_cents, net_cents, share_pct, share_cents, fee_source, kind, reverses_payout_id, note.strip(), _now()),
        )
        return cur.lastrowid


def get_promo_payout(payout_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM promo_payouts WHERE id = ?", (payout_id,)).fetchone()


def promo_payouts_for_payment(payment_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM promo_payouts WHERE payment_id = ? ORDER BY id", (payment_id,)).fetchall()


def reversed_cents_for(payout_id: int) -> int:
    """How much of a row has already been reversed (a positive number)."""
    with connection() as conn:
        return -(conn.execute("SELECT COALESCE(SUM(share_cents), 0) FROM promo_payouts WHERE reverses_payout_id = ?", (payout_id,)).fetchone()[0])


def set_bounty_payout(redemption_id: int, payout_id: int) -> None:
    with connection() as conn:
        conn.execute("UPDATE promo_redemptions SET bounty_payout_id = ? WHERE id = ? AND bounty_payout_id IS NULL", (payout_id, redemption_id))


def count_active_referrals(promoter_id: int) -> int:
    """R7's 'active': referred customers who have paid at least once and
    hold an active or trialing subscription right now."""
    with connection() as conn:
        return conn.execute(
            "SELECT COUNT(DISTINCT r.customer_id) FROM promo_redemptions r JOIN promotions ON promotions.id = r.promotion_id "
            "WHERE promotions.promoter_id = ? AND r.first_payment_at IS NOT NULL AND EXISTS ("
            "  SELECT 1 FROM subscriptions s WHERE s.customer_id = r.customer_id AND s.status IN ('active','trialing','past_due'))",
            (promoter_id,)).fetchone()[0]


def set_bounty_reinstated(promoter_id: int, at: str) -> bool:
    with connection() as conn:
        cur = conn.execute("UPDATE promoters SET bounty_reinstated_at = ?, updated_at = ? WHERE id = ? AND bounty_reinstated_at IS NULL", (at, _now(), promoter_id))
        return cur.rowcount > 0


def get_payment_by_invoice(stripe_invoice_id: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM payments WHERE stripe_invoice_id = ?", (stripe_invoice_id,)).fetchone()


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
        payment_id = cur.lastrowid
        promoter = conn.execute("SELECT name FROM promoters WHERE id = ?", (promoter_id,)).fetchone()
        # Money out: it belongs on the profit-and-loss too.
        conn.execute(
            "INSERT INTO expenses (date, category, vendor, description, amount_cents, source, external_id, created_at) VALUES (?, 'Promoter payouts', ?, ?, ?, 'manual', ?, ?)",
            (paid_at[:10], promoter["name"] if promoter else "Promoter", (note.strip() or "Revenue share payout"), amount_cents, f"promoter_payment:{payment_id}", _now()),
        )
        return payment_id


def list_promoter_payments(promoter_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM promoter_payments WHERE promoter_id = ? ORDER BY paid_at DESC, id DESC", (promoter_id,)).fetchall()


CLAWBACK_DAYS = 60


def promoter_totals(promoter_id: int, *, now: Optional[str] = None) -> dict:
    """The promoter's ledger in one row. Every SUM here is signed --
    reversal rows carry a negative share_cents -- so earned is the net of
    the whole ledger, and owed is earned minus paid. A row becomes
    *payable* 60 days after it was booked (the clawback window, §6.6);
    reversals count at once. Computed on read, no scheduler."""
    cutoff = ((datetime.fromisoformat((now or _now()).rstrip("Z")) - timedelta(days=CLAWBACK_DAYS)).isoformat(timespec="seconds") + "Z")
    with connection() as conn:
        p = conn.execute(
            "SELECT SUM(CASE WHEN kind = 'recurring' THEN 1 ELSE 0 END) AS payouts, "
            "COALESCE(SUM(CASE WHEN kind = 'recurring' THEN gross_cents ELSE 0 END), 0) AS gross, COALESCE(SUM(CASE WHEN kind = 'recurring' THEN net_cents ELSE 0 END), 0) AS net, "
            "COALESCE(SUM(share_cents), 0) AS earned, "
            "COALESCE(SUM(CASE WHEN kind = 'reversal' THEN share_cents ELSE 0 END), 0) AS reversed, "
            "COALESCE(SUM(CASE WHEN kind = 'bounty' THEN share_cents ELSE 0 END), 0) AS bounties, "
            "COALESCE(SUM(CASE WHEN kind = 'reversal' OR created_at <= ? THEN share_cents ELSE 0 END), 0) AS matured "
            "FROM promo_payouts WHERE promoter_id = ?", (cutoff, promoter_id)).fetchone()
        paid = conn.execute("SELECT COALESCE(SUM(amount_cents), 0) FROM promoter_payments WHERE promoter_id = ?", (promoter_id,)).fetchone()[0]
        referred = conn.execute("SELECT COUNT(DISTINCT r.customer_id) FROM promo_redemptions r JOIN promotions ON promotions.id = r.promotion_id WHERE promotions.promoter_id = ?", (promoter_id,)).fetchone()[0]
        codes = conn.execute("SELECT COUNT(*) FROM promotions WHERE promoter_id = ?", (promoter_id,)).fetchone()[0]
    active = count_active_referrals(promoter_id)
    earned = p["earned"]; owed = earned - paid
    payable = max(0, min(owed, p["matured"] - paid))
    return {"referred": referred, "active": active, "codes": codes, "payouts": p["payouts"] or 0, "gross_cents": p["gross"], "net_cents": p["net"],
            "earned_cents": earned, "reversed_cents": -p["reversed"], "bounty_cents": p["bounties"], "paid_cents": paid, "owed_cents": owed,
            "payable_cents": payable, "held_cents": max(0, owed - payable)}


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


# --------------------------------------------------------------- finance --


EXPENSE_CATEGORIES = ["Hosting", "Email", "Domain", "Software", "Marketing", "Professional services", "Promoter payouts", "Stripe fees", "Refunds", "Taxes", "Other"]


def set_payment_fee(payment_id: int, *, fee_cents: int, balance_transaction_id: Optional[str]) -> None:
    with connection() as conn:
        conn.execute("UPDATE payments SET fee_cents = ?, balance_transaction_id = COALESCE(?, balance_transaction_id) WHERE id = ?", (fee_cents, balance_transaction_id, payment_id))


def add_expense(*, date: str, category: str, vendor: str, description: str, amount_cents: int, source: str = "manual", external_id: Optional[str] = None, recurring_id: Optional[int] = None) -> Optional[int]:
    """Returns None when an expense with this external_id already exists
    (imports and recurring materialization are idempotent)."""
    with connection() as conn:
        if external_id and conn.execute("SELECT 1 FROM expenses WHERE external_id = ?", (external_id,)).fetchone():
            return None
        cur = conn.execute(
            "INSERT INTO expenses (date, category, vendor, description, amount_cents, source, external_id, recurring_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (date, category, vendor.strip(), description.strip(), amount_cents, source, external_id, recurring_id, _now()),
        )
        return cur.lastrowid


def delete_expense(expense_id: int) -> bool:
    """Imported Stripe rows can't be deleted -- they'd just come back."""
    with connection() as conn:
        return conn.execute("DELETE FROM expenses WHERE id = ? AND source != 'stripe'", (expense_id,)).rowcount > 0


def list_expenses(start: str, end: str) -> list[sqlite3.Row]:
    """Expenses dated in [start, end] (YYYY-MM-DD inclusive)."""
    with connection() as conn:
        return conn.execute("SELECT * FROM expenses WHERE date >= ? AND date <= ? ORDER BY date DESC, id DESC", (start, end)).fetchall()


def add_recurring_expense(*, vendor: str, category: str, description: str, amount_cents: int, day_of_month: int, start_month: str, end_month: Optional[str]) -> int:
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO recurring_expenses (vendor, category, description, amount_cents, day_of_month, start_month, end_month, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (vendor.strip(), category, description.strip(), amount_cents, day_of_month, start_month, end_month, _now()),
        )
        return cur.lastrowid


def list_recurring_expenses() -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM recurring_expenses ORDER BY active DESC, vendor COLLATE NOCASE").fetchall()


def get_recurring_expense(recurring_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM recurring_expenses WHERE id = ?", (recurring_id,)).fetchone()


def update_recurring_expense(recurring_id: int, *, amount_cents: int, active: bool, end_month: Optional[str]) -> None:
    with connection() as conn:
        conn.execute("UPDATE recurring_expenses SET amount_cents = ?, active = ?, end_month = ? WHERE id = ?", (amount_cents, 1 if active else 0, end_month, recurring_id))


def period_financials(start: str, end: str) -> dict:
    """One profit-and-loss row for the dates [start, end] inclusive.
    Revenue is paid invoices by the day they were paid; expenses by their
    date; Stripe fees and refunds are expense categories the Stripe import
    fills; the promoter share is shown both as accrued (earned in the
    period) and, within expenses, as actually paid out."""
    with connection() as conn:
        rev = conn.execute("SELECT COUNT(*) AS n, COALESCE(SUM(amount_cents), 0) AS cents FROM payments WHERE status = 'paid' AND paid_at IS NOT NULL AND substr(paid_at, 1, 10) >= ? AND substr(paid_at, 1, 10) <= ?", (start, end)).fetchone()
        by_cat = conn.execute("SELECT category, COALESCE(SUM(amount_cents), 0) AS cents FROM expenses WHERE date >= ? AND date <= ? GROUP BY category", (start, end)).fetchall()
        share = conn.execute("SELECT COALESCE(SUM(share_cents), 0) FROM promo_payouts WHERE substr(created_at, 1, 10) >= ? AND substr(created_at, 1, 10) <= ?", (start, end)).fetchone()[0]
        by_product = conn.execute(
            "SELECT COALESCE(s.product, 'core') AS product, COALESCE(SUM(p.amount_cents), 0) AS cents FROM payments p LEFT JOIN subscriptions s ON s.id = p.subscription_id "
            "WHERE p.status = 'paid' AND p.paid_at IS NOT NULL AND substr(p.paid_at, 1, 10) >= ? AND substr(p.paid_at, 1, 10) <= ? GROUP BY COALESCE(s.product, 'core')", (start, end)).fetchall()
        started = conn.execute("SELECT COUNT(*) FROM subscriptions WHERE source = 'stripe' AND substr(created_at, 1, 10) >= ? AND substr(created_at, 1, 10) <= ?", (start, end)).fetchone()[0]
        ended = conn.execute("SELECT COUNT(*) FROM subscriptions WHERE source = 'stripe' AND ended_at IS NOT NULL AND substr(ended_at, 1, 10) >= ? AND substr(ended_at, 1, 10) <= ?", (start, end)).fetchone()[0]
    categories = {r["category"]: r["cents"] for r in by_cat}
    stripe_fees = categories.get("Stripe fees", 0)
    refunds = categories.get("Refunds", 0)
    other = {k: v for k, v in categories.items() if k not in ("Stripe fees", "Refunds")}
    total_expenses = sum(categories.values())
    return {
        "start": start, "end": end,
        "payments": rev["n"], "revenue_cents": rev["cents"],
        "revenue_core_cents": next((r["cents"] for r in by_product if r["product"] == "core"), 0),
        "revenue_proofs_cents": next((r["cents"] for r in by_product if r["product"] == "proofs"), 0),
        "stripe_fees_cents": stripe_fees, "refunds_cents": refunds,
        "net_revenue_cents": rev["cents"] - stripe_fees - refunds,
        "expenses_by_category": other, "other_expenses_cents": sum(other.values()),
        "total_expenses_cents": total_expenses,
        "net_cents": rev["cents"] - total_expenses,
        "promoter_share_accrued_cents": share,
        "started": started, "ended": ended,
    }


# -------------------------------------------------------------- feedback --


def add_feedback(*, customer_id: Optional[int], customer_email: str, design_name: str, stitch_count: int, note: str,
                  original_image_data: Optional[str], original_image_type: str,
                  digitized_image_data: str, digitized_image_type: str) -> int:
    with connection() as conn:
        cur = conn.execute(
            "INSERT INTO feedback_submissions (customer_id, customer_email, design_name, stitch_count, note, original_image_data, original_image_type, digitized_image_data, digitized_image_type, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (customer_id, customer_email, design_name, stitch_count, note.strip(), original_image_data, original_image_type, digitized_image_data, digitized_image_type, _now()),
        )
        return cur.lastrowid


def list_feedback(*, limit: int = 200, only_unreviewed: bool = False) -> list[sqlite3.Row]:
    with connection() as conn:
        if only_unreviewed:
            return conn.execute("SELECT id, customer_id, customer_email, design_name, stitch_count, note, created_at, reviewed_at, reviewed_by FROM feedback_submissions WHERE reviewed_at IS NULL ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
        return conn.execute("SELECT id, customer_id, customer_email, design_name, stitch_count, note, created_at, reviewed_at, reviewed_by FROM feedback_submissions ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()


def count_feedback_unreviewed() -> int:
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM feedback_submissions WHERE reviewed_at IS NULL").fetchone()[0]


def get_feedback(feedback_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM feedback_submissions WHERE id = ?", (feedback_id,)).fetchone()


def mark_feedback_reviewed(feedback_id: int, *, reviewed_by: str) -> bool:
    with connection() as conn:
        return conn.execute("UPDATE feedback_submissions SET reviewed_at = ?, reviewed_by = ? WHERE id = ?", (_now(), reviewed_by, feedback_id)).rowcount > 0


def record_sent_file(*, customer_id: int, to_email: str, filename: str, size_bytes: int) -> None:
    with connection() as conn:
        conn.execute("INSERT INTO sent_files (customer_id, to_email, filename, size_bytes, created_at) VALUES (?, ?, ?, ?, ?)", (customer_id, to_email.strip().lower(), filename, size_bytes, _now()))


def count_sent_files(customer_id: int, *, hours: int = 24) -> int:
    since = (datetime.utcnow() - timedelta(hours=hours)).isoformat(timespec="seconds") + "Z"
    with connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM sent_files WHERE customer_id = ? AND created_at >= ?", (customer_id, since)).fetchone()[0]


# --------------------------------------------------------------- emails --


def get_email_template(key: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM email_templates WHERE key = ?", (key,)).fetchone()


def list_email_templates() -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM email_templates ORDER BY name").fetchall()


def seed_email_template(*, key: str, name: str, description: str, subject: str, body: str, cta_label: str, cta_url: str, preheader: str, placeholders: str) -> None:
    """Insert if missing; refresh name/description/placeholders (metadata)
    but never the text of a row the admin has edited."""
    with connection() as conn:
        row = conn.execute("SELECT edited FROM email_templates WHERE key = ?", (key,)).fetchone()
        if row is None:
            conn.execute("INSERT INTO email_templates (key, name, description, subject, body, cta_label, cta_url, preheader, placeholders, edited, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)",
                         (key, name, description, subject, body, cta_label, cta_url, preheader, placeholders, _now()))
        elif not row["edited"]:
            conn.execute("UPDATE email_templates SET name = ?, description = ?, subject = ?, body = ?, cta_label = ?, cta_url = ?, preheader = ?, placeholders = ? WHERE key = ?",
                         (name, description, subject, body, cta_label, cta_url, preheader, placeholders, key))
        else:
            conn.execute("UPDATE email_templates SET name = ?, description = ?, placeholders = ? WHERE key = ?", (name, description, placeholders, key))


def update_email_template(key: str, *, subject: str, body: str, cta_label: str, cta_url: str, preheader: str) -> None:
    with connection() as conn:
        conn.execute("UPDATE email_templates SET subject = ?, body = ?, cta_label = ?, cta_url = ?, preheader = ?, edited = 1, updated_at = ? WHERE key = ?", (subject, body, cta_label, cta_url, preheader, _now(), key))


def reset_email_template(key: str) -> None:
    with connection() as conn:
        conn.execute("UPDATE email_templates SET edited = 0 WHERE key = ?", (key,))


def log_email(*, customer_id: Optional[int], to_email: str, kind: str, subject: str, status: str, error: str = "", message_id: str = "") -> None:
    with connection() as conn:
        conn.execute("INSERT INTO email_log (customer_id, to_email, kind, subject, status, error, message_id, sent_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                     (customer_id, to_email, kind, subject, status, error[:500], message_id or None, _now()))


def list_email_log(customer_id: int, limit: int = 30) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM email_log WHERE customer_id = ? ORDER BY sent_at DESC, id DESC LIMIT ?", (customer_id, limit)).fetchall()


def set_marketing_opt_out(customer_id: int, opted_out: bool) -> None:
    with connection() as conn:
        conn.execute("UPDATE customers SET marketing_opt_out = ?, updated_at = ? WHERE id = ?", (1 if opted_out else 0, _now(), customer_id))


def touch_customer_activity(customer_id: int) -> None:
    with connection() as conn:
        conn.execute("UPDATE customers SET last_active_at = ? WHERE id = ?", (_now(), customer_id))


# sequences

def get_sequence(key: str) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM email_sequences WHERE key = ?", (key,)).fetchone()


def get_sequence_by_id(sequence_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM email_sequences WHERE id = ?", (sequence_id,)).fetchone()


def list_sequences() -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM email_sequences ORDER BY id").fetchall()


def seed_sequence(*, key: str, name: str, description: str) -> int:
    with connection() as conn:
        row = conn.execute("SELECT id FROM email_sequences WHERE key = ?", (key,)).fetchone()
        if row:
            conn.execute("UPDATE email_sequences SET description = ? WHERE id = ?", (description, row["id"]))
            return row["id"]
        cur = conn.execute("INSERT INTO email_sequences (key, name, description, created_at) VALUES (?, ?, ?, ?)", (key, name, description, _now()))
        return cur.lastrowid


def set_sequence_active(sequence_id: int, active: bool) -> None:
    with connection() as conn:
        conn.execute("UPDATE email_sequences SET active = ? WHERE id = ?", (1 if active else 0, sequence_id))


def sequence_has_steps(sequence_id: int) -> bool:
    with connection() as conn:
        return conn.execute("SELECT 1 FROM sequence_steps WHERE sequence_id = ? LIMIT 1", (sequence_id,)).fetchone() is not None


def add_sequence_step(*, sequence_id: int, delay_days: int, name: str, subject: str, body: str, cta_label: str = "", cta_url: str = "") -> int:
    with connection() as conn:
        cur = conn.execute("INSERT INTO sequence_steps (sequence_id, delay_days, name, subject, body, cta_label, cta_url, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                           (sequence_id, delay_days, name.strip(), subject, body, cta_label, cta_url, _now(), _now()))
        return cur.lastrowid


def update_sequence_step(step_id: int, *, delay_days: int, name: str, subject: str, body: str, cta_label: str, cta_url: str, active: bool) -> None:
    with connection() as conn:
        conn.execute("UPDATE sequence_steps SET delay_days = ?, name = ?, subject = ?, body = ?, cta_label = ?, cta_url = ?, active = ?, updated_at = ? WHERE id = ?",
                     (delay_days, name.strip(), subject, body, cta_label, cta_url, 1 if active else 0, _now(), step_id))


def delete_sequence_step(step_id: int) -> None:
    with connection() as conn:
        conn.execute("DELETE FROM sequence_deliveries WHERE step_id = ? AND status = 'scheduled'", (step_id,))
        conn.execute("DELETE FROM sequence_steps WHERE id = ?", (step_id,))


def get_sequence_step(step_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT * FROM sequence_steps WHERE id = ?", (step_id,)).fetchone()


def list_sequence_steps(sequence_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT s.*, (SELECT COUNT(*) FROM sequence_deliveries d WHERE d.step_id = s.id AND d.status = 'sent') AS sent_count FROM sequence_steps s WHERE sequence_id = ? ORDER BY delay_days, id", (sequence_id,)).fetchall()


def customer_in_sequence(customer_id: int, sequence_id: int) -> bool:
    with connection() as conn:
        return conn.execute("SELECT 1 FROM sequence_deliveries WHERE customer_id = ? AND sequence_id = ? LIMIT 1", (customer_id, sequence_id)).fetchone() is not None


def schedule_delivery(*, customer_id: int, sequence_id: int, step_id: int, scheduled_for: str) -> int:
    with connection() as conn:
        cur = conn.execute("INSERT INTO sequence_deliveries (customer_id, sequence_id, step_id, scheduled_for, created_at) VALUES (?, ?, ?, ?, ?)", (customer_id, sequence_id, step_id, scheduled_for, _now()))
        return cur.lastrowid


def get_delivery(delivery_id: int) -> Optional[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT d.*, s.name AS step_name, s.subject, s.body, s.cta_label, s.cta_url, s.active AS step_active, q.key AS sequence_key, q.name AS sequence_name, q.active AS sequence_active "
                            "FROM sequence_deliveries d JOIN sequence_steps s ON s.id = d.step_id JOIN email_sequences q ON q.id = d.sequence_id WHERE d.id = ?", (delivery_id,)).fetchone()


def list_due_deliveries(now_iso: str, limit: int = 200) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT d.id FROM sequence_deliveries d JOIN sequence_steps s ON s.id = d.step_id JOIN email_sequences q ON q.id = d.sequence_id "
                            "WHERE d.status = 'scheduled' AND d.scheduled_for <= ? AND s.active = 1 AND q.active = 1 ORDER BY d.scheduled_for LIMIT ?", (now_iso, limit)).fetchall()


def list_deliveries_for_customer(customer_id: int) -> list[sqlite3.Row]:
    with connection() as conn:
        return conn.execute("SELECT d.*, s.name AS step_name, s.subject, s.delay_days, s.active AS step_active, q.key AS sequence_key, q.name AS sequence_name "
                            "FROM sequence_deliveries d JOIN sequence_steps s ON s.id = d.step_id JOIN email_sequences q ON q.id = d.sequence_id WHERE d.customer_id = ? ORDER BY d.scheduled_for", (customer_id,)).fetchall()


def mark_delivery(delivery_id: int, *, status: str, sent_by: Optional[str] = None, note: str = "") -> None:
    with connection() as conn:
        conn.execute("UPDATE sequence_deliveries SET status = ?, sent_at = CASE WHEN ? = 'sent' THEN ? ELSE sent_at END, sent_by = COALESCE(?, sent_by), note = ? WHERE id = ?",
                     (status, status, _now(), sent_by, note[:500], delivery_id))


def skip_scheduled_deliveries(customer_id: int, sequence_id: int, note: str) -> int:
    with connection() as conn:
        return conn.execute("UPDATE sequence_deliveries SET status = 'skipped', note = ? WHERE customer_id = ? AND sequence_id = ? AND status = 'scheduled'", (note, customer_id, sequence_id)).rowcount


def last_delivery_sent_at(customer_id: int, sequence_id: int) -> Optional[str]:
    with connection() as conn:
        row = conn.execute("SELECT MAX(sent_at) FROM sequence_deliveries WHERE customer_id = ? AND sequence_id = ? AND status = 'sent'", (customer_id, sequence_id)).fetchone()
        return row[0] if row else None


def inactive_subscribers(*, inactive_since_iso: str) -> list[sqlite3.Row]:
    """Entitled Stripe subscribers whose last activity (web session, Mac
    device, or sign-in) is before the cutoff -- or unknown but older
    than their subscription."""
    with connection() as conn:
        return conn.execute(
            "SELECT c.* FROM customers c WHERE c.marketing_opt_out = 0 AND EXISTS ("
            "  SELECT 1 FROM subscriptions s WHERE s.customer_id = c.id AND s.source = 'stripe' AND s.status IN ('active','past_due')) "
            "AND COALESCE(c.last_active_at, (SELECT MAX(last_seen_at) FROM web_sessions w WHERE w.customer_id = c.id), (SELECT MAX(last_seen_at) FROM devices d WHERE d.customer_id = c.id), c.created_at) < ?",
            (inactive_since_iso,),
        ).fetchall()


def sequence_stats() -> list[dict]:
    with connection() as conn:
        rows = conn.execute("SELECT q.id, q.key, q.name, q.active, "
                            "(SELECT COUNT(DISTINCT customer_id) FROM sequence_deliveries d WHERE d.sequence_id = q.id) AS enrolled, "
                            "(SELECT COUNT(*) FROM sequence_deliveries d WHERE d.sequence_id = q.id AND d.status = 'sent') AS sent, "
                            "(SELECT COUNT(*) FROM sequence_deliveries d WHERE d.sequence_id = q.id AND d.status = 'scheduled') AS scheduled, "
                            "(SELECT COUNT(*) FROM sequence_steps s WHERE s.sequence_id = q.id AND s.active = 1) AS steps "
                            "FROM email_sequences q ORDER BY q.id").fetchall()
        return [dict(r) for r in rows]
