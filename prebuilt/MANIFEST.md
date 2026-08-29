# Prebuilt binaries

Neither the ICP nor the Ballerina workflow module is released yet, so this demo carries
them prebuilt. Every artifact here is from the PR head named below — `build.sh` consumes
them; nothing needs to be built from these sources.

| Artifact | Source | Commit |
|---|---|---|
| `wso2-integration-control-plane-2.0.0-SNAPSHOT.zip` | `hasithaa/integration-control-plane` @ `workflow-instance-graph` (PR wso2#851, carries wso2#834) | `314346cf` — 2026-08-28 |
| `ballerina-workflow-java21-0.9.0.bala` | `hasithaa/fork-module-ballerina-workflow` @ `wf-graph-metadata` (PR ballerina-platform#96) | `ca91bcd` |
| `wso2-icp.runtime.bridge-java21-0.3.0-SNAPSHOT.bala` | `hasithaa/icp-runtime-bridge` @ `workflow-metadata` (PR wso2#44) | `cecf6ef` |

The module comes from PR #96 rather than `main` deliberately: the console's unified work
queue calls `workItems.list`, which exists only on that PR. Pairing this ICP with module
`main` leaves that view unable to answer.

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
