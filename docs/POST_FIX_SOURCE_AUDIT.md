# Post-Fix Source Audit

**Audit date:** 2026-09-22  
**Scope:** delta review of the implemented CSV/TSV recovery candidate after C-01 and H-01 through H-03 remediation  
**Verdict:** **FAIL — REMAIN PROVISIONAL / NOT ENGINE LOCKED**

This was a source-only review of the current tree. No implementation source was modified. The environment contains no `swift` or `swiftc`; therefore this report does not claim that the package compiles, that XCTest or the CLI runs, or that Foundation, Security, Keychain, file-protection, or `flock` behavior has been exercised on an Apple platform.

Per the audit request, the stale checksum file is excluded from the finding count. It must be regenerated as the final packaging step after this report and every other artifact is frozen.

## Prior-finding dispositions

| Prior finding | Disposition | Source evidence |
|---|---|---|
| C-01 — CRLF could collapse a populated file into a header-only source | **CLOSED in source; Swift execution pending** | `DelimitedParser.tokenize` now consumes UTF-8 bytes and handles LF, CR, and CRLF explicitly, including quoted multiline fields (`DelimitedParser.swift:149-242`). Regression tests cover CRLF, CR, and quoted CRLF line locators (`DelimitedParserTests.swift:39-68`). |
| H-01 — delimiter-built identity collisions could cross partitions | **CLOSED in source; Swift execution pending** | Strong, composite, duplicate, and balance identities are structured values (`Reconciliation.swift:80-127`, `241-295`, `416-439`), and both automatic match paths recheck the account/currency partition (`170-172`, `196-198`). The original collision is retained as a regression test (`ReconciliationTests.swift:132-147`). |
| H-02 — CSV/TSV Mode C could not produce replayable locked proof | **CLOSED in source; Swift execution pending** | `ParseReplayDescriptor` binds balance overrides (`Domain.swift:372-391`); `FormatRouter` reconstructs them (`DelimitedParser.swift:287-305`); reconciliation requires source balances to equal the replay values (`Reconciliation.swift:28-31`); canonical evidence includes them (`Evidence.swift:277-317`). The test at `ReconciliationTests.swift:149-183` performs byte parse, Mode C run, evidence lock, and full replay verification. |
| H-03 — snapshot-tail deletion revived a draft and reset usage | **CLOSED for the reported tail-deletion reproduction; follow-on H-05 remains** | Current snapshot heads and receipts are compared with an external anchor before store operations (`Store.swift:233-299`), using the Keychain in production (`DurableStoreAnchor.swift:1-57`). Removing the locked tail now produces an anchor mismatch, covered at `StoreTests.swift:67-110`. |
| H-04 — stale/incomplete checksum manifest | **DEFERRED PACKAGING STEP, not counted** | The caller will regenerate it after this post-fix report. |

The earlier medium findings for syntactically invalid timestamps and lowercased “exact” references are also corrected: timestamp components and the Gregorian date are validated (`Evidence.swift:199-215`), and `CompositeMatchKey` retains the exact cleaned reference (`Reconciliation.swift:246-253`).

## Critical findings

None found by this source-only delta review.

## High findings

### H-05 — Any anchor-write failure after a snapshot write permanently strands the store

Every mutating store operation uses this order:

1. validate the current external anchor;
2. write or move the new revision into the visible jobs tree;
3. update the external anchor.

The relevant paths are `createDraftRecord` (`Store.swift:95-114`), `updateDraft` (`118-140`), and `commitLock` (`144-180`). `write` and `writeNewJob` make the file-tree mutation visible before `advanceAnchor` calls `compareAndSwap` (`373-391`, `286-299`). There is no rollback, pending journal, or recovery state when the anchor update throws.

Concrete reproduction with the already-supported injected `DurableStoreAnchor` interface:

1. Initialize an empty store and allow creation of its initial empty anchor.
2. Configure the next `compareAndSwap` to throw, simulating a Keychain denial, transient Security error, size failure, or process termination after the snapshot write.
3. Call `createDraft`. Revision 1 is written, then the call throws while advancing the anchor.
4. Call any store operation. `validatedAnchor` observes the old empty anchor and the new on-disk head, then throws `durable store anchor does not match snapshot heads` (`Store.swift:233-258`).

The same window exists for draft updates and lock commits. In the lock case, the API reports failure although a locked revision exists on disk; all later operations fail closed with no supported repair. A transient persistence failure therefore causes durable loss of service and requires manual file/Keychain surgery or destructive reset. This meets HIGH severity: a normal supported state becomes unrecoverable and no application-level workaround exists.

Required correction: implement a recoverable two-phase protocol or write-ahead intent that distinguishes an authorized unanchored successor from tampering. On an anchor failure, safely roll back the just-created revision while the root lock is held, or retain enough externally authenticated intent to finish/reconcile the commit on next launch. Add deterministic failure injection before/after the snapshot rename and before/during/after anchor update for create, update, and lock. Verify restart recovery and unchanged free-lock accounting at every boundary.

