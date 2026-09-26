# PiperStitch Partner Program — Build Specification

**Status:** ready to build · **Owner:** Ashley Woods · **Last updated:** 21 Sept 2026
**Repo:** `awoods990/piperstitch` · **Primary service:** `license-admin/` (FastAPI + SQLite + Jinja2, Stripe 11.4.1, Railway)

---

## 0. Read this first

**Most of this already exists.** `license-admin/app/promotions.py` is a working promoter
revenue-share system: promoters, codes backed by real Stripe coupons, redemption tracking,
per-invoice share accrual, an owed-versus-paid ledger, and admin pages at `/admin/promotions`
and `/admin/promoters`. The Financials page already folds promoter payouts into P&L.

**This brief is an extension of that system, not a replacement.** Do not build a parallel
affiliate module. Do not introduce a new datastore, framework, or service. Everything below
either adds columns to existing tables, adds branches to existing functions, or adds pages
alongside existing ones.

Before writing code, read in this order:

1. `license-admin/app/promotions.py` — the whole file. It is short and it is the core.
2. `license-admin/app/db.py` — the `promoters`, `promotions`, `promo_redemptions`,
   `promo_payouts`, `promoter_payments` DDL (~line 226 onward), and `record_promo_payout`,
   `record_promoter_payment`, `promoter_totals` (~line 1397 onward).
3. `license-admin/app/main.py` — routes from ~line 1482 (`/admin/promotions` … `/admin/promoters/*`)
   and the `/api/promo/validate` + `/api/web/promo/validate` endpoints (~lines 349, 679).
4. `license-admin/app/web_access.py` — how a web trial starts (`config.TRIAL_DAYS`, ~line 162).
5. `license-admin/app/config.py` — `TRIAL_DAYS`, `PROOFS_FREE_PROOFS`, `STRIPE_FEE_PCT`,
   `STRIPE_FEE_FIXED_CENTS`.
6. `license-admin/app/templates/` — `promotions.html`, `promoter_detail.html`,
   `account_request.html` / `account_link_sent.html` / `account_manage.html` (the magic-link
   pattern we will reuse for partner login), `admin_base.html`.

### 0.1 Exact touchpoints

Verified against the working tree on 21 Sept 2026. Line numbers may drift; the symbol names will not.

| What | File | Line |
|---|---|---|
| `create_promotion()` | `app/promotions.py` | 52 |
| ↳ **`if not (0 < percent_off <= 100)` — blocks our no-discount offer (§3.2)** | `app/promotions.py` | **61** |
| `describe()` — renders "X% off", needs a perks branch | `app/promotions.py` | 123 |
| `attribute_subscription()` | `app/promotions.py` | 140 |
| `record_share_for_payment()` | `app/promotions.py` | 194 |
| ↳ **`redemption_for_subscription(...)` — the Proofs underpayment bug (§3.1)** | `app/promotions.py` | **199** |
| `db.redemption_for_subscription()` | `app/db.py` | 1392 |
| `db.record_promo_payout()` | `app/db.py` | 1397 |
| `db.promoter_totals()` — audit for negative rows | `app/db.py` | 1443 |
| `timedelta(days=config.TRIAL_DAYS)` — trial length (§9) | `app/web_access.py` | 162 |
| `promoters` DDL | `app/db.py` | 226 |
| `promo_payouts` DDL | `app/db.py` | 269 |
| `/admin/promotions` route | `app/main.py` | 1482 |

Confirmed absent: **`db.redemption_for_customer()` does not exist** — it is new work in §5.3.

Then confirm §3's gap analysis against the code and report any discrepancy before building.

**Money correctness is the priority.** Prefer boring and auditable. Every rule in §2 has a test
in §12. All money is integer cents.

---

## 1. What we are building

We are recruiting ~50 creators and educators in the machine-embroidery niche. The commercial
differentiator is that no competitor in this category pays recurring commission at all — every
published embroidery affiliate program pays 15–20% once, on a ~$12 design download.

Three new surfaces plus changes to the engine:

| Surface | Where | What |
|---|---|---|
| Public program page | `piperstitch.com/partners` | The offer, calculator, FAQ, link to apply. Public. |
| Partner portal | `piperstitch.com/partners/portal` (gated) | Password/magic-link. Their code, link, stats, earnings, creative kit. |
| Application | `piperstitch.com/partners/apply` | Form → `promoters` row with `status='applied'` |
| Admin | `admin.piperstitch.com/admin/partners` | Approvals, windows, referrals, ledger, payouts, compliance log |

