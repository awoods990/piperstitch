"""Every email PiperStitch sends, as editable templates, plus the drip
sequences: the trial series, the subscriber series, and the "we miss
you" win-back. The admin edits all of it at /admin/emails; the text
below is only the starting point, seeded into the database once and
never written over an admin's edit.

Placeholders are written {like_this} and filled per customer. Sequence
emails carry an unsubscribe link (required for marketing email); sign-in
codes, receipts and billing notices are transactional and never affected
by an opt-out."""

from __future__ import annotations

import hashlib
import hmac
import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from . import config, db, email_branding, email_sender

log = logging.getLogger("license_admin")

COMMON_PLACEHOLDERS = "first_name, name, email, app_url, site_url, account_url, price, trial_days, unsubscribe_url"

# --------------------------------------------------------- system emails ---

SYSTEM_TEMPLATES: list[dict] = [
    dict(key="welcome", name="Welcome (subscription started)", description="Sent automatically the moment a paid subscription starts (Stripe webhook).",
         subject="Welcome to PiperStitch — you're all set",
         body="""Hi {first_name},

Welcome to PiperStitch — your subscription is active.

There's no license key to enter. Open PiperStitch in your browser at {app_url} and sign in with this email address ({email}). We'll send a six-digit code to confirm it's you, and that's it — everything is unlocked.

Use it from any computer: your saved projects follow your account.

Your plan is {price} a month and renews automatically. Update your card, see invoices, or cancel any time from your account page — cancelling keeps PiperStitch working until the end of the period you've paid for.

If anything doesn't work, just reply to this email.""",
         cta_label="Open PiperStitch", cta_url="{app_url}", preheader="Your subscription is active — sign in with this email.", placeholders=COMMON_PLACEHOLDERS),
    dict(key="sign_in_code", name="Sign-in code", description="The six-digit code, sent every time someone signs in. Keep {code} in it.",
         subject="{code} is your PiperStitch sign-in code",
         body="""Your PiperStitch sign-in code:

{code}

Enter it in PiperStitch{device} to finish signing in. The code expires in {code_minutes} minutes and only works once.{link_line}

If you didn't just try to sign in to PiperStitch, you can ignore this email — nothing happens without the code.""",
         cta_label="", cta_url="", preheader="{code} is your PiperStitch sign-in code.", placeholders="code, code_minutes, device, link_line, sign_in_url"),
    dict(key="account_link", name="Account page link", description="The one-time link to the customer's account page (card, invoices, cancel).",
         subject="Manage your PiperStitch subscription",
         body="""Here's your link to manage your PiperStitch subscription:

{url}

From there you can update your card, download invoices, or cancel. The link expires in {link_minutes} minutes and only works once.

If you didn't request this, you can ignore it.""",
         cta_label="Manage my subscription", cta_url="{url}", preheader="Your one-time link to manage your PiperStitch subscription.", placeholders="url, link_minutes"),
    dict(key="payment_failed", name="Renewal payment failed", description="Sent when Stripe reports a failed renewal charge.",
         subject="Action needed: your PiperStitch renewal didn't go through",
         body="""Hi {first_name},

We couldn't renew your PiperStitch subscription — the card on file was declined.

Nothing has been switched off yet. Stripe will retry the charge over the next few days, and PiperStitch keeps working for {grace_days} days past your renewal date. To keep using it beyond that, update your card from your account page (link below), and the retry will go through.

If you meant to cancel, there's nothing you need to do — the subscription will end on its own.

Questions? Just reply.""",
         cta_label="Update my card", cta_url="{account_url}", preheader="Your renewal didn't go through — update your card to keep PiperStitch.", placeholders=COMMON_PLACEHOLDERS + ", grace_days"),
    dict(key="cancellation_scheduled", name="Cancellation scheduled", description="Sent when a customer cancels (access continues to the period end).",
         subject="Your PiperStitch subscription is scheduled to end",
         body="""Hi {first_name},

Your PiperStitch subscription is set to end on {ends_on}. You won't be charged again.

PiperStitch keeps working until then, and any embroidery files you've already downloaded are yours to keep — they're ordinary files on your computer.

Changed your mind? You can resume the subscription from your account page any time before {ends_on} and nothing is interrupted.

Thanks for stitching with us.""",
         cta_label="Resume my subscription", cta_url="{account_url}", preheader="Your subscription ends on {ends_on}.", placeholders=COMMON_PLACEHOLDERS + ", ends_on"),
    dict(key="comp_granted", name="Complimentary access granted", description="Sent when the admin grants complimentary access.",
         subject="Your complimentary PiperStitch access",
         body="""Hi {first_name},

We've given you complimentary access to PiperStitch through {until} — nothing to pay.

Open PiperStitch at {app_url} and sign in with this email address ({email}). A six-digit code will arrive by email to confirm it's you.
{note}
If anything doesn't work, just reply to this email.""",
         cta_label="Open PiperStitch", cta_url="{app_url}", preheader="Complimentary PiperStitch access through {until}.", placeholders=COMMON_PLACEHOLDERS + ", until, note"),
    dict(key="feedback_received", name="Feedback received", description="Sent right after someone uses Send feedback in the editor.",
         subject="Thanks for the feedback — we're on it",
         body="""Hi {first_name},

Thanks for sending us that design — we've received the original artwork and the digitized result you sent, and someone on the PiperStitch team will look it over.

This is exactly how we improve the automatic digitizing itself: every submission helps us see where the algorithm is making good calls and where it isn't, so we can make tomorrow's PiperStitch better than today's.

There's nothing else for you to do. If we make a change because of what you sent, we'll follow up.

Thanks again for helping us make PiperStitch better.""",
         cta_label="", cta_url="", preheader="We received your design and will look it over.", placeholders=COMMON_PLACEHOLDERS),
    dict(key="feedback_reviewed", name="Feedback reviewed", description="Sent by the admin from a feedback submission once it's been looked at.",
         subject="We used your feedback — come try PiperStitch again",
         body="""Hi {first_name},

We've reviewed the design you sent us and used it to help improve PiperStitch's digitizing.

We'd love for you to try it again — open PiperStitch and give it another run. If anything still looks off, send us that one too; every real design like yours makes the engine a little better.

Thanks for helping us make PiperStitch better.""",
         cta_label="Open PiperStitch", cta_url="{app_url}", preheader="We used your feedback — come try PiperStitch again.", placeholders=COMMON_PLACEHOLDERS),
    dict(key="unsubscribe_confirmed", name="Unsubscribed from tips (confirmation)", description="Sent when someone clicks the unsubscribe link in a tip email. Makes clear their subscription is unchanged.",
         subject="You're unsubscribed from PiperStitch tips — your subscription is unchanged",
         body="""Hi {first_name},

Done — we've stopped the tip and check-in emails to {email}.

One thing to be clear about: this only stops the tips. It does not cancel your PiperStitch subscription. If you're subscribed, it continues exactly as before, and you'll still get the emails the app needs — sign-in codes, receipts and billing notices.

If you did mean to cancel the subscription itself, that's done from your account page (link below): update your card, see invoices, or cancel — access continues to the end of the period you've paid for.

Changed your mind about the tips? Reply to this email and we'll switch them back on.""",
         cta_label="Manage my subscription", cta_url="{account_url}", preheader="Tips stopped. Your subscription itself is unchanged.", placeholders=COMMON_PLACEHOLDERS),
    dict(key="file_sent", name="Embroidery file sent to someone", description="The email a recipient gets when a customer uses Send. The file is attached automatically.",
         subject="{sender_name} sent you an embroidery file: {filename}",
         body="""{sender_name} sent you an embroidery file from PiperStitch: {filename}.{note_block}

Save the attached file and load it on your embroidery machine the way you normally would. Reply to this email to reach {sender_name} directly.

PiperStitch turns any image into a machine-ready embroidery file in a browser — {app_url}""",
         cta_label="Try PiperStitch free", cta_url="{app_url}", preheader="{filename} — sent from PiperStitch", placeholders="sender_name, sender_email, filename, note_block, app_url"),
]

