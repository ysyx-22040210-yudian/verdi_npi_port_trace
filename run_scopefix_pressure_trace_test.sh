#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[scopefix_pressure] cwd=$PWD"
echo "[scopefix_pressure] verify one module per RTL file"
python3 - <<'PY'
from pathlib import Path
bad = []
for path in sorted(Path(".").glob("scopefix_pressure_*.v")):
    count = sum(1 for line in path.read_text().splitlines() if line.strip().startswith("module "))
    if count != 1:
        bad.append((path.name, count))
if bad:
    raise SystemExit(f"one-module-per-file check failed: {bad}")
print("[scopefix_pressure] one-module-per-file check passed")
PY

echo "[scopefix_pressure] clean previous outputs for this test only"
rm -rf scopefix_pressure_trace_build
rm -f scopefix_pressure_vcs.log
rm -f scopefix_pressure_probe.csv scopefix_pressure_probe_boundary.csv scopefix_pressure_probe_full_owner.csv
rm -f scopefix_pressure_probe__*.csv scopefix_pressure_trace.log
rm -f SFPProbe_full.csv SFPProbe_module_connections.csv
rm -f SFPProbe_SFPKeySrc_SFPKeySink_instances.txt

echo "[scopefix_pressure] build KDB"
mkdir -p scopefix_pressure_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top ScopeFixPressureTop -f scopefix_pressure_trace_test.f \
  -Mdir=scopefix_pressure_trace_build/csrc \
  -o scopefix_pressure_trace_build/simv \
  -l scopefix_pressure_vcs.log
vcs_rc=$?
set -e

if [ ! -d scopefix_pressure_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[scopefix_pressure] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 100 scopefix_pressure_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[scopefix_pressure] KDB OK, vcs_rc=$vcs_rc"

echo "[scopefix_pressure] run trace_and_filter"
./trace_and_filter.sh \
  -module SFPProbe \
  -lib "$(pwd)/scopefix_pressure_trace_build/simv.daidir/kdb.elab++" \
  -keywords SFPKeySrc,SFPKeySink \
  -ports drv_chain,drv_concat_bit,drv_nested_bit,drv_const_chain,drv_decoy_bit,load_chain,load_bus,load_bus[7],load_bus[18],load_bus[28],load_orphan \
  -output scopefix_pressure_probe.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 12 \
  -assign-trace-depth 24 \
  -assign-expr-trace-depth 12 \
  -trace-debug 1 \
  -log-file scopefix_pressure_trace.log

echo "[scopefix_pressure] inspect important debug lines"
grep -E "trace_port instance=.*u_probe port=|collect_load_rec_enter signal=.*(net|c|load_bus|load_chain)|source_module_port_load_(probe|match|skip)|source_assign_(direct_)?load_fanout|source_assign_(direct_)?driver_source|load_module_port_high_continue|trace_result instance=.*u_probe port=" \
  scopefix_pressure_trace.log | head -n 260 || true

echo "[scopefix_pressure] assert expected results"
python3 - <<'PY'
import csv
from pathlib import Path

full_rows = list(csv.DictReader(Path("SFPProbe_full.csv").open()))
filtered_rows = list(csv.DictReader(Path("scopefix_pressure_probe.csv").open()))
log_text = Path("scopefix_pressure_trace.log").read_text(errors="replace")

def full_has(port, role, token):
    return any(r["port_name"] == port and r["role"] == role and token in r["signal_full_name"] for r in full_rows)

def filtered_has(port, role, token):
    return any(r["port_name"] == port and r["role"] == role and token in r["signal_full_name"] for r in filtered_rows)

def full_signals(port, role):
    return [r["signal_full_name"] for r in full_rows if r["port_name"] == port and r["role"] == role]

required_full = [
    ("drv_chain", "driver", "u_driver.u_key_scalar"),
    ("drv_concat_bit", "driver", "u_driver.u_key_vec1.out"),
    ("drv_nested_bit", "driver", "u_driver.u_key_nested.out"),
    ("drv_const_chain", "driver", "Const:"),
    ("load_chain", "load", "u_sibling.u_consumer.u_key_chain.in"),
    ("load_bus", "load", "u_sibling.u_consumer.u_key_low.in"),
    ("load_bus", "load", "u_sibling.u_consumer.u_key_concat.in"),
    ("load_bus[7]", "load", "u_sibling.u_consumer.u_key_low.in"),
    ("load_bus[28]", "load", "u_sibling.u_consumer.u_key_concat.in"),
    ("load_orphan", "load", "u_sibling.u_consumer.u_key_orphan.in"),
]
missing = [(p, r, t) for p, r, t in required_full if not full_has(p, r, t)]
if missing:
    details = {f"{p}:{r}": full_signals(p, r)[:80] for p, r, _ in missing}
    raise SystemExit(f"missing expected full trace tokens: {missing}\n{details}")

required_filtered = [
    ("drv_chain", "driver", "u_key_scalar"),
    ("drv_concat_bit", "driver", "u_key_vec1.out"),
    ("drv_nested_bit", "driver", "u_key_nested.out"),
    ("load_chain", "load", "u_key_chain.in"),
    ("load_bus", "load", "u_key_low.in"),
    ("load_bus", "load", "u_key_concat.in"),
    ("load_bus[7]", "load", "u_key_low.in"),
    ("load_bus[28]", "load", "u_key_concat.in"),
    ("load_orphan", "load", "u_key_orphan.in"),
]
missing_filtered = [(p, r, t) for p, r, t in required_filtered if not filtered_has(p, r, t)]
if missing_filtered:
    raise SystemExit(f"missing expected filtered rows: {missing_filtered}")

if any(r["port_name"] == "drv_const_chain" and r["role"] == "driver" for r in filtered_rows):
    raise SystemExit("drv_const_chain must not be keyword-filtered; it should remain a const/no-keyword driver")

if any(r["port_name"] == "drv_decoy_bit" and r["role"] == "driver" for r in filtered_rows):
    raise SystemExit("drv_decoy_bit must not be keyword-filtered")

if filtered_has("load_bus[7]", "load", "u_key_concat.in"):
    print("[scopefix_pressure] note: load_bus[7] also reaches whole-bus/concat fanout through NPI load trace")

if filtered_has("load_bus[18]", "load", "u_key_low.in") or filtered_has("load_bus[18]", "load", "u_key_concat.in"):
    raise SystemExit("load_bus[18] is an intentionally unused middle-slice bit and must not reach either key sink")

if filtered_has("load_bus[28]", "load", "u_key_low.in"):
    raise SystemExit("load_bus[28] must reach the concat sink without leaking into the low-slice sink")

if any("u_noise" in r["inst_full_name"] or "u_noise" in r["signal_full_name"] for r in filtered_rows):
    raise SystemExit("noise clusters leaked into keyword-filtered output")

for marker in [
    "source_module_port_load_match",
    "source_assign_direct_load_fanout",
    "source_assign_load_fanout",
    "source_assign_direct_driver_source",
    "source_assign_driver_source",
    "load_module_port_high_continue",
]:
    if marker not in log_text:
        raise SystemExit(f"missing debug marker: {marker}")

instances = {r["inst_full_name"] for r in full_rows if r["port_name"] == "load_chain"}
if len(instances) != 4:
    raise SystemExit(f"expected 4 SFPProbe instances from two clusters x two paths, got {len(instances)}: {sorted(instances)}")

print("[scopefix_pressure] assertions passed")
PY

echo "[scopefix_pressure] SUCCESS"
