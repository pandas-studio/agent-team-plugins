# agent-team-graph

`agent-team-plugins`의 기존 CLI 역할을 사용하면서 LangGraph 1.2 체크포인트,
제한된 재시도, 테스트 게이트, 사람 승인을 추가하는 실행 계층입니다. 공급자 API를 직접
호출하지 않으며 공용 `models.json` registry의 모델 믹싱 규칙을 따릅니다.

```bash
uv sync --python 3.12 --extra dev
uv run agent-team-graph run \
  --project-id demo --workspace . --spec SPEC.md \
  --task "첫 번째 수직 슬라이스 구현" --test-command "pytest -q" \
  --allow-path src --allow-path tests \
  --exclude-path .reviewer-cache
```

`--allow-path`는 **저장소 루트 기준** 경로이며 반복 지정할 수 있습니다.
`--exclude-path`도 저장소 루트 기준·반복 지정이며, 지정한 경로를 범위 검사와 변경
digest에서 완전히 제외합니다. 이는 신뢰할 수 있는 reviewer CLI의 in-repo scratch처럼
증명 대상이 아닌 경로에만 사용하세요. 승인 질문과 영수증의
`excluded_paths_not_attested`에 모든 제외 경로가 표시됩니다.
출력된 `thread_id`는 `status`, `resume`, `approve`에서 재사용합니다.

```bash
uv run agent-team-graph status --thread-id demo-abc123
uv run agent-team-graph approve --thread-id demo-abc123 --decision approve
```

## 종료 코드

JSON을 파싱하지 말고 종료 코드로 분기하세요.

| 코드 | 의미 |
| ---- | ---- |
| 0 | 승인됨 — `publish`까지 도달해 승인 영수증을 기록 |
| 3 | 진행 중 — ship 승인 인터럽트에서 대기, `approve` 필요 |
| 4 | 승인 없이 종료 (`rejected` / `needs-human`) |
| 5 | 알 수 없는 `--thread-id` |

## 안전 경계

- 테스트 명령은 argv로 실행하며 셸 연산자나 `eval`을 지원하지 않습니다.
- base SHA 이후 변경은 반복 지정한 `--allow-path` 안에 있어야 합니다. 경로는
  **저장소 루트 기준**이며, `--workspace`가 하위 디렉터리여도 동일합니다. 변경
  탐지(`git diff` + `git ls-files --others`)는 항상 저장소 루트에서 실행되므로
  workspace 밖에 생성된 파일도 게이트를 빠져나가지 못합니다.
- `.gitignore` 대상 파일은 기본적으로 게이트를 실패시키지 않지만(테스트 명령이
  만드는 빌드 산출물과 구분할 수 없기 때문) 게이트 산출물의 `ignored_paths`에
  항상 기록됩니다. `--strict-ignored`를 주면 범위 검사와 내용 증명에 포함됩니다.
  이 모드는 모든 ignored 파일을 매 snapshot마다 읽으며 성공 시도에는 gate,
  pre-review, post-review, publish의 **최대 4회** snapshot이 있으므로 `.venv`,
  `node_modules` 같은 대형 트리가 있으면 비용이 파일 수에 선형으로 증가합니다.
  격리된 깨끗한 workspace에서 활성화하고, 신뢰할 수 있는 도구 scratch는 명시적인
  `--exclude-path`로 제한하세요.
- 재시도는 기본 2회, 최대 5회입니다.
- 승인은 push/merge 권한이 아니라 로컬 승인 영수증만 생성합니다. 영수증의
  `change_sha256`은 tracked diff와 **untracked 신규 파일의 내용 해시**를 함께
  덮습니다 — `git diff`만으로는 신규 파일이 빠지기 때문입니다.
- gate와 reviewer가 확정한 `reviewed_change_sha256`을 승인 질문에 표시하고 승인 직전
  다시 계산합니다. 승인 대기 중 파일이 바뀌면 영수증 생성을 차단하고 `needs-human`으로
  종료합니다. reviewer 실행 전 drift와 reviewer 자체 mutation은 별도 산출물로
  구분하며 reviewer 역할은 read-only입니다. snapshot 도중 파일 삭제나 안전하지 않은
  경로를 만나도 실행을 crash시키지 않고 fail-closed로 기록합니다.
- `base_sha`와 변경 내용은 digest에 포함되지만 영수증의 `head_sha`는 실행 시점 정보일
  뿐 증명 대상이 아닙니다. 따라서 동일한 변경 내용을 commit해 HEAD만 이동해도 digest는
  유지되며 `head_sha_attested: false`로 명시됩니다.
- 리뷰 판정은 `VERDICT: <값>` 형식의 줄만 인정합니다. 인용문이나 코드 블록에
  들어 있는 맨 `SHIP`으로는 승인되지 않습니다.
- 산출물은 run별 immutable 경로에 저장하며 `latest` 링크를 만들지 않습니다.
- 코더 역할은 `claude-write`(= `claude --permission-mode acceptEdits`)에
  바인딩됩니다. 일반 `claude -p`는 파일을 쓸 수 없어 코더가 무동작이 됩니다.
