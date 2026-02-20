#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak:8080}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
REALM_NAME="${REALM_NAME:-demo}"

DEMO_USER_USERNAME="${DEMO_USER_USERNAME:-demo-user}"
DEMO_USER_PASSWORD="${DEMO_USER_PASSWORD:-demo-user-password}"

CLIENT_A_ID="${CLIENT_A_ID:-demo-client-a}"
CLIENT_A_SECRET="${CLIENT_A_SECRET:-demo-client-a-secret}"
CLIENT_B_ID="${CLIENT_B_ID:-demo-client-b}"
CLIENT_B_SECRET="${CLIENT_B_SECRET:-demo-client-b-secret}"

echo "Waiting for Keycloak at ${KEYCLOAK_URL} ..."
until curl -fsS "${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration" >/dev/null; do
  sleep 2
done

echo "Logging in to admin API ..."
/opt/keycloak/bin/kcadm.sh config credentials --server "${KEYCLOAK_URL}" --realm master --user "${ADMIN_USER}" --password "${ADMIN_PASSWORD}"

if ! /opt/keycloak/bin/kcadm.sh get "realms/${REALM_NAME}" >/dev/null 2>&1; then
  echo "Creating realm ${REALM_NAME}"
  /opt/keycloak/bin/kcadm.sh create realms -s realm="${REALM_NAME}" -s enabled=true
fi

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

if ! /opt/keycloak/bin/kcadm.sh get clients -r "${REALM_NAME}" -q clientId="${CLIENT_A_ID}" --fields id | grep -q '"id"'; then
  echo "Creating client A (${CLIENT_A_ID})"
  /opt/keycloak/bin/kcadm.sh create clients -r "${REALM_NAME}" \
    -s clientId="${CLIENT_A_ID}" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s secret="${CLIENT_A_SECRET}" \
    -s directAccessGrantsEnabled=true \
    -s standardFlowEnabled=false \
    -s serviceAccountsEnabled=true
fi

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

Demo credentials:
- Realm: ${REALM_NAME}
- User: ${DEMO_USER_USERNAME} / ${DEMO_USER_PASSWORD}
- Client A: ${CLIENT_A_ID} / ${CLIENT_A_SECRET}
- Client B: ${CLIENT_B_ID} / ${CLIENT_B_SECRET}

User token (client A):
curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=${CLIENT_A_ID}" \
  -d "client_secret=${CLIENT_A_SECRET}" \
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
