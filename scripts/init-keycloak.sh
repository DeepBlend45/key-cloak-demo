#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ============================================================
# Keycloak (Standard Token Exchange v2) demo initializer
#
# 仕様:
#   - initial   : demo-user-client（password grantでユーザトークン取得）
#   - requester : demo-client-a    （Token Exchange を要求するクライアント）
#   - target    : demo-client-b    （audience の宛先。aud は固定）
#   - 拡張       : Token Exchange 段階で scope を basic/premium の2種類から動的選択
#
# 重要:
#   - audience は「追加」ではなく「候補からのフィルタ」なので、
#     subject_token（ユーザトークン）側で該当 scope を要求して
#     client-b 権限が“候補化”される必要がある。
# ============================================================

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

# Dynamic scopes（2種類）
B_ROLE_BASIC="${B_ROLE_BASIC:-invoke.basic}"
B_ROLE_PREMIUM="${B_ROLE_PREMIUM:-invoke.premium}"

SCOPE_B_BASIC="${SCOPE_B_BASIC:-scope-b-basic}"
SCOPE_B_PREMIUM="${SCOPE_B_PREMIUM:-scope-b-premium}"

KC=/opt/keycloak/bin/kcadm.sh

# =========================
# helper: stdoutは「値のみ」、ログはstderr
# =========================
log() { echo "[init] $*" >&2; }

trim_nl() { tr -d '\r\n'; }

# =========================
# helper: 安全な client-scope ID 取得（name 完全一致）
# =========================
get_client_scope_id_exact() {
  local name="$1"
  ${KC} get client-scopes -r "${REALM_NAME}" --fields id,name --format csv --noquotes \
    | tr -d "\r" \
    | grep ",${name}$" \
    | cut -d, -f1 \
    | head -n 1 \
    | trim_nl
}

# =========================
# helper: client-scope 作成（存在しなければ）
#  - include.in.token.scope=true を必ず付ける（invalid_scope対策）
#  - stdout: UUIDのみ
# =========================
ensure_client_scope() {
  local name="$1"
  local id
  id="$(get_client_scope_id_exact "${name}")" || true

  if [ -z "${id}" ]; then
    log "Creating client-scope: ${name}"
    ${KC} create client-scopes -r "${REALM_NAME}" \
      -s name="${name}" \
      -s protocol="openid-connect" \
      -s 'attributes."include.in.token.scope"'="true" \
      -s description="Token exchange selectable scope: ${name}" >/dev/null

    id="$(get_client_scope_id_exact "${name}")" || true
  fi

  if [ -z "${id}" ]; then
    log "[ERROR] client-scope not found after create: ${name}"
    exit 1
  fi

  echo "${id}" | trim_nl
}

# =========================
# helper: optional scope を client に付与（idempotent）
# =========================
attach_optional_scope() {
  local client_internal_id="$1"
  local scope_id="$2"
  scope_id="$(echo "${scope_id}" | trim_nl)"
  ${KC} update "clients/${client_internal_id}/optional-client-scopes/${scope_id}" -r "${REALM_NAME}" >/dev/null
}

# =========================
# helper: client role 作成（idempotent）
# =========================
ensure_client_role() {
  local client_internal_id="$1"
  local role_name="$2"
  if ! ${KC} get "clients/${client_internal_id}/roles/${role_name}" -r "${REALM_NAME}" >/dev/null 2>&1; then
    log "Creating client role: ${CLIENT_B_ID}.${role_name}"
    ${KC} create "clients/${client_internal_id}/roles" -r "${REALM_NAME}" \
      -s name="${role_name}" \
      -s description="Role ${role_name}" >/dev/null
  fi
}

# =========================
# helper: role-scope-mapping を追加（idempotent）
# =========================
ensure_role_scope_mapping() {
  local scope_id="$1"
  local target_client_id="$2"
  local role_name="$3"

  scope_id="$(echo "${scope_id}" | trim_nl)"

  if ${KC} get "client-scopes/${scope_id}/scope-mappings/clients/${target_client_id}" -r "${REALM_NAME}" 2>/dev/null \
      | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${role_name}\""; then
    return 0
  fi

  log "Mapping role to scope: ${role_name} -> scope_id=${scope_id}"
  local role_json
  role_json="$(${KC} get "clients/${target_client_id}/roles/${role_name}" -r "${REALM_NAME}" --format json)"
  printf '[%s]\n' "${role_json}" > /tmp/role.json
  ${KC} create "client-scopes/${scope_id}/scope-mappings/clients/${target_client_id}" -r "${REALM_NAME}" -f /tmp/role.json >/dev/null
}

# =========================
# 1) Keycloak 管理APIへログイン（起動待ち）
# =========================
log "Waiting for Keycloak admin API at ${KEYCLOAK_URL} ..."
until ${KC} config credentials \
  --server "${KEYCLOAK_URL}" --realm master \
  --user "${ADMIN_USER}" --password "${ADMIN_PASSWORD}" >/dev/null 2>&1; do
  sleep 2