`KeychainStoreAnchor.compareAndSwap` also performs a separate read followed by `SecItemAdd`/`SecItemUpdate` (`DurableStoreAnchor.swift:29-47`), rather than a platform-atomic compare-and-swap. The root `flock` serializes cooperative stores sharing the same root, but this implementation detail must be included in the concurrency and crash tests.

### H-06 — A reconciled Mode C result carries a nonzero comparison “difference” total

`proveSingleStatement` validates opening + activity = closing, but constructs totals by calling `partitionTotals(left: source.transactions, right: [])` (`Reconciliation.swift:65-75`). `partitionTotals` consequently sets:

- `left` = statement activity;
- `right` = zero;
- `difference` = statement activity (`Reconciliation.swift:442-449`).

Concrete reproduction is already present in `testDelimitedModeCParsesLocksAndReplaysBalanceOverrides`: opening 100, activity +5, and closing 105 correctly produce `.reconciled` (`ReconciliationTests.swift:149-183`), but the result total is `left = 5`, `right = 0`, `difference = 5`. The canonical evidence serializes that nonzero difference without mode-specific interpretation (`Evidence.swift:344-362`).

Impact: a supported successful Mode C run emits internally contradictory evidence—a green reconciliation state alongside a nonzero field explicitly named `difference`. The product contract requires Mode C arithmetic proof and the product flow exposes total difference. A screen, exporter, or independent evidence consumer cannot safely interpret this as the closing-balance residual.

Required correction: define mode-specific totals. For Mode C, bind opening, signed activity, closing, and residual explicitly, or populate the common total as `left = opening + activity`, `right = closing`, and `difference = residual`. Tie `.reconciled` to an exactly zero residual and add assertions for the result object and canonical evidence, not only the state.

## Compile and runtime plausibility

- The revised Swift is structurally plausible on the declared iOS 18/macOS 15 targets; no definite compiler error was identified by inspection. This is not compilation evidence.
- `DurableStoreAnchor.swift` adds `Security`, Core Foundation bridging, `OSStatus`, and Keychain accessibility constants. The unit tests inject an in-memory anchor and never instantiate or exercise the production `KeychainStoreAnchor`; signed-device and macOS Keychain behavior therefore remains wholly unverified.
- The package intentionally imports Apple-only `Darwin` and `Security`, so absence of Linux portability is not a defect for the declared platforms. It makes the unavailable Apple gate mandatory.
- Adding the nonoptional `balanceOverrides` property under the existing synthesized `Codable` shape means pre-fix stored jobs lacking that key will fail decoding. The parser algorithm also changed without incrementing `DelimitedParser.version` from `delimited-1.0.0`, and the evidence schema/engine version remain unchanged. If any pre-fix snapshots or evidence are expected to survive an upgrade, explicit decoding compatibility or a schema/version migration is required. Otherwise the reset-only boundary must be documented before distribution.
- A single Keychain item stores the complete unbounded job-head and receipt dictionaries. Real-device testing must establish a safe capacity bound and failure behavior; H-05 currently turns any size-related Keychain update failure into a stranded store.

## Portable gate confirmation

The three generators were executed against a temporary copy so the audited tree remained untouched. Their generated reports were byte-identical to the reports in the tree:

| Gate | Result | Report SHA-256 |
|---|---:|---|
| Python reference oracle | PASS — 550,002 checks, seed 739,996 | `5cdddb1c6d42a31604e16da048cfa9f9e1831cb84bc293321d0d8d4f1eaf9375` |
| Static source gate | PASS — 12 checks | `9c88ea26b73ca114d4edfff8c076e09ae0560720448450124d62db6abe5e9f82` |
| Requirement-manifest gate | PASS — 31 requirements: 16 source-uncompiled, 3 portable-tested, 12 planned blockers | `efa017fd355d903697fa330c1e3ca86a3c92b7ab38a26ed5341f20202c8b3873` |

These gates do not execute Swift. The reference lifecycle model does not model the file-tree/Keychain two-resource commit, and the static gate checks for anchor-related tokens rather than recovery semantics. Their PASS results therefore do not contradict H-05 or H-06.

## Verdict

C-01 and the specific H-01, H-02, and H-03 reproductions are addressed in source, subject to Swift/XCTest confirmation. The current candidate still has two unresolved HIGH defects in its implemented scope: unrecoverable file/anchor partial commits and inconsistent Mode C totals/evidence. It must remain **PROVISIONAL / NOT ENGINE LOCKED**.

After correcting H-05 and H-06, rerun targeted Swift tests, the full critical-invariant suite, real Keychain integration, multi-process/crash injection, the CLI fixture command, and the declared Apple gate. The already-declared missing adapters, StoreKit, backup/restore, report rendering, localization, performance, and hardware validation remain separate release blockers. Regenerate and verify the final checksum manifest only after the post-fix source, tests, generated reports, and audit documents are frozen.
