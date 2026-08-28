#!/usr/bin/env bash
# Builds everything this demo runs, using nothing from the host but Docker.
#
#   ./build.sh            # then: docker compose up -d
#
# What it does:
#   1. Builds a Ballerina builder image (the toolchain lives in Docker, not on your machine).
#   2. Inside it: publishes the prebuilt workflow-module and bridge balas to the
#      container-local Ballerina repository, then builds each integration against them.
#   3. Stages the integration jars and extracts the ICP's database init scripts from the
#      prebuilt distribution zip.
#
# docker compose then builds the runtime images from the staged artifacts.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

command -v docker >/dev/null 2>&1 || { echo "docker is required (and is the only prerequisite)" >&2; exit 1; }

ICP_DIST="wso2-integration-control-plane-2.0.0-SNAPSHOT"
INTEGRATIONS=(claims bill-store notifications)

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

log "Building the Ballerina builder image"
docker build -q -f docker/builder.Dockerfile -t claimflow/builder:local docker >/dev/null
echo "claimflow/builder:local"

log "Building the integrations inside the builder"
# One container run does it all: push the prebuilt balas into the container's local bala
# repository, then build each integration. The repo is mounted read-write so `bal build`
# writes target/ and we can stage the jars; nothing else on the host is touched. The
# Ballerina home lives on a named volume so Central packages are pulled once, not per run,
# and the compiler JVM is bounded so three consecutive builds fit in Docker's memory.
docker run --rm -v "$HERE":/work -w /work \
    -v claimflow-bal-cache:/root/.ballerina \
    -e JAVA_OPTS=-Xmx2g \
    claimflow/builder:local bash -ec '
    # Re-pushing an existing version is refused; clear our two from the local repo first.
    rm -rf /root/.ballerina/repositories/local/bala/ballerina/workflow \
           /root/.ballerina/repositories/local/bala/wso2/icp.runtime.bridge
    bal push --repository=local prebuilt/ballerina-workflow-java21-0.9.0.bala
    bal push --repository=local prebuilt/wso2-icp.runtime.bridge-java21-0.3.0-SNAPSHOT.bala
    for name in '"${INTEGRATIONS[*]}"'; do
        echo "-- bal build integrations/${name}"
        (cd "integrations/${name}" && bal build)
        mkdir -p "integrations/${name}/artifacts"
        cp "integrations/${name}"/target/bin/*.jar "integrations/${name}/artifacts/${name}.jar"
    done
'

log "Staging the ICP database init scripts out of the distribution zip"
mkdir -p artifacts/db icp/artifacts
docker run --rm -v "$HERE":/work -w /work busybox sh -ec "
    unzip -o -q prebuilt/${ICP_DIST}.zip '${ICP_DIST}/dbscripts/postgresql_init.sql' '${ICP_DIST}/dbscripts/credentials_postgresql_init.sql' -d /tmp/icpzip
    cp /tmp/icpzip/${ICP_DIST}/dbscripts/postgresql_init.sql artifacts/db/
    cp /tmp/icpzip/${ICP_DIST}/dbscripts/credentials_postgresql_init.sql artifacts/db/
"
# The ICP image builds from ./icp; the zip stays in prebuilt/ (git) and is linked in by copy.
cp "prebuilt/${ICP_DIST}.zip" "icp/artifacts/${ICP_DIST}.zip"

log "Done"
echo "Next: docker compose up -d"
echo "Console: https://localhost:\${CONSOLE_PORT:-9664}  (admin/admin — note the https)"
