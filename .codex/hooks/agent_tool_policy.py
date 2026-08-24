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
RPM_ROLES = {
    "rpm_workflow_manager",
    "rpm_backlog_manager",
    "rpm_issue_manager",
    "pr-review-resolver",
    "rpm_spec_updater",
    "rpm_test_author",
    "rpm_implementer",
    "rpm_backlog_scout",
    "rpm_idea_issue_creator",
    "rpm_issue_fetcher",
    "rpm_issue_researcher",
    "rpm_issue_refiner",
    "rpm_issue_readiness_reviewer",
    "rpm_ready_ticket_claimer",
    "rpm_followup_issue_creator",
    "rpm_spec_reviewer",
    "rpm_issue_spec_reconciler",
    "rpm_test_runner",
    "rpm_verifier",
    "rpm_adversarial_reviewer",
}
MCP_MUTATION_VERBS = {
    "create",
    "update",
    "edit",
    "write",
    "delete",
    "remove",
    "add",
    "close",
    "reopen",
    "comment",
    "label",
    "mutation",
    "merge",
    "set",
    "assign",
    "archive",
    "publish",
    "transfer",
    "approve",
    "pin",
    "mutate",
    "modify",
    "commit",
    "claim",
    "resolve",
}
MCP_HTTP_MUTATION_VERBS = {"post", "patch", "put"}
MCP_OPERATION_KEYS = {
    "action",
    "operation",
    "method",
    "http_method",
    "request_method",
    "httpmethod",
    "requestmethod",
    "mutation",
    "op",
    "verb",
    "command",
    "intent",
}
POLICY_DIR = Path(tempfile.gettempdir()) / "rpm-agent-tool-policy"
PATCH_PATH = re.compile(
    r"^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+?)\s*$",
    re.MULTILINE,
)
STATE_LABELS = {
    "agent:research",
    "agent:ready",
    "agent:claimed",
    "agent:review-pending",
    "agent:awaiting-merge",
    "agent:blocked",
}
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


def registration_path(transcript: str) -> Path:
    digest = hashlib.sha256(transcript.encode()).hexdigest()
    return POLICY_DIR / f"{digest}.registered"


def register(event: dict[str, object]) -> int:
    role = event.get("agent_type")
    transcript = transcript_path(event, start_or_stop=True)
    if not isinstance(role, str) or role not in RPM_ROLES:
        return 0
    if transcript is None:
        return deny(f"{role} registration is missing an agent transcript path")
    try:
        POLICY_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
        registration_path(transcript).write_text(json.dumps({"agent_type": role}))
        policy_path(transcript).write_text(json.dumps({"agent_type": role}))
    except OSError as error:
        return deny(f"{role} policy registration failed: {error}")
    return 0


def cleanup(event: dict[str, object]) -> int:
    role = event.get("agent_type")
    transcript = transcript_path(event, start_or_stop=True)
    if transcript is None:
        if isinstance(role, str) and role in RPM_ROLES:
            return deny(f"{role} cleanup is missing an agent transcript path")
        return 0
    for path in (policy_path(transcript), registration_path(transcript)):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    return 0


