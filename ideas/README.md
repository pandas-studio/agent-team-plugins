# 플러그인 아이디어: 파이프라인 이음새 보완

현재 플러그인은 단계별로 잘 동작하지만, 단계와 단계 사이는 사람이 손으로 잇는다.
이 문서는 [시나리오 3: 토론 → 명세 → 구현](../scenarios/03-design-to-spec/README.md)의
흐름을 기준으로 손 작업이 남는 **이음새**를 찾고, 이를 메울 새 플러그인 또는 기존
플러그인의 확장을 제안한다. 확정된 로드맵이 아니라 후보 목록이며, 각 항목은 별도
이슈와 RFC로 범위를 정한 뒤 착수한다.

## 현재 파이프라인과 이음새

```
[막연한 요구]
   │ G0  design-topic.md를 사람이 작성
   ▼
debate-conductor (Generator 대 Critic, 2자)
   │ G1  대안이 셋 이상이면 토론을 여러 번 돌리고 사람이 비교
   ▼
design-decision.md (사람이 작성)
   │ G2  spec.md §1–§6과 BACKLOG.md를 사람이 작성
   ▼
spec-trio / ralph-trio / dev-trio 루프
   │ G3  eval case.json을 사람이 작성
   ▼
eval-trio
   │ G4  실패 finding을 다시 BACKLOG로 옮기는 경로가 없음
   ▼
[출하]
   G5  PR 본문·CHANGELOG·마이그레이션 노트를 사람이 작성
```

