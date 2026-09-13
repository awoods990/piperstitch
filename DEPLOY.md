# Deploying the web edition to Railway

Two services from this one GitHub repo, in one Railway project:

| Service | What | Root directory | Config |
|---|---|---|---|
| **app** | Swift engine server + the built browser app (`server/Dockerfile`) | `/` (repo root) | `server/railway.json` |
| **license-admin** | Accounts, trial, Stripe, saved projects (`license-admin/Dockerfile`) | `license-admin` | `license-admin/railway.json` |

The browser talks only to **app**; **app** talks to **license-admin**
server-to-server. Stripe's webhooks go to **license-admin**. Everything
below is a one-time setup; after it, every push to `main` redeploys.

## 0. Before you start

- The repo is on GitHub (`awoods990/piperstitch`) and the CI workflow is
  green — Railway builds the same Dockerfiles CI does.
- Have ready: a Stripe account (test mode is fine), and a Postmark server
  token — Postmark sends as `hello@piperstitch.com` (replies redirect to
  `contact@piperstitch.com`, a real Microsoft 365/GoDaddy mailbox); see
  license-admin/README.md's "Email deliverability" section for the DNS
  records Postmark needs before mail actually arrives anywhere.
- Generate the secrets you'll paste in (run each, keep the output somewhere
  safe — never in git or in chat):

```bash
python3 -c "import secrets; print('SESSION_SECRET (license-admin) =', secrets.token_hex(32)); print('SESSION_SECRET (app) =', secrets.token_hex(32)); print('WEB_API_KEY =', secrets.token_urlsafe(32)); print('INTAKE_API_KEY =', secrets.token_hex(24)); print('DOWNLOAD_LINK_SECRET =', secrets.token_hex(24))"
```

```bash
cd license-admin && ./.venv/bin/python scripts/set_admin_password.py
```

The `PIPERSTITCH_LICENSE_PRIVATE_KEY` value is `PRIVATE_KEY_B64` in
`~/Documents/PiperStitch-Licensing/PRIVATE_KEY_DO_NOT_SHARE.txt`.

## 1. Create the project

1. <https://railway.com> → **Login with GitHub** → **New Project** →
   **Deploy from GitHub repo** → pick `awoods990/piperstitch`. Railway may
   ask to install its GitHub app on the repo; allow it.
2. This creates the first service. Rename it **license-admin**
   (Settings → Service name).

## 2. Service: license-admin

**Settings → Source:** Root directory `license-admin`. Railway then finds
`license-admin/Dockerfile` and `railway.json` on its own.

**Settings → Volumes → Add volume:** mount path `/data`. (The SQLite
database lives here; without a volume it is wiped on every deploy.)

