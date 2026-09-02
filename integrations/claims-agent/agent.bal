// The Smart Claim agent itself: the pre-approval rules, the activities that are its
// hands, and the DurableAgent declaration that wires them together. The HTTP surface
// the portal drives lives in main.bal; the keyless scripted stand-in for the model
// lives in scripted_model.bal — this file is only the process.
import ballerina/log;
import ballerina/sql;
import ballerina/uuid;
import ballerina/workflow;

// The pre-approval rules the agent enforces (and its instructions explain).
final decimal BILL_REQUIRED_OVER = 1000d;
final decimal MANAGER_SIGNOFF_OVER = 3000d;

// Who holds a role, for role-addressed notifications. The demo's directory is Thunder;
// this map is the demo shortcut for "everyone in the accountants group".
final map<string[]> & readonly ROLE_MEMBERS = {"ACCOUNTANT": ["john"], "MANAGER": ["jane"]};

// ── Activities: the agent's hands ─────────────────────────────────────────────

# The one-way voice: posts into the user's chat without ending the turn. This is how
# the agent greets, narrates progress, and reports status — a turn reply reaches the
# user only when their message is answered; this reaches them any time.
@workflow:Activity
function sendChatMessage(string workflowId, string message) returns string|error {
    _ = check db->execute(`INSERT INTO agent_turns (conversation_id, who, text)
        VALUES (${workflowId}, 'agent', ${message})`);
    return "delivered";
}

@workflow:Activity
function fileClaim(string workflowId, decimal amount, string description, string submittedBy)
        returns string|error {
    string claimId = "CLM-A" + uuid:createType4AsString().substring(0, 7).toUpperAscii();
    _ = check db->execute(`INSERT INTO claims
            (claim_id, workflow_id, submitted_by, amount, status, note, filed_via, updated_at)
        VALUES (${claimId}, ${workflowId}, ${submittedBy}, ${amount}, 'SUBMITTED',
                ${description}, 'agent', now())
        ON CONFLICT (claim_id) DO NOTHING`);
    return claimId;
}

# The pre-approval rulebook, applied to the claim as recorded: a bill is required over
# $1000, a manager's sign-off over $3000. Returns the facts and the verdict as JSON.
@workflow:Activity
function validateClaim(string claimId) returns string|error {
    stream<record {|decimal amount; string? billUrl;|}, sql:Error?> rows = db->query(
        `SELECT amount, bill_url AS "billUrl" FROM claims WHERE claim_id = ${claimId}`);
    record {|decimal amount; string? billUrl;|}[] found = check from var r in rows select r;
    if found.length() == 0 {
        return error("No claim recorded under " + claimId);
    }
    decimal amount = found[0].amount;
    boolean billAttached = found[0].billUrl is string;
    boolean billRequired = amount > BILL_REQUIRED_OVER;
    boolean managerApprovalRequired = amount > MANAGER_SIGNOFF_OVER;
    string[] missing = [];
    if billRequired && !billAttached {
        missing.push("bill or receipt");
    }
    map<json> verdict = {
        claimId: claimId,
        amount: amount,
        billAttached: billAttached,
        billRequired: billRequired,
        managerApprovalRequired: managerApprovalRequired,
        preApproved: !(billRequired && !billAttached) && !managerApprovalRequired,
        missing: missing
    };
    return verdict.toJsonString();
}

@workflow:Activity
function updateClaimStatus(string claimId, string status, string note) returns string|error {
    _ = check db->execute(`UPDATE claims SET status = ${status}, note = ${note},
        updated_at = now() WHERE claim_id = ${claimId}`);
    return status;
}

# Opens an attachment case for missing documents. The case carries the workflow
# instance id, so the user's later submission is delivered back into this very run as
# a `caseSubmitted` event.
@workflow:Activity
function createAttachmentCase(string workflowId, string claimId, string requested)
        returns string|error {
    string caseId = "CASE-" + uuid:createType4AsString().substring(0, 8).toUpperAscii();
    _ = check db->execute(`INSERT INTO attachment_cases
            (case_id, workflow_id, claim_id, requested)
        VALUES (${caseId}, ${workflowId}, ${claimId}, ${requested})`);
    return caseId;
}

