#!/usr/bin/env python3
"""Validate the project-scoped RPM agent organization and workflow policy."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tomllib
import unicodedata
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
AGENTS_DIR = ROOT / ".codex" / "agents"
POLICY_PATH = ROOT / ".agents" / "workflows" / "backlog-policy.json"

MANAGER_REPORTS = {
    "rpm_workflow_manager": {
        "rpm_backlog_manager",
        "rpm_existing_pr_adopter",
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
    "rpm_existing_pr_adopter": "read-only",
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
EXPECTED_ADOPTION_CONTRACT = {
    "operation": "adopt-existing-pr",
    "operation_version": 1,
    "owner": "rpm_existing_pr_adopter",
    "from_state": "untracked",
    "to_state": "review-pending",
    "batch_limit": 1,
    "required_checks": ["metadata", "verify"],
    "approved_plus_one_actors": ["chatgpt-codex-connector"],
    "canonical_array_order": {
        "authorization.closing_issues": ["repository", "number"],
        "evidence.issue.labels": ["$value"],
        "evidence.issue.closing_prs": ["$value"],
        "evidence.pr.closing_issues": ["repository", "number"],
        "evidence.checks.records": ["name", "workflow_run_id"],
        "evidence.review.automatic_reviews.records": [
            "submitted_at",
            "actor",
            "reviewed_head_sha",
        ],
        "evidence.review.reactions.records": ["created_at", "actor", "content"],
        "evidence.findings.items": ["severity", "id"],
        "evidence.writers.records": [
            "kind",
            "repository",
            "issue",
            "pr",
            "run_id",
        ],
        "evidence.dependent_prs.records": ["number"],
    },
    "p2_terminal_dispositions": [
        "already-addressed",
        "defer-follow-up",
        "residual-risk",
        "reject-out-of-scope",
    ],
    "writer_inventory": {
        "source": "repository-global-writer-inventory-v1",
        "lease_ttl_seconds": 3600,
        "adoption_acquisition_order": "source-comment-id-ascending",
        "kinds": ["claim", "implementation", "review-resolution", "adoption"],
    },
    "dependent_pr_inventory": {
        "source": "repository-open-pr-base-inventory-v1"
    },
    "ledger": {
        "namespace": "rpm-agent-adoption",
        "marker": "<!-- rpm-agent-adoption:v1 -->",
        "approved_authors": ["nerdchanii"],
        "phases": ["prepared", "label-mutation", "committed", "reconciled"],
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
    if policy.get("version") != 4:
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: version must be 4")
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
    if policy.get("existing_pr_adoption") != EXPECTED_ADOPTION_CONTRACT:
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: invalid existing PR adoption contract")
    if policy.get("batch_limits") != {"research": 1, "execution": 1}:
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: both batch limits must equal 1")
    if policy.get("allowed_transitions") != EXPECTED_TRANSITIONS:
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: transition allowlist changed")
    lifecycle_contract = policy.get("lifecycle_contract")
    expected_edges = {
        f"{source}->{target}"
        for source, targets in EXPECTED_TRANSITIONS.items()
        for target in targets
    }
    if not isinstance(lifecycle_contract, dict):
        fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: lifecycle contract is missing")
    else:
        if lifecycle_contract.get("initial_states") != ["untracked", "research", "ready"]:
            fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: invalid lifecycle initial states")
        if lifecycle_contract.get("safe_stop_states") != ["awaiting-merge", "blocked"]:
            fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: invalid lifecycle safe stops")
        if lifecycle_contract.get("external_terminal_states") != ["closed"]:
            fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: invalid lifecycle terminal states")
        edge_fixtures = lifecycle_contract.get("edge_fixtures")
        if not isinstance(edge_fixtures, dict) or set(edge_fixtures) != expected_edges:
            fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: lifecycle edge fixtures are incomplete")
        elif any(
            not isinstance(descriptor, dict)
            or descriptor.get("case") != edge
            or descriptor.get("path")
            != "tests/fixtures/agent-workflow/lifecycle-edges.json"
            or not (ROOT / str(descriptor.get("path"))).is_file()
            for edge, descriptor in edge_fixtures.items()
        ):
            fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: lifecycle edge fixture is missing")
        if lifecycle_contract.get("operation_fixtures") != {
            "adopt-existing-pr": "adopt-existing-pr"
        }:
            fail(errors, f"{POLICY_PATH.relative_to(ROOT)}: adoption fixture binding changed")
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


def parse_frontmatter(path: Path, errors: list[str]) -> dict[str, str | bool]:
    """Read the root fields needed by the repository policy.

    Root ``description`` is required and must be a non-empty string.
    Its supported string forms include the YAML literal and folded block
    scalar subset parsed by ``parse_frontmatter_block_scalar``. Other root
    fields remain single-line scalar values.
    The supported forms are an empty ``metadata:`` block, an empty
    ``metadata: {}`` flow mapping, or a block mapping with one direct,
    non-empty ``short-description`` string child.  We keep that child out of
    the root identity map, so a nested ``name`` can never satisfy the
    inventory check.
    """
    try:
        text = path.read_bytes().decode("utf-8")
    except UnicodeDecodeError as error:
        fail(errors, f"{path.relative_to(ROOT)}: frontmatter is not valid UTF-8: {error}")
        return {}
    except OSError as error:
        fail(errors, f"{path.relative_to(ROOT)}: cannot read: {error}")
        return {}
    # Accept CRLF as a line ending at the file boundary. A remaining carriage
    # return is a bare or malformed CR and stays covered by the control check
    # below, so scalar content cannot silently acquire a different newline.
    text = text.replace("\r\n", "\n")
    if not text.startswith("---\n"):
        fail(errors, f"{path.relative_to(ROOT)}: missing frontmatter")
        return {}
    lines = text.split("\n")
    try:
        closing_line = lines.index("---", 1)
    except ValueError:
        fail(errors, f"{path.relative_to(ROOT)}: unterminated frontmatter")
        return {}
    frontmatter_lines = lines[1:closing_line]
    frontmatter_source = "\n".join(frontmatter_lines)
    if (
        "\r" in frontmatter_source
        or contains_yaml_surrogate(frontmatter_source)
        or contains_unsupported_yaml_structure_separator(frontmatter_source)
        or contains_literal_yaml_control(frontmatter_source)
        or contains_unsupported_yaml_line_separator(frontmatter_source)
    ):
        fail(
            errors,
            f"{path.relative_to(ROOT)}: frontmatter contains an unsupported control "
            "or line separator",
        )
        return {}
    values: dict[str, str | bool] = {}
    root_keys: set[str] = set()
    description_seen = False
    active_nested_mapping: str | None = None
    metadata_flow_mapping = False
    metadata_keys: set[str] = set()
    skip_until = 0
    for line_index, line in enumerate(frontmatter_lines):
        if line_index < skip_until:
            continue
        line_number = line_index + 2
        leading_whitespace = line[: len(line) - len(line.lstrip())]
        if any(character != YAML_SEPARATOR_SPACE for character in leading_whitespace):
            fail(
                errors,
                f"{path.relative_to(ROOT)}: line {line_number}: "
                "frontmatter indentation must use ASCII spaces",
            )
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent != 0:
            if metadata_flow_mapping:
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: line {line_number}: "
                    "metadata flow mapping cannot contain indented children",
                )
                continue
            if active_nested_mapping != "metadata":
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: line {line_number}: "
                    "nested frontmatter fields are not supported",
                )
                continue
            if indent != 2:
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: line {line_number}: "
                    "metadata descendants must be direct children at two-space indentation",
                )
                continue
            key, separator, value = stripped.partition(":")
            if separator != ":" or re.fullmatch(r"[a-z][a-z0-9-]*", key) is None:
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: line {line_number}: invalid metadata field",
                )
                continue
            if value and not value.startswith(YAML_SEPARATOR_SPACE):
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: line {line_number}: "
                    f"metadata field {key!r} must use YAML separation space after ':'",
                )
                continue
            if key not in FRONTMATTER_METADATA_KEYS:
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: line {line_number}: "
                    f"unsupported metadata field {key!r}",
                )
                continue
            if key in metadata_keys:
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: line {line_number}: "
                    f"duplicate metadata field {key!r}",
                )
                continue
            metadata_keys.add(key)
            if value.strip(YAML_SEPARATOR_SPACE).startswith("#"):
                parsed_value, scalar_error = None, None
            else:
                parsed_value, scalar_error = parse_yaml_string_scalar(value, line_number)
            if scalar_error is not None:
                if INTERFACE_METADATA_SCALAR_ERROR in scalar_error:
                    fail(
                        errors,
                        f"{path.relative_to(ROOT)}: line {line_number}: "
                        f"{FRONTMATTER_METADATA_VALUE_ERROR}",
                    )
                else:
                    fail(errors, f"{path.relative_to(ROOT)}: {scalar_error}")
                continue
            if parsed_value is None or not parsed_value.strip():
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: line {line_number}: "
                    f"{FRONTMATTER_METADATA_VALUE_ERROR}",
                )
            continue

        active_nested_mapping = None
        metadata_flow_mapping = False
        key, separator, value = line.partition(":")
        if separator != ":" or re.fullmatch(r"[a-z][a-z0-9-]*", key) is None:
            fail(
                errors,
                f"{path.relative_to(ROOT)}: line {line_number}: invalid root frontmatter field",
            )
            continue
        if value and not value.startswith(YAML_SEPARATOR_SPACE):
            fail(
                errors,
                f"{path.relative_to(ROOT)}: line {line_number}: "
                f"frontmatter field {key!r} must use YAML separation space after ':'",
            )
            continue
        if key not in FRONTMATTER_ROOT_KEYS:
            fail(
                errors,
                f"{path.relative_to(ROOT)}: line {line_number}: "
                f"unsupported root frontmatter field {key!r}",
            )
            continue
        if key == "metadata":
            mapping_value = strip_ascii_space_inline_comment(value)
            if mapping_value not in {"", "{}"}:
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: line {line_number}: "
                    f"{FRONTMATTER_METADATA_SHAPE_ERROR}",
                )
                continue
            if key in root_keys:
                fail(errors, f"{path.relative_to(ROOT)}: duplicate root frontmatter field 'metadata'")
                continue
            root_keys.add(key)
            metadata_flow_mapping = mapping_value == "{}"
            active_nested_mapping = None if metadata_flow_mapping else key
            metadata_keys.clear()
            continue
        if key == "description":
            description_seen = True
        block_header = parse_frontmatter_block_header(value, line_number)
        if key == "description" and block_header is not None:
            if isinstance(block_header, str):
                fail(errors, f"{path.relative_to(ROOT)}: {block_header}")
                skip_until = line_index + 1
                while skip_until < len(frontmatter_lines):
                    candidate = frontmatter_lines[skip_until]
                    if candidate.strip(YAML_SEPARATOR_SPACE) == "":
                        skip_until += 1
                        continue
                    candidate_indent = len(candidate) - len(
                        candidate.lstrip(YAML_SEPARATOR_SPACE)
                    )
                    if candidate_indent == 0:
                        break
                    skip_until += 1
                continue
            parsed_value, skip_until, scalar_error = parse_frontmatter_block_scalar(
                frontmatter_lines,
                line_index,
                block_header,
            )
        else:
            parsed_value, scalar_error = parse_frontmatter_scalar(value, line_number)
        if scalar_error is not None:
            if key in FRONTMATTER_NON_EMPTY_STRING_KEYS:
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: line {line_number}: "
                    f"frontmatter field {key!r} must be a non-empty string",
                )
            else:
                fail(errors, f"{path.relative_to(ROOT)}: {scalar_error}")
            continue
        if key == "description" and (
            not isinstance(parsed_value, str) or not parsed_value.strip()
        ):
            fail(
                errors,
                f"{path.relative_to(ROOT)}: line {line_number}: "
                "frontmatter description must be a non-empty string",
            )
            continue
        if key == "description":
            description = parsed_value.strip()
            if description.startswith("[TODO:"):
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: line {line_number}: "
                    "frontmatter description contains an unfinished TODO placeholder",
                )
                continue
            if "<" in description or ">" in description:
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: line {line_number}: "
                    "frontmatter description cannot contain angle brackets (< or >)",
                )
                continue
            if len(description) > 1024:
                fail(
                    errors,
                    f"{path.relative_to(ROOT)}: line {line_number}: "
                    f"frontmatter description is too long ({len(description)} characters). "
                    "Maximum is 1024 characters.",
                )
                continue
        if key in FRONTMATTER_NON_EMPTY_STRING_KEYS and (
            not isinstance(parsed_value, str) or not parsed_value.strip()
        ):
            fail(
                errors,
                f"{path.relative_to(ROOT)}: line {line_number}: "
                f"frontmatter field {key!r} must be a non-empty string",
            )
            continue
        if key == "disable-model-invocation" and not isinstance(parsed_value, bool):
            fail(
                errors,
                f"{path.relative_to(ROOT)}: line {line_number}: "
                "disable-model-invocation must be boolean",
            )
            continue
        if key in root_keys:
            if key == "name":
                message = "expected exactly one root frontmatter name"
            else:
                message = f"duplicate root frontmatter field {key!r}"
            fail(errors, f"{path.relative_to(ROOT)}: {message}")
            continue
        root_keys.add(key)
        if parsed_value is not None:
            values[key] = parsed_value
    if not description_seen:
        fail(errors, f"{path.relative_to(ROOT)}: frontmatter description is missing")
    return values


YAML_SEPARATOR_SPACE = " "
FRONTMATTER_METADATA_KEYS = frozenset(("short-description",))
# Hidden entry guards are repository-local extensions validated here.
FRONTMATTER_ROOT_KEYS = frozenset((
    "name",
    "description",
    "license",
    "allowed-tools",
    "metadata",
    "argument-hint",
    "disable-model-invocation",
))
FRONTMATTER_NON_EMPTY_STRING_KEYS = frozenset((
    "license",
    "argument-hint",
    "allowed-tools",
))
FRONTMATTER_METADATA_VALUE_ERROR = (
    "metadata field 'short-description' must be a non-empty string"
)
FRONTMATTER_METADATA_SHAPE_ERROR = (
    "metadata must be an empty flow mapping or a block mapping"
)
YAML_DOCUMENT_MARKER_ERROR = "YAML document markers are not supported in openai.yaml"
YAML_ROOT_MAPPING_ERROR = "root-level YAML nodes must be supported mappings"
YAML_UNSUPPORTED_ROOT_MAPPING_ERROR = (
    "only interface, dependencies, and policy root mappings are supported"
)
YAML_SUPPORTED_ROOT_MAPPING_KEYS = frozenset(("interface", "dependencies", "policy"))
YAML_UNSUPPORTED_LINE_SEPARATOR_ERROR = (
    "U+0085, U+2028, and U+2029 are not supported in openai.yaml"
)
YAML_UNSUPPORTED_LINE_SEPARATORS = frozenset(("\u0085", "\u2028", "\u2029"))
YAML_UNSUPPORTED_STRUCTURE_SEPARATOR_ERROR = (
    "U+000B, U+000C, U+001C, U+001D, and U+001E are not supported "
    "as YAML line separators in openai.yaml"
)
YAML_UNSUPPORTED_STRUCTURE_SEPARATORS = frozenset(
    ("\u000B", "\u000C", "\u001C", "\u001D", "\u001E")
)
YAML_LITERAL_CONTROL_ERROR = (
    "literal C0 and DEL control characters are not allowed in openai.yaml; "
    "C1 controls and YAML noncharacters are also forbidden"
)
YAML_SURROGATE_ERROR = "surrogate Unicode code points are not allowed in YAML scalars"
YAML_DEPENDENCY_ERROR = "dependencies.tools must be a sequence of supported tool mappings"
YAML_DEPENDENCY_TOOL_KEYS = frozenset(("type", "value", "description", "transport", "url"))
YAML_DEPENDENCY_TOOL_TYPE = "mcp"
YAML_TOKEN_ASCII_CONTINUATIONS = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
)
YAML_TOKEN_UNICODE_CONTINUATION_CATEGORIES = frozenset(
    (
        "Ll",
        "Lm",
        "Lo",
        "Lt",
        "Lu",
        "Mc",
        "Me",
        "Mn",
        "Nd",
        "Nl",
        "No",
        "Cf",
    )
)
YAML_TOKEN_EXPLICIT_CONTINUATIONS = frozenset((0x200C, 0x200D))


def contains_unsupported_yaml_line_separator(text: str) -> bool:
    return any(character in text for character in YAML_UNSUPPORTED_LINE_SEPARATORS)


def contains_unsupported_yaml_structure_separator(text: str) -> bool:
    return any(character in text for character in YAML_UNSUPPORTED_STRUCTURE_SEPARATORS)


def contains_literal_yaml_control(text: str) -> bool:
    return any(
        (ord(character) <= 0x1F and character not in "\t\r\n")
        or ord(character) == 0x7F
        or 0x80 <= ord(character) <= 0x84
        or 0x86 <= ord(character) <= 0x9F
        or ord(character) in {0xFFFE, 0xFFFF}
        for character in text
    )


def contains_yaml_surrogate(text: str) -> bool:
    return any(0xD800 <= ord(character) <= 0xDFFF for character in text)


def is_supported_root_mapping_line(stripped: str) -> bool:
    key, separator, value = stripped.partition(":")
    return bool(
        separator
        and re.fullmatch(r"[a-z][a-z0-9-]*", key) is not None
        and (not value or value.startswith(YAML_SEPARATOR_SPACE))
    )


def supported_root_mapping_key(stripped: str) -> str | None:
    if not is_supported_root_mapping_line(stripped):
        return None
    return stripped.partition(":")[0]


def is_supported_root_mapping_header(stripped: str, key: str) -> bool:
    """Accept an empty root mapping value or an ASCII-space comment suffix."""
    prefix = f"{key}:"
    if stripped == prefix:
        return True
    if not stripped.startswith(prefix):
        return False
    suffix = stripped[len(prefix) :]
    return suffix.startswith(YAML_SEPARATOR_SPACE) and suffix.lstrip(
        YAML_SEPARATOR_SPACE
    ).startswith("#")


def strip_ascii_space_inline_comment(value: str) -> str:
    """Remove a comment only when ``#`` has an ASCII space immediately before it."""
    comment_index = next(
        (
            index
            for index, character in enumerate(value)
            if character == "#" and index > 0 and value[index - 1] == YAML_SEPARATOR_SPACE
        ),
        len(value),
    )
    return value[:comment_index].strip(YAML_SEPARATOR_SPACE)


