# agy logging with a pre-created file on a full volume (#149)

Measured on 2026-09-27 with agy 1.2.11 and 1.2.12 on macOS. The earlier agy
1.2.9 measurement covered a log path that could not be opened and sent 24.8 KB
to stderr. These experiments used pre-created mode-0600 logs on full 32 MiB HFS+
volumes: one log had an allocated data block; the other had zero bytes and no
allocated block, matching the file state just after wrapper pre-creation.

## Paired runs

Both live invocations used agy 1.2.11 with the same command and prompt. The control used
an empty log on the host APFS Data volume; the failure run used a 1,024-byte
log on the full HFS+ image:

```text
agy --log-file <log> -p 'Reply only OK.' --print-timeout 30s
```

| Condition | agy | Elapsed | Exit | Stdout | Stderr | Log before → after |
| --- | --- | ---: | ---: | --- | ---: | ---: |
| Writable private log | 1.2.11 | 12.935 s | 0 | `OK` (3 bytes) | 0 bytes | 0 → 25,477 bytes |
| Full-volume private log | 1.2.11 | 3.149 s | 2 | 0 bytes | 0 bytes | 1,024 → 4,096 bytes |

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
  first line was 92 bytes. The content change was not append-only: agy
  overwrote, truncated, or replaced the earlier bytes before writing new log
  lines. These checks were made without printing log contents.

The successful control, short failure run, zero free blocks, and agy log
content reaching the end of its allocated block are consistent with the full
log volume stopping agy. The control also differed in filesystem (APFS versus
HFS+) and prior log content (empty versus 1,024 bytes). The shell's `ENOSPC`
check establishes the filesystem condition; agy's own failing write syscall
was not traced.

## Exploratory zero-byte log observation

On a second full 32 MiB HFS+ volume, the log was created before the volume was
filled. Immediately before agy 1.2.12 ran, it was mode 0600, size zero, with
zero allocated 512-byte blocks and zero free filesystem blocks. Opening the
log for append succeeded; writing 4,096 bytes to a separate pre-created empty
file failed with `ENOSPC` (errno 28). The same probe failed after agy exited.
Creating a *new* file on the already full volume also failed with `ENOSPC`, so
this setup models the disk filling after the wrapper has created its log.

The single live call used the registry's agy argv order and stdin delivery:

```text
agy --log-file <zero-byte-log> --add-dir <workspace> --input-format text --output-format text
stdin: Reply only OK. followed by a newline
```

The `--add-dir` workspace and agy home were on the writable host APFS Data
volume, outside the full HFS+ image. Only `--log-file` pointed into that image.

It exited rc 2 in 0.304 seconds, without reaching the 45-second capture
timeout. Stdout and stderr were both zero bytes. The log remained zero bytes,
mode 0600, zero allocated blocks, and the same inode. The 41 current
`settings.permissions.allow` entries had zero matches in either captured
stream. The private captures were retained locally for inspection; their
contents were not copied into this repository.

There was no same-version writable control with this argv and stdin shape.
Thus rc 2 cannot be attributed to the full volume: an unrelated startup,
authentication, or argument failure could produce the same observation. This
run does not establish that agy opened the log or reached a failed write.

This run did not execute `ask-researcher.sh` itself. Its registry configuration
uses the argv and stdin shape above, and the wrapper redirects agy's stderr
into its private transcript. This direct call provided zero stderr bytes for
that route, but does not establish what the wrapper transcript would contain
in a confirmed first-write failure. Actual transcript contents were not
inspected.

## Stderr and wrapper consequence

The allocated-block full-volume run emitted **no stderr bytes**, so it did not
fall back to stderr in this measured case. Its stdout and stderr were both
empty, so the 41 `settings.permissions.allow` entries could not appear in
either stream. `ask-researcher.sh` and `ask-reviewer.sh` redirect agy's stderr
into their private transcript. All live invocations here called agy directly.
Actual wrapper transcript contents and user-visible failure reporting were
not measured.

Each condition was run once (n=1). There was also no same-version test of a
log path that agy could not open, so these runs cannot distinguish whether
newer agy versions removed stderr fallback from whether this full-volume
condition simply did not trigger it. These results do not establish behavior
for agy 1.2.9, quota errors, or other write-failure timing.
