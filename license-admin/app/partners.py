"""The Partner Program's people-facing half (spec §7, §8, §10): the
application, approval, the portal's sign-in links and the numbers the
portal shows. Money itself is computed in promotions.py and db.py; this
module only reads it.

The portal never sees a customer's identity -- a referral is a date, a
status, a month count and a number (§7, §10.3).
"""

from __future__ import annotations

import base64
import csv
import logging
import hashlib
import hmac
import io
import re
import secrets
from datetime import date, datetime, timedelta, timezone
from typing import Optional
from urllib.parse import quote

from . import config, db, email_sender, promotions

log = logging.getLogger("license_admin.partners")

# Program constants (spec §2). The rate itself is stored per promoter and
# per code (R2); these are the defaults an approval starts from.
FOUNDING_LIMIT = 50
FOUNDING_SHARE = 30.0
STANDARD_SHARE = 25.0
COMMISSION_MONTHS = 24
BOUNTY_WINDOW_DAYS = 120
BOUNTY_DOLLARS = 15
REINSTATE_AT = promotions.REINSTATE_AT
PAYOUT_MINIMUM_CENTS = 50_00
OFFER_TRIAL_DAYS = 30
OFFER_PROOFS = 10            # total included proofs the audience offer gives
LINK_TTL_MINUTES = 30
PROGRAM_TOKEN_DAYS = 180     # how long a "here are the details" link keeps working

# FTC disclosure (§10.1). Shown above the creative kit, in the agreement,
# and in the welcome email.
DISCLOSURE_APPROVED = [
    "I get a commission if you subscribe through my link",
    "I earn a commission for up to two years on anyone who subscribes through my link",
    "Paid link",
    "#ad",
]
DISCLOSURE_INADEQUATE = ["affiliate link", "commissionable link", "sp", "spon", "collab"]
CLAIMS_APPROVED = [
    "It makes the decisions a digitizer would: stitch type, underlay, density, compensation and sew order.",
    "It's rules-based, not AI, so the same artwork gives the same file every time.",
    "Seconds instead of a day waiting on an outsourced digitizer.",
    "Every decision is shown and can be edited.",
    "$24 a month instead of a thousand-dollar package.",
    "It flags problems before you hoop.",
]
CLAIMS_FORBIDDEN = [
    "\"Perfect every time\" or \"never needs editing\".",
    "\"Replaces a professional digitizer\".",
    "Named quality comparisons to Hatch, Embrilliance, Wilcom or any other product.",
    "Any income claim for the viewer.",
    "Calling it AI.",
    "Anything about a feature you haven't used yourself.",
]
CAPTION_DRAFTS = [
    "I get a commission if you subscribe through my link. I dropped a customer's logo into PiperStitch and had a stitch file in seconds — every decision it made is right there to change. 30-day free trial and 10 proofs through my link: {link}",
    "Paid link. If you've been paying a digitizer per design, try this on your next order: {link} — 30 days free, no card, and it shows you the stitches before you hoop.",
    "#ad — I've been sending proofs from PiperStitch: the customer opens a link on their phone, sees the real stitches on the garment, taps approve. My link gets you 30 days and 10 proofs free: {link}",
]


class PartnerError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _date(value: Optional[str]) -> Optional[date]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).date()
    except ValueError:
        return None


def is_partner(promoter) -> bool:
    return promoter is not None and (bool(promoter["tier"]) or promoter["status"] != "active" or bool(promoter["applied_at"]))


def can_use_portal(promoter) -> bool:
    """Applied partners can sign in to see where their application is;
    closed ones can't."""
    return promoter is not None and promoter["active"] and promoter["status"] in ("applied", "approved", "active", "suspended")


def tier_label(promoter) -> str:
    """R7a: 'Established' is derived, never stored."""
    if promoter["bounty_reinstated_at"]:
        return "Established partner"
    return {"founding": "Founding partner", "standard": "Partner"}.get(promoter["tier"] or "", "Partner")


def link_url(code: str) -> str:
    return f"{config.WEBSITE_BASE_URL}/r/{code}"


def portal_url() -> str:
    return f"{config.PUBLIC_BASE_URL}/partners/portal"


# ------------------------------------------------------------ portal auth --


def create_portal_link(promoter_id: int) -> str:
    token = secrets.token_urlsafe(32)
    db.create_partner_link(promoter_id=promoter_id, token_hash=_hash(token), ttl_minutes=LINK_TTL_MINUTES)
    return f"{config.PUBLIC_BASE_URL}/partners/portal/open?token={token}"


def resolve_portal_link(token: str) -> Optional[int]:
    return db.consume_partner_link(_hash(token)) if token else None


def send_portal_link(email: str) -> bool:
    """Emails a sign-in link if the address belongs to a partner who may
    use the portal. Returns whether anything was sent (the caller shows
    the same page either way)."""
    promoter = db.get_promoter_by_email(email)
    if not can_use_portal(promoter):
        return False
    url = create_portal_link(promoter["id"])
    email_sender.send_partner_link_email(to_email=email, partner_name=promoter["name"], url=url)
    return True


# ------------------------------------------------- the program details gate --
# The program page carries rates, the bounty and payout terms. That is not
# something every customer should meet by wandering the site, so it sits
# behind a short registration: name and email, then straight in. We also
# mail a link so they can come back, and can send that link cold to
# someone we want in the program.


def _program_sign(payload: str) -> str:
    return hmac.new(_secret(), payload.encode(), hashlib.sha256).hexdigest()[:32]


