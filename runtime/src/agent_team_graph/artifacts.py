"""Immutable per-run artifact storage."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class ArtifactStore:
    root: Path

    def write(self, run_id: str, name: str, content: str) -> dict[str, Any]:
        run_dir = self.root / run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        path = run_dir / name
        digest = hashlib.sha256(content.encode()).hexdigest()
        if path.exists():
            existing = path.read_text(encoding="utf-8")
            if hashlib.sha256(existing.encode()).hexdigest() != digest:
                raise FileExistsError(f"immutable artifact already exists with different content: {path}")
            created_at = datetime.fromtimestamp(path.stat().st_mtime, UTC).isoformat()
        else:
            path.write_text(content, encoding="utf-8")
            created_at = datetime.now(UTC).isoformat()
        return {
            "name": name,
            "path": str(path),
            "sha256": digest,
            "created_at": created_at,
        }

    def write_json(self, run_id: str, name: str, value: Any) -> dict[str, Any]:
        return self.write(run_id, name, json.dumps(value, ensure_ascii=False, indent=2) + "\n")
