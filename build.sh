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
# The released distribution every mode but the observability one builds against.
BAL_RELEASE="2201.13.4"
# The unreleased distribution the telemetry build of the workflow module needs. Its runtime
# carries the OpenTelemetry version that build uses, so the module and whatever compiles
# against it share one distribution.
BAL_PRERELEASE="2201.14.0-20260914-141400-b8d79cea"
BAL_DIST_URL="https://maven.pkg.github.com/ballerina-platform/ballerina-lang/org/ballerinalang/jballerina-tools/${BAL_PRERELEASE}/jballerina-tools-${BAL_PRERELEASE}.zip"
# The distribution-internal observe package, which observabilityIncluded compiles against. Its
# version is the one the workflow module builds that distribution with.
BAL_OBSERVE_VERSION="1.7.1"
BAL_OBSERVE_URL="https://maven.pkg.github.com/ballerina-platform/ballerina-lang/io/ballerina/observe-ballerina/${BAL_OBSERVE_VERSION}/observe-ballerina-${BAL_OBSERVE_VERSION}.zip"

BUILDER_IMAGE="claimflow/builder:local"
DISTRIBUTION="$BAL_RELEASE"
if [ "$WITH_OBS" = 1 ]; then
    BUILDER_IMAGE="claimflow/builder-prerelease:local"
    DISTRIBUTION="$BAL_PRERELEASE"
    if [ ! -f "$WORKFLOW_BALA" ]; then
        echo "--with-observability needs ${WORKFLOW_BALA} (see prebuilt/MANIFEST.md)" >&2
        exit 1
    fi
    if [ -z "${packageUser:-}" ] || [ -z "${packagePAT:-}" ]; then
        cat >&2 <<MSG
--with-observability builds against Ballerina ${BAL_PRERELEASE}, which is not released:
its only download is the ballerina-platform GitHub Packages registry. Export a GitHub
username and a token with read:packages, then run this again:

    export packageUser=<github-username> packagePAT=<token>

Without the flag the demo builds with Docker alone, against the released module.
MSG
        exit 1
    fi
fi

ICP_VERSION="2.1.0-alpha3"
ICP_DIST="wso2-integration-control-plane-${ICP_VERSION}"
ICP_URL="https://github.com/wso2/integration-control-plane/releases/download/v${ICP_VERSION}/${ICP_DIST}.zip"
INTEGRATIONS=(claims bill-store notifications claims-agent)

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

log "Building the Ballerina builder image"
if [ "$WITH_OBS" = 1 ]; then
    # The credentials reach the build as a secret file, so they are in neither the image nor
    # its history; the shell never puts them on a command line either.
    CREDS_FILE="$(mktemp)"
    trap 'rm -f "$CREDS_FILE"' EXIT
    printf 'packageUser=%s\npackagePAT=%s\n' "$packageUser" "$packagePAT" > "$CREDS_FILE"
    DOCKER_BUILDKIT=1 docker build -q -f docker/builder-prerelease.Dockerfile \
        --secret "id=ghcreds,src=$CREDS_FILE" \
        --build-arg "BAL_VERSION=$BAL_PRERELEASE" --build-arg "BAL_DIST_URL=$BAL_DIST_URL" \
        --build-arg "BAL_OBSERVE_URL=$BAL_OBSERVE_URL" \
        -t "$BUILDER_IMAGE" docker >/dev/null
else
    docker build -q -f docker/builder.Dockerfile -t "$BUILDER_IMAGE" docker >/dev/null
fi
echo "$BUILDER_IMAGE"

if [ "$WITH_OBS" = 1 ]; then
    log "Building the integrations (workflow module 0.9.1 from prebuilt/ on Ballerina ${BAL_PRERELEASE}, telemetry on)"
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
    -e DISTRIBUTION="$DISTRIBUTION" \
    "$BUILDER_IMAGE" bash -ec '
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
        awk -v dep="$DEP" -v dist="$DISTRIBUTION" "{ if (\$0 == \"@WORKFLOW_DEP@\") { if (dep != \"\") print dep } else { gsub(/@DISTRIBUTION@/, dist); print } }" \
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
