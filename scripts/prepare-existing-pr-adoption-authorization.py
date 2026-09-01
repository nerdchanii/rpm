#!/usr/bin/env python3
"""Prepare an externally approved marker for existing-PR adoption.

This entry point only reads a prospective adoption evidence packet.  It never
contacts GitHub and never publishes the marker.  A trusted caller must review
the returned checkpoint and publish the exact marker as an issue comment before
the adopter can resume.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import runpy
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SHA256 = re.compile(r"sha256:[0-9a-f]{64}\Z")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")
MARKER_FIELDS = (
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
    "approval_id",
    "plan_revision",
    "scope_hash",
    "executor",
)
APPROVAL_FIELDS = ("approval_id", "plan_revision", "scope_hash", "executor")


class InputError(ValueError):
    """An input packet cannot be used for a new authorization checkpoint."""


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise InputError(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def load_json_bytes(raw: bytes, source: str) -> dict[str, object]:
    if not raw:
        raise InputError(f"{source} is empty")
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InputError(f"{source} must be UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise InputError(f"{source} must contain a JSON object")
    return value


def load_json_file(path: Path) -> dict[str, object]:
    try:
        return load_json_bytes(path.read_bytes(), str(path))
    except OSError as error:
        raise InputError(f"cannot read evidence file: {path}") from error


def adoption_evidence_digest(value: object) -> str:
    """Reuse the adoption digest contract owned by the mutation authorizer."""
    namespace = runpy.run_path(
        str(ROOT / "scripts/authorize-existing-pr-adoption-mutation.py")
    )
    digest = namespace.get("adoption_evidence_digest")
    if not callable(digest):
        raise InputError("adoption digest contract is unavailable")
    result = digest(value)
    if not isinstance(result, str) or SHA256.fullmatch(result) is None:
        raise InputError("adoption digest contract returned an invalid digest")
    return result


def _require_string(value: object, field: str) -> str:
    if not isinstance(value, str) or not value.strip() or any(
        character in value for character in ("\r", "\n")
    ):
        raise InputError(f"{field} must be a non-empty single-line string")
    return value


def _require_positive_int(value: object, field: str) -> int:
    if type(value) is not int or value <= 0:
        raise InputError(f"{field} must be a positive integer")
    return value


def _require_sha(value: object, field: str) -> str:
    result = _require_string(value, field)
    if SHA.fullmatch(result) is None:
        raise InputError(f"{field} must be a lowercase 40-character SHA")
    return result


def _require_repository(value: object, field: str) -> str:
    result = _require_string(value, field)
    if REPOSITORY.fullmatch(result) is None:
        raise InputError(f"{field} must be an owner/name repository")
    return result


def _require_object(value: object, field: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise InputError(f"{field} must be an object")
    return value


def _require_complete_collection(
    value: object,
    field: str,
) -> dict[str, object]:
    collection = _require_object(value, field)
    if collection.get("read_complete") is not True:
        raise InputError(f"{field}.read_complete must be true")
    if collection.get("pagination_complete") is not True:
        raise InputError(f"{field}.pagination_complete must be true")
    if collection.get("has_next_page") is not False:
        raise InputError(f"{field}.has_next_page must be false")
    records = collection.get("records", collection.get("items"))
    if not isinstance(records, list) or not all(isinstance(item, dict) for item in records):
        raise InputError(f"{field}.records must be an array of objects")
    if collection.get("count") != len(records):
        raise InputError(f"{field}.count does not match its records")
    return collection


def _extract_evidence(packet: dict[str, object]) -> tuple[dict[str, object], dict[str, object] | None]:
    nested = packet.get("evidence")
    if nested is None:
        return packet, None
    return _require_object(nested, "evidence"), packet


def _validate_policy(policy: dict[str, object]) -> dict[str, object]:
    repository = _require_repository(policy.get("repository"), "policy.repository")
    contract = _require_object(policy.get("existing_pr_adoption"), "policy.existing_pr_adoption")
    if contract.get("operation") != "adopt-existing-pr":
        raise InputError("policy existing-PR operation is invalid")
    expected_identity = [
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
    ]
    if contract.get("approval_identity_fields") != expected_identity:
        raise InputError("policy approval identity contract is invalid")
    return {"repository": repository, "contract": contract}


def _validate_target(
    evidence: dict[str, object],
    policy: dict[str, object],
) -> tuple[str, int, int, dict[str, object], dict[str, object], dict[str, object]]:
    policy_repository = _require_repository(policy.get("repository"), "policy.repository")
    repository = _require_object(evidence.get("repository"), "evidence.repository")
    issue = _require_object(evidence.get("issue"), "evidence.issue")
    pr = _require_object(evidence.get("pr"), "evidence.pr")
    evidence_repository = _require_repository(
        repository.get("name_with_owner"), "evidence.repository.name_with_owner"
    )
    if evidence_repository != policy_repository or repository.get("read_complete") is not True:
        raise InputError("evidence repository identity is incomplete or mismatched")
    issue_repository = _require_repository(issue.get("repository"), "evidence.issue.repository")
    pr_repository = _require_repository(pr.get("repository"), "evidence.pr.repository")
    if issue_repository != policy_repository or pr_repository != policy_repository:
        raise InputError("issue or pull request repository identity is mismatched")
    issue_number = _require_positive_int(issue.get("number"), "evidence.issue.number")
    pr_number = _require_positive_int(pr.get("number"), "evidence.pr.number")
    if str(issue.get("state", "")).casefold() != "open":
        raise InputError("evidence.issue must be open")
    if str(pr.get("state", "")).casefold() != "open" or pr.get("is_draft") is not False:
        raise InputError("evidence.pr must be an open non-draft pull request")

    closing_prs = issue.get("closing_prs")
    closing_issues = pr.get("closing_issues")
    if (
        issue.get("closing_prs_complete") is not True
        or not isinstance(closing_prs, list)
        or closing_prs != [pr_number]
        or pr.get("closing_issues_complete") is not True
        or not isinstance(closing_issues, list)
        or closing_issues != [{"repository": policy_repository, "number": issue_number}]
    ):
        raise InputError("issue and pull request closing relationship is incomplete")

    base = _require_object(pr.get("base"), "evidence.pr.base")
    head = _require_object(pr.get("head"), "evidence.pr.head")
    base_repository = _require_repository(base.get("repository"), "evidence.pr.base.repository")
    head_repository = _require_repository(head.get("repository"), "evidence.pr.head.repository")
    if base_repository != policy_repository:
        raise InputError("pull request base repository is mismatched")
    base_ref = _require_string(base.get("ref"), "evidence.pr.base.ref")
    head_ref = _require_string(head.get("ref"), "evidence.pr.head.ref")
    base_sha = _require_sha(base.get("sha"), "evidence.pr.base.sha")
    head_sha = _require_sha(head.get("sha"), "evidence.pr.head.sha")
    return (
        policy_repository,
        issue_number,
        pr_number,
        {
            "repository": base_repository,
            "ref": base_ref,
            "sha": base_sha,
        },
        {
            "repository": head_repository,
            "ref": head_ref,
            "sha": head_sha,
        },
        {"issue": issue, "pr": pr},
    )


def _validate_live_evidence(
    packet: dict[str, object] | None,
    evidence: dict[str, object],
    policy: dict[str, object],
    head_sha: str,
) -> None:
    """Require complete collections before producing an approval checkpoint."""
    contract = _require_object(policy.get("existing_pr_adoption"), "policy.existing_pr_adoption")
    repository = _require_repository(
        _require_object(evidence.get("repository"), "evidence.repository").get(
            "name_with_owner"
        ),
        "evidence.repository.name_with_owner",
    )
    pr = _require_object(evidence.get("pr"), "evidence.pr")
    pr_number = _require_positive_int(pr.get("number"), "evidence.pr.number")
    for field in ("checks", "review", "findings", "writers", "dependent_prs"):
        if field not in evidence:
            raise InputError(f"prospective evidence is missing {field}")
    checks = _require_complete_collection(evidence.get("checks"), "evidence.checks")
    if (
        checks.get("source") != "github-check-runs-v1"
        or checks.get("repository") != repository
        or checks.get("pr") != pr_number
        or checks.get("head_sha") != head_sha
    ):
        raise InputError("evidence.checks source or head is mismatched")
    review = _require_object(evidence.get("review"), "evidence.review")
    if (
        review.get("repository") != repository
        or review.get("pr") != pr_number
        or review.get("head_sha") != head_sha
    ):
        raise InputError("evidence.review head is mismatched")
    automatic_reviews = _require_complete_collection(
        review.get("automatic_reviews"), "evidence.review.automatic_reviews"
    )
    reactions = _require_complete_collection(
        review.get("reactions"), "evidence.review.reactions"
    )
    if automatic_reviews.get("source") != "github-pull-request-reviews-v1":
        raise InputError("evidence.review.automatic_reviews source is mismatched")
    if reactions.get("source") != "github-pull-request-reactions-v1":
        raise InputError("evidence.review.reactions source is mismatched")
    findings = _require_complete_collection(evidence.get("findings"), "evidence.findings")
    if (
        findings.get("source") != "current-head-review-findings-v1"
        or findings.get("repository") != repository
        or findings.get("pr") != pr_number
        or findings.get("head_sha") != head_sha
    ):
        raise InputError("evidence.findings source or head is mismatched")
    writers = _require_complete_collection(evidence.get("writers"), "evidence.writers")
    dependents = _require_complete_collection(evidence.get("dependent_prs"), "evidence.dependent_prs")
    if (
        writers.get("source") != "repository-global-writer-inventory-v1"
        or writers.get("repository") != repository
        or writers.get("pr") != pr_number
        or writers.get("head_sha") != head_sha
    ):
        raise InputError("evidence.writers source or head is mismatched")
    if (
        dependents.get("source") != "repository-open-pr-base-inventory-v1"
        or dependents.get("repository") != repository
        or dependents.get("pr") != pr_number
        or dependents.get("head_sha") != head_sha
    ):
        raise InputError("evidence.dependent_prs source or head is mismatched")
    execution = evidence.get("execution")
    if execution is not None:
        if not isinstance(execution, dict):
            raise InputError("prospective execution evidence is invalid")
        if set(execution) == set(APPROVAL_FIELDS):
            raise InputError("prospective execution evidence uses the legacy schema")
    if packet is None:
        return
    operation = _require_object(packet.get("operation"), "operation")
    authorization = _require_object(packet.get("authorization"), "authorization")
    if operation.get("name") != contract.get("operation") or operation.get("version") != contract.get("operation_version"):
        raise InputError("prospective operation identity is mismatched")
    if operation.get("policy_version") != policy.get("version"):
        raise InputError("prospective policy version is mismatched")
    if authorization.get("repository") != policy.get("repository"):
        raise InputError("prospective authorization repository is mismatched")
    # The packet may carry a previous digest for comparison.  It is never used
    # as the digest source; the imported canonical function below is the source.
    supplied_digest = authorization.get("evidence_digest")
    if supplied_digest is not None and not isinstance(supplied_digest, str):
        raise InputError("prospective authorization digest is invalid")


def _validate_optional_bindings(
    packet: dict[str, object] | None,
    marker_payload: dict[str, object],
) -> None:
    if packet is None:
        return
    authorization = packet.get("authorization")
    if not isinstance(authorization, dict):
        raise InputError("prospective authorization is missing")
    expected = {
        "repository": marker_payload["repository"],
        "issue": marker_payload["issue"],
        "pr": marker_payload["pr"],
        "base": {
            "repository": marker_payload["base_repository"],
            "ref": marker_payload["base_ref"],
            "sha": marker_payload["base_sha"],
        },
        "head": {
            "repository": marker_payload["head_repository"],
            "ref": marker_payload["head_ref"],
            "sha": marker_payload["head_sha"],
        },
    }
    for field, value in expected.items():
        if authorization.get(field) != value:
            raise InputError(f"prospective authorization {field} binding is mismatched")
    for field in APPROVAL_FIELDS:
        supplied = authorization.get(field)
        if supplied is not None and supplied != marker_payload[field]:
            raise InputError(f"prospective authorization {field} binding is mismatched")
    supplied_digest = authorization.get("evidence_digest")
    if supplied_digest is not None and supplied_digest != marker_payload["evidence_digest"]:
        raise InputError("prospective authorization evidence digest is stale")


def prepare(
    packet: dict[str, object],
    policy: dict[str, object],
    *,
    approval_id: str,
    plan_revision: str,
    scope_hash: str,
    executor: str,
) -> dict[str, object]:
    policy_data = _validate_policy(policy)
    repository = str(policy_data["repository"])
    evidence, full_packet = _extract_evidence(packet)
    (
        target_repository,
        issue_number,
        pr_number,
        base,
        head,
        _target,
    ) = _validate_target(
        evidence,
        {"repository": repository, "existing_pr_adoption": policy_data["contract"]},
    )
    if target_repository != repository:
        raise InputError("target repository is mismatched")
    _require_string(approval_id, "approval_id")
    _require_string(plan_revision, "plan_revision")
    if SHA256.fullmatch(scope_hash) is None:
        raise InputError("scope_hash must be sha256 followed by 64 lowercase hex characters")
    if executor not in {"local", "cloud"}:
        raise InputError("executor must be local or cloud")
    head_sha = str(head["sha"])
    _validate_live_evidence(full_packet, evidence, policy, head_sha)
    digest = adoption_evidence_digest(evidence)
    marker_payload: dict[str, object] = {
        "repository": repository,
        "issue": issue_number,
        "pr": pr_number,
        "base_repository": base["repository"],
        "base_ref": base["ref"],
        "base_sha": base["sha"],
        "head_repository": head["repository"],
        "head_ref": head["ref"],
        "head_sha": head_sha,
        "evidence_digest": digest,
        "approval_id": approval_id,
        "plan_revision": plan_revision,
        "scope_hash": scope_hash,
        "executor": executor,
    }
    if set(marker_payload) != set(MARKER_FIELDS):
        raise InputError("authorization marker field contract is invalid")
    _validate_optional_bindings(full_packet, marker_payload)
    marker = "<!-- rpm-agent-execution: " + json.dumps(
        marker_payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ) + " -->"
    marker_digest = f"sha256:{hashlib.sha256(marker.encode('utf-8')).hexdigest()}"
    return {
        "type": "existing_pr_adoption_authorization",
        "data": {
            "status": "authorization-required",
            "phase": "authorization-required",
            "repository": repository,
            "issue": issue_number,
            "pr": pr_number,
            "evidence_digest": digest,
            "approval_id": approval_id,
            "plan_revision": plan_revision,
            "scope_hash": scope_hash,
            "executor": executor,
            "marker": marker,
            "marker_digest": marker_digest,
            "authorization": marker_payload,
            "checkpoint": {
                "phase": "authorization-required",
                "requires_external_approval": True,
                "publish_exact_marker_as_issue_comment": True,
                "mutation_count": 0,
            },
            "mutations": [],
        },
    }


def _error_event(reason: str) -> dict[str, object]:
    return {
        "type": "existing_pr_adoption_authorization",
        "data": {
            "status": "blocked",
            "phase": "authorization-required",
            "reason": reason,
            "mutations": [],
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Prepare an externally approved existing-PR adoption marker."
    )
    parser.add_argument("--policy", default=".agents/workflows/backlog-policy.json", type=Path)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--evidence-file", type=Path)
    source.add_argument("--evidence-stdin", action="store_true")
    parser.add_argument("--approval-id", required=True)
    parser.add_argument("--plan-revision", required=True)
    parser.add_argument("--scope-hash", required=True)
    parser.add_argument("--executor", required=True, choices=("cloud", "local"))
    args = parser.parse_args(argv)
    try:
        policy = load_json_file(args.policy)
        packet = (
            load_json_bytes(sys.stdin.buffer.read(), "stdin")
            if args.evidence_stdin
            else load_json_file(args.evidence_file)
        )
        result = prepare(
            packet,
            policy,
            approval_id=args.approval_id,
            plan_revision=args.plan_revision,
            scope_hash=args.scope_hash,
            executor=args.executor,
        )
    except (InputError, OSError, TypeError, ValueError) as error:
        print(json.dumps(_error_event(str(error)), ensure_ascii=False, separators=(",", ":"), sort_keys=True))
        return 1
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
