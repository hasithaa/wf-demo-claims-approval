// The Smart Claim agent — the agentic half of the Claimflow demo.
//
// Same domain as the claims workflow, agentic execution: a durable agent runs the whole
// claim case. It greets first (a one-way chat push — no user turn needed), gathers the
// facts over the chat channel, files the claim, validates it against the pre-approval
// rules, opens an attachment case when the bill is missing and durably waits for the
// case-submitted event, escalates big claims to a manager sign-off task, notifies the
// user and the accountants, and only then reaches for the payment — where
// `requiresApproval: true` parks the call on a PRE_RUN review an ACCOUNTANT decides in
// the portal. Model calls use WSO2's default provider when a token is configured, and a
// scripted stand-in that walks the same path when not — the demo never dies keyless.
import ballerina/ai;
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
configurable string idpIssuer = "https://localhost:8090";
configurable string idpJwksUrl = "https://thunder:8090/oauth2/jwks";

// The pre-approval rules the agent enforces (and its instructions explain).
final decimal BILL_REQUIRED_OVER = 1000d;
final decimal MANAGER_SIGNOFF_OVER = 3000d;

// Who holds a role, for role-addressed notifications. The demo's directory is Thunder;
// this map is the demo shortcut for "everyone in the accountants group".
final map<string[]> & readonly ROLE_MEMBERS = {"ACCOUNTANT": ["john"], "MANAGER": ["jane"]};

final postgresql:Client db = check initDb();
final http:Client notifications = check new (notificationsUrl);

// Conversations, turns, and attachment cases are application data, not workflow
// history: the instance id correlates all three back to the running agent, so a
// returning user resumes the same chat and a case submission finds its process.
function initDb() returns postgresql:Client|error {
    postgresql:Client c = check new (host = dbHost, port = dbPort,
        username = dbUser, password = dbPassword, database = dbName);
    _ = check c->execute(`CREATE TABLE IF NOT EXISTS agent_conversations (
        conversation_id VARCHAR(100) PRIMARY KEY,
        username VARCHAR(200) NOT NULL,
        status VARCHAR(16) NOT NULL DEFAULT 'OPEN',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now())`);
    _ = check c->execute(`CREATE TABLE IF NOT EXISTS agent_turns (
        id BIGSERIAL PRIMARY KEY,
        conversation_id VARCHAR(100) NOT NULL,
        who VARCHAR(8) NOT NULL,
        text TEXT,
        token VARCHAR(100),
        pending BOOLEAN NOT NULL DEFAULT FALSE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now())`);
    _ = check c->execute(`CREATE INDEX IF NOT EXISTS idx_agent_turns_conv
        ON agent_turns (conversation_id, id)`);
    // An attachment case asks the user for a missing document. The workflow instance id
    // is the correlation identifier: a submission finds the waiting agent through it.
    _ = check c->execute(`CREATE TABLE IF NOT EXISTS attachment_cases (
        case_id VARCHAR(40) PRIMARY KEY,
        workflow_id VARCHAR(100) NOT NULL,
        claim_id VARCHAR(40) NOT NULL,
        requested TEXT NOT NULL,
        status VARCHAR(12) NOT NULL DEFAULT 'OPEN',
        bill_url VARCHAR(600),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        submitted_at TIMESTAMPTZ)`);
    _ = check c->execute(`CREATE INDEX IF NOT EXISTS idx_cases_wf
        ON attachment_cases (workflow_id, created_at)`);
    // The claims table belongs to the claims service; this column says which channel
    // filed a claim. Idempotent, so whichever service boots first wins harmlessly.
    _ = check c->execute(`ALTER TABLE IF EXISTS claims
        ADD COLUMN IF NOT EXISTS filed_via VARCHAR(16) NOT NULL DEFAULT 'portal'`);
    return c;
}

type Conversation record {|
    string conversationId;
    string username;
    string status;
    string createdAt;
|};

type Turn record {|
    int id;
    string who;
    string? text;
    string? token;
    boolean pending;
    string createdAt;
|};