def is_skill_token_continuation(character: str) -> bool:
    r"""Apply the explicit skill-token boundary contract without regex ``\w``."""
    if not character:
        return False
    if character in YAML_TOKEN_ASCII_CONTINUATIONS:
        return True
    codepoint = ord(character)
    if (
        codepoint in YAML_TOKEN_EXPLICIT_CONTINUATIONS
        or 0xFE00 <= codepoint <= 0xFE0F
        or 0xE0100 <= codepoint <= 0xE01EF
    ):
        return True
    return unicodedata.category(character) in YAML_TOKEN_UNICODE_CONTINUATION_CATEGORIES


def has_complete_skill_token(value: str, skill_name: str) -> bool:
    """Require a boundary on both sides of at least one exact skill token."""
    token = f"${skill_name}"
    search_start = 0
    while True:
        index = value.find(token, search_start)
        if index < 0:
            return False
        token_end = index + len(token)
        before = value[index - 1] if index else ""
        after = value[token_end] if token_end < len(value) else ""
        if not is_skill_token_continuation(before) and not is_skill_token_continuation(after):
            return True
        search_start = index + 1


def is_yaml_document_marker(stripped: str) -> bool:
    stripped = stripped.removeprefix("\ufeff")
    return any(
        stripped == marker
        or stripped.startswith(f"{marker} ")
        or stripped.startswith(f"{marker}\t")
        for marker in ("---", "...")
    )


