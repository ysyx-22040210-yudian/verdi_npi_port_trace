#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[loader_complex_scope] cwd=$PWD"
echo "[loader_complex_scope] verify one module per RTL file"
python3 - <<'PY'
from pathlib import Path
files = sorted(Path(".").glob("loader_complex_scope_*.v"))
bad = []
for path in files:
    count = sum(1 for line in path.read_text().splitlines() if line.strip().startswith("module "))
    if count != 1:
        bad.append((path.name, count))
if bad:
    raise SystemExit(f"one-module-per-file check failed: {bad}")
print("[loader_complex_scope] one-module-per-file check passed")
PY

echo "[loader_complex_scope] clean previous outputs"
rm -rf loader_complex_scope_trace_build
rm -f loader_complex_scope_vcs.log
rm -f loader_complex_scope.csv loader_complex_scope_boundary.csv loader_complex_scope_full_owner.csv
rm -f loader_complex_scope.log
rm -f LCSChild0_full.csv LCSChild0_module_connections.csv LCSChild0_LCSKeyBit_LCSKeyVec_instances.txt

echo "[loader_complex_scope] build KDB"
mkdir -p loader_complex_scope_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top LoaderComplexScopeTop -f loader_complex_scope_trace_test.f \
  -Mdir=loader_complex_scope_trace_build/csrc \
  -o loader_complex_scope_trace_build/simv \
  -l loader_complex_scope_vcs.log
vcs_rc=$?
set -e

if [ ! -d loader_complex_scope_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[loader_complex_scope] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 loader_complex_scope_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[loader_complex_scope] KDB OK, vcs_rc=$vcs_rc"

echo "[loader_complex_scope] run trace_and_filter"
./trace_and_filter.sh \
  -module LCSChild0 \
  -lib "$(pwd)/loader_complex_scope_trace_build/simv.daidir/kdb.elab++" \
  -keywords LCSKeyBit,LCSKeyVec \
  -ports a,data_o \
  -output loader_complex_scope.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 10 \
  -assign-trace-depth 16 \
  -assign-expr-trace-depth 8 \
  -trace-debug 1 \
  -log-file loader_complex_scope.log

echo "[loader_complex_scope] inspect scope-sensitive log lines"
grep -E "trace_port instance=.*u_child0 port=(a|data_o)|collect_load_rec_enter signal=|source_module_port_load_(probe|match|empty)|source_module_port_skip_nonexistent|source_assign_direct_load_fanout|source_assign_load_fanout|load_module_port_high_continue|trace_result instance=.*u_child0 port=(a|data_o)" \
  loader_complex_scope.log | head -n 220 || true

echo "[loader_complex_scope] assert expected keyword loaders are reached"
python3 - <<'PY'
import csv
from pathlib import Path

rows = list(csv.DictReader(Path("LCSChild0_full.csv").open()))
loads = [
    (row["inst_full_name"], row["port_name"], row["signal_full_name"])
    for row in rows
    if row["role"] == "load"
]

for inst, port, signal in loads[:80]:
    print(f"{inst},{port},{signal}")

def has(port, token):
    return any(p == port and token in sig for _, p, sig in loads)

required = [
    ("a", "u_parent1.u_child1.u_key_b.in"),
    ("data_o", "u_parent1.u_child1.u_key_low.in"),
    ("data_o", "u_parent1.u_child1.u_key_high.in"),
    ("data_o", "LCSChild1/Always"),
]
missing = [(port, token) for port, token in required if not has(port, token)]
if missing:
    raise SystemExit(f"missing expected loader tokens {missing}")

filtered = list(csv.DictReader(Path("loader_complex_scope.csv").open()))
if not any(row["port_name"] == "a" and "u_key_b.in" in row["signal_full_name"] for row in filtered):
    raise SystemExit("filtered CSV missing a -> u_key_b.in")
if not any(row["port_name"] == "data_o" and "u_key_low.in" in row["signal_full_name"] for row in filtered):
    raise SystemExit("filtered CSV missing data_o -> u_key_low.in")
if not any(row["port_name"] == "data_o" and "u_key_high.in" in row["signal_full_name"] for row in filtered):
    raise SystemExit("filtered CSV missing data_o -> u_key_high.in")

log_text = Path("loader_complex_scope.log").read_text(errors="replace")
if "source_module_port_load_match signal=net " in log_text:
    print("[loader_complex_scope] natural bare-name failure was observed")
else:
    print("[loader_complex_scope] natural run kept hierarchical signal names")

print("[loader_complex_scope] assertions passed")
PY

echo "[loader_complex_scope] SUCCESS"
