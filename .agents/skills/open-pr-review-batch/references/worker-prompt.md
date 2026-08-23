# Open PR Review Batch — Worker Prompt Template

Spawn one agent per PR with this prompt, substituting `<PR>`, `<TITLE>`, and a
one-line theme. Run all reviewers in one message (parallel, background).

---

You are one of several PARALLEL code-review agents. Review ONE open PR in the
`rpm` repo and post a single COMMENT review. REVIEW ONLY — do not modify code.

REPO: `rpm`, a Rust package-manager prototype. Working dir is the repo root.
Sources of truth: `AGENTS.md` (code-review rules, change discipline),
`docs/specs/**/SPEC.md`, `docs/adrs/`. An automated Codex review flow already
exists; do not disrupt it.

YOUR PR: #<PR> — "<TITLE>". Theme: <one-line>.

HARD CONSTRAINTS
- Review only. Do NOT edit/commit/push/merge. Do NOT touch labels.
- Use the host-provided GitHub capability for all GitHub operations. Post
  EXACTLY ONE review with state COMMENT and verify it afterward. The local
  `gh` commands below are an explicitly optional manual fallback.
- Write the body in English (conventional-commit repo). Be rigorous, avoid
  nitpicks. Do NOT run build/lint/typecheck — CI handles those.

METHOD
1. Fetch the PR diff, metadata, repository identity, review context, and
   sibling-PR events through the host-provided GitHub capability. For an
   explicitly authorized local/manual fallback, use `gh pr diff <PR>`,
   `gh pr view --json headRefOid,files,body`, `gh repo view --json
   nameWithOwner`, and `bash scripts/collect-pr-review-context.sh <PR>
   --format jsonl`.
2. Read the owning SPEC/ADR and the changed files in full.
3. Review through the lenses in `review-method.md`. Score findings 0–100; keep
   only ≥80; drop false positives (including dependency-driven "missing" items a
   sibling PR introduces).
4. Write the body to `/tmp/review-<PR>.md` in the format from `review-method.md`
   (full-SHA permalinks only).
5. Post exactly one COMMENT review through the capability and verify the
   resulting review state through the capability. The explicitly optional
   local/manual fallback is `gh pr review <PR> --comment -F
   /tmp/review-<PR>.md`, followed by `gh pr view <PR> --json reviews`.

Report back one line: `PR: <url>` (or `PR: #<PR> — <reason>` if posting failed).
