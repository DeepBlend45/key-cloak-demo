#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ============================================================
# 목적:
#   Keycloak (Standard Token Exchange v2) 用のデモ環境を自動構築する。
#
# 仕様（あなたの要件）:
#   - initial   : demo-user-client（password grantでユーザトークン取得）
#   - requester : demo-client-a    （Token Exchange を要求するクライアント）
#   - target    : demo-client-b    （audience の宛先。aud は固定にしたい）
#   - 拡張要件  : Token Exchange 時に付与する scope を2種類に分け、
#                requester(client-a) が scope を動的に選べるようにする。
#
# 実現方法（Keycloak v2 の考え方）:
#   - audience は「追加」ではなく「利用可能候補からのフィルタ」。
#     -> 事前に「client-b が audience 候補として成立する」状態を作る必要がある。
#   - そのために client-b の client role を作り、ユーザに付与し、
#     さらに client scope に role-scope-mapping を入れる。
#   - 動的に切り替えたい2種類の scope は「Optional Client Scopes」として
#     client-a に紐づけ、Token Exchange リクエストの scope=... で選ぶ。
# ============================================================

# =========================
# 0) 変数（環境変数で上書き可能）
# =========================
KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak:8080}"  # 管理API（kcadm）から見えるURL
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
REALM_NAME="${REALM_NAME:-demo}"

DEMO_USER_USERNAME="${DEMO_USER_USERNAME:-demo-user}"
DEMO_USER_PASSWORD="${DEMO_USER_PASSWORD:-demo-user-password}"

# initial client（ユーザトークン取得用）
USER_CLIENT_ID="${USER_CLIENT_ID:-demo-user-client}"
USER_CLIENT_SECRET="${USER_CLIENT_SECRET:-demo-user-client-secret}"

# requester（token exchange を要求するクライアント）
CLIENT_A_ID="${CLIENT_A_ID:-demo-client-a}"
CLIENT_A_SECRET="${CLIENT_A_SECRET:-demo-client-a-secret}"

# target（audience の宛先クライアント）
CLIENT_B_ID="${CLIENT_B_ID:-demo-client-b}"
CLIENT_B_SECRET="${CLIENT_B_SECRET:-demo-client-b-secret}"

# --- 拡張: scope を2種類に分ける（basic / premium） ---
# client-b 側の client roles（権限そのもの）
B_ROLE_BASIC="${B_ROLE_BASIC:-invoke.basic}"
B_ROLE_PREMIUM="${B_ROLE_PREMIUM:-invoke.premium}"

# client-a から要求できる client scopes（トークンに載せる“パッケージ”）
# ※これを token exchange リクエストの scope= で選ぶ
SCOPE_B_BASIC="${SCOPE_B_BASIC:-scope-b-basic}"
SCOPE_B_PREMIUM="${SCOPE_B_PREMIUM:-scope-b-premium}"

KC=/opt/keycloak/bin/kcadm.sh

# =========================
# 1) Keycloak 管理APIへログイン（起動待ち）
# =========================
echo "Waiting for Keycloak admin API at ${KEYCLOAK_URL} ..."
until ${KC} config credentials \
  --server "${KEYCLOAK_URL}" --realm master \
  --user "${ADMIN_USER}" --password "${ADMIN_PASSWORD}" >/dev/null 2>&1; do
  sleep 2
done
echo "Logged in to admin API"

# =========================
# 2) Realm を作成（なければ）＋最低限の安定設定
# =========================
if ! ${KC} get "realms/${REALM_NAME}" >/dev/null 2>&1; then
  echo "Creating realm ${REALM_NAME}"
  ${KC} create realms \
    -s realm="${REALM_NAME}" \
    -s enabled=true \
    -s bruteForceProtected=false >/dev/null
fi

# デモ安定化（本番では推奨しない）
${KC} update "realms/${REALM_NAME}" \
  -s enabled=true \
  -s bruteForceProtected=false >/dev/null

# =========================
# 3) デモユーザ作成（なければ）＋必須属性を収束
# =========================
if ! ${KC} get users -r "${REALM_NAME}" -q username="${DEMO_USER_USERNAME}" --fields id | grep -q '"id"'; then
  echo "Creating demo user ${DEMO_USER_USERNAME}"
  ${KC} create users -r "${REALM_NAME}" \
    -s username="${DEMO_USER_USERNAME}" \
    -s enabled=true \
    -s email="${DEMO_USER_USERNAME}@example.local" \
    -s emailVerified=true \
    -s firstName="Demo" \
    -s lastName="User" >/dev/null
fi

