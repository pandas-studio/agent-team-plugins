"""Vendored copies stay in step, checked in one place (#150).

IDENTICAL groups must match byte for byte. KNOWN_DIFF pairs may differ, but
only by the difference recorded here: a one-sided edit changes the digest and
fails. After an intended change to one side of a KNOWN_DIFF pair, print the
new digests with

    python3 tests/test_vendored_copies.py --print-digests

and update KNOWN_DIFF in the same commit, so the review sees the new difference.
"""

import difflib
import hashlib
import os
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]

PLUGINS = ("debate-conductor", "dev-trio", "ralph-trio", "spec-trio")

# The first path of each group is the copy to edit; cp it over the others.
IDENTICAL = {
    "namespace.sh": tuple(f"{p}/lib/namespace.sh" for p in ("dev-trio", "debate-conductor", "ralph-trio", "spec-trio")),
    "registry.sh": tuple(f"{p}/lib/registry.sh" for p in ("dev-trio", "debate-conductor", "ralph-trio", "spec-trio")),
    # ralph-trio's copy is itself vendored from agent-team-harness core/lib/manifest.sh (#121).
    "manifest.sh": tuple(f"{p}/lib/manifest.sh" for p in ("ralph-trio", "dev-trio", "spec-trio")),
    "stage-result.sh": ("ralph-trio/lib/stage-result.sh", "spec-trio/lib/stage-result.sh"),
    "plugin-deps.sh": ("ralph-trio/lib/plugin-deps.sh", "spec-trio/lib/plugin-deps.sh"),
    "model-stage.sh": ("ralph-trio/lib/model-stage.sh", "spec-trio/lib/model-stage.sh"),
    "agent-team-models.sh": ("dev-trio/bin/agent-team-models.sh", "debate-conductor/bin/agent-team-models.sh"),
}

# Compared as links: the target string, not the bytes behind it.
SYMLINKS = {
    "agent-team-models": ("dev-trio/bin/agent-team-models", "debate-conductor/bin/agent-team-models"),
}

# install-pm.py differs between plugins only in the plugin's own name, which
# each copy must name exactly this many times and no other plugin's name at all.
INSTALL_PM_NAME_COUNT = 7
INSTALL_PM = tuple(f"{p}/bin/install-pm.py" for p in ("dev-trio", "ralph-trio", "spec-trio"))


def whole(path, data):
    return data


def plugin_name(plugin):
    """A plugin name not inside a longer word; a following dash is allowed, as
    in the ".dev-trio-policy-" temporary-file prefix."""
    return re.compile(rb"(?<![\w-])" + re.escape(plugin.encode()) + rb"(?!\w)")


def plugin_neutral(path, data):
    """Replace this copy's own plugin name, after checking it names no other."""
    plugin = path.split("/", 1)[0]
    others = [p for p in PLUGINS if p != plugin and plugin_name(p).search(data)]
    if others:
        raise ValueError(f"{path} names another plugin: {', '.join(others)}")
    data, count = plugin_name(plugin).subn(b"<plugin>", data)
    if count != INSTALL_PM_NAME_COUNT:
        raise ValueError(f"{path} names {plugin} {count} times, expected {INSTALL_PM_NAME_COUNT}")
    return data


def function_section(path, data, name):
    """One shell function, with the plugin's names neutralised."""
    plugin = path.split("/", 1)[0]
    prefix = plugin.replace("-", "_") + "_"
    match = re.search(rb"^" + prefix.encode() + name.encode() + rb"\(\) \{\n.*?^\}\n", data, re.M | re.S)
    if match is None:
        raise ValueError(f"{path} has no {prefix}{name} function")
    # The section ends at the first column-0 brace. Another one before the next
    # function means that brace closed something nested, so the cut is wrong.
    rest = data[match.end():]
    following = re.search(rb"^[A-Za-z_][A-Za-z0-9_]*\(\) \{", rest, re.M)
    if re.search(rb"^\}", rest[:following.start() if following else len(rest)], re.M):
        raise ValueError(f"{path}: {prefix}{name} has a column-0 brace before its end")
    return (match.group(0).replace(prefix.encode(), b"<prefix>_")
            .replace(prefix.upper().encode(), b"<PREFIX>_").replace(plugin.encode(), b"<plugin>"))


# The functions the two host.sh files share; the rest of each file is its own.
HOST_SHARED_FUNCTIONS = ("host", "check_cli")


def host_shared_sections(path, data):
    return b"".join(function_section(path, data, name) for name in HOST_SHARED_FUNCTIONS)


