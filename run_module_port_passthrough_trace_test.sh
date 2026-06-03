#!/usr/bin/env bash
set -euo pipefail

echo "[module_port_passthrough] cwd=$PWD"
echo "[module_port_passthrough] build KDB"
mkdir -p module_port_passthrough_trace_build

set +e
vcs -full64 -sverilog -lca -kdb -top ModulePortPassthroughTop -f module_port_passthrough_trace_test.f \
  -Mdir=module_port_passthrough_trace_build/csrc \
  -o module_port_passthrough_trace_build/simv \
  -l module_port_passthrough_vcs.log
vcs_rc=$?
set -e

if [ ! -d module_port_passthrough_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[module_port_passthrough] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  exit 1
fi
echo "[module_port_passthrough] KDB OK, vcs_rc=$vcs_rc"

echo "[module_port_passthrough] run driver trace_and_filter"
./trace_and_filter.sh \
  -module MPDriverChild \
  -lib "$(pwd)/module_port_passthrough_trace_build/simv.daidir/kdb.elab++" \
  -keywords MPKeySrc,MPKeySink \
  -ports a \
  -output module_port_passthrough_driver_filtered.csv \
  --keyword-batch-size 1 \
  -assign-trace-depth 6 \
  -assign-expr-trace-depth 1 \
  2>&1 | tee module_port_passthrough_trace.log

echo "[module_port_passthrough] run loader trace_and_filter"
./trace_and_filter.sh \
  -module MPLoadChild \
  -lib "$(pwd)/module_port_passthrough_trace_build/simv.daidir/kdb.elab++" \
  -keywords MPKeySrc,MPKeySink \
  -ports y \
  -output module_port_passthrough_load_filtered.csv \
  --keyword-batch-size 1 \
  -assign-trace-depth 6 \
  -assign-expr-trace-depth 1 \
  2>&1 | tee -a module_port_passthrough_trace.log

echo "[module_port_passthrough] assert filtered CSV"
python3 - <<'PY'
import csv
from pathlib import Path

rows = []
for filename in [
    "module_port_passthrough_driver_filtered.csv",
    "module_port_passthrough_load_filtered.csv",
]:
    rows.extend(csv.DictReader(Path(filename).open()))
expected = [
    {
        "inst_full_name": "ModulePortPassthroughTop.u_driver_child",
        "port_name": "a",
        "port_dir": "input",
        "role": "driver",
        "signal_full_name": "ModulePortPassthroughTop.u_key_src.out",
    },
    {
        "inst_full_name": "ModulePortPassthroughTop.u_load_child",
        "port_name": "y",
        "port_dir": "output",
        "role": "load",
        "signal_full_name": "ModulePortPassthroughTop.u_key_sink.in",
    },
]
missing = [row for row in expected if row not in rows]
if missing:
    print("rows:")
    for row in rows:
        print(row)
    raise SystemExit(f"missing expected rows: {missing}")
print("[module_port_passthrough] assertions passed")
print("MODULE_PORT_PASSTHROUGH_OK")
PY
