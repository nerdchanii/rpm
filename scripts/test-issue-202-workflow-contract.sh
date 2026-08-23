#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

fixture_dir=".agents/fixtures/backlog"

require_contract_text() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! tr '\n' ' ' < "$file" | rg -qi "$pattern"; then
    printf 'missing %s in %s\n' "$label" "$file" >&2
    exit 1
  fi
}

require_section_text() {
  local section="$1"
  local pattern="$2"
  local label="$3"
  if ! printf '%s\n' "$section" | rg -qi "$pattern"; then
    printf 'missing %s in take-ticket explicit contract\n' "$label" >&2
    exit 1
  fi
}

explicit_section="$(awk '
  /^### Explicit/ { in_section=1 }
  /^### Scheduled/ { in_section=0 }
  in_section { print }
' .agents/skills/take-ticket/SKILL.md)"
require_section_text "$explicit_section" 'complete' 'complete outcome'
require_section_text "$explicit_section" 'no-work' 'no-work outcome'
require_section_text "$explicit_section" 'blocked' 'blocked outcome'
require_contract_text .agents/skills/take-ticket/SKILL.md 'entry point|single entry' 'single ticket entrypoint'

require_contract_text .agents/skills/take-ticket/SKILL.md 'existing policy-authorized claim workflow|shared path' 'shared explicit claim path'
require_contract_text .agents/skills/take-ticket/SKILL.md 'exact user-selected issue|exact issue' 'exact selected issue'
require_contract_text .agents/skills/take-ticket/SKILL.md 'never creates a second claim path|second claim path' 'single explicit claim path'
require_contract_text .codex/agents/rpm_workflow_manager.toml 'mode=claim-ready|claim-ready' 'claim-ready routing'
require_contract_text .codex/agents/rpm_workflow_manager.toml 'selected_issue.*exact|exact.*selected_issue' 'exact selected issue routing'
require_contract_text .codex/agents/rpm_workflow_manager.toml 'same claimed issue' 'same claimed issue handoff'
require_contract_text .codex/agents/rpm_workflow_manager.toml 'do not create a second claim path|second claim path' 'single router claim path'
require_contract_text .codex/agents/rpm_backlog_manager.toml 'selected_issue.*exact|exact.*selected_issue' 'backlog exact selected issue'
require_contract_text .codex/agents/rpm_backlog_manager.toml 'never substitute another candidate' 'no explicit candidate substitution'
require_contract_text .codex/agents/rpm_ready_ticket_claimer.toml 'cloud_queue_contract' 'deterministic claim input'
require_contract_text .codex/agents/rpm_ready_ticket_claimer.toml 'status.*claim.*status.*claimed|status.*claimed.*status.*claim' 'controller claim normalization'
require_contract_text .codex/agents/rpm_ready_ticket_claimer.toml 'idempotency_key' 'claim idempotency evidence'
require_contract_text .codex/agents/rpm_ready_ticket_claimer.toml 'valid.*lease|lease.*valid' 'claim lease evidence'
require_contract_text .codex/agents/rpm_backlog_manager.toml 'normalized candidate snapshot' 'claim snapshot handoff'
require_contract_text .codex/agents/rpm_backlog_manager.toml 'approved claim inputs' 'claim input handoff'
require_contract_text .codex/agents/rpm_backlog_manager.toml 'claim_result' 'structured backlog claim result'
require_contract_text .codex/agents/rpm_workflow_manager.toml 'complete verified.*ready_ticket_claim_result|ready_ticket_claim_result.*without reducing' 'scheduled claim result relay'
require_contract_text .codex/agents/rpm_issue_manager.toml 'Missing.*controller evidence.*never falls back|never falls back.*label state' 'missing controller result blocked'

for claim_contract in \
  .agents/skills/take-ticket/SKILL.md \
  .codex/agents/rpm_issue_manager.toml