def _secret() -> bytes:
    return (config.REFERRAL_SECRET or config.SESSION_SECRET or "development-only").encode()


def program_token(prospect_id: int, *, at: Optional[datetime] = None) -> str:
    """Dots, not pipes: this token travels in a URL inside an email, and a
    `|` is not legal in one -- mail clients and scanners truncate the
    auto-linked text at it, and the recipient lands on a broken link and
    meets the registration gate we sent them past."""
    payload = f"{int(prospect_id)}.{(at or _now()).date().isoformat()}"
    return f"{payload}.{_program_sign(payload)}"


def resolve_program_token(token: str) -> Optional[int]:
    """The prospect a details link points at, if the signature holds and
    it is under PROGRAM_TOKEN_DAYS old."""
    if not token:
        return None
    separator = "." if "." in token.split("|")[0] else "|"      # "|" is the older shape; both still open
    try:
        pid, issued, sig = token.split(separator, 2)
    except ValueError:
        return None
    if not hmac.compare_digest(sig, _program_sign(f"{pid}{separator}{issued}")):
        return None
    try:
        when = date.fromisoformat(issued)
    except ValueError:
        return None
    if (_now().date() - when).days > PROGRAM_TOKEN_DAYS or when > _now().date() + timedelta(days=1):
        return None
    prospect = db.get_partner_prospect(int(pid))
    return prospect["id"] if prospect is not None else None


def video_url(prospect_id: int) -> str:
    """The two-minute introduction, with their token so the click counts
    and the details are one step away rather than behind a form."""
    return f"{config.PUBLIC_BASE_URL}/partners/video?k={quote(program_token(prospect_id), safe='')}"


def program_url(prospect_id: int) -> str:
    """Straight into the full program details -- no registration, nothing
    to fill in again. The token is escaped so the link survives the trip
    through an email client."""
    return f"{config.PUBLIC_BASE_URL}/partners/program?k={quote(program_token(prospect_id), safe='')}"


def apply_url(prospect_id: int) -> str:
    return f"{config.PUBLIC_BASE_URL}/partners/apply?k={quote(program_token(prospect_id), safe='')}"


def register_prospect(*, name: str, email: str, organization: str = "", platforms: str = "", source: str = "self", note: str = "") -> int:
    name = (name or "").strip(); email = (email or "").strip().lower()
    if len(name) < 2:
        raise PartnerError("name", "Please tell us your name.")
    if "@" not in email or "." not in email.split("@")[-1]:
        raise PartnerError("email", "That doesn't look like an email address.")
    prospect_id = db.create_partner_prospect(name=name, email=email, organization=organization, platforms=platforms, source=source, note=note)
    try:
        email_sender.send_partner_program_email(to_email=email, partner_name=name, url=program_url(prospect_id), invited=(source == "invite"))
    except email_sender.EmailSendError:
        pass
    return prospect_id


def prospect_context(prospect) -> dict:
    """What the gated program page needs to know about its reader."""
    return {"prospect": prospect, "seats_left": founding_seats_left(), "program_link": program_url(prospect["id"]) if prospect else ""}


# ------------------------------------------------- tax forms and payouts --

DOCUMENT_TYPES = {"application/pdf": ".pdf", "image/png": ".png", "image/jpeg": ".jpg", "image/heic": ".heic"}
MAX_DOCUMENT_BYTES = 8 * 1024 * 1024
PAYOUT_COUNTRIES_NOTE = "PayPal must be able to receive US dollars in that country."


def store_document(promoter, *, kind: str, filename: str, content_type: str, raw: bytes) -> int:
    """A partner's tax form, straight into the database (the durable
    volume). An upload doesn't unlock payouts by itself -- we look at it
    first, which is the point of having it."""
    if kind not in ("w9", "w8ben", "other"):
        raise PartnerError("kind", "Choose which form it is: W-9 or W-8BEN.")
    if not raw:
        raise PartnerError("file", "That file came through empty — try again.")
    if len(raw) > MAX_DOCUMENT_BYTES:
        raise PartnerError("file", f"That file is {len(raw) / 1024 / 1024:.1f} MB; the limit is {MAX_DOCUMENT_BYTES // 1024 // 1024} MB. A PDF or a photo of the signed form is plenty.")
    if content_type not in DOCUMENT_TYPES:
        raise PartnerError("file", "Send a PDF, or a photo as PNG, JPEG or HEIC.")
    document_id = db.add_partner_document(promoter_id=promoter["id"], kind=kind, filename=filename or f"tax-form{DOCUMENT_TYPES[content_type]}",
                                          content_type=content_type, data=base64.b64encode(raw).decode(), size_bytes=len(raw))
    db.update_partner_fields(promoter["id"], tax_form_type=kind if kind != "other" else promoter["tax_form_type"])
    try:
        email_sender.send_plain_email(
            to_email=config.REPLY_TO_EMAIL,
            subject=f"Tax form from {promoter['name']} ({kind.upper()})",
            body=f"{promoter['name']} ({promoter['email']}) uploaded a {kind.upper()} from the partner portal.\n\nAccept it here: {config.PUBLIC_BASE_URL}/admin/promoters/{promoter['id']}")
    except email_sender.EmailSendError:
        pass
    return document_id


def accept_document(document_id: int, *, by: str = "admin") -> None:
    """Accepting the form is what unblocks payouts (§10.2)."""
    doc = db.get_partner_document(document_id)
    if doc is None:
        raise PartnerError("missing", "That document isn't here.")
    db.decide_partner_document(document_id, accepted=True, by=by)
    db.update_partner_fields(doc["promoter_id"], tax_form_type=doc["kind"] if doc["kind"] != "other" else None, tax_form_received_at=db.now_iso())


