# 리팩터링 전후 유지할 계약

- 기준 커밋: __BASE_SHA__
- 변경 목적: __REFACTOR_PURPOSE__
- 허용 경로: __ALLOWED_PATHS__
- 금지 경로·의존성: __OFF_LIMITS_PATHS_AND_DEPENDENCIES__

| 입력/조건 | 기존 결과 | 비교 방법 |
| --- | --- | --- |
| __NORMAL_COMMAND__ | __STDOUT_STDERR_EXIT__ | __NORMAL_CHECK__ |
| __INVALID_COMMAND__ | __ERROR_OUTPUT_AND_EXIT__ | __ERROR_CHECK__ |
| __EMPTY_RESULT_COMMAND__ | __EMPTY_JSON_AND_EXIT__ | __EMPTY_CHECK__ |

- JSON 필드 이름·타입·필수 여부: __JSON_CONTRACT__
- 유지할 CLI 옵션과 기본값: __CLI_CONTRACT__
- 비결정적 값의 비교 규칙: __NORMALIZATION_RULES__
- 전체 회귀 테스트 명령과 예상 테스트 수: __TEST_COMMAND_AND_COUNT__

기존 출력 표현을 유지한다. 새 정보가 꼭 필요하다면 별도 이름의 필드 추가를
별도 기능 변경으로 논의한다. 이번 리팩터링에는 포함하지 않는다.
