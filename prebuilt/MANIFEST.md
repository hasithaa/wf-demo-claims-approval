# Prebuilt binaries

Neither the ICP nor the Ballerina workflow module is released yet, so this demo carries
them prebuilt. `build.sh` consumes them; nothing here needs to be built from source.

| Artifact | Source | Commit |
|---|---|---|
| `wso2-integration-control-plane-2.0.0-SNAPSHOT.zip` | `hasithaa/integration-control-plane`, local merge `icp-demo-all` = upstream main + `workflow-instance-graph` (PR wso2#851) + `workflow-metrics` (PR wso2#870) | `icp-demo-all` @ `f5ecbd92b` merging 851 @ `e7a01cab5` and 870 @ `2d614ddff` (Workflows section gains the AI Agent Steps table and control-operation counts; `tool_name`/`error_type` mapped in the index template) — 2026-09-11 |
| `ballerina-workflow-java21-0.9.1.bala` | `hasithaa/fork-module-ballerina-workflow` @ `observability-integration` (PR ballerina-platform#106 on top of the released 0.9.0) | `44383ea` — durable-agent steps (`agent_*` events, `tool_name`, `workflow_agent_step_duration_seconds`), control events (suspended/resumed/terminated/cancelled), task-decision signals and built-in activities kept out of the counts — 2026-09-11 |
| `wso2-icp.runtime.bridge-java21-0.3.0-SNAPSHOT.bala` | `hasithaa/icp-runtime-bridge` @ `main` = upstream main + the heartbeat-guard fix | `0278ab5` — 2026-09-02 |

## What the ICP build carries

Upstream main already includes wso2#859 (connection hardening, the pool-leak fix, trapped
periodic jobs). On top of it, PR wso2#851 brings the workflow console:

- **Navigation.** Workflows and Human Tasks sit in a *Manage* group ahead of Observability.
- **Project pages.** An integration whose runtime publishes a worker's task queue counts as a
  workflow integration, whatever its type. The Workflow page is a per-integration stats table with the project-wide
  pending-task total; an offline runtime's row says so in place of its figures. The Human Tasks
  page is one queue across every integration: held until its sources answer, then frozen in
  order, with a summary line and source chips naming which integrations it reflects, which are
  still answering, and which are offline. Each source pages independently (50+, *Load more*).
- **Integration overview.** Figures follow the selected workflow definition. *Start Workflow*
  separates the workflow's input from an *Advanced* section for Workflow ID and Timeout.
- **Work queue.** Human tasks and review activities share one queue. Bulk review decisions are
  an explicit *Select reviews* mode. A review shows its decision; a task's fail is a decision
  card. Completing a task stays on the queue.
- **Execution view.** Instance graph joined to the run's history — the run's own task queue picks
  its descriptor, and a run of interpolated steps keeps its rail — one card style and Title Case
  throughout, reset points without Temporal event ids.
- **Time.** Workflow-page timestamps are `YYYY-MM-DD HH:mm:ss` on one clock, local or UTC,
  switched beside the environment picker; the tooltip carries the UTC instant.
- **Server.** Stateless tunnel with a stable actor id beside the tunneled identity, pending-task
  figures gated on the human-task permission, serialized heartbeat transaction
  (ballerina-library#9129). *Add Runtime* no longer special-cases workflow integrations; its
  snippet emits `enableWorkflowManagement = true`, the flag being the deployment's headless
  opt-out.

The module bala carries #106: client spans, the events counter and duration histograms, the
task-decision audit trail with identity provenance, and the per-event log samples the console charts. The bridge bala carries the heartbeat guard that survives a
hung tick and bounds the request.

## Observability

The integrations build with `observabilityIncluded = true`, log JSON, and publish HTTP metrics as
log lines (`ballerinax/metrics.logs`); the workflow module publishes one record per workflow event
(`logger = "workflow-metrics"`, PR #106: started/closed runs with duration and outcome, activity
attempts, data sent, task decisions — plus an audit entry per decision). fluent-bit (Docker's
fluentd driver) routes them to three OpenSearch indices, and the console's Observability tab reads
all three: application logs, HTTP metrics, and — with wso2#870 — the workflow metrics section,
including the AI agent's steps. Beside the console, a Prometheus scrapes each integration's
reporter (:9797) and a Jaeger receives every integration's spans over OTLP.

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
