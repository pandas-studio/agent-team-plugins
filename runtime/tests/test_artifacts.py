from pathlib import Path

import pytest

from agent_team_graph.artifacts import ArtifactStore
from agent_team_graph.graph import _normalize_allowed, _outside_scope


def test_identical_artifact_write_is_idempotent_but_overwrite_is_blocked(tmp_path: Path):
    store = ArtifactStore(tmp_path)
    first = store.write("run", "receipt.txt", "same")
    second = store.write("run", "receipt.txt", "same")
    assert first["sha256"] == second["sha256"]
    with pytest.raises(FileExistsError):
        store.write("run", "receipt.txt", "different")


def test_scope_paths_are_relative_and_directory_aware():
    allowed = _normalize_allowed(["src/checkout/", "tests/test_checkout.py"])
    assert _outside_scope(
        ["src/checkout/api.py", "tests/test_checkout.py", "README.md"], allowed
    ) == ["README.md"]
    with pytest.raises(ValueError):
        _normalize_allowed(["../outside"])


def test_crlf_bytes_and_metadata_are_preserved(tmp_path: Path):
    store = ArtifactStore(tmp_path)
    first = store.write("run", "answer", "hello\r\nworld\r\n")
    assert store.write("run", "answer", "hello\r\nworld\r\n") == first
    assert Path(first["path"]).read_bytes() == b"hello\r\nworld\r\n"


def test_posix_parent_directory_can_contain_a_backslash(tmp_path: Path):
    store = ArtifactStore(tmp_path / "operator\\directory" / "artifacts")
    store.preflight()
    first = store.write("run", "answer", "complete")
    assert store.read("run", "answer") == b"complete"
    assert store.write("run", "answer", "complete") == first
    with pytest.raises(ValueError):
        store.write("run\\invalid", "answer", "blocked")


@pytest.mark.parametrize("bad", ["", ".", "..", "../escape", "/absolute", "a/b", "a\\b", "a\0b"])
def test_rejects_unsafe_run_ids_and_names(tmp_path: Path, bad):
    store = ArtifactStore(tmp_path)
    with pytest.raises(ValueError):
        store.write(bad, "answer", "x")
    with pytest.raises(ValueError):
        store.write("run", bad, "x")
    assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize("component", ["root", "run", "answer"])
@pytest.mark.parametrize("dangling", [False, True])
def test_symlinks_never_redirect_artifact_writes(tmp_path: Path, component, dangling):
    root = tmp_path / "artifacts"
    root.mkdir()
    (root / "run").mkdir()
    external = tmp_path / "external"
    if not dangling:
        if component == "answer":
            external.write_text("untouched")
        else:
            external.mkdir()
    link = {"root": root, "run": root / "run", "answer": root / "run" / "answer"}[component]
    if link.is_dir():
        if component == "root":
            (root / "run").rmdir()
        link.rmdir()
    link.symlink_to(external, target_is_directory=component != "answer")
    with pytest.raises(OSError):
        ArtifactStore(root).write("run", "answer", "changed")
    if dangling:
        assert not external.exists()
    elif component == "answer":
        assert external.read_text() == "untouched"
    else:
        assert list(external.iterdir()) == []


def test_fifo_collision_does_not_block(tmp_path: Path):
    import os
    import subprocess
    import sys

    (tmp_path / "run").mkdir()
    os.mkfifo(tmp_path / "run" / "answer")
    result = subprocess.run(
        [sys.executable, "-c", ("from pathlib import Path; from agent_team_graph.artifacts "
         "import ArtifactStore; import sys; ArtifactStore(Path(sys.argv[1])).write('run', 'answer', 'x')"),
         str(tmp_path)],
        capture_output=True, text=True, timeout=5, check=False,
    )
    assert result.returncode != 0
    assert "not a regular file" in result.stderr


def test_concurrent_writers_publish_one_complete_value(tmp_path: Path):
    from concurrent.futures import ThreadPoolExecutor

    store = ArtifactStore(tmp_path)
    values = ["first\r\n" * 10000, "second\n" * 10000] * 8

    def write(value):
        try:
            return store.write("run", "answer", value)
        except FileExistsError:
            return None

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(write, values))
    winner = (tmp_path / "run" / "answer").read_bytes()
    assert winner in [value.encode() for value in values]
    assert sum(r is not None for r in results) == 8
    assert list((tmp_path / "run").iterdir()) == [tmp_path / "run" / "answer"]


