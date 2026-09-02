# PR Review Resolution Templates

## Review Input Event

```jsonl
{"type":"review_input","data":{"pr":"<number-or-url>","ticket_scope":"<one-sentence-scope>","spec_status":"conforms|violates|stale|missing|not-contract-affecting|unknown","spec_paths":["<path>"],"validation_plan":["<command>"],"may_create_followup_issues":false}}
```

## Resolver Prompt

```text
Use the pr-review-resolver agent for RPM PR review feedback.

Inputs:
- pr: <number-or-url>
- ticket_scope: <scope>
- spec_status: <status>
- spec_paths: <paths-or-none>
- validation_plan: <command>
- may_create_followup_issues: true|false
- followup_identity: `pr:<positive integer>` or `issue:<positive integer>` plus a
  lowercase `sha256:<64 hex>` fingerprint
- followup_body_path_pattern: /tmp/rpm-review-followup-pr<pr>-<slug>.md

Review context:
<paste full JSONL output of: bash scripts/collect-pr-review-context.sh <pr-number> --format jsonl>

Rules:
- Classify every actionable review item.
- Patch only accept-now items.
- For accepted behavior changes, add/update tests or fixtures when relevant.
- Run the delegated validation after accepted changes.
- For deferred items, compute one canonical source-and-SHA-256 identity. The
  body must start with a source marker and fingerprint marker in that order:
  `<!-- rpm-agent-followup-source: pr:<positive integer> -->` and
  `<!-- rpm-agent-followup-fingerprint: sha256:<64 lowercase hex> -->`.
  The canonical body keeps the source marker and removes the fingerprint
  marker. Hash the final title UTF-8 bytes, one NUL byte (`0x00`), and the
  canonical body UTF-8 bytes. Scheduled Cloud runs and the local helper use
  this exact calculation and apply `process:agent-followup`.
- Preview has result status `drafted`; successful creation has result status
  `created`. Duplicate and blocked results keep those exact statuses in both
  paths. Scheduled Cloud runs use the GitHub plugin only to inventory trusted
  identities and return exact `title`, canonical `body`, `source`,
  `fingerprint`, and ordinary `labels` fields in the final handoff. The GitHub
  Actions publisher performs creation. Local/manual runs create body files and
  preview with `scripts/create-review-followup-issue.sh`.
- Local helper `--label` values must be ordinary labels. `agent:*`,
  `process:*`, and `codex-label*` are rejected; `process:agent-followup` is
  added internally. All helper GitHub calls name the policy repository
  explicitly.
- The helper rereads the created issue and verifies its title, body markers,
  fingerprint, and identity label. GitHub has no issue-create compare-and-set;
  concurrent creators remain a residual and are reconciled by a later run.
- Use --create only if may_create_followup_issues=true and no existing issue naturally absorbs the work.
- The `pr-review-resolver` leaf does not resolve GitHub threads. After an
  accepted fix is validated and pushed, its parent caller gives the exact head,
  evidence, and fixed thread IDs to `rpm_review_reconciler`, which resolves only
  those threads with `resolve_review_thread(thread_id)`. Rejected, deferred,
  or unfixed threads stay unresolved.
- Do not make unrelated cleanup.

Return the exact Review Resolver Output shape.
```

## Review Resolver Output

```jsonl
{"type":"review_resolution_result","data":{"status":"complete|no-work|blocked","pr":"<number-or-url-or-empty>","issue":"<number-or-url-or-empty>","review_present":true,"validation":["<command-or-not-run-with-reason>"],"adversarial_review":"pass|findings|not-run","actionable_p0_p1_remaining":false,"final_issue_state":"review-pending|awaiting-merge|blocked|unchanged","decisions":[{"target":"<comment-url-or-thread-id>","classification":"<classification>","reason":"<one-line reason>","action":"<action taken>"}],"changes":[{"path":"<file>","summary":"<summary>"}],"follow_up_issues":[{"status":"created|drafted|duplicate|blocked","url":"<url-or-null>","path":"<draft-path-or-null>","title":"<title>"}],"blockers":[]}}
```

## Follow-Up Issue Body

```markdown
<!-- rpm-agent-followup-source: pr:<positive integer> -->
<!-- rpm-agent-followup-fingerprint: sha256:<64 lowercase hex> -->

## Source

- PR:
- Review comment:
- Classification: defer-contract-change | defer-missing-spec

## Current Contract

- SPEC path: <path or missing>
- Current behavior:

## Proposed Behavior

<Describe the suggested behavior without referencing private notes.>

## Why It May Be Valuable

<Explain product or compatibility value.>

## Required Work

- SPEC update:
- Tests or fixtures:
- Compatibility or migration concerns:
```
