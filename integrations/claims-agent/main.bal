// The Smart Claim agent — the agentic half of the Claimflow demo.
//
// Same domain as the claims workflow, agentic execution: a durable agent converses with
// the user over its `chat` event channel (every turn correlated by a token), decides its
// own steps, and when it reaches for the payment activity the same governance stops it —
// `requiresApproval: true` raises a PRE_RUN review for an ACCOUNTANT before the money
// moves. Model calls use WSO2's default provider when a token is configured, and a
// scripted stand-in that walks the happy path when not — the demo never dies keyless.
import ballerina/ai;
import ballerina/http;
import ballerina/jwt;
import ballerina/log;
import ballerina/sql;
import ballerina/uuid;
import ballerina/workflow;
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

final postgresql:Client db = check initDb();
final http:Client notifications = check new (notificationsUrl);

// Conversations are application data, not workflow history: the instance id and every
// turn's correlation token live in the claims database, so a returning user resumes the
// same chat and nothing depends on Temporal retention or a browser session.
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

// ── Activities: the agent's hands ─────────────────────────────────────────────

@workflow:Activity
function fileClaim(decimal amount, string description, string submittedBy)
        returns string|error {
    string claimId = "CLM-A" + uuid:createType4AsString().substring(0, 7).toUpperAscii();
    _ = check db->execute(`INSERT INTO claims
            (claim_id, workflow_id, submitted_by, amount, status, note, updated_at)
        VALUES (${claimId}, 'agent', ${submittedBy}, ${amount}, 'SUBMITTED', ${description}, now())
        ON CONFLICT (claim_id) DO NOTHING`);
    return claimId;
}

@workflow:Activity
function estimatePayout(string claimId, decimal amount) returns decimal|error {
    // The insurer's cut: 90%, capped — enough arithmetic to be worth a tool.
    decimal payout = amount * 0.9d;
    return payout > 5000d ? 5000d : payout;
}

# The guarded step: every call parks on a PRE_RUN review an accountant decides.
@workflow:Activity
function executePayment(string claimId, decimal payout) returns string|error {
    string reference = "PAY-" + claimId;
    _ = check db->execute(`UPDATE claims SET status = 'PAID', note = ${reference},
        updated_at = now() WHERE claim_id = ${claimId}`);
    return reference;
}

// ── The model: WSO2's default provider, or the same provider aimed at a scripted
// stand-in ─────────────────────────────────────────────────────────────────────
//
// `ai:ModelProvider` cannot be implemented in pure Ballerina (its `generate` is
// dependently typed, which requires an external body), so the keyless fallback works at
// the wire instead: a tiny /mockllm endpoint in this same process speaks the provider's
// OpenAI-style chat/completions protocol and walks the claim script deterministically.
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

# The scripted brain, one turn at a time: file the claim once an amount is known,
# estimate the payout, and — told to pay — reach for the gated payment.
isolated function scriptedTurn(json[] messages) returns map<json> {
    string? filedClaim = ();
    string? estimate = ();
    boolean paid = false;
    string lastUserText = "";
    string user = "you";
    foreach json m in messages {
        if m !is map<json> {
            continue;
        }
        string role = m["role"] is string ? <string>m["role"] : "";
        string content = m["content"] is string ? <string>m["content"] : "";
        if role == "function" || role == "tool" {
            string name = m["name"] is string ? <string>m["name"] : "";
            if name == "fileClaim" {
                filedClaim = content.trim();
            } else if name == "estimatePayout" {
                estimate = content.trim();
            } else if name == "executePayment" {
                paid = true;
            }
        } else if role == "user" {
            // The run query arrives as the first user turn and carries only context
            // ("user=<name>" plus the structured input) — read the identity, but never
            // treat it as something the person typed.
            if content.startsWith("user=") {
                int? nl = content.indexOf("\n");
                user = (nl is int ? content.substring(5, nl) : content.substring(5)).trim();
            } else {
                lastUserText = content;
            }
        }
    }
    decimal amount = 0d;
    decimal|error parsed = extractAmount(lastUserText);
    if parsed is decimal {
        amount = parsed;
    }

    if paid {
        string claim = filedClaim ?: "your claim";
        return {content: string `All done — ${claim} is paid. The reference is in your claims list.`};
    }
    if filedClaim is string && estimate is string {
        string lower = lastUserText.toLowerAscii();
        if lower.includes("pay") || lower.includes("yes") || lower.includes("go ahead") {
            return {function_call: {name: "executePayment",
                arguments: string `{"claimId": "${filedClaim}", "payout": ${estimate}}`}};
        }
        return {content: string `Claim ${filedClaim} is filed with an estimated payout of $${estimate}. Say "pay" and I will send it to the accountant for release.`};
    }
    if filedClaim is string {
        return {function_call: {name: "estimatePayout",
            arguments: string `{"claimId": "${filedClaim}", "amount": ${amount}}`}};
    }
    if amount > 0d {
        string desc = lastUserText.length() > 300 ? lastUserText.substring(0, 300) : lastUserText;
        return {function_call: {name: "fileClaim",
            arguments: (<map<json>>{"amount": amount, "description": desc, "submittedBy": user}).toJsonString()}};
    }
    return {content: "Tell me what happened and roughly what it cost — I will file the claim for you."};
}