# ------------------------------------------------------------ sequences ---
# Short, one idea each, one button. Trial: seven touches across the 14
# days (the norm for a two-week trial). Subscriber: a welcome the day
# after, then one tip every two weeks. Win-back: one email after three
# quiet weeks, then quiet for two months.

SEQUENCES: list[dict] = [
    dict(key="trial", name="Free trial series", description="For new accounts during the 14-day trial. Stops the moment they subscribe.", steps=[
        dict(delay_days=0, name="Welcome to your trial", subject="Welcome to PiperStitch — your first design in five minutes",
             body="""Hi {first_name},

Welcome to PiperStitch. Your free trial is running — every feature, for {trial_days} days, no card.

The fastest way to see what it does: drop in a logo, answer the five quick questions (where it's going, how big, which hoop, what fabric, how many colours), and watch it digitize. You'll have a file your machine can sew before the kettle boils.

A tip for the first one: pick a clean logo with flat colours on a plain background. That's what embroidery loves, and it's where PiperStitch shines.

I'm a real person and I read replies — if anything is confusing, tell me.""",
             cta_label="Open PiperStitch", cta_url="{app_url}"),
        dict(delay_days=1, name="Read the readiness report", subject="What the 94/100 means",
             body="""Hi {first_name},

After every digitize, PiperStitch shows a readiness score in the bottom corner. It isn't decoration — it's the checks an experienced digitizer runs before threading a needle: satin columns too wide to hold, detail too fine to survive, jumps that should be trims, a design that won't fit the hoop.

Hover the badge to see each issue in plain English. Most fixes are one click: a bigger finished size, a different stitch type on one object, or merging two fragments into one shape.

Sew a test before a production run — that's true of any digitizing, ours included.""",
             cta_label="Check a design", cta_url="{app_url}"),
        dict(delay_days=3, name="Size, hoop and fabric", subject="Why PiperStitch asks about fabric",
             body="""Hi {first_name},

Stretchy fabric pulls as it sews; stiff fabric barely moves. A design digitized for a twill jacket will pucker on a knit polo unless the pull compensation changes with it.

That's why the setup asks what it's going on. Pick the fabric and PiperStitch widens the shapes just enough to keep the finished size true — and shows you the number in the inspector if you want to tune it yourself.

The same goes for size: change the finished size later and the whole design regenerates from the artwork, not scaled stitches. Try the same logo at 5 cm and at 12 cm and compare the readiness scores.""",
             cta_label="Try a fabric change", cta_url="{app_url}"),
        dict(delay_days=5, name="Lettering", subject="Text that stays sharp at any size",
             body="""Hi {first_name},

Tracing an image of text can never be sharper than the image. That's why small lettering from a photo or a low-resolution logo comes out fuzzy in most tools.

PiperStitch's Add lettering builds letters from the font's own outlines — a dozen fonts, from bold sans-serifs to scripts — so a 6 mm word is as clean as a 60 mm one. Curve it along a ring for a badge, set the letter spacing, pick the thread colour, and each letter becomes its own object you can still edit.

If your artwork has text that traced badly: select those pieces, open Add lettering, tick "Replace selected", and type the words.""",
             cta_label="Add some lettering", cta_url="{app_url}"),
        dict(delay_days=7, name="Merge shapes, paint and erase", subject="The three tools that fix a stubborn import",
             body="""Hi {first_name},

Real artwork isn't always tidy. Three tools handle the awkward cases:

Merge shapes — a letter or detail that came in as several fragments. Drag a box around the pieces, click Merge shapes, and they become one outline with one stitch type.

Paint — draw in coverage that's missing. With an object selected, the stroke extends it; with nothing selected, it becomes a new shape.

Erase — draw over anything that shouldn't sew. It's removed from whatever it touches.

Every edit re-digitizes automatically, and Back undoes it. Fifteen seconds with these tools usually beats redrawing the artwork.""",
             cta_label="Open the editor", cta_url="{app_url}"),
        dict(delay_days=10, name="Your thread library", subject="Match colours to the threads you actually own",
             body="""Hi {first_name},

By default PiperStitch matches each colour in your artwork to a built-in palette. If you stitch with a particular brand — Madeira, Isacord, Sulky, Robison-Anton — you can tell it exactly which spools are on your rack.

Settings → Thread library: add each thread with its name and colour (the manufacturer's chart or the spool's hex value). From then on, imports snap to your inventory and every colour picker lists your threads first — so the file you download names spools you can reach for.

It's the difference between "close enough" and "that's the one".""",
             cta_label="Set up your threads", cta_url="{app_url}"),
        dict(delay_days=12, name="Two days left", subject="Your PiperStitch trial ends in two days",
             body="""Hi {first_name},

Your free trial ends the day after tomorrow.

If PiperStitch has earned a place on your bench, subscribing takes a minute: open Settings → Account & billing → Subscribe. It's {price} a month, renews automatically, cancels with one click, and every file you've downloaded is yours whether or not you continue.

If it hasn't — I'd genuinely like to know why. Reply and tell me what didn't work; it's how the next version gets better.""",
             cta_label="Subscribe", cta_url="{app_url}"),
        dict(delay_days=14, name="Last day", subject="Last day of your PiperStitch trial",
             body="""Hi {first_name},

Today is the last day of your free trial. After today the editor locks until you subscribe — nothing is deleted; your saved projects are waiting.

Subscribe from inside the app (Settings → Account & billing) for {price} a month, cancel any time.

Thank you for trying it. Whatever you decide, happy stitching.""",
             cta_label="Keep using PiperStitch", cta_url="{app_url}"),
    ]),
    dict(key="subscriber", name="Subscriber series", description="For paying subscribers: a welcome the day after subscribing, then a tip every two weeks.", steps=[
        dict(delay_days=1, name="Welcome to the family", subject="Welcome to the PiperStitch family",
             body="""Hi {first_name},

Thank you for subscribing — you're officially part of the PiperStitch family.

A few things now that you're in for the long haul: your projects save to your account (the Save button, top left), so you can pick a design back up from any computer. The Send button emails a finished file straight to a customer or a colleague. And Settings → Thread library lets you match colours to the threads you own.

Every couple of weeks I'll send one short note about something PiperStitch can do that you might not have found yet. And if you ever hit a design it gets wrong, use Send feedback — real designs are how the digitizing engine improves.

Happy stitching.""",
             cta_label="Open PiperStitch", cta_url="{app_url}"),
        dict(delay_days=15, name="Density and push past normal limits", subject="A tip: when to change density (and when not to)",
             body="""Hi {first_name},

The default satin density (0.32 mm) suits most 40-weight thread on most fabrics. Two cases where changing it helps:

Thin stretchy fabric — go a touch lighter (0.36–0.40 mm) so the fill doesn't stiffen the garment.

Caps and dense twill — go a touch tighter for full coverage.

In the inspector, the project-wide sliders change every satin or fill object at once; select one object to tune just that one. "Push past normal limits" unlocks the sliders to the engine's floor for special jobs — test on a scrap first.""",
             cta_label="Try it", cta_url="{app_url}"),
        dict(delay_days=29, name="Placement presets", subject="A tip: the standard sizes are built in",
             body="""Hi {first_name},

Left chest, polo chest, youth chest, sleeve, cap front, full back — the industry standard sizes are in the setup questions and in the Finished size panel as one-click chips.

Pick "Cap / Hat Front" and PiperStitch also pre-selects a structured cap as the fabric, because a buckram front pulls differently from a knit. Change your mind later and the design regenerates from the artwork at the new size, with each object re-classified.""",
             cta_label="Open PiperStitch", cta_url="{app_url}"),
        dict(delay_days=43, name="Fill patterns and angles", subject="A tip: cross-hatch and fill angle",
             body="""Hi {first_name},

Large fills can show a faint directional sheen in one light. Two things in the inspector for a selected fill:

Fill pattern — Rows is the standard; Cross-hatch sews two passes at right angles for a lattice texture that hides the sheen; Basket weave is bolder still.

Fill angle — Automatic follows the shape; set it by hand to match a neighbouring object or the grain of a design.

Both regenerate the preview in a moment so you can compare.""",
             cta_label="Try a fill pattern", cta_url="{app_url}"),
        dict(delay_days=57, name="Merge colours", subject="A tip: fewer thread changes with Merge colours",
             body="""Hi {first_name},

An imported photo or gradient can produce more colours than the design needs — and every colour is a thread change on the machine.

Merge colours (toolbar) lists every colour in the design with how many objects use it. Tick the near-duplicates, pick the thread they should all become, and the design re-sequences with fewer changes. The readiness report will thank you.

Related: the Colour reduction setting in the inspector re-imports an image with fewer colours from the start.""",
             cta_label="Merge some colours", cta_url="{app_url}"),
        dict(delay_days=71, name="Appliqué", subject="A tip: appliqué in one checkbox",
             body="""Hi {first_name},

Select any object and tick Appliqué in the inspector. PiperStitch sews a placement outline (so you know where to lay the fabric), stops, sews a tack-down outline slightly inset, stops again, then sews the object's own satin or fill over the edge.

It's the standard three-pass appliqué, without setting up three objects by hand. Works best on a shape with a clean outline — a letter, a badge, a simple logo mark.""",
             cta_label="Try an appliqué", cta_url="{app_url}"),
        dict(delay_days=85, name="Sending files and saving projects", subject="A tip: Send, Save and Start over",
             body="""Hi {first_name},

Three small buttons worth knowing:

Send — emails the finished file to anyone, from us, with you as the reply-to. Handy for a customer approving a sample.

Save — keeps the project on your account so you can reopen it from any computer, edits and all.

Start over — throws away every edit and regenerates from the original artwork at the current size. Useful when an experiment went sideways.""",
             cta_label="Open PiperStitch", cta_url="{app_url}"),
        dict(delay_days=99, name="Tell us what you'd like", subject="What should PiperStitch do next?",
             body="""Hi {first_name},

You've been stitching with PiperStitch for a few months now. What's the one thing you wish it did — a machine format, a font, a tool, a report?

Reply to this email. Short is fine. Every feature on the roadmap started as a note like that from someone using it every day.

Thank you for being part of this.""",
             cta_label="", cta_url=""),
    ]),
    dict(key="winback", name="We're missing you", description="For a subscriber who hasn't signed in for three weeks. One email, then quiet for two months.", steps=[
        dict(delay_days=0, name="We're missing you", subject="We're missing you at PiperStitch",
             body="""Hi {first_name},

It's been a few weeks since you last opened PiperStitch, and I wanted to check in.

If you've simply been busy — your projects are exactly where you left them, and the editor's had a few improvements since your last visit.

If something got in the way — a design that didn't come out right, a machine format we don't have, anything at all — reply and tell me. That's the fastest way to get it fixed.""",
             cta_label="Pick up where you left off", cta_url="{app_url}"),
    ]),
]

