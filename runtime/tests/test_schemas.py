"""The published schemas must describe what the runtime actually checkpoints and records."""

from __future__ import annotations

import json
import sqlite3
from dataclasses import replace
from pathlib import Path

import pytest
from helpers import FakeRunner, initial, make_repo
from jsonschema import Draft202012Validator
from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.types import Command

from agent_team_graph.graph import build_graph

SCHEMAS = Path(__file__).resolve().parents[1] / "schemas"


def _validator(name: str) -> Draft202012Validator:
    schema = json.loads((SCHEMAS / name).read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


RUN = _validator("graph-run-v1.schema.json")
RECEIPT = _validator("rfc0004-manifest-v1.schema.json")


def _conforms(values: dict) -> None:
    assert list(RUN.iter_errors(values)) == []
    assert values["usage"]
    for usage in values["usage"]:
        assert list(RECEIPT.iter_errors(usage)) == []
        assert usage["run_id"] == values["run_id"]


def _run(tmp_path: Path, runner: FakeRunner, **overrides):
    workspace, spec = make_repo(tmp_path)
    connection = sqlite3.connect(tmp_path / "runs.sqlite3", check_same_thread=False)
    graph = build_graph(checkpointer=SqliteSaver(connection),
                        artifact_root=tmp_path / "artifacts", runner=runner)
    config = {"configurable": {"thread_id": "demo-thread"}}
    graph.invoke(initial(workspace, spec) | overrides, config=config)
    return graph, config


def test_approved_run_conforms_at_the_interrupt_and_the_end(tmp_path: Path):
    graph, config = _run(tmp_path, FakeRunner(),
                         role_timeout_seconds=30, gate_timeout_seconds=60)
    parked = graph.get_state(config).values
    _conforms(parked)
    assert (parked["role_timeout_seconds"], parked["gate_timeout_seconds"]) == (30, 60)
    digest = parked["reviewed_change_sha256"]
    graph.invoke(Command(resume={"decision": "approve", "reviewed_change_sha256": digest}),
                 config=config)
    done = graph.get_state(config).values
    _conforms(done)
    assert done["status"] == "approved" and done["approved_change_sha256"] == digest


def test_rejected_run_conforms(tmp_path: Path):
    graph, config = _run(tmp_path, FakeRunner())
    graph.invoke(Command(resume={"decision": "reject", "reviewed_change_sha256": None}),
                 config=config)
    values = graph.get_state(config).values
    _conforms(values)
    assert values["status"] == "rejected" and values["approved_change_sha256"] is None
    # Defaults are written into the checkpoint, not left implicit.
    assert (values["role_timeout_seconds"], values["gate_timeout_seconds"]) == (900, 900)


class FailingCoder(FakeRunner):
    def run(self, role, prompt, workspace):
        result = super().run(role, prompt, workspace)
        return replace(result, returncode=1) if role.endswith(".coder") else result


def test_failed_role_conforms_with_null_digests(tmp_path: Path):
    graph, config = _run(tmp_path, FailingCoder(), max_attempts=1)
    values = graph.get_state(config).values
    _conforms(values)
    assert values["status"] == "needs-human"
    assert values["gated_change_sha256"] is None and values["reviewed_change_sha256"] is None


def test_failed_gate_conforms(tmp_path: Path):
    graph, config = _run(tmp_path, FakeRunner(), max_attempts=1, test_command=["false"])
    values = graph.get_state(config).values
    _conforms(values)
    assert values["status"] == "needs-human" and values["gate_passed"] is False


def test_exhausted_five_attempt_budget_conforms(tmp_path: Path):
    graph, config = _run(tmp_path, FakeRunner(["NEEDS-FIX"]), max_attempts=5)
    values = graph.get_state(config).values
    _conforms(values)
    assert values["status"] == "needs-human" and values["attempt"] == 5


@pytest.mark.parametrize("validator, mutate", [
    (RUN, lambda v: v.pop("run_id")),
    (RUN, lambda v: v.update(status="not-found")),
    (RUN, lambda v: v.update(reviewed_change_sha256="ABC")),
    (RUN, lambda v: v.update(gate_timeout_seconds=0)),
    (RECEIPT, lambda v: v.pop("run_id")),
    (RECEIPT, lambda v: v.update(usage_source="guessed")),
])
def test_schemas_reject_drifted_records(tmp_path: Path, validator, mutate):
    """Negative controls: the checks above would catch the drift they exist for."""
    graph, config = _run(tmp_path, FakeRunner())
    values = dict(graph.get_state(config).values)
    record = values if validator is RUN else dict(values["usage"][0])
    assert list(validator.iter_errors(record)) == []
    mutate(record)
    assert list(validator.iter_errors(record)) != []
