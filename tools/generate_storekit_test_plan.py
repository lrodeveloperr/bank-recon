#!/usr/bin/env python3
"""Generate the Xcode test plan that activates the local StoreKit catalog."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


TARGET_NAMES = (
    "BankReconciliationEngineTests",
    "BankReconciliationAppCoreTests",
    "BankReconciliationStoreKitTests",
)
APP_TARGET_NAME = "BankReconciliation"


def target_identifier(project: str, name: str) -> str:
    pattern = re.compile(
        rf"([A-F0-9]{{24}}) /\* {re.escape(name)} \*/ = \{{\s+isa = PBXNativeTarget;",
        re.MULTILINE,
    )
    match = pattern.search(project)
    if match is None:
        raise SystemExit(f"could not find PBXNativeTarget identifier for {name}")
    return match.group(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if args.project is None:
        identifiers = {
            APP_TARGET_NAME: "000000000000000000000001",
            TARGET_NAMES[0]: "000000000000000000000002",
            TARGET_NAMES[1]: "000000000000000000000003",
            TARGET_NAMES[2]: "000000000000000000000004",
        }
    else:
        project = args.project.read_text(encoding="utf-8")
        identifiers = {
            name: target_identifier(project, name)
            for name in (APP_TARGET_NAME, *TARGET_NAMES)
        }

    container = "container:BankReconciliation.xcodeproj"
    plan = {
        "configurations": [
            {
                "id": "606BBF5D-7668-4AB0-97F6-02F353D8C72A",
                "name": "StoreKit Lifecycle",
                "options": {},
            }
        ],
        "defaultOptions": {
            "storeKitConfiguration": "App/StoreKit/BankReconciliation.storekit",
            "targetForVariableExpansion": {
                "containerPath": container,
                "identifier": identifiers[APP_TARGET_NAME],
                "name": APP_TARGET_NAME,
            },
        },
        "testTargets": [
            {
                "target": {
                    "containerPath": container,
                    "identifier": identifiers[name],
                    "name": name,
                }
            }
            for name in TARGET_NAMES
        ],
        "version": 1,
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
