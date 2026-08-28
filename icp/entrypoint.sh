#!/usr/bin/env bash
# Renders conf/deployment.toml from the template, then runs the server in the foreground so
# Docker owns the process lifecycle (bin/icp.sh start would daemonise and exit).
set -euo pipefail

: "${ICP_DB_HOST:=postgres}"
: "${ICP_DB_NAME:=icp_db}"
: "${ICP_DB_USER:=icp_user}"
: "${ICP_DB_PASSWORD:=icp_password}"
: "${ICP_PUBLIC_BASE_URL:=https://localhost:9446}"
: "${ICP_NODE_ID:=icp-1}"
: "${SSO_ENABLED:=false}"
: "${THUNDER_PUBLIC_URL:=https://localhost:8090}"
: "${THUNDER_INTERNAL_URL:=https://thunder:8090}"
: "${ICP_SSO_CLIENT_SECRET:=icp-console-secret}"

sed -e "s|@ICP_DB_HOST@|${ICP_DB_HOST}|g" \
    -e "s|@ICP_DB_NAME@|${ICP_DB_NAME}|g" \
    -e "s|@ICP_DB_USER@|${ICP_DB_USER}|g" \
    -e "s|@ICP_DB_PASSWORD@|${ICP_DB_PASSWORD}|g" \
    -e "s|@ICP_PUBLIC_BASE_URL@|${ICP_PUBLIC_BASE_URL}|g" \
    -e "s|@SSO_ENABLED@|${SSO_ENABLED}|g" \
    -e "s|@THUNDER_PUBLIC_URL@|${THUNDER_PUBLIC_URL}|g" \
    -e "s|@THUNDER_INTERNAL_URL@|${THUNDER_INTERNAL_URL}|g" \
    -e "s|@ICP_SSO_CLIENT_SECRET@|${ICP_SSO_CLIENT_SECRET}|g" \
    /opt/icp/conf/deployment.toml.tmpl > /opt/icp/conf/deployment.toml

echo "[entrypoint] ${ICP_NODE_ID}: postgresql://${ICP_DB_USER}@${ICP_DB_HOST}/${ICP_DB_NAME}, public ${ICP_PUBLIC_BASE_URL}"
exec /opt/icp/bin/icp.sh run
