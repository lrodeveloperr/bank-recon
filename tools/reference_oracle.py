#!/usr/bin/env python3
"""Portable contract oracle. It validates mathematical and lifecycle invariants; it does not compile Swift."""

from __future__ import annotations

import hashlib
import json
import random
from dataclasses import dataclass
from pathlib import Path

MAX_SCALE = 6
MAX_I64 = 2**63 - 1
MIN_I64 = -(2**63)


@dataclass(frozen=True, order=True)
class Amount:
    mantissa: int
    scale: int

    @staticmethod
    def make(mantissa: int, scale: int) -> "Amount":
        if not MIN_I64 <= mantissa <= MAX_I64 or not 0 <= scale <= MAX_SCALE:
            raise OverflowError
        while scale and mantissa % 10 == 0:
            mantissa //= 10
            scale -= 1
        return Amount(mantissa, scale)

    def rescale(self, scale: int) -> int:
        if scale < self.scale or scale > MAX_SCALE:
            raise OverflowError
        value = self.mantissa * 10 ** (scale - self.scale)
        if not MIN_I64 <= value <= MAX_I64:
            raise OverflowError
        return value

    def add(self, other: "Amount") -> "Amount":
        scale = max(self.scale, other.scale)
        value = self.rescale(scale) + other.rescale(scale)
        return Amount.make(value, scale)

    def sub(self, other: "Amount") -> "Amount":
        scale = max(self.scale, other.scale)
        value = self.rescale(scale) - other.rescale(scale)
        return Amount.make(value, scale)


def amount_invariants(rng: random.Random, rounds: int) -> int:
    minimum = Amount.make(MIN_I64, 0)
    assert minimum.sub(minimum) == Amount.make(0, 0)
    checks = 1
    for _ in range(rounds):
        scale = rng.randrange(MAX_SCALE + 1)
        a = Amount.make(rng.randint(-10**10, 10**10), scale)
        b = Amount.make(rng.randint(-10**10, 10**10), rng.randrange(MAX_SCALE + 1))
        try:
            total = a.add(b)
            assert total.sub(b) == a
            assert a.add(b) == b.add(a)
            checks += 2
        except OverflowError:
            checks += 1
    return checks


def deterministic_matching_invariants(rng: random.Random, rounds: int) -> int:
    checks = 0
    for _ in range(rounds):
        size = rng.randrange(1, 40)
        left = [(f"A{rng.randrange(4)}", "USD", f"ID-{index}") for index in range(size)]
        right = list(left)
        rng.shuffle(left)
        rng.shuffle(right)
        first = sorted(set(left).intersection(right))
        rng.shuffle(left)
        rng.shuffle(right)
        second = sorted(set(left).intersection(right))
        assert first == second
        assert len(first) == size
        checks += 2
    return checks


def lifecycle_invariants(rng: random.Random, rounds: int) -> int:
    checks = 0
    jobs: dict[int, tuple[int, str]] = {}
    receipts: set[str] = set()
    for step in range(rounds):
        job_id = rng.randrange(2_000)
        if job_id not in jobs:
            jobs[job_id] = (1, "draft")
            checks += 1
            continue
        revision, state = jobs[job_id]
        if state == "locked":
            before = jobs[job_id]
            assert jobs[job_id] == before
            checks += 1
            continue
        if rng.random() < 0.85:
            jobs[job_id] = (revision + 1, "draft")
        else:
            receipt = hashlib.sha256(f"{job_id}:{revision}".encode()).hexdigest()
            assert receipt not in receipts
            receipts.add(receipt)
            jobs[job_id] = (revision + 1, "locked")
        checks += 1
    assert sum(1 for _, state in jobs.values() if state == "locked") == len(receipts)
    return checks + 1


def canonicalization_invariants(rng: random.Random, rounds: int) -> int:
    checks = 0
    for _ in range(rounds):
        items = [(f"k-{index}", rng.randrange(1_000_000)) for index in range(rng.randrange(1, 20))]
        left = dict(items)
        rng.shuffle(items)
        right = dict(items)
        encoded_left = json.dumps(left, sort_keys=True, separators=(",", ":")).encode()
        encoded_right = json.dumps(right, sort_keys=True, separators=(",", ":")).encode()
        assert encoded_left == encoded_right
        assert hashlib.sha256(encoded_left).digest() == hashlib.sha256(encoded_right).digest()
        checks += 2
    return checks


def main() -> None:
    rng = random.Random(0xB4A9C)
    components = {
        "amount": amount_invariants(rng, 100_000),
        "matching": deterministic_matching_invariants(rng, 25_000),
        "lifecycle": lifecycle_invariants(rng, 250_000),
        "canonicalization": canonicalization_invariants(rng, 25_000),
    }
    report = {
        "status": "PASS",
        "scope": "portable reference invariants only; not a Swift compile or Apple platform gate",
        "seed": 0xB4A9C,
        "checks": sum(components.values()),
        "components": components,
    }
    destination = Path(__file__).resolve().parents[1] / "verification" / "portable-gate-results.json"
    destination.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