done
log "Logged in to admin API"

# =========================
# 2) Realm を作成（なければ）＋最低限の安定設定
# =========================
if ! ${KC} get "realms/${REALM_NAME}" >/dev/null 2>&1; then
  log "Creating realm ${REALM_NAME}"
  ${KC} create realms \
    -s realm="${REALM_NAME}" \
    -s enabled=true \
    -s bruteForceProtected=false >/dev/null
fi

${KC} update "realms/${REALM_NAME}" \
  -s enabled=true \
  -s bruteForceProtected=false >/dev/null

# =========================
# 3) デモユーザ作成（なければ）＋必須属性を収束
# =========================
if ! ${KC} get users -r "${REALM_NAME}" -q username="${DEMO_USER_USERNAME}" --fields id | grep -q '"id"'; then
  log "Creating demo user ${DEMO_USER_USERNAME}"
  ${KC} create users -r "${REALM_NAME}" \
    -s username="${DEMO_USER_USERNAME}" \
    -s enabled=true \
    -s email="${DEMO_USER_USERNAME}@example.local" \
    -s emailVerified=true \
    -s firstName="Demo" \
    -s lastName="User" >/dev/null
fi

USER_ID=$(${KC} get users -r "${REALM_NAME}" -q username="${DEMO_USER_USERNAME}" --fields id --format csv --noquotes | tail -n1 | trim_nl)

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
  log "Creating user client (${USER_CLIENT_ID})"
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

USER_CLIENT_INTERNAL_ID=$(${KC} get clients -r "${REALM_NAME}" -q clientId="${USER_CLIENT_ID}" --fields id --format csv --noquotes | tail -n1 | trim_nl)

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
  log "Creating client A (${CLIENT_A_ID})"
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

CLIENT_A_INTERNAL_ID=$(${KC} get clients -r "${REALM_NAME}" -q clientId="${CLIENT_A_ID}" --fields id --format csv --noquotes | tail -n1 | trim_nl)

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

# v2 token exchange を requester に有効化
${KC} update "clients/${CLIENT_A_INTERNAL_ID}" -r "${REALM_NAME}" \
  -s 'attributes."standard.token.exchange.enabled"'="true" >/dev/null

# =========================
# 6) client B（target / audience）
# =========================
if ! ${KC} get clients -r "${REALM_NAME}" -q clientId="${CLIENT_B_ID}" --fields id | grep -q '"id"'; then
  log "Creating client B (${CLIENT_B_ID})"
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

CLIENT_B_INTERNAL_ID=$(${KC} get clients -r "${REALM_NAME}" -q clientId="${CLIENT_B_ID}" --fields id --format csv --noquotes | tail -n1 | trim_nl)

# =========================
# 7) user-client のユーザトークンに aud=client-a を入れる
# =========================
if ! ${KC} get "clients/${USER_CLIENT_INTERNAL_ID}/protocol-mappers/models" -r "${REALM_NAME}" | grep -q 'audience-client-a-on-user-client'; then
  log "Adding audience mapper to user-client to include aud=${CLIENT_A_ID}"
  ${KC} create "clients/${USER_CLIENT_INTERNAL_ID}/protocol-mappers/models" -r "${REALM_NAME}" \
    -s name='audience-client-a-on-user-client' \
    -s protocol='openid-connect' \
    -s protocolMapper='oidc-audience-mapper' \
    -s 'config."included.client.audience"'="${CLIENT_A_ID}" \
    -s 'config."id.token.claim"'='false' \
    -s 'config."access.token.claim"'='true' >/dev/null
fi

# ============================================================
# [本体] Dynamic scopes (basic/premium)
# ============================================================

# 8) client-b roles（basic/premium）を確実に作成
ensure_client_role "${CLIENT_B_INTERNAL_ID}" "${B_ROLE_BASIC}"
ensure_client_role "${CLIENT_B_INTERNAL_ID}" "${B_ROLE_PREMIUM}"

# 9) demo-user に client-b roles を付与（デモは両方）
${KC} add-roles -r "${REALM_NAME}" --uusername "${DEMO_USER_USERNAME}" --cclientid "${CLIENT_B_ID}" --rolename "${B_ROLE_BASIC}" >/dev/null 2>&1 || true
${KC} add-roles -r "${REALM_NAME}" --uusername "${DEMO_USER_USERNAME}" --cclientid "${CLIENT_B_ID}" --rolename "${B_ROLE_PREMIUM}" >/dev/null 2>&1 || true

# 10) scope-b-basic / scope-b-premium を作成（存在しなければ）
SCOPE_B_BASIC_ID="$(ensure_client_scope "${SCOPE_B_BASIC}")"
SCOPE_B_PREMIUM_ID="$(ensure_client_scope "${SCOPE_B_PREMIUM}")"

