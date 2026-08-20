-- src/sql/parse.lua — shared SQL parser module
-- Streaming state machine for statement splitting, classification, and syntax highlighting.
-- This is the sole authority on statement boundaries and statement classification.

local M = {}

-- Tokenizer states
M.STATE_NORMAL        = 1
M.STATE_SINGLE_QUOTE  = 2
M.STATE_DOUBLE_QUOTE  = 3
M.STATE_BACKTICK      = 4
M.STATE_DOLLAR_QUOTE  = 5
M.STATE_LINE_COMMENT  = 6
M.STATE_BLOCK_COMMENT = 7

-- Statement types
M.TYPE_SELECT   = "select"
M.TYPE_INSERT   = "insert"
M.TYPE_UPDATE   = "update"
M.TYPE_DELETE   = "delete"
M.TYPE_DROP     = "drop"
M.TYPE_CREATE   = "create"
M.TYPE_ALTER    = "alter"
M.TYPE_TRUNCATE = "truncate"
M.TYPE_REPLACE  = "replace"
M.TYPE_MERGE    = "merge"
M.TYPE_EXPLAIN  = "explain"
M.TYPE_SHOW     = "show"
M.TYPE_DESCRIBE = "describe"
M.TYPE_PRAGMA   = "pragma"
M.TYPE_SET      = "set"
M.TYPE_WITH     = "with"
M.TYPE_OTHER    = "other"

-- Blocked keywords for read-only enforcement
M.BLOCKED_KEYWORDS = {
    "INSERT", "UPDATE", "DELETE", "DROP", "TRUNCATE",
    "ALTER", "CREATE", "REPLACE", "MERGE",
}

-- Allow-list keywords for read-only
M.ALLOWED_KEYWORDS = {
    "SELECT", "EXPLAIN", "SHOW", "DESCRIBE", "DESC", "PRAGMA", "SET",
}

-- Create a new tokenizer state machine.
-- Returns an object with methods for processing characters.
function M.new_tokenizer()
    local self = {
        state = M.STATE_NORMAL,
        pos = 0,           -- current byte position
        dollar_tag = nil,  -- the dollar-quote tag we're looking for
    }

    -- Process a single character. Returns true if this char is a statement boundary (;).
    function self:process_char(ch, byte_pos)
        self.pos = byte_pos

        if self.state == M.STATE_NORMAL then
            if ch == "'" then
                self.state = M.STATE_SINGLE_QUOTE
            elseif ch == '"' then
                self.state = M.STATE_DOUBLE_QUOTE
            elseif ch == '`' then
                self.state = M.STATE_BACKTICK
            elseif ch == '-' then
                -- Peek: is next char also '-'?
                -- We handle this at the string level, not char level
                -- For now, we'll handle -- detection in the string scanner
            elseif ch == '/' then
                -- Peek: is next char '*'?
                -- Same: handled at string level
            elseif ch == '$' then
                -- Dollar-quote start: need to capture the tag
                -- Handled at string level
            elseif ch == ';' then
                return true  -- statement boundary
            end
        elseif self.state == M.STATE_SINGLE_QUOTE then
            if ch == "'" then
                -- Check for escaped single-quote (doubled)
                -- This is handled at string level
                self.state = M.STATE_NORMAL
            end
        elseif self.state == M.STATE_DOUBLE_QUOTE then
            if ch == '"' then
                -- Check for escaped double-quote
                -- Handled at string level
                self.state = M.STATE_NORMAL
            end
        elseif self.state == M.STATE_BACKTICK then
            if ch == '`' then
                self.state = M.STATE_NORMAL
            end
        elseif self.state == M.STATE_DOLLAR_QUOTE then
            if ch == '$' then
                -- Check if we're closing the dollar quote
                -- Handled at string level
            end
        elseif self.state == M.STATE_LINE_COMMENT then
            if ch == '\n' then
                self.state = M.STATE_NORMAL
            end
        elseif self.state == M.STATE_BLOCK_COMMENT then
            if ch == '*' then
                -- Check if next char is '/'
                -- Handled at string level
            end
        end
        return false
    end

    return self
end

