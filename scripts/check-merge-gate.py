#!/usr/bin/env python3
"""Validate deterministic connector-normalized merge-gate decisions."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def load_json(path: str) -> dict[str, object]:
    value = json.loads(Path(path).read_text())
    if not isinstance(value, dict):
        raise ValueError("fixture must be a JSON object")
    return value


def lifecycle_labels(policy: dict[str, object]) -> dict[str, str]:
    labels = policy.get("labels")
    if not isinstance(labels, dict):
        raise ValueError("policy labels must be an object")
    return {str(state): str(label) for state, label in labels.items()}


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


def evaluate_gate(
    gate: dict[str, object], issue: dict[str, object], pr: dict[str, object]
) -> dict[str, object]:
    issue_number = int(issue.get("number", 0))
    pr_number = int(pr.get("number", 0))
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
        }
    pending = sorted(name for name in required if conclusions.get(name) != "success")
    if pending:
        return {
            "status": "no-work",
            "reason": "checks-pending",
            "issue": issue_number,
            "pr": pr_number,
            "checks": pending,
        }
    if gate.get("required_mergeable") is True and pr.get("mergeable") is not True:
        reason = "not-mergeable" if pr.get("mergeable") is False else "mergeability-unknown"
        status = "blocked" if pr.get("mergeable") is False else "no-work"
        return {"status": status, "reason": reason, "issue": issue_number, "pr": pr_number}
    if gate.get("forbid_unresolved_p0_p1") is True and pr.get("unresolved_p0_p1") is not False:
        return {
            "status": "blocked",
            "reason": "review-findings-remain",
            "issue": issue_number,
            "pr": pr_number,
        }
    return {
        "status": "merge",
        "reason": "gate-passed",
        "issue": issue_number,
        "pr": pr_number,
        "method": str(gate.get("method", "")),
        "delete_branch": gate.get("delete_branch") is True,
    }


def select_merge(
    fixture: dict[str, object], lifecycle: dict[str, str], gate: dict[str, object]
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
    return evaluate_gate(gate, selected, prs[0])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", default=".agents/workflows/backlog-policy.json")
    parser.add_argument("--issues-file", required=True)
    parser.add_argument("--operation", required=True, choices=("select-merge",))
    args = parser.parse_args()

    policy = load_json(args.policy)
    fixture = load_json(args.issues_file)
    result = select_merge(fixture, lifecycle_labels(policy), merge_gate(policy))
    print(json.dumps({"type": "merge_gate_contract", "data": result}, sort_keys=True))
    return 1 if result.get("status") == "blocked" else 0


if __name__ == "__main__":
    raise SystemExit(main())
