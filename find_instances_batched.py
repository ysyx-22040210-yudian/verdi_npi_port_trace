#!/usr/bin/env python3
"""Find filter-module instances through resource-bounded kdebug batches."""

from __future__ import annotations

import argparse
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


SCRIPT_DIR = Path(__file__).resolve().parent
RUN_CWD = Path.cwd()
VERDI_KILL_AFTER_SEC = 5


def log_step(message: str) -> None:
    print(f"[find_instances_batched] {message}", file=sys.stderr)


def timeout_with_cleanup_grace(timeout_sec: Optional[float]) -> Optional[float]:
    if timeout_sec is None or timeout_sec <= 0:
        return None
    try:
        grace = max(
            0.0, float(os.environ.get("KDEBUG_COMMAND_CLEANUP_GRACE_SEC", "15"))
        )
    except ValueError:
        grace = 15.0
        log_step("invalid KDEBUG_COMMAND_CLEANUP_GRACE_SEC; using 15s")
    return timeout_sec + grace


def split_csv_arg(text: str) -> List[str]:
    return [item.strip() for item in text.split(",") if item.strip()] if text else []


def safe_name(text: str) -> str:
    text = re.sub(r"[^A-Za-z0-9_.-]+", "_", text)
    return text.strip("._") or "unnamed"


def read_instances(path: Path) -> List[str]:
    if not path.exists():
        return []
    instances: List[str] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            text = line.strip().lstrip("\ufeff")
            if text:
                instances.append(text)
    return instances


def write_instances(
    path: Path,
    instances: Sequence[str],
    output_mode: Optional[int] = None,
) -> None:
    atomic_write_lines(path, instances, output_mode=output_mode)