USER_ID=$(${KC} get users -r "${REALM_NAME}" -q username="${DEMO_USER_USERNAME}" --fields id --format csv --noquotes | tail -n1)

${KC} update "users/${USER_ID}" -r "${REALM_NAME}" \
  -s enabled=true \
  -s email="${DEMO_USER_USERNAME}@example.local" \
  -s emailVerified=true \
  -s firstName="Demo" \
  -s lastName="User" \
  -s "requiredActions=[]" >/dev/null

${KC} set-password -r "${REALM_NAME}" \
  --userid "${USER_ID}" \
  --new-password "${DEMO_USER_PASSWORD}" \
  --temporary=false >/dev/null

# =========================
# 4) user client（password grant 用 / initial token）
# =========================
if ! ${KC} get clients -r "${REALM_NAME}" -q clientId="${USER_CLIENT_ID}" --fields id | grep -q '"id"'; then
  echo "Creating user client (${USER_CLIENT_ID})"
  ${KC} create clients -r "${REALM_NAME}" \
    -s clientId="${USER_CLIENT_ID}" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s secret="${USER_CLIENT_SECRET}" \
    -s directAccessGrantsEnabled=true \
    -s standardFlowEnabled=false \
    -s serviceAccountsEnabled=false >/dev/null
fi

USER_CLIENT_INTERNAL_ID=$(${KC} get clients -r "${REALM_NAME}" -q clientId="${USER_CLIENT_ID}" --fields id --format csv --noquotes | tail -n1)

${KC} update "clients/${USER_CLIENT_INTERNAL_ID}" -r "${REALM_NAME}" \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s secret="${USER_CLIENT_SECRET}" \
  -s directAccessGrantsEnabled=true \
  -s standardFlowEnabled=false \
  -s serviceAccountsEnabled=false >/dev/null

# =========================
# 5) client A（requester）
# =========================
if ! ${KC} get clients -r "${REALM_NAME}" -q clientId="${CLIENT_A_ID}" --fields id | grep -q '"id"'; then
  echo "Creating client A (${CLIENT_A_ID})"
  ${KC} create clients -r "${REALM_NAME}" \
    -s clientId="${CLIENT_A_ID}" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s secret="${CLIENT_A_SECRET}" \
    -s directAccessGrantsEnabled=true \
    -s standardFlowEnabled=true \
    -s serviceAccountsEnabled=true \
    -s 'redirectUris=["http://localhost:9000/*","http://127.0.0.1:9000/*"]' \
    -s 'webOrigins=["http://localhost:9000","http://127.0.0.1:9000"]' \
    -s rootUrl="http://localhost:9000" \
    -s baseUrl="http://localhost:9000" >/dev/null
fi

CLIENT_A_INTERNAL_ID=$(${KC} get clients -r "${REALM_NAME}" -q clientId="${CLIENT_A_ID}" --fields id --format csv --noquotes | tail -n1)

${KC} update "clients/${CLIENT_A_INTERNAL_ID}" -r "${REALM_NAME}" \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s secret="${CLIENT_A_SECRET}" \
  -s directAccessGrantsEnabled=true \
  -s standardFlowEnabled=true \
  -s serviceAccountsEnabled=true \
  -s 'redirectUris=["http://localhost:9000/*","http://127.0.0.1:9000/*"]' \
  -s 'webOrigins=["http://localhost:9000","http://127.0.0.1:9000"]' \
  -s rootUrl="http://localhost:9000" \
  -s baseUrl="http://localhost:9000" >/dev/null

# ------------------------------------------------------------
# [追加] Standard Token Exchange v2 を requester(client-a) に有効化
# 理由:
#   v2 では RFC8693 grant を「そのクライアントが使ってよいか」を
#   client-a の属性で制御する。
# ------------------------------------------------------------
${KC} update "clients/${CLIENT_A_INTERNAL_ID}" -r "${REALM_NAME}" \
  -s 'attributes."standard.token.exchange.enabled"'="true" >/dev/null

# =========================
# 6) client B（target / audience）
# =========================
if ! ${KC} get clients -r "${REALM_NAME}" -q clientId="${CLIENT_B_ID}" --fields id | grep -q '"id"'; then
  echo "Creating client B (${CLIENT_B_ID})"
  ${KC} create clients -r "${REALM_NAME}" \
    -s clientId="${CLIENT_B_ID}" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s secret="${CLIENT_B_SECRET}" \
    -s directAccessGrantsEnabled=false \
    -s standardFlowEnabled=false \
    -s serviceAccountsEnabled=false >/dev/null
fi

