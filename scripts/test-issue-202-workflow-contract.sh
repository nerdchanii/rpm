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
require_contract_text .codex/agents/rpm_ready_ticket_claimer.toml 'transition_required.:true.*already-claimed.*transition_required:false' 'claim transition boolean schema'
require_contract_text .codex/agents/rpm_ready_ticket_claimer.toml 'resumed.:false.*already-claimed.*resumed:true' 'claim recovery boolean schema'
require_contract_text .codex/agents/rpm_ready_ticket_claimer.toml 'hook.*(re-runs|authorization).*controller|controller.*authorization.*blocked' 'hook-bound claim authorization'
require_contract_text .codex/agents/rpm_ready_ticket_claimer.toml 'parent-issued.*rpm_claim_authorization|rpm_claim_authorization.*parent-issued' 'parent-issued claim authorization'
require_contract_text .codex/agents/rpm_backlog_manager.toml 'never place both.*phases.*one child transcript|one child transcript.*both.*phases' 'one-phase claimer handoff'
require_contract_text .codex/agents/rpm_backlog_scout.toml 'normalized_snapshot.*snapshot_sha256|snapshot_sha256.*normalized_snapshot' 'scout snapshot digest handoff'
python3 -c 'import json,tomllib; text=tomllib.load(open(".codex/agents/rpm_ready_ticket_claimer.toml","rb"))["developer_instructions"]; event=json.loads(next(line for line in text.splitlines() if line.startswith("{\"type\":\"ready_ticket_claim_result\""))); contract=event["data"]["claim_contract"]; assert isinstance(contract["transition_required"], bool); assert isinstance(contract["recovery"]["resumed"], bool); assert isinstance(event["data"]["verified"], bool)'
require_contract_text .codex/agents/rpm_ready_ticket_claimer.toml 'idempotency_key' 'claim idempotency evidence'
require_contract_text .codex/agents/rpm_ready_ticket_claimer.toml 'valid.*lease|lease.*valid' 'claim lease evidence'
require_contract_text .codex/agents/rpm_backlog_manager.toml 'normalized candidate snapshot' 'claim snapshot handoff'
require_contract_text .codex/agents/rpm_backlog_manager.toml 'approved claim inputs' 'claim input handoff'
require_contract_text .codex/agents/rpm_backlog_manager.toml 'claim_result' 'structured backlog claim result'
require_contract_text .codex/agents/rpm_backlog_scout.toml 'claimed-recovery.*before.*ready|before.*ready.*claimed-recovery' 'scout claimed recovery routing'
require_contract_text .codex/agents/rpm_backlog_manager.toml 'claimed-recovery.*before.*ready|before.*ready.*claimed-recovery' 'manager claimed recovery routing'
require_contract_text .codex/agents/rpm_workflow_manager.toml 'complete verified.*ready_ticket_claim_result|ready_ticket_claim_result.*without reducing' 'scheduled claim result relay'
require_contract_text .codex/agents/rpm_issue_manager.toml 'Missing.*controller evidence.*never falls back|never falls back.*label state' 'missing controller result blocked'
require_contract_text .agents/skills/pr-review-resolution/SKILL.md 'dedicated clean.*worktree|clean.*worktree.*exact.*head' 'review resolver clean head worktree'
require_contract_text .codex/agents/pr-review-resolver.toml 'dedicated clean.*worktree|clean.*worktree.*exact.*head' 'review resolver worker clean head worktree'

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
require_contract_text .codex/hooks.json '\[Ii\].*\[Ss\].*\[Ss\].*\[Uu\].*\[Ee\]' 'case-insensitive issue alias PreToolUse matcher'
require_contract_text .codex/hooks.json '\[Pp\].*\[Uu\].*\[Ll\].*\[Ll\].*\[Rr\].*\[Ee\].*\[Qq\].*\[Uu\].*\[Ee\].*\[Ss\].*\[Tt\]' 'case-insensitive pull-request alias PreToolUse matcher'
require_contract_text .codex/hooks.json '\[Ll\].*\[Aa\].*\[Bb\].*\[Ee\].*\[Ll\]' 'case-insensitive label alias PreToolUse matcher'
hook_matcher="$(jq -r '.hooks.PreToolUse[0].matcher' .codex/hooks.json)"
for aliased_github_tool in \
  gh_pr_merge \
  gh_update_issue \
  issue_update \
  ISSUE_UPDATE \
  hostIssueUpdate \
  hostISSUEUpdate \
  hostGetProfile \
  hostPullRequestMerge \
  PULLREQUESTMERGE \
  project_update \
  connector_call \
  connector_update \
  dispatcher \
  execute \
  executor \
  run \
  foo_execute \
  foo_run \
  foo.execute \
  serviceRun \
  provider_do \
  providerDo \
  host_mutate \
  hostMutate \
  api_write \
  apiWrite \
  providerProjectUpdate \
  hostProjectUpdate \
  connectorProjectUpdate \
  apiProjectUpdate \
  add_project_item \
  update_project_item \
  create_label \
  add_labels \
  get_project \
  list_project_items \
  get_label \
  list_labels
