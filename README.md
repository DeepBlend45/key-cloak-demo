# key-cloak-demo

Docker 上で Keycloak を起動し、`docker compose up` と同時に次のデモ設定を自動作成します。

- デモユーザ: `demo-user`
- ユーザクライアント: `demo-user-client`
- デモクライアントA: `demo-client-a`
- デモクライアントB: `demo-client-b`
- `demo-user` が **user client** 経由でユーザトークン取得可能（aud は client A）
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

> TokenExchange を GUI/API の両方で安定して扱うため、Keycloak `24.0.5` を `--features=token-exchange,admin-fine-grained-authz` 付きで起動しています。

> 以前の設定が残っているとクライアント設定が古いままになるため、必要に応じて `docker compose down -v` 後に再起動してください。

> ログイン後に「アクセスが集中している」系の画面になる場合は、過去の失敗ログインや古い realm 設定が残っている可能性があるため、`docker compose down -v` 後に再起動してください（init スクリプトで brute force 保護を無効化しています）。

3. Keycloak 管理画面にアクセス

- URL: <http://localhost:8080>
- ユーザー名: `.env` の `KEYCLOAK_ADMIN`
- パスワード: `.env` の `KEYCLOAK_ADMIN_PASSWORD`

## 動作確認

### 1) demo-user が user client 経由でアクセストークン取得（aud は client A）

```bash
curl -s -X POST "http://localhost:8080/realms/demo/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=demo-user-client" \
  -d "client_secret=demo-user-client-secret" \
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
- `/callback/view` : 認可コード受信後にトークン取得し、**トークン JSON と JWT ペイロードを HTML で表示**
- `/token-exchange/view` : 取得済み access token を使って **Client A → Client B の TokenExchange** をブラウザで実行し、交換後トークンを表示
- `/login` : 認可 URL を JSON で返却（API用途）
- `/callback` : 認可コード受信とトークン交換を JSON で返却（API用途）
- `/token-exchange` : TokenExchange 結果を JSON で返却（API用途）

### 起動

```bash
uv run uvicorn auth_code_receiver:app --host 0.0.0.0 --port 9000
```

起動後にブラウザで以下にアクセス:

- <http://localhost:9000>

### 必要に応じた環境変数

- `KEYCLOAK_BASE_URL` (default: `http://localhost:8080`)
- `KEYCLOAK_REALM` (default: `demo`)
- `OIDC_USER_CLIENT_ID` (default: `demo-user-client`)
- `OIDC_USER_CLIENT_SECRET` (default: `demo-user-client-secret`)
- `OIDC_CLIENT_A_ID` (default: `demo-client-a`)
- `OIDC_CLIENT_A_SECRET` (default: `demo-client-a-secret`)
- `OIDC_CLIENT_B_ID` (default: `demo-client-b`)
- `OIDC_REDIRECT_URI` (default: `http://localhost:9000/callback/view`)

停止する場合:

```bash
docker compose down
```


## 直近PRのコンフリクト解消後チェック

- `scripts/init-keycloak.sh` の構文チェック（OK）
- `auth_code_receiver.py` の Python 構文チェック（OK）
- `demo-client-a` のブラウザログイン設定（standard flow / redirect URI / web origins）が init スクリプト内で有効化されていることを確認
- Keycloak 初期待機を `kcadm.sh` リトライ方式に変更し、`curl` 非依存で起動可能なことを確認


## トラブルシューティング（同じエラーが続く場合）

1. 既存データを消して再作成（最重要）

```bash
docker compose down -v
docker compose up -d
```

2. Keycloak 側で demo-user のロック状態を手動クリア

```bash
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password admin

docker compose exec keycloak /opt/keycloak/bin/kcadm.sh get users -r demo -q username=demo-user --fields id

# 取得したidを<USER_ID>に入れる
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh delete \
  attack-detection/brute-force/users/<USER_ID> -r demo
```

3. クライアントAのリダイレクト設定確認（localhost/127.0.0.1 の両方）

```bash
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r demo -q clientId=demo-client-a
```

4. ブラウザのシークレットウィンドウで再試行（古いCookie回避）


## 最小構成でアクセストークンを取得（検証用）

複雑なブラウザフローを使わず、最小構成で token endpoint の疎通確認をしたい場合は `minimal_access_token.py` を使ってください。

```bash
python minimal_access_token.py
```

このスクリプトは以下のみを実行します。

- `grant_type=password` で `demo-user-client` + `demo-user` のアクセストークン取得（audは `demo-client-a`）
- 取得した `access_token` の JWT payload 表示


## CLI中心の検証

- 手順詳細: `docs/flows.md`（user client -> client A -> client B）
- ワンコマンド検証: `bash scripts/verify_flow.sh`
- JWTデコード/検証: `python token_tools.py --token <JWT> --expected-aud <aud>`
