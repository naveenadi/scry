-- src/export/stream.lua — stream a Result set from the adapter to disk
-- Re-executes one read-only SELECT; not bounded by max_result_rows.

local parse = require("src.sql.parse")
local csv = require("src.export.csv")
local json = require("src.export.json")

local M = {}

local function select_type(type_name)
    return type_name == parse.TYPE_SELECT
        or type_name == parse.TYPE_WITH
        or type_name == parse.TYPE_EXPLAIN
end

-- Returns sql text or nil + error if the last Execution cannot be exported.
function M.eligible_sql(metadata)
    if not metadata then
        return nil, "no execution metadata"
    end
    if metadata.status ~= "success" then
        return nil, "last execution did not succeed"
    end
    local statements = metadata.statements or {}
    if #statements ~= 1 then
        return nil, "export requires a single statement"
    end
    local stmt = statements[1]
    if stmt.status ~= "success" or not stmt.columns then
        return nil, "last statement has no result set"
    end

    local sql = stmt.sql
    if not sql or sql == "" then
        return nil, "no SQL to export"
    end

    local classification = parse.classify_statement(sql)
    if not select_type(classification.type) then
        return nil, "export requires a read-only SELECT"
    end
    if classification.blocked_keyword then
        return nil, "export blocked: " .. classification.blocked_keyword
    end

    return sql
end

local function acquire_result(adapter)
    while adapter:state() == "QUERYING" do
        adapter:poll()
    end

    local state = adapter:state()
    if state == "ERROR" then
        return nil, adapter:error() or "query failed"
    end
    if state == "CANCELED" then
        return nil, "query cancelled"
    end

    if state == "RESULT_READY" or state ~= "FETCHING" then
        local ok, err = adapter:get_result()
        if not ok then
            return nil, err or "get_result failed"
        end
    end

    return true
end

-- format: "csv" or "json"
function M.to_file(adapter, sql, format, path)
    if adapter:state() ~= "READY" then
        return nil, "connection busy"
    end

    local ok, err = adapter:send_query(sql)
    if not ok then
        return nil, err or "send_query failed"
    end

    ok, err = acquire_result(adapter)
    if not ok then
        return nil, err
    end

    local columns = adapter:columns()
    if not columns or #columns == 0 then
        adapter:close_result()
        return nil, "no columns in result"
    end

    local f, ferr = io.open(path, "w")
    if not f then
        adapter:close_result()
        return nil, ferr
    end

    local write_row, finish
    if format == "json" then
        write_row, finish = json.open_writer(f, columns)
    else
        write_row, finish = csv.open_writer(f, columns)
    end

    -- Consume rows until the adapter runs out
    local row_count = 0
    while true do
        local row = adapter:next_row()
        if row == nil then
            break
        end
        write_row(row)
        row_count = row_count + 1
    end
    finish()
    f:close()
    adapter:close_result()

    return true, row_count
end

return M
