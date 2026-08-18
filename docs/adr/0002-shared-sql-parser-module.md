# Single shared SQL parser module for splitting, classification, and highlighting

Statement splitting, read-only classification, and syntax highlighting all need to skip over string literals and comments to find statement boundaries and keywords. Implemented as separate modules, they diverge — the splitter and the classifier will disagree on where a Statement ends, silently breaking read-only enforcement.

Decision: one module, `src/utils/sql_parse.lua`, with a streaming state machine that tracks single-quoted strings, double-quoted identifiers, backtick-quoted identifiers (MySQL), Postgres dollar-quoting (`$tag$...$tag$`), line comments (`--`), block comments (`/* */`, non-nested — nested comments documented as a known limitation for MVP), and semicolons as boundaries only outside those contexts.

Exposes three consumers:
- `split_statements(buffer_text) → Statement[]` — used by the Execution loop
- `classify_statement(sql) → { type, keyword }` — used by read-only enforcement; receives pre-split text
- Tokenizer for `syntax.lua` — reuses the same state machine for highlighting

The splitter is the authority on boundaries. The classifier only receives pre-split Statements, making cross-boundary classification structurally impossible.
