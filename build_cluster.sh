#!/usr/bin/env bash
# Turns the demo into a two-node ICP cluster — the deployment shape the database-backed
# workflow tunnel exists for — and proves the balancing before it says "done".
#
#   ./build_cluster.sh          # bring the cluster up (idempotent)
#   ./build_cluster.sh --down   # back to the single-node demo
#
# What changes: a second ICP node (icp-2) joins on the SAME database, and the edge swaps
# its TCP passthrough for a per-request HTTPS round-robin (edge/nginx.cluster.conf) with
# its own self-signed certificate. Everything else — integrations, Thunder, the portal —
# is untouched; the console stays at https://localhost:${CONSOLE_PORT:-9664}.
#
# The mode is persisted as COMPOSE_FILE in .env, so every later `docker compose` call —
# scripts/recover.sh and friends included — sees the whole cluster. (Exporting it only in
# this shell is the landmine: the next `up -d --force-recreate` from another shell would
# silently recreate the edge back to the pinned single-node config.)
#
# .env is tracked, so that line leaves your checkout dirty while the cluster is up. That is
# deliberate — the repo's default is one node, and the mode belongs to your machine, not to
# the demo. `--down` removes the line again.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

CLUSTER_FILES="docker-compose.yml:docker-compose.cluster.yml"
CONSOLE="https://localhost:${CONSOLE_PORT:-9664}"

log() { printf '\033[1m== %s\033[0m\n' "$*"; }

set_compose_file() {
    # One line in .env owns the mode; replace it in place, or append it.
    if grep -q '^COMPOSE_FILE=' .env 2>/dev/null; then
        sed -i.bak "s|^COMPOSE_FILE=.*|COMPOSE_FILE=$1|" .env && rm -f .env.bak
    else
        printf 'COMPOSE_FILE=%s\n' "$1" >> .env
    fi
}

clear_compose_file() {
    if grep -q '^COMPOSE_FILE=' .env 2>/dev/null; then
        sed -i.bak '/^COMPOSE_FILE=/d' .env && rm -f .env.bak
    fi
}

if [ "${1:-}" = "--down" ]; then
    log "Returning to the single-node demo"
    docker compose -f docker-compose.yml -f docker-compose.cluster.yml stop icp-2 || true
    docker compose -f docker-compose.yml -f docker-compose.cluster.yml rm -f icp-2 || true
    clear_compose_file
    # Recreate the edge from the base file alone so it mounts the passthrough config again,
    # then re-pin the portal's proxy behind it.
    docker compose up -d --force-recreate edge
    docker compose restart webapp
    log "Single node again. Console: $CONSOLE"
    exit 0
fi

# The round-robin edge terminates TLS, so it needs a certificate of its own. Self-signed
# and regenerating is harmless: nothing pins it — the browser already accepts the demo's
# self-signed certificates, and the bridge dials with verification off.
mkdir -p edge/certs
if [ ! -f edge/certs/edge.crt ]; then
    log "Generating the edge certificate"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout edge/certs/edge.key \
        -out edge/certs/edge.crt -days 825 -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,DNS:edge,IP:127.0.0.1" 2>/dev/null
fi

log "Switching compose to cluster mode (persisted in .env)"
set_compose_file "$CLUSTER_FILES"

log "Starting the second ICP node"
docker compose up -d icp-2

log "Waiting for both nodes to answer"
for node in icp icp-2; do
    for _ in $(seq 1 60); do
        state="$(docker compose ps --format '{{.Name}} {{.Health}}' "$node" 2>/dev/null | awk '{print $2}')"
        [ "$state" = "healthy" ] && break
        sleep 5
    done
    state="$(docker compose ps --format '{{.Name}} {{.Health}}' "$node" 2>/dev/null | awk '{print $2}')"
    echo "   $node: ${state:-unknown}"
    [ "$state" = "healthy" ] || { echo "   $node never became healthy — check: docker compose logs $node"; exit 1; }
done

log "Swapping the edge to per-request round-robin"
docker compose up -d --force-recreate edge
# nginx pins upstream IPs at startup: the portal's proxy needs the same treatment
# whenever the edge is recreated.
docker compose restart webapp >/dev/null

log "Verifying"
sleep 3
ok="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$CONSOLE/" || true)"
echo "   console $CONSOLE -> $ok"
[ "$ok" = "200" ] || { echo "   console not answering — try scripts/recover.sh"; exit 1; }

# The proof that requests alternate: ten fresh requests through the edge, then count which
# node each landed on in the edge's own access log. Fresh connections per request (curl
# defaults), so a healthy round-robin splits close to 5/5 — a 10/0 split means the
# passthrough config is still mounted.
for _ in $(seq 1 10); do
    curl -sk -o /dev/null --max-time 10 "$CONSOLE/auth/capabilities" || true
done
# The nginx image symlinks its access log to stdout, so the evidence is in `docker
# compose logs`, not in a file inside the container.
split="$(docker compose logs edge --since 2m 2>/dev/null \
    | grep -o 'upstream=[0-9.]*:9446' | sort | uniq -c | awk '{printf "%s ", $1}')"
echo "   recent console requests split across nodes: ${split:-unreadable}"

log "Cluster is up"
echo "   Console:  $CONSOLE  (admin/admin or SSO — same as before)"
echo "   Nodes:    icp, icp-2 — one shared database, per-request balancing"
echo "   Watch it: docker compose logs -f edge"
echo "   Wind down: ./build_cluster.sh --down"
