-- src/utils/syntax.lua — SQL syntax highlighting
-- Reuses the tokenizer from sql.parse for keyword/string/comment detection.

local M = {}

-- Token types for highlighting
local TOKEN_KEYWORD   = 1
local TOKEN_STRING    = 2
local TOKEN_COMMENT   = 3
local TOKEN_NUMBER    = 4
local TOKEN_OPERATOR  = 5
local TOKEN_PAREN     = 6
local TOKEN_DEFAULT   = 7

M.TOKEN_KEYWORD  = TOKEN_KEYWORD
M.TOKEN_STRING   = TOKEN_STRING
M.TOKEN_COMMENT  = TOKEN_COMMENT
M.TOKEN_NUMBER   = TOKEN_NUMBER
M.TOKEN_OPERATOR = TOKEN_OPERATOR
M.TOKEN_PAREN    = TOKEN_PAREN
M.TOKEN_DEFAULT  = TOKEN_DEFAULT

-- SQL keywords (for highlighting — not the same as classification keywords)
local KEYWORDS = {
    ["SELECT"] = true, ["FROM"] = true, ["WHERE"] = true, ["AND"] = true,
    ["OR"] = true, ["NOT"] = true, ["IN"] = true, ["IS"] = true,
    ["NULL"] = true, ["AS"] = true, ["ON"] = true, ["JOIN"] = true,
    ["LEFT"] = true, ["RIGHT"] = true, ["INNER"] = true, ["OUTER"] = true,
    ["CROSS"] = true, ["FULL"] = true, ["GROUP"] = true, ["BY"] = true,
    ["ORDER"] = true, ["ASC"] = true, ["DESC"] = true, ["HAVING"] = true,
    ["LIMIT"] = true, ["OFFSET"] = true, ["UNION"] = true, ["ALL"] = true,
    ["INSERT"] = true, ["INTO"] = true, ["VALUES"] = true, ["UPDATE"] = true,
    ["SET"] = true, ["DELETE"] = true, ["CREATE"] = true, ["TABLE"] = true,
    ["ALTER"] = true, ["DROP"] = true, ["INDEX"] = true, ["VIEW"] = true,
    ["TRIGGER"] = true, ["IF"] = true, ["EXISTS"] = true, ["NOT"] = true,
    ["PRIMARY"] = true, ["KEY"] = true, ["FOREIGN"] = true, ["REFERENCES"] = true,
    ["DEFAULT"] = true, ["AUTOINCREMENT"] = true, ["UNIQUE"] = true,
    ["CHECK"] = true, ["CONSTRAINT"] = true, ["ADD"] = true, ["COLUMN"] = true,
    ["RENAME"] = true, ["TO"] = true, ["EXPLAIN"] = true, ["SHOW"] = true,
    ["DESCRIBE"] = true, ["PRAGMA"] = true, ["BEGIN"] = true, ["COMMIT"] = true,
    ["ROLLBACK"] = true, ["TRANSACTION"] = true, ["WITH"] = true, ["RECURSIVE"] = true,
    ["CASE"] = true, ["WHEN"] = true, ["THEN"] = true, ["ELSE"] = true,
    ["END"] = true, ["BETWEEN"] = true, ["LIKE"] = true, ["GLOB"] = true,
    ["REGEXP"] = true, ["MATCH"] = true, ["ESCAPE"] = true, ["CAST"] = true,
    ["DISTINCT"] = true, ["TOP"] = true, ["FETCH"] = true, ["NEXT"] = true,
    ["ROWS"] = true, ["ONLY"] = true, ["FIRST"] = true, ["LAST"] = true,
    ["RETURNING"] = true, ["REPLACE"] = true, ["TRUNCATE"] = true, ["MERGE"] = true,
    ["INTO"] = true, ["USING"] = true, ["WHEN"] = true, ["MATCHED"] = true,
    ["EXCLUDE"] = true, ["CURRENT"] = true, ["ROW"] = true, ["OVER"] = true,
    ["PARTITION"] = true, ["RANGE"] = true, ["PRECEDING"] = true, ["FOLLOWING"] = true,
    ["UNBOUNDED"] = true, ["UNION"] = true, ["INTERSECT"] = true, ["EXCEPT"] = true,
    ["TEMP"] = true, ["TEMPORARY"] = true, ["REPLACE"] = true, ["WITHOUT"] = true,
    ["ROWID"] = true, ["STRICT"] = true, ["GENERATED"] = true, ["ALWAYS"] = true,
    ["STORED"] = true, ["VIRTUAL"] = true, ["COLLATE"] = true, ["NOCASE"] = true,
    ["BINARY"] = true, ["RTRIM"] = true,
}

