# Codex 자동 작업 연결

이 저장소의 GitHub Actions는 작업을 Cloud 실행과 Action 게시로 나눕니다.

1. GitHub runner가 `agent:ready`, `agent:review-pending`,
   `agent:awaiting-merge` 중 하나의 큐에서 번호가 가장 작은 이슈 하나를
   고릅니다.
2. runner가 고정된 요청을 `codex cloud exec`로 Codex Cloud에 제출하고 완료를
   기다립니다.
3. runner가 `codex cloud diff --attempt 1`로 결과를 내려받아 짧은 수명의
   artifact로 전달합니다.
4. 별도의 publisher job이 정확한 commit을 checkout하고 diff와 결과 파일을
   검증한 뒤 branch, PR, issue 상태를 게시합니다.

Issue와 Review Cloud job은 저장소를 checkout하지 않고 GitHub 읽기 권한과
`CODEX_ACCESS_TOKEN`만 가집니다. Merge Cloud job은 신뢰된 증거 수집 스크립트만
checkout합니다. 세 Cloud job 모두 GitHub 쓰기 권한이 없습니다. 실제 코드
작업은 Cloud에서 수행합니다. Publisher job은 Cloud token을 받지 않으며,
GitHub 쓰기 권한으로 검증된 결과만 게시합니다. Merge도 같은 artifact 경계를
사용합니다. Cloud는 읽기 전용 판단 결과를 만들고 Action publisher가 상태를
두 번 다시 읽은 뒤 정확한 PR head만 병합합니다.

## Cloud 설정

세 작업 차선은 서로 다른 GitHub Environment와 Codex Cloud 환경을 사용합니다.

| 차선 | GitHub Environment | Repository Variable | Codex Cloud 설정·유지 명령 |
| --- | --- | --- | --- |
| Issue | `codex-cloud-issue` | `CODEX_CLOUD_ISSUE_ENV_ID` | `bash scripts/setup-codex-cloud-lane.sh issue` |
| Review | `codex-cloud-review` | `CODEX_CLOUD_REVIEW_ENV_ID` | `bash scripts/setup-codex-cloud-lane.sh review` |
| Merge | `codex-cloud-merge` | `CODEX_CLOUD_MERGE_ENV_ID` | `bash scripts/setup-codex-cloud-lane.sh merge` |

각 GitHub Environment에 Secret `CODEX_ACCESS_TOKEN`을 설정합니다. 같은 이름의
secret을 세 Environment에서 사용해도 됩니다. 이 secret은 Cloud 작업 제출에
사용하는 인증 값입니다. 각 행의 Variable 값은 해당 Codex Cloud 환경 ID입니다.
Codex Cloud 환경 안에는 표의 차선과 같은 `RPM_CLOUD_LANE` 값도 설정해야
합니다. 표의 명령을 각 환경의 setup command와 maintenance command에 모두
넣습니다. 명령은 실제 Git 디렉터리에 권한 `0600`인 차선 marker를 만듭니다.
Hook는 marker와 환경 변수의 값이 정확히 같은지 매 도구 호출에서 확인합니다.

Merge Cloud 환경에는 GitHub connector를 설치하지 않습니다. Repository Secret
`RPM_AUTOMATION_GITHUB_TOKEN`에는 저장소 하나로 범위를 제한한 fine-grained PAT를
설정합니다. Issue와 Review publisher는 이 token으로 branch push와 PR 변경을
수행합니다. PR이 열리거나 갱신되면 `Rust`와 `PR Metadata` 검사가 실행되고,
검사 완료의 `workflow_run`이 보호된 main Workflow에서 Review·Merge 차선을 다시
확인합니다. 5분 schedule도 같은 큐를 확인합니다. Secret이 없으면 두 publisher는
안전하게 실패합니다. 최소 권한은 Contents write, Issues write, Pull requests
write, Administration read입니다.
Workflow write 권한은 부여하지 않습니다.

`main` 보호 규칙은 `metadata`와 `verify`를 GitHub Actions App ID `15368`의
필수 검사로 고정해야 합니다. 최신 base를 요구하는 strict checks, 대화 해결
필수, 관리자 적용, force push 금지, branch 삭제 금지도 켭니다. merge queue와
auto-merge는 끕니다. PAT에는 Administration write, ruleset 변경, 보호 규칙
우회 권한을 부여하지 않습니다. Publisher는 이 설정을 매 병합 전에 확인합니다.

