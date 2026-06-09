#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[loader_unknown_direction] cwd=$PWD"
echo "[loader_unknown_direction] clean previous outputs"
rm -rf loader_unknown_direction_trace_build
rm -f loader_unknown_direction_vcs.log
rm -f loader_unknown_direction.csv loader_unknown_direction_boundary.csv loader_unknown_direction_full_owner.csv
rm -f loader_unknown_direction.log
rm -f LoaderUnknownDirTarget_full.csv LoaderUnknownDirTarget_module_connections.csv
rm -f LoaderUnknownDirTarget_LoaderUnknownDirKeyword_instances.txt

echo "[loader_unknown_direction] build KDB"
mkdir -p loader_unknown_direction_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top LoaderUnknownDirTop -f loader_unknown_direction_trace_test.f \
  -Mdir=loader_unknown_direction_trace_build/csrc \
  -o loader_unknown_direction_trace_build/simv \
  -l loader_unknown_direction_vcs.log
vcs_rc=$?
set -e
if [ ! -d loader_unknown_direction_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[loader_unknown_direction] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 loader_unknown_direction_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[loader_unknown_direction] KDB OK, vcs_rc=$vcs_rc"

echo "[loader_unknown_direction] trace target output loaders through unknown-direction sibling and slice assigns"
./trace_and_filter.sh \
  -module LoaderUnknownDirTarget \
  -lib "$(pwd)/loader_unknown_direction_trace_build/simv.daidir/kdb.elab++" \
  -keywords LoaderUnknownDirKeyword \
  -ports A \
  -output loader_unknown_direction.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 4 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 2 \
  -trace-debug 1 \
  -log-file loader_unknown_direction.log

echo "[loader_unknown_direction] assert results"
python3 - <<'PY'
import csv
from pathlib import Path

full_rows = list(csv.DictReader(Path("LoaderUnknownDirTarget_full.csv").open()))
load_hits = [
    row["signal_full_name"]
    for row in full_rows
    if row["port_name"] == "A" and row["role"] == "load"
]
for token in ["B", "C", "u_key_b.in", "u_key_c.in"]:
    if not any(token in signal for signal in load_hits):
        raise SystemExit(f"missing loader trace token {token}; loads={load_hits}")

filtered_rows = list(csv.DictReader(Path("loader_unknown_direction.csv").open()))
filtered_hits = [
    row["signal_full_name"]
    for row in filtered_rows
    if row["port_name"] == "A" and row["role"] == "load"
]
for token in ["u_key_b.in", "u_key_c.in"]:
    if not any(token in signal for signal in filtered_hits):
        raise SystemExit(f"missing filtered keyword hit {token}; rows={filtered_rows}")

log_text = Path("loader_unknown_direction.log").read_text(errors="replace")
if "source_assign_direct_load_fanout" not in log_text:
    raise SystemExit("debug log did not record source_assign_direct_load_fanout")

print("[loader_unknown_direction] assertions passed")
PY

echo "[loader_unknown_direction] SUCCESS"