# name: (path_a, path_b, normalise, sha256 of diff_lines(normalised a, normalised b))
KNOWN_DIFF = {
    # spec-trio's copy adds a header and its own workspace overrides; see its header.
    "common.sh": (
        "ralph-trio/lib/common.sh", "spec-trio/lib/common.sh", whole,
        "90686e672085a39f270838d1e996bd97b50d8a0ea939ab135eaadc29e91cb82f",
    ),
    "roles/reviewer.md": (
        "dev-trio/lib/roles/reviewer.md", "spec-trio/lib/roles/reviewer.md", whole,
        "72da0033193939bcafb460febb496799d3919e610a8b381d02fb43fae36d6b2d",
    ),
    "install-pm.py": (
        "dev-trio/bin/install-pm.py", "debate-conductor/bin/install-pm.py", plugin_neutral,
        "26dc9408c85bd42358bb3e58d7fe71f2514a4530e496c180e300a6f92a88f57c",
    ),
    # Only HOST_SHARED_FUNCTIONS were written once and pasted into both host.sh
    # files: *_host, and the *_check_cli login preflight (#127, #155).
    "host.sh shared functions": (
        "dev-trio/lib/host.sh", "debate-conductor/lib/host.sh", host_shared_sections,
        "ab85a07c672dd7cea318999149faa8e5bb52122de822b1978161ee2b018070e1",
    ),
}


def diff_lines(a, b):
    """The changed lines of two byte strings, each with its line ending.

    No context and no line numbers: an edit made the same way on both sides
    keeps the digest, and so does moving a difference without changing it.
    Every changed byte counts, including a line ending or a missing final newline.
    """
    lines = []
    matcher = difflib.SequenceMatcher(None, a.splitlines(keepends=True), b.splitlines(keepends=True),
                                      autojunk=False)
    a_lines, b_lines = matcher.a, matcher.b
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        lines.append(b"@\n")
        lines.extend(b"-" + line for line in a_lines[i1:i2])
        lines.extend(b"+" + line for line in b_lines[j1:j2])
    return lines


def digest(a, b):
    return hashlib.sha256(b"".join(diff_lines(a, b))).hexdigest()


def read(path):
    return (ROOT / path).read_bytes()


def identical_failure(paths, contents):
    """None, or a message naming the copies that differ from the first."""
    first = contents[0]
    stray = [path for path, data in zip(paths[1:], contents[1:]) if data != first]
    if not stray:
        return None
    return (f"{', '.join(stray)} differ from {paths[0]}; the copies of this file are: "
            f"{', '.join(paths)}. Edit {paths[0]} and copy it over the others.")


def known_digest(name):
    path_a, path_b, normalise, _ = KNOWN_DIFF[name]
    return digest(normalise(path_a, read(path_a)), normalise(path_b, read(path_b)))


class VendoredCopyTests(unittest.TestCase):
    def test_identical_groups(self):
        for name, paths in IDENTICAL.items():
            with self.subTest(group=name):
                message = identical_failure(paths, [read(p) for p in paths])
                self.assertIsNone(message, message)

    def test_symlink_groups(self):
        for name, paths in SYMLINKS.items():
            with self.subTest(group=name):
                for path in paths:
                    self.assertTrue((ROOT / path).is_symlink(),
                                    f"{path} must stay a symlink, like the other copies: {', '.join(paths)}")
                message = identical_failure(paths, [os.readlink(ROOT / p) for p in paths])
                self.assertIsNone(message, message)

    def test_install_pm_differs_only_in_plugin_name(self):
        copies = INSTALL_PM + (KNOWN_DIFF["install-pm.py"][1],)
        neutral = {}
        for path in copies:
            with self.subTest(copy=path):
                try:
                    neutral[path] = plugin_neutral(path, read(path))
                except ValueError as exc:
                    self.fail(f"{exc}; the copies of install-pm.py are: {', '.join(copies)}")
        if len(neutral) == len(copies):
            message = identical_failure(INSTALL_PM, [neutral[p] for p in INSTALL_PM])
            self.assertIsNone(message, message)

    def test_known_differences(self):
        for name, (path_a, path_b, normalise, expected) in KNOWN_DIFF.items():
            with self.subTest(pair=name):
                a, b = normalise(path_a, read(path_a)), normalise(path_b, read(path_b))
                self.assertEqual(
                    digest(a, b), expected,
                    f"{path_a} and {path_b} ({name}) no longer differ only as recorded; "
                    "if one side changed on purpose, make the same change to the other, "
                    "or record the new difference (see this file's docstring). "
                    "Current difference:\n" + b"".join(diff_lines(a, b)).decode("utf-8", "backslashreplace"),
                )


