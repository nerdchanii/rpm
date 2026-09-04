#!/usr/bin/env python3
"""Validate deterministic connector-normalized Cloud queue decisions."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SHA256 = re.compile(r"sha256:[0-9a-f]{64}")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
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


def has_only_unfinished_open_closing_pr(issue: dict[str, object]) -> bool:
    """Identify open closing PRs that have no completed adoption evidence.

    An open closing PR becomes an adoption candidate only after its complete
    current-head evidence has been materialized.  Draft status is one useful
    signal, while a non-draft PR can still be in review or have pending checks.
    Treat an issue without a completed evidence document as unfinished so it
    does not strand unrelated ready work in the ordinary execution queue.
    """
    prs = issue.get("closing_prs", [])
    if not isinstance(prs, list):
        raise ValueError("closing_prs must be an array")
    open_prs = [
        pr
        for pr in prs
        if isinstance(pr, dict)
        and str(pr.get("state", "")).casefold() == "open"
    ]
    return (
        bool(open_prs)
        and issue.get("implementation_complete") is not True
        and not isinstance(issue.get("completed_pr_evidence"), dict)
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
        lease_rules = contract.get("lease")
        if not isinstance(lease_rules, dict):
            raise ValueError("execution contract lease rules are invalid")
        lease_field = str(lease_rules.get("field", "lease"))
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
    lease_rules = contract.get("lease")
    if not isinstance(lease_rules, dict):
        raise ValueError("execution contract lease rules are invalid")
    ttl_seconds = int(lease_rules.get("ttl_seconds", 0))
    if ttl_seconds <= 0:
        raise ValueError("execution contract lease ttl must be positive")
    expires_at = now + timedelta(seconds=ttl_seconds)
    ordinary = sorted(
        label for label in issue_labels(issue) if label not in lifecycle.values()
    )
    return {
        "status": "claim",
        "issue": issue_number,
        "before": "ready",
        "after": "claimed",
        "run_id": run_id,
        "idempotency_key": key,
        "preserved_labels": ordinary,
        "labels": sorted([*ordinary, lifecycle["claimed"]]),
        "lease": {
            "run_id": run_id,
            "owner": lease_owner,
            "expires_at": expires_at.isoformat().replace("+00:00", "Z"),
        },
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
    batch_limit: int,
    policy: dict[str, object] | None = None,
) -> dict[str, object]:
    inventory = fixture.get("execution_inventory")
    records, inventory_error = complete_inventory(
        inventory, source="repository-open-issue-lifecycle-inventory-v1"
    )
    if inventory_error:
        return blocked(f"execution-{inventory_error}")
    assert records is not None and isinstance(inventory, dict)
    if inventory.get("repository") != fixture.get("repository"):
        return blocked("execution-inventory-repository-mismatch")
    issue_identities = {
        (fixture.get("repository"), int(issue.get("number", 0)))
        for issue in normalized_issues(fixture)
        if is_open(issue)
    }
    record_identities: set[tuple[object, int]] = set()
    for record in records:
        if record.get("repository") != fixture.get("repository") or not isinstance(
            record.get("number"), int
        ):
            return blocked("execution-inventory-record-identity-mismatch")
        identity = (record.get("repository"), int(record["number"]))
        if identity in record_identities:
            return blocked("execution-inventory-record-identity-duplicate")
        record_identities.add(identity)
    if record_identities != issue_identities:
        return blocked("execution-inventory-record-identity-mismatch")
    open_issues = [issue for issue in normalized_issues(fixture) if is_open(issue)]
    closing_error = validate_closing_pr_inventory(
        fixture, open_issues, str(fixture.get("repository"))
    )
    if closing_error:
        open_with_pr = [
            int(issue.get("number", 0))
            for issue in open_issues
            if isinstance(issue.get("closing_prs"), list)
            and len(issue.get("closing_prs", [])) > 0
        ]
        # Adoption is a lifecycle decision that may be exposed only after the
        # complete repository relationship inventory has been validated.  A
        # missing, partial, or identity-mismatched inventory must remain
        # visible to the caller; otherwise an incomplete connector response
        # can be misreported as a healthy adoption candidate.
        return blocked(
            closing_error,
            issues=open_with_pr,
            inventory_reason=closing_error,
        )
    invalid = []
    states: list[tuple[dict[str, object], str]] = []
    for issue in open_issues:
        state, matched = issue_state(issue, lifecycle)
        if state == "invalid":
            invalid.append({"number": issue.get("number"), "states": matched})
        states.append((issue, state))
    if invalid:
        return {"status": "blocked", "reason": "multiple-lifecycle-labels", "invalid": invalid, "issues": []}
    adoption_required: list[int] = []
    for issue, state in states:
        if state != "untracked" or not has_open_closing_pr(issue):
            continue
        if has_only_unfinished_open_closing_pr(issue):
            continue
        completed = issue.get("completed_pr_evidence")
        adoption = adoption_contract(policy or {})
        if not isinstance(adoption, dict):
            return blocked("wiring-blocked")
        if not isinstance(completed, dict):
            return blocked("adoption-evidence-incomplete")
        pr = completed.get("pr")
        evidence_issue = completed.get("issue")
        if not isinstance(pr, dict) or not isinstance(evidence_issue, dict):
            return blocked("adoption-evidence-incomplete")
        head = pr.get("head")
        closing = issue.get("closing_prs")
        if (
            not isinstance(head, dict)
            or not isinstance(closing, list)
            or len(closing) != 1
            or not isinstance(closing[0], dict)
            or evidence_issue.get("number") != issue.get("number")
            or pr.get("number") != closing[0].get("number")
            or str(pr.get("state", "")).casefold() != "open"
            or pr.get("is_draft") is not False
            or validate_checks(completed, adoption, str(head.get("sha"))) is not None
            or validate_review(completed, adoption, str(head.get("sha"))) is not None
            or validate_findings(completed, adoption, str(head.get("sha"))) is not None
        ):
            return blocked("adoption-evidence-incomplete")
        adoption_required.append(int(issue.get("number", 0)))
    adoption_required.sort()
    if adoption_required:
        return {
            "status": "blocked",
            "reason": (
                "adoption-required"
                if isinstance(policy, dict)
                and isinstance(policy.get("existing_pr_adoption"), dict)
                else "wiring-blocked"
            ),
            "issues": adoption_required,
        }
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
    active_states = set(str(value) for value in contract.get("active_states", []))
    active = [
        int(issue.get("number", 0))
        for issue, state in states
        if state in active_states
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
    policy: dict[str, object],
    issue_number: int,
    before: str,
    after: str,
) -> dict[str, object]:
    allowed = policy.get("allowed_transitions")
    if (
        not isinstance(allowed, dict)
        or before not in allowed
        or not isinstance(allowed.get(before), list)
        or after not in allowed[before]
    ):
        return blocked("transition-not-allowed")
    issue = next(
        (item for item in normalized_issues(fixture) if int(item.get("number", 0)) == issue_number),
        None,
    )
    if issue is None:
        return {"status": "blocked", "reason": "issue-not-found"}
    current, matched = issue_state(issue, lifecycle)
    expected_match_count = 0 if before == "untracked" else 1
    if not is_open(issue) or current != before or len(matched) != expected_match_count:
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


def blocked(reason: str, **details: object) -> dict[str, object]:
    return {"status": "blocked", "reason": reason, **details}


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

        def sort_key(item: object) -> tuple[str, ...]:
            if fields == ("$value",) or not isinstance(item, dict):
                return (json.dumps(item, ensure_ascii=False, sort_keys=True),)
            # The declared fields keep the common ordering readable.  The
            # complete canonical item breaks ties when two records share the
            # declared identity fields, including findings with distinct
            # source IDs.
            return (
                *(str(item.get(field, "")) for field in fields),
                json.dumps(
                    canonicalize(item, path),
                    ensure_ascii=False,
                    sort_keys=True,
                    separators=(",", ":"),
                ),
            )

        return sorted(normalized, key=sort_key)
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
    payload = json.dumps(
        canonicalize(value, root_path),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return f"sha256:{hashlib.sha256(payload).hexdigest()}"


def adoption_evidence(value: object) -> object:
    """Normalize the one authorized lifecycle delta before digesting evidence.

    The prepared authorization covers the issue, PR, checks, review, findings,
    writer, dependent, and execution evidence.  Adding
    ``agent:review-pending`` is the operation's expected post-state and must
    remain visible in the live observation while leaving that immutable digest
    unchanged.  Other label or lifecycle changes are still rejected by the
    normal identity/CAS checks.
    """
    normalized = copy.deepcopy(value)
    if isinstance(normalized, dict):
        execution = normalized.get("execution")
        if isinstance(execution, dict) and "evidence_digest" in execution:
            # The approved marker carries the digest of this same evidence.
            # Mask only that self-referential field while keeping the marker's
            # complete target identity inside the canonical digest.
            execution["evidence_digest"] = "<evidence-digest>"
        issue = normalized.get("issue")
        if isinstance(issue, dict):
            labels = issue.get("labels")
            if isinstance(labels, list):
                issue["labels"] = sorted(
                    str(label)
                    for label in labels
                    if not str(label).startswith("agent:")
                )
            issue["lifecycle_state"] = "untracked"
        writers = normalized.get("writers")
        if isinstance(writers, dict):
            if "observed_at" in writers:
                # The live read binds this value to its current authorization,
                # but it is a runtime clock and must not make an otherwise
                # unchanged prepared ledger digest stale on a later retry.
                writers["observed_at"] = "<observation-time>"
            records = writers.get("records")
            if isinstance(records, list):
                # The adopter publishes its own short-lived writer lease before
                # the first ledger write.  That runtime lock is validated and
                # CAS-bound independently, so it cannot make the user's
                # immutable pre-lease authorization stale.  Other writer kinds
                # remain part of the authorized evidence.
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
                writers["cas_token"] = canonical_digest(
                    {
                        "repository": writers.get("repository"),
                        "records": stable_records,
                    }
                )
    return normalized


def adoption_evidence_digest(value: object) -> str:
    return canonical_digest(adoption_evidence(value))


def immutable_adoption_authorization(value: object) -> object:
    normalized = copy.deepcopy(value)
    if isinstance(normalized, dict) and "observation_time" in normalized:
        normalized["observation_time"] = "<observation-time>"
    return normalized


def comparable_ledger_comment(value: dict[str, object]) -> dict[str, object]:
    """Normalize runtime-only fields before comparing duplicate phase writes."""
    normalized = copy.deepcopy(value)
    normalized.pop("comment_id", None)
    document = normalized.get("prepared_document")
    if isinstance(document, dict):
        document["authorization"] = immutable_adoption_authorization(
            document.get("authorization")
        )
        document["evidence"] = adoption_evidence(document.get("evidence"))
        normalized["prepared_document_digest"] = canonical_digest(document)
    return normalized


def adoption_contract(policy: dict[str, object]) -> dict[str, object] | None:
    value = policy.get("existing_pr_adoption")
    return value if isinstance(value, dict) else None


def complete_inventory(
    value: object,
    *,
    source: str,
    records_field: str = "records",
    repository: str | None = None,
) -> tuple[list[dict[str, object]] | None, str | None]:
    if not isinstance(value, dict):
        return None, "inventory-missing"
    if value.get("source") != source:
        return None, "inventory-source-mismatch"
    if repository is not None and value.get("repository") != repository:
        return None, "inventory-repository-mismatch"
    if value.get("read_complete") is not True:
        return None, "inventory-read-incomplete"
    if value.get("pagination_complete") is not True:
        return None, "inventory-pagination-incomplete"
    if value.get("has_next_page") is not False:
        return None, "inventory-has-next-page"
    records = value.get(records_field)
    if not isinstance(records, list) or not all(
        isinstance(record, dict) for record in records
    ):
        return None, "inventory-records-invalid"
    if value.get("count") != len(records):
        return None, "inventory-count-mismatch"
    return records, None


def target_identity(evidence: object) -> tuple[str, int, str] | None:
    """Return a complete repository/PR/head identity from live evidence."""
    if not isinstance(evidence, dict):
        return None
    repository = evidence.get("repository")
    pr = evidence.get("pr")
    if not isinstance(repository, dict) or not isinstance(pr, dict):
        return None
    name = repository.get("name_with_owner")
    number = pr.get("number")
    head = pr.get("head")
    if (
        not isinstance(name, str)
        or not name.strip()
        or not isinstance(number, int)
        or number <= 0
        or not isinstance(head, dict)
        or not isinstance(head.get("sha"), str)
        or not re.fullmatch(r"[0-9a-f]{40}", head["sha"])
    ):
        return None
    return name, number, head["sha"]


def validate_closing_pr_inventory(
    fixture: dict[str, object],
    open_issues: list[dict[str, object]],
    repository: str,
) -> str | None:
    """Require a complete, repository-bound closing-PR inventory for orphans.

    The issue's convenient ``closing_prs`` field is a live view, not proof that
    the connector followed every page of ``closingIssuesReferences``.  Queue
    selection must therefore stop when the companion inventory is absent or
    inconsistent.  An open closing PR can be adopted when the dedicated
    operation is configured; all other incomplete cases are wiring failures.
    """
    # The execution inventory is the complete issue universe.  The closing-PR
    # relationship inventory has a narrower contract: it contains one record
    # per non-empty relationship, while issues without a closing PR are
    # represented only by the complete execution inventory.  Keeping those
    # two sets separate allows a mixed open-issue response to remain
    # verifiable without treating an omitted empty relationship as a missing
    # record.
    expected: dict[int, list[int]] = {}
    for issue in open_issues:
        issue_number = issue.get("number")
        if not isinstance(issue_number, int):
            return "closing-pr-inventory-identity-mismatch"
        closing = issue.get("closing_prs")
        if not isinstance(closing, list):
            return "closing-pr-inventory-records-invalid"
        numbers: list[int] = []
        for pr in closing:
            if (
                not isinstance(pr, dict)
                or not isinstance(pr.get("number"), int)
                or pr.get("number", 0) <= 0
                or pr.get("repository") != repository
                or not isinstance(pr.get("state"), str)
                or not pr.get("state", "").strip()
            ):
                return "closing-pr-inventory-records-invalid"
            numbers.append(int(pr["number"]))
        if len(numbers) != len(set(numbers)):
            return "closing-pr-inventory-identity-mismatch"
        if numbers:
            expected[issue_number] = numbers

    inventory = fixture.get("closing_pr_inventory")
    normalized_inventory = inventory
    if isinstance(inventory, dict) and isinstance(inventory.get("records"), list):
        normalized_inventory = dict(inventory)
        normalized_inventory["records"] = [
            {"number": record} if isinstance(record, int) else record
            for record in inventory["records"]
        ]
    records, error = complete_inventory(
        normalized_inventory,
        source="repository-open-closing-pr-inventory-v1",
        repository=repository,
    )
    if error:
        return f"closing-pr-inventory-{error.removeprefix('inventory-')}"
    assert records is not None
    if not expected:
        # An empty relationship set is complete when every open issue has no
        # closing PR.  The inventory object is still mandatory; its omission
        # is a wiring failure handled above.
        return None if not records else "closing-pr-inventory-identity-mismatch"
    observed: dict[int, list[int]] = {}
    for record in records:
        issue_number = record.get("issue")
        pr_number = record.get("pr")
        if (
            not isinstance(issue_number, int)
            or issue_number <= 0
            or not isinstance(pr_number, int)
            or pr_number <= 0
        ):
            return "closing-pr-inventory-records-invalid"
        record_repository = record.get("repository")
        if record_repository != repository:
            return "closing-pr-inventory-repository-mismatch"
        observed.setdefault(issue_number, []).append(pr_number)
    if any(
        len(numbers) != len(set(numbers))
        or issue_number not in expected
        or sorted(numbers) != sorted(expected[issue_number])
        for issue_number, numbers in observed.items()
    ) or set(observed) != set(expected):
        return "closing-pr-inventory-identity-mismatch"
    return None


def validate_checks(
    evidence: dict[str, object],
    contract: dict[str, object],
    head_sha: str,
) -> str | None:
    identity = target_identity(evidence)
    repository_evidence = evidence.get("repository")
    issue_evidence = evidence.get("issue")
    pr_evidence = evidence.get("pr")
    if identity is None or not isinstance(issue_evidence, dict):
        return "checks-target-evidence-missing"
    assert isinstance(repository_evidence, dict)
    assert isinstance(issue_evidence, dict)
    assert isinstance(pr_evidence, dict)
    checks = evidence.get("checks")
    if not isinstance(checks, dict) or checks.get("read_complete") is not True:
        return "checks-read-incomplete"
    if checks.get("source") != "github-check-runs-v1":
        return "checks-source-mismatch"
    if (
        checks.get("repository") != repository_evidence.get("name_with_owner")
        or checks.get("pr") != pr_evidence.get("number")
    ):
        return "checks-target-mismatch"
    if checks.get("pagination_complete") is not True:
        return "checks-pagination-incomplete"
    if checks.get("has_next_page") is not False:
        return "checks-pagination-open"
    if checks.get("head_sha") != head_sha:
        return "checks-head-mismatch"
    records = checks.get("records")
    if not isinstance(records, list) or not all(
        isinstance(record, dict) for record in records
    ):
        return "checks-invalid"
    if checks.get("count") != len(records):
        return "checks-count-mismatch"
    required = contract.get("required_checks")
    if not isinstance(required, list):
        return "required-checks-invalid"
    required_names = {str(name) for name in required}
    names: list[str] = []
    workflow_ids: list[int] = []
    conclusions: dict[str, str] = {}
    pending_statuses = {"queued", "in_progress", "pending", "requested", "waiting"}
    for record in records:
        name = record.get("name")
        if not isinstance(name, str) or not name:
            return "check-name-invalid"
        status = record.get("status")
        conclusion = record.get("conclusion")
        # Contradictory check evidence is invalid even when the check is not
        # policy-required.  Incomplete third-party records stay informational.
        if isinstance(status, str) and (
            status.casefold() in pending_statuses and conclusion is not None
            or status.casefold() == "completed"
            and isinstance(conclusion, str)
            and conclusion.casefold() in pending_statuses
        ):
            return "check-status-conclusion-conflict"
        # Third-party runs remain visible in the complete inventory, while
        # provenance is required for policy-required checks only.
        if name not in required_names:
            continue
        names.append(name)
        if record.get("head_sha") != head_sha:
            return "check-head-mismatch"
        if record.get("source") != "github-actions":
            return "check-source-invalid"
        if not isinstance(record.get("workflow_run_id"), int):
            return "check-provenance-missing"
        workflow_ids.append(int(record["workflow_run_id"]))
        if not isinstance(status, str) or status.casefold() not in pending_statuses | {
            "completed"
        }:
            return "check-status-invalid"
        normalized_status = status.casefold()
        if normalized_status in pending_statuses:
            if conclusion is not None:
                return "check-status-conclusion-conflict"
            conclusions[name] = "pending"
            continue
        if not isinstance(conclusion, str):
            return "check-conclusion-invalid"
        normalized_conclusion = conclusion.casefold()
        if normalized_conclusion in pending_statuses:
            return "check-status-conclusion-conflict"
        conclusions[name] = normalized_conclusion
    if len(names) != len(set(names)) or len(workflow_ids) != len(set(workflow_ids)):
        return "duplicate-check-name"
    if any(conclusions.get(str(name)) != "success" for name in required):
        return "required-check-not-successful"
    return None


def validate_review(
    evidence: dict[str, object],
    contract: dict[str, object],
    head_sha: str,
) -> str | None:
    review = evidence.get("review")
    if not isinstance(review, dict):
        return "review-invalid"
    identity = target_identity(evidence)
    repository_evidence = evidence.get("repository")
    pr_evidence = evidence.get("pr")
    if identity is None:
        return "review-target-evidence-missing"
    assert isinstance(repository_evidence, dict)
    assert isinstance(pr_evidence, dict)
    if (
        review.get("repository") != repository_evidence.get("name_with_owner")
        or review.get("pr") != pr_evidence.get("number")
        or review.get("head_sha") != head_sha
    ):
        return "review-target-mismatch"
    try:
        head_updated_at = parse_timestamp(
            review.get("head_updated_at"), "review.head_updated_at"
        )
    except ValueError:
        return "review-head-timestamp-invalid"
    actors = contract.get("approved_plus_one_actors")
    if not isinstance(actors, list):
        return "approved-review-actors-invalid"
    approved = {str(actor) for actor in actors}
    automatic = review.get("automatic_reviews")
    reactions = review.get("reactions")
    collections = (
        (automatic, "github-pull-request-reviews-v1", "automatic-review"),
        (reactions, "github-pull-request-reactions-v1", "reaction"),
    )
    for collection, source, prefix in collections:
        records, error = complete_inventory(collection, source=source)
        if error:
            return f"{prefix}-{error}"
        assert records is not None and isinstance(collection, dict)
        if (
            collection.get("repository") != repository_evidence.get("name_with_owner")
            or collection.get("pr") != pr_evidence.get("number")
            or collection.get("head_sha") != head_sha
        ):
            return f"{prefix}-head-mismatch"
    assert isinstance(automatic, dict) and isinstance(reactions, dict)
    automatic_records = automatic["records"]
    reaction_records = reactions["records"]
    assert isinstance(automatic_records, list) and isinstance(reaction_records, list)
    automatic_ids: set[tuple[object, object, object]] = set()
    automatic_candidate = False
    for item in automatic_records:
        identity = (item.get("actor"), item.get("submitted_at"), item.get("reviewed_head_sha"))
        if identity in automatic_ids:
            return "automatic-review-duplicate"
        automatic_ids.add(identity)
        if (
            item.get("actor") in approved
            and item.get("reviewed_head_sha") == head_sha
            and str(item.get("state", "")).casefold()
            in {"approved", "commented"}
        ):
            finding_count = item.get("finding_count")
            if finding_count == 0:
                automatic_candidate = True
            elif finding_count is None and validate_findings(
                evidence, contract, head_sha
            ) is None:
                # The live REST review object has no finding_count.  A
                # complete current-head findings inventory is the independent
                # source of truth for the in-scope review gate.
                automatic_candidate = True
    reaction_ids: set[tuple[object, object, object]] = set()
    for item in reaction_records:
        identity = (item.get("actor"), item.get("created_at"), item.get("content"))
        if identity in reaction_ids:
            return "reaction-duplicate"
        reaction_ids.add(identity)
        if (
            item.get("content") != "+1"
            or item.get("actor") not in approved
            or item.get("head_sha") != head_sha
            or item.get("deleted") is not False
        ):
            continue
        try:
            created_at = parse_timestamp(
                item.get("created_at"), "review.reaction.created_at"
            )
        except ValueError:
            continue
        if created_at >= head_updated_at:
            automatic_candidate = True
    if automatic_candidate:
        return None
    return "current-head-review-missing"


def validate_findings(
    evidence: dict[str, object], contract: dict[str, object], head_sha: str
) -> str | None:
    findings = evidence.get("findings")
    if not isinstance(findings, dict):
        return "findings-invalid"
    identity = target_identity(evidence)
    repository_evidence = evidence.get("repository")
    pr_evidence = evidence.get("pr")
    if identity is None:
        return "findings-target-evidence-missing"
    assert isinstance(repository_evidence, dict)
    assert isinstance(pr_evidence, dict)
    if findings.get("source") != "current-head-review-findings-v1":
        return "findings-source-mismatch"
    if (
        findings.get("repository") != repository_evidence.get("name_with_owner")
        or findings.get("pr") != pr_evidence.get("number")
        or findings.get("head_sha") != head_sha
    ):
        return "findings-head-mismatch"
    if findings.get("read_complete") is not True:
        return "findings-read-incomplete"
    if findings.get("pagination_complete") is not True:
        return "findings-pagination-incomplete"
    if findings.get("has_next_page") is not False:
        return "findings-pagination-open"
    items = findings.get("items")
    if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
        return "findings-invalid"
    if findings.get("count") != len(items):
        return "findings-count-mismatch"
    terminal = contract.get("p2_terminal_dispositions")
    if not isinstance(terminal, list):
        return "finding-dispositions-invalid"
    terminal_set = {str(item) for item in terminal}
    identities: set[tuple[str, str, str]] = set()
    for item in items:
        if any(
            not isinstance(item.get(field), str) or not str(item[field]).strip()
            for field in ("id", "source_id", "head_sha")
        ):
            return "finding-identity-incomplete"
        if item.get("head_sha") != head_sha:
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
        disposition = item.get("disposition")
        if severity in {"P0", "P1"}:
            return "p0-p1-finding-remains"
        if severity == "P3":
            continue
        if severity != "P2" or disposition not in terminal_set:
            return "finding-disposition-incomplete"
        owner = item.get("owner")
        if not isinstance(owner, str) or not owner.strip():
            return "finding-owner-missing"
        if disposition == "defer-follow-up":
            follow_up = item.get("follow_up_issue")
            authority = item.get("follow_up_creation_authority")
            if not (
                type(follow_up) is int and follow_up > 0
                or (isinstance(authority, str) and authority.strip())
            ):
                return "follow-up-owner-incomplete"
        elif disposition in {
            "already-addressed",
            "residual-risk",
            "reject-out-of-scope",
        }:
            rationale = item.get("rationale")
            if not isinstance(rationale, str) or not rationale.strip():
                return "finding-rationale-missing"
    return None


def validate_writers(
    fixture: dict[str, object],
    evidence: dict[str, object],
    contract: dict[str, object],
) -> str | None:
    writer_contract = contract.get("writer_inventory")
    if not isinstance(writer_contract, dict):
        return "writer-contract-invalid"
    source = writer_contract.get("source")
    if not isinstance(source, str):
        return "writer-contract-invalid"
    writers = evidence.get("writers")
    identity = target_identity(evidence)
    repository_evidence = evidence.get("repository")
    pr_evidence = evidence.get("pr")
    if identity is None:
        return "writer-target-evidence-missing"
    assert isinstance(repository_evidence, dict)
    assert isinstance(pr_evidence, dict)
    records, error = complete_inventory(writers, source=source)
    if error:
        return f"writer-{error}"
    assert records is not None and isinstance(writers, dict)
    authorization = fixture.get("authorization")
    if not isinstance(authorization, dict):
        return "authorization-invalid"
    head = pr_evidence.get("head")
    if not isinstance(head, dict):
        return "authorization-head-invalid"
    if (
        writers.get("repository") != repository_evidence.get("name_with_owner")
        or writers.get("pr") != pr_evidence.get("number")
        or writers.get("head_sha") != head.get("sha")
    ):
        return "writer-target-mismatch"
    token = writers.get("cas_token")
    if not isinstance(token, str) or not token.strip():
        return "writer-cas-missing"
    operation = fixture.get("operation")
    if not isinstance(operation, dict):
        return "operation-invalid"
    allowed_kinds = writer_contract.get("kinds")
    if not isinstance(allowed_kinds, list):
        return "writer-contract-invalid"
    try:
        now = parse_timestamp(fixture.get("now"), "fixture.now")
    except ValueError:
        return "writer-observation-invalid"
    try:
        observed_at = parse_timestamp(writers.get("observed_at"), "writers.observed_at")
    except ValueError:
        return "writer-observation-invalid"
    if observed_at != now:
        return "writer-observation-stale"
    active_records: list[dict[str, object]] = []
    for record in records:
        required = (
            "kind",
            "repository",
            "issue",
            "pr",
            "run_id",
            "owner",
            "lease_expires_at",
            "head_sha",
        )
        if any(field not in record for field in required):
            return "writer-record-incomplete"
        if record.get("kind") not in allowed_kinds:
            return "writer-kind-invalid"
        try:
            expires_at = parse_timestamp(
                record.get("lease_expires_at"), "writer.lease_expires_at"
            )
        except ValueError:
            return "writer-lease-invalid"
        if expires_at <= now:
            continue
        active_records.append(record)

    if any(record.get("kind") != "adoption" for record in active_records):
        return "active-writer"

    adoption_records = [
        record for record in active_records if record.get("kind") == "adoption"
    ]
    if not adoption_records:
        return None

    source_ids: set[int] = set()
    for record in adoption_records:
        source_id = record.get("source_comment_id")
        if type(source_id) is not int or source_id <= 0:
            return "writer-adoption-source-invalid"
        if source_id in source_ids:
            return "writer-adoption-source-duplicate"
        source_ids.add(source_id)

    # GitHub issue-comment IDs are server-assigned and monotonically ordered.
    # Requiring one acquisition-only round trip means concurrent contenders
    # are all visible before any ledger write; the earliest trusted lease wins
    # and later contenders stop without stranding the winner.
    winner = min(adoption_records, key=lambda record: int(record["source_comment_id"]))
    if not (
        winner.get("run_id") == operation.get("run_id")
        and winner.get("owner") == operation.get("owner")
        and winner.get("repository") == fixture.get("repository")
        and winner.get("issue") == authorization.get("issue")
        and winner.get("pr") == authorization.get("pr")
        and winner.get("head_sha") == head.get("sha")
    ):
        return "active-writer"
    return None


def validate_dependent_inventory(
    evidence: dict[str, object], contract: dict[str, object]
) -> str | None:
    dependent_contract = contract.get("dependent_pr_inventory")
    if not isinstance(dependent_contract, dict):
        return "dependent-pr-contract-invalid"
    source = dependent_contract.get("source")
    if not isinstance(source, str):
        return "dependent-pr-contract-invalid"
    identity = target_identity(evidence)
    repository_evidence = evidence.get("repository")
    pr_evidence = evidence.get("pr")
    if identity is None:
        return "dependent-pr-target-evidence-missing"
    assert isinstance(repository_evidence, dict)
    assert isinstance(pr_evidence, dict)
    dependent = evidence.get("dependent_prs")
    records, error = complete_inventory(dependent, source=source)
    if error:
        return f"dependent-pr-{error}"
    assert records is not None and isinstance(dependent, dict)
    head = pr_evidence.get("head")
    if not isinstance(head, dict) or (
        dependent.get("repository") != repository_evidence.get("name_with_owner")
        or dependent.get("pr") != pr_evidence.get("number")
        or dependent.get("head_sha") != head.get("sha")
    ):
        return "dependent-pr-target-mismatch"
    seen_numbers: set[int] = set()
    repository = repository_evidence.get("name_with_owner")
    for record in records:
        if not all(
            field in record
            for field in (
                "number",
                "state",
                "repository",
                "base_ref",
                "base_sha",
                "head_ref",
                "head_sha",
            )
        ):
            return "dependent-pr-record-incomplete"
        number = record.get("number")
        if (
            not isinstance(number, int)
            or number <= 0
            or number in seen_numbers
            or record.get("repository") != repository
            or not isinstance(record.get("state"), str)
            or record.get("state") != "OPEN"
            or not isinstance(record.get("base_ref"), str)
            or not record.get("base_ref", "").strip()
            or not isinstance(record.get("head_ref"), str)
            or not record.get("head_ref", "").strip()
            or not isinstance(record.get("base_sha"), str)
            or not re.fullmatch(r"[0-9a-f]{40}", record["base_sha"])
            or not isinstance(record.get("head_sha"), str)
            or not re.fullmatch(r"[0-9a-f]{40}", record["head_sha"])
        ):
            return "dependent-pr-record-identity-invalid"
        seen_numbers.add(number)
    return None


def validate_ledger(
    fixture: dict[str, object],
    contract: dict[str, object],
    head_sha: str,
    evidence_digest: str,
) -> tuple[list[dict[str, object]] | None, str | None]:
    ledger = fixture.get("ledger")
    if not isinstance(ledger, dict):
        return None, "ledger-missing"
    if ledger.get("read_complete") is not True:
        return None, "ledger-read-incomplete"
    if ledger.get("pagination_complete") is not True:
        return None, "ledger-pagination-incomplete"
    if ledger.get("has_next_page") is not False:
        return None, "ledger-has-next-page"
    comments = ledger.get("comments")
    if not isinstance(comments, list) or not all(
        isinstance(comment, dict) for comment in comments
    ):
        return None, "ledger-comments-invalid"
    ledger_contract = contract.get("ledger")
    operation = fixture.get("operation")
    authorization = fixture.get("authorization")
    if not isinstance(ledger_contract, dict) or not isinstance(operation, dict):
        return None, "ledger-contract-invalid"
    if not isinstance(authorization, dict):
        return None, "authorization-invalid"
    phases = ledger_contract.get("phases")
    authors = ledger_contract.get("approved_authors")
    if not isinstance(phases, list) or not isinstance(authors, list):
        return None, "ledger-contract-invalid"
    approved_authors = {str(author) for author in authors}
    terminal_history = ledger_contract.get("terminal_history")
    if terminal_history != {
        "classification": "manually-reconciled-old-head",
        "phases": ["prepared", "label-mutation"],
        "require_head_change": True,
    }:
        return None, "ledger-contract-invalid"
    required = (
        "comment_id",
        "author",
        "marker",
        "namespace",
        "run_id",
        "phase",
        "repository",
        "issue",
        "pr",
        "head_sha",
        "evidence_digest",
        "prepared_document",
        "prepared_document_digest",
    )
    comment_ids: set[int] = set()
    for comment in comments:
        if any(field not in comment for field in required):
            return None, "ledger-record-incomplete"
        comment_id = comment.get("comment_id")
        if not isinstance(comment_id, int) or comment_id in comment_ids:
            return None, "ledger-comment-id-invalid"
        comment_ids.add(comment_id)

    # A successful stale-label compensation intentionally leaves the old
    # prepared and label-mutation comments as immutable audit history.  Once
    # that old head is no longer current, validate the history against its own
    # embedded prepared document, then let only the fresh run drive progress.
    # Any extra phase, mixed identity, or incomplete document remains blocking.
    current_run_id = operation.get("run_id")
    active_comments = [
        comment for comment in comments if comment.get("run_id") == current_run_id
    ]
    historical_by_run: dict[str, list[dict[str, object]]] = {}
    for comment in comments:
        run_id = comment.get("run_id")
        if run_id == current_run_id:
            continue
        if not isinstance(run_id, str) or not run_id.strip():
            return None, "ledger-history-run-invalid"
        historical_by_run.setdefault(run_id, []).append(comment)

    live = fixture.get("live")
    if historical_by_run and not active_comments and (
        not isinstance(live, dict)
        or live.get("lifecycle_state") != contract.get("from_state")
    ):
        return None, "ledger-history-live-state-mismatch"
    historical_phases = set(terminal_history["phases"])
    for run_comments in historical_by_run.values():
        accepted_history_by_phase: dict[str, dict[str, object]] = {}
        history_identity: tuple[object, ...] | None = None
        for comment in run_comments:
            phase = comment.get("phase")
            if (
                phase not in phases
                or comment.get("author") not in approved_authors
                or comment.get("marker") != ledger_contract.get("marker")
                or comment.get("namespace") != ledger_contract.get("namespace")
                or comment.get("repository") != fixture.get("repository")
                or comment.get("issue") != authorization.get("issue")
                or comment.get("pr") != authorization.get("pr")
                or comment.get("head_sha") == head_sha
            ):
                return None, "ledger-history-record-mismatch"
            document = comment.get("prepared_document")
            if not isinstance(document, dict):
                return None, "ledger-history-document-invalid"
            if document.get("schema") != "rpm-existing-pr-adoption-prepared-v1":
                return None, "ledger-history-document-invalid"
            if comment.get("prepared_document_digest") != canonical_digest(document):
                return None, "ledger-history-document-digest-mismatch"
            document_authorization = document.get("authorization")
            document_evidence = document.get("evidence")
            if not isinstance(document_authorization, dict) or not isinstance(
                document_evidence, dict
            ):
                return None, "ledger-history-document-invalid"
            document_head = document_authorization.get("head")
            document_digest = adoption_evidence_digest(document_evidence)
            if (
                not isinstance(document_head, dict)
                or document_authorization.get("repository")
                != comment.get("repository")
                or document_authorization.get("issue") != comment.get("issue")
                or document_authorization.get("pr") != comment.get("pr")
                or document_head.get("sha") != comment.get("head_sha")
                or document_authorization.get("evidence_digest") != document_digest
                or comment.get("evidence_digest") != document_digest
            ):
                return None, "ledger-history-document-mismatch"
            identity = (
                comment.get("run_id"),
                comment.get("repository"),
                comment.get("issue"),
                comment.get("pr"),
                comment.get("head_sha"),
                comment.get("evidence_digest"),
                canonical_digest(
                    {
                        "schema": document.get("schema"),
                        "authorization": immutable_adoption_authorization(
                            document_authorization
                        ),
                        "evidence": adoption_evidence(document_evidence),
                    }
                ),
            )
            if history_identity is None:
                history_identity = identity
            elif history_identity != identity:
                return None, "ledger-history-identity-ambiguous"
            phase_name = str(phase)
            prior = accepted_history_by_phase.get(phase_name)
            if prior is not None:
                if canonical_digest(
                    comparable_ledger_comment(prior)
                ) != canonical_digest(comparable_ledger_comment(comment)):
                    return None, "ledger-history-phase-ambiguous"
                if int(comment["comment_id"]) < int(prior["comment_id"]):
                    accepted_history_by_phase[phase_name] = comment
            else:
                accepted_history_by_phase[phase_name] = comment
        if set(accepted_history_by_phase) != historical_phases:
            return None, "ledger-history-not-terminal"

    comments = active_comments
    accepted_by_phase: dict[str, dict[str, object]] = {}
    for comment in comments:
        phase = comment.get("phase")
        if phase not in phases:
            return None, "ledger-phase-invalid"
        if (
            comment.get("author") not in approved_authors
            or comment.get("marker") != ledger_contract.get("marker")
            or comment.get("namespace") != ledger_contract.get("namespace")
            or comment.get("run_id") != operation.get("run_id")
            or comment.get("repository") != fixture.get("repository")
            or comment.get("issue") != authorization.get("issue")
            or comment.get("pr") != authorization.get("pr")
            or comment.get("head_sha") != head_sha
            or comment.get("evidence_digest") != evidence_digest
        ):
            return None, "ledger-record-mismatch"
        document = comment.get("prepared_document")
        if not isinstance(document, dict):
            return None, "ledger-prepared-document-invalid"
        if document.get("schema") != "rpm-existing-pr-adoption-prepared-v1":
            return None, "ledger-prepared-document-schema-mismatch"
        if comment.get("prepared_document_digest") != canonical_digest(document):
            return None, "ledger-prepared-document-digest-mismatch"
        if immutable_adoption_authorization(
            document.get("authorization")
        ) != immutable_adoption_authorization(authorization):
            return None, "ledger-prepared-document-mismatch"
        if canonical_digest(
            adoption_evidence(document.get("evidence"))
        ) != canonical_digest(adoption_evidence(fixture.get("evidence"))):
            return None, "ledger-prepared-document-mismatch"
        phase_name = str(phase)
        prior = accepted_by_phase.get(phase_name)
        if prior is not None:
            comparable_prior = comparable_ledger_comment(prior)
            comparable_comment = comparable_ledger_comment(comment)
            if canonical_digest(comparable_prior) != canonical_digest(
                comparable_comment
            ):
                return None, "ledger-phase-ambiguous"
            if int(comment["comment_id"]) < int(prior["comment_id"]):
                accepted_by_phase[phase_name] = comment
        else:
            accepted_by_phase[phase_name] = comment
    deduplicated = sorted(
        accepted_by_phase.values(), key=lambda comment: int(comment["comment_id"])
    )
    present = {str(comment.get("phase")) for comment in deduplicated}
    if "label-mutation" in present and "prepared" not in present:
        return None, "ledger-phase-gap"
    if "committed" in present and not {"prepared", "label-mutation"} <= present:
        return None, "ledger-phase-gap"
    if "reconciled" in present and not {
        "prepared",
        "label-mutation",
        "committed",
    } <= present:
        return None, "ledger-phase-gap"
    return deduplicated, None


def ledger_action(
    fixture: dict[str, object],
    contract: dict[str, object],
    phase: str,
    digest: str,
) -> dict[str, object]:
    authorization = fixture["authorization"]
    operation = fixture["operation"]
    assert isinstance(authorization, dict) and isinstance(operation, dict)
    head = authorization["head"]
    assert isinstance(head, dict)
    document = {
        "schema": "rpm-existing-pr-adoption-prepared-v1",
        "authorization": authorization,
        "evidence": fixture["evidence"],
    }
    ledger = contract["ledger"]
    assert isinstance(ledger, dict)
    return {
        "author": list(ledger["approved_authors"])[0],
        "marker": ledger["marker"],
        "namespace": ledger["namespace"],
        "run_id": operation["run_id"],
        "phase": phase,
        "repository": authorization["repository"],
        "issue": authorization["issue"],
        "pr": authorization["pr"],
        "head_sha": head["sha"],
        "evidence_digest": digest,
        "prepared_document": document,
        "prepared_document_digest": canonical_digest(document),
    }


def adoption_mutation_request(
    fixture: dict[str, object],
    contract: dict[str, object],
    record: dict[str, object],
    ordinary: list[str],
    digest: str,
    target_label: str,
) -> dict[str, object]:
    authorization = fixture["authorization"]
    operation = fixture["operation"]
    assert isinstance(authorization, dict) and isinstance(operation, dict)
    adoption_input = json.loads(json.dumps(fixture))
    return {
        "role": contract["owner"],
        "operation": "add-lifecycle-label",
        "repository": authorization["repository"],
        "issue": authorization["issue"],
        "pr": authorization["pr"],
        "label": target_label,
        "before": contract["from_state"],
        "after": contract["to_state"],
        "mode": "add-only",
        "expected_current_labels": ordinary,
        "run_id": operation["run_id"],
        "evidence_digest": digest,
        "ledger_phase": "label-mutation",
        "prepared_record": record,
        "adoption_input": adoption_input,
        "adoption_input_digest": canonical_digest(adoption_input),
    }


def adopt_existing_pr(
    fixture: dict[str, object], policy: dict[str, object]
) -> dict[str, object]:
    contract = adoption_contract(policy)
    if contract is None:
        return blocked("adoption-contract-missing")
    operation = fixture.get("operation")
    authorization = fixture.get("authorization")
    evidence = fixture.get("evidence")
    live = fixture.get("live")
    if not all(isinstance(value, dict) for value in (operation, authorization, evidence, live)):
        return blocked("adoption-input-invalid")
    assert isinstance(operation, dict)
    assert isinstance(authorization, dict)
    assert isinstance(evidence, dict)
    assert isinstance(live, dict)
    if contract.get("approval_identity_fields") != [
        "repository",
        "issue",
        "pr",
        "base_repository",
        "base_ref",
        "base_sha",
        "head_repository",
        "head_ref",
        "head_sha",
        "evidence_digest",
    ]:
        return blocked("approval-identity-contract-invalid")
    if (
        fixture.get("repository") != policy.get("repository")
        or operation.get("name") != contract.get("operation")
        or operation.get("version") != contract.get("operation_version")
        or operation.get("policy_version") != policy.get("version")
        or operation.get("owner") != contract.get("owner")
        or operation.get("batch_limit") != contract.get("batch_limit")
        or not isinstance(operation.get("run_id"), str)
        or not str(operation.get("run_id")).strip()
    ):
        return blocked("operation-mismatch")
    # The live observation may contain the authorized review-pending label;
    # its immutable prepared evidence digest intentionally excludes that one
    # lifecycle delta.
    digest = adoption_evidence_digest(evidence)
    if authorization.get("evidence_digest") != digest:
        return blocked("evidence-digest-mismatch")
    if not SHA256.fullmatch(str(authorization.get("scope_hash", ""))):
        return blocked("scope-hash-invalid")
    required_text = ("approval_id", "plan_revision", "executor")
    if any(
        not isinstance(authorization.get(field), str)
        or not str(authorization.get(field)).strip()
        for field in required_text
    ):
        return blocked("authorization-field-missing")
    repository_evidence = evidence.get("repository")
    issue = evidence.get("issue")
    pr = evidence.get("pr")
    execution = evidence.get("execution")
    if not all(
        isinstance(value, dict)
        for value in (repository_evidence, issue, pr, execution)
    ):
        return blocked("identity-evidence-invalid")
    assert isinstance(repository_evidence, dict)
    assert isinstance(issue, dict)
    assert isinstance(pr, dict)
    assert isinstance(execution, dict)
    ledger_contract = contract.get("ledger")
    approved_execution_actors = (
        ledger_contract.get("approved_authors")
        if isinstance(ledger_contract, dict)
        else None
    )
    if (
        execution.get("source") != "github-approved-workflow-comment-v1"
        or not isinstance(approved_execution_actors, list)
        or execution.get("source_actor")
        not in {str(actor) for actor in approved_execution_actors}
    ):
        return blocked("execution-authorization-source-untrusted")
    if (
        execution.get("repository") != fixture.get("repository")
        or execution.get("issue") != issue.get("number")
        or execution.get("pr") != pr.get("number")
        or not isinstance(pr.get("base"), dict)
        or not isinstance(pr.get("head"), dict)
        or execution.get("base_repository") != pr.get("base", {}).get("repository")
        or execution.get("base_ref") != pr.get("base", {}).get("ref")
        or execution.get("base_sha") != pr.get("base", {}).get("sha")
        or execution.get("head_repository") != pr.get("head", {}).get("repository")
        or execution.get("head_ref") != pr.get("head", {}).get("ref")
        or execution.get("head_sha") != pr.get("head", {}).get("sha")
        or execution.get("evidence_digest") != digest
        or execution.get("policy_version") != policy.get("version")
        or execution.get("operation_version") != contract.get("operation_version")
    ):
        return blocked("execution-authorization-unbound")
    canonical_closing = pr.get("closing_issues")
    if not isinstance(canonical_closing, list) or not all(
        isinstance(value, dict) for value in canonical_closing
    ):
        return blocked("closing-issues-invalid")
    expected_authorization = {
        "repository": fixture.get("repository"),
        "issue": issue.get("number"),
        "pr": pr.get("number"),
        "base": pr.get("base"),
        "head": pr.get("head"),
        "closing_issues": canonical_closing,
        "policy_version": policy.get("version"),
        "operation_version": contract.get("operation_version"),
        "evidence_digest": digest,
        "approval_id": execution.get("approval_id"),
        "plan_revision": execution.get("plan_revision"),
        "scope_hash": execution.get("scope_hash"),
        "executor": execution.get("executor"),
        "observation_time": (
            evidence.get("writers", {}).get("observed_at")
            if isinstance(evidence.get("writers"), dict)
            else None
        ),
    }
    if authorization != expected_authorization:
        return blocked("authorization-mismatch")
    if (
        repository_evidence.get("name_with_owner") != fixture.get("repository")
        or repository_evidence.get("read_complete") is not True
        or issue.get("repository") != fixture.get("repository")
        or pr.get("repository") != fixture.get("repository")
        or str(issue.get("state", "")).casefold() != "open"
        or str(pr.get("state", "")).casefold() != "open"
        or pr.get("is_draft") is not False
        or issue.get("closing_prs_complete") is not True
        or pr.get("closing_issues_complete") is not True
        or issue.get("closing_prs") != [pr.get("number")]
        or len(canonical_closing) != 1
        or canonical_closing
        != [{"repository": fixture.get("repository"), "number": issue.get("number")}]
    ):
        return blocked("live-identity-ambiguous")
    base = pr.get("base")
    head = pr.get("head")
    if not isinstance(base, dict) or not isinstance(head, dict):
        return blocked("ref-identity-invalid")
    if (
        base.get("repository") != fixture.get("repository")
        or not isinstance(head.get("repository"), str)
        or REPOSITORY.fullmatch(str(head.get("repository"))) is None
        or not isinstance(base.get("ref"), str)
        or not isinstance(head.get("ref"), str)
        or not re.fullmatch(r"[0-9a-f]{40}", str(base.get("sha", "")))
        or not re.fullmatch(r"[0-9a-f]{40}", str(head.get("sha", "")))
    ):
        return blocked("ref-identity-invalid")
    current_state = issue.get("lifecycle_state")
    if current_state not in {
        contract.get("from_state"),
        contract.get("to_state"),
    }:
        return blocked("issue-not-untracked")
    if (
        live.get("head_sha") != head.get("sha")
        or live.get("base_sha") != base.get("sha")
        or live.get("lifecycle_state")
        not in {contract.get("from_state"), contract.get("to_state")}
    ):
        return blocked("live-cas-mismatch")
    labels = issue.get("labels")
    live_labels = live.get("issue_labels")
    if not isinstance(labels, list) or not isinstance(live_labels, list):
        return blocked("label-evidence-invalid")
    lifecycle = lifecycle_labels(policy)
    lifecycle_values = set(lifecycle.values())
    present_lifecycle = sorted(
        str(label) for label in labels if str(label) in lifecycle_values
    )
    expected_lifecycle = (
        [str(lifecycle[str(contract.get("to_state"))])]
        if current_state == contract.get("to_state")
        else []
    )
    if present_lifecycle != expected_lifecycle:
        return blocked("label-evidence-invalid")
    ordinary = sorted(
        str(label) for label in labels if str(label) not in lifecycle_values
    )
    expected_live = (
        sorted([*ordinary, lifecycle[str(contract.get("to_state"))]])
        if live.get("lifecycle_state") == contract.get("to_state")
        else sorted(str(label) for label in labels)
    )
    if sorted(str(label) for label in live_labels) != expected_live:
        return blocked("label-cas-mismatch")
    for validator in (
        lambda: validate_checks(evidence, contract, str(head.get("sha"))),
        lambda: validate_review(evidence, contract, str(head.get("sha"))),
        lambda: validate_findings(evidence, contract, str(head.get("sha"))),
        lambda: validate_writers(fixture, evidence, contract),
        lambda: validate_dependent_inventory(evidence, contract),
    ):
        error = validator()
        if error:
            return blocked(error)
    comments, ledger_error = validate_ledger(
        fixture, contract, str(head.get("sha")), digest
    )
    if ledger_error:
        return blocked(ledger_error)
    assert comments is not None
    phases = {str(comment.get("phase")) for comment in comments}
    adopted = live.get("lifecycle_state") == contract.get("to_state")
    common: dict[str, object] = {
        "issue": issue.get("number"),
        "pr": pr.get("number"),
        "before": contract.get("from_state"),
        "after": contract.get("to_state"),
        "preserved_labels": ordinary,
        "evidence_digest": digest,
        "project_inventory": (
            "unavailable-independent"
            if isinstance(fixture.get("project_inventory"), dict)
            and dict(fixture["project_inventory"]).get("read_status") == "failed"
            else "available-independent"
        ),
    }
    if "reconciled" in phases and adopted:
        return {"status": "reconciled", "phase": "reconciled", **common}
    if "reconciled" in phases or ("committed" in phases and not adopted):
        return blocked("ledger-live-state-mismatch")
    if adopted and "label-mutation" not in phases:
        # A live review-pending label without the durable label-mutation
        # ledger phase is an externally advanced or partially observed
        # lifecycle.  Treat it as a wiring conflict.  In particular, a
        # prepared-only ledger must never manufacture a committed result or
        # authorize another mutation from the already-present label.
        return blocked("wiring-blocked")
    if "committed" in phases and adopted:
        return {
            "status": "reconciled",
            "phase": "reconciled",
            **common,
            "ledger_action": ledger_action(fixture, contract, "reconciled", digest),
        }
    if adopted:
        return {
            "status": "adopt",
            "phase": "committed",
            **common,
            "ledger_action": ledger_action(fixture, contract, "committed", digest),
        }
    if "label-mutation" in phases:
        record = next(
            comment for comment in comments if comment.get("phase") == "label-mutation"
        )
        return {
            "status": "adopt",
            "phase": "label-mutation",
            **common,
            "mutation_request": adoption_mutation_request(
                fixture,
                contract,
                record,
                ordinary,
                digest,
                lifecycle[str(contract.get("to_state"))],
            ),
        }
    phase = "label-mutation" if "prepared" in phases else "prepared"
    result = {
        "status": "adopt",
        "phase": phase,
        **common,
        "ledger_action": ledger_action(fixture, contract, phase, digest),
    }
    return result


def validate_lifecycle(
    fixture: dict[str, object], policy: dict[str, object]
) -> dict[str, object]:
    contract = policy.get("lifecycle_contract")
    if not isinstance(contract, dict):
        return blocked("lifecycle-contract-missing")
    for field in ("initial_states", "safe_stop_states", "external_terminal_states"):
        if contract.get(field) != fixture.get(field):
            return blocked(f"lifecycle-{field}-mismatch")
    allowed = policy.get("allowed_transitions")
    edge_fixtures = contract.get("edge_fixtures")
    if not isinstance(allowed, dict) or not isinstance(edge_fixtures, dict):
        return blocked("lifecycle-edges-invalid")
    generic_edges = {
        f"{source}->{target}"
        for source, targets in allowed.items()
        if isinstance(targets, list)
        for target in targets
    }
    if set(fixture.get("generic_edges", [])) != generic_edges:
        return blocked("generic-edge-set-mismatch")
    if set(edge_fixtures) != generic_edges:
        return blocked("edge-fixture-missing")
    expected_descriptor = {
        "path": "tests/fixtures/agent-workflow/lifecycle-edges.json",
    }
    if any(
        not isinstance(descriptor, dict)
        or descriptor.get("path") != expected_descriptor["path"]
        or descriptor.get("case") != edge
        or not (ROOT / str(descriptor.get("path"))).is_file()
        for edge, descriptor in edge_fixtures.items()
    ):
        return blocked("edge-fixture-not-executable")
    edge_cases = fixture.get("edge_cases")
    if not isinstance(edge_cases, list) or not all(
        isinstance(case, dict) for case in edge_cases
    ):
        return blocked("edge-cases-invalid")
    cases_by_id = {str(case.get("id")): case for case in edge_cases}
    if len(cases_by_id) != len(edge_cases) or set(cases_by_id) != generic_edges:
        return blocked("edge-case-set-mismatch")
    for edge, case in cases_by_id.items():
        source, target = edge.split("->", 1)
        if case != {
            "id": edge,
            "source": source,
            "target": target,
            "verdict": "allowed",
        }:
            return blocked("edge-case-execution-mismatch", edge=edge)
    operations = fixture.get("dedicated_operations")
    operation_fixtures = contract.get("operation_fixtures")
    if not isinstance(operations, list) or not isinstance(operation_fixtures, dict):
        return blocked("operation-fixtures-invalid")
    expected_operations = {
        str(item.get("name")): str(item.get("name"))
        for item in operations
        if isinstance(item, dict)
    }
    if operation_fixtures != expected_operations:
        return blocked("operation-fixture-mismatch")
    states = {"untracked", *[str(state) for state in lifecycle_labels(policy)]}
    initial = {str(state) for state in contract.get("initial_states", [])}
    safe = {str(state) for state in contract.get("safe_stop_states", [])}
    edges: dict[str, set[str]] = {state: set() for state in states}
    incoming: dict[str, set[str]] = {state: set() for state in states}
    for raw in generic_edges:
        source, target = raw.split("->", 1)
        if source not in states or target not in states:
            return blocked("edge-state-unknown")
        edges[source].add(target)
        incoming[target].add(source)
    for item in operations:
        if not isinstance(item, dict):
            return blocked("operation-edge-invalid")
        source = str(item.get("from"))
        target = str(item.get("to"))
        if source not in states or target not in states:
            return blocked("operation-edge-state-unknown")
        edges[source].add(target)
        incoming[target].add(source)
    for state in states:
        if state not in initial and not incoming[state]:
            return blocked("lifecycle-state-has-no-incoming-edge", state=state)
        if state not in safe and not edges[state]:
            return blocked("lifecycle-state-has-no-outgoing-edge", state=state)
        seen: set[str] = set()
        pending = [state]
        reachable_safe = False
        while pending:
            current = pending.pop()
            if current in seen:
                continue
            seen.add(current)
            if current in safe:
                reachable_safe = True
                break
            pending.extend(edges.get(current, set()) - seen)
        if not reachable_safe:
            return blocked("lifecycle-state-cannot-reach-safe-stop", state=state)
    return {"status": "valid", "states": sorted(states), "edges": sorted(generic_edges)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", default=".agents/workflows/backlog-policy.json")
    parser.add_argument("--issues-file", required=True)
    parser.add_argument(
        "--operation",
        required=True,
        choices=(
            "select-execution",
            "select-review",
            "transition",
            "claim",
            "adopt-existing-pr",
            "validate-lifecycle",
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
    args = parser.parse_args()

    policy = load_json(args.policy)
    fixture = load_json(args.issues_file)
    lifecycle = lifecycle_labels(policy)
    contract = execution_contract(policy)
    if args.operation == "select-execution":
        limit = int(dict(policy["batch_limits"])["execution"])
        result = select_execution(fixture, lifecycle, contract, limit, policy)
    elif args.operation == "select-review":
        result = select_review(fixture, lifecycle)
    elif args.operation == "adopt-existing-pr":
        result = adopt_existing_pr(fixture, policy)
    elif args.operation == "validate-lifecycle":
        result = validate_lifecycle(fixture, policy)
    elif args.operation == "transition":
        if args.issue is None or args.from_state is None or args.to_state is None:
            parser.error("transition requires --issue, --from-state, and --to-state")
        result = transition(
            fixture,
            lifecycle,
            policy,
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
