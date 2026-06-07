#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "[scope_fallback_stress] cwd=$PWD"
echo "[scope_fallback_stress] build KDB"
mkdir -p scope_fallback_stress_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top ScopeFallbackStressTop -f scope_fallback_stress_trace_test.f \
  -Mdir=scope_fallback_stress_trace_build/csrc \
  -o scope_fallback_stress_trace_build/simv \
  -l scope_fallback_stress_vcs.log
vcs_rc=$?
set -e
if [ ! -d scope_fallback_stress_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[scope_fallback_stress] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  exit "$vcs_rc"
fi
echo "[scope_fallback_stress] KDB OK, vcs_rc=$vcs_rc"

echo "[scope_fallback_stress] run trace_and_filter"
./trace_and_filter.sh \
  -module ScopeStressChild \
  -lib "$(pwd)/scope_fallback_stress_trace_build/simv.daidir/kdb.elab++" \
  -keywords ScopeKeySrc,ScopeKeyVecSrc,ScopeKeySink,ScopeKeyVecSink \
  -ports drv_parent,drv_sibling,drv_wrapper,drv_slice_bit,drv_concat_bit,drv_gen,load_plain,load_bus \
  -output scope_fallback_stress_filtered.csv \
  --keyword-batch-size 2 \
  -const-source-fallback 1 \
  -const-trace-depth 4 \
  -assign-trace-depth 5 \
  -assign-expr-trace-depth 2 \
  2>&1 | tee scope_fallback_stress_trace.log

echo "[scope_fallback_stress] assert filtered CSV"
python3 - <<'PY'
import csv
from pathlib import Path

rows = list(csv.DictReader(Path("scope_fallback_stress_filtered.csv").open()))
signals_by_port = {}
for row in rows:
    signals_by_port.setdefault((row["port_name"], row["role"]), []).append(row["signal_full_name"])

def require(port, role, token):
    hits = signals_by_port.get((port, role), [])
    if not any(token in sig for sig in hits):
        raise SystemExit(f"missing {port}/{role} token={token}; hits={hits}; rows={rows}")

require("drv_parent", "driver", "ScopeFallbackStressTop.u_parent.u_key_nested.out")
require("drv_sibling", "driver", "ScopeFallbackStressTop.u_sibling_prod.u_key_sibling.out")
require("drv_wrapper", "driver", "ScopeFallbackStressTop.u_key_wrap_src.out")
require("drv_slice_bit", "driver", "ScopeFallbackStressTop.u_vec_parent.u_vec_key.out")
require("drv_concat_bit", "driver", "ScopeFallbackStressTop.u_key_hi.out")
require("drv_gen", "driver", "ScopeFallbackStressTop.u_gen_parent.g[2].u_key_gen.out")
require("load_plain", "load", "ScopeFallbackStressTop.u_load_sink.in")
require("load_bus", "load", "ScopeFallbackStressTop.u_load_lo.in")
require("load_bus", "load", "ScopeFallbackStressTop.u_load_hi.in")

bad_tokens = [
    "u_key_nested.u_key_nested",
    "u_key_sibling.u_key_sibling",
    "u_vec_key.u_vec_key",
    "u_key_hi.u_key_hi",
    "u_key_nested.in",
    "u_key_sibling.in",
    "u_key_wrap_src.in",
    "u_vec_key.in",
    "u_key_hi.in",
    "u_key_gen.in",
    "u_load_sink.out",
    "u_load_lo.out",
    "u_load_hi.out",
]
text = "\n".join(",".join(row.values()) for row in rows)
for token in bad_tokens:
    if token in text:
        raise SystemExit(f"found fabricated nested path token={token}; rows={rows}")

full_text = Path("ScopeStressChild_full.csv").read_text()
for token in [
    "ScopeFallbackStressTop.c_parent",
    "ScopeFallbackStressTop.u_parent.out",
    "ScopeFallbackStressTop.u_parent.u_key_nested.out",
    "ScopeFallbackStressTop.c_sibling",
    "ScopeFallbackStressTop.u_sibling_prod.out",
    "ScopeFallbackStressTop.u_sibling_prod.u_key_sibling.out",
    "ScopeFallbackStressTop.load_mid",
    "ScopeFallbackStressTop.u_load_sink.in",
]:
    if token not in full_text:
        raise SystemExit(f"full trace missing token={token}")

print("[scope_fallback_stress] assertions passed")
PY
