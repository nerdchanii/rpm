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

The main session owns user decisions, final scope acceptance, Draft PR creation,
commits, pushes, PR state, and the final report. The workflow manager is the
single entry router. One per-issue manager owns the process for one issue. Leaf
agents receive only their inputs, scope, and output contract.

## Process

```mermaid
flowchart TD
    A["Workflow manager starts one per-issue manager"] --> B["Fetch issue packet"]
    B --> C["Review owning SPECs"]
    C --> D["Reconcile issue and SPEC"]
    D --> E{"Contract decision clear?"}
    E -- "No" --> X["Return BLOCKED with decision required"]
    E -- "Yes, SPEC edit needed" --> F["Update SPEC"]
    E -- "Yes, SPEC already aligned" --> G["Draft PR checkpoint"]
    F --> G
    G --> H["Main creates Draft PR and resumes workflow"]
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
    Q -- "No" --> S["Return complete result to main"]
    R --> S
```

## Concurrency Rules

- Read-only exploration and independent review may run in parallel.
- SPEC writing, test writing, production implementation, and review-fix writing
  run sequentially.
- Two agents must not edit overlapping files concurrently.
- Concurrent issues require separate worktrees.
- The default correction-loop budget is two.

## Authority Boundaries

| Role | Repository writes | Command execution | External mutation |
|---|---:|---:|---:|
| Main session | Final integration | As needed | Commits, pushes, PR state |
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
follow-up handling have separate allowlists. Unmapped main-session tool calls
remain unaffected.

## Terminal Results

The per-issue manager returns one JSONL `issue_workflow_result` with one of
these states. The workflow manager relays it to the caller:

- `checkpoint`: the main session must create the Draft PR and resume the same workflow run.
- `complete`: contract, tests, implementation, validation, and review converged.
- `blocked`: an explicit decision, permission, tool, or unresolved finding prevents safe progress.

Follow-up issue creation defaults to disabled. A valid finding produces a draft
until `may_create_followup_issues=true` is supplied.

## Review Boundary

The adversarial reviewer is an internal correctness gate over the issue, SPEC,
diff, tests, and validation evidence. The ticket workflow marks the validated
PR review-ready and moves the linked issue to review-pending. It does not post,
request, or wait for `@codex review`. Repository-configured Codex Automatic
review runs independently. The scheduled reconciliation workflow applies
accepted findings and moves an exhausted review to awaiting-merge.

## Completion Enforcement

The project `SubagentStop` hook matches the per-issue manager. When the manager
returns `status:"complete"`, the hook runs `just validate` with Cargo artifacts
under `/tmp/rpm-codex-target`. Exit code `2` blocks completion when the gate is
red. Checkpoint and blocked results remain returnable so the main session can
make the required decision.

Project hooks require one-time trust review in Codex after their contents
change.
