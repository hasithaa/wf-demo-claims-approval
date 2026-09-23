#!/usr/bin/env bash
# Populates the demo with AI-filed claims: real Smart Claim agent runs, each parked
# somewhere different, so the console and the portal both have agent data to show.
#
#   bob   $2400 hotel    -> over $1000, so the agent opens an attachment case and waits
#   jane  $640  taxi     -> straight through to the accountant's payment gate, left pending
#   john  $4200 dental   -> also over $1000: a second claim waiting on its document
#   bob   $180  parking  -> to the gate, and the seeder releases it, so one run is PAID
#
# Every run here is a genuine durable-agent execution: the tool calls, the human tasks
# and the gates are all real, and each conversation is left live, so opening it in the
# portal and typing carries it on from where the seed stopped.
#
# One seam worth knowing. A conversation normally starts from the portal, which hands
# the agent `user=<name>` as its run context and then sends what the person typed as a
# separate chat turn. The ICP can start a workflow but cannot send it a data event, so
# a seeded run can carry the person's FIRST MESSAGE or their NAME, not both — the
# agent reads a `user=` query as context and never as something typed. These runs carry
# the message, and the seeder stamps the identity afterwards: the claim's `submitted_by`
# and the conversation's owner. Everything else is the agent's own doing.
#
#   scripts/seed-agent-data.sh                 # all four
#   scripts/seed-agent-data.sh jane            # every story for one person
#   scripts/seed-agent-data.sh bob-parking     # one story, by its tag
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
PRESET_CONSOLE="${CONSOLE:-}"; PRESET_CONSOLE_PORT="${CONSOLE_PORT:-}"
[ -f .env ] && { set -a; . ./.env; set +a; }
CONSOLE_PORT="${PRESET_CONSOLE_PORT:-${CONSOLE_PORT:-9664}}"
CONSOLE="${PRESET_CONSOLE:-https://localhost:${CONSOLE_PORT}}"
ENV_ID="${ICP_ENVIRONMENT_ID:-750e8400-e29b-41d4-a716-446655440001}"
ADMIN="${ICP_ADMIN_USER:-admin}"; PASSWORD="${ICP_ADMIN_PASSWORD:-admin}"
OUT="$(mktemp)"; BODY="$(mktemp)"
trap 'rm -f "$OUT" "$BODY"' EXIT

say() { printf '\033[1m%s\033[0m\n' "$*"; }
psql_claims() { docker compose exec -T appdb psql -qtAX -U app -d claims_db "$@"; }

