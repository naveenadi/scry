-- src/ui/grid.lua — client-side result view (filter, sort, paging, scroll)

local M = {}

function M.new(page_size)
    return {
        page = 1,
        page_size = page_size or 100,
        sort_col = nil,
        sort_asc = true,
        filter = "",
        col_offset = 0,
        select_row = 1,
        select_col = 1,
        filter_mode = false,
        filter_buffer = "",
        pending_g = false,
        cell_modal = nil,
    }
end

function M.reset(view)
    view.page = 1
    view.sort_col = nil
    view.sort_asc = true
    view.filter = ""
    view.col_offset = 0
    view.select_row = 1
    view.select_col = 1
    view.filter_mode = false
    view.filter_buffer = ""
    view.pending_g = false
    view.cell_modal = nil
end

function M.format_cell(value)
    if value == nil or (type(value) == "table" and value.is_null) then
        return "NULL"
    end
    if type(value) == "table" then
        local parts = {}
        for i = 1, #value do
            parts[i] = string.format("%02x", value[i] or 0)
        end
        return table.concat(parts)
    end
    return tostring(value)
end

local function row_matches(row, columns, filter)
    if filter == "" then return true end
    local lower = filter:lower()
    for i = 1, #columns do
        if M.format_cell(row[i]):lower():find(lower, 1, true) then
            return true
        end
    end
    return false
end

function M.filtered_rows(result, view)
    local rows = result and result.rows or {}
    if view.filter == "" then return rows end
    local out = {}
    for _, row in ipairs(rows) do
        if row_matches(row, result.columns or {}, view.filter) then
            table.insert(out, row)
        end
    end
    return out
end

function M.sorted_rows(rows, columns, view)
    if not view.sort_col or view.sort_col < 1 or view.sort_col > #columns then
        return rows
    end
    local col = view.sort_col
    local copy = {}
    for i, row in ipairs(rows) do copy[i] = row end
    table.sort(copy, function(a, b)
        local av, bv = a[col], b[col]
        local anil = av == nil or (type(av) == "table" and av.is_null)
        local bnil = bv == nil or (type(bv) == "table" and bv.is_null)
        if anil and bnil then return false end
        if anil then return not view.sort_asc end
        if bnil then return view.sort_asc end
        local as, bs = M.format_cell(av), M.format_cell(bv)
        if as == bs then return false end
        if view.sort_asc then return as < bs else return as > bs end
    end)
    return copy
end

function M.prepare(result, view)
    if not result or not result.columns then
        return nil
    end

    local rows = M.sorted_rows(M.filtered_rows(result, view), result.columns, view)
    local total = #rows
    local pages = math.max(1, math.ceil(total / view.page_size))
    if view.page > pages then view.page = pages end
    if view.page < 1 then view.page = 1 end
    if view.select_row < 0 then view.select_row = 0 end
    if view.select_row > total then view.select_row = total end
    if view.select_col < 1 then view.select_col = 1 end
    if view.select_col > #result.columns then view.select_col = #result.columns end

    local start = (view.page - 1) * view.page_size + 1
    local page_rows = {}
    for i = start, math.min(start + view.page_size - 1, total) do
        page_rows[#page_rows + 1] = rows[i]
    end

    return {
        columns = result.columns,
        rows = page_rows,
        all_rows = rows,
        total_rows = total,
        total_pages = pages,
        page_start = start,
        truncated = result.truncated,
        row_count = result.row_count,
        error = result.error,
    }
end

function M.toggle_sort(view, col_index)
    if view.sort_col == col_index then
        view.sort_asc = not view.sort_asc
    else
        view.sort_col = col_index
        view.sort_asc = true
    end
end

function M.go_first(view)
    view.page = 1
    view.select_row = 0
end

function M.go_last(view, total_rows, page_size)
    view.page = math.max(1, math.ceil(total_rows / page_size))
    view.select_row = total_rows
end

function M.page_info(view, prepared)
    if not prepared then return nil end
    return string.format("Page %d/%d", view.page, prepared.total_pages)
end

return M