def atomic_write_lines(
    path: Path,
    lines: Sequence[str],
    output_mode: Optional[int] = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if output_mode is None:
        try:
            output_mode = stat.S_IMODE(path.stat().st_mode)
        except FileNotFoundError:
            current_umask = os.umask(0)
            os.umask(current_umask)
            output_mode = 0o666 & ~current_umask
    fd, temp_name = tempfile.mkstemp(
        dir=str(path.parent),
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            fd = -1
            for line in lines:
                f.write(line)
                f.write("\n")
        temp_path.chmod(output_mode)
        os.replace(str(temp_path), str(path))
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


def remove_stale_result_files(path: Path) -> None:
    error_path = path.with_name(f"{path.stem}_errors.log")
    for stale_path in (path, error_path):
        try:
            stale_path.unlink()
            log_step(f"removed_stale_output={stale_path}")
        except FileNotFoundError:
            pass


def existing_file_mode(path: Path) -> Optional[int]:
    try:
        return stat.S_IMODE(path.stat().st_mode)
    except FileNotFoundError:
        return None


def write_errors(
    path: Path,
    errors: Sequence[str],
    output_mode: Optional[int] = None,
) -> None:
    error_path = path.with_name(f"{path.stem}_errors.log")
    if not errors:
        try:
            error_path.unlink()
            log_step(f"removed_stale_error_log={error_path}")
        except FileNotFoundError:
            pass
        return
    atomic_write_lines(error_path, errors, output_mode=output_mode)
    log_step(f"error_log={error_path}")


def posix_session_processes(session_id: int) -> List[int]:
    result = subprocess.run(
        ["ps", "-e", "-o", "pid=", "-o", "sid=", "-o", "stat="],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"could not enumerate Verdi session {session_id}: {result.stderr.strip()}"
        )

    processes: List[int] = []
    for line in result.stdout.splitlines():
        fields = line.split(None, 2)
        if len(fields) != 3:
            continue
        pid_text, sid_text, state = fields
        if sid_text == str(session_id) and not state.startswith("Z"):
            try:
                processes.append(int(pid_text))
            except ValueError:
                continue
    return processes


def signal_posix_session(session_id: int, sig: signal.Signals) -> List[int]:
    try:
        os.killpg(session_id, sig)
    except ProcessLookupError:
        pass

    processes = posix_session_processes(session_id)
    for pid in processes:
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass
    return processes


def terminate_posix_process_session(proc: subprocess.Popen, reason: str) -> None:
    log_step(
        "{}: sending TERM to Verdi session={} kill_after={}s".format(
            reason,
            proc.pid,
            VERDI_KILL_AFTER_SEC,
        )
    )
    session_id = proc.pid
    signal_posix_session(session_id, signal.SIGTERM)
    deadline = time.monotonic() + VERDI_KILL_AFTER_SEC
    while time.monotonic() < deadline:
        proc.poll()
        if not posix_session_processes(session_id):
            return
        time.sleep(0.05)

    remaining = posix_session_processes(session_id)
    if remaining:
        log_step(
            "{}: sending KILL to Verdi session={} remaining_pids={}".format(
                reason,
                session_id,
                ",".join(str(pid) for pid in remaining),
            )
        )

    kill_deadline = time.monotonic() + 2
    while remaining and time.monotonic() < kill_deadline:
        signal_posix_session(session_id, signal.SIGKILL)
        proc.poll()
        time.sleep(0.05)
        remaining = posix_session_processes(session_id)

    proc.poll()
    if remaining:
        raise RuntimeError(
            "could not kill all processes in Verdi session {}: {}".format(
                session_id,
                ",".join(str(pid) for pid in remaining),
            )
        )


def terminate_timed_out_process(proc: subprocess.Popen) -> None:
    if os.name == "posix":
        terminate_posix_process_session(proc, "timeout")
        return

    log_step(
        "timeout: sending TERM to Verdi pid={} kill_after={}s".format(
            proc.pid,
            VERDI_KILL_AFTER_SEC,
        )
    )
    try:
        proc.terminate()
        proc.wait(timeout=VERDI_KILL_AFTER_SEC)
    except subprocess.TimeoutExpired:
        log_step(f"timeout: sending KILL to Verdi pid={proc.pid}")
        proc.kill()
        proc.wait()


def cleanup_completed_process_session(proc: subprocess.Popen) -> None:
    if os.name != "posix":
        return
    remaining = posix_session_processes(proc.pid)
    if not remaining:
        return
    log_step(
        "post-exit: Verdi leader exited with live session processes={}".format(
            ",".join(str(pid) for pid in remaining)
        )
    )
    terminate_posix_process_session(proc, "post-exit")


def run_kdebug_find(args, modules: Sequence[str], batch_id: str, outfile: Path) -> List[str]:
    modules_text = ",".join(modules)
    cmd = [
        sys.executable,
        str(SCRIPT_DIR / "kdebug_backend.py"),
        "find-instances",
        "--lib",
        str(args.lib),
        "--definitions",
        modules_text,
        "--output",
        str(outfile),
    ]
    kdebug_bin = getattr(args, "kdebug_bin", "")
    if kdebug_bin:
        cmd.extend(["--kdebug-bin", kdebug_bin])
    if args.log_instances:
        cmd.append("--debug")
    if args.verdi_timeout_sec > 0:
        cmd.extend(["--timeout-sec", str(args.verdi_timeout_sec)])
    log_step(
        "batch={} module_count={} modules={} outfile={}".format(
            batch_id,
            len(modules),
            modules_text,
            outfile,
        )
    )
    log_step("command: {}".format(" ".join(cmd)))

    with outfile.open("w", encoding="utf-8"):
        pass
    proc = subprocess.Popen(
        cmd,
        cwd=str(RUN_CWD),
        stdout=sys.stderr,
        stderr=sys.stderr,
        start_new_session=(os.name == "posix" and args.verdi_timeout_sec > 0),
    )
    try:
        command_timeout = timeout_with_cleanup_grace(args.verdi_timeout_sec)
        if command_timeout is not None:
            rc = proc.wait(timeout=command_timeout)
        else:
            rc = proc.wait()
    except subprocess.TimeoutExpired as exc:
        terminate_timed_out_process(proc)
        raise subprocess.TimeoutExpired(cmd, args.verdi_timeout_sec) from exc
    if args.verdi_timeout_sec > 0 and os.name == "posix":
        cleanup_completed_process_session(proc)
    if rc != 0:
        raise subprocess.CalledProcessError(rc, cmd)

    instances = read_instances(outfile)
    log_step(f"batch={batch_id} instances={len(instances)}")
    return instances


def split_batches(items: Sequence[str], batch_size: int) -> Iterable[List[str]]:
    if batch_size <= 0:
        yield list(items)
        return
    for idx in range(0, len(items), batch_size):
        yield list(items[idx : idx + batch_size])


def run_batch_with_retry(args, modules: Sequence[str], batch_id: str) -> Tuple[List[str], List[str]]:
    batch_file = args.output.with_name(
        f"{args.output.stem}__batch_{safe_name(batch_id)}{args.output.suffix}"
    )
    try:
        instances = run_kdebug_find(args, modules, batch_id, batch_file)
        return instances, []
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        if isinstance(exc, subprocess.TimeoutExpired):
            failure = f"timeout={args.verdi_timeout_sec}s"
        else:
            failure = f"rc={exc.returncode}"
        log_step(f"batch={batch_id} failed {failure} module_count={len(modules)}")
        if len(modules) > 1:
            mid = max(1, len(modules) // 2)
            left_instances, left_errors = run_batch_with_retry(args, modules[:mid], f"{batch_id}a")
            right_instances, right_errors = run_batch_with_retry(args, modules[mid:], f"{batch_id}b")
            return left_instances + right_instances, left_errors + right_errors

        message = "module={} failed during instance search {}".format(
            modules[0],
            failure,
        )
        if args.continue_on_error:
            log_step(f"continue_after_error {message}")
            return [], [message]
        raise RuntimeError(message) from exc
    finally:
        if not args.keep_batch_files and batch_file.exists():
            try:
                batch_file.unlink()
            except OSError as exc:
                log_step(f"warning: could not remove batch file {batch_file}: {exc}")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Find instances for many -keywords modules through public kdebug JSON actions."
    )
    parser.add_argument("-lib", required=True, help="KDB path, for example kdb.elab++")
    parser.add_argument("-keywords", required=True, help="comma-separated filter module names")
    parser.add_argument("-output", required=True, help="merged instance output file")
    parser.add_argument(
        "--batch-size",
        type=int,
        default=8,
        help="keyword modules per Verdi process; 0 means one process for all modules",
    )
    parser.add_argument(
        "--continue-on-error",
        action="store_true",
        help="skip a keyword module if it still fails after retrying as a single-module batch",
    )
    parser.add_argument(
        "--log-instances",
        action="store_true",
        help="print every resolved instance path from Tcl; disabled by default for large projects",
    )
    parser.add_argument(
        "--keep-batch-files",
        action="store_true",
        help="keep per-batch instance files for debugging",
    )
    parser.add_argument(
        "--verdi-timeout-sec",
        type=int,
        default=0,
        help="wall-clock limit for each Verdi process; 0 disables the timeout",
    )
    parser.add_argument(
        "--kdebug-bin",
        default=os.environ.get("KDEBUG_BIN", ""),
        help="kdebug executable; defaults to KDEBUG_BIN/KVERIF_HOME/PATH discovery",
    )
    args = parser.parse_args()

    modules = split_csv_arg(args.keywords)
    if not modules:
        parser.error("-keywords expects one or more module definition names.")
    if args.batch_size < 0:
        parser.error("--batch-size must be 0 or a positive integer.")
    if args.verdi_timeout_sec < 0:
        parser.error("--verdi-timeout-sec must be 0 or a positive integer.")

    lib = Path(args.lib).expanduser()
    if not lib.is_absolute():
        lib = RUN_CWD / lib
    lib = lib.resolve()
    if not lib.exists():
        parser.error(f"KDB not found: {lib}")
    args.lib = lib
    args.modules = modules
    args.output = Path(args.output).expanduser()
    if not args.output.is_absolute():
        args.output = RUN_CWD / args.output
    args.output = args.output.resolve()
    return args


def main() -> int:
    args = parse_args()
    log_step(f"run_cwd={RUN_CWD}")
    log_step(f"lib={args.lib}")
    log_step(f"keyword_count={len(args.modules)}")
    log_step(f"batch_size={args.batch_size}")
    log_step(f"continue_on_error={args.continue_on_error}")
    log_step(f"log_instances={args.log_instances}")
    log_step(f"verdi_timeout_sec={args.verdi_timeout_sec}")
    log_step(f"kdebug_bin={args.kdebug_bin or '<auto>'}")
    log_step(f"output={args.output}")
    output_mode = existing_file_mode(args.output)
    error_output = args.output.with_name(f"{args.output.stem}_errors.log")
    error_output_mode = existing_file_mode(error_output)
    remove_stale_result_files(args.output)

    seen: Dict[str, None] = {}
    errors: List[str] = []
    batches = list(split_batches(args.modules, args.batch_size))
    for idx, batch in enumerate(batches, start=1):
        instances, batch_errors = run_batch_with_retry(args, batch, str(idx))
        errors.extend(batch_errors)
        for inst in instances:
            seen.setdefault(inst, None)

    merged = list(seen.keys())
    write_instances(args.output, merged, output_mode=output_mode)
    write_errors(args.output, errors, output_mode=error_output_mode)
    log_step(
        "done batches={} keyword_count={} merged_instances={} errors={}".format(
            len(batches),
            len(args.modules),
            len(merged),
            len(errors),
        )
    )
    if not merged:
        raise RuntimeError(f"no instances found for filter modules: {args.keywords}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        log_step(f"ERROR: {exc}")
        raise SystemExit(1)
