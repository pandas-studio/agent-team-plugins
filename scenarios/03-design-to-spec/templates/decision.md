# 보고서 생성 설계 결정

- 상태: 미결정 — 사용자 선택이 확인된 뒤 확정으로 변경
- 정확한 토론 디렉터리·완료 Critic 라운드: __DEBATE_EVIDENCE__
- Critic 판정과 추천 근거: __VERDICT_AND_REASON__
- 남은 불확실성과 확인 결과: __OPEN_QUESTIONS_AND_EVIDENCE__
- 사용자 선택과 확인 날짜: __USER_DECISION_AND_DATE__
- 채택 대안·기각 대안과 이유: __SELECTED_AND_REJECTED__
- 허용할 인터페이스 변경·호환성 요구: __APPROVED_CONTRACT__
- 수용 기준과 실제 검사 명령: __ACCEPTANCE_COMMAND__
- 적용 후 확인할 지표와 되돌림 조건: __OBSERVATION_AND_ROLLBACK__

구현 중 새로운 요구가 생기면 이 기록과 명세를 다시 결정한다.
이미 실행 중인 루프의 명세를 고쳐 판정 기준을 바꾸지 않는다.
