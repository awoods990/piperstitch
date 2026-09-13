# Licensing — How It Actually Works

The operational guide: what happens automatically, what you do by hand,
and where everything lives. The code is in three places —
`license-admin/` (the server), `website/` (the marketing site with the
download gate and subscribe form), and `Sources/StitchPilotCore/Licensing/`
plus `Sources/StitchPilotApp/LicenseManager.swift` (the app). This file is
the "how do I actually run this business" view on top of them.

The whole system is modelled on the Amerus License Admin and amerus.ai
site — same service shape, same hosting, same third parties (GoDaddy
cPanel, Stripe, Microsoft 365 mail, optional Postmark) — with the one-time
licence key replaced by a monthly subscription. Nothing in the Amerus
project was changed; this is a copy that diverged.

## The model, in one paragraph

Every install gets a **14-day free trial** automatically — no card, no
account. After that the editor is locked until someone **signs in with an
email that has an active subscription**. A subscription is **$24/month**,
started on the website's pricing page through Stripe, and **renews
automatically** until the customer cancels. There is no licence key: the
app signs in by email + six-digit code, receives a short-lived
Ed25519-signed *entitlement* from License Admin, and refreshes it silently
in the background. Cancelling keeps the app working to the end of the paid
period; exported files are ordinary files and keep working forever.

## The web edition

The browser app (repo: `web/`, served by `server/`) uses the **same
License Admin, the same Stripe subscription and the same customer
record** as the Mac app -- one email, one $24/month, either edition.
The difference is where the free trial lives: a Mac gets its 14 days
from the install with no account, but a browser can't be trusted to
keep a trial clock, so on the web the trial belongs to the *account* and
starts the first time an email is verified. It's a `trialing`
subscription row (`source = manual`, notes "Web free trial") that never
renews; one per email, ever. A Stripe subscription later takes over
from it through the normal webhook path, and a customer who already
subscribed on the Mac simply signs in on the web with no trial.

Sign-in is the same email + six-digit code, but any address may request
a code (verifying it is how the trial starts). The web server holds the
resulting session token in its own HttpOnly cookie and asks License
Admin's `/api/web/*` endpoints -- server-to-server, with the `WEB_API_KEY`
shared secret -- for the account's standing, Stripe Checkout / Billing
Portal links, and saved projects (`projects` table: the design's JSON,
per account). Browser sessions don't count toward the two-Mac device
limit. In the admin, a web trial shows as a `trialing` subscription and
`web_signed_in` / `trial_started` events on the customer.

## Promotions

Two kinds of code, both managed entirely from `/admin/promotions` (the
admin never opens Stripe for this):

- **Promoter referral codes** — a promoter (a person or organization,
  with their own record and page) gets one or more codes. Their audience
  enters the code and receives the discount (1–100%, for N monthly cycles
  or forever); the promoter earns a share (0–100%) of the **net** revenue
  from every invoice those customers pay — net meaning amount paid minus
  Stripe's fee (the actual fee when Stripe reports it, otherwise the
  standard 2.9% + 30¢ estimate, marked as such). The promoter's page is a
  ledger: referred customers, each invoice's gross/fee/net/share, what
  has been paid to them, and what's owed. Payouts are recorded by hand.
- **Direct discounts** — a code the admin gives a person or group:
  discount and duration in monthly cycles, optionally restricted to
  listed email addresses, capped in uses, or expiring. No revenue share.

Each code is created as a real Stripe coupon + promotion code, so the
discount appears on Stripe's invoices and receipts. Codes are entered in
the app (subscribe wall, Settings → Account & billing, or a
`app.piperstitch.com/?promo=CODE` link) or on the pricing page; the
server validates them (active, not expired, uses left, allowed email) and
applies them to the Checkout session, tagging the subscription with the
promotion so the webhook can attribute the redemption. Stripe's own
"add promotion code" field is off. The admin can also apply a code to a
*current* subscriber from their customer page (from the next invoice).
Every redemption and share shows on the customer's record, the
promoter's record, and the Promotions dashboard.

## The pieces