Off-the-shelf affiliate platforms (Rewardful, Affonso, FirstPromoter, Tolt) were evaluated and
rejected: none supports the time-boxed signup bounty or the reinstatement threshold in §2, and
we already own a working revenue-share engine that does most of the rest.

**Non-goals for v1:** multi-currency, sub-affiliates, self-serve instant approval.

---

## 2. Program rules

Contractual. Implement exactly. Each has a test in §12.

| Rule | Value |
|---|---|
| Recurring rate — founding partners (first 50) | **30%** |
| Recurring rate — standard partners (after the first 50) | **25%** |
| Commission term, per referred customer | **24 months** |
| Term starts | That customer's **first successful payment** |
| Signup bounty | **$15.00** per referred customer |
| Bounty eligibility | The partner's **first 120 days**, unlimited count |
| Bounty reinstatement | Permanent, at **25+ active referrals** |
| Bounty clawback | Cancel or refund within **60 days** of first payment |
| Cookie window (link attribution) | **90 days** |
| Payout | Monthly, net-30, **$50 minimum**, balance rolls over |
| Audience offer | **30-day trial** (not 14) and **10 proofs** (not 3). **No price discount.** |

### 2.1 Precise statements

**R1 — Commission base.** A percentage of each paid invoice for an attributed customer, covering
**both** the core subscription and the Proofs add-on. Compute from the actual invoice, never from
a hardcoded $24 — this makes proration, mid-cycle upgrades, partial refunds and future price
changes correct for free. See §13.1 for the gross-versus-net decision, which must be settled
before any partner terms are published.

**R2 — Rate is stored per promoter, not global.** Set at approval, changed only by explicit admin
action. Changing the program's headline rate must never alter existing partners' entries. The
existing `promotions.share_pct` already gives per-code storage; keep using it.

**R3 — Term start.** The 24-month clock starts at the referred customer's first *successful
payment*, not trial start and not redemption. Written once, immutable.

**R4 — Term does not restart.** Cancel-then-resubscribe resumes commission only if the original
window is still open, and still ends at the original date.

**R5 — Bounty trigger.** $15 fires **once per referred customer**, on first successful payment,
if at that moment either the payment date is inside the partner's bounty window, or the partner's
reinstatement flag is set. **Never on trial start** — a bounty on a free trial will be farmed.

**R6 — Bounty clawback.** Cancellation, full refund or chargeback within 60 days of first payment
reverses the bounty. Recurring share on refunded invoices reverses separately and proportionally.

**R7 — Reinstatement.** When active referrals reach 25, set the flag permanently. It does not
lapse if the count later falls. "Active" = a referred customer with a currently active or trialing
subscription that has made at least one successful payment.

**R7a — The three tiers, and why only two are stored.** The program has three tiers publicly:

| Tier shown to the partner | Rate | Bounty | How it is represented |
|---|---|---|---|
| **Founding partner** (first 50) | 30% | first 120 days | `tier='founding'`, `share_pct=30` |
| **Partner** (open enrolment) | 25% | none | `tier='standard'`, `share_pct=25` |
| **Established partner** (25+ active) | unchanged | **restored permanently** | `bounty_reinstated_at IS NOT NULL` |

"Established" is a **derived label, never a stored tier value.** It changes nothing about the rate
or the term — it only means the signup bounty has come back. Compute it for display as
`bounty_reinstated_at IS NOT NULL` and label it "Established partner" in the portal (§7), the
admin partner list (§8), and the reinstatement email. Writing `'established'` into `tier` would
break the rate lookup, because rate follows `founding`/`standard` and nothing else.

**R8 — Attribution precedence.** An entered code always beats a link cookie. Attribution is
provisional until first payment and locked at first payment.

**R9 — Attribution is per customer, not per subscription.** See §3.1 — this is a correctness fix
to existing behaviour, not a new feature.

**R10 — Self-referral prohibited.** A promoter earns nothing on their own account. Match the
promoter's `email` and payout email; flag rather than silently drop.

**R11 — Ledger is append-only.** `promo_payouts` rows are never edited. Reversals are new rows
with negative `share_cents` referencing the original.

**R12 — Idempotency.** Every Stripe event processed at most once.

---

## 3. Gap analysis — what exists vs. what is needed

### ✅ Already built, reuse as-is

- `promoters` table with `default_share_pct`, `active`, contact fields.
- `promotions` table: `code`, `kind='promoter'|'direct'`, `promoter_id`, `share_pct`,
  `max_redemptions`, `expires_at`, `allowed_emails`, `stripe_coupon_id`,
  `stripe_promotion_code_id`, `active`.
