#!/usr/bin/env python3
"""Optional native discovery smoke. Installs only in a disposable CODEX_HOME.

No user prompts are submitted and no model inference is requested.
Requires local codex and claude executables; intentionally separate from CI.
"""

import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CODEX_NAMES = {
    "eval-trio": {"evaluate"},
    "dev-trio": {"bootstrap", "research", "review", "install-pm"},
    "debate-conductor": {"bootstrap", "run", "continue", "install-pm"},
    "ralph-trio": {"bootstrap", "run", "install-pm"},
    "spec-trio": {"bootstrap", "run", "install-pm"},
}
CLAUDE_NAMES = {
    **CODEX_NAMES,
    "ralph-trio": {"bootstrap", "install-pm", "install-stop-hook"},
    "spec-trio": {"bootstrap", "install-pm"},
}


def send(process, message):
    process.stdin.write((json.dumps(message) + "\n").encode())
    process.stdin.flush()


def messages(process, timeout=30):
    deadline, buffer = time.monotonic() + timeout, b""
    while time.monotonic() < deadline:
        if not select.select([process.stdout], [], [], 0.5)[0]:
            continue
        data = os.read(process.stdout.fileno(), 65536)
        if not data:
            raise RuntimeError(f"loader exited before discovery (rc={process.poll()})")
        buffer += data
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue
    raise TimeoutError("loader discovery timed out")


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def check_codex(root):
    env = dict(os.environ, CODEX_HOME=str(root / "codex-home"))
    Path(env["CODEX_HOME"]).mkdir()
    for command in (
        ["codex", "plugin", "marketplace", "add", str(root), "--json"],
        *(["codex", "plugin", "add", name + "@pandas-studio", "--json"] for name in CODEX_NAMES),
    ):
        subprocess.run(command, cwd=root, env=env, check=True, capture_output=True, timeout=30)
    process = subprocess.Popen(["codex", "app-server", "--stdio"], cwd=root, env=env,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        send(process, {"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "dev-trio-discovery", "version": "1"},
            "capabilities": {"experimentalApi": True},
        }})
        for message in messages(process):
            if message.get("error"):
                raise RuntimeError(message["error"])
            if message.get("id") == 1:
                send(process, {"method": "initialized", "params": {}})
                send(process, {"id": 2, "method": "skills/list", "params": {
                    "cwds": [str(root)], "forceReload": True,
                }})
            elif message.get("id") == 2:
                data = message["result"]["data"][0]
                for plugin, names in CODEX_NAMES.items():
                    skills = [s for s in data["skills"] if s.get("pluginId") == plugin + "@pandas-studio"]
                    assert {s["name"] for s in skills} == {plugin + ":" + name for name in names}, skills
                    assert all(s["enabled"] and "/codex-skills/" in s["path"] for s in skills), skills
                assert not data.get("errors"), data.get("errors")
                print("Codex: all plugins loaded only their codex-skills")
                return
    finally:
        stop(process)


def check_claude(root, plugin):
    env = dict(os.environ, CLAUDE_CONFIG_DIR=str(root / "claude-config"))
    process = subprocess.Popen([
        "claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
        "--verbose", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "",
        "--plugin-dir", str(root / plugin),
    ], cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        send(process, {"type": "control_request", "request_id": "discovery",
                       "request": {"subtype": "initialize"}})
        for message in messages(process):
            if message.get("type") != "control_response":
                continue
            response = message["response"]
            assert response["subtype"] == "success", response
            commands = [c for c in response["response"]["commands"] if c["name"].startswith(plugin + ":")]
            assert {c["name"] for c in commands} == {plugin + ":" + name for name in CLAUDE_NAMES[plugin]}, commands
            # Check which host's variant was loaded, not merely the shared names.
            for command in commands:
                name = command["name"].split(":", 1)[1]
                text = (root / plugin / "claude-skills" / name / "SKILL.md").read_text()
                description = next(line.removeprefix("description: ") for line in text.splitlines()
                                   if line.startswith("description: "))
                assert description in command["description"], command
            print(f"Claude: {plugin} loaded only its Claude skills")
            return
    finally:
        stop(process)


def main():
    for cli in ("codex", "claude"):
        if not shutil.which(cli):
            raise SystemExit(f"{cli} is required for native loader checks")
    with tempfile.TemporaryDirectory(prefix="dev trio loaders ") as temporary:
        root = Path(temporary)
        for plugin in CODEX_NAMES:
            shutil.copytree(ROOT / plugin, root / plugin)
        shutil.copytree(ROOT / ".agents/plugins", root / ".agents/plugins")
        check_codex(root)
        for plugin in CLAUDE_NAMES:
            check_claude(root, plugin)


if __name__ == "__main__":
    main()
