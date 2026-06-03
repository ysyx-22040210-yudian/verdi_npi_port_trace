#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

csv_from_list() {
  grep -v '^[[:space:]]*$' "$1" | grep -v '^[[:space:]]*#' | paste -sd, -
}

MODULES="$(csv_from_list ultimate_features_modules.list)"
KEYWORDS="$(csv_from_list ultimate_features_keywords.list)"
PORTS="$(csv_from_list ultimate_features_ports.list)"

echo "[ultimate_features] cwd=$PWD"
echo "[ultimate_features] modules=$MODULES"
echo "[ultimate_features] keywords=$KEYWORDS"
echo "[ultimate_features] ports=$PORTS"

echo "[ultimate_features] clean previous outputs"
rm -rf ultimate_features_trace_build
rm -f ultimate_features_trace_vcs.log
rm -f ultimate_features_probe.csv ultimate_features_probe_boundary.csv ultimate_features_probe_full_owner.csv
rm -f ultimate_features_probe__*.csv ultimate_features_probe.log
rm -f ultimate_features_annotated.xlsx ultimate_features_annotated__subsys_*.xlsx ultimate_features_annotate.log
rm -f ultimate_features_gui_command.log ultimate_features_trace_template.xlsx
rm -f UFProbe_full.csv UFProbe_module_connections.csv UFAuxProbe_full.csv UFAuxProbe_module_connections.csv
rm -f UFKeywordSink_full.csv UFKeywordSink_module_connections.csv
rm -f UFProbe_UFKeywordSrc_UFKeywordSink_instances.txt
rm -f module_parameters.csv

echo "[ultimate_features] create xlsx template"
python3 - <<'PY'
from pathlib import Path
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

