---
name: adopt-existing-pr
description: Policy-checked adoption of one completed existing RPM pull request into review-pending lifecycle reconciliation.
argument-hint: "<issue-number> <pr-number>"
disable-model-invocation: true
---

# Adopt Existing PR

Use this operation only for an open, completed pull request whose closing issue
has no lifecycle label. Read `.agents/workflows/backlog-policy.json` and process
at most one exact issue/PR pair.

Route this entry through `rpm_workflow_manager` with
`workflow=adopt-existing-pr` and `mode=adoption`. The manager dispatches the
dedicated adopter leaf with the exact issue/PR pair and authorization flags.
The leaf collects the complete live evidence after dispatch while the manager
preserves its read-only role boundary.

## Required evidence

- Exact repository, issue, pull request, base ref and SHA, head ref and SHA
- The complete canonical closing-issue set
- Current-head `metadata` and `verify` checks with provenance
- A current-head approved Automatic review or approved post-head plus-one
- Complete finding dispositions with no P0/P1 and no `accept-now` P2
- Complete repository-global writer, ledger, and dependent-PR inventories
- Exact approval, plan revision, scope hash, executor, policy version, operation
  version, and canonical evidence digest

Normalize the evidence into a per-run temporary handoff. The issue/PR-only
workflow uses the repository materializer, which accepts one UTF-8 JSON object
over stdin (or a small base64 payload) and writes only the selected
`issues.json`, `request.json`, or `prepared.json` below
`/tmp/rpm-existing-pr-adoption/<safe-run-id>/`:

```sh
python3 scripts/materialize-existing-pr-adoption.py \
  --run-id <safe-run-id> \
  --kind issues \
  --payload-base64 <base64-encoded-json>
```

For complete evidence or mutation documents, use `--payload-stdin` so the
payload is not constrained by a process argument limit. Materialize the
checker result's `mutation_request` as `request.json` for the authorization
helper, and materialize its `adoption_input` as `prepared.json` for the writer.
These are separate documents with separate entrypoint schemas.

Use the returned path as the checker input:

```sh
python3 scripts/check-cloud-queue-contract.py \
  --issues-file /tmp/rpm-existing-pr-adoption/<safe-run-id>/issues.json \
  --operation adopt-existing-pr
```

The checker is authoritative. A blocked result permits no mutation. For an
adopt result, record the phase ledger exactly, re-fetch the current issue
labels, and pass the exact add-only request through
`scripts/authorize-existing-pr-adoption-mutation.py`. Preserve every ordinary
label. The execution tuple must come from exactly one complete issue comment
authored by a policy-approved actor. The ordinary editable issue body is not
an authorization source. Then invoke `scripts/write-existing-pr-adoption.py`
with the prepared snapshot and policy. That entry point owns the narrow GitHub
API transport for writer/ledger comments and the add-only lifecycle label.
Before the first ledger comment, it publishes a short-lived adoption writer
lease and stops at the `writer-lease` phase. A later invocation re-fetches the
complete repository-global writer inventory, applies the server-assigned
comment-ID winner rule, and proceeds only for the winning run. It re-fetches
and CAS-checks the full authorization tuple immediately before each write.
Re-fetch after each phase and resume only an exact matching ledger run.

Project membership synchronization is a separate inventory operation. Project
read failure does not change the adoption decision. This operation does not
create reviews, alter pull request content, resolve review threads, manipulate
branches, or perform merges.

Return the checker decision, phase, evidence digest, mutation authorization,
and any fail-closed reason to the caller. Do not infer missing evidence.
