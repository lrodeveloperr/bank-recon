# Code-Breaker Disposition

This file tracks architectural hazards carried into the recovery build.

| Prior hazard | Recovery disposition |
|---|---|
| Evidence did not prove bytes → normalized source | Lock now verifies hash/size, reparses the bound bytes with the full replay descriptor, compares the full `SourceStatement`, then reruns the job |
| Generic save could create or alter a lock | Only `commitLock` creates locked state; history rejects any revision after a lock |
| Revision lineage bypass | Every revision is append-only, contiguous and binds the SHA-256 of its predecessor |
| Multiple store actors lost index updates | No mutable index exists; a cross-process root `flock` serializes discovery, validation and writes |
| New-job crash left an invisible record | Jobs are discovered directly from per-job revision directories; an incomplete directory fails validation visibly |
| Amount results could be undecodable | Scale and `Int64` range are checked at construction, decoding, rescaling and arithmetic |
| Free counter could be reset independently | Count is derived from Keychain-anchored locked heads and unique evidence-derived receipts; no independent mutable counter is trusted |
| Snapshot-tail deletion revived a draft and reset usage | Snapshot heads and receipts are now compared against a monotonic anchor stored outside the file tree through `DurableStoreAnchor`; the production adapter uses the device Keychain and any missing/mismatched tail fails closed |
| CRLF collapsed into one Swift grapheme | Delimited tokenization now operates on UTF-8 bytes with explicit CR, LF and CRLF paths, including quoted multiline line tracking |
| Delimiter-built match key collision | Automatic strong/composite and balance identities are structured `Hashable` values and every automatic pair rechecks its partition |
| Mode C could not lock a delimited proof | Opening/closing overrides are explicit replay inputs, included in canonical evidence, reconstructed by `FormatRouter`, and covered by an end-to-end parse/run/lock/replay test |
| Anchor failure after a snapshot stranded the store | Mutations now publish a fixed-size external pending intent before the snapshot; validation clears a pre-write intent or finalizes a matching post-write snapshot after restart |
| Mode C green result carried a nonzero comparison difference | Mode C totals are typed as `statementBalanceEquation` and encode `opening + activity` versus `closing`; the reported difference is the exact residual |
| Dictionary/set output was nondeterministic | Evidence builds explicit sorted JSON arrays and sorted-key objects |

This disposition does not close adapter-specific findings for adapters absent from this checkpoint. See `docs/FINAL_SOURCE_AUDIT.md` when the independent recovery audit completes.
