#!/usr/bin/env bash
# Diagnoses and heals the stack's known failure modes in one pass — the issues this
# demo has actually hit in the field, each with its specific recovery:
#
#   - The ICP connection-pool wedge ("Error getting user details", 500s on every
#     DB-backed view, console unreachable). Two faces, both handled: sessions stuck
#     idle-in-transaction on Postgres (terminated), and client-side pool exhaustion
#     inside the ICP (container restart).
#   - nginx's pinned upstreams: the edge and the webapp resolve container IPs at
#     startup, so any icp/service restart leaves them proxying into the void until
#     they restart too. This script always re-pins after healing.
#   - Plainly stopped or unhealthy containers.
#
#   scripts/recover.sh          # diagnose, heal what needs healing, report
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
PRESET_CONSOLE_PORT="${CONSOLE_PORT:-}"; PRESET_PORTAL_PORT="${PORTAL_PORT:-}"
[ -f .env ] && { set -a; . ./.env; set +a; }
CONSOLE_PORT="${PRESET_CONSOLE_PORT:-${CONSOLE_PORT:-9664}}"
PORTAL_PORT="${PRESET_PORTAL_PORT:-${PORTAL_PORT:-9090}}"

say() { printf '%s\n' "$*"; }
restarted_icp=false
restarted_services=false

say "== containers =="
docker compose ps --format '{{.Name}} {{.Status}}' | sed 's/^/   /'

# Anything not running comes up first.
stopped="$(docker compose ps --format '{{.Service}} {{.State}}' | awk '$2 != "running" {print $1}')"
if [ -n "$stopped" ]; then
  say "-- starting stopped services: $(echo "$stopped" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  docker compose up -d $stopped
  restarted_services=true
fi

say "== the ICP =="
console_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "https://localhost:${CONSOLE_PORT}/" || true)"
icp_health="$(docker compose ps icp --format '{{.Status}}')"
say "   console answers: ${console_code} | container: ${icp_health}"

# Face one of the wedge: sessions parked idle-in-transaction hold the pool hostage.
stuck="$(docker compose exec -T postgres psql -qtAX -U postgres -d icp_db -c \
  "SELECT count(*) FROM pg_stat_activity WHERE datname='icp_db' AND state='idle in transaction'" || echo 0)"
if [ "${stuck:-0}" -gt 0 ]; then
  say "-- terminating ${stuck} idle-in-transaction session(s) on icp_db"
  docker compose exec -T postgres psql -qtAX -U postgres -d icp_db -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='icp_db' AND state='idle in transaction'" >/dev/null
fi

# Face two: the ICP's own pool is exhausted (connections checked out and never
# returned) — Postgres looks idle while every ICP query times out after 30s.
pool_exhausted=false
if docker compose logs --since 5m icp 2>/dev/null | grep -q "Connection is not available"; then
  pool_exhausted=true
fi
if [ "$console_code" != "200" ] || [ "$pool_exhausted" = true ] || echo "$icp_health" | grep -q unhealthy; then
  say "-- restarting the ICP (console ${console_code}, pool exhausted: ${pool_exhausted})"
  docker compose restart icp >/dev/null
  sleep 20
  restarted_icp=true
fi

# nginx pins upstream IPs at startup: after any icp restart the edge must follow, and
# after service restarts the webapp must follow.
if [ "$restarted_icp" = true ]; then
  say "-- re-pinning the edge"
  docker compose restart edge >/dev/null
  sleep 8
fi
if [ "$restarted_services" = true ]; then
  say "-- re-pinning the webapp"
  docker compose restart webapp >/dev/null
  sleep 3
fi

say "== verdict =="
console_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://localhost:${CONSOLE_PORT}/" || true)"
portal_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://localhost:${PORTAL_PORT}/" || true)"
say "   console https://localhost:${CONSOLE_PORT} -> ${console_code}"
say "   portal  http://localhost:${PORTAL_PORT}  -> ${portal_code}"
if [ "$console_code" = "200" ] && [ "$portal_code" = "200" ]; then
  say "   healthy."
else
  say "   still unwell — check: docker compose logs --since 10m icp | tail -50"
  exit 1
fi