do
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
for deferred_followup_contract in \
  .codex/agents/pr-review-resolver.toml \
  .agents/skills/pr-review-resolution/SKILL.md \
  .agents/skills/pr-review-resolution/references/resolution-workflow.md \
  .agents/skills/pr-review-resolution/references/templates.md
do
  require_contract_text "$deferred_followup_contract" 'body_markdown' 'structured complete follow-up body'
  require_contract_text "$deferred_followup_contract" 'path.*null|null.*path' 'resolver null draft path'
  require_contract_text "$deferred_followup_contract" 'do not.*(write|create).*(file|/tmp)|never creates.*file|performs no file' 'resolver file delegation boundary'
done
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

claim_prepare_output="$(python3 scripts/check-cloud-queue-contract.py \
  --issues-file .agents/fixtures/backlog/cloud-claim-prepare.json \
  --operation claim --issue 3 --run-id run-3 --event-id delivery-3 \
  --executor cloud --plan-revision plan-3 \
  --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --lease-owner cloud:executor)"
printf '%s\n' "$claim_prepare_output" | jq -e '
  .type == "cloud_queue_contract"
  and .data.status == "persist"
  and .data.issue == 3
  and .data.before == "ready"
  and .data.transition_required == false
  and .data.claim_record.issue == 3
  and .data.claim_record.lease.owner == "cloud:executor"
  and (.data.issue_comment_marker | startswith("<!-- rpm-agent-claim: "))
' >/dev/null
claim_comment_marker="$(printf '%s\n' "$claim_prepare_output" | jq -r '.data.issue_comment_marker')"
claim_prepare_token="$(printf '%s\n' "$claim_prepare_output" | jq -r '.data.authorization_token')"

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
  and .data.transition_required == true
  and .data.recovery == {
    state:"ready",
    resumed:false,
    evidence:["durable-claim-record","exact-persistence-marker","refetched-runs-ledger"]
  }
  and .data.lease.owner == "cloud:executor"
  and .data.preserved_labels == ["priority:high"]
' >/dev/null
claim_token="$(printf '%s\n' "$claim_output" | jq -r '.data.authorization_token')"

claim_restart_output="$(python3 scripts/check-cloud-queue-contract.py \
  --issues-file .agents/fixtures/backlog/cloud-claim-restart.json \
  --operation claim --issue 3 --run-id run-3 --event-id delivery-3 \
  --executor cloud --plan-revision plan-3 \
  --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --lease-owner cloud:executor)"
printf '%s\n' "$claim_restart_output" | jq -e '
  .type == "cloud_queue_contract"
  and .data.status == "claim"
  and .data.issue == 3
  and .data.before == "claimed"
  and .data.after == "claimed"
  and .data.transition_required == false
  and .data.recovery.state == "claimed"
  and .data.recovery.resumed == true
' >/dev/null

