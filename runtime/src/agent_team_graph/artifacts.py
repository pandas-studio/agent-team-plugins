"""Immutable per-run artifact storage."""

from __future__ import annotations

import errno
import hashlib
import json
import os
import tempfile
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

# link(2) failures that mean the filesystem has no hard links, as opposed to a
# name that already exists.
_NO_HARD_LINKS = {errno.EPERM, errno.ENOTSUP, errno.EOPNOTSUPP, errno.EXDEV, errno.EMLINK}


def _read_no_follow(path: Path) -> bytes:
    """Read a published artifact; a symlink at its name is refused, not followed."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise ValueError(f"artifact path is a symlink: {path}") from exc
        raise
    with os.fdopen(fd, "rb") as handle:
        return handle.read()


@dataclass(frozen=True)
class ArtifactStore:
    """Write-once files under `<root>/<run_id>/`.

    Only the artifact name itself is checked for a symlink: the state directory
    is trusted like `.git` (see README), since a role that can write it can also
    rewrite the checkpoint database.
    """

    root: Path

    def write(self, run_id: str, name: str, content: str) -> dict[str, Any]:
        run_dir = self.root / run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        path = run_dir / name
        data = content.encode("utf-8")
        digest = hashlib.sha256(data).hexdigest()
        # Publish by hard-linking a complete temp file: link(2) never replaces an
        # existing name, so a crash leaves at most a `.tmp-*` file, never a
        # truncated artifact that would block the node's re-execution.
        fd, temp_name = tempfile.mkstemp(dir=run_dir, prefix=".tmp-")
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            try:
                os.link(temp_name, path, follow_symlinks=False)
            except FileExistsError:
                published = False
            except OSError as exc:
                if exc.errno in _NO_HARD_LINKS:
                    raise ValueError(f"artifact store requires hard links: {self.root}") from exc
                raise
            else:
                published = True
        finally:
            os.unlink(temp_name)
        if published:
            created_at = datetime.now(UTC).isoformat()
        else:
            # Bytes, not text: reading back as text would turn CRLF into LF and
            # report a false conflict for identical content.
            if hashlib.sha256(_read_no_follow(path)).hexdigest() != digest:
                raise FileExistsError(
                    f"immutable artifact already exists with different content: {path}. "
                    "A node re-executed and produced a different result; start a new "
                    "run_id rather than overwriting the recorded history."
                )
            created_at = datetime.fromtimestamp(path.lstat().st_mtime, UTC).isoformat()
        return {
            "name": name,
            "path": str(path),
            "sha256": digest,
            "created_at": created_at,
        }

    def write_json(self, run_id: str, name: str, value: Any) -> dict[str, Any]:
        return self.write(run_id, name, json.dumps(value, ensure_ascii=False, indent=2) + "\n")
