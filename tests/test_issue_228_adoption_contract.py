#!/usr/bin/env python3
"""Deterministic contract tests for issue #228 existing-PR adoption."""

from __future__ import annotations

import base64
import copy
import contextlib
import hashlib
import io
import json
import runpy
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from unittest import mock
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / ".agents/workflows/backlog-policy.json"
QUEUE_CHECK = ROOT / "scripts/check-cloud-queue-contract.py"
MERGE_CHECK = ROOT / "scripts/check-merge-gate.py"
MUTATION_HELPER = ROOT / "scripts/authorize-existing-pr-adoption-mutation.py"
ADOPTION_WRITER = ROOT / "scripts/write-existing-pr-adoption.py"
ADOPTION_MATERIALIZER = ROOT / "scripts/materialize-existing-pr-adoption.py"
TOOL_POLICY = ROOT / ".codex/hooks/agent_tool_policy.py"
ADOPTION_FIXTURE = (
    ROOT / "tests/fixtures/agent-workflow/existing-pr-adoption.json"
)
LIFECYCLE_FIXTURE = ROOT / "tests/fixtures/agent-workflow/lifecycle-edges.json"
DEPENDENT_FIXTURE = (
    ROOT / "tests/fixtures/agent-workflow/dependent-pr-retarget.json"
)

HEAD_SHA = "b" * 40
BASE_SHA = "a" * 40
LEDGER_MARKER = "<!-- rpm-agent-adoption:v1 -->"
LEDGER_AUTHOR = "nerdchanii"
TERMINAL_P2 = {
    "already-addressed",
    "defer-follow-up",
    "residual-risk",
    "reject-out-of-scope",
}

CANONICAL_ARRAY_ORDER = {
    "authorization.closing_issues": ("repository", "number"),
    "evidence.issue.labels": ("$value",),
    "evidence.issue.closing_prs": ("$value",),
    "evidence.pr.closing_issues": ("repository", "number"),
    "evidence.checks.records": ("name", "workflow_run_id"),
    "evidence.review.automatic_reviews.records": (
        "submitted_at",
        "actor",
        "reviewed_head_sha",
    ),
    "evidence.review.reactions.records": ("created_at", "actor", "content"),
    "evidence.findings.items": ("severity", "id"),
    "evidence.writers.records": (
        "kind",
        "repository",
        "issue",
        "pr",
        "run_id",
    ),
    "evidence.dependent_prs.records": ("number",),
}


def canonicalize(value: object, path: str = "") -> object:
    if isinstance(value, dict):
        return {
            key: canonicalize(value[key], f"{path}.{key}" if path else key)
            for key in sorted(value)
        }
    if isinstance(value, list):
        normalized = [canonicalize(item, path) for item in value]
        fields = CANONICAL_ARRAY_ORDER.get(path)
        if fields is None:
            return normalized

        def key(item: object) -> tuple[str, ...]:
            if fields == ("$value",) or not isinstance(item, dict):
                return (json.dumps(item, ensure_ascii=False, sort_keys=True),)
            return (
                *(str(item.get(field, "")) for field in fields),
                json.dumps(
                    canonicalize(item, path),
                    ensure_ascii=False,
                    sort_keys=True,
                    separators=(",", ":"),
                ),
            )

        return sorted(normalized, key=key)
    return value


