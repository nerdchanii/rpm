#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
workflow="${repo_root}/.github/workflows/agent-loop-triggers.yml"

fail() {
  printf 'codex_cloud_dispatch_test.FAIL=%s\n' "$1" >&2
  exit 1
}

[ -f "$workflow" ] || fail 'workflow-missing'
[ -x "${repo_root}/scripts/validate-cloud-diff.sh" ] || fail 'validator-missing'
[ -x "${repo_root}/scripts/publish-cloud-diff.sh" ] || fail 'publisher-missing'
[ -x "${repo_root}/scripts/publish-cloud-merge.sh" ] || fail 'merge-publisher-missing'
[ -x "${repo_root}/scripts/quarantine-merge-selector-anomaly.sh" ] || fail 'merge-selector-quarantine-missing'
[ -x "${repo_root}/scripts/test-quarantine-merge-selector-anomaly.sh" ] || fail 'merge-selector-quarantine-test-missing'
[ -x "${repo_root}/scripts/quarantine-review-correction-limit.sh" ] || fail 'review-correction-quarantine-missing'
[ -x "${repo_root}/scripts/test-quarantine-review-correction-limit.sh" ] || fail 'review-correction-quarantine-test-missing'
for graphql_caller in \
  "$workflow" \
  "${repo_root}/scripts/publish-cloud-diff.sh" \
  "${repo_root}/scripts/quarantine-review-correction-limit.sh"; do
  if grep -Fq 'api graphql --repo' "$graphql_caller"; then
    fail "unsupported-gh-api-repo-flag:${graphql_caller#${repo_root}/}"
  fi
done

