# PR Resolution Loop — Pipeline

5개 서브에이전트 파이프라인의 단계별 입출력, 라우팅 규칙, 판정 로직을
정의한다. 메인 세션은 이 문서와 `subagent-prompts.md`를 함께 읽고
오케스트레이션한다.

## 전체 흐름

```
메인 preflight
     │
     ▼
①selector  ── PR 1개 선택 (batch_limit=1)
     │          없으면 no-work
     ▼
②collector ── PR 리뷰 컨텍스트 JSONL 수집
     │
     ▼
③router    ── 분류 + 수정 필요성 판단
     │   ├─ 수정 필요 → ④code-writer → ⑤verifier → 결과
     │   └─ 수정 불필요 → 결과만 반환 (④⑤ 건너뜀)
     ▼
메인: ⑥ 코멘트 작성 (1개)
     │
     ▼
메인: ⑦ 라벨 전환 (review-pending → awaiting-merge)
              남은 finding이 없으면 전환, 있으면 review-pending 유지
              머지는 이 루프 밖 — scheduled merge-gatekeeper가 담당
```

## 단계 명세

### ① Selector — PR 선택

**역할:** 열린 PR 중 이번 루프에서 처리할 PR 하나를 선택한다.

**입력:**
- 명시적 모드: 사용자가 지정한 PR 번호/URL
- 스케줄드 모드: GitHub 큐 (없음)

**수행:**
- `gh pr list --state open --json number,title,headRefName,baseRefName,labels,isDraft`
- 우선순위:
  1. `agent:review-pending` 이슈에 연결된 PR (이슈 번호 오름차순)
  2. unresolved 리뷰 스레드가 있는 열린 PR (PR 번호 오름차순)
- 초안(draft) PR, 닫힌 PR, 이미 머지된 PR은 제외
- `batch_limit: 1` 준수 — 최대 1개만 선택

**출력 (JSONL):**
```json
{"type":"selector_result","data":{"status":"selected|no-work","pr":<number>,"title":"<title>","head_ref":"<branch>","base_ref":"<branch>","reason":"<selection-reason>"}}
```

**no-work 조건:** 처리할 PR이 없음.

### ② Collector — 컨텍스트 수집

**역할:** 선택 PR의 diff, 리뷰, unresolved 스레드를 JSONL로 포맷팅해 수집한다.

**입력:** selector 결과의 PR 번호.

**수행:**
- `bash scripts/collect-pr-review-context.sh <pr> --format jsonl`
- 출력 이벤트 타입: `pr_review_context`, `pr_issue_comment`, `pr_review`,
  `pr_review_thread`, `pr_review_thread_comment`, `pr_sibling_pr`
- `isResolved: false` 스레드만 actionable으로 표시
- 최신 Codex Automatic 리뷰가 도착했는지 확인; 미도착 시 `review-not-arrived`

**출력 (JSONL 스트림):** 위 이벤트들을 그대로 메인에 반환.

**no-work 조건:** 최신 Codex 리뷰가 아직 도착하지 않음. 이 경우 mutation 없이
종료.

### ③ Router — 분류 및 라우팅 판정

**역할:** 수집된 코멘트를 분류하고, 수정이 필요한지 판단한 뒤 필요 시
code-writer/verifier로 라우팅한다.

**입력:** collector의 JSONL 컨텍스트 + PR diff.

**수행:**
- `accept-now` 6종 분류법으로 각 actionable 코멘트 분류:
  - `accept-now`: 정확하고, 범위 내이며, 활성 SPEC과 일치하고, 충분히 작음 → 코드 수정 허용
  - `reject-invalid`: 부정확하거나 이미 처리됨 또는 거짓 전제
  - `reject-out-of-scope`: 타당하지만 이 티켓/패치 범위 밖
  - `reject-conflicts-with-spec`: 활성 SPEC과 충돌하고 이 PR은 계약 변경 작업이 아님
  - `defer-contract-change`: SPEC 충돌이지만 가치 있는 제품/계약 아이디어
  - `defer-missing-spec`: 가치 있지만 안전하게 판단할 권위 SPEC 없음
- `accept-now` 항목이 있으면 → ④ code-writer spawn
- 없으면 → ④⑤ 건너뛰고 바로 결과 반환

**하위 라우팅:**
- ④ code-writer: `accept-now` 항목만 수정. PR 브랜치에 커밋·push. `main`,
  `.codex/`, `.agents/`, `.github/workflows/` 수정 금지.
- ⑤ verifier: `just validate`(또는 좁은 범위 게이트) 실행 + adversarial 검증.
  실패 시 router에게 보고, router는 blocked 반환.

