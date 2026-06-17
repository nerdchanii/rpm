# RPM Agent Contracts

Use these output shapes for `.codex/agents/*` background/subagent configs.

## Ticket Explorer Result

```jsonl
{"type":"explorer_result","data":{"status":"complete|blocked","issue":"<number-or-url>","issue_summary":"<one sentence>","spec_impact":"contract-affecting|not-contract-affecting|unknown","spec_paths":["<path-or-missing>"],"fixture_need":"yes|no|unknown","likely_files":["<path>"],"validation":["<command>"],"risks":["<risk>"],"notes":["<note>"]}}
```

## PR Checklist Result

Preferred dispatch settings: `gpt-5.4-mini`, `thinking=low`. Use `thinking=medium` only for non-mechanical PR body rewrites.

```jsonl
{"type":"pr_checklist_result","data":{"status":"complete|blocked","pr":"<number-or-url>","updated":true,"body_file":"<path-or-null>","changes":[{"section":"<section>","summary":"<summary>"}],"blockers":[]}}
```

## Blocked Rule

When blocked, return the same event type with `status:"blocked"` and list exact missing input, permission problem, or failing command in `blockers`.
