# Prebuilt binaries

This branch (`v2`) runs the workflow 0.10 task model with task administrators, which is not
released yet. Two pieces therefore come from builds rather than releases:

| Artifact | Where it comes from | Version |
|---|---|---|
| `ballerina/workflow` | `ballerina-workflow-java21-0.9.1.bala`, committed here; packed from [module-ballerina-workflow#131](https://github.com/ballerina-platform/module-ballerina-workflow/pull/131) (stacked on #128–#130) on Ballerina `2201.13.4` | `0.9.1` (PR #131 @ `861c80a`) |
| ICP distribution | `wso2-integration-control-plane-2.1.0-taskmodel.2def73913.zip`, built from [integration-control-plane#888](https://github.com/wso2/integration-control-plane/pull/888) and published as release asset `icp-2.1.0-taskmodel.2def73913` of this repository; `build.sh` downloads it into this directory, checksum verified, not committed | `2.1.0-taskmodel.2def73913` |
| `wso2/icp.runtime.bridge` | Ballerina Central | `1.0.0` |

`bal push` of a bala extracts `platform/` and `compiler-plugin/` next to it; both are gitignored.

## Rebuilding them

Module: in the PR's checkout, `./gradlew :workflow-ballerina:build`, then `cd ballerina && bal pack --offline`
(the gradle build does not refresh the bala when only Java changed) and copy `target/bala/*.bala` here.

ICP: `cd frontend && pnpm install && pnpm build`, then
`docker run --rm -v $PWD:/work -w /work/icp_server ballerina/ballerina:2201.13.4 bal build`, then
`./gradlew copyFrontendDist -x buildFrontend -Pproject.version=2.1.0-taskmodel.2def73913` and
`./gradlew packageICP -x buildICP -x buildFrontend -x copyFrontendDist -Pproject.version=2.1.0-taskmodel.2def73913`;
the zip lands in `build/distribution/`.