**Settings → Networking → Generate domain.** When it asks for a port,
enter **8080** — Railway injects `PORT=8080` into the container and both
services listen on whatever `PORT` says (the Deploy Logs' "Uvicorn running
on …:8080" line confirms it). Note the URL — something like
`https://license-admin-production.up.railway.app`. This is
`PUBLIC_BASE_URL` for now; `admin.piperstitch.com` comes in step 6.

**Variables** (Variables tab → Raw editor is quickest):

| Variable | Value |
|---|---|
| `DATABASE_PATH` | `/data/license_admin.db` |
| `PIPERSTITCH_LICENSE_PRIVATE_KEY` | from the key file |
| `ADMIN_USERNAME` | `admin` |
| `ADMIN_PASSWORD_HASH` | from `set_admin_password.py` |
| `SESSION_SECRET` | generated (the license-admin one) |
| `SESSION_COOKIE_SECURE` | `true` |
| `STRIPE_PUBLISHABLE_KEY` / `STRIPE_SECRET_KEY` | Stripe → Developers → API keys (test keys first) |
| `STRIPE_PRICE_MONTHLY` | see step 4 |
| `STRIPE_WEBHOOK_SECRET` | see step 5 |
| `POSTMARK_API_TOKEN` / `POSTMARK_FROM` | Postmark server token and a verified From address — **or** the `SMTP_*` set from `license-admin/README.md` |
| `PUBLIC_BASE_URL` | this service's URL (no trailing slash) |
| `WEBSITE_BASE_URL` | `https://www.piperstitch.com` |
| `INTAKE_API_KEY` / `DOWNLOAD_LINK_SECRET` | generated (same values the website's PHP holds) |
| `WEB_API_KEY` | generated — **the same value goes into app** |
| `WEB_APP_URL` | the **app** service's URL (step 3; come back and fill it) |
| `CORS_ALLOWED_ORIGINS` | `https://piperstitch.com,https://www.piperstitch.com` |
| `MONTHLY_PRICE_CENTS` / `TRIAL_DAYS` / `MAX_DEVICES` | `1900` / `14` / `2` (or your numbers) |

Deploy (it redeploys on variable changes). **Check:** open
`<PUBLIC_BASE_URL>/health` → `{"status":"ok"}`, and `<PUBLIC_BASE_URL>/admin`
→ the login page. The deploy log should not say "missing configuration".

## 3. Service: app

**+ New → GitHub Repo → `awoods990/piperstitch`** again. Rename it **app**.

**Settings → Source:** Root directory `/` (leave as the repo root).
**Settings → Config-as-code:** path `server/railway.json` — this is what
tells Railway to build `server/Dockerfile` (the Swift server needs the
whole repo as build context, since it depends on the root package).

**Settings → Networking → Generate domain**, port **8080** again. Note
the URL. Put it into license-admin's `WEB_APP_URL` (step 2).

**Variables:**

| Variable | Value |
|---|---|
| `LICENSE_ADMIN_URL` | license-admin's `PUBLIC_BASE_URL` |
| `WEB_API_KEY` | the same value as in license-admin |
| `SESSION_SECRET` | generated (the app one) |

`PORT` is set by Railway (8080). The first build takes ~10–15 minutes (Swift
compiles Vapor from source once; later builds reuse the cached layers).

**Check:** open the app URL → the sign-in screen. Enter your email → a code
arrives (Postmark/SMTP working) → sign in → "Free trial · 14 days left" →
drop a logo → the five questions → stitches. Download a DST.

## 3b. Service: site (the marketing website)

**+ New → GitHub Repo → `awoods990/piperstitch`** a third time. Rename it
**site**. **Settings → Source → Root directory** `website`. Railway finds
`website/Dockerfile` (nginx serving the static pages). **Networking →
Generate domain**, port **8080**. No variables needed.

Custom domains: **Settings → Networking → + Custom Domain** →
`www.piperstitch.com`, and again `piperstitch.com`. GoDaddy: a **CNAME**
`www` → the target Railway shows (plus its TXT verification record). For
the bare `piperstitch.com`, GoDaddy can't CNAME an apex, so use
**Domain → Forwarding**: forward `piperstitch.com` to
`https://www.piperstitch.com` (301, forward path). The site's canonical
URLs are all `www`, so that's the right direction.

Every push to `main` that touches `website/` redeploys the site.

## 4. Stripe: the price

Locally, with the test secret key in `license-admin/.env`:

```bash
cd license-admin && ./.venv/bin/python scripts/create_stripe_prices.py
```

Put the printed `price_…` id into license-admin's `STRIPE_PRICE_MONTHLY`.

## 5. Stripe: the webhook

Stripe Dashboard → Developers → Webhooks → **Add endpoint** →
`<license-admin PUBLIC_BASE_URL>/webhooks/stripe`, events
`checkout.session.completed`, `customer.subscription.created`,
`customer.subscription.updated`, `customer.subscription.deleted`,
`invoice.paid`, `invoice.payment_failed`. Copy the signing secret into
`STRIPE_WEBHOOK_SECRET`.

**Check the whole loop:** in the app's account menu, **Subscribe** → Stripe
Checkout (test card `4242 4242 4242 4242`, any future date) → back in the
app with "You're subscribed" → the account menu shows your email instead
of the trial countdown → `/admin/subscribers` lists you as active.

## 6. Your own domains

Railway: each service → Settings → Networking → **Custom domain** →
`app.piperstitch.com` for **app**, `admin.piperstitch.com` for
**license-admin**. Railway shows a CNAME target for each.

GoDaddy: DNS → add two **CNAME** records (`app` and `admin`) pointing at
those targets. Certificates are automatic once DNS resolves (minutes to an
hour).

Then update: license-admin's `PUBLIC_BASE_URL` → `https://admin.piperstitch.com`,
`WEB_APP_URL` → `https://app.piperstitch.com`; app's `LICENSE_ADMIN_URL` →
`https://admin.piperstitch.com`; and the Stripe webhook endpoint URL.
Point the marketing site's "Start free trial" / sign-in links at
`https://app.piperstitch.com`.

## 7. Optional but worth doing

- **Nightly Stripe reconcile:** + New → GitHub Repo (same repo), root
  `license-admin`, Settings → **Cron schedule** `0 4 * * *`, custom start
  command `python scripts/reconcile_stripe.py`, same variables as
  license-admin (Railway's *shared variables* make this a reference). It
  needs the same `/data` volume — or simply skip it: webhooks keep the
  mirror right and the admin's *Sync* button covers the rest.
- **Backups:** Railway volumes have snapshots (Settings → Volume →
  Backups). Turn daily on. The database is the customer list.
- **Going live:** swap the four Stripe values to live-mode ones (a second
  price id from `create_stripe_prices.py` in live mode, a second webhook
  endpoint with its own secret).

## Costs

Both services on Railway's Hobby plan: about **$5/month base** plus
usage — realistically $8–15/month at launch. The app service idles at
near-zero CPU between digitizes.

## If something's wrong

- **app shows "Couldn't reach the PiperStitch server"** — the app service
  isn't up; check its deploy log.
- **Sign-in never emails a code** — license-admin's log will show the
  Postmark/SMTP error; the app only relays it.
- **"Accounts are not configured on this server"** — `LICENSE_ADMIN_URL`
  is unset on app.
- **401 "Invalid API key" in license-admin's log** — `WEB_API_KEY` differs
  between the two services.
- **Subscribed but still on the trial wall** — the webhook isn't
  reaching license-admin (Stripe → Webhooks shows delivery attempts).
  "I've already subscribed — check again" re-reads the database.
