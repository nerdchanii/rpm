#!/usr/bin/env bash
set -euo pipefail

status="ok"
format="jsonl"
skill_validator="${RPM_SKILL_VALIDATOR:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --format)
      [ "$#" -ge 2 ] || {
        printf 'agent_assets.error=missing-format-value\n' >&2
        exit 2
      }
      format="$2"
      shift 2
      ;;
    --format=*)
      format="${1#--format=}"
      shift
      ;;
    *)
      printf 'agent_assets.error=unknown-argument:%s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ "${format}" != "jsonl" ] && [ "${format}" != "text" ] && [ "${format}" != "summary" ]; then
  printf 'agent_assets.error=invalid-format:%s\n' "${format}" >&2
  exit 2
fi

if [ -z "${skill_validator}" ] && [ -n "${HOME:-}" ]; then
  candidate="${HOME}/.codex/skills/.system/skill-creator/scripts/quick_validate.py"
  if [ -f "${candidate}" ]; then
    skill_validator="${candidate}"
  fi
fi

emit_check() {
  local name="$1"
  local result="$2"
  local output="${3:-}"
  if [ "${format}" = "jsonl" ]; then
    jq -nc \
      --arg name "${name}" \
      --arg status "${result}" \
      --arg output "${output}" \
      '{type:"agent_asset_check",data:{name:$name,status:$status,output:(if $output == "" then null else $output end)}}'
  elif [ "${format}" = "text" ] || [ "${result}" != "ok" ]; then
    printf 'agent_assets.%s=%s\n' "${name}" "${result}"
    if [ -n "${output}" ]; then
      printf 'agent_assets.%s.output.begin\n%s\nagent_assets.%s.output.end\n' \
        "${name}" "${output}" "${name}"
    fi
  fi
}

check() {
  local name="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    emit_check "${name}" "ok"
  else
    status="fail"
    emit_check "${name}" "fail" "${output}"
  fi
}

with_fake_collect_gh() {
  local fixture="$1"
  shift
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-collect-gh.XXXXXX")"
  trap 'rm -rf "${temp_dir}"' RETURN
  cat >"${temp_dir}/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  printf 'owner/repo\n'
  exit 0
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
  count_file="${RPM_COLLECT_FIXTURE}/.count"
  count=0
  if [ -f "${count_file}" ]; then
    count="$(cat "${count_file}")"
  fi
  count=$((count + 1))
  printf '%s\n' "${count}" >"${count_file}"
  if [ -f "${RPM_COLLECT_FIXTURE}/page-${count}.json" ]; then
    cat "${RPM_COLLECT_FIXTURE}/page-${count}.json"
    exit 0
  fi
  cat "${RPM_COLLECT_FIXTURE}/page-last.json"
  exit 0
fi

printf 'unexpected gh call: %s\n' "$*" >&2
exit 99
GH
  chmod +x "${temp_dir}/gh"
  PATH="${temp_dir}:${PATH}" RPM_COLLECT_FIXTURE="${fixture}" "$@"
}

check_collect_paginates_comments_and_reviews() {
  local fixture_dir
  fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-collect-paginated.XXXXXX")"
  trap 'rm -rf "${fixture_dir}"' RETURN

  jq -n '
    {
      data: {
        repository: {
          pullRequest: {
            number: 1,
            title: "Fixture PR",
            url: "https://example.test/pr/1",
            state: "OPEN",
            isDraft: false,
            comments: {
              pageInfo: {hasNextPage: true, endCursor: "comment-100"},
              nodes: [
                range(0; 100) as $i |
                {
                  author: {login: "octocat"},
                  createdAt: "2025-12-31T23:59:59Z",
                  body: ("old comment " + ($i | tostring)),
                  url: ("https://example.test/comment/" + ($i | tostring))
                }
              ]
            },
            reviews: {
              pageInfo: {hasNextPage: true, endCursor: "review-100"},
              nodes: [
                range(0; 100) as $i |
                {
                  author: {login: "octocat"},
                  submittedAt: "2025-12-31T23:59:59Z",
                  state: "COMMENTED",
                  body: ("old review " + ($i | tostring)),
                  url: ("https://example.test/review/" + ($i | tostring))
                }
              ]
            },
            reviewThreads: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: []
            }
          }
        }
      }
    }
  ' >"${fixture_dir}/page-1.json"

  jq -n '
    {
      data: {
        repository: {
          pullRequest: {
            number: 1,
            title: "Fixture PR",
            url: "https://example.test/pr/1",
            state: "OPEN",
            isDraft: false,
            comments: {
              pageInfo: {hasNextPage: false, endCursor: "comment-101"},
              nodes: [
                {
                  author: {login: "chatgpt-codex-connector"},
                  createdAt: "2026-01-01T00:00:01Z",
                  body: "latest issue comment",
                  url: "https://example.test/comment/latest"
                }
              ]
            },
            reviews: {
              pageInfo: {hasNextPage: false, endCursor: "review-101"},
              nodes: [
                {
                  author: {login: "chatgpt-codex-connector"},
                  submittedAt: "2026-01-01T00:00:02Z",
                  state: "COMMENTED",
                  body: "latest review",
                  url: "https://example.test/review/latest"
                }
              ]
            },
            reviewThreads: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: []
            }
          }
        }
      }
    }
  ' >"${fixture_dir}/page-2.json"
  cp "${fixture_dir}/page-2.json" "${fixture_dir}/page-last.json"

  local output
  output="$(
    with_fake_collect_gh \
      "${fixture_dir}" \
      bash scripts/collect-pr-review-context.sh 1 --format json 2>&1
  )"
  printf '%s\n' "${output}" | jq -e '
    (.issueComments | length) == 101
    and (.reviews | length) == 101
    and any(.issueComments[]; .body == "latest issue comment")
    and any(.reviews[]; .body == "latest review")
  ' >/dev/null
}

