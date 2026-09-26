#!/usr/bin/env python3
"""Precompute bounded workspace snapshot for agy reviewer (#109).

Opens descriptors without following symlinks (artifacts.py pattern),
bounds all reads, accounts for multibyte lengths in bytes, and buffers
output to guarantee atomic generation.
"""

from __future__ import annotations

import fnmatch
import io
import math
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import time


def kill_process_tree(proc: subprocess.Popen) -> None:
    try:
        pgid = os.getpgid(proc.pid)
        os.killpg(pgid, signal.SIGKILL)
    except OSError:
        try:
            proc.kill()
        except OSError:
            pass


def run_bounded(cmd: list[str], max_bytes: int, timeout: float = 10.0) -> tuple[int, bytes]:
    if max_bytes <= 0:
        return 0, b""
    try:
        if "DEV_TRIO_GIT_TIMEOUT" in os.environ:
            timeout = float(os.environ["DEV_TRIO_GIT_TIMEOUT"])
    except ValueError:
        pass
    if not math.isfinite(timeout) or timeout <= 0:
        timeout = 10.0
    env = os.environ.copy()
    env["GIT_OPTIONAL_LOCKS"] = "0"
    deadline = time.monotonic() + timeout
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=env,
        start_new_session=True,
    )
    if proc.stdout is None:
        return 1, b""
    os.set_blocking(proc.stdout.fileno(), False)
    chunks: list[bytes] = []
    total = 0
    timed_out = False
    killed = False
    io_error = False

    while True:
        rem = deadline - time.monotonic()
        if rem <= 0:
            timed_out = True
            kill_process_tree(proc)
            break
        r, _, _ = select.select([proc.stdout], [], [], min(rem, 0.1))
        if r:
            try:
                chunk = os.read(proc.stdout.fileno(), 65536)
            except BlockingIOError:
                continue
            except OSError:
                io_error = True
                kill_process_tree(proc)
                break
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                killed = True
                kill_process_tree(proc)
                break
        # Even after Git exits, its pipe can still contain several chunks.
        # Continue until EOF (or the byte/time cap) so success is complete.

    try:
        proc.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        kill_process_tree(proc)
        try:
            proc.wait(timeout=0.5)
        except Exception:
            pass

    try:
        proc.stdout.close()
    except OSError:
        pass

    if timed_out:
        return 124, b""
    if io_error:
        return 125, b""
    rc = 0 if killed else proc.returncode
    data = b"".join(chunks)[: max_bytes + 1]
    return rc, data


# Exit codes for a snapshot that was not produced. Each one prints nothing on
# stdout, so the wrapper never injects partial output; it maps the code to a
# fixed reason for the manifest, run.json and stderr (#137).
SKIP_UNSUPPORTED = 3
SKIP_NOT_WORKTREE = 4
SKIP_GIT_FAILED = 5
SKIP_GIT_TIMEOUT = 6
SKIP_PARSE_FAILED = 7
SKIP_BUDGET = 8


def skip(code: int) -> None:
    sys.exit(code)


def run_git(
    cmd: list[str], max_bytes: int, ok: tuple[int, ...] = (0,)
) -> tuple[int, bytes]:
    """run_bounded for the snapshot, and the one place Git outcomes are classified.

    A timeout drops the whole snapshot as git-timeout; any exit status outside
    `ok` (the ones this call site handles itself) drops it as git-failed.
    """
    result = run_bounded(cmd, max_bytes)
    if result[0] == 124:
        skip(SKIP_GIT_TIMEOUT)
    if result[0] not in ok:
        skip(SKIP_GIT_FAILED)
    return result


def truncate_utf8(data: bytes, limit: int) -> bytes:
    if len(data) <= limit:
        return data
    chunk = data[:max(0, limit)]
    for i in range(1, min(5, len(chunk) + 1)):
        b = chunk[-i]
        if (b & 0xC0) != 0x80:
            if (b & 0x80) == 0:
                return chunk
            if (b & 0xE0) == 0xC0:
                expected = 2
            elif (b & 0xF0) == 0xE0:
                expected = 3
            elif (b & 0xF8) == 0xF0:
                expected = 4
            else:
                expected = 1
            if i < expected:
                return chunk[:-i]
            return chunk
    return chunk