```
website/pricing.html ─fetch─▶ license-admin /api/checkout ─▶ Stripe Checkout (mode=subscription)
                                                                  │ webhooks
                                                                  ▼
                              license-admin  ── mirrors the subscription (SQLite), emails welcome ──▶ customer
                                   ▲    │
   app: Sign In → email ───────────┘    └──▶ 6-digit code by email
   app: code ──▶ /api/app/activate/verify ──▶ device token + signed entitlement (PSE1.…)
   app: every 12h ──▶ /api/app/entitlement ──▶ fresh entitlement (or 402: subscription ended)
   customer: /account ──▶ magic link ──▶ Stripe Billing Portal (card, invoices, cancel), sign out Macs
   admin:    /admin ──▶ subscribers, MRR, past-due, comps, cancel/reactivate, devices, updates
```

## The trial (app side)

- Starts the first time PiperStitch launches on a Mac. Counts calendar
  days including the first, so it ends at the end of day 14.
- Tracked in **two** places — `~/Library/Application Support/PiperStitch/
  license.json` (0600) and `UserDefaults` (`com.piperstitch.license`) — and
  the *earlier* start wins, so deleting one doesn't reset the clock. See
  `LicenseRecord` in `LicenseManager.swift`.
- When it ends: `LockedOverlay` covers the editor with Subscribe / Sign In
  buttons. Nothing is deleted; a saved project is still on disk.
- **To reset it while developing:** delete that file and run
  `defaults delete com.piperstitch.app com.piperstitch.license` (or
  `defaults delete StitchPilot com.piperstitch.license` for a bare
  `swift run` binary).

## Signing in (app side)

`AccountSheet` (PiperStitch menu → *PiperStitch Subscription…*, the
status-bar pill, or the locked overlay):

1. Customer types their email → `POST /api/app/activate/request`. If the
   email has no entitled subscription the server says so and the sheet
   offers the pricing page — no code is sent.
2. Code arrives by email → `POST /api/app/activate/verify` → the app
   stores a **device token** and its first **entitlement**, verifies the
   entitlement's signature against the public key baked into
   `LicenseConfig.production`, and unlocks.
3. Every launch and every 12 hours: `POST /api/app/entitlement` with the
   device token → a fresh entitlement. Offline? The current one keeps
   working until its `exp`. Revoked (signed out from the account page or
   by you)? The app drops its token and locks.

Up to **2 Macs** per subscription (`MAX_DEVICES`). A Mac signing in again
replaces its own token rather than counting twice.

## The entitlement token

`PSE1.<base64url(payload JSON)>.<base64url(Ed25519 signature)>` — see the
docstring in `license-admin/app/entitlement.py` and
`Sources/StitchPilotCore/Licensing/Entitlement.swift`; they must stay in
sync, and `Tests/StitchPilotCoreTests/LicensingTests.swift` carries a
token signed by the Python side to prove they do.

How long a token lasts is decided in `license-admin/app/subscriptions.py`
→ `validity_for`: the earlier of *period end + 5 days grace* and *now + 30
days*. So an active subscriber's Mac is never more than ~30 days from a
lock if the server stops confirming; a cancelled subscription gets no
grace past the date the customer was told; `past_due` keeps working
through the grace days while Stripe retries the card.

## Where the private key lives

`~/Documents/PiperStitch-Licensing/PRIVATE_KEY_DO_NOT_SHARE.txt` on this
Mac — generated once, deliberately outside this repository. Its
`PRIVATE_KEY_B64` line goes into license-admin's `.env` as
`PIPERSTITCH_LICENSE_PRIVATE_KEY`; its `PUBLIC_KEY_B64` is already in both
`license-admin/app/entitlement.py` (`_PUBLIC_KEY_B64`) and
`LicenseConfig.production.publicKeyBase64`.

Anyone with the private half can unlock PiperStitch for anyone. Back it up
in a password manager; never commit it. If it's lost, run
`license-admin/scripts/generate_keypair.py`, update both public-key
constants, and ship a new build — every already-installed copy will reject
tokens from the new key until it updates.

## Selling a subscription (nothing to do per sale)

