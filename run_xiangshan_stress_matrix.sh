#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
XIANGSHAN_KDB="${XIANGSHAN_KDB:-/root/XiangShan-build/build/xverif_xiangshan/kdb/simv.daidir/kdb.elab++}"
PYTHON_BIN="${PYTHON_BIN:-/opt/rh/rh-python38/root/usr/bin/python3}"
OUT_ROOT="${XIANGSHAN_STRESS_OUT:-$SCRIPT_DIR/xiangshan_trace_stress_$(date +%Y%m%d_%H%M%S)}"
VERDI_TIMEOUT_SEC="${VERDI_TIMEOUT_SEC:-900}"

log() {
  echo "[xiangshan_stress] $*"
}

fail() {
  echo "[xiangshan_stress] ERROR: $*" >&2
  exit 1
}

case "$VERDI_TIMEOUT_SEC" in
  ''|*[!0-9]*) fail "VERDI_TIMEOUT_SEC must be a positive integer" ;;
  0) fail "VERDI_TIMEOUT_SEC must be greater than zero" ;;
esac

[ -d "$XIANGSHAN_KDB" ] || fail "XiangShan KDB not found: $XIANGSHAN_KDB"
[ -x "$PYTHON_BIN" ] || fail "Python 3.8+ not found: $PYTHON_BIN"
"$PYTHON_BIN" -c 'import sys; assert sys.version_info >= (3, 8); import openpyxl; print("python={} openpyxl={}".format(sys.version.split()[0], openpyxl.__version__))'
[ ! -e "$OUT_ROOT" ] || fail "output already exists: $OUT_ROOT"
mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd)"

export PYTHON_BIN
export VCS_HOME="${VCS_HOME:-/home/synopsys/vcs/O-2018.09-SP2}"
export VERDI_HOME="${VERDI_HOME:-/home/synopsys/verdi/Verdi_O-2018.09-SP2}"
export VCS_TARGET_ARCH="${VCS_TARGET_ARCH:-linux64}"
export PATH="$VCS_HOME/bin:$VERDI_HOME/bin:$PATH"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-27000@IC_EDA}"
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@IC_EDA}"
export VERDI_LICENSE_FILE="${VERDI_LICENSE_FILE:-27000@IC_EDA}"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

log "script_dir=$SCRIPT_DIR"
log "kdb=$XIANGSHAN_KDB"
log "out_root=$OUT_ROOT"
log "verdi_timeout_sec=$VERDI_TIMEOUT_SEC"
df -h / | tee "$OUT_ROOT/disk_before.txt"
sha256sum "$SCRIPT_DIR/npi_port_trace.tcl" "$SCRIPT_DIR/npi_elaborated.tcl" \
  "$SCRIPT_DIR/trace_support.tcl" "$SCRIPT_DIR/npi_trace.sh" \
  "$SCRIPT_DIR/annotate_trace_xlsx.py" "$SCRIPT_DIR/npi_find_module_params.tcl" \
  "$SCRIPT_DIR/trace_identity.py" "$SCRIPT_DIR/runtime_paths.py" \
  "$SCRIPT_DIR/validate_xiangshan_stress.py" > "$OUT_ROOT/tool_sha256.txt"

run_mshr_constants() {
  local case_dir="$OUT_ROOT/01_mshr_constants"
  mkdir -p "$case_dir"
  log "case=01_mshr_constants start"
  (
    cd "$case_dir"
    # Exercise the real Tcl stop-set transport/index, beyond the historical
    # 4096-item and per-argument/environment-size limits. Nonmatching entries
    # must not change the independently known MSHR constant bit results.
    seq -w 0 49999 | sed 's/^/tb_top.nonmatching_stress_stop_/; s/$/.u_leaf/' > stops.list
    /usr/bin/time -v -o time.txt "$SCRIPT_DIR/npi_trace.sh" \
      -module MSHR \
      -lib "$XIANGSHAN_KDB" \
      -ports 'io_id[0],io_id[1],io_id[2],io_id[3],io_id[4],io_id[5],io_id[6],io_id[7]' \
      -module-out boundary.csv \
      -const-source-fallback 1 \
      -const-trace-depth 8 \
      -assign-trace-depth 0 \
      -assign-expr-trace-depth 0 \
      -load-trace-node-limit 1000 \
      -load-trace-edge-limit 5000 \
      -load-trace-api-list-limit 1000 \
      -load-stop-instance-file stops.list \
      -verdi-timeout-sec "$VERDI_TIMEOUT_SEC" \
      -trace-debug 1 \
      -log-file trace.log \
      > full.csv
    "$PYTHON_BIN" "$SCRIPT_DIR/validate_xiangshan_stress.py" mshr-constants \
      --full full.csv --boundary boundary.csv --log trace.log --bits 0 1 2 3 4 5 6 7 | tee validation.log
    printf 'mshr_constants\n' > PASS
  )
  log "case=01_mshr_constants PASS"
}

