#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# =========================
# 0) 変数（環境変数で上書き可能）
# =========================
KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak:8080}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
REALM_NAME="${REALM_NAME:-demo}"

DEMO_USER_USERNAME="${DEMO_USER_USERNAME:-demo-user}"
DEMO_USER_PASSWORD="${DEMO_USER_PASSWORD:-demo-user-password}"

USER_CLIENT_ID="${USER_CLIENT_ID:-demo-user-client}"
USER_CLIENT_SECRET="${USER_CLIENT_SECRET:-demo-user-client-secret}"

CLIENT_A_ID="${CLIENT_A_ID:-demo-client-a}"
CLIENT_A_SECRET="${CLIENT_A_SECRET:-demo-client-a-secret}"

CLIENT_B_ID="${CLIENT_B_ID:-demo-client-b}"
CLIENT_B_SECRET="${CLIENT_B_SECRET:-demo-client-b-secret}"

# Standard Token Exchange v2 用
B_CLIENT_ROLE="${B_CLIENT_ROLE:-invoke}"         # demo-client-b の client role
B_CLIENT_SCOPE="${B_CLIENT_SCOPE:-scope-b}"      # demo-client-a に割り当てる client scope

KC=/opt/keycloak/bin/kcadm.sh

# =========================
# 1) Admin API login（起動待ち）
# =========================
echo "Waiting for Keycloak admin API at ${KEYCLOAK_URL} ..."
until ${KC} config credentials \
  --server "${KEYCLOAK_URL}" --realm master \
  --user "${ADMIN_USER}" --password "${ADMIN_PASSWORD}" >/dev/null 2>&1; do
  sleep 2
done
echo "Logged in to admin API"

# =========================
# 2) Realm 作成（なければ）
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
# 3) Demo user 作成（なければ）＋パスワード設定
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

${KC} set-password -r "${REALM_NAME}" \
  --userid "${USER_ID}" \
  --new-password "${DEMO_USER_PASSWORD}" \
  --temporary=false >/dev/null

# =========================
# 4) USER_CLIENT（password grant 用）
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

# =========================
# 5) CLIENT_A（requester）
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

# Standard Token Exchange v2 を requester に有効化（必須）
${KC} update "clients/${CLIENT_A_INTERNAL_ID}" -r "${REALM_NAME}" \
  -s 'attributes."standard.token.exchange.enabled"'="true" \
  -s enabled=true \
  -s secret="${CLIENT_A_SECRET}" \
  >/dev/null

# =========================
# 6) CLIENT_B（target / audience）
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
# 7) demo-client-b に client role を作る（audience 可能化の核）
# =========================
# クライアントロールは /clients/{id}/roles で管理
if ! ${KC} get "clients/${CLIENT_B_INTERNAL_ID}/roles/${B_CLIENT_ROLE}" -r "${REALM_NAME}" >/dev/null 2>&1; then
  echo "Creating client-b role: ${CLIENT_B_ID}.${B_CLIENT_ROLE}"
  ${KC} create "clients/${CLIENT_B_INTERNAL_ID}/roles" -r "${REALM_NAME}" \
    -s name="${B_CLIENT_ROLE}" \
    -s description="Role for token exchange audience=${CLIENT_B_ID}" >/dev/null
fi

# =========================
# 8) demo-user に client-b role を付与（audience が「利用可能」になる条件）
# =========================
# user に client role を付ける（realm role ではない）
echo "Granting client-b role to demo user"
${KC} add-roles -r "${REALM_NAME}" \
  --uusername "${DEMO_USER_USERNAME}" \
  --cclientid "${CLIENT_B_ID}" \
  --rolename "${B_CLIENT_ROLE}" >/dev/null 2>&1 || true

