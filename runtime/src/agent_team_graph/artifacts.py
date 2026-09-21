"""Immutable artifacts, published atomically beneath descriptor-pinned directories."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


def _component(value: str) -> str:
    if not isinstance(value, str) or not value or value in {".", ".."}:
        raise ValueError("artifact names must be nonempty single path components")
    if any(c in value for c in ("/", "\\", "\0")):
        raise ValueError("artifact names must be single path components")
    return value


@contextmanager
def directory_fd(path: Path, *, create: bool = True) -> Iterator[int]:
    """Open each component without following links; callers own the selected root."""
    path = path.expanduser().absolute()
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open(path.anchor, flags)
    try:
        for part in path.parts[1:]:
            # Path.parts already splits POSIX separators. Operator-selected
            # parent names may contain backslashes; only runtime-owned names
            # use the stricter _component contract.
            if part == ".." or "\0" in part:
                raise ValueError("state directory must not contain parent traversal or NUL")
            if create:
                try:
                    os.mkdir(part, dir_fd=fd)
                except FileExistsError:
                    pass
                else:
                    os.fsync(fd)
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def _read(fd: int, name: str) -> tuple[bytes, os.stat_result]:
    # O_NONBLOCK matters before fstat: opening an existing FIFO must not hang.
    file_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    try:
        info = os.fstat(file_fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"artifact is not a regular file: {name}")
        chunks = []
        while chunk := os.read(file_fd, 1024 * 1024):
            chunks.append(chunk)
        return b"".join(chunks), info
    finally:
        os.close(file_fd)


def _publish(fd: int, name: str, content: bytes) -> bool:
    """Return whether this invocation created the final name, never replacing it."""
    temporary = f".artifact-{uuid.uuid4().hex}.tmp"
    file_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666, dir_fd=fd)
    failure = None
    try:
        remaining = memoryview(content)
        while remaining:
            written = os.write(file_fd, remaining)
            if written <= 0:
                raise OSError("artifact write made no progress")
            remaining = remaining[written:]
        os.fsync(file_fd)
        try:
            os.link(temporary, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
        except FileExistsError:
            return False
        os.fsync(fd)
        return True
    except BaseException as exc:
        failure = exc
        raise
    finally:
        cleanup_errors = []
        for cleanup in (lambda: os.close(file_fd),
                        lambda: os.unlink(temporary, dir_fd=fd), lambda: os.fsync(fd)):
            try:
                cleanup()
            except OSError as exc:
                cleanup_errors.append(exc)
        if failure is not None:
            for exc in cleanup_errors:
                failure.add_note(f"artifact cleanup also failed: {exc}")
        elif cleanup_errors:
            raise cleanup_errors[0]


@dataclass(frozen=True)
class ArtifactStore:
    root: Path

    def _path(self, run_id: str, name: str) -> Path:
        return self.root.expanduser().absolute() / _component(run_id) / _component(name)

    def path(self, run_id: str, name: str) -> Path:
        """Where an artifact lives, for a reader that must open it by path (git)."""
        return self._path(run_id, name)

    def preflight(self) -> None:
        """Exercise publication on the selected filesystem before external calls."""
        name = f".capability-{uuid.uuid4().hex}"
        try:
            with directory_fd(self.root) as fd:
                try:
                    if not _publish(fd, name, b"artifact capability probe\n"):
                        raise FileExistsError(name)
                    _read(fd, name)
                finally:
                    try:
                        os.unlink(name, dir_fd=fd)
                        os.fsync(fd)
                    except FileNotFoundError:
                        pass
        except (OSError, NotImplementedError, AttributeError) as exc:
            raise ValueError(
                f"state directory cannot safely publish artifacts: {self.root}; "
                "choose a local POSIX state directory supporting directory descriptors, "
                "no-follow opens, hard links and fsync"
            ) from exc

    def _write(self, run_id: str, name: str, content: str) -> tuple[dict[str, Any], bool]:
        path = self._path(run_id, name)
        encoded = content.encode("utf-8")
        with directory_fd(path.parent) as fd:
            created = _publish(fd, name, encoded)
            existing, info = _read(fd, name)
            if existing != encoded:
                raise FileExistsError(
                    f"immutable artifact already exists with different content: {path}. "
                    "Start a new run_id rather than overwriting recorded history."
                )
        return {
            "name": name,
            "path": str(path),
            "sha256": hashlib.sha256(encoded).hexdigest(),
            "created_at": datetime.fromtimestamp(info.st_mtime, UTC).isoformat(),
        }, created

    def write(self, run_id: str, name: str, content: str) -> dict[str, Any]:
        return self._write(run_id, name, content)[0]

    def write_json(self, run_id: str, name: str, value: Any) -> dict[str, Any]:
        return self.write(run_id, name, json.dumps(value, ensure_ascii=False, indent=2) + "\n")

    def create_json(self, run_id: str, name: str, value: Any) -> tuple[dict[str, Any], bool]:
        """Like write_json, also distinguish a new claim from an identical replay."""
        return self._write(run_id, name, json.dumps(value, ensure_ascii=False, indent=2) + "\n")

    def read(self, run_id: str, name: str) -> bytes:
        path = self._path(run_id, name)
        with directory_fd(path.parent, create=False) as fd:
            return _read(fd, name)[0]

    def read_json(self, run_id: str, name: str) -> Any:
        return json.loads(self.read(run_id, name))
