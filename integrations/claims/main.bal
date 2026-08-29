// The claims integration's HTTP surface and storage — the deterministic half of the
// Claimflow demo. The portal's API (submit, list, decide) and the bill-store's event
// inlet live here, along with the configuration, the database, and the JWT gate they
// share. The claim approval process itself lives in workflow.bal.
import ballerina/http;
import ballerina/jwt;
import ballerina/log;
import ballerina/sql;
import ballerina/uuid;
import ballerina/workflow;
import ballerina/workflow.management;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;
import wso2/icp.runtime.bridge as _;

configurable string dbHost = "appdb";
configurable int dbPort = 5432;
configurable string dbUser = "app";
configurable string dbPassword = "app";
configurable string dbName = "claims_db";
configurable string notificationsUrl = "http://notifications:8080";
// The portal's tokens come from Thunder; the issuer must match `iss` exactly and the
// JWKS endpoint is dialed inside the compose network.
configurable string idpIssuer = "https://localhost:8090";
configurable string idpJwksUrl = "https://thunder:8090/oauth2/jwks";

final postgresql:Client db = check initDb();
final http:Client notifications = check new (notificationsUrl);

function initDb() returns postgresql:Client|error {
    postgresql:Client c = check new (host = dbHost, port = dbPort,
        username = dbUser, password = dbPassword, database = dbName);
    _ = check c->execute(`CREATE TABLE IF NOT EXISTS claims (
        claim_id VARCHAR(100) PRIMARY KEY,
        workflow_id VARCHAR(100) NOT NULL,
        submitted_by VARCHAR(200) NOT NULL,
        amount NUMERIC(12,2) NOT NULL,
        status VARCHAR(24) NOT NULL,
        bill_url VARCHAR(600),
        note VARCHAR(600),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now())`);
    // Which channel filed the claim ('portal' or 'agent') — the portal badges AI-filed
    // claims by it. Also added by the agent service; idempotent either way.
    _ = check c->execute(`ALTER TABLE claims
        ADD COLUMN IF NOT EXISTS filed_via VARCHAR(16) NOT NULL DEFAULT 'portal'`);
    return c;
}

type ClaimRecord record {|
    string claimId;
    string workflowId;
    string submittedBy;
    decimal amount;
    string status;
    string? billUrl;
    string? note;
    string filedVia = "portal";
    string updatedAt;
|};

// ── Portal authentication ─────────────────────────────────────────────────────
// The portal sends Thunder-issued JWTs. Validation is explicit — signature via JWKS,
// issuer exact — and the caller's identity is whatever the token says: `username` for
// attribution, `groups` mapped to the role names the human tasks are gated on.

type Caller record {|
    string username;
    string[] roles;
|};

final readonly & map<string> GROUP_TO_ROLE = {"managers": "MANAGER", "accountants": "ACCOUNTANT"};