SENSITIVE_FILENAME_PATTERNS = [
    ".env*",
    "*.env",
    "*.pem",
    "*.key",
    "*.jks",
    "*.keystore",
    "*.p12",
    "*.pfx",
    "*.pkcs12",
    "*.kdbx",
    "id_rsa*",
    "id_ed25519*",
    "id_ecdsa*",
    "id_dsa*",
    "secrets.json",
    "service-account*.json",
    "credentials.json",
    "token.json",
    "auth.json",
    "kubeconfig",
    ".netrc",
    ".npmrc",
    ".pypirc",
    ".pgpass",
    ".htpasswd",
    ".git-credentials",
    "*.tfvars*",
    "*.tfstate*",
]

SENSITIVE_DIR_PATTERNS = [
    ".dev-trio",
    ".env*",
    ".aws",
    ".kube",
    ".ssh",
    ".docker",
    ".gnupg",
]

SENSITIVE_PATH_EXCLUDES = [
    f":(icase,exclude,glob)**/{pat}" for pat in SENSITIVE_FILENAME_PATTERNS
] + [
    f":(icase,exclude,glob)**/{dpat}/**" for dpat in SENSITIVE_DIR_PATTERNS
]

STATUS_PARSE_MAX_BYTES = 1024 * 1024


def is_sensitive_filename(name: str) -> bool:
    lower = name.lower()
    return any(fnmatch.fnmatch(lower, pat) for pat in SENSITIVE_FILENAME_PATTERNS)


def is_sensitive_path(
    rel_path: str,
    custom_log_rel: str | None = None,
    custom_log_rels: tuple[str, ...] | list[str] | None = None,
) -> bool:
    rels: list[str] = []
    if custom_log_rel:
        rels.append(custom_log_rel)
    if custom_log_rels:
        rels.extend(custom_log_rels)
    if rels:
        clean_rel = rel_path.rstrip("/")
        for r in rels:
            clean_log = r.rstrip("/")
            if clean_rel.casefold() == clean_log.casefold() or clean_rel.casefold().startswith(
                clean_log.casefold() + "/"
            ):
                return True
    parts = Path(rel_path).parts
    if not parts:
        return False
    if is_sensitive_filename(parts[-1]):
        return True
    for p in parts:
        lower_p = p.lower()
        if any(fnmatch.fnmatch(lower_p, dpat) for dpat in SENSITIVE_DIR_PATTERNS):
            return True
    return False


def display_path(path: str) -> str:
    """Keep one filesystem path on one snapshot line."""
    return path.replace("\r", "\\r").replace("\n", "\\n")


def parse_status_z(data: bytes) -> list[tuple[str, str, str | None]]:
    """Decode porcelain v1 -z without Git's quotePath presentation layer.

    Rename/copy records carry the destination first and the source in the
    following NUL-delimited field.
    """
    if data and not data.endswith(b"\0"):
        raise ValueError("incomplete porcelain status")
    fields = data.split(b"\0")[:-1] if data else []
    entries: list[tuple[str, str, str | None]] = []
    i = 0
    while i < len(fields):
        record = fields[i]
        i += 1
        if len(record) < 4 or record[2:3] != b" ":
            raise ValueError("invalid porcelain status")
        code = record[:2].decode("ascii")
        path = os.fsdecode(record[3:])
        source = None
        if "R" in code or "C" in code:
            if i >= len(fields):
                raise ValueError("incomplete porcelain rename")
            source = os.fsdecode(fields[i])
            i += 1
        entries.append((code, path, source))
    return entries