별도 GitHub Environment `codex-cloud-merge-publisher`에서도 같은 Secret을
사용합니다. Merge collector가 branch protection을 읽고 publisher가 exact-head
merge를 수행할 수 있어야 합니다. 이 환경에는 `CODEX_ACCESS_TOKEN`을 넣지
않습니다. Secret은 repository secret으로 두거나 `codex-cloud-merge`
Environment에도 같은 값을 설정합니다. 수집 step이 끝나면 token을 해제하며
Codex Cloud에는 전달하지 않습니다.

저장소 Variable `CODEX_CLOUD_AUTOMATION_ENABLED`는 Issue와 Review 차선의 자동
시작 스위치입니다. 값이 `true`가 되기 전에는 schedule과 GitHub 이벤트가 두
차선의 Cloud 작업을 제출하지 않습니다. 보호된 main Workflow를 사용하는
`repository_dispatch` 수동 실행은 이 값과 관계없이 사용할 수 있습니다.

자동 병합은 별도 Variable `CODEX_CLOUD_AUTO_MERGE_ENABLED`로 잠급니다. Merge
selector는 수동 요청을 포함해 이 값이 정확히 `true`일 때만 시작합니다. 실제
branch protection, 필수 검사 App ID, 대화 해결 규칙, 사용자 정의 P1 판정의
서버 강제를 확인하기 전에는 `false`로 유지합니다. 이 상태에서도 Issue와
Review 자동화는 사용할 수 있고, 준비된 PR은 사람이 병합할 수 있습니다.

필수 ID나 인증 값 중 하나라도 없으면 제출 step이 명확한 오류로 끝납니다. 인증 값은
Cloud 제출 step의 환경 변수로만 전달됩니다. 별도 로그인 파일을 만들지
않으며 GitHub 저장소에도 값을 기록하지 않습니다.

Actions는 runner의 임시 폴더에 `@openai/codex@0.152.0`을 설치한 뒤 선택기에서
확인한 정확한 commit SHA를 사용해 작업을 제출합니다. Issue는 현재 `main`
SHA를 사용하고, Review는 현재 PR head SHA를 사용하며, Merge는 선택 시점의
`main` SHA를 사용합니다. Merge publisher는 같은 run의 결과 artifact를
검증하고 현재 GitHub 상태를 두 번 수집합니다. 마지막 호출은 GraphQL
`mergePullRequest`에 `expectedHeadOid=<HEAD_SHA>`와 `mergeMethod=SQUASH`를
전달합니다. GitHub가 PR head 변경을 원자적으로 거부합니다. merge queue,
auto-merge, 관리자 우회, branch 삭제는 사용하지 않습니다.

```sh
codex cloud exec \
  --env "$CODEX_CLOUD_ENV_ID" \
  --branch "$EXACT_START_SHA" \
  --attempts 1 \
  "$prompt"
```

`codex cloud exec`는 현재 Experimental 기능입니다. 이 명령은 작업 제출을
담당합니다. `--attempts 1`은 한 제출에서 사용할 후보 수를 뜻합니다. 리뷰
수정은 정책의 correction label로 최대 5회 진행하며, follow-up 이슈도 한
원본에서 최대 5개까지입니다. 자동 생성된 follow-up에는
`process:agent-followup` label을 붙여 공개 이슈 본문의 가짜 중복 marker와
구분합니다.

제출 job은 반환된 `https://chatgpt.com/codex/tasks/<id>` URL을 검증하고
`codex cloud list --json`을 30초마다 확인합니다. `ready` 또는 `applied`이면
성공으로 보고 `codex cloud diff --attempt 1 <id>`를 실행합니다. `error`이면
실패로 끝납니다. 최대 대기 시간은 5시간이며 같은
차선의 다음 제출은 이 job이 끝날 때까지 GitHub concurrency에 대기합니다.
시간 제한이 끝난 Cloud 작업은 서버에서 계속 실행될 수 있으므로 task URL을
확인한 뒤 다시 제출해야 합니다.

