"""The mailboxes recruitment goes out of.

Cold outreach does not belong on the same path as a customer's sign-in
code: Postmark's terms allow only mail people asked for, and one complaint
in a hundred cold sends is ten times their stated limit -- against the
account that also carries licence keys and proof links. So recruitment
leaves instead through mailboxes we own, on a domain kept apart from
piperstitch.com.

More than one mailbox, because Google and Microsoft both begin reading a
single mailbox as bulk somewhere above twenty a day, and because a
particular prospect may deserve a particular sender. Each carries its own
daily cap; a send that would breach it waits for tomorrow rather than
going out and teaching the provider that this mailbox sends in bursts.

Passwords are sealed with the same key that seals partners' tax forms.
What this costs: a mailbox hands back no message id, so opens and clicks
stop being recorded for anything sent this way. Replies reach whatever
each mailbox's reply-to says -- the mailbox itself, or Postmark's inbound
address to keep them showing on the recruit page.
"""

from __future__ import annotations

import json
import smtplib
from datetime import datetime, timezone
from typing import Optional

from . import config, db, documents

LEGACY_SETTING = "outreach_mailbox"


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _row_to_dict(row) -> dict:
    return {
        "id": row["id"], "label": row["label"], "host": row["host"], "port": row["port"],
        "username": row["username"], "from_email": row["from_email"], "reply_to": row["reply_to"],
        "daily_cap": row["daily_cap"], "active": bool(row["active"]),
        "last_ok_at": row["last_ok_at"], "last_error": row["last_error"],
        "has_password": bool(row["password"]),
    }


def adopt_legacy() -> None:
    """The single mailbox this page used to hold becomes the first row, so
    an admin who set one up before does not find it gone."""
    if db.list_outreach_mailboxes():
        return
    raw = db.get_setting(LEGACY_SETTING)
    saved = None
    if raw:
        try:
            saved = json.loads(raw)
        except ValueError:
            saved = None
    if saved and saved.get("host"):
        db.add_outreach_mailbox(label=saved.get("username") or saved["host"], host=saved["host"],
                                port=int(saved.get("port") or 587), username=saved.get("username", ""),
                                password=saved.get("password", ""), from_email=saved.get("from_email", ""),
                                reply_to=saved.get("reply_to", ""))
        db.set_setting(LEGACY_SETTING, "")
    elif config.PARTNER_OUTREACH_SMTP_HOST and config.PARTNER_OUTREACH_FROM:
        db.add_outreach_mailbox(label=config.PARTNER_OUTREACH_SMTP_USERNAME or config.PARTNER_OUTREACH_SMTP_HOST,
                                host=config.PARTNER_OUTREACH_SMTP_HOST, port=config.PARTNER_OUTREACH_SMTP_PORT,
                                username=config.PARTNER_OUTREACH_SMTP_USERNAME,
                                password=documents.seal(config.PARTNER_OUTREACH_SMTP_PASSWORD.encode()) if config.PARTNER_OUTREACH_SMTP_PASSWORD else "",
                                from_email=config.PARTNER_OUTREACH_FROM, reply_to=config.PARTNER_OUTREACH_REPLY_TO)


def mailboxes(*, active_only: bool = False) -> list[dict]:
    usage = db.mailbox_usage(_today())
    out = []
    for row in db.list_outreach_mailboxes(active_only=active_only):
        item = _row_to_dict(row)
        item["sent_today"] = usage.get(row["id"], 0)
        item["room_today"] = max(0, item["daily_cap"] - item["sent_today"])
        out.append(item)
    return out


def configured() -> bool:
    return any(m["host"] and m["username"] and m["from_email"] and m["has_password"] for m in mailboxes(active_only=True))


def password_for(mailbox_id: int) -> str:
    row = db.get_outreach_mailbox(mailbox_id)
    if row is None or not row["password"]:
        return ""
    try:
        return documents.open_(row["password"]).decode()
    except Exception:  # noqa: BLE001 - a key that no longer opens it must not crash a send
        return ""


