#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${repo_root}/scripts/check-cloud-queue-contract.py"
merge_checker="${repo_root}/scripts/check-merge-gate.py"
fixtures="${repo_root}/.agents/fixtures/backlog"
policy="${repo_root}/.agents/workflows/backlog-policy.json"
workflow="${repo_root}/.github/workflows/agent-loop-triggers.yml"

fail() {
  printf 'cloud_automation_policy_test.FAIL=%s\n' "$1" >&2
  exit 1
}

jq -e '
  .version == 4
  and .execution_queue.active_states == ["claimed","review-pending","awaiting-merge"]
  and .execution_queue.blocking_states == ["claimed","review-pending","awaiting-merge"]
  and .execution_contract.active_states == ["claimed","review-pending","awaiting-merge"]
  and .execution_contract.blocking_states == ["claimed","review-pending","awaiting-merge"]
  and .automation.create_followup_issues_by_default == true
  and .automation.merge_pull_requests == true
  and .automation.request_codex_review == false
  and .trusted_lifecycle_actors == {
    ready:["nerdchanii"],
    "awaiting-merge":["nerdchanii","chatgpt-codex-connector[bot]","github-actions[bot]"]
  }
  and .merge_gate.delete_branch == false
  and .merge_gate.max_no_work_attempts == 5
  and .review_correction.max_attempts == 5
  and ([.review_correction.counter_labels[]] | sort) == [
    "agent:correction-0",
    "agent:correction-1",
    "agent:correction-2",
    "agent:correction-3",
    "agent:correction-4",
    "agent:correction-5"
  ]
  and .followup == {
    identity_label:"process:agent-followup",
    dedupe_key_fields:["source","fingerprint"],
    duplicate_result:"duplicate",
    max_per_source:5
  }
  and .merge_gate.server_protection == {
    branch:"main",
    enforce_admins:true,
    required_conversation_resolution:true,
    required_status_checks:[
      {context:"metadata",app_id:15368},
      {context:"verify",app_id:15368}
    ],
    strict_status_checks:true,
    allow_force_pushes:false,
    allow_deletions:false
  }
' "$policy" >/dev/null || fail "policy-v4-contract"

grep -Fq 'cron: "*/5 * * * *"' "$workflow" || fail "five-minute-cloud-poll"
if grep -Fq 'pull_request_review:' "$workflow" ||
  grep -Fq 'pull_request_review_comment:' "$workflow" ||
  grep -Fq 'pull_request:' "$workflow" ||
  grep -Fq "github.event_name == 'pull_request_review'" "$workflow" ||
  grep -Fq "github.event_name == 'pull_request_review_comment'" "$workflow" ||
  grep -Fq "github.event_name == 'pull_request'" "$workflow"
then
  fail "pr-controlled-publisher-trigger"
fi
grep -Fq 'queue_states=' "$workflow" || fail "complete-lifecycle-selector"
grep -Fq 'agent:awaiting-merge' "$workflow" || fail "awaiting-merge-selector-blocker"
grep -Fq "needs.issue-cloud.result == 'cancelled'" "$workflow" || fail "cancelled-issue-recovery"
grep -Fq 'workflow_run:' "$workflow" || fail "trusted-workflow-run-trigger"
grep -Fq 'repository_dispatch:' "$workflow" || fail "trusted-manual-dispatch-trigger"
grep -Fq "github.actor == 'nerdchanii'" "$workflow" || fail "trusted-manual-dispatch-actor"
if grep -Fq 'workflow_dispatch:' "$workflow"; then
  fail "branch-selected-manual-dispatch"
fi

selected="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-review-pending-ready.json" \
  --operation select-execution)"
printf '%s\n' "$selected" | jq -e '
  .data.status == "no-work"
  and .data.reason == "active-work"
  and .data.active == [12]
  and .data.blocking == [12]
  and .data.blocking_states == ["awaiting-merge","claimed","review-pending"]
' >/dev/null || fail "review-pending-blocked-ready-lane"

inline_selected="$(python3 "$checker" \
  --issues-json "$(jq -c . "$fixtures/cloud-review-pending-ready.json")" \
  --operation select-execution)"
