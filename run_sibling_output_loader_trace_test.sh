#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[sibling_output_loader] cwd=$PWD"
echo "[sibling_output_loader] clean previous outputs"
rm -rf sibling_output_loader_trace_build
rm -f sibling_output_loader_vcs.log
rm -f sibling_output_loader.csv sibling_output_loader_boundary.csv sibling_output_loader_full_owner.csv
rm -f sibling_output_loader__*.csv sibling_output_loader.log
rm -f SiblingChild_full.csv SiblingChild_module_connections.csv
rm -f SiblingChild_SiblingKeyword_instances.txt

echo "[sibling_output_loader] build KDB"
mkdir -p sibling_output_loader_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top SiblingLoaderTop -f sibling_output_loader_trace_test.f \
  -Mdir=sibling_output_loader_trace_build/csrc \
  -o sibling_output_loader_trace_build/simv \
  -l sibling_output_loader_vcs.log
vcs_rc=$?
set -e
if [ ! -d sibling_output_loader_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[sibling_output_loader] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 sibling_output_loader_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[sibling_output_loader] KDB OK, vcs_rc=$vcs_rc"

echo "[sibling_output_loader] trace Child.a output loaders through sibling parent input slices"
./trace_and_filter.sh \
  -module SiblingChild \
  -lib "$(pwd)/sibling_output_loader_trace_build/simv.daidir/kdb.elab++" \
  -keywords SiblingKeyword \
  -ports a \
  -output sibling_output_loader.csv \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 10 \
  -assign-expr-trace-depth 8 \
  2>&1 | tee sibling_output_loader.log

echo "[sibling_output_loader] assert results"
python3 - <<'PY'
import csv
from pathlib import Path

full_rows = list(csv.DictReader(Path("SiblingChild_full.csv").open()))
expected_instances = [
    "SiblingLoaderTop.u_p0.u_child",
    "SiblingLoaderTop.u_p0_alias.u_child",
    "SiblingLoaderTop.u_prod.u_p0.u_child",
    "SiblingLoaderTop.u_prod_expr.u_p0.u_child",
]

loads_by_inst = {inst: [] for inst in expected_instances}
for row in full_rows:
    if row["port_name"] == "a" and row["role"] == "load" and row["inst_full_name"] in loads_by_inst:
        loads_by_inst[row["inst_full_name"]].append(row["signal_full_name"])

for inst, load_rows in loads_by_inst.items():
    if not load_rows:
        raise SystemExit(f"missing load rows for {inst}")
    for token in [
        "B",
        "C",
        "B_l1",
        "C_l1",
        "u_key_b.in",
        "u_key_c.in",
        "SiblingParent1/Always0",
    ]:
        if not any(token in sig for sig in load_rows):
            raise SystemExit(f"{inst}: missing loader trace token {token}")

filtered_rows = list(csv.DictReader(Path("sibling_output_loader.csv").open()))
filtered_by_inst = {inst: [] for inst in expected_instances}
for row in filtered_rows:
    if row["inst_full_name"] in filtered_by_inst:
        filtered_by_inst[row["inst_full_name"]].append(row["signal_full_name"])

for inst, rows in filtered_by_inst.items():
    if not rows:
        raise SystemExit(f"filtered CSV did not include {inst}")
    if not any("u_key_b" in sig for sig in rows):
        raise SystemExit(f"filtered CSV did not include {inst} -> u_key_b")
    if not any("u_key_c" in sig for sig in rows):
        raise SystemExit(f"filtered CSV did not include {inst} -> u_key_c")

print("[sibling_output_loader] assertions passed")
PY

echo "[sibling_output_loader] SUCCESS"
