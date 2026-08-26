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
    "rpm_existing_pr_adopter",
    "rpm_backlog_scout",
    "rpm_idea_issue_creator",
    "rpm_issue_fetcher",
    "rpm_issue_researcher",
    "rpm_issue_refiner",
    "rpm_issue_readiness_reviewer",
    "rpm_ready_ticket_claimer",
    "rpm_followup_issue_creator",
}
# The existing-PR adopter may collect evidence through the host GitHub MCP
# connector, but it must never receive an implicit allow for an unrecognized
# operation.  Keep this list keyed by the operation suffix so host-specific
# MCP namespaces (for example ``mcp__codex_apps__github_*``) share the same
# fail-closed boundary.
MCP_READ_ONLY_OPERATIONS = {
    "compare_commits",
    "download_user_content",
    "fetch",
    "fetch_blob",
    "fetch_commit",
    "fetch_commit_workflow_runs",
    "fetch_file",
    "fetch_issue",
    "fetch_issue_comments",
    "fetch_pr",
    "fetch_pr_comments",
    "fetch_pr_file_patch",
    "fetch_pr_patch",
    "fetch_workflow_job_logs",
    "fetch_workflow_job_steps",
    "fetch_workflow_run_artifacts",
    "get_commit_combined_status",
    "get_issue",
    "get_issue_comment_reactions",
    "get_pr_diff",
    "get_pr_info",
    "get_pr_reactions",
    "get_pr_review_comment_reactions",
    "get_pull_request",
    "get_profile",
    "get_repo",
    "get_repo_collaborator_permission",
    "get_user_login",
    "get_users_recent_prs_in_repo",
    "list_installations",
    "list_installed_accounts",
    "list_pr_changed_filenames",
    "list_pull_request_review_threads",
    "list_pull_request_reviews",
    "list_recent_issues",
    "list_repositories",
    "list_repositories_by_affiliation",
    "list_repositories_by_installation",
    "list_user_org_memberships",
    "list_user_orgs",
    "search",
    "search_branches",
    "search_commits",
    "search_installed_repositories_streaming",
    "search_installed_repositories_v2",
    "search_issues",
    "search_prs",
    "search_repositories",
}
GITHUB_MUTATION_ROLES = {
    "rpm_idea_issue_creator",
    "rpm_issue_refiner",
    "rpm_ready_ticket_claimer",
    "rpm_followup_issue_creator",
}
RPM_ROLES = MANAGERS | LOCAL_WRITE_ROLES | MCP_READ_ROLES | {
    "rpm_existing_pr_adopter",
    "rpm_spec_reviewer",
    "rpm_issue_spec_reconciler",
    "rpm_test_runner",
    "rpm_verifier",
    "rpm_adversarial_reviewer",
}
POLICY_DIR = Path(tempfile.gettempdir()) / "rpm-agent-tool-policy"
TRUSTED_REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
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
            if str(key).casefold() in {"action", "operation", "method", "mutation"}
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
    if re.search(r"\bgh\s+api\b", lowered) and (
        re.search(r"(?:--method|-x)\s*(?:post|patch|put|delete)\b", lowered)
        or re.search(r"\bmutation\b", lowered)
    ):
        return "raw_api_mutation"
    return None


def mcp_mutation_kind(tool: str, tool_input: object) -> str | None:
    lowered = f"{normalized_tool(tool)} {' '.join(operation_values(tool_input)).casefold()}"
    mutation_words = (
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
    )
    if not any(word in lowered for word in mutation_words):
        return None
    if "merge" in lowered:
        return "merge"
    if "issue" in lowered and "create" in lowered:
        return "issue_create"
    if "project" in lowered and any(word in lowered for word in ("add", "create")):
        return "project_add"
    if "project" in lowered:
        return "project_other"
    if "label" in lowered:
        return "label"
    if "issue" in lowered and any(word in lowered for word in ("update", "edit")):
        return "issue_edit"
    if "issue" in lowered:
        return "issue_other"
    return "unknown_mutation"


def mcp_read_only_allowed(tool: str) -> bool:
    """Return whether a host MCP operation is explicitly read-only."""
    normalized = normalized_tool(tool)
    if not normalized.startswith("mcp__"):
        return False
    operation = normalized.rsplit("__", 1)[-1]
    # Codex desktop exposes GitHub operations as ``github_<operation>`` while
    # the policy is intentionally keyed by the provider-neutral suffix.  The
    # namespace is part of the host transport, not a new permission.
    if operation.startswith("github_"):
        operation = operation.removeprefix("github_")
    return operation in MCP_READ_ONLY_OPERATIONS


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


