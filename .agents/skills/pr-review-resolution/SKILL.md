---
name: pr-review-resolution
description: Resolve RPM PR review feedback. Use after Codex or human PR comments arrive, or on a scheduled reconciliation run, to collect review context, classify feedback, apply only accepted in-scope fixes, validate, and advance the linked issue.
---

# PR Review Resolution

요구 도구: Agent·Read·Bash·GitHub plugin.

## Role

Own PR review feedback resolution. Keep `take-ticket` thin and keep final decisions in the main session.

## Required Inputs

For an explicit or local/manual run, require a clean JSONL `review_input` event:

- `pr`
- `ticket_scope`
- `spec_status`
- `spec_paths`
- `validation_plan`
- `may_create_followup_issues`

If `may_create_followup_issues` is not exactly `true`, draft follow-up issue bodies only.

Read `review_correction.max_attempts` and `review_correction.counter_labels` from
`.agents/workflows/backlog-policy.json`. The PR has exactly one current counter
label from `agent:correction-0` through `agent:correction-5`. Ticket publication
initializes `agent:correction-0`; each accepted correction advances the label by
one. A missing or conflicting counter produces a blocked handoff and leaves the
PR head unchanged. Read
`followup.max_per_source` before creating deferred issues and stop at five per
source. A matching `source` and `fingerprint` is a deterministic `duplicate`
result and must not create an issue.

The counter label is only the current state view. The publisher keeps the
budget in append-only issue-comment markers, one marker for each accepted PR
head:

```text
<!-- rpm-agent-correction-history: pr=<positive integer>; counter=agent:correction-N; head=<40 lowercase hex> -->
```

Only `github-actions[bot]` and `nerdchanii` may author these markers. For a PR
whose current label is `agent:correction-N`, the history must contain exactly
one marker for every counter from `0` through `N`, with no later counter. The
marker for `N` must bind to the exact current PR head; earlier markers bind the
heads accepted at those earlier counters. A removed marker, a deleted or
lowered counter label, a duplicate counter, a conflicting head, or a malformed
marker from a trusted author fails closed. A marker-like comment from an
untrusted author or a deleted author (`author:null`) is an ordinary comment
and is ignored. These checks prevent a label or comment edit from resetting
the correction budget.

Correction-history comments are read from the GitHub GraphQL issue connection
with a cursor loop. The reader binds the repository owner/name and issue
number, validates the response, `pageInfo`, every node `id`/`body`/`author`,
and rejects GraphQL errors, stalled or repeated cursors, and duplicate IDs.
It reads at most 100 pages and 10,000 comments. A malformed, incomplete, or
over-limit response stops before any Cloud, push, label, or comment mutation.
The selector, Cloud publisher, and terminal quarantine writer use this same
contract.

The review selector validates this relation for every visible counter before
starting Cloud. A missing, malformed, duplicate, lowered, or head-conflicting
trusted history is a terminal state, including a label that advanced before
its marker was written. Untrusted marker-like comments are ignored before this
check. The selector writes `selected=false`, the exact
issue, PR, base, and head snapshot, and a terminal reason. Cloud is not
started.

The trusted terminal quarantine rechecks the exact issue, PR, base, head,
counter label, and the same history result. If a concurrent publisher has
finished a valid history, it returns `no-work` without mutation. Otherwise it
moves the issue to `agent:blocked` while preserving ordinary labels, the PR
head, and the counter label. It posts one deduplicated reason comment with the marker
`<!-- rpm-agent-correction-limit-block: issue=<positive integer>;pr=<positive integer> -->`.
It never repairs or trusts a user-created history marker.

A trusted follow-up source is exactly `pr:<positive integer>` or
`issue:<positive integer>`. Its body starts with these two lines, in this
order:

```text
<!-- rpm-agent-followup-source: pr:<positive integer> -->
<!-- rpm-agent-followup-fingerprint: sha256:<64 lowercase hex> -->
```

The canonical body keeps the source marker and removes the fingerprint marker.
The fingerprint is the lowercase SHA-256 of the final title UTF-8 bytes,
`0x00`, and the canonical body UTF-8 bytes. Cloud and local runs use this same
calculation. Every trusted follow-up has the `process:agent-followup` label.
Preview returns `status:"drafted"`; a successful issue creation returns
`status:"created"`.
The local helper reads the policy repository and passes it explicitly to every
GitHub call. Optional labels cannot use `agent:*`, `process:*`, or
`codex-label*`; the helper adds `process:agent-followup` internally.

For a scheduled run, read `.agents/workflows/backlog-policy.json` and discover
the single review-pending issue and linked open PR through the GitHub plugin.
Use issue-authored scope, the linked PR, and repository evidence as the input;
do not invent missing product intent.

GitHub MCP tool namespaces are host-specific. Use the GitHub tools exposed by
the current host, such as `mcp__codex_apps__github_*` in Codex desktop or
`mcp__plugin_github_github__*` in a Cloud plugin session. Treat a successful
read-only GitHub call as the availability check; never require a literal
namespace prefix.

