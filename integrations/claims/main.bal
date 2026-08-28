// The claim approval process — the deterministic half of the Claimflow demo.
//
// The claim is created first; the bill is something the reviewing manager may ASK for.
// The review task is three-way (APPROVE | REQUEST_BILL | REJECT), a requested bill
// arrives as the `billUploaded` event carrying the bill-store URL, and the payment is
// released by an accountant before it executes.
//
// Importing the bridge is the whole ICP story — no management port, no plumbing.
import ballerina/http;
import ballerina/log;
import ballerina/workflow;
import wso2/icp.runtime.bridge as _;

type Claim record {|
    string id;
    decimal amount;
    string submittedBy;
    string description?;
    // Optional at submission: most claims start without one.
    string billUrl?;
|};

type BillAttachment record {|
    string url;
    string note?;
|};

type Validation record {|
    boolean plausible;
    string note;
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
# the bill in the payload.
@workflow:Workflow
function claimApproval(workflow:Context ctx, Claim claim,
        record {|future<json> billUploaded;|} events) returns ClaimResult|error {
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
        string _billAsk = check ctx->callActivity(notifyUser,
            {"user": claim.submittedBy, "message": "A bill is required for claim " + claim.id});
        // Parks until a bill is attached (the bill store's URL travels in the event).
        json bill = check wait events.billUploaded;
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
        string _rejected = check ctx->callActivity(notifyUser,
            {"user": claim.submittedBy, "message": "Claim " + claim.id + " was rejected"});
        return {claimId: claim.id, status: "REJECTED", reason: decision?.comment};
    }

    // The money moves only after an accountant releases it.
    PayApproval pay = check ctx->awaitHumanTask("approvePayment", "ACCOUNTANT",
        payload = {"claimId": claim.id, "amount": claim.amount, "payee": claim.submittedBy},
        title = "Approve payment for claim " + claim.id);
    if !pay.approved {
        string _refused = check ctx->callActivity(notifyUser,
            {"user": claim.submittedBy, "message": "Payment for claim " + claim.id + " was refused"});
        return {claimId: claim.id, status: "REJECTED", reason: pay?.comment};
    }

    Receipt receipt = check ctx->callActivity(executePayment,
        {"claimId": claim.id, "amount": claim.amount, "account": pay?.account});
    string _paid = check ctx->callActivity(notifyUser,
        {"user": claim.submittedBy, "message": "Claim " + claim.id + " paid: " + receipt.reference});
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
    // Phase 2 turns this into a real transfer against the claims database.
    return {reference: "PAY-" + claimId, amount: amount};
}

@workflow:Activity
function notifyUser(string user, string message) returns string|error {
    // Phase 2 posts this to the notification service; until then the log is the inbox.
    log:printInfo(string `notify ${user}: ${message}`);
    return "notified";
}

// The bill inlet: what the bill store (and, until it exists, curl) calls to attach a
// bill to a waiting claim. Delivered into the parked instance as the `billUploaded`
// event — events travel through code in the owning integration, not through the ICP.
service /claims on new http:Listener(8080) {
    resource function post [string workflowId]/bills(BillAttachment bill) returns json|error {
        check workflow:sendData(claimApproval, workflowId, "billUploaded", bill.toJson());
        log:printInfo(string `bill attached to ${workflowId}: ${bill.url}`);
        return {attached: true, workflowId: workflowId};
    }
}
