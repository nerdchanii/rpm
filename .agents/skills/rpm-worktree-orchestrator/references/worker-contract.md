# RPM Worker Contract

The main session includes these fields in every worker prompt:

```text
ROLE: RPM worker role
OBJECTIVE: one-sentence objective
SCOPE: exact issue or local scope
OWNERSHIP: disjoint files or modules
ALLOWED: read, commands, and explicitly authorized writes
FORBIDDEN: other ownership, lifecycle mutation, merge, and unapproved publish
INPUTS: base_revision, plan_revision, scope_hash, executor, prior results
DONE_WHEN: observable acceptance and validation conditions
REPORT: state, changed files, commit SHA, tests, risks, blockers
```

The worker reports observable evidence. It does not claim a gate or integration
step that it did not execute.
