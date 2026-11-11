#!/bin/sh
# Garage setup (Phase 1 step 1.8, plan P15). Runs as an ArgoCD PostSync hook in curlimages/curl (busybox sh, no jq).
# Idempotent: storage layout only if none is applied; buckets only if missing; the platform-test key is kept if
# the Secret holds one that Garage still knows, otherwise Garage creates a new key (CreateKey, never imported) and
# the Secret garage-platform-test-key is overwritten. The key may read and write platform-test only.
# Never prints an API response or a secret: only HTTP codes, names, the key ID and the secret's length.
# Fails closed: an empty parsed value (layout version, node ID, health, key ID, bucket ID) stops the Job before it
# changes anything further, with a message naming the value.
set -eu
R=/tmp/r.json
# First string or number value of a JSON key in a file (responses are split at , { [ so the first match wins)
jstr(){ tr ',{[' '\n\n\n' < "$2" | sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" | head -n 1; }
jnum(){ tr ',{[' '\n\n\n' < "$2" | sed -n "s/.*\"$1\": *\([0-9][0-9]*\).*/\1/p" | head -n 1; }
fail(){ echo "FAIL: $*"; rm -f /tmp/*.json; exit 1; }
need(){ [ -n "$2" ] || fail "empty $1 in the API response; stopped before changing anything further"; }
[ "${BOOTSTRAP_LIB_ONLY:-}" = 1 ] && return 0

A="${GARAGE_ADMIN:?}"; T="${ADMIN_TOKEN:?}"
K8S=https://kubernetes.default.svc; SA=/var/run/secrets/kubernetes.io/serviceaccount
NS=platform; SECRET=garage-platform-test-key
BUCKETS="app-001-dev app-001-prod app-002-dev app-002-prod platform-test"
api(){ # method path [json-file] -> prints the HTTP code; the body stays in $R
  if [ -n "${3:-}" ]; then
    curl -s -m 20 -o "$R" -w '%{http_code}' -X "$1" -H "Authorization: Bearer $T" -H 'Content-Type: application/json' --data @"$3" "$A$2"
  else curl -s -m 20 -o "$R" -w '%{http_code}' -X "$1" -H "Authorization: Bearer $T" "$A$2"; fi; }
k8s(){ # method path out [merge-patch-file] -> prints the HTTP code
  if [ -n "${4:-}" ]; then
    curl -s -m 20 -o "$3" -w '%{http_code}' -X "$1" --cacert "$SA/ca.crt" -H "Authorization: Bearer $(cat "$SA/token")" \
      -H 'Content-Type: application/merge-patch+json' --data @"$4" "$K8S$2"
  else curl -s -m 20 -o "$3" -w '%{http_code}' -X "$1" --cacert "$SA/ca.crt" -H "Authorization: Bearer $(cat "$SA/token")" "$K8S$2"; fi; }
body(){ umask 077; printf '%s' "$1" > /tmp/body.json; echo /tmp/body.json; }

echo "== garage-bootstrap $(date -u '+%Y-%m-%dT%H:%M:%SZ') admin API $A"
# 1. Wait for the admin API (Garage listens before it has a layout; /health stays 503 until then)
i=0; until [ "$(api GET /v2/GetClusterStatus)" = 200 ]; do
  i=$((i+1)); [ "$i" -ge 60 ] && fail "admin API not reachable after 300 s"; sleep 5; done
echo "admin API reachable after about $((i*5)) s"
# 2. Layout, only if none is applied yet
LV="$(jnum layoutVersion "$R")"; NID="$(jstr id "$R")"
need "layout version" "$LV"; need "node ID" "$NID"
echo "layout version $LV, node $(echo "$NID" | cut -c1-16)"
if [ "$LV" = 0 ]; then
  c="$(api POST /v2/UpdateClusterLayout "$(body "{\"roles\":[{\"id\":\"$NID\",\"zone\":\"dc1\",\"capacity\":1000000000,\"tags\":[]}]}")")"
  [ "$c" = 200 ] || fail "UpdateClusterLayout HTTP $c"
  c="$(api POST /v2/ApplyClusterLayout "$(body '{"version":1}')")"; [ "$c" = 200 ] || fail "ApplyClusterLayout HTTP $c"
  echo "layout assigned (zone dc1, 1 GB) and applied as version 1"
else echo "layout already applied: left alone"; fi
i=0; while :; do
  if [ "$(api GET /v2/GetClusterHealth)" = 200 ]; then H="$(jstr status "$R")"; need "cluster health status" "$H"; [ "$H" = healthy ] && break; fi
  i=$((i+1)); [ "$i" -ge 60 ] && fail "cluster not healthy after 300 s (last status: ${H:-none})"; sleep 5; done
echo "cluster health: healthy"
# 3. Buckets, only if missing
for b in $BUCKETS; do
  if [ "$(api GET "/v2/GetBucketInfo?globalAlias=$b")" = 200 ]; then echo "bucket $b: exists"
  else c="$(api POST /v2/CreateBucket "$(body "{\"globalAlias\":\"$b\"}")")"; [ "$c" = 200 ] || fail "CreateBucket $b HTTP $c"; echo "bucket $b: created"; fi
done
# 4. Key: keep it if the Secret holds one Garage still knows; otherwise Garage creates a new one
c="$(k8s GET "/api/v1/namespaces/$NS/secrets/$SECRET" /tmp/s.json)"; [ "$c" = 200 ] || fail "read Secret $SECRET HTTP $c"
KB64="$(jstr accessKeyId /tmp/s.json)"; rm -f /tmp/s.json; KID=""
if [ -n "$KB64" ]; then KID="$(echo "$KB64" | base64 -d 2>/dev/null || true)"; need "key ID decoded from Secret $SECRET" "$KID"; fi
if [ -n "$KID" ] && [ "$(api GET "/v2/GetKeyInfo?id=$KID")" = 200 ]; then
  echo "key $KID: in the Secret and known to Garage: kept"
else
  [ -n "$KID" ] && echo "key $KID: in the Secret but unknown to Garage: replaced" || echo "Secret $SECRET is empty: creating a key"
  c="$(api POST /v2/CreateKey "$(body '{"name":"platform-test"}')")"; [ "$c" = 200 ] || fail "CreateKey HTTP $c"
  KID="$(jstr accessKeyId "$R")"; KSEC="$(jstr secretAccessKey "$R")"; rm -f "$R"
  need "key ID (CreateKey)" "$KID"; need "secret key (CreateKey)" "$KSEC"
  c="$(k8s PATCH "/api/v1/namespaces/$NS/secrets/$SECRET" /tmp/p.json "$(body "{\"stringData\":{\"accessKeyId\":\"$KID\",\"secretAccessKey\":\"$KSEC\"}}")")"
  rm -f /tmp/body.json /tmp/p.json
  [ "$c" = 200 ] || fail "patch Secret $SECRET HTTP $c"
  echo "key $KID: created by Garage, secret length ${#KSEC}, written to Secret $SECRET"; KSEC=""
fi
# 5. The key may read and write platform-test only
[ "$(api GET "/v2/GetBucketInfo?globalAlias=platform-test")" = 200 ] || fail "bucket platform-test not found"
BID="$(jstr id "$R")"; need "bucket ID of platform-test" "$BID"; need "key ID" "$KID"
# verify the parsed ID: looked up by ID, the bucket must carry the alias platform-test
[ "$(api GET "/v2/GetBucketInfo?id=$BID")" = 200 ] && grep -q '"platform-test"' "$R" || fail "bucket ID check failed: $(echo "$BID" | cut -c1-16) is not platform-test"
c="$(api POST /v2/AllowBucketKey "$(body "{\"bucketId\":\"$BID\",\"accessKeyId\":\"$KID\",\"permissions\":{\"read\":true,\"write\":true,\"owner\":false}}")")"
[ "$c" = 200 ] || fail "AllowBucketKey HTTP $c"
echo "key $KID: read and write on platform-test (bucket $(echo "$BID" | cut -c1-16))"
rm -f /tmp/*.json
echo "PASS: garage-bootstrap done"