def parse_dependency_tool_field(
    stripped: str, line_number: int, keys: set[str]
) -> str | None:
    key, separator, value = stripped.partition(":")
    if separator != ":" or key not in YAML_DEPENDENCY_TOOL_KEYS:
        return f"line {line_number}: {YAML_DEPENDENCY_ERROR}"
    if value and not value.startswith(YAML_SEPARATOR_SPACE):
        return (
            f"line {line_number}: dependency tool field {key!r} must use "
            "YAML separation space after ':'"
        )
    parsed_value, scalar_error = parse_yaml_string_scalar(value, line_number)
    if scalar_error is not None:
        return scalar_error
    if parsed_value is None:
        return f"line {line_number}: dependency tool field {key!r} must be a string"
    if key == "type" and parsed_value != YAML_DEPENDENCY_TOOL_TYPE:
        return (
            f"line {line_number}: dependency tool type must be "
            f"{YAML_DEPENDENCY_TOOL_TYPE!r}"
        )
    if key == "value" and not parsed_value.strip():
        return f"line {line_number}: dependency tool field 'value' must be a non-empty string"
    if key in keys:
        return f"line {line_number}: duplicate dependency tool field {key!r}"
    keys.add(key)
    return None


def validate_supported_dependencies(text: str) -> str | None:
    """Validate the dependency shape supported by Codex's ``openai.yaml`` loader.

    The installed OpenAI schema supports ``type: mcp`` and a non-empty string
    ``value``, with optional ``description``, ``transport``, and ``url``
    strings.  This validator intentionally accepts only ``tools: []`` or the
    block sequence form with four-space items and six-space child fields (the
    first field may follow ``-`` on the same line).  Flow sequences and inline
    mapping forms remain unsupported.  A narrow structural check keeps this
    repository validator aligned with that contract while allowing the other
    root mappings to be validated by their dedicated checks.
    """
    if text.startswith("\ufeff"):
        text = text[1:]

    active_root: str | None = None
    dependencies_seen = False
    tools_seen = False
    tools_mode: str | None = None
    tools_items_seen = False
    tool_keys: set[str] | None = None

    def finish_tool(line_number: int) -> str | None:
        if tool_keys is None:
            return None
        if not {"type", "value"}.issubset(tool_keys):
            return f"line {line_number}: dependency tool requires type and value"
        return None

    def finish_tools(line_number: int) -> str | None:
        if tools_mode == "sequence" and not tools_items_seen:
            return f"line {line_number}: {YAML_DEPENDENCY_ERROR}"
        return finish_tool(line_number)

    for line_number, raw_line in enumerate(text.splitlines(), 1):
        leading = raw_line[: len(raw_line) - len(raw_line.lstrip(" \t"))]
        if "\t" in leading:
            return f"line {line_number}: tabs are not allowed for dependency indentation"
        stripped = raw_line.strip(" \t")
        if not stripped or stripped.startswith("#"):
            continue
        if "\t" in raw_line and active_root == "dependencies":
            return f"line {line_number}: literal tabs are not supported in dependencies"
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        if indent == 0:
            if tool_error := finish_tools(line_number):
                return tool_error
            tool_keys = None
            if not is_supported_root_mapping_line(stripped):
                active_root = None
                continue
            root_key = supported_root_mapping_key(stripped)
            active_root = root_key
            if root_key != "dependencies":
                continue
            if not is_supported_root_mapping_header(stripped, "dependencies"):
                return f"line {line_number}: dependencies must be a root mapping"
            if dependencies_seen:
                return f"line {line_number}: duplicate root dependencies mapping"
            dependencies_seen = True
            tools_seen = False
            tools_mode = None
            tools_items_seen = False
            continue

        if active_root != "dependencies":
            continue
        if indent == 2:
            if tool_error := finish_tools(line_number):
                return tool_error
            tool_keys = None
            key, separator, value = stripped.partition(":")
            if separator != ":" or key != "tools":
                return f"line {line_number}: {YAML_DEPENDENCY_ERROR}"
            if tools_seen:
                return f"line {line_number}: duplicate dependencies.tools mapping"
            if value and not value.startswith(YAML_SEPARATOR_SPACE):
                return f"line {line_number}: dependencies.tools must use YAML separation space after ':'"
            tools_seen = True
            tools_value = strip_ascii_space_inline_comment(value)
            if tools_value == "[]":
                tools_mode = "empty"
            elif tools_value:
                return f"line {line_number}: {YAML_DEPENDENCY_ERROR}"
            else:
                tools_mode = "sequence"
            continue
        if not tools_seen or tools_mode == "empty":
            return f"line {line_number}: {YAML_DEPENDENCY_ERROR}"
        if indent == 4:
            if tool_error := finish_tool(line_number):
                return tool_error
            tool_keys = None
            if stripped == "-":
                tools_items_seen = True
                tool_keys = set()
                continue
            if not stripped.startswith("- "):
                return f"line {line_number}: {YAML_DEPENDENCY_ERROR}"
            tools_items_seen = True
            tool_keys = set()
            inline_field = stripped[2:].strip()
            if inline_field and not inline_field.startswith("#"):
                if field_error := parse_dependency_tool_field(
                    inline_field, line_number, tool_keys
                ):
                    return field_error
            continue
        if indent == 6 and tool_keys is not None:
            if field_error := parse_dependency_tool_field(stripped, line_number, tool_keys):
                return field_error
            continue
        return f"line {line_number}: {YAML_DEPENDENCY_ERROR}"

    return finish_tools(len(text.splitlines()) + 1)


