#!/usr/bin/env python3
"""Validate the RPM-local worktree orchestration plan contract."""

from __future__ import annotations

import json
import posixpath
import re
import sys
from pathlib import Path
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


def invalid(message: str) -> None:
    raise ValueError(message)


def normalize_path(value: str) -> str:
    path = posixpath.normpath(value.strip())
    if (
        value == "*"
        or path in {"", "."}
        or path == ".."
        or path.startswith("../")
        or path.startswith("/")
        or path.startswith("~")
    ):
        if value == "*":
            return "*"
        invalid(f"unsafe write path: {value!r}")
    return path.removeprefix("./")


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
        if node["base_revision"] != plan["base_revision"]:
            invalid(f"{node_id}.base_revision is stale")
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
        ownership.extend((node_id, normalize_path(path)) for path in paths)
        if node["state"] not in STATES:
            invalid(f"{node_id}.state is invalid")
        if not isinstance(node["attempt"], int) or node["attempt"] < 0:
            invalid(f"{node_id}.attempt must be non-negative")

    for node_id, node in by_id.items():
        for dependency in node["depends_on"]:
            if dependency not in by_id:
                invalid(f"{node_id} depends on missing node: {dependency}")
        if node["state"] in {"ready", "running", "completed", "integrated"}:
            unfinished = [
                dependency
                for dependency in node["depends_on"]
                if by_id[dependency]["state"] not in {"completed", "integrated"}
            ]
            if unfinished:
                invalid(f"{node_id} has unfinished dependencies: {','.join(unfinished)}")
    for gate in gates:
        if gate not in by_id:
            invalid(f"required gate is missing: {gate}")
    for index, (left_id, left_path) in enumerate(ownership):
        for right_id, right_path in ownership[index + 1 :]:
            if left_id != right_id and overlap(left_path, right_path):
                invalid(f"overlapping ownership: {left_id}:{left_path} vs {right_id}:{right_path}")

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
