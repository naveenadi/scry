# Halt-on-first statement failure during Execution

When an Execution contains multiple Statements (multi-statement Buffer), halt at the first failed Statement. Surface Result sets for all Statements that succeeded before the failure, plus the error for the failed one. Remaining Statements are not executed.

The alternative (run-all, report-per-statement) was rejected because of transaction-interleaving risk: if a batch contains `BEGIN; ...; COMMIT` and a mid-batch Statement fails, the driver may or may not have opened a transaction, and continuing executes remaining Statements inside (or outside) that half-broken transaction. Different drivers handle this inconsistently. Halt-on-first avoids the problem entirely.

A `--continue-on-error` flag or per-Execution toggle can be added later once the UI supports multi-result-set display and transaction state awareness.
