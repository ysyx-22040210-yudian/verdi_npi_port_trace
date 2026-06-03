#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[keyword_assign_driver] cwd=$PWD"
echo "[keyword_assign_driver] build KDB"
mkdir -p keyword_assign_driver_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top KeywordAssignDriverTop -f keyword_assign_driver_trace_test.f \
  -Mdir=keyword_assign_driver_trace_build/csrc \
  -o keyword_assign_driver_trace_build/simv \
  -l keyword_assign_driver_vcs.log
vcs_rc=$?
set -e
if [ ! -d keyword_assign_driver_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[keyword_assign_driver] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  exit "$vcs_rc"
fi
echo "[keyword_assign_driver] KDB OK, vcs_rc=$vcs_rc"

echo "[keyword_assign_driver] run trace_and_filter"
./trace_and_filter.sh \
  -module AssignDriverChild \
  -lib "$(pwd)/keyword_assign_driver_trace_build/simv.daidir/kdb.elab++" \
  -keywords KeyMod \
  -ports a \
  -output keyword_assign_driver_filtered.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 4 \
  -assign-trace-depth 4 \
  -assign-expr-trace-depth 0 \
  2>&1 | tee keyword_assign_driver_trace.log

echo "[keyword_assign_driver] assert filtered CSV"
python3 - <<'PY'
import csv
from pathlib import Path

rows = list(csv.DictReader(Path("keyword_assign_driver_filtered.csv").open()))
hits = [
    row["signal_full_name"]
    for row in rows
    if row["port_name"] == "a" and row["role"] == "driver"
]
if not any("u_key.out" in signal for signal in hits):
    raise SystemExit(f"missing KeyMod driver hit through assign b=c: {rows}")

full_text = Path("AssignDriverChild_full.csv").read_text()
for token in ["KeywordAssignDriverTop.c", "KeywordAssignDriverTop.u_key.out"]:
    if token not in full_text:
        raise SystemExit(f"full trace missing expected token: {token}")

print("[keyword_assign_driver] assertions passed")
PY