set +e
active_lease_output="$(python3 scripts/check-cloud-queue-contract.py \
  --issues-file .agents/fixtures/backlog/cloud-claim-active-lease.json \
  --operation claim --issue 3 --run-id run-3 --event-id delivery-new \
  --executor cloud --plan-revision plan-3 \
  --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --lease-owner cloud:executor)"
active_lease_code=$?
set -e
[ "$active_lease_code" -eq 1 ]
printf '%s\n' "$active_lease_output" | jq -e '
  .type == "cloud_queue_contract"
  and .data.status == "blocked"
  and .data.reason == "claim-record-lease-conflict"
  and .data.conflicting_event_id == "delivery-old"
' >/dev/null

set +e
invalid_identifier_output="$(python3 scripts/check-cloud-queue-contract.py \
  --issues-file .agents/fixtures/backlog/cloud-claim-invalid-identifier.json \
  --operation claim --issue 3 --run-id run-3 --event-id delivery-3 \
  --executor cloud --plan-revision 'plan revision 3' \
  --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --lease-owner cloud:executor)"
invalid_identifier_code=$?
set -e
[ "$invalid_identifier_code" -eq 1 ]
printf '%s\n' "$invalid_identifier_output" | jq -e '
  .type == "cloud_queue_contract"
  and .data.status == "blocked"
  and .data.reason == "invalid-execution-identifier:plan_revision"
' >/dev/null

for invalid_claim_fixture in cloud-claim-conflict.json cloud-claim-malformed.json; do
  set +e
  invalid_claim_output="$(python3 scripts/check-cloud-queue-contract.py \
    --issues-file "$fixture_dir/$invalid_claim_fixture" \
    --operation claim --issue 3 --run-id run-3 --event-id delivery-3 \
    --executor cloud --plan-revision plan-3 \
    --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --lease-owner cloud:executor)"
  invalid_claim_code=$?
  set -e
  [ "$invalid_claim_code" -eq 1 ]
  printf '%s\n' "$invalid_claim_output" | jq -e '
    .type == "cloud_queue_contract"
    and .data.status == "blocked"
    and (.data.reason | type) == "string"
  ' >/dev/null
done

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
probe_hook_tool 'pull-request resource read' 0 'github_get_pull_request' '{}'
probe_hook_tool 'issue comments read' 0 'github_get_issue_comments' '{}'
probe_hook_tool 'list issue comments read' 0 'github_list_issue_comments' '{}'
probe_hook_tool 'non-prefixed GitHub mutation' 2 'github_update_issue' '{"issue_number":202,"body":"changed"}'
probe_hook_tool 'camelCase GitHub read' 0 'githubGetIssue' '{}'
probe_hook_tool 'camelCase GitHub mutation' 2 'githubUpdateIssue' '{"issue_number":202,"body":"changed"}'
probe_hook_tool 'gh alias merge' 2 'gh_pr_merge' '{"pr_number":202}'
probe_hook_tool 'gh alias issue mutation' 2 'gh_update_issue' '{"issue_number":202,"body":"changed"}'
probe_hook_tool 'bare issue mutation' 2 'issue_update' '{"issue_number":202,"body":"changed"}'
probe_hook_tool 'uppercase issue mutation' 2 'ISSUE_UPDATE' '{"issue_number":202,"body":"changed"}'
probe_hook_tool 'host camel issue mutation' 2 'hostIssueUpdate' '{"issue_number":202,"body":"changed"}'
probe_hook_tool 'generic connector dispatcher' 2 'connector_call' '{"service":"github","operation":"update_issue","issue_number":202}'
probe_hook_tool 'provider-neutral connector update' 2 'connector_update' '{"service":"github","issue_number":202}'
probe_hook_tool 'bare generic dispatcher alias' 2 'dispatcher' '{"service":"github","operation":"update_issue","issue_number":202}'
probe_hook_tool 'generic dispatch alias' 2 'foo_dispatch' '{"service":"github","operation":"update_issue","issue_number":202}'
probe_hook_tool 'bare generic dispatcher' 2 'execute' '{"service":"github","operation":"update_issue","issue_number":202}'
probe_hook_tool 'bare generic executor' 2 'executor' '{"service":"github","operation":"update_issue","issue_number":202}'
probe_hook_tool 'bare generic run' 2 'run' '{"service":"github","operation":"update_issue","issue_number":202}'
probe_hook_tool 'generic execute alias' 2 'foo_execute' '{"service":"github","operation":"update_issue","issue_number":202}'
probe_hook_tool 'generic run alias' 2 'foo_run' '{"service":"github","operation":"update_issue","issue_number":202}'
probe_hook_tool 'generic dotted alias' 2 'foo.execute' '{"service":"github","operation":"update_issue","issue_number":202}'
probe_hook_tool 'generic camel run alias' 2 'serviceRun' '{"service":"github","operation":"update_issue","issue_number":202}'
probe_hook_tool 'provider-neutral do alias' 2 'provider_do' '{"service":"github","issue_number":202}'
probe_hook_tool 'provider-neutral camel do alias' 2 'providerDo' '{"service":"github","issue_number":202}'
probe_hook_tool 'provider-neutral mutate alias' 2 'host_mutate' '{"service":"github","issue_number":202}'
probe_hook_tool 'provider-neutral camel mutate alias' 2 'hostMutate' '{"service":"github","issue_number":202}'
probe_hook_tool 'provider-neutral write alias' 2 'api_write' '{"service":"github","issue_number":202}'
probe_hook_tool 'provider-neutral camel write alias' 2 'apiWrite' '{"service":"github","issue_number":202}'
probe_hook_tool 'provider-neutral dedicated read alias' 0 'hostGetProfile' '{}'
probe_hook_tool 'provider-neutral read alias mutation override' 2 'hostGetProfile' '{"operation":"update","issue_number":202,"body":"changed"}'
for project_mutation_alias in \
  providerProjectUpdate \
  hostProjectUpdate \
  connectorProjectUpdate \
  apiProjectUpdate
