# 3. 설계 토론에서 명세 기반 구현까지

“보고서 생성을 동기로 유지할지 백그라운드 작업으로 전환할지”처럼 서로 다른
장단점이 있는 결정을 다룬다. debate-conductor로 대안을 검토하고, 사용자가 선택한
계약을 spec-trio의 명세·검사로 구체화한다. 토론의 추천이 구현 승인이나 명세를
자동으로 대신하지 않는다.

## 입력 준비

[공통 준비](../README.md#공통-준비)를 마친 전용 작업 브랜치에서 다음 내용을 준비한다.

| 템플릿 | 저장·반영 위치 | 채울 내용 |
| --- | --- | --- |
| [topic.md](templates/topic.md) | 새 `design-topic.md` | 두 대안, 현재 측정값, 운영 제약 |
| [decision.md](templates/decision.md) | 새 `design-decision.md` | 토론 근거와 사용자 선택 |
| [spec.md](templates/spec.md) | bootstrap 후 `spec.md` | 선택한 설계의 §1–§6 계약 |
| [BACKLOG.md](templates/BACKLOG.md) | bootstrap 후 `BACKLOG.md` | 명세 조항별 구현 단위 |

`__CURRENT_INTERFACE__`, `__MEASURED_LATENCY__`, `__ACCEPTANCE_COMMAND__` 등의
치환 항목을 채운다. 지연·부하를 아직 측정하지 않았다면 미측정으로 명시하고 필요한
측정을 수행한다. 외부 서비스 사양이 결정에 필요하면 별도 조사 근거를 첨부한다.
측정치나 출처를 만들어 채우지 않는다.

## 1단계: 4라운드 토론

Codex의 `$debate-conductor:run` 또는 Claude의 `/debate-conductor:run`에
“design-topic.md의 대안을 4라운드 토론하고 최종 Critic 판정과 근거를 보고”하도록
요청한다. 직접 실행은 [공통 셸 설정](../README.md#직접-셸에서-실행할-때) 후 다음과 같다.

```bash
"$PLUGIN_SOURCE/debate-conductor/bin/debate.sh" -n 4 \
  "$(cat design-topic.md)"
```

실행이 출력한 정확한 transcript 디렉터리를 기록한다. `index.jsonl`에서 `role: crit`,
`rc: 0`인 완료(`end`) 기록 중 마지막 라운드가 가리키는 파일을 읽고 판정을 확인한다.
완료된 Critic 기록이 없으면 최종 판정 없음으로 남긴다. 토론이 끝났어도 반대 의견이
남을 수 있으며, 라운드 수를 채웠다는 사실은 합의가 아니다.

## 2단계: 사용자 결정과 명세 확정

최종 추천과 미해결 쟁점을 먼저 제시하고 `design-decision.md`에 사용자 선택을 기록한다.
선택이 확정되기 전에는 구현 루프를 실행하지 않는다. 결정 기록에는 채택 대안,
기각 사유, 허용할 변경, 테스트 가능한 수용 기준과 되돌림 조건을 남긴다.

Codex에서 `$spec-trio:bootstrap`, Claude에서 `/spec-trio:bootstrap`을 호출한다.
기존 파일을 보존하면서 명세와 backlog 템플릿의 내용을 반영한다. §2에는 **선택한
대안만**의 구체 인터페이스를 적고, §3과 §5를 관찰 가능한 동작·검사로 채운다.
미결정 A/B를 남긴 채 구현을 시작하지 않는다. backlog의 § 인용이 실제 조항과 맞는지
확인한다. worktree에서 읽을 명세·backlog와 관련 자료를 프로젝트 절차에 따라 커밋한다.

## 3단계: 명세 기반 구현

```bash
"$PLUGIN_SOURCE/spec-trio/bin/spec-trio.sh" \
  --spec spec.md --backlog BACKLOG.md \
  --max-iter 3 --max-runtime 30m --dry-run
```

dry-run 이후 실제 구현은 다음과 같다. `--test-cmd`는 §5의 모든 기준을 검증하는
프로젝트 명령으로 바꾸고, 테스트 0개 수집을 성공으로 인정하지 않는다.

```bash
"$PLUGIN_SOURCE/spec-trio/bin/spec-trio.sh" \
  --spec spec.md --backlog BACKLOG.md \
  --max-iter 3 --max-runtime 30m --worktree \
  --test-cmd 'python3 -m unittest discover -s tests -v'
```

Codex는 `$spec-trio:run`에, Claude는 자연어 요청으로 같은 입력·상한·검사 명령을
전달한다. 루프가 실행 중인 동안 명세나 backlog를 바꾸지 않는다. 계약 변경이
필요하면 실행을 멈추고 결정 기록과 명세를 갱신한 후 새 실행으로 검증한다.

## 산출물과 실패 시 다음 행동

- **완료:** 선택한 설계의 결정 기록, 구현 커밋, §5 검사 출력, 정확한 리뷰 receipt와
  manifest가 있다. summary가 완료를 나타내고 미완료 작업·차단 판정이 없다.
- **종료 3:** 반복·시간 상한 또는 추가된 미완료 작업이 있다. summary의 pending과
  reason을 읽고 다음 작업을 정한다.
- **종료 4:** 명세·backlog 변경 또는 `OUT-OF-SCOPE`·`DISCUSS`·`UNKNOWN` 등으로
  판단이 필요하다. 보존된 작업 공간과 근거를 검토하고 계약을 임의 완화하지 않는다.
- **검사 실패·NEEDS-FIX:** 같은 작업이 남는다. 실행 근거를 읽고 수정하며, 상한을
  무제한으로 늘리지 않는다. 테스트 실행 오류와 제품 동작 실패를 구분한다.
- **모델 미실행·인증 실패:** `NOT RUN` 또는 실제 오류로 남기고 토론·구현·리뷰가
  완료되었다고 기록하지 않는다.

전체 종료 코드와 게이트는 [Spec 계약](../../spec-trio/README.md#exit-status-and-migration)을 따른다.
완료 후 실제 서비스 적용은 결정 기록의 되돌림 조건을 포함해 별도로 검토한다.
