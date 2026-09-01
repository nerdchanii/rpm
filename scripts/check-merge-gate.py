#!/usr/bin/env python3
"""Validate deterministic connector-normalized merge-gate decisions."""

from __future__ import annotations

import argparse
import json
import re
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


P2_TERMINAL_DISPOSITIONS = {
    "already-addressed",
    "defer-follow-up",
    "residual-risk",
    "reject-out-of-scope",
}


def validate_findings_collection(
    pr: dict[str, object], selected_head_sha: str
) -> str | None:
    """Validate the complete current-head findings inventory for merge."""
    if "unresolved_p0_p1" in pr:
        return "legacy-findings-boolean"
    findings = pr.get("findings")
    if not isinstance(findings, dict):
        return "findings-inventory-missing"
    if (
        findings.get("repository") != pr.get("repository")
        or findings.get("pr") != pr.get("number")
    ):
        return "findings-identity-mismatch"
    if findings.get("source") != "current-head-review-findings-v1":
        return "findings-source-mismatch"
    if findings.get("read_complete") is not True:
        return "findings-read-incomplete"
    if findings.get("pagination_complete") is not True:
        return "findings-pagination-incomplete"
    if findings.get("has_next_page") is not False:
        return "findings-pagination-open"
    if findings.get("head_sha") != selected_head_sha:
        return "findings-head-mismatch"
    items = findings.get("items")
    if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
        return "findings-invalid"
    if findings.get("count") != len(items):
        return "findings-count-mismatch"
    identities: set[tuple[str, str, str]] = set()
    for item in items:
        if any(
            not isinstance(item.get(field), str) or not str(item[field]).strip()
            for field in ("id", "source_id", "head_sha")
        ):
            return "finding-identity-incomplete"
        if item.get("head_sha") != selected_head_sha:
            return "finding-head-mismatch"
        identity = (
            str(item["id"]),
            str(item["source_id"]),
            str(item["head_sha"]),
        )
        if identity in identities:
            return "finding-identity-duplicate"
        identities.add(identity)
        severity = str(item.get("severity", "")).upper()
        if severity in {"P0", "P1"}:
            return "review-findings-remain"
        if severity == "P3":
            continue
        if severity != "P2":
            return "finding-severity-invalid"
        disposition = item.get("disposition")
        if disposition not in P2_TERMINAL_DISPOSITIONS:
            return "finding-disposition-incomplete"
        owner = item.get("owner")
        if not isinstance(owner, str) or not owner.strip():
            return "finding-owner-missing"
        if disposition == "defer-follow-up":
            follow_up_issue = item.get("follow_up_issue")
            if not (type(follow_up_issue) is int and follow_up_issue > 0) and not (
                isinstance(item.get("follow_up_creation_authority"), str)
                and str(item["follow_up_creation_authority"]).strip()
            ):
                return "follow-up-owner-incomplete"
        elif not isinstance(item.get("rationale"), str) or not str(
            item["rationale"]
        ).strip():
            return "finding-rationale-missing"
    return None


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


def validate_pr_ready_state(pr: dict[str, object]) -> str | None:
    """Require the normalized PR evidence to identify a ready-for-review PR."""
    is_draft = pr.get("is_draft")
    raw_draft = pr.get("draft")
    if raw_draft is not None and type(raw_draft) is not bool:
        return "selected-pr-ready-state-invalid"
    if raw_draft is True or is_draft is True:
        return "pr-is-draft"
    if type(is_draft) is not bool or is_draft is not False:
        return "selected-pr-ready-state-invalid"
    return None