do
  require_contract_text "$claim_contract" 'agent:claimed' 'current claimed state'
  require_contract_text "$claim_contract" 'valid.*lease|unexpired.*lease' 'valid unexpired lease evidence'
  require_contract_text "$claim_contract" 'current.*(re)?validation|revalidat.*current|refetch.*current' 'current-state revalidation'
  require_contract_text "$claim_contract" 'stale.*blocked|blocked.*stale' 'stale claim rejection'
  require_contract_text "$claim_contract" 'expired.*blocked|blocked.*expired' 'expired claim rejection'
  require_contract_text "$claim_contract" 'wrong-issue|wrong issue|mismatched' 'wrong-issue claim rejection'
done
require_contract_text .codex/agents/rpm_workflow_manager.toml 'verified.*ready_ticket_claim_result|matching current claim evidence' 'router current claim evidence'
require_contract_text .codex/agents/rpm_workflow_manager.toml 'valid.*lease|unexpired.*lease' 'router valid unexpired lease evidence'
require_contract_text .codex/agents/rpm_issue_manager.toml 'exact requested issue|exact issue' 'manager exact issue revalidation'
require_contract_text .codex/agents/rpm_issue_manager.toml 'never.*replaces.*current-state revalidation|current-state revalidation' 'claim evidence cannot bypass revalidation'

for provider_contract in \
  .codex/agents/rpm_backlog_manager.toml \
  .codex/agents/rpm_backlog_scout.toml \
  .codex/agents/rpm_ready_ticket_claimer.toml \
  .codex/agents/rpm_issue_fetcher.toml
do
  require_contract_text "$provider_contract" 'host-provided GitHub capability' 'host GitHub capability'
  if rg -n -i -P 'GitHub plugin|GH_TOKEN|GITHUB_TOKEN|GITHUB_PERSONAL_ACCESS_TOKEN|(?<![[:alnum:]_])PAT(?![[:alnum:]_])|mcp__' "$provider_contract" >/dev/null; then
    printf 'provider-specific GitHub dependency remains in %s\n' "$provider_contract" >&2
    exit 1
  fi
done
require_contract_text .codex/hooks.json '\[Gg\].*\[Ii\].*\[Tt\].*\[Hh\].*\[Uu\].*\[Bb\]' 'provider-neutral GitHub PreToolUse matcher'
require_contract_text .codex/hooks.json '\[Gg\]\[Hh\]_' 'gh alias PreToolUse matcher'
require_contract_text .codex/hooks.json '\[Ii\]ssue' 'issue alias PreToolUse matcher'
hook_matcher="$(jq -r '.hooks.PreToolUse[0].matcher' .codex/hooks.json)"
for aliased_github_tool in gh_pr_merge gh_update_issue issue_update hostIssueUpdate hostPullRequestMerge; do
  python3 -c 'import re,sys; raise SystemExit(0 if re.fullmatch(sys.argv[1], sys.argv[2]) else 1)' \
    "$hook_matcher" "$aliased_github_tool"
done
for hooked_shell_tool in terminal Terminal Shell bash functions.terminal functions.shell; do
  python3 -c 'import re,sys; raise SystemExit(0 if re.fullmatch(sys.argv[1], sys.argv[2]) else 1)' \
    "$hook_matcher" "$hooked_shell_tool"
done

for implementation_handoff in \
  .agents/skills/take-ticket/SKILL.md \
  .codex/agents/rpm_issue_fetcher.toml \
  .codex/agents/rpm_issue_manager.toml \
  .codex/agents/rpm_implementer.toml \
  .codex/agents/pr-review-resolver.toml
do
  require_contract_text "$implementation_handoff" 'validated.*durable.*handoff|durable.*handoff.*valid' 'validated durable handoff when present'
  require_contract_text "$implementation_handoff" 'canonical.*issue packet.*compatibility|compatibility.*handoff' 'canonical issue packet compatibility handoff'
done
for intake_boundary in \
  .agents/skills/take-ticket/SKILL.md \
  .codex/agents/rpm_issue_fetcher.toml \
  .codex/agents/rpm_issue_manager.toml
