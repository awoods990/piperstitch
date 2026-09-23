#!/usr/bin/env python3
"""Prints a key for DOCUMENT_ENCRYPTION_KEY, which encrypts partners' tax
forms at rest. Set it on the license-admin service and redeploy; then run
scripts/encrypt_documents.py once to bring any existing forms in.

Keep a copy somewhere safe. Without it the stored forms cannot be read —
which is the point, and also the risk.
"""
import base64
import os

print(base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("="))
