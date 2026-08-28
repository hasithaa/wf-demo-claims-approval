// The bill store — files with state.
//
// A plain service integration with its own database: upload a bill, get back a
// copyable URL; attach it to a waiting claim and the store forwards the event to the
// claims integration. Status moves UPLOADED → ATTACHED as the claim consumes it.
import ballerina/http;
import ballerina/io;
import ballerina/sql;
import ballerina/uuid;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;
import wso2/icp.runtime.bridge as _;

configurable string dbHost = "appdb";
configurable int dbPort = 5432;
configurable string dbUser = "app";
configurable string dbPassword = "app";
configurable string dbName = "bills_db";
configurable string storageDir = "/data/bills";
// What a person can open from outside docker — the copyable half of every bill URL.
configurable string publicBaseUrl = "http://localhost:9081";
// Where the claims integration answers inside the compose network.
configurable string claimsUrl = "http://claims:8080";

final postgresql:Client db = check initDb();
final http:Client claims = check new (claimsUrl);

function initDb() returns postgresql:Client|error {
    postgresql:Client c = check new (host = dbHost, port = dbPort,
        username = dbUser, password = dbPassword, database = dbName);
    _ = check c->execute(`CREATE TABLE IF NOT EXISTS bills (
        bill_id VARCHAR(36) PRIMARY KEY,
        owner VARCHAR(200) NOT NULL,
        claim_id VARCHAR(100),
        filename VARCHAR(400) NOT NULL,
        size_bytes BIGINT NOT NULL,
        status VARCHAR(16) NOT NULL DEFAULT 'UPLOADED',
        uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now())`);
    return c;
}

type Bill record {|
    string billId;
    string owner;
    string? claimId;
    string filename;
    int sizeBytes;
    string status;
    string uploadedAt;
|};

type AttachRequest record {|
    // The workflow instance waiting on its bill.
    string workflowId;
    string claimId?;
|};

service /bills on new http:Listener(8080) {

    # Upload a bill: raw bytes in the body, metadata as query parameters. Returns the
    # bill's id and its copyable URL.
    resource function post .(@http:Payload byte[] content, string filename,
            string owner, string? claimId) returns json|error {
        if content.length() == 0 {
            return error("An empty upload is not a bill");
        }
        string id = uuid:createType4AsString();
        check io:fileWriteBytes(storageDir + "/" + id, content);
        _ = check db->execute(`INSERT INTO bills (bill_id, owner, claim_id, filename, size_bytes)
            VALUES (${id}, ${owner}, ${claimId}, ${filename}, ${content.length()})`);
        return {billId: id, url: publicBaseUrl + "/bills/" + id, filename: filename};
    }

    # The file itself — what the manager opens from the review task.
    resource function get [string id]() returns http:Response|error {
        Bill bill = check self.meta(id);
        byte[] content = check io:fileReadBytes(storageDir + "/" + id);
        http:Response res = new;
        res.setBinaryPayload(content);
        check res.setContentType("application/octet-stream");
        res.setHeader("Content-Disposition", "attachment; filename=\"" + bill.filename + "\"");
        return res;
    }

    resource function get [string id]/meta() returns Bill|error {
        return self.meta(id);
    }

    # Attach an uploaded bill to a waiting claim: forwards the bill's URL to the claims
    # integration (which delivers it into the parked instance as the billUploaded event)
    # and marks the bill ATTACHED.
    resource function post [string id]/attach(AttachRequest req) returns json|error {
        Bill bill = check self.meta(id);
        json body = {url: publicBaseUrl + "/bills/" + id, note: bill.filename};
        json _forwarded = check claims->post("/claims/" + req.workflowId + "/bills", body);
        _ = check db->execute(`UPDATE bills SET status = 'ATTACHED',
            claim_id = COALESCE(${req?.claimId}, claim_id) WHERE bill_id = ${id}`);
        return {attached: true, billId: id, workflowId: req.workflowId};
    }

    isolated function meta(string id) returns Bill|error {
        stream<Bill, sql:Error?> rows = db->query(
            `SELECT bill_id AS "billId", owner, claim_id AS "claimId", filename,
                    size_bytes AS "sizeBytes", status, uploaded_at::text AS "uploadedAt"
               FROM bills WHERE bill_id = ${id}`);
        Bill[] found = check from Bill b in rows select b;
        if found.length() == 0 {
            return error("Unknown bill: " + id);
        }
        return found[0];
    }
}
