#!/usr/bin/env python3
"""Offline tests for the read-only PR event intake.

The fake adapter below is deliberately the boundary of these tests.  It does
not emulate a Cloud task, a GitHub write, a workflow run, or a real Actions
credential; it only supplies snapshots to the pure evaluator.
"""

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


# Keep the repository validation gate from creating an untracked __pycache__.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "inspect_codex_pr_event", Path(__file__).with_name("inspect-codex-pr-event.py")
)
assert spec is not None and spec.loader is not None
inspector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspector)


REPOSITORY = "nerdchanii/rpm"
BASE = "a" * 40
HEAD = "b" * 40
OLD_HEAD = "c" * 40

POLICY = {
    "version": 3,
    "repository": REPOSITORY,
    "labels": {
        "research": "agent:research",
        "ready": "agent:ready",
        "claimed": "agent:claimed",
        "review-pending": "agent:review-pending",
        "awaiting-merge": "agent:awaiting-merge",
        "blocked": "agent:blocked",
    },
    "merge_gate": {
        "enabled": True,
        "source_state": "awaiting-merge",
        "required_checks": ["metadata", "verify"],
        "required_mergeable": True,
        "forbid_unresolved_p0_p1": True,
        "method": "squash",
        "delete_branch": True,
    },
}


def connection(nodes, *, has_next=False):
    return {"pageInfo": {"hasNextPage": has_next, "endCursor": None}, "nodes": nodes}


def event(name="pull_request_target", *, head=HEAD, number=7):
    if name in {"pull_request_target", "pull_request_review"}:
        return {
            "repository": {"full_name": REPOSITORY},
            "pull_request": {"number": number, "head": {"sha": head}},
        }
    if name == "workflow_run":
        return {
            "repository": {"full_name": REPOSITORY},
            "workflow_run": {"head_sha": head, "pull_requests": [{"number": number}]},
        }
    return {"repository": {"full_name": REPOSITORY}}


def pull_request(
    *,
    head=HEAD,
    head_repository=REPOSITORY,
    draft=False,
    reviews=None,
    unresolved=False,
    closing_issues=None,
    mergeable="MERGEABLE",
):
    return {
        "number": 7,
        "state": "OPEN",
        "isDraft": draft,
        "mergeable": mergeable,
        "baseRefName": "main",
        "headRefName": "feature",
        "baseRefOid": BASE,
        "headRefOid": head,
        "baseRepository": {"nameWithOwner": REPOSITORY},
        "headRepository": {"nameWithOwner": head_repository},
        "labels": connection([]),
        "closingIssuesReferences": connection(
            [{"number": 42, "repository": {"nameWithOwner": REPOSITORY}}]
            if closing_issues is None
            else closing_issues
        ),
        "reviews": connection([] if reviews is None else reviews),
        "reviewThreads": connection([]),
        "unresolved_p0_p1": unresolved,
    }


def issue(*, state="OPEN", labels=("agent:review-pending",), closing_prs=None):
    return {
        "number": 42,
        "state": state,
        "repository": {"nameWithOwner": REPOSITORY},
        "labels": connection([{"name": label} for label in labels]),
        "closing_prs": [
            {
                "number": number,
                "state": "OPEN",
                "draft": False,
                "repository": REPOSITORY,
            }
            for number in (closing_prs if closing_prs is not None else [7])
        ],
    }


def checks(*, head=HEAD, metadata="SUCCESS", verify="SUCCESS"):
    return {
        "head_sha": head,
        "contexts": connection(
            [
                {"__typename": "CheckRun", "name": "metadata", "conclusion": metadata},
                {"__typename": "CheckRun", "name": "verify", "conclusion": verify},
            ]
        ),
    }


