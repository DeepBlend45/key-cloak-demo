#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${KEYCLOAK_BASE_URL:-http://localhost:8080}"
REALM="${KEYCLOAK_REALM:-demo}"
USER_CLIENT_ID="${OIDC_USER_CLIENT_ID:-demo-user-client}"
USER_CLIENT_SECRET="${OIDC_USER_CLIENT_SECRET:-demo-user-client-secret}"
A_ID="${OIDC_CLIENT_A_ID:-demo-client-a}"
A_SECRET="${OIDC_CLIENT_A_SECRET:-demo-client-a-secret}"
B_ID="${OIDC_CLIENT_B_ID:-demo-client-b}"
USER="${DEMO_USER_USERNAME:-demo-user}"
PASS="${DEMO_USER_PASSWORD:-demo-user-password}"

USER_JSON=$(curl -s -X POST "${BASE_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -d "grant_type=password" -d "client_id=${USER_CLIENT_ID}" -d "client_secret=${USER_CLIENT_SECRET}" \
  -d "username=${USER}" -d "password=${PASS}")

USER_TOKEN=$(USER_JSON="$USER_JSON" python - <<'PY'
import json, os
print(json.loads(os.environ['USER_JSON'])['access_token'])
PY
)

python token_tools.py --token "$USER_TOKEN" --expected-aud "$A_ID"

EXCHANGED_JSON=$(curl -s -X POST "${BASE_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "client_id=${A_ID}" -d "client_secret=${A_SECRET}" \
  -d "subject_token=${USER_TOKEN}" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=${B_ID}")

EXCHANGED_TOKEN=$(EXCHANGED_JSON="$EXCHANGED_JSON" python - <<'PY'
import json, os
print(json.loads(os.environ['EXCHANGED_JSON'])['access_token'])
PY
)

python token_tools.py --token "$EXCHANGED_TOKEN" --expected-aud "$B_ID"

echo "Flow verification done."
