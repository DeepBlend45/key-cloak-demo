#!/usr/bin/env bash
set -euo pipefail

KC_URL="${KC_URL:-http://localhost:8080}"
REALM="${REALM:-demo}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

CLIENT_A_ID="${CLIENT_A_ID:-demo-client-a}"
CLIENT_B_ID="${CLIENT_B_ID:-demo-client-b}"

KEYCLOAK_CONTAINER="${KEYCLOAK_CONTAINER:-keycloak}"

# ---- 0) policy JSON をホスト側で生成 ----
python - <<PY
import json, os
client_a = os.environ.get("CLIENT_A_ID", "demo-client-a")
policy = {
  "name": f"client.policy.{client_a}",
  "description": f"Allow {client_a} token exchange",
  "type": "client",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "clients": [client_a],
}
open("./client-policy.json","w",encoding="utf-8").write(json.dumps(policy))
print("wrote ./client-policy.json")
PY

# ---- 1) コンテナに policy JSON をコピー ----
docker compose cp ./client-policy.json "${KEYCLOAK_CONTAINER}:/tmp/client-policy.json"

# ---- 2) realm-management と clientB のIDと token-exchange permission ID を取得 ----
INFO_JSON="$(
docker compose exec -T "${KEYCLOAK_CONTAINER}" sh -lc "
set -euo pipefail
/opt/keycloak/bin/kcadm.sh config credentials --server '${KC_URL}' --realm master --user '${ADMIN_USER}' --password '${ADMIN_PASSWORD}' >/dev/null

RM_ID=\$(/opt/keycloak/bin/kcadm.sh get clients -r '${REALM}' -q clientId=realm-management --fields id --format csv --noquotes | tail -n1)
B_ID=\$(/opt/keycloak/bin/kcadm.sh get clients -r '${REALM}' -q clientId='${CLIENT_B_ID}' --fields id --format csv --noquotes | tail -n1)

# fine-grained admin permissions を有効化
/opt/keycloak/bin/kcadm.sh update \"clients/\${B_ID}/management/permissions\" -r '${REALM}' -s enabled=true >/dev/null

MP=\$(/opt/keycloak/bin/kcadm.sh get \"clients/\${B_ID}/management/permissions\" -r '${REALM}')
PERM_ID=\$(echo \"\$MP\" | sed -n \"s/.*\\\"token-exchange\\\"[[:space:]]*:[[:space:]]*\\\"\\([^\\\"]*\\)\\\".*/\\1/p\")

echo \"{\\\"rm_id\\\":\\\"\$RM_ID\\\",\\\"b_id\\\":\\\"\$B_ID\\\",\\\"perm_id\\\":\\\"\$PERM_ID\\\"}\"
"
)"
echo "$INFO_JSON" | python -m json.tool

RM_ID=$(echo "$INFO_JSON" | python -c 'import sys,json; print(json.load(sys.stdin)["rm_id"])')
PERM_ID=$(echo "$INFO_JSON" | python -c 'import sys,json; print(json.load(sys.stdin)["perm_id"])')

# ---- 3) policy を作成（既存なら無視） ----
docker compose exec -T "${KEYCLOAK_CONTAINER}" sh -lc "
set -euo pipefail
/opt/keycloak/bin/kcadm.sh create 'clients/${RM_ID}/authz/resource-server/policy/client' -r '${REALM}' \
  -f /tmp/client-policy.json >/dev/null 2>&1 || true
echo created_or_exists
"

# ---- 4) policy 一覧を取得して、対象 policy の UUID をホスト側で抽出 ----
POLICIES_JSON="$(
docker compose exec -T "${KEYCLOAK_CONTAINER}" sh -lc "
set -euo pipefail
/opt/keycloak/bin/kcadm.sh get 'clients/${RM_ID}/authz/resource-server/policy' -r '${REALM}'
"
)"

POLICY_ID=$(echo "$POLICIES_JSON" | python - <<PY
import json, sys, os
items = json.load(sys.stdin)
name = f"client.policy.{os.environ.get('CLIENT_A_ID','demo-client-a')}"
for it in items:
    if it.get("name") == name:
        print(it.get("id",""))
        sys.exit(0)
print("")
PY
)

if [ -z "${POLICY_ID}" ]; then
  echo "[ERROR] could not find policy id for client.policy.${CLIENT_A_ID}" >&2
  echo "$POLICIES_JSON" | head -n 50 >&2
  exit 2
fi
echo "policy_id=${POLICY_ID}"

# ---- 5) permission を取得→policies を policy_id に置換した JSON をホスト側で生成 ----
PERM_JSON="$(
docker compose exec -T "${KEYCLOAK_CONTAINER}" sh -lc "
set -euo pipefail
/opt/keycloak/bin/kcadm.sh get 'clients/${RM_ID}/authz/resource-server/permission/scope/${PERM_ID}' -r '${REALM}'
"
)"

echo "$PERM_JSON" | python - <<PY
import json, sys, os
perm = json.load(sys.stdin)
perm["policies"] = [os.environ["POLICY_ID"]]
open("./perm-update.json","w",encoding="utf-8").write(json.dumps(perm))
print("wrote ./perm-update.json")
PY

docker compose cp ./perm-update.json "${KEYCLOAK_CONTAINER}:/tmp/perm-update.json"

# ---- 6) permission を update ----
docker compose exec -T "${KEYCLOAK_CONTAINER}" sh -lc "
set -euo pipefail
/opt/keycloak/bin/kcadm.sh update 'clients/${RM_ID}/authz/resource-server/permission/scope/${PERM_ID}' -r '${REALM}' \
  -f /tmp/perm-update.json >/dev/null
echo updated
"

# ---- 7) 最終確認（policies が入っているか） ----
docker compose exec -T "${KEYCLOAK_CONTAINER}" sh -lc "
/opt/keycloak/bin/kcadm.sh get 'clients/${RM_ID}/authz/resource-server/permission/scope/${PERM_ID}' -r '${REALM}' | head -n 260
"
