// The claim approval process itself: the workflow, its activities, and the types
// they exchange. The claim is created first; the bill is something the reviewing
// manager may ASK for; the payment is released by an accountant before it executes.
// The HTTP surface the portal drives lives in main.bal — this file is only the process.
//
// The workflow is the orchestrator, not the database: every state change runs the
// recordClaimState activity, which upserts the claims table. Temporal keeps history for
// its retention window; the claims table is the record that outlives it, and what the
// user portal lists.
import ballerina/log;
import ballerina/workflow;

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

# A claim from submission to payment. Parks on the manager's review; when the manager
# requests a bill, parks again on the `billUploaded` event and reviews once more with
# the bill in the task input.
@workflow:Workflow
function claimApproval(workflow:Context ctx, Claim claim,
        record {|future<json> billUploaded;|} events) returns ClaimResult|error {
    string wfId = check ctx.getWorkflowId();
    string submittedState = check ctx->callActivity(recordClaimState,
        {"claim": claim, "workflowId": wfId, "status": "SUBMITTED", "note": ()});
    Validation v = check ctx->callActivity(validateClaim,
        {"id": claim.id, "amount": claim.amount});

    ReviewDecision decision = check ctx->awaitHumanTask("reviewClaim",
        {
            "claimId": claim.id,
            "amount": claim.amount,
            "submittedBy": claim.submittedBy,
            "description": claim?.description,
            "billUrl": claim?.billUrl,
            "validation": v.note
        },
        userRoles = "MANAGER", title = "Review claim " + claim.id);

    if decision.outcome == "REQUEST_BILL" {
        string billRequestedState = check ctx->callActivity(recordClaimState,
            {"claim": claim, "workflowId": wfId, "status": "BILL_REQUESTED", "note": decision?.comment});
        string billRequestNotice = check ctx->callActivity(notifyUser,
            {"user": claim.submittedBy, "title": "A bill is required for claim " + claim.id,
                "body": decision?.comment, "link": ()});
        // Parks until a bill is attached (the bill store's URL travels in the event).
        json bill = check wait events.billUploaded;
        string billUrl = check bill.url;
        claim.billUrl = billUrl;
        string billAttachedState = check ctx->callActivity(recordClaimState,
            {"claim": claim, "workflowId": wfId, "status": "BILL_ATTACHED", "note": ()});
        decision = check ctx->awaitHumanTask("reviewClaimWithBill",
            {
                "claimId": claim.id,
                "amount": claim.amount,
                "submittedBy": claim.submittedBy,
                "bill": bill
            },
            userRoles = "MANAGER", title = "Review claim " + claim.id + " (bill attached)");
    }

    if decision.outcome != "APPROVE" {
        string rejectedState = check ctx->callActivity(recordClaimState,
            {"claim": claim, "workflowId": wfId, "status": "REJECTED", "note": decision?.comment});
        string rejectionNotice = check ctx->callActivity(notifyUser,
            {"user": claim.submittedBy, "title": "Claim " + claim.id + " was rejected",
                "body": decision?.comment, "link": ()});
        return {claimId: claim.id, status: "REJECTED", reason: decision?.comment};
    }

    // The money moves only after an accountant releases it.
    PayApproval pay = check ctx->awaitHumanTask("approvePayment",
        {"claimId": claim.id, "amount": claim.amount, "payee": claim.submittedBy},
        userRoles = "ACCOUNTANT", title = "Approve payment for claim " + claim.id);
    if !pay.approved {
        string refusedState = check ctx->callActivity(recordClaimState,
            {"claim": claim, "workflowId": wfId, "status": "PAYMENT_REFUSED", "note": pay?.comment});
        string refusalNotice = check ctx->callActivity(notifyUser,
            {"user": claim.submittedBy, "title": "Payment for claim " + claim.id + " was refused",
                "body": pay?.comment, "link": ()});
        return {claimId: claim.id, status: "REJECTED", reason: pay?.comment};
    }

    Receipt receipt = check ctx->callActivity(executePayment,
        {"claimId": claim.id, "amount": claim.amount, "account": pay?.account});
    string paidState = check ctx->callActivity(recordClaimState,
        {"claim": claim, "workflowId": wfId, "status": "PAID", "note": receipt.reference});
    string paymentNotice = check ctx->callActivity(notifyUser,
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
