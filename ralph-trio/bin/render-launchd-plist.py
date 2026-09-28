#!/usr/bin/env python3
"""Render the bundled Ralph LaunchAgent template without shell interpolation."""

from __future__ import annotations

import argparse
import os
import plistlib
import tempfile
from pathlib import Path
from typing import Any


TEMPLATE = (
    Path(__file__).resolve().parent.parent
    / "templates"
    / "launchd"
    / "com.user.ralph.plist.template"
)


def _replace_placeholders(value: Any, repo: str, ralph_solo_bin: str) -> Any:
    if isinstance(value, str):
        return value.replace("{{REPO}}", repo).replace(
            "{{RALPH_SOLO_BIN}}", ralph_solo_bin
        )
    if isinstance(value, list):
        return [_replace_placeholders(item, repo, ralph_solo_bin) for item in value]
    if isinstance(value, dict):
        return {
            key: _replace_placeholders(item, repo, ralph_solo_bin)
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
    parser.add_argument("--output", required=True, help="output plist path")
    args = parser.parse_args()

    repo = _absolute(parser, "--repo", args.repo)
    ralph_solo_bin = _absolute(parser, "--ralph-solo-bin", args.ralph_solo_bin)
    output = Path(args.output)

    with TEMPLATE.open("rb") as stream:
        template = plistlib.load(stream)
    rendered = _replace_placeholders(template, repo, ralph_solo_bin)
    encoded = plistlib.dumps(rendered, fmt=plistlib.FMT_XML, sort_keys=False)
    if b"{{REPO}}" in encoded or b"{{RALPH_SOLO_BIN}}" in encoded:
        raise RuntimeError("launchd template still contains an unresolved placeholder")

    output_parent = output.parent
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