CLIENT_B_INTERNAL_ID=$(${KC} get clients -r "${REALM_NAME}" -q clientId="${CLIENT_B_ID}" --fields id --format csv --noquotes | tail -n1)

# =========================
# 7) initial token に aud=client-a を入れる（user-client に audience mapper）
# =========================
# ------------------------------------------------------------
# [重要] v2 token exchange では、requester が関係者として扱われるために
#        subject_token の aud に requester(client-a) が含まれる構成が安定。
# ------------------------------------------------------------
if ! ${KC} get "clients/${USER_CLIENT_INTERNAL_ID}/protocol-mappers/models" -r "${REALM_NAME}" | grep -q 'audience-client-a-on-user-client'; then
  echo "Adding audience mapper to user-client to include aud=${CLIENT_A_ID}"
  ${KC} create "clients/${USER_CLIENT_INTERNAL_ID}/protocol-mappers/models" -r "${REALM_NAME}" \
    -s name='audience-client-a-on-user-client' \
    -s protocol='openid-connect' \
    -s protocolMapper='oidc-audience-mapper' \
    -s 'config."included.client.audience"'="${CLIENT_A_ID}" \
    -s 'config."id.token.claim"'='false' \
    -s 'config."access.token.claim"'='true' >/dev/null
fi

# =========================
# 8) [追加] client-b の client roles を2種類作る（basic / premium）
# =========================
# ------------------------------------------------------------
# [追加] ここが「audience=client-b を“利用可能候補”にする」足場。
#   - client-b に client role が存在し、ユーザがそれを持つことで
#     「ユーザに client-b 向けの権限がある」という根拠ができる。
#   - さらに scope mapping を通じて、token exchange 時に
#     「その権限をトークンへ載せる」ことが可能になる。
# ------------------------------------------------------------
for R in "${B_ROLE_BASIC}" "${B_ROLE_PREMIUM}"; do
  if ! ${KC} get "clients/${CLIENT_B_INTERNAL_ID}/roles/${R}" -r "${REALM_NAME}" >/dev/null 2>&1; then
    echo "Creating client-b role: ${CLIENT_B_ID}.${R}"
    ${KC} create "clients/${CLIENT_B_INTERNAL_ID}/roles" -r "${REALM_NAME}" \
      -s name="${R}" \
      -s description="Role for ${CLIENT_B_ID} (${R})" >/dev/null
  fi
done

# =========================
# 9) [追加] demo-user に client-b roles を付与
# =========================
# ------------------------------------------------------------
# [追加] ここは「ユーザが premium/basis どちらを使えるか」を決める場所。
#   - デモでは両方付与（両方の scope を要求できる状態）
#   - 本番想定なら、premium だけは一部ユーザにのみ付与する
#     -> premium scope を要求しても role が無ければ権限が載らない/拒否に寄る
# ------------------------------------------------------------
echo "Granting client-b roles to demo user (basic + premium for demo)"
${KC} add-roles -r "${REALM_NAME}" \
  --uusername "${DEMO_USER_USERNAME}" \
  --cclientid "${CLIENT_B_ID}" \
  --rolename "${B_ROLE_BASIC}" >/dev/null 2>&1 || true

${KC} add-roles -r "${REALM_NAME}" \
  --uusername "${DEMO_USER_USERNAME}" \
  --cclientid "${CLIENT_B_ID}" \
  --rolename "${B_ROLE_PREMIUM}" >/dev/null 2>&1 || true

# =========================
# 10) [追加] client scopes を2つ作る（scope-b-basic / scope-b-premium）
# =========================
create_scope_if_missing() {
  local name="$1"
  if ! ${KC} get client-scopes -r "${REALM_NAME}" -q name="${name}" --fields id | grep -q '"id"'; then
    echo "Creating client scope: ${name}"
    ${KC} create client-scopes -r "${REALM_NAME}" \
      -s name="${name}" \
      -s protocol="openid-connect" \
      -s description="Token exchange selectable scope: ${name}" >/dev/null
  fi
}

create_scope_if_missing "${SCOPE_B_BASIC}"
create_scope_if_missing "${SCOPE_B_PREMIUM}"

SCOPE_B_BASIC_ID=$(${KC} get client-scopes -r "${REALM_NAME}" -q name="${SCOPE_B_BASIC}" --fields id --format csv --noquotes | tail -n1)
SCOPE_B_PREMIUM_ID=$(${KC} get client-scopes -r "${REALM_NAME}" -q name="${SCOPE_B_PREMIUM}" --fields id --format csv --noquotes | tail -n1)

