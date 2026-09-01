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
The manager and adopter remain read-only. The leaf collects the complete live
evidence after dispatch while the manager preserves its read-only role
boundary. The authorization flags describe the proposed execution metadata;
they do not approve the adoption.

## Required evidence

- Exact repository, issue, pull request, base ref and SHA, head ref and SHA
- The complete canonical closing-issue set
- Current-head `metadata` and `verify` checks with provenance
- A current-head approved Automatic review or approved post-head plus-one
- Complete finding dispositions with no P0/P1 and no `accept-now` P2
- Complete repository-global writer, ledger, and dependent-PR inventories
- An external approval comment whose marker explicitly names the repository,
  issue, pull request, base repository/ref/SHA, head repository/ref/SHA, and
  canonical evidence digest, plus plan revision, scope hash, and executor.
  Never rebind a marker written for another target, identity, head, or evidence
  snapshot.

## Authorization checkpoint

The first adopter phase is a read-only evidence phase. After the live packet is
complete, run the local helper below against that exact packet:

```sh
python3 scripts/prepare-existing-pr-adoption-authorization.py \
  --policy .agents/workflows/backlog-policy.json \
  --evidence-file /tmp/rpm-existing-pr-adoption/<safe-run-id>/prepared.json \
  --approval-id <approval-id> \
  --plan-revision <plan-revision> \
  --scope-hash sha256:<64-lowercase-hex> \
  --executor local|cloud
```

The helper reuses the canonical digest function from
`authorize-existing-pr-adoption-mutation.py`. It prints exactly one JSONL
checkpoint with `status: authorization-required`, the complete target tuple,
and one exact `rpm-agent-execution` marker. The checkpoint has
`requires_external_approval: true` and `mutation_count: 0`. The helper does
not publish a comment, add a label, or call GitHub.

The manager returns this checkpoint to the caller and stops. The user or an
already trusted top-level caller must review the exact marker and publish that
unchanged marker as an issue comment. The adopter and workflow manager may not
approve themselves or publish this marker. The external publisher must return
the comment identity with the checkpoint when resuming the operation.

On resume, the adopter re-reads the issue comments and requires exactly one
comment from a policy-approved actor with the exact marker. It compares every
repository, issue, PR, base/head ref and SHA, and evidence digest with the
fresh live packet. Missing, ambiguous, forged, legacy, or drifted comments
return `blocked` and perform no mutation. Only this verified comment permits
the existing checker and writer phases to continue.

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
authored by a policy-approved actor. Its marker must carry the exact
`repository`, `issue`, `pr`, `base_repository`, `base_ref`, `base_sha`,
`head_repository`, `head_ref`, `head_sha`, and `evidence_digest` values
refetched for this run. The ordinary editable issue body is not an
authorization source. Then invoke
`scripts/write-existing-pr-adoption.py`
with the prepared snapshot and policy. That entry point owns the narrow GitHub
API transport for writer/ledger comments and the add-only lifecycle label.
Before the first ledger comment, it publishes a short-lived adoption writer
lease and stops at the `writer-lease` phase. A later invocation re-fetches the
complete repository-global writer inventory, applies the server-assigned
comment-ID winner rule, and proceeds only for the winning run. It re-fetches
and CAS-checks the full authorization tuple immediately before each write.
Re-fetch after each phase and resume only an exact matching ledger run.
Stale-head recovery never removes a review-pending label because GitHub does
not expose an atomic owner identity for that shared label. It fails closed with
`recovery-label-ownership-unprovable` and requires an independently authorized
manual reconciliation. Retain the exact prepared and label-mutation comments
as old-head history. A fresh authorization uses a new run ID and only that
run's ledger phases may advance the current head.

Project membership synchronization is a separate inventory operation. Project
read failure does not change the adoption decision. This operation does not
create reviews, alter pull request content, resolve review threads, manipulate
branches, or perform merges.

Return the checker decision, phase, evidence digest, mutation authorization,
and any fail-closed reason to the caller. Do not infer missing evidence.
