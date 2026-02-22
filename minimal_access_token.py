"""Minimal script to fetch an access token from Keycloak using password grant.

Usage:
  python minimal_access_token.py
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.parse
import urllib.request

KEYCLOAK_BASE_URL = os.getenv("KEYCLOAK_BASE_URL", "http://localhost:8080")
REALM = os.getenv("KEYCLOAK_REALM", "demo")
CLIENT_ID = os.getenv("OIDC_CLIENT_ID", "demo-client-a")
CLIENT_SECRET = os.getenv("OIDC_CLIENT_SECRET", "demo-client-a-secret")
USERNAME = os.getenv("DEMO_USER_USERNAME", "demo-user")
PASSWORD = os.getenv("DEMO_USER_PASSWORD", "demo-user-password")


def decode_payload(jwt_token: str) -> dict:
    try:
        payload = jwt_token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        return {"error": f"failed to decode payload: {exc}"}


def main() -> int:
    token_url = f"{KEYCLOAK_BASE_URL}/realms/{REALM}/protocol/openid-connect/token"
    data = urllib.parse.urlencode(
        {
            "grant_type": "password",
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
            "username": USERNAME,
            "password": PASSWORD,
        }
    ).encode("utf-8")

    req = urllib.request.Request(token_url, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8")
    except Exception as exc:  # noqa: BLE001
        print(f"token request failed: {exc}", file=sys.stderr)
        return 1

    token_json = json.loads(body)
    access_token = token_json.get("access_token", "")

    print("=== token response ===")
    print(json.dumps(token_json, ensure_ascii=False, indent=2))

    if access_token:
        print("\n=== decoded access_token payload ===")
        print(json.dumps(decode_payload(access_token), ensure_ascii=False, indent=2))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
