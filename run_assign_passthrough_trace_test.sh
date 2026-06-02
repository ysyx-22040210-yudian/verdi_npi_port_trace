#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[assign_passthrough] cwd=$PWD"
echo "[assign_passthrough] build KDB"
mkdir -p assign_passthrough_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top AssignPassTop -f assign_passthrough_trace_test.f \
  -Mdir=assign_passthrough_trace_build/csrc \
  -o assign_passthrough_trace_build/simv \
  -l assign_passthrough_vcs.log
vcs_rc=$?
set -e
if [ ! -d assign_passthrough_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[assign_passthrough] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  exit "$vcs_rc"
fi
echo "[assign_passthrough] KDB OK, vcs_rc=$vcs_rc"

echo "[assign_passthrough] run trace_and_filter"
./trace_and_filter.sh \
  -module AssignPassTarget \
  -lib "$(pwd)/assign_passthrough_trace_build/simv.daidir/kdb.elab++" \
  -keywords AssignPassKey \
  -ports a,direct \
  -output assign_passthrough_filtered.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 4 \
  -assign-trace-depth 4 \
  -assign-expr-trace-depth 0 \
  2>&1 | tee assign_passthrough_trace.log

echo "[assign_passthrough] assert filtered CSV"
python3 - <<'PY'
import csv
from pathlib import Path

rows = list(csv.DictReader(Path("assign_passthrough_filtered.csv").open()))
hits = {(row["port_name"], row["role"]) for row in rows}
for expected in [("a", "driver"), ("direct", "driver")]:
    if expected not in hits:
        raise SystemExit(f"missing keyword driver hit through assign pass-through: {expected}; rows={rows}")

full_text = Path("AssignPassTarget_full.csv").read_text()
for token in ["mid1", "key_out", "direct_key_out"]:
    if token not in full_text:
        raise SystemExit(f"full trace did not record expected assign pass-through token: {token}")
if "u_key_chain.out" not in full_text or "u_key_direct.out" not in full_text:
    raise SystemExit("full trace did not continue from assign nets to keyword output ports")

print("[assign_passthrough] assertions passed")
PY