def reject_document(document_id: int, *, note: str) -> None:
    doc = db.get_partner_document(document_id)
    if doc is None:
        raise PartnerError("missing", "That document isn't here.")
    db.decide_partner_document(document_id, accepted=False, note=note)
    promoter = db.get_promoter(doc["promoter_id"])
    if promoter is not None and not any(d["accepted_at"] for d in db.list_partner_documents(promoter["id"])):
        db.update_partner_fields(promoter["id"], tax_form_received_at=None)
        try:
            email_sender.send_partner_document_rejected_email(to_email=promoter["email"], partner_name=promoter["name"], note=note)
        except email_sender.EmailSendError:
            pass


def save_payout_details(promoter, *, method: str, payout_email: str, payout_name: str, payout_country: str) -> None:
    """Exactly what PayPal needs from us to send the money, and nothing
    we don't need."""
    method = method if method in ("paypal", "bank", "other") else "paypal"
    payout_email = (payout_email or "").strip().lower()
    if method == "paypal":
        if "@" not in payout_email or "." not in payout_email.split("@")[-1]:
            raise PartnerError("payout_email", "That doesn't look like the email address on a PayPal account.")
        if not (payout_name or "").strip():
            raise PartnerError("payout_name", "We need the name exactly as it appears on the PayPal account.")
    db.update_partner_fields(promoter["id"], payout_method=method, payout_email=payout_email, payout_name=(payout_name or "").strip(), payout_country=(payout_country or "").strip())


def payout_readiness(promoter) -> dict:
    """What's still missing before the first payout can go out."""
    documents = db.list_partner_documents(promoter["id"])
    accepted = [d for d in documents if d["accepted_at"]]
    waiting = [d for d in documents if not d["accepted_at"] and not d["rejected_at"]]
    rejected = [d for d in documents if d["rejected_at"] and not accepted]
    missing = []
    if not accepted:
        missing.append("your tax form" if not waiting else "")
    if promoter["payout_method"] == "paypal" and not promoter["payout_email"]:
        missing.append("your PayPal email")
    if promoter["payout_method"] == "paypal" and not promoter["payout_name"]:
        missing.append("the name on your PayPal account")
    return {"documents": documents, "accepted": accepted[0] if accepted else None, "waiting": waiting[0] if waiting else None,
            "rejected": rejected[0] if rejected else None, "missing": [m for m in missing if m], "ready": bool(accepted) and not [m for m in missing if m]}


# ----------------------------------------------- the kit, announced (§8) --


def announce_resource(resource_id: int) -> int:
    """Tells every active partner about a new piece of kit, with the link
    to it. Returns how many were told."""
    item = db.get_partner_resource(resource_id)
    if item is None:
        raise PartnerError("missing", "That item isn't in the kit.")
    sent = 0
    for promoter in db.partners_to_notify():
        try:
            email_sender.send_partner_kit_email(to_email=promoter["email"], partner_name=promoter["name"], title=item["title"],
                                                description=item["description"], url=item["url"], kind=item["kind"])
            sent += 1
        except email_sender.EmailSendError:
            log.warning("Could not tell %s about kit item %s", promoter["email"], resource_id)
    db.mark_resource_announced(resource_id)
    return sent


KIT_VIDEOS = [
    {"title": "PiperStitch in a minute (animated)", "file": "piperstitch-animated-introduction.mp4", "sort_order": 10,
     "description": "The short one. Good for a post, a Story, or the top of a video."},
    {"title": "The full introduction", "file": "piperstitch-introduction.mp4", "sort_order": 20,
     "description": "Artwork to machine file, start to finish — for when you want to show rather than tell."},
    {"title": "The Partner Program, in two minutes", "file": "piperstitch-partner-program.mp4", "sort_order": 30,
     "description": "What the program is. Send it to anyone you think should be a partner; we'll send them their own link."},
]


def seed_kit() -> None:
    """The films we make, in every partner's kit from the day they join.
    Added once; an admin can rename, reorder, hide or remove them after
    that, and this will not put them back."""
    have = {r["url"] for r in db.list_partner_resources()}
    for video in KIT_VIDEOS:
        url = f"{config.WEBSITE_BASE_URL}/assets/video/{video['file']}"
        if url not in have:
            db.add_partner_resource(title=video["title"], url=url, kind="video", description=video["description"], sort_order=video["sort_order"])


# ------------------------------------------------------ recruitment (§8) --
# Someone we'd like in the program, approached properly: four emails over
# a fortnight, each one shorter than the last, every one carrying their
# own link into the details and a way to tell us to stop. It runs on the
# scheduler that already sends the customer sequences.

OUTREACH_STEPS = [
    {"step": 1, "delay_days": 0, "key": "partner_outreach_1"},
    {"step": 2, "delay_days": 3, "key": "partner_outreach_2"},
    {"step": 3, "delay_days": 8, "key": "partner_outreach_3"},
    {"step": 4, "delay_days": 16, "key": "partner_outreach_4"},
]
RECRUIT_LINE = re.compile(r"^\s*(?P<name>[^,<]+?)\s*(?:[,<]\s*)(?P<email>[^>,\s]+@[^>,\s]+?)>?\s*$")


def opt_out_url(prospect_id: int) -> str:
    return f"{config.PUBLIC_BASE_URL}/partners/no-thanks?k={quote(program_token(prospect_id), safe='')}"


