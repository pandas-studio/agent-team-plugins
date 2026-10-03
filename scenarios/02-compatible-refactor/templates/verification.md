# 리팩터링 결과 확인

- base/head SHA: __BASE_SHA__ / __HEAD_SHA__
- 실제 변경 경로: __CHANGED_PATHS__
- 실행 summary와 stage manifest: __EXACT_RUN_ARTIFACTS__
- 각 리뷰 receipt와 구조화된 결과: __EXACT_REVIEW_ARTIFACTS__

| 검사 | 명령 | 수집 수·종료 코드 | 출력 경로 | 판정 |
| --- | --- | --- | --- | --- |
| 기준 구현 계약 | __BASE_CHECK__ | __COUNT_AND_RC__ | __BASE_OUTPUT__ | NOT RUN |
| 수정 후 계약 | __HEAD_CHECK__ | __COUNT_AND_RC__ | __HEAD_OUTPUT__ | NOT RUN |
| 전체 회귀 | __REGRESSION_COMMAND__ | __COUNT_AND_RC__ | __REGRESSION_OUTPUT__ | NOT RUN |

- 기존 옵션·JSON 필드와 타입·종료 코드 유지 여부: __CONTRACT_RESULT__
- 리뷰 미해결 지적: __OPEN_FINDINGS__
- 남은 작업과 중단 사유: __PENDING_AND_REASON__
- 최종 판정과 근거: __CONCLUSION__

NOT RUN은 실제 실행 후에만 바꾼다. backlog 체크나 모델의 완료 선언만으로
테스트 결과·리뷰 결과를 채우지 않는다.
