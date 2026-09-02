#!/usr/bin/env python3
"""Validate deterministic connector-normalized merge-gate decisions."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


HEAD_SHA_PATTERN = re.compile(r"[0-9a-fA-F]{40}\Z")
TRANSITION_ACTOR_FIELDS = {"awaiting-merge": "awaiting_merge_transition_actor"}


def load_json(path: str) -> dict[str, object]:
    value = json.loads(Path(path).read_text())
    if not isinstance(value, dict):
        raise ValueError("fixture must be a JSON object")
    return value


def load_json_input(path: str | None, inline: str | None) -> dict[str, object]:
    """Load normalized state from a fixture file or one inline Cloud argument."""
    value = load_json(path) if path is not None else json.loads(inline or "")
    if not isinstance(value, dict):
        raise ValueError("fixture must be a JSON object")
    return value


def lifecycle_labels(policy: dict[str, object]) -> dict[str, str]:
    labels = policy.get("labels")
    if not isinstance(labels, dict):
        raise ValueError("policy labels must be an object")
    return {str(state): str(label) for state, label in labels.items()}


def trusted_lifecycle_actors(policy: dict[str, object]) -> dict[str, list[str]]:
    actors = policy.get("trusted_lifecycle_actors")
    if not isinstance(actors, dict):
        raise ValueError("policy trusted_lifecycle_actors must be an object")
    values = actors.get("awaiting-merge")
    if not isinstance(values, list) or not values:
        raise ValueError(
            "policy trusted_lifecycle_actors.awaiting-merge must be non-empty"
        )
    if not all(type(actor) is str and actor.strip() for actor in values):
        raise ValueError(
            "policy trusted_lifecycle_actors.awaiting-merge must contain actor names"
        )
    normalized = [actor.casefold() for actor in values]
    if len(set(normalized)) != len(normalized):
        raise ValueError(
            "policy trusted_lifecycle_actors.awaiting-merge must contain unique actors"
        )
    return {"awaiting-merge": normalized}


def transition_actor_error(
    issue: dict[str, object],
    state: str,
    trusted_actors: dict[str, list[str]],
) -> str | None:
    field = TRANSITION_ACTOR_FIELDS.get(state)
    if field is None:
        return None
    if field not in issue:
        return f"missing-{field.replace('_', '-')}"
    actor = issue.get(field)
    if type(actor) is not str or not actor.strip():
        return f"invalid-{field.replace('_', '-')}"
    if actor.casefold() not in trusted_actors.get(state, []):
        return f"untrusted-{field.replace('_', '-')}"
    return None


def merge_gate(policy: dict[str, object]) -> dict[str, object]:
    gate = policy.get("merge_gate")
    if not isinstance(gate, dict):
        raise ValueError("policy merge_gate must be an object")
    return gate


def issue_labels(issue: dict[str, object]) -> list[str]:
    labels = issue.get("labels", [])
    if not isinstance(labels, list):
        raise ValueError("issue labels must be an array")
    return sorted(str(label) for label in labels)


def issue_state(issue: dict[str, object], lifecycle: dict[str, str]) -> tuple[str, list[str]]:
    labels = issue_labels(issue)
    states = sorted(state for state, label in lifecycle.items() if label in labels)
    if len(states) == 0:
        return "untracked", states
    if len(states) == 1:
        return states[0], states
    return "invalid", states


def is_open(value: dict[str, object]) -> bool:
    return str(value.get("state", "")).casefold() == "open"


def open_closing_prs(issue: dict[str, object]) -> list[dict[str, object]]:
    prs = issue.get("closing_prs", [])
    if not isinstance(prs, list):
        raise ValueError("closing_prs must be an array")
    return [pr for pr in prs if isinstance(pr, dict) and is_open(pr)]


def normalized_issues(fixture: dict[str, object]) -> list[dict[str, object]]:
    issues = fixture.get("issues")
    if not isinstance(issues, list) or not all(isinstance(issue, dict) for issue in issues):
        raise ValueError("fixture issues must be an array of objects")
    return sorted(issues, key=lambda issue: (int(issue.get("number", 0)), str(issue.get("url", ""))))


def canonical_json(value: object) -> str:
    """Compare connector-normalized JSON with JSON type and key-order stability."""
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    )


def normalize_required_status_checks(
    value: object, *, policy: bool
) -> tuple[list[dict[str, object]] | None, str | None]:
    """Normalize and validate required check identities.

    GitHub's branch-protection API exposes both legacy ``contexts`` and the
    richer ``checks`` entries.  A merge gate must retain the check's App
    identity, so a contexts-only or otherwise malformed value is rejected.
    """
    invalid_reason = (
        "server-protection-policy-invalid"
        if policy
        else "server-protection-invalid"
    )
    if not isinstance(value, list) or not value:
        return None, invalid_reason

    normalized: list[dict[str, object]] = []
    contexts: set[str] = set()
    for entry in value:
        if not isinstance(entry, dict):
            return None, invalid_reason
        context = entry.get("context")
        app_id = entry.get("app_id")
        if (
            type(context) is not str
            or not context.strip()
            or context != context.strip()
            or type(app_id) is not int
            or app_id <= 0
        ):
            return None, invalid_reason
        if context in contexts:
            return None, invalid_reason
        contexts.add(context)
        normalized.append({"context": context, "app_id": app_id})

    return sorted(normalized, key=lambda check: str(check["context"])), None


def validate_server_protection(
    gate: dict[str, object], pr: dict[str, object]
) -> str | None:
    """Require the PR evidence to match the policy's live protection snapshot."""
    expected = gate.get("server_protection")
    if (
        not isinstance(expected, dict)
        or type(expected.get("branch")) is not str
        or not expected["branch"].strip()
    ):
        return "server-protection-policy-invalid"
    expected_checks, expected_error = normalize_required_status_checks(
        expected.get("required_status_checks"), policy=True
    )
    if expected_error is not None:
        return expected_error
    if "server_protection" not in pr:
        return "server-protection-missing"
    actual = pr.get("server_protection")
    if not isinstance(actual, dict):
        return "server-protection-invalid"
    actual_checks, actual_error = normalize_required_status_checks(
        actual.get("required_status_checks"), policy=False
    )
    if actual_error is not None:
        return actual_error
    expected_normalized = dict(expected)
    expected_normalized["required_status_checks"] = expected_checks
    actual_normalized = dict(actual)
    actual_normalized["required_status_checks"] = actual_checks
    if canonical_json(actual_normalized) != canonical_json(expected_normalized):
        return "server-protection-mismatch"
    return None