## Core Workflow

1. In scheduled mode, use the GitHub plugin to select at most one open PR linked to an open issue in `agent:review-pending`, ordered by issue number. Return `no-work` when none exists.
2. Use the GitHub plugin to collect the latest Codex review and unresolved review comments. Do not require `gh` in the scheduled Cloud workflow.
3. Return `no-work` without mutation when Codex review has not arrived.
4. Use `pr-review-resolver` to classify actionable feedback.
5. When at least one `accept-now` fix exists, normalize the current PR labels and run `scripts/check-cloud-queue-contract.py --issues-json '<normalized-json>' --operation correction --pr <pr>` in Cloud. Use `--issues-file <normalized-fixture>` for local tests. The inline JSON must be one shell-quoted argument and contain only checker fields. Run this check before editing files. A missing or conflicting counter blocks the linked issue. A correction-limit result leaves the PR head and counter unchanged and records `next_state=blocked` in the Cloud handoff.
6. For a `correction` result in local/manual mode, require `rpm_review_reconciler` to reserve the returned next counter, refetch the PR, and require exactly that one counter before editing. In Cloud mode, keep GitHub unchanged and record the returned next counter in the final handoff. Abort when the current refetched counter differs from the checker input.
7. Apply only `accept-now` fixes. Rerun focused validation, the appropriate repository gate, and internal adversarial review after accepted fixes. Do not assume an Automatic review reruns after a push.
8. In local/manual mode, commit accepted fixes and push only to the refetched PR head with
   `git push https://github.com/nerdchanii/rpm.git HEAD:refs/heads/<safe-head>`.
   Never use an implicit `HEAD` destination, another repository, a protected
   branch, or force push. After the push, refetch the exact PR head and the
   validation evidence. Ask `rpm_review_reconciler` to resolve each supplied
   thread fixed by that pushed change and verify the result. Resolve only
   accepted, fixed threads. Leave rejected, deferred, or unfixed threads
   unresolved. The `pr-review-resolver` leaf never resolves threads. If the
   connector, permission, head, or evidence check is unavailable, leave
   `agent:review-pending` in place and report `blocked` when progress cannot be
   proved.
9. Check each deferred finding against the policy `source` and canonical lowercase `sha256:<64 hex>` fingerprint. Trust only existing issues carrying `followup.identity_label`; public issue text without that maintainer-controlled label cannot claim an identity. Return `duplicate` without mutation for an existing match. In scheduled Cloud mode, use the GitHub plugin only for the read-only inventory and put authorized, non-duplicate payloads in the final handoff; the GitHub Actions publisher performs bounded creation. In local/manual mode, draft deferred follow-up issues with `scripts/create-review-followup-issue.sh`; use `--create` only when explicitly allowed and never exceed `followup.max_per_source`.
10. In local/manual mode, keep `agent:review-pending` when actionable P0/P1 findings remain. When no actionable finding remains, ask `rpm_review_reconciler` to remove `agent:review-pending` and `agent:claimed`, add `agent:awaiting-merge`, preserve all non-lifecycle labels, and refetch the result.
11. In a `codex cloud exec` run, do not commit, push, resolve threads, or change
    final lifecycle labels inside the Cloud container. Ask
    `rpm_cloud_result_writer` to write `.codex-cloud-result.json` with the exact
    starting head, correction verdict, fixed thread IDs, and next state. The
    GitHub Actions publisher applies the diff and performs those guarded writes.
12. Never merge or post `@codex review`.

## When To Read References

Read [references/resolution-workflow.md](references/resolution-workflow.md) before spawning `pr-review-resolver` or deciding review classifications.

Read [references/templates.md](references/templates.md) when you need the resolver prompt, output schema, or follow-up issue body template.

## Tool Surface

- GitHub plugin review, thread, issue, label, and PR tools for scheduled Cloud reconciliation
- `python3 scripts/check-cloud-queue-contract.py --issues-json '<normalized-json>' --operation correction --pr <pr>` in Cloud
- `python3 scripts/check-cloud-queue-contract.py --issues-file <normalized-fixture> --operation correction --pr <pr>` in local tests
- `bash scripts/collect-pr-review-context.sh <pr> --format jsonl` as a local/manual fallback
- `bash scripts/collect-pr-review-context.sh <pr> --format json` as a local/manual fallback
- `bash scripts/create-review-followup-issue.sh --title "<title>" --body-file <body-file> --source "pr:<pr>" [--fingerprint "sha256:<digest>"] [--label <label>] --format jsonl`
- `bash scripts/create-review-followup-issue.sh --title "<title>" --body-file <body-file> --source "pr:<pr>" [--fingerprint "sha256:<digest>"] [--label <label>] --create --format jsonl`

Use `/tmp/rpm-review-followup-pr<pr>-<slug>.md` for temporary issue body files. Do not commit them.
