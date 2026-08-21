#!/usr/bin/env python3
"""Validate deterministic connector-normalized Cloud queue decisions."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from execution_contract import SHA256_KEY, parse_rfc3339, validate_run_record


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


def execution_contract(policy: dict[str, object]) -> dict[str, object]:
    contract = policy.get("execution_contract")
    if not isinstance(contract, dict):
        raise ValueError("policy execution_contract must be an object")
    return contract


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


def execution_metadata(issue: dict[str, object]) -> dict[str, object] | None:
    metadata = issue.get("execution")
    if metadata is None:
        return None
    if not isinstance(metadata, dict):
        raise ValueError("issue execution must be an object")
    return metadata


def validate_execution_metadata(
    issue: dict[str, object], contract: dict[str, object]
) -> tuple[dict[str, object] | None, str | None]:
    metadata = execution_metadata(issue)
    required = contract.get("approved_metadata")
    executors = contract.get("executor_values")
    if not isinstance(required, list) or not isinstance(executors, list):
        raise ValueError("execution contract metadata rules are invalid")
    if metadata is None:
        return None, "missing-execution-contract"
    missing = [
        str(field)
        for field in required
        if not isinstance(metadata.get(str(field)), str)
        or not str(metadata.get(str(field))).strip()
    ]
    if missing:
        return metadata, f"missing-execution-fields:{','.join(missing)}"
    if metadata["executor"] not in [str(value) for value in executors]:
        return metadata, "invalid-executor"
    if not SHA256_KEY.fullmatch(str(metadata["scope_hash"])):
        return metadata, "invalid-scope-hash"
    return metadata, None


def parse_timestamp(value: object, field: str) -> datetime:
    return parse_rfc3339(value, field).astimezone(timezone.utc)


def validate_lease(lease: object, contract: dict[str, object]) -> str | None:
    if not isinstance(lease, dict):
        return "missing-lease"
    lease_rules = contract.get("lease")
    if not isinstance(lease_rules, dict):
        raise ValueError("execution contract lease rules are invalid")
    required = lease_rules.get("required_fields")
    if not isinstance(required, list):
        raise ValueError("execution contract lease required_fields are invalid")
    missing = [
        str(field)
        for field in required
        if not isinstance(lease.get(str(field)), str) or not str(lease[str(field)]).strip()
    ]
    if missing:
        return f"invalid-lease-fields:{','.join(missing)}"
    try:
        parse_timestamp(lease["expires_at"], "lease.expires_at")
    except ValueError:
        return "invalid-lease-expiry"
    return None


def idempotency_key(
    repository: str,
    issue_number: int,
    plan_revision: str,
    scope_hash: str,
    event_id: str,
) -> str:
    values = (repository, str(issue_number), plan_revision, scope_hash, event_id)
    canonical = "\0".join(values).encode("utf-8")
    return f"sha256:{hashlib.sha256(canonical).hexdigest()}"


def approval_marker(metadata: dict[str, object]) -> str:
    payload = {field: metadata[field] for field in ("approval_id", "plan_revision", "scope_hash", "executor")}
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return f"<!-- rpm-agent-execution: {encoded} -->"


def execution_marker(
    metadata: dict[str, object],
    lease: dict[str, str],
    run: dict[str, str],
    prior_runs: list[dict[str, object]],
) -> str:
    payload = {**metadata, "lease": lease, "runs": [*prior_runs, run]}
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return f"<!-- rpm-agent-execution: {encoded} -->"


def persisted_runs(fixture: dict[str, object], issue: dict[str, object]) -> list[dict[str, object]]:
    execution = issue.get("execution")
    issue_number = int(issue.get("number", 0))
    sources: list[object] = []
    if isinstance(execution, dict) and "runs" in execution:
        sources.append(execution["runs"])
    runs_by_issue = fixture.get("runs_by_issue", {})
    if not isinstance(runs_by_issue, dict):
        raise ValueError("runs_by_issue must be an object keyed by issue number")
    if fixture.get("runs"):
        raise ValueError("top-level runs must be moved to runs_by_issue")
    sources.append(runs_by_issue.get(str(issue.get("number")), []))
    result: list[dict[str, object]] = []
    seen: set[str] = set()
    for raw_runs in sources:
        if not isinstance(raw_runs, list) or not all(isinstance(run, dict) for run in raw_runs):
            raise ValueError("persisted runs must be an array of objects")
        for run in raw_runs:
            scoped_run = dict(run)
            if "issue" in scoped_run:
                if not isinstance(scoped_run["issue"], int) or isinstance(scoped_run["issue"], bool):
                    raise ValueError("persisted runs must identify an integer issue")
                if scoped_run["issue"] != issue_number:
                    raise ValueError("persisted run belongs to another issue")
                scoped_run.pop("issue")
            try:
                validate_run_record(scoped_run, "persisted run")
            except ValueError as error:
                raise ValueError("persisted runs contains an invalid record") from error
            normalized = json.dumps(scoped_run, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            if normalized not in seen:
                seen.add(normalized)
                result.append(scoped_run)
    return result


def current_execution_marker(
    issue: dict[str, object], metadata: dict[str, object], runs: list[dict[str, object]]
) -> str:
    explicit = issue.get("execution_marker")
    if isinstance(explicit, str) and explicit.strip():
        return explicit.strip()
    execution = issue.get("execution")
    if not isinstance(execution, dict) or ("lease" not in execution and "runs" not in execution):
        return approval_marker(metadata)
    lease = execution.get("lease")
    if not runs:
        raise ValueError("recovery execution marker must include runs")
    if not isinstance(lease, dict):
        payload = {**metadata, "runs": runs}
        encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        return f"<!-- rpm-agent-execution: {encoded} -->"
    payload = {**metadata, "lease": lease, "runs": runs}
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return f"<!-- rpm-agent-execution: {encoded} -->"


def claim(
    fixture: dict[str, object],
    lifecycle: dict[str, str],
    contract: dict[str, object],
    issue_number: int,
    run_id: str,
    event_id: str,
    executor: str,
    plan_revision: str,
    scope_hash: str,
    lease_owner: str,
) -> dict[str, object]:
    issue = next(
        (item for item in normalized_issues(fixture) if int(item.get("number", 0)) == issue_number),
        None,
    )
    if issue is None:
        return {"status": "blocked", "reason": "issue-not-found"}
    current, matched = issue_state(issue, lifecycle)
    if len(matched) > 1:
        return {
            "status": "blocked",
            "reason": "multiple-lifecycle-labels",
            "states": matched,
        }
    if not is_open(issue):
        return {"status": "no-work", "reason": "issue-not-open", "issue": issue_number}
    if has_open_closing_pr(issue):
        return {
            "status": "no-work",
            "reason": "closing-pr-present",
            "issue": issue_number,
        }
    metadata, metadata_error = validate_execution_metadata(issue, contract)
    if metadata_error:
        return {"status": "blocked", "reason": metadata_error, "issue": issue_number}
    assert metadata is not None
    if str(metadata["plan_revision"]) != plan_revision:
        return {"status": "blocked", "reason": "plan-revision-mismatch", "issue": issue_number}
    if str(metadata["scope_hash"]) != scope_hash:
        return {"status": "blocked", "reason": "scope-hash-mismatch", "issue": issue_number}
    if str(metadata["executor"]) != executor:
        return {"status": "blocked", "reason": "executor-mismatch", "issue": issue_number}
    repository = fixture.get("repository")
    if not isinstance(repository, str) or not repository.strip():
        raise ValueError("fixture repository is required for claim")
    if not run_id.strip() or not event_id.strip() or not lease_owner.strip():
        raise ValueError("run_id, event_id, and lease_owner are required for claim")
    key = idempotency_key(repository, issue_number, plan_revision, scope_hash, event_id)
    try:
        runs = persisted_runs(fixture, issue)
    except ValueError as error:
        return {
            "status": "blocked",
            "reason": "invalid-run-ledger",
            "issue": issue_number,
            "detail": str(error),
        }
    matching_runs = [run for run in runs if run.get("idempotency_key") == key]
    if matching_runs:
        if all(run.get("run_id") == run_id for run in matching_runs):
            return {
                "status": "no-work",
                "reason": "duplicate-event",
                "issue": issue_number,
                "run_id": run_id,
                "idempotency_key": key,
            }
        return {"status": "blocked", "reason": "idempotency-conflict", "issue": issue_number}
    lease_rules = contract.get("lease")
    if not isinstance(lease_rules, dict):
        raise ValueError("execution contract lease rules are invalid")
    lease_field = str(lease_rules.get("field", "lease"))
    lease = metadata.get(lease_field)
    if current in set(str(value) for value in contract.get("active_states", [])) or lease is not None:
        lease_error = validate_lease(lease, contract)
        if lease_error:
            return {"status": "blocked", "reason": lease_error, "issue": issue_number}
        assert isinstance(lease, dict)
        now = parse_timestamp(fixture.get("now"), "fixture now")
        expires_at = parse_timestamp(lease.get("expires_at"), "lease.expires_at")
        if expires_at <= now:
            return {"status": "blocked", "reason": "lease-expired", "issue": issue_number}
        return {"status": "no-work", "reason": "lease-active", "issue": issue_number}
    if current != "ready":
        return {"status": "no-work", "reason": "issue-not-ready", "issue": issue_number}
    now = parse_timestamp(fixture.get("now"), "fixture now")
    lease_rules = contract.get("lease")
    if not isinstance(lease_rules, dict):
        raise ValueError("execution contract lease rules are invalid")
    ttl_seconds = int(lease_rules.get("ttl_seconds", 0))
    if ttl_seconds <= 0:
        raise ValueError("execution contract lease ttl must be positive")
    expires_at = now + timedelta(seconds=ttl_seconds)
    lease = {
        "run_id": run_id,
        "owner": lease_owner,
        "expires_at": expires_at.isoformat().replace("+00:00", "Z"),
    }
    run = {
        "run_id": run_id,
        "event_id": event_id,
        "idempotency_key": key,
        "status": "active",
    }
    prior_runs = [dict(previous_run) for previous_run in runs]
    marker = execution_marker(metadata, lease, run, prior_runs)
    ordinary = sorted(
        label for label in issue_labels(issue) if label not in lifecycle.values()
    )
    return {
        "status": "claim",
        "issue": issue_number,
        "before": "ready",
        "after": "claimed",
        "before_open": True,
        "expected_issue_state": str(issue.get("state", "")),
        "expected_closing_prs": issue.get("closing_prs", []),
        "run_id": run_id,
        "event_id": event_id,
        "idempotency_key": key,
        "expected_labels": issue_labels(issue),
        "preserved_labels": ordinary,
        "labels": sorted([*ordinary, lifecycle["claimed"]]),
        "lease": lease,
        "run": run,
        "expected_execution_marker": current_execution_marker(issue, metadata, runs),
        "execution_marker": marker,
        "execution": {
            "lease": lease,
            "runs": [*prior_runs, run],
        },
    }


def normalized_issues(fixture: dict[str, object]) -> list[dict[str, object]]:
    issues = fixture.get("issues")
    if not isinstance(issues, list) or not all(isinstance(issue, dict) for issue in issues):
        raise ValueError("fixture issues must be an array of objects")
    return sorted(issues, key=lambda issue: (int(issue.get("number", 0)), str(issue.get("url", ""))))


def select_execution(
    fixture: dict[str, object], lifecycle: dict[str, str], contract: dict[str, object], batch_limit: int
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
    active_states = set(str(value) for value in contract.get("active_states", []))
    active = [
        int(issue.get("number", 0))
        for issue, state in states
        if state in active_states
    ]
    if active:
        return {"status": "no-work", "reason": "active-work", "active": active, "issues": []}
    invalid_execution = []
    for issue, state in states:
        if state == "ready":
            _, reason = validate_execution_metadata(issue, contract)
            if reason:
                invalid_execution.append({"number": issue.get("number"), "reason": reason})
    if invalid_execution:
        return {
            "status": "blocked",
            "reason": "execution-contract-invalid",
            "invalid": invalid_execution,
            "issues": [],
        }
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
        choices=("select-execution", "select-review", "transition", "claim"),
    )
    parser.add_argument("--issue", type=int)
    parser.add_argument("--from-state")
    parser.add_argument("--to-state")
    parser.add_argument("--run-id")
    parser.add_argument("--event-id")
    parser.add_argument("--executor")
    parser.add_argument("--plan-revision")
    parser.add_argument("--scope-hash")
    parser.add_argument("--lease-owner")
    args = parser.parse_args()

    policy = load_json(args.policy)
    fixture = load_json(args.issues_file)
    lifecycle = lifecycle_labels(policy)
    contract = execution_contract(policy)
    if args.operation == "select-execution":
        limit = int(dict(policy["batch_limits"])["execution"])
        result = select_execution(fixture, lifecycle, contract, limit)
    elif args.operation == "select-review":
        result = select_review(fixture, lifecycle)
    elif args.operation == "transition":
        if args.issue is None or args.from_state is None or args.to_state is None:
            parser.error("transition requires --issue, --from-state, and --to-state")
        result = transition(
            fixture,
            lifecycle,
            args.issue,
            args.from_state,
            args.to_state,
        )
    else:
        required = {
            "issue_number": args.issue,
            "run_id": args.run_id,
            "event_id": args.event_id,
            "executor": args.executor,
            "plan_revision": args.plan_revision,
            "scope_hash": args.scope_hash,
            "lease_owner": args.lease_owner,
        }
        if any(value is None for value in required.values()):
            parser.error("claim requires --issue, --run-id, --event-id, --executor, --plan-revision, --scope-hash, and --lease-owner")
        result = claim(fixture, lifecycle, contract, **required)
    print(json.dumps({"type": "cloud_queue_contract", "data": result}, sort_keys=True))
    return 1 if result.get("status") == "blocked" else 0


if __name__ == "__main__":
    raise SystemExit(main())
