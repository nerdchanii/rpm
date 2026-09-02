# RPM Per-Issue Agent Workflow

This document describes the human-visible organization for one GitHub issue.
Runtime routing authority lives in the workflow and per-issue manager
configuration under `.codex/agents/`. Backlog and lifecycle mechanics live in
`.agents/workflows/backlog-policy.json`.

## Organization

```text
explicit user or scheduled run
└── workflow manager
    └── per-issue manager
        ├── issue fetcher
        ├── SPEC reviewer
        ├── issue/SPEC reconciler
        ├── SPEC updater
        ├── test author
        ├── production implementer
        ├── targeted test runner
        ├── full verifier
        ├── adversarial reviewer
        └── follow-up issue creator
```

The main session owns user decisions, final scope acceptance, commits, pushes,
and the final report. At the two external publication boundaries, the top-level
entry skill calls its dedicated MCP-only writer: `rpm_ticket_publisher` for the
read-only publication checkpoint and final PR publication. The workflow manager is the
single entry router. One per-issue manager owns the process for one issue. Leaf
agents receive only their inputs, scope, and output contract.

## DAG and Worktree Harness

The main session owns the global DAG and final integration. It assigns each
executable node to one worker task with an isolated worktree and a disjoint
write scope. The worker receives the current `plan_revision`, `scope_hash`,
executor, acceptance criteria, and validation contract. Worker output returns
to the main session as evidence and a structured result.

The main session may keep decomposition, dependency analysis, and review as
local worker tasks. A node becomes a GitHub issue when it needs durable state,
permission, recovery, or a PR. This keeps GitHub lifecycle labels aligned with
executable work while allowing internal DAG nodes to remain lightweight.

When decomposition or scope changes, the main session creates a new
`plan_revision` and recomputes `scope_hash`. Existing workers finish only if
their revision still matches. A stale worker returns `blocked` and performs no
mutation. The claim controller binds the issue, revision, scope, executor,
lease, and event id through the policy-defined idempotency key.

## Process

```mermaid
flowchart TD
    A["Workflow manager starts one per-issue manager"] --> B["Fetch issue packet"]
    B --> C["Review owning SPECs"]
    C --> D["Reconcile issue and SPEC"]
    D --> E{"Contract decision clear?"}
    E -- "No" --> X["Return BLOCKED with decision required"]
    E -- "Yes, SPEC edit needed" --> F["Update SPEC"]
    E -- "Yes, SPEC already aligned" --> G["Publication preflight checkpoint"]
    F --> G
    G --> H["Publication writer verifies readiness; main resumes workflow"]
    H --> I["Write regression test or fixture"]
    I --> J["Implement production change"]
    J --> K["Run targeted tests"]
    K --> L{"Targeted tests pass?"}
    L -- "No" --> M["Route one correction"]
    M --> K
    L -- "Yes" --> N["Run just validate"]
    N --> O{"Full verification passes?"}
    O -- "No" --> M
    O -- "Yes" --> P["Adversarial review"]
    P --> Q{"Material in-scope finding?"}
    Q -- "Yes" --> M
    Q -- "Deferred work" --> R["Draft or create authorized follow-up issue"]
    Q -- "No" --> S["Return validated result to main"]
    R --> S
    S --> T["Main commits and pushes explicit safe branch ref"]
    T --> U["Publication writer creates and finalizes review-ready PR"]
```

## Concurrency Rules

- Read-only exploration and independent review may run in parallel.
- SPEC writing, test writing, production implementation, and review-fix writing
  run sequentially.
- Two agents must not edit overlapping files concurrently.
- Concurrent issues require separate worktrees.
- One issue, one active claim lease, and one worker worktree are the default
  execution unit.
- The review correction budget is five. The PR keeps one counter label from
  `agent:correction-0` through `agent:correction-5`; a sixth correction is
  blocked.

## Authority Boundaries

| Role | Repository writes | Command execution | External mutation |
|---|---:|---:|---:|
| Main session | Final integration | As needed | Decisions, commits, pushes, final acceptance |
| Workflow manager | No | No validation | No |
| Per-issue manager | No | No validation | No |
| Issue/SPEC reviewers | No | Read-only discovery | No |
| SPEC updater | `docs/specs/**` only | Narrow checks | No |
| Test author | Tests and fixtures only | No full gate | No |
| Implementer | Approved production paths | No full gate | No |
| Test runner | Read-only workspace | Supplied targeted tests | No |
| Verifier | Read-only workspace | `just validate` | No |
| Adversarial reviewer | No | Read-only inspection | No |
| Follow-up issue creator | Read-only workspace and temporary body | Duplicate check and issue helper | Explicit authorization required |
| Ticket publication writer | No | Connected GitHub plugin reads | Read-only publication checkpoint, validated PR creation, review-ready state, and linked issue transition |
| Review reconciliation writer | No | Connected GitHub plugin reads | Correction counter, verified fixed-thread resolution, and review-pending state transition |
| Merge state writer | No | Connected GitHub plugin reads | Awaiting-merge to blocked transition and deduplicated reason comment |

Codex custom agents use `sandbox_mode = "read-only"` for judgment roles.
Command-only roles redirect Cargo build artifacts to
`/tmp/rpm-codex-target`, keeping the repository read-only. Their outputs include
exact commands and exit codes.

The project tool-policy hooks record each RPM subagent type at start. Leaf
agents are blocked from spawning agents. Read-only roles are blocked from
repository patch tools. Writer patches are constrained by role:

- SPEC updater: `docs/specs/**`
- test author: `tests/**` and explicitly scoped test modules under `src/**`
- implementer: production paths, excluding tests, SPECs, and agent configuration
- PR review resolver: accepted review fixes across production, test, and SPEC
  paths, excluding agent configuration

MCP calls are limited by the project tool-policy hook to each role's assigned
read or mutation boundary. Backlog GitHub writers, issue intake, and authorized
follow-up handling have separate allowlists. The three publication writers are
MCP-only and have no shell, patch, commit, push, or merge access. Unmapped
main-session tool calls remain unaffected.

## Terminal Results

The per-issue manager returns one JSONL `issue_workflow_result` with one of
these states. The workflow manager relays it to the caller:

- `checkpoint`: the main session must invoke `rpm_ticket_publisher` for a read-only publication preflight, then resume the same workflow run.
- `complete`: contract, tests, implementation, validation, and review converged.
- `blocked`: an explicit decision, permission, tool, or unresolved finding prevents safe progress.

Follow-up issue creation follows the committed policy. The automated workflow
currently supplies `may_create_followup_issues=true`, deduplicates by source and
fingerprint among issues carrying `process:agent-followup`, and creates at most
five follow-up issues per source.

## Review Boundary

The adversarial reviewer is an internal correctness gate over the issue, SPEC,
diff, tests, and validation evidence. The ticket workflow marks the validated
PR review-ready and moves the linked issue to review-pending. It does not post,
request, or wait for `@codex review`. Repository-configured Codex Automatic
review runs independently. The scheduled reconciliation workflow applies
accepted findings, moves a converged review to awaiting-merge, and moves a
sixth correction request to blocked.

## Completion Enforcement

The project `SubagentStop` hook matches the per-issue manager. When the manager
returns `status:"complete"`, the hook runs `just validate` with Cargo artifacts
under `/tmp/rpm-codex-target`. Exit code `2` blocks completion when the gate is
red. Checkpoint and blocked results remain returnable so the main session can
make the required decision.

Project hooks require one-time trust review in Codex after their contents
change.
