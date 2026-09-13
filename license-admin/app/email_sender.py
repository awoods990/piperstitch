"""Outgoing email via plain SMTP — no third-party email API. Every
message this service sends goes through here, so the plain-text and HTML
halves always agree and a resend is byte-for-byte the original.

There is no "here is your license key" email in this service — the
subscription world has no key. What replaces it:
  - the welcome email after a subscription starts (sign in with this
    email inside the app),
  - the six-digit sign-in code the app asks for,
  - the magic link to the self-service account page,
  - a heads-up when a renewal charge fails, and when a cancellation is
    scheduled or complimentary access is granted.
"""

from __future__ import annotations

import smtplib
from email.message import EmailMessage
from typing import Optional

from . import config, email_branding


class EmailSendError(Exception):
    """Wraps any smtplib/socket failure with a plain message — callers
    catch this specifically so a failed send never masks a failed
    subscription update."""


def _send_smtp(msg: EmailMessage) -> None:
    """Despite the name, the one send path: Postmark's HTTP API when
    POSTMARK_API_TOKEN is set, plain SMTP otherwise -- or, in development,
    a file in EMAIL_OUTBOX_DIR."""
    if config.EMAIL_OUTBOX_DIR:
        import logging, time
        from pathlib import Path

        outbox = Path(config.EMAIL_OUTBOX_DIR)
        outbox.mkdir(parents=True, exist_ok=True)
        path = outbox / f"{time.strftime('%Y%m%d-%H%M%S')}-{int(time.time() * 1000) % 1000:03d}.eml"
        path.write_bytes(bytes(msg))
        logging.getLogger("license_admin").info("EMAIL_OUTBOX_DIR: wrote %s (%s -> %s)", path.name, msg["Subject"], msg["To"])
        return
    if config.POSTMARK_API_TOKEN:
        from . import email_postmark

        text_part = msg.get_body(preferencelist=("plain",))
        html_part = msg.get_body(preferencelist=("html",))
        attachments = [(part.get_filename(), part.get_payload(decode=True), part.get_content_type()) for part in msg.iter_attachments()]
        try:
            email_postmark.send_postmark_email(
                to_email=str(msg["To"]),
                subject=str(msg["Subject"]),
                text_body=text_part.get_content() if text_part else "",
                html_body=html_part.get_content() if html_part else "",
                reply_to=str(msg["Reply-To"]) if msg["Reply-To"] else "",
                attachments=attachments or None,
            )
        except email_postmark.PostmarkError as e:
            raise EmailSendError(str(e)) from e
        return
    try:
        if config.SMTP_USE_SSL:
            with smtplib.SMTP_SSL(config.SMTP_HOST, config.SMTP_PORT, timeout=15) as smtp:
                if config.SMTP_USERNAME:
                    smtp.login(config.SMTP_USERNAME, config.SMTP_PASSWORD)
                smtp.send_message(msg)
        else:
            with smtplib.SMTP(config.SMTP_HOST, config.SMTP_PORT, timeout=15) as smtp:
                smtp.starttls()
                if config.SMTP_USERNAME:
                    smtp.login(config.SMTP_USERNAME, config.SMTP_PASSWORD)
                smtp.send_message(msg)
    except (smtplib.SMTPException, OSError) as e:
        raise EmailSendError(str(e)) from e


def _compose(*, to_email: str, subject: str, body: str, html_body: str, reply_to: str = "") -> EmailMessage:
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = config.SMTP_FROM
    msg["To"] = to_email
    if reply_to or config.REPLY_TO_EMAIL:
        msg["Reply-To"] = reply_to or config.REPLY_TO_EMAIL
    msg.set_content(body)
    if html_body:
        msg.add_alternative(html_body, subtype="html")
    return msg


def _price() -> str:
    return f"${config.MONTHLY_PRICE_CENTS / 100:.0f}" if config.MONTHLY_PRICE_CENTS % 100 == 0 else f"${config.MONTHLY_PRICE_CENTS / 100:.2f}"


