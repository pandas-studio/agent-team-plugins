"""Deterministic policy that is deliberately kept outside model prompts."""

from __future__ import annotations

import re

VERDICTS = ("SHIP", "NEEDS-FIX", "DISCUSS", "OUT-OF-SCOPE")


def parse_verdict(text: str) -> str:
    """Last explicitly-prefixed verdict line wins; anything else fails to DISCUSS.

    The `VERDICT:` prefix is required — the reviewer prompt mandates it, and
    accepting a bare `SHIP` line would let a fenced code block or a quoted
    excerpt at the end of a review auto-approve the run.
    """
    matches = re.findall(
        r"(?im)^\s*VERDICT\s*:\s*(SHIP|NEEDS-FIX|DISCUSS|OUT-OF-SCOPE)\s*$",
        text,
    )
    return matches[-1].upper() if matches else "DISCUSS"


def review_route(verdict: str, attempt: int, max_attempts: int) -> str:
    if verdict == "SHIP":
        return "approval"
    if verdict == "NEEDS-FIX" and attempt < max_attempts:
        return "retry"
    return "stop"


def approval_route(decision: str) -> str:
    return "publish" if decision == "approve" else "stop"
