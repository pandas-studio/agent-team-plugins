#!/usr/bin/env python3
"""Fail when a plugin changes without a version bump in all its manifests (#151).

The marketplace cache refreshes only when a plugin's version changes, so every
change to a plugin outside its tests/ needs a higher version, and every file
that carries that plugin's version must agree.

A plugin is a top-level directory holding .claude-plugin/plugin.json. The base
is VERSION_BUMP_BASE (default origin/main); changes are taken from
merge-base(base, HEAD) to the working tree, untracked files included, so a
local run checks what is about to be committed.

Exit 0: consistent. Exit 1: a missing or inconsistent bump. Exit 2: the base
cannot be resolved while it is required (CI=true, or VERSION_BUMP_BASE set).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, Optional

DEFAULT_BASE = "origin/main"
VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def _json_version(text: str) -> Optional[str]:
    value = json.loads(text).get("version")
    return value if isinstance(value, str) else None


def _toml(text: str) -> dict:
    try:
        import tomllib
    except ModuleNotFoundError:  # Python < 3.11
        raise ValueError("reading TOML needs Python 3.11 or newer (tomllib)")
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise ValueError(str(exc)) from exc


def _pyproject_version(text: str) -> Optional[str]:
    value = _toml(text).get("project", {}).get("version")
    return value if isinstance(value, str) else None


def _dunder_version(text: str) -> Optional[str]:
    match = re.search(r'^__version__\s*=\s*"([^"]*)"', text, re.M)
    return match.group(1) if match else None


def _uv_lock_version(name: str) -> Callable[[str], Optional[str]]:
    def read(text: str) -> Optional[str]:
        for package in _toml(text).get("package", []):
            if package.get("name") == name:
                value = package.get("version")
                return value if isinstance(value, str) else None
        return None

    return read


MANIFESTS: list[tuple[str, Callable[[str], Optional[str]]]] = [
    (".claude-plugin/plugin.json", _json_version),
    (".codex-plugin/plugin.json", _json_version),
]

# Version copies outside the manifests, per plugin directory. Every entry here
# is required to exist, unlike the optional Codex manifest.
EXTRA_SOURCES: dict[str, list[tuple[str, Callable[[str], Optional[str]]]]] = {
    "runtime": [
        ("pyproject.toml", _pyproject_version),
        ("src/agent_team_graph/__init__.py", _dunder_version),
        ("uv.lock", _uv_lock_version("agent-team-graph")),
    ],
}


def git(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )


MANIFEST_GLOB = "*/.claude-plugin/plugin.json"


def _plugin_dirs(listing: str) -> set[str]:
    # Only top-level plugin directories: <dir>/.claude-plugin/plugin.json.
    return {
        path.split("/", 1)[0]
        for path in listing.split("\0")
        if path.count("/") == 2 and path.endswith("/.claude-plugin/plugin.json")
    }


def head_plugins(root: Path) -> set[str]:
    # Git-visible files only: an ignored scratch copy is not a plugin.
    listing = git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard",
                  "--", MANIFEST_GLOB)
    return {p for p in _plugin_dirs(listing.stdout) if (root / p / MANIFEST_GLOB[2:]).is_file()}


def base_plugins(root: Path, commit: str) -> set[str]:
    listing = git(root, "ls-tree", "-r", "-z", "--name-only", commit, "--", ".")
    return _plugin_dirs(listing.stdout)


def read_versions(plugin: str, read: Callable[[str], Optional[str]]):
    """Return ({path: version or None}, [problems]) for one plugin."""
    versions: dict[str, Optional[str]] = {}
    problems: list[str] = []
    sources = [(path, fn, False) for path, fn in MANIFESTS]
    sources += [(path, fn, True) for path, fn in EXTRA_SOURCES.get(plugin, [])]
    for rel, parse, required in sources:
        path = f"{plugin}/{rel}"
        text = read(path)
        if text is None:
            if required or rel == MANIFESTS[0][0]:
                problems.append(f"{path}: missing")
            continue
        try:
            version = parse(text)
        except ValueError as exc:
            problems.append(f"{path}: cannot parse: {exc}")
            continue
        if version is None:
            problems.append(f"{path}: no version found")
        elif not VERSION_RE.match(version):
            problems.append(f"{path}: version {version!r} is not MAJOR.MINOR.PATCH")
        versions[path] = version
    return versions, problems


def as_tuple(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args(argv)
    root: Path = args.root

    explicit = os.environ.get("VERSION_BUMP_BASE", "")
    base = explicit or DEFAULT_BASE
    # A push that creates a branch reports an all-zero "before" SHA.
    if re.fullmatch(r"0+", base):
        base = DEFAULT_BASE
    required = bool(explicit) or os.environ.get("CI") == "true"
    # A push to main compares with the previous tip itself: after a force push
    # the merge base can predate it and hide a rollback.
    direct = os.environ.get("VERSION_BUMP_DIRECT") == "true"

    resolved = git(root, "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}")
    if resolved.returncode != 0:
        if required:
            print(f"version-bump: base {base!r} does not resolve to a commit", file=sys.stderr)
            return 2
        print(f"version-bump: base {base!r} not found; skipping", file=sys.stderr)
        return 0
    if direct:
        mb = resolved.stdout.strip()
    else:
        merge_base = git(root, "merge-base", resolved.stdout.strip(), "HEAD")
        if merge_base.returncode != 0:
            print(f"version-bump: no merge base between {base!r} and HEAD", file=sys.stderr)
            return 2
        mb = merge_base.stdout.strip()

    # --no-renames: a move from bin/ into tests/ must show its source too.
    diff = git(root, "diff", "--name-only", "--no-renames", "-z", mb, "--")
    untracked = git(root, "ls-files", "--others", "--exclude-standard", "-z")
    for result in (diff, untracked):
        if result.returncode != 0:
            print(f"version-bump: git failed: {result.stderr.strip()}", file=sys.stderr)
            return 2
    changed = {p for p in (diff.stdout + untracked.stdout).split("\0") if p}

    def read_head(path: str) -> Optional[str]:
        file = root / path
        return file.read_text(encoding="utf-8") if file.is_file() else None

    def read_base(path: str) -> Optional[str]:
        shown = git(root, "show", f"{mb}:{path}")
        return shown.stdout if shown.returncode == 0 else None

    failures: list[str] = []
    # A top-level submodule would hide its plugin's files from every check here;
    # none exist, so refuse the layout rather than half-support it.
    staged = git(root, "ls-files", "-z", "--stage")
    for entry in filter(None, staged.stdout.split("\0")):
        meta, _, path = entry.partition("\t")  # "<mode> <object> <stage>\t<path>"
        if meta.startswith("160000 ") and "/" not in path:
            failures.append(f"{path}: a top-level submodule is not supported by this check")
    present = head_plugins(root)
    for plugin in sorted(base_plugins(root, mb) - present):
        # The manifest went away. Deleting the whole plugin is fine; leaving
        # files behind without a manifest hides them from this check.
        remaining = git(root, "ls-files", "-z", "--cached", "--others",
                        "--exclude-standard", "--", f"{plugin}/")
        # --cached still lists a deletion that is not staged yet.
        if any((root / p).exists() for p in remaining.stdout.split("\0") if p):
            failures.append(f"{plugin}: {MANIFESTS[0][0]} was removed but the plugin's files remain")
    for plugin in sorted(present):
        versions, problems = read_versions(plugin, read_head)
        failures += problems
        distinct = {v for v in versions.values() if v is not None}
        if len(distinct) > 1:
            listing = ", ".join(f"{p}={v}" for p, v in sorted(versions.items()))
            failures.append(f"{plugin}: versions disagree: {listing}")
            continue
        if problems or not distinct:
            continue
        head_version = distinct.pop()

        touched = sorted(
            p for p in changed
            if p.startswith(f"{plugin}/") and not p.startswith(f"{plugin}/tests/")
        )
        if not touched:
            continue
        base_manifest = read_base(f"{plugin}/{MANIFESTS[0][0]}")
        if base_manifest is None:
            continue  # a plugin new since the base
        try:
            base_version = _json_version(base_manifest)
        except ValueError:
            base_version = None
        if base_version is None or not VERSION_RE.match(base_version):
            failures.append(f"{plugin}: base version unreadable ({base_version!r})")
            continue
        if as_tuple(head_version) <= as_tuple(base_version):
            shown = ", ".join(touched[:5]) + (", ..." if len(touched) > 5 else "")
            failures.append(
                f"{plugin}: changed ({shown}) but version {head_version} is not "
                f"greater than {base_version} at {base}"
            )

    for failure in failures:
        print(f"version-bump: {failure}", file=sys.stderr)
    if failures:
        print(
            "version-bump: bump every manifest of each changed plugin "
            "(the marketplace cache refreshes only on a version change)",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
