#!/usr/bin/env python3
"""Evidence-first evaluation of a local submission. No provider SDK required."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MAX_FILE = 16 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024
MAX_FILES = 4096
MAX_TEXT = 128 * 1024
MAX_OUTPUT = 64 * 1024
EXIT = {"PASS": 0, "FAIL": 1, "HOLD": 2, "ERROR": 3}


class EvalError(Exception):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvalError(message)


def allowed_keys(value: dict[str, Any], allowed: set[str], label: str) -> None:
    extra = set(value) - allowed
    require(not extra, f"unknown {label} field(s): {', '.join(sorted(extra))}")


def relpath(value: str) -> Path:
    require(isinstance(value, str) and value != "", "expected a nonempty relative path")
    posix = PurePosixPath(value)
    require(not posix.is_absolute() and all(p not in (".", "..", "") for p in value.split("/")),
            f"unsafe relative path: {value!r}")
    require("\\" not in value and "\x00" not in value, f"unsafe relative path: {value!r}")
    return Path(*posix.parts)


def read_regular(path: Path, limit: int = MAX_FILE) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode), f"not a regular file: {path}")
        require(info.st_size <= limit, f"file too large: {path}")
        data = os.read(fd, limit + 1)
        require(len(data) <= limit, f"file too large: {path}")
        return data
    finally:
        os.close(fd)


def write_private(path: Path, data: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("xb") as out:
        os.chmod(path, 0o600)
        out.write(data)


def safe_case_file(case_dir: Path, value: str) -> tuple[Path, bytes]:
    relative = relpath(value)
    current = case_dir
    for part in relative.parts[:-1]:
        current /= part
        require(stat.S_ISDIR(current.lstat().st_mode), f"unsafe case path: {value}")
    path = current / relative.parts[-1]
    return path, read_regular(path, MAX_TEXT)


def copy_directory(source: Path, target: Path) -> list[dict[str, Any]]:
    require(stat.S_ISDIR(source.lstat().st_mode), f"not a directory: {source}")
    target.mkdir(mode=0o700, parents=True)
    manifest: list[dict[str, Any]] = []
    total = 0
    for root, dirs, files in os.walk(source, followlinks=False):
        relative_root = Path(root).relative_to(source)
        dirs[:] = sorted(d for d in dirs if not (relative_root == Path(".") and d == ".git"))
        for name in dirs:
            path = Path(root) / name
            require(stat.S_ISDIR(path.lstat().st_mode), f"symlink or special directory: {path}")
            (target / relative_root / name).mkdir(mode=0o700)
        for name in sorted(files):
            src = Path(root) / name
            data = read_regular(src)
            total += len(data)
            require(total <= MAX_TOTAL and len(manifest) < MAX_FILES, "submission size limit exceeded")
            rel = relative_root / name
            dest = target / rel
            write_private(dest, data)
            mode = src.lstat().st_mode
            if mode & stat.S_IXUSR:
                dest.chmod(0o700)
            manifest.append({"path": rel.as_posix(), "sha256": digest(data), "mode": 0o755 if mode & stat.S_IXUSR else 0o644})
    return manifest


def source_fingerprint(sub: dict[str, Any], case_dir: Path) -> str:
    """Detect changes to submitted files or the selected Git object refs."""
    kind = sub.get("kind")
    path = (case_dir / str(sub.get("repo" if kind == "git" else "path", ""))).absolute()
    if kind == "git":
        base = git(path, "rev-parse", "--verify", "--end-of-options", f"{sub.get('base', '')}^{{commit}}").decode().strip()
        head = git(path, "rev-parse", "--verify", "--end-of-options", f"{sub.get('head', '')}^{{commit}}").decode().strip()
        return digest(f"{base}\n{head}\n".encode())
    if kind == "file":
        return digest(read_regular(path))
    require(kind == "directory", "invalid submission kind")
    require(stat.S_ISDIR(path.lstat().st_mode), f"not a directory: {path}")
    manifest = []
    total = 0
    for root, dirs, files in os.walk(path, followlinks=False):
        relative_root = Path(root).relative_to(path)
        dirs[:] = sorted(d for d in dirs if not (relative_root == Path(".") and d == ".git"))
        for name in dirs:
            require(stat.S_ISDIR((Path(root) / name).lstat().st_mode), "source has symlink directory")
        for name in sorted(files):
            src = Path(root) / name
            data = read_regular(src)
            total += len(data)
            require(total <= MAX_TOTAL and len(manifest) < MAX_FILES, "source size limit exceeded")
            manifest.append((str(relative_root / name), digest(data), bool(src.lstat().st_mode & stat.S_IXUSR)))
    return digest(json.dumps(manifest, sort_keys=True).encode())


def git(repo: Path, *args: str) -> bytes:
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": "/nonexistent",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
           "GIT_OPTIONAL_LOCKS": "0", "GIT_LFS_SKIP_SMUDGE": "1", "GIT_NO_REPLACE_OBJECTS": "1"}
    cmd = ["git", "-C", str(repo), "-c", "core.fsmonitor=false", "-c", f"core.hooksPath={os.devnull}",
           "-c", "protocol.allow=never", *args]
    try:
        result = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise EvalError(f"git probe failed: {exc}") from exc
    require(result.returncode == 0, f"git {' '.join(args[:2])} failed: {result.stderr[:300].decode('utf-8', 'replace')}")
    require(len(result.stdout) <= MAX_TOTAL + MAX_FILES * 200, "git output size limit exceeded")
    return result.stdout


def git_tree(repo: Path, sha: str, target: Path) -> list[dict[str, Any]]:
    target.mkdir(mode=0o700)
    manifest: list[dict[str, Any]] = []
    total = 0
    for record in git(repo, "ls-tree", "-rz", "--full-tree", sha).split(b"\x00"):
        if not record:
            continue
        try:
            metadata, raw_name = record.split(b"\t", 1)
            mode, kind, oid = metadata.decode("ascii").split(" ")
            name = raw_name.decode("utf-8", "strict")
        except (ValueError, UnicodeError) as exc:
            raise EvalError("invalid git tree entry") from exc
        require(kind == "blob" and mode in ("100644", "100755"), f"unsupported git entry: {name}")
        relative = relpath(name)
        data = git(repo, "cat-file", "blob", oid)
        total += len(data)
        require(len(data) <= MAX_FILE and total <= MAX_TOTAL and len(manifest) < MAX_FILES,
                "submission size limit exceeded")
        dest = target / relative
        write_private(dest, data)
        if mode == "100755":
            dest.chmod(0o700)
        manifest.append({"path": relative.as_posix(), "sha256": digest(data), "mode": int(mode[-3:], 8)})
    return manifest


def freeze(case: dict[str, Any], case_dir: Path, run_dir: Path) -> dict[str, Any]:
    sub = case.get("submission")
    require(isinstance(sub, dict), "submission must be an object")
    kind = sub.get("kind")
    allowed_keys(sub, {"kind", "repo", "base", "head"} if kind == "git" else {"kind", "path"},
                 "submission")
    info: dict[str, Any] = {"kind": kind}
    frozen = run_dir / "frozen"
    frozen.mkdir(mode=0o700)
    if kind == "git":
        require(all(isinstance(sub.get(key), str) and sub[key] for key in ("repo", "base", "head")),
                "git submission requires repo, base and head strings")
        repo = (case_dir / str(sub.get("repo", ""))).absolute()
        require(repo.is_dir(), "git repo missing")
        base = git(repo, "rev-parse", "--verify", "--end-of-options", f"{sub.get('base', '')}^{{commit}}").decode().strip()
        head = git(repo, "rev-parse", "--verify", "--end-of-options", f"{sub.get('head', '')}^{{commit}}").decode().strip()
        require(git(repo, "merge-base", base, head).decode().strip() == base, "base is not an ancestor of head")
        info.update({"base_sha": base, "head_sha": head})
        for label, sha in (("base", base), ("head", head)):
            info[f"{label}_manifest"] = git_tree(repo, sha, frozen / label)
    elif kind in ("directory", "file"):
        require(isinstance(sub.get("path"), str) and sub["path"], "submission path must be a string")
        source = (case_dir / str(sub.get("path", ""))).absolute()
        if kind == "directory":
            info["head_manifest"] = copy_directory(source, frozen / "head")
        else:
            data = read_regular(source)
            (frozen / "head").mkdir(mode=0o700)
            write_private(frozen / "head" / source.name, data)
            info["head_manifest"] = [{"path": source.name, "sha256": digest(data), "mode": 0o644}]
    else:
        raise EvalError("submission.kind must be git, directory or file")
    info["manifest_sha256"] = digest(json.dumps(info, sort_keys=True).encode())
    return info


def prepare_overlays(case_dir: Path, files: list[Any]) -> list[tuple[Path, Path, bytes]]:
    prepared = []
    for item in files:
        require(isinstance(item, dict), "check file must be an object")
        allowed_keys(item, {"source", "target"}, "check file")
        source, data = safe_case_file(case_dir, item.get("source"))
        prepared.append((source, relpath(item.get("target")), data))
    return prepared


def validate_checks(checks: list[Any], case_dir: Path, run_dir: Path,
                    submission_kind: str) -> list[dict[str, Any]]:
    """Validate every check and its independent inputs before executing any check."""
    validated = []
    ids: set[str] = set()
    for index, check in enumerate(checks):
        require(isinstance(check, dict), "check must be an object")
        allowed_keys(check, {"id", "baseline", "argv", "timeout_seconds", "expected_base", "files"}, "check")
        check_id = check.get("id", f"check-{index + 1}")
        require(isinstance(check_id, str) and check_id, "check.id must be a nonempty string")
        require(check_id not in ids, f"duplicate check.id: {check_id}")
        ids.add(check_id)
        baseline = check.get("baseline", False)
        require(type(baseline) is bool, "check.baseline must be boolean")
        require(not baseline or submission_kind == "git", "baseline check requires git")
        argv = check.get("argv")
        require(isinstance(argv, list) and argv and all(isinstance(x, str) and x for x in argv),
                "check.argv must be a nonempty string array")
        require(sum(len(x.encode()) for x in argv) < MAX_TEXT and all("\x00" not in x for x in argv),
                "check.argv size or NUL invalid")
        timeout = check.get("timeout_seconds", 30)
        require(type(timeout) in (int, float) and 0 < timeout <= 300, "invalid check timeout")
        files = check.get("files", [])
        require(isinstance(files, list), "check.files must be an array")
        prepared = prepare_overlays(case_dir, files)
        targets: set[Path] = set()
        for _, relative, _ in prepared:
            require(relative not in targets, f"duplicate check file target: {relative}")
            require(all(parent not in targets for parent in relative.parents),
                    f"check file target conflicts with another target: {relative}")
            require(not any(relative in target.parents for target in targets),
                    f"check file target conflicts with another target: {relative}")
            targets.add(relative)
            for label in (("base", "head") if baseline else ("head",)):
                frozen = run_dir / "frozen" / label
                target = frozen / relative
                require(not target.exists() and not target.is_symlink(),
                        f"check file would overwrite submission: {target}")
                require(all(not (frozen / parent).is_file() and not (frozen / parent).is_symlink()
                            for parent in relative.parents if parent != Path(".")),
                        f"check file parent conflicts with submission: {target}")
        expected = check.get("expected_base")
        if baseline:
            require(isinstance(expected, dict), "baseline check requires expected_base")
            allowed_keys(expected, {"rc", "stdout_regex", "stderr_regex"}, "expected_base")
            rcs = expected.get("rc")
            require(isinstance(rcs, list) and rcs and all(type(x) is int and x != 0 for x in rcs),
                    "base expected.rc must list nonzero integers")
            for stream in ("stdout", "stderr"):
                pattern = expected.get(f"{stream}_regex")
                if pattern is not None:
                    require(isinstance(pattern, str) and len(pattern) < 1024, "invalid failure regex")
                    try:
                        re.compile(pattern)
                    except re.error as exc:
                        raise EvalError(f"invalid failure regex: {exc}") from exc
        else:
            require("expected_base" not in check, "expected_base requires baseline: true")
        validated.append({"id": check_id, "argv": argv, "baseline": baseline,
                          "timeout": timeout, "expected_base": expected, "prepared": prepared})
    return validated


def overlay(prepared: list[tuple[Path, Path, bytes]], target: Path) -> list[dict[str, str]]:
    entries = []
    for source, relative, data in prepared:
        dest = target / relative
        require(not dest.exists() and not dest.is_symlink(), f"check file would overwrite submission: {dest}")
        write_private(dest, data)
        entries.append({"source": str(source), "target": str(dest.relative_to(target)), "sha256": digest(data)})
    return entries


def run_check(argv: list[str], cwd: Path, scratch: Path, timeout: float, output_cap: int) -> dict[str, Any]:
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(scratch / "home"),
           "TMPDIR": str(scratch / "tmp"), "LANG": "C.UTF-8"}
    Path(env["HOME"]).mkdir(mode=0o700, parents=True, exist_ok=True)
    Path(env["TMPDIR"]).mkdir(mode=0o700, parents=True, exist_ok=True)
    started = time.monotonic()
    try:
        proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError as exc:
        return {"outcome": "spawn-error", "error": str(exc), "env_keys": sorted(env)}
    sel = selectors.DefaultSelector()
    output = {"stdout": bytearray(), "stderr": bytearray()}
    for name, pipe in (("stdout", proc.stdout), ("stderr", proc.stderr)):
        assert pipe is not None
        os.set_blocking(pipe.fileno(), False)
        sel.register(pipe, selectors.EVENT_READ, name)
    outcome = "exit"
    try:
        while sel.get_map():
            remaining = timeout - (time.monotonic() - started)
            if remaining <= 0:
                outcome = "timeout"
                break
            for key, _ in sel.select(min(remaining, 0.2)):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    sel.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                output[key.data].extend(chunk)
                if sum(map(len, output.values())) > output_cap:
                    outcome = "output-limit"
                    break
            if outcome != "exit":
                break
        if outcome != "exit":
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            rc = proc.wait(timeout=5)
        else:
            remaining = timeout - (time.monotonic() - started)
            try:
                rc = proc.wait(timeout=max(0, remaining))
            except subprocess.TimeoutExpired:
                outcome = "timeout"
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                rc = proc.wait(timeout=5)
        # A check can exit after starting a child that closed inherited pipes.
        # It still belongs to this process group and must not outlive the run.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    except KeyboardInterrupt:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        raise
    except (OSError, subprocess.TimeoutExpired):
        outcome = "process-error"
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        rc = proc.returncode
    finally:
        sel.close()
        for pipe in (proc.stdout, proc.stderr):
            if pipe:
                pipe.close()
    return {"outcome": outcome, "rc": rc, "duration_seconds": round(time.monotonic() - started, 3),
            "stdout": bytes(output["stdout"][:output_cap]).decode("utf-8", "replace"),
            "stderr": bytes(output["stderr"][:output_cap]).decode("utf-8", "replace"),
            "stdout_sha256": digest(output["stdout"]), "stderr_sha256": digest(output["stderr"]),
            "env_keys": sorted(env)}


def expected_failure(result: dict[str, Any], expected: dict[str, Any]) -> bool:
    require(result["outcome"] == "exit", "base check did not exit normally")
    rcs = expected.get("rc")
    require(isinstance(rcs, list) and rcs and all(type(x) is int and x != 0 for x in rcs),
            "base expected.rc must list nonzero integers")
    if result["rc"] not in rcs:
        return False
    for stream in ("stdout", "stderr"):
        pattern = expected.get(f"{stream}_regex")
        if pattern is not None:
            require(isinstance(pattern, str) and len(pattern) < 1024, "invalid failure regex")
            try:
                if not re.search(pattern, result[stream]):
                    return False
            except re.error as exc:
                raise EvalError(f"invalid failure regex: {exc}") from exc
    return True


def resolve_reviewer() -> Path:
    override = os.environ.get("DEV_TRIO_BIN")
    if override:
        candidate = Path(override) / "ask-reviewer.sh"
        require(candidate.is_file() and os.access(candidate, os.X_OK), "DEV_TRIO_BIN has no executable ask-reviewer.sh")
        return candidate.absolute()
    sibling = ROOT.parent / "dev-trio/bin/ask-reviewer.sh"
    if sibling.is_file() and os.access(sibling, os.X_OK):
        return sibling
    found = shutil.which("ask-reviewer.sh")
    if found:
        return Path(found)
    claude = shutil.which("claude")
    if claude:
        try:
            result = subprocess.run([claude, "plugin", "list", "--json"], capture_output=True,
                                    timeout=10, check=True, text=True)
            entries = json.loads(result.stdout)
            require(isinstance(entries, list), "plugin list is not an array")
            cwd = Path.cwd().resolve()
            eligible = []
            rank = {"local": 0, "project": 1, "user": 2}
            for item in entries:
                if not isinstance(item, dict) or item.get("id") != "dev-trio@pandas-studio" or item.get("enabled") is not True:
                    continue
                scope = item.get("scope")
                if scope in ("local", "project"):
                    project = item.get("projectPath")
                    if not isinstance(project, str) or Path(project).resolve() != cwd:
                        continue
                install = item.get("installPath")
                if isinstance(install, str):
                    eligible.append((rank.get(scope, 3), install))
            for _, install in sorted(eligible):
                candidate = Path(install) / "bin/ask-reviewer.sh"
                if candidate.is_file() and os.access(candidate, os.X_OK):
                    return candidate
        except (OSError, ValueError, subprocess.SubprocessError, KeyError):
            pass
    raise EvalError("dev-trio ask-reviewer.sh unavailable; set DEV_TRIO_BIN to its bin directory")


def review(wrapper: Path, role: str, model: str, workspace: Path, spec: Path,
           context: Path, run_dir: Path, focus: str) -> dict[str, Any]:
    receipt = run_dir / f"{role}.receipt.json"
    require(not receipt.exists(), "review receipt path already exists")
    log_root = run_dir / "model-logs"
    log_root.mkdir(mode=0o700, exist_ok=True)
    env = os.environ.copy()
    env.update({"DEV_TRIO_REVIEW_RECEIPT": str(receipt), "DEV_TRIO_LOG_DIR": str(log_root),
                "DEV_TRIO_REVIEWER_MODEL": model, "DEV_TRIO_PM_HOST": os.environ.get("DEV_TRIO_PM_HOST", "claude"),
                "DEV_TRIO_SNAPSHOT_MAX_BYTES": "0",
                "GIT_CEILING_DIRECTORIES": str(run_dir.parent)})
    if role == "challenger":
        env["REVIEWER_ROLE_FILE"] = str(ROOT / "lib/challenger.md")
    else:
        env.pop("REVIEWER_ROLE_FILE", None)
    cmd = [str(wrapper), "--with-spec", str(spec), "--with-context", str(context), focus]
    try:
        proc = subprocess.Popen(cmd, cwd=workspace, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
        try:
            rc = proc.wait(timeout=600)
        except (KeyboardInterrupt, subprocess.TimeoutExpired):
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            raise
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise EvalError(f"{role} invocation failed: {exc}") from exc
    require(receipt.is_file(), f"{role} receipt missing (rc={rc})")
    pointers = json.loads(read_regular(receipt, MAX_TEXT))
    require(isinstance(pointers, dict), f"{role} receipt must be an object")
    require(pointers.get("schema_version") == 1, f"{role} receipt schema invalid")
    require(isinstance(pointers.get("result_path"), str), f"{role} result path missing")
    result_path = Path(pointers["result_path"])
    require(result_path.is_file() and result_path.is_relative_to(log_root), f"{role} result path outside run")
    raw = read_regular(result_path, MAX_TEXT)
    result = json.loads(raw)
    require(isinstance(result, dict), f"{role} result must be an object")
    require(result.get("schema_version") == 1 and result.get("exit_code") == rc,
            f"{role} receipt/result mismatch")
    return {"model": model, "wrapper_rc": rc, "result_path": str(result_path),
            "result_sha256": digest(raw), "result": result}


def model_status(result: dict[str, Any], role: str) -> tuple[str, str]:
    data = result["result"]
    require(data.get("status") == "ok" and result["wrapper_rc"] == 0,
            f"{role} review unavailable: {data.get('status')}")
    verdict = data.get("verdict")
    require(verdict in ("SHIP", "NEEDS-FIX", "DISCUSS"), f"{role} verdict invalid")
    findings = data.get("findings")
    require(isinstance(findings, dict), f"{role} findings invalid")
    for severity in ("blocker", "major", "minor"):
        require(isinstance(findings.get(severity), list), f"{role} {severity} findings missing")
    if role == "challenger":
        if verdict != "SHIP" or any(findings[x] for x in ("blocker", "major", "minor")):
            return "HOLD", "open_counterexample"
        return "PASS", "no_counterexamples"
    if verdict == "NEEDS-FIX" or findings.get("blocker") or findings.get("major"):
        return "FAIL", "judge_needs_fix"
    if verdict == "DISCUSS" or findings.get("minor"):
        return "HOLD", "judge_discuss"
    return "PASS", "judge_ship"


def verify_evidence(report: dict[str, Any], evidence: Path, case_dir: Path) -> None:
    expected = report["evidence"]
    require(digest(read_regular(evidence / "spec.md", MAX_TEXT)) == expected["spec_sha256"],
            "review changed frozen spec")
    require(digest(read_regular(evidence / "checks.json", MAX_TEXT)) == expected["checks_sha256"],
            "review changed frozen check evidence")
    require(source_fingerprint({"kind": "directory", "path": str(evidence / "submission")}, case_dir)
            == expected["submission_manifest_sha256"], "review changed frozen submission")
    require(source_fingerprint({"kind": "directory", "path": str(evidence / "checks")}, case_dir)
            == expected["check_files_manifest_sha256"], "review changed frozen check files")
    if "base_manifest_sha256" in expected:
        require(source_fingerprint({"kind": "directory", "path": str(evidence / "base")}, case_dir)
                == expected["base_manifest_sha256"], "review changed frozen base")
    if "challenger_sha256" in expected:
        require(digest(read_regular(evidence / "challenger.json", MAX_TEXT)) == expected["challenger_sha256"],
                "review changed frozen Challenger evidence")


def atomic_bytes(path: Path, payload: bytes) -> None:
    fd, temp = tempfile.mkstemp(prefix=".report-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as out:
            out.write(payload)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def atomic_json(path: Path, data: dict[str, Any]) -> None:
    atomic_bytes(path, (json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode())


def evaluate(args: argparse.Namespace, report: dict[str, Any], case: dict[str, Any], raw_case: bytes) -> None:
    case_path = Path(args.case).absolute()
    case_dir = case_path.parent
    require(isinstance(case, dict) and type(case.get("schema_version")) is int and
            case["schema_version"] == 1, "case schema_version must be 1")
    allowed_keys(case, {"schema_version", "preset", "task", "criteria", "submission", "checks"}, "case")
    require(case.get("preset") in ("generic", "bug-fix"), "preset must be generic or bug-fix")
    task_path, task = safe_case_file(case_dir, case.get("task"))
    criteria_path, criteria = safe_case_file(case_dir, case.get("criteria"))
    report["inputs"] = {"case_sha256": digest(raw_case), "task_sha256": digest(task),
                        "criteria_sha256": digest(criteria), "task_path": str(task_path),
                        "criteria_path": str(criteria_path)}
    require(isinstance(case.get("submission"), dict), "submission must be an object")
    report["inputs"]["source_sha256_before"] = source_fingerprint(case["submission"], case_dir)
    report["submission"] = freeze(case, case_dir, args.output_dir)
    require(source_fingerprint(case["submission"], case_dir) == report["inputs"]["source_sha256_before"],
            "submitted source changed during freezing")
    checks = case.get("checks", [])
    require(isinstance(checks, list), "checks must be an array")
    require(len(checks) <= 32, "too many checks")
    report["mode"] = "checks-only" if args.checks_only else ("full" if checks else "review-only")
    if checks:
        require(args.allow_execution, "checks execute submitted code; pass --allow-execution")
    elif not args.checks_only:
        require(args.allow_execution, "model tools may execute submitted code; pass --allow-execution")
    elif args.checks_only:
        raise EvalError("checks-only requires at least one check")
    validated = validate_checks(checks, case_dir, args.output_dir, report["submission"]["kind"])
    if case["preset"] == "bug-fix":
        require(report["submission"]["kind"] == "git", "bug-fix preset requires a git submission")
        require(any(c["baseline"] for c in validated),
                "bug-fix preset requires a baseline check")
    for index, check in enumerate(validated):
        check_id = check["id"]
        baseline = check["baseline"]
        argv = check["argv"]
        timeout = check["timeout"]
        prepared = check["prepared"]
        labels = ("base", "head") if baseline else ("head",)
        entry: dict[str, Any] = {"id": check_id, "argv": argv, "baseline": baseline,
                                 "runs": {}}
        report["checks"].append(entry)
        for label in labels:
            work = args.output_dir / "check-work" / f"{index:02d}-{label}"
            manifest = copy_directory(args.output_dir / "frozen" / label, work)
            overlays = overlay(prepared, work)
            outcome = run_check(argv, work, args.output_dir / "check-work" / f"{index:02d}-{label}-scratch",
                                timeout, MAX_OUTPUT)
            entry["runs"][label] = {**outcome, "overlay": overlays,
                                     "workspace_manifest_sha256": digest(json.dumps(manifest, sort_keys=True).encode())}
            if outcome["outcome"] != "exit" or outcome["rc"] < 0:
                raise EvalError(f"check {check_id} {label}: {outcome['outcome']} rc={outcome.get('rc')}")
            if label == "head" and outcome["rc"] != 0:
                report.update(status="FAIL", reason=f"head_check_failed:{check_id}")
            if label == "base":
                if not expected_failure(outcome, check["expected_base"]):
                    report.update(status="FAIL", reason=f"base_signal_mismatch:{check_id}")
    if report["status"] == "FAIL":
        return
    if args.checks_only:
        report.update(status="HOLD", reason="review_skipped")
        return
    wrapper = resolve_reviewer()
    challenger_model = os.environ.get("EVAL_TRIO_CHALLENGER_MODEL", "agy")
    judge_model = os.environ.get("EVAL_TRIO_JUDGE_MODEL", "claude" if os.environ.get("DEV_TRIO_PM_HOST", "claude") == "codex" else "codex")
    require(challenger_model != judge_model, "Challenger and Judge models must differ")
    evidence = args.output_dir / "evidence"
    evidence.mkdir(mode=0o700)
    copy_directory(args.output_dir / "frozen" / "head", evidence / "submission")
    check_files = evidence / "checks"
    check_files.mkdir(mode=0o700)
    for index, check in enumerate(validated):
        copied = []
        for _, relative, data in check["prepared"]:
            evidence_path = Path("checks") / f"{index:02d}" / relative
            write_private(evidence / evidence_path, data)
            copied.append({"path": evidence_path.as_posix(), "target": relative.as_posix(),
                           "sha256": digest(data)})
        report["checks"][index]["evidence_files"] = copied
    if report["submission"]["kind"] == "git":
        copy_directory(args.output_dir / "frozen" / "base", evidence / "base")
    spec = evidence / "spec.md"
    write_private(spec, b"# Task\n" + task + b"\n# Criteria\n" + criteria)
    require(spec.stat().st_size <= MAX_TEXT, "task and criteria exceed model input limit")
    context = evidence / "checks.json"
    write_private(context, json.dumps(report["checks"], indent=2, ensure_ascii=False).encode())
    require(context.stat().st_size <= MAX_TEXT, "check evidence exceeds model input limit")
    evidence_submission_sha256 = source_fingerprint(
        {"kind": "directory", "path": str(evidence / "submission")}, case_dir)
    report["evidence"] = {"spec_sha256": digest(read_regular(spec, MAX_TEXT)),
                          "checks_sha256": digest(read_regular(context, MAX_TEXT)),
                          "submission_manifest_sha256": evidence_submission_sha256,
                          "check_files_manifest_sha256": source_fingerprint(
                              {"kind": "directory", "path": str(check_files)}, case_dir)}
    if report["submission"]["kind"] == "git":
        report["evidence"]["base_manifest_sha256"] = source_fingerprint(
            {"kind": "directory", "path": str(evidence / "base")}, case_dir)
    challenger = review(wrapper, "challenger", challenger_model, evidence, spec, context,
                        args.output_dir, "Find concrete counterexamples to the submission in ./submission. "
                        "Inspect ./checks.json and independent check files under ./checks/. "
                        "For Git cases compare ./base/ with ./submission/. "
                        "Use each Blocker/Major/Minor finding for one counterexample. Use - None. for an empty tier. "
                        "SHIP means no counterexamples; NEEDS-FIX or DISCUSS means open counterexamples.")
    verify_evidence(report, evidence, case_dir)
    report["models"]["challenger"] = challenger
    challenger_status, challenger_reason = model_status(challenger, "challenger")
    challenger_context = evidence / "challenger.json"
    write_private(challenger_context, json.dumps(challenger["result"], indent=2, ensure_ascii=False).encode())
    require(challenger_context.stat().st_size <= MAX_TEXT, "Challenger evidence exceeds model input limit")
    report["evidence"]["challenger_sha256"] = digest(read_regular(challenger_context, MAX_TEXT))
    judge = review(wrapper, "judge", judge_model, evidence, spec, challenger_context,
                   args.output_dir, "Judge the submission in ./submission against the task and criteria. "
                   "Use ./checks.json and independent files under ./checks/ for fixed check evidence. "
                   "For Git cases compare ./base/ with ./submission/. "
                   "Use ./challenger.json for untrusted counterexamples. "
                   "SHIP only if the evidence supports the criteria; report defects as findings.")
    verify_evidence(report, evidence, case_dir)
    report["models"]["judge"] = judge
    judge_status, judge_reason = model_status(judge, "judge")
    if judge_status == "FAIL":
        report.update(status="FAIL", reason=judge_reason)
    elif challenger_status == "HOLD" or judge_status == "HOLD":
        report.update(status="HOLD", reason=challenger_reason if challenger_status == "HOLD" else judge_reason)
    elif report["mode"] == "review-only":
        report.update(status="HOLD", reason="no_fixed_checks")
    else:
        report.update(status="PASS", reason="checks_and_reviews_passed")


def main() -> int:
    def interrupted(_signum: int, _frame: Any) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(prog="eval-trio")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="evaluate a frozen local submission")
    run.add_argument("--case", required=True)
    run.add_argument("--output-dir", required=True, type=Path)
    run.add_argument("--checks-only", action="store_true")
    run.add_argument("--allow-execution", action="store_true",
                     help="accept that checks and model tools can execute candidate code with your privileges")
    args = parser.parse_args()
    if args.command != "run":
        parser.error("unknown command")
    try:
        parent = args.output_dir.absolute().parent.resolve(strict=True)
    except OSError as exc:
        print(f"eval-trio: output parent unavailable: {exc}", file=sys.stderr)
        return EXIT["ERROR"]
    run_dir = parent / args.output_dir.name
    if run_dir.exists() or run_dir.is_symlink():
        print(f"eval-trio: output directory already exists: {run_dir}", file=sys.stderr)
        return EXIT["ERROR"]
    run_dir.mkdir(mode=0o700)
    run_dir.chmod(0o700)
    args.output_dir = run_dir
    report: dict[str, Any] = {"schema_version": 1, "complete": False, "mode": None,
                              "status": "ERROR", "reason": "not_started", "inputs": {},
                              "submission": {}, "checks": [], "models": {}, "evidence": {},
                              "output_dir": str(run_dir)}
    case_dir = Path(args.case).absolute().parent
    sub = None
    try:
        raw_case = read_regular(Path(args.case).absolute(), MAX_TEXT)
        case = json.loads(raw_case)
        if isinstance(case, dict) and isinstance(case.get("submission"), dict):
            sub = case["submission"]
        evaluate(args, report, case, raw_case)
    except (EvalError, OSError, ValueError, KeyError, TypeError) as exc:
        report.update(status="ERROR", reason=str(exc))
    except KeyboardInterrupt:
        report.update(status="ERROR", reason="interrupted")
    except Exception as exc:
        report.update(status="ERROR", reason=f"unexpected {type(exc).__name__}: {exc}")
    if sub is not None and "source_sha256_before" in report["inputs"]:
        try:
            after = source_fingerprint(sub, case_dir)
            report["inputs"]["source_sha256_after"] = after
            if after != report["inputs"]["source_sha256_before"]:
                report.update(status="ERROR", reason="submitted source changed during evaluation")
        except Exception as exc:
            report.update(status="ERROR", reason=f"source recheck failed: {exc}")
    if "case_sha256" in report["inputs"]:
        try:
            require(digest(read_regular(Path(args.case).absolute(), MAX_TEXT)) == report["inputs"]["case_sha256"],
                    "case changed during evaluation")
            for label in ("task", "criteria"):
                path = Path(report["inputs"][f"{label}_path"])
                require(digest(read_regular(path, MAX_TEXT)) == report["inputs"][f"{label}_sha256"],
                        f"{label} changed during evaluation")
        except Exception as exc:
            report.update(status="ERROR", reason=str(exc))
    report["complete"] = True
    report["exit_code"] = EXIT[report["status"]]
    markdown = f"# Eval Trio result\n\nStatus: **{report['status']}** ({report['mode']})\n\nReason: {report['reason']}\n\nSee report.json for authoritative evidence.\n"
    atomic_bytes(run_dir / "report.md", markdown.encode())
    atomic_json(run_dir / "report.json", report)
    print(f"{report['status']} — {report['reason']} ({run_dir / 'report.json'})")
    return report["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
