#!/usr/bin/env bash
# Builds everything this demo runs, using nothing from the host but Docker.
#
#   ./build.sh                        # then: docker compose up -d
#   ./build.sh --with-observability   # same, plus the workflow module that reports telemetry
#
# What it does:
#   1. Builds a Ballerina builder image (the toolchain lives in Docker, not on your machine).
#   2. Inside it: builds each integration against the released workflow module and ICP
#      runtime bridge from Ballerina Central. With --with-observability the workflow module
#      comes instead from prebuilt/, which is the only unreleased piece this demo can use.
#   3. Downloads the released ICP distribution (cached in prebuilt/) and stages the
#      integration jars plus the ICP's database init scripts out of it.
#
# docker compose then builds the runtime images from the staged artifacts.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

command -v docker >/dev/null 2>&1 || { echo "docker is required (and is the only prerequisite)" >&2; exit 1; }

WITH_OBS=0
for arg in "$@"; do
    case "$arg" in
        --with-observability) WITH_OBS=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
    esac
done

WORKFLOW_BALA="prebuilt/ballerina-workflow-java21-0.9.1.bala"
if [ "$WITH_OBS" = 1 ] && [ ! -f "$WORKFLOW_BALA" ]; then
    echo "--with-observability needs ${WORKFLOW_BALA} (see prebuilt/MANIFEST.md)" >&2
    exit 1
fi

ICP_VERSION="2.1.0-alpha3"
ICP_DIST="wso2-integration-control-plane-${ICP_VERSION}"
ICP_URL="https://github.com/wso2/integration-control-plane/releases/download/v${ICP_VERSION}/${ICP_DIST}.zip"
INTEGRATIONS=(claims bill-store notifications claims-agent)

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

log "Building the Ballerina builder image"
docker build -q -f docker/builder.Dockerfile -t claimflow/builder:local docker >/dev/null
echo "claimflow/builder:local"

if [ "$WITH_OBS" = 1 ]; then
    log "Building the integrations (workflow module 0.9.1 from prebuilt/, telemetry on)"
else
    log "Building the integrations (workflow module and bridge from Ballerina Central)"
fi
# One container run renders each Ballerina.toml and builds the integration. The repo is
# mounted read-write so bal build writes target/ and we can stage the jars. The Ballerina
# home lives on a named volume so Central packages are pulled once, not per run, and the
# compiler JVM is bounded so three consecutive builds fit in Docker memory.
docker run --rm -v "$HERE":/work -w /work \
    -v claimflow-bal-cache:/root/.ballerina \
    -e JAVA_OPTS=-Xmx2g \
    -e WITH_OBS="$WITH_OBS" \
    claimflow/builder:local bash -ec '
    if [ "$WITH_OBS" = 1 ]; then
        # Re-pushing an existing version is refused, and the compiled cache is keyed by
        # version alone, so a rebuilt 0.9.1 bala would be shadowed by the earlier BIR.
        rm -rf /root/.ballerina/repositories/local/bala/ballerina/workflow \
               /root/.ballerina/repositories/local/cache-*/ballerina/workflow \
               /root/.ballerina/repositories/central.ballerina.io/cache-*/ballerina/workflow
        bal push --repository=local prebuilt/ballerina-workflow-java21-0.9.1.bala
        DEP=$(printf "%s\n" "[[dependency]]" "org = \"ballerina\"" "name = \"workflow\"" "version = \"0.9.1\"" "repository = \"local\"")
    else
        DEP=""
    fi
    for name in '"${INTEGRATIONS[*]}"'; do
        awk -v dep="$DEP" "{ if (\$0 == \"@WORKFLOW_DEP@\") { if (dep != \"\") print dep } else print }" \
            "integrations/${name}/Ballerina.toml.tmpl" > "integrations/${name}/Ballerina.toml"
        echo "-- bal build integrations/${name}"
        # target/ caches dependency BIRs and Dependencies.toml locks the resolved versions;
        # both would pin the previous mode, so start from nothing.
        rm -rf "integrations/${name}/target" "integrations/${name}/Dependencies.toml"
        (cd "integrations/${name}" && bal build)
        mkdir -p "integrations/${name}/artifacts"
        cp "integrations/${name}"/target/bin/*.jar "integrations/${name}/artifacts/${name}.jar"
    done
'

log "Fetching the ICP distribution"
mkdir -p prebuilt
if [ -f "prebuilt/${ICP_DIST}.zip" ]; then
    echo "prebuilt/${ICP_DIST}.zip (cached)"
else
    # Downloaded and checksummed in containers, so the host needs no curl and no shasum.
    docker run --rm -v "$HERE/prebuilt":/out -w /out curlimages/curl:8.10.1 \
        -fSL --retry 3 -o "${ICP_DIST}.zip.part" "$ICP_URL"
    docker run --rm -v "$HERE/prebuilt":/out -w /out curlimages/curl:8.10.1 \
        -fsSL --retry 3 -o "${ICP_DIST}.zip.sha256" "${ICP_URL}.sha256"
    docker run --rm -v "$HERE/prebuilt":/out -w /out busybox sh -ec "
        mv ${ICP_DIST}.zip.part ${ICP_DIST}.zip
        sha256sum -c ${ICP_DIST}.zip.sha256
    " || { rm -f "prebuilt/${ICP_DIST}.zip"; echo "checksum failed" >&2; exit 1; }
    echo "prebuilt/${ICP_DIST}.zip"
fi

log "Staging the ICP database init scripts out of the distribution zip"
mkdir -p artifacts/db icp/artifacts
docker run --rm -v "$HERE":/work -w /work busybox sh -ec "
    unzip -o -q prebuilt/${ICP_DIST}.zip '${ICP_DIST}/dbscripts/postgresql_init.sql' '${ICP_DIST}/dbscripts/credentials_postgresql_init.sql' -d /tmp/icpzip
    cp /tmp/icpzip/${ICP_DIST}/dbscripts/postgresql_init.sql artifacts/db/
    cp /tmp/icpzip/${ICP_DIST}/dbscripts/credentials_postgresql_init.sql artifacts/db/
"
# The ICP image builds from ./icp, so the zip is copied in; older versions are cleared out.
rm -f icp/artifacts/*.zip
cp "prebuilt/${ICP_DIST}.zip" "icp/artifacts/${ICP_DIST}.zip"

log "Done"
echo "Next: docker compose up -d"
echo "Console: https://localhost:\${CONSOLE_PORT:-9664}  (admin/admin — note the https)"
