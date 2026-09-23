"""Backups that survive losing the platform.

The failure this is written against is not "someone deleted a row" — it
is "Railway is gone, with the volume and the snapshots on it". Anything
kept on the same platform as the thing it protects is not a backup of
that platform; it is a second copy of the same risk.

So: every night this builds one archive holding a consistent dump of the
database and a manifest describing it, and puts that archive in an
S3-compatible bucket belonging to somebody else — Backblaze B2,
Cloudflare R2, AWS, whichever. It then reads back what it wrote and
checks the size and digest match, because an upload nobody verified is a
belief rather than a backup. A weekly note says what is there; a failure
says so at once.

Signing is done here rather than with boto3: the whole AWS SDK to make
one PUT a night is a poor trade, and SigV4 is sixty lines. The algorithm
is exercised against Amazon's published test vector in the tests.

With no bucket configured nothing is lost quietly: the service says it
is unprotected on its Security page and emails a weekly reminder to take
one by hand.
"""

from __future__ import annotations

import hashlib
import hmac
import io
import json
import logging
import tarfile
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional
from urllib.parse import quote

import httpx

from . import config, db, email_sender

log = logging.getLogger("license_admin.backups")

SERVICE = "license-admin"
DAILY_KEEP = 30          # a month of nights...
MONTHLY_KEEP = 12        # ...and the first of each month for a year
TIMEOUT = 120.0


# ----------------------------------------------------------- the archive --


def build_archive() -> tuple[bytes, dict]:
    """One .tar.gz: the database, consistent, plus a manifest saying what
    it is and what it should weigh. Returns the bytes and the manifest."""
    with tempfile.TemporaryDirectory() as work:
        dump = Path(work) / "license_admin.sqlite3"
        size = db.backup_to(str(dump))
        digest = hashlib.sha256(dump.read_bytes()).hexdigest()
        counts = db.customer_data_counts()
        manifest = {
            "service": SERVICE,
            "taken_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "database_bytes": size,
            "database_sha256": digest,
            "row_counts": counts,
            "restore": "Unpack, put license_admin.sqlite3 at DATABASE_PATH, deploy the service from GitHub, set the variables listed in DEPLOY.md.",
        }
        out = io.BytesIO()
        with tarfile.open(fileobj=out, mode="w:gz") as tar:
            tar.add(dump, arcname="license_admin.sqlite3")
            info = tarfile.TarInfo("manifest.json")
            body = json.dumps(manifest, indent=2).encode()
            info.size = len(body)
            tar.addfile(info, io.BytesIO(body))
        return out.getvalue(), manifest


# --------------------------------------------------------- the signature --


def _sign(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode(), hashlib.sha256).digest()


def signing_key(secret: str, date: str, region: str, service: str = "s3") -> bytes:
    return _sign(_sign(_sign(_sign(f"AWS4{secret}".encode(), date), region), service), "aws4_request")


def authorization(*, method: str, host: str, path: str, payload_sha: str, now: datetime,
                  access_key: str, secret_key: str, region: str, query: str = "", extra_headers: Optional[dict] = None) -> dict:
    """AWS Signature Version 4 for one request. Returns the headers to
    send, including the Authorization line. `extra_headers` are signed
    along with the rest, which is what lets the tests check this against
    Amazon's own published example."""
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    date = now.strftime("%Y%m%d")
    headers = {"host": host, "x-amz-content-sha256": payload_sha, "x-amz-date": stamp}
    headers.update({k.lower(): v for k, v in (extra_headers or {}).items()})
    canonical_headers = "".join(f"{k}:{headers[k]}\n" for k in sorted(headers))
    signed_headers = ";".join(sorted(headers))
    canonical_request = "\n".join([method, path, query, canonical_headers, signed_headers, payload_sha])
    scope = f"{date}/{region}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", stamp, scope, hashlib.sha256(canonical_request.encode()).hexdigest()])
    signature = hmac.new(signing_key(secret_key, date, region), to_sign.encode(), hashlib.sha256).hexdigest()
    return {
        "Authorization": f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={signed_headers}, Signature={signature}",
        "x-amz-content-sha256": payload_sha,
        "x-amz-date": stamp,
    }