def validate_pr_refs(
    gate: dict[str, object],
    pr: dict[str, object],
    expected_base_sha: str | None = None,
) -> str | None:
    """Require non-empty PR refs and prevent protected-branch head cleanup."""
    base_ref = pr.get("base_ref")
    head_ref = pr.get("head_ref")
    if base_ref is None or head_ref is None:
        return "pr-ref-metadata-missing"
    if type(base_ref) is not str or type(head_ref) is not str:
        return "pr-ref-metadata-invalid"
    if not base_ref.strip() or not head_ref.strip():
        return "pr-ref-metadata-missing"

    if "base_sha" in pr:
        base_sha = pr.get("base_sha")
        if type(base_sha) is not str or HEAD_SHA_PATTERN.fullmatch(base_sha) is None:
            return "base-sha-metadata-invalid"
        if expected_base_sha is not None and base_sha.casefold() != expected_base_sha.casefold():
            return "base-sha-changed"
    elif expected_base_sha is not None:
        return "base-sha-metadata-missing"

    expected = gate.get("server_protection")
    if (
        not isinstance(expected, dict)
        or type(expected.get("branch")) is not str
        or not expected["branch"].strip()
    ):
        return "server-protection-policy-invalid"
    protected_branch = expected["branch"]
    if base_ref != protected_branch:
        return "unexpected-base-branch"
    if head_ref in {protected_branch, f"refs/heads/{protected_branch}"}:
        return "protected-head-branch"
    return None