[ "$inline_selected" = "$selected" ] || fail "inline-queue-json-parity"

awaiting_merge_blocked="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-awaiting-merge-ready.json" \
  --operation select-execution)"
printf '%s\n' "$awaiting_merge_blocked" | jq -e '
  .data.status == "no-work"
  and .data.reason == "active-work"
  and .data.active == [12]
  and .data.blocking == [12]
' >/dev/null || fail "awaiting-merge-blocked-ready-lane"

claimed_blocked="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-active.json" \
  --operation select-execution)"
printf '%s\n' "$claimed_blocked" | jq -e '
  .data.status == "no-work"
  and .data.reason == "active-work"
  and .data.active == [4]
  and .data.blocking == [4]
' >/dev/null || fail "claimed-blocked-ready-lane"

set +e
malformed_ready="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-ready-malformed.json" \
  --operation select-execution)"
malformed_ready_status=$?
set -e
[ "$malformed_ready_status" -eq 1 ] || fail "malformed-ready-exit"
printf '%s\n' "$malformed_ready" | jq -e '
  .data.status == "blocked"
  and .data.reason == "malformed-ready"
  and .data.invalid == [{"number":13,"reason":"missing-ready-transition-actor","reasons":["missing-ready-transition-actor"]}]
' >/dev/null || fail "malformed-ready-result"

set +e
untrusted_ready="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-ready-untrusted.json" \
  --operation select-execution)"
untrusted_ready_status=$?
set -e
[ "$untrusted_ready_status" -eq 1 ] || fail "untrusted-ready-actor-exit"
printf '%s\n' "$untrusted_ready" | jq -e '
  .data.status == "blocked"
  and .data.reason == "malformed-ready"
  and .data.invalid[0].number == 15
  and .data.invalid[0].reason == "untrusted-ready-transition-actor"
' >/dev/null || fail "untrusted-ready-actor-result"

demoted_ready="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-ready-malformed.json" \
  --operation transition --issue 13 --from-state ready --to-state blocked)"
printf '%s\n' "$demoted_ready" | jq -e '
  .data.status == "transition"
  and .data.issue == 13
  and .data.before == "ready"
  and .data.after == "blocked"
  and .data.labels == ["agent:blocked","kind:bug"]
' >/dev/null || fail "malformed-ready-demotion"

claim="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-claim-ready.json" \
  --operation claim --issue 3 --run-id run-3 --event-id delivery-3 \
  --executor cloud --plan-revision plan-3 \
  --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --lease-owner cloud:executor)"
printf '%s\n' "$claim" | jq -e '
  .data.status == "claim"
  and .data.updated_execution.approval_id == "approval-3"
  and .data.updated_execution.plan_revision == "plan-3"
  and .data.updated_execution.scope_hash == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  and .data.updated_execution.executor == "cloud"
  and .data.updated_execution.lease.run_id == "run-3"
  and .data.updated_execution.lease.owner == "cloud:executor"
  and .data.updated_execution.runs[0].repository == "nerdchanii/rpm"
  and .data.updated_execution.runs[0].issue == 3
  and .data.updated_execution.runs[0].event_id == "delivery-3"
  and .data.updated_execution.runs[0].idempotency_key == .data.idempotency_key
' >/dev/null || fail "claim-updated-execution"

initialized="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-correction.json" \
  --operation initialize-correction --pr 47)"
printf '%s\n' "$initialized" | jq -e '
  .data.status == "initialize"
  and .data.after_attempt == 0
  and .data.label == "agent:correction-0"
  and .data.labels == ["agent:correction-0","kind:feature"]
' >/dev/null || fail "correction-initialization"

for pr in 41 42 43 44 45; do
  attempt=$((pr - 40))
  result="$(python3 "$checker" \
    --issues-file "$fixtures/cloud-correction.json" \
    --operation correction --pr "$pr")"
  printf '%s\n' "$result" | jq -e --argjson attempt "$attempt" '
    .data.status == "correction"
    and .data.attempt == $attempt
    and .data.label == ("agent:correction-" + ($attempt | tostring))
  ' >/dev/null || fail "correction-${attempt}"
done

set +e
invalid_correction_label="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-correction.json" \
  --operation correction --pr 48)"