- `promotions.create_promotion()` — creates the Stripe coupon **and** promotion code
  automatically. Partners can have several codes; the schema already supports it.
- `promotions.validate()` — expiry, exhaustion, email allow-list, active checks.
- `promotions.attribute_subscription()` — records the redemption from
  `subscription.metadata.promotion_id`, falling back to the Stripe promotion-code id on the
  discount. Codes are validated by us at checkout, never typed on Stripe's page.
- `promo_redemptions`, `promo_payouts` (per-invoice share rows), `promoter_payments`
  (money actually sent), `promoter_totals()` → owed = earned − paid.
- `promotions.record_share_for_payment()` — per-invoice share accrual.
- Admin pages `/admin/promotions`, `/admin/promoters/{id}` and the Financials integration.
- `customers.proofs_free_extra` — an admin-grantable extra-free-proofs column. **This is how the
  10-proofs perk gets delivered.** See §9.
- The magic-link account pattern (`account_request.html` → `account_link_sent.html` →
  `account_manage.html`) — reuse for partner portal sign-in.
- `auth.py` single-admin password + signed session cookie, for the admin side.

### ⚠️ Must change — existing behaviour is wrong for this program

**3.1 — Share is computed per subscription; it must be per customer.** `record_share_for_payment()`
calls `db.redemption_for_subscription(subscription_row["id"])`. Proofs is a **separate
subscription** (`subscriptions.product = 'proofs'`), so the redemption — which is attached to the
core subscription — will not be found, and **no share is paid on the Proofs add-on at all.**
Our offer explicitly promises commission on both. Fix: resolve the redemption by
`customer_id`, so every subscription that customer holds is covered. Add
`db.redemption_for_customer(customer_id)` and prefer it, keeping the per-subscription lookup as a
fallback for legacy rows.

*This is the single most important fix in this brief. Without it the program silently
underpays every partner whose referrals take Proofs — roughly half the advertised value.*

**3.2 — `percent_off` is mandatory; our offer has no discount.** `create_promotion()` enforces
`0 < percent_off <= 100`, and `promotions.describe()` renders "X% off…". The partner offer
deliberately gives **more product, not less money** — a 30-day trial and 10 proofs — because a
discount would shrink both our revenue and the partner's commission base. Required changes:
- Relax validation to `0 <= percent_off <= 100`.
- When `percent_off == 0`, do **not** create a Stripe coupon; create a promotion code with no
  discount, or skip Stripe entirely and treat the code as attribution-plus-perks only.
  Confirm which Stripe shape works and note it in the PR.
- Update `describe()` to render perks when there is no discount:
  *"30-day free trial and 10 proofs included"*.

**3.3 — No commission term cap.** `record_share_for_payment()` books a share on **every** paid
invoice, forever. Add the 24-month cut-off (R3/R4).

**3.4 — `duration_months` is the discount's duration, not the commission term.** Do not conflate
them. They are different columns with different meanings; add a new one for the term.

### ❌ Not built — new work

- Signup bounty ($15), its 120-day window, and reinstatement at 25 (R5, R7).
- Bounty and share clawback on refund/dispute/early cancellation (R6).
- Link-based attribution with a signed cookie (`/r/<CODE>`) — today attribution is code-only,
  so everyone who clicks a partner's link and signs up without typing the code is lost.
- Partner-facing portal (gated) and public `/partners` page and application form.
- Partner tiers, rate locking, application/approval lifecycle.
- Per-promotion trial-days and proofs-extra overrides (§9).
- Tax form collection and the $600 1099-NEC threshold report.
- FTC disclosure/content compliance log.

---

## 4. Schema changes

Additive migrations only, in `db.py`'s existing `_add_column_if_missing` style. Nothing is dropped
or renamed; existing promoter/direct codes keep working untouched.