type AttachmentCase record {|
    string caseId;
    string workflowId;
    string claimId;
    string requested;
    string status;
    string? billUrl;
    string createdAt;
|};

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

// ── The model: WSO2's default provider, or the same provider aimed at a scripted
// stand-in ─────────────────────────────────────────────────────────────────────
//
// `ai:ModelProvider` cannot be implemented in pure Ballerina (its `generate` is
// dependently typed, which requires an external body), so the keyless fallback works at
// the wire instead: a tiny /mockllm endpoint in this same process speaks the provider's
// OpenAI-style chat/completions protocol and walks the claim case deterministically.
// Either way the agent talks to a Wso2ModelProvider — only the far end differs.

isolated function selectModel() returns ai:ModelProvider|error {
    ai:Wso2ModelProvider|ai:Error wso2 = ai:getDefaultModelProvider();
    if wso2 is ai:Wso2ModelProvider {
        log:printInfo("Smart Claim agent uses the WSO2 default model provider");
        return wso2;
    }
    log:printInfo("No WSO2 AI token configured; the Smart Claim agent uses the scripted model");
    return new ai:Wso2ModelProvider("http://localhost:8080/agent/mockllm", "scripted");
}

isolated function extractAmount(string text) returns decimal|error {
    string digits = "";
    boolean seen = false;
    foreach string:Char ch in text {
        if (ch >= "0" && ch <= "9") || (seen && ch == ".") {
            digits += ch;
            seen = true;
        } else if seen {
            break;
        }
    }
    return decimal:fromString(digits);
}

// Everything the scripted brain reads out of the conversation so far, in order.
type ScriptState record {|
    string user = "you";
    string lastUserText = "";
    string? workflowId = ();
    boolean greeted = false;
    boolean approvalChatSent = false;
    string? claimId = ();
    map<json>? validation = ();
    boolean validationStale = false;
    string? caseId = ();
    string? managerOutcome = ();
    string? estimate = ();
    string lastStatus = "";
    boolean userNotified = false;
    boolean accountantsNotified = false;
    string? paymentRef = ();
|};

isolated function scanScript(json[] messages) returns ScriptState {
    ScriptState s = {};
    foreach json m in messages {
        if m !is map<json> {
            continue;
        }
        string role = m["role"] is string ? <string>m["role"] : "";
        string content = m["content"] is string ? <string>m["content"] : "";
        if role == "user" {
            // The run query arrives as the first user turn and carries only context
            // ("user=<name>" plus the structured input) — read the identity, but never
            // treat it as something the person typed.
            if content.startsWith("user=") {
                int? nl = content.indexOf("\n");
                s.user = (nl is int ? content.substring(5, nl) : content.substring(5)).trim();
            } else {
                s.lastUserText = content;
                if content.startsWith("[case-submitted]") {
                    // The attachment case came back: whatever was validated before is
                    // stale — the document is on the claim now.
                    s.validationStale = true;
                }
            }
            continue;
        }
        if role == "assistant" {
            // Tool ARGUMENTS live on the assistant message; use them to tell the
            // one-way chat pushes apart.
            json calls = m["tool_calls"] ?: m["toolCalls"];
            json single = m["function_call"];
            json[] callList = (calls is json[]) ? calls : ((single is map<json>) ? [single] : []);
            foreach json c in callList {
                if c !is map<json> {
                    continue;
                }
                map<json> fn = c["function"] is map<json> ? <map<json>>c["function"] : c;
                string name = fn["name"] is string ? <string>fn["name"] : "";
                if name != "sendChatMessage" {
                    continue;
                }
                string args = fn["arguments"] is string ? <string>fn["arguments"] : "";
                if args.includes("[approved]") {
                    s.approvalChatSent = true;
                } else {
                    s.greeted = true;
                }
            }
            continue;
        }
        if role != "function" && role != "tool" {
            continue;
        }
        string name = m["name"] is string ? <string>m["name"] : "";
        match name {
            "getWorkflowId" => {
                s.workflowId = content.trim();
            }
            "fileClaim" => {
                s.claimId = content.trim();
            }
            "validateClaim" => {
                json|error parsed = content.fromJsonString();
                if parsed is map<json> {
                    s.validation = parsed;
                    s.validationStale = false;
                }
            }
            "createAttachmentCase" => {
                s.caseId = content.trim();
            }
            "managerApproval" => {
                json|error parsed = content.fromJsonString();
                if parsed is map<json> && parsed["outcome"] is string {
                    s.managerOutcome = <string>parsed["outcome"];
                } else {
                    s.managerOutcome = content.includes("REJECT") ? "REJECT" : "APPROVE";
                }
            }
            "estimatePayout" => {
                s.estimate = content.trim();
            }
            "updateClaimStatus" => {
                s.lastStatus = content.trim();
            }
            "notifyUser" => {
                s.userNotified = true;
            }
            "notifyRole" => {
                s.accountantsNotified = true;
            }
            "executePayment" => {
                s.paymentRef = content.trim();
            }
        }
    }
    return s;
}

