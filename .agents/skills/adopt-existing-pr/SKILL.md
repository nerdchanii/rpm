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

## Required evidence

- Exact repository, issue, pull request, base ref and SHA, head ref and SHA
- The complete canonical closing-issue set
- Current-head `metadata` and `verify` checks with provenance
- A current-head approved Automatic review or approved post-head plus-one
- Complete finding dispositions with no P0/P1 and no `accept-now` P2
- Complete repository-global writer, ledger, and dependent-PR inventories
- Exact approval, plan revision, scope hash, executor, policy version, operation
  version, and canonical evidence digest

Normalize the evidence and run:

```sh
python3 scripts/check-cloud-queue-contract.py \
  --issues-file /tmp/rpm-adopt-existing-pr.json \
  --operation adopt-existing-pr
```

The checker is authoritative. A blocked result permits no mutation. For an
adopt result, record the phase ledger exactly, re-fetch the current issue
labels, and pass the exact add-only request through
`scripts/authorize-existing-pr-adoption-mutation.py`. Preserve every ordinary
label. Then invoke `scripts/write-existing-pr-adoption.py` with the prepared
snapshot and policy. That entry point owns the narrow GitHub API transport for
ledger comments and the add-only lifecycle label; it re-fetches and CAS-checks
the full authorization tuple immediately before each write. Re-fetch after
each phase and resume only an exact matching ledger run.

Project membership synchronization is a separate inventory operation. Project
read failure does not change the adoption decision. This operation does not
create reviews, alter pull request content, resolve review threads, manipulate
branches, or perform merges.

Return the checker decision, phase, evidence digest, mutation authorization,
and any fail-closed reason to the caller. Do not infer missing evidence.
