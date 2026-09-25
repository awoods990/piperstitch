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


def _send_smtp(msg: EmailMessage, *, stream: str = "") -> str:
    """Despite the name, the one send path: Postmark's HTTP API when
    POSTMARK_API_TOKEN is set, plain SMTP otherwise -- or, in development,
    a file in EMAIL_OUTBOX_DIR.

    Returns the provider's message id where there is one (Postmark), and an
    empty string otherwise. Opens and clicks are reported against that id
    later, so it is the only thread tying an event back to a send."""
    if config.EMAIL_OUTBOX_DIR:
        import logging, time
        from pathlib import Path

        outbox = Path(config.EMAIL_OUTBOX_DIR)
        outbox.mkdir(parents=True, exist_ok=True)
        path = outbox / f"{time.strftime('%Y%m%d-%H%M%S')}-{int(time.time() * 1000) % 1000:03d}.eml"
        path.write_bytes(bytes(msg))
        logging.getLogger("license_admin").info("EMAIL_OUTBOX_DIR: wrote %s (%s -> %s)", path.name, msg["Subject"], msg["To"])
        return ""
    if config.POSTMARK_API_TOKEN:
        from . import email_postmark

        text_part = msg.get_body(preferencelist=("plain",))
        html_part = msg.get_body(preferencelist=("html",))
        attachments = [(part.get_filename(), part.get_payload(decode=True), part.get_content_type()) for part in msg.iter_attachments()]
        extra = [{"Name": name, "Value": str(msg[name])} for name in ("List-Unsubscribe", "List-Unsubscribe-Post") if msg[name]]
        try:
            return email_postmark.send_postmark_email(
                to_email=str(msg["To"]),
                subject=str(msg["Subject"]),
                text_body=text_part.get_content() if text_part else "",
                html_body=html_part.get_content() if html_part else "",
                reply_to=str(msg["Reply-To"]) if msg["Reply-To"] else "",
                attachments=attachments or None,
                stream=stream,
                headers=extra or None,
            )
        except email_postmark.PostmarkError as e:
            raise EmailSendError(str(e)) from e
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
    return ""                       # plain SMTP reports nothing back to tie events to


