"""A `jq` on PATH that fails one chosen call, for the tests of jq exit-status handling.

Imported by the test modules (not itself a test module); they put this directory on
`sys.path` first, so it loads whether the suite is discovered or a module is run alone.
"""

import os
from pathlib import Path
import shlex
import shutil

# The libraries target macOS's bash 3.2 as well as current bash.
SHELLS = tuple(dict.fromkeys(s for s in ("/bin/bash", shutil.which("bash")) if s and os.path.exists(s)))


def write_jq_shim(bin_dir, counter, real_jq, match, n=1, mode="empty", stderr=False):
    """Put a `jq` in bin_dir that fails the n-th call carrying every argument in `match`.

    `match` is one exact argument or a tuple of them; a call matches when each one is among
    its arguments. `counter` records how many calls matched. Modes: "empty" exits 1 with no
    output, "output" prints the real result and then exits 1, "count" fails nothing and only
    counts. `stderr` makes a failing call also write its own error line.
    """
    counter = Path(counter)
    counter.write_text("0")
    real = shlex.quote(str(real_jq))
    c = shlex.quote(str(counter))
    if mode == "empty":
        fail = "exit 1"
    elif mode == "output":
        fail = f'{real} "$@"; exit 1'
    elif mode == "count":
        fail = ":"
    else:
        raise ValueError(mode)
    if stderr:
        fail = "echo 'jq: error: injected' >&2; " + fail
    tokens = (match,) if isinstance(match, str) else tuple(match)
    checks = "".join(
        f'found=; for a in "$@"; do [ "$a" = {shlex.quote(t)} ] && found=1; done; [ -n "$found" ] || hit=\n'
        for t in tokens)
    shim = Path(bin_dir) / "jq"
    shim.write_text(
        "#!/bin/sh\n"
        "hit=1\n"
        + checks +
        'if [ -n "$hit" ]; then\n'
        f"  k=$(($(cat {c}) + 1)); echo \"$k\" > {c}\n"
        f'  if [ "$k" = {int(n)} ]; then {fail}; fi\n'
        "fi\n"
        f'exec {real} "$@"\n')
    shim.chmod(0o755)
