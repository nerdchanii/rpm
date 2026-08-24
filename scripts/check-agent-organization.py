#!/usr/bin/env python3
"""Validate the project-scoped RPM agent organization and workflow policy."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AGENTS_DIR = ROOT / ".codex" / "agents"
POLICY_PATH = ROOT / ".agents" / "workflows" / "backlog-policy.json"

MANAGER_REPORTS = {
    "rpm_workflow_manager": {
        "rpm_backlog_manager",
        "rpm_issue_manager",
    },
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
LEAF_SANDBOX = {
    "rpm_backlog_scout": "read-only",
    "rpm_idea_issue_creator": "read-only",
    "rpm_issue_researcher": "read-only",
    "rpm_issue_refiner": "read-only",
    "rpm_issue_readiness_reviewer": "read-only",
    "rpm_ready_ticket_claimer": "read-only",
    "rpm_issue_fetcher": "read-only",
    "rpm_spec_reviewer": "read-only",
    "rpm_issue_spec_reconciler": "read-only",
    "rpm_spec_updater": "workspace-write",
    "rpm_test_author": "workspace-write",
    "rpm_implementer": "workspace-write",
    "rpm_test_runner": "read-only",
    "rpm_verifier": "read-only",
    "rpm_adversarial_reviewer": "read-only",
    "rpm_followup_issue_creator": "read-only",
}
EXPECTED_SANDBOX = {
    **{manager: "read-only" for manager in MANAGER_REPORTS},
    **LEAF_SANDBOX,
}
BACKLOG_ROLES = {
    "rpm_workflow_manager",
    "rpm_backlog_manager",
    *MANAGER_REPORTS["rpm_backlog_manager"],
}
FORBIDDEN_ASSETS = (
    ".agents/skills/ticket-pr-lifecycle",
    ".codex/agents/ticket-explorer.toml",
    ".codex/agents/pr-checklist-updater.toml",
    "scripts/watch-codex-review.sh",
)
FORBIDDEN_REFERENCES = (
    "ticket-pr-lifecycle",
    "ticket-explorer",
    "pr-checklist-updater",
    "watch-codex-review.sh",
)
EXPECTED_SKILL_INVOCATION_POLICY = {
    "fixture-governance": True,
    "merge-gatekeeper": False,
    "open-pr-review-batch": False,
    "pr-resolution-loop": False,
    "pr-review-resolution": False,
    "prepare-backlog": False,
    "rust-analyzer": True,
    "safe-direct-merge": False,
    "spec-governance": True,
    "take-ticket": False,
}
EXPECTED_TRANSITIONS = {
    "untracked": ["research"],
    "research": ["research", "ready", "blocked"],
    "ready": ["claimed", "blocked"],
    "claimed": ["ready", "review-pending", "blocked"],
    "review-pending": ["review-pending", "awaiting-merge", "blocked"],
    "awaiting-merge": ["blocked"],
    "blocked": ["research", "ready"],
}
EXPECTED_LABELS = {
    "research": "agent:research",
    "ready": "agent:ready",
    "claimed": "agent:claimed",
    "review-pending": "agent:review-pending",
    "awaiting-merge": "agent:awaiting-merge",
    "blocked": "agent:blocked",
}
EXPECTED_EXECUTION_CONTRACT = {
    "approved_metadata": ["approval_id", "plan_revision", "scope_hash", "executor"],
    "executor_values": ["local", "cloud"],
    "active_states": ["claimed", "review-pending"],
    "lease": {
        "field": "lease",
        "required_fields": ["run_id", "owner", "expires_at"],
        "ttl_seconds": 3600,
    },
    "idempotency": {
        "ledger_field": "runs",
        "key_fields": ["repository", "issue", "plan_revision", "scope_hash", "event_id"],
        "algorithm": "sha256-nul-joined",
    },
}


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def load_agents(errors: list[str]) -> dict[str, tuple[Path, dict[str, object]]]:
    loaded: dict[str, tuple[Path, dict[str, object]]] = {}
    for path in sorted(AGENTS_DIR.glob("*.toml")):
        try:
            with path.open("rb") as handle:
                data = tomllib.load(handle)
        except (OSError, tomllib.TOMLDecodeError) as error:
            fail(errors, f"{path.relative_to(ROOT)}: invalid TOML: {error}")
            continue
        for key in ("name", "description", "developer_instructions"):
            if not isinstance(data.get(key), str) or not str(data[key]).strip():
                fail(errors, f"{path.relative_to(ROOT)}: missing non-empty {key}")
        name = data.get("name")
        if not isinstance(name, str):
            continue
        if name in loaded:
            fail(errors, f"{path.relative_to(ROOT)}: duplicate agent name {name!r}")
            continue
        loaded[name] = (path, data)
        sandbox = data.get("sandbox_mode")
        if sandbox is not None and sandbox not in {
            "read-only",
            "workspace-write",
            "danger-full-access",
        }:
            fail(errors, f"{path.relative_to(ROOT)}: unsupported sandbox_mode {sandbox!r}")
    return loaded


def check_policy(errors: list[str]) -> None:
    try:
        policy = json.loads(POLICY_PATH.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: invalid policy JSON: {error}")
        return
    if not isinstance(policy, dict):
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: policy must be an object")
        return
    if policy.get("version") != 3:
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: version must be 3")
    if policy.get("repository") != "nerdchanii/rpm":
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: repository must be nerdchanii/rpm")
    queue = policy.get("execution_queue")
    if queue != {
        "source": "issue-labels",
        "open_issues_only": True,
        "order": "issue-number-ascending",
        "active_states": ["claimed", "review-pending"],
    }:
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: invalid execution queue contract")
    project = policy.get("project")
    if not isinstance(project, dict) or project != {
        "owner": "@me",
        "number": 7,
        "role": "local-roadmap",
        "required_for_execution": False,
    }:
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: invalid local-roadmap Project contract")
    if policy.get("labels") != EXPECTED_LABELS:
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: lifecycle labels changed")
    if policy.get("execution_contract") != EXPECTED_EXECUTION_CONTRACT:
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: invalid execution contract")
    if policy.get("batch_limits") != {"research": 1, "execution": 1}:
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: both batch limits must equal 1")
    if policy.get("allowed_transitions") != EXPECTED_TRANSITIONS:
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: transition allowlist changed")
    automation = policy.get("automation")
    if not isinstance(automation, dict) or any(
        automation.get(key) is not False
        for key in (
            "create_followup_issues_by_default",
            "merge_pull_requests",
            "request_codex_review",
        )
    ):
        fail(
            errors,
            f"{POLICY_PATH.relative_to(ROOT)}: automatic follow-ups, subagent merge, and Codex review must stay disabled",
        )
    if policy.get("merge_gate") != {
        "enabled": True,
        "source_state": "awaiting-merge",
        "order": "issue-number-ascending",
        "batch_limit": 1,
        "required_checks": ["metadata", "verify"],
        "required_mergeable": True,
        "forbid_unresolved_p0_p1": True,
        "method": "squash",
        "delete_branch": True,
    }:
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: invalid merge-gate contract")


def check_role_contracts(
    agents: dict[str, tuple[Path, dict[str, object]]], errors: list[str]
) -> None:
    for name, sandbox in EXPECTED_SANDBOX.items():
        if name not in agents:
            fail(errors, f".codex/agents/{name}.toml: required role is missing")
            continue
        path, data = agents[name]
        relative = path.relative_to(ROOT)
        if data.get("sandbox_mode") != sandbox:
            fail(
                errors,
                f"{relative}: expected sandbox_mode={sandbox!r}, got {data.get('sandbox_mode')!r}",
            )
        instructions = str(data.get("developer_instructions", ""))
        if "Return exactly one JSONL event:" not in instructions or '{"type":' not in instructions:
            fail(errors, f"{relative}: missing exact JSONL output contract")
        if name in BACKLOG_ROLES and ".agents/workflows/backlog-policy.json" not in instructions:
            fail(errors, f"{relative}: backlog role does not read the policy")
        if name in LEAF_SANDBOX and "spawn/contact other agents" not in instructions:
            fail(errors, f"{relative}: leaf is missing the no-delegation boundary")
        if name in {"rpm_test_runner", "rpm_verifier"}:
            environment = data.get("shell_environment_policy")
            if not isinstance(environment, dict) or environment.get("set") != {
                "CARGO_TARGET_DIR": "/tmp/rpm-codex-target"
            }:
                fail(errors, f"{relative}: command-only role must redirect Cargo artifacts")

    role_pattern = re.compile(r"\brpm_[a-z0-9_]+\b")
    known_roles = set(EXPECTED_SANDBOX)
    for manager, reports in MANAGER_REPORTS.items():
        if manager not in agents:
            continue
        path, data = agents[manager]
        text = str(data.get("developer_instructions", ""))
        for report in sorted(reports):
            if report not in text:
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: direct report {report!r} is unreachable",
                )
        exposed = set(role_pattern.findall(text)) & known_roles
        unexpected = exposed - reports - {manager}
        if unexpected:
            fail(
                errors,
                f"{path.relative_to(ROOT)}: manager exposes non-report roles: {', '.join(sorted(unexpected))}",
            )
        if f"Do not spawn another {manager}" not in text:
            fail(errors, f"{path.relative_to(ROOT)}: missing self-recursion prohibition")

    for leaf in LEAF_SANDBOX:
        if leaf not in agents:
            continue
        path, data = agents[leaf]
        text = str(data.get("developer_instructions", ""))
        leaked = (set(role_pattern.findall(text)) & known_roles) - {leaf}
        if leaked:
            fail(
                errors,
                f"{path.relative_to(ROOT)}: leaf exposes other role names: {', '.join(sorted(leaked))}",
            )

    if "rpm_workflow_manager" in agents:
        text = str(agents["rpm_workflow_manager"][1].get("developer_instructions", ""))
        for required in ("scheduled", 'status:"no-work"', "at most one issue"):
            if required not in text:
                fail(
                    errors,
                    f".codex/agents/rpm_workflow_manager.toml: missing scheduled contract {required!r}",
                )
    if "rpm_backlog_manager" in agents:
        text = str(agents["rpm_backlog_manager"][1].get("developer_instructions", ""))
        for required in ("research batch limit", "execution batch limit", "no-work"):
            if required not in text:
                fail(
                    errors,
                    f".codex/agents/rpm_backlog_manager.toml: missing batch contract {required!r}",
                )


def parse_frontmatter(path: Path, errors: list[str]) -> dict[str, str]:
    try:
        text = path.read_text()
    except OSError as error:
        fail(errors, f"{path.relative_to(ROOT)}: cannot read: {error}")
        return {}
    if not text.startswith("---\n"):
        fail(errors, f"{path.relative_to(ROOT)}: missing frontmatter")
        return {}
    try:
        frontmatter = text.split("---\n", 2)[1]
    except IndexError:
        fail(errors, f"{path.relative_to(ROOT)}: unterminated frontmatter")
        return {}
    values: dict[str, str] = {}
    for line in frontmatter.splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            values[key.strip()] = value.strip()
    return values


def parse_skill_invocation_policy(text: str) -> tuple[bool | None, str | None]:
    """Parse the deliberately small policy mapping in an openai.yaml file.

    A full YAML dependency is unnecessary here. The supported policy shape is
    intentionally strict: one root ``policy:`` mapping with one direct child.
    """
    blocks: list[list[tuple[int, str, int]]] = []
    current: list[tuple[int, str, int]] | None = None
    for line_number, raw_line in enumerate(text.splitlines(), 1):
        leading = raw_line[: len(raw_line) - len(raw_line.lstrip(" \t"))]
        if "\t" in leading:
            return None, f"line {line_number}: tabs are not allowed for policy indentation"
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        if indent == 0:
            if re.match(r"^policy\s*:", stripped):
                if stripped != "policy:":
                    return None, f"line {line_number}: policy must be a root mapping"
                blocks.append([])
                current = blocks[-1]
            else:
                current = None
            continue
        if current is not None:
            current.append((indent, stripped, line_number))

    if len(blocks) != 1:
        return None, "expected exactly one root policy mapping"
    children = blocks[0]
    if len(children) != 1:
        return None, "expected exactly one direct policy child"
    indent, child, line_number = children[0]
    if indent != 2:
        return None, f"line {line_number}: policy child must be directly indented by two spaces"
    key, separator, value = child.partition(":")
    if separator != ":" or key.strip() != "allow_implicit_invocation":
        return None, f"line {line_number}: unexpected policy child"
    if value.strip() not in {"true", "false"}:
        return None, f"line {line_number}: allow_implicit_invocation must be boolean"
    return value.strip() == "true", None


INTERFACE_METADATA_SCALAR_ERROR = (
    "interface metadata must be a non-empty YAML string scalar "
    "(plain scalars cannot start with YAML indicators such as - ? : , @ % or `; "
    "ASCII space is the only separator, literal tabs are rejected, and "
    "single/double quotes with separation-space comments are supported)"
)
YAML_SEPARATOR_SPACE = " "
LITERAL_SCALAR_CONTROL_ERROR = (
    "literal C0 and DEL control characters are not allowed in interface metadata scalars"
)


def parse_yaml_string_scalar(value: str, line_number: int) -> tuple[str | None, str | None]:
    """Parse the supported openai.yaml scalar subset without third-party dependencies.

    Interface metadata accepts non-empty plain, single-quoted, or double-quoted
    YAML string scalars. Plain scalars use YAML comment and leading-indicator
    rules; a comment is allowed after one ASCII separation space. Nulls,
    collections, tags, block scalars, non-string scalars, and literal tabs are
    rejected. Double-quoted YAML escapes remain supported; single-quoted and
    plain backslashes remain literal.
    """
    source = value.strip(YAML_SEPARATOR_SPACE)
    if not source:
        return None, None
    if any(ord(character) <= 0x1F or ord(character) == 0x7F for character in source):
        return None, f"line {line_number}: {LITERAL_SCALAR_CONTROL_ERROR}"

    def validate_quoted_tail(tail: str) -> str | None:
        if not tail:
            return None
        if not tail.startswith(YAML_SEPARATOR_SPACE):
            return "trailing content after quoted scalar"
        comment = tail.lstrip(YAML_SEPARATOR_SPACE)
        if comment and not comment.startswith("#"):
            return "trailing content after quoted scalar"
        return None

    if source.startswith('"'):
        end: int | None = None
        escaped = False
        for index in range(1, len(source)):
            character = source[index]
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                end = index
                break
        if end is None or escaped:
            return None, f"line {line_number}: unterminated double-quoted scalar"
        tail_error = validate_quoted_tail(source[end + 1 :])
        if tail_error is not None:
            return None, f"line {line_number}: {tail_error}"

        escape_values = {
            "0": "\0",
            "a": "\a",
            "b": "\b",
            "t": "\t",
            "n": "\n",
            "v": "\v",
            "f": "\f",
            "r": "\r",
            "e": "\x1b",
            " ": " ",
            '"': '"',
            "/": "/",
            "\\": "\\",
            "N": "\x85",
            "_": "\xa0",
            "L": "\u2028",
            "P": "\u2029",
        }
        decoded: list[str] = []
        index = 1
        while index < end:
            character = source[index]
            if character != "\\":
                decoded.append(character)
                index += 1
                continue
            index += 1
            if index >= end:
                return None, f"line {line_number}: invalid double-quoted scalar escape"
            escape = source[index]
            if escape in escape_values:
                decoded.append(escape_values[escape])
                index += 1
                continue
            if escape in {"x", "u", "U"}:
                width = {"x": 2, "u": 4, "U": 8}[escape]
                digits = source[index + 1 : index + 1 + width]
                if len(digits) != width or not re.fullmatch(r"[0-9a-fA-F]+", digits):
                    return None, f"line {line_number}: invalid double-quoted scalar escape"
                codepoint = int(digits, 16)
                try:
                    decoded.append(chr(codepoint))
                except ValueError:
                    return None, f"line {line_number}: invalid double-quoted scalar escape"
                index += width + 1
                continue
            return None, f"line {line_number}: invalid double-quoted scalar escape"
        return "".join(decoded), None

    if source.startswith("'"):
        end: int | None = None
        decoded: list[str] = []
        index = 1
        while index < len(source):
            character = source[index]
            if character != "'":
                decoded.append(character)
                index += 1
                continue
            if index + 1 < len(source) and source[index + 1] == "'":
                decoded.append("'")
                index += 2
                continue
            end = index
            break
        if end is None:
            return None, f"line {line_number}: unterminated single-quoted scalar"
        tail_error = validate_quoted_tail(source[end + 1 :])
        if tail_error is not None:
            return None, f"line {line_number}: {tail_error}"
        return "".join(decoded), None

    comment_index = next(
        (
            index
            for index, character in enumerate(source)
            if character == "#"
            and (index == 0 or source[index - 1] == YAML_SEPARATOR_SPACE)
        ),
        len(source),
    )
    plain = source[:comment_index].rstrip(YAML_SEPARATOR_SPACE)
    if not plain:
        return None, None
    if plain.startswith((",", "[", "]", "{", "}", "&", "*", "!", "|", ">", "@", "%", "`")):
        return None, f"line {line_number}: {INTERFACE_METADATA_SCALAR_ERROR}"
    if plain[0] in "-?:" and (
        len(plain) == 1 or plain[1] == YAML_SEPARATOR_SPACE
    ):
        return None, f"line {line_number}: {INTERFACE_METADATA_SCALAR_ERROR}"
    if re.search(r":[ \t]", plain):
        return None, f"line {line_number}: {INTERFACE_METADATA_SCALAR_ERROR}"
    if plain.lower() in {"null", "true", "false", "yes", "no", "on", "off", "~"}:
        return None, f"line {line_number}: {INTERFACE_METADATA_SCALAR_ERROR}"
    if plain.lower() in {".inf", "+.inf", "-.inf", ".nan"}:
        return None, f"line {line_number}: {INTERFACE_METADATA_SCALAR_ERROR}"
    if re.fullmatch(
        r"[-+]?(?:[0-9][0-9_]*(?:\.[0-9_]*)?|\.[0-9_]+)(?:[eE][-+]?[0-9]+)?",
        plain,
    ) or re.fullmatch(r"[-+]?0[xob][0-9a-fA-F_]+", plain, re.IGNORECASE):
        return None, f"line {line_number}: {INTERFACE_METADATA_SCALAR_ERROR}"
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[Tt ].*)?", plain):
        return None, f"line {line_number}: {INTERFACE_METADATA_SCALAR_ERROR}"
    return plain, None


def validate_skill_interface_metadata(text: str, skill_name: str) -> list[str]:
    """Validate required metadata as direct children of one interface mapping."""
    blocks: list[dict[str, tuple[str | None, int]]] = []
    current: dict[str, tuple[str | None, int]] | None = None
    for line_number, raw_line in enumerate(text.splitlines(), 1):
        leading = raw_line[: len(raw_line) - len(raw_line.lstrip(" \t"))]
        if "\t" in leading:
            return [f"line {line_number}: tabs are not allowed for interface indentation"]
        if "\t" in raw_line:
            return [f"line {line_number}: literal tabs are not supported in interface metadata"]
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        if indent == 0:
            if re.match(r"^interface\s*:", stripped):
                if stripped != "interface:":
                    return [f"line {line_number}: interface must be a root mapping"]
                blocks.append({})
                current = blocks[-1]
            else:
                current = None
            continue
        if current is None or indent != 2:
            continue
        key, separator, value = stripped.partition(":")
        if separator != ":":
            return [f"line {line_number}: invalid interface child"]
        key = key.strip()
        if value and not value.startswith(YAML_SEPARATOR_SPACE):
            return [
                f"line {line_number}: interface child {key!r} must use YAML separation space after ':'"
            ]
        if key in current:
            return [f"line {line_number}: duplicate interface child {key!r}"]
        parsed_value, scalar_error = parse_yaml_string_scalar(value, line_number)
        if scalar_error is not None:
            return [scalar_error]
        current[key] = (parsed_value, line_number)

    if len(blocks) != 1:
        return ["expected exactly one root interface mapping"]

    errors: list[str] = []
    fields = blocks[0]
    for key in ("display_name", "short_description"):
        if key not in fields or not fields[key][0]:
            errors.append(f"{key} is missing")
    default_prompt = fields.get("default_prompt")
    if default_prompt is None or not default_prompt[0]:
        errors.append("default_prompt is missing")
    elif f"${skill_name}" not in default_prompt[0]:
        errors.append(f"default_prompt must mention ${skill_name}")
    return errors


def check_skill_inventory(errors: list[str]) -> None:
    skills_dir = ROOT / ".agents" / "skills"
    if not skills_dir.is_dir():
        fail(errors, f"{skills_dir.relative_to(ROOT)}: skill directory is missing")
        return

    actual = {path.name for path in skills_dir.iterdir() if path.is_dir()}
    expected = set(EXPECTED_SKILL_INVOCATION_POLICY)
    for missing in sorted(expected - actual):
        fail(errors, f".agents/skills/{missing}: inventory entry is missing")
    for unexpected in sorted(actual - expected):
        fail(errors, f".agents/skills/{unexpected}: unregistered skill directory")

    for skill_name, allow_implicit in EXPECTED_SKILL_INVOCATION_POLICY.items():
        metadata_path = skills_dir / skill_name / "agents" / "openai.yaml"
        if not metadata_path.is_file():
            fail(errors, f"{metadata_path.relative_to(ROOT)}: metadata is missing")
            continue
        try:
            text = metadata_path.read_text()
        except OSError as error:
            fail(errors, f"{metadata_path.relative_to(ROOT)}: cannot read: {error}")
            continue
        for interface_error in validate_skill_interface_metadata(text, skill_name):
            fail(
                errors,
                f"{metadata_path.relative_to(ROOT)}: invalid interface metadata: {interface_error}",
            )
        value, policy_error = parse_skill_invocation_policy(text)
        if policy_error is not None:
            fail(
                errors,
                f"{metadata_path.relative_to(ROOT)}: invalid invocation policy: {policy_error}",
            )
        elif value != allow_implicit:
            fail(
                errors,
                f"{metadata_path.relative_to(ROOT)}: allow_implicit_invocation must be {str(allow_implicit).lower()}",
            )


def check_entries_and_assets(errors: list[str]) -> None:
    for skill_name in ("take-ticket", "prepare-backlog"):
        path = ROOT / ".agents" / "skills" / skill_name / "SKILL.md"
        values = parse_frontmatter(path, errors)
        if values.get("disable-model-invocation") != "true":
            fail(errors, f"{path.relative_to(ROOT)}: entry must be hidden from model invocation")
        try:
            text = path.read_text()
        except OSError:
            continue
        if "rpm_workflow_manager" not in text:
            fail(errors, f"{path.relative_to(ROOT)}: entry does not route to workflow manager")
        leaked = sorted(
            role
            for role in EXPECTED_SANDBOX
            if role != "rpm_workflow_manager" and role in text
        )
        if leaked:
            fail(
                errors,
                f"{path.relative_to(ROOT)}: entry duplicates internal routing: {', '.join(leaked)}",
            )
        if skill_name == "take-ticket":
            for required in ("scheduled", "at most", "no-work"):
                if required not in text:
                    fail(errors, f"{path.relative_to(ROOT)}: missing scheduled contract {required!r}")
        else:
            for required in ("research-cycle", "no-work"):
                if required not in text:
                    fail(errors, f"{path.relative_to(ROOT)}: missing research contract {required!r}")

    gatekeeper = ROOT / ".agents" / "skills" / "merge-gatekeeper" / "SKILL.md"
    values = parse_frontmatter(gatekeeper, errors)
    if values.get("disable-model-invocation") != "true":
        fail(errors, f"{gatekeeper.relative_to(ROOT)}: entry must be hidden from model invocation")
    try:
        text = gatekeeper.read_text()
    except OSError:
        text = ""
    if text:
        for required in (
            "no-work",
            "check-merge-gate.py",
            "At most one merge per run",
            "merge_gate",
        ):
            if required not in text:
                fail(errors, f"{gatekeeper.relative_to(ROOT)}: missing merge-gate contract {required!r}")
        leaked = sorted(role for role in EXPECTED_SANDBOX if role in text)
        if leaked:
            fail(
                errors,
                f"{gatekeeper.relative_to(ROOT)}: gatekeeper must not delegate to roles: {', '.join(leaked)}",
            )

    for relative in FORBIDDEN_ASSETS:
        path = ROOT / relative
        if path.is_file() or (path.is_dir() and any(item.is_file() for item in path.rglob("*"))):
            fail(errors, f"{relative}: retired workflow asset still exists")

    scan_paths = (
        ROOT / ".agents" / "skills",
        ROOT / ".codex" / "agents",
        ROOT / ".agents" / "docs",
    )
    for base in scan_paths:
        if not base.exists():
            continue
        for path in sorted(item for item in base.rglob("*") if item.is_file()):
            try:
                text = path.read_text()
            except (OSError, UnicodeDecodeError):
                continue
            for forbidden in FORBIDDEN_REFERENCES:
                if forbidden in text:
                    fail(
                        errors,
                        f"{path.relative_to(ROOT)}: retired workflow reference {forbidden!r}",
                    )


def check_deterministic_assets(errors: list[str]) -> None:
    required_files = (
        "scripts/backlog-gen",
        "scripts/check-agent-backlog-access.sh",
        "scripts/check-cloud-queue-contract.py",
        "scripts/check-merge-gate.py",
        "scripts/check-agent-issue-readiness.py",
        ".codex/hooks/agent_tool_policy.py",
        ".codex/hooks/issue_manager_stop_gate.py",
        ".codex/hooks.json",
    )
    for relative in required_files:
        if not (ROOT / relative).is_file():
            fail(errors, f"{relative}: required deterministic asset is missing")

    hooks_path = ROOT / ".codex" / "hooks.json"
    try:
        hooks = json.loads(hooks_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(errors, f"{hooks_path.relative_to(ROOT)}: invalid hook config: {error}")
        return
    pre_tool = hooks.get("hooks", {}).get("PreToolUse", [])
    serialized = json.dumps(pre_tool)
    for required in ("Agent", "apply_patch", "exec_command", "mcp__"):
        if required not in serialized:
            fail(errors, f"{hooks_path.relative_to(ROOT)}: PreToolUse misses {required!r}")
    stops = json.dumps(hooks.get("hooks", {}).get("SubagentStop", []))
    if "rpm_issue_manager" not in stops or "issue_manager_stop_gate.py" not in stops:
        fail(errors, f"{hooks_path.relative_to(ROOT)}: issue completion gate is missing")


def check_tool_policy_runtime(errors: list[str]) -> None:
    script = ROOT / ".codex" / "hooks" / "agent_tool_policy.py"
    transcript = f"/tmp/rpm-agent-policy-probe-{os.getpid()}"

    def run(payload: dict[str, object]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(script)],
            cwd=ROOT,
            input=json.dumps(payload),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def pre_tool(role: str, tool: str, tool_input: object) -> int:
        registered = run(
            {
                "hook_event_name": "SubagentStart",
                "agent_type": role,
                "agent_transcript_path": transcript,
            }
        )
        if registered.returncode != 0:
            fail(errors, f"agent tool policy could not register {role}: {registered.stderr}")
        return run(
            {
                "hook_event_name": "PreToolUse",
                "transcript_path": transcript,
                "cwd": str(ROOT),
                "tool_name": tool,
                "tool_input": tool_input,
            }
        ).returncode

    cases = (
        ("leaf-spawn", "rpm_issue_researcher", "spawn_agent", {}, 2),
        ("manager-spawn", "rpm_backlog_manager", "Agent", {}, 0),
        (
            "spec-patch",
            "rpm_spec_updater",
            "apply_patch",
            "*** Begin Patch\n*** Update File: docs/specs/core/manifest/SPEC.md\n*** End Patch\n",
            0,
        ),
        (
            "reviewer-patch",
            "rpm_adversarial_reviewer",
            "apply_patch",
            "*** Begin Patch\n*** Update File: src/main.rs\n*** End Patch\n",
            2,
        ),
        ("scout-read", "rpm_backlog_scout", "mcp__github__get_issue", {}, 0),
        (
            "researcher-mutate",
            "rpm_issue_researcher",
            "mcp__github__update_issue",
            {"issue_number": 1, "body": "changed"},
            2,
        ),
        (
            "creator-create",
            "rpm_idea_issue_creator",
            "mcp__github__create_issue",
            {"title": "idea", "body": "body"},
            0,
        ),
        (
            "refiner-project",
            "rpm_issue_refiner",
            "mcp__github__update_project_item",
            {"item": "x"},
            2,
        ),
        (
            "claimer-labels",
            "rpm_ready_ticket_claimer",
            "mcp__github__update_issue",
            {"labels": ["agent:claimed"]},
            0,
        ),
        (
            "claimer-body",
            "rpm_ready_ticket_claimer",
            "mcp__github__update_issue",
            {"body": "changed"},
            2,
        ),
        (
            "codex-review",
            "rpm_idea_issue_creator",
            "exec_command",
            {"cmd": 'gh pr comment 1 --body "@codex review"'},
            2,
        ),
        (
            "merge",
            "rpm_issue_refiner",
            "Bash",
            {"command": "gh pr merge 1 --squash"},
            2,
        ),
        (
            "manager-issue-mutation",
            "rpm_backlog_manager",
            "exec_command",
            {"cmd": "gh issue create --title x --body y"},
            2,
        ),
        (
            "review-resolver-merge",
            "pr-review-resolver",
            "exec_command",
            {"cmd": "gh pr merge 1 --squash"},
            2,
        ),
    )
    for name, role, tool, tool_input, expected in cases:
        actual = pre_tool(role, tool, tool_input)
        if actual != expected:
            fail(errors, f"tool policy probe {name} expected exit {expected}, got {actual}")
    run(
        {
            "hook_event_name": "SubagentStop",
            "agent_type": "rpm_workflow_manager",
            "agent_transcript_path": transcript,
        }
    )


def main() -> int:
    errors: list[str] = []
    if not AGENTS_DIR.is_dir():
        print(f"missing agent directory: {AGENTS_DIR}", file=sys.stderr)
        return 2
    agents = load_agents(errors)
    check_policy(errors)
    check_role_contracts(agents, errors)
    check_skill_inventory(errors)
    check_entries_and_assets(errors)
    check_deterministic_assets(errors)
    check_tool_policy_runtime(errors)
    if errors:
        for error in errors:
            print(f"agent_organization.error={error}", file=sys.stderr)
        return 1
    print(
        "agent_organization.status=ok "
        f"agents={len(agents)} rpm_roles={len(EXPECTED_SANDBOX)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
