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
