#!/usr/bin/env python3
"""Create deterministic execution metadata for an approved RPM issue scope."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


EXECUTOR_VALUES = {"local", "cloud"}
HEADING = re.compile(r"^##\s+(.+?)\s*#*\s*$")
SCOPE_HEADINGS = ("Initial scope", "Done criteria")
EXECUTION_MARKER = re.compile(r"^\s*<!--\s*rpm-agent-execution:\s*(\{.*\})\s*-->\s*$")
RUN_LEDGER_MARKER = re.compile(r"^\s*<!--\s*rpm-agent-run-ledger:\s*(\{.*\})\s*-->\s*$")
IDEMPOTENCY_KEY = re.compile(r"sha256:[0-9a-f]{64}\Z")
RUN_FIELDS = ("run_id", "event_id", "idempotency_key", "status")


def normalize_heading(value: str) -> str:
    value = re.sub(r"[`*_]", "", value).strip().casefold()
    value = re.sub(r"[-_]+", " ", value)
    return re.sub(r"\s+", " ", value)


def extract_scope(body: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current: str | None = None
    for line in body.splitlines():
        match = HEADING.match(line.strip())
        if match:
            current = normalize_heading(match.group(1))
            sections.setdefault(current, [])
            continue
        if current is not None:
            text = line.strip()
            if text and not text.startswith("<!--"):
                sections[current].append(text)

    scope: dict[str, str] = {}
    for heading in SCOPE_HEADINGS:
        key = normalize_heading(heading)
        lines = sections.get(key, [])
        if not lines:
            raise ValueError(f"{heading} must be populated before approval")
        scope[heading] = "\n".join(lines)
    return scope


def _decode_runs(raw: object) -> list[dict[str, str]]:
    if not isinstance(raw, list) or not raw or not all(isinstance(run, dict) for run in raw):
        raise ValueError("run ledger must contain a non-empty array of objects")
    result: list[dict[str, str]] = []
    seen: set[str] = set()
    for run in raw:
        if any(not isinstance(run.get(field), str) or not run[field].strip() for field in RUN_FIELDS):
            raise ValueError("run ledger contains an invalid record")
        if not IDEMPOTENCY_KEY.fullmatch(run["idempotency_key"]):
            raise ValueError("run ledger contains an invalid idempotency key")
        normalized = json.dumps(run, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        if normalized not in seen:
            seen.add(normalized)
            result.append({field: str(run[field]) for field in RUN_FIELDS})
    return result


def extract_run_ledger(body: str) -> list[dict[str, str]]:
    runs: list[dict[str, str]] = []
    seen: set[str] = set()
    for line in body.splitlines():
        for pattern, source in ((RUN_LEDGER_MARKER, "run ledger"), (EXECUTION_MARKER, "execution marker")):
            match = pattern.match(line)
            if match is None:
                continue
            try:
                payload = json.loads(match.group(1))
            except json.JSONDecodeError as error:
                raise ValueError(f"{source} JSON is invalid") from error
            if not isinstance(payload, dict):
                raise ValueError(f"{source} must contain an object")
            raw_runs = payload.get("runs")
            if raw_runs is None:
                continue
            for run in _decode_runs(raw_runs):
                normalized = json.dumps(run, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                if normalized not in seen:
                    seen.add(normalized)
                    runs.append(run)
    return runs


def create_metadata(issue: str, body: str, executor: str) -> dict[str, object]:
    if not issue.isdigit() or int(issue) <= 0:
        raise ValueError("issue must be a positive issue number")
    if executor not in EXECUTOR_VALUES:
        raise ValueError("executor must be local or cloud")

    scope = extract_scope(body)
    scope_basis = json.dumps(scope, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(scope_basis.encode("utf-8")).hexdigest()
    metadata = {
        "approval_id": f"approval-{issue}-{digest[:16]}",
        "plan_revision": f"plan-{digest[:16]}",
        "scope_hash": f"sha256:{digest}",
        "executor": executor,
    }
    marker_payload: dict[str, object] = dict(metadata)
    prior_runs = extract_run_ledger(body)
    if prior_runs:
        marker_payload["runs"] = prior_runs
    marker = "<!-- rpm-agent-execution: " + json.dumps(
        marker_payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ) + " -->"
    return {
        "type": "execution_metadata_result",
        "data": {
            "issue": int(issue),
            "metadata": metadata,
            "marker": marker,
            "scope": scope,
        },
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--issue", required=True, help="positive GitHub issue number")
    parser.add_argument("--body-file", required=True, type=Path)
    parser.add_argument("--executor", required=True, choices=sorted(EXECUTOR_VALUES))
    parser.add_argument("--format", choices=("json", "jsonl"), default="jsonl")
    args = parser.parse_args(argv)
    try:
        body = args.body_file.read_text(encoding="utf-8")
        result = create_metadata(args.issue, body, args.executor)
    except (OSError, ValueError) as error:
        print(f"execution_metadata.error={error}", file=sys.stderr)
        return 2

    if args.format == "json":
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
