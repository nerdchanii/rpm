#!/usr/bin/env bash
set -euo pipefail

# Independent, non-mutating checks for the read-only Codex artifact lane.
# The workflow is inspected as a data contract and path/size helpers are
# exercised only inside temporary Git repositories.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

fail() {
  printf 'agent_loop_artifact_test.FAIL=%s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'agent_loop_artifact_test.PASS=%s\n' "$1"
}

require_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

require_text() {
  local path="$1" needle="$2" description
  description="${3:-${needle}}"
  rg -q --fixed-strings -- "${needle}" "${path}" || fail "${description} (${path})"
}

require_regex() {
  local path="$1" pattern="$2" description
  description="${3:-${pattern}}"
  rg -q --pcre2 -- "${pattern}" "${path}" || fail "${description} (${path})"
}

require_no_regex() {
  local path="$1" pattern="$2" description
  description="${3:-${pattern}}"
  if rg -q --pcre2 -- "${pattern}" "${path}"; then
    fail "${description} (${path})"
  fi
}

require_any_text() {
  local path="$1" description="$2" needle
  shift 2
  for needle in "$@"; do
    if rg -q --fixed-strings -- "${needle}" "${path}"; then
      return 0
    fi
  done
  fail "${description} (${path})"
}

# Discover the artifact workflow by its pinned Codex and upload Actions. This
# supports a later safe filename change without selecting an unrelated workflow.
workflow="${ARTIFACT_WORKFLOW:-}"
if [ -z "${workflow}" ]; then
  workflow="$(find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 \
    | xargs -0 rg -l -m 1 'openai/codex-action@.*86365089eb2b84e0a8fb0717b304f8bdcb13b20e|actions/upload-artifact@.*ea165f8d65b6e75b540449e92b4886f43607fa02' \
    | head -n 1 || true)"
fi
require_file "${workflow}"

# Parse the YAML structure. Psych 4 treats YAML 1.1's on key as true, so
# accept both representations explicitly.
ruby -ryaml - "${workflow}" <<'RUBY'
path = ARGV.fetch(0)
document = YAML.safe_load(File.read(path), aliases: true)
raise "workflow root must be a mapping" unless document.is_a?(Hash)

events = document["on"] || document[true] || document["true"]
raise "workflow must define an event map" unless events.is_a?(Hash)
event_names = events.keys.map(&:to_s)
raise "artifact lane must be workflow_dispatch-only: #{event_names.inspect}" unless event_names == ["workflow_dispatch"]

dispatch = events["workflow_dispatch"]
inputs = dispatch.is_a?(Hash) ? (dispatch["inputs"] || {}) : {}
raise "workflow_dispatch.inputs must be a mapping" unless inputs.is_a?(Hash)
names = inputs.keys.map(&:to_s)
lane_name = names.find { |name| name == "lane" }
number_name = names.find { |name| ["number", "issue_number", "pr_number"].include?(name) }
if lane_name && number_name
  lane_value = inputs.fetch(lane_name) { inputs.fetch(lane_name.to_sym) }
  options = lane_value.is_a?(Hash) ? (lane_value["options"] || []) : []
  raise "lane input must offer issue and review" unless options.map(&:to_s).sort == ["issue", "review"]
  selected_names = [lane_name, number_name]
else
  issue_name = names.find { |name| ["issue", "issue_number"].include?(name) }
  review_name = names.find { |name| ["review", "review_number", "pr", "pr_number"].include?(name) }
  raise "issue input is missing" unless issue_name
  raise "review input is missing" unless review_name
  selected_names = [issue_name, review_name]
end

[selected_names].flatten.each do |name|
  value = inputs.fetch(name) { inputs.fetch(name.to_sym) }
  raise "#{name} input must be required" unless value.is_a?(Hash) && value["required"] == true
end

permissions = document["permissions"]
raise "workflow permissions must be an explicit mapping" unless permissions.is_a?(Hash)
%w[contents issues pull-requests].each do |name|
  raise "#{name}: read permission is missing" unless permissions[name] == "read"
