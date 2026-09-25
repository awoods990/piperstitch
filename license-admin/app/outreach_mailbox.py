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
import socket
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


SMTP_TIMEOUT = 10


def _open(mailbox: dict) -> smtplib.SMTP:
    if mailbox["port"] == 465:
        return smtplib.SMTP_SSL(mailbox["host"], mailbox["port"], timeout=SMTP_TIMEOUT)
    smtp = smtplib.SMTP(mailbox["host"], mailbox["port"], timeout=SMTP_TIMEOUT)
    smtp.starttls()
    return smtp


def connect(mailbox: dict) -> smtplib.SMTP:
    smtp = _open(mailbox)
    smtp.login(mailbox["username"], password_for(mailbox["id"]))
    return smtp


def _reachable(host: str, port: int) -> str:
    """Open a bare socket, before any SMTP at all. A password cannot be the
    reason this fails, so when it does the answer is never to retype one.
    The two failures look different from the outside and mean different
    things: refused comes back at once and is a server saying no, while
    silence for the whole timeout is a port being dropped -- which is what
    a hosting platform blocking outbound SMTP looks like from inside it."""
    try:
        with socket.create_connection((host, port), timeout=SMTP_TIMEOUT):
            return ""
    except socket.timeout:
        return (f"{host} never answered on port {port} — {SMTP_TIMEOUT} seconds of silence. Nothing refused the "
                f"connection; it simply went nowhere. That is what a blocked outbound port looks like from inside "
                f"a hosting platform.")
    except socket.gaierror as e:
        return f"There is no such server as {host} — the name doesn't resolve. ({e})"
    except OSError as e:
        if getattr(e, "errno", None) in (101, 113) or "unreachable" in str(e).lower():
            return (f"This server cannot open a connection to {host}:{port} at all. Outbound SMTP is blocked where "
                    f"the admin runs, and no password will change that.")
        return f"Couldn't reach {host} on port {port} — {e}"


def diagnose(mailbox_id: int) -> dict:
    """Three separate questions, asked in order, because they have three
    different answers. Can this server reach the internet on that port; will
    the mail server hold an encrypted conversation; and only last, is the
    password right. Reported as stages so the one that failed is the one
    you read, rather than a single line that sends you back to the password
    when the password was never involved."""
    row = db.get_outreach_mailbox(mailbox_id)
    if row is None:
        return {"ok": False, "gone": True, "steps": [], "summary": "That mailbox isn't here any more.", "advice": ""}
    mailbox = _row_to_dict(row)
    steps = [{"name": f"Reaching {mailbox['host']} on port {mailbox['port']}", "state": "waiting", "detail": ""},
             {"name": "Starting an encrypted session", "state": "waiting", "detail": ""},
             {"name": f"Signing in as {mailbox['username']}", "state": "waiting", "detail": ""}]

    if not (mailbox["host"] and mailbox["username"] and mailbox["has_password"]):
        for s in steps:
            s["state"] = "skipped"
        return {"ok": False, "steps": steps, "mailbox": mailbox,
                "summary": "This mailbox isn't filled in yet.",
                "advice": "It needs a server, a username and a password before it can sign in."}

    problem = _reachable(mailbox["host"], mailbox["port"])
    if problem:
        steps[0].update(state="failed", detail=problem)
        steps[1]["state"] = steps[2]["state"] = "skipped"
        db.update_outreach_mailbox(mailbox_id, last_error=problem)
        return {"ok": False, "steps": steps, "mailbox": mailbox, "network": True,
                "summary": "This server can't get out to the mail server.",
                "advice": "Railway blocks outbound SMTP below the Pro plan, and enabling it can be a per-service "
                          "setting rather than an account-wide one — check the admin service itself, not only the "
                          "plan. Until a connection opens here, nothing about the mailbox or its password matters."}
    steps[0].update(state="ok", detail="The port answered.")

    try:
        smtp = _open(mailbox)
    except smtplib.SMTPException as e:
        steps[1].update(state="failed", detail=f"{mailbox['host']} answered, but wouldn't start an encrypted session: {e}")
        steps[2]["state"] = "skipped"
        db.update_outreach_mailbox(mailbox_id, last_error=steps[1]["detail"])
        return {"ok": False, "steps": steps, "mailbox": mailbox,
                "summary": "The mail server answered but refused an encrypted session.",
                "advice": "Port 587 expects STARTTLS and port 465 expects TLS from the first byte. If the port was "
                          "changed by hand, set it back to 587 for Google and Microsoft."}
    except OSError as e:
        steps[1].update(state="failed", detail=f"The connection dropped: {e}")
        steps[2]["state"] = "skipped"
        db.update_outreach_mailbox(mailbox_id, last_error=steps[1]["detail"])
        return {"ok": False, "steps": steps, "mailbox": mailbox, "network": True,
                "summary": "The connection opened and then died.",
                "advice": "Something between here and the mail server is closing SMTP connections part-way."}
    steps[1].update(state="ok", detail="Encrypted.")

    try:
        with smtp:
            smtp.login(mailbox["username"], password_for(mailbox["id"]))
    except smtplib.SMTPAuthenticationError as e:
        steps[2].update(state="failed", detail=f"{mailbox['host']} refused the sign-in: {e}")
        db.update_outreach_mailbox(mailbox_id, last_error=steps[2]["detail"])
        return {"ok": False, "steps": steps, "mailbox": mailbox, "password": True,
                "summary": "The server is reachable. It's the sign-in that's being refused.",
                "advice": "For Google this must be a 16-character App Password, not the account password, with "
                          "2-Step Verification on; paste it without the spaces Google shows it in. The username is "
                          "the full address. If the address is on a Workspace domain, the admin console must also "
                          "allow app passwords."}
    except smtplib.SMTPException as e:
        steps[2].update(state="failed", detail=f"{mailbox['host']} refused it: {e}")
        db.update_outreach_mailbox(mailbox_id, last_error=steps[2]["detail"])
        return {"ok": False, "steps": steps, "mailbox": mailbox,
                "summary": "The mail server turned the sign-in away.",
                "advice": "The words above come from the mail server itself."}
    except OSError as e:
        steps[2].update(state="failed", detail=f"The connection dropped during sign-in: {e}")
        db.update_outreach_mailbox(mailbox_id, last_error=steps[2]["detail"])
        return {"ok": False, "steps": steps, "mailbox": mailbox, "network": True,
                "summary": "The connection died while signing in.", "advice": ""}
    steps[2].update(state="ok", detail="Signed in.")

    db.update_outreach_mailbox(mailbox_id, last_ok_at=db.now_iso(), last_error="")
    return {"ok": True, "steps": steps, "mailbox": mailbox,
            "summary": f"Signed in to {mailbox['host']} as {mailbox['username']}. This mailbox can send.",
            "advice": ""}


def check(mailbox_id: int) -> str:
    """Sign in without sending. '' when it worked; otherwise words an admin
    can act on. The outcome is kept on the row so the list shows it."""
    result = diagnose(mailbox_id)
    if result["ok"]:
        return ""
    failed = next((s["detail"] for s in result["steps"] if s["state"] == "failed"), "")
    return failed or result["summary"]
