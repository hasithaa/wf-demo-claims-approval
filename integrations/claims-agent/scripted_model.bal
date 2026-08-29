// The keyless fallback: when no WSO2 AI token is configured, the agent talks to a
// scripted stand-in that walks the same claim case deterministically. All of it lives
// here so the agent's actual process (agent.bal) reads without this noise — the only
// thing main.bal keeps is the /mockllm wire endpoint that serves these turns.
import ballerina/ai;
import ballerina/log;

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
    boolean awaitingCaseSubmit = false;
    string? managerOutcome = ();
    string? managerComment = ();
    boolean managerWantsBill = false;
    boolean rejectedChatSent = false;
    boolean terminal = false;
    boolean userAfterTerminal = false;
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
                    // stale — the document is on the claim now. A submission also
                    // satisfies a manager's document request, so the sign-off is asked
                    // again with the new document on record.
                    s.validationStale = true;
                    s.awaitingCaseSubmit = false;
                    if s.managerWantsBill {
                        s.managerWantsBill = false;
                        s.managerOutcome = ();
                    }
                } else if s.terminal {
                    // The case is settled and the user spoke again: closing etiquette.
                    s.userAfterTerminal = true;
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
                } else if args.includes("[rejected]") {
                    s.rejectedChatSent = true;
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
                s.awaitingCaseSubmit = true;
            }
            "managerApproval" => {
                json|error parsed = content.fromJsonString();
                if parsed is map<json> && parsed["outcome"] is string {
                    s.managerOutcome = <string>parsed["outcome"];
                    json comment = parsed["comment"];
                    s.managerComment = comment is string && comment != "" ? comment : ();
                } else {
                    s.managerOutcome = content.includes("REJECT") ? "REJECT" : "APPROVE";
                }
                s.managerWantsBill = s.managerOutcome == "REQUEST_BILL";
            }
            "estimatePayout" => {
                s.estimate = content.trim();
            }
            "updateClaimStatus" => {
                s.lastStatus = content.trim();
                if s.lastStatus == "REJECTED" {
                    s.terminal = true;
                }
            }
            "notifyUser" => {
                s.userNotified = true;
            }
            "notifyRole" => {
                s.accountantsNotified = true;
            }
            "executePayment" => {
                s.paymentRef = content.trim();
                s.terminal = true;
            }
        }
    }
    return s;
}

isolated function callTool(string name, map<json> args) returns map<json> {
    return {function_call: {name: name, arguments: args.toJsonString()}};
}

// Whether a post-settlement reply means "we're done here" — the cue to end the
// conversation (and with it the workflow) instead of leaving it hanging open.
isolated function isDone(string text) returns boolean {
    string t = text.trim().toLowerAscii();
    if t == "no" || t.startsWith("no ") || t.startsWith("no,") || t.startsWith("no.") {
        return true;
    }
    foreach string done in ["nothing", "nope", "bye", "thanks", "thank you",
            "that's all", "all good", "we're done", "i'm good", "im good", "done"] {
        if t.includes(done) {
            return true;
        }
    }
    return false;
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

    if s.userAfterTerminal {
        // The case is settled and the user spoke again: answer, offer, and close the
        // workflow when they are done.
        if isDone(s.lastUserText) {
            return callTool("endConversation", {farewell:
                "Happy to help — closing this claim conversation. Start a new AI claim anytime."});
        }
        string outcome = s.paymentRef is string
            ? string `${s.claimId ?: "The claim"} is paid — reference ${s.paymentRef ?: ""}.`
            : string `${s.claimId ?: "The claim"} was rejected; nothing was paid.`;
        return {content: outcome + " Is there anything else I can help you with?"};
    }
    if s.paymentRef is string {
        string claim = s.claimId ?: "your claim";
        return {content: string `All done — ${claim} is paid. Reference ${s.paymentRef ?: ""}. Is there anything else I can help you with?`};
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
    if billShort || s.managerWantsBill {
        // A manager's REQUEST_BILL opens a fresh case even when a document is already
        // attached: they looked at it and asked for another. The submission clears
        // managerWantsBill and the sign-off is asked again (see the scan).
        if !s.awaitingCaseSubmit {
            string requested = s.managerWantsBill
                ? "the document the manager asked for"
                    + ((s.managerComment is string) ? ": " + (s.managerComment ?: "") : "")
                : "the bill or receipt for this claim";
            return callTool("createAttachmentCase",
                {workflowId: wfId, claimId: claimId, requested: requested});
        }
        // Answer the turn: the case submission comes back as the next chat message.
        string why = s.managerWantsBill
            ? "The manager asked for another document"
                + ((s.managerComment is string) ? " (" + (s.managerComment ?: "") + ")" : "") + "."
            : string `I filed ${claimId} — but it is over $1000, so I need the bill or receipt.`;
        return {content: why + string ` Attach it to case ${s.caseId ?: ""} right below this chat and I will pick the claim back up.`};
    }
    if validation["managerApprovalRequired"] == true && s.managerOutcome is () {
        return callTool("managerApproval", {claimId: claimId, amount: amount,
            submittedBy: s.user, description: s.lastUserText,
            validation: string `Over the $3000 sign-off threshold; bill attached: ${validation["billAttached"] == true}`});
    }
    if s.managerOutcome == "REJECT" {
        string note = "The manager rejected the claim"
            + ((s.managerComment is string) ? ": " + (s.managerComment ?: "") : "");
        if !s.rejectedChatSent {
            // The rejection reaches the chat immediately, mid-turn, reason included.
            return callTool("sendChatMessage", {workflowId: wfId, message:
                string `[rejected] ${note} (${claimId}). Nothing will be paid.`});
        }
        if s.lastStatus != "REJECTED" {
            return callTool("updateClaimStatus",
                {claimId: claimId, status: "REJECTED", note: note});
        }
        return {content: string `I'm sorry — ${claimId} was rejected. ${note}. Is there anything else I can help you with?`};
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
