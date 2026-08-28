#!/usr/bin/env bash
# Renders Config.toml from the environment, then runs the integration.
#
# The org secret cannot be baked into the image: it only exists once a running ICP has
# issued it. The `seed` compose service mints one and writes it to the shared secrets
# volume; this entrypoint waits for that file — which is what lets `docker compose up`
# be the only command anyone runs.
set -euo pipefail

: "${ICP_SERVER_URL:=https://edge:9445}"
: "${ICP_PROJECT:=claimflow}"
: "${ICP_ENVIRONMENT:=dev}"
: "${TEMPORAL_URL:=temporal:7233}"
: "${HEARTBEAT_INTERVAL:=10}"
: "${THUNDER_PUBLIC_URL:=https://localhost:8090}"
: "${ICP_ORG_SECRET_FILE:=}"

if [ -z "${ICP_ORG_SECRET:-}" ] && [ -n "${ICP_ORG_SECRET_FILE}" ]; then
    echo "[entrypoint] waiting for the org secret at ${ICP_ORG_SECRET_FILE} (minted by the seed service)"
    for i in $(seq 1 120); do
        [ -s "${ICP_ORG_SECRET_FILE}" ] && break
        sleep 5
    done
    [ -s "${ICP_ORG_SECRET_FILE}" ] || { echo "[entrypoint] no org secret after 10 minutes — check: docker compose logs seed" >&2; exit 1; }
    ICP_ORG_SECRET="$(cat "${ICP_ORG_SECRET_FILE}")"
fi
: "${ICP_ORG_SECRET:?ICP_ORG_SECRET (or ICP_ORG_SECRET_FILE) is required}"

sed -e "s|@ICP_SERVER_URL@|${ICP_SERVER_URL}|g" \
    -e "s|@ICP_ORG_SECRET@|${ICP_ORG_SECRET}|g" \
    -e "s|@ICP_PROJECT@|${ICP_PROJECT}|g" \
    -e "s|@ICP_ENVIRONMENT@|${ICP_ENVIRONMENT}|g" \
    -e "s|@TEMPORAL_URL@|${TEMPORAL_URL}|g" \
    -e "s|@HEARTBEAT_INTERVAL@|${HEARTBEAT_INTERVAL}|g" \
    -e "s|@THUNDER_PUBLIC_URL@|${THUNDER_PUBLIC_URL}|g" \
    /app/Config.toml.tmpl > /app/Config.toml

# The WSO2 default model provider is opt-in: the section only exists when a token is
# supplied, so `ai:getDefaultModelProvider()` fails cleanly and the agent falls back to
# its scripted model when it is not.
if [ -n "${WSO2_AI_TOKEN:-}" ]; then
    cat >> /app/Config.toml <<TOML

[ballerina.ai.wso2ProviderConfig]
serviceUrl = "${WSO2_AI_SERVICE_URL:?WSO2_AI_SERVICE_URL is required when WSO2_AI_TOKEN is set}"
accessToken = "${WSO2_AI_TOKEN}"
TOML
    echo "[entrypoint] WSO2 default model provider configured"
fi

echo "[entrypoint] $(hostname): temporal=${TEMPORAL_URL} icp=${ICP_SERVER_URL} project=${ICP_PROJECT}"
export BAL_CONFIG_FILES=/app/Config.toml
exec java -jar /app/app.jar
