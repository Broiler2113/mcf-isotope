#!/usr/bin/env bash
# (Re)create the Cloudflare side of rlm.mindcontrolfactor.com: a remotely-managed tunnel
# "mcf-rlm" whose only ingress is http://localhost:8501 on whatever machine runs the
# connector, plus the proxied CNAME. Idempotent. Prints the connector token to pass to
# `bash rl/setup.sh <token>` on the training machine.
#   CF_API_TOKEN=... bash rl/tools/cf_tunnel.sh
# Token permissions: Account → Cloudflare Tunnel: Edit; Zone → DNS: Edit; Zone → Zone: Read.
set -euo pipefail
: "${CF_API_TOKEN:?set CF_API_TOKEN}"
HOST="${HOST:-rlm.mindcontrolfactor.com}"; ZONE_NAME="${HOST#*.}"; NAME="${NAME:-mcf-rlm}"
API=https://api.cloudflare.com/client/v4
api() { curl -sf -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "$@"; }
jq_() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

ACC=$(api "$API/accounts" | jq_ 'd["result"][0]["id"]')
ZONE=$(api "$API/zones?name=$ZONE_NAME" | jq_ 'd["result"][0]["id"]')
TID=$(api "$API/accounts/$ACC/cfd_tunnel?is_deleted=false&name=$NAME" | jq_ 'd["result"][0]["id"] if d["result"] else ""')
[ -n "$TID" ] || TID=$(api -X POST "$API/accounts/$ACC/cfd_tunnel" --data "{\"name\":\"$NAME\",\"config_src\":\"cloudflare\"}" | jq_ 'd["result"]["id"]')
api -X PUT "$API/accounts/$ACC/cfd_tunnel/$TID/configurations" \
  --data "{\"config\":{\"ingress\":[{\"hostname\":\"$HOST\",\"service\":\"http://localhost:8501\"},{\"service\":\"http_status:404\"}]}}" >/dev/null
REC=$(api "$API/zones/$ZONE/dns_records?name=$HOST" | jq_ 'd["result"][0]["id"] if d["result"] else ""')
BODY="{\"type\":\"CNAME\",\"name\":\"${HOST%%.*}\",\"content\":\"$TID.cfargotunnel.com\",\"proxied\":true,\"ttl\":1}"
if [ -n "$REC" ]; then api -X PUT "$API/zones/$ZONE/dns_records/$REC" --data "$BODY" >/dev/null
else api -X POST "$API/zones/$ZONE/dns_records" --data "$BODY" >/dev/null; fi
echo "tunnel $NAME ($TID) → $HOST → localhost:8501"
echo "connector token (run on the training machine: bash rl/setup.sh <token>):"
api "$API/accounts/$ACC/cfd_tunnel/$TID/token" | jq_ 'd["result"]'
