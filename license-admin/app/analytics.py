"""Knowing which channel actually brings people, without following anyone.

You are about to spend money promoting this, and until now nothing
answered "where did that trial come from?". This does, on our own
server, with no third party in the path and nothing that identifies a
person.

How it avoids being surveillance:

* No cookie, no device id, no fingerprint. A visitor is counted as a
  salted one-way digest of address + browser + *today's date*, so the
  same person tomorrow is a different number and nobody -- including us
  -- can work backwards to an address.
* The referrer is reduced to its host: we learn that someone came from
  youtube.com, never which video or search they typed.
* Do Not Track is honoured. It costs us a little data and it is the only
  answer consistent with what we tell people elsewhere.
* Rows are pruned after PRUNE_DAYS; the counts are the point, not the log.

The valuable half is attribution, not traffic: where a *signup* came
from, which is captured once on the customer's own row at first sign-in
and never overwritten.
"""

from __future__ import annotations

import hashlib
import re
from datetime import datetime, timedelta, timezone
from typing import Optional
from urllib.parse import urlparse

from . import config, db

PRUNE_DAYS = 400              # a year and a bit, so year-on-year comparisons exist
SAFE_PATH = re.compile(r"^/[^\s?#]*$")
KNOWN_MEDIUMS = {"", "email", "social", "cpc", "ppc", "referral", "video", "partner", "print", "qr", "organic", "affiliate", "newsletter"}


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _salt() -> bytes:
    return (config.REFERRAL_SECRET or config.SESSION_SECRET or "development-only").encode()


def visitor_hash(*, ip: str, user_agent: str, day: Optional[str] = None) -> str:
    """One number per person per day, and only for that day. Salted with a
    secret we hold, so even someone with the database cannot test whether
    a given address visited."""
    material = b"|".join([_salt(), (day or _today()).encode(), (ip or "").encode(), (user_agent or "")[:200].encode()])
    return hashlib.sha256(material).hexdigest()[:20]


def referrer_host(referrer: str) -> str:
    """The site, not the page. `https://www.youtube.com/watch?v=x` becomes
    `youtube.com` -- enough to credit a channel, not enough to know what
    someone was watching. Our own pages count as direct."""
    if not referrer:
        return ""
    try:
        host = (urlparse(referrer).hostname or "").lower()
    except ValueError:
        return ""
    host = host[4:] if host.startswith("www.") else host
    if not host or host.endswith("piperstitch.com"):
        return ""
    return host[:120]


def clean_path(path: str) -> str:
    """Query strings can carry anything, including an email someone pasted
    into a URL. Only the path is kept."""
    path = (path or "").split("?")[0].split("#")[0]
    if not SAFE_PATH.match(path):
        return "/"
    if len(path) > 1 and path.endswith("/"):
        path = path[:-1]
    return (path or "/")[:200]


def clean_tag(value: str, *, allowed: Optional[set] = None) -> str:
    value = re.sub(r"[^A-Za-z0-9 ._/+-]", "", (value or "").strip().lower())[:80]
    if allowed is not None and value not in allowed:
        return value[:60]
    return value


def record(*, path: str, referrer: str, utm: dict, ip: str, user_agent: str, do_not_track: bool = False) -> bool:
    """One page view. False when we deliberately didn't count it."""
    if do_not_track:
        return False
    db.record_page_view(
        day=_today(), path=clean_path(path), referrer_host=referrer_host(referrer),
        utm_source=clean_tag(utm.get("source", "")), utm_medium=clean_tag(utm.get("medium", ""), allowed=KNOWN_MEDIUMS),
        utm_campaign=clean_tag(utm.get("campaign", "")), visitor_hash=visitor_hash(ip=ip, user_agent=user_agent))
    return True


def since(days: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days - 1)).strftime("%Y-%m-%d")


def overview(days: int = 30) -> dict:
    """What the admin page shows: traffic, where it came from, and -- the
    part that matters -- what it turned into."""
    start = since(days)
    by_day = db.traffic_by_day(since=start)
    totals = db.traffic_totals(since=start)
    sources = db.signups_by_source(since=start + "T00:00:00Z")
    return {
        "days": days, "since": start, "totals": totals, "by_day": by_day,
        "peak": max([r["visitors"] for r in by_day], default=0),
        "pages": db.top_pages(since=start), "referrers": db.top_referrers(since=start), "campaigns": db.top_campaigns(since=start),
        "sources": sources,
        "signups": sum(r["signups"] for r in sources), "subscribed": sum(r["subscribed"] for r in sources),
    }


def prune() -> int:
    return db.prune_page_views(before=(datetime.now(timezone.utc) - timedelta(days=PRUNE_DAYS)).strftime("%Y-%m-%d"))
