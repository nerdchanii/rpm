#!/usr/bin/env bash
set -euo pipefail

# safe-direct-merge.sh — gate-checked squash merge for PRs the scheduled
# merge-gatekeeper cannot reach (e.g. a PR with no closing issue, or issues
# outside the agent lifecycle). Verifies the SAME conditions the gate checks
# in .agents/workflows/backlog-policy.json `merge_gate`, blocks on unsafe linked
# worktrees, squash-merges, and safely cleans up matching branches
# without paying the full pre-push test gate on ref deletions.

usage() {
  cat <<'USAGE'
usage: safe-direct-merge.sh [--dry-run] [--allow-findings] <pr> [<pr> ...]

Gate-checked squash merge for one or more PRs, for the manual path the
scheduled merge-gatekeeper cannot reach (a PR with no closing issue, or issues
outside the agent lifecycle). Pass PRs in dependency-friendly order: land a
referenced PR before one that references it.

For each PR, verifies (mirroring merge_gate in backlog-policy.json):
  - state OPEN, not draft
  - mergeable true, mergeState CLEAN
  - every check named in merge_gate.required_checks concluded pass
  - GitHub enforces those checks and conversation resolution at merge time
  - no unresolved review threads (--allow-findings overrides)

Then, per PR:
  - rejects cross-repository PRs
  - rejects dirty git worktrees still holding the PR branch
  - preserves primary/current worktrees and blocks on any other linked checkout
  - squash-merges via `gh pr merge --squash`
  - deletes the merged remote branch through an encoded, pinned API endpoint
  - deletes only an unreferenced local branch still matching the merged head

Options:
  --dry-run          verify and report only; merge nothing
  --allow-findings   override only the local unresolved-thread count; platform
                     conversation-resolution enforcement still applies

Does NOT touch issue/PR labels, never force-pushes, never requests @codex,
and never blocks on a fresh Automatic review. Execute only the clean-main
launcher configured in rpm.safeDirectMergeTrustedCheckout; PR copies fail.
USAGE
}

normalize_github_repo() {
  local remote="$1"
  remote="${remote,,}"
  remote="${remote%.git}"
  case "$remote" in
    git@github.com:*) remote="${remote#git@github.com:}" ;;
    ssh://git@github.com/*) remote="${remote#ssh://git@github.com/}" ;;
    https://github.com/*) remote="${remote#https://github.com/}" ;;
    http://github.com/*) remote="${remote#http://github.com/}" ;;
    *) return 1 ;;
  esac
  if [[ "$remote" =~ ^[^/]+/[^/]+$ ]]; then
    printf '%s\n' "${remote,,}"
  else
    return 1
  fi
}

canonical_path() {
  local path="$1"
  (cd "$(dirname "$path")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")")
}

if ! command -v git >/dev/null 2>&1; then
  echo "safe-direct-merge.error=missing-git" >&2
  exit 127
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "safe-direct-merge.error=missing-gh" >&2
  exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "safe-direct-merge.error=missing-jq" >&2
  exit 127
fi

original_args=("$@")
trusted_stage="${RPM_SAFE_DIRECT_MERGE_STAGE:-launcher}"
# A shared worktree can create replace refs without dirtying the trusted main
# checkout. Object identity for the trust root must ignore those refs.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_REPLACE_REF_BASE
export GIT_NO_REPLACE_OBJECTS=1
export GH_HOST=github.com

