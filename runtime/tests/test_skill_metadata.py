"""Shipped skills must be loadable by their host's YAML parser."""
import json
import re
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
MANIFESTS = sorted(ROOT.glob("*/.*-plugin/plugin.json"))


def declared_skill_dirs():
    """Every skills directory a plugin manifest points a host at.

    A manifest without a `skills` key uses the host's default, `skills/`, when
    the plugin has one; a plugin with neither ships no skills.
    """
    directories = {}
    for manifest in MANIFESTS:
        plugin = manifest.parents[1]
        declared = json.loads(manifest.read_text()).get("skills")
        directory = (plugin / (declared or "skills")).resolve()
        if declared is None and not directory.is_dir():
            continue
        directories.setdefault(directory, []).append(manifest)
    return directories


SKILL_DIRS = declared_skill_dirs()
SKILLS = sorted(skill for directory in SKILL_DIRS for skill in directory.glob("*/SKILL.md"))


def relative(path):
    return str(path.relative_to(ROOT))


def test_manifests_are_discoverable():
    assert MANIFESTS, f"No plugin manifests found under {ROOT}"
    assert SKILL_DIRS, "No manifest declares a skills directory"


@pytest.mark.parametrize("directory", sorted(SKILL_DIRS), ids=relative)
def test_declared_skill_directory_ships_skills(directory):
    manifests = [relative(manifest) for manifest in SKILL_DIRS[directory]]
    assert directory.is_dir(), manifests
    assert list(directory.glob("*/SKILL.md")), manifests


def test_no_skill_outside_a_declared_directory():
    shipped = {
        skill.resolve()
        for skill in ROOT.glob("**/SKILL.md")
        if ".venv" not in skill.parts and ".git" not in skill.parts
    }
    assert shipped == {skill.resolve() for skill in SKILLS}


@pytest.mark.parametrize("skill", SKILLS, ids=relative)
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
