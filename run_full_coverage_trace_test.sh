#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

csv_from_list() {
  grep -v '^[[:space:]]*$' "$1" | grep -v '^[[:space:]]*#' | paste -sd, -
}

MODULES="$(csv_from_list full_coverage_modules.list)"
KEYWORDS="$(csv_from_list full_coverage_keywords.list)"
PORTS="$(csv_from_list full_coverage_ports.list)"

echo "[full_coverage] cwd=$PWD"
echo "[full_coverage] modules=$MODULES"
echo "[full_coverage] keywords=$KEYWORDS"
echo "[full_coverage] ports=$PORTS"

echo "[full_coverage] build KDB"
mkdir -p full_coverage_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top FullCoverageTop -f full_coverage_trace_test.f \
  -Mdir=full_coverage_trace_build/csrc \
  -o full_coverage_trace_build/simv \
  -l full_coverage_vcs.log
vcs_rc=$?
set -e
if [ ! -d full_coverage_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[full_coverage] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  exit "$vcs_rc"
fi
echo "[full_coverage] KDB OK, vcs_rc=$vcs_rc"

echo "[full_coverage] build GUI command from JSON"
python3 trace_gui.py --build-command full_coverage_gui_xlsx.json | tee full_coverage_gui_command.log
grep -q "annotate_trace_xlsx.sh" full_coverage_gui_command.log
grep -q "FCTProbe,FCTAuxProbe,FCTKeywordSink" full_coverage_gui_command.log

echo "[full_coverage] run CSV feature trace"
./trace_and_filter.sh \
  -module FCTProbe \
  -lib "$(pwd)/full_coverage_trace_build/simv.daidir/kdb.elab++" \
  -keywords "$KEYWORDS" \
  -ports "$PORTS" \
  -output full_coverage_probe.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 8 \
  2>&1 | tee full_coverage_probe.log

echo "[full_coverage] run XLSX annotation"
./annotate_trace_xlsx.sh \
  -template full_coverage_trace_template.xlsx \
  -output full_coverage_annotated.xlsx \
  -lib full_coverage_trace_build/simv.daidir/kdb.elab++ \
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
  2>&1 | tee full_coverage_annotate.log

echo "[full_coverage] assert results"
python3 - <<'PY'
import csv
from pathlib import Path
from openpyxl import load_workbook

filtered = Path("full_coverage_probe.csv").read_text()
for token in [
    "drv_vec[2],input,driver",
    "drv_alias_bit,input,driver",
    "drv_range_bit,input,driver",
    "load_bus[6],output,load",
    "load_bus[3],output,load",
    "load_scalar,output,load",
]:
    if token not in filtered:
        raise SystemExit(f"filtered CSV missing expected keyword path: {token}")
for token in [
    "drv_const_direct,input",
    "drv_const_parent,input",
    "drv_const_after_end,input",
    "drv_false_same_bus,input",
    "drv_reg_endpoint,input",
    "drv_float,input",
    "load_unconnected,output",
]:
    if token in filtered:
        raise SystemExit(f"filtered CSV unexpectedly matched keyword path: {token}")

rows = list(csv.DictReader(Path("FCTProbe_full.csv").open()))

def port_role(port, role):
    return [r for r in rows if r["port_name"] == port and r["role"] == role]

for port in ["drv_vec[2]", "drv_alias_bit", "drv_range_bit"]:
    drivers = port_role(port, "driver")
    if not any("u_kw_" in r["signal_full_name"] and ".out" in r["signal_full_name"] for r in drivers):
        raise SystemExit(f"{port} missing keyword source")
    bad = [
        r["signal_full_name"]
        for r in drivers
        if r["signal_full_name"].startswith("Const:")
        or "kw_vec[1]" in r["signal_full_name"]
        or "kw_mixed" in r["signal_full_name"]
    ]
    if bad:
        raise SystemExit(f"{port} polluted by unrelated source: {bad}")

for port in ["drv_const_direct", "drv_const_parent", "drv_const_after_end", "drv_false_same_bus"]:
    drivers = port_role(port, "driver")
    if not any(r["signal_full_name"].startswith("Const:") for r in drivers):
        raise SystemExit(f"{port} missing constant driver")
    if any("u_kw_mixed.out" in r["signal_full_name"] for r in drivers):
        raise SystemExit(f"{port} falsely matched mixed-bus keyword source")

if not any("Reg.O0" in r["signal_full_name"] or "RegCombo" in r["signal_full_name"] for r in port_role("drv_reg_endpoint", "driver")):
    raise SystemExit("drv_reg_endpoint missing register endpoint")
if not any(r["signal_full_name"] == "NO_DRIVER" for r in port_role("drv_float", "driver")):
    raise SystemExit("drv_float missing NO_DRIVER")
if not any(r["signal_full_name"] == "NO_LOAD" for r in port_role("load_unconnected", "load")):
    raise SystemExit("load_unconnected missing NO_LOAD")

books = sorted(Path(".").glob("full_coverage_annotated__subsys_*.xlsx"))
if len(books) != 2:
    raise SystemExit(f"expected two subsystem workbooks, got {len(books)}: {books}")

checked_probe = 0
checked_aux = 0
for book in books:
    wb = load_workbook(book, data_only=False)
    ws = wb.active
    headers = [c.value for c in ws[1]]
    for values in ws.iter_rows(min_row=2, values_only=True):
        data = dict(zip(headers, values))
        module = data.get("module")
        if module == "FCTProbe":
            checked_probe += 1
            for port in ["drv_vec[2]", "drv_alias_bit", "drv_range_bit", "load_bus[6]", "load_bus[3]", "load_scalar"]:
                if not str(data.get(port, "")).startswith("yes"):
                    raise SystemExit(f"{book}: {data.get('instance')} {port} not yes: {data.get(port)}")
            for port in ["drv_const_direct", "drv_const_parent", "drv_const_after_end", "drv_false_same_bus"]:
                cell = str(data.get(port, ""))
                if not cell.startswith("no") or "Const:" not in cell:
                    raise SystemExit(f"{book}: {data.get('instance')} {port} missing no const: {cell}")
            reg_cell = str(data.get("drv_reg_endpoint", ""))
            if not reg_cell.startswith("no") or ("Reg.O0" not in reg_cell and "RegCombo" not in reg_cell):
                raise SystemExit(f"{book}: drv_reg_endpoint missing reg endpoint: {reg_cell}")
            if "NO_DRIVER" not in str(data.get("drv_float", "")):
                raise SystemExit(f"{book}: drv_float missing NO_DRIVER: {data.get('drv_float')}")
            if "NO_LOAD" not in str(data.get("load_unconnected", "")):
                raise SystemExit(f"{book}: load_unconnected missing NO_LOAD: {data.get('load_unconnected')}")
            if "ID=" not in str(data.get("parameters", "")) or "DW=32'sd8" not in str(data.get("parameters", "")):
                raise SystemExit(f"{book}: FCTProbe parameters missing: {data.get('parameters')}")
        elif module == "FCTAuxProbe":
            checked_aux += 1
            if not str(data.get("aux_in", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_in not yes: {data.get('aux_in')}")
            if not str(data.get("aux_out", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_out not yes: {data.get('aux_out')}")
            if "MODE=" not in str(data.get("parameters", "")):
                raise SystemExit(f"{book}: FCTAuxProbe parameters missing: {data.get('parameters')}")

if checked_probe != 2 or checked_aux != 2:
    raise SystemExit(f"unexpected checked rows: probe={checked_probe} aux={checked_aux}")

print("[full_coverage] assertions passed")
PY
