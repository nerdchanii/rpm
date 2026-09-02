#!/usr/bin/env python3
"""Validate deterministic connector-normalized Cloud queue decisions."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path


CORRECTION_LABEL_PREFIX = "agent:correction-"
CANONICAL_SOURCE_PATTERN = re.compile(r"(?:pr|issue):[1-9][0-9]*\Z")
CANONICAL_FINGERPRINT_PATTERN = re.compile(r"sha256:[0-9a-f]{64}\Z")
TRANSITION_ACTOR_FIELDS = {
    "ready": "ready_transition_actor",
    "awaiting-merge": "awaiting_merge_transition_actor",
}
SERIAL_PIPELINE_STATES = ["claimed", "review-pending", "awaiting-merge"]


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
    expected_states = set(TRANSITION_ACTOR_FIELDS)
    if set(str(state) for state in actors) != expected_states:
        raise ValueError(
            "policy trusted_lifecycle_actors must cover ready and awaiting-merge"
        )
    result: dict[str, list[str]] = {}
    for state in sorted(expected_states):
        values = actors.get(state)
        if not isinstance(values, list) or not values:
            raise ValueError(f"policy trusted_lifecycle_actors.{state} must be non-empty")
        if not all(type(actor) is str and actor.strip() for actor in values):
            raise ValueError(
                f"policy trusted_lifecycle_actors.{state} must contain actor names"
            )
        normalized = [actor.casefold() for actor in values]
        if len(set(normalized)) != len(normalized):
            raise ValueError(
                f"policy trusted_lifecycle_actors.{state} must contain unique actors"
            )
        result[state] = normalized
    return result


def transition_actor_error(
    issue: dict[str, object], state: str, trusted_actors: dict[str, list[str]]
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


def execution_contract(policy: dict[str, object]) -> dict[str, object]:
    contract = policy.get("execution_contract")
    if not isinstance(contract, dict):
        raise ValueError("policy execution_contract must be an object")
    if contract.get("active_states") != SERIAL_PIPELINE_STATES:
        raise ValueError(
            "execution contract active_states must cover claimed, review-pending, and awaiting-merge"
        )
    if contract.get("blocking_states") != SERIAL_PIPELINE_STATES:
        raise ValueError(
            "execution contract blocking_states must cover claimed, review-pending, and awaiting-merge"
        )
    return contract


def validate_execution_queue(policy: dict[str, object]) -> None:
    queue = policy.get("execution_queue")
    if not isinstance(queue, dict):
        raise ValueError("policy execution_queue must be an object")
    if queue.get("active_states") != SERIAL_PIPELINE_STATES:
        raise ValueError(
            "execution queue active_states must cover claimed, review-pending, and awaiting-merge"
        )
    if queue.get("blocking_states") != SERIAL_PIPELINE_STATES:
        raise ValueError(
            "execution queue blocking_states must cover claimed, review-pending, and awaiting-merge"
        )


def review_correction_contract(policy: dict[str, object]) -> dict[str, object]:
    contract = policy.get("review_correction")
    if not isinstance(contract, dict):
        raise ValueError("policy review_correction must be an object")
    max_attempts = contract.get("max_attempts")
    labels = contract.get("counter_labels")
    if type(max_attempts) is not int or max_attempts < 0:
        raise ValueError("review_correction max_attempts must be a non-negative integer")
    if not isinstance(labels, dict):
        raise ValueError("review_correction counter_labels must be an object")
    expected_keys = {str(attempt) for attempt in range(max_attempts + 1)}
    if set(str(key) for key in labels) != expected_keys:
        raise ValueError("review_correction counter_labels must cover every attempt")
    values = [value for value in labels.values() if isinstance(value, str) and value.strip()]
    if len(values) != len(labels) or len(set(values)) != len(values):
        raise ValueError("review_correction counter_labels must contain unique labels")
    expected_values = {
        str(attempt): f"{CORRECTION_LABEL_PREFIX}{attempt}"
        for attempt in range(max_attempts + 1)
    }
    if labels != expected_values:
        raise ValueError("review_correction counter_labels must use canonical labels")
    if contract.get("exhausted_result") != "blocked":
        raise ValueError("review_correction exhausted_result must be blocked")
    return contract


def followup_contract(policy: dict[str, object]) -> dict[str, object]:
    contract = policy.get("followup")
    if not isinstance(contract, dict):
        raise ValueError("policy followup must be an object")
    max_per_source = contract.get("max_per_source")
    fields = contract.get("dedupe_key_fields")
    if type(max_per_source) is not int or max_per_source <= 0:
        raise ValueError("followup max_per_source must be a positive integer")
    if fields != ["source", "fingerprint"]:
        raise ValueError("followup dedupe_key_fields must be source and fingerprint")
    if contract.get("duplicate_result") != "duplicate":
        raise ValueError("followup duplicate_result must be duplicate")
    if contract.get("identity_label") != "process:agent-followup":
        raise ValueError("followup identity_label must be process:agent-followup")
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
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(metadata["scope_hash"])):
        return metadata, "invalid-scope-hash"
    return metadata, None


def parse_timestamp(value: object, field: str) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be an RFC3339 timestamp")
    normalized = value.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise ValueError(f"{field} must be an RFC3339 timestamp") from error
    if parsed.tzinfo is None:
        raise ValueError(f"{field} must include a timezone")
    return parsed.astimezone(timezone.utc)


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


def claim(
    fixture: dict[str, object],
    lifecycle: dict[str, str],
    contract: dict[str, object],
    trusted_actors: dict[str, list[str]],
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
    if current == "ready":
        actor_error = transition_actor_error(issue, "ready", trusted_actors)
        if actor_error is not None:
            return {
                "status": "blocked",
                "reason": "malformed-ready",
                "issue": issue_number,
                "invalid": [{"number": issue_number, "reason": actor_error}],
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
    lease_rules = contract.get("lease")
    if not isinstance(lease_rules, dict):
        raise ValueError("execution contract lease rules are invalid")
    lease_field = str(lease_rules.get("field", "lease"))
    if not lease_field.strip():
        raise ValueError("execution contract lease field is required")
    repository = fixture.get("repository")
    if not isinstance(repository, str) or not repository.strip():
        raise ValueError("fixture repository is required for claim")
    if not run_id.strip() or not event_id.strip() or not lease_owner.strip():
        raise ValueError("run_id, event_id, and lease_owner are required for claim")
    key = idempotency_key(repository, issue_number, plan_revision, scope_hash, event_id)
    runs = fixture.get("runs", [])
    if not isinstance(runs, list) or not all(isinstance(run, dict) for run in runs):
        raise ValueError("fixture runs must be an array of objects")
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
    if current in set(str(value) for value in contract.get("active_states", [])):
        lease = metadata.get(lease_field)
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
    ttl_seconds = int(lease_rules.get("ttl_seconds", 0))
    if ttl_seconds <= 0:
        raise ValueError("execution contract lease ttl must be positive")
    expires_at = now + timedelta(seconds=ttl_seconds)
    ordinary = sorted(
        label for label in issue_labels(issue) if label not in lifecycle.values()
    )
    idempotency = contract.get("idempotency")
    if not isinstance(idempotency, dict):
        raise ValueError("execution contract idempotency rules are invalid")
    ledger_field = str(idempotency.get("ledger_field", "runs"))
    if not ledger_field.strip():
        raise ValueError("execution contract idempotency ledger_field is required")
    run_entry = {
        "repository": repository,
        "issue": issue_number,
        "plan_revision": plan_revision,
        "scope_hash": scope_hash,
        "event_id": event_id,
        "idempotency_key": key,
        "run_id": run_id,
        "status": "active",
    }
    existing_execution_runs = metadata.get(ledger_field)
    if existing_execution_runs is None:
        existing_execution_runs = runs
    if not isinstance(existing_execution_runs, list) or not all(
        isinstance(run, dict) for run in existing_execution_runs
    ):
        return {
            "status": "blocked",
            "reason": "invalid-execution-runs",
            "issue": issue_number,
        }
    updated_execution = dict(metadata)
    updated_execution[lease_field] = {
        "run_id": run_id,
        "owner": lease_owner,
        "expires_at": expires_at.isoformat().replace("+00:00", "Z"),
    }
    updated_execution[ledger_field] = [*existing_execution_runs, run_entry]
    return {
        "status": "claim",
        "issue": issue_number,
        "before": "ready",
        "after": "claimed",
        "run_id": run_id,
        "idempotency_key": key,
        "preserved_labels": ordinary,
        "labels": sorted([*ordinary, lifecycle["claimed"]]),
        "lease": updated_execution[lease_field],
        "run_entry": run_entry,
        "updated_execution": updated_execution,
    }


def normalized_issues(fixture: dict[str, object]) -> list[dict[str, object]]:
    issues = fixture.get("issues")
    if not isinstance(issues, list) or not all(isinstance(issue, dict) for issue in issues):
        raise ValueError("fixture issues must be an array of objects")
    return sorted(issues, key=lambda issue: (int(issue.get("number", 0)), str(issue.get("url", ""))))


def select_execution(
    fixture: dict[str, object],
    lifecycle: dict[str, str],
    contract: dict[str, object],
    trusted_actors: dict[str, list[str]],
    batch_limit: int,
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
    invalid_ready = []
    for issue, state in states:
        if state == "ready":
            reasons = []
            actor_error = transition_actor_error(issue, "ready", trusted_actors)
            if actor_error:
                reasons.append(actor_error)
            _, metadata_error = validate_execution_metadata(issue, contract)
            if metadata_error:
                reasons.append(metadata_error)
            if reasons:
                invalid_ready.append(
                    {
                        "number": issue.get("number"),
                        "reason": reasons[0],
                        "reasons": reasons,
                    }
                )
    if invalid_ready:
        return {
            "status": "blocked",
            "reason": "malformed-ready",
            "invalid": invalid_ready,
            "issues": [],
        }
    active_states = set(str(value) for value in contract.get("active_states", []))
    blocking_states = set(str(value) for value in contract.get("blocking_states", []))
    if not blocking_states.issubset(active_states):
        raise ValueError("execution contract blocking_states must be active states")
    active = [
        int(issue.get("number", 0))
        for issue, state in states
        if state in active_states
    ]
    blocking = [
        int(issue.get("number", 0))
        for issue, state in states
        if state in blocking_states
    ]
    if blocking:
        return {
            "status": "no-work",
            "reason": "active-work",
            "active": active,
            "blocking": blocking,
            "blocking_states": sorted(blocking_states),
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


def normalized_pull_requests(fixture: dict[str, object]) -> list[dict[str, object]]:
    pull_requests = fixture.get("pull_requests")
    if not isinstance(pull_requests, list) or not all(
        isinstance(pull_request, dict) for pull_request in pull_requests
    ):
        raise ValueError("fixture pull_requests must be an array of objects")
    return sorted(
        pull_requests,
        key=lambda pull_request: (
            int(pull_request.get("number", 0)),
            str(pull_request.get("url", "")),
        ),
    )


def validate_correction_labels(
    pull_request: dict[str, object],
    pull_request_number: int,
    counter_labels: dict[int, str],
) -> tuple[list[str], list[int]] | dict[str, object]:
    labels = pull_request.get("labels", [])
    if not isinstance(labels, list):
        return {
            "status": "blocked",
            "reason": "invalid-correction-labels",
            "pr": pull_request_number,
        }
    if not all(isinstance(label, str) for label in labels):
        return {
            "status": "blocked",
            "reason": "invalid-correction-labels",
            "pr": pull_request_number,
            "invalid_labels": [label for label in labels if not isinstance(label, str)],
        }
    if len(labels) != len(set(labels)):
        return {
            "status": "blocked",
            "reason": "duplicate-pr-labels",
            "pr": pull_request_number,
            "labels": labels,
        }
    labels = sorted(labels)
    allowed = set(counter_labels.values())
    unknown = sorted(
        label
        for label in labels
        if label.startswith(CORRECTION_LABEL_PREFIX) and label not in allowed
    )
    if unknown:
        return {
            "status": "blocked",
            "reason": "invalid-correction-label",
            "pr": pull_request_number,
            "invalid_labels": unknown,
            "preserved_labels": labels,
        }
    counters = [attempt for attempt, label in counter_labels.items() if label in labels]
    return labels, counters


def next_correction(
    fixture: dict[str, object], policy: dict[str, object], pull_request_number: int
) -> dict[str, object]:
    pull_request = next(
        (
            item
            for item in normalized_pull_requests(fixture)
            if int(item.get("number", 0)) == pull_request_number
        ),
        None,
    )
    if pull_request is None:
        return {"status": "blocked", "reason": "pull-request-not-found"}
    pull_request_state = pull_request.get("state")
    if not isinstance(pull_request_state, str) or not pull_request_state.strip():
        return {
            "status": "blocked",
            "reason": "invalid-pull-request-state",
            "pr": pull_request_number,
        }
    if pull_request_state.casefold() != "open":
        return {
            "status": "no-work",
            "reason": "pull-request-not-open",
            "pr": pull_request_number,
        }
    contract = review_correction_contract(policy)
    max_attempts = int(contract["max_attempts"])
    counter_labels = {
        int(attempt): str(label)
        for attempt, label in dict(contract["counter_labels"]).items()
    }
    validated_labels = validate_correction_labels(
        pull_request, pull_request_number, counter_labels
    )
    if isinstance(validated_labels, dict):
        return validated_labels
    labels, counters = validated_labels
    if len(counters) > 1:
        return {
            "status": "blocked",
            "reason": "multiple-correction-labels",
            "pr": pull_request_number,
            "attempts": sorted(counters),
        }
    current = counters[0] if counters else -1
    if current < 0:
        return {
            "status": "blocked",
            "reason": "missing-correction-counter",
            "pr": pull_request_number,
            "attempt": 0,
            "required_label": counter_labels[0],
            "preserved_labels": labels,
        }
    next_attempt = current + 1
    if next_attempt > max_attempts:
        return {
            "status": "blocked",
            "reason": "correction-limit",
            "pr": pull_request_number,
            "attempt": next_attempt,
            "last_attempt": current,
            "max_attempts": max_attempts,
            "preserved_labels": labels,
        }
    counter_values = set(counter_labels.values())
    ordinary = sorted(label for label in labels if label not in counter_values)
    return {
        "status": "correction",
        "pr": pull_request_number,
        "before_attempt": None if current < 0 else current,
        "after_attempt": next_attempt,
        "attempt": next_attempt,
        "label": counter_labels[next_attempt],
        "preserved_labels": ordinary,
        "labels": sorted([*ordinary, counter_labels[next_attempt]]),
    }


def initialize_correction(
    fixture: dict[str, object], policy: dict[str, object], pull_request_number: int
) -> dict[str, object]:
    pull_request = next(
        (
            item
            for item in normalized_pull_requests(fixture)
            if int(item.get("number", 0)) == pull_request_number
        ),
        None,
    )
    if pull_request is None:
        return {"status": "blocked", "reason": "pull-request-not-found"}
    pull_request_state = pull_request.get("state")
    if not isinstance(pull_request_state, str) or not pull_request_state.strip():
        return {
            "status": "blocked",
            "reason": "invalid-pull-request-state",
            "pr": pull_request_number,
        }
    if pull_request_state.casefold() != "open":
        return {
            "status": "no-work",
            "reason": "pull-request-not-open",
            "pr": pull_request_number,
        }
    contract = review_correction_contract(policy)
    counter_labels = {
        int(attempt): str(label)
        for attempt, label in dict(contract["counter_labels"]).items()
    }
    validated_labels = validate_correction_labels(
        pull_request, pull_request_number, counter_labels
    )
    if isinstance(validated_labels, dict):
        return validated_labels
    labels, counters = validated_labels
    if counters:
        if len(counters) > 1:
            return {
                "status": "blocked",
                "reason": "multiple-correction-labels",
                "pr": pull_request_number,
                "attempts": sorted(counters),
            }
        return {
            "status": "no-work",
            "reason": "correction-counter-present",
            "pr": pull_request_number,
            "attempt": counters[0],
            "label": counter_labels[counters[0]],
            "preserved_labels": labels,
        }
    ordinary = sorted(label for label in labels if label not in counter_labels.values())
    return {
        "status": "initialize",
        "pr": pull_request_number,
        "after_attempt": 0,
        "label": counter_labels[0],
        "preserved_labels": ordinary,
        "labels": sorted([*ordinary, counter_labels[0]]),
    }


def decide_followup(
    fixture: dict[str, object], policy: dict[str, object], source: str, fingerprint: str
) -> dict[str, object]:
    if not isinstance(source, str) or CANONICAL_SOURCE_PATTERN.fullmatch(source) is None:
        return {"status": "blocked", "reason": "invalid-followup-source"}
    if (
        not isinstance(fingerprint, str)
        or CANONICAL_FINGERPRINT_PATTERN.fullmatch(fingerprint) is None
    ):
        return {
            "status": "blocked",
            "reason": "invalid-followup-fingerprint",
            "source": source,
        }
    contract = followup_contract(policy)
    identity_label = str(contract["identity_label"])
    existing = fixture.get("followups", [])
    if not isinstance(existing, list) or not all(isinstance(item, dict) for item in existing):
        raise ValueError("fixture followups must be an array of objects")
    normalized_existing = []
    for item in existing:
        item_labels = item.get("labels", [])
        if not isinstance(item_labels, list) or not all(
            isinstance(label, str) for label in item_labels
        ):
            return {
                "status": "blocked",
                "reason": "invalid-existing-followup-labels",
                "issue": item.get("number"),
            }
        if identity_label not in item_labels:
            continue
        item_source = item.get("source")
        item_fingerprint = item.get("fingerprint")
        if (
            not isinstance(item_source, str)
            or CANONICAL_SOURCE_PATTERN.fullmatch(item_source) is None
            or not isinstance(item_fingerprint, str)
            or CANONICAL_FINGERPRINT_PATTERN.fullmatch(item_fingerprint) is None
        ):
            return {
                "status": "blocked",
                "reason": "invalid-existing-followup-identity",
                "issue": item.get("number"),
            }
        normalized_existing.append(
            {**item, "source": item_source, "fingerprint": item_fingerprint}
        )
    matching = [
        item
        for item in normalized_existing
        if str(item.get("source", "")) == source
        and str(item.get("fingerprint", "")) == fingerprint
    ]
    if matching:
        return {
            "status": "duplicate",
            "reason": "existing-followup",
            "source": source,
            "fingerprint": fingerprint,
            "existing": matching[0],
        }
    source_count = sum(
        1 for item in normalized_existing if str(item.get("source", "")) == source
    )
    max_per_source = int(contract["max_per_source"])
    if source_count >= max_per_source:
        return {
            "status": "blocked",
            "reason": "followup-limit",
            "source": source,
            "count": source_count,
            "max_per_source": max_per_source,
        }
    return {
        "status": "eligible",
        "reason": "new-followup",
        "source": source,
        "fingerprint": fingerprint,
        "ordinal": source_count + 1,
        "max_per_source": max_per_source,
    }


def transition(
    fixture: dict[str, object],
    lifecycle: dict[str, str],
    allowed_transitions: object,
    trusted_actors: dict[str, list[str]],
    issue_number: int,
    before: str,
    after: str,
) -> dict[str, object]:
    if not isinstance(allowed_transitions, dict):
        return {
            "status": "blocked",
            "reason": "invalid-transition-policy",
            "before": before,
            "after": after,
        }

    normalized_transitions: dict[str, list[str]] = {}
    for source, targets in allowed_transitions.items():
        if not isinstance(source, str) or not source.strip() or not isinstance(targets, list):
            return {
                "status": "blocked",
                "reason": "invalid-transition-policy",
                "before": before,
                "after": after,
            }
        if not all(isinstance(target, str) and target.strip() for target in targets):
            return {
                "status": "blocked",
                "reason": "invalid-transition-policy",
                "before": before,
                "after": after,
            }
        normalized_transitions[source] = [str(target) for target in targets]

    known_states = set(lifecycle) | set(normalized_transitions)
    known_states.update(
        target for targets in normalized_transitions.values() for target in targets
    )
    unknown_states = sorted(
        state for state in {before, after} if state not in known_states
    )
    if unknown_states:
        return {
            "status": "blocked",
            "reason": "unknown-state",
            "states": unknown_states,
            "before": before,
            "after": after,
        }

    allowed_targets = normalized_transitions.get(before, [])
    if after not in allowed_targets:
        return {
            "status": "blocked",
            "reason": "transition-not-allowed",
            "before": before,
            "after": after,
            "allowed_targets": allowed_targets,
        }

    issue = next(
        (item for item in normalized_issues(fixture) if int(item.get("number", 0)) == issue_number),
        None,
    )
    if issue is None:
        return {"status": "blocked", "reason": "issue-not-found"}
    current, matched = issue_state(issue, lifecycle)
    if not is_open(issue) or current != before or len(matched) != 1:
        return {"status": "no-work", "reason": "compare-and-set-mismatch", "current": current}
    actor_states = {before} if before == "ready" and after != "blocked" else set()
    # A merge-gate failure can demote an awaiting-merge issue.  Re-read the
    # provenance for that state before allowing the destructive label change;
    # an absent or untrusted actor must fail closed.
    if before == "awaiting-merge" and after == "blocked":
        actor_states.add(before)
    if after in TRANSITION_ACTOR_FIELDS:
        actor_states.add(after)
    for actor_state in sorted(actor_states):
        actor_error = transition_actor_error(issue, actor_state, trusted_actors)
        if actor_error is not None:
            return {
                "status": "blocked",
                "reason": actor_error,
                "issue": issue_number,
                "before": before,
                "after": after,
            }
    if after not in lifecycle:
        return {
            "status": "blocked",
            "reason": "state-label-missing",
            "state": after,
        }
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
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--issues-file")
    source.add_argument("--issues-json")
    parser.add_argument(
        "--operation",
        required=True,
        choices=(
            "select-execution",
            "select-review",
            "transition",
            "claim",
            "correction",
            "initialize-correction",
            "followup",
        ),
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
    parser.add_argument("--pr", type=int)
    parser.add_argument("--source")
    parser.add_argument("--fingerprint")
    args = parser.parse_args()

    policy = load_json(args.policy)
    fixture = load_json_input(args.issues_file, args.issues_json)
    lifecycle = lifecycle_labels(policy)
    contract = execution_contract(policy)
    validate_execution_queue(policy)
    trusted_actors = trusted_lifecycle_actors(policy)
    if args.operation == "select-execution":
        limit = int(dict(policy["batch_limits"])["execution"])
        result = select_execution(fixture, lifecycle, contract, trusted_actors, limit)
    elif args.operation == "select-review":
        result = select_review(fixture, lifecycle)
    elif args.operation == "transition":
        if args.issue is None or args.from_state is None or args.to_state is None:
            parser.error("transition requires --issue, --from-state, and --to-state")
        result = transition(
            fixture,
            lifecycle,
            policy.get("allowed_transitions"),
            trusted_actors,
            args.issue,
            args.from_state,
            args.to_state,
        )
    elif args.operation == "claim":
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
        result = claim(
            fixture,
            lifecycle,
            contract,
            trusted_actors,
            **required,
        )
    elif args.operation == "correction":
        if args.pr is None:
            parser.error("correction requires --pr")
        result = next_correction(fixture, policy, args.pr)
    elif args.operation == "initialize-correction":
        if args.pr is None:
            parser.error("initialize-correction requires --pr")
        result = initialize_correction(fixture, policy, args.pr)
    else:
        if args.source is None or args.fingerprint is None:
            parser.error("followup requires --source and --fingerprint")
        result = decide_followup(fixture, policy, args.source, args.fingerprint)
    print(json.dumps({"type": "cloud_queue_contract", "data": result}, sort_keys=True))
    return 1 if result.get("status") == "blocked" else 0


if __name__ == "__main__":
    raise SystemExit(main())
