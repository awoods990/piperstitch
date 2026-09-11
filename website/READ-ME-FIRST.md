# PiperStitch website — what this is and how to put it on GoDaddy

A complete, self-contained website, built from the same structure as the
amerus.ai site (same stylesheet skeleton, same PHP download gate, same
hosting assumptions) with PiperStitch's brand, copy, and a subscription
instead of a one-time licence. No frameworks, no build step, no tracking.

```
index.html                Homepage
how-it-works.html         Product tour — import, decide, engineer, check
formats.html              Supported machine formats, imports, hoops
pricing.html              Pricing + the embedded subscribe form (talks to license-admin)
faq.html                  Questions and answers (with FAQ schema for Google)
system-requirements.html  Mac hardware/OS specification
download.html             Registration form (gates the download)
terms.html                Terms and Conditions of Use  ← DRAFT, have counsel review
privacy-policy.html       Privacy Policy               ← DRAFT, have counsel review

register.php              Handles the registration form        ← needs PHP
thank-you.php             Post-registration page + download button
get.php                   Serves the .dmg, only after registration

styles.css                All styling for all pages
site.js                   Mobile menu, footer year, FAQ accordion, form errors
favicon.ico               Browser tab icon
.htaccess                 Apache settings (https, www, compression, caching, .dmg type)
robots.txt / sitemap.xml  Search-engine files
updates/                  The update feed the app polls — permanent URL
releases/                 Versioned .dmg files for existing subscribers (public)
assets/                   Logos and icons, web-optimized
downloads/                Put PiperStitch.dmg here — blocked from direct access
private/                  Registration records land here — blocked from the web
```

---

## How the download gate works

1. A visitor fills in the form on `download.html` and ticks three boxes:
   the Terms + Privacy Policy, the trial/subscription terms, and being 18+.
2. `register.php` validates it, appends a row to `private/registrations.csv`,
   emails you a copy, forwards the registration to the License Admin
   service (so a customer record exists before any subscription), and sets
   a session flag.
3. The visitor lands on `thank-you.php`, which offers the download.
4. `get.php` streams `downloads/PiperStitch.dmg` — only to someone with that
   session flag, or with a signed link from a License Admin reminder email
   — and tells License Admin the download actually happened.

`downloads/` and `private/` each carry an `.htaccess` that denies direct web
access. **Both depend on Apache honouring `.htaccess`** — true on GoDaddy's
Linux/cPanel hosting, which is what this is built for.

No credit card is requested anywhere in this flow. Subscribing happens on
`pricing.html`, whose form POSTs to the License Admin service's
`/api/checkout`, which sends the visitor to Stripe's hosted checkout.

---

## How the subscription flow works (the part that differs from Amerus)

```
pricing.html ──fetch──▶ license-admin /api/checkout ──▶ Stripe Checkout (subscription mode)
                                                              │ webhook
                                                              ▼
                        license-admin mirrors the subscription, emails "welcome — sign in with this email"
                                                              │
        PiperStitch app: Sign In → email → 6-digit code → device token + signed entitlement
                                                              │
        account page (admin.piperstitch.com/account): update card / invoices / sign out a Mac / cancel
```

There is no license key anywhere. The app is unlocked by signing in with
the subscribed email; License Admin decides, from the mirrored Stripe
state, whether to hand it a signed entitlement. See the main repo's
`LICENSING.md` for the full story.

---

## Putting it on GoDaddy cPanel

Same steps as the Amerus site:

1. GoDaddy → **My Products** → next to your hosting plan, **Manage** →
   **cPanel Admin** → **File Manager** → open **public_html**.
2. On your Mac, select everything *inside* the `website` folder (files and
   the `assets`, `downloads`, `private`, `releases`, `updates` folders) and
   compress it. Do **not** zip the outer folder.
3. Upload the `.zip`, extract it in `public_html`, delete the `.zip`.
4. **Settings → Show Hidden Files** — confirm `.htaccess`,
   `downloads/.htaccess`, `private/.htaccess` and `releases/.htaccess` all arrived.
5. Set PHP to 8.0 or newer (cPanel → *Select PHP Version*).
6. Visit your domain.

