import json
import sys
from pathlib import Path

from agent_team_graph.registry import ModelRegistry, RoleRunner


def test_config_role_overrides_builtin_and_prompt_is_one_argv(tmp_path: Path):
    config = tmp_path / "models.json"
    config.write_text(
        json.dumps(
            {
                "models": {
                    "fake": {
                        "command": sys.executable,
                        "args": ["-c", "import sys; print(sys.argv[1])", "{prompt}"],
                    }
                },
                "roles": {"langgraph-conductor.planner": "fake"},
            }
        ),
        encoding="utf-8",
    )
    result = RoleRunner(ModelRegistry(config)).run(
        "langgraph-conductor.planner", "line one\nline two", tmp_path
    )
    assert result.returncode == 0
    assert result.output == "line one\nline two\n"
    assert result.model == "fake"


def test_placeholders_replace_whole_arguments_only(tmp_path: Path):
    """A literal "{final}" inside the prompt text must reach the CLI unchanged."""
    config = tmp_path / "models.json"
    config.write_text(
        json.dumps(
            {
                "models": {
                    "fake": {
                        "command": sys.executable,
                        "args": ["-c", "import sys; print(sys.argv[1:])", "{prompt}", "x{prompt}"],
                    }
                },
                "roles": {"langgraph-conductor.planner": "fake"},
            }
        ),
        encoding="utf-8",
    )
    result = RoleRunner(ModelRegistry(config)).run(
        "langgraph-conductor.planner", "write {final} and {prompt} literally", tmp_path
    )
    assert result.output == "['write {final} and {prompt} literally', 'x{prompt}']\n"


def test_zero_exit_without_stdout_is_a_failure(tmp_path: Path):
    """A soft-denied agy run prints guidance on stderr only and exits 0."""
    config = tmp_path / "models.json"
    config.write_text(
        json.dumps(
            {
                "models": {
                    "fake": {
                        "command": sys.executable,
                        "args": ["-c", "import sys; sys.stderr.write('auto-denied\\n')", "{prompt}"],
                    }
                },
                "roles": {"langgraph-conductor.researcher": "fake"},
            }
        ),
        encoding="utf-8",
    )
    result = RoleRunner(ModelRegistry(config)).run("langgraph-conductor.researcher", "q", tmp_path)
    assert result.returncode == 5
    assert "no output" in result.output
    assert "auto-denied" in result.output


def _single_model(tmp_path: Path, code: str, role: str) -> ModelRegistry:
    config = tmp_path / "models.json"
    config.write_text(
        json.dumps(
            {
                "models": {"fake": {"command": sys.executable, "args": ["-c", code, "{prompt}"]}},
                "roles": {role: "fake"},
            }
        ),
        encoding="utf-8",
    )
    return ModelRegistry(config)


def test_harness_timeout_is_flagged_not_raised(tmp_path: Path):
    role = "langgraph-conductor.coder"
    registry = _single_model(tmp_path, "import time; print('half', flush=True); time.sleep(30)", role)
    result = RoleRunner(registry, timeout_seconds=1).run(role, "p", tmp_path)
    assert result.timed_out is True
    assert result.returncode == 124
    assert "timed out after 1s" in result.output
    assert "half" in result.output


def test_a_cli_exiting_124_itself_is_not_a_timeout(tmp_path: Path):
    role = "langgraph-conductor.coder"
    registry = _single_model(tmp_path, "import sys; print('x'); sys.exit(124)", role)
    result = RoleRunner(registry).run(role, "p", tmp_path)
    assert result.timed_out is False
    assert result.returncode == 124


def test_runner_reads_models_json_only_when_a_role_runs(tmp_path: Path, monkeypatch):
    """`status` builds the graph (and a RoleRunner) but never runs a role."""
    import pytest

    from agent_team_graph.registry import RegistryError

    bad = tmp_path / "models.json"
    bad.write_text("{not json", encoding="utf-8")
    monkeypatch.setenv("AGENT_TEAM_MODELS_CONFIG", str(bad))
    runner = RoleRunner()
    with pytest.raises(RegistryError):
        runner.run("langgraph-conductor.planner", "p", tmp_path)
