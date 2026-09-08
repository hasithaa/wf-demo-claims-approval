# Prebuilt binaries

Neither the ICP nor the Ballerina workflow module is released yet, so this demo carries
them prebuilt. Every artifact here is from the PR head named below — `build.sh` consumes
them; nothing needs to be built from these sources.

| Artifact | Source | Commit |
|---|---|---|
| `wso2-integration-control-plane-2.0.0-SNAPSHOT.zip` | `hasithaa/integration-control-plane`, local merge `icp-demo-obs` = main + `workflow-instance-graph` (PR wso2#851) + `icp-connection-hardening` (PR wso2#859) | `3e523fd77` — 2026-09-08 (project Workflow page is a per-integration stats table with the project-wide pending-task total; review shows its decision; a task's fail is a decision card; Add Runtime no longer special-cases workflow integrations; serialized heartbeat transaction, ballerina-library#9129) |
| `ballerina-workflow-java21-0.9.1.bala` | `hasithaa/fork-module-ballerina-workflow` @ `observability-integration` (PR ballerina-platform#106 on top of the released 0.9.0: decision audit trail, content capture, `workflow_task_decisions_total`) | `fad4bec` — 2026-09-07 |
| `wso2-icp.runtime.bridge-java21-0.3.0-SNAPSHOT.bala` | `hasithaa/icp-runtime-bridge` @ `workflow-stateless-tunnel` = upstream main + the heartbeat-guard fix (`0278ab5`) + PR wso2#46 (workflow management follows the registered workflow integration; `enableWorkflowManagement` removed) | `bdfa255` — 2026-09-08 |

Every open PR the demo depends on rides in these builds: #105 (taskInput rename +
deprecation removal), wso2#851 (the workflow console UX — the split-view overview, the
unified work queue, the agent shape, the review's decision + the human-task
fail-as-decision card, the project-level per-integration stats table, and Add Runtime
without workflow special-casing), wso2#859 (connection hardening + the pool-leak fix),
bridge wso2#46 (workflow management follows the registered workflow integration — the
`enableWorkflowManagement` flag is gone, so the four integration Config.toml templates no
longer carry it), and the bridge's heartbeat-guard release.

Observability is **not** wired into this demo: the integrations build with
`observabilityIncluded = false`, link no `ballerinax/prometheus` or `jaeger`, and the
compose stack carries no prometheus/jaeger/opensearch/fluent-bit services. (The module bala
still contains the observability capability from #106; the demo simply does not turn it on.)

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
