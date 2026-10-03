# 2. CLI·JSON 호환성을 유지하는 단계별 리팩터링

여러 모듈에 중복된 CLI 출력 조립 코드를 공통 함수로 옮기는 경우를 예로 든다.
옵션·JSON 필드·종료 코드는 유지하고, 내부 구현만 작은 단위로 바꾼다.
ralph-trio가 작업별 계획·구현·리뷰를 반복하며 dev-trio가 리뷰를 담당한다.

## 입력 준비

[공통 준비](../README.md#공통-준비)에 따라 전용 작업 브랜치에서 시작한다.
먼저 실제 CLI 입력과 stdout/stderr·종료 코드·JSON 필드 및 타입을 기록한다.
시간·임의 ID 같은 비결정적 값은 비교 규칙을 명시한다. 스냅샷을 무조건 갱신하는
명령은 호환성 검증으로 사용하지 않는다.

| 템플릿 | 반영 위치 | 용도 |
| --- | --- | --- |
| [contract.md](templates/contract.md) | 새 `refactor-contract.md` | 유지할 동작과 비교 명령 |
| [PROMPT.md](templates/PROMPT.md) | bootstrap 후 `PROMPT.md` | 전체 목표와 공통 제한 |
| [BACKLOG.md](templates/BACKLOG.md) | bootstrap 후 `BACKLOG.md` | 한 번에 한 변경 단위 |
| [verification.md](templates/verification.md) | 새 `refactor-verification.md` | 전후 결과와 판정 기록 |

Codex에서 `$ralph-trio:bootstrap`, Claude Code에서 `/ralph-trio:bootstrap`을 호출한다.
생성되거나 기존에 있던 파일을 읽고 템플릿 내용을 편집해 반영한다. `__MODULE_A__`,
`__MODULE_B__`, `__SHARED_MODULE__`, `__TEST_COMMAND__` 등 모든 치환 항목을 채운다.
아래 `--worktree` 실행에서 읽을 입력과 계약·테스트는 시작 커밋에 포함되어 있어야 한다.
입력 준비 커밋은 프로젝트 절차를 따르고 기존 작업 파일을 덮어쓰지 않는다.

## 1단계: 기준 동작 검증

```bash
BASE_SHA=$(git rev-parse HEAD)
python3 -m unittest discover -s tests -v
```

기준 SHA와 실제 테스트 수를 verification에 기록한다. 명령은 프로젝트 테스트로
바꾼다. CLI 정상 입력, 잘못된 입력, 빈 결과에 대한 계약 검사가 없으면 먼저 추가해
기존 구현에서 통과시키고 기준을 고정한다. 전체 목표는 3개 작업으로 나누되, 한 번의
반복에서 여러 모듈을 동시에 전환하지 않는다.

## 2단계: dry-run과 제한된 반복

[공통 셸 설정](../README.md#직접-셸에서-실행할-때) 후 대상 프로젝트 루트에서 실행한다.
dry-run에는 worktree 옵션을 넣지 않는다.

```bash
"$PLUGIN_SOURCE/ralph-trio/bin/ralph-trio.sh" \
  --prompt PROMPT.md --backlog BACKLOG.md --fix-plan fix_plan.md \
  --max-iter 3 --max-runtime 30m --dry-run
```

경로와 로그 생성을 확인한 뒤 실제 모델 실행을 시작한다.

```bash
"$PLUGIN_SOURCE/ralph-trio/bin/ralph-trio.sh" \
  --prompt PROMPT.md --backlog BACKLOG.md --fix-plan fix_plan.md \
  --max-iter 3 --max-runtime 30m --worktree
```

스킬로 실행한다면 Codex의 `$ralph-trio:run`에, Claude에서는 자연어 요청으로
“trio 변형, 위 입력 파일, 최대 3회·30분, dry-run 먼저, 실제 실행은 worktree 사용”을
요청한다. 연구가 필요하다는 결과가 나오면 근거를 확보한 뒤 진행한다.

`ralph-trio.sh`에는 `--test-cmd` 옵션이 없다. PROMPT와 각 backlog 작업에 테스트
명령을 넣고 실제 출력이 남았는지 확인한다. worktree 병합 전 기본 검사는 diff·변경
크기·의심 문자열 검사이며 프로젝트 테스트 실행을 강제하지 않는다. 리뷰의 `SHIP`과
작업 브랜치 병합도 별도 호환성 검사 통과를 대신하지 않는다. 강제 테스트 게이트가
필요하면 [Spec 시나리오](../03-design-to-spec/README.md)로 계약을 옮긴다.

## 3단계: 전체 호환성 검증과 판정

루프가 끝나면 현재 작업 브랜치에서 계약 명령과 전체 회귀 검사를 다시 실행한다.

```bash
python3 -m unittest discover -s tests -v
git diff --check "$BASE_SHA" HEAD
git diff --stat "$BASE_SHA" HEAD
git status --short
```

verification에 head SHA, 테스트 수·종료 코드, 바뀐 경로, 해당 실행의 summary와
manifest·리뷰 결과 경로를 기록한다. 미커밋 변경이 남았다면 함께 검토한다.

- **완료:** 모든 계획 작업의 구현과 테스트 증거가 있고 기존 옵션, JSON 필드·타입,
  stdout/stderr 구분, 종료 코드가 유지된다. 전체 회귀 검사와 리뷰 지적도 해결됐다.
- **상한 도달:** 남은 작업을 실제 변경과 대조해 기록한다. 완료로 표시하지 않는다.
- **DISCUSS·UNKNOWN·호출 실패:** fix_plan과 정확한 리뷰 결과를 읽는다. Ralph는 일부
  판정에서 다음 작업으로 진행할 수 있어 backlog의 `[x]`나 종료 코드만 믿지 않는다.
  빠진 작업은 확인 후 다시 명시한다.
- **호환성 검사 실패:** 실패한 작업 단위를 찾아 수정하거나 프로젝트 절차로 되돌린다.
  기대 출력을 새 동작으로 바꿔 리팩터링 성공으로 처리하지 않는다.

자세한 반복 동작은 [Ralph trio 안내](../../ralph-trio/README.md#trio-3-stage-with-codex-review)를 따른다.
