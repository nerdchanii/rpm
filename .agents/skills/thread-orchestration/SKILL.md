---
name: thread-orchestration
description: Coordinate separate Codex threads via callback messages. Use only when the user explicitly asks to create sessions/threads or run a thread-based loop; not for subagents.
---

# Thread Orchestration

## Purpose

Coordinate user-visible Codex threads created with thread tools. Do not use this skill for subagents.

Use this skill when the user wants one session to create other Codex sessions, route callback messages, and repeat a multi-pass loop such as review -> fix -> verify until a terminal result.

In normal mode, prefer delegation for non-trivial work. Keep the main session as a low-cost coordinator, and use bounded background threads for review, implementation, research, verification, or other role-specific work. Work directly only for small, obvious tasks where a separate thread would add overhead.

## Core Workflow

1. Use `list_projects` before `create_thread` for repo-scoped work.
2. Create a focused background thread with one role, one scope, and one callback prefix.
3. Tell every background thread which main thread to message when done.
4. Do not repeatedly read/poll background threads unless the user asks for status or a callback fails to arrive.
5. Treat callback messages as the handoff contract for the next thread.
6. Stop when a callback reports terminal success, `BLOCKED`, or the user changes direction.

## Required Prompt Fields

Every background thread prompt must include:

- role
- scope
- allowed actions and forbidden actions
- input packet or callback content
- target thread id for callback
- callback prefix
- required report fields: status, findings or changed files, validation, risks/blockers

## When To Read References

Read [references/operating-patterns.md](references/operating-patterns.md) when any of these apply:

- the loop has more than one role pair
- you are deciding whether to delegate in normal mode
- the user specifies model/effort shorthand such as `5.5high` or `5.5-medium`
- you need a prompt template or callback prefix convention
- a callback is malformed, blocked, or incomplete

## Boundaries

- Background threads are not subagents.
- Do not ask background threads to revert user changes unless explicitly requested.
- Do not ask background threads to create public artifacts, commits, pushes, PRs, or issues unless the user explicitly requested that capability.
- Keep validation narrow and aligned with the current repository guidance.
