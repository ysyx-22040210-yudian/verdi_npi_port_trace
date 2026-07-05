#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[bit_precision_stress] cwd=$PWD"
echo "[bit_precision_stress] clean previous outputs"
rm -rf bit_precision_stress_trace_build
rm -f bit_precision_stress_vcs.log bit_precision_stress_trace.log
rm -f bit_precision_stress_full.csv bit_precision_stress_filtered.csv
rm -f bit_precision_stress_filtered_boundary.csv bit_precision_stress_filtered_full_owner.csv
rm -f BPStressChild_module_connections.csv BPStressChild_full.csv
rm -f BPStressChild_BPStressKeySrc_BPStressKeySink_BPStressRegSink_instances.txt

echo "[bit_precision_stress] build KDB"
mkdir -p bit_precision_stress_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top BPStressTop -f bit_precision_stress_trace_test.f \
  -Mdir=bit_precision_stress_trace_build/csrc \
  -o bit_precision_stress_trace_build/simv \
  -l bit_precision_stress_vcs.log
vcs_rc=$?
set -e
if [ ! -d bit_precision_stress_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[bit_precision_stress] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 120 bit_precision_stress_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[bit_precision_stress] KDB OK, vcs_rc=$vcs_rc"

echo "[bit_precision_stress] run raw NPI trace"
./npi_trace.sh \
  -module BPStressChild \
  -lib "$(pwd)/bit_precision_stress_trace_build/simv.daidir/kdb.elab++" \
  -ports 'A[7],A[6],one_bit_from_bus,ternary_stop,Y,Y[7],Y[13]' \
  -module-out BPStressChild_module_connections.csv \
  -const-source-fallback 1 \
  -const-trace-depth 10 \
  -assign-trace-depth 10 \
  -assign-expr-trace-depth 10 \
  -trace-debug 1 \
  -log-file bit_precision_stress_trace.log \
  > bit_precision_stress_full.csv

cp bit_precision_stress_full.csv BPStressChild_full.csv

echo "[bit_precision_stress] run trace/filter"
./trace_and_filter.sh \
  -module BPStressChild \
  -lib "$(pwd)/bit_precision_stress_trace_build/simv.daidir/kdb.elab++" \
  -keywords BPStressKeySrc,BPStressKeySink,BPStressRegSink \
  -ports 'A[7],A[6],one_bit_from_bus,ternary_stop,Y,Y[7],Y[13]' \
  -output bit_precision_stress_filtered.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 10 \
  -assign-trace-depth 10 \
  -assign-expr-trace-depth 10 \
  -trace-debug 1 \
  -log-file bit_precision_stress_trace.log

echo "[bit_precision_stress] assert bit-precise results"
python3 - <<'PY'
import csv
from pathlib import Path

full_rows = list(csv.DictReader(Path("bit_precision_stress_full.csv").open()))
filtered_rows = list(csv.DictReader(Path("bit_precision_stress_filtered.csv").open()))

def signals(rows, port, role):
    return [r["signal_full_name"] for r in rows if r["port_name"] == port and r["role"] == role]

def has(items, token):
    return any(token in item for item in items)

a7_drivers = signals(full_rows, "A[7]", "driver")
a6_drivers = signals(full_rows, "A[6]", "driver")
one_bit_drivers = signals(full_rows, "one_bit_from_bus", "driver")
ternary_drivers = signals(full_rows, "ternary_stop", "driver")
y_loads = signals(full_rows, "Y", "load")
y7_loads = signals(full_rows, "Y[7]", "load")
y13_loads = signals(full_rows, "Y[13]", "load")

a7_filtered = signals(filtered_rows, "A[7]", "driver")
a6_filtered = signals(filtered_rows, "A[6]", "driver")
one_bit_filtered = signals(filtered_rows, "one_bit_from_bus", "driver")
ternary_filtered = signals(filtered_rows, "ternary_stop", "driver")
y_filtered_loads = signals(filtered_rows, "Y", "load")
y7_filtered_loads = signals(filtered_rows, "Y[7]", "load")
y13_filtered_loads = signals(filtered_rows, "Y[13]", "load")

if not has(a7_drivers, "u_key7.out"):
    raise SystemExit(f"A[7] missing keyword driver: {a7_drivers}")
if has(a7_drivers, "Const:"):
    raise SystemExit(f"A[7] should not include sibling constants: {a7_drivers}")
if not a7_filtered or has(a7_filtered, "Const:"):
    raise SystemExit(f"A[7] filtered should be keyword-only: {a7_filtered}")

if not has(a6_drivers, "Const:1'b1"):
    raise SystemExit(f"A[6] missing projected tie1: {a6_drivers}")
if has(a6_drivers, "u_key7.out"):
    raise SystemExit(f"A[6] incorrectly includes A[7] keyword: {a6_drivers}")
if a6_filtered:
    raise SystemExit(f"A[6] should not match keywords: {a6_filtered}")

if not has(one_bit_drivers, "u_key7.out"):
    raise SystemExit(f"one_bit_from_bus missing B[7] keyword source: {one_bit_drivers}")
if has(one_bit_drivers, "32'h") or has(one_bit_drivers, "32'b") or has(one_bit_drivers, "Const:32"):
    raise SystemExit(f"one_bit_from_bus leaked whole-vector const: {one_bit_drivers}")
if has(one_bit_drivers, "Const:1'b1") or has(one_bit_drivers, "Const:1'b0"):
    raise SystemExit(f"one_bit_from_bus should not include sibling bit constants: {one_bit_drivers}")
if not one_bit_filtered:
    raise SystemExit(f"one_bit_from_bus should match keyword through wide bit chain: {one_bit_filtered}")

if not has(ternary_drivers, "COMBO_EXPR:ternary"):
    raise SystemExit(f"ternary_stop should stop at combo expression: {ternary_drivers}")
if has(ternary_drivers, "u_key7.out") or has(ternary_drivers, "Const:1'b1"):
    raise SystemExit(f"ternary_stop should not continue into data branches: {ternary_drivers}")
if ternary_filtered:
    raise SystemExit(f"ternary_stop should not be keyword-filtered: {ternary_filtered}")

if not (has(y_loads, "u_sink_low.in") or has(y_loads, "u_reg_high.in")):
    raise SystemExit(f"Y loads missing sliced fanout endpoints: {y_loads}")
if not y_filtered_loads:
    raise SystemExit(f"Y should have keyword/reg loader matches: {y_filtered_loads}")

if not has(y7_loads, "u_sink_low.in"):
    raise SystemExit(f"Y[7] missing low-slice loader: {y7_loads}")
if has(y7_loads, "u_reg_high.in"):
    raise SystemExit(f"Y[7] leaked sibling high-slice loader: {y7_loads}")
if not y7_filtered_loads or has(y7_filtered_loads, "u_reg_high.in"):
    raise SystemExit(f"Y[7] filtered loader should only match low-slice keyword: {y7_filtered_loads}")

if not has(y13_loads, "u_reg_high.in"):
    raise SystemExit(f"Y[13] missing high-slice reg loader: {y13_loads}")
if has(y13_loads, "u_sink_low.in"):
    raise SystemExit(f"Y[13] leaked sibling low-slice loader: {y13_loads}")
if not y13_filtered_loads or has(y13_filtered_loads, "u_sink_low.in"):
    raise SystemExit(f"Y[13] filtered loader should only match high-slice reg keyword: {y13_filtered_loads}")

log_text = Path("bit_precision_stress_trace.log").read_text(errors="replace")
required_log_tokens = [
    "trace_port_bit",
    "select_hdl_by_index",
    "bit_driver_source_restrict",
    "driver_combo_stop",
]
missing = [tok for tok in required_log_tokens if tok not in log_text]
if missing:
    raise SystemExit(f"debug log missing expected evidence {missing}")

print("[bit_precision_stress] assertions passed")
PY

echo "[bit_precision_stress] SUCCESS"
