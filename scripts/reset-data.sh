#!/usr/bin/env bash
# Starts the demo over: wipes every piece of USER data while leaving the installation
# intact — Thunder identities, ICP components/config, and the SSO wiring all survive,
# so the stack is immediately demoable again with empty screens.
#
# What goes: all claims, agent conversations/turns/cases, uploaded bills (rows and
# files), notifications, and every open workflow execution (running claims, parked
# agents, and their orphaned human-task / review children) in the Temporal namespace.
#
#   scripts/reset-data.sh        # asks first
#   scripts/reset-data.sh -y     # no questions
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

if [ "${1:-}" != "-y" ]; then
  printf 'This wipes ALL demo data (claims, chats, bills, notifications) and terminates\n'
  printf 'every open workflow execution. Identities and configuration survive. Continue? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) echo "aborted."; exit 1;; esac
fi

echo "-- terminating every open workflow execution"
# Batch-terminate everything still open: claim workflows, agent runs, and the
# human-task / review-activity children a terminated parent leaves behind.
docker compose exec -T temporal temporal workflow terminate \
  --address temporal:7233 --namespace default \
  --query 'ExecutionStatus="Running"' \
  --reason "demo reset: starting from scratch" --yes >/dev/null 2>&1 || true
sleep 3
open_count="$(docker compose exec -T temporal temporal workflow count \
  --address temporal:7233 --namespace default \
  --query 'ExecutionStatus="Running"' 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo '?')"
echo "   open executions remaining: ${open_count}"

echo "-- wiping the application databases"
docker compose exec -T appdb psql -q -U app -d claims_db -c \
  "TRUNCATE claims, agent_conversations, agent_turns, attachment_cases" >/dev/null
docker compose exec -T appdb psql -q -U app -d bills_db -c "TRUNCATE bills" >/dev/null
docker compose exec -T appdb psql -q -U app -d notifications_db -c "TRUNCATE notifications" >/dev/null

echo "-- deleting uploaded bill files"
docker compose exec -T bill-store sh -c 'find /data/bills -type f -delete 2>/dev/null || true'

echo "done. The portal and the console now show a clean slate;"
echo "seed a lived-in look with: scripts/seed-demo-data.sh"
