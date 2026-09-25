"""Failure cases for manifest and runstate publication (#122)."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
COPIES = ("dev-trio", "ralph-trio", "spec-trio")


class PublicationSafetyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="publication safety ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("MANIFEST_")}

    def shell(self, plugin, script):
        return subprocess.run(
            ["bash", "-c", script],
            env=self.env | dict(P=str(ROOT / plugin), R=str(self.root), C=plugin),
            text=True, capture_output=True, timeout=20,
        )

    def test_unique_private_init_does_not_follow_legacy_symlink(self):
        for plugin in COPIES:
            with self.subTest(plugin=plugin):
                sentinel = self.root / f"{plugin}.sentinel"
                sentinel.write_text("keep this")
                legacy = self.root / f"{plugin}.manifest.json.tmp"
                legacy.symlink_to(sentinel)
                result = self.shell(plugin, '''
set -eu
umask 000
. "$P/lib/manifest.sh"
manifest_init test "$R/$C.log"
manifest_add_input kind=mode value=private
printf '%s\n' "$MANIFEST_TMP"
''')
                self.assertEqual(result.returncode, 0, result.stderr)
                current = Path(result.stdout.strip())
                self.assertEqual(current.parent, self.root)
                self.assertTrue(current.name.startswith(f"{plugin}.manifest.json.tmp."))
                self.assertEqual(current.stat().st_mode & 0o777, 0o600)
                self.assertTrue(legacy.is_symlink())
                self.assertEqual(sentinel.read_text(), "keep this")

    def test_failed_rewrites_preserve_parent_manifest(self):
        for plugin in COPIES:
            with self.subTest(plugin=plugin):
                result = self.shell(plugin, '''
set -eu
. "$P/lib/manifest.sh"
manifest_init parent "$R/$C.log"
manifest_add_input kind=old value=unchanged
parent="$MANIFEST_TMP"
cp "$parent" "$R/$C.before"
mv() { return 1; }
if MANIFEST_PARENT_TMP="$parent" manifest_add_role child model ""; then exit 91; fi
unset -f mv
printf() { return 1; }
if manifest_set_verdict SHIP; then exit 92; fi
unset -f printf
printf '%s\n' "$parent"
''')
                self.assertEqual(result.returncode, 0, result.stderr)
                current = Path(result.stdout.strip())
                self.assertEqual(current.read_bytes(), (self.root / f"{plugin}.before").read_bytes())
                self.assertEqual(list(self.root.glob(current.name + ".tmp.*")), [])

    def test_manifest_directory_destination_is_not_published(self):
        for plugin in COPIES:
            for linked in (False, True):
                with self.subTest(plugin=plugin, linked=linked):
                    stem = f"{plugin}-{'linked' if linked else 'direct'}"
                    destination = self.root / f"{stem}.manifest.json"
                    directory = self.root / f"{stem}.directory"
                    if linked:
                        directory.mkdir()
                        destination.symlink_to(directory, target_is_directory=True)
                    else:
                        destination.mkdir()
                        directory = destination
                    result = subprocess.run(
                        ["bash", "-c", '''
set -eu
. "$P/lib/manifest.sh"
manifest_init test "$R/$S.log"
if manifest_finalize; then exit 93; fi
printf '%s\n' "$MANIFEST_TMP"
'''], env=self.env | dict(P=str(ROOT / plugin), R=str(self.root), S=stem),
                        text=True, capture_output=True, timeout=20)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(list(directory.iterdir()), [])
                    retained = Path(result.stdout.strip())
                    self.assertTrue(retained.is_file())
                    self.assertIn(
                        f"temporary manifest still open at {retained}", result.stderr)

    def test_runstate_directory_destination_is_not_published(self):
        for linked in (False, True):
            with self.subTest(linked=linked):
                stem = "linked" if linked else "direct"
                destination = self.root / f"{stem}.run.json"
                directory = self.root / f"{stem}.directory"
                if linked:
                    directory.mkdir()
                    destination.symlink_to(directory, target_is_directory=True)
                else:
                    destination.mkdir()
                    directory = destination
                result = subprocess.run(
                    ["bash", "-c", '''
set -eu
. "$P/lib/runstate.sh"
if _runstate_publish "$R/$S.run.json" '{"schema_version":1}'; then exit 94; fi
'''], env=self.env | dict(P=str(ROOT / "dev-trio"), R=str(self.root), S=stem),
                    text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(list(directory.iterdir()), [])
                self.assertEqual(list(self.root.glob(f"{stem}.run.json.tmp.*")), [])


if __name__ == "__main__":
    unittest.main()
