# agent-team-graph

`agent-team-plugins`의 기존 CLI 역할을 사용하면서 LangGraph 1.2 체크포인트,
제한된 재시도, 테스트 게이트, 사람 승인을 추가하는 실행 계층입니다. 공급자 API를 직접
호출하지 않으며 공용 `models.json` registry의 모델 믹싱 규칙을 따릅니다.

이 디렉터리(플러그인 설치 시에는 플러그인 루트)가 `uv` 프로젝트입니다. 명령은 작업할
저장소에서 `--project`로 이 디렉터리를 지정해 실행하세요. `--workspace .`와 기본
`--state-dir .agent-team`이 현재 디렉터리 기준이므로 `status`/`resume`/`approve`도
`run`과 같은 디렉터리에서 실행해야 합니다.

```bash
RUNTIME=/path/to/agent-team-plugins/runtime   # 플러그인 설치 시: ${CLAUDE_PLUGIN_ROOT}
uv sync --project "$RUNTIME" --frozen --python 3.12
uv run --project "$RUNTIME" agent-team-graph run \
  --project-id demo --workspace . --spec SPEC.md \
  --task "첫 번째 수직 슬라이스 구현" --test-command "pytest -q" \
  --allow-path src --allow-path tests \
  --exclude-path .reviewer-cache
```

깨끗한 작업 트리에서 시작하세요. 실행 전에 이미 `--allow-path` 밖에 있는 변경(커밋하지 않은
`SPEC.md` 포함)은 모든 시도를 실패시키므로, 어떤 역할도 실행하기 전에 run을 거부합니다
(`needs-human`, `05-preexisting-changes.json` 참고). spec은 커밋하거나 저장소 밖에 두세요.
`--allow-path` 안에 이미 있던 변경은 유지되며 `00-context.json`의 `preexisting_changes`에
기록되고 coder의 변경과 함께 증명됩니다.

`--allow-path`는 **저장소 루트 기준** 경로이며 반복 지정할 수 있습니다.
`--exclude-path`도 저장소 루트 기준·반복 지정이며, 지정한 경로를 범위 검사와 변경
digest에서 완전히 제외합니다(tracked·untracked 모두). 이는 신뢰할 수 있는 reviewer CLI의 in-repo scratch처럼
증명 대상이 아닌 경로에만 사용하세요. 승인 질문과 영수증의
`excluded_paths_not_attested`에 모든 제외 경로가 표시됩니다.
출력된 `thread_id`는 `status`, `resume`, `approve`에서 재사용합니다. 이미 존재하는
`--thread-id`로 `run`하면 거부합니다(종료 코드 2). 그 thread는 `resume`/`approve`로 이어가세요.

```bash
uv run --project "$RUNTIME" agent-team-graph status --thread-id demo-abc123
uv run --project "$RUNTIME" agent-team-graph approve --thread-id demo-abc123 --decision approve
```

## 종료 코드

JSON을 파싱하지 말고 종료 코드로 분기하세요.

| 코드 | 의미 |
| ---- | ---- |
| 0 | 승인됨 — `publish`까지 도달해 승인 영수증을 기록 |
| 3 | 진행 중 — ship 승인 인터럽트에서 대기, `approve` 필요 |
| 4 | 승인 없이 종료 (`rejected` / `needs-human`) |
| 5 | 알 수 없는 `--thread-id` |
| 6 | 미완료 — 승인에 도달하기 전에 멈춤(crash 또는 프로세스 중단), `resume`으로 마지막 체크포인트부터 재개 |
| 7 | 사용 중 — 다른 프로세스가 이 thread를 실행 중, 끝난 뒤 다시 시도 |

역할과 테스트 명령의 timeout은 run을 crash시키지 않습니다. coder timeout은 실패한 시도로
세어 남은 시도가 있으면 재시도하고, planner·researcher timeout은 `needs-human`으로, reviewer
timeout은 판정 없이 `needs-human`으로 종료합니다. timeout은 자식 프로세스 그룹 전체를 종료합니다.

## 안전 경계

- 테스트 명령은 argv로 실행하며 셸 연산자나 `eval`을 지원하지 않습니다.
- 역할과 테스트 명령은 비대화형으로 실행합니다. stdin은 `/dev/null`이며(0.1.3은 CLI의 stdin을
  그대로 넘겼습니다) 각자 별도 프로세스 그룹에서 실행되고, timeout이나 CLI 중단(Ctrl-C) 시 그룹
  전체를 종료합니다. SIGTERM·SIGHUP으로 CLI가 종료될 때도 먼저 그룹을 종료하며, 이후 `resume`으로
  이어갈 수 있습니다(종료 코드 6). 입력을 묻거나 stdin을 읽는 명령은 EOF를 받으므로 wrapper 스크립트에서
  파일로 입력을 넘기세요.
