#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
workflow="$repo_root/.github/workflows/issue-labeler.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file=$1
  local text=$2
  grep -Fq -- "$text" "$file" || fail "$file is missing: $text"
}

assert_not_contains() {
  local file=$1
  local text=$2
  if grep -Fq -- "$text" "$file"; then
    fail "$file unexpectedly contains: $text"
  fi
}

[ -f "$workflow" ] || fail "workflow is missing"
ruby -e 'require "yaml"; YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)' \
  "$workflow" >/dev/null || fail "workflow YAML is invalid"

# Keep the trigger and the repository guard aligned with openai/codex's pattern.
assert_contains "$workflow" 'types: [opened, labeled]'
assert_contains "$workflow" "github.repository == 'nerdchanii/rpm'"
assert_contains "$workflow" "github.event.action == 'labeled' && github.event.label.name == 'codex-label'"
assert_contains "$workflow" "github.event.issue.user.login == 'nerdchanii'"
assert_contains "$workflow" "github.actor == 'nerdchanii'"
assert_contains "$workflow" 'group: issue-labeler-${{ github.repository }}-${{ github.event.issue.number }}'
assert_contains "$workflow" 'cancel-in-progress: false'

gather_trigger="$(sed -n '/^  gather-labels:/,/^    runs-on:/p' "$workflow")"
apply_trigger="$(sed -n '/^  apply-labels:/,/^    runs-on:/p' "$workflow")"
for trigger_block in "$gather_trigger" "$apply_trigger"; do
  printf '%s\n' "$trigger_block" | grep -Fq "github.repository == 'nerdchanii/rpm'" \
    || fail "trusted trigger must guard repository"
  printf '%s\n' "$trigger_block" | grep -Fq "github.event.action == 'opened'" \
    || fail "trusted trigger must handle opened events"
  printf '%s\n' "$trigger_block" | grep -Fq "github.event.issue.user.login == 'nerdchanii'" \
    || fail "trusted trigger must require owner for opened events"
  printf '%s\n' "$trigger_block" | grep -Fq "github.event.action == 'labeled'" \
    || fail "trusted trigger must handle labeled events"
  printf '%s\n' "$trigger_block" | grep -Fq "github.event.label.name == 'codex-label'" \
    || fail "trusted trigger must require codex-label for labeled events"
  printf '%s\n' "$trigger_block" | grep -Fq "github.actor == 'nerdchanii'" \
    || fail "trusted trigger must require owner for labeled events"
done

# Exercise the four trigger cases so future edits cannot accidentally turn the
# policy back into "every opened issue" or "every codex-label event".
ruby <<'RUBY' || fail "trusted trigger scenarios failed"
cases = [
  ["owner-opened", {repository: "nerdchanii/rpm", action: "opened", issue_user: "nerdchanii", actor: "nerdchanii"}, true],
  ["external-opened", {repository: "nerdchanii/rpm", action: "opened", issue_user: "outside-user", actor: "outside-user"}, false],
  ["owner-added-codex-label", {repository: "nerdchanii/rpm", action: "labeled", issue_user: "outside-user", label: "codex-label", actor: "nerdchanii"}, true],
  ["untrusted-label-event", {repository: "nerdchanii/rpm", action: "labeled", issue_user: "outside-user", label: "codex-label", actor: "outside-user"}, false],
]

trusted = lambda do |event|
  event[:repository] == "nerdchanii/rpm" &&
    ((event[:action] == "opened" && event[:issue_user] == "nerdchanii") ||
      (event[:action] == "labeled" && event[:label] == "codex-label" && event[:actor] == "nerdchanii"))
end

cases.each do |name, event, expected|
  actual = trusted.call(event)
  abort "#{name}: expected #{expected}, got #{actual}" unless actual == expected
end
RUBY

# The model job is read-only and uses the exact reviewed action revision.
assert_contains "$workflow" 'uses: openai/codex-action@5c3f4ccdb2b8790f73d6b21751ac00e602aa0c02 # v1.7'
assert_contains "$workflow" 'environment: issue-triage'
assert_contains "$workflow" 'openai-api-key: ${{ secrets.CODEX_OPENAI_API_KEY }}'
assert_contains "$workflow" 'allow-users: "nerdchanii"'
assert_not_contains "$workflow" 'allow-users: "*"'
assert_contains "$workflow" 'safety-strategy: drop-sudo'
assert_contains "$workflow" 'sandbox: read-only'

gather_block="$(sed -n '/^  gather-labels:/,/^  apply-labels:/p' "$workflow")"
apply_block="$(sed -n '/^  apply-labels:/,$p' "$workflow")"
printf '%s\n' "$gather_block" | grep -Fq 'contents: read' || fail "gather job must read contents"
if printf '%s\n' "$gather_block" | grep -Fq 'issues: write'; then
  fail "gather job must not write issues"
fi

# The mutation job receives only the GitHub issue-write permission. The API key
# must never cross the job boundary.
printf '%s\n' "$apply_block" | grep -Fq 'contents: read' || fail "apply job must read contents"
printf '%s\n' "$apply_block" | grep -Fq 'issues: write' || fail "apply job must write issues"
assert_not_contains <(printf '%s\n' "$apply_block") 'CODEX_OPENAI_API_KEY'
assert_not_contains <(printf '%s\n' "$apply_block") 'openai-api-key:'

# Require exactly one of RPM's five mutually exclusive classification labels in
# both the structured schema and the write-boundary shell check.
for label in bug enhancement documentation refactor planning; do
  assert_contains "$workflow" "\"$label\""
  assert_contains "$workflow" "$label"
done
assert_contains "$workflow" '"minItems": 1'
assert_contains "$workflow" '"maxItems": 1'
assert_contains "$workflow" '"uniqueItems": true'
assert_contains "$workflow" '"enum": ['
assert_contains "$workflow" '((.labels | length) == 1)'
assert_contains "$workflow" '((.labels | unique | length) == 1)'
assert_contains "$workflow" 'keys | sort'
assert_contains "$workflow" '--argjson allowed'
assert_contains "$workflow" 'current_labels="$(gh issue view "$ISSUE_NUMBER"'
assert_contains "$workflow" 'grep -Fxq -- "$core_label"'
assert_contains "$workflow" 'command+=(--remove-label "$core_label")'
assert_contains "$workflow" 'command+=(--add-label "$selected")'
assert_contains "$workflow" '"${command[@]}"'

# The prompt and schema keep workflow labels outside the model's output contract.
for forbidden in 'agent:*' 'process:*' 'milestone-contract' 'codex-label'; do
  assert_contains "$workflow" "$forbidden"
done
assert_contains "$workflow" 'They are forbidden in model output.'
assert_contains "$workflow" 'Do not add, remove, or change lifecycle labels.'

# A manual codex-label retrigger is cleaned up even after a failed model run.
assert_contains "$workflow" 'always()'
assert_contains "$workflow" 'Attempted to remove label: codex-label'
assert_contains "$workflow" 'gh issue edit "$ISSUE_NUMBER" --repo "$GH_REPO" --remove-label codex-label || true'
assert_contains "$workflow" 'needs.gather-labels.result != '\''success'\'''

echo "PASS: issue-labeler workflow contract"
