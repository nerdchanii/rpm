#!/usr/bin/env python3
"""Execute one CAS-protected phase of the dedicated existing-PR adoption."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import runpy
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Protocol, Sequence
from urllib.parse import quote


ROOT = Path(__file__).resolve().parents[1]


EXECUTION_MARKER = re.compile(
    r"<!--\s*rpm-agent-execution:\s*(\{.*?\})\s*-->", re.DOTALL
)
FINDING_MARKER = re.compile(
    r"<!--\s*(?:rpm-agent-finding|rpm-review-finding)(?::v1)?:\s*(\{.*?\})\s*-->",
    re.DOTALL,
)
WRITER_MARKER = re.compile(
    r"<!--\s*rpm-agent-writer(?::v1)?:\s*(\{.*?\})\s*-->",
    re.DOTALL,
)


class AdoptionTransport(Protocol):
    def read(self, repository: str, issue: int, pr: int) -> dict[str, object]: ...

    def compare_and_write(
        self,
        repository: str,
        issue: int,
        pr: int,
        expected_cas: str,
        mutation: dict[str, object],
    ) -> dict[str, object]: ...


class GithubAdoptionTransport:
    """Narrow GitHub transport for the dedicated adoption writer.

    The writer is the only caller allowed to use this transport.  It accepts a
    callable runner so tests can supply deterministic responses without a
    network.  The default runner invokes only explicit ``gh api`` GET/POST
    endpoints; it never executes a shell and has no merge, review, branch, or
    safe-direct operation.
    """

    def __init__(
        self,
        snapshot: dict[str, object] | None = None,
        runner: Callable[..., object] | None = None,
        collectors: dict[str, Callable[..., object]] | None = None,
        approved_marker_actors: Sequence[str] | None = None,
        observation_clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.snapshot = copy.deepcopy(snapshot) if snapshot is not None else None
        self.runner = runner or self._subprocess_runner
        self.observation_clock = observation_clock or (
            lambda: datetime.now(timezone.utc)
        )
        # Finding markers are review evidence, so their authors must come from
        # the policy-owned allowlist.  An omitted allowlist is intentionally an
        # empty set and causes the GitHub collector to fail closed.
        if approved_marker_actors is None:
            self.approved_marker_actors: frozenset[str] = frozenset()
        else:
            if any(
                not isinstance(actor, str) or not actor.strip()
                for actor in approved_marker_actors
            ):
                raise ValueError("approved finding marker actors are invalid")
            self.approved_marker_actors = frozenset(approved_marker_actors)
        # These collectors are the trust boundary for evidence which GitHub's
        # ordinary REST API cannot provide (execution authorization, review
        # findings, the repository writer lease, and dependent-PR inventory).
        # The normal CLI has concrete repository-owned collectors for every
        # required source.  An integration may override one with a callable,
        # but a prepared request is never used as a fallback for live data.
        self._current_observation_time: str | None = None
        self.collectors: dict[str, Callable[..., object]] = {
            "execution": self._collect_execution,
            "findings": self._collect_findings,
            "writers": self._collect_writers,
            "dependent_prs": self._collect_dependents,
            "observation_time": self._collect_observation_time,
        }
        if collectors:
            self.collectors.update(collectors)

    @staticmethod
    def _subprocess_runner(
        argv: Sequence[str], input_text: str | None = None
    ) -> tuple[int, str, str]:
        completed = subprocess.run(
            list(argv),
            input=input_text,
            text=True,
            capture_output=True,
            check=False,
        )
        return completed.returncode, completed.stdout, completed.stderr

    def _call(
        self,
        endpoint: str,
        *,
        method: str = "GET",
        payload: dict[str, object] | None = None,
    ) -> object:
        if not endpoint.startswith("repos/"):
            raise ValueError("adoption endpoint must be repository-scoped")
        if method not in {"GET", "POST", "DELETE"}:
            raise ValueError("adoption transport method is not allowed")
        if method == "POST" and not (
            endpoint.endswith("/comments") or endpoint.endswith("/labels")
        ):
            raise ValueError("adoption transport write endpoint is not allowed")
        if method == "DELETE" and "/labels/" not in endpoint:
            raise ValueError("adoption transport delete endpoint is not allowed")
        argv = [
            "gh",
            "api",
            endpoint,
            "--method",
            method,
            "--header",
            "Accept: application/vnd.github+json",
        ]
        input_text = None
        if payload is not None:
            argv.extend(["--input", "-"])
            input_text = json.dumps(
                payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
            )
        raw = self.runner(argv, input_text)
        if isinstance(raw, tuple) and len(raw) == 3:
            return_code, stdout, stderr = raw
        elif isinstance(raw, subprocess.CompletedProcess):
            return_code, stdout, stderr = (
                raw.returncode,
                raw.stdout,
                raw.stderr,
            )
        else:
            raise RuntimeError("adoption transport runner returned invalid result")
        if return_code != 0:
            detail = str(stderr).strip() or f"gh api exited {return_code}"
            raise RuntimeError(detail)
        if method == "DELETE" and not str(stdout).strip():
            # GitHub returns 204 with an empty body for a successful label
            # deletion.  The narrow transport still treats the response code
            # as authoritative and does its own refetch/CAS below.
            return None
        try:
            return json.loads(str(stdout))
        except (TypeError, json.JSONDecodeError) as error:
            raise RuntimeError("gh api returned invalid JSON") from error

    def _graphql(self, query: str, variables: dict[str, object]) -> dict[str, object]:
        """Run one read-only, repository-scoped GraphQL query."""
        argv = [
            "gh",
            "api",
            "graphql",
            "-f",
            f"query={query}",
        ]
        for name, value in variables.items():
            flag = "-F" if isinstance(value, int) else "-f"
            argv.extend([flag, f"{name}={value}"])
        raw = self.runner(argv, None)
        if isinstance(raw, tuple) and len(raw) == 3:
            return_code, stdout, stderr = raw
        elif isinstance(raw, subprocess.CompletedProcess):
            return_code, stdout, stderr = raw.returncode, raw.stdout, raw.stderr
        else:
            raise RuntimeError("adoption transport runner returned invalid result")
        if return_code != 0:
            raise RuntimeError(str(stderr).strip() or "gh graphql exited non-zero")
        try:
            response = json.loads(str(stdout))
        except (TypeError, json.JSONDecodeError) as error:
            raise RuntimeError("gh graphql returned invalid JSON") from error
        if not isinstance(response, dict) or response.get("errors"):
            raise RuntimeError("gh graphql returned errors")
        data = response.get("data")
        if not isinstance(data, dict):
            raise RuntimeError("gh graphql response data is invalid")
        return data

    def _paginate(
        self, endpoint: str, *, collection_key: str | None = None
    ) -> list[object]:
        """Read every REST page and fail closed on an unbounded collection.

        Most GitHub REST collection endpoints return a JSON array.  The
        check-runs endpoint returns an object containing ``check_runs`` and a
        ``total_count`` instead.  Treating that object as an array silently
        loses the completeness boundary, so the expected total is checked on
        every page and against the final record count.
        """
        # Keep the public helper safe when callers use the endpoint directly:
        # the GitHub check-runs route is the one REST collection whose payload
        # is an object rather than a bare array.
        if collection_key is None and endpoint.split("?", 1)[0].endswith("/check-runs"):
            collection_key = "check_runs"
        records: list[object] = []
        expected_total: int | None = None
        for page in range(1, 101):
            separator = "&" if "?" in endpoint else "?"
            payload = self._call(f"{endpoint}{separator}per_page=100&page={page}")
            if collection_key is None:
                if not isinstance(payload, list):
                    raise RuntimeError("GitHub paginated payload is invalid")
                page_records = payload
            else:
                if not isinstance(payload, dict):
                    raise RuntimeError("GitHub object collection payload is invalid")
                total = payload.get("total_count")
                page_records = payload.get(collection_key)
                if type(total) is not int or total < 0:
                    raise RuntimeError("GitHub object collection total is invalid")
                if expected_total is None:
                    expected_total = total
                elif expected_total != total:
                    raise RuntimeError("GitHub object collection total changed")
                if not isinstance(page_records, list):
                    raise RuntimeError("GitHub object collection records are invalid")
            if len(page_records) > 100:
                raise RuntimeError("GitHub pagination page is oversized")
            records.extend(page_records)
            if len(page_records) < 100:
                if expected_total is not None and len(records) != expected_total:
                    raise RuntimeError("GitHub object collection count is incomplete")
                return records
        raise RuntimeError("GitHub pagination exceeded the safety limit")

    def _collector(
        self,
        name: str,
        repository: str,
        issue: int,
        pr: int,
        *,
        required: bool = True,
    ) -> object | None:
        collector = self.collectors.get(name)
        if collector is None:
            if required:
                raise RuntimeError(f"live collector missing: {name}")
            return None
        try:
            value = collector(repository, issue, pr)
        except TypeError as error:
            raise RuntimeError(f"live collector {name} has invalid signature") from error
        if value is None and required:
            raise RuntimeError(f"live collector returned no {name} evidence")
        return copy.deepcopy(value)

    @staticmethod
    def _collection_metadata(
        source: str,
        repository: str,
        pr: int,
        head_sha: str,
        records: list[object],
        **extra: object,
    ) -> dict[str, object]:
        return {
            "source": source,
            "repository": repository,
            "pr": pr,
            "head_sha": head_sha,
            "read_complete": True,
            "pagination_complete": True,
            "has_next_page": False,
            "count": len(records),
            "records": records,
            **extra,
        }

    @staticmethod
    def _items_metadata(
        source: str,
        repository: str,
        pr: int,
        head_sha: str,
        items: list[object],
        **extra: object,
    ) -> dict[str, object]:
        return {
            "source": source,
            "repository": repository,
            "pr": pr,
            "head_sha": head_sha,
            "read_complete": True,
            "pagination_complete": True,
            "has_next_page": False,
            "count": len(items),
            "items": items,
            **extra,
        }

    @staticmethod
    def _canonical_digest(value: object) -> str:
        payload = json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        return f"sha256:{hashlib.sha256(payload).hexdigest()}"

    @staticmethod
    def _execution_from_body(
        body: object,
        repository: str,
        issue: int,
        pr: int,
        operation: object,
        *,
        source_actor: str,
    ) -> dict[str, object]:
        if not isinstance(body, str):
            raise RuntimeError("GitHub issue execution metadata is missing")
        if not isinstance(source_actor, str) or not source_actor.strip():
            raise RuntimeError("GitHub issue execution authorization actor is invalid")
        matches = [match.group(1) for match in EXECUTION_MARKER.finditer(body)]
        if len(matches) != 1:
            raise RuntimeError("GitHub issue execution metadata is ambiguous")
        try:
            metadata = json.loads(matches[0])
        except json.JSONDecodeError as error:
            raise RuntimeError("GitHub issue execution metadata is invalid") from error
        if not isinstance(metadata, dict):
            raise RuntimeError("GitHub issue execution metadata is invalid")
        required = (
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
        legacy_required = {
            "approval_id",
            "plan_revision",
            "scope_hash",
            "executor",
        }
        if set(metadata) == legacy_required:
            raise RuntimeError("GitHub issue execution metadata uses legacy schema")
        if set(metadata) != set(required):
            raise RuntimeError("GitHub issue execution metadata has unexpected fields")
        if any(
            not isinstance(metadata.get(field), str)
            or not str(metadata.get(field)).strip()
            for field in (
                "repository",
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
        ):
            raise RuntimeError("GitHub issue execution metadata is incomplete")
        if type(metadata.get("issue")) is not int or type(metadata.get("pr")) is not int:
            raise RuntimeError("GitHub issue execution target is invalid")
        if (
            metadata.get("repository") != repository
            or metadata.get("issue") != issue
            or metadata.get("pr") != pr
        ):
            raise RuntimeError("GitHub issue execution target does not match")
        if any(
            not re.fullmatch(r"[0-9a-f]{40}", str(metadata[field]))
            for field in ("base_sha", "head_sha")
        ):
            raise RuntimeError("GitHub issue execution target SHA is invalid")
        if not re.fullmatch(
            r"sha256:[0-9a-f]{64}", str(metadata["evidence_digest"])
        ):
            raise RuntimeError("GitHub issue execution evidence digest is invalid")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(metadata["scope_hash"])):
            raise RuntimeError("GitHub issue execution scope hash is invalid")
        if not isinstance(operation, dict):
            raise RuntimeError("prepared operation is missing")
        return {
            "repository": repository,
            "issue": issue,
            "pr": pr,
            "base_repository": metadata["base_repository"],
            "base_ref": metadata["base_ref"],
            "base_sha": metadata["base_sha"],
            "head_repository": metadata["head_repository"],
            "head_ref": metadata["head_ref"],
            "head_sha": metadata["head_sha"],
            "evidence_digest": metadata["evidence_digest"],
            "approval_id": metadata["approval_id"],
            "plan_revision": metadata["plan_revision"],
            "scope_hash": metadata["scope_hash"],
            "executor": metadata["executor"],
            "source": "github-approved-workflow-comment-v1",
            "source_actor": source_actor,
            "policy_version": operation.get("policy_version"),
            "operation_version": operation.get("version"),
        }

    def _collect_execution(
        self, repository: str, issue: int, pr: int
    ) -> dict[str, object]:
        # An issue body is editable workflow input.  The authorization marker
        # is therefore accepted only from a complete issue comment authored by
        # the policy-owned actor allowlist, whose identity is returned by the
        # authenticated GitHub API response and carried into the evidence.
        if self.snapshot is None:
            raise RuntimeError("prepared snapshot is required")
        if not self.approved_marker_actors:
            raise RuntimeError("GitHub execution authorization actor allowlist is missing")
        comments = self._paginate(
            f"repos/{self._repository_path(repository)}/issues/{issue}/comments"
        )
        authorization = self.snapshot.get("authorization")
        expected_digest = (
            authorization.get("evidence_digest")
            if isinstance(authorization, dict)
            else None
        )
        if not isinstance(expected_digest, str) or not re.fullmatch(
            r"sha256:[0-9a-f]{64}", expected_digest
        ):
            raise RuntimeError("prepared authorization evidence digest is invalid")
        live_identity = self._pr_identity_from_pr(repository, pr)
        applicable: list[dict[str, object]] = []
        for comment in comments:
            if not isinstance(comment, dict) or not isinstance(comment.get("body"), str):
                continue
            user = comment.get("user")
            actor = user.get("login") if isinstance(user, dict) else None
            if not isinstance(actor, str) or actor not in self.approved_marker_actors:
                continue
            if EXECUTION_MARKER.search(comment["body"]):
                try:
                    execution = self._execution_from_body(
                        comment["body"],
                        repository,
                        issue,
                        pr,
                        self.snapshot.get("operation"),
                        source_actor=actor,
                    )
                except RuntimeError as error:
                    if str(error) in {
                        "GitHub issue execution target does not match",
                        "GitHub issue execution metadata uses legacy schema",
                    }:
                        continue
                    raise
                if execution.get("evidence_digest") != expected_digest:
                    continue
                if any(
                    execution.get(field) != live_identity.get(field)
                    for field in (
                        "base_repository",
                        "base_ref",
                        "base_sha",
                        "head_repository",
                        "head_ref",
                        "head_sha",
                    )
                ):
                    continue
                applicable.append(execution)
        if len(applicable) != 1:
            raise RuntimeError(
                "GitHub workflow execution authorization is missing or ambiguous"
            )
        return applicable[0]

    def _graphql_connection(
        self,
        query: str,
        variables: dict[str, object],
        path: tuple[str, ...],
    ) -> list[dict[str, object]]:
        """Read a complete GraphQL connection, rejecting partial pages."""
        records: list[dict[str, object]] = []
        cursor: str | None = None
        for _ in range(100):
            page_variables = dict(variables)
            if cursor is not None:
                page_variables["after"] = cursor
            data = self._graphql(query, page_variables)
            value: object = data
            for key in path:
                if not isinstance(value, dict):
                    raise RuntimeError("GitHub GraphQL collection path is invalid")
                value = value.get(key)
            if not isinstance(value, dict):
                raise RuntimeError("GitHub GraphQL collection is invalid")
            nodes = value.get("nodes")
            page_info = value.get("pageInfo")
            if not isinstance(nodes, list) or not all(
                isinstance(item, dict) for item in nodes
            ):
                raise RuntimeError("GitHub GraphQL collection nodes are invalid")
            if not isinstance(page_info, dict):
                raise RuntimeError("GitHub GraphQL collection page info is invalid")
            has_next = page_info.get("hasNextPage")
            next_cursor = page_info.get("endCursor")
            records.extend(nodes)
            if has_next is False:
                return records
            if has_next is not True or not isinstance(next_cursor, str) or not next_cursor:
                raise RuntimeError("GitHub GraphQL collection pagination is invalid")
            if next_cursor == cursor:
                raise RuntimeError("GitHub GraphQL collection cursor repeated")
            cursor = next_cursor
        raise RuntimeError("GitHub GraphQL collection exceeded the safety limit")

    @staticmethod
    def _finding_from_thread(
        thread: dict[str, object],
        head_sha: str,
        approved_marker_actors: frozenset[str] | None = None,
    ) -> dict[str, object] | None:
        # Keep the pure collector helper usable by deterministic fixtures that
        # call it directly.  The production transport always replaces this
        # fallback with the policy ledger's approved authors.
        if approved_marker_actors is None:
            approved_marker_actors = frozenset({"nerdchanii"})
        thread_id = thread.get("id")
        resolved = thread.get("isResolved")
        comments = thread.get("comments")
        if not isinstance(thread_id, str) or not thread_id.strip():
            raise RuntimeError("GitHub review thread identity is invalid")
        if type(resolved) is not bool:
            raise RuntimeError("GitHub review thread resolution state is invalid")
        if not isinstance(comments, dict):
            raise RuntimeError("GitHub review thread comments are incomplete")
        nodes = comments.get("nodes")
        page_info = comments.get("pageInfo")
        if not isinstance(nodes, list) or not isinstance(page_info, dict):
            raise RuntimeError("GitHub review thread comments are incomplete")
        if page_info.get("hasNextPage") is not False:
            raise RuntimeError("GitHub review thread comments are incomplete")
        markers: list[tuple[dict[str, object], str]] = []
        for comment in nodes:
            if not isinstance(comment, dict) or not isinstance(comment.get("body"), str):
                raise RuntimeError("GitHub review comment is invalid")
            for match in FINDING_MARKER.finditer(comment["body"]):
                author = comment.get("author")
                actor = author.get("login") if isinstance(author, dict) else None
                if (
                    not isinstance(actor, str)
                    or not actor.strip()
                    or actor not in approved_marker_actors
                ):
                    # Unapproved text is never evidence.  Resolved historical
                    # threads can therefore be ignored safely, while an
                    # unresolved thread with no trusted marker still fails the
                    # required-finding check below.
                    continue
                try:
                    value = json.loads(match.group(1))
                except json.JSONDecodeError as error:
                    raise RuntimeError("GitHub review finding metadata is invalid") from error
                if not isinstance(value, dict):
                    raise RuntimeError("GitHub review finding metadata is invalid")
                markers.append((value, actor))
        if len(markers) != 1:
            if resolved:
                # A resolved thread is historical evidence and does not
                # contribute an active finding.  Its marker authors were still
                # checked above so an attacker cannot hide an unauthorized
                # marker in a resolved thread.
                if len(markers) > 1:
                    raise RuntimeError("GitHub review finding metadata is ambiguous")
                return None
            raise RuntimeError("GitHub unresolved review thread finding metadata is missing or ambiguous")
        finding, actor = markers[0]
        finding = copy.deepcopy(finding)
        required = (
            "id",
            "source_id",
            "severity",
            "disposition",
            "owner",
            "head_sha",
        )
        if any(
            not isinstance(finding.get(field), str) or not str(finding.get(field)).strip()
            for field in required
        ):
            raise RuntimeError("GitHub review finding metadata is incomplete")
        if finding.get("head_sha") != head_sha:
            raise RuntimeError("GitHub review finding head mismatch")
        if finding.get("source_id") != thread_id:
            raise RuntimeError("GitHub review finding source does not match thread")
        if finding.get("thread_id") not in (None, thread_id):
            raise RuntimeError("GitHub review finding thread identity mismatch")
        if resolved:
            return None
        finding["thread_id"] = thread_id
        return finding

    def _collect_findings(
        self, repository: str, issue: int, pr: int
    ) -> dict[str, object]:
        owner, name = self._repository_path(repository).split("/", 1)
        head_payload = self._call(f"repos/{repository}/pulls/{pr}")
        head = head_payload.get("head") if isinstance(head_payload, dict) else None
        head_sha = head.get("sha") if isinstance(head, dict) else None
        if not isinstance(head_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", head_sha):
            raise RuntimeError("GitHub PR head SHA is invalid")
        query = """
          query($owner:String!, $name:String!, $pr:Int!, $after:String = null) {
            repository(owner:$owner, name:$name) {
              pullRequest(number:$pr) {
                reviewThreads(first:100, after:$after) {
                  nodes {
                    id
                    isResolved
                    comments(first:100) {
                      nodes { id body author { login } }
                      pageInfo { hasNextPage endCursor }
                    }
                  }
                  pageInfo { hasNextPage endCursor }
                }
              }
            }
          }
        """
        threads = self._graphql_connection(
            query,
            {"owner": owner, "name": name, "pr": pr},
            ("repository", "pullRequest", "reviewThreads"),
        )
        if not self.approved_marker_actors:
            raise RuntimeError("GitHub finding marker actor allowlist is missing")
        items: list[dict[str, object]] = []
        for thread in threads:
            finding = self._finding_from_thread(
                thread, head_sha, self.approved_marker_actors
            )
            if finding is not None:
                items.append(finding)
        return self._items_metadata(
            "current-head-review-findings-v1", repository, pr, head_sha, items
        )

    @staticmethod
    def _writer_records_from_text(
        text: object,
        repository: str,
        issue: int,
        pr: int | None,
        *,
        include_execution_lease: bool = False,
        head_sha: str | None = None,
        author: str | None = None,
        approved_marker_actors: frozenset[str] | None = None,
        source_comment_id: int | None = None,
    ) -> list[dict[str, object]]:
        if not isinstance(text, str):
            return []
        records: list[dict[str, object]] = []
        for match in WRITER_MARKER.finditer(text):
            if (
                approved_marker_actors is not None
                and (not isinstance(author, str) or author not in approved_marker_actors)
            ):
                continue
            try:
                value = json.loads(match.group(1))
            except json.JSONDecodeError as error:
                raise RuntimeError("GitHub writer metadata is invalid") from error
            if not isinstance(value, dict):
                raise RuntimeError("GitHub writer metadata is invalid")
            if value.get("kind") == "adoption" and source_comment_id is not None:
                value = copy.deepcopy(value)
                value["source_comment_id"] = source_comment_id
            records.append(value)
        if include_execution_lease:
            for match in EXECUTION_MARKER.finditer(text):
                if (
                    approved_marker_actors is not None
                    and (not isinstance(author, str) or author not in approved_marker_actors)
                ):
                    continue
                try:
                    metadata = json.loads(match.group(1))
                except json.JSONDecodeError as error:
                    raise RuntimeError("GitHub execution metadata is invalid") from error
                if not isinstance(metadata, dict):
                    raise RuntimeError("GitHub execution metadata is invalid")
                lease = metadata.get("lease")
                if lease is None:
                    continue
                if not isinstance(lease, dict):
                    raise RuntimeError("GitHub execution lease is invalid")
                if any(
                    not isinstance(lease.get(field), str)
                    or not str(lease.get(field)).strip()
                    for field in ("run_id", "owner", "expires_at")
                ):
                    raise RuntimeError("GitHub execution lease is incomplete")
                lease_head_sha = lease.get("head_sha")
                record_head_sha = head_sha
                if record_head_sha is None and isinstance(lease_head_sha, str):
                    record_head_sha = lease_head_sha
                if record_head_sha is not None and not re.fullmatch(
                    r"[0-9a-f]{40}", record_head_sha
                ):
                    raise RuntimeError("GitHub execution lease head is invalid")
                records.append(
                    {
                        "kind": "claim",
                        "repository": repository,
                        "issue": issue,
                        "pr": pr,
                        "run_id": lease["run_id"],
                        "owner": lease["owner"],
                        "lease_expires_at": lease["expires_at"],
                        "head_sha": record_head_sha,
                    }
                )
        return records

    @staticmethod
    def _writer_record_from_execution(
        execution: object,
        repository: str,
        issue: int,
        pr: int | None,
        head_sha: str | None,
    ) -> dict[str, object] | None:
        if not isinstance(execution, dict):
            return None
        lease = execution.get("lease")
        if lease is None:
            return None
        if not isinstance(lease, dict) or any(
            not isinstance(lease.get(field), str) or not str(lease.get(field)).strip()
            for field in ("run_id", "owner", "expires_at")
        ):
            raise RuntimeError("GitHub execution lease is incomplete")
        lease_head_sha = lease.get("head_sha")
        record_head_sha = head_sha
        if record_head_sha is None and isinstance(lease_head_sha, str):
            record_head_sha = lease_head_sha
        if record_head_sha is not None and not re.fullmatch(
            r"[0-9a-f]{40}", record_head_sha
        ):
            raise RuntimeError("GitHub execution lease head is invalid")
        return {
            "kind": "claim",
            "repository": repository,
            "issue": issue,
            "pr": pr,
            "run_id": lease["run_id"],
            "owner": lease["owner"],
            "lease_expires_at": lease["expires_at"],
            "head_sha": record_head_sha,
        }

    def _collect_writers(
        self, repository: str, issue: int, pr: int
    ) -> dict[str, object]:
        # Writer leases are repository-global.  GitHub has no native lease
        # endpoint, so the repository contract stores signed inventory records
        # in issue/PR bodies or comments.  Read the complete open issue/PR set
        # and every comment page; an API failure remains fail-closed.
        if not self.approved_marker_actors:
            raise RuntimeError("GitHub writer marker actor allowlist is missing")
        target_head_sha = self._head_sha_from_pr(repository, pr)
        all_items = self._paginate(
            f"repos/{self._repository_path(repository)}/issues?state=open"
        )
        records: list[dict[str, object]] = []
        for item in all_items:
            if not isinstance(item, dict) or not isinstance(item.get("number"), int):
                raise RuntimeError("GitHub open-item inventory is invalid")
            number = int(item["number"])
            labels = item.get("labels")
            if not isinstance(labels, list):
                raise RuntimeError("GitHub writer issue labels are invalid")
            lifecycle_labels = {
                label.get("name")
                for label in labels
                if isinstance(label, dict) and isinstance(label.get("name"), str)
            }
            writer_pr = pr if number == issue else None
            writer_head_sha = target_head_sha if number == issue else None
            item_records: list[dict[str, object]] = []
            execution_record = self._writer_record_from_execution(
                item.get("execution"),
                repository,
                number,
                writer_pr,
                writer_head_sha,
            )
            if execution_record is not None:
                item_records.append(execution_record)
            item_user = item.get("user")
            item_author = (
                item_user.get("login") if isinstance(item_user, dict) else None
            )
            item_records.extend(
                self._writer_records_from_text(
                    item.get("body"),
                    repository,
                    number,
                    writer_pr,
                    include_execution_lease=True,
                    head_sha=writer_head_sha,
                    author=item_author,
                    approved_marker_actors=self.approved_marker_actors,
                )
            )
            comments = self._paginate(
                f"repos/{self._repository_path(repository)}/issues/{number}/comments"
            )
            for comment in comments:
                if not isinstance(comment, dict):
                    raise RuntimeError("GitHub writer comment inventory is invalid")
                comment_id = comment.get("id")
                if type(comment_id) is not int or comment_id <= 0:
                    raise RuntimeError("GitHub writer comment identity is invalid")
                comment_user = comment.get("user")
                comment_author = (
                    comment_user.get("login")
                    if isinstance(comment_user, dict)
                    else None
                )
                item_records.extend(
                    self._writer_records_from_text(
                        comment.get("body"),
                        repository,
                        number,
                        writer_pr,
                        include_execution_lease=True,
                        head_sha=writer_head_sha,
                        author=comment_author,
                        approved_marker_actors=self.approved_marker_actors,
                        source_comment_id=comment_id,
                    )
                )
            if "agent:claimed" in lifecycle_labels and not any(
                record.get("kind") == "claim" for record in item_records
            ):
                # A claim lease is part of the active-writer safety boundary.
                # An older claimer or an incomplete connector response must
                # stop adoption instead of allowing an unobserved worker.
                raise RuntimeError("GitHub active claim lease is missing")
            records.extend(item_records)
        records.sort(
            key=lambda record: json.dumps(
                record,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        observed_at = self._current_observation_time
        if not isinstance(observed_at, str) or not observed_at.strip():
            observed_at = self._collect_observation_time(repository, issue, pr)
        return self._collection_metadata(
            "repository-global-writer-inventory-v1",
            repository,
            pr,
            target_head_sha,
            records,
            observed_at=observed_at,
            cas_token=self._canonical_digest({"repository": repository, "records": records}),
        )

    def _head_sha_from_pr(self, repository: str, pr: int) -> str:
        return str(self._pr_identity_from_pr(repository, pr)["head_sha"])

    def _pr_identity_from_pr(
        self, repository: str, pr: int
    ) -> dict[str, str]:
        payload = self._call(f"repos/{self._repository_path(repository)}/pulls/{pr}")
        base = payload.get("base") if isinstance(payload, dict) else None
        head = payload.get("head") if isinstance(payload, dict) else None
        base_repo = base.get("repo") if isinstance(base, dict) else None
        head_repo = head.get("repo") if isinstance(head, dict) else None
        identity = {
            "base_repository": base_repo.get("full_name")
            if isinstance(base_repo, dict)
            else None,
            "base_ref": base.get("ref") if isinstance(base, dict) else None,
            "base_sha": base.get("sha") if isinstance(base, dict) else None,
            "head_repository": head_repo.get("full_name")
            if isinstance(head_repo, dict)
            else None,
            "head_ref": head.get("ref") if isinstance(head, dict) else None,
            "head_sha": head.get("sha") if isinstance(head, dict) else None,
        }
        if any(not isinstance(value, str) or not value for value in identity.values()):
            raise RuntimeError("GitHub PR ref identity is invalid")
        if identity["base_repository"] != repository:
            raise RuntimeError("GitHub PR base repository identity is invalid")
        for field in ("base_sha", "head_sha"):
            if not re.fullmatch(r"[0-9a-f]{40}", str(identity[field])):
                raise RuntimeError("GitHub PR ref SHA is invalid")
        return {field: str(value) for field, value in identity.items()}

    def _head_transition_timestamp(
        self,
        repository: str,
        pr: int,
        head_sha: str,
        *,
        updated_at: object = None,
    ) -> str:
        """Return the timestamp at which the selected head became current.

        A force-push can select an old commit whose commit timestamp predates
        a review reaction.  The timeline's head-ref transition is the
        authoritative freshness boundary for that case.  GitHub does not emit
        a head-ref timeline event for every ordinary fast-forward push, so the
        PR's ``updated_at`` high-water mark is the conservative fallback.  A
        commit-authored timestamp cannot establish when that SHA became the
        selected PR head and is therefore never used for freshness.
        """
        events = self._paginate(
            f"repos/{self._repository_path(repository)}/issues/{pr}/timeline"
        )
        transition_timestamps: list[tuple[datetime, str]] = []
        for event in events:
            if not isinstance(event, dict):
                raise RuntimeError("GitHub PR timeline event is invalid")
            if event.get("event") not in {
                "head_ref_force_pushed",
                "head_ref_restored",
            }:
                continue
            if event.get("commit_id") != head_sha:
                continue
            created_at = event.get("created_at")
            if not isinstance(created_at, str) or not created_at.strip():
                raise RuntimeError("GitHub head transition timestamp is missing")
            try:
                parsed = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
            except ValueError as error:
                raise RuntimeError(
                    "GitHub head transition timestamp is invalid"
                ) from error
            if parsed.tzinfo is None:
                raise RuntimeError("GitHub head transition timestamp is invalid")
            transition_timestamps.append((parsed.astimezone(timezone.utc), created_at))
        if transition_timestamps:
            return max(transition_timestamps, key=lambda item: item[0])[1]
        if not isinstance(updated_at, str) or not updated_at.strip():
            raise RuntimeError("GitHub head transition timestamp is unavailable")
        try:
            parsed_updated_at = datetime.fromisoformat(
                updated_at.replace("Z", "+00:00")
            )
        except ValueError as error:
            raise RuntimeError(
                "GitHub head transition timestamp is invalid"
            ) from error
        if parsed_updated_at.tzinfo is None:
            raise RuntimeError("GitHub head transition timestamp is invalid")
        return updated_at

    def _collect_observation_time(
        self, repository: str, issue: int, pr: int
    ) -> str:
        # The prepared request's ``now`` is authorization input and may be
        # stale or caller-controlled.  Capture one real instant for this
        # refetch and let the writer inventory reuse it through
        # ``_current_observation_time``.
        if self._current_observation_time is None:
            observed = self.observation_clock()
            if not isinstance(observed, datetime) or observed.tzinfo is None:
                raise RuntimeError("live observation clock returned invalid time")
            self._current_observation_time = observed.astimezone(timezone.utc).isoformat().replace(
                "+00:00", "Z"
            )
        return self._current_observation_time

    def _collect_dependents(
        self, repository: str, issue: int, pr: int
    ) -> dict[str, object]:
        owner, name = self._repository_path(repository).split("/", 1)
        target_payload = self._call(f"repos/{repository}/pulls/{pr}")
        target_head = target_payload.get("head") if isinstance(target_payload, dict) else None
        target_head_ref = target_head.get("ref") if isinstance(target_head, dict) else None
        target_head_sha = target_head.get("sha") if isinstance(target_head, dict) else None
        if not isinstance(target_head_ref, str) or not isinstance(target_head_sha, str):
            raise RuntimeError("GitHub selected PR head is incomplete")
        query = """
          query($owner:String!, $name:String!, $after:String = null) {
            repository(owner:$owner, name:$name) {
              pullRequests(states:OPEN, first:100, after:$after) {
                nodes {
                  number
                  state
                  baseRefName
                  baseRefOid
                  headRefName
                  headRefOid
                  repository { nameWithOwner }
                  baseRepository { nameWithOwner }
                  headRepository { nameWithOwner }
                }
                pageInfo { hasNextPage endCursor }
              }
            }
          }
        """
        prs = self._graphql_connection(
            query,
            {"owner": owner, "name": name},
            ("repository", "pullRequests"),
        )
        records: list[dict[str, object]] = []
        for value in prs:
            if not isinstance(value, dict):
                raise RuntimeError("GitHub dependent PR record is invalid")
            number = value.get("number")
            base_ref = value.get("baseRefName")
            base_sha = value.get("baseRefOid")
            head_ref = value.get("headRefName")
            head_sha = value.get("headRefOid")
            base_repo = value.get("baseRepository")
            head_repo = value.get("headRepository")
            # Only PRs based on the selected head branch are dependents.  An
            # unrelated fork PR must not fail the inventory before that
            # relationship is established.
            if number == pr or base_ref != target_head_ref:
                continue
            if (
                not isinstance(number, int)
                or not isinstance(base_ref, str)
                or not isinstance(base_sha, str)
                or not isinstance(head_ref, str)
                or not isinstance(head_sha, str)
                or not isinstance(base_repo, dict)
                or not isinstance(head_repo, dict)
                or base_repo.get("nameWithOwner") != repository
                or head_repo.get("nameWithOwner") != repository
            ):
                raise RuntimeError("GitHub dependent PR identity is incomplete")
            records.append(
                {
                    "number": number,
                    "state": "OPEN",
                    "repository": repository,
                    "base_ref": base_ref,
                    "base_sha": base_sha,
                    "head_ref": head_ref,
                    "head_sha": head_sha,
                }
            )
        return self._collection_metadata(
            "repository-open-pr-base-inventory-v1",
            repository,
            pr,
            target_head_sha,
            records,
        )

    @staticmethod
    def _validate_injected_collection(
        value: object,
        *,
        name: str,
        repository: str,
        pr: int,
        head_sha: str,
        required_source: str,
    ) -> dict[str, object]:
        if not isinstance(value, dict):
            raise RuntimeError(f"live {name} evidence is invalid")
        if (
            value.get("source") != required_source
            or value.get("repository") != repository
            or value.get("pr") != pr
            or value.get("head_sha") != head_sha
            or value.get("read_complete") is not True
            or value.get("pagination_complete") is not True
            or value.get("has_next_page") is not False
            or not isinstance(value.get("records"), list)
            or value.get("count") != len(value.get("records", []))
        ):
            raise RuntimeError(f"live {name} evidence is incomplete or unbound")
        return value

    @staticmethod
    def _validate_items_collection(
        value: object,
        *,
        name: str,
        repository: str,
        pr: int,
        head_sha: str,
        required_source: str,
    ) -> dict[str, object]:
        if not isinstance(value, dict):
            raise RuntimeError(f"live {name} evidence is invalid")
        if (
            value.get("source") != required_source
            or value.get("repository") != repository
            or value.get("pr") != pr
            or value.get("head_sha") != head_sha
            or value.get("read_complete") is not True
            or value.get("pagination_complete") is not True
            or value.get("has_next_page") is not False
            or not isinstance(value.get("items"), list)
            or value.get("count") != len(value.get("items", []))
        ):
            raise RuntimeError(f"live {name} evidence is incomplete or unbound")
        return value

    @staticmethod
    def _repository_path(repository: str) -> str:
        parts = repository.split("/")
        if len(parts) != 2 or any(
            not part or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_." for char in part)
            for part in parts
        ):
            raise ValueError("repository identity is invalid")
        return repository

    def _read_state(
        self,
        repository: str,
        issue: int,
        pr: int,
        *,
        allow_lifecycle_conflict: bool = False,
        allow_ordinary_label_conflict: bool = False,
    ) -> dict[str, object]:
        if self.snapshot is None:
            raise RuntimeError("prepared snapshot is required")
        repository = self._repository_path(repository)
        if issue <= 0 or pr <= 0:
            raise ValueError("issue and PR numbers must be positive")

        state = copy.deepcopy(self.snapshot)
        # A retry is a new live observation.  Never reuse the prior read's
        # timestamp when the same transport instance is used again.
        self._current_observation_time = None
        issue_payload = self._call(f"repos/{repository}/issues/{issue}")
        pr_payload = self._call(f"repos/{repository}/pulls/{pr}")
        comments_payload = self._paginate(
            f"repos/{repository}/issues/{issue}/comments"
        )
        owner, name = repository.split("/", 1)
        closing_data = self._graphql(
            """
            query($owner:String!, $name:String!, $issue:Int!, $pr:Int!) {
              repository(owner:$owner, name:$name) {
                issue(number:$issue) {
                  closedByPullRequestsReferences(first:100) {
                    nodes { number repository { nameWithOwner } }
                    pageInfo { hasNextPage }
                  }
                }
                pullRequest(number:$pr) {
                  closingIssuesReferences(first:100) {
                    nodes { number repository { nameWithOwner } }
                    pageInfo { hasNextPage }
                  }
                }
              }
            }
            """,
            {"owner": owner, "name": name, "issue": issue, "pr": pr},
        )
        if not isinstance(issue_payload, dict) or not isinstance(pr_payload, dict):
            raise RuntimeError("GitHub issue/PR payload is invalid")
        if issue_payload.get("number") != issue or pr_payload.get("number") != pr:
            raise RuntimeError("GitHub issue/PR number mismatch")
        issue_repository_payload = issue_payload.get("repository")
        issue_repository = (
            issue_repository_payload.get("full_name")
            if isinstance(issue_repository_payload, dict)
            else None
        )
        if issue_repository is None:
            repository_url = issue_payload.get("repository_url")
            expected_url = f"https://api.github.com/repos/{repository}"
            if repository_url != expected_url:
                raise RuntimeError("GitHub issue repository identity is incomplete")
        elif issue_repository != repository:
            raise RuntimeError("GitHub issue repository identity mismatch")
        repository_data = closing_data.get("repository")
        if not isinstance(repository_data, dict):
            raise RuntimeError("GitHub closing-reference payload is invalid")
        issue_refs = repository_data.get("issue", {})
        pr_refs = repository_data.get("pullRequest", {})
        issue_refs = issue_refs.get("closedByPullRequestsReferences") if isinstance(issue_refs, dict) else None
        pr_refs = pr_refs.get("closingIssuesReferences") if isinstance(pr_refs, dict) else None
        if not isinstance(issue_refs, dict) or not isinstance(pr_refs, dict):
            raise RuntimeError("GitHub closing-reference collection is incomplete")
        issue_page = issue_refs.get("pageInfo")
        pr_page = pr_refs.get("pageInfo")
        if (
            not isinstance(issue_refs.get("nodes"), list)
            or not isinstance(pr_refs.get("nodes"), list)
            or not isinstance(issue_page, dict)
            or not isinstance(pr_page, dict)
            or issue_page.get("hasNextPage") is not False
            or pr_page.get("hasNextPage") is not False
        ):
            raise RuntimeError("GitHub closing-reference pagination is incomplete")
        live_closing_prs: list[int] = []
        for item in issue_refs["nodes"]:
            if not isinstance(item, dict) or not isinstance(item.get("number"), int):
                raise RuntimeError("GitHub closing PR identity is invalid")
            repo_info = item.get("repository")
            if not isinstance(repo_info, dict) or repo_info.get("nameWithOwner") != repository:
                raise RuntimeError("GitHub closing PR repository mismatch")
            live_closing_prs.append(int(item["number"]))
        live_closing_issues: list[dict[str, object]] = []
        for item in pr_refs["nodes"]:
            if not isinstance(item, dict) or not isinstance(item.get("number"), int):
                raise RuntimeError("GitHub closing issue identity is invalid")
            repo_info = item.get("repository")
            if not isinstance(repo_info, dict) or repo_info.get("nameWithOwner") != repository:
                raise RuntimeError("GitHub closing issue repository mismatch")
            live_closing_issues.append(
                {"repository": repository, "number": int(item["number"])}
            )
        raw_labels = issue_payload.get("labels")
        if not isinstance(raw_labels, list) or any(
            not isinstance(item, dict) or not isinstance(item.get("name"), str)
            for item in raw_labels
        ):
            raise RuntimeError("GitHub issue labels payload is incomplete")
        issue_labels = sorted(str(item["name"]) for item in raw_labels)
        base_payload = pr_payload.get("base")
        head_payload = pr_payload.get("head")
        if not isinstance(base_payload, dict) or not isinstance(head_payload, dict):
            raise RuntimeError("GitHub PR ref payload is incomplete")
        base_repo = base_payload.get("repo")
        head_repo = head_payload.get("repo")
        base_repository = base_repo.get("full_name") if isinstance(base_repo, dict) else None
        head_repository = head_repo.get("full_name") if isinstance(head_repo, dict) else None
        if base_repository != repository:
            raise RuntimeError("GitHub PR repository identity mismatch")
        try:
            self._repository_path(str(head_repository))
        except (TypeError, ValueError) as error:
            raise RuntimeError("GitHub PR head repository identity is invalid") from error
        head_sha = head_payload.get("sha")
        base_sha = base_payload.get("sha")
        if (
            not isinstance(head_sha, str)
            or not isinstance(base_sha, str)
            or not re.fullmatch(r"[0-9a-f]{40}", head_sha)
            or not re.fullmatch(r"[0-9a-f]{40}", base_sha)
            or not isinstance(base_payload.get("ref"), str)
            or not isinstance(head_payload.get("ref"), str)
        ):
            raise RuntimeError("GitHub PR SHA payload is incomplete")

        # A prepared request may identify the target, but it cannot supply
        # any of the mutable evidence used by a writer phase.  The standard
        # REST calls cover checks and reviews; the remaining evidence must be
        # supplied by explicitly injected, independently fetched collectors.
        bundle = self._collector("evidence", repository, issue, pr, required=False)
        if bundle is not None:
            if not isinstance(bundle, dict):
                raise RuntimeError("live evidence bundle is invalid")
            external: dict[str, object] = bundle
        else:
            # Observation time is collected before the repository-global
            # writer inventory so both values are bound to the same prepared
            # selected-head observation.  A custom collector must provide the
            # same explicit value on every retry.
            observation_time = self._collector(
                "observation_time", repository, issue, pr
            )
            if not isinstance(observation_time, str) or not observation_time.strip():
                raise RuntimeError("live observation time is missing")
            self._current_observation_time = observation_time
            external = {
                name: self._collector(name, repository, issue, pr)
                for name in (
                    "execution",
                    "findings",
                    "writers",
                    "dependent_prs",
                )
            }
            external["observation_time"] = observation_time
            for optional_name in ("checks", "review", "reactions"):
                if optional_name in self.collectors:
                    external[optional_name] = self._collector(
                        optional_name, repository, issue, pr
                    )

        checks_value = external.get("checks")
        if checks_value is None:
            check_records = self._paginate(
                f"repos/{repository}/commits/{head_sha}/check-runs",
                collection_key="check_runs",
            )
            checks: dict[str, object] = self._collection_metadata(
                "github-check-runs-v1",
                repository,
                pr,
                head_sha,
                check_records,
            )
            normalized_checks: list[dict[str, object]] = []
            for item in check_records:
                if not isinstance(item, dict):
                    raise RuntimeError("GitHub check-run record is invalid")
                app = item.get("app")
                name = item.get("name")
                status = item.get("status")
                conclusion = item.get("conclusion")
                run_id = item.get("id")
                if (
                    not isinstance(name, str)
                    or not name.strip()
                    or not isinstance(status, str)
                    or (conclusion is not None and not isinstance(conclusion, str))
                    or not isinstance(run_id, int)
                ):
                    raise RuntimeError("GitHub check-run record is incomplete")
                normalized_checks.append(
                    {
                        "name": name,
                        "status": status,
                        "conclusion": conclusion,
                        "head_sha": head_sha,
                        "source": "github-actions"
                        if isinstance(app, dict)
                        and app.get("slug") == "github-actions"
                        else "unknown",
                        "workflow_run_id": run_id,
                    }
                )
            checks["records"] = normalized_checks
        else:
            checks = self._validate_injected_collection(
                checks_value,
                name="checks",
                repository=repository,
                pr=pr,
                head_sha=head_sha,
                required_source="github-check-runs-v1",
            )

        review_value = external.get("review")
        if review_value is None:
            review_records = self._paginate(
                f"repos/{repository}/pulls/{pr}/reviews"
            )
            reaction_records = self._paginate(
                f"repos/{repository}/issues/{pr}/reactions"
            )
            automatic: list[dict[str, object]] = []
            for item in review_records:
                if not isinstance(item, dict):
                    raise RuntimeError("GitHub review record is invalid")
                user = item.get("user")
                actor = user.get("login") if isinstance(user, dict) else None
                submitted_at = item.get("submitted_at")
                commit_id = item.get("commit_id")
                state_name = item.get("state")
                if not all(
                    isinstance(value, str) and value
                    for value in (actor, submitted_at, commit_id, state_name)
                ):
                    raise RuntimeError("GitHub review record is incomplete")
                automatic.append(
                    {
                        "actor": actor,
                        "submitted_at": submitted_at,
                        "reviewed_head_sha": commit_id,
                        "state": state_name,
                        # GitHub's REST review endpoint does not expose the
                        # connector's finding count.  Keep it unknown until
                        # the independently collected findings inventory is
                        # available.
                        "finding_count": item.get("finding_count"),
                    }
                )
            reactions: list[dict[str, object]] = []
            for item in reaction_records:
                if not isinstance(item, dict):
                    raise RuntimeError("GitHub reaction record is invalid")
                user = item.get("user")
                actor = user.get("login") if isinstance(user, dict) else None
                created_at = item.get("created_at")
                content = item.get("content")
                if not all(
                    isinstance(value, str) and value
                    for value in (actor, created_at, content)
                ):
                    raise RuntimeError("GitHub reaction record is incomplete")
                reactions.append(
                    {
                        "actor": actor,
                        "created_at": created_at,
                        "content": content,
                        "head_sha": head_sha,
                        "deleted": False,
                    }
                )
            head_updated_at = self._head_transition_timestamp(
                repository,
                pr,
                head_sha,
                updated_at=pr_payload.get("updated_at"),
            )
            review = {
                "repository": repository,
                "pr": pr,
                "head_sha": head_sha,
                "head_updated_at": head_updated_at,
                "automatic_reviews": {
                    "source": "github-pull-request-reviews-v1",
                    "repository": repository,
                    "pr": pr,
                    "head_sha": head_sha,
                    "read_complete": True,
                    "pagination_complete": True,
                    "has_next_page": False,
                    "count": len(automatic),
                    "records": automatic,
                },
                "reactions": {
                    "source": "github-pull-request-reactions-v1",
                    "repository": repository,
                    "pr": pr,
                    "head_sha": head_sha,
                    "read_complete": True,
                    "pagination_complete": True,
                    "has_next_page": False,
                    "count": len(reactions),
                    "records": reactions,
                },
            }
        else:
            if not isinstance(review_value, dict):
                raise RuntimeError("live review evidence is invalid")
            review = copy.deepcopy(review_value)
            if (
                review.get("repository") != repository
                or review.get("pr") != pr
                or review.get("head_sha") != head_sha
            ):
                raise RuntimeError("live review evidence is unbound")
            if "reactions" in external:
                reaction_value = external["reactions"]
                reaction = self._validate_injected_collection(
                    reaction_value,
                    name="reactions",
                    repository=repository,
                    pr=pr,
                    head_sha=head_sha,
                    required_source="github-pull-request-reactions-v1",
                )
                review["reactions"] = reaction

        findings = self._validate_items_collection(
            external.get("findings"),
            name="findings",
            repository=repository,
            pr=pr,
            head_sha=head_sha,
            required_source="current-head-review-findings-v1",
        )
        automatic_reviews = review.get("automatic_reviews")
        if isinstance(automatic_reviews, dict):
            finding_items = findings.get("items")
            if isinstance(finding_items, list) and not finding_items:
                # REST review payloads omit the connector-only finding count.
                # An independently complete empty findings inventory provides
                # the deterministic zero value used by the prepared digest.
                for item in automatic_reviews.get("records", []):
                    if isinstance(item, dict) and item.get("finding_count") is None:
                        item["finding_count"] = 0
        writers = self._validate_injected_collection(
            external.get("writers"),
            name="writers",
            repository=repository,
            pr=pr,
            head_sha=head_sha,
            required_source="repository-global-writer-inventory-v1",
        )
        dependent_prs = self._validate_injected_collection(
            external.get("dependent_prs"),
            name="dependent-PR",
            repository=repository,
            pr=pr,
            head_sha=head_sha,
            required_source="repository-open-pr-base-inventory-v1",
        )
        execution = external.get("execution")
        if not isinstance(execution, dict):
            raise RuntimeError("live execution authorization is invalid")
        operation = state.get("operation")
        if not isinstance(operation, dict):
            raise RuntimeError("prepared operation is missing")
        if any(
            not isinstance(execution.get(field), str)
            or not str(execution.get(field)).strip()
            for field in ("approval_id", "plan_revision", "scope_hash", "executor")
        ):
            raise RuntimeError("live execution authorization is incomplete")
        if (
            execution.get("source")
            != "github-approved-workflow-comment-v1"
            or execution.get("source_actor") not in self.approved_marker_actors
        ):
            raise RuntimeError("live execution authorization source is untrusted")
        if (
            execution.get("repository") != repository
            or execution.get("issue") != issue
            or execution.get("pr") != pr
            or execution.get("base_repository") != base_repository
            or execution.get("base_ref") != base_payload.get("ref")
            or execution.get("base_sha") != base_sha
            or execution.get("head_repository") != head_repository
            or execution.get("head_ref") != head_payload.get("ref")
            or execution.get("head_sha") != head_sha
            or execution.get("policy_version") != operation.get("policy_version")
            or execution.get("operation_version") != operation.get("version")
        ):
            raise RuntimeError("live execution authorization is unbound")
        observation_time = external.get("observation_time")
        if not isinstance(observation_time, str) or not observation_time.strip():
            raise RuntimeError("live observation time is missing")
        state["now"] = observation_time
        if state.get("now") != observation_time:
            raise RuntimeError("live observation time mismatch")
        if writers.get("observed_at") != observation_time:
            raise RuntimeError("live writer observation mismatch")
        lifecycle_by_label = {
            "agent:research": "research",
            "agent:ready": "ready",
            "agent:claimed": "claimed",
            "agent:review-pending": "review-pending",
            "agent:" + "awaiting-merge": "awaiting-merge",
            "agent:blocked": "blocked",
        }
        matched_states = sorted(
            state_name
            for label, state_name in lifecycle_by_label.items()
            if label in issue_labels
        )
        lifecycle_state = matched_states[0] if len(matched_states) == 1 else (
            "invalid" if matched_states else "untracked"
        )
        state["live"] = {
            "head_sha": head_sha,
            "base_sha": base_sha,
            "lifecycle_state": lifecycle_state,
            "issue_labels": issue_labels,
        }

        # Replace every mutable evidence subtree with an independently fetched
        # value.  The prepared snapshot is an authorization input only; it is
        # never a fallback for a missing live source.  Rebuild the identity
        # records from the REST/GraphQL responses instead of mutating prepared
        # dictionaries, so an unrecognised prepared field cannot enter the
        # writer CAS or its evidence digest.
        prepared_evidence = state.get("evidence")
        if not isinstance(prepared_evidence, dict):
            raise RuntimeError("prepared evidence is missing")
        prepared_repository = prepared_evidence.get("repository")
        prepared_issue = prepared_evidence.get("issue")
        prepared_pr = prepared_evidence.get("pr")
        if not all(
            isinstance(value, dict)
            for value in (prepared_repository, prepared_issue, prepared_pr)
        ):
            raise RuntimeError("prepared identity evidence is missing")
        assert (
            isinstance(prepared_repository, dict)
            and isinstance(prepared_issue, dict)
            and isinstance(prepared_pr, dict)
        )
        if (
            prepared_repository.get("name_with_owner") != repository
            or prepared_repository.get("read_complete") is not True
        ):
            raise RuntimeError("live repository evidence is incomplete")
        live_state = str(issue_payload.get("state", "")).upper()
        if live_state not in {"OPEN", "CLOSED"}:
            raise RuntimeError("GitHub issue state is invalid")
        prepared_labels = prepared_issue.get("labels")
        prepared_ordinary = (
            sorted(
                label
                for label in prepared_labels
                if isinstance(label, str) and not label.startswith("agent:")
            )
            if isinstance(prepared_labels, list)
            else []
        )
        live_ordinary = sorted(
            label for label in issue_labels if not label.startswith("agent:")
        )
        live_lifecycle = sorted(
            label for label in issue_labels if label.startswith("agent:")
        )
        if live_ordinary != prepared_ordinary and not allow_ordinary_label_conflict:
            raise RuntimeError("GitHub issue ordinary labels changed")
        if (
            not allow_lifecycle_conflict
            and live_lifecycle not in ([], ["agent:" + "review-pending"])
        ):
            raise RuntimeError("GitHub issue lifecycle labels are ambiguous")
        prepared_lifecycle = sorted(
            label
            for label in prepared_labels
            if isinstance(label, str) and label.startswith("agent:")
        ) if isinstance(prepared_labels, list) else []
        if prepared_lifecycle not in ([], ["agent:review-pending"]):
            raise RuntimeError("prepared issue lifecycle labels are ambiguous")
        prepared_state = prepared_issue.get("lifecycle_state")
        if prepared_state not in (None, "untracked", "review-pending"):
            raise RuntimeError("prepared issue lifecycle state is invalid")
        if (
            prepared_state == "review-pending"
            and prepared_lifecycle != ["agent:review-pending"]
        ) or (
            prepared_state in (None, "untracked") and prepared_lifecycle
        ):
            raise RuntimeError("prepared issue lifecycle state is unbound")
        pr_state = str(pr_payload.get("state", "")).upper()
        if pr_state not in {"OPEN", "CLOSED"}:
            raise RuntimeError("GitHub PR state is invalid")
        draft = pr_payload.get("draft")
        if type(draft) is not bool:
            raise RuntimeError("GitHub PR draft state is invalid")
        live_issue = {
            "repository": repository,
            "number": issue,
            "state": live_state,
            # Keep the current labels visible to the reconciliation contract.
            # The digest used by the immutable authorization is normalized by
            # adoption_evidence_digest below, which permits only the one
            # authorized lifecycle-label delta.
            "labels": issue_labels,
            "lifecycle_state": lifecycle_state,
            "closing_prs_complete": True,
            "closing_prs": sorted(live_closing_prs),
        }
        live_pr = {
            "repository": repository,
            "number": pr,
            "state": pr_state,
            "is_draft": draft,
            "base": {
                "repository": repository,
                "ref": base_payload.get("ref"),
                "sha": base_sha,
            },
            "head": {
                "repository": head_repository,
                "ref": head_payload.get("ref"),
                "sha": head_sha,
            },
            "closing_issues": live_closing_issues,
            "closing_issues_complete": True,
        }
        evidence: dict[str, object] = {
            "repository": {
                "name_with_owner": repository,
                "read_complete": True,
            },
            "issue": live_issue,
            "pr": live_pr,
            "checks": checks,
            "review": review,
            "findings": findings,
            "writers": writers,
            "dependent_prs": dependent_prs,
            "execution": execution,
        }
        queue = runpy.run_path(str(ROOT / "scripts/check-cloud-queue-contract.py"))
        if (
            not allow_ordinary_label_conflict
            and execution.get("evidence_digest")
            != queue["adoption_evidence_digest"](evidence)
        ):
            raise RuntimeError("live execution authorization evidence digest changed")
        state["evidence"] = evidence
        state["closing_pr_inventory"] = {
            "repository": repository,
            "source": "repository-open-closing-pr-inventory-v1",
            "read_complete": True,
            "pagination_complete": True,
            "has_next_page": False,
            "count": len(live_closing_prs),
            "records": [
                {
                    "repository": repository,
                    "issue": issue,
                    "pr": number,
                    **(
                        {
                            "base_ref": base_payload.get("ref"),
                            "base_sha": base_sha,
                            "head_ref": head_payload.get("ref"),
                            "head_sha": head_sha,
                        }
                        if number == pr
                        else {}
                    ),
                }
                for number in sorted(live_closing_prs)
            ],
        }
        live_authorization = state.get("authorization")
        if not isinstance(live_authorization, dict):
            raise RuntimeError("prepared authorization is missing")
        live_authorization = copy.deepcopy(live_authorization)
        live_authorization.update(
            {
                "repository": repository,
                "issue": issue,
                "pr": pr,
                "base": live_pr["base"],
                "head": live_pr["head"],
                "closing_issues": live_closing_issues,
                "approval_id": execution["approval_id"],
                "plan_revision": execution["plan_revision"],
                "scope_hash": execution["scope_hash"],
                "executor": execution["executor"],
                "observation_time": observation_time,
            }
        )

        comments = self._ledger_comments(
            comments_payload,
            repository,
            issue,
            pr,
            self.approved_marker_actors,
        )
        ledger = state.get("ledger")
        if isinstance(ledger, dict):
            ledger["comments"] = comments
            ledger["count"] = len(comments)

        live_authorization["evidence_digest"] = queue["adoption_evidence_digest"](
            evidence
        )
        state["authorization"] = live_authorization
        return state

    def _ledger_comments(
        self,
        payload: object,
        repository: str,
        issue: int,
        pr: int,
        approved_authors: frozenset[str],
    ) -> list[dict[str, object]]:
        if not isinstance(payload, list):
            raise RuntimeError("GitHub ledger comments payload is invalid")
        marker = "<!-- rpm-agent-adoption:v1 -->"
        comments: list[dict[str, object]] = []
        for item in payload:
            if not isinstance(item, dict) or not isinstance(item.get("body"), str):
                continue
            body = item["body"]
            if marker not in body:
                continue
            author = item.get("user")
            actor = author.get("login") if isinstance(author, dict) else None
            # Ordinary users can quote the ledger marker in issue comments.
            # Ignore those comments before parsing attacker-controlled JSON;
            # only the policy-approved ledger authors can contribute records.
            if not isinstance(actor, str) or actor not in approved_authors:
                continue
            encoded = body.split(marker, 1)[1].strip()
            try:
                record = json.loads(encoded)
            except json.JSONDecodeError:
                raise RuntimeError("GitHub ledger marker has invalid JSON")
            if not isinstance(record, dict):
                raise RuntimeError("GitHub ledger record is invalid")
            record["comment_id"] = item.get("id")
            record["author"] = actor
            if (
                record.get("repository") != repository
                or record.get("issue") != issue
                or record.get("pr") != pr
            ):
                raise RuntimeError("GitHub ledger target mismatch")
            comments.append(record)
        return sorted(comments, key=lambda record: int(record.get("comment_id", 0)))

    @staticmethod
    def _record_fingerprint(records: object, fields: tuple[str, ...]) -> list[tuple[str, ...]]:
        if not isinstance(records, list):
            return []
        return sorted(
            tuple(str(item.get(field, "")) for field in fields)
            for item in records
            if isinstance(item, dict)
        )

    def _mark_check_drift(self, state: dict[str, object], payload: object, head_sha: str) -> None:
        if not isinstance(payload, dict):
            raise RuntimeError("GitHub check-runs payload is invalid")
        evidence = state.get("evidence")
        if not isinstance(evidence, dict):
            return
        checks = evidence.get("checks")
        if not isinstance(checks, dict):
            return
        live_records = []
        for item in payload.get("check_runs", []):
            if not isinstance(item, dict):
                continue
            app = item.get("app")
            live_records.append(
                {
                    "name": item.get("name"),
                    "status": item.get("status"),
                    "conclusion": item.get("conclusion"),
                    "head_sha": head_sha,
                    "source": "github-actions" if isinstance(app, dict) and app.get("slug") == "github-actions" else "unknown",
                    "workflow_run_id": item.get("id"),
                }
            )
        if self._record_fingerprint(checks.get("records"), ("name", "status", "conclusion", "head_sha", "workflow_run_id")) != self._record_fingerprint(live_records, ("name", "status", "conclusion", "head_sha", "workflow_run_id")):
            checks["records"] = live_records
            checks["count"] = len(live_records)
            checks["head_sha"] = head_sha

    def _mark_review_drift(self, state: dict[str, object], payload: object, head_sha: str) -> None:
        if not isinstance(payload, list):
            raise RuntimeError("GitHub review payload is invalid")
        evidence = state.get("evidence")
        if not isinstance(evidence, dict):
            return
        review = evidence.get("review")
        if not isinstance(review, dict):
            return
        automatic = review.get("automatic_reviews")
        if not isinstance(automatic, dict):
            return
        live_records = []
        for item in payload:
            if not isinstance(item, dict):
                continue
            user = item.get("user")
            live_records.append(
                {
                    "actor": user.get("login") if isinstance(user, dict) else None,
                    "submitted_at": item.get("submitted_at"),
                    "reviewed_head_sha": item.get("commit_id"),
                    "state": item.get("state"),
                    "finding_count": item.get("finding_count"),
                }
            )
        if self._record_fingerprint(automatic.get("records"), ("actor", "submitted_at", "reviewed_head_sha", "state")) != self._record_fingerprint(live_records, ("actor", "submitted_at", "reviewed_head_sha", "state")):
            automatic["records"] = live_records
            automatic["count"] = len(live_records)
            automatic["head_sha"] = head_sha

    @staticmethod
    def _label_state_projection(state: object) -> object:
        """Project a live state while retaining every non-label CAS field.

        A lifecycle label write is allowed to change only the issue label set
        and the two derived lifecycle-state fields.  The projection is used
        solely to decide whether a compensating delete is safe; authorization,
        evidence, ledger, refs, checks, reviews, and writer/dependent
        inventories remain part of the comparison.
        """
        projected = GithubAdoptionTransport._runtime_time_projection(state)
        if not isinstance(projected, dict):
            return projected
        live = projected.get("live")
        if isinstance(live, dict):
            live["issue_labels"] = "<lifecycle-labels>"
            live["lifecycle_state"] = "<lifecycle-state>"
        evidence = projected.get("evidence")
        if isinstance(evidence, dict):
            issue = evidence.get("issue")
            if isinstance(issue, dict):
                issue["labels"] = "<lifecycle-labels>"
                issue["lifecycle_state"] = "<lifecycle-state>"
        # The authorization digest covers the evidence snapshot, including
        # ordinary labels.  A label-only race therefore changes this derived
        # value even when every non-label field is unchanged.  Mask the
        # derivative while retaining the underlying evidence comparison.
        authorization = projected.get("authorization")
        if isinstance(authorization, dict):
            authorization["evidence_digest"] = "<label-derived-digest>"
        return projected

    @staticmethod
    def _runtime_time_projection(state: object) -> object:
        """Mask per-read clock fields before comparing a live CAS snapshot."""
        projected = copy.deepcopy(state)
        if not isinstance(projected, dict):
            return projected
        if "now" in projected:
            projected["now"] = "<observation-time>"
        authorization = projected.get("authorization")
        if isinstance(authorization, dict) and "observation_time" in authorization:
            authorization["observation_time"] = "<observation-time>"
        evidence = projected.get("evidence")
        if isinstance(evidence, dict):
            writers = evidence.get("writers")
            if isinstance(writers, dict) and "observed_at" in writers:
                writers["observed_at"] = "<observation-time>"
        return projected

    @staticmethod
    def _state_labels(state: object) -> tuple[list[str], list[str]] | None:
        """Return ordinary and lifecycle labels from a fully-read state."""
        if not isinstance(state, dict):
            return None
        live = state.get("live")
        if not isinstance(live, dict) or not isinstance(live.get("issue_labels"), list):
            return None
        labels = live["issue_labels"]
        if not all(isinstance(label, str) and label for label in labels):
            return None
        ordinary = sorted(label for label in labels if not label.startswith("agent:"))
        lifecycle = sorted(label for label in labels if label.startswith("agent:"))
        return ordinary, lifecycle

    @classmethod
    def _expected_label_state(
        cls, state: object, label: str
    ) -> dict[str, object] | None:
        """Build the only state that may follow an add-only lifecycle write."""
        if not isinstance(state, dict) or not isinstance(label, str) or not label.startswith("agent:"):
            return None
        labels = cls._state_labels(state)
        if labels is None:
            return None
        ordinary, lifecycle = labels
        # The dedicated operation starts from an untracked issue.  An existing
        # lifecycle label means another writer won the race; it must never be
        # silently folded into this write's expected post-state.
        if lifecycle or label in ordinary:
            return None
        expected = copy.deepcopy(state)
        expected_labels = sorted([*ordinary, label])
        live = expected.get("live")
        evidence = expected.get("evidence")
        issue = evidence.get("issue") if isinstance(evidence, dict) else None
        if not isinstance(live, dict) or not isinstance(issue, dict):
            return None
        live["issue_labels"] = expected_labels
        live["lifecycle_state"] = "review-pending"
        issue["labels"] = expected_labels
        issue["lifecycle_state"] = "review-pending"
        return expected

    @classmethod
    def _safe_label_compensation(
        cls, before: object, after: object, label: str
    ) -> bool:
        """Check that deleting only ``label`` cannot erase another change."""
        before_labels = cls._state_labels(before)
        after_labels = cls._state_labels(after)
        if before_labels is None or after_labels is None:
            return False
        before_ordinary, before_lifecycle = before_labels
        after_ordinary, after_lifecycle = after_labels
        if label in before_lifecycle or label not in after_lifecycle:
            return False
        # No lifecycle label may disappear while the write is being checked.
        # New labels are preserved by the compensating delete.
        if not set(before_lifecycle).issubset(after_lifecycle):
            return False
        return cls._label_state_projection(before) == cls._label_state_projection(after)

    @classmethod
    def _compensated_label_state(
        cls, before: object, restored: object, after: object, label: str
    ) -> bool:
        """Confirm that only this transport's label was removed."""
        before_labels = cls._state_labels(before)
        after_labels = cls._state_labels(after)
        restored_labels = cls._state_labels(restored)
        if (
            before_labels is None
            or after_labels is None
            or restored_labels is None
        ):
            return False
        before_ordinary, before_lifecycle = before_labels
        after_ordinary, after_lifecycle = after_labels
        restored_ordinary, restored_lifecycle = restored_labels
        if (
            label in before_lifecycle
            or label not in after_lifecycle
            or label in restored_lifecycle
            or after_ordinary != restored_ordinary
            or not set(before_lifecycle).issubset(after_lifecycle)
            or sorted(item for item in after_lifecycle if item != label)
            != restored_lifecycle
        ):
            return False
        return cls._label_state_projection(before) == cls._label_state_projection(after) == cls._label_state_projection(restored)

    def _recover_label_conflict(
        self,
        repository: str,
        issue: int,
        pr: int,
        label: str,
        before: dict[str, object],
        post_observation: object,
        expected_cas: str,
    ) -> dict[str, object]:
        """Fail closed after a post-write drift and undo only our label."""
        post_state = (
            post_observation.get("state")
            if isinstance(post_observation, dict)
            else None
        )
        post_cas = (
            post_observation.get("cas")
            if isinstance(post_observation, dict)
            else None
        )
        conflict: dict[str, object] = {
            "schema": "rpm-existing-pr-adoption-label-conflict-v1",
            "repository": repository,
            "issue": issue,
            "pr": pr,
            "label": label,
            "before_cas": expected_cas,
            "post_cas": post_cas,
        }
        recovery: dict[str, object] = {
            "status": "not-safe",
            "target_label": label,
        }
        if not isinstance(post_state, dict):
            conflict["recovery"] = recovery
            return {
                "status": "label-conflict",
                "reason": "post-write-refetch-incomplete",
                "conflict": conflict,
                "recovery": recovery,
            }
        if not self._safe_label_compensation(before, post_state, label):
            conflict["recovery"] = recovery
            return {
                "status": "label-conflict",
                "reason": "post-write-cas-conflict",
                "conflict": conflict,
                "recovery": recovery,
            }

        endpoint = f"repos/{self._repository_path(repository)}/issues/{issue}"
        encoded_label = quote(label, safe="")
        delete_endpoint = f"{endpoint}/labels/{encoded_label}"
        try:
            self._call(delete_endpoint, method="DELETE")
        except (RuntimeError, ValueError, KeyError, TypeError) as error:
            recovery.update({"status": "failed", "reason": str(error)})
            conflict["recovery"] = recovery
            return {
                "status": "label-conflict-recovery-failed",
                "reason": "label-compensation-failed",
                "conflict": conflict,
                "recovery": recovery,
            }

        try:
            restored_observation = self._read_label_recovery_state(
                repository, issue, pr
            )
        except (RuntimeError, ValueError, KeyError, TypeError) as error:
            recovery.update({"status": "unknown", "reason": str(error)})
            conflict["recovery"] = recovery
            return {
                "status": "label-conflict-recovery-failed",
                "reason": "label-compensation-refetch-failed",
                "conflict": conflict,
                "recovery": recovery,
            }
        restored_state = (
            restored_observation.get("state")
            if isinstance(restored_observation, dict)
            else None
        )
        if not self._compensated_label_state(
            before, restored_state, post_state, label
        ):
            recovery.update({"status": "failed", "reason": "restoration-mismatch"})
            conflict["recovery"] = recovery
            return {
                "status": "label-conflict-recovery-failed",
                "reason": "label-compensation-verification-failed",
                "conflict": conflict,
                "recovery": recovery,
            }
        recovery.update(
            {
                "status": "restored",
                "restored_cas": restored_observation.get("cas")
                if isinstance(restored_observation, dict)
                else None,
                "preserved_lifecycle_labels": self._state_labels(restored_state)[1]
                if self._state_labels(restored_state) is not None
                else [],
            }
        )
        conflict["recovery"] = recovery
        return {
            "status": "label-conflict-recovered",
            "reason": "post-write-cas-conflict",
            "conflict": conflict,
            "recovery": recovery,
        }

    def read(self, repository: str, issue: int, pr: int) -> dict[str, object]:
        state = self._read_state(repository, issue, pr)
        queue = runpy.run_path(str(ROOT / "scripts/check-cloud-queue-contract.py"))
        return {
            "state": state,
            "cas": queue["canonical_digest"](
                self._runtime_time_projection(state)
            ),
        }

    def _read_label_recovery_state(
        self, repository: str, issue: int, pr: int
    ) -> dict[str, object]:
        """Read a post-label state even when another lifecycle label won."""
        state = self._read_state(
            repository,
            issue,
            pr,
            allow_lifecycle_conflict=True,
            allow_ordinary_label_conflict=True,
        )
        queue = runpy.run_path(str(ROOT / "scripts/check-cloud-queue-contract.py"))
        return {
            "state": state,
            "cas": queue["canonical_digest"](
                self._runtime_time_projection(state)
            ),
        }

    @staticmethod
    def _issue_label_names(payload: object) -> list[str] | None:
        if not isinstance(payload, dict):
            return None
        labels = payload.get("labels")
        if not isinstance(labels, list) or any(
            not isinstance(item, dict) or not isinstance(item.get("name"), str)
            for item in labels
        ):
            return None
        return sorted(str(item["name"]) for item in labels)

    def recover_stale_label(
        self,
        policy: dict[str, object],
        repository: str,
        issue: int,
        pr: int,
        prepared_authorization: dict[str, object],
    ) -> dict[str, object]:
        """Diagnose a stale label without mutating shared lifecycle state.

        GitHub labels do not expose an atomic per-write owner identity. A
        current review-pending label therefore cannot be proven to belong to
        this stale run, even when its old ledger and writer lease are exact.
        Recovery always fails closed and leaves manual reconciliation to an
        independently authorized principal.
        """
        if self.snapshot is None or self.snapshot.get("authorization") != prepared_authorization:
            return {"status": "not-safe", "reason": "prepared-authorization-mismatch"}
        if (
            prepared_authorization.get("repository") != repository
            or prepared_authorization.get("issue") != issue
            or prepared_authorization.get("pr") != pr
        ):
            return {"status": "not-safe", "reason": "prepared-target-mismatch"}
        prepared_head = prepared_authorization.get("head")
        prepared_base = prepared_authorization.get("base")
        if not isinstance(prepared_head, dict) or not isinstance(prepared_base, dict):
            return {"status": "not-safe", "reason": "prepared-ref-missing"}
        expected_digest = prepared_authorization.get("evidence_digest")
        operation = self.snapshot.get("operation")
        if (
            not isinstance(expected_digest, str)
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", expected_digest)
            or not isinstance(operation, dict)
            or not isinstance(operation.get("run_id"), str)
        ):
            return {"status": "not-safe", "reason": "prepared-recovery-invalid"}
        queue = runpy.run_path(str(ROOT / "scripts/check-cloud-queue-contract.py"))
        contract = queue["adoption_contract"](policy)
        recovery_contract = (
            contract.get("stale_label_recovery")
            if isinstance(contract, dict)
            else None
        )
        if recovery_contract != {
            "mode": "fail-closed",
            "delete_label": False,
            "reason": "recovery-label-ownership-unprovable",
        }:
            return {"status": "not-safe", "reason": "recovery-contract-invalid"}

        try:
            live_identity = self._pr_identity_from_pr(repository, pr)
            issue_payload = self._call(
                f"repos/{self._repository_path(repository)}/issues/{issue}"
            )
        except (RuntimeError, ValueError, KeyError, TypeError) as error:
            return {"status": "unknown", "reason": f"recovery-read-failed:{error}"}
        old_identity = {
            "base_repository": prepared_base.get("repository"),
            "base_ref": prepared_base.get("ref"),
            "base_sha": prepared_base.get("sha"),
            "head_repository": prepared_head.get("repository"),
            "head_ref": prepared_head.get("ref"),
            "head_sha": prepared_head.get("sha"),
        }
        if live_identity == old_identity:
            return {"status": "not-needed", "reason": "prepared-head-still-current"}
        if live_identity.get("head_sha") == prepared_head.get("sha"):
            return {"status": "not-safe", "reason": "recovery-head-sha-unchanged"}
        labels = self._issue_label_names(issue_payload)
        if labels is None:
            return {"status": "not-safe", "reason": "recovery-labels-invalid"}
        target_label = "agent:review-pending"
        lifecycle = sorted(label for label in labels if label.startswith("agent:"))
        if lifecycle != [target_label]:
            return {"status": "not-safe", "reason": "recovery-lifecycle-conflict"}
        return {
            "status": "not-safe",
            "reason": "recovery-label-ownership-unprovable",
            "fresh_authorization_required": True,
            "old_head_sha": prepared_head.get("sha"),
            "current_head_sha": live_identity.get("head_sha"),
        }

    def compare_and_write(
        self,
        repository: str,
        issue: int,
        pr: int,
        expected_cas: str,
        mutation: dict[str, object],
    ) -> dict[str, object]:
        try:
            observation = self.read(repository, issue, pr)
            state = observation["state"]
            if observation.get("cas") != expected_cas:
                return {"status": "cas-mismatch"}
            authorization = state.get("authorization") if isinstance(state, dict) else None
            if not exact_authorization(
                mutation.get("authorization"),
                authorization,
                allow_observation_time_drift=True,
            ):
                return {"status": "cas-mismatch"}
            if not isinstance(authorization, dict):
                return {"status": "cas-mismatch"}
            if mutation.get("evidence_digest") != authorization.get("evidence_digest"):
                return {"status": "cas-mismatch"}
            endpoint = f"repos/{self._repository_path(repository)}/issues/{issue}"
            kind = mutation.get("kind")
            if kind == "append-writer-lease-comment":
                record = mutation.get("record")
                author = mutation.get("author")
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
                if (
                    not isinstance(record, dict)
                    or any(field not in record for field in required)
                    or record.get("kind") != "adoption"
                    or record.get("repository") != repository
                    or record.get("issue") != issue
                    or record.get("pr") != pr
                    or not isinstance(author, str)
                    or author not in self.approved_marker_actors
                ):
                    return {"status": "invalid-mutation"}
                body = "<!-- rpm-agent-writer:v1 -->\n" + json.dumps(
                    record, ensure_ascii=False, sort_keys=True, separators=(",", ":")
                )
                response = self._call(
                    endpoint + "/comments", method="POST", payload={"body": body}
                )
                if not isinstance(response, dict) or not isinstance(response.get("id"), int):
                    return {"status": "write-invalid-response"}
                user = response.get("user")
                if (
                    not isinstance(user, dict)
                    or user.get("login") != author
                    or response.get("body") != body
                ):
                    return {"status": "write-author-mismatch"}
            elif kind == "append-ledger-comment":
                record = mutation.get("record")
                if not isinstance(record, dict):
                    return {"status": "invalid-mutation"}
                body = "<!-- rpm-agent-adoption:v1 -->\n" + json.dumps(
                    record, ensure_ascii=False, sort_keys=True, separators=(",", ":")
                )
                response = self._call(
                    endpoint + "/comments", method="POST", payload={"body": body}
                )
                if not isinstance(response, dict) or not isinstance(response.get("id"), int):
                    return {"status": "write-invalid-response"}
                user = response.get("user")
                if (
                    not isinstance(user, dict)
                    or user.get("login") != record.get("author")
                    or response.get("body") != body
                ):
                    return {"status": "write-author-mismatch"}
            elif kind == "add-lifecycle-label":
                if mutation.get("mode") != "add-only" or not isinstance(mutation.get("label"), str):
                    return {"status": "invalid-mutation"}
                label = mutation["label"]
                expected_state = self._expected_label_state(state, label)
                if expected_state is None:
                    return {
                        "status": "label-conflict",
                        "reason": "pre-write-label-state-invalid",
                        "recovery": {
                            "status": "not-safe",
                            "target_label": label,
                        },
                    }
                response = self._call(
                    endpoint + "/labels",
                    method="POST",
                    payload={"labels": [label]},
                )
                if not isinstance(response, list):
                    return {"status": "write-invalid-response"}
                response_labels = sorted(
                    str(item.get("name"))
                    for item in response
                    if isinstance(item, dict) and isinstance(item.get("name"), str)
                )
                live_labels = state.get("live", {}).get("issue_labels", [])
                if (
                    not isinstance(live_labels, list)
                    or not set(live_labels).issubset(response_labels)
                    or label not in response_labels
                ):
                    return {"status": "write-label-preservation-failed"}
                try:
                    post_observation = self._read_label_recovery_state(
                        repository, issue, pr
                    )
                except (RuntimeError, ValueError, KeyError, TypeError) as error:
                    return {
                        "status": "label-conflict",
                        "reason": "post-write-refetch-failed",
                        "recovery": {
                            "status": "unknown",
                            "target_label": label,
                            "reason": str(error),
                        },
                    }
                post_state = (
                    post_observation.get("state")
                    if isinstance(post_observation, dict)
                    else None
                )
                if self._runtime_time_projection(post_state) != self._runtime_time_projection(
                    expected_state
                ):
                    return self._recover_label_conflict(
                        repository,
                        issue,
                        pr,
                        label,
                        state,
                        post_observation,
                        expected_cas,
                    )
                return {
                    "status": "applied",
                    "cas": post_observation.get("cas")
                    if isinstance(post_observation, dict)
                    else None,
                }
            else:
                return {"status": "mutation-kind-denied"}
            return {"status": "applied"}
        except (RuntimeError, ValueError, KeyError, TypeError) as error:
            return {"status": "write-failed", "reason": str(error)}