def selected_pr_evidence(
    fixture: dict[str, object],
    issue: dict[str, object],
    pr: dict[str, object],
    selected_head_sha: object,
) -> str | None:
    """Bind the selected PR refs to the independent selection snapshot.

    Dependent-PR comparison uses the selected PR head repository and ref.  A
    mutable PR object must therefore be checked against the closing-PR
    inventory before that comparison; otherwise a forged head identity or
    ready-state value can make a real dependent PR or a draft PR disappear
    from the gate.
    """
    repository = fixture.get("repository")
    number = pr.get("number")
    ready_state_error = validate_pr_ready_state(pr)
    if (
        not isinstance(repository, str)
        or not isinstance(number, int)
        or pr.get("repository") != repository
        or pr.get("base_ref") is None
        or pr.get("head_ref") is None
        or not isinstance(pr.get("base_ref"), str)
        or not isinstance(pr.get("head_ref"), str)
        or not isinstance(pr.get("base_sha"), str)
        or not isinstance(pr.get("head_repository"), str)
        or not pr.get("head_repository", "").strip()
        or not isinstance(pr.get("head_sha"), str)
        or not re.fullmatch(r"[0-9a-f]{40}", str(pr.get("base_sha")))
        or not re.fullmatch(r"[0-9a-f]{40}", str(pr.get("head_sha")))
        or pr.get("head_sha") != selected_head_sha
        or ready_state_error is not None
    ):
        return ready_state_error or "selected-pr-identity-invalid"

    evidence: object = fixture.get("selected_pr_evidence")
    if evidence is None:
        inventory = issue.get("closing_pr_inventory")
        records = inventory.get("records") if isinstance(inventory, dict) else None
        if isinstance(records, list):
            candidates = [
                item
                for item in records
                if isinstance(item, dict)
                and item.get("pr", item.get("number")) == number
            ]
            if len(candidates) == 1:
                evidence = candidates[0]
    if isinstance(evidence, dict) and isinstance(evidence.get("pr"), dict):
        evidence = evidence["pr"]
    if not isinstance(evidence, dict):
        return "selected-pr-evidence-missing"
    for field in (
        "repository",
        "base_ref",
        "base_sha",
        "head_repository",
        "head_ref",
        "head_sha",
        "is_draft",
    ):
        if evidence.get(field) != pr.get(field):
            return "selected-pr-evidence-mismatch"
    if evidence.get("number") != number:
        return "selected-pr-evidence-mismatch"
    return None


def validate_merge_inventories(
    fixture: dict[str, object], lifecycle: dict[str, str]
) -> dict[str, object] | None:
    inventory = fixture.get("issue_inventory")
    if not isinstance(inventory, dict):
        return {"status": "blocked", "reason": "issue-inventory-missing"}
    if (
        inventory.get("repository") != fixture.get("repository")
        or inventory.get("source") != "repository-open-issue-merge-inventory-v1"
        or inventory.get("read_complete") is not True
        or inventory.get("pagination_complete") is not True
        or inventory.get("has_next_page") is not False
    ):
        return {"status": "blocked", "reason": "issue-inventory-incomplete"}
    records = inventory.get("records")
    if not isinstance(records, list) or not all(isinstance(item, dict) for item in records):
        return {"status": "blocked", "reason": "issue-inventory-records-invalid"}
    if inventory.get("count") != len(records):
        return {"status": "blocked", "reason": "issue-inventory-count-mismatch"}
    issues = normalized_issues(fixture)
    open_issues = [issue for issue in issues if is_open(issue)]
    expected: list[tuple[int, str, str]] = []
    for issue in open_issues:
        state, matched = issue_state(issue, lifecycle)
        if len(matched) > 1:
            return {"status": "blocked", "reason": "multiple-lifecycle-labels"}
        expected.append((int(issue.get("number", 0)), "OPEN", state))
        closing_inventory = issue.get("closing_pr_inventory")
        if not isinstance(closing_inventory, dict) or (
            closing_inventory.get("repository") != fixture.get("repository")
            or
            closing_inventory.get("source") != "github-closing-issue-references-v1"
            or closing_inventory.get("read_complete") is not True
            or closing_inventory.get("pagination_complete") is not True
            or closing_inventory.get("has_next_page") is not False
        ):
            return {"status": "blocked", "reason": "closing-pr-inventory-incomplete"}
        closing_records = closing_inventory.get("records")
        if not isinstance(closing_records, list) or not all(
            isinstance(record, dict) for record in closing_records
        ):
            return {"status": "blocked", "reason": "closing-pr-inventory-records-invalid"}
        if closing_inventory.get("count") != len(closing_records):
            return {"status": "blocked", "reason": "closing-pr-inventory-count-mismatch"}
        expected_closing: dict[int, str] = {}
        closing_views = issue.get("closing_prs")
        if not isinstance(closing_views, list):
            return {
                "status": "blocked",
                "reason": "closing-pr-inventory-records-invalid",
            }
        for closing_pr in closing_views:
            if not isinstance(closing_pr, dict):
                return {
                    "status": "blocked",
                    "reason": "closing-pr-inventory-records-invalid",
                }
            closing_number = closing_pr.get("number")
            closing_state = closing_pr.get("state")
            if (
                not isinstance(closing_number, int)
                or closing_number <= 0
                or closing_pr.get("repository") != fixture.get("repository")
                or not isinstance(closing_state, str)
                or not closing_state.strip()
                or closing_state.upper() not in {"OPEN", "CLOSED"}
                or closing_number in expected_closing
            ):
                return {
                    "status": "blocked",
                    "reason": "closing-pr-inventory-identity-mismatch",
                }
            expected_closing[closing_number] = closing_state.upper()

        observed_closing: dict[int, str] = {}
        for record in closing_records:
            if (
                "pr" in record
                and "number" in record
                and record.get("pr") != record.get("number")
            ):
                return {
                    "status": "blocked",
                    "reason": "closing-pr-inventory-identity-mismatch",
                }
            record_number = record.get("pr") if "pr" in record else record.get("number")
            record_issue = record.get("issue")
            record_state = record.get("state")
            if (
                not isinstance(record_number, int)
                or record_number <= 0
                or record.get("repository") != fixture.get("repository")
                or (record_issue is not None and record_issue != issue.get("number"))
                or record_number in observed_closing
                or record_number not in expected_closing
            ):
                return {
                    "status": "blocked",
                    "reason": "closing-pr-inventory-identity-mismatch",
                }
            if record_state is not None and (
                not isinstance(record_state, str)
                or record_state.upper() != expected_closing[record_number]
            ):
                return {
                    "status": "blocked",
                    "reason": "closing-pr-inventory-identity-mismatch",
                }
            observed_closing[record_number] = expected_closing[record_number]
        if set(observed_closing) != set(expected_closing):
            return {
                "status": "blocked",
                "reason": "closing-pr-inventory-identity-mismatch",
            }
    observed: list[tuple[int, str, str]] = []
    for record in records:
        if not isinstance(record.get("number"), int):
            return {"status": "blocked", "reason": "issue-inventory-record-invalid"}
        observed.append(
            (
                int(record["number"]),
                str(record.get("state", "")).upper(),
                str(record.get("lifecycle_state", "")),
            )
        )
    if sorted(observed) != sorted(expected) or len(observed) != len(set(observed)):
        return {"status": "blocked", "reason": "issue-inventory-identity-mismatch"}
    return None


