# agy log write failure after open (#149)

Measured on 2026-09-27 UTC with agy 1.2.11 on macOS. This is a measurement of
the installed version, not a repeat of the earlier agy 1.2.9 measurement where
an unopenable log path sent 24.8 KB to stderr.

## Setup

- Created a 32 MiB HFS+ disk image and a mode-0600 `agy.log` on it before
  exhausting the volume. The volume reported zero available blocks.
- Opening the existing log for append succeeded. A separate shell append that
  needed a new block failed with `ENOSPC` (errno 28). This confirms the
  filesystem condition, but does not establish that agy encountered the same
  write failure.
- Captured stdout and stderr into separate mode-0600 files outside the full
  volume. Checked for all 41 entries in the local `permissions.allow` list
  without printing their values.

## Observation

An offline `agy --log-file <full-volume-log> agent list` command exited 1,
emitted 36 stderr bytes, and did not write the log. It was not a useful
post-open measurement. A sandboxed print-mode attempt stopped before model
execution because local socket binding was denied; its 71 stderr bytes held no
allow-list entry.

The print-mode command outside the sandbox, with prompt `Reply only OK.` and a
30-second print timeout, exited 2. It emitted **0 stdout bytes and 0 stderr
bytes**. The existing log grew from 1,283 to 4,096 bytes on a volume still
reporting zero available blocks. None of the 41 allow-list entries appeared in
the captured stdout or stderr. No model answer was produced. Elapsed time was
not recorded, and no matching writable-log control run was made.

Both current dev-trio wrappers, `ask-researcher.sh` and `ask-reviewer.sh`,
direct agy's stderr into their transcript, so the observed zero stderr bytes
would add no allow-list content there. This wrapper consequence follows from
the code path; the live command above called agy directly.

This run did not spill log contents to stderr. Its exit code cannot yet be
attributed to a failed agy log write: a timeout, authentication failure, or
another cause remains possible. Whether agy continues after a post-open log
write error is therefore still unmeasured. A matching writable-log control,
timings for both runs, and retained before/after log evidence are needed to
settle that question. The result does not establish behavior for agy 1.2.9 or
other write-failure timing.