def diff_requires_omission(
    repo_root: str, diff_args: list[str], extra_log_rels: list[str]
) -> bool | None:
    """Omit a committed range when a sensitive path changed or the probe failed."""
    max_names = 65536
    rc, data = run_git(
        [
            "git", "-c", "core.fsmonitor=false", "-C", repo_root,
            "diff", "--name-status", "-z", "--no-renames",
            *diff_args, "--",
        ],
        max_names,
    )
    # Too many names or malformed output: omit content with a notice.
    if len(data) > max_names or (data and not data.endswith(b"\0")):
        return None
    fields = data.split(b"\0")[:-1] if data else []
    i = 0
    while i < len(fields):
        status = fields[i]
        i += 1
        if not status or i >= len(fields):
            return None
        path = os.fsdecode(fields[i])
        i += 1
        if is_sensitive_path(path, custom_log_rels=extra_log_rels):
            return True
    return False


def main() -> None:
    if not (hasattr(os, "O_NOFOLLOW") and hasattr(os, "O_DIRECTORY")):
        skip(SKIP_UNSUPPORTED)

    if len(sys.argv) < 5:
        sys.exit(2)

    repo_root = sys.argv[1]
    scope = sys.argv[2]
    target = sys.argv[3]
    if scope not in ("range", "working-tree"):
        sys.exit(2)
    try:
        budget_bytes = int(sys.argv[4])
    except ValueError:
        sys.exit(2)

    rc, wt_out = run_git(
        [
            "git",
            "-c",
            "core.fsmonitor=false",
            "-C",
            repo_root,
            "rev-parse",
            "--is-inside-work-tree",
        ],
        1024,
        ok=(0, 128),
    )
    if rc != 0 or wt_out.strip() != b"true":
        skip(SKIP_NOT_WORKTREE)

    out = io.BytesIO()
    effective_budget = max(0, budget_bytes - 4096)
    remaining = effective_budget

    extra_log_rels: list[str] = []
    candidates: list[str] = []
    if len(sys.argv) > 5 and sys.argv[5]:
        candidates.append(sys.argv[5])
    if os.environ.get("DEV_TRIO_LOG_DIR"):
        candidates.append(os.environ["DEV_TRIO_LOG_DIR"])
    for log_dir_input in candidates:
        try:
            cand = Path(log_dir_input).expanduser().resolve()
            repo_resolved = Path(repo_root).expanduser().resolve()
            if cand == repo_resolved or repo_resolved in cand.parents:
                rel = cand.relative_to(repo_resolved).as_posix()
                if rel and rel != "." and rel not in extra_log_rels:
                    extra_log_rels.append(rel)
        except Exception:
            pass

    sensitive_excludes = list(SENSITIVE_PATH_EXCLUDES)
    for extra_log_rel in extra_log_rels:
        # The directory is a literal path even when its name contains glob
        # metacharacters. A directory pathspec excludes its descendants too.
        sensitive_excludes.append(f":(exclude,top,icase,literal){extra_log_rel}")

    if scope == "range":
        header = f"### git diff {target}\n".encode("utf-8", errors="backslashreplace")
        if len(header) >= remaining:
            skip(SKIP_BUDGET)
        out.write(header)
        remaining -= len(header)

        omission = diff_requires_omission(repo_root, [target], extra_log_rels)
        if omission is not False:
            reason = (
                b"a sensitive path is present"
                if omission else b"the change-name probe was incomplete"
            )
            out.write(b"[... range diff content omitted because " + reason + b"; inspect directly with 'git diff " + target.encode("utf-8", errors="backslashreplace") + b" --' ...]\n")
            sys.stdout.buffer.write(out.getvalue())
            sys.exit(0)

        if remaining <= 0:
            out.write(
                f"\n[... snapshot truncated at {budget_bytes} bytes; run 'git diff {target} --' for remaining diff ...]\n".encode(
                    "utf-8"
                )
            )
            sys.stdout.buffer.write(out.getvalue())
            sys.exit(0)

        rc, data = run_git(
            [
                "git",
                "-c",
                "core.fsmonitor=false",
                "-C",
                repo_root,
                "diff",
                "--no-color",
                "--no-ext-diff",
                "--no-textconv",
                "--no-renames",
                target,
                "--",
                *sensitive_excludes,
            ],
            remaining,
        )
        data = data.replace(b"\0", b"\\0")
        if len(data) > remaining:
            out.write(truncate_utf8(data, remaining))
            out.write(
                f"\n[... snapshot truncated at {budget_bytes} bytes; run 'git diff {target} --' for remaining diff ...]\n".encode(
                    "utf-8"
                )
            )
        else:
            out.write(data)

    elif scope == "working-tree":
        # 1. Working tree status
        rc, data = run_git(
            [
                "git",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "color.status=never",
                "-C",
                repo_root,
                "status",
                "--porcelain=v1",
                "-z",
                "--untracked-files=all",
            ],
            STATUS_PARSE_MAX_BYTES,
        )
        header = b"### Working tree status\n"
        if len(data) > STATUS_PARSE_MAX_BYTES:
            out.write(header)
            out.write(
                b"[... status exceeded snapshot budget; diff and untracked files were omitted. Run 'git status --short --untracked-files=all', then 'git diff HEAD' if HEAD exists, or 'git diff --cached' and 'git diff --' otherwise ...]\n"
            )
            sys.stdout.buffer.write(out.getvalue())
            sys.exit(0)
        try:
            status_entries = parse_status_z(data)
        except ValueError:
            skip(SKIP_PARSE_FAILED)
        # Excluded log directories can still be either side of a move.
        # Preserve deletion and rename signals before hiding log paths.
        has_hidden_move_risk = any(
            code != "??" and (
                "D" in code or (
                    ("R" in code or "C" in code)
                    and any(
                        entry and is_sensitive_path(entry, custom_log_rels=extra_log_rels)
                        for entry in (path, source)
                    )
                )
            )
            for code, path, source in status_entries
        )
        visible_entries = []
        for code, path, source in status_entries:
            if path == ".dev-trio" or path.startswith(".dev-trio/") or any(
                path.casefold() == rel.casefold() or path.casefold().startswith(rel.casefold() + "/")
                for rel in extra_log_rels
            ):
                continue
            visible_entries.append((code, path, source))
        status_lines = [
            f"{code} {display_path(path)}"
            + (f" <- {display_path(source)}" if source is not None else "")
            for code, path, source in visible_entries
        ]
        data = ("\n".join(status_lines) + ("\n" if status_lines else "")).encode(
            "utf-8", errors="backslashreplace"
        )
        if len(header) + len(data) > remaining:
            out.write(header)
            out.write(truncate_utf8(data, max(0, remaining - len(header))))
            out.write(
                b"\n[... status exceeded snapshot budget; diff and untracked files were omitted. Run 'git status --short --untracked-files=all', then 'git diff HEAD' if HEAD exists, or 'git diff --cached' and 'git diff --' otherwise ...]\n"
            )
            sys.stdout.buffer.write(out.getvalue())
            sys.exit(0)
        out.write(header)
        out.write(data)
        remaining = max(0, remaining - len(header) - len(data))

        # A tracked deletion can be a move to an ignored sensitive path, or
        # from a tracked sensitive path into an ordinary file. An ignored or
        # untracked source moved into an ordinary file is indistinguishable
        # from a copy and cannot be detected here.
        if has_hidden_move_risk or any(
            (code != "??" and "D" in code)
            or any(
                entry and is_sensitive_path(entry, custom_log_rels=extra_log_rels)
                for entry in (path, source)
            )
            for code, path, source in visible_entries
        ):
            out.write(
                b"[... tracked diff and untracked contents omitted because a sensitive path or tracked deletion is present; inspect directly with git and your file viewer ...]\n"
            )
            sys.stdout.buffer.write(out.getvalue())
            sys.exit(0)

        # 2. Tracked modifications
        rc_head, _ = run_git(
            [
                "git",
                "-c",
                "core.fsmonitor=false",
                "-C",
                repo_root,
                "rev-parse",
                "--verify",
                "--quiet",
                "HEAD",
            ],
            1024,
            # rev-parse --verify --quiet exits 1 for an unborn HEAD.
            ok=(0, 1),
        )
        has_head = rc_head == 0

        if has_head:
            if remaining <= 0:
                out.write(
                    b"### Tracked modifications\n[... snapshot budget reached; tracked diff and untracked files were omitted. Run 'git diff HEAD' directly ...]\n"
                )
                sys.stdout.buffer.write(out.getvalue())
                sys.exit(0)
            rc, diff_data = run_git(
                [
                    "git",
                    "-c",
                    "core.fsmonitor=false",
                    "-C",
                    repo_root,
                    "diff",
                    "--no-color",
                    "--no-ext-diff",
                    "--no-textconv",
                    "--no-renames",
                    "HEAD",
                    "--",
                    *sensitive_excludes,
                ],
                remaining,
            )
            diff_header = b"### Tracked modifications\n"
            out.write(diff_header)
            remaining = max(0, remaining - len(diff_header))
            if len(diff_data) > 0:
                diff_data = diff_data.replace(b"\0", b"\\0")
                if len(diff_data) > remaining:
                    out.write(truncate_utf8(diff_data, remaining))
                    out.write(
                        f"\n[... tracked diff filled snapshot budget ({budget_bytes} bytes); untracked files were omitted. Run 'git diff HEAD --' for remaining changes and use 'git status --short --untracked-files=all' and your file viewer to inspect untracked files ...]\n".encode(
                            "utf-8"
                        )
                    )
                    sys.stdout.buffer.write(out.getvalue())
                    sys.exit(0)
                else:
                    out.write(diff_data)
                    remaining = max(
                        0, remaining - len(diff_data)
                    )
            else:
                out.write(b"(no tracked modifications)\n")
        else:
            # Initial repo without HEAD
            # Staged diff
            if remaining <= 0:
                out.write(
                    b"### Staged modifications\n[... snapshot budget reached; staged diff, unstaged diff, and untracked files were omitted. Run 'git diff --cached --' directly ...]\n"
                )
                sys.stdout.buffer.write(out.getvalue())
                sys.exit(0)
            rc, staged = run_git(
                [
                    "git",
                    "-c",
                    "core.fsmonitor=false",
                    "-C",
                    repo_root,
                    "diff",
                    "--no-color",
                    "--no-ext-diff",
                    "--no-textconv",
                    "--no-renames",
                    "--cached",
                    "--",
                    *sensitive_excludes,
                ],
                remaining,
            )
            staged_header = b"### Staged modifications\n"
            if len(staged) > 0:
                staged = staged.replace(b"\0", b"\\0")
                if len(staged_header) + len(staged) > remaining:
                    out.write(staged_header)
                    out.write(truncate_utf8(staged, max(0, remaining - len(staged_header))))
                    out.write(
                        b"\n[... staged diff filled snapshot budget; unstaged diff and untracked files omitted. Run 'git diff --cached --' and 'git diff --' directly ...]\n"
                    )
                    sys.stdout.buffer.write(out.getvalue())
                    sys.exit(0)
                else:
                    out.write(staged_header + staged)
                    remaining = max(
                        0, remaining - len(staged_header) - len(staged)
                    )

            # Unstaged diff
            if remaining <= 0:
                out.write(
                    b"### Unstaged modifications\n[... snapshot budget reached; unstaged diff and untracked files were omitted. Run 'git diff --' directly ...]\n"
                )
                sys.stdout.buffer.write(out.getvalue())
                sys.exit(0)
            rc, unstaged = run_git(
                [
                    "git",
                    "-c",
                    "core.fsmonitor=false",
                    "-C",
                    repo_root,
                    "diff",
                    "--no-color",
                    "--no-ext-diff",
                    "--no-textconv",
                    "--no-renames",
                    "--",
                    *sensitive_excludes,
                ],
                remaining,
            )
            unstaged_header = b"### Unstaged modifications\n"
            if len(unstaged) > 0:
                unstaged = unstaged.replace(b"\0", b"\\0")
                if len(unstaged_header) + len(unstaged) > remaining:
                    out.write(unstaged_header)
                    out.write(
                        truncate_utf8(unstaged, max(0, remaining - len(unstaged_header)))
                    )
                    out.write(
                        b"\n[... unstaged diff filled snapshot budget; untracked files omitted. Run 'git diff --' directly ...]\n"
                    )
                    sys.stdout.buffer.write(out.getvalue())
                    sys.exit(0)
                else:
                    out.write(unstaged_header + unstaged)
                    remaining = max(
                        0, remaining - len(unstaged_header) - len(unstaged)
                    )

        # 3. Untracked files
        if remaining <= 256:
            out.write(
                b"\n[... snapshot budget reached; untracked files were omitted. Use 'git status --short --untracked-files=all' and your file viewer tool to read untracked files ...]\n"
            )
        else:
            root_path = Path(repo_root).expanduser().resolve()
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            root_fd = None
            try:
                root_fd = os.open(root_path.anchor, flags)
                for part in root_path.parts[1:]:
                    child = os.open(part, flags, dir_fd=root_fd)
                    os.close(root_fd)
                    root_fd = child
            except OSError:
                if root_fd is not None:
                    try:
                        os.close(root_fd)
                    except OSError:
                        pass
                    root_fd = None
                try:
                    root_fd = os.open(
                        str(root_path),
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    )
                except OSError:
                    out.write(
                        b"\n[... repository directory path contains symlink or could not be opened safely ...]\n"
                    )
                    sys.stdout.buffer.write(out.getvalue())
                    sys.exit(0)

            try:
                ls_env = os.environ.copy()
                ls_env["GIT_OPTIONAL_LOCKS"] = "0"
                ls_cmd = [
                    "git",
                    "-c",
                    "core.fsmonitor=false",
                    "-c",
                    "color.ui=never",
                    "-C",
                    repo_root,
                    "ls-files",
                    "--others",
                    "--exclude-standard",
                    "--exclude=.dev-trio",
                    "--exclude=.dev-trio/**",
                ]
                ls_cmd.append("-z")
                if extra_log_rels:
                    ls_cmd.append("--")
                    ls_cmd.extend(
                        f":(exclude,top,icase,literal){rel}" for rel in extra_log_rels
                    )
                proc = subprocess.Popen(
                    ls_cmd,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    env=ls_env,
                    start_new_session=True,
                )
                ls_timeout = 10.0
                try:
                    if "DEV_TRIO_GIT_TIMEOUT" in os.environ:
                        ls_timeout = float(os.environ["DEV_TRIO_GIT_TIMEOUT"])
                except ValueError:
                    pass
                if not math.isfinite(ls_timeout) or ls_timeout <= 0:
                    ls_timeout = 10.0
                deadline = time.monotonic() + ls_timeout
                if proc.stdout is not None:
                    os.set_blocking(proc.stdout.fileno(), False)

                paths = []
                capped = False
                timed_out = False
                read_failed = False
                buf = bytearray()

                def consume_chunk(chunk: bytes) -> bool:
                    nonlocal capped, buf
                    buf.extend(chunk)
                    while b"\0" in buf:
                        item, rest = buf.split(b"\0", 1)
                        buf = bytearray(rest)
                        if item:
                            paths.append(os.fsdecode(bytes(item)))
                            if len(paths) >= 5000:
                                capped = True
                                kill_process_tree(proc)
                                return True
                    return False

                try:
                    while True:
                        rem = deadline - time.monotonic()
                        if rem <= 0:
                            timed_out = True
                            kill_process_tree(proc)
                            break
                        if proc.stdout is None:
                            break
                        r, _, _ = select.select([proc.stdout], [], [], min(rem, 0.1))
                        if r:
                            try:
                                chunk = os.read(proc.stdout.fileno(), 65536)
                            except OSError:
                                read_failed = True
                                break
                            if not chunk:
                                break
                            if consume_chunk(chunk):
                                break
                        elif proc.poll() is not None:
                            while True:
                                try:
                                    chunk = os.read(proc.stdout.fileno(), 65536)
                                except OSError:
                                    read_failed = True
                                    break
                                if not chunk:
                                    break
                                if consume_chunk(chunk):
                                    break
                            break
                    if not capped and not timed_out and buf:
                        paths.append(os.fsdecode(bytes(buf)))
                    proc.wait(timeout=0.5)
                except Exception:
                    read_failed = True
                    kill_process_tree(proc)
                    try:
                        proc.wait(timeout=0.5)
                    except Exception:
                        pass
                finally:
                    if proc.stdout is not None:
                        try:
                            proc.stdout.close()
                        except OSError:
                            pass

                # The same classification as run_git; a partial list is never used.
                if timed_out:
                    skip(SKIP_GIT_TIMEOUT)
                if read_failed or (proc.returncode != 0 and not capped):
                    skip(SKIP_GIT_FAILED)
                else:
                    omitted_paths = []
                    if capped:
                        cap_note = b"\n[... untracked file enumeration capped at 5,000 files; remaining untracked files were not scanned ...]\n"
                        out.write(cap_note)
                        remaining = max(0, remaining - len(cap_note))

                    for rel_path in paths:
                        clean_path = rel_path.replace("\r", "\\r").replace("\n", "\\n")
                        if rel_path == ".dev-trio" or rel_path.startswith(".dev-trio/") or any(
                            rel_path.casefold() == rel.casefold()
                            or rel_path.casefold().startswith(rel.casefold() + "/")
                            for rel in extra_log_rels
                        ):
                            continue
                        if remaining <= 0:
                            omitted_paths.append(clean_path)
                            continue

                        if is_sensitive_path(rel_path, custom_log_rels=extra_log_rels):
                            meta = f"### Untracked sensitive file: {clean_path} (omitted)\n".encode(
                                "utf-8", errors="backslashreplace"
                            )
                            if len(meta) <= remaining:
                                out.write(meta)
                                remaining = max(0, remaining - len(meta))
                            else:
                                omitted_paths.append(clean_path)
                            continue

                        parts = Path(rel_path).parts
                        cur_fd = root_fd
                        fds_to_close = []
                        failed_intermediate = False
                        try:
                            for part in parts[:-1]:
                                try:
                                    next_fd = os.open(
                                        part, flags, dir_fd=cur_fd
                                    )
                                    fds_to_close.append(next_fd)
                                    cur_fd = next_fd
                                except OSError:
                                    failed_intermediate = True
                                    try:
                                        link_target = os.readlink(
                                            part, dir_fd=cur_fd
                                        )
                                        clean_target = link_target.replace("\r", "\\r").replace("\n", "\\n")
                                        meta = f"### Untracked intermediate symlink: {clean_path} ({part} -> {clean_target})\n".encode(
                                            "utf-8", errors="backslashreplace"
                                        )
                                    except OSError:
                                        meta = f"### Untracked intermediate directory inaccessible: {clean_path}\n".encode(
                                            "utf-8", errors="backslashreplace"
                                        )
                                    if len(meta) <= remaining:
                                        out.write(meta)
                                        remaining = max(
                                            0, remaining - len(meta)
                                        )
                                    else:
                                        omitted_paths.append(clean_path)
                                    break
                            if failed_intermediate:
                                continue

                            leaf = parts[-1]
                            leaf_fd = None
                            try:
                                leaf_fd = os.open(
                                    leaf,
                                    os.O_RDONLY
                                    | os.O_NOFOLLOW
                                    | os.O_NONBLOCK,
                                    dir_fd=cur_fd,
                                )
                            except OSError:
                                try:
                                    link_target = os.readlink(leaf, dir_fd=cur_fd)
                                    clean_target = link_target.replace("\r", "\\r").replace("\n", "\\n")
                                    meta = f"### Untracked symlink: {clean_path} -> {clean_target}\n".encode(
                                        "utf-8", errors="backslashreplace"
                                    )
                                except OSError:
                                    meta = f"### Untracked file: {clean_path} (inaccessible)\n".encode(
                                        "utf-8", errors="backslashreplace"
                                    )
                                if len(meta) <= remaining:
                                    out.write(meta)
                                    remaining = max(0, remaining - len(meta))
                                else:
                                    omitted_paths.append(clean_path)
                                continue

                            try:
                                try:
                                    st = os.fstat(leaf_fd)
                                    if stat.S_ISDIR(st.st_mode):
                                        meta = f"### Untracked nested repository or directory: {clean_path} (skipped)\n".encode(
                                            "utf-8", errors="backslashreplace"
                                        )
                                        if len(meta) <= remaining:
                                            out.write(meta)
                                            remaining = max(
                                            0, remaining - len(meta)
                                        )
                                        else:
                                            omitted_paths.append(clean_path)
                                        continue
                                    elif not stat.S_ISREG(st.st_mode):
                                        meta = f"### Untracked non-regular file: {clean_path} (skipped)\n".encode(
                                            "utf-8", errors="backslashreplace"
                                        )
                                        if len(meta) <= remaining:
                                            out.write(meta)
                                            remaining = max(
                                                0, remaining - len(meta)
                                            )
                                        else:
                                            omitted_paths.append(clean_path)
                                        continue

                                    header = (
                                        f"### Untracked file: {clean_path}\n".encode(
                                            "utf-8", errors="backslashreplace"
                                        )
                                    )
                                    delimiter = b"\n"
                                    max_content = (
                                        remaining - len(header) - len(delimiter)
                                    )
                                    if max_content < 0:
                                        omitted_paths.append(clean_path)
                                        continue

                                    if st.st_size > max_content:
                                        omitted_paths.append(clean_path)
                                        continue

                                    content = bytearray()
                                    while len(content) <= max_content:
                                        chunk = os.read(
                                            leaf_fd,
                                            min(65536, max_content + 1 - len(content)),
                                        )
                                        if not chunk:
                                            break
                                        content.extend(chunk)

                                    if len(content) > max_content:
                                        omitted_paths.append(clean_path)
                                    else:
                                        is_binary = b"\0" in content
                                        if not is_binary:
                                            try:
                                                content.decode("utf-8")
                                            except UnicodeDecodeError:
                                                is_binary = True

                                        if is_binary:
                                            meta = f"### Untracked binary file: {clean_path} (binary content omitted)\n".encode(
                                                "utf-8", errors="backslashreplace"
                                            )
                                            if len(meta) <= remaining:
                                                out.write(meta)
                                                remaining = max(
                                                    0, remaining - len(meta)
                                                )
                                            else:
                                                omitted_paths.append(clean_path)
                                        else:
                                            chunk_bytes = (
                                                header + bytes(content) + delimiter
                                            )
                                            out.write(chunk_bytes)
                                            remaining = max(
                                                0, remaining - len(chunk_bytes)
                                            )
                                except OSError:
                                    meta = f"### Untracked file: {clean_path} (inaccessible)\n".encode(
                                        "utf-8", errors="backslashreplace"
                                    )
                                    if len(meta) <= remaining:
                                        out.write(meta)
                                        remaining = max(0, remaining - len(meta))
                                    else:
                                        omitted_paths.append(clean_path)
                                    continue
                            finally:
                                if leaf_fd is not None:
                                    os.close(leaf_fd)
                        finally:
                            for fd in reversed(fds_to_close):
                                os.close(fd)

                    if omitted_paths:
                        printed_names = []
                        total_bytes = 0
                        for name in omitted_paths:
                            n_bytes = name.encode("utf-8", errors="backslashreplace")
                            if total_bytes + len(n_bytes) + 2 > 1024:
                                break
                            printed_names.append(name)
                            total_bytes += len(n_bytes) + 2
                        more_count = len(omitted_paths) - len(printed_names)
                        more_suffix = f" ... and {more_count} more" if more_count > 0 else ""
                        names_str = ", ".join(printed_names)
                        notice = f"\n[... snapshot budget reached ({budget_bytes} bytes). Untracked files omitted: {names_str}{more_suffix}. Use your file viewer tool to read omitted untracked files ...]\n".encode(
                            "utf-8", errors="backslashreplace"
                        )
                        out.write(notice)
                        remaining = max(0, remaining - len(notice))
            finally:
                if root_fd is not None:
                    os.close(root_fd)

    sys.stdout.buffer.write(out.getvalue())
    sys.exit(0)


if __name__ == "__main__":
    main()