if [ "$trusted_stage" = "launcher" ]; then
  # The trust root lives in repository-local Git config, outside PR content.
  # Invoke this script from that configured clean main checkout. A script in
  # the current PR checkout is never a valid launcher.
  if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "safe-direct-merge.error=missing-repository" >&2
    exit 2
  fi
  if ! trusted_checkout="$(git config --local --path --get rpm.safeDirectMergeTrustedCheckout 2>/dev/null)" \
    || [[ "$trusted_checkout" != /* ]]; then
    echo "safe-direct-merge.error=missing-trusted-checkout" >&2
    exit 2
  fi
  if ! trusted_checkout="$(canonical_path "$trusted_checkout")" \
    || [ ! -d "$trusted_checkout" ]; then
    echo "safe-direct-merge.error=invalid-trusted-checkout" >&2
    exit 2
  fi
  launcher_path="$trusted_checkout/scripts/safe-direct-merge.sh"
  if [ "$(canonical_path "$0")" != "$(canonical_path "$launcher_path")" ]; then
    echo "safe-direct-merge.error=untrusted-launcher" >&2
    exit 2
  fi
  if [ "$(git -C "$trusted_checkout" rev-parse --show-toplevel 2>/dev/null || true)" != "$trusted_checkout" ] \
    || [ "$(git -C "$trusted_checkout" symbolic-ref --short HEAD 2>/dev/null || true)" != "main" ]; then
    echo "safe-direct-merge.error=trusted-checkout-not-main" >&2
    exit 2
  fi
  repo_common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  trusted_common_dir="$(git -C "$trusted_checkout" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -z "$repo_common_dir" ] || [ "$repo_common_dir" != "$trusted_common_dir" ]; then
    echo "safe-direct-merge.error=trusted-checkout-repository-mismatch" >&2
    exit 2
  fi
  if [ -n "$(git -C "$trusted_checkout" -c core.fsmonitor=false \
    status --porcelain --untracked-files=all 2>/dev/null || printf 'status-failed')" ]; then
    echo "safe-direct-merge.error=trusted-checkout-dirty" >&2
    exit 2
  fi
  if ! origin_url="$(git -C "$trusted_checkout" config --local --get remote.origin.url 2>/dev/null)" \
    || ! repo="$(normalize_github_repo "$origin_url")"; then
    echo "safe-direct-merge.error=unsupported-trusted-origin" >&2
    exit 2
  fi
  if ! trusted_main_sha="$(gh api -X GET "repos/$repo/commits/main" --jq .sha 2>/dev/null)" \
    || [[ ! "$trusted_main_sha" =~ ^[[:xdigit:]]{40}$ ]] \
    || [ "$(git -C "$trusted_checkout" rev-parse HEAD 2>/dev/null || true)" != "$trusted_main_sha" ] \
    || ! git -C "$trusted_checkout" cat-file -e "${trusted_main_sha}^{commit}" 2>/dev/null; then
    echo "safe-direct-merge.error=trusted-checkout-not-live-main" >&2
    exit 2
  fi

  trusted_root="$(mktemp -d "${TMPDIR:-/tmp}/rpm-safe-direct-trusted.XXXXXX")"
  cleanup_trusted_root() {
    # trusted_root is assigned only from mktemp in this launcher. Keeping the
    # cleanup in the launcher prevents caller-supplied implementation-stage
    # variables from selecting a deletion target.
    rm -rf -- "$trusted_root"
  }
  trap cleanup_trusted_root EXIT
  mkdir -p "$trusted_root/scripts" "$trusted_root/.agents/workflows"
  for trusted_asset in \
    scripts/safe-direct-merge.sh \
    scripts/collect-pr-review-context.sh \
    .agents/workflows/backlog-policy.json
  do
    if ! expected_blob="$(git -C "$trusted_checkout" rev-parse "$trusted_main_sha:$trusted_asset" 2>/dev/null)" \
      || ! git -C "$trusted_checkout" show "$trusted_main_sha:$trusted_asset" >"$trusted_root/$trusted_asset" \
      || ! actual_blob="$(git hash-object "$trusted_root/$trusted_asset" 2>/dev/null)" \
      || [ "$actual_blob" != "$expected_blob" ]; then
      echo "safe-direct-merge.error=trusted-main-asset-invalid:$trusted_asset" >&2
      exit 2
    fi
    case "$trusted_asset" in
      scripts/safe-direct-merge.sh) trusted_script_blob="$expected_blob" ;;
      scripts/collect-pr-review-context.sh) trusted_collector_blob="$expected_blob" ;;
      .agents/workflows/backlog-policy.json) trusted_policy_blob="$expected_blob" ;;
    esac
  done
  # Load exact bytes with a non-newline sentinel so command substitution keeps
  # trailing newlines. The second hash closes the verify-to-read window. Once
  # loaded, no materialized path is opened again by the implementation.
  trusted_script_source="$(cat "$trusted_root/scripts/safe-direct-merge.sh"; printf .)"
  trusted_script_source="${trusted_script_source%.}"
  trusted_collector_source="$(cat "$trusted_root/scripts/collect-pr-review-context.sh"; printf .)"
  trusted_collector_source="${trusted_collector_source%.}"
  trusted_policy_source="$(cat "$trusted_root/.agents/workflows/backlog-policy.json"; printf .)"
  trusted_policy_source="${trusted_policy_source%.}"
  if [ "$(printf '%s' "$trusted_script_source" | git hash-object --stdin)" \
       != "$trusted_script_blob" ] \
    || [ "$(printf '%s' "$trusted_collector_source" | git hash-object --stdin)" \
         != "$trusted_collector_blob" ] \
    || [ "$(printf '%s' "$trusted_policy_source" | git hash-object --stdin)" \
         != "$trusted_policy_blob" ]; then
    echo "safe-direct-merge.error=trusted-main-asset-changed-after-verification" >&2
    exit 2
  fi
  cleanup_trusted_root
  trap - EXIT
  trusted_root=""

  set +e
  RPM_SAFE_DIRECT_MERGE_STAGE=implementation \
    RPM_SAFE_DIRECT_MERGE_TRUSTED_SHA="$trusted_main_sha" \
    RPM_SAFE_DIRECT_MERGE_TRUSTED_CHECKOUT="$trusted_checkout" \
    RPM_SAFE_DIRECT_MERGE_REPO_ROOT="$repo_root" \
    RPM_SAFE_DIRECT_MERGE_POLICY_SOURCE="$trusted_policy_source" \
    RPM_SAFE_DIRECT_MERGE_COLLECTOR_SOURCE="$trusted_collector_source" \
    "$BASH" -c "$trusted_script_source" "$launcher_path" "${original_args[@]}"
  implementation_rc=$?
  set -e
  exit "$implementation_rc"
fi

if [ "$trusted_stage" != "implementation" ]; then
  echo "safe-direct-merge.error=invalid-trusted-stage" >&2
  exit 2
fi
trusted_main_sha="${RPM_SAFE_DIRECT_MERGE_TRUSTED_SHA:-}"
trusted_checkout="${RPM_SAFE_DIRECT_MERGE_TRUSTED_CHECKOUT:-}"
repo_root="${RPM_SAFE_DIRECT_MERGE_REPO_ROOT:-}"
policy_source="${RPM_SAFE_DIRECT_MERGE_POLICY_SOURCE:-}"
collector_source="${RPM_SAFE_DIRECT_MERGE_COLLECTOR_SOURCE:-}"
if [ -z "$trusted_checkout" ] || [ -z "$repo_root" ] \
  || [[ ! "$trusted_main_sha" =~ ^[[:xdigit:]]{40}$ ]] \
  || [ -z "$policy_source" ] || [ -z "$collector_source" ]; then
  echo "safe-direct-merge.error=invalid-trusted-materialization" >&2
  exit 2
fi
if ! configured_checkout="$(git -C "$repo_root" config --local --path --get rpm.safeDirectMergeTrustedCheckout 2>/dev/null)" \
  || [ "$(canonical_path "$configured_checkout")" != "$trusted_checkout" ] \
  || [ "$(git -C "$trusted_checkout" symbolic-ref --short HEAD 2>/dev/null || true)" != "main" ] \
  || [ "$(git -C "$trusted_checkout" rev-parse HEAD 2>/dev/null || true)" != "$trusted_main_sha" ] \
  || [ -n "$(git -C "$trusted_checkout" -c core.fsmonitor=false \
       status --porcelain --untracked-files=all 2>/dev/null || printf 'status-failed')" ] \
  || [ "$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)" \
       != "$(git -C "$trusted_checkout" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)" ]; then
  echo "safe-direct-merge.error=trusted-checkout-changed" >&2
  exit 2
fi
if ! origin_url="$(git -C "$trusted_checkout" config --local --get remote.origin.url 2>/dev/null)" \
  || ! repo="$(normalize_github_repo "$origin_url")" \
  || [ "$(gh api -X GET "repos/$repo/commits/main" --jq .sha 2>/dev/null || true)" != "$trusted_main_sha" ]; then
  echo "safe-direct-merge.error=trusted-main-changed" >&2
  exit 2
fi
if ! expected_script_blob="$(git -C "$trusted_checkout" rev-parse "$trusted_main_sha:scripts/safe-direct-merge.sh" 2>/dev/null)" \
  || ! expected_collector_blob="$(git -C "$trusted_checkout" rev-parse "$trusted_main_sha:scripts/collect-pr-review-context.sh" 2>/dev/null)" \
  || ! expected_policy_blob="$(git -C "$trusted_checkout" rev-parse "$trusted_main_sha:.agents/workflows/backlog-policy.json" 2>/dev/null)" \
  || [ "$(printf '%s' "${BASH_EXECUTION_STRING:-}" | git hash-object --stdin)" != "$expected_script_blob" ] \
  || [ "$(printf '%s' "$collector_source" | git hash-object --stdin)" != "$expected_collector_blob" ] \
  || [ "$(printf '%s' "$policy_source" | git hash-object --stdin)" != "$expected_policy_blob" ]; then
  echo "safe-direct-merge.error=materialized-asset-invalid" >&2
  exit 2
fi

dry_run=false
allow_findings=false
prs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) dry_run=true; shift ;;
    --allow-findings) allow_findings=true; shift ;;
    --*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) prs+=("$1"); shift ;;
  esac
done
if [ "${#prs[@]}" -eq 0 ]; then
  usage >&2
  exit 2
fi

if ! jq -e '
  (.merge_gate.required_checks | type == "array" and length > 0)
  and all(.merge_gate.required_checks[]; type == "string" and length > 0)
' <<<"$policy_source" >/dev/null 2>&1; then
  echo "safe-direct-merge.error=missing-required-checks" >&2
  exit 2
fi
required_checks=()
while IFS= read -r check; do
  [ -n "${check}" ] && required_checks+=("${check}")
done < <(jq -r '.merge_gate.required_checks[]?' <<<"$policy_source")

if [ "${#required_checks[@]}" -eq 0 ]; then
  echo "safe-direct-merge.error=missing-required-checks" >&2
  exit 2
fi

validate_merge_enforcement() {
  local protection active_rules ruleset_detail ruleset_id
  local required_checks_json
  required_checks_json="$(jq -cn --args '$ARGS.positional' "${required_checks[@]}")"

  # A successful `gh pr merge` can mean queue admission. This direct path has
  # no queue observer, so it must reject any applicable merge-queue rule and
  # prove the complete active-rule response before considering classic branch
  # protection or a ruleset sufficient.
  if ! active_rules="$(gh api --paginate -X GET \
    "repos/$repo/rules/branches/main?per_page=100" 2>/dev/null \
    | jq -cse 'if length > 0 and all(.[]; type == "array") then add else error("invalid pages") end')" \
    || ! jq -e 'type == "array" and (all(.[]; type == "object"))' \
      <<<"$active_rules" >/dev/null 2>&1; then
    echo "skip: unable to prove active branch rules; refusing to merge" >&2
    return 1
  fi
  if jq -e 'any(.[]; .type == "merge_queue")' <<<"$active_rules" >/dev/null 2>&1; then
    echo "skip: merge queue applies to main; direct merge cannot prove completion" >&2
    return 1
  fi

  if protection="$(gh api -X GET "repos/$repo/branches/main/protection" 2>/dev/null)"; then
    if jq -e --argjson required "$required_checks_json" '
      . as $protection |
      type == "object"
      and ($protection.required_status_checks.contexts | type == "array")
      and all($required[]; . as $required_check |
        any($protection.required_status_checks.contexts[]; . == $required_check))
      and ($protection.required_conversation_resolution.enabled == true)
      and ($protection.enforce_admins.enabled == true)
      and (($protection.required_pull_request_reviews.bypass_pull_request_allowances? // {}) as $bypass |
        all(["users", "teams", "apps"][]; . as $kind |
          (($bypass[$kind]? // []) | type == "array" and length == 0)))
    ' <<<"$protection" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # This endpoint returns flattened active rules. A single no-bypass ruleset
  # must carry both the required checks and conversation-resolution rule.
  while IFS= read -r ruleset_id; do
    [ -n "$ruleset_id" ] || continue
    if ruleset_detail="$(gh api -X GET "repos/$repo/rulesets/$ruleset_id" 2>/dev/null)" \
      && jq -e '
        type == "object"
        and (.enforcement == "active")
        and (.bypass_actors | type == "array" and length == 0)
      ' <<<"$ruleset_detail" >/dev/null 2>&1; then
      return 0
    fi
  done < <(jq -r --argjson required "$required_checks_json" '
    [ .[] | select((.ruleset_id | type) == "number") ]
    | group_by(.ruleset_id)[]
    | . as $rules
    | select(
        any($rules[];
          .type == "required_status_checks"
          and (.parameters.required_status_checks | type == "array")
          and (.parameters.required_status_checks as $checks |
            all($required[]; . as $required_check |
              any($checks[]; .context == $required_check))))
        and any($rules[];
          .type == "pull_request"
          and (.parameters.required_review_thread_resolution == true)))
    | .[0].ruleset_id
  ' <<<"$active_rules")
  echo "skip: main branch protection/ruleset enforcement is unavailable or ambiguous; refusing to merge" >&2
  return 1
}

validate_required_checks() {
  local pr="$1"
  local checks_json bucket
  local failed=() pending=()
  if ! checks_json="$(gh pr checks "$pr" --repo "$repo" --json name,bucket 2>/dev/null)"; then
    echo "skip: unable to inspect required checks"; return 1
  fi
  if ! printf '%s' "$checks_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "skip: required checks payload is invalid"; return 1
  fi
  for c in "${required_checks[@]}"; do
    bucket="$(printf '%s' "$checks_json" | jq -r --arg n "$c" '
      [.[]? | select(.name == $n) | .bucket // ""] as $buckets |
      if ($buckets | length) == 0 then
        "pending"
      elif any($buckets[]; . == "fail" or . == "failure" or . == "cancelled" or . == "timed_out" or . == "action_required") then
        "fail"
      elif all($buckets[]; . == "pass") then
        "pass"
      else
        "pending"
      end
    ')"
    case "$bucket" in
      pass) : ;;
      fail|failure|cancelled|timed_out|action_required) failed+=("$c=$bucket") ;;
      *) pending+=("$c=${bucket:-pending}") ;;
    esac
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    echo "skip: required checks failed: ${failed[*]}"; return 1
  fi
  if [ "${#pending[@]}" -gt 0 ]; then
    echo "skip: required checks pending: ${pending[*]} (retry shortly)"; return 1
  fi
}

validate_review_context() {
  local pr="$1"
  local review_context unresolved
  if ! review_context="$(GH_REPO="$repo" "$BASH" -c "$collector_source" \
    collect-pr-review-context.sh --format json "$pr")"; then
    echo "skip: review context collection failed; refusing to merge"; return 1
  fi
  if ! jq -e --argjson number "$pr" --arg expected_url "https://github.com/$repo/pull/$pr" \
    'type == "object"
     and (.pullRequest | type == "object")
     and (.pullRequest.number == $number)
     and ((.pullRequest.url | type == "string")
          and ((.pullRequest.url | sub("/$"; "") | ascii_downcase)
               == ($expected_url | ascii_downcase)))
     and (.reviewThreads | type == "array")' \
    <<<"$review_context" >/dev/null 2>&1; then
    echo "skip: review context payload is invalid (identity or shape); refusing to merge"; return 1
  fi
  if ! unresolved="$(jq -er '[.reviewThreads[] | select(.isResolved != true)] | length' \
    <<<"$review_context")"; then
    echo "skip: review context reviewThreads could not be parsed; refusing to merge"; return 1
  fi
  if [ "${unresolved:-0}" -gt 0 ] && [ "$allow_findings" = "false" ]; then
    echo "skip: $unresolved unresolved review thread(s); pass --allow-findings to override"
    return 1
  fi
}

validate_expected_head() {
  local pr="$1" expected_head="$2" current_head
  if ! current_head="$(gh pr view "$pr" --repo "$repo" --json headRefOid -q .headRefOid)" \
    || [[ ! "$current_head" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "skip: unable to recheck PR head revision; refusing to merge"
    return 1
  fi
  if [ "$current_head" != "$expected_head" ]; then
    echo "skip: PR head revision changed from $expected_head to $current_head; refusing to merge"
    return 1
  fi
}

validate_completed_merge() {
  local pr="$1" expected_head="$2" merged_json
  if ! merged_json="$(gh pr view "$pr" --repo "$repo" \
    --json number,url,state,headRefOid)"; then
    echo "FAIL: merge command returned success but PR state could not be verified"
    return 1
  fi
  if ! jq -e --argjson number "$pr" --arg expected_url "https://github.com/$repo/pull/$pr" \
    --arg expected_head "$expected_head" '
      type == "object"
      and (.number == $number)
      and ((.url | type == "string")
           and ((.url | sub("/$"; "") | ascii_downcase)
                == ($expected_url | ascii_downcase)))
      and (.state == "MERGED")
      and (.headRefOid == $expected_head)
    ' <<<"$merged_json" >/dev/null 2>&1; then
    echo "FAIL: merge command did not prove the expected PR reached MERGED state"
    return 1
  fi
}

delete_remote_branch() {
  local branch="$1" encoded_ref delete_output delete_rc http_status
  if ! encoded_ref="$(jq -rn --arg ref "heads/$branch" '$ref | @uri')" \
    || [ -z "$encoded_ref" ]; then
    echo "FAIL: unable to encode remote branch ref $branch"
    return 1
  fi
  set +e
  delete_output="$(gh api --include -X DELETE \
    "repos/$repo/git/refs/$encoded_ref" 2>&1)"
  delete_rc=$?
  set -e
  if [ "$delete_rc" -eq 0 ]; then
    echo "deleted remote branch $branch"
    return 0
  fi
  http_status="$(printf '%s\n' "$delete_output" \
    | sed -nE 's/^HTTP\/[^ ]+ ([0-9]{3}).*/\1/p' | tail -n 1)"
  if [ "$http_status" = "404" ]; then
    echo "remote branch $branch is already absent"
    return 0
  fi
  echo "FAIL: unable to delete remote branch $branch (http=${http_status:-unknown})"
  return 1
}

delete_matching_local_branch() {
  local branch="$1" expected_head="$2" checked_out="$3"
  local local_ref="refs/heads/$branch" local_oid show_ref_rc
  set +e
  local_oid="$(git show-ref --verify --hash "$local_ref" 2>/dev/null)"
  show_ref_rc=$?
  set -e
  if [ "$show_ref_rc" -eq 1 ]; then
    return 0
  fi
  if [ "$show_ref_rc" -ne 0 ]; then
    echo "FAIL: unable to inspect local branch $branch"
    return 1
  fi
  if [ "$checked_out" = "true" ]; then
    echo "note: retained checked-out local branch $branch"
    return 0
  fi
  if [ "$local_oid" != "$expected_head" ]; then
    echo "note: retained divergent local branch $branch at $local_oid"
    return 0
  fi
  if ! git -c core.hooksPath=/dev/null update-ref -d "$local_ref" "$expected_head"; then
    echo "FAIL: unable to delete matching local branch $branch"
    return 1
  fi
  echo "deleted matching local branch $branch"
}

merge_one() {
  local pr="$1"
  echo "=== PR #$pr ==="

  local pr_json state draft mergeable merge_state branch base_branch cross_repository head_oid
  if ! pr_json="$(gh pr view "$pr" --repo "$repo" \
    --json number,url,state,isDraft,mergeable,mergeStateStatus,baseRefName,headRefName,isCrossRepository,headRefOid)"; then
    echo "skip: unable to read PR metadata; refusing to merge"; return 1
  fi
  if ! jq -e --argjson number "$pr" --arg expected_url "https://github.com/$repo/pull/$pr" '
    type == "object"
    and (.number | type == "number") and (.number == $number)
    and (.url | type == "string")
    and ((.url | ascii_downcase) == ($expected_url | ascii_downcase))
    and (.state | type == "string")
    and (.isDraft | type == "boolean")
    and (.mergeable | type == "string")
    and (.mergeStateStatus | type == "string")
    and (.baseRefName | type == "string") and (.baseRefName | length > 0)
    and (.headRefName | type == "string") and (.headRefName | length > 0)
    and (.isCrossRepository | type == "boolean")
    and (.headRefOid | type == "string")
    and (.headRefOid | test("^[0-9a-fA-F]{40}$"))
  ' <<<"$pr_json" >/dev/null 2>&1; then
    echo "skip: PR metadata shape or identity is invalid; refusing to merge"; return 1
  fi
  state="$(jq -er .state <<<"$pr_json")"
  draft="$(jq -er .isDraft <<<"$pr_json")"
  mergeable="$(jq -er .mergeable <<<"$pr_json")"
  merge_state="$(jq -er .mergeStateStatus <<<"$pr_json")"
  base_branch="$(jq -er .baseRefName <<<"$pr_json")"
  branch="$(jq -er .headRefName <<<"$pr_json")"
  cross_repository="$(jq -er .isCrossRepository <<<"$pr_json")"
  head_oid="$(jq -er .headRefOid <<<"$pr_json")"

  if [ "$state" != "OPEN" ]; then
    echo "skip: state=$state (not OPEN)"; return 1
  fi
  if [ "$draft" = "true" ]; then
    echo "skip: draft PR"; return 1
  fi
  if [ "$mergeable" != "MERGEABLE" ]; then
    echo "skip: mergeable=$mergeable"; return 1
  fi
  if [ "$merge_state" != "CLEAN" ]; then
    echo "skip: mergeState=$merge_state (resolve conflicts/blocking reviews first)"; return 1
  fi
  if [ "$cross_repository" != "false" ]; then
    echo "skip: cross-repository PRs are not eligible for safe direct merge"; return 1
  fi
  if [ "$base_branch" != "main" ]; then
    echo "skip: base branch $base_branch is not protected main; refusing to merge"; return 1
  fi

  if ! validate_merge_enforcement; then
    return 1
  fi
  if ! validate_required_checks "$pr"; then
    return 1
  fi
  if ! validate_review_context "$pr"; then
    return 1
  fi

  # Check every matching worktree before removing any of them. A dirty
  # worktree may contain user changes, so it is never deleted implicitly.
  local wt wt_branch wt_status worktree_inventory primary_worktree
  local branch_checked_out=false
  if ! worktree_inventory="$(git worktree list --porcelain 2>/dev/null)"; then
    echo "skip: unable to inventory git worktrees; refusing to merge"; return 1
  fi
  if [ -z "$worktree_inventory" ]; then
    echo "skip: worktree inventory is empty; refusing to merge"; return 1
  fi
  primary_worktree="$(printf '%s\n' "$worktree_inventory" | sed -n 's/^worktree //p' | sed -n '1p')"
  if [ -z "$primary_worktree" ]; then
    echo "skip: worktree inventory has no primary checkout; refusing to merge"; return 1
  fi
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    if ! wt_branch="$(git -C "$wt" branch --show-current 2>/dev/null)"; then
      echo "skip: unable to inspect branch for worktree $wt; refusing to merge"; return 1
    fi
    if [ "$wt_branch" = "$branch" ]; then
      branch_checked_out=true
      if ! wt_status="$(git -C "$wt" -c core.fsmonitor=false \
        status --ignored --porcelain --untracked-files=all 2>/dev/null)"; then
        echo "skip: unable to inspect worktree $wt; refusing to merge"; return 1
      fi
      if [ -n "$wt_status" ]; then
        echo "skip: dirty worktree $wt holds $branch; refusing to remove or merge"; return 1
      fi
      if [ "$wt" != "$primary_worktree" ] && [ "$wt" != "$repo_root" ]; then
        echo "skip: linked worktree $wt holds $branch; remove it manually and retry"; return 1
      fi
    fi
  done < <(printf '%s\n' "$worktree_inventory" | sed -n 's/^worktree //p')

  # Re-run mutable remote gates immediately before the head check. A later
  # failing check or newly opened review thread must prevent cleanup.
  if ! validate_required_checks "$pr"; then
    return 1
  fi
  if ! validate_review_context "$pr"; then
    return 1
  fi
  if ! validate_merge_enforcement; then
    return 1
  fi

  # GitHub enforces the same checks and conversation resolution at merge
  # time. The expected head pin is an independent API boundary.
  if ! validate_expected_head "$pr" "$head_oid"; then
    return 1
  fi

  echo "OK: branch=$branch mergeable=$mergeable mergeState=$merge_state checks=green"

  if [ "$dry_run" = "true" ]; then
    echo "(dry-run) would squash-merge and delete branch $branch"
    return 0
  fi

  # Re-run every local observation at the final merge boundary while relying
  # on the verified GitHub rule for transactional enforcement.
  if ! validate_merge_enforcement \
    || ! validate_required_checks "$pr" \
    || ! validate_review_context "$pr" \
    || ! validate_expected_head "$pr" "$head_oid"; then
    return 1
  fi

  # Squash merge (non-interactive). No --delete-branch: cleanup uses the
  # repository-pinned GitHub API endpoint below.
  if ! gh pr merge "$pr" --repo "$repo" --squash --match-head-commit "$head_oid" < /dev/null; then
    echo "FAIL: gh pr merge returned non-zero"; return 1
  fi

  # A successful CLI call may mean queue admission. Prove completion before
  # deleting any ref, then use the repository-pinned and percent-encoded API
  # endpoint so remote.origin.pushurl and URL fragments cannot redirect it.
  if ! validate_completed_merge "$pr" "$head_oid"; then
    return 1
  fi
  if ! delete_remote_branch "$branch"; then
    echo "FAIL: PR #$pr merged but remote branch cleanup is incomplete"
    return 1
  fi
  # Delete only an unreferenced local ref that still equals the merged head.
  # Checked-out or divergent refs may contain local work and are retained.
  if ! delete_matching_local_branch "$branch" "$head_oid" "$branch_checked_out"; then
    echo "FAIL: PR #$pr merged but local branch cleanup is incomplete"
    return 1
  fi

  echo "merged #$pr"
}

rc=0
for pr in "${prs[@]}"; do
  normalized_pr_ref="${pr,,}"
  if [[ "$normalized_pr_ref" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)(/.*)?$ ]]; then
    requested_repo="${BASH_REMATCH[1],,}/${BASH_REMATCH[2],,}"
    if [ "$requested_repo" != "$repo" ]; then
      echo "skip: PR URL repository $requested_repo does not match current origin $repo" >&2
      rc=1
      continue
    fi
    pr="${BASH_REMATCH[3]}"
  elif ! [[ "$pr" =~ ^[0-9]+$ ]]; then
    echo "skip: invalid PR reference $pr" >&2
    rc=1
    continue
  fi
  merge_one "$pr" || rc=1
done

exit "$rc"