```sql
-- promoters: partner program lifecycle
ALTER TABLE promoters ADD COLUMN status TEXT NOT NULL DEFAULT 'active';
       -- 'applied' | 'approved' | 'active' | 'suspended' | 'closed'
ALTER TABLE promoters ADD COLUMN tier TEXT NOT NULL DEFAULT '';
       -- 'founding' (first 50, 30%) | 'standard' (open enrolment, 25%) | ''
       -- NOTE: there is no 'established' value. The third tier is DERIVED, not stored —
       -- see §2.2 R7a. Never write 'established' here.
ALTER TABLE promoters ADD COLUMN bounty_window_start TEXT;             -- ISO date
ALTER TABLE promoters ADD COLUMN bounty_window_end TEXT;               -- start + 120 days
ALTER TABLE promoters ADD COLUMN bounty_reinstated_at TEXT;            -- ISO; permanent once set (R7)
ALTER TABLE promoters ADD COLUMN payout_method TEXT NOT NULL DEFAULT 'paypal';
ALTER TABLE promoters ADD COLUMN payout_email TEXT NOT NULL DEFAULT '';
ALTER TABLE promoters ADD COLUMN tax_form_type TEXT NOT NULL DEFAULT '';        -- 'w9' | 'w8ben'
ALTER TABLE promoters ADD COLUMN tax_form_received_at TEXT;            -- NULL blocks payout (§10.2)
ALTER TABLE promoters ADD COLUMN platforms TEXT NOT NULL DEFAULT '';   -- JSON [{platform,handle,url,followers}]
ALTER TABLE promoters ADD COLUMN application TEXT NOT NULL DEFAULT ''; -- JSON of the apply form
ALTER TABLE promoters ADD COLUMN portal_token_hash TEXT NOT NULL DEFAULT '';
ALTER TABLE promoters ADD COLUMN applied_at TEXT;
ALTER TABLE promoters ADD COLUMN approved_at TEXT;

-- promotions: the non-price perks, and the commission term
ALTER TABLE promotions ADD COLUMN trial_days INTEGER;                  -- NULL = config.TRIAL_DAYS (§9)
ALTER TABLE promotions ADD COLUMN proofs_extra INTEGER NOT NULL DEFAULT 0;  -- added to proofs_free_extra (§9)
ALTER TABLE promotions ADD COLUMN commission_months INTEGER;           -- NULL = unlimited (legacy); 24 for partners

-- promo_redemptions: the per-customer commission clock (R3, R4)
ALTER TABLE promo_redemptions ADD COLUMN first_payment_at TEXT;        -- immutable once written
ALTER TABLE promo_redemptions ADD COLUMN term_ends_at TEXT;            -- first_payment_at + commission_months
ALTER TABLE promo_redemptions ADD COLUMN bounty_payout_id INTEGER REFERENCES promo_payouts(id);
ALTER TABLE promo_redemptions ADD COLUMN attribution_source TEXT NOT NULL DEFAULT 'code';  -- 'code'|'link'|'manual'
ALTER TABLE promo_redemptions ADD COLUMN attribution_locked INTEGER NOT NULL DEFAULT 0;

-- promo_payouts: entry kinds and reversals (R11)
ALTER TABLE promo_payouts ADD COLUMN kind TEXT NOT NULL DEFAULT 'recurring';  -- 'recurring'|'bounty'|'reversal'
ALTER TABLE promo_payouts ADD COLUMN reverses_payout_id INTEGER REFERENCES promo_payouts(id);
ALTER TABLE promo_payouts ADD COLUMN note TEXT NOT NULL DEFAULT '';
-- share_cents may now be NEGATIVE on reversal rows. Audit every SUM() over this
-- table — promoter_totals() and finance.py — and confirm signed arithmetic is correct.

-- new: link attribution
CREATE TABLE IF NOT EXISTS referral_clicks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    promotion_id INTEGER NOT NULL REFERENCES promotions(id),
    clicked_at TEXT NOT NULL,
    ip_hash TEXT NOT NULL DEFAULT '',     -- hashed, never raw
    user_agent TEXT NOT NULL DEFAULT '',
    landing_path TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_referral_clicks_promo ON referral_clicks(promotion_id, clicked_at);

-- new: idempotency guard for Stripe events (R12)
CREATE TABLE IF NOT EXISTS stripe_events (
    stripe_event_id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    processed_at TEXT NOT NULL,
    result TEXT NOT NULL DEFAULT ''
);

-- new: FTC compliance log (§10.1)
CREATE TABLE IF NOT EXISTS partner_content (
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
```

### 4.1 Bounty window — cohorts for free

`bounty_window_start` / `bounty_window_end` are plain dates. Per-partner: `start = approved_at`,
`end = start + 120 days`. Per-cohort: give everyone approved in the same recruiting batch the
same pair. We recruit in batches of four, so cohorts mean ~12 date pairs rather than 50. Default
to per-partner; the admin must be able to set both fields directly and in bulk.

---

## 5. Attribution

### 5.1 Codes — existing path, keep it

The current flow is good and should remain primary: the customer types a code, we validate it
server-side via `/api/web/promo/validate`, we apply it at checkout and set
`subscription.metadata.promotion_id`, and `attribute_subscription()` records the redemption.
Codes are essential in this niche because much of it sells in Facebook Lives where nothing is
clickable.

