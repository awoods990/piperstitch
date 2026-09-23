# If everything is gone

This is the runbook for the bad day: Railway has lost the volumes, or the
account, or itself. It assumes nothing survives except the bucket and
what is in your password manager.

Read it once now, while nothing is wrong. The first time you follow it
should not be the first time you have read it.

---

## What exists, and where

| Copy | Holds | Where it lives | Made by |
|---|---|---|---|
| **Nightly service backups** | License Admin database; Proofs database **and every artifact** — renders, PDFs, Certificates of Approval | Your S3-compatible bucket (Backblaze B2, Cloudflare R2, AWS…) | Each service, ~03:00 and ~04:00 UTC, verified by reading back |
| **Weekly repository mirror** | All code, the marketing site, the videos, every commit and tag | Same bucket, `repository/` | GitHub Actions, Sundays |
| **GitHub** | The same code, live | github.com | Every push |
| **Stripe** | Customers, subscriptions, invoices, payouts | stripe.com | Continuously |
| **Your password manager** | The secrets below — *the one thing no backup can hold for you* | Wherever you keep it | You |

The bucket is the only place that holds all of our own data, and it is
deliberately on a different company from everything else.

## The secrets you must keep yourself

A perfect backup with none of these restores nothing. Keep them in your
password manager, not in the bucket and not on Railway:

- `PIPERSTITCH_LICENSE_PRIVATE_KEY` — signs licences. Without it every
  installed copy stops trusting us.
- `DOCUMENT_ENCRYPTION_KEY` — partners' tax forms are encrypted with it.
  **Without it those forms are unreadable in every backup you hold.**
- `SESSION_SECRET`, `REFERRAL_SECRET`, `WEB_API_KEY`, `CORE_API_KEY`,
  `INTAKE_API_KEY`, `ADMIN_PASSWORD_HASH`, `ADMIN_TOTP_SECRET`
- `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_MONTHLY`,
  `STRIPE_PRICE_PROOFS`
- `POSTMARK_API_TOKEN` (or the SMTP credentials)
- `BACKUP_ACCESS_KEY` / `BACKUP_SECRET_KEY` — and note that if these are
  lost *with* everything else, the bucket's own provider login is the way
  back in. Keep that login too.

Stripe, Postmark and the bucket can all issue new credentials if these
are lost. The licence key and the document key cannot be reissued —
losing them loses what they protect.

### Getting the list right

Each service can print the full list of variables it reads, names only:

```bash
cd license-admin && python scripts/env_checklist.py
```

It marks which are secrets and which two cannot be reissued. Work down it
once with your password manager open; that is the whole job.

### The names, for rebuilding DNS

If the domain has to be pointed somewhere new (GoDaddy → whichever host):

| Name | Points at |
|---|---|
| `www` | the site service |
| `app` | the engine + browser app |
| `admin` | License Admin |
| `proofs` | Proofs |
| apex `piperstitch.com` | forwards to `www` (path-preserving — see below) |
| `pm-bounces` | CNAME to `pm.mtasv.net` (Postmark's return path) |
| SPF `TXT` | `v=spf1 include:secureserver.net include:spf.mtasv.net -all` |
| DMARC `TXT` at `_dmarc` | `v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=...` |
| MX | Microsoft 365 |

## Restoring

### 1. Get the files

```bash
aws --endpoint-url "$BACKUP_ENDPOINT" s3 ls "s3://$BACKUP_BUCKET/license-admin/" --recursive | tail -5
aws --endpoint-url "$BACKUP_ENDPOINT" s3 cp "s3://$BACKUP_BUCKET/license-admin/2026/license-admin-2026-09-23-0300.tar.gz" .
aws --endpoint-url "$BACKUP_ENDPOINT" s3 cp "s3://$BACKUP_BUCKET/proofs/2026/proofs-2026-09-23-0400.tar.gz" .
tar xzf license-admin-*.tar.gz && tar xzf proofs-*.tar.gz
cat manifest.json          # what it should weigh, and how many artifacts it should hold
```

Check the database is whole before trusting it:

```bash
sqlite3 license_admin.sqlite3 "PRAGMA integrity_check; SELECT COUNT(*) FROM customers;"
```

### 2. Get the code

From GitHub if it is there. If it is not:

```bash
aws --endpoint-url "$BACKUP_ENDPOINT" s3 cp "s3://$BACKUP_BUCKET/repository/piperstitch-2026-09-21.bundle" .
git clone piperstitch-2026-09-21.bundle piperstitch
```

That clone contains every commit, the marketing site and the videos.

### 3. Stand the services up

Any host that runs a container will do; Railway is not special. For each
service, point it at the repository, attach a volume, and set the
variables from `DEPLOY.md` plus the secrets above.

- **license-admin** → volume at `/data`, put `license_admin.sqlite3`
  there as `/data/license_admin.db`
- **proofs** → volume at `/data`, put `proofs.sqlite3` there as
  `/data/proofs.db` and the unpacked `artifacts/` directory at
  `/data/artifacts`
- **app** (the engine) → no volume; it holds nothing
- **site** → static, no volume

### 4. Point the names at it

DNS at GoDaddy: `www`, `app`, `admin`, `proofs` to the new hosts, and the
apex to `www`. Certificates reissue themselves once the names resolve.

### 5. Tell Stripe where the webhook went

A new webhook endpoint at `https://admin.piperstitch.com/webhooks/stripe`
and its signing secret into `STRIPE_WEBHOOK_SECRET`. Until this is done
subscriptions still bill, but the mirror here stops updating — then run
`scripts/reconcile_stripe.py` to catch up.

### 6. Check it

- Sign in to the admin; the subscriber count should match the manifest.
- Open a partner's record; the tax form should open (this is where a
  missing `DOCUMENT_ENCRYPTION_KEY` shows itself).
- Open an old proof link; the render and the certificate should appear —
  that proves the artifacts came back, not just the rows.
- Send yourself a test email from Admin → Emails.

## Practising

Twice a year, and after any change to what is stored:

1. Download last night's archive.
2. Unpack it somewhere local and run the integrity check above.
3. Open one artifact file by hand.

Ten minutes. A backup nobody has ever restored is a belief, not a backup
— and the moment you need this you will not be in a state to debug it.
