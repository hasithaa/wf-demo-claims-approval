# Prebuilt binaries

Neither the ICP nor the Ballerina workflow module is released yet, so this demo carries
them prebuilt. Every artifact here is from the PR head named below — `build.sh` consumes
them; nothing needs to be built from these sources.

| Artifact | Source | Commit |
|---|---|---|
| `wso2-integration-control-plane-2.0.0-SNAPSHOT.zip` | `hasithaa/integration-control-plane` @ `workflow-instance-graph-connfix` (PR wso2#851 + the connection-pool hardening of wso2#859) | `9fb141012` + tunnel-sweep trap — 2026-09-01 |
| `ballerina-workflow-java21-0.9.0.bala` | `hasithaa/fork-module-ballerina-workflow` @ `humantask-options` + `model-activity-retry` (PRs ballerina-platform#102 + #103, local merge `demo-bala-102`) | `3639d6f` + `48d9119` |
| `wso2-icp.runtime.bridge-java21-0.3.0-SNAPSHOT.bala` | `hasithaa/icp-runtime-bridge` @ `workflow-metadata` (PR wso2#44) | `cecf6ef` |

The module comes from the PR stack rather than `main` deliberately: the console's unified
work queue calls `workItems.list`, which exists only on that stack — and this build adds
#102's options records (`awaitHumanTask`/`callActivity` forward-compatible option shapes)
plus #103's automatic retry for the built-in model activities.

## Rebuilding

Check out the branch named above and:

```sh
# ICP zip
CI=true ./gradlew assembleICP        # -> build/distribution/*.zip

# workflow module bala
cd ballerina && bal pack             # -> target/bala/*.bala

# bridge bala
./gradlew build -x test              # -> ballerina/build/bal_build_target/bala/*.bala
```