// ── The agent ─────────────────────────────────────────────────────────────────

final workflow:DurableAgent claimAgent = check new ({
    systemPrompt: {
        role: "Claimflow assistant",
        instructions: string `You help one user file an insurance claim and get it paid.
File the claim with fileClaim as soon as you know the amount, estimate the payout, and
confirm with the user before calling executePayment — which requires an accountant's
approval and may take a while. Be brief and concrete. The user's messages arrive on the
chat channel; answer every turn.`
    },
    model: check selectModel(),
    activities: [
        fileClaim,
        estimatePayout,
        // The gate: every call raises a PRE_RUN review decided by an ACCOUNTANT.
        {activity: executePayment, requiresApproval: true, userRoles: "ACCOUNTANT"}
    ],
    events: {chat: {request: string, response: string, cardinality: workflow:MULTI_EVENT}}
});

// ── Portal authentication (same contract as the claims service) ───────────────

isolated function authenticate(string? authorization) returns string|http:Unauthorized {
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
    return username;
}

type NewMessage record {|
    string message;
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
    # it. The run query carries only the user's identity; every actual user turn goes
    # through the chat channel, so every reply is token-addressed.
    resource function post conversations(@http:Header string? authorization)
            returns json|http:Unauthorized|error {
        string|http:Unauthorized user = authenticate(authorization);
        if user is http:Unauthorized {
            return user;
        }
        string instanceId = check claimAgent.run(string `user=${user}`, input = {user: user});
        _ = check db->execute(`INSERT INTO agent_conversations (conversation_id, username)
            VALUES (${instanceId}, ${user}) ON CONFLICT DO NOTHING`);
        return {conversationId: instanceId};
    }

    # The caller's conversations, newest first.
    resource function get conversations(@http:Header string? authorization)
            returns Conversation[]|http:Unauthorized|error {
        string|http:Unauthorized user = authenticate(authorization);
        if user is http:Unauthorized {
            return user;
        }
        stream<Conversation, sql:Error?> rows = db->query(
            `SELECT conversation_id AS "conversationId", username, status,
                    created_at::text AS "createdAt"
               FROM agent_conversations WHERE username = ${user}
              ORDER BY created_at DESC LIMIT 50`);
        return from Conversation c in rows select c;
    }

    # One conversation's transcript — the durable record of the chat, tokens included,
    # so a fresh browser session resumes exactly where the last one stopped.
    resource function get conversations/[string id](@http:Header string? authorization)
            returns Turn[]|http:Unauthorized|error {
        string|http:Unauthorized user = authenticate(authorization);
        if user is http:Unauthorized {
            return user;
        }
        boolean owned = check self.owns(id, user);
        if !owned {
            return <http:Unauthorized>{body: {message: "Not your conversation"}};
        }
        stream<Turn, sql:Error?> rows = db->query(
            `SELECT id, who, text, token, pending, created_at::text AS "createdAt"
               FROM agent_turns WHERE conversation_id = ${id} ORDER BY id`);
        return from Turn t in rows select t;
    }

    # One user turn: durably delivered, correlated by the returned token, and recorded —
    # the user's words and the pending reply slot both land in the application database.
    resource function post conversations/[string id]/messages(
            @http:Header string? authorization, NewMessage m)
            returns json|http:Unauthorized|error {
        string|http:Unauthorized user = authenticate(authorization);
        if user is http:Unauthorized {
            return user;
        }
        boolean owned = check self.owns(id, user);
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
        string|http:Unauthorized user = authenticate(authorization);
        if user is http:Unauthorized {
            return user;
        }
        string reply = check claimAgent.waitForDataResult(id, token);
        _ = check db->execute(`UPDATE agent_turns SET text = ${reply}, pending = FALSE
            WHERE conversation_id = ${id} AND token = ${token}`);
        http:Response res = new;
        res.setJsonPayload({reply: reply});
        return res;
    }

    isolated function owns(string conversationId, string user) returns boolean|error {
        stream<record {|int c;|}, sql:Error?> rows = db->query(
            `SELECT count(*)::int AS c FROM agent_conversations
              WHERE conversation_id = ${conversationId} AND username = ${user}`);
        record {|int c;|}[] found = check from var r in rows select r;
        return found.length() > 0 && found[0].c > 0;
    }
}
