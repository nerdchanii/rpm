#!/usr/bin/env python3
"""Block a completed issue manager when the deterministic RPM gate is red."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


MANAGER = "rpm_issue_manager"
EVENT_TYPE = "issue_workflow_result"
TARGET_DIR = "/tmp/rpm-codex-target"


def read_event() -> dict[str, object]:
    try:
        value = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        print(f"RPM manager gate received invalid hook JSON: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    if not isinstance(value, dict):
        print("RPM manager gate received a non-object hook payload.", file=sys.stderr)
        raise SystemExit(2)
    return value


def workflow_status(message: object) -> str | None:
    if not isinstance(message, str) or not message.strip():
        return None
    try:
        result = json.loads(message)
    except json.JSONDecodeError:
        return None
    if not isinstance(result, dict) or result.get("type") != EVENT_TYPE:
        return None
    data = result.get("data")
    if not isinstance(data, dict):
        return None
    status = data.get("status")
    return status if isinstance(status, str) else None


def main() -> int:
    event = read_event()
    if event.get("agent_type") != MANAGER:
        return 0
    if workflow_status(event.get("last_assistant_message")) != "complete":
        return 0

    cwd_value = event.get("cwd")
    if not isinstance(cwd_value, str):
        print("RPM manager gate could not determine the repository cwd.", file=sys.stderr)
        return 2
    cwd = Path(cwd_value)
    if not (cwd / "justfile").is_file():
        print(f"RPM manager gate found no justfile under {cwd}.", file=sys.stderr)
        return 2

    environment = os.environ.copy()
    environment["CARGO_TARGET_DIR"] = TARGET_DIR
    completed = subprocess.run(
        ["just", "validate"],
        cwd=cwd,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode == 0:
        return 0

    excerpt = completed.stdout[-6000:]
    print(
        "RPM issue workflow cannot complete because `just validate` failed. "
        "Route the failure to the responsible leaf, rerun targeted tests and verification, "
        "then return a new issue_workflow_result.\n"
        f"exit_code={completed.returncode}\n"
        f"{excerpt}",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
