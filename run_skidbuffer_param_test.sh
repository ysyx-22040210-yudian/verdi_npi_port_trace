#!/bin/bash
# Build and run the parameter-annotation smoke test from this directory.
# All generated files stay in the current working directory.

set -euo pipefail

log_step() {
    echo "[run_skidbuffer_param_test] $*" >&2
}

RUN_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RTL_DIR="$REPO_ROOT/skidbuffer_param_kdb_test"
if [ ! -d "$RTL_DIR" ]; then
    RTL_DIR="/mnt/hgfs/VMshare-2/CPU_CORE/ysyx/skidbuffer_param_kdb_test"
fi

BUILD_DIR="$RUN_DIR/skidbuffer_param_build"
FILELIST="$RUN_DIR/skidbuffer_param_rtl.f"
VCS_LOG="$RUN_DIR/skidbuffer_param_vcs_build.log"
ANNOTATE_LOG="$RUN_DIR/skidbuffer_annotate_params.log"
TEMPLATE="$RUN_DIR/skidbuffer_trace_template.xlsx"
OUTPUT="$RUN_DIR/skidbuffer_annotated.xlsx"
KDB="$BUILD_DIR/simv.daidir/kdb.elab++"

log_step "run_dir=$RUN_DIR"
log_step "script_dir=$SCRIPT_DIR"
log_step "rtl_dir=$RTL_DIR"

if [ "$RUN_DIR" != "$SCRIPT_DIR" ]; then
    echo "[ERROR] run this script from $SCRIPT_DIR so all outputs stay in the tool directory." >&2
    exit 1
fi

if ! command -v vcs >/dev/null 2>&1; then
    echo "[ERROR] vcs is not in PATH" >&2
    exit 1
fi

if ! command -v verdi >/dev/null 2>&1; then
    echo "[ERROR] verdi is not in PATH" >&2
    exit 1
fi

if [ ! -f "$RTL_DIR/skidbuffer.v" ] || [ ! -f "$RTL_DIR/top_skidbuffer_subsystems.v" ]; then
    echo "[ERROR] missing test RTL under $RTL_DIR" >&2
    exit 1
fi

log_step "clean previous skidbuffer test outputs"
rm -rf "$BUILD_DIR"
rm -f "$FILELIST" "$VCS_LOG" "$ANNOTATE_LOG"
rm -f "$TEMPLATE" "$OUTPUT" "$RUN_DIR"/skidbuffer_annotated__subsys_*.xlsx
rm -f "$RUN_DIR"/module_parameters.csv
rm -f "$RUN_DIR"/skidbuffer_full.csv "$RUN_DIR"/skidbuffer_module_connections.csv
rm -f "$RUN_DIR"/SkidPeer_instances.txt

log_step "write filelist=$FILELIST"
cat > "$FILELIST" <<EOF
$RTL_DIR/skidbuffer.v
$RTL_DIR/top_skidbuffer_subsystems.v
EOF

log_step "build KDB with VCS"
mkdir -p "$BUILD_DIR"
set +e
vcs -full64 -sverilog -lca -kdb -top top -f "$FILELIST" \
    -Mdir="$BUILD_DIR/csrc" \
    -o "$BUILD_DIR/simv" \
    -l "$VCS_LOG"
VCS_RC=$?
set -e

if [ ! -d "$KDB" ]; then
    echo "[ERROR] KDB was not generated: $KDB" >&2
    tail -n 80 "$VCS_LOG" >&2 || true
    exit 1
fi

if ! find "$KDB" -mindepth 1 -print -quit | grep -q .; then
    echo "[ERROR] generated KDB is empty: $KDB" >&2
    tail -n 80 "$VCS_LOG" >&2 || true
    exit 1
fi

if [ "$VCS_RC" -ne 0 ]; then
    log_step "VCS exited with status $VCS_RC after KDB generation; continuing because KDB is present and non-empty"
fi

log_step "KDB ready: $KDB"
find "$KDB" -mindepth 1 -maxdepth 2 -print | sed -n '1,20p' >&2 || true

log_step "run XLSX annotation"
"$SCRIPT_DIR/annotate_trace_xlsx.sh" \
    -template "$TEMPLATE" \
    -output "$OUTPUT" \
    -lib "$KDB" \
    -keywords SkidPeer \
    -module skidbuffer \
    -ports i_clk,i_reset,i_valid,o_ready,i_data,o_valid,i_ready,o_data \
    -subsystem-level 2 \
    2>&1 | tee "$ANNOTATE_LOG"

for file in \
    "$RUN_DIR/skidbuffer_annotated__subsys_top.subsys0.xlsx" \
    "$RUN_DIR/skidbuffer_annotated__subsys_top.subsys1.xlsx" \
    "$RUN_DIR/module_parameters.csv" \
    "$RUN_DIR/skidbuffer_full.csv" \
    "$RUN_DIR/skidbuffer_module_connections.csv" \
    "$RUN_DIR/SkidPeer_instances.txt"
do
    if [ ! -s "$file" ]; then
        echo "[ERROR] expected output is missing or empty: $file" >&2
        exit 1
    fi
    log_step "output_ok=$file"
done

log_step "validate parameter cells"
python3 - <<'PY'
import openpyxl
from pathlib import Path

checks = [
    Path("skidbuffer_annotated__subsys_top.subsys0.xlsx"),
    Path("skidbuffer_annotated__subsys_top.subsys1.xlsx"),
]

for path in checks:
    wb = openpyxl.load_workbook(path)
    ws = wb.active
    module_value = ws["A2"].value or ""
    instance_value = ws["B2"].value or ""
    param_value = ws["C2"].value or ""
    print(f"[run_skidbuffer_param_test] {path.name} A2={module_value} B2={instance_value} C2={param_value}")
    if module_value != "skidbuffer":
        raise SystemExit(f"module column missing expected value in {path}")
    if not str(instance_value).startswith("top.subsys"):
        raise SystemExit(f"instance column missing expected value in {path}")
    if "DW=" not in param_value or "OPT_OUTREG=" not in param_value:
        raise SystemExit(f"parameter summary missing expected values in {path}")

param_csv = Path("module_parameters.csv").read_text(encoding="utf-8", errors="replace")
for token in ["skidbuffer", "OPT_LOWPOWER", "OPT_OUTREG", "DW"]:
    if token not in param_csv:
        raise SystemExit(f"module_parameters.csv missing {token}")
PY

log_step "SUCCESS"
