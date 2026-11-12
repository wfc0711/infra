#!/bin/sh
# Governance gate (Phase 1 step 1.9; plan P8, P9, P11, P12, ADR-08). Runs as an ArgoCD PreSync hook in
# curlimages/curl (busybox sh) before every sync of an app lane. Fails closed: any missing input or failed step
# stops the gate with exit 1, which fails the sync.
# 1. gate-state (platform ConfigMap) already holds this release for <app>.<lane> -> "no-change", no ticket, pass.
# 2. DEV -> "auto-approved", pass. 3. PROD -> ticket in /approvals, wait for line 1 "yes" or "no" (any letter case;
#    trailing CR and spaces ignored; anything else keeps waiting) or GATE_TIMEOUT_SECONDS -> "approved", "rejected"
#    or "timeout"; the ticket is archived with the result, so a late answer does nothing.
# Every run writes exactly one line to /outputs/change-log.csv, under a lock, BEFORE gate-state is updated.
# Only "no-change", "auto-approved" and "approved" pass; only "auto-approved" and "approved" update gate-state.
# Never prints the service account token.
# Paths can be overridden for tests outside the cluster (09-gate-flow-selftest.sh); the defaults are the real ones.
set -eu
AP="${GATE_APPROVALS:-/approvals}"; OUTD="${GATE_OUTPUTS:-/outputs}"
CL="$OUTD/change-log.csv"; CL_LOCK="$OUTD/.change-log.lock"
HEADER='time_utc,app,lane,release,decision,ticket'
LOCK_WAIT="${LOCK_WAIT:-30}"; POLL="${POLL:-5}"
fail(){ echo "FAIL: $*"; exit 1; }
need(){ [ -n "$2" ] || fail "empty $1; the gate stops (fail closed)"
  [ "$2" != unset ] || fail "$1 is still the placeholder \"unset\" (the lane did not set it); the gate stops (fail closed)"; }
now(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }
# Line 1 of a ticket -> yes | no | wait
answer(){ l="$(head -n 1 "$1" 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//' | tr 'A-Z' 'a-z')"
  case "$l" in yes) echo yes;; no) echo no;; *) echo wait;; esac; }
# One change-log line (no newline): time,app,lane,release,decision,ticket ("-" when there is no ticket)
csvline(){ printf '%s,%s,%s,%s,%s,%s' "$(now)" "$APP" "$LANE" "$RELEASE_ID" "$1" "${2:--}"; }
# Append one line under a lock; fails closed (missing file, wrong header, lock not obtained, write error)
log(){ [ -f "$CL" ] || fail "change log $CL missing (created by the secrets script)"
  [ "$(head -n 1 "$CL")" = "$HEADER" ] || fail "change log $CL: line 1 is not the header"
  for v in "$APP" "$LANE" "$RELEASE_ID" "$1" "${2:--}"; do   # checked here, not in a subshell, so the message is seen
    case "$v" in *,*|*'
'*) fail "a change-log field contains a comma or a line break: $v";; esac; done
  line="$(csvline "$1" "${2:-}")"
  i=0; until mkdir "$CL_LOCK" 2>/dev/null; do
    i=$((i+1)); [ "$i" -ge "$LOCK_WAIT" ] && fail "change-log lock $CL_LOCK held for ${LOCK_WAIT} s (stale lock? see Rollback)"; sleep 1; done
  if printf '%s\n' "$line" >> "$CL"; then rmdir "$CL_LOCK"; else rmdir "$CL_LOCK"; fail "append to $CL failed"; fi
  echo "change log: $line"; }
[ "${GATE_LIB_ONLY:-}" = 1 ] && return 0

