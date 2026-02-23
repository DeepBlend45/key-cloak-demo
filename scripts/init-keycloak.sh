#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'  # 安全のため: 空白/改行を含む値でも壊れにくくする

# =========================
# 0) 変数（環境変数で上書き可能）
# =========================
KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak:8080}"  # Keycloak 管理APIのURL（コンテナ内から見えるURL想定）
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"                 # Keycloak 管理者ユーザ
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"    # Keycloak 管理者パスワード
REALM_NAME="${REALM_NAME:-demo}"                      # 作成/設定対象のRealm

DEMO_USER_USERNAME="${DEMO_USER_USERNAME:-demo-user}"           # デモ用のユーザ名
DEMO_USER_PASSWORD="${DEMO_USER_PASSWORD:-demo-user-password}"  # デモ用のパスワード

USER_CLIENT_ID="${USER_CLIENT_ID:-demo-user-client}"  # ROPC(password grant)でユーザトークンを取るクライアント
USER_CLIENT_SECRET="${USER_CLIENT_SECRET:-demo-user-client-secret}"
CLIENT_A_ID="${CLIENT_A_ID:-demo-client-a}"            # トークン交換（Token Exchange）を実行するクライアント（=主体）
CLIENT_A_SECRET="${CLIENT_A_SECRET:-demo-client-a-secret}"
CLIENT_B_ID="${CLIENT_B_ID:-demo-client-b}"            # トークン交換の対象（audience）クライアント
CLIENT_B_SECRET="${CLIENT_B_SECRET:-demo-client-b-secret}"

# =========================
# 1) Keycloak 管理APIへログイン（起動待ち）
# =========================
echo "Waiting for Keycloak admin API at ${KEYCLOAK_URL} ..."
until /opt/keycloak/bin/kcadm.sh config credentials \
  --server "${KEYCLOAK_URL}" --realm master --user "${ADMIN_USER}" --password "${ADMIN_PASSWORD}" >/dev/null 2>&1; do
  sleep 2
done
echo "Logged in to admin API"

# =========================
# 2) Realm を作成（なければ）＋最低限の安定設定
# =========================
if ! /opt/keycloak/bin/kcadm.sh get "realms/${REALM_NAME}" >/dev/null 2>&1; then
  echo "Creating realm ${REALM_NAME}"
  /opt/keycloak/bin/kcadm.sh create realms \
    -s realm="${REALM_NAME}" \
    -s enabled=true \
    -s bruteForceProtected=false
fi

echo "Ensuring realm settings for demo login stability"
# brute force 保護を切って「デモでロックして入れない」を回避（本番では推奨しない）
/opt/keycloak/bin/kcadm.sh update "realms/${REALM_NAME}" \
  -s enabled=true \
  -s bruteForceProtected=false >/dev/null

# =========================
# 3) Realm ロール user を用意
# =========================
if ! /opt/keycloak/bin/kcadm.sh get "roles/user" -r "${REALM_NAME}" >/dev/null 2>&1; then
  echo "Creating realm role: user"
  /opt/keycloak/bin/kcadm.sh create roles -r "${REALM_NAME}" \
    -s name=user \
    -s description='Demo user role'
fi

# =========================
# 4) デモユーザ作成（なければ）＋必須属性を“毎回”収束
# =========================
if ! /opt/keycloak/bin/kcadm.sh get users -r "${REALM_NAME}" -q username="${DEMO_USER_USERNAME}" --fields id | grep -q '"id"'; then
  echo "Creating demo user ${DEMO_USER_USERNAME}"
  /opt/keycloak/bin/kcadm.sh create users -r "${REALM_NAME}" \
    -s username="${DEMO_USER_USERNAME}" \
    -s enabled=true \
    -s email="${DEMO_USER_USERNAME}@example.local" \
    -s emailVerified=true \
    -s firstName="Demo" \
    -s lastName="User"
fi

USER_ID=$(/opt/keycloak/bin/kcadm.sh get users -r "${REALM_NAME}" -q username="${DEMO_USER_USERNAME}" --fields id --format csv --noquotes | tail -n1)