# ------------------------------------------------------------ the bucket --


def configured() -> bool:
    return bool(config.BACKUP_BUCKET and config.BACKUP_ACCESS_KEY and config.BACKUP_SECRET_KEY and config.BACKUP_ENDPOINT)


def _endpoint() -> tuple[str, str]:
    """(scheme://host, host) for the configured S3-compatible service."""
    endpoint = config.BACKUP_ENDPOINT.rstrip("/")
    if not endpoint.startswith("http"):
        endpoint = "https://" + endpoint
    return endpoint, endpoint.split("://", 1)[1]


def _request(method: str, key: str, *, body: bytes = b"", query: str = "") -> httpx.Response:
    """Path-style (`host/bucket/key`) suits Backblaze, R2, Spaces and
    Wasabi; AWS has deprecated it for newer buckets and wants the bucket
    in the hostname instead. BACKUP_PATH_STYLE=false picks the latter, so
    the choice of provider stays yours."""
    base, host = _endpoint()
    if config.BACKUP_PATH_STYLE:
        path = f"/{config.BACKUP_BUCKET}/{quote(key)}" if key else f"/{config.BACKUP_BUCKET}"
    else:
        host = f"{config.BACKUP_BUCKET}.{host}"
        base = base.split("://", 1)[0] + "://" + host
        path = f"/{quote(key)}" if key else "/"
    payload_sha = hashlib.sha256(body).hexdigest()
    headers = authorization(method=method, host=host, path=path, payload_sha=payload_sha, now=datetime.now(timezone.utc),
                            access_key=config.BACKUP_ACCESS_KEY, secret_key=config.BACKUP_SECRET_KEY, region=config.BACKUP_REGION, query=query)
    url = f"{base}{path}" + (f"?{query}" if query else "")
    with httpx.Client(timeout=TIMEOUT) as client:
        return client.request(method, url, content=body if body else None, headers=headers)


def put(key: str, body: bytes) -> None:
    r = _request("PUT", key, body=body)
    if r.status_code not in (200, 201):
        raise RuntimeError(f"Upload refused ({r.status_code}): {r.text[:200]}")


def head(key: str) -> Optional[int]:
    r = _request("HEAD", key)
    return int(r.headers.get("content-length", 0)) if r.status_code == 200 else None


def get(key: str) -> bytes:
    r = _request("GET", key)
    if r.status_code != 200:
        raise RuntimeError(f"Could not read back ({r.status_code}): {r.text[:200]}")
    return r.content


def canonical_query(params: dict) -> str:
    """SigV4 signs the query string *sorted by parameter name*, so the
    order we happen to write them in is not a detail -- get it wrong and
    the request is rejected as SignatureDoesNotMatch, which is what
    happened the first time this ran against a real bucket."""
    return "&".join(f"{quote(k, safe='')}={quote(str(v), safe='')}" for k, v in sorted(params.items()))


def listing(prefix: str = "") -> list[str]:
    r = _request("GET", "", query=canonical_query({"list-type": 2, "prefix": prefix, "max-keys": 1000}))
    if r.status_code != 200:
        raise RuntimeError(f"Could not list ({r.status_code}): {r.text[:200]}")
    import re

    return re.findall(r"<Key>([^<]+)</Key>", r.text)


def delete(key: str) -> None:
    _request("DELETE", key)


# -------------------------------------------------------------- the run --


def key_for(when: datetime) -> str:
    return f"{SERVICE}/{when:%Y}/{SERVICE}-{when:%Y-%m-%d-%H%M}.tar.gz"


def prune(now: Optional[datetime] = None) -> int:
    """A month of nights, and the first of each month for a year."""
    now = now or datetime.now(timezone.utc)
    keys = sorted(k for k in listing(f"{SERVICE}/") if k.endswith(".tar.gz"))
    keep = set(keys[-DAILY_KEEP:])
    by_month: dict[str, str] = {}
    for key in keys:
        stamp = key.rsplit("-", 3)[-3:]
        month = "-".join(stamp[:2]) if len(stamp) == 3 else ""
        if month and month not in by_month:
            by_month[month] = key
    keep |= set(list(by_month.values())[-MONTHLY_KEEP:])
    removed = 0
    for key in keys:
        if key not in keep:
            delete(key)
            removed += 1
    return removed