Each partner may hold several codes (e.g. `KATHLEEN`, `KATHLEEN-YT`) — the schema already allows
it, and per-code stats let a partner see which channel converts. Codes stay
`^[A-Z0-9][A-Z0-9-]{2,29}$` per the existing `CODE_RE`.

### 5.2 Links — new, and the bigger half

Today anyone who clicks a partner's link and subscribes **without typing the code is lost.** In
practice that is most of them. Add:

```
GET piperstitch.com/r/<CODE>
  → validate code against an active promoter code
  → log a referral_clicks row (hash the IP, never store it raw)
  → set cookie, 302 to / or to ?to=<allowlisted path>

Cookie: ps_ref
Value:  <PROMOTION_ID>|<ISO timestamp>|<HMAC signature>
Domain: .piperstitch.com        # must span www, app, proofs and apex
Max-Age: 7776000                # 90 days
SameSite=Lax; Secure; HttpOnly=false   # the signup JS reads it
```

HMAC with a server-side secret so nobody can mint a code. Reject bad signatures at resolution.
Also accept `?ref=CODE` on any marketing page — partners will paste bare query strings whatever
we tell them.

At signup, pre-fill the promo field from the cookie, leave it editable, and resolve:

```
1. A valid code entered by the customer            -> that promotion, source='code'
2. Else a valid unexpired signed cookie            -> that promotion, source='link'
3. Else none
```

### 5.3 Per-customer attribution (R9)

Add `db.redemption_for_customer(customer_id)` and use it in `record_share_for_payment()` in
preference to `redemption_for_subscription()`. This is the §3.1 fix. When a customer later adds
Proofs as a second subscription, the share follows automatically.

Also: a customer may only ever be attributed to one promoter. Attribution is overwritable while
`attribution_locked = 0` (last touch wins), frozen once first payment lands.

---

## 6. Commission engine

### 6.1 `record_share_for_payment()` — changes

Keep the existing shape; add these branches in order:

```
1. redemption = db.redemption_for_customer(customer_id)            # §3.1 / R9
   or fall back to redemption_for_subscription() for legacy rows.
   None, or kind != 'promoter', or no promoter_id -> return.
2. Promoter status must be 'active'.                                # else return + log
3. If redemption.first_payment_at is NULL:                          # R3
       first_payment_at = invoice paid_at
       term_ends_at     = first_payment_at + promotions.commission_months months
                          (NULL commission_months = no cap, legacy behaviour)
       attribution_locked = 1
       maybe_award_bounty(redemption)                                # R5
4. If paid_at > term_ends_at -> return.                             # R3/R4 — the close window
5. base = gross or net per §13.1
   share = round(base * share_pct / 100)
6. db.record_promo_payout(..., kind='recurring')
7. recheck_reinstatement(promoter)                                  # R7
```

Step 4 is the whole close-window mechanism. After month 24 invoices keep arriving and are simply
ignored — no row, no error, nothing to clean up.

### 6.2 `maybe_award_bounty(redemption)` — new

```
if redemption.bounty_payout_id is not None: return          # once per customer (R5)
p = promoter
eligible = (p.bounty_window_start <= today <= p.bounty_window_end)
        or (p.bounty_reinstated_at is not None and p.bounty_reinstated_at <= now)
if not eligible: return
row = db.record_promo_payout(promoter_id=p.id, promotion_id=..., customer_id=...,
                             kind='bounty', gross_cents=0, fee_cents=0, net_cents=0,
                             share_pct=0, share_cents=1500, note='Signup bounty')
redemption.bounty_payout_id = row
```

### 6.3 `recheck_reinstatement(promoter)` — new

```
if promoter.bounty_reinstated_at is not None: return        # permanent (R7)
active = count of distinct customers attributed to this promoter
         whose subscription status is active/trialing
         and whose redemption.first_payment_at is not NULL
if active >= 25:
    promoter.bounty_reinstated_at = now()
    send the reinstatement email
```

Call after any subscription status change, not only on payment.

### 6.4 Refunds, disputes, early cancellation (R6)

Add handlers for `charge.refunded` and `charge.dispute.created`, and extend the existing
subscription-deleted path:

```
1. Resolve invoice -> customer -> redemption. None -> done.
2. Proportional reversal of the recurring row:
     share_cents = -round(original.share_cents * refunded / original_gross)
     kind='reversal', reverses_payout_id=<original.id>
3. If redemption.bounty_payout_id is set AND event date <= first_payment_at + 60 days:
     insert kind='reversal', share_cents=-1500, reverses_payout_id=<bounty id>
4. Never mutate the original row. Two rows that net correctly is the point (R11).
```

