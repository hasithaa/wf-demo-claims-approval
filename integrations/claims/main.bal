// The claim approval process — the deterministic half of the Claimflow demo.
//
// The claim is created first; the bill is something the reviewing manager may ASK for.
// The review task is three-way (APPROVE | REQUEST_BILL | REJECT), a requested bill
// arrives as the `billUploaded` event carrying the bill-store URL, and the payment is
// released by an accountant before it executes.
//
// The workflow is the orchestrator, not the database: every state change runs the
// recordClaimState activity, which upserts the claims table. Temporal keeps history for
// its retention window; the claims table is the record that outlives it, and what the
// user portal lists.
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
    return c;
}

type Claim record {|
    string id;
    decimal amount;
    string submittedBy;
    string description?;
    // Optional at submission: most claims start without one.
    string billUrl?;
|};

type Validation record {|
    boolean plausible;
    string note;
|};

type BillAttachment record {|
    string url;
    string note?;
|};

// The three-way decision the manager makes. The string-literal union renders as a
// choice in the generated task form.
type ReviewDecision record {|
    "APPROVE"|"REQUEST_BILL"|"REJECT" outcome;
    string comment?;
|};

type PayApproval record {|
    boolean approved;
    string account?;
    string comment?;
|};

type Receipt record {|
    string reference;
    decimal amount;
|};

type ClaimResult record {|
    string claimId;
    "PAID"|"REJECTED" status;
    string reference?;
    string reason?;
|};

type ClaimRecord record {|
    string claimId;
    string workflowId;
    string submittedBy;
    decimal amount;
    string status;
    string? billUrl;
    string? note;
    string updatedAt;
|};

# A claim from submission to payment. Parks on the manager's review; when the manager
# requests a bill, parks again on the `billUploaded` event and reviews once more with
# the bill in the payload.
@workflow:Workflow
function claimApproval(workflow:Context ctx, Claim claim,
        record {|future<json> billUploaded;|} events) returns ClaimResult|error {
    string wfId = check ctx.getWorkflowId();
    string _submitted = check ctx->callActivity(recordClaimState,
        {"claim": claim, "workflowId": wfId, "status": "SUBMITTED", "note": ()});
    Validation v = check ctx->callActivity(validateClaim,
        {"id": claim.id, "amount": claim.amount});

    ReviewDecision decision = check ctx->awaitHumanTask("reviewClaim", "MANAGER",
        payload = {
            "claimId": claim.id,
            "amount": claim.amount,
            "submittedBy": claim.submittedBy,
            "description": claim?.description,
            "billUrl": claim?.billUrl,
            "validation": v.note
        },
        title = "Review claim " + claim.id);

    if decision.outcome == "REQUEST_BILL" {
        string _billAsked = check ctx->callActivity(recordClaimState,
            {"claim": claim, "workflowId": wfId, "status": "BILL_REQUESTED", "note": decision?.comment});
        string _billAsk = check ctx->callActivity(notifyUser,
            {"user": claim.submittedBy, "title": "A bill is required for claim " + claim.id,
                "body": decision?.comment, "link": ()});
        // Parks until a bill is attached (the bill store's URL travels in the event).
        json bill = check wait events.billUploaded;
        string billUrl = check bill.url;
        claim.billUrl = billUrl;
        string _billIn = check ctx->callActivity(recordClaimState,
            {"claim": claim, "workflowId": wfId, "status": "BILL_ATTACHED", "note": ()});
        decision = check ctx->awaitHumanTask("reviewClaimWithBill", "MANAGER",
            payload = {
                "claimId": claim.id,
                "amount": claim.amount,
                "submittedBy": claim.submittedBy,
                "bill": bill
            },
            title = "Review claim " + claim.id + " (bill attached)");
    }

    if decision.outcome != "APPROVE" {
        string _r = check ctx->callActivity(recordClaimState,
            {"claim": claim, "workflowId": wfId, "status": "REJECTED", "note": decision?.comment});
        string _rejected = check ctx->callActivity(notifyUser,
            {"user": claim.submittedBy, "title": "Claim " + claim.id + " was rejected",
                "body": decision?.comment, "link": ()});
        return {claimId: claim.id, status: "REJECTED", reason: decision?.comment};
    }

    // The money moves only after an accountant releases it.
    PayApproval pay = check ctx->awaitHumanTask("approvePayment", "ACCOUNTANT",
        payload = {"claimId": claim.id, "amount": claim.amount, "payee": claim.submittedBy},
        title = "Approve payment for claim " + claim.id);
    if !pay.approved {
        string _pr = check ctx->callActivity(recordClaimState,
            {"claim": claim, "workflowId": wfId, "status": "PAYMENT_REFUSED", "note": pay?.comment});
        string _refused = check ctx->callActivity(notifyUser,
            {"user": claim.submittedBy, "title": "Payment for claim " + claim.id + " was refused",
                "body": pay?.comment, "link": ()});
        return {claimId: claim.id, status: "REJECTED", reason: pay?.comment};
    }

    Receipt receipt = check ctx->callActivity(executePayment,
        {"claimId": claim.id, "amount": claim.amount, "account": pay?.account});
    string _paidState = check ctx->callActivity(recordClaimState,
        {"claim": claim, "workflowId": wfId, "status": "PAID", "note": receipt.reference});
    string _paid = check ctx->callActivity(notifyUser,
        {"user": claim.submittedBy, "title": "Claim " + claim.id + " paid",
            "body": "Reference " + receipt.reference, "link": ()});
    return {claimId: claim.id, status: "PAID", reference: receipt.reference};
}

