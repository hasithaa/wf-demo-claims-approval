# Prebuilt binaries

Neither the ICP nor the Ballerina workflow module is released yet, so this demo carries
them prebuilt. `build.sh` consumes them; nothing here needs to be built from source.

| Artifact | Source | Commit |
|---|---|---|
| `wso2-integration-control-plane-2.0.0-SNAPSHOT.zip` | `hasithaa/integration-control-plane`, local merge `icp-demo-obs` = upstream main + `workflow-instance-graph` (PR wso2#851) | `bcb25cfff` — 2026-09-10 |
| `ballerina-workflow-java21-0.9.1.bala` | `hasithaa/fork-module-ballerina-workflow` @ `observability-integration` (PR ballerina-platform#106 on top of the released 0.9.0) | `fad4bec` — 2026-09-07 |
| `wso2-icp.runtime.bridge-java21-0.3.0-SNAPSHOT.bala` | `hasithaa/icp-runtime-bridge` @ `main` = upstream main + the heartbeat-guard fix | `0278ab5` — 2026-09-02 |

## What the ICP build carries

Upstream main already includes wso2#859 (connection hardening, the pool-leak fix, trapped
periodic jobs). On top of it, PR wso2#851 brings the workflow console:

- **Navigation.** Workflows and Human Tasks sit in a *Manage* group ahead of Observability.
- **Project pages.** The Workflow page is a per-integration stats table with the project-wide
  pending-task total; an offline runtime's row says so in place of its figures. The Human Tasks
  page is one queue across every integration: held until its sources answer, then frozen in
  order, with a summary line and source chips naming which integrations it reflects, which are
  still answering, and which are offline. Each source pages independently (50+, *Load more*).
- **Integration overview.** Figures follow the selected workflow definition. *Start Workflow*
  separates the workflow's input from an *Advanced* section for Workflow ID and Timeout.
- **Work queue.** Human tasks and review activities share one queue. Bulk review decisions are
  an explicit *Select reviews* mode. A review shows its decision; a task's fail is a decision
  card. Completing a task stays on the queue.
- **Execution view.** Instance graph joined to the run's history, one card style and Title Case
  throughout, reset points without Temporal event ids.
- **Time.** Workflow-page timestamps are `YYYY-MM-DD HH:mm:ss` on one clock, local or UTC,
  switched beside the environment picker; the tooltip carries the UTC instant.
- **Server.** Stateless tunnel with a stable actor id beside the tunneled identity, pending-task
  figures gated on the human-task permission, serialized heartbeat transaction
  (ballerina-library#9129). *Add Runtime* no longer special-cases workflow integrations; its
  snippet emits `enableWorkflowManagement = true`, the flag being the deployment's headless
  opt-out.

The module bala carries #106's decision audit trail, content capture and
`workflow_task_decisions_total`. The bridge bala carries the heartbeat guard that survives a
hung tick and bounds the request.

Observability is **not** wired into this demo: the integrations build with
`observabilityIncluded = false`, link no `ballerinax/prometheus` or `jaeger`, and the
compose stack carries no prometheus/jaeger/opensearch/fluent-bit services. The module bala
still contains the observability capability from #106; the demo simply does not turn it on.

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
