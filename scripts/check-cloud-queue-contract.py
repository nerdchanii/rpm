#!/usr/bin/env python3
"""Validate deterministic connector-normalized Cloud queue decisions."""

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


def is_open(issue: dict[str, object]) -> bool:
    return str(issue.get("state", "")).casefold() == "open"


def has_open_closing_pr(issue: dict[str, object]) -> bool:
    prs = issue.get("closing_prs", [])
    if not isinstance(prs, list):
        raise ValueError("closing_prs must be an array")
    return any(
        isinstance(pr, dict) and str(pr.get("state", "")).casefold() == "open"
        for pr in prs
    )


def normalized_issues(fixture: dict[str, object]) -> list[dict[str, object]]:
    issues = fixture.get("issues")
    if not isinstance(issues, list) or not all(isinstance(issue, dict) for issue in issues):
        raise ValueError("fixture issues must be an array of objects")
    return sorted(issues, key=lambda issue: (int(issue.get("number", 0)), str(issue.get("url", ""))))


def select_execution(
    fixture: dict[str, object], lifecycle: dict[str, str], batch_limit: int
) -> dict[str, object]:
    open_issues = [issue for issue in normalized_issues(fixture) if is_open(issue)]
    invalid = []
    states: list[tuple[dict[str, object], str]] = []
    for issue in open_issues:
        state, matched = issue_state(issue, lifecycle)
        if state == "invalid":
            invalid.append({"number": issue.get("number"), "states": matched})
        states.append((issue, state))
    if invalid:
        return {"status": "blocked", "reason": "multiple-lifecycle-labels", "invalid": invalid, "issues": []}
    active = [
        int(issue.get("number", 0))
        for issue, state in states
        if state in {"claimed", "review-pending"}
    ]
    if active:
        return {"status": "no-work", "reason": "active-work", "active": active, "issues": []}
    selected = [
        issue
        for issue, state in states
        if state == "ready" and not has_open_closing_pr(issue)
    ][:batch_limit]
    return {
        "status": "selected" if selected else "no-work",
        "reason": "ready" if selected else "no-ready-issue",
        "issues": [int(issue.get("number", 0)) for issue in selected],
    }


def select_review(fixture: dict[str, object], lifecycle: dict[str, str]) -> dict[str, object]:
    candidates = []
    for issue in normalized_issues(fixture):
        state, matched = issue_state(issue, lifecycle)
        if len(matched) > 1:
            return {
                "status": "blocked",
                "reason": "multiple-lifecycle-labels",
                "invalid": [{"number": issue.get("number"), "states": matched}],
                "issues": [],
            }
        if is_open(issue) and state == "review-pending" and has_open_closing_pr(issue):
            candidates.append(issue)
    if not candidates:
        return {"status": "no-work", "reason": "no-review-pending-pr", "issues": []}
    selected = candidates[0]
    if selected.get("codex_review_present") is not True:
        return {
            "status": "no-work",
            "reason": "review-not-arrived",
            "issues": [int(selected.get("number", 0))],
        }
    return {
        "status": "selected",
        "reason": "review-present",
        "issues": [int(selected.get("number", 0))],
    }


def transition(
    fixture: dict[str, object],
    lifecycle: dict[str, str],
    issue_number: int,
    before: str,
    after: str,
) -> dict[str, object]:
    issue = next(
        (item for item in normalized_issues(fixture) if int(item.get("number", 0)) == issue_number),
        None,
    )
    if issue is None:
        return {"status": "blocked", "reason": "issue-not-found"}
    current, matched = issue_state(issue, lifecycle)
    if not is_open(issue) or current != before or len(matched) != 1:
        return {"status": "no-work", "reason": "compare-and-set-mismatch", "current": current}
    labels = issue_labels(issue)
    ordinary = sorted(label for label in labels if label not in lifecycle.values())
    result_labels = sorted([*ordinary, lifecycle[after]])
    return {
        "status": "transition",
        "issue": issue_number,
        "before": before,
        "after": after,
        "preserved_labels": ordinary,
        "labels": result_labels,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", default=".agents/workflows/backlog-policy.json")
    parser.add_argument("--issues-file", required=True)
    parser.add_argument(
        "--operation",
        required=True,
        choices=("select-execution", "select-review", "transition"),
    )
    parser.add_argument("--issue", type=int)
    parser.add_argument("--from-state")
    parser.add_argument("--to-state")
    args = parser.parse_args()

    policy = load_json(args.policy)
    fixture = load_json(args.issues_file)
    lifecycle = lifecycle_labels(policy)
    if args.operation == "select-execution":
        limit = int(dict(policy["batch_limits"])["execution"])
        result = select_execution(fixture, lifecycle, limit)
    elif args.operation == "select-review":
        result = select_review(fixture, lifecycle)
    else:
        if args.issue is None or args.from_state is None or args.to_state is None:
            parser.error("transition requires --issue, --from-state, and --to-state")
        result = transition(
            fixture,
            lifecycle,
            args.issue,
            args.from_state,
            args.to_state,
        )
    print(json.dumps({"type": "cloud_queue_contract", "data": result}, sort_keys=True))
    return 1 if result.get("status") == "blocked" else 0


if __name__ == "__main__":
    raise SystemExit(main())
