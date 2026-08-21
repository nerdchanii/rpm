#!/usr/bin/env python3
"""Regression tests for the RPM-local orchestration plan validator."""

from __future__ import annotations

import unittest

from validate_plan import validate


HASH = "sha256:" + "a" * 64


def node(node_id: str, *, depends_on: list[str] | None = None, paths: list[str] | None = None, state: str = "pending", revision: str = "p1", base_revision: str = "abc123", integrated_revision: str | None = None) -> dict[str, object]:
    value = {
        "id": node_id,
        "objective": node_id,
        "role": "worker",
        "depends_on": depends_on or [],
        "write_paths": paths or [],
        "base_revision": base_revision,
        "plan_revision": revision,
        "state": state,
        "attempt": 0,
    }
    if integrated_revision is not None:
        value["integrated_revision"] = integrated_revision
    return value


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

    def test_ordered_overlap_is_allowed(self) -> None:
        validate(
            plan(
                [
                    node("a", paths=["src/shared"]),
                    node("b", depends_on=["a"], paths=["src/shared/x.rs"]),
                ]
            )
        )

    def test_completed_dependency_is_not_integrated(self) -> None:
        self.assert_invalid(
            plan(
                [
                    node("producer", state="completed"),
                    node("consumer", depends_on=["producer"], state="ready"),
                ]
            ),
            "unfinished dependencies",
        )

    def test_dependent_node_uses_verified_integrated_revision(self) -> None:
        validate(
            plan(
                [
                    node("producer", state="integrated", integrated_revision="commit-2"),
                    node("consumer", depends_on=["producer"], state="ready", base_revision="commit-2"),
                ]
            )
        )

    def test_dependent_node_rejects_unverified_base_revision(self) -> None:
        self.assert_invalid(
            plan(
                [
                    node("producer", state="integrated", integrated_revision="commit-2"),
                    node("consumer", depends_on=["producer"], state="ready", base_revision="commit-3"),
                ]
            ),
            "base_revision is stale",
        )

    def test_integrated_node_requires_verified_revision(self) -> None:
        self.assert_invalid(plan([node("producer", state="integrated")]), "integrated_revision")

    def test_join_node_records_all_integrated_dependencies(self) -> None:
        join = node(
            "join",
            depends_on=["left", "right"],
            state="ready",
            base_revision="commit-join",
        )
        join["base_revision_dependencies"] = ["left", "right"]
        validate(
            plan(
                [
                    node("left", state="integrated", integrated_revision="commit-left"),
                    node("right", state="integrated", integrated_revision="commit-right"),
                    join,
                ]
            )
        )

    def test_join_node_rejects_missing_aggregate_evidence(self) -> None:
        self.assert_invalid(
            plan(
                [
                    node("left", state="integrated", integrated_revision="commit-left"),
                    node("right", state="integrated", integrated_revision="commit-right"),
                    node("join", depends_on=["left", "right"], state="ready", base_revision="commit-left"),
                ]
            ),
            "base_revision_dependencies",
        )

    def test_windows_absolute_path(self) -> None:
        self.assert_invalid(plan([node("a", paths=["C:/Users/me/file"])]), "unsafe write path")

    def test_windows_unc_path(self) -> None:
        self.assert_invalid(plan([node("a", paths=[r"\\server\share\file"])]), "unsafe write path")

    def test_windows_traversal_path(self) -> None:
        self.assert_invalid(plan([node("a", paths=[r"..\outside"])]), "unsafe write path")

    def test_windows_separator_relative_path(self) -> None:
        validate(plan([node("a", paths=[r"src\shared\file.rs"])]))

    def test_git_directory_is_unsafe_after_normalization(self) -> None:
        self.assert_invalid(plan([node("a", paths=[".git"])]), "unsafe write path")
        self.assert_invalid(plan([node("a", paths=["nested/../.git/config"])]), "unsafe write path")

    def test_git_prefix_name_is_safe(self) -> None:
        validate(plan([node("a", paths=[".gitfoo/config"])]))

    def test_symlink_aliases_are_not_disjoint(self) -> None:
        self.assert_invalid(
            plan(
                [
                    node("a", paths=[".claude/skills/pr-resolution-loop/SKILL.md"]),
                    node("b", paths=[".agents/skills/pr-resolution-loop/SKILL.md"]),
                ]
            ),
            "overlapping",
        )

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
