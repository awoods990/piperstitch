"""Turns a plain-text email body into a branded HTML email.

Every email is sent as multipart/alternative: the plain text (the source
of truth, and what a client that blocks HTML shows in full) plus this
HTML rendering of it. Same constraints as the Amerus version, because
they're limits of email clients, not stylistic preferences:
  - Tables for layout, inline styles only (Outlook ignores <style>,
    flexbox and grid entirely).
  - The logo is a hosted https image, never a data: URI (Gmail strips
    those) and never an attachment (paper-clips in several clients).
  - Images are assumed blocked by default, so nothing depends on the
    logo loading.
  - No web fonts; a system stack only.
"""

from __future__ import annotations

import html
import re

from . import config

# The mark alone (the sandpiper with its trailing thread looped under its
# own feet, not the older "thread in its beak" pose) -- the "PiperStitch"
# wordmark below it is real HTML text, not baked into the image, so it
# still reads even with images blocked (the norm for a first-open email;
# see the module doc comment).
MARK_URL = f"{config.WEBSITE_BASE_URL}/assets/piperstitch-mark-512.png"

# Sampled from the logo: the navy of "Piper", the thread-blue of "Stitch",
# the sandpiper's caramel, and a warm linen ground.
NAVY = "#0f2a4d"
BLUE = "#1a6fd1"
CARAMEL = "#a8621f"
INK = "#161a20"
INK_2 = "#3b424d"
MUTED = "#6a7280"
LINEN = "#f7f3ec"
LINE = "#e6e0d4"

FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"


def _paragraphs(text: str) -> list[str]:
    return [b.strip() for b in re.split(r"\n\s*\n", text.strip()) if b.strip()]


#: A bare URL sitting in a sentence. Trailing punctuation is left out of the
#: link -- "…details: {url}." should not send anyone to a URL ending in a
#: full stop.
_URL = re.compile(r"(https?://[^\s<>\"]+?)([.,;:!?)\]]*)(?=\s|$)")


def _linkify(escaped_line: str) -> str:
    """Make the URLs in a plain-text body clickable.

    The bodies are written as plain text and shown as HTML, so until now a
    link was only a link if the reader's client happened to underline it
    for them. Several clients do not, and an invitation whose signup link
    cannot be clicked is an invitation nobody accepts. The line is already
    HTML-escaped when it gets here, so nothing is re-escaped.
    """
    def wrap(m):
        url, tail = m.group(1), m.group(2)
        return f'<a href="{url}" style="color:{BLUE};text-decoration:underline;">{url}</a>{tail}'
    return _URL.sub(wrap, escaped_line)


def _render_block(block: str) -> str:
    """One plain-text paragraph -> one HTML block. A block whose every
    line starts with '- ' or '* ' becomes a bullet list; a lone '---' a
    divider; a line that is only a 6-digit code is set large (the
    sign-in code email)."""
    lines = [ln.strip() for ln in block.split("\n") if ln.strip()]

    if all(ln.startswith(("- ", "* ")) for ln in lines):
        items = "".join(
            f'<tr><td style="padding:0 0 10px 0;vertical-align:top;width:20px;color:{BLUE};font-size:16px;line-height:24px;">&bull;</td>'
            f'<td style="padding:0 0 10px 0;color:{INK_2};font-size:16px;line-height:24px;font-family:{FONT};">{html.escape(ln[2:])}</td></tr>'
            for ln in lines
        )
        return f'<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">{items}</table>'

    if lines == ["---"]:
        return f'<hr style="border:none;border-top:1px solid {LINE};margin:26px 0;">'

    if len(lines) == 1 and re.fullmatch(r"\d{6}", lines[0]):
        return (
            f'<p style="margin:6px 0 22px 0;font-family:ui-monospace,Menlo,monospace;font-size:34px;letter-spacing:.28em;'
            f'font-weight:700;color:{NAVY};background:{LINEN};border:1px solid {LINE};border-radius:12px;padding:16px 20px;text-align:center;">{lines[0]}</p>'
        )

    body = "<br>".join(_linkify(html.escape(ln)) for ln in lines)
    return f'<p style="margin:0 0 18px 0;color:{INK_2};font-size:16px;line-height:26px;font-family:{FONT};">{body}</p>'


def button(label: str, url: str) -> str:
    return (
        f'<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:6px 0 22px 0;"><tr><td align="center" bgcolor="{BLUE}" style="border-radius:999px;">'
        f'<a href="{html.escape(url, quote=True)}" style="display:inline-block;padding:14px 32px;font-family:{FONT};font-size:16px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:999px;">{html.escape(label)}</a>'
        f"</td></tr></table>"
    )


