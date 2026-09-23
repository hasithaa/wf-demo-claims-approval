# Prebuilt binaries

This branch (`v2`) runs the workflow 0.10 task model with task administrators, which is not
released yet. Two pieces therefore come from builds rather than releases:

The ICP build carries #888's task model (an ancestor of #916) plus the workflow-console fixes in
[#916](https://github.com/wso2/integration-control-plane/pull/916): multiline input survives the
review form, `Edit as JSON` is on every workflow input surface, the project listing says Workflow
Definitions, and the instance diagram reports steps it could not place instead of drawing them as
never executed. It also gives up on a tunnel read that no runtime answers at that read's own deadline
rather than leaving the console on "Fetching…" until the five-minute sweep notices.

| Artifact | Where it comes from | Version |
|---|---|---|
| `ballerina/workflow` | `ballerina-workflow-java21-0.9.1.bala`, committed here; packed from [module-ballerina-workflow#131](https://github.com/ballerina-platform/module-ballerina-workflow/pull/131) (stacked on #128–#130) on Ballerina `2201.13.4` | `0.9.1` (PR #131 @ `861c80a`) |
| ICP distribution | `wso2-integration-control-plane-2.1.0-wfinput.ecc26c54f.zip`, built from [integration-control-plane#916](https://github.com/wso2/integration-control-plane/pull/916) at `ecc26c54f`. **Not published yet**: no release asset carries it, so `build.sh` uses the copy already in this directory and would fail to fetch it on a fresh clone. Publish it as `icp-2.1.0-wfinput.ecc26c54f` when the demo needs to travel | `2.1.0-wfinput.ecc26c54f` |
| `wso2/icp.runtime.bridge` | Ballerina Central | `1.0.0` |

`bal push` of a bala extracts `platform/` and `compiler-plugin/` next to it; both are gitignored.

## Rebuilding them

Module: in the PR's checkout, `./gradlew :workflow-ballerina:build`, then `cd ballerina && bal pack --offline`
(the gradle build does not refresh the bala when only Java changed) and copy `target/bala/*.bala` here.

ICP: `cd frontend && pnpm install && pnpm build`, then
`docker run --rm -v $PWD:/work -w /work/icp_server ballerina/ballerina:2201.13.4 bal build`, then
`./gradlew copyFrontendDist -x buildFrontend -Pproject.version=2.1.0-wfinput.ecc26c54f` and
`./gradlew packageICP -x buildICP -x buildFrontend -x copyFrontendDist -Pproject.version=2.1.0-wfinput.ecc26c54f`;
the zip lands in `build/distribution/`.
