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
MANAGER_CONTACT_ROLES = {
    "rpm_workflow_manager:rpm_backlog_manager",
    "rpm_workflow_manager:rpm_issue_manager",
    "rpm_backlog_manager:rpm_backlog_scout",
    "rpm_backlog_manager:rpm_idea_issue_creator",
    "rpm_backlog_manager:rpm_issue_researcher",
    "rpm_backlog_manager:rpm_issue_refiner",
    "rpm_backlog_manager:rpm_issue_readiness_reviewer",
    "rpm_backlog_manager:rpm_ready_ticket_claimer",
    "rpm_issue_manager:rpm_issue_fetcher",
    "rpm_issue_manager:rpm_spec_reviewer",
    "rpm_issue_manager:rpm_issue_spec_reconciler",
    "rpm_issue_manager:rpm_spec_updater",
    "rpm_issue_manager:rpm_test_author",
    "rpm_issue_manager:rpm_implementer",
    "rpm_issue_manager:rpm_test_runner",
    "rpm_issue_manager:rpm_verifier",
    "rpm_issue_manager:rpm_adversarial_reviewer",
    "rpm_issue_manager:rpm_followup_issue_creator",
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
MCP_COMPOUND_MUTATION_VERBS = MCP_MUTATION_VERBS
MCP_STRONG_MUTATION_VERBS = MCP_MUTATION_VERBS - {
    "archive",
    "comment",
    "commit",
    "label",
    "publish",
}
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
MCP_READ_ACTIONS = {"get", "list", "fetch", "read", "search", "view"}
GH_READ_ACTIONS = {
    "issue": {"list", "view"},
    "project": {"field-list", "item-list", "list", "view"},
    "label": {"list"},
    "pr": {"checks", "diff", "list", "status", "view"},
    "repo": {"list", "view"},
    "release": {"download", "list", "view"},
    "workflow": {"list", "view"},
    "run": {"download", "list", "view", "watch"},
    "search": {"code", "commits", "issues", "prs", "repos"},
}
GH_GLOBAL_VALUE_FLAGS = {"--hostname", "--repo", "-R"}
REFINER_ISSUE_EDIT_FLAGS = {
    "--add-label",
    "--body",
    "--body-file",
    "--remove-label",
    "-F",
    "-b",
}
CLAIMER_ISSUE_EDIT_FLAGS = {"--add-label", "--remove-label"}
STRUCTURED_TARGET_KEYS = {"issue", "issue_number", "owner", "repo", "repository"}
REFINER_STRUCTURED_KEYS = STRUCTURED_TARGET_KEYS | {
    "add_label",
    "add_labels",
    "body",
    "body_file",
    "label",
    "labels",
    "remove_label",
    "remove_labels",
}
CLAIMER_STRUCTURED_KEYS = STRUCTURED_TARGET_KEYS | {
    "add_label",
    "add_labels",
    "label",
    "labels",
    "remove_label",
    "remove_labels",
}
CREATOR_ISSUE_KEYS = {
    "body",
    "label",
    "labels",
    "owner",
    "repo",
    "repository",
    "title",
}
PROJECT_ADD_KEYS = {"content_id", "content_type", "owner", "project_number"}
LABEL_INPUT_KEYS = {
    "label",
    "labels",
    "add_label",
    "add_labels",
    "remove_label",
    "remove_labels",
}
SHELL_CONTROL_TOKENS = {";", "&&", "||", "|", "&"}
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
CLAIMER_STATE_LABELS = {"agent:ready", "agent:claimed"}
EXPECTED_REPOSITORY_OWNER = "nerdchanii"
EXPECTED_REPOSITORY_NAME = "rpm"
SHELL_TOOL_PARTS = {
    "bash",
    "shell",
    "exec",
    "exec_command",
    "functions.exec",
    "functions.exec_command",
    "terminal",
}
COLLABORATION_TOOL_PARTS = {
    "spawn_agent",
    "followup_task",
    "send_message",
    "interrupt_agent",
    "list_agents",
    "wait_agent",
}
COLLABORATION_STATUS_TOOL_PARTS = {"list_agents", "wait_agent"}


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


def shell_source(value: object) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("cmd", "command", "script", "code", "source"):
            candidate = value.get(key)
            if isinstance(candidate, str):
                return candidate
    return "\n".join(flatten_strings(value))


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
            if key_text in MCP_OPERATION_KEYS:
                selected.extend(flatten_strings(child))
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


def collaboration_tool_part(tool: str) -> str | None:
    normalized = normalized_tool(tool)
    if normalized == "agent" or normalized.endswith("__agent"):
        return "agent"
    for part in COLLABORATION_TOOL_PARTS:
        if (
            normalized == part
            or normalized.endswith(f"__{part}")
            or normalized.endswith(f".{part}")
        ):
            return part
    if "collaboration." in normalized or "collaboration__" in normalized:
        return "unknown_contact"
    return None


def is_agent_tool(tool: str) -> bool:
    return collaboration_tool_part(tool) is not None


def requested_agent_role(tool_input: object) -> str | None:
    if not isinstance(tool_input, dict):
        return None
    for key in ("agent_type", "subagent_type"):
        value = tool_input.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def manager_report_allowed(manager: str, report: str) -> bool:
    return f"{manager}:{report}" in MANAGER_CONTACT_ROLES


def manager_contact_allowed(manager: str, tool_input: object) -> bool:
    if not isinstance(tool_input, dict):
        return False
    target = tool_input.get("target")
    return (
        isinstance(target, str)
        and "/" not in target
        and manager_report_allowed(manager, target)
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
    if re.search(r"\bgh\s+pr\s+merge\b", lowered) or (
        has_shell_indirection(text) and re.search(r"\bpr\s+merge\b", lowered)
    ):
        return "RPM subagents cannot merge pull requests"
    if "mergepullrequest" in lowered or re.search(
        r"\bmerge(?:_pull_request|pullrequest)\b", lowered
    ):
        return "RPM subagents cannot merge pull requests"
    return None


def shell_words(text: str) -> list[str] | None:
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|")
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return None


def has_shell_indirection(text: str) -> bool:
    words = shell_words(text)
    if words is None:
        return re.search(r"\b(?:ba|da|z)?sh\b|\beval\b", text, re.IGNORECASE) is not None
    for index, token in enumerate(words):
        executable = shell_executable_name(token)
        if executable == "eval":
            return True
        if executable in {"sh", "bash", "dash", "zsh"} and nested_shell_text(
            words, index
        ) is not None:
            return True
    return False


def nested_shell_text(words: list[str], index: int) -> str | None:
    option_index = index + 1
    while option_index < len(words) and words[option_index].startswith("-"):
        option = words[option_index]
        if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", option):
            return words[option_index + 1] if option_index + 1 < len(words) else ""
        option_index += 1
    return None


def indirect_script_has_possible_gh(text: str, depth: int = 0) -> bool:
    words = shell_words(text)
    if words is None:
        return True
    if any(
        is_dynamic_shell_executable(token)
        and is_shell_command_position(words, index)
        for index, token in enumerate(words)
    ):
        return True
    if depth >= 3:
        return has_shell_indirection(text)
    for index, token in enumerate(words):
        executable = shell_executable_name(token)
        nested_text: str | None = None
        if executable in {"sh", "bash", "dash", "zsh"}:
            nested_text = nested_shell_text(words, index)
        elif executable == "eval":
            end = index + 1
            while end < len(words) and words[end] not in SHELL_CONTROL_TOKENS:
                end += 1
            nested_text = " ".join(words[index + 1 : end])
        if nested_text is not None and indirect_script_has_possible_gh(
            nested_text, depth + 1
        ):
            return True
    return False


def has_indirect_github_mutation_shape(text: str) -> bool:
    if not has_shell_indirection(text):
        return False
    # Shells and ``eval`` can expand both the gh executable and every command
    # token after this hook has inspected the source text. Parse once with
    # shell quoting removed so constructions such as ``g\"h\"`` cannot hide
    # the executable. A dynamic nested executable is also opaque: its value is
    # unknowable at policy time. Literal nested commands such as ``curl`` stay
    # available when they contain no gh executable or dynamic command token.
    words = shell_words(text)
    if words is None:
        return True
    if any(shell_executable_name(token) == "gh" for token in words):
        return True
    for index, token in enumerate(words):
        executable = shell_executable_name(token)
        nested_text: str | None = None
        if executable in {"sh", "bash", "dash", "zsh"}:
            nested_text = nested_shell_text(words, index)
        elif executable == "eval":
            end = index + 1
            while end < len(words) and words[end] not in SHELL_CONTROL_TOKENS:
                end += 1
            nested_text = " ".join(words[index + 1 : end])
        if nested_text is None:
            continue
        if indirect_script_has_possible_gh(nested_text):
            return True
    return False


def shell_executable_name(token: str) -> str:
    # ``shlex`` keeps assignment and command-substitution prefixes attached to
    # the executable token (for example ``result=$(gh``). Normalize those
    # wrappers as well as absolute paths before checking the executable name.
    candidate = re.split(r"[=$(`]", token)[-1].strip("()$`")
    return PurePosixPath(candidate).name


def shell_token_value(token: str) -> str:
    return token.strip("()$`")


def is_dynamic_shell_token(token: str) -> bool:
    return "$" in token or "`" in token


def is_dynamic_shell_executable(token: str) -> bool:
    return is_possible_gh_executable(token) or any(
        marker in token for marker in ("*", "?", "[", "{")
    )


def has_shell_executable_expansion(token: str) -> bool:
    return is_dynamic_shell_token(token) or any(
        marker in token for marker in ("*", "?", "[", "{")
    )


def is_possible_gh_executable(token: str) -> bool:
    if shell_executable_name(token) == "gh":
        return True
    return is_dynamic_shell_token(token) or any(
        marker in token for marker in ("*", "?", "[", "{")
    )


def is_shell_command_position(words: list[str], index: int) -> bool:
    segment_start = index
    while segment_start > 0 and words[segment_start - 1] not in SHELL_CONTROL_TOKENS:
        segment_start -= 1
    prefix = words[segment_start:index]
    if not prefix:
        return True
    if all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", token) for token in prefix):
        return True
    return shell_executable_name(prefix[0]) in {
        "command",
        "env",
        "exec",
        "find",
        "nice",
        "nohup",
        "sudo",
        "timeout",
        "xargs",
    }


def gh_top_level_command_index(tokens: list[str]) -> int | None:
    index = 1
    while index < len(tokens):
        token = tokens[index]
        if is_dynamic_shell_token(token):
            return index
        normalized = shell_token_value(token)
        flag = normalized.split("=", 1)[0]
        if normalized.startswith("-R") and len(normalized) > 2:
            flag = "-R"
        if flag in GH_GLOBAL_VALUE_FLAGS:
            if "=" in normalized or (flag == "-R" and len(normalized) > 2):
                index += 1
                continue
            if index + 1 >= len(tokens) or is_dynamic_shell_token(tokens[index + 1]):
                return None
            index += 2
            continue
        if normalized.startswith("-"):
            return None
        return index
    return None


def gh_invocations(text: str) -> list[list[str]] | None:
    words = shell_words(text)
    if words is None:
        return None
    invocations: list[list[str]] = []
    index = 0
    while index + 1 < len(words):
        if not is_possible_gh_executable(words[index]) or not is_shell_command_position(
            words, index
        ):
            index += 1
            continue
        if words[index + 1] in SHELL_CONTROL_TOKENS:
            index += 1
            continue
        end = index + 1
        while end < len(words) and words[end] not in SHELL_CONTROL_TOKENS:
            end += 1
        invocations.append(["gh", *words[index + 1 : end]])
        index = end
    return invocations


def gh_command_index(tokens: list[str], command: str) -> int | None:
    index = gh_top_level_command_index(tokens)
    if index is not None and shell_token_value(tokens[index]).casefold() == command:
        return index
    return None


def gh_api_invocations(text: str) -> list[list[str]] | None:
    invocations = gh_invocations(text)
    if invocations is None:
        return None
    api_invocations: list[list[str]] = []
    for tokens in invocations:
        index = gh_command_index(tokens, "api")
        if index is not None:
            api_invocations.append(["gh", "api", *tokens[index + 1 :]])
    return api_invocations


def has_raw_possible_gh_command(text: str, command: str) -> bool:
    expansion = (
        r"(?:\$\{[^}\n]*\}|\$[A-Za-z0-9_]+|\$\([^)]*\)|`[^`\n]*`)"
    )
    literal = re.search(
        rf"\bgh[\"']?\s+{re.escape(command)}\b", text, re.IGNORECASE
    )
    if literal is not None:
        return True
    wrapped = re.search(
        rf"(?P<expansion>{expansion})[\"']?\s+{re.escape(command)}\b",
        text,
        re.IGNORECASE,
    )
    if wrapped is None:
        return False
    expansion_text = wrapped.group("expansion").casefold()
    return "gh" in expansion_text or (
        re.fullmatch(r"\$[0-9]+", expansion_text) is not None
        and re.search(r"\bgh\b", text, re.IGNORECASE) is not None
    )


def gh_api_method(tokens: list[str]) -> list[str] | None:
    methods: list[str] = []
    index = 2
    while index < len(tokens):
        token = shell_token_value(tokens[index]).casefold()
        method: str | None = None
        if token in {"--method", "-x"}:
            if index + 1 >= len(tokens):
                return None
            method = shell_token_value(tokens[index + 1]).casefold()
            index += 1
        elif token.startswith("--method="):
            method = token.split("=", 1)[1]
        elif token.startswith("-x="):
            method = token.split("=", 1)[1]
        elif token.startswith("-x") and len(token) > 2:
            method = token[2:]
        if method is not None:
            methods.append(method)
        index += 1
    return methods


def gh_api_has_payload_flag(tokens: list[str]) -> bool:
    for raw_token in tokens[2:]:
        token = shell_token_value(raw_token).casefold()
        if token in {
            "--field",
            "--raw-field",
            "-f",
            "-F",
            "--input",
            "--input-file",
        }:
            return True
        if token.startswith(("--field=", "--raw-field=", "--input=", "--input-file=")):
            return True
        if token.startswith(("-f", "-F")) and len(token) > 2:
            return True
    return False


def gh_api_mutation_kind(text: str) -> str | None:
    invocations = gh_api_invocations(text)
    raw_invocation = has_raw_possible_gh_command(text, "api")
    if invocations is None:
        return "raw_api_unknown" if raw_invocation else None
    if not invocations and raw_invocation:
        return "raw_api_unknown"
    for tokens in invocations:
        if any(is_dynamic_shell_token(token) for token in tokens[2:]):
            return "raw_api_unknown"
        methods = gh_api_method(tokens)
        if methods is None:
            return "raw_api_unknown"
        if any(method in {"post", "patch", "put", "delete"} for method in methods):
            return "raw_api_mutation"
        if any(method not in {"get", "head", "options"} for method in methods):
            return "raw_api_unknown"
        if gh_api_has_payload_flag(tokens) and not methods:
            return "raw_api_mutation"
        if any(token.casefold() == "mutation" for token in tokens[2:]):
            return "raw_api_unknown"
    return None


def source_has_gh_evidence(text: str) -> bool:
    if re.search(r"(?<![a-z0-9_-])gh(?![a-z0-9_-])", text, re.IGNORECASE):
        return True
    words = shell_words(text)
    return words is None or any(
        shell_executable_name(token) == "gh" for token in words
    )


def has_command_substitution(text: str) -> bool:
    return re.search(r"\$\(|`|[<>]\(", text) is not None


def nested_mcp_mutation(text: str) -> bool:
    static_access_removed = re.sub(r"\btools\.[A-Za-z_][A-Za-z0-9_]*", "", text)
    if (
        "ALL_TOOLS" in text
        or re.search(r"\btools\b", static_access_removed)
        or re.search(
            r"\\(?:u[0-9A-Fa-f]{4}|x[0-9A-Fa-f]{2})|"
            r"\b(?:eval|Function|Reflect\.get)\s*\(|"
            r"\b(?:constructor|globalThis)\b",
            text,
        )
    ):
        return True
    names = set(re.findall(r"\b(mcp__[A-Za-z0-9_]+)", text))
    return any(mcp_mutation_kind(name, {}) is not None for name in names)


def has_github_http_mutation(text: str) -> bool:
    words = shell_words(text)
    normalized = " ".join(words) if words is not None else text
    lowered = f"{text}\n{normalized}".casefold()
    if not re.search(r"\b(?:curl|http|https|httpie)\b", lowered):
        return False
    if not any(
        marker in lowered
        for marker in (
            "api.github.com",
            "uploads.github.com",
            "$github_api_url",
            "${github_api_url",
        )
    ):
        return False
    return re.search(
        r"(?:--request|-x)\s*(?:=\s*)?(?:post|patch|put|delete)\b|"
        r"-x(?:post|patch|put|delete)\b|"
        r"\b(?:http|https|httpie)\s+(?:post|patch|put|delete)\b|"
        r"(?:--data(?:-ascii|-binary|-raw|-urlencode)?|--form|--json|"
        r"--upload-file|-d|-f|-t)\b|"
        r"(?:--request|-x)\s+[\"']?(?:\$|`)",
        lowered,
    ) is not None or re.search(
        r"\bmethod\s*=\s*[\"']?(?:post|patch|put|delete)\b|"
        r"\brequests?\.(?:post|patch|put|delete)\s*\(|"
        r"\burllib\.request\.Request\s*\([^\n]*(?:data\s*=|"
        r"method\s*=\s*[\"']?(?:post|patch|put|delete))",
        lowered,
    ) is not None or re.search(
        r"\b(?:post|patch|put|delete)\b|"
        r"\b(?:body|data|json|payload)\s*=",
        lowered,
    ) is not None


def has_raw_github_mutation_shape(text: str) -> bool:
    lowered = text.casefold()
    patterns = (
        r"\bissue\s+(?:create|edit|comment|close|reopen|delete|transfer|pin)\b",
        r"\bproject\s+(?:item-add|item-edit|item-delete|edit|delete|copy|close)\b",
        r"\bpr\s+(?:comment|create|edit|review|close|reopen|ready|merge)\b",
        r"\blabel\s+(?:create|edit|delete|clone)\b",
        r"\brepo\s+(?:archive|create|delete|edit|fork|rename|sync)\b",
        r"\brelease\s+(?:create|delete|edit|upload)\b",
        r"\bworkflow\s+(?:disable|enable|run)\b",
    )
    return any(re.search(pattern, lowered) is not None for pattern in patterns)


def has_git_push(text: str) -> bool:
    words = shell_words(text)
    normalized = " ".join(words) if words is not None else text
    if re.search(
        r"\balias\.[A-Za-z0-9_-]+\s*=\s*push\b",
        f"{text}\n{normalized}",
        re.IGNORECASE,
    ):
        return True
    if words is not None:
        for index, token in enumerate(words):
            if shell_executable_name(token) != "git" or not is_shell_command_position(
                words, index
            ):
                continue
            end = index + 1
            while end < len(words) and words[end] not in SHELL_CONTROL_TOKENS:
                end += 1
            if any(
                shell_token_value(candidate).casefold() == "push"
                for candidate in words[index + 1 : end]
            ):
                return True
            if any(is_dynamic_shell_token(candidate) for candidate in words[index + 1 : end]):
                return True
        segments: list[list[str]] = [[]]
        for token in words:
            if token in SHELL_CONTROL_TOKENS:
                segments.append([])
            else:
                segments[-1].append(token)
        if any(
            any(shell_token_value(token).casefold() == "push" for token in segment)
            and any(
                token == "origin"
                or "refs/heads/" in token
                or "://" in token
                or "@" in token
                for token in segment
            )
            for segment in segments
        ):
            return True
    return re.search(r"(?<![a-z0-9_-])git\s+push\b", text, re.IGNORECASE) is not None


def has_unsupported_dynamic_gh_execution(text: str) -> bool:
    words = shell_words(text)
    if words is None or not source_has_gh_evidence(text):
        return words is None
    if any(
        has_shell_executable_expansion(token)
        and is_shell_command_position(words, index)
        for index, token in enumerate(words)
    ):
        return True
    if not any(has_shell_executable_expansion(token) for token in words):
        return False
    invocations = gh_invocations(text)
    return invocations is None or not invocations


def shell_mutation_kind(text: str) -> str | None:
    if "\n" in text and source_has_gh_evidence(text):
        return "raw_api_unknown"
    if has_command_substitution(text) and source_has_gh_evidence(text):
        return "raw_api_unknown"
    if nested_mcp_mutation(text):
        return "nested_mcp_mutation"
    if has_github_http_mutation(text):
        return "raw_api_unknown"
    if has_git_push(text):
        return "git_push"
    if has_unsupported_dynamic_gh_execution(text):
        return "raw_api_unknown"
    if has_indirect_github_mutation_shape(text):
        return "raw_api_unknown"
    invocations = gh_invocations(text)
    if invocations is None:
        return "raw_api_unknown" if any(
            has_raw_possible_gh_command(text, command)
            for command in ("api", "issue", "project", "pr", "label")
        ) else None
    if not invocations and has_raw_github_mutation_shape(text):
        return "raw_api_unknown"
    for tokens in invocations:
        command_index = gh_top_level_command_index(tokens)
        if command_index is None:
            return "raw_api_unknown"
        if is_dynamic_shell_token(tokens[command_index]):
            return "raw_api_unknown"
        command = shell_token_value(tokens[command_index]).casefold()
        if command == "api":
            continue
        if command == "status":
            continue
        issue_index = gh_command_index(tokens, "issue")
        if issue_index is not None:
            if issue_index + 1 >= len(tokens):
                return "other_github"
            action_token = tokens[issue_index + 1]
            if is_dynamic_shell_token(action_token):
                return "raw_api_unknown"
            action = shell_token_value(action_token).casefold()
            if action in {
                "create",
                "edit",
                "comment",
                "close",
                "reopen",
                "delete",
                "transfer",
                "pin",
            } and any(
                is_dynamic_shell_token(token)
                for token in tokens[issue_index + 2 :]
            ):
                return "raw_api_unknown"
            if action == "create":
                return "issue_create"
            if action == "edit" and any(
                shell_token_value(token).casefold().startswith(
                    ("--add-label", "--remove-label")
                )
                for token in tokens[issue_index + 2 :]
            ):
                return "label"
            if action == "edit":
                return "issue_edit"
            if action in {"comment", "close", "reopen", "delete", "transfer", "pin"}:
                return "issue_other"
            if action in GH_READ_ACTIONS["issue"]:
                continue
            return "other_github"
        project_index = gh_command_index(tokens, "project")
        if project_index is not None:
            if project_index + 1 >= len(tokens):
                return "other_github"
            action_token = tokens[project_index + 1]
            if is_dynamic_shell_token(action_token):
                return "raw_api_unknown"
            action = shell_token_value(action_token).casefold()
            if action in {
                "item-add",
                "item-edit",
                "item-delete",
                "edit",
                "delete",
                "copy",
                "close",
            } and any(
                is_dynamic_shell_token(token)
                for token in tokens[project_index + 2 :]
            ):
                return "raw_api_unknown"
            if action == "item-add":
                return "project_add"
            if action in {"item-edit", "item-delete", "edit", "delete", "copy", "close"}:
                return "project_other"
            if action in GH_READ_ACTIONS["project"]:
                continue
            return "other_github"
        label_index = gh_command_index(tokens, "label")
        if label_index is not None:
            if label_index + 1 < len(tokens) and (
                not is_dynamic_shell_token(tokens[label_index + 1])
                and shell_token_value(tokens[label_index + 1]).casefold()
                in GH_READ_ACTIONS["label"]
            ):
                continue
            return "other_github"
        pr_index = gh_command_index(tokens, "pr")
        if pr_index is not None:
            if pr_index + 1 >= len(tokens):
                return "other_github"
            action_token = tokens[pr_index + 1]
            if is_dynamic_shell_token(action_token):
                return "raw_api_unknown"
            action = shell_token_value(action_token).casefold()
            if action in {"comment", "create", "edit", "review", "close", "reopen", "ready", "merge"}:
                return "other_github"
            if action in GH_READ_ACTIONS["pr"]:
                continue
            return "other_github"
        if command in GH_READ_ACTIONS:
            action_index = command_index + 1
            if len(tokens) <= action_index or is_dynamic_shell_token(
                tokens[action_index]
            ):
                return "other_github"
            action = shell_token_value(tokens[action_index]).casefold()
            if action in GH_READ_ACTIONS[command]:
                continue
            return "other_github"
        return "other_github"
    if not invocations and any(
        has_raw_possible_gh_command(text, command)
        for command in ("issue", "project", "pr", "label")
    ):
        return "other_github"
    return gh_api_mutation_kind(text)


def has_mcp_word(text: str, word: str) -> bool:
    return re.search(rf"(?<![a-z0-9]){re.escape(word)}(?![a-z0-9])", text) is not None


def has_explicit_mcp_read_action(tool: str) -> bool:
    command = normalized_tool(tool).split("__")[-1]
    return any(
        re.search(rf"(?:^|_){action}(?:_|$)", command) is not None
        for action in MCP_READ_ACTIONS
    )


def mcp_segment_action(tokens: list[str]) -> str | None:
    for token in tokens:
        if token in MCP_READ_ACTIONS:
            return "read"
        if token in MCP_COMPOUND_MUTATION_VERBS:
            return "mutation"
    return None


def has_compound_mcp_mutation(tool: str) -> bool:
    command = normalized_tool(tool).split("__")[-1]
    tokens = command.split("_")
    for index, token in enumerate(tokens):
        if token not in {"and", "or"}:
            continue
        left = tokens[:index]
        right = tokens[index + 1 :]
        left_action = mcp_segment_action(left)
        right_action = mcp_segment_action(right)
        if (
            left_action == "read" and right_action != "read"
        ) or (
            right_action == "read" and left_action != "read"
        ):
            return True
    return False


def has_trailing_mcp_mutation(tool: str) -> bool:
    command = normalized_tool(tool).split("__")[-1]
    tokens = command.split("_")
    read_index = next(
        (index for index, token in enumerate(tokens) if token in MCP_READ_ACTIONS),
        None,
    )
    if read_index is None:
        return False
    tail = tokens[read_index + 1 :]
    if any(token in MCP_STRONG_MUTATION_VERBS for token in tail):
        return True
    if any(
        token in MCP_HTTP_MUTATION_VERBS and index > 0
        for index, token in enumerate(tail)
    ):
        return True
    if len(tail) > 1 and tail[0] in MCP_HTTP_MUTATION_VERBS:
        return True
    return any(
        token in {"archive", "comment", "commit", "label", "publish"}
        and index > 0
        and tail[index - 1] in {"and", "or", "then", "to"}
        for index, token in enumerate(tail)
    )


def mcp_mutation_kind(tool: str, tool_input: object) -> str | None:
    operation_text = " ".join(operation_values(tool_input)).casefold()
    command = normalized_tool(tool).split("__")[-1]
    lowered = f"{command} {operation_text}"
    operation_mutation = any(
        has_mcp_word(operation_text, word)
        for word in MCP_MUTATION_VERBS | MCP_HTTP_MUTATION_VERBS
    )
    read_action = has_explicit_mcp_read_action(tool)
    compound_mutation = has_compound_mcp_mutation(tool)
    trailing_mutation = has_trailing_mcp_mutation(tool)
    tool_mutation = any(
        has_mcp_word(command, word)
        for word in MCP_MUTATION_VERBS | MCP_HTTP_MUTATION_VERBS
    )
    primary_action = mcp_segment_action(command.split("_"))
    if (
        not operation_mutation
        and read_action
        and not compound_mutation
        and not trailing_mutation
        and primary_action == "read"
    ):
        return None
    if not operation_mutation and not compound_mutation and not tool_mutation:
        return "unknown_mutation"
    if has_mcp_word(lowered, "merge"):
        return "merge"
    if has_mcp_word(lowered, "comment"):
        return "issue_other" if has_mcp_word(lowered, "issue") else "unknown_mutation"
    if has_mcp_word(lowered, "issue") and has_mcp_word(lowered, "create"):
        return "issue_create"
    if has_mcp_word(lowered, "project") and any(
        has_mcp_word(lowered, word) for word in ("add", "create")
    ):
        return "project_add"
    if has_mcp_word(lowered, "project"):
        return "project_other"
    if any(has_mcp_word(lowered, word) for word in ("label", "labels")):
        return "label"
    if has_mcp_word(lowered, "issue") and any(
        has_mcp_word(lowered, word) for word in ("update", "edit")
    ):
        return "issue_edit"
    if has_mcp_word(lowered, "issue"):
        return "issue_other"
    return "unknown_mutation"


def structured_label_values(value: object) -> list[str]:
    if isinstance(value, dict):
        selected: list[str] = []
        for key, child in value.items():
            if str(key).casefold() in LABEL_INPUT_KEYS:
                selected.extend(flatten_strings(child))
            else:
                selected.extend(structured_label_values(child))
        return selected
    if isinstance(value, list):
        return [item for child in value for item in structured_label_values(child)]
    return []


def shell_label_values(text: str) -> list[str]:
    try:
        words = shlex.split(text)
    except ValueError:
        return []
    values: list[str] = []
    index = 0
    flags = {"--add-label", "--remove-label", "--label"}
    while index < len(words):
        token = words[index]
        if token in flags and index + 1 < len(words):
            values.extend(item for item in words[index + 1].split(",") if item)
            index += 2
            continue
        for flag in flags:
            if token.startswith(f"{flag}="):
                values.extend(item for item in token.split("=", 1)[1].split(",") if item)
                break
        index += 1
    return values


def requested_label_values(tool_input: object, shell_text: str) -> set[str]:
    return {
        value
        for value in [
            *structured_label_values(tool_input),
            *shell_label_values(shell_text),
        ]
        if value
    }


def shell_issue_edit_flags(text: str) -> set[str] | None:
    invocations = gh_invocations(text)
    if invocations is None:
        return None
    flags: set[str] = set()
    for tokens in invocations:
        issue_index = gh_command_index(tokens, "issue")
        if issue_index is None or issue_index + 1 >= len(tokens):
            continue
        if shell_token_value(tokens[issue_index + 1]).casefold() != "edit":
            continue
        for raw_token in tokens[issue_index + 2 :]:
            token = shell_token_value(raw_token)
            if token.startswith("--"):
                flags.add(token.split("=", 1)[0])
            elif token.startswith("-") and len(token) >= 2:
                flags.update(f"-{character}" for character in token[1:])
    return flags


def structured_repository_allowed(tool_input: object) -> bool:
    if not isinstance(tool_input, dict):
        return False
    owner = tool_input.get("owner")
    repo = tool_input.get("repo")
    repository = tool_input.get("repository")
    has_owner_or_repo = owner is not None or repo is not None
    if has_owner_or_repo and not (
        owner == EXPECTED_REPOSITORY_OWNER and repo == EXPECTED_REPOSITORY_NAME
    ):
        return False
    if repository is not None and repository != (
        f"{EXPECTED_REPOSITORY_OWNER}/{EXPECTED_REPOSITORY_NAME}"
    ):
        return False
    return has_owner_or_repo or repository is not None


def structured_issue_target_allowed(tool_input: object) -> bool:
    if not isinstance(tool_input, dict) or not structured_repository_allowed(tool_input):
        return False
    issue = tool_input.get("issue_number", tool_input.get("issue"))
    return (
        isinstance(issue, int) and issue > 0
        or isinstance(issue, str) and issue.isdigit() and int(issue) > 0
    )


def structured_project_target_allowed(tool_input: object) -> bool:
    if not isinstance(tool_input, dict) or not set(tool_input) <= PROJECT_ADD_KEYS:
        return False
    return (
        tool_input.get("owner") in {"@me", EXPECTED_REPOSITORY_OWNER}
        and tool_input.get("project_number") == 7
        and isinstance(tool_input.get("content_id"), str)
        and bool(tool_input.get("content_id"))
    )


def label_values_for_keys(tool_input: dict[object, object], keys: set[str]) -> set[str]:
    values: set[str] = set()
    for key, child in tool_input.items():
        if str(key).casefold() not in keys:
            continue
        values.update(item for item in flatten_strings(child) if item)
    return values


def claimer_transition_allowed(tool_input: object) -> bool:
    if not isinstance(tool_input, dict):
        return False
    replacement = label_values_for_keys(tool_input, {"label", "labels"})
    added = label_values_for_keys(tool_input, {"add_label", "add_labels"})
    removed = label_values_for_keys(tool_input, {"remove_label", "remove_labels"})
    if replacement:
        return replacement & STATE_LABELS == {"agent:claimed"} and not added and not removed
    return (
        added == {"agent:claimed"}
        and removed == {"agent:ready"}
    )


def allowed_github_mutation(
    role: str, kind: str, tool_input: object, shell_text: str = ""
) -> bool:
    if role == "rpm_idea_issue_creator":
        if kind == "project_add":
            return structured_project_target_allowed(tool_input)
        return (
            kind == "issue_create"
            and isinstance(tool_input, dict)
            and set(tool_input) <= CREATOR_ISSUE_KEYS
            and structured_repository_allowed(tool_input)
        )
    if role == "rpm_followup_issue_creator":
        return (
            kind == "issue_create"
            and isinstance(tool_input, dict)
            and set(tool_input) <= CREATOR_ISSUE_KEYS
            and structured_repository_allowed(tool_input)
        )
    if role == "rpm_issue_refiner":
        if kind not in {"issue_edit", "label"}:
            return False
        if not shell_text and not structured_issue_target_allowed(tool_input):
            return False
        if not shell_text and isinstance(tool_input, dict) and not (
            set(tool_input) <= REFINER_STRUCTURED_KEYS
        ):
            return False
        forbidden_keys = {
            "add_assignee",
            "add_project",
            "assignee",
            "assignees",
            "milestone",
            "project",
            "projects",
            "remove_assignee",
            "remove_milestone",
            "remove_project",
            "state",
            "title",
        }
        if collect_keys(tool_input) & forbidden_keys:
            return False
        if shell_text:
            flags = shell_issue_edit_flags(shell_text)
            if not flags or not flags <= REFINER_ISSUE_EDIT_FLAGS:
                return False
        labels = requested_label_values(tool_input, shell_text)
        if kind == "label":
            return bool(labels) and labels <= STATE_LABELS
        if labels and not labels <= STATE_LABELS:
            return False
        return True
    if role == "rpm_ready_ticket_claimer":
        if kind not in {"issue_edit", "label"}:
            return False
        if not shell_text and not structured_issue_target_allowed(tool_input):
            return False
        if not shell_text and isinstance(tool_input, dict) and not (
            set(tool_input) <= CLAIMER_STRUCTURED_KEYS
        ):
            return False
        forbidden_keys = {
            "add_assignee",
            "add_project",
            "assignee",
            "assignees",
            "body",
            "body_file",
            "milestone",
            "project",
            "projects",
            "remove_assignee",
            "remove_milestone",
            "remove_project",
            "state",
            "title",
        }
        if collect_keys(tool_input) & forbidden_keys:
            return False
        if shell_text:
            flags = shell_issue_edit_flags(shell_text)
            if not flags or not flags <= CLAIMER_ISSUE_EDIT_FLAGS:
                return False
        labels = requested_label_values(tool_input, shell_text)
        if not claimer_transition_allowed(tool_input):
            return False
        if kind == "label":
            return bool(labels) and labels <= CLAIMER_STATE_LABELS
        if not labels or not labels <= CLAIMER_STATE_LABELS:
            return False
        return True
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

    collaboration_part = collaboration_tool_part(tool)
    if collaboration_part is not None:
        if role not in MANAGERS:
            return deny(f"{role} is a leaf and cannot spawn or contact agents")
        if collaboration_part in COLLABORATION_STATUS_TOOL_PARTS:
            return 0
        if collaboration_part in {"agent", "spawn_agent"}:
            report = requested_agent_role(tool_input)
            if not isinstance(report, str) or not manager_report_allowed(role, report):
                return deny(f"{role} cannot spawn the requested agent role")
            if collaboration_part == "spawn_agent" and (
                not isinstance(tool_input, dict)
                or tool_input.get("task_name") != report
            ):
                return deny(f"{role} must use the report role as its task name")
            return 0
        if collaboration_part not in {"followup_task", "send_message", "interrupt_agent"}:
            return deny(f"{role} cannot use an unknown agent contact tool")
        return 0 if manager_contact_allowed(role, tool_input) else deny(
            f"{role} cannot contact a non-report agent target"
        )

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
        command_text = shell_source(tool_input)
        mutation = shell_mutation_kind(command_text)
        if mutation is None:
            return 0
        if mutation == "git_push":
            return deny(f"{role} cannot push repository state")
        if role in {"rpm_issue_refiner", "rpm_ready_ticket_claimer"}:
            return deny(f"{role} must use a structured GitHub mutation tool")
        if role not in GITHUB_MUTATION_ROLES:
            return deny(f"{role} cannot mutate GitHub through a shell command")
        try:
            shlex.split(text)
        except ValueError:
            return deny(f"{role} supplied an unparsable shell mutation")
        return (
            0
            if allowed_github_mutation(role, mutation, tool_input, command_text)
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