isolated function callTool(string name, map<json> args) returns map<json> {
    return {function_call: {name: name, arguments: args.toJsonString()}};
}

# The scripted brain: one deterministic ladder through the whole case — greet, gather,
# file, validate, chase the missing bill through an attachment case, escalate to the
# manager over the threshold, notify, and reach for the gated payment.
isolated function scriptedTurn(json[] messages) returns map<json> {
    // A side turn: the framework injects a park-note system message mid-list when the
    // main loop is durably parked and the user asks something meanwhile. Tool-less by
    // contract - answer with a status line.
    foreach json m in messages {
        if m is map<json> && m["role"] == "system" && m["content"] is string
                && (<string>m["content"]).startsWith("You are the same assistant") {
            return {content: "Quick update: the claim is parked on an approval right now - " +
                "I will pick the conversation back up the moment it clears."};
        }
    }
    ScriptState s = scanScript(messages);

    if s.paymentRef is string {
        string claim = s.claimId ?: "your claim";
        return {content: string `All done — ${claim} is paid. Reference ${s.paymentRef ?: ""}.`};
    }
    string? wfId = s.workflowId;
    if wfId is () {
        return callTool("getWorkflowId", {});
    }
    if !s.greeted {
        return callTool("sendChatMessage", {workflowId: wfId, message:
            "Hi! I'm your Smart Claim assistant. Tell me what happened, what you are " +
            "claiming for, and roughly what it cost — I will take it from there. " +
            "Anything over $1000 needs a bill or receipt, so keep one handy."});
    }
    if s.claimId is () {
        if s.lastUserText == "" {
            // Turn 1 was only the run context; the greeting went out on the side
            // channel. Close the turn and wait for the user's first real message.
            return {content: "ready"};
        }
        decimal amount = 0d;
        decimal|error parsed = extractAmount(s.lastUserText);
        if parsed is decimal {
            amount = parsed;
        }
        if amount <= 0d {
            return {content: "Tell me roughly what it cost, and I will file the claim."};
        }
        string desc = s.lastUserText.length() > 300 ? s.lastUserText.substring(0, 300) : s.lastUserText;
        return callTool("fileClaim",
            {workflowId: wfId, amount: amount, description: desc, submittedBy: s.user});
    }
    string claimId = s.claimId ?: "";
    map<json>? validation = s.validation;
    if validation is () || s.validationStale {
        return callTool("validateClaim", {claimId: claimId});
    }
    decimal amount = 0d;
    json vAmount = validation["amount"];
    if vAmount is decimal|int|float {
        amount = <decimal>vAmount;
    }
    boolean billShort = validation["billRequired"] == true && validation["billAttached"] != true;
    boolean billChase = billShort || (s.managerOutcome == "REQUEST_BILL" && validation["billAttached"] != true);
    if billChase {
        if s.caseId is () {
            return callTool("createAttachmentCase",
                {workflowId: wfId, claimId: claimId, requested: "the bill or receipt for this claim"});
        }
        // Answer the turn: the case submission comes back as the next chat message.
        return {content: string `I filed ${claimId} — but it is over $1000, so I need the bill or receipt. Attach it to case ${s.caseId ?: ""} right below this chat and I will pick the claim back up.`};
    }
    if validation["managerApprovalRequired"] == true && s.managerOutcome is () {
        return callTool("managerApproval", {claimId: claimId, amount: amount,
            submittedBy: s.user, description: s.lastUserText,
            validation: string `Over the $3000 sign-off threshold; bill attached: ${validation["billAttached"] == true}`});
    }
    if s.managerOutcome == "REJECT" {
        if s.lastStatus != "REJECTED" {
            return callTool("updateClaimStatus",
                {claimId: claimId, status: "REJECTED", note: "The manager rejected the claim"});
        }
        return {content: string `I'm sorry — the manager rejected ${claimId}. Nothing was paid.`};
    }
    if s.estimate is () {
        return callTool("estimatePayout", {claimId: claimId, amount: amount});
    }
    if s.lastStatus != "APPROVED" {
        return callTool("updateClaimStatus", {claimId: claimId, status: "APPROVED",
            note: string `Pre-approved; payout $${s.estimate ?: ""} awaiting release`});
    }
    if !s.approvalChatSent {
        return callTool("sendChatMessage", {workflowId: wfId, message:
            string `[approved] Good news — ${claimId} is approved for $${s.estimate ?: ""}. It is now waiting for payment processing by the accountant.`});
    }
    if !s.userNotified {
        return callTool("notifyUser", {username: s.user, title: string `Claim ${claimId} approved`,
            body: string `Approved for $${s.estimate ?: ""}; waiting for payment processing.`});
    }
    if !s.accountantsNotified {
        return callTool("notifyRole", {role: "ACCOUNTANT",
            title: string `Payment pending: ${claimId}`,
            body: string `$${s.estimate ?: ""} awaits release — open Decisions in the portal.`});
    }
    decimal payout = 0d;
    decimal|error parsedPayout = decimal:fromString(s.estimate ?: "0");
    if parsedPayout is decimal {
        payout = parsedPayout;
    }
    return callTool("executePayment", {claimId: claimId, payout: payout});
}

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
  greeting, progress notes, and status updates while you keep working.
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
   APPROVE means continue; REQUEST_BILL means chase the bill (step 5) and ask again;
   REJECT means updateClaimStatus REJECTED, tell the user why, and stop.
