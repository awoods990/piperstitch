"""Link attribution for the Partner Program (spec §5.2, §5.3, §9).

A partner's link is `/r/<CODE>`. Landing on it logs a click (IP hashed,
never stored), sets a signed `ps_ref` cookie for the whole piperstitch.com
family (90 days) and shows the partner's own landing page -- or, with
`?to=`, sends the visitor on to a marketing page. Nobody can mint a cookie
without the server's secret, and a tampered one is simply ignored.

At trial start the cookie (or a typed code, which always wins -- R8) turns
into a *provisional* redemption on the customer: the perks (a longer
trial, extra proofs) apply at once, and when the first payment lands the
existing promotion webhook path locks the attribution (R3). Only ever one
promoter per customer (R9): while unlocked the latest touch wins.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import re
from datetime import datetime, timedelta, timezone
from typing import Optional

from . import config, db, promotions

COOKIE_NAME = "ps_ref"
COOKIE_DAYS = 90
SAFE_PATH = re.compile(r"^/[A-Za-z0-9\-_/]*(\.html)?$")


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds").replace("+00:00", "Z")


def _secret() -> bytes:
    return (config.REFERRAL_SECRET or config.SESSION_SECRET or "development-only").encode()


def _sign(payload: str) -> str:
    return hmac.new(_secret(), payload.encode(), hashlib.sha256).hexdigest()[:32]


def cookie_value(promotion_id: int, at: Optional[datetime] = None) -> str:
    payload = f"{int(promotion_id)}|{_iso(at or _now())}"
    return f"{payload}|{_sign(payload)}"


def cookie_domain() -> str:
    """`.piperstitch.com` in production so www, app, proofs and admin all
    see it; empty (host-only) on localhost / bare IPs."""
    if config.REFERRAL_COOKIE_DOMAIN:
        return config.REFERRAL_COOKIE_DOMAIN
    host = re.sub(r"^https?://", "", config.PUBLIC_BASE_URL).split("/")[0].split(":")[0]
    parts = host.split(".")
    if len(parts) < 2 or host == "localhost" or re.match(r"^[\d.]+$", host):
        return ""
    return "." + ".".join(parts[-2:])


def resolve_cookie(value: Optional[str]) -> Optional["db.sqlite3.Row"]:
    """The promotion a `ps_ref` cookie points at, if the signature holds,
    it is under 90 days old, and the code is still usable."""
    if not value:
        return None
    try:
        pid, ts, sig = value.split("|", 2)
    except ValueError:
        return None
    if not hmac.compare_digest(sig, _sign(f"{pid}|{ts}")):
        return None
    try:
        when = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    if _now() - when > timedelta(days=COOKIE_DAYS) or when > _now() + timedelta(minutes=5):
        return None
    try:
        promo = db.get_promotion(int(pid))
    except (TypeError, ValueError):
        return None
    if promo is None or not promo["active"]:
        return None
    try:
        return promotions.validate(promo["code"])
    except promotions.PromoError:
        return None


def record_click(promotion_id: int, *, ip: str, user_agent: str, landing_path: str) -> int:
    ip_hash = hashlib.sha256((ip or "").encode() + _secret()).hexdigest()[:24] if ip else ""
    return db.record_referral_click(promotion_id=promotion_id, ip_hash=ip_hash, user_agent=(user_agent or "")[:200], landing_path=(landing_path or "")[:200])


def safe_path(to: Optional[str]) -> Optional[str]:
    """A marketing-site path a partner may send someone to; anything else
    (another host, a scheme, odd characters) is ignored."""
    if not to or not SAFE_PATH.match(to) or "//" in to:
        return None
    return to


def resolve_for_signup(*, typed_code: str = "", cookie: Optional[str] = None, email: str = "") -> tuple[Optional["db.sqlite3.Row"], str]:
    """The promotion attributing a signup and where it came from (R8: a
    typed code beats the cookie). A bad typed code raises the same
    PromoError the checkout path shows; a bad cookie is just ignored."""
    if typed_code and typed_code.strip():
        return promotions.validate(typed_code, email=email), "code"
    promo = resolve_cookie(cookie)
    return (promo, "link") if promo is not None else (None, "")


def self_referral(promo, email: str) -> bool:
    """R10: a promoter can't earn on their own account."""
    if promo is None or not promo["promoter_id"]:
        return False
    promoter = db.get_promoter(promo["promoter_id"])
    if promoter is None:
        return False
    e = (email or "").strip().lower()
    return bool(e) and e in {(promoter["email"] or "").strip().lower(), (promoter["payout_email"] or "").strip().lower()}


def attribute_customer(customer_id: int, promo, *, source: str, subscription_id: Optional[int] = None) -> Optional[int]:
    """A provisional (unlocked) redemption for this customer -- the latest
    touch wins until first payment locks it. Applies the perks the code
    carries. Returns the redemption id, or None when nothing changed."""
    if promo is None:
        return None
    customer = db.get_customer(customer_id)
    if customer is None:
        return None
    if promo["promoter_id"] and self_referral(promo, customer["email"]):
        db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="promo_self_referral",
                     detail=f"Code {promo['code']} belongs to this person's own promoter account -- not attributed.")
        return None
    if promo["promoter_id"]:
        promoter = db.get_promoter(promo["promoter_id"])
        if promoter is None or promoter["status"] not in ("active", "approved") or not promoter["active"]:
            db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="promo_inactive_promoter",
                         detail=f"Code {promo['code']} belongs to a promoter who isn't active -- not attributed.")
            return None
    redemption_id = db.attribute_customer(promotion_id=promo["id"], customer_id=customer_id, subscription_id=subscription_id, source=source)
    if redemption_id is None:
        return None
    # Perks: extra proofs (max, never stacked -- §9).
    extra = int(promo["proofs_extra"] or 0)
    if extra and int(customer["proofs_free_extra"] or 0) < extra:
        db.set_proofs_free_extra(customer_id, extra)
    detail = f"Used code {promo['code']} ({promotions.describe(promo)})"
    if promo["promoter_id"]:
        promoter = db.get_promoter(promo["promoter_id"])
        detail += f" — referred by {promoter['name'] if promoter else 'a promoter'}"
    detail += " via link." if source == "link" else "."
    db.add_event(customer_id=customer_id, subscription_id=subscription_id, kind="promo_redeemed", detail=detail)
    return redemption_id


def trial_days_for(promo) -> int:
    if promo is not None and "trial_days" in promo.keys() and promo["trial_days"]:
        return int(promo["trial_days"])
    return config.TRIAL_DAYS


def landing_context(promo) -> dict:
    promoter = db.get_promoter(promo["promoter_id"]) if promo["promoter_id"] else None
    return {
        "code": promo["code"], "promoter": promoter, "perks": promotions.perks(promo), "description": promotions.describe(promo),
        "trial_days": trial_days_for(promo), "proofs": config.PROOFS_FREE_PROOFS + int(promo["proofs_extra"] or 0),
        "app_url": f"{config.WEB_APP_URL}/?trial=1&ref={promo['code']}",
    }


def clicks_json(rows) -> str:
    return json.dumps([dict(r) for r in rows])