def test_short_writes_and_umask(tmp_path: Path, monkeypatch):
    import os
    import stat

    real_write = os.write
    monkeypatch.setattr(os, "write", lambda fd, content: real_write(fd, content[:3]))
    old_umask = os.umask(0o027)
    try:
        artifact = ArtifactStore(tmp_path).write("run", "answer", "complete bytes\r\n")
    finally:
        os.umask(old_umask)
    path = Path(artifact["path"])
    assert path.read_bytes() == b"complete bytes\r\n"
    assert stat.S_IMODE(path.stat().st_mode) == 0o640


def test_unsupported_publication_fails_preflight_without_partial_file(tmp_path: Path, monkeypatch):
    import errno
    import os

    def unsupported(*args, **kwargs):
        raise OSError(errno.EOPNOTSUPP, "hard links unsupported")

    monkeypatch.setattr(os, "link", unsupported)
    with pytest.raises(ValueError, match="cannot safely publish"):
        ArtifactStore(tmp_path).preflight()
    assert list(tmp_path.iterdir()) == []


def test_claim_distinguishes_new_creation_from_replay(tmp_path: Path):
    store = ArtifactStore(tmp_path)
    first, created = store.create_json("run", "started.json", {"stage": "coder"})
    repeated, replay_created = store.create_json("run", "started.json", {"stage": "coder"})
    assert created is True
    assert replay_created is False
    assert repeated == first
    assert store.read_json("run", "started.json") == {"stage": "coder"}


def _killed_writer(root, phase, ready):
    import os
    import signal

    real_link = os.link

    def interrupted_link(*args, **kwargs):
        if phase == "after":
            real_link(*args, **kwargs)
        ready.set()
        # Wait on a test-owned barrier; the parent kills only this child.
        signal.pause()

    os.link = interrupted_link
    ArtifactStore(root).write("run", "answer", "complete\r\n" * 10000)


@pytest.mark.parametrize("phase", ["before", "after"])
def test_killed_writer_never_publishes_partial_content(tmp_path: Path, phase):
    import multiprocessing

    ctx = multiprocessing.get_context("fork")
    ready = ctx.Event()
    child = ctx.Process(target=_killed_writer, args=(tmp_path, phase, ready))
    child.start()
    try:
        assert ready.wait(5)
        child.kill()
        child.join(5)
        assert not child.is_alive()
        final = tmp_path / "run" / "answer"
        assert final.exists() is (phase == "after")
        artifact = ArtifactStore(tmp_path).write("run", "answer", "complete\r\n" * 10000)
        assert Path(artifact["path"]).read_bytes() == b"complete\r\n" * 10000
    finally:
        if child.is_alive():
            child.kill()
            child.join(5)


@pytest.mark.parametrize("operation", ["write", "link"])
@pytest.mark.parametrize("cleanup", ["unlink", "fsync"])
def test_cleanup_preserves_the_original_publication_failure(tmp_path, monkeypatch, operation, cleanup):
    import os

    from agent_team_graph.artifacts import _publish

    original = OSError("original publication failure")
    real_cleanup = getattr(os, cleanup)
    failed = False

    def fail_publication(*args, **kwargs):
        nonlocal failed
        failed = True
        raise original

    def fail_cleanup(*args, **kwargs):
        if failed:
            raise PermissionError("secondary cleanup failure")
        return real_cleanup(*args, **kwargs)

    monkeypatch.setattr(os, operation, fail_publication)
    monkeypatch.setattr(os, cleanup, fail_cleanup)
    fd = os.open(tmp_path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        with pytest.raises(OSError) as caught:
            _publish(fd, "answer", b"complete")
    finally:
        os.close(fd)
    assert caught.value is original
    assert any("secondary cleanup failure" in note for note in original.__notes__)
    assert not (tmp_path / "answer").exists()


def test_successful_publication_still_reports_cleanup_failure(tmp_path, monkeypatch):
    import os

    from agent_team_graph.artifacts import _publish

    def fail_cleanup(*args, **kwargs):
        raise PermissionError("cleanup failure after publication")

    monkeypatch.setattr(os, "unlink", fail_cleanup)
    fd = os.open(tmp_path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        with pytest.raises(PermissionError, match="cleanup failure after publication"):
            _publish(fd, "answer", b"complete")
    finally:
        os.close(fd)
    assert (tmp_path / "answer").read_bytes() == b"complete"
