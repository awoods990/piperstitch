"""The Partner Program's people-facing half (spec §7, §8, §10): the
application, approval, the portal's sign-in links and the numbers the
portal shows. Money itself is computed in promotions.py and db.py; this
module only reads it.

The portal never sees a customer's identity -- a referral is a date, a
status, a month count and a number (§7, §10.3).
"""

from __future__ import annotations

import csv
import hashlib
import io
import secrets
from datetime import date, datetime, timedelta, timezone
from typing import Optional

from . import config, db, email_sender, promotions

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


# ------------------------------------------------------------ application --


def apply(*, name: str, email: str, organization: str, platforms: str, application: str) -> int:
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
    pid = db.create_partner_application(name=name, email=email, organization=organization or "", platforms=platforms or "", application=application)
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
        "captions": [c.replace("{link}", codes[0]["link"] if codes else link_url("YOURCODE")) for c in CAPTION_DRAFTS],
    }


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
