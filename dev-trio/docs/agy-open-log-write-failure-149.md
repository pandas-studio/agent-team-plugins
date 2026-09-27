# agy logging with a pre-created file on a full volume (#149)

Measured on 2026-09-27 and 2026-09-28 with agy 1.2.11 and 1.2.12 on macOS.
The earlier agy 1.2.9 measurement covered a log path that could not be opened
and sent 24.8 KB to stderr. Three full-volume runs used pre-created mode-0600
logs on 32 MiB HFS+ images: one started with an allocated data block, and two
started at zero bytes with no allocated block. Both zero-byte logs were created
before their images filled; one was created by the wrapper itself.

## Paired runs

Both paired invocations used agy 1.2.11 with the same command and prompt. The
control used an empty log on the host APFS Data volume; the failure run used a
1,024-byte log on the full HFS+ image.

The failure run's `--log-file` path pointed into the HFS+ image. Both used:

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

## Initial zero-byte direct observation

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

This call alone did not distinguish a full-volume failure from an unrelated
startup, authentication, or argument failure. A later same-version writable
control, recorded below, validates the argv and stdin shape. Neither call
traces the failing syscall or establishes exactly when agy opened the log.

This run did not execute `ask-researcher.sh` itself. Its registry configuration
uses the argv and stdin shape above, and the wrapper redirects agy's stderr
into its private transcript. This direct call provided zero stderr bytes for
that route. The later wrapper run below inspects the actual transcript.

## 1.2.12 writable controls and full-volume wrapper run

On 2026-09-28, a writable control used agy 1.2.12, the same argv and stdin
prompt as the initial zero-byte direct call, and the same `--add-dir` workspace.
Its new mode-0600 log was on the host APFS Data volume. It returned `OK` on
stdout (3 bytes), rc 0 in 13.775 seconds, with zero stderr bytes; the log grew
from zero to 27,393 bytes. This confirms that agy could answer with that
argv/stdin shape. The direct full-volume call was made the previous day, so
the pair is not a simultaneous control of authentication or provider state.

A separate run invoked `ask-researcher.sh` itself. It first created a new
mode-0600, zero-byte agy log on a writable 32 MiB HFS+ image. A one-use
`RESEARCHER_CLI` binary override filled that image, then executed the real agy
1.2.12 binary with the wrapper's actual argv and stdin prompt. Immediately
before agy started, the log still had zero allocated blocks and the same
inode. The image reported zero free blocks; append-open of the log succeeded,
while a write to a separate pre-created empty file failed with `ENOSPC`
before and after agy. The workspace and normal user home (`HOME`) were on host
APFS Data. The wrapper's `DEV_TRIO_AGY_HOME` placed its pinned log and unused
denial-transcript lookup on the HFS+ image.

A second `ask-researcher.sh` run used a new writable mode-0600 agy log on host
APFS Data; its `DEV_TRIO_AGY_HOME` pointed to a private APFS directory. It used
the same wrapper, query, role file, workspace, built-in agy
model, and agy 1.2.12 binary. The two manifests recorded the same resolved
prompt SHA-256 (`5bd1b08d7daf68525d9d596dceac9229488b68797a7a1b3847f8f3087430513b`).
The full-volume run's binary override only filled the image before executing
agy; the writable wrapper control invoked agy directly.

| Wrapper condition | Elapsed | Exit | Stdout | Stderr | Transcript | Pinned agy log |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Writable APFS log | 22.480 s | 0 | 198 bytes | 418 bytes | 355 bytes | 0 → 26,666 bytes |
| Full HFS+ log | 2.709 s | 2 | 1 newline byte | 1,036 bytes | 157 bytes | 0 → 0 bytes |

Both pinned logs remained mode 0600. All 41 allow-list entries had zero exact
matches in each captured wrapper stdout, user-facing stderr, and private
transcript. The full-volume wrapper published a failed runstate
(`exit_code=2`, `reason=failed`); the writable control published rc 0 and
`reason=ok`. The user query was `Reply only OK.`; the wrapper's stdin also
carried its researcher role framing and execution-environment note, which the
direct control did not.

The full-volume user-facing stderr had seven lines, including the wrapper's
running, failure, inspection, setup-check, and recovery notices. The
setup-check notice included the `RESEARCHER_CLI` override path. Its eight-line
transcript contained query, response, and end markers; neither capture had an
agy timestamp marker. Raw transcript contents were kept privately outside
this repository. The matching prompt and successful wrapper control support
attributing rc 2 to the full-volume condition. The control also differed in
log filesystem (APFS versus HFS+) and lacked the override exec layer; the agy
syscall that failed was not traced.

## Stderr and wrapper consequence

The allocated-block full-volume run emitted **no stderr bytes**, so it did not
fall back to stderr in this measured case. Its stdout and stderr were both
empty, so the 41 `settings.permissions.allow` entries could not appear in
either stream. `ask-researcher.sh` and `ask-reviewer.sh` redirect agy's stderr
into their private transcript. The wrapper run above measured the transcript
and user-facing failure output for a zero-byte pinned log when the volume
filled after its creation.

Each condition was run once (n=1). No allow-list spill was observed in the
measured full-volume cases. #149 adds no stderr scrub or leak-path stub test
on that basis; this decision remains unverified for `ask-reviewer.sh`, other
filesystems, quota errors, other write-failure timing, and other agy versions.
There was no same-version test of an unopenable log path, so these runs cannot
distinguish a removed fallback in newer agy versions from one that this failure
timing did not trigger.
