#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[loader_deep_port_scope] cwd=$PWD"
echo "[loader_deep_port_scope] clean previous outputs"
rm -rf loader_deep_port_scope_trace_build
rm -f loader_deep_port_scope_vcs.log
rm -f loader_deep_port_scope.csv loader_deep_port_scope_boundary.csv loader_deep_port_scope_full_owner.csv
rm -f loader_deep_port_scope.log
rm -f LDPSChild0_full.csv LDPSChild0_module_connections.csv LDPSChild0_LDPSKeyword_instances.txt

echo "[loader_deep_port_scope] build KDB"
mkdir -p loader_deep_port_scope_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top LoaderDeepPortScopeTop -f loader_deep_port_scope_trace_test.f \
  -Mdir=loader_deep_port_scope_trace_build/csrc \
  -o loader_deep_port_scope_trace_build/simv \
  -l loader_deep_port_scope_vcs.log
vcs_rc=$?
set -e

if [ ! -d loader_deep_port_scope_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[loader_deep_port_scope] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 loader_deep_port_scope_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[loader_deep_port_scope] KDB OK, vcs_rc=$vcs_rc"

echo "[loader_deep_port_scope] run trace_and_filter"
./trace_and_filter.sh \
  -module LDPSChild0 \
  -lib "$(pwd)/loader_deep_port_scope_trace_build/simv.daidir/kdb.elab++" \
  -keywords LDPSKeyword \
  -ports a \
  -output loader_deep_port_scope.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 12 \
  -assign-expr-trace-depth 4 \
  -trace-debug 1 \
  -log-file loader_deep_port_scope.log

echo "[loader_deep_port_scope] inspect scope-sensitive log lines"
grep -E "trace_port instance=.*u_child0 port=a|collect_load_rec_enter signal=|source_module_port_load_(probe|match|empty)|source_module_port_skip_nonexistent|source_assign_direct_load_fanout|load_module_port_high_continue|trace_result instance=.*u_child0 port=a" \
  loader_deep_port_scope.log | head -n 160 || true

echo "[loader_deep_port_scope] assert expected keyword loader is reached"
python3 - <<'PY'
import csv
from pathlib import Path

full_rows = list(csv.DictReader(Path("LDPSChild0_full.csv").open()))
loads = [
    row["signal_full_name"]
    for row in full_rows
    if row["port_name"] == "a" and row["role"] == "load"
]

for item in loads:
    print(item)

required = [
    "u_parent1.net",
    "u_child1.b",
    "u_key.in",
]
missing = [token for token in required if not any(token in load for load in loads)]
if missing:
    raise SystemExit(f"missing expected loader tokens {missing}; loads={loads}")

bare_fail = any(load == "net" or load == "prod_shadow" for load in loads)
if bare_fail:
    raise SystemExit(f"loader stopped at a bare local name: {loads}")

print("[loader_deep_port_scope] assertions passed")
PY

echo "[loader_deep_port_scope] SUCCESS"
