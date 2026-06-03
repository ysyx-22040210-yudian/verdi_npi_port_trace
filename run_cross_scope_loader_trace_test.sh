#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[cross_scope_loader] cwd=$PWD"
echo "[cross_scope_loader] clean previous outputs"
rm -rf cross_scope_loader_trace_build
rm -f cross_scope_loader_vcs.log cross_scope_loader_filtered.csv
rm -f cross_scope_loader_filtered_boundary.csv cross_scope_loader_filtered_full_owner.csv
rm -f cross_scope_loader_filtered__*.csv cross_scope_loader_trace.log
rm -f CSProducer_full.csv CSProducer_module_connections.csv
rm -f CSProducer_CSKeywordSink11_CSKeywordSink10_instances.txt

echo "[cross_scope_loader] build KDB"
mkdir -p cross_scope_loader_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top CrossScopeLoaderTop -f cross_scope_loader_trace_test.f \
  -Mdir=cross_scope_loader_trace_build/csrc \
  -o cross_scope_loader_trace_build/simv \
  -l cross_scope_loader_vcs.log
vcs_rc=$?
set -e
if [ ! -d cross_scope_loader_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[cross_scope_loader] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 cross_scope_loader_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[cross_scope_loader] KDB OK, vcs_rc=$vcs_rc"

echo "[cross_scope_loader] run trace_and_filter"
./trace_and_filter.sh \
  -module CSProducer \
  -lib "$(pwd)/cross_scope_loader_trace_build/simv.daidir/kdb.elab++" \
  -keywords CSKeywordSink11,CSKeywordSink10 \
  -ports out \
  -output cross_scope_loader_filtered.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 8 \
  2>&1 | tee cross_scope_loader_trace.log

echo "[cross_scope_loader] assert results"
python3 - <<'PY'
import csv
from pathlib import Path

filtered = list(csv.DictReader(Path("cross_scope_loader_filtered.csv").open()))
signals = [row["signal_full_name"] for row in filtered if row["port_name"] == "out" and row["role"] == "load"]

for expected in [
    "u_top_b.in",
    "u_top_c.in",
    "u_sibling.u_sibling_b.in",
    "u_sibling.u_sibling_c.in",
]:
    if not any(expected in sig for sig in signals):
        raise SystemExit(f"missing expected keyword load endpoint: {expected}\nfiltered={signals}")

if any(row["port_dir"] == "output" and row["role"] != "load" for row in filtered):
    raise SystemExit(f"output port filter kept non-load rows: {filtered}")

log_text = Path("cross_scope_loader_trace.log").read_text(errors="replace")
for marker in ["load_module_port_high_continue", "source_assign_load_fanout"]:
    if marker not in log_text:
        raise SystemExit(f"missing trace marker {marker}")

print("[cross_scope_loader] assertions passed")
PY
