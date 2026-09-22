# Canonical Engine Contract

Status: **LOCKED PRODUCT CONTRACT; PROVISIONAL IMPLEMENTATION**

## Product boundary

The engine compares already-structured financial exports locally. It is not a ledger, bank connector, statement converter, OCR system or assurance service. Source bytes are read-only.

## Inputs and modes

| Mode | Required roles | Question |
|---|---|---|
| A | exactly one `bank`, one `ledger` | Do both sources agree for the selected period? |
| B | exactly one `olderExport`, one `newerExport` | What was added, deleted or mutated? |
| C | exactly one `statement` | Is one structured statement arithmetically coherent? |

All records must be within the selected inclusive period. Accounts and currencies partition matching. Cross-partition matches are forbidden.

## Determinism and failure rules

1. Parse and arithmetic limits are checked before allocation or rescaling.
2. No source field is silently invented; every derived value is identified.
3. Strong identifiers match first, then exact composite identity. Equal candidates remain ambiguous.
4. One source transaction participates in at most one automatic match.
5. A locked result binds immutable source bytes, parser replay settings, the full normalized statements, user decisions and the exact result.
6. Canonical serialization sorts object keys, set values, transactions, matches, exceptions and decisions.
7. Missing proof produces `cannotConclude`, never a guessed green result.

## Required production formats

CSV, TSV, XLSX, OFX, QFX, QBO, QIF, QMTF, CAMT.053 001.02–001.08, CAMT.054 001.02–001.08, MT940 and BAI2.

All required families are implemented with replay-bound profiles, bounded parsers and format-specific validation. Unsupported or malformed variants return typed errors and cannot be locked.

## Monetization boundary

Failed parses and previews never consume free usage. Only a successfully committed non-sample lock creates an immutable receipt. Restoring data cannot create an App Store entitlement.

Free permits one entity, one saved mapping and two committed real locks. Pro is a non-consumable purchase for one entity with unlimited mappings, locks and evidence packs. Accountant is a non-consumable purchase that additionally permits multiple entities and branded evidence headers. Live access is derived from verified, non-revoked StoreKit transactions; backup data contains no entitlement state.

## Release rule

Do not label this engine complete or locked until all acceptance gates in `docs/PRODUCT_SPEC.md` pass on real Apple hardware and an independent code-breaker review has no unresolved critical/high defect.
