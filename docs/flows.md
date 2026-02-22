# CLI Flow Verification

## 1) User token for client A (aud should include demo-client-a)

```bash
USER_TOKEN_JSON=$(curl -s -X POST "http://localhost:8080/realms/demo/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=demo-client-a" \
  -d "client_secret=demo-client-a-secret" \
  -d "username=demo-user" \
  -d "password=demo-user-password")

USER_ACCESS_TOKEN=$(python - <<'PY'
import json, os
print(json.loads(os.environ['USER_TOKEN_JSON'])['access_token'])
PY
)
```

## 2) Token Exchange (A -> B, aud should include demo-client-b)

```bash
EXCHANGED_JSON=$(curl -s -X POST "http://localhost:8080/realms/demo/protocol/openid-connect/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "client_id=demo-client-a" \
  -d "client_secret=demo-client-a-secret" \
  -d "subject_token=${USER_ACCESS_TOKEN}" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=demo-client-b")

EXCHANGED_ACCESS_TOKEN=$(python - <<'PY'
import json, os
print(json.loads(os.environ['EXCHANGED_JSON'])['access_token'])
PY
)
```

## 3) Validate claims

```bash
python token_tools.py --token "$USER_ACCESS_TOKEN" --expected-aud demo-client-a
python token_tools.py --token "$EXCHANGED_ACCESS_TOKEN" --expected-aud demo-client-b
```
