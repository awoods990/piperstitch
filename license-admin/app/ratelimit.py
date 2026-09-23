"""Per-IP limits on the handful of endpoints that send email to whoever
asks.

Every one of them is unauthenticated and puts a message in a stranger's
inbox: the sign-in code, the account link, the partner registration and
the application. The existing limits are per *address*, which stops
someone pestering one person but not someone working through a list of
ten thousand — that is a mail bomb sent from our domain, on our Postmark
bill, against our sending reputation.

In-memory on purpose: this service is one process on one volume (SQLite
sees to that), so a dict is honest about what it protects and costs
nothing. If it ever runs as two instances, this wants moving into the
database along with everything else that assumes one.
"""

from __future__ import annotations

import threading
import time
from typing import Optional

from fastapi import Request

# bucket -> (max hits, window in seconds)
LIMITS: dict[str, tuple[int, int]] = {
    "email": (8, 3600),          # one endpoint, one IP: eight emails an hour
    "email_total": (20, 3600),   # ...and twenty across all of them
    "form": (40, 3600),          # non-mailing public form posts
    "track": (240, 3600),        # page views: generous for a real reader, closed to a flood
}

_hits: dict[tuple[str, str], list[float]] = {}
_lock = threading.Lock()


def client_ip(request: Request) -> str:
    """The caller's address as the platform reports it. Railway terminates
    TLS and forwards, so `request.client.host` is the proxy for every
    visitor alike -- keying anything on it would put the whole internet in
    one bucket."""
    forwarded = request.headers.get("x-forwarded-for", "")
    if forwarded:
        return forwarded.split(",")[0].strip()[:60]
    real = request.headers.get("x-real-ip", "")
    if real:
        return real.strip()[:60]
    return (request.client.host if request.client else "unknown")[:60]


def _take(bucket: str, ip: str, now: float) -> bool:
    limit, window = LIMITS[bucket]
    key = (bucket, ip)
    with _lock:
        recent = [t for t in _hits.get(key, []) if now - t < window]
        if len(recent) >= limit:
            _hits[key] = recent
            return False
        recent.append(now)
        _hits[key] = recent
        if len(_hits) > 20_000:                      # a cheap ceiling; the oldest go first
            for stale in [k for k, v in list(_hits.items()) if not v or now - max(v) > 7200][:5000]:
                _hits.pop(stale, None)
        return True


def allow(request: Request, bucket: str = "email") -> bool:
    """True when this caller may proceed. A mailing endpoint counts twice:
    once for itself and once against the per-IP total."""
    now = time.time()
    ip = client_ip(request)
    if bucket == "email":
        return _take("email_total", ip, now) and _take("email", f"{ip}|{request.url.path}", now)
    return _take(bucket, f"{ip}|{request.url.path}", now)


def retry_after(bucket: str = "email") -> int:
    return LIMITS[bucket][1]


def reset(ip: Optional[str] = None) -> None:
    """Tests, and the admin's own escape hatch."""
    with _lock:
        if ip is None:
            _hits.clear()
        else:
            for key in [k for k in _hits if k[1].split("|")[0] == ip]:
                _hits.pop(key, None)
