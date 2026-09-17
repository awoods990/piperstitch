"""Every email PiperStitch sends, as editable templates, plus the drip
sequences: the trial series, the subscriber series, the Proofs series
(discovering it, trying it, subscribed to it), the lapsed-trial and
cancelled follow-ups, and the "we miss you" win-back. The admin edits
all of it at /admin/emails; the text below is only the starting point,
seeded into the database once and never written over an admin's edit.

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
    dict(key="proofs_welcome", name="Proofs welcome (subscription started)", description="Sent automatically the moment a PiperStitch Proofs subscription starts (Stripe webhook).",
         subject="PiperStitch Proofs is on — unlimited proofs from here",
         body="""Hi {first_name},

Thanks for subscribing to PiperStitch Proofs. Your free proofs are behind you and there's no limit from here: send as many proofs as your customers need, with the automatic reminders, texting and art-by-email all switched on.

Nothing changes for jobs already in flight — every link you've sent keeps working.

Your Proofs plan is {proofs_price} a month and renews automatically, separately from PiperStitch itself. Update your card, see invoices, or cancel any time from your account page.

If anything doesn't work, just reply to this email.""",
         cta_label="Open PiperStitch Proofs", cta_url="{proofs_url}", preheader="Your Proofs subscription is active.", placeholders=COMMON_PLACEHOLDERS + ", proofs_price, proofs_url"),
    dict(key="proofs_free_used_up", name="Free proofs used up", description="Sent automatically when the last included proof is sent without a Proofs subscription.",
         subject="That was your last included proof",
         body="""Hi {first_name},

The proof you just sent was the last of the {free_proofs} included with your PiperStitch account — so you've now seen the whole loop: the link, the approval on their phone, the certificate.

Nothing already sent is affected: every link keeps working, approvals in flight can finish, and your certificates stay downloadable.

To keep sending, add PiperStitch Proofs for {proofs_price} a month on the same account and the same bill. Open Proofs → Settings → Upgrade, and the next proof goes out as normal. Cancel any time.

If Proofs hasn't earned it yet, I'd like to know why — reply and tell me.""",
         cta_label="Add PiperStitch Proofs", cta_url="{proofs_url}", preheader="Your included proofs are used up — add Proofs to keep sending.", placeholders=COMMON_PLACEHOLDERS + ", free_proofs, proofs_price, proofs_url"),
    dict(key="sign_in_code", name="Sign-in code", description="The six-digit code, sent every time someone signs in. Keep {code} in it.",
         subject="{code} is your PiperStitch sign-in code",
         body="""Your PiperStitch sign-in code:

{code}

Enter it in PiperStitch{device} to finish signing in. The code expires in {code_minutes} minutes and only works once.{link_line}

If you didn't just try to sign in to PiperStitch, you can ignore this email — nothing happens without the code.""",
         cta_label="", cta_url="", preheader="{code} is your PiperStitch sign-in code.", placeholders="code, code_minutes, device, link_line, sign_in_url"),
    dict(key="signup_code", name="Sign-up code (free trial)", description="The six-digit code sent when someone starts their free trial from the website or the app's guided setup. Its link returns them to the setup step. Keep {code} in it.",
         subject="{code} — welcome to PiperStitch",
         body="""Welcome to PiperStitch! Here's the code that finishes creating your account:

{code}

Enter it on the setup screen you just left, and we'll carry on setting PiperStitch up for your business. The code expires in {code_minutes} minutes and only works once.{link_line}

Your free trial starts the moment you're in — no card, nothing to cancel.

If you didn't just start a PiperStitch free trial, you can ignore this email — nothing happens without the code.""",
         cta_label="", cta_url="", preheader="{code} finishes creating your PiperStitch account.", placeholders="code, code_minutes, device, link_line, sign_in_url"),
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
# after, then one tip every two weeks. Proofs: a discovery series for
# accounts that never chose it, a trial series for accounts trying it
# (chosen at sign-up, or a first proof sent), and a value note every
# three weeks for Proofs subscribers. Lapsed trial and cancelled
# subscriber each get a short follow-up. Win-back: one email after
# three quiet weeks, then quiet for two months. Which Proofs series a
# customer is in is decided by `proofs_sequences_check` from what they
# actually have and do, so nobody gets two of them at once.

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
        dict(delay_days=45, name="How are we doing?", subject="One question, thirty seconds",
             body="""Hi {first_name},

You've been subscribed for six weeks, which is long enough to have an opinion.

On a scale of 0 to 10, how likely are you to recommend PiperStitch to another embroiderer? Reply with the number — and, if you have a moment, the one thing that would move it up a point.

If it's a 9 or a 10 and you'd be willing to say so somewhere public, tell me and I'll send you a link. Reviews from working embroiderers are how people like you find us.

Either way, thank you for being here.""",
             cta_label="", cta_url=""),
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
        dict(delay_days=92, name="Know another embroiderer?", subject="Know someone who'd like PiperStitch?",
             body="""Hi {first_name},

Most people find PiperStitch because someone in a guild, a Facebook group or a shop down the road mentioned it.

If you know an embroiderer who's still paying per design or wrestling with software from 2009, forward them this: {site_url}. The trial is free, there's no card, and it takes seven minutes to set up.

And if you'd like a referral link that credits you when they subscribe, reply "referral" and I'll set one up.""",
             cta_label="", cta_url=""),
        dict(delay_days=99, name="Tell us what you'd like", subject="What should PiperStitch do next?",
             body="""Hi {first_name},

You've been stitching with PiperStitch for a few months now. What's the one thing you wish it did — a machine format, a font, a tool, a report?

Reply to this email. Short is fine. Every feature on the roadmap started as a note like that from someone using it every day.

Thank you for being part of this.""",
             cta_label="", cta_url=""),
    ]),
    dict(key="proofs_intro", name="Meet Proofs", description="For PiperStitch accounts (trial or subscribed) that didn't choose Proofs at sign-up and haven't sent a proof. Starts a few days in; stops the moment they send a proof or add Proofs.", steps=[
        dict(delay_days=0, name="The job doesn't end at the file", subject="Sewing for someone else? Send them a proof",
             body="""Hi {first_name},

You've got PiperStitch turning artwork into stitches. Here's the part most people don't know is in the box.

When a design is for someone else — a customer, the team, the neighbour's business — the job doesn't stall at the file. It stalls in the days between "can you do this?" and "yes, go ahead": the mockup, the questions, the week of silence, the "I thought it would be bigger."

PiperStitch Proofs closes that gap. Click Send to Proofs and they get one link, on their phone: the real stitches, the thread colours, the size on the garment, and an Approve button. No account for them. If they go quiet, it sends the reminder so you don't have to.

Three proofs are included with your account. The next design you make for someone else — send it as a proof and see.""",
             cta_label="Send your first proof", cta_url="{proofs_url}"),
        dict(delay_days=5, name="Approved from a parking lot", subject="What your customer sees",
             body="""Hi {first_name},

Here's what happens on the other end of a proof.

Your customer gets an email (or a text) from you — your shop name, your reply-to. They tap the link and see the design rendered from the actual stitch file, not a picture drawn next to it: visible stitch texture, thread colours, stitch count, size, where it sits on the garment.

Under it, three buttons: Approve, Request a change, Ask a question. Requesting a change lets them drop a note on the exact spot. Approving takes one tap and ten seconds, in a parking lot, between other things.

You get an email the moment they act, and every reply lands in your own inbox. There's nothing to set up — your name and reply-to came from the guided setup.

You still have your three included proofs. Try one on a real order.""",
             cta_label="Open Proofs", cta_url="{proofs_url}"),
        dict(delay_days=12, name="Stop eating reprints", subject="\u201cThat\u2019s not the blue I picked\u201d",
             body="""Hi {first_name},

Every embroiderer has eaten a reprint over a colour, a size or a placement the customer swears they never agreed to.

A Proofs approval is tied to one version, on one garment, at one size, in one placement. Change any of those and Proofs asks again instead of reusing the old yes. When they approve, a Certificate of Approval records who, when, from what device, the wording they agreed to, and a fingerprint of the exact file.

Most disputes never start, because the customer saw the real stitches before you sewed. The ones that do end when they see the certificate.

Three proofs are included with your account; after that it's {proofs_price} a month, on the same bill, cancel any time.""",
             cta_label="Send a proof", cta_url="{proofs_url}"),
        dict(delay_days=24, name="Your three proofs are waiting", subject="Three proofs, still unused",
             body="""Hi {first_name},

Your account still has its three included proofs. They don't expire, and they cost nothing — but they're only useful if you try one on a real job.

The whole thing takes about a minute: finish the design in PiperStitch, click Send to Proofs, check the garment and the note, send. Then watch what happens on the customer's end.

If proofing isn't part of how you work — if everything you sew is for you — ignore this and I'll stop mentioning it. Reply "just me" and the Proofs emails stop.""",
             cta_label="Try a proof", cta_url="{proofs_url}"),
    ]),
    dict(key="proofs_trial", name="Trying Proofs", description="For accounts using their included proofs without a Proofs subscription — chose both at sign-up, or sent a first proof. Shows the value of both together; stops when Proofs is added.", steps=[
        dict(delay_days=0, name="Your first proof", subject="Send your first proof today",
             body="""Hi {first_name},

You picked PiperStitch and Proofs together — good call. Here's the fastest way to see them work as one thing.

Take the next design that's for someone else. Digitize it as usual. When it looks right, click Send to Proofs (next to Download). The proof builds itself from the stitch file — render, thread stops, size on the garment — and you'll be looking at the job in Proofs with the design already attached. Check the garment, add a note, send.

Your customer gets one link on their phone. You get an email when they open it, and another when they approve.

Three proofs are included, so the first three orders are on us.""",
             cta_label="Open Proofs", cta_url="{proofs_url}"),
        dict(delay_days=3, name="The intake link", subject="Stop asking the same five questions",
             body="""Hi {first_name},

Every new order starts with the same questions: what garment, what colour, how big, where, how many, and can you send me the logo again.

In Proofs, send an intake link instead (or give customers your art@ address). They answer once, on a page with your name on it, and upload the artwork. It lands on the job with a readiness report — which tells you the logo has 3 mm text before you spend the evening digitizing it.

Then the proof, the approval, the certificate and the run ticket all follow from that one job. No retyping, no second platform.""",
             cta_label="Send an intake link", cta_url="{proofs_url}"),
        dict(delay_days=7, name="Reminders and the chase", subject="The customer who goes quiet",
             body="""Hi {first_name},

The most expensive customer isn't the one who says no. It's the one who says nothing for a week while the machine sits.

Proofs chases for you. Set how long they have to respond (the setup asked; Settings changes it) and it sends the reminder on schedule, under your name, with the link. You see on the board who's waiting on you and who's waiting on them. When they finally answer at 10pm on a Sunday, the approval is recorded and the run ticket is ready Monday morning.

If they said yes on the phone instead, record it on their behalf in one tap and the record says so.""",
             cta_label="See your board", cta_url="{proofs_url}"),
        dict(delay_days=11, name="Two products, one bill", subject="PiperStitch and Proofs together: what it costs, what it saves",
             body="""Hi {first_name},

A quick, honest summary as your trial winds down.

PiperStitch is {price} a month: unlimited digitizing, every format, every update. Proofs is {proofs_price} a month on top, on the same bill: unlimited proofs, intake links, reminders, certificates. Both cancel with one click; everything you've downloaded or had approved stays yours.

What it replaces: the per-design digitizing fee and the wait; the mockup in a drawing app; the follow-up texts; and, once in a while, the reprint you'd otherwise have eaten. Decorators put mockups and follow-up at a day and a half a week. If Proofs gives you back one evening a month, it's paid for itself several times over.

Subscribe to PiperStitch from Settings → Account & billing; add Proofs from inside Proofs → Settings. Or reply and tell me what's holding you back.""",
             cta_label="Subscribe", cta_url="{app_url}"),
        dict(delay_days=13, name="Last day, both products", subject="Last day of your trial — PiperStitch and Proofs",
             body="""Hi {first_name},

Your trial ends today. After today the PiperStitch editor locks until you subscribe; nothing is deleted, and every proof you've sent keeps working — links stay live, approvals in flight can finish, certificates stay downloadable.

To carry on with both: subscribe to PiperStitch ({price} a month) from Settings → Account & billing, then add Proofs ({proofs_price} a month) from Proofs → Settings. One account, one bill, cancel either any time.

Thank you for trying both. Whatever you decide, happy stitching.""",
             cta_label="Keep both", cta_url="{app_url}"),
    ]),
    dict(key="proofs_subscriber", name="Proofs subscriber series", description="For accounts subscribed to both PiperStitch and Proofs: one note every three weeks on getting more from Proofs. Stops if Proofs ends.", steps=[
        dict(delay_days=2, name="Getting the most from Proofs", subject="Three habits of shops that never chase",
             body="""Hi {first_name},

Welcome to Proofs, properly. Three habits that make it pay:

Start every order with the intake link (or your art@ address), so the artwork, the garment and the sizes arrive together and you never retype them.

Send the proof the same day you digitize. The readiness report is already on the job, the design attaches in one click, and a proof sent while the customer is still thinking about the order gets approved in hours, not days.

Let the reminders run. Set the response window once and stop checking. The board tells you who's waiting on whom.

I'll send one short note like this every three weeks. If there's something Proofs should do and doesn't, reply — that's how it gets built.""",
             cta_label="Open Proofs", cta_url="{proofs_url}"),
        dict(delay_days=23, name="Reorders", subject="The reorder that's exactly like last time",
             body="""Hi {first_name},

A repeat order is where the approval record earns its keep.

When the same customer comes back for the same design, Proofs reuses the approval if nothing changed — same version, same garment, same size, same placement — and asks for a fresh one-tap re-approval if anything did. No "I'm sure it's fine," no reprint because the polo colour changed and the thread didn't.

Open the old job, click Reorder, adjust what's different, send. The certificate on the new job cites the old one.""",
             cta_label="Find a repeat customer", cta_url="{proofs_url}"),
        dict(delay_days=44, name="The certificate, explained", subject="What's actually in a Certificate of Approval",
             body="""Hi {first_name},

You've been collecting them for a while; here's what a Certificate of Approval contains, in case you ever need to lean on one.

Who approved and when. The device and IP address they did it from. The exact wording they agreed to, as it appeared on their screen. Which version, on which garment, at what size, in which placement. And a fingerprint of the exact stitch file the proof was rendered from — so nobody can claim the file changed after they said yes.

They're downloadable from any job, forever, whether or not you're still subscribed. Most shops never need one. The ones that do are glad it's there.""",
             cta_label="Download a certificate", cta_url="{proofs_url}"),
        dict(delay_days=65, name="Art by email and text", subject="Let customers text you the logo",
             body="""Hi {first_name},

Customers send artwork however is easiest for them — usually a photo, by text, at night. Proofs meets them there.

Your art@ address turns any email into a job, with the attachments in the right place and a readiness report attached. With texting on, a customer can text a photo straight to a job. Either way you're looking at it on the board in the morning, already triaged, instead of hunting through your phone.

Settings → Art by email, and Settings → Texting.""",
             cta_label="Set up your art@ address", cta_url="{proofs_url}"),
        dict(delay_days=86, name="Approve on their behalf", subject="\u201cJust go ahead\u201d — recorded properly",
             body="""Hi {first_name},

Some customers will never tap a link. They call, they say "just go ahead," and they mean it.

Record it: open the job, Approve on their behalf, note how they told you (phone, in person, email) and, if you like, paste what they said. The proof moves to approved, the run ticket unlocks, and the certificate says plainly that you recorded it and how. It's an honest record — which is worth more than a silent assumption when the polo comes out and they've changed their mind.""",
             cta_label="Open Proofs", cta_url="{proofs_url}"),
        dict(delay_days=107, name="What should Proofs do next?", subject="What should Proofs do next?",
             body="""Hi {first_name},

You've been running orders through Proofs for a few months. What's the one thing you wish it did — a report, a message template, a garment, a step it should skip?

Reply to this email. Short is fine. The next piece — PiperStitch Clients: customers, quotes, deposits, reorders — is being built from exactly these notes.

Thank you for building your shop on this.""",
             cta_label="", cta_url=""),
    ]),
    dict(key="lapsed", name="Trial ended, not subscribed", description="For a trial that ended without a subscription. Two emails; stops if they subscribe.", steps=[
        dict(delay_days=2, name="What held you back?", subject="Your PiperStitch trial ended — what held you back?",
             body="""Hi {first_name},

Your free trial ended a couple of days ago and you didn't subscribe — which is fine, and I'd like to learn from it.

Was it a design that didn't come out right? A machine format we don't have? Not enough time to try it properly? The price? Reply with a sentence; I read every one, and more than a few features exist because of a reply like it.

If it was simply time: your saved projects are exactly where you left them, and subscribing from Settings → Account & billing picks up mid-project.""",
             cta_label="Pick up where you left off", cta_url="{app_url}"),
        dict(delay_days=30, name="What's changed", subject="What's new in PiperStitch since your trial",
             body="""Hi {first_name},

It's been a month since your trial, and PiperStitch has moved on — the digitizing engine improves from real sew-outs every week, and Proofs now sends your customers a stitch-accurate proof to approve from their phone.

If you'd like another look, reply and I'll extend your trial by a week. No card, no catch — it's easier to judge with your own artwork than from an email.""",
             cta_label="Open PiperStitch", cta_url="{app_url}"),
    ]),
    dict(key="cancelled", name="After cancelling", description="For a subscriber who cancelled: a why-ask the next day and a check-in a month after access ends. Stops if they resubscribe.", steps=[
        dict(delay_days=1, name="Why did you cancel?", subject="Sorry to see you go — one question",
             body="""Hi {first_name},

You've cancelled PiperStitch; access continues to the end of the period you've paid for, and every file you've downloaded is yours.

One question, if you'll indulge me: what was the reason? A design it got wrong, something it doesn't do, the price, or just not enough embroidery on the bench right now? A one-line reply helps more than you'd think.

If it was a specific design, use Send feedback on it before your access ends — those are how the engine gets fixed.""",
             cta_label="", cta_url=""),
        dict(delay_days=45, name="If things have changed", subject="Whenever you're ready, it's all still here",
             body="""Hi {first_name},

Just a note that your account, your saved projects and your settings are all still here. Resubscribe with the same email and everything picks up where it left off — including the seven-minute setup you already did.

If something specific sent you away, reply and tell me whether it's been fixed. Often it has.""",
             cta_label="Resubscribe", cta_url="{account_url}"),
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
        "proofs_price": f"${config.PROOFS_MONTHLY_PRICE_CENTS / 100:.0f}",
        "proofs_url": config.PROOFS_APP_URL,
        "free_proofs": config.PROOFS_FREE_PROOFS,
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


PROOFS_INTRO_AFTER_DAYS = 4
LAPSED_AFTER_DAYS = 2

# The three Proofs series are exclusive: an account is in at most one of
# them at a time, decided by what it has and does.
PROOFS_SERIES = ("proofs_intro", "proofs_trial", "proofs_subscriber")


def _chose_proofs_at_signup(customer_id: int) -> bool:
    """The guided setup records which products were picked; the web app
    saves that in the account's preferences."""
    import json
    row = db.get_preferences(customer_id)
    if row is None:
        return False
    try:
        prefs = json.loads(row["preferences"])
    except (TypeError, ValueError):
        return False
    products = ((prefs or {}).get("onboarding") or {}).get("products") or []
    return "proofs" in products


def _in_or_done(customer_id: int, sequence_key: str) -> bool:
    seq = db.get_sequence(sequence_key)
    return seq is not None and db.customer_in_sequence(customer_id, seq["id"])


def proofs_sequence_for(customer_id: int, *, now: Optional[datetime] = None) -> Optional[str]:
    """Which Proofs series this customer belongs in right now, or None.

    - subscribed to Proofs -> proofs_subscriber
    - using the included proofs (chose Proofs at sign-up, or has sent one)
      with PiperStitch access -> proofs_trial
    - PiperStitch access for PROOFS_INTRO_AFTER_DAYS or more, never chose
      Proofs and never sent one -> proofs_intro
    """
    from . import subscriptions
    now = now or _now()
    if subscriptions.validity_for(customer_id, now=now, product="proofs").entitled:
        return "proofs_subscriber"
    core = subscriptions.validity_for(customer_id, now=now, product="core")
    if not core.entitled:
        return None
    if _chose_proofs_at_signup(customer_id) or db.count_proofs_used(customer_id) > 0:
        return "proofs_trial"
    sub = db.best_subscription_for_customer(customer_id, "core")
    started = datetime.fromisoformat(((sub["current_period_start"] if sub else None) or _iso(now)).replace("Z", "+00:00"))
    if now - started >= timedelta(days=PROOFS_INTRO_AFTER_DAYS):
        return "proofs_intro"
    return None


def place_in_proofs_sequence(customer_id: int, *, now: Optional[datetime] = None) -> Optional[str]:
    """Moves the customer to the Proofs series they belong in: pending
    emails from the other two are skipped and the right one is enrolled
    (once). Called on the events that change the answer -- a proof sent,
    Proofs subscribed or ended, the setup finished -- and by the daily
    check for everyone else. Returns the series enrolled, if any."""
    now = now or _now()
    target = proofs_sequence_for(customer_id, now=now)
    for key in PROOFS_SERIES:
        if key != target:
            skip_pending(customer_id, key, "moved to another Proofs series" if target else "no longer applies")
    if target is None or _in_or_done(customer_id, target):
        return None
    return target if enroll(customer_id, target, start=now) else None


def proofs_sequences_check(*, now: Optional[datetime] = None) -> int:
    """Daily: every customer with PiperStitch access lands in the right
    Proofs series. Cheap enough to run every tick (one query per entitled
    customer, all local)."""
    now = now or _now()
    n = 0
    with db.connection() as conn:
        ids = [r[0] for r in conn.execute("SELECT DISTINCT customer_id FROM subscriptions WHERE status IN ('active','trialing','past_due','comp') AND product IN ('core','proofs')").fetchall()]
    for cid in ids:
        customer = db.get_customer(cid)
        if customer is None or customer["marketing_opt_out"]:
            continue
        if place_in_proofs_sequence(cid, now=now):
            n += 1
    return n


def lapsed_check(*, now: Optional[datetime] = None) -> int:
    """A web trial that ended LAPSED_AFTER_DAYS ago or more with no
    PiperStitch subscription since joins the lapsed series, once."""
    from . import subscriptions
    now = now or _now()
    seq = db.get_sequence("lapsed")
    if seq is None or not seq["active"]:
        return 0
    cutoff = _iso(now - timedelta(days=LAPSED_AFTER_DAYS))
    n = 0
    with db.connection() as conn:
        rows = conn.execute("SELECT customer_id, current_period_end FROM subscriptions WHERE source = 'manual' AND status = 'trialing' AND notes = ? AND current_period_end <= ?", ("Web free trial", cutoff)).fetchall()
    for row in rows:
        cid = row["customer_id"]
        if db.customer_in_sequence(cid, seq["id"]):
            continue
        customer = db.get_customer(cid)
        if customer is None or customer["marketing_opt_out"]:
            continue
        if subscriptions.validity_for(cid, now=now, product="core").entitled:
            continue
        ended = datetime.fromisoformat(row["current_period_end"].replace("Z", "+00:00"))
        n += 1 if enroll(cid, "lapsed", start=ended) else 0
    return n


def run_scheduled_work() -> dict:
    """Everything the background loop does each tick."""
    from . import finance
    result = {"sent": 0, "winback": 0, "proofs": 0, "lapsed": 0, "recurring": 0, "backfilled": 0}
    try:
        result["sent"] = process_due()
    except Exception as e:  # noqa: BLE001 - the loop must survive
        log.exception("Sequence processing failed: %s", e)
    try:
        result["winback"] = winback_check()
    except Exception as e:  # noqa: BLE001
        log.exception("Win-back check failed: %s", e)
    try:
        result["proofs"] = proofs_sequences_check()
    except Exception as e:  # noqa: BLE001
        log.exception("Proofs sequence check failed: %s", e)
    try:
        result["lapsed"] = lapsed_check()
    except Exception as e:  # noqa: BLE001
        log.exception("Lapsed-trial check failed: %s", e)
    try:
        result["backfilled"] = sum(backfill_existing_customers().values())
    except Exception as e:  # noqa: BLE001
        log.exception("Sequence backfill failed: %s", e)
    try:
        result["recurring"] = finance.materialize_recurring(through=finance.today())
    except Exception as e:  # noqa: BLE001
        log.exception("Recurring expense materialization failed: %s", e)
    return result