def parse_skill_invocation_policy(text: str) -> tuple[bool | None, str | None]:
    """Parse the deliberately small policy mapping in an openai.yaml file.

    A full YAML dependency is unnecessary here. The supported policy shape is
    intentionally strict: one root ``policy:`` mapping with one direct child,
    alongside the optional ``interface:`` and ``dependencies:`` mappings. Every
    non-comment root line must use one of the supported mapping keys.
    """
    if contains_yaml_surrogate(text):
        return None, YAML_SURROGATE_ERROR
    if contains_unsupported_yaml_structure_separator(text):
        return None, YAML_UNSUPPORTED_STRUCTURE_SEPARATOR_ERROR
    if contains_literal_yaml_control(text):
        return None, YAML_LITERAL_CONTROL_ERROR
    if contains_unsupported_yaml_line_separator(text):
        return None, YAML_UNSUPPORTED_LINE_SEPARATOR_ERROR
    if text.startswith("\ufeff"):
        text = text[1:]
    if dependency_error := validate_supported_dependencies(text):
        return None, dependency_error

    blocks: list[list[tuple[int, str, int]]] = []
    current: list[tuple[int, str, int]] | None = None
    active_root: str | None = None
    for line_number, raw_line in enumerate(text.splitlines(), 1):
        leading = raw_line[: len(raw_line) - len(raw_line.lstrip(" \t"))]
        if "\t" in leading:
            return None, f"line {line_number}: tabs are not allowed for policy indentation"
        stripped = raw_line.strip(" \t")
        if not stripped or stripped.startswith("#"):
            continue
        if is_yaml_document_marker(stripped):
            return None, f"line {line_number}: {YAML_DOCUMENT_MARKER_ERROR}"
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        if indent == 0:
            if not is_supported_root_mapping_line(stripped):
                return None, f"line {line_number}: {YAML_ROOT_MAPPING_ERROR}"
            root_key = supported_root_mapping_key(stripped)
            if root_key not in YAML_SUPPORTED_ROOT_MAPPING_KEYS:
                return None, f"line {line_number}: {YAML_UNSUPPORTED_ROOT_MAPPING_ERROR}"
            if not is_supported_root_mapping_header(stripped, root_key):
                return None, f"line {line_number}: {root_key} must be a root mapping"
            active_root = root_key
            if root_key == "policy":
                blocks.append([])
                current = blocks[-1]
            else:
                current = None
            continue
        if active_root is None:
            return None, f"line {line_number}: {YAML_ROOT_MAPPING_ERROR}"
        if active_root == "dependencies":
            continue
        if indent != 2:
            return None, (
                f"line {line_number}: {active_root} descendants must be direct children "
                "at two-space indentation"
            )
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
    if separator != ":" or key != "allow_implicit_invocation":
        return None, f"line {line_number}: unexpected policy child"
    if value and not value.startswith(YAML_SEPARATOR_SPACE):
        return None, (
            f"line {line_number}: policy child {key!r} must use "
            "YAML separation space after ':'"
        )
    boolean_value = strip_ascii_space_inline_comment(value)
    if boolean_value not in {"true", "false"}:
        return None, f"line {line_number}: allow_implicit_invocation must be boolean"
    return boolean_value == "true", None


