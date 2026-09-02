#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
helper="${repo_root}/scripts/quarantine-merge-selector-anomaly.sh"
policy="${repo_root}/.agents/workflows/backlog-policy.json"

fail() {
  printf 'quarantine_merge_selector_test.FAIL=%s\n' "$1" >&2
  exit 1
}

[ -x "$helper" ] || fail 'helper-missing'
[ -r "$policy" ] || fail 'policy-missing'

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-merge-selector-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
fake_bin="${tmp_dir}/bin"
mkdir -p "$fake_bin"
fake_gh="${fake_bin}/gh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'state="${FAKE_STATE:?}"' \
  'log="${FAKE_LOG:?}"' \
  'printf "%s\\n" "$*" >>"$log"' \
  'if [ "${1:-}" = issue ] && [ "${2:-}" = view ]; then' \
  '  if [ "${FAKE_READ_MODE:-normal}" = invalid ]; then printf "%s\\n" "{}"; exit 0; fi' \
  '  if [ "${FAKE_READ_MODE:-normal}" = changed ]; then jq '\''(.state = "OPEN" | .labels = [{name:"agent:ready"},{name:"kind:bug"}])'\'' "$state"; exit 0; fi' \
  '  if [[ "$*" == *"--json comments"* && "$*" != *"number,state,labels,comments"* ]]; then jq -c "{comments:.comments}" "$state"; else cat "$state"; fi' \
  'elif [ "${1:-}" = issue ] && [ "${2:-}" = edit ]; then' \
  '  if [ "${FAKE_EDIT_MODE:-normal}" = race ]; then jq '\''(.labels = [.labels[] | select(.name != "agent:awaiting-merge")] + [{name:"agent:ready"}])'\'' "$state" >"${state}.next"; mv "${state}.next" "$state"; exit 0; fi' \
  '  if [ "${FAKE_EDIT_MODE:-normal}" = drop-ordinary ]; then jq '\''(.labels = [.labels[] | select(.name != "agent:awaiting-merge" and .name != "kind:bug")] + [{name:"agent:blocked"}])'\'' "$state" >"${state}.next"; else jq '\''(.labels = [.labels[] | select(.name != "agent:awaiting-merge")] + [{name:"agent:blocked"}])'\'' "$state" >"${state}.next"; fi' \
  '  mv "${state}.next" "$state"' \
  'elif [ "${1:-}" = issue ] && [ "${2:-}" = comment ]; then' \
  '  body_file=""' \
  '  while [ "$#" -gt 0 ]; do if [ "$1" = --body-file ]; then body_file="$2"; shift 2; else shift; fi; done' \
  '  [ -n "$body_file" ] || exit 2' \
  '  jq --arg body "$(<"$body_file")" '\''(.comments += [{body:$body}])'\'' "$state" >"${state}.next"' \
  '  mv "${state}.next" "$state"' \
  'else' \
  '  printf "unexpected fake gh call: %s\\n" "$*" >&2' \
  '  exit 90' \
  'fi' >"$fake_gh"
chmod +x "$fake_gh"

run_case() {
  local name="$1" initial="$2" expected_rc="$3" edit_mode="${4:-normal}" read_mode="${5:-normal}" reason="${6:-no-closing-pr}"
  local case_dir state log output
  case_dir="${tmp_dir}/${name}"
  state="${case_dir}/state.json"
  log="${case_dir}/gh.log"
  mkdir -p "$case_dir"
  printf '%s\n' "$initial" >"$state"
  : >"$log"
  set +e
  output="$(
    PATH="${fake_bin}:${PATH}" \
      FAKE_STATE="$state" \
      FAKE_LOG="$log" \
      FAKE_EDIT_MODE="$edit_mode" \
      FAKE_READ_MODE="$read_mode" \
      GITHUB_REPOSITORY=nerdchanii/rpm \
      GH_TOKEN=test-token \
      bash "$helper" --policy "$policy" --issue 12 --reason "$reason" --details '테스트 사유' \
      2>"${case_dir}/stderr"
  )"
  local actual_rc=$?
  set -e
  [ "$actual_rc" -eq "$expected_rc" ] || {
    printf '%s\n' "$output" >&2
    fail "${name}-exit-${actual_rc}"
  }
  printf '%s\n' "$output"
}

awaiting='{"number":12,"state":"OPEN","labels":[{"name":"agent:awaiting-merge"},{"name":"kind:bug"}],"comments":[]}'
blocked='{"number":12,"state":"OPEN","labels":[{"name":"agent:blocked"},{"name":"kind:bug"}],"comments":[{"body":"<!-- rpm-agent-merge-selector-block: issue=12;reason=no-closing-pr -->\\nprevious"}]}'

run_case success "$awaiting" 0
success_state="${tmp_dir}/success/state.json"
jq -e '
  .state == "OPEN" and
  ([.labels[].name] | sort) == ["agent:blocked", "kind:bug"] and
  (.comments | length) == 1 and
  (.comments[0].body | startswith("<!-- rpm-agent-merge-selector-block: issue=12;reason=no-closing-pr -->"))
' "$success_state" >/dev/null || fail 'success-state'

run_case multiple-closing-references "$awaiting" 0 normal normal multiple-closing-references
multiple_state="${tmp_dir}/multiple-closing-references/state.json"
jq -e '
  .state == "OPEN" and
  ([.labels[].name] | sort) == ["agent:blocked", "kind:bug"] and
  (.comments | length) == 1 and
  (.comments[0].body | startswith("<!-- rpm-agent-merge-selector-block: issue=12;reason=multiple-closing-references -->"))
' "$multiple_state" >/dev/null || fail 'multiple-closing-references-state'

run_case dedupe "$blocked" 0
dedupe_state="${tmp_dir}/dedupe/state.json"
jq -e '(.comments | length) == 1 and ([.labels[].name] | sort) == ["agent:blocked", "kind:bug"]' "$dedupe_state" >/dev/null || fail 'dedupe-state'

run_case changed-before-write "$awaiting" 0 normal changed
changed_log="${tmp_dir}/changed-before-write/gh.log"
! rg -q 'issue edit|issue comment' "$changed_log" || fail 'changed-before-write-mutated'

run_case invalid-read "$awaiting" 1 normal invalid
invalid_log="${tmp_dir}/invalid-read/gh.log"
! rg -q 'issue edit|issue comment' "$invalid_log" || fail 'invalid-read-mutated'

run_case ordinary-label-loss "$awaiting" 1 drop-ordinary

run_case unknown-reason "$awaiting" 1 normal normal unknown-reason
unknown_log="${tmp_dir}/unknown-reason/gh.log"
! rg -q 'issue edit|issue comment' "$unknown_log" || fail 'unknown-reason-mutated'

printf 'quarantine_merge_selector_test.PASS=state-cas-labels-comment-dedupe\n'