def render(*, body_text: str, cta_label: str = "", cta_url: str = "", preheader: str = "", footer_note: str = "",
           hero_image: str = "", hero_alt: str = "", hero_url: str = "", hero_full: bool = False, hero_kicker: str = "") -> str:
    """Wraps a plain-text body in the PiperStitch shell.

    `hero_image` is an absolute URL shown above the words -- Piper's
    confetti on a welcome, and nothing at all on an ordinary email. It is
    drawn small and centred by default; `hero_full` gives it the width of
    the card instead, for an email whose picture *is* the message. Either
    can be wrapped in a link with `hero_url`.

    Alt text matters more here than on a web page: a good share of people
    will see the words and no picture at all, because their client blocks
    images until they ask for them.
    """
    blocks = "".join(_render_block(b) for b in _paragraphs(body_text))
    hero = ""
    if hero_image:
        src, alt = html.escape(hero_image, quote=True), html.escape(hero_alt, quote=True)
        if hero_full:
            img = (f'<img src="{src}" width="568" alt="{alt}" '
                   f'style="display:block;width:100%;max-width:568px;height:auto;border:0;border-radius:10px;">')
            pad = "16px 16px 4px 16px"
        else:
            img = (f'<img src="{src}" width="240" alt="{alt}" '
                   f'style="display:block;width:240px;max-width:70%;height:auto;border:0;margin:0 auto;">')
            pad = "6px 32px 0 32px"
        if hero_url:
            img = f'<a href="{html.escape(hero_url, quote=True)}" style="display:block;text-decoration:none;">{img}</a>'
        hero = f'<tr><td align="center" style="padding:{pad};">{img}</td></tr>' 
    # A full-width hero carries its own branding -- the graphic opens with
    # the mark already -- so the shell's masthead stands down rather than
    # showing the logo twice, one above the other.
    # A line of type above the picture, where the masthead would otherwise
    # be: it says what the email is about before the graphic has loaded, or
    # at all if the reader's client never loads it.
    kicker = (f'<tr><td align="center" style="padding:30px 32px 0 32px;">'
              f'<div style="font-family:{FONT};font-size:17px;font-weight:700;letter-spacing:-0.005em;'
              f'line-height:24px;color:{NAVY};">{html.escape(hero_kicker)}</div></td></tr>') if hero_kicker else ""
    masthead = "" if (hero_image and hero_full) else (
        f'<tr><td align="center" style="padding:34px 32px 8px 32px;">'
        f'<img src="{MARK_URL}" width="72" alt="" style="display:block;width:72px;max-width:30%;height:auto;border:0;margin:0 auto;">'
        f'<div style="margin-top:10px;font-family:{FONT};font-size:26px;font-weight:800;letter-spacing:-0.01em;line-height:1;">'
        f'<span style="color:{NAVY};">Piper</span><span style="color:{BLUE};">Stitch</span>'
        f'</div></td></tr>')
    cta = button(cta_label, cta_url) if cta_label and cta_url else ""
    pre = f'<div style="display:none;max-height:0;overflow:hidden;opacity:0;">{html.escape(preheader)}</div>' if preheader else ""
    note = html.escape(footer_note) if footer_note else "You're receiving this because you have a PiperStitch account. Replies reach a person."

    return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light">
</head>
<body style="margin:0;padding:0;background:{LINEN};">
{pre}
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background:{LINEN};">
<tr><td align="center" style="padding:32px 16px;">

<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:600px;background:#ffffff;border:1px solid {LINE};border-radius:14px;">
  {masthead}
  {kicker}
  {hero}
  <tr><td style="padding:22px 32px 8px 32px;">
    {blocks}
    {cta}
  </td></tr>
  <tr><td style="padding:0 32px 30px 32px;">
    <hr style="border:none;border-top:1px solid {LINE};margin:0 0 18px 0;">
    <p style="margin:0;color:{MUTED};font-size:13px;line-height:20px;font-family:{FONT};">
      PiperStitch turns any image into a machine-ready embroidery file, right in your browser.<br>
      <a href="{config.WEBSITE_BASE_URL}" style="color:{BLUE};text-decoration:none;">{config.WEBSITE_BASE_URL.replace('https://', '')}</a>
    </p>
    <p style="margin:12px 0 0 0;color:{MUTED};font-size:12px;line-height:18px;font-family:{FONT};">
      {html.escape(config.LEGAL_NAME)}, {html.escape(config.POSTAL_ADDRESS)}<br>
      <a href="mailto:{config.REPLY_TO_EMAIL}" style="color:{BLUE};text-decoration:none;">{config.REPLY_TO_EMAIL}</a>
    </p>
  </td></tr>
</table>

<p style="margin:18px 0 0 0;color:{MUTED};font-size:12px;line-height:18px;font-family:{FONT};max-width:600px;">{note}</p>

</td></tr></table>
</body></html>"""