- base SHA 이후 변경은 반복 지정한 `--allow-path` 안에 있어야 합니다. 경로는
  **저장소 루트 기준**이며, `--workspace`가 하위 디렉터리여도 동일합니다. 변경
  탐지(`git diff` + `git ls-files --others`)는 항상 저장소 루트에서 실행되므로
  workspace 밖에 생성된 파일도 게이트를 빠져나가지 못합니다.
- `.gitignore` 대상 파일은 기본적으로 게이트를 실패시키지 않지만(테스트 명령이
  만드는 빌드 산출물과 구분할 수 없기 때문) 게이트 산출물의 `ignored_paths`에
  항상 기록됩니다. `--strict-ignored`를 주면 범위 검사와 내용 증명에 포함됩니다.
  이 모드는 모든 ignored 파일을 매 snapshot마다 읽으며 성공 시도에는 시작, gate,
  pre-review, post-review, publish의 **최대 5회** snapshot이 있으므로 `.venv`,
  `node_modules` 같은 대형 트리가 있으면 비용이 파일 수에 선형으로 증가합니다.
  또한 `--allow-path` 밖에 ignored 파일이 이미 있으면 시작을 거부하므로 저장소 안의
  `.venv`·`node_modules`는 `--exclude-path`로 제외하거나 깨끗한 workspace를 쓰세요.
  격리된 깨끗한 workspace에서 활성화하고, 신뢰할 수 있는 도구 scratch는 명시적인
  `--exclude-path`로 제한하세요.
- `--allow-path`/`--exclude-path`는 정규화됩니다(`./src` → `src`). 절대 경로, `..`, 저장소
  루트로 해석되는 경로(`.`, `./.`)와 저장소 루트를 가리키는 `--state-dir`는 거부합니다.
  이름이 UTF-8이 아닌 변경 파일은 증명할 수 없으므로 게이트 실패로 처리합니다.
- tracked 경로에 git clean/process 필터(예: git-lfs)가 걸려 있으면 게이트와 승인이 항상
  실패합니다. 필터는 git이 파일을 비교하기 전에 실행되므로 수정 내용이 범위 검사와 digest에서
  사라질 수 있기 때문입니다. 이런 필터가 없는 workspace에서 실행하세요.
- **신뢰 경계: coder가 `.git`에 쓸 수 있으면 안 됩니다.** 게이트와 digest는 git에게 변경 내용을
  묻고, git은 자신의 config·index·ref를 근거로 답합니다. 알려진 은닉 경로(clean/process 필터,
  assume-unchanged/skip-worktree 항목, replace ref, `core.worktree` 전환)는 거부하지만,
  `.git` 쓰기 권한이 있는 역할의 변경은 승인 영수증이 증명할 수 있는 범위 밖입니다. coder는
  `.git` 쓰기 권한이 없는 sandbox에서 실행하세요.
- 플러그인을 업데이트하기 전에 승인 대기 중인 run을 끝내세요. 버전에 따라 digest 계산이
  달라질 수 있어, 대기 중이던 run은 `needs-human`으로 종료되고 새 run이 필요합니다. 이전
  버전으로 실행 중인 명령도 모두 끝난 뒤 업데이트하세요. thread당 한 프로세스 잠금(종료 코드
  7)은 잠금을 쓰는 버전끼리만 동작하며 0.1.3 이하는 잠금을 쓰지 않습니다.
- 시도는 기본 2회(재시도 1회), 최대 5회입니다(`--max-attempts`는 재시도가 아니라 시도 횟수).
- **신뢰 경계: 역할이 state 디렉터리에 쓸 수 있으면 안 됩니다.** `--state-dir`(기본
  `.agent-team`)는 증명 대상에서 제외되며, 여기에 쓸 수 있는 역할은 체크포인트 DB도 고칠 수
  있으므로 `.git`과 같은 신뢰 대상입니다. 산출물 이름 자체의 symlink는 거부하지만 그 위
  경로에 심은 symlink는 검사하지 않습니다. coder가 sandbox 밖에서 실행되면 `--state-dir`를
  저장소 밖에 두세요.
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
- 산출물은 run별 immutable 경로에 저장하며 `latest` 링크를 만들지 않습니다. 임시 파일을
  hard link로 게시하므로 부분적으로 쓰인 산출물이 남지 않습니다(hard link를 지원하지 않는
  파일시스템에서는 오류로 멈춥니다). 0.1.3이 남긴 부분 산출물은 복구하지 않으니 새 thread로
  시작하세요.
- 코더 역할은 `claude-write`(= `claude --permission-mode acceptEdits`)에
  바인딩됩니다. 일반 `claude -p`는 파일을 쓸 수 없어 코더가 무동작이 됩니다.
