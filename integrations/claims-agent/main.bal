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
import ballerina/http;
import ballerina/jwt;
import ballerina/log;
import ballerina/sql;
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
        // The believable-latency pause (see scripted_model.bal) — a real model call
        // never answers in a millisecond, and neither should its stand-in.
        scriptedThinkPause();
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
            CaseSubmission submission) returns json|http:Unauthorized|http:NotFound|http:Response|error {
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
        string|error caseToken = claimAgent.sendData(c.workflowId, "chat",
            string `[case-submitted] Case ${caseId} for claim ${c.claimId}: document attached (${submission.url}).`);
        if caseToken is error {
            return check self.conversationEnded(c.workflowId, caseToken);
        }
        string token = caseToken;
        _ = check db->execute(`INSERT INTO agent_turns (conversation_id, who, text)
            VALUES (${c.workflowId}, 'me', ${"📎 Attached the document to case " + caseId})`);
        _ = check db->execute(`INSERT INTO agent_turns (conversation_id, who, token, pending)
            VALUES (${c.workflowId}, 'agent', ${token}, TRUE)`);
        return {submitted: true, caseId: caseId, token: token};
    }

    # One user turn: durably delivered, correlated by the returned token, and recorded —
    # the user's words and the pending reply slot both land in the application database.
    # A send into a run that no longer accepts one answers 410 with a sentence the portal
    # can show, never a raw engine error.
    resource function post conversations/[string id]/messages(
            @http:Header string? authorization, NewMessage m)
            returns json|http:Unauthorized|http:Response|error {
        Caller|http:Unauthorized caller = authenticate(authorization);
        if caller is http:Unauthorized {
            return caller;
        }
        boolean owned = check self.owns(id, caller.username);
        if !owned {
            return <http:Unauthorized>{body: {message: "Not your conversation"}};
        }
        string|error token = claimAgent.sendData(id, "chat", m.message);
        if token is error {
            return check self.conversationEnded(id, token);
        }
        _ = check db->execute(`INSERT INTO agent_turns (conversation_id, who, text)
            VALUES (${id}, 'me', ${m.message})`);
        _ = check db->execute(`INSERT INTO agent_turns (conversation_id, who, token, pending)
            VALUES (${id}, 'agent', ${token}, TRUE)`);
        return {token: token};
    }

    # Marks the conversation CLOSED and answers 410 with a reason a person can read.
    # The engine's words classify the ending: a timeout reads differently from a run
    # that finished, and both read differently from one whose history has aged out.
    isolated function conversationEnded(string id, error cause) returns http:Response|error {
        string msg = cause.message().toLowerAscii();
        string reason;
        if msg.includes("timed out") || msg.includes("timeout") {
            reason = "This conversation timed out while waiting — start a new chat.";
        } else if msg.includes("not found") {
            reason = "This conversation's run is no longer available — start a new chat.";
        } else if msg.includes("completed") || msg.includes("closed") || msg.includes("ended") {
            reason = "This conversation has finished — start a new chat.";
        } else {
            reason = "This conversation has ended — start a new chat.";
        }
        _ = check db->execute(`UPDATE agent_conversations SET status = 'CLOSED'
            WHERE conversation_id = ${id}`);
        log:printWarn("chat operation on an ended conversation", conversation = id, 'error = cause);
        http:Response res = new;
        res.statusCode = 410;
        res.setJsonPayload({ended: true, message: reason});
        return res;
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
            // The run ended without answering this turn — timed out, failed, terminated,
            // or concluded. Close the turn out with the classified reason so the portal
            // stops waiting on it and the transcript says what actually happened.
            http:Response ended = check self.conversationEnded(id, reply);
            json payload = check ended.getJsonPayload();
            string reason = check payload.message;
            _ = check db->execute(`UPDATE agent_turns SET text = ${reason}, pending = FALSE
                WHERE conversation_id = ${id} AND token = ${token}`);
            return ended;
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
        // The run has concluded either way — keep the durable record in step.
        sql:ExecutionResult|sql:Error closed = db->execute(`UPDATE agent_conversations
            SET status = 'CLOSED' WHERE conversation_id = ${id} AND status <> 'CLOSED'`);
        if closed is sql:Error {
            log:printWarn("could not close the conversation record", 'error = closed);
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
