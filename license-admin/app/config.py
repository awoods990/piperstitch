"""All configuration comes from environment variables (loaded from .env in
dev via python-dotenv; a real deployment should set these as actual
environment variables instead of shipping a .env file to the server).
Nothing here has a hardcoded secret — see .env.example for what each
variable is and how to obtain it.

Same shape as the Amerus License Admin's config.py, with the one-time
purchase/renewal settings replaced by subscription ones: a single monthly
Stripe Price, an entitlement grace window, and a per-subscription device
limit.
"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")


def _bool(name: str, default: str = "false") -> bool:
    return os.environ.get(name, default).strip().lower() in ("1", "true", "yes")


def _int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    return int(raw) if raw else default


# --- entitlement signing -----------------------------------------------
# The private half of the keypair whose PUBLIC half is baked into the
# shipped PiperStitch app (Sources/StitchPilotCore/Licensing/
# EntitlementVerifier.swift). Every entitlement token this service hands
# to an installed copy of the app is signed with this; the app trusts
# nothing else. See LICENSING.md in the main repo for where it lives.
PIPERSTITCH_LICENSE_PRIVATE_KEY = os.environ.get("PIPERSTITCH_LICENSE_PRIVATE_KEY", "")

# --- admin login -------------------------------------------------------
ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD_HASH = os.environ.get("ADMIN_PASSWORD_HASH", "")
SESSION_SECRET = os.environ.get("SESSION_SECRET", "")
# False by default so local http://127.0.0.1 testing works at all (a
# Secure cookie is never sent over plain http). MUST be true in any real
# deployment — Stripe refuses to send webhooks to a plain-http endpoint
# anyway, so a real deploy is https-only by construction.
SESSION_COOKIE_SECURE = _bool("SESSION_COOKIE_SECURE")

# --- Stripe ------------------------------------------------------------
STRIPE_PUBLISHABLE_KEY = os.environ.get("STRIPE_PUBLISHABLE_KEY", "")
STRIPE_SECRET_KEY = os.environ.get("STRIPE_SECRET_KEY", "")
STRIPE_WEBHOOK_SECRET = os.environ.get("STRIPE_WEBHOOK_SECRET", "")
# The ONE recurring Price this service sells: PiperStitch, billed monthly.
# Created by scripts/create_stripe_prices.py. There is deliberately no
# second "renewal" price the way Amerus has — a subscription renews
# itself; that is the whole point of the model.
STRIPE_PRICE_MONTHLY = os.environ.get("STRIPE_PRICE_MONTHLY", "")
# PiperStitch Proofs: the second product, sold and tracked here alongside
# the app -- three free proofs, then its own monthly subscription.
STRIPE_PRICE_PROOFS_MONTHLY = os.environ.get("STRIPE_PRICE_PROOFS_MONTHLY", "")


def stripe_mode() -> str:
    """'live', 'test' or '' from the secret key."""
    if STRIPE_SECRET_KEY.startswith("sk_live_") or STRIPE_SECRET_KEY.startswith("rk_live_"):
        return "live"
    if STRIPE_SECRET_KEY.startswith("sk_test_") or STRIPE_SECRET_KEY.startswith("rk_test_"):
        return "test"
    return ""


def stripe_mode_problems() -> list[str]:
    """Live keys with test-mode objects (or the reverse) is the classic
    go-live failure -- Checkout answers "No such price" to the first real
    customer. Key modes are visible in the key prefixes; a price id is not
    marked, so this checks the pieces that are and leaves the price check
    to the Stripe API (`stripe_client.check_prices`)."""
    problems = []
    mode = stripe_mode()
    if not mode and STRIPE_SECRET_KEY:
        problems.append("STRIPE_SECRET_KEY is neither a live nor a test key")
    if STRIPE_PUBLISHABLE_KEY and mode:
        pub_mode = "live" if STRIPE_PUBLISHABLE_KEY.startswith("pk_live_") else "test" if STRIPE_PUBLISHABLE_KEY.startswith("pk_test_") else ""
        if pub_mode and pub_mode != mode:
            problems.append(f"STRIPE_PUBLISHABLE_KEY is a {pub_mode} key but STRIPE_SECRET_KEY is {mode}")
    if STRIPE_SECRET_KEY and not STRIPE_WEBHOOK_SECRET:
        problems.append("STRIPE_WEBHOOK_SECRET is empty -- subscriptions will never reach the database")
    return problems

# --- outgoing email (plain SMTP) ---------------------------------------
SMTP_HOST = os.environ.get("SMTP_HOST", "")
SMTP_PORT = _int("SMTP_PORT", 587)
SMTP_USE_SSL = _bool("SMTP_USE_SSL")
SMTP_USERNAME = os.environ.get("SMTP_USERNAME", "")
SMTP_PASSWORD = os.environ.get("SMTP_PASSWORD", "")
SMTP_FROM = os.environ.get("SMTP_FROM", "PiperStitch <hello@piperstitch.com>")
# Where replies to any email land. Postmark sends as hello@piperstitch.com,
# which has no real inbox behind it -- contact@piperstitch.com (GoDaddy/
# Microsoft 365) is the address that actually receives mail, so replies
# should go there instead. Left empty, no Reply-To header is set and mail
# clients reply to SMTP_FROM (hello@) instead, which bounces.
REPLY_TO_EMAIL = os.environ.get("REPLY_TO_EMAIL", "contact@piperstitch.com")

# Optional: route ALL outgoing email through Postmark's HTTP API instead
# of SMTP — the same service Amerus uses for its sequence mail. Dormant
# until set. See email_postmark.py for why PiperStitch sends everything
# (not just marketing) through it when it's configured.
# Development only: instead of sending, write every email to
# ./outbox/<timestamp>.eml and log its subject -- so the sign-in code flow
# can be exercised locally with no mail server. Ignored when empty.
EMAIL_OUTBOX_DIR = os.environ.get("EMAIL_OUTBOX_DIR", "")
POSTMARK_API_TOKEN = os.environ.get("POSTMARK_API_TOKEN", "")
# From address at a domain verified in Postmark, e.g. "PiperStitch <hello@piperstitch.com>".
# Falls back to SMTP_FROM if blank.
POSTMARK_FROM = os.environ.get("POSTMARK_FROM", "")
POSTMARK_MESSAGE_STREAM = os.environ.get("POSTMARK_MESSAGE_STREAM", "outbound")

# --- URLs --------------------------------------------------------------
# Where THIS service is reachable, no trailing slash — used for Stripe's
# success/cancel redirects, the billing-portal return URL, and every link
# in an email that points back here (account page, magic links).
PUBLIC_BASE_URL = os.environ.get("PUBLIC_BASE_URL", "http://127.0.0.1:8000").rstrip("/")
# The marketing site (website/ in the main repo) — a different origin.
WEBSITE_BASE_URL = os.environ.get("WEBSITE_BASE_URL", "https://www.piperstitch.com").rstrip("/")
DOWNLOAD_BASE_URL = os.environ.get("DOWNLOAD_BASE_URL", f"{WEBSITE_BASE_URL}/downloads")
# Must exactly match the URL baked into every already-shipped build's
# UpdateChecker — changing this here does NOT change what installed
# copies poll, so it must never move once a build has shipped.
UPDATE_FEED_URL = os.environ.get("UPDATE_FEED_URL", f"{WEBSITE_BASE_URL}/updates/piperstitch-mac.json")

# --- website integration ---------------------------------------------
# Shared secret the website's own server-side PHP (register.php, get.php)
# sends as an X-API-Key header. Server-to-server only — never exposed to
# a browser — so simple header-comparison auth is enough.
INTAKE_API_KEY = os.environ.get("INTAKE_API_KEY", "")
# Signs the direct-download link in reminder emails so it works from a
# cold email click with no PHP session (get.php holds the same value).
DOWNLOAD_LINK_SECRET = os.environ.get("DOWNLOAD_LINK_SECRET", "")
# Origins allowed to call the public JSON checkout API via browser
# fetch() — the subscribe form lives on the marketing site itself.
CORS_ALLOWED_ORIGINS = [
    o.strip()
    for o in os.environ.get("CORS_ALLOWED_ORIGINS", "https://piperstitch.com,https://www.piperstitch.com").split(",")
    if o.strip()
]

# The web edition (see the repo's server/ and web/): its Swift server
# calls this service's /api/web/* endpoints server-to-server, identified
# by this shared secret in X-API-Key. Never given to a browser.
WEB_API_KEY = os.environ.get("WEB_API_KEY", "")
# Where the web app lives, for Stripe's return URLs after checkout and
# the billing portal.
WEB_APP_URL = os.environ.get("WEB_APP_URL", "http://localhost:5173").rstrip("/")
# Partner links (/r/<CODE>): the cookie's signing secret (SESSION_SECRET when
# unset) and the domain it is set for (derived from PUBLIC_BASE_URL when unset:
# `.piperstitch.com`, so www, app, proofs and admin all see it).
REFERRAL_SECRET = os.environ.get("REFERRAL_SECRET", "")
REFERRAL_COOKIE_DOMAIN = os.environ.get("REFERRAL_COOKIE_DOMAIN", "")
# The app server's own address for server-to-server calls (re-digitizing a
# saved project for the admin's project view). Usually the same as
# WEB_APP_URL; set separately when the app is on a private hostname.
APP_SERVER_URL = os.environ.get("APP_SERVER_URL", "").rstrip("/") or WEB_APP_URL

DATABASE_PATH = os.environ.get("DATABASE_PATH", "./license_admin.db")

# --- website publishing (optional) ------------------------------------
WEBSITE_SFTP_HOST = os.environ.get("WEBSITE_SFTP_HOST", "")
WEBSITE_SFTP_PORT = _int("WEBSITE_SFTP_PORT", 22)
WEBSITE_SFTP_USERNAME = os.environ.get("WEBSITE_SFTP_USERNAME", "")
WEBSITE_SFTP_PASSWORD = os.environ.get("WEBSITE_SFTP_PASSWORD", "")
WEBSITE_SFTP_DOWNLOADS_PATH = os.environ.get("WEBSITE_SFTP_DOWNLOADS_PATH", "public_html/downloads")
WEBSITE_SFTP_UPDATES_PATH = os.environ.get("WEBSITE_SFTP_UPDATES_PATH", "public_html/updates")

# --- the subscription itself ------------------------------------------
# Price in cents, stated here so the subscribe page's copy, the admin
# financials, and the Stripe Price created by scripts/create_stripe_prices.py
# all agree. The marketing site's static pages repeat the number in prose;
# README.md's go-live checklist says to change both together.
MONTHLY_PRICE_CENTS = _int("MONTHLY_PRICE_CENTS", 24_00)
PROOFS_MONTHLY_PRICE_CENTS = _int("PROOFS_MONTHLY_PRICE_CENTS", 24_00)
PROOFS_FREE_PROOFS = _int("PROOFS_FREE_PROOFS", 3)     # the trial: this many proofs sent, then subscribe
PROOFS_APP_URL = os.environ.get("PROOFS_APP_URL", "https://proofs.piperstitch.com")
CURRENCY = os.environ.get("CURRENCY", "usd")
# Stripe's standard card fee, used to estimate a promoter's net revenue
# share when the actual fee isn't on the invoice webhook (see
# promotions.record_share_for_payment; the actual fee is preferred).
STRIPE_FEE_PCT = float(os.environ.get("STRIPE_FEE_PCT", "2.9"))
STRIPE_FEE_FIXED_CENTS = _int("STRIPE_FEE_FIXED_CENTS", 30)
# Free trial length inside the app — informational here (the trial clock
# runs on the customer's Mac, see LICENSING.md), used only for email copy
# and the admin's "trial ends around" estimate.
TRIAL_DAYS = _int("TRIAL_DAYS", 14)
# How long an installed copy keeps working after the subscription's
# current period ends without the service having confirmed a renewal —
# covers a card that needs a retry, a Mac that was offline on renewal day,
# and Stripe's own dunning window. After this, the app locks.
ENTITLEMENT_GRACE_DAYS = _int("ENTITLEMENT_GRACE_DAYS", 5)
# Hard ceiling on any single entitlement token's validity, regardless of
# the subscription's period end. The app refreshes silently far more
# often than this; the ceiling exists so a cancelled subscription can't
# keep a device unlocked indefinitely just by staying offline.
ENTITLEMENT_MAX_DAYS = _int("ENTITLEMENT_MAX_DAYS", 30)
# Macs that can be signed in to one subscription at the same time.
MAX_DEVICES = _int("MAX_DEVICES", 2)
# Sign-in codes emailed to the app expire after this many minutes.
ACTIVATION_CODE_TTL_MINUTES = _int("ACTIVATION_CODE_TTL_MINUTES", 15)
# Magic links to the customer's self-service account page.
ACCOUNT_LINK_TTL_MINUTES = _int("ACCOUNT_LINK_TTL_MINUTES", 30)
# The version date shown on website/terms.html. A web sign-in records the
# customer's acceptance of this version (customers.consent_terms_version);
# bump it together with the page when the Terms change materially, and
# each customer's next sign-in stamps the new acceptance.
TERMS_VERSION = os.environ.get("TERMS_VERSION", "2026-09-15")


def require_for_serving() -> list[str]:
    """Names of required settings that are still empty — checked at
    startup so a misconfigured deploy fails immediately and obviously,
    rather than accepting subscriptions it can't actually fulfil."""
    required = {
        "PIPERSTITCH_LICENSE_PRIVATE_KEY": PIPERSTITCH_LICENSE_PRIVATE_KEY,
        "ADMIN_PASSWORD_HASH": ADMIN_PASSWORD_HASH,
        "SESSION_SECRET": SESSION_SECRET,
        "STRIPE_SECRET_KEY": STRIPE_SECRET_KEY,
        "STRIPE_WEBHOOK_SECRET": STRIPE_WEBHOOK_SECRET,
        "STRIPE_PRICE_MONTHLY": STRIPE_PRICE_MONTHLY,
        "INTAKE_API_KEY": INTAKE_API_KEY,
    }
    missing = [name for name, value in required.items() if not value]
    if not SMTP_HOST and not POSTMARK_API_TOKEN and not EMAIL_OUTBOX_DIR:
        missing.append("SMTP_HOST (or POSTMARK_API_TOKEN)")
    return missing

# The in-process scheduler (sequence emails, win-back, recurring expenses).
# Off in tests; on in production.
SCHEDULER_ENABLED = _bool("SCHEDULER_ENABLED", "true")
SCHEDULER_INTERVAL_SECONDS = _int("SCHEDULER_INTERVAL_SECONDS", 300)