def send_welcome_email(*, to_email: str, customer_name: str) -> None:
    """After a subscription starts. There is nothing to paste: the app
    signs in with the same email address, and the code arrives by email."""
    body = f"""Hi {customer_name or 'there'},

Welcome to PiperStitch — your subscription is active.

There's no license key to enter. Open PiperStitch in your browser at {config.WEB_APP_URL} and sign in with this email address ({to_email}). We'll send a six-digit code to confirm it's you, and that's it — everything is unlocked.

Use it from any computer: your saved projects follow your account.

Your plan is {_price()} a month and renews automatically. Update your card, see invoices, or cancel any time from your account page — cancelling keeps PiperStitch working until the end of the period you've paid for.

If anything doesn't work, just reply to this email."""
    html = email_branding.render(
        body_text=body,
        cta_label="Open PiperStitch",
        cta_url=config.WEB_APP_URL,
        preheader="Your subscription is active — sign in with this email.",
    )
    _send_smtp(_compose(to_email=to_email, subject="Welcome to PiperStitch — you're all set", body=body, html_body=html))


def send_activation_code_email(*, to_email: str, code: str, device_name: str) -> None:
    body = f"""Your PiperStitch sign-in code:

{code}

Enter it in PiperStitch{(' on ' + device_name) if device_name and device_name != 'the web' else ''} to finish signing in. The code expires in {config.ACTIVATION_CODE_TTL_MINUTES} minutes and only works once.

If you didn't just try to sign in to PiperStitch, you can ignore this email — nothing happens without the code."""
    html = email_branding.render(body_text=body, preheader=f"{code} is your PiperStitch sign-in code.", footer_note="Sent because someone entered this address in PiperStitch's sign-in screen.")
    _send_smtp(_compose(to_email=to_email, subject=f"{code} is your PiperStitch sign-in code", body=body, html_body=html))


def send_account_link_email(*, to_email: str, url: str) -> None:
    body = f"""Here's your link to manage your PiperStitch subscription:

{url}

From there you can update your card, download invoices, or cancel. The link expires in {config.ACCOUNT_LINK_TTL_MINUTES} minutes and only works once.

If you didn't request this, you can ignore it."""
    html = email_branding.render(body_text=body.replace(url, "").replace("\n\n\n", "\n\n"), cta_label="Manage my subscription", cta_url=url, preheader="Your one-time link to manage your PiperStitch subscription.")
    _send_smtp(_compose(to_email=to_email, subject="Manage your PiperStitch subscription", body=body, html_body=html))


def send_payment_failed_email(*, to_email: str, customer_name: str, account_url: str) -> None:
    body = f"""Hi {customer_name or 'there'},

We couldn't renew your PiperStitch subscription — the card on file was declined.

Nothing has been switched off yet. Stripe will retry the charge over the next few days, and PiperStitch keeps working for {config.ENTITLEMENT_GRACE_DAYS} days past your renewal date. To keep using it beyond that, update your card from your account page (link below), and the retry will go through.

If you meant to cancel, there's nothing you need to do — the subscription will end on its own.

Questions? Just reply."""
    html = email_branding.render(body_text=body, cta_label="Update my card", cta_url=account_url, preheader="Your renewal didn't go through — update your card to keep PiperStitch.")
    _send_smtp(_compose(to_email=to_email, subject="Action needed: your PiperStitch renewal didn't go through", body=body, html_body=html))


def send_cancellation_scheduled_email(*, to_email: str, customer_name: str, ends_on: str, account_url: str) -> None:
    body = f"""Hi {customer_name or 'there'},

Your PiperStitch subscription is set to end on {ends_on}. You won't be charged again.

PiperStitch keeps working until then, and any embroidery files you've already downloaded are yours to keep — they're ordinary files on your computer.

Changed your mind? You can resume the subscription from your account page any time before {ends_on} and nothing is interrupted.

Thanks for stitching with us."""
    html = email_branding.render(body_text=body, cta_label="Resume my subscription", cta_url=account_url, preheader=f"Your subscription ends on {ends_on}.")
    _send_smtp(_compose(to_email=to_email, subject="Your PiperStitch subscription is scheduled to end", body=body, html_body=html))


