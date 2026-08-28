# Claimflow — a durable-workflow claims demo

An insurance-claims application built on the Ballerina workflow module and the WSO2
Integration Control Plane (ICP): a claim is created first, the reviewing **manager**
decides whether to approve, **request a bill**, or reject; an **accountant** releases the
payment before it executes. Everything runs locally in Docker — including the unreleased
ICP and workflow module, which ship prebuilt in [`prebuilt/`](prebuilt/MANIFEST.md).

## Run it

Docker is the only prerequisite (no Java, no Ballerina on the host).

```sh
./build.sh              # builds the integrations inside a Docker toolchain (~2-4 min first run)
docker compose up -d    # brings up the stack and seeds itself (~2 min to healthy)
```

Then open the admin console — note the **https**:

| What | Where | Sign in |
|---|---|---|
| ICP console (admin portal) | https://localhost:9664 | `admin` / `admin` |
| Thunder (identity, later phases) | https://localhost:8090/console | `admin` / `admin12345` |
| Temporal UI (optional) | `docker compose --profile ui up -d temporal-ui` → http://localhost:8233 | — |

The browser will warn about the self-signed certificate; proceed. Opening plain
`http://localhost:9664` answers `400 The plain HTTP request was sent to HTTPS port`.

## Walk the claim through (current phase)

Until the user portal lands, the ICP console plays every part:

1. **Workflows → claims → Start workflow** → `claimApproval` with
   `{"id": "CLM-1001", "amount": 2400, "submittedBy": "alice"}`.
2. **Human Tasks** → *Review claim CLM-1001* → complete it with outcome `REQUEST_BILL`.
   The instance parks, waiting for the bill.
3. Attach the bill — events travel through the integration, not the ICP:
   `curl -X POST http://localhost:9080/claims/<workflowId>/bills -H 'Content-Type: application/json' -d '{"url": "https://bills/CLM-1001.pdf"}'`
   (the workflow id is on the instance you started).
4. The review returns with the bill attached → complete with `APPROVE`.
5. *Approve payment for claim CLM-1001* appears → complete it (`approved: true`).
6. The claim completes `PAID`; the execution-flow view shows the whole path — both
   reviews, the event wait, the payment.

The admin already holds `MANAGER` and `ACCOUNTANT` — the demo seeds those roles at first
boot (`db/initdb/30-demo-roles.sql`); a later phase replaces them with Thunder SSO group
mappings. Human tasks are role-gated by name, so without a matching role the task views
are correctly empty.

`scripts/walkthrough.sh` drives all six steps from the command line — a smoke test and
the demo's dry run.

## What is running

```
browser ──► edge (nginx, the one gateway)
              ├── ICP console  ── postgres (icp_db + credentials_db)
              └── (integration side is only reachable OUTWARD)
claims integration ──► temporal (+ its postgres, 30-day retention)
        └──── heartbeats out to the ICP through the edge; commands ride the responses
thunder ── identity provider (OIDC), the single user store for later phases
seed    ── one-shot: mints the integrations' org secrets against the running ICP
```

The ICP never connects to an integration: commands are delivered inside heartbeat
*responses* and answered on a second outbound call. `docker compose up` is self-seeding —
the `seed` service waits for the ICP, mints one org secret per integration into a shared
volume, and each integration's entrypoint waits for its file.

## Repository layout

```
prebuilt/        the unreleased binaries this demo runs (see prebuilt/MANIFEST.md)
build.sh         builds everything inside Docker; the only build command
docker-compose.yml
icp/             ICP runtime image (unpacks the prebuilt zip)
db/initdb/       Postgres first-boot scripts (apply the zip's own schema)
edge/            the gateway config
seed/            first-boot secret minting
integrations/
  claims/        the claim-approval workflow integration
```

## Roadmap

This is phase 1 of the [Claimflow proposal]: coming next are the bill-store and
notification services, Thunder SSO with `MANAGER`/`ACCOUNTANT` group mappings
(Jane/John/Alice/Bob), the user portal (classic forms + a chat-based Smart Claim portal
driving a durable agent whose payment tool needs accountant pre-approval).
