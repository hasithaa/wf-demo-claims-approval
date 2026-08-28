// The notification service — the user portal's inbox.
//
// A plain service integration: one table, three resources. Workflow activities post
// into it; the portal (phase 4) reads it for the bell icon. Until the portal exists,
// GET /notifications?user=alice is how the demo shows a user what happened.
import ballerina/http;
import ballerina/sql;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;
import wso2/icp.runtime.bridge as _;

configurable string dbHost = "appdb";
configurable int dbPort = 5432;
configurable string dbUser = "app";
configurable string dbPassword = "app";
configurable string dbName = "notifications_db";

final postgresql:Client db = check initDb();

function initDb() returns postgresql:Client|error {
    postgresql:Client c = check new (host = dbHost, port = dbPort,
        username = dbUser, password = dbPassword, database = dbName);
    _ = check c->execute(`CREATE TABLE IF NOT EXISTS notifications (
        id BIGSERIAL PRIMARY KEY,
        username VARCHAR(200) NOT NULL,
        title VARCHAR(400) NOT NULL,
        body TEXT,
        link VARCHAR(600),
        is_read BOOLEAN NOT NULL DEFAULT FALSE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now())`);
    _ = check c->execute(`CREATE INDEX IF NOT EXISTS idx_notifications_user
        ON notifications (username, is_read, created_at DESC)`);
    return c;
}

// body/link are nilable-with-default rather than optional: a sender that writes an
// explicit JSON null (as the claims activities do) must bind, not 400.
type NewNotification record {|
    string user;
    string title;
    string? body = ();
    string? link = ();
|};

type Notification record {|
    int id;
    string username;
    string title;
    string? body;
    string? link;
    boolean isRead;
    string createdAt;
|};

service /notifications on new http:Listener(8080) {

    resource function post .(NewNotification n) returns json|error {
        _ = check db->execute(`INSERT INTO notifications (username, title, body, link)
            VALUES (${n.user}, ${n.title}, ${n.body}, ${n.link})`);
        return {created: true};
    }

    resource function get .(string user, boolean unreadOnly = false) returns Notification[]|error {
        sql:ParameterizedQuery q = unreadOnly
            ? `SELECT id, username, title, body, link, is_read AS "isRead",
                      created_at::text AS "createdAt"
                 FROM notifications WHERE username = ${user} AND is_read = FALSE
                ORDER BY created_at DESC LIMIT 100`
            : `SELECT id, username, title, body, link, is_read AS "isRead",
                      created_at::text AS "createdAt"
                 FROM notifications WHERE username = ${user}
                ORDER BY created_at DESC LIMIT 100`;
        stream<Notification, sql:Error?> rows = db->query(q);
        return from Notification n in rows select n;
    }

    resource function post [int id]/read() returns json|error {
        sql:ExecutionResult r = check db->execute(
            `UPDATE notifications SET is_read = TRUE WHERE id = ${id}`);
        return {read: (r.affectedRowCount ?: 0) > 0};
    }
}
