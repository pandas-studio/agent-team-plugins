"""Exit codes are the wrapper-facing contract; the JSON body is for humans."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from agent_team_graph.cli import _exit_code, _view, build_parser


@pytest.mark.parametrize(
    ("status", "expected"),
    [
        ("approved", 0),
        ("running", 3),
        ("rejected", 4),
        ("needs-human", 4),
        ("not-found", 5),
        ("something-new", 4),
    ],
)
def test_status_maps_to_a_distinct_exit_code(status: str, expected: int):
    assert _exit_code({"status": status, "next": []}) == expected


def test_max_attempts_is_bounded_and_reports_real_choices(capsys):
    parser = build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(
            [
                "run", "--project-id", "p", "--spec", "s", "--task", "t",
                "--test-command", "true", "--allow-path", "src",
                "--max-attempts", "9",
            ]
        )
    # argparse renders a tuple as "1, 2, 3, 4, 5"; a bare range() leaks "range(1, 6)".
    assert "range(" not in capsys.readouterr().err


def test_exclude_path_is_repeatable():
    args = build_parser().parse_args(
        [
            "run",
            "--project-id", "p",
            "--spec", "s",
            "--task", "t",
            "--test-command", "true",
            "--allow-path", "src",
            "--exclude-path", ".codex",
            "--exclude-path", ".claude",
        ]
    )
    assert args.exclude_path == [".codex", ".claude"]


def test_view_distinguishes_recorded_approve_from_blocked_receipt():
    class Graph:
        def get_state(self, config):
            return SimpleNamespace(
                values={
                    "status": "needs-human",
                    "approval": "approve",
                    "excluded_paths": [".reviewer-cache"],
                },
                next=(),
            )

    view = _view(Graph(), "blocked")
    assert view["approval"] == "approve"
    assert "receipt blocked" in view["approval_note"]
    assert view["excluded_paths_not_attested"] == [".reviewer-cache"]