do
  probe_hook_tool_as_role 'rpm_issue_refiner' \
    "$project_mutation_alias project mutation denied" 2 "$project_mutation_alias" \
    '{"project_id":"pwn","body":"changed","labels":["agent:ready"]}'
done
for namespace_free_mutation in \
  add_project_item \
  addProjectItem \
  project.add_item \
  update_project_item \
  updateProjectItem \
  create_label \
  createLabel \
  label.create \
  add_labels \
  addLabels
do
  probe_hook_tool "$namespace_free_mutation namespace-free mutation denied" 2 \
    "$namespace_free_mutation" \
    '{"issue_number":202,"project_id":"pwn","labels":["agent:ready"]}'
done
for namespace_free_read in \
  get_project \
  list_project_items \
  get_label \
  list_labels
do
  probe_hook_tool "$namespace_free_read namespace-free read allowed" 0 \
    "$namespace_free_read" '{}'
done
probe_hook_tool_as_role 'rpm_issue_refiner' \
  'issue refiner namespace-free label creation denied' 2 'create_label' \
  '{"name":"agent:pwn","color":"000000"}'
probe_hook_tool_as_role 'rpm_issue_refiner' \
  'issue refiner namespace-free additive labels denied' 2 'add_labels' \
  '{"issue_number":202,"labels":["agent:ready"]}'
probe_hook_tool_as_role 'rpm_idea_issue_creator' \
  'idea creator opaque project id denied' 2 'add_project_item' \
  '{"project_id":"pwn","content_id":"pwn"}'
probe_hook_tool_as_role 'rpm_idea_issue_creator' \
  'idea creator configured project registration allowed' 0 'add_project_item' \
  '{"project_number":7,"issue_number":202,"repository":"nerdchanii/rpm","owner":"@me"}'
probe_hook_tool_as_role 'rpm_idea_issue_creator' \
  'idea creator configured project registration extra field denied' 2 \
  'add_project_item' \
  '{"project_number":7,"issue_number":202,"repository":"nerdchanii/rpm","owner":"@me","labels":["agent:ready"]}'
