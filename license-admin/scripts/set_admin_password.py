"""Prompts for an admin password and prints the PBKDF2 hash to put in
.env as ADMIN_PASSWORD_HASH. The plaintext is never stored anywhere."""

from __future__ import annotations

import getpass
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import auth  # noqa: E402


def main() -> None:
    password = getpass.getpass("New admin password: ")
    confirm = getpass.getpass("Confirm: ")
    if password != confirm:
        print("Passwords don't match.", file=sys.stderr)
        sys.exit(1)
    if len(password) < 12:
        print("Use at least 12 characters.", file=sys.stderr)
        sys.exit(1)
    print("\nPut this line in .env:\n")
    print(f"ADMIN_PASSWORD_HASH={auth.hash_password(password)}")


if __name__ == "__main__":
    main()
