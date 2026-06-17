#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[loader_scope_repro] cwd=$PWD"
echo "[loader_scope_repro] clean previous outputs"
rm -rf loader_scope_trace_build
rm -f loader_scope_vcs.log loader_scope_full.csv loader_scope_module.csv loader_scope_trace.log

echo "[loader_scope_repro] build KDB"
mkdir -p loader_scope_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top LoaderScopeTop -f loader_scope_trace_test.f \
  -Mdir=loader_scope_trace_build/csrc \
  -o loader_scope_trace_build/simv \
  -l loader_scope_vcs.log
vcs_rc=$?
set -e
if [ ! -d loader_scope_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[loader_scope_repro] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 loader_scope_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[loader_scope_repro] KDB OK, vcs_rc=$vcs_rc"

echo "[loader_scope_repro] run NPI trace"
./npi_trace.sh \
  -module LoaderScopeChild0 \
  -lib "$(pwd)/loader_scope_trace_build/simv.daidir/kdb.elab++" \
  -ports a \
  -module-out loader_scope_module.csv \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 12 \
  -assign-expr-trace-depth 8 \
  -trace-debug 1 \
  -log-file loader_scope_trace.log \
  > loader_scope_full.csv

echo "[loader_scope_repro] inspect key log lines"
grep -E "source_module_port_load_(probe|match|empty)|load_module_port_high_continue" loader_scope_trace.log | tail -n 80 || true

echo "[loader_scope_repro] inspect full csv"
grep -E "u_child1|u_sink|RegCombo|Counter|rb|NO_LOAD" loader_scope_full.csv || true

python3 - <<'PY'
import csv
from pathlib import Path

rows = list(csv.DictReader(Path("loader_scope_full.csv").open()))
loads = [r["signal_full_name"] for r in rows if r["role"] == "load"]
print("[loader_scope_repro] loads:")
for item in loads:
    print(item)
has_sink = any("u_child1.u_sink.in" in item for item in loads)
has_child1_b = any("u_child1.b" in item for item in loads)
has_reg = any("RegCombo" in item or "rb" in item for item in loads)
print(f"[loader_scope_repro] has_child1_b={has_child1_b} has_sink={has_sink} has_reg={has_reg}")
PY

echo "[loader_scope_repro] done"
