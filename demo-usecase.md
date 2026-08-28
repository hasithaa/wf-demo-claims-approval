# The Claimflow demo, step by step

One insurance-claims process, told twice: once through a classic form-driven portal
backed by a **durable workflow**, once through a chat with a **durable AI agent** — and
in both, the moments that matter go through people. This script is the demo; every step
below is exactly what to click and what to say.

## Cast

| Sign in as | Password | Where | Role in the story |
|---|---|---|---|
| alice | alice12345 | Portal http://localhost:9090 | Submits a claim with the form |
| bob | bob12345 | Portal | Files his claim by chatting with the AI agent |
| jane | jane12345 | Portal (Decisions tab) or ICP | Manager — reviews every claim |
| john | john12345 | Portal (Decisions) or ICP | Accountant — releases every payment |
| admin | admin | ICP https://localhost:9664 (local login) | Operations narrator |

One identity for everything: all four sign into both portals through Thunder (SSO on
the ICP side), and their groups become the roles the tasks are gated on.

## Before the audience arrives

```sh
./build.sh && docker compose up -d     # ~5 min cold; self-seeding
```

- Open https://localhost:9664 once and accept the self-signed certificate (**https**,
  not http — plain http answers 400).
- Optional but recommended — the real model for the AI act: in VS Code (Ballerina
  Integrator), open the integration and generate a **default model provider** token; put
  the two values in `.env` as `WSO2_AI_SERVICE_URL` / `WSO2_AI_TOKEN`, then
  `docker compose up -d claims-agent`. The token lives ~1 hour, which is why it travels
  as environment: refreshing is *edit `.env`, recreate one container*. Without a token
  the agent runs a scripted stand-in — same steps, canned prose.

## Act 1 — the classic claim (durable workflow)

1. **alice** signs into the portal. Empty state, two calls to action.
2. **＋ New claim** → the form: amount `2400`, description
   `Hotel flooded, replaced my equipment`, leave the bill empty ("you can add it later
   if the reviewer asks"). **Submit.** The claim card appears — `SUBMITTED`.
   *Say: the workflow is already running; the claim row you see is the application's own
   database, which the workflow keeps updated — Temporal history is not the system of
   record.*
3. **jane** signs in (second browser/profile) → **Decisions**. The review shows the
   claim's facts. Type `Need the receipt, please` and click **Request bill**.
4. **alice**'s card flips to `BILL REQUESTED` (bell rings). Pick any file →
   **Upload & attach bill**. *Say: the file went to the bill store — its own service,
   its own database — and the attach fired an event into the parked workflow.*
5. **jane** → Decisions: the review is back **with the bill link**. **Approve**.
6. **john** signs in → Decisions → **Approve payment**. *Say: the money moves only
   after this — the payment step is a separate human gate for a separate role.*
7. **alice**: the card reads `PAID` with the payment reference; the bell narrates the
   whole story. Total elapsed: about two minutes.

## Act 2 — the AI claim (durable agent)

1. **bob** signs in → **🤖 Submit with AI agent** (or the AI claims tab → New AI claim).
2. Type: `I broke my laptop on a work trip last week, it cost about $1200 to replace`.
   The agent answers in its own words, files the claim (watch **My claims** — the card
   carries an *🤖 AI filed* badge), and estimates the payout.
3. Reply `yes, pay it please` → the bubble holds on
   *"working (a payment may be waiting on the accountant)"*. **This is the demo's
   point**: the agent decided to pay, and the platform stopped it — `executePayment`
   is declared `requiresApproval: true` for role `ACCOUNTANT`.
4. **john** opens the ICP → claims-agent → Human Tasks → the **approval gate**
   (trigger: Approval gate) → Proceed.
5. bob's bubble resolves: the agent confirms the payment in its own words.
6. The persistence beat: **sign bob out, sign back in** → AI claims → the conversation
   is intact, every turn — conversations and their correlation tokens live in the
   application database, not the browser.

## The operations view (run alongside either act)

Sign into the ICP as jane (SSO) or admin:

- **Workflow Executions** → open a claim run → the execution flow: the workflow's
  structure with the taken path, the event wait, both human tasks, the timeline.
  Click a node — the right panel shows that step's input and result.
- The agent's run renders as its **star**: the model in the middle, tools around it,
  the gated payment marked as an approval gate.
- **Human Tasks** at the project level: the per-integration dashboard with live counts.
- Recovery tools worth showing on a failed run: retry reviews, **Reset…** to a chosen
  point (completed steps are not re-executed).

## If something looks wrong

| Symptom | Cause / fix |
|---|---|
| `400 The plain HTTP request was sent to HTTPS port` | Use **https**://localhost:9664 |
| Portal API calls fail after recreating a service | nginx pins upstream IPs: `docker compose restart webapp` (same for `edge` after recreating `icp`) |
| AI chat answers with canned prose | No/expired `WSO2_AI_TOKEN` — the scripted stand-in took over; refresh the token and `docker compose up -d claims-agent` |
| Agent bubble pending forever | The gate is waiting — that's john's cue, not a bug |
| ICP login says "Error getting user details" | Connection-pool wedge: `docker compose exec postgres psql -U postgres -d icp_db -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='icp_db' AND state='idle in transaction'"` |
| Tasks views empty for a user | Human tasks are role-gated by name — the user's group must map to `MANAGER`/`ACCOUNTANT` (seeded for jane/john) |
