#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[source_scope_collision] cwd=$PWD"
echo "[source_scope_collision] build KDB"
mkdir -p source_scope_collision_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top SourceScopeCollisionTop -f source_scope_collision_trace_test.f \
  -Mdir=source_scope_collision_trace_build/csrc \
  -o source_scope_collision_trace_build/simv \
  -l source_scope_collision_vcs.log
vcs_rc=$?
set -e
if [ ! -d source_scope_collision_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[source_scope_collision] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 source_scope_collision_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[source_scope_collision] KDB OK, vcs_rc=$vcs_rc"

echo "[source_scope_collision] run trace_and_filter"
./trace_and_filter.sh \
  -module CollisionProbe \
  -lib "$(pwd)/source_scope_collision_trace_build/simv.daidir/kdb.elab++" \
  -keywords CollisionKeyword \
  -ports drv_collision,drv_real \
  -output source_scope_collision_filtered.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 4 \
  -assign-trace-depth 4 \
  -assign-expr-trace-depth 2 \
  2>&1 | tee source_scope_collision_trace.log

echo "[source_scope_collision] assert filtered CSV"
python3 - <<'PY'
import csv
from pathlib import Path

rows = list(csv.DictReader(Path("source_scope_collision_filtered.csv").open()))
by_port = {}
for row in rows:
    by_port.setdefault((row["port_name"], row["role"]), []).append(row["signal_full_name"])

collision_hits = by_port.get(("drv_collision", "driver"), [])
if collision_hits:
    raise SystemExit(f"drv_collision falsely matched keyword: {collision_hits}")

real_hits = by_port.get(("drv_real", "driver"), [])
if not any("SourceScopeCollisionTop.u_key_decoy.out" in sig for sig in real_hits):
    raise SystemExit(f"drv_real missing real keyword hit: {real_hits}")

full_text = Path("CollisionProbe_full.csv").read_text()
for token in [
    "SourceScopeCollisionTop.c_nonkey",
    "SourceScopeCollisionTop.u_nonkey.out",
]:
    if token not in full_text:
        raise SystemExit(f"full trace missing expected non-key path token={token}")

if "SourceScopeCollisionTop.u_key_decoy.out" in "\n".join(
    line for line in full_text.splitlines() if ",drv_collision," in line
):
    raise SystemExit("drv_collision full trace was polluted by decoy keyword")

print("[source_scope_collision] assertions passed")
PY

echo "[source_scope_collision] SUCCESS"
