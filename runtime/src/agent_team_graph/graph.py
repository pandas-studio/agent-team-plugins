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

GATE_TIMEOUT_SECONDS = 900


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


def _under(path: str, roots: list[str]) -> bool:
    return any(path == root or path.startswith(root + "/") for root in roots)


def _keep(paths: list[str], excluded: list[str]) -> list[str]:
    return sorted({path for path in paths if path and not _under(path, excluded)})


def _changed_paths(
    repo_root: Path, base_sha: str, excluded: list[str]
) -> tuple[list[str], list[str]]:
    """Repository-root-relative (tracked-diff, untracked) path sets.

    Both git invocations run from the repository root so their output shares one
    base. `git diff --name-only` is always root-relative, while `git ls-files
    --others` is relative to — and scoped to — its working directory; running it
    anywhere but the root would both mislabel paths and hide files created
    outside that subtree.
    """
    tracked = _git(repo_root, "diff", "--name-only", base_sha, "--").splitlines()
    untracked = _git(repo_root, "ls-files", "--others", "--exclude-standard").splitlines()
    return _keep(tracked, excluded), _keep(untracked, excluded)


def _ignored_paths(repo_root: Path, excluded: list[str]) -> list[str]:
    """Untracked files that .gitignore hides from `_changed_paths`.

    Always reported so an operator can see writes the scope gate would otherwise
    never surface; only enforced when the run opts into `strict_ignored`, because
    a test command routinely creates ignored build output (`__pycache__`,
    `.venv`) before the gate ever looks.
    """
    listed = _git(
        repo_root, "ls-files", "--others", "--ignored", "--exclude-standard"
    ).splitlines()
    return _keep(listed, excluded)


def _outside_scope(changed: list[str], allowed: list[str]) -> list[str]:
    return [path for path in changed if not _under(path, allowed)]


def _repo_relative(repo_root: Path, path: Path) -> str | None:
    try:
        relative = path.expanduser().resolve().relative_to(repo_root)
    except ValueError:
        return None
    return relative.as_posix() or None


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
        return (
            shared
            + f"Plan:\n{state['plan']}\nIdentify relevant evidence and risks. Do not edit files."
        )
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
    state_root: Path | None = None,
):
    """Compile the graph with injected persistence and role execution boundaries."""

    role_runner = runner or RoleRunner()
    store = ArtifactStore(artifact_root)
    runtime_root = Path(state_root or artifact_root)

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
        repo_root = Path(_git(workspace, "rev-parse", "--show-toplevel")).resolve()
        base_sha = _git(repo_root, "rev-parse", "HEAD")
        # The runtime's own state (checkpoint db + artifacts) is machine-written,
        # never coder-written, so it must not count against the scope gate.
        excluded = [
            relative
            for relative in (_repo_relative(repo_root, runtime_root),)
            if relative is not None
        ]
        strict_ignored = bool(state.get("strict_ignored", False))
        spec_text = spec.read_text(encoding="utf-8")
        artifact = store.write_json(
            state["run_id"],
            "00-context.json",
            {
                "workspace": str(workspace),
                "repo_root": str(repo_root),
                "spec_path": str(spec),
                "base_sha": base_sha,
                "allowed_paths": allowed_paths,
                "excluded_paths": excluded,
                "strict_ignored": strict_ignored,
            },
        )
        return {
            "schema_version": "graph-run-v1",
            "workspace": str(workspace),
            "repo_root": str(repo_root),
            "spec_path": str(spec),
            "spec_sha256": hashlib.sha256(spec_text.encode()).hexdigest(),
            "base_sha": base_sha,
            "allowed_paths": allowed_paths,
            "excluded_paths": excluded,
            "strict_ignored": strict_ignored,
            "attempt": 0,
            "max_attempts": int(state.get("max_attempts", 2)),
            "status": "running",
            "artifacts": [artifact],
        }

    def invoke_role(state: GraphState, role: str, name: str) -> tuple[str, dict, dict]:
        try:
            result = role_runner.run(
                f"langgraph-conductor.{role}",
                _role_prompt(state, role),
                Path(state["workspace"]),
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(f"{role} timed out after {exc.timeout}s") from exc
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
        output, artifact, usage = invoke_role(staged, "coder", f"30-code-attempt-{attempt}.md")
        return {
            "attempt": attempt,
            "code_report": output,
            "artifacts": [artifact],
            "usage": [usage],
        }

    def gate_node(state: GraphState) -> dict[str, Any]:
        command = state.get("test_command", [])
        errors: list[str] = []
        if not command:
            passed, returncode, output = False, 2, "test_command is required"
        else:
            try:
                completed = subprocess.run(
                    command,
                    cwd=state["workspace"],
                    text=True,
                    capture_output=True,
                    check=False,
                    timeout=GATE_TIMEOUT_SECONDS,
                )
            except subprocess.TimeoutExpired as exc:
                # A hung test command is a gate failure, not a crashed run: record
                # it and let the bounded retry / human-stop paths handle it.
                passed, returncode = False, 124
                output = f"test command timed out after {GATE_TIMEOUT_SECONDS}s\n{exc.stdout or ''}"
                errors.append(f"gate attempt {state['attempt']}: test command timed out")
            else:
                passed, returncode = completed.returncode == 0, completed.returncode
                output = completed.stdout + completed.stderr
        repo_root = Path(state["repo_root"])
        excluded = state.get("excluded_paths", [])
        tracked, untracked = _changed_paths(repo_root, state["base_sha"], excluded)
        ignored = _ignored_paths(repo_root, excluded)
        changed = sorted(set(tracked) | set(untracked))
        scoped = sorted(set(changed) | set(ignored)) if state.get("strict_ignored") else changed
        outside_scope = _outside_scope(scoped, state["allowed_paths"])
        passed = passed and not outside_scope
        record = {
            "command": command,
            "returncode": returncode,
            "passed": passed,
            "changed_paths": changed,
            "untracked_paths": untracked,
            "ignored_paths": ignored,
            "strict_ignored": bool(state.get("strict_ignored", False)),
            "outside_scope": outside_scope,
            "output": output,
        }
        artifact = store.write_json(
            state["run_id"], f"40-gate-attempt-{state['attempt']}.json", record
        )
        update: dict[str, Any] = {"gate_passed": passed, "artifacts": [artifact]}
        if errors:
            update["errors"] = errors
        return update

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
        repo_root = Path(state["repo_root"])
        excluded = state.get("excluded_paths", [])
        diff = _git(repo_root, "diff", "--binary", state["base_sha"], "--")
        _, untracked = _changed_paths(repo_root, state["base_sha"], excluded)
        # `git diff` cannot see files git does not track yet, so a receipt built
        # from the diff alone would attest to an incomplete change set. Fold each
        # new file's content digest into the receipt hash.
        new_files = {
            path: hashlib.sha256((repo_root / path).read_bytes()).hexdigest()
            for path in untracked
        }
        manifest = diff + "".join(f"\n{path}\t{new_files[path]}" for path in sorted(new_files))
        receipt = {
            "approved": True,
            "base_sha": state["base_sha"],
            "head_sha": _git(repo_root, "rev-parse", "HEAD"),
            "tracked_diff_sha256": hashlib.sha256(diff.encode()).hexdigest(),
            "new_files": new_files,
            "change_sha256": hashlib.sha256(manifest.encode()).hexdigest(),
            "covers": "tracked diff against base_sha plus a content digest per untracked file",
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
        lambda state: review_route(
            state["verdict"], state["attempt"], state.get("max_attempts", 2)
        ),
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
