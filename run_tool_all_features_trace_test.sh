#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

csv_from_list() {
  grep -v '^[[:space:]]*$' "$1" | grep -v '^[[:space:]]*#' | paste -sd, -
}

MODULES="$(csv_from_list tool_all_features_modules.list)"
KEYWORDS="$(csv_from_list tool_all_features_keywords.list)"
PORTS="$(csv_from_list tool_all_features_ports.list)"

echo "[tool_all_features] cwd=$PWD"
echo "[tool_all_features] modules=$MODULES"
echo "[tool_all_features] keywords=$KEYWORDS"
echo "[tool_all_features] ports=$PORTS"

echo "[tool_all_features] verify one module per RTL file"
python3 - <<'PY'
from pathlib import Path
bad = []
for path in sorted(Path(".").glob("tool_all_features_*.v")):
    count = sum(1 for line in path.read_text().splitlines() if line.strip().startswith("module "))
    if count != 1:
        bad.append((path.name, count))
if bad:
    raise SystemExit(f"one-module-per-file check failed: {bad}")
print("[tool_all_features] one-module-per-file check passed")
PY

echo "[tool_all_features] clean previous outputs for this test only"
rm -rf tool_all_features_trace_build
rm -f tool_all_features_trace_vcs.log
rm -f tool_all_features_trace_template.xlsx
rm -f tool_all_features_gui_command.log tool_all_features_gui_xlsx.log
rm -f tool_all_features_raw_full.csv tool_all_features_raw_module.csv tool_all_features_raw.log
rm -f tool_all_features_filtered.csv tool_all_features_filtered_boundary.csv tool_all_features_filtered_full_owner.csv
rm -f tool_all_features_filtered__*.csv tool_all_features_filter.log
rm -f tool_all_features_annotated.xlsx tool_all_features_annotated__subsys_*.xlsx tool_all_features_annotate.log
rm -f TAFTarget_full.csv TAFTarget_module_connections.csv
rm -f TAFAuxTarget_full.csv TAFAuxTarget_module_connections.csv
rm -f TAFLeaf_full.csv TAFLeaf_module_connections.csv
rm -f TAFKeySrc_full.csv TAFKeySrc_module_connections.csv
rm -f TAFKeySink_full.csv TAFKeySink_module_connections.csv
rm -f TAFTarget_TAFKeySrc_TAFKeySink_instances.txt
rm -f TAFAuxTarget_TAFKeySrc_TAFKeySink_instances.txt
rm -f TAFLeaf_TAFKeySrc_TAFKeySink_instances.txt
rm -f TAFKeySrc_TAFKeySink_instances.txt

echo "[tool_all_features] create xlsx template"
python3 - <<'PY'
from pathlib import Path
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

