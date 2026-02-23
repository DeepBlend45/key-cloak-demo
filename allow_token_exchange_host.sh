#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config (override via env)
# =========================
KC_URL="${KC_URL:-http://localhost:8080}"
REALM="${REALM:-demo}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

CLIENT_A_ID="${CLIENT_A_ID:-demo-client-a}"
CLIENT_B_ID="${CLIENT_B_ID:-demo-client-b}"

KEYCLOAK_CONTAINER="${KEYCLOAK_CONTAINER:-keycloak}"

# =========================
# 0) Create client policy JSON on host
#    (Policy name: client.policy.<clientA>)
# =========================
python -c 'import json,os
a=os.getenv("CLIENT_A_ID","demo-client-a")
policy={
  "name":"client.policy.{}".format(a),
  "description":"Allow {} token exchange".format(a),
  "type":"client",
  "logic":"POSITIVE",
  "decisionStrategy":"UNANIMOUS",
  "clients":[a],
}
open("./client-policy.json","w",encoding="utf-8").write(json.dumps(policy))
print("wrote ./client-policy.json")
'

docker compose cp ./client-policy.json "${KEYCLOAK_CONTAINER}:/tmp/client-policy.json" >/dev/null

# =========================
# 1) Get realm-management client internal id (RM_ID),
#    clientB internal id (B_ID),
#    and token-exchange permission id (PERM_ID)
#    Note: PERM_ID lives under realm-management's authz server.
# =========================
INFO_JSON="$(
docker compose exec -T "${KEYCLOAK_CONTAINER}" sh -lc "
set -euo pipefail

/opt/keycloak/bin/kcadm.sh config credentials \
  --server '${KC_URL}' --realm master --user '${ADMIN_USER}' --password '${ADMIN_PASSWORD}' >/dev/null

RM_ID=\$(/opt/keycloak/bin/kcadm.sh get clients -r '${REALM}' -q clientId=realm-management --fields id --format csv --noquotes | tail -n1)
B_ID=\$(/opt/keycloak/bin/kcadm.sh get clients -r '${REALM}' -q clientId='${CLIENT_B_ID}' --fields id --format csv --noquotes | tail -n1)

/opt/keycloak/bin/kcadm.sh update \"clients/\${B_ID}/management/permissions\" -r '${REALM}' -s enabled=true >/dev/null

MP=\$(/opt/keycloak/bin/kcadm.sh get \"clients/\${B_ID}/management/permissions\" -r '${REALM}')
PERM_ID=\$(echo \"\$MP\" | sed -n \"s/.*\\\"token-exchange\\\"[[:space:]]*:[[:space:]]*\\\"\\([^\\\"]*\\)\\\".*/\\1/p\")

echo \"{\\\"rm_id\\\":\\\"\$RM_ID\\\",\\\"b_id\\\":\\\"\$B_ID\\\",\\\"perm_id\\\":\\\"\$PERM_ID\\\"}\"
"
)"

RM_ID="$(echo "$INFO_JSON" | python -c 'import sys,json; print(json.load(sys.stdin)["rm_id"])')"
PERM_ID="$(echo "$INFO_JSON" | python -c 'import sys,json; print(json.load(sys.stdin)["perm_id"])')"

echo "RM_ID=${RM_ID}"
echo "PERM_ID=${PERM_ID}"

# =========================
# 2) Create policy in realm-management authz (idempotent)
# =========================
docker compose exec -T "${KEYCLOAK_CONTAINER}" sh -lc "
set -euo pipefail
/opt/keycloak/bin/kcadm.sh config credentials \
  --server '${KC_URL}' --realm master --user '${ADMIN_USER}' --password '${ADMIN_PASSWORD}' >/dev/null

/opt/keycloak/bin/kcadm.sh create 'clients/${RM_ID}/authz/resource-server/policy/client' -r '${REALM}' \
  -f /tmp/client-policy.json >/dev/null 2>&1 || true
" >/dev/null

# =========================
# 3) Get policy list (JSON) and extract policy UUID for clientA
# =========================
POLICIES_JSON="$(
docker compose exec -T "${KEYCLOAK_CONTAINER}" sh -lc "
set -euo pipefail
/opt/keycloak/bin/kcadm.sh config credentials \
  --server '${KC_URL}' --realm master --user '${ADMIN_USER}' --password '${ADMIN_PASSWORD}' >/dev/null

/opt/keycloak/bin/kcadm.sh get 'clients/${RM_ID}/authz/resource-server/policy' -r '${REALM}' --format json
"
)"

POLICY_ID="$(echo "$POLICIES_JSON" | python -c '
import sys,json,os
items=json.load(sys.stdin)
client_a=os.environ.get("CLIENT_A_ID","demo-client-a")
name="client.policy.{}".format(client_a)
for it in items:
    if it.get("name")==name:
        print(it.get("id",""))
        raise SystemExit(0)
print("")
')"

if [ -z "${POLICY_ID}" ]; then
  echo "[ERROR] Policy not found for client.policy.${CLIENT_A_ID}" >&2
  echo "$POLICIES_JSON" | head -n 120 >&2
  exit 2
fi

echo "POLICY_ID=${POLICY_ID}"

# =========================
# 4) Get token-exchange permission JSON and write updated JSON on host:
#    policies=[POLICY_ID]
# =========================
PERM_JSON="$(
docker compose exec -T "${KEYCLOAK_CONTAINER}" sh -lc "
set -euo pipefail
/opt/keycloak/bin/kcadm.sh config credentials \
  --server '${KC_URL}' --realm master --user '${ADMIN_USER}' --password '${ADMIN_PASSWORD}' >/dev/null

/opt/keycloak/bin/kcadm.sh get 'clients/${RM_ID}/authz/resource-server/permission/scope/${PERM_ID}' -r '${REALM}' --format json
"
)"

POLICY_ID="${POLICY_ID}" python -c '
import sys,json,os
perm=json.load(sys.stdin)
perm["policies"]=[os.environ["POLICY_ID"]]
open("./perm-update.json","w",encoding="utf-8").write(json.dumps(perm))
print("wrote ./perm-update.json")
' <<< "$PERM_JSON"

docker compose cp ./perm-update.json "${KEYCLOAK_CONTAINER}:/tmp/perm-update.json" >/dev/null

# =========================
# 5) Update permission from file, then print final detail
# =========================
docker compose exec -T "${KEYCLOAK_CONTAINER}" sh -lc "
set -euo pipefail
/opt/keycloak/bin/kcadm.sh config credentials \
  --server '${KC_URL}' --realm master --user '${ADMIN_USER}' --password '${ADMIN_PASSWORD}' >/dev/null

/opt/keycloak/bin/kcadm.sh update 'clients/${RM_ID}/authz/resource-server/permission/scope/${PERM_ID}' -r '${REALM}' \
  -f /tmp/perm-update.json >/dev/null

/opt/keycloak/bin/kcadm.sh get 'clients/${RM_ID}/authz/resource-server/permission/scope/${PERM_ID}' -r '${REALM}' --format json
" | python -m json.tool