need APP "${APP:-}"; need LANE "${LANE:-}"; need RELEASE_ID "${RELEASE_ID:-}"; need GATE_TIMEOUT_SECONDS "${GATE_TIMEOUT_SECONDS:-}"
case "$LANE" in dev|prod) ;; *) fail "LANE must be dev or prod, not $LANE";; esac
case "$RELEASE_ID$APP" in *[!A-Za-z0-9._-]*) fail "APP and RELEASE_ID may hold only letters, digits, dot, dash and underscore";; esac
case "$GATE_TIMEOUT_SECONDS" in ''|*[!0-9]*) fail "GATE_TIMEOUT_SECONDS is not a number";; esac
[ -d "$AP" ] && [ -d "$OUTD" ] || fail "$AP or $OUTD is not mounted"
K8S="${GATE_K8S_API:-https://kubernetes.default.svc}"; SA="${GATE_SA_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}"
CM="/api/v1/namespaces/platform/configmaps/gate-state"; KEY="$APP.$LANE"
k8s(){ # method out [merge-patch-body] -> HTTP code
  if [ -n "${3:-}" ]; then
    printf '%s' "$3" > /tmp/patch.json
    curl -s -m 20 -o "$2" -w '%{http_code}' -X "$1" --cacert "$SA/ca.crt" -H "Authorization: Bearer $(cat "$SA/token")" \
      -H 'Content-Type: application/merge-patch+json' --data @/tmp/patch.json "$K8S$CM"
  else curl -s -m 20 -o "$2" -w '%{http_code}' -X "$1" --cacert "$SA/ca.crt" -H "Authorization: Bearer $(cat "$SA/token")" "$K8S$CM"; fi; }
set_state(){ c="$(k8s PATCH /tmp/p.json "{\"data\":{\"$KEY\":\"$RELEASE_ID\"}}")" || fail "update gate-state: request failed (curl)"; [ "$c" = 200 ] || fail "update gate-state HTTP $c (the change-log line is already written; the next run asks again)"
  echo "gate-state $KEY = $RELEASE_ID"; }

echo "== gate $(now)  app $APP  lane $LANE  release $RELEASE_ID  timeout ${GATE_TIMEOUT_SECONDS}s"
c="$(k8s GET /tmp/s.json)" || fail "read gate-state: request failed (curl)"; [ "$c" = 200 ] || fail "read gate-state HTTP $c"
K="$(printf '%s' "$KEY" | sed 's/[.]/\\./g')"
LAST="$(tr ',{' '\n\n' < /tmp/s.json | sed -n "s/.*\"$K\": *\"\([^\"]*\)\".*/\1/p" | head -n 1)"
echo "last approved release for $KEY: ${LAST:-none}"
if [ "$LAST" = "$RELEASE_ID" ]; then log no-change; echo "PASS: release unchanged, no ticket"; exit 0; fi
if [ "$LANE" = dev ]; then log auto-approved; set_state; echo "PASS: DEV auto-approved"; exit 0; fi

T="$APP-$LANE-$RELEASE_ID-$(date -u '+%Y%m%dT%H%M%SZ').ticket.txt"
[ -e "$AP/$T" ] && fail "ticket $T already exists"
START=$(date +%s); DEADLINE=$((START + GATE_TIMEOUT_SECONDS))
{ echo pending
  echo "# Change ticket: app $APP, lane $LANE, release $RELEASE_ID, created $(now) by the gate Job."
  echo "# To approve, replace 'pending' on line 1 with: yes    To reject: no    Only line 1 counts (any letter case)."
  echo "# Edit with VS Code or nano, not TextEdit. Waiting until $(date -u -d "@$DEADLINE" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "+${GATE_TIMEOUT_SECONDS}s") (timeout ${GATE_TIMEOUT_SECONDS}s);"
  echo "# after that this ticket is archived and a late answer does nothing."; } > "$AP/$T" || fail "cannot write ticket $AP/$T"
echo "ticket $T written; waiting for line 1 = yes or no"
D=timeout; MISS=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  # an editor that saves by write-new-then-replace can leave the ticket absent for a moment: missing twice in a row counts
  if [ ! -f "$AP/$T" ]; then MISS=$((MISS+1)); [ "$MISS" -ge 2 ] && { D=ticket-missing; break; }; sleep "$POLL"; continue; fi
  MISS=0
  a="$(answer "$AP/$T")"
  [ "$a" = yes ] && { D=approved; break; }
  [ "$a" = no ] && { D=rejected; break; }
  sleep "$POLL"
done
echo "decision: $D after $(( $(date +%s) - START )) s"
if [ "$D" != ticket-missing ]; then
  echo "# result: $D at $(now) by the gate Job" >> "$AP/$T" || fail "cannot append the result to the ticket"
  mkdir -p "$AP/archive" && mv "$AP/$T" "$AP/archive/$T" || fail "cannot archive the ticket"
  echo "ticket archived: archive/$T"
fi
log "$D" "$T"
[ "$D" = approved ] && { set_state; echo "PASS: PROD approved"; exit 0; }
echo "FAIL: PROD $D; the sync stops (no automatic retry)"; exit 1