def blocked(reason: str) -> dict[str, object]:
    return {"status": "blocked", "reason": reason}


AUTHORIZATION_FIELDS = (
    "repository",
    "issue",
    "pr",
    "base",
    "head",
    "closing_issues",
    "policy_version",
    "operation_version",
    "evidence_digest",
    "approval_id",
    "plan_revision",
    "scope_hash",
    "executor",
    "observation_time",
)


def adoption_writer_lease_mutation(
    policy: dict[str, object], live: dict[str, object]
) -> dict[str, object] | None:
    """Return the acquisition-only lease write when this run has no live lease."""
    contract = policy.get("existing_pr_adoption")
    writer_contract = contract.get("writer_inventory") if isinstance(contract, dict) else None
    ledger = contract.get("ledger") if isinstance(contract, dict) else None
    operation = live.get("operation")
    authorization = live.get("authorization")
    evidence = live.get("evidence")
    writers = evidence.get("writers") if isinstance(evidence, dict) else None
    pr_evidence = evidence.get("pr") if isinstance(evidence, dict) else None
    head = pr_evidence.get("head") if isinstance(pr_evidence, dict) else None
    if not all(
        isinstance(value, dict)
        for value in (contract, writer_contract, ledger, operation, authorization, writers, head)
    ):
        raise ValueError("writer lease contract or evidence is incomplete")
    records = writers.get("records")
    authors = ledger.get("approved_authors")
    ttl_seconds = writer_contract.get("lease_ttl_seconds")
    now_text = live.get("now")
    if (
        not isinstance(records, list)
        or not isinstance(authors, list)
        or len(authors) != 1
        or not isinstance(authors[0], str)
        or type(ttl_seconds) is not int
        or ttl_seconds <= 0
        or not isinstance(now_text, str)
    ):
        raise ValueError("writer lease policy is invalid")
    try:
        now = datetime.fromisoformat(now_text.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("writer lease observation time is invalid") from error
    if now.tzinfo is None:
        raise ValueError("writer lease observation time has no timezone")
    now = now.astimezone(timezone.utc)
    run_id = operation.get("run_id")
    owner = operation.get("owner")
    repository = authorization.get("repository")
    issue = authorization.get("issue")
    pr = authorization.get("pr")
    head_sha = head.get("sha")
    if (
        not isinstance(run_id, str)
        or not run_id.strip()
        or not isinstance(owner, str)
        or not owner.strip()
        or not isinstance(repository, str)
        or type(issue) is not int
        or type(pr) is not int
        or not isinstance(head_sha, str)
        or not re.fullmatch(r"[0-9a-f]{40}", head_sha)
    ):
        raise ValueError("writer lease identity is invalid")
    for record in records:
        if not isinstance(record, dict) or record.get("kind") != "adoption":
            continue
        expires_at = record.get("lease_expires_at")
        if not isinstance(expires_at, str):
            continue
        try:
            expiry = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
        except ValueError:
            continue
        if expiry.tzinfo is None or expiry.astimezone(timezone.utc) <= now:
            continue
        if (
            record.get("run_id") == run_id
            and record.get("owner") == owner
            and record.get("repository") == repository
            and record.get("issue") == issue
            and record.get("pr") == pr
            and record.get("head_sha") == head_sha
        ):
            return None
    expires_at = (now + timedelta(seconds=ttl_seconds)).isoformat().replace(
        "+00:00", "Z"
    )
    return {
        "kind": "append-writer-lease-comment",
        "author": authors[0],
        "record": {
            "kind": "adoption",
            "repository": repository,
            "issue": issue,
            "pr": pr,
            "run_id": run_id,
            "owner": owner,
            "lease_expires_at": expires_at,
            "head_sha": head_sha,
        },
    }


def exact_authorization(
    prepared: object,
    live: object,
    *,
    allow_observation_time_drift: bool = False,
) -> bool:
    """Require immutable authorization fields to match across a refetch.

    ``observation_time`` can be refreshed for every live read so lease
    validation cannot use a stale prepared clock.  It remains bound to the
    live writer inventory and authorization in ``read``.  Callers must opt in
    to that one runtime-field drift explicitly.
    """
    if not isinstance(prepared, dict) or not isinstance(live, dict):
        return False
    return all(
        field in prepared
        and field in live
        and (
            field == "observation_time" and allow_observation_time_drift
            or prepared.get(field) == live.get(field)
        )
        for field in AUTHORIZATION_FIELDS
    )


def execute_adoption_phase(
    policy: dict[str, object],
    prepared_snapshot: dict[str, object],
    transport: AdoptionTransport,
) -> dict[str, object]:
    """Refetch, revalidate, and compare-and-write exactly one adoption phase."""
    authorization = prepared_snapshot.get("authorization")
    if not isinstance(authorization, dict):
        return blocked("prepared-authorization-missing")
    repository = authorization.get("repository")
    issue = authorization.get("issue")
    pr = authorization.get("pr")
    if not isinstance(repository, str) or not isinstance(issue, int) or not isinstance(pr, int):
        return blocked("prepared-target-invalid")

    try:
        observation = transport.read(repository, issue, pr)
    except (RuntimeError, ValueError, KeyError, TypeError) as error:
        recovery_method = getattr(transport, "recover_stale_label", None)
        if callable(recovery_method):
            try:
                recovery = recovery_method(
                    policy,
                    repository,
                    issue,
                    pr,
                    authorization,
                )
            except (RuntimeError, ValueError, KeyError, TypeError) as recovery_error:
                recovery = {
                    "status": "unknown",
                    "reason": f"recovery-entry-failed:{recovery_error}",
                }
            if isinstance(recovery, dict) and recovery.get("status") == "restored":
                result = blocked("fresh-authorization-required")
                result["recovery"] = recovery
                return result
        result = blocked("live-refetch-failed")
        result["detail"] = str(error)
        if "recovery" in locals() and isinstance(recovery, dict):
            result["recovery"] = recovery
        return result
    live = observation.get("state") if isinstance(observation, dict) else None
    cas = observation.get("cas") if isinstance(observation, dict) else None
    if not isinstance(live, dict) or not isinstance(cas, str):
        return blocked("live-refetch-incomplete")
    live_authorization = live.get("authorization")
    if not exact_authorization(
        authorization,
        live_authorization,
        allow_observation_time_drift=True,
    ):
        return blocked("live-authorization-mismatch")

    queue = runpy.run_path(str(ROOT / "scripts/check-cloud-queue-contract.py"))
    decision = queue["adopt_existing_pr"](live, policy)
    if not isinstance(decision, dict) or decision.get("status") == "blocked":
        return blocked(str(decision.get("reason", "live-eligibility-failed")))
    if decision.get("status") == "reconciled" and "ledger_action" not in decision:
        return {"status": "reconciled", "phase": "reconciled"}

    try:
        lease_mutation = adoption_writer_lease_mutation(policy, live)
    except (TypeError, ValueError, KeyError) as error:
        return blocked(f"writer-lease-invalid:{error}")
    if lease_mutation is not None:
        lease_mutation["authorization"] = copy.deepcopy(live_authorization)
        lease_mutation["evidence_digest"] = live_authorization.get("evidence_digest")
        outcome = transport.compare_and_write(
            repository, issue, pr, cas, lease_mutation
        )
        if not isinstance(outcome, dict) or outcome.get("status") != "applied":
            return blocked("writer-lease-cas")
        return {
            "status": "applied",
            "phase": "writer-lease",
            "repository": repository,
            "issue": issue,
            "pr": pr,
        }

    mutation: dict[str, object]
    ledger = decision.get("ledger_action")
    request = decision.get("mutation_request")
    if isinstance(ledger, dict):
        mutation = {"kind": "append-ledger-comment", "record": ledger}
    elif isinstance(request, dict):
        helper = runpy.run_path(
            str(ROOT / "scripts/authorize-existing-pr-adoption-mutation.py")
        )
        authorization_result = helper["authorize"](policy, request)
        if authorization_result.get("status") != "authorized":
            return blocked(str(authorization_result.get("reason", "mutation-not-authorized")))
        mutation = {
            "kind": "add-lifecycle-label",
            "mode": "add-only",
            "label": request.get("label"),
        }
    else:
        return blocked("phase-action-missing")

    # Carry the complete authorization into the transport request.  The
    # transport performs a fresh read immediately before writing and checks
    # this tuple again, so a reused issue/PR number cannot cross the CAS gate.
    mutation["authorization"] = copy.deepcopy(live_authorization)
    mutation["evidence_digest"] = live_authorization.get("evidence_digest")

    outcome = transport.compare_and_write(repository, issue, pr, cas, mutation)
    if not isinstance(outcome, dict) or outcome.get("status") != "applied":
        result = blocked("compare-and-write-cas")
        if isinstance(outcome, dict):
            for field in ("conflict", "recovery"):
                if field in outcome:
                    result[field] = copy.deepcopy(outcome[field])
        return result
    return {
        "status": "applied",
        "phase": decision.get("phase"),
        "repository": repository,
        "issue": issue,
        "pr": pr,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--request-file", required=True)
    parser.add_argument("--policy", default=".agents/workflows/backlog-policy.json")
    args = parser.parse_args(argv)
    try:
        request = json.loads(Path(args.request_file).read_text())
        policy = json.loads(Path(args.policy).read_text())
        if not isinstance(request, dict) or not isinstance(policy, dict):
            result = blocked("request-invalid")
        else:
            prepared = request.get("prepared_snapshot", request)
            if not isinstance(prepared, dict):
                result = blocked("prepared-snapshot-invalid")
            else:
                authorization = prepared.get("authorization")
                if not isinstance(authorization, dict):
                    result = blocked("prepared-authorization-missing")
                else:
                    adoption_contract = policy.get("existing_pr_adoption")
                    ledger = (
                        adoption_contract.get("ledger")
                        if isinstance(adoption_contract, dict)
                        else None
                    )
                    approved_marker_actors = (
                        ledger.get("approved_authors")
                        if isinstance(ledger, dict)
                        else None
                    )
                    transport = GithubAdoptionTransport(
                        snapshot=prepared,
                        approved_marker_actors=approved_marker_actors,
                    )
                    result = execute_adoption_phase(policy, prepared, transport)
    except (
        OSError,
        json.JSONDecodeError,
        TypeError,
        ValueError,
        RuntimeError,
    ) as error:
        result = blocked(f"request-load-failed:{error}")
    print(
        json.dumps(
            {"type": "existing_pr_adoption_write", "data": result},
            sort_keys=True,
        )
    )
    return 1 if result.get("status") == "blocked" else 0


if __name__ == "__main__":
    raise SystemExit(main())