**Test the gate before announcing anything:** submit the form yourself,
confirm the email and the thank-you page, then open
`yourdomain.com/private/registrations.csv` and
`yourdomain.com/downloads/PiperStitch.dmg` directly. Both must be refused.

---

## Before you go live — checklist

1. **Secrets in the PHP files.** `register.php` lines 18–24 and `get.php`
   lines 18–20: set `$OWNER_EMAIL`, `$FROM_EMAIL` (an address on your own
   domain or mail is filtered as spam), `$LICENSE_ADMIN_URL`,
   `$LICENSE_ADMIN_API_KEY` (= `INTAKE_API_KEY` in license-admin's `.env`)
   and `$DOWNLOAD_LINK_SECRET` (= `DOWNLOAD_LINK_SECRET` there).
2. **The License Admin URL in `pricing.html`.** Near the bottom:
   `var LICENSE_ADMIN_BASE = "https://admin.piperstitch.com";` — set to
   wherever license-admin is actually deployed. The footer's "Manage
   subscription" links (`admin.piperstitch.com/account`) on every page must
   match too — search and replace `admin.piperstitch.com`.
3. **The download file.** Put the shipping disk image at
   `downloads/PiperStitch.dmg`. Until it is there, `get.php` shows a polite
   "not available yet" page.
4. **The domain.** `sitemap.xml`, `robots.txt`, `.htaccess` and the
   `og:`/`canonical` tags use `https://www.piperstitch.com/`. Replace if
   the real domain differs.
5. **Price, trial and device count.** The site says **$19/month**, a
   **14-day** trial, and **2 Macs**. These must match license-admin's
   `MONTHLY_PRICE_CENTS`, `TRIAL_DAYS` and `MAX_DEVICES`, and the app's
   `LicenseConfig.trialDays`. Change all together.
6. **Version.** Pages state version 0.1.0 — match the build you ship.
7. **Legal pages are drafts.** `terms.html` and `privacy-policy.html` were
   written for this launch and carry a visible "Draft for review" callout.
   Have counsel review them, then remove the callout (search `Draft for
   review` in both files). Governing law is set to Florida, matching Amerus.
8. **Gatekeeper.** The build is not yet signed/notarized; `download.html`
   and `thank-you.php` already include the right-click → Open step.
9. **Keep the registration list safe.** `private/registrations.csv` holds
   real names and email addresses.

---

## Shipping an update

PiperStitch checks a JSON file on this site to learn a new release exists.
The URL is compiled into every build and **can never change** for copies
already installed:

```
https://www.piperstitch.com/updates/piperstitch-mac.json
```

**Every release:** bump `CFBundleShortVersionString` in the main repo's
`Resources/Info.plist`, build with `Scripts/build_app_bundle.sh`, then
either use License Admin's **Updates** page (uploads the .dmg to
`releases/` and rewrites the feed over SFTP), or by hand: upload
`PiperStitch-<version>.dmg` to `public_html/releases/` and overwrite the
feed:

```json
{
  "latest_version": "0.2.0",
  "download_url": "https://www.piperstitch.com/releases/PiperStitch-0.2.0.dmg",
  "notes": "What changed, in a sentence."
}
```

`releases/` is public on purpose: a subscriber installing a bug fix should
never have to fill in the registration form again. The subscription is
enforced inside the app, not by the download.

---

## Notes on how it was built

- **Brand.** A shoreline palette: sky and sea-foam from the thread
  (`#2b86e8`, `#3fb5a8`), sand and shell from the sandpiper (`#fdfaf4`,
  `#d99a6a`), a touch of sun (`#f2a93b`), with navy (`#1f3f63`) as a text
  colour rather than a backdrop. Light everywhere — no dark bands; the
  hero and callout sections use the `.sky` class. Headings use the
  system rounded face (`ui-rounded`) for a friendlier feel. The stylesheet
  is structurally the Amerus one with the palette and mock replaced.
- **Logos.** Cut from `Logo/Primary Logo.png` and `Logo/Favicon.png`:
  background removed (outside only — the cream stitching inside the bird
  is preserved), resized; touch/OG icons on a linen square.
- **Images.** Every illustration is inline SVG or CSS.
- **Privacy of the site itself.** No analytics, no cookies beyond the PHP
  session that gates the download, no third-party requests from the pages
  themselves (the subscribe form calls your own License Admin service).