def evaluate_gate(
    gate: dict[str, object],
    issue: dict[str, object],
    pr: dict[str, object],
    selected_head_sha: str | None = None,
) -> dict[str, object]:
    pending_conclusions = {
        "queued",
        "in_progress",
        "pending",
        "requested",
        "waiting",
    }
    issue_number = int(issue.get("number", 0))
    pr_number = int(pr.get("number", 0))
    ready_state_error = validate_pr_ready_state(pr)
    if ready_state_error:
        return {
            "status": "blocked",
            "reason": ready_state_error,
            "issue": issue_number,
            "pr": pr_number,
        }
    if (
        issue_number <= 0
        or pr_number <= 0
        or not isinstance(pr.get("repository"), str)
        or not pr.get("repository")
    ):
        return {
            "status": "blocked",
            "reason": "selected-pr-identity-invalid",
            "issue": issue_number,
            "pr": pr_number,
        }
    raw_checks = pr.get("checks")
    if not isinstance(raw_checks, dict):
        return {
            "status": "blocked",
            "reason": "checks-dictionary-required",
            "issue": issue_number,
            "pr": pr_number,
        }
    if (
        raw_checks.get("source") != "github-check-runs-v1"
        or raw_checks.get("repository") != pr.get("repository")
        or raw_checks.get("pr") != pr_number
        or raw_checks.get("read_complete") is not True
        or raw_checks.get("pagination_complete") is not True
        or raw_checks.get("has_next_page") is not False
        or raw_checks.get("head_sha") != selected_head_sha
        or not isinstance(raw_checks.get("records"), list)
        or raw_checks.get("count") != len(raw_checks.get("records", []))
    ):
        return {
            "status": "blocked",
            "reason": "checks-dictionary-or-invalid",
            "issue": issue_number,
            "pr": pr_number,
        }
    checks = raw_checks["records"]
    if not all(isinstance(item, dict) for item in checks):
        return {
            "status": "blocked",
            "reason": "checks-records-invalid",
            "issue": issue_number,
            "pr": pr_number,
        }
    if selected_head_sha is None or not re.fullmatch(r"[0-9a-f]{40}", selected_head_sha):
        return {
            "status": "blocked",
            "reason": "selected-head-invalid",
            "issue": issue_number,
            "pr": pr_number,
        }
    required = [str(name) for name in list(gate.get("required_checks", []))]
    required_names = set(required)
    names: list[str] = []
    workflow_ids: list[int] = []
    conclusions: dict[str, str] = {}
    for item in checks:
        name = item.get("name")
        if not isinstance(name, str) or not name.strip():
            return {
                "status": "blocked",
                "reason": "checks-ambiguous",
                "issue": issue_number,
                "pr": pr_number,
            }
        if name not in required_names:
            continue
        if (
            item.get("head_sha") != selected_head_sha
            or item.get("source") != "github-actions"
            or not isinstance(item.get("workflow_run_id"), int)
        ):
            return {
                "status": "blocked",
                "reason": "checks-head-or-source-mismatch",
                "issue": issue_number,
                "pr": pr_number,
            }
        conclusion = item.get("conclusion")
        status = item.get("status")
        if (
            conclusion is None
            and isinstance(status, str)
            and status.casefold() in pending_conclusions
        ):
            conclusion = status
        elif not isinstance(conclusion, str):
            return {
                "status": "blocked",
                "reason": "check-conclusion-invalid",
                "issue": issue_number,
                "pr": pr_number,
            }
        names.append(name)
        workflow_ids.append(int(item["workflow_run_id"]))
        conclusions[name] = conclusion.casefold()
    if len(names) != len(set(names)) or len(workflow_ids) != len(set(workflow_ids)):
        return {
            "status": "blocked",
            "reason": "checks-ambiguous",
            "issue": issue_number,
            "pr": pr_number,
        }
    terminal_non_success = sorted(
        name
        for name in required
        if name in conclusions
        and conclusions[name] not in {"success", *pending_conclusions}
    )
    if terminal_non_success:
        return {
            "status": "blocked",
            "reason": "checks-failed",
            "issue": issue_number,
            "pr": pr_number,
            "checks": terminal_non_success,
        }
    pending = sorted(
        name
        for name in required
        if name not in conclusions or conclusions[name] in pending_conclusions
    )
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
    if gate.get("forbid_unresolved_p0_p1") is True:
        findings_error = validate_findings_collection(pr, selected_head_sha or "")
        if findings_error:
            return {
                "status": "blocked",
                "reason": findings_error,
                "issue": issue_number,
                "pr": pr_number,
            }
    result = {
        "status": "merge",
        "reason": "gate-passed",
        "issue": issue_number,
        "pr": pr_number,
        "method": str(gate.get("method", "")),
        "delete_branch": gate.get("delete_branch") is True,
    }
    if selected_head_sha is not None:
        result["head_sha"] = selected_head_sha
        result["batch_limit"] = int(gate.get("batch_limit", 0))
    return result


