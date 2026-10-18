#!/bin/bash
# Deploys the Hall server (index.js) to Cloudflare Workers with its Durable Object, using only curl (no Node).
#
#   ./hall-server/deploy.sh
#
# It asks for your Cloudflare account ID (Cloudflare dashboard > Workers & Pages, right side) and an API token
# (My Profile > API Tokens > Create Token > "Edit Cloudflare Workers" template). The token is read without being
# shown, used for this run only and never saved. Prints the server's address at the end: put it in
# CONFIG.hallServer in web/index.html (wss://…/hall).
set -euo pipefail
cd "$(dirname "$0")"
NAME=${WORKER_NAME:-pepesfamily}
API=https://api.cloudflare.com/client/v4
read -r -p "Cloudflare account ID: " ACCOUNT
read -r -s -p "Cloudflare API token (hidden): " TOKEN; echo
[ -n "$ACCOUNT" ] && [ -n "$TOKEN" ] || { echo "Both are needed."; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cf() { curl -sS -H "Authorization: Bearer $TOKEN" "$@"; }
ok() { python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("success") else (print(json.dumps(d.get("errors"), indent=1)) or 1))'; }

# A first deploy creates the Durable Object class (a migration); later ones just replace the code.
if [ "$(cf -o /dev/null -w '%{http_code}' "$API/accounts/$ACCOUNT/workers/scripts/$NAME/settings")" = 200 ]; then
  MIGRATIONS=''
  echo "Updating $NAME…"
else
  MIGRATIONS=',"migrations":{"new_tag":"v1","new_sqlite_classes":["Hall"]}'
  echo "Creating $NAME…"
fi
cat > "$TMP/metadata.json" <<EOF
{"main_module":"index.js","compatibility_date":"2025-01-01","bindings":[{"type":"durable_object_namespace","name":"HALL","class_name":"Hall"}]$MIGRATIONS}
EOF
cf -X PUT "$API/accounts/$ACCOUNT/workers/scripts/$NAME" \
  -F "metadata=@$TMP/metadata.json;type=application/json" \
  -F "index.js=@index.js;type=application/javascript+module" | ok
echo "Uploaded."
# reachable at <name>.<your subdomain>.workers.dev
cf -X POST "$API/accounts/$ACCOUNT/workers/scripts/$NAME/subdomain" -H "Content-Type: application/json" --data '{"enabled":true}' | ok
SUB=$(cf "$API/accounts/$ACCOUNT/workers/subdomain" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("result") or {}).get("subdomain") or "")')
if [ -z "$SUB" ]; then
  echo "Your account has no workers.dev subdomain yet: open Workers & Pages in the Cloudflare dashboard once (it offers one), then run this again."
  exit 1
fi
echo
echo "Hall server: https://$NAME.$SUB.workers.dev"
echo "In web/index.html set: hallServer: \"wss://$NAME.$SUB.workers.dev/hall\""