check_collect_does_not_duplicate_exhausted_connections() {
  local fixture_dir
  fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-collect-asymmetric.XXXXXX")"
  trap 'rm -rf "${fixture_dir}"' RETURN

  jq -n '
    {
      data: {
        repository: {
          pullRequest: {
            number: 1,
            title: "Fixture PR",
            url: "https://example.test/pr/1",
            state: "OPEN",
            isDraft: false,
            comments: {
              pageInfo: {hasNextPage: false, endCursor: "comment-only"},
              nodes: [
                {
                  author: {login: "octocat"},
                  createdAt: "2026-01-01T00:00:01Z",
                  body: "single issue comment",
                  url: "https://example.test/comment/only"
                }
              ]
            },
            reviews: {
              pageInfo: {hasNextPage: true, endCursor: "review-1"},
              nodes: [
                {
                  author: {login: "octocat"},
                  submittedAt: "2026-01-01T00:00:02Z",
                  state: "COMMENTED",
                  body: "review page 1",
                  url: "https://example.test/review/1"
                }
              ]
            },
            reviewThreads: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: []
            }
          }
        }
      }
    }
  ' >"${fixture_dir}/page-1.json"

  jq -n '
    {
      data: {
        repository: {
          pullRequest: {
            number: 1,
            title: "Fixture PR",
            url: "https://example.test/pr/1",
            state: "OPEN",
            isDraft: false,
            comments: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: [
                {
                  author: {login: "octocat"},
                  createdAt: "2026-01-01T00:00:01Z",
                  body: "single issue comment",
                  url: "https://example.test/comment/only"
                }
              ]
            },
            reviews: {
              pageInfo: {hasNextPage: true, endCursor: "review-2"},
              nodes: [
                {
                  author: {login: "octocat"},
                  submittedAt: "2026-01-01T00:00:03Z",
                  state: "COMMENTED",
                  body: "review page 2",
                  url: "https://example.test/review/2"
                }
              ]
            },
            reviewThreads: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: []
            }
          }
        }
      }
    }
  ' >"${fixture_dir}/page-2.json"

  jq -n '
    {
      data: {
        repository: {
          pullRequest: {
            number: 1,
            title: "Fixture PR",
            url: "https://example.test/pr/1",
            state: "OPEN",
            isDraft: false,
            comments: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: [
                {
                  author: {login: "octocat"},
                  createdAt: "2026-01-01T00:00:01Z",
                  body: "single issue comment",
                  url: "https://example.test/comment/only"
                }
              ]
            },
            reviews: {
              pageInfo: {hasNextPage: false, endCursor: "review-3"},
              nodes: [
                {
                  author: {login: "octocat"},
                  submittedAt: "2026-01-01T00:00:04Z",
                  state: "COMMENTED",
                  body: "review page 3",
                  url: "https://example.test/review/3"
                }
              ]
            },
            reviewThreads: {
              pageInfo: {hasNextPage: false, endCursor: null},
              nodes: []
            }
          }
        }
      }
    }
  ' >"${fixture_dir}/page-3.json"
  cp "${fixture_dir}/page-3.json" "${fixture_dir}/page-last.json"

  local output
  output="$(
    with_fake_collect_gh \
      "${fixture_dir}" \
      bash scripts/collect-pr-review-context.sh 1 --format json 2>&1
  )"
  printf '%s\n' "${output}" | jq -e '
    ([.issueComments[] | select(.body == "single issue comment")] | length) == 1
    and (.issueComments | length) == 1
    and (.reviews | length) == 3
    and ([.reviews[].body] == ["review page 1", "review page 2", "review page 3"])
  ' >/dev/null
}