def adopter_command_allowed(
    tool: str, tool_input: object, event_cwd: object = None
) -> bool:
    """Allow only the repository-local adoption checker/helper/writer.

    The adopter's Python entry points own their own narrowly scoped GitHub
    transport.  Allowing a general-purpose shell or Python interpreter would
    let the role bypass that transport and its evidence/CAS checks.
    """
    if not is_shell_tool(tool):
        return False
    command = tool_input.get("cmd") if isinstance(tool_input, dict) else None
    if not isinstance(command, str) or not command.strip():
        return False
    if any(
        marker in command
        for marker in (";", "&&", "||", "|", "`", "$(", "\n", "\r", ">", "<")
    ):
        return False
    try:
        words = shlex.split(command)
    except ValueError:
        return False
    if not words or words[0] != "python3":
        return False

    requested_workdir = (
        tool_input.get("workdir") if isinstance(tool_input, dict) else None
    )
    if requested_workdir is not None and not isinstance(requested_workdir, str):
        return False
    cwd_text = requested_workdir
    if cwd_text is None:
        cwd_text = event_cwd if isinstance(event_cwd, str) else str(Path.cwd())
    cwd = Path(cwd_text)
    if not cwd.is_absolute():
        event_base = Path(event_cwd) if isinstance(event_cwd, str) else Path.cwd()
        cwd = event_base / cwd
    try:
        cwd = cwd.resolve(strict=True)
    except OSError:
        return False
    if cwd != TRUSTED_REPOSITORY_ROOT:
        return False

    def trusted_script(path_text: str) -> bool:
        candidate = Path(path_text)
        if candidate.is_absolute():
            resolved = candidate
        else:
            resolved = cwd / candidate
        try:
            resolved = resolved.resolve(strict=True)
        except OSError:
            return False
        try:
            resolved.relative_to(TRUSTED_REPOSITORY_ROOT)
        except ValueError:
            return False
        return resolved == TRUSTED_REPOSITORY_ROOT / candidate and resolved.is_file()

    def request_path(value: object) -> bool:
        return (
            isinstance(value, str)
            and bool(value)
            and not value.startswith("-")
            and not any(
                char in value
                for char in ("\\", "$", "*", "?", "[", "]", "~", "#")
            )
        )

    helper = "scripts/authorize-existing-pr-adoption-mutation.py"
    writer = "scripts/write-existing-pr-adoption.py"
    checker = "scripts/check-cloud-queue-contract.py"
    materializer = "scripts/materialize-existing-pr-adoption.py"
    if len(words) in {7, 8} and words[1] == materializer:
        if not trusted_script(words[1]):
            return False
        run_id, kind = words[3], words[5]
        if (
            words[2] != "--run-id"
            or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", run_id) is None
            or words[4] != "--kind"
            or kind not in {"issues", "prepared", "request"}
        ):
            return False
        if len(words) == 7:
            return words[6] == "--payload-stdin"
        payload = words[7]
        return (
            words[6] == "--payload-base64"
            and re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", payload) is not None
            and len(payload) <= 64_000
        )
    if len(words) >= 2 and words[1] == helper:
        if not trusted_script(words[1]):
            return False
        if len(words) == 4:
            return (
                words[2] == "--request-file"
                and request_path(words[3])
            )
        return (
            len(words) == 6
            and words[2:4] == ["--policy", ".agents/workflows/backlog-policy.json"]
            and words[4] == "--request-file"
            and request_path(words[5])
        )
    if len(words) >= 2 and words[1] == writer:
        if not trusted_script(words[1]):
            return False
        if len(words) == 4:
            return words[2] == "--request-file" and request_path(words[3])
        return (
            len(words) == 6
            and words[2:4] == ["--policy", ".agents/workflows/backlog-policy.json"]
            and words[4] == "--request-file"
            and request_path(words[5])
        )
    if len(words) >= 2 and words[1] == checker:
        if not trusted_script(words[1]):
            return False
        if len(words) == 6:
            return (
                words[2] == "--issues-file"
                and request_path(words[3])
                and words[4:6] == ["--operation", "adopt-existing-pr"]
            )
        return (
            len(words) == 8
            and words[2:4] == ["--policy", ".agents/workflows/backlog-policy.json"]
            and words[4] == "--issues-file"
            and request_path(words[5])
            and words[6:8] == ["--operation", "adopt-existing-pr"]
        )
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

    if role == "rpm_existing_pr_adopter":
        forbidden = has_forbidden_review_or_merge(f"{tool}\n{text}")
        if forbidden:
            return deny(forbidden)
        # The adopter's entrypoints own the write boundary, while read-only
        # MCP calls are required when the task receives only an issue/PR pair
        # and must collect the live evidence itself.
        if tool.startswith("mcp__"):
            if mcp_read_only_allowed(tool):
                return 0
            return deny(
                "existing PR adopter MCP operation is not on the explicit read-only allowlist"
            )
        if adopter_command_allowed(tool, tool_input, event.get("cwd")):
            return 0
        return deny("existing PR adopter is restricted to exact adoption entrypoints and read-only MCP")

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
