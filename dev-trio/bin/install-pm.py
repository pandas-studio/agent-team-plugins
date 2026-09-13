#!/usr/bin/env python3
"""Install only the selected host's marked policy into the current workspace."""

import argparse
import os
from pathlib import Path
import stat
import tempfile


def install(workspace: Path, host: str) -> Path:
    plugin = Path(__file__).resolve().parent.parent
    source = plugin / "lib" / ("pm-codex.md" if host == "codex" else "pm.md")
    target = workspace / ("AGENTS.md" if host == "codex" else "CLAUDE.md")
    if target.is_symlink():
        raise ValueError(f"refusing to replace a symlink: {target}")
    begin = "<!-- BEGIN dev-trio PM policy -->"
    end = "<!-- END dev-trio PM policy -->"
    old = target.read_bytes() if target.exists() else b""
    # Byte slicing preserves every byte outside the policy, including CRLFs.
    start, stop = begin.encode(), end.encode()
    if (old.count(start), old.count(stop)) not in ((0, 0), (1, 1)):
        raise ValueError("incomplete or duplicate dev-trio policy markers; file left unchanged")
    block = start + b"\n" + source.read_bytes().rstrip(b"\r\n") + b"\n" + stop
    if start in old:
        left, right = old.index(start), old.index(stop)
        if right < left:
            raise ValueError("reversed dev-trio policy markers; file left unchanged")
        new = old[:left] + block + old[right + len(stop):]
    else:
        separator = b"" if not old else (b"\n" if old.endswith(b"\n") else b"\n\n")
        new = old + separator + block + b"\n"
    if new == old:
        return target
    mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o644
    fd, temporary = tempfile.mkstemp(prefix=".dev-trio-policy-", dir=workspace)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(new)
            os.fchmod(stream.fileno(), mode)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", choices=("claude", "codex"), required=True)
    args = parser.parse_args()
    try:
        target = install(Path.cwd(), args.host)
    except (OSError, ValueError) as exc:
        parser.exit(2, f"dev-trio: {exc}\n")
    print(f"Installed dev-trio PM policy: {target}")


if __name__ == "__main__":
    main()
