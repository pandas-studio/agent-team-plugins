"""Read-only setup checks, deliberately not a model or permission-engine probe."""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def check_settings(path: Path) -> bool:
    print(f"agy settings: {path}")
    try:
        settings = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print("[warn] No settings file; CLI defaults apply. Research permissions are unverified.")
        return True
    except (OSError, UnicodeError, ValueError):
        print("[FAIL] Settings are unreadable or invalid JSON. Repair the file in agy or an editor.")
        return False
    if not isinstance(settings, dict):
        print("[FAIL] Settings must be a JSON object.")
        return False
    permissions = settings.get("permissions", {})
    if not isinstance(permissions, dict):
        print("[FAIL] permissions must be an object containing allow/ask/deny arrays.")
        return False
    for key in ("allow", "ask", "deny"):
        rules = permissions.get(key, [])
        if not isinstance(rules, list) or any(not isinstance(rule, str) for rule in rules):
            print(f"[FAIL] permissions.{key} must be an array of strings.")
            return False
        # Do not dump rules: they can contain private paths, commands or URLs.
        print(f"[info] permissions.{key}: {len(rules)} rule(s)")
        if any(rule.strip().startswith("unsandboxed(") for rule in rules):
            print("[warn] Legacy unsandboxed(...) rules found. Check this CLI's actual warnings "
                  "and version documentation; do not migrate rules based on this check alone.")
    mode = settings.get("toolPermission")
    known_modes = {"request-review", "proceed-in-sandbox", "always-proceed", "strict"}
    if isinstance(mode, str) and mode in known_modes:
        print(f"[info] Configured toolPermission: {mode}")
    else:
        print("[info] Effective permission mode is not verified by this static check.")
    sandbox = settings.get("enableTerminalSandbox")
    if isinstance(sandbox, bool):
        print(f"[info] Configured terminal sandbox: {'enabled' if sandbox else 'disabled'}")
    print("[info] Ask/deny rules can override allow rules; configured rules do not prove access.")
    return True


def report_checks(valid: bool) -> None:
    status = "PASS" if valid else "FAIL"
    print(f"[{status}] Installation/config checks only (see warnings/skipped checks above).")
    print("[NOT_CHECKED] Host execution: CLI startup writes, localhost binding and network access.")
    print("[NOT_CHECKED] Research permissions: effective tool grants and actual research access.")


def check(model: str, binary: str, standard: bool, settings_path: Path) -> int:
    print(f"dev-trio research setup — model={model}")
    resolved = shutil.which(binary)
    if not resolved:
        print(f"[FAIL] Researcher executable not found: {binary}")
        print("Install/authenticate the selected CLI, or correct its existing model/CLI override.")
        report_checks(False)
        return 1
    print(f"[ok] Researcher executable: {resolved}")
    valid = True
    if standard:
        # Regular files avoid waiting for descendants that retain output pipes.
        # Never send a prompt, invoke auth, or echo arbitrary CLI stderr.
        try:
            with tempfile.TemporaryFile() as output:
                result = subprocess.run(
                    [resolved, "--version"], stdin=subprocess.DEVNULL,
                    stdout=output, stderr=subprocess.DEVNULL, timeout=5, check=False,
                )
                output.seek(0)
                version = output.read(256).decode("utf-8", errors="replace").splitlines()
            if result.returncode == 0 and version:
                print("[info] CLI version: " + "".join(c for c in version[0] if c.isprintable()))
            else:
                print("[warn] CLI version unavailable; installation/auth/runtime may need inspection.")
        except (OSError, subprocess.TimeoutExpired):
            print("[warn] CLI version probe failed or timed out; no research was attempted.")
        if model == "agy":
            valid = check_settings(settings_path)
    else:
        print("[warn] Custom adapter/CLI override: version and vendor settings checks skipped. "
              "Its probe and settings contracts are unknown.")
    print("[info] Authentication and host sandbox access are unverified; no auth or model call was made.")
    print("[info] If a run fails, use its exact log, not a latest link, to identify the cause:")
    print("  Authentication error: authenticate the selected CLI interactively in a terminal.")
    print("  Host sandbox/keychain restriction: use the host's normal permission flow.")
    print("  Confirmed agy headless denial: inspect the requested action in agy's /permissions.")
    print("    Review only the required command(<target>), read_url(<domain>), or mcp(<server/tool>) rule.")
    print("    If the target is absent from the diagnostic, inspect the request interactively; do not guess.")
    print("  Empty answer without a denial notice: cause unknown. rc=5 alone is not a permission diagnosis.")
    print("  After resolving the cause, explicitly rerun the original question and context through research.")
    print(f"Guide: {Path(__file__).resolve().parents[1] / 'README.md'}#research-troubleshooting")
    report_checks(valid)
    return 0 if valid else 1


if __name__ == "__main__":
    raise SystemExit(check(sys.argv[1], sys.argv[2], sys.argv[3] == "true", Path(sys.argv[4])))
