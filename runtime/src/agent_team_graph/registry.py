"""Safe Python implementation of the shared agent-team model registry contract."""

from __future__ import annotations

import json
import os
import subprocess
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

BUILTIN_MODELS: dict[str, dict[str, Any]] = {
    "agy": {"command": "agy", "env_command": "AGY_CLI", "args": ["-p", "{prompt}"]},
    "codex": {
        "command": "codex",
        "env_command": "CODEX_CLI",
        "args": ["exec", "--skip-git-repo-check", "{prompt}"],
        "final_args": [
            "exec",
            "--skip-git-repo-check",
            "--output-last-message",
            "{final}",
            "{prompt}",
        ],
    },
    "claude": {"command": "claude", "env_command": "CLAUDE_CLI", "args": ["-p", "{prompt}"]},
    # Headless `claude -p` cannot write files without an explicit permission
    # mode, so a coder bound to plain "claude" is a silent no-op. Kept as a
    # separate model so read-only roles never inherit edit rights.
    "claude-write": {
        "command": "claude",
        "env_command": "CLAUDE_CLI",
        "args": ["-p", "--permission-mode", "acceptEdits", "{prompt}"],
    },
}

BUILTIN_ROLES = {
    "langgraph-conductor.planner": "claude",
    "langgraph-conductor.coder": "claude-write",
    "langgraph-conductor.researcher": "agy",
    "langgraph-conductor.reviewer": "codex",
}

ROLE_ENV = {
    "langgraph-conductor.planner": "LANGGRAPH_CONDUCTOR_PLANNER_MODEL",
    "langgraph-conductor.coder": "LANGGRAPH_CONDUCTOR_CODER_MODEL",
    "langgraph-conductor.researcher": "LANGGRAPH_CONDUCTOR_RESEARCHER_MODEL",
    "langgraph-conductor.reviewer": "LANGGRAPH_CONDUCTOR_REVIEWER_MODEL",
}


def default_config_path() -> Path:
    explicit = os.environ.get("AGENT_TEAM_MODELS_CONFIG")
    if explicit:
        return Path(explicit).expanduser()
    root = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return root / "agent-team-plugins" / "models.json"


class RegistryError(RuntimeError):
    pass


class ModelRegistry:
    def __init__(self, config_path: Path | None = None):
        self.config_path = config_path or default_config_path()
        self._config = self._load()

    def _load(self) -> dict[str, Any]:
        if not self.config_path.exists():
            return {"version": 1, "models": {}, "roles": {}}
        try:
            value = json.loads(self.config_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RegistryError(f"invalid registry config {self.config_path}: {exc}") from exc
        if not isinstance(value, dict):
            raise RegistryError("registry config root must be an object")
        models = value.get("models", {})
        roles = value.get("roles", {})
        for name, section in (("models", models), ("roles", roles)):
            if not isinstance(section, dict):
                raise RegistryError(f"registry config {name!r} must be an object")
        for model_id, definition in models.items():
            if not isinstance(definition, dict):
                raise RegistryError(f"model {model_id!r} must be an object")
        return {"version": value.get("version", 1), "models": models, "roles": roles}

    @property
    def models(self) -> dict[str, dict[str, Any]]:
        return BUILTIN_MODELS | self._config["models"]

    def resolve_model(self, role: str) -> tuple[str, dict[str, Any]]:
        env_name = ROLE_ENV.get(role, "")
        model_id = (
            (os.environ.get(env_name) if env_name else None)
            or self._config["roles"].get(role)
            or BUILTIN_ROLES.get(role)
        )
        if not model_id or model_id not in self.models:
            raise RegistryError(f"role {role!r} does not resolve to a known model")
        return model_id, self.models[model_id]


@dataclass(frozen=True)
class RoleResult:
    invocation_id: str
    role: str
    model: str
    output: str
    returncode: int
    elapsed_ms: int
    usage_source: str = "unavailable"
    input_tokens: int | None = None
    output_tokens: int | None = None


class RoleRunner:
    """Run a configured CLI adapter without a shell or eval boundary."""

    def __init__(self, registry: ModelRegistry | None = None, timeout_seconds: int = 900):
        self.registry = registry or ModelRegistry()
        self.timeout_seconds = timeout_seconds

    def run(
        self,
        role: str,
        prompt: str,
        workspace: Path,
        final_path: Path | None = None,
    ) -> RoleResult:
        model_id, definition = self.registry.resolve_model(role)
        # Binary precedence mirrors registry.sh: caller override, then the
        # model's env_command, then its literal command.
        command = (
            os.environ.get("REGISTRY_CMD_OVERRIDE")
            or os.environ.get(definition.get("env_command", ""))
            or definition.get("command")
        )
        if not command:
            raise RegistryError(f"model {model_id!r} has no command")
        field = "final_args" if final_path and definition.get("final_args") else "args"
        template = definition.get(field)
        if not isinstance(template, list) or not all(isinstance(item, str) for item in template):
            raise RegistryError(f"model {model_id!r} has an invalid {field} template")
        replacements = {"{prompt}": prompt, "{final}": str(final_path or "")}
        argv = [command]
        for item in template:
            for marker, value in replacements.items():
                item = item.replace(marker, value)
            argv.append(item)
        started = time.monotonic()
        completed = subprocess.run(
            argv,
            cwd=workspace,
            text=True,
            capture_output=True,
            timeout=self.timeout_seconds,
            check=False,
        )
        elapsed_ms = round((time.monotonic() - started) * 1000)
        output = completed.stdout
        if final_path and final_path.exists():
            output = final_path.read_text(encoding="utf-8")
        elif completed.stderr:
            output += ("\n" if output else "") + completed.stderr
        return RoleResult(
            invocation_id=str(uuid.uuid4()),
            role=role,
            model=model_id,
            output=output,
            returncode=completed.returncode,
            elapsed_ms=elapsed_ms,
        )


def usage_record(result: RoleResult) -> dict[str, Any]:
    return asdict(result) | {"output": None}
