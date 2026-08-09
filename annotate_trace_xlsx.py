#!/usr/bin/env python3
"""
Annotate an XLSX trace template with NPI yes/no connectivity results.

Template layout:
  - column A, row 2..N: target module definition names
  - column B: reserved for output instance paths
  - column C: reserved for output parameter summaries
  - row 1, column D..N: target port names
  - old templates with ports starting from column C are still accepted

Output layout:
  - column A: target module definition name
  - column B, row 2..N: concrete target instance paths
  - column C: elaborated parameters for the instance on the same row
  - row 1, column D..N: target port names

Each instance/port intersection is filled with:
  - yes: the direction-relevant endpoint belongs to an instance of -keywords
         (input uses driver, output uses load, inout/unknown uses both)
         or -regcombo-as-keyword is 1 and that endpoint is a RegCombo node
  - no: no such endpoint is found
  - markers such as driver=Const:'b1, driver=NO_DRIVER, load=NO_LOAD, NO_TRACE

This version targets Python 3.8+ and uses openpyxl for robust XLSX editing.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import stat
import subprocess
import sys
import tempfile
from copy import copy
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

from find_instances_batched import (
    cleanup_completed_process_session,
    terminate_timed_out_process,
    timeout_with_cleanup_grace,
)
from runtime_paths import (
    bounded_derived_path,
    bounded_path,
    derived_glob_prefixes,
    fixed_temp_prefix,
    sanitize_component,
)

try:
    import openpyxl
except ImportError as exc:
    print(
        "[annotate_trace_xlsx] ERROR: openpyxl is required for Python 3.8 XLSX mode.\n"
        "[annotate_trace_xlsx] Install it on the VM with:\n"
        "[annotate_trace_xlsx]   python3 -m pip install openpyxl",
        file=sys.stderr,
    )
    raise SystemExit(1) from exc


SCRIPT_DIR = Path(__file__).resolve().parent
RUN_CWD = Path.cwd()

MODULE_COL = 1
INSTANCE_COL = 2
PARAMETER_COL = 3
PORT_START_COL = 4


class TeeStream:
    def __init__(self, *streams):
        self.streams = streams

    def write(self, data: str) -> int:
        for stream in self.streams:
            stream.write(data)
        return len(data)

    def flush(self) -> None:
        for stream in self.streams:
            stream.flush()


def path_has_contents(path: Path) -> bool:
    if path.is_file():
        return path.stat().st_size > 0
    if path.is_dir():
        return any(path.iterdir())
    return False


def current_umask_file_mode() -> int:
    current_umask = os.umask(0)
    os.umask(current_umask)
    return 0o666 & ~current_umask


def atomic_save_workbook(
    workbook,
    output: Path,
    output_mode: Optional[int] = None,
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if output_mode is None:
        try:
            output_mode = stat.S_IMODE(output.stat().st_mode)
        except FileNotFoundError:
            output_mode = current_umask_file_mode()
    fd, temp_name = tempfile.mkstemp(
        dir=str(output.parent),
        prefix=fixed_temp_prefix("xlsx"),
        suffix=f".tmp{output.suffix}",
    )
    os.close(fd)
    temp_path = Path(temp_name)
    try:
        workbook.save(temp_path)
        temp_path.chmod(output_mode)
        os.replace(str(temp_path), str(output))
    finally:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


@dataclass(frozen=True)
class TraceRow:
    inst_full_name: str
    port_name: str
    port_dir: str
    role: str
    signal_full_name: str


@dataclass(frozen=True)
class ParamRow:
    module: str
    inst_full_name: str
    param_name: str
    param_value: str
    param_kind: str
    param_info: str


@dataclass
class TemplateAxes:
    row_by_module: Dict[str, int]
    col_by_port: Dict[str, int]
    body_style_cell: Optional[object]
    header_style_cell: Optional[object]
    module_style_cell: Optional[object]
    instance_style_cell: Optional[object]
    parameter_style_cell: Optional[object]


@dataclass
class ModuleTrace:
    rows: Sequence[TraceRow]
    error: Optional[str] = None


class TraceOutputError(RuntimeError):
    pass


@dataclass(frozen=True)
class InstanceEntry:
    module: str
    inst_full_name: str

    @property
    def label(self) -> str:
        return self.inst_full_name or self.module


@dataclass
class PortSummary:
    seen: bool = False
    matched: bool = False
    regcombo_as_keyword: bool = False
    port_dir: str = ""
    details: List[str] = field(default_factory=list)
    detail_seen: Set[str] = field(default_factory=set)
    actual_details: List[str] = field(default_factory=list)
    actual_seen: Set[str] = field(default_factory=set)
    actual_blocked_roles: Set[str] = field(default_factory=set)
    matched_roles: Set[str] = field(default_factory=set)

    def observe(self, role: str, signal: str, matcher: "InstanceMatcher") -> None:
        self.seen = True
        signal_text = signal or ""
        role_text = role or "unknown"
        relevant_endpoint = should_report_actual_endpoint(self.port_dir, role_text)
        matched = matcher.belongs(signal_text)
        if self.regcombo_as_keyword and relevant_endpoint and is_regcombo_signal(signal_text):
            matched = True
        if matched and relevant_endpoint:
            self.matched = True
            self.mark_matched(role_text)

        if not self.port_dir:
            self.port_dir = "unknown"

        if signal_text.startswith("TRACE_LIMIT_REACHED:") and relevant_endpoint:
            self.add_detail(f"{role_text}={signal_text}")
        elif signal_text.startswith("Const:") and relevant_endpoint:
            if role_text in self.matched_roles:
                return
            self.block_actual(role_text)
            self.add_detail(f"{role_text}={signal_text}")
        elif (
            signal_text in {"NO_DRIVER", "NO_LOAD", "ERROR:no_connections"}
            or signal_text.startswith("ERROR:")
        ) and relevant_endpoint:
            if role_text in self.matched_roles:
                return
            self.block_actual(role_text)
            self.add_detail(f"{role_text}={signal_text}")
        elif not matched:
            self.add_actual(role_text, signal_text)

    def observe_row(self, row: "TraceRow", matcher: "InstanceMatcher") -> None:
        if row.port_dir and self.port_dir in {"", "unknown"}:
            self.port_dir = normalize_port_dir(row.port_dir)
        self.observe(row.role, row.signal_full_name, matcher)

    def add_actual(self, role: str, signal: str) -> None:
        if not signal:
            return
        if role in self.actual_blocked_roles:
            return
        if signal.startswith("Const:"):
            return
        if signal in {"NO_DRIVER", "NO_LOAD", "ERROR:no_connections"} or signal.startswith("ERROR:"):
            return
        if not should_report_actual_endpoint(self.port_dir, role):
            return
        label = "driver_actual" if role == "driver" else "loader_actual" if role == "load" else f"{role}_actual"
        detail = f"{label}={signal}"
        if detail in self.actual_seen:
            return
        self.actual_seen.add(detail)
        self.actual_details.append(detail)

    def block_actual(self, role: str) -> None:
        self.actual_blocked_roles.add(role)
        label = "driver_actual" if role == "driver" else "loader_actual" if role == "load" else f"{role}_actual"
        prefix = f"{label}="
        if not any(detail.startswith(prefix) for detail in self.actual_details):
            return
        self.actual_details = [
            detail for detail in self.actual_details
            if not detail.startswith(prefix)
        ]
        self.actual_seen = set(self.actual_details)

    def mark_matched(self, role: str) -> None:
        self.matched_roles.add(role)
        prefixes = [f"{role}="]
        label = "driver_actual" if role == "driver" else "loader_actual" if role == "load" else f"{role}_actual"
        prefixes.append(f"{label}=")
        self.details = [
            detail for detail in self.details
            if not any(detail.startswith(prefix) for prefix in prefixes)
        ]
        self.detail_seen = set(self.details)
        self.actual_details = [
            detail for detail in self.actual_details
            if not any(detail.startswith(prefix) for prefix in prefixes)
        ]
        self.actual_seen = set(self.actual_details)

    def add_detail(self, detail: str) -> None:
        if detail in self.detail_seen:
            return
        self.detail_seen.add(detail)
        self.details.append(detail)

    def result(self) -> str:
        if not self.seen:
            return "no; NO_TRACE"
        text = "yes" if self.matched else "no"
        if self.details:
            text += "; " + "; ".join(self.details)
        if not self.matched and self.actual_details:
            text += "; " + "; ".join(self.actual_details)
        return text


class InstanceMatcher:
    def __init__(self, instances: Sequence[str], cache_size: int = 200000) -> None:
        self.prefixes: Set[str] = set()
        self.cache: Dict[str, bool] = {}
        self.cache_size = max(0, cache_size)
        for inst in instances:
            self.add_instance(inst)

    def add_instance(self, inst: str) -> None:
        inst = inst.strip()
        if not inst:
            return
        parts = [part for part in inst.split(".") if part]
        if not parts:
            return
        for idx in range(len(parts)):
            self.prefixes.add(".".join(parts[idx:]))

    def belongs(self, signal_name: str) -> bool:
        if not signal_name or signal_name.startswith("Const:") or not self.prefixes:
            return False
        cached = self.cache.get(signal_name)
        if cached is not None:
            return cached

        result = self._belongs_uncached(signal_name)
        if self.cache_size and len(self.cache) < self.cache_size:
            self.cache[signal_name] = result
        return result

    def _belongs_uncached(self, signal_name: str) -> bool:
        for prefix in candidate_signal_prefixes(signal_name):
            if prefix not in self.prefixes:
                continue
            if is_direct_instance_node(strip_instance_prefix(signal_name, prefix)):
                return True
        return False


def log_step(message: str) -> None:
    print(f"[annotate_trace_xlsx] {message}", file=sys.stderr)


def setup_log_file(log_file: str):
    if not log_file or os.environ.get("ANNOTATE_TRACE_XLSX_LOG_TEE_ACTIVE") == "1":
        return None
    path = Path(log_file).expanduser()
    if not path.is_absolute():
        path = RUN_CWD / path
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("w", encoding="utf-8", buffering=1)
    sys.stderr = TeeStream(sys.stderr, handle)
    log_step(f"log_file={path}")
    return handle


def split_csv_arg(text: str) -> List[str]:
    return [item.strip() for item in text.split(",") if item.strip()] if text else []


def safe_name(text: str) -> str:
    return sanitize_component(text)


def cell_text(value: object) -> str:
    if value is None:
        return ""
    return str(value).strip()


def normalize_port_dir(port_dir: str) -> str:
    text = (port_dir or "").strip().lower()
    if text in {"input", "npiinput", "1"}:
        return "input"
    if text in {"output", "npioutput", "2"}:
        return "output"
    if text in {"inout", "npiinout", "3"}:
        return "inout"
    return "unknown"


def should_report_actual_endpoint(port_dir: str, role: str) -> bool:
    direction = normalize_port_dir(port_dir)
    role = (role or "").strip().lower()
    if direction == "input":
        return role == "driver"
    if direction == "output":
        return role == "load"
    if direction == "inout":
        return role in {"driver", "load"}
    return role in {"driver", "load"}


def is_regcombo_signal(signal: str) -> bool:
    return re.search(r"(^|[/:])RegCombo\.", signal or "") is not None


def template_has_instance_column(sheet) -> bool:
    header_b = cell_text(sheet.cell(row=1, column=INSTANCE_COL).value).lower()
    return header_b == "instance"


def copy_cell_style(dst, src) -> None:
    if src is None:
        return
    if src.has_style:
        dst.font = copy(src.font)
        dst.fill = copy(src.fill)
        dst.border = copy(src.border)
        dst.alignment = copy(src.alignment)
        dst.number_format = src.number_format
        dst.protection = copy(src.protection)


def create_minimal_template(
    template_path: Path,
    modules: Sequence[str],
    ports: Sequence[str],
    sheet_name: Optional[str],
) -> None:
    log_step(f"template missing; create minimal template: {template_path}")
    workbook = openpyxl.Workbook()
    sheet = workbook.active
    if sheet_name:
        sheet.title = sheet_name

    sheet.cell(row=1, column=MODULE_COL, value="module")
    sheet.cell(row=1, column=INSTANCE_COL, value="instance")
    sheet.cell(row=1, column=PARAMETER_COL, value="parameters")
    for col, port in enumerate(ports, start=PORT_START_COL):
        sheet.cell(row=1, column=col, value=port)
    for row, module in enumerate(modules, start=2):
        sheet.cell(row=row, column=MODULE_COL, value=module)

    sheet.column_dimensions["A"].width = 18
    sheet.column_dimensions["B"].width = 44
    sheet.column_dimensions["C"].width = 48
    for col in range(PORT_START_COL, PORT_START_COL + len(ports)):
        sheet.column_dimensions[openpyxl.utils.get_column_letter(col)].width = 16

    header_font = openpyxl.styles.Font(bold=True)
    header_fill = openpyxl.styles.PatternFill("solid", fgColor="D9EAF7")
    thin = openpyxl.styles.Side(style="thin", color="A6A6A6")
    border = openpyxl.styles.Border(left=thin, right=thin, top=thin, bottom=thin)
    for row in sheet.iter_rows(
        min_row=1,
        max_row=max(2, 1 + len(modules)),
        min_col=1,
        max_col=max(3, 3 + len(ports)),
    ):
        for cell in row:
            cell.border = border
            cell.alignment = openpyxl.styles.Alignment(vertical="top", wrap_text=True)
            if cell.row == 1:
                cell.font = header_font
                cell.fill = header_fill

    try:
        atomic_save_workbook(workbook, template_path)
    finally:
        workbook.close()
    log_step(f"created template={template_path}")


def load_workbook(template_path: Path, sheet_name: Optional[str]):
    log_step(f"loading workbook: {template_path}")
    workbook = openpyxl.load_workbook(template_path)
    if sheet_name:
        if sheet_name not in workbook.sheetnames:
            raise ValueError(f"sheet not found: {sheet_name}")
        sheet = workbook[sheet_name]
    else:
        sheet = workbook[workbook.sheetnames[0]]
    log_step(f"worksheet={sheet.title}")
    return workbook, sheet


def extract_modules_and_ports(sheet, cli_modules: str, cli_ports: str) -> Tuple[List[str], List[str]]:
    modules = split_csv_arg(cli_modules)
    ports = split_csv_arg(cli_ports)

    if not modules:
        modules = []
        for row in range(2, sheet.max_row + 1):
            value = cell_text(sheet.cell(row=row, column=1).value)
            if value:
                modules.append(value)

    if not ports:
        ports = []
        port_start_col = PORT_START_COL if template_has_instance_column(sheet) else 3
        for col in range(port_start_col, sheet.max_column + 1):
            value = cell_text(sheet.cell(row=1, column=col).value)
            if value:
                ports.append(value)

    if not modules:
        raise ValueError("no modules found; fill column A or pass -module")
    if not ports:
        raise ValueError("no ports found; fill row 1 from the port columns or pass -ports")
    return modules, ports


def prepare_template_axes(sheet, modules: Sequence[str], ports: Sequence[str]) -> TemplateAxes:
    row_by_module: Dict[str, int] = {}
    col_by_port: Dict[str, int] = {}

    for row in range(2, sheet.max_row + 1):
        value = cell_text(sheet.cell(row=row, column=MODULE_COL).value)
        if value:
            row_by_module.setdefault(value, row)

    for col in range(PORT_START_COL, sheet.max_column + 1):
        value = cell_text(sheet.cell(row=1, column=col).value)
        if value:
            col_by_port.setdefault(value, col)

    next_row = max(sheet.max_row + 1, 2)
    next_col = max(sheet.max_column + 1, PORT_START_COL)

    body_style_cell = sheet.cell(row=2, column=PORT_START_COL)
    module_style_cell = sheet.cell(row=2, column=MODULE_COL)
    instance_style_cell = sheet.cell(row=2, column=INSTANCE_COL)
    header_style_cell = sheet.cell(row=1, column=PORT_START_COL)
    parameter_style_cell = sheet.cell(row=2, column=PARAMETER_COL)

    for module in modules:
        if module in row_by_module:
            continue
        row_by_module[module] = next_row
        cell = sheet.cell(row=next_row, column=MODULE_COL, value=module)
        copy_cell_style(cell, module_style_cell)
        log_step(f"append module row: row={next_row} module={module}")
        next_row += 1

    for port in ports:
        if port in col_by_port:
            continue
        col_by_port[port] = next_col
        cell = sheet.cell(row=1, column=next_col, value=port)
        copy_cell_style(cell, header_style_cell)
        log_step(f"append port column: col={next_col} port={port}")
        next_col += 1

    return TemplateAxes(
        row_by_module=row_by_module,
        col_by_port=col_by_port,
        body_style_cell=body_style_cell,
        header_style_cell=header_style_cell,
        module_style_cell=module_style_cell,
        instance_style_cell=instance_style_cell,
        parameter_style_cell=parameter_style_cell,
    )


def prepare_instance_axes(
    sheet,
    entries: Sequence[InstanceEntry],
    ports: Sequence[str],
) -> TemplateAxes:
    if not template_has_instance_column(sheet):
        sheet.insert_cols(INSTANCE_COL, 1)
    axes = prepare_template_axes(sheet, [entry.module for entry in entries], ports)
    header_style = axes.header_style_cell or axes.body_style_cell

    for col, text in (
        (MODULE_COL, "module"),
        (INSTANCE_COL, "instance"),
        (PARAMETER_COL, "parameters"),
    ):
        cell = sheet.cell(row=1, column=col, value=text)
        copy_cell_style(cell, header_style)

    row_by_module: Dict[str, int] = {}
    start_row = 2
    for idx, entry in enumerate(entries):
        row = start_row + idx
        row_by_module[entry.label] = row
        module_cell = sheet.cell(row=row, column=MODULE_COL, value=entry.module)
        copy_cell_style(module_cell, axes.module_style_cell or axes.body_style_cell)
        module_alignment = copy(module_cell.alignment)
        module_alignment.wrap_text = True
        if module_alignment.vertical is None:
            module_alignment.vertical = "top"
        module_cell.alignment = module_alignment

        instance_cell = sheet.cell(row=row, column=INSTANCE_COL, value=entry.inst_full_name or "")
        copy_cell_style(instance_cell, axes.instance_style_cell or axes.body_style_cell)
        instance_alignment = copy(instance_cell.alignment)
        instance_alignment.wrap_text = True
        if instance_alignment.vertical is None:
            instance_alignment.vertical = "top"
        instance_cell.alignment = instance_alignment

        parameter_cell = sheet.cell(row=row, column=PARAMETER_COL)
        copy_cell_style(parameter_cell, axes.parameter_style_cell or axes.body_style_cell)
        parameter_alignment = copy(parameter_cell.alignment)
        parameter_alignment.wrap_text = True
        if parameter_alignment.vertical is None:
            parameter_alignment.vertical = "top"
        parameter_cell.alignment = parameter_alignment

    old_max_row = sheet.max_row
    last_entry_row = start_row + len(entries) - 1
    if last_entry_row < old_max_row:
        sheet.delete_rows(last_entry_row + 1, old_max_row - last_entry_row)

    sheet.column_dimensions["A"].width = max(sheet.column_dimensions["A"].width or 0, 18)
    sheet.column_dimensions["B"].width = max(sheet.column_dimensions["B"].width or 0, 44)
    sheet.column_dimensions["C"].width = max(sheet.column_dimensions["C"].width or 0, 48)
    for col in range(PORT_START_COL, sheet.max_column + 1):
        letter = openpyxl.utils.get_column_letter(col)
        sheet.column_dimensions[letter].width = max(sheet.column_dimensions[letter].width or 0, 16)

    return TemplateAxes(
        row_by_module=row_by_module,
        col_by_port=axes.col_by_port,
        body_style_cell=axes.body_style_cell,
        header_style_cell=axes.header_style_cell,
        module_style_cell=axes.module_style_cell,
        instance_style_cell=axes.instance_style_cell,
        parameter_style_cell=axes.parameter_style_cell,
    )


def set_parameter_cell(sheet, axes: TemplateAxes, row_key: str, result: str) -> None:
    row = axes.row_by_module[row_key]
    cell = sheet.cell(row=row, column=PARAMETER_COL, value=result)
    copy_cell_style(cell, axes.parameter_style_cell or axes.body_style_cell)
    alignment = copy(cell.alignment)
    alignment.wrap_text = True
    if alignment.vertical is None:
        alignment.vertical = "top"
    cell.alignment = alignment
    current_width = sheet.column_dimensions["C"].width or 0
    if current_width < 48:
        sheet.column_dimensions["C"].width = 48


def set_result_cell(sheet, axes: TemplateAxes, row_key: str, port: str, result: str) -> None:
    row = axes.row_by_module[row_key]
    col = axes.col_by_port[port]
    cell = sheet.cell(row=row, column=col, value=result)
    copy_cell_style(cell, axes.body_style_cell)


def subsystem_key(inst_full_name: str, level: int) -> str:
    if level <= 0:
        raise ValueError("subsystem level must be greater than zero")
    if not inst_full_name:
        return "UNKNOWN_SUBSYSTEM"
    parts = [part for part in inst_full_name.split(".") if part]
    if not parts:
        return "UNKNOWN_SUBSYSTEM"
    if len(parts) < level:
        return ".".join(parts)
    return ".".join(parts[:level])


def split_rows_by_subsystem(rows: Sequence[TraceRow], level: int) -> Dict[str, List[TraceRow]]:
    by_subsystem: Dict[str, List[TraceRow]] = {}
    for row in rows:
        key = subsystem_key(row.inst_full_name, level)
        by_subsystem.setdefault(key, []).append(row)
    return by_subsystem


def split_instances_by_subsystem(instances: Sequence[str], level: int) -> Dict[str, List[str]]:
    by_subsystem: Dict[str, List[str]] = {}
    for inst in instances:
        key = subsystem_key(inst, level)
        by_subsystem.setdefault(key, []).append(inst)
    return by_subsystem


def split_params_by_subsystem(rows: Sequence[ParamRow], level: int) -> Dict[str, List[ParamRow]]:
    by_subsystem: Dict[str, List[ParamRow]] = {}
    for row in rows:
        key = subsystem_key(row.inst_full_name, level)
        by_subsystem.setdefault(key, []).append(row)
    return by_subsystem


def select_subsystem_modules(
    modules: Sequence[str],
    subsystem: str,
    module_data_by_subsystem: Dict[str, Dict[str, object]],
    params_by_module_subsystem: Dict[str, Dict[str, Sequence[ParamRow]]],
    module_errors: Dict[str, str],
) -> List[str]:
    selected: List[str] = []
    for module in modules:
        module_data = module_data_by_subsystem.get(module, {})
        module_params = params_by_module_subsystem.get(module, {})
        has_data = subsystem in module_data
        has_instance = bool(module_params.get(subsystem))
        if has_data or has_instance:
            selected.append(module)
    return selected


def trace_failure_marker(exc: BaseException) -> str:
    if isinstance(exc, subprocess.TimeoutExpired):
        return "TRACE_TIMEOUT"
    if isinstance(exc, TraceOutputError):
        return "TRACE_OUTPUT_MISSING"
    if isinstance(exc, subprocess.CalledProcessError):
        if exc.returncode == 124:
            return "TRACE_TIMEOUT"
        return f"TRACE_FAILED:rc={exc.returncode}"
    return f"TRACE_FAILED:{type(exc).__name__}"


def split_trace_rows_by_instance(rows: Sequence[TraceRow]) -> Dict[str, List[TraceRow]]:
    by_instance: Dict[str, List[TraceRow]] = {}
    for row in rows:
        by_instance.setdefault(row.inst_full_name, []).append(row)
    return by_instance


def split_param_rows_by_instance(rows: Sequence[ParamRow]) -> Dict[str, List[ParamRow]]:
    by_instance: Dict[str, List[ParamRow]] = {}
    for row in rows:
        by_instance.setdefault(row.inst_full_name, []).append(row)
    return by_instance


def instances_from_trace_rows(module: str, rows: Sequence[TraceRow]) -> List[InstanceEntry]:
    seen: Dict[str, None] = {}
    for row in rows:
        if row.inst_full_name:
            seen.setdefault(row.inst_full_name, None)
    return [InstanceEntry(module=module, inst_full_name=inst) for inst in sorted(seen)]


def instances_from_param_rows(module: str, rows: Sequence[ParamRow]) -> List[InstanceEntry]:
    seen: Dict[str, None] = {}
    for row in rows:
        if row.module == module and row.inst_full_name:
            seen.setdefault(row.inst_full_name, None)
    return [InstanceEntry(module=module, inst_full_name=inst) for inst in sorted(seen)]


def split_output_path(output: Path, subsystem: str) -> Path:
    requested = output.with_name(
        f"{output.stem}__subsys_{safe_name(subsystem)}{output.suffix}"
    )
    bounded = bounded_derived_path(
        output,
        "__subsys_",
        subsystem,
        readable_identity=safe_name(subsystem),
    )
    if bounded != requested:
        log_step(
            f"filename_shortened original={requested.name} bounded={bounded.name} "
            f"identity={subsystem}"
        )
    return bounded


def remove_intermediate_file(path: Path, reason: str) -> None:
    if not path.exists() and not path.is_symlink():
        return
    if not path.is_file() and not path.is_symlink():
        raise RuntimeError(f"refusing to remove non-file intermediate output: {path}")
    path.unlink()
    log_step(f"removed {reason}: {path}")


def cleanup_subsystem_outputs(template: Path, output: Path) -> None:
    protected = template.resolve()
    candidates = [output]
    if output.parent.is_dir():
        prefixes = derived_glob_prefixes(output, "__subsys_")
        candidates.extend(
            candidate
            for candidate in output.parent.iterdir()
            if candidate.name.startswith(prefixes)
            and candidate.name.endswith(output.suffix)
        )

    seen: Set[Path] = set()
    for candidate in candidates:
        resolved = candidate.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        if resolved == protected:
            log_step(f"preserved subsystem template output: {candidate}")
            continue
        remove_intermediate_file(candidate, "stale subsystem output")


def collect_existing_output_modes(output: Path) -> Dict[Path, int]:
    candidates = [output]
    if output.parent.is_dir():
        prefixes = derived_glob_prefixes(output, "__subsys_")
        candidates.extend(
            candidate
            for candidate in output.parent.iterdir()
            if candidate.name.startswith(prefixes)
            and candidate.name.endswith(output.suffix)
        )

    modes: Dict[Path, int] = {}
    for candidate in candidates:
        try:
            modes[candidate] = stat.S_IMODE(candidate.stat().st_mode)
        except FileNotFoundError:
            continue
    return modes


def rollback_outputs(paths: Sequence[Path], reason: str) -> None:
    failures: List[str] = []
    seen: Set[Path] = set()
    for path in reversed(paths):
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        try:
            remove_intermediate_file(path, reason)
        except Exception as exc:
            failures.append(f"{path}: {exc}")
    if failures:
        raise RuntimeError("failed to roll back outputs: " + "; ".join(failures))


@dataclass
class OutputTransaction:
    paths: List[Path] = field(default_factory=list)
    protected_paths: Set[Path] = field(default_factory=set)
    committed: bool = False

    def track(self, path: Path) -> Path:
        resolved = path.resolve()
        if resolved in self.protected_paths:
            raise ValueError(f"subsystem output path collides with protected input: {path}")
        if any(existing.resolve() == resolved for existing in self.paths):
            raise ValueError(f"duplicate subsystem output path: {path}")
        self.paths.append(path)
        return path

    def commit(self) -> None:
        self.committed = True

    def rollback_if_uncommitted(self) -> None:
        if not self.committed:
            rollback_outputs(self.paths, "failed subsystem run output")


def format_module_params(module: str, param_rows: Sequence[ParamRow]) -> str:
    rows = [row for row in param_rows if row.module == module]
    if not rows:
        return "NO_PARAMETER"

    parameters = [
        row for row in rows if row.param_kind not in {"instance", "localparam"}
    ]
    if not parameters:
        localparam_count = sum(row.param_kind == "localparam" for row in rows)
        if localparam_count:
            return f"NO_PARAMETER; localparam_count={localparam_count}"
        return "NO_PARAMETER"

    grouped: Dict[str, List[ParamRow]] = {}
    for row in parameters:
        grouped.setdefault(row.inst_full_name, []).append(row)

    lines: List[str] = []
    for inst in sorted(grouped):
        parts = []
        seen = set()
        for row in grouped[inst]:
            key = (row.param_name, row.param_value)
            if key in seen:
                continue
            seen.add(key)
            parts.append(f"{row.param_name}={row.param_value}")
        if parts:
            lines.append(f"{inst}: " + ", ".join(parts))
        else:
            lines.append(f"{inst}: NO_PARAMETER")
    return "\n".join(lines) if lines else "NO_PARAMETER"


def format_instance_params(module: str, inst_full_name: str, param_rows: Sequence[ParamRow]) -> str:
    rows = [
        row
        for row in param_rows
        if row.module == module
        and row.inst_full_name == inst_full_name
        and row.param_kind not in {"instance", "localparam"}
    ]
    if not rows:
        return "NO_PARAMETER"

    parts = []
    seen = set()
    for row in rows:
        key = (row.param_name, row.param_value)
        if key in seen:
            continue
        seen.add(key)
        parts.append(f"{row.param_name}={row.param_value}")
    return ", ".join(parts) if parts else "NO_PARAMETER"


def build_instance_entries(
    modules: Sequence[str],
    module_traces: Dict[str, ModuleTrace],
    module_params: Dict[str, Sequence[ParamRow]],
) -> List[InstanceEntry]:
    entries: List[InstanceEntry] = []
    seen: Set[Tuple[str, str]] = set()
    for module in modules:
        trace = module_traces.get(module)
        candidates: List[InstanceEntry] = []
        if trace is not None and trace.error is None:
            candidates.extend(instances_from_trace_rows(module, trace.rows))
        candidates.extend(instances_from_param_rows(module, module_params.get(module, [])))
        if not candidates:
            candidates = [InstanceEntry(module=module, inst_full_name="")]

        for entry in candidates:
            key = (entry.module, entry.inst_full_name)
            if key in seen:
                continue
            seen.add(key)
            entries.append(entry)
    return entries


def build_instance_entries_from_results(
    modules: Sequence[str],
    module_port_results: Dict[str, Dict[str, Dict[str, str]]],
    module_params: Dict[str, Sequence[ParamRow]],
) -> List[InstanceEntry]:
    entries: List[InstanceEntry] = []
    seen: Set[Tuple[str, str]] = set()
    for module in modules:
        candidates = [
            InstanceEntry(module=module, inst_full_name=inst)
            for inst in sorted(module_port_results.get(module, {}))
            if inst
        ]
        candidates.extend(instances_from_param_rows(module, module_params.get(module, [])))
        if not candidates:
            candidates = [InstanceEntry(module=module, inst_full_name="")]

        for entry in candidates:
            key = (entry.module, entry.inst_full_name)
            if key in seen:
                continue
            seen.add(key)
            entries.append(entry)
    return entries


def write_annotation_workbook(
    *,
    template: Path,
    sheet_name: Optional[str],
    output: Path,
    modules: Sequence[str],
    ports: Sequence[str],
    module_traces: Dict[str, ModuleTrace],
    module_params: Dict[str, Sequence[ParamRow]],
    module_param_errors: Optional[Dict[str, str]] = None,
    filter_instances: Sequence[str],
    missing_marker: str = "NO_MODULE",
    regcombo_as_keyword: bool = False,
    output_mode: Optional[int] = None,
) -> None:
    workbook, sheet = load_workbook(template, sheet_name)
    module_param_errors = module_param_errors or {}
    entries = build_instance_entries(modules, module_traces, module_params)
    axes = prepare_instance_axes(sheet, entries, ports)

    for entry in entries:
        row_key = entry.label
        module = entry.module
        trace = module_traces.get(module, ModuleTrace(rows=[], error=missing_marker))
        if module in module_param_errors:
            param_text = module_param_errors[module]
        else:
            param_text = format_instance_params(module, entry.inst_full_name, module_params.get(module, []))
        if param_text == "NO_PARAMETER" and trace.error is not None:
            param_text = trace.error
        log_step(f"parameter cell instance={row_key} module={module} result={param_text}")
        set_parameter_cell(sheet, axes, row_key, param_text)

        if trace.error is None and entry.inst_full_name:
            instance_rows = [
                row for row in trace.rows if row.inst_full_name == entry.inst_full_name
            ]
        else:
            instance_rows = trace.rows
        for port in ports:
            if trace.error is not None:
                result = trace.error
            else:
                result = summarize_port(
                    instance_rows,
                    port,
                    filter_instances,
                    regcombo_as_keyword=regcombo_as_keyword,
                )
            log_step(f"cell instance={row_key} module={module} port={port} result={result}")
            set_result_cell(sheet, axes, row_key, port, result)

    try:
        atomic_save_workbook(workbook, output, output_mode=output_mode)
    finally:
        workbook.close()
    log_step(f"done output={output}")


def write_annotation_results_workbook(
    *,
    template: Path,
    sheet_name: Optional[str],
    output: Path,
    modules: Sequence[str],
    ports: Sequence[str],
    module_port_results: Dict[str, Dict[str, Dict[str, str]]],
    module_params: Dict[str, Sequence[ParamRow]],
    module_errors: Optional[Dict[str, str]] = None,
    module_param_errors: Optional[Dict[str, str]] = None,
    missing_marker: str = "NO_MODULE",
    output_mode: Optional[int] = None,
) -> None:
    workbook, sheet = load_workbook(template, sheet_name)
    module_errors = module_errors or {}
    module_param_errors = module_param_errors or {}
    entries = build_instance_entries_from_results(modules, module_port_results, module_params)
    axes = prepare_instance_axes(sheet, entries, ports)

    for entry in entries:
        row_key = entry.label
        module = entry.module
        trace_error = module_errors.get(module)
        if module in module_param_errors:
            param_text = module_param_errors[module]
        else:
            param_text = format_instance_params(module, entry.inst_full_name, module_params.get(module, []))
        if param_text == "NO_PARAMETER" and trace_error is not None:
            param_text = trace_error
        log_step(f"parameter cell instance={row_key} module={module} result={param_text}")
        set_parameter_cell(sheet, axes, row_key, param_text)

        results = module_port_results.get(module, {}).get(entry.inst_full_name, {})
        for port in ports:
            if trace_error is not None:
                result = trace_error
            else:
                result = results.get(port, f"no; {missing_marker}")
            log_step(f"cell instance={row_key} module={module} port={port} result={result}")
            set_result_cell(sheet, axes, row_key, port, result)

    try:
        atomic_save_workbook(workbook, output, output_mode=output_mode)
    finally:
        workbook.close()
    log_step(f"done output={output}")


def run_checked(
    cmd: Sequence[object],
    cwd: Path,
    stdout_path: Optional[Path] = None,
    env: Optional[Dict[str, str]] = None,
    timeout_sec: Optional[float] = None,
) -> None:
    text_cmd = " ".join(str(x) for x in cmd)
    log_step(f"command: {text_cmd}")
    timeout = timeout_sec if timeout_sec is not None and timeout_sec > 0 else None
    out = None
    try:
        if stdout_path is not None:
            out = stdout_path.open("w", encoding="utf-8", newline="")
        proc = subprocess.Popen(
            [str(x) for x in cmd],
            cwd=str(cwd),
            env=env,
            stdout=out if out is not None else sys.stderr,
            stderr=sys.stderr,
            start_new_session=bool(timeout is not None and os.name == "posix"),
        )
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            log_step(f"command timed out after {timeout_sec} seconds: {text_cmd}")
            terminate_timed_out_process(proc)
            raise
        if timeout is not None and os.name == "posix":
            cleanup_completed_process_session(proc)
    finally:
        if out is not None:
            out.close()
    if rc != 0:
        raise subprocess.CalledProcessError(rc, [str(x) for x in cmd])


def load_instances(path: Path) -> List[str]:
    instances = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            text = line.strip().lstrip("\ufeff")
            if text:
                instances.append(text)
    log_step(f"loaded {len(instances)} filter instances from {path}")
    return instances


def find_filter_instances(args, workdir: Path) -> Tuple[List[str], Path]:
    requested = workdir / f"{safe_name(args.keywords)}_instances.txt"
    out_file = bounded_path(requested, suffix="_instances.txt", identity=args.keywords)
    if out_file != requested:
        log_step(
            f"filename_shortened original={requested.name} bounded={out_file.name} "
            f"identity={args.keywords}"
        )
    remove_intermediate_file(out_file, "stale keyword instance output")
    cmd: List[object] = [
        sys.executable,
        SCRIPT_DIR / "find_instances_batched.py",
        "-lib",
        args.lib,
        "-keywords",
        args.keywords,
        "-output",
        out_file,
        "--batch-size",
        str(args.keyword_batch_size),
        "--verdi-timeout-sec",
        str(args.verdi_timeout_sec),
    ]
    if args.keyword_continue_on_error:
        cmd.append("--continue-on-error")
    if args.keyword_log_instances:
        cmd.append("--log-instances")
    kdebug_bin = getattr(args, "kdebug_bin", "")
    if kdebug_bin:
        cmd.extend(["--kdebug-bin", kdebug_bin])

    try:
        run_checked(cmd, cwd=RUN_CWD)
    except Exception:
        remove_intermediate_file(out_file, "failed keyword instance output")
        raise

    instances = load_instances(out_file)
    if not instances:
        raise RuntimeError(f"no instances found for filter modules: {args.keywords}")
    return instances, out_file


def read_param_rows(path: Path) -> List[ParamRow]:
    rows: List[ParamRow] = []
    seen = set()
    log_step(f"reading parameter csv: {path}")
    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            normalized = ParamRow(
                module=row.get("module", ""),
                inst_full_name=row.get("inst_full_name", ""),
                param_name=row.get("param_name", ""),
                param_value=row.get("param_value", ""),
                param_kind=row.get("param_kind", ""),
                param_info=row.get("param_info", ""),
            )
            key = (
                normalized.module,
                normalized.inst_full_name,
                normalized.param_name,
                normalized.param_value,
                normalized.param_kind,
            )
            if key in seen:
                continue
            seen.add(key)
            rows.append(normalized)
    log_step(f"loaded parameter rows: {len(rows)}")
    return rows


def find_module_parameters(args, modules: Sequence[str], workdir: Path) -> Tuple[List[ParamRow], Path, Optional[str]]:
    out_file = workdir / "module_parameters.csv"
    remove_intermediate_file(out_file, "stale module parameter output")
    if args.no_params:
        log_step("skip module parameter collection because --no-params is set")
        return [], out_file, "PARAM_SKIPPED"

    try:
        cmd: List[object] = [
            sys.executable,
            SCRIPT_DIR / "kdebug_backend.py",
            "find-parameters",
            "--lib",
            args.lib,
            "--modules",
            ",".join(modules),
            "--output",
            out_file,
        ]
        kdebug_bin = getattr(args, "kdebug_bin", "")
        if kdebug_bin:
            cmd.extend(["--kdebug-bin", kdebug_bin])
        if getattr(args, "trace_debug", 0):
            cmd.append("--debug")
        if args.verdi_timeout_sec > 0:
            cmd.extend(["--timeout-sec", str(args.verdi_timeout_sec)])
        run_checked(
            cmd,
            cwd=RUN_CWD,
            timeout_sec=timeout_with_cleanup_grace(args.verdi_timeout_sec),
        )
        if not path_has_contents(out_file):
            raise RuntimeError(
                f"parameter kdebug backend completed without a non-empty output: {out_file}"
            )
        rows = read_param_rows(out_file)
    except Exception as exc:
        remove_intermediate_file(out_file, "failed module parameter output")
        if args.strict_params:
            raise
        message = f"PARAM_TRACE_FAILED: {exc}"
        log_step(message)
        return [], out_file, message

    return rows, out_file, None


def strip_instance_prefix(signal_name: str, inst: str) -> Optional[str]:
    if signal_name == inst:
        return ""
    if signal_name.startswith(inst + "."):
        return signal_name[len(inst) + 1 :]
    if signal_name.startswith(inst + "/"):
        return signal_name[len(inst) + 1 :]
    return None


def candidate_signal_prefixes(signal_name: str) -> Iterable[str]:
    start = 0
    while True:
        dot = signal_name.find(".", start)
        slash = signal_name.find("/", start)
        positions = [pos for pos in (dot, slash) if pos != -1]
        if not positions:
            break
        pos = min(positions)
        if pos > 0:
            yield signal_name[:pos]
        start = pos + 1
    if signal_name:
        yield signal_name


def is_direct_instance_node(rest: Optional[str]) -> bool:
    if rest is None:
        return False
    if rest == "":
        return True
    if rest.startswith("_ExprInst__:"):
        return False
    if "/" in rest:
        head = rest.split("/", 1)[0]
        return "." not in head
    return rest.count(".") <= 1


def signal_belongs_to_instance(signal_name: str, instances: Iterable[str]) -> bool:
    if not signal_name or signal_name.startswith("Const:"):
        return False

    for inst in instances:
        if is_direct_instance_node(strip_instance_prefix(signal_name, inst)):
            return True

        # The trace backend may remove a common top prefix for readability.
        parts = inst.split(".")
        for idx in range(1, len(parts)):
            suffix = ".".join(parts[idx:])
            if is_direct_instance_node(strip_instance_prefix(signal_name, suffix)):
                return True
    return False


def read_trace_rows(csv_paths: Sequence[Path]) -> List[TraceRow]:
    rows: List[TraceRow] = []
    seen = set()
    for path in csv_paths:
        log_step(f"reading trace csv: {path}")
        with path.open("r", encoding="utf-8", newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                signal = row.get("signal_full_name") or row.get("module_signal_full_name") or ""
                normalized = TraceRow(
                    inst_full_name=row.get("inst_full_name", ""),
                    port_name=row.get("port_name", ""),
                    port_dir=normalize_port_dir(row.get("port_dir", "")),
                    role=row.get("role", ""),
                    signal_full_name=signal,
                )
                key = (
                    normalized.inst_full_name,
                    normalized.port_name,
                    normalized.port_dir,
                    normalized.role,
                    normalized.signal_full_name,
                )
                if key in seen:
                    continue
                seen.add(key)
                rows.append(normalized)
    return rows


def trace_module(
    args,
    module: str,
    ports: Sequence[str],
    workdir: Path,
    stop_instance_file: Optional[Path] = None,
) -> Tuple[Path, Path]:
    requested_full_csv = workdir / f"{safe_name(module)}_full.csv"
    requested_module_csv = workdir / f"{safe_name(module)}_module_connections.csv"
    full_csv = bounded_path(requested_full_csv, suffix="_full.csv", identity=module)
    module_csv = bounded_path(
        requested_module_csv,
        suffix="_module_connections.csv",
        identity=module,
    )
    for requested, bounded in (
        (requested_full_csv, full_csv),
        (requested_module_csv, module_csv),
    ):
        if bounded != requested:
            log_step(
                f"filename_shortened original={requested.name} bounded={bounded.name} "
                f"identity={module}"
            )
    remove_intermediate_file(full_csv, f"stale full trace output for {module}")
    remove_intermediate_file(module_csv, f"stale boundary trace output for {module}")
    cmd: List[object] = [
        SCRIPT_DIR / "npi_trace.sh",
        "-module",
        module,
        "-module-out",
        module_csv,
    ]
    cmd.extend(["-lib", args.lib])
    if ports:
        cmd.extend(["-ports", ",".join(ports)])
    cmd.extend(
        [
            "-const-source-fallback",
            str(args.const_source_fallback),
            "-const-trace-depth",
            str(args.const_trace_depth),
            "-assign-trace-depth",
            str(args.assign_trace_depth),
            "-assign-expr-trace-depth",
            str(args.assign_expr_trace_depth),
            "-load-trace-node-limit",
            str(args.load_trace_node_limit),
            "-load-trace-edge-limit",
            str(args.load_trace_edge_limit),
            "-load-trace-api-list-limit",
            str(args.load_trace_api_list_limit),
            "-verdi-timeout-sec",
            str(args.verdi_timeout_sec),
            "-trace-debug",
            str(args.trace_debug),
        ]
    )
    if stop_instance_file is not None:
        cmd.extend(["-load-stop-instance-file", str(stop_instance_file)])
    kdebug_bin = getattr(args, "kdebug_bin", "")
    if kdebug_bin:
        cmd.extend(["--kdebug-bin", kdebug_bin])

    try:
        run_checked(cmd, cwd=RUN_CWD, stdout_path=full_csv)
        missing = [
            path
            for path in (full_csv, module_csv)
            if not path_has_contents(path)
        ]
        if missing:
            raise TraceOutputError(
                "trace command completed without current non-empty output(s): "
                + ", ".join(str(path) for path in missing)
            )
    except Exception:
        remove_intermediate_file(full_csv, f"failed full trace output for {module}")
        remove_intermediate_file(module_csv, f"failed boundary trace output for {module}")
        raise
    return full_csv, module_csv


def summarize_port(
    rows: Sequence[TraceRow],
    port: str,
    filter_instances: Sequence[str],
    regcombo_as_keyword: bool = False,
) -> str:
    port_rows = [row for row in rows if row.port_name == port]
    if not port_rows:
        return "no; NO_TRACE"

    matcher = InstanceMatcher(filter_instances)
    summary = PortSummary(regcombo_as_keyword=regcombo_as_keyword)
    for row in port_rows:
        summary.observe_row(row, matcher)
    return summary.result()


def finalize_summaries(summaries: Dict[str, PortSummary], ports: Sequence[str]) -> Dict[str, str]:
    return {
        port: summaries.get(port, PortSummary()).result()
        for port in ports
    }


def finalize_instance_summaries(
    summaries_by_instance: Dict[str, Dict[str, PortSummary]],
    ports: Sequence[str],
) -> Dict[str, Dict[str, str]]:
    return {
        inst: finalize_summaries(summaries, ports)
        for inst, summaries in summaries_by_instance.items()
    }


def stream_trace_results(
    csv_paths: Sequence[Path],
    ports: Sequence[str],
    matcher: Optional[InstanceMatcher] = None,
    subsystem_level: int = 0,
    matchers_by_subsystem: Optional[Dict[str, InstanceMatcher]] = None,
    regcombo_as_keyword: bool = False,
) -> Tuple[
    Dict[str, Dict[str, str]],
    Dict[str, Dict[str, Dict[str, str]]],
    Set[str],
    int,
]:
    port_set = set(ports)
    empty_matcher = InstanceMatcher([])
    flat_summaries: Dict[str, Dict[str, PortSummary]] = {}
    subsystem_summaries: Dict[str, Dict[str, Dict[str, PortSummary]]] = {}
    subsystems: Set[str] = set()
    total_rows = 0

    for path in csv_paths:
        log_step(f"stream reading trace csv: {path}")
        with path.open("r", encoding="utf-8", newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                port = row.get("port_name", "")
                if port not in port_set:
                    continue
                total_rows += 1
                inst = row.get("inst_full_name", "")
                port_dir = normalize_port_dir(row.get("port_dir", ""))
                role = row.get("role", "")
                signal = row.get("signal_full_name") or row.get("module_signal_full_name") or ""
                trace_row = TraceRow(
                    inst_full_name=inst,
                    port_name=port,
                    port_dir=port_dir,
                    role=role,
                    signal_full_name=signal,
                )

                if subsystem_level:
                    subsystem = subsystem_key(inst, subsystem_level)
                    subsystems.add(subsystem)
                    summaries = subsystem_summaries.setdefault(subsystem, {}).setdefault(inst, {})
                    active_matcher = (
                        matchers_by_subsystem.get(subsystem, empty_matcher)
                        if matchers_by_subsystem is not None
                        else empty_matcher
                    )
                else:
                    summaries = flat_summaries.setdefault(inst, {})
                    active_matcher = matcher or empty_matcher

                summaries.setdefault(
                    port,
                    PortSummary(regcombo_as_keyword=regcombo_as_keyword),
                ).observe_row(trace_row, active_matcher)

    flat_results = finalize_instance_summaries(flat_summaries, ports) if not subsystem_level else {}
    subsystem_results = {
        subsystem: finalize_instance_summaries(instance_summaries, ports)
        for subsystem, instance_summaries in subsystem_summaries.items()
    }
    return flat_results, subsystem_results, subsystems, total_rows


def parse_args():
    parser = argparse.ArgumentParser(
        description="Annotate an XLSX template with NPI trace connectivity results."
    )
    parser.add_argument("-template", required=True, help="input XLSX template")
    parser.add_argument("-output", required=True, help="output annotated XLSX")
    parser.add_argument(
        "-keywords",
        required=True,
        help="comma-separated filter module definition names",
    )
    parser.add_argument(
        "-module",
        default="",
        help="comma-separated target module definitions; defaults to column A",
    )
    parser.add_argument(
        "-ports",
        default="",
        help="comma-separated target ports; defaults to the template port columns",
    )
    parser.add_argument("-lib", required=True, help="KDB path, for example kdb.elab++")
    parser.add_argument(
        "--kdebug-bin",
        default=os.environ.get("KDEBUG_BIN", ""),
        help="kdebug executable; defaults to KDEBUG_BIN/KVERIF_HOME/PATH discovery",
    )
    parser.add_argument(
        "-filelist",
        default="",
        help=argparse.SUPPRESS,
    )
    parser.add_argument("-top", default="", help=argparse.SUPPRESS)
    parser.add_argument("-incdir", default="", help=argparse.SUPPRESS)
    parser.add_argument("-sheet", default=None, help="worksheet name; defaults to first sheet")
    parser.add_argument(
        "-workdir",
        default="",
        help="directory for intermediate CSV files; defaults to the current directory",
    )
    parser.add_argument(
        "-subsystem-level",
        type=int,
        default=0,
        help=(
            "split output by subsystem path prefix. For inst path "
            "top.dut.subsys.u_mod and level 3, subsystem is top.dut.subsys. "
            "Default 0 writes one XLSX."
        ),
    )
    parser.add_argument(
        "--keep-workdir",
        action="store_true",
        help="compatibility option; intermediate workdir is kept by default",
    )
    parser.add_argument(
        "--no-params",
        action="store_true",
        help="skip module parameter collection and keep port annotation running",
    )
    parser.add_argument(
        "--strict-params",
        action="store_true",
        help="fail the whole annotation flow if module parameter collection fails",
    )
    parser.add_argument(
        "--stream",
        action="store_true",
        help="use streaming CSV aggregation and cached instance matching for large designs",
    )
    parser.add_argument(
        "-regcombo-as-keyword",
        "--regcombo-as-keyword",
        type=int,
        choices=(0, 1),
        default=0,
        help=(
            "when set to 1, treat a direction-relevant RegCombo trace endpoint "
            "as a keyword match and annotate the port as yes"
        ),
    )
    parser.add_argument(
        "-const-source-fallback",
        "--const-source-fallback",
        type=int,
        choices=(0, 1),
        default=1,
        help=(
            "enable source-based constant fallback for parent nets tied by assign/declaration. "
            "Set to 0 in very large designs to reduce source parsing work."
        ),
    )
    parser.add_argument(
        "-const-trace-depth",
        "--const-trace-depth",
        type=int,
        default=16,
        help=(
            "maximum parent port recursion depth for constant tie backtrace. "
            "Use 0 to disable recursive parent-port constant tracing."
        ),
    )
    parser.add_argument(
        "-assign-trace-depth",
        "--assign-trace-depth",
        type=int,
        default=2,
        help=(
            "maximum recursive continuation depth when NPI trace stops at a "
            "plain assign/pass-through net such as assign B = A. Use 0 to "
            "disable assign endpoint continuation."
        ),
    )
    parser.add_argument(
        "-assign-expr-trace-depth",
        "--assign-expr-trace-depth",
        type=int,
        default=1,
        help=(
            "maximum recursive continuation depth on driver/load paths when "
            "NPI stops at a continuous-assign expression endpoint such as "
            "assign A = {b0, b1} or assign B = {C, A, D}. "
            "Use 0 to disable expression continuation."
        ),
    )
    parser.add_argument(
        "-load-trace-node-limit",
        "--load-trace-node-limit",
        type=int,
        default=20000,
        help=(
            "maximum recursive loader trace nodes per target port. "
            "When reached, the CSV/XLSX result contains TRACE_LIMIT_REACHED instead of hanging. "
            "Use 0 to disable this guard."
        ),
    )
    parser.add_argument(
        "-load-trace-edge-limit",
        "--load-trace-edge-limit",
        type=int,
        default=100000,
        help=(
            "maximum recursive loader trace edges per target port. "
            "This caps wide fanout expansion in large designs. Use 0 to disable this guard."
        ),
    )
    parser.add_argument(
        "-load-trace-api-list-limit",
        "--load-trace-api-list-limit",
        type=int,
        default=20000,
        help=(
            "maximum number of handles consumed from one NPI loader API result list. "
            "Large lists are truncated and marked with TRACE_LIMIT_REACHED. Use 0 to disable."
        ),
    )
    parser.add_argument(
        "-verdi-timeout-sec",
        "--verdi-timeout-sec",
        type=int,
        default=0,
        help=(
            "optional wall-clock timeout in seconds for each Verdi NPI trace process. "
            "Use 0 to run without a timeout."
        ),
    )
    parser.add_argument(
        "-trace-debug",
        "--trace-debug",
        type=int,
        choices=(0, 1),
        default=0,
        help=(
            "when set to 1, print detailed NPI/source-fallback trace diagnostics "
            "for module-port continuation and assign fanout debugging"
        ),
    )
    parser.add_argument(
        "-log-file",
        "--log-file",
        default="",
        help=(
            "write script and Verdi/NPI diagnostic logs to this file. "
            "CSV data outputs are not redirected by this option."
        ),
    )
    parser.add_argument(
        "--match-cache-size",
        type=int,
        default=200000,
        help="maximum cached signal ownership decisions in --stream mode; 0 disables the cache",
    )
    parser.add_argument(
        "--keyword-batch-size",
        type=int,
        default=8,
        help=(
            "number of -keywords module names searched per Verdi process; "
            "smaller values reduce peak memory during instance search, 0 searches all at once"
        ),
    )
    parser.add_argument(
        "--keyword-continue-on-error",
        action="store_true",
        help="skip a keyword module if its instance search still fails after single-module retry",
    )
    parser.add_argument(
        "--keyword-log-instances",
        action="store_true",
        help="print every found keyword instance path while searching; off by default for large designs",
    )
    args = parser.parse_args()

    if sys.version_info < (3, 8):
        parser.error("Python 3.8 or newer is required.")
    if args.filelist or args.top or args.incdir:
        parser.error("KDB input is mandatory. Do not use -filelist, -top, or -incdir; use -lib <kdb.elab++>.")
    if not split_csv_arg(args.keywords):
        parser.error("-keywords expects one or more module definition names.")
    if args.subsystem_level < 0:
        parser.error("-subsystem-level must be 0 or a positive integer.")
    if args.match_cache_size < 0:
        parser.error("--match-cache-size must be 0 or a positive integer.")
    if args.keyword_batch_size < 0:
        parser.error("--keyword-batch-size must be 0 or a positive integer.")
    if args.const_trace_depth < 0:
        parser.error("-const-trace-depth must be 0 or a positive integer.")
    if args.assign_trace_depth < 0:
        parser.error("-assign-trace-depth must be 0 or a positive integer.")
    if args.assign_expr_trace_depth < 0:
        parser.error("-assign-expr-trace-depth must be 0 or a positive integer.")
    if args.load_trace_node_limit < 0:
        parser.error("-load-trace-node-limit must be 0 or a positive integer.")
    if args.load_trace_edge_limit < 0:
        parser.error("-load-trace-edge-limit must be 0 or a positive integer.")
    if args.load_trace_api_list_limit < 0:
        parser.error("-load-trace-api-list-limit must be 0 or a positive integer.")
    if args.verdi_timeout_sec < 0:
        parser.error("-verdi-timeout-sec must be 0 or a positive integer.")
    return args


def main() -> None:
    args = parse_args()
    setup_log_file(args.log_file)
    template = Path(args.template).expanduser().resolve()
    requested_output = Path(args.output).expanduser().resolve()
    output = bounded_path(
        requested_output,
        suffix=requested_output.suffix,
        identity=args.output,
    )
    if output != requested_output:
        log_step(
            f"filename_shortened original={requested_output.name} "
            f"bounded={output.name} identity={args.output}"
        )
    existing_output_modes = collect_existing_output_modes(output)
    if args.subsystem_level:
        cleanup_subsystem_outputs(template, output)
    elif output.resolve() != template.resolve():
        remove_intermediate_file(output, "stale annotation output")
    output_transaction = (
        OutputTransaction(protected_paths={template.resolve()})
        if args.subsystem_level
        else None
    )

    lib = Path(args.lib).expanduser()
    if not lib.is_absolute():
        lib = RUN_CWD / lib
    lib = lib.resolve()
    if not lib.exists():
        raise FileNotFoundError(f"KDB not found: {lib}")
    if not path_has_contents(lib):
        raise RuntimeError(
            f"KDB path is empty: {lib}. Rebuild with VCS -kdb before running annotation."
        )
    args.lib = str(lib)

    if not template.exists():
        cli_modules = split_csv_arg(args.module)
        cli_ports = split_csv_arg(args.ports)
        if cli_modules and cli_ports:
            create_minimal_template(template, cli_modules, cli_ports, args.sheet)
        else:
            raise FileNotFoundError(
                f"template not found: {template}. Pass both -module and -ports "
                "to auto-create a minimal template."
            )

    if args.workdir:
        workdir = Path(args.workdir).expanduser().resolve()
    else:
        workdir = RUN_CWD.resolve()
    workdir.mkdir(parents=True, exist_ok=True)

    log_step(f"python={sys.version.split()[0]} executable={sys.executable}")
    log_step(f"openpyxl={openpyxl.__version__}")
    log_step(f"run_cwd={RUN_CWD}")
    log_step(f"template={template}")
    log_step(f"output={output}")
    log_step(f"lib={args.lib}")
    log_step(f"kdebug_bin={args.kdebug_bin or '<auto>'}")
    log_step(f"workdir={workdir}")
    log_step(f"const_source_fallback={args.const_source_fallback}")
    log_step(f"const_trace_depth={args.const_trace_depth}")
    log_step(f"assign_trace_depth={args.assign_trace_depth}")
    log_step(f"assign_expr_trace_depth={args.assign_expr_trace_depth}")
    log_step(f"load_trace_node_limit={args.load_trace_node_limit}")
    log_step(f"load_trace_edge_limit={args.load_trace_edge_limit}")
    log_step(f"load_trace_api_list_limit={args.load_trace_api_list_limit}")
    log_step(f"verdi_timeout_sec={args.verdi_timeout_sec}")

    try:
        workbook, sheet = load_workbook(template, args.sheet)
        try:
            modules, ports = extract_modules_and_ports(sheet, args.module, args.ports)
        finally:
            workbook.close()
        log_step(f"modules={','.join(modules)}")
        log_step(f"ports={','.join(ports)}")

        filter_instances, instance_file = find_filter_instances(args, workdir)
        log_step(f"filter_instance_file={instance_file}")

        subsystems = set()
        param_rows, param_file, param_error = find_module_parameters(args, modules, workdir)
        log_step(f"module_parameter_file={param_file}")
        params_by_module: Dict[str, List[ParamRow]] = {}
        params_by_module_subsystem: Dict[str, Dict[str, List[ParamRow]]] = {}
        param_errors_by_module: Dict[str, str] = {}
        param_errors_by_module_subsystem: Dict[str, Dict[str, str]] = {}
        if param_error is not None:
            param_errors_by_module = {module: param_error for module in modules}
        for row in param_rows:
            params_by_module.setdefault(row.module, []).append(row)
        if args.subsystem_level:
            for module, rows in params_by_module.items():
                by_subsystem = split_params_by_subsystem(rows, args.subsystem_level)
                params_by_module_subsystem[module] = by_subsystem
                subsystems.update(by_subsystem)
                log_step(
                    "module={} parameter_subsystem_count={} subsystem_level={}".format(
                        module, len(by_subsystem), args.subsystem_level
                    )
                )
            if param_error is not None:
                # The exact subsystem list may only be known after trace rows are
                # loaded. It is filled below before writing workbooks.
                param_errors_by_module_subsystem = {module: {} for module in modules}

        if args.stream:
            log_step(
                "stream_mode=enabled match_cache_size={} filter_instance_count={}".format(
                    args.match_cache_size,
                    len(filter_instances),
                )
            )
            module_port_results: Dict[str, Dict[str, Dict[str, str]]] = {}
            module_errors: Dict[str, str] = {}
            module_port_results_by_subsystem: Dict[str, Dict[str, Dict[str, Dict[str, str]]]] = {}

            if args.subsystem_level:
                filter_instances_by_subsystem = split_instances_by_subsystem(
                    filter_instances,
                    args.subsystem_level,
                )
                matchers_by_subsystem = {
                    subsystem: InstanceMatcher(instances, args.match_cache_size)
                    for subsystem, instances in filter_instances_by_subsystem.items()
                }
                for subsystem, matcher in sorted(matchers_by_subsystem.items()):
                    log_step(
                        "stream matcher subsystem={} filter_instances={} prefixes={}".format(
                            subsystem,
                            len(filter_instances_by_subsystem.get(subsystem, [])),
                            len(matcher.prefixes),
                        )
                    )
            else:
                matcher = InstanceMatcher(filter_instances, args.match_cache_size)
                matchers_by_subsystem = None
                log_step(
                    "stream matcher filter_instances={} prefixes={}".format(
                        len(filter_instances),
                        len(matcher.prefixes),
                    )
                )

            for module in modules:
                log_step(f"trace module: {module}")
                try:
                    full_csv, module_csv = trace_module(
                        args,
                        module,
                        ports,
                        workdir,
                        instance_file,
                    )
                    log_step(f"module_boundary_debug_csv={module_csv}")
                    if args.subsystem_level:
                        _, subsystem_results, module_subsystems, total_rows = stream_trace_results(
                            [full_csv, module_csv],
                            ports,
                            subsystem_level=args.subsystem_level,
                            matchers_by_subsystem=matchers_by_subsystem,
                            regcombo_as_keyword=bool(args.regcombo_as_keyword),
                        )
                        module_port_results_by_subsystem[module] = subsystem_results
                        subsystems.update(module_subsystems)
                        log_step(
                            "stream loaded trace rows for {}: {} subsystem_count={}".format(
                                module,
                                total_rows,
                                len(subsystem_results),
                            )
                        )
                    else:
                        results, _, _, total_rows = stream_trace_results(
                            [full_csv, module_csv],
                            ports,
                            matcher=matcher,
                            regcombo_as_keyword=bool(args.regcombo_as_keyword),
                        )
                        module_port_results[module] = results
                        log_step(f"stream loaded trace rows for {module}: {total_rows}")
                except (subprocess.SubprocessError, TraceOutputError) as exc:
                    marker = trace_failure_marker(exc)
                    module_errors[module] = marker
                    log_step(
                        "module={} trace_status=failed marker={} error_type={} error={}".format(
                            module, marker, type(exc).__name__, exc
                        )
                    )

            if args.subsystem_level:
                for module, error in module_errors.items():
                    if (
                        not module_port_results_by_subsystem.get(module)
                        and not params_by_module_subsystem.get(module)
                    ):
                        log_step(
                            "module={} trace_status=failed subsystem_topology=none "
                            "action=omit_from_subsystem_outputs error={}".format(
                                module, error
                            )
                        )
                if not subsystems:
                    raise RuntimeError("no subsystem instances found in streamed trace rows")
                for subsystem in sorted(subsystems):
                    log_step(f"write subsystem workbook: {subsystem}")
                    subsystem_modules = select_subsystem_modules(
                        modules,
                        subsystem,
                        module_port_results_by_subsystem,
                        params_by_module_subsystem,
                        module_errors,
                    )
                    skipped_modules = [
                        module for module in modules if module not in subsystem_modules
                    ]
                    log_step(
                        "subsystem={} output_modules={} skipped_modules={}".format(
                            subsystem,
                            ",".join(subsystem_modules) or "<none>",
                            ",".join(skipped_modules) or "<none>",
                        )
                    )
                    subsystem_results: Dict[str, Dict[str, Dict[str, str]]] = {}
                    subsystem_errors: Dict[str, str] = {}
                    subsystem_params: Dict[str, Sequence[ParamRow]] = {}
                    subsystem_param_errors: Dict[str, str] = {}
                    for module in subsystem_modules:
                        subsystem_params[module] = params_by_module_subsystem.get(module, {}).get(
                            subsystem,
                            [],
                        )
                        if module in param_errors_by_module:
                            subsystem_param_errors[module] = param_errors_by_module[module]
                        elif module in param_errors_by_module_subsystem:
                            error = param_errors_by_module_subsystem[module].get(subsystem)
                            if error is not None:
                                subsystem_param_errors[module] = error

                        if module in module_errors:
                            subsystem_errors[module] = module_errors[module]
                            continue
                        results = module_port_results_by_subsystem.get(module, {}).get(subsystem)
                        if results is None:
                            subsystem_errors[module] = "NO_TRACE"
                        else:
                            subsystem_results[module] = results

                    assert output_transaction is not None
                    subsystem_output = output_transaction.track(
                        split_output_path(output, subsystem)
                    )
                    write_annotation_results_workbook(
                        template=template,
                        sheet_name=args.sheet,
                        output=subsystem_output,
                        modules=subsystem_modules,
                        ports=ports,
                        module_port_results=subsystem_results,
                        module_params=subsystem_params,
                        module_errors=subsystem_errors,
                        module_param_errors=subsystem_param_errors,
                        missing_marker="NO_TRACE",
                        output_mode=existing_output_modes.get(subsystem_output),
                    )
            else:
                write_annotation_results_workbook(
                    template=template,
                    sheet_name=args.sheet,
                    output=output,
                    modules=modules,
                    ports=ports,
                    module_port_results=module_port_results,
                    module_params=params_by_module,
                    module_errors=module_errors,
                    module_param_errors=param_errors_by_module,
                    output_mode=existing_output_modes.get(output),
                )
            if output_transaction is not None:
                output_transaction.commit()
            return

        module_traces: Dict[str, ModuleTrace] = {}
        rows_by_module_subsystem: Dict[str, Dict[str, List[TraceRow]]] = {}
        for module in modules:
            log_step(f"trace module: {module}")
            try:
                full_csv, module_csv = trace_module(
                    args,
                    module,
                    ports,
                    workdir,
                    instance_file,
                )
                log_step(f"module_boundary_debug_csv={module_csv}")
                rows = read_trace_rows([full_csv, module_csv])
                log_step(f"loaded trace rows for {module}: {len(rows)}")
                module_traces[module] = ModuleTrace(rows=rows)
                if args.subsystem_level:
                    by_subsystem = split_rows_by_subsystem(rows, args.subsystem_level)
                    rows_by_module_subsystem[module] = by_subsystem
                    subsystems.update(by_subsystem)
                    log_step(
                        "module={} subsystem_count={} subsystem_level={}".format(
                            module, len(by_subsystem), args.subsystem_level
                        )
                    )
            except (subprocess.SubprocessError, TraceOutputError) as exc:
                marker = trace_failure_marker(exc)
                module_traces[module] = ModuleTrace(rows=[], error=marker)
                log_step(
                    "module={} trace_status=failed marker={} error_type={} error={}".format(
                        module, marker, type(exc).__name__, exc
                    )
                )

        if args.subsystem_level:
            for module, trace in module_traces.items():
                if (
                    trace.error is not None
                    and not rows_by_module_subsystem.get(module)
                    and not params_by_module_subsystem.get(module)
                ):
                    log_step(
                        "module={} trace_status=failed subsystem_topology=none "
                        "action=omit_from_subsystem_outputs error={}".format(
                            module, trace.error
                        )
                    )
            if not subsystems:
                raise RuntimeError("no subsystem instances found in full trace rows")
            filter_instances_by_subsystem = split_instances_by_subsystem(
                filter_instances,
                args.subsystem_level,
            )
            trace_errors = {
                module: trace.error
                for module, trace in module_traces.items()
                if trace.error is not None
            }
            for subsystem in sorted(subsystems):
                log_step(f"write subsystem workbook: {subsystem}")
                subsystem_filter_instances = filter_instances_by_subsystem.get(subsystem, [])
                log_step(
                    "subsystem={} filter_instance_count={}".format(
                        subsystem, len(subsystem_filter_instances)
                    )
                )
                subsystem_modules = select_subsystem_modules(
                    modules,
                    subsystem,
                    rows_by_module_subsystem,
                    params_by_module_subsystem,
                    trace_errors,
                )
                skipped_modules = [
                    module for module in modules if module not in subsystem_modules
                ]
                log_step(
                    "subsystem={} output_modules={} skipped_modules={}".format(
                        subsystem,
                        ",".join(subsystem_modules) or "<none>",
                        ",".join(skipped_modules) or "<none>",
                    )
                )
                subsystem_traces: Dict[str, ModuleTrace] = {}
                subsystem_params: Dict[str, Sequence[ParamRow]] = {}
                subsystem_param_errors: Dict[str, str] = {}
                for module in subsystem_modules:
                    subsystem_params[module] = params_by_module_subsystem.get(module, {}).get(
                        subsystem,
                        [],
                    )
                    if module in param_errors_by_module:
                        subsystem_param_errors[module] = param_errors_by_module[module]
                    elif module in param_errors_by_module_subsystem:
                        error = param_errors_by_module_subsystem[module].get(subsystem)
                        if error is not None:
                            subsystem_param_errors[module] = error
                    trace = module_traces[module]
                    if trace.error is not None:
                        subsystem_traces[module] = trace
                        continue
                    subsystem_rows = rows_by_module_subsystem.get(module, {}).get(subsystem)
                    if subsystem_rows is None:
                        subsystem_traces[module] = ModuleTrace(
                            rows=[],
                            error="NO_TRACE",
                        )
                    else:
                        subsystem_traces[module] = ModuleTrace(rows=subsystem_rows)
                assert output_transaction is not None
                subsystem_output = output_transaction.track(
                    split_output_path(output, subsystem)
                )
                write_annotation_workbook(
                    template=template,
                    sheet_name=args.sheet,
                    output=subsystem_output,
                    modules=subsystem_modules,
                    ports=ports,
                    module_traces=subsystem_traces,
                    module_params=subsystem_params,
                    module_param_errors=subsystem_param_errors,
                    filter_instances=subsystem_filter_instances,
                    missing_marker="NO_TRACE",
                    regcombo_as_keyword=bool(args.regcombo_as_keyword),
                    output_mode=existing_output_modes.get(subsystem_output),
                )
        else:
            write_annotation_workbook(
                template=template,
                sheet_name=args.sheet,
                output=output,
                modules=modules,
                ports=ports,
                module_traces=module_traces,
                module_params=params_by_module,
                module_param_errors=param_errors_by_module,
                filter_instances=filter_instances,
                regcombo_as_keyword=bool(args.regcombo_as_keyword),
                output_mode=existing_output_modes.get(output),
            )
        if output_transaction is not None:
            output_transaction.commit()
    finally:
        if output_transaction is not None:
            output_transaction.rollback_if_uncommitted()
        log_step(f"intermediate files kept in workdir={workdir}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log_step(f"ERROR: {exc}")
        sys.exit(1)
