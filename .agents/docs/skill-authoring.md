# RPM Skill Authoring

Use progressive disclosure:

- `SKILL.md`: discovery-triggered instructions only. Keep role, routing, critical rules, and when to read references.
- `references/*`: detailed workflows, prompt templates, schemas, examples, decision taxonomies, and checklists.
- `scripts/*`: deterministic executable helpers. Prefer scripts for repeated fragile command logic.
- `assets/*`: templates or files copied into outputs. Do not put instructions here.
- `agents/openai.yaml`: UI metadata only. Keep it short and make `default_prompt` mention `$skill-name`.
- `.codex/agents/*`: background/subagent configuration, not skill instructions. Link to skills or scripts instead of duplicating long procedures.

Avoid long inline prompt templates in `SKILL.md`. Put them in `references/` and point to the file from `SKILL.md`.

For thread-based workflows, put normal-mode delegation criteria in the skill or a reference. Keep the distinction clear: Codex threads are user-visible sessions; subagents are separate execution helpers.

Do not create README-style extras inside skills. Add only files that the agent should read or execute.