def current_role(event: dict[str, object]) -> str | None:
    transcript = transcript_path(event)
    if transcript is None:
        return None
    try:
        registration = json.loads(registration_path(transcript).read_text())
        value = json.loads(policy_path(transcript).read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
    registered_role = (
        registration.get("agent_type") if isinstance(registration, dict) else None
    )
    role = value.get("agent_type") if isinstance(value, dict) else None
    if (
        not isinstance(registered_role, str)
        or registered_role not in RPM_ROLES
        or registered_role != role
    ):
        return None
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
        selected: list[str] = []
        for key, child in value.items():
            key_text = str(key).casefold()
            if key_text in MCP_OPERATION_KEYS or key_text in MCP_MUTATION_VERBS:
                selected.extend(flatten_strings(child))
                if key_text in MCP_MUTATION_VERBS:
                    selected.append(key_text)
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
        return not (text.startswith(".codex/") or text.startswith(".agents/"))
    return False


def deny(reason: str) -> int:
    print(f"RPM agent tool policy blocked this call: {reason}", file=sys.stderr)
    return 2


def normalized_tool(tool: str) -> str:
    return tool.replace("-", "_").casefold()


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
    if "mergepullrequest" in lowered or re.search(
        r"\bmerge(?:_pull_request|pullrequest)\b", lowered
    ):
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
    if re.search(r"\bgh\s+api\b", lowered):
        method_flag = re.compile(r"(?<!\S)(?:--method|-x)(?=$|\s|=|[a-z])")
        methods = re.findall(
            r"(?<!\S)(?:--method|-x)(?:=|\s+|(?=[a-z]))([a-z][a-z0-9_-]*)\b",
            lowered,
        )
        if method_flag.search(lowered) and not methods:
            return "raw_api_unknown"
        if any(method in {"post", "patch", "put", "delete"} for method in methods):
            return "raw_api_mutation"
        if any(method not in {"get", "head", "options"} for method in methods):
            return "raw_api_unknown"
        if re.search(
            r"(?<!\S)(?:--field|--raw-field|-f|-F|--input|--input-file)(?=$|\s|=)",
            lowered,
        ) and not methods:
            return "raw_api_mutation"
        if re.search(r"\bmutation\b", lowered):
            return "raw_api_unknown"
    return None


def has_mcp_word(text: str, word: str) -> bool:
    return re.search(rf"(?<![a-z0-9]){re.escape(word)}(?![a-z0-9])", text) is not None


def has_explicit_mcp_read_action(tool: str) -> bool:
    command = normalized_tool(tool).split("__")[-1]
    return any(
        command == action or command.startswith(f"{action}_")
        for action in ("get", "list", "fetch", "read", "search", "view")
    )


def mcp_mutation_kind(tool: str, tool_input: object) -> str | None:
    operation_text = " ".join(operation_values(tool_input)).casefold()
    lowered = f"{normalized_tool(tool)} {operation_text}"
    operation_mutation = any(
        has_mcp_word(operation_text, word)
        for word in MCP_MUTATION_VERBS | MCP_HTTP_MUTATION_VERBS
    )
    if not operation_mutation and has_explicit_mcp_read_action(tool):
        return None
    if not operation_mutation and not any(
        has_mcp_word(lowered, word) for word in MCP_MUTATION_VERBS
    ):
        return None
    if has_mcp_word(lowered, "merge"):
        return "merge"
    if has_mcp_word(lowered, "issue") and has_mcp_word(lowered, "create"):
        return "issue_create"
    if has_mcp_word(lowered, "project") and any(
        has_mcp_word(lowered, word) for word in ("add", "create")
    ):
        return "project_add"
    if has_mcp_word(lowered, "project"):
        return "project_other"
    if has_mcp_word(lowered, "label"):
        return "label"
    if has_mcp_word(lowered, "issue") and any(
        has_mcp_word(lowered, word) for word in ("update", "edit")
    ):
        return "issue_edit"
    if has_mcp_word(lowered, "issue"):
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
        forbidden_keys = {
            "title",
            "body",
            "body_file",
            "assignees",
            "milestone",
            "state",
        }
        if collect_keys(tool_input) & forbidden_keys:
            return False
        lowered = shell_text.casefold()
        if lowered and any(
            flag in lowered
            for flag in ("--body", "--body-file", "--title", "--assignee", "--milestone")
        ):
            return False
        labels = {
            value
            for value in flatten_strings(tool_input)
            if isinstance(value, str) and value.startswith("agent:")
        }
        return not labels or labels <= STATE_LABELS
    return False


def check_tool(event: dict[str, object]) -> int:
    transcript = transcript_path(event)
    declared_role = event.get("agent_type")
    role = current_role(event)
    if role is None:
        state_exists = transcript is not None and (
            policy_path(transcript).is_file() or registration_path(transcript).is_file()
        )
        if (
            isinstance(declared_role, str)
            and declared_role in RPM_ROLES
        ) or state_exists:
            return deny("known RPM role has no valid registered policy state")
        return 0
    if isinstance(declared_role, str) and declared_role != role:
        return deny("registered RPM role does not match the declared agent type")

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

    if tool.startswith("mcp__"):
        if role not in MCP_READ_ROLES:
            return deny(f"{role} has no MCP assignment")
        mutation = mcp_mutation_kind(tool, tool_input)
        if mutation is None:
            return 0
        if role not in GITHUB_MUTATION_ROLES:
            return deny(f"{role} has read-only MCP access; detected mutation {mutation}")
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
