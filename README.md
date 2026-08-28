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
| ICP console (admin portal) | https://localhost:9664 | **Sign in with SSO** as `jane`/`jane12345` (manager) or `john`/`john12345` (accountant); `admin`/`admin` stays local |
| Claims API / bill store / inbox | http://localhost:9080 · 9081 · 9082 | — |
| Thunder console (identity admin) | https://localhost:8090/console | `admin` / `admin12345` |
| Thunder (identity, later phases) | https://localhost:8090/console | `admin` / `admin12345` |
| Temporal UI (optional) | `docker compose --profile ui up -d temporal-ui` → http://localhost:8233 | — |

The browser will warn about the self-signed certificate; proceed. Opening plain
`http://localhost:9664` answers `400 The plain HTTP request was sent to HTTPS port`.

## The cast — one user store, mapped to roles

Thunder is the single identity provider; its declarative seed
([`seed/thunder-resources.yaml`](seed/thunder-resources.yaml)) creates the users, the
groups, and the ICP's OAuth client. On SSO login the ICP reads the token's `groups`
claim and maps group names to its roles (`db/initdb/40-sso-mappings.sql`); human tasks
are gated on those role names.

| User | Password | Thunder group → ICP role | Plays |
|---|---|---|---|
| jane | jane12345 | `managers` → `MANAGER` | Decides claim reviews |
| john | john12345 | `accountants` → `ACCOUNTANT` | Releases payments |
| alice, bob | alice12345, bob12345 | `users` (portal only, later phase) | Submit claims |

## Walk the claim through (current phase)

Until the user portal lands, the ICP console plays every part — or sign in with SSO as
jane for the reviews and john for the payment, which is the demo's real story:

1. **Workflows → claims → Start workflow** → `claimApproval` with
   `{"id": "CLM-1001", "amount": 2400, "submittedBy": "alice"}`.
2. **Human Tasks** → *Review claim CLM-1001* → complete it with outcome `REQUEST_BILL`.
   The instance parks, waiting for the bill.
3. Upload the bill to the bill store and attach it (events travel through the
   integrations, not the ICP):
   ```sh
   curl -X POST 'http://localhost:9081/bills?filename=receipt.pdf&owner=alice&claimId=CLM-1001' \
        -H 'Content-Type: application/octet-stream' --data-binary @receipt.pdf
   curl -X POST http://localhost:9081/bills/<billId>/attach \
        -H 'Content-Type: application/json' -d '{"workflowId": "<workflowId>"}'
   ```
4. The review returns with the bill attached → complete with `APPROVE`.
5. *Approve payment for claim CLM-1001* appears → complete it (`approved: true`).
6. The claim completes `PAID`; the execution-flow view shows the whole path — both
   reviews, the event wait, the payment.
7. What the user would see: `curl http://localhost:9082/notifications?user=alice` (the
   inbox) and `curl http://localhost:9080/claims?user=alice` (the durable record — the
   claims table the workflow maintains, which outlives Temporal's retention window).

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
claims        ──► temporal (30-day retention) · claims_db (the durable record)
bill-store    ──► bills_db + a file volume; forwards attached bills to claims
notifications ──► notifications_db; the user-facing inbox
        └──── all three heartbeat out to the ICP through the edge
appdb   ── one Postgres for the integration side, one database per service
thunder ── identity provider (OIDC): the single user store, declaratively seeded;
           the ICP validates its ID tokens (JWKS) and syncs groups→roles on every login
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
  claims/         the claim-approval workflow integration (+ claims_db record, bill inlet)
  bill-store/     bill upload/download with file state (its own DB + volume)
  notifications/  the per-user inbox (its own DB)
```

## Roadmap

Phases 1–3 of the Claimflow proposal are in place: the claim process, the bill store,
the notification inbox, the claims database as the durable record, and Thunder SSO with
group→role mappings. Coming next: the user portal (classic forms) and a chat-based
Smart Claim portal driving a durable agent whose payment tool needs accountant
pre-approval.

Demo-only notes: `seed/thunder-tls/` holds a committed self-signed TLS pair whose SANs
cover both `localhost` (browser) and `thunder` (the ICP's server-side JWKS fetch) — do
not reuse it anywhere real. Thunder persists two volumes (`config` and `database`);
they must live and die together, or the server boots half-initialized.
