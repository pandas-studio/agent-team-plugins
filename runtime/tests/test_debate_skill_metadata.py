"""Shipped debate skills must be loadable by their host's YAML parser."""
import re
from pathlib import Path

import pytest
import yaml

PLUGIN = Path(__file__).resolve().parents[2] / "debate-conductor"
SKILLS = sorted(PLUGIN.glob("*-skills/*/SKILL.md"))


def test_debate_skills_are_discoverable():
    assert SKILLS, f"No shipped skills found under {PLUGIN}"
    for host in ("claude", "codex"):
        assert any(skill.parent.parent.name == f"{host}-skills" for skill in SKILLS)


@pytest.mark.parametrize("skill", SKILLS)
def test_debate_skill_frontmatter(skill):
    sections = re.split(r"(?m)^---$", skill.read_text(), maxsplit=2)
    assert len(sections) == 3 and not sections[0].strip(), skill
    metadata = yaml.safe_load(sections[1])
    assert isinstance(metadata, dict), skill
    assert isinstance(metadata.get("description"), str) and metadata["description"].strip()
    for field in ("argument-hint", "allowed-tools"):
        if field in metadata:
            assert isinstance(metadata[field], str), (skill, field)
    if skill.parent.parent.name == "codex-skills":
        assert metadata["name"] == skill.parent.name
