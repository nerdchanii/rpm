#!/usr/bin/env bash
set -euo pipefail

status="ok"
format="jsonl"
skill_validator="${RPM_SKILL_VALIDATOR:-}"

if [ "${1:-}" = "--format" ]; then
  format="${2:-}"
elif [ "${1:-}" = "--format=text" ]; then
  format="text"
elif [ "${1:-}" = "--format=jsonl" ]; then
  format="jsonl"
fi

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
    jq -nc --arg name "${name}" --arg status "${result}" --arg output "${output}" \
      '{type:"agent_asset_check", data:{name:$name, status:$status, output:(if $output == "" then null else $output end)}}'
  else
    printf 'agent_assets.%s=%s\n' "${name}" "${result}"
    if [ -n "${output}" ]; then
      printf 'agent_assets.%s.output.begin\n%s\nagent_assets.%s.output.end\n' "${name}" "${output}" "${name}"
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

with_fake_watch_gh() {
  local fixture="$1"
  shift
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-watch-gh.XXXXXX")"
  trap 'rm -rf "${temp_dir}"' RETURN
  cat >"${temp_dir}/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  printf 'owner/repo\n'
  exit 0
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
  if [ -d "${RPM_WATCH_FIXTURE}" ]; then
    count_file="${RPM_WATCH_FIXTURE}/.count"
    count=0
    if [ -f "${count_file}" ]; then
      count="$(cat "${count_file}")"
    fi
    count=$((count + 1))
    printf '%s\n' "${count}" > "${count_file}"
    if [ -f "${RPM_WATCH_FIXTURE}/page-${count}.json" ]; then
      cat "${RPM_WATCH_FIXTURE}/page-${count}.json"
      exit 0
    fi
    cat "${RPM_WATCH_FIXTURE}/page-last.json"
    exit 0
  fi
  cat "${RPM_WATCH_FIXTURE}"
  exit 0
fi

printf 'unexpected gh call: %s\n' "$*" >&2
exit 99
GH
  chmod +x "${temp_dir}/gh"
  PATH="${temp_dir}:${PATH}" RPM_WATCH_FIXTURE="${fixture}" "$@"
}