def validate_dependent_prs(
    fixture: dict[str, object], pr: dict[str, object]
) -> dict[str, object] | None:
    inventory = pr.get("dependent_prs")
    if not isinstance(inventory, dict):
        return {"status": "blocked", "reason": "dependent-pr-inventory-missing"}
    if inventory.get("source") != "repository-open-pr-base-inventory-v1":
        return {"status": "blocked", "reason": "dependent-pr-inventory-source"}
    if (
        inventory.get("repository") != fixture.get("repository")
        or inventory.get("pr") != pr.get("number")
        or inventory.get("head_sha") != pr.get("head_sha")
    ):
        return {"status": "blocked", "reason": "dependent-pr-target-mismatch"}
    if inventory.get("read_complete") is not True:
        return {"status": "blocked", "reason": "dependent-pr-inventory-incomplete"}
    if inventory.get("pagination_complete") is not True:
        return {"status": "blocked", "reason": "dependent-pr-pagination-incomplete"}
    if inventory.get("has_next_page") is not False:
        return {"status": "blocked", "reason": "dependent-pr-pagination-open"}
    records = inventory.get("records")
    if not isinstance(records, list) or not all(isinstance(item, dict) for item in records):
        return {"status": "blocked", "reason": "dependent-pr-records-invalid"}
    if inventory.get("count") != len(records):
        return {"status": "blocked", "reason": "dependent-pr-count-mismatch"}
    repository = fixture.get("repository")
    head_repository = pr.get("head_repository")
    head_ref = pr.get("head_ref")
    dependents = []
    seen_numbers: set[int] = set()
    for record in records:
        required = (
            "number",
            "state",
            "repository",
            "base_ref",
            "base_sha",
            "head_ref",
            "head_sha",
        )
        if any(field not in record for field in required):
            return {"status": "blocked", "reason": "dependent-pr-record-incomplete"}
        number = record.get("number")
        if (
            not isinstance(number, int)
            or number <= 0
            or number in seen_numbers
            or record.get("repository") != repository
            or not isinstance(head_repository, str)
            or not head_repository.strip()
            or not isinstance(record.get("state"), str)
            or not record.get("state", "").strip()
            or str(record.get("state", "")).casefold() != "open"
            or not isinstance(record.get("base_ref"), str)
            or not record.get("base_ref", "").strip()
            or not isinstance(record.get("head_ref"), str)
            or not record.get("head_ref", "").strip()
            or not isinstance(record.get("base_sha"), str)
            or not re.fullmatch(r"[0-9a-f]{40}", record["base_sha"])
            or not isinstance(record.get("head_sha"), str)
            or not re.fullmatch(r"[0-9a-f]{40}", record["head_sha"])
        ):
            return {"status": "blocked", "reason": "dependent-pr-record-identity"}
        seen_numbers.add(number)
        if (
            str(record.get("state", "")).casefold() == "open"
            and record.get("repository") == head_repository
            and record.get("base_ref") == head_ref
        ):
            dependents.append(int(record.get("number", 0)))
    if dependents:
        return {
            "status": "blocked",
            "reason": "retarget-required",
            "dependent_prs": sorted(dependents),
        }
    return None


