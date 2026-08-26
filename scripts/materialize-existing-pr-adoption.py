#!/usr/bin/env python3
"""Materialize one normalized existing-PR adoption handoff in a confined run dir."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
import secrets
import stat
import sys
from pathlib import Path


RUN_ROOT = Path("/tmp/rpm-existing-pr-adoption")
RUN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}")
KINDS = {
    "issues": "issues.json",
    "prepared": "prepared.json",
    "request": "request.json",
}
MAX_PAYLOAD_BYTES = 2_000_000
DIRECTORY_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_NOFOLLOW", 0)
)
FILE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)


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
    payload = parser.add_mutually_exclusive_group(required=True)
    payload.add_argument("--payload-base64")
    payload.add_argument(
        "--payload-stdin",
        action="store_true",
        help="read the UTF-8 JSON object from stdin to avoid argv size limits",
    )
    return parser.parse_args(argv)


def decode_payload_bytes(raw: bytes) -> dict[str, object]:
    if not raw or len(raw) > MAX_PAYLOAD_BYTES:
        raise ValueError("payload is empty or too large")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("payload is not UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise ValueError("payload must be a JSON object")
    return value


def decode_payload(encoded: str) -> dict[str, object]:
    if not encoded or len(encoded) > MAX_PAYLOAD_BYTES * 2:
        raise ValueError("payload is empty or too large")
    try:
        raw = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("payload is not valid base64") from error
    return decode_payload_bytes(raw)


def _open_private_directory(parent_fd: int, name: str) -> int:
    try:
        os.mkdir(name, mode=0o700, dir_fd=parent_fd)
    except FileExistsError:
        pass
    try:
        directory_fd = os.open(name, DIRECTORY_FLAGS, dir_fd=parent_fd)
    except OSError as error:
        raise ValueError("private directory cannot be opened safely") from error
    try:
        metadata = os.fstat(directory_fd)
    except OSError as error:
        os.close(directory_fd)
        raise ValueError("private directory metadata cannot be read safely") from error
    permissions = stat.S_IMODE(metadata.st_mode)
    current_uid = os.geteuid() if hasattr(os, "geteuid") else os.getuid()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != current_uid
        or permissions & 0o077
        or permissions & 0o700 != 0o700
    ):
        os.close(directory_fd)
        raise ValueError("private directory ownership or permissions are invalid")
    return directory_fd


def _open_handoff_directory(run_id: str) -> tuple[int, int]:
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        raise ValueError("platform lacks no-follow directory support")
    try:
        parent_path = RUN_ROOT.parent.resolve(strict=True)
    except OSError as error:
        raise ValueError("handoff parent directory is unavailable") from error
    parent_fd = os.open(parent_path, DIRECTORY_FLAGS)
    try:
        root_fd = _open_private_directory(parent_fd, RUN_ROOT.name)
    except BaseException:
        os.close(parent_fd)
        raise
    try:
        run_fd = _open_private_directory(root_fd, run_id)
    except BaseException:
        os.close(root_fd)
        os.close(parent_fd)
        raise
    os.close(parent_fd)
    return root_fd, run_fd


def _write_atomically(run_fd: int, filename: str, payload: bytes) -> None:
    temporary_name: str | None = None
    temporary_fd: int | None = None
    try:
        for _ in range(8):
            candidate = f".{filename}.{secrets.token_hex(16)}.tmp"
            try:
                temporary_fd = os.open(
                    candidate,
                    FILE_FLAGS,
                    0o600,
                    dir_fd=run_fd,
                )
            except FileExistsError:
                continue
            temporary_name = candidate
            break
        if temporary_fd is None or temporary_name is None:
            raise OSError("could not allocate a unique temporary handoff")
        with os.fdopen(temporary_fd, "wb") as temporary:
            temporary_fd = None
            temporary.write(payload)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(
            temporary_name,
            filename,
            src_dir_fd=run_fd,
            dst_dir_fd=run_fd,
        )
        temporary_name = None
        os.fsync(run_fd)
    finally:
        if temporary_fd is not None:
            os.close(temporary_fd)
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=run_fd)
            except FileNotFoundError:
                pass


def materialize(
    run_id: str,
    kind: str,
    encoded: str | None = None,
    raw_payload: bytes | None = None,
) -> dict[str, object]:
    if not RUN_ID.fullmatch(run_id):
        return blocked("run-id-invalid")
    filename = KINDS.get(kind)
    if filename is None:
        return blocked("kind-invalid")
    try:
        if encoded is not None and raw_payload is not None:
            return blocked("payload-source-ambiguous")
        payload = (
            decode_payload(encoded)
            if encoded is not None
            else decode_payload_bytes(raw_payload or b"")
        )
    except ValueError as error:
        return blocked(str(error))

    root_fd: int | None = None
    run_fd: int | None = None
    try:
        root_fd, run_fd = _open_handoff_directory(run_id)
        serialized = (
            json.dumps(
                payload,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")
        _write_atomically(run_fd, filename, serialized)
    except (OSError, ValueError) as error:
        return blocked(f"materialization-failed:{error}")
    finally:
        if run_fd is not None:
            os.close(run_fd)
        if root_fd is not None:
            os.close(root_fd)
    return {
        "status": "materialized",
        "kind": kind,
        "run_id": run_id,
        "path": str(RUN_ROOT / run_id / filename),
    }


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    raw_payload = None
    if args.payload_stdin:
        raw_payload = sys.stdin.buffer.read(MAX_PAYLOAD_BYTES + 1)
    result = materialize(
        args.run_id,
        args.kind,
        encoded=args.payload_base64,
        raw_payload=raw_payload,
    )
    print(
        json.dumps(
            {"type": "existing_pr_adoption_materialized", "data": result},
            sort_keys=True,
        )
    )
    return 0 if result.get("status") == "materialized" else 1


if __name__ == "__main__":
    raise SystemExit(main())
