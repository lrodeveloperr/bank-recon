# Bank Reconciliation: CSV — App Candidate

This repository contains the deterministic local-first Swift engine and shared SwiftUI app layer for the locked WorksBien product specification in `docs/PRODUCT_SPEC.md`.

## What is executable in this checkpoint

- Exact fixed-point amounts with bounded parsing and checked arithmetic.
- Strict CSV/TSV and XLSX parsing with replayable mappings, exact dates, bounded archive expansion and source locators.
- OFX/QFX/QBO (XML and SGML), QIF/QMTF, CAMT.053/054, MT940 and BAI2 adapters with format-specific integrity checks.
- Mode A (bank vs ledger), Mode B (older vs newer export) and Mode C (single-statement proof).
- Conservative strong-ID and exact-composite matching, controlled mutual-best fuzzy matching, and bounded split/merge candidate detection. Ambiguity fails closed.
- Deterministic exception ordering, result states and canonical JSON evidence manifests.
- Immutable lock envelopes that bind source hashes, replay descriptors, normalized sources and the reconciliation result.
- Atomic file persistence with optimistic revision checks, a fixed-size Keychain-backed head/receipt anchor, recoverable two-phase commits and fail-closed tail-loss detection.
- An adaptive SwiftUI workflow for Mac, iPad and iPhone covering imports, previews, explanations, locks, source profiles, evidence packs and settings.
- StoreKit 2 non-consumable Pro and Accountant entitlements, dynamic App Store pricing, fresh verification and purchase restoration.
- A two-lock free allowance enforced only when a non-sample reconciliation is successfully committed.
- Bounded digest-verified local backup/restore that deliberately excludes App Store entitlement state.
- PDF, CSV and canonical JSON evidence exports with source proof, parser mappings, totals, exceptions, decisions and limitations.
- A portable Python reference oracle and static gate runnable without Xcode.
- A GitHub-hosted Apple gate that builds both the package and SwiftUI executable with warnings as errors and runs 40 Swift tests, the CLI fixture harness and the portable gates.

## Deliberate release blockers

The requested app, entitlement and product-infrastructure layers are implemented. Their automated Apple gate is green, including a real Keychain integration test and injected backup-recovery interruption. Signed StoreKit sandbox transactions, retained real-bank parser corpora and fuzzing, device UI/performance/export testing, native-language QA, an independent final review and product-owner acceptance remain open. The package is therefore still **PROVISIONAL / NOT ENGINE LOCKED**.

The authoritative Apple result is recorded in `verification/apple-gate-results.json`. To rerun it locally on a supported Mac:

```sh
swift test
swift run bank-reconcile verify-fixtures
```

The portable gate is:

```sh
python3 tools/reference_oracle.py
python3 tools/static_checks.py
python3 tools/validate_manifest.py
```

## Privacy and claims

The engine has no networking dependency and never modifies imported source files. An evidence pack proves only the supplied files and recorded decisions; it is not bank, accounting, tax, legal or audit assurance.
