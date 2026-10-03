현재 작업 트리에서 __TARGET_MODULE__의 버그 수정과 관련 테스트를 리뷰하세요.
아래 작업 요약과 첨부한 criteria를 기준으로 재현 조건, __BOUNDARY_CASES__, 기존 정상 동작,
변경 범위를 확인하세요. 검사 파일의 부재나 환경 실패를 버그 재현으로 오인하지
않았는지 확인하고, 실제 확인한 내용과 실행하지 못한 검사를 구분하세요.
판정은 dev-trio의 표준 구조화된 리뷰 형식을 따르세요.

## 작업 요약 — 확정한 task.md와 일치하도록 작성

- 재현 입력과 실행 명령: __REPRO_INPUT_AND_COMMAND__
- 실제 결과: __ACTUAL_BEHAVIOR__
- 기대 결과와 근거: __EXPECTED_BEHAVIOR__
- 허용 수정 경로: __ALLOWED_PATHS__
- 수정 금지 경로: __OFF_LIMITS_PATHS__
