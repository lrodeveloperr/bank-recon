# Final Source Audit — Recovery Candidate

**Audit date:** 2026-09-22  
**Scope:** frozen Swift package, limited to the implemented CSV/TSV recovery scope  
**Verdict:** **REJECT / REMAIN PROVISIONAL — CRITICAL AND HIGH DEFECTS OPEN**

This was an independent source audit. No implementation source was changed. The environment has no `swift` or `swiftc`, so this report does not claim compilation, XCTest execution, CLI execution, or Apple-platform validation.

## Frozen payload identity

The pre-audit payload contains 39 files, excluding this report. Its aggregate SHA-256 is:

`39f17652d96f8da763c11bfa08904f0a1d946d1f45dc8c587b1cc83b3b9dfa59`

Method: sort all pre-audit relative file paths bytewise; for each file emit the lowercase file SHA-256, two spaces, the relative path, and LF; hash the resulting 39-line UTF-8 manifest with SHA-256. This identity is independent of the stale `verification/SHA256SUMS.txt` discussed below.

## Critical

### C-01 — Ordinary CRLF CSV/TSV can be collapsed into a header-only source and falsely reconcile

`DelimitedParser.tokenize` iterates a Swift `String` by `Character` (`DelimitedParser.swift:178-223`) and compares each element separately with `"\r"` and `"\n"`. Swift `Character` is an extended grapheme cluster; the Unicode CR+LF pair is one character. Consequently, a normal Windows line ending does not enter either row-ending branch and is appended to the current field.

Concrete reproduction: parse a header-bearing source such as `date,amount,account,currency\r\n2026-01-01,1,A,USD\r\n` with `hasHeader == true`. Tokenization produces one enlarged row. `parse` then treats that sole row as the header (`DelimitedParser.swift:62`), obtains an empty `dataRows`, and returns a complete statement with zero transactions. Two populated CRLF sources can therefore reach `ReconciliationEngine.compare` with no transactions, no totals, and no exceptions; `resultState` returns `.reconciled` (`Reconciliation.swift:168-178`, `379-384`). Evidence replay reproduces the same bad parse, so locking does not detect it.

Impact: common valid CSV/TSV input can produce a false green financial result while silently omitting every source record. This is a critical correctness and evidence defect.

Required correction: tokenize by UTF-8 byte or Unicode scalar with explicit CR, LF, and CRLF handling; add retained CRLF/LF/CR fixtures, quoted multiline fixtures, and a gate that a nonempty physical data section cannot disappear.

## High

### H-01 — Delimiter-built matching keys permit automatic cross-account matches

Strong and composite identities are encoded as unescaped `|`-joined strings (`Reconciliation.swift:181-189`), and automatic matching trusts key equality without rechecking the partitions (`Reconciliation.swift:111-119`, `133-142`). Account, strong-ID, and reference values are unrestricted strings, so different structured identities can collide.

Concrete strong-key collision:

- left: account `A|USD`, currency `USD`, strong ID `X`;
- right: account `A`, currency `USD`, strong ID `USD|X`.

Both encode as `A|USD|USD|X` and are automatically matched despite different accounts. Reciprocal colliding pairs can make per-partition totals close; after approving the resulting metadata-change exceptions, the job can become `.reconciledWithExplanations` without ever reporting the cross-account match. This violates the locked rule that cross-partition matches are forbidden.

Required correction: use structured `Hashable` key types (partition plus identifier/date/amount/reference), and assert `partition(lhs) == partition(rhs)` immediately before every automatic match. Add adversarial separator/control-character tests.

### H-02 — Evidence-lockable CSV/TSV Mode C can never produce a positive statement proof

The CSV/TSV parser always creates `SourceStatement` with its default empty `balances` array (`DelimitedParser.swift:131-137`); the mapping has no opening/closing balance representation. Single-statement execution treats empty balances as inconclusive (`Reconciliation.swift:60-70`) and also produces a period-gap exception for transaction partitions lacking exactly one opening and closing balance (`306-340`). Therefore a source created by the only implemented adapter can never reach `.reconciled` in Mode C.

The passing balance-only unit test constructs `SourceStatement` directly and supplies balances, but its replay descriptor has no delimited mapping (`ReconciliationTests.swift:42-60`). Such a statement cannot be evidence-locked: `EvidenceLocker.lock` reparses bytes and requires the replayed statement to equal the supplied one (`Evidence.swift:71-80`), while `FormatRouter` requires the missing mapping (`DelimitedParser.swift:273-276`).

Impact: the package and manifest claim all three modes in source, but Mode C is not end-to-end implementable or lockable for CSV/TSV.

Required correction: either add replay-bound opening/closing balance inputs to the delimited adapter and evidence model, or mark Mode C as unimplemented. Add a test that parses real bytes, runs Mode C, locks, reloads, and fully verifies evidence.

### H-03 — Snapshot-chain tail deletion rolls back a lock and resets free usage

The predecessor hash authenticates backward only. No durable head, tombstone, monotonic receipt ledger, or external anchor records the latest revision. `validatedHistory` accepts whatever contiguous prefix remains (`Store.swift:195-243`), and `countedRealLocks` derives usage solely from the latest surviving records (`Store.swift:186-188`, `246-265`).

