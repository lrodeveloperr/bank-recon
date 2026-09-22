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
- An adaptive SwiftUI workflow for Mac, iPad and iPhone covering imports, previews, a synchronized two-column review, a persistent exception inspector, explanations, locks, evidence packs and settings.
- A complete source-profile editor and Accountant batch-folder workflow with deterministic `_bank`/`_ledger`, `_old`/`_new` and `_statement` pairing.
- StoreKit 2 non-consumable Pro and Accountant entitlements, dynamic App Store pricing, fresh verification and purchase restoration.
- A local StoreKit configuration with five product localizations and automated purchase, restore, refund, Ask to Buy and interrupted-purchase tests.
- A two-lock free allowance enforced only when a non-sample reconciliation is successfully committed.
- Bounded digest-verified local backup/restore that deliberately excludes App Store entitlement state.
- PDF, CSV and canonical JSON evidence exports with source proof, parser mappings, totals, exceptions, decisions and limitations.
- A portable Python reference oracle and static gate runnable without Xcode.
- A generated universal Xcode project for iOS 18, iPadOS 18 and macOS 15 with a privacy manifest, complete app-icon catalog, Mac sandbox entitlements and unsigned archive validation.
- A GitHub-hosted Apple gate that builds the package and all three Apple destinations, runs 46 package tests plus 5 StoreKit tests, produces unsigned validation archives, runs the CLI fixture harness and runs the portable gates.

## Deliberate release blockers

The app, entitlement and product-infrastructure layers are implemented. Signed distribution and TestFlight upload, live App Store Connect product records, retained real-bank parser corpora and fuzzing, device UI/performance/export testing, native-language QA, an independent final review and product-owner acceptance remain open. The package is therefore still **PROVISIONAL / NOT ENGINE LOCKED**.

The authoritative Apple result is recorded in `verification/apple-gate-results.json`. To rerun it locally on a supported Mac:

```sh
swift test
swift run bank-reconcile verify-fixtures
```

To generate and open the universal Apple project:

```sh
brew install xcodegen
tools/generate_apple_project.sh
open BankReconciliation.xcodeproj
```

Distribution ownership, product configuration and the exact signing handoff are documented in `docs/APPLE_DISTRIBUTION.md`.

The portable gate is:

```sh
python3 tools/reference_oracle.py
python3 tools/static_checks.py
python3 tools/validate_manifest.py
```

## Privacy and claims

The engine has no networking dependency and never modifies imported source files. An evidence pack proves only the supplied files and recorded decisions; it is not bank, accounting, tax, legal or audit assurance.
