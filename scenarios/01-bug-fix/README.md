# 1. 재현 가능한 버그 수정과 독립 평가

CLI가 빈 입력에서 잘못된 종료 코드를 반환하는 것처럼, 실패 조건과 기대 동작을
고정할 수 있는 버그에 적합하다. PM이 수정하고 dev-trio가 변경을 리뷰한 다음,
eval-trio가 제출된 커밋의 전후 동작을 독립 검사한다.

## 입력 준비

[공통 준비](../README.md#공통-준비)를 마친다. 대상 프로젝트 바깥에 새 case 디렉터리를
만들어 아래 템플릿의 내용을 편집해 저장한다. 외부 case 파일은 수정 코드에 섞이지
않고 base/head에 동일하게 적용할 수 있다.

| 템플릿 | 저장 이름 | 채울 내용 |
| --- | --- | --- |
| [task.md](templates/task.md) | `task.md` | 재현 입력, 실제·기대 결과, 수정 범위 |
| [criteria.md](templates/criteria.md) | `criteria.md` | 사전에 정한 합격 기준과 회귀 검사 |
| [review-prompt.md](templates/review-prompt.md) | `review-prompt.md` | 리뷰 범위와 확인할 경계 조건 |
| [case.json.template](templates/case.json.template) | `case.json` | 저장소 절대 경로, base/head SHA |
| [reproducer.py.template](templates/reproducer.py.template) | `reproducer.py` | 실제 결함을 검출하는 독립 unittest |

`__CASE_DIR__`, `__PROJECT_REPO__`, `__BASE_SHA__`, `__HEAD_SHA__`, `__EXPECTED_BEHAVIOR__`
등 모든 치환 항목을 채운다. head SHA는 수정 후 확정한다. task와 criteria는 구현 전
고정한다. 재현 검사 템플릿의 `self.fail`은 미완성 표시이므로 실제 입력·호출·assert로
교체해야 한다. 단순히 삭제해 항상 통과하는 검사를 만들지 않는다.

## 1단계: 수정 전 실패 확인

```bash
BASE_SHA=$(git rev-parse HEAD)
printf '%s\n' "$BASE_SHA"
```

이 SHA를 case의 base에 기록한다. 독립 검사는 base와 head 어느 쪽에도 없는
`_scenario_bug_reproducer.py`라는 이름으로 주입된다. 두 커밋 모두에 그 경로가 없도록
확인한다. Eval은 기존 파일을 덮어쓰는 검사 주입을 거부한다.

재현 검사를 기준 커밋의 별도 작업 공간에서 실행해, 실제 결함 때문에 실패하는지
먼저 확인한다. 템플릿의 예상 신호는 종료 코드 1과 `BUG_REPRO`를 포함한 `AssertionError`다.
실제 assert의 메시지에 `BUG_REPRO`를 붙이고, 필요하다면 case의 예상 신호도 실제
출력에 맞춰 좁힌다. import 실패, 테스트 파일 부재, timeout은 버그 재현으로 인정하지 않는다.
Python 의존성이 필요한 프로젝트는 base/head 모두에서 사용할 실행 환경을 준비한다.

## 2단계: PM 수정과 dev-trio 리뷰

PM에게 완성한 task·criteria를 주고 최소 수정 및 회귀 테스트 추가를 요청한다.
리뷰 프롬프트는 [호스트별 스킬](../README.md#호스트별-스킬-표기)에 전달하거나,
공통 셸 설정 후 다음처럼 직접 호출한다.

```bash
CASE_DIR='/absolute/path/to/bug-case'
"$DEV_TRIO_BIN/ask-reviewer.sh" \
  "$(cat "$CASE_DIR/review-prompt.md")" \
  --with-spec "$CASE_DIR/criteria.md" \
  --with-context "$CASE_DIR/task.md"
```

이 호출은 현재 작업 트리의 수정을 검토한다. `NEEDS-FIX`면 지적을 수정하고 테스트를
다시 실행한다. `DISCUSS`면 판단이 필요한 사항을 해결한다. 호출 실패나 형식 오류는
판정 없음으로 기록하고 [리뷰 계약](../../dev-trio/README.md#model-configuration)을 따른다.

프로젝트 절차에 따라 수정 결과를 커밋한 뒤 `git rev-parse HEAD`로 head SHA를 얻는다.
case의 repo/base/head를 실제 값으로 채운다. Eval의 Git 제출은 커밋 객체만 읽으므로
미커밋 수정은 평가에 포함되지 않는다. base는 head의 조상이어야 한다.

## 3단계: 고정 검사 후 전체 평가

case의 regression 명령은 프로젝트의 전체 회귀 검사로 교체한다. 예시 `unittest`
명령이 테스트를 0개 수집하지 않는지 먼저 확인한다. Eval의 검사 환경에는 PATH·LANG과
임시 HOME/TMPDIR만 전달되므로 프로젝트 전용 환경변수에 의존하는 검사도 조정한다.

```bash
CHECK_OUTPUT='/absolute/path/to/new-bug-checks-001'
"$PLUGIN_SOURCE/eval-trio/bin/eval-trio" run \
  --case "$CASE_DIR/case.json" --output-dir "$CHECK_OUTPUT" \
  --checks-only --allow-execution
```

출력 디렉터리는 존재하면 안 된다. `--allow-execution`은 제출 코드·검사를 실행한다는
뜻이며, 복사된 작업 공간은 OS 샌드박스가 아니다. 신뢰할 수 있는 로컬 입력에 사용한다.
검사만 성공하면 종료 코드 **2 / HOLD**가 정상이다. `report.json`과 `checks.json`에서
base의 예상 실패와 head의 성공을 확인한다.

모델을 통한 전체 평가를 실행할 때는 **새 출력 디렉터리**를 사용한다.

```bash
FULL_OUTPUT='/absolute/path/to/new-bug-eval-001'
"$PLUGIN_SOURCE/eval-trio/bin/eval-trio" run \
  --case "$CASE_DIR/case.json" --output-dir "$FULL_OUTPUT" \
  --allow-execution
```

## 결과와 실패 시 다음 행동

- **완료:** 동일 재현 검사가 base에서 예상 실패하고 head에서 통과하며 회귀 검사도
  통과한다. 전체 `report.json`의 `complete: true`, `status: PASS`를 확인한다.
- **HOLD:** 고정 검사만 수행했거나 미해결 평가 의견이 있다. 모델 미실행은 `NOT RUN`으로
  남긴다. 코드 테스트 통과와 전체 평가 완료를 구분한다.
- **FAIL:** head 실패 또는 평가 지적을 고친다. 변경된 커밋 SHA를 case에 반영하고 새
  출력 디렉터리에서 평가한다. 기준을 사후 완화해 통과시키지 않는다.
- **ERROR:** 입력·환경·인증·receipt 오류를 먼저 해결한다. timeout이나 실행 오류를
  `expected_base`에 추가해 정상 실패로 취급하지 않는다.

증거는 base/head SHA, 독립 검사, 테스트 출력, 정확한 리뷰 결과 경로, Eval report다.
상세 상태는 [Eval 판정 계약](../../eval-trio/README.md#decision-contract)을 따른다.
