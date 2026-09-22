# Release Gate

**Overall status: BLOCKED — PROVISIONAL / NOT ENGINE LOCKED**

| Gate | State | Evidence / blocker |
|---|---|---|
| Locked scope and contract | PASS | `docs/PRODUCT_SPEC.md`, `docs/CANONICAL_ENGINE_CONTRACT.md` |
| Exact arithmetic and deterministic core | APPLE + PORTABLE PASS | 30 Swift tests plus `verification/portable-gate-results.json` |
| Controlled fuzzy and split/merge matching | APPLE PASS | Mutual-unique-best fuzzy tests, ambiguity test and bounded split candidate test |
| CSV/TSV and required structured adapters | APPLE PASS | XLSX, OFX/QFX/QBO, QIF/QMTF, CAMT.053/054, MT940 and BAI2 route through tested parsers |
| Swift compile and unit tests | PASS | `verification/apple-gate-results.json`; warnings-as-errors build on Apple Swift 6.1.2 / macOS 15 arm64 |
| Parser corpus and fuzzing | BLOCKED | Retained real-bank corpus, malformed-input matrix and fuzz campaigns are not complete |
| StoreKit entitlement adapter | BLOCKED | Requires signed StoreKit 2 integration and receipt tests |
| Backup/restore | BLOCKED | Production archive and recovery design not implemented |
| Evidence PDF/CSV rendering | BLOCKED | Export renderers and golden output review are not implemented |
| iPhone/iPad/Mac performance | BLOCKED | Requires device matrix |
| Five UI languages | BLOCKED | Engine error catalog is seeded; native QA not complete |
| Independent code-breaker review | BLOCKED | Earlier limited audit covered the CSV/TSV checkpoint; repeat for matching and all structured adapters |
| User acceptance | BLOCKED | Acceptance runbook has not been completed by the product owner |

No storefront submission should be prepared from this checkpoint.