def parse_recruits(text: str) -> tuple[list[dict], list[str]]:
    """`Name <email>`, `Name, email`, or a CSV's `name,email` rows -- one
    per line. Returns the people and the lines we couldn't read."""
    people, bad = [], []
    for raw in (text or "").splitlines():
        line = raw.strip().strip('"')
        if not line or line.lower().replace(" ", "").startswith(("name,email", "name;email")):
            continue
        m = RECRUIT_LINE.match(line)
        if not m:
            bad.append(raw.strip()); continue
        name, email = m.group("name").strip().strip('"'), m.group("email").strip().lower()
        if "@" not in email or "." not in email.split("@")[-1] or len(name) < 2:
            bad.append(raw.strip()); continue
        people.append({"name": name, "email": email})
    return people, bad


SEND_NOW_LIMIT = 10          # beyond this, the scheduler takes the first emails too


def start_outreach(people: list[dict], *, note: str = "", send_now_limit: int = SEND_NOW_LIMIT) -> dict:
    """Sends the first email straight away (up to a batch worth, so the
    request doesn't sit on SMTP all afternoon) and leaves the rest to the
    scheduler. Anyone already a partner, already applied, or who has told
    us no is skipped."""
    result = {"started": 0, "sent": 0, "queued": 0, "skipped": []}
    for person in people:
        email = person["email"]
        promoter = db.get_promoter_by_email(email)
        if promoter is not None and partner_exists(promoter):
            result["skipped"].append(f"{email} (already {promoter['status']})"); continue
        existing = db.get_partner_prospect_by_email(email)
        if existing is not None:
            if existing["opted_out_at"]:
                result["skipped"].append(f"{email} (asked not to be contacted)"); continue
            if existing["applied_at"]:
                result["skipped"].append(f"{email} (already applied)"); continue
            if existing["outreach_status"] == "active":
                result["skipped"].append(f"{email} (already being contacted)"); continue
        prospect_id = db.create_partner_prospect(name=person["name"], email=email, source="recruit", note=note)
        db.set_prospect_outreach(prospect_id, outreach_step=0, outreach_status="active", outreach_next_at=db.now_iso(), source="recruit")
        result["started"] += 1
        if result["sent"] < send_now_limit and send_outreach_step(db.get_partner_prospect(prospect_id), 1):
            result["sent"] += 1
        else:
            result["queued"] += 1
    return result


def partner_exists(promoter) -> bool:
    return promoter is not None and promoter["status"] in ("applied", "approved", "active", "suspended")


def send_outreach_step(prospect, step: int, *, advance: bool = True) -> bool:
    """One recruitment email. Everything is logged, sent or failed. With
    `advance` off it is a plain resend: the same words again, and the
    schedule left exactly where it was."""
    spec = next((s for s in OUTREACH_STEPS if s["step"] == step), None)
    if spec is None:
        return False
    url = program_url(prospect["id"])
    try:
        subject = email_sender.send_partner_outreach_email(
            to_email=prospect["email"], partner_name=prospect["name"], key=spec["key"], url=url,
            apply_url=apply_url(prospect["id"]), opt_out_url=opt_out_url(prospect["id"]), video_url=video_url(prospect["id"]))
    except email_sender.EmailSendError as e:
        db.log_outreach(prospect_id=prospect["id"], step=step, subject=spec["key"], status="failed", error=str(e))
        return False
    db.log_outreach(prospect_id=prospect["id"], step=step, subject=subject)
    if not advance:
        return True
    nxt = next((s for s in OUTREACH_STEPS if s["step"] == step + 1), None)
    if nxt is None:
        db.set_prospect_outreach(prospect["id"], outreach_step=step, outreach_status="done", outreach_next_at=None)
    else:
        due = _now() + timedelta(days=nxt["delay_days"] - next(s["delay_days"] for s in OUTREACH_STEPS if s["step"] == step))
        db.set_prospect_outreach(prospect["id"], outreach_step=step, outreach_next_at=due.isoformat(timespec="seconds").replace("+00:00", "Z"))
    return True


def outreach_check(*, now: Optional[datetime] = None) -> int:
    """The scheduler's tick for recruitment: send whatever is due."""
    sent = 0
    for prospect in db.due_outreach((now or _now()).isoformat(timespec="seconds").replace("+00:00", "Z")):
        if send_outreach_step(prospect, int(prospect["outreach_step"] or 0) + 1):
            sent += 1
    return sent


def record_reply(prospect, *, subject: str = "", body: str, pause: bool = True) -> int:
    """They wrote back. The sequence stops there: nobody should get the
    next scripted email while a person is halfway through answering
    them."""
    reply_id = db.add_outreach_reply(prospect_id=prospect["id"], subject=subject or "(no subject)", body=body)
    if pause and prospect["outreach_status"] in ("active", "done"):
        db.set_prospect_outreach(prospect["id"], outreach_status="replied", outreach_next_at=None)
    return reply_id


def resume_outreach(prospect_id: int) -> None:
    """Back into the sequence where it left off."""
    prospect = db.get_partner_prospect(prospect_id)
    if prospect is None:
        return
    step = int(prospect["outreach_step"] or 0)
    nxt = next((s for s in OUTREACH_STEPS if s["step"] == step + 1), None)
    if nxt is None:
        db.set_prospect_outreach(prospect_id, outreach_status="done", outreach_next_at=None)
        return
    db.set_prospect_outreach(prospect_id, outreach_status="active", outreach_next_at=db.now_iso())


