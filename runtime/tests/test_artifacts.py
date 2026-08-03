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
