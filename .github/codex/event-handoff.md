# Cloud submission and PR event handoff

This change implements two bounded pieces: a submit-only CLI transport and a
read-only PR event handler. **It does not enable unattended Cloud delivery.**
Account authentication, automatic PR publication, and host-verifiable claim
authority still prevent a verified end-to-end rollout.

## Intended flow and current implementation

| Boundary | Current evidence / implementation |
| --- | --- |
| Select and claim one issue | Existing queue and claim policy remains authoritative. The current host cannot attest a parent claim handoff; its manual checkpoint remains. |
| Submit Cloud task, retain task ID, exit | `scripts/submit-codex-cloud-task.py` calls `codex cloud exec` once using an existing ChatGPT login. It does not run `codex exec`, poll Cloud status, download a diff, or wait for implementation. |
| Cloud implements and publishes a PR | Cloud background work and opening a PR from the result are documented. Automatic publication without a session approval is unverified. No replacement publisher is installed. |
| PR creation/update starts checks | Existing `Rust` / `verify` and `PR Metadata` / `metadata` workflows remain. Actual workflow behavior depends on the credential used to publish the PR. |
| PR/review/check event selects next owner | `codex-pr-events.yml` refetches the current PR and reports the existing review or merge route. It performs no external mutation or Cloud submission. |
| Review and merge | Existing `pr-review-resolution` and top-level `merge-gatekeeper` retain ownership. The event report is preliminary evidence, not an authorization or a replacement for their fresh checks. |

The workflow checks out the handler scripts from the default branch, with read
permissions only. Event payloads provide identity hints; their check results, text, files,
caches, and artifacts are not executed or trusted as current evidence. This
handler starts operating after it exists on the default branch. A local run
against GitHub before that point proves only the read adapter.

`pull_request_target` covers creation, reopen, push, editing, and review-ready
events. `pull_request_review` covers feedback arrival and changes. GitHub
evaluates that event's workflow YAML from the PR merge ref; it is an advisory,
read-only surface. Its checked-in steps still load the default-branch scripts
and skip intake if they are not deployed yet. This workflow must not acquire
mutation credentials or be used as trusted authorization by a downstream writer.
`workflow_run` covers completion of the two existing check workflows. Empty
PR associations return `no-work`; existing scheduled owners remain the recovery
path for missed events and later lifecycle transitions. There is no new
schedule, Cloud-completion polling loop, lifecycle transition, merge switch,
or rule about when the next issue starts.

An untracked existing PR is reported as needing authorized adoption. The
event handler does not infer adoption permission from the existence of a PR.
This keeps the eventual narrow adoption entry in the common review/merge
path without importing the separate ledger and merge authority from PR #233.

## Submit-only transport

Run on a trusted, already signed-in machine with CLI 0.152.0. The prompt must
come from the authorized caller and preserve the issue's scope and the
repository claim contract; copying issue text into a prompt grants no new
authority. This command does not select or claim an issue on the caller's behalf.

```sh
codex login status
python3 scripts/submit-codex-cloud-task.py \
  --environment '<verified RPM Cloud environment ID>' \
  --branch main \
  --prompt-file /absolute/path/approved-prompt.txt \
  --receipt /absolute/path/request-receipt.json
```

The output is `submitted` with a task ID and URL, never `complete`. The receipt
contains the environment, branch and prompt digest, not the prompt or auth.
Reuse the same receipt for a retry of the same request. A known submission
returns the recorded identity without another Cloud call. A timeout, interrupted
submission, nonzero exit, or unrecognized output leaves an uncertain attempt;
inspect that attempt in Cloud before deciding what to do. A new receipt is a
new request and can create another task. This is local duplicate suppression,
not a claim that the Cloud API offers an idempotency key.

Only the transport's direct call is bounded by a timeout. The remote task's
lifetime is independent. No task status is fetched by the transport.

## Official support boundary (checked 2026-09-13)

