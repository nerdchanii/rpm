#!/usr/bin/env python3
"""Enforce role-specific tool, GitHub mutation, and patch boundaries."""

from __future__ import annotations

import base64
import hashlib
import json
import re
import shlex
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath


MANAGERS = {
    "rpm_workflow_manager",
    "rpm_backlog_manager",
    "rpm_issue_manager",
}
LOCAL_WRITE_ROLES = {
    "pr-review-resolver",
    "rpm_spec_updater",
    "rpm_test_author",
    "rpm_implementer",
}
MCP_READ_ROLES = {
    "pr-review-resolver",
    "rpm_backlog_scout",
    "rpm_idea_issue_creator",
    "rpm_issue_fetcher",
    "rpm_issue_researcher",
    "rpm_issue_refiner",
    "rpm_issue_readiness_reviewer",
    "rpm_ready_ticket_claimer",
    "rpm_followup_issue_creator",
}
GITHUB_MUTATION_ROLES = {
    "rpm_idea_issue_creator",
    "rpm_issue_refiner",
    "rpm_ready_ticket_claimer",
    "rpm_followup_issue_creator",
}
RPM_ROLES = MANAGERS | LOCAL_WRITE_ROLES | MCP_READ_ROLES | {
    "rpm_spec_reviewer",
    "rpm_issue_spec_reconciler",
    "rpm_test_runner",
    "rpm_verifier",
    "rpm_adversarial_reviewer",
}
POLICY_DIR = Path(tempfile.gettempdir()) / "rpm-agent-tool-policy"
PATCH_PATH = re.compile(
    r"^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+?)\s*$",
    re.MULTILINE,
)
SHELL_TOOL_PARTS = {
    "bash",
    "shell",
    "exec",
    "exec_command",
    "functions.exec",
    "functions.exec_command",
    "terminal",
}


