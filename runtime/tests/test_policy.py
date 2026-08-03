from agent_team_graph.policy import parse_verdict, review_route


def test_unknown_or_embedded_verdict_fails_to_human():
    assert parse_verdict("I think we should SHIP this") == "DISCUSS"
    assert review_route("DISCUSS", 1, 2) == "stop"


def test_bare_verdict_word_does_not_approve():
    """A quoted excerpt or fenced block ending in `SHIP` must not auto-approve."""
    assert parse_verdict("VERDICT: NEEDS-FIX\n\n```\nSHIP\n```") == "NEEDS-FIX"
    assert parse_verdict("SHIP") == "DISCUSS"


def test_last_exact_verdict_wins():
    assert parse_verdict("VERDICT: NEEDS-FIX\nnotes\nVERDICT: SHIP") == "SHIP"
