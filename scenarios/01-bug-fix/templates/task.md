# 버그 수정 작업

- 대상 저장소와 모듈: __PROJECT_REPO__ / __TARGET_MODULE__
- 기준 커밋: __BASE_SHA__
- 재현 입력과 실행 명령: __REPRO_INPUT_AND_COMMAND__
- 실제 결과: __ACTUAL_BEHAVIOR__
- 기대 결과와 근거: __EXPECTED_BEHAVIOR__
- 허용 수정 경로: __ALLOWED_PATHS__
- 수정 금지 경로: __OFF_LIMITS_PATHS__
- 회귀 테스트 명령: __REGRESSION_COMMAND__

PM은 재현 조건을 확인한 뒤 최소 수정과 회귀 테스트를 작성한다.
독립 평가용 reproducer와 판정 기준은 수정 코드와 별도로 유지한다.
작업 범위 밖의 정리·의존성 업그레이드는 별도 작업으로 남긴다.
