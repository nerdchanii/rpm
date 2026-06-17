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
- followup_body_path_pattern: /tmp/rpm-review-followup-pr<pr>-<slug>.md

Review context:
<paste full JSONL output of: bash scripts/collect-pr-review-context.sh <pr-number> --format jsonl>

Rules:
- Classify every actionable review item.
- Patch only accept-now items.
- For accepted behavior changes, add/update tests or fixtures when relevant.
- Run the delegated validation after accepted changes.
- For deferred items, create body files and preview issue creation with scripts/create-review-followup-issue.sh.
- Use --create only if may_create_followup_issues=true and no existing issue naturally absorbs the work.
- Do not resolve GitHub threads.
- Do not make unrelated cleanup.

Return the exact Review Resolver Output shape.
```

## Review Resolver Output

```jsonl
{"type":"review_resolution_result","data":{"status":"complete|blocked","pr":"<number-or-url>","validation":["<command-or-not-run-with-reason>"],"decisions":[{"target":"<comment-url-or-thread-id>","classification":"<classification>","reason":"<one-line reason>","action":"<action taken>"}],"changes":[{"path":"<file>","summary":"<summary>"}],"follow_up_issues":[{"state":"opened|drafted","url":"<url-or-null>","path":"<draft-path-or-null>","title":"<title>"}],"blockers":[]}}
```

## Follow-Up Issue Body

```markdown
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