def inbound_reply(*, from_email: str, subject: str, body: str) -> Optional[int]:
    """A reply arriving from the mail provider's inbound hook. Matched to
    the person by address; anything we can't place is ignored rather than
    stored, since this endpoint is open to the internet."""
    prospect = db.get_partner_prospect_by_email(from_email)
    if prospect is None or not prospect["outreach_status"]:
        return None
    return record_reply(prospect, subject=subject, body=(body or "").strip()[:20000])


def recruit_timeline(prospect) -> list[dict]:
    """Everything that has happened with this person, in order: what we
    sent, what they wrote back, when they opened the details, and what
    is due next."""
    events = []
    for row in db.list_outreach_log(prospect["id"]):
        events.append({"at": row["created_at"], "kind": "reply" if row["direction"] == "in" else ("failed" if row["status"] == "failed" else "sent"),
                       "step": row["step"], "subject": row["subject"], "body": row["body"], "error": row["error"]})
    if prospect["last_seen_at"]:
        events.append({"at": prospect["last_seen_at"], "kind": "opened", "subject": f"Opened the program details ({prospect['views']}&times; in all)", "step": 0, "body": "", "error": ""})
    if prospect["applied_at"]:
        events.append({"at": prospect["applied_at"], "kind": "applied", "subject": "Applied to the program", "step": 0, "body": "", "error": ""})
    if prospect["opted_out_at"]:
        events.append({"at": prospect["opted_out_at"], "kind": "opted_out", "subject": "Asked not to be contacted again", "step": 0, "body": "", "error": ""})
    return sorted(events, key=lambda e: e["at"] or "")


def outreach_plan(prospect) -> list[dict]:
    """The four steps with where this person is in them."""
    sent_steps = {row["step"] for row in db.list_outreach_log(prospect["id"]) if row["direction"] == "out" and row["status"] == "sent"}
    plan = []
    for spec in OUTREACH_STEPS:
        row = next((r for r in db.list_outreach_log(prospect["id"]) if r["step"] == spec["step"] and r["direction"] == "out"), None)
        state = "sent" if spec["step"] in sent_steps else ("next" if spec["step"] == int(prospect["outreach_step"] or 0) + 1 else "to come")
        if prospect["outreach_status"] in ("stopped", "opted_out", "replied") and state == "next":
            state = "held"
        plan.append({**spec, "state": state, "sent_at": row["created_at"] if row else None, "subject": row["subject"] if row else "",
                     "sent_count": sum(1 for r in db.list_outreach_log(prospect["id"]) if r["step"] == spec["step"] and r["direction"] == "out" and r["status"] == "sent")})
    return plan


def stop_outreach(prospect_id: int, *, opted_out: bool = False) -> None:
    fields = {"outreach_status": "opted_out" if opted_out else "stopped", "outreach_next_at": None}
    if opted_out:
        fields["opted_out_at"] = db.now_iso()
    db.set_prospect_outreach(prospect_id, **fields)


def opt_out(token: str) -> Optional["db.sqlite3.Row"]:
    prospect_id = resolve_program_token(token)
    if prospect_id is None:
        return None
    stop_outreach(prospect_id, opted_out=True)
    return db.get_partner_prospect(prospect_id)


# ------------------------------------------------------------ application --


def apply(*, name: str, email: str, organization: str, platforms: str, application: str, handles: str = "") -> int:
    name = (name or "").strip(); email = (email or "").strip().lower()
    if len(name) < 2:
        raise PartnerError("name", "Please tell us your name.")
    if "@" not in email or "." not in email.split("@")[-1]:
        raise PartnerError("email", "That doesn't look like an email address.")
    if len((application or "").strip()) < 20:
        raise PartnerError("application", "Tell us a little about your audience — a sentence or two is plenty.")
    existing = db.get_promoter_by_email(email)
    if existing is not None:
        if existing["status"] == "applied":
            raise PartnerError("duplicate", "We already have an application from this address — we'll be in touch soon.")
        if existing["status"] in ("approved", "active"):
            raise PartnerError("duplicate", "You're already a partner. Sign in to the portal instead.")
    pid = db.create_partner_application(name=name, email=email, organization=organization or "", platforms=platforms or "", application=application, handles=handles or "")
    db.mark_prospect_applied(email)
    try:
        email_sender.send_partner_applied_email(to_email=email, partner_name=name)
    except email_sender.EmailSendError:
        pass
    return pid


def founding_seats_left() -> int:
    return max(0, FOUNDING_LIMIT - db.count_founding_partners())