Concrete reproduction: create revision 1 draft, commit revision 2 locked, then remove `revision-00000002.json`. On the next load, revision 1 is a valid complete history and is again treated as the current draft. The real-lock count falls by one, and the draft can be updated and locked again. Removing the job directory resets the count entirely. The same truncation also defeats the claimed immutability of a locked reconciliation.

Impact: append-only behavior is enforced only through the API, not by the persisted format; local deletion, incomplete restore, or tail loss silently revives mutable state and restores free locks.

Required correction: add a separately durable monotonic head/receipt log whose loss or rollback fails closed, bind sample status and receipts to it, and test tail deletion, directory deletion, partial restore, and crash recovery. StoreKit/restore work may supply part of the eventual trust anchor, but the current source claim must not say “lock receipt ledger.”

### H-04 — The supplied checksum manifest does not identify the frozen candidate

Fresh `sha256sum -c verification/SHA256SUMS.txt` reports 12 failures: five engine sources, four tests, `tools/reference_oracle.py`, `verification/portable-gate-results.json`, and the checksum file itself. The manifest also omits six present files: `docs/CODE_BREAKER_DISPOSITION.md`, `docs/CUSTOMER_STRESS_TEST.md`, `docs/FORMAT_PROFILES.md`, `verification/APPLE_GATE_RESULT_TEMPLATE.json`, `verification/EXTERNAL_AI_REVIEW_REQUEST.md`, and `verification/SBOM.json`. Including the checksum file's own digest creates an intrinsically unstable self-reference.

Impact: the purported frozen artifact cannot be authenticated by its shipped integrity manifest, and the portable PASS results are not bound to the audited source snapshot.

Required correction: after all source and report generation is complete, generate a complete non-self-referential manifest (or externally signed manifest), verify it from a clean copy, and bind the Apple-gate result to the same aggregate identity.

## Medium observations

- `EvidenceLocker.validateTimestamp` checks only an RFC-3339-shaped regular expression (`Evidence.swift:199-205`). It accepts impossible values such as `2026-99-99T99:99:99Z`, and the API accepts an arbitrary caller-supplied lock time. Evidence consumers must not treat `lockedAt` as a validated instant until exact calendar/time parsing and clock provenance are defined.
- The “exact composite” key lowercases references (`Reconciliation.swift:186-189`). This is not exact equality as specified. The later mutation exception prevents a silent clean result in the simple case, but matching semantics and naming are inconsistent.
- A CR-only newline inside a quoted field is not counted as a source line (`DelimitedParser.swift:190-193`), so later line locators can be wrong even after the CRLF defect is repaired unless all newline forms are handled explicitly.

## Portable gate confirmation

The three portable generators were run afresh and each emitted `PASS`:

| Report | Fresh result | What it establishes |
|---|---:|---|
| `portable-gate-results.json` | 550,002 checks; seed 739,996 | Python reference invariants for bounded amount examples, simplified matching, lifecycle simulation, and JSON key ordering |
| `static-gate-results.json` | 8 named checks true | Presence/absence and token-pattern checks over source |
| `manifest-gate-results.json` | 30 requirements: 15 source-uncompiled, 3 portable-tested, 12 planned blockers | Manifest shape, unique IDs, allowed status values, and counts |

These are portable script results only. They do not execute Swift, parse CRLF with Swift `Character`, exercise the real matching key encoding, execute the real file store, or establish an Apple build. The static gate's PASS is therefore compatible with C-01 and H-01 through H-03. The separate shipped checksum verification fails as described in H-04.

## Controls reviewed without an additional critical/high static finding

- `ExactAmount` normalizes scale, bounds input and decoded scale, uses reporting-overflow arithmetic, and handles `Int64.min` without unary-negation overflow. `LocalDate` enforces fixed-width ISO input and reconstructs exact Gregorian components. Runtime confirmation still requires Swift tests.
- Role counts/order, selected-period equality, transaction provenance, unique locators/ordinals, and manual-match transaction fingerprints fail closed in the reviewed paths.
- The full evidence path used by `commitLock` binds the supplied job and result hashes, retained byte hashes/sizes, parser replay, normalized statements, and engine rerun. The CRLF parser defect means a reproducible parse is not necessarily a correct parse.
- Cooperative store actors/processes use one root `flock`, revision filenames are contiguous, and revisions after a surviving locked revision are rejected. H-03 remains because the latest revision itself is not durably anchored.
- The built-in sample exemption is checked against the fixed sample job and a surviving sample draft cannot be mutated through `updateDraft`. Persisted-history truncation/forgery and restore handling remain unresolved.

## Release verdict

Do not promote this candidate, describe it as engine-locked, or rely on its evidence for reconciliation decisions. C-01 must be fixed before any CSV/TSV result is trusted. H-01 through H-04 must also be closed, targeted Swift tests added, and the package compiled and tested with current Swift 6/Xcode on the declared Apple platforms. The already-declared non-CSV adapter, StoreKit, backup/restore, report-rendering, localization, device-performance, and Apple gates remain separate blockers.
