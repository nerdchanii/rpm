# Open PR Review Batch — Method

## Lenses (flag only REAL, IMPORTANT issues)

Apply the AGENTS.md "Code Review Rules" plus:

- Correctness/bugs: scan the diff for genuine bugs. Large bugs only; ignore
  style, formatting, imports, and anything a linter/typechecker/compiler catches.
- Contract integrity: conflict with the owning SPEC, or a contract-affecting
  change without SPEC classification. For docs, internal consistency vs the
  owning SPEC/ADR and the doc's own statements.
- Filesystem safety: path traversal, symlink escape, partial writes, cache/store
  boundary leaks (install/registry/linker/cache).
- Determinism: dependence on iteration order, HashMap randomization, network
  timing, ambient machine state, or an uncontrolled clock (resolver/lockfile/
  registry/fixtures).
- Change discipline: focused scope; behavior changes carry tests/fixtures.
- Historical context: `git log`/blame on modified code; prior PRs touching these
  files for applicable comments.

## Cross-PR dependency awareness

`collect-pr-review-context.sh` may emit `pr_sibling_pr` events. When a finding
says something "does not exist" or "is missing", check whether a sibling PR
introduces it before flagging — it may be landing in another open PR. Prefer a
note over a defect in that case.

## Confidence scoring (keep only ≥ 80)

- 0: false positive / pre-existing.
- 25: maybe real, unverifiable.
- 50: real but minor/rare.
- 75: verified, important, hits in practice.
- 100: certain, frequent.

Drop < 80. Drop false positives: pre-existing issues, linter/compiler-caught,
intentional behavior, pedantic nitpicks, lines the PR did not modify, and
generic "add more tests/docs" unless a SPEC requires it.

## COMMENT review body format

When no findings survive:

```
### Code review

No issues found. Checked for correctness, contract integrity, filesystem
safety, and determinism.

🤖 Generated with [Claude Code](https://claude.ai/code)
```

When findings survive:

```
### Code review

Found N issues:

1. <brief description> (AGENTS.md / <SPEC path> says "<…>")
<full-SHA permalink, ±1 line context>

🤖 Generated with [Claude Code](https://claude.ai/code)
```

Permalink rules: use the full HEAD SHA (never `HEAD`/`main`/branch), repo must
match `nameWithOwner`, `#L<start>-L<end>` after the path. Keep it brief; keep
finding text emoji-free (the trailer line is the only emoji). Post with
`gh pr review <n> --comment -F <file>`, then verify with
`gh pr view <n> --json reviews`.
