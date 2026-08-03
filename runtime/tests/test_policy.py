from agent_team_graph.policy import parse_verdict, review_route


def test_unknown_or_embedded_verdict_fails_to_human():
    assert parse_verdict("I think we should SHIP this") == "DISCUSS"
    assert review_route("DISCUSS", 1, 2) == "stop"


def test_last_exact_verdict_wins():
    assert parse_verdict("VERDICT: NEEDS-FIX\nnotes\nVERDICT: SHIP") == "SHIP"
