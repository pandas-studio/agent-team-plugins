import json
import sys
from pathlib import Path

import pytest

from agent_team_graph.registry import ARGV_MAX_BYTES, ModelRegistry, RegistryError, RoleRunner


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
    assert "no output" in result.stderr
    assert "auto-denied" in result.stderr
    assert result.output == ""


def _native_runner(tmp_path, code):
    config = tmp_path / "native.json"
    config.write_text(json.dumps({
        # args lacks {prompt} on purpose: with final_args it never runs, and an
        # unused template is not a delivery error (#119).
        "models": {"native": {"command": sys.executable, "args": ["-c", "print('wrong')"],
                              "final_args": ["-c", code, "{final}", "{prompt}"]}},
        "roles": {"langgraph-conductor.planner": "native"},
    }))
    return RoleRunner(ModelRegistry(config))


def test_native_capture_is_authoritative_and_decodes_invalid_bytes(tmp_path):
    runner = _native_runner(tmp_path, (
        "import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b'answer\\xff\\r\\n'); "
        "print('stream diagnostic'); sys.stderr.write('stderr diagnostic')"
    ))
    result = runner.run("langgraph-conductor.planner", "q", tmp_path)
    assert result.returncode == 0
    assert result.output == "answer\ufffd\r\n"
    assert result.stderr == "stderr diagnostic"


def test_missing_native_answer_does_not_fall_back_to_stdout(tmp_path):
    result = _native_runner(tmp_path, "print('only diagnostic')").run(
        "langgraph-conductor.planner", "q", tmp_path,
    )
    assert result.returncode == 5 and result.output == ""


def test_native_symlink_is_capture_failure_and_nonzero_model_rc_wins(tmp_path):
    for rc in (0, 7):
        result = _native_runner(tmp_path, (
            "import pathlib,sys; pathlib.Path(sys.argv[1]).symlink_to('/dev/null'); "
            f"sys.exit({rc})"
        )).run("langgraph-conductor.planner", "q", tmp_path)
        assert result.returncode == (6 if rc == 0 else 7)


def test_existing_native_capture_is_never_reused(tmp_path):
    import pytest

    from agent_team_graph.registry import RegistryError

    stale = tmp_path / "stale.md"
    stale.write_text("old answer")
    runner = _native_runner(tmp_path, "print('diagnostic')")
    with pytest.raises(RegistryError, match="already exists"):
        runner.run("langgraph-conductor.planner", "q", tmp_path, final_path=stale)
    assert stale.read_text() == "old answer"


def test_stdout_answer_keeps_stderr_separate(tmp_path):
    config = tmp_path / "model.json"
    config.write_text(json.dumps({
        "models": {"fake": {"command": sys.executable, "args": ["-c",
                   "import os; os.write(1,b'answer\\xff'); os.write(2,b'diagnostic')", "{prompt}"]}},
        "roles": {"langgraph-conductor.planner": "fake"},
    }))
    result = RoleRunner(ModelRegistry(config)).run("langgraph-conductor.planner", "q", tmp_path)
    assert result.output == "answer\ufffd"
    assert result.stderr == "diagnostic"


def test_relative_path_entries_are_resolved_in_workspace(tmp_path, monkeypatch):
    tools = tmp_path / "bin"
    tools.mkdir()
    model = tools / "local-model"
    model.write_text("#!/bin/sh\nprintf 'workspace model\\n'\n")
    model.chmod(0o755)
    config = tmp_path / "relative.json"
    config.write_text(json.dumps({
        "models": {"fake": {"command": "local-model", "args": ["{prompt}"]}},
        "roles": {"langgraph-conductor.planner": "fake"},
    }))
    monkeypatch.setenv("PATH", "bin")
    result = RoleRunner(ModelRegistry(config)).run("langgraph-conductor.planner", "q", tmp_path)
    assert result.returncode == 0 and result.output == "workspace model\n"


def _planner_config(tmp_path, definition):
    config = tmp_path / "models.json"
    config.write_text(json.dumps({"models": {"fake": definition},
                                  "roles": {"langgraph-conductor.planner": "fake"}}))
    return RoleRunner(ModelRegistry(config))


