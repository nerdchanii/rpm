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


def check_entries_and_assets(errors: list[str]) -> None:
    for skill_name in ("take-ticket", "prepare-backlog", "adopt-existing-pr"):
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