ruby -ryaml -rjson -e '
  document = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  workflow_concurrency = document.fetch("concurrency")
  raise "workflow-concurrency-group" unless workflow_concurrency.fetch("group") == "codex-cloud-agent-loop-${{ github.repository }}"
  raise "workflow-concurrency-cancel-in-progress" unless workflow_concurrency.fetch("cancel-in-progress") == false
  jobs = document.fetch("jobs")
  expected = %w[select-issue issue-cloud issue-publish issue-recover select-review review-selector-quarantine review-cloud review-publish select-merge merge-selector-quarantine merge-cloud merge-publish]
  raise "job-set" unless jobs.keys.sort == expected.sort

  write = {"contents" => "write", "issues" => "write", "pull-requests" => "write"}
  %w[issue-cloud review-cloud].each do |name|
    job = jobs.fetch(name)
    permissions = job.fetch("permissions")
    raise "#{name}-contents-read" unless permissions["contents"] == "read"
    raise "#{name}-issues-read" unless permissions["issues"] == "read"
    if name == "review-cloud"
      raise "#{name}-pull-requests-read" unless permissions["pull-requests"] == "read"
    end
    raise "#{name}-write-permissions" if permissions.values.any? { |value| value == "write" }
    serialized = job.to_json
    raise "#{name}-checkout" if serialized.include?("actions/checkout@")
    raise "#{name}-download" if serialized.include?("actions/download-artifact@")
    raise "#{name}-cloud-secret" unless serialized.include?("secrets.CODEX_ACCESS_TOKEN")
    raise "#{name}-write-token" if serialized.include?("contents: write")
  end
  %w[issue-publish review-publish].each do |name|
    job = jobs.fetch(name)
    raise "#{name}-permissions" unless job.fetch("permissions") == write
    serialized = job.to_json
    raise "#{name}-cloud-secret" if serialized.include?("CODEX_ACCESS_TOKEN")
    raise "#{name}-checkout-pin" unless serialized.include?("actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683")
    raise "#{name}-download-pin" unless serialized.include?("actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093")
    raise "#{name}-expected-issue" unless serialized.include?("--expected-issue") && serialized.include?("ISSUE_NUMBER")
    raise "#{name}-publisher-token" unless serialized.include?("secrets.RPM_AUTOMATION_GITHUB_TOKEN")
    raise "#{name}-github-token-fallback" if serialized.include?("${{ github.token }}")
    raise "#{name}-git-auth" unless serialized.include?("gh auth setup-git")
    exact_checkout = Array(job.fetch("steps")).find { |step| step.is_a?(Hash) && step["name"].to_s.start_with?("Check out exact Cloud") }
    raise "#{name}-persisted-checkout-credentials" unless exact_checkout&.dig("with", "persist-credentials") == false
  end
  issue_publish = jobs.fetch("issue-publish")
  issue_publish_serialized = issue_publish.to_json
  raise "issue-publish-untrusted-workflow-sha" if issue_publish_serialized.include?("github.workflow_sha")
  issue_tool_step = Array(issue_publish.fetch("steps")).find { |step| step.is_a?(Hash) && step["name"] == "Check out trusted Cloud publisher tools" }
  raise "issue-publish-tools-not-selected-base" unless issue_tool_step&.dig("with", "ref") == "${{ needs.select-issue.outputs.base_sha }}"
  raise "issue-publish-trusted-revision-check" unless issue_publish_serialized.include?("Verify trusted issue publisher revision")

  review_publish = jobs.fetch("review-publish")
  review_publish_serialized = review_publish.to_json
  raise "review-publish-untrusted-workflow-sha" if review_publish_serialized.include?("github.workflow_sha")
  review_tool_step = Array(review_publish.fetch("steps")).find { |step| step.is_a?(Hash) && step["name"] == "Check out trusted Cloud publisher tools" }
  raise "review-publish-tools-not-selected-base" unless review_tool_step&.dig("with", "ref") == "${{ needs.select-review.outputs.base_sha }}"
  review_revision_step = Array(review_publish.fetch("steps")).find { |step| step.is_a?(Hash) && step["name"] == "Verify trusted review publisher revision" }
  raise "review-publish-trusted-revision-check" unless review_revision_step
  review_revision_run = review_revision_step.fetch("run")
  raise "review-publish-trusted-revision-base-check" unless review_revision_run.include?(%q{git -C "$GITHUB_WORKSPACE/rpm-cloud-tools" rev-parse HEAD)" = "$BASE_SHA"})
  review_quarantine = jobs.fetch("review-selector-quarantine")
  raise "review-quarantine-permissions" unless review_quarantine.fetch("permissions") == {"contents" => "read", "issues" => "write", "pull-requests" => "read"}
  raise "review-quarantine-always" unless review_quarantine.fetch("if").to_s.include?("always()")
  raise "review-quarantine-success-gate" unless review_quarantine.fetch("if").to_s.include?("needs.select-review.result") && review_quarantine.fetch("if").to_s.include?("'success'")
  review_quarantine_true_literal = 39.chr + "true" + 39.chr
  raise "review-quarantine-output-gate" unless review_quarantine.fetch("if").to_s.include?("correction_limit_exhausted") && review_quarantine.fetch("if").to_s.include?("== #{review_quarantine_true_literal}")
  review_quarantine_serialized = review_quarantine.to_json
  raise "review-quarantine-cloud-secret" if review_quarantine_serialized.include?("CODEX_ACCESS_TOKEN")
  raise "review-quarantine-checkout-pin" unless review_quarantine_serialized.include?("actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683")
  raise "review-quarantine-writer-script" unless review_quarantine_serialized.include?("quarantine-review-correction-limit.sh")
  raise "review-quarantine-policy" unless review_quarantine_serialized.include?("backlog-policy.json")
  raise "review-quarantine-github-token" unless review_quarantine_serialized.include?("github.token")
  review_quarantine_checkout = Array(review_quarantine.fetch("steps")).find { |step| step.is_a?(Hash) && step["name"].to_s.start_with?("Check out trusted review terminal writer") }
  raise "review-quarantine-tools-selected-base" unless review_quarantine_checkout&.dig("with", "ref") == "${{ needs.select-review.outputs.terminal_base_sha }}"
  raise "review-quarantine-sparse-checkout" unless review_quarantine_checkout&.dig("with", "sparse-checkout-cone-mode") == false
  raise "review-quarantine-persisted-checkout-credentials" unless review_quarantine_checkout&.dig("with", "persist-credentials") == false
  raise "review-quarantine-trusted-revision-check" unless review_quarantine_serialized.include?("Verify protected review terminal writer revision")
  raise "review-quarantine-exact-target" unless %w[terminal_issue terminal_pr terminal_base_ref terminal_base_sha terminal_head_ref terminal_head_sha terminal_reason].all? { |key| review_quarantine_serialized.include?(key) }
  recovery = jobs.fetch("issue-recover")
  raise "recovery-permissions" unless recovery.fetch("permissions") == {"contents" => "read", "issues" => "write"}
  raise "recovery-cloud-secret" if recovery.to_json.include?("CODEX_ACCESS_TOKEN")
  raise "recovery-always" unless recovery.fetch("if").to_s.include?("always()")
  raise "recovery-claim-check" unless recovery.to_json.include?("agent:claimed") && recovery.to_json.include?("agent:blocked")
  recovery_serialized = recovery.to_json
  %w[approval_id plan_revision scope_hash executor lease expires_at idempotency_key status expected_key].each do |marker|
    raise "recovery-claim-#{marker}" unless recovery_serialized.include?(marker)
  end
  raise "recovery-claim-unique-ledger" unless recovery_serialized.include?("unique | length")
  raise "recovery-claim-current-tuple" unless recovery_serialized.include?("exact current run tuple")
  merge_cloud = jobs.fetch("merge-cloud")
  merge_cloud_permissions = {"contents" => "read", "issues" => "read", "pull-requests" => "read"}
  raise "merge-cloud-permissions" unless merge_cloud.fetch("permissions") == merge_cloud_permissions
  raise "merge-cloud-runnerless" unless merge_cloud.fetch("runs-on") == "ubuntu-latest"
  merge_cloud_serialized = merge_cloud.to_json
  raise "merge-cloud-cloud-secret" unless merge_cloud_serialized.include?("secrets.CODEX_ACCESS_TOKEN")
  raise "merge-cloud-publisher-token" unless merge_cloud_serialized.include?("secrets.RPM_AUTOMATION_GITHUB_TOKEN")
  raise "merge-cloud-github-token-fallback" if merge_cloud_serialized.include?("secrets.RPM_AUTOMATION_GITHUB_TOKEN || github.token")
  raise "merge-cloud-direct-merge" if merge_cloud_serialized.match?(/gh\s+pr\s+merge|merge_pull_request/)
  merge_cloud_uploads = Array(merge_cloud["steps"]).select { |step| step.is_a?(Hash) && step["uses"].to_s.start_with?("actions/upload-artifact@") }
  raise "merge-cloud-artifact" unless merge_cloud_uploads.length == 1 && merge_cloud_uploads.first.fetch("with").fetch("retention-days") == 1
  raise "merge-cloud-diff" unless merge_cloud_serialized.include?("cloud diff")

  quarantine = jobs.fetch("merge-selector-quarantine")
  raise "quarantine-permissions" unless quarantine.fetch("permissions") == {"contents" => "read", "issues" => "write"}
  raise "quarantine-always" unless quarantine.fetch("if").to_s.include?("always()")
  quarantine_serialized = quarantine.to_json
  raise "quarantine-cloud-secret" if quarantine_serialized.include?("CODEX_ACCESS_TOKEN")
  raise "quarantine-checkout-pin" unless quarantine_serialized.include?("actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683")
  raise "quarantine-writer-script" unless quarantine_serialized.include?("quarantine-merge-selector-anomaly.sh")
  raise "quarantine-policy" unless quarantine_serialized.include?("backlog-policy.json")
  raise "quarantine-github-token" unless quarantine_serialized.include?("github.token")
  quarantine_checkout = Array(quarantine.fetch("steps")).find { |step| step.is_a?(Hash) && step["name"].to_s.start_with?("Check out trusted selector writer") }
  raise "quarantine-tools-selected-base" unless quarantine_checkout&.dig("with", "ref") == "${{ needs.select-merge.outputs.base_sha }}"
  raise "quarantine-sparse-checkout" unless quarantine_checkout&.dig("with", "sparse-checkout-cone-mode") == false
  raise "quarantine-persisted-checkout-credentials" unless quarantine_checkout&.dig("with", "persist-credentials") == false
  raise "quarantine-trusted-revision-check" unless quarantine_serialized.include?("Verify protected selector revision")

  merge_publish = jobs.fetch("merge-publish")
  merge_publish_permissions = {"contents" => "write", "issues" => "write", "pull-requests" => "write"}
  raise "merge-publish-permissions" unless merge_publish.fetch("permissions") == merge_publish_permissions
  raise "merge-publish-runnerless" unless merge_publish.fetch("runs-on") == "ubuntu-latest"
  merge_publish_serialized = merge_publish.to_json
  raise "merge-publish-cloud-secret" if merge_publish_serialized.include?("CODEX_ACCESS_TOKEN")
  raise "merge-publish-publisher-token" unless merge_publish_serialized.include?("secrets.RPM_AUTOMATION_GITHUB_TOKEN")
  raise "merge-publish-github-token-fallback" if merge_publish_serialized.include?("secrets.RPM_AUTOMATION_GITHUB_TOKEN || github.token")
  raise "merge-publish-checkout-pin" unless merge_publish_serialized.include?("actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683")
  raise "merge-publish-download-pin" unless merge_publish_serialized.include?("actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093")
  raise "merge-publish-validate-lane" unless merge_publish_serialized.include?("--lane merge")
  raise "merge-publish-script" unless merge_publish_serialized.include?("publish-cloud-merge.sh")
  raise "merge-publish-trusted-revision-step" unless merge_publish_serialized.include?("Verify trusted workflow revision")
  %w[WORKFLOW_SHA rpm-cloud-tools rev-parse].each do |marker|
    raise "merge-publish-trusted-revision-#{marker}" unless merge_publish_serialized.include?(marker)
  end
  %w[select-issue select-review select-merge].each do |name|
    raise "#{name}-read-permissions" unless jobs.fetch(name).fetch("permissions").fetch("contents") == "read"
  end
  raise "issue-outputs" unless %w[selected issue base_ref base_sha].all? { |key| jobs.fetch("select-issue").fetch("outputs").key?(key) }
  raise "review-outputs" unless %w[selected issue pr base_ref base_sha head_ref head_sha correction_limit_exhausted terminal_issue terminal_pr terminal_base_ref terminal_base_sha terminal_head_ref terminal_head_sha terminal_reason].all? { |key| jobs.fetch("select-review").fetch("outputs").key?(key) }
  raise "merge-outputs" unless %w[selected issue base_ref base_sha anomaly anomaly_issue anomaly_reason anomaly_details].all? { |key| jobs.fetch("select-merge").fetch("outputs").key?(key) }
  select_merge_if = jobs.fetch("select-merge").fetch("if").to_s
  true_literal = 39.chr + "true" + 39.chr
  auto_merge_gate = "vars.CODEX_CLOUD_AUTO_MERGE_ENABLED == #{true_literal}"
  raise "merge-auto-gate-missing" unless select_merge_if.include?(auto_merge_gate)
  raise "merge-auto-gate-count" unless select_merge_if.scan(auto_merge_gate).length == 1
  raise "merge-automation-gate-missing" unless select_merge_if.include?("vars.CODEX_CLOUD_AUTOMATION_ENABLED == #{true_literal}")
  %w[issue-cloud review-cloud merge-cloud].each do |name|
    upload_steps = Array(jobs.fetch(name)["steps"]).select { |step| step.is_a?(Hash) && step["uses"].to_s.start_with?("actions/upload-artifact@") }
    raise "#{name}-artifact" unless upload_steps.length == 1 && upload_steps.first.fetch("with").fetch("retention-days") == 1
  end
' "$workflow" || fail 'yaml-contract'

assert_contains() {
  local text="$1"
  grep -Fq -- "$text" "$workflow" || fail "missing:${text}"
}

assert_absent() {
  local text="$1"
  if grep -Fq -- "$text" "$workflow"; then
    fail "forbidden:${text}"
  fi
}

assert_contains 'schedule:'
assert_contains 'cron: "*/5 * * * *"'
assert_contains 'repository_dispatch:'
assert_contains 'types: [codex-cloud-run]'
assert_absent 'workflow_dispatch:'
assert_absent "github.event_name == 'workflow_dispatch'"
assert_contains 'types: [labeled]'
assert_absent 'pull_request_review:'
assert_absent 'pull_request_review_comment:'
assert_absent 'pull_request:'
assert_absent "github.event_name == 'pull_request_review'"
assert_absent "github.event_name == 'pull_request_review_comment'"
assert_absent "github.event_name == 'pull_request'"
assert_contains 'workflow_run:'
assert_contains 'workflows: ["Rust", "PR Metadata"]'
assert_absent 'pull_request_target:'
assert_contains "vars.CODEX_CLOUD_AUTOMATION_ENABLED == 'true'"
[ "$(grep -Fc -- "vars.CODEX_CLOUD_AUTOMATION_ENABLED == 'true'" "$workflow")" -eq 3 ] || fail 'automation-enable-gate-count'
assert_contains "vars.CODEX_CLOUD_AUTO_MERGE_ENABLED == 'true'"
[ "$(grep -Fc -- "vars.CODEX_CLOUD_AUTO_MERGE_ENABLED == 'true'" "$workflow")" -eq 1 ] || fail 'auto-merge-enable-gate-count'
assert_contains "github.ref == 'refs/heads/main'"
[ "$(grep -Fc -- "github.ref == 'refs/heads/main'" "$workflow")" -eq 3 ] || fail 'manual-dispatch-main-guard-count'
assert_contains 'github.event.client_payload.lane'
[ "$(grep -Fc -- 'github.event.client_payload.lane' "$workflow")" -eq 6 ] || fail 'repository-dispatch-lane-count'
assert_contains "github.actor == 'nerdchanii'"
[ "$(grep -Fc -- "github.actor == 'nerdchanii'" "$workflow")" -eq 4 ] || fail 'trusted-trigger-actor-count'

assert_contains 'agent:ready'
assert_contains 'queue_states='
assert_contains 'reason=active-work'
for label in agent:review-pending agent:awaiting-merge; do
  assert_contains "--label '${label}'"
done
assert_contains 'sort_by(.number) | .[0].number // empty'
[ "$(grep -Fc -- '--state open' "$workflow")" -eq 5 ] || fail 'open-selector-count'
assert_contains 'defaultBranchRef'
assert_contains 'git/ref/heads/${base_ref}'
assert_contains 'base_sha='
assert_contains 'head_sha='
assert_contains 'head.repo.full_name'
assert_contains 'base.repo.full_name'
assert_contains 'merge-selector-quarantine'
assert_contains 'review-selector-quarantine'
assert_contains 'correction_limit_exhausted'
assert_contains 'quarantine-review-correction-limit.sh'
assert_contains 'scripts/quarantine-review-correction-limit*'
assert_contains 'needs.select-review.result == '\''success'\'''
assert_contains 'terminal_base_sha'
assert_contains 'terminal_reason'
assert_contains 'Move exhausted review to blocked with one reason'
assert_contains '--reason "$TERMINAL_REASON"'
assert_contains 'correction-history-sequence-missing'
assert_contains 'anomaly_reason'
assert_contains 'no-closing-pr'
assert_contains 'fork-pr'
assert_contains 'multiple-prs'
assert_contains 'unsafe-base'
assert_contains 'unsafe-head'
assert_contains 'stale-base'
assert_contains 'multiple-closing-references'
assert_contains 'quarantine-merge-selector-anomaly.sh'
assert_contains 'open_fork=1'
assert_contains 'Invalid linked PR'
assert_contains 'git check-ref-format --branch "$head_ref"'
assert_contains 'git check-ref-format --branch "$HEAD_REF"'
assert_contains 'gh api --paginate --slurp'
assert_contains 'sort_by(.number) | .[].number'
assert_contains 'protected_review_path()'
assert_contains '/pulls/${pr_number}/files?per_page=100'
assert_contains 'length == $count'
assert_contains 'Protected review path'
assert_contains 'changed during protected-path validation'
assert_contains 'echo "selection=issue-${issue_number} pr=${pr_number}'
assert_contains '            break'
for protected_head in main master develop release HEAD; do
  assert_contains "|${protected_head}|"
done

assert_contains '"@openai/codex@0.152.0"'
assert_contains '--ignore-scripts'
assert_contains '--no-audit'
assert_contains '--no-fund'
assert_absent 'login --with-access-token'
assert_absent 'auth.json'
assert_absent '--branch main'
assert_absent 'MERGE_BRANCH'
assert_contains 'cloud exec --env "$CODEX_CLOUD_ENV_ID" --branch "$BASE_SHA" --attempts 1 "$prompt"'
assert_contains 'cloud exec --env "$CODEX_CLOUD_ENV_ID" --branch "$HEAD_SHA" --attempts 1 "$prompt"'
assert_contains 'cloud exec --env "$CODEX_CLOUD_ENV_ID" --branch "$BASE_SHA" --attempts 1 "$prompt"'
assert_contains 'dispatch_base_sha='
assert_contains 'cloud diff --attempt 1 "$task_id"'
[ "$(grep -Fc -- 'cloud diff --attempt 1 "$task_id"' "$workflow")" -eq 3 ] || fail 'cloud-diff-download-count'
[ "$(grep -Fc -- 'unset GH_TOKEN' "$workflow")" -eq 3 ] || fail 'gh-token-unset-boundary-count'
assert_contains 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'
assert_contains 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
[ "$(grep -Fc -- 'actions/upload-artifact@' "$workflow")" -eq 3 ] || fail 'upload-artifact-count'
[ "$(grep -Fc -- 'actions/download-artifact@' "$workflow")" -eq 3 ] || fail 'download-artifact-count'
assert_contains 'retention-days: 1'
assert_contains 'CLOUD_ARTIFACT_NAME: codex-cloud-issue-${{ github.run_id }}-${{ github.run_attempt }}'
assert_contains 'CLOUD_ARTIFACT_NAME: codex-cloud-review-${{ github.run_id }}-${{ github.run_attempt }}'
assert_contains 'CLOUD_ARTIFACT_NAME: codex-cloud-merge-${{ github.run_id }}-${{ github.run_attempt }}'

for lane in issue review merge; do
  assert_contains "environment: codex-cloud-${lane}"
  assert_contains "EXPECTED_CLOUD_LANE: ${lane}"
done
assert_contains 'cloud list --json --env "$CODEX_CLOUD_ENV_ID" --limit 20'
assert_contains 'ready|applied)'
assert_contains 'rpm_cloud_result_writer'
assert_contains 'Do not commit, push, create/update a PR'
assert_contains 'Do not change final lifecycle labels in Cloud'
assert_contains 'The sole exception is the take-ticket contract for a policy-checked malformed-ready candidate'
assert_contains 'agent:ready to agent:blocked quarantine'
assert_contains 'Do not select a replacement issue or retry that demotion'
assert_contains 'validate-cloud-diff.sh'
assert_contains 'publish-cloud-diff.sh'
assert_contains '--expected-base-sha "$BASE_SHA"'
assert_contains '--expected-head-sha "$HEAD_SHA"'
assert_contains '--code-patch-out "$VALIDATED_PATCH"'
assert_contains '--result-out "$RESULT_FILE"'
assert_contains '--mode issue'
assert_contains '--mode review'
assert_contains '--expected-pr "$PR_NUMBER"'
assert_contains '--expected-head-ref "$HEAD_REF"'
assert_contains '--lane merge'
assert_contains 'publish-cloud-merge.sh'
assert_contains 'GITHUB_RUN_ATTEMPT'
assert_contains 'dispatcher_run_id='
assert_contains 'event_id=github-actions:${GITHUB_RUN_ID}:${GITHUB_RUN_ATTEMPT}:issue'
assert_contains 'event_id=github-actions:${GITHUB_RUN_ID}:${GITHUB_RUN_ATTEMPT}:review'
assert_contains 'event_id=github-actions:${GITHUB_RUN_ID}:${GITHUB_RUN_ATTEMPT}:merge'
assert_contains '(.run_id == $run_id)'
assert_contains 'any(.[]; .run_id == $run_id and .event_id == $event)'
assert_absent "github.actor == 'chatgpt-codex-connector'"
assert_contains 'Keep the execution batch limit at 1.'
assert_contains 'correction limit of 5'
assert_absent "github.actor == 'chatgpt-codex-connector[bot]'"
for untrusted in github.event.issue.title github.event.issue.body github.event.comment.body github.event.review.body; do
  assert_absent "$untrusted"
done
assert_absent 'gh pr merge'
assert_absent 'merge_pull_request'
assert_contains 'Do not call any GitHub connector, merge tool, gh command'
assert_contains 'Verify trusted workflow revision'
assert_contains '[ "$(git -C "$GITHUB_WORKSPACE" rev-parse HEAD)" = "$BASE_SHA" ]'
assert_contains '[ "$(git -C "$GITHUB_WORKSPACE/rpm-cloud-tools" rev-parse HEAD)" = "$WORKFLOW_SHA" ]'
assert_contains '[ "$WORKFLOW_SHA" = "$BASE_SHA" ]'
grep -Fq 'mergePullRequest' "${repo_root}/scripts/publish-cloud-merge.sh" || fail 'trusted-merge-script-missing'
grep -Fq 'expectedHeadOid' "${repo_root}/scripts/publish-cloud-merge.sh" || fail 'trusted-merge-head-cas-missing'
grep -Fq 'mergeMethod:"SQUASH"' "${repo_root}/scripts/publish-cloud-merge.sh" || fail 'trusted-squash-method-missing'
bash "${repo_root}/scripts/test-quarantine-merge-selector-anomaly.sh" >/dev/null || fail 'merge-selector-quarantine-regression'
bash "${repo_root}/scripts/test-quarantine-review-correction-limit.sh" >/dev/null || fail 'review-correction-quarantine-regression'

runs_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-codex-cloud-runs.XXXXXX")"
trap 'rm -rf "$runs_dir"' EXIT
export RUNNER_TEMP="$runs_dir"
ruby -ryaml -e '
  document = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  index = 0
  document.fetch("jobs").each do |job_name, job|
    Array(job["steps"]).each do |step|
      next unless step.is_a?(Hash) && step["run"].is_a?(String)
      slug = step.fetch("name", "step").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
      File.write(File.join(ARGV.fetch(1), format("run-%02d-%s-%s.sh", index, job_name, slug)), step.fetch("run"))
      index += 1
    end
  end
' "$workflow" "$runs_dir"
for run_script in "$runs_dir"/*.sh; do
  bash -n "$run_script" || fail "embedded-shell-invalid:${run_script##*/}"
