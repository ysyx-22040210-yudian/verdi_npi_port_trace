#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[assign_loader_slice] cwd=$PWD"
echo "[assign_loader_slice] build KDB"
mkdir -p assign_loader_slice_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top AssignLoadTop -f assign_loader_slice_trace_test.f \
  -Mdir=assign_loader_slice_trace_build/csrc \
  -o assign_loader_slice_trace_build/simv \
  -l assign_loader_slice_vcs.log
vcs_rc=$?
set -e
if [ ! -d assign_loader_slice_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[assign_loader_slice] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  exit "$vcs_rc"
fi
echo "[assign_loader_slice] KDB OK, vcs_rc=$vcs_rc"

echo "[assign_loader_slice] run trace_and_filter"
./trace_and_filter.sh \
  -module AssignLoadTarget \
  -lib "$(pwd)/assign_loader_slice_trace_build/simv.daidir/kdb.elab++" \
  -keywords AssignLoadSink \
  -ports A \
  -output assign_loader_slice_filtered.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 4 \
  -assign-trace-depth 4 \
  -assign-expr-trace-depth 0 \
  2>&1 | tee assign_loader_slice_trace.log

echo "[assign_loader_slice] assert filtered CSV"
python3 - <<'PY'
import csv
from pathlib import Path

rows = list(csv.DictReader(Path("assign_loader_slice_filtered.csv").open()))
load_hits = [
    row["signal_full_name"]
    for row in rows
    if row["port_name"] == "A" and row["role"] == "load"
]
for token in ["u_sink_b.in", "u_sink_c.in"]:
    if not any(token in signal for signal in load_hits):
        raise SystemExit(f"missing keyword load hit through slice assign: {token}; rows={rows}")

full_text = Path("AssignLoadTarget_full.csv").read_text()
for token in ["B", "C", "u_sink_b.in", "u_sink_c.in"]:
    if token not in full_text:
        raise SystemExit(f"full trace did not record expected slice fanout token: {token}")

print("[assign_loader_slice] assertions passed")
PY