WINBACK_INACTIVE_DAYS = 21
WINBACK_COOLDOWN_DAYS = 60


def seed() -> None:
    for t in SYSTEM_TEMPLATES:
        db.seed_email_template(**t)
    for seq in SEQUENCES:
        sequence_id = db.seed_sequence(key=seq["key"], name=seq["name"], description=seq["description"])
        if not db.sequence_has_steps(sequence_id):
            for step in seq["steps"]:
                db.add_sequence_step(sequence_id=sequence_id, **step)


# ------------------------------------------------------------- rendering ---


class _Safe(dict):
    def __missing__(self, key):
        return "{" + key + "}"


def _price() -> str:
    cents = config.MONTHLY_PRICE_CENTS
    return f"${cents / 100:.0f}" if cents % 100 == 0 else f"${cents / 100:.2f}"


def unsubscribe_token(customer_id: int) -> str:
    return hmac.new((config.SESSION_SECRET or "dev").encode(), f"unsubscribe:{customer_id}".encode(), hashlib.sha256).hexdigest()[:32]


def unsubscribe_url(customer_id: int) -> str:
    return f"{config.PUBLIC_BASE_URL}/unsubscribe?c={customer_id}&t={unsubscribe_token(customer_id)}"


def variables(customer=None, **extra) -> dict:
    name = (customer["name"] if customer else "") or ""
    v = {
        "name": name or "there",
        "first_name": (name.split(" ")[0] if name else "there"),
        "email": customer["email"] if customer else "",
        "app_url": config.WEB_APP_URL,
        "site_url": config.WEBSITE_BASE_URL,
        "account_url": f"{config.PUBLIC_BASE_URL}/account",
        "price": _price(),
        "trial_days": config.TRIAL_DAYS,
        "unsubscribe_url": unsubscribe_url(customer["id"]) if customer else "",
    }
    v.update(extra)
    return v