probe_hook_tool 'curl raw GitHub mutation' 2 'exec_command' '{"cmd":"curl -X PATCH https://api.github.com/repos/nerdchanii/rpm/issues/202"}'
probe_hook_tool 'wget raw GitHub mutation' 2 'exec_command' '{"cmd":"wget --method=POST https://api.github.com/repos/nerdchanii/rpm/issues/202"}'
probe_hook_tool 'HTTPie raw GitHub mutation' 2 'exec_command' '{"cmd":"http PATCH https://api.github.com/repos/nerdchanii/rpm/issues/202"}'
probe_hook_tool 'Python raw GitHub mutation' 2 'exec_command' '{"cmd":"python3 -c \"import urllib.request; urllib.request.urlopen(\\\"https://api.github.com/repos/nerdchanii/rpm/issues/202\\\")\""}'
probe_hook_tool 'Node raw GitHub mutation' 2 'exec_command' '{"cmd":"node -e \"fetch(\\\"https://api.github.com/repos/nerdchanii/rpm/issues/202\\\")\""}'
probe_hook_tool 'Python dynamic-host raw mutation' 2 'exec_command' '{"cmd":"python3 -c \"import urllib.request,os; urllib.request.urlopen(os.environ[\\\"TARGET\\\"], data=b[\\\"mutation\\\"])\""}'
probe_hook_tool 'Node dynamic-host raw mutation' 2 'exec_command' '{"cmd":"node -e \"fetch(process.env.TARGET, {method: \\\"POST\\\"})\""}'
probe_hook_tool 'Python benign inline command' 0 'exec_command' '{"cmd":"python3 -c \"print(1 + 1)\""}'
probe_hook_tool 'Node benign inline command' 0 'exec_command' '{"cmd":"node -e \"console.log(1 + 1)\""}'
probe_hook_tool 'nested shell curl raw GitHub mutation' 2 'exec_command' '{"cmd":"sh -c \"curl -X PATCH https://api.github.com/repos/nerdchanii/rpm/issues/202\""}'
probe_hook_tool 'nested bash curl raw GitHub mutation' 2 'exec_command' '{"cmd":"bash -c \"curl -X PATCH https://api.github.com/repos/nerdchanii/rpm/issues/202\""}'
probe_hook_tool 'xargs curl raw GitHub mutation' 2 'exec_command' '{"cmd":"printf %s https://api.github.com/repos/nerdchanii/rpm/issues/202 | xargs curl -X PATCH"}'
probe_hook_tool 'sudo curl raw GitHub mutation' 2 'exec_command' '{"cmd":"sudo curl -X PATCH https://api.github.com/repos/nerdchanii/rpm/issues/202"}'
probe_hook_tool 'git push raw network mutation' 2 'exec_command' '{"cmd":"git push origin HEAD"}'
probe_hook_tool 'git fetch raw network fallback' 2 'exec_command' '{"cmd":"git fetch origin"}'
probe_hook_tool 'git clone raw network fallback' 2 'exec_command' '{"cmd":"git clone https://github.com/nerdchanii/rpm.git"}'
probe_hook_tool 'git remote update raw network fallback' 2 'exec_command' '{"cmd":"git remote update"}'
probe_hook_tool 'git submodule update raw network fallback' 2 'exec_command' '{"cmd":"git submodule update --remote"}'
probe_hook_tool 'git archive remote raw network fallback' 2 'exec_command' '{"cmd":"git archive --remote=origin HEAD"}'
probe_hook_tool 'gh api implicit POST issue create' 2 'exec_command' '{"cmd":"gh api repos/nerdchanii/rpm/issues -f title=pwn -f body=pwn"}'
probe_hook_tool 'gh api implicit POST issue edit' 2 'exec_command' '{"cmd":"gh api repos/nerdchanii/rpm/issues/202 -f body=pwn"}'
probe_hook_tool 'gh api raw-field implicit POST' 2 'exec_command' '{"cmd":"gh api repos/nerdchanii/rpm/issues/202 --raw-field labels[]=agent:claimed"}'
probe_hook_tool 'SSH raw network mutation' 2 'exec_command' '{"cmd":"ssh git@github.com receive-pack nerdchanii/rpm"}'
probe_hook_tool 'netcat raw network mutation' 2 'exec_command' '{"cmd":"nc api.github.com 443"}'
probe_hook_tool 'OpenSSL raw network mutation' 2 'exec_command' '{"cmd":"openssl s_client -connect api.github.com:443"}'
probe_hook_tool 'Bash TCP raw network mutation' 2 'exec_command' '{"cmd":"printf x > /dev/tcp/api.github.com/443"}'
probe_hook_tool 'Ruby raw GitHub mutation' 2 'exec_command' '{"cmd":"ruby -e \"TCPSocket.new(\\\"api.github.com\\\", 443)\""}'
probe_hook_tool 'local git status remains shell-safe' 0 'exec_command' '{"cmd":"git status --short"}'
probe_hook_tool 'plain HTTPS text remains local-shell-safe' 0 'exec_command' '{"cmd":"printf %s https://example.com"}'
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
claim_comment_input="$(jq -nc --arg body "$claim_comment_marker" \
  '{issue_number:3,body:$body}')"
