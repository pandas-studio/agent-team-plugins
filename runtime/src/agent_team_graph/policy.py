"""Deterministic policy that is deliberately kept outside model prompts."""

from __future__ import annotations

import re

VERDICTS = ("SHIP", "NEEDS-FIX", "DISCUSS", "OUT-OF-SCOPE")


_VERDICT_LINE = re.compile(r"(?i)^ {0,3}VERDICT\s*:\s*(SHIP|NEEDS-FIX|DISCUSS|OUT-OF-SCOPE)\s*$")
_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")


def parse_verdict(text: str) -> str:
    """Last explicitly-prefixed verdict line wins; anything else fails to DISCUSS.

    The `VERDICT:` prefix is required — the reviewer prompt mandates it, and
    accepting a bare `SHIP` line would let a fenced code block or a quoted
    excerpt at the end of a review auto-approve the run. For the same reason a
    prefixed line inside a code fence, indented four or more columns, or quoted
    with `>` is an example, not the verdict: otherwise an example placed after a
    real `VERDICT: NEEDS-FIX` would turn the result into SHIP.
    """
    verdict = "DISCUSS"
    fence = ""
    for line in text.splitlines():
        opened = _FENCE.match(line)
        if fence:
            if opened and opened.group(1)[0] == fence[0] and len(opened.group(1)) >= len(fence) \
                    and not opened.group(2).strip():
                fence = ""
            continue
        if opened and not (opened.group(1)[0] == "`" and "`" in opened.group(2)):
            fence = opened.group(1)
            continue
        match = _VERDICT_LINE.match(line)
        if match:
            verdict = match.group(1).upper()
    return verdict

def review_route(verdict: str, attempt: int, max_attempts: int) -> str:
    if verdict == "SHIP":
        return "approval"
    if verdict == "NEEDS-FIX" and attempt < max_attempts:
        return "retry"
    return "stop"


def approval_route(decision: str) -> str:
    return "publish" if decision == "approve" else "stop"
