# Spec — 선택한 보고서 생성 방식

## §1 Goals

- design-decision.md에서 확정한 __SELECTED_APPROACH__를 구현한다.
- 사용자에게 __OBSERVABLE_BENEFIT__를 제공한다.

## §2 Interfaces

- 선택한 설계의 함수·CLI·API 이름과 입력: __EXACT_INTERFACE_AND_INPUT__
- 출력 구조·필드 타입·종료 코드 또는 HTTP 상태: __EXACT_OUTPUT_CONTRACT__
- 기존 호출자와의 호환성: __COMPATIBILITY_RULES__

## §3 Behavior

### §3.1 정상 보고서 생성

- __VALID_INPUT__에 대해 __EXPECTED_REPORT_RESULT__를 반환한다.
- 생성 완료·결과 조회 시점과 관찰 방법: __COMPLETION_BEHAVIOR__

### §3.2 실패와 경계 조건

- 잘못된 입력, 생성 실패, 중복 요청에 대한 동작: __FAILURE_AND_DUPLICATE_BEHAVIOR__
- 동기 또는 비동기 중 선택한 방식의 중단·재시작 동작: __INTERRUPTION_BEHAVIOR__

## §4 Constraints

- 허용 경로: __ALLOWED_PATHS__
- 수정 금지 경로: __OFF_LIMITS_PATHS__
- 의존성·운영 제약: __DEPENDENCY_AND_OPERATIONAL_LIMITS__
- 사용자가 승인하지 않은 공개 계약 변경은 금지한다.

## §5 Test criteria

### §5.1 정상 경로와 인터페이스

- 명령: __NORMAL_AND_INTERFACE_TEST_COMMAND__
- 수집될 테스트와 관찰할 값: __NORMAL_TESTS_AND_ASSERTIONS__

### §5.2 실패·호환성과 전체 회귀

- 명령: __FAILURE_AND_REGRESSION_TEST_COMMAND__
- 수집될 테스트와 관찰할 값: __FAILURE_TESTS_AND_ASSERTIONS__

## §6 Non-goals

- 기각한 설계 대안의 구현, 운영 배포, 요청하지 않은 UI 변경.
- 추가 제외 사항: __OTHER_NON_GOALS__