def approve(promoter_id: int, *, tier: str, share_pct: Optional[float], code: str, window_days: int = BOUNTY_WINDOW_DAYS, notes: str = "") -> int:
    """Approval (spec §8): tier, rate, the bounty window from today, and the
    partner's first code with the audience offer (30-day trial, 10 proofs,
    24-month term). Sends the welcome email with a portal link. Returns
    the new promotion id."""
    p = db.get_promoter(promoter_id)
    if p is None:
        raise PartnerError("missing", "That partner doesn't exist.")
    if tier not in ("founding", "standard"):
        raise PartnerError("tier", "Tier is founding or standard.")
    if tier == "founding" and p["tier"] != "founding" and founding_seats_left() <= 0:
        raise PartnerError("founding_full", f"All {FOUNDING_LIMIT} founding seats are taken — approve as a standard partner.")
    share = float(share_pct) if share_pct is not None else (FOUNDING_SHARE if tier == "founding" else STANDARD_SHARE)
    if not (0 < share <= 100):
        raise PartnerError("share", "The revenue share must be between 0 and 100.")
    today = _now().date()
    fields = dict(status="active", tier=tier)
    if not p["approved_at"]:
        fields["approved_at"] = db.now_iso()
    if tier == "founding" and window_days > 0 and not p["bounty_window_start"]:
        fields["bounty_window_start"] = today.isoformat()
        fields["bounty_window_end"] = (today + timedelta(days=window_days)).isoformat()
    db.update_partner_fields(promoter_id, **fields)
    db.update_promoter(promoter_id, name=p["name"], email=p["email"], organization=p["organization"], default_share_pct=share, notes=(p["notes"] + ("\n" if p["notes"] and notes else "") + notes).strip(), active=True)
    promotion_id = promotions.create_promotion(
        code=code, kind="promoter", promoter_id=promoter_id, percent_off=0, duration_months=None, share_pct=share,
        trial_days=OFFER_TRIAL_DAYS, proofs_extra=max(0, OFFER_PROOFS - config.PROOFS_FREE_PROOFS), commission_months=COMMISSION_MONTHS,
        notes="Partner Program launch code",
    )
    promo = db.get_promotion(promotion_id)
    try:
        email_sender.send_partner_welcome_email(to_email=p["email"], partner_name=p["name"], code=promo["code"], link=link_url(promo["code"]),
                                               portal_link=create_portal_link(promoter_id), tier=tier_label(db.get_promoter(promoter_id)), share_pct=share)
    except email_sender.EmailSendError:
        pass
    return promotion_id


def decline(promoter_id: int, *, note: str = "") -> None:
    p = db.get_promoter(promoter_id)
    if p is None:
        raise PartnerError("missing", "That partner doesn't exist.")
    db.update_partner_fields(promoter_id, status="closed")
    if note:
        db.update_promoter(promoter_id, name=p["name"], email=p["email"], organization=p["organization"], default_share_pct=p["default_share_pct"],
                           notes=(p["notes"] + "\n" + note).strip(), active=False)
    else:
        db.update_promoter(promoter_id, name=p["name"], email=p["email"], organization=p["organization"], default_share_pct=p["default_share_pct"], notes=p["notes"], active=False)
    try:
        email_sender.send_partner_declined_email(to_email=p["email"], partner_name=p["name"])
    except email_sender.EmailSendError:
        pass


# --------------------------------------------- code requests (portal §7) --

RESERVED_CODES = {"PIPERSTITCH", "PIPER", "STITCH", "ADMIN", "SUPPORT", "PROOFS", "FREE", "TRIAL", "OFFICIAL", "SALE", "DISCOUNT", "COUPON"}


def check_requested_code(promoter, code: str) -> str:
    """The house rules for a partner's own code: the same shape every
    code has, theirs to recognise, not ours to be confused with, and not
    already taken. Returns the normalised code or raises."""
    code = promotions.normalize_code(code)
    if not promotions.CODE_RE.match(code):
        raise PartnerError("code", "Codes are 3-30 letters, numbers or dashes, starting with a letter or number.")
    if code in RESERVED_CODES or code.startswith("PIPERSTITCH"):
        raise PartnerError("code", "That one's too close to our own name — try your name, your channel, or a word your audience knows you by.")
    if db.get_promotion_by_code(code) is not None:
        raise PartnerError("code", f"{code} is already taken. Try adding your channel to it, like {code}-YT.")
    if len(db.list_code_requests(promoter_id=promoter["id"], status="pending")) >= 3:
        raise PartnerError("pending", "You've three requests waiting already — we'll get to those first.")
    return code


def request_code(promoter, *, code: str, reason: str) -> int:
    """A partner asking for another code from the portal. It is a request,
    not a code: we approve the ones that fit (§7)."""
    code = check_requested_code(promoter, code)
    request_id = db.create_code_request(promoter_id=promoter["id"], requested_code=code, reason=reason)
    return request_id


def approve_code_request(request_id: int, *, code: str = "", note: str = "") -> int:
    """Creates the code on the partner's own terms -- their rate, and the
    same audience offer their first code carries -- and tells them."""
    req = db.get_code_request(request_id)
    if req is None or req["status"] != "pending":
        raise PartnerError("missing", "That request has already been dealt with.")
    promoter = db.get_promoter(req["promoter_id"])
    code = promotions.normalize_code(code or req["requested_code"])
    existing = db.partner_code_stats(promoter["id"])
    share = float(existing[0]["share_pct"]) if existing else float(promoter["default_share_pct"] or (FOUNDING_SHARE if promoter["tier"] == "founding" else STANDARD_SHARE))
    promotion_id = promotions.create_promotion(
        code=code, kind="promoter", promoter_id=promoter["id"], percent_off=0, duration_months=None, share_pct=share,
        trial_days=OFFER_TRIAL_DAYS, proofs_extra=max(0, OFFER_PROOFS - config.PROOFS_FREE_PROOFS), commission_months=COMMISSION_MONTHS,
        notes=f"Requested from the portal: {req['reason']}".strip(),
    )
    db.decide_code_request(request_id, status="approved", note=note, promotion_id=promotion_id)
    try:
        email_sender.send_partner_code_ready_email(to_email=promoter["email"], partner_name=promoter["name"], code=code, link=link_url(code), reason=req["reason"])
    except email_sender.EmailSendError:
        pass
    return promotion_id


def decline_code_request(request_id: int, *, note: str) -> None:
    req = db.get_code_request(request_id)
    if req is None or req["status"] != "pending":
        raise PartnerError("missing", "That request has already been dealt with.")
    db.decide_code_request(request_id, status="declined", note=note)
    promoter = db.get_promoter(req["promoter_id"])
    try:
        email_sender.send_partner_code_declined_email(to_email=promoter["email"], partner_name=promoter["name"], code=req["requested_code"], note=note)
    except email_sender.EmailSendError:
        pass