done

# Recovery must reject a marker that only names the Cloud run. A malformed
# marker must not be able to trigger the claimed-to-blocked mutation.
recovery_script="$(find "$runs_dir" -type f -name '*-issue-recover-*.sh' -print -quit)"
[ -n "$recovery_script" ] || fail 'recovery-script-missing'
recovery_bin="${runs_dir}/recovery-bin"
mkdir -p "$recovery_bin"
recovery_state="${runs_dir}/recovery-minimal-state.json"
recovery_log="${runs_dir}/recovery-minimal-gh.log"
minimal_execution_marker='<!-- rpm-agent-execution: {"executor":"cloud","lease":{"run_id":"123:1","owner":"cloud:test","expires_at":"2099-01-01T00:00:00Z"},"runs":[{"run_id":"123:1","event_id":"github-actions:123:1:issue"}]} -->'
jq -nc --arg body "$minimal_execution_marker" \
  '{number:42,state:"OPEN",body:$body,labels:[{name:"agent:claimed"}],comments:[]}' >"$recovery_state"
cat >"${recovery_bin}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
request="$*"
printf '%s\n' "$request" >>"${RECOVERY_LOG:?}"
case "$request" in
  *"issue view"*) cat "${RECOVERY_STATE:?}" ;;
  *"issue edit"*)
    jq '(.labels = [.labels[] | select(.name != "agent:claimed")] + [{name:"agent:blocked"}])' \
      "${RECOVERY_STATE:?}" >"${RECOVERY_STATE:?}.next"
    mv "${RECOVERY_STATE:?}.next" "${RECOVERY_STATE:?}"
    ;;
  *"issue comment"*)
    body=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --body ]; then
        body="${2:-}"
        shift 2
      else
        shift
      fi
    done
    jq --arg body "$body" '(.comments += [{body:$body}])' \
      "${RECOVERY_STATE:?}" >"${RECOVERY_STATE:?}.next"
    mv "${RECOVERY_STATE:?}.next" "${RECOVERY_STATE:?}"
    ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${recovery_bin}/gh"
set +e
env PATH="${recovery_bin}:$PATH" \
  RECOVERY_STATE="$recovery_state" RECOVERY_LOG="$recovery_log" \
  GH_TOKEN=test-token ISSUE_NUMBER=42 GITHUB_REPOSITORY=nerdchanii/rpm \
  GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 GITHUB_SERVER_URL=https://github.com \
  GITHUB_STEP_SUMMARY="${runs_dir}/recovery-minimal.summary" \
  bash "$recovery_script" >"${runs_dir}/recovery-minimal.output" 2>&1
recovery_status=$?
set -e
[ "$recovery_status" -ne 0 ] || fail 'recovery-minimal-marker-succeeded'
! grep -Fq 'issue edit' "$recovery_log" || fail 'recovery-minimal-marker-edited'
! grep -Fq 'issue comment' "$recovery_log" || fail 'recovery-minimal-marker-commented'

# A complete-looking marker owned by another Action run is also rejected.
wrong_recovery_state="${runs_dir}/recovery-wrong-owner-state.json"
wrong_recovery_log="${runs_dir}/recovery-wrong-owner-gh.log"
wrong_owner_plan='test-plan'
wrong_owner_scope='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
wrong_owner_event='github-actions:999:1:issue'
wrong_owner_key="$(python3 - nerdchanii/rpm 42 "$wrong_owner_plan" "$wrong_owner_scope" "$wrong_owner_event" <<'PY'
import hashlib
import sys

print("sha256:" + hashlib.sha256("\0".join(sys.argv[1:]).encode("utf-8")).hexdigest())
PY
  )"
wrong_owner_marker="$(jq -nc --arg plan_revision "$wrong_owner_plan" --arg scope_hash "$wrong_owner_scope" \
  --arg event_id "$wrong_owner_event" --arg idempotency_key "$wrong_owner_key" \
  '{approval_id:"test-approval",plan_revision:$plan_revision,scope_hash:$scope_hash,executor:"cloud",lease:{run_id:"999:1",owner:"cloud:other",expires_at:"2099-01-01T00:00:00Z"},runs:[{repository:"nerdchanii/rpm",issue:42,plan_revision:$plan_revision,scope_hash:$scope_hash,event_id:$event_id,idempotency_key:$idempotency_key,run_id:"999:1",status:"active"}]}')"
jq -nc --arg body "<!-- rpm-agent-execution: ${wrong_owner_marker} -->" \
  '{number:42,state:"OPEN",body:$body,labels:[{name:"agent:claimed"}],comments:[]}' >"$wrong_recovery_state"
: >"$wrong_recovery_log"
set +e
env PATH="${recovery_bin}:$PATH" \
  RECOVERY_STATE="$wrong_recovery_state" RECOVERY_LOG="$wrong_recovery_log" \
  GH_TOKEN=test-token ISSUE_NUMBER=42 GITHUB_REPOSITORY=nerdchanii/rpm \
  GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 GITHUB_SERVER_URL=https://github.com \
  GITHUB_STEP_SUMMARY="${runs_dir}/recovery-wrong-owner.summary" \
  bash "$recovery_script" >"${runs_dir}/recovery-wrong-owner.output" 2>&1
wrong_recovery_status=$?
set -e
[ "$wrong_recovery_status" -ne 0 ] || fail 'recovery-wrong-owner-succeeded'
! grep -Fq 'issue edit' "$wrong_recovery_log" || fail 'recovery-wrong-owner-edited'
! grep -Fq 'issue comment' "$wrong_recovery_log" || fail 'recovery-wrong-owner-commented'

