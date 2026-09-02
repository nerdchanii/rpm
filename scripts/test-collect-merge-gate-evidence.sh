#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
collector="${repo_root}/scripts/collect-merge-gate-evidence.sh"
checker="${repo_root}/scripts/check-merge-gate.py"
policy="${repo_root}/.agents/workflows/backlog-policy.json"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-collect-merge-gate.XXXXXX")"
trap 'rm -rf -- "$tmp_dir"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

cat >"$tmp_dir/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

log_file="${GH_LOG:?}"
printf '%s\n' "$*" >>"$log_file"
json() { printf '%s\n' "$1"; }

if [ "${1:-}" = api ]; then
  endpoint=""
  query=""
  threads_after=""
  reviews_after=""
  closing_after=""
  for arg in "$@"; do
    case "$arg" in
      repos/*) endpoint="$arg" ;;
      query=*) query="${arg#query=}" ;;
      threadsAfter=*) threads_after="${arg#threadsAfter=}" ;;
      reviewsAfter=*) reviews_after="${arg#reviewsAfter=}" ;;
      after=*) closing_after="${arg#after=}" ;;
    esac
  done
  case "$endpoint" in
    repos/nerdchanii/rpm/issues\?*)
      if [ "${GH_NO_CANDIDATE:-0}" = 1 ]; then
        json '[[ ]]'
      elif [ "${GH_LOWER_CANDIDATE:-0}" = 1 ]; then
        json '[[{"number":11,"title":"lower","html_url":"https://github.com/nerdchanii/rpm/issues/11","state":"open","labels":[{"name":"agent:awaiting-merge"}]}],[{"number":12,"title":"target","html_url":"https://github.com/nerdchanii/rpm/issues/12","state":"open","labels":[{"name":"agent:awaiting-merge"}]}]]'
      else
        json '[[{"number":12,"title":"target","html_url":"https://github.com/nerdchanii/rpm/issues/12","state":"open","labels":[{"name":"agent:awaiting-merge"}]}]]'
      fi
      ;;
    repos/nerdchanii/rpm/issues/12/timeline\?*)
      json '[[{"event":"labeled","label":{"name":"agent:awaiting-merge"},"actor":{"login":"github-actions[bot]"}},{"event":"cross-referenced","source":{"issue":{"number":44,"title":"PR","html_url":"https://github.com/nerdchanii/rpm/pull/44","pull_request":{"url":"x"}}}}]]'
      ;;
    repos/nerdchanii/rpm/pulls/44)
      json '{"number":44,"title":"PR","html_url":"https://github.com/nerdchanii/rpm/pull/44","state":"open","draft":false,"mergeable":true,"mergeable_state":"clean","base":{"ref":"main","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo":{"full_name":"nerdchanii/rpm"}},"head":{"ref":"agent/issue-12","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"nerdchanii/rpm"}}}'
      ;;
    repos/nerdchanii/rpm/git/ref/heads/main)
      json '{"object":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}'
      ;;
    repos/nerdchanii/rpm/branches/main/protection)
      case "${GH_PROTECTION_MODE:-valid}" in
        contexts-only)
          json '{"enforce_admins":{"enabled":true},"required_conversation_resolution":{"enabled":true},"required_status_checks":{"strict":true,"contexts":["metadata","verify"]},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
          ;;
        missing)
          json '{"enforce_admins":{"enabled":true},"required_conversation_resolution":{"enabled":true},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
          ;;
        null)
          json '{"enforce_admins":{"enabled":true},"required_conversation_resolution":{"enabled":true},"required_status_checks":{"strict":true,"contexts":["metadata","verify"],"checks":[{"context":"metadata","app_id":null},{"context":"verify","app_id":15368}]},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
          ;;
        negative)
          json '{"enforce_admins":{"enabled":true},"required_conversation_resolution":{"enabled":true},"required_status_checks":{"strict":true,"contexts":["metadata","verify"],"checks":[{"context":"metadata","app_id":-1},{"context":"verify","app_id":15368}]},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
          ;;
        duplicate)
          json '{"enforce_admins":{"enabled":true},"required_conversation_resolution":{"enabled":true},"required_status_checks":{"strict":true,"contexts":["metadata","metadata","verify"],"checks":[{"context":"metadata","app_id":15368},{"context":"metadata","app_id":15368},{"context":"verify","app_id":15368}]},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
          ;;
        *)
          json '{"enforce_admins":{"enabled":true},"required_conversation_resolution":{"enabled":true},"required_status_checks":{"strict":true,"contexts":["metadata","verify"],"checks":[{"context":"metadata","app_id":15368},{"context":"verify","app_id":15368}]},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
          ;;
      esac
      ;;
    *)
      if [[ "$query" == *closingIssuesReferences* ]]; then
        if [ "${GH_SIMPLE_CROSS_REFERENCE:-0}" = 1 ]; then
          json '{"data":{"repository":{"pullRequest":{"number":44,"repository":{"nameWithOwner":"nerdchanii/rpm"},"closingIssuesReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
        elif [ "${GH_CLOSING_EXTRA:-0}" = 1 ]; then
          json '{"data":{"repository":{"pullRequest":{"number":44,"repository":{"nameWithOwner":"nerdchanii/rpm"},"closingIssuesReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":12,"repository":{"nameWithOwner":"nerdchanii/rpm"}},{"number":13,"repository":{"nameWithOwner":"nerdchanii/rpm"}}]}}}}}'
        elif [ -z "$closing_after" ]; then
          json '{"data":{"repository":{"pullRequest":{"number":44,"repository":{"nameWithOwner":"nerdchanii/rpm"},"closingIssuesReferences":{"pageInfo":{"hasNextPage":true,"endCursor":"closing-1"},"nodes":[]}}}}}'
        else
          json '{"data":{"repository":{"pullRequest":{"number":44,"repository":{"nameWithOwner":"nerdchanii/rpm"},"closingIssuesReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":12,"repository":{"nameWithOwner":"nerdchanii/rpm"}}]}}}}}'
        fi
      elif [[ "$query" == *reviewThreads* ]]; then
        review_nodes='[]'
        case "${GH_REVIEW_MODE:-none}" in
          old-head-p1)
            review_nodes='[{"id":"review-old-head","state":"COMMENTED","body":"**P1:** old head finding","submittedAt":"2026-09-01T00:00:00Z","commit":{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"author":{"login":"reviewer"}} ,{"id":"review-current-approved","state":"APPROVED","body":"Looks good.","submittedAt":"2026-09-01T00:00:01Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"author":{"login":"reviewer"}}]'
            ;;
          dismissed-p1)
            review_nodes='[{"id":"review-dismissed","state":"DISMISSED","body":"**P1:** dismissed finding","submittedAt":"2026-09-01T00:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"author":{"login":"reviewer"}}]'
            ;;
          pending-null)
            review_nodes='[{"id":"review-pending","state":"PENDING","body":"**P1:** pending finding","submittedAt":null,"commit":null,"author":{"login":"reviewer"}}]'
            ;;
          current-bold-p1)
            review_nodes='[{"id":"review-current-commented","state":"COMMENTED","body":"**P1:** current commented finding","submittedAt":"2026-09-01T00:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"author":{"login":"reviewer"}},{"id":"review-current-changes-requested","state":"CHANGES_REQUESTED","body":"**P1:** current requested finding","submittedAt":"2026-09-01T00:00:01Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"author":{"login":"reviewer"}}]'
            ;;
          current-bold-wrapped-p1)
            review_nodes='[{"id":"review-current-bold-wrapped-p1","state":"COMMENTED","body":"**P1**: current critical finding","submittedAt":"2026-09-01T00:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"author":{"login":"reviewer"}}]'
            ;;
          current-bold-wrapped-p0)
            review_nodes='[{"id":"review-current-bold-wrapped-p0","state":"COMMENTED","body":"**P0**: current critical finding","submittedAt":"2026-09-01T00:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"author":{"login":"reviewer"}}]'
            ;;
          current-bracket-p0)
            review_nodes='[{"id":"review-current-bracket-p0","state":"COMMENTED","body":"[P0] current critical finding","submittedAt":"2026-09-01T00:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"author":{"login":"reviewer"}}]'
            ;;
          current-bold-bracket-p1)
            review_nodes='[{"id":"review-current-bold-bracket-p1","state":"COMMENTED","body":"**[P1]** current critical finding","submittedAt":"2026-09-01T00:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"author":{"login":"reviewer"}}]'
            ;;
          current-em-dash-p1)
            review_nodes='[{"id":"review-current-em-dash-p1","state":"COMMENTED","body":"P1— current critical finding","submittedAt":"2026-09-01T00:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"author":{"login":"reviewer"}}]'
            ;;
          current-en-dash-p1)
            review_nodes='[{"id":"review-current-en-dash-p1","state":"COMMENTED","body":"P1– current critical finding","submittedAt":"2026-09-01T00:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"author":{"login":"reviewer"}}]'
            ;;
          current-hyphen-p1)
            review_nodes='[{"id":"review-current-hyphen-p1","state":"COMMENTED","body":"P1- current critical finding","submittedAt":"2026-09-01T00:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"author":{"login":"reviewer"}}]'
            ;;
          current-badge-p1)
            review_nodes='[{"id":"review-current-badge-p1","state":"COMMENTED","body":"P1 Badge current critical finding","submittedAt":"2026-09-01T00:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"author":{"login":"reviewer"}}]'
            ;;
          invalid-state)
            review_nodes='[{"id":"review-invalid-state","state":"UNKNOWN","body":"review","submittedAt":"2026-09-01T00:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"author":{"login":"reviewer"}}]'
            ;;
          invalid-commit)
            review_nodes='[{"id":"review-invalid-commit","state":"COMMENTED","body":"review","submittedAt":"2026-09-01T00:00:00Z","commit":{"oid":"not-a-sha"},"author":{"login":"reviewer"}}]'
            ;;
        esac
        if [ -n "$threads_after" ]; then
          json "{\"data\":{\"repository\":{\"pullRequest\":{\"number\":44,\"headRefOid\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":\"cursor-2\"},\"nodes\":[{\"id\":\"thread-2\",\"isResolved\":true,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]}}]},\"reviews\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":${review_nodes}},\"mergeQueueEntry\":null}}}}"
        else
          json "{\"data\":{\"repository\":{\"pullRequest\":{\"number\":44,\"headRefOid\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"cursor-1\"},\"nodes\":[{\"id\":\"thread-1\",\"isResolved\":true,\"isOutdated\":false,\"comments\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]}}]},\"reviews\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":${review_nodes}},\"mergeQueueEntry\":null}}}}"
        fi
      else
        json '{"errors":[{"message":"unexpected endpoint"}]}'
        exit 1
      fi
      ;;
  esac
  exit 0
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = checks ]; then
  json '[{"name":"metadata","bucket":"pass"},{"name":"verify","bucket":"pass"}]'
  exit 0
fi

printf 'unexpected fake gh call: %s\n' "$*" >&2
exit 99
FAKE_GH
chmod +x "$tmp_dir/gh"

export PATH="$tmp_dir:$PATH"
export GH_LOG="$tmp_dir/gh.log"
: >"$GH_LOG"

evidence="$tmp_dir/evidence.json"
if ! "$collector" --repo nerdchanii/rpm --policy "$policy" --output "$evidence" >/dev/null; then
  fail 'collector rejected the paginated happy snapshot'
fi
jq -e '
  .schema_version == 1 and .repository == "nerdchanii/rpm" and
  .selection.status == "merge" and .selection.issue == 12 and
  .selection.pr == 44 and .selection.base_sha == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and
  .selection.head_sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  .issues[0].awaiting_merge_transition_actor == "github-actions[bot]" and
  .issues[0].closing_prs[0].server_protection.required_status_checks == [
    {"context":"metadata","app_id":15368},
    {"context":"verify","app_id":15368}
  ] and
  (.issues[0].closing_prs[0].review_threads | length == 2)
' "$evidence" >/dev/null || fail 'collector output did not preserve the complete canonical shape'
if ! python3 "$checker" --policy "$policy" --issues-file "$evidence" --operation select-merge \
  --expected-head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --expected-base-sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >/dev/null; then
  fail 'checker rejected the canonical happy snapshot'
fi
pass 'collector flattens all pages and emits checker-compatible evidence'

run_review_case() {
  local mode="$1" expected_top_level="$2" expected_status="$3" evidence result
  evidence="$tmp_dir/review-${mode}.json"
  export GH_REVIEW_MODE="$mode"
  if ! "$collector" --repo nerdchanii/rpm --policy "$policy" --output "$evidence" >/dev/null; then
    fail "collector rejected review case: ${mode}"
  fi
  jq -e --argjson expected "$expected_top_level" '
    .issues[0].closing_prs[0].top_level_p0_p1 == $expected
    and .issues[0].closing_prs[0].unresolved_p0_p1 == $expected
  ' "$evidence" >/dev/null || fail "collector calculated top-level review gate incorrectly: ${mode}"

  if [ "$expected_status" = merge ]; then
    if ! result="$(python3 "$checker" --policy "$policy" --issues-file "$evidence" --operation select-merge \
      --expected-head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      --expected-base-sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)"; then
      fail "checker blocked a safe review case: ${mode}"
    fi
    jq -e '.data.status == "merge" and .data.reason == "gate-passed"' <<<"$result" >/dev/null \
      || fail "checker emitted an unexpected result for review case: ${mode}"
  else
    if result="$(python3 "$checker" --policy "$policy" --issues-file "$evidence" --operation select-merge \
      --expected-head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      --expected-base-sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2>/dev/null)"; then
      fail "checker merged a blocking review case: ${mode}"
    fi
    jq -e '.data.status == "blocked" and .data.reason == "review-findings-remain"' <<<"$result" >/dev/null \
      || fail "checker emitted an unexpected blocking result for review case: ${mode}"
  fi
  unset GH_REVIEW_MODE
  pass "collector filters top-level reviews safely: ${mode}"
}

run_review_case old-head-p1 false merge
run_review_case dismissed-p1 false merge
run_review_case pending-null false merge
run_review_case current-bold-p1 true blocked
run_review_case current-bold-wrapped-p1 true blocked
run_review_case current-bold-wrapped-p0 true blocked
run_review_case current-bracket-p0 true blocked
run_review_case current-bold-bracket-p1 true blocked
run_review_case current-em-dash-p1 true blocked
run_review_case current-en-dash-p1 true blocked
run_review_case current-hyphen-p1 true blocked
run_review_case current-badge-p1 true blocked

for invalid_review_mode in invalid-state invalid-commit; do
  export GH_REVIEW_MODE="$invalid_review_mode"
  if "$collector" --repo nerdchanii/rpm --policy "$policy" >/dev/null 2>"$tmp_dir/${invalid_review_mode}.err"; then
    fail "collector accepted malformed top-level review: ${invalid_review_mode}"
  fi
  unset GH_REVIEW_MODE
  pass "collector rejects malformed top-level review: ${invalid_review_mode}"
done

: >"$GH_LOG"
export GH_NO_CANDIDATE=1
if ! no_work="$($collector --repo nerdchanii/rpm --policy "$policy")"; then
  fail 'collector rejected an empty awaiting-merge queue'
fi
jq -e '.selection.status == "no-work" and .selection.reason == "no-awaiting-merge-candidate" and .issues == []' <<<"$no_work" >/dev/null \
  || fail 'collector did not emit the canonical no-work result'
unset GH_NO_CANDIDATE
pass 'collector emits an idempotent no-work result'

: >"$GH_LOG"
export GH_SIMPLE_CROSS_REFERENCE=1
simple_reference="$tmp_dir/simple-reference.json"
if ! "$collector" --repo nerdchanii/rpm --policy "$policy" --output "$simple_reference" >/dev/null; then
  fail 'collector rejected a timeline-only PR reference'
fi
jq -e '.selection.status == "blocked" and .selection.reason == "ambiguous-closing-pr" and .selection.pr == null and (.issues[0].closing_prs | length == 0)' "$simple_reference" >/dev/null \
  || fail 'collector treated a simple timeline mention as a closing PR'
unset GH_SIMPLE_CROSS_REFERENCE
pass 'collector excludes a PR that does not close the selected issue'

: >"$GH_LOG"
export GH_CLOSING_EXTRA=1
if "$collector" --repo nerdchanii/rpm --policy "$policy" >/dev/null 2>&1; then
  fail 'collector accepted an extra closing issue reference'
fi
unset GH_CLOSING_EXTRA
pass 'collector rejects an extra closing issue reference'

: >"$GH_LOG"
export GH_LOWER_CANDIDATE=1
if "$collector" --repo nerdchanii/rpm --policy "$policy" --expected-issue 12 --expected-pr 44 >/dev/null 2>&1; then
  fail 'collector accepted a lower candidate appearing in a later inventory'
fi
pass 'collector rejects a changed lowest candidate'

for protection_mode in contexts-only missing null negative duplicate; do
  export GH_PROTECTION_MODE="$protection_mode"
  if "$collector" --repo nerdchanii/rpm --policy "$policy" >/dev/null 2>"$tmp_dir/${protection_mode}.err"; then
    fail "collector accepted malformed branch protection: ${protection_mode}"
  fi
  pass "collector rejects malformed branch protection: ${protection_mode}"
done
unset GH_PROTECTION_MODE
