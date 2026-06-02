#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

csv_from_list() {
  grep -v '^[[:space:]]*$' "$1" | grep -v '^[[:space:]]*#' | paste -sd, -
}

MODULES="$(csv_from_list all_features_modules.list)"
KEYWORDS="$(csv_from_list all_features_keywords.list)"
PORTS="$(csv_from_list all_features_ports.list)"

echo "[all_features] cwd=$PWD"
echo "[all_features] modules=$MODULES"
echo "[all_features] keywords=$KEYWORDS"
echo "[all_features] ports=$PORTS"

rm -f all_features_probe.csv all_features_probe_boundary.csv all_features_probe_full_owner.csv
rm -f all_features_probe__*.csv all_features_annotated*.xlsx all_features_gui_command.log

echo "[all_features] build KDB"
mkdir -p all_features_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top AllFeaturesTop -f all_features_trace_test.f \
  -Mdir=all_features_trace_build/csrc \
  -o all_features_trace_build/simv \
  -l all_features_trace_vcs.log
vcs_rc=$?
set -e
if [ ! -d all_features_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[all_features] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  exit "$vcs_rc"
fi
echo "[all_features] KDB OK, vcs_rc=$vcs_rc"

echo "[all_features] build GUI command from JSON"
python3 trace_gui.py --build-command all_features_gui_xlsx.json | tee all_features_gui_command.log
grep -q "annotate_trace_xlsx.sh" all_features_gui_command.log
grep -q "AFProbe,AFKeywordSink" all_features_gui_command.log
grep -q "load_bus" all_features_gui_command.log

echo "[all_features] run CSV feature trace"
./trace_and_filter.sh \
  -module AFProbe \
  -lib "$(pwd)/all_features_trace_build/simv.daidir/kdb.elab++" \
  -keywords "$KEYWORDS" \
  -ports "$PORTS" \
  -output all_features_probe.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 8 \
  2>&1 | tee all_features_probe.log

echo "[all_features] run XLSX annotation"
./annotate_trace_xlsx.sh \
  -template all_features_trace_template.xlsx \
  -output all_features_annotated.xlsx \
  -lib all_features_trace_build/simv.daidir/kdb.elab++ \
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
  2>&1 | tee all_features_annotate.log

echo "[all_features] assert results"
python3 - <<'PY'
from pathlib import Path
import csv
from openpyxl import load_workbook

filtered_csv_text = Path("all_features_probe.csv").read_text()
required_csv = [
    "drv_concat[2],input,driver",
    "drv_bit,input,driver",
    "drv_range,input,driver",
    "load_bus,output,load",
    "load_bus[3],output,load",
    "load_bus[6],output,load",
    "load_bit,output,load",
]
missing = [item for item in required_csv if item not in filtered_csv_text]
if "drv_false,input" in filtered_csv_text:
    missing.append("drv_false unexpectedly matched keyword")
if missing:
    raise SystemExit("CSV assertions failed:\n" + "\n".join(missing))

full_rows = list(csv.DictReader(Path("AFProbe_full.csv").open()))
for row in full_rows:
    if row["port_name"] == "drv_concat[2]" and row["role"] == "driver":
        sig = row["signal_full_name"]
        if sig.startswith("Const:") or "kw_vec[1]" in sig:
            raise SystemExit(f"drv_concat[2] polluted by unrelated concat source: {sig}")
drv_false_consts = [
    row for row in full_rows
    if row["port_name"] == "drv_false"
    and row["role"] == "driver"
    and row["signal_full_name"].startswith("Const:")
]
if not drv_false_consts:
    raise SystemExit("drv_false did not resolve selected-bit constant driver")

workbooks = sorted(Path(".").glob("all_features_annotated__subsys_*.xlsx"))
if len(workbooks) != 2:
    raise SystemExit(f"expected two subsystem XLSX files, got {len(workbooks)}: {workbooks}")

checked_probe = False
for path in workbooks:
    wb = load_workbook(path, data_only=False)
    ws = wb.active
    headers = [c.value for c in ws[1]]
    for row in ws.iter_rows(min_row=2, values_only=True):
        data = dict(zip(headers, row))
        if data.get("module") != "AFProbe":
            continue
        checked_probe = True
        for port in ["drv_concat[2]", "drv_bit", "drv_range", "load_bus", "load_bus[3]", "load_bus[6]", "load_bit"]:
            if not str(data.get(port, "")).startswith("yes"):
                raise SystemExit(f"{path}: {data.get('instance')} {port} not yes: {data.get(port)}")
        if "Const:" in str(data.get("drv_concat[2]", "")):
            raise SystemExit(f"{path}: {data.get('instance')} drv_concat[2] contains unrelated const: {data.get('drv_concat[2]')}")
        for port in ["drv_const", "drv_parent_const"]:
            if "Const:" not in str(data.get(port, "")):
                raise SystemExit(f"{path}: {data.get('instance')} {port} missing Const: {data.get(port)}")
        if "Reg.O0" not in str(data.get("drv_regcombo", "")) and "RegCombo" not in str(data.get("drv_regcombo", "")):
            raise SystemExit(f"{path}: {data.get('instance')} drv_regcombo missing reg endpoint: {data.get('drv_regcombo')}")
        if not str(data.get("drv_false", "")).startswith("no") or "Const:" not in str(data.get("drv_false", "")):
            raise SystemExit(f"{path}: {data.get('instance')} drv_false missing constant no result: {data.get('drv_false')}")

if not checked_probe:
    raise SystemExit("no AFProbe rows checked")
print("[all_features] assertions passed")
PY
