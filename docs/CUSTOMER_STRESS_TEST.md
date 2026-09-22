# Simulated Long-Term Customer Stress Test

This is a model-based engineering stress exercise, not customer research.

## Workflows exercised

1. A bookkeeper repeatedly previews failed mappings; no usage is consumed because only `commitLock` creates a receipt.
2. A controller revisits a locked month; append-only history rejects every later mutation.
3. Two processes try to update the same root; the advisory root lock serializes revision checks and writes.
4. A ledger row changes after a manual match; bound row fingerprints make the match stale.
5. Two currencies share dates and references; account/currency partitioning prevents cross-netting.
6. A source is changed after preview; lock reparses the exact hashed bytes and compares the full normalized statement.
7. A balance-only month has one opening and closing balance; Mode C permits zero activity and checks equality.
8. A user explains exceptions whose totals do not close; state remains `differenceFound`.

## Portable lifecycle run

The deterministic oracle executes 250,000 draft/update/lock lifecycle events and checks that a locked job never changes and every counted lock has one unique receipt. Together with arithmetic, matching and canonicalization, the current portable run contains 550,002 checks. This does not replace Swift, crash-injection, StoreKit, device or parser-corpus testing.

## Long-term gaps

Archive backup/restore, StoreKit refresh, evidence rendering, parser corpus/fuzzing, native-language QA, independent review, user acceptance and hardware performance remain release blockers. Those gaps prevent an engine-lock claim.