check_readiness_ready() {
  local output
  output="$(
    python3 scripts/check-agent-issue-readiness.py \
      --body-file .agents/fixtures/backlog/readiness-ready.md \
      --format jsonl
  )"
  printf '%s\n' "${output}" | jq -e '
    .type == "issue_readiness_result"
    and .data.status == "ready"
    and .data.ready == true
    and (.data.missing_sections | length) == 0
    and (.data.unresolved_decisions | length) == 0
    and .data.execution_error == null
    and .data.execution_metadata.executor == "cloud"
  ' >/dev/null
}

check_readiness_missing_execution() {
  local output
  local exit_code
  set +e
  output="$(
    python3 scripts/check-agent-issue-readiness.py \
      --body-file .agents/fixtures/backlog/readiness-missing-execution.md \
      --format jsonl
  )"
  exit_code=$?
  set -e
  [ "${exit_code}" -eq 1 ] || {
    printf 'expected readiness exit 1, got %s\n%s\n' "${exit_code}" "${output}"
    return 1
  }
  printf '%s\n' "${output}" | jq -e '
    .data.ready == false
    and .data.execution_error == "missing-execution-metadata"
  ' >/dev/null
}

check_readiness_missing() {
  local output
  local exit_code
  set +e
  output="$(
    python3 scripts/check-agent-issue-readiness.py \
      --body-file .agents/fixtures/backlog/readiness-missing.md \
      --format json
  )"
  exit_code=$?
  set -e
  [ "${exit_code}" -eq 1 ] || {
    printf 'expected readiness exit 1, got %s\n%s\n' "${exit_code}" "${output}"
    return 1
  }
  printf '%s\n' "${output}" | jq -e '
    .data.status == "needs-refinement"
    and .data.ready == false
    and (.data.missing_sections | index("Contract")) != null
    and (.data.missing_sections | index("Done criteria")) != null
  ' >/dev/null
}

check_readiness_unresolved() {
  local output
  local exit_code
  set +e
  output="$(
    python3 scripts/check-agent-issue-readiness.py \
      --body-file .agents/fixtures/backlog/readiness-unresolved.md \
      --format jsonl
  )"
  exit_code=$?
  set -e
  [ "${exit_code}" -eq 1 ] || {
    printf 'expected readiness exit 1, got %s\n%s\n' "${exit_code}" "${output}"
    return 1
  }
  printf '%s\n' "${output}" | jq -e '
    .data.ready == false
    and any(.data.unresolved_decisions[]; .reason == "contract-tbd")
    and any(.data.unresolved_decisions[]; .reason == "unchecked-decision")
  ' >/dev/null
}

check_readiness_live_issue() {
  local temp_dir
  local output
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-readiness-gh.XXXXXX")"
  trap 'rm -rf "${temp_dir}"' RETURN
  cp .agents/fixtures/backlog/fake-gh "${temp_dir}/gh"
  chmod +x "${temp_dir}/gh"
  output="$(
    PATH="${temp_dir}:${PATH}" \
      RPM_READINESS_FIXTURE=".agents/fixtures/backlog/live-issue.json" \
      python3 scripts/check-agent-issue-readiness.py --issue 3 --format jsonl
  )"
  printf '%s\n' "${output}" | jq -e '
    .data.status == "ready"
    and .data.source.kind == "live-issue"
    and .data.source.number == 3
    and .data.source.labels == ["agent:research"]
  ' >/dev/null
}

check_execution_metadata_generator() {
  local output
  output="$(
    python3 scripts/create-execution-metadata.py \
      --issue 42 \
      --body-file .agents/fixtures/backlog/readiness-ready.md \
      --executor cloud \
      --format jsonl
  )"
  printf '%s\n' "${output}" | jq -e '
    .type == "execution_metadata_result"
    and .data.issue == 42
    and .data.metadata.executor == "cloud"
    and (.data.metadata.scope_hash | test("^sha256:[0-9a-f]{64}$"))
    and (.data.marker | contains("rpm-agent-execution"))
  ' >/dev/null
}

with_fake_backlog_gh() {
  local state_arg="$1"
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-backlog-gh.XXXXXX")"
  trap 'rm -rf "${temp_dir}"' RETURN
  cp .agents/fixtures/backlog/fake-gh "${temp_dir}/gh"
  chmod +x "${temp_dir}/gh"
  PATH="${temp_dir}:${PATH}" \
    RPM_BACKLOG_FIXTURE=".agents/fixtures/backlog/project-items.json" \
    bash scripts/backlog-gen --state "${state_arg}" --format jsonl
}

