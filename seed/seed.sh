#!/bin/sh
# First-boot seeding, run as a one-shot compose service on the ICP network.
#
# Mints one organization secret per integration against the running ICP and writes each
# to the shared secrets volume, where the integrations' entrypoints wait for them. The
# secret is the one value that cannot ship in an image or in git: it exists only once a
# running ICP has issued it. Idempotent: an already-minted secret is left alone, so
# restarting the stack does not rebind integrations to new keys.
set -eu

ICP_URL="${ICP_URL:-https://icp:9446}"
ADMIN_USER="${ICP_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ICP_ADMIN_PASSWORD:-admin}"
ENVIRONMENT_ID="${ICP_ENVIRONMENT_ID:-750e8400-e29b-41d4-a716-446655440001}"
SECRETS_DIR="${SECRETS_DIR:-/secrets}"
INTEGRATIONS="${INTEGRATIONS:-claims}"

echo "[seed] waiting for the ICP console at ${ICP_URL}"
i=0
until curl -sk --max-time 3 "${ICP_URL}/auth/capabilities" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -ge 60 ] && { echo "[seed] console did not come up; check: docker compose logs icp" >&2; exit 1; }
    sleep 5
done
echo "[seed] console is up"

token=$(curl -sk -X POST "${ICP_URL}/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASSWORD}\"}" \
    | jq -r '.token // empty')
[ -n "$token" ] || { echo "[seed] login failed - check the admin credentials" >&2; exit 1; }

# One secret per integration: a secret binds to the first project/component that presents
# it, and a second integration reusing it is rejected as "already bound".
for name in $INTEGRATIONS; do
    out="${SECRETS_DIR}/${name}.secret"
    if [ -s "$out" ]; then
        echo "[seed] ${name}: secret already minted, keeping it"
        continue
    fi
    secret=$(curl -sk -X POST "${ICP_URL}/graphql" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer ${token}" \
        -d "{\"query\":\"mutation { createOrgSecret(environmentId: \\\"${ENVIRONMENT_ID}\\\") }\"}" \
        | jq -r '.data.createOrgSecret // empty')
    [ -n "$secret" ] || { echo "[seed] could not mint a secret for ${name}" >&2; exit 1; }
    umask 077
    printf '%s' "$secret" > "${out}.tmp" && mv "${out}.tmp" "$out"
    echo "[seed] ${name}: secret minted"
done

echo "[seed] done"