run_recovery_claim_case() {
  local name="$1" expires_at="$2"
  local state="${runs_dir}/recovery-${name}-state.json"
  local log="${runs_dir}/recovery-${name}-gh.log"
  local output="${runs_dir}/recovery-${name}.output"
  local summary="${runs_dir}/recovery-${name}.summary"
  local plan_revision='test-plan'
  local scope_hash='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  local event_id='github-actions:123:1:issue'
  local expected_key marker body
  expected_key="$(python3 - nerdchanii/rpm 42 "$plan_revision" "$scope_hash" "$event_id" <<'PY'
import hashlib
import sys

print("sha256:" + hashlib.sha256("\0".join(sys.argv[1:]).encode("utf-8")).hexdigest())
PY
  )"
  marker="$(jq -nc --arg plan_revision "$plan_revision" --arg scope_hash "$scope_hash" \
    --arg event_id "$event_id" --arg expires_at "$expires_at" --arg expected_key "$expected_key" \
    '{approval_id:"test-approval",plan_revision:$plan_revision,scope_hash:$scope_hash,executor:"cloud",lease:{run_id:"123:1",owner:"cloud:test",expires_at:$expires_at},runs:[{repository:"nerdchanii/rpm",issue:42,plan_revision:$plan_revision,scope_hash:$scope_hash,event_id:$event_id,idempotency_key:$expected_key,run_id:"123:1",status:"active"}]}')"
  body="$(printf 'Issue context\n\n<!-- rpm-agent-execution: %s -->\n\nAdditional issue text\n' "$marker")"
  jq -nc --arg body "$body" \
    '{number:42,state:"OPEN",body:$body,labels:[{name:"agent:claimed"}],comments:[]}' >"$state"
  : >"$log"
  set +e
  env PATH="${recovery_bin}:$PATH" \
    RECOVERY_STATE="$state" RECOVERY_LOG="$log" \
    GH_TOKEN=test-token ISSUE_NUMBER=42 GITHUB_REPOSITORY=nerdchanii/rpm \
    GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 GITHUB_SERVER_URL=https://github.com \
    GITHUB_STEP_SUMMARY="$summary" bash "$recovery_script" >"$output" 2>&1
  local status=$?
  set -e
  [ "$status" -eq 0 ] || { sed 's/^/DEBUG /' "$output" >&2; fail "recovery-${name}-failed"; }
  jq -e --arg marker 'rpm-agent-cloud-recovery: issue=42;run=123:1' '
    .state == "OPEN" and
    ([.labels[].name] | sort) == ["agent:blocked"] and
    any(.comments[]; (.body | contains($marker)))
  ' "$state" >/dev/null || fail "recovery-${name}-state"
  [ "$(rg -c 'issue edit 42' "$log" || true)" -eq 1 ] || fail "recovery-${name}-edit-count"
  [ "$(rg -c 'issue comment 42' "$log" || true)" -eq 1 ] || fail "recovery-${name}-comment-count"
}

run_recovery_claim_case future '2099-01-01T00:00:00.123+00:00'
run_recovery_claim_case expired '2000-01-01T00:00:00.123+00:00'

fake_codex="${runs_dir}/fake-codex"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [ "${1:-} ${2:-}" = "cloud exec" ]; then' \
  '  printf "%s\\n" "https://chatgpt.com/codex/tasks/task-test"' \
  'elif [ "${1:-} ${2:-}" = "cloud list" ]; then' \
  '  jq -nc --arg status "${FAKE_TASK_STATUS:-ready}" '\''{tasks:[{id:"task-test",status:$status}],cursor:null}'\''' \
  'elif [ "${1:-} ${2:-}" = "cloud diff" ]; then' \
  '  printf "%s\\n" "diff --git a/src.txt b/src.txt"' \
  'else' \
  '  exit 99' \
  'fi' >"$fake_codex"
chmod +x "$fake_codex"

fake_gh="${runs_dir}/gh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'request="$*"' \
  'if [[ "$request" == *"/git/ref/heads/main"* ]]; then' \
  '  printf "%s\\n" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  'elif [[ "$request" == *"issue view"* ]]; then' \
  '  if [ "${FAKE_GH_LANE:-issue}" = review ]; then printf "%s\\n" '\''{"state":"OPEN","labels":[{"name":"agent:review-pending"}]}'\''; else printf "%s\\n" '\''{"state":"OPEN","labels":[{"name":"agent:ready"}]}'\''; fi' \
  'elif [[ "$request" == *"/pulls/77"* ]]; then' \
  '  printf "%s\\n" '\''{"state":"open","base":{"ref":"main","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"feat/test","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"nerdchanii/rpm"}}}'\''' \
  'else' \
  '  exit 99' \
  'fi' >"$fake_gh"
chmod +x "$fake_gh"

run_submission() {
  local lane="$1"
  local submit_script
  submit_script="$(find "$runs_dir" -type f -name "*-${lane}-cloud-submit-*.sh" -print -quit)"
  [ -n "$submit_script" ] || fail "${lane}-submit-script-missing"
  local summary="${runs_dir}/${lane}.summary"
  env \
    PATH="$runs_dir:$PATH" \
    FAKE_GH_LANE="$lane" \
    CODEX_BIN="$fake_codex" \
    CODEX_ACCESS_TOKEN=test-token \
    CODEX_CLOUD_ENV_ID=environment-test \
    ISSUE_NUMBER=42 \
    PR_NUMBER=77 \
    BASE_REF=main \
    BASE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    HEAD_REF=feat/test \
    HEAD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    CLOUD_ARTIFACT_NAME="codex-cloud-${lane}-123-1" \
    RUNNER_TEMP="$runs_dir" \
    GITHUB_SERVER_URL=https://github.com \
    GITHUB_REPOSITORY=nerdchanii/rpm \
    GITHUB_RUN_ID=123 \
    GITHUB_RUN_ATTEMPT=1 \
    GITHUB_STEP_SUMMARY="$summary" \
    bash "$submit_script" >/dev/null || fail "${lane}-ready-poll-flow"
  grep -Fq 'task_status: ready' "$summary" || fail "${lane}-ready-summary"
  [ -s "${runs_dir}/codex-cloud-${lane}-123-1.patch" ] || fail "${lane}-diff-download"
}

run_submission issue
run_submission review

issue_submit_script="$(find "$runs_dir" -type f -name '*-issue-cloud-submit-*.sh' -print -quit)"
[ -n "$issue_submit_script" ] || fail 'issue-submit-script-missing-for-error'
set +e
env \
  PATH="$runs_dir:$PATH" \
  FAKE_GH_LANE=issue \
  FAKE_TASK_STATUS=error \
  CODEX_BIN="$fake_codex" \
  CODEX_ACCESS_TOKEN=test-token \
  CODEX_CLOUD_ENV_ID=environment-test \
  ISSUE_NUMBER=42 \
  BASE_REF=main \
  BASE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  HEAD_REF=feat/test \
  HEAD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  CLOUD_ARTIFACT_NAME=codex-cloud-issue-124-1 \
  RUNNER_TEMP="$runs_dir" \
  GITHUB_SERVER_URL=https://github.com \
  GITHUB_REPOSITORY=nerdchanii/rpm \
  GITHUB_RUN_ID=124 \
  GITHUB_RUN_ATTEMPT=1 \
  GITHUB_STEP_SUMMARY="${runs_dir}/error.summary" \
  bash "$issue_submit_script" >/dev/null 2>&1
error_status=$?
set -e
[ "$error_status" -ne 0 ] || fail 'cloud-error-reported-success'

# Review selection must stop after the first eligible issue. A second normal
# candidate is deliberately made unreachable so this exercises the queue
# liveness contract instead of only checking for a textual `break`.
selector_bin="${runs_dir}/selector-bin"
mkdir -p "$selector_bin"
selector_gh="${selector_bin}/gh"
cat >"$selector_gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
request="$*"
selector_correction="${SELECTOR_CORRECTION:-agent:correction-0}"
case "$selector_correction" in
  agent:correction-0|agent:correction-1|agent:correction-2|agent:correction-3|agent:correction-4|agent:correction-5)
    selector_counter="${selector_correction##*-}"
    ;;
  *)
    selector_counter=0
    ;;
