# Acceptance Runbook

1. On macOS with current Xcode, run `swift test` and `swift run bank-reconcile verify-fixtures`.
2. Run `python3 tools/reference_oracle.py`, `python3 tools/static_checks.py`, and `python3 tools/validate_manifest.py`.
3. Add and run retained corpus fixtures for every production format and all five locale conventions.
4. Prove malformed, truncated, oversized, entity-expanded, zip-bomb, symlink and duplicate-entry inputs fail before excessive allocation.
5. Prove normalized sources reproduce byte-for-byte in canonical evidence from the locked source bytes and replay settings.
6. Run concurrent multi-process store writers plus crash injection between every revision write boundary.
7. Verify StoreKit 2 entitlements after fresh launch and restore; prove backup data cannot grant entitlement or erase real lock usage.
8. Reproduce evidence totals independently and compare with screen totals.
9. Run large-file performance and low-storage tests on the oldest supported iPhone, iPad and Mac.
10. Complete native financial-language QA for `en`, `fr`, `de`, `es` and `pt-BR`.
11. Repeat independent source audit and code-breaker review. Close every critical/high finding.
12. Ask the user to run the acceptance pack. Only then may the status move from provisional toward engine lock.
