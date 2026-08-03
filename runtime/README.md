# agent-team-graph

`agent-team-plugins`의 기존 CLI 역할을 사용하면서 LangGraph 1.2 체크포인트,
제한된 재시도, 테스트 게이트, 사람 승인을 추가하는 실행 계층입니다. 공급자 API를 직접
호출하지 않으며 공용 `models.json` registry의 모델 믹싱 규칙을 따릅니다.

```bash
uv sync --python 3.12 --extra dev
uv run agent-team-graph run \
  --project-id demo --workspace . --spec SPEC.md \
  --task "첫 번째 수직 슬라이스 구현" --test-command "pytest -q" \
  --allow-path src --allow-path tests
```

출력된 `thread_id`는 `status`, `resume`, `approve`에서 재사용합니다.

```bash
uv run agent-team-graph status --thread-id demo-abc123
uv run agent-team-graph approve --thread-id demo-abc123 --decision approve
```

안전 경계:

- 테스트 명령은 argv로 실행하며 셸 연산자나 `eval`을 지원하지 않습니다.
- base SHA 이후 변경은 반복 지정한 repository-relative `--allow-path` 안에 있어야 합니다.
- 재시도는 기본 2회, 최대 5회입니다.
- 승인은 push/merge 권한이 아니라 로컬 승인 영수증만 생성합니다.
- 산출물은 run별 immutable 경로에 저장하며 `latest` 링크를 만들지 않습니다.