# =========================
# 11) [追加] scope に role-scope-mapping を入れる
# =========================
# ------------------------------------------------------------
# [追加] 「Role（権限）」と「Scope（トークンへ載せるパッケージ）」を分離する。
#   - role は “持っている権限”
#   - scope は “今回のトークンで提示する権限セット”
#
# これにより:
#   - aud を固定（audience=client-b）にしつつ、
#   - Token Exchange 時に scope=... を変えるだけで
#     basic/premium の提示内容を動的に切り替えられる。
# ------------------------------------------------------------
add_role_to_scope() {
  local scope_id="$1"
  local role_name="$2"

  local role_json
  role_json=$(${KC} get "clients/${CLIENT_B_INTERNAL_ID}/roles/${role_name}" -r "${REALM_NAME}" --format json)

  if ! ${KC} get "client-scopes/${scope_id}/scope-mappings/clients/${CLIENT_B_INTERNAL_ID}" -r "${REALM_NAME}" 2>/dev/null \
      | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${role_name}\""; then
    echo "Adding role-scope-mapping: scope_id=${scope_id} includes ${CLIENT_B_ID}.${role_name}"
    printf '[%s]\n' "${role_json}" > /tmp/role-scope.json
    ${KC} create "client-scopes/${scope_id}/scope-mappings/clients/${CLIENT_B_INTERNAL_ID}" -r "${REALM_NAME}" \
      -f /tmp/role-scope.json >/dev/null
  fi
}

add_role_to_scope "${SCOPE_B_BASIC_ID}" "${B_ROLE_BASIC}"
add_role_to_scope "${SCOPE_B_PREMIUM_ID}" "${B_ROLE_PREMIUM}"

# =========================
# 12) [追加] client-a に optional client scopes として2つを紐づける
# =========================
# ------------------------------------------------------------
# [追加] “動的切り替え”の要点。
#   - Default に入れると常に有効になり、切り替えができない。
#   - Optional に入れて、Token Exchange リクエストで
#       scope=scope-b-basic   または
#       scope=scope-b-premium
#     を指定したときだけ有効になる。
# ------------------------------------------------------------
attach_optional_scope() {
  local scope_id="$1"
  local scope_name="$2"

  if ! ${KC} get "clients/${CLIENT_A_INTERNAL_ID}/optional-client-scopes" -r "${REALM_NAME}" 2>/dev/null \
        | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${scope_name}\""; then
    echo "Attaching OPTIONAL client scope to client-a: ${scope_name}"
    ${KC} update "clients/${CLIENT_A_INTERNAL_ID}/optional-client-scopes/${scope_id}" -r "${REALM_NAME}" >/dev/null
  fi
}

attach_optional_scope "${SCOPE_B_BASIC_ID}" "${SCOPE_B_BASIC}"
attach_optional_scope "${SCOPE_B_PREMIUM_ID}" "${SCOPE_B_PREMIUM}"

# =========================
# 13) 完了メッセージ（検証用コマンド）
# =========================
cat <<EOF

Keycloak demo setup complete (Standard Token Exchange v2 + dynamic scopes).

Realm: ${REALM_NAME}
User : ${DEMO_USER_USERNAME} / ${DEMO_USER_PASSWORD}

Clients:
- initial   (password grant): ${USER_CLIENT_ID}
- requester (token exchange) : ${CLIENT_A_ID}
- target    (audience)       : ${CLIENT_B_ID}

Dynamic scopes (select one at token exchange time):
- basic  scope : ${SCOPE_B_BASIC}   (maps role ${CLIENT_B_ID}.${B_ROLE_BASIC})
- premium scope: ${SCOPE_B_PREMIUM} (maps role ${CLIENT_B_ID}.${B_ROLE_PREMIUM})

User token (initial token; should include aud=${CLIENT_A_ID}):
curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=${USER_CLIENT_ID}" \
  -d "client_secret=${USER_CLIENT_SECRET}" \
  -d "username=${DEMO_USER_USERNAME}" \
  -d "password=${DEMO_USER_PASSWORD}" \
  -d "scope=profile email"

Token exchange (aud fixed to client-b; scope selectable = basic):
curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "${CLIENT_A_ID}:${CLIENT_A_SECRET}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=<USER_ACCESS_TOKEN>" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=${CLIENT_B_ID}" \
  -d "scope=${SCOPE_B_BASIC}"

Token exchange (aud fixed to client-b; scope selectable = premium):
curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "${CLIENT_A_ID}:${CLIENT_A_SECRET}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=<USER_ACCESS_TOKEN>" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=${CLIENT_B_ID}" \
  -d "scope=${SCOPE_B_PREMIUM}"

EOF