def canonical_digest(value: object) -> str:
    root_path = ""
    if isinstance(value, dict) and {
        "repository",
        "issue",
        "pr",
        "checks",
        "review",
        "findings",
        "writers",
    }.issubset(value):
        root_path = "evidence"
        value = copy.deepcopy(value)
        writers = value.get("writers")
        if isinstance(writers, dict):
            if "observed_at" in writers:
                writers["observed_at"] = "<observation-time>"
            records = writers.get("records")
            if isinstance(records, list):
                stable_records = [
                    copy.deepcopy(record)
                    for record in records
                    if not isinstance(record, dict)
                    or record.get("kind") != "adoption"
                ]
                stable_records.sort(
                    key=lambda record: json.dumps(
                        canonicalize(record, "evidence.writers.records"),
                        ensure_ascii=False,
                        sort_keys=True,
                        separators=(",", ":"),
                    )
                )
                writers["records"] = stable_records
                writers["count"] = len(stable_records)
                token_payload = json.dumps(
                    canonicalize(
                        {
                            "repository": writers.get("repository"),
                            "records": stable_records,
                        }
                    ),
                    ensure_ascii=False,
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode("utf-8")
                writers["cas_token"] = (
                    "sha256:" + hashlib.sha256(token_payload).hexdigest()
                )
    payload = json.dumps(
        canonicalize(value, root_path),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return f"sha256:{hashlib.sha256(payload).hexdigest()}"


def reverse_object_keys(value: object) -> object:
    if isinstance(value, dict):
        return {
            key: reverse_object_keys(value[key])
            for key in reversed(list(value.keys()))
        }
    if isinstance(value, list):
        return [reverse_object_keys(item) for item in value]
    return value


class FakeGithubAdoptionTransport:
    """Independent deterministic live source with compare-and-write CAS."""

    def __init__(self, state: dict[str, object]) -> None:
        self.state = copy.deepcopy(state)
        self.mutations: list[tuple[str, str]] = []
        self.before_write = None

    def read(
        self, repository: str, issue: int, pr: int
    ) -> dict[str, object]:
        authorization = self.state["authorization"]
        if (
            repository != authorization["repository"]
            or issue != authorization["issue"]
            or pr != authorization["pr"]
        ):
            raise AssertionError("writer read the wrong adoption target")
        return {
            "state": copy.deepcopy(self.state),
            "cas": canonical_digest(self.state),
        }

    def compare_and_write(
        self,
        repository: str,
        issue: int,
        pr: int,
        expected_cas: str,
        mutation: dict[str, object],
    ) -> dict[str, object]:
        if self.before_write is not None:
            callback = self.before_write
            self.before_write = None
            callback(self.state)
        authorization = self.state["authorization"]
        if (
            repository != authorization["repository"]
            or issue != authorization["issue"]
            or pr != authorization["pr"]
            or expected_cas != canonical_digest(self.state)
        ):
            return {"status": "cas-mismatch"}
        kind = mutation.get("kind")
        if kind == "append-writer-lease-comment":
            record = copy.deepcopy(mutation.get("record"))
            if not isinstance(record, dict):
                return {"status": "invalid-mutation"}
            record["source_comment_id"] = 80001 + len(
                self.state["evidence"]["writers"]["records"]
            )
            writers = self.state["evidence"]["writers"]
            writers["records"].append(record)
            writers["records"].sort(
                key=lambda item: json.dumps(item, sort_keys=True, separators=(",", ":"))
            )
            writers["count"] = len(writers["records"])
            writers["cas_token"] = canonical_digest(
                {
                    "repository": record["repository"],
                    "records": writers["records"],
                }
            )
            self.mutations.append(("append-writer-lease-comment", str(record["run_id"])))
        elif kind == "append-ledger-comment":
            record = copy.deepcopy(mutation.get("record"))
            if not isinstance(record, dict):
                return {"status": "invalid-mutation"}
            record["comment_id"] = 81001 + len(
                self.state["ledger"]["comments"]
            )
            self.state["ledger"]["comments"].append(record)
            self.mutations.append(("append-ledger-comment", str(record["phase"])))
        elif kind == "add-lifecycle-label":
            if mutation.get("mode") != "add-only":
                return {"status": "invalid-mutation"}
            label = str(mutation.get("label"))
            labels = set(str(item) for item in self.state["live"]["issue_labels"])
            labels.add(label)
            self.state["live"]["issue_labels"] = sorted(labels)
            self.state["live"]["lifecycle_state"] = "review-pending"
            self.mutations.append(("add-lifecycle-label", label))
        else:
            return {"status": "invalid-mutation"}
        return {"status": "applied", "cas": canonical_digest(self.state)}


class FakeGithubApiRunner:
    """Stateful, real-shaped GitHub API responses for the narrow transport."""

    def __init__(self, fixture: dict[str, object]) -> None:
        self.fixture = copy.deepcopy(fixture)
        self.labels = set(self.fixture["evidence"]["issue"]["labels"])
        self.comments: list[dict[str, object]] = []
        self.writes: list[tuple[str, object]] = []
        self.next_comment_id = 81001
        self.pr_updated_at = "2026-08-25T12:00:00Z"
        self.timeline_events: list[dict[str, object]] = []

    def __call__(
        self, argv: list[str], input_text: str | None = None
    ) -> tuple[int, str, str]:
        if argv[:3] == ["gh", "api", "graphql"]:
            payload = {
                "data": {
                    "repository": {
                        "issue": {
                            "closedByPullRequestsReferences": {
                                "nodes": [
                                    {
                                        "number": 210,
                                        "repository": {
                                            "nameWithOwner": "nerdchanii/rpm"
                                        },
                                    }
                                ],
                                "pageInfo": {"hasNextPage": False},
                            }
                        },
                        "pullRequest": {
                            "closingIssuesReferences": {
                                "nodes": [
                                    {
                                        "number": 145,
                                        "repository": {
                                            "nameWithOwner": "nerdchanii/rpm"
                                        },
                                    }
                                ],
                                "pageInfo": {"hasNextPage": False},
                            }
                        },
                    }
                }
            }
            return 0, json.dumps(payload), ""

        if argv[:2] != ["gh", "api"] or len(argv) < 3:
            return 2, "", "unexpected command"
        endpoint = argv[2]
        method = argv[argv.index("--method") + 1]
        route = endpoint.split("?", 1)[0]
        payload = json.loads(input_text) if input_text is not None else None

        if method == "POST":
            if route.endswith("/comments"):
                assert isinstance(payload, dict)
                response = {
                    "id": self.next_comment_id,
                    "body": payload["body"],
                    "user": {"login": LEDGER_AUTHOR},
                }
                self.next_comment_id += 1
                self.comments.append(copy.deepcopy(response))
                self.writes.append(("comment", payload["body"]))
                return 0, json.dumps(response), ""
            if route.endswith("/labels"):
                assert isinstance(payload, dict)
                requested = payload.get("labels")
                assert requested == ["agent:review-pending"]
                self.labels.update(requested)
                self.writes.append(("labels", copy.deepcopy(requested)))
                response = [{"name": label} for label in sorted(self.labels)]
                return 0, json.dumps(response), ""
            return 2, "", f"unexpected POST endpoint: {endpoint}"

        if route == "repos/nerdchanii/rpm/issues/145":
            response = {
                "number": 145,
                "state": "open",
                "repository_url": "https://api.github.com/repos/nerdchanii/rpm",
                "repository": {"full_name": "nerdchanii/rpm"},
                "labels": [{"name": label} for label in sorted(self.labels)],
            }
        elif route == "repos/nerdchanii/rpm/pulls/210":
            head_repository = self.fixture["evidence"]["pr"]["head"][
                "repository"
            ]
            response = {
                "number": 210,
                "state": "open",
                "draft": False,
                "updated_at": self.pr_updated_at,
                "base": {
                    "ref": "main",
                    "sha": BASE_SHA,
                    "repo": {"full_name": "nerdchanii/rpm"},
                },
                "head": {
                    "ref": "feat/issue-145-workspaces",
                    "sha": HEAD_SHA,
                    "repo": {"full_name": head_repository},
                },
            }
        elif route == "repos/nerdchanii/rpm/issues/145/comments":
            response = copy.deepcopy(self.comments)
        elif route == f"repos/nerdchanii/rpm/commits/{HEAD_SHA}":
            response = {
                "sha": HEAD_SHA,
                "commit": {
                    "author": {"date": "2026-08-25T12:00:00Z"},
                    "committer": {"date": "2026-08-25T12:00:00Z"},
                },
            }
        elif route == "repos/nerdchanii/rpm/issues/210/timeline":
            response = copy.deepcopy(self.timeline_events)
        elif route == f"repos/nerdchanii/rpm/commits/{HEAD_SHA}/check-runs":
            response = {
                "total_count": 2,
                "check_runs": [
                    {
                        "id": 41001,
                        "name": "metadata",
                        "conclusion": "success",
                        "app": {"slug": "github-actions"},
                    },
                    {
                        "id": 41002,
                        "name": "verify",
                        "conclusion": "success",
                        "app": {"slug": "github-actions"},
                    },
                ],
            }
        elif route == "repos/nerdchanii/rpm/pulls/210/reviews":
            response = [
                {
                    "user": {"login": "chatgpt-codex-connector"},
                    "submitted_at": "2026-08-25T12:10:00Z",
                    "commit_id": HEAD_SHA,
                    "state": "COMMENTED",
                }
            ]
        elif route == "repos/nerdchanii/rpm/issues/210/reactions":
            response = []
        else:
            return 2, "", f"unexpected GET endpoint: {endpoint}"
        return 0, json.dumps(response), ""


class RacingLifecycleLabelApiRunner(FakeGithubApiRunner):
    """Inject an external lifecycle label at the label-write boundary."""

    def __init__(
        self,
        fixture: dict[str, object],
        external_label: str,
        *,
        compensation_fails: bool = False,
    ) -> None:
        super().__init__(fixture)
        self.external_label = external_label
        self.compensation_fails = compensation_fails
        self.race_injected = False
        self.calls: list[tuple[str, str]] = []

    def __call__(
        self, argv: list[str], input_text: str | None = None
    ) -> tuple[int, str, str]:
        if (
            argv[:3] != ["gh", "api", "graphql"]
            and argv[:2] == ["gh", "api"]
            and len(argv) >= 3
        ):
            endpoint = argv[2]
            method = argv[argv.index("--method") + 1]
            route = endpoint.split("?", 1)[0]
            self.calls.append((method, route))
            if method == "POST" and route.endswith("/labels"):
                self.labels.add(self.external_label)
                self.race_injected = True
            if method == "DELETE" and "/labels/" in route:
                label = route.rsplit("/", 1)[-1].replace("%3A", ":")
                self.writes.append(("delete-label", label))
                if self.compensation_fails:
                    return 500, "", "deterministic compensation failure"
                self.labels.discard(label)
                response = [
                    {"name": current} for current in sorted(self.labels)
                ]
                return 200, json.dumps(response), ""
        return super().__call__(argv, input_text)


class AdoptionContractTest(unittest.TestCase):
    maxDiff = None

    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture_bytes = ADOPTION_FIXTURE.read_bytes()

    @classmethod
    def tearDownClass(cls) -> None:
        if ADOPTION_FIXTURE.read_bytes() != cls.fixture_bytes:
            raise AssertionError("the immutable adoption fixture was modified")

    def load_adoption(self) -> dict[str, object]:
        return json.loads(ADOPTION_FIXTURE.read_text())

    def load_policy(self) -> dict[str, object]:
        return json.loads(POLICY.read_text())

    def live_collectors(
        self, fixture: dict[str, object]
    ) -> dict[str, object]:
        evidence = fixture["evidence"]
        values = {
            "execution": evidence["execution"],
            "findings": evidence["findings"],
            "writers": evidence["writers"],
            "dependent_prs": evidence["dependent_prs"],
            "observation_time": fixture["now"],
        }

        def collector(value: object):
            return lambda repository, issue, pr: copy.deepcopy(value)

        return {name: collector(value) for name, value in values.items()}

    def resign(self, fixture: dict[str, object]) -> None:
        fixture["authorization"]["evidence_digest"] = canonical_digest(
            fixture["evidence"]
        )

    def write_json(self, directory: Path, name: str, value: object) -> Path:
        path = directory / name
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        )
        return path

    def run_json_command(
        self,
        command: list[str],
        expected_codes: set[int] = {0, 1},
        input_text: str | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
        result = subprocess.run(
            command,
            cwd=ROOT,
            input=input_text,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertIn(
            result.returncode,
            expected_codes,
            msg=f"unexpected exit {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        self.assertTrue(
            lines,
            msg=f"command emitted no JSON\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        try:
            event = json.loads(lines[-1])
        except json.JSONDecodeError as error:
            self.fail(f"last stdout line is not JSON: {error}\n{result.stdout}")
        self.assertIsInstance(event, dict)
        self.assertIsInstance(event.get("data"), dict)
        return result, event

    def run_queue(
        self,
        fixture: dict[str, object],
        operation: str = "adopt-existing-pr",
        policy: dict[str, object] | None = None,
        fixture_override: dict[str, object] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
        with tempfile.TemporaryDirectory(prefix="rpm-issue-228-") as raw:
            directory = Path(raw)
            fixture_path = self.write_json(
                directory, "fixture.json", fixture_override or fixture
            )
            policy_path = POLICY
            if policy is not None:
                policy_path = self.write_json(directory, "policy.json", policy)
            return self.run_json_command(
                [
                    "python3",
                    str(QUEUE_CHECK),
                    "--policy",
                    str(policy_path),
                    "--issues-file",
                    str(fixture_path),
                    "--operation",
                    operation,
                ],
                {0, 1},
            )

    def run_transition(
        self,
        fixture: dict[str, object],
        *,
        issue: int,
        before: str,
        after: str,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
        with tempfile.TemporaryDirectory(prefix="rpm-transition-228-") as raw:
            fixture_path = self.write_json(Path(raw), "fixture.json", fixture)
            return self.run_json_command(
                [
                    "python3",
                    str(QUEUE_CHECK),
                    "--policy",
                    str(POLICY),
                    "--issues-file",
                    str(fixture_path),
                    "--operation",
                    "transition",
                    "--issue",
                    str(issue),
                    "--from-state",
                    before,
                    "--to-state",
                    after,
                ],
                {0, 1},
            )

    def assert_blocked(
        self, result: subprocess.CompletedProcess[str], event: dict[str, object]
    ) -> dict[str, object]:
        data = event["data"]
        self.assertEqual(result.returncode, 1, data)
        self.assertEqual(data.get("status"), "blocked", data)
        self.assertIsInstance(data.get("reason"), str, data)
        self.assertNotIn("labels", data)
        self.assertNotIn("label_mutation", data)
        self.assertNotIn("mutation", data)
        self.assertNotIn("merge", data)
        return data

    def assert_adoptable(
        self, result: subprocess.CompletedProcess[str], event: dict[str, object]
    ) -> dict[str, object]:
        data = event["data"]
        self.assertEqual(result.returncode, 0, data)
        self.assertEqual(data.get("status"), "adopt", data)
        self.assertEqual(data.get("issue"), 145, data)
        self.assertEqual(data.get("pr"), 210, data)
        self.assertEqual(data.get("before"), "untracked", data)
        self.assertEqual(data.get("after"), "review-pending", data)
        mutation = data.get("label_mutation")
        if mutation is not None:
            self.assertIsInstance(mutation, dict, data)
            self.assertEqual(mutation.get("mode"), "add-only", data)
            self.assertEqual(mutation.get("add"), ["agent:review-pending"], data)
            self.assertEqual(mutation.get("remove"), [], data)
        self.assertEqual(data.get("preserved_labels"), ["documentation"], data)
        return data

    def test_policy_exposes_only_the_dedicated_operation(self) -> None:
        policy = self.load_policy()
        contract = policy.get("existing_pr_adoption")
        self.assertIsInstance(contract, dict)
        self.assertEqual(policy.get("version"), 4)
        self.assertEqual(contract.get("operation"), "adopt-existing-pr")
        self.assertEqual(contract.get("operation_version"), 1)
        self.assertEqual(contract.get("owner"), "rpm_existing_pr_adopter")
        self.assertEqual(contract.get("from_state"), "untracked")
        self.assertEqual(contract.get("to_state"), "review-pending")
        self.assertEqual(contract.get("batch_limit"), 1)
        self.assertEqual(
            set(contract.get("p2_terminal_dispositions", [])), TERMINAL_P2
        )
        self.assertEqual(
            contract.get("approved_plus_one_actors"),
            ["chatgpt-codex-connector"],
        )
        self.assertEqual(
            contract.get("required_checks"), ["metadata", "verify"]
        )
        self.assertEqual(
            contract.get("canonical_array_order"),
            {path: list(fields) for path, fields in CANONICAL_ARRAY_ORDER.items()},
        )
        self.assertEqual(
            contract.get("ledger"),
            {
                "namespace": "rpm-agent-adoption",
                "marker": LEDGER_MARKER,
                "approved_authors": [LEDGER_AUTHOR],
                "phases": [
                    "prepared",
                    "label-mutation",
                    "committed",
                    "reconciled",
                ],
            },
        )
        self.assertNotIn(
            "review-pending", policy["allowed_transitions"]["untracked"]
        )
        self.assertNotIn(
            "awaiting-merge", policy["allowed_transitions"]["untracked"]
        )
        self.assertEqual(policy["merge_gate"]["batch_limit"], 1)
        self.assertFalse(policy["project"]["required_for_execution"])

    def transition_fixture(self, source: str) -> dict[str, object]:
        fixture = self.load_adoption()
        policy = self.load_policy()
        labels = policy["labels"]
        ordinary = ["documentation"]
        fixture["issues"] = [
            {
                "number": 145,
                "url": "https://github.com/nerdchanii/rpm/issues/145",
                "state": "OPEN",
                "labels": (
                    ordinary
                    if source == "untracked"
                    else [*ordinary, labels[source]]
                ),
                "closing_prs": [],
            }
        ]
        return fixture

    def test_generic_transition_executes_only_policy_allowed_edges(self) -> None:
        policy = self.load_policy()
        allowed = {
            (source, target)
            for source, targets in policy["allowed_transitions"].items()
            for target in targets
        }
        states = {"untracked", *policy["labels"]}
        for before, after in sorted(allowed):
            with self.subTest(verdict="allowed", before=before, after=after):
                result, event = self.run_transition(
                    self.transition_fixture(before),
                    issue=145,
                    before=before,
                    after=after,
                )
                self.assertEqual(result.returncode, 0, event)
                self.assertEqual(event["data"].get("status"), "transition", event)

        for before in sorted(states):
            for after in sorted(policy["labels"]):
                if (before, after) in allowed:
                    continue
                with self.subTest(verdict="denied", before=before, after=after):
                    result, event = self.run_transition(
                        self.transition_fixture(before),
                        issue=145,
                        before=before,
                        after=after,
                    )
                    data = self.assert_blocked(result, event)
                    self.assertEqual(data.get("reason"), "transition-not-allowed", data)

        for before in ("ready", "claimed"):
            result, event = self.run_transition(
                self.transition_fixture(before),
                issue=145,
                before=before,
                after="awaiting-merge",
            )
            data = self.assert_blocked(result, event)
            self.assertEqual(data.get("reason"), "transition-not-allowed", data)

    def test_eligible_fixture_uses_canonical_utf8_json_sha256(self) -> None:
        fixture = self.load_adoption()
        self.assertEqual(
            fixture["authorization"]["evidence_digest"],
            canonical_digest(fixture["evidence"]),
        )
        result, event = self.run_queue(fixture)
        self.assert_adoptable(result, event)

    def test_canonical_digest_uses_only_field_specific_array_ordering(self) -> None:
        first = self.load_adoption()
        first["evidence"]["findings"]["items"] = [
            {
                "id": "P2-b",
                "source_id": "thread-b",
                "head_sha": HEAD_SHA,
                "severity": "P2",
                "disposition": "already-addressed",
                "owner": "issue-228",
                "rationale": "fixture b",
            },
            {
                "id": "P2-a",
                "source_id": "thread-a",
                "head_sha": HEAD_SHA,
                "severity": "P2",
                "disposition": "already-addressed",
                "owner": "issue-228",
                "rationale": "fixture a",
            },
        ]
        first["evidence"]["findings"]["count"] = 2
        second = copy.deepcopy(first)
        second["evidence"]["checks"]["records"].reverse()
        second["evidence"]["findings"]["items"].reverse()
        self.assertEqual(
            canonical_digest(first["evidence"]),
            canonical_digest(second["evidence"]),
        )

        tie_first = self.load_adoption()
        tie_first["evidence"]["findings"]["items"] = [
            self.p2(
                "already-addressed",
                owner="issue-228",
                rationale="source a",
                id="P2-same",
                source_id="thread-a",
            ),
            self.p2(
                "already-addressed",
                owner="issue-228",
                rationale="source b",
                id="P2-same",
                source_id="thread-b",
            ),
        ]
        tie_first["evidence"]["findings"]["count"] = 2
        tie_second = copy.deepcopy(tie_first)
        tie_second["evidence"]["findings"]["items"].reverse()
        self.assertEqual(
            canonical_digest(tie_first["evidence"]),
            canonical_digest(tie_second["evidence"]),
        )

        for fixture in (first, second):
            self.resign(fixture)
            result, event = self.run_queue(fixture)
            self.assertEqual(result.returncode, 0, event)
            self.assertEqual(event["data"].get("status"), "adopt", event)

        fixture["evidence"] = reverse_object_keys(fixture["evidence"])
        result, event = self.run_queue(fixture)
        self.assert_adoptable(result, event)

    def test_every_authorization_tuple_field_is_exact_and_non_null(self) -> None:
        mutations = {
            "repository": lambda value: value.__setitem__("repository", "other/rpm"),
            "issue": lambda value: value.__setitem__("issue", 146),
            "pr": lambda value: value.__setitem__("pr", 211),
            "base-repository": lambda value: value["base"].__setitem__(
                "repository", "other/rpm"
            ),
            "base-ref": lambda value: value["base"].__setitem__("ref", "develop"),
            "base-sha": lambda value: value["base"].__setitem__("sha", "d" * 40),
            "head-repository": lambda value: value["head"].__setitem__(
                "repository", "fork/rpm"
            ),
            "head-ref": lambda value: value["head"].__setitem__(
                "ref", "feat/other"
            ),
            "head-sha": lambda value: value["head"].__setitem__("sha", "e" * 40),
            "closing-set": lambda value: value.__setitem__(
                "closing_issues",
                [{"repository": "nerdchanii/rpm", "number": 146}],
            ),
            "policy-version": lambda value: value.__setitem__("policy_version", 3),
            "operation-version": lambda value: value.__setitem__(
                "operation_version", 2
            ),
            "digest": lambda value: value.__setitem__(
                "evidence_digest", "sha256:" + "0" * 64
            ),
            "approval-id": lambda value: value.__setitem__(
                "approval_id", "other-approval"
            ),
            "plan-revision": lambda value: value.__setitem__(
                "plan_revision", "other-plan"
            ),
            "scope-hash": lambda value: value.__setitem__(
                "scope_hash", "sha256:" + "1" * 64
            ),
            "executor-null": lambda value: value.__setitem__("executor", None),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                fixture = self.load_adoption()
                mutate(fixture["authorization"])
                result, event = self.run_queue(fixture)
                self.assert_blocked(result, event)

    def test_live_identity_closing_set_and_cas_are_refetched(self) -> None:
        variants = []
        fixture = self.load_adoption()
        fixture["evidence"]["pr"]["closing_issues_complete"] = False
        self.resign(fixture)
        variants.append(("closing-read-partial", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["pr"]["closing_issues"].append(
            {"repository": "nerdchanii/rpm", "number": 146}
        )
        self.resign(fixture)
        fixture["authorization"]["closing_issues"] = copy.deepcopy(
            fixture["evidence"]["pr"]["closing_issues"]
        )
        variants.append(("ambiguous-closing-set", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["issue"]["closing_prs"].append(211)
        self.resign(fixture)
        variants.append(("competing-closing-pr", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["pr"]["state"] = "CLOSED"
        self.resign(fixture)
        variants.append(("closed-pr", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["pr"]["is_draft"] = True
        self.resign(fixture)
        variants.append(("draft-pr", fixture))

        fixture = self.load_adoption()
        fixture["live"]["head_sha"] = "f" * 40
        variants.append(("head-cas", fixture))

        fixture = self.load_adoption()
        fixture["live"]["base_sha"] = "f" * 40
        variants.append(("base-cas", fixture))

        fixture = self.load_adoption()
        fixture["live"]["lifecycle_state"] = "ready"
        variants.append(("lifecycle-cas", fixture))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_queue(fixture)
                self.assert_blocked(result, event)

    def test_fork_head_repository_is_bound_without_rejecting_adoption(self) -> None:
        fixture = self.load_adoption()
        fork_repository = "contributor/rpm"
        fixture["authorization"]["head"]["repository"] = fork_repository
        fixture["evidence"]["pr"]["head"]["repository"] = fork_repository
        self.resign(fixture)

        result, event = self.run_queue(fixture)
        data = self.assert_adoptable(result, event)
        self.assertEqual(data.get("phase"), "prepared", data)

        namespace = runpy.run_path(str(ADOPTION_WRITER))
        writer = namespace.get("execute_adoption_phase")
        github_transport = namespace.get("GithubAdoptionTransport")
        self.assertTrue(callable(writer), namespace.keys())
        self.assertTrue(callable(github_transport), namespace.keys())
        api = FakeGithubApiRunner(fixture)
        transport = github_transport(
            snapshot=fixture,
            runner=api,
            approved_marker_actors=frozenset({"nerdchanii"}),
            collectors=self.live_collectors(fixture),
        )
        writer_result = writer(self.load_policy(), fixture, transport)
        self.assertEqual(writer_result.get("status"), "applied", writer_result)
        live_state = transport.read("nerdchanii/rpm", 145, 210)["state"]
        self.assertEqual(
            live_state["evidence"]["pr"]["head"]["repository"],
            fork_repository,
        )

    def test_checks_are_complete_current_head_provenanced_and_unique(self) -> None:
        variants = []
        for field, value in (
            ("source", "unknown-source"),
            ("pagination_complete", False),
            ("has_next_page", True),
            ("count", 3),
        ):
            fixture = self.load_adoption()
            fixture["evidence"]["checks"][field] = value
            self.resign(fixture)
            variants.append((f"collection-{field}", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["checks"]["read_complete"] = False
        self.resign(fixture)
        variants.append(("partial-read", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["checks"]["head_sha"] = "c" * 40
        self.resign(fixture)
        variants.append(("summary-wrong-head", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["checks"]["records"][0]["head_sha"] = "c" * 40
        self.resign(fixture)
        variants.append(("record-wrong-head", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["checks"]["records"][0].pop("workflow_run_id")
        self.resign(fixture)
        variants.append(("missing-provenance", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["checks"]["records"].append(
            copy.deepcopy(fixture["evidence"]["checks"]["records"][0])
        )
        fixture["evidence"]["checks"]["count"] = 3
        self.resign(fixture)
        variants.append(("duplicate-name", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["checks"]["records"][1]["conclusion"] = "failure"
        self.resign(fixture)
        variants.append(("failed", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["checks"]["records"] = fixture["evidence"][
            "checks"
        ]["records"][:1]
        self.resign(fixture)
        variants.append(("missing-required", fixture))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_queue(fixture)
                self.assert_blocked(result, event)

        third_party = self.load_adoption()
        third_party_record = {
            "name": "coverage-app",
            "conclusion": "success",
            "head_sha": HEAD_SHA,
            "source": "third-party-app",
            "workflow_run_id": 91001,
        }
        third_party["evidence"]["checks"]["records"].append(third_party_record)
        third_party["evidence"]["checks"]["count"] = 3
        self.resign(third_party)
        result, event = self.run_queue(third_party)
        self.assert_adoptable(result, event)

        fixture = self.load_adoption()
        failed_duplicate = copy.deepcopy(
            fixture["evidence"]["checks"]["records"][1]
        )
        failed_duplicate["conclusion"] = "failure"
        failed_duplicate["workflow_run_id"] = 41999
        fixture["evidence"]["checks"]["records"].append(failed_duplicate)
        fixture["evidence"]["checks"]["count"] = 3
        self.resign(fixture)
        result, event = self.run_queue(fixture)
        self.assert_blocked(result, event)

        fixture["evidence"]["checks"]["records"].pop()
        self.resign(fixture)
        result, event = self.run_queue(fixture)
        self.assert_blocked(result, event)

    def use_plus_one(
        self,
        fixture: dict[str, object],
        *,
        actor: str = "chatgpt-codex-connector",
        created_at: str = "2026-08-25T12:10:00Z",
        deleted: bool = False,
    ) -> None:
        review = fixture["evidence"]["review"]
        review["automatic_reviews"]["records"] = []
        review["automatic_reviews"]["count"] = 0
        review["reactions"]["records"] = [
            {
                "content": "+1",
                "actor": actor,
                "created_at": created_at,
                "head_sha": HEAD_SHA,
                "deleted": deleted,
            }
        ]
        review["reactions"]["count"] = 1
        self.resign(fixture)

    def test_review_is_current_or_an_approved_post_head_plus_one(self) -> None:
        fixture = self.load_adoption()
        self.use_plus_one(fixture)
        result, event = self.run_queue(fixture)
        self.assert_adoptable(result, event)

        ordinary_push = self.load_adoption()
        self.use_plus_one(ordinary_push)
        ordinary_push["evidence"]["review"]["head_updated_at"] = (
            "2026-08-25T13:00:00Z"
        )
        self.resign(ordinary_push)
        result, event = self.run_queue(ordinary_push)
        data = self.assert_blocked(result, event)
        self.assertEqual(data.get("reason"), "current-head-review-missing", data)

        variants = []
        for collection in ("automatic_reviews", "reactions"):
            for field, value in (
                ("source", "unknown-source"),
                ("head_sha", "c" * 40),
                ("read_complete", False),
                ("pagination_complete", False),
                ("has_next_page", True),
                (
                    "count",
                    2
                    if collection == "automatic_reviews"
                    else 1,
                ),
            ):
                fixture = self.load_adoption()
                fixture["evidence"]["review"][collection][field] = value
                self.resign(fixture)
                variants.append((f"{collection}-{field}", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["review"]["automatic_reviews"]["read_complete"] = False
        self.resign(fixture)
        variants.append(("review-read-failure", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["review"]["automatic_reviews"]["records"][0][
            "reviewed_head_sha"
        ] = "c" * 40
        self.resign(fixture)
        variants.append(("review-wrong-head", fixture))

        fixture = self.load_adoption()
        self.use_plus_one(fixture, actor="unapproved-user")
        variants.append(("wrong-actor", fixture))

        fixture = self.load_adoption()
        self.use_plus_one(fixture, created_at="2026-08-25T11:59:59Z")
        variants.append(("pre-head", fixture))

        fixture = self.load_adoption()
        self.use_plus_one(fixture, deleted=True)
        variants.append(("deleted", fixture))

        fixture = self.load_adoption()
        fixture["evidence"]["review"]["automatic_reviews"]["records"] = []
        fixture["evidence"]["review"]["automatic_reviews"]["count"] = 0
        fixture["evidence"]["review"]["reactions"]["records"] = []
        fixture["evidence"]["review"]["reactions"]["count"] = 0
        self.resign(fixture)
        variants.append(("missing", fixture))

        fixture = self.load_adoption()
        self.use_plus_one(fixture)
        fixture["evidence"]["review"]["reactions"]["read_complete"] = False
        self.resign(fixture)
        variants.append(("reaction-read-failure", fixture))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_queue(fixture)
                self.assert_blocked(result, event)

    def test_review_scans_all_automatic_records_before_accepting_a_clean_signal(self) -> None:
        for records in (
            [
                {
                    "actor": "chatgpt-codex-connector",
                    "submitted_at": "2026-08-25T12:10:00Z",
                    "reviewed_head_sha": HEAD_SHA,
                    "state": "COMMENTED",
                    "finding_count": 0,
                },
                {
                    "actor": "chatgpt-codex-connector",
                    "submitted_at": "2026-08-25T12:10:00Z",
                    "reviewed_head_sha": HEAD_SHA,
                    "state": "COMMENTED",
                    "finding_count": 1,
                },
            ],
            [
                {
                    "actor": "chatgpt-codex-connector",
                    "submitted_at": "2026-08-25T12:10:00Z",
                    "reviewed_head_sha": HEAD_SHA,
                    "state": "COMMENTED",
                    "finding_count": 1,
                },
                {
                    "actor": "chatgpt-codex-connector",
                    "submitted_at": "2026-08-25T12:10:00Z",
                    "reviewed_head_sha": HEAD_SHA,
                    "state": "COMMENTED",
                    "finding_count": 0,
                },
            ],
        ):
            with self.subTest(records=records):
                fixture = self.load_adoption()
                fixture["evidence"]["review"]["automatic_reviews"]["records"] = records
                fixture["evidence"]["review"]["automatic_reviews"]["count"] = len(records)
                self.resign(fixture)
                result, event = self.run_queue(fixture)
                data = self.assert_blocked(result, event)
                self.assertEqual(data.get("reason"), "automatic-review-duplicate", data)

    def p2(self, disposition: str, **extra: object) -> dict[str, object]:
        finding = {
            "id": "P2-fixture",
            "source_id": "review-thread-P2-fixture",
            "head_sha": HEAD_SHA,
            "severity": "P2",
            "disposition": disposition,
            **extra,
        }
        return finding

    def test_finding_dispositions_are_complete_and_terminal(self) -> None:
        accepted = [
            self.p2(
                "already-addressed",
                owner="issue-228",
                rationale="covered by the current-head fixture",
            ),
            self.p2(
                "defer-follow-up",
                owner="issue-229",
                follow_up_issue=229,
            ),
            self.p2(
                "defer-follow-up",
                owner="workflow-owner",
                follow_up_creation_authority="not-authorized",
            ),
            self.p2(
                "residual-risk",
                owner="platform-owner",
                rationale="external reaction availability is fail-closed",
            ),
            self.p2(
                "reject-out-of-scope",
                owner="issue-229",
                rationale="the threat class is outside this operation",
            ),
        ]
        for finding in accepted:
            with self.subTest(disposition=finding["disposition"], finding=finding):
                fixture = self.load_adoption()
                fixture["evidence"]["findings"]["items"] = [finding]
                fixture["evidence"]["findings"]["count"] = 1
                self.resign(fixture)
                result, event = self.run_queue(fixture)
                self.assert_adoptable(result, event)

        p3 = {
            "id": "P3-fixture",
            "source_id": "review-thread-P3-fixture",
            "head_sha": HEAD_SHA,
            "severity": "P3",
        }
        fixture = self.load_adoption()
        fixture["evidence"]["findings"]["items"] = [p3]
        fixture["evidence"]["findings"]["count"] = 1
        self.resign(fixture)
        result, event = self.run_queue(fixture)
        self.assert_adoptable(result, event)

        rejected = [
            self.p2("accept-now", owner="issue-228", rationale="still open"),
            self.p2("residual-risk", rationale="missing owner"),
            self.p2("residual-risk", owner="platform-owner"),
            self.p2("reject-out-of-scope", owner="issue-229"),
            self.p2("defer-follow-up", owner="workflow-owner"),
            self.p2(
                "defer-follow-up",
                owner="workflow-owner",
                follow_up_issue=True,
            ),
            self.p2(
                "defer-follow-up",
                owner="workflow-owner",
                follow_up_issue=0,
            ),
            self.p2(
                "defer-follow-up",
                owner="workflow-owner",
                follow_up_issue=-1,
            ),
            {"id": "P1-open", "severity": "P1", "disposition": "accept-now"},
        ]
        for finding in rejected:
            with self.subTest(rejected=finding):
                fixture = self.load_adoption()
                fixture["evidence"]["findings"]["items"] = [finding]
                fixture["evidence"]["findings"]["count"] = 1
                self.resign(fixture)
                result, event = self.run_queue(fixture)
                self.assert_blocked(result, event)

        fixture = self.load_adoption()
        fixture["evidence"]["findings"]["read_complete"] = False
        self.resign(fixture)
        result, event = self.run_queue(fixture)
        self.assert_blocked(result, event)

    def test_findings_inventory_binds_head_source_completeness_and_identity(self) -> None:
        variants: list[tuple[str, dict[str, object]]] = []
        for field, value in (
            ("source", "unknown-source"),
            ("head_sha", "c" * 40),
            ("read_complete", False),
            ("pagination_complete", False),
            ("has_next_page", True),
            ("count", 1),
        ):
            fixture = self.load_adoption()
            fixture["evidence"]["findings"][field] = value
            self.resign(fixture)
            variants.append((field, fixture))

        for missing in ("id", "source_id", "head_sha"):
            fixture = self.load_adoption()
            finding = self.p2(
                "already-addressed",
                owner="issue-228",
                rationale="covered by fixture",
            )
            finding.pop(missing)
            fixture["evidence"]["findings"]["items"] = [finding]
            fixture["evidence"]["findings"]["count"] = 1
            self.resign(fixture)
            variants.append((f"missing-{missing}", fixture))

        fixture = self.load_adoption()
        finding = self.p2(
            "already-addressed",
            owner="issue-228",
            rationale="covered by fixture",
        )
        fixture["evidence"]["findings"]["items"] = [finding, copy.deepcopy(finding)]
        fixture["evidence"]["findings"]["count"] = 2
        self.resign(fixture)
        variants.append(("duplicate-stable-identity", fixture))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_queue(fixture)
                self.assert_blocked(result, event)

    def test_review_thread_finding_markers_require_a_trusted_actor_and_identity(
        self,
    ) -> None:
        namespace = runpy.run_path(str(ADOPTION_WRITER))
        github_transport = namespace.get("GithubAdoptionTransport")
        self.assertTrue(callable(github_transport), namespace.keys())
        finder = github_transport._finding_from_thread

        def thread(
            *,
            actor: str,
            source_id: str = "thread-P2-fixture",
            disposition: str = "residual-risk",
            marker_count: int = 1,
            marker_head_sha: str | None = HEAD_SHA,
            resolved: bool = False,
        ) -> dict[str, object]:
            marker = {
                "id": "P2-fixture",
                "source_id": source_id,
                "severity": "P2",
                "disposition": disposition,
                "owner": "issue-229",
                "rationale": "deterministic review-thread fixture",
            }
            if marker_head_sha is not None:
                marker["head_sha"] = marker_head_sha
            body = (
                "<!-- rpm-agent-finding:v1: "
                + json.dumps(marker, sort_keys=True, separators=(",", ":"))
                + " -->"
            )
            comments = [
                {
                    "id": f"comment-{index}",
                    "author": {"login": actor},
                    "body": body,
                }
                for index in range(marker_count)
            ]
            return {
                "id": "thread-P2-fixture",
                "isResolved": resolved,
                "comments": {
                    "nodes": comments,
                    "pageInfo": {"hasNextPage": False, "endCursor": None},
                },
            }

        trusted = finder(thread(actor=LEDGER_AUTHOR), HEAD_SHA)
        self.assertEqual(trusted.get("source_id"), "thread-P2-fixture", trusted)
        self.assertEqual(trusted.get("thread_id"), "thread-P2-fixture", trusted)
        self.assertEqual(trusted.get("severity"), "P2", trusted)
        self.assertEqual(trusted.get("disposition"), "residual-risk", trusted)

        with self.assertRaisesRegex(RuntimeError, "missing|ambiguous"):
            finder(thread(actor="attacker"), HEAD_SHA)
        self.assertIsNone(
            finder(thread(actor="attacker", resolved=True), HEAD_SHA)
        )
        with self.assertRaisesRegex(RuntimeError, "head"):
            finder(thread(actor=LEDGER_AUTHOR, marker_head_sha="c" * 40), HEAD_SHA)
        with self.assertRaisesRegex(RuntimeError, "incomplete"):
            finder(thread(actor=LEDGER_AUTHOR, marker_head_sha=None), HEAD_SHA)
        with self.assertRaisesRegex(RuntimeError, "identity|source|thread"):
            finder(
                thread(actor=LEDGER_AUTHOR, source_id="forged-other-thread"),
                HEAD_SHA,
            )
        with self.assertRaisesRegex(RuntimeError, "missing|ambiguous"):
            finder(thread(actor=LEDGER_AUTHOR, marker_count=0), HEAD_SHA)
        with self.assertRaisesRegex(RuntimeError, "missing|ambiguous"):
            finder(thread(actor=LEDGER_AUTHOR, marker_count=2), HEAD_SHA)

    def writer(
        self,
        fixture: dict[str, object],
        *,
        kind: str,
        run_id: str,
        owner: str,
        expires_at: str,
    ) -> dict[str, object]:
        record = {
            "kind": kind,
            "repository": "nerdchanii/rpm",
            "issue": 145,
            "pr": 210,
            "run_id": run_id,
            "owner": owner,
            "lease_expires_at": expires_at,
            "head_sha": HEAD_SHA,
        }
        if kind == "adoption":
            record["source_comment_id"] = 80001
        return record

    def install_current_adoption_lease(
        self,
        fixture: dict[str, object],
        *,
        source_comment_id: int = 80001,
        expires_at: str = "2026-08-25T13:00:00Z",
    ) -> None:
        record = self.writer(
            fixture,
            kind="adoption",
            run_id="adopt-run-001",
            owner="rpm_existing_pr_adopter",
            expires_at=expires_at,
        )
        record["source_comment_id"] = source_comment_id
        self.set_writers(fixture, [record])

    def set_writers(
        self, fixture: dict[str, object], records: list[dict[str, object]]
    ) -> None:
        writers = fixture["evidence"]["writers"]
        writers["records"] = records
        writers["count"] = len(records)
        writers["cas_token"] = f"writer-inventory-{len(records)}-fixture"
        self.resign(fixture)

    def test_repository_global_writer_inventory_is_complete_and_cas_bound(self) -> None:
        for kind in ("claim", "implementation", "review-resolution", "adoption"):
            with self.subTest(active_kind=kind):
                fixture = self.load_adoption()
                record = self.writer(
                    fixture,
                    kind=kind,
                    run_id="other-run",
                    owner="other-owner",
                    expires_at="2026-08-25T13:00:00Z",
                )
                self.set_writers(fixture, [record])
                result, event = self.run_queue(fixture)
                self.assert_blocked(result, event)

        fixture = self.load_adoption()
        record = self.writer(
            fixture,
            kind="adoption",
            run_id="adopt-run-001",
            owner="rpm_existing_pr_adopter",
            expires_at="2026-08-25T13:00:00Z",
        )
        self.set_writers(fixture, [record])
        result, event = self.run_queue(fixture)
        self.assert_adoptable(result, event)

        fixture = self.load_adoption()
        current = self.writer(
            fixture,
            kind="adoption",
            run_id="adopt-run-001",
            owner="rpm_existing_pr_adopter",
            expires_at="2026-08-25T13:00:00Z",
        )
        contender = self.writer(
            fixture,
            kind="adoption",
            run_id="other-run",
            owner="rpm_existing_pr_adopter",
            expires_at="2026-08-25T13:00:00Z",
        )
        current["source_comment_id"] = 80001
        contender["source_comment_id"] = 80002
        self.set_writers(fixture, [contender, current])
        result, event = self.run_queue(fixture)
        self.assert_adoptable(result, event)

        current["source_comment_id"] = 80003
        contender["source_comment_id"] = 80002
        self.set_writers(fixture, [current, contender])
        result, event = self.run_queue(fixture)
        self.assert_blocked(result, event)

        fixture = self.load_adoption()
        record = self.writer(
            fixture,
            kind="implementation",
            run_id="expired-run",
            owner="old-owner",
            expires_at="2026-08-25T12:00:00Z",
        )
        self.set_writers(fixture, [record])
        result, event = self.run_queue(fixture)
        self.assert_adoptable(result, event)

        fixture["evidence"]["writers"]["records"][0]["run_id"] = "changed-after-cas"
        result, event = self.run_queue(fixture)
        self.assert_blocked(result, event)

        for field, bad_value in (
            ("source", "unknown-source"),
            ("read_complete", False),
            ("pagination_complete", False),
            ("has_next_page", True),
            ("count", 3),
            ("cas_token", ""),
        ):
            with self.subTest(incomplete=field):
                fixture = self.load_adoption()
                fixture["evidence"]["writers"][field] = bad_value
                self.resign(fixture)
                result, event = self.run_queue(fixture)
                self.assert_blocked(result, event)

    def test_writer_observation_time_and_same_run_exemption_are_exactly_bound(self) -> None:
        fixture = self.load_adoption()
        fixture["now"] = "2026-08-25T14:00:00Z"
        result, event = self.run_queue(fixture)
        self.assert_blocked(result, event)

        for field, value in (
            ("issue", 146),
            ("pr", 211),
            ("head_sha", "c" * 40),
        ):
            with self.subTest(field=field):
                fixture = self.load_adoption()
                record = self.writer(
                    fixture,
                    kind="adoption",
                    run_id="adopt-run-001",
                    owner="rpm_existing_pr_adopter",
                    expires_at="2026-08-25T13:00:00Z",
                )
                record[field] = value
                self.set_writers(fixture, [record])
                result, event = self.run_queue(fixture)
                self.assert_blocked(result, event)

    def ledger_record(
        self,
        fixture: dict[str, object],
        phase: str,
        *,
        comment_id: int = 81001,
        author: str = LEDGER_AUTHOR,
        marker: str = LEDGER_MARKER,
        run_id: str = "adopt-run-001",
    ) -> dict[str, object]:
        prepared_document = {
            "schema": "rpm-existing-pr-adoption-prepared-v1",
            "authorization": copy.deepcopy(fixture["authorization"]),
            "evidence": copy.deepcopy(fixture["evidence"]),
        }
        return {
            "comment_id": comment_id,
            "author": author,
            "marker": marker,
            "namespace": "rpm-agent-adoption",
            "run_id": run_id,
            "phase": phase,
            "repository": fixture["authorization"]["repository"],
            "issue": fixture["authorization"]["issue"],
            "pr": fixture["authorization"]["pr"],
            "head_sha": fixture["authorization"]["head"]["sha"],
            "evidence_digest": fixture["authorization"]["evidence_digest"],
            "prepared_document": prepared_document,
            "prepared_document_digest": canonical_digest(prepared_document),
        }

    def set_adopted_live_state(self, fixture: dict[str, object]) -> None:
        fixture["live"]["issue_labels"] = [
            "agent:review-pending",
            "documentation",
        ]
        fixture["live"]["lifecycle_state"] = "review-pending"

    def test_ledger_phase_progression_and_every_interruption_is_retry_safe(self) -> None:
        fixture = self.load_adoption()
        result, event = self.run_queue(fixture)
        data = self.assert_adoptable(result, event)
        self.assertEqual(data.get("phase"), "prepared")
        self.assertEqual(data.get("ledger_action", {}).get("phase"), "prepared", data)
        self.assertNotIn("label_mutation", data)
        self.assertNotIn("mutation_request", data)

        fixture = self.load_adoption()
        fixture["ledger"]["comments"] = [self.ledger_record(fixture, "prepared")]
        result, event = self.run_queue(fixture)
        data = self.assert_adoptable(result, event)
        self.assertEqual(data.get("phase"), "label-mutation")
        self.assertEqual(
            data.get("ledger_action", {}).get("phase"), "label-mutation", data
        )
        self.assertNotIn("label_mutation", data)
        self.assertNotIn("mutation_request", data)

        fixture = self.load_adoption()
        fixture["ledger"]["comments"] = [
            self.ledger_record(fixture, "prepared", comment_id=81001),
            self.ledger_record(fixture, "label-mutation", comment_id=81002),
        ]
        result, event = self.run_queue(fixture)
        data = self.assert_adoptable(result, event)
        self.assertEqual(data.get("phase"), "label-mutation")
        self.assertIsInstance(data.get("mutation_request"), dict, data)

        fixture = self.load_adoption()
        fixture["ledger"]["comments"] = [
            self.ledger_record(fixture, "prepared", comment_id=81001),
            self.ledger_record(fixture, "label-mutation", comment_id=81002),
        ]
        self.set_adopted_live_state(fixture)
        result, event = self.run_queue(fixture)
        data = event["data"]
        self.assertEqual(result.returncode, 0, data)
        self.assertEqual(data.get("phase"), "committed", data)
        self.assertNotIn("label_mutation", data)

        fixture = self.load_adoption()
        fixture["ledger"]["comments"] = [
            self.ledger_record(fixture, "prepared", comment_id=81001),
            self.ledger_record(fixture, "label-mutation", comment_id=81002),
            self.ledger_record(fixture, "committed", comment_id=81003),
        ]
        self.set_adopted_live_state(fixture)
        result, event = self.run_queue(fixture)
        data = event["data"]
        self.assertEqual(result.returncode, 0, data)
        self.assertEqual(data.get("status"), "reconciled", data)
        self.assertEqual(data.get("phase"), "reconciled", data)
        self.assertNotIn("label_mutation", data)

    def test_ledger_prepared_document_compare_uses_canonical_evidence_order(self) -> None:
        fixture = self.load_adoption()
        record = self.ledger_record(fixture, "prepared")
        document = record["prepared_document"]
        document["evidence"]["checks"]["records"].reverse()
        record["prepared_document_digest"] = canonical_digest(document)
        fixture["ledger"]["comments"] = [record]

        result, event = self.run_queue(fixture)
        data = self.assert_adoptable(result, event)
        self.assertEqual(data.get("phase"), "label-mutation", data)
        self.assertNotIn("mutation_request", data)

    def test_equivalent_concurrent_ledger_phase_comments_reconcile(self) -> None:
        fixture = self.load_adoption()
        first = self.ledger_record(fixture, "prepared", comment_id=81001)
        second = copy.deepcopy(first)
        second["comment_id"] = 81002
        fixture["ledger"]["comments"] = [second, first]

        result, event = self.run_queue(fixture)
        data = self.assert_adoptable(result, event)
        self.assertEqual(data.get("phase"), "label-mutation", data)
        self.assertEqual(
            data.get("ledger_action", {}).get("phase"), "label-mutation", data
        )

    def test_prepared_only_ledger_cannot_commit_an_external_lifecycle_label(
        self,
    ) -> None:
        fixture = self.load_adoption()
        fixture["ledger"]["comments"] = [
            self.ledger_record(fixture, "prepared", comment_id=81001)
        ]
        self.set_adopted_live_state(fixture)

        first_result, first_event = self.run_queue(fixture)
        second_result, second_event = self.run_queue(fixture)
        first = self.assert_blocked(first_result, first_event)
        self.assertEqual(first_event, second_event)
        self.assertEqual(first_result.returncode, second_result.returncode)
        self.assertIn(
            first.get("reason"),
            {"ledger-live-state-conflict", "wiring-blocked"},
            first,
        )
        for key in (
            "ledger_action",
            "label_mutation",
            "mutation_request",
            "mutation",
        ):
            self.assertNotIn(key, first)
        self.assertEqual(
            [record["phase"] for record in fixture["ledger"]["comments"]],
            ["prepared"],
        )

        authorized = self.load_adoption()
        authorized["ledger"]["comments"] = [
            self.ledger_record(authorized, "prepared", comment_id=81001),
            self.ledger_record(
                authorized, "label-mutation", comment_id=81002
            ),
        ]
        self.set_adopted_live_state(authorized)
        result, event = self.run_queue(authorized)
        data = self.assert_adoptable(result, event)
        self.assertEqual(data.get("phase"), "committed", data)
        self.assertEqual(
            data.get("ledger_action", {}).get("phase"), "committed", data
        )

    def test_ledger_rejects_incomplete_stale_or_ambiguous_records(self) -> None:
        variants = []
        fixture = self.load_adoption()
        fixture["ledger"]["read_complete"] = False
        variants.append(("read-incomplete", fixture))

        fixture = self.load_adoption()
        fixture["ledger"]["pagination_complete"] = False
        variants.append(("pagination-incomplete", fixture))

        for field in (
            "comment_id",
            "author",
            "marker",
            "run_id",
            "evidence_digest",
        ):
            fixture = self.load_adoption()
            record = self.ledger_record(fixture, "prepared")
            record.pop(field)
            fixture["ledger"]["comments"] = [record]
            variants.append((f"missing-{field}", fixture))

        fixture = self.load_adoption()
        fixture["ledger"]["comments"] = [
            self.ledger_record(fixture, "prepared", author="attacker")
        ]
        variants.append(("wrong-author", fixture))

        fixture = self.load_adoption()
        fixture["ledger"]["comments"] = [
            self.ledger_record(fixture, "prepared", marker="<!-- forged -->")
        ]
        variants.append(("wrong-marker", fixture))

        fixture = self.load_adoption()
        fixture["ledger"]["comments"] = [
            self.ledger_record(fixture, "prepared", comment_id=81001),
            self.ledger_record(
                fixture,
                "prepared",
                comment_id=81002,
                run_id="conflicting-run",
            ),
        ]
        variants.append(("multiple-prepared", fixture))

        fixture = self.load_adoption()
        fixture["ledger"]["comments"] = [
            self.ledger_record(fixture, "committed", comment_id=81001),
            self.ledger_record(
                fixture,
                "committed",
                comment_id=81002,
                run_id="conflicting-run",
            ),
        ]
        self.set_adopted_live_state(fixture)
        variants.append(("multiple-committed", fixture))

        fixture = self.load_adoption()
        record = self.ledger_record(fixture, "prepared")
        record["head_sha"] = "c" * 40
        fixture["ledger"]["comments"] = [record]
        variants.append(("stale-head", fixture))

        for phase in ("label-mutation", "committed", "reconciled"):
            fixture = self.load_adoption()
            fixture["ledger"]["comments"] = [
                self.ledger_record(fixture, phase, comment_id=81002)
            ]
            if phase in {"committed", "reconciled"}:
                self.set_adopted_live_state(fixture)
            variants.append((f"{phase}-without-prior-phases", fixture))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_queue(fixture)
                self.assert_blocked(result, event)

    def test_terminal_reconciled_exact_replay_is_idempotent(self) -> None:
        fixture = self.load_adoption()
        fixture["ledger"]["comments"] = [
            self.ledger_record(fixture, phase, comment_id=81001 + index)
            for index, phase in enumerate(
                ("prepared", "label-mutation", "committed", "reconciled")
            )
        ]
        self.set_adopted_live_state(fixture)

        first_result, first_event = self.run_queue(fixture)
        second_result, second_event = self.run_queue(fixture)
        self.assertEqual(first_result.returncode, 0, first_event)
        self.assertEqual(second_result.returncode, 0, second_event)
        self.assertEqual(first_event, second_event)
        self.assertEqual(first_event["data"].get("status"), "reconciled")
        self.assertEqual(first_event["data"].get("phase"), "reconciled")
        for key in ("label_mutation", "mutation_request", "ledger_action"):
            self.assertNotIn(key, first_event["data"])

    def mutation_request(self, fixture: dict[str, object]) -> dict[str, object]:
        authorization = copy.deepcopy(fixture["authorization"])
        evidence = copy.deepcopy(fixture["evidence"])
        prepared_document = {
            "schema": "rpm-existing-pr-adoption-prepared-v1",
            "authorization": authorization,
            "evidence": evidence,
        }
        repository = authorization["repository"]
        issue = authorization["issue"]
        pr = authorization["pr"]
        head_sha = authorization["head"]["sha"]
        run_id = fixture["operation"]["run_id"]
        prepared_record = {
            "comment_id": 81002,
            "author": LEDGER_AUTHOR,
            "marker": LEDGER_MARKER,
            "namespace": "rpm-agent-adoption",
            "run_id": run_id,
            "phase": "label-mutation",
            "repository": repository,
            "issue": issue,
            "pr": pr,
            "head_sha": head_sha,
            "evidence_digest": authorization["evidence_digest"],
            "prepared_document": prepared_document,
            "prepared_document_digest": canonical_digest(prepared_document),
        }
        adoption_input = copy.deepcopy(fixture)
        return {
            "role": "rpm_existing_pr_adopter",
            "operation": "add-lifecycle-label",
            "repository": repository,
            "issue": issue,
            "pr": pr,
            "label": "agent:review-pending",
            "before": "untracked",
            "after": "review-pending",
            "mode": "add-only",
            "expected_current_labels": sorted(evidence["issue"]["labels"]),
            "run_id": run_id,
            "evidence_digest": authorization["evidence_digest"],
            "ledger_phase": "label-mutation",
            "prepared_record": prepared_record,
            "adoption_input": adoption_input,
            "adoption_input_digest": canonical_digest(adoption_input),
        }

    def retarget_fixture(
        self,
        fixture: dict[str, object],
        *,
        repository: str,
        issue: int,
        pr: int,
    ) -> None:
        authorization = fixture["authorization"]
        authorization["repository"] = repository
        authorization["issue"] = issue
        authorization["pr"] = pr
        authorization["base"]["repository"] = repository
        authorization["head"]["repository"] = repository
        authorization["head"]["ref"] = f"feat/issue-{issue}-fixture"
        authorization["closing_issues"] = [
            {"repository": repository, "number": issue}
        ]

        evidence = fixture["evidence"]
        evidence["repository"]["name_with_owner"] = repository
        evidence["issue"]["repository"] = repository
        evidence["issue"]["number"] = issue
        evidence["issue"]["closing_prs"] = [pr]
        evidence["pr"]["repository"] = repository
        evidence["pr"]["number"] = pr
        evidence["pr"]["base"]["repository"] = repository
        evidence["pr"]["head"]["repository"] = repository
        evidence["pr"]["head"]["ref"] = f"feat/issue-{issue}-fixture"
        evidence["pr"]["closing_issues"] = [
            {"repository": repository, "number": issue}
        ]
        evidence["execution"].update(
            {"repository": repository, "issue": issue, "pr": pr}
        )
        evidence["checks"].update({"repository": repository, "pr": pr})
        evidence["review"].update(
            {"repository": repository, "pr": pr, "head_sha": HEAD_SHA}
        )
        for collection in ("automatic_reviews", "reactions"):
            evidence["review"][collection].update(
                {"repository": repository, "pr": pr, "head_sha": HEAD_SHA}
            )
        evidence["findings"].update(
            {"repository": repository, "pr": pr, "head_sha": HEAD_SHA}
        )
        for collection in ("writers", "dependent_prs"):
            evidence[collection].update(
                {"repository": repository, "pr": pr, "head_sha": HEAD_SHA}
            )

        fixture["repository"] = repository
        fixture["issues"][0]["number"] = issue
        fixture["issues"][0]["url"] = (
            f"https://github.com/{repository}/issues/{issue}"
        )
        fixture["issues"][0]["closing_prs"][0]["number"] = pr
        fixture["issues"][0]["closing_prs"][0]["repository"] = repository
        fixture["issues"][0]["closing_pr_inventory"]["repository"] = repository
        fixture["issues"][0]["closing_pr_inventory"]["records"] = [
            {"repository": repository, "number": pr}
        ]
        fixture["closing_pr_inventory"]["repository"] = repository
        fixture["closing_pr_inventory"]["records"] = [
            {
                "repository": repository,
                "issue": issue,
                "pr": pr,
                "state": "OPEN",
                "base_ref": authorization["base"]["ref"],
                "base_sha": authorization["base"]["sha"],
                "head_ref": authorization["head"]["ref"],
                "head_sha": authorization["head"]["sha"],
            }
        ]
        fixture["execution_inventory"]["repository"] = repository
        fixture["execution_inventory"]["records"] = [
            {"repository": repository, "number": issue}
        ]
        self.resign(fixture)

    def run_mutation_helper(
        self, request: dict[str, object]
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
        with tempfile.TemporaryDirectory(prefix="rpm-adoption-mutation-") as raw:
            path = self.write_json(Path(raw), "request.json", request)
            return self.run_json_command(
                [
                    "python3",
                    str(MUTATION_HELPER),
                    "--policy",
                    str(POLICY),
                    "--request-file",
                    str(path),
                ],
                {0, 1},
            )

    def test_narrow_helper_authorizes_only_add_only_review_pending(self) -> None:
        fixture = self.load_adoption()
        fixture["ledger"]["comments"] = [
            self.ledger_record(fixture, "prepared", comment_id=81001),
            self.ledger_record(fixture, "label-mutation", comment_id=81002),
        ]
        queue_result, queue_event = self.run_queue(fixture)
        queue_data = self.assert_adoptable(queue_result, queue_event)
        request = queue_data.get("mutation_request")
        self.assertIsInstance(request, dict, queue_data)
        result, event = self.run_mutation_helper(request)
        self.assertEqual(result.returncode, 0, event)
        self.assertEqual(event["data"].get("status"), "authorized")
        self.assertEqual(
            event["data"].get("mutation"),
            {
                "mode": "add-only",
                "add": ["agent:review-pending"],
                "remove": [],
                "preserve": ["documentation"],
            },
        )

        alternate = self.load_adoption()
        self.retarget_fixture(
            alternate,
            repository="nerdchanii/rpm",
            issue=345,
            pr=410,
        )
        alternate["ledger"]["comments"] = [
            self.ledger_record(alternate, "prepared", comment_id=82001),
            self.ledger_record(alternate, "label-mutation", comment_id=82002),
        ]
        queue_result, queue_event = self.run_queue(alternate)
        alternate_data = queue_event["data"]
        self.assertEqual(queue_result.returncode, 0, alternate_data)
        alternate_request = alternate_data.get("mutation_request")
        self.assertIsInstance(alternate_request, dict, alternate_data)
        result, event = self.run_mutation_helper(alternate_request)
        self.assertEqual(result.returncode, 0, event)
        self.assertEqual(event["data"].get("status"), "authorized", event)

        variants = []
        for field, value in (
            ("mode", "replace-all"),
            ("label", "agent:awaiting-merge"),
            ("issue", 146),
            ("pr", 211),
            ("repository", "other/rpm"),
            ("ledger_phase", "prepared"),
            ("operation", "raw-github-mutation"),
        ):
            changed = copy.deepcopy(request)
            changed[field] = value
            variants.append((field, changed))

        changed = copy.deepcopy(request)
        changed["prepared_record"]["issue"] = 146
        variants.append(("prepared-record-target", changed))

        changed = copy.deepcopy(request)
        changed["prepared_record"]["run_id"] = "other-run"
        variants.append(("prepared-record-run", changed))

        changed = copy.deepcopy(request)
        changed["prepared_record"]["phase"] = "prepared"
        variants.append(("prepared-record-phase", changed))

        changed = copy.deepcopy(request)
        changed["prepared_record"]["prepared_document_digest"] = (
            "sha256:" + "0" * 64
        )
        variants.append(("prepared-document-digest", changed))

        changed = copy.deepcopy(request)
        changed["prepared_record"]["prepared_document"]["authorization"][
            "issue"
        ] = 146
        changed["prepared_record"]["prepared_document_digest"] = canonical_digest(
            changed["prepared_record"]["prepared_document"]
        )
        variants.append(("prepared-authorization-target", changed))

        changed = copy.deepcopy(request)
        changed["prepared_record"]["prepared_document"]["evidence"]["issue"][
            "number"
        ] = 146
        changed["prepared_record"]["prepared_document_digest"] = canonical_digest(
            changed["prepared_record"]["prepared_document"]
        )
        variants.append(("prepared-evidence-target", changed))

        changed = copy.deepcopy(request)
        changed["prepared_record"]["prepared_document"]["evidence"]["checks"][
            "records"
        ][0]["conclusion"] = "failure"
        changed["prepared_record"]["prepared_document_digest"] = canonical_digest(
            changed["prepared_record"]["prepared_document"]
        )
        variants.append(("opaque-digest-cannot-hide-changed-evidence", changed))
        for name, changed in variants:
            with self.subTest(name=name):
                result, event = self.run_mutation_helper(changed)
                self.assert_blocked(result, event)

    def test_helper_refetches_eligibility_and_requires_real_ledger_membership(self) -> None:
        fixture = self.load_adoption()
        fabricated = self.mutation_request(fixture)
        result, event = self.run_mutation_helper(fabricated)
        self.assert_blocked(result, event)

        fixture = self.load_adoption()
        fixture["evidence"]["checks"]["records"][0]["conclusion"] = "failure"
        self.resign(fixture)
        fixture["ledger"]["comments"] = [
            self.ledger_record(fixture, "prepared", comment_id=81001),
            self.ledger_record(fixture, "label-mutation", comment_id=81002),
        ]
        resigned_failed = self.mutation_request(fixture)
        result, event = self.run_mutation_helper(resigned_failed)
        self.assert_blocked(result, event)

        valid = self.load_adoption()
        valid["ledger"]["comments"] = [
            self.ledger_record(valid, "prepared", comment_id=81001),
            self.ledger_record(valid, "label-mutation", comment_id=81002),
        ]
        request = self.mutation_request(valid)
        for name, mutate in (
            (
                "missing-prepared-membership",
                lambda value: value["adoption_input"]["ledger"].__setitem__(
                    "comments", value["adoption_input"]["ledger"]["comments"][1:]
                ),
            ),
            (
                "missing-label-membership",
                lambda value: value["adoption_input"]["ledger"].__setitem__(
                    "comments", value["adoption_input"]["ledger"]["comments"][:1]
                ),
            ),
            (
                "stale-live-head",
                lambda value: value["adoption_input"]["live"].__setitem__(
                    "head_sha", "c" * 40
                ),
            ),
        ):
            with self.subTest(name=name):
                changed = copy.deepcopy(request)
                mutate(changed)
                changed["adoption_input_digest"] = canonical_digest(
                    changed["adoption_input"]
                )
                result, event = self.run_mutation_helper(changed)
                self.assert_blocked(result, event)

    def load_adoption_writer(self):
        self.assertTrue(ADOPTION_WRITER.is_file(), ADOPTION_WRITER)
        namespace = runpy.run_path(str(ADOPTION_WRITER))
        writer = namespace.get("execute_adoption_phase")
        self.assertTrue(callable(writer), namespace.keys())
        self.assertTrue(callable(namespace.get("main")), namespace.keys())
        return writer

    def test_github_check_runs_object_payload_is_paginated(self) -> None:
        namespace = runpy.run_path(str(ADOPTION_WRITER))
        github_transport = namespace.get("GithubAdoptionTransport")
        self.assertTrue(callable(github_transport), namespace.keys())
        calls: list[str] = []

        def runner(
            argv: list[str], input_text: str | None = None
        ) -> tuple[int, str, str]:
            self.assertIsNone(input_text)
            endpoint = argv[2]
            calls.append(endpoint)
            if endpoint.endswith("page=1"):
                records = [
                    {"id": index, "name": f"check-{index}"}
                    for index in range(1, 101)
                ]
            elif endpoint.endswith("page=2"):
                records = [{"id": 101, "name": "check-101"}]
            else:
                self.fail(f"unexpected check-runs page: {endpoint}")
            return (
                0,
                json.dumps({"total_count": 101, "check_runs": records}),
                "",
            )

        transport = github_transport(snapshot=self.load_adoption(), runner=runner)
        records = transport._paginate(
            f"repos/nerdchanii/rpm/commits/{HEAD_SHA}/check-runs"
        )
        self.assertEqual(len(records), 101)
        self.assertEqual([record["id"] for record in records], list(range(1, 102)))
        self.assertEqual(
            calls,
            [
                f"repos/nerdchanii/rpm/commits/{HEAD_SHA}/check-runs?per_page=100&page=1",
                f"repos/nerdchanii/rpm/commits/{HEAD_SHA}/check-runs?per_page=100&page=2",
            ],
        )

    def test_default_github_transport_wires_repository_collectors_and_fails_closed(
        self,
    ) -> None:
        namespace = runpy.run_path(str(ADOPTION_WRITER))
        writer = namespace.get("execute_adoption_phase")
        github_transport = namespace.get("GithubAdoptionTransport")
        self.assertTrue(callable(writer), namespace.keys())
        self.assertTrue(callable(github_transport), namespace.keys())

        prepared = self.load_adoption()
        api = FakeGithubApiRunner(prepared)
        transport = github_transport(
            snapshot=prepared,
            runner=api,
            approved_marker_actors=frozenset({"nerdchanii"}),
        )
        required = {
            "execution",
            "findings",
            "writers",
            "dependent_prs",
            "observation_time",
        }
        self.assertTrue(required.issubset(transport.collectors), transport.collectors)
        self.assertTrue(
            all(callable(transport.collectors[name]) for name in required),
            transport.collectors,
        )

        # The API runner is the mocked network boundary. Keep the production
        # transport class and its default wiring, while supplying deterministic
        # live collector results through those repository-owned slots.
        transport.collectors.update(self.live_collectors(prepared))
        result = writer(self.load_policy(), prepared, transport)
        self.assertEqual(result.get("status"), "applied", result)
        self.assertEqual(result.get("phase"), "writer-lease", result)
        self.assertEqual([kind for kind, _ in api.writes], ["comment"])
        self.assertTrue(
            str(api.writes[0][1]).startswith("<!-- rpm-agent-writer:v1 -->\n")
        )

        missing_api = FakeGithubApiRunner(prepared)
        missing = github_transport(
            snapshot=prepared,
            runner=missing_api,
            approved_marker_actors=frozenset({"nerdchanii"}),
        )
        missing.collectors.update(self.live_collectors(prepared))
        missing.collectors.pop("writers")
        with self.assertRaisesRegex(RuntimeError, "collector missing: writers"):
            missing.read("nerdchanii/rpm", 145, 210)
        self.assertEqual(missing_api.writes, [])

        partial_api = FakeGithubApiRunner(prepared)
        partial = github_transport(
            snapshot=prepared,
            runner=partial_api,
            approved_marker_actors=frozenset({"nerdchanii"}),
        )
        partial.collectors.update(self.live_collectors(prepared))
        bad_writers = copy.deepcopy(prepared["evidence"]["writers"])
        bad_writers["read_complete"] = False
        partial.collectors["writers"] = (
            lambda repository, issue, pr: copy.deepcopy(bad_writers)
        )
        with self.assertRaisesRegex(RuntimeError, "dependent-PR|writers"):
            partial.read("nerdchanii/rpm", 145, 210)
        self.assertEqual(partial_api.writes, [])

    def test_execution_authorization_ignores_issue_body_and_requires_approved_comment(
        self,
    ) -> None:
        namespace = runpy.run_path(str(ADOPTION_WRITER))
        github_transport = namespace.get("GithubAdoptionTransport")
        self.assertTrue(callable(github_transport), namespace.keys())
        prepared = self.load_adoption()
        execution = copy.deepcopy(prepared["evidence"]["execution"])
        marker_payload = {
            field: execution[field]
            for field in ("approval_id", "plan_revision", "scope_hash", "executor")
        }
        marker = "<!-- rpm-agent-execution: " + json.dumps(marker_payload) + " -->"
        transport = github_transport(
            snapshot=prepared,
            approved_marker_actors=frozenset({"nerdchanii"}),
        )
        transport._call = lambda endpoint, **kwargs: {"body": marker}
        transport._paginate = lambda endpoint, **kwargs: []
        with self.assertRaisesRegex(RuntimeError, "authorization is missing"):
            transport._collect_execution("nerdchanii/rpm", 145, 210)

        transport._paginate = lambda endpoint, **kwargs: [
            {"id": 70001, "user": {"login": "untrusted-user"}, "body": marker}
        ]
        with self.assertRaisesRegex(RuntimeError, "authorization is missing"):
            transport._collect_execution("nerdchanii/rpm", 145, 210)

        transport._paginate = lambda endpoint, **kwargs: [
            {"id": 70002, "user": {"login": "nerdchanii"}, "body": marker}
        ]
        collected = transport._collect_execution("nerdchanii/rpm", 145, 210)
        self.assertEqual(collected, execution)
        self.assertEqual(
            collected["source"], "github-approved-workflow-comment-v1"
        )
        self.assertEqual(collected["source_actor"], "nerdchanii")

        forged_marker_payload = {
            **marker_payload,
            "repository": "other/rpm",
            "issue": 999,
            "pr": 998,
            "source": "forged-source",
            "source_actor": "forged-actor",
            "policy_version": 0,
            "operation_version": 0,
        }
        forged_marker = "<!-- rpm-agent-execution: " + json.dumps(
            forged_marker_payload
        ) + " -->"
        transport._paginate = lambda endpoint, **kwargs: [
            {"id": 70003, "user": {"login": "nerdchanii"}, "body": forged_marker}
        ]
        rebound = transport._collect_execution("nerdchanii/rpm", 145, 210)
        self.assertEqual(rebound["repository"], "nerdchanii/rpm")
        self.assertEqual(rebound["issue"], 145)
        self.assertEqual(rebound["pr"], 210)
        self.assertEqual(rebound["source"], "github-approved-workflow-comment-v1")
        self.assertEqual(rebound["source_actor"], "nerdchanii")
        self.assertEqual(rebound["policy_version"], prepared["operation"]["policy_version"])
        self.assertEqual(rebound["operation_version"], prepared["operation"]["version"])

    def test_default_observation_time_and_claim_lease_use_contract_evidence(self) -> None:
        namespace = runpy.run_path(str(ADOPTION_WRITER))
        github_transport = namespace.get("GithubAdoptionTransport")
        self.assertTrue(callable(github_transport), namespace.keys())
        prepared = self.load_adoption()
        observed_at = datetime(2026, 8, 26, 1, 2, 3, 456789, tzinfo=timezone.utc)
        transport = github_transport(
            snapshot=prepared, observation_clock=lambda: observed_at
        )

        expected_observed_at = "2026-08-26T01:02:03.456789Z"
        self.assertEqual(
            transport._collect_observation_time("nerdchanii/rpm", 145, 210),
            expected_observed_at,
        )
        self.assertEqual(
            transport._collect_observation_time("nerdchanii/rpm", 145, 210),
            expected_observed_at,
        )
        lease = {
            "lease": {
                "run_id": "claim-run-1",
                "owner": "cloud:executor",
                "expires_at": "2026-08-25T13:00:00Z",
            }
        }
        record = transport._writer_record_from_execution(
            lease,
            "nerdchanii/rpm",
            145,
            210,
            HEAD_SHA,
        )
        self.assertEqual(
            record,
            {
                "kind": "claim",
                "repository": "nerdchanii/rpm",
                "issue": 145,
                "pr": 210,
                "run_id": "claim-run-1",
                "owner": "cloud:executor",
                "lease_expires_at": "2026-08-25T13:00:00Z",
                "head_sha": HEAD_SHA,
            },
        )
        marker = "<!-- rpm-agent-execution: " + json.dumps(lease) + " -->"
        self.assertEqual(
            transport._writer_records_from_text(
                marker,
                "nerdchanii/rpm",
                145,
                210,
                include_execution_lease=True,
                head_sha=HEAD_SHA,
            ),
            [record],
        )

        api = FakeGithubApiRunner(prepared)
        api.pr_updated_at = "2026-08-25T13:00:00Z"
        live = github_transport(
            snapshot=prepared,
            runner=api,
            approved_marker_actors=frozenset({"nerdchanii"}),
        )
        live.collectors.update(self.live_collectors(prepared))
        observed = live.read("nerdchanii/rpm", 145, 210)["state"]
        self.assertEqual(
            observed["evidence"]["review"]["head_updated_at"],
            "2026-08-25T13:00:00Z",
        )

        api.timeline_events = [
            {
                "event": "head_ref_force_pushed",
                "commit_id": "c" * 40,
                "created_at": "2026-08-25T12:05:00Z",
            },
            {
                "event": "head_ref_force_pushed",
                "commit_id": HEAD_SHA,
                "created_at": "2026-08-25T12:20:00Z",
            },
        ]
        transitioned = github_transport(
            snapshot=prepared,
            runner=api,
            approved_marker_actors=frozenset({"nerdchanii"}),
        )
        transitioned.collectors.update(self.live_collectors(prepared))
        transitioned_state = transitioned.read("nerdchanii/rpm", 145, 210)["state"]
        self.assertEqual(
            transitioned_state["evidence"]["review"]["head_updated_at"],
            "2026-08-25T12:20:00Z",
        )

        trusted_record = self.ledger_record(prepared, "prepared", comment_id=81001)
        parsed = transitioned._ledger_comments(
            [
                {
                    "id": 81000,
                    "user": {"login": "untrusted-user"},
                    "body": "<!-- rpm-agent-adoption:v1 -->\nnot-json",
                },
                {
                    "id": 81001,
                    "user": {"login": "nerdchanii"},
                    "body": "<!-- rpm-agent-adoption:v1 -->\n"
                    + json.dumps(trusted_record),
                },
            ],
            "nerdchanii/rpm",
            145,
            210,
            frozenset({"nerdchanii"}),
        )
        self.assertEqual(parsed, [trusted_record])

    def test_live_observation_clock_refreshes_each_refetch_and_keeps_phase_retry_safe(
        self,
    ) -> None:
        namespace = runpy.run_path(str(ADOPTION_WRITER))
        github_transport = namespace.get("GithubAdoptionTransport")
        writer = namespace.get("execute_adoption_phase")
        self.assertTrue(callable(github_transport), namespace.keys())
        self.assertTrue(callable(writer), namespace.keys())
        prepared = self.load_adoption()
        self.install_current_adoption_lease(
            prepared, expires_at="2026-08-26T02:00:00Z"
        )
        observation_times = iter(
            [
                datetime(2026, 8, 26, 1, 2, 3, tzinfo=timezone.utc),
                datetime(2026, 8, 26, 1, 2, 4, tzinfo=timezone.utc),
                datetime(2026, 8, 26, 1, 3, 4, tzinfo=timezone.utc),
                datetime(2026, 8, 26, 1, 3, 5, tzinfo=timezone.utc),
                datetime(2026, 8, 26, 1, 4, 4, tzinfo=timezone.utc),
                datetime(2026, 8, 26, 1, 4, 5, tzinfo=timezone.utc),
                datetime(2026, 8, 26, 1, 4, 6, tzinfo=timezone.utc),
                datetime(2026, 8, 26, 1, 4, 7, tzinfo=timezone.utc),
                datetime(2026, 8, 26, 1, 4, 8, tzinfo=timezone.utc),
                datetime(2026, 8, 26, 1, 4, 9, tzinfo=timezone.utc),
            ]
        )
        api = FakeGithubApiRunner(prepared)
        transport = github_transport(
            snapshot=prepared,
            runner=api,
            approved_marker_actors=frozenset({"nerdchanii"}),
            observation_clock=lambda: next(observation_times),
        )
        evidence = prepared["evidence"]

        def copy_evidence(name: str):
            return lambda repository, issue, pr: copy.deepcopy(evidence[name])

        transport.collectors.update(
            {
                name: copy_evidence(name)
                for name in ("execution", "findings", "dependent_prs")
            }
        )

        def writers(repository: str, issue: int, pr: int) -> dict[str, object]:
            value = copy.deepcopy(evidence["writers"])
            value["observed_at"] = transport._current_observation_time
            return value

        transport.collectors["writers"] = writers
        first = writer(self.load_policy(), prepared, transport)
        second = writer(self.load_policy(), prepared, transport)
        third = writer(self.load_policy(), prepared, transport)
        self.assertEqual(first.get("status"), "applied", first)
        self.assertEqual(first.get("phase"), "prepared", first)
        self.assertEqual(second.get("status"), "applied", second)
        self.assertEqual(second.get("phase"), "label-mutation", second)
        self.assertEqual(third.get("status"), "applied", third)
        self.assertEqual(third.get("phase"), "label-mutation", third)
        self.assertEqual(
            [kind for kind, _ in api.writes],
            ["comment", "comment", "labels"],
        )

    def test_writer_leases_are_global_and_marker_authors_are_bound(self) -> None:
        namespace = runpy.run_path(str(ADOPTION_WRITER))
        github_transport = namespace.get("GithubAdoptionTransport")
        self.assertTrue(callable(github_transport), namespace.keys())
        prepared = self.load_adoption()
        transport = github_transport(
            snapshot=prepared,
            approved_marker_actors=frozenset({"nerdchanii"}),
        )
        lease = {
            "lease": {
                "run_id": "claim-run-other-issue",
                "owner": "cloud:executor",
                "expires_at": "2026-08-25T13:00:00Z",
            }
        }
        marker = "<!-- rpm-agent-execution: " + json.dumps(lease) + " -->"
        transport._head_sha_from_pr = lambda repository, pr: HEAD_SHA
        transport._current_observation_time = prepared["now"]

        def paginate(endpoint: str, **kwargs: object) -> list[object]:
            if endpoint == "repos/nerdchanii/rpm/issues?state=open":
                return [
                    {
                        "number": 145,
                        "body": "",
                        "labels": [],
                        "user": {"login": "nerdchanii"},
                    },
                    {
                        "number": 999,
                        "body": marker,
                        "labels": [],
                        "user": {"login": "nerdchanii"},
                    },
                ]
            if endpoint.endswith("/comments"):
                return []
            raise AssertionError(endpoint)

        transport._paginate = paginate
        inventory = transport._collect_writers("nerdchanii/rpm", 145, 210)
        self.assertEqual(inventory["records"][0]["issue"], 999)
        self.assertIsNone(inventory["records"][0]["pr"])

        writer_marker = "<!-- rpm-agent-writer: " + json.dumps(
            {
                "kind": "claim",
                "repository": "nerdchanii/rpm",
                "issue": 999,
                "pr": None,
                "run_id": "marker-run",
                "owner": "cloud:executor",
                "lease_expires_at": "2026-08-25T13:00:00Z",
                "head_sha": None,
            }
        ) + " -->"
        self.assertEqual(
            transport._writer_records_from_text(
                writer_marker,
                "nerdchanii/rpm",
                999,
                None,
                author="untrusted-user",
                approved_marker_actors=frozenset({"nerdchanii"}),
            ),
            [],
        )
        self.assertEqual(
            len(
                transport._writer_records_from_text(
                    writer_marker,
                    "nerdchanii/rpm",
                    999,
                    None,
                    author="nerdchanii",
                    approved_marker_actors=frozenset({"nerdchanii"}),
                )
            ),
            1,
        )

        claimed_without_lease = github_transport(
            snapshot=prepared,
            approved_marker_actors=frozenset({"nerdchanii"}),
        )

        def claimed_issue_paginate(endpoint: str, **kwargs: object) -> list[object]:
            if endpoint == "repos/nerdchanii/rpm/issues?state=open":
                return [
                    {
                        "number": 999,
                        "body": "",
                        "labels": [{"name": "agent:claimed"}],
                        "user": {"login": "nerdchanii"},
                    }
                ]
            if endpoint.endswith("/comments"):
                return []
            raise AssertionError(endpoint)

        claimed_without_lease._paginate = claimed_issue_paginate
        claimed_without_lease._head_sha_from_pr = lambda repository, pr: HEAD_SHA
        with self.assertRaisesRegex(RuntimeError, "claim lease"):
            claimed_without_lease._collect_writers("nerdchanii/rpm", 145, 210)

    def test_writer_inventory_cas_is_independent_of_api_item_order(self) -> None:
        namespace = runpy.run_path(str(ADOPTION_WRITER))
        github_transport = namespace.get("GithubAdoptionTransport")
        self.assertTrue(callable(github_transport), namespace.keys())
        prepared = self.load_adoption()
        transport = github_transport(
            snapshot=prepared,
            approved_marker_actors=frozenset({"nerdchanii"}),
        )
        transport._head_sha_from_pr = lambda repository, pr: HEAD_SHA
        transport._current_observation_time = prepared["now"]

        def item(number: int, run_id: str) -> dict[str, object]:
            record = {
                "kind": "implementation",
                "repository": "nerdchanii/rpm",
                "issue": number,
                "pr": None,
                "run_id": run_id,
                "owner": "cloud:executor",
                "lease_expires_at": "2026-08-25T13:00:00Z",
                "head_sha": None,
            }
            return {
                "number": number,
                "body": "<!-- rpm-agent-writer:v1: "
                + json.dumps(record, sort_keys=True)
                + " -->",
                "labels": [],
                "user": {"login": "nerdchanii"},
            }

        items = [item(145, "run-z"), item(999, "run-a")]

        def collect(order: list[dict[str, object]]) -> dict[str, object]:
            def paginate(endpoint: str, **kwargs: object) -> list[object]:
                if endpoint == "repos/nerdchanii/rpm/issues?state=open":
                    return copy.deepcopy(order)
                if endpoint.endswith("/comments"):
                    return []
                raise AssertionError(endpoint)

            transport._paginate = paginate
            return transport._collect_writers("nerdchanii/rpm", 145, 210)

        forward = collect(items)
        reverse = collect(list(reversed(items)))
        self.assertEqual(forward["records"], reverse["records"])
        self.assertEqual(forward["cas_token"], reverse["cas_token"])

    def test_dependent_inventory_filters_unrelated_forks_before_identity_checks(self) -> None:
        namespace = runpy.run_path(str(ADOPTION_WRITER))
        github_transport = namespace.get("GithubAdoptionTransport")
        self.assertTrue(callable(github_transport), namespace.keys())
        prepared = self.load_adoption()
        transport = github_transport(snapshot=prepared)
        target = {
            "head": {"ref": "feat/issue-145-workspaces", "sha": HEAD_SHA}
        }
        transport._call = lambda endpoint, **kwargs: target
        unrelated_fork = {
            "number": 999,
            "state": "OPEN",
            "baseRefName": "main",
            "baseRefOid": BASE_SHA,
            "headRefName": "fork-change",
            "headRefOid": "c" * 40,
            "repository": {"nameWithOwner": "nerdchanii/rpm"},
            "baseRepository": {"nameWithOwner": "nerdchanii/rpm"},
            "headRepository": {"nameWithOwner": "someone/rpm"},
        }
        transport._graphql_connection = lambda query, variables, path: [unrelated_fork]
        inventory = transport._collect_dependents("nerdchanii/rpm", 145, 210)
        self.assertEqual(inventory["records"], [])

        dependent_fork = copy.deepcopy(unrelated_fork)
        dependent_fork["baseRefName"] = "feat/issue-145-workspaces"
        transport._graphql_connection = lambda query, variables, path: [dependent_fork]
        with self.assertRaisesRegex(RuntimeError, "identity"):
            transport._collect_dependents("nerdchanii/rpm", 145, 210)

    def test_real_github_transport_recovers_all_phases_with_immutable_authorization(
        self,
    ) -> None:
        namespace = runpy.run_path(str(ADOPTION_WRITER))
        writer = namespace.get("execute_adoption_phase")
        github_transport = namespace.get("GithubAdoptionTransport")
        self.assertTrue(callable(writer), namespace.keys())
        self.assertTrue(callable(github_transport), namespace.keys())

        prepared = self.load_adoption()
        self.install_current_adoption_lease(prepared)
        immutable_authorization = copy.deepcopy(prepared["authorization"])
        api = FakeGithubApiRunner(prepared)
        transport = github_transport(
            snapshot=prepared,
            runner=api,
            approved_marker_actors=frozenset({"nerdchanii"}),
            collectors=self.live_collectors(prepared),
        )
        expected_phases = [
            "prepared",
            "label-mutation",
            "label-mutation",
            "committed",
            "reconciled",
        ]
        for phase in expected_phases:
            with self.subTest(phase=phase):
                result = writer(self.load_policy(), prepared, transport)
                self.assertEqual(result.get("status"), "applied", result)
                self.assertEqual(result.get("phase"), phase, result)
                self.assertEqual(prepared["authorization"], immutable_authorization)

        replay = writer(self.load_policy(), prepared, transport)
        self.assertEqual(
            replay,
            {"status": "reconciled", "phase": "reconciled"},
        )
        self.assertEqual(
            api.labels,
            {"documentation", "agent:review-pending"},
        )
        self.assertEqual(
            [kind for kind, _ in api.writes],
            ["comment", "comment", "labels", "comment", "comment"],
        )
        self.assertEqual(
            [payload for kind, payload in api.writes if kind == "labels"],
            [["agent:review-pending"]],
        )

        observation = transport.read("nerdchanii/rpm", 145, 210)["state"]
        self.assertEqual(
            observation["live"]["issue_labels"],
            ["agent:review-pending", "documentation"],
        )
        self.assertEqual(
            observation["evidence"]["issue"]["labels"],
            ["agent:review-pending", "documentation"],
        )
        self.assertEqual(observation["authorization"], immutable_authorization)
        phases = [record["phase"] for record in observation["ledger"]["comments"]]
        self.assertEqual(
            phases,
            ["prepared", "label-mutation", "committed", "reconciled"],
        )
        for record in observation["ledger"]["comments"]:
            prepared_document = record.get("prepared_document")
            if prepared_document is not None:
                self.assertEqual(
                    prepared_document["authorization"], immutable_authorization
                )

    def test_label_write_race_compensates_only_its_own_lifecycle_label(self) -> None:
        namespace = runpy.run_path(str(ADOPTION_WRITER))
        writer = namespace.get("execute_adoption_phase")
        github_transport = namespace.get("GithubAdoptionTransport")
        self.assertTrue(callable(writer), namespace.keys())
        self.assertTrue(callable(github_transport), namespace.keys())

        cases = (
            ("agent:claimed", False),
            ("agent:blocked", False),
            ("agent:claimed", True),
            ("priority:high", False),
        )
        for external_label, compensation_fails in cases:
            with self.subTest(
                external_label=external_label,
                compensation_fails=compensation_fails,
            ):
                prepared = self.load_adoption()
                self.install_current_adoption_lease(prepared)
                api = RacingLifecycleLabelApiRunner(
                    prepared,
                    external_label,
                    compensation_fails=compensation_fails,
                )
                transport = github_transport(
                    snapshot=prepared,
                    runner=api,
                    approved_marker_actors=frozenset({"nerdchanii"}),
                    collectors=self.live_collectors(prepared),
                )

                for expected_phase in ("prepared", "label-mutation"):
                    result = writer(self.load_policy(), prepared, transport)
                    self.assertEqual(result.get("status"), "applied", result)
                    self.assertEqual(result.get("phase"), expected_phase, result)

                result = writer(self.load_policy(), prepared, transport)
                self.assertTrue(api.race_injected)
                self.assertEqual(result.get("status"), "blocked", result)

                phases = [
                    json.loads(str(comment["body"]).split("\n", 1)[1])[
                        "phase"
                    ]
                    for comment in api.comments
                ]
                self.assertEqual(phases, ["prepared", "label-mutation"])
                self.assertNotIn("committed", phases)
                self.assertNotIn("reconciled", phases)
                self.assertIn(external_label, api.labels)
                self.assertIn("documentation", api.labels)

                post_index = next(
                    index
                    for index, call in enumerate(api.calls)
                    if call[0] == "POST" and call[1].endswith("/labels")
                )
                later_calls = api.calls[post_index + 1 :]
                self.assertTrue(
                    any(
                        method == "GET"
                        and route == "repos/nerdchanii/rpm/issues/145"
                        for method, route in later_calls
                    ),
                    api.calls,
                )

                if compensation_fails:
                    self.assertIn("agent:review-pending", api.labels)
                else:
                    self.assertNotIn("agent:review-pending", api.labels)
                    self.assertEqual(
                        [
                            payload
                            for kind, payload in api.writes
                            if kind == "delete-label"
                        ],
                        ["agent:review-pending"],
                    )

                retry = writer(self.load_policy(), prepared, transport)
                self.assertEqual(retry.get("status"), "blocked", retry)
                retry_phases = [
                    json.loads(str(comment["body"]).split("\n", 1)[1])[
                        "phase"
                    ]
                    for comment in api.comments
                ]
                self.assertEqual(
                    retry_phases, ["prepared", "label-mutation"]
                )

    def test_narrow_writer_performs_every_phase_and_exact_replay(self) -> None:
        writer = self.load_adoption_writer()
        prepared_snapshot = self.load_adoption()
        transport = FakeGithubAdoptionTransport(prepared_snapshot)
        self.assertIsNot(transport.state, prepared_snapshot)

        expected = [
            ("append-writer-lease-comment", "adopt-run-001"),
            ("append-ledger-comment", "prepared"),
            ("append-ledger-comment", "label-mutation"),
            ("add-lifecycle-label", "agent:review-pending"),
            ("append-ledger-comment", "committed"),
            ("append-ledger-comment", "reconciled"),
        ]
        for index, mutation in enumerate(expected, start=1):
            with self.subTest(step=index, mutation=mutation):
                result = writer(self.load_policy(), prepared_snapshot, transport)
                self.assertEqual(result.get("status"), "applied", result)
                self.assertEqual(transport.mutations, expected[:index])

        replay = writer(self.load_policy(), prepared_snapshot, transport)
        self.assertEqual(replay.get("status"), "reconciled", replay)
        self.assertEqual(replay.get("phase"), "reconciled", replay)
        self.assertEqual(transport.mutations, expected)

    def test_cli_entrypoint_uses_the_github_transport_and_completes_every_phase(
        self,
    ) -> None:
        namespace = runpy.run_path(str(ADOPTION_WRITER))
        main = namespace.get("main")
        github_transport = namespace.get("GithubAdoptionTransport")
        self.assertTrue(callable(main), namespace.keys())
        self.assertTrue(callable(github_transport), namespace.keys())

        prepared_snapshot = self.load_adoption()
        transport = FakeGithubAdoptionTransport(prepared_snapshot)
        expected = [
            ("append-writer-lease-comment", "adopt-run-001"),
            ("append-ledger-comment", "prepared"),
            ("append-ledger-comment", "label-mutation"),
            ("add-lifecycle-label", "agent:review-pending"),
            ("append-ledger-comment", "committed"),
            ("append-ledger-comment", "reconciled"),
        ]
        with tempfile.TemporaryDirectory(prefix="rpm-adoption-cli-") as raw:
            request_path = self.write_json(
                Path(raw), "request.json", prepared_snapshot
            )
            with mock.patch.dict(
                main.__globals__,
                {"GithubAdoptionTransport": lambda *args, **kwargs: transport},
            ):
                for index, mutation in enumerate(expected, start=1):
                    with self.subTest(step=index, mutation=mutation):
                        stdout = io.StringIO()
                        with contextlib.redirect_stdout(stdout):
                            exit_code = main(
                                [
                                    "--policy",
                                    str(POLICY),
                                    "--request-file",
                                    str(request_path),
                                ]
                            )
                        self.assertEqual(exit_code, 0, stdout.getvalue())
                        event = json.loads(stdout.getvalue().splitlines()[-1])
                        self.assertEqual(
                            event.get("type"), "existing_pr_adoption_write", event
                        )
                        self.assertEqual(
                            event.get("data", {}).get("status"), "applied", event
                        )
                        self.assertEqual(transport.mutations, expected[:index])

                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    exit_code = main(
                        [
                            "--policy",
                            str(POLICY),
                            "--request-file",
                            str(request_path),
                        ]
                    )
                self.assertEqual(exit_code, 0, stdout.getvalue())
                event = json.loads(stdout.getvalue().splitlines()[-1])
                self.assertEqual(
                    event.get("data"),
                    {"status": "reconciled", "phase": "reconciled"},
                    event,
                )
                self.assertEqual(transport.mutations, expected)

    def test_writer_binds_every_prepared_authorization_field_to_live_state(
        self,
    ) -> None:
        writer = self.load_adoption_writer()
        prepared_snapshot = self.load_adoption()
        self.install_current_adoption_lease(prepared_snapshot)

        def change_authorization_and_execution(
            state: dict[str, object], field: str, value: object
        ) -> None:
            state["authorization"][field] = value
            state["evidence"]["execution"][field] = value
            self.resign(state)

        variants = {
            "approval_id": lambda state: change_authorization_and_execution(
                state, "approval_id", "other-approval"
            ),
            "plan_revision": lambda state: change_authorization_and_execution(
                state, "plan_revision", "other-plan"
            ),
            "scope_hash": lambda state: change_authorization_and_execution(
                state, "scope_hash", "sha256:" + "9" * 64
            ),
            "policy_version": lambda state: change_authorization_and_execution(
                state, "policy_version", 5
            ),
            "operation_version": lambda state: change_authorization_and_execution(
                state, "operation_version", 2
            ),
            "executor": lambda state: change_authorization_and_execution(
                state, "executor", "cloud"
            ),
            "evidence_digest": lambda state: self.set_writers(
                state,
                [
                    self.writer(
                        state,
                        kind="implementation",
                        run_id="expired-different-evidence",
                        owner="old-owner",
                        expires_at="2026-08-25T12:00:00Z",
                    )
                ],
            ),
        }
        for field, mutate in variants.items():
            with self.subTest(field=field):
                transport = FakeGithubAdoptionTransport(prepared_snapshot)
                mutate(transport.state)
                result = writer(self.load_policy(), prepared_snapshot, transport)
                self.assertEqual(result.get("status"), "blocked", result)
                self.assertEqual(transport.mutations, [])

    def test_narrow_writer_refetches_and_cas_blocks_every_live_drift(self) -> None:
        writer = self.load_adoption_writer()
        prepared_snapshot = self.load_adoption()
        self.install_current_adoption_lease(prepared_snapshot)

        stale_before_read = FakeGithubAdoptionTransport(prepared_snapshot)
        stale_before_read.state["live"]["head_sha"] = "c" * 40
        result = writer(self.load_policy(), prepared_snapshot, stale_before_read)
        self.assertEqual(result.get("status"), "blocked", result)
        self.assertEqual(stale_before_read.mutations, [])

        def drift_head(state: dict[str, object]) -> None:
            state["live"]["head_sha"] = "c" * 40

        def drift_check(state: dict[str, object]) -> None:
            state["evidence"]["checks"]["records"][0]["conclusion"] = "failure"

        def drift_reaction(state: dict[str, object]) -> None:
            reviews = state["evidence"]["review"]["automatic_reviews"]
            reviews["records"] = []
            reviews["count"] = 0
            reactions = state["evidence"]["review"]["reactions"]
            reactions["records"] = [
                {
                    "content": "+1",
                    "actor": "chatgpt-codex-connector",
                    "created_at": "2026-08-25T12:10:00Z",
                    "head_sha": HEAD_SHA,
                    "deleted": True,
                }
            ]
            reactions["count"] = 1

        def drift_lifecycle(state: dict[str, object]) -> None:
            state["live"]["lifecycle_state"] = "review-pending"
            state["live"]["issue_labels"] = [
                "agent:review-pending",
                "documentation",
            ]

        def drift_ledger(state: dict[str, object]) -> None:
            state["ledger"]["comments"].append(
                {
                    "comment_id": 99999,
                    "author": "attacker",
                    "marker": LEDGER_MARKER,
                    "namespace": "rpm-agent-adoption",
                    "run_id": "attacker-run",
                    "phase": "prepared",
                    "repository": "nerdchanii/rpm",
                    "issue": 145,
                    "pr": 210,
                    "head_sha": HEAD_SHA,
                    "evidence_digest": prepared_snapshot["authorization"][
                        "evidence_digest"
                    ],
                }
            )

        for name, callback in (
            ("head", drift_head),
            ("check", drift_check),
            ("reaction", drift_reaction),
            ("lifecycle", drift_lifecycle),
            ("ledger", drift_ledger),
        ):
            with self.subTest(drift=name):
                transport = FakeGithubAdoptionTransport(prepared_snapshot)
                transport.before_write = callback
                result = writer(self.load_policy(), prepared_snapshot, transport)
                self.assertEqual(result.get("status"), "blocked", result)
                self.assertEqual(result.get("reason"), "compare-and-write-cas", result)
                self.assertEqual(transport.mutations, [])

    def test_writer_cas_binds_all_live_inputs_before_every_phase(self) -> None:
        writer = self.load_adoption_writer()

        def phase_fixture(phase: str) -> dict[str, object]:
            fixture = self.load_adoption()
            if phase in {"label-mutation", "label-write", "committed", "reconciled"}:
                fixture["ledger"]["comments"].append(
                    self.ledger_record(fixture, "prepared", comment_id=81001)
                )
            if phase in {"label-write", "committed", "reconciled"}:
                fixture["ledger"]["comments"].append(
                    self.ledger_record(
                        fixture, "label-mutation", comment_id=81002
                    )
                )
            if phase in {"committed", "reconciled"}:
                self.set_adopted_live_state(fixture)
            if phase == "reconciled":
                fixture["ledger"]["comments"].append(
                    self.ledger_record(fixture, "committed", comment_id=81003)
                )
            self.install_current_adoption_lease(fixture)
            return fixture

        def drift_reactions(state: dict[str, object]) -> None:
            reactions = state["evidence"]["review"]["reactions"]
            reactions["records"] = [
                {
                    "content": "+1",
                    "actor": "chatgpt-codex-connector",
                    "created_at": "2026-08-25T12:20:00Z",
                    "head_sha": HEAD_SHA,
                    "deleted": False,
                }
            ]
            reactions["count"] = 1

        def drift_findings(state: dict[str, object]) -> None:
            state["evidence"]["findings"]["items"] = [
                {
                    "id": "P1-live-drift",
                    "source_id": "thread-live-drift",
                    "head_sha": HEAD_SHA,
                    "severity": "P1",
                    "disposition": "accept-now",
                    "owner": "issue-228",
                    "rationale": "deterministic live drift",
                }
            ]
            state["evidence"]["findings"]["count"] = 1

        def drift_writers(state: dict[str, object]) -> None:
            state["evidence"]["writers"]["cas_token"] = (
                "writer-inventory-version-18"
            )

        def drift_dependents(state: dict[str, object]) -> None:
            state["evidence"]["dependent_prs"]["records"] = [
                {
                    "number": 216,
                    "state": "OPEN",
                    "repository": "nerdchanii/rpm",
                    "base_ref": "feat/issue-145-workspaces",
                    "base_sha": HEAD_SHA,
                    "head_ref": "feat/issue-148-workspace-targeting",
                    "head_sha": "c" * 40,
                }
            ]
            state["evidence"]["dependent_prs"]["count"] = 1

        def drift_execution(state: dict[str, object]) -> None:
            state["evidence"]["execution"]["plan_revision"] = "other-plan"

        def drift_observation_time(state: dict[str, object]) -> None:
            state["now"] = "2026-08-25T12:31:00Z"
            state["evidence"]["writers"]["observed_at"] = (
                "2026-08-25T12:31:00Z"
            )

        drifts = {
            "reactions": drift_reactions,
            "findings": drift_findings,
            "global-writers": drift_writers,
            "dependents": drift_dependents,
            "execution-metadata": drift_execution,
            "observation-time": drift_observation_time,
        }
        for phase in (
            "prepared",
            "label-mutation",
            "label-write",
            "committed",
            "reconciled",
        ):
            for name, callback in drifts.items():
                with self.subTest(phase=phase, live_input=name):
                    fixture = phase_fixture(phase)
                    transport = FakeGithubAdoptionTransport(fixture)
                    transport.before_write = callback
                    result = writer(self.load_policy(), fixture, transport)
                    self.assertEqual(result.get("status"), "blocked", result)
                    self.assertEqual(
                        result.get("reason"), "compare-and-write-cas", result
                    )
                    self.assertEqual(transport.mutations, [])

    def run_hook(self, event: dict[str, object]) -> subprocess.CompletedProcess[str]:
        event.setdefault("cwd", str(ROOT))
        return subprocess.run(
            ["python3", str(TOOL_POLICY)],
            cwd=ROOT,
            input=json.dumps(event),
            text=True,
            capture_output=True,
            check=False,
        )

    def test_adopter_tool_policy_denies_generic_raw_review_and_merge_mutations(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rpm-adopter-hook-") as raw:
            transcript = str(Path(raw) / "transcript.jsonl")
            start = self.run_hook(
                {
                    "hook_event_name": "SubagentStart",
                    "agent_type": "rpm_existing_pr_adopter",
                    "agent_transcript_path": transcript,
                }
            )
            self.assertEqual(start.returncode, 0, start.stderr)
            try:
                helper = self.run_hook(
                    {
                        "hook_event_name": "PreToolUse",
                        "transcript_path": transcript,
                        "tool_name": "exec_command",
                        "tool_input": {
                            "cmd": "python3 scripts/authorize-existing-pr-adoption-mutation.py --request-file /tmp/request.json"
                        },
                    }
                )
                self.assertEqual(helper.returncode, 0, helper.stderr)

                writer = self.run_hook(
                    {
                        "hook_event_name": "PreToolUse",
                        "transcript_path": transcript,
                        "tool_name": "exec_command",
                        "tool_input": {
                            "cmd": "python3 scripts/write-existing-pr-adoption.py --request-file /tmp/request.json"
                        },
                    }
                )
                self.assertEqual(writer.returncode, 0, writer.stderr)

                read_only = self.run_hook(
                    {
                        "hook_event_name": "PreToolUse",
                        "transcript_path": transcript,
                        "tool_name": "mcp__github__get_pull_request",
                        "tool_input": {"repository": "nerdchanii/rpm", "number": 210},
                    }
                )
                self.assertEqual(read_only.returncode, 0, read_only.stderr)

                host_prefixed = self.run_hook(
                    {
                        "hook_event_name": "PreToolUse",
                        "transcript_path": transcript,
                        "tool_name": "mcp__codex_apps__github_get_pull_request",
                        "tool_input": {"repository": "nerdchanii/rpm", "number": 210},
                    }
                )
                self.assertEqual(host_prefixed.returncode, 0, host_prefixed.stderr)

                forbidden = [
                    (
                        "mcp__github__update_issue",
                        {"issue_number": 145, "labels": ["agent:review-pending"]},
                    ),
                    (
                        "mcp__github__submit_pending_pull_request_review",
                        {"pull_request_number": 210, "event": "COMMENT"},
                    ),
                    (
                        "mcp__github__resolve_review_thread",
                        {"thread_id": "thread-1"},
                    ),
                    (
                        "mcp__codex_apps__github_update_issue",
                        {"issue_number": 145, "labels": ["agent:review-pending"]},
                    ),
                    (
                        "exec_command",
                        {
                            "cmd": "gh api --method PATCH repos/nerdchanii/rpm/issues/145 -f labels[]=agent:review-pending"
                        },
                    ),
                    ("exec_command", {"cmd": "gh pr merge 210 --squash"}),
                    ("exec_command", {"cmd": "gh pr comment 210 --body '@codex review'"}),
                    ("exec_command", {"cmd": "bash scripts/safe-direct-merge.sh 210"}),
                ]
                for tool, tool_input in forbidden:
                    with self.subTest(tool=tool, tool_input=tool_input):
                        denied = self.run_hook(
                            {
                                "hook_event_name": "PreToolUse",
                                "transcript_path": transcript,
                                "tool_name": tool,
                                "tool_input": tool_input,
                            }
                        )
                        self.assertEqual(denied.returncode, 2, denied.stderr)
            finally:
                self.run_hook(
                    {
                        "hook_event_name": "SubagentStop",
                        "agent_type": "rpm_existing_pr_adopter",
                        "agent_transcript_path": transcript,
                    }
                )

    def test_adopter_exec_allowlist_is_exact_and_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rpm-adopter-exec-hook-") as raw:
            transcript = str(Path(raw) / "transcript.jsonl")
            start = self.run_hook(
                {
                    "hook_event_name": "SubagentStart",
                    "agent_type": "rpm_existing_pr_adopter",
                    "agent_transcript_path": transcript,
                }
            )
            self.assertEqual(start.returncode, 0, start.stderr)
            try:
                allowed = (
                    "python3 scripts/materialize-existing-pr-adoption.py "
                    "--run-id adoption-run-228 --kind issues --payload-base64 e30=",
                    "python3 scripts/materialize-existing-pr-adoption.py "
                    "--run-id adoption-run-228 --kind prepared --payload-base64 e30=",
                    "python3 scripts/materialize-existing-pr-adoption.py "
                    "--run-id adoption-run-228 --kind request --payload-stdin",
                    "python3 scripts/authorize-existing-pr-adoption-mutation.py "
                    "--policy .agents/workflows/backlog-policy.json "
                    "--request-file /tmp/adoption-request.json",
                    "python3 scripts/write-existing-pr-adoption.py "
                    "--policy .agents/workflows/backlog-policy.json "
                    "--request-file /tmp/adoption-request.json",
                )
                for command in allowed:
                    with self.subTest(verdict="allowed", command=command):
                        result = self.run_hook(
                            {
                                "hook_event_name": "PreToolUse",
                                "transcript_path": transcript,
                                "tool_name": "exec_command",
                                "tool_input": {"cmd": command},
                            }
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)

                forbidden = (
                    "python3 -c 'print(1)'",
                    "python3 -c 'import urllib.request; urllib.request.urlopen(chr(104)+chr(116)+chr(116)+chr(112)+chr(115)+\"://example.invalid\")'",
                    "/bin/sh -c 'echo local-command'",
                    "bash -lc 'echo local-command'",
                    "printf aHR0cHM6Ly9leGFtcGxlLmludmFsaWQ= | base64 -d | sh",
                    "env python3 scripts/write-existing-pr-adoption.py --request-file /tmp/adoption-request.json",
                    "python3 ./scripts/write-existing-pr-adoption.py --request-file /tmp/adoption-request.json",
                    "python3 scripts/write-existing-pr-adoption.py --request-file /tmp/adoption-request.json --extra value",
                    "python3 scripts/write-existing-pr-adoption.py --request-file /tmp/adoption-request.json && gh api repos/nerdchanii/rpm/issues/145",
                    "python3 scripts/materialize-existing-pr-adoption.py --run-id ../escape --kind issues --payload-base64 e30=",
                    "python3 scripts/materialize-existing-pr-adoption.py --run-id adoption-run-228 --kind unknown --payload-base64 e30=",
                    "python3 scripts/materialize-existing-pr-adoption.py --run-id adoption-run-228 --kind issues --payload-base64 e30= --extra value",
                    "ls -la",
                )
                for command in forbidden:
                    with self.subTest(verdict="denied", command=command):
                        result = self.run_hook(
                            {
                                "hook_event_name": "PreToolUse",
                                "transcript_path": transcript,
                                "tool_name": "exec_command",
                                "tool_input": {"cmd": command},
                            }
                        )
                        self.assertEqual(result.returncode, 2, result.stderr)

                outside = Path(raw) / "outside"
                outside.mkdir()
                for event in (
                    {
                        "hook_event_name": "PreToolUse",
                        "transcript_path": transcript,
                        "tool_name": "exec_command",
                        "tool_input": {
                            "cmd": "python3 scripts/write-existing-pr-adoption.py --request-file /tmp/adoption-request.json",
                            "workdir": str(outside),
                        },
                    },
                    {
                        "hook_event_name": "PreToolUse",
                        "transcript_path": transcript,
                        "cwd": str(outside),
                        "tool_name": "exec_command",
                        "tool_input": {
                            "cmd": "python3 scripts/write-existing-pr-adoption.py --request-file /tmp/adoption-request.json",
                        },
                    },
                ):
                    with self.subTest(verdict="untrusted-workdir", event=event):
                        result = self.run_hook(event)
                        self.assertEqual(result.returncode, 2, result.stderr)
            finally:
                self.run_hook(
                    {
                        "hook_event_name": "SubagentStop",
                        "agent_type": "rpm_existing_pr_adopter",
                        "agent_transcript_path": transcript,
                    }
                )

    def test_issue_pr_only_handoff_materializes_a_confined_checker_input(self) -> None:
        fixture = self.load_adoption()
        fixture["ledger"]["comments"] = [
            self.ledger_record(fixture, "prepared", comment_id=81001),
            self.ledger_record(fixture, "label-mutation", comment_id=81002),
        ]
        encoded = base64.b64encode(
            json.dumps(fixture, ensure_ascii=False, sort_keys=True).encode("utf-8")
        ).decode("ascii")
        run_id = "test-materializer-228"
        result, event = self.run_json_command(
            [
                "python3",
                str(ADOPTION_MATERIALIZER),
                "--run-id",
                run_id,
                "--kind",
                "issues",
                "--payload-base64",
                encoded,
            ],
            {0},
        )
        data = event["data"]
        self.assertEqual(result.returncode, 0, data)
        self.assertEqual(data.get("status"), "materialized", data)
        handoff = Path(data["path"])
        self.assertEqual(
            handoff,
            Path("/tmp/rpm-existing-pr-adoption") / run_id / "issues.json",
        )
        self.assertEqual(json.loads(handoff.read_text()), fixture)

        checker_result, checker_event = self.run_json_command(
            [
                "python3",
                str(QUEUE_CHECK),
                "--policy",
                str(POLICY),
                "--issues-file",
                str(handoff),
                "--operation",
                "adopt-existing-pr",
            ],
            {0},
        )
        self.assertEqual(checker_result.returncode, 0, checker_event)
        self.assertEqual(checker_event["data"].get("status"), "adopt", checker_event)
        self.assertEqual(
            checker_event["data"].get("phase"), "label-mutation", checker_event
        )

        mutation_request = checker_event["data"].get("mutation_request")
        self.assertIsInstance(mutation_request, dict, checker_event)
        request_encoded = base64.b64encode(
            json.dumps(
                mutation_request, ensure_ascii=False, sort_keys=True
            ).encode("utf-8")
        ).decode("ascii")
        request_result, request_event = self.run_json_command(
            [
                "python3",
                str(ADOPTION_MATERIALIZER),
                "--run-id",
                run_id,
                "--kind",
                "request",
                "--payload-base64",
                request_encoded,
            ],
            {0},
        )
        self.assertEqual(request_result.returncode, 0, request_event)
        request_path = Path(request_event["data"]["path"])
        self.assertEqual(
            request_path,
            Path("/tmp/rpm-existing-pr-adoption") / run_id / "request.json",
        )
        helper_result, helper_event = self.run_json_command(
            [
                "python3",
                str(MUTATION_HELPER),
                "--policy",
                str(POLICY),
                "--request-file",
                str(request_path),
            ],
            {0},
        )
        self.assertEqual(helper_result.returncode, 0, helper_event)
        self.assertEqual(helper_event["data"].get("status"), "authorized", helper_event)

        prepared_snapshot = mutation_request.get("adoption_input")
        self.assertIsInstance(prepared_snapshot, dict, mutation_request)
        prepared_encoded = base64.b64encode(
            json.dumps(
                prepared_snapshot, ensure_ascii=False, sort_keys=True
            ).encode("utf-8")
        ).decode("ascii")
        prepared_result, prepared_event = self.run_json_command(
            [
                "python3",
                str(ADOPTION_MATERIALIZER),
                "--run-id",
                run_id,
                "--kind",
                "prepared",
                "--payload-base64",
                prepared_encoded,
            ],
            {0},
        )
        self.assertEqual(prepared_result.returncode, 0, prepared_event)
        prepared_path = Path(prepared_event["data"]["path"])
        self.assertEqual(
            prepared_path,
            Path("/tmp/rpm-existing-pr-adoption") / run_id / "prepared.json",
        )
        self.assertNotEqual(request_path, prepared_path)
        self.assertEqual(json.loads(prepared_path.read_text()), prepared_snapshot)

        writer_namespace = runpy.run_path(str(ADOPTION_WRITER))
        writer = writer_namespace.get("execute_adoption_phase")
        self.assertTrue(callable(writer), writer_namespace.keys())
        transport = FakeGithubAdoptionTransport(
            json.loads(prepared_path.read_text())
        )
        writer_result = writer(
            self.load_policy(), json.loads(prepared_path.read_text()), transport
        )
        self.assertEqual(writer_result.get("status"), "applied", writer_result)
        self.assertEqual(
            writer_result.get("phase"), "writer-lease", writer_result
        )

        rejected_result, rejected_event = self.run_json_command(
            [
                "python3",
                str(ADOPTION_MATERIALIZER),
                "--run-id",
                "../escape",
                "--kind",
                "issues",
                "--payload-base64",
                encoded,
            ],
            {1},
        )
        self.assertEqual(rejected_result.returncode, 1, rejected_event)
        self.assertEqual(rejected_event["data"].get("reason"), "run-id-invalid")

    def test_materializer_stdin_handles_payloads_larger_than_one_argv(self) -> None:
        payload = {"records": [{"value": "x" * 120_000}]}
        raw_payload = json.dumps(payload, ensure_ascii=False, sort_keys=True)
        result, event = self.run_json_command(
            [
                "python3",
                str(ADOPTION_MATERIALIZER),
                "--run-id",
                "stdin-materializer-228",
                "--kind",
                "issues",
                "--payload-stdin",
            ],
            {0},
            input_text=raw_payload,
        )
        self.assertEqual(result.returncode, 0, event)
        self.assertEqual(event["data"].get("status"), "materialized", event)
        self.assertEqual(
            json.loads(Path(event["data"]["path"]).read_text()), payload
        )

    def test_materializer_rejects_shared_or_symlinked_handoff_directories(self) -> None:
        namespace = runpy.run_path(str(ADOPTION_MATERIALIZER))
        materialize = namespace.get("materialize")
        self.assertTrue(callable(materialize), namespace.keys())
        with tempfile.TemporaryDirectory(prefix="rpm-materializer-root-") as raw:
            parent = Path(raw)
            outside = parent / "outside"
            outside.mkdir()
            materializer_globals = materialize.__globals__
            original_root = materializer_globals["RUN_ROOT"]

            try:
                shared_root = parent / "shared-root"
                shared_root.mkdir(mode=0o777)
                materializer_globals["RUN_ROOT"] = shared_root
                shared_result = materialize("run-228", "issues", encoded="e30=")
                self.assertEqual(shared_result.get("status"), "blocked", shared_result)

                symlink_root = parent / "symlink-root"
                symlink_root.symlink_to(outside, target_is_directory=True)
                materializer_globals["RUN_ROOT"] = symlink_root
                symlink_result = materialize("run-228", "issues", encoded="e30=")
                self.assertEqual(symlink_result.get("status"), "blocked", symlink_result)

                private_root = parent / "private-root"
                private_root.mkdir(mode=0o700)
                run_dir = private_root / "run-228"
                run_dir.symlink_to(outside, target_is_directory=True)
                materializer_globals["RUN_ROOT"] = private_root
                run_result = materialize("run-228", "issues", encoded="e30=")
                self.assertEqual(run_result.get("status"), "blocked", run_result)
            finally:
                materializer_globals["RUN_ROOT"] = original_root

    def test_project_read_failure_does_not_change_adoption_decision(self) -> None:
        fixture = self.load_adoption()
        fixture["project_inventory"] = {
            "required_for_execution": False,
            "read_status": "failed",
            "error": "missing read:project",
        }
        result, event = self.run_queue(fixture)
        data = self.assert_adoptable(result, event)
        self.assertEqual(data.get("project_inventory"), "unavailable-independent")

    def test_lifecycle_graph_and_every_edge_have_executable_fixtures(self) -> None:
        fixture = json.loads(LIFECYCLE_FIXTURE.read_text())
        policy = self.load_policy()
        contract = policy.get("lifecycle_contract")
        self.assertIsInstance(contract, dict)
        self.assertEqual(contract.get("initial_states"), fixture["initial_states"])
        self.assertEqual(contract.get("safe_stop_states"), fixture["safe_stop_states"])
        self.assertEqual(
            contract.get("external_terminal_states"),
            fixture["external_terminal_states"],
        )
        edge_fixtures = contract.get("edge_fixtures")
        self.assertIsInstance(edge_fixtures, dict)
        self.assertEqual(set(edge_fixtures), set(fixture["generic_edges"]))
        self.assertEqual(
            contract.get("operation_fixtures"),
            {"adopt-existing-pr": "adopt-existing-pr"},
        )
        for edge, descriptor in edge_fixtures.items():
            self.assertIsInstance(descriptor, dict, (edge, descriptor))
            self.assertEqual(
                descriptor,
                {
                    "path": "tests/fixtures/agent-workflow/lifecycle-edges.json",
                    "case": edge,
                },
            )

        result, event = self.run_queue(
            self.load_adoption(),
            operation="validate-lifecycle",
            fixture_override=fixture,
        )
        self.assertEqual(result.returncode, 0, event)
        self.assertEqual(event["data"].get("status"), "valid", event)

        for field, value in (
            ("source", "blocked"),
            ("target", "awaiting-merge"),
            ("verdict", "denied"),
        ):
            with self.subTest(executed_fixture_field=field):
                changed_fixture = copy.deepcopy(fixture)
                changed_fixture["edge_cases"][0][field] = value
                result, event = self.run_queue(
                    self.load_adoption(),
                    operation="validate-lifecycle",
                    fixture_override=changed_fixture,
                )
                self.assert_blocked(result, event)

        mutations = []
        policy = self.load_policy()
        policy["labels"]["orphan"] = "agent:orphan"
        policy["allowed_transitions"]["orphan"] = ["orphan"]
        mutations.append(("unreachable", policy))

        policy = self.load_policy()
        policy["labels"]["no-incoming"] = "agent:no-incoming"
        policy["allowed_transitions"]["no-incoming"] = ["blocked"]
        mutations.append(("no-incoming", policy))

        policy = self.load_policy()
        policy["labels"]["dead-end"] = "agent:dead-end"
        policy["allowed_transitions"]["ready"].append("dead-end")
        policy["allowed_transitions"]["dead-end"] = []
        mutations.append(("no-outgoing", policy))

        policy = self.load_policy()
        policy["lifecycle_contract"]["edge_fixtures"].pop("ready->claimed")
        mutations.append(("missing-edge-fixture", policy))

        for name, bad_policy in mutations:
            with self.subTest(name=name):
                result, event = self.run_queue(
                    self.load_adoption(),
                    operation="validate-lifecycle",
                    policy=bad_policy,
                    fixture_override=fixture,
                )
                self.assert_blocked(result, event)

    def test_completed_untracked_pr_is_adoption_required_before_selection(self) -> None:
        fixture = self.load_adoption()
        fixture["issues"][0].pop("implementation_complete", None)
        fixture["issues"][0]["completed_pr_evidence"] = copy.deepcopy(
            fixture["evidence"]
        )
        fixture["issues"].append(
            {
                "number": 300,
                "url": "https://github.com/nerdchanii/rpm/issues/300",
                "state": "OPEN",
                "labels": ["agent:ready"],
                "closing_prs": [
                    {
                        "number": 3000,
                        "state": "CLOSED",
                        "repository": "nerdchanii/rpm",
                    }
                ],
                "execution": {
                    "approval_id": "approval-300",
                    "plan_revision": "plan-300",
                    "scope_hash": "sha256:" + "3" * 64,
                    "executor": "local",
                },
            }
        )
        fixture["execution_inventory"]["records"].append(
            {"repository": "nerdchanii/rpm", "number": 300}
        )
        fixture["execution_inventory"]["count"] = 2
        fixture["closing_pr_inventory"]["records"].append(
            {
                "repository": "nerdchanii/rpm",
                "issue": 300,
                "pr": 3000,
            }
        )
        fixture["closing_pr_inventory"]["count"] = 2
        first_result, first_event = self.run_queue(
            fixture, operation="select-execution"
        )
        first = self.assert_blocked(first_result, first_event)
        self.assertEqual(first.get("reason"), "adoption-required", first)
        self.assertEqual(first.get("issues"), [145], first)

        second_result, second_event = self.run_queue(
            fixture, operation="select-execution"
        )
        self.assertEqual(first_event, second_event)
        self.assertEqual(first_result.returncode, second_result.returncode)

        policy = self.load_policy()
        policy.pop("existing_pr_adoption")
        result, event = self.run_queue(
            fixture, operation="select-execution", policy=policy
        )
        data = self.assert_blocked(result, event)
        self.assertEqual(data.get("reason"), "wiring-blocked", data)

    def test_adoption_required_is_derived_from_complete_current_head_evidence(self) -> None:
        fixture = self.load_adoption()
        fixture["issues"][0]["implementation_complete"] = False
        fixture["issues"][0]["completed_pr_evidence"] = copy.deepcopy(
            fixture["evidence"]
        )
        result, event = self.run_queue(fixture, operation="select-execution")
        data = self.assert_blocked(result, event)
        self.assertEqual(data.get("reason"), "adoption-required", data)
        self.assertEqual(data.get("issues"), [145], data)

        variants: list[tuple[str, dict[str, object]]] = []
        missing = self.load_adoption()
        missing["issues"][0]["implementation_complete"] = True
        missing["issues"][0].pop("completed_pr_evidence", None)
        variants.append(("missing", missing))

        false_value = self.load_adoption()
        false_value["issues"][0]["implementation_complete"] = True
        false_value["issues"][0]["completed_pr_evidence"] = False
        variants.append(("false", false_value))

        forged = self.load_adoption()
        forged["issues"][0]["implementation_complete"] = True
        forged["issues"][0]["completed_pr_evidence"] = copy.deepcopy(
            forged["evidence"]
        )
        forged["issues"][0]["completed_pr_evidence"]["checks"]["head_sha"] = (
            "c" * 40
        )
        variants.append(("forged-wrong-head", forged))

        for name, changed in variants:
            with self.subTest(name=name):
                result, event = self.run_queue(
                    changed, operation="select-execution"
                )
                data = self.assert_blocked(result, event)
                self.assertEqual(
                    data.get("reason"), "adoption-evidence-incomplete", data
                )

    def test_select_execution_skips_unfinished_draft_closing_prs(self) -> None:
        fixture = self.load_adoption()
        fixture["issues"][0].pop("completed_pr_evidence", None)
        fixture["issues"][0]["closing_prs"][0]["is_draft"] = True
        fixture["issues"].append(
            {
                "number": 146,
                "url": "https://github.com/nerdchanii/rpm/issues/146",
                "state": "OPEN",
                "labels": ["agent:ready", "documentation"],
                "closing_prs": [],
                "execution": {
                    "approval_id": "approval-146",
                    "plan_revision": "plan-146",
                    "scope_hash": "sha256:" + "3" * 64,
                    "executor": "local",
                },
            }
        )
        fixture["execution_inventory"]["records"].append(
            {"repository": "nerdchanii/rpm", "number": 146}
        )
        fixture["execution_inventory"]["count"] = 2
        result, event = self.run_queue(fixture, operation="select-execution")
        data = event["data"]
        self.assertEqual(result.returncode, 0, data)
        self.assertEqual(data.get("status"), "selected", data)
        self.assertEqual(data.get("issues"), [146], data)

    def test_select_execution_skips_unfinished_non_draft_closing_prs(self) -> None:
        fixture = self.load_adoption()
        fixture["issues"][0].pop("completed_pr_evidence", None)
        fixture["issues"][0]["closing_prs"][0]["is_draft"] = False
        fixture["issues"].append(
            {
                "number": 146,
                "url": "https://github.com/nerdchanii/rpm/issues/146",
                "state": "OPEN",
                "labels": ["agent:ready", "documentation"],
                "closing_prs": [],
                "execution": {
                    "approval_id": "approval-146",
                    "plan_revision": "plan-146",
                    "scope_hash": "sha256:" + "3" * 64,
                    "executor": "local",
                },
            }
        )
        fixture["execution_inventory"]["records"].append(
            {"repository": "nerdchanii/rpm", "number": 146}
        )
        fixture["execution_inventory"]["count"] = 2
        result, event = self.run_queue(fixture, operation="select-execution")
        data = event["data"]
        self.assertEqual(result.returncode, 0, data)
        self.assertEqual(data.get("status"), "selected", data)
        self.assertEqual(data.get("issues"), [146], data)

    def test_execution_inventory_is_complete_before_orphan_candidate_filtering(self) -> None:
        variants: list[tuple[str, dict[str, object]]] = []
        baseline = self.load_adoption()
        baseline["issues"] = [
            {
                "number": 145,
                "url": "https://github.com/nerdchanii/rpm/issues/145",
                "state": "OPEN",
                "labels": ["agent:ready", "documentation"],
                "closing_prs": [],
                "execution": {
                    "approval_id": "approval-145",
                    "plan_revision": "plan-145",
                    "scope_hash": "sha256:" + "3" * 64,
                    "executor": "local",
                },
            }
        ]
        for field, value in (
            ("repository", "other/rpm"),
            ("source", "unknown-source"),
            ("read_complete", False),
            ("pagination_complete", False),
            ("has_next_page", True),
            ("count", 2),
        ):
            fixture = copy.deepcopy(baseline)
            fixture["execution_inventory"][field] = value
            variants.append((field, fixture))

        fixture = copy.deepcopy(baseline)
        fixture["execution_inventory"]["records"][0]["repository"] = "other/rpm"
        variants.append(("record-repository", fixture))

        fixture = copy.deepcopy(baseline)
        fixture["execution_inventory"]["records"][0]["number"] = 999
        variants.append(("record-identity", fixture))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_queue(
                    fixture, operation="select-execution"
                )
                data = self.assert_blocked(result, event)
                self.assertTrue(
                    str(data.get("reason", "")).startswith("execution-inventory-"),
                    data,
                )

    def test_mixed_issue_inventory_lists_only_nonempty_closing_relationships(
        self,
    ) -> None:
        baseline = self.load_adoption()
        baseline["issues"][0]["completed_pr_evidence"] = copy.deepcopy(
            baseline["evidence"]
        )
        baseline["issues"].append(
            {
                "number": 146,
                "url": "https://github.com/nerdchanii/rpm/issues/146",
                "state": "OPEN",
                "labels": ["agent:ready", "documentation"],
                "closing_prs": [],
                "execution": {
                    "approval_id": "approval-146",
                    "plan_revision": "plan-146",
                    "scope_hash": "sha256:" + "3" * 64,
                    "executor": "local",
                },
            }
        )
        baseline["execution_inventory"]["records"].append(
            {"repository": "nerdchanii/rpm", "number": 146}
        )
        baseline["execution_inventory"]["count"] = 2

        # The repository relationship inventory contains one row for the one
        # non-empty relationship. Issue 146 is represented by the complete
        # issue inventory and correctly contributes no synthetic PR row.
        self.assertEqual(baseline["closing_pr_inventory"]["count"], 1)
        self.assertEqual(
            baseline["closing_pr_inventory"]["records"],
            [
                {
                    "repository": "nerdchanii/rpm",
                    "issue": 145,
                    "pr": 210,
                    "state": "OPEN",
                    "base_ref": "main",
                    "base_sha": BASE_SHA,
                    "head_ref": "feat/issue-145-workspaces",
                    "head_sha": HEAD_SHA,
                }
            ],
        )

        result, event = self.run_queue(
            baseline, operation="select-execution"
        )
        data = self.assert_blocked(result, event)
        self.assertEqual(data.get("reason"), "adoption-required", data)
        self.assertEqual(data.get("issues"), [145], data)

        selectable = copy.deepcopy(baseline)
        selectable["issues"][0].pop("completed_pr_evidence")
        selectable["issues"][0]["closing_prs"][0]["state"] = "CLOSED"
        selectable["closing_pr_inventory"]["records"][0]["state"] = "CLOSED"
        result, event = self.run_queue(
            selectable, operation="select-execution"
        )
        data = event["data"]
        self.assertEqual(result.returncode, 0, data)
        self.assertEqual(data.get("status"), "selected", data)
        self.assertEqual(data.get("reason"), "ready", data)
        self.assertEqual(data.get("issues"), [146], data)

    def test_orphan_detection_requires_repository_closing_pr_inventory(self) -> None:
        baseline = self.load_adoption()
        baseline["issues"][0]["labels"] = ["agent:claimed", "documentation"]

        result, event = self.run_queue(baseline, operation="select-execution")
        data = event["data"]
        self.assertEqual(result.returncode, 0, data)
        self.assertEqual(data.get("status"), "no-work", data)
        self.assertEqual(data.get("reason"), "active-work", data)

        variants: list[tuple[str, dict[str, object]]] = []
        missing = copy.deepcopy(baseline)
        missing.pop("closing_pr_inventory")
        variants.append(("missing", missing))

        for field, value in (
            ("repository", "other/rpm"),
            ("source", "unknown-source"),
            ("read_complete", False),
            ("pagination_complete", False),
            ("has_next_page", True),
            ("count", 2),
        ):
            fixture = copy.deepcopy(baseline)
            fixture["closing_pr_inventory"][field] = value
            variants.append((field, fixture))

        omitted = copy.deepcopy(baseline)
        omitted["closing_pr_inventory"]["records"] = []
        omitted["closing_pr_inventory"]["count"] = 0
        variants.append(("omitted-open-closing-pr", omitted))

        wrong_issue = copy.deepcopy(baseline)
        wrong_issue["closing_pr_inventory"]["records"][0]["issue"] = 146
        variants.append(("wrong-issue-binding", wrong_issue))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_queue(
                    fixture, operation="select-execution"
                )
                data = self.assert_blocked(result, event)
                self.assertTrue(
                    str(data.get("reason", "")).startswith(
                        "closing-pr-inventory-"
                    ),
                    data,
                )

    def test_select_execution_requires_repository_closing_inventory_for_empty_issue_views(
        self,
    ) -> None:
        fixture = self.load_adoption()
        fixture["issues"][0]["closing_prs"] = []
        fixture.pop("closing_pr_inventory")

        result, event = self.run_queue(fixture, operation="select-execution")
        data = self.assert_blocked(result, event)
        self.assertTrue(
            str(data.get("reason", "")).startswith("closing-pr-inventory-"),
            data,
        )

    def test_select_execution_reports_closing_inventory_failure_before_adoption(
        self,
    ) -> None:
        baseline = self.load_adoption()
        baseline["issues"][0]["completed_pr_evidence"] = copy.deepcopy(
            baseline["evidence"]
        )

        variants: list[tuple[str, dict[str, object]]] = []
        missing = copy.deepcopy(baseline)
        missing.pop("closing_pr_inventory")
        variants.append(("missing", missing))
        for field, value in (
            ("source", "unknown-source"),
            ("read_complete", False),
            ("pagination_complete", False),
            ("has_next_page", True),
            ("count", 2),
        ):
            partial = copy.deepcopy(baseline)
            partial["closing_pr_inventory"][field] = value
            variants.append((field, partial))
        omitted = copy.deepcopy(baseline)
        omitted["closing_pr_inventory"]["records"] = []
        omitted["closing_pr_inventory"]["count"] = 0
        variants.append(("omitted-closing-pr", omitted))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_queue(
                    fixture, operation="select-execution"
                )
                data = self.assert_blocked(result, event)
                self.assertNotEqual(data.get("reason"), "adoption-required", data)
                self.assertTrue(
                    str(data.get("reason", "")).startswith(
                        "closing-pr-inventory-"
                    ),
                    data,
                )

        incomplete = copy.deepcopy(baseline)
        incomplete["issues"][0]["completed_pr_evidence"]["checks"][
            "read_complete"
        ] = False
        result, event = self.run_queue(
            incomplete, operation="select-execution"
        )
        data = self.assert_blocked(result, event)
        self.assertEqual(data.get("reason"), "adoption-evidence-incomplete", data)

        result, event = self.run_queue(
            baseline, operation="select-execution"
        )
        data = self.assert_blocked(result, event)
        self.assertEqual(data.get("reason"), "adoption-required", data)
        self.assertEqual(data.get("issues"), [145], data)

    def run_merge(
        self, fixture: dict[str, object], policy: dict[str, object] | None = None
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
        with tempfile.TemporaryDirectory(prefix="rpm-merge-228-") as raw:
            directory = Path(raw)
            fixture_path = self.write_json(directory, "merge.json", fixture)
            policy_path = POLICY
            if policy is not None:
                policy_path = self.write_json(directory, "policy.json", policy)
            return self.run_json_command(
                [
                    "python3",
                    str(MERGE_CHECK),
                    "--policy",
                    str(policy_path),
                    "--issues-file",
                    str(fixture_path),
                    "--operation",
                    "select-merge",
                ],
                {0, 1},
            )

    def test_dependent_pr_inventory_is_complete_and_requires_retarget(self) -> None:
        fixture = json.loads(DEPENDENT_FIXTURE.read_text())
        result, event = self.run_merge(fixture)
        data = self.assert_blocked(result, event)
        self.assertEqual(data.get("reason"), "retarget-required", data)
        self.assertEqual(data.get("dependent_prs"), [216], data)

        divergent = copy.deepcopy(fixture)
        divergent["issues"][0]["closing_prs"][0]["dependent_prs"]["records"][0][
            "base_sha"
        ] = "d" * 40
        result, event = self.run_merge(divergent)
        data = self.assert_blocked(result, event)
        self.assertEqual(data.get("reason"), "retarget-required", data)
        self.assertEqual(data.get("dependent_prs"), [216], data)

        for field, value in (
            ("read_complete", False),
            ("pagination_complete", False),
            ("has_next_page", True),
            ("count", 2),
            ("source", "unknown-source"),
        ):
            with self.subTest(field=field):
                changed = copy.deepcopy(fixture)
                changed["issues"][0]["closing_prs"][0]["dependent_prs"][field] = value
                result, event = self.run_merge(changed)
                self.assert_blocked(result, event)

        closed = copy.deepcopy(fixture)
        closed["issues"][0]["closing_prs"][0]["dependent_prs"]["records"][0][
            "state"
        ] = "CLOSED"
        result, event = self.run_merge(closed)
        data = self.assert_blocked(result, event)
        self.assertEqual(data.get("reason"), "dependent-pr-record-identity", data)

    def test_merge_inventory_preserves_closed_relationships_without_selecting_them(
        self,
    ) -> None:
        fixture = json.loads(DEPENDENT_FIXTURE.read_text())
        candidate = fixture["issues"][0]["closing_prs"][0]
        candidate["dependent_prs"]["records"] = []
        candidate["dependent_prs"]["count"] = 0

        closed_relationship = {
            "number": 214,
            "state": "CLOSED",
            "repository": "nerdchanii/rpm",
            "base_ref": "main",
            "base_sha": "d" * 40,
            "head_ref": "feat/issue-189-operating-model",
            "head_sha": "e" * 40,
        }
        noncandidate = {
            "number": 189,
            "url": "https://github.com/nerdchanii/rpm/issues/189",
            "state": "OPEN",
            "labels": ["agent:ready", "documentation"],
            "closing_pr_inventory": {
                "repository": "nerdchanii/rpm",
                "source": "github-closing-issue-references-v1",
                "read_complete": True,
                "pagination_complete": True,
                "has_next_page": False,
                "count": 1,
                "records": [
                    {
                        "repository": "nerdchanii/rpm",
                        "pr": 214,
                        "state": "CLOSED",
                    }
                ],
            },
            "closing_prs": [closed_relationship],
        }
        fixture["issues"].append(noncandidate)
        fixture["issue_inventory"]["records"].append(
            {
                "number": 189,
                "state": "OPEN",
                "lifecycle_state": "ready",
            }
        )
        fixture["issue_inventory"]["count"] = 2

        result, event = self.run_merge(fixture)
        data = event["data"]
        self.assertEqual(result.returncode, 0, data)
        self.assertEqual(data.get("status"), "merge", data)
        self.assertEqual(data.get("issue"), 145, data)
        self.assertEqual(data.get("pr"), 210, data)

        variants: list[tuple[str, dict[str, object]]] = []
        missing = copy.deepcopy(fixture)
        missing["issues"][1]["closing_pr_inventory"]["records"] = []
        missing["issues"][1]["closing_pr_inventory"]["count"] = 0
        variants.append(("missing", missing))

        extra = copy.deepcopy(fixture)
        extra_records = extra["issues"][1]["closing_pr_inventory"][
            "records"
        ]
        extra_records.append(
            {
                "repository": "nerdchanii/rpm",
                "pr": 215,
                "state": "CLOSED",
            }
        )
        extra["issues"][1]["closing_pr_inventory"]["count"] = 2
        variants.append(("extra", extra))

        duplicate = copy.deepcopy(fixture)
        duplicate_records = duplicate["issues"][1]["closing_pr_inventory"][
            "records"
        ]
        duplicate_records.append(copy.deepcopy(duplicate_records[0]))
        duplicate["issues"][1]["closing_pr_inventory"]["count"] = 2
        variants.append(("duplicate", duplicate))

        wrong_state = copy.deepcopy(fixture)
        wrong_state["issues"][1]["closing_pr_inventory"]["records"][0][
            "state"
        ] = "OPEN"
        variants.append(("wrong-state", wrong_state))

        for name, changed in variants:
            with self.subTest(name=name):
                result, event = self.run_merge(changed)
                data = self.assert_blocked(result, event)
                self.assertTrue(
                    str(data.get("reason", "")).startswith(
                        "closing-pr-inventory-"
                    ),
                    data,
                )

    def test_merge_gate_binds_selected_head_and_keeps_batch_limit_one(self) -> None:
        fixture = json.loads(DEPENDENT_FIXTURE.read_text())
        dependents = fixture["issues"][0]["closing_prs"][0]["dependent_prs"]
        dependents["records"] = []
        dependents["count"] = 0

        second = copy.deepcopy(fixture["issues"][0])
        second["number"] = 146
        second["url"] = "https://github.com/nerdchanii/rpm/issues/146"
        second["closing_prs"][0]["number"] = 217
        second["closing_pr_inventory"]["records"] = [
            {"repository": "nerdchanii/rpm", "pr": 217, "is_draft": False}
        ]
        fixture["issues"].append(second)
        fixture["issue_inventory"]["records"].append(
            {"number": 146, "state": "OPEN", "lifecycle_state": "awaiting-merge"}
        )
        fixture["issue_inventory"]["count"] = 2

        result, event = self.run_merge(fixture)
        data = event["data"]
        self.assertEqual(result.returncode, 0, data)
        self.assertEqual(data.get("status"), "merge", data)
        self.assertEqual(data.get("issue"), 145, data)
        self.assertEqual(data.get("pr"), 210, data)
        self.assertEqual(data.get("head_sha"), HEAD_SHA, data)
        self.assertEqual(data.get("batch_limit"), 1, data)

        changed = copy.deepcopy(fixture)
        changed["selected_head_sha"] = "c" * 40
        result, event = self.run_merge(changed)
        self.assert_blocked(result, event)

    def test_merge_gate_requires_a_ready_non_draft_pull_request(self) -> None:
        baseline = json.loads(DEPENDENT_FIXTURE.read_text())
        pr = baseline["issues"][0]["closing_prs"][0]
        pr["dependent_prs"]["records"] = []
        pr["dependent_prs"]["count"] = 0

        for name, field, value in (
            ("normalized-draft", "is_draft", True),
            ("raw-draft", "draft", True),
        ):
            with self.subTest(name=name):
                fixture = copy.deepcopy(baseline)
                fixture["issues"][0]["closing_prs"][0][field] = value
                result, event = self.run_merge(fixture)
                data = self.assert_blocked(result, event)
                self.assertEqual(data.get("reason"), "pr-is-draft", data)

        missing = copy.deepcopy(baseline)
        missing["issues"][0]["closing_prs"][0].pop("is_draft")
        result, event = self.run_merge(missing)
        data = self.assert_blocked(result, event)
        self.assertEqual(data.get("reason"), "selected-pr-ready-state-invalid", data)

        mismatched_evidence = copy.deepcopy(baseline)
        mismatched_evidence["selected_pr_evidence"]["is_draft"] = True
        result, event = self.run_merge(mismatched_evidence)
        data = self.assert_blocked(result, event)
        self.assertEqual(data.get("reason"), "selected-pr-evidence-mismatch", data)

    def test_merge_checks_require_a_complete_selected_head_inventory(self) -> None:
        baseline = json.loads(DEPENDENT_FIXTURE.read_text())
        pr = baseline["issues"][0]["closing_prs"][0]
        pr["dependent_prs"]["records"] = []
        pr["dependent_prs"]["count"] = 0
        records = copy.deepcopy(pr["checks"]["records"])
        pr["checks"] = {
            "source": "github-check-runs-v1",
            "repository": baseline["repository"],
            "pr": pr["number"],
            "head_sha": HEAD_SHA,
            "read_complete": True,
            "pagination_complete": True,
            "has_next_page": False,
            "count": len(records),
            "records": records,
        }

        result, event = self.run_merge(baseline)
        data = event["data"]
        self.assertEqual(result.returncode, 0, data)
        self.assertEqual(data.get("status"), "merge", data)

        third_party = copy.deepcopy(baseline)
        third_party["issues"][0]["closing_prs"][0]["checks"]["records"].append(
            {
                "name": "coverage-app",
                "conclusion": "success",
                "head_sha": HEAD_SHA,
                "source": "third-party-app",
                "workflow_run_id": 91002,
            }
        )
        third_party["issues"][0]["closing_prs"][0]["checks"]["count"] = 3
        result, event = self.run_merge(third_party)
        self.assertEqual(result.returncode, 0, event)
        self.assertEqual(event["data"].get("status"), "merge", event)

        p3 = copy.deepcopy(baseline)
        p3["issues"][0]["closing_prs"][0]["findings"]["items"] = [
            {
                "id": "P3-fixture",
                "source_id": "review-thread-P3-fixture",
                "head_sha": HEAD_SHA,
                "severity": "P3",
            }
        ]
        p3["issues"][0]["closing_prs"][0]["findings"]["count"] = 1
        result, event = self.run_merge(p3)
        self.assertEqual(result.returncode, 0, event)
        self.assertEqual(event["data"].get("status"), "merge", event)

        variants: list[tuple[str, dict[str, object]]] = []
        legacy = copy.deepcopy(baseline)
        legacy["issues"][0]["closing_prs"][0]["checks"] = {
            "metadata": "success",
            "verify": "success",
        }
        variants.append(("legacy-dict", legacy))

        duplicate = copy.deepcopy(baseline)
        checks = duplicate["issues"][0]["closing_prs"][0]["checks"]
        checks["records"].append(copy.deepcopy(checks["records"][0]))
        checks["count"] = 3
        variants.append(("duplicate-name", duplicate))

        for field, value in (
            ("source", "unknown-source"),
            ("head_sha", "c" * 40),
            ("read_complete", False),
            ("pagination_complete", False),
            ("has_next_page", True),
            ("count", 3),
        ):
            fixture = copy.deepcopy(baseline)
            fixture["issues"][0]["closing_prs"][0]["checks"][field] = value
            variants.append((field, fixture))

        wrong_record_head = copy.deepcopy(baseline)
        wrong_record_head["issues"][0]["closing_prs"][0]["checks"][
            "records"
        ][0]["head_sha"] = "c" * 40
        variants.append(("record-wrong-head", wrong_record_head))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_merge(fixture)
                data = self.assert_blocked(result, event)
                self.assertIn("checks", str(data.get("reason", "")), data)

    def test_merge_gate_treats_terminal_non_success_checks_as_failures(self) -> None:
        baseline = json.loads(DEPENDENT_FIXTURE.read_text())
        pr = baseline["issues"][0]["closing_prs"][0]
        pr["dependent_prs"]["records"] = []
        pr["dependent_prs"]["count"] = 0

        for conclusion in (
            "failure",
            "cancelled",
            "startup_failure",
            "stale",
            "skipped",
            "neutral",
        ):
            with self.subTest(conclusion=conclusion):
                fixture = copy.deepcopy(baseline)
                fixture["issues"][0]["closing_prs"][0]["checks"]["records"][1][
                    "conclusion"
                ] = conclusion
                result, event = self.run_merge(fixture)
                data = self.assert_blocked(result, event)
                self.assertEqual(data.get("reason"), "checks-failed", data)
                self.assertEqual(data.get("checks"), ["verify"], data)

    def test_merge_gate_requires_a_positive_follow_up_issue(self) -> None:
        fixture = json.loads(DEPENDENT_FIXTURE.read_text())
        pr = fixture["issues"][0]["closing_prs"][0]
        pr["dependent_prs"]["records"] = []
        pr["dependent_prs"]["count"] = 0
        for follow_up_issue in (True, 0, -1):
            with self.subTest(follow_up_issue=follow_up_issue):
                changed = copy.deepcopy(fixture)
                changed_pr = changed["issues"][0]["closing_prs"][0]
                changed_pr["findings"]["items"] = [
                    {
                        "id": "P2-follow-up",
                        "source_id": "review-thread-follow-up",
                        "head_sha": HEAD_SHA,
                        "severity": "P2",
                        "disposition": "defer-follow-up",
                        "owner": "issue-229",
                        "follow_up_issue": follow_up_issue,
                    }
                ]
                changed_pr["findings"]["count"] = 1
                result, event = self.run_merge(changed)
                data = self.assert_blocked(result, event)
                self.assertEqual(
                    data.get("reason"), "follow-up-owner-incomplete", data
                )

    def test_merge_checks_reject_legacy_lists_and_bind_repo_pr_head_and_runs(
        self,
    ) -> None:
        baseline = json.loads(DEPENDENT_FIXTURE.read_text())
        pr = baseline["issues"][0]["closing_prs"][0]
        pr["dependent_prs"]["records"] = []
        pr["dependent_prs"]["count"] = 0
        records = copy.deepcopy(pr["checks"]["records"])
        pr["checks"] = {
            "source": "github-check-runs-v1",
            "repository": baseline["repository"],
            "pr": pr["number"],
            "head_sha": HEAD_SHA,
            "read_complete": True,
            "pagination_complete": True,
            "has_next_page": False,
            "count": len(records),
            "records": records,
        }

        result, event = self.run_merge(baseline)
        self.assertEqual(result.returncode, 0, event)
        self.assertEqual(event["data"].get("status"), "merge", event)

        variants: list[tuple[str, dict[str, object]]] = []
        for name, legacy_records in (
            ("legacy-empty-list", []),
            ("legacy-one-record-list", records[:1]),
            ("legacy-complete-list", records),
        ):
            fixture = copy.deepcopy(baseline)
            fixture_pr = fixture["issues"][0]["closing_prs"][0]
            fixture_pr["checks"] = copy.deepcopy(legacy_records)
            fixture_pr["checks_read_complete"] = True
            fixture_pr["checks_pagination_complete"] = True
            fixture_pr["checks_has_next_page"] = False
            fixture_pr["checks_count"] = len(legacy_records)
            variants.append((name, fixture))

        for field, value in (
            ("repository", None),
            ("repository", "other/rpm"),
            ("pr", None),
            ("pr", 211),
            ("source", "unknown-source"),
            ("head_sha", "c" * 40),
            ("pagination_complete", False),
            ("has_next_page", True),
            ("count", 3),
        ):
            fixture = copy.deepcopy(baseline)
            checks = fixture["issues"][0]["closing_prs"][0]["checks"]
            if value is None:
                checks.pop(field)
                name = f"missing-{field}"
            else:
                checks[field] = value
                name = f"wrong-{field}"
            variants.append((name, fixture))

        duplicate_run = copy.deepcopy(baseline)
        duplicate_checks = duplicate_run["issues"][0]["closing_prs"][0][
            "checks"
        ]
        duplicate_checks["records"][1]["workflow_run_id"] = duplicate_checks[
            "records"
        ][0]["workflow_run_id"]
        variants.append(("duplicate-workflow-run", duplicate_run))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_merge(fixture)
                data = self.assert_blocked(result, event)
                self.assertIn("checks", str(data.get("reason", "")), data)

    def test_merge_findings_require_a_complete_selected_head_inventory(self) -> None:
        baseline = json.loads(DEPENDENT_FIXTURE.read_text())
        pr = baseline["issues"][0]["closing_prs"][0]
        pr["dependent_prs"]["records"] = []
        pr["dependent_prs"]["count"] = 0
        pr.pop("unresolved_p0_p1", None)
        pr["findings"] = {
            "source": "current-head-review-findings-v1",
            "repository": baseline["repository"],
            "pr": pr["number"],
            "head_sha": HEAD_SHA,
            "read_complete": True,
            "pagination_complete": True,
            "has_next_page": False,
            "count": 0,
            "items": [],
        }

        result, event = self.run_merge(baseline)
        data = event["data"]
        self.assertEqual(result.returncode, 0, data)
        self.assertEqual(data.get("status"), "merge", data)

        variants: list[tuple[str, dict[str, object]]] = []
        legacy = copy.deepcopy(baseline)
        legacy_pr = legacy["issues"][0]["closing_prs"][0]
        legacy_pr.pop("findings")
        legacy_pr["unresolved_p0_p1"] = False
        variants.append(("legacy-boolean", legacy))

        for field, value in (
            ("source", "unknown-source"),
            ("head_sha", "c" * 40),
            ("read_complete", False),
            ("pagination_complete", False),
            ("has_next_page", True),
            ("count", 1),
        ):
            fixture = copy.deepcopy(baseline)
            fixture["issues"][0]["closing_prs"][0]["findings"][field] = value
            variants.append((field, fixture))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_merge(fixture)
                data = self.assert_blocked(result, event)
                self.assertIn("finding", str(data.get("reason", "")), data)

    def test_merge_findings_bind_repository_pr_and_head_identity(self) -> None:
        baseline = json.loads(DEPENDENT_FIXTURE.read_text())
        pr = baseline["issues"][0]["closing_prs"][0]
        pr["dependent_prs"]["records"] = []
        pr["dependent_prs"]["count"] = 0
        pr["findings"]["repository"] = baseline["repository"]
        pr["findings"]["pr"] = pr["number"]

        result, event = self.run_merge(baseline)
        self.assertEqual(result.returncode, 0, event)
        self.assertEqual(event["data"].get("status"), "merge", event)

        variants: list[tuple[str, dict[str, object]]] = []
        for field, value in (
            ("repository", None),
            ("repository", "other/rpm"),
            ("pr", None),
            ("pr", 211),
            ("head_sha", None),
            ("head_sha", "c" * 40),
        ):
            fixture = copy.deepcopy(baseline)
            findings = fixture["issues"][0]["closing_prs"][0]["findings"]
            if value is None:
                findings.pop(field)
                name = f"missing-{field}"
            else:
                findings[field] = value
                name = f"wrong-{field}"
            variants.append((name, fixture))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_merge(fixture)
                data = self.assert_blocked(result, event)
                self.assertIn("finding", str(data.get("reason", "")), data)

    def test_dependent_retarget_binds_selected_pr_repository_and_refs(self) -> None:
        baseline = json.loads(DEPENDENT_FIXTURE.read_text())
        pr = baseline["issues"][0]["closing_prs"][0]
        baseline["selected_pr_evidence"] = {
            "repository": baseline["repository"],
            "number": pr["number"],
            "base_ref": pr["base_ref"],
            "base_sha": pr["base_sha"],
            "head_ref": pr["head_ref"],
            "head_sha": pr["head_sha"],
            "is_draft": pr["is_draft"],
        }

        result, event = self.run_merge(baseline)
        data = self.assert_blocked(result, event)
        self.assertEqual(data.get("reason"), "retarget-required", data)

        missing = copy.deepcopy(baseline)
        missing.pop("selected_pr_evidence")
        result, event = self.run_merge(missing)
        data = self.assert_blocked(result, event)
        self.assertEqual(
            data.get("reason"), "selected-pr-evidence-mismatch", data
        )

        variants: list[tuple[str, dict[str, object]]] = []
        for field, value in (
            ("repository", "other/rpm"),
            ("number", 211),
            ("base_ref", "develop"),
            ("base_sha", "d" * 40),
            ("head_ref", "feat/other"),
            ("head_sha", "d" * 40),
        ):
            fixture = copy.deepcopy(baseline)
            fixture["selected_pr_evidence"][field] = value
            variants.append((f"inventory-{field}", fixture))

        for field, value in (
            ("base_ref", "develop"),
            ("base_sha", "d" * 40),
            ("head_ref", "feat/other"),
        ):
            fixture = copy.deepcopy(baseline)
            fixture["issues"][0]["closing_prs"][0][field] = value
            variants.append((f"selected-pr-{field}", fixture))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_merge(fixture)
                data = self.assert_blocked(result, event)
                self.assertEqual(
                    data.get("reason"),
                    "selected-pr-evidence-mismatch",
                    data,
                )

    def test_merge_gate_requires_complete_issue_and_closing_pr_inventories(self) -> None:
        baseline = json.loads(DEPENDENT_FIXTURE.read_text())
        dependents = baseline["issues"][0]["closing_prs"][0]["dependent_prs"]
        dependents["records"] = []
        dependents["count"] = 0

        variants: list[tuple[str, dict[str, object]]] = []
        for field, value in (
            ("repository", "other/rpm"),
            ("source", "unknown-source"),
            ("read_complete", False),
            ("pagination_complete", False),
            ("has_next_page", True),
            ("count", 2),
        ):
            fixture = copy.deepcopy(baseline)
            fixture["issue_inventory"][field] = value
            variants.append((f"issue-{field}", fixture))

        for field, value in (
            ("source", "unknown-source"),
            ("read_complete", False),
            ("pagination_complete", False),
            ("has_next_page", True),
            ("count", 2),
        ):
            fixture = copy.deepcopy(baseline)
            fixture["issues"][0]["closing_pr_inventory"][field] = value
            variants.append((f"closing-pr-{field}", fixture))

        omitted_lower = copy.deepcopy(baseline)
        omitted_lower["issue_inventory"]["records"].insert(
            0,
            {"number": 100, "state": "OPEN", "lifecycle_state": "awaiting-merge"},
        )
        omitted_lower["issue_inventory"]["count"] = 2
        variants.append(("omitted-lower-awaiting-issue", omitted_lower))

        second_pr = copy.deepcopy(baseline)
        duplicate = copy.deepcopy(second_pr["issues"][0]["closing_prs"][0])
        duplicate["number"] = 211
        duplicate["head_ref"] = "feat/second"
        duplicate["head_sha"] = "d" * 40
        duplicate["selected_head_sha"] = "d" * 40
        second_pr["issues"][0]["closing_prs"].append(duplicate)
        second_pr["issues"][0]["closing_pr_inventory"]["records"] = [
            {"repository": "nerdchanii/rpm", "pr": 210},
            {"repository": "nerdchanii/rpm", "pr": 211},
        ]
        second_pr["issues"][0]["closing_pr_inventory"]["count"] = 2
        variants.append(("second-open-closing-pr", second_pr))

        for name, fixture in variants:
            with self.subTest(name=name):
                result, event = self.run_merge(fixture)
                data = self.assert_blocked(result, event)
                if name == "second-open-closing-pr":
                    self.assertEqual(
                        data.get("reason"), "multiple-open-closing-prs", data
                    )
                else:
                    self.assertIn("inventory", str(data.get("reason", "")), data)

    def test_authoritative_merge_fixtures_have_no_pathname_legacy_bypass(self) -> None:
        source = MERGE_CHECK.read_text()
        self.assertNotIn("LEGACY_FIXTURES", source)
        self.assertNotIn("allow_legacy_fixture", source)

        for relative in (
            ".agents/fixtures/backlog/merge-ready.json",
            ".agents/fixtures/backlog/merge-checks-pending.json",
            ".agents/fixtures/backlog/merge-checks-failed.json",
        ):
            with self.subTest(fixture=relative):
                fixture = json.loads((ROOT / relative).read_text())
                self.assertIsInstance(fixture.get("selected_head_sha"), str)
                issue_inventory = fixture.get("issue_inventory")
                self.assertIsInstance(issue_inventory, dict)
                self.assertEqual(
                    issue_inventory.get("source"),
                    "repository-open-issue-merge-inventory-v1",
                )
                self.assertTrue(issue_inventory.get("read_complete"))
                self.assertTrue(issue_inventory.get("pagination_complete"))
                self.assertFalse(issue_inventory.get("has_next_page"))
                self.assertEqual(
                    issue_inventory.get("count"),
                    len(issue_inventory.get("records", [])),
                )
                for issue in fixture.get("issues", []):
                    closing_inventory = issue.get("closing_pr_inventory")
                    self.assertIsInstance(closing_inventory, dict)
                    self.assertEqual(
                        closing_inventory.get("source"),
                        "github-closing-issue-references-v1",
                    )
                    self.assertTrue(closing_inventory.get("read_complete"))
                    self.assertTrue(closing_inventory.get("pagination_complete"))
                    self.assertFalse(closing_inventory.get("has_next_page"))
                    self.assertEqual(
                        closing_inventory.get("count"),
                        len(closing_inventory.get("records", [])),
                    )
                    for pr in issue.get("closing_prs", []):
                        self.assertEqual(
                            pr.get("selected_head_sha"),
                            fixture["selected_head_sha"],
                        )
                        inventory = pr.get("dependent_prs")
                        self.assertIsInstance(inventory, dict)
                        self.assertEqual(
                            inventory.get("source"),
                            "repository-open-pr-base-inventory-v1",
                        )
                        self.assertTrue(inventory.get("read_complete"))
                        self.assertTrue(inventory.get("pagination_complete"))
                        self.assertFalse(inventory.get("has_next_page"))
                        self.assertEqual(
                            inventory.get("count"), len(inventory.get("records", []))
                        )

    def test_adoption_assets_contain_no_direct_review_or_merge_path(self) -> None:
        skill = ROOT / ".agents/skills/adopt-existing-pr/SKILL.md"
        metadata = ROOT / ".agents/skills/adopt-existing-pr/agents/openai.yaml"
        role = ROOT / ".codex/agents/rpm_existing_pr_adopter.toml"
        manager = ROOT / ".codex/agents/rpm_workflow_manager.toml"
        self.assertTrue(skill.is_file(), skill)
        self.assertTrue(metadata.is_file(), metadata)
        self.assertTrue(role.is_file(), role)
        self.assertTrue(manager.is_file(), manager)
        self.assertTrue(ADOPTION_WRITER.is_file(), ADOPTION_WRITER)
        skill_text = skill.read_text()
        manager_text = manager.read_text()
        self.assertIn("rpm_workflow_manager", skill_text)
        self.assertIn("workflow=adopt-existing-pr", skill_text)
        metadata_text = metadata.read_text()
        self.assertIn("$adopt-existing-pr", metadata_text)
        self.assertIn("allow_implicit_invocation: false", metadata_text)
        self.assertIn("rpm_existing_pr_adopter", manager_text)
        self.assertIn("complete current-head evidence", manager_text)
        self.assertIn("after dispatch", manager_text)
        role_text = role.read_text()
        self.assertIn("Required dispatch inputs", role_text)
        self.assertIn("After dispatch, collect", role_text)
        text = "\n".join(
            [
                skill_text,
                role_text,
                MUTATION_HELPER.read_text(),
                ADOPTION_WRITER.read_text(),
            ]
        ).casefold()
        for forbidden in (
            "gh pr merge",
            "@codex review",
            "safe-direct-merge.sh",
            "agent:awaiting-merge\"",
        ):
            self.assertNotIn(forbidden, text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
