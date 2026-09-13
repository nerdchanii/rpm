#!/usr/bin/env python3
"""Read and route a GitHub PR event using current read-only evidence.

The event payload is used only to locate a pull request.  The adapter refetches
the pull request, its linked issue, review state, and the required checks before
returning a preliminary route.  This command never submits Cloud work, writes
GitHub state, checks out a PR head, or executes repository-provided content.

``inspect_event`` accepts a small fake-friendly adapter with these read-only
methods:

* ``get_pull_request(repository, number)``
* ``get_issue(repository, number)``
* ``get_checks(repository, head_sha)``

The returned values may use the GraphQL connection shape (``nodes`` plus
``pageInfo``) or the equivalent already-normalized fixture fields.  Real
``GhReadAdapter`` responses retain the page information so truncated evidence
fails closed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Mapping, Protocol


JSON = dict[str, Any]
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
CODEX_REVIEW_LOGINS = frozenset(
    {"chatgpt-codex-connector", "chatgpt-codex-connector[bot]"}
)
P0_P1_RE = re.compile(
    r"(?:^|[^A-Za-z0-9])(?:P[01]|priority\s*[:=]?\s*P?[01])(?:$|[^A-Za-z0-9])",
    re.IGNORECASE,
)


class EvidenceError(ValueError):
    """A malformed, stale, or incomplete read-only evidence response."""


class ReadOnlyGitHub(Protocol):
    """The injectable read-only boundary used by the evaluator and tests."""

    def get_pull_request(self, repository: str, number: int) -> Mapping[str, Any]: ...

    def get_issue(self, repository: str, number: int) -> Mapping[str, Any]: ...

    def get_checks(self, repository: str, head_sha: str) -> Mapping[str, Any]: ...


def _require_mapping(value: Any, name: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise EvidenceError(f"{name}-shape")
    return value


def _connection_nodes(value: Any, name: str, *, required: bool = True) -> list[Any]:
    """Read a bounded GraphQL connection and reject omitted/truncated pages."""

    if value is None:
        if required:
            raise EvidenceError(f"{name}-missing")
        return []
    if isinstance(value, list):
        # Injected fixtures are allowed to provide an already-normalized list.
        return value
    connection = _require_mapping(value, name)
    page_info = connection.get("pageInfo")
    page_info = _require_mapping(page_info, f"{name}-page-info")
    has_next = page_info.get("hasNextPage")
    if not isinstance(has_next, bool):
        raise EvidenceError(f"{name}-page-info-invalid")
    if has_next:
        raise EvidenceError(f"{name}-truncated")
    nodes = connection.get("nodes")
    if not isinstance(nodes, list):
        raise EvidenceError(f"{name}-nodes-shape")
    return nodes


def _first(value: Mapping[str, Any], *names: str, default: Any = None) -> Any:
    for name in names:
        if name in value:
            return value[name]
    return default


def _positive_number(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise EvidenceError(f"{name}-invalid")
    return value


def _sha(value: Any, name: str) -> str:
    if not isinstance(value, str) or not SHA_RE.fullmatch(value):
        raise EvidenceError(f"{name}-invalid")
    return value


def _repository(value: Any, name: str) -> str:
    if isinstance(value, Mapping):
        value = _first(value, "full_name", "fullName", "nameWithOwner")
    if not isinstance(value, str) or not REPOSITORY_RE.fullmatch(value):
        raise EvidenceError(f"{name}-invalid")
    return value


def _labels(value: Any, name: str) -> list[str]:
    labels = _connection_nodes(value, name)
    result: list[str] = []
    for label in labels:
        if isinstance(label, str):
            result.append(label)
            continue
        item = _require_mapping(label, f"{name}-item")
        label_name = item.get("name")
        if not isinstance(label_name, str):
            raise EvidenceError(f"{name}-item-invalid")
        result.append(label_name)
    return sorted(set(result))


def _nested(value: Mapping[str, Any], name: str) -> Mapping[str, Any]:
    nested = value.get(name)
    if nested is None:
        return {}
    return _require_mapping(nested, name)


def _mergeable(value: Any) -> bool | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.casefold()
        if normalized in {"mergeable", "clean", "true"}:
            return True
        if normalized in {"conflicting", "dirty", "false"}:
            return False
        if normalized in {"unknown", ""}:
            return None
    raise EvidenceError("mergeable-invalid")


def _normalize_pr(value: Mapping[str, Any], repository: str, *, labels: bool = True) -> JSON:
    number = _positive_number(value.get("number"), "pull-request-number")
    state = value.get("state")
    if not isinstance(state, str) or not state.strip():
        raise EvidenceError("pull-request-state-invalid")
    draft = _first(value, "isDraft", "draft")
    if not isinstance(draft, bool):
        raise EvidenceError("pull-request-draft-invalid")

    base = _nested(value, "base")
    head = _nested(value, "head")
    base_sha = _first(value, "baseRefOid", "base_sha", default=_first(base, "sha"))
    head_sha = _first(value, "headRefOid", "head_sha", default=_first(head, "sha"))
    base_ref = _first(value, "baseRefName", "base_ref", default=_first(base, "ref"))
    head_ref = _first(value, "headRefName", "head_ref", default=_first(head, "ref"))
    base_repo = _first(
        value,
        "base_repository",
        default=_first(value, "baseRepository", default=_first(base, "repo")),
    )
    head_repo = _first(
        value,
        "head_repository",
        default=_first(value, "headRepository", default=_first(head, "repo")),
    )
    normalized_base_repo = _repository(base_repo, "base-repository")
    normalized_head_repo = _repository(head_repo, "head-repository")
    if not isinstance(base_ref, str) or not base_ref.strip():
        raise EvidenceError("base-ref-invalid")
    if not isinstance(head_ref, str) or not head_ref.strip():
        raise EvidenceError("head-ref-invalid")

    result: JSON = {
        "number": number,
        "state": state,
        "draft": draft,
        "base": {
            "sha": _sha(base_sha, "base-sha"),
            "ref": base_ref,
            "repository": normalized_base_repo,
        },
        "head": {
            "sha": _sha(head_sha, "head-sha"),
            "ref": head_ref,
            "repository": normalized_head_repo,
        },
        "same_repository": normalized_base_repo == repository
        and normalized_head_repo == repository,
        "mergeable": _mergeable(value.get("mergeable")),
    }
    if labels:
        label_value = value.get("labels")
        if label_value is None:
            raise EvidenceError("pull-request-labels-missing")
        result["labels"] = _labels(label_value, "pull-request-labels")
    return result


def _normalize_closing_pr(value: Mapping[str, Any], repository: str) -> JSON:
    number = _positive_number(value.get("number"), "closing-pr-number")
    state = value.get("state")
    if not isinstance(state, str) or not state.strip():
        raise EvidenceError("closing-pr-state-invalid")
    draft = _first(value, "isDraft", "draft", default=False)
    if not isinstance(draft, bool):
        raise EvidenceError("closing-pr-draft-invalid")
    head_repo = _first(
        value,
        "head_repository",
        default=_first(value, "headRepository", default=_first(_nested(value, "head"), "repo")),
    )
    # A timeline source must identify its source repository.  An already
    # normalized fake may provide ``repository`` instead.
    source_repo = _first(value, "repository", default=head_repo)
    normalized_repo = _repository(source_repo, "closing-pr-repository")
    if normalized_repo != repository:
        raise EvidenceError("closing-pr-repository-mismatch")
    return {
        "number": number,
        "state": state,
        "draft": draft,
        "repository": normalized_repo,
        "mergeable": _mergeable(value.get("mergeable")),
    }


def _normalize_issue(value: Mapping[str, Any], repository: str) -> JSON:
    number = _positive_number(value.get("number"), "issue-number")
    issue_repository = _repository(
        _first(value, "repository", "repository_name", default=repository),
        "issue-repository",
    )
    if issue_repository != repository:
        raise EvidenceError("issue-repository-mismatch")
    state = value.get("state")
    if not isinstance(state, str) or not state.strip():
        raise EvidenceError("issue-state-invalid")
    if "labels" not in value:
        raise EvidenceError("issue-labels-missing")
    labels = _labels(value["labels"], "issue-labels")

    if "closing_prs" in value:
        closing_source = value["closing_prs"]
    elif "closingPullRequests" in value:
        closing_source = value["closingPullRequests"]
    else:
        timeline = value.get("timelineItems")
        if timeline is None:
            raise EvidenceError("closing-prs-missing")
        closing_source = []
        for item in _connection_nodes(timeline, "closing-prs-timeline"):
            event = _require_mapping(item, "closing-pr-event")
            will_close = event.get("willCloseTarget")
            if not isinstance(will_close, bool):
                raise EvidenceError("closing-pr-event-invalid")
            if not will_close:
                continue
            source = event.get("source")
            if source is None:
                raise EvidenceError("closing-pr-source-missing")
            closing_source.append(source)
    closing_prs = []
    for item in _connection_nodes(closing_source, "closing-prs"):
        closing_prs.append(_normalize_closing_pr(_require_mapping(item, "closing-pr"), repository))
    return {
        "number": number,
        "state": state,
        "labels": labels,
        "closing_prs": closing_prs,
    }


def _review_login(value: Mapping[str, Any]) -> str | None:
    author = value.get("author")
    if author is None:
        return None
    author = _require_mapping(author, "review-author")
    login = author.get("login")
    return login if isinstance(login, str) else None


def _has_codex_review(value: Any) -> bool:
    reviews = _connection_nodes(value, "reviews")
    for review in reviews:
        item = _require_mapping(review, "review")
        if _review_login(item) in CODEX_REVIEW_LOGINS:
            return True
    return False


def _thread_has_p0_p1(thread: Mapping[str, Any]) -> bool:
    resolved = thread.get("isResolved")
    outdated = thread.get("isOutdated")
    if not isinstance(resolved, bool) or not isinstance(outdated, bool):
        raise EvidenceError("review-thread-state-invalid")
    comments_value = thread.get("comments", [])
    comments = _connection_nodes(comments_value, "review-thread-comments")
    if resolved:
        return False
    for comment in comments:
        comment_map = _require_mapping(comment, "review-comment")
        body = comment_map.get("body", "")
        if not isinstance(body, str):
            raise EvidenceError("review-comment-body-invalid")
        if P0_P1_RE.search(body):
            return True
    return False


def _unresolved_p0_p1(value: Mapping[str, Any]) -> bool | None:
    direct = value.get("unresolved_p0_p1")
    if direct is not None:
        if not isinstance(direct, bool):
            raise EvidenceError("unresolved-p0-p1-invalid")
        return direct
    threads_value = _first(value, "review_threads", "reviewThreads")
    if threads_value is None:
        return None
    threads = _connection_nodes(threads_value, "review-threads")
    return any(_thread_has_p0_p1(_require_mapping(thread, "review-thread")) for thread in threads)


def _conclusion(value: Any) -> str:
    if value is None:
        return "pending"
    if not isinstance(value, str) or not value.strip():
        raise EvidenceError("check-conclusion-invalid")
    normalized = value.casefold()
    if normalized in {"success", "passed", "pass"}:
        return "success"
    if normalized in {"failure", "failed", "cancelled", "timed_out", "action_required"}:
        return normalized
    if normalized in {"pending", "queued", "in_progress", "expected", "waiting"}:
        return "pending"
    return normalized


def _required_checks(value: Any, policy: Mapping[str, Any]) -> dict[str, str]:
    gate = policy.get("merge_gate")
    gate = _require_mapping(gate, "policy-merge-gate")
    required_value = gate.get("required_checks")
    if not isinstance(required_value, list) or not required_value or not all(
        isinstance(name, str) and name.strip() for name in required_value
    ):
        raise EvidenceError("required-checks-policy-invalid")
    required = [str(name) for name in required_value]
    if len(set(required)) != len(required):
        raise EvidenceError("required-checks-policy-ambiguous")

    check_map: dict[str, str] = {}
    if "checks" in value:
        direct = value["checks"]
        if not isinstance(direct, Mapping):
            raise EvidenceError("checks-shape")
        for name, conclusion in direct.items():
            if not isinstance(name, str):
                raise EvidenceError("check-name-invalid")
            if name in required:
                if name in check_map:
                    raise EvidenceError("ambiguous-required-checks")
                check_map[name] = _conclusion(conclusion)
    else:
        contexts_value = value.get("contexts")
        if contexts_value is None:
            raise EvidenceError("checks-missing")
        for context in _connection_nodes(contexts_value, "check-contexts"):
            item = _require_mapping(context, "check-context")
            name = _first(item, "name", "context")
            if not isinstance(name, str) or not name.strip():
                raise EvidenceError("check-name-invalid")
            if name not in required:
                continue
            if name in check_map:
                raise EvidenceError("ambiguous-required-checks")
            check_map[name] = _conclusion(_first(item, "conclusion", "state"))
    return {name: check_map.get(name, "pending") for name in required}


def _policy_labels(policy: Mapping[str, Any]) -> dict[str, str]:
    labels = policy.get("labels")
    labels = _require_mapping(labels, "policy-labels")
    result = {str(state): label for state, label in labels.items() if isinstance(label, str)}
    if len(result) != len(labels):
        raise EvidenceError("policy-labels-invalid")
    return result


def _issue_state(issue: Mapping[str, Any], labels: Mapping[str, str]) -> tuple[str, list[str]]:
    issue_labels = issue.get("labels")
    if not isinstance(issue_labels, list):
        raise EvidenceError("issue-labels-invalid")
    matched = sorted(state for state, label in labels.items() if label in issue_labels)
    if len(matched) == 0:
        return "untracked", matched
    if len(matched) == 1:
        return matched[0], matched
    return "invalid", matched


def _event_repository(event: Mapping[str, Any]) -> str:
    repository = event.get("repository")
    if not isinstance(repository, Mapping):
        raise EvidenceError("event-repository-missing")
    return _repository(repository.get("full_name"), "event-repository")


def _event_head(event: Mapping[str, Any], event_name: str) -> str | None:
    if event_name in {"pull_request_target", "pull_request_review"}:
        payload = event.get("pull_request")
        if not isinstance(payload, Mapping):
            raise EvidenceError("event-pull-request-missing")
        head = payload.get("head")
        if head is None:
            return None
        head = _require_mapping(head, "event-head")
        value = head.get("sha")
    elif event_name == "workflow_run":
        payload = event.get("workflow_run")
        if not isinstance(payload, Mapping):
            raise EvidenceError("event-workflow-run-missing")
        value = payload.get("head_sha")
    else:
        return None
    if value is None:
        return None
    return _sha(value, "event-head-sha")


def _event_pr_number(
    event: Mapping[str, Any], event_name: str, dispatch_pr: int | None
) -> tuple[int | None, str | None]:
    if event_name == "workflow_dispatch":
        if dispatch_pr is None:
            raise EvidenceError("workflow-dispatch-pr-required")
        return _positive_number(dispatch_pr, "dispatch-pr"), None
    if event_name in {"pull_request_target", "pull_request_review"}:
        payload = event.get("pull_request")
        if not isinstance(payload, Mapping):
            raise EvidenceError("event-pull-request-missing")
        return _positive_number(payload.get("number"), "event-pr-number"), None
    workflow_run = event.get("workflow_run")
    if not isinstance(workflow_run, Mapping):
        raise EvidenceError("event-workflow-run-missing")
    pull_requests = workflow_run.get("pull_requests")
    if not isinstance(pull_requests, list):
        raise EvidenceError("workflow-run-pull-requests-invalid")
    if not pull_requests:
        return None, "workflow-run-without-pull-request"
    if len(pull_requests) != 1:
        raise EvidenceError("workflow-run-pull-requests-ambiguous")
    hint = _require_mapping(pull_requests[0], "workflow-run-pull-request")
    return _positive_number(hint.get("number"), "workflow-run-pr-number"), None


def _base_result(
    event_name: str, repository: str | None, event_repository: str | None
) -> JSON:
    return {
        "type": "codex_pr_event",
        "version": 1,
        "event_name": event_name,
        "repository": repository,
        "event_repository": event_repository,
        "pr": None,
        "issue": None,
        "current_head": None,
        "current_head_sha": None,
        "head_sha": None,
        "event_head": None,
        "head_stale": False,
        "same_repository": None,
        "status": "blocked",
        "route": "blocked",
        "reason": "uninitialized",
        "next": None,
        "merge_authorized": False,
        "preliminary": {"select_review": None, "select_merge": None},
    }


def _blocked(result: JSON, reason: str) -> JSON:
    result.update(status="blocked", route="blocked", reason=reason, next=None)
    result["merge_authorized"] = False
    return result


def _queue_verdicts(
    fixture: JSON, policy: Mapping[str, Any], labels: Mapping[str, str]
) -> dict[str, JSON]:
    queue = _load_source_module(Path(__file__).with_name("check-cloud-queue-contract.py"))
    merge = _load_source_module(Path(__file__).with_name("check-merge-gate.py"))
    review_data = queue.select_review(fixture, labels)
    merge_data = merge.select_merge(
        fixture,
        merge.lifecycle_labels(policy),
        merge.merge_gate(policy),
    )
    return {
        "select_review": {"type": "cloud_queue_contract", "data": review_data},
        "select_merge": {"type": "merge_gate_contract", "data": merge_data},
    }


def _load_source_module(path: Path) -> SimpleNamespace:
    """Load an existing validator without creating ``__pycache__`` files."""

    namespace: dict[str, Any] = {
        "__name__": path.stem.replace("-", "_"),
        "__file__": str(path),
        "__package__": None,
    }
    try:
        source = path.read_text(encoding="utf-8")
        exec(compile(source, str(path), "exec"), namespace)
    except (OSError, SyntaxError) as exc:
        raise EvidenceError("validator-unavailable") from exc
    return SimpleNamespace(**namespace)


def inspect_event(
    event: Mapping[str, Any],
    event_name: str,
    policy: Mapping[str, Any],
    github: ReadOnlyGitHub,
    *,
    pr_number: int | None = None,
) -> JSON:
    """Evaluate one event with a read-only adapter and return JSON-safe data."""

    policy_repository = policy.get("repository")
    try:
        repository = _repository(policy_repository, "policy-repository")
    except EvidenceError as exc:
        result = _base_result(event_name, None, None)
        return _blocked(result, str(exc))

    result = _base_result(event_name, repository, None)
    try:
        if not isinstance(event, Mapping):
            raise EvidenceError("event-shape")
        event_repository = _event_repository(event)
        result["event_repository"] = event_repository
        if event_repository != repository:
            return _blocked(result, "event-repository-mismatch")
        event_head = _event_head(event, event_name)
        result["event_head"] = event_head
        selected_number, no_work_reason = _event_pr_number(event, event_name, pr_number)
        if selected_number is None:
            result.update(status="no-work", route="no-work", reason=no_work_reason)
            return result
        result["pr"] = selected_number
        current_raw = github.get_pull_request(repository, selected_number)
        current = _normalize_pr(_require_mapping(current_raw, "pull-request"), repository)
        if current["number"] != selected_number:
            raise EvidenceError("pull-request-number-mismatch")
        result["current_head"] = current["head"]
        result["current_head_sha"] = current["head"]["sha"]
        result["head_sha"] = current["head"]["sha"]
        result["same_repository"] = current["same_repository"]
        result["head_stale"] = event_head is not None and event_head != current["head"]["sha"]
        result["current"] = {
            "state": current["state"],
            "draft": current["draft"],
            "base": current["base"],
            "head": current["head"],
            "labels": current["labels"],
            "same_repository": current["same_repository"],
        }

        if current["state"].casefold() != "open":
            return result | {
                "status": "no-work",
                "route": "no-work",
                "reason": "pr-not-open",
                "next": None,
            }
        if current["draft"]:
            return result | {
                "status": "no-work",
                "route": "no-work",
                "reason": "draft-pr",
                "next": None,
            }
        if not current["same_repository"]:
            return _blocked(result, "head-repository-mismatch")

        # These reads remain current-head evidence even when no linked issue is
        # available.  An untracked PR still needs a bounded report before the
        # eventual authorized-adoption path can consider it.
        checks_raw = github.get_checks(repository, current["head"]["sha"])
        checks = _required_checks(
            _require_mapping(checks_raw, "checks"), policy
        )
        codex_review_value = _first(current_raw, "reviews")
        if codex_review_value is None:
            raise EvidenceError("reviews-missing")
        codex_review_present = _has_codex_review(codex_review_value)
        unresolved = _unresolved_p0_p1(_require_mapping(current_raw, "pull-request"))

        closing_issues_value = _first(
            _require_mapping(current_raw, "pull-request"),
            "closing_issues",
            "closingIssuesReferences",
        )
        closing_issues = _connection_nodes(closing_issues_value, "closing-issues")
        if len(closing_issues) == 0:
            result.update(
                status="no-work",
                route="publication-state-pending",
                reason="authorized-adoption-required",
                next="authorized-adoption-required",
                source_state="untracked",
            )
            result["evidence"] = {
                "pr_labels": current["labels"],
                "closing_issues": [],
                "required_checks": checks,
                "codex_review_present": codex_review_present,
                "unresolved_p0_p1": unresolved,
            }
            return result
        if len(closing_issues) > 1:
            return _blocked(result, "multiple-closing-issues")
        issue_hint = _require_mapping(closing_issues[0], "closing-issue")
        issue_number = _positive_number(issue_hint.get("number"), "closing-issue-number")
        issue_repository = _repository(
            _first(issue_hint, "repository", "repository_name", default=repository),
            "closing-issue-repository",
        )
        if issue_repository != repository:
            return _blocked(result, "closing-issue-repository-mismatch")
        issue_raw = github.get_issue(repository, issue_number)
        issue = _normalize_issue(_require_mapping(issue_raw, "issue"), repository)
        if issue["number"] != issue_number:
            raise EvidenceError("issue-number-mismatch")
        result["issue"] = issue_number

        closing_prs = issue["closing_prs"]
        open_closing_prs = [
            pr for pr in closing_prs if str(pr["state"]).casefold() == "open"
        ]
        if len(open_closing_prs) > 1:
            return _blocked(result, "multiple-open-closing-prs")
        if len(open_closing_prs) == 0:
            return _blocked(result, "no-open-closing-pr")
        if open_closing_prs[0]["number"] != selected_number:
            return _blocked(result, "closing-pr-mismatch")

        labels = _policy_labels(policy)
        source_state, matched_states = _issue_state(issue, labels)
        if source_state == "invalid":
            return _blocked(result, "multiple-lifecycle-labels")
        result["source_state"] = source_state
        result["issue_labels"] = issue["labels"]
        result["evidence"] = {
            "pr_labels": current["labels"],
            "issue_labels": issue["labels"],
            "closing_issues": [issue_number],
            "closing_prs": [pr["number"] for pr in closing_prs],
            "required_checks": checks,
            "codex_review_present": codex_review_present,
            "unresolved_p0_p1": unresolved,
        }
        fixture_pr: JSON = {
            "number": selected_number,
            "state": current["state"],
            "draft": current["draft"],
            "checks": checks,
            "mergeable": current["mergeable"],
            "unresolved_p0_p1": unresolved,
        }
        fixture_closing_prs: list[JSON] = []
        for closing_pr in closing_prs:
            if closing_pr["number"] == selected_number:
                fixture_closing_prs.append(fixture_pr)
            else:
                fixture_closing_prs.append(closing_pr)
        fixture: JSON = {
            "repository": repository,
            "issues": [
                {
                    "number": issue_number,
                    "state": issue["state"],
                    "labels": issue["labels"],
                    "closing_prs": fixture_closing_prs,
                    "codex_review_present": codex_review_present,
                }
            ],
        }
        result["preliminary"] = _queue_verdicts(fixture, policy, labels)

        if source_state == "claimed":
            result.update(
                status="no-work",
                route="publication-state-pending",
                reason="publication-state-pending",
                next=None,
            )
            return result
        if source_state == "untracked" or source_state not in {
            "review-pending",
            "awaiting-merge",
        }:
            reason = (
                "authorized-adoption-required"
                if source_state == "untracked"
                else f"source-state-{source_state}"
            )
            result.update(
                status="no-work",
                route="publication-state-pending",
                reason=reason,
                next="authorized-adoption-required" if source_state == "untracked" else None,
            )
            return result
        if source_state == "review-pending":
            review_data = result["preliminary"]["select_review"]["data"]
            if review_data.get("status") == "selected":
                result.update(
                    status="ready",
                    route="pr-review-resolution",
                    reason="review-present",
                    next="pr-review-resolution",
                )
            elif review_data.get("status") == "no-work":
                result.update(
                    status="no-work",
                    route="no-work",
                    reason=str(review_data.get("reason", "review-not-arrived")),
                    next=None,
                )
            else:
                result.update(status="blocked", route="blocked", reason="review-route-blocked", next=None)
            return result

        merge_data = result["preliminary"]["select_merge"]["data"]
        result["next"] = "merge-gatekeeper"
        if merge_data.get("status") == "merge":
            result.update(status="ready", route="merge-gatekeeper", reason="gate-passed")
        elif merge_data.get("status") == "no-work":
            result.update(status="no-work", route="no-work", reason=str(merge_data.get("reason")))
        else:
            result.update(status="blocked", route="blocked", reason=str(merge_data.get("reason")))
        # The event report is guidance only.  It never contains a merge token.
        result["merge_authorized"] = False
        return result
    except EvidenceError as exc:
        return _blocked(result, str(exc))
    except (OSError, subprocess.SubprocessError, TypeError, KeyError):
        return _blocked(result, "github-read-failed")


class GhReadAdapter:
    """Official GitHub CLI read adapter using read-only GraphQL queries."""

    pull_request_query = """
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      number state isDraft mergeable baseRefName headRefName baseRefOid headRefOid
      baseRepository{nameWithOwner} headRepository{nameWithOwner}
      labels(first:100){pageInfo{hasNextPage,endCursor}nodes{name}}
      closingIssuesReferences(first:100){pageInfo{hasNextPage,endCursor}nodes{number state repository{nameWithOwner}}}
      reviews(first:100){pageInfo{hasNextPage,endCursor}nodes{author{login}state submittedAt body}}
      reviewThreads(first:100){pageInfo{hasNextPage,endCursor}nodes{
        isResolved isOutdated comments(first:100){pageInfo{hasNextPage,endCursor}nodes{body}}
      }}
    }
  }
}
"""

    issue_query = """
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    issue(number:$number){
      number state repository{nameWithOwner}
      labels(first:100){pageInfo{hasNextPage,endCursor}nodes{name}}
      timelineItems(first:100,itemTypes:[CROSS_REFERENCED_EVENT]){
        pageInfo{hasNextPage,endCursor}
        nodes{... on CrossReferencedEvent{
          isCrossRepository willCloseTarget
          source{__typename ... on PullRequest{
            number state isDraft mergeable baseRefName headRefName baseRefOid headRefOid
            baseRepository{nameWithOwner} headRepository{nameWithOwner}
          }}
        }}
      }
    }
  }
}
"""

    checks_query = """
