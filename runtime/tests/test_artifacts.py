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


def test_a_write_that_dies_midway_leaves_no_artifact_and_can_be_retried(
    tmp_path: Path, monkeypatch
):
    """A crash mid-write used to leave a truncated file that blocked resume forever."""
    import os

    import agent_team_graph.artifacts as artifacts_module

    store = ArtifactStore(tmp_path)

    class Crash(Exception):
        pass

    def crash(fd):
        raise Crash

    real_fsync = os.fsync
    monkeypatch.setattr(artifacts_module.os, "fsync", crash)
    with pytest.raises(Crash):
        store.write("run", "10-plan.md", "a complete plan")
    assert not (tmp_path / "run" / "10-plan.md").exists()
    assert list((tmp_path / "run").iterdir()) == []

    monkeypatch.setattr(artifacts_module.os, "fsync", real_fsync)
    record = store.write("run", "10-plan.md", "a complete plan")
    assert Path(record["path"]).read_text(encoding="utf-8") == "a complete plan"


def test_a_truncated_artifact_left_by_an_older_version_stays_rejected(tmp_path: Path):
    (tmp_path / "run").mkdir()
    (tmp_path / "run" / "10-plan.md").write_text("a comp", encoding="utf-8")
    with pytest.raises(FileExistsError):
        ArtifactStore(tmp_path).write("run", "10-plan.md", "a complete plan")


def test_a_symlink_at_the_artifact_name_is_refused_not_written_through(tmp_path: Path):
    outside = tmp_path / "outside.txt"
    outside.write_text("untouched", encoding="utf-8")
    run_dir = tmp_path / "state" / "run"
    run_dir.mkdir(parents=True)
    (run_dir / "10-plan.md").symlink_to(outside)
    with pytest.raises(ValueError, match="symlink"):
        ArtifactStore(tmp_path / "state").write("run", "10-plan.md", "planted")
    assert outside.read_text(encoding="utf-8") == "untouched"


def test_identical_crlf_content_is_idempotent(tmp_path: Path):
    store = ArtifactStore(tmp_path)
    first = store.write("run", "a.md", "line\r\n")
    second = store.write("run", "a.md", "line\r\n")
    assert first["sha256"] == second["sha256"]
    assert (tmp_path / "run" / "a.md").read_bytes() == b"line\r\n"


def test_concurrent_identical_writes_both_succeed(tmp_path: Path):
    """Compatibility: the loser of the link race compares bytes and returns."""
    from concurrent.futures import ThreadPoolExecutor

    store = ArtifactStore(tmp_path)
    with ThreadPoolExecutor(8) as pool:
        records = list(pool.map(lambda _: store.write("run", "a.md", "same"), range(16)))
    assert {record["sha256"] for record in records} == {records[0]["sha256"]}
    assert [p.name for p in (tmp_path / "run").iterdir()] == ["a.md"]
