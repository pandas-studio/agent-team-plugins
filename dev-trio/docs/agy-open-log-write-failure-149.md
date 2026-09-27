# agy log write failure after open (#149)

Measured on 2026-09-27 with agy 1.2.11 on macOS. The earlier agy 1.2.9
measurement covered a log path that could not be opened and sent 24.8 KB to
stderr. This experiment instead used a pre-created mode-0600 log on a full
32 MiB HFS+ volume.

## Paired runs

Both live invocations used the same agy command and prompt. The control used
an empty log on the host APFS Data volume; the failure run used a 1,024-byte
log on the full HFS+ image:

```text
agy --log-file <log> -p 'Reply only OK.' --print-timeout 30s
```

| Condition | Elapsed | Exit | Stdout | Stderr | Log before → after |
| --- | ---: | ---: | --- | ---: | ---: |
| Writable private log | 12.935 s | 0 | `OK` (3 bytes) | 0 bytes | 0 → 25,477 bytes |
| Full-volume private log | 3.149 s | 2 | 0 bytes | 0 bytes | 1,024 → 4,096 bytes |

The control produced the requested answer before the 30-second timeout. The
full-volume run ended much sooner, without a model answer. A separate 45-second
capture timeout did not fire in either run.

## Full-volume precondition and log evidence

- The existing log was written with a 4,096-byte marker, then truncated to
  1,024 bytes, retaining one allocated 4,096-byte block. It was mode 0600.
- The volume reported zero available blocks. Opening the log for append
  succeeded. A separate pre-created probe file's next-block append failed
  with `ENOSPC` (errno 28), both before and after the agy invocation.
- After agy exited, the log occupied one allocated block and remained
  mode 0600. Its size was 4,096 bytes. The original marker was no longer at
  the start; the new first line matched agy's letter-prefixed timestamp form
  (`[IWEF]` plus date and time), and the file contained 29 newline bytes. The
  first line was 92 bytes with SHA-256
  `9eac10588395abb2ebcd647054ad9102323cd3fbb14fdcb76dd7ebfe11734239`.
  The content change was not append-only: agy overwrote, truncated, or
  replaced the earlier bytes before writing new log lines. These checks were
  made without printing log contents.
- The full-volume log's SHA-256 changed from
  `9ea764ef654dc61f19ab23af219e5aa420b68157b1d135dc297ab0527941f951`
  to `3d56e7d12f80b5e4b5b7e8c49d416c1bb88e998ed2c3df7427448ebd82177e19`.

The matching successful control, short failure run, zero free blocks, and agy
log content reaching the end of its allocated block support the conclusion
that the full log volume stopped agy. The shell's `ENOSPC` check establishes
the filesystem condition; agy's own failing write syscall was not traced.

## Stderr and wrapper consequence

The 41 current `settings.permissions.allow` entries were checked against each
captured stdout and stderr stream without printing their values: **zero
matches** in both runs. The full-volume run emitted **no stderr bytes**, so it
did not fall back to stderr in this measured case. `ask-researcher.sh` and
`ask-reviewer.sh` both redirect agy's stderr into their private transcript;
the observed zero-byte stderr stream would add no allow-list content through
that path. The live invocations called agy directly, so a wrapper transcript
was not separately measured.

Each condition was run once (n=1). This result covers agy 1.2.11 with an
already allocated log block on this full HFS+ volume. It does not establish
behavior for agy 1.2.9, quota errors, or other write-failure timing.