def evaluate_gate(
    gate: dict[str, object],
    issue: dict[str, object],
    pr: dict[str, object],
    expected_head_sha: str | None = None,
    expected_base_sha: str | None = None,
) -> dict[str, object]:
    issue_number = int(issue.get("number", 0))
    pr_number = int(pr.get("number", 0))
    if "state" in pr and not is_open(pr):
        return {
            "status": "blocked",
            "reason": "pr-not-open",
            "issue": issue_number,
            "pr": pr_number,
        }
    if "is_draft" in pr and pr.get("is_draft") is not False:
        return {
            "status": "blocked",
            "reason": "pr-is-draft",
            "issue": issue_number,
            "pr": pr_number,
        }
    if "auto_merge_enabled" in pr and pr.get("auto_merge_enabled") is not False:
        return {
            "status": "blocked",
            "reason": "auto-merge-enabled",
            "issue": issue_number,
            "pr": pr_number,
        }
    if "merge_state" in pr:
        merge_state = pr.get("merge_state")
        if type(merge_state) is not str or not merge_state.strip():
            return {
                "status": "blocked",
                "reason": "merge-state-metadata-invalid",
                "issue": issue_number,
                "pr": pr_number,
            }
        merge_state = merge_state.casefold()
        if merge_state != "clean":
            status = "no-work" if merge_state in {"unknown", "blocked", "draft"} else "blocked"
            return {
                "status": status,
                "reason": "merge-state-not-clean",
                "issue": issue_number,
                "pr": pr_number,
                "expected_head_sha": pr.get("head_sha"),
            }
    head_sha = pr.get("head_sha")
    if head_sha is None:
        return {
            "status": "blocked",
            "reason": "head-sha-metadata-missing",
            "issue": issue_number,
            "pr": pr_number,
        }
    if type(head_sha) is not str or HEAD_SHA_PATTERN.fullmatch(head_sha) is None:
        return {
            "status": "blocked",
            "reason": "head-sha-metadata-invalid",
            "issue": issue_number,
            "pr": pr_number,
        }
    head_sha = head_sha.casefold()
    if expected_head_sha is not None and head_sha.casefold() != expected_head_sha.casefold():
        return {
            "status": "blocked",
            "reason": "head-sha-changed",
            "issue": issue_number,
            "pr": pr_number,
            "expected_head_sha": expected_head_sha,
            "actual_head_sha": head_sha,
        }
    server_protection_error = validate_server_protection(gate, pr)
    if server_protection_error is not None:
        return {
            "status": "blocked",
            "reason": server_protection_error,
            "issue": issue_number,
            "pr": pr_number,
            "expected_head_sha": head_sha,
        }
    pr_refs_error = validate_pr_refs(gate, pr, expected_base_sha)
    if pr_refs_error is not None:
        return {
            "status": "blocked",
            "reason": pr_refs_error,
            "issue": issue_number,
            "pr": pr_number,
            "expected_head_sha": head_sha,
        }
    checks = pr.get("checks", {})
    if not isinstance(checks, dict):
        raise ValueError("pr checks must be an object")
    conclusions = {str(name): str(conclusion).casefold() for name, conclusion in checks.items()}
    required = [str(name) for name in list(gate.get("required_checks", []))]
    failed = sorted(
        name
        for name in required
        if conclusions.get(name) in {"failure", "cancelled", "timed_out", "action_required"}
    )
    if failed:
        return {
            "status": "blocked",
            "reason": "checks-failed",
            "issue": issue_number,
            "pr": pr_number,
            "checks": failed,
            "expected_head_sha": head_sha,
        }
    pending = sorted(name for name in required if conclusions.get(name) != "success")
    if pending:
        return {
            "status": "no-work",
            "reason": "checks-pending",
            "issue": issue_number,
            "pr": pr_number,
            "checks": pending,
            "expected_head_sha": head_sha,
        }
    if gate.get("required_mergeable") is True and pr.get("mergeable") is not True:
        reason = "not-mergeable" if pr.get("mergeable") is False else "mergeability-unknown"
        status = "blocked" if pr.get("mergeable") is False else "no-work"
        return {
            "status": status,
            "reason": reason,
            "issue": issue_number,
            "pr": pr_number,
            "expected_head_sha": head_sha,
        }
    if gate.get("forbid_unresolved_p0_p1") is True and pr.get("unresolved_p0_p1") is not False:
        return {
            "status": "blocked",
            "reason": "review-findings-remain",
            "issue": issue_number,
            "pr": pr_number,
            "expected_head_sha": head_sha,
        }
    if "unresolved_review_threads" in pr:
        unresolved_threads = pr.get("unresolved_review_threads")
        if type(unresolved_threads) is not int or unresolved_threads < 0:
            return {
                "status": "blocked",
                "reason": "review-thread-metadata-invalid",
                "issue": issue_number,
                "pr": pr_number,
                "expected_head_sha": head_sha,
            }
        if unresolved_threads > 0:
            return {
                "status": "blocked",
                "reason": "unresolved-review-conversations",
                "issue": issue_number,
                "pr": pr_number,
                "expected_head_sha": head_sha,
            }
    if "merge_queue" in pr:
        queue = pr.get("merge_queue")
        if not isinstance(queue, dict):
            return {
                "status": "blocked",
                "reason": "merge-queue-metadata-invalid",
                "issue": issue_number,
                "pr": pr_number,
                "expected_head_sha": head_sha,
            }
        present = queue.get("present")
        if type(present) is not bool:
            return {
                "status": "blocked",
                "reason": "merge-queue-metadata-invalid",
                "issue": issue_number,
                "pr": pr_number,
                "expected_head_sha": head_sha,
            }
        position = queue.get("position")
        state = queue.get("state")
        if present:
            if (position is not None and (type(position) is not int or position < 1)) or (
                state is not None and (type(state) is not str or not state)
            ):
                return {
                    "status": "blocked",
                    "reason": "merge-queue-metadata-invalid",
                    "issue": issue_number,
                    "pr": pr_number,
                    "expected_head_sha": head_sha,
                }
        elif position is not None or state is not None:
            return {
                "status": "blocked",
                "reason": "merge-queue-metadata-invalid",
                "issue": issue_number,
                "pr": pr_number,
                "expected_head_sha": head_sha,
            }
        if present:
            return {
                "status": "blocked",
                "reason": "merge-queue-active",
                "issue": issue_number,
                "pr": pr_number,
                "expected_head_sha": head_sha,
            }
    return {
        "status": "merge",
        "reason": "gate-passed",
        "issue": issue_number,
        "pr": pr_number,
        "method": str(gate.get("method", "")),
        "delete_branch": gate.get("delete_branch") is True,
        "expected_head_sha": head_sha,
    }


