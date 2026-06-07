#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[sibling_mf_output_loader] cwd=$PWD"
echo "[sibling_mf_output_loader] clean previous outputs"
rm -rf sibling_mf_output_loader_trace_build
rm -f sibling_mf_output_loader_vcs.log
rm -f sibling_mf_output_loader.csv sibling_mf_output_loader_boundary.csv sibling_mf_output_loader_full_owner.csv
rm -f sibling_mf_output_loader__*.csv sibling_mf_output_loader.log
rm -f SiblingMfChild_full.csv SiblingMfChild_module_connections.csv
rm -f SiblingMfChild_SiblingMfKeyword_instances.txt

echo "[sibling_mf_output_loader] build KDB"
mkdir -p sibling_mf_output_loader_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top SiblingMfTop -f sibling_mf_output_loader_trace_test.f \
  -Mdir=sibling_mf_output_loader_trace_build/csrc \
  -o sibling_mf_output_loader_trace_build/simv \
  -l sibling_mf_output_loader_vcs.log
vcs_rc=$?
set -e
if [ ! -d sibling_mf_output_loader_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[sibling_mf_output_loader] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 sibling_mf_output_loader_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[sibling_mf_output_loader] KDB OK, vcs_rc=$vcs_rc"

echo "[sibling_mf_output_loader] trace SiblingMfChild.a output loaders through multi-file sibling inputs"
./trace_and_filter.sh \
  -module SiblingMfChild \
  -lib "$(pwd)/sibling_mf_output_loader_trace_build/simv.daidir/kdb.elab++" \
  -keywords SiblingMfKeyword \
  -ports a \
  -output sibling_mf_output_loader.csv \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 12 \
  -assign-expr-trace-depth 8 \
  2>&1 | tee sibling_mf_output_loader.log

echo "[sibling_mf_output_loader] assert results"
python3 - <<'PY'
import csv
from pathlib import Path

expected_instances = [
    "SiblingMfTop.u_p0.u_child",
    "SiblingMfTop.u_p0_alias.u_child",
    "SiblingMfTop.u_prod.u_p0.u_child",
    "SiblingMfTop.u_prod_expr.u_p0.u_child",
    "SiblingMfTop.u_p0_gen.u_child",
]

full_rows = list(csv.DictReader(Path("SiblingMfChild_full.csv").open()))
loads_by_inst = {inst: [] for inst in expected_instances}
for row in full_rows:
    if row["port_name"] == "a" and row["role"] == "load" and row["inst_full_name"] in loads_by_inst:
        loads_by_inst[row["inst_full_name"]].append(row["signal_full_name"])

for inst, rows in loads_by_inst.items():
    if not rows:
        raise SystemExit(f"missing full trace rows for {inst}")
    for token in ["B", "C", "B_l1", "C_l1", "u_key_b.in", "u_key_c.in", "SiblingMfParent1/Always0"]:
        if not any(token in sig for sig in rows):
            raise SystemExit(f"{inst}: missing full trace token {token}")

filtered_rows = list(csv.DictReader(Path("sibling_mf_output_loader.csv").open()))
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

print("[sibling_mf_output_loader] assertions passed")
PY

echo "[sibling_mf_output_loader] SUCCESS"