| 이음새 | 지금의 손 작업 | 제안 | 형태 | 우선순위 |
| --- | --- | --- | --- | --- |
| G2 결정 → 명세 | 결정 기록을 읽고 명세·backlog를 작성하고 § 인용을 맞춘다 | [spec-forge](#1-spec-forge-결정--명세) | 새 플러그인 | 1 |
| G1 다자 결정 | 2자 토론을 반복하고 결과를 직접 비교한다 | [council-conductor](#2-council-conductor-n자-결정) | 새 플러그인 | 2 |
| G0 요구 → 토픽 | 대안·측정값·제약을 모아 토픽을 쓴다 | [discovery-trio](#3-discovery-trio-요구--토픽) | 새 플러그인 | 3 |
| G3·G4 구현 ↔ 평가 | case를 손으로 쓰고, 실패 결과를 손으로 옮긴다 | [eval-trio 확장](#4-eval-trio-확장-구현--평가) | 기존 확장 | 4 |
| G5 평가 → 출하 | 출하 문서를 직접 쓴다 | [ship-scribe](#5-ship-scribe-평가--출하) | 새 플러그인 | 5 |
| 전 구간 | 단계별 명령을 사람이 이어 붙인다 | [relay](#6-relay-전-구간-연결) | 마지막 | 6 |

## 평가 매트릭스

점수는 상(3)·중(2)·하(1)이다. 재사용도와 에피소드 가치는 높을수록, 구현 난이도는
낮을수록 좋다.

| 후보 | 재사용도 | 구현 난이도 | 에피소드 가치 | Codex PM | 근거 |
| --- | --- | --- | --- | --- | --- |
| spec-forge | 3 | 1 | 3 | 가능 | 명세 템플릿과 `spec-coverage.sh`가 이미 있다. 시나리오 3의 가장 긴 손 작업을 없앤다. |
| council-conductor | 3 | 2 | 3 | 가능 | registry와 debate의 캡처·ledger 패턴을 재사용한다. "N개 모델 블라인드 투표"는 시각적으로 강하다. |
| discovery-trio | 2 | 2 | 2 | 가능 | 출력 계약은 단순하지만 인터뷰는 사람과 여러 번 왕복해야 한다. |
| eval-trio 확장 | 3 | 1 | 1 | 이미 지원 | preset 추가와 출력 변환뿐이다. 단독 에피소드보다는 다른 회차의 부록에 가깝다. |
| ship-scribe | 2 | 2 | 2 | 가능 | 주장과 근거를 대조하는 규칙이 핵심이며, 근거 수집기는 새로 만들어야 한다. |
| relay | 2 | 3 | 3 | 미정 | 위 단계들이 있어야 의미가 있다. langgraph-conductor와 겹치는지 먼저 정리해야 한다. |

## 상세 스케치

공통 전제는 다음과 같다. 디렉터리는 루트 README의
[Pattern](../README.md#pattern)을 따르고, 역할은 `<plugin>.<role>` 이름으로 공유 model
registry에 묶으며, 역할마다 env override를 둔다. 모든 실행은 RFC 0004 run
manifest(`dev-trio/lib/manifest.sh` 계열)를 남기고, 판정은 마지막 메시지의 verdict
토큰으로 파싱한다. 모델이 만든 수치·출처를 사실로 쓰지 않는다는 시나리오의 원칙도
그대로 유지한다.

### 1. spec-forge: 결정 → 명세

**목표.** 확정된 `design-decision.md`와 토론 transcript를 받아
[spec.md 템플릿](../spec-trio/prompts/spec.md.template) 형식의 `spec.md`와 § 인용이
붙은 `BACKLOG.md` 초안을 만든다. spec-trio가 그대로 소비할 수 있어야 한다.

> 상세 설계는 [RFC 0005](../rfcs/0005-spec-forge.md)를 따른다. 아래는 요약이다.

| 역할 | 이름 | 기본 모델 | 하는 일 |
| --- | --- | --- | --- |
| Drafter | PM (호스트) | — | 결정 기록의 채택안만으로 §1–§6을 작성한다. 기각안은 §6 Non-goals에 남기고, 조항마다 출처를 기록한다. |
| Auditor | `SPEC_FORGE_AUDITOR_MODEL` | PM과 다른 계열(`codex` 또는 `claude`) | 검증할 수 없는 조항, 수치 없는 성능 요구, 모호한 §4 금지 경로, §5 검사가 없는 §3 동작, 결정 기록과의 충돌을 찾는다. dev-trio의 `ask-reviewer.sh`를 재사용한다. |

- **입력:** `design-decision.md`(상태가 확정이 아니면 거부), 선택적으로 debate 결과 receipt(`debate-conductor/lib/debate-result.sh` 형식)
- **출력:** `.spec-forge/runs/<run_id>/`의 `spec.md`, `BACKLOG.md`, `report.md`(출처 표, Auditor finding). `promote`는 대상 파일이 없을 때만 복사한다.
- **verdict:** 기존 토큰을 재사용한다. `SHIP`(준비됨) / `NEEDS-FIX`(결정 기록만으로 고칠 수 있는 결함) / `DISCUSS`(사람 결정 필요)
- **기계 검증:** spec-trio의 `parse_test_criteria`를 source하는 결정적 `lint`로 §1–§6 구조, §5.N 검사 명령, backlog의 § 인용, 출처 표를 확인한다. `spec-trio.sh --dry-run`은 구조를 읽지 않으므로 쓰지 않는다.
- **재사용:** spec-trio의 템플릿과 파서, dev-trio의 reviewer wrapper와 판정 parser, `lib/plugin-deps.sh` 패턴. v1에서는 registry 역할을 등록하지 않는다.
- **리스크:** 결정 기록에 없는 계약을 모델이 채워 넣는 것이 가장 위험하다. 출처 표에 원천이 없는 조항은 lint에서 실패하고, 결정 기록에 없는 선택은 `DISCUSS`로 멈춘다.
- **에피소드 각도:** "명세를 쓰는 AI와 명세의 빈틈을 찾는 AI." 기존 EP D(spec-trio)의 앞 단계다.

### 2. council-conductor: N자 결정

**목표.** 대안이 셋 이상이거나 답이 열려 있는 질문에 대해 여러 모델이 서로를 모른
채 독립적으로 제안하고, 익명화한 제안을 서로 순위 매긴 뒤, 결과를
[decision.md 템플릿](../scenarios/03-design-to-spec/templates/decision.md) 형식의
초안으로 정리한다. 최종 선택은 사람이 한다.

| 역할 | 이름 | 기본 모델 | 하는 일 |
| --- | --- | --- | --- |
| Moderator | PM (호스트) | — | 질문과 평가 기준을 고정하고, 제안을 익명화하며, 최종 초안을 쓴다. 제안은 하지 않는다. |
| Member × N | `council-conductor.member.<i>` | `agy`, `codex`, `claude` | 1라운드에서 독립 제안을 쓰고, 2라운드에서 자기 것을 뺀 익명 제안의 순위를 근거와 함께 매긴다. |
| Dissent Keeper | `council-conductor.dissent` | 최다 득표안을 내지 않은 멤버 | 채택될 안의 가장 강한 반론과 되돌림 조건을 쓴다. |

- **집계:** Borda 점수와 기준별 점수를 함께 낸다. 동점이거나 1·2위 차이가 작으면 `NO-CONSENSUS`로 보고하고, 억지로 하나를 고르지 않는다.
- **출력:** `council/<run>/proposal-<i>.md`, `ranking-<i>.json`, `tally.json`, `decision-draft.md`(상태는 항상 "미결정")
- **재사용:** registry의 `final_args` 캡처, debate의 ledger·재개 규칙(완료 기록만 신뢰), tmux 다중 pane 레이아웃(`team-3pane.sh`를 N pane으로 확장)
- **debate와의 관계:** 대체가 아니라 앞 단계다. council로 후보를 두 개로 좁히고, 그 둘을 debate로 깊게 검증한다.
- **리스크:** 같은 계열 모델이 많으면 독립성이 약하다. 멤버 구성의 모델 다양성을 doctor에서 경고한다. 익명화가 문체로 깨질 수 있으므로, Moderator가 형식을 정규화한 뒤 배포한다.
- **에피소드 각도:** "AI 배심원단." 같은 질문에 대한 N개 모델의 블라인드 투표를 화면에 나란히 보여준다.

### 3. discovery-trio: 요구 → 토픽

**목표.** "보고서가 느리다" 같은 막연한 요구에서 시작해, 토론에 넣을 수 있는
`design-topic.md`(대안, 제공 사실, 미측정 항목)와 명세 §1·§4의 씨앗을 만든다.

| 역할 | 이름 | 기본 모델 | 하는 일 |
| --- | --- | --- | --- |
| Interviewer | PM (호스트) | — | 사람에게 질문하고 답을 기록한다. 질문은 한 번에 최대 3개다. |
| Persona | `discovery-trio.persona` | `agy` | 호출자·운영자·신규 사용자 관점에서 놓친 요구와 사용 사례를 제기한다. |
| Assumption Auditor | `discovery-trio.auditor` | `codex` | 토픽의 각 사실이 측정값인지, 사람이 진술한 것인지, 추정인지 분류하고 측정 방법을 제안한다. |

- **출력:** `design-topic.md`([topic.md 템플릿](../scenarios/03-design-to-spec/templates/topic.md) 형식), `discovery-log.md`(질문·답·출처), `spec-seed.md`(§1 Goals, §4 Constraints 후보)
- **규칙:** 측정되지 않은 값은 `미측정`으로 쓰고, 측정 명령을 함께 남긴다. 대안이 하나뿐이면 토론 대신 바로 spec-forge로 보낸다는 권고를 출력한다.
- **verdict:** `READY-FOR-DEBATE` / `READY-FOR-COUNCIL`(대안 3개 이상) / `READY-FOR-SPEC`(대안 1개) / `NEEDS-MEASUREMENT`
- **리스크:** Persona가 실제 사용자의 목소리를 대신한다고 오해될 수 있다. 출력의 모든 페르소나 발언에 "가설" 표시를 붙인다.

### 4. eval-trio 확장: 구현 ↔ 평가

새 플러그인보다 eval-trio에 기능을 더하는 편이 낫다.

- **`spec` preset (G3):** `spec.md`의 `### §5.N`마다 check를 하나씩 만들어
  [case.schema.json](../eval-trio/schema/case.schema.json)을 채운다. 검사 명령이 없는
  §5.N은 case 생성을 거부하고 목록으로 보고한다. 이후 Challenger에게는 §4 Constraints를
  반례 탐색 범위로 넘긴다.
- **`export-backlog` (G4):** report의 finding을 `- [ ] (spec §N.M) <요약> — eval <case id>`
  형식의 BACKLOG 항목으로 내보낸다. [`spec-coverage.sh --requeue`](../spec-trio/bin/spec-coverage.sh)가
  NOT-COVERED 기준을 backlog에 다시 넣는 방식과 형식을 맞춘다. 기존 항목은 고치지 않고
  덧붙이기만 한다.
- **리스크:** eval-trio는 "편집하지 않는다"가 원칙이다. `export-backlog`는 대상 파일을
  직접 쓰지 않고 stdout이나 별도 파일로만 내보내고, 반영은 사람이나 PM이 한다.

### 5. ship-scribe: 평가 → 출하

**목표.** 결정 기록, 명세, 커밋, run manifest, eval report를 근거로 PR 본문,
CHANGELOG 항목, 마이그레이션 노트 초안을 만든다. 모든 문장에 근거가 있어야 한다.

| 역할 | 이름 | 기본 모델 | 하는 일 |
| --- | --- | --- | --- |
| Writer | PM (호스트) | — | 초안을 쓰고, 문장마다 근거 ID(커밋, manifest, report finding, §)를 단다. |
| Fact Checker | `ship-scribe.checker` | `codex-plan` | 근거 ID를 실제 파일·diff와 대조하고, 근거 없는 주장과 과장을 표시한다. |
| Reader | `ship-scribe.reader` | `agy` | 호출자·운영자 입장에서 읽고, 업그레이드에 필요한데 빠진 정보를 지적한다. |

- **verdict:** `PUBLISHABLE` / `UNSUPPORTED-CLAIMS` / `MISSING-MIGRATION`
- **규칙:** eval report가 없거나 실패면 "검증 완료" 같은 표현을 금지한다. 출하 자체(push, 릴리스)는 하지 않는다.
- **리스크:** PR 템플릿과 CHANGELOG 형식이 저장소마다 다르다. 형식은 대상 저장소의 기존 파일에서 읽고, 없으면 Keep a Changelog를 기본으로 한다.

### 6. relay: 전 구간 연결

위 단계들이 생긴 뒤에 검토한다. `pipeline.json`에 단계 순서, 단계별 입력·출력 파일,
사람 승인 게이트(결정 확정, 출하)를 선언하고, 단계 사이는 RFC 0004 run manifest로
넘긴다. 단계가 실패하면 그 단계만 재실행하고, 사람 게이트는 승인한 파일의 digest에
묶는다. 이 요구는 [langgraph-conductor](../runtime/README.md)가 이미 갖춘 체크포인트,
digest 기반 출하 승인과 많이 겹친다. 따라서 새 플러그인보다 langgraph-conductor 그래프에
discovery·council·spec-forge·eval·ship 노드를 추가하는 방안을 먼저 RFC로 비교한다.

## 완성된 흐름 예시

시나리오 3을 위 도구로 다시 쓰면 사람이 하는 일은 판단과 승인으로 줄어든다.

| 단계 | 도구 | 사람이 하는 일 |
| --- | --- | --- |
| 1 | discovery-trio | 질문에 답하고, 미측정 값을 측정한다. |
| 2 | council-conductor → debate-conductor | 후보를 둘로 좁힌 결과를 보고 깊게 검증할 쌍을 고른다. |
| 3 | (사람) | `design-decision.md`의 상태를 확정으로 바꾼다. |
| 4 | spec-forge | `NEEDS-HUMAN` 항목에 답하고 명세를 승인한다. |
| 5 | spec-trio | 상한과 검사 명령을 정한다. |
| 6 | eval-trio `spec` preset | report를 읽고, 실패 시 `export-backlog` 결과를 반영해 5로 돌아간다. |
| 7 | ship-scribe | 초안을 고쳐 PR을 연다. |

## 부록: 범위 밖에서 발견한 아이디어

파이프라인 보완에는 해당하지 않지만 조사 중 나온 후보다.

- **redteam-trio:** Attacker가 PoC를 쓰고, PM이 패치하고, Auditor가 패치 전 성공·패치 후 실패를 확인하는 보안 팀
- **migrate-trio:** changelog와 breaking change를 조사해 BACKLOG를 만들고, ralph-trio 루프와 eval-trio로 업그레이드
- **mutant-trio:** 변이를 주입하고, 살아남은 변이를 잡는 테스트를 추가하는 테스트 강도 팀
- **model-arena:** 시드 버그 코퍼스로 역할별 모델을 블라인드 비교해 `agent-team-models set-role`을 추천
- **team-ledger:** 플러그인 전반의 run manifest를 모아 모델별 시간·verdict 통계를 리포트
- **hook-guard:** PreToolUse·PostToolUse·SessionStart hook 모음(커밋 전 자동 리뷰, 위험 경로 편집 차단)
- **agent-team-core:** vendored된 registry와 `manifest.sh`를 공유 의존성으로 추출
- **ui-critic:** Playwright 스크린샷을 멀티모달 비평가 둘이 검토
