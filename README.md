# Bank Reconciliation: CSV — Engine Candidate

This repository is a deterministic, local-first Swift engine candidate for the locked WorksBien product specification in `docs/PRODUCT_SPEC.md`.

## What is executable in this checkpoint

- Exact fixed-point amounts with bounded parsing and checked arithmetic.
- Strict CSV/TSV parsing with replayable mappings, exact dates, record/field limits and source locators.
- Mode A (bank vs ledger), Mode B (older vs newer export) and Mode C (single-statement proof).
- Conservative strong-ID and exact-composite matching. Ambiguity fails closed.
- Deterministic exception ordering, result states and canonical JSON evidence manifests.
- Immutable lock envelopes that bind source hashes, replay descriptors, normalized sources and the reconciliation result.
- Atomic file persistence with optimistic revision checks, a fixed-size Keychain-backed head/receipt anchor, recoverable two-phase commits and fail-closed tail-loss detection.
- A portable Python reference oracle and static gate runnable without Xcode.

## Deliberate release blockers

The product specification requires XLSX, OFX/QFX/QBO, QIF/QMTF, CAMT.053/054, MT940 and BAI2 adapters. Those adapters, Apple StoreKit verification, PDF/CSV evidence rendering, backup/restore hardening, device performance gates and native-language QA are contractually represented but are **not implemented in this recovery checkpoint**. The package is therefore **PROVISIONAL / NOT ENGINE LOCKED**.

This environment has no Swift or Xcode toolchain, so the package has not been compiled here. Run the Apple gate before relying on it:

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
