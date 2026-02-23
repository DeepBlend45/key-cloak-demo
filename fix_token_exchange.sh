#!/usr/bin/env bash
set -euo pipefail

KC_URL="${KC_URL:-http://localhost:8080}"
REALM="${REALM:-demo}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

CLIENT_A_ID="${CLIENT_A_ID:-demo-client-a}"
CLIENT_B_ID="${CLIENT_B_ID:-demo-client-b}"

docker compose exec -T keycloak sh -lc "
set -euo pipefail

/opt/keycloak/bin/kcadm.sh config credentials --server '${KC_URL}' --realm master --user '${ADMIN_USER}' --password '${ADMIN_PASSWORD}' >/dev/null

B_ID=\$(/opt/keycloak/bin/kcadm.sh get clients -r '${REALM}' -q clientId='${CLIENT_B_ID}' --fields id --format csv --noquotes | tail -n1)
echo \"clientB_internal_id=\$B_ID\"

# 1) management permissions を有効化（Authorization Services を内部でオンにする）
/opt/keycloak/bin/kcadm.sh update \"clients/\${B_ID}/management/permissions\" -r '${REALM}' -s enabled=true >/dev/null
echo \"enabled management permissions\"

# 2) client policy を作成（clientA のみ許可）
/opt/keycloak/bin/kcadm.sh create \"clients/\${B_ID}/authz/resource-server/policy/client\" -r '${REALM}' \
  -s name=\"client.policy.${CLIENT_A_ID}\" \
  -s description=\"Allow ${CLIENT_A_ID} token exchange\" \
  -s logic=POSITIVE \
  -s decisionStrategy=UNANIMOUS \
  -s clients='[\"${CLIENT_A_ID}\"]' >/dev/null 2>&1 || true
echo \"ensured policy client.policy.${CLIENT_A_ID}\"

# 3) token-exchange permission を 'scope permission一覧' から探す（management/permissionsのIDに頼らない）
PERM_ID=\$(/opt/keycloak/bin/kcadm.sh get \"clients/\${B_ID}/authz/resource-server/permission/scope\" -r '${REALM}' --format csv --noquotes | awk -F, 'NR==1{next} {print \$1 \",\" \$2}' | grep -i token-exchange | head -n1 | cut -d, -f1 || true)
echo \"found token-exchange scope-permission id=\$PERM_ID\"

if [ -z \"\$PERM_ID\" ]; then
  echo \"[ERROR] token-exchange scope permission not found. Dumping all scope permissions...\" >&2
  /opt/keycloak/bin/kcadm.sh get \"clients/\${B_ID}/authz/resource-server/permission/scope\" -r '${REALM}' | head -n 200 >&2
  exit 2
fi

# 4) 見つけた permission に policy を紐付け（ここは失敗したら落とす）
/opt/keycloak/bin/kcadm.sh update \"clients/\${B_ID}/authz/resource-server/permission/scope/\${PERM_ID}\" -r '${REALM}' \
  -s \"policies=[\\\"client.policy.${CLIENT_A_ID}\\\"]\" \
  -s decisionStrategy=UNANIMOUS \
  -s logic=POSITIVE >/dev/null

echo \"updated token-exchange permission policies\"

# 5) 結果を表示（確認用）
echo \"== token-exchange permission detail ==\"
/opt/keycloak/bin/kcadm.sh get \"clients/\${B_ID}/authz/resource-server/permission/scope/\${PERM_ID}\" -r '${REALM}' | head -n 200
"