def save(mailbox_id: Optional[int], *, label: str, host: str, port: int, username: str, password: str,
         from_email: str, reply_to: str, daily_cap: int) -> int:
    """A blank password keeps the one already stored: editing a reply-to
    should not mean retyping a secret the form never shows back."""
    sealed = documents.seal(password.encode()) if password else None
    # The same mailbox re-entered is the same mailbox. Without this, every
    # attempt at a credential that is being refused leaves another identical
    # row behind, and the list fills with copies of the one thing that is
    # not working.
    if not mailbox_id:
        twin = db.find_outreach_mailbox(host, username)
        if twin is not None:
            mailbox_id = twin["id"]
    if mailbox_id:
        fields = {"label": label[:80], "host": host.strip(), "port": port, "username": username.strip(),
                  "from_email": from_email.strip(), "reply_to": reply_to.strip(), "daily_cap": daily_cap}
        if sealed is not None:
            fields["password"] = sealed
        db.update_outreach_mailbox(mailbox_id, **fields)
        return mailbox_id
    return db.add_outreach_mailbox(label=label[:80] or username, host=host.strip(), port=port,
                                   username=username.strip(), password=sealed or "",
                                   from_email=from_email.strip(), reply_to=reply_to.strip(), daily_cap=daily_cap)


def choose(prospect) -> Optional[dict]:
    """Which mailbox carries this approach.

    An explicit assignment wins, because someone chose it on purpose -- but
    it still waits when that mailbox has had its day's worth. Otherwise the
    one with the most room left today, so the load spreads rather than one
    mailbox carrying everything.
    """
    ready = [m for m in mailboxes(active_only=True) if m["host"] and m["username"] and m["from_email"] and m["has_password"]]
    if not ready:
        return None
    assigned = prospect["mailbox_id"] if "mailbox_id" in prospect.keys() else None
    if assigned:
        picked = next((m for m in ready if m["id"] == assigned), None)
        return picked if picked and picked["room_today"] > 0 else None
    with_room = [m for m in ready if m["room_today"] > 0]
    if not with_room:
        return None
    return max(with_room, key=lambda m: (m["room_today"], -m["id"]))


def connect(mailbox: dict) -> smtplib.SMTP:
    password = password_for(mailbox["id"])
    if mailbox["port"] == 465:
        smtp = smtplib.SMTP_SSL(mailbox["host"], mailbox["port"], timeout=20)
    else:
        smtp = smtplib.SMTP(mailbox["host"], mailbox["port"], timeout=20)
        smtp.starttls()
    smtp.login(mailbox["username"], password)
    return smtp


def check(mailbox_id: int) -> str:
    """Sign in without sending. '' when it worked; otherwise words an admin
    can act on. The outcome is kept on the row so the list shows it."""
    row = db.get_outreach_mailbox(mailbox_id)
    if row is None:
        return "That mailbox isn't here any more."
    mailbox = _row_to_dict(row)
    if not (mailbox["host"] and mailbox["username"] and mailbox["has_password"]):
        return "It needs a server, a username and a password before it can sign in."
    try:
        with connect(mailbox):
            pass
    except smtplib.SMTPAuthenticationError:
        problem = ("Sign-in refused. Google needs an App Password with 2-Step Verification on the account; "
                   "Microsoft 365 needs SMTP AUTH enabled for this mailbox.")
        db.update_outreach_mailbox(mailbox_id, last_error=problem)
        return problem
    except OSError as e:
        # Errno 101/113: the host cannot open the connection at all. On
        # Railway that is the platform, not the credential -- outbound SMTP
        # ports are blocked except on the Pro plan. Saying so here saves
        # retyping a password that was never the problem.
        blocked = getattr(e, "errno", None) in (101, 113) or "unreachable" in str(e).lower()
        problem = (f"Couldn't reach {mailbox['host']}. This server cannot open an SMTP connection at all — on Railway, "
                   f"outbound SMTP is blocked below the Pro plan, and no password will change that. ({e})"
                   if blocked else f"Couldn't reach {mailbox['host']}: {e}")
        db.update_outreach_mailbox(mailbox_id, last_error=problem)
        return problem
    except smtplib.SMTPException as e:
        problem = f"{mailbox['host']} refused it: {e}"
        db.update_outreach_mailbox(mailbox_id, last_error=problem)
        return problem
    db.update_outreach_mailbox(mailbox_id, last_ok_at=db.now_iso(), last_error="")
    return ""