echo "Ensuring demo user attributes are fully set up (idempotent)"
/opt/keycloak/bin/kcadm.sh update "users/${USER_ID}" -r "${REALM_NAME}" \
  -s enabled=true \
  -s email="${DEMO_USER_USERNAME}@example.local" \
  -s emailVerified=true \
  -s firstName="Demo" \
  -s lastName="User" \
  -s "requiredActions=[]" >/dev/null

/opt/keycloak/bin/kcadm.sh set-password -r "${REALM_NAME}" \
  --userid "${USER_ID}" \
  --new-password "${DEMO_USER_PASSWORD}" \
  --temporary=false

/opt/keycloak/bin/kcadm.sh add-roles -r "${REALM_NAME}" \
  --uusername "${DEMO_USER_USERNAME}" \
  --rolename user

/opt/keycloak/bin/kcadm.sh delete "attack-detection/brute-force/users/${USER_ID}" -r "${REALM_NAME}" >/dev/null 2>&1 || true

# =========================
# 5) user client（ROPC用クライアント）
# =========================
if ! /opt/keycloak/bin/kcadm.sh get clients -r "${REALM_NAME}" -q clientId="${USER_CLIENT_ID}" --fields id | grep -q '"id"'; then
  echo "Creating user client (${USER_CLIENT_ID})"
  /opt/keycloak/bin/kcadm.sh create clients -r "${REALM_NAME}" \
    -s clientId="${USER_CLIENT_ID}" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s secret="${USER_CLIENT_SECRET}" \
    -s directAccessGrantsEnabled=true \
    -s standardFlowEnabled=false \
    -s serviceAccountsEnabled=false
fi

USER_CLIENT_INTERNAL_ID=$(/opt/keycloak/bin/kcadm.sh get clients -r "${REALM_NAME}" -q clientId="${USER_CLIENT_ID}" --fields id --format csv --noquotes | tail -n1)

echo "Ensuring user client settings (idempotent)"
/opt/keycloak/bin/kcadm.sh update "clients/${USER_CLIENT_INTERNAL_ID}" -r "${REALM_NAME}" \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s secret="${USER_CLIENT_SECRET}" \
  -s directAccessGrantsEnabled=true \
  -s standardFlowEnabled=false \
  -s serviceAccountsEnabled=false >/dev/null

# user client のアクセストークンに audience=clientA を含める（Token Exchange 前段）
if ! /opt/keycloak/bin/kcadm.sh get "clients/${USER_CLIENT_INTERNAL_ID}/protocol-mappers/models" -r "${REALM_NAME}" | grep -q 'audience-client-a-on-user-client'; then
  /opt/keycloak/bin/kcadm.sh create "clients/${USER_CLIENT_INTERNAL_ID}/protocol-mappers/models" -r "${REALM_NAME}" \
    -s name='audience-client-a-on-user-client' \
    -s protocol='openid-connect' \
    -s protocolMapper='oidc-audience-mapper' \
    -s 'config."included.client.audience"'="${CLIENT_A_ID}" \
    -s 'config."id.token.claim"'='false' \
    -s 'config."access.token.claim"'='true' >/dev/null
fi

# =========================
# 6) client A
# =========================
if ! /opt/keycloak/bin/kcadm.sh get clients -r "${REALM_NAME}" -q clientId="${CLIENT_A_ID}" --fields id | grep -q '"id"'; then
  echo "Creating client A (${CLIENT_A_ID})"
  /opt/keycloak/bin/kcadm.sh create clients -r "${REALM_NAME}" \
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
    -s baseUrl="http://localhost:9000"
fi

CLIENT_A_INTERNAL_ID=$(/opt/keycloak/bin/kcadm.sh get clients -r "${REALM_NAME}" -q clientId="${CLIENT_A_ID}" --fields id --format csv --noquotes | tail -n1)

echo "Ensuring client A supports browser login flow"
/opt/keycloak/bin/kcadm.sh update "clients/${CLIENT_A_INTERNAL_ID}" -r "${REALM_NAME}" \
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

