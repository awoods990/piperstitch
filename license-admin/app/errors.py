"""Knowing when something broke.

There was no answer to "did anyone hit a 500 today?" — the logs scroll
past and nobody reads them at three in the morning. This writes every
unhandled exception (and every crash in the browser app) to a table,
grouped so a storm is one row with a count, and emails when a *new* one
appears. First occurrence only: an outage should be one message, not ten
thousand.

It is deliberately not a third-party service. One table, one page in the
admin, no account to keep and nothing leaving the box. If the volume
ever justifies Sentry, this is the seam to replace.
"""

from __future__ import annotations

import hashlib
import logging
import traceback
from typing import Optional

from . import config, db, email_sender

log = logging.getLogger("license_admin.errors")

MAX_ALERTS_PER_HOUR = 6
_alerts: list[float] = []


def _fingerprint(*parts: str) -> str:
    return hashlib.sha256("|".join(p or "" for p in parts).encode()).hexdigest()[:32]


def _may_alert() -> bool:
    """Even new errors get a ceiling: a bad deploy produces a great many
    kinds of new error at once, and an inbox full of them helps nobody."""
    import time

    now = time.time()
    _alerts[:] = [t for t in _alerts if now - t < 3600]
    if len(_alerts) >= MAX_ALERTS_PER_HOUR:
        return False
    _alerts.append(now)
    return True


def capture(exc: BaseException, *, where: str, source: str = "server") -> None:
    kind = type(exc).__name__
    message = str(exc)[:500]
    detail = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))[-4000:]
    # The line it came from, not the message: two failures of the same
    # shape with different ids are one problem.
    frames = traceback.extract_tb(exc.__traceback__)
    origin = f"{frames[-1].filename}:{frames[-1].lineno}" if frames else where
    _store(fingerprint=_fingerprint(source, kind, origin), source=source, kind=kind, message=message, where=where, detail=detail)


def capture_browser(*, name: str, message: str, page: str, stack: str) -> None:
    _store(fingerprint=_fingerprint("browser", name, (stack or message).split("\n")[0][:200]),
           source="browser", kind=name or "Error", message=message, where=page, detail=stack)


def _store(*, fingerprint: str, source: str, kind: str, message: str, where: str, detail: str) -> None:
    try:
        first = db.record_error(fingerprint=fingerprint, source=source, kind=kind, message=message, where=where, detail=detail)
    except Exception as e:  # noqa: BLE001 - never let the error handler be the error
        log.error("Could not record an error (%s: %s): %s", kind, message, e)
        return
    if not first or not _may_alert():
        return
    try:
        email_sender.send_plain_email(
            to_email=config.REPLY_TO_EMAIL,
            subject=f"PiperStitch: {kind} in {where}"[:120],
            body=(f"A new kind of failure, {'in the browser app' if source == 'browser' else 'on the server'}:\n\n"
                  f"{kind}: {message}\n\nWhere: {where}\n\n{detail[:1500]}\n\n"
                  f"All of them: {config.PUBLIC_BASE_URL}/admin/errors"))
    except email_sender.EmailSendError as e:
        log.warning("Could not email about %s: %s", kind, e)


def reset_alert_window() -> None:
    _alerts.clear()