def select_merge(
    fixture: dict[str, object],
    lifecycle: dict[str, str],
    gate: dict[str, object],
    trusted_actors: dict[str, list[str]],
    expected_head_sha: str | None = None,
    expected_base_sha: str | None = None,
) -> dict[str, object]:
    if gate.get("enabled") is not True:
        return {"status": "no-work", "reason": "merge-gate-disabled"}
    source_state = str(gate.get("source_state", "awaiting-merge"))
    candidates = []
    for issue in normalized_issues(fixture):
        state, matched = issue_state(issue, lifecycle)
        if len(matched) > 1:
            return {
                "status": "blocked",
                "reason": "multiple-lifecycle-labels",
                "invalid": [{"number": issue.get("number"), "states": matched}],
            }
        if is_open(issue) and state == source_state:
            candidates.append(issue)
    if not candidates:
        return {"status": "no-work", "reason": "no-awaiting-merge-candidate"}
    selected = candidates[0]
    actor_error = transition_actor_error(selected, "awaiting-merge", trusted_actors)
    if actor_error is not None:
        return {
            "status": "blocked",
            "reason": actor_error,
            "issue": int(selected.get("number", 0)),
        }
    prs = open_closing_prs(selected)
    if len(prs) == 0:
        return {
            "status": "blocked",
            "reason": "no-open-closing-pr",
            "issue": int(selected.get("number", 0)),
        }
    if len(prs) > 1:
        return {
            "status": "blocked",
            "reason": "multiple-open-closing-prs",
            "issue": int(selected.get("number", 0)),
        }
    if "same_repository" in prs[0] and prs[0].get("same_repository") is not True:
        return {
            "status": "blocked",
            "reason": "cross-repository-closing-pr",
            "issue": int(selected.get("number", 0)),
            "pr": int(prs[0].get("number", 0)),
        }
    return evaluate_gate(gate, selected, prs[0], expected_head_sha, expected_base_sha)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", default=".agents/workflows/backlog-policy.json")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--issues-file")
    source.add_argument("--issues-json")
    parser.add_argument("--operation", required=True, choices=("select-merge",))
    parser.add_argument("--expected-head-sha")
    parser.add_argument("--expected-base-sha")
    args = parser.parse_args()

    policy = load_json(args.policy)
    fixture = load_json_input(args.issues_file, args.issues_json)
    expected_head_sha = args.expected_head_sha.casefold() if args.expected_head_sha else None
    expected_base_sha = args.expected_base_sha.casefold() if args.expected_base_sha else None
    result = select_merge(
        fixture,
        lifecycle_labels(policy),
        merge_gate(policy),
        trusted_lifecycle_actors(policy),
        expected_head_sha,
        expected_base_sha,
    )
    print(json.dumps({"type": "merge_gate_contract", "data": result}, sort_keys=True))
    return 1 if result.get("status") == "blocked" else 0


if __name__ == "__main__":
    raise SystemExit(main())
