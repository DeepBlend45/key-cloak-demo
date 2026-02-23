"""
Fetch a user access token via password grant, then perform Token Exchange (Client A -> audience Client B),
and decode both JWT payloads for inspection.

Usage:
  python minimal_access_token.py

Env:
  KEYCLOAK_BASE_URL           (default: http://localhost:8080)
  KEYCLOAK_REALM              (default: demo)

  # Password grant (user token)
  OIDC_USER_CLIENT_ID         (default: demo-user-client)
  OIDC_USER_CLIENT_SECRET     (default: demo-user-client-secret)
  DEMO_USER_USERNAME          (default: demo-user)
  DEMO_USER_PASSWORD          (default: demo-user-password)
  REQUEST_SCOPE               (default: profile email)

  # Token Exchange (Client A -> Client B)
  OIDC_CLIENT_A_ID            (default: demo-client-a)
  OIDC_CLIENT_A_SECRET        (default: demo-client-a-secret)
  AUDIENCE_CLIENT_B           (default: demo-client-b)

  # Checks (optional)
  EXPECTED_AUD_USER_TOKEN     (default: demo-client-a)
  EXPECTED_AUD_EXCHANGED      (default: demo-client-b)

  TIMEOUT_SECONDS             (default: 10)
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any

import requests

from token_tools import decode_jwt_payload


KEYCLOAK_BASE_URL = os.getenv("KEYCLOAK_BASE_URL", "http://localhost:8080").rstrip("/")
REALM = os.getenv("KEYCLOAK_REALM", "demo")
TIMEOUT_SECONDS = int(os.getenv("TIMEOUT_SECONDS", "10"))

# password grant (user token)
USER_CLIENT_ID = os.getenv("OIDC_USER_CLIENT_ID", "demo-user-client")
USER_CLIENT_SECRET = os.getenv("OIDC_USER_CLIENT_SECRET", "demo-user-client-secret")
USERNAME = os.getenv("DEMO_USER_USERNAME", "demo-user")
PASSWORD = os.getenv("DEMO_USER_PASSWORD", "demo-user-password")
REQUEST_SCOPE = os.getenv("REQUEST_SCOPE", "profile email").strip()

# token exchange (clientA -> audience clientB)
CLIENT_A_ID = os.getenv("OIDC_CLIENT_A_ID", "demo-client-a")
CLIENT_A_SECRET = os.getenv("OIDC_CLIENT_A_SECRET", "demo-client-a-secret")
AUDIENCE_CLIENT_B = os.getenv("AUDIENCE_CLIENT_B", "demo-client-b")

# checks
EXPECTED_AUD_USER_TOKEN = os.getenv("EXPECTED_AUD_USER_TOKEN", "demo-client-a")
EXPECTED_AUD_EXCHANGED = os.getenv("EXPECTED_AUD_EXCHANGED", "demo-client-b")


def _truncate(token: str, keep: int = 18) -> str:
    if not token:
        return ""
    if len(token) <= keep * 2:
        return token
    return f"{token[:keep]}...{token[-keep:]}"


def _aud_contains(expected: str, aud_value: Any) -> bool:
    if isinstance(aud_value, str):
        return aud_value == expected
    if isinstance(aud_value, list):
        return expected in [x for x in aud_value if isinstance(x, str)]
    return False


def _post_form(url: str, form: dict[str, str]) -> dict[str, Any]:
    resp = requests.post(
        url,
        data=form,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=TIMEOUT_SECONDS,
    )
    if resp.status_code != 200:
        raise RuntimeError(f"HTTP {resp.status_code}: {resp.text}")
    return resp.json()


def _print_response(title: str, token_json: dict[str, Any]) -> None:
    safe = dict(token_json)
    for k in ("access_token", "refresh_token", "id_token"):
        if isinstance(safe.get(k), str):
            safe[k] = _truncate(safe[k])
    print(f"\n=== {title} response (sanitized) ===")
    print(json.dumps(safe, ensure_ascii=False, indent=2))


def _print_payload(title: str, token: str) -> dict[str, Any]:
    payload = decode_jwt_payload(token)
    print(f"\n=== decoded {title} access_token payload ===")
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return payload


def main() -> int:
    token_url = f"{KEYCLOAK_BASE_URL}/realms/{REALM}/protocol/openid-connect/token"
    print("=== token endpoint ===")
    print(token_url)

    # ---------------------------------------
    # 1) password grant: user token
    # ---------------------------------------
    user_form: dict[str, str] = {
        "grant_type": "password",
        "client_id": USER_CLIENT_ID,
        "client_secret": USER_CLIENT_SECRET,
        "username": USERNAME,
        "password": PASSWORD,
    }
    if REQUEST_SCOPE:
        user_form["scope"] = REQUEST_SCOPE

    try:
        user_token_json = _post_form(token_url, user_form)
    except Exception as exc:  # noqa: BLE001
        print(f"[ERROR] user token request failed: {exc}", file=sys.stderr)
        return 1

    _print_response("user token", user_token_json)

    user_access_token = user_token_json.get("access_token")
    if not isinstance(user_access_token, str) or not user_access_token:
        print("[ERROR] user token response missing access_token", file=sys.stderr)
        return 1

    user_payload = _print_payload("user", user_access_token)
    user_aud = user_payload.get("aud")
    user_sub = user_payload.get("sub")
    ok_user_aud = _aud_contains(EXPECTED_AUD_USER_TOKEN, user_aud)

    print(f"\n[user token] expected aud: {EXPECTED_AUD_USER_TOKEN}")
    print(f"[user token] actual aud  : {user_aud}")
    print(f"[user token] aud check   : {'OK' if ok_user_aud else 'NG'}")

    # ---------------------------------------
    # 2) token exchange: clientA -> audience clientB
    #    subject_token = user access_token
    # ---------------------------------------
    exchange_form: dict[str, str] = {
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "client_id": CLIENT_A_ID,
        "client_secret": CLIENT_A_SECRET,
        "subject_token": user_access_token,
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "audience": AUDIENCE_CLIENT_B,
    }

    try:
        exchanged_json = _post_form(token_url, exchange_form)
    except Exception as exc:  # noqa: BLE001
        print(f"[ERROR] token exchange failed: {exc}", file=sys.stderr)
        return 1

    _print_response("token exchange", exchanged_json)

    exchanged_access_token = exchanged_json.get("access_token")
    if not isinstance(exchanged_access_token, str) or not exchanged_access_token:
        print("[ERROR] exchanged response missing access_token", file=sys.stderr)
        return 1

    exchanged_payload = _print_payload("exchanged", exchanged_access_token)
    ex_aud = exchanged_payload.get("aud")
    ex_sub = exchanged_payload.get("sub")
    ok_ex_aud = _aud_contains(EXPECTED_AUD_EXCHANGED, ex_aud)

    print(f"\n[exchanged] expected aud: {EXPECTED_AUD_EXCHANGED}")
    print(f"[exchanged] actual aud  : {ex_aud}")
    print(f"[exchanged] aud check   : {'OK' if ok_ex_aud else 'NG'}")

    # continuity checks (you said you want sub continuity)
    print(f"\n[continuity] user sub      : {user_sub}")
    print(f"[continuity] exchanged sub : {ex_sub}")
    print(f"[continuity] sub same?     : {'OK' if (user_sub and user_sub == ex_sub) else 'NG'}")

    # quick summary fields (handy for humans)
    def _summary(p: dict[str, Any]) -> dict[str, Any]:
        return {
            "iss": p.get("iss"),
            "sub": p.get("sub"),
            "aud": p.get("aud"),
            "azp": p.get("azp"),
            "scope": p.get("scope"),
            "exp": p.get("exp"),
            "iat": p.get("iat"),
        }

    print("\n=== summary ===")
    print(json.dumps({"user": _summary(user_payload), "exchanged": _summary(exchanged_payload)}, ensure_ascii=False, indent=2))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