do
  require_contract_text "$intake_boundary" 'prior[- ]session' 'prior-session boundary'
  require_contract_text "$intake_boundary" 'hidden|implicit|untrusted' 'hidden-context rejection'
  require_contract_text "$intake_boundary" 'reject|ignore|forbid|never|do not' 'handoff rejection rule'
done
require_contract_text .codex/agents/rpm_issue_fetcher.toml 'issue-authored' 'issue-authored handoff boundary'
require_contract_text .codex/agents/rpm_issue_manager.toml 'issue-authored' 'manager issue-authored scope boundary'
require_contract_text .codex/agents/rpm_issue_fetcher.toml 'source.*issue_body|issue_body.*source' 'issue-body handoff source'
require_contract_text .codex/agents/rpm_issue_fetcher.toml 'body_sha256|body digest' 'issue-body digest binding'
require_contract_text .codex/agents/rpm_issue_fetcher.toml 'evidence_events' 'separate evidence events'
require_contract_text .codex/agents/rpm_issue_fetcher.toml 'cannot populate or override.*handoff|evidence events cannot' 'comment scope isolation'

for discovered_work_contract in \
  .codex/agents/rpm_implementer.toml \
  .codex/agents/pr-review-resolver.toml
do
  require_contract_text "$discovered_work_contract" 'validated.*#?208|#208.*handoff|discovered[- ]work' '#208 discovered-work boundary'
  require_contract_text "$discovered_work_contract" 'risks|decisions|follow[- ]up' 'existing discovered-work output preservation'
  require_contract_text "$discovered_work_contract" 'without inventing.*schema|do not invent.*schema|do not invent a replacement schema' 'no invented #208 schema'
done
require_contract_text .codex/agents/pr-review-resolver.toml 'may_create_followup_issues' 'follow-up authorization flag'
require_contract_text .codex/agents/pr-review-resolver.toml 'only.*(allowed|authorized)|authorization.*follow[- ]up|follow[- ]up.*authorization' 'follow-up authorization gate'
require_contract_text .agents/skills/pr-review-resolution/SKILL.md 'may_create_followup_issues' 'review follow-up authorization flag'
require_contract_text .agents/skills/pr-review-resolution/SKILL.md 'only.*(allowed|authorized)|authorization.*follow[- ]up|follow[- ]up.*authorization' 'review follow-up authorization gate'
require_contract_text .codex/agents/rpm_implementer.toml 'risks' 'implementer risks output'
require_contract_text .codex/agents/pr-review-resolver.toml 'decisions|follow[- ]up' 'resolver decisions and follow-up output'
require_contract_text .codex/agents/rpm_issue_manager.toml 'followup_issues' 'manager follow-up output'
require_contract_text .codex/agents/rpm_issue_manager.toml 'status":"complete\|checkpoint\|no-work\|blocked' 'manager no-work result schema'
require_contract_text .codex/agents/rpm_workflow_manager.toml 'no-work.*empty issue|empty issue.*no-work' 'workflow manager no-work protocol'

readiness_output="$(python3 scripts/check-agent-issue-readiness.py \
  --body-file .agents/fixtures/backlog/readiness-ready.md \
  --format jsonl)"
printf '%s\n' "$readiness_output" | jq -e '
  .type == "issue_readiness_result"
  and .data.status == "ready"
  and .data.ready == true
  and (.data.missing_sections | length) == 0
  and (.data.unresolved_decisions | length) == 0
  and .data.execution_error == null
  and .data.execution_metadata.executor == "cloud"
' >/dev/null

claim_output="$(python3 scripts/check-cloud-queue-contract.py \
  --issues-file .agents/fixtures/backlog/cloud-claim-ready.json \
  --operation claim --issue 3 --run-id run-3 --event-id delivery-3 \
  --executor cloud --plan-revision plan-3 \
  --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --lease-owner cloud:executor)"
