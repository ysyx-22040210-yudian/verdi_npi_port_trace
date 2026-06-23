#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[ternary_driver] cwd=$PWD"
echo "[ternary_driver] clean previous outputs"
rm -rf ternary_driver_trace_build
rm -f ternary_driver_vcs.log ternary_driver_filtered.csv ternary_driver_filtered_boundary.csv
rm -f ternary_driver_filtered_full_owner.csv ternary_driver_filter.log
rm -f TDChild_full.csv TDChild_module_connections.csv TDChild_TDKeySrc_instances.txt

echo "[ternary_driver] build KDB"
mkdir -p ternary_driver_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top TDTernaryTop -f ternary_driver_trace_test.f \
  -Mdir=ternary_driver_trace_build/csrc \
  -o ternary_driver_trace_build/simv \
  -l ternary_driver_vcs.log
vcs_rc=$?
set -e
if [ ! -d ternary_driver_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[ternary_driver] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  exit "$vcs_rc"
fi
echo "[ternary_driver] KDB OK, vcs_rc=$vcs_rc"

echo "[ternary_driver] run trace/filter"
./trace_and_filter.sh \
  -module TDChild \
  -lib "$(pwd)/ternary_driver_trace_build/simv.daidir/kdb.elab++" \
  -keywords TDKeySrc \
  -ports bad_a,good_a \
  -output ternary_driver_filtered.csv \
  --keyword-batch-size 1 \
  --keyword-log-instances \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 8 \
  -trace-debug 1 \
  -log-file ternary_driver_filter.log

echo "[ternary_driver] assert results"
python3 - <<'PY'
import csv
from pathlib import Path

full_rows = list(csv.DictReader(Path("TDChild_full.csv").open()))
filtered_rows = list(csv.DictReader(Path("ternary_driver_filtered.csv").open()))
log_text = Path("ternary_driver_filter.log").read_text(errors="replace")

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

bad_drivers = signals("bad_a", "driver")
good_drivers = signals("good_a", "driver")

if any("u_cond_reg.out" in sig or "RegCombo" in sig for sig in bad_drivers):
    raise SystemExit(f"bad_a incorrectly kept ternary condition driver: {bad_drivers}")
if any("u_cond_reg" in sig for sig in filtered_signals("bad_a", "driver")):
    raise SystemExit(f"bad_a incorrectly matched keyword through ternary condition: {filtered_signals('bad_a', 'driver')}")
if filtered_signals("bad_a", "driver"):
    raise SystemExit(f"bad_a should not be keyword matched, got: {filtered_signals('bad_a', 'driver')}")

if not any("u_data_reg.out" in sig or "RegCombo" in sig for sig in good_drivers):
    raise SystemExit(f"good_a did not trace ternary data branch reg source: {good_drivers}")
if not filtered_signals("good_a", "driver"):
    raise SystemExit("good_a should match keyword through ternary data branch")

for token in [
    "driver_data_source_restrict",
    "driver_data_source_skip",
    "source_assign_driver_data_sources",
]:
    if token not in log_text:
        raise SystemExit(f"debug log missing {token}")

print("[ternary_driver] assertions passed")
PY

echo "[ternary_driver] SUCCESS"