def fill(text: str, vars: dict) -> str:
    return (text or "").format_map(_Safe(vars))


def render_template(row, vars: dict, *, marketing: bool = False, footer_note: str = "") -> tuple[str, str, str]:
    """(subject, plain body, html) for a template or sequence-step row."""
    subject = fill(row["subject"], vars)
    body = fill(row["body"], vars)
    cta_label = fill(row["cta_label"] or "", vars)
    cta_url = fill(row["cta_url"] or "", vars)
    preheader = fill(row["preheader"] if "preheader" in row.keys() else "", vars)
    if marketing and vars.get("unsubscribe_url"):
        footer_note = footer_note or f"You're getting this because you have a PiperStitch account. Unsubscribe from tips: {vars['unsubscribe_url']}"
        body = body.rstrip() + f"\n\n—\nDon't want these tips? Unsubscribe: {vars['unsubscribe_url']}"
    html = email_branding.render(body_text=body, cta_label=cta_label, cta_url=cta_url, preheader=preheader, footer_note=footer_note)
    return subject, body, html


def send_system(key: str, *, to_email: str, customer_id: Optional[int] = None, vars: Optional[dict] = None, reply_to: str = "", attachments: Optional[list] = None, footer_note: str = "") -> None:
    """Sends one of the editable system emails. Raises EmailSendError on
    failure after logging it."""
    row = db.get_email_template(key)
    if row is None:
        seed(); row = db.get_email_template(key)
    subject, body, html = render_template(row, vars or {}, footer_note=footer_note)
    msg = email_sender._compose(to_email=to_email, subject=subject, body=body, html_body=html, reply_to=reply_to)
    for name, data, ctype in attachments or []:
        maintype, _, subtype = (ctype or "application/octet-stream").partition("/")
        msg.add_attachment(data, maintype=maintype, subtype=subtype or "octet-stream", filename=name)
    try:
        email_sender._send_smtp(msg)
    except email_sender.EmailSendError as e:
        db.log_email(customer_id=customer_id, to_email=to_email, kind=key, subject=subject, status="failed", error=str(e))
        raise
    db.log_email(customer_id=customer_id, to_email=to_email, kind=key, subject=subject, status="sent")