check_watch_no_signal_timeout() {
  local fixture
  fixture="$(mktemp "${TMPDIR:-/tmp}/rpm-watch-no-signal.XXXXXX.json")"
  trap 'rm -f "${fixture}"' RETURN
  cat >"${fixture}" <<'JSON'
{"data":{"repository":{"pullRequest":{"comments":{"nodes":[]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
JSON

  local output
  set +e
  output="$(with_fake_watch_gh "${fixture}" bash scripts/watch-codex-review.sh 1 --start-time 2026-01-01T00:00:00Z --timeout 0 --format jsonl 2>&1)"
  local exit_code=$?
  set -e

  [ "${exit_code}" -eq 30 ] || {
    printf 'expected exit 30, got %s\n%s\n' "${exit_code}" "${output}"
    return 1
  }
  printf '%s\n' "${output}" | jq -e 'select(.type == "review_watch_status" and .data.status == "timeout")' >/dev/null
}

check_watch_review_precedes_thumbs_up() {
  local fixture
  fixture="$(mktemp "${TMPDIR:-/tmp}/rpm-watch-review-and-thumbs.XXXXXX.json")"
  trap 'rm -f "${fixture}"' RETURN
  cat >"${fixture}" <<'JSON'
{"data":{"repository":{"pullRequest":{"comments":{"nodes":[{"author":{"login":"octocat"},"createdAt":"2026-01-01T00:00:01Z","body":"@codex review","reactionGroups":[{"content":"THUMBS_UP","users":{"totalCount":1,"nodes":[{"login":"chatgpt-codex-connector"}]}}]}]},"reviews":{"nodes":[{"author":{"login":"chatgpt-codex-connector"},"submittedAt":"2026-01-01T00:00:02Z","state":"COMMENTED","body":"No findings."}]},"reviewThreads":{"nodes":[]}}}}}
JSON

  local output
  output="$(with_fake_watch_gh "${fixture}" bash scripts/watch-codex-review.sh 1 --start-time 2026-01-01T00:00:00Z --max-polls 1 --format jsonl 2>&1)"
  printf '%s\n' "${output}" | jq -e 'select(.type == "review_watch_status" and .data.status == "review_output_ready")' >/dev/null
}

check_watch_ignores_user_thumbs_up() {
  local fixture
  fixture="$(mktemp "${TMPDIR:-/tmp}/rpm-watch-user-thumbs.XXXXXX.json")"
  trap 'rm -f "${fixture}"' RETURN
  cat >"${fixture}" <<'JSON'
{"data":{"repository":{"pullRequest":{"comments":{"nodes":[{"author":{"login":"octocat"},"createdAt":"2026-01-01T00:00:01Z","body":"@codex review","reactionGroups":[{"content":"THUMBS_UP","users":{"totalCount":1,"nodes":[{"login":"octocat"}]}}]}]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
JSON

  local output
  set +e
  output="$(with_fake_watch_gh "${fixture}" bash scripts/watch-codex-review.sh 1 --start-time 2026-01-01T00:00:00Z --max-polls 1 --format jsonl 2>&1)"
  local exit_code=$?
  set -e

  [ "${exit_code}" -eq 30 ] || {
    printf 'expected exit 30, got %s\n%s\n' "${exit_code}" "${output}"
    return 1
  }
  if printf '%s\n' "${output}" | jq -e 'select(.type == "review_watch_status" and .data.status == "no_findings_reaction")' >/dev/null; then
    printf 'user thumbs-up was treated as no findings\n%s\n' "${output}"
    return 1
  fi
}

check_watch_paginates_review_threads() {
  local fixture_dir
  fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-watch-paginated.XXXXXX")"
  trap 'rm -rf "${fixture_dir}"' RETURN

  local page
  page=1
  while [ "${page}" -le 9 ]; do
    jq -n --argjson page "${page}" '
    {
      data: {
        repository: {
          pullRequest: {
            comments: {nodes: []},
            reviews: {nodes: []},
            reviewThreads: {
              pageInfo: {hasNextPage: true, endCursor: ("cursor-" + ($page | tostring))},
              nodes: [
                {
                  id: ("old-thread-" + ($page | tostring)),
                  isResolved: false,
                  isOutdated: false,
                  comments: {
                    nodes: [
                      {
                        author: {login: "octocat"},
                        createdAt: "2025-12-31T23:59:59Z",
                        body: "old thread",
                        url: ("https://example.test/old/" + ($page | tostring))
                      }
                    ]
                  }
                }
              ]
            }
          }
        }
      }
    }
  ' > "${fixture_dir}/page-${page}.json"
    page=$((page + 1))
  done

  jq -n '
    {
      data: {
        repository: {
          pullRequest: {
            comments: {nodes: []},
            reviews: {nodes: []},
            reviewThreads: {
              pageInfo: {hasNextPage: false, endCursor: "cursor-10"},
              nodes: [
                {
                  id: "new-codex-thread",
                  isResolved: false,
                  isOutdated: false,
                  comments: {
                    nodes: [
                      {
                        author: {login: "chatgpt-codex-connector"},
                        createdAt: "2026-01-01T00:00:01Z",
                        body: "new finding",
                        url: "https://example.test/new"
                      }
                    ]
                  }
                }
              ]
            }
          }
        }
      }
    }
  ' > "${fixture_dir}/page-10.json"
  cp "${fixture_dir}/page-10.json" "${fixture_dir}/page-last.json"

  local output
  output="$(with_fake_watch_gh "${fixture_dir}" bash scripts/watch-codex-review.sh 1 --start-time 2026-01-01T00:00:00Z --max-polls 1 --format jsonl 2>&1)"
  printf '%s\n' "${output}" | jq -e 'select(.type == "review_watch_status" and .data.status == "review_threads_ready" and .data.thread_count == "1")' >/dev/null
}

check_watch_page_file_ordering_after_ten() {
  local fixture_dir
  fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpm-watch-page-order.XXXXXX")"
  trap 'rm -rf "${fixture_dir}"' RETURN

  local page
  local page_file
  page=1
  while [ "${page}" -le 10 ]; do
    printf -v page_file '%s/page-%06d.json' "${fixture_dir}" "${page}"
    jq -n --argjson page "${page}" '{page: $page}' > "${page_file}"
    page=$((page + 1))
  done

  grep -Fq "page-%06d.json" scripts/watch-codex-review.sh || {
    printf 'watch review page files are not zero-padded\n'
    return 1
  }

  local actual
  actual="$(jq -s -r '[.[].page] | join(",")' "${fixture_dir}"/page-*.json)"
  [ "${actual}" = "1,2,3,4,5,6,7,8,9,10" ] || {
    printf 'expected numeric page order, got %s\n' "${actual}"
    return 1
  }
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
  ' > "${fixture_dir}/page-1.json"

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
  ' > "${fixture_dir}/page-2.json"
  cp "${fixture_dir}/page-2.json" "${fixture_dir}/page-last.json"

  local output
  output="$(with_fake_watch_gh "${fixture_dir}" bash scripts/collect-pr-review-context.sh 1 --format json 2>&1)"
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
  ' > "${fixture_dir}/page-1.json"

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
  ' > "${fixture_dir}/page-2.json"

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
  ' > "${fixture_dir}/page-3.json"
  cp "${fixture_dir}/page-3.json" "${fixture_dir}/page-last.json"

  local output
  output="$(with_fake_watch_gh "${fixture_dir}" bash scripts/collect-pr-review-context.sh 1 --format json 2>&1)"
  printf '%s\n' "${output}" | jq -e '
    ([.issueComments[] | select(.body == "single issue comment")] | length) == 1
    and (.issueComments | length) == 1
    and (.reviews | length) == 3
    and ([.reviews[].body] == ["review page 1", "review page 2", "review page 3"])
  ' >/dev/null
}

for skill in .agents/skills/*; do
  [ -d "${skill}" ] || continue
  name="$(basename "${skill}")"
  if [ -n "${skill_validator}" ]; then
    check "skill_${name}" \
      python3 "${skill_validator}" "${skill}"
  else
    emit_check "skill_${name}" "skip" "skill validator not found; set RPM_SKILL_VALIDATOR to enable this check"
  fi
done

if [ -d .codex/agents ]; then
  for agent in .codex/agents/*.toml; do
    [ -f "${agent}" ] || continue
    name="$(basename "${agent}" .toml)"
    check "agent_${name}_toml" \
      python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "${agent}"
  done
fi

check "script_collect_pr_review_context_syntax" \
  bash -n scripts/collect-pr-review-context.sh

check "script_create_review_followup_issue_syntax" \
  bash -n scripts/create-review-followup-issue.sh

check "script_ticket_gen_syntax" \
  bash -n scripts/ticket-gen

check "script_watch_codex_review_syntax" \
  bash -n scripts/watch-codex-review.sh

check "script_watch_codex_review_no_signal_timeout" \
  check_watch_no_signal_timeout

check "script_watch_codex_review_review_precedes_thumbs_up" \
  check_watch_review_precedes_thumbs_up

check "script_watch_codex_review_ignores_user_thumbs_up" \
  check_watch_ignores_user_thumbs_up

check "script_watch_codex_review_paginates_review_threads" \
  check_watch_paginates_review_threads

check "script_watch_codex_review_page_file_ordering_after_ten" \
  check_watch_page_file_ordering_after_ten

check "script_collect_pr_review_context_paginates_comments_and_reviews" \
  check_collect_paginates_comments_and_reviews

check "script_collect_pr_review_context_no_duplicate_exhausted_connections" \
  check_collect_does_not_duplicate_exhausted_connections

check "script_validate_agent_workflow_assets_syntax" \
  bash -n scripts/validate-agent-workflow-assets.sh

if [ "${format}" = "jsonl" ]; then
  jq -nc --arg status "${status}" '{type:"agent_assets_result", data:{status:$status}}'
else
  printf 'agent_assets.status=%s\n' "${status}"
fi

if [ "${status}" != "ok" ]; then
  exit 1
fi
