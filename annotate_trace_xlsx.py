#!/usr/bin/env python3
"""
Annotate an XLSX trace template with NPI yes/no connectivity results.

Template layout:
  - column A, row 2..N: target module definition names
  - column B: generated instance parameter summary
  - row 1, column C..N: target port names

Each module/port intersection is filled with:
  - yes: at least one driver/load endpoint belongs to an instance of -keywords
  - no: no such endpoint is found
  - markers such as driver=Const:'b1, driver=NO_DRIVER, load=NO_LOAD, NO_TRACE

This version targets Python 3.8+ and uses openpyxl for robust XLSX editing.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import subprocess
import sys
from copy import copy
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

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


def path_has_contents(path: Path) -> bool:
    if path.is_file():
        return path.stat().st_size > 0
    if path.is_dir():
        return any(path.iterdir())
    return False


@dataclass(frozen=True)
class TraceRow:
    inst_full_name: str
    port_name: str
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
    parameter_style_cell: Optional[object]


@dataclass
class ModuleTrace:
    rows: Sequence[TraceRow]
    error: Optional[str] = None


def log_step(message: str) -> None:
    print(f"[annotate_trace_xlsx] {message}", file=sys.stderr)


def split_csv_arg(text: str) -> List[str]:
    return [item.strip() for item in text.split(",") if item.strip()] if text else []


def safe_name(text: str) -> str:
    text = re.sub(r"[^A-Za-z0-9_.-]+", "_", text)
    return text.strip("._") or "unnamed"


def cell_text(value: object) -> str:
    if value is None:
        return ""
    return str(value).strip()


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

    sheet.cell(row=1, column=1, value="module")
    sheet.cell(row=1, column=2, value="parameters")
    for col, port in enumerate(ports, start=3):
        sheet.cell(row=1, column=col, value=port)
    for row, module in enumerate(modules, start=2):
        sheet.cell(row=row, column=1, value=module)

    sheet.column_dimensions["A"].width = 24
    sheet.column_dimensions["B"].width = 48
    for col in range(3, 3 + len(ports)):
        sheet.column_dimensions[openpyxl.utils.get_column_letter(col)].width = 16

    header_font = openpyxl.styles.Font(bold=True)
    header_fill = openpyxl.styles.PatternFill("solid", fgColor="D9EAF7")
    thin = openpyxl.styles.Side(style="thin", color="A6A6A6")
    border = openpyxl.styles.Border(left=thin, right=thin, top=thin, bottom=thin)
    for row in sheet.iter_rows(
        min_row=1,
        max_row=max(2, 1 + len(modules)),
        min_col=1,
        max_col=max(3, 2 + len(ports)),
    ):
        for cell in row:
            cell.border = border
            cell.alignment = openpyxl.styles.Alignment(vertical="top", wrap_text=True)
            if cell.row == 1:
                cell.font = header_font
                cell.fill = header_fill

    template_path.parent.mkdir(parents=True, exist_ok=True)
    workbook.save(template_path)
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
        for col in range(3, sheet.max_column + 1):
            value = cell_text(sheet.cell(row=1, column=col).value)
            if value:
                ports.append(value)

    if not modules:
        raise ValueError("no modules found; fill column A or pass -module")
    if not ports:
        raise ValueError("no ports found; fill row 1 from column C or pass -ports")
    return modules, ports


def prepare_template_axes(sheet, modules: Sequence[str], ports: Sequence[str]) -> TemplateAxes:
    row_by_module: Dict[str, int] = {}
    col_by_port: Dict[str, int] = {}

    for row in range(2, sheet.max_row + 1):
        value = cell_text(sheet.cell(row=row, column=1).value)
        if value:
            row_by_module.setdefault(value, row)

    for col in range(3, sheet.max_column + 1):
        value = cell_text(sheet.cell(row=1, column=col).value)
        if value:
            col_by_port.setdefault(value, col)

    next_row = max(sheet.max_row + 1, 2)
    next_col = max(sheet.max_column + 1, 3)

    body_style_cell = sheet.cell(row=2, column=3)
    module_style_cell = sheet.cell(row=2, column=1)
    header_style_cell = sheet.cell(row=1, column=3)
    parameter_style_cell = sheet.cell(row=2, column=2)

    parameter_header = sheet.cell(row=1, column=2)
    if not cell_text(parameter_header.value):
        parameter_header.value = "parameters"
        copy_cell_style(parameter_header, header_style_cell)
        log_step("set parameter header: column=B value=parameters")

    for module in modules:
        if module in row_by_module:
            continue
        row_by_module[module] = next_row
        cell = sheet.cell(row=next_row, column=1, value=module)
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
        parameter_style_cell=parameter_style_cell,
    )


def set_parameter_cell(sheet, axes: TemplateAxes, module: str, result: str) -> None:
    row = axes.row_by_module[module]
    cell = sheet.cell(row=row, column=2, value=result)
    copy_cell_style(cell, axes.parameter_style_cell or axes.body_style_cell)
    alignment = copy(cell.alignment)
    alignment.wrap_text = True
    if alignment.vertical is None:
        alignment.vertical = "top"
    cell.alignment = alignment
    current_width = sheet.column_dimensions["B"].width or 0
    if current_width < 36:
        sheet.column_dimensions["B"].width = 36


def set_result_cell(sheet, axes: TemplateAxes, module: str, port: str, result: str) -> None:
    row = axes.row_by_module[module]
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


def split_output_path(output: Path, subsystem: str) -> Path:
    return output.with_name(f"{output.stem}__subsys_{safe_name(subsystem)}{output.suffix}")


def format_module_params(module: str, param_rows: Sequence[ParamRow]) -> str:
    rows = [row for row in param_rows if row.module == module]
    if not rows:
        return "NO_PARAMETER"

    parameters = [row for row in rows if row.param_kind != "localparam"]
    if not parameters:
        return f"NO_PARAMETER; localparam_count={len(rows)}"

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
) -> None:
    workbook, sheet = load_workbook(template, sheet_name)
    axes = prepare_template_axes(sheet, modules, ports)
    module_param_errors = module_param_errors or {}

    for module in modules:
        trace = module_traces.get(module, ModuleTrace(rows=[], error=missing_marker))
        if module in module_param_errors:
            param_text = module_param_errors[module]
        else:
            param_text = format_module_params(module, module_params.get(module, []))
        if param_text == "NO_PARAMETER" and trace.error is not None:
            param_text = trace.error
        log_step(f"parameter cell module={module} result={param_text}")
        set_parameter_cell(sheet, axes, module, param_text)
        for port in ports:
            if trace.error is not None:
                result = trace.error
            else:
                result = summarize_port(trace.rows, port, filter_instances)
            log_step(f"cell module={module} port={port} result={result}")
            set_result_cell(sheet, axes, module, port, result)

    output.parent.mkdir(parents=True, exist_ok=True)
    workbook.save(output)
    log_step(f"done output={output}")


def run_checked(
    cmd: Sequence[object],
    cwd: Path,
    stdout_path: Optional[Path] = None,
    env: Optional[Dict[str, str]] = None,
) -> None:
    text_cmd = " ".join(str(x) for x in cmd)
    log_step(f"command: {text_cmd}")
    if stdout_path is not None:
        with stdout_path.open("w", encoding="utf-8", newline="") as out:
            subprocess.run(
                [str(x) for x in cmd],
                cwd=str(cwd),
                env=env,
                stdout=out,
                stderr=sys.stderr,
                check=True,
            )
    else:
        subprocess.run(
            [str(x) for x in cmd],
            cwd=str(cwd),
            env=env,
            stdout=sys.stderr,
            stderr=sys.stderr,
            check=True,
        )


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
    out_file = workdir / f"{safe_name(args.keywords)}_instances.txt"
    env = os.environ.copy()
    env["NPI_LIB"] = args.lib
    env["NPI_FILTER_MODULE"] = args.keywords
    env["NPI_FILTER_MODULES"] = args.keywords
    env["NPI_INSTANCE_OUTFILE"] = str(out_file)

    run_checked(
        ["verdi", "-batch", "-nologo", "-play", SCRIPT_DIR / "npi_find_instances.tcl"],
        cwd=RUN_CWD,
        env=env,
    )

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
    if args.no_params:
        log_step("skip module parameter collection because --no-params is set")
        return [], out_file, "PARAM_SKIPPED"

    env = os.environ.copy()
    env["NPI_LIB"] = args.lib
    env["NPI_PARAM_MODULES"] = ",".join(modules)
    env["NPI_PARAM_OUTFILE"] = str(out_file)

    try:
        run_checked(
            ["verdi", "-batch", "-nologo", "-play", SCRIPT_DIR / "npi_find_module_params.tcl"],
            cwd=RUN_CWD,
            env=env,
        )
    except subprocess.CalledProcessError as exc:
        if args.strict_params:
            raise
        message = f"PARAM_TRACE_FAILED: {exc}"
        log_step(message)
        if out_file.exists() and out_file.stat().st_size > 0:
            try:
                return read_param_rows(out_file), out_file, message
            except Exception as read_exc:
                log_step(f"parameter csv read failed after Tcl error: {read_exc}")
        return [], out_file, message

    return read_param_rows(out_file), out_file, None


def strip_instance_prefix(signal_name: str, inst: str) -> Optional[str]:
    if signal_name == inst:
        return ""
    if signal_name.startswith(inst + "."):
        return signal_name[len(inst) + 1 :]
    if signal_name.startswith(inst + "/"):
        return signal_name[len(inst) + 1 :]
    return None


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

        # npi_port_trace.tcl may remove a common top prefix for readability.
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
                    role=row.get("role", ""),
                    signal_full_name=signal,
                )
                key = (
                    normalized.inst_full_name,
                    normalized.port_name,
                    normalized.role,
                    normalized.signal_full_name,
                )
                if key in seen:
                    continue
                seen.add(key)
                rows.append(normalized)
    return rows


def trace_module(args, module: str, ports: Sequence[str], workdir: Path) -> Tuple[Path, Path]:
    full_csv = workdir / f"{safe_name(module)}_full.csv"
    module_csv = workdir / f"{safe_name(module)}_module_connections.csv"
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

    run_checked(cmd, cwd=RUN_CWD, stdout_path=full_csv)
    return full_csv, module_csv


def summarize_port(rows: Sequence[TraceRow], port: str, filter_instances: Sequence[str]) -> str:
    port_rows = [row for row in rows if row.port_name == port]
    if not port_rows:
        return "no; NO_TRACE"

    matched = any(
        signal_belongs_to_instance(row.signal_full_name, filter_instances)
        for row in port_rows
    )
    details: List[str] = []
    for row in port_rows:
        role = row.role or "unknown"
        signal = row.signal_full_name or ""
        if signal.startswith("Const:"):
            details.append(f"{role}={signal}")
        elif signal in {"NO_DRIVER", "NO_LOAD", "ERROR:no_connections"} or signal.startswith("ERROR:"):
            details.append(f"{role}={signal}")

    unique_details = list(dict.fromkeys(details))
    result = "yes" if matched else "no"
    if unique_details:
        result += "; " + "; ".join(unique_details)
    return result


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
        help="comma-separated target ports; defaults to row 1 from column C",
    )
    parser.add_argument("-lib", required=True, help="KDB path, for example kdb.elab++")
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
    args = parser.parse_args()

    if sys.version_info < (3, 8):
        parser.error("Python 3.8 or newer is required.")
    if args.filelist or args.top or args.incdir:
        parser.error("KDB input is mandatory. Do not use -filelist, -top, or -incdir; use -lib <kdb.elab++>.")
    if not split_csv_arg(args.keywords):
        parser.error("-keywords expects one or more module definition names.")
    if args.subsystem_level < 0:
        parser.error("-subsystem-level must be 0 or a positive integer.")
    return args


def main() -> None:
    args = parse_args()
    template = Path(args.template).expanduser().resolve()
    output = Path(args.output).expanduser().resolve()
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
    log_step(f"workdir={workdir}")

    try:
        workbook, sheet = load_workbook(template, args.sheet)
        modules, ports = extract_modules_and_ports(sheet, args.module, args.ports)
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

        module_traces: Dict[str, ModuleTrace] = {}
        rows_by_module_subsystem: Dict[str, Dict[str, List[TraceRow]]] = {}
        for module in modules:
            log_step(f"trace module: {module}")
            try:
                full_csv, module_csv = trace_module(args, module, ports, workdir)
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
            except subprocess.CalledProcessError as exc:
                module_traces[module] = ModuleTrace(rows=[], error="NO_MODULE")
                log_step(f"module {module} trace failed: {exc}")

        if args.subsystem_level:
            if not subsystems:
                raise RuntimeError("no subsystem instances found in full trace rows")
            filter_instances_by_subsystem = split_instances_by_subsystem(
                filter_instances,
                args.subsystem_level,
            )
            for subsystem in sorted(subsystems):
                log_step(f"write subsystem workbook: {subsystem}")
                subsystem_filter_instances = filter_instances_by_subsystem.get(subsystem, [])
                log_step(
                    "subsystem={} filter_instance_count={}".format(
                        subsystem, len(subsystem_filter_instances)
                    )
                )
                subsystem_traces: Dict[str, ModuleTrace] = {}
                subsystem_params: Dict[str, Sequence[ParamRow]] = {}
                subsystem_param_errors: Dict[str, str] = {}
                for module in modules:
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
                            error="NO_SUBSYSTEM_INSTANCE",
                        )
                    else:
                        subsystem_traces[module] = ModuleTrace(rows=subsystem_rows)
                write_annotation_workbook(
                    template=template,
                    sheet_name=args.sheet,
                    output=split_output_path(output, subsystem),
                    modules=modules,
                    ports=ports,
                    module_traces=subsystem_traces,
                    module_params=subsystem_params,
                    module_param_errors=subsystem_param_errors,
                    filter_instances=subsystem_filter_instances,
                    missing_marker="NO_SUBSYSTEM_INSTANCE",
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
            )
    finally:
        log_step(f"intermediate files kept in workdir={workdir}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log_step(f"ERROR: {exc}")
        sys.exit(1)