1. Customer subscribes on `pricing.html` → Stripe Checkout.
2. Stripe's webhook tells License Admin → subscription mirrored → welcome
   email ("open PiperStitch, Sign In, use this email").
3. Customer signs in inside the app. Done.

Renewals, failed cards, cancellations and reactivations all arrive as
webhooks and are applied automatically (`subscriptions.sync_from_stripe`,
`record_invoice`). A nightly `scripts/reconcile_stripe.py` re-pulls every
subscription from Stripe as a safety net for a missed webhook.

## What you do by hand (admin, `/admin`)

- **Complimentary access** — a reviewer, a friend, a make-good: customer
  record → *Grant complimentary access*, N months or through a date. No
  Stripe involved; extend or end it from the same page.
- **Cancel for someone** — at period end (kind default) or immediately
  (refunds/abuse). Goes through Stripe; the webhook echo updates the record.
- **Sign out a Mac** — if a customer can't reach the account page.
- **Sync from Stripe** — repairs one subscription after a missed webhook.
- **Resend welcome / send account link / write an email.**
- **Delete a record** — refused while a paid subscription is live, so
  nobody keeps getting charged for a record that no longer exists.

## Customer self-service (`/account`)

Enter email → one-time link by email → page showing status, next renewal
or end date, signed-in Macs (sign any out), payments, and a **Manage
billing** button into Stripe's hosted Billing Portal (update card,
invoices, cancel/resume). What the portal allows is configured in the
Stripe Dashboard → Settings → Billing → Customer portal — turn on
*cancel subscriptions* and *update payment method*; leave *switch plans*
off (there's one plan).

## Shipping an update

Each build's version is `CFBundleShortVersionString` in
`Resources/Info.plist`. The app polls `LicenseConfig.updateFeedURL` —
**nil in development builds** so nothing polls a URL nobody hosts. Before
the first public release set it to the permanent
`https://www.piperstitch.com/updates/piperstitch-mac.json` and never move
it. Then, per release: bump the version, `Scripts/build_app_bundle.sh`,
make a `.dmg`, and either use License Admin's **Updates** page (SFTP) or
upload to `website/releases/` and rewrite the feed by hand — see
`website/READ-ME-FIRST.md`. A running copy shows "PiperStitch X is
available" in its status bar with a download link; nothing installs
itself.

## Prices and numbers live in four places

`$24`, `14 days`, `2 Macs`: `license-admin/.env` (`MONTHLY_PRICE_CENTS`,
`TRIAL_DAYS`, `MAX_DEVICES`), the Stripe Price (created once by
`scripts/create_stripe_prices.py`), the website's prose, and
`LicenseConfig.production.trialDays`. Change them together.

## Verifying it without waiting 14 days

- App: edit `firstLaunchAt` in `license.json` (and the defaults blob, or
  delete the defaults key) to 20 days ago; relaunch → locked overlay.
- Server: `license-admin/tests/` covers every state (trial lead, active,
  past-due within/after grace, cancelling, cancelled, comp, device limit,
  revoked device, ended subscription on refresh). `./.venv/bin/pytest -q`.
- End to end locally: run license-admin with a test keypair, then launch a
  debug build with `PIPERSTITCH_API_BASE=http://127.0.0.1:8000
  PIPERSTITCH_PUBLIC_KEY=<test public key>` — DEBUG builds honour these
  two variables (`LicenseConfig.current`); release builds ignore them.

## The honest limitation

PiperStitch ships unsigned and un-notarized, and its subscription check
is client-side code in a binary the customer owns. As with Amerus, no
check in an app distributed this way is unbypassable — a determined
person with a debugger can patch out `isLocked`. What this design does
guarantee:

- An entitlement that verifies really was issued by License Admin for
  this Mac — it can't be forged, and one Mac's token is useless on another.
- A stored entitlement can't be edited to extend its expiry.
- A casual user can't reset the trial by deleting one file.
- Nothing about the customer's artwork ever leaves their Mac.

Closing the remaining gap means code-signing and notarizing the app (which
also removes the Gatekeeper right-click-to-open step), a distinct project
from the licensing system itself.