query($owner:String!,$name:String!,$expression:String!){
  repository(owner:$owner,name:$name){
    object(expression:$expression){
      __typename
      ... on Commit{oid statusCheckRollup{contexts(first:100){
        pageInfo{hasNextPage,endCursor}
        nodes{__typename ... on CheckRun{name conclusion status detailsUrl}
          ... on StatusContext{context state targetUrl}}
      }}}
    }
  }
}
"""

    def _run(self, args: list[str]) -> JSON:
        try:
            completed = subprocess.run(
                ["gh", *args],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
            )
        except OSError as exc:
            raise EvidenceError("github-read-failed") from exc
        if completed.returncode != 0:
            raise EvidenceError("github-read-failed")
        try:
            value = json.loads(completed.stdout)
        except (TypeError, json.JSONDecodeError) as exc:
            raise EvidenceError("github-response-invalid") from exc
        return _require_mapping(value, "github-response") | {}

    def _graphql(self, query: str, **variables: Any) -> JSON:
        args = ["api", "graphql", "-f", f"query={query}"]
        for name, value in variables.items():
            option = "-F" if isinstance(value, int) else "-f"
            args.extend([option, f"{name}={value}"])
        response = self._run(args)
        errors = response.get("errors")
        if errors:
            raise EvidenceError("github-graphql-read-failed")
        data = response.get("data")
        if not isinstance(data, Mapping):
            raise EvidenceError("github-graphql-response-invalid")
        return _require_mapping(data, "github-graphql-data") | {}

    @staticmethod
    def _owner_name(repository: str) -> tuple[str, str]:
        if not REPOSITORY_RE.fullmatch(repository):
            raise EvidenceError("repository-invalid")
        return tuple(repository.split("/", 1))  # type: ignore[return-value]

    def get_pull_request(self, repository: str, number: int) -> Mapping[str, Any]:
        owner, name = self._owner_name(repository)
        data = self._graphql(self.pull_request_query, owner=owner, name=name, number=number)
        repo = _require_mapping(data.get("repository"), "github-repository")
        pull_request = repo.get("pullRequest")
        if pull_request is None:
            raise EvidenceError("pull-request-not-found")
        return _require_mapping(pull_request, "pull-request")

    def get_issue(self, repository: str, number: int) -> Mapping[str, Any]:
        owner, name = self._owner_name(repository)
        data = self._graphql(self.issue_query, owner=owner, name=name, number=number)
        repo = _require_mapping(data.get("repository"), "github-repository")
        issue = repo.get("issue")
        if issue is None:
            raise EvidenceError("issue-not-found")
        return _require_mapping(issue, "issue")

    def get_checks(self, repository: str, head_sha: str) -> Mapping[str, Any]:
        owner, name = self._owner_name(repository)
        data = self._graphql(
            self.checks_query, owner=owner, name=name, expression=head_sha
        )
        obj = data.get("repository")
        obj = _require_mapping(obj, "github-repository").get("object")
        obj = _require_mapping(obj, "github-commit")
        if obj.get("__typename") != "Commit" or obj.get("oid") != head_sha:
            raise EvidenceError("checks-head-mismatch")
        rollup = obj.get("statusCheckRollup")
        if rollup is None:
            # GitHub can expose a commit before its first check run exists.
            # Keep that as an empty, complete connection so the existing merge
            # gate reports the required checks as pending.
            return {
                "head_sha": head_sha,
                "contexts": {
                    "pageInfo": {"hasNextPage": False, "endCursor": None},
                    "nodes": [],
                },
            }
        rollup = _require_mapping(rollup, "checks-rollup")
        return {"head_sha": head_sha, "contexts": rollup.get("contexts")}


def _load_json(path: Path, name: str) -> JSON:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"{name}-invalid") from exc
    return dict(_require_mapping(value, name))


def _positive_arg(value: str) -> int:
    try:
        number = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a positive decimal number") from exc
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive decimal number")
    return number


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-file", type=Path, required=True)
    parser.add_argument(
        "--event-name",
        required=True,
        choices=(
            "pull_request_target",
            "pull_request_review",
            "workflow_run",
            "workflow_dispatch",
        ),
    )
    parser.add_argument("--pr", type=_positive_arg, help="PR number for workflow_dispatch")
    parser.add_argument("--policy", type=Path, default=Path(".agents/workflows/backlog-policy.json"))
    args = parser.parse_args(argv)
    result: JSON
    try:
        event = _load_json(args.event_file, "event")
        policy = _load_json(args.policy, "policy")
        if args.event_name == "workflow_dispatch" and args.pr is None:
            parser.error("--pr is required for workflow_dispatch")
        if args.event_name != "workflow_dispatch" and args.pr is not None:
            parser.error("--pr is only valid for workflow_dispatch")
        result = inspect_event(
            event,
            args.event_name,
            policy,
            GhReadAdapter(),
            pr_number=args.pr,
        )
    except EvidenceError as exc:
        result = _base_result(args.event_name, None, None)
        result = _blocked(result, str(exc))
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 1 if result.get("status") == "blocked" else 0


if __name__ == "__main__":
    raise SystemExit(main())
