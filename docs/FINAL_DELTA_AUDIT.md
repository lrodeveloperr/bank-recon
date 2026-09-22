# Final Delta Audit

**Audit date:** 2026-09-22  
**Scope:** frozen current source; final review of H-05/H-06 corrections and adjacent implemented CSV/TSV invariants  
**Delta verdict:** **PASS — zero unresolved CRITICAL/HIGH source findings in the implemented scope**  
**Overall product verdict:** **PROVISIONAL / NOT ENGINE LOCKED**

This is a source-only verdict. No implementation source was modified. The environment has no `swift` or `swiftc`, so the package, XCTest suite, CLI, Foundation file behavior, `flock`, Security bridging, and production Keychain adapter were not executed. The stale checksum file is intentionally excluded from this audit; it is a final packaging step after this report.

## Final dispositions

### H-05 — Anchor failure after snapshot write stranded the store

**CLOSED in source; Apple execution pending.**

The mutation protocol now publishes a fixed-size pending target before changing the file tree:

1. serialize the exact next record and calculate its snapshot ID;
2. derive the target heads/receipt digests and real-lock count;
3. compare-and-swap the external anchor to `PendingAnchorMutation`;
4. atomically publish the snapshot;
5. compare-and-swap the anchor to the completed state.

This ordering is implemented for create, update, and lock (`Store.swift:95-188`). `validatedAnchor` resolves an interrupted pending state mechanically (`Store.swift:251-304`):

| External state | File-tree summary | Recovery |
|---|---|---|
| pending | prior committed digest/count | clear the unused pending intent |
| pending | pending target digest/count | advance sequence, commit target digests/count, clear pending |
| pending | anything else | fail closed |

The anchor contains only schema, sequence, two digests, one count, and an optional fixed-size pending summary (`Store.swift:225-238`); it no longer grows with job history. Snapshot bytes are encoded and hashed before the intent is published, then the written hash is checked (`Store.swift:112-116`, `141-145`, `184-188`, `367-369`). The injected final-anchor failure test confirms that a subsequent `load` recognizes the matching on-disk target and completes recovery (`StoreTests.swift:37-55`). Tail deletion after a completed mutation still mismatches the committed anchor and fails closed (`StoreTests.swift:99-142`).

No critical/high defect was found in this state machine by source inspection.

### H-06 — Reconciled Mode C carried a nonzero comparison difference

**CLOSED in source; Swift execution pending.**

`PartitionTotal` now carries an explicit `PartitionTotalKind` distinguishing source-activity comparisons from statement-balance equations (`Domain.swift:626-645`). Modes A/B continue to calculate left activity minus right activity with `.sourceActivityComparison` (`Reconciliation.swift:442-456`). Mode C now calculates:

`left = opening + signed activity`, `right = closing`, `difference = left - right`

with `.statementBalanceEquation` (`Reconciliation.swift:458-479`). The end-to-end CRLF Mode C fixture asserts kind, 105/105 sides, and exact zero residual before evidence lock and full replay verification (`ReconciliationTests.swift:149-188`). Canonical result evidence includes the total kind and all exact amount components (`Evidence.swift:344-363`).

No critical/high inconsistency remains in the reviewed Mode C result path.

## Regression review

No new CRITICAL or HIGH source defect was found in the adjacent implemented scope. In particular:

- CR, LF, and CRLF byte tokenization and quoted multiline line tracking remain intact, with bounded input/field/record handling.
- Strong, composite, duplicate, and balance keys remain structured, and automatic/manual pairs remain partition-checked.
- Balance overrides remain part of the replay descriptor, normalized source equality, job digest, canonical manifest, retained-byte replay, and result rerun.
- Exact fixed-point construction/decoding, scale normalization, rescaling, addition/subtraction overflow checks, `Int64.min` handling, and fixed-width Gregorian dates retain the prior fail-closed behavior.
- Mode/role counts, selected periods, unique transaction locators/ordinals, manual-match row fingerprints, exception-decision keys, per-partition totals, and ambiguity handling remain enforced.
- Locked-store history remains contiguous, predecessor-bound, immutable after a surviving lock, externally head-anchored, sample-exemption-bound, and real-lock-counted from the anchored summary.
- Evidence still binds the exact job, typed result, replay settings, normalized sources, retained byte hashes/sizes, decisions, and engine rerun.

