#!/usr/bin/env python3
"""Regression tests for deterministic RPM execution metadata generation."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("create-execution-metadata.py")
SPEC = importlib.util.spec_from_file_location("create_execution_metadata", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


BODY = """## Context

Queue work.

## Initial scope

- Claim one issue.
- Preserve ordinary labels.

## Done criteria

- Lease and idempotency data are persisted.
"""


class ExecutionMetadataTests(unittest.TestCase):
    def test_metadata_is_deterministic_and_contains_marker(self) -> None:
        first = MODULE.create_metadata("42", BODY, "cloud")
        second = MODULE.create_metadata("42", BODY, "cloud")
        self.assertEqual(first, second)
        metadata = first["data"]["metadata"]
        self.assertEqual(metadata["executor"], "cloud")
        self.assertRegex(metadata["scope_hash"], r"^sha256:[0-9a-f]{64}$")
        self.assertTrue(metadata["approval_id"].endswith(metadata["plan_revision"].removeprefix("plan-")))
        self.assertIn("rpm-agent-execution", first["data"]["marker"])

    def test_scope_change_changes_revision_and_hash(self) -> None:
        changed = BODY.replace("Claim one issue.", "Claim two issues.")
        original = MODULE.create_metadata("42", BODY, "cloud")["data"]["metadata"]
        revised = MODULE.create_metadata("42", changed, "cloud")["data"]["metadata"]
        self.assertNotEqual(original["plan_revision"], revised["plan_revision"])
        self.assertNotEqual(original["scope_hash"], revised["scope_hash"])

    def test_missing_scope_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "Done criteria"):
            MODULE.create_metadata("42", "## Initial scope\n\nScope.", "cloud")

    def test_invalid_executor_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "executor"):
            MODULE.create_metadata("42", BODY, "github-actions")


if __name__ == "__main__":
    unittest.main()
