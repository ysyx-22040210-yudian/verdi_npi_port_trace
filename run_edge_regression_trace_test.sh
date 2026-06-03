#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[edge_regression] cwd=$PWD"
echo "[edge_regression] build KDB"
mkdir -p edge_regression_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top EREdgeTop -f edge_regression_trace_test.f \
  -Mdir=edge_regression_trace_build/csrc \
  -o edge_regression_trace_build/simv \
  -l edge_regression_vcs.log
vcs_rc=$?
set -e
if [ ! -d edge_regression_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[edge_regression] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  exit "$vcs_rc"
fi
echo "[edge_regression] KDB OK, vcs_rc=$vcs_rc"

PORTS='in_alias_bit,in_range_bit,in_const_after_end,in_const_after_initial,in_false_no_keyword,out_bus[6],out_bus[3],out_scalar,unused_out,in,used'

echo "[edge_regression] run CSV trace"
./trace_and_filter.sh \
  -module ERProbe \
  -lib "$(pwd)/edge_regression_trace_build/simv.daidir/kdb.elab++" \
  -keywords ERKeySrc,ERKeySink \
  -ports "$PORTS" \
  -output edge_regression_probe.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 8 \
  2>&1 | tee edge_regression_probe.log

echo "[edge_regression] run XLSX annotation"
./annotate_trace_xlsx.sh \
  -template edge_regression_trace_template.xlsx \
  -output edge_regression_annotated.xlsx \
  -lib edge_regression_trace_build/simv.daidir/kdb.elab++ \
  -keywords ERKeySrc,ERKeySink \
  -module ERProbe,ERKeySink \
  -ports "$PORTS" \
  --stream \
  -regcombo-as-keyword 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 8 \
  --match-cache-size 200000 \
  --keyword-batch-size 1 \
  2>&1 | tee edge_regression_annotate.log

echo "[edge_regression] assert results"
python3 - <<'PY'
import csv
from pathlib import Path
from openpyxl import load_workbook

filtered = Path("edge_regression_probe.csv").read_text()
for token in [
    "in_alias_bit,input,driver",
    "in_range_bit,input,driver",
    "out_bus[6],output,load",
    "out_bus[3],output,load",
    "out_scalar,output,load",
]:
    if token not in filtered:
        raise SystemExit(f"filtered CSV missing expected keyword path: {token}")
for token in [
    "in_const_after_end,input",
    "in_const_after_initial,input",
    "in_false_no_keyword,input",
    "unused_out,output",
]:
    if token in filtered:
        raise SystemExit(f"filtered CSV unexpectedly matched keyword path: {token}")

full_rows = list(csv.DictReader(Path("ERProbe_full.csv").open()))

def port_role(port, role):
    return [r for r in full_rows if r["port_name"] == port and r["role"] == role]

for port in ["in_alias_bit", "in_range_bit"]:
    drivers = port_role(port, "driver")
    bad = [
        r["signal_full_name"]
        for r in drivers
        if r["signal_full_name"].startswith("Const:")
        or "key_after_initial[0]" in r["signal_full_name"]
        or "key_after_initial[1]" in r["signal_full_name"]
        or "key_after_initial[3]" in r["signal_full_name"]
    ]
    if bad:
        raise SystemExit(f"{port} polluted by unrelated source: {bad}")
    if not any("u_key_after_initial.out" in r["signal_full_name"] for r in drivers):
        raise SystemExit(f"{port} did not reach ERKeySrc output")

for port in ["in_const_after_end", "in_const_after_initial", "in_false_no_keyword"]:
    drivers = port_role(port, "driver")
    if not any(r["signal_full_name"].startswith("Const:") for r in drivers):
        raise SystemExit(f"{port} did not resolve constant driver")
    if any("u_key_after_initial.out" in r["signal_full_name"] for r in drivers):
        raise SystemExit(f"{port} falsely matched keyword output")

wb = load_workbook("edge_regression_annotated.xlsx", data_only=False)
ws = wb.active
headers = [c.value for c in ws[1]]
probe_rows = [
    dict(zip(headers, row))
    for row in ws.iter_rows(min_row=2, values_only=True)
    if row and row[0] == "ERProbe"
]
if len(probe_rows) != 1:
    raise SystemExit(f"expected one ERProbe row, got {len(probe_rows)}")
row = probe_rows[0]
if "ID=32'sd7" not in str(row.get("parameters", "")):
    raise SystemExit(f"parameter annotation missing ID=7: {row.get('parameters')}")
for port in ["in_alias_bit", "in_range_bit", "out_bus[6]", "out_bus[3]", "out_scalar"]:
    if not str(row.get(port, "")).startswith("yes"):
        raise SystemExit(f"{port} not yes in XLSX: {row.get(port)}")
for port in ["in_const_after_end", "in_const_after_initial", "in_false_no_keyword"]:
    cell = str(row.get(port, ""))
    if not cell.startswith("no") or "Const:" not in cell:
        raise SystemExit(f"{port} missing constant no result in XLSX: {cell}")
if "NO_LOAD" not in str(row.get("unused_out", "")):
    raise SystemExit(f"unused_out missing NO_LOAD: {row.get('unused_out')}")

print("[edge_regression] assertions passed")
PY
