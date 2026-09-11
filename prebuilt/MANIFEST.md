# Prebuilt binaries

Almost nothing lives here any more. The ICP, the Ballerina workflow module and the ICP runtime
bridge are all released, so `build.sh` takes them from their releases:

| Artifact | Where it comes from | Version |
|---|---|---|
| ICP distribution | [wso2/integration-control-plane release `v2.1.0-alpha3`](https://github.com/wso2/integration-control-plane/releases/tag/v2.1.0-alpha3) — downloaded into this directory on first build, checksum verified, not committed | `2.1.0-alpha3` (commit `2d0ad07b5`) |
| `ballerina/workflow` | Ballerina Central | `0.9.0` |
| `wso2/icp.runtime.bridge` | Ballerina Central | `1.0.0` |

## The one exception: workflow telemetry

The workflow module only reports its own telemetry — spans, the events counter, one log record per
workflow event, and the task-decision audit trail — from PR
[ballerina-platform/module-ballerina-workflow#106](https://github.com/ballerina-platform/module-ballerina-workflow/pull/106),
which is not released. To see the console's Workflow metrics section, build with that module:

```sh
./build.sh --with-observability     # uses prebuilt/ballerina-workflow-java21-0.9.1.bala
```

`ballerina-workflow-java21-0.9.1.bala` is built from `hasithaa/fork-module-ballerina-workflow` @
`observability-integration` (`e1e5d84`, 2026-09-10). Without the flag the demo runs the released
`0.9.0`: everything works, and the Observability tab still shows logs and HTTP metrics — only the
Workflow metrics section is empty.

Note the released bridge does not carry the heartbeat-guard fix that the earlier prebuilt bala had.
Its root cause was JDK 21 carrier pinning, and the integrations run on JDK 25, where it cannot happen.

## What the release carries

`v2.1.0-alpha3` is cut from the merge of wso2#851, and already contains wso2#859 (connection
hardening, the pool-leak fix, trapped periodic jobs) and wso2#870 (the workflow metrics view).
The workflow console it brings:

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
- **Observability.** A Workflow section on the metrics page (wso2#870): runs started, completed and
  failed with durations, activities ranked by failures, and task decisions by task.

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
reporter (:9797) and a Jaeger receives every integration's spans over OTLP. A run filed from the portal is
one trace from the HTTP request through the run's activities and its human-task children; a run started
through the ICP tunnel has no traced caller, so its execution forms a trace of its own.

## Rebuilding

The ICP zip comes from the release; delete it from `prebuilt/` and the next build fetches it again.
To refresh the observability bala after new commits on PR #106:

```sh
cd ballerina && bal pack             # -> target/bala/*.bala
```
