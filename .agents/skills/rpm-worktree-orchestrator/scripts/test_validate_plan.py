#!/usr/bin/env python3
"""Regression tests for the RPM-local orchestration plan validator."""

from __future__ import annotations

import unittest

from validate_plan import validate


HASH = "sha256:" + "a" * 64


def node(node_id: str, *, depends_on: list[str] | None = None, paths: list[str] | None = None, state: str = "pending", revision: str = "p1") -> dict[str, object]:
    return {
        "id": node_id,
        "objective": node_id,
        "role": "worker",
        "depends_on": depends_on or [],
        "write_paths": paths or [],
        "base_revision": "abc123",
        "plan_revision": revision,
        "state": state,
        "attempt": 0,
    }


def plan(nodes: list[dict[str, object]], gates: list[str] | None = None) -> dict[str, object]:
    return {
        "repository": "nerdchanii/rpm",
        "plan_revision": "p1",
        "base_revision": "abc123",
        "scope_hash": HASH,
        "executor": "local",
        "required_gates": gates or [nodes[-1]["id"]],
        "nodes": nodes,
    }


class ValidatePlanTests(unittest.TestCase):
    def assert_invalid(self, value: dict[str, object], text: str) -> None:
        with self.assertRaisesRegex(ValueError, text):
            validate(value)

    def test_valid_dag(self) -> None:
        validate(plan([node("map"), node("impl", depends_on=["map"], paths=["src/impl.rs"]), node("verify", depends_on=["impl"])]))

    def test_missing_dependency(self) -> None:
        self.assert_invalid(plan([node("impl", depends_on=["missing"])]), "missing node")

    def test_cycle(self) -> None:
        self.assert_invalid(plan([node("a", depends_on=["b"]), node("b", depends_on=["a"])]), "cycle")

    def test_overlap(self) -> None:
        self.assert_invalid(plan([node("a", paths=["src/shared"]), node("b", paths=["src/shared/x.rs"])]), "overlapping")

    def test_stale_revision(self) -> None:
        self.assert_invalid(plan([node("a", revision="old")]), "stale")

    def test_stale_base_revision(self) -> None:
        stale = node("a")
        stale["base_revision"] = "different-base"
        self.assert_invalid(plan([stale]), "base_revision is stale")

    def test_required_gate(self) -> None:
        self.assert_invalid(plan([node("a")], gates=["missing"]), "required gate")


if __name__ == "__main__":
    unittest.main()