# 11) requester(client-a) と initial(user-client) の両方に Optional Client Scopes として付与
attach_optional_scope "${CLIENT_A_INTERNAL_ID}" "${SCOPE_B_BASIC_ID}"
attach_optional_scope "${CLIENT_A_INTERNAL_ID}" "${SCOPE_B_PREMIUM_ID}"
attach_optional_scope "${USER_CLIENT_INTERNAL_ID}" "${SCOPE_B_BASIC_ID}"
attach_optional_scope "${USER_CLIENT_INTERNAL_ID}" "${SCOPE_B_PREMIUM_ID}"

# 12) role-scope-mapping（scopeごとに中身を変える）
ensure_role_scope_mapping "${SCOPE_B_BASIC_ID}" "${CLIENT_B_INTERNAL_ID}" "${B_ROLE_BASIC}"
ensure_role_scope_mapping "${SCOPE_B_PREMIUM_ID}" "${CLIENT_B_INTERNAL_ID}" "${B_ROLE_PREMIUM}"

# ============================================================
# fail-fast checks（壊れてたらここで落とす）
# ============================================================
log "== verify client scopes exist =="
${KC} get client-scopes -r "${REALM_NAME}" --fields id,name --format csv --noquotes | tr -d "\r" | grep "scope-b-" >&2 || true

log "== verify client-a optional scopes =="
${KC} get "clients/${CLIENT_A_INTERNAL_ID}/optional-client-scopes" -r "${REALM_NAME}" | grep -E "\"name\"|scope-b-" >&2 || true

log "== verify user-client optional scopes =="
${KC} get "clients/${USER_CLIENT_INTERNAL_ID}/optional-client-scopes" -r "${REALM_NAME}" | grep -E "\"name\"|scope-b-" >&2 || true

${KC} get "clients/${CLIENT_A_INTERNAL_ID}/optional-client-scopes" -r "${REALM_NAME}" | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${SCOPE_B_BASIC}\"" \
  || { log "[ERROR] client-a missing optional scope: ${SCOPE_B_BASIC}"; exit 1; }
${KC} get "clients/${CLIENT_A_INTERNAL_ID}/optional-client-scopes" -r "${REALM_NAME}" | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${SCOPE_B_PREMIUM}\"" \
  || { log "[ERROR] client-a missing optional scope: ${SCOPE_B_PREMIUM}"; exit 1; }
${KC} get "clients/${USER_CLIENT_INTERNAL_ID}/optional-client-scopes" -r "${REALM_NAME}" | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${SCOPE_B_BASIC}\"" \
  || { log "[ERROR] user-client missing optional scope: ${SCOPE_B_BASIC}"; exit 1; }
${KC} get "clients/${USER_CLIENT_INTERNAL_ID}/optional-client-scopes" -r "${REALM_NAME}" | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${SCOPE_B_PREMIUM}\"" \
  || { log "[ERROR] user-client missing optional scope: ${SCOPE_B_PREMIUM}"; exit 1; }

# =========================
# 完了メッセージ（検証用コマンド）
# =========================
cat <<EOF

Keycloak demo setup complete (Standard Token Exchange v2 + dynamic scopes).

Realm: ${REALM_NAME}
User : ${DEMO_USER_USERNAME} / ${DEMO_USER_PASSWORD}

Clients:
- initial   (password grant): ${USER_CLIENT_ID}
- requester (token exchange) : ${CLIENT_A_ID}
- target    (audience)       : ${CLIENT_B_ID}

Dynamic scopes:
- basic   : ${SCOPE_B_BASIC}   (maps role ${CLIENT_B_ID}.${B_ROLE_BASIC})
- premium : ${SCOPE_B_PREMIUM} (maps role ${CLIENT_B_ID}.${B_ROLE_PREMIUM})

IMPORTANT:
- subject_token（password grant）でも scope を要求すること（audience候補化のため）
  basic   : scope="profile email ${SCOPE_B_BASIC}"
  premium : scope="profile email ${SCOPE_B_PREMIUM}"

User token (subject_token) example (basic):
curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=${USER_CLIENT_ID}" \
  -d "client_secret=${USER_CLIENT_SECRET}" \
  -d "username=${DEMO_USER_USERNAME}" \
  -d "password=${DEMO_USER_PASSWORD}" \
  -d "scope=profile email ${SCOPE_B_BASIC}"

Token exchange (aud fixed to client-b; scope=basic):
curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "${CLIENT_A_ID}:${CLIENT_A_SECRET}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=<USER_ACCESS_TOKEN>" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=${CLIENT_B_ID}" \
  -d "scope=${SCOPE_B_BASIC}"

Token exchange (aud fixed to client-b; scope=premium):
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
