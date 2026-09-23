"""Backups that survive losing the platform: the archive, the signing,
the verification, and saying so when there aren't any."""

from __future__ import annotations

import hashlib
import hmac
import io
import json
import sqlite3
import tarfile
from datetime import datetime, timedelta, timezone

import pytest

from app import backups, config, db


def test_the_signature_matches_amazons_documented_example():
    """Anchored on the canonical-request hash Amazon publishes for its
    GET-object example; the signing key and string-to-sign are then
    derived independently here and must agree with ours."""
    empty = hashlib.sha256(b"").hexdigest()
    headers = backups.authorization(
        method="GET", host="examplebucket.s3.amazonaws.com", path="/test.txt", payload_sha=empty,
        now=datetime(2013, 5, 24, tzinfo=timezone.utc), access_key="AKIAIOSFODNN7EXAMPLE",
        secret_key="wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", region="us-east-1", extra_headers={"range": "bytes=0-9"})

    # Amazon's published canonical request for that example.
    canonical = "\n".join([
        "GET", "/test.txt", "",
        f"host:examplebucket.s3.amazonaws.com\nrange:bytes=0-9\nx-amz-content-sha256:{empty}\nx-amz-date:20130524T000000Z\n",
        "host;range;x-amz-content-sha256;x-amz-date", empty])
    assert hashlib.sha256(canonical.encode()).hexdigest() == "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972"

    def sign(key: bytes, msg: str) -> bytes:
        return hmac.new(key, msg.encode(), hashlib.sha256).digest()

    key = sign(sign(sign(sign(b"AWS4wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20130524"), "us-east-1"), "s3"), "aws4_request")
    to_sign = "\n".join(["AWS4-HMAC-SHA256", "20130524T000000Z", "20130524/us-east-1/s3/aws4_request",
                         hashlib.sha256(canonical.encode()).hexdigest()])
    expected = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()

    assert headers["Authorization"].endswith(f"Signature={expected}")
    assert "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date" in headers["Authorization"]
    assert headers["x-amz-date"] == "20130524T000000Z"


def test_the_archive_holds_a_working_database_and_a_manifest(isolated_db, tmp_path):
    db.create_promoter(name="Kathleen", email="kathleen@example.com", default_share_pct=30)
    archive, manifest = backups.build_archive()

    assert manifest["service"] == "license-admin" and manifest["database_sha256"] and manifest["row_counts"]
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        assert sorted(tar.getnames()) == ["license_admin.sqlite3", "manifest.json"]
        assert json.loads(tar.extractfile("manifest.json").read())["service"] == "license-admin"
        restored = tmp_path / "restored.sqlite3"
        restored.write_bytes(tar.extractfile("license_admin.sqlite3").read())
        assert hashlib.sha256(restored.read_bytes()).hexdigest() == manifest["database_sha256"]

    conn = sqlite3.connect(restored)          # it is a real database, not just bytes
    try:
        assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert conn.execute("SELECT name FROM promoters").fetchone()[0] == "Kathleen"
    finally:
        conn.close()


def test_without_a_bucket_it_says_so_rather_than_pretending(isolated_db, monkeypatch):
    monkeypatch.setattr(config, "BACKUP_BUCKET", "")
    assert backups.configured() is False
    result = backups.run()
    assert result["ok"] is False and result["reason"] == "unconfigured"
    assert db.last_backup(service="license-admin")["status"] == "unconfigured"
    assert backups.status()["configured"] is False


def _configure(monkeypatch):
    for name, value in (("BACKUP_ENDPOINT", "https://s3.example.com"), ("BACKUP_BUCKET", "piperstitch"),
                        ("BACKUP_ACCESS_KEY", "key"), ("BACKUP_SECRET_KEY", "secret"), ("BACKUP_REGION", "us-east-1")):
        monkeypatch.setattr(config, name, value)


def test_a_run_uploads_reads_back_and_records_it(isolated_db, monkeypatch):
    _configure(monkeypatch)
    store: dict[str, bytes] = {}
    monkeypatch.setattr(backups, "put", lambda key, body: store.__setitem__(key, body))
    monkeypatch.setattr(backups, "head", lambda key: len(store.get(key, b"")) or None)
    monkeypatch.setattr(backups, "get", lambda key: store[key])
    monkeypatch.setattr(backups, "prune", lambda now=None: 0)

    result = backups.run()
    assert result["ok"] and result["key"].startswith("license-admin/") and result["key"].endswith(".tar.gz")
    assert len(store) == 1 and result["bytes"] == len(next(iter(store.values())))
    row = db.last_backup(service="license-admin", status="ok")
    assert row["key"] == result["key"] and row["digest"] == hashlib.sha256(store[result["key"]]).hexdigest()


def test_an_upload_that_arrives_wrong_is_a_failure_not_a_success(isolated_db, fake_smtp, monkeypatch):
    """The read-back is the point: an upload nobody checked is a belief."""
    _configure(monkeypatch)
    monkeypatch.setattr(backups, "put", lambda key, body: None)
    monkeypatch.setattr(backups, "head", lambda key: 12)          # not the size we sent
    monkeypatch.setattr(backups, "prune", lambda now=None: 0)

    result = backups.run()
    assert result["ok"] is False and "Read back" in result["reason"]
    assert db.last_backup(service="license-admin")["status"] == "failed"
    assert any("backup failed" in m["Subject"] for m in fake_smtp.sent)


def test_it_runs_once_a_day_after_the_chosen_hour(isolated_db, monkeypatch):
    _configure(monkeypatch)
    monkeypatch.setattr(config, "BACKUP_HOUR_UTC", 3)
    early = datetime.now(timezone.utc).replace(hour=1)
    assert backups.due(early) is False
    later = datetime.now(timezone.utc).replace(hour=4)
    assert backups.due(later) is True
    db.record_backup(service="license-admin", key="k", size_bytes=1, digest="d", status="ok")
    assert backups.due(later) is False                            # already done today
    assert backups.due(later + timedelta(days=1)) is True


def test_a_stale_backup_is_reported_as_stale(isolated_db, monkeypatch):
    _configure(monkeypatch)
    db.record_backup(service="license-admin", key="k", size_bytes=1, digest="d", status="ok")
    with db.connection() as conn:
        conn.execute("UPDATE backup_runs SET created_at = ?", ((datetime.utcnow() - timedelta(days=5)).isoformat(timespec="seconds") + "Z",))
    assert backups.status()["stale"] is True


@pytest.mark.parametrize("path_style, expect_host, expect_path", [
    (True, "s3.example.com", "/piperstitch/license-admin/x.tar.gz"),
    (False, "piperstitch.s3.example.com", "/license-admin/x.tar.gz"),
])
def test_it_speaks_to_either_kind_of_provider(monkeypatch, path_style, expect_host, expect_path):
    """Backblaze, R2, Spaces and Wasabi put the bucket in the path; AWS
    wants it in the hostname. Both, so the choice stays open."""
    _configure(monkeypatch)
    monkeypatch.setattr(config, "BACKUP_PATH_STYLE", path_style)
    seen = {}

    class FakeClient:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def request(self, method, url, content=None, headers=None):
            seen["url"] = url
            seen["host"] = headers["Authorization"]
            import types
            return types.SimpleNamespace(status_code=200, headers={"content-length": "1"}, content=b"", text="")

    monkeypatch.setattr(backups.httpx, "Client", lambda timeout=None: FakeClient())
    backups._request("PUT", "license-admin/x.tar.gz", body=b"x")
    assert seen["url"] == f"https://{expect_host}{expect_path}"