def run(*, verify: bool = True) -> dict:
    """Build, upload, read back, record. The read-back is the point: an
    upload nobody checked is a belief, not a backup."""
    started = datetime.now(timezone.utc)
    if not configured():
        db.record_backup(service=SERVICE, key="", size_bytes=0, digest="", status="unconfigured",
                         detail="No off-platform bucket is configured; nothing has been copied anywhere.")
        return {"ok": False, "reason": "unconfigured"}
    try:
        archive, manifest = build_archive()
        key = key_for(started)
        put(key, archive)
        if verify:
            there = head(key)
            if there != len(archive):
                raise RuntimeError(f"Read back {there} bytes, sent {len(archive)}")
            if hashlib.sha256(get(key)).hexdigest() != hashlib.sha256(archive).hexdigest():
                raise RuntimeError("What came back is not what went up")
        try:
            removed = prune(started)
        except Exception as e:  # noqa: BLE001 - tidying old copies is not the backup
            log.warning("Backup uploaded and verified, but pruning old copies failed: %s", e)
            removed = -1
        db.record_backup(service=SERVICE, key=key, size_bytes=len(archive), digest=hashlib.sha256(archive).hexdigest(),
                         status="ok", detail=json.dumps({"rows": manifest["row_counts"], "pruned": removed}))
        log.info("Backup %s uploaded and verified (%.1f MB)", key, len(archive) / 1024 / 1024)
        return {"ok": True, "key": key, "bytes": len(archive), "pruned": removed}
    except Exception as e:  # noqa: BLE001 - a failed backup must be reported, never raised into the scheduler
        log.exception("Backup failed: %s", e)
        db.record_backup(service=SERVICE, key="", size_bytes=0, digest="", status="failed", detail=str(e)[:500])
        _tell_someone(str(e))
        return {"ok": False, "reason": str(e)}


def _tell_someone(error: str) -> None:
    """A backup that has been failing quietly for a fortnight is how
    people discover they have no backups."""
    recent = db.recent_backups(service=SERVICE, limit=5)
    failures = [r for r in recent if r["status"] == "failed"]
    if len(failures) not in (1, 3, 7):       # first, then occasionally
        return
    try:
        email_sender.send_plain_email(
            to_email=config.REPLY_TO_EMAIL,
            subject=f"PiperStitch backup failed ({len(failures)} in a row)",
            body=(f"The nightly off-platform backup of {SERVICE} failed:\n\n{error}\n\n"
                  f"Everything still runs; there is simply no fresh copy off Railway until this is fixed.\n\n"
                  f"{config.PUBLIC_BASE_URL}/admin/security"))
    except email_sender.EmailSendError:
        pass


def due(now: Optional[datetime] = None) -> bool:
    """Once a day, after the configured hour."""
    now = now or datetime.now(timezone.utc)
    if now.hour < config.BACKUP_HOUR_UTC:
        return False
    last = db.last_backup(service=SERVICE, status="ok")
    if last is None:
        return True
    return last["created_at"][:10] < now.strftime("%Y-%m-%d")


def check() -> int:
    """The scheduler's tick."""
    if not due():
        return 0
    return 1 if run().get("ok") else 0


def status() -> dict:
    last_ok = db.last_backup(service=SERVICE, status="ok")
    last_any = db.last_backup(service=SERVICE)
    stale = True
    if last_ok:
        age = datetime.now(timezone.utc) - datetime.fromisoformat(last_ok["created_at"].replace("Z", "+00:00"))
        stale = age > timedelta(days=2)
    return {
        "configured": configured(), "destination": f"{config.BACKUP_ENDPOINT}/{config.BACKUP_BUCKET}" if configured() else "",
        "last_ok": last_ok, "last_any": last_any, "stale": stale, "recent": db.recent_backups(service=SERVICE, limit=10),
    }
