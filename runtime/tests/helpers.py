"""Shared fixtures for the graph tests: a scripted runner and a throwaway repo."""

from __future__ import annotations

import subprocess
from pathlib import Path

from agent_team_graph.registry import RoleResult


class FakeRunner:
    """Stands in for the CLI adapters; optionally lets the coder touch the disk."""

    def __init__(
        self,
        verdicts: list[str] | None = None,
        writes: dict[str, str] | None = None,
    ):
        self.verdicts = list(verdicts or ["SHIP"])
        self.writes = writes or {}
        self.roles: list[str] = []

    def _next_verdict(self) -> str:
        # The last verdict repeats: a gate failure can drive an extra retry that
        # the caller did not have to script.
        return self.verdicts.pop(0) if len(self.verdicts) > 1 else self.verdicts[0]

    def run(self, role: str, prompt: str, workspace: Path) -> RoleResult:
        self.roles.append(role)
        output = f"output from {role}"
        if role.endswith(".coder"):
            for relative, content in self.writes.items():
                target = workspace / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content, encoding="utf-8")
        if role.endswith(".reviewer"):
            output = f"review complete\nVERDICT: {self._next_verdict()}"
        return RoleResult("fake-id", role, "fake", output, 0, 1)


def make_repo(tmp_path: Path) -> tuple[Path, Path]:
    workspace = tmp_path / "repo"
    workspace.mkdir()
    subprocess.run(["git", "init", "-q", workspace], check=True)
    subprocess.run(["git", "-C", workspace, "config", "user.email", "test@example.com"], check=True)
    subprocess.run(["git", "-C", workspace, "config", "user.name", "Test"], check=True)
    (workspace / "README.md").write_text("demo\n", encoding="utf-8")
    subprocess.run(["git", "-C", workspace, "add", "README.md"], check=True)
    subprocess.run(["git", "-C", workspace, "commit", "-qm", "init"], check=True)
    spec = tmp_path / "SPEC.md"
    spec.write_text("# bounded task\n", encoding="utf-8")
    return workspace, spec


def initial(workspace: Path, spec: Path, thread_id: str = "demo-thread") -> dict:
    return {
        "thread_id": thread_id,
        "run_id": f"run-{thread_id}",
        "project_id": "demo",
        "workspace": str(workspace),
        "spec_path": str(spec),
        "task": "implement one vertical slice",
        "test_command": ["git", "status", "--short"],
        "allowed_paths": ["README.md"],
        "max_attempts": 2,
        "artifacts": [],
        "usage": [],
        "errors": [],
    }