def _compose(*, to_email: str, subject: str, body: str, html_body: str, reply_to: str = "", unsubscribe_url: str = "") -> EmailMessage:
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = config.SMTP_FROM
    msg["To"] = to_email
    if reply_to or config.REPLY_TO_EMAIL:
        msg["Reply-To"] = reply_to or config.REPLY_TO_EMAIL
    if unsubscribe_url:
        # Gmail and Yahoo expect these on bulk mail, and a Broadcast stream
        # requires a way out. One-Click means the reader's client can stop it
        # without opening anything, which is the difference between an
        # unsubscribe and a spam complaint.
        msg["List-Unsubscribe"] = f"<{unsubscribe_url}>"
        msg["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    msg.set_content(body)
    if html_body:
        msg.add_alternative(html_body, subtype="html")
    return msg


def _price() -> str:
    return f"${config.MONTHLY_PRICE_CENTS / 100:.0f}" if config.MONTHLY_PRICE_CENTS % 100 == 0 else f"${config.MONTHLY_PRICE_CENTS / 100:.2f}"


def _emails():
    from . import emails  # late import: emails.py uses _compose/_send_smtp from here
    return emails


def _customer_id(to_email: str):
    from . import db
    row = db.get_customer_by_email(to_email)
    return row["id"] if row else None


def send_welcome_email(*, to_email: str, customer_name: str) -> None:
    """After a subscription starts. There is nothing to paste: the app
    signs in with the same email address, and the code arrives by email."""
    e = _emails()
    e.send_system("welcome", to_email=to_email, customer_id=_customer_id(to_email), vars=e.variables({"name": customer_name, "email": to_email, "id": _customer_id(to_email) or 0}))


def send_proofs_welcome_email(*, to_email: str, customer_name: str) -> None:
    """After a PiperStitch Proofs subscription starts."""
    e = _emails()
    e.send_system("proofs_welcome", to_email=to_email, customer_id=_customer_id(to_email), vars=e.variables({"name": customer_name, "email": to_email, "id": _customer_id(to_email) or 0}))


def send_activation_code_email(*, to_email: str, code: str, device_name: str, sign_in_url: Optional[str] = None, signup: bool = False) -> None:
    """`sign_in_url` (web sign-in only) carries the code right in the
    link, so clicking it on the device signs it in without retyping.
    `signup` sends the free-trial version instead (the "signup_code"
    template): different words, and a link that returns to the guided
    setup step the visitor left rather than dropping them into the app."""
    e = _emails()
    link_line = (f"\n\nOr open this link on the device you're setting up on and skip typing it: {sign_in_url}" if signup
                 else f"\n\nOr open this link on the device you're signing in on and skip typing it: {sign_in_url}") if sign_in_url else ""
    device = (" on " + device_name) if device_name and device_name != "the web" else ""
    vars = e.variables(None, code=code, code_minutes=config.ACTIVATION_CODE_TTL_MINUTES, device=device, link_line=link_line, sign_in_url=sign_in_url or "")
    from . import db
    key = "signup_code" if signup else "sign_in_code"
    row = db.get_email_template(key)
    if row is None:
        e.seed(); row = db.get_email_template(key)
    subject, body, _ = e.render_template(row, vars)
    html = email_branding.render(body_text=body, preheader=e.fill(row["preheader"], vars),
                                 footer_note="Sent because someone started a PiperStitch free trial with this address." if signup else "Sent because someone entered this address in PiperStitch's sign-in screen.",
                                 cta_label=("Continue setting up" if signup else "Sign in instantly") if sign_in_url else "", cta_url=sign_in_url or "")
    _send_smtp(_compose(to_email=to_email, subject=subject, body=body, html_body=html))


def send_account_link_email(*, to_email: str, url: str) -> None:
    e = _emails()
    e.send_system("account_link", to_email=to_email, customer_id=_customer_id(to_email), vars=e.variables(None, url=url, link_minutes=config.ACCOUNT_LINK_TTL_MINUTES))


def send_payment_failed_email(*, to_email: str, customer_name: str, account_url: str) -> None:
    e = _emails()
    cid = _customer_id(to_email)
    e.send_system("payment_failed", to_email=to_email, customer_id=cid, vars=e.variables({"name": customer_name, "email": to_email, "id": cid or 0}, account_url=account_url, grace_days=config.ENTITLEMENT_GRACE_DAYS))


def send_cancellation_scheduled_email(*, to_email: str, customer_name: str, ends_on: str, account_url: str) -> None:
    e = _emails()
    cid = _customer_id(to_email)
    e.send_system("cancellation_scheduled", to_email=to_email, customer_id=cid, vars=e.variables({"name": customer_name, "email": to_email, "id": cid or 0}, ends_on=ends_on, account_url=account_url))


def send_comp_email(*, to_email: str, customer_name: str, until: str, note: str = "") -> None:
    e = _emails()
    cid = _customer_id(to_email)
    e.send_system("comp_granted", to_email=to_email, customer_id=cid, vars=e.variables({"name": customer_name, "email": to_email, "id": cid or 0}, until=until, note=(chr(10) + note + chr(10)) if note else ""))


def send_partner_reinstated_email(*, to_email: str, partner_name: str) -> None:
    """R7: the signup bounty is back for good."""
    e = _emails()
    e.send_system("partner_reinstated", to_email=to_email, customer_id=None, vars=e.variables({"name": partner_name, "email": to_email, "id": 0}))


def _partner_vars(partner_name: str, to_email: str, **extra) -> dict:
    return _emails().variables({"name": partner_name, "email": to_email, "id": 0}, **extra)


def send_partner_link_email(*, to_email: str, partner_name: str, url: str) -> None:
    from . import partners
    _emails().send_system("partner_link", to_email=to_email, customer_id=None, vars=_partner_vars(partner_name, to_email, url=url, link_minutes=partners.LINK_TTL_MINUTES))


def send_partner_program_email(*, to_email: str, partner_name: str, url: str, invited: bool = False) -> None:
    """The gated program page's link -- on registration, or as our own
    invitation when we go to someone first."""
    from . import partners
    _emails().send_system("partner_invited" if invited else "partner_program", to_email=to_email, customer_id=None,
                          vars=_partner_vars(partner_name, to_email, url=url, link_days=partners.PROGRAM_TOKEN_DAYS))


#: The programme on one page, drawn rather than written. It leads the first
#: recruitment email and links straight to the full details.
PARTNER_INTRO_IMAGE = "/assets/partner-introduction-email.jpg"
#: Read instead of the picture by everyone whose client blocks images, which
#: on cold mail is most of them on first open -- so it carries the offer, not
#: a description of a picture.
PARTNER_INTRO_KICKER = "A New Way to Digitize and Proof"
PARTNER_INTRO_ALT = ("The PiperStitch Partner Program: get paid every month, for two years. "
                     "$15 the day they subscribe, then 30% of everything they pay for 24 months. "
                     "Founding rate locked for life for the first fifty partners.")


def send_partner_outreach_email(*, to_email: str, partner_name: str, key: str, url: str, apply_url: str, opt_out_url: str,
                                video_url: str = "", trial_url: str = "", join_url: str = "") -> tuple[str, str]:
    """One step of the recruitment sequence. Returns the subject line, for
    the outreach log, and the provider's message id, which is what a later
    open or click is reported against. Cold mail, so the opt-out rides in
    the footer as well as the body.

    The first step leads with the programme graphic, full width and linked
    to the details; the later steps are words alone."""
    from . import db
    e = _emails()
    vars = _partner_vars(partner_name, to_email, url=url, apply_url=apply_url, opt_out_url=opt_out_url,
                         video_url=video_url, join_url=join_url, trial_url=trial_url or f"{config.WEB_APP_URL}/?trial=1")
    row = db.get_email_template(key)
    if row is None:
        e.seed(); row = db.get_email_template(key)
    subject = e.fill(row["subject"], vars)
    lead = key == "partner_outreach_1"
    message_id = e.send_system(key, to_email=to_email, customer_id=None, vars=vars,
                  broadcast=True, unsubscribe_url=opt_out_url,
                  hero_image=f"{config.WEBSITE_BASE_URL}{PARTNER_INTRO_IMAGE}" if lead else "",
                  hero_alt=PARTNER_INTRO_ALT if lead else "", hero_url=url if lead else "", hero_full=lead,
                  hero_kicker=PARTNER_INTRO_KICKER if lead else "",
                  footer_note=f"You're getting this because we think you'd be a good PiperStitch partner. To hear no more: {opt_out_url}")
    return subject, message_id


def send_partner_kit_email(*, to_email: str, partner_name: str, title: str, description: str, url: str, kind: str = "video") -> None:
    _emails().send_system("partner_kit_item", to_email=to_email, customer_id=None,
                          vars=_partner_vars(partner_name, to_email, title=title, url=url, kind=kind,
                                             description_line=("\n\n" + description) if description else ""))


def send_partner_document_rejected_email(*, to_email: str, partner_name: str, note: str) -> None:
    _emails().send_system("partner_document_rejected", to_email=to_email, customer_id=None, vars=_partner_vars(partner_name, to_email, note=note or "It wasn't readable."))


def send_partner_applied_email(*, to_email: str, partner_name: str) -> None:
    _emails().send_system("partner_applied", to_email=to_email, customer_id=None, vars=_partner_vars(partner_name, to_email))


PIPER_CONGRATULATIONS = "/assets/piper-congratulations.png"


def send_partner_welcome_email(*, to_email: str, partner_name: str, code: str, link: str, portal_link: str, tier: str, share_pct: float) -> None:
    """Joining the team, with Piper's confetti at the top of it."""
    _emails().send_system("partner_welcome", to_email=to_email, customer_id=None,
                          hero_image=f"{config.WEBSITE_BASE_URL}{PIPER_CONGRATULATIONS}", hero_alt="Piper the sandpiper, mid-hop, with confetti",
                          vars=_partner_vars(partner_name, to_email, code=code, link=link, portal_link=portal_link, tier=tier, share_pct=f"{share_pct:g}"))


def send_partner_code_ready_email(*, to_email: str, partner_name: str, code: str, link: str, reason: str = "") -> None:
    _emails().send_system("partner_code_ready", to_email=to_email, customer_id=None, vars=_partner_vars(partner_name, to_email, code=code, link=link, reason=reason))


def send_partner_code_declined_email(*, to_email: str, partner_name: str, code: str, note: str) -> None:
    _emails().send_system("partner_code_declined", to_email=to_email, customer_id=None, vars=_partner_vars(partner_name, to_email, code=code, note=note))


def send_partner_paid_email(*, to_email: str, partner_name: str, amount: str, paid_at: str, method: str, payout_email: str, attachments=None) -> None:
    _emails().send_system("partner_paid", to_email=to_email, customer_id=None, attachments=attachments,
                          vars=_partner_vars(partner_name, to_email, amount=amount, paid_at=paid_at, method=("PayPal" if method == "paypal" else method), payout_email=payout_email or "your account"))


def send_partner_declined_email(*, to_email: str, partner_name: str) -> None:
    _emails().send_system("partner_declined", to_email=to_email, customer_id=None, vars=_partner_vars(partner_name, to_email))


def send_feedback_received_email(*, to_email: str, customer_name: str) -> None:
    e = _emails()
    cid = _customer_id(to_email)
    e.send_system("feedback_received", to_email=to_email, customer_id=cid, vars=e.variables({"name": customer_name, "email": to_email, "id": cid or 0}))


def send_feedback_reviewed_email(*, to_email: str, customer_name: str, account_url: str) -> None:
    e = _emails()
    cid = _customer_id(to_email)
    e.send_system("feedback_reviewed", to_email=to_email, customer_id=cid, vars=e.variables({"name": customer_name, "email": to_email, "id": cid or 0}, account_url=account_url, app_url=account_url))


def send_plain_email(*, to_email: str, subject: str, body: str, html_body: str = "", reply_to: str = "") -> None:
    """A free-form email from the admin. Plain text is what the admin
    wrote; an HTML rendering of it is added as an alternative."""
    _send_smtp(_compose(to_email=to_email, subject=subject, body=body, html_body=html_body or email_branding.render(body_text=body), reply_to=reply_to))


def send_file_email(*, to_email: str, sender_name: str, sender_email: str, filename: str, data: bytes, message: str = "", design_name: str = "") -> None:
    """A customer sending an embroidery file to someone from inside the
    app (the web edition's Send button). From us, reply-to the customer,
    the file attached, their note in the body."""
    e = _emails()
    note_block = f"\n\nTheir note:\n\n{message.strip()}" if message.strip() else ""
    vars = e.variables(None, sender_name=sender_name or sender_email, sender_email=sender_email, filename=filename, note_block=note_block)
    e.send_system("file_sent", to_email=to_email, customer_id=_customer_id(sender_email), vars=vars, reply_to=sender_email,
                  attachments=[(filename, data, "application/octet-stream")],
                  footer_note=f"Sent by {sender_email} using PiperStitch. Reply to reach them; we only carried the message.")