class FakeGitHub:
    """Read snapshots only; any attempted mutation would have no method."""

    def __init__(self, pr, issue_value=None, checks_value=None):
        self.pr = copy.deepcopy(pr)
        self.issue_value = copy.deepcopy(issue_value)
        self.checks_value = copy.deepcopy(checks_value or checks())
        self.calls = []

    def get_pull_request(self, repository, number):
        self.calls.append(("pull_request", repository, number))
        return copy.deepcopy(self.pr)

    def get_issue(self, repository, number):
        self.calls.append(("issue", repository, number))
        if self.issue_value is None:
            raise AssertionError("unexpected issue read")
        return copy.deepcopy(self.issue_value)

    def get_checks(self, repository, head_sha):
        self.calls.append(("checks", repository, head_sha))
        return copy.deepcopy(self.checks_value)


def evaluate(fake, name="pull_request_target", *, payload=None, pr_number=None):
    return inspector.inspect_event(
        payload or event(name), name, POLICY, fake, pr_number=pr_number
    )


class EventIntakeTests(unittest.TestCase):
    def test_opened_without_automatic_review_is_no_work(self):
        fake = FakeGitHub(pull_request(), issue(), checks())
        result = evaluate(fake)
        self.assertEqual(result["status"], "no-work")
        self.assertEqual(result["route"], "no-work")
        self.assertEqual(result["reason"], "review-not-arrived")
        self.assertEqual(result["issue"], 42)
        self.assertEqual(result["current_head"], {"sha": HEAD, "ref": "feature", "repository": REPOSITORY})
        self.assertIn(("checks", REPOSITORY, HEAD), fake.calls)

    def test_synchronize_with_codex_review_routes_to_resolution(self):
        review = {"author": {"login": "chatgpt-codex-connector"}, "state": "COMMENTED"}
        fake = FakeGitHub(pull_request(reviews=[review]), issue(), checks())
        result = evaluate(fake, payload=event(head=OLD_HEAD))
        self.assertEqual(result["status"], "ready")
        self.assertEqual(result["route"], "pr-review-resolution")
        self.assertEqual(result["next"], "pr-review-resolution")
        self.assertTrue(result["head_stale"])
        self.assertEqual(result["current_head_sha"], HEAD)

    def test_pull_request_review_arrival_uses_current_head(self):
        review = {"author": {"login": "chatgpt-codex-connector[bot]"}, "state": "COMMENTED"}
        fake = FakeGitHub(pull_request(reviews=[review]), issue(), checks())
        result = evaluate(fake, "pull_request_review", payload=event("pull_request_review"))
        self.assertEqual(result["route"], "pr-review-resolution")
        self.assertIn(("checks", REPOSITORY, HEAD), fake.calls)

    def test_workflow_run_with_no_pull_requests_is_healthy_no_work(self):
        fake = FakeGitHub(pull_request(), issue(), checks())
        payload = event("workflow_run")
        payload["workflow_run"]["pull_requests"] = []
        result = evaluate(fake, "workflow_run", payload=payload)
        self.assertEqual(result["status"], "no-work")
        self.assertEqual(result["reason"], "workflow-run-without-pull-request")
        self.assertEqual(fake.calls, [])

    def test_workflow_run_stale_head_is_refetched_and_re_evaluated(self):
        fake = FakeGitHub(pull_request(), issue(), checks())
        result = evaluate(fake, "workflow_run", payload=event("workflow_run", head=OLD_HEAD))
        self.assertTrue(result["head_stale"])
        self.assertEqual(result["current_head"], {"sha": HEAD, "ref": "feature", "repository": REPOSITORY})
        self.assertEqual(result["reason"], "review-not-arrived")
        self.assertIn(("checks", REPOSITORY, HEAD), fake.calls)

    def test_pending_required_checks_keep_merge_owner_as_next(self):
        fake = FakeGitHub(
            pull_request(), issue(labels=("agent:awaiting-merge",)), checks(verify="PENDING")
        )
        result = evaluate(fake)
        self.assertEqual(result["status"], "no-work")
        self.assertEqual(result["route"], "no-work")
        self.assertEqual(result["reason"], "checks-pending")
        self.assertEqual(result["next"], "merge-gatekeeper")
        self.assertFalse(result["merge_authorized"])
        self.assertEqual(result["preliminary"]["select_merge"]["data"]["status"], "no-work")

    def test_current_head_required_checks_can_pass_gate(self):
        fake = FakeGitHub(
            pull_request(), issue(labels=("agent:awaiting-merge",)), checks()
        )
        result = evaluate(fake, payload=event(head=OLD_HEAD))
        self.assertEqual(result["status"], "ready")
        self.assertEqual(result["route"], "merge-gatekeeper")
        self.assertEqual(result["next"], "merge-gatekeeper")
        self.assertFalse(result["merge_authorized"])
        self.assertTrue(result["head_stale"])
        self.assertEqual(result["preliminary"]["select_merge"]["data"]["status"], "merge")

    def test_workflow_dispatch_requires_and_uses_explicit_pr_number(self):
        fake = FakeGitHub(pull_request(), issue(), checks())
        result = evaluate(
            fake,
            "workflow_dispatch",
            payload=event("workflow_dispatch"),
            pr_number=7,
        )
        self.assertEqual(result["pr"], 7)
        self.assertEqual(result["reason"], "review-not-arrived")

    def test_fork_head_fails_closed(self):
        fake = FakeGitHub(
            pull_request(head_repository="someone/rpm"), issue(), checks()
        )
        result = evaluate(fake)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason"], "head-repository-mismatch")
        self.assertFalse(result["same_repository"])
        self.assertEqual(fake.calls, [("pull_request", REPOSITORY, 7)])

    def test_draft_pr_is_not_routed(self):
        fake = FakeGitHub(pull_request(draft=True), issue(), checks())
        result = evaluate(fake)
        self.assertEqual(result["status"], "no-work")
        self.assertEqual(result["reason"], "draft-pr")
        self.assertEqual(fake.calls, [("pull_request", REPOSITORY, 7)])

    def test_invalid_event_repository_is_rejected_before_github_reads(self):
        fake = FakeGitHub(pull_request(), issue(), checks())
        payload = event()
        payload["repository"]["full_name"] = "other/repository"
        result = evaluate(fake, payload=payload)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason"], "event-repository-mismatch")
        self.assertEqual(fake.calls, [])

    def test_truncated_closing_issue_connection_fails_closed(self):
        pr = pull_request()
        pr["closingIssuesReferences"] = connection(
            [{"number": 42, "repository": {"nameWithOwner": REPOSITORY}}], has_next=True
        )
        fake = FakeGitHub(pr, issue(), checks())
        result = evaluate(fake)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason"], "closing-issues-truncated")

    def test_truncated_required_checks_fail_closed(self):
        fake = FakeGitHub(
            pull_request(), issue(labels=("agent:awaiting-merge",)),
            {"contexts": connection([], has_next=True)},
        )
        result = evaluate(fake)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason"], "check-contexts-truncated")

    def test_missing_status_rollup_is_pending_until_checks_exist(self):
        adapter = inspector.GhReadAdapter()
        adapter._graphql = lambda query, **variables: {
            "repository": {
                "object": {
                    "__typename": "Commit",
                    "oid": HEAD,
                    "statusCheckRollup": None,
                }
            }
        }
        evidence = adapter.get_checks(REPOSITORY, HEAD)
        self.assertEqual(evidence["contexts"]["pageInfo"]["hasNextPage"], False)
        self.assertEqual(evidence["contexts"]["nodes"], [])
        fake = FakeGitHub(
            pull_request(), issue(labels=("agent:awaiting-merge",)), evidence
        )
        result = evaluate(fake)
        self.assertEqual(result["status"], "no-work")
        self.assertEqual(result["reason"], "checks-pending")

    def test_multiple_closing_issues_fail_closed(self):
        pr = pull_request(
            closing_issues=[
                {"number": 42, "repository": {"nameWithOwner": REPOSITORY}},
                {"number": 43, "repository": {"nameWithOwner": REPOSITORY}},
            ]
        )
        fake = FakeGitHub(pr, issue(), checks())
        result = evaluate(fake)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason"], "multiple-closing-issues")

    def test_multiple_open_closing_prs_fail_closed(self):
        fake = FakeGitHub(
            pull_request(), issue(labels=("agent:awaiting-merge",), closing_prs=[7, 8]), checks()
        )
        result = evaluate(fake)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason"], "multiple-open-closing-prs")

    def test_existing_untracked_pr_requires_authorized_adoption(self):
        pr = pull_request(closing_issues=[])
        fake = FakeGitHub(pr, None, checks())
        result = evaluate(fake)
        self.assertEqual(result["status"], "no-work")
        self.assertEqual(result["route"], "publication-state-pending")
        self.assertEqual(result["reason"], "authorized-adoption-required")
        self.assertEqual(result["next"], "authorized-adoption-required")
        self.assertEqual(result["source_state"], "untracked")
        self.assertEqual(result["evidence"]["required_checks"], {"metadata": "success", "verify": "success"})
        self.assertEqual(
            fake.calls,
            [("pull_request", REPOSITORY, 7), ("checks", REPOSITORY, HEAD)],
        )

    def test_claimed_source_waits_for_publication_without_label_write(self):
        fake = FakeGitHub(
            pull_request(), issue(labels=("agent:claimed",)), checks()
        )
        result = evaluate(fake)
        self.assertEqual(result["route"], "publication-state-pending")
        self.assertEqual(result["reason"], "publication-state-pending")
        self.assertIsNone(result["next"])
        self.assertEqual(result["source_state"], "claimed")
        self.assertNotIn("labels", result)
        self.assertEqual(fake.calls.count(("issue", REPOSITORY, 42)), 1)

    def test_gate_result_is_guidance_and_contains_both_existing_verdicts(self):
        fake = FakeGitHub(
            pull_request(), issue(labels=("agent:awaiting-merge",)), checks()
        )
        result = evaluate(fake)
        self.assertEqual(result["route"], "merge-gatekeeper")
        self.assertIn("select_review", result["preliminary"])
        self.assertIn("select_merge", result["preliminary"])
        self.assertEqual(result["preliminary"]["select_merge"]["type"], "merge_gate_contract")
        self.assertFalse(result["merge_authorized"])

    def test_duplicate_required_check_contexts_fail_closed(self):
        duplicate = {
            "head_sha": HEAD,
            "contexts": connection(
                [
                    {"name": "metadata", "conclusion": "SUCCESS"},
                    {"name": "metadata", "conclusion": "SUCCESS"},
                    {"name": "verify", "conclusion": "SUCCESS"},
                ]
            ),
        }
        fake = FakeGitHub(pull_request(), issue(labels=("agent:awaiting-merge",)), duplicate)
        result = evaluate(fake)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason"], "ambiguous-required-checks")

    def test_outdated_unresolved_p0_thread_remains_gate_evidence(self):
        pr = pull_request()
        pr["reviewThreads"] = connection(
            [
                {
                    "isResolved": False,
                    "isOutdated": True,
                    "comments": connection([{"body": "P1: still requires a fix"}]),
                }
            ]
        )
        pr["unresolved_p0_p1"] = None
        fake = FakeGitHub(pr, issue(labels=("agent:awaiting-merge",)), checks())
        result = evaluate(fake)
        self.assertEqual(result["evidence"]["unresolved_p0_p1"], True)
        self.assertEqual(result["preliminary"]["select_merge"]["data"]["reason"], "review-findings-remain")

    def test_cli_emits_json_for_workflow_run_without_pull_request(self):
        with tempfile.TemporaryDirectory() as directory:
            event_path = Path(directory) / "event.json"
            policy_path = Path(directory) / "policy.json"
            event_path.write_text(json.dumps(event("workflow_run"), sort_keys=True))
            event_data = json.loads(event_path.read_text())
            event_data["workflow_run"]["pull_requests"] = []
            event_path.write_text(json.dumps(event_data, sort_keys=True))
            policy_path.write_text(json.dumps(POLICY, sort_keys=True))
            completed = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("inspect-codex-pr-event.py")),
                    "--event-file",
                    str(event_path),
                    "--event-name",
                    "workflow_run",
                    "--policy",
                    str(policy_path),
                ],
                text=True,
                capture_output=True,
                check=False,
                env={**__import__("os").environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(json.loads(completed.stdout)["reason"], "workflow-run-without-pull-request")


if __name__ == "__main__":
    unittest.main()
