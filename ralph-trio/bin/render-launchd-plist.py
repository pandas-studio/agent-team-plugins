#!/usr/bin/env python3
"""Render the bundled Ralph LaunchAgent template without shell interpolation."""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import tempfile
from pathlib import Path
from typing import Any


TEMPLATE = (
    Path(__file__).resolve().parent.parent
    / "templates"
    / "launchd"
    / "com.user.ralph.plist.template"
)
PLACEHOLDER_RE = re.compile(r"\{\{([A-Z][A-Z0-9_]*)\}\}")
EXPECTED_PLACEHOLDERS = {"RALPH_SOLO_BIN", "REPO", "TEST_CMD"}


def _placeholders(value: Any) -> set[str]:
    if isinstance(value, str):
        return set(PLACEHOLDER_RE.findall(value))
    if isinstance(value, list):
        return {
            placeholder for item in value for placeholder in _placeholders(item)
        }
    if isinstance(value, dict):
        return {
            placeholder
            for item in value.values()
            for placeholder in _placeholders(item)
        }
    return set()


def _replace_placeholders(value: Any, replacements: dict[str, str]) -> Any:
    if isinstance(value, str):
        return PLACEHOLDER_RE.sub(lambda match: replacements[match.group(1)], value)
    if isinstance(value, list):
        return [_replace_placeholders(item, replacements) for item in value]
    if isinstance(value, dict):
        return {
            key: _replace_placeholders(item, replacements)
            for key, item in value.items()
        }
    return value


def _absolute(parser: argparse.ArgumentParser, option: str, value: str) -> str:
    if not os.path.isabs(value):
        parser.error(f"{option} must be an absolute path: {value}")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="absolute repository path")
    parser.add_argument(
        "--ralph-solo-bin", required=True, help="absolute path to ralph-solo.sh"
    )
    parser.add_argument(
        "--test-cmd", required=True, help="command that gates worktree merges"
    )
    parser.add_argument("--output", required=True, help="output plist path")
    args = parser.parse_args()

    repo = _absolute(parser, "--repo", args.repo)
    ralph_solo_bin = _absolute(parser, "--ralph-solo-bin", args.ralph_solo_bin)
    if not args.test_cmd.strip():
        parser.error("--test-cmd must not be empty")
    output = Path(args.output)
    output_parent = output.parent
    if not output_parent.is_dir():
        parser.error(f"--output parent directory does not exist: {output_parent}")

    with TEMPLATE.open("rb") as stream:
        template = plistlib.load(stream)
    placeholders = _placeholders(template)
    if placeholders != EXPECTED_PLACEHOLDERS:
        raise RuntimeError(
            "launchd template placeholders differ: "
            f"expected {sorted(EXPECTED_PLACEHOLDERS)}, got {sorted(placeholders)}"
        )
    replacements = {
        "REPO": repo,
        "RALPH_SOLO_BIN": ralph_solo_bin,
        "TEST_CMD": args.test_cmd,
    }
    rendered = _replace_placeholders(template, replacements)
    encoded = plistlib.dumps(rendered, fmt=plistlib.FMT_XML, sort_keys=False)

    with tempfile.NamedTemporaryFile(
        dir=output_parent, prefix=f".{output.name}.", delete=False
    ) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        os.replace(temporary, output)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise

    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
