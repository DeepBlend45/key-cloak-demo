#!/usr/bin/env bash
set -euo pipefail

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

echo "Waiting for Keycloak admin API at ${KEYCLOAK_URL} ..."
until /opt/keycloak/bin/kcadm.sh config credentials --server "${KEYCLOAK_URL}" --realm master --user "${ADMIN_USER}" --password "${ADMIN_PASSWORD}" >/dev/null 2>&1; do
  sleep 2
done

echo "Logged in to admin API"

if ! /opt/keycloak/bin/kcadm.sh get "realms/${REALM_NAME}" >/dev/null 2>&1; then
  echo "Creating realm ${REALM_NAME}"
  /opt/keycloak/bin/kcadm.sh create realms -s realm="${REALM_NAME}" -s enabled=true -s bruteForceProtected=false
fi

echo "Ensuring realm settings for demo login stability"
/opt/keycloak/bin/kcadm.sh update "realms/${REALM_NAME}" -s enabled=true -s bruteForceProtected=false >/dev/null

if ! /opt/keycloak/bin/kcadm.sh get "roles/user" -r "${REALM_NAME}" >/dev/null 2>&1; then
  echo "Creating realm role: user"
  /opt/keycloak/bin/kcadm.sh create roles -r "${REALM_NAME}" -s name=user -s description='Demo user role'
fi

if ! /opt/keycloak/bin/kcadm.sh get users -r "${REALM_NAME}" -q username="${DEMO_USER_USERNAME}" --fields id | grep -q '"id"'; then
  echo "Creating demo user ${DEMO_USER_USERNAME}"
  /opt/keycloak/bin/kcadm.sh create users -r "${REALM_NAME}" -s username="${DEMO_USER_USERNAME}" -s enabled=true -s email="${DEMO_USER_USERNAME}@example.local"
fi

USER_ID=$(/opt/keycloak/bin/kcadm.sh get users -r "${REALM_NAME}" -q username="${DEMO_USER_USERNAME}" --fields id --format csv --noquotes | tail -n1)

/opt/keycloak/bin/kcadm.sh set-password -r "${REALM_NAME}" --userid "${USER_ID}" --new-password "${DEMO_USER_PASSWORD}" --temporary=false
/opt/keycloak/bin/kcadm.sh add-roles -r "${REALM_NAME}" --uusername "${DEMO_USER_USERNAME}" --rolename user

# Clear possible temporary lock/throttle state for demo user if present.
/opt/keycloak/bin/kcadm.sh delete "attack-detection/brute-force/users/${USER_ID}" -r "${REALM_NAME}" >/dev/null 2>&1 || true

if ! /opt/keycloak/bin/kcadm.sh get clients -r "${REALM_NAME}" -q clientId="${USER_CLIENT_ID}" --fields id | grep -q '"id"'; then
  echo "Creating user client (${USER_CLIENT_ID})"
  /opt/keycloak/bin/kcadm.sh create clients -r "${REALM_NAME}"     -s clientId="${USER_CLIENT_ID}"     -s enabled=true     -s protocol=openid-connect     -s publicClient=false     -s secret="${USER_CLIENT_SECRET}"     -s directAccessGrantsEnabled=true     -s standardFlowEnabled=false     -s serviceAccountsEnabled=false
fi

USER_CLIENT_INTERNAL_ID=$(/opt/keycloak/bin/kcadm.sh get clients -r "${REALM_NAME}" -q clientId="${USER_CLIENT_ID}" --fields id --format csv --noquotes | tail -n1)

if ! /opt/keycloak/bin/kcadm.sh get "clients/${USER_CLIENT_INTERNAL_ID}/protocol-mappers/models" -r "${REALM_NAME}" | grep -q 'audience-client-a-on-user-client'; then
  /opt/keycloak/bin/kcadm.sh create "clients/${USER_CLIENT_INTERNAL_ID}/protocol-mappers/models" -r "${REALM_NAME}"     -s name='audience-client-a-on-user-client'     -s protocol='openid-connect'     -s protocolMapper='oidc-audience-mapper'     -s 'config."included.client.audience"'="${CLIENT_A_ID}"     -s 'config."id.token.claim"'='false'     -s 'config."access.token.claim"'='true' >/dev/null