artifact 이름에는 lane, run ID, run attempt가 들어가며 보관 기간은 1일입니다.
Publisher는 artifact 안의 `.codex-cloud-result.json`과 코드 patch를 분리해
검증합니다. 검증기는 경로 이동, symlink·submodule·rename/copy, 보호된
workflow·policy·gate 파일, 잘못된 결과 JSON을 거부합니다. 결과가 `no-work`나
`blocked`이면 코드 변경을 게시하지 않습니다. 선택된 병합 후보의 `no-work`는
이유와 시도 횟수를 댓글로 남깁니다. 같은 PR head를 다섯 번 확인해도 준비되지
않으면 이슈를 `agent:blocked`로 옮깁니다.

각 Cloud 작업은 시작할 때 Git 디렉터리 marker와 `RPM_CLOUD_LANE`을 함께
확인합니다. 값이 요청된 차선과 다르거나 하나라도 없으면 Hook가 도구 호출을
막습니다. setup과 maintenance를 건너뛴 환경은 자동화 활성화 대상이 아닙니다.

Cloud의 worker는 Issue와 Review 작업을 수행하고 마지막에
`rpm_cloud_result_writer`에게 `.codex-cloud-result.json`을 작성하게 합니다.
Cloud 안에서는 commit, push, PR 생성·수정, 최종 lifecycle label 변경, review
thread 해결을 수행하지 않습니다. Action publisher가 exact SHA를 다시 확인한
뒤 이 작업을 수행합니다. Merge Cloud는 `.codex-cloud-result.json`만 작성할 수
있습니다. GitHub plugin merge, `gh pr merge`, raw merge API와 상태 변경 호출은
Hook가 차단합니다.

## 세 작업 차선

- Issue 차선은 `$take-ticket scheduled`를 제출합니다. Action이 본 이슈 번호는
  참고값이며, Cloud에서 전체 큐와 claimed 상태를 다시 읽고 compare-and-set
  claim을 수행합니다. batch limit 1을 지키며 ticket 작업 안에서 merge하지
  않습니다. 성공 결과는 Action publisher가 branch와 Draft PR을 만들고
  `agent:review-pending` 상태를 게시합니다.
- Review 차선은 `$pr-review-resolution scheduled`를 제출합니다. 선택된
  이슈와 PR 번호는 참고값으로만 전달하고, Cloud에서 현재 eligibility를 다시
  확인합니다. Action publisher가 검증된 correction patch를 PR head에
  fast-forward로 게시하고 thread와 lifecycle 상태를 반영합니다. 이 차선은
  merge하지 않습니다. Review selector는 Cloud 제출 전에 전체 changed-file
  목록과 개수를 확인합니다. `.codex`, `.agents`, Workflow, hook, setup,
  validator 같은 보호 경로가 바뀌었으면 제출을 중단하고, 목록 확인 뒤 PR
  base/head도 다시 읽습니다.
- Merge 차선은 `$merge-gatekeeper scheduled`를 읽기 전용으로 제출합니다.
  Cloud 결과는 병합 권한을 갖지 않습니다. Action publisher가 가장 낮은 번호의
  이슈, 실제 closing PR, base/head SHA, 검사, 모든 review thread, 보호 규칙,
  merge queue 상태를 다시 확인합니다. 두 snapshot과 Cloud target이 같을 때
  최대 하나를 병합합니다. 후보가 없거나 상태가 바뀌면 `no-work`로 끝납니다.

각 제출의 step summary에는 성공 여부, 최종 task 상태, 검증된 Cloud task
URL, exact SHA, artifact 이름을 남깁니다. Cloud CLI의 전체 출력은 summary에
복사하지 않습니다.

## Label 역할 분리

`.github/workflows/issue-labeler.yml`은 현재 `openai/codex` 저장소에서
사용하는 흐름을 따릅니다. 읽기 전용 gather job이 이슈의 종류를
판단하고, 별도의 apply job이 label만 변경합니다. 이 workflow에서
`openai/codex-action`은 이슈 종류 분류 용도로만 사용합니다. 코드 작업,
review 수정, PR 게시에는 사용하지 않습니다. 그 작업은 이 문서의 Issue와
Review Cloud lane에서 `codex cloud exec`로 실행합니다.

분류 label은 `bug`, `enhancement`, `documentation`, `refactor`, `planning` 중
하나이며 이슈 내용을 설명합니다. 실행 상태인 `agent:*` label은 queue
selector와 정책이 관리합니다. 두 label 그룹을 섞지 않아 분류 작업이 자동
실행을 시작하지 않습니다. `codex-label`은 분류를 다시 실행할 때만 잠시
사용하고, 작업이 끝나면 제거합니다.