esac
case "$request" in
  *"--json number,labels"*)
    case "${SELECTOR_QUEUE_MODE:-single}" in
      truncated)
        jq -nc '[range(1;1001) | {number:.,labels:[{name:"agent:ready"}]}]'
        ;;
      multi)
        printf '%s\n' '[{"number":10,"labels":[{"name":"agent:review-pending"}]},{"number":11,"labels":[{"name":"agent:claimed"}]}]'
        ;;
      *)
        printf '%s\n' '[{"number":10,"labels":[{"name":"agent:review-pending"}]}]'
        ;;
    esac
    ;;
  "issue list"*)
    if [ "${SELECTOR_QUEUE_MODE:-single}" = multi ]; then
      printf '%s\n' 'review candidate query should be skipped when multiple issues are active' >&2
      exit 93
    fi
    if [ "${SELECTOR_QUEUE_MODE:-single}" = review-truncated ]; then
      jq -nc '[range(1;1001) | {number:.}]'
    else
      printf '%s\n' '[{"number":10},{"number":20}]'
    fi
    ;;
  *"--json number,state,labels"*)
    jq -nc --argjson comments '[]' '{number:10,state:"OPEN",labels:[{name:"agent:review-pending"}],comments:$comments}'
    ;;
  *"pullRequest(number:"*"closingIssuesReferences(first:100"*)
    after=''
    number=77
    for argument in "$@"; do
      case "$argument" in
        after=*) after="${argument#after=}" ;;
        number=*) number="${argument#number=}" ;;
      esac
    done
    closing_mode="${SELECTOR_CLOSING_MODE:-valid}"
    case "$closing_mode" in
      malformed)
        printf '%s\n' '{"data":{}}'
        exit 0
        ;;
      graphql-errors)
        printf '%s\n' '{"errors":[{"message":"synthetic GraphQL failure"}],"data":null}'
        exit 0
        ;;
      cursor-stalled)
        jq -nc --argjson pr "$number" --arg cursor "${after:-selector-closing-cursor-1}" \
          '{data:{repository:{nameWithOwner:"nerdchanii/rpm",pullRequest:{number:$pr,repository:{nameWithOwner:"nerdchanii/rpm"},closingIssuesReferences:{pageInfo:{hasNextPage:true,endCursor:$cursor},nodes:[]}}}}}'
        exit 0
        ;;
      duplicate-id)
        jq -nc --argjson pr "$number" \
          '{data:{repository:{nameWithOwner:"nerdchanii/rpm",pullRequest:{number:$pr,repository:{nameWithOwner:"nerdchanii/rpm"},closingIssuesReferences:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"closing-10",number:10,repository:{nameWithOwner:"nerdchanii/rpm"}},{id:"closing-10",number:11,repository:{nameWithOwner:"other/rpm"}}]}}}}}'
        exit 0
        ;;
    esac
    nodes='[{"id":"closing-10","number":10,"repository":{"nameWithOwner":"nerdchanii/rpm"}}]'
    has_next=false
    cursor=''
    if [ "$closing_mode" = extra ]; then
      nodes='[{"id":"closing-10","number":10,"repository":{"nameWithOwner":"nerdchanii/rpm"}},{"id":"closing-11","number":11,"repository":{"nameWithOwner":"nerdchanii/rpm"}}]'
    elif [ "$closing_mode" = cross-repo-extra ]; then
      if [ -z "$after" ]; then
        has_next=true
        cursor=selector-closing-cursor-1
      else
        nodes='[{"id":"closing-11","number":11,"repository":{"nameWithOwner":"other/rpm"}}]'
      fi
    elif [ "$closing_mode" = page-limit ]; then
      has_next=true
      cursor="selector-closing-cursor-${after:-0}-next"
      [ -z "$after" ] || nodes='[]'
    fi
    jq -nc --argjson pr "$number" --argjson nodes "$nodes" --arg cursor "$cursor" --argjson has_next "$has_next" \
      '{data:{repository:{nameWithOwner:"nerdchanii/rpm",pullRequest:{number:$pr,repository:{nameWithOwner:"nerdchanii/rpm"},closingIssuesReferences:{pageInfo:{hasNextPage:$has_next,endCursor:(if $cursor == "" then null else $cursor end)},nodes:$nodes}}}}}'
    ;;
  *"issue(number:"*"comments(first:100"*)
    after=''
    number=10
    for argument in "$@"; do
      case "$argument" in
        after=*) after="${argument#after=}" ;;
        number=*) number="${argument#number=}" ;;
      esac
    done
    comment_mode="${SELECTOR_COMMENT_MODE:-normal}"
    if [ "$comment_mode" = response-invalid ]; then
      printf '%s\n' '{"data":{}}'
    elif [ "$comment_mode" = graphql-errors ]; then
      printf '%s\n' '{"errors":[{"message":"synthetic GraphQL failure"}],"data":null}'
    elif [ "$comment_mode" = cursor-stalled ]; then
      jq -nc --argjson issue "$number" --arg cursor "${after:-selector-cursor-1}" \
        '{data:{repository:{nameWithOwner:"nerdchanii/rpm",issue:{number:$issue,repository:{nameWithOwner:"nerdchanii/rpm"},comments:{pageInfo:{hasNextPage:true,endCursor:$cursor},nodes:[]}}}}}'
    elif [ "$comment_mode" = page-limit ]; then
      next_cursor="selector-cursor-${after:-0}-next"
      jq -nc --argjson issue "$number" --arg cursor "$next_cursor" \
        '{data:{repository:{nameWithOwner:"nerdchanii/rpm",issue:{number:$issue,repository:{nameWithOwner:"nerdchanii/rpm"},comments:{pageInfo:{hasNextPage:true,endCursor:$cursor},nodes:[]}}}}}'
    else
      history_max="$selector_counter"
      history_author="github-actions[bot]"
      history_mode="${SELECTOR_HISTORY_MODE:-complete}"
      case "$history_mode" in
        missing) history_max=-1 ;;
        partial) history_max=$((selector_counter - 1)) ;;
        untrusted) history_author=human-user ;;
      esac
      history_comments="$(jq -nc --arg head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --argjson max_counter "$history_max" --arg author "$history_author" '[range(0; ($max_counter + 1)) | {id:("history-" + tostring),body:("<!-- rpm-agent-correction-history: pr=77; counter=agent:correction-" + tostring + "; head=" + $head + " -->"),author:{login:$author}}]')"
      if [ "$history_mode" = duplicate ] && [ "$history_max" -ge 0 ]; then
        history_comments="$(jq -c '. + [.[-1]]' <<<"$history_comments")"
      fi
      if [ "$history_mode" = wrong-head ] && [ "$history_max" -ge 0 ]; then
        history_comments="$(jq -c '.[-1].body |= sub("head=[0-9a-fA-F]+"; "head=cccccccccccccccccccccccccccccccccccccccc")' <<<"$history_comments")"
      fi
      if [ "$history_mode" = untrusted-extra ]; then
        history_comments="$(jq -c --arg head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb '. + [
          {id:"untrusted-exact",body:("<!-- rpm-agent-correction-history: pr=77; counter=agent:correction-5; head=" + $head + " -->"),author:{login:"human-user"}},
          {id:"anonymous-malformed",body:"<!-- rpm-agent-correction-history: malformed",author:null}
        ]' <<<"$history_comments")"
      fi
      if [ "$history_mode" = second-page ]; then
        history_comments="$(jq -c --argjson history "$history_comments" '[range(0;100) | {id:("filler-" + tostring),body:"ordinary comment",author:null}] + $history' <<<"$history_comments")"
      fi
      if [ "$comment_mode" = duplicate-id ]; then
        nodes="$(jq -c '.[0:1] + .[0:1]' <<<"$history_comments")"
        has_next=false
        cursor=''
      elif [ "$history_mode" = second-page ] && [ -z "$after" ]; then
        nodes="$(jq -c '.[0:100]' <<<"$history_comments")"
        has_next=true
        cursor=selector-cursor-1
      elif [ "$history_mode" = second-page ]; then
        nodes="$(jq -c '.[100:]' <<<"$history_comments")"
        has_next=false
        cursor=''
      else
        nodes="$history_comments"
        has_next=false
        cursor=''
      fi
      jq -nc --argjson issue "$number" --argjson nodes "$nodes" --arg cursor "$cursor" --argjson has_next "$has_next" \
        '{data:{repository:{nameWithOwner:"nerdchanii/rpm",issue:{number:$issue,repository:{nameWithOwner:"nerdchanii/rpm"},comments:{pageInfo:{hasNextPage:$has_next,endCursor:(if $cursor == "" then null else $cursor end)},nodes:$nodes}}}}}'
    fi
    ;;
  "repo view"*)
    printf '%s\n' 'main'
    ;;
  *"/git/ref/heads/main"*)
    printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    ;;
  *"/issues/10/timeline"*)
    printf '%s\n' '[[{"event":"cross-referenced","source":{"issue":{"number":77,"pull_request":{"url":"https://github.com/nerdchanii/rpm/pull/77"}}}}]]'
    ;;
  *"/issues/20/timeline"*)
    printf '%s\n' 'second candidate should not be queried' >&2
    exit 91
    ;;
  "pr view 77 --repo nerdchanii/rpm --json closingIssuesReferences")
    case "${SELECTOR_CLOSING_MODE:-valid}" in
      extra) printf '%s\n' '{"closingIssuesReferences":[{"number":10,"repository":{"name":"rpm","owner":{"login":"nerdchanii"}}},{"number":11,"repository":{"name":"rpm","owner":{"login":"nerdchanii"}}}]}' ;;
      wrong-repository) printf '%s\n' '{"closingIssuesReferences":[{"number":10,"repository":{"name":"rpm","owner":{"login":"evil"}}}]}' ;;
      *) printf '%s\n' '{"closingIssuesReferences":[{"number":10,"repository":{"name":"rpm","owner":{"login":"nerdchanii"}}}]}' ;;
    esac
    ;;
  *"/pulls/77/files?per_page=100"*)
    if [ "$selector_correction" = agent:correction-5 ]; then
      printf '%s\n' 'correction-5 review must stop before changed-file inventory' >&2
      exit 89
    fi
    jq -nc --arg path "${SELECTOR_FILE:-src/lib.rs}" '[[{filename:$path}]]'
    ;;
  *"/pulls/77"*)
    jq -nc --arg correction "$selector_correction" '{state:"open",changed_files:1,base:{ref:"main",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{full_name:"nerdchanii/rpm"}},head:{ref:"feat/first",sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",repo:{full_name:"nerdchanii/rpm"}},labels:[{name:$correction}]}'
    ;;
  *)
    printf 'unexpected selector gh call: %s\n' "$request" >&2
    exit 92
    ;;
esac
EOF
chmod +x "$selector_gh"
review_selector="$(find "$runs_dir" -type f -name '*-select-review-*.sh' -print -quit)"
[ -n "$review_selector" ] || fail 'review-selector-script-missing'
selector_output="${runs_dir}/review-selector.output"
selector_outputs="${runs_dir}/review-selector.outputs"
selector_summary="${runs_dir}/review-selector.summary"
env PATH="$selector_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=nerdchanii/rpm GITHUB_OUTPUT="$selector_outputs" GITHUB_STEP_SUMMARY="$selector_summary" bash "$review_selector" >"$selector_output" || fail 'review-selector-first-candidate'
grep -Fxq 'selected=true' "$selector_outputs" || fail 'review-selector-selected'
grep -Fxq 'issue=10' "$selector_outputs" || fail 'review-selector-first-issue'
grep -Fxq 'pr=77' "$selector_outputs" || fail 'review-selector-first-pr'
! grep -Fq 'issue=20' "$selector_outputs" || fail 'review-selector-queried-second-issue'

# Complete histories at counters below the terminal limit remain eligible for
# one review Cloud execution.
valid_counter_outputs="${runs_dir}/review-selector-counter-4.outputs"
valid_counter_summary="${runs_dir}/review-selector-counter-4.summary"
env PATH="$selector_bin:$PATH" GITHUB_REPOSITORY=nerdchanii/rpm \
  SELECTOR_CORRECTION=agent:correction-4 SELECTOR_HISTORY_MODE=complete \
  GITHUB_OUTPUT="$valid_counter_outputs" GITHUB_STEP_SUMMARY="$valid_counter_summary" \
  bash "$review_selector" >/dev/null || fail 'review-selector-valid-counter-failed'
grep -Fxq 'selected=true' "$valid_counter_outputs" || fail 'review-selector-valid-counter-not-selected'
grep -Fxq 'correction_limit_exhausted=false' "$valid_counter_outputs" || fail 'review-selector-valid-counter-terminal'
grep -Fxq 'terminal_reason=' "$valid_counter_outputs" || fail 'review-selector-valid-counter-reason'

# A trusted correction marker after a full first page of ordinary comments is
# still part of the complete history. The selector must paginate before
# deciding whether the candidate may spend another correction.
second_page_outputs="${runs_dir}/review-selector-second-page.outputs"
second_page_summary="${runs_dir}/review-selector-second-page.summary"
env PATH="$selector_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=nerdchanii/rpm \
  SELECTOR_HISTORY_MODE=second-page SELECTOR_CORRECTION=agent:correction-1 \
  GITHUB_OUTPUT="$second_page_outputs" GITHUB_STEP_SUMMARY="$second_page_summary" \
  bash "$review_selector" >/dev/null || fail 'review-selector-second-page-failed'
grep -Fxq 'selected=true' "$second_page_outputs" || fail 'review-selector-second-page-not-selected'
grep -Fxq 'correction_limit_exhausted=false' "$second_page_outputs" || fail 'review-selector-second-page-terminal'