fi

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

echo "Ensuring demo roles for downscope"
/opt/keycloak/bin/kcadm.sh create roles -r "${REALM_NAME}" -s name='role:user:read' >/dev/null 2>&1 || true
/opt/keycloak/bin/kcadm.sh create roles -r "${REALM_NAME}" -s name='role:user:write' >/dev/null 2>&1 || true
/opt/keycloak/bin/kcadm.sh create roles -r "${REALM_NAME}" -s name='role:b:invoke' >/dev/null 2>&1 || true

/opt/keycloak/bin/kcadm.sh add-roles -r "${REALM_NAME}" --uusername "${DEMO_USER_USERNAME}" --rolename 'role:user:read' >/dev/null 2>&1 || true
/opt/keycloak/bin/kcadm.sh add-roles -r "${REALM_NAME}" --uusername "${DEMO_USER_USERNAME}" --rolename 'role:user:write' >/dev/null 2>&1 || true

# Ensure audience mapper: token for client A includes audience client A
if ! /opt/keycloak/bin/kcadm.sh get "clients/${CLIENT_A_INTERNAL_ID}/protocol-mappers/models" -r "${REALM_NAME}" | grep -q 'audience-client-a'; then
  /opt/keycloak/bin/kcadm.sh create "clients/${CLIENT_A_INTERNAL_ID}/protocol-mappers/models" -r "${REALM_NAME}"     -s name='audience-client-a'     -s protocol='openid-connect'     -s protocolMapper='oidc-audience-mapper'     -s 'config."included.client.audience"'="${CLIENT_A_ID}"     -s 'config."id.token.claim"'='false'     -s 'config."access.token.claim"'='true' >/dev/null
fi

echo "Enabling permissions on client B"
/opt/keycloak/bin/kcadm.sh update "clients/${CLIENT_B_INTERNAL_ID}/management/permissions" -r "${REALM_NAME}" -s enabled=true >/dev/null

PERMISSIONS_JSON=$(/opt/keycloak/bin/kcadm.sh get "clients/${CLIENT_B_INTERNAL_ID}/management/permissions" -r "${REALM_NAME}")
TOKEN_EXCHANGE_PERMISSION=$(echo "${PERMISSIONS_JSON}" | sed -n 's/.*"token-exchange"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

if [ -n "${TOKEN_EXCHANGE_PERMISSION}" ]; then
  echo "Configuring token exchange permission for ${CLIENT_A_ID} -> ${CLIENT_B_ID}"
  /opt/keycloak/bin/kcadm.sh update "clients/${CLIENT_B_INTERNAL_ID}/authz/resource-server/permission/scope/${TOKEN_EXCHANGE_PERMISSION}" \
    -r "${REALM_NAME}" \
    -s 'policies=["client.policy.'"${CLIENT_A_ID}"'"]' \
    -s decisionStrategy=UNANIMOUS \
    -s logic=POSITIVE >/dev/null || true

  /opt/keycloak/bin/kcadm.sh create "clients/${CLIENT_B_INTERNAL_ID}/authz/resource-server/policy/client" \
    -r "${REALM_NAME}" \
    -s name="client.policy.${CLIENT_A_ID}" \
    -s description="Allow ${CLIENT_A_ID} token exchange" \
    -s logic=POSITIVE \
    -s decisionStrategy=UNANIMOUS \
    -s clients='["'"${CLIENT_A_ID}"'"]' >/dev/null 2>&1 || true

  /opt/keycloak/bin/kcadm.sh update "clients/${CLIENT_B_INTERNAL_ID}/authz/resource-server/permission/scope/${TOKEN_EXCHANGE_PERMISSION}" \
    -r "${REALM_NAME}" \
    -s 'policies=["client.policy.'"${CLIENT_A_ID}"'"]' >/dev/null || true
fi

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
  -d "subject_token=<ACCESS_TOKEN_FOR_CLIENT_A>" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=${CLIENT_B_ID}"
EOF
