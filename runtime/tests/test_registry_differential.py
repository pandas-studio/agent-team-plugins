"""`registry.sh` and `registry.py` apply one model-definition contract (#130).

Both implementations stay native: the runtime depends on neither bash nor jq, so
this test is the one place that runs the bash library next to the Python one.
Every named case in tests/fixtures/model-definition-cases.json and every
generated shape must get the same verdict, with the same rejected field, from
both; every valid definition must run the same argv on both.
"""

from __future__ import annotations

import itertools
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from agent_team_graph import registry
from agent_team_graph.registry import (
    BUILTIN_MODELS,
    ROLE_ENV,
    ModelRegistry,
    RegistryError,
    RoleRunner,
)

ROOT = Path(__file__).resolve().parents[2]
REGISTRY_SH = ROOT / "dev-trio" / "lib" / "registry.sh"
CASES = json.loads((ROOT / "tests" / "fixtures" / "model-definition-cases.json").read_text(encoding="utf-8"))
ROLE = "langgraph-conductor.planner"
# A literal {final} inside the prompt is text, not a placeholder.
PROMPT = "line one\nline two  {final} spaced"


def _bashes() -> list[str]:
    """bash on PATH, plus /bin/bash when it is another binary (macOS ships 3.2 there)."""
    found: list[str] = []
    for candidate in (shutil.which("bash"), "/bin/bash"):
        if candidate and os.path.exists(candidate) and all(
                not os.path.samefile(candidate, other) for other in found):
            found.append(candidate)
    return found


BASHES = _bashes()
# CI must run this; a developer without bash or jq may skip it.
pytestmark = pytest.mark.skipif(
    os.environ.get("CI") != "true" and (not BASHES or not shutil.which("jq")),
    reason="bash and jq are needed to run registry.sh")


def _bash_env(tmp_path: Path, **extra: str) -> dict[str, str]:
    """Nothing from the host but PATH: no role, command or registry override leaks in."""
    return {"PATH": os.environ["PATH"], "HOME": str(tmp_path), "TMPDIR": str(tmp_path),
            "AGENT_TEAM_MODELS_CONFIG": str(tmp_path / "absent.json"), **extra}


@pytest.fixture
def isolated(monkeypatch):
    for name in ("REGISTRY_CMD_OVERRIDE", "REGISTRY_WORKSPACE", "REGISTRY_CLI_LOG",
                 "AGENT_TEAM_MODELS_CONFIG", *ROLE_ENV.values(),
                 *(model["env_command"] for model in BUILTIN_MODELS.values())):
        monkeypatch.delenv(name, raising=False)
    return monkeypatch


# ---- verdicts ---------------------------------------------------------------

BASH_CHECK = r'''
set -euo pipefail
. "$1"
while IFS= read -r line; do
  _registry_def_problem "$line" || printf '"not-json"\n'
done
'''


def _bash_fields(bash: str, definitions: list, tmp_path: Path) -> list:
    """The field registry.sh rejects each definition on, or None when it is valid."""
    lines = "".join(json.dumps(definition) + "\n" for definition in definitions)
    completed = subprocess.run([bash, "-c", BASH_CHECK, "_", str(REGISTRY_SH)], input=lines,
                               capture_output=True, text=True, env=_bash_env(tmp_path), check=True)
    results = [json.loads(line) for line in completed.stdout.splitlines()]
    assert len(results) == len(definitions), completed.stderr
    return [result if result is None or isinstance(result, str) else result["field"] for result in results]


def _listed(rows: list) -> str:
    """Every disagreement, one per line: the first alone would hide the rest."""
    return f"{len(rows)} disagreement(s):\n" + "\n".join(repr(row) for row in rows)


def _python_field(definition):
    problem = registry.definition_problem(definition)
    return None if problem is None else problem[0]


