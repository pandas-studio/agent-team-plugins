# 버그 수정 판정 기준

1. __REPRO_INPUT__에 대해 __EXPECTED_BEHAVIOR__를 만족한다.
2. 독립 재현 검사는 base __BASE_SHA__에서 실제 결함에 해당하는 assertion으로
   실패하고, head에서 같은 명령과 검사 파일로 통과한다.
3. __REGRESSION_COMMAND__가 통과하고 실제 테스트가 수집된다.
4. __BOUNDARY_CASES__에서도 기존 정상 동작을 유지한다.
5. __PUBLIC_CONTRACTS__ 및 __OFF_LIMITS_PATHS__를 변경하지 않는다.

환경 오류·누락된 테스트·import 실패·timeout은 버그의 예상 실패가 아니다.
검사만 성공한 Eval 결과는 HOLD다. 전체 PASS 여부는 Eval의 고정 판정 계약을 따른다.