def preview(row, customer=None, **extra) -> tuple[str, str, str]:
    return render_template(row, variables(customer, **extra), marketing="delay_days" in row.keys())


# ------------------------------------------------------------- sequences ---


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds").replace("+00:00", "Z")


def enroll(customer_id: int, sequence_key: str, *, start: Optional[datetime] = None, force: bool = False) -> int:
    """Schedules every active step for this customer from `start`. A
    customer is enrolled in a sequence at most once unless forced."""
    seq = db.get_sequence(sequence_key)
    if seq is None:
        seed(); seq = db.get_sequence(sequence_key)
        if seq is None:
            return 0
    if not force and db.customer_in_sequence(customer_id, seq["id"]):
        return 0
    start = start or _now()
    n = 0
    for step in db.list_sequence_steps(seq["id"]):
        if not step["active"]:
            continue
        db.schedule_delivery(customer_id=customer_id, sequence_id=seq["id"], step_id=step["id"], scheduled_for=_iso(start + timedelta(days=int(step["delay_days"]))))
        n += 1
    if n:
        db.add_event(customer_id=customer_id, subscription_id=None, kind="sequence_enrolled", detail=f"Enrolled in the {seq['name']} ({n} emails scheduled).")
    return n


def enroll_from(customer_id: int, sequence_key: str, *, start: datetime, now: Optional[datetime] = None) -> int:
    """Enrol as of a start date in the past, without sending the steps
    that would already have gone: those are recorded as skipped ("before
    enrolment") so the record is complete and only future steps send."""
    n = enroll(customer_id, sequence_key, start=start)
    if not n:
        return 0
    now = now or _now()
    seq = db.get_sequence(sequence_key)
    with db.connection() as conn:
        conn.execute("UPDATE sequence_deliveries SET status = 'skipped', note = 'before enrolment' WHERE customer_id = ? AND sequence_id = ? AND status = 'scheduled' AND scheduled_for < ?",
                     (customer_id, seq["id"], _iso(now - timedelta(hours=12))))
    return n


