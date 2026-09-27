# agy log write failure after open (#149)

Measured on 2026-09-27 UTC with agy 1.2.11 on macOS. This is a measurement of
the installed version, not a repeat of the earlier agy 1.2.9 measurement where
an unopenable log path sent 24.8 KB to stderr.

## Setup and control

- Created a 32 MiB HFS+ disk image and a mode-0600 `agy.log` on it before
  exhausting the volume. The volume reported zero available blocks.
- Opening the existing log for append succeeded. An append that needed a new
  block failed with `ENOSPC` (errno 28). This distinguishes the case from a
  log path that cannot be opened.
- Captured stdout and stderr into separate mode-0600 files outside the full
  volume. Checked for all 41 entries in the local `permissions.allow` list
  without printing their values.

## Observation

An offline `agy --log-file <full-volume-log> agent list` command exited 1,
emitted 36 stderr bytes, and did not write the log. It was not a useful
post-open measurement. A sandboxed print-mode attempt stopped before model
execution because local socket binding was denied; its 71 stderr bytes held no
allow-list entry.

The same print-mode command outside the sandbox, with prompt `Reply only OK.`
and a 30-second print timeout, exited 2. It emitted **0 stdout bytes and 0
stderr bytes**. The existing log ended at 4,096 bytes, on a volume still
reporting zero available blocks. None of the 41 allow-list entries appeared in
the captured stdout or stderr. No model answer was produced.

The current dev-trio wrappers direct agy's stderr into their transcript, so
the observed zero stderr bytes would add no allow-list content there. This
wrapper consequence follows from the code path; the live command above called
agy directly. The result shows that this agy 1.2.11 failure stopped the run
without spilling its log to stderr. It does not establish behavior for agy
1.2.9, other write-failure timing, or a run that continues after a write error.
