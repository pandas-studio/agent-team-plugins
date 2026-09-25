"""Every plugin's manifest_add_input keeps its value off jq's argv (#118, #121)."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
COPIES = ("dev-trio", "ralph-trio", "spec-trio")


class ManifestCopyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="manifest copies ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        # Linux refuses any one argument of 128 KiB or more; macOS caps only the
        # total, so without this shim a large value passes locally and proves nothing.
        shim = self.root / "argv limited"
        shim.mkdir()
        jq = shim / "jq"
        jq.write_text(
            "#!/bin/bash\n"
            "LC_ALL=C\n"
            "for a in \"$@\"; do\n"
            "  if [ \"${#a}\" -ge 131072 ]; then\n"
            "    echo \"jq: Argument list too long (${#a} bytes)\" >&2; exit 126\n"
            "  fi\n"
            "done\n"
            f"exec {shlex.quote(shutil.which('jq'))} \"$@\"\n")
        jq.chmod(0o755)
        self.path = f"{shim}{os.pathsep}{os.environ['PATH']}"

    def test_values_are_recorded_exactly_off_argv(self):
        # 141,000 bytes; passed through a file because an environment string has
        # the same per-string limit on Linux.
        big = "é" * 70000 + "y" * 1000
        (self.root / "big").write_text(big)
        script = r"""
set -eu
. "$P/lib/manifest.sh"
big=$(cat "$R/big")
manifest_init test "$R/$C.log"
manifest_add_input kind=a value=$'a\n\n'
manifest_add_input kind=empty value=
manifest_add_input kind=p path="/x y"
manifest_add_input kind=big value="$big"
"""
        for copy in COPIES:
            with self.subTest(copy=copy):
                env = {k: v for k, v in os.environ.items() if not k.startswith("MANIFEST_")}
                result = subprocess.run(
                    ["bash", "-c", script],
                    env=env | dict(P=str(ROOT / copy), R=str(self.root), C=copy, PATH=self.path),
                    text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                paths = list(self.root.glob(f"{copy}.manifest.json.tmp*"))
                self.assertEqual(len(paths), 1, paths)
                manifest = json.loads(paths[0].read_text())
                self.assertEqual(manifest["inputs"], [
                    {"kind": "a", "value": "a\n\n"}, {"kind": "empty"},
                    {"kind": "p", "path": "/x y"}, {"kind": "big", "value": big}])


if __name__ == "__main__":
    unittest.main()
