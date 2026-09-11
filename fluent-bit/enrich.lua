-- Enrichment for the Ballerina integrations' log stream, after the ICP's reference pipeline
-- (icp_server/resources/observability/.../fluent-bit/scripts/scripts.lua): the same field names,
-- so the console's Observability tab reads these documents exactly as it reads the documented setup.
--
-- Records arrive tagged claimflow.<service> from Docker's fluentd driver, already parsed (JSON for the
-- integrations' own lines, logfmt for the workflow module's Java lines). Keys still carry their dots
-- here (http.method, src.object.name); the output's Replace_Dots turns them into underscores.

local runtime_ids = {}

local function simple_hash(str)
    local hash1 = 0
    for i = 1, #str do
        hash1 = (hash1 * 31 + string.byte(str, i)) % 2147483647
    end
    local hash2 = 5381
    for i = 1, #str do
        hash2 = (hash2 * 37 + string.byte(str, i)) % 2147483647
    end
    return string.format("%08x%08x", hash1, hash2)
end

local function ts_text(ts)
    if type(ts) == "table" then
        return string.format("%d.%09d", ts.sec or ts[1] or 0, ts.nsec or ts[2] or 0)
    end
    return tostring(ts)
end

-- Every record: who it belongs to, the runtime id the console scopes by, and a document id so a
-- retried bulk request cannot index the same line twice.
function enrich(tag, ts, record)
    local app = string.match(tag, "^claimflow%.(.+)$") or tag
    record["app_name"] = app
    record["deployment"] = app
    record["service_type"] = "BI"
    record["product"] = "ballerina integrator"
    if record["message"] == nil then
        record["message"] = record["log"]
    end
    local module = record["src.module"] or record["module"]
    if module then
        record["app"] = app .. " - " .. module
        record["app_module"] = string.match(module, "^([^/]+)")
    else
        record["app"] = app
    end

    -- The bridge logs its runtime id once at startup. JSON lines carry it as a field (renamed here
    -- to what the console reads and cached for the lines that lack it); unparsed lines still yield
    -- it to the regex.
    local rid = record["icp.runtimeId"]
    if rid == nil then
        local source = record["extras"] or record["log"] or ""
        rid = string.match(source, 'icp%.runtimeId="([^"]+)"')
    end
    if rid ~= nil then
        runtime_ids[app] = rid
        record["icp.runtimeId"] = nil
    end
    if runtime_ids[app] ~= nil then
        record["icp_runtimeId"] = runtime_ids[app]
    end

    local sep = string.char(31)
    record["doc_id"] = simple_hash(ts_text(ts) .. sep .. app .. sep .. tostring(record["message"] or "")
        .. sep .. tostring(record["src.position"] or "") .. sep .. tostring(record["response_time_seconds"] or "")
        .. sep .. tostring(record["taskId"] or ""))
    record["log"] = nil
    return 1, ts, record
end

-- Metric samples only (logger="metrics", re-tagged metrics.*): the derived fields the console's
-- metrics view aggregates on — a numeric response time, a successful/failed status, method and URL.
function metrics(tag, ts, record)
    local seconds = tonumber(record["response_time_seconds"]) or 0
    record["response_time_seconds"] = seconds
    record["response_time"] = math.floor(seconds * 1000 + 0.5)
    local group = record["http.status_code_group"] or ""
    record["status"] = (group == "4xx" or group == "5xx") and "failed" or "successful"
    record["status_code_group"] = group
    record["protocol"] = record["protocol"] or "Unknown"
    local integration = record["src.object.name"] or "Unknown"
    if record["src.main"] == "true" then
        integration = "main"
    end
    record["integration"] = integration
    record["sublevel"] = record["entrypoint.function.name"] or ""
    record["method"] = record["http.method"] or ""
    record["url"] = record["http.url"] or ""
    return 1, ts, record
end