@workflow:Activity
function notifyUser(string username, string title, string body) returns string|error {
    // Best-effort: a notification hiccup must not wedge the claim.
    json|error posted = notifications->post("/notifications",
        {user: username, title: title, body: body, link: ()});
    if posted is error {
        log:printWarn("could not deliver a notification", 'error = posted);
        return "undelivered";
    }
    return "notified";
}

# Tells everyone holding a role. The demo maps roles to users statically; a real
# deployment would resolve the role in the directory.
@workflow:Activity
function notifyRole(string role, string title, string body) returns string|error {
    string[] members = ROLE_MEMBERS[role] ?: [];
    foreach string member in members {
        json|error posted = notifications->post("/notifications",
            {user: member, title: title, body: body, link: ()});
        if posted is error {
            log:printWarn("could not deliver a role notification", 'error = posted);
        }
    }
    return string `notified ${members.length()} ${role}`;
}

# The guarded step: every call parks on a PRE_RUN review an accountant decides.
@workflow:Activity
function executePayment(string claimId, decimal payout) returns string|error {
    string reference = "PAY-" + claimId;
    _ = check db->execute(`UPDATE claims SET status = 'PAID', note = ${reference},
        updated_at = now() WHERE claim_id = ${claimId}`);
    return reference;
}

@workflow:Activity
function estimatePayout(string claimId, decimal amount) returns decimal|error {
    // The insurer's cut: 90%, capped — enough arithmetic to be worth a tool.
    decimal payout = amount * 0.9d;
    return payout > 5000d ? 5000d : payout;
}

// The manager sign-off result — the same shape the claims workflow's review uses, so
// the portal's existing decision card completes it unchanged.
type SignoffDecision record {|
    "APPROVE"|"REQUEST_BILL"|"REJECT" outcome;
    string comment?;
|};

// ── The agent ─────────────────────────────────────────────────────────────────
//
// One event channel on purpose: the module pairs every update with the turn that
// answers it, so a conversational agent cannot park on a second update channel while a
// chat turn is open. The attachment-case submission therefore arrives ON the chat
// channel, as a structured `[case-submitted]` message the service sends.

final workflow:DurableAgent claimAgent = check new ({
    systemPrompt: {
        role: "Smart Claim assistant",
        instructions: string `You run one user's insurance claim case end to end. The run
context names the user (user=<name>); their messages arrive on the chat channel.

Your two voices — use the right one:
- Answering the chat turn ends the turn. Anything you do after a reply reaches nobody
  until the user speaks again, so ACT FIRST, THEN ANSWER with what actually happened.
  Never reply "just a moment" or "filing now".
- sendChatMessage posts to the user's chat WITHOUT ending the turn. Use it for the
  greeting, progress notes, and status updates while you keep working. NEVER send the
  same content you are about to return as the turn's answer — the answer reaches the
  user by itself, and repeating it via sendChatMessage shows the user every message
  twice. Push progress BEFORE the outcome is known; deliver the outcome as the answer.
Call getWorkflowId once at the start and reuse the id for every tool that needs it.

The case, step by step:
1. GREET FIRST. Before anything else: getWorkflowId, then sendChatMessage a short
   greeting asking what happened, what is claimed, and roughly what it cost. Mention
   that claims over $1000 need a bill or receipt. Then reply "ready" to close the turn.
2. GATHER over the chat until you know what happened and the amount.
3. FILE with fileClaim (pass the workflow id) and tell the user the claim id.
4. VALIDATE with validateClaim. The rules it applies: over $1000 a bill or receipt is
   REQUIRED; over $3000 a manager's sign-off is REQUIRED. Send the user a status update
   with the outcome (sendChatMessage).
5. MISSING BILL: when a required bill is not attached, createAttachmentCase (it returns
   a case id), then ANSWER THE TURN telling the user the claim id and to attach the
   document to that case right in the chat view. The submission comes back to you as a
   chat message that starts with [case-submitted] — treat it as an event, not prose:
   validate again and continue the case from step 4.
6. MANAGER SIGN-OFF: when required, call the managerApproval task with the claim facts
   (claimId, amount, submittedBy, description, validation) and wait for the outcome.
   APPROVE means continue. REQUEST_BILL means the manager wants another or better
   document: open a NEW attachment case (step 5), tell the user what the manager asked
   for (their comment), and after the submission validate and ask the manager AGAIN.
   REJECT means: FIRST sendChatMessage the rejection with the manager's comment so the
   user sees it immediately, then updateClaimStatus REJECTED, then reply stating the
   rejection and asking whether there is anything else you can help with.
7. APPROVED: estimatePayout, updateClaimStatus APPROVED, then tell the user (both
   sendChatMessage and notifyUser) the claim is approved and waiting for payment
   processing, and notifyRole ACCOUNTANT that a payment awaits release.
8. PAY with executePayment. It is gated: the call parks until an accountant releases it
   in their portal. When it returns, reply with the payment reference and ask whether
   there is anything else you can help with.
9. CLOSE. Once the claim is settled — PAID or REJECTED — the case is over: every later
   reply answers briefly and offers to help with anything else. When the user indicates
   they are done (no, nothing, thanks, bye), call endConversation with a short farewell
   — that completes the workflow. Never leave a settled conversation hanging open.
Be brief and concrete in every message.`
    },
    model: check selectModel(),
    maxIter: 24,
    activities: [
        {activity: sendChatMessage, description: "Post a message into the user's chat without ending the current turn — greetings, progress notes, status updates."},
        {activity: fileClaim, description: "Record the claim in the claims database; returns the claim id."},
        {activity: validateClaim, description: "Apply the pre-approval rules to the recorded claim; returns the facts and verdict as JSON."},
        {activity: updateClaimStatus, description: "Set the claim's status (e.g. APPROVED, REJECTED) with a short note."},
        {activity: createAttachmentCase, description: "Open an attachment case asking the user for a missing document; returns the case id. The user's submission arrives later as the caseSubmitted event."},
        {activity: notifyUser, description: "Send a bell notification to one user."},
        {activity: notifyRole, description: "Send a bell notification to everyone holding a role (e.g. ACCOUNTANT)."},
        {activity: estimatePayout, description: "Compute the payout for a claim amount."},
        // The gate: every call raises a PRE_RUN review decided by an ACCOUNTANT.
        {activity: executePayment, requiresApproval: true, userRoles: "ACCOUNTANT",
            description: "Release the payment. Gated: parks on an accountant's approval before it runs."}
    ],
    events: {chat: {request: string, response: string, cardinality: workflow:MULTI_EVENT}},
    humanTasks: {
        managerApproval: {
            userRoles: "MANAGER",
            resultType: SignoffDecision,
            title: "Manager sign-off (Smart Claim)",
            description: "The Smart Claim agent asks for sign-off on a claim above the $3000 threshold."
        }
    }
});