invalid_correction_label_status=$?
set -e
[ "$invalid_correction_label_status" -eq 1 ] || fail "unknown-correction-label-exit"
printf '%s\n' "$invalid_correction_label" | jq -e '
  .data.status == "blocked"
  and .data.reason == "invalid-correction-label"
  and .data.invalid_labels == ["agent:correction-99"]
' >/dev/null || fail "unknown-correction-label-result"

set +e
invalid_pr_labels="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-correction.json" \
  --operation initialize-correction --pr 49)"
invalid_pr_labels_status=$?
set -e
[ "$invalid_pr_labels_status" -eq 1 ] || fail "non-string-pr-label-exit"
printf '%s\n' "$invalid_pr_labels" | jq -e '
  .data.status == "blocked"
  and .data.reason == "invalid-correction-labels"
  and .data.invalid_labels == [7]
' >/dev/null || fail "non-string-pr-label-result"

for pr_and_reason in \
  "50:invalid-pull-request-state" \
  "51:duplicate-pr-labels" \
  "52:multiple-correction-labels"; do
  pr="${pr_and_reason%%:*}"
  expected_reason="${pr_and_reason#*:}"
  set +e
  malformed_pr="$(python3 "$checker" \
    --issues-file "$fixtures/cloud-correction.json" \
    --operation correction --pr "$pr")"
  malformed_pr_status=$?
  set -e
  [ "$malformed_pr_status" -eq 1 ] || fail "malformed-pr-exit:${pr}"
  printf '%s\n' "$malformed_pr" | jq -e --arg reason "$expected_reason" '
    .data.status == "blocked" and .data.reason == $reason
  ' >/dev/null || fail "malformed-pr-result:${pr}"
done

set +e
limit_result="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-correction.json" \
  --operation correction --pr 46)"
limit_status=$?
set -e
[ "$limit_status" -eq 1 ] || fail "sixth-correction-exit"
printf '%s\n' "$limit_result" | jq -e '
  .data.status == "blocked"
  and .data.reason == "correction-limit"
  and .data.attempt == 6
  and .data.last_attempt == 5
' >/dev/null || fail "sixth-correction-result"

duplicate="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-followup-duplicate.json" \
  --operation followup --source pr:44 \
  --fingerprint sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
printf '%s\n' "$duplicate" | jq -e '
  .data.status == "duplicate" and .data.reason == "existing-followup"
' >/dev/null || fail "followup-duplicate"

untrusted_marker="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-followup-untrusted-marker.json" \
  --operation followup --source pr:44 \
  --fingerprint sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
printf '%s\n' "$untrusted_marker" | jq -e '
  .data.status == "eligible"
  and .data.reason == "new-followup"
  and .data.ordinal == 1
' >/dev/null || fail "untrusted-followup-marker-ignored"

set +e
followup_limit="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-followup-limit.json" \
  --operation followup --source pr:44 \
  --fingerprint sha256:6666666666666666666666666666666666666666666666666666666666666666)"
followup_status=$?
set -e
[ "$followup_status" -eq 1 ] || fail "sixth-followup-exit"
printf '%s\n' "$followup_limit" | jq -e '
  .data.status == "blocked"
  and .data.reason == "followup-limit"
  and .data.count == 5
  and .data.max_per_source == 5
' >/dev/null || fail "sixth-followup-result"

created="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-followup-created.json" \
  --operation followup --source pr:44 \
  --fingerprint sha256:7777777777777777777777777777777777777777777777777777777777777777)"
printf '%s\n' "$created" | jq -e '
  .data.status == "eligible"
  and .data.reason == "new-followup"
  and .data.ordinal == 1
' >/dev/null || fail "followup-created"

issue_source="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-followup-created.json" \
  --operation followup --source issue:1 \
  --fingerprint sha256:8888888888888888888888888888888888888888888888888888888888888888)"
printf '%s\n' "$issue_source" | jq -e '
  .data.status == "eligible"
  and .data.reason == "new-followup"
  and .data.source == "issue:1"
' >/dev/null || fail "issue-source-format"