say "Signing in as ${ADMIN}"
printf '{"username":"%s","password":"%s"}' "$ADMIN" "$PASSWORD" > "$BODY"
TOKEN=$(curl -sk -X POST "$CONSOLE/auth/login" -H 'Content-Type: application/json' -d @"$BODY" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

CID=$(docker compose exec -T postgres psql -qtAX -U "${POSTGRES_SUPERUSER:-postgres}" -d "${ICP_DB_NAME:-icp_db}" \
    -c "SELECT component_id FROM components WHERE name='claims-agent'")
[ -n "$CID" ] || { echo "the claims-agent integration has not registered yet — give it a heartbeat interval" >&2; exit 1; }
BASE="$CONSOLE/icp/workflow/$CID/$ENV_ID"

# The tunnel answers a read with 202 FETCHING while a runtime materializes it; poll until it settles.
wf_read() {
    local path="$1" code i
    for i in $(seq 1 40); do
        code=$(curl -sk -o "$OUT" -w '%{http_code}' "$BASE/$path" -H "Authorization: Bearer $TOKEN")
        [ "$code" = "200" ] && return 0
        [ "$code" = "202" ] || { echo "   !! $path answered $code" >&2; return 1; }
        sleep 1
    done
    echo "   !! $path never settled" >&2
    return 1
}

# Starts one conversation and prints its workflow id. The start is a mutation, so the
# console polls the operation rather than holding the request open.
start_conversation() {
    local message="$1"
    python3 -c "
import json, sys
print(json.dumps({'workflowType': 'claimAgent',
                  'input': {'query': sys.argv[1], 'input': {}}}))" "$message" > "$BODY"
    curl -sk -o "$OUT" -X POST "$BASE/workflows" -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' -d @"$BODY" > /dev/null
    local op
    op=$(python3 -c "import json; print(json.load(open('$OUT')).get('operationId',''))")
    [ -n "$op" ] || { echo "   !! the start was refused: $(head -c 200 "$OUT")" >&2; return 1; }
    local i wf
    for i in $(seq 1 40); do
        curl -sk -o "$OUT" "$BASE/operations/$op" -H "Authorization: Bearer $TOKEN" > /dev/null
        wf=$(python3 -c "
import json
d = json.load(open('$OUT'))
r = d.get('result') or d.get('body') or d
print(r.get('workflowId', '') if isinstance(r, dict) else '')")
        [ -n "$wf" ] && { echo "$wf"; return 0; }
        sleep 1
    done
    echo "   !! the start never reported a workflow id" >&2
    return 1
}

# Waits until the agent's turn settles — it either parks on the next chat message or
# finishes. Both read as "no activity started in the last few seconds".
settle() {
    local wf="$1" i prev="" now
    for i in $(seq 1 45); do
        wf_read "workflows/$wf/activity-tree" || return 1
        now=$(python3 -c "
import json
d = json.load(open('$OUT'))
nodes = d if isinstance(d, list) else d.get('nodes', [])
print(len(nodes))")
        [ "$now" = "$prev" ] && [ "$i" -gt 3 ] && return 0
        prev="$now"
        sleep 2
    done
    return 0
}

# Hands the run to its person: the claim's submitter, the conversation's owner, and the
# person's own first message in the transcript, placed after the agent's greeting where
# the portal would have put it.
adopt() {
    local wf="$1" who="$2" message="$3"
    psql_claims -v ON_ERROR_STOP=1 -c "
        INSERT INTO agent_conversations (conversation_id, username, status)
        VALUES ('$wf', '$who', 'OPEN') ON CONFLICT (conversation_id) DO UPDATE SET username = '$who';
        UPDATE claims SET submitted_by = '$who' WHERE workflow_id = '$wf';
        -- The transcript is ordered by id, and the agent's replies were written while the
        -- run believed it had no named user. Rebuilding it puts the person's message where
        -- they would have typed it: after the greeting, before the answers to it.
        CREATE TEMP TABLE seed_turns AS
            SELECT who, text, token, pending, created_at FROM agent_turns
             WHERE conversation_id = '$wf' ORDER BY id;
        DELETE FROM agent_turns WHERE conversation_id = '$wf';
        INSERT INTO agent_turns (conversation_id, who, text, token, pending, created_at)
            SELECT '$wf', who, text, token, pending, created_at FROM seed_turns LIMIT 1;
        INSERT INTO agent_turns (conversation_id, who, text, created_at)
            VALUES ('$wf', 'me', \$seed\$$message\$seed\$, now());
        INSERT INTO agent_turns (conversation_id, who, text, token, pending, created_at)
            SELECT '$wf', who, text, token, pending, created_at FROM (
                SELECT who, text, token, pending, created_at,
                       row_number() OVER (ORDER BY created_at) AS rn FROM seed_turns) t
             WHERE rn > 1;
        DROP TABLE seed_turns;" > /dev/null
}

seed_one() {
    local who="$1" message="$2" label="$3"
    say "$label"
    local wf
    wf=$(start_conversation "$message") || return 1
    echo "   -> conversation $wf"
    settle "$wf"
    adopt "$wf" "$who" "$message"
    psql_claims -c "
        SELECT '   -> ' || claim_id || ' ' || status || ' \$' || amount || ' for ' || submitted_by
          FROM claims WHERE workflow_id = '$wf'" | sed '/^$/d'
}

# Releases the payment the agent parked on, the way an accountant would from the console.
release_gate() {
    local wf="$1" task="" i op
    for i in $(seq 1 30); do
        wf_read "review-activities?status=PENDING&limit=50" || return 1
        task=$(python3 -c "
import json
d = json.load(open('$OUT'))
items = d.get('items', d if isinstance(d, list) else [])
print(next((t.get('taskId', '') for t in items if t.get('parentWorkflowId') == '$wf'), ''))")
        [ -n "$task" ] && break
        sleep 2
    done
    [ -n "$task" ] || { echo "   !! no payment gate appeared for $wf" >&2; return 1; }
    curl -sk -o "$OUT" -X POST "$BASE/review-activities/$task/proceed" \
        -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}' > /dev/null
    op=$(python3 -c "import json; print(json.load(open('$OUT')).get('operationId',''))")
    [ -n "$op" ] || { echo "   !! the release was refused: $(head -c 200 "$OUT")" >&2; return 1; }
    for i in $(seq 1 30); do
        curl -sk -o "$OUT" "$BASE/operations/$op" -H "Authorization: Bearer $TOKEN" > /dev/null
        case "$(python3 -c "import json; print(json.load(open('$OUT')).get('status',''))")" in
            COMPLETED) echo "   -> payment released"; return 0 ;;
            FAILED|EXPIRED) echo "   !! the release failed"; return 1 ;;
        esac
        sleep 1
    done
    echo "   -> release still in flight"
}

# Each story has a tag (`bob-hotel`); an argument selects it by tag or by person.
wanted() {
    [ "$#" -eq 1 ] && return 0
    local tag="$1"; local who="${tag%%-*}"; shift
    for name in "$@"; do
        [ "$name" = "$tag" ] || [ "$name" = "$who" ] && return 0
    done
    return 1
}

if wanted bob-hotel "$@"; then
seed_one bob  "I stayed overnight near the clinic after my appointment and paid 2400 for the hotel. Can you claim it?" \
              "Bob claims a 2400 hotel stay — over \$1000, so the agent asks for the bill"
fi
if wanted jane-taxi "$@"; then
seed_one jane "Took a taxi to the regional office and back for the audit, 640 in total." \
              "Jane claims a 640 taxi run — straight through to the payment gate"
fi
if wanted john-dental "$@"; then
seed_one john "Emergency dental work while travelling for the quarter close, 4200 all in." \
              "John claims 4200 of dental work — a second claim waiting on its document"
fi
if wanted bob-parking "$@"; then
say "Bob claims 180 of parking — and the accountant releases it, so one run runs to PAID"
PAID_WF=$(start_conversation "Parked at the client site all week for the quarter close, 180 in parking fees.") || exit 1
echo "   -> conversation $PAID_WF"
settle "$PAID_WF"
adopt "$PAID_WF" bob "Parked at the client site all week for the quarter close, 180 in parking fees."
release_gate "$PAID_WF"
settle "$PAID_WF"
psql_claims -c "
    SELECT '   -> ' || claim_id || ' ' || status || ' \$' || amount || ' for ' || submitted_by
      FROM claims WHERE workflow_id = '$PAID_WF'" | sed '/^$/d'
fi

say "What the agents left behind"
wf_read "human-tasks?status=PENDING&limit=50" && python3 -c "
import json
d = json.load(open('$OUT'))
items = d.get('items', d if isinstance(d, list) else [])
print(f'   -> {len(items)} human task(s) waiting') if items else print('   -> no human tasks waiting')
for t in items[:6]:
    print('      -', t.get('taskName') or t.get('name'), t.get('status'))"
wf_read "review-activities?status=PENDING&limit=50" && python3 -c "
import json
d = json.load(open('$OUT'))
items = d.get('items', d if isinstance(d, list) else [])
print(f'   -> {len(items)} review(s) waiting') if items else print('   -> no reviews waiting')
for t in items[:6]:
    print('      -', t.get('taskName') or t.get('name'), t.get('trigger'), t.get('status'))"

say "Done. Open Workflows in the console, or sign in to the portal as bob, jane or john."
