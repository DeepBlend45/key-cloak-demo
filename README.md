# key-cloak-demo

Docker 上で Keycloak を起動し、`docker compose up` と同時に次のデモ設定を自動作成します。

- デモユーザ: `demo-user`
- デモクライアントA: `demo-client-a`
- デモクライアントB: `demo-client-b`
- `demo-user` が client A でユーザトークン取得可能
- client A が Token Exchange で audience=client B のアクセストークン取得可能

## 使い方

1. 環境変数ファイルを作成

```bash
cp .env.example .env
```

2. コンテナ起動（Keycloak + 初期化スクリプト）

```bash
docker compose up -d
```

> 以前の設定が残っているとクライアント設定が古いままになるため、必要に応じて `docker compose down -v` 後に再起動してください。

3. Keycloak 管理画面にアクセス

- URL: <http://localhost:8080>
- ユーザー名: `.env` の `KEYCLOAK_ADMIN`
- パスワード: `.env` の `KEYCLOAK_ADMIN_PASSWORD`

## 動作確認

### 1) demo-user が client A 向けアクセストークンを取得

```bash
curl -s -X POST "http://localhost:8080/realms/demo/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=demo-client-a" \
  -d "client_secret=demo-client-a-secret" \
  -d "username=demo-user" \
  -d "password=demo-user-password"
```

### 2) client A が Token Exchange で client B 宛アクセストークンを取得

```bash
curl -s -X POST "http://localhost:8080/realms/demo/protocol/openid-connect/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "client_id=demo-client-a" \
  -d "client_secret=demo-client-a-secret" \
  -d "subject_token=<CLIENT_A_ACCESS_TOKEN>" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=demo-client-b"
```

## 認可コード受け取りサーバー（FastAPI + 簡易UI）

`auth_code_receiver.py` は FastAPI サーバーです。

- `/` : ブラウザ操作用のトップページ
- `/login-page` : Keycloak のログイン画面へリダイレクト
- `/callback/view` : 認可コード受信後にトークン交換し、**トークン JSON と JWT ペイロードを HTML で表示**
- `/login` : 認可 URL を JSON で返却（API用途）
- `/callback` : 認可コード受信とトークン交換を JSON で返却（API用途）

### 起動

```bash
uv run uvicorn auth_code_receiver:app --host 0.0.0.0 --port 9000
```

起動後にブラウザで以下にアクセス:

- <http://localhost:9000>

### 必要に応じた環境変数

- `KEYCLOAK_BASE_URL` (default: `http://localhost:8080`)
- `KEYCLOAK_REALM` (default: `demo`)
- `OIDC_CLIENT_ID` (default: `demo-client-a`)
- `OIDC_CLIENT_SECRET` (default: `demo-client-a-secret`)
- `OIDC_REDIRECT_URI` (default: `http://localhost:9000/callback/view`)

停止する場合:

```bash
docker compose down
```