end
permissions.each do |name, value|
  if value.to_s == "write" || value.to_s.end_with?("-all")
    raise "write permission is present: #{name}: #{value}"
  end
end

jobs = document["jobs"]
raise "workflow jobs must be a mapping" unless jobs.is_a?(Hash) && !jobs.empty?
jobs.each do |job_name, job|
  next unless job.is_a?(Hash)
  raise "job #{job_name} must use the codex-artifact environment" unless job["environment"] == "codex-artifact"
  job_if = job["if"].to_s
  unless job_if.include?("github.ref") && job_if.include?("default_branch")
    raise "job #{job_name} must be restricted to the default branch"
  end
  local_permissions = job["permissions"]
  next unless local_permissions.is_a?(Hash)
  local_permissions.each do |name, value|
    if value.to_s == "write" || value.to_s.end_with?("-all")
      raise "job #{job_name} grants write permission: #{name}: #{value}"
    end
  end
end

steps = jobs.values.flat_map { |job| job.is_a?(Hash) && job["steps"].is_a?(Array) ? job["steps"] : [] }
codex_steps = steps.select { |step| step.is_a?(Hash) && step["uses"].to_s.start_with?("openai/codex-action@") }
raise "exactly one Codex action is required" unless codex_steps.length == 1
codex = codex_steps.first
raise "Codex action is not pinned" unless codex["uses"] == "openai/codex-action@86365089eb2b84e0a8fb0717b304f8bdcb13b20e"
codex_with = codex["with"]
raise "Codex action inputs must be a mapping" unless codex_with.is_a?(Hash)
output_file = codex_with["output-file"].to_s
unless output_file.include?("runner.temp") && output_file.end_with?("/rpm-codex-output/final-message.json")
  raise "Codex output file must use the isolated runner-temp path"
end

%w[issue_context review_context].each do |step_id|
  step = steps.find { |candidate| candidate.is_a?(Hash) && candidate["id"] == step_id }
  raise "#{step_id} step is missing" unless step
  run = step["run"].to_s
  install_at = run.index("install -m 0600")
  append_at = run.index('>>"$prompt"')
  lock_at = run.index('chmod 0444 "$prompt"')
  unless install_at && append_at && lock_at && install_at < append_at && append_at < lock_at
    raise "#{step_id} must create a writable prompt and lock it after appending"
  end
end

