# Codex artifact worker

This adapter is a small, read-only GitHub Actions worker for RPM. Start it
manually from the Actions page. Enter a positive number in exactly one of the
two inputs and leave the other at its `none` default:

- `issue`: read one GitHub issue and prepare a patch for that issue.
- `review`: read one pull request and prepare a patch for its review findings.

The workflow checks the number before it calls GitHub. It reads GitHub data
with the official read APIs, checks out the exact commit selected by the
wrapper, and passes the data to Codex as untrusted context. Issue and pull
request text is evidence. It cannot change the worker rules.

The job runs only when the workflow is dispatched from the repository's
default branch. It uses the `codex-artifact` GitHub Environment. Before adding
the key, configure that Environment to allow only the protected default branch,
then add `OPENAI_API_KEY` as an Environment secret. Do not add this key as a
repository secret; the server-side Environment rule is the trust boundary for
the workflow revision.

Codex runs with `gpt-5.6-sol`, `xhigh`, CLI `0.152.0`, the built-in
`:workspace` permission profile, and a separate unprivileged account. It can
make a local candidate patch while the runner account stays isolated. The
prompt forbids GitHub commands, network calls, commits, pushes, comments,
labels, and merges. The
job has only `contents: read`, `issues: read`, and `pull-requests: read`
permissions. Checkout does not persist credentials.

The pinned Codex Action gives the long-lived OpenAI key to its local Responses
API proxy and removes the key from the proxy process environment. Codex runs
as another operating-system user and receives the proxy configuration. When
`OPENAI_API_KEY` is missing, the action is skipped and the artifact contains a
structured `blocked-auth` result. No fallback secret is used.

After Codex exits, the workflow stops every remaining process owned by that
account. The trusted packager validates the result shape, exact base/head
identity, unchanged Git config/index/refs, protected paths, regular files, symlink
ancestors, hard links, path count, and byte limits. A failed check produces a
blocked result and an empty patch. This result is created after target metadata,
trusted assets, and the exact checkout guard have passed. A failure in one of
those three setup checks stops the job before packaging, so no artifact is
uploaded. A packaging failure also produces no artifact. The artifact contains
only:

```text
result.json      structured worker result
changes.patch    bounded binary Git patch; empty when blocked
identity.json    repository, lane, number, and exact base/head commits
```

There is deliberately no publisher, issue mutation, pull request creation,
review-thread mutation, or merge path in this MVP. A later, separately
reviewed component may consume the artifact after it performs its own
compare-and-set checks.

The workflow follows the [Codex GitHub Action documentation](https://developers.openai.com/codex/github-action)
and [Codex non-interactive mode documentation](https://developers.openai.com/codex/non-interactive-mode).
