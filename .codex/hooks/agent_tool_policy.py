#!/usr/bin/env python3
"""Enforce role-specific tool, GitHub mutation, and patch boundaries."""

from __future__ import annotations

import hashlib
import json
import re
import shlex
import sys
import tempfile
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
    if any(token in GENERIC_EXECUTOR_WORDS for token in tokens):
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
    if not re.search(r"(?:api\.)?github\.com\b", lowered):
        return False
    return bool(
        re.search(
            r"(?<![a-z0-9_])"
            r"(?:node(?:js)?|perl|php|python(?:3(?:\.\d+)?)?|ruby)"
            r"(?![a-z0-9_])",
            lowered,
        )
    )


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
        generic_executor = any(
            token in GENERIC_EXECUTOR_WORDS for token in operation_tokens(tool)
        )
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
    if has_issue and "create" in context_tokens:
        return "issue_create"
    if has_project and any(word in context_tokens for word in ("add", "create")):
        return "project_add"
    if has_project:
        return "project_other"
    if "label" in context_tokens:
        return "label"
    if has_issue and any(word in context_tokens for word in ("update", "edit")):
        return "issue_edit"
    if has_issue:
        return "issue_other"
    return "unknown_mutation"


def allowed_github_mutation(
    role: str, kind: str, tool_input: object, shell_text: str = ""
) -> bool:
    if role == "rpm_idea_issue_creator":
        return kind in {"issue_create", "project_add"}
    if role == "rpm_followup_issue_creator":
        return kind == "issue_create"
    if role == "rpm_issue_refiner":
        if kind not in {"issue_edit", "label"}:
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
        if kind not in {"issue_edit", "label"}:
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
            if allowed_github_mutation(role, mutation, tool_input)
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
            if allowed_github_mutation(role, mutation, tool_input)
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
            if allowed_github_mutation(role, mutation, tool_input, text)
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