def submit_feedback(promoter, *, topic: str, message: str) -> int:
    """Partners use PiperStitch daily and talk to the people who haven't
    bought yet -- what they notice is worth more than a survey."""
    if len((message or "").strip()) < 10:
        raise PartnerError("message", "Tell us a little more — a sentence or two is plenty.")
    feedback_id = db.add_partner_feedback(promoter_id=promoter["id"], topic=topic, message=message)
    try:
        email_sender.send_plain_email(
            to_email=config.REPLY_TO_EMAIL,
            subject=f"Partner feedback from {promoter['name']}" + (f": {topic.strip()}" if topic.strip() else ""),
            body=f"{promoter['name']} ({promoter['email']}) sent this from the partner portal:\n\n{message.strip()}\n\n{config.PUBLIC_BASE_URL}/admin/promoters/{promoter['id']}",
            reply_to=promoter["email"] or "")
    except email_sender.EmailSendError:
        pass
    return feedback_id


# ------------------------------------------------------------ the numbers --


def bounty_state(promoter, *, today: Optional[date] = None) -> dict:
    """What the portal's second panel says: days left of the window, or
    progress toward reinstatement, or 'restored'."""
    today = today or _now().date()
    start, end = _date(promoter["bounty_window_start"]), _date(promoter["bounty_window_end"])
    active = db.count_active_referrals(promoter["id"])
    if promoter["bounty_reinstated_at"]:
        return {"state": "restored", "active": active, "since": promoter["bounty_reinstated_at"][:10]}
    if start and end and start <= today <= end:
        return {"state": "open", "days_left": (end - today).days, "ends": end.isoformat(), "total_days": (end - start).days, "active": active}
    if end and today > end:
        return {"state": "closed", "ended": end.isoformat(), "active": active, "needed": REINSTATE_AT, "remaining": max(0, REINSTATE_AT - active)}
    return {"state": "none", "active": active, "needed": REINSTATE_AT, "remaining": max(0, REINSTATE_AT - active)}


def term_month(referral, *, today: Optional[date] = None) -> Optional[int]:
    """Month N of the commission term for a referral that has paid (1 on
    the first payment's day); None before the first payment."""
    first = _date(referral["first_payment_at"])
    if first is None:
        return None
    today = today or _now().date()
    n = (today.year - first.year) * 12 + (today.month - first.month)
    if today.day < first.day:
        n -= 1
    return max(1, n + 1)


def referral_rows(promoter_id: int, *, today: Optional[date] = None) -> list[dict]:
    today = today or _now().date()
    rows = []
    for r in db.list_referrals_for_partner(promoter_id):
        months = int(r["commission_months"] or COMMISSION_MONTHS)
        month = term_month(r, today=today)
        ended = _date(r["term_ends_at"])
        if r["first_payment_at"] is None:
            status = "trial" if (r["subscription_status"] in ("trialing", "active", "comp")) else ("gone" if r["subscription_status"] in ("canceled", "unpaid", "incomplete_expired") else "trial")
        elif ended and today >= ended:
            status = "term complete"
        elif r["subscription_status"] in ("active", "trialing", "comp"):
            status = "subscribed"
        elif r["subscription_status"] == "past_due":
            status = "payment due"
        else:
            status = "cancelled"
        rows.append({
            "id": r["id"], "signed_up": (r["redeemed_at"] or "")[:10], "first_payment": (r["first_payment_at"] or "")[:10], "code": r["code"], "source": r["attribution_source"],
            "status": status, "month": min(month, months) if month else None, "months": months, "earned_cents": r["earned_cents"], "bounty": bool(r["bounty_payout_id"]),
        })
    return rows


def next_payout_date(today: Optional[date] = None) -> date:
    """Monthly, net-30: what was earned in month M is paid at the end of
    month M+1. The next payout is the last day of next month."""
    today = today or _now().date()
    first_of_after_next = (today.replace(day=1) + timedelta(days=62)).replace(day=1)
    return first_of_after_next - timedelta(days=1)


def dashboard(promoter) -> dict:
    today = _now().date()
    totals = db.promoter_totals(promoter["id"])
    codes = [dict(c, link=link_url(c["code"]), perks=promotions.describe(c)) for c in db.partner_code_stats(promoter["id"])]
    return {
        "promoter": promoter, "tier_label": tier_label(promoter), "codes": codes, "bounty": bounty_state(promoter, today=today), "totals": totals,
        "held_under_minimum": totals["payable_cents"] > 0 and totals["payable_cents"] < PAYOUT_MINIMUM_CENTS,
        "minimum_cents": PAYOUT_MINIMUM_CENTS, "next_payout": next_payout_date(today), "referrals": referral_rows(promoter["id"], today=today),
        "statements": db.partner_statement_periods(promoter["id"]), "payments": db.list_promoter_payments(promoter["id"]),
        "tax_form_missing": not promoter["tax_form_received_at"],
        "disclosure_approved": DISCLOSURE_APPROVED, "disclosure_inadequate": DISCLOSURE_INADEQUATE, "claims_approved": CLAIMS_APPROVED, "claims_forbidden": CLAIMS_FORBIDDEN,
        "resources": db.list_partner_resources(active_only=True), "code_requests": db.list_code_requests(promoter_id=promoter["id"]),
        "feedback": db.list_partner_feedback(promoter_id=promoter["id"], limit=10),
        "captions": [c.replace("{link}", codes[0]["link"] if codes else link_url("YOURCODE")) for c in CAPTION_DRAFTS],
    }


