#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[scalar_bit_conn] cwd=$PWD"
echo "[scalar_bit_conn] clean previous outputs"
rm -rf scalar_bit_conn_trace_build
rm -f scalar_bit_conn_vcs.log scalar_bit_conn_trace.log
rm -f scalar_bit_conn_filtered.csv scalar_bit_conn_filtered_boundary.csv scalar_bit_conn_filtered_full_owner.csv
rm -f ScalarBitConnChild_full.csv ScalarBitConnChild_module_connections.csv
rm -f ScalarBitConnChild_ScalarBitConnKeySrc_instances.txt

echo "[scalar_bit_conn] build KDB"
mkdir -p scalar_bit_conn_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top ScalarBitConnTop -f scalar_bit_conn_trace_test.f \
  -Mdir=scalar_bit_conn_trace_build/csrc \
  -o scalar_bit_conn_trace_build/simv \
  -l scalar_bit_conn_vcs.log
vcs_rc=$?
set -e
if [ ! -d scalar_bit_conn_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[scalar_bit_conn] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 120 scalar_bit_conn_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[scalar_bit_conn] KDB OK, vcs_rc=$vcs_rc"

echo "[scalar_bit_conn] run trace/filter"
./trace_and_filter.sh \
  -module ScalarBitConnChild \
  -lib "$(pwd)/scalar_bit_conn_trace_build/simv.daidir/kdb.elab++" \
  -keywords ScalarBitConnKeySrc \
  -ports a,m0,m1 \
  -output scalar_bit_conn_filtered.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 8 \
  -trace-debug 1 \
  -log-file scalar_bit_conn_trace.log

echo "[scalar_bit_conn] assert scalar port bit-select connection precision"
python3 - <<'PY'
import csv
from pathlib import Path

full_rows = list(csv.DictReader(Path("ScalarBitConnChild_full.csv").open()))
filtered_rows = list(csv.DictReader(Path("scalar_bit_conn_filtered.csv").open()))

def signals(rows, port, role):
    return [r["signal_full_name"] for r in rows if r["port_name"] == port and r["role"] == role]

def has(items, token):
    return any(token in item for item in items)

a_drivers = signals(full_rows, "a", "driver")
m0_drivers = signals(full_rows, "m0", "driver")
m1_drivers = signals(full_rows, "m1", "driver")
a_filtered = signals(filtered_rows, "a", "driver")
m0_filtered = signals(filtered_rows, "m0", "driver")
m1_filtered = signals(filtered_rows, "m1", "driver")

for name, drivers, filtered in [
    ("a", a_drivers, a_filtered),
    ("m0", m0_drivers, m0_filtered),
]:
    if not has(drivers, "u_key7.out"):
        raise SystemExit(f"{name} missing keyword driver through bus[7]: {drivers}")
    if has(drivers, "Const:"):
        raise SystemExit(f"{name} leaked sibling bus constants: {drivers}")
    if not filtered:
        raise SystemExit(f"{name} should be keyword-filtered: {filtered}")
    if has(filtered, "Const:"):
        raise SystemExit(f"{name} filtered output leaked const: {filtered}")

if has(m1_drivers, "u_key7.out"):
    raise SystemExit(f"m1 incorrectly includes bus[7] keyword driver: {m1_drivers}")
if not has(m1_drivers, "Const:1'b"):
    raise SystemExit(f"m1 should report projected constant from bus[8]: {m1_drivers}")
if m1_filtered:
    raise SystemExit(f"m1 should not be keyword-filtered: {m1_filtered}")

log_text = Path("scalar_bit_conn_trace.log").read_text(errors="replace")
for token in [
    "source_port_conn_driver_start",
    "driver_precise_start_continue",
    "bit_driver_source_restrict",
]:
    if token not in log_text:
        raise SystemExit(f"debug log missing {token}")

print("[scalar_bit_conn] assertions passed")
PY

echo "[scalar_bit_conn] SUCCESS"
