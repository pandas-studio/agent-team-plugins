"""scripts/check.sh refuses an argument that is not one of its parts."""

from __future__ import annotations

import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECK = ROOT / "scripts" / "check.sh"


class CheckShArgumentTests(unittest.TestCase):
    def run_check(self, *args):
        """Run check.sh with stubs that end it at its first command.

        check.sh runs this file, so a regression that let a bad argument
        through would otherwise run the suites, and this test again. The
        stubs come first on PATH: python3 is the first command check.sh runs
        after it has accepted its arguments, find the first one after that.
        """
        with tempfile.TemporaryDirectory(prefix="check sh ") as tmp:
            marker = Path(tmp) / "ran"
            for name in ("python3", "find"):
                stub = Path(tmp) / name
                stub.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\nexit 97\n")
                stub.chmod(0o755)
            env = os.environ | {"PATH": tmp + os.pathsep + os.environ["PATH"]}
            result = subprocess.run(
                ["bash", str(CHECK), *args],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                stdin=subprocess.DEVNULL,
                timeout=30,
                check=False,
            )
            return result, marker.exists()

    def test_unknown_part_and_extra_argument_exit_2_before_any_check(self):
        for args in (("bogus",), ("tests", "smoke"), ("",), ("--help",), ("all", "all")):
            with self.subTest(args=args):
                result, ran = self.run_check(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(
                    result.stderr, "usage: scripts/check.sh [all|tests|smoke|rest]\n"
                )
                self.assertEqual(result.stdout, "")
                self.assertFalse(ran, "a check ran after a refused argument")

    def test_each_part_is_accepted(self):
        # The stub python3 ends the run at the preflight with its own code, so
        # 97 and the marker mean the argument was accepted and nothing else ran.
        for args in ((), ("all",), ("tests",), ("smoke",), ("rest",)):
            with self.subTest(args=args):
                result, ran = self.run_check(*args)
                self.assertEqual(result.returncode, 97, result.stderr)
                self.assertNotIn("usage:", result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertTrue(ran, "the preflight did not run")


if __name__ == "__main__":
    unittest.main()