check_backlog_research_batch() {
  local output
  output="$(with_fake_backlog_gh research)"
  printf '%s\n' "${output}" | jq -e '
    .type == "backlog_selection"
    and .data.status == "selected"
    and .data.project.number == 7
    and .data.batch_limit == 1
    and .data.count == 1
    and [.data.issues[].number] == [3]
  ' >/dev/null
}

check_backlog_no_work() {
  local output
  output="$(with_fake_backlog_gh blocked)"
  printf '%s\n' "${output}" | jq -e '
    .data.status == "no-work"
    and .data.count == 0
    and .data.issues == []
  ' >/dev/null
}

check_backlog_inventory_order() {
  local output
  output="$(with_fake_backlog_gh all)"
  printf '%s\n' "${output}" | jq -e '
    .data.status == "selected"
    and [.data.issues[].number] == [3, 7, 9]
    and [.data.issues[].state] == ["research", "research", "ready"]
  ' >/dev/null
}

check_backlog_access_preflight() {
  local temp_dir
  local output
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-backlog-access-gh.XXXXXX")"
  trap 'rm -rf "${temp_dir}"' RETURN
  cp .agents/fixtures/backlog/fake-gh "${temp_dir}/gh"
  chmod +x "${temp_dir}/gh"
  output="$(
    PATH="${temp_dir}:${PATH}" \
      RPM_BACKLOG_FIXTURE=".agents/fixtures/backlog/project-items.json" \
      bash scripts/check-agent-backlog-access.sh --format jsonl
  )"
  printf '%s\n' "${output}" | jq -s -e '
    length == 5
    and ([.[] | select(.type == "backlog_access_check" and .data.status == "ok")] | length) == 4
    and .[-1].type == "backlog_access_result"
    and .[-1].data.status == "ok"
    and .[-1].data.repository == "nerdchanii/rpm"
    and .[-1].data.project == 7
  ' >/dev/null
}

