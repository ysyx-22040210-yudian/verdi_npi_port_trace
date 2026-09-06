#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
PYTHON_BIN="${PYTHON_BIN:-python3}"

echo "[loader_pressure] cwd=$PWD"
echo "[loader_pressure] python_bin=$PYTHON_BIN"
echo "[loader_pressure] build KDB"
mkdir -p loader_pressure_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top LoaderPressureTop -f loader_pressure_trace_test.f \
  -Mdir=loader_pressure_trace_build/csrc \
  -o loader_pressure_trace_build/simv \
  -l loader_pressure_vcs.log
vcs_rc=$?
set -e
if [ ! -d loader_pressure_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[loader_pressure] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 loader_pressure_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[loader_pressure] KDB OK, vcs_rc=$vcs_rc"

echo "[loader_pressure] run trace_and_filter"
./trace_and_filter.sh \
  -module LPLoadTarget \
  -lib "$(pwd)/loader_pressure_trace_build/simv.daidir/kdb.elab++" \
  -keywords LPKeySink8 \
  -ports a \
  -output loader_pressure_filtered.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 4 \
  -assign-trace-depth 16 \
  -assign-expr-trace-depth 6 \
  -load-trace-node-limit 50000 \
  -load-trace-edge-limit 200000 \
  -load-trace-api-list-limit 50000 \
  -verdi-timeout-sec 900 \
  -trace-debug 1 \
  2>&1 | tee loader_pressure_trace.log

echo "[loader_pressure] assert filtered CSV"
"$PYTHON_BIN" - <<'PY'
import csv
from pathlib import Path

rows = list(csv.DictReader(Path("loader_pressure_filtered.csv").open()))
signals = [row["signal_full_name"] for row in rows if row["port_name"] == "a" and row["role"] == "load"]

required = [
    "LoaderPressureTop.u_root.u_sub.u_leaf.u_sink_direct.in",
    "LoaderPressureTop.u_root.u_sub.u_leaf.u_sink_alias.in",
    "LoaderPressureTop.u_root.u_sub.u_leaf.u_sink_concat.in",
    "LoaderPressureTop.u_root.u_sub.u_leaf.u_sink_lhs_hi.in",
    "LoaderPressureTop.u_root.u_sub.u_leaf.u_sink_lhs_lo.in",
    "LoaderPressureTop.u_root.u_sub.u_leaf.u_sink_param.in",
    "LoaderPressureTop.u_root.u_sub.u_leaf.u_sink_port.in",
    "LoaderPressureTop.u_root.u_sub.u_leaf.u_sink_gen2.in",
]
for token in required:
    if not any(token in sig for sig in signals):
        raise SystemExit(f"missing expected load token={token}; signals={signals}")

if any("LPDecoySameNames" in sig for sig in signals):
    raise SystemExit(f"decoy module leaked into filtered signals={signals}")

full_text = Path("LPLoadTarget_full.csv").read_text()
for token in [
    "LoaderPressureTop.A",
]:
    if token not in full_text:
        raise SystemExit(f"full trace missing token={token}")

print("[loader_pressure] assertions passed")
PY

echo "[loader_pressure] SUCCESS"
