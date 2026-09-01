# RPM Skill Authoring

Use progressive disclosure:

- `SKILL.md`: discovery-triggered instructions only. Keep role, routing, critical rules, and when to read references.
- `references/*`: detailed workflows, prompt templates, schemas, examples, decision taxonomies, and checklists.
- `scripts/*`: deterministic executable helpers. Prefer scripts for repeated fragile command logic.
- `assets/*`: templates or files copied into outputs. Do not put instructions here.
- `agents/openai.yaml`: short UI and invocation metadata. Make `default_prompt` mention `$skill-name` and keep the policy mapping explicit.
- `.codex/agents/*`: background/subagent configuration, not skill instructions. Link to skills or scripts instead of duplicating long procedures.

## Repository skill inventory and invocation policy

Every directory under `.agents/skills/` is registered below and owns an
`agents/openai.yaml` file. The OpenAI metadata key
`policy.allow_implicit_invocation` defaults to `true`; setting it to `false`
prevents automatic model selection while preserving explicit `$skill-name`
invocation.

| Skill | `allow_implicit_invocation` | Decision |
| --- | --- | --- |
| `adopt-existing-pr` | `false` | Explicit-only authorized existing-PR adoption entry point. |
| `fixture-governance` | `true` | Implicit-eligible deterministic fixture guidance. |
| `merge-gatekeeper` | `false` | Explicit-only scheduled merge owner. |
| `open-pr-review-batch` | `false` | Explicit-only review posting across every open PR. |
| `pr-resolution-loop` | `false` | Explicit-only review-resolution lifecycle transition. |
| `pr-review-resolution` | `false` | Explicit-only actionable review feedback resolution. |
| `prepare-backlog` | `false` | Explicit-only issue capture and research entry point. |
| `rust-analyzer` | `true` | Implicit-eligible local Rust diagnostics; historical compatibility notes remain factual. |
| `safe-direct-merge` | `false` | Explicit-only manual merge path outside the lifecycle queue. |
| `spec-governance` | `true` | Implicit-eligible contract and SPEC consistency guidance. |
| `take-ticket` | `false` | Explicit-only issue claim and execution entry point. |

The eight `false` entries can claim or trigger repository-wide review, issue,
label, or merge lifecycle effects and require an explicit user or scheduled
caller. The three `true` entries provide implicit-eligible local analysis or
guidance and keep implicit discovery available. Tool and sandbox permissions
continue to govern command execution. `take-ticket`, `prepare-backlog`,
`merge-gatekeeper`, and `adopt-existing-pr` also retain their legacy `SKILL.md`
entry guard where the entry point itself must be hidden from model invocation.

The following overlaps are deliberate dispositions for this inventory:

- `pr-resolution-loop` and `pr-review-resolution` overlap in review feedback
  handling. Issue #202 owns the eventual removal of `pr-resolution-loop`;
  `pr-review-resolution` remains canonical. No directory is removed here.
- `merge-gatekeeper` owns the normal `awaiting-merge` queue, while
  `safe-direct-merge` handles explicitly authorized PRs outside that queue.
- `open-pr-review-batch` posts non-blocking reviews; `pr-review-resolution`
  resolves feedback after it exists.
- `take-ticket` executes ready issues; `prepare-backlog` captures or researches
  backlog items.

No other duplicate directory has a mechanically safe removal disposition.
Issue #188 owns Claude validation assets. The repository keeps only factual
historical compatibility notes in skill references, while Codex invocation
behavior is governed by the `agents/openai.yaml` policy above.

Avoid long inline prompt templates in `SKILL.md`. Put them in `references/` and point to the file from `SKILL.md`.

For thread-based workflows, put normal-mode delegation criteria in the skill or a reference. Keep the distinction clear: Codex threads are user-visible sessions; subagents are separate execution helpers.

Do not create README-style extras inside skills. Add only files that the agent should read or execute.