for skill in .agents/skills/*; do
  [ -d "${skill}" ] || continue
  name="$(basename "${skill}")"
  if [ "${name}" = "take-ticket" ] || [ "${name}" = "prepare-backlog" ] || [ "${name}" = "merge-gatekeeper" ] \
    || [ "${name}" = "open-pr-review-batch" ] || [ "${name}" = "pr-resolution-loop" ] \
    || [ "${name}" = "pr-review-resolution" ] || [ "${name}" = "safe-direct-merge" ] \
    || [ "${name}" = "rpm-worktree-orchestrator" ]; then
    emit_check \
      "skill_${name}" \
      "ok" \
      "hidden entry flags and routing are validated by check-agent-organization.py"
  elif [ -n "${skill_validator}" ]; then
    check "skill_${name}" python3 "${skill_validator}" "${skill}"
  else
    emit_check \
      "skill_${name}" \
      "skip" \
      "skill validator not found; set RPM_SKILL_VALIDATOR to enable this check"
  fi
done

if [ -d .codex/agents ]; then
  for agent in .codex/agents/*.toml; do
    [ -f "${agent}" ] || continue
    name="$(basename "${agent}" .toml)"
    check "agent_${name}_toml" \
      python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "${agent}"
  done
fi

check "backlog_policy_schema" jq -e '
  .version == 3
  and .repository == "nerdchanii/rpm"
  and .execution_queue == {
    source:"issue-labels",
    open_issues_only:true,
    order:"issue-number-ascending",
    active_states:["claimed","review-pending"]
  }
  and .project.number == 7
  and .project.role == "local-roadmap"
  and .project.required_for_execution == false
  and .labels == {
    research:"agent:research",
    ready:"agent:ready",
    claimed:"agent:claimed",
    "review-pending":"agent:review-pending",
    "awaiting-merge":"agent:awaiting-merge",
    blocked:"agent:blocked"
  }
  and .execution_contract == {
    approved_metadata:["approval_id","plan_revision","scope_hash","executor"],
    executor_values:["local","cloud"],
    active_states:["claimed","review-pending"],
    lease:{
      field:"lease",
      required_fields:["run_id","owner","expires_at"],
      ttl_seconds:3600
    },
    idempotency:{
      ledger_field:"runs",
      key_fields:["repository","issue","plan_revision","scope_hash","event_id"],
      algorithm:"sha256-nul-joined"
    }
  }
  and .batch_limits == {research:1,execution:1}
  and .allowed_transitions == {
    untracked:["research"],
    research:["research","ready","blocked"],
    ready:["claimed","blocked"],
    claimed:["ready","review-pending","blocked"],
    "review-pending":["review-pending","awaiting-merge","blocked"],
    "awaiting-merge":["blocked"],
    blocked:["research","ready"]
  }
  and .automation == {
    create_followup_issues_by_default:false,
    merge_pull_requests:false,
    request_codex_review:false
  }
  and .merge_gate == {
    enabled:true,
    source_state:"awaiting-merge",
    order:"issue-number-ascending",
    batch_limit:1,
    required_checks:["metadata","verify"],
    required_mergeable:true,
    forbid_unresolved_p0_p1:true,
    method:"squash",
    delete_branch:true
  }
' .agents/workflows/backlog-policy.json

check "agent_organization" python3 scripts/check-agent-organization.py
check "agent_hooks_json" jq -e . .codex/hooks.json
check "claude_security" bash scripts/check-claude-security.sh

for hook in .codex/hooks/agent_tool_policy.py .codex/hooks/issue_manager_stop_gate.py; do
  name="$(basename "${hook}" .py)"
  check "hook_${name}_syntax" \
    python3 -c 'import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' "${hook}"
done

for script in \
  scripts/backlog-gen \
  scripts/check-agent-backlog-access.sh \
  scripts/collect-pr-review-context.sh \
  scripts/create-review-followup-issue.sh \
  scripts/ticket-gen
do
  [ -f "${script}" ] || continue
  name="$(basename "${script}")"
  check "script_${name}_syntax" bash -n "${script}"
done

check "script_check_agent_issue_readiness_syntax" \
  python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/check-agent-issue-readiness.py").read_text())'
check "script_create_execution_metadata_syntax" \
  python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/create-execution-metadata.py").read_text())'
check "script_apply_execution_marker_syntax" \
  python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/apply-execution-marker.py").read_text())'
check "script_execution_contract_syntax" \
  python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/execution_contract.py").read_text())'
check "script_check_agent_organization_syntax" \
  python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/check-agent-organization.py").read_text())'
check "script_check_cloud_queue_contract_syntax" \
  python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/check-cloud-queue-contract.py").read_text())'
check "script_check_merge_gate_syntax" \
  python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/check-merge-gate.py").read_text())'
check "script_check_claude_security_syntax" \
  bash -n scripts/check-claude-security.sh
check "script_validate_agent_workflow_assets_syntax" \
  bash -n scripts/validate-agent-workflow-assets.sh

check "collect_pr_review_context_paginates" check_collect_paginates_comments_and_reviews
check "collect_pr_review_context_no_duplicates" check_collect_does_not_duplicate_exhausted_connections
check "readiness_ready_fixture" check_readiness_ready
check "readiness_missing_execution_fixture" check_readiness_missing_execution
check "readiness_missing_fixture" check_readiness_missing
check "readiness_unresolved_fixture" check_readiness_unresolved
check "readiness_live_issue_fixture" check_readiness_live_issue
check "execution_metadata_generator" check_execution_metadata_generator
check "execution_marker_regression" \
  env PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_apply_execution_marker.py
check "execution_metadata_regression" \
  env PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_create_execution_metadata.py
check "worktree_plan_regression" \
  env PYTHONDONTWRITEBYTECODE=1 \
    python3 .agents/skills/rpm-worktree-orchestrator/scripts/test_validate_plan.py
check "backlog_research_batch" check_backlog_research_batch
check "backlog_no_work" check_backlog_no_work
check "backlog_inventory_order" check_backlog_inventory_order
check "backlog_access_preflight" check_backlog_access_preflight

check "cloud_label_only_selection" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-issues.json \
    --operation select-execution)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"selected\"
    and .data.issues == [3]
  " >/dev/null
'
check "cloud_claim_contract" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-ready.json \
    --operation claim --issue 3 --run-id run-3 --event-id delivery-3 \
    --executor cloud --plan-revision plan-3 \
    --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --lease-owner cloud:executor)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"claim\"
    and .data.issue == 3
    and .data.before == \"ready\"
    and .data.after == \"claimed\"
    and .data.before_open == true
    and .data.expected_issue_state == \"OPEN\"
    and .data.expected_closing_prs == []
    and .data.lease.run_id == \"run-3\"
    and .data.lease.owner == \"cloud:executor\"
    and .data.lease.expires_at == \"2026-08-21T13:00:00Z\"
    and .data.run.run_id == \"run-3\"
    and .data.run.event_id == \"delivery-3\"
    and .data.run.idempotency_key == .data.idempotency_key
    and .data.expected_labels == [\"agent:ready\",\"priority:high\"]
    and (.data.execution_marker | contains(\"rpm-agent-execution\"))
    and (.data.execution_marker | contains(\"\\\"lease\\\"\"))
    and .data.execution.runs[0].status == \"active\"
    and .data.preserved_labels == [\"priority:high\"]
    and .data.labels == [\"agent:claimed\",\"priority:high\"]
  " >/dev/null
'
check "cloud_claim_recovery_active_lease_no_work" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-recovered-ready.json \
    --operation claim --issue 15 --run-id run-new --event-id delivery-new \
    --executor cloud --plan-revision plan-15 \
    --scope-hash sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
    --lease-owner cloud:executor)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"no-work\"
    and .data.reason == \"lease-active\"
  " >/dev/null
'
check "cloud_claim_preserves_prior_runs" sh -c '
  old_key="sha256:0ebb451daf89062a9f7314eec90cb39f62d5aae73bcdf47f7dd89e2e70f74cb1"
  first_fixture="$(mktemp "${TMPDIR:-/tmp}/rpm-claim-ledger.XXXXXX")"
  second_fixture="$(mktemp "${TMPDIR:-/tmp}/rpm-claim-ledger.XXXXXX")"
  trap "rm -f \"${first_fixture}\" \"${second_fixture}\"" EXIT
  jq --arg key "${old_key}" \
    ".runs_by_issue = {\"3\": [{run_id:\"run-3\",event_id:\"delivery-3\",idempotency_key:\$key,status:\"active\"}]}" \
    .agents/fixtures/backlog/cloud-claim-ready.json >"${first_fixture}"
  first_output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file "${first_fixture}" \
    --operation claim --issue 3 --run-id run-new --event-id delivery-new \
    --executor cloud --plan-revision plan-3 \
    --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --lease-owner cloud:executor)"
  printf "%s\n" "${first_output}" | jq -e \
    ".data.status == \"claim\" and (.data.execution.runs | length) == 2 and .data.execution.runs[0].idempotency_key == \"${old_key}\"" >/dev/null
  jq --argjson runs "$(printf "%s\n" "${first_output}" | jq -c .data.execution.runs)" ".runs_by_issue = {\"3\": \$runs}" "${first_fixture}" >"${second_fixture}"
  old_output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file "${second_fixture}" \
    --operation claim --issue 3 --run-id run-3 --event-id delivery-3 \
    --executor cloud --plan-revision plan-3 \
    --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --lease-owner cloud:executor)"
  printf "%s\n" "${old_output}" | jq -e ".data.status == \"no-work\" and .data.reason == \"duplicate-event\"" >/dev/null
'
check "cloud_claim_ignores_unrelated_runs" sh -c '
  fixture="$(mktemp "${TMPDIR:-/tmp}/rpm-claim-scoped-ledger.XXXXXX")"
  trap "rm -f \"${fixture}\"" EXIT
  jq \
    ".runs_by_issue = {\"3\": [{run_id:\"old-3\",event_id:\"delivery-3\",idempotency_key:\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",status:\"active\"}], \"4\": [{run_id:\"old-4\",event_id:\"delivery-4\",idempotency_key:\"sha256:2222222222222222222222222222222222222222222222222222222222222222\",status:\"active\"}]}" \
    .agents/fixtures/backlog/cloud-claim-ready.json >"${fixture}"
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file "${fixture}" \
    --operation claim --issue 3 --run-id run-new --event-id delivery-new \
    --executor cloud --plan-revision plan-3 \
    --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --lease-owner cloud:executor)"
  printf "%s\n" "${output}" | jq -e \
    ".data.status == \"claim\" and (.data.execution.runs | length) == 2 and .data.execution.runs[0].run_id == \"old-3\" and all(.data.execution.runs[]; .run_id != \"old-4\")" >/dev/null
'
check "cloud_claim_recovered_ready_preserves_ledger" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-recovered-ready-ledger.json \
    --operation claim --issue 3 --run-id run-new --event-id delivery-new \
    --executor cloud --plan-revision plan-3 \
    --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --lease-owner cloud:executor)"
  printf "%s\n" "$output" | jq -e \
    ".data.status == \"claim\" and (.data.expected_execution_marker | contains(\"\\\"runs\\\"\")) and (.data.execution.runs | length) == 2 and .data.execution.runs[0].event_id == \"delivery-3\"" >/dev/null
  duplicate="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-recovered-ready-ledger.json \
    --operation claim --issue 3 --run-id run-3 --event-id delivery-3 \
    --executor cloud --plan-revision plan-3 \
    --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --lease-owner cloud:executor)"
  printf "%s\n" "$duplicate" | jq -e ".data.status == \"no-work\" and .data.reason == \"duplicate-event\"" >/dev/null
'
check "cloud_claim_stale_revision_blocked" sh -c '
  set +e
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-ready.json \
    --operation claim --issue 3 --run-id run-stale --event-id delivery-stale \
    --executor cloud --plan-revision plan-old \
    --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --lease-owner cloud:executor)"
  code=$?
  set -e
  [ "$code" -eq 1 ]
  printf "%s\n" "$output" | jq -e ".data.status == \"blocked\" and .data.reason == \"plan-revision-mismatch\"" >/dev/null
'
check "cloud_claim_duplicate_event_no_work" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-duplicate.json \
    --operation claim --issue 3 --run-id run-3 --event-id delivery-3 \
    --executor cloud --plan-revision plan-3 \
    --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --lease-owner cloud:executor)"
  printf "%s\n" "$output" | jq -e ".data.status == \"no-work\" and .data.reason == \"duplicate-event\"" >/dev/null
'
check "cloud_claim_expired_lease_blocked" sh -c '
  set +e
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-expired.json \
    --operation claim --issue 8 --run-id run-8b --event-id delivery-8b \
    --executor cloud --plan-revision plan-8 \
    --scope-hash sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --lease-owner cloud:executor)"
  code=$?
  set -e
  [ "$code" -eq 1 ]
  printf "%s\n" "$output" | jq -e ".data.status == \"blocked\" and .data.reason == \"lease-expired\"" >/dev/null
'
check "cloud_claim_malformed_lease_blocked" sh -c '
  fixture="$(mktemp "${TMPDIR:-/tmp}/rpm-malformed-lease.XXXXXX")"
  trap "rm -f \"${fixture}\"" EXIT
  jq ".issues[0].execution.lease.expires_at = \"tomorrow\"" \
    .agents/fixtures/backlog/cloud-claim-expired.json >"${fixture}"
  set +e
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file "${fixture}" \
    --operation claim --issue 8 --run-id run-8b --event-id delivery-8b \
    --executor cloud --plan-revision plan-8 \
    --scope-hash sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --lease-owner cloud:executor)"
  code=$?
  set -e
  [ "$code" -eq 1 ]
  printf "%s\n" "$output" | jq -e ".data.status == \"blocked\" and .data.reason == \"invalid-lease-expiry\"" >/dev/null
'
check "cloud_claim_malformed_run_blocked" sh -c '
  fixture="$(mktemp "${TMPDIR:-/tmp}/rpm-malformed-run.XXXXXX")"
  trap "rm -f \"${fixture}\"" EXIT
  jq ".runs_by_issue = {\"3\": [{run_id:\"run-3\",event_id:\"delivery-3\",idempotency_key:\"invalid\",status:\"active\"}]}" \
    .agents/fixtures/backlog/cloud-claim-ready.json >"${fixture}"
  set +e
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file "${fixture}" \
    --operation claim --issue 3 --run-id run-3b --event-id delivery-3b \
    --executor cloud --plan-revision plan-3 \
    --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --lease-owner cloud:executor)"
  code=$?
  set -e
  [ "$code" -eq 1 ]
  printf "%s\n" "$output" | jq -e ".data.status == \"blocked\" and .data.reason == \"invalid-run-ledger\"" >/dev/null
'
check "cloud_claim_executor_mismatch_blocked" sh -c '
  set +e
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-executor-mismatch.json \
    --operation claim --issue 7 --run-id run-7 --event-id delivery-7 \
    --executor local --plan-revision plan-7 \
    --scope-hash sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
    --lease-owner local:executor)"
  code=$?
  set -e
  [ "$code" -eq 1 ]
  printf "%s\n" "$output" | jq -e ".data.status == \"blocked\" and .data.reason == \"executor-mismatch\"" >/dev/null
'
check "cloud_multiple_lifecycle_blocked" sh -c '
  set +e
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-invalid.json \
    --operation select-execution)"
  code=$?
  set -e
  [ "$code" -eq 1 ]
  printf "%s\n" "$output" | jq -e "
    .data.status == \"blocked\"
    and .data.reason == \"multiple-lifecycle-labels\"
  " >/dev/null
'
check "cloud_active_work_no_work" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-active.json \
    --operation select-execution)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"no-work\"
    and .data.reason == \"active-work\"
  " >/dev/null
'
check "cloud_active_work_precedes_invalid_ready" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-active-invalid-ready.json \
    --operation select-execution)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"no-work\"
    and .data.reason == \"active-work\"
  " >/dev/null
'
check "cloud_claim_open_closing_pr_no_work" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-claim-closing-pr.json \
    --operation claim --issue 13 --run-id run-13 --event-id delivery-13 \
    --executor cloud --plan-revision plan-13 \
    --scope-hash sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
    --lease-owner cloud:executor)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"no-work\"
    and .data.reason == \"closing-pr-present\"
  " >/dev/null
'
check "cloud_ready_to_claimed" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-issues.json \
    --operation transition --issue 3 --from-state ready --to-state claimed)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"transition\"
    and .data.preserved_labels == [\"priority:high\"]
    and .data.labels == [\"agent:claimed\",\"priority:high\"]
  " >/dev/null
'
check "cloud_claimed_to_review_pending" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-active.json \
    --operation transition --issue 4 --from-state claimed --to-state review-pending)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"transition\"
    and .data.labels == [\"agent:review-pending\",\"kind:bug\"]
  " >/dev/null
'
check "cloud_review_not_arrived_no_work" sh -c '
  output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-review.json \
    --operation select-review)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"no-work\"
    and .data.reason == \"review-not-arrived\"
    and .data.issues == [12]
  " >/dev/null
'
check "cloud_review_pending_to_awaiting_merge" sh -c '
  selected="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-review-ready.json \
    --operation select-review)"
  transitioned="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file .agents/fixtures/backlog/cloud-review-ready.json \
    --operation transition --issue 12 --from-state review-pending --to-state awaiting-merge)"
  printf "%s\n" "$selected" | jq -e ".data.status == \"selected\"" >/dev/null
  printf "%s\n" "$transitioned" | jq -e "
    .data.status == \"transition\"
    and .data.preserved_labels == [\"kind:feature\"]
    and .data.labels == [\"agent:awaiting-merge\",\"kind:feature\"]
  " >/dev/null
'
check "cloud_queue_has_no_gh_or_project_dependency" sh -c '
  ! rg -n "(^|[^[:alnum:]_])(gh|GH_TOKEN|Project)([^[:alnum:]_]|$)" \
    scripts/check-cloud-queue-contract.py
'
check "merge_gate_pass" sh -c '
  output="$(python3 scripts/check-merge-gate.py \
    --issues-file .agents/fixtures/backlog/merge-ready.json \
    --operation select-merge)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"merge\"
    and .data.issue == 12
    and .data.pr == 44
    and .data.method == \"squash\"
    and .data.delete_branch == true
  " >/dev/null
'
check "merge_gate_checks_pending_no_work" sh -c '
  output="$(python3 scripts/check-merge-gate.py \
    --issues-file .agents/fixtures/backlog/merge-checks-pending.json \
    --operation select-merge)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"no-work\"
    and .data.reason == \"checks-pending\"
    and .data.checks == [\"verify\"]
  " >/dev/null
'
check "merge_gate_checks_failed_blocked" sh -c '
  set +e
  output="$(python3 scripts/check-merge-gate.py \
    --issues-file .agents/fixtures/backlog/merge-checks-failed.json \
    --operation select-merge)"
  code=$?
  set -e
  [ "$code" -eq 1 ]
  printf "%s\n" "$output" | jq -e "
    .data.status == \"blocked\"
    and .data.reason == \"checks-failed\"
  " >/dev/null
'
check "merge_gate_no_candidate_no_work" sh -c '
  output="$(python3 scripts/check-merge-gate.py \
    --issues-file .agents/fixtures/backlog/cloud-issues.json \
    --operation select-merge)"
  printf "%s\n" "$output" | jq -e "
    .data.status == \"no-work\"
    and .data.reason == \"no-awaiting-merge-candidate\"
  " >/dev/null
'
check "merge_gate_has_no_gh_or_project_dependency" sh -c '
  ! rg -n "(^|[^[:alnum:]_])(gh|GH_TOKEN|Project)([^[:alnum:]_]|$)" \
    scripts/check-merge-gate.py
'
check "local_prepare_keeps_project_registration" sh -c '
  rg -q "register the new issue in the policy-defined Project" \
    .codex/agents/rpm_idea_issue_creator.toml
  rg -q "local Project preflight" .agents/skills/prepare-backlog/SKILL.md
'
check "workflow_forbids_merge_and_codex_request" sh -c '
  ! rg -n -i \
    "(gh pr merge|merge_pull_request|@codex review)" \
    .agents/skills .codex/agents .agents/docs \
    | rg -v \
      "(Never|never|금지|Do not|does not|do not|without|request_codex_review|configured code review|does not post|no @codex review|or request @codex review|request, or wait for)"
'

if [ "${format}" = "jsonl" ]; then
  jq -nc --arg status "${status}" '{type:"agent_assets_result",data:{status:$status}}'
else
  printf 'agent_assets.status=%s\n' "${status}"
fi

if [ "${status}" != "ok" ]; then
  exit 1
fi
