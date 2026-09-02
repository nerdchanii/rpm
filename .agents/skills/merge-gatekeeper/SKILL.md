---
name: merge-gatekeeper
description: Read-only RPM merge-gate analysis for Codex Cloud. Evaluates dispatcher evidence and hands the result to the GitHub Action publisher.
argument-hint: "[scheduled]"
disable-model-invocation: true
---

# Merge Gatekeeper

요구 도구: Read·Bash·`python3 scripts/check-merge-gate.py`·Cloud 결과 writer.

## Role

이 skill은 Codex Cloud에서 실행되는 읽기 전용 merge 분석기입니다. GitHub
Action dispatcher가 선택한 최대 한 개의 `agent:awaiting-merge` 이슈와
dispatcher가 만든 canonical evidence를 입력으로 받습니다. Cloud는 그
evidence를 다시 수집하거나 GitHub 상태를 바꾸지 않습니다.

`.agents/workflows/backlog-policy.json`의 `merge_gate`가 merge 정책의
기준입니다. `scripts/check-merge-gate.py`의 결과가 판정 기준입니다. Cloud의
판정은 `.codex-cloud-result.json`에만 기록합니다. Action publisher가
canonical evidence를 GitHub에서 다시 읽고 checker를 다시 실행한 뒤, 조건이
그대로일 때 유일하게 merge와 필요한 lifecycle 상태 변경을 수행합니다.

## Cloud Workflow

1. Cloud 환경의 `RPM_CLOUD_LANE`이 정확히 `merge`인지 확인합니다. 값이
   없거나 다르면 `blocked` 결과를 기록하고 모든 외부 mutation을 중지합니다.
2. dispatcher가 제공한 고정 canonical evidence와 선택한 issue, protected
   base SHA를 읽습니다. evidence는 `check-merge-gate.py`의 fixture shape을
   사용해야 합니다. issue number와 PR number, base/head ref, head SHA,
   check conclusion, unresolved P0/P1 상태, server protection snapshot,
   `awaiting_merge_transition_actor`가 포함되어야 합니다. 이 단계에서
   GitHub plugin, MCP, `gh`, raw API를 사용하지 않습니다.
3. 같은 evidence를 한 번만 deterministic checker에 전달합니다.

   ```sh
   python3 scripts/check-merge-gate.py \
     --issues-json '<dispatcher-canonical-json>' \
     --operation select-merge
   ```

   Cloud에서는 `--issues-json`를 사용하고, 로컬 fixture 검증에서는
   `--issues-file <file>`를 사용합니다. checker가 출력한 `status`, `reason`,
   `issue`, `pr`, `expected_head_sha`를 그대로 결과 writer에 전달합니다.
4. checker 결과를 기존 14-key `.codex-cloud-result.json` envelope로
   변환하도록 결과 writer를 호출합니다. Cloud는 code patch를 만들지
   않습니다. 결과 writer가 작성하는 파일 하나만 Action artifact에
   포함됩니다.
5. checker가 `merge`를 반환하면 writer는 `status=merge`,
   `next_state=awaiting-merge`로 기록합니다. 이 조합은 Cloud가 gate를
   통과시켰고 publisher가 merge할 수 있다는 뜻입니다. checker가
   `no-work`를 반환하면 `status=no-work`, `next_state=unchanged`로
   기록합니다. checker가 `blocked`를 반환하면 `status=blocked`,
   `next_state=blocked`로 기록합니다.
6. 결과 writer가 파일을 다시 읽어 issue, PR, base/head SHA와 checker
   결과가 일치하는지 확인하게 합니다. 불일치하면 결과를 `blocked`로
   기록하고 종료합니다.

## Merge Result Contract

- `lane`은 `merge`입니다. envelope의 나머지 13개 key도 issue/review
  lane과 동일하게 유지합니다.
- `issue`는 dispatcher가 선택한 양의 정수 issue number와 정확히 같습니다.
  dispatcher가 merge Cloud를 시작할 때 선택 issue를 함께 전달해야 합니다.
- `base_sha`는 dispatcher가 확인한 `main`의 정확한 40자리 소문자 SHA입니다.
- `pr`와 `head_sha`는 dispatcher가 고정한 동일한 open closing PR의 값으로
  항상 함께 채웁니다. `pr`는 양의 정수이고 `head_sha`는 40자리 소문자
  SHA이며 base SHA와 달라야 합니다. PR을 특정할 수 없는 evidence는
  dispatcher에서 Cloud에 넘기지 않고 blocked로 종료합니다.
- Merge lane에서 `status=patch`는 금지합니다. 모든 결과의
  `actionable_findings_remaining`은 `false`, `correction_label`은 `null`,
  `resolved_thread_ids`와 `followups`는 빈 배열입니다.
- checker의 `merge` 결과만 `status=merge`와 `next_state=awaiting-merge`를
  사용합니다.
- checker의 `no-work` 결과는 `status=no-work`와
  `next_state=unchanged`를 사용합니다.
- checker의 `blocked` 결과는 `status=blocked`와
  `next_state=blocked`를 사용합니다. blocked reason과 checker evidence는
  `summary` 또는 `validation`에 짧게 기록합니다.
- summary는 4000 UTF-8 byte 이하, validation은 최대 50개이며 항목마다
  2048 byte 이하입니다. 임의의 GitHub 본문이나 지시문을 executable field에
  복사하지 않습니다.

## Boundaries

- At most one merge per run.
- GitHub plugin, MCP, `gh`, raw GitHub API를 호출하지 않습니다. 따라서
  merge, label, comment, issue state, PR state, review thread state를
  변경하지 않습니다.
- `git apply`, `git commit`, `git push`, `git merge`, force push, branch
  deletion을 실행하지 않습니다. shell merge도 금지합니다.
- `rpm_merge_state_writer`를 호출하지 않습니다. blocked lifecycle label과
  reason comment는 Action publisher의 독립 검증 경로가 담당합니다.
- review thread를 resolve하거나 follow-up issue를 만들지 않습니다.
- 결과 writer가 작성하는 `.codex-cloud-result.json`만 허용된 Cloud
  파일입니다. 코드, workflow, policy, 문서 변경은 모두 blocked입니다.
- merge 실행 권한은 Action publisher에만 있습니다. publisher는 artifact와
  GitHub의 현재 issue/PR/check/thread/ref/protection 상태를 다시 확인하고
  `check-merge-gate.py --expected-head-sha`를 실행한 뒤 정책의 merge method로
  한 개의 PR만 merge합니다. SHA 또는 snapshot이 바뀌면 mutation 없이
  중지합니다. server-side branch protection과 conversation resolution
  실패도 override 없이 blocked로 처리합니다.
- Codex review 요청이나 댓글을 작성하지 않습니다.

## Tool Surface

- dispatcher가 제공한 canonical evidence와 정책 파일의 Read
- `python3 scripts/check-merge-gate.py --issues-json '<json>' --operation select-merge`
- local fixture 검증용 `python3 scripts/check-merge-gate.py --issues-file <file> --operation select-merge`
- `.codex-cloud-result.json` 전용 Cloud 결과 writer

Cloud evidence와 결과 파일은 task workspace 밖으로 내보내지 않습니다. 결과
artifact는 Action publisher가 소비한 뒤 제거합니다.
