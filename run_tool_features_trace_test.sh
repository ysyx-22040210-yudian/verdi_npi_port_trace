#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

csv_from_list() {
  grep -v '^[[:space:]]*$' "$1" | grep -v '^[[:space:]]*#' | paste -sd, -
}

MODULES="$(csv_from_list tool_features_modules.list)"
KEYWORDS="$(csv_from_list tool_features_keywords.list)"
PORTS="$(csv_from_list tool_features_ports.list)"

echo "[tool_features] cwd=$PWD"
echo "[tool_features] modules=$MODULES"
echo "[tool_features] keywords=$KEYWORDS"
echo "[tool_features] ports=$PORTS"

echo "[tool_features] clean previous outputs"
rm -rf tool_features_trace_build
rm -f tool_features_trace_vcs.log
rm -f tool_features_trace_template.xlsx tool_features_gui_command.log tool_features_gui_xlsx.log
rm -f tool_features_raw_full.csv tool_features_raw_module.csv tool_features_raw.log
rm -f tool_features_filtered.csv tool_features_filtered_boundary.csv tool_features_filtered_full_owner.csv tool_features_filter.log
rm -f tool_features_annotated.xlsx tool_features_annotated__subsys_*.xlsx tool_features_annotate.log
rm -f TFTarget_full.csv TFTarget_module_connections.csv TFAuxTarget_full.csv TFAuxTarget_module_connections.csv
rm -f TFLeaf_full.csv TFLeaf_module_connections.csv TFKeySink_full.csv TFKeySink_module_connections.csv
rm -f TFTarget_TFKeySrc_TFKeySink_instances.txt module_parameters.csv

echo "[tool_features] create xlsx template"
python3 - <<'PY'
from pathlib import Path
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

