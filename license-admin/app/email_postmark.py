"""Sends email via Postmark's HTTP API — the same service the Amerus
License Admin uses. Only used when POSTMARK_API_TOKEN is configured (see
config.py); otherwise everything goes out over plain SMTP.

Unlike Amerus, which routes only its marketing sequences through Postmark
and keeps license-key delivery on SMTP, PiperStitch sends *every* email
through whichever one transport is configured: all of its emails are
transactional (sign-in codes, welcome, failed renewal), and a sign-in
code that lands in spam locks a paying customer out of the app — so the
better-deliverability route is the right default for all of them.
"""

from __future__ import annotations

from typing import Optional

import httpx

from . import config

POSTMARK_API_URL = "https://api.postmarkapp.com/email"


class PostmarkError(Exception):
    pass


def send_postmark_email(*, to_email: str, subject: str, text_body: str, html_body: str = "", reply_to: str = "",
                        attachments: Optional[list] = None, stream: str = "", headers: Optional[list] = None,
                        from_email: str = "") -> str:
    """`attachments`: [(filename, bytes, content_type)].

    Returns Postmark's MessageID. It is what ties an open or a click
    reported later to the exact email that earned it -- matching on the
    address alone could not tell which of four sequence emails was the
    one they opened."""
    payload = {
        "From": from_email or config.POSTMARK_FROM or config.SMTP_FROM,
        "To": to_email,
        "Subject": subject,
        "TextBody": text_body,
        "MessageStream": stream or config.POSTMARK_MESSAGE_STREAM,
    }
    if html_body:
        payload["HtmlBody"] = html_body
    if reply_to or config.REPLY_TO_EMAIL:
        payload["ReplyTo"] = reply_to or config.REPLY_TO_EMAIL
    if headers:
        payload["Headers"] = headers
    if attachments:
        import base64
        payload["Attachments"] = [{"Name": name, "Content": base64.b64encode(data).decode(), "ContentType": ctype} for name, data, ctype in attachments]

    try:
        response = httpx.post(
            POSTMARK_API_URL,
            json=payload,
            headers={"Accept": "application/json", "Content-Type": "application/json", "X-Postmark-Server-Token": config.POSTMARK_API_TOKEN},
            timeout=15,
        )
    except httpx.HTTPError as e:
        raise PostmarkError(str(e)) from e
    if response.status_code != 200:
        raise PostmarkError(f"Postmark returned {response.status_code}: {response.text}")
    try:
        return str(response.json().get("MessageID") or "")
    except (ValueError, AttributeError):
        # The mail went out; only the id for matching a later open is lost,
        # and that must never turn a successful send into a failure.
        return ""
