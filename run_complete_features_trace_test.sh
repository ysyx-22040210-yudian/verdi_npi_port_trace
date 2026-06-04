#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

csv_from_list() {
  grep -v '^[[:space:]]*$' "$1" | grep -v '^[[:space:]]*#' | paste -sd, -
}

MODULES="$(csv_from_list complete_features_modules.list)"
KEYWORDS="$(csv_from_list complete_features_keywords.list)"
PORTS="$(csv_from_list complete_features_ports.list)"

echo "[complete_features] cwd=$PWD"
echo "[complete_features] modules=$MODULES"
echo "[complete_features] keywords=$KEYWORDS"
echo "[complete_features] ports=$PORTS"

echo "[complete_features] clean previous outputs"
rm -rf complete_features_trace_build
rm -f complete_features_trace_vcs.log
rm -f complete_features_probe.csv complete_features_probe_boundary.csv complete_features_probe_full_owner.csv
rm -f complete_features_probe__*.csv complete_features_probe.log
rm -f complete_features_annotated.xlsx complete_features_annotated__subsys_*.xlsx complete_features_annotate.log
rm -f complete_features_gui_command.log complete_features_trace_template.xlsx
rm -f CFProbe_full.csv CFProbe_module_connections.csv CFAuxProbe_full.csv CFAuxProbe_module_connections.csv
rm -f CFFanoutLeaf_full.csv CFFanoutLeaf_module_connections.csv CFKeywordSink_full.csv CFKeywordSink_module_connections.csv
rm -f CFProbe_CFKeywordSrc_CFKeywordSink_instances.txt module_parameters.csv

echo "[complete_features] create xlsx template"
python3 - <<'PY'
from pathlib import Path
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

