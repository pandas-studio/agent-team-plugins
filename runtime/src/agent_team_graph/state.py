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
    repo_root: str
    spec_path: str
    spec_sha256: str
    task: str
    test_command: list[str]
    allowed_paths: list[str]
    operator_excluded_paths: list[str]
    excluded_paths: list[str]
    strict_ignored: bool
    base_sha: str
    base_manifest_sha256: str | None
    attestation_ignore_rules: str | None
    attempt: int
    execution_policy_version: int
    attempt_start: str
    role_failed: bool
    halted: bool
    cancelled_signal: int | None
    max_attempts: int
    role_timeout_seconds: int
    gate_timeout_seconds: int
    plan: str
    research: str
    code_report: str
    review: str
    verdict: str
    gate_passed: bool
    gate_feedback: str
    gated_change_sha256: str | None
    reviewed_change_sha256: str | None
    approved_change_sha256: str | None
    approval: str
    status: str
    artifacts: Annotated[list[dict[str, Any]], operator.add]
    usage: Annotated[list[dict[str, Any]], operator.add]
    errors: Annotated[list[str], operator.add]