# Marker-shaped comments from an untrusted or deleted author are ordinary
# comments. They must not block a valid trusted history or start quarantine.
untrusted_extra_outputs="${runs_dir}/review-selector-untrusted-extra.outputs"
untrusted_extra_summary="${runs_dir}/review-selector-untrusted-extra.summary"
env PATH="$selector_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=nerdchanii/rpm \
  SELECTOR_HISTORY_MODE=untrusted-extra SELECTOR_CORRECTION=agent:correction-4 \
  GITHUB_OUTPUT="$untrusted_extra_outputs" GITHUB_STEP_SUMMARY="$untrusted_extra_summary" \
  bash "$review_selector" >/dev/null || fail 'review-selector-untrusted-extra-failed'
grep -Fxq 'selected=true' "$untrusted_extra_outputs" || fail 'review-selector-untrusted-extra-blocked'
grep -Fxq 'correction_limit_exhausted=false' "$untrusted_extra_outputs" || fail 'review-selector-untrusted-extra-terminal'

# A review PR with more than one closing issue is never eligible for Cloud.
# The selector must emit an immutable terminal snapshot so the trusted
# quarantine job can block the selected issue instead of retrying forever.
closing_extra_outputs="${runs_dir}/review-selector-closing-extra.outputs"
closing_extra_summary="${runs_dir}/review-selector-closing-extra.summary"
env PATH="$selector_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=nerdchanii/rpm \
  SELECTOR_CLOSING_MODE=extra SELECTOR_CORRECTION=agent:correction-1 \
  GITHUB_OUTPUT="$closing_extra_outputs" GITHUB_STEP_SUMMARY="$closing_extra_summary" \
  bash "$review_selector" >"${runs_dir}/review-selector-closing-extra.output" 2>&1 || { sed 's/^/DEBUG /' "${runs_dir}/review-selector-closing-extra.output" >&2; fail 'review-selector-closing-extra-failed'; }
grep -Fxq 'selected=false' "$closing_extra_outputs" || fail 'review-selector-closing-extra-selected'
grep -Fxq 'correction_limit_exhausted=true' "$closing_extra_outputs" || fail 'review-selector-closing-extra-terminal-output'
grep -Fxq 'terminal_issue=10' "$closing_extra_outputs" || fail 'review-selector-closing-extra-terminal-issue'
grep -Fxq 'terminal_pr=77' "$closing_extra_outputs" || fail 'review-selector-closing-extra-terminal-pr'
grep -Fxq 'terminal_base_ref=main' "$closing_extra_outputs" || fail 'review-selector-closing-extra-terminal-base-ref'
grep -Fxq 'terminal_base_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$closing_extra_outputs" || fail 'review-selector-closing-extra-terminal-base-sha'
grep -Fxq 'terminal_head_ref=feat/first' "$closing_extra_outputs" || fail 'review-selector-closing-extra-terminal-head-ref'
grep -Fxq 'terminal_head_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$closing_extra_outputs" || fail 'review-selector-closing-extra-terminal-head-sha'
grep -Fxq 'terminal_reason=multiple-closing-references' "$closing_extra_outputs" || fail 'review-selector-closing-extra-terminal-reason'
grep -Fq 'selection=blocked reason=multiple-closing-references issue-10 pr=77' "$closing_extra_summary" || fail 'review-selector-closing-extra-summary'
! grep -Fq 'cloud exec' "${runs_dir}/review-selector-closing-extra.output" || fail 'review-selector-closing-extra-started-cloud'

# A valid closing reference from another repository is still a real node. It
# must count as an additional closing reference when the selected issue is
# present, and must reach the same trusted terminal quarantine without Cloud.
closing_cross_repo_outputs="${runs_dir}/review-selector-closing-cross-repo.outputs"
closing_cross_repo_summary="${runs_dir}/review-selector-closing-cross-repo.summary"
env PATH="$selector_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=nerdchanii/rpm \
  SELECTOR_CLOSING_MODE=cross-repo-extra SELECTOR_CORRECTION=agent:correction-1 \
  GITHUB_OUTPUT="$closing_cross_repo_outputs" GITHUB_STEP_SUMMARY="$closing_cross_repo_summary" \
  bash "$review_selector" >"${runs_dir}/review-selector-closing-cross-repo.output" 2>&1 || {
    sed 's/^/DEBUG /' "${runs_dir}/review-selector-closing-cross-repo.output" >&2
    fail 'review-selector-closing-cross-repo-failed'
  }
grep -Fxq 'selected=false' "$closing_cross_repo_outputs" || fail 'review-selector-closing-cross-repo-selected'
grep -Fxq 'terminal_reason=multiple-closing-references' "$closing_cross_repo_outputs" || fail 'review-selector-closing-cross-repo-terminal-reason'
grep -Fq 'selection=blocked reason=multiple-closing-references issue-10 pr=77' "$closing_cross_repo_summary" || fail 'review-selector-closing-cross-repo-summary'
! grep -Fq 'cloud exec' "${runs_dir}/review-selector-closing-cross-repo.output" || fail 'review-selector-closing-cross-repo-started-cloud'

# Invalid closing-reference pages are fail-closed reads. The selector must
# leave terminal outputs empty and avoid Cloud when pagination or node
# identity cannot be trusted.
for closing_mode in malformed graphql-errors cursor-stalled duplicate-id page-limit; do
  invalid_outputs="${runs_dir}/review-selector-closing-${closing_mode}.outputs"
  invalid_summary="${runs_dir}/review-selector-closing-${closing_mode}.summary"
  set +e
  env PATH="$selector_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=nerdchanii/rpm \
    SELECTOR_CLOSING_MODE="$closing_mode" SELECTOR_CORRECTION=agent:correction-1 \
    GITHUB_OUTPUT="$invalid_outputs" GITHUB_STEP_SUMMARY="$invalid_summary" \
    bash "$review_selector" >"${runs_dir}/review-selector-closing-${closing_mode}.output" 2>&1
  invalid_status=$?
  set -e
  [ "$invalid_status" -ne 0 ] || fail "review-selector-closing-${closing_mode}-succeeded"
  grep -Fxq 'selected=false' "$invalid_outputs" || fail "review-selector-closing-${closing_mode}-selected"
  case "$closing_mode" in
    malformed|graphql-errors) invalid_reason=response-invalid ;;
    cursor-stalled) invalid_reason=pagination-cursor-stalled ;;
    duplicate-id) invalid_reason=pagination-duplicate-id ;;
    page-limit) invalid_reason=pagination-limit ;;
  esac
  grep -Fq "selection=blocked reason=closing-reference-${invalid_reason} issue-10 pr=77" "$invalid_summary" || {
    sed 's/^/DEBUG /' "$invalid_summary" >&2
    fail "review-selector-closing-${closing_mode}-reason"
  }
  ! grep -Fq 'cloud exec' "${runs_dir}/review-selector-closing-${closing_mode}.output" || fail "review-selector-closing-${closing_mode}-started-cloud"
done

# A malformed response, broken cursor, duplicate comment id, or pagination
# limit is a fail-closed read. No candidate is selected and no Cloud step can
# be reached after any of these comment-inventory failures.
for comment_mode in response-invalid graphql-errors cursor-stalled duplicate-id page-limit; do
  invalid_outputs="${runs_dir}/review-selector-comments-${comment_mode}.outputs"
  invalid_summary="${runs_dir}/review-selector-comments-${comment_mode}.summary"
  set +e
  env PATH="$selector_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=nerdchanii/rpm \
    SELECTOR_COMMENT_MODE="$comment_mode" SELECTOR_CORRECTION=agent:correction-1 \
    GITHUB_OUTPUT="$invalid_outputs" GITHUB_STEP_SUMMARY="$invalid_summary" \
    bash "$review_selector" >"${runs_dir}/review-selector-comments-${comment_mode}.output" 2>&1
  invalid_status=$?
  set -e
  [ "$invalid_status" -ne 0 ] || fail "review-selector-comments-${comment_mode}-succeeded"
  grep -Fxq 'selected=false' "$invalid_outputs" || fail "review-selector-comments-${comment_mode}-selected"
  case "$comment_mode" in
    response-invalid|graphql-errors) invalid_reason=correction-history-response-invalid ;;
    cursor-stalled) invalid_reason=correction-history-pagination-cursor-stalled ;;
    duplicate-id) invalid_reason=correction-history-pagination-duplicate-id ;;
    page-limit) invalid_reason=correction-history-pagination-limit ;;
  esac
  grep -Fq "selection=blocked reason=${invalid_reason} issue-10 pr=77" "$invalid_summary" || fail "review-selector-comments-${comment_mode}-reason"
  ! grep -Fq 'cloud exec' "${runs_dir}/review-selector-comments-${comment_mode}.output" || fail "review-selector-comments-${comment_mode}-started-cloud"
done

multi_review_outputs="${runs_dir}/review-selector-multi.outputs"
multi_review_summary="${runs_dir}/review-selector-multi.summary"
env PATH="$selector_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=nerdchanii/rpm \
  SELECTOR_QUEUE_MODE=multi GITHUB_OUTPUT="$multi_review_outputs" GITHUB_STEP_SUMMARY="$multi_review_summary" \
  bash "$review_selector" >/dev/null || fail 'review-selector-multiple-active-failed'
grep -Fxq 'selected=false' "$multi_review_outputs" || fail 'review-selector-multiple-active-selected'
grep -Fq 'selection=no-work reason=active-work blockers=10,11' "$multi_review_summary" || fail 'review-selector-multiple-active-reason'

set +e
env PATH="$selector_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=nerdchanii/rpm \
  SELECTOR_FILE=.codex/hooks/agent_tool_policy.py \
  GITHUB_OUTPUT="${runs_dir}/review-selector-protected.outputs" \
  GITHUB_STEP_SUMMARY="${runs_dir}/review-selector-protected.summary" \
  bash "$review_selector" >"${runs_dir}/review-selector-protected.output" 2>&1
protected_selector_status=$?
set -e
[ "$protected_selector_status" -ne 0 ] || fail 'review-selector-protected-path-succeeded'
grep -Fq 'Protected review path' "${runs_dir}/review-selector-protected.output" || fail 'review-selector-protected-path-reason'

# A response exactly at the requested API limit may be truncated. Every
# selector that claims complete-queue knowledge must stop before selecting or
# starting Cloud when that boundary is reached.
issue_selector="$(find "$runs_dir" -type f -name '*-select-issue-*.sh' -print -quit)"
[ -n "$issue_selector" ] || fail 'issue-selector-script-missing'
for selector_case in \
  "issue:${issue_selector}:issue" \
  "review:${review_selector}:review"; do
  IFS=: read -r selector_name selector_script selector_kind <<<"$selector_case"
  truncation_outputs="${runs_dir}/${selector_name}-selector-truncated.outputs"
  truncation_summary="${runs_dir}/${selector_name}-selector-truncated.summary"
  set +e
  env PATH="$selector_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=nerdchanii/rpm \
    SELECTOR_QUEUE_MODE=truncated GITHUB_OUTPUT="$truncation_outputs" \
    GITHUB_STEP_SUMMARY="$truncation_summary" bash "$selector_script" >/dev/null 2>&1
  truncation_status=$?
  set -e
  [ "$truncation_status" -ne 0 ] || fail "${selector_name}-selector-truncation-succeeded"
  grep -Fxq 'selected=false' "$truncation_outputs" || fail "${selector_name}-selector-truncation-selected"
  grep -Fq 'selection=blocked reason=issue-inventory-may-be-truncated' "$truncation_summary" || fail "${selector_name}-selector-truncation-reason"
