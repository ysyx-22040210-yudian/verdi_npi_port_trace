#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[bit_select_precision] cwd=$PWD"
echo "[bit_select_precision] clean previous outputs"
rm -rf bit_select_precision_trace_build
rm -f bit_select_precision_vcs.log bit_select_precision_filtered.csv
rm -f bit_select_precision_filtered_boundary.csv bit_select_precision_filtered_full_owner.csv
rm -f bit_select_precision_filter.log
rm -f BSPChild_full.csv BSPChild_module_connections.csv BSPChild_BSPKeySrc_instances.txt

echo "[bit_select_precision] build KDB"
mkdir -p bit_select_precision_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top BSPTop -f bit_select_precision_trace_test.f \
  -Mdir=bit_select_precision_trace_build/csrc \
  -o bit_select_precision_trace_build/simv \
  -l bit_select_precision_vcs.log
vcs_rc=$?
set -e
if [ ! -d bit_select_precision_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[bit_select_precision] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 bit_select_precision_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[bit_select_precision] KDB OK, vcs_rc=$vcs_rc"

echo "[bit_select_precision] run trace/filter"
./trace_and_filter.sh \
  -module BSPChild \
  -lib "$(pwd)/bit_select_precision_trace_build/simv.daidir/kdb.elab++" \
  -keywords BSPKeySrc \
  -ports 'A[7],A[6]' \
  -output bit_select_precision_filtered.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 8 \
  -trace-debug 1 \
  -log-file bit_select_precision_filter.log

echo "[bit_select_precision] assert bit-precise results"
python3 - <<'PY'
import csv
from pathlib import Path

full_rows = list(csv.DictReader(Path("BSPChild_full.csv").open()))
filtered_rows = list(csv.DictReader(Path("bit_select_precision_filtered.csv").open()))

def signals(port, role):
    return [
        row["signal_full_name"]
        for row in full_rows
        if row["port_name"] == port and row["role"] == role
    ]

def filtered_signals(port, role):
    return [
        row["signal_full_name"]
        for row in filtered_rows
        if row["port_name"] == port and row["role"] == role
    ]

def has(items, token):
    return any(token in item for item in items)

a7_drivers = signals("A[7]", "driver")
a6_drivers = signals("A[6]", "driver")
a7_filtered = filtered_signals("A[7]", "driver")
a6_filtered = filtered_signals("A[6]", "driver")

if not has(a7_drivers, "u_key7.out"):
    raise SystemExit(f"A[7] missing keyword driver: {a7_drivers}")
if has(a7_drivers, "Const:1'b1") or has(a7_drivers, "Const:'b1"):
    raise SystemExit(f"A[7] incorrectly includes sibling tie1: {a7_drivers}")
if not a7_filtered:
    raise SystemExit("A[7] should be filtered as keyword-connected")
if has(a7_filtered, "Const:"):
    raise SystemExit(f"A[7] filtered rows should not include const: {a7_filtered}")

if not (has(a6_drivers, "Const:1'b1") or has(a6_drivers, "Const:'b1")):
    raise SystemExit(f"A[6] missing tie1 driver: {a6_drivers}")
if has(a6_drivers, "u_key7.out"):
    raise SystemExit(f"A[6] incorrectly includes keyword driver: {a6_drivers}")
if a6_filtered:
    raise SystemExit(f"A[6] should not be keyword-filtered: {a6_filtered}")

log_text = Path("bit_select_precision_filter.log").read_text(errors="replace")
if "bit_driver_source_restrict signal=" not in log_text:
    raise SystemExit("debug log missing bit_driver_source_restrict evidence")

print("[bit_select_precision] assertions passed")
PY

echo "[bit_select_precision] SUCCESS"
