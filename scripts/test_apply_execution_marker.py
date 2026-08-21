#!/usr/bin/env python3
"""Regression tests for safe execution-marker updates."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("apply-execution-marker.py")
SPEC = importlib.util.spec_from_file_location("apply_execution_marker", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


MARKER = '<!-- rpm-agent-execution: {"approval_id":"a","executor":"cloud","lease":{"expires_at":"2026-08-21T13:00:00Z","owner":"cloud:executor","run_id":"r"},"plan_revision":"p","runs":[{"event_id":"e","idempotency_key":"sha256:' + "b" * 64 + '","run_id":"r","status":"active"}],"scope_hash":"sha256:' + "a" * 64 + '"} -->'


class ApplyExecutionMarkerTests(unittest.TestCase):
    def test_appends_marker_without_changing_existing_body(self) -> None:
        body = "## Intent\n\nKeep this text.\n"
        self.assertEqual(MODULE.apply_marker(body, MARKER), body + MARKER + "\n")

    def test_replaces_one_marker_and_preserves_surrounding_text(self) -> None:
        old = MARKER.replace('"status":"active"', '"status":"old"')
        body = "prefix\n" + old + "\nsuffix\n"
        result = MODULE.apply_marker(body, MARKER)
        self.assertEqual(result, "prefix\n" + MARKER + "\nsuffix\n")

    def test_multiple_markers_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "multiple"):
            MODULE.apply_marker(MARKER + "\n" + MARKER, MARKER)

    def test_marker_without_lease_is_rejected(self) -> None:
        invalid = MARKER.replace(
            ',"lease":{"expires_at":"2026-08-21T13:00:00Z","owner":"cloud:executor","run_id":"r"}',
            "",
        )
        with self.assertRaisesRegex(ValueError, "lease"):
            MODULE.apply_marker("body\n", invalid)


if __name__ == "__main__":
    unittest.main()
