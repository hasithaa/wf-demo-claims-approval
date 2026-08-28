#!/usr/bin/env bash
# Walks one claim through the whole process from the command line — the same steps the
# README describes for the console. Useful as a smoke test and as the demo's dry run.
#
#   scripts/walkthrough.sh            # against https://localhost:${CONSOLE_PORT:-9664}
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
# Explicit environment wins over .env defaults (sourcing would otherwise clobber it).
PRESET_CONSOLE="${CONSOLE:-}"; PRESET_CLAIMS="${CLAIMS:-}"
PRESET_CONSOLE_PORT="${CONSOLE_PORT:-}"; PRESET_CLAIMS_PORT="${CLAIMS_PORT:-}"
[ -f .env ] && { set -a; . ./.env; set +a; }
CONSOLE_PORT="${PRESET_CONSOLE_PORT:-${CONSOLE_PORT:-9664}}"
CLAIMS_PORT="${PRESET_CLAIMS_PORT:-${CLAIMS_PORT:-9080}}"

CONSOLE="${PRESET_CONSOLE:-https://localhost:${CONSOLE_PORT}}"
CLAIMS="${PRESET_CLAIMS:-http://localhost:${CLAIMS_PORT}}"
ENV_ID="${ICP_ENVIRONMENT_ID:-750e8400-e29b-41d4-a716-446655440001}"
ADMIN="${ICP_ADMIN_USER:-admin}"; PASSWORD="${ICP_ADMIN_PASSWORD:-admin}"
OUT="$(mktemp)"; BODY="$(mktemp)"
trap 'rm -f "$OUT" "$BODY"' EXIT

say() { printf '\033[1m%s\033[0m\n' "$*"; }
jqr() { python3 -c "import json,sys; d=json.load(open('$OUT')); $1"; }

say "Signing in as ${ADMIN}"
printf '{"username":"%s","password":"%s"}' "$ADMIN" "$PASSWORD" > "$BODY"
TOKEN=$(curl -sk -X POST "$CONSOLE/auth/login" -H 'Content-Type: application/json' -d @"$BODY" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

CID=$(docker compose exec -T postgres psql -qtAX -U "${POSTGRES_SUPERUSER:-postgres}" -d "${ICP_DB_NAME:-icp_db}" \
    -c "SELECT component_id FROM components WHERE name='claims'")
[ -n "$CID" ] || { echo "the claims integration has not registered yet — give it a heartbeat interval" >&2; exit 1; }

# A read may answer 202 FETCHING while a runtime materializes it; poll until it settles.
wf_read() {
    local path="$1" code i
    for i in $(seq 1 30); do
        code=$(curl -sk -o "$OUT" -w '%{http_code}' \
            "$CONSOLE/icp/workflow/$CID/$ENV_ID/$path" -H "Authorization: Bearer $TOKEN")
        [ "$code" != "202" ] && { printf '%s' "$code"; return 0; }
        sleep 3
    done
    printf '%s' "$code"
}

# A mutation answers 202 {operationId}; poll the operation until the runtime confirms it.
wf_mutate() {
    local path="$1" code op i
    code=$(curl -sk -o "$OUT" -w '%{http_code}' -X POST \
        "$CONSOLE/icp/workflow/$CID/$ENV_ID/$path" \
        -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d @"$BODY")
    if [ "$code" = "202" ]; then
        op=$(jqr 'print(d.get("operationId",""))')
        [ -n "$op" ] || { printf '%s' "$code"; return 0; }
        for i in $(seq 1 60); do
            code=$(curl -sk -o "$OUT" -w '%{http_code}' \
                "$CONSOLE/icp/workflow/$CID/$ENV_ID/operations/$op" -H "Authorization: Bearer $TOKEN")
            [ "$code" != "202" ] && break
            sleep 2
        done
    fi
    printf '%s' "$code"
}

# The pending task raised by one specific instance, excluding ids already decided —
# the task list is served stale-while-revalidate, so a just-completed task can linger
# in it for a refresh cycle and must not be matched again.
task_for() {
    local wfid="$1" exclude="${2:-}" i task code
    for i in $(seq 1 20); do
        code=$(wf_read "human-tasks?status=PENDING&refresh=true")
        task=$(jqr "
items = d.get('items') or []
m = [t for t in items
     if t.get('parentWorkflowId') == '$wfid' and t.get('taskId') not in '$exclude'.split(',')]
print(m[0]['taskId'] if m else '')")
        [ -n "$task" ] && { printf '%s' "$task"; return 0; }
        sleep 4
    done
    return 1
}

STAMP=$(date +%H%M%S)
CLAIM="CLM-${STAMP}"

say "1. Alice submits claim ${CLAIM} for 2400 (no bill attached)"
printf '{"workflowType":"claimApproval","input":{"id":"%s","amount":2400,"submittedBy":"alice"}}' "$CLAIM" > "$BODY"
code=$(wf_mutate "workflows")
WFID=$(jqr 'print(d.get("workflowId",""))')
echo "   -> $code  workflowId=$WFID"
[ -n "$WFID" ] || { cat "$OUT" >&2; exit 1; }

say "2. The manager's review appears"
TASK=$(task_for "$WFID"); echo "   -> task $TASK"

say "3. Manager asks for the bill (REQUEST_BILL)"
printf '{"result":{"outcome":"REQUEST_BILL","comment":"need the receipt"}}' > "$BODY"
echo "   -> $(wf_mutate "human-tasks/$TASK/complete")"

say "4. Alice attaches the bill (through the integration, not the ICP)"
code=$(curl -s -o "$OUT" -w '%{http_code}' -X POST "$CLAIMS/claims/$WFID/bills" \
    -H 'Content-Type: application/json' -d "{\"url\": \"https://bills/${CLAIM}.pdf\"}")
echo "   -> $code $(cat "$OUT")"

say "5. The review returns with the bill; manager approves"
TASK2=$(task_for "$WFID" "$TASK"); echo "   -> task $TASK2"
printf '{"result":{"outcome":"APPROVE"}}' > "$BODY"
echo "   -> $(wf_mutate "human-tasks/$TASK2/complete")"

say "6. The accountant releases the payment"
TASK3=$(task_for "$WFID" "$TASK,$TASK2"); echo "   -> task $TASK3"
printf '{"result":{"approved":true,"account":"ACC-77"}}' > "$BODY"
echo "   -> $(wf_mutate "human-tasks/$TASK3/complete")"

say "7. The claim completes"
for i in $(seq 1 15); do
    code=$(wf_read "workflows/$WFID?refresh=true")
    status=$(jqr 'print(d.get("status",""))')
    [ "$status" = "COMPLETED" ] && break
    sleep 4
done
jqr "print('   -> ' + d.get('status','?') + '  result: ' + json.dumps(d.get('result'))[:160])"