def select_merge(
    fixture: dict[str, object],
    lifecycle: dict[str, str],
    gate: dict[str, object],
) -> dict[str, object]:
    if gate.get("enabled") is not True:
        return {"status": "no-work", "reason": "merge-gate-disabled"}
    inventory_error = validate_merge_inventories(fixture, lifecycle)
    if inventory_error is not None:
        return inventory_error
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
    pr = prs[0]
    selected_head_sha = fixture.get("selected_head_sha")
    if selected_head_sha is None:
        return {
            "status": "blocked",
            "reason": "selected-head-missing",
            "issue": int(selected.get("number", 0)),
            "pr": int(pr.get("number", 0)),
        }
    if not isinstance(selected_head_sha, str) or pr.get("selected_head_sha") != selected_head_sha:
        return {
            "status": "blocked",
            "reason": "selected-head-mismatch",
            "issue": int(selected.get("number", 0)),
            "pr": int(pr.get("number", 0)),
        }
    selected_identity_error = selected_pr_evidence(
        fixture, selected, pr, selected_head_sha
    )
    if selected_identity_error is not None:
        return {
            "status": "blocked",
            "reason": selected_identity_error,
            "issue": int(selected.get("number", 0)),
            "pr": int(pr.get("number", 0)),
        }
    dependent_error = validate_dependent_prs(fixture, pr)
    if dependent_error is not None:
        dependent_error.update(
            {
                "issue": int(selected.get("number", 0)),
                "pr": int(pr.get("number", 0)),
            }
        )
        return dependent_error
    return evaluate_gate(gate, selected, pr, selected_head_sha)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", default=".agents/workflows/backlog-policy.json")
    parser.add_argument("--issues-file", required=True)
    parser.add_argument("--operation", required=True, choices=("select-merge",))
    args = parser.parse_args()

    policy = load_json(args.policy)
    fixture = load_json(args.issues_file)
    result = select_merge(
        fixture,
        lifecycle_labels(policy),
        merge_gate(policy),
    )
    print(json.dumps({"type": "merge_gate_contract", "data": result}, sort_keys=True))
    return 1 if result.get("status") == "blocked" else 0


if __name__ == "__main__":
    raise SystemExit(main())