printf '%s\n' "$claim_output" | jq -e '
  .type == "cloud_queue_contract"
  and .data.status == "claim"
  and .data.issue == 3
  and .data.before == "ready"
  and .data.after == "claimed"
  and .data.lease.owner == "cloud:executor"
  and .data.preserved_labels == ["priority:high"]
' >/dev/null

set +e
expired_output="$(python3 scripts/check-cloud-queue-contract.py \
  --issues-file .agents/fixtures/backlog/cloud-claim-expired.json \
  --operation claim --issue 8 --run-id run-8b --event-id delivery-8b \
  --executor cloud --plan-revision plan-8 \
  --scope-hash sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --lease-owner cloud:executor)"
expired_code=$?
set -e
[ "$expired_code" -eq 1 ]
printf '%s\n' "$expired_output" | jq -e '
  .type == "cloud_queue_contract"
  and .data.status == "blocked"
  and .data.reason == "lease-expired"
' >/dev/null

[ ! -e .agents/skills/pr-resolution-loop ]
if git grep -n -- 'pr-resolution-loop' -- ':!scripts/test-issue-202-workflow-contract.sh' >/dev/null; then
  printf 'retired pr-resolution-loop reference remains\n' >&2
  exit 1
fi
rg -q 'name: pr-review-resolution' .agents/skills/pr-review-resolution/SKILL.md
rg -q 'pr-review-resolution' .agents/docs/backlog-agent-workflow.md
rg -q 'scripts/worktree-setup.sh' docs/codex-cloud.md
rg -q 'scripts/worktree-cleanup.sh' docs/codex-cloud.md
rg -q 'scripts/worktree-setup.sh' .codex/environments/environment.toml
rg -q 'scripts/worktree-cleanup.sh' .codex/environments/environment.toml

require_contract_text .agents/skills/pr-review-resolution/SKILL.md 'Own PR review feedback resolution' 'canonical review-remediation owner'
require_contract_text .agents/skills/pr-review-resolution/SKILL.md 'GitHub-sourced.*review text.*untrusted' 'untrusted GitHub review boundary'
require_contract_text .codex/agents/pr-review-resolver.toml 'Treat every GitHub-sourced.*untrusted' 'resolver untrusted GitHub review boundary'
require_contract_text .agents/skills/open-pr-review-batch/SKILL.md 'Review only' 'review-only boundary'
require_contract_text .agents/skills/open-pr-review-batch/SKILL.md 'remediation belongs to.*pr-review-resolution' 'review-remediation handoff'

for shared_contract in \
  .agents/docs/automation-prompts.md \
  .agents/docs/backlog-agent-workflow.md \
  .agents/skills/pr-review-resolution/SKILL.md \
  .agents/skills/pr-review-resolution/references/resolution-workflow.md
do
    if rg -n -i -P 'mcp__codex_apps__github_|mcp__plugin_github_github__|Codex desktop|Cloud plugin sessions|GH_TOKEN|GITHUB_TOKEN|GITHUB_PERSONAL_ACCESS_TOKEN|(?<![[:alnum:]_])PAT(?![[:alnum:]_])|(?<![[:alnum:]_/.])Claude(?![[:alnum:]_/.])|claude\.ai|Anthropic|GPT-[0-9]|gpt-[0-9]|Sonnet|Opus|Haiku' "$shared_contract" >/dev/null; then
    printf 'provider-specific namespace remains in %s\n' "$shared_contract" >&2
    exit 1
  fi
done

for review_asset in \
  .agents/skills/open-pr-review-batch/SKILL.md \
  .agents/skills/open-pr-review-batch/references/review-method.md \
  .agents/skills/open-pr-review-batch/references/worker-prompt.md
do
  rg -qi 'host-provided GitHub capability|GitHub capability' "$review_asset"
  rg -qi 'local/manual fallback|optional.*gh|gh.*fallback' "$review_asset"
  if rg -n -i -P 'mcp__|GH_TOKEN|GITHUB_TOKEN|GITHUB_PERSONAL_ACCESS_TOKEN|(?<![[:alnum:]_])PAT(?![[:alnum:]_])|Claude|claude\.ai|Anthropic|GPT-[0-9]|gpt-[0-9]|Sonnet|Opus|Haiku' "$review_asset" >/dev/null; then
    printf 'provider-specific or named-model attribution remains in %s\n' "$review_asset" >&2
    exit 1
  fi