@pytest.mark.parametrize("bash", BASHES)
def test_named_cases_get_the_expected_verdict_from_both(bash, tmp_path):
    fields = _bash_fields(bash, [case["definition"] for case in CASES], tmp_path)
    wrong = [(case["name"], case["expect"], {"bash": field, "python": _python_field(case["definition"])})
             for case, field in zip(CASES, fields)
             if field != case["expect"] or _python_field(case["definition"]) != case["expect"]]
    assert not wrong, _listed(wrong)


ABSENT = object()
PROMPT_VIA = [ABSENT, "argv", "stdin", None, False, "file", "x\ny", "a\u0000"]
ARGS = [ABSENT, None, "x", [], [1], ["{prompt}"], ["-p"], ["-p", "{prompt}"], ["{final}", "{prompt}"],
        ["{cwd}", "{prompt}"], ["{cli_log}"], ["a\nb", "{prompt}"], ["a\u0000b", "{prompt}"], ["", "{prompt}"]]
FINAL_ARGS = [ABSENT, None, "x", [], [2], ["{final}"], ["{final}", "{prompt}"], ["{final}", "-"],
              ["{cwd}", "{final}", "{prompt}"], ["a\u0000", "{prompt}"], ["x\n", "{final}", "{prompt}"]]


PREFIXES = [None, "x", [], [3], ["--add-dir", "{cwd}"], ["a\nb"], ["--safe\u0000--danger"]]


def _generated_shapes() -> list:
    shapes: list = []
    for values in itertools.product(PROMPT_VIA, ARGS, FINAL_ARGS):
        shapes.append({key: value for key, value in zip(("prompt_via", "args", "final_args"), values)
                       if value is not ABSENT})
    for field, value in itertools.product(("workspace_args", "log_args"), PREFIXES):
        shapes.append({"args": ["{prompt}"], field: value})
        shapes.append({"args": ["{prompt}"], "final_args": None, field: value})
    return shapes + ["invalid", [], 1, None, True]


@pytest.mark.parametrize("bash", BASHES)
def test_generated_shapes_get_the_same_verdict_from_both(bash, tmp_path):
    shapes = _generated_shapes()
    fields = _bash_fields(bash, shapes, tmp_path)
    differ = [(shape, {"bash": field, "python": _python_field(shape)})
              for shape, field in zip(shapes, fields) if field != _python_field(shape)]
    assert not differ, _listed(differ)
    # Both verdicts occur, so agreement is not agreement on everything.
    assert None in fields and "args" in fields and "final_args" in fields and "prompt_via" in fields


# ---- execution --------------------------------------------------------------

RECORDER = "#!/usr/bin/env bash\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done > \"$REC_OUT\"\n"

BASH_RUN = r'''
set -euo pipefail
. "$1"
while IFS=$'\t' read -r config out final; do
  export AGENT_TEAM_MODELS_CONFIG="$config" REC_OUT="$out"
  rc=0
  if [ -n "$final" ]; then
    registry_run m "$PROMPT" "$final" </dev/null || rc=$?
  else
    registry_run m "$PROMPT" </dev/null || rc=$?
  fi
  printf '%s\n' "$rc"
done
'''


def _recorded(out: Path) -> list[str]:
    return [item.decode("utf-8") for item in out.read_bytes().split(b"\0")[:-1]]


def _execution_cases() -> list[tuple[str, dict, dict | None]]:
    """(name, definition, expected argv or None) for every valid definition."""
    cases = [(case["name"], case["definition"], case.get("argv")) for case in CASES if case["expect"] is None]
    cases += [(f"built-in {model_id}", definition, None) for model_id, definition in BUILTIN_MODELS.items()]
    # One long element, as valid UTF-8 (two bytes per character).
    cases.append(("64 KiB element", {"args": ["é" * 32768, "{prompt}"]}, None))
    # Valid by the Python rule; one bash refuses shows up as a refused run.
    cases += [(f"generated {json.dumps(shape)}", shape, None)
              for shape in _generated_shapes() if _python_field(shape) is None]
    return cases


