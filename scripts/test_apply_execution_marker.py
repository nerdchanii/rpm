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


REPOSITORY = "nerdchanii/rpm"
ISSUE_NUMBER = 3
SCOPE_HASH = "sha256:" + "a" * 64
VALID_KEY = MODULE.compute_idempotency_key(REPOSITORY, ISSUE_NUMBER, "p", SCOPE_HASH, "e")
MARKER = f'<!-- rpm-agent-execution: {{"approval_id":"a","executor":"cloud","lease":{{"expires_at":"2026-08-21T13:00:00Z","owner":"cloud:executor","run_id":"r"}},"plan_revision":"p","runs":[{{"event_id":"e","idempotency_key":"{VALID_KEY}","run_id":"r","status":"active"}}],"scope_hash":"{SCOPE_HASH}"}} -->'
APPROVAL_MARKER = '<!-- rpm-agent-execution: {"approval_id":"a","executor":"cloud","plan_revision":"p","scope_hash":"sha256:' + "a" * 64 + '"} -->'
APPROVAL_WITH_RUNS = APPROVAL_MARKER.replace(
    '} -->',
    f',"runs":[{{"event_id":"e","idempotency_key":"{VALID_KEY}","run_id":"r","status":"active"}}]}} -->',
)


class ApplyExecutionMarkerTests(unittest.TestCase):
    def test_appends_marker_without_changing_existing_body(self) -> None:
        body = "## Intent\n\nKeep this text.\n"
        self.assertEqual(
            MODULE.apply_marker(body, MARKER, initialization=True),
            body + MARKER + "\n",
        )

    def test_replaces_one_marker_and_preserves_surrounding_text(self) -> None:
        body = "prefix\n" + APPROVAL_MARKER + "\nsuffix\n"
        result = MODULE.apply_marker(
            body,
            MARKER,
            expected_marker=APPROVAL_MARKER,
            repository=REPOSITORY,
            issue_number=ISSUE_NUMBER,
        )
        self.assertEqual(result, "prefix\n" + MARKER + "\nsuffix\n")

    def test_approval_marker_with_prior_runs_is_a_valid_predecessor(self) -> None:
        self.assertEqual(
            MODULE.apply_marker(
                "prefix\n" + APPROVAL_WITH_RUNS + "\n",
                MARKER,
                expected_marker=APPROVAL_WITH_RUNS,
                repository=REPOSITORY,
                issue_number=ISSUE_NUMBER,
            ),
            "prefix\n" + MARKER + "\n",
        )

    def test_multiple_markers_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "multiple"):
            MODULE.apply_marker(
                APPROVAL_MARKER + "\n" + APPROVAL_MARKER,
                MARKER,
                expected_marker=APPROVAL_MARKER,
                repository=REPOSITORY,
                issue_number=ISSUE_NUMBER,
            )

    def test_missing_marker_is_rejected_for_claim_application(self) -> None:
        with self.assertRaisesRegex(ValueError, "exactly one"):
            MODULE.apply_marker(
                "body\n",
                MARKER,
                expected_marker=APPROVAL_MARKER,
                repository=REPOSITORY,
                issue_number=ISSUE_NUMBER,
            )

    def test_changed_predecessor_is_rejected(self) -> None:
        changed = APPROVAL_MARKER.replace('"plan_revision":"p"', '"plan_revision":"other"')
        with self.assertRaisesRegex(ValueError, "compare-and-set"):
            MODULE.apply_marker(
                changed + "\n",
                MARKER,
                expected_marker=APPROVAL_MARKER,
                repository=REPOSITORY,
                issue_number=ISSUE_NUMBER,
            )

    def test_full_recovery_predecessor_is_accepted(self) -> None:
        replacement = MARKER.replace('"run_id":"r"', '"run_id":"next"')
        self.assertEqual(
            MODULE.apply_marker(
                MARKER + "\n",
                replacement,
                expected_marker=MARKER,
                repository=REPOSITORY,
                issue_number=ISSUE_NUMBER,
            ),
            replacement + "\n",
        )

    def test_replacement_must_preserve_approval_metadata(self) -> None:
        for old, new in (
            ('"approval_id":"a"', '"approval_id":"other-approval"'),
            ('"plan_revision":"p"', '"plan_revision":"other-plan"'),
            ('"scope_hash":"sha256:' + "a" * 64 + '"', '"scope_hash":"sha256:' + "c" * 64 + '"'),
            ('"executor":"cloud"', '"executor":"local"'),
        ):
            with self.subTest(field=old.split(":", 1)[0]):
                replacement = MARKER.replace(old, new)
                with self.assertRaisesRegex(ValueError, "approval metadata"):
                    MODULE.apply_marker(
                        APPROVAL_MARKER + "\n",
                        replacement,
                        expected_marker=APPROVAL_MARKER,
                        repository=REPOSITORY,
                        issue_number=ISSUE_NUMBER,
                    )

    def test_initialization_rejects_existing_marker(self) -> None:
        with self.assertRaisesRegex(ValueError, "initialization"):
            MODULE.apply_marker(APPROVAL_MARKER + "\n", MARKER, initialization=True)

    def test_claim_rejects_unbound_active_run_idempotency_key(self) -> None:
        invalid = MARKER.replace(VALID_KEY, "sha256:" + "b" * 64, 1)
        with self.assertRaisesRegex(ValueError, "idempotency key"):
            MODULE.apply_marker(
                APPROVAL_MARKER + "\n",
                invalid,
                expected_marker=APPROVAL_MARKER,
                repository=REPOSITORY,
                issue_number=ISSUE_NUMBER,
            )

    def test_claim_requires_repository_and_issue_binding_context(self) -> None:
        with self.assertRaisesRegex(ValueError, "repository and issue"):
            MODULE.apply_marker(
                APPROVAL_MARKER + "\n",
                MARKER,
                expected_marker=APPROVAL_MARKER,
            )

    def test_marker_without_lease_is_rejected(self) -> None:
        invalid = MARKER.replace(
            ',"lease":{"expires_at":"2026-08-21T13:00:00Z","owner":"cloud:executor","run_id":"r"}',
            "",
        )
        with self.assertRaisesRegex(ValueError, "lease"):
            MODULE.apply_marker("body\n", invalid, initialization=True)

    def test_malformed_lease_expiry_is_rejected(self) -> None:
        invalid = MARKER.replace("2026-08-21T13:00:00Z", "tomorrow")
        with self.assertRaisesRegex(ValueError, "lease.expires_at"):
            MODULE.apply_marker("body\n", invalid, initialization=True)

    def test_malformed_historical_run_is_rejected(self) -> None:
        invalid = MARKER.replace(VALID_KEY, "invalid", 1)
        with self.assertRaisesRegex(ValueError, "runs ledger"):
            MODULE.apply_marker("body\n", invalid, initialization=True)

    def test_lease_expiry_requires_rfc3339_timezone_and_shape(self) -> None:
        for value in (
            "2026-08-21T13:00:00",
            "2026-08-21T13:00:00+0000",
            "2026-08-21T13:00:00Zsuffix",
            "2026-02-30T13:00:00Z",
        ):
            invalid = MARKER.replace("2026-08-21T13:00:00Z", value)
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "lease.expires_at"):
                    MODULE.apply_marker("body\n", invalid, initialization=True)

    def test_lease_run_must_match_active_run(self) -> None:
        invalid = MARKER.replace(
            '"run_id":"r","status":"active"}],"scope_hash"',
            '"run_id":"other","status":"active"}],"scope_hash"',
        )
        with self.assertRaisesRegex(ValueError, "lease.run_id"):
            MODULE.apply_marker("body\n", invalid, initialization=True)


if __name__ == "__main__":
    unittest.main()