done
rg -qi 'manual|local' .agents/skills/safe-direct-merge/SKILL.md
rg -qi 'explicitly authorized|user.*authorized|authorized.*direct merge' .agents/skills/safe-direct-merge/SKILL.md
rg -qi 'gh' .agents/skills/safe-direct-merge/SKILL.md
require_contract_text .agents/skills/merge-gatekeeper/SKILL.md 'single authorized merge path|sole merge path' 'sole scheduled merge owner'
require_contract_text .agents/skills/merge-gatekeeper/SKILL.md 'top-level scheduled|scheduled.*merge|merge.*scheduled' 'scheduled merge ownership'
require_contract_text .agents/skills/safe-direct-merge/SKILL.md 'sole merge path for lifecycle|scheduled.*merge-gatekeeper' 'manual merge exception boundary'

hook_script=".codex/hooks/agent_tool_policy.py"
hook_transcript="$(mktemp /tmp/rpm-issue-202-hook.XXXXXX)"
hook_stop() {
  jq -nc --arg path "$hook_transcript" \
    '{hook_event_name:"SubagentStop",agent_type:"rpm_backlog_scout",agent_transcript_path:$path}' \
    | python3 "$hook_script" >/dev/null 2>&1 || true
  rm -f "$hook_transcript"
}
trap hook_stop EXIT

hook_event() {
  python3 "$hook_script"
}

hook_start_payload="$(jq -nc --arg path "$hook_transcript" \
  '{hook_event_name:"SubagentStart",agent_type:"rpm_backlog_scout",agent_transcript_path:$path}')"
if ! printf '%s\n' "$hook_start_payload" | hook_event; then
  printf 'agent_tool_policy SubagentStart probe failed\n' >&2
  exit 1
fi

