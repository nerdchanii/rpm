#!/usr/bin/env python3
"""Materialize one normalized existing-PR adoption handoff in a confined run dir."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
import tempfile
from pathlib import Path


RUN_ROOT = Path("/tmp/rpm-existing-pr-adoption")
RUN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}")
KINDS = {"issues": "issues.json", "request": "request.json"}
MAX_PAYLOAD_BYTES = 2_000_000


def blocked(reason: str) -> dict[str, object]:
    return {"status": "blocked", "reason": reason}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Write one normalized adoption input under "
            "/tmp/rpm-existing-pr-adoption/<run-id>."
        )
    )
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--kind", choices=sorted(KINDS), required=True)
    parser.add_argument("--payload-base64", required=True)
    return parser.parse_args(argv)


def decode_payload(encoded: str) -> dict[str, object]:
    if not encoded or len(encoded) > MAX_PAYLOAD_BYTES * 2:
        raise ValueError("payload is empty or too large")
    try:
        raw = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("payload is not valid base64") from error
    if len(raw) > MAX_PAYLOAD_BYTES:
        raise ValueError("payload is too large")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("payload is not UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise ValueError("payload must be a JSON object")
    return value


def materialize(run_id: str, kind: str, encoded: str) -> dict[str, object]:
    if not RUN_ID.fullmatch(run_id):
        return blocked("run-id-invalid")
    filename = KINDS.get(kind)
    if filename is None:
        return blocked("kind-invalid")
    try:
        payload = decode_payload(encoded)
    except ValueError as error:
        return blocked(str(error))

    run_dir = RUN_ROOT / run_id
    target = run_dir / filename
    temporary_path: Path | None = None
    try:
        RUN_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
        if RUN_ROOT.is_symlink() or not RUN_ROOT.is_dir():
            return blocked("materialization-root-invalid")
        if run_dir.exists() and (run_dir.is_symlink() or not run_dir.is_dir()):
            return blocked("run-directory-invalid")
        run_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        if run_dir.is_symlink() or not run_dir.is_dir():
            return blocked("run-directory-invalid")
        # The fixed root and validated single-component run ID keep both the
        # temporary file and final destination inside this one per-run handoff.
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=run_dir,
            prefix=f".{filename}.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(
                json.dumps(
                    payload,
                    ensure_ascii=False,
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\n"
            )
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, target)
        temporary_path = None
    except OSError as error:
        return blocked(f"materialization-failed:{error}")
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass
    return {
        "status": "materialized",
        "kind": kind,
        "run_id": run_id,
        "path": str(target),
    }


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    result = materialize(args.run_id, args.kind, args.payload_base64)
    print(
        json.dumps(
            {"type": "existing_pr_adoption_materialized", "data": result},
            sort_keys=True,
        )
    )
    return 0 if result.get("status") == "materialized" else 1


if __name__ == "__main__":
    raise SystemExit(main())