run_uncache_xlsx() {
  local case_dir="$OUT_ROOT/02_uncache_xlsx"
  mkdir -p "$case_dir/work"
  log "case=02_uncache_xlsx start"
  (
    cd "$case_dir"
    /usr/bin/time -v -o time.txt "$SCRIPT_DIR/annotate_trace_xlsx.sh" \
      -template "$case_dir/template.xlsx" \
      -output "$case_dir/result.xlsx" \
      -workdir "$case_dir/work" \
      -lib "$XIANGSHAN_KDB" \
      -module Uncache \
      -keywords ClockGate \
      -ports io_enableOutstanding \
      --stream \
      --keyword-batch-size 1 \
      --match-cache-size 50000 \
      -const-source-fallback 0 \
      -const-trace-depth 0 \
      -assign-trace-depth 12 \
      -assign-expr-trace-depth 0 \
      -load-trace-node-limit 100 \
      -load-trace-edge-limit 500 \
      -load-trace-api-list-limit 100 \
      -verdi-timeout-sec "$VERDI_TIMEOUT_SEC" \
      -trace-debug 0 \
      -log-file "$case_dir/annotate.log" \
      > stdout.log 2> stderr.log
    "$PYTHON_BIN" "$SCRIPT_DIR/validate_xiangshan_stress.py" uncache-xlsx \
      --book result.xlsx \
      --full work/Uncache_full.csv \
      --boundary work/Uncache_module_connections.csv \
      --instances work/ClockGate_instances.txt | tee validation.log
    printf 'uncache_xlsx\n' > PASS
  )
  log "case=02_uncache_xlsx PASS"
}

run_subsystem_mode() {
  local mode="$1"
  local case_dir="$OUT_ROOT/03_subsystem_${mode}"
  local stream_arg=""
  if [ "$mode" = "stream" ]; then
    stream_arg="--stream"
  fi
  mkdir -p "$case_dir/work"
  log "case=03_subsystem_${mode} start"
  (
    cd "$case_dir"
    /usr/bin/time -v -o time.txt "$SCRIPT_DIR/annotate_trace_xlsx.sh" \
      -template "$case_dir/template.xlsx" \
      -output "$case_dir/result.xlsx" \
      -workdir "$case_dir/work" \
      -lib "$XIANGSHAN_KDB" \
      -module MSHR,LevelGateway \
      -keywords ClockGate \
      -ports 'io_id[0],io_id[7],io_interrupt,io_plic_valid' \
      -subsystem-level 6 \
      ${stream_arg:+$stream_arg} \
      --no-params \
      --keyword-batch-size 1 \
      --match-cache-size 50000 \
      -const-source-fallback 1 \
      -const-trace-depth 8 \
      -assign-trace-depth 0 \
      -assign-expr-trace-depth 0 \
      -load-trace-node-limit 1000 \
      -load-trace-edge-limit 5000 \
      -load-trace-api-list-limit 1000 \
      -verdi-timeout-sec "$VERDI_TIMEOUT_SEC" \
      -trace-debug 0 \
      -log-file "$case_dir/annotate.log" \
      > stdout.log 2> stderr.log
  )
  log "case=03_subsystem_${mode} trace_done"
}

validate_subsystems() {
  "$PYTHON_BIN" "$SCRIPT_DIR/validate_xiangshan_stress.py" subsystem-compare \
    --stream-root "$OUT_ROOT/03_subsystem_stream" \
    --nonstream-root "$OUT_ROOT/03_subsystem_nonstream" \
    | tee "$OUT_ROOT/03_subsystem_compare.log"
  printf 'subsystem_stream\n' > "$OUT_ROOT/03_subsystem_stream/PASS"
  printf 'subsystem_nonstream\n' > "$OUT_ROOT/03_subsystem_nonstream/PASS"
  log "case=03_subsystem_compare PASS"
}

run_timeout_cleanup() {
  local case_dir="$OUT_ROOT/04_timeout_cleanup"
  mkdir -p "$case_dir"
  log "case=04_timeout_cleanup start"
  set +e
  (
    cd "$case_dir"
    /usr/bin/time -v -o time.txt "$SCRIPT_DIR/npi_trace.sh" \
      -module Uncache \
      -lib "$XIANGSHAN_KDB" \
      -ports io_enableOutstanding \
      -module-out boundary.csv \
      -const-source-fallback 0 \
      -const-trace-depth 0 \
      -assign-trace-depth 0 \
      -assign-expr-trace-depth 0 \
      -load-trace-node-limit 100 \
      -load-trace-edge-limit 500 \
      -load-trace-api-list-limit 100 \
      -verdi-timeout-sec 1 \
      -trace-debug 0 \
      -log-file trace.log \
      > full.csv
  )
  local rc=$?
  set -e
  printf '%s\n' "$rc" > "$case_dir/rc.txt"
  "$PYTHON_BIN" "$SCRIPT_DIR/validate_xiangshan_stress.py" timeout-cleanup \
    --root "$case_dir" | tee "$case_dir/validation.log"
  printf 'timeout_cleanup\n' > "$case_dir/PASS"
  log "case=04_timeout_cleanup PASS"
}

run_mshr_constants
run_uncache_xlsx
run_subsystem_mode stream
run_subsystem_mode nonstream
validate_subsystems
run_timeout_cleanup

sleep 2
if ps -eo comm= | grep -E '^(verdi|Novas|Xvfb|npi_port_trace)$' > "$OUT_ROOT/eda_processes_after.txt"; then
  if [ "${VM_STRESS_ALLOW_CONCURRENT_EDA:-0}" = 1 ]; then
    log "global EDA inventory retained; concurrent mode does not assert VM-wide process absence"
  else
    cat "$OUT_ROOT/eda_processes_after.txt" >&2
    fail "EDA processes remained after the stress matrix"
  fi
fi

"$PYTHON_BIN" "$SCRIPT_DIR/validate_xiangshan_stress.py" summary \
  --root "$OUT_ROOT" --expected-passes 5 | tee "$OUT_ROOT/summary.log"
df -h / | tee "$OUT_ROOT/disk_after.txt"
log "SUCCESS out_root=$OUT_ROOT"
