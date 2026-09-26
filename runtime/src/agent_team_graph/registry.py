"""Safe Python implementation of the shared agent-team model registry contract."""

from __future__ import annotations

import json
import os
import shutil
import stat
import tempfile
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from .process import Cancellation, run_process

BUILTIN_MODELS: dict[str, dict[str, Any]] = {
    # workspace_args/log_args mirror registry.sh; this runtime never passes
    # REGISTRY_WORKSPACE/REGISTRY_CLI_LOG. agy reads its prompt on stdin.
    "agy": {
        "command": "agy",
        "env_command": "AGY_CLI",
        "prompt_via": "stdin",
        "args": ["--input-format", "text", "--output-format", "text"],
        "workspace_args": ["--add-dir", "{cwd}"],
        "log_args": ["--log-file", "{cli_log}"],
    },
    # claude and codex read the prompt on stdin (#102): one argv element is
    # capped at 128 KiB on Linux, and specs plus research reach that.
    "codex": {
        "command": "codex",
        "env_command": "CODEX_CLI",
        "prompt_via": "stdin",
        "args": ["exec", "--skip-git-repo-check", "-"],
        "final_args": [
            "exec",
            "--skip-git-repo-check",
            "--output-last-message",
            "{final}",
            "-",
        ],
    },
    "codex-plan": {
        "command": "codex",
        "env_command": "CODEX_CLI",
        "prompt_via": "stdin",
        "args": ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "-"],
        "final_args": ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--output-last-message", "{final}", "-"],
    },
    "codex-write": {
        "command": "codex",
        "env_command": "CODEX_CLI",
        "prompt_via": "stdin",
        "args": ["exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "-"],
        "final_args": ["exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "--output-last-message", "{final}", "-"],
    },
    # Codex injects its memory summary into every `exec` prompt while the
    # memories feature is on, so a review would carry earlier sessions' context.
    "codex-no-memories": {
        "command": "codex",
        "env_command": "CODEX_CLI",
        "prompt_via": "stdin",
        "args": ["exec", "--skip-git-repo-check", "-c", "features.memories=false", "-"],
        "final_args": [
            "exec",
            "--skip-git-repo-check",
            "-c",
            "features.memories=false",
            "--output-last-message",
            "{final}",
            "-",
        ],
    },
    "claude": {"command": "claude", "env_command": "CLAUDE_CLI", "prompt_via": "stdin", "args": ["-p"]},
    # Headless `claude -p` cannot write files without an explicit permission
    # mode, so a coder bound to plain "claude" is a silent no-op. Kept as a
    # separate model so read-only roles never inherit edit rights.
    "claude-write": {
        "command": "claude",
        "env_command": "CLAUDE_CLI",
        "prompt_via": "stdin",
        "args": ["-p", "--permission-mode", "acceptEdits"],
    },
}

# Linux refuses one argv element of this many bytes or more (MAX_ARG_STRLEN,
# NUL included); registry.sh refuses the same prompts, on every platform.
ARGV_MAX_BYTES = 131072


# Placeholders a template may not hold. args runs exactly when nothing captures
# a final answer, so {final} there has no meaning; {cwd} and {cli_log} belong
# to registry.sh's caller-gated prefixes, which this runtime never applies.
_REFUSED_PLACEHOLDERS = {
    "args": ("{final}", "{cwd}", "{cli_log}"),
    "final_args": ("{cwd}", "{cli_log}"),
    # Checked only so a definition gets one verdict everywhere: registry.sh
    # reads these NUL-delimited, and a NUL would split an element in two.
    "workspace_args": (),
    "log_args": (),
}


def _template_problem(definition: dict[str, Any], field: str) -> str | None:
    template = definition[field]
    if not isinstance(template, list) or not all(isinstance(item, str) for item in template):
        return f"has {'an' if field == 'args' else 'a'} {field} template that is not an array of strings"
    if any("\0" in item for item in template):
        return f"has a NUL byte in its {field} template, which no argument can carry"
    for item in template:
        if item in _REFUSED_PLACEHOLDERS[field]:
            return (f"has {item} in its {field} template; {{final}} belongs in final_args, "
                    "{cwd} and {cli_log} in workspace_args and log_args")
    return None


def definition_problem(definition: Any) -> tuple[str, str] | None:
    """The model-definition rule: None, or (field, reason) for the first rule broken.

    registry.sh's _registry_def_problem applies the same rules in the same
    order; runtime/tests/test_registry_differential.py holds the two to one
    verdict and one field (#130).
    """
    if not isinstance(definition, dict):
        return "definition", "is not a JSON object"
    if "prompt_via" in definition and definition["prompt_via"] not in ("argv", "stdin"):
        return "prompt_via", f"has prompt_via {definition['prompt_via']!r}; use 'argv' or 'stdin'"
    if "args" not in definition:
        return "args", "has no args template; give one, [] for a stdin CLI that takes no arguments"
    for field in ("args", "final_args", "workspace_args", "log_args"):
        if field in definition and (why := _template_problem(definition, field)):
            return field, why
    if definition.get("prompt_via") == "stdin":
        for field in ("args", "final_args"):
            if "{prompt}" in definition.get(field, []):
                return field, (f"takes its prompt on stdin but its {field} template contains {{prompt}}; "
                               "remove it")
        return None
    # The template that runs must carry the prompt, or the CLI never sees it
    # (#119). run() uses final_args whenever it is non-empty.
    field = "final_args" if definition.get("final_args") else "args"
    if "{prompt}" not in definition[field]:
        return field, (f"takes its prompt as an argument but its {field} template has no {{prompt}}, "
                       "so the CLI would never see the prompt")
    return None


def check_definition(model_id: str, definition: Any) -> str:
    """Return the model's prompt_via, or raise what registry.sh rejects with rc 3."""
    problem = definition_problem(definition)
    if problem is not None:
        raise RegistryError(f"model {model_id!r} {problem[1]}")
    return definition.get("prompt_via", "argv")

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
        if not all(isinstance(value, str) for value in roles.values()):
            raise RegistryError("registry role bindings must be model ID strings")
        for model_id, definition in models.items():
            if not isinstance(definition, dict):
                raise RegistryError(f"model {model_id!r} must be an object")
            for field in ("command", "env_command"):
                if field in definition and not isinstance(definition[field], str):
                    raise RegistryError(f"model {model_id!r} {field} must be a string")
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


# Matches registry_run_answer in registry.sh: a zero exit with no answer.
NO_OUTPUT_RETURNCODE = 5


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
    stderr: str = ""
    timed_out: bool = False
    cancelled_signal: int | None = None
    cleanup_error: str = ""


class RoleRunner:
    """Run a configured CLI adapter without a shell or eval boundary."""

    def __init__(self, registry: ModelRegistry | None = None, timeout_seconds: float = 900,
                 cancellation: Cancellation | None = None):
        self._registry = registry
        self.timeout_seconds = timeout_seconds
        self.cancellation = cancellation

    @property
    def registry(self) -> ModelRegistry:
        if self._registry is None:
            self._registry = ModelRegistry()
        return self._registry

    def preflight(self, workspace: Path) -> None:
        for role in BUILTIN_ROLES:
            model_id, definition, _ = self.resolve_adapter(role, workspace)
            check_definition(model_id, definition)

    def resolve_adapter(self, role: str, workspace: Path) -> tuple[str, dict[str, Any], str]:
        """Resolve the model, definition and executable used for execution and call identity."""
        model_id, definition = self.registry.resolve_model(role)
        command = (
            os.environ.get("REGISTRY_CMD_OVERRIDE")
            or os.environ.get(definition.get("env_command", ""))
            or definition.get("command")
        )
        if not isinstance(command, str) or not command or "\0" in command:
            raise RegistryError(f"model {model_id!r} has no valid command")
        if os.sep in command:
            executable = (workspace / command).absolute()
            resolved = str(executable) if executable.is_file() and os.access(executable, os.X_OK) else None
        else:
            search_path = os.pathsep.join(
                str(workspace / entry) if not Path(entry).is_absolute() else entry
                for entry in os.environ.get("PATH", os.defpath).split(os.pathsep)
            )
            resolved = shutil.which(command, path=search_path)
        if not resolved:
            raise RegistryError(f"model {model_id!r} executable not found: {command}")
        return model_id, definition, resolved

    def run(
        self,
        role: str,
        prompt: str,
        workspace: Path,
        final_path: Path | None = None,
        timeout: float | None = None,
    ) -> RoleResult:
        timeout = self.timeout_seconds if timeout is None else timeout
        model_id, definition, command = self.resolve_adapter(role, workspace)
        # The whole definition, not only the template this call selects (#130).
        via = check_definition(model_id, definition)
        # The bytes the OS would see: os.fsencode's encoding for argv, and the
        # same bytes on stdin, so neither path rejects what the other accepts.
        encoded = prompt.encode("utf-8", errors="surrogateescape")
        # An argv template that runs always carries {prompt} (check_definition).
        if via == "argv" and len(encoded) >= ARGV_MAX_BYTES:
            raise RegistryError(
                f"model {model_id!r} takes its prompt as one argument, and this prompt is "
                f"{len(encoded)} bytes; Linux refuses a single argument of {ARGV_MAX_BYTES} bytes "
                "or more. Bind the role to a model with prompt_via 'stdin', or pass less context.")
        with tempfile.TemporaryDirectory(prefix="agent-team-answer-") as temporary:
            native = bool(definition.get("final_args"))
            capture = (final_path or Path(temporary) / "answer.md") if native else None
            if capture is not None and os.path.lexists(capture):
                raise RegistryError(f"final-answer path already exists: {capture}")
            template = definition["final_args" if native else "args"]
            replacements = {"{final}": str(capture or "")}
            if via == "argv":
                replacements["{prompt}"] = prompt
            argv = [command, *(replacements.get(item, item) for item in template)]
            completed = run_process(argv, cwd=workspace, timeout=timeout,
                                    cancellation=self.cancellation,
                                    input_bytes=encoded if via == "stdin" else None)
            returncode = completed.returncode
            output = completed.stdout if not native else ""
            diagnostic = completed.stderr
            if native:
                try:
                    fd = os.open(capture, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    with os.fdopen(fd, "rb") as answer:
                        if not stat.S_ISREG(os.fstat(answer.fileno()).st_mode):
                            raise ValueError("final-answer capture is not a regular file")
                        output = answer.read().decode("utf-8", errors="replace")
                except FileNotFoundError:
                    pass
                except (OSError, ValueError) as exc:
                    if returncode == 0:
                        returncode = 6
                    diagnostic += f"\ninvalid final-answer capture: {exc}"
            if returncode == 0 and not output.strip():
                returncode = NO_OUTPUT_RETURNCODE
                diagnostic = f"model {model_id!r} exited 0 with no output\n{diagnostic}"
            if completed.timed_out:
                diagnostic = f"role timed out after {timeout}s\n{diagnostic}"
            # Diagnostics are separate even for stdout-only adapters. They must
            # never become research, review or coder input.
            return RoleResult(
                invocation_id=str(uuid.uuid4()), role=role, model=model_id,
                output=output, returncode=returncode, elapsed_ms=completed.elapsed_ms,
                stderr=diagnostic, timed_out=completed.timed_out,
                cancelled_signal=completed.cancelled_signal,
                cleanup_error=completed.cleanup_error,
            )


def usage_record(result: RoleResult, run_id: str) -> dict[str, Any]:
    """One RFC 0004 harness receipt (schemas/rfc0004-manifest-v1.schema.json)."""
    return asdict(result) | {"run_id": run_id, "output": None, "stderr": None}
