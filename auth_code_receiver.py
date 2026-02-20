import base64
import json
import os
from typing import Any
from urllib.parse import urlencode

import httpx
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import HTMLResponse


KEYCLOAK_BASE_URL = os.getenv("KEYCLOAK_BASE_URL", "http://localhost:8080")
KEYCLOAK_REALM = os.getenv("KEYCLOAK_REALM", "demo")
CLIENT_ID = os.getenv("OIDC_CLIENT_ID", "demo-client-a")
CLIENT_SECRET = os.getenv("OIDC_CLIENT_SECRET", "demo-client-a-secret")
REDIRECT_URI = os.getenv("OIDC_REDIRECT_URI", "http://localhost:9000/callback/view")

app = FastAPI(title="Keycloak Auth Code Receiver")


def build_authorization_url(state: str) -> str:
    auth_params = {
        "client_id": CLIENT_ID,
        "response_type": "code",
        "scope": "openid profile",
        "redirect_uri": REDIRECT_URI,
        "state": state,
    }
    return (
        f"{KEYCLOAK_BASE_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/auth"
        f"?{urlencode(auth_params)}"
    )


def decode_jwt_payload(token: str) -> dict[str, Any]:
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return {"error": "Token is not JWT format"}

        payload_part = parts[1]
        padding = "=" * (-len(payload_part) % 4)
        decoded = base64.urlsafe_b64decode(payload_part + padding)
        return json.loads(decoded.decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        return {"error": f"Failed to decode token payload: {exc}"}


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return f"""
<!doctype html>
<html lang=\"ja\">
<head>
  <meta charset=\"utf-8\" />
  <title>Keycloak Auth Code Demo</title>
  <style>
    body {{ font-family: sans-serif; max-width: 980px; margin: 2rem auto; line-height: 1.5; }}
    .card {{ border: 1px solid #ddd; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; }}
    code, pre {{ background: #f6f8fa; padding: .25rem .4rem; border-radius: 4px; }}
    pre {{ overflow-x: auto; padding: 1rem; }}
    button, a.btn {{ display: inline-block; padding: .6rem 1rem; border-radius: 6px; border: 1px solid #444; text-decoration: none; color: #111; }}
    small {{ color: #666; }}
  </style>
</head>
<body>
  <h1>Keycloak 認可コード検証 UI</h1>
  <div class=\"card\">
    <p>以下のボタンで Keycloak ログイン画面に移動し、認可コードフローを実行します。</p>
    <p><a class=\"btn\" href=\"/login-page\">ログインを開始</a></p>
    <small>Realm: <code>{KEYCLOAK_REALM}</code> / Client: <code>{CLIENT_ID}</code> / Redirect: <code>{REDIRECT_URI}</code></small>
  </div>
  <div class=\"card\">
    <p>API でも確認できます:</p>
    <ul>
      <li><code>GET /login</code> 認可 URL を JSON で取得</li>
      <li><code>GET /callback?code=...&state=...</code> コード交換結果を JSON で取得</li>
    </ul>
  </div>
</body>
</html>
"""


@app.get("/login")
def login(state: str = "demo-state") -> dict[str, str]:
    return {"authorization_url": build_authorization_url(state)}


@app.get("/login-page")
def login_page(state: str = "demo-state"):
    return HTMLResponse(status_code=302, headers={"Location": build_authorization_url(state)})


@app.get("/callback")
async def callback(code: str = Query(...), state: str = Query("")) -> dict[str, Any]:
    token_url = (
        f"{KEYCLOAK_BASE_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token"
    )
    payload = {
        "grant_type": "authorization_code",
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "code": code,
        "redirect_uri": REDIRECT_URI,
    }

    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.post(token_url, data=payload)

    if response.status_code != 200:
        raise HTTPException(
            status_code=response.status_code,
            detail={
                "message": "Failed to exchange authorization code for token.",
                "keycloak_response": response.text,
            },
        )

    token_response = response.json()
    access_token = token_response.get("access_token", "")
    id_token = token_response.get("id_token", "")

    return {
        "message": "Authorization code received and exchanged for token.",
        "state": state,
        "token_response": token_response,
        "decoded": {
            "access_token_payload": decode_jwt_payload(access_token) if access_token else None,
            "id_token_payload": decode_jwt_payload(id_token) if id_token else None,
        },
    }


@app.get("/callback/view", response_class=HTMLResponse)
async def callback_view(code: str = Query(...), state: str = Query("")) -> str:
    result = await callback(code=code, state=state)
    token_response = json.dumps(result["token_response"], ensure_ascii=False, indent=2)
    access_payload = json.dumps(
        result["decoded"]["access_token_payload"], ensure_ascii=False, indent=2
    )
    id_payload = json.dumps(result["decoded"]["id_token_payload"], ensure_ascii=False, indent=2)

    return f"""
<!doctype html>
<html lang=\"ja\">
<head>
  <meta charset=\"utf-8\" />
  <title>Token Result</title>
  <style>
    body {{ font-family: sans-serif; max-width: 980px; margin: 2rem auto; line-height: 1.5; }}
    .card {{ border: 1px solid #ddd; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; }}
    pre {{ background: #f6f8fa; padding: 1rem; border-radius: 6px; overflow-x: auto; }}
  </style>
</head>
<body>
  <h1>トークン交換結果</h1>
  <p><a href=\"/\">← トップへ戻る</a></p>
  <div class=\"card\"><h2>Raw token response</h2><pre>{token_response}</pre></div>
  <div class=\"card\"><h2>Decoded access_token payload</h2><pre>{access_payload}</pre></div>
  <div class=\"card\"><h2>Decoded id_token payload</h2><pre>{id_payload}</pre></div>
</body>
</html>
"""
