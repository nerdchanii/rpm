---
name: prepare-backlog
description: Explicit or scheduled entry point for capturing RPM ideas and advancing Project backlog research.
argument-hint: "[capture <idea> | research-cycle]"
disable-model-invocation: true
---

# Prepare Backlog

요구 도구: Agent·Read·Bash.

## Role

Act as the explicit user or scheduled entry point for RPM backlog preparation. Delegate all routing to `rpm_workflow_manager`. GitHub Project and lifecycle policy come from `.agents/workflows/backlog-policy.json`.

## Modes

### Capture

Use `capture <idea>` for one concrete user idea. The invocation authorizes creation of at most one bounded GitHub issue after duplicate checking. Supply:

- the user's original intent and desired outcome;
- known constraints, exclusions, and open questions;
- repository identity;
- `may_create_issue=true`.

The created issue begins in the policy-defined research state and is registered in the policy-defined Project.

### Research Cycle

Use `research-cycle` manually or from a scheduled run. The router advances only the policy-defined research batch. A cycle gathers current evidence, judges readiness, updates the managed research section, and applies an allowed lifecycle transition.

`no-work` is a healthy terminal result. Report it concisely and make no retry in the same run.

## Entry Workflow

1. Read `.agents/workflows/backlog-policy.json`.
2. Run the local Project preflight with `bash scripts/check-agent-backlog-access.sh --format jsonl`.
3. Spawn only `rpm_workflow_manager` with:
   - `workflow=prepare-backlog`
   - `mode=capture|research-cycle`
   - repository scope
   - the idea payload for capture
   - exact mutation authorization
4. Wait for its structured result.
5. Inspect created or refined issue URLs, Project registration, lifecycle changes, research evidence, and blockers.
6. Report duplicate and no-work results as successful terminal outcomes.
7. When blocked, report the decision, permission, or external state required. Do not silently create a replacement issue or alter another lifecycle state.

The router owns detailed routing. Do not duplicate its manager or leaf map here.

## Scheduled Use

A scheduled research cycle uses the policy batch limit and may update only managed research sections and allowed lifecycle labels. Schedule ticket execution separately through `$take-ticket scheduled`. This separation keeps backlog research and implementation independently retryable.

Project #7 is the local roadmap and backlog-preparation inventory. Capture and research-cycle require its registration and read/write access. Cloud ticket execution uses open issue lifecycle labels and does not consume this Project inventory.
