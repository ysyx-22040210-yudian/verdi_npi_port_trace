#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[driver_precise_stress] cwd=$PWD"
echo "[driver_precise_stress] clean previous outputs"
rm -rf driver_precise_stress_trace_build
rm -f driver_precise_stress_vcs.log
rm -f driver_precise_stress.csv driver_precise_stress_boundary.csv driver_precise_stress_full_owner.csv
rm -f driver_precise_stress.log
rm -f DPStressChild_full.csv DPStressChild_module_connections.csv
rm -f DPStressChild_DPStressKey_instances.txt DPStressChild_DPStressKey_instances__batch_*.txt

echo "[driver_precise_stress] build KDB"
mkdir -p driver_precise_stress_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top DPStressTop -f driver_precise_stress_trace_test.f \
  -Mdir=driver_precise_stress_trace_build/csrc \
  -o driver_precise_stress_trace_build/simv \
  -l driver_precise_stress_vcs.log
vcs_rc=$?
set -e
if [ ! -d driver_precise_stress_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[driver_precise_stress] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 driver_precise_stress_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[driver_precise_stress] KDB OK, vcs_rc=$vcs_rc"

PORTS='deep_bus,deep_bus[13],deep_bus[20],precise_bus,precise_bus[7],precise_bus[6],precise_bus[8],bridge_bus,bridge_bus[13],bridge_bus[20],lhs_lane,lhs_lane[3],reg_lane,scalar_passthru'

echo "[driver_precise_stress] trace complex driver paths"
./trace_and_filter.sh \
  -module DPStressChild \
  -lib "$(pwd)/driver_precise_stress_trace_build/simv.daidir/kdb.elab++" \
  -keywords DPStressKey \
  -ports "$PORTS" \
  -output driver_precise_stress.csv \
  -const-source-fallback 1 \
  -const-trace-depth 10 \
  -assign-trace-depth 18 \
  -assign-expr-trace-depth 12 \
  -trace-debug 1 \
  -log-file driver_precise_stress.log

echo "[driver_precise_stress] assert results"
python3 - <<'PY'
import csv
from pathlib import Path

full_rows = list(csv.DictReader(Path("DPStressChild_full.csv").open()))
filtered_rows = list(csv.DictReader(Path("driver_precise_stress.csv").open()))
inst = "DPStressTop.u_sub.u_p1.u_p0.u_child"

def full_signals(port):
    return [
        r["signal_full_name"]
        for r in full_rows
        if r["inst_full_name"] == inst
        and r["port_name"] == port
        and r["role"] == "driver"
    ]

def filtered_signals(port):
    return [
        r["signal_full_name"]
        for r in filtered_rows
        if r["inst_full_name"] == inst
        and r["port_name"] == port
        and r["role"] == "driver"
    ]

def require_any(port, rows, tokens):
    for token in tokens:
        if any(token in sig for sig in rows):
            return
    raise SystemExit(f"{port} missing any of {tokens}; got {rows}")

def reject_any(port, rows, tokens):
    for token in tokens:
        if any(token in sig for sig in rows):
            raise SystemExit(f"{port} was polluted by {token}; got {rows}")

precise7 = full_signals("precise_bus[7]")
precise6 = full_signals("precise_bus[6]")
precise8 = full_signals("precise_bus[8]")
require_any("precise_bus[7]", precise7, ["precise_c", "u_key_precise.out[0]"])
reject_any("precise_bus[7]", precise7, [
    "precise_b[", ".precise_b[", "precise_d[", ".precise_d[",
    "Const:7'b0101010", "Const:3'b101"
])
require_any("precise_bus[6]", precise6, ["precise_b[6]", "Const:7'b0101010"])
reject_any("precise_bus[6]", precise6, ["precise_c", "u_key_precise"])
require_any("precise_bus[8]", precise8, ["precise_d[0]", "Const:3'b101"])
reject_any("precise_bus[8]", precise8, ["precise_c", "u_key_precise"])

require_any("deep_bus[13]", full_signals("deep_bus[13]"), ["u_key_deep_lane1.out[5]"])
reject_any("deep_bus[20]", full_signals("deep_bus[20]"), ["u_key_deep_lane1", "u_key_deep_lane3"])
require_any("bridge_bus[13]", full_signals("bridge_bus[13]"), ["u_key_bridge_lane1.out[5]"])
reject_any("bridge_bus[20]", full_signals("bridge_bus[20]"), ["u_key_bridge_lane1", "u_key_bridge_lane3"])
require_any("lhs_lane[3]", full_signals("lhs_lane[3]"), ["u_key_lhs_lane.out[3]"])
require_any("reg_lane", full_signals("reg_lane"), ["Reg", "Always", "u_reg_lane.out"])
require_any("scalar_passthru", full_signals("scalar_passthru"), ["u_key_scalar.out"])

for port, tokens in {
    "precise_bus[7]": ["u_key_precise.out"],
    "deep_bus[13]": ["u_key_deep_lane1.out"],
    "bridge_bus[13]": ["u_key_bridge_lane1.out"],
    "lhs_lane[3]": ["u_key_lhs_lane.out"],
    "scalar_passthru": ["u_key_scalar.out"],
}.items():
    require_any(port, filtered_signals(port), tokens)

for port in ["precise_bus[6]", "precise_bus[8]", "deep_bus[20]", "bridge_bus[20]", "reg_lane"]:
    hits = filtered_signals(port)
    if hits:
        raise SystemExit(f"{port} should not match keyword filtering; got {hits}")

whole_hits = filtered_signals("precise_bus")
require_any("precise_bus", whole_hits, ["u_key_precise.out"])
require_any("deep_bus", filtered_signals("deep_bus"), ["u_key_deep_lane1.out", "u_key_deep_lane3.out"])
require_any("bridge_bus", filtered_signals("bridge_bus"), ["u_key_bridge_lane1.out", "u_key_bridge_lane3.out"])

print("[driver_precise_stress] assertions passed")
PY

echo "[driver_precise_stress] SUCCESS"
