#!/usr/bin/env python3
"""Find filter-module instances with resource-bounded Verdi batches."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple


SCRIPT_DIR = Path(__file__).resolve().parent
RUN_CWD = Path.cwd()


def log_step(message: str) -> None:
    print(f"[find_instances_batched] {message}", file=sys.stderr)


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


def write_instances(path: Path, instances: Sequence[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as f:
        for inst in instances:
            f.write(inst)
            f.write("\n")


def write_errors(path: Path, errors: Sequence[str]) -> None:
    if not errors:
        return
    error_path = path.with_name(f"{path.stem}_errors.log")
    with error_path.open("w", encoding="utf-8", newline="\n") as f:
        for item in errors:
            f.write(item)
            f.write("\n")
    log_step(f"error_log={error_path}")


def run_verdi_find(args, modules: Sequence[str], batch_id: str, outfile: Path) -> List[str]:
    env = os.environ.copy()
    modules_text = ",".join(modules)
    env["NPI_LIB"] = str(args.lib)
    env["NPI_FILTER_MODULE"] = modules_text
    env["NPI_FILTER_MODULES"] = modules_text
    env["NPI_INSTANCE_OUTFILE"] = str(outfile)
    env["NPI_FIND_LOG_INSTANCES"] = "1" if args.log_instances else "0"

    cmd = ["verdi", "-batch", "-nologo", "-play", str(SCRIPT_DIR / "npi_find_instances.tcl")]
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
        env=env,
        stdout=sys.stderr,
        stderr=sys.stderr,
    )
    rc = proc.wait()
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
        instances = run_verdi_find(args, modules, batch_id, batch_file)
        return instances, []
    except subprocess.CalledProcessError as exc:
        log_step(
            "batch={} failed rc={} module_count={}".format(
                batch_id,
                exc.returncode,
                len(modules),
            )
        )
        if len(modules) > 1:
            mid = max(1, len(modules) // 2)
            left_instances, left_errors = run_batch_with_retry(args, modules[:mid], f"{batch_id}a")
            right_instances, right_errors = run_batch_with_retry(args, modules[mid:], f"{batch_id}b")
            return left_instances + right_instances, left_errors + right_errors

        message = "module={} failed during instance search rc={}".format(
            modules[0],
            exc.returncode,
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
        description="Find instances for many -keywords modules using smaller Verdi batches."
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
    args = parser.parse_args()

    modules = split_csv_arg(args.keywords)
    if not modules:
        parser.error("-keywords expects one or more module definition names.")
    if args.batch_size < 0:
        parser.error("--batch-size must be 0 or a positive integer.")

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
    log_step(f"output={args.output}")

    seen: Dict[str, None] = {}
    errors: List[str] = []
    batches = list(split_batches(args.modules, args.batch_size))
    for idx, batch in enumerate(batches, start=1):
        instances, batch_errors = run_batch_with_retry(args, batch, str(idx))
        errors.extend(batch_errors)
        for inst in instances:
            seen.setdefault(inst, None)

    merged = list(seen.keys())
    write_instances(args.output, merged)
    write_errors(args.output, errors)
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