done

review_truncated_outputs="${runs_dir}/review-selector-filtered-truncated.outputs"
review_truncated_summary="${runs_dir}/review-selector-filtered-truncated.summary"
set +e
env PATH="$selector_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=nerdchanii/rpm \
  SELECTOR_QUEUE_MODE=review-truncated GITHUB_OUTPUT="$review_truncated_outputs" \
  GITHUB_STEP_SUMMARY="$review_truncated_summary" bash "$review_selector" >/dev/null 2>&1
review_truncated_status=$?
set -e
[ "$review_truncated_status" -ne 0 ] || fail 'review-selector-filtered-truncation-succeeded'
grep -Fxq 'selected=false' "$review_truncated_outputs" || fail 'review-selector-filtered-truncation-selected'
grep -Fq 'selection=blocked reason=issue-inventory-may-be-truncated' "$review_truncated_summary" || fail 'review-selector-filtered-truncation-reason'

# Exhausted correction state is terminal for the automatic review selector.
# The fake issue response supplies all six trusted history records, so this
# covers the valid correction-5 terminal path.
exhausted_outputs="${runs_dir}/review-selector-exhausted.outputs"
exhausted_summary="${runs_dir}/review-selector-exhausted.summary"
set +e
env PATH="$selector_bin:$PATH" GH_TOKEN=test-token GITHUB_REPOSITORY=nerdchanii/rpm \
  SELECTOR_CORRECTION=agent:correction-5 GITHUB_OUTPUT="$exhausted_outputs" \
  GITHUB_STEP_SUMMARY="$exhausted_summary" bash "$review_selector" >"${runs_dir}/review-selector-exhausted.output" 2>&1
exhausted_status=$?
set -e
[ "$exhausted_status" -eq 0 ] || fail 'review-selector-exhausted-failed'
grep -Fxq 'selected=false' "$exhausted_outputs" || fail 'review-selector-exhausted-selected'
grep -Fxq 'correction_limit_exhausted=true' "$exhausted_outputs" || fail 'review-selector-exhausted-terminal-output'
grep -Fxq 'terminal_issue=10' "$exhausted_outputs" || fail 'review-selector-exhausted-terminal-issue'
grep -Fxq 'terminal_pr=77' "$exhausted_outputs" || fail 'review-selector-exhausted-terminal-pr'
grep -Fxq 'terminal_base_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$exhausted_outputs" || fail 'review-selector-exhausted-terminal-base'
grep -Fxq 'terminal_head_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$exhausted_outputs" || fail 'review-selector-exhausted-terminal-head'
grep -Fxq 'terminal_reason=correction-limit' "$exhausted_outputs" || fail 'review-selector-exhausted-terminal-reason'
grep -Fq 'Correction limit exhausted' "${runs_dir}/review-selector-exhausted.output" || fail 'review-selector-exhausted-reason'
grep -Fq 'selection=blocked reason=correction-limit issue-10 pr=77' "$exhausted_summary" || fail 'review-selector-exhausted-summary'
! grep -Fq 'cloud exec' "${runs_dir}/review-selector-exhausted.output" || fail 'review-selector-exhausted-started-cloud'

# A label can advance before its durable history comment is written. Every
# such partial transaction is terminal and must reach the trusted writer
# without starting Cloud.
partial_outputs="${runs_dir}/review-selector-partial.outputs"
partial_summary="${runs_dir}/review-selector-partial.summary"
set +e
env PATH="$selector_bin:$PATH" GITHUB_REPOSITORY=nerdchanii/rpm \
  SELECTOR_CORRECTION=agent:correction-1 SELECTOR_HISTORY_MODE=partial \
  GITHUB_OUTPUT="$partial_outputs" GITHUB_STEP_SUMMARY="$partial_summary" \
  bash "$review_selector" >"${runs_dir}/review-selector-partial.output" 2>&1
partial_status=$?
set -e
[ "$partial_status" -eq 0 ] || fail 'review-selector-partial-failed'
grep -Fxq 'selected=false' "$partial_outputs" || fail 'review-selector-partial-selected'
grep -Fxq 'correction_limit_exhausted=true' "$partial_outputs" || fail 'review-selector-partial-terminal-output'
grep -Fxq 'terminal_reason=correction-history-sequence-missing' "$partial_outputs" || fail 'review-selector-partial-terminal-reason'
grep -Fxq 'terminal_issue=10' "$partial_outputs" || fail 'review-selector-partial-terminal-issue'
grep -Fxq 'terminal_pr=77' "$partial_outputs" || fail 'review-selector-partial-terminal-pr'
grep -Fq 'selection=blocked reason=correction-history-sequence-missing issue-10 pr=77' "$partial_summary" || fail 'review-selector-partial-summary'
! grep -Fq 'cloud exec' "${runs_dir}/review-selector-partial.output" || fail 'review-selector-partial-started-cloud'

# A correction-5 label without trusted history is treated as forged/partial
# state. It is sent to quarantine with the exact inconsistency reason.
for invalid_history_mode in missing untrusted; do
  invalid_outputs="${runs_dir}/review-selector-${invalid_history_mode}.outputs"
  invalid_summary="${runs_dir}/review-selector-${invalid_history_mode}.summary"
  set +e
  env PATH="$selector_bin:$PATH" GITHUB_REPOSITORY=nerdchanii/rpm \
    SELECTOR_CORRECTION=agent:correction-5 SELECTOR_HISTORY_MODE="$invalid_history_mode" \
    GITHUB_OUTPUT="$invalid_outputs" GITHUB_STEP_SUMMARY="$invalid_summary" \
    bash "$review_selector" >"${runs_dir}/review-selector-${invalid_history_mode}.output" 2>&1
  invalid_status=$?
  set -e
  [ "$invalid_status" -eq 0 ] || fail "review-selector-${invalid_history_mode}-failed"
  grep -Fxq 'selected=false' "$invalid_outputs" || fail "review-selector-${invalid_history_mode}-selected"
  if [ "$invalid_history_mode" = missing ]; then
    invalid_reason=correction-history-sequence-missing
  else
    invalid_reason=correction-history-sequence-missing
  fi
  grep -Fxq "terminal_reason=${invalid_reason}" "$invalid_outputs" || fail "review-selector-${invalid_history_mode}-terminal-reason"
  grep -Fq "selection=blocked reason=${invalid_reason} issue-10 pr=77" "$invalid_summary" || fail "review-selector-${invalid_history_mode}-summary"
  ! grep -Fq 'cloud exec' "${runs_dir}/review-selector-${invalid_history_mode}.output" || fail "review-selector-${invalid_history_mode}-started-cloud"
done

# Merge selection quarantines deterministic candidate anomalies so a malformed
# lowest-numbered issue cannot keep failing the 15-minute scheduler forever.
merge_selector_gh="${selector_bin}/gh-merge"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'request="$*"' \
  'mode="${MERGE_SELECTOR_MODE:-no-closing-pr}"' \
  'if [ "$mode" = cross-repo-extra ] && [[ "$request" == "pr view 44 --repo nerdchanii/rpm --json closingIssuesReferences" ]]; then' \
  '  jq -nc '\''{closingIssuesReferences:[{number:12,repository:{name:"rpm",owner:{login:"nerdchanii"}}},{number:13,repository:{name:"rpm",owner:{login:"other"}}}]}'\''' \
  '  exit 0' \
  'fi' \
  'case "$request" in' \
  '  *"--json number,labels"*)' \
  '    case "${MERGE_QUEUE_MODE:-single}" in' \
  '      truncated)' \
  '        jq -nc '\''[range(1;1001) | {number:.,labels:[{name:"agent:awaiting-merge"}]}]'\''' \
  '        ;;' \
  '      multi)' \
  '        printf "%s\\n" '\''[{"number":12,"labels":[{"name":"agent:awaiting-merge"}]},{"number":13,"labels":[{"name":"agent:review-pending"}]}]'\''' \
  '        ;;' \
  '      *)' \
  '        printf "%s\\n" '\''[{"number":12,"labels":[{"name":"agent:awaiting-merge"}]}]'\''' \
  '        ;;' \
  '    esac' \
  '    ;;' \
  '  "issue list"*)' \
  '    if [ "${MERGE_QUEUE_MODE:-single}" = multi ]; then' \
  '      printf "%s\\n" "merge candidate query should be skipped when multiple issues are active" >&2' \
  '      exit 93' \
  '    fi' \
  '    if [ "${MERGE_QUEUE_MODE:-single}" = merge-truncated ]; then' \
  '      jq -nc '\''[range(1;1001) | {number:.}]'\''' \
  '    else' \
  '      printf "%s\\n" '\''[{"number":12},{"number":20}]'\''' \
  '    fi' \
  '    ;;' \
  '  "repo view"*)' \
  '    printf "%s\\n" main' \
  '    ;;' \
  '  *"/git/ref/heads/main"*)' \
  '    printf "%s\\n" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '    ;;' \
  '  *"/issues/20/timeline"*)' \
  '    printf "%s\\n" "second candidate must not be queried" >&2' \
  '    exit 91' \
  '    ;;' \
  '  *"/issues/12/timeline"*)' \
  '    case "$mode" in malformed) printf "%s\\n" "{}" ;; no-closing-pr) printf "%s\\n" '\''[[]]'\'' ;; multiple-prs) printf "%s\\n" '\''[[{"event":"cross-referenced","source":{"issue":{"number":44,"pull_request":{"url":"x"}}}},{"event":"cross-referenced","source":{"issue":{"number":45,"pull_request":{"url":"x"}}}}]]'\'' ;; same-repo-plus-fork) printf "%s\\n" '\''[[{"event":"cross-referenced","source":{"issue":{"number":44,"pull_request":{"url":"x"}}}},{"event":"cross-referenced","source":{"issue":{"number":45,"pull_request":{"url":"x"}}}}]]'\'' ;; *) printf "%s\\n" '\''[[{"event":"cross-referenced","source":{"issue":{"number":44,"pull_request":{"url":"x"}}}}]]'\'' ;; esac' \
  '    ;;' \
  '  *"/pulls/44"*|*"/pulls/45"*)' \
  '    case "$mode" in fork-pr) printf "%s\\n" '\''{"state":"open","base":{"ref":"main","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"feat/fork-noise","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"other/rpm"}}}'\'' ;; same-repo-plus-fork) if [[ "$request" == *"/pulls/44"* ]]; then printf "%s\\n" '\''{"state":"open","base":{"ref":"main","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"feat/fork-noise","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"other/rpm"}}}'\''; else printf "%s\\n" '\''{"state":"open","base":{"ref":"main","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"feat/trusted","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"nerdchanii/rpm"}}}'\''; fi ;; unsafe-base) printf "%s\\n" '\''{"state":"open","base":{"ref":"release","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"feat/safe","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"nerdchanii/rpm"}}}'\'' ;; unsafe-head) printf "%s\\n" '\''{"state":"open","base":{"ref":"main","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"main","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"nerdchanii/rpm"}}}'\'' ;; stale-base) printf "%s\\n" '\''{"state":"open","base":{"ref":"main","sha":"cccccccccccccccccccccccccccccccccccccccc","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"feat/safe","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"nerdchanii/rpm"}}}'\'' ;; *) printf "%s\\n" '\''{"state":"open","base":{"ref":"main","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"feat/safe","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"nerdchanii/rpm"}}}'\'' ;; esac' \
  '    ;;' \
  "  \"pr view 44 --repo nerdchanii/rpm --json closingIssuesReferences\")" \
  '    if [ "$mode" = extra-closing ]; then printf "%s\\n" '\''{"closingIssuesReferences":[{"number":12,"repository":{"name":"rpm","owner":{"login":"nerdchanii"}}},{"number":13,"repository":{"name":"rpm","owner":{"login":"nerdchanii"}}}]}'\''; else printf "%s\\n" '\''{"closingIssuesReferences":[{"number":12,"repository":{"name":"rpm","owner":{"login":"nerdchanii"}}}]}'\''; fi' \
  '    ;;' \
  "  \"pr view 45 --repo nerdchanii/rpm --json closingIssuesReferences\")" \
  '    printf "%s\\n" '\''{"closingIssuesReferences":[{"number":12,"repository":{"name":"rpm","owner":{"login":"nerdchanii"}}}]}'\''' \
  '    ;;' \
  '  *)' \
  '    printf "unexpected merge selector gh call: %s\\n" "$request" >&2' \
  '    exit 92' \
  '    ;;' \
  'esac' >"$merge_selector_gh"