READ_STDIN = ("import sys; data = sys.stdin.buffer.read(); "
              "print(len(data), sys.argv[1:], data[:9].decode())")


def test_stdin_model_gets_the_whole_prompt_on_stdin_and_none_in_argv(tmp_path):
    """#102: a prompt past Linux's 128 KiB single-argument cap still arrives."""
    runner = _planner_config(tmp_path, {"command": sys.executable, "prompt_via": "stdin",
                                        "args": ["-c", READ_STDIN, "-p"]})
    prompt = "BIG-PROMPT" + "x" * 300_000
    result = runner.run("langgraph-conductor.planner", prompt, tmp_path)
    assert result.returncode == 0, result.stderr
    assert result.output == f"{len(prompt)} ['-p'] BIG-PROMP\n"


def test_argv_model_refuses_a_prompt_one_argument_cannot_hold(tmp_path):
    runner = _planner_config(tmp_path, {"command": sys.executable,
                                        "args": ["-c", "print('ran')", "{prompt}"]})
    # Multibyte text: the limit is in bytes, not characters.
    prompt = "é" * (ARGV_MAX_BYTES // 2)
    with pytest.raises(RegistryError, match=f"{ARGV_MAX_BYTES} bytes; Linux refuses"):
        runner.run("langgraph-conductor.planner", prompt, tmp_path)
    assert runner.run("langgraph-conductor.planner", "é" * (ARGV_MAX_BYTES // 2 - 1),
                      tmp_path).output == "ran\n"


@pytest.mark.parametrize("definition, message", [
    ({"prompt_via": "file", "args": ["-c", "pass"]}, "prompt_via 'file'"),
    ({"prompt_via": "stdin", "args": ["-c", "pass", "{prompt}"]}, "args template contains"),
    ({"prompt_via": "stdin", "args": ["-c", "pass"],
      "final_args": ["-c", "pass", "{final}", "{prompt}"]}, "final_args template contains"),
])
def test_prompt_delivery_misconfiguration_is_refused_before_anything_runs(tmp_path, definition, message):
    runner = _planner_config(tmp_path, {"command": sys.executable, **definition})
    with pytest.raises(RegistryError, match=message):
        runner.run("langgraph-conductor.planner", "q", tmp_path)
    with pytest.raises(RegistryError, match=message):
        runner.preflight(tmp_path)


@pytest.mark.parametrize("templates, field", [
    ({"args": ["-c", "{code}"]}, "args"),
    ({"args": ["-c", "{code}"], "final_args": []}, "args"),
    ({"args": ["-c", "{code}", "{prompt}"], "final_args": ["-c", "{code}", "{final}"]}, "final_args"),
    ({"prompt_via": "argv", "args": ["-c", "{code}"]}, "args"),
])
def test_argv_model_whose_running_template_has_no_prompt_is_refused(tmp_path, templates, field):
    """#119: the CLI would run without ever seeing the prompt; nothing may start."""
    marker = tmp_path / "started"
    code = f"open({str(marker)!r}, 'w').close()"
    definition = {key: [code if item == "{code}" else item for item in value] if isinstance(value, list) else value
                  for key, value in templates.items()}
    runner = _planner_config(tmp_path, {"command": sys.executable, **definition})
    message = f"its {field} template has no {{prompt}}"
    with pytest.raises(RegistryError, match=message):
        runner.preflight(tmp_path)
    with pytest.raises(RegistryError, match=message):
        runner.run("langgraph-conductor.planner", "x" * (2 * ARGV_MAX_BYTES), tmp_path)
    assert not marker.exists()


def test_unused_args_without_prompt_is_accepted_beside_final_args(tmp_path):
    # preflight checks every role, so all four use this model: a passing
    # preflight must not depend on which CLIs the host has installed.
    config = tmp_path / "models.json"
    config.write_text(json.dumps({
        "models": {"fake": {"command": sys.executable, "args": ["-c", "pass"],
                            "final_args": ["-c", "pass", "{final}", "{prompt}"]}},
        "roles": {f"langgraph-conductor.{role}": "fake"
                  for role in ("planner", "researcher", "coder", "reviewer")},
    }))
    RoleRunner(ModelRegistry(config)).preflight(tmp_path)