INTERFACE_METADATA_SCALAR_ERROR = (
    "interface metadata must be a non-empty YAML string scalar "
    "(plain scalars cannot start with YAML indicators such as - ? : , @ % or `; "
    "ASCII space is the only separator, literal tabs are rejected, and "
    "single/double quotes with separation-space comments are supported)"
)
INTERFACE_METADATA_KEYS = frozenset((
    "display_name",
    "short_description",
    "icon_small",
    "icon_large",
    "brand_color",
    "default_prompt",
))
INTERFACE_ICON_KEYS = frozenset(("icon_small", "icon_large"))
INTERFACE_BRAND_COLOR_RE = re.compile(r"^#[0-9A-F]{6}$", re.IGNORECASE)
WINDOWS_DRIVE_PATH_RE = re.compile(r"^[A-Za-z]:")
LITERAL_SCALAR_CONTROL_ERROR = (
    "literal C0 and DEL control characters are not allowed in interface metadata scalars; "
    "C1 controls and YAML noncharacters are also forbidden"
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
    if contains_yaml_surrogate(value):
        return None, f"line {line_number}: {YAML_SURROGATE_ERROR}"
    if contains_unsupported_yaml_line_separator(value):
        return None, f"line {line_number}: {YAML_UNSUPPORTED_LINE_SEPARATOR_ERROR}"
    source = value.strip(YAML_SEPARATOR_SPACE)
    if not source:
        return None, None
    # The control-character contract is for literal source characters; valid
    # double-quoted escape sequences are decoded below.
    if any(
        (ord(character) <= 0x1F)
        or ord(character) == 0x7F
        or 0x80 <= ord(character) <= 0x84
        or 0x86 <= ord(character) <= 0x9F
        or ord(character) in {0xFFFE, 0xFFFF}
        for character in source
    ):
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
        decoded_value = "".join(decoded)
        if contains_yaml_surrogate(decoded_value):
            return None, f"line {line_number}: {YAML_SURROGATE_ERROR}"
        if contains_unsupported_yaml_line_separator(decoded_value):
            return None, f"line {line_number}: {YAML_UNSUPPORTED_LINE_SEPARATOR_ERROR}"
        return decoded_value, None

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
    if re.search(r":(?:[ \t]|$)", plain):
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


def parse_frontmatter_scalar(
    value: str, line_number: int
) -> tuple[str | bool | None, str | None]:
    """Parse a scalar in the supported SKILL.md frontmatter subset."""
    stripped = strip_ascii_space_inline_comment(value).strip(YAML_SEPARATOR_SPACE)
    if stripped in {"true", "false"}:
        return stripped == "true", None
    parsed, error = parse_yaml_string_scalar(value, line_number)
    if error is not None:
        return None, error.replace("interface metadata", "frontmatter")
    if parsed is None:
        return None, f"line {line_number}: frontmatter values must be non-empty scalars"
    return parsed, None


FRONTMATTER_BLOCK_SCALAR_HEADER_ERROR = (
    "frontmatter description block scalar header must use '|' or '>' with "
    "optional one-digit indentation and '-' or '+' chomping indicators"
)
FRONTMATTER_BLOCK_SCALAR_INDENTATION_ERROR = (
    "frontmatter description block scalar content must be indented consistently"
)


def parse_frontmatter_block_header(
    value: str, line_number: int
) -> tuple[str, int | None, str] | str | None:
    """Parse the supported root-description block-scalar header subset.

    The boundary is intentionally explicit: ``|`` and ``>`` are accepted with
    an optional one-digit indentation indicator, an optional ``-`` or ``+``
    chomping indicator in either order, and an optional ASCII-space comment.
    Tabs are accepted in comment text and after the required content
    indentation; structural header and indentation tabs remain unsupported.
    Collections and block scalars on other frontmatter fields remain outside
    this parser contract.
    """
    source = value.strip(YAML_SEPARATOR_SPACE)
    if not source.startswith(("|", ">")):
        return None
    match = re.fullmatch(
        r"(?P<style>[|>])(?P<indicators>(?:[1-9][+-]?|[+-][1-9]?)?)(?: +#.*)?",
        source,
    )
    if match is None:
        return f"line {line_number}: {FRONTMATTER_BLOCK_SCALAR_HEADER_ERROR}"
    comment_index = source.find("#")
    structural_header = source if comment_index < 0 else source[:comment_index]
    if "\t" in structural_header:
        return f"line {line_number}: {FRONTMATTER_BLOCK_SCALAR_HEADER_ERROR}"
    indicators = match.group("indicators")
    indent_indicator = next(
        (int(character) for character in indicators if character.isdigit()),
        None,
    )
    chomping = next(
        (character for character in indicators if character in "+-"),
        "",
    )
    return match.group("style"), indent_indicator, chomping


def fold_frontmatter_block_lines(
    payloads: list[str], more_indented: list[bool]
) -> str:
    """Fold base-indented lines while preserving blank and indented breaks."""
    if not payloads:
        return ""
    folded: list[str] = [payloads[0]]
    for index in range(len(payloads) - 1):
        current = payloads[index]
        following = payloads[index + 1]
        if more_indented[index] or more_indented[index + 1]:
            separator = "\n"
        elif current == "" and following != "":
            run_start = index
            while (
                run_start > 0
                and payloads[run_start - 1] == ""
                and not more_indented[run_start - 1]
            ):
                run_start -= 1
            separator = "\n" if (
                run_start == 0
                or more_indented[run_start - 1]
            ) else ""
        elif current == "" or following == "":
            separator = "\n"
        else:
            separator = " "
        folded.append(separator)
        folded.append(following)
    return "".join(folded)


def parse_frontmatter_block_scalar(
    lines: list[str],
    header_index: int,
    header: tuple[str, int | None, str],
) -> tuple[str | None, int, str | None]:
    """Parse a root ``description`` block scalar and return its next line.

    Leading ASCII spaces determine indentation. Tabs after that indentation
    remain scalar content, including when they begin a folded line.
    """
    style, indent_indicator, chomping = header
    content_lines: list[tuple[int, str]] = []
    line_index = header_index + 1
    while line_index < len(lines):
        line = lines[line_index]
        if line.strip(YAML_SEPARATOR_SPACE) == "":
            content_lines.append((line_index, line))
            line_index += 1
            continue
        indent = len(line) - len(line.lstrip(YAML_SEPARATOR_SPACE))
        if indent == 0:
            break
        content_lines.append((line_index, line))
        line_index += 1

    non_empty_lines = [
        (physical_index, line)
        for physical_index, line in content_lines
        if line.strip(YAML_SEPARATOR_SPACE)
    ]
    if indent_indicator is None:
        if non_empty_lines:
            content_indent = len(non_empty_lines[0][1]) - len(
                non_empty_lines[0][1].lstrip(YAML_SEPARATOR_SPACE)
            )
        else:
            content_indent = 0
    else:
        content_indent = indent_indicator

    if indent_indicator is None and non_empty_lines:
        first_non_empty_index = non_empty_lines[0][0]
        for physical_index, line in content_lines:
            if physical_index >= first_non_empty_index:
                break
            indent = len(line) - len(line.lstrip(YAML_SEPARATOR_SPACE))
            if indent > content_indent:
                return (
                    None,
                    line_index,
                    f"line {physical_index + 2}: {FRONTMATTER_BLOCK_SCALAR_INDENTATION_ERROR}",
                )

    payloads: list[str] = []
    more_indented: list[bool] = []
    for physical_index, line in content_lines:
        indent = len(line) - len(line.lstrip(YAML_SEPARATOR_SPACE))
        if (
            non_empty_lines
            and line.strip(YAML_SEPARATOR_SPACE)
            and indent < content_indent
        ):
            return (
                None,
                line_index,
                f"line {physical_index + 2}: {FRONTMATTER_BLOCK_SCALAR_INDENTATION_ERROR}",
            )
        if not non_empty_lines:
            payload = ""
            is_more_indented = False
        elif indent < content_indent:
            payload = ""
            is_more_indented = False
        else:
            payload = line[content_indent:]
            is_more_indented = indent > content_indent or payload.startswith("\t")
        payloads.append(payload)
        more_indented.append(is_more_indented)

    if style == "|":
        value = "\n".join(payloads)
    else:
        value = fold_frontmatter_block_lines(payloads, more_indented)
    if payloads:
        value += "\n"
    if chomping == "-":
        value = value.rstrip("\n")
    elif chomping == "":
        if not any(payload.strip(YAML_SEPARATOR_SPACE) for payload in payloads):
            value = ""
        else:
            value = value.rstrip("\n") + "\n"
    return value, line_index, None


def validate_interface_asset_path(
    value: str,
    key: str,
    line_number: int,
    skill_root: Path | None,
) -> str | None:
    """Validate an interface icon as a spelling-preserving skill asset path."""
    error_prefix = f"line {line_number}: interface field {key!r}"
    if "\\" in value or WINDOWS_DRIVE_PATH_RE.match(value):
        return f"{error_prefix} must be a skill-relative POSIX path under 'assets'"
    candidate = PurePosixPath(value)
    if (
        candidate.is_absolute()
        or not candidate.parts
        or candidate.parts[0] != "assets"
        or ".." in candidate.parts
    ):
        return f"{error_prefix} must stay inside the skill directory"
    if skill_root is None:
        return None

    try:
        resolved_root = skill_root.resolve(strict=True)
    except (OSError, RuntimeError):
        return f"{error_prefix} skill root cannot be resolved"
    current = resolved_root
    for component in candidate.parts:
        try:
            entries = list(current.iterdir())
        except OSError:
            return f"{error_prefix} path cannot be inspected"
        requested_bytes = os.fsencode(component)
        exact_entry = next(
            (
                entry
                for entry in entries
                if os.fsencode(entry.name) == requested_bytes
            ),
            None,
        )
        if exact_entry is None:
            if any(entry.name.casefold() == component.casefold() for entry in entries):
                return (
                    f"{error_prefix} path component spelling must match the on-disk "
                    "name exactly"
                )
            return f"{error_prefix} points to a missing file"
        current = exact_entry

    try:
        assets_root = (resolved_root / "assets").resolve(strict=True)
        resolved_target = current.resolve(strict=True)
    except (OSError, RuntimeError):
        return f"{error_prefix} must resolve to a file inside skill assets"
    if (
        not assets_root.is_dir()
        or not assets_root.is_relative_to(resolved_root)
        or not resolved_target.is_relative_to(assets_root)
    ):
        return f"{error_prefix} must resolve to a file inside skill assets"
    if not resolved_target.is_file():
        return f"{error_prefix} points to a missing file"
    return None


def validate_skill_interface_metadata(
    text: str,
    skill_name: str,
    skill_root: Path | None = None,
) -> list[str]:
    """Validate direct children of one interface mapping in the supported subset.

    The supported root mapping keys are ``interface:``, ``dependencies:``, and
    ``policy:``.
    """
    if contains_yaml_surrogate(text):
        return [YAML_SURROGATE_ERROR]
    if contains_unsupported_yaml_structure_separator(text):
        return [YAML_UNSUPPORTED_STRUCTURE_SEPARATOR_ERROR]
    if contains_literal_yaml_control(text):
        return [YAML_LITERAL_CONTROL_ERROR]
    if contains_unsupported_yaml_line_separator(text):
        return [YAML_UNSUPPORTED_LINE_SEPARATOR_ERROR]
    if text.startswith("\ufeff"):
        text = text[1:]
    if dependency_error := validate_supported_dependencies(text):
        return [dependency_error]

    blocks: list[dict[str, tuple[str | None, int]]] = []
    current: dict[str, tuple[str | None, int]] | None = None
    active_root: str | None = None
    for line_number, raw_line in enumerate(text.splitlines(), 1):
        leading = raw_line[: len(raw_line) - len(raw_line.lstrip(" \t"))]
        if "\t" in leading:
            return [f"line {line_number}: tabs are not allowed for interface indentation"]
        if "\t" in raw_line:
            return [f"line {line_number}: literal tabs are not supported in interface metadata"]
        stripped = raw_line.strip(" \t")
        if not stripped or stripped.startswith("#"):
            continue
        if is_yaml_document_marker(stripped):
            return [f"line {line_number}: {YAML_DOCUMENT_MARKER_ERROR}"]
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        if indent == 0:
            if not is_supported_root_mapping_line(stripped):
                return [f"line {line_number}: {YAML_ROOT_MAPPING_ERROR}"]
            root_key = supported_root_mapping_key(stripped)
            if root_key not in YAML_SUPPORTED_ROOT_MAPPING_KEYS:
                return [f"line {line_number}: {YAML_UNSUPPORTED_ROOT_MAPPING_ERROR}"]
            active_root = root_key
            if root_key == "interface":
                if not is_supported_root_mapping_header(stripped, "interface"):
                    return [f"line {line_number}: interface must be a root mapping"]
                blocks.append({})
                current = blocks[-1]
            elif root_key == "policy":
                if not is_supported_root_mapping_header(stripped, "policy"):
                    return [f"line {line_number}: policy must be a root mapping"]
                current = None
            else:
                if not is_supported_root_mapping_header(stripped, "dependencies"):
                    return [f"line {line_number}: dependencies must be a root mapping"]
                current = None
            continue
        if active_root is None:
            return [f"line {line_number}: {YAML_ROOT_MAPPING_ERROR}"]
        if active_root == "dependencies":
            continue
        if indent != 2:
            return [
                f"line {line_number}: {active_root} descendants must be direct children "
                "at two-space indentation"
            ]
        if current is None:
            continue
        key, separator, value = stripped.partition(":")
        if separator != ":":
            return [f"line {line_number}: invalid interface child"]
        if value and not value.startswith(YAML_SEPARATOR_SPACE):
            return [
                f"line {line_number}: interface child {key!r} must use YAML separation space after ':'"
            ]
        if key not in INTERFACE_METADATA_KEYS:
            return [f"line {line_number}: unsupported interface child {key!r}"]
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
    elif not has_complete_skill_token(default_prompt[0], skill_name):
        errors.append(f"default_prompt must mention ${skill_name}")
    for key, (value, line_number) in fields.items():
        if key in INTERFACE_ICON_KEYS:
            if value is None:
                continue
            if asset_error := validate_interface_asset_path(
                value,
                key,
                line_number,
                skill_root,
            ):
                errors.append(asset_error)
        elif key == "brand_color" and value is not None:
            if INTERFACE_BRAND_COLOR_RE.fullmatch(value) is None:
                errors.append(
                    f"line {line_number}: interface field 'brand_color' must use #RRGGBB"
                )
    return errors


def validate_skill_frontmatter_name(skill_name: str, skill_path: Path, errors: list[str]) -> None:
    values = parse_frontmatter(skill_path, errors)
    declared_name = values.get("name")
    if declared_name is None:
        fail(errors, f"{skill_path.relative_to(ROOT)}: frontmatter name is missing")
    elif declared_name != skill_name:
        fail(
            errors,
            f"{skill_path.relative_to(ROOT)}: frontmatter name {declared_name!r} "
            f"does not match inventory entry {skill_name!r}",
        )


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
        skill_path = skills_dir / skill_name / "SKILL.md"
        if not skill_path.is_file():
            fail(errors, f"{skill_path.relative_to(ROOT)}: skill instructions are missing")
        else:
            validate_skill_frontmatter_name(skill_name, skill_path, errors)
        metadata_path = skills_dir / skill_name / "agents" / "openai.yaml"
        if not metadata_path.is_file():
            fail(errors, f"{metadata_path.relative_to(ROOT)}: metadata is missing")
            continue
        try:
            text = metadata_path.read_text()
        except OSError as error:
            fail(errors, f"{metadata_path.relative_to(ROOT)}: cannot read: {error}")
            continue
        for interface_error in validate_skill_interface_metadata(
            text,
            skill_name,
            metadata_path.parent.parent,
        ):
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
    for skill_name in ("take-ticket", "prepare-backlog", "adopt-existing-pr"):
        path = ROOT / ".agents" / "skills" / skill_name / "SKILL.md"
        values = parse_frontmatter(path, errors)
        if values.get("disable-model-invocation") is not True:
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
        if skill_name == "adopt-existing-pr":
            for required in (
                "check-cloud-queue-contract.py",
                "authorize-existing-pr-adoption-mutation.py",
                "materialize-existing-pr-adoption.py",
                "add-only",
            ):
                if required not in text:
                    fail(errors, f"{path.relative_to(ROOT)}: missing adoption contract {required!r}")
        elif skill_name == "take-ticket":
            for required in ("scheduled", "at most", "no-work"):
                if required not in text:
                    fail(errors, f"{path.relative_to(ROOT)}: missing scheduled contract {required!r}")
        else:
            for required in ("research-cycle", "no-work"):
                if required not in text:
                    fail(errors, f"{path.relative_to(ROOT)}: missing research contract {required!r}")

    gatekeeper = ROOT / ".agents" / "skills" / "merge-gatekeeper" / "SKILL.md"
    values = parse_frontmatter(gatekeeper, errors)
    if values.get("disable-model-invocation") is not True:
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
        "scripts/authorize-existing-pr-adoption-mutation.py",
        "scripts/materialize-existing-pr-adoption.py",
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
        (
            "adopter-helper",
            "rpm_existing_pr_adopter",
            "exec_command",
            {
                "cmd": "python3 scripts/authorize-existing-pr-adoption-mutation.py --request-file /tmp/request.json"
            },
            0,
        ),
        (
            "adopter-materializer",
            "rpm_existing_pr_adopter",
            "exec_command",
            {
                "cmd": "python3 scripts/materialize-existing-pr-adoption.py --run-id adoption-run-228 --kind issues --payload-base64 e30="
            },
            0,
        ),
        (
            "adopter-writer",
            "rpm_existing_pr_adopter",
            "exec_command",
            {
                "cmd": "python3 scripts/write-existing-pr-adoption.py --policy .agents/workflows/backlog-policy.json --request-file /tmp/request.json"
            },
            0,
        ),
        (
            "adopter-checker",
            "rpm_existing_pr_adopter",
            "exec_command",
            {
                "cmd": "python3 scripts/check-cloud-queue-contract.py --issues-file /tmp/issues.json --operation adopt-existing-pr"
            },
            0,
        ),
        (
            "adopter-python-shell",
            "rpm_existing_pr_adopter",
            "exec_command",
            {"cmd": "python3 -c 'import subprocess; subprocess.run([\"gh\", \"api\"])'"},
            2,
        ),
        (
            "adopter-network-shell",
            "rpm_existing_pr_adopter",
            "exec_command",
            {"cmd": "curl -X POST https://api.github.com/repos/nerdchanii/rpm/issues"},
            2,
        ),
        (
            "adopter-terminal-shell",
            "rpm_existing_pr_adopter",
            "terminal",
            {"cmd": "curl -X POST https://api.github.com/repos/nerdchanii/rpm/issues"},
            2,
        ),
        (
            "adopter-generic-executor",
            "rpm_existing_pr_adopter",
            "foo.execute",
            {"cmd": "python3 scripts/write-existing-pr-adoption.py --request-file /tmp/request.json"},
            2,
        ),
        (
            "adopter-obfuscated-shell",
            "rpm_existing_pr_adopter",
            "exec_command",
            {
                "cmd": "python3 scripts/check-cloud-queue-contract.py --issues-file /tmp/issues.json --operation adopt-existing-pr; gh api repos/nerdchanii/rpm/issues"
            },
            2,
        ),
        (
            "adopter-generic-mutation",
            "rpm_existing_pr_adopter",
            "mcp__github__update_issue",
            {"issue_number": 145, "labels": ["agent:review-pending"]},
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