def run_payouts(promoter_ids: list[int], *, paid_at: str, note: str = "", now: Optional[str] = None) -> list[dict]:
    """A payout run (spec §8): pays each ticked partner their payable
    balance, skipping anyone the preview excludes (under $50, no tax
    form, no PayPal email, suspended) even if ticked -- the exclusions
    are hard rules, not suggestions. Records the payment through the
    existing ledger (it lands on the P&L too) and emails a receipt with
    the month's statement attached. Returns what happened per partner."""
    preview = {row["promoter"]["id"]: row for row in db.payout_run_preview(now=now)}
    period = paid_at[:7]
    results = []
    for pid in promoter_ids:
        row = preview.get(pid)
        if row is None:
            continue
        if not row["eligible"]:
            results.append({"promoter": row["promoter"], "paid_cents": 0, "skipped": ", ".join(row["reasons"])})
            continue
        amount = row["totals"]["payable_cents"]
        label = note.strip() or f"Payout run {period}"
        db.record_promoter_payment(promoter_id=pid, amount_cents=amount, paid_at=paid_at, note=label)
        p = row["promoter"]
        try:
            email_sender.send_partner_paid_email(to_email=p["email"], partner_name=p["name"], amount=f"${amount / 100:,.2f}", paid_at=paid_at, method=p["payout_method"],
                                                 payout_email=p["payout_email"], attachments=[(f"piperstitch-partner-statement-{period}.csv", statement_csv(p, period).encode(), "text/csv")])
        except email_sender.EmailSendError:
            pass
        results.append({"promoter": p, "paid_cents": amount, "skipped": ""})
    return results


def ledger_csv(rows) -> str:
    out = io.StringIO()
    w = csv.writer(out)
    w.writerow(["Date", "Partner", "Kind", "Code", "Customer", "Invoice", "Invoice paid", "Base (gross)", "Fee", "Net", "Rate", "Amount", "Reverses", "Note"])
    for r in rows:
        w.writerow([r["created_at"][:19], r["promoter_name"], r["kind"], r["code"], r["customer_email"] or "", r["stripe_invoice_id"] or "", (r["invoice_paid_at"] or "")[:10],
                    f"{r['gross_cents'] / 100:.2f}" if r["kind"] == "recurring" else "", f"{r['fee_cents'] / 100:.2f}" if r["kind"] == "recurring" else "",
                    f"{r['net_cents'] / 100:.2f}" if r["kind"] == "recurring" else "", f"{r['share_pct']:g}%" if r["kind"] == "recurring" else "",
                    f"{r['share_cents'] / 100:.2f}", r["reverses_payout_id"] or "", r["note"] or ""])
    return out.getvalue()


NEC_THRESHOLD_CENTS = 600_00


def tax_report(year: int) -> list[dict]:
    """Per partner, what was paid in the year and whether a 1099-NEC is
    due: US persons (W-9) paid $600 or more (§10.2)."""
    out = []
    for r in db.payments_by_promoter_for_year(year):
        us = (r["tax_form_type"] or "") == "w9"
        out.append({**dict(r), "us": us, "nec_due": us and r["paid_cents"] >= NEC_THRESHOLD_CENTS, "over_threshold": r["paid_cents"] >= NEC_THRESHOLD_CENTS})
    return out


def tax_report_csv(year: int) -> str:
    out = io.StringIO()
    w = csv.writer(out)
    w.writerow(["Year", "Partner", "Email", "Payout email", "Tax form", "Form received", "Paid", "Payments", "1099-NEC due"])
    for r in tax_report(year):
        w.writerow([year, r["name"], r["email"], r["payout_email"], (r["tax_form_type"] or "").upper(), (r["tax_form_received_at"] or "")[:10], f"{r['paid_cents'] / 100:.2f}", r["payments"],
                    "yes" if r["nec_due"] else ("non-US" if r["over_threshold"] and not r["us"] else "no")])
    return out.getvalue()


def alerts() -> dict:
    return {"events": db.partner_alert_events(), "webhooks": db.list_failed_stripe_events(), "spikes": db.conversion_spikes(), "unchecked_content": db.count_unchecked_content()}


def statement_csv(promoter, period: str) -> str:
    """A month's ledger as CSV: kind, date, code, base, rate, share. Rows
    carry no customer identity."""
    out = io.StringIO()
    w = csv.writer(out)
    w.writerow(["Statement for", promoter["name"], period])
    w.writerow(["Date", "Kind", "Code", "Invoice amount", "Rate", "Amount", "Note"])
    total = 0
    for r in db.partner_statement_rows(promoter["id"], period):
        base = f"{r['gross_cents'] / 100:.2f}" if r["kind"] == "recurring" else ""
        rate = f"{r['share_pct']:g}%" if r["kind"] == "recurring" else ""
        w.writerow([r["created_at"][:10], r["kind"], r["code"], base, rate, f"{r['share_cents'] / 100:.2f}", r["note"] or ""])
        total += r["share_cents"]
    w.writerow([]); w.writerow(["Total", "", "", "", "", f"{total / 100:.2f}", ""])
    return out.getvalue()


def qr_svg(url: str) -> Optional[str]:
    """The link as a QR code, or None if the QR library isn't installed."""
    try:
        import segno
    except ImportError:
        return None
    buf = io.BytesIO()
    segno.make(url, error="m").save(buf, kind="svg", scale=6, border=2, dark="#0f2a4d", xmldecl=False, svgclass=None, lineclass=None)
    return buf.getvalue().decode()
