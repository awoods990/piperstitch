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
nginx.conf / Dockerfile   How it's served (canonical www redirect, caching, /health)
updates/                  The Mac app's update feed — kept for the later Mac launch
assets/                   Logos and icons
```

## How sign-up works now

There is no download and no registration form. Every call to action goes
to **https://app.piperstitch.com/** — the visitor enters their email, a
six-digit code arrives, and that first sign-in starts the 14-day trial.
Subscribing happens inside the app (Settings → Account & billing) or from
`pricing.html`'s form, which creates a Stripe Checkout through License
Admin; either way it's the same account, keyed by email.

The Mac edition's download gate (`register.php`, `thank-you.php`,
`get.php`, `downloads/`, `private/`) was removed with the web launch and
is in git history (commit before "Point the marketing site at the web
app") if the Mac app launches later.
