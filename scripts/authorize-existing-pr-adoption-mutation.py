#!/usr/bin/env python3
"""Authorize the one add-only lifecycle mutation used by PR adoption."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import runpy
from pathlib import Path


SHA256 = re.compile(r"sha256:[0-9a-f]{64}")
ROOT = Path(__file__).resolve().parents[1]
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


def load_object(path: str) -> dict[str, object]:
    value = json.loads(Path(path).read_text())
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def blocked(reason: str) -> dict[str, object]:
    return {"status": "blocked", "reason": reason}


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


def adoption_evidence_digest(value: object) -> str:
    """Digest immutable evidence while ignoring the authorized label delta."""
    normalized = json.loads(json.dumps(value))
    if isinstance(normalized, dict):
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
        if isinstance(writers, dict) and "observed_at" in writers:
            writers["observed_at"] = "<observation-time>"
    return canonical_digest(normalized)


def validate_prepared_record(
    policy: dict[str, object],
    contract: dict[str, object],
    request: dict[str, object],
) -> tuple[dict[str, object] | None, dict[str, object] | None, str | None]:
    record = request.get("prepared_record")
    ledger = contract.get("ledger")
    if not isinstance(record, dict) or not isinstance(ledger, dict):
        return None, None, "prepared-record-missing"
    document = record.get("prepared_document")
    if not isinstance(document, dict):
        return None, None, "prepared-document-missing"
    if document.get("schema") != "rpm-existing-pr-adoption-prepared-v1":
        return None, None, "prepared-document-schema-mismatch"
    document_digest = record.get("prepared_document_digest")
    if (
        not isinstance(document_digest, str)
        or not SHA256.fullmatch(document_digest)
        or document_digest != canonical_digest(document)
    ):
        return None, None, "prepared-document-digest-mismatch"
    authorization = document.get("authorization")
    evidence = document.get("evidence")
    if not isinstance(authorization, dict) or not isinstance(evidence, dict):
        return None, None, "prepared-document-invalid"
    evidence_digest = authorization.get("evidence_digest")
    if (
        not isinstance(evidence_digest, str)
        or not SHA256.fullmatch(evidence_digest)
        or evidence_digest != adoption_evidence_digest(evidence)
    ):
        return None, None, "prepared-evidence-digest-mismatch"

    repository = evidence.get("repository")
    issue = evidence.get("issue")
    pr = evidence.get("pr")
    execution = evidence.get("execution")
    if not all(
        isinstance(value, dict)
        for value in (repository, issue, pr, execution)
    ):
        return None, None, "prepared-identity-evidence-invalid"
    assert isinstance(repository, dict)
    assert isinstance(issue, dict)
    assert isinstance(pr, dict)
    assert isinstance(execution, dict)
    writers = evidence.get("writers")
    if not isinstance(writers, dict):
        return None, None, "prepared-writer-evidence-invalid"
    observation_time = writers.get("observed_at")
    if not isinstance(observation_time, str) or not observation_time.strip():
        return None, None, "prepared-observation-time-missing"
    expected_authorization = {
        "repository": policy.get("repository"),
        "issue": issue.get("number"),
        "pr": pr.get("number"),
        "base": pr.get("base"),
        "head": pr.get("head"),
        "closing_issues": pr.get("closing_issues"),
        "policy_version": policy.get("version"),
        "operation_version": contract.get("operation_version"),
        "evidence_digest": evidence_digest,
        "approval_id": execution.get("approval_id"),
        "plan_revision": execution.get("plan_revision"),
        "scope_hash": execution.get("scope_hash"),
        "executor": execution.get("executor"),
        "observation_time": observation_time,
    }
    if authorization != expected_authorization:
        return None, None, "prepared-authorization-mismatch"
    if (
        repository.get("name_with_owner") != policy.get("repository")
        or repository.get("read_complete") is not True
        or issue.get("repository") != policy.get("repository")
        or pr.get("repository") != policy.get("repository")
        or issue.get("closing_prs_complete") is not True
        or pr.get("closing_issues_complete") is not True
        or issue.get("closing_prs") != [pr.get("number")]
        or pr.get("closing_issues")
        != [{"repository": policy.get("repository"), "number": issue.get("number")}]
    ):
        return None, None, "prepared-identity-mismatch"
    head = authorization.get("head")
    if not isinstance(head, dict) or not re.fullmatch(
        r"[0-9a-f]{40}", str(head.get("sha", ""))
    ):
        return None, None, "prepared-head-invalid"

    approved_authors = ledger.get("approved_authors")
    if not isinstance(approved_authors, list):
        return None, None, "ledger-contract-invalid"
    record_exact = {
        "author": set(str(author) for author in approved_authors),
        "marker": ledger.get("marker"),
        "namespace": ledger.get("namespace"),
        "run_id": request.get("run_id"),
        "phase": "label-mutation",
        "repository": authorization.get("repository"),
        "issue": authorization.get("issue"),
        "pr": authorization.get("pr"),
        "head_sha": head.get("sha"),
        "evidence_digest": evidence_digest,
    }
    if not isinstance(record.get("comment_id"), int):
        return None, None, "prepared-record-comment-invalid"
    for field, expected in record_exact.items():
        actual = record.get(field)
        if field == "author":
            if actual not in expected:
                return None, None, "prepared-record-author-mismatch"
        elif actual != expected:
            return None, None, f"prepared-record-{field.replace('_', '-')}-mismatch"
    return authorization, evidence, None


def authorize(
    policy: dict[str, object], request: dict[str, object]
) -> dict[str, object]:
    contract = policy.get("existing_pr_adoption")
    labels = policy.get("labels")
    if not isinstance(contract, dict) or not isinstance(labels, dict):
        return blocked("adoption-contract-missing")
    expected_label = labels.get(str(contract.get("to_state")))
    exact = {
        "role": contract.get("owner"),
        "operation": "add-lifecycle-label",
        "repository": policy.get("repository"),
        "label": expected_label,
        "before": contract.get("from_state"),
        "after": contract.get("to_state"),
        "mode": "add-only",
        "ledger_phase": "label-mutation",
    }
    if any(request.get(field) != value for field, value in exact.items()):
        return blocked("mutation-contract-mismatch")
    if not isinstance(request.get("run_id"), str) or not str(
        request.get("run_id")
    ).strip():
        return blocked("mutation-run-invalid")
    adoption_input = request.get("adoption_input")
    adoption_input_digest = request.get("adoption_input_digest")
    if not isinstance(adoption_input, dict):
        return blocked("adoption-input-missing")
    if (
        not isinstance(adoption_input_digest, str)
        or not SHA256.fullmatch(adoption_input_digest)
        or adoption_input_digest != canonical_digest(adoption_input)
    ):
        return blocked("adoption-input-digest-mismatch")
    checker = runpy.run_path(str(ROOT / "scripts/check-cloud-queue-contract.py"))
    recomputed = checker["adopt_existing_pr"](adoption_input, policy)
    if not isinstance(recomputed, dict) or recomputed.get("status") != "adopt":
        return blocked("adoption-eligibility-refetch-failed")
    recomputed_request = recomputed.get("mutation_request")
    if not isinstance(recomputed_request, dict) or recomputed_request != request:
        return blocked("adoption-mutation-request-mismatch")
    authorization, evidence, prepared_error = validate_prepared_record(
        policy, contract, request
    )
    if prepared_error:
        return blocked(prepared_error)
    assert authorization is not None and evidence is not None
    if any(
        request.get(field) != authorization.get(field)
        for field in ("repository", "issue", "pr", "evidence_digest")
    ):
        return blocked("mutation-target-binding-mismatch")
    current = request.get("expected_current_labels")
    if not isinstance(current, list) or not all(
        isinstance(label, str) for label in current
    ):
        return blocked("mutation-label-cas-invalid")
    lifecycle_labels = {str(value) for value in labels.values()}
    if any(label in lifecycle_labels for label in current):
        return blocked("mutation-lifecycle-cas-invalid")
    issue_evidence = evidence.get("issue")
    if not isinstance(issue_evidence, dict):
        return blocked("mutation-issue-evidence-invalid")
    evidence_labels = issue_evidence.get("labels")
    if not isinstance(evidence_labels, list) or not all(
        isinstance(label, str) for label in evidence_labels
    ):
        return blocked("mutation-label-evidence-invalid")
    if sorted(current) != sorted(evidence_labels):
        return blocked("mutation-label-cas-mismatch")
    preserved = sorted(set(current))
    return {
        "status": "authorized",
        "repository": request["repository"],
        "issue": request["issue"],
        "pr": request["pr"],
        "run_id": request["run_id"],
        "evidence_digest": request["evidence_digest"],
        "mutation": {
            "mode": "add-only",
            "add": [expected_label],
            "remove": [],
            "preserve": preserved,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", default=".agents/workflows/backlog-policy.json")
    parser.add_argument("--request-file", required=True)
    args = parser.parse_args()
    result = authorize(load_object(args.policy), load_object(args.request_file))
    print(
        json.dumps(
            {"type": "existing_pr_adoption_mutation", "data": result},
            sort_keys=True,
        )
    )
    return 1 if result.get("status") == "blocked" else 0


if __name__ == "__main__":
    raise SystemExit(main())