`customer.subscription.deleted` within 60 days of `first_payment_at` triggers the same bounty
reversal, then `recheck_reinstatement`. **Never** touch `first_payment_at` or `term_ends_at` here
(R4).

### 6.5 Idempotency (R12)

Every Stripe webhook handler begins by inserting into `stripe_events` on `stripe_event_id`. On
conflict, return 200 and do nothing. Stripe retries; duplicate processing means paying twice.
Verify the Stripe signature on every request.

### 6.6 Payout eligibility

A `promo_payouts` row becomes payable 60 days after its source invoice's paid date (the clawback
window). Add a nightly job, or compute eligibility on read in `promoter_totals()` — prefer
computing on read; it needs no scheduler and cannot drift.

`promoter_totals()` must return: lifetime earned, reversed, payable now, below-minimum held,
and paid. Audit it for the new negative `share_cents` rows.

---

## 7. Partner portal — `piperstitch.com/partners/portal`

Gated. **Use the existing magic-link pattern** (`account_request.html` →
`account_link_sent.html` → `account_manage.html`): the partner enters their email, we mail a
signed one-time link, and they get a session cookie. No new password store, no password resets,
and it matches what customers already experience. If a simple shared password is preferred for
launch, gate the *static* program page that way and still use magic links for anything showing
partner-specific numbers.

Content, in priority order:

1. **Code and link** — `piperstitch.com/r/<CODE>`, one-click copy, the spoken code shown large,
   and a QR code. If they hold several codes, show each with its own click and conversion count.
2. **Bounty window** — days remaining of 120 as a countdown; once closed, progress toward the 25
   active referrals that reinstate it. This is the primary motivational surface — put it second.
3. **Earnings** — accrued, payable now, held below the $50 minimum, paid to date, and the next
   payout date stated explicitly.
4. **Referrals table** — one row per referred customer: signed up (date), status,
   **month N of 24**, earned to date. Showing remaining months is not decoration; it means month
   24 never arrives as a surprise that feels like a clawback.
5. **Statements** — per payout period, downloadable.
6. **Creative kit** — graphics, caption drafts, the screen recording, sample artwork, and the
   required FTC disclosure wording (§10.1) **at the top, not the bottom**.

**Never expose customer identity.** A referral row is a date, a status and a number. No names, no
emails, no company names. This is a privacy-policy obligation, not a preference.

---

## 8. Admin — `admin.piperstitch.com/admin/partners`

Add a Partners section to `admin_base.html` nav, alongside Promotions. Reuse
`promoter_detail.html` patterns rather than inventing new ones.

- **Applications queue** — review, approve (sets `tier`, `share_pct`, bounty window, creates the
  first code via the existing `create_promotion()`), or reject. Approval sends the welcome email
  with the portal link and creative kit.
- **Partner list** — status, tier, codes, clicks, referrals, active referrals, lifetime earned,
  payable now, window state, tax form on file. Bulk-set bounty windows for a cohort (§4.1).
- **Partner detail** — extend `promoter_detail.html`: the referral table with each customer's
  month N of 24, the full `promo_payouts` ledger including reversals, and the content log.
- **Ledger view** — filterable, CSV export, every row showing kind, rate, base and source invoice.
- **Payout run** — pick a period, preview per-partner payable totals, auto-exclude anyone below
  $50 or missing a tax form, record payments via the existing `record_promoter_payment()`,
  generate statements.
- **Compliance log** — CRUD over `partner_content`: URL, platform, disclosure present yes/no.
  This is the evidence that we monitored the network (§10.1).
- **Alerts** — self-referral attempts, attribution to inactive promoters, failed webhooks,
  conversion spikes.

---

## 9. Delivering the audience offer — 30-day trial and 10 proofs

The offer gives **more product, not a discount**. Both halves already have a mechanism; neither is
wired to promotion codes yet.

**Trial: 30 days instead of 14.** `web_access.py` (~line 162) computes
`until = now + timedelta(days=config.TRIAL_DAYS)` from the global config. Change it to take a
per-promotion override:

```
trial_days = promotion.trial_days if (promotion and promotion.trial_days) else config.TRIAL_DAYS
```

This requires the code to be captured **at trial start**, not only at checkout — today it is
applied at checkout. Add an optional promo field to the trial/verify step, resolve it the same way
as §5.2, and record a provisional redemption then. This is the one genuinely new plumbing in the
audience offer and it must not be skipped: the 30-day trial is the hook in every partner's post.

