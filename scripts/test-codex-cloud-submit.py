#!/usr/bin/env python3
"""Offline transport tests. Fake CLI responses do not prove a Cloud run."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "submitter", Path(__file__).with_name("submit-codex-cloud-task.py"))
submitter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(submitter)
TASK = "task_1234567890abcdef"
URL = f"https://chatgpt.com/codex/tasks/{TASK}"


class SubmitTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.receipt = Path(self.temporary.name) / "receipt.json"
        self.calls = []

    def cli(self, argv, timeout):
        self.calls.append(argv)
        if argv == ["codex", "login", "status"]:
            return subprocess.CompletedProcess(argv, 0, "Logged in using ChatGPT")
        return subprocess.CompletedProcess(argv, 0, URL + "\n")

    def submit(self, run=None, prompt="Caller-approved task"):
        return submitter.submit("env_123", "main", prompt, self.receipt, run=run or self.cli)

    def test_receipt_returns_immediately_without_polling_or_results(self):
        result = self.submit()
        self.assertEqual(result["status"], "submitted")
        self.assertEqual(result["task_id"], TASK)
        self.assertEqual(self.calls, [["codex", "login", "status"],
            ["codex", "cloud", "exec", "--env", "env_123", "--branch", "main",
             "--attempts", "1", "--", "Caller-approved task"]])
        self.assertNotIn("Caller-approved task", self.receipt.read_text())
        self.assertEqual(self.receipt.stat().st_mode & 0o777, 0o600)

    def test_same_receipt_retry_never_submits_twice(self):
        first = self.submit()
        self.assertEqual(self.submit(), first)
        self.assertEqual(len(self.calls), 2)

    def test_changed_prompt_cannot_reuse_receipt(self):
        self.submit()
        with self.assertRaisesRegex(submitter.SubmissionError, "another-request"):
            self.submit(prompt="Different task")
        self.assertEqual(len(self.calls), 2)

    def test_timeout_is_uncertain_and_retry_is_blocked(self):
        def timeout(argv, seconds):
            if argv[1] == "login":
                return self.cli(argv, seconds)
            self.calls.append(argv)
            raise subprocess.TimeoutExpired(argv, seconds, output=URL)
        with self.assertRaisesRegex(submitter.SubmissionError, "uncertain"):
            self.submit(run=timeout)
        self.assertEqual(json.loads(self.receipt.read_text())["status"], "uncertain")
        with self.assertRaisesRegex(submitter.SubmissionError, "uncertain"):
            self.submit()
        self.assertEqual(len(self.calls), 2)

    def test_missing_or_multiple_task_ids_do_not_claim_submission_success(self):
        for output in ("", "task_1234567890abcdef", URL + " " + URL + "extra"):
            with self.subTest(output=output):
                self.receipt.unlink(missing_ok=True)
                def invalid(argv, seconds):
                    if argv[1] == "login":
                        return self.cli(argv, seconds)
                    return subprocess.CompletedProcess(argv, 0, output)
                with self.assertRaisesRegex(submitter.SubmissionError, "uncertain"):
                    self.submit(run=invalid)

    def test_nonzero_with_task_url_is_uncertain(self):
        def fail(argv, seconds):
            if argv[1] == "login":
                return self.cli(argv, seconds)
            return subprocess.CompletedProcess(argv, 1, URL)
        with self.assertRaisesRegex(submitter.SubmissionError, "uncertain"):
            self.submit(run=fail)

    def test_api_login_does_not_submit(self):
        def api(argv, seconds):
            self.calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, "Logged in using an API key")
        with self.assertRaisesRegex(submitter.SubmissionError, "chatgpt-login-required"):
            self.submit(run=api)
        self.assertEqual(len(self.calls), 1)
        self.assertFalse(self.receipt.exists())

    def test_preexisting_attempt_is_not_retried(self):
        self.submit()
        record = json.loads(self.receipt.read_text())
        record["status"] = "submitting"
        self.receipt.write_text(json.dumps(record))
        with self.assertRaisesRegex(submitter.SubmissionError, "uncertain"):
            self.submit()
        self.assertEqual(len(self.calls), 2)

    def test_shell_text_is_one_prompt_argument(self):
        self.submit(prompt="$(touch /tmp/never) `do-not-run`\nline two")
        self.assertEqual(len(self.calls[-1]), 11)
        self.assertEqual(self.calls[-1][-1], "$(touch /tmp/never) `do-not-run`\nline two")

    def test_leading_hyphen_prompt_is_not_a_cli_option(self):
        self.submit(prompt="- Implement the approved issue")
        self.assertEqual(self.calls[-1][-2:], ["--", "- Implement the approved issue"])

    def test_invalid_inputs_and_symlink_never_call_cli(self):
        with self.assertRaises(submitter.SubmissionError):
            submitter.submit("--bad", "main", "prompt", self.receipt, run=self.cli)
        self.receipt.symlink_to(Path(self.temporary.name) / "missing")
        with self.assertRaises(submitter.SubmissionError):
            self.submit()
        self.assertFalse(self.calls)


if __name__ == "__main__":
    unittest.main()
