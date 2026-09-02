# Prebuilt binaries

Neither the ICP nor the Ballerina workflow module is released yet, so this demo carries
them prebuilt. Every artifact here is from the PR head named below — `build.sh` consumes
them; nothing needs to be built from these sources.

| Artifact | Source | Commit |
|---|---|---|
| `wso2-integration-control-plane-2.0.0-SNAPSHOT.zip` | `hasithaa/integration-control-plane` @ `workflow-instance-graph-connfix` (PR wso2#851 + the connection-pool hardening of wso2#859) | `a07fa3403` — 2026-09-02 |
| `ballerina-workflow-java21-0.9.0.bala` | `hasithaa/fork-module-ballerina-workflow` @ `humantask-options` + `model-activity-retry` (PRs ballerina-platform#102 + #103, local merge `demo-bala-taskinput`) | `c562d4a` — 2026-09-02 |
| `wso2-icp.runtime.bridge-java21-0.3.0-SNAPSHOT.bala` | `hasithaa/icp-runtime-bridge` @ `management-reset` (PR wso2#44 and later) | `0278ab5` — 2026-09-02 |

The module comes from the PR stack rather than `main` deliberately: the console's unified
work queue calls `workItems.list`, which exists only on that stack — and this build adds
#102's options records (`awaitHumanTask`/`callActivity` forward-compatible option shapes)
plus #103's automatic retry for the built-in model activities.

The 2026-09-02 rebuild carries three stability fixes found by running this demo, all on the
branches above:

- **ICP** resolves a heartbeat's environment with `queryRow` instead of consuming a stream.
  The stream returned its connection only on the paths that reached the end of it, so a
  failing heartbeat leaked one; ten leaks retired the Hikari pool and every request that
  needed the database timed out after 30s — including `/auth/login`.
- **The bridge** releases its heartbeat overlap guard on every path, panic included. One tick
  that died used to leave the guard held, and the runtime then never heartbeated again — it
  was swept OFFLINE and stayed there, which the console shows as an empty task list.
- **The bridge** states a 15s request timeout, so an ICP holding a request open costs a few
  skipped ticks rather than the registration.

This module build also renames the human task's `payload` to `taskInput`, which is why the
integrations here pass the task input positionally and read `HumanTaskInfo.taskInput`.

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