ports = [
    line.strip()
    for line in Path("complete_features_ports.list").read_text().splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
wb = Workbook()
ws = wb.active
ws.title = "Trace"
headers = ["module", "instance", "parameters"] + ports
ws.append(headers)
for module in ["CFProbe", "CFAuxProbe", "CFFanoutLeaf", "CFKeywordSink"]:
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
    ws.column_dimensions[get_column_letter(col_idx)].width = min(max(len(str(header)) + 4, 14), 34)
ws.freeze_panes = "A2"
wb.save("complete_features_trace_template.xlsx")
print("[complete_features] template=complete_features_trace_template.xlsx")
PY

echo "[complete_features] verify GUI command builder"
python3 trace_gui.py --build-command complete_features_gui_xlsx.json | tee complete_features_gui_command.log
grep -q "annotate_trace_xlsx.sh" complete_features_gui_command.log
grep -q "CFProbe,CFAuxProbe,CFFanoutLeaf,CFKeywordSink" complete_features_gui_command.log
grep -q "drv_concat_bus\\[7\\]" complete_features_gui_command.log

echo "[complete_features] build KDB"
mkdir -p complete_features_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top CompleteFeatureTop -f complete_features_trace_test.f \
  -Mdir=complete_features_trace_build/csrc \
  -o complete_features_trace_build/simv \
  -l complete_features_trace_vcs.log
vcs_rc=$?
set -e
if [ ! -d complete_features_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[complete_features] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 complete_features_trace_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[complete_features] KDB OK, vcs_rc=$vcs_rc"

echo "[complete_features] run CSV feature trace"
./trace_and_filter.sh \
  -module CFProbe \
  -lib "$(pwd)/complete_features_trace_build/simv.daidir/kdb.elab++" \
  -keywords "$KEYWORDS" \
  -ports "$PORTS" \
  -output complete_features_probe.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 10 \
  -assign-expr-trace-depth 8 \
  2>&1 | tee complete_features_probe.log

echo "[complete_features] run XLSX annotation"
./annotate_trace_xlsx.sh \
  -template complete_features_trace_template.xlsx \
  -output complete_features_annotated.xlsx \
  -lib complete_features_trace_build/simv.daidir/kdb.elab++ \
  -keywords "$KEYWORDS" \
  -module "$MODULES" \
  -ports "$PORTS" \
  -subsystem-level 2 \
  --stream \
  -regcombo-as-keyword 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 10 \
  -assign-expr-trace-depth 8 \
  --match-cache-size 200000 \
  --keyword-batch-size 1 \
  2>&1 | tee complete_features_annotate.log

echo "[complete_features] assert results"
python3 - <<'PY'
import csv
from pathlib import Path
from openpyxl import load_workbook

filtered = Path("complete_features_probe.csv").read_text()
required_csv = [
    "drv_concat_bus[7],input,driver",
    "drv_recursive[2],input,driver",
    "drv_plain,input,driver",
    "drv_range_bit,input,driver",
    "drv_module_port,input,driver",
    "load_bus[7],output,load",
    "load_bus[3],output,load",
    "load_plain,output,load",
    "load_module_port,output,load",
]
for token in required_csv:
    if token not in filtered:
        raise SystemExit(f"filtered CSV missing expected keyword path: {token}")

for token in [
    "drv_concat_bus[6],input",
    "drv_const_direct,input",
    "drv_const_parent,input",
    "drv_const_after_block,input",
    "drv_false_same_bus,input",
    "drv_noise,input",
    "drv_reg_endpoint,input",
    "drv_float,input",
    "load_unconnected,output",
]:
    if token in filtered:
        raise SystemExit(f"filtered CSV unexpectedly matched keyword path: {token}")

for path in [
    Path("complete_features_probe__CompleteFeatureTop.subsys0.u_probe.csv"),
    Path("complete_features_probe__CompleteFeatureTop.subsys1.u_probe.csv"),
]:
    if not path.exists():
        raise SystemExit(f"missing per-instance split CSV: {path}")

rows = list(csv.DictReader(Path("CFProbe_full.csv").open()))

def port_role(port, role):
    return [r for r in rows if r["port_name"] == port and r["role"] == role]

concat7 = port_role("drv_concat_bus[7]", "driver")
if not any("u_kw_concat" in r["signal_full_name"] for r in concat7):
    raise SystemExit("drv_concat_bus[7] did not reach CFKeywordSrc u_kw_concat")
if any("u_noise" in r["signal_full_name"] for r in concat7):
    raise SystemExit("drv_concat_bus[7] was polluted by adjacent noise bits")

concat6 = port_role("drv_concat_bus[6]", "driver")
if any("u_kw_concat" in r["signal_full_name"] for r in concat6):
    raise SystemExit("drv_concat_bus[6] falsely reached keyword concat bit")

for port in [
    "drv_const_direct",
    "drv_const_parent",
    "drv_const_after_block",
    "drv_false_same_bus",
]:
    if not any(r["signal_full_name"].startswith("Const:") for r in port_role(port, "driver")):
        raise SystemExit(f"{port} missing constant driver")

if not any(r["signal_full_name"] == "NO_DRIVER" for r in port_role("drv_float", "driver")):
    raise SystemExit("drv_float missing NO_DRIVER")
if not any(r["signal_full_name"] == "NO_LOAD" for r in port_role("load_unconnected", "load")):
    raise SystemExit("load_unconnected missing NO_LOAD")
if not any("Reg.O0" in r["signal_full_name"] or "RegCombo" in r["signal_full_name"] for r in port_role("drv_reg_endpoint", "driver")):
    raise SystemExit("drv_reg_endpoint missing register endpoint")

leaf_rows = list(csv.DictReader(Path("CFFanoutLeaf_full.csv").open()))
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
        raise SystemExit(f"CFFanoutLeaf leaf_in load trace missing {token}")

leaf_drivers = [
    r["signal_full_name"]
    for r in leaf_rows
    if r["port_name"] == "leaf_in" and r["role"] == "driver"
]
if not any("u_kw_plain.out" in sig for sig in leaf_drivers):
    raise SystemExit("CFFanoutLeaf leaf_in driver did not continue to keyword source")
if any(sig == "Const:32" for sig in leaf_drivers):
    raise SystemExit("CFFanoutLeaf leaf_in driver included replication count Const:32")

books = sorted(Path(".").glob("complete_features_annotated__subsys_*.xlsx"))
if len(books) != 2:
    raise SystemExit(f"expected two subsystem workbooks, got {len(books)}: {books}")

checked_probe = 0
checked_aux = 0
checked_leaf = 0
for book in books:
    wb = load_workbook(book, data_only=False)
    ws = wb.active
    headers = [cell.value for cell in ws[1]]
    for values in ws.iter_rows(min_row=2, values_only=True):
        data = dict(zip(headers, values))
        module = data.get("module")
        if module == "CFProbe":
            checked_probe += 1
            for port in [
                "drv_concat_bus[7]",
                "drv_recursive[2]",
                "drv_plain",
                "drv_range_bit",
                "drv_module_port",
                "load_bus[7]",
                "load_bus[3]",
                "load_plain",
                "load_module_port",
            ]:
                if not str(data.get(port, "")).startswith("yes"):
                    raise SystemExit(f"{book}: {data.get('instance')} {port} not yes: {data.get(port)}")
            if not str(data.get("drv_concat_bus[6]", "")).startswith("no"):
                raise SystemExit(f"{book}: drv_concat_bus[6] should be no: {data.get('drv_concat_bus[6]')}")
            if "driver_actual=" not in str(data.get("drv_noise", "")):
                raise SystemExit(f"{book}: drv_noise missing actual driver: {data.get('drv_noise')}")
            for port in [
                "drv_const_direct",
                "drv_const_parent",
                "drv_const_after_block",
                "drv_false_same_bus",
            ]:
                cell = str(data.get(port, ""))
                if not cell.startswith("no") or "Const:" not in cell:
                    raise SystemExit(f"{book}: {port} missing no Const result: {cell}")
            reg_cell = str(data.get("drv_reg_endpoint", ""))
            if not (reg_cell.startswith("yes") or reg_cell.startswith("no")):
                raise SystemExit(f"{book}: drv_reg_endpoint malformed: {reg_cell}")
            if "NO_DRIVER" not in str(data.get("drv_float", "")):
                raise SystemExit(f"{book}: drv_float missing NO_DRIVER: {data.get('drv_float')}")
            if "NO_LOAD" not in str(data.get("load_unconnected", "")):
                raise SystemExit(f"{book}: load_unconnected missing NO_LOAD: {data.get('load_unconnected')}")
            params = str(data.get("parameters", ""))
            if "ID=" not in params or "DW=32'sd16" not in params:
                raise SystemExit(f"{book}: CFProbe parameters missing: {params}")
        elif module == "CFAuxProbe":
            checked_aux += 1
            if not str(data.get("aux_in", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_in not yes: {data.get('aux_in')}")
            if not str(data.get("aux_out", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_out not yes: {data.get('aux_out')}")
            if "MODE=" not in str(data.get("parameters", "")):
                raise SystemExit(f"{book}: CFAuxProbe parameters missing: {data.get('parameters')}")
        elif module == "CFFanoutLeaf":
            checked_leaf += 1
            if not str(data.get("leaf_in", "")).startswith("yes"):
                raise SystemExit(f"{book}: leaf_in not yes: {data.get('leaf_in')}")
            if "LEAF_ID=" not in str(data.get("parameters", "")):
                raise SystemExit(f"{book}: CFFanoutLeaf parameters missing: {data.get('parameters')}")

if checked_probe != 2 or checked_aux != 2 or checked_leaf != 2:
    raise SystemExit(f"unexpected checked rows: probe={checked_probe} aux={checked_aux} leaf={checked_leaf}")

for log_name in ["complete_features_probe.log", "complete_features_annotate.log"]:
    text = Path(log_name).read_text(errors="replace")
    if "source_assign_driver_source" not in text:
        raise SystemExit(f"{log_name} missing source assign fallback evidence")
    if "module_port" not in text:
        raise SystemExit(f"{log_name} missing module port continuation evidence")

print("[complete_features] assertions passed")
PY

echo "[complete_features] SUCCESS"
