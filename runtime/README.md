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

`--allow-path`는 **저장소 루트 기준** 경로이며 반복 지정할 수 있습니다.
`--exclude-path`도 저장소 루트 기준·반복 지정이며, 지정한 경로를 범위 검사와 변경
digest에서 완전히 제외합니다(tracked·untracked 모두). 이는 신뢰할 수 있는 reviewer CLI의 in-repo scratch처럼
증명 대상이 아닌 경로에만 사용하세요. 승인 질문과 영수증의
`excluded_paths_not_attested`에 모든 제외 경로가 표시됩니다.
새 run은 기존 tracked 변경과 untracked 파일이 없는 작업 트리에서 시작합니다.
예제의 `SPEC.md`는 먼저 commit하거나 저장소 밖에 두고 `--spec /절대경로/SPEC.md`로
지정하세요. 기존 변경을 발견하면 경로를 보고하고 모델을 호출하지 않습니다.
`--strict-ignored`에서는 기존 ignored 파일도 검사하며 명시적 제외 경로는 유지합니다.
기존 변경과 모델 설정 오류가 함께 있으면 기존 변경을 먼저 보고해 코드 4로 종료합니다.
작업 트리가 깨끗할 때의 모델 설정 오류는 체크포인트 갱신 전에 코드 2로 반환합니다.

출력된 `thread_id`는 `status`, `resume`, `approve`에서 재사용합니다.

```bash
uv run --project "$RUNTIME" agent-team-graph status --thread-id demo-abc123
uv run --project "$RUNTIME" agent-team-graph approve --thread-id demo-abc123 --decision approve
```

## 종료 코드

JSON을 파싱하지 말고 종료 코드로 분기하세요.

| 코드 | 의미 |
| ---- | ---- |
| 0 | 승인됨 — `publish`까지 도달해 승인 영수증을 기록 |
| 2 | 잘못된 입력·허용하지 않는 명령 전이·같은 thread의 명령 실행 중 |
| 3 | 실제 ship 승인 인터럽트에서 대기, `approve` 필요 |
| 4 | 승인 완료·승인 대기가 아닌 결과 (`rejected` / `needs-human` 또는 중단된 `running`) |
| 5 | 알 수 없는 `--thread-id` |

`awaiting_approval`은 실제 체크포인트의 승인 인터럽트를 확인한 값입니다. `running`만으로
승인 대기를 뜻하지 않습니다. `next`와 `errors`로 중단 위치를 확인하세요.
SIGINT/SIGTERM으로 취소하면 자식 프로세스를 정리한 뒤 각각 130/143을 반환합니다.

## thread 재사용과 복구

- 종료된 thread에만 새 `run --thread-id`를 허용합니다. 새 run은 리뷰·승인·digest와
  누적 artifact/usage/errors를 초기화하고 새 run ID를 사용합니다. 이전 체크포인트와
  파일은 보존됩니다. 승인 대기는 `approve --decision approve|reject`, 중단은 `resume`으로
  처리합니다. 승인 대기에 대한 `resume`은 코드 3과 승인 명령 안내만 반환합니다.
- 같은 thread의 `run/resume/approve`는 동시에 실행할 수 없습니다. `status` 조회와 승인
  거절은 models.json이 손상되어도 가능합니다. 미등록 thread의 조회·재개·승인은 코드 5입니다.
- 외부 호출 전에 시도를 체크포인트에 저장하고 호출 시작 기록을 원자적으로 생성합니다.
  명시적인 `resume`이 시작될 때 체크포인트가 가리키는 run·시도·역할 하나에 한해서,
  완료 기록·출력 해시·작업 트리 digest가 맞으면 결과를 재사용합니다. 새 run이나 재개 후
  이어지는 다른 호출에서 기존 기록을 만나면 실행을 중단합니다. 시작 기록만
  남았거나 내용이 달라졌으면 재호출하지 않고 사람 확인으로 종료합니다. 강제 종료 직전에
  외부 명령이 실행되었는지는 기록만으로 단정할 수 없습니다. 작업 트리와 남은 프로세스를
  확인하고 정리한 뒤 새 run을 시작하세요. SIGKILL 및 별도 세션으로 이탈한 daemon의 정리는
  자동으로 보장하지 않습니다.
  비 strict 모드에서 게이트 기록을 이미 저장한 뒤 중단됐다면, 재개 시 증명 대상인 필드는
  다시 확인하되 `ignored_paths` 안내 목록은 원래 관찰값을 보존합니다. strict 모드에서는
  ignored 파일 변경도 작업 트리 변경으로 판단해 재사용을 거부합니다.
