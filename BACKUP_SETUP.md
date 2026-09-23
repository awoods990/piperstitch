# Turning the off-platform backups on

Twenty minutes, once. After this, both services copy themselves to
DigitalOcean every night, read the copy back to check it arrived, and
email you if it ever stops working. `RESTORE.md` is the other half: what
to do with those copies on the bad day.

---

## 1. Create the Space (5 minutes)

1. **cloud.digitalocean.com** → sign up. Use **contact@piperstitch.com**,
   not a personal address — this account holds a copy of everything, and
   it should outlive any one person's inbox.
2. Turn on **two-factor authentication** straight away
   (Settings → Security). This account is the one door to every copy of
   your data.
3. **Spaces Object Storage** → **Create a Spaces Bucket**.
   - Datacentre: **New York (nyc3)** — closest to Railway's US region.
   - Name: **piperstitch-backups** (must be unique across DigitalOcean;
     if it's taken, `piperstitch-backups-fl` or similar).
   - File listing: **Restrict** (private). It holds tax forms.
   - Leave CDN off.
4. **API** (left menu) → **Spaces Keys** → **Generate New Key**.
   Name it `piperstitch-backups`. You get a **key** and a **secret**, and
   the secret is shown **once** — put both in your password manager now.

Cost: $5/month for 250 GB. We will use well under a gigabyte, so that is
the whole bill.

## 2. Tell the two services (10 minutes)

In Railway, on **license-admin** → Variables, add:

```
BACKUP_ENDPOINT=https://nyc3.digitaloceanspaces.com
BACKUP_BUCKET=piperstitch-backups
BACKUP_REGION=nyc3
BACKUP_ACCESS_KEY=<the key>
BACKUP_SECRET_KEY=<the secret>
```

Then the same five on the **proofs** service. (If you chose a different
datacentre, both the endpoint and the region change to match it — `ams3`,
`fra1`, `sfo3`, and so on.)

Both services redeploy themselves when variables change.

## 3. Prove it, rather than hope (2 minutes)

Admin → **Security & backups** → **Back up now**.

It should come back with something like *"Backed up 0.4 MB to
piperstitch-backups, read back and checked."* If it doesn't, the message
says why. From a terminal you can get a fuller diagnosis:

```bash
cd license-admin && python scripts/check_backup.py
```

Then look in the Space: you should see `license-admin/2026/…tar.gz`, and
after Proofs' own run (or its next scheduled one) a `proofs/…` beside it.

## 4. The repository too (3 minutes)

So that losing GitHub costs nothing either:

**github.com/awoods990/piperstitch** → Settings → Secrets and variables →
Actions → New repository secret, four times:

| Name | Value |
|---|---|
| `BACKUP_ENDPOINT` | `https://nyc3.digitaloceanspaces.com` |
| `BACKUP_BUCKET` | `piperstitch-backups` |
| `BACKUP_REGION` | `nyc3` |
| `BACKUP_ACCESS_KEY` | the key |
| `BACKUP_SECRET_KEY` | the secret |

Then Actions → **offsite-backup** → **Run workflow** to test it now
rather than waiting for Sunday. It writes `repository/piperstitch-<date>.bundle`
— a complete clone of everything, verified before it finishes.

## 5. The two things no backup can replace

Put these in your password manager **today**, because they cannot be
reissued and everything else can:

- `PIPERSTITCH_LICENSE_PRIVATE_KEY` — lose it and every installed copy
  stops trusting us.
- `DOCUMENT_ENCRYPTION_KEY` — lose it and partners' tax forms are
  unreadable in every backup you hold.

Copy the rest of the variables from both Railway services in there too
while you are at it. A perfect backup with no credentials restores
nothing; `RESTORE.md` lists them all.

## What happens from then on

| When | What |
|---|---|
| ~03:00 UTC nightly | License Admin copies itself up, reads it back, checks the digest |
| ~04:00 UTC nightly | Proofs does the same, artifacts included |
| Sundays 04:30 UTC | The whole repository goes up as a git bundle |
| Kept | 30 nights, plus the first of each month for a year |
| If it fails | Email on the first, third and seventh night, and the admin says so |

Twice a year, download one and open it. Ten minutes, and it is the only
thing that turns a backup from a belief into a fact.