- [Developer commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli)
  documents `codex cloud exec --env`, best-of-N attempts, shared CLI
  authentication, and nonzero submission failure. Cloud commands are marked
  experimental. This does not establish a stable machine-readable submission
  receipt or automatic PR publication.
  The pinned [0.152.0 CLI implementation](https://github.com/openai/codex/blob/rust-v0.152.0/codex-rs/cloud-tasks/src/lib.rs#L178-L200)
  prints the created task URL; its
  [URL formatter](https://github.com/openai/codex/blob/rust-v0.152.0/codex-rs/cloud-tasks/src/util.rs#L136-L149)
  supplies the production `/codex/tasks/{task_id}` form parsed by the transport.
- [Account authentication in CI](https://learn.chatgpt.com/docs/auth/ci-cd-auth)
  limits the managed `auth.json` pattern to trusted private automation and
  explicitly says: “Do not use this workflow for public or open-source
  repositories.” RPM is public. No subscription credential export, CI secret
  injection workflow, refresh workaround, or API-key fallback is introduced.
  Moving a runner into a private controller repository has not been verified
  as an exception for this public target.
- [Codex Cloud](https://learn.chatgpt.com/docs/cloud) documents independent
  background work and opening a PR after reviewing the result.
  [GitHub integration](https://learn.chatgpt.com/docs/third-party/github)
  describes connected repository access. Neither establishes that this
  account's background task can create a PR without further interaction,
  which credential it uses, or whether host approval review will allow it.
- [GitHub token behavior](https://docs.github.com/en/actions/concepts/security/github_token)
  currently says `GITHUB_TOKEN`-generated `opened`, `synchronize`, and
  `reopened` PR events create approval-required runs. Other PR activity types
  do not create runs. A separate GitHub App installation token or PAT can
  trigger these runs without that particular approval. An actor name alone
  does not prove which credential was used. The submit job's `GITHUB_TOKEN`
  also expires when that job finishes; it is not a durable Cloud credential.

The repository's separate approval gap is concrete:
`.codex/agents/rpm_ready_ticket_claimer.toml` and
`.codex/hooks/agent_tool_policy.py:trusted_claim_authorization` stop automatic
claim mutation until the host supplies verifiable parent authority. Repeating
approval prose in a task or manufacturing a claim token does not resolve this.
No authorization hook or previously denied operation is bypassed here.

## Rollout decision still required

The concrete account/host prerequisite is a supported GitHub publication
capability **inside the background Cloud task**, with verifiable claim
authority. The live probe below did not expose it despite using an existing
connected RPM environment. No documented account switch was found that supplies
these capabilities. Confirm this support with the host before enabling any
submission workflow; do not ask the owner to paste credentials or repeat an
approval into each task.

After that prerequisite is met, verify one intended PR's current head and
matching `pull_request` Actions runs, including any approval-required state.
A human clicking **Create PR** can validate the PR-to-Actions half; record that
human step and do not call it autonomous Cloud publication.

This single check will not itself solve the public-CI subscription-auth or
host claim-authority gaps. Those require a supported product/authentication
path. One missing secret or repeated user approval is not an evidenced fix.

## Integration with existing work

Inspected base: `main` at `fb7eb380e9484222b44b9316439faa5bcab4b901`.
PR #246 at `d8afb52e8498770263f5ca9c90c41011b1f40554` and PR #233 at
`16b7df576fa49104fa1b20a3835de3410e2543fc` were open and conflicting.

PR #246's three result-polling lanes and Actions publisher are not imported.
PR #233's broad adoption ledger and two-stage merge authorization are not
imported. Both existing PRs remain available for separate disposition.
The policy, mandatory `metadata`/`verify` checks, strict protected `main`,
current merge owner, and unrelated worktree changes remain intact.

## Validation

On 2026-09-13, the owner account's Cloud UI showed an existing `nerdchanii/rpm`
environment. A bounded read-only capability probe was submitted from the
already ChatGPT-authenticated local CLI through this transport. It returned
`submitted`, task `task_e_6aa6a00a5fac8328abb3a6d9b278e373`, and exit 0.
A separate status read after the submitter exited showed `PENDING` with no
diff. The [Cloud probe](https://chatgpt.com/codex/tasks/task_e_6aa6a00a5fac8328abb3a6d9b278e373)
then completed, and its final report and execution logs were inspected in the
account UI. The report identified only `mcp__make_pr__make_pr` as PR-specific;
its described function records title/body metadata and does not establish
authenticated GitHub publication. No dedicated GitHub read/write capability
or verified parent authorization was exposed to that run. Its shell log showed
no Git remotes, an installed `gh` binary, and an empty final
`git status --porcelain=v2`. Authentication and mutations were not attempted.

This verifies local subscription-authenticated submission, independent remote
execution after local exit, and completion of a read-only probe. It does not
verify Actions authentication, automatic PR publication, an actual mutation
approval or rejection, or a Cloud-to-PR-to-Actions cycle.

`just agent-events` runs offline process-boundary and event-routing tests.
Their fake CLI/GitHub responses prove the code paths and failure handling;
they are not evidence of a real Cloud task or PR publication. The same checks
are included in `just validate` and the existing `verify` workflow.

The final task/PR report records actual local gate results and any live
read-only GitHub checks separately. Actions-based Cloud submission, autonomous PR
publication, and an end-to-end Cloud-to-Actions run remain unverified unless
that report includes their actual IDs and outcomes.