modules = [
    line.strip()
    for line in Path("tool_all_features_modules.list").read_text().splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
ports = [
    line.strip()
    for line in Path("tool_all_features_ports.list").read_text().splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
wb = Workbook()
ws = wb.active
ws.title = "Trace"
headers = ["module", "instance", "parameters"] + ports
ws.append(headers)
for module in modules:
    ws.append([module])

header_fill = PatternFill("solid", fgColor="D9EAF7")
body_fill = PatternFill("solid", fgColor="FFFFFF")
thin = Side(style="thin", color="B7C7D9")
border = Border(left=thin, right=thin, top=thin, bottom=thin)
for row in ws.iter_rows(min_row=1, max_row=ws.max_row, max_col=ws.max_column):
    for cell in row:
        cell.border = border
        cell.alignment = Alignment(wrap_text=True, vertical="top")
        cell.fill = header_fill if cell.row == 1 else body_fill
        if cell.row == 1:
            cell.font = Font(bold=True)
for col_idx, header in enumerate(headers, start=1):
    ws.column_dimensions[get_column_letter(col_idx)].width = min(max(len(str(header)) + 4, 14), 44)
ws.freeze_panes = "A2"
wb.save("tool_all_features_trace_template.xlsx")
print("[tool_all_features] template=tool_all_features_trace_template.xlsx")
PY

echo "[tool_all_features] verify GUI command builder"
python3 trace_gui.py --build-command tool_all_features_gui_xlsx.json | tee tool_all_features_gui_command.log
grep -q "annotate_trace_xlsx.sh" tool_all_features_gui_command.log
grep -q "TAFTarget,TAFAuxTarget,TAFLeaf" tool_all_features_gui_command.log
grep -q "TAFKeySrc,TAFKeySink" tool_all_features_gui_command.log
grep -q "drv_precise_bus\\[7\\]" tool_all_features_gui_command.log
grep -q "drv_wide_bit" tool_all_features_gui_command.log
grep -q "drv_ternary_stop" tool_all_features_gui_command.log
grep -q -- "--stream" tool_all_features_gui_command.log
grep -q -- "-regcombo-as-keyword 1" tool_all_features_gui_command.log
grep -q -- "-trace-debug 0" tool_all_features_gui_command.log
grep -q -- "-log-file tool_all_features_gui_xlsx.log" tool_all_features_gui_command.log

echo "[tool_all_features] build KDB"
mkdir -p tool_all_features_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top TAFAllFeatureTop -f tool_all_features_trace_test.f \
  -Mdir=tool_all_features_trace_build/csrc \
  -o tool_all_features_trace_build/simv \
  -l tool_all_features_trace_vcs.log
vcs_rc=$?
set -e
if [ ! -d tool_all_features_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[tool_all_features] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 100 tool_all_features_trace_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[tool_all_features] KDB OK, vcs_rc=$vcs_rc"

echo "[tool_all_features] run raw NPI trace with debug log"
./npi_trace.sh \
  -module TAFTarget \
  -lib "$(pwd)/tool_all_features_trace_build/simv.daidir/kdb.elab++" \
  -ports "drv_wide_bit,drv_ternary_stop" \
  -module-out tool_all_features_raw_module.csv \
  -const-source-fallback 1 \
  -const-trace-depth 12 \
  -assign-trace-depth 18 \
  -assign-expr-trace-depth 8 \
  -trace-debug 0 \
  -log-file tool_all_features_raw.log \
  > tool_all_features_raw_full.csv

echo "[tool_all_features] run CSV filter"
./trace_and_filter.sh \
  -module TAFTarget \
  -lib "$(pwd)/tool_all_features_trace_build/simv.daidir/kdb.elab++" \
  -keywords "$KEYWORDS" \
  -ports "$PORTS" \
  -output tool_all_features_filtered.csv \
  --keyword-batch-size 1 \
  --keyword-log-instances \
  -const-source-fallback 1 \
  -const-trace-depth 12 \
  -assign-trace-depth 18 \
  -assign-expr-trace-depth 8 \
  -trace-debug 0 \
  -log-file tool_all_features_filter.log

echo "[tool_all_features] run XLSX annotation"
./annotate_trace_xlsx.sh \
  -template tool_all_features_trace_template.xlsx \
  -output tool_all_features_annotated.xlsx \
  -lib tool_all_features_trace_build/simv.daidir/kdb.elab++ \
  -keywords "$KEYWORDS" \
  -module "$MODULES" \
  -ports "$PORTS" \
  -subsystem-level 2 \
  --stream \
  -regcombo-as-keyword 1 \
  -const-source-fallback 1 \
  -const-trace-depth 12 \
  -assign-trace-depth 18 \
  -assign-expr-trace-depth 8 \
  -trace-debug 0 \
  --match-cache-size 200000 \
  --keyword-batch-size 1 \
  --keyword-log-instances \
  -log-file tool_all_features_annotate.log

echo "[tool_all_features] assert CSV, XLSX, and debug log results"
python3 - <<'PY'
import csv
import re
from pathlib import Path
from openpyxl import load_workbook

full_rows = list(csv.DictReader(Path("TAFTarget_full.csv").open()))
filtered_rows = list(csv.DictReader(Path("tool_all_features_filtered.csv").open()))
raw_text = Path("tool_all_features_raw.log").read_text(errors="replace")
filter_text = Path("tool_all_features_filter.log").read_text(errors="replace")
annotate_text = Path("tool_all_features_annotate.log").read_text(errors="replace")

def full_signals(port, role):
    return [
        r["signal_full_name"]
        for r in full_rows
        if r["port_name"] == port and r["role"] == role
    ]

def full_has(port, role, token):
    return any(token in sig for sig in full_signals(port, role))

def filtered_has(port, role, token):
    return any(
        r["port_name"] == port and r["role"] == role and token in r["signal_full_name"]
        for r in filtered_rows
    )

def require_full(port, role, token):
    if not full_has(port, role, token):
        raise SystemExit(f"missing full trace token port={port} role={role} token={token} got={full_signals(port, role)[:80]}")

def reject_full(port, role, token):
    if full_has(port, role, token):
        raise SystemExit(f"unexpected full trace token port={port} role={role} token={token} got={full_signals(port, role)[:80]}")

def require_filtered(port, role, token):
    if not filtered_has(port, role, token):
        got = [r["signal_full_name"] for r in filtered_rows if r["port_name"] == port and r["role"] == role]
        raise SystemExit(f"missing filtered token port={port} role={role} token={token} got={got[:80]}")

def reject_filtered_port(port, role):
    got = [r["signal_full_name"] for r in filtered_rows if r["port_name"] == port and r["role"] == role]
    if got:
        raise SystemExit(f"unexpected filtered rows for port={port} role={role}: {got[:80]}")

def log_fields(line):
    return {
        match.group(1): match.group(2).strip("{}")
        for match in re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)=(\{[^}]*\}|\S+)", line)
    }

const_evidence = [
    log_fields(line)
    for line in filter_text.splitlines()
    if "const_driver_source_detail " in line
]

def require_const_evidence(port):
    expected = sorted({
        (r["inst_full_name"], r["signal_full_name"])
        for r in full_rows
        if r["port_name"] == port
        and r["role"] == "driver"
        and r["signal_full_name"].startswith("Const:")
    })
    if not expected:
        raise SystemExit(f"missing constant driver rows for evidence check: port={port}")

    for instance, value in expected:
        port_path = f"{instance}.{port}"
        matches = [
            fields for fields in const_evidence
            if fields.get("value") == value
            and fields.get("role") == "driver"
            and fields.get("port_path") == port_path
        ]
        if not matches:
            raise SystemExit(
                f"missing constant evidence record: port_path={port_path} value={value}"
            )
        if not any(
            fields.get("evidence_source") not in {
                None,
                "",
                "<empty>",
                "trace_result_fallback",
            }
            and fields.get("const_full_path", "").startswith(f"{port_path}<-")
            and fields.get("const_full_path", "").endswith(value)
            for fields in matches
        ):
            raise SystemExit(
                f"incomplete constant evidence: port_path={port_path} value={value} matches={matches}"
            )

for port, token in [
    ("drv_precise_bus[7]", "u_key_precise.out"),
    ("drv_recursive[2]", "u_kw_rec_hi.out"),
    ("drv_plain", "u_kw_plain.out"),
    ("drv_assign_chain", "u_parent_key.u_key_nested.out"),
    ("drv_cross_concat", "u_local_deep_provider.u_key_deep_h.out"),
    ("drv_module_port", "u_kw_module.out"),
    ("drv_wide_bit", "u_kw_wide_bit.out"),
]:
    require_full(port, "driver", token)
    require_filtered(port, "driver", token)

require_full("drv_precise_bus[7]", "driver", "precise_c")
reject_full("drv_precise_bus[7]", "driver", "precise_b[")
reject_full("drv_precise_bus[7]", "driver", "precise_d[")
reject_full("drv_precise_bus[7]", "driver", "Const:7'b0101010")
reject_full("drv_precise_bus[7]", "driver", "Const:3'b101")

reject_full("drv_wide_bit", "driver", "Const:32")
reject_full("drv_wide_bit", "driver", "32'h")
reject_full("drv_wide_bit", "driver", "Const:1'b1")
reject_full("drv_wide_bit", "driver", "Const:1'b0")
reject_full("drv_wide_bit", "driver", "24'h5aa55a")
reject_full("drv_wide_bit", "driver", "7'b1010101")

require_full("drv_ternary_stop", "driver", "COMBO_EXPR:ternary")
reject_full("drv_ternary_stop", "driver", "u_kw_ternary_data")
reject_full("drv_ternary_stop", "driver", "Const:1'b1")
reject_full("drv_ternary_stop", "driver", "RegCombo")
reject_filtered_port("drv_ternary_stop", "driver")

require_full("drv_precise_bus[6]", "driver", "Const:1'b0")
reject_full("drv_precise_bus[6]", "driver", "u_key_precise")
require_full("drv_precise_bus[8]", "driver", "Const:1'b1")
reject_full("drv_precise_bus[8]", "driver", "u_key_precise")

for port in ["drv_const_direct", "drv_const_parent", "drv_const_source"]:
    require_full(port, "driver", "Const:")
    reject_filtered_port(port, "driver")

for port in [
    "drv_precise_bus[6]",
    "drv_precise_bus[8]",
    "drv_const_direct",
    "drv_const_parent",
    "drv_const_source",
]:
    require_const_evidence(port)

require_full("drv_noise", "driver", "u_noise")
reject_filtered_port("drv_noise", "driver")
require_full("drv_reg_endpoint", "driver", "u_reg_source")
reject_filtered_port("drv_reg_endpoint", "driver")

for port, token in [
    ("load_bus[7]", "u_sink_slice_lo.in"),
    ("load_bus[15]", "u_sink_slice_hi.in"),
    ("load_bus[15]", "u_sink_concat.in"),
    ("load_plain", "u_sink_plain.in"),
    ("load_module_port", "u_sink_pass.in"),
    ("load_sibling_bus", "u_sib_p1.u_sink_lo.in"),
    ("load_sibling_bus", "u_sib_p1.u_sink_hi.in"),
    ("load_sibling_bus", "u_sib_p1.u_sink_concat"),
    ("load_sibling_bus", "u_sib_p1.u_sink_port.in"),
    ("load_leaf_bus", "u_leaf_load.u_sink_direct.in"),
    ("load_leaf_bus", "u_leaf_load.u_sink_alias.in"),
    ("load_leaf_bus", "u_leaf_load.u_sink_concat.in"),
    ("load_leaf_bus", "u_leaf_load.u_sink_lhs_hi.in"),
    ("load_leaf_bus", "u_leaf_load.u_sink_lhs_lo.in"),
    ("load_leaf_bus", "u_leaf_load.u_sink_param.in"),
    ("load_leaf_bus", "u_leaf_load.u_sink_port.in"),
    ("load_leaf_bus", "u_leaf_load.u_sink_gen2.in"),
]:
    require_full(port, "load", token)
    require_filtered(port, "load", token)

require_full("load_reg_endpoint", "load", "RegCombo")
reject_full("load_reg_endpoint", "load", "XorRedu")
reject_full("drv_reg_endpoint", "driver", "RegCombo")
reject_filtered_port("load_reg_endpoint", "load")
require_full("load_unconnected", "load", "drv_noise")
reject_filtered_port("load_unconnected", "load")

leaf_rows = list(csv.DictReader(Path("TAFLeaf_full.csv").open()))
leaf_loads = [
    r["signal_full_name"]
    for r in leaf_rows
    if r["port_name"] == "leaf_in" and r["role"] == "load"
]
for token in [
    "u_sink_direct.in",
    "u_sink_alias.in",
    "u_sink_concat.in",
    "u_sink_lhs_hi.in",
    "u_sink_lhs_lo.in",
    "u_sink_param.in",
    "u_sink_port.in",
    "u_sink_gen2.in",
]:
    if not any(token in sig for sig in leaf_loads):
        raise SystemExit(f"TAFLeaf leaf_in load trace missing {token}: {leaf_loads[:80]}")

split_csvs = sorted(Path(".").glob("tool_all_features_filtered__TAFAllFeatureTop.subsys*.csv"))
if len(split_csvs) != 2:
    raise SystemExit(f"expected two per-target-instance CSV files, got {len(split_csvs)}: {split_csvs}")

xlsx_books = sorted(Path(".").glob("tool_all_features_annotated__subsys_*.xlsx"))
if len(xlsx_books) != 2:
    raise SystemExit(f"expected two subsystem workbooks, got {len(xlsx_books)}: {xlsx_books}")

checked_target = 0
checked_aux = 0
checked_leaf = 0
checked_sparse = 0
for book in xlsx_books:
    wb = load_workbook(book, data_only=False)
    ws = wb.active
    headers = [cell.value for cell in ws[1]]
    for values in ws.iter_rows(min_row=2, values_only=True):
        data = dict(zip(headers, values))
        if any("NO_SUBSYSTEM_INSTANCE" in str(value) for value in values):
            raise SystemExit(f"{book}: stale absent-module marker found: {values}")
        module = data.get("module")
        if module == "TAFTarget":
            checked_target += 1
            for port in [
                "drv_precise_bus[7]",
                "drv_recursive[2]",
                "drv_plain",
                "drv_assign_chain",
                "drv_cross_concat",
                "drv_module_port",
                "drv_wide_bit",
                "load_bus[7]",
                "load_bus[15]",
                "load_plain",
                "load_module_port",
                "load_sibling_bus",
                "load_leaf_bus",
                "load_reg_endpoint",
            ]:
                if not str(data.get(port, "")).startswith("yes"):
                    raise SystemExit(f"{book}: {data.get('instance')} {port} not yes: {data.get(port)}")
            for port in ["drv_precise_bus[6]", "drv_precise_bus[8]"]:
                cell = str(data.get(port, ""))
                if not cell.startswith("no") or "Const:" not in cell:
                    raise SystemExit(f"{book}: {port} should be no with const detail: {cell}")
            for port in ["drv_const_direct", "drv_const_parent", "drv_const_source"]:
                cell = str(data.get(port, ""))
                if not cell.startswith("no") or "Const:" not in cell:
                    raise SystemExit(f"{book}: {port} missing no Const result: {cell}")
            if "driver_actual=" not in str(data.get("drv_noise", "")):
                raise SystemExit(f"{book}: drv_noise missing actual driver: {data.get('drv_noise')}")
            if "driver_actual=" not in str(data.get("drv_reg_endpoint", "")):
                raise SystemExit(f"{book}: drv_reg_endpoint missing actual register driver: {data.get('drv_reg_endpoint')}")
            ternary_cell = str(data.get("drv_ternary_stop", ""))
            if not ternary_cell.startswith("no") or "COMBO_EXPR:ternary" not in ternary_cell:
                raise SystemExit(f"{book}: drv_ternary_stop should be no with combo detail: {ternary_cell}")
            if "loader_actual=" not in str(data.get("load_unconnected", "")):
                raise SystemExit(f"{book}: load_unconnected missing actual loader detail: {data.get('load_unconnected')}")
            params = str(data.get("parameters", ""))
            if "ID=" not in params or "DW=32'sd16" not in params or "TAG=" not in params:
                raise SystemExit(f"{book}: TAFTarget parameters missing: {params}")
        elif module == "TAFAuxTarget":
            checked_aux += 1
            if not str(data.get("aux_in", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_in not yes: {data.get('aux_in')}")
            aux_float = str(data.get("aux_float", ""))
            if "NO_DRIVER" not in aux_float and "driver_actual=" not in aux_float:
                raise SystemExit(f"{book}: aux_float missing floating-driver detail: {aux_float}")
            if not str(data.get("aux_out", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_out not yes: {data.get('aux_out')}")
            if "NO_LOAD" not in str(data.get("aux_unused_out", "")):
                raise SystemExit(f"{book}: aux_unused_out missing NO_LOAD: {data.get('aux_unused_out')}")
            if "MODE=" not in str(data.get("parameters", "")):
                raise SystemExit(f"{book}: TAFAuxTarget parameters missing: {data.get('parameters')}")
        elif module == "TAFLeaf":
            checked_leaf += 1
            inst_name = str(data.get("instance", ""))
            if "u_leaf_direct" in inst_name:
                if not str(data.get("leaf_in", "")).startswith("yes"):
                    raise SystemExit(f"{book}: direct leaf_in not yes: {data.get('leaf_in')}")
            if not str(data.get("leaf_out", "")).startswith("yes"):
                raise SystemExit(f"{book}: leaf_out not yes: {data.get('leaf_out')}")
            if "LEAF_ID=" not in str(data.get("parameters", "")):
                raise SystemExit(f"{book}: TAFLeaf parameters missing: {data.get('parameters')}")
        elif module == "TAFSparseTarget":
            checked_sparse += 1
            if "subsys0" not in book.name:
                raise SystemExit(f"{book}: sparse target leaked into absent subsystem")
            sparse_in = str(data.get("sparse_in", ""))
            if "driver_actual=" not in sparse_in or "NO_TRACE" in sparse_in:
                raise SystemExit(f"{book}: sparse_in missing trace evidence: {sparse_in}")
            if not str(data.get("sparse_out", "")).startswith("yes"):
                raise SystemExit(f"{book}: sparse_out not yes: {data.get('sparse_out')}")
            if str(data.get("parameters", "")) != "NO_PARAMETER":
                raise SystemExit(
                    f"{book}: parameterless sparse target inventory failed: {data.get('parameters')}"
                )

if checked_target != 2 or checked_aux != 2 or checked_leaf != 4 or checked_sparse != 1:
    raise SystemExit(
        "unexpected annotated rows: "
        f"target={checked_target} aux={checked_aux} leaf={checked_leaf} sparse={checked_sparse}"
    )

for marker in [
    "source_assign_direct_driver_source",
    "source_assign_driver_source",
    "source_assign_direct_load_fanout",
    "source_assign_load_fanout",
    "source_module_port_load",
    "load_module_port_high_continue",
]:
    if marker not in raw_text and marker not in filter_text:
        raise SystemExit(f"missing debug marker: {marker}")

for marker in [
    "stream_mode=enabled",
    "stream matcher subsystem=",
    "trace_debug=0",
]:
    if marker not in annotate_text:
        raise SystemExit(f"annotate log missing marker: {marker}")

if "found_filter_instances=" not in filter_text:
    raise SystemExit("filter log missing marker: found_filter_instances=")

print("[tool_all_features] assertions passed")
PY

echo "[tool_all_features] SUCCESS"
