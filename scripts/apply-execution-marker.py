#!/usr/bin/env python3
"""Safely replace or append the managed RPM execution marker in an issue body."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

from execution_contract import SHA256_KEY, parse_rfc3339, validate_run_record


MARKER_LINE = re.compile(r"^[ \t]*<!--\s*rpm-agent-execution:\s*(\{.*\})\s*-->[ \t]*$")
REQUIRED_FIELDS = ("approval_id", "plan_revision", "scope_hash", "executor")


def parse_timestamp(value: str) -> datetime:
    return parse_rfc3339(value)


def marker_payload(marker: str) -> dict[str, object]:
    match = MARKER_LINE.fullmatch(marker.strip())
    if match is None:
        raise ValueError("marker must be one rpm-agent-execution comment")
    try:
        payload = json.loads(match.group(1))
    except json.JSONDecodeError as error:
        raise ValueError("marker JSON is invalid") from error
    if not isinstance(payload, dict):
        raise ValueError("marker JSON must be an object")
    return payload


def validate_runs(runs: object, *, require_active: bool) -> dict[str, object]:
    if not isinstance(runs, list) or not runs:
        raise ValueError("marker is missing runs ledger")
    for run in runs:
        try:
            validate_run_record(run, "marker runs ledger")
        except ValueError as error:
            raise ValueError("marker has an invalid runs ledger") from error
    final = runs[-1]
    if require_active and final["status"] != "active":
        raise ValueError("marker has an invalid runs ledger")
    return final


def validate_marker(marker: str) -> None:
    match = MARKER_LINE.fullmatch(marker.strip())
    if match is None:
        raise ValueError("marker must be one rpm-agent-execution comment")
    try:
        payload = json.loads(match.group(1))
    except json.JSONDecodeError as error:
        raise ValueError("marker JSON is invalid") from error
    if not isinstance(payload, dict):
        raise ValueError("marker JSON must be an object")
    if any(not isinstance(payload.get(field), str) or not payload[field].strip() for field in REQUIRED_FIELDS):
        raise ValueError("marker is missing required execution metadata")
    if payload["executor"] not in {"local", "cloud"}:
        raise ValueError("marker has an invalid executor")
    if not SHA256_KEY.fullmatch(payload["scope_hash"]):
        raise ValueError("marker has an invalid scope hash")
    lease = payload.get("lease")
    if not isinstance(lease, dict) or any(
        not isinstance(lease.get(field), str) or not lease[field].strip()
        for field in ("run_id", "owner", "expires_at")
    ):
        raise ValueError("marker is missing lease")
    try:
        parse_timestamp(lease["expires_at"])
    except (TypeError, ValueError) as error:
        raise ValueError("lease.expires_at must be an RFC3339 timestamp") from error
    run = validate_runs(payload.get("runs"), require_active=True)
    if lease["run_id"] != run["run_id"]:
        raise ValueError("lease.run_id must match the active run")


def validate_approval_marker(marker: str) -> None:
    match = MARKER_LINE.fullmatch(marker.strip())
    if match is None:
        raise ValueError("expected marker must be one rpm-agent-execution comment")
    try:
        payload = json.loads(match.group(1))
    except json.JSONDecodeError as error:
        raise ValueError("expected marker JSON is invalid") from error
    if not isinstance(payload, dict) or set(payload) - (set(REQUIRED_FIELDS) | {"runs"}):
        raise ValueError("expected marker must contain only approved execution metadata and runs")
    if not set(REQUIRED_FIELDS).issubset(payload):
        raise ValueError("expected marker is missing approved execution metadata")
    if any(not isinstance(payload.get(field), str) or not payload[field].strip() for field in REQUIRED_FIELDS):
        raise ValueError("expected marker is missing approved execution metadata")
    if payload["executor"] not in {"local", "cloud"}:
        raise ValueError("expected marker has an invalid executor")
    if not SHA256_KEY.fullmatch(payload["scope_hash"]):
        raise ValueError("expected marker has an invalid scope hash")
    if "runs" in payload:
        validate_runs(payload["runs"], require_active=False)


def validate_expected_marker(marker: str) -> None:
    match = MARKER_LINE.fullmatch(marker.strip())
    if match is None:
        raise ValueError("expected marker must be one rpm-agent-execution comment")
    try:
        payload = json.loads(match.group(1))
    except json.JSONDecodeError as error:
        raise ValueError("expected marker JSON is invalid") from error
    if (
        isinstance(payload, dict)
        and set(payload).issubset(set(REQUIRED_FIELDS) | {"runs"})
        and set(REQUIRED_FIELDS).issubset(payload)
    ):
        validate_approval_marker(marker)
        return
    validate_marker(marker)


def apply_marker(
    body: str,
    marker: str,
    *,
    expected_marker: str | None = None,
    initialization: bool = False,
) -> str:
    normalized_marker = marker.strip()
    validate_marker(normalized_marker)
    if (expected_marker is None) == (not initialization):
        raise ValueError("claim application requires an expected predecessor or explicit initialization")
    normalized_expected = expected_marker.strip() if expected_marker is not None else None
    if normalized_expected is not None:
        validate_expected_marker(normalized_expected)
        expected_payload = marker_payload(normalized_expected)
        replacement_payload = marker_payload(normalized_marker)
        if any(
            replacement_payload[field] != expected_payload[field]
            for field in REQUIRED_FIELDS
        ):
            raise ValueError("replacement marker approval metadata mismatch")
    lines = body.splitlines(keepends=True)
    matches = [index for index, line in enumerate(lines) if MARKER_LINE.fullmatch(line.rstrip("\r\n"))]
    if len(matches) > 1:
        raise ValueError("body contains multiple execution markers")
    if matches:
        index = matches[0]
        current_marker = lines[index].rstrip("\r\n").strip()
        if initialization:
            raise ValueError("initialization requires no existing execution marker")
        if current_marker != normalized_expected:
            raise ValueError("execution marker compare-and-set mismatch")
        newline = "\n" if lines[index].endswith("\n") else ""
        lines[index] = normalized_marker + newline
        return "".join(lines)
    if not initialization:
        raise ValueError("claim application requires exactly one existing execution marker")
    separator = "" if not body or body.endswith(("\n", "\r")) else "\n"
    return body + separator + normalized_marker + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--body-file", required=True, type=Path)
    parser.add_argument("--marker-file", required=True, type=Path)
    expected = parser.add_mutually_exclusive_group(required=True)
    expected.add_argument("--expected-marker-file", type=Path)
    expected.add_argument("--initialize", action="store_true")
    parser.add_argument("--output-file", type=Path)
    args = parser.parse_args(argv)
    try:
        body = args.body_file.read_text(encoding="utf-8")
        marker = args.marker_file.read_text(encoding="utf-8")
        expected_marker = (
            args.expected_marker_file.read_text(encoding="utf-8")
            if args.expected_marker_file is not None
            else None
        )
        result = apply_marker(
            body,
            marker,
            expected_marker=expected_marker,
            initialization=args.initialize,
        )
        if args.output_file is None:
            sys.stdout.write(result)
        else:
            args.output_file.write_text(result, encoding="utf-8")
    except (OSError, ValueError) as error:
        print(f"execution_marker.error={error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