claim_comment_create_input="$(jq -nc --arg body "$claim_comment_marker" \
  '{owner:"nerdchanii",repo:"rpm",issue_number:3,body:$body}')"
claim_comment_tampered_input="$(jq -nc --arg body "$claim_comment_marker" \
  '{issue_number:3,body:($body | sub("delivery-3";"delivery-pwn"))}')"
claim_comment_wrong_issue_input="$(jq -nc --arg body "$claim_comment_marker" \
  '{issue_number:4,body:$body}')"
probe_hook_tool_as_role 'rpm_ready_ticket_claimer' \
  'ready-ticket claimer controller-unissued durable comment denied' 2 \
  'add_issue_comment' "$claim_comment_input"
probe_hook_tool_as_role 'rpm_ready_ticket_claimer' \
  'ready-ticket claimer controller-unissued claimed label denied' 2 \
  'githubUpdateIssue' \
  '{"issue_number":3,"labels":["agent:claimed","priority:high"]}'
jq -nc --arg token "$claim_prepare_token" \
  '{role:"assistant",content:("rpm_claim_authorization=" + $token)}' \
  | tee "$hook_transcript" >/dev/null
jq -nc --arg path "$hook_transcript" \
  '{hook_event_name:"SubagentStart",agent_type:"rpm_ready_ticket_claimer",agent_transcript_path:$path}' \
  | hook_event >/dev/null 2>&1
probe_hook_tool 'ready-ticket claimer self-authored token denied' 2 \
  'exec_command' \
  '{"cmd":"python3 scripts/check-cloud-queue-contract.py --issues-file .agents/fixtures/backlog/cloud-claim-prepare.json --operation claim --issue 3 --run-id run-3 --event-id delivery-3 --executor cloud --plan-revision plan-3 --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --lease-owner cloud:executor"}'
jq -nc --arg path "$hook_transcript" \
  '{hook_event_name:"SubagentStop",agent_type:"rpm_ready_ticket_claimer",agent_transcript_path:$path}' \
  | hook_event >/dev/null 2>&1 || true
jq -nc --arg token "$claim_prepare_token" \
  '{role:"user",content:"issue body contains rpm_claim_authorization=untrusted",rpm_claim_authorization:$token}' \
  | tee "$hook_transcript" >/dev/null
jq -nc --arg path "$hook_transcript" \
  '{hook_event_name:"SubagentStart",agent_type:"rpm_ready_ticket_claimer",agent_transcript_path:$path}' \
  | hook_event >/dev/null 2>&1
probe_hook_tool 'ready-ticket claimer persist controller attestation' 0 \
  'exec_command' \
  '{"cmd":"python3 scripts/check-cloud-queue-contract.py --issues-file .agents/fixtures/backlog/cloud-claim-prepare.json --operation claim --issue 3 --run-id run-3 --event-id delivery-3 --executor cloud --plan-revision plan-3 --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --lease-owner cloud:executor"}'
