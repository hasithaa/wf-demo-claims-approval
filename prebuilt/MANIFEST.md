# Prebuilt binaries

Neither the ICP nor the Ballerina workflow module is released yet, so this demo carries
them prebuilt. Every artifact here is from the PR head named below — `build.sh` consumes
them; nothing needs to be built from these sources.

| Artifact | Source | Commit |
|---|---|---|
| `wso2-integration-control-plane-2.0.0-SNAPSHOT.zip` | `hasithaa/integration-control-plane`, local merge `icp-demo-obs` = upstream main (which now carries wso2#859, merged) + `workflow-instance-graph` (PR wso2#851) | `3647007e5` — 2026-09-10 (bulk review decisions in the integration queue are an explicit Select reviews mode, no checkboxes by default; the project Human Tasks page is one queue across every integration again — held until its sources answer, then frozen in order so rows never move under the reader, late sources appended and named — with a summary line and source chips saying which integrations it reflects, which are still answering, and which are offline or unreachable; workflow-page timestamps are YYYY-MM-DD HH:mm:ss on one clock, local or UTC, switched beside the environment picker, with the UTC instant in the tooltip; reset points no longer show Temporal event ids; completing a task stays on the Human Tasks queue; Workflows and Human Tasks sit in a Manage group ahead of Observability; the project tables drop the Runtime column and an offline runtime's row says so in place of its figures; the integration overview's figures follow the selected workflow definition and its State/Worker Count cells are gone; Start Workflow separates the workflow's input from an Advanced section for Workflow ID and Timeout; project Workflow page is a per-integration stats table with the project-wide pending-task total;  the integration overview shows the same figures in place of the running-instances list; review shows its decision; a task's fail is a decision card; Add Runtime no longer special-cases workflow integrations; serialized heartbeat transaction, ballerina-library#9129) |
| `ballerina-workflow-java21-0.9.1.bala` | `hasithaa/fork-module-ballerina-workflow` @ `observability-integration` (PR ballerina-platform#106 on top of the released 0.9.0: decision audit trail, content capture, `workflow_task_decisions_total`) | `fad4bec` — 2026-09-07 |
| `wso2-icp.runtime.bridge-java21-0.3.0-SNAPSHOT.bala` | `hasithaa/icp-runtime-bridge` @ `workflow-stateless-tunnel` = upstream main + the heartbeat-guard fix (`enableWorkflowManagement` stays: it is the deployment's headless opt-out) | `0278ab5` — 2026-09-02 |

Every open PR the demo depends on rides in these builds: #105 (taskInput rename +
deprecation removal), wso2#851 (the workflow console UX — the split-view overview, the
unified work queue, the agent shape, the review's decision + the human-task
fail-as-decision card, the project-level per-integration summaries for executions and human
tasks, the selected definition's figures on the integration overview, the Start dialog's input/advanced split, and Add Runtime
without workflow special-casing — its snippet emits `enableWorkflowManagement = true` by
default, the flag being the deployment's headless opt-out), and the bridge's heartbeat-guard
release. wso2#859 (connection hardening, the pool-leak fix and the trapped periodic jobs) is
no longer a branch the demo carries: it merged upstream on 2026-09-08 and arrives with main.

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