# A missing key must skip the action. Either the action itself has a secret
# guard, or it is guarded by an auth job output named ready.
codex_if = codex["if"].to_s
source = File.read(path)
auth_guard = source.match?(/OPENAI_API_KEY/) &&
             source.match?(/-n\s+.*OPENAI_API_KEY|OPENAI_API_KEY.*!=\s*['"]['"]?/) &&
             source.match?(/ready.*true|blocked-auth|no Codex call/i)
direct_guard = codex_if.match?(/OPENAI_API_KEY|needs\.[^.]+\.outputs\.ready/) &&
               codex_if.match?(/true|!=|==/)
direct_guard ||= codex_if.match?(/steps\.[^.]+\.outputs\.(available|ready)/) &&
                 codex_if.match?(/true|!=|==/)
raise "Codex action is not skipped without OPENAI_API_KEY" unless auth_guard || direct_guard

upload_steps = steps.select { |step| step.is_a?(Hash) && step["uses"].to_s.start_with?("actions/upload-artifact@") }
raise "at least one artifact upload is required" if upload_steps.empty?
upload_steps.each do |step|
  raise "upload-artifact is not pinned" unless step["uses"] == "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
  with = step["with"]
  raise "artifact upload path is missing" unless with.is_a?(Hash) && with["path"]
  raise "artifact upload must fail when files are absent" unless with["if-no-files-found"] == "error"
  upload_path = with["path"].to_s
  unless upload_path.include?("runner.temp") || upload_path.include?("RUNNER_TEMP") || upload_path.include?("artifact_dir")
    raise "artifact path must be under the runner temp directory"
  end
end
RUBY

# Keep the human-readable pins explicit, so a floating reference cannot hide
# behind a different YAML representation.
require_text "${workflow}" "openai/codex-action@86365089eb2b84e0a8fb0717b304f8bdcb13b20e"
require_text "${workflow}" "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
require_text "${workflow}" "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
if rg -q --pcre2 'uses:[[:space:]]+[^[:space:]#]+@(v[0-9]+|main|master)([[:space:]#]|$)' "${workflow}"; then
  fail "artifact workflow contains a floating Action reference"
fi
require_text "${workflow}" "model: gpt-5.6-sol"
require_any_text "${workflow}" "Codex effort must be xhigh" \
  "effort: xhigh" "reasoning-effort: xhigh" "reasoning_effort: xhigh"
require_text "${workflow}" "codex-version: 0.152.0"
require_text "${workflow}" 'permission-profile: ":workspace"'
require_text "${workflow}" "safety-strategy: unprivileged-user"
require_text "${workflow}" "codex-user: rpm-codex"
require_no_regex "${workflow}" 'sandbox:[[:space:]]*(workspace-write|danger-full-access)' \
  "legacy or unrestricted sandbox must not replace the permission profile"
require_text "${workflow}" 'output-schema-file: ${{ steps.trusted_assets.outputs.trusted_root }}/result-schema.json'
require_text "${workflow}" 'output-file: ${{ runner.temp }}/rpm-codex-output/final-message.json'
require_no_regex "${workflow}" 'CODEX_FINAL_MESSAGE:' \
  "Codex final output must not cross the Linux per-variable environment limit"
require_text "${workflow}" "MAX_RESULT_BYTES: 262144"
require_text "${workflow}" "MAX_PATCH_BYTES: 10485760"
require_text "${workflow}" 'wc -c <"$raw"'
require_text "${workflow}" 'wc -c <"$patch_file"'
require_regex "${workflow}" 'persist-credentials:[[:space:]]*false' \
  "checkout must not persist a write credential"
require_no_regex "${workflow}" 'persist-credentials:[[:space:]]*true' \
  "artifact lane must not persist a write credential"

# Exact positive-integer validation rejects empty, zero, signs, and shell
# syntax in the issue/review selectors.
require_regex "${workflow}" '\^\[1-9\]\[0-9\]' \
  "issue/review input must use a positive-integer check"

# Artifact generation has no GitHub mutation capability. Read-only gh calls are
# allowed; known write commands and write-oriented API methods are not.
for forbidden in \
  'gh pr merge' 'gh pr comment' 'gh issue comment' 'gh issue edit' \
  'gh pr edit' 'gh label' 'git push' 'git commit' 'git merge' 'git tag' \
  'scripts/agent-loop-publish.sh' 'scripts/agent-loop-merge.sh'; do
  require_no_regex "${workflow}" "${forbidden}" "artifact workflow contains a mutation command: ${forbidden}"
done
require_no_regex "${workflow}" 'gh[[:space:]]+api[^\n]*(--method|-X)[[:space:]]+(POST|PUT|PATCH|DELETE)' \
  "artifact workflow contains a mutating GitHub API call"
require_no_regex "${workflow}" '(^|[[:space:]])[^#]*:[[:space:]]*(write|write-all)([[:space:]#]|$)' \
  "artifact workflow grants a write permission"
require_text "${workflow}" 'GH_TOKEN: ""'
require_text "${workflow}" 'GITHUB_TOKEN: ""'
require_text "${workflow}" 'CODEX_API_KEY: ""'

# Fail-closed artifact boundary. These checks cover model output, binary patch,
# symlink/new-file containment, and finite path/count limits.
require_any_text "${workflow}" "artifact workflow must isolate result paths" \
  "trusted artifact directory is unavailable" "unsafe-result-path" "result path is unsafe"
require_any_text "${workflow}" "artifact workflow must reject oversized result output" \
  "result-size-exceeded" "result JSON exceeds"
require_any_text "${workflow}" "artifact workflow must reject oversized patches" \
  "patch-size-exceeded" "patch exceeds"
require_any_text "${workflow}" "artifact workflow must reject unsafe new files" \
  "unsafe-new-file" "unsafe or oversized untracked file"
require_any_text "${workflow}" "artifact workflow must bound changed paths" \
  "changed-path-count-exceeded" "changed paths"
require_any_text "${workflow}" "result size limit is missing" '256 * 1024' '256 KiB'
require_any_text "${workflow}" "patch size limit is missing" \
  '10 * 1024 * 1024' '10 MiB' '10 * 1024*1024'
require_any_text "${workflow}" "symlink checks are missing" '[ -L' 'find . -type l' 'symlink'
require_any_text "${workflow}" "path containment checks are missing" 'realpath' 'canonical' 'containment'
require_any_text "${workflow}" "new-file enumeration is missing" 'git ls-files --others' 'git diff --name-only'
require_regex "${workflow}" 'sudo([[:space:]]+-n)?[[:space:]]+pkill[[:space:]]+-KILL[[:space:]]+-u[[:space:]]+rpm-codex' \
  "isolated Codex process cleanup is missing"
require_text "${workflow}" 'blocked_result "git-metadata-changed"'
require_text "${workflow}" 'blocked_result "codex-action-failed"'
require_text "${workflow}" "GIT_NO_REPLACE_OBJECTS=1"

stage_helper="${repo_root}/scripts/agent-loop-stage-files.sh"
require_file "${stage_helper}"
bash -n "${stage_helper}" || fail "stage helper has invalid Bash syntax"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-agent-loop-artifact.XXXXXX")"
cleanup_tmp_dir() {
  # The trusted-copy contract deliberately leaves its directory non-writable;
  # restore owner write bits before removing the test fixture on macOS/Linux.
  if [ -d "${tmp_dir:-}" ]; then
    find "${tmp_dir}" -type d -exec chmod u+rwx {} + 2>/dev/null || true
    find "${tmp_dir}" -type f -exec chmod u+rw {} + 2>/dev/null || true
    rm -rf -- "${tmp_dir}"
  fi
}
trap cleanup_tmp_dir EXIT

# Parse every workflow run block as Bash. This catches shell syntax errors in
# branches that the focused path fixtures do not execute.
run_blocks_dir="${tmp_dir}/workflow-run-blocks"
mkdir -p "${run_blocks_dir}"
ruby -ryaml - "${workflow}" "${run_blocks_dir}" <<'RUBY'
path = ARGV.fetch(0)
output_dir = ARGV.fetch(1)
document = YAML.safe_load(File.read(path), aliases: true)
steps = document.fetch("jobs").values.flat_map do |job|
  job.is_a?(Hash) && job["steps"].is_a?(Array) ? job["steps"] : []
end
run_blocks = steps.map { |step| step.is_a?(Hash) ? step["run"] : nil }.compact
raise "workflow has no run blocks" if run_blocks.empty?
run_blocks.each_with_index do |run, index|
  File.write(File.join(output_dir, format("%02d.sh", index)), run)
end
RUBY
for run_block in "${run_blocks_dir}"/*.sh; do
  bash -n "${run_block}" || fail "workflow run block has invalid Bash syntax: ${run_block}"
done
pass "workflow run-block Bash syntax"

# Execute the trusted-copy step itself. Static checks can miss a mode that is
# applied before a copy, so extract the exact run block with Psych and execute
# it against an isolated runner-temp directory.
copy_step_script="${tmp_dir}/copy-trusted-assets.sh"
if ! ruby -ryaml - "${workflow}" >"${copy_step_script}" <<'RUBY'
path = ARGV.fetch(0)
document = YAML.safe_load(File.read(path), aliases: true)
jobs = document.fetch("jobs")
steps = jobs.values.flat_map do |job|
  job.is_a?(Hash) && job["steps"].is_a?(Array) ? job["steps"] : []
end
step = steps.find { |candidate| candidate.is_a?(Hash) && candidate["name"] == "Copy trusted worker assets" }
raise "Copy trusted worker assets step is missing" unless step
run = step["run"]
raise "Copy trusted worker assets step has no run block" unless run.is_a?(String) && !run.empty?
print run
RUBY
then
  fail "trusted-copy step could not be extracted"
fi
chmod 0555 "${copy_step_script}"

runner_temp="${tmp_dir}/runner-temp"
github_output="${tmp_dir}/copy-output"
mkdir -p "${runner_temp}"
: >"${github_output}"
if ! (cd "${repo_root}" && \
  RUNNER_TEMP="${runner_temp}" GITHUB_OUTPUT="${github_output}" \
  bash "${copy_step_script}"); then
  fail "trusted-copy step failed during isolated execution"
fi

output_value() {
  local key="$1" value
  value="$(sed -n "s/^${key}=//p" "${github_output}")"
  [ -n "${value}" ] || fail "trusted-copy output is missing: ${key}"
  printf '%s' "${value}"
}

trusted_root="$(output_value trusted_root)"
artifact_dir="$(output_value artifact_dir)"
stage_sha256="$(output_value stage_sha256)"
schema_sha256="$(output_value schema_sha256)"
[ "${trusted_root}" = "${runner_temp}/rpm-codex-trusted" ] \
  || fail "trusted-copy output points outside the runner temp directory"
[ "${artifact_dir}" = "${runner_temp}/rpm-codex-artifact" ] \
  || fail "artifact output points outside the runner temp directory"
[ -d "${trusted_root}" ] && [ ! -L "${trusted_root}" ] \
  || fail "trusted root was not created as a real directory"
[ -d "${artifact_dir}" ] && [ ! -L "${artifact_dir}" ] \
  || fail "artifact directory was not created as a real directory"

mode_of() {
  local path="$1"
  if stat -c '%a' "${path}" >/dev/null 2>&1; then
    stat -c '%a' "${path}"
  else
    stat -f '%Lp' "${path}"
  fi
}

case "$(mode_of "${trusted_root}")" in
  555|0555) ;;
  *) fail "trusted root mode is not 0555" ;;
esac
case "$(mode_of "${artifact_dir}")" in
  700|0700) ;;
  *) fail "artifact directory mode is not 0700" ;;
esac

trusted_sources=(
  .github/codex/issue-agent-prompt.md
  .github/codex/review-agent-prompt.md
  .github/codex/result-schema.json
  scripts/agent-loop-stage-files.sh
  scripts/collect-pr-review-context.sh
)
for source in "${trusted_sources[@]}"; do
  destination="${trusted_root}/$(basename "${source}")"
  [ -f "${destination}" ] && [ ! -L "${destination}" ] \
    || fail "trusted-copy destination is missing or a symlink: ${source}"
  cmp -s -- "${source}" "${destination}" \
    || fail "trusted-copy content differs from source: ${source}"
  case "$(basename "${source}")" in
    agent-loop-stage-files.sh)
      case "$(mode_of "${destination}")" in
        555|0555) ;;
        *) fail "trusted stage helper mode is not 0555" ;;
      esac
      ;;
    *)
      case "$(mode_of "${destination}")" in
        444|0444) ;;
        *) fail "trusted read-only asset mode is not 0444: ${source}" ;;
      esac
      ;;
  esac
done

actual_stage_sha256="$(sha256sum "${trusted_root}/agent-loop-stage-files.sh" | awk '{print $1}')"
actual_schema_sha256="$(sha256sum "${trusted_root}/result-schema.json" | awk '{print $1}')"
[ "${stage_sha256}" = "${actual_stage_sha256}" ] \
  || fail "trusted stage helper output hash does not match the copied file"
[ "${schema_sha256}" = "${actual_schema_sha256}" ] \
  || fail "trusted schema output hash does not match the copied file"
[ "${stage_sha256}" = "$(sha256sum scripts/agent-loop-stage-files.sh | awk '{print $1}')" ] \
  || fail "trusted stage helper output hash does not match the source"
[ "${schema_sha256}" = "$(sha256sum .github/codex/result-schema.json | awk '{print $1}')" ] \
  || fail "trusted schema output hash does not match the source"

# The packager and upload must run only after their prerequisites succeeded so
# an invalid selector or preparation failure cannot produce a partial result.
ruby -ryaml - "${workflow}" <<'RUBY'
path = ARGV.fetch(0)
document = YAML.safe_load(File.read(path), aliases: true)
steps = document.fetch("jobs").values.flat_map do |job|
  job.is_a?(Hash) && job["steps"].is_a?(Array) ? job["steps"] : []
end
package = steps.find { |candidate| candidate.is_a?(Hash) && candidate["id"] == "package" }
raise "package step is missing" unless package
package_if = package["if"].to_s
%w[trusted_assets metadata checkout_guard].each do |step_id|
  expected = /steps\.#{Regexp.escape(step_id)}\.outcome\s*==\s*['"]success['"]/i
  raise "package step is not fail-closed for #{step_id}" unless package_if.match?(expected)
end
unless package_if.include?("steps.codex_user.outcome") && package_if.include?("steps.stop_codex.outcome")
  raise "package step does not require successful isolated-process cleanup"
end
package_env = package["env"]
if package_env.is_a?(Hash) && package_env.key?("CODEX_FINAL_MESSAGE")
  raise "package step passes Codex output through an environment variable"
end
upload = steps.find do |candidate|
  candidate.is_a?(Hash) && candidate["uses"].to_s.start_with?("actions/upload-artifact@")
end
raise "artifact upload step is missing" unless upload
upload_if = upload["if"].to_s
unless upload_if.match?(/steps\.package\.outcome\s*==\s*['"]success['"]/i)
  raise "artifact upload is not fail-closed on package success"
end
RUBY
pass "trusted-copy execution, permissions, hashes, and fail-closed guards"

# Execute the package block on the missing-secret path. This proves that a
# valid target can still produce the documented blocked-auth artifact without
# invoking Codex or depending on its untrusted output file.
package_step_script="${tmp_dir}/package-artifact.sh"
if ! ruby -ryaml - "${workflow}" >"${package_step_script}" <<'RUBY'
path = ARGV.fetch(0)
document = YAML.safe_load(File.read(path), aliases: true)
steps = document.fetch("jobs").values.flat_map do |job|
  job.is_a?(Hash) && job["steps"].is_a?(Array) ? job["steps"] : []
end
step = steps.find { |candidate| candidate.is_a?(Hash) && candidate["id"] == "package" }
raise "package step is missing" unless step
run = step["run"]
raise "package step has no run block" unless run.is_a?(String) && !run.empty?
print run
RUBY
then
  fail "package step could not be extracted"
fi
chmod 0555 "${package_step_script}"

package_repo="${tmp_dir}/package-repo"
package_runner_temp="${tmp_dir}/package-runner-temp"
package_artifact_dir="${package_runner_temp}/rpm-codex-artifact"
mkdir -p "${package_repo}" "${package_artifact_dir}"
chmod 0700 "${package_artifact_dir}"
git init -q "${package_repo}"
git -C "${package_repo}" config user.name fixture
git -C "${package_repo}" config user.email fixture@example.invalid
printf 'base\n' >"${package_repo}/README.md"
git -C "${package_repo}" add README.md
git -C "${package_repo}" commit -q -m base
package_sha="$(git -C "${package_repo}" rev-parse HEAD)"
package_git_dir="$(git -C "${package_repo}" rev-parse --absolute-git-dir)"
package_summary="${tmp_dir}/package-summary"
package_output="${tmp_dir}/package-output"
package_fake_bin="${tmp_dir}/package-fake-bin"
package_path="${PATH}"
if [ "$(uname -s)" = "Darwin" ]; then
  mkdir -p "${package_fake_bin}"
  cat >"${package_fake_bin}/stat" <<'STAT'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-c" ]; then
  format="${2:-}"
  shift 2
  case "${format}" in
    %a) exec /usr/bin/stat -f '%Lp' "$@" ;;
    %u) exec /usr/bin/stat -f '%u' "$@" ;;
    %h) exec /usr/bin/stat -f '%l' "$@" ;;
    %s) exec /usr/bin/stat -f '%z' "$@" ;;
    %F)
      if [ -f "${1:-}" ] && [ ! -L "${1:-}" ]; then
        printf 'regular file\n'
        exit 0
      fi
      exit 1
      ;;
  esac
fi
exec /usr/bin/stat "$@"
STAT
  chmod 0555 "${package_fake_bin}/stat"
  package_path="${package_fake_bin}:${PATH}"
fi
: >"${package_summary}"
: >"${package_output}"
if ! (
  cd "${package_repo}"
  RUNNER_TEMP="${package_runner_temp}" \
  GITHUB_STEP_SUMMARY="${package_summary}" \
  GITHUB_OUTPUT="${package_output}" \
  LANE=issue TARGET_NUMBER=1 REPOSITORY=owner/repo \
  BASE_SHA="${package_sha}" HEAD_SHA= START_SHA="${package_sha}" \
  AUTH_AVAILABLE=false PROMPT_READY=true CODEX_OUTCOME=skipped \
  TRUSTED_ROOT="${tmp_dir}/unused-trusted-root" \
  EXPECTED_STAGE_SHA=unused EXPECTED_SCHEMA_SHA=unused \
  EXPECTED_GIT_DIR="${package_git_dir}" EXPECTED_CONFIG_SHA=unused \
  EXPECTED_INDEX_SHA=unused EXPECTED_REFS_SHA=unused EXPECTED_TREE_SHA=unused \
  MAX_RESULT_BYTES=262144 MAX_PATCH_BYTES=10485760 \
  PATH="${package_path}" \
  BASH_ENV= ENV= LD_PRELOAD= \
  bash "${package_step_script}"
); then
  fail "package step failed on the blocked-auth path"
fi
jq -e '
  .version == 1 and .status == "blocked" and .issue == 1 and .pr == null and
  .base_sha == $sha and .head_sha == null and .reason == "blocked-auth"
' --arg sha "${package_sha}" "${package_artifact_dir}/result.json" >/dev/null \
  || fail "blocked-auth result artifact is invalid"
[ ! -s "${package_artifact_dir}/changes.patch" ] \
  || fail "blocked-auth artifact contains a non-empty patch"
jq -e '
  .version == 1 and .repository == "owner/repo" and .lane == "issue" and
  .number == 1 and .base_sha == $sha and .head_sha == null
' --arg sha "${package_sha}" "${package_artifact_dir}/identity.json" >/dev/null \
  || fail "blocked-auth identity artifact is invalid"
pass "blocked-auth package execution"

# Positive case: a new regular file is included without touching ignored build
# output. The original checkout remains untouched because this is a temp repo.
stage_repo="${tmp_dir}/stage-repo"
git init -q "${stage_repo}"
git -C "${stage_repo}" config user.name fixture
git -C "${stage_repo}" config user.email fixture@example.invalid
printf 'base\n' >"${stage_repo}/README.md"
printf 'target/\n' >"${stage_repo}/.gitignore"
git -C "${stage_repo}" add README.md .gitignore
git -C "${stage_repo}" commit -q -m base
mkdir -p "${stage_repo}/src" "${stage_repo}/target"
printf 'new regular file\n' >"${stage_repo}/src/new-file.txt"
printf 'ignored build output\n' >"${stage_repo}/target/build.bin"
stage_output="$(cd "${stage_repo}" && bash "${stage_helper}")"
printf '%s\n' "${stage_output}" | rg -q 'new_files=1|files=1' || fail "regular new file was not staged"
if git -C "${stage_repo}" diff --name-only | rg -q '(^|/)target(/|$)'; then
  fail "ignored build output entered the artifact patch"
fi
pass "regular new file and ignored output boundary"

# Rejection cases: symlink, protected path, and per-file size limit all fail
# before a patch can be accepted.
mkdir -p "${tmp_dir}/outside"
printf 'outside\n' >"${tmp_dir}/outside/escape.txt"
ln -s "${tmp_dir}/outside/escape.txt" "${stage_repo}/src/escape.txt"
set +e
symlink_output="$(cd "${stage_repo}" && bash "${stage_helper}" 2>&1)"
symlink_status=$?
set -e
[ "${symlink_status}" -ne 0 ] || fail "symlinked new file was accepted"
printf '%s\n' "${symlink_output}" | rg -q -i -e 'symlink|ancestor' || fail "symlink rejection reason is missing"
rm -f -- "${stage_repo}/src/escape.txt"
mkdir -p "${stage_repo}/scripts"
printf '#!/usr/bin/env bash\n' >"${stage_repo}/scripts/safe-direct-merge.sh"
set +e
protected_output="$(cd "${stage_repo}" && bash "${stage_helper}" 2>&1)"
protected_status=$?
set -e
[ "${protected_status}" -ne 0 ] || fail "protected new file was accepted"
printf '%s\n' "${protected_output}" | rg -q 'protected-path' || fail "protected path rejection reason is missing"
rm -f -- "${stage_repo}/scripts/safe-direct-merge.sh"
printf 'untrusted override\n' >"${stage_repo}/AGENTS.override.md"
set +e
override_output="$(cd "${stage_repo}" && bash "${stage_helper}" 2>&1)"
override_status=$?
set -e
[ "${override_status}" -ne 0 ] || fail "AGENTS.override.md was accepted"
printf '%s\n' "${override_output}" | rg -q 'protected-path:AGENTS.override.md' \
  || fail "AGENTS.override.md rejection reason is missing"
rm -f -- "${stage_repo}/AGENTS.override.md"
dd if=/dev/zero of="${stage_repo}/src/oversized.bin" bs=1024 count=1025 2>/dev/null
set +e
size_output="$(cd "${stage_repo}" && bash "${stage_helper}" 2>&1)"
size_status=$?
set -e
[ "${size_status}" -ne 0 ] || fail "oversized new file was accepted"
printf '%s\n' "${size_output}" | rg -q -i -e 'too-large|size-limit' || fail "size rejection reason is missing"
pass "symlink, protected path, and oversized file rejection"

# A staged rename can otherwise hide the protected source path because Git's
# rename detection reports only the destination in --name-only output.
rename_repo="${tmp_dir}/rename-repo"
git init -q "${rename_repo}"
git -C "${rename_repo}" config user.name fixture
git -C "${rename_repo}" config user.email fixture@example.invalid
mkdir -p "${rename_repo}/scripts" "${rename_repo}/src"
printf '#!/usr/bin/env bash\n' >"${rename_repo}/scripts/protected.sh"
git -C "${rename_repo}" add scripts/protected.sh
git -C "${rename_repo}" commit -q -m base
git -C "${rename_repo}" mv scripts/protected.sh src/moved.sh
set +e
rename_output="$(cd "${rename_repo}" && bash "${stage_helper}" 2>&1)"
rename_status=$?
set -e
[ "${rename_status}" -ne 0 ] || fail "staged protected-path rename was accepted"
printf '%s\n' "${rename_output}" | rg -q 'protected-path:scripts/protected.sh' \
  || fail "protected rename source rejection reason is missing"

# Staging a new file must not bypass the one-file size limit.
staged_add_repo="${tmp_dir}/staged-add-repo"
git init -q "${staged_add_repo}"
git -C "${staged_add_repo}" config user.name fixture
git -C "${staged_add_repo}" config user.email fixture@example.invalid
printf 'base\n' >"${staged_add_repo}/README.md"
git -C "${staged_add_repo}" add README.md
git -C "${staged_add_repo}" commit -q -m base
mkdir -p "${staged_add_repo}/src"
dd if=/dev/zero of="${staged_add_repo}/src/staged-oversized.bin" bs=1024 count=1025 2>/dev/null
git -C "${staged_add_repo}" add src/staged-oversized.bin
set +e
staged_add_output="$(cd "${staged_add_repo}" && bash "${stage_helper}" 2>&1)"
staged_add_status=$?
set -e
[ "${staged_add_status}" -ne 0 ] || fail "staged oversized new file was accepted"
printf '%s\n' "${staged_add_output}" | rg -q 'file-too-large:src/staged-oversized.bin' \
  || fail "staged oversized file rejection reason is missing"
pass "staged rename source and staged new-file limits"

printf 'agent_loop_artifact_test.status=ok\n'