def read_event() -> dict[str, object]:
    try:
        value = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        print(f"RPM agent policy received invalid hook JSON: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    if not isinstance(value, dict):
        print("RPM agent policy received a non-object hook payload.", file=sys.stderr)
        raise SystemExit(2)
    return value


def transcript_path(event: dict[str, object], start_or_stop: bool = False) -> str | None:
    key = "agent_transcript_path" if start_or_stop else "transcript_path"
    value = event.get(key)
    return value if isinstance(value, str) and value else None


def policy_path(transcript: str) -> Path:
    digest = hashlib.sha256(transcript.encode()).hexdigest()
    return POLICY_DIR / f"{digest}.json"


def register(event: dict[str, object]) -> int:
    role = event.get("agent_type")
    transcript = transcript_path(event, start_or_stop=True)
    if not isinstance(role, str) or role not in RPM_ROLES or transcript is None:
        return 0
    POLICY_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    policy_path(transcript).write_text(json.dumps({"agent_type": role}))
    return 0


def cleanup(event: dict[str, object]) -> int:
    transcript = transcript_path(event, start_or_stop=True)
    if transcript is None:
        return 0
    try:
        policy_path(transcript).unlink()
    except FileNotFoundError:
        pass
    return 0


def current_role(event: dict[str, object]) -> str | None:
    transcript = transcript_path(event)
    if transcript is None:
        return None
    try:
        value = json.loads(policy_path(transcript).read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
    role = value.get("agent_type") if isinstance(value, dict) else None
    return role if isinstance(role, str) and role in RPM_ROLES else None


def transcript_role(value: object) -> str | None:
    if not isinstance(value, dict):
        return None
    for key in ("role", "type"):
        role = value.get(key)
        if role in {"assistant", "developer", "system", "user"}:
            return str(role)
    message = value.get("message")
    return transcript_role(message) if isinstance(message, dict) else None


def trusted_claim_authorization(
    event: dict[str, object],
) -> tuple[str, dict[str, object]] | None:
    """Read one parent-issued token from a dedicated handoff field."""
    transcript = transcript_path(event)
    if transcript is None:
        return None
    try:
        lines = Path(transcript).read_text().splitlines()
    except OSError:
        return None
    parent_tokens: list[str] = []
    for line in lines:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        role = transcript_role(record)
        if role == "assistant":
            break
        if role in {"developer", "system", "user"}:
            if isinstance(record, dict):
                token = record.get("rpm_claim_authorization")
                if isinstance(token, str):
                    parent_tokens.append(token)
    if len(parent_tokens) != 1:
        return None
    token = parent_tokens[0]
    try:
        padding = "=" * (-len(token) % 4)
        payload = json.loads(base64.urlsafe_b64decode(token + padding))
    except (ValueError, json.JSONDecodeError):
        return None
    expected_keys = {
        "controller_sha256",
        "idempotency_key",
        "issue",
        "issue_comment_marker",
        "labels",
        "phase",
        "repository",
        "snapshot_sha256",
        "transition_required",
        "version",
    }
    if not isinstance(payload, dict) or set(payload) != expected_keys:
        return None
    hashes = (payload.get("controller_sha256"), payload.get("idempotency_key"), payload.get("snapshot_sha256"))
    labels = payload.get("labels")
    if (
        payload.get("version") != 1
        or payload.get("phase") not in {"claim", "persist"}
        or payload.get("repository") != "nerdchanii/rpm"
        or not isinstance(payload.get("issue"), int)
        or isinstance(payload.get("issue"), bool)
        or int(payload["issue"]) <= 0
        or not all(isinstance(value, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", value) for value in hashes)
        or not isinstance(payload.get("issue_comment_marker"), str)
        or not isinstance(payload.get("transition_required"), bool)
        or not isinstance(labels, list)
        or not all(isinstance(label, str) for label in labels)
    ):
        return None
    if payload["phase"] == "persist" and (
        payload["transition_required"] is not False or labels != []
    ):
        return None
    return token, payload


def flatten_strings(value: object) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [item for child in value for item in flatten_strings(child)]
    if isinstance(value, dict):
        return [item for child in value.values() for item in flatten_strings(child)]
    return []


def collect_keys(value: object) -> set[str]:
    if isinstance(value, dict):
        return {
            str(key).casefold()
            for key in value
        } | {item for child in value.values() for item in collect_keys(child)}
    if isinstance(value, list):
        return {item for child in value for item in collect_keys(child)}
    return set()


def operation_values(value: object) -> list[str]:
    if isinstance(value, dict):
        selected = [
            item
            for key, child in value.items()
            if str(key).casefold()
            in {"action", "operation", "operationname", "method", "mutation"}
            for item in flatten_strings(child)
        ]
        return selected + [
            item for child in value.values() for item in operation_values(child)
        ]
    if isinstance(value, list):
        return [item for child in value for item in operation_values(child)]
    return []


def patch_paths(tool_input: object, cwd: Path) -> list[PurePosixPath]:
    paths: list[PurePosixPath] = []
    for text in flatten_strings(tool_input):
        for raw in PATCH_PATH.findall(text):
            candidate = Path(raw.strip())
            try:
                relative = candidate.relative_to(cwd) if candidate.is_absolute() else candidate
            except ValueError:
                relative = Path("..") / candidate
            paths.append(PurePosixPath(relative.as_posix()))
    return paths


def path_allowed(role: str, path: PurePosixPath) -> bool:
    parts = path.parts
    if not parts or path.is_absolute() or ".." in parts:
        return False
    text = path.as_posix()
    if role == "rpm_spec_updater":
        return text.startswith("docs/specs/")
    if role == "rpm_test_author":
        return text.startswith("tests/") or text.startswith("src/")
    if role == "rpm_implementer":
        return not (
            text.startswith("tests/")
            or text.startswith("docs/specs/")
            or text.startswith(".codex/")
            or text.startswith(".agents/")
        )
    if role == "pr-review-resolver":
        return not (
            text.startswith(".codex/")
            or text.startswith(".agents/")
            or text.startswith(".claude/")
            or text.startswith(".github/")
            or text.startswith(".githooks/")
            or text.startswith("scripts/")
            or text == "justfile"
        )
    return False


def deny(reason: str) -> int:
    print(f"RPM agent tool policy blocked this call: {reason}", file=sys.stderr)
    return 2


def normalized_tool(tool: str) -> str:
    return tool.replace("-", "_").casefold()


def is_github_tool(tool: str) -> bool:
    """Recognize GitHub capabilities without depending on an MCP namespace."""
    normalized = normalized_tool(tool)
    tokens = operation_tokens(tool)
    has_issue = any(token.startswith("issue") for token in tokens)
    has_label = any(token.startswith("label") for token in tokens)
    has_project = any(token.startswith("project") for token in tokens)
    has_pull_request = (
        "pullrequest" in tokens
        or ("pull" in tokens and "request" in tokens)
        or "pr" in tokens
    )
    return (
        "github" in normalized
        or "gh" in tokens
        or has_issue
        or has_label
        or has_project
        or has_pull_request
    )


def is_agent_tool(tool: str) -> bool:
    normalized = normalized_tool(tool)
    return (
        normalized == "agent"
        or "spawn_agent" in normalized
        or normalized.endswith("__agent")
    )


def is_shell_tool(tool: str) -> bool:
    normalized = normalized_tool(tool)
    return any(
        normalized == part
        or normalized.endswith(f"__{part}")
        or normalized.endswith(f".{part}")
        for part in SHELL_TOOL_PARTS
    )


def has_forbidden_review_or_merge(text: str) -> str | None:
    lowered = text.casefold()
    if "@codex review" in lowered:
        return "`@codex review` is owned by external repository review configuration"
    if re.search(r"\bgh\s+pr\s+merge\b", lowered):
        return "RPM subagents cannot merge pull requests"
    if "mergepullrequest" in lowered or "pullrequestmerge" in lowered or re.search(
        r"\bmerge(?:_pull_request|pullrequest)\b", lowered
    ) or re.search(r"\b(?:gh[_-]?pr|pr|pull[_-]?request)[_-]?merge\b", lowered):
        return "RPM subagents cannot merge pull requests"
    return None


def shell_mutation_kind(text: str) -> str | None:
    lowered = text.casefold()
    if re.search(r"\bgh\s+issue\s+create\b", lowered):
        return "issue_create"
    if re.search(r"\bgh\s+issue\s+edit\b", lowered):
        return "issue_edit"
    if re.search(r"\bgh\s+issue\s+(?:comment|close|reopen|delete|transfer|pin)\b", lowered):
        return "issue_other"
    if re.search(r"\bgh\s+project\s+item-add\b", lowered):
        return "project_add"
    if re.search(r"\bgh\s+project\s+(?:item-edit|item-delete|edit|delete|copy|close)\b", lowered):
        return "project_other"
    if re.search(
        r"\bgh\s+(?:label|pr\s+(?:comment|create|edit|review|close|reopen|ready))\b",
        lowered,
    ):
        return "other_github"
    if re.search(r"\bgh\s+api\b", lowered) and (
        re.search(r"(?:--method|-x)\s*(?:post|patch|put|delete)\b", lowered)
        or re.search(r"\bmutation\b", lowered)
    ):
        return "raw_api_mutation"
    return None


def graphql_query_document(value: object) -> str | None:
    """Return only the request's dedicated top-level GraphQL document field."""
    if not isinstance(value, dict):
        return None
    for key, child in value.items():
        if str(key).casefold() == "query" and isinstance(child, str):
            return child
    return None


READ_OPERATION_WORDS = {
    "check",
    "fetch",
    "find",
    "get",
    "head",
    "list",
    "options",
    "query",
    "read",
    "search",
    "status",
    "view",
}
MUTATION_OPERATION_WORDS = {
    "add",
    "claim",
    "close",
    "comment",
    "create",
    "delete",
    "edit",
    "label",
    "merge",
    "mutate",
    "mutation",
    "patch",
    "post",
    "put",
    "remove",
    "reopen",
    "replace",
    "set",
    "transition",
    "update",
    "write",
}
GENERIC_EXECUTOR_WORDS = {
    "call",
    "dispatch",
    "dispatcher",
    "execute",
    "executor",
    "invoke",
    "request",
    "run",
}
AMBIGUOUS_PROVIDER_NAMESPACES = {"api", "connector", "host", "provider", "service"}
AMBIGUOUS_PROVIDER_ACTIONS = (
    MUTATION_OPERATION_WORDS
    | GENERIC_EXECUTOR_WORDS
    | {"do", "perform"}
)


def operation_tokens(value: str) -> list[str]:
    camel_case = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", value)
    return [token for token in re.split(r"[^a-z0-9]+", camel_case.casefold()) if token]


def is_generic_dispatcher(tool: str, tool_input: object) -> bool:
    """Reject generic provider calls whose registered operation is not inspectable."""
    tokens = operation_tokens(tool)
    has_pull_request_resource = (
        "pull" in tokens
        and "request" in tokens
        and any(token in READ_OPERATION_WORDS for token in tokens)
    )
    if any(token in GENERIC_EXECUTOR_WORDS for token in tokens) and not has_pull_request_resource:
        return True
    has_ambiguous_namespace = any(
        token in AMBIGUOUS_PROVIDER_NAMESPACES for token in tokens
    )
    input_kinds = {
        kind
        for value in operation_values(tool_input)
        if (kind := operation_kind(value)) is not None
    }
    if has_ambiguous_namespace and "mutation" in input_kinds:
        return True
    has_ambiguous_action = any(token in AMBIGUOUS_PROVIDER_ACTIONS for token in tokens)
    has_explicit_resource = (
        "github" in tokens
        or "gh" in tokens
        or "pr" in tokens
        or has_pull_request_resource
        or any(
            token.startswith(("issue", "project", "pullrequest")) for token in tokens
        )
    )
    return has_ambiguous_namespace and has_ambiguous_action and not has_explicit_resource


def uses_raw_network_client(text: str) -> bool:
    """Keep GitHub-capable roles on inspectable host-provided capabilities."""
    lowered = text.casefold()
    if re.search(r"(?<![a-z0-9_])gh(?![a-z0-9_])\s+api(?![a-z0-9_])", lowered):
        return True
    if re.search(
        r"(?<![a-z0-9_])"
        r"(?:curl|ftp|httpie|nc|ncat|netcat|scp|sftp|socat|ssh|telnet|wget)"
        r"(?![a-z0-9_])",
        lowered,
    ):
        return True
    if re.search(r"(?<![a-z0-9_])(?:http|https)(?![a-z0-9_:])", lowered):
        return True
    if "/dev/tcp/" in lowered or "/dev/udp/" in lowered:
        return True
    if re.search(r"(?<![a-z0-9_])openssl(?![a-z0-9_])", lowered) and re.search(
        r"(?<![a-z0-9_])s_client(?![a-z0-9_])", lowered
    ):
        return True
    if re.search(r"(?<![a-z0-9_])git(?![a-z0-9_])", lowered):
        if re.search(
            r"(?<![a-z0-9_])"
            r"(?:clone|fetch|ls-remote|pull|push|receive-pack|send-pack|upload-pack)"
            r"(?![a-z0-9_])",
            lowered,
        ):
            return True
        if re.search(r"(?<![a-z0-9_])remote(?![a-z0-9_])", lowered) and re.search(
            r"(?<![a-z0-9_])update(?![a-z0-9_])", lowered
        ):
            return True
        if re.search(r"(?<![a-z0-9_])submodule(?![a-z0-9_])", lowered) and re.search(
            r"(?<![a-z0-9_])update(?![a-z0-9_])", lowered
        ):
            return True
        if "--remote" in lowered:
            return True
    has_script_runtime = re.search(
        r"(?<![a-z0-9_])"
        r"(?:node(?:js)?|perl|php|python(?:3(?:\.\d+)?)?|ruby)"
        r"(?![a-z0-9_])",
        lowered,
    )
    if has_script_runtime and re.search(
        r"(?<![a-z0-9_])(?:"
        r"aiohttp|axios|faraday|fetch|ftplib|got|httpparty|httpx|"
        r"lwp|net::http|requests|smtplib|socket|stream_socket_client|"
        r"undici|urllib|xmlhttprequest"
        r")(?![a-z0-9_])",
        lowered,
    ):
        return True
    if not re.search(r"(?:api\.)?github\.com\b", lowered):
        return False
    return bool(has_script_runtime)


def operation_kind(value: str) -> str | None:
    for token in operation_tokens(value):
        if token in READ_OPERATION_WORDS:
            return "read"
        if token in MUTATION_OPERATION_WORDS:
            return "mutation"
    return None


def mcp_mutation_kind(tool: str, tool_input: object) -> str | None:
    normalized = normalized_tool(tool)
    is_graphql = "graphql" in normalized
    if is_graphql:
        # Inline GraphQL operations declare their operation in the dedicated
        # query field. Ignore operationName, variables, and descriptions:
        # those values can contain arbitrary words that are not a document.
        document = graphql_query_document(tool_input)
        if document is None:
            # A persisted operation name does not prove the registered
            # document is read-only, so fail closed without the document.
            return "unknown_mutation"
        payload = document.casefold()
        if re.search(r"\bmutation\b", payload):
            # Raw GraphQL mutations remain unavailable to every mutation role.
            return "raw_api_mutation"
        elif re.search(r"\bquery\b", payload) or payload.lstrip().startswith("{"):
            return None
        else:
            return "unknown_mutation"
    else:
        # REST-style capabilities expose the operation in an explicit field or
        # in the tool name. Do not scan ordinary search/read payload text.
        operation_tokens_value = operation_tokens(tool)
        has_pull_request_read = (
            "pull" in operation_tokens_value
            and "request" in operation_tokens_value
            and any(token in READ_OPERATION_WORDS for token in operation_tokens_value)
        )
        generic_executor = any(
            token in GENERIC_EXECUTOR_WORDS for token in operation_tokens_value
        ) and not has_pull_request_read
        if generic_executor:
            # Generic executors cannot prove read-only semantics across hosts.
            return "raw_api_mutation"
        operation_text = operation_values(tool_input)
        candidates = [operation_kind(value) for value in operation_text]
        candidates = [candidate for candidate in candidates if candidate is not None]
        tool_kind = operation_kind(tool)
        signals = [tool_kind, *candidates]
        signals = [signal for signal in signals if signal is not None]
        if len(set(signals)) > 1:
            return "unknown_mutation"
        selected_kind = signals[0] if signals else None
        if selected_kind is None:
            return "unknown_mutation"
        if selected_kind == "read":
            return None
        context = [tool, *operation_text]
    context_tokens = [
        token
        for value in context
        for token in operation_tokens(value)
    ]
    if "merge" in context_tokens:
        return "merge"
    has_issue = any(token.startswith("issue") for token in context_tokens)
    has_project = any(token.startswith("project") for token in context_tokens)
    has_comment = any(token.startswith("comment") for token in context_tokens)
    if has_issue and has_comment:
        return "issue_comment"
    if has_issue and "create" in context_tokens:
        return "issue_create"
    if has_project and any(word in context_tokens for word in ("add", "create")):
        return "project_add"
    if has_project:
        return "project_other"
    has_label = any(token.startswith("label") for token in context_tokens)
    if has_label:
        return "issue_label_edit" if has_issue else "label_admin"
    if has_issue and any(word in context_tokens for word in ("update", "edit")):
        return "issue_edit"
    if has_issue:
        return "issue_other"
    return "unknown_mutation"


def approved_idea_project_add(tool_input: object) -> bool:
    """Allow only the repository policy's inspectable Project registration."""
    if not isinstance(tool_input, dict):
        return False
    normalized = {str(key).casefold(): value for key, value in tool_input.items()}
    allowed = {"issue_number", "owner", "project_number", "repository"}
    if set(normalized) != allowed:
        return False
    project_number = normalized.get("project_number")
    issue_number = normalized.get("issue_number")
    repository = normalized.get("repository")
    owner = normalized.get("owner")
    return (
        project_number == 7
        and isinstance(issue_number, int)
        and issue_number > 0
        and repository == "nerdchanii/rpm"
        and owner == "@me"
    )


def approved_claim_record_comment(
    tool_input: object, expected_marker: str | None = None
) -> bool:
    """Validate the exact durable claim marker before allowing comment creation."""
    if not isinstance(tool_input, dict):
        return False
    normalized = {str(key).casefold(): value for key, value in tool_input.items()}
    allowed = {
        "body",
        "comment",
        "issue",
        "issue_number",
        "number",
        "owner",
        "repo",
        "repository",
    }
    if set(normalized) - allowed:
        return False
    bodies = [normalized[key] for key in ("body", "comment") if key in normalized]
    if len(bodies) != 1 or not isinstance(bodies[0], str):
        return False
    body = bodies[0]
    prefix = "<!-- rpm-agent-claim: "
    suffix = " -->"
    if not body.startswith(prefix) or not body.endswith(suffix):
        return False
    try:
        record = json.loads(body[len(prefix) : -len(suffix)])
    except json.JSONDecodeError:
        return False
    if not isinstance(record, dict):
        return False
    required = {
        "event_id",
        "executor",
        "expires_at",
        "idempotency_key",
        "issue",
        "lease",
        "plan_revision",
        "repository",
        "run_id",
        "scope_hash",
        "started_at",
    }
    if set(record) != required or record.get("repository") != "nerdchanii/rpm":
        return False
    issue = record.get("issue")
    if not isinstance(issue, int) or isinstance(issue, bool) or issue <= 0:
        return False
    outer_issues = [
        normalized[key]
        for key in ("issue", "issue_number", "number")
        if key in normalized
    ]
    if len(outer_issues) != 1 or outer_issues[0] != issue:
        return False
    if "repository" in normalized and normalized["repository"] != "nerdchanii/rpm":
        return False
    if "repo" in normalized and normalized["repo"] != "rpm":
        return False
    if "owner" in normalized and normalized["owner"] != "nerdchanii":
        return False
    safe_identifier = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:@/+\-]{0,127}\Z")
    for field in ("event_id", "plan_revision", "run_id"):
        if not isinstance(record.get(field), str) or not safe_identifier.fullmatch(record[field]):
            return False
    if record.get("executor") not in {"local", "cloud"}:
        return False
    hash_pattern = re.compile(r"sha256:[0-9a-f]{64}\Z")
    if not isinstance(record.get("scope_hash"), str) or not hash_pattern.fullmatch(record["scope_hash"]):
        return False
    if not isinstance(record.get("idempotency_key"), str) or not hash_pattern.fullmatch(record["idempotency_key"]):
        return False
    canonical_key = "\0".join(
        (
            record["repository"],
            str(issue),
            record["plan_revision"],
            record["scope_hash"],
            record["event_id"],
        )
    ).encode()
    if record["idempotency_key"] != f"sha256:{hashlib.sha256(canonical_key).hexdigest()}":
        return False
    lease = record.get("lease")
    if not isinstance(lease, dict) or set(lease) != {
        "expires_at",
        "owner",
        "run_id",
        "started_at",
    }:
        return False
    if lease.get("run_id") != record["run_id"]:
        return False
    if not isinstance(lease.get("owner"), str) or not safe_identifier.fullmatch(lease["owner"]):
        return False
    if lease.get("started_at") != record.get("started_at") or lease.get("expires_at") != record.get("expires_at"):
        return False
    try:
        started = datetime.fromisoformat(str(record["started_at"]).replace("Z", "+00:00"))
        expires = datetime.fromisoformat(str(record["expires_at"]).replace("Z", "+00:00"))
    except ValueError:
        return False
    if started.tzinfo is None or expires.tzinfo is None:
        return False
    if started.astimezone(timezone.utc) + timedelta(seconds=3600) != expires.astimezone(timezone.utc):
        return False
    canonical = json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    canonical_marker = f"{prefix}{canonical}{suffix}"
    return body == canonical_marker and (
        expected_marker is None or body == expected_marker
    )


def shell_command(tool_input: object) -> str | None:
    if not isinstance(tool_input, dict):
        return None
    commands = [
        value
        for key, value in tool_input.items()
        if str(key).casefold() in {"cmd", "command"} and isinstance(value, str)
    ]
    return commands[0] if len(commands) == 1 else None


def attest_claim_controller(
    event: dict[str, object],
    tool_input: object,
    trusted: tuple[str, dict[str, object]] | None,
) -> tuple[bool, bool]:
    """Re-run a direct claim command and bind it to the parent-issued token."""
    command = shell_command(tool_input)
    cwd_value = event.get("cwd")
    if command is None or not isinstance(cwd_value, str):
        return False, False
    try:
        argv = shlex.split(command)
    except ValueError:
        return False, False
    if len(argv) < 2 or not re.fullmatch(r"(?:.*/)?python3?(?:\.\d+)?", argv[0]):
        return False, False
    cwd = Path(cwd_value).resolve()
    repository_root = Path(__file__).resolve().parents[2]
    if cwd != repository_root:
        return False, False
    script = Path(argv[1])
    script = (cwd / script).resolve() if not script.is_absolute() else script.resolve()
    expected = repository_root / "scripts" / "check-cloud-queue-contract.py"
    if (
        script != expected
        or "--operation" not in argv
        or any(arg == "--policy" or arg.startswith("--policy=") for arg in argv[2:])
    ):
        return False, False
    operation_index = argv.index("--operation")
    if operation_index + 1 >= len(argv) or argv[operation_index + 1] != "claim":
        return False, False
    try:
        completed = subprocess.run(
            [sys.executable, str(expected), *argv[2:]],
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return True, False
    try:
        output = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return True, False
    data = output.get("data") if isinstance(output, dict) else None
    if (
        completed.returncode != 0
        or not isinstance(output, dict)
        or output.get("type") != "cloud_queue_contract"
        or not isinstance(data, dict)
        or data.get("status") not in {"persist", "claim"}
    ):
        return True, False
    issue = data.get("issue")
    marker = data.get("issue_comment_marker")
    record = data.get("claim_record")
    if (
        trusted is None
        or not isinstance(issue, int)
        or isinstance(issue, bool)
        or not isinstance(marker, str)
        or not isinstance(record, dict)
        or record.get("issue") != issue
        or data.get("idempotency_key") != record.get("idempotency_key")
        or not approved_claim_record_comment({"issue_number": issue, "body": marker})
    ):
        return True, False
    token, authorization = trusted
    controller_data = {
        key: value
        for key, value in data.items()
        if key not in {"authorization_token", "snapshot_sha256"}
    }
    controller_sha256 = "sha256:" + hashlib.sha256(
        json.dumps(
            controller_data,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    authorized = (
        data.get("authorization_token") == token
        and data.get("snapshot_sha256") == authorization.get("snapshot_sha256")
        and controller_sha256 == authorization.get("controller_sha256")
        and data.get("status") == authorization.get("phase")
        and issue == authorization.get("issue")
        and record.get("repository") == authorization.get("repository")
        and data.get("idempotency_key") == authorization.get("idempotency_key")
        and marker == authorization.get("issue_comment_marker")
        and data.get("transition_required")
        == authorization.get("transition_required")
        and data.get("labels", []) == authorization.get("labels")
    )
    return True, authorized


def allowed_github_mutation(
    role: str,
    kind: str,
    tool_input: object,
    shell_text: str = "",
    authorization: dict[str, object] | None = None,
) -> bool:
    if role == "rpm_idea_issue_creator":
        if kind == "issue_create":
            return True
        return kind == "project_add" and approved_idea_project_add(tool_input)
    if role == "rpm_followup_issue_creator":
        return kind == "issue_create"
    if role == "rpm_issue_refiner":
        if kind not in {"issue_edit", "issue_label_edit"}:
            return False
        forbidden_keys = {"title", "assignees", "milestone", "state"}
        if collect_keys(tool_input) & forbidden_keys:
            return False
        lowered = shell_text.casefold()
        return not lowered or not any(
            flag in lowered
            for flag in ("--title", "--assignee", "--milestone", "--state")
        )
    if role == "rpm_ready_ticket_claimer":
        if kind == "issue_comment":
            return (
                isinstance(authorization, dict)
                and authorization.get("phase") == "persist"
                and isinstance(authorization.get("issue_comment_marker"), str)
                and approved_claim_record_comment(
                    tool_input, str(authorization["issue_comment_marker"])
                )
            )
        if kind not in {"issue_edit", "issue_label_edit"}:
            return False
        allowed_keys = {
            "issue",
            "issue_number",
            "labels",
            "number",
            "owner",
            "repo",
            "repository",
        }
        if collect_keys(tool_input) - allowed_keys:
            return False
        lowered = shell_text.casefold()
        if lowered:
            return False
        if not isinstance(tool_input, dict):
            return False
        issue_fields = [
            child
            for key, child in tool_input.items()
            if str(key).casefold() in {"issue", "issue_number", "number"}
        ]
        if (
            len(issue_fields) != 1
            or not isinstance(authorization, dict)
            or authorization.get("phase") != "claim"
            or authorization.get("transition_required") is not True
            or issue_fields[0] != authorization.get("issue")
        ):
            return False
        label_fields = [
            child
            for key, child in tool_input.items()
            if str(key).casefold() == "labels"
        ]
        if len(label_fields) != 1:
            return False
        label_values = label_fields[0]
        if not isinstance(label_values, list) or not all(
            isinstance(value, str) for value in label_values
        ):
            return False
        expected_labels = authorization.get("labels")
        if not isinstance(expected_labels, list) or label_values != expected_labels:
            return False
        labels = {
            value
            for value in label_values
            if value.startswith("agent:")
        }
        return labels == {"agent:claimed"}
    return False


def check_tool(event: dict[str, object]) -> int:
    role = current_role(event)
    if role is None:
        return 0

    tool = event.get("tool_name")
    if not isinstance(tool, str):
        return deny(f"{role} supplied no tool_name")
    tool_input = event.get("tool_input")
    text = "\n".join(flatten_strings(tool_input))
    trusted_claim = (
        trusted_claim_authorization(event)
        if role == "rpm_ready_ticket_claimer"
        else None
    )
    authorization = trusted_claim[1] if trusted_claim is not None else None

    forbidden = has_forbidden_review_or_merge(f"{tool}\n{text}")
    if forbidden:
        return deny(forbidden)

    if is_agent_tool(tool):
        return 0 if role in MANAGERS else deny(f"{role} is a leaf and cannot spawn agents")

    if is_generic_dispatcher(tool, tool_input):
        return deny(f"{role} cannot use a generic provider dispatcher")

    if is_github_tool(tool):
        if role not in MCP_READ_ROLES:
            return deny(f"{role} has no GitHub capability assignment")
        mutation = mcp_mutation_kind(tool, tool_input)
        if mutation is None:
            return 0
        if role not in GITHUB_MUTATION_ROLES:
            return deny(f"{role} has read-only GitHub capability access")
        return (
            0
            if allowed_github_mutation(
                role, mutation, tool_input, authorization=authorization
            )
            else deny(f"{role} cannot perform GitHub capability mutation {mutation}")
        )

    if tool.startswith("mcp__"):
        if role not in MCP_READ_ROLES:
            return deny(f"{role} has no MCP assignment")
        mutation = mcp_mutation_kind(tool, tool_input)
        if mutation is None:
            return 0
        if role not in GITHUB_MUTATION_ROLES:
            return deny(f"{role} has read-only MCP access")
        return (
            0
            if allowed_github_mutation(
                role, mutation, tool_input, authorization=authorization
            )
            else deny(f"{role} cannot perform MCP mutation {mutation}")
        )

    if tool in {"apply_patch", "Edit", "Write"}:
        if role not in LOCAL_WRITE_ROLES:
            return deny(f"{role} has no repository write assignment")
        cwd_value = event.get("cwd")
        if not isinstance(cwd_value, str):
            return deny(f"{role} has no cwd for path validation")
        paths = patch_paths(tool_input, Path(cwd_value))
        if not paths:
            return deny(f"{role} patch paths could not be resolved")
        rejected = [path.as_posix() for path in paths if not path_allowed(role, path)]
        if rejected:
            return deny(f"{role} cannot edit: {', '.join(rejected)}")
        return 0

    if is_shell_tool(tool):
        if uses_raw_network_client(text):
            return deny(f"{role} must use its assigned provider capability for network access")
        if role == "pr-review-resolver":
            return deny("pr-review-resolver delegates all shell validation to test roles")
        if role == "rpm_ready_ticket_claimer":
            recognized, authorized = attest_claim_controller(
                event, tool_input, trusted_claim
            )
            if recognized and not authorized:
                return deny("rpm_ready_ticket_claimer claim controller lacks parent authorization")
        mutation = shell_mutation_kind(text)
        if mutation is None:
            return 0
        if role not in GITHUB_MUTATION_ROLES:
            return deny(f"{role} cannot mutate GitHub through a shell command")
        try:
            shlex.split(text)
        except ValueError:
            return deny(f"{role} supplied an unparsable shell mutation")
        return (
            0
            if allowed_github_mutation(
                role,
                mutation,
                tool_input,
                text,
                authorization=authorization,
            )
            else deny(f"{role} cannot perform shell mutation {mutation}")
        )

    return 0


def main() -> int:
    event = read_event()
    name = event.get("hook_event_name")
    if name == "SubagentStart":
        return register(event)
    if name == "SubagentStop":
        return cleanup(event)
    if name == "PreToolUse":
        return check_tool(event)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
