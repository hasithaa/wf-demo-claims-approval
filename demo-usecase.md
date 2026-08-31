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

The agent runs the whole case under three pre-approval rules it enforces itself:
over **$1000** a bill is required, over **$3000** a manager signs off, and the payment
is **always** gated on an accountant. Small claims sail straight through.

1. **bob** signs in → **🤖 Submit with AI agent**. Say nothing: **the agent speaks
   first** — a greeting asking what happened, pushed through its one-way chat activity
   before any user turn exists.
2. Type: `Crashed my rental car on a client visit, about $4200 in damages`. The agent
   files the claim (the reply names the claim id; **My claims** shows the card with the
   *🤖 AI filed* badge), validates it, and — over $1000 with no receipt — opens an
   **attachment case** right in the thread: a dashed card asking for the bill.
   *Say: the case carries the workflow instance ID — that correlation is how the
   uploaded file finds its way back into this exact run.*
3. Pick any file → **Attach & resume**. The submission fires an event into the parked
   agent; it re-validates and — over $3000 — raises a **manager sign-off** task.
4. **jane** → **Decisions** → the *Manager sign-off (Smart Claim)* card, claim facts
   attached → **Approve**.
5. Watch bob's chat: the agent pushes *"approved … waiting for payment processing"*,
   rings bob's bell, and notifies the accountants — then reaches for `executePayment`,
   where the platform stops it: `requiresApproval: true` for role `ACCOUNTANT`.
6. **john** → **Decisions** → the 💸 **Release payment** card (the in-app face of the
   PRE_RUN review; the ICP shows the same gate) → **Release payment**.
7. bob's chat concludes in the agent's words: the claim **is paid**, and the claim card
   reads `PAID`. The agent asks whether anything else is needed — answer `no thanks`
   and it says goodbye and **completes the workflow**: a settled conversation never
   hangs open.

The manager's other two buttons tell their own stories: **Request bill** opens a fresh
attachment case quoting jane's comment, and once the new document arrives the sign-off
is asked again; **Reject** pushes the rejection — reason included — straight into bob's
chat, marks the claim `REJECTED`, and the same closing etiquette ends the conversation.
8. The persistence beat: **sign bob out, sign back in** → AI claims → the conversation
   is intact, every turn — conversations, cases, and correlation tokens live in the
   application database, not the browser.

Try it small, too: a fresh AI claim for `$800` skips the case and the sign-off — the
agent validates, approves, notifies, and parks only on john's release.

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
| AI chat answers with canned prose | No/expired `WSO2_AI_TOKEN` — the scripted stand-in took over; refresh the token and `docker compose up -d claims-agent`. (The stand-in paces itself like a real model — a few seconds per step; set `mockThinkSeconds = 0` in the agent's config to make it instant.) |
| Agent bubble pending forever | The gate is waiting — that's john's cue, not a bug |
| ICP login says "Error getting user details", or the console stops answering | The connection-pool wedge — run `scripts/recover.sh`; it terminates stuck sessions, restarts the ICP when its own pool is exhausted, and re-pins nginx |
| Tasks views empty for a user | Human tasks are role-gated by name — the user's group must map to `MANAGER`/`ACCOUNTANT` (seeded for jane/john) |
| An AI chat "looks stuck" | `scripts/trace-agent.sh <conversationId>` (or a `CLM-` id) — a pending turn with a token is parked behind a gate/task/event, not lost |

## Housekeeping scripts

- `scripts/recover.sh` — diagnoses and heals the stack's known failure modes (the ICP
  pool wedge in both its faces, nginx's pinned upstreams, stopped containers).
- `scripts/reset-data.sh` — start from scratch: wipes all claims, chats, bills, and
  notifications and terminates every open workflow execution; identities and
  configuration survive. Asks first (`-y` skips).
- `scripts/seed-demo-data.sh` — a lived-in look: historical claims in terminal states
  for alice and bob (AI-filed ones included) plus their bell history. Pending work is
  deliberately not seeded — create it through the portal so decisions actually work.
- `scripts/trace-agent.sh [id]` — follows one agent run's correlation chain: the
  conversation, every turn's reply token, attachment cases, claim rows, and what
  Temporal says the run is doing right now. No argument traces the newest conversation.