# =========================
# 9) client scope（scope-b）を作り、そこに client-b role を含める
#    -> demo-client-a にこの scope を割り当てると、token exchange 時に aud に client-b が出せる
# =========================
# 9-1) client scope 作成
if ! ${KC} get client-scopes -r "${REALM_NAME}" -q name="${B_CLIENT_SCOPE}" --fields id | grep -q '"id"'; then
  echo "Creating client scope: ${B_CLIENT_SCOPE}"
  ${KC} create client-scopes -r "${REALM_NAME}" \
    -s name="${B_CLIENT_SCOPE}" \
    -s protocol="openid-connect" \
    -s description="Scope enabling audience ${CLIENT_B_ID} via client role mapping" >/dev/null
fi

SCOPE_B_ID=$(${KC} get client-scopes -r "${REALM_NAME}" -q name="${B_CLIENT_SCOPE}" --fields id --format csv --noquotes | tail -n1)

# 9-2) client scope に role-scope-mapping を追加（client-b の role を scope に含める）
# まず role 表現(JSON)を取る
ROLE_JSON=$(${KC} get "clients/${CLIENT_B_INTERNAL_ID}/roles/${B_CLIENT_ROLE}" -r "${REALM_NAME}" --format json)

# すでに付いているか確認（雑に name で判定）
if ! ${KC} get "client-scopes/${SCOPE_B_ID}/scope-mappings/clients/${CLIENT_B_INTERNAL_ID}" -r "${REALM_NAME}" 2>/dev/null | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${B_CLIENT_ROLE}\""; then
  echo "Adding role-scope-mapping: scope ${B_CLIENT_SCOPE} includes ${CLIENT_B_ID}.${B_CLIENT_ROLE}"
  # role を配列で POST する必要がある
  printf '[%s]\n' "${ROLE_JSON}" > /tmp/role-b.json
  ${KC} create "client-scopes/${SCOPE_B_ID}/scope-mappings/clients/${CLIENT_B_INTERNAL_ID}" -r "${REALM_NAME}" \
    -f /tmp/role-b.json >/dev/null
fi

# 9-3) demo-client-a に scope-b を default client scope として割当
# （optional にすると token exchange リクエストに scope=scope-b が必要になる）
if ! ${KC} get "clients/${CLIENT_A_INTERNAL_ID}/default-client-scopes" -r "${REALM_NAME}" 2>/dev/null | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${B_CLIENT_SCOPE}\""; then
  echo "Attaching default client scope to client-a: ${B_CLIENT_SCOPE}"
  ${KC} update "clients/${CLIENT_A_INTERNAL_ID}/default-client-scopes/${SCOPE_B_ID}" -r "${REALM_NAME}" >/dev/null
fi

# =========================
# 10) ユーザトークンに aud=client-a を入れる（initial token -> requester を成立させる）
#     これはあなたの元スクリプト通り audience mapper を user-client に付ける
# =========================
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
# 11) 完了メッセージ（検証用 curl）
# =========================
cat <<EOF

Keycloak demo setup complete (Standard Token Exchange v2).

Realm: ${REALM_NAME}
User:  ${DEMO_USER_USERNAME} / ${DEMO_USER_PASSWORD}

Clients:
- user-client (password grant): ${USER_CLIENT_ID}
- requester (token exchange):    ${CLIENT_A_ID}
- target (audience):             ${CLIENT_B_ID}

Token Exchange v2 prerequisites created:
- client-b role: ${CLIENT_B_ID}.${B_CLIENT_ROLE}
- demo-user granted role: ${CLIENT_B_ID}.${B_CLIENT_ROLE}
- client scope: ${B_CLIENT_SCOPE} includes ${CLIENT_B_ID}.${B_CLIENT_ROLE}
- client-a has default scope: ${B_CLIENT_SCOPE}
- client-a standard.token.exchange.enabled=true

User token:
curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=${USER_CLIENT_ID}" \
  -d "client_secret=${USER_CLIENT_SECRET}" \
  -d "username=${DEMO_USER_USERNAME}" \
  -d "password=${DEMO_USER_PASSWORD}" \
  -d "scope=profile email"

Token exchange (requester=client-a, audience=client-b):
curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "${CLIENT_A_ID}:${CLIENT_A_SECRET}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=<USER_ACCESS_TOKEN>" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=${CLIENT_B_ID}"

EOF
