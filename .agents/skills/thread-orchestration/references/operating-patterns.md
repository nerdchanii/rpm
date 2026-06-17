# Thread Orchestration Operating Patterns

## Model And Effort Mapping

Main-session preference:

- Use a cheap main session such as `gpt-5.4-mini` with `thinking: "low"` for pure orchestration.
- Use `thinking: "medium"` only when callback classification or next-role selection is ambiguous.
- Put expensive reasoning into role-specific background threads.

Map user shorthand to available `create_thread` or `send_message_to_thread` fields:

- `5.5 high`, `5.5high`: `model: "gpt-5.5"`, `thinking: "high"`
- `5.5 medium`, `5.5-medium`: `model: "gpt-5.5"`, `thinking: "medium"`
- If the user names another available model or effort, pass it through.
- If the user does not specify model or effort, omit those fields.

## Normal Mode Delegation Criteria

Default to delegation for non-trivial work. The main session should usually coordinate, classify callbacks, and choose the next role while background threads do deeper work.

Delegate to a separate Codex thread when any of these are true:

- Work can be expressed as a bounded role with clear allowed and forbidden actions.
- Independent review, verification, or research would reduce blind spots.
- The task benefits from isolation from the main conversation context.
- A smaller/cheaper main session can coordinate while a stronger model handles deep reasoning.
- The delegated thread can report a structured callback that the main session can route.
- The work is long-running enough that a background thread reduces main-session noise.
- The work naturally splits into roles such as review, implementation, research, reproduction, verification, audit, or documentation.

Work directly only when any of these are true:

- The user asked the current session to do the work directly.
- The task is a small edit, simple command, or single obvious answer.
- The callback target cannot be identified.
- The background thread would need broad destructive authority.
- The role boundaries are unclear enough that a background thread would guess.
- The user asked for a subagent specifically; use subagent tooling instead of thread tools.

## Standard Loop

1. Identify the main callback thread id.
   - Use known thread context if available.
   - Otherwise use `list_threads` only when needed and choose the active current-project thread only when unambiguous.
2. Create the first background thread with `create_thread`.
3. Wait for callback in the main session. Do not poll by repeatedly reading the thread.
4. Classify callback:
   - Terminal success: `NO_ISSUES`, `DONE`, `VERIFY_PASS`
   - Actionable work: issue list, patch request, failed validation, missing evidence
   - Blocked: missing access, ambiguity, command failure, conflicting instructions
5. If actionable work remains, create the next role-appropriate background thread and include the full callback.
6. Repeat until terminal success or blocked.
7. Final response should name thread ids used, terminal result, validation, and residual risk.

## Prompt Template

```text
You are the <role> thread for <project/task>.

Scope:
- <specific files, repo state, issue, artifact, or URL>

Rules:
- <what this thread may do>
- <what this thread must not do>
- Preserve unrelated worktree changes.

Input:
<task packet or previous callback>

When done, send a message to thread <main-thread-id>.
Start the message with <PREFIX>.
Include:
- status
- changed files or findings
- validation performed
- remaining risks/blockers
```

## Common Role Pairs

- Review -> Implementation -> Review: use for code or workflow changes until `NO_ISSUES`.
- Research -> Implementation -> Verification: use when current facts must be gathered before edits.
- Planner -> Executor -> Auditor: use when the task needs a bounded plan before mutation.
- Reproducer -> Fixer -> Verifier: use for bugs where one thread should isolate the failure and another should patch it.

## Callback Prefixes

- `REVIEW_DONE`: contains `NO_ISSUES` or actionable review issues.
- `IMPLEMENTATION_DONE`: contains changed files, validation, and residual risks.
- `RESEARCH_DONE`: contains evidence, sources, and open questions.
- `VERIFY_DONE`: contains pass/fail status and validation commands.
- `BLOCKED`: contains the exact blocker and what input or access is needed.

## Malformed Or Incomplete Callbacks

If the callback is malformed but usable, continue with the usable content and ask the next thread to normalize its final report.

If the callback omits critical fields, send one follow-up to the same background thread asking for the missing fields instead of creating a new thread.

If a background thread reports `BLOCKED`, do not guess. Either provide the missing input, create a different role thread with the blocker as input, or report the blocker to the user.
