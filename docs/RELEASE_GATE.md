# Release Gate

**Overall status: BLOCKED — PROVISIONAL / NOT ENGINE LOCKED**

| Gate | State | Evidence / blocker |
|---|---|---|
| Locked scope and contract | PASS | `docs/PRODUCT_SPEC.md`, `docs/CANONICAL_ENGINE_CONTRACT.md` |
| Exact arithmetic and deterministic core | PORTABLE PASS | `verification/portable-gate-results.json` after running local scripts |
| CSV/TSV adapter | SOURCE PRESENT | Requires `swift test` |
| Remaining required adapters | BLOCKED | Not implemented in this checkpoint |
| Swift compile and unit tests | BLOCKED | No Swift/Xcode toolchain in build environment |
| StoreKit entitlement adapter | BLOCKED | Requires signed StoreKit 2 integration and receipt tests |
| Backup/restore | BLOCKED | Production archive and recovery design not implemented |
| iPhone/iPad/Mac performance | BLOCKED | Requires device matrix |
| Five UI languages | BLOCKED | Engine error catalog is seeded; native QA not complete |
| Independent code-breaker review | LIMITED PASS | `docs/FINAL_DELTA_AUDIT.md`: zero open critical/high findings in implemented CSV/TSV scope; repeat after Apple gate and adapter completion |

No storefront submission should be prepared from this checkpoint.