def backfill_existing_customers() -> dict:
    """Run at startup: anyone already on a web trial or a live Stripe
    subscription who was never enrolled joins the right series from
    their real start date. Idempotent."""
    counts = {"trial": 0, "subscriber": 0}
    trial_seq, sub_seq = db.get_sequence("trial"), db.get_sequence("subscriber")
    if trial_seq is None or sub_seq is None:
        return counts
    with db.connection() as conn:
        trials = conn.execute("SELECT customer_id, current_period_start FROM subscriptions WHERE source = 'manual' AND status = 'trialing' AND notes = 'Web free trial' AND current_period_end > ?", (_iso(_now()),)).fetchall()
        subs = conn.execute("SELECT customer_id, created_at FROM subscriptions WHERE source = 'stripe' AND status IN ('active','trialing','past_due')").fetchall()
    for row in trials:
        cid = row["customer_id"]
        if db.customer_in_sequence(cid, trial_seq["id"]) or db.customer_in_sequence(cid, sub_seq["id"]):
            continue
        start = datetime.fromisoformat((row["current_period_start"] or _iso(_now())).replace("Z", "+00:00"))
        counts["trial"] += 1 if enroll_from(cid, "trial", start=start) else 0
    for row in subs:
        cid = row["customer_id"]
        if db.customer_in_sequence(cid, sub_seq["id"]):
            continue
        skip_pending(cid, "trial", "subscribed")
        start = datetime.fromisoformat((row["created_at"] or _iso(_now())).replace("Z", "+00:00"))
        counts["subscriber"] += 1 if enroll_from(cid, "subscriber", start=start) else 0
    return counts


