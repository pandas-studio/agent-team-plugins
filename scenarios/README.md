# 실무 시나리오

기존 저장소에 적용할 수 있는 세 가지 워크플로우다. 플러그인별 명령을 익혔다면,
여기서는 입력을 준비하고 여러 도구를 연결해 결과를 확인하는 과정을 따라간다.
가이드와 입력 템플릿이며, 완성된 샘플 앱이나 자동 실행기는 아니다.

## 시나리오 선택

| 순서 | 상황 | 워크플로우 | 선택 이유 |
| --- | --- | --- | --- |
| 1 | 실패를 재현할 수 있는 버그 | [재현 → 수정 → 독립 평가](01-bug-fix/README.md): PM + dev-trio + eval-trio | 전후 차이가 명확해 결과를 검증하기 쉽다. |
| 2 | 동작은 유지하면서 중복 구현을 정리 | [호환성 유지 리팩터링](02-compatible-refactor/README.md): ralph-trio + dev-trio | 작은 작업을 반복하되 기존 CLI·JSON 계약을 보존한다. |
| 3 | 구현 전에 설계 선택이 필요 | [토론 → 명세 → 구현](03-design-to-spec/README.md): debate-conductor + spec-trio + dev-trio | 선택 근거를 명세와 테스트로 이어 간다. |

1번부터 적용하는 것을 권장한다. 재현 가능한 한 건의 버그로 리뷰·평가의 차이를
확인한 뒤, 반복 작업과 설계 결정으로 넓힌다. 2번의 Ralph는 테스트 실행을 강제하는
명세 게이트가 아니다. 자동 테스트 게이트가 필수라면 3번의 Spec 흐름을 사용한다.

## 공통 준비

1. 작업할 프로젝트의 테스트 명령과 기준 커밋을 확인한다. 예시는 Python 표준
   `unittest`를 사용한다. 다른 언어라면 명령과 재현 검사를 함께 교체한다.
