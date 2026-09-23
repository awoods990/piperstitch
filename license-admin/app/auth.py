"""Single-admin password auth. No user table, no roles — one shared
password (its PBKDF2 hash lives in ADMIN_PASSWORD_HASH), a signed session
cookie on success, and an in-memory lockout on repeated failures, the same
shape as the Amerus License Admin this service is modelled on.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
import time
from urllib.parse import quote

from fastapi import HTTPException, Request

from . import config

# PBKDF2-HMAC-SHA256, not scrypt: hashlib.scrypt's availability depends on
# the Python build's underlying OpenSSL having scrypt support at compile
# time (it's silently absent on, e.g., a LibreSSL-linked build) — a bad
# trap for a service meant to run on whatever host you deploy it to.
# PBKDF2 is in every Python build unconditionally. 600,000 iterations
# matches OWASP's 2023 recommendation for PBKDF2-SHA256.
_PBKDF2_ITERATIONS = 600_000
_KEY_LEN = 32

MAX_LOGIN_FAILURES = 8
LOCKOUT_WINDOW_SECONDS = 15 * 60

# {ip: [failure_timestamps]} — process-local, resets on restart. Fine at
# this scale (one admin); a real multi-instance deploy would need this in
# the database instead, same caveat backend/health.py's lockout carries.
_login_failures: dict[str, list[float]] = {}


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, _PBKDF2_ITERATIONS, dklen=_KEY_LEN)
    return f"pbkdf2_sha256${_PBKDF2_ITERATIONS}${salt.hex()}${digest.hex()}"


def verify_password(password: str, stored_hash: str) -> bool:
    try:
        scheme, iterations_str, salt_hex, digest_hex = stored_hash.split("$")
    except ValueError:
        return False
    if scheme != "pbkdf2_sha256":
        return False
    try:
        iterations = int(iterations_str)
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(digest_hex)
    except ValueError:
        return False
    candidate = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations, dklen=len(expected))
    return hmac.compare_digest(candidate, expected)


def _client_ip(request: Request) -> str:
    """Behind Railway every request arrives from the same proxy, so the
    socket address identifies nobody. The forwarded header is what tells
    one caller from another."""
    from . import ratelimit
    return ratelimit.client_ip(request)


def is_locked_out(request: Request) -> bool:
    ip = _client_ip(request)
    now = time.monotonic()
    recent = [t for t in _login_failures.get(ip, []) if now - t < LOCKOUT_WINDOW_SECONDS]
    _login_failures[ip] = recent
    return len(recent) >= MAX_LOGIN_FAILURES


def record_login_failure(request: Request) -> None:
    ip = _client_ip(request)
    _login_failures.setdefault(ip, []).append(time.monotonic())


def clear_login_failures(request: Request) -> None:
    _login_failures.pop(_client_ip(request), None)


def try_login(request: Request, username: str, password: str) -> bool:
    """The password step. With an authenticator configured this only gets
    as far as the second step: the admin session isn't granted until the
    code checks out."""
    if is_locked_out(request):
        return False
    username_ok = hmac.compare_digest(username.encode("utf-8"), config.ADMIN_USERNAME.encode("utf-8"))
    if not username_ok or not config.ADMIN_PASSWORD_HASH or not verify_password(password, config.ADMIN_PASSWORD_HASH):
        record_login_failure(request)
        return False
    clear_login_failures(request)
    if totp_required():
        request.session.pop("admin", None)
        request.session["admin_pending"] = time.time()
        return True
    request.session["admin"] = True
    return True


# ------------------------------------------------- the second step (TOTP) --
# RFC 6238 in twenty lines rather than a dependency: HMAC-SHA1 over the
# 30-second counter, six digits, and a window either side for clocks that
# disagree. What every authenticator app speaks.

TOTP_STEP = 30
TOTP_WINDOW = 1          # ±30 seconds
PENDING_TTL = 300        # five minutes between password and code


def totp_required() -> bool:
    return bool(config.ADMIN_TOTP_SECRET)


def _totp_at(secret: str, counter: int) -> str:
    key = base64.b32decode(secret + "=" * (-len(secret) % 8), casefold=True)
    digest = hmac.new(key, counter.to_bytes(8, "big"), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    code = int.from_bytes(digest[offset:offset + 4], "big") & 0x7FFFFFFF
    return f"{code % 1_000_000:06d}"


def verify_totp(code: str, *, secret: str = "", now: Optional[float] = None) -> bool:
    secret = (secret or config.ADMIN_TOTP_SECRET).replace(" ", "").upper()
    code = (code or "").strip().replace(" ", "")
    if not secret or not code.isdigit() or len(code) != 6:
        return False
    counter = int((now if now is not None else time.time()) // TOTP_STEP)
    return any(hmac.compare_digest(code, _totp_at(secret, counter + drift)) for drift in range(-TOTP_WINDOW, TOTP_WINDOW + 1))


def awaiting_code(request: Request) -> bool:
    started = request.session.get("admin_pending")
    if not started or time.time() - float(started) > PENDING_TTL:
        request.session.pop("admin_pending", None)
        return False
    return True


def try_code(request: Request, code: str) -> bool:
    if is_locked_out(request) or not awaiting_code(request):
        return False
    if not verify_totp(code):
        record_login_failure(request)
        return False
    clear_login_failures(request)
    request.session.pop("admin_pending", None)
    request.session["admin"] = True
    return True


def new_totp_secret() -> str:
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


def totp_uri(secret: str) -> str:
    """What the QR code encodes, for an authenticator app to scan."""
    label = quote(f"PiperStitch admin ({config.ADMIN_USERNAME})")
    return f"otpauth://totp/{label}?secret={secret}&issuer=PiperStitch&digits=6&period={TOTP_STEP}"


def logout(request: Request) -> None:
    request.session.pop("admin", None)


def require_admin(request: Request) -> None:
    """FastAPI dependency — raises 303 to the login page rather than a
    bare 401, since every admin route here is meant to be opened directly
    in a browser, not called as an API."""
    if not request.session.get("admin"):
        raise HTTPException(status_code=303, headers={"Location": "/admin/login"})