isolated function authenticate(string? authorization) returns Caller|http:Unauthorized {
    if authorization is () || !authorization.startsWith("Bearer ") {
        return <http:Unauthorized>{body: {message: "A Bearer token is required"}};
    }
    string token = authorization.substring(7);
    jwt:ValidatorConfig config = {
        issuer: idpIssuer,
        clockSkew: 30,
        signatureConfig: {
            jwksConfig: {
                url: idpJwksUrl,
                // Thunder serves the demo's self-signed certificate.
                clientConfig: {secureSocket: {disable: true}}
            }
        }
    };
    jwt:Payload|jwt:Error payload = jwt:validate(token, config);
    if payload is jwt:Error {
        log:printWarn("portal token rejected", 'error = payload);
        return <http:Unauthorized>{body: {message: "Invalid token"}};
    }
    anydata usernameClaim = payload["username"] ?: payload["email"];
    if usernameClaim !is string {
        return <http:Unauthorized>{body: {message: "The token names no user"}};
    }
    string[] roles = [];
    anydata groups = payload["groups"];
    if groups is anydata[] {
        foreach anydata g in groups {
            if g is string {
                string? role = GROUP_TO_ROLE[g];
                if role is string {
                    roles.push(role);
                }
            }
        }
    }
    return {username: usernameClaim, roles: roles};
}

type NewClaim record {|
    decimal amount;
    string description?;
    string billUrl?;
|};

type TaskDecision record {|
    json result;
|};

type PortalTask record {|
    string taskId;
    string title;
    string status;
    string startTime;
    string[] userRoles;
    string parentWorkflowId;
    map<json>? payload;
|};

// The claims API: the bill inlet and the durable listing live here because events and
// the claims table both belong to this integration. The user portal calls these.
service /claims on new http:Listener(8080) {

    # The bill inlet: what the bill store calls to attach a bill to a waiting claim.
    # Delivered into the parked instance as the `billUploaded` event — events travel
    # through code in the owning integration, not through the ICP.
    resource function post [string workflowId]/bills(BillAttachment bill) returns json|error {
        check workflow:sendData(claimApproval, workflowId, "billUploaded", bill.toJson());
        // The durable record carries the bill immediately, whatever stage the workflow
        // is at — the event stays buffered until the flow asks for it.
        _ = check db->execute(`UPDATE claims SET bill_url = ${bill.url}, updated_at = now()
            WHERE workflow_id = ${workflowId}`);
        log:printInfo(string `bill attached to ${workflowId}: ${bill.url}`);
        return {attached: true, workflowId: workflowId};
    }

    # Submit a claim as the signed-in portal user. Starts the workflow; the durable
    # record and the notifications tell the rest of the story.
    resource function post .(@http:Header string? authorization, NewClaim newClaim)
            returns json|http:Unauthorized|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        string claimId = "CLM-" + uuid:createType4AsString().substring(0, 8).toUpperAscii();
        Claim claim = {
            id: claimId,
            amount: newClaim.amount,
            submittedBy: caller.username,
            description: newClaim?.description,
            billUrl: newClaim?.billUrl
        };
        string workflowId = check workflow:run(claimApproval, input = claim);
        return {claimId: claimId, workflowId: workflowId, status: "SUBMITTED"};
    }

    # The signed-in user's claims, from the durable record.
    resource function get my(@http:Header string? authorization)
            returns ClaimRecord[]|http:Unauthorized|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        return self.listClaims(caller.username);
    }

    # The signed-in user's pending decisions — the portal's LIMITED task surface: only
    # tasks whose roles intersect the caller's, only the fields the decision needs.
    resource function get tasks(@http:Header string? authorization)
            returns PortalTask[]|http:Unauthorized|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        if caller.roles.length() == 0 {
            return [];
        }
        management:HumanTaskSummary[] all = check management:listAllHumanTasks(status = "PENDING");
        PortalTask[] mine = [];
        foreach management:HumanTaskSummary t in all {
            // The listing spans the namespace, but completion is task-queue-scoped: only
            // this integration's own tasks belong here. The Smart Claim agent's tasks are
            // listed (and completed) by its own service.
            if !t.taskName.startsWith("claimApproval") {
                continue;
            }
            boolean eligible = false;
            foreach string r in t.userRoles {
                if caller.roles.indexOf(r) is int {
                    eligible = true;
                    break;
                }
            }
            if !eligible {
                continue;
            }
            management:HumanTaskInfo|error info = management:getHumanTaskInfo(t.taskId);
            // The native layer hands the payload back as map<anydata> even though the
            // record says map<json> — assigning it directly is a runtime type panic.
            map<json>? payload = ();
            if info is management:HumanTaskInfo {
                json coerced = (info.payload).toJson();
                if coerced is map<json> {
                    payload = coerced;
                }
            }
            mine.push({
                taskId: t.taskId,
                title: t.title,
                status: t.status,
                startTime: t.startTime,
                userRoles: t.userRoles,
                parentWorkflowId: t.parentWorkflowId,
                payload: payload
            });
        }
        return mine;
    }

    # Decide one task. The module itself validates the caller's roles against the
    # task's, and records who decided — the same arbiter the ICP goes through, so a
    # portal decision racing a console decision resolves to exactly one outcome.
    resource function post tasks/[string taskId]/complete(@http:Header string? authorization,
            TaskDecision decision) returns json|http:Unauthorized|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        if caller.roles.length() == 0 {
            return <http:Unauthorized>{body: {message: "No decision roles"}};
        }
        [string, string...] callerRoles = [caller.roles[0], ...caller.roles.slice(1)];
        check workflow:completeHumanTask(taskId, decision.result,
            callerRoles = callerRoles, userId = caller.username);
        return {completed: true, taskId: taskId, decidedBy: caller.username};
    }

    # A user's claims, from the durable record — not from Temporal, whose history ages
    # out with the retention window. Unauthenticated variant kept for the walkthrough.
    resource function get .(string? user) returns ClaimRecord[]|error {
        sql:ParameterizedQuery q = user is string
            ? `SELECT claim_id AS "claimId", workflow_id AS "workflowId",
                      submitted_by AS "submittedBy", amount, status, bill_url AS "billUrl",
                      note, filed_via AS "filedVia", updated_at::text AS "updatedAt"
                 FROM claims WHERE submitted_by = ${user} ORDER BY updated_at DESC LIMIT 100`
            : `SELECT claim_id AS "claimId", workflow_id AS "workflowId",
                      submitted_by AS "submittedBy", amount, status, bill_url AS "billUrl",
                      note, filed_via AS "filedVia", updated_at::text AS "updatedAt"
                 FROM claims ORDER BY updated_at DESC LIMIT 100`;
        stream<ClaimRecord, sql:Error?> rows = db->query(q);
        return from ClaimRecord c in rows select c;
    }

    isolated function listClaims(string user) returns ClaimRecord[]|error {
        stream<ClaimRecord, sql:Error?> rows = db->query(
            `SELECT claim_id AS "claimId", workflow_id AS "workflowId",
                    submitted_by AS "submittedBy", amount, status, bill_url AS "billUrl",
                    note, filed_via AS "filedVia", updated_at::text AS "updatedAt"
               FROM claims WHERE submitted_by = ${user} ORDER BY updated_at DESC LIMIT 100`);
        return from ClaimRecord c in rows select c;
    }
}