@pytest.mark.parametrize("bash", BASHES)
def test_valid_definitions_run_the_same_argv_on_both(bash, tmp_path, isolated):
    recorder = tmp_path / "recorder"
    recorder.write_text(RECORDER)
    recorder.chmod(0o755)
    final = tmp_path / "answer.md"
    runs = []  # (name, mode, definition, expected)
    for name, definition, expected in _execution_cases():
        runs.append((name, "final", definition, (expected or {}).get("final")))
        # The runtime always captures when final_args is non-empty, so it has no
        # run without a final file to compare for such a model.
        if not definition.get("final_args"):
            runs.append((name, "no_final", definition, (expected or {}).get("no_final")))

    lines = []
    for index, (_, mode, definition, _) in enumerate(runs):
        config = tmp_path / f"bash-{index}.json"
        config.write_text(json.dumps({"models": {"m": {**definition, "command": str(recorder)}}}))
        lines.append(f"{config}\t{tmp_path / f'bash-{index}.argv'}\t{final if mode == 'final' else ''}\n")
    completed = subprocess.run([bash, "-c", BASH_RUN, "_", str(REGISTRY_SH)], input="".join(lines),
                               capture_output=True, text=True, check=True,
                               env=_bash_env(tmp_path, PROMPT=PROMPT))
    statuses = completed.stdout.splitlines()
    assert len(statuses) == len(runs), completed.stderr

    differ = []
    for index, (name, mode, definition, expected) in enumerate(runs):
        bash_argv = (_recorded(tmp_path / f"bash-{index}.argv") if statuses[index] == "0"
                     else f"refused rc={statuses[index]}")
        out = tmp_path / f"runtime-{index}.argv"
        config = tmp_path / f"runtime-{index}.json"
        config.write_text(json.dumps({"models": {"m": {**definition, "command": str(recorder)}},
                                      "roles": {ROLE: "m"}}))
        isolated.setenv("REC_OUT", str(out))
        try:
            RoleRunner(ModelRegistry(config)).run(ROLE, PROMPT, tmp_path,
                                                  final_path=final if mode == "final" else None)
            runtime_argv = _recorded(out)
        except RegistryError as exc:
            runtime_argv = f"refused: {exc}"
        assert not final.exists()
        if expected is not None:
            expected = [PROMPT if item == "<prompt>" else str(final) if item == "<final>" else item
                        for item in expected]
        if bash_argv != runtime_argv or (expected is not None and runtime_argv != expected):
            differ.append((name, mode, {"bash": bash_argv, "runtime": runtime_argv, "expected": expected}))
    assert not differ, _listed(differ)


@pytest.mark.parametrize("bash", BASHES)
@pytest.mark.parametrize("workspace, cli_log, argv", [
    ("", "", []),
    ("/r", "", ["--add-dir", "/r"]),
    ("", "/l", ["--log-file", "/l"]),
    ("/r", "/l", ["--log-file", "/l", "--add-dir", "/r"]),
])
def test_empty_args_with_each_prefix(bash, tmp_path, workspace, cli_log, argv):
    """bash 3.2 under `set -u` fails on an empty array expanded bare; the runtime has no prefixes."""
    recorder = tmp_path / "recorder"
    recorder.write_text(RECORDER)
    recorder.chmod(0o755)
    config = tmp_path / "models.json"
    config.write_text(json.dumps({"models": {"m": {
        "command": str(recorder), "prompt_via": "stdin", "args": [],
        "workspace_args": ["--add-dir", "{cwd}"], "log_args": ["--log-file", "{cli_log}"]}}}))
    out = tmp_path / "argv"
    subprocess.run([bash, "-c", 'set -euo pipefail; . "$1"; registry_run m P </dev/null', "_", str(REGISTRY_SH)],
                   check=True, env=_bash_env(tmp_path, AGENT_TEAM_MODELS_CONFIG=str(config), REC_OUT=str(out),
                                             REGISTRY_WORKSPACE=workspace, REGISTRY_CLI_LOG=cli_log))
    assert _recorded(out) == argv