**Proofs: 10 instead of 3.** `customers.proofs_free_extra` already exists as an admin-grantable
column, and the allowance is `config.PROOFS_FREE_PROOFS + proofs_free_extra`. On redemption, set
`proofs_free_extra = max(existing, promotion.proofs_extra)` — `proofs_extra = 7` gives 10 total.
Use `max()` rather than `+=` so a re-applied code cannot stack.

**No price discount:** `percent_off = 0` on partner codes, which is why §3.2's validation change
is required.

---

## 10. Compliance

### 10.1 FTC — an obligation on us, not only on partners

The advertiser is responsible for what its network says.

- Embed disclosure wording in the agreement and show it above the creative kit. **Approved:**
  *"I get a commission if you subscribe through my link"*, *"Paid link"* adjacent to the link,
  *"#ad"*. **Explicitly inadequate per the FTC:** "affiliate link" alone, "commissionable link",
  "sp", "spon", "collab".
- Disclosure must be inside a video rather than only in the description, overlaid on a Story with
  time to read, and **repeated periodically during a livestream** — which is where much of this
  industry sells.
- Because the term is capped, the honest form is *"I earn a commission for up to two years on
  anyone who subscribes through my link."*
- **Approved claims:** it makes the decisions a digitizer would (stitch type, underlay, density,
  compensation, sew order); rules-based, not AI, so the same artwork gives the same file every
  time; seconds instead of a day waiting on an outsourced digitizer; every decision is shown and
  editable; $24/month instead of a thousand-dollar package; it flags problems before you hoop.
- **Forbidden claims:** "perfect every time", "never needs editing", "replaces a professional
  digitizer", named quality comparisons to Hatch/Embrilliance/Wilcom, any income claim for the
  viewer, calling it AI, and anything about a feature the partner has not used.
- `partner_content` (§4) is the monitoring evidence. Ship it.

### 10.2 Tax

- Collect **W-9** (US) or **W-8BEN** (non-US) after approval, before the first payout. A null
  `tax_form_received_at` must hard-block inclusion in a payout run.
- Issue **1099-NEC** to any US partner paid **$600+** in a calendar year. Several partners on the
  target list will cross this. Build the annual threshold report into the admin export now.
- Partners are independent contractors. Say so in the agreement.

### 10.3 Privacy

The portal exposes no customer identity (§7). Hash IPs in `referral_clicks`. The existing Privacy
Policy language about project access (`project_view.py`) is the right standard to match.

---

## 11. Build order

**Phase 0 — before any partner is recruited. The only launch blocker.**

Attribution cannot be applied retroactively. Every click that lands before this ships is revenue
we cannot pay out on and a relationship that starts with an apology.

- [ ] Schema migrations (§4)
- [ ] §3.1 per-customer attribution fix — **do this first, it is a live underpayment bug**
- [ ] §3.2 allow `percent_off = 0` and non-price perks
- [ ] `/r/<CODE>` redirect, signed `ps_ref` cookie, `?ref=` handling, `referral_clicks`
- [ ] Promo capture at **trial start**, not only checkout (§9)
- [ ] `stripe_events` idempotency guard on every existing and new webhook handler
- [ ] Admin: create a partner + code by hand (the existing pages mostly do this already)

**Phase 1 — before the first payout is due (~30 days after the first conversion)**
- [ ] 24-month term cap (§6.1 step 4)
- [ ] Signup bounty, 120-day window, reinstatement (§6.2, §6.3)
- [ ] Refund / dispute / early-cancel reversals (§6.4)
- [ ] `promoter_totals()` audited for negative rows; payable-vs-held split (§6.6)
- [ ] Trial-days and proofs-extra delivery (§9)

**Phase 2 — before the second cohort is recruited**
- [ ] Partner portal (§7)
- [ ] Public `/partners` page, calculator, application form, terms
- [ ] Admin partners section and application queue (§8)

**Phase 3**
- [ ] Payout runs and statements
- [ ] Tax forms and the 1099 threshold report
- [ ] Compliance log UI

---

## 12. Test cases

All must pass before real money moves. Use Stripe test clocks for elapsed time. Extend
`license-admin/tests/`.

**Attribution**
1. Link click → cookie → signup 89 days later → attributed. At 91 days → not attributed.
2. Cookie for promoter A, code for promoter B entered at signup → **B** wins (R8).
3. Tampered cookie signature → rejected.
4. Two different partners' links clicked before first payment → last touch wins.
5. Attribution locked at first payment → a later click does not move it.
6. Promoter's own email signs up on their own code → no redemption, admin alert (R10).
7. Code belonging to a suspended promoter → not attributed.