chmod +x "$merge_selector_gh"
merge_selector="$(find "$runs_dir" -type f -name '*-select-merge-*.sh' -print -quit)"
[ -n "$merge_selector" ] || fail 'merge-selector-script-missing'
cp "$merge_selector_gh" "${selector_bin}/gh"

merge_truncation_outputs="${runs_dir}/merge-selector-truncated.outputs"
merge_truncation_summary="${runs_dir}/merge-selector-truncated.summary"
set +e
env PATH="${selector_bin}:$PATH" GH_TOKEN=test-token MERGE_QUEUE_MODE=truncated \
  GITHUB_REPOSITORY=nerdchanii/rpm GITHUB_OUTPUT="$merge_truncation_outputs" \
  GITHUB_STEP_SUMMARY="$merge_truncation_summary" bash "$merge_selector" >/dev/null 2>&1
merge_truncation_status=$?
set -e
[ "$merge_truncation_status" -ne 0 ] || fail 'merge-selector-truncation-succeeded'
grep -Fxq 'selected=false' "$merge_truncation_outputs" || fail 'merge-selector-truncation-selected'
grep -Fq 'selection=blocked reason=issue-inventory-may-be-truncated' "$merge_truncation_summary" || fail 'merge-selector-truncation-reason'

merge_filtered_truncation_outputs="${runs_dir}/merge-selector-filtered-truncated.outputs"
merge_filtered_truncation_summary="${runs_dir}/merge-selector-filtered-truncated.summary"
set +e
env PATH="${selector_bin}:$PATH" GH_TOKEN=test-token MERGE_QUEUE_MODE=merge-truncated \
  GITHUB_REPOSITORY=nerdchanii/rpm GITHUB_OUTPUT="$merge_filtered_truncation_outputs" \
  GITHUB_STEP_SUMMARY="$merge_filtered_truncation_summary" bash "$merge_selector" >/dev/null 2>&1
merge_filtered_truncation_status=$?
set -e
[ "$merge_filtered_truncation_status" -ne 0 ] || fail 'merge-selector-filtered-truncation-succeeded'
grep -Fxq 'selected=false' "$merge_filtered_truncation_outputs" || fail 'merge-selector-filtered-truncation-selected'
grep -Fq 'selection=blocked reason=issue-inventory-may-be-truncated' "$merge_filtered_truncation_summary" || fail 'merge-selector-filtered-truncation-reason'

run_merge_selector_anomaly() {
  local mode="$1" expected_reason="$2"
  local output_file="${runs_dir}/merge-selector-${mode}.outputs"
  local summary_file="${runs_dir}/merge-selector-${mode}.summary"
  env PATH="${selector_bin}:$PATH" GH_TOKEN=test-token MERGE_SELECTOR_MODE="$mode" \
    GITHUB_REPOSITORY=nerdchanii/rpm GITHUB_OUTPUT="$output_file" GITHUB_STEP_SUMMARY="$summary_file" \
    bash "$merge_selector" >/dev/null || fail "merge-selector-${mode}-failed"
  grep -Fxq 'selected=false' "$output_file" || fail "merge-selector-${mode}-selected"
  grep -Fxq 'anomaly=true' "$output_file" || fail "merge-selector-${mode}-anomaly"
  grep -Fxq "anomaly_issue=12" "$output_file" || fail "merge-selector-${mode}-issue"
  grep -Fxq "anomaly_reason=${expected_reason}" "$output_file" || fail "merge-selector-${mode}-reason"
  grep -Fxq 'base_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$output_file" || fail "merge-selector-${mode}-base"
  ! grep -Fq 'issue=20' "$output_file" || fail "merge-selector-${mode}-second-issue"
}

# The fake is selected through PATH as `gh`; keep the mode-specific assertions
# above independent from the review selector fixture.
cp "$merge_selector_gh" "${selector_bin}/gh"

# A linked PR whose head comes from a fork is merge noise. It must be ignored
# before closing-reference validation, produce bounded no-work output, and
# avoid the anomaly path that would quarantine the awaiting-merge issue.
fork_only_outputs="${runs_dir}/merge-selector-fork-only.outputs"
fork_only_summary="${runs_dir}/merge-selector-fork-only.summary"
env PATH="${selector_bin}:$PATH" GH_TOKEN=test-token MERGE_SELECTOR_MODE=fork-pr \
  GITHUB_REPOSITORY=nerdchanii/rpm GITHUB_OUTPUT="$fork_only_outputs" GITHUB_STEP_SUMMARY="$fork_only_summary" \
  bash "$merge_selector" >/dev/null || fail 'merge-selector-fork-only-failed'
grep -Fxq 'selected=false' "$fork_only_outputs" || fail 'merge-selector-fork-only-selected'
grep -Fxq 'anomaly=false' "$fork_only_outputs" || fail 'merge-selector-fork-only-anomaly'
! grep -Fq 'anomaly_issue=12' "$fork_only_outputs" || fail 'merge-selector-fork-only-quarantined'
grep -Fq 'selection=no-work reason=fork-pr-ignored issue-12 count=1' "$fork_only_summary" || fail 'merge-selector-fork-only-reason'

# Fork noise must not hide a valid same-repository candidate. The selector
# should ignore PR #44 and evaluate the trusted PR #45 completely.
trusted_with_fork_outputs="${runs_dir}/merge-selector-same-repo-plus-fork.outputs"
trusted_with_fork_summary="${runs_dir}/merge-selector-same-repo-plus-fork.summary"
env PATH="${selector_bin}:$PATH" GH_TOKEN=test-token MERGE_SELECTOR_MODE=same-repo-plus-fork \
  GITHUB_REPOSITORY=nerdchanii/rpm GITHUB_OUTPUT="$trusted_with_fork_outputs" GITHUB_STEP_SUMMARY="$trusted_with_fork_summary" \
  bash "$merge_selector" >/dev/null || fail 'merge-selector-same-repo-plus-fork-failed'
grep -Fxq 'selected=true' "$trusted_with_fork_outputs" || fail 'merge-selector-same-repo-plus-fork-not-selected'
grep -Fxq 'issue=12' "$trusted_with_fork_outputs" || fail 'merge-selector-same-repo-plus-fork-issue'
grep -Fxq 'pr=45' "$trusted_with_fork_outputs" || fail 'merge-selector-same-repo-plus-fork-pr'
grep -Fxq 'anomaly=false' "$trusted_with_fork_outputs" || fail 'merge-selector-same-repo-plus-fork-anomaly'
grep -Fq 'selection=issue-12 pr=45' "$trusted_with_fork_summary" || fail 'merge-selector-same-repo-plus-fork-summary'

for selector_case in \
  'no-closing-pr no-closing-pr' \
  'extra-closing multiple-closing-references' \
  'cross-repo-extra multiple-closing-references' \
  'multiple-prs multiple-prs' \
  'unsafe-base unsafe-base' \
  'unsafe-head unsafe-head' \
  'stale-base stale-base'; do
  read -r mode reason <<<"$selector_case"
  run_merge_selector_anomaly "$mode" "$reason"
done

multi_merge_outputs="${runs_dir}/merge-selector-multi.outputs"
multi_merge_summary="${runs_dir}/merge-selector-multi.summary"
env PATH="${selector_bin}:$PATH" GH_TOKEN=test-token MERGE_QUEUE_MODE=multi \
  GITHUB_REPOSITORY=nerdchanii/rpm GITHUB_OUTPUT="$multi_merge_outputs" GITHUB_STEP_SUMMARY="$multi_merge_summary" \
  bash "$merge_selector" >/dev/null || fail 'merge-selector-multiple-active-failed'
grep -Fxq 'selected=false' "$multi_merge_outputs" || fail 'merge-selector-multiple-active-selected'
grep -Fxq 'anomaly=false' "$multi_merge_outputs" || fail 'merge-selector-multiple-active-anomaly'
grep -Fq 'selection=no-work reason=active-work blockers=12,13' "$multi_merge_summary" || fail 'merge-selector-multiple-active-reason'

malformed_outputs="${runs_dir}/merge-selector-malformed.outputs"
set +e
env PATH="${selector_bin}:$PATH" GH_TOKEN=test-token MERGE_SELECTOR_MODE=malformed \
  GITHUB_REPOSITORY=nerdchanii/rpm GITHUB_OUTPUT="$malformed_outputs" \
  GITHUB_STEP_SUMMARY="${runs_dir}/merge-selector-malformed.summary" \
  bash "$merge_selector" >/dev/null 2>&1
malformed_status=$?
set -e
[ "$malformed_status" -ne 0 ] || fail 'merge-selector-malformed-succeeded'
! grep -q 'anomaly=true' "$malformed_outputs" 2>/dev/null || fail 'merge-selector-malformed-quarantined'

printf 'codex_cloud_dispatch_test.PASS=cloud-diff-publisher-boundary\n'