ports = [
    line.strip()
    for line in Path("ultimate_features_ports.list").read_text().splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
wb = Workbook()
ws = wb.active
ws.title = "Trace"
headers = ["module", "instance", "parameters"] + ports
ws.append(headers)
for module in ["UFProbe", "UFAuxProbe", "UFKeywordSink"]:
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
    ws.column_dimensions[get_column_letter(col_idx)].width = min(max(len(str(header)) + 4, 14), 32)
ws.freeze_panes = "A2"
wb.save("ultimate_features_trace_template.xlsx")
print("[ultimate_features] template=ultimate_features_trace_template.xlsx")
PY

echo "[ultimate_features] verify GUI list readers"
python3 - <<'PY'
import trace_gui

assert trace_gui.read_list_file("ultimate_features_modules.list") == "UFProbe,UFAuxProbe,UFKeywordSink"
assert trace_gui.read_list_file("ultimate_features_keywords.list") == "UFKeywordSrc,UFKeywordSink"
ports = trace_gui.read_list_file("ultimate_features_ports.list")
assert "drv_concat_bus[7]" in ports and "load_module_port" in ports
print("[ultimate_features] gui list reader assertions passed")
PY

echo "[ultimate_features] build KDB"
mkdir -p ultimate_features_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top UltimateFeatureTop -f ultimate_features_trace_test.f \
  -Mdir=ultimate_features_trace_build/csrc \
  -o ultimate_features_trace_build/simv \
  -l ultimate_features_trace_vcs.log
vcs_rc=$?
set -e
if [ ! -d ultimate_features_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[ultimate_features] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 ultimate_features_trace_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[ultimate_features] KDB OK, vcs_rc=$vcs_rc"

echo "[ultimate_features] build GUI command from JSON"
python3 trace_gui.py --build-command ultimate_features_gui_xlsx.json | tee ultimate_features_gui_command.log
grep -q "annotate_trace_xlsx.sh" ultimate_features_gui_command.log
grep -q "UFProbe,UFAuxProbe,UFKeywordSink" ultimate_features_gui_command.log
grep -q "drv_concat_bus\\[7\\]" ultimate_features_gui_command.log

echo "[ultimate_features] run CSV feature trace"
./trace_and_filter.sh \
  -module UFProbe \
  -lib "$(pwd)/ultimate_features_trace_build/simv.daidir/kdb.elab++" \
  -keywords "$KEYWORDS" \
  -ports "$PORTS" \
  -output ultimate_features_probe.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 8 \
  2>&1 | tee ultimate_features_probe.log

echo "[ultimate_features] run XLSX annotation"
./annotate_trace_xlsx.sh \
  -template ultimate_features_trace_template.xlsx \
  -output ultimate_features_annotated.xlsx \
  -lib ultimate_features_trace_build/simv.daidir/kdb.elab++ \
  -keywords "$KEYWORDS" \
  -module "$MODULES" \
  -ports "$PORTS" \
  -subsystem-level 2 \
  --stream \
  -regcombo-as-keyword 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 8 \
  --match-cache-size 200000 \
  --keyword-batch-size 1 \
  2>&1 | tee ultimate_features_annotate.log

echo "[ultimate_features] assert results"
python3 - <<'PY'
import csv
from pathlib import Path
from openpyxl import load_workbook

filtered = Path("ultimate_features_probe.csv").read_text()
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
    Path("ultimate_features_probe__UltimateFeatureTop.subsys0.u_probe.csv"),
    Path("ultimate_features_probe__UltimateFeatureTop.subsys1.u_probe.csv"),
]:
    if not path.exists():
        raise SystemExit(f"missing per-instance split CSV: {path}")

rows = list(csv.DictReader(Path("UFProbe_full.csv").open()))

def port_role(port, role):
    return [r for r in rows if r["port_name"] == port and r["role"] == role]

concat7 = port_role("drv_concat_bus[7]", "driver")
if not any("u_kw_concat" in r["signal_full_name"] for r in concat7):
    raise SystemExit("drv_concat_bus[7] did not reach UFKeywordSrc u_kw_concat")
if any("u_noise" in r["signal_full_name"] for r in concat7):
    raise SystemExit("drv_concat_bus[7] was polluted by adjacent noise bits")

concat6 = port_role("drv_concat_bus[6]", "driver")
if any("u_kw_concat" in r["signal_full_name"] for r in concat6):
    raise SystemExit("drv_concat_bus[6] falsely reached keyword concat bit")

for port in ["drv_const_direct", "drv_const_parent", "drv_const_after_block", "drv_false_same_bus"]:
    if not any(r["signal_full_name"].startswith("Const:") for r in port_role(port, "driver")):
        raise SystemExit(f"{port} missing constant driver")

if not any(r["signal_full_name"] == "NO_DRIVER" for r in port_role("drv_float", "driver")):
    raise SystemExit("drv_float missing NO_DRIVER")
if not any(r["signal_full_name"] == "NO_LOAD" for r in port_role("load_unconnected", "load")):
    raise SystemExit("load_unconnected missing NO_LOAD")

books = sorted(Path(".").glob("ultimate_features_annotated__subsys_*.xlsx"))
if len(books) != 2:
    raise SystemExit(f"expected two subsystem workbooks, got {len(books)}: {books}")

checked_probe = 0
checked_aux = 0
for book in books:
    wb = load_workbook(book, data_only=False)
    ws = wb.active
    headers = [cell.value for cell in ws[1]]
    for values in ws.iter_rows(min_row=2, values_only=True):
        data = dict(zip(headers, values))
        module = data.get("module")
        if module == "UFProbe":
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
            if not reg_cell.startswith("no") or ("Reg.O0" not in reg_cell and "RegCombo" not in reg_cell):
                raise SystemExit(f"{book}: drv_reg_endpoint missing register endpoint: {reg_cell}")
            if "NO_DRIVER" not in str(data.get("drv_float", "")):
                raise SystemExit(f"{book}: drv_float missing NO_DRIVER: {data.get('drv_float')}")
            if "NO_LOAD" not in str(data.get("load_unconnected", "")):
                raise SystemExit(f"{book}: load_unconnected missing NO_LOAD: {data.get('load_unconnected')}")
            params = str(data.get("parameters", ""))
            if "ID=" not in params or "DW=32'sd16" not in params:
                raise SystemExit(f"{book}: UFProbe parameters missing: {params}")
        elif module == "UFAuxProbe":
            checked_aux += 1
            if not str(data.get("aux_in", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_in not yes: {data.get('aux_in')}")
            if not str(data.get("aux_out", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_out not yes: {data.get('aux_out')}")
            if "MODE=" not in str(data.get("parameters", "")):
                raise SystemExit(f"{book}: UFAuxProbe parameters missing: {data.get('parameters')}")

if checked_probe != 2 or checked_aux != 2:
    raise SystemExit(f"unexpected checked rows: probe={checked_probe} aux={checked_aux}")

for log_name in ["ultimate_features_probe.log", "ultimate_features_annotate.log"]:
    text = Path(log_name).read_text(errors="replace")
    if "source_assign_driver_source" not in text:
        raise SystemExit(f"{log_name} missing source assign fallback evidence")
    if "module_port" not in text:
        raise SystemExit(f"{log_name} missing module port continuation evidence")

print("[ultimate_features] assertions passed")
PY

echo "[ultimate_features] SUCCESS"