# =========================
# 7) client B（audience）
# =========================
if ! /opt/keycloak/bin/kcadm.sh get clients -r "${REALM_NAME}" -q clientId="${CLIENT_B_ID}" --fields id | grep -q '"id"'; then
  echo "Creating client B (${CLIENT_B_ID})"
  /opt/keycloak/bin/kcadm.sh create clients -r "${REALM_NAME}" \
    -s clientId="${CLIENT_B_ID}" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s secret="${CLIENT_B_SECRET}" \
    -s directAccessGrantsEnabled=false \
    -s standardFlowEnabled=false \
    -s serviceAccountsEnabled=false
fi

CLIENT_B_INTERNAL_ID=$(/opt/keycloak/bin/kcadm.sh get clients -r "${REALM_NAME}" -q clientId="${CLIENT_B_ID}" --fields id --format csv --noquotes | tail -n1)

# =========================
# 8) デモ用ロール（ダウンスコープ例）
# =========================
echo "Ensuring demo roles for downscope"
/opt/keycloak/bin/kcadm.sh create roles -r "${REALM_NAME}" -s name='role:user:read' >/dev/null 2>&1 || true
/opt/keycloak/bin/kcadm.sh create roles -r "${REALM_NAME}" -s name='role:user:write' >/dev/null 2>&1 || true
/opt/keycloak/bin/kcadm.sh create roles -r "${REALM_NAME}" -s name='role:b:invoke' >/dev/null 2>&1 || true

/opt/keycloak/bin/kcadm.sh add-roles -r "${REALM_NAME}" --uusername "${DEMO_USER_USERNAME}" --rolename 'role:user:read' >/dev/null 2>&1 || true
/opt/keycloak/bin/kcadm.sh add-roles -r "${REALM_NAME}" --uusername "${DEMO_USER_USERNAME}" --rolename 'role:user:write' >/dev/null 2>&1 || true

# =========================
# 9) client A のトークンに audience=clientA を含める（デモ用）
# =========================
if ! /opt/keycloak/bin/kcadm.sh get "clients/${CLIENT_A_INTERNAL_ID}/protocol-mappers/models" -r "${REALM_NAME}" | grep -q 'audience-client-a'; then
  /opt/keycloak/bin/kcadm.sh create "clients/${CLIENT_A_INTERNAL_ID}/protocol-mappers/models" -r "${REALM_NAME}" \
    -s name='audience-client-a' \
    -s protocol='openid-connect' \
    -s protocolMapper='oidc-audience-mapper' \
    -s 'config."included.client.audience"'="${CLIENT_A_ID}" \
    -s 'config."id.token.claim"'='false' \
    -s 'config."access.token.claim"'='true' >/dev/null
fi

# =========================
# 10) Token Exchange allowlist: Client A -> audience Client B (realm-management)
# =========================
echo "Configuring Token Exchange allowlist (realm-management): ${CLIENT_A_ID} -> audience ${CLIENT_B_ID}"

REALM_MGMT_INTERNAL_ID=$(
  /opt/keycloak/bin/kcadm.sh get clients -r "${REALM_NAME}" -q clientId=realm-management \
    --fields id --format csv --noquotes | tail -n1
)
if [ -z "${REALM_MGMT_INTERNAL_ID}" ]; then
  echo "[ERROR] realm-management internal id not found" >&2
  exit 1
fi

/opt/keycloak/bin/kcadm.sh update "clients/${CLIENT_B_INTERNAL_ID}/management/permissions" -r "${REALM_NAME}" \
  -s enabled=true >/dev/null

