#!/usr/bin/env python3
"""Enforce role-specific tool, GitHub mutation, and patch boundaries."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath


MANAGERS = {
    "rpm_workflow_manager",
    "rpm_backlog_manager",
    "rpm_issue_manager",
}
MANAGER_CHILDREN = {
    "rpm_workflow_manager": {"rpm_backlog_manager", "rpm_issue_manager"},
    "rpm_backlog_manager": {
        "rpm_backlog_scout",
        "rpm_idea_issue_creator",
        "rpm_issue_researcher",
        "rpm_issue_refiner",
        "rpm_issue_readiness_reviewer",
        "rpm_ready_ticket_claimer",
    },
    "rpm_issue_manager": {
        "rpm_issue_fetcher",
        "rpm_spec_reviewer",
        "rpm_issue_spec_reconciler",
        "rpm_spec_updater",
        "rpm_test_author",
        "rpm_implementer",
        "rpm_test_runner",
        "rpm_verifier",
        "rpm_adversarial_reviewer",
        "rpm_followup_issue_creator",
    },
}
CLOUD_ISSUE_MANAGER_CHILDREN = {
    "rpm_workflow_manager": {"rpm_backlog_manager", "rpm_issue_manager"},
    "rpm_backlog_manager": {"rpm_backlog_scout", "rpm_ready_ticket_claimer"},
    "rpm_issue_manager": MANAGER_CHILDREN["rpm_issue_manager"],
}
LOCAL_WRITE_ROLES = {
    "pr-review-resolver",
    "rpm_cloud_result_writer",
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
    "rpm_ticket_publisher",
    "rpm_review_reconciler",
    "rpm_merge_state_writer",
}
GITHUB_MUTATION_ROLES = {
    "rpm_idea_issue_creator",
    "rpm_issue_refiner",
    "rpm_ready_ticket_claimer",
    "rpm_followup_issue_creator",
    "rpm_ticket_publisher",
    "rpm_review_reconciler",
    "rpm_merge_state_writer",
}
WRITER_ROLES = {
    "rpm_ticket_publisher",
    "rpm_review_reconciler",
    "rpm_merge_state_writer",
}
RESULT_WRITER_ROLES = {"rpm_cloud_result_writer"}
RPM_ROLES = MANAGERS | LOCAL_WRITE_ROLES | MCP_READ_ROLES | {
    "rpm_spec_reviewer",
    "rpm_issue_spec_reconciler",
    "rpm_test_runner",
    "rpm_verifier",
    "rpm_adversarial_reviewer",
    *WRITER_ROLES,
}
POLICY_DIR = Path(tempfile.gettempdir()) / "rpm-agent-tool-policy"
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
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
# Shell commands are an escape hatch around the structured tool boundary.  A
# command interpreter or wrapper can hide a file, Git, or GitHub mutation from
# the simple command classifier, so these executables are treated as writes by
# default.  The small read-only exceptions are checked separately and only
# cover repository-owned deterministic readers.
SHELL_INTERPRETERS = {
    "awk",
    "bash",
    "bun",
    "csh",
    "dash",
    "deno",
    "fish",
    "gawk",
    "go",
    "java",
    "js",
    "ksh",
    "lua",
    "node",
    "nodejs",
    "npx",
    "nawk",
    "perl",
    "php",
    "php8",
    "pypy",
    "pypy3",
    "python",
    "python2",
    "python3",
    "qjs",
    "raku",
    "ruby",
    "rscript",
    "sh",
    "tcsh",
    "zsh",
}
SHELL_WRAPPERS = {
    "builtin",
    "busybox",
    "cargo",
    "chroot",
    "command",
    "doas",
    "env",
    "exec",
    "eval",
    "find",
    "just",
    "nsenter",
    "nice",
    "nohup",
    "make",
    "npm",
    "parallel",
    "runuser",
    "setsid",
    "source",
    "su",
    "sudo",
    "timeout",
    "xargs",
}
# Versioned executable names are common in Cloud images.  Matching only the
# unversioned basename would let ``python3.11``, ``node20``, or ``ruby3.2``
# hide the same arbitrary source execution that the exact names already deny.
# The build wrappers are included because npm/make/cargo can execute scripts
# that write protected automation files or invoke a dynamic GitHub command.
VERSIONED_SHELL_EXECUTORS = (
    re.compile(
        r"^(?:python|node|nodejs|ruby|npm|make|cargo)"
        r"(?:-v?)?\d+(?:[._-]\d+)*$"
    ),
)
READ_ONLY_SHELL_WRAPPER_PREFIXES = {
    ("bash", "scripts/check-agent-backlog-access.sh"),
    ("bash", "scripts/check-workflow-intake.sh"),
    ("bash", "scripts/check-workflow-final.sh"),
    ("bash", "scripts/collect-pr-review-context.sh"),
}
READ_ONLY_INTERPRETER_SCRIPTS = {
    "scripts/backlog-gen",
    "scripts/check-agent-issue-readiness.py",
    "scripts/check-agent-organization.py",
    "scripts/check-cloud-queue-contract.py",
    "scripts/check-merge-gate.py",
}
# These commands expose read-only output without handing Cloud an arbitrary
# executable path.  Any interpreter, wrapper, separator, redirect, or unsafe
# Git option is still rejected by the existing parser before this allowlist is
# consulted.
CLOUD_READ_ONLY_SHELL_PROGRAMS = {
    "cat",
    "cmp",
    "cut",
    "diff",
    "file",
    "grep",
    "head",
    "less",
    "ls",
    "realpath",
    "rg",
    "sed",
    "sort",
    "stat",
    "tail",
    "tr",
    "uniq",
    "wc",
}
CLOUD_TEST_COMMANDS = {
    ("rpm_test_runner", ("just", "validate")),
    ("rpm_verifier", ("just", "validate")),
}
CLOUD_LANE_ENV = "RPM_CLOUD_LANE"
CLOUD_LANES = {"issue", "review", "merge"}
CLOUD_LANE_MARKER = "rpm-cloud-lane"
RPM_REPOSITORY = "nerdchanii/rpm"
CLOUD_MCP_PREFIXES = (
    "mcp__plugin_github_github__",
    "mcp__codex_apps__github_",
    "mcp__github__",
)
CLOUD_MCP_READ_OPERATIONS = {
    "compare_commits",
    "download_user_content",
    "download_workflow_artifact",
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
    "fetch_workflow_run_jobs",
    "get_commit_combined_status",
    "get_issue",
    "get_issue_comment_reactions",
    "get_me",
    "get_pr_diff",
    "get_pr_info",
    "get_pr_reactions",
    "get_pr_review_comment_reactions",
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
REPOSITORY_SCOPED_MCP_READ_OPERATIONS = {
    "compare_commits",
    "download_user_content",
    "download_workflow_artifact",
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
    "fetch_workflow_run_jobs",
    "get_commit_combined_status",
    "get_issue",
    "get_issue_comment_reactions",
    "get_pr_diff",
    "get_pr_info",
    "get_pr_reactions",
    "get_pr_review_comment_reactions",
    "get_repo",
    "get_repo_collaborator_permission",
    "get_users_recent_prs_in_repo",
    "list_pr_changed_filenames",
    "list_pull_request_review_threads",
    "list_pull_request_reviews",
    "list_recent_issues",
    "search_branches",
    "search_commits",
    "search_issues",
    "search_prs",
}
CLOUD_PATCH_TOOLS = {"apply_patch", "edit", "write"}
CLOUD_TOP_LEVEL_AGENT_ALLOWLIST = {
    "issue": {"rpm_workflow_manager", "rpm_ticket_publisher", "rpm_cloud_result_writer"},
    "review": {
        "pr-review-resolver",
        "rpm_review_reconciler",
        "rpm_cloud_result_writer",
    },
    "merge": {"rpm_cloud_result_writer"},
}
# These are the roles that may exist inside each Cloud task.  The narrower
# top-level allowlist above controls which roles the role-less Cloud session
# may start; this map is checked again for every tool call after the role is
# recovered from its transcript.  The issue lane deliberately includes the
# ready-ticket claimer because claiming is its one GitHub mutation exception.
CLOUD_AGENT_ALLOWLIST = {
    "issue": {
        "rpm_workflow_manager",
        "rpm_backlog_manager",
        "rpm_backlog_scout",
        "rpm_ready_ticket_claimer",
        "rpm_issue_manager",
        "rpm_issue_fetcher",
        "rpm_spec_reviewer",
        "rpm_issue_spec_reconciler",
        "rpm_spec_updater",
        "rpm_test_author",
        "rpm_implementer",
        "rpm_test_runner",
        "rpm_verifier",
        "rpm_adversarial_reviewer",
        "rpm_followup_issue_creator",
        "rpm_ticket_publisher",
        "rpm_cloud_result_writer",
    },
    "review": {
        "pr-review-resolver",
        "rpm_review_reconciler",
        "rpm_cloud_result_writer",
    },
    "merge": {"rpm_cloud_result_writer"},
}
CLOUD_ACTION_SIDE_WRITERS = {
    "rpm_ticket_publisher",
    "rpm_review_reconciler",
    "rpm_followup_issue_creator",
}
PROTECTED_AUTOMATION_ROOTS = (".github/", ".codex/", ".agents/")
PROTECTED_AUTOMATION_ROOT_NAMES = {".git", ".githooks", ".github", ".codex", ".agents"}
PROTECTED_AUTOMATION_SCRIPT_PREFIXES = (
    "agent-loop-",
    "check-agent-",
    "check-cloud-",
    "check-merge-",
    "check-workflow-",
    "collect-pr-review-context",
    "create-review-followup-issue",
    "safe-direct-merge",
    "validate-agent-workflow-assets",
    "validate-cloud-diff",
    "publish-cloud-diff",
    "test-agent-loop",
    "test-cloud-automation",
    "test-codex-cloud-dispatch",
    "test-create-review-followup-issue",
    "test-issue-labeler",
    "test-validate-cloud-diff",
    "test-publish-cloud-diff",
    "test-safe-direct-merge",
    "test-collect-pr-review-context",
)


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


def policy_data(event: dict[str, object]) -> dict[str, object] | None:
    transcript = transcript_path(event)
    if transcript is None:
        transcript = transcript_path(event, start_or_stop=True)
    if transcript is None:
        return None
    try:
        value = json.loads(policy_path(transcript).read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
    return value if isinstance(value, dict) else None


def register(event: dict[str, object]) -> int:
    role = event.get("agent_type")
    transcript = transcript_path(event, start_or_stop=True)
    lane_present, lane = cloud_lane_from_environment()
    attestation_error = cloud_lane_attestation_error()
    known_role = role if isinstance(role, str) and role in RPM_ROLES else None
    if transcript is None or (known_role is None and not lane_present):
        return 0
    POLICY_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    policy: dict[str, object] = {}
    if isinstance(role, str) and role:
        # Keep an unrecognized Cloud identity in the record so that a later
        # PreToolUse event cannot silently downgrade it to a role-less root.
        policy["agent_type"] = known_role if known_role is not None else role
    if lane_present:
        # Persist the fact that this transcript entered through a Cloud
        # environment.  The runner may accidentally omit the environment from
        # a later hook process; allowing that transition would turn a Cloud
        # role into an unguarded local role.
        policy["cloud"] = True
        policy["lane"] = lane
        marker_present, _ = cloud_lane_marker()
        policy["marker"] = marker_present
    else:
        policy["cloud"] = False
    policy_path(transcript).write_text(json.dumps(policy, sort_keys=True))
    if attestation_error is not None:
        return deny(f"Cloud lane attestation failed: {attestation_error}")
    if lane_present and lane not in CLOUD_LANES:
        return deny(
            f"Cloud registration has missing or invalid {CLOUD_LANE_ENV}; "
            "complete the lane preflight before any tool use"
        )
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
    value = policy_data(event)
    if value is None:
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


def field_values(value: object, field: str) -> list[str]:
    """Read values for one direct tool argument without scanning free text."""
    if not isinstance(value, dict):
        return []
    for key, child in value.items():
        if str(key).casefold() == field.casefold():
            return flatten_strings(child)
    return []


def repository_is_rpm(value: object) -> bool:
    if not isinstance(value, dict):
        return False
    repositories = [
        child
        for key, child in value.items()
        if str(key).casefold()
        in {"repository", "repository_full_name", "repo_full_name"}
    ]
    if len(repositories) == 1:
        return repositories[0] == RPM_REPOSITORY
    if repositories:
        return False
    owner = next(
        (
            child
            for key, child in value.items()
            if str(key).casefold() == "owner"
        ),
        None,
    )
    repo_name = next(
        (
            child
            for key, child in value.items()
            if str(key).casefold() in {"repo", "repository_name"}
        ),
        None,
    )
    return owner == "nerdchanii" and repo_name == "rpm"


def repository_input_is_allowed(value: object) -> bool:
    """Reject an explicitly supplied GitHub repository outside this checkout.

    Some connector operations are account-scoped and omit a repository.  Those
    reads remain available when no repository was supplied.  Whenever a
    repository is present, however, it must identify this exact repository.
    """
    if not isinstance(value, dict):
        return False
    repositories = [
        child
        for key, child in value.items()
        if str(key).casefold()
        in {"repository", "repository_full_name", "repo_full_name"}
    ]
    if repositories and (
        len(repositories) != 1 or repositories[0] != RPM_REPOSITORY
    ):
        return False
    owner = next(
        (
            child
            for key, child in value.items()
            if str(key).casefold() == "owner"
        ),
        None,
    )
    repo_name = next(
        (
            child
            for key, child in value.items()
            if str(key).casefold() in {"repo", "repository_name"}
        ),
        None,
    )
    if owner is not None or repo_name is not None:
        if owner != "nerdchanii" or repo_name != "rpm":
            return False
    return True


def positive_number(value: object, field: str) -> bool:
    if not isinstance(value, dict):
        return False
    candidate = next(
        (child for key, child in value.items() if str(key).casefold() == field.casefold()),
        None,
    )
    return isinstance(candidate, int) and not isinstance(candidate, bool) and candidate > 0


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


def is_protected_automation_path(path: PurePosixPath) -> bool:
    """Identify repository automation and merge-gate files owned by managers."""
    if path.parts and path.parts[0] in PROTECTED_AUTOMATION_ROOT_NAMES:
        return True
    text = path.as_posix()
    if text == ".codex-cloud-result.json":
        return True
    if any(text.startswith(prefix) for prefix in PROTECTED_AUTOMATION_ROOTS):
        return True
    if not text.startswith("scripts/"):
        return False
    name = text.removeprefix("scripts/")
    return any(name.startswith(prefix) for prefix in PROTECTED_AUTOMATION_SCRIPT_PREFIXES)


def path_allowed(role: str, path: PurePosixPath) -> bool:
    parts = path.parts
    if not parts or path.is_absolute() or ".." in parts:
        return False
    text = path.as_posix()
    if role == "rpm_cloud_result_writer":
        return text == ".codex-cloud-result.json"
    if role == "rpm_spec_updater":
        return text.startswith("docs/specs/")
    if role == "rpm_test_author":
        return text.startswith("tests/") or text.startswith("src/")
    if role == "rpm_implementer":
        return not (
            text.startswith("tests/")
            or text.startswith("docs/specs/")
            or is_protected_automation_path(path)
        )
    if role == "pr-review-resolver":
        return not is_protected_automation_path(path)
    return False


def deny(reason: str) -> int:
    print(f"RPM agent tool policy blocked this call: {reason}", file=sys.stderr)
    return 2


def normalized_tool(tool: str) -> str:
    return tool.replace("-", "_").casefold()


SHELL_SEPARATORS = {";", "&&", "||", "|", "(", ")"}
GIT_GLOBAL_OPTIONS_WITH_VALUE = {
    "-C",
    "-c",
    "--exec-path",
    "--git-dir",
    "--namespace",
    "--super-prefix",
    "--work-tree",
}
GIT_GLOBAL_OPTIONS_WITHOUT_VALUE = {
    "--bare",
    "--git-dir",
    "--literal-pathspecs",
    "--glob-pathspecs",
    "--noglob-pathspecs",
    "--icase-pathspecs",
    "--no-pager",
    "--no-replace-objects",
    "--no-optional-locks",
    "--paginate",
    "-p",
    "-P",
}
GIT_READ_SUBCOMMANDS = {
    "blame",
    "cat-file",
    "describe",
    "diff",
    "for-each-ref",
    "for-each-repo",
    "grep",
    "help",
    "ls-files",
    "log",
    "merge-base",
    "rev-parse",
    "show",
    "shortlog",
    "status",
    "version",
    "whatchanged",
}
GIT_MUTATING_SUBCOMMANDS = {
    "add",
    "am",
    "apply",
    "bisect",
    "checkout",
    "cherry-pick",
    "clean",
    "clone",
    "commit",
    "fetch",
    "filter-branch",
    "filter-repo",
    "gc",
    "init",
    "merge",
    "mv",
    "notes",
    "pull",
    "push",
    "rebase",
    "reflog",
    "remote",
    "replace",
    "reset",
    "restore",
    "rm",
    "stash",
    "switch",
    "tag",
    "update-index",
    "update-ref",
    "worktree",
}
GIT_UNSAFE_READ_OPTIONS = {
    "--exec",
    "--ext-diff",
    "--paginate",
    "--textconv",
    "--output",
}


def shell_tokens(text: str) -> list[str] | None:
    """Tokenize command text while retaining shell command separators."""
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return None


def executable_name(token: str) -> str:
    """Return a case-folded executable basename for absolute-path commands."""
    name = token.rsplit("/", 1)[-1]
    if name.casefold().endswith(".exe"):
        name = name[:-4]
    return name.casefold()


def read_only_shell_wrapper(text: str) -> bool:
    """Allow only known read-only scripts through a local shell wrapper."""
    if any(character in text for character in ";&|()<>`$\r\n"):
        return False
    tokens = shell_tokens(text)
    if tokens is None:
        return False
    for prefix in READ_ONLY_SHELL_WRAPPER_PREFIXES:
        if tuple(tokens[: len(prefix)]) != prefix:
            continue
        # The wrapper owns its arguments.  Separators are retained by the
        # tokenizer, so a second command cannot be smuggled into this check.
        return len(tokens) >= len(prefix) and not any(
            token in SHELL_SEPARATORS for token in tokens[len(prefix) :]
        )
    return False


def read_only_interpreter_command(text: str) -> bool:
    """Allow direct invocation of repository-owned read-only checkers."""
    if any(character in text for character in ";&|()<>`$\r\n"):
        return False
    tokens = shell_tokens(text)
    if tokens is None or not tokens:
        return False
    if executable_name(tokens[0]) not in {"python", "python2", "python3"}:
        return False
    script_index = 1
    if len(tokens) > script_index and tokens[script_index] in {"-B", "--no-user-site"}:
        script_index += 1
    if len(tokens) <= script_index:
        return False
    script = tokens[script_index]
    return script in READ_ONLY_INTERPRETER_SCRIPTS


def shell_executor_kind(text: str) -> str | None:
    """Find interpreters and command wrappers before mutation parsing.

    The hook cannot prove what arbitrary interpreter source will do.  It thus
    returns a mutation classification for every such command and leaves only
    the explicit read-only wrappers to ``read_only_shell_wrapper``.
    """
    tokens = shell_tokens(text)
    if tokens is None:
        return "unparsed_shell"
    for token in tokens:
        name = executable_name(token)
        if name in SHELL_INTERPRETERS or any(
            pattern.fullmatch(name) for pattern in VERSIONED_SHELL_EXECUTORS
        ):
            return f"interpreter:{name}"
        if name in SHELL_WRAPPERS:
            return f"wrapper:{name}"
    return None


def _git_subcommand(tokens: list[str], index: int) -> tuple[str | None, int]:
    """Return a git subcommand and its token index after global options."""
    cursor = index + 1
    while cursor < len(tokens):
        token = tokens[cursor]
        if token in SHELL_SEPARATORS:
            return None, cursor
        if token in GIT_GLOBAL_OPTIONS_WITH_VALUE:
            cursor += 2
            continue
        if any(
            token.startswith(option + "=")
            for option in ("--exec-path", "--git-dir", "--namespace", "--super-prefix", "--work-tree")
        ):
            cursor += 1
            continue
        if token.startswith("-C") and token != "-C":
            cursor += 1
            continue
        if token.startswith("-c") and token != "-c":
            cursor += 1
            continue
        if token in GIT_GLOBAL_OPTIONS_WITHOUT_VALUE:
            cursor += 1
            continue
        if token.startswith("-"):
            return "__unknown_option__", cursor
        return token, cursor
    return None, cursor


def _git_branch_is_mutating(tokens: list[str], subcommand_index: int) -> bool:
    read_options_with_value = {
        "--contains",
        "--format",
        "--merged",
        "--no-merged",
        "--points-at",
        "--sort",
        "--column",
    }
    mutation_options = {
        "-c",
        "-C",
        "-d",
        "-D",
        "-m",
        "-M",
        "--copy",
        "--delete",
        "--edit-description",
        "--move",
        "--set-upstream-to",
        "--unset-upstream",
    }
    cursor = subcommand_index + 1
    while cursor < len(tokens) and tokens[cursor] not in SHELL_SEPARATORS:
        token = tokens[cursor]
        if token in mutation_options or token.startswith("--set-upstream-to="):
            return True
        if token in read_options_with_value:
            cursor += 2
            continue
        if token.startswith(tuple(f"{option}=" for option in read_options_with_value)):
            cursor += 1
            continue
        if token in {"-a", "-r", "-v", "-vv", "--all", "--list", "--remotes", "--show-current"}:
            cursor += 1
            continue
        if token.startswith("-"):
            return True
        # A bare branch name creates a branch.
        return True
    return False


def _git_config_is_mutating(tokens: list[str], subcommand_index: int) -> bool:
    read_options = {
        "--get",
        "--get-all",
        "--get-regexp",
        "--get-urlmatch",
        "--list",
        "-l",
        "--name-only",
        "--show-origin",
        "--show-scope",
    }
    arguments = tokens[subcommand_index + 1 :]
    arguments = [token for token in arguments if token not in SHELL_SEPARATORS]
    if any(
        token in read_options
        or any(token.startswith(option + "=") for option in read_options)
        for token in arguments
    ):
        return False
    return True


def _git_remote_is_mutating(tokens: list[str], subcommand_index: int) -> bool:
    arguments = [token for token in tokens[subcommand_index + 1 :] if token not in SHELL_SEPARATORS]
    if not arguments:
        return False
    return arguments[0] in {
        "add",
        "prune",
        "remove",
        "rename",
        "set-head",
        "set-branches",
        "set-url",
    }


def _git_tag_is_mutating(tokens: list[str], subcommand_index: int) -> bool:
    arguments = [token for token in tokens[subcommand_index + 1 :] if token not in SHELL_SEPARATORS]
    if not arguments:
        return False
    read_options = {
        "-l",
        "--list",
        "--contains",
        "--merged",
        "--no-merged",
        "--points-at",
        "--sort",
        "-n",
    }
    return not all(
        token in read_options
        or token.startswith(tuple(f"{option}=" for option in read_options))
        or token.startswith("-") and token[1:].isdigit()
        for token in arguments
    )


def _git_invocation_is_mutating(tokens: list[str], index: int) -> bool:
    subcommand, subcommand_index = _git_subcommand(tokens, index)
    if subcommand is None or subcommand == "__unknown_option__":
        return True
    if subcommand == "branch":
        return _git_branch_is_mutating(tokens, subcommand_index)
    if subcommand == "config":
        return _git_config_is_mutating(tokens, subcommand_index)
    if subcommand == "remote":
        return _git_remote_is_mutating(tokens, subcommand_index)
    if subcommand == "tag":
        return _git_tag_is_mutating(tokens, subcommand_index)
    if subcommand in GIT_READ_SUBCOMMANDS:
        remainder = tokens[subcommand_index + 1 :]
        if any(
            token in GIT_UNSAFE_READ_OPTIONS
            or token.startswith("--output=")
            or token.startswith("--format=%x")
            for token in remainder
        ):
            return True
        return False
    # Unknown git subcommands are fail-closed because aliases and extensions
    # may mutate the repository even when they are not in our read allowlist.
    return True


def contains_shell_program(text: str, program: str) -> bool:
    """Find a shell executable even when wrappers or subcommand options vary."""
    tokens = shell_tokens(text)
    if tokens is not None and any(token.casefold() == program for token in tokens):
        return True
    lowered = text.casefold()
    return re.search(rf"(?<![a-z0-9_-]){re.escape(program)}(?=\s|$|[;&|()<>])", lowered) is not None


def contains_shell_sequence(text: str, *words: str) -> bool:
    """Find ordered command words, allowing arbitrary options between them."""
    lowered = text.casefold()
    for segment in re.split(r"[;&|()<>\r\n]+", lowered):
        cursor = 0
        for word in words:
            match = re.search(rf"\b{re.escape(word.casefold())}\b", segment[cursor:])
            if match is None:
                break
            cursor += match.end()
        else:
            return True
    return False


def cloud_lane_marker_path() -> Path | None:
    """Resolve the per-clone Cloud attestation file from the actual git dir."""
    try:
        result = subprocess.run(
            [
                "/usr/bin/git",
                "-C",
                str(REPOSITORY_ROOT),
                "rev-parse",
                "--git-path",
                CLOUD_LANE_MARKER,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
            env={"PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"},
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    raw_path = result.stdout.strip()
    if not raw_path:
        return None
    candidate = Path(raw_path)
    return candidate if candidate.is_absolute() else REPOSITORY_ROOT / candidate


def cloud_lane_marker() -> tuple[bool, str | None]:
    """Read an exact issue/review/merge marker, rejecting malformed content."""
    marker_path = cloud_lane_marker_path()
    if marker_path is None:
        return False, None
    try:
        metadata = marker_path.lstat()
    except FileNotFoundError:
        return False, None
    except OSError:
        return True, None
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
        return True, None
    try:
        raw = marker_path.read_bytes()
    except OSError:
        return True, None
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    try:
        value = raw.decode("ascii")
    except UnicodeDecodeError:
        return True, None
    return True, value if value in CLOUD_LANES else None


def cloud_lane_from_environment() -> tuple[bool, str | None]:
    """Read the Cloud signal and lane from the two-part attestation.

    A normal local process has neither signal.  The presence of either the
    clone-local marker or ``RPM_CLOUD_LANE`` identifies an attempted Cloud
    session; that session must pass ``cloud_lane_attestation_error`` before a
    tool can run.  This keeps a partial Cloud setup from falling back to local
    permissions while preserving existing unmarked local sessions.
    """
    marker_present, marker_lane = cloud_lane_marker()
    environment_present = CLOUD_LANE_ENV in os.environ
    if not marker_present and not environment_present:
        return False, None
    if marker_lane in CLOUD_LANES:
        return True, marker_lane
    value = os.environ.get(CLOUD_LANE_ENV, "")
    return True, value or None


def cloud_lane_attestation_error() -> str | None:
    """Reject every partial, invalid, or mismatched Cloud lane attestation."""
    marker_present, marker_lane = cloud_lane_marker()
    environment_present = CLOUD_LANE_ENV in os.environ
    if not marker_present and not environment_present:
        return None
    if not marker_present:
        return f"{CLOUD_LANE_MARKER} is missing while {CLOUD_LANE_ENV} is present"
    if marker_lane is None:
        return f"{CLOUD_LANE_MARKER} is missing or contains an invalid lane"
    if not environment_present:
        return f"{CLOUD_LANE_ENV} is missing while {CLOUD_LANE_MARKER} is present"
    environment_lane = os.environ.get(CLOUD_LANE_ENV, "")
    if environment_lane not in CLOUD_LANES:
        return f"{CLOUD_LANE_ENV} contains an invalid lane"
    if environment_lane != marker_lane:
        return (
            f"{CLOUD_LANE_ENV}={environment_lane!r} disagrees with "
            f"{CLOUD_LANE_MARKER}={marker_lane!r}"
        )
    return None


def check_registered_cloud_context(
    event: dict[str, object], lane_present: bool, lane: str | None
) -> int | None:
    """Keep a registered Cloud transcript inside its original lane.

    Local sessions have no lane marker and remain extensible.  Once a
    transcript was registered while a lane marker was present, dropping or
    changing that marker is an execution-boundary failure and must stop the
    call.  This also covers a role-less Cloud root when its SubagentStart hook
    ran with the marker.
    """
    policy = policy_data(event)
    if policy is None:
        return None
    registered_role = policy.get("agent_type")
    if registered_role is not None and (
        not isinstance(registered_role, str) or registered_role not in RPM_ROLES
    ):
        return deny(
            f"Cloud transcript registered an unknown agent role {registered_role!r}"
        )
    if policy.get("cloud") is True:
        registered_lane = policy.get("lane")
        if not lane_present:
            return deny(
                f"Cloud transcript lost {CLOUD_LANE_ENV} after registration; "
                "stop before using a local fallback"
            )
        if registered_lane not in CLOUD_LANES or lane != registered_lane:
            return deny(
                f"Cloud transcript changed {CLOUD_LANE_ENV} after registration; "
                "restart with the registered lane"
            )
        if policy.get("marker") is True:
            marker_present, marker_lane = cloud_lane_marker()
            if not marker_present or marker_lane != registered_lane:
                return deny(
                    f"Cloud transcript lost or changed {CLOUD_LANE_MARKER} after "
                    "registration"
                )
    elif policy.get("cloud") is False and lane_present:
        return deny(
            f"local transcript cannot enter Cloud lane {lane!r} after registration"
        )
    return None


def is_agent_tool(tool: str) -> bool:
    if tool not in {"Agent", "spawn_agent"} and tool != tool.casefold():
        return False
    normalized = normalized_tool(tool)
    return (
        normalized == "agent"
        or "spawn_agent" in normalized
        or normalized.endswith("__agent")
    )


def requested_agent_roles(tool_input: object) -> set[str]:
    """Extract only explicit agent identity fields from an Agent call."""
    if not isinstance(tool_input, dict):
        return set()
    roles: set[str] = set()
    for key, value in tool_input.items():
        if str(key).casefold() not in {"agent_type", "role", "agent"}:
            continue
        if isinstance(value, str) and value:
            roles.add(value)
        elif isinstance(value, list):
            roles.update(item for item in value if isinstance(item, str) and item)
    return roles


def is_shell_tool(tool: str) -> bool:
    if tool not in {"Bash", "shell", "exec", "exec_command", "functions.exec", "functions.exec_command", "terminal"} and tool != tool.casefold():
        return False
    normalized = normalized_tool(tool)
    return any(
        normalized == part
        or normalized.endswith(f"__{part}")
        or normalized.endswith(f".{part}")
        for part in SHELL_TOOL_PARTS
    )


def is_merge_mcp_call(tool: str, tool_input: object) -> bool:
    """Recognize a merge operation from the tool name or explicit operation field."""
    normalized = normalized_tool(tool)
    if re.search(
        r"(?:^|__)(?:github_)?merge(?:_pull_request|pullrequest)?(?:__|$)",
        normalized,
    ) or re.search(r"github_merge_pull_request$|mergepullrequest", normalized):
        return True
    return any(
        re.search(r"\bmerge(?:[_ -]pull[_ -]?request)?\b", value.casefold())
        for value in operation_values(tool_input)
    )


def has_forbidden_review_or_merge(text: str) -> str | None:
    lowered = text.casefold()
    if "@codex review" in lowered:
        return "`@codex review` is owned by external repository review configuration"
    if (
        contains_shell_sequence(lowered, "gh", "pr", "merge")
        or contains_shell_sequence(lowered, "git", "merge")
        or re.search(r"\bsafe-direct-merge(?:\.sh)?\b", lowered)
        or re.search(r"\b(?:merge_pull_request|mergepullrequest)\b", lowered)
    ):
        return "RPM subagents cannot merge pull requests"
    return None


def shell_mutation_kind(text: str) -> str | None:
    if read_only_shell_wrapper(text) or read_only_interpreter_command(text):
        return None
    executor = shell_executor_kind(text)
    if executor is not None:
        return "repo_write"
    lowered = text.casefold()
    tokens = shell_tokens(text)
    if tokens is not None:
        for index, token in enumerate(tokens):
            if token.casefold() == "git" and _git_invocation_is_mutating(tokens, index):
                return "repo_write"
    # A shell wrapper can keep a nested command in one quoted token (for
    # example, ``bash -c 'git -C repo push origin HEAD'``).  Scan each command
    # segment conservatively so option placement cannot hide a mutation.
    for segment in re.split(r"[;&|()<>\r\n]+", lowered):
        git_at = re.search(r"(?<![a-z0-9_-])git\b", segment)
        if git_at is not None:
            git_tail = segment[git_at.end() :]
            if re.search(
                r"\b(?:add|am|apply|bisect|checkout|cherry-pick|clean|clone|commit|fetch|filter-branch|filter-repo|gc|init|merge|mv|notes|pull|push|rebase|reflog|replace|reset|restore|rm|stash|switch|tag|update-index|update-ref|worktree)\b",
                git_tail,
            ) or re.search(
                r"\bremote\s+(?:add|prune|remove|rename|set-head|set-branches|set-url)\b",
                git_tail,
            ) or re.search(
                r"\b(?:exec|ext-diff|paginate|textconv|output)\b",
                git_tail,
            ):
                return "repo_write"
    if re.search(r"\b(?:curl|wget|nc|netcat)\b", lowered):
        return "raw_api_mutation"
    if contains_shell_sequence(lowered, "gh", "api"):
        return "raw_api_mutation"
    if re.search(r"\b(?:tee|sed\s+-i|perl\s+-pi|python(?:3)?\s+-c)\b", lowered):
        return "repo_write"
    if re.search(
        r"(?:^|[;&|]\s*)(?:sudo\s+)?(?:cp|mv|touch|install|truncate|dd|rm|unlink|rmdir|mkdir|chmod|chown|ln|rename|shred|scp|rsync|ed|ex|vi|vim|nvim)\b",
        lowered,
    ):
        return "repo_write"
    # Redirects and heredocs can write files without naming a writer command.
    if re.search(r"(?:^|[\s;&|])(?:>>?|<<)(?:[^=]|$)", lowered):
        return "repo_write"
    if contains_shell_sequence(lowered, "gh", "issue", "create"):
        return "issue_create"
    if contains_shell_sequence(lowered, "gh", "issue", "edit"):
        return "issue_edit"
    if any(
        contains_shell_sequence(lowered, "gh", "issue", subcommand)
        for subcommand in ("comment", "close", "reopen", "delete", "transfer", "pin")
    ):
        return "issue_other"
    if contains_shell_sequence(lowered, "gh", "project", "item-add"):
        return "project_add"
    if any(
        contains_shell_sequence(lowered, "gh", "project", subcommand)
        for subcommand in ("item-edit", "item-delete", "edit", "delete", "copy", "close")
    ):
        return "project_other"
    if contains_shell_program(lowered, "gh"):
        return "other_github"
    if re.search(r"\bgh\s+(?:label|pr)\b", lowered):
        return "other_github"
    return None


def is_cloud_merge_shell(text: str) -> bool:
    lowered = text.casefold()
    return bool(
        contains_shell_sequence(lowered, "gh", "pr", "merge")
        or re.search(r"\bsafe-direct-merge(?:\.sh)?\b", lowered)
        or contains_shell_sequence(lowered, "git", "merge")
        or (
            contains_shell_sequence(lowered, "gh", "api")
            and re.search(r"(?:/merge\b|\bmergepullrequest\b)", lowered)
        )
    )


def mcp_mutation_kind(tool: str, tool_input: object) -> str | None:
    """Classify GitHub MCP writes using the operation name, never free text.

    Connector tool names differ slightly between hosts. The operation field is
    considered only when it is an action/operation/method/mutation value, so a
    review body mentioning ``resolve`` cannot turn a read into a write.
    """
    normalized = normalized_tool(tool)
    operation_text = " ".join(
        [normalized, *[normalized_tool(value) for value in operation_values(tool_input)]]
    )
    if is_merge_mcp_call(tool, tool_input):
        return "merge"
    if re.search(r"(?:^|[_ ])(?:resolve|resolve_review_thread)$", operation_text):
        return "review_resolve"
    if re.search(r"(?:^|[_ ])(?:unresolve|unresolve_review_thread)$", operation_text):
        return "review_unresolve"
    if re.search(r"dismiss(?:_pull_request)?_review", operation_text):
        return "review_dismiss"
    if re.search(r"enable(?:_pull_request)?_auto_merge|enable_auto_merge", operation_text):
        return "pr_auto_merge"
    if re.search(r"mark(?:_pull_request)?_ready(?:_for_review)?", operation_text):
        return "pr_ready"
    if re.search(r"(?:create|open)_pull_request", operation_text):
        return "pull_request_create"
    if re.search(r"(?:update|edit)_pull_request", operation_text):
        return "pull_request_update"
    if re.search(r"(?:add|create|post)_.*comment|comment_.*(?:issue|pull_request|pr)", operation_text):
        return "issue_comment"
    if re.search(r"(?:update|edit)_.*comment", operation_text):
        return "issue_comment_update"
    if re.search(r"(?:add|remove|delete)_.*label|(?:label|labels)$", operation_text):
        return "label"
    mutation_words = r"create|update|edit|write|delete|remove|add|close|reopen|comment|label|mutation|resolve|dismiss|enable|mark"
    if not re.search(rf"(?:^|[_ ])(?:{mutation_words})(?:[_ ]|$)", operation_text):
        return None
    if "issue" in operation_text and "create" in operation_text:
        return "issue_create"
    if "project" in operation_text and any(word in operation_text for word in ("add", "create")):
        return "project_add"
    if "project" in operation_text:
        return "project_other"
    if "label" in operation_text:
        return "label"
    if "issue" in operation_text and any(word in operation_text for word in ("update", "edit")):
        return "issue_edit"
    if "issue" in operation_text:
        return "issue_other"
    return "unknown_mutation"


def is_known_mcp_read(tool: str, tool_input: object) -> bool:
    """Allow only explicitly read-shaped MCP operations by default."""
    if mcp_mutation_kind(tool, tool_input) is not None:
        return False
    name = normalized_tool(tool)
    if not any(name.startswith(prefix) for prefix in CLOUD_MCP_PREFIXES):
        return False
    operation = name.rsplit("__", 1)[-1]
    if operation.startswith("github_"):
        operation = operation.removeprefix("github_")
    if operation not in CLOUD_MCP_READ_OPERATIONS:
        return False
    if not repository_input_is_allowed(tool_input):
        return False
    if operation in REPOSITORY_SCOPED_MCP_READ_OPERATIONS:
        return repository_is_rpm(tool_input)
    return True


def cloud_mutation_kind(tool: str, tool_input: object, text: str) -> str | None:
    if normalized_tool(tool) in CLOUD_PATCH_TOOLS:
        return "patch"
    if is_cloud_merge_shell(text):
        return "merge"
    if tool.startswith("mcp__"):
        mutation = mcp_mutation_kind(tool, tool_input)
        return mutation if mutation is not None or is_known_mcp_read(tool, tool_input) else "unknown_mutation"
    if is_shell_tool(tool):
        return shell_mutation_kind(text)
    return None


def is_cloud_recognized_tool(tool: str) -> bool:
    """Return whether a Cloud call has an explicitly reviewed tool shape."""
    if tool in {
        "Bash",
        "shell",
        "exec",
        "exec_command",
        "functions.exec",
        "functions.exec_command",
        "terminal",
        "apply_patch",
        "Edit",
        "Write",
    }:
        return True
    if is_agent_tool(tool):
        return tool in {"Agent", "spawn_agent"}
    if is_shell_tool(tool):
        return tool in {
            "Bash",
            "shell",
            "exec",
            "exec_command",
            "functions.exec",
            "functions.exec_command",
            "terminal",
        }
    # Connector and namespaced tool identifiers are lower-case by contract.
    # Keeping this exact prevents a newly introduced or mixed-case tool from
    # inheriting a lower-cased read/mutation classification.
    return (
        tool == tool.casefold()
        and any(tool.startswith(prefix) for prefix in CLOUD_MCP_PREFIXES)
    )


def safe_cloud_read_shell(text: str) -> bool:
    """Recognize one non-composed read or deterministic checker command."""
    if re.search(r"[;&|<>`$\r\n]", text):
        return False
    tokens = shell_tokens(text)
    if tokens is None:
        return False
    if not tokens:
        return False
    if tokens == ["pwd"]:
        return True
    if tokens[:2] == ["bash", "scripts/check-workflow-intake.sh"]:
        return len(tokens) == 2
    if tokens and tokens[0] == "git":
        subcommand, subcommand_index = _git_subcommand(tokens, 0)
        if subcommand is None or _git_invocation_is_mutating(tokens, 0):
            return False
        if subcommand not in GIT_READ_SUBCOMMANDS and subcommand != "branch":
            return False
        forbidden = {
            "--ext-diff",
            "--textconv",
            "--exec",
            "--paginate",
        }
        return not any(
            token in forbidden
            or token == "--output"
            or token.startswith("--output=")
            or token.startswith("--format=%x")
            for token in tokens[subcommand_index + 1 :]
        )
    python_index = 1 if tokens[0] == "python3" else -1
    if python_index < 0:
        return False
    if len(tokens) > 1 and tokens[1] == "-B":
        python_index = 2
    if len(tokens) <= python_index or tokens[python_index] not in {
        "scripts/check-cloud-queue-contract.py",
        "scripts/check-merge-gate.py",
    }:
        return False
    arguments = tokens[python_index + 1 :]
    if any(
        argument.startswith("--policy=")
        and argument != "--policy=.agents/workflows/backlog-policy.json"
        for argument in arguments
    ):
        return False
    if "--policy" in arguments:
        if arguments.count("--policy") != 1:
            return False
        policy_index = arguments.index("--policy")
        if (
            policy_index + 1 >= len(arguments)
            or arguments[policy_index + 1]
            != ".agents/workflows/backlog-policy.json"
        ):
            return False
    if arguments.count("--issues-json") != 1 or any(
        argument == "--issues-file" or argument.startswith("--issues-file=")
        for argument in arguments
    ):
        return False
    index = arguments.index("--issues-json")
    if index + 1 >= len(arguments):
        return False
    try:
        inline = json.loads(arguments[index + 1])
    except json.JSONDecodeError:
        return False
    return isinstance(inline, dict)


def safe_cloud_shell_command(text: str, lane: str) -> bool:
    del lane
    return safe_cloud_read_shell(text)


def safe_cloud_role_shell_command(text: str, role: str) -> bool:
    """Allow only fixed read commands and the verifier's fixed gate command.

    Cloud workers still need a small inspection surface.  Unknown executables
    are denied here before the generic mutation classifier can treat them as
    harmless.  Build and interpreter commands remain denied, including their
    versioned aliases; the two command-only roles may run the exact repository
    validation recipe used by their contract.
    """
    if read_only_shell_wrapper(text) or safe_cloud_read_shell(text):
        return True
    if any(character in text for character in ";&|()<>`$\r\n"):
        return False
    tokens = shell_tokens(text)
    if tokens is None or not tokens:
        return False
    if (role, tuple(tokens)) in CLOUD_TEST_COMMANDS:
        return True
    if shell_executor_kind(text) is not None:
        return False
    return executable_name(tokens[0]) in CLOUD_READ_ONLY_SHELL_PROGRAMS


def check_cloud_top_level(
    tool: str, tool_input: object, text: str
) -> int | None:
    """Apply the lane boundary only to a role-less Cloud session.

    A valid merge lane has one mutating exception: the connected GitHub plugin's
    merge operation. Every other repository or GitHub mutation stays with the
    role-specific workers. An explicitly present invalid marker fails closed.
    When the marker is absent, the hook preserves established local execution;
    the Cloud launcher must therefore always configure RPM_CLOUD_LANE.
    """
    lane_present, lane = cloud_lane_from_environment()
    if not lane_present:
        return None
    if lane not in CLOUD_LANES:
        return deny(
            f"top-level Cloud session has missing or invalid {CLOUD_LANE_ENV}; "
            "complete the lane preflight before any mutation"
        )
    if not is_cloud_recognized_tool(tool):
        return deny(
            f"top-level Cloud {lane} lane cannot use unknown or mixed-case tool {tool!r}"
        )
    if is_agent_tool(tool):
        requested = requested_agent_roles(tool_input)
        allowed = CLOUD_TOP_LEVEL_AGENT_ALLOWLIST[lane]
        if len(requested) != 1 or not requested <= allowed:
            return deny(
                f"top-level Cloud {lane} lane cannot spawn unassigned agent "
                f"{', '.join(sorted(requested)) or '<missing>'}"
            )
        return 0
    if is_shell_tool(tool):
        if contains_shell_program(text, "gh"):
            return deny(
                f"top-level Cloud {lane} lane cannot use gh; use the connected GitHub plugin"
            )
        if is_cloud_merge_shell(text):
            return deny(
                f"top-level Cloud {lane} lane cannot merge through a shell command"
            )
        return 0 if safe_cloud_shell_command(text, lane) else deny(
            f"top-level Cloud {lane} lane shell command is outside the reviewed allowlist"
        )
    mutation = cloud_mutation_kind(tool, tool_input, text)
    if mutation is None:
        if tool.startswith("mcp__") and is_known_mcp_read(tool, tool_input):
            return 0
        return deny(
            f"top-level Cloud {lane} lane cannot use an unclassified tool operation"
        )
    if mutation == "merge":
        return deny(
            f"top-level Cloud {lane} lane cannot merge; merge execution is "
            "owned by the server-side gate"
        )
    return deny(
        f"top-level Cloud {lane} lane cannot perform mutations; delegate writes "
        "to the assigned RPM worker"
    )


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
            "body_file",
            "assignees",
            "milestone",
            "state",
        }
        if collect_keys(tool_input) & forbidden_keys:
            return False
        keys = collect_keys(tool_input)
        if "body" in keys:
            if "labels" not in keys or not any(
                re.search(r"<!--\s*rpm-agent-execution:\s*\{", value)
                for value in flatten_strings(tool_input)
            ):
                return False
        lowered = shell_text.casefold()
        if lowered and any(
            flag in lowered
            for flag in ("--body-file", "--title", "--assignee", "--milestone")
        ):
            return False
        if "--body" in lowered and not (
            "rpm-agent-execution:" in lowered and "--label" in lowered
        ):
            return False
        labels = {
            value
            for value in flatten_strings(tool_input)
            if isinstance(value, str) and value.startswith("agent:")
        }
        return not labels or labels <= STATE_LABELS
    if role == "rpm_ticket_publisher":
        keys = collect_keys(tool_input)
        if kind == "pull_request_create":
            allowed = {
                "repository_full_name",
                "head",
                "head_branch",
                "base",
                "base_branch",
                "title",
                "body",
                "draft",
                "maintainer_can_modify",
            }
            has_head = "head" in keys or "head_branch" in keys
            has_base = "base" in keys or "base_branch" in keys
            head_values = field_values(tool_input, "head") or field_values(
                tool_input, "head_branch"
            )
            base_values = field_values(tool_input, "base") or field_values(
                tool_input, "base_branch"
            )
            if not isinstance(tool_input, dict):
                return False
            return (
                keys <= allowed
                and repository_is_rpm(tool_input)
                and {"repository_full_name", "title", "body", "draft"} <= keys
                and has_head
                and has_base
                and ("head" in keys) != ("head_branch" in keys)
                and ("base" in keys) != ("base_branch" in keys)
                and base_values == ["main"]
                and len(head_values) == 1
                and head_values[0] != "main"
                and tool_input.get("draft") is True
            )
        if kind == "pull_request_update":
            return keys <= {
                "repository_full_name",
                "pr_number",
                "body",
                "maintainer_can_modify",
            } and repository_is_rpm(tool_input) and positive_number(
                tool_input, "pr_number"
            ) and {"repository_full_name", "pr_number", "body"} <= keys
        if kind == "pr_ready":
            return (
                keys == {"repository_full_name", "pr_number"}
                and repository_is_rpm(tool_input)
                and positive_number(tool_input, "pr_number")
            )
        if kind == "issue_edit":
            values = field_values(tool_input, "labels")
            lifecycle = [value for value in values if value in STATE_LABELS]
            corrections = [
                value for value in values if re.fullmatch(r"agent:correction-[0-5]", value)
            ]
            return (
                keys <= {"repository_full_name", "issue_number", "labels"}
                and repository_is_rpm(tool_input)
                and positive_number(tool_input, "issue_number")
                and {"repository_full_name", "issue_number", "labels"} <= keys
                and (
                    (lifecycle == ["agent:review-pending"] and not corrections)
                    or (not lifecycle and corrections == ["agent:correction-0"])
                )
            )
        if kind == "label":
            values = field_values(tool_input, "labels")
            corrections = [
                value for value in values if re.fullmatch(r"agent:correction-[0-5]", value)
            ]
            lifecycle = [value for value in values if value in STATE_LABELS]
            return (
                keys <= {"repository_full_name", "issue_number", "labels"}
                and repository_is_rpm(tool_input)
                and positive_number(tool_input, "issue_number")
                and {"repository_full_name", "issue_number", "labels"} <= keys
                and corrections == ["agent:correction-0"]
                and not lifecycle
            )
        return False
    if role == "rpm_review_reconciler":
        keys = collect_keys(tool_input)
        values = flatten_strings(tool_input)
        if kind == "review_resolve":
            return keys == {"thread_id"} and bool(
                isinstance(tool_input, dict) and tool_input.get("thread_id")
            )
        if kind == "issue_comment":
            return (
                keys <= {"repository_full_name", "repo_full_name", "issue_number", "pr_number", "comment"}
                and {"comment"} <= keys
                and ("repository_full_name" in keys) != ("repo_full_name" in keys)
                and ("issue_number" in keys) != ("pr_number" in keys)
                and repository_is_rpm(tool_input)
                and any(
                    re.search(
                        r"<!--\s*rpm-agent-correction-block:\s*source=pr:[1-9][0-9]*;\s*reason=[^;\s]+;\s*counter=agent:correction-[0-5]\s*-->",
                        value,
                    )
                    for value in values
                )
            )
        if kind == "issue_edit":
            labels = field_values(tool_input, "labels")
            lifecycle = [value for value in labels if value in STATE_LABELS]
            corrections = [
                value for value in labels if re.fullmatch(r"agent:correction-[0-5]", value)
            ]
            return (
                keys <= {"repository_full_name", "issue_number", "labels"}
                and repository_is_rpm(tool_input)
                and positive_number(tool_input, "issue_number")
                and {"repository_full_name", "issue_number", "labels"} <= keys
                and (
                    (
                        len(lifecycle) == 1
                        and lifecycle[0] in {"agent:awaiting-merge", "agent:blocked"}
                        and not corrections
                    )
                    or (
                        not lifecycle
                        and len(corrections) == 1
                        and corrections[0] in {
                            f"agent:correction-{index}" for index in range(1, 6)
                        }
                    )
                )
            )
        if kind == "label":
            labels = field_values(tool_input, "labels")
            corrections = [
                value for value in labels if re.fullmatch(r"agent:correction-[0-5]", value)
            ]
            lifecycle = [value for value in labels if value in STATE_LABELS]
            return (
                keys <= {"repository_full_name", "issue_number", "labels"}
                and repository_is_rpm(tool_input)
                and positive_number(tool_input, "issue_number")
                and {"repository_full_name", "issue_number", "labels"} <= keys
                and len(corrections) == 1
                and corrections[0] in {f"agent:correction-{index}" for index in range(1, 6)}
                and not lifecycle
            )
        return False
    if role == "rpm_merge_state_writer":
        keys = collect_keys(tool_input)
        values = flatten_strings(tool_input)
        if kind == "issue_edit":
            labels = field_values(tool_input, "labels")
            lifecycle = [value for value in labels if value in STATE_LABELS]
            corrections = [
                value for value in labels if re.fullmatch(r"agent:correction-[0-5]", value)
            ]
            return (
                keys <= {"repository_full_name", "issue_number", "labels"}
                and repository_is_rpm(tool_input)
                and positive_number(tool_input, "issue_number")
                and {"repository_full_name", "issue_number", "labels"} <= keys
                and lifecycle == ["agent:blocked"]
                and not corrections
            )
        if kind == "issue_comment":
            return (
                keys <= {"repository_full_name", "repo_full_name", "issue_number", "pr_number", "comment"}
                and {"comment"} <= keys
                and ("repository_full_name" in keys) != ("repo_full_name" in keys)
                and ("issue_number" in keys) != ("pr_number" in keys)
                and repository_is_rpm(tool_input)
                and any("rpm-agent-merge-block" in value for value in values)
            )
        return False
    return False


def check_tool(event: dict[str, object]) -> int:
    role = current_role(event)
    tool = event.get("tool_name")
    if not isinstance(tool, str):
        return deny(f"{role or 'top-level Cloud session'} supplied no tool_name")
    tool_input = event.get("tool_input")
    text = "\n".join(flatten_strings(tool_input))

    lane_present, lane = cloud_lane_from_environment()
    attestation_error = cloud_lane_attestation_error()
    if attestation_error is not None:
        return deny(f"Cloud lane attestation failed: {attestation_error}")
    registered_context_error = check_registered_cloud_context(
        event, lane_present, lane
    )
    if registered_context_error is not None:
        return registered_context_error
    if lane_present:
        if lane not in CLOUD_LANES:
            return deny(
                f"Cloud tool call has missing or invalid {CLOUD_LANE_ENV}; "
                "complete the lane preflight before any tool use"
            )
        if role is None:
            if event.get("agent_type") is not None:
                return deny(
                    "Cloud role identity was supplied but could not be verified "
                    "from the registered transcript"
                )
            return check_cloud_top_level(tool, tool_input, text) or 0
        if role not in CLOUD_AGENT_ALLOWLIST[lane]:
            return deny(
                f"role {role} is not assigned to the Cloud {lane} lane"
            )
        if not is_cloud_recognized_tool(tool):
            return deny(
                f"Cloud {lane} lane cannot use unknown or mixed-case tool {tool!r}"
            )
        if tool in {"functions.exec", "functions.exec_command"}:
            return deny(
                f"Cloud {lane} role calls cannot use {tool}; nested tool execution "
                "could bypass the shell and GitHub boundaries"
            )

    if role is None:
        return 0

    forbidden = has_forbidden_review_or_merge(f"{tool}\n{text}")
    if forbidden:
        return deny(forbidden)

    if is_agent_tool(tool):
        if role not in MANAGERS:
            return deny(f"{role} is a leaf and cannot spawn agents")
        requested = requested_agent_roles(tool_input)
        allowed = MANAGER_CHILDREN[role]
        lane_present, lane = cloud_lane_from_environment()
        if lane_present:
            if lane != "issue":
                return deny(f"{role} cannot route workers in the Cloud {lane or 'invalid'} lane")
            allowed = CLOUD_ISSUE_MANAGER_CHILDREN[role]
        if len(requested) != 1 or not requested <= allowed:
            return deny(
                f"{role} cannot spawn unassigned agent "
                f"{', '.join(sorted(requested)) or '<missing>'}"
            )
        return 0

    if tool.startswith("mcp__"):
        if role not in MCP_READ_ROLES:
            return deny(f"{role} has no MCP assignment")
        mutation = mcp_mutation_kind(tool, tool_input)
        if mutation is None:
            return 0 if is_known_mcp_read(tool, tool_input) else deny(
                f"{role} cannot use an unclassified MCP operation"
            )
        lane_present, lane = cloud_lane_from_environment()
        if (
            lane_present
            and lane in {"issue", "review"}
            and role in CLOUD_ACTION_SIDE_WRITERS
        ):
            return deny(
                f"{role} cannot mutate GitHub in the Cloud {lane} lane; "
                "the GitHub Actions publisher owns these writes"
            )
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
        if role in WRITER_ROLES | RESULT_WRITER_ROLES:
            return deny(f"{role} is MCP-only and cannot use shell tools")
        if lane_present and lane in {"issue", "review"} and contains_shell_program(text, "gh"):
            return deny(
                f"Cloud {lane} subagents cannot use gh; use the connected GitHub plugin"
            )
        if lane_present and not safe_cloud_role_shell_command(text, role):
            return deny(
                f"Cloud {lane} role shell command is outside the fixed read-only allowlist"
            )
        if lane_present and (role, tuple(shell_tokens(text) or [])) in CLOUD_TEST_COMMANDS:
            return 0
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
