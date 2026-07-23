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

if [ "${format}" != "jsonl" ] && [ "${format}" != "text" ]; then
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
  else
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

for skill in .agents/skills/*; do
  [ -d "${skill}" ] || continue
  name="$(basename "${skill}")"
  if [ "${name}" = "take-ticket" ] || [ "${name}" = "prepare-backlog" ]; then
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
  .version == 1
  and .repository == "nerdchanii/rpm"
  and .project.number == 7
  and .project.required == true
  and .labels == {
    research:"agent:research",
    ready:"agent:ready",
    claimed:"agent:claimed",
    blocked:"agent:blocked"
  }
  and .batch_limits == {research:1,execution:1}
  and .allowed_transitions == {
    untracked:["research"],
    research:["research","ready","blocked"],
    ready:["claimed","blocked"],
    claimed:["ready","blocked"],
    blocked:["research","ready"]
  }
' .agents/workflows/backlog-policy.json

check "agent_organization" python3 scripts/check-agent-organization.py
check "agent_hooks_json" jq -e . .codex/hooks.json

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
check "script_check_agent_organization_syntax" \
  python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/check-agent-organization.py").read_text())'
check "script_validate_agent_workflow_assets_syntax" \
  bash -n scripts/validate-agent-workflow-assets.sh

check "collect_pr_review_context_paginates" check_collect_paginates_comments_and_reviews
check "collect_pr_review_context_no_duplicates" check_collect_does_not_duplicate_exhausted_connections
check "readiness_ready_fixture" check_readiness_ready
check "readiness_missing_fixture" check_readiness_missing
check "readiness_unresolved_fixture" check_readiness_unresolved
check "readiness_live_issue_fixture" check_readiness_live_issue
check "backlog_research_batch" check_backlog_research_batch
check "backlog_no_work" check_backlog_no_work
check "backlog_inventory_order" check_backlog_inventory_order

if [ "${format}" = "jsonl" ]; then
  jq -nc --arg status "${status}" '{type:"agent_assets_result",data:{status:$status}}'
else
  printf 'agent_assets.status=%s\n' "${status}"
fi

if [ "${status}" != "ok" ]; then
  exit 1
fi
