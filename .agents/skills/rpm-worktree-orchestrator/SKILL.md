---
name: rpm-worktree-orchestrator
description: Explicit RPM-only coordinator for decomposing a local or already-authorized issue task into isolated worktree workers, integrating their results, and preserving RPM lifecycle ownership.
argument-hint: "[local <objective> | issue <number-or-url>]"
disable-model-invocation: true
---

# RPM Worktree Orchestrator

RPM에서만 사용하는 명시적 coordinator입니다. 메인 세션이 DAG와 최종 통합을
소유하고, 독립적인 작업 node를 격리된 worktree thread에 배정합니다. 이
스킬은 RPM의 issue lifecycle, Project, PR, merge 정책을 대체하지 않습니다.

## 진입 모드

- `local <objective>`: 사용자가 선택한 RPM 로컬 작업을 분해합니다. 기본적으로
  GitHub issue·label·PR·push mutation을 수행하지 않습니다.
- `issue <number-or-url>`: 이미 사용자가 선택했거나 `$take-ticket`이 권한을
  부여한 한 개의 issue 작업을 분해합니다. issue claim과 lifecycle 전이는
  `$take-ticket`과 정책 계약을 따릅니다.

다음 entrypoint의 scheduled 실행을 이 스킬로 재라우팅하지 않습니다.

- `$prepare-backlog`: Project #7 연구와 readiness
- `$take-ticket`: issue claim과 per-issue execution
- `$pr-review-resolution`: review-pending PR reconciliation
- `$merge-gatekeeper`: 유일한 일반 lifecycle merge

`safe-direct-merge`는 사용자 승인을 받은 lifecycle 외부 PR의 명시적 예외로
남깁니다. 이 스킬이나 worker가 merge를 호출하지 않습니다.

## RPM 권위와 사전 점검

항상 다음 순서로 확인합니다.

1. `AGENTS.md`, `.agents/workflows/backlog-policy.json`, 관련 SPEC·ADR와
   `.agents/docs/issue-agent-workflow.md`를 읽습니다.
2. `git status --short --branch`, `git rev-parse HEAD`,
   `git rev-parse --show-toplevel`을 기록합니다.
3. 현재 worktree가 dirty이면 기존 변경을 worker 기준 상태로 복제하지
   않습니다. clean 기준 commit에서 새 worktree를 만들고, 기존 변경을
   덮어쓰지 않습니다.
4. scheduled issue 실행은 `bash scripts/check-workflow-intake.sh`가 성공한
   경우에만 진행합니다. dirty, 권한 실패, intake 실패는 `blocked`입니다.

RPM 정책은 batch limit, lifecycle label, lease, idempotency, `scope_hash`,
`plan_revision`, executor를 최종 권위로 둡니다. DAG adapter가 이 값을
재정의하거나 label을 직접 바꾸지 않습니다.

## DAG와 worker 계약

계획은 `repository=nerdchanii/rpm`, `plan_revision`, `base_revision`,
`scope_hash`, `executor`, `required_gates`, `nodes`를 가집니다. 각 node에는
`id`, `objective`, `depends_on`, `role`, `write_paths`, `base_revision`,
`plan_revision`, `state`, `attempt`를 기록합니다. 통합된 node는 메인 세션이
검증한 통합 commit을 `integrated_revision`으로 기록합니다. 후속 node는
계획의 `base_revision` 또는 직접 의존하는 통합 node의 검증된
`integrated_revision`에서만 생성합니다. `required_gates`가 모두
성공해 `integrated`가 되기 전에는 전체 작업을 완료로 판정하지 않습니다.

허용 상태는 다음과 같습니다.

`pending -> ready -> running -> completed -> integrated`

실패·취소 node의 후속 node는 자동 실행하지 않고 `blocked` 또는 `cancelled`로
기록합니다. plan revision이나 scope가 바뀌면 기존 결과를 stale로 폐기하고
새 attempt를 만듭니다. 동일한 issue·revision·scope·executor를 중복 dispatch하지
않습니다.

write worker 프롬프트의 필수 필드는
[references/worker-contract.md](references/worker-contract.md)에 둡니다.

서로 겹치는 `write_paths`를 가진 write worker를 동시에 실행하지 않습니다.
순차 dependency로 연결된 node는 이전 결과를 통합한 뒤 같은 경로를 다시
소유할 수 있으며, 검증기는 순서 없는 동시 node의 overlap만 거부합니다.
read-only 조사·review worker는 변경을 만들지 않습니다. write worker는 자신의
worktree에서 local commit을 만들고 SHA와 기준 commit을 보고합니다. push,
PR, issue label, merge는 메인 세션 또는 해당 RPM entrypoint의 권한 범위입니다.

계획 파일을 만들었다면 다음 검증기를 실행합니다.

```bash
python3 .agents/skills/rpm-worktree-orchestrator/scripts/validate_plan.py <plan.json>
```

## Worktree 실행과 통합

저장소 worker는 가능한 경우 `codex_app__list_projects`로 RPM project와
`isGitRepository`를 확인한 뒤 `codex_app__create_thread`의 `worktree`
환경으로 생성합니다. 기준 branch/ref는 실제로 확인한 값만 사용합니다.
`clientThreadId`를 실제 `threadId`가 필요한 도구에 전달하지 않습니다.

준비된 worker마다 worktree path, repository root, HEAD, `base_revision`을
기록합니다. 결과를 받으면 메인 세션이 다음을 확인합니다.

- `PLAN_REVISION`과 `scope_hash`가 현재 계획과 일치하는지
- `git cat-file -e <sha>^{commit}`과
  `git merge-base --is-ancestor <base_revision> <sha>`가 성공하는지
- diff가 worker ownership에만 포함되는지
- 사용자 변경, conflict marker, `git ls-files -u`, `git diff --check`가
  안전한지

검증되지 않은 SHA, stale 결과, 다른 worktree의 dirty branch를 통합하지
않습니다. 메인 worktree가 clean하고 의도한 branch에 있을 때만 cherry-pick
또는 명시적으로 승인된 patch 방식으로 통합합니다. 각 wave 통합 뒤 관련
검증을 실행하고 최종적으로 `just validate`를 실행합니다.

## RPM pilot 완료 조건

- local pilot은 issue/PR/label mutation 없이 DAG dispatch·worker report·commit
  통합·검증을 재현합니다.
- issue pilot은 정확히 한 issue, 한 lease, 한 active worktree를 사용하며
  `scope_hash`와 `plan_revision`을 결과에 보존합니다.
- dirty worktree, stale revision, 중복 ownership, 실패 gate, missing
  dependency는 mutation 없이 `blocked`가 됩니다.
- review 경로는 `agent:awaiting-merge` 전환까지만 수행하고, merge는
  `$merge-gatekeeper`에 남깁니다.
- 최종 보고에는 node별 상태·worktree·commit, 실행한 검증, 실행하지 못한
  검증, 남은 위험을 구분해 기록합니다.

실제 thread를 만들지 못했거나 실행하지 않은 테스트를 통과로 보고하지
않습니다. worker thread와 임시 worktree는 지원되는 정리 수단으로 정리하고,
dirty worktree는 사용자의 확인 없이 삭제하지 않습니다.
