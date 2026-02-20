# key-cloak-demo

Docker上でKeycloakを起動するための最小構成です。

## 使い方

1. 環境変数ファイルを作成

```bash
cp .env.example .env
```

2. コンテナを起動

```bash
docker compose up -d
```

3. Keycloak管理画面にアクセス

- URL: <http://localhost:8080>
- ユーザー名: `.env` の `KEYCLOAK_ADMIN`
- パスワード: `.env` の `KEYCLOAK_ADMIN_PASSWORD`

停止する場合:

```bash
docker compose down
```