for invalid_source in "pr:0" "PR:44" "pr:01" "owner/repo#44" "issue:-1" "pr:44 "; do
  set +e
  invalid_source_result="$(python3 "$checker" \
    --issues-file "$fixtures/cloud-followup-created.json" \
    --operation followup --source "$invalid_source" \
    --fingerprint sha256:9999999999999999999999999999999999999999999999999999999999999999)"
  invalid_source_status=$?
  set -e
  [ "$invalid_source_status" -eq 1 ] || fail "invalid-followup-source-exit:${invalid_source}"
  printf '%s\n' "$invalid_source_result" | jq -e '
    .data.status == "blocked"
    and .data.reason == "invalid-followup-source"
  ' >/dev/null || fail "invalid-followup-source-result:${invalid_source}"
done

for invalid_identity_fixture in \
  cloud-followup-invalid-source-type.json \
  cloud-followup-invalid-source-format.json \
  cloud-followup-invalid-fingerprint-type.json \
  cloud-followup-invalid-label.json; do
  set +e
  invalid_identity="$(python3 "$checker" \
    --issues-file "$fixtures/$invalid_identity_fixture" \
    --operation followup --source pr:44 \
    --fingerprint sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
  invalid_identity_status=$?
  set -e
  [ "$invalid_identity_status" -eq 1 ] || fail "invalid-followup-identity-exit:${invalid_identity_fixture}"
  printf '%s\n' "$invalid_identity" | jq -e '
    .data.status == "blocked"
    and (.data.reason == "invalid-existing-followup-identity"
      or .data.reason == "invalid-existing-followup-labels")
  ' >/dev/null || fail "invalid-followup-identity-result:${invalid_identity_fixture}"
done

set +e
invalid_fingerprint="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-followup-created.json" \
  --operation followup --source pr:44 --fingerprint finding:legacy)"
invalid_fingerprint_status=$?
set -e
[ "$invalid_fingerprint_status" -eq 1 ] || fail "invalid-followup-fingerprint-exit"
printf '%s\n' "$invalid_fingerprint" | jq -e '
  .data.status == "blocked"
  and .data.reason == "invalid-followup-fingerprint"
' >/dev/null || fail "invalid-followup-fingerprint-result"

set +e
invalid_transition="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-transition-invalid.json" \
  --operation transition --issue 3 --from-state ready --to-state review-pending)"
invalid_transition_status=$?
set -e
[ "$invalid_transition_status" -eq 1 ] || fail "invalid-transition-exit"
printf '%s\n' "$invalid_transition" | jq -e '
  .data.status == "blocked"
  and .data.reason == "transition-not-allowed"
' >/dev/null || fail "invalid-transition-result"

set +e
untrusted_block_transition="$(python3 "$checker" \
  --issues-file "$fixtures/cloud-awaiting-merge-untrusted.json" \
  --operation transition --issue 12 --from-state awaiting-merge --to-state blocked)"
untrusted_block_transition_status=$?
set -e
[ "$untrusted_block_transition_status" -eq 1 ] || fail "untrusted-awaiting-merge-block-exit"
printf '%s\n' "$untrusted_block_transition" | jq -e '
  .data.status == "blocked"
  and .data.reason == "untrusted-awaiting-merge-transition-actor"
  and .data.issue == 12
  and .data.before == "awaiting-merge"
  and .data.after == "blocked"
' >/dev/null || fail "untrusted-awaiting-merge-block-result"

allowed_block_transition="$(python3 "$checker" \
  --issues-file "$fixtures/merge-ready.json" \
  --operation transition --issue 12 --from-state awaiting-merge --to-state blocked)"
printf '%s\n' "$allowed_block_transition" | jq -e '
  .data.status == "transition"
  and .data.issue == 12
  and .data.before == "awaiting-merge"
  and .data.after == "blocked"
  and .data.labels == ["agent:blocked","kind:feature"]
' >/dev/null || fail "trusted-awaiting-merge-block-result"

merge_ready="$(python3 "$merge_checker" \
  --issues-file "$fixtures/merge-ready.json" \
  --operation select-merge)"
printf '%s\n' "$merge_ready" | jq -e '
  .data.status == "merge"
  and .data.expected_head_sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  and .data.delete_branch == false
