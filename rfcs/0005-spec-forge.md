# RFC 0005: spec-forge — 결정 기록에서 명세 초안까지

- 상태: Draft
- 작성일: 2026-10-06
- 대상: 새 플러그인 `spec-forge` (의존: spec-trio, dev-trio; 선택: debate-conductor)
- 관련: [플러그인 아이디어 G2](../ideas/README.md#1-spec-forge-결정--명세),
  [시나리오 3](../scenarios/03-design-to-spec/README.md), RFC 0003(spec-trio), RFC 0004(run manifest)

## 1. 요약

사용자가 확정한 `design-decision.md`를 입력으로 받아, spec-trio가 그대로 소비할 수 있는
`spec.md`와 § 인용이 붙은 `BACKLOG.md` 초안을 만든다. 초안은 호스트 PM(Claude 또는
Codex)이 쓰고, 모델 없이 동작하는 결정적 검사(`lint`)와 외부 CLI Auditor의 감사(`audit`)를
통과해야 한다. 결과는 별도 실행 디렉터리에만 쓰며, 기존 파일을 덮어쓰지 않는다. 명세
승인과 반영은 사람이 한다.

## 2. 동기

[시나리오 3](../scenarios/03-design-to-spec/README.md)의 2단계는 전부 손 작업이다.
결정 기록을 읽고 §1–§6을 채우고, backlog의 § 인용이 실제 조항과 맞는지 직접 확인해야
한다. 이 단계에서 생기는 결함은 늦게 드러난다.

- §5에 검사 명령이 없거나 `### §5.N` 형식이 틀리면 `spec-coverage.sh`가 exit 2로
  멈추거나, coverage가 의미 없게 된다.
- backlog 작업이 존재하지 않는 조항을 인용해도 아무것도 막지 않는다.
  `spec_select_task`는 인용을 검사하지 않는다(`spec-trio/lib/verification.sh:93-96`).
- `spec-trio.sh --dry-run`은 파일 존재와 미완료 줄 수만 확인한다. 섹션 구조와 작업
  본문은 읽지 않는다.
- 결정 기록에 없는 계약을 사람이든 모델이든 명세에 끼워 넣어도 추적할 수 없다.

## 3. 목표와 비목표

**목표**

1. 결정 기록과 일치하는 `spec.md`와 `BACKLOG.md` 초안을 만든다. spec-trio의 파서와 같은
   규칙으로 검증한다.
2. 명세의 모든 조항이 결정 기록의 어느 항목에서 왔는지 추적할 수 있게 한다.
3. 사람이 판단해야 할 부분(결정 기록에 없는 선택)을 초안이 메우지 않고 드러낸다.
4. 기존 공용 라이브러리를 수정하지 않고 v1을 낸다. 다른 플러그인의 버전 bump를
   요구하지 않는다.

**비목표**

- 설계 결정을 대신하지 않는다. 결정 기록의 상태가 `확정`이 아니면 시작하지 않는다.
- spec-trio 루프를 실행하지 않고, 커밋하지 않는다.
- 검사 명령을 실행해 통과 여부를 확인하지 않는다. 명령이 있는지만 확인한다. 실행은
  spec-trio의 `--test-cmd`와 eval-trio가 맡는다.
- 기존 `spec.md`와 `BACKLOG.md`를 병합하거나 수정하지 않는다.

## 4. 흐름

```
design-decision.md (상태: 확정)
   │ spec-forge gate     자리표시자·상태·입력 확인, 실행 디렉터리 생성
   ▼
.spec-forge/runs/<run_id>/
   │ (PM 초안 작성)     spec.md, BACKLOG.md, report.md
   ▼
   │ spec-forge lint     결정적 검사. 실패하면 PM이 고치고 다시 lint
   ▼
   │ spec-forge audit    Auditor 1회 호출. NEEDS-FIX면 PM이 고치고 lint→audit
   │                     (audit는 최대 2라운드)
   ▼
사람 검토
   │ spec-forge promote  대상 파일이 없을 때만 복사
   ▼
spec.md, BACKLOG.md → spec-trio
```

PM의 초안 작성 절차는 스킬(`forge`)에 정의한다. CLI는 PM 대신 내용을 생성하지 않는다.
PM 정책 문서 `lib/pm.md`와 `lib/pm-codex.md`에서는 Drafter가 다음을 지키도록 한다.

- 결정 기록의 채택 대안만으로 §1–§5를 쓰고, 기각 대안은 §6 Non-goals에 쓴다.
- 결정 기록에 근거가 없는 조항은 쓰지 않는다. 대신 report.md의 "사람 결정 필요"
  목록에 올린다.
- 측정되지 않은 수치를 만들어 쓰지 않는다.

## 5. 입력 계약

### 5.1 결정 기록

[decision.md 템플릿](../scenarios/03-design-to-spec/templates/decision.md) 형식을 따른다.
`gate`는 다음 중 하나라도 해당하면 exit 2로 거부한다.

- `- 상태:` 줄이 없거나, 값이 `확정`으로 시작하지 않는다.
- `__[A-Z][A-Z0-9_]*__` 형태의 자리표시자가 남아 있다.
- 다음 항목 중 하나가 비어 있다: 채택·기각 대안, 허용할 인터페이스 변경, 수용 기준과
  실제 검사 명령.

항목은 템플릿의 굵지 않은 bullet 라벨(`채택 대안·기각 대안과 이유` 등)로 식별한다.
라벨 표는 `lib/decision-fields.tsv` 하나에서만 관리하고, lint와 스킬이 같은 표를 읽는다.

### 5.2 토론 결과(선택)

`--debate-receipt PATH`를 받으면 debate-conductor의 `debate_receipt_read`로만 읽는다
(`debate-conductor/lib/debate-result.sh:87-139`). 이 reader는 transcript 디렉터리가
옮겨졌거나 Critic 파일이 symlink이면 실패하고, 그 경우 `gate`도 실패한다. receipt에는
판정이 없다. 따라서 Critic 파일 경로만 PM에게 참고 자료로 넘기고, 판정은 결정 기록에
사람이 적은 내용을 따른다.

## 6. 출력 계약

실행마다 `.spec-forge/runs/<run_id>/`(0700)를 만든다. PM이 쓰는 세 파일과 도구가 쓰는
기록 파일을 둔다.

| 파일 | 쓰는 쪽 | 형식 |
| --- | --- | --- |
| `spec.md` | PM | [spec.md 템플릿](../spec-trio/prompts/spec.md.template)의 `## §1`–`## §6` 구조 |
| `BACKLOG.md` | PM | 미완료 작업 줄은 `- [ ] (§…) 설명` |
| `report.md` | PM | 출처 표, 사람 결정 필요 목록, audit 라운드별 finding과 처리 |
| `decision.md` | `gate` | 결정 기록 스냅샷. 이후 단계는 원본이 아니라 이 사본을 기준으로 한다. |
| `run.json` | `gate` | `schema_version`, `run_id`, `created_at`, `decision{path, sha256}`, `debate`(receipt 정보 또는 null) |
| `lint.json` | `lint` | `ok`, `checked_at`, 세 파일의 sha256, `violations[{file, line, rule, message}]` |

### 6.1 출처 표

`report.md`에 다음 표를 둔다. spec의 모든 `## §N`과 `### §N.M`이 한 행씩 있어야 한다.

```markdown
## Provenance

| 조항 | 결정 기록 항목 |
| --- | --- |
| §1 | 채택 대안·기각 대안과 이유 |
| §2 | 허용할 인터페이스 변경·호환성 요구 |
| §5.1 | 수용 기준과 실제 검사 명령 |
```

둘째 칸에는 `decision-fields.tsv`의 라벨이나 key(`selected`, `contract` 등)를 `,`로 구분해
쓴다. 기본 대응은 다음과 같다. PM은 이 대응을 벗어나도 되지만, 표에 없는 라벨은 lint에서
실패한다.

| 조항 | 기본 원천 |
| --- | --- |
| §1 Goals | 채택 대안·기각 대안과 이유 |
| §2 Interfaces | 허용할 인터페이스 변경·호환성 요구 |
| §3 Behavior | 채택 대안·기각 대안과 이유, 허용할 인터페이스 변경·호환성 요구 |
| §4 Constraints | 허용할 인터페이스 변경·호환성 요구, 적용 후 확인할 지표와 되돌림 조건 |
| §5 Test criteria | 수용 기준과 실제 검사 명령 |
| §6 Non-goals | 채택 대안·기각 대안과 이유 |

## 7. `lint` 규칙

모델을 호출하지 않는 결정적 검사다. 실패하면 위반 사항을 한 줄씩 `파일:줄: 규칙ID 설명`
형식으로 출력하고 exit 5로 끝난다. 아래 규칙은 모두 적용되며, 하나라도 위반하면 실패다.

| ID | 규칙 | 근거 |
| --- | --- | --- |
| F1 | `spec.md`, `BACKLOG.md`, `report.md`가 모두 일반 파일로 있다. 하나라도 없으면 다른 규칙은 검사하지 않는다. | — |
| S1 | `## §1`–`## §6`이 이 순서로 한 번씩 있다. | 템플릿 구조, 역할 프롬프트의 § 참조 |
| S2 | §5 파싱 결과가 하나 이상이고, id가 모두 `§5.N` 형식이며, 코드 펜스와 HTML 주석을 인식한 읽기와 결과가 같다. 펜스 안의 `### §5.N`을 spec-trio가 세거나, 펜스 안의 `## §N` 때문에 spec-trio가 §5 블록을 일찍 닫으면 실패한다. | spec-trio의 `parse_test_criteria`를 source해 그대로 사용 (`spec-trio/lib/spec-helpers.sh:264-293`). 이 파서는 펜스를 인식하지 않는다. |
| S3 | §5.N 번호가 중복되지 않는다. | 파서가 중복을 잡지 않으므로 여기서 보완 |
| S4 | 각 `### §5.N` 본문에 backtick으로 감싼 명령이 하나 이상 있다. | 템플릿 §5 주석("observable check") |
| B1 | 미완료 작업 줄은 spec-trio와 같은 정규식 `^[[:space:]]*-[[:space:]]*\[ \][[:space:]]+`에 맞는다. `* [ ]`처럼 작업처럼 보이지만 spec-trio가 건너뛰는 줄, 코드 펜스 안의 작업 줄(spec-trio는 펜스를 무시하지 않고 집어 간다), 미완료 작업이 하나도 없는 경우는 실패다. | `spec-trio/lib/verification.sh:89` |
| B2 | 미완료 작업마다 괄호 안에 § 인용이 하나 이상 있다. `(§2, §3.1)`, `(spec §3.2)`, `(spec coverage gap §5.1)` 형식을 모두 인정한다. | 시나리오 3 backlog 형식, `planner.md:11` |
| B3 | 인용한 § 번호가 spec에 실제로 있다. | — |
| B4 | 모든 §5.N이 적어도 한 작업에서 인용된다. | spec-trio의 reviewer verdict rollup이 작업 본문의 §5.N만 집계 |
| P1 | 출처 표가 spec의 모든 § 제목을 덮고, 원천 라벨이 `decision-fields.tsv`에 있다. | 목표 2 |
| P2 | 세 출력 파일에 `__UPPER_SNAKE__` 자리표시자, spec-trio 템플릿의 주석 밖 `<…>` 자리표시자, `(replace this)`가 남지 않는다. | 자리표시자 목록은 해석한 spec-trio 설치본의 `prompts/spec.md.template`에서 읽는다. |

`spec-trio.sh --dry-run`은 lint에 쓰지 않는다. 섹션 구조를 읽지 않으면서
`fix_plan.md` 복사, 로그 생성 같은 부작용이 있기 때문이다. `spec-coverage.sh`도 쓰지
않는다. git 저장소가 필요하고, "§5 없음"과 "git 아님"이 같은 exit 2로 나와 구분되지
않는다. 둘 다 파싱 함수는 `parse_test_criteria`를 공유하므로, 그 함수 하나를 직접
source하면 파싱 결과가 일치한다.

## 8. `audit`: Auditor 호출

새 호출 경로를 만들지 않고, eval-trio의 선례(`eval-trio/lib/eval_trio.py:495-512`)처럼
dev-trio의 `ask-reviewer.sh`를 재사용한다.

```bash
DEV_TRIO_REVIEW_RECEIPT="$receipt" \
REVIEWER_ROLE_FILE="$SPEC_FORGE_ROOT/lib/roles/auditor.md" \
DEV_TRIO_REVIEWER_MODEL="$auditor_model" \
DEV_TRIO_REVIEW_PROFILE=default \
  "$ask_reviewer" --with-spec "$run_dir/spec.md" \
  "Audit the spec draft in $run_dir against $decision ..."
```

- `receipt`는 dev-trio의 `review_receipt_create`로 만들고, 결과는
  `review_result_from_receipt`로 읽는다(`dev-trio/lib/review-result.sh:196-229`).
- focus를 반드시 넘긴다. 기본 focus는 git 작업 트리 전체 리뷰다
  (`dev-trio/bin/ask-reviewer.sh:218`).
- 모델은 `SPEC_FORGE_AUDITOR_MODEL`로 고른다. 기본값은 PM과 다른 계열로 한다. Claude PM이면
  `codex`, Codex PM이면 `claude`이며, debate-conductor Critic의 선택 규칙과 같다. v1에서는
  registry 역할을 등록하지 않는다(§11).

### 8.1 판정 토큰

dev-trio의 parser는 `SHIP|NEEDS-FIX|DISCUSS`만 받는다(`OUT-OF-SCOPE`는 spec 프로필 전용,
`dev-trio/lib/review-result.sh:32`). RFC 0004 manifest의 판정 집합도 이 토큰들로 닫혀
있다(`dev-trio/lib/manifest.sh:370`). 따라서 새 토큰을 만들지 않고, Auditor 역할
프롬프트에서 기존 토큰의 뜻을 다음과 같이 정의한다.

| 토큰 | spec-forge에서의 의미 | 다음 행동 |
| --- | --- | --- |
| `SHIP` | 결정 기록과 일치하고, 모든 조항을 검증할 수 있다. | 사람 검토로 넘김 |
| `NEEDS-FIX` | PM이 결정 기록만으로 고칠 수 있는 결함이 있다. 검증 불가 조항, 수치 없는 성능 요구, 모호한 §4 금지 경로, §5 검사가 없는 §3 동작 등이다. | PM이 수정 후 lint→audit |
| `DISCUSS` | 결정 기록에 없는 선택이 필요하거나, 결정 기록과 초안이 충돌한다. | 즉시 멈추고 사람에게 질문 |

finding은 dev-trio 형식(`## Findings` → `### Blocker|Major|Minor`)을 그대로 쓴다. Blocker가
하나라도 있으면 `SHIP`을 낼 수 없다는 규칙을 역할 프롬프트에 둔다.

### 8.2 라운드 상한

audit은 기본 최대 2라운드(`--max-rounds`)다. 2라운드 뒤에도 `NEEDS-FIX`면 exit 3으로
끝나고, 남은 finding을 report.md에 기록한다. 같은 finding이 반복되는 것은 결정 기록이
부족하다는 신호로 보고, PM은 사람에게 보고한다.

## 9. CLI

```
spec-forge gate    --decision FILE [--debate-receipt FILE] [--workspace DIR]
spec-forge lint    --run DIR
spec-forge audit   --run DIR --decision FILE [--max-rounds N] [--auditor-model ID]
spec-forge promote --run DIR [--spec PATH] [--backlog PATH]
```

| 종료 코드 | 의미 |
| --- | --- |
| 0 | 성공. audit은 `SHIP`일 때만 0 |
| 2 | 사용법 오류, gate 거부, 의존 플러그인 없음 |
| 3 | audit 라운드 상한 후에도 `NEEDS-FIX` |
| 4 | audit `DISCUSS`: 사람 결정이 필요함 |
| 5 | lint 실패 |
| 6 | 캡처·I/O 오류 또는 Auditor 응답 parse 실패. dev-trio의 exit 3을 여기로 옮김 |
| 그 외 | Auditor CLI 자체의 0이 아닌 종료 코드를 그대로 전달 |

`promote`는 대상 파일이 하나라도 이미 있으면 아무것도 복사하지 않는다. 그때는
`diff -u`를 출력하고 exit 2로 끝난다. lint와 마지막 audit가 각각 성공 기록을 남기지
않은 실행 디렉터리는 promote하지 않는다.

## 10. 구현 메모

### 10.1 레이아웃

루트 README의 [Pattern](../README.md#pattern)을 따른다.

```
spec-forge/
  .claude-plugin/plugin.json
  .codex-plugin/plugin.json
  claude-skills/{forge,install-pm}/SKILL.md
  codex-skills/{forge,install-pm}/SKILL.md (+ agents/openai.yaml)
  bin/spec-forge               # gate|lint|audit|promote 디스패처 (bash 3.2, jq)
  bin/spec-forge-doctor.sh
  lib/decision-fields.tsv
  lib/roles/auditor.md
  lib/pm.md, lib/pm-codex.md
  lib/manifest.sh              # vendored (RFC 0004)
  lib/plugin-deps.sh           # vendored
  tests/
```

### 10.2 의존성 해석

spec-trio의 방식을 그대로 쓴다.

| 대상 | 해석 방법 | 필요성 |
| --- | --- | --- |
| spec-trio | `resolve_plugin_script SPEC_TRIO_BIN spec-trio@pandas-studio spec-coverage.sh`로 찾고, 같은 설치본의 `../lib/spec-helpers.sh`를 source | 필수 |
| dev-trio | `resolve_plugin_script DEV_TRIO_BIN dev-trio@pandas-studio ask-reviewer.sh`로 찾고, `../lib/review-result.sh`를 source | 필수 |
| debate-conductor | `resolve_plugin_script DEBATE_CONDUCTOR_BIN debate-conductor@pandas-studio debate.sh`로 찾음 | `--debate-receipt`를 줄 때만 |

### 10.3 manifest

`manifest_init`의 variant는 `spec-forge-lint`와 `spec-forge-audit`다. variant는 자유
문자열이라 등록이 필요 없다. 입력 기록은 다음과 같다.

- `kind=decision`: 결정 기록의 경로와 sha256
- `kind=spec-draft`, `kind=backlog-draft`
- `kind=raw-verdict`: Auditor 판정이 닫힌 집합에 대응하지 않을 때(parse 실패 등)만 원문을 남긴다. spec-trio 관례(`spec-trio/bin/spec-trio.sh:866-870`)를 따른다.

spec-trio의 coverage rollup은 `variant == "spec-review"`만 읽으므로 spec-forge manifest와
섞이지 않는다.

### 10.4 안전

- 모든 프롬프트는 stdin으로 전달한다.
- 로그와 실행 디렉터리는 0700이다.
- 결정 기록의 내용은 신뢰하지 않는 데이터로 다룬다. Auditor 프롬프트에서는 경계 블록
  안에 넣는다. 이 경계는 dev-trio가 이미 적용한다.
- 대상 저장소의 추적 파일은 promote 외에는 쓰지 않는다.
- `.spec-forge/`를 `.gitignore`에 넣으라고 bootstrap 안내와 시나리오 문서에 추가한다.

## 11. 검토한 대안

| 대안 | 채택하지 않은 이유 |
| --- | --- |
| registry 역할 `spec-forge.auditor` 등록 | `registry.sh`의 네 함수를 고쳐야 하고, 이 파일은 4개 플러그인에 byte-identical로 vendoring되어 있다(`tests/test_vendored_copies.py`). 그러면 4개 플러그인 모두 버전 bump가 필요하다. env override로 시작하고, 사용이 확인되면 별도 PR로 등록한다. |
| 새 판정 토큰(`READY`/`NEEDS-HUMAN`/`UNTESTABLE`) | dev-trio parser와 manifest의 닫힌 집합을 둘 다 바꿔야 한다. 기존 세 토큰으로 의미를 모두 표현할 수 있다. |
| Test Mapper 역할(agy)을 따로 둠 | 검사 명령이 있는지는 lint S4가 결정적으로 확인한다. 명령이 적절한지는 Auditor가 본다. 역할이 늘면 비용과 실패 지점만 는다. |
| Python 구현(eval-trio처럼) | §5 파싱을 다시 구현하면 spec-trio와 결과가 어긋날 수 있다. awk 파서를 source하는 bash가 일치를 보장한다. |
| lint에 `spec-trio.sh --dry-run` 사용 | 구조를 검사하지 않고 부작용이 있다(§7). |
| spec-trio 안에 `forge` 스킬로 넣기 | 의존성 해석과 호스트 변수 문제가 사라지는 장점이 있어 열린 질문으로 남긴다(§14-2). |

## 12. 단계별 PR

| PR | 범위 | 다른 플러그인 버전 bump |
| --- | --- | --- |
| 1 (구현됨) | 플러그인 골격, `gate`, `lint`, `decision-fields.tsv`, fixture 테스트, `scripts/check.sh`에 테스트 줄 추가 | 없음 |
| 2 | `audit`, `lib/roles/auditor.md`, manifest vendoring, 스텁 CLI 테스트 | 없음. vendoring 목록 테스트(`tests/test_vendored_copies.py`, `tests/test_manifest_copies.py`, `tests/test_publication_safety.py`)는 `tests/` 변경이라 bump가 필요 없음 |
| 3 | `promote`, Claude·Codex 스킬, `install-pm`, doctor, 두 마켓플레이스 등록, README Plugins 표, 시나리오 3 갱신 | 없음 |
| 4 (선택) | registry 역할 `spec-forge.auditor` 등록 | dev-trio, debate-conductor, ralph-trio, spec-trio |

## 13. 테스트 계획

- **lint fixture**: 정상 실행 디렉터리 1개와 규칙(S1–S4, B1–B4, P1–P2)마다 하나씩 실패하는
  fixture를 둔다. 각 fixture가 정확히 해당 규칙 ID만 보고하는지 확인한다.
- **파서 일치**: 같은 spec에 대해 `parse_test_criteria`의 출력과 lint가 집계한 §5 목록이
  같은지 확인한다. 코드 펜스 안의 `### §5.9` 같은 경계 사례를 포함한다.
- **audit 스텁**: 스텁 CLI가 `SHIP`, `NEEDS-FIX`(2라운드 반복), `DISCUSS`, 형식 오류,
  빈 응답을 내는 경우 각각 종료 코드 0/3/4/6/6과 report.md 기록을 확인한다.
  `spec-trio/bin/spec-trio-doctor.sh`의 stub smoke 방식을 따른다.
- **promote**: 대상이 없을 때 복사하는지, 대상이 있으면 diff만 출력하고 exit 2인지,
  lint 또는 audit 성공 기록이 없으면 거부하는지 확인한다.
- **gate**: `상태: 미결정`, 남은 자리표시자, 옮겨진 debate transcript를 각각 거부하는지
  확인한다.
- **호환성**: 정상 fixture의 promote 결과로 `spec-trio.sh --dry-run`과
  `spec-coverage.sh`(임시 git 저장소)가 각각 exit 0으로 끝나는지 확인한다.

## 14. 열린 질문

1. **RFC 번호.** 이 저장소에서는 RFC 0003·0004만 코드 주석으로 확인된다. upstream
   (agent-team-harness)에 0005가 이미 있는지 확인이 필요하다.
2. **독립 플러그인으로 낼지, spec-trio의 스킬로 넣을지.** spec-trio에 넣으면 의존성
   해석과 마켓플레이스 항목이 줄고, `spec-helpers.sh`를 로컬로 쓸 수 있다. 대신 spec-trio의
   책임이 "루프 실행"에서 "명세 작성 보조"까지 넓어지고, 단독 에피소드로 보여주기도
   어려워진다.
3. **Auditor를 `ask-reviewer.sh`로 부르는 것이 맞는가.** 이 wrapper는 코드 리뷰용
   workspace snapshot과 git 상태 점검을 전제로 한다. 문서 감사에서 이 비용과 잡음이 크면
   dev-trio에 `--no-snapshot` 같은 옵션이 필요할 수 있다. 그 경우 dev-trio 버전 bump가
   필요하다.
4. **Codex 호스트 선택.** vendoring된 `plugin-deps.sh`는 호스트를
   `${RALPH_TRIO_PM_HOST:-${SPEC_TRIO_PM_HOST:-claude}}`로 정한다. spec-forge 전용 변수를
   추가하려면 ralph-trio와 spec-trio의 복사본도 바꿔야 한다. 그 대신 spec-forge가
   `SPEC_TRIO_PM_HOST`를 설정해 넘길 수도 있다.
5. **출처 표의 강도.** v1은 조항 단위로만 추적한다. bullet 단위 추적이 필요한지는
   실사용 후 판단한다.
