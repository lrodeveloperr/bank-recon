# Release Gate

**Overall status: BLOCKED — PROVISIONAL / NOT ENGINE LOCKED**

| Gate | State | Evidence / blocker |
|---|---|---|
| Locked scope and contract | PASS | `docs/PRODUCT_SPEC.md`, `docs/CANONICAL_ENGINE_CONTRACT.md` |
| Exact arithmetic and deterministic core | APPLE + PORTABLE PASS | 41 Swift tests plus `verification/portable-gate-results.json` |
| Controlled fuzzy and split/merge matching | APPLE PASS | Mutual-unique-best fuzzy tests, ambiguity test and bounded split candidate test |
| CSV/TSV and required structured adapters | APPLE PASS | XLSX, OFX/QFX/QBO, QIF/QMTF, CAMT.053/054, MT940 and BAI2 route through tested parsers |
| Swift compile and unit tests | PASS | `verification/apple-gate-results.json`; warnings-as-errors build on Apple Swift 6.1.2 / macOS 15 arm64 |
| Parser corpus and fuzzing | BLOCKED | Retained real-bank corpus, malformed-input matrix and fuzz campaigns are not complete |
| SwiftUI product shell | APPLE COMPILE PASS | Adaptive Mac/iPad navigation and compact iPhone tabs share the import/review/lock model; device UX testing remains blocked |
| StoreKit entitlement adapter | APPLE COMPILE PASS / SANDBOX BLOCKED | Verified non-revoked non-consumables, dynamic prices, purchase and restore are implemented; signed sandbox transaction/revocation testing remains open |
| Free/paid policy boundary | APPLE PASS | Two-lock free allowance, Pro bypass, Accountant-only entities/branding, and entitlement-free backups are tested |
| Backup/restore | APPLE PASS / DEVICE ACCEPTANCE OPEN | Bounded digest verification, empty-store restore, durable anchor replacement and injected final-anchor recovery are tested |
| Evidence PDF/CSV/JSON rendering | APPLE PASS / VISUAL ACCEPTANCE OPEN | PDF signature/content, CSV content, exact manifest and Accountant brand gating are tested; device/file-provider and golden visual review remain open |
| Real Keychain integration | APPLE PASS | Unique-service read, compare-and-swap, stale-write rejection, update and cleanup run in XCTest |
| iPhone/iPad/Mac performance | BLOCKED | Requires device matrix |
| Five UI languages | BLOCKED | Engine error catalog is seeded; native QA not complete |
| Independent code-breaker review | BLOCKED | Earlier limited audit covered the CSV/TSV checkpoint; repeat for matching and all structured adapters |
| User acceptance | BLOCKED | Acceptance runbook has not been completed by the product owner |

No storefront submission build should be uploaded from this checkpoint. The listing pack may continue to be prepared while the blocked acceptance gates remain explicit.