MGMT_PERMS_JSON=$(/opt/keycloak/bin/kcadm.sh get "clients/${CLIENT_B_INTERNAL_ID}/management/permissions" -r "${REALM_NAME}")
TOKEN_EXCHANGE_PERMISSION_ID=$(echo "${MGMT_PERMS_JSON}" | sed -n 's/.*"token-exchange"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ -z "${TOKEN_EXCHANGE_PERMISSION_ID}" ]; then
  echo "[ERROR] token-exchange permission id not found in management/permissions" >&2
  echo "${MGMT_PERMS_JSON}" >&2
  exit 1
fi
echo "token-exchange permission id: ${TOKEN_EXCHANGE_PERMISSION_ID}"

cat > /tmp/rm-client-policy.json <<EOF
{
  "name": "client.policy.${CLIENT_A_ID}",
  "description": "Allow ${CLIENT_A_ID} token exchange",
  "type": "client",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "clients": ["${CLIENT_A_ID}"]
}
EOF

/opt/keycloak/bin/kcadm.sh create "clients/${REALM_MGMT_INTERNAL_ID}/authz/resource-server/policy/client" -r "${REALM_NAME}" \
  -f /tmp/rm-client-policy.json >/dev/null 2>&1 || true

POLICIES_JSON=$(/opt/keycloak/bin/kcadm.sh get "clients/${REALM_MGMT_INTERNAL_ID}/authz/resource-server/policy" -r "${REALM_NAME}" --format json)
POLICY_UUID=$(
  echo "${POLICIES_JSON}" \
  | sed -n '
      /"id"[[:space:]]*:[[:space:]]*"/{h;}
      /"name"[[:space:]]*:[[:space:]]*"client.policy.'"${CLIENT_A_ID}"'"/{
        g;
        s/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;
        q;
      }
    '
)
if [ -z "${POLICY_UUID}" ]; then
  echo "[ERROR] policy UUID not found for client.policy.${CLIENT_A_ID}" >&2
  echo "${POLICIES_JSON}" | head -n 200 >&2
  exit 1
fi
echo "policy uuid: ${POLICY_UUID}"

PERM_JSON=$(/opt/keycloak/bin/kcadm.sh get "clients/${REALM_MGMT_INTERNAL_ID}/authz/resource-server/permission/scope/${TOKEN_EXCHANGE_PERMISSION_ID}" -r "${REALM_NAME}" --format json)
PERM_NAME=$(echo "${PERM_JSON}" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ -z "${PERM_NAME}" ]; then
  echo "[ERROR] permission name not found for token-exchange permission" >&2
  echo "${PERM_JSON}" >&2
  exit 1
fi

cat > /tmp/rm-perm-update.json <<EOF
{
  "id": "${TOKEN_EXCHANGE_PERMISSION_ID}",
  "name": "${PERM_NAME}",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "policies": ["${POLICY_UUID}"]
}
EOF

/opt/keycloak/bin/kcadm.sh update "clients/${REALM_MGMT_INTERNAL_ID}/authz/resource-server/permission/scope/${TOKEN_EXCHANGE_PERMISSION_ID}" -r "${REALM_NAME}" \
  -f /tmp/rm-perm-update.json >/dev/null

echo "Token Exchange permission updated (realm-management): allow ${CLIENT_A_ID} -> audience ${CLIENT_B_ID}"

# =========================
# 11) 動作確認用の curl を表示
# =========================
cat <<EOF

Keycloak demo setup complete.
Demo user lock state cleared (best effort).

Demo credentials:
- Realm: ${REALM_NAME}
- User: ${DEMO_USER_USERNAME} / ${DEMO_USER_PASSWORD}
- User Client: ${USER_CLIENT_ID} / ${USER_CLIENT_SECRET}
- Client A: ${CLIENT_A_ID} / ${CLIENT_A_SECRET}
- Client B: ${CLIENT_B_ID} / ${CLIENT_B_SECRET}

User token (via user client, aud should include client A):
curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=${USER_CLIENT_ID}" \
  -d "client_secret=${USER_CLIENT_SECRET}" \
  -d "username=${DEMO_USER_USERNAME}" \
  -d "password=${DEMO_USER_PASSWORD}"

Token exchange (A -> B):
curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "client_id=${CLIENT_A_ID}" \
  -d "client_secret=${CLIENT_A_SECRET}" \
  -d "subject_token=<USER_ACCESS_TOKEN>" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=${CLIENT_B_ID}"
EOF