def stop_all_marketing(customer_id: int, note: str) -> int:
    """Unsubscribed: every pending sequence email is cancelled now."""
    total = 0
    for seq in db.list_sequences():
        total += skip_pending(customer_id, seq["key"], note)
    return total


def skip_pending(customer_id: int, sequence_key: str, note: str) -> int:
    seq = db.get_sequence(sequence_key)
    if seq is None:
        return 0
    n = db.skip_scheduled_deliveries(customer_id, seq["id"], note)
    if n:
        db.add_event(customer_id=customer_id, subscription_id=None, kind="sequence_stopped", detail=f"{seq['name']}: {n} remaining email(s) skipped — {note}.")
    return n


def send_delivery(delivery_id: int, *, by: str) -> bool:
    """Sends one scheduled step now (the scheduler, or the admin's Send
    now). Returns True if it went."""
    d = db.get_delivery(delivery_id)
    if d is None:
        return False
    customer = db.get_customer(d["customer_id"])
    if customer is None:
        db.mark_delivery(delivery_id, status="skipped", note="customer deleted"); return False
    if customer["marketing_opt_out"]:
        db.mark_delivery(delivery_id, status="skipped", note="unsubscribed from tips"); return False
    if by == "auto" and (not d["step_active"] or not d["sequence_active"]):
        return False
    vars = variables(customer, trial_ends=_trial_ends(customer["id"]))
    subject, body, html = render_template(d, vars, marketing=True)
    msg = email_sender._compose(to_email=customer["email"], subject=subject, body=body, html_body=html)
    try:
        email_sender._send_smtp(msg)
    except email_sender.EmailSendError as e:
        db.mark_delivery(delivery_id, status="failed", sent_by=by, note=str(e))
        db.log_email(customer_id=customer["id"], to_email=customer["email"], kind=f"sequence:{d['sequence_key']}", subject=subject, status="failed", error=str(e))
        return False
    db.mark_delivery(delivery_id, status="sent", sent_by=by)
    db.log_email(customer_id=customer["id"], to_email=customer["email"], kind=f"sequence:{d['sequence_key']}", subject=subject, status="sent")
    db.add_event(customer_id=customer["id"], subscription_id=None, kind="sequence_email", detail=f"{d['sequence_name']} — “{d['step_name']}” sent{' by admin' if by == 'admin' else ''}.")
    return True


