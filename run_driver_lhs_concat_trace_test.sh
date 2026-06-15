#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[driver_lhs_concat] cwd=$PWD"
echo "[driver_lhs_concat] clean previous outputs"
rm -rf driver_lhs_concat_trace_build
rm -f driver_lhs_concat_vcs.log
rm -f driver_lhs_concat.csv driver_lhs_concat_boundary.csv driver_lhs_concat_full_owner.csv
rm -f driver_lhs_concat.log
rm -f DriverLhsConcatChild_full.csv DriverLhsConcatChild_module_connections.csv
rm -f DriverLhsConcatChild_DriverLhsConcatKeyword_instances.txt

echo "[driver_lhs_concat] build KDB"
mkdir -p driver_lhs_concat_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top DriverLhsConcatTop -f driver_lhs_concat_trace_test.f \
  -Mdir=driver_lhs_concat_trace_build/csrc \
  -o driver_lhs_concat_trace_build/simv \
  -l driver_lhs_concat_vcs.log
vcs_rc=$?
set -e
if [ ! -d driver_lhs_concat_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[driver_lhs_concat] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 driver_lhs_concat_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[driver_lhs_concat] KDB OK, vcs_rc=$vcs_rc"

echo "[driver_lhs_concat] trace child input drivers through LHS concat and nested RHS concat"
./trace_and_filter.sh \
  -module DriverLhsConcatChild \
  -lib "$(pwd)/driver_lhs_concat_trace_build/simv.daidir/kdb.elab++" \
  -keywords DriverLhsConcatKeyword \
  -ports 'a,a[2],a_reg,a_precise,a_precise[7],a_precise[6]' \
  -output driver_lhs_concat.csv \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 12 \
  -assign-expr-trace-depth 8 \
  2>&1 | tee driver_lhs_concat.log

echo "[driver_lhs_concat] assert results"
python3 - <<'PY'
import csv
from pathlib import Path

full_rows = list(csv.DictReader(Path("DriverLhsConcatChild_full.csv").open()))
filtered_rows = list(csv.DictReader(Path("driver_lhs_concat.csv").open()))

def full_signals(port):
    return [
        r["signal_full_name"]
        for r in full_rows
        if r["inst_full_name"] == "DriverLhsConcatTop.u_p0.u_child"
        and r["port_name"] == port
        and r["role"] == "driver"
    ]

def filtered_signals(port):
    return [
        r["signal_full_name"]
        for r in filtered_rows
        if r["inst_full_name"] == "DriverLhsConcatTop.u_p0.u_child"
        and r["port_name"] == port
        and r["role"] == "driver"
    ]

a_full = full_signals("a")
a_bit_full = full_signals("a[2]")
a_reg_full = full_signals("a_reg")
a_precise_full = full_signals("a_precise")
a_precise_bit_full = full_signals("a_precise[7]")
a_precise_noise_bit_full = full_signals("a_precise[6]")

for token in ["u_p1.e", "u_p1.h", "u_p1.u_key.out"]:
    if not any(token in sig for sig in a_full):
        raise SystemExit(f"a full trace did not continue through LHS/RHS concat to {token}; got {a_full}")

if not any("u_p1.u_key.out[2]" in sig for sig in a_bit_full):
    raise SystemExit(f"a[2] full trace did not preserve bit mapping to u_key.out[2]; got {a_bit_full}")

if not any("RegCombo" in sig or "/Always" in sig or "u_reg_src.out" in sig for sig in a_reg_full):
    raise SystemExit(f"a_reg full trace did not reach register endpoint; got {a_reg_full}")

if not any("u_key_precise.out" in sig for sig in a_precise_full):
    raise SystemExit(f"a_precise whole-port trace did not include keyword bit source; got {a_precise_full}")

if not any("c_precise" in sig or "u_key_precise.out[0]" in sig for sig in a_precise_bit_full):
    raise SystemExit(f"a_precise[7] did not map to the C lane; got {a_precise_bit_full}")
for bad in ["b_precise", "d_precise", "Const:7'b0000001", "Const:3'b101"]:
    if any(bad in sig for sig in a_precise_bit_full):
        raise SystemExit(f"a_precise[7] was polluted by adjacent concat lane {bad}; got {a_precise_bit_full}")

if any("u_key_precise" in sig or "c_precise" in sig for sig in a_precise_noise_bit_full):
    raise SystemExit(f"a_precise[6] falsely reached the C/keyword lane; got {a_precise_noise_bit_full}")

for port in ["a", "a[2]", "a_precise", "a_precise[7]"]:
    hits = filtered_signals(port)
    if not any("u_p1.u_key.out" in sig for sig in hits):
        if port not in ["a_precise", "a_precise[7]"] or not any("u_key_precise.out" in sig for sig in hits):
            raise SystemExit(f"filtered CSV missing keyword hit for {port}; got {hits}")

if filtered_signals("a_reg"):
    raise SystemExit(f"a_reg should not match keyword-only filtering; got {filtered_signals('a_reg')}")

if filtered_signals("a_precise[6]"):
    raise SystemExit(f"a_precise[6] should not match keyword-only filtering; got {filtered_signals('a_precise[6]')}")

print("[driver_lhs_concat] assertions passed")
PY

echo "[driver_lhs_concat] SUCCESS"