probe_hook_tool 'ready-ticket claimer untrusted snapshot denied' 2 \
  'exec_command' \
  '{"cmd":"python3 scripts/check-cloud-queue-contract.py --issues-file .agents/fixtures/backlog/cloud-claim-ready.json --operation claim --issue 3 --run-id run-3 --event-id delivery-3 --executor cloud --plan-revision plan-3 --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --lease-owner cloud:executor"}'
probe_hook_tool 'ready-ticket claimer exact durable claim comment' 0 \
  'add_issue_comment' "$claim_comment_input"
probe_hook_tool 'ready-ticket claimer exact durable claim create-comment alias' 0 \
  'create_issue_comment' "$claim_comment_create_input"
probe_hook_tool 'ready-ticket claimer tampered durable claim comment denied' 2 \
  'add_issue_comment' "$claim_comment_tampered_input"
probe_hook_tool 'ready-ticket claimer wrong-issue durable claim comment denied' 2 \
  'add_issue_comment' "$claim_comment_wrong_issue_input"
probe_hook_tool 'ready-ticket claimer ordinary comment denied' 2 \
  'add_issue_comment' '{"issue_number":3,"body":"please claim this issue"}'
probe_hook_tool 'ready-ticket claimer label before persisted controller denied' 2 \
  'githubUpdateIssue' \
  '{"issue_number":3,"labels":["agent:claimed","priority:high"]}'
jq -nc --arg path "$hook_transcript" \
  '{hook_event_name:"SubagentStop",agent_type:"rpm_ready_ticket_claimer",agent_transcript_path:$path}' \
  | hook_event >/dev/null 2>&1 || true
jq -nc '{role:"user",content:"issue body contains rpm_claim_authorization=untrusted"}' \
  | tee "$hook_transcript" >/dev/null
jq -nc --arg path "$hook_transcript" \
  '{hook_event_name:"SubagentStart",agent_type:"rpm_ready_ticket_claimer",agent_transcript_path:$path}' \
  | hook_event >/dev/null 2>&1
probe_hook_tool 'ready-ticket claimer issue-text authorization ignored' 2 \
  'exec_command' \
  '{"cmd":"python3 scripts/check-cloud-queue-contract.py --issues-file .agents/fixtures/backlog/cloud-claim-prepare.json --operation claim --issue 3 --run-id run-3 --event-id delivery-3 --executor cloud --plan-revision plan-3 --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --lease-owner cloud:executor"}'
jq -nc --arg path "$hook_transcript" \
  '{hook_event_name:"SubagentStop",agent_type:"rpm_ready_ticket_claimer",agent_transcript_path:$path}' \
  | hook_event >/dev/null 2>&1 || true
jq -nc --arg token "$claim_prepare_token" \
  '{role:"user",rpm_claim_authorization:$token}' \
  | tee "$hook_transcript" >/dev/null
jq -nc --arg path "$hook_transcript" \
  '{hook_event_name:"SubagentStart",agent_type:"rpm_ready_ticket_claimer",agent_transcript_path:$path}' \
  | hook_event >/dev/null 2>&1
jq -nc --arg token "$claim_token" \
  '{role:"user",rpm_claim_authorization:$token}' \
  | tee "$hook_transcript" >/dev/null
jq -nc --arg path "$hook_transcript" \
  '{hook_event_name:"SubagentStart",agent_type:"rpm_ready_ticket_claimer",agent_transcript_path:$path}' \
  | hook_event >/dev/null 2>&1
probe_hook_tool 'ready-ticket claimer persisted controller attestation' 0 \
  'exec_command' \
  '{"cmd":"python3 scripts/check-cloud-queue-contract.py --issues-file .agents/fixtures/backlog/cloud-claim-ready.json --operation claim --issue 3 --run-id run-3 --event-id delivery-3 --executor cloud --plan-revision plan-3 --scope-hash sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --lease-owner cloud:executor"}'
probe_hook_tool 'ready-ticket claimer exact claimed label' 0 'githubUpdateIssue' \
  '{"issue_number":3,"labels":["agent:claimed","priority:high"]}'
