"""A bounded, checkpointable role workflow for one engineering task."""

from __future__ import annotations

import hashlib
import re
import subprocess
from pathlib import Path
from typing import Any, Protocol

from langgraph.graph import END, START, StateGraph
from langgraph.types import interrupt

from .artifacts import ArtifactStore
from .policy import approval_route, parse_verdict, review_route
from .registry import RoleResult, RoleRunner, usage_record
from .state import GraphState


class Runner(Protocol):
    def run(self, role: str, prompt: str, workspace: Path) -> RoleResult: ...


def _git(workspace: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(workspace), *args],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def _normalize_allowed(paths: list[str]) -> list[str]:
    normalized: list[str] = []
    for value in paths:
        candidate = value.replace("\\", "/").strip().rstrip("/")
        parts = Path(candidate).parts
        if not candidate or candidate.startswith("/") or ".." in parts or candidate == ".":
            raise ValueError(f"unsafe allowed path: {value!r}")
        normalized.append(candidate)
    return normalized


def _changed_paths(workspace: Path, base_sha: str) -> list[str]:
    tracked = _git(workspace, "diff", "--name-only", base_sha, "--").splitlines()
    untracked = _git(workspace, "ls-files", "--others", "--exclude-standard").splitlines()
    return sorted(
        {
            path
            for path in tracked + untracked
            if path and path != ".agent-team" and not path.startswith(".agent-team/")
        }
    )


def _outside_scope(changed: list[str], allowed: list[str]) -> list[str]:
    return [
        path
        for path in changed
        if not any(path == root or path.startswith(root + "/") for root in allowed)
    ]


def _role_prompt(state: GraphState, role: str) -> str:
    shared = (
        f"Task: {state['task']}\n"
        f"Specification: {state['spec_path']}\n"
        f"Workspace: {state['workspace']}\n"
        f"Attempt: {state.get('attempt', 0)}/{state.get('max_attempts', 2)}\n"
    )
    if role == "planner":
        return shared + "Produce a concise implementation plan. Do not edit files."
    if role == "researcher":
        return shared + f"Plan:\n{state['plan']}\nIdentify relevant evidence and risks. Do not edit files."
    if role == "coder":
        return (
            shared
            + f"Plan:\n{state['plan']}\nResearch:\n{state['research']}\n"
            + f"Previous review:\n{state.get('review', '(none)')}\n"
            + "Implement the task in the workspace. Stay within the specification."
        )
    return (
        shared
        + f"Plan:\n{state['plan']}\nResearch:\n{state['research']}\n"
        + f"Coder report:\n{state['code_report']}\nGate passed: {state['gate_passed']}\n"
        + "Review the current git diff. End with exactly one line: "
        + "VERDICT: SHIP, VERDICT: NEEDS-FIX, VERDICT: DISCUSS, or VERDICT: OUT-OF-SCOPE."
    )