probe_hook_tool() {
  local label="$1"
  local expected="$2"
  local tool="$3"
  local tool_input="$4"
  local payload
  local actual
  payload="$(jq -nc \
    --arg path "$hook_transcript" \
    --arg cwd "$repo_root" \
    --arg tool "$tool" \
    --argjson input "$tool_input" \
    '{hook_event_name:"PreToolUse",transcript_path:$path,cwd:$cwd,tool_name:$tool,tool_input:$input}')"
  set +e
  printf '%s\n' "$payload" | hook_event >/dev/null 2>&1
  actual=$?
  set -e
  if [ "$actual" -ne "$expected" ]; then
    printf 'agent_tool_policy %s expected exit %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

probe_hook_tool_as_role() {
  local role="$1"
  shift
  jq -nc --arg path "$hook_transcript" --arg role "$role" \
    '{hook_event_name:"SubagentStart",agent_type:$role,agent_transcript_path:$path}' \
    | hook_event >/dev/null 2>&1
  probe_hook_tool "$@"
  jq -nc --arg path "$hook_transcript" --arg role "$role" \
    '{hook_event_name:"SubagentStop",agent_type:$role,agent_transcript_path:$path}' \
    | hook_event >/dev/null 2>&1 || true
  printf '%s\n' "$hook_start_payload" | hook_event >/dev/null
}

probe_hook_tool 'non-prefixed GitHub read' 0 'github_get_issue' '{}'
probe_hook_tool 'issue comments read' 0 'github_get_issue_comments' '{}'
probe_hook_tool 'list issue comments read' 0 'github_list_issue_comments' '{}'
probe_hook_tool 'non-prefixed GitHub mutation' 2 'github_update_issue' '{"issue_number":202,"body":"changed"}'
probe_hook_tool 'camelCase GitHub read' 0 'githubGetIssue' '{}'
probe_hook_tool 'camelCase GitHub mutation' 2 'githubUpdateIssue' '{"issue_number":202,"body":"changed"}'
probe_hook_tool 'gh alias merge' 2 'gh_pr_merge' '{"pr_number":202}'
probe_hook_tool 'gh alias issue mutation' 2 'gh_update_issue' '{"issue_number":202,"body":"changed"}'
probe_hook_tool 'bare issue mutation' 2 'issue_update' '{"issue_number":202,"body":"changed"}'
probe_hook_tool 'host camel issue mutation' 2 'hostIssueUpdate' '{"issue_number":202,"body":"changed"}'
probe_hook_tool 'inline GraphQL mutation' 2 'mcp__github__graphql' '{"query":"mutation UpdateIssue { updateIssue(input: {}) { issue { number } } }"}'
probe_hook_tool 'snake-case GraphQL mutation in variables query' 2 'mcp__github__graphql' '{"variables":{"query":"mutation UpdateIssue { updateIssue(input: {}) { issue { number } } }"}}'
probe_hook_tool 'camelCase GraphQL mutation in variables query' 2 'githubGraphql' '{"variables":{"query":"mutation UpdateIssue { updateIssue(input: {}) { issue { number } } }"}}'
probe_hook_tool 'github_execute GraphQL mutation in query' 2 'github_execute' '{"query":"mutation UpdateIssue { updateIssue(input: {}) { issue { number } } }"}'
probe_hook_tool 'github_execute REST PATCH in request' 2 'github_execute' '{"request":{"method":"PATCH","path":"/repos/nerdchanii/rpm/issues/202"}}'
probe_hook_tool 'github_execute getIssue plus REST POST' 2 'github_execute' '{"operationName":"getIssue","request":{"method":"POST","path":"/repos/nerdchanii/rpm/issues/202"}}'
probe_hook_tool 'github_execute getIssue plus REST PUT' 2 'github_execute' '{"operationName":"getIssue","request":{"method":"PUT","path":"/repos/nerdchanii/rpm/issues/202"}}'
probe_hook_tool 'github update operation conflict' 2 'github_update_issue' '{"operation":"get","issue_number":202}'
probe_hook_tool 'github_execute POST with create body' 2 'github_execute' '{"request":{"method":"POST","body":"query create issue"}}'
probe_hook_tool 'github_execute methodless request mutation' 2 'github_execute' '{"request":{"body":"query mutation UpdateIssue { updateIssue(input: {}) {} }"}}'
probe_hook_tool 'github_execute methodless query mutation' 2 'github_execute' '{"query":"query create issue"}'
probe_hook_tool 'github_execute nested method spoof' 2 'github_execute' '{"request":{"path":"/repos/nerdchanii/rpm/issues","body":{"method":"GET","title":"attacker-controlled"}}}'
probe_hook_tool 'github_execute explicit GET denied' 2 'github_execute' '{"request":{"method":"GET","path":"/repos/nerdchanii/rpm/issues/202"}}'
probe_hook_tool 'persisted GraphQL mutation' 2 'mcp__github__graphql' '{"operationName":"updateIssue"}'
probe_hook_tool 'persisted GraphQL read without query text' 2 'mcp__github__graphql' '{"operationName":"getIssue"}'
probe_hook_tool 'camelCase persisted GraphQL mutation without query text' 2 'githubGraphql' '{"operationName":"updateIssue"}'
probe_hook_tool 'camelCase persisted GraphQL read without query text' 2 'githubGraphql' '{"operationName":"getIssue"}'
probe_hook_tool_as_role 'rpm_ready_ticket_claimer' \
  'ready-ticket claimer GraphQL update fields' 2 'mcp__github__graphql' \
  '{"query":"mutation UpdateIssue { updateIssue(input: {title: \"x\", body: \"x\", state: OPEN, assignees: [\"x\"], labels: [\"x\"]}) { issue { number } } }"}'
probe_hook_tool_as_role 'rpm_ready_ticket_claimer' \
  'ready-ticket claimer persisted generic mutation' 2 'github_execute' \
  '{"operationName":"updateIssue","variables":{"id":"x","x":"attacker-controlled-value"}}'
probe_hook_tool_as_role 'rpm_ready_ticket_claimer' \
  'ready-ticket claimer exact claimed label' 0 'githubUpdateIssue' \
  '{"issue_number":202,"labels":["agent:claimed","priority:high"]}'
probe_hook_tool_as_role 'rpm_ready_ticket_claimer' \
  'ready-ticket claimer ready label denied' 2 'githubUpdateIssue' \
  '{"issue_number":202,"labels":["agent:ready"]}'
probe_hook_tool_as_role 'rpm_ready_ticket_claimer' \
  'ready-ticket claimer empty labels denied' 2 'githubUpdateIssue' \
  '{"issue_number":202,"labels":[]}'
probe_hook_tool_as_role 'rpm_ready_ticket_claimer' \
  'ready-ticket claimer metadata denied' 2 'githubUpdateIssue' \
  '{"issue_number":202,"labels":["agent:claimed"],"project_ids":["pwn"]}'
probe_hook_tool_as_role 'rpm_issue_refiner' \
  'issue refiner GraphQL update fields' 2 'mcp__github__graphql' \
  '{"query":"mutation UpdateIssue { updateIssue(input: {title: \"x\", body: \"x\", state: OPEN, assignees: [\"x\"], labels: [\"x\"]}) { issue { number } } }"}'
probe_hook_tool_as_role 'pr-review-resolver' \
  'review resolver workflow patch' 2 'apply_patch' \
  '{"patch":"*** Begin Patch\n*** Update File: .github/workflows/ci.yml\n*** End Patch\n"}'
probe_hook_tool_as_role 'pr-review-resolver' \
  'review resolver claude symlink patch' 2 'apply_patch' \
  '{"patch":"*** Begin Patch\n*** Update File: .claude/skills/pr-review-resolution/SKILL.md\n*** End Patch\n"}'
probe_hook_tool_as_role 'pr-review-resolver' \
  'review resolver workflow shell write' 2 'exec_command' \
  '{"cmd":"printf changed > .github/workflows/ci.yml"}'
probe_hook_tool_as_role 'pr-review-resolver' \
  'review resolver generic shell write' 2 'shell' \
  '{"cmd":"printf changed > src/lib.rs"}'
probe_hook_tool_as_role 'pr-review-resolver' \
  'review resolver shell validation delegation' 2 'exec_command' \
  '{"cmd":"just validate"}'
probe_hook_tool_as_role 'pr-review-resolver' \
  'review resolver benign bash validation delegation' 2 'bash' \
  '{"cmd":"just validate"}'

jq -e '
  type == "array"
  and length > 0
  and all(.[];
    (keys_unsorted | sort) == ["expected_status", "input", "mode", "owner"]
    and (.mode | type) == "string"
    and (.input | type) == "object"
    and (.owner | type) == "string"
    and (.expected_status | type) == "string"
    and (.expected_status | IN("complete", "no-work", "blocked"))
  )
  and any(.[];
    .mode == "scheduled"
    and .input.queue == "eligible-issue"
    and .input.claim_result.data.status == "claimed"
    and .input.claim_result.data.claim_contract.status == "claim"
    and .input.claim_result.data.claim_contract.issue == .input.issue
    and .expected_status == "complete"
  )
  and any(.[];
    .mode == "explicit"
    and .input.claim_state == "ready"
    and .input.controller_status == "claim"
    and .input.claim_result_issue == .input.issue
    and .input.idempotency_key != ""
    and .input.lease == "valid"
    and .expected_status == "complete"
  )
  and any(.[];
    .mode == "scheduled"
    and .input.queue == "empty"
    and .expected_status == "no-work"
  )
  and any(.[];
    .mode == "explicit"
    and .input.claim_state == "mismatched"
    and .expected_status == "blocked"
  )
' "$fixture_dir/issue-202-terminal-outcomes.json" >/dev/null
printf 'issue-202 workflow contract checks passed\n'