-- Split a buffer text into statements.
-- Returns an array of { text = "...", start_pos = N, end_pos = N }.
-- This is the sole authority on statement boundaries.
function M.split_statements(buffer_text)
    if not buffer_text or buffer_text == "" then
        return {}
    end

    local statements = {}
    local tok = M.new_tokenizer()
    local stmt_start = 1
    local i = 1
    local len = #buffer_text

    while i <= len do
        local ch = buffer_text:sub(i, i)

        if tok.state == M.STATE_NORMAL then
            if ch == "'" then
                tok.state = M.STATE_SINGLE_QUOTE
                i = i + 1
            elseif ch == '"' then
                tok.state = M.STATE_DOUBLE_QUOTE
                i = i + 1
            elseif ch == '`' then
                tok.state = M.STATE_BACKTICK
                i = i + 1
            elseif ch == '-' and i + 1 <= len and buffer_text:sub(i + 1, i + 1) == '-' then
                tok.state = M.STATE_LINE_COMMENT
                i = i + 2
            elseif ch == '/' and i + 1 <= len and buffer_text:sub(i + 1, i + 1) == '*' then
                tok.state = M.STATE_BLOCK_COMMENT
                i = i + 2
            elseif ch == '$' then
                -- Dollar-quote: capture the tag
                local tag_end = buffer_text:find("$", i + 1, true)
                if tag_end then
                    local tag = buffer_text:sub(i, tag_end)
                    -- Verify it's a valid dollar-quote tag (starts and ends with $)
                    if tag:match("^%$[%w_]*%$$") then
                        tok.dollar_tag = tag
                        tok.state = M.STATE_DOLLAR_QUOTE
                        i = tag_end + 1
                    else
                        i = i + 1
                    end
                else
                    i = i + 1
                end
            elseif ch == ';' then
                -- Statement boundary
                local stmt_text = buffer_text:sub(stmt_start, i - 1)
                -- Trim whitespace
                local trimmed = stmt_text:match("^%s*(.-)%s*$")
                if trimmed and trimmed ~= "" then
                    table.insert(statements, {
                        text = trimmed,
                        start_pos = stmt_start,
                        end_pos = i - 1,
                    })
                end
                stmt_start = i + 1
                i = i + 1
            else
                i = i + 1
            end

        elseif tok.state == M.STATE_SINGLE_QUOTE then
            if ch == "'" then
                -- Check for escaped single-quote (doubled '')
                if i + 1 <= len and buffer_text:sub(i + 1, i + 1) == "'" then
                    i = i + 2  -- skip both quotes
                else
                    tok.state = M.STATE_NORMAL
                    i = i + 1
                end
            elseif ch == '\\' then
                -- Backslash escape (Postgres-style)
                i = i + 2  -- skip escaped char
            else
                i = i + 1
            end

        elseif tok.state == M.STATE_DOUBLE_QUOTE then
            if ch == '"' then
                -- Check for escaped double-quote (doubled "")
                if i + 1 <= len and buffer_text:sub(i + 1, i + 1) == '"' then
                    i = i + 2
                else
                    tok.state = M.STATE_NORMAL
                    i = i + 1
                end
            elseif ch == '\\' then
                i = i + 2
            else
                i = i + 1
            end

        elseif tok.state == M.STATE_BACKTICK then
            if ch == '`' then
                tok.state = M.STATE_NORMAL
            end
            i = i + 1

        elseif tok.state == M.STATE_DOLLAR_QUOTE then
            if ch == '$' then
                -- Check if we're closing the dollar quote with the same tag
                local remaining = buffer_text:sub(i)
                local tag_len = #tok.dollar_tag
                if remaining:sub(1, tag_len) == tok.dollar_tag then
                    tok.state = M.STATE_NORMAL
                    tok.dollar_tag = nil
                    i = i + tag_len
                else
                    i = i + 1
                end
            else
                i = i + 1
            end

        elseif tok.state == M.STATE_LINE_COMMENT then
            if ch == '\n' then
                tok.state = M.STATE_NORMAL
            end
            i = i + 1

        elseif tok.state == M.STATE_BLOCK_COMMENT then
            if ch == '*' and i + 1 <= len and buffer_text:sub(i + 1, i + 1) == '/' then
                tok.state = M.STATE_NORMAL
                i = i + 2
            else
                i = i + 1
            end
        end
    end

    -- Handle remaining text (no trailing semicolon)
    if stmt_start <= len then
        local stmt_text = buffer_text:sub(stmt_start)
        local trimmed = stmt_text:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            table.insert(statements, {
                text = trimmed,
                start_pos = stmt_start,
                end_pos = len,
            })
        end
    end

    return statements
end

