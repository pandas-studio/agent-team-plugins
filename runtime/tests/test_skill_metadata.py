"""Shipped skills must be loadable by their host's YAML parser."""
import re
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
SKILLS = sorted(
    [*ROOT.glob("*/*-skills/*/SKILL.md"), *ROOT.glob("runtime/skills/*/SKILL.md")]
)
DEBATE = ROOT / "debate-conductor"


def skill_id(skill):
    return str(skill.relative_to(ROOT))


def test_skills_are_discoverable():
    assert SKILLS, f"No shipped skills found under {ROOT}"
    plugins = {skill.relative_to(ROOT).parts[0] for skill in SKILLS}
    for plugin in ("debate-conductor", "dev-trio", "eval-trio", "ralph-trio", "spec-trio", "runtime"):
        assert plugin in plugins, plugin
    for host in ("claude", "codex", "agy"):
        assert any(
            skill.parent.parent == DEBATE / f"{host}-skills" for skill in SKILLS
        ), host


@pytest.mark.parametrize("skill", SKILLS, ids=skill_id)
def test_skill_frontmatter(skill):
    sections = re.split(r"(?m)^---$", skill.read_text(), maxsplit=2)
    assert len(sections) == 3 and not sections[0].strip(), skill
    metadata = yaml.safe_load(sections[1])
    assert isinstance(metadata, dict), skill
    assert isinstance(metadata.get("description"), str) and metadata["description"].strip()
    for field in ("argument-hint", "allowed-tools"):
        if field in metadata:
            assert isinstance(metadata[field], str), (skill, field)
    if skill.parent.parent.name in ("codex-skills", "agy-skills"):
        assert metadata["name"] == skill.parent.name
