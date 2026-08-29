#!/usr/bin/env bash
# Follows one Smart Claim agent run end to end by its correlation chain: the agent's
# workflow instance ID ties the conversation, every turn's reply token, the attachment
# cases, and the claim rows together — this prints all of it, plus what Temporal says
# the run is doing right now. The first stop when a chat "looks stuck": a pending turn
# with a token means the reply is parked (a gate, a task, an event), not lost.
#
#   scripts/trace-agent.sh <conversationId|CLM-...>   # by run id, or by claim id
#   scripts/trace-agent.sh                            # traces the newest conversation
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

psql_claims() { docker compose exec -T appdb psql -U app -d claims_db "$@"; }

ID="${1:-}"
if [ -z "$ID" ]; then
  ID="$(psql_claims -qtAX -c \
    "SELECT conversation_id FROM agent_conversations ORDER BY created_at DESC LIMIT 1")"
  [ -n "$ID" ] || { echo "no agent conversations recorded yet."; exit 1; }
  echo "(tracing the newest conversation)"
fi
case "$ID" in
  CLM-*)
    WF="$(psql_claims -qtAX -c \
      "SELECT workflow_id FROM claims WHERE claim_id = '${ID}'")"
    [ -n "$WF" ] || { echo "no claim '${ID}' in the durable record."; exit 1; }
    echo "claim ${ID} was filed by run ${WF}"
    ID="$WF"
    ;;
esac

echo "== conversation =="
psql_claims -c "SELECT conversation_id, username, status, created_at
                  FROM agent_conversations WHERE conversation_id = '${ID}'"

echo "== turns (a pending row with a token is a reply parked behind a wait) =="
psql_claims -c "SELECT id, who, pending, token, left(coalesce(text, ''), 70) AS text, created_at
                  FROM agent_turns WHERE conversation_id = '${ID}' ORDER BY id"

echo "== attachment cases correlated to this run =="
psql_claims -c "SELECT case_id, claim_id, requested, status, bill_url, created_at, submitted_at
                  FROM attachment_cases WHERE workflow_id = '${ID}' ORDER BY created_at"

echo "== claims this run filed =="
psql_claims -c "SELECT claim_id, amount, status, bill_url, note, updated_at
                  FROM claims WHERE workflow_id = '${ID}' ORDER BY updated_at"

echo "== what Temporal says the run is doing =="
docker compose exec -T temporal temporal workflow describe \
  --address temporal:7233 --namespace default --workflow-id "$ID" 2>/dev/null \
  | grep -E "Status|WorkflowType|StartTime|CloseTime|HistoryLength" | head -6 || \
  echo "   (no execution found — the run may have aged out of retention)"

echo "== its open children (gates and human tasks parked on people) =="
docker compose exec -T temporal temporal workflow list \
  --address temporal:7233 --namespace default \
  --query "ExecutionStatus='Running' AND (WorkflowType STARTS_WITH 'reviewactivity-' OR WorkflowType STARTS_WITH 'humantask-')" \
  2>/dev/null | head -12 || true
echo "   (children list is namespace-wide; match by start time against the turns above)"
