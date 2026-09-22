#!/usr/bin/env python3
"""Fail-closed static checks for this source candidate."""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources" / "BankReconciliationEngine"


def main() -> None:
    required = [
        ROOT / "Package.swift",
        ROOT / "README.md",
        ROOT / "docs" / "PRODUCT_SPEC.md",
        ROOT / "docs" / "CANONICAL_ENGINE_CONTRACT.md",
        ROOT / "docs" / "RELEASE_GATE.md",
        SOURCE / "Domain.swift",
        SOURCE / "DelimitedParser.swift",
        SOURCE / "Reconciliation.swift",
        SOURCE / "Evidence.swift",
        SOURCE / "Store.swift",
    ]
    failures: list[str] = []
    for path in required:
        if not path.is_file() or path.stat().st_size == 0:
            failures.append(f"missing:{path.relative_to(ROOT)}")

    swift = "\n".join(path.read_text(encoding="utf-8") for path in SOURCE.glob("*.swift"))
    checks = {
        "no_try_force": not re.search(r"\btry!", swift),
        "no_trap_calls": not re.search(r"\b(?:fatalError|preconditionFailure)\s*\(", swift),
        "no_binary_floating_money": not re.search(r"\b(?:Double|Float)\b", swift),
        "no_network_stack": not re.search(r"\b(?:URLSession|NWConnection|Alamofire|Network\.framework)\b", swift),
        "required_adapter_routing": all(token in (SOURCE / "DelimitedParser.swift").read_text(encoding="utf-8") for token in ["case .xlsx:", "case .ofx, .qfx, .qbo:", "case .qif, .qmtf:", "case .camt053, .camt054:", "case .mt940:", "case .bai2:"]),
        "bounded_structured_parsing": all(token in swift for token in ["maximumArchiveEntries", "maximumExpandedBytes", "archive compression ratio", "maximumXMLNodes", "maximumXMLDepth"]),
        "controlled_advanced_matching": all(token in (SOURCE / "Reconciliation.swift").read_text(encoding="utf-8") for token in ["maximumFuzzyCandidatePairs", "minimumTextSimilarityPermille", "maximumSplitMergeGroupSize", "maximumSplitMergeEvaluations"]),
        "evidence_replays_source_bytes": all(token in (SOURCE / "Evidence.swift").read_text(encoding="utf-8") for token in ["sourceBytesByID", "router.parse", "replayed == source", "rerun == result"]),
        "append_only_revision_chain": all(token in (SOURCE / "Store.swift").read_text(encoding="utf-8") for token in ["predecessorSnapshotID", "revision already exists", "revision sequence mismatch", "revision exists after lock"]),
        "crlf_byte_tokenizer": all(token in (SOURCE / "DelimitedParser.swift").read_text(encoding="utf-8") for token in ["let bytes = Array(data)", "byte == 13", "bytes[next] == 10"]),
        "structured_match_keys": all(token in (SOURCE / "Reconciliation.swift").read_text(encoding="utf-8") for token in ["StrongMatchKey", "CompositeMatchKey", "partition(lhs) == partition(rhs)"]),
        "mode_c_replay_balances": all(token in (SOURCE / "Domain.swift").read_text(encoding="utf-8") + (SOURCE / "DelimitedParser.swift").read_text(encoding="utf-8") for token in ["balanceOverrides", "balances: replay.balanceOverrides"]),
        "external_durable_anchor": all(token in (SOURCE / "Store.swift").read_text(encoding="utf-8") + (SOURCE / "DurableStoreAnchor.swift").read_text(encoding="utf-8") for token in ["validatedAnchor", "KeychainStoreAnchor", "compareAndSwap", "durable store anchor does not match snapshot heads"]),
        "recoverable_two_phase_anchor": all(token in (SOURCE / "Store.swift").read_text(encoding="utf-8") for token in ["PendingAnchorMutation", "beginAnchoredMutation", "finalizeAnchoredMutation", "actualSummary.matches(pending)"]),
        "mode_c_residual_total": all(token in (SOURCE / "Reconciliation.swift").read_text(encoding="utf-8") + (SOURCE / "Domain.swift").read_text(encoding="utf-8") for token in ["singleStatementTotals", "statementBalanceEquation", "equationLeft.subtracting(closing)"]),
        "release_status_blocked": "BLOCKED — PROVISIONAL / NOT ENGINE LOCKED" in (ROOT / "docs" / "RELEASE_GATE.md").read_text(encoding="utf-8"),
    }
    failures.extend(name for name, passed in checks.items() if not passed)
    report = {
        "status": "PASS" if not failures else "FAIL",
        "scope": "source/static checks; not compiler execution",
        "checks": checks,
        "failures": failures,
    }
    destination = ROOT / "verification" / "static-gate-results.json"
    destination.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, sort_keys=True))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