' >/dev/null || fail "merge-expected-head-sha"

inline_merge_ready="$(python3 "$merge_checker" \
  --issues-json "$(jq -c . "$fixtures/merge-ready.json")" \
  --operation select-merge)"
[ "$inline_merge_ready" = "$merge_ready" ] || fail "inline-merge-json-parity"

set +e
missing_merge_actor="$(python3 "$merge_checker" \
  --issues-file "$fixtures/merge-actor-missing.json" \
  --operation select-merge)"
missing_merge_actor_status=$?
set -e
[ "$missing_merge_actor_status" -eq 1 ] || fail "missing-awaiting-merge-actor-exit"
printf '%s\n' "$missing_merge_actor" | jq -e '
  .data.status == "blocked"
  and .data.reason == "missing-awaiting-merge-transition-actor"
  and .data.issue == 12
' >/dev/null || fail "missing-awaiting-merge-actor-result"

set +e
untrusted_merge_actor="$(python3 "$merge_checker" \
  --issues-file "$fixtures/merge-actor-untrusted.json" \
  --operation select-merge)"
untrusted_merge_actor_status=$?
set -e
[ "$untrusted_merge_actor_status" -eq 1 ] || fail "untrusted-awaiting-merge-actor-exit"
printf '%s\n' "$untrusted_merge_actor" | jq -e '
  .data.status == "blocked"
  and .data.reason == "untrusted-awaiting-merge-transition-actor"
  and .data.issue == 12
' >/dev/null || fail "untrusted-awaiting-merge-actor-result"

for malformed_protection_fixture in \
  merge-server-protection-contexts-only.json \
  merge-server-protection-app-id-missing.json \
  merge-server-protection-app-id-null.json \
  merge-server-protection-app-id-negative.json \
  merge-server-protection-duplicate-context.json
do
  set +e
  malformed_protection="$(python3 "$merge_checker" \
    --issues-file "$fixtures/$malformed_protection_fixture" \
    --operation select-merge)"
  malformed_protection_status=$?
  set -e
  [ "$malformed_protection_status" -eq 1 ] || fail "${malformed_protection_fixture}-exit"
  printf '%s\n' "$malformed_protection" | jq -e '
    .data.status == "blocked"
    and .data.reason == "server-protection-invalid"
    and .data.issue == 12
    and .data.pr == 44
  ' >/dev/null || fail "${malformed_protection_fixture}-result"
done

set +e
app_id_mismatch="$(python3 "$merge_checker" \
  --issues-file "$fixtures/merge-server-protection-app-id-mismatch.json" \
  --operation select-merge)"
app_id_mismatch_status=$?
set -e
[ "$app_id_mismatch_status" -eq 1 ] || fail "server-protection-app-id-mismatch-exit"
printf '%s\n' "$app_id_mismatch" | jq -e '
  .data.status == "blocked"
  and .data.reason == "server-protection-mismatch"
  and .data.issue == 12
  and .data.pr == 44
' >/dev/null || fail "server-protection-app-id-mismatch-result"

set +e
missing_head_sha="$(python3 "$merge_checker" \
  --issues-file "$fixtures/merge-head-sha-missing.json" \
  --operation select-merge)"
missing_head_sha_status=$?
set -e
[ "$missing_head_sha_status" -eq 1 ] || fail "missing-head-sha-exit"
printf '%s\n' "$missing_head_sha" | jq -e '
  .data.status == "blocked"
  and .data.reason == "head-sha-metadata-missing"
' >/dev/null || fail "missing-head-sha-result"

set +e
changed_head_sha="$(python3 "$merge_checker" \
  --issues-file "$fixtures/merge-head-sha-changed.json" \
  --operation select-merge \
  --expected-head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
changed_head_sha_status=$?
set -e
[ "$changed_head_sha_status" -eq 1 ] || fail "changed-head-sha-exit"
printf '%s\n' "$changed_head_sha" | jq -e '
  .data.status == "blocked"
  and .data.reason == "head-sha-changed"
  and .data.expected_head_sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  and .data.actual_head_sha == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
' >/dev/null || fail "changed-head-sha-result"

printf 'cloud_automation_policy_test.PASS=policy-corrections-followups\n'
