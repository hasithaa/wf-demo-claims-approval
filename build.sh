#!/usr/bin/env bash
# Builds everything this demo runs, using nothing from the host but Docker.
#
#   ./build.sh          # then: docker compose up -d
#
# What it does:
#   1. Builds a Ballerina builder image (the toolchain lives in Docker, not on your machine).
#   2. Inside it: builds each integration against the prebuilt workflow module (the 0.10 task
#      model with task administrators, unreleased) and the released ICP runtime bridge.
#   3. Fetches the ICP distribution built from the matching console branch (cached in
#      prebuilt/) and stages the integration jars plus the ICP's database init scripts.
#
# docker compose then builds the runtime images from the staged artifacts.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

command -v docker >/dev/null 2>&1 || { echo "docker is required (and is the only prerequisite)" >&2; exit 1; }

for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
    esac
done

# The workflow module carrying task administrators: module-ballerina-workflow PR #131, packed
# on the released distribution, so nothing prerelease is needed to compile against it.
WORKFLOW_VERSION="0.9.1"
WORKFLOW_BALA="prebuilt/ballerina-workflow-java21-${WORKFLOW_VERSION}.bala"
BAL_RELEASE="2201.13.4"
BUILDER_IMAGE="claimflow/builder:local"
DISTRIBUTION="$BAL_RELEASE"
[ -f "$WORKFLOW_BALA" ] || { echo "missing ${WORKFLOW_BALA} (see prebuilt/MANIFEST.md)" >&2; exit 1; }

ICP_VERSION="2.1.0-taskmodel.2def73913"
ICP_DIST="wso2-integration-control-plane-${ICP_VERSION}"
# Built from wso2/integration-control-plane PR #888 (the task-model console) and published as a
# release asset of this repository; too large to commit.
ICP_URL="https://github.com/hasithaa/wf-demo-claims-approval/releases/download/icp-${ICP_VERSION}/${ICP_DIST}.zip"
INTEGRATIONS=(claims bill-store notifications claims-agent)

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

log "Building the Ballerina builder image"
docker build -q -f docker/builder.Dockerfile -t "$BUILDER_IMAGE" docker >/dev/null
echo "$BUILDER_IMAGE"

log "Building the integrations (workflow module ${WORKFLOW_VERSION} from prebuilt/, bridge from Ballerina Central)"
# One container run renders each Ballerina.toml and builds the integration. The repo is
# mounted read-write so bal build writes target/ and we can stage the jars. The Ballerina
# home lives on a named volume so Central packages are pulled once, not per run, and the
# compiler JVM is bounded so three consecutive builds fit in Docker memory.
docker run --rm -v "$HERE":/work -w /work \
    -v claimflow-bal-cache:/root/.ballerina \
    -e JAVA_OPTS=-Xmx2g \
    -e WORKFLOW_BALA="$WORKFLOW_BALA" -e WORKFLOW_VERSION="$WORKFLOW_VERSION" \
    -e DISTRIBUTION="$DISTRIBUTION" \
    "$BUILDER_IMAGE" bash -ec '
    # Re-pushing an existing version is refused, and the compiled cache is keyed by version
    # alone, so a rebuilt bala would be shadowed by the earlier BIR: clear both first.
    rm -rf /root/.ballerina/repositories/local/bala/ballerina/workflow \
           /root/.ballerina/repositories/local/cache-*/ballerina/workflow \
           /root/.ballerina/repositories/central.ballerina.io/cache-*/ballerina/workflow
    bal push --repository=local "$WORKFLOW_BALA"
    DEP=$(printf "%s\n" "[[dependency]]" "org = \"ballerina\"" "name = \"workflow\"" "version = \"$WORKFLOW_VERSION\"" "repository = \"local\"")
    for name in '"${INTEGRATIONS[*]}"'; do
        awk -v dep="$DEP" -v dist="$DISTRIBUTION" "{ if (\$0 == \"@WORKFLOW_DEP@\") print dep; else { gsub(/@DISTRIBUTION@/, dist); print } }" \
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