7. APPROVED: estimatePayout, updateClaimStatus APPROVED, then tell the user (both
   sendChatMessage and notifyUser) the claim is approved and waiting for payment
   processing, and notifyRole ACCOUNTANT that a payment awaits release.
8. PAY with executePayment. It is gated: the call parks until an accountant releases it
   in their portal. When it returns, reply with the payment reference.
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
            roles: "MANAGER",
            resultType: SignoffDecision,
            title: "Manager sign-off (Smart Claim)",
            description: "The Smart Claim agent asks for sign-off on a claim above the $3000 threshold."
        }
    }
});

// ── Portal authentication (same contract as the claims service) ───────────────

final map<string> & readonly GROUP_TO_ROLE = {"managers": "MANAGER", "accountants": "ACCOUNTANT"};

type Caller record {|
    string username;
    string[] roles;
|};

isolated function authenticate(string? authorization) returns Caller|http:Unauthorized {
    if authorization is () || !authorization.startsWith("Bearer ") {
        return <http:Unauthorized>{body: {message: "A Bearer token is required"}};
    }
    jwt:Payload|jwt:Error payload = jwt:validate(authorization.substring(7), {
        issuer: idpIssuer,
        clockSkew: 30,
        signatureConfig: {
            jwksConfig: {url: idpJwksUrl, clientConfig: {secureSocket: {disable: true}}}
        }
    });
    if payload is jwt:Error {
        log:printWarn("smart-claim token rejected", 'error = payload);
        return <http:Unauthorized>{body: {message: "Invalid token"}};
    }
    anydata username = payload["username"] ?: payload["email"];
    if username !is string {
        return <http:Unauthorized>{body: {message: "The token names no user"}};
    }
    string[] roles = [];
    anydata groups = payload["groups"];
    if groups is anydata[] {
        foreach anydata g in groups {
            if g is string && GROUP_TO_ROLE[g] is string {
                roles.push(GROUP_TO_ROLE[g] ?: "");
            }
        }
    }
    return {username: username, roles: roles};
}

type NewMessage record {|
    string message;
|};

type CaseSubmission record {|
    string url;
    string billId?;
|};

type ReviewDecisionRequest record {|
    "proceed"|"reject" action;
    string feedback?;
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

// ── The chat API the Smart Claim portal drives ────────────────────────────────

service /agent on new http:Listener(8080) {

    # The scripted model's wire endpoint (see selectModel). Not part of the portal API.
    resource function post mockllm/chat/completions(map<json> request) returns http:Ok {
        json[] messages = request["messages"] is json[] ? <json[]>request["messages"] : [];
        map<json> turn = scriptedTurn(messages);
        map<json> message = {"role": "assistant"};
        foreach [string, json] [k, v] in turn.entries() {
            message[k] = v;
        }
        // http:Ok, not the bare json: a bare return answers 201 Created, and the
        // provider's client treats anything but 200 as a connection failure.
        return <http:Ok>{body: {
            id: "scripted",
            'object: "chat.completion",
            created: 0,
            model: "scripted-claim-model",
            choices: [{index: 0, message: message, finish_reason: "stop"}],
            usage: {prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
        }};
    }

    # Opens a conversation: starts one durable agent instance for this user and records
    # it. There is no first message — the agent speaks first, greeting the user through
    # its chat-push activity; the run query carries only the user's identity.
    resource function post conversations(@http:Header string? authorization)
            returns json|http:Unauthorized|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        string instanceId = check claimAgent.run(string `user=${caller.username}`,
            input = {user: caller.username});
        _ = check db->execute(`INSERT INTO agent_conversations (conversation_id, username)
            VALUES (${instanceId}, ${caller.username}) ON CONFLICT DO NOTHING`);
        return {conversationId: instanceId};
    }

    # The caller's conversations, newest first.
    resource function get conversations(@http:Header string? authorization)
            returns Conversation[]|http:Unauthorized|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        stream<Conversation, sql:Error?> rows = db->query(
            `SELECT conversation_id AS "conversationId", username, status,
                    created_at::text AS "createdAt"
               FROM agent_conversations WHERE username = ${caller.username}
              ORDER BY created_at DESC LIMIT 50`);
        return from Conversation c in rows select c;
    }

    # One conversation's transcript — the durable record of the chat, tokens included,
    # so a fresh browser session resumes exactly where the last one stopped.
    resource function get conversations/[string id](@http:Header string? authorization)
            returns Turn[]|http:Unauthorized|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        boolean owned = check self.owns(id, caller.username);
        if !owned {
            return <http:Unauthorized>{body: {message: "Not your conversation"}};
        }
        stream<Turn, sql:Error?> rows = db->query(
            `SELECT id, who, text, token, pending, created_at::text AS "createdAt"
               FROM agent_turns WHERE conversation_id = ${id} ORDER BY id`);
        return from Turn t in rows select t;
    }

    # The conversation's attachment cases — the chat view renders OPEN ones as an
    # upload prompt right in the thread.
    resource function get conversations/[string id]/cases(@http:Header string? authorization)
            returns AttachmentCase[]|http:Unauthorized|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        boolean owned = check self.owns(id, caller.username);
        if !owned {
            return <http:Unauthorized>{body: {message: "Not your conversation"}};
        }
        stream<AttachmentCase, sql:Error?> rows = db->query(
            `SELECT case_id AS "caseId", workflow_id AS "workflowId", claim_id AS "claimId",
                    requested, status, bill_url AS "billUrl", created_at::text AS "createdAt"
               FROM attachment_cases WHERE workflow_id = ${id} ORDER BY created_at`);
        return from AttachmentCase c in rows select c;
    }

    # A case submission: the uploaded document lands on the claim, the case closes, and
    # the `caseSubmitted` event wakes the waiting agent — the case's workflow id is the
    # correlation that finds the right run.
    resource function post cases/[string caseId]/submit(@http:Header string? authorization,
            CaseSubmission submission) returns json|http:Unauthorized|http:NotFound|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        stream<AttachmentCase, sql:Error?> rows = db->query(
            `SELECT case_id AS "caseId", workflow_id AS "workflowId", claim_id AS "claimId",
                    requested, status, bill_url AS "billUrl", created_at::text AS "createdAt"
               FROM attachment_cases WHERE case_id = ${caseId}`);
        AttachmentCase[] found = check from AttachmentCase c in rows select c;
        if found.length() == 0 {
            return <http:NotFound>{body: {message: "No such case"}};
        }
        AttachmentCase c = found[0];
        boolean owned = check self.owns(c.workflowId, caller.username);
        if !owned {
            return <http:Unauthorized>{body: {message: "Not your case"}};
        }
        // The bill must be on the claim BEFORE the agent wakes: it re-validates
        // immediately and must see what was submitted.
        _ = check db->execute(`UPDATE claims SET bill_url = ${submission.url},
            updated_at = now() WHERE claim_id = ${c.claimId}`);
        _ = check db->execute(`UPDATE attachment_cases SET status = 'SUBMITTED',
            bill_url = ${submission.url}, submitted_at = now() WHERE case_id = ${caseId}`);
        // The wake-up event rides the chat channel (see the events declaration for
        // why): a structured message the agent recognizes, a turn the user can watch.
        string token = check claimAgent.sendData(c.workflowId, "chat",
            string `[case-submitted] Case ${caseId} for claim ${c.claimId}: document attached (${submission.url}).`);
        _ = check db->execute(`INSERT INTO agent_turns (conversation_id, who, text)
            VALUES (${c.workflowId}, 'me', ${"📎 Attached the document to case " + caseId})`);
        _ = check db->execute(`INSERT INTO agent_turns (conversation_id, who, token, pending)
            VALUES (${c.workflowId}, 'agent', ${token}, TRUE)`);
        return {submitted: true, caseId: caseId, token: token};
    }

    # One user turn: durably delivered, correlated by the returned token, and recorded —
    # the user's words and the pending reply slot both land in the application database.
    resource function post conversations/[string id]/messages(
            @http:Header string? authorization, NewMessage m)
            returns json|http:Unauthorized|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        boolean owned = check self.owns(id, caller.username);
        if !owned {
            return <http:Unauthorized>{body: {message: "Not your conversation"}};
        }
        string token = check claimAgent.sendData(id, "chat", m.message);
        _ = check db->execute(`INSERT INTO agent_turns (conversation_id, who, text)
            VALUES (${id}, 'me', ${m.message})`);
        _ = check db->execute(`INSERT INTO agent_turns (conversation_id, who, token, pending)
            VALUES (${id}, 'agent', ${token}, TRUE)`);
        return {token: token};
    }

    # The reply for one turn, as a long poll: waitForDataResult durably blocks until the
    # agent answers — including while the payment gate waits on the accountant, which is
    # the demo's point. The proxy cuts a poll after ~60s; the portal simply polls again,
    # so a long-held gate reads as successive quiet polls, not a failure.
    resource function get conversations/[string id]/replies/[string token](
            @http:Header string? authorization) returns http:Response|http:Unauthorized|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        string|error reply = claimAgent.waitForDataResult(id, token);
        http:Response res = new;
        if reply is error {
            // The run ended without answering this turn — failed, terminated, or
            // concluded. Close the turn out so the portal stops waiting on it.
            string reason = "The agent run has ended; start a new AI claim.";
            _ = check db->execute(`UPDATE agent_turns SET text = ${reason}, pending = FALSE
                WHERE conversation_id = ${id} AND token = ${token}`);
            _ = check db->execute(`UPDATE agent_conversations SET status = 'CLOSED'
                WHERE conversation_id = ${id}`);
            log:printWarn("agent turn unanswered", 'error = reply);
            res.statusCode = 410;
            res.setJsonPayload({ended: true, message: reason});
            return res;
        }
        _ = check db->execute(`UPDATE agent_turns SET text = ${reply}, pending = FALSE
            WHERE conversation_id = ${id} AND token = ${token}`);
        res.setJsonPayload({reply: reply});
        return res;
    }

    # The run's own state: still running, or finished with its final answer — the words
    # an agent produces as it concludes never belong to a turn, so the portal reads them
    # here and closes the conversation visually.
    resource function get conversations/[string id]/state(@http:Header string? authorization)
            returns json|http:Unauthorized {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        string|error outcome = claimAgent.getResult(id);
        if outcome is workflow:AgentBusyError {
            return {running: true};
        }
        if outcome is error {
            return {running: false, failed: true};
        }
        return {running: false, "final": outcome};
    }

    # The agent's own human tasks (the manager sign-off): completion is task-queue-
    # scoped, so only this service — the queue's owner — can decide them. Same shape as
    # the claims service's task surface, so the portal renders both with one card.
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
            if !t.taskName.startsWith("claimAgent") {
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

    # Decide one of the agent's tasks. The module validates the caller's roles against
    # the task's and records who decided.
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

    # The accountant's payment queue: pending PRE_RUN reviews of the gated payment,
    # narrowed to the caller's roles — the portal's in-app counterpart of the ICP view.
    resource function get reviews(@http:Header string? authorization)
            returns json|http:Unauthorized|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        if caller.roles.length() == 0 {
            return [];
        }
        management:ReviewActivitySummary[] all =
            check management:listAllReviewActivities(status = "PENDING");
        json[] mine = [];
        foreach management:ReviewActivitySummary r in all {
            boolean eligible = r.userRoles.length() == 0;
            foreach string role in r.userRoles {
                if caller.roles.indexOf(role) is int {
                    eligible = true;
                    break;
                }
            }
            if !eligible {
                continue;
            }
            map<json>? args = ();
            management:ReviewActivityInfo|error info = management:getReviewActivityInfo(r.taskId);
            if info is management:ReviewActivityInfo {
                // The native layer hands maps back as map<anydata>; coerce via JSON.
                json coerced = (info.activityArgs).toJson();
                if coerced is map<json> {
                    args = coerced;
                }
            }
            mine.push(<map<json>>{taskId: r.taskId, title: r.title, activityName: r.activityName,
                parentWorkflowId: r.parentWorkflowId, startTime: r.startTime, args: args});
        }
        return mine;
    }

    # Decide one payment review. The module validates the caller's roles against the
    # gate's and records who decided — the same arbiter the ICP goes through.
    resource function post reviews/[string taskId]/decide(@http:Header string? authorization,
            ReviewDecisionRequest decision) returns json|http:Unauthorized|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        if caller.roles.length() == 0 {
            return <http:Unauthorized>{body: {message: "No decision roles"}};
        }
        [string, string...] callerRoles = [caller.roles[0], ...caller.roles.slice(1)];
        check management:completeReviewActivity(taskId,
            {action: decision.action, feedback: decision.feedback},
            callerRoles = callerRoles, userId = caller.username);
        return {decided: true, taskId: taskId, decidedBy: caller.username};
    }

    isolated function owns(string conversationId, string user) returns boolean|error {
        stream<record {|int c;|}, sql:Error?> rows = db->query(
            `SELECT count(*)::int AS c FROM agent_conversations
              WHERE conversation_id = ${conversationId} AND username = ${user}`);
        record {|int c;|}[] found = check from var r in rows select r;
        return found.length() > 0 && found[0].c > 0;
    }
}
