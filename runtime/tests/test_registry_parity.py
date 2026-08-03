"""`registry.py` is a hand-written port of `registry.sh` — hold them to one contract.

The bash library is the canonical source (vendored byte-for-byte into
debate-conductor). Without this test the Python copy silently drifts the first
time a model or role is added on only one side.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from agent_team_graph.registry import BUILTIN_MODELS, BUILTIN_ROLES, ROLE_ENV

REGISTRY_SH = Path(__file__).resolve().parents[2] / "dev-trio" / "lib" / "registry.sh"


def _heredoc(function: str) -> dict:
    source = REGISTRY_SH.read_text(encoding="utf-8")
    body = re.search(
        rf"^{re.escape(function)}\(\) \{{\n  cat <<'JSON'\n(.*?)\nJSON\n",
        source,
        re.DOTALL | re.MULTILINE,
    )
    assert body, f"could not extract {function} from {REGISTRY_SH}"
    return json.loads(body.group(1))


def test_builtin_models_match_the_bash_registry():
    assert BUILTIN_MODELS == _heredoc("_registry_builtin_models")


def test_langgraph_conductor_role_bindings_match_the_bash_registry():
    bash_roles = _heredoc("_registry_builtin_roles")
    conductor = {k: v for k, v in bash_roles.items() if k.startswith("langgraph-conductor.")}
    assert BUILTIN_ROLES == conductor


def test_every_role_has_an_env_override_and_is_known_to_bash():
    source = REGISTRY_SH.read_text(encoding="utf-8")
    assert set(ROLE_ENV) == set(BUILTIN_ROLES)
    for role, env_name in ROLE_ENV.items():
        assert re.search(rf"^\s*{re.escape(role)}\)\s*printf '{env_name}'", source, re.MULTILINE), (
            f"{role} -> {env_name} missing from _registry_role_envname"
        )


def test_every_role_resolves_to_a_defined_model():
    for role, model_id in BUILTIN_ROLES.items():
        assert model_id in BUILTIN_MODELS, f"{role} points at unknown model {model_id!r}"


def test_coder_can_actually_write():
    """Headless `claude -p` is read-only without an explicit permission mode."""
    coder = BUILTIN_MODELS[BUILTIN_ROLES["langgraph-conductor.coder"]]
    assert "--permission-mode" in coder["args"]
