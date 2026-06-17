# Ticket PR Lifecycle Prompts And Outputs

## Explorer Prompt

```text
Use the ticket-explorer agent for RPM ticket intake. Do not edit files.

Inputs:
- issue: <number-or-url>
- ticket_packet_jsonl: <full output from scripts/ticket-gen <issue> --format jsonl>
- allowed_read_scope: <repo paths or "repo">

Return JSONL:
{"type":"explorer_result","data":{"status":"complete|blocked","issue_summary":"...","spec_impact":"contract-affecting|not-contract-affecting|unknown","spec_paths":["..."],"fixture_need":"yes|no|unknown","likely_files":["..."],"validation":["..."],"risks":["..."]}}
```

## Draft PR Body Minimum

```markdown
## Contract

SPEC status:
SPEC path:

## Plan

- [ ] Intake passed
- [ ] SPEC impact classified
- [ ] Implementation complete
- [ ] Validation run
- [ ] Review resolution complete

## Validation

Not run yet.

Closes #<issue>
```

## Lifecycle Result

```jsonl
{"type":"ticket_lifecycle_result","data":{"status":"complete|blocked","issue":"<number-or-url>","pr":"<number-or-url>","spec_status":"<status>","validation":["<commands-and-results>"],"next_skill":"pr-review-resolution|none","changed_files":[{"path":"<path>","summary":"<summary>"}],"blockers":[]}}
```