The semantic versions are now separated appropriately for this candidate: `DelimitedParser.version` is `delimited-2.0.0`, evidence schema is 2, engine version is `0.2.0-recovery`, the durable anchor schema is 3, and the SBOM package version is `0.2.0-recovery`.

## Compile and runtime plausibility

No definite Swift syntax/type error was identified by inspection. The source is structurally plausible for the declared iOS 18/macOS 15 targets, including the actor-isolated store, `any DurableStoreAnchor` existential, synthesized `Codable`/`Hashable` types, Darwin locking calls, and Security APIs. This is not compiler evidence.

The following remain mandatory execution concerns, but are not classified as source-proven CRITICAL/HIGH defects:

- The real `KeychainStoreAnchor` is not exercised by the unit tests; its Core Foundation bridging, accessibility behavior, signed-process access, error codes, and interaction with the root `flock` require macOS/iOS integration tests.
- `compareAndSwap` is implemented as Keychain read followed by add/update rather than a native atomic conditional update. Cooperative store writers sharing the root are serialized by `flock`; multi-process tests must confirm that every production writer shares that lock and anchor identifier.
- The recovery test covers failure of the final anchor write. Apple crash/failure injection should additionally cover interruption before pending publication, after pending publication but before snapshot publication, during atomic file publication, after snapshot publication, and during recovery compare-and-swap for create, update, and lock.
- Missing opening/closing balances cause Mode C to fail closed, but `singleStatementTotals` represents missing sides with zero while the result is `cannotConclude`. Evidence/UI consumers must treat the accompanying period-gap exception and total kind as authoritative; a later schema may prefer optional/unavailable sides rather than placeholder zero.
- Schema/version bumps correctly reject incompatible older artifacts, but there is no migration path for earlier provisional snapshots/anchors. This is acceptable only while the recovery candidate has no supported installed-data compatibility promise; production upgrade/restore remains blocked.
- Parser corpus, fuzzing, large-file memory/performance, low-storage behavior, signed Keychain access, cross-process crash recovery, and device testing remain absent.

## Portable gate confirmation

The three generators were executed against a temporary copy, leaving the audited tree untouched. Their regenerated outputs are byte-identical to the checked-in reports:

| Gate | Result | Report SHA-256 |
|---|---:|---|
| Python reference oracle | PASS — 550,002 checks, seed 739,996 | `5cdddb1c6d42a31604e16da048cfa9f9e1831cb84bc293321d0d8d4f1eaf9375` |
| Static source gate | PASS — 14 checks | `e778790b0382c6862355966a878f03c8c9a0764bdba4b816156da4513f8a49c1` |
| Requirement-manifest gate | PASS — 33 requirements: 18 source-uncompiled, 3 portable-tested, 12 planned blockers | `000b7e55a7a4523b7d1a0c93e05258ade64a8b957c2acae373b90639d833bc41` |

These reports are portable reference/static/manifest evidence only. They do not compile or execute Swift and do not replace the Apple gate.

## Verdict

H-05 and H-06 are closed in the current source, and this final delta audit found **zero remaining CRITICAL/HIGH defects in the implemented CSV/TSV scope**. The source candidate passes this limited independent delta review.

It must nevertheless remain **PROVISIONAL / NOT ENGINE LOCKED**. Swift compilation and XCTest, real Keychain integration, exhaustive crash/concurrency testing, parser corpus/fuzzing, and device gates have not run. The declared non-CSV adapters, StoreKit entitlement verification, backup/restore, PDF/CSV reporting, localization QA, performance matrix, external verification, and user acceptance also remain release blockers. Regenerate and verify the complete non-self-referential checksum manifest only after this report and every other final artifact are frozen.
