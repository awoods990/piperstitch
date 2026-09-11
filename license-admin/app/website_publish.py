"""Publishes a new PiperStitch build to the website over SFTP: the .dmg
itself, and the update-feed JSON the shipped app polls (see
Sources/StitchPilotCore/Licensing/UpdateChecker.swift in the main repo).
Only used when WEBSITE_SFTP_* is configured — see config.py's comment for
why this is dormant otherwise. Same code as the Amerus License Admin's.
"""

from __future__ import annotations

import json
import posixpath

import paramiko

from . import config


class PublishError(Exception):
    """Wraps any SFTP/auth failure with a plain message — the Updates
    route catches this specifically so a failed publish never gets
    recorded as one that succeeded."""


def _connect() -> paramiko.SFTPClient:
    try:
        transport = paramiko.Transport((config.WEBSITE_SFTP_HOST, config.WEBSITE_SFTP_PORT))
        transport.connect(username=config.WEBSITE_SFTP_USERNAME, password=config.WEBSITE_SFTP_PASSWORD)
        return paramiko.SFTPClient.from_transport(transport)
    except (paramiko.SSHException, OSError) as e:
        raise PublishError(f"Could not connect to the website over SFTP: {e}") from e


def upload_build(local_path: str, remote_filename: str) -> None:
    """Uploads the .dmg to WEBSITE_SFTP_DOWNLOADS_PATH/remote_filename."""
    sftp = _connect()
    try:
        remote_path = posixpath.join(config.WEBSITE_SFTP_DOWNLOADS_PATH, remote_filename)
        sftp.put(local_path, remote_path)
    except (paramiko.SSHException, OSError) as e:
        raise PublishError(f"Upload of the build to the website failed: {e}") from e
    finally:
        sftp.close()
        sftp.get_channel().get_transport().close()


def write_feed_json(*, version: str, download_url: str, notes: str) -> None:
    """Overwrites the live update-feed JSON — the one step that actually
    makes an update visible to already-installed copies of PiperStitch."""
    payload = json.dumps({"latest_version": version, "download_url": download_url, "notes": notes}, indent=2)
    sftp = _connect()
    try:
        remote_path = posixpath.join(config.WEBSITE_SFTP_UPDATES_PATH, "piperstitch-mac.json")
        with sftp.open(remote_path, "w") as f:
            f.write(payload)
    except (paramiko.SSHException, OSError) as e:
        raise PublishError(f"Writing the update feed failed: {e}") from e
    finally:
        sftp.close()
        sftp.get_channel().get_transport().close()