-- Classify a pre-split statement.
-- Returns { type = "...", keyword = "...", blocked_keyword = "..." or nil }.
-- This receives only the output of split_statements(), never raw buffer text.
function M.classify_statement(sql_text)
    if not sql_text or sql_text == "" then
        return { type = M.TYPE_OTHER, keyword = nil, blocked_keyword = nil }
    end

    -- Tokenize the statement to find keywords
    -- We need to scan for keywords outside of strings and comments
    local tokens = M._tokenize_for_classification(sql_text)
    if #tokens == 0 then
        return { type = M.TYPE_OTHER, keyword = nil, blocked_keyword = nil }
    end

    -- Get the leading keyword
    local leading = tokens[1]:upper()
    local stmt_type = M.TYPE_OTHER

    if leading == "SELECT" then
        stmt_type = M.TYPE_SELECT
    elseif leading == "INSERT" then
        stmt_type = M.TYPE_INSERT
    elseif leading == "UPDATE" then
        stmt_type = M.TYPE_UPDATE
    elseif leading == "DELETE" then
        stmt_type = M.TYPE_DELETE
    elseif leading == "DROP" then
        stmt_type = M.TYPE_DROP
    elseif leading == "CREATE" then
        stmt_type = M.TYPE_CREATE
    elseif leading == "ALTER" then
        stmt_type = M.TYPE_ALTER
    elseif leading == "TRUNCATE" then
        stmt_type = M.TYPE_TRUNCATE
    elseif leading == "REPLACE" then
        stmt_type = M.TYPE_REPLACE
    elseif leading == "MERGE" then
        stmt_type = M.TYPE_MERGE
    elseif leading == "EXPLAIN" then
        stmt_type = M.TYPE_EXPLAIN
    elseif leading == "SHOW" then
        stmt_type = M.TYPE_SHOW
    elseif leading == "DESCRIBE" or leading == "DESC" then
        stmt_type = M.TYPE_DESCRIBE
    elseif leading == "PRAGMA" then
        stmt_type = M.TYPE_PRAGMA
    elseif leading == "SET" then
        stmt_type = M.TYPE_SET
    elseif leading == "WITH" then
        stmt_type = M.TYPE_WITH
    end

    -- Scan for blocked keywords anywhere in the tokenized statement
    local blocked_keyword = nil
    for _, token in ipairs(tokens) do
        local upper = token:upper()
        for _, blocked in ipairs(M.BLOCKED_KEYWORDS) do
            if upper == blocked then
                blocked_keyword = blocked
                break
            end
        end
        if blocked_keyword then break end
    end

    return {
        type = stmt_type,
        keyword = leading,
        blocked_keyword = blocked_keyword,
    }
end

-- Internal: tokenize a statement for classification.
-- Returns an array of keyword tokens (strings and comments are stripped).
function M._tokenize_for_classification(sql_text)
    local tokens = {}
    local i = 1
    local len = #sql_text
    local current_token = ""

    while i <= len do
        local ch = sql_text:sub(i, i)

        if ch == "'" then
            -- Single-quoted string: skip to closing quote
            i = i + 1
            while i <= len do
                if sql_text:sub(i, i) == "'" then
                    if i + 1 <= len and sql_text:sub(i + 1, i + 1) == "'" then
                        i = i + 2  -- escaped quote
                    else
                        i = i + 1
                        break
                    end
                elseif sql_text:sub(i, i) == '\\' then
                    i = i + 2
                else
                    i = i + 1
                end
            end

        elseif ch == '"' then
            -- Double-quoted identifier: skip to closing quote
            i = i + 1
            while i <= len do
                if sql_text:sub(i, i) == '"' then
                    if i + 1 <= len and sql_text:sub(i + 1, i + 1) == '"' then
                        i = i + 2
                    else
                        i = i + 1
                        break
                    end
                else
                    i = i + 1
                end
            end

        elseif ch == '`' then
            -- Backtick-quoted identifier: skip to closing backtick
            i = i + 1
            while i <= len do
                if sql_text:sub(i, i) == '`' then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end

        elseif ch == '-' and i + 1 <= len and sql_text:sub(i + 1, i + 1) == '-' then
            -- Line comment: skip to newline
            i = i + 2
            while i <= len and sql_text:sub(i, i) ~= '\n' do
                i = i + 1
            end

        elseif ch == '/' and i + 1 <= len and sql_text:sub(i + 1, i + 1) == '*' then
            -- Block comment: skip to */
            i = i + 2
            while i <= len do
                if sql_text:sub(i, i) == '*' and i + 1 <= len and sql_text:sub(i + 1, i + 1) == '/' then
                    i = i + 2
                    break
                else
                    i = i + 1
                end
            end

        elseif ch == '$' then
            -- Dollar-quote: skip to closing tag
            local tag_end = sql_text:find("$", i + 1, true)
            if tag_end then
                local tag = sql_text:sub(i, tag_end)
                if tag:match("^%$[%w_]*%$$") then
                    -- Find closing tag
                    local close_start = sql_text:find(tag, tag_end + 1, true)
                    if close_start then
                        i = close_start + #tag
                    else
                        i = tag_end + 1
                    end
                else
                    -- Not a dollar quote, treat as regular char
                    if current_token ~= "" then
                        table.insert(tokens, current_token)
                        current_token = ""
                    end
                    i = i + 1
                end
            else
                if current_token ~= "" then
                    table.insert(tokens, current_token)
                    current_token = ""
                end
                i = i + 1
            end

        elseif ch:match("[%w_]") then
            -- Part of a word
            current_token = current_token .. ch
            i = i + 1

        else
            -- Whitespace or other separator
            if current_token ~= "" then
                table.insert(tokens, current_token)
                current_token = ""
            end
            i = i + 1
        end
    end

    if current_token ~= "" then
        table.insert(tokens, current_token)
    end

    return tokens
end

-- Check if a statement is read-only (no blocked keywords).
-- Returns true if safe, false if blocked.
function M.is_read_only(sql_text)
    local classification = M.classify_statement(sql_text)
    return classification.blocked_keyword == nil
end

-- Get the statement type as a string.
function M.get_type(sql_text)
    local classification = M.classify_statement(sql_text)
    return classification.type
end

return M
