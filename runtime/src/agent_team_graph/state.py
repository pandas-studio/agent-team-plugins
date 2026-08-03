"""Versioned graph state and append-only event records."""

from __future__ import annotations

import operator
from typing import Annotated, Any, TypedDict


class GraphState(TypedDict, total=False):
    schema_version: str
    thread_id: str
    run_id: str
    project_id: str
    workspace: str
    spec_path: str
    spec_sha256: str
    task: str
    test_command: list[str]
    allowed_paths: list[str]
    base_sha: str
    attempt: int
    max_attempts: int
    plan: str
    research: str
    code_report: str
    review: str
    verdict: str
    gate_passed: bool
    approval: str
    status: str
    artifacts: Annotated[list[dict[str, Any]], operator.add]
    usage: Annotated[list[dict[str, Any]], operator.add]
    errors: Annotated[list[str], operator.add]
