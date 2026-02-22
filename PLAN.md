# 実装計画（要件すり合わせ版）

## 1. ゴール（ユーザー要件を実装にマッピング）

以下のフローを **再現性高く** 実行・検証できる構成にする。

1. Keycloak がユーザトークンを発行する（対象: クライアントA）
2. クライアントAが受け取ったユーザトークンを使って Token Exchange を実行し、クライアントB向けトークンを得る
3. クライアントBが交換後トークンを検証する
4. ダウンスコープ原則を適用する（Token Exchange後トークンは必要最小権限）
5. aud が期待通りになることを保証する
   - ユーザ -> クライアントA: `aud=client-a`
   - クライアントA -> クライアントB: `aud=client-b`
6. CLIだけでも一連の検証ができる（実行コマンドを明示）
7. アクセストークンをデコードする関数を実装し、CLIから叩ける

---

## 2. 構成案

### 2.1 Keycloak初期化（`scripts/init-keycloak.sh`）

- realm `demo` を作成
- ユーザ `demo-user` を作成
- client A / client B を作成
- client A は以下を有効化
  - `directAccessGrantsEnabled=true`（CLIからユーザトークン取得）
  - `standardFlowEnabled=true`（必要に応じてブラウザ検証）
- client B は Token Exchange 受け口として管理権限設定を行う
- Token Exchange permission（A -> B）を明示的に設定
- **aud制御前提**として、client scope / audience mapper を構成

### 2.2 ダウンスコープ

- realm role 例:
  - `role:user:read`
  - `role:user:write`
  - `role:b:invoke`（B向け最小権限）
- user token（A向け）は広め（read/write）
- exchange token（B向け）は `role:b:invoke` のみに絞る
- 実装手段は2パターン
  1. Client Policy + Token Exchange 設定（ユーザー確認済み方式）
  2. クライアントスコープを分離して交換時に限定スコープを適用

本実装では **Client Policy 優先** で構成し、必要に応じて2を補助で追加する。

### 2.3 aud の保証

- ユーザトークン取得時は `client_id=client-a` で取得し、`aud` に `client-a` を含める
- Token Exchange時は `audience=client-b` を指定
- 必要に応じて audience mapper で `client-b` を強制

### 2.4 検証方法（CLI）

- `docs/flows.md` を新規作成し、以下を記載
  1. ユーザトークン取得コマンド
  2. Token Exchangeコマンド
  3. client Bでの検証観点（issuer / audience / exp / scope / roles）
- `scripts/verify_flow.sh` を新規作成し、ワンコマンド実行可能化

### 2.5 トークンデコード関数

- `token_tools.py` を新規作成
  - `decode_jwt_payload(token: str) -> dict`
  - `validate_basic_claims(payload, expected_aud, expected_iss)`
- `minimal_access_token.py` からも再利用
- `python token_tools.py --token <JWT> --expected-aud client-b` のように実行可能化

---

## 3. 具体的な成果物（追加/修正）

1. `scripts/init-keycloak.sh`（権限・aud・exchangeの設定を整理）
2. `docs/flows.md`（CLI手順を明示）
3. `scripts/verify_flow.sh`（一連フロー実行）
4. `token_tools.py`（デコード・基本検証）
5. `README.md`（最短手順と参照導線のみ）

---

## 4. 受け入れ基準（Definition of Done）

- [ ] CLIでユーザトークンを取得できる
- [ ] `aud=client-a` を確認できる
- [ ] CLIで Token Exchange が成功する
- [ ] 交換後トークンで `aud=client-b` を確認できる
- [ ] ダウンスコープ（不要権限が落ちている）を確認できる
- [ ] `token_tools.py` でトークンデコード/検証が可能

---

## 5. 実装確定のための Yes/No 質問

以下はすべて **Yes/No** で回答可能。

1. クライアントAのユーザトークン取得は Password Grant（Direct Access Grant）を使う前提でよいですか？（Yes/No）
2. クライアントBは「受信したトークンを検証するだけ」の想定で、B自身が再交換はしない前提でよいですか？（Yes/No）
3. ダウンスコープは「交換後トークンで `role:b:invoke` のみ残す」方針でよいですか？（Yes/No）
4. `aud` は厳密一致（単一）でなく、「期待audを含むこと」を合格条件にしてよいですか？（Yes/No）
5. 検証コマンドは bash + curl + python（jqなし）で統一してよいですか？（Yes/No）
6. Token Exchange設定は GUI ではなく init script（kcadm）を正として自動化してよいですか？（Yes/No）
7. Keycloakバージョンは現在の `24.0.5` 固定で進めてよいですか？（Yes/No）
8. FastAPI UIは補助機能として残し、公式の検証導線はCLI中心に寄せてよいですか？（Yes/No）