-- Tokenize a line of SQL for highlighting.
-- Returns an array of { type = TOKEN_*, text = "..." }.
function M.tokenize_line(line)
    if not line or line == "" then
        return {}
    end

    local tokens = {}
    local i = 1
    local len = #line
    local current = ""
    local current_type = TOKEN_DEFAULT

    local function flush()
        if current ~= "" then
            table.insert(tokens, { type = current_type, text = current })
            current = ""
            current_type = TOKEN_DEFAULT
        end
    end

    while i <= len do
        local ch = line:sub(i, i)

        if ch == "'" then
            flush()
            -- Single-quoted string
            local start = i
            i = i + 1
            while i <= len do
                if line:sub(i, i) == "'" then
                    if i + 1 <= len and line:sub(i + 1, i + 1) == "'" then
                        i = i + 2
                    else
                        i = i + 1
                        break
                    end
                elseif line:sub(i, i) == '\\' then
                    i = i + 2
                else
                    i = i + 1
                end
            end
            table.insert(tokens, { type = TOKEN_STRING, text = line:sub(start, i - 1) })

        elseif ch == '"' then
            flush()
            -- Double-quoted identifier
            local start = i
            i = i + 1
            while i <= len do
                if line:sub(i, i) == '"' then
                    if i + 1 <= len and line:sub(i + 1, i + 1) == '"' then
                        i = i + 2
                    else
                        i = i + 1
                        break
                    end
                else
                    i = i + 1
                end
            end
            table.insert(tokens, { type = TOKEN_STRING, text = line:sub(start, i - 1) })

        elseif ch == '`' then
            flush()
            -- Backtick identifier
            local start = i
            i = i + 1
            while i <= len do
                if line:sub(i, i) == '`' then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            table.insert(tokens, { type = TOKEN_STRING, text = line:sub(start, i - 1) })

        elseif ch == '-' and i + 1 <= len and line:sub(i + 1, i + 1) == '-' then
            flush()
            -- Line comment
            table.insert(tokens, { type = TOKEN_COMMENT, text = line:sub(i) })
            i = len + 1

        elseif ch == '/' and i + 1 <= len and line:sub(i + 1, i + 1) == '*' then
            flush()
            -- Block comment (may span lines — highlight to end of line)
            local start = i
            local close = line:find("*/", i + 2, true)
            if close then
                i = close + 2
            else
                i = len + 1
            end
            table.insert(tokens, { type = TOKEN_COMMENT, text = line:sub(start, i - 1) })

        elseif ch:match("[%a_]") then
            -- Word: keyword or identifier
            local start = i
            while i <= len and line:sub(i, i):match("[%w_]") do
                i = i + 1
            end
            local word = line:sub(start, i - 1)
            if KEYWORDS[word:upper()] then
                table.insert(tokens, { type = TOKEN_KEYWORD, text = word })
            else
                table.insert(tokens, { type = TOKEN_DEFAULT, text = word })
            end

        elseif ch:match("[%d]") then
            -- Number
            local start = i
            while i <= len and line:sub(i, i):match("[%d%.]") do
                i = i + 1
            end
            table.insert(tokens, { type = TOKEN_NUMBER, text = line:sub(start, i - 1) })

        elseif ch:match("[%+%-%*%/%%%=<>!~%^&|]") then
            flush()
            table.insert(tokens, { type = TOKEN_OPERATOR, text = ch })
            i = i + 1

        elseif ch == '(' or ch == ')' then
            flush()
            table.insert(tokens, { type = TOKEN_PAREN, text = ch })
            i = i + 1

        else
            current = current .. ch
            i = i + 1
        end
    end

    flush()
    return tokens
end

return M
