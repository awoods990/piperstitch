# PiperStitch website — what this is and how it's published

The marketing site for the **web edition**: static HTML/CSS/JS, no build
step, no PHP. It is served by nginx from `website/Dockerfile` as the
**site** service on Railway and redeploys automatically on every push to
`main` (see the repo's `DEPLOY.md` → "Service: site"). Custom domains
`www.piperstitch.com` (CNAME) and `piperstitch.com` (forwarded to www).

```
index.html                Homepage
how-it-works.html         Product tour
formats.html              Machine formats, imports, hoops
technology.html           "Under the hood" — footer-linked only
pricing.html              Pricing; the subscribe form talks to License Admin's /api/checkout
faq.html                  FAQ (with FAQ schema)
system-requirements.html  "What you need" — a browser
download.html             "Start your free trial" — an email field that hands off to app.piperstitch.com/?email=
terms.html                Terms and Conditions   ← DRAFT, have counsel review
privacy-policy.html       Privacy Policy         ← DRAFT, have counsel review
styles.css / site.js      Styling; mobile menu, footer year, FAQ accordion
piper.js                  The sandpiper animation
track.js                  First-party analytics: one POST per page to License Admin
nginx.conf / Dockerfile   How it's served (canonical www redirect, caching, /health)
updates/                  The Mac app's update feed — kept for the later Mac launch
assets/                   Logos and icons
```

## Changing a versioned asset — read this first

`styles.css`, `piper.js` and `track.js` are referenced with a `?v=` query
and served with an hour of caching (`nginx.conf`). **Changing one of these
files without bumping its `?v=` in all twelve HTML pages means the change
does not reach anyone who has visited before** — their browser keeps the
old copy until it expires, and the deploy looks completely successful from
the server side.

```bash
# after editing track.js, piper.js or styles.css:
cd website && sed -i '' 's|track\.js?v=1|track.js?v=2|g' *.html
```

This is not hypothetical. A fix to `track.js` was deployed, verified as
present on the server, and still failed in a browser — because the browser
was running the cached previous version under the same `?v=`.

## How sign-up works now

There is no download and no registration form. Every call to action goes
to **https://app.piperstitch.com/** — the visitor enters their email, a
six-digit code arrives, and that first sign-in starts the trial -- 14
days normally, longer when they arrived through a partner's link or
code (the promotion carries its own `trial_days`; see `referrals.py`).
Subscribing happens inside the app (Settings → Account & billing) or from
`pricing.html`'s form, which creates a Stripe Checkout through License
Admin; either way it's the same account, keyed by email.

The Mac edition's download gate (`register.php`, `thank-you.php`,
`get.php`, `downloads/`, `private/`) was removed with the web launch and
is in git history (commit before "Point the marketing site at the web
app") if the Mac app launches later.
