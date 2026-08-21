#!/usr/bin/env python3
"""Validate the RPM-local worktree orchestration plan contract."""

from __future__ import annotations

import json
import posixpath
import re
import sys
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Any


STATES = {
    "pending",
    "ready",
    "running",
    "completed",
    "blocked",
    "failed",
    "integrated",
    "cancelled",
}
SCOPE_HASH = re.compile(r"sha256:[0-9a-f]{64}\Z")
REPOSITORY_ROOT = Path(__file__).resolve().parents[4]


def invalid(message: str) -> None:
    raise ValueError(message)


def normalize_path(value: str) -> str:
    raw = value.strip()
    if raw == "*":
        invalid(f"unsafe write path: {value!r}")
    windows = PureWindowsPath(raw)
    if windows.drive or windows.root:
        invalid(f"unsafe write path: {value!r}")
    path = posixpath.normpath(raw.replace("\\", "/"))
    if (
        path in {"", "."}
        or path == ".."
        or path.startswith("../")
        or path.startswith("/")
        or path.startswith("~")
    ):
        invalid(f"unsafe write path: {value!r}")
    normalized = path.removeprefix("./")
    if normalized == ".git" or normalized.startswith(".git/"):
        invalid(f"unsafe write path: {value!r}")
    return normalized


def canonicalize_path(normalized: str) -> str:
    if normalized == "*":
        return normalized
    try:
        resolved = (REPOSITORY_ROOT / normalized).resolve(strict=False)
        relative = resolved.relative_to(REPOSITORY_ROOT)
    except (OSError, RuntimeError, ValueError) as error:
        invalid(f"unsafe write path: {normalized!r}")
        raise AssertionError("unreachable") from error
    return relative.as_posix()


def reject_existing_symlink(normalized: str) -> None:
    current = REPOSITORY_ROOT
    for component in PurePosixPath(normalized).parts:
        current /= component
        try:
            is_symlink = current.is_symlink()
        except OSError as error:
            invalid(f"cannot inspect write path: {normalized!r}")
            raise AssertionError("unreachable") from error
        if is_symlink:
            invalid(f"unsafe write path through symlink: {normalized!r}")


def overlap(left: str, right: str) -> bool:
    return (
        left == "*"
        or right == "*"
        or left == right
        or left.startswith(f"{right}/")
        or right.startswith(f"{left}/")
    )


