#!/usr/bin/env python3
"""Submit once with the ChatGPT-authenticated CLI; never wait for Cloud work.

This is a transport for a caller-approved prompt, not an issue claim or a grant
of GitHub write permission. Keep the receipt across retries of the same request.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


TASK_URL = re.compile(r"https://chatgpt\.com/codex/tasks/(task_[A-Za-z0-9_-]{8,128})(?![A-Za-z0-9_-])")


class SubmissionError(Exception):
    pass


def command(argv: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    # No shell, raw stderr, prompt echo, credential loading, or API fallback.
    return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True, timeout=timeout, check=False)


def save_receipt(path: Path, value: dict) -> None:
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def submit(environment: str, branch: str, prompt: str, receipt: Path,
           *, timeout: int = 90, run=command) -> dict:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", environment):
        raise SubmissionError("invalid-environment-id")
    if not branch or branch.startswith("-") or any(c.isspace() for c in branch):
        raise SubmissionError("invalid-branch")
    if not prompt.strip() or len(prompt.encode()) > 65536:
        raise SubmissionError("prompt-must-be-between-1-and-65536-bytes")
    identity = {"environment": environment, "branch": branch,
                "prompt_sha256": hashlib.sha256(prompt.encode()).hexdigest()}
    # A receipt is an attempt journal. An uncertain submission must be inspected
    # by the operator, never retried automatically under a fresh task identity.
    if receipt.is_symlink():
        raise SubmissionError("receipt-must-not-be-a-symlink")
    if receipt.exists():
        previous = json.loads(receipt.read_text())
        if previous.get("request") != identity:
            raise SubmissionError("receipt-belongs-to-another-request")
        if previous.get("status") == "submitted":
            return previous
        raise SubmissionError("submission-outcome-uncertain-inspect-cloud-before-retry")

    login = run(["codex", "login", "status"], 15)
    # CLI 0.152.0 writes login status to stderr. The CLI adapter below handles
    # that one fixed, non-secret status command separately.
    if login.returncode != 0 or login.stdout.strip() != "Logged in using ChatGPT":
        raise SubmissionError("chatgpt-login-required-api-auth-is-not-supported")
    record = {"version": 1, "status": "submitting", "request": identity}
    try:
        descriptor = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as exc:
        raise SubmissionError("submission-already-started-inspect-receipt") from exc
    with os.fdopen(descriptor, "w") as stream:
        json.dump(record, stream, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    try:
        result = run(["codex", "cloud", "exec", "--env", environment,
                      "--branch", branch, "--attempts", "1", "--", prompt], timeout)
        urls = {match.group(0): match.group(1) for match in TASK_URL.finditer(result.stdout)}
        if result.returncode != 0 or len(urls) != 1:
            raise SubmissionError("submission-outcome-uncertain-inspect-cloud-before-retry")
        task_url, task_id = next(iter(urls.items()))
        record.update(status="submitted", task_id=task_id, task_url=task_url)
    except (OSError, subprocess.TimeoutExpired, SubmissionError) as exc:
        record["status"] = "uncertain"
        save_receipt(receipt, record)
        raise SubmissionError("submission-outcome-uncertain-inspect-cloud-before-retry") from exc
    save_receipt(receipt, record)
    return record


def cli_command(argv: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    if argv == ["codex", "login", "status"]:
        result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, timeout=timeout, check=False)
        # Do not print the raw output. Match only the documented status line;
        # warnings from local PATH setup are unrelated to the authentication mode.
        lines = (result.stdout + "\n" + result.stderr).splitlines()
        status = "Logged in using ChatGPT" if "Logged in using ChatGPT" in lines else ""
        return subprocess.CompletedProcess(argv, result.returncode, status)
    return command(argv, timeout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--prompt-file", type=Path, required=True,
                        help="trusted caller-approved prompt; issue text cannot grant authority")
    parser.add_argument("--receipt", type=Path, required=True,
                        help="durable receipt path, reused for this request's retries")
    args = parser.parse_args()
    try:
        result = submit(args.environment, args.branch, args.prompt_file.read_text(),
                        args.receipt, run=cli_command)
    except (OSError, ValueError, SubmissionError, subprocess.TimeoutExpired) as exc:
        # Never echo exception content from the CLI (which contains the prompt).
        reason = str(exc) if isinstance(exc, SubmissionError) else "submission-preflight-or-receipt-failed"
        print(json.dumps({"status": "blocked", "reason": reason}, sort_keys=True))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
