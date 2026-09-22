# App Finalization — Items 1 to 3

Date: 2026-09-22  
Decision: **implemented with a green Apple automation gate; release remains provisional**

## 1. SwiftUI app layer

One shared SwiftUI layer now exposes Reconciliations, Source Profiles, Evidence Packs and Settings. Mac and regular-width iPad use sidebar navigation; compact iPhone uses four tabs. The workflow supports mode and period selection, security-scoped file import, automatic parser planning, preview, exception explanations, evidence locking, the immutable sample and saved-record status.

The Swift package builds a macOS executable and the shared app-core target is declared for iOS 18 and macOS 15. A signed Xcode archive, device interaction matrix and App Store packaging are not claimed by this checkpoint.

## 2. StoreKit 2 and plan enforcement

- Product IDs: `com.worksbienstudios.bankreconciliation.pro` and `com.worksbienstudios.bankreconciliation.accountant`.
- Products are non-consumables with App Store-supplied display names and localized prices.
- Access refresh reads current verified entitlements, ignores revoked or unrelated transactions, selects the highest tier, verifies a purchase before finishing it, and uses `AppStore.sync()` for restore.
- Free permits one entity, one saved mapping and two committed real locks. Failed imports, failures, previews and the immutable sample do not count.
- Pro permits one entity with unlimited saved mappings, locks and evidence packs.
- Accountant additionally permits multiple entities and branded evidence headers.

The adapter is Apple-compiled and the policy boundary is Apple-tested. Signed StoreKit sandbox purchase, revocation and restore scenarios remain an explicit release gate.

## 3. Product infrastructure

- Engine backups are size/count bounded, canonical-digest protected and accepted only into an empty store.
- Restore validates every revision chain, evidence envelope and unique receipt before replacing the store through the recoverable durable-anchor protocol.
- Application backups wrap engine data plus entity/profile settings. The schema has no entitlement field, so a backup cannot grant a purchase.
- Locked records export a standalone PDF, detailed CSV and the exact canonical JSON evidence manifest.
- Reports include the entity, source filenames/hashes/sizes/import times, parser versions/mappings, totals, matches, exceptions, recorded decisions, lock time, engine version and a limitation notice.
- Keychain compare-and-swap and post-replacement anchor recovery have Apple integration tests.

## Verification snapshot

Apple workflow run `35742751689` passed on macOS 15 arm64 with Apple Swift 6.1.2: warnings-as-errors package build, explicit SwiftUI executable build, 41 XCTest cases, CLI fixture replay and all portable gates. The authoritative result is recorded in `verification/apple-gate-results.json`.

## Still required before engine lock or submission

Retained real-bank corpora and fuzzing; signed StoreKit sandbox tests; iPhone/iPad/Mac device UI, performance and file-provider checks; native QA for all five languages; independent review of the expanded scope; and product-owner acceptance.
