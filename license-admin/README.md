# PiperStitch License Admin

A standalone, password-protected web service for running PiperStitch's
subscription business: take monthly subscriptions through Stripe, mirror
their state from Stripe's webhooks, sign Macs in and hand the app signed
entitlements, give customers a self-service account page, and give you a
dashboard over all of it. Separate from the desktop app on purpose (same
reasoning as the Amerus License Admin it's built from) so it can be
deployed anywhere — a small VPS, Render, Railway — and put behind a
subdomain of the marketing site (`admin.piperstitch.com`).

The repo's `LICENSING.md` explains the business model and how the app,
this service and the website fit together; this file is how to run *this
service*.

## What it does

- **Subscriptions through Stripe Checkout** in subscription mode: one
  monthly Price, renews automatically, `allow_promotion_codes` on so you
  can hand out coupon codes from the Stripe Dashboard.
- **Webhooks** (`checkout.session.completed`, `customer.subscription.*`,
  `invoice.paid`, `invoice.payment_failed`) keep a local mirror of every
  subscription; idempotent on Stripe's event id.
- **The app's sign-in API**: email → six-digit code → device token +
  Ed25519-signed entitlement; background refresh; device limit; sign-out.
- **Customer account page** (`/account`): magic link by email → status,
  Macs (sign out), payments, and a button into Stripe's Billing Portal.
- **Admin** (`/admin`): dashboard KPIs (paying, MRR, past due, cancelling,
  comps, downloads), subscribers with filters, registrations (leads),
  per-customer page (grant/extend/end comps, cancel/reactivate/sync a
  Stripe subscription, sign out Macs, notes, emails, timeline), financials
  by month, CSV exports, and publishing an app update over SFTP.
- **Emails**: welcome, sign-in code, account link, failed renewal,
  cancellation scheduled, complimentary access, free-form — all
  multipart text + branded HTML, via SMTP or Postmark.

## How it fits together

```
app/
  main.py            FastAPI app — every route lives here
  config.py          All settings, from environment variables (.env in dev)
  db.py              SQLite: customers, subscriptions, events, payments, devices, codes, links
  entitlement.py     Signs/verifies entitlement tokens (mirrors EntitlementVerifier.swift)
  subscriptions.py   Stripe object → subscription record; comps; validity/entitlement decisions
  activation.py      Sign-in codes, device tokens, account magic links
  stripe_client.py   Checkout Sessions (subscription mode), Billing Portal, cancel, webhooks
  email_sender.py    Every email the service sends (SMTP, or Postmark when configured)
  email_branding.py  Plain text → branded HTML
  auth.py            Admin password hashing, session gate, login lockout
  website_publish.py SFTP upload of a build + the update feed
  templates/         Jinja2 HTML (admin pages, subscribe/account pages)
scripts/
  set_admin_password.py   Prompts for a password, prints its hash for .env
  create_stripe_prices.py One-time: creates the product + monthly Price in Stripe
  generate_keypair.py     Only if the real keypair is ever lost — see LICENSING.md
  reconcile_stripe.py     Nightly: re-pull every subscription from Stripe (missed-webhook safety net)
tests/               71 pytest tests; disposable keypair, temp DB, fake SMTP/Stripe
```

## One-time setup

```bash
cd license-admin
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt
cp .env.example .env    # then fill in .env — see below
```

### Fill in `.env`

| Variable | Where it comes from |
|---|---|
| `PIPERSTITCH_LICENSE_PRIVATE_KEY` | `PRIVATE_KEY_B64` from `~/Documents/PiperStitch-Licensing/PRIVATE_KEY_DO_NOT_SHARE.txt`. Its public half is already baked into the app and `app/entitlement.py`. |
| `ADMIN_PASSWORD_HASH` | `python3 scripts/set_admin_password.py` |
| `SESSION_SECRET` | `python3 -c "import secrets; print(secrets.token_hex(32))"` |
| `SESSION_COOKIE_SECURE` | `false` locally, **`true` in any real deployment.** |
| `STRIPE_PUBLISHABLE_KEY` / `STRIPE_SECRET_KEY` | Stripe Dashboard → Developers → API keys. A **new Stripe account** for PiperStitch, or a separate product in the existing one — either way, test keys until you go live. |
| `STRIPE_PRICE_MONTHLY` | `python3 scripts/create_stripe_prices.py` (needs `STRIPE_SECRET_KEY`). Once in test mode, once more in live mode. |
| `STRIPE_PRICE_PROOFS_MONTHLY` | The same script prints it: the PiperStitch Proofs monthly price ($24 by default, `PROOFS_MONTHLY_PRICE_CENTS`). Proofs is sold and tracked here as a second product on the same customer — three free proofs (`PROOFS_FREE_PROOFS`), then this subscription. `PROOFS_APP_URL` is where its checkout returns to. |
| `STRIPE_WEBHOOK_SECRET` | See "Stripe webhook" below. |
| `SMTP_*` (fallback, not what's live) | A Microsoft 365 mailbox, same pattern as Amerus's setup: `smtp.office365.com`, port 587, `SMTP_USE_SSL=false`, the mailbox's address/app password. Only used when `POSTMARK_API_TOKEN` is unset. |
| `POSTMARK_*` | **This is what actually sends production email.** Postmark server token + `POSTMARK_FROM=PiperStitch <hello@piperstitch.com>`. See "Email deliverability" below — Postmark needs its own DNS records added before mail from hello@ will actually arrive anywhere. |
| `REPLY_TO_EMAIL` | `contact@piperstitch.com` — hello@ (above) has no real inbox behind it; this is what puts a working reply address on every outgoing email. |
| `PUBLIC_BASE_URL` | Where this service is reachable — `http://127.0.0.1:8000` locally, `https://admin.piperstitch.com` deployed. |
| `WEBSITE_BASE_URL` | The marketing site. |
| `INTAKE_API_KEY` / `DOWNLOAD_LINK_SECRET` | Random hex; the SAME values go in the website's `register.php` / `get.php`. |
| `MONTHLY_PRICE_CENTS`, `TRIAL_DAYS`, `MAX_DEVICES`, `ENTITLEMENT_GRACE_DAYS`, `ENTITLEMENT_MAX_DAYS` | The business numbers. The website's prose and the app's `LicenseConfig` repeat the first three — change together. |
| `WEBSITE_SFTP_*` (optional) | cPanel SFTP account for the Updates page. |

### Stripe webhook

**Locally:** `stripe listen --forward-to localhost:8000/webhooks/stripe`
and put the printed `whsec_…` in `.env`.

**Deployed:** Stripe Dashboard → Developers → Webhooks → Add endpoint →
`https://admin.piperstitch.com/webhooks/stripe`, events:
`checkout.session.completed`, `customer.subscription.created`,
`customer.subscription.updated`, `customer.subscription.deleted`,
`invoice.paid`, `invoice.payment_failed`. Copy the signing secret into
`.env` and restart.

### Email deliverability

The intended split: **Postmark sends** every transactional email as
`hello@piperstitch.com` (no real inbox behind that address — it's a
sending identity only); **replies go to `contact@piperstitch.com`**, a
real mailbox on GoDaddy/Microsoft 365 (`REPLY_TO_EMAIL`, above). Getting
this actually working needs DNS changes beyond just setting the app's own
env vars:

1. **Verify the sending domain in Postmark** — Postmark dashboard →
   Sending → Domains → add `piperstitch.com`. It gives you a DKIM `TXT`
   record (`<selector>._domainkey.piperstitch.com`) to add in GoDaddy's
   DNS. Without this, mail isn't signed at all.
2. **Add Postmark to the domain's SPF record.** As of this writing,
   piperstitch.com's SPF is `v=spf1 include:secureserver.net -all` —
   GoDaddy only, hard fail, no Postmark include. Add Postmark's include
   (Postmark's domain setup page gives the exact value) to the *existing*
   record rather than replacing it — a domain can only have one SPF
   `TXT` record: `v=spf1 include:secureserver.net include:<postmark's value> -all`.
3. **Check DMARC.** Current policy is `p=quarantine` — mail failing both
   SPF and DKIM gets quarantined or dropped by any receiving server that
   honors DMARC (Gmail, Outlook.com, ...), which is exactly what was
   happening with neither of the above in place. Once DKIM is added and
   aligned, DMARC passes on DKIM alone even if some SPF edge case still
   fails, but do both.
4. **Confirm `contact@piperstitch.com` is a real, provisioned mailbox**
   in the Microsoft 365 admin center (not just a DNS entry) — an address
   can resolve via MX and still bounce if nothing's actually provisioned
   for it. Consider also adding `hello@` as an alias that forwards to
   `contact@`, so a direct email to hello@ (not just a reply) still
   reaches someone, in case `REPLY_TO_EMAIL` isn't honored by every
   mail client.
5. **After DNS changes propagate** (can take a few hours), send a real
   test signup/sign-in through the live app and confirm the code
   arrives and that replying lands in the contact@ inbox. Postmark's
   own Activity log (dashboard) also shows per-message delivery status
   and any bounce/spam-complaint reason directly — check there first
   if something still isn't arriving.

None of this lives in the app's own config — it's DNS (GoDaddy) and the
Postmark/Microsoft 365 dashboards, so it has to be done by whoever holds
those accounts.

### Stripe Billing Portal

Dashboard → Settings → Billing → Customer portal: turn on *update payment
method*, *invoice history*, and *cancel subscription* (at end of period).
Leave *switch plans* off. The portal is what the account page's "Manage
billing" button opens.

## Running it

```bash
./.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
```

- Subscribe (fallback form): `http://127.0.0.1:8000/subscribe`
- Customer account page: `http://127.0.0.1:8000/account`
- Admin login: `http://127.0.0.1:8000/admin/login`

## Deploying it

Identical to the Amerus License Admin: a plain ASGI app. systemd +
nginx/Caddy on a VPS (`uvicorn app.main:app --host 127.0.0.1 --port 8000`,
`Restart=always`, TLS at the proxy), or a Render/Railway/Fly service with
the same run command and the `.env` variables set in the platform's
dashboard. Stripe requires `https://` for webhooks and redirects.

Cron, on the server:

```
0 4 * * * cd /opt/piperstitch-admin && ./.venv/bin/python scripts/reconcile_stripe.py >> /var/log/piperstitch-reconcile.log 2>&1
```

Secrets (`.env`, the private key) never belong in git — already in
`.gitignore`.

## Day-to-day use

- **A customer subscribes:** nothing to do. The webhook mirrors it and the
  welcome email goes out; they sign in inside the app.
- **Someone says the app is locked:** open their record (`/admin/subscribers`,
  search by email). The status line says exactly what's going on; *Sync
  from Stripe* repairs a missed webhook; *Send account link* gets them to
  the card page; *Sign out* frees a Mac slot.
- **A comp:** their record → *Grant complimentary access*.
- **Money:** `/admin/financials` and the CSV.
- **A release:** `/admin/updates`.

## Testing

```bash
./.venv/bin/pytest -q
```

71 tests mock the real boundaries — SMTP/Postmark, Stripe's API, the
signing key — no test sends an email, calls Stripe, or touches your real
key.

## Security notes

- Admin password stored only as a PBKDF2 hash; 8 wrong attempts from one
  IP locks that IP out for 15 minutes.
- Webhooks always verify Stripe's signature first; unsigned requests are
  refused with 400 before any code touches the body.
- Sign-in codes, device tokens and account links are stored as SHA-256
  hashes; codes expire in 15 minutes, allow 5 attempts, and only the
  newest code for an email+Mac is live; at most 5 codes per email per hour.
- The account page's "enter your email" form gives the same response
  whether or not the address is known. The app's sign-in deliberately
  does tell the user "no subscription for this email" — a real customer
  needs that answer more than the address list needs hiding.
- `PIPERSTITCH_LICENSE_PRIVATE_KEY` unlocks PiperStitch for anyone who
  holds it. Treat the server's environment accordingly.
