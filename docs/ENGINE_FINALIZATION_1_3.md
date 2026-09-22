# Engine Finalization — Items 1 to 3

Date: 2026-09-22  
Decision: **implemented and Apple-tested; overall release remains blocked**

## 1. Apple compilation gate

The repository workflow resolves the Swift package, builds with warnings as errors, runs the complete XCTest suite in parallel, runs the CLI fixture harness, and executes the portable oracle/static/manifest gates on macOS 15 arm64. The exact run, commit and toolchain are captured in `verification/apple-gate-results.json`.

## 2. Controlled matching

- Strong identifiers remain the first automatic tier and are case-sensitive.
- Exact composite matching remains account/currency/date/amount scoped.
- Fuzzy matching has hard account, currency and exact-amount gates; bounded date distance; bounded candidate count and text length; an integer similarity threshold; and mutual-unique-best acceptance.
- Equal best scores fail closed as ambiguous candidates.
- Split/merge discovery checks bounded groups and a bounded total number of evaluations. It emits candidates rather than silently auto-matching many-to-one rows.
- The effective policy is part of the canonical evidence manifest.

## 3. Import adapters

| Family | Parser version | Implemented controls |
|---|---:|---|
| CSV / TSV | `delimited-2.0.0` | Strict quoting/width, byte-aware CRLF handling, replayable locale mapping, bounds |
| XLSX | `xlsx-1.0.0` | Bounded ZIP, path/link/duplicate/CRC checks, selected sheet binding, shared/inline strings, strict typed cells and styled dates |
| OFX / QFX / QBO | `ofx-1.0.0` | Declared-version XML/SGML split, bounded tree, entity decoding, statement envelopes, account/currency/FITID and ledger balance |
| QIF / QMTF | `qif-1.0.0` | Section/account state, strict `^` termination, locale-bound date/amount parsing and duplicate critical-field rejection |
| CAMT.053 / .054 | `camt-1.0.0` | Namespace/version allowlist for 001.02–001.08, per-amount currency, references/remittance, balances and notification-only state |
| MT940 | `mt940-1.0.0` | Required statement segments, continuation handling, balance partitions, reversal-aware debit/credit signs |
| BAI2 | `bai2-1.0.0` | Required record hierarchy, 88 continuations, currency minor units and literal record/count/control-total validation |

Every normalized source retains its parser version, replay profile, exact source proof and locators so evidence locking can reparse the original bytes and compare the complete normalized value.

## Remaining release blockers

- Retained real-bank parser corpus, malformed-input matrix and fuzzing.
- Signed StoreKit sandbox purchase, revocation and restore tests. The StoreKit 2 adapter and policy integration are implemented and Apple-compiled.
- Device/file-provider backup restore and golden visual evidence-export review. Archive integrity, entitlement exclusion, PDF/CSV/JSON rendering and injected recovery are Apple-tested.
- Multi-process kill-point campaigns and iPhone/iPad/Mac performance matrices. Real Keychain compare-and-swap is Apple-tested.
- Native review of all five UI languages.
- Independent code-breaker review of this expanded scope and product-owner acceptance.

These blockers are independent of items 1–3 and are intentionally preserved in the gate manifest.
