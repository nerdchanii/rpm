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

ruby -ryaml -rjson -e '
  document = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  jobs = document.fetch("jobs")
  expected = %w[select-issue issue-cloud issue-publish issue-recover select-review review-cloud review-publish select-merge merge-selector-quarantine merge-cloud merge-publish]
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
  recovery = jobs.fetch("issue-recover")
  raise "recovery-permissions" unless recovery.fetch("permissions") == {"contents" => "read", "issues" => "write"}
  raise "recovery-cloud-secret" if recovery.to_json.include?("CODEX_ACCESS_TOKEN")
  raise "recovery-always" unless recovery.fetch("if").to_s.include?("always()")
  raise "recovery-claim-check" unless recovery.to_json.include?("agent:claimed") && recovery.to_json.include?("agent:blocked")
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
  raise "review-outputs" unless %w[selected issue pr base_ref base_sha head_ref head_sha].all? { |key| jobs.fetch("select-review").fetch("outputs").key?(key) }
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
assert_contains 'anomaly_reason'
assert_contains 'no-closing-pr'
assert_contains 'fork-pr'
assert_contains 'multiple-prs'
assert_contains 'unsafe-base'
assert_contains 'unsafe-head'
assert_contains 'stale-base'
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

runs_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-codex-cloud-runs.XXXXXX")"
trap 'rm -rf "$runs_dir"' EXIT
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
case "$request" in
  *"--json number,labels"*)
    if [ "${SELECTOR_QUEUE_MODE:-single}" = multi ]; then
      printf '%s\n' '[{"number":10,"labels":[{"name":"agent:review-pending"}]},{"number":11,"labels":[{"name":"agent:claimed"}]}]'
    else
      printf '%s\n' '[{"number":10,"labels":[{"name":"agent:review-pending"}]}]'
    fi
    ;;
  "issue list"*)
    if [ "${SELECTOR_QUEUE_MODE:-single}" = multi ]; then
      printf '%s\n' 'review candidate query should be skipped when multiple issues are active' >&2
      exit 93
    fi
    printf '%s\n' '[{"number":10},{"number":20}]'
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
    printf '%s\n' '{"closingIssuesReferences":[{"number":10}]}'
    ;;
  *"/pulls/77/files?per_page=100"*)
    jq -nc --arg path "${SELECTOR_FILE:-src/lib.rs}" '[[{filename:$path}]]'
    ;;
  *"/pulls/77"*)
    printf '%s\n' '{"state":"open","changed_files":1,"base":{"ref":"main","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"feat/first","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"nerdchanii/rpm"}}}'
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

# Merge selection quarantines deterministic candidate anomalies so a malformed
# lowest-numbered issue cannot keep failing the 15-minute scheduler forever.
merge_selector_gh="${selector_bin}/gh-merge"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'request="$*"' \
  'mode="${MERGE_SELECTOR_MODE:-no-closing-pr}"' \
  'case "$request" in' \
  '  *"--json number,labels"*)' \
  '    if [ "${MERGE_QUEUE_MODE:-single}" = multi ]; then' \
  '      printf "%s\\n" '\''[{"number":12,"labels":[{"name":"agent:awaiting-merge"}]},{"number":13,"labels":[{"name":"agent:review-pending"}]}]'\''' \
  '    else' \
  '      printf "%s\\n" '\''[{"number":12,"labels":[{"name":"agent:awaiting-merge"}]}]'\''' \
  '    fi' \
  '    ;;' \
  '  "issue list"*)' \
  '    if [ "${MERGE_QUEUE_MODE:-single}" = multi ]; then' \
  '      printf "%s\\n" "merge candidate query should be skipped when multiple issues are active" >&2' \
  '      exit 93' \
  '    fi' \
  '    printf "%s\\n" '\''[{"number":12},{"number":20}]'\''' \
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
  '    case "$mode" in malformed) printf "%s\\n" "{}" ;; no-closing-pr) printf "%s\\n" '\''[[]]'\'' ;; multiple-prs) printf "%s\\n" '\''[[{"event":"cross-referenced","source":{"issue":{"number":44,"pull_request":{"url":"x"}}}},{"event":"cross-referenced","source":{"issue":{"number":45,"pull_request":{"url":"x"}}}}]]'\'' ;; *) printf "%s\\n" '\''[[{"event":"cross-referenced","source":{"issue":{"number":44,"pull_request":{"url":"x"}}}}]]'\'' ;; esac' \
  '    ;;' \
  '  *"/pulls/44"*|*"/pulls/45"*)' \
  '    case "$mode" in fork-pr) printf "%s\\n" '\''{"state":"open","base":{"ref":"main","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"other/repo"}},"head":{"ref":"feat/safe","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"other/repo"}}}'\'' ;; unsafe-base) printf "%s\\n" '\''{"state":"open","base":{"ref":"release","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"feat/safe","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"nerdchanii/rpm"}}}'\'' ;; unsafe-head) printf "%s\\n" '\''{"state":"open","base":{"ref":"main","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"main","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"nerdchanii/rpm"}}}'\'' ;; stale-base) printf "%s\\n" '\''{"state":"open","base":{"ref":"main","sha":"cccccccccccccccccccccccccccccccccccccccc","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"feat/safe","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"nerdchanii/rpm"}}}'\'' ;; *) printf "%s\\n" '\''{"state":"open","base":{"ref":"main","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"feat/safe","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"nerdchanii/rpm"}}}'\'' ;; esac' \
  '    ;;' \
  "  \"pr view 44 --repo nerdchanii/rpm --json closingIssuesReferences\")" \
  '    printf "%s\\n" '\''{"closingIssuesReferences":[{"number":12}]}'\''' \
  '    ;;' \
  "  \"pr view 45 --repo nerdchanii/rpm --json closingIssuesReferences\")" \
  '    printf "%s\\n" '\''{"closingIssuesReferences":[{"number":12}]}'\''' \
  '    ;;' \
  '  *)' \
  '    printf "unexpected merge selector gh call: %s\\n" "$request" >&2' \
  '    exit 92' \
  '    ;;' \
  'esac' >"$merge_selector_gh"
chmod +x "$merge_selector_gh"
merge_selector="$(find "$runs_dir" -type f -name '*-select-merge-*.sh' -print -quit)"
[ -n "$merge_selector" ] || fail 'merge-selector-script-missing'

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
for selector_case in \
  'no-closing-pr no-closing-pr' \
  'fork-pr fork-pr' \
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