2. [설치 안내](../README.md#install-the-marketplace-in-codex)에 따라 필요한 플러그인을
   설치한다. Bash, Git, Python 3, jq가 필요하다. 실제 모델 실행에는 선택한 CLI의
   설치·로그인이 필요하며 별도 비용이 발생할 수 있다.
3. 변경이 없는 전용 작업 브랜치 또는 별도 작업 공간에서 시작한다. 다른 작업이
   남아 있으면 보존하고 분리한다. 아래 예시의 반복 루프는 커밋하거나 현재 작업
   브랜치로 fast-forward 병합할 수 있으므로 기본 브랜치에서 실행하지 않는다.
4. 템플릿의 `__UPPER_SNAKE_CASE__`를 모두 실제 값으로 채운다. 경로는 대상
   프로젝트 기준이며, Eval case 내부의 파일 경로는 case 디렉터리 기준이다.
   셸 예시의 `/absolute/path/to/...`도 실제 경로로 교체한다. `PLUGIN_SOURCE`,
   `CASE_DIR`, `CHECK_OUTPUT`, `FULL_OUTPUT`의 값이 해당하며 출력 경로는 새 경로를 쓴다.
   예시의 `python3 -m unittest discover -s tests -v`도 실제 테스트를 수집하는지 확인한다.
5. 기존 `PROMPT.md`, `spec.md`, `BACKLOG.md`, `fix_plan.md`는 먼저 읽는다.
   bootstrap은 없는 파일만 만든다. 템플릿 내용을 필요한 위치에 편집해 반영하며
   기존 작업 파일에 `cp`로 덮어쓰지 않는다.
6. 모델 호출 전에 대상 프로젝트의 `.gitignore`에 `.dev-trio/`, `.debate-conductor/`,
   `.ralph-trio/`, `.spec-trio/`를 추가한다. 파일이 없으면 만들고, 기존 규칙은 보존한다.
   리뷰·토론 transcript와 루프 로그·상태가 커밋이나 Eval 제출물에 섞이지 않도록
   준비 변경에 포함한다. 이미 추적 중인 로그는 `.gitignore`만으로 제외되지 않으므로
   커밋 대상에서 빠졌는지 별도로 확인한다.

### 호스트별 스킬 표기

아래는 **에이전트 대화창**에 입력한다. 셸 명령이 아니다. `<요청>`은 각 가이드의
입력 파일과 제한 조건을 포함한 요청으로 바꾼다.

| 용도 | Codex | Claude Code |
| --- | --- | --- |
| 버그 리뷰 | `$dev-trio:review <요청>` | `/dev-trio:review <요청>` |
| 결과 평가 | `$eval-trio:evaluate <요청>` | `/eval-trio:evaluate <요청>` |
| 반복 작업 준비 | `$ralph-trio:bootstrap` | `/ralph-trio:bootstrap` |
| 반복 실행 | `$ralph-trio:run <요청>` | 아래 가이드의 `ralph-trio.sh` 실행을 자연어로 요청 |
| 설계 토론 | `$debate-conductor:run <요청>` | `/debate-conductor:run <요청>` |
| 명세 작업 준비 | `$spec-trio:bootstrap` | `/spec-trio:bootstrap` |
| 명세 실행 | `$spec-trio:run <요청>` | 아래 가이드의 `spec-trio.sh` 실행을 자연어로 요청 |

현재 Claude 플러그인에는 Ralph·Spec의 `run` 스킬이 없다. bootstrap 이후 자연어로
실행을 요청하거나 가이드의 셸 명령을 사용한다.

### 직접 셸에서 실행할 때

가이드의 셸 블록은 같은 터미널에서 **대상 프로젝트 루트**를 작업 디렉터리로
사용한다. `PLUGIN_SOURCE`에는 이 marketplace 저장소를 받은 실제 절대 경로를 넣는다.
설치된 스킬은 해당 호스트의 플러그인 경로를 스스로 해결하므로 이 설정이 필요 없다.

```bash
PLUGIN_SOURCE='/absolute/path/to/agent-team-plugins'
export DEV_TRIO_BIN="$PLUGIN_SOURCE/dev-trio/bin"
export DEV_TRIO_PM_HOST=codex
export RALPH_TRIO_PM_HOST=codex
export SPEC_TRIO_PM_HOST=codex
export DEBATE_CONDUCTOR_PM_HOST=codex
```

Claude를 PM으로 사용하면 네 `*_PM_HOST` 값을 모두 `claude`로 바꾼다. 모델 선택은
기존 [모델 설정](../README.md#shared-model-configuration)을 따른다. 가이드는 전역
모델 설정을 바꾸지 않는다. 호스트 권한이나 인증 문제는 해당 플러그인의 안내대로
처리하고, 실패를 피하려고 다른 모델로 임의 전환하지 않는다.

## 실행과 결과 판정

- dry-run은 실제 모델을 부르지 않지만 로그·manifest 등의 로컬 파일을 만들 수 있다.
  Ralph trio는 지정한 fix-plan 파일(기본 `fix_plan.md`)에도 모의 작업의 `SHIP` 기록을
  추가한다. 리팩터링 가이드는 이 파일을 실행마다 별도 dry-run 디렉터리로 분리한다.
  명령·입력 경로 확인용이며 구현, 테스트 통과, 리뷰 성공의 증거가 아니다.
- Ralph·Spec 예시는 최대 3회·30분으로 제한한다. 이 상한은 성공을 보장하지 않으며
  남은 작업과 중단 사유를 확인해야 한다. 토론은 4라운드로 실행한다.
- dev-trio는 해당 호출의 `.run.json`에서 실행 모델·종료 상태를, `.review.json`에서
  리뷰 판정을 확인한다. `.final.md`는 같은 실행의 설명 자료다. `latest` 링크를
  고정된 실행 근거로 사용하지 않는다.
- 루프는 해당 실행의 summary, stage manifest, review receipt와 테스트 출력을 함께
  확인한다. 명령 종료 코드나 backlog 체크 표시만으로 전체 완료를 선언하지 않는다.
- eval-trio의 authoritative 결과는 `report.json`이다. checks-only 성공은 `HOLD`다.
  고정 검사와 Challenger·Judge 조건을 모두 충족한 전체 평가만 `PASS`가 될 수 있다.
- 실제 모델 호출을 하지 않았다면 `NOT RUN`으로 기록한다. 인증·권한·출력 형식 오류는
  결과를 읽을 수 없는 상태로 남기고, 통과할 때까지 반복 호출하지 않는다.

각 시나리오의 완료는 로컬 작업과 근거 확인까지다. 원격 push·PR·병합·배포는
프로젝트의 별도 절차를 따른다.