@workflow:Activity
function validateClaim(string id, decimal amount) returns Validation|error {
    if amount <= 0d {
        return error("A claim must be for a positive amount");
    }
    string note = amount > 1000d
        ? "High-value claim: a bill is recommended before approval"
        : "Routine claim";
    return {plausible: true, note: note};
}

@workflow:Activity
function executePayment(string claimId, decimal amount, string? account) returns Receipt|error {
    // A later phase can make this a real transfer; the gate in front of it is the point.
    return {reference: "PAY-" + claimId, amount: amount};
}

# The durable record: every transition upserts the claims table. Idempotent by
# construction, so a replay that re-runs nothing (activities never re-execute) and a
# retry that runs twice both leave the same row.
@workflow:Activity
function recordClaimState(Claim claim, string workflowId, string status, string? note)
        returns string|error {
    _ = check db->execute(`INSERT INTO claims
            (claim_id, workflow_id, submitted_by, amount, status, bill_url, note, updated_at)
        VALUES (${claim.id}, ${workflowId}, ${claim.submittedBy}, ${claim.amount},
            ${status}, ${claim?.billUrl}, ${note}, now())
        ON CONFLICT (claim_id) DO UPDATE SET
            status = EXCLUDED.status,
            bill_url = COALESCE(EXCLUDED.bill_url, claims.bill_url),
            note = EXCLUDED.note,
            updated_at = now()`);
    return status;
}

@workflow:Activity
function notifyUser(string user, string title, string? body, string? link) returns string|error {
    // Best-effort: a notification hiccup must not wedge a claim.
    json|error posted = notifications->post("/notifications",
        {user: user, title: title, body: body, link: link});
    if posted is error {
        log:printWarn("could not deliver a notification", 'error = posted);
        return "undelivered";
    }
    return "notified";
}

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
                      note, updated_at::text AS "updatedAt"
                 FROM claims WHERE submitted_by = ${user} ORDER BY updated_at DESC LIMIT 100`
            : `SELECT claim_id AS "claimId", workflow_id AS "workflowId",
                      submitted_by AS "submittedBy", amount, status, bill_url AS "billUrl",
                      note, updated_at::text AS "updatedAt"
                 FROM claims ORDER BY updated_at DESC LIMIT 100`;
        stream<ClaimRecord, sql:Error?> rows = db->query(q);
        return from ClaimRecord c in rows select c;
    }

    isolated function listClaims(string user) returns ClaimRecord[]|error {
        stream<ClaimRecord, sql:Error?> rows = db->query(
            `SELECT claim_id AS "claimId", workflow_id AS "workflowId",
                    submitted_by AS "submittedBy", amount, status, bill_url AS "billUrl",
                    note, updated_at::text AS "updatedAt"
               FROM claims WHERE submitted_by = ${user} ORDER BY updated_at DESC LIMIT 100`);
        return from ClaimRecord c in rows select c;
    }
}
