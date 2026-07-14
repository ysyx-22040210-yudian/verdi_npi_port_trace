#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[driver_constant_precision] clean previous outputs"
rm -rf driver_constant_precision_trace_build
rm -f driver_constant_precision_vcs.log driver_constant_precision_trace.log
rm -f driver_constant_precision_full.csv DCP_Target_module_connections.csv

echo "[driver_constant_precision] build KDB"
mkdir -p driver_constant_precision_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top DCP_Top -f driver_constant_precision_trace_test.f \
  -Mdir=driver_constant_precision_trace_build/csrc \
  -o driver_constant_precision_trace_build/simv \
  -l driver_constant_precision_vcs.log
vcs_rc=$?
set -e
if [ ! -d driver_constant_precision_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[driver_constant_precision] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 100 driver_constant_precision_vcs.log >&2 || true
  if [ "$vcs_rc" -eq 0 ]; then
    exit 1
  fi
  exit "$vcs_rc"
fi

echo "[driver_constant_precision] run trace"
./npi_trace.sh \
  -module DCP_Target \
  -lib "$(pwd)/driver_constant_precision_trace_build/simv.daidir/kdb.elab++" \
  -ports 'scope_const,generate_const,param_const,ifdef_const,range_bit0,range_bit1,asc_bit0,asc_bit7,asc_whole0,asc_whole7,symbolic_asc0,asc_port_from_desc[0],asc_port_from_desc[7],assign_map0,assign_map7,child_map0,child_map7,decl_init0,decl_init7,implicit_inactive,mux_stop' \
  -module-out DCP_Target_module_connections.csv \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 8 \
  -trace-debug 1 \
  -log-file driver_constant_precision_trace.log \
  > driver_constant_precision_full.csv

echo "[driver_constant_precision] assert exact scalar constants"
python3 - <<'PY'
import csv
import re
from pathlib import Path

rows = list(csv.DictReader(Path("driver_constant_precision_full.csv").open()))

def drivers(port):
    return [
        row["signal_full_name"]
        for row in rows
        if row["port_name"] == port and row["role"] == "driver"
    ]

CONST_BIT_RE = re.compile(r"^Const:(?:1'b([01xz])|'b([01xz])|'([01xz]))$", re.IGNORECASE)

def const_bit(value):
    match = CONST_BIT_RE.fullmatch(value)
    if match is None:
        return None
    return next(group.lower() for group in match.groups() if group is not None)

expected = {
    "scope_const": "1",
    "generate_const": "1",
    "param_const": "1",
    "ifdef_const": "1",
    "range_bit0": "0",
    "range_bit1": "1",
    "asc_bit0": "1",
    "asc_bit7": "0",
    "asc_whole0": "1",
    "asc_whole7": "0",
    "symbolic_asc0": "1",
    "asc_port_from_desc[0]": "1",
    "asc_port_from_desc[7]": "0",
    "assign_map0": "1",
    "assign_map7": "0",
    "child_map0": "1",
    "child_map7": "0",
    "decl_init0": "1",
    "decl_init7": "0",
}

for port, bit in expected.items():
    values = drivers(port)
    constants = [value for value in values if value.startswith("Const:")]
    parsed = [const_bit(value) for value in constants]
    if bit not in parsed:
        raise SystemExit(f"{port} missing Const:1'b{bit}: {values}")
    if any(value is None or value != bit for value in parsed):
        raise SystemExit(f"{port} contains a non-exact scalar constant: {values}")

inactive = drivers("implicit_inactive")
if any(value.startswith("Const:") for value in inactive):
    raise SystemExit(f"implicit_inactive leaked a non-elaborated generate constant: {inactive}")

mux = drivers("mux_stop")
if "COMBO_EXPR:ternary" not in mux:
    raise SystemExit(f"mux_stop must stop at ternary expression: {mux}")
if any(value.startswith("Const:") for value in mux):
    raise SystemExit(f"mux_stop leaked conditional constants: {mux}")

log = Path("driver_constant_precision_trace.log").read_text()
required_mapping_steps = {
    "ascending formal bit 0": re.compile(
        r"source_port_conn_driver_start .*port=asc_port_from_desc select=\[0\].*"
        r"starts=DCP_Top\.desc_port_source\[7\]"
    ),
    "ascending formal bit 7": re.compile(
        r"source_port_conn_driver_start .*port=asc_port_from_desc select=\[7\].*"
        r"starts=DCP_Top\.desc_port_source\[0\]"
    ),
    "ascending assignment bit 0": re.compile(
        r"source_assign_direct_driver_source signal=DCP_Top\.asc_assign_from_desc\[0\].*"
        r"drivers=DCP_Top\.desc_port_source\[7\]"
    ),
    "ascending assignment bit 7": re.compile(
        r"source_assign_direct_driver_source signal=DCP_Top\.asc_assign_from_desc\[7\].*"
        r"drivers=DCP_Top\.desc_port_source\[0\]"
    ),
    "child formal bit 7": re.compile(
        r"source_module_port_driver signal=DCP_Top\.asc_from_child_desc\[0\].*"
        r"drivers=DCP_Top\.u_desc_vector\.out\[7\]"
    ),
    "child formal bit 0": re.compile(
        r"source_module_port_driver signal=DCP_Top\.asc_from_child_desc\[7\].*"
        r"drivers=DCP_Top\.u_desc_vector\.out\[0\]"
    ),
}
for label, pattern in required_mapping_steps.items():
    if pattern.search(log) is None:
        raise SystemExit(f"missing exact {label} mapping in trace log")

print("[driver_constant_precision] assertions passed")
PY

echo "[driver_constant_precision] SUCCESS"
