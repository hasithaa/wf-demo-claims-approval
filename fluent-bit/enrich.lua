-- Stamps app_name, the BI markers, and the ICP runtime id onto every record.
local runtime_ids = {}

function enrich(tag, ts, record)
    local app = string.match(tag, "^claimflow%.(.+)$") or tag
    record["app_name"] = app
    record["service_type"] = "BI"
    record["product"] = "BI"
    if record["message"] == nil then
        record["message"] = record["log"]
    end
    local source = record["extras"] or record["log"] or ""
    local rid = string.match(source, 'icp%.runtimeId="([^"]+)"')
    if rid ~= nil then
        runtime_ids[app] = rid
    end
    if runtime_ids[app] ~= nil then
        record["icp_runtimeId"] = runtime_ids[app]
    end
    -- The adapter renders `log` over `message` when both exist; the parsed message is the
    -- readable one, so the raw line goes.
    record["log"] = nil
    return 1, ts, record
end
