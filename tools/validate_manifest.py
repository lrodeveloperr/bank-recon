#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VALID = {"apple-compiled", "apple-tested", "portable-tested", "planned-release-blocker"}


def main() -> None:
    path = ROOT / "manifest" / "gate-manifest.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    ids = [item["id"] for item in data["requirements"]]
    assert len(ids) == len(set(ids)), "duplicate requirement id"
    assert all(item["status"] in VALID for item in data["requirements"]), "invalid status"
    assert any(item["status"] == "planned-release-blocker" for item in data["requirements"]), "release blockers must be explicit"
    report = {
        "status": "PASS",
        "requirements": len(ids),
        "apple_compiled": sum(item["status"] == "apple-compiled" for item in data["requirements"]),
        "apple_tested": sum(item["status"] == "apple-tested" for item in data["requirements"]),
        "portable_tested": sum(item["status"] == "portable-tested" for item in data["requirements"]),
        "planned_release_blockers": sum(item["status"] == "planned-release-blocker" for item in data["requirements"]),
    }
    (ROOT / "verification" / "manifest-gate-results.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