**출력 (JSONL):**
```json
{"type":"router_result","data":{"status":"fixed|no-change|blocked","pr":<number>,"accept_now":[],"rejected":[],"deferred":[],"changes":[{"path":"","summary":""}],"verify":{"command":"just validate","exit_code":0,"summary":""},"blockers":[]}}
```

### ④ Code-writer (router가 spawn)

**역할:** `accept-now` 항목의 실제 코드 수정을 수행한다.

**입력:** router가 전달한 `accept-now` 항목 리스트 + PR 브랜치.

**수행:**
- PR 브랜치 체크아웃
- 각 항목을 최소 변경으로 수정 (관련 테스트/픽스처/SPEC 업데이트 포함)
- 의도적인 커밋 1개 작성, 같은 PR 브랜치에 push
- 무관한 cleanup, 광범위 리팩터, 포맷팅-only 변경, 파일 이동 금지

**출력 (JSONL):**
```json
{"type":"code_writer_result","data":{"status":"committed|nothing-to-do|failed","pr":<number>,"commit":"<sha>","changed_files":[""],"summary":""}}
```

### ⑤ Verifier (router가 spawn)

**역할:** code-writer의 수정이 적절한지 검증한다.

**입력:** code-writer 결과 + 변경된 파일.

**수행:**
- 좁은 범위: `just check`, `just test`(관련 모듈)
- 넓은 게이트: `just validate`
- adversarial 검증: AGENTS.md "Code Review Rules" 렌즈로 diff 재검토
- 실패 시 정확한 명령, exit code, 출력 요약 포함

**출력 (JSONL):**
```json
{"type":"verifier_result","data":{"status":"pass|fail","pr":<number>,"targeted_tests":[],"validate":{"command":"just validate","exit_code":0,"summary":""},"adversarial":{"status":"pass|findings","findings":[]}}}
```

## 메인 직접 단계

### ⑥ 코멘트 작성 (메인)

router 결과를 바탕으로 PR에 해결 내역 코멘트 **1개만** 작성한다.

- `gh pr comment <pr> --body-file <file>`
- 내용: 처리된 `accept-now` 항목 요약, 거부/연기 항목 사유, 검증 결과
- 임시 파일: `/tmp/rpm-pr-loop-pr<pr>-comment.md` (커밋 안 함)
- 이미 동일 내역의 코멘트가 있으면 중복 작성하지 않는다.

### ⑦ 라벨 전환 (메인)

이 루프는 머지하지 않는다. 남은 actionable finding 여부에 따라 연결 이슈의
라이프사이클 라벨만 전환하고, 머지는 scheduled `merge-gatekeeper`로 이관한다.

1. router 결과의 `accept_now`와 남은 P0/P1 finding을 확인한다.
2. 남은 actionable finding이 없으면 연결 이슈의 라벨 전환을 검증한다:
   `python3 scripts/check-cloud-queue-contract.py --issues-file <file>
   --operation transition --issue <n> --from-state review-pending
   --to-state awaiting-merge`.
3. 검증 통과 시:
   - `agent:review-pending` 제거, 스테일한 `agent:claimed`도 함께 제거.
   - 일반 라벨 보존.
   - `agent:awaiting-merge` 추가.
   - 이 시점부터 머지는 다음 scheduled `merge-gatekeeper` 사이클이 맡는다.
4. 남은 actionable P0/P1 finding이 있으면 `agent:review-pending`을 유지한다
   (mutation 없이 다음 루프에서 재시도).

## 라벨 전환 규칙

`.agents/workflows/backlog-policy.json`의 `allowed_transitions`를 준수한다.

- 수정 후에도 actionable P0/P1이 남으면 `agent:review-pending` 유지.
- 남은 actionable finding이 없으면 `agent:review-pending` 제거,
  `agent:claimed` 제거(스테일 시), 일반 라벨 보존, `agent:awaiting-merge` 추가.
- `agent:awaiting-merge` → `agent:blocked` 전환은 이 루프의 책임이 아니다.
  그것은 scheduled `merge-gatekeeper`가 게이트 판정 후 수행한다.
- `no-work`는 라벨을 건드리지 않는다.

## 멱등성

- 같은 PR에 대해 같은 코멘트를 반복 작성하지 않는다.
- 이미 머지된 PR은 선택하지 않는다.
- `accept-now` 항목이 없으면 코드 수정·push 없이 no-change로 종료.
- 이 루프는 머지하지 않는다. `awaiting-merge` 전환 후 머지가 일어나지 않은
  채 다음 루프가 도달하면, PR은 이미 `agent:awaiting-merge` 상태이므로
  selector의 우선순위에서 자연스럽게 밀려난다 (selector는
  `agent:review-pending`을 우선).
- `no-work`는 정상 결과다.