def build_graph(
    *,
    checkpointer: Any,
    artifact_root: Path,
    runner: Runner | None = None,
):
    """Compile the graph with injected persistence and role execution boundaries."""

    role_runner = runner or RoleRunner()
    store = ArtifactStore(artifact_root)

    def context_node(state: GraphState) -> dict[str, Any]:
        workspace = Path(state["workspace"]).expanduser().resolve()
        spec = Path(state["spec_path"]).expanduser().resolve()
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,47}", state["project_id"]):
            raise ValueError("project_id must be a safe 1-48 character identifier")
        if not workspace.is_dir() or not spec.is_file():
            raise ValueError("workspace must be a directory and spec_path must be a file")
        allowed_paths = _normalize_allowed(state.get("allowed_paths", []))
        if not allowed_paths:
            raise ValueError("at least one allowed path is required")
        _git(workspace, "rev-parse", "--is-inside-work-tree")
        base_sha = _git(workspace, "rev-parse", "HEAD")
        spec_text = spec.read_text(encoding="utf-8")
        artifact = store.write_json(
            state["run_id"],
            "00-context.json",
            {
                "workspace": str(workspace),
                "spec_path": str(spec),
                "base_sha": base_sha,
                "allowed_paths": allowed_paths,
            },
        )
        return {
            "schema_version": "graph-run-v1",
            "workspace": str(workspace),
            "spec_path": str(spec),
            "spec_sha256": hashlib.sha256(spec_text.encode()).hexdigest(),
            "base_sha": base_sha,
            "allowed_paths": allowed_paths,
            "attempt": 0,
            "status": "running",
            "artifacts": [artifact],
        }

    def invoke_role(state: GraphState, role: str, name: str) -> tuple[str, dict, dict]:
        result = role_runner.run(
            f"langgraph-conductor.{role}",
            _role_prompt(state, role),
            Path(state["workspace"]),
        )
        if result.returncode:
            raise RuntimeError(f"{role} failed with exit code {result.returncode}: {result.output}")
        artifact = store.write(state["run_id"], name, result.output)
        return result.output, artifact, usage_record(result)

    def planner_node(state: GraphState) -> dict[str, Any]:
        output, artifact, usage = invoke_role(state, "planner", "10-plan.md")
        return {"plan": output, "artifacts": [artifact], "usage": [usage]}

    def researcher_node(state: GraphState) -> dict[str, Any]:
        output, artifact, usage = invoke_role(state, "researcher", "20-research.md")
        return {"research": output, "artifacts": [artifact], "usage": [usage]}

    def coder_node(state: GraphState) -> dict[str, Any]:
        attempt = state.get("attempt", 0) + 1
        staged = dict(state)
        staged["attempt"] = attempt
        output, artifact, usage = invoke_role(
            staged, "coder", f"30-code-attempt-{attempt}.md"
        )
        return {
            "attempt": attempt,
            "code_report": output,
            "artifacts": [artifact],
            "usage": [usage],
        }

    def gate_node(state: GraphState) -> dict[str, Any]:
        command = state.get("test_command", [])
        if not command:
            passed, returncode, output = False, 2, "test_command is required"
        else:
            completed = subprocess.run(
                command,
                cwd=state["workspace"],
                text=True,
                capture_output=True,
                check=False,
                timeout=900,
            )
            passed, returncode = completed.returncode == 0, completed.returncode
            output = completed.stdout + completed.stderr
        changed = _changed_paths(Path(state["workspace"]), state["base_sha"])
        outside_scope = _outside_scope(changed, state["allowed_paths"])
        passed = passed and not outside_scope
        record = {
            "command": command,
            "returncode": returncode,
            "passed": passed,
            "changed_paths": changed,
            "outside_scope": outside_scope,
            "output": output,
        }
        artifact = store.write_json(
            state["run_id"], f"40-gate-attempt-{state['attempt']}.json", record
        )
        return {"gate_passed": passed, "artifacts": [artifact]}

    def reviewer_node(state: GraphState) -> dict[str, Any]:
        output, artifact, usage = invoke_role(
            state, "reviewer", f"50-review-attempt-{state['attempt']}.md"
        )
        verdict = parse_verdict(output)
        if not state["gate_passed"] and verdict == "SHIP":
            verdict = "NEEDS-FIX"
        return {
            "review": output,
            "verdict": verdict,
            "artifacts": [artifact],
            "usage": [usage],
        }

    def approval_node(state: GraphState) -> dict[str, Any]:
        decision = interrupt(
            {
                "kind": "ship-approval",
                "thread_id": state["thread_id"],
                "verdict": state["verdict"],
                "base_sha": state["base_sha"],
                "attempt": state["attempt"],
            }
        )
        normalized = decision.get("decision") if isinstance(decision, dict) else decision
        if normalized not in {"approve", "reject"}:
            normalized = "reject"
        return {"approval": normalized}

    def publish_node(state: GraphState) -> dict[str, Any]:
        diff = _git(Path(state["workspace"]), "diff", "--binary", state["base_sha"], "--")
        receipt = {
            "approved": True,
            "base_sha": state["base_sha"],
            "head_sha": _git(Path(state["workspace"]), "rev-parse", "HEAD"),
            "diff_sha256": hashlib.sha256(diff.encode()).hexdigest(),
            "note": "approval receipt only; this runtime never pushes or force-merges",
        }
        artifact = store.write_json(state["run_id"], "90-approval-receipt.json", receipt)
        return {"status": "approved", "artifacts": [artifact]}

    def stop_node(state: GraphState) -> dict[str, Any]:
        status = "rejected" if state.get("approval") == "reject" else "needs-human"
        return {"status": status}

    builder = StateGraph(GraphState)
    builder.add_node("context", context_node)
    builder.add_node("planner", planner_node)
    builder.add_node("researcher", researcher_node)
    builder.add_node("coder", coder_node)
    builder.add_node("gate", gate_node)
    builder.add_node("reviewer", reviewer_node)
    builder.add_node("approval", approval_node)
    builder.add_node("publish", publish_node)
    builder.add_node("stop", stop_node)
    builder.add_edge(START, "context")
    builder.add_edge("context", "planner")
    builder.add_edge("planner", "researcher")
    builder.add_edge("researcher", "coder")
    builder.add_edge("coder", "gate")
    builder.add_edge("gate", "reviewer")
    builder.add_conditional_edges(
        "reviewer",
        lambda state: review_route(state["verdict"], state["attempt"], state["max_attempts"]),
        {"approval": "approval", "retry": "coder", "stop": "stop"},
    )
    builder.add_conditional_edges(
        "approval",
        lambda state: approval_route(state["approval"]),
        {"publish": "publish", "stop": "stop"},
    )
    builder.add_edge("publish", END)
    builder.add_edge("stop", END)
    return builder.compile(checkpointer=checkpointer)