def send_comp_email(*, to_email: str, customer_name: str, until: str, note: str = "") -> None:
    body = f"""Hi {customer_name or 'there'},

We've given you complimentary access to PiperStitch through {until} — nothing to pay.

Open PiperStitch at {config.WEB_APP_URL} and sign in with this email address ({to_email}). A six-digit code will arrive by email to confirm it's you.
{(chr(10) + note + chr(10)) if note else ''}
If anything doesn't work, just reply to this email."""
    html = email_branding.render(body_text=body, cta_label="Open PiperStitch", cta_url=config.WEB_APP_URL, preheader=f"Complimentary PiperStitch access through {until}.")
    _send_smtp(_compose(to_email=to_email, subject="Your complimentary PiperStitch access", body=body, html_body=html))


def send_feedback_received_email(*, to_email: str, customer_name: str) -> None:
    """Sent immediately when someone uses "Send feedback" in the web
    editor -- before anyone on our side has actually looked at it, so
    this promises review, not a fix."""
    body = f"""Hi {customer_name or 'there'},

Thanks for sending us that design — we've received the original artwork and the digitized result you sent, and someone on the PiperStitch team will look it over.

This is exactly how we improve the automatic digitizing itself: every submission helps us see where the algorithm is making good calls and where it isn't, so we can make tomorrow's PiperStitch better than today's.

There's nothing else for you to do. If we make a change because of what you sent, we'll follow up.

Thanks again for helping us make PiperStitch better."""
    html = email_branding.render(body_text=body, preheader="We received your design and will look it over.")
    _send_smtp(_compose(to_email=to_email, subject="Thanks for the feedback — we're on it", body=body, html_body=html))


def send_feedback_reviewed_email(*, to_email: str, customer_name: str, account_url: str) -> None:
    """Admin-triggered from the feedback submission's own page, once
    someone has actually looked at it (and, ideally, used it to make a
    real improvement)."""
    body = f"""Hi {customer_name or 'there'},

We've reviewed the design you sent us and used it to help improve PiperStitch's digitizing.

We'd love for you to try it again — open PiperStitch and give it another run. If anything still looks off, send us that one too; every real design like yours makes the engine a little better.

Thanks for helping us make PiperStitch better."""
    html = email_branding.render(body_text=body, cta_label="Open PiperStitch", cta_url=account_url, preheader="We used your feedback — come try PiperStitch again.")
    _send_smtp(_compose(to_email=to_email, subject="We used your feedback — come try PiperStitch again", body=body, html_body=html))


def send_plain_email(*, to_email: str, subject: str, body: str, html_body: str = "", reply_to: str = "") -> None:
    """A free-form email from the admin. Plain text is what the admin
    wrote; an HTML rendering of it is added as an alternative."""
    _send_smtp(_compose(to_email=to_email, subject=subject, body=body, html_body=html_body or email_branding.render(body_text=body), reply_to=reply_to))


def send_file_email(*, to_email: str, sender_name: str, sender_email: str, filename: str, data: bytes, message: str = "", design_name: str = "") -> None:
    """A customer sending an embroidery file to someone from inside the
    app (the web edition's Send button). From us, reply-to the customer,
    the file attached, their note in the body."""
    design = design_name or filename.rsplit(".", 1)[0]
    intro = f"{sender_name or sender_email} sent you an embroidery file from PiperStitch: {filename}."
    body = intro + (f"\n\nTheir note:\n\n{message.strip()}" if message.strip() else "") + f"""

Save the attached file and load it on your embroidery machine the way you normally would. Reply to this email to reach {sender_name or 'the sender'} directly.

PiperStitch turns any image into a machine-ready embroidery file in a browser — {config.WEB_APP_URL}"""
    html = email_branding.render(body_text=body, cta_label="Try PiperStitch free", cta_url=config.WEB_APP_URL, preheader=f"{design} — sent from PiperStitch",
                                 footer_note=f"Sent by {sender_email} using PiperStitch. Reply to reach them; we only carried the message.")
    msg = _compose(to_email=to_email, subject=f"{sender_name or sender_email} sent you an embroidery file: {filename}", body=body, html_body=html, reply_to=sender_email)
    msg.add_attachment(data, maintype="application", subtype="octet-stream", filename=filename)
    _send_smtp(msg)
