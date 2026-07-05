#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[loader_bit_precision] cwd=$PWD"
echo "[loader_bit_precision] clean previous outputs"
rm -rf loader_bit_precision_trace_build
rm -f loader_bit_precision_vcs.log loader_bit_precision_trace.log
rm -f loader_bit_precision_filtered.csv loader_bit_precision_filtered_boundary.csv loader_bit_precision_filtered_full_owner.csv
rm -f LBPTarget_full.csv LBPTarget_module_connections.csv LBPTarget_LBPKeySink_instances.txt

echo "[loader_bit_precision] build KDB"
mkdir -p loader_bit_precision_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top LBPTop -f loader_bit_precision_trace_test.f \
  -Mdir=loader_bit_precision_trace_build/csrc \
  -o loader_bit_precision_trace_build/simv \
  -l loader_bit_precision_vcs.log
vcs_rc=$?
set -e
if [ ! -d loader_bit_precision_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[loader_bit_precision] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 120 loader_bit_precision_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[loader_bit_precision] KDB OK, vcs_rc=$vcs_rc"

echo "[loader_bit_precision] run trace/filter"
./trace_and_filter.sh \
  -module LBPTarget \
  -lib "$(pwd)/loader_bit_precision_trace_build/simv.daidir/kdb.elab++" \
  -keywords LBPKeySink \
  -ports 'A[7]' \
  -output loader_bit_precision_filtered.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 8 \
  -trace-debug 1 \
  -log-file loader_bit_precision_trace.log

echo "[loader_bit_precision] assert bit-precise loader fanout"
python3 - <<'PY'
import csv
from pathlib import Path

full_rows = list(csv.DictReader(Path("LBPTarget_full.csv").open()))
filtered_rows = list(csv.DictReader(Path("loader_bit_precision_filtered.csv").open()))

def signals(rows, port, role):
    return [
        row["signal_full_name"]
        for row in rows
        if row["port_name"] == port and row["role"] == role
    ]

loads = signals(full_rows, "A[7]", "load")
filtered_loads = signals(filtered_rows, "A[7]", "load")

def has(items, token):
    return any(token in item for item in items)

if not has(loads, "u_key7.in"):
    raise SystemExit(f"A[7] missing expected loader through B[7]: {loads}")
for bad in ["u_key0.in", "u_key8.in"]:
    if has(loads, bad):
        raise SystemExit(f"A[7] leaked sibling loader {bad}: {loads}")
    if has(filtered_loads, bad):
        raise SystemExit(f"A[7] filtered output leaked sibling loader {bad}: {filtered_loads}")
if not filtered_loads:
    raise SystemExit(f"A[7] should be keyword-filtered through B[7]: {filtered_loads}")

log_text = Path("loader_bit_precision_trace.log").read_text(errors="replace")
for token in [
    "source_assign_load_fanout",
    "module_conn_base_query_skip",
]:
    if token not in log_text:
        raise SystemExit(f"debug log missing {token}")

print("[loader_bit_precision] assertions passed")
PY

echo "[loader_bit_precision] SUCCESS"