class CheckerTests(unittest.TestCase):
    """The checks catch what they are for, shown on fixed in-memory fixtures."""

    A = b"#!/usr/bin/env bash\nshared one\nonly in a\nshared two\n"
    B = b"#!/usr/bin/env bash\nshared one\nshared two\nonly in b\n"

    def test_one_changed_copy_is_named_with_all_copies(self):
        paths = ("x/lib/f.sh", "y/lib/f.sh", "z/lib/f.sh")
        message = identical_failure(paths, [b"same\n", b"same\n", b"same\n\n"])
        self.assertIsNotNone(message)
        self.assertIn("z/lib/f.sh differ from x/lib/f.sh", message)
        for path in paths:
            self.assertIn(path, message)
        self.assertIsNone(identical_failure(paths, [b"same\n"] * 3))

    def test_one_sided_edits_change_the_digest(self):
        base = digest(self.A, self.B)
        for a, b in (
            (self.A.replace(b"shared one", b"shared one edited"), self.B),
            (self.A, self.B.replace(b"shared two", b"shared two edited")),
            (b"--newflag\n" + self.A, self.B),  # a changed line that starts with "--"
            (self.A, self.B + b"@@ -1 +1 @@\n"),
            (self.A, self.B[:-1]),  # final newline removed on one side
            (self.A.replace(b"\n", b"\r\n"), self.B),  # line endings changed on one side
            (self.A.replace(b"only in a", b"only in a, edited"), self.B),
        ):
            with self.subTest(a=a[:30], b=b[-30:]):
                self.assertNotEqual(digest(a, b), base)

    def test_same_edit_on_both_sides_keeps_the_digest(self):
        base = digest(self.A, self.B)
        self.assertEqual(digest(b"# new first line\n" + self.A, b"# new first line\n" + self.B), base)
        self.assertEqual(digest(self.A.replace(b"shared one", b"shared 1"),
                                self.B.replace(b"shared one", b"shared 1")), base)

    def test_install_pm_rejects_a_renamed_identifier(self):
        path = "dev-trio/bin/install-pm.py"
        good = b"x = 'dev-trio'\n" * INSTALL_PM_NAME_COUNT
        self.assertEqual(plugin_neutral(path, good), b"x = '<plugin>'\n" * INSTALL_PM_NAME_COUNT)
        with self.assertRaisesRegex(ValueError, "names another plugin: spec-trio"):
            plugin_neutral(path, good.replace(b"dev-trio", b"spec-trio", 1))
        with self.assertRaisesRegex(ValueError, "6 times, expected 7"):
            plugin_neutral(path, good.replace(b"dev-trio", b"policy", 1))
        # A longer token that contains a plugin name is neither the plugin nor another one.
        self.assertEqual(plugin_neutral(path, good + b"nonspec-trio-token dev-trios\n"),
                         b"x = '<plugin>'\n" * INSTALL_PM_NAME_COUNT + b"nonspec-trio-token dev-trios\n")

    def test_function_section_is_the_function_only(self):
        path = "dev-trio/lib/host.sh"
        data = (b"dev_trio_host() {\n  :\n}\n\ndev_trio_check_cli() {\n  local model=dev-trio\n"
                b"  dev_trio_host\n}\n\ndev_trio_next() {\n  :\n}\n")
        self.assertEqual(function_section(path, data, "check_cli"),
                         b"<prefix>_check_cli() {\n  local model=<plugin>\n  <prefix>_host\n}\n")
        self.assertEqual(function_section(path, b"dev_trio_host() {\n  echo ${DEV_TRIO_PM_HOST:-claude}\n}\n", "host"),
                         b"<prefix>_host() {\n  echo ${<PREFIX>_PM_HOST:-claude}\n}\n")
        nested = data.replace(b"  dev_trio_host\n}\n", b"  inner() {\n  :\n}\n  echo after\n}\n", 1)
        with self.assertRaisesRegex(ValueError, "column-0 brace before its end"):
            function_section(path, nested, "check_cli")
        with self.assertRaisesRegex(ValueError, "no dev_trio_check_cli"):
            function_section(path, b"dev_trio_host() {\n}\n", "check_cli")

if __name__ == "__main__":
    if sys.argv[1:] == ["--print-digests"]:
        for name in KNOWN_DIFF:
            print(f"{name}: {known_digest(name)}")
    else:
        unittest.main()
