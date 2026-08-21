# RPM Worker Contract

The main session includes these fields in every worker prompt:

```text
ROLE: RPM worker role
OBJECTIVE: one-sentence objective
SCOPE: exact issue or local scope
OWNERSHIP: disjoint files or modules
ALLOWED: read, commands, and explicitly authorized writes
FORBIDDEN: other ownership, lifecycle mutation, merge, and unapproved publish
INPUTS: node_id, attempt, base_revision, plan_revision, scope_hash, executor, prior results
DONE_WHEN: observable acceptance and validation conditions
REPORT: node_id, attempt, state, changed files, commit SHA, tests, risks, blockers
```

The main session assigns the exact current `node_id` and non-negative `attempt`
in every dispatch. The worker repeats both values in its report. The main
session rejects a report whose node or attempt differs from the current plan,
including late results from a timed-out or cancelled attempt. The worker reports
observable evidence. It does not claim a gate or integration step that it did
not execute.