def _trial_ends(customer_id: int) -> str:
    sub = db.best_subscription_for_customer(customer_id)
    return (sub["current_period_end"] or "")[:10] if sub else ""


def process_due(*, now: Optional[datetime] = None) -> int:
    """The scheduler's tick: send everything that's due. Returns how many went."""
    sent = 0
    for row in db.list_due_deliveries(_iso(now or _now())):
        if send_delivery(row["id"], by="auto"):
            sent += 1
    return sent


def winback_check(*, now: Optional[datetime] = None) -> int:
    """Enrols quiet subscribers in the win-back (one email), at most once
    every WINBACK_COOLDOWN_DAYS."""
    now = now or _now()
    seq = db.get_sequence("winback")
    if seq is None or not seq["active"]:
        return 0
    cutoff = _iso(now - timedelta(days=WINBACK_INACTIVE_DAYS))
    n = 0
    for customer in db.inactive_subscribers(inactive_since_iso=cutoff):
        last = db.last_delivery_sent_at(customer["id"], seq["id"])
        if last and last > _iso(now - timedelta(days=WINBACK_COOLDOWN_DAYS)):
            continue
        if db.customer_in_sequence(customer["id"], seq["id"]) and not last:
            continue  # scheduled and not yet sent
        n += enroll(customer["id"], "winback", start=now, force=True)
    return n


def run_scheduled_work() -> dict:
    """Everything the background loop does each tick."""
    from . import finance
    result = {"sent": 0, "winback": 0, "recurring": 0, "backfilled": 0}
    try:
        result["sent"] = process_due()
    except Exception as e:  # noqa: BLE001 - the loop must survive
        log.exception("Sequence processing failed: %s", e)
    try:
        result["winback"] = winback_check()
    except Exception as e:  # noqa: BLE001
        log.exception("Win-back check failed: %s", e)
    try:
        result["backfilled"] = sum(backfill_existing_customers().values())
    except Exception as e:  # noqa: BLE001
        log.exception("Sequence backfill failed: %s", e)
    try:
        result["recurring"] = finance.materialize_recurring(through=finance.today())
    except Exception as e:  # noqa: BLE001
        log.exception("Recurring expense materialization failed: %s", e)
    return result