분류 workflow는 비용이 생기는 모델 실행이므로 신뢰할 수 있는 이벤트만
받습니다. `nerdchanii`가 작성한 이슈가 열리면 자동 분류합니다. 다른 사람이
작성한 이슈는 `nerdchanii`가 `codex-label`을 붙인 이벤트에서만 분류합니다.
다른 사람이 이 label을 붙인 이벤트와 외부 작성자의 `opened` 이벤트는
분류 작업을 시작하지 않습니다. gather와 apply가 같은 조건을 확인합니다.
gather가 실패해도 trusted `codex-label` 실행의 apply job이 label 제거를
시도합니다. `openai/codex-action`의 `allow-users`도 `nerdchanii`로 제한되어
있습니다.

Cloud 자동 작업의 시작점은 `agent:ready`입니다. 종류 label만 붙은 새 이슈는
바로 구현하지 않습니다. Project #7의 조사와 준비 판정이 끝나고
`agent:ready`가 붙은 뒤 Issue 차선이 이어받습니다. 따라서 현재 자동 범위는
준비된 이슈부터 PR 수정과 병합까지입니다. Project 조사 차선은 기존 로컬
`$prepare-backlog research-cycle` 계약을 유지합니다.

분류 workflow는 `issue-triage` GitHub Environment의 Secret
`CODEX_OPENAI_API_KEY`를 사용합니다. `codex-cloud`의 인증 값과 서로 공유하지
않습니다.

첫 실행 전에 `codex-label`, `process:agent-followup`,
`agent:correction-0`부터 `agent:correction-5`까지의 label이 저장소에 있어야
합니다. Codex Cloud 환경의 GitHub 연결에는 정책이 허용한 queue 읽기와
Issue claim 기록에 필요한 권한이 있어야 합니다. branch·PR·최종 lifecycle
게시 권한은 Action publisher job의 GitHub token이 담당합니다.

Codex Automatic review는 저장소 설정에서 별도로 켭니다. 이 workflow와
Cloud 작업은 `@codex review` 댓글을 만들지 않습니다.

## 실행 조건

다음 명령의 `lane`에는 `all`, `issue`, `review`, `merge` 중 하나를 넣습니다.

```sh
gh api --method POST repos/nerdchanii/rpm/dispatches \
  -f event_type=codex-cloud-run \
  -f 'client_payload[lane]=issue'
```

`repository_dispatch`는 `nerdchanii` 계정이 호출한 요청만 받고 보호된 기본
branch의 Workflow를 사용합니다. 저장소
Variable `CODEX_CLOUD_AUTOMATION_ENABLED=true`일 때 5분 schedule은 Issue와
Review selector를 확인합니다. Merge selector는 이 값과
`CODEX_CLOUD_AUTO_MERGE_ENABLED=true`를 함께 요구합니다. 이슈의 `agent:ready`
부착과 `Rust` 또는 `PR Metadata` workflow 완료 이벤트도 해당 차선을
깨웁니다. 쓰기 secret을 사용하는 Workflow는 PR이 수정한 Workflow 파일에서
시작하지 않습니다.

세 차선 모두 repository가 `nerdchanii/rpm`일 때만 실행됩니다. selector는
`contents: read`, `issues: read`, `pull-requests: read`만 사용합니다.
Issue Cloud 제출 job은 `contents: read`, `issues: read`를 사용합니다. Review
Cloud 제출 job은 여기에 `pull-requests: read`를 추가합니다. 두 Cloud job은
checkout과 GitHub write 권한을 갖지 않습니다. 두 publisher job은
`contents: write`, `issues: write`, `pull-requests: write`를 가지며
`CODEX_ACCESS_TOKEN`을 받지 않습니다. Merge Cloud도 읽기 권한만 사용하며,
Merge publisher만 `contents: write`, `issues: write`, `pull-requests: write`를
사용합니다.
Publisher는 선택기의 exact base/head SHA와 Cloud 결과 JSON의 값을 모두
비교합니다. SHA나 보호 상태가 달라지면 push와 GitHub 상태 변경을 중단합니다.