def validate(plan: Any) -> None:
    if not isinstance(plan, dict):
        invalid("plan must be an object")
    if plan.get("repository") != "nerdchanii/rpm":
        invalid("repository must be nerdchanii/rpm")
    for field in ("plan_revision", "base_revision"):
        if not isinstance(plan.get(field), str) or not plan[field].strip():
            invalid(f"{field} must be a non-empty string")
    if plan.get("executor") not in {"local", "cloud"}:
        invalid("executor must be local or cloud")
    if not isinstance(plan.get("scope_hash"), str) or not SCOPE_HASH.fullmatch(plan["scope_hash"]):
        invalid("scope_hash must be sha256:<64 lowercase hex characters>")

    gates = plan.get("required_gates")
    if not isinstance(gates, list) or not gates or any(not isinstance(gate, str) or not gate for gate in gates):
        invalid("required_gates must be a non-empty array")
    nodes = plan.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        invalid("nodes must be a non-empty array")

    by_id: dict[str, dict[str, Any]] = {}
    ownership: list[tuple[str, str]] = []
    for index, node in enumerate(nodes):
        if not isinstance(node, dict):
            invalid(f"nodes[{index}] must be an object")
        required = (
            "id",
            "objective",
            "role",
            "depends_on",
            "write_paths",
            "base_revision",
            "plan_revision",
            "state",
            "attempt",
        )
        missing = [field for field in required if field not in node]
        if missing:
            invalid(f"node missing fields: {','.join(missing)}")
        node_id = node["id"]
        if not isinstance(node_id, str) or not node_id or node_id in by_id:
            invalid(f"invalid or duplicate node id: {node_id!r}")
        by_id[node_id] = node
        for field in ("objective", "role", "base_revision", "plan_revision"):
            if not isinstance(node[field], str) or not node[field].strip():
                invalid(f"{node_id}.{field} must be a non-empty string")
        integrated_revision = node.get("integrated_revision")
        if integrated_revision is not None and (
            not isinstance(integrated_revision, str) or not integrated_revision.strip()
        ):
            invalid(f"{node_id}.integrated_revision must be a non-empty string")
        if node["state"] == "integrated" and integrated_revision is None:
            invalid(f"{node_id}.integrated_revision is required for integrated nodes")
        base_revision_dependencies = node.get("base_revision_dependencies")
        if base_revision_dependencies is not None and (
            not isinstance(base_revision_dependencies, list)
            or any(
                not isinstance(dependency, str) or not dependency.strip()
                for dependency in base_revision_dependencies
            )
            or len(set(base_revision_dependencies)) != len(base_revision_dependencies)
        ):
            invalid(f"{node_id}.base_revision_dependencies must be a unique array of node ids")
        if node["plan_revision"] != plan["plan_revision"]:
            invalid(f"{node_id}.plan_revision is stale")
        dependencies = node["depends_on"]
        if not isinstance(dependencies, list) or any(not isinstance(dep, str) or not dep for dep in dependencies):
            invalid(f"{node_id}.depends_on must be an array of node ids")
        if node_id in dependencies:
            invalid(f"{node_id} depends on itself")
        paths = node["write_paths"]
        if not isinstance(paths, list) or any(not isinstance(path, str) or not path for path in paths):
            invalid(f"{node_id}.write_paths must be an array")
        for path in paths:
            normalized = normalize_path(path)
            reject_existing_symlink(normalized)
            ownership.append((node_id, canonicalize_path(normalized)))
        if node["state"] not in STATES:
            invalid(f"{node_id}.state is invalid")
        if isinstance(node["attempt"], bool) or not isinstance(node["attempt"], int) or node["attempt"] < 0:
            invalid(f"{node_id}.attempt must be non-negative")

    for node_id, node in by_id.items():
        for dependency in node["depends_on"]:
            if dependency not in by_id:
                invalid(f"{node_id} depends on missing node: {dependency}")
        integrated_dependencies = [
            dependency
            for dependency in node["depends_on"]
            if by_id[dependency]["state"] == "integrated"
        ]
        recorded_dependencies = node.get("base_revision_dependencies")
        if recorded_dependencies is not None and set(recorded_dependencies) != set(integrated_dependencies):
            invalid(f"{node_id}.base_revision_dependencies must match integrated dependencies")
        if len(integrated_dependencies) > 1 and recorded_dependencies is None:
            invalid(f"{node_id} must record every integrated dependency in base_revision_dependencies")
        integrated_revisions = {
            by_id[dependency]["integrated_revision"] for dependency in integrated_dependencies
        }
        if len(integrated_dependencies) > 1:
            if node["base_revision"] == plan["base_revision"]:
                invalid(f"{node_id}.base_revision must be a verified aggregate revision")
            allowed_base_revisions = {node["base_revision"]}
        else:
            allowed_base_revisions = {plan["base_revision"]} if not integrated_dependencies else integrated_revisions
        if node["base_revision"] not in allowed_base_revisions:
            invalid(f"{node_id}.base_revision is stale or not a verified integrated revision")
        if node["state"] in {"ready", "running", "completed", "integrated"}:
            unfinished = [
                dependency
                for dependency in node["depends_on"]
                if by_id[dependency]["state"] != "integrated"
            ]
            if unfinished:
                invalid(f"{node_id} has unfinished dependencies: {','.join(unfinished)}")
    for gate in gates:
        if gate not in by_id:
            invalid(f"required gate is missing: {gate}")
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(node_id: str, trail: list[str]) -> None:
        if node_id in visiting:
            start = trail.index(node_id)
            invalid("dependency cycle: " + " -> ".join(trail[start:] + [node_id]))
        if node_id in visited:
            return
        visiting.add(node_id)
        for dependency in by_id[node_id]["depends_on"]:
            visit(dependency, trail + [node_id])
        visiting.remove(node_id)
        visited.add(node_id)

    for node_id in by_id:
        visit(node_id, [])

    ancestors_cache: dict[str, set[str]] = {}

    def ancestors(node_id: str) -> set[str]:
        if node_id in ancestors_cache:
            return ancestors_cache[node_id]
        result: set[str] = set()
        for dependency in by_id[node_id]["depends_on"]:
            result.add(dependency)
            result.update(ancestors(dependency))
        ancestors_cache[node_id] = result
        return result

    for index, (left_id, left_path) in enumerate(ownership):
        for right_id, right_path in ownership[index + 1 :]:
            ordered = right_id in ancestors(left_id) or left_id in ancestors(right_id)
            if left_id != right_id and not ordered and overlap(left_path, right_path):
                invalid(f"overlapping ownership: {left_id}:{left_path} vs {right_id}:{right_path}")


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] in {"-h", "--help"}:
        print(f"usage: {argv[0]} PLAN.json")
        return 0
    if len(argv) != 2:
        print(f"usage: {argv[0]} PLAN.json", file=sys.stderr)
        return 2
    try:
        validate(json.loads(Path(argv[1]).read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"INVALID: {error}", file=sys.stderr)
        return 1
    print(f"VALID: {argv[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