jq -nc --arg path "$hook_transcript" \
  '{hook_event_name:"SubagentStop",agent_type:"rpm_ready_ticket_claimer",agent_transcript_path:$path}' \
  | hook_event >/dev/null 2>&1 || true
printf '%s\n' "$hook_start_payload" | hook_event >/dev/null
probe_hook_tool_as_role 'rpm_ready_ticket_claimer' \
  'ready-ticket claimer ready label denied' 2 'githubUpdateIssue' \
  '{"issue_number":202,"labels":["agent:ready"]}'
probe_hook_tool_as_role 'rpm_ready_ticket_claimer' \
  'ready-ticket claimer empty labels denied' 2 'githubUpdateIssue' \
  '{"issue_number":202,"labels":[]}'
probe_hook_tool_as_role 'rpm_ready_ticket_claimer' \
  'ready-ticket claimer claimed marker outside labels denied' 2 'githubUpdateIssue' \
  '{"issue_number":202,"owner":"agent:claimed","repo":"rpm","labels":[]}'
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
  'review resolver scripts gate patch' 2 'apply_patch' \
  '{"patch":"*** Begin Patch\n*** Update File: scripts/check-merge-gate.py\n*** End Patch\n"}'
probe_hook_tool_as_role 'pr-review-resolver' \
  'review resolver justfile gate patch' 2 'apply_patch' \
  '{"patch":"*** Begin Patch\n*** Update File: justfile\n*** End Patch\n"}'
probe_hook_tool_as_role 'pr-review-resolver' \
  'review resolver git hook patch' 2 'apply_patch' \
  '{"patch":"*** Begin Patch\n*** Update File: .githooks/pre-commit\n*** End Patch\n"}'
probe_hook_tool_as_role 'pr-review-resolver' \
  'review resolver ordinary source patch allowed' 0 'apply_patch' \
  '{"patch":"*** Begin Patch\n*** Update File: src/lib.rs\n*** End Patch\n"}'
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

jq -e --argjson canonical_claim "$(printf '%s\n' "$claim_output" | jq '.data')" '
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
    and .input.claim_result == {
      type:"ready_ticket_claim_result",
      data:{
        status:"claimed",
        issue:.input.issue,
        before_state:$canonical_claim.before,
        after_state:$canonical_claim.after,
        claim_contract:$canonical_claim,
        preserved_labels:$canonical_claim.preserved_labels,
        verified:true,
        race_evidence:[],
        blockers:[]
      }
    }
    and .input.claim_result.data.claim_contract.transition_required == true
    and .input.claim_result.data.claim_contract.claim_record.idempotency_key
      == .input.claim_result.data.claim_contract.idempotency_key
    and .input.claim_result.data.claim_contract.claim_record.lease
      == .input.claim_result.data.claim_contract.lease
    and .input.claim_result.data.claim_contract.recovery.resumed == false
    and (.input.claim_result.data.claim_contract.issue_comment_marker
      | startswith("<!-- rpm-agent-claim: "))
    and .expected_status == "complete"
  )
  and any(.[];
    .mode == "explicit"
    and .input.claim_state == "ready"
    and .input.controller_status == "claim"
    and .input.claim_result_issue == .input.issue
    and .input.claim_result.type == "ready_ticket_claim_result"
    and .input.claim_result.data.status == "claimed"
    and .input.claim_result.data.issue == .input.issue
    and .input.claim_result.data.claim_contract.status == "claim"
    and .input.claim_result.data.claim_contract.transition_required == true
    and (.input.claim_result.data.claim_contract.claim_record.lease.expires_at | type) == "string"
    and .input.controller_authorization.phase == "claim"
    and .input.controller_authorization.issue == .input.issue
    and .input.durable_record.idempotency_key == .input.idempotency_key
    and (.input.marker | startswith("<!-- rpm-agent-claim: "))
    and .input.transition_required == true
    and (.input.timestamped_lease.expires_at | type) == "string"
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