- 0.1.3까지의 형식의 승인 대기·종료 기록은 계속 조회/승인/거절할 수 있습니다. 외부 호출
  노드에서 중단된 구버전 checkpoint에는 호출 기록이 없으므로 `resume`이 코드 4와 복구
  안내를 반환하고 기록을 보존합니다. 자동으로 옛 노드를 재실행하지 않습니다.
- artifact는 로컬 POSIX 파일시스템의 임시 파일과 hard link로 공개합니다. 같은 내용의
  재기록은 허용하고 다른 내용·symlink·비정규 파일은 거부합니다. 해당 기능을 지원하지
  않는 state-dir은 시작 전에 거부합니다. 구버전이 남긴 부분 파일은 덮어쓰지 않으며,
  새 run으로 복구합니다. CRLF 바이트는 그대로 보존됩니다.
- Python에서 `build_graph`를 직접 쓰면 operator가 확인한 정규 경로를 `artifact_root`로
  넘기세요. macOS의 `/tmp`·`/var`처럼 신뢰하는 시스템 별칭은 먼저 `Path.resolve()`로
  정규화해야 합니다. 저장 계층은 임의의 symlink를 따라가지 않습니다. 재개할 때는 thread의
  단독 실행을 보장한 뒤 `resume_graph(graph, config)`를 사용하세요. 일반 `graph.invoke`
  호출에는 기록 재사용 권한이 없으며, 재개 권한은 체크포인트에 저장되지 않습니다.

## 안전 경계

- 테스트 명령은 argv로 실행하며 셸 연산자나 `eval`을 지원하지 않습니다.
- base SHA 이후 변경은 반복 지정한 `--allow-path` 안에 있어야 합니다. 경로는
  **저장소 루트 기준**이며, `--workspace`가 하위 디렉터리여도 동일합니다. 변경
  탐지(`git diff` + `git ls-files --others`)는 항상 저장소 루트에서 실행되므로
  workspace 밖에 생성된 파일도 게이트를 빠져나가지 못합니다.
- `.gitignore` 대상 파일은 기본적으로 게이트를 실패시키지 않지만(테스트 명령이
  만드는 빌드 산출물과 구분할 수 없기 때문) 게이트 산출물의 `ignored_paths`에
  항상 기록됩니다. `--strict-ignored`를 주면 범위 검사와 내용 증명에 포함됩니다.
  이 모드는 시작 전 검사, 호출 완료 기록, gate/review/승인의 snapshot마다 ignored 파일을
  읽습니다. 복구용 기록 때문에 이전 버전보다 snapshot 횟수가 늘어나므로 `.venv`,
  `node_modules` 같은 대형 트리가 있으면 비용이 파일 수에 선형으로 증가합니다.
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
- **신뢰 경계: coder가 state-dir에도 쓸 수 있으면 안 됩니다.** checkpoint와 호출 기록은
  실행 여부와 승인 판단의 근거이며 범위 검사·digest에서 제외됩니다. coder에게 쓰기가 허용된
  workspace 밖에 state-dir을 두고 sandbox에서 쓰기 접근을 막으세요. 경로를 옮기기만 해서는
  같은 사용자 권한으로 실행되는 CLI의 접근이 차단되지 않습니다. 기본 `.agent-team` 경로도
  별도로 보호해야 하며, 이 런타임은 sandbox를 자동으로 구성하지 않습니다.
- 플러그인을 업데이트하기 전에 승인 대기 중인 run을 끝내세요. 버전에 따라 digest 계산이
  달라질 수 있어, 대기 중이던 run은 `needs-human`으로 종료되고 새 run이 필요합니다.
- 총 시도는 기본 2회(최대 재시도 1회), 상한은 총 5회입니다. 각 역할의 timeout·nonzero·빈
  답변도 실패한 시도로 셉니다. 성공한 plan/research는 다음 시도에서 재사용합니다.
  모델 CLI 내부 재시도나 실제 청구 횟수의 상한을 뜻하지 않습니다. snapshot 오류나
  결과를 알 수 없는 호출, 사용자 취소는 자동 재시도하지 않습니다.
- 역할과 테스트는 별도 process group으로 실행합니다. timeout/취소 시 TERM 후 2초 유예를
  두고 남은 그룹을 KILL합니다. stdout/stderr는 바이트로 수집한 뒤 UTF-8의 잘못된 바이트를
  대체 문자로 표시합니다. native final-answer가 있는 모델은 그 파일만 답변으로 사용하며,
  stderr 진단을 다음 역할의 답변 입력에 섞지 않습니다.
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
