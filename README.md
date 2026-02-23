## 起動方法

```bash
docker compose up -d --build
```
これでKeycloak起動＋デモクライアント（ユーザクライアント＋クライアントA＋クライアントB）などが作成される

## TokenExchangeの確認方法

```bash
uv run minimal_access_token.py
```

- ユーザ権限でaud=クライアントA、azp=ユーザクライアントのアクセストークン取得
- TokenExchangeでaud=クライアントB、azp=クライアントAのアクセストークン取得
- 取得したアクセストークンの中身をCLIに出力

詳細はそれぞれのファイルの中身を確認すべし。