modules = [
    line.strip()
    for line in Path("tool_features_modules.list").read_text().splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
ports = [
    line.strip()
    for line in Path("tool_features_ports.list").read_text().splitlines()
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
    ws.column_dimensions[get_column_letter(col_idx)].width = min(max(len(str(header)) + 4, 14), 36)
ws.freeze_panes = "A2"
wb.save("tool_features_trace_template.xlsx")
print("[tool_features] template=tool_features_trace_template.xlsx")
PY

echo "[tool_features] verify GUI command builder"
python3 trace_gui.py --build-command tool_features_gui_xlsx.json | tee tool_features_gui_command.log
grep -q "annotate_trace_xlsx.sh" tool_features_gui_command.log
grep -q "TFTarget,TFAuxTarget,TFLeaf,TFKeySink" tool_features_gui_command.log
grep -q "TFKeySrc,TFKeySink" tool_features_gui_command.log
grep -q "drv_concat_bus\\[7\\]" tool_features_gui_command.log
grep -q -- "-trace-debug 1" tool_features_gui_command.log
grep -q -- "-log-file tool_features_gui_xlsx.log" tool_features_gui_command.log

echo "[tool_features] build KDB"
mkdir -p tool_features_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top ToolFeatureTop -f tool_features_trace_test.f \
  -Mdir=tool_features_trace_build/csrc \
  -o tool_features_trace_build/simv \
  -l tool_features_trace_vcs.log
vcs_rc=$?
set -e
if [ ! -d tool_features_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[tool_features] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 tool_features_trace_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[tool_features] KDB OK, vcs_rc=$vcs_rc"

echo "[tool_features] run Raw Trace with debug"
./npi_trace.sh \
  -module TFTarget \
  -lib "$(pwd)/tool_features_trace_build/simv.daidir/kdb.elab++" \
  -ports drv_assign_chain,load_bus,load_sibling_bus \
  -module-out tool_features_raw_module.csv \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 12 \
  -assign-expr-trace-depth 8 \
  -trace-debug 1 \
  -log-file tool_features_raw.log \
  > tool_features_raw_full.csv

echo "[tool_features] run CSV filter"
./trace_and_filter.sh \
  -module TFTarget \
  -lib "$(pwd)/tool_features_trace_build/simv.daidir/kdb.elab++" \
  -keywords "$KEYWORDS" \
  -ports "$PORTS" \
  -output tool_features_filtered.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 12 \
  -assign-expr-trace-depth 8 \
  -trace-debug 1 \
  -log-file tool_features_filter.log

echo "[tool_features] run XLSX annotation"
./annotate_trace_xlsx.sh \
  -template tool_features_trace_template.xlsx \
  -output tool_features_annotated.xlsx \
  -lib tool_features_trace_build/simv.daidir/kdb.elab++ \
  -keywords "$KEYWORDS" \
  -module "$MODULES" \
  -ports "$PORTS" \
  -subsystem-level 2 \
  --stream \
  -regcombo-as-keyword 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 12 \
  -assign-expr-trace-depth 8 \
  -trace-debug 1 \
  --match-cache-size 200000 \
  --keyword-batch-size 1 \
  -log-file tool_features_annotate.log

echo "[tool_features] assert results"
python3 - <<'PY'
import csv
from pathlib import Path
from openpyxl import load_workbook

filtered = Path("tool_features_filtered.csv").read_text()
for token in [
    "drv_concat_bus[7],input,driver",
    "drv_recursive[2],input,driver",
    "drv_plain,input,driver",
    "drv_assign_chain,input,driver",
    "drv_module_port,input,driver",
    "load_bus[7],output,load",
    "load_bus[15],output,load",
    "load_plain,output,load",
    "load_module_port,output,load",
    "load_sibling_bus,output,load",
    "load_leaf_bus,output,load",
]:
    if token not in filtered:
        raise SystemExit(f"filtered CSV missing expected keyword path: {token}")

for token in [
    "drv_concat_bus[6],input",
    "drv_const_direct,input",
    "drv_const_parent,input",
    "drv_const_source,input",
    "drv_noise,input",
    "drv_reg_endpoint,input",
    "drv_float,input",
    "load_unconnected,output",
]:
    if token in filtered:
        raise SystemExit(f"filtered CSV unexpectedly matched keyword path: {token}")

rows = list(csv.DictReader(Path("TFTarget_full.csv").open()))

def port_role(port, role):
    return [r for r in rows if r["port_name"] == port and r["role"] == role]

concat7 = port_role("drv_concat_bus[7]", "driver")
if not any("u_kw_concat" in r["signal_full_name"] for r in concat7):
    raise SystemExit("drv_concat_bus[7] did not reach TFKeySrc u_kw_concat")
if any("u_noise" in r["signal_full_name"] for r in concat7):
    raise SystemExit("drv_concat_bus[7] was polluted by adjacent noise bits")
if any("u_kw_concat" in r["signal_full_name"] for r in port_role("drv_concat_bus[6]", "driver")):
    raise SystemExit("drv_concat_bus[6] falsely reached keyword concat bit")
if not any("u_parent_key.u_key_nested.out" in r["signal_full_name"] for r in port_role("drv_assign_chain", "driver")):
    raise SystemExit("drv_assign_chain did not continue b -> c -> nested keyword")
if not any("u_driver_pass.o" in r["signal_full_name"] or "u_kw_module.out" in r["signal_full_name"] for r in port_role("drv_module_port", "driver")):
    raise SystemExit("drv_module_port did not include module port pass-through")

for port in ["drv_const_direct", "drv_const_parent", "drv_const_source"]:
    if not any(r["signal_full_name"].startswith("Const:") for r in port_role(port, "driver")):
        raise SystemExit(f"{port} missing constant driver")
if not any(r["signal_full_name"] == "NO_DRIVER" for r in port_role("drv_float", "driver")):
    raise SystemExit("drv_float missing NO_DRIVER")
if not any(r["signal_full_name"] == "NO_LOAD" for r in port_role("load_unconnected", "load")):
    raise SystemExit("load_unconnected missing NO_LOAD")
if not any("Reg.O0" in r["signal_full_name"] or "RegCombo" in r["signal_full_name"] for r in port_role("drv_reg_endpoint", "driver")):
    raise SystemExit("drv_reg_endpoint missing register endpoint")

for port, tokens in {
    "load_sibling_bus": ["u_sib_p1.u_sink_lo.in", "u_sib_p1.u_sink_hi.in", "u_sib_p1.u_sink_alias.in"],
    "load_leaf_bus": ["u_leaf.leaf_in", "u_leaf.u_sink_direct.in"],
}.items():
    loads = [r["signal_full_name"] for r in port_role(port, "load")]
    for token in tokens:
        if not any(token in sig for sig in loads):
            raise SystemExit(f"{port} load trace missing {token}: {loads}")

leaf_rows = list(csv.DictReader(Path("TFLeaf_full.csv").open()))
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
        raise SystemExit(f"TFLeaf leaf_in load trace missing {token}")
leaf_drivers = [
    r["signal_full_name"]
    for r in leaf_rows
    if r["port_name"] == "leaf_in" and r["role"] == "driver"
]
if not any("u_kw_plain.out" in sig for sig in leaf_drivers):
    raise SystemExit("TFLeaf leaf_in driver did not continue to keyword source")
if any(sig == "Const:32" for sig in leaf_drivers):
    raise SystemExit("TFLeaf leaf_in driver included replication count Const:32")

for path in [
    Path("tool_features_filtered__ToolFeatureTop.subsys0.u_target.csv"),
    Path("tool_features_filtered__ToolFeatureTop.subsys1.u_target.csv"),
]:
    if not path.exists():
        raise SystemExit(f"missing per-instance split CSV: {path}")

books = sorted(Path(".").glob("tool_features_annotated__subsys_*.xlsx"))
if len(books) != 2:
    raise SystemExit(f"expected two subsystem workbooks, got {len(books)}: {books}")

checked_target = 0
checked_aux = 0
checked_leaf = 0
checked_sink = 0
checked_sink_yes = 0
for book in books:
    wb = load_workbook(book, data_only=False)
    ws = wb.active
    headers = [cell.value for cell in ws[1]]
    for values in ws.iter_rows(min_row=2, values_only=True):
        data = dict(zip(headers, values))
        module = data.get("module")
        if module == "TFTarget":
            checked_target += 1
            for port in [
                "drv_concat_bus[7]",
                "drv_recursive[2]",
                "drv_plain",
                "drv_assign_chain",
                "drv_module_port",
                "load_bus[7]",
                "load_bus[15]",
                "load_plain",
                "load_module_port",
                "load_sibling_bus",
                "load_leaf_bus",
            ]:
                if not str(data.get(port, "")).startswith("yes"):
                    raise SystemExit(f"{book}: {data.get('instance')} {port} not yes: {data.get(port)}")
            if not str(data.get("drv_concat_bus[6]", "")).startswith("no"):
                raise SystemExit(f"{book}: drv_concat_bus[6] should be no: {data.get('drv_concat_bus[6]')}")
            if "driver_actual=" not in str(data.get("drv_noise", "")):
                raise SystemExit(f"{book}: drv_noise missing actual driver: {data.get('drv_noise')}")
            for port in ["drv_const_direct", "drv_const_parent", "drv_const_source"]:
                cell = str(data.get(port, ""))
                if not cell.startswith("no") or "Const:" not in cell:
                    raise SystemExit(f"{book}: {port} missing no Const result: {cell}")
            if "NO_DRIVER" not in str(data.get("drv_float", "")):
                raise SystemExit(f"{book}: drv_float missing NO_DRIVER: {data.get('drv_float')}")
            if "NO_LOAD" not in str(data.get("load_unconnected", "")):
                raise SystemExit(f"{book}: load_unconnected missing NO_LOAD: {data.get('load_unconnected')}")
            params = str(data.get("parameters", ""))
            if "ID=" not in params or "DW=32'sd16" not in params:
                raise SystemExit(f"{book}: TFTarget parameters missing: {params}")
        elif module == "TFAuxTarget":
            checked_aux += 1
            if not str(data.get("aux_in", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_in not yes: {data.get('aux_in')}")
            if not str(data.get("aux_out", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_out not yes: {data.get('aux_out')}")
            if "MODE=" not in str(data.get("parameters", "")):
                raise SystemExit(f"{book}: TFAuxTarget parameters missing: {data.get('parameters')}")
        elif module == "TFLeaf":
            checked_leaf += 1
            if not str(data.get("leaf_in", "")).startswith("yes"):
                raise SystemExit(f"{book}: leaf_in not yes: {data.get('leaf_in')}")
            if not str(data.get("leaf_out", "")).startswith("yes"):
                raise SystemExit(f"{book}: leaf_out not yes: {data.get('leaf_out')}")
            if "LEAF_ID=" not in str(data.get("parameters", "")):
                raise SystemExit(f"{book}: TFLeaf parameters missing: {data.get('parameters')}")
        elif module == "TFKeySink":
            checked_sink += 1
            if str(data.get("in", "")).startswith("yes"):
                checked_sink_yes += 1

if checked_target != 2 or checked_aux != 2 or checked_leaf != 2 or checked_sink < 10 or checked_sink_yes == 0:
    raise SystemExit(
        f"unexpected checked rows: target={checked_target} aux={checked_aux} leaf={checked_leaf} sink={checked_sink} sink_yes={checked_sink_yes}"
    )

for log_name in ["tool_features_raw.log", "tool_features_filter.log", "tool_features_annotate.log"]:
    text = Path(log_name).read_text(errors="replace")
    for marker in [
        "source_assign_direct_driver_source",
        "source_assign_direct_load_fanout",
        "source_module_port_load",
        "source_module_port_load_unknown_direction_keep",
        "module_port_high_continue",
    ]:
        if marker not in text:
            raise SystemExit(f"{log_name} missing debug marker {marker}")

print("[tool_features] assertions passed")
PY

echo "[tool_features] SUCCESS"