**Per-customer attribution — the §3.1 regression**
8. Customer subscribes with a partner code, then adds Proofs as a second subscription →
   **shares accrue on both invoices.** This test fails against today's code; it is the point.
9. A legacy redemption with only a subscription-level link still resolves.

**Term and commission**
10. First payment 1 Mar 2026 → term ends 1 Mar 2028. Invoice 28 Feb 2028 accrues; 2 Mar 2028
    does not (R3).
11. Cancel month 8, resubscribe month 14 → resumes, still ends at original month 24 (R4).
12. Legacy promotion with `commission_months = NULL` → unchanged, uncapped behaviour.
13. Mid-cycle Proofs upgrade producing a prorated invoice → share is a percentage of the actual
    invoice, not of $24 or $48 (R1).
14. Changing the program's headline rate does not alter existing promotions' `share_pct` (R2).

**Bounty**
15. First payment on day 119 of the window → awarded. Day 121 → not awarded (R5).
16. Trial starts inside the window, first payment after it closes → **no bounty** (R5).
17. Two referred customers in the window → two bounties; one customer → exactly one, ever (R5).
18. Reinstatement fires at 25 active; next conversion earns $15 even though the window closed (R7).
19. Active count later falls to 23 → reinstatement **persists** (R7).
19a. A reinstated partner displays as "Established partner" while `tier` still reads
    `founding` or `standard`, and their rate is unchanged (R7a).

**Reversals**
20. Full refund day 45 → recurring reversed in full **and** bounty reversed (R6).
21. Full refund day 75 → recurring reversed, bounty **retained** (R6).
22. 50% partial refund → recurring reversed by exactly half.
23. Chargeback treated identically to a refund.
24. After any reversal the original row's `share_cents` is unchanged, and
    `promoter_totals()` nets correctly (R11).

**Perks**
25. Signup with a partner code → trial is 30 days, not 14 (§9).
26. Signup with a partner code → allowance is 10 proofs, not 3 (§9).
27. Re-applying the same code does not stack `proofs_free_extra` (§9).
28. A `percent_off = 0` promotion is created without error and charges full price (§3.2).
29. An existing `direct` discount code still behaves exactly as before.

**Integrity**
30. The same `invoice.paid` event delivered three times → exactly one payout row (R12).
31. Invalid Stripe signature → 400, nothing written.
32. Partner at $43.20 payable → excluded from the run, rolls over.
33. Partner with no tax form → excluded regardless of balance (§10.2).

---

## 13. Decisions needed from Ashley before building

**13.1 — Gross or net of Stripe fees? Settle this first; the partner terms depend on it.**
The existing `record_share_for_payment()` computes the share on **net** — gross minus Stripe's
actual fee, falling back to `estimate_fee_cents()`. The partner offer as currently written implies
**gross** ("30% of everything your referral pays").

| | per $24/mo | per referral over 24mo | with Proofs |
|---|---|---|---|
| **Gross** (offer as written) | $7.20 | $187.80 | $360.60 |
| **Net** (code as built) | ≈$6.90 | ≈$180.60 | ≈$348 |

The difference is about $0.30 per referral per month. **Recommendation: switch promoter-kind
codes to gross.** "30% of what they pay" needs no footnote, and for a program whose entire selling
point is clarity and generosity, the plain sentence is worth more than $0.30 a month. It is a
small change to step 5 of §6.1. If you prefer net, the marketing page and agreement must say
*"30% of net revenue after payment processing fees"* and the advertised ceiling drops to ~$348.

**13.2 — Bounty window per partner or per cohort?** Schema supports both (§4.1). Brief assumes
per-partner at approval.

**13.3 — Portal auth:** magic link (recommended, already built) or a shared password.

**13.4 — Payout rail:** PayPal Payouts API, or keep recording manual payments through the existing
`record_promoter_payment()`. Manual is entirely reasonable at fifty partners and defers a real
integration.

**13.5 — Does `/r/<CODE>` land on the homepage or a partner-specific page?** A page that says
"Kathleen sent you — here's your 30-day trial and 10 proofs" will convert better, and it is the
natural place to set the cookie and pre-fill the code.

**13.6 — One code per partner or several?** The schema supports several. Per-channel codes
(`KATHLEEN-YT`, `KATHLEEN-FB`) give the partner useful data and cost nothing.

---

© PiperStitch LLC. All Rights Reserved.
