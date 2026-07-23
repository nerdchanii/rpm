#!/usr/bin/env python3
"""Deterministically check whether an RPM issue is ready for execution."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


EVENT_TYPE = "issue_readiness_result"
REQUIRED_SECTIONS = (
    "Context",
    "Research",
    "Contract",
    "Initial scope",
    "Done criteria",
    "Related work",
)
NONE_VALUES = {
    "none",
    "n/a",
    "not applicable",
    "no unresolved decisions",
    "없음",
    "해당 없음",
}
DECISION_HEADINGS = {
    "decision",
    "decisions",
    "open decision",
    "open decisions",
    "unresolved decision",
    "unresolved decisions",
    "open question",
    "open questions",
}
HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*#*\s*$")
UNCHECKED = re.compile(r"^\s*[-*+]\s+\[\s\]\s+(.+?)\s*$", re.IGNORECASE)
STATUS_MARKER = re.compile(
    r"\b(?:decision[_ -]?status|decision)\s*[:=]\s*"
    r"(?:unresolved|open|pending|blocked)\b",
    re.IGNORECASE,
)
TBD_MARKER = re.compile(r"(?:\bTBD\b|결정\s*(?:필요|대기|미정))", re.IGNORECASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Check required issue sections and unresolved-decision markers. "
            "The command never mutates repository or GitHub state."
        )
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--body-file", type=Path, help="read Markdown from a file")
    source.add_argument("--issue", help="read a live issue through `gh issue view`")
    parser.add_argument(
        "--format",
        choices=("json", "jsonl"),
        default="jsonl",
        help="machine-readable output format (default: jsonl)",
    )
    return parser.parse_args()


def normalize_heading(value: str) -> str:
    value = re.sub(r"[`*_]", "", value).strip().casefold()
    value = re.sub(r"[-_]+", " ", value)
    return re.sub(r"\s+", " ", value)


def load_body(args: argparse.Namespace) -> tuple[str, dict[str, object]]:
    if args.body_file is not None:
        try:
            body = args.body_file.read_text(encoding="utf-8")
        except OSError as error:
            raise RuntimeError(f"cannot read body file {args.body_file}: {error}") from error
        return body, {"kind": "body-file", "value": str(args.body_file)}

    try:
        completed = subprocess.run(
            [
                "gh",
                "issue",
                "view",
                str(args.issue),
                "--json",
                "number,title,body,url,state,labels",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        raise RuntimeError(f"cannot execute `gh issue view`: {error}") from error
    if completed.returncode != 0:
        detail = completed.stderr.strip() or f"exit {completed.returncode}"
        raise RuntimeError(f"`gh issue view` failed: {detail}")
    try:
        issue = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"`gh issue view` returned invalid JSON: {error}") from error
    if not isinstance(issue, dict):
        raise RuntimeError("`gh issue view` returned a non-object JSON value")
    body = issue.get("body")
    if not isinstance(body, str):
        raise RuntimeError("live issue has no string body")
    return body, {
        "kind": "live-issue",
        "value": issue.get("url") or str(args.issue),
        "number": issue.get("number"),
        "title": issue.get("title"),
        "state": issue.get("state"),
        "labels": [
            label.get("name")
            for label in issue.get("labels", [])
            if isinstance(label, dict) and isinstance(label.get("name"), str)
        ],
    }


def meaningful(lines: list[tuple[int, str]]) -> bool:
    for _, line in lines:
        text = re.sub(r"<!--.*?-->", "", line).strip()
        if text and text not in {"---", "***"}:
            return True
    return False


def analyze(body: str, source: dict[str, object]) -> dict[str, object]:
    sections: dict[str, list[tuple[int, str]]] = {}
    current = ""
    for number, line in enumerate(body.splitlines(), start=1):
        match = HEADING.match(line.strip())
        if match:
            current = normalize_heading(match.group(2))
            sections.setdefault(current, [])
            continue
        if current:
            sections.setdefault(current, []).append((number, line))

    required: dict[str, dict[str, bool]] = {}
    missing: list[str] = []
    empty: list[str] = []
    for display_name in REQUIRED_SECTIONS:
        key = normalize_heading(display_name)
        present = key in sections
        populated = present and meaningful(sections[key])
        required[display_name] = {"present": present, "populated": populated}
        if not present:
            missing.append(display_name)
        elif not populated:
            empty.append(display_name)

    unresolved: list[dict[str, object]] = []
    for heading, lines in sections.items():
        decision_section = heading in DECISION_HEADINGS
        open_lines: list[tuple[int, str]] = []
        for number, line in lines:
            text = line.strip()
            if not text:
                continue
            normalized = re.sub(r"^\s*[-*+]\s+", "", text).strip().casefold()
            normalized = normalized.rstrip(".:;!。；：")
            if decision_section and normalized not in NONE_VALUES:
                open_lines.append((number, text))
            unchecked = UNCHECKED.match(line)
            if decision_section and unchecked:
                unresolved.append(
                    {"line": number, "text": unchecked.group(1), "reason": "unchecked-decision"}
                )
            elif STATUS_MARKER.search(line):
                unresolved.append(
                    {"line": number, "text": text, "reason": "unresolved-status"}
                )
            elif heading in {"contract", "initial scope", "done criteria"} and TBD_MARKER.search(
                line
            ):
                unresolved.append(
                    {"line": number, "text": text, "reason": "contract-tbd"}
                )
        if decision_section and open_lines and not any(
            item["line"] in {number for number, _ in lines} for item in unresolved
        ):
            unresolved.append(
                {
                    "line": open_lines[0][0],
                    "text": open_lines[0][1],
                    "reason": "open-decision-section",
                }
            )

    ready = not missing and not empty and not unresolved
    return {
        "type": EVENT_TYPE,
        "data": {
            "status": "ready" if ready else "needs-refinement",
            "ready": ready,
            "source": source,
            "required_sections": required,
            "missing_sections": missing,
            "empty_sections": empty,
            "unresolved_decisions": unresolved,
        },
    }


def emit(result: dict[str, object], output_format: str) -> None:
    if output_format == "json":
        json.dump(result, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        json.dump(result, sys.stdout, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        sys.stdout.write("\n")


def main() -> int:
    args = parse_args()
    try:
        body, source = load_body(args)
    except RuntimeError as error:
        print(f"issue_readiness.error={error}", file=sys.stderr)
        return 2
    result = analyze(body, source)
    emit(result, args.format)
    return 0 if result["data"]["ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
