#!/bin/bash
# trace_and_filter.sh - Run kdebug trace and filter rows by driver/load owner module
#
# Usage:
#   ./trace_and_filter.sh -module <target_module> -lib <kdb.elab++> \
#                         -keywords <filter_module[,filter_module...]> \
#                         [-output <output.csv>] [-ports <port1,port2,...>] \
#                         [--keyword-batch-size <n>] \
#                         [-const-source-fallback 0|1] [-const-trace-depth <N>] \
#                         [-assign-trace-depth <N>] [-assign-expr-trace-depth <N>]
#                         [-load-trace-node-limit <N>] [-load-trace-edge-limit <N>]
#                         [-load-trace-api-list-limit <N>]
#                         [-verdi-timeout-sec <N>]
#                         [-trace-debug 0|1] [-log-file <run.log>]
#
# Example:
#   ./trace_and_filter.sh -module ysyx_22050058_id \
#                         -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
#                         -keywords ysyx_22050058_regfile \
#                         -output id_filtered.csv

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log_step() {
    echo "[trace_and_filter] $*" >&2
}

bound_runtime_path() {
    "$PYTHON_BIN" "$SCRIPT_DIR/runtime_paths.py" \
        --path="$1" --suffix="$2" --identity="$3"
}

setup_log_file() {
    if [ -z "$LOG_FILE" ]; then
        return
    fi
    case "$LOG_FILE" in
        /*) ;;
        *) LOG_FILE="$PWD/$LOG_FILE" ;;
    esac
    mkdir -p "$(dirname "$LOG_FILE")"
    : > "$LOG_FILE"
    exec 2> >(tee -a "$LOG_FILE" >&2)
    log_step "log_file=$LOG_FILE"
}

MODULE=""
LIB=""
KEYWORDS=""
OUTPUT=""
PORTS=""
FILELIST=""
INCDIR=""
TOP=""
KEYWORD_BATCH_SIZE="${KEYWORD_BATCH_SIZE:-8}"
KEYWORD_CONTINUE_ON_ERROR=0
KEYWORD_LOG_INSTANCES=0
CONST_SOURCE_FALLBACK="${NPI_CONST_SOURCE_FALLBACK:-1}"
CONST_TRACE_DEPTH="${NPI_CONST_TRACE_MAX_DEPTH:-16}"
ASSIGN_TRACE_DEPTH="${NPI_ASSIGN_TRACE_MAX_DEPTH:-2}"
ASSIGN_EXPR_TRACE_DEPTH="${NPI_ASSIGN_EXPR_TRACE_MAX_DEPTH:-1}"
LOAD_TRACE_NODE_LIMIT="${NPI_LOAD_TRACE_NODE_LIMIT:-20000}"
LOAD_TRACE_EDGE_LIMIT="${NPI_LOAD_TRACE_EDGE_LIMIT:-100000}"
LOAD_TRACE_API_LIST_LIMIT="${NPI_LOAD_TRACE_API_LIST_LIMIT:-20000}"
VERDI_TIMEOUT_SEC="${NPI_VERDI_TIMEOUT_SEC:-0}"
TRACE_DEBUG="${NPI_TRACE_DEBUG:-0}"
LOG_FILE=""
PYTHON_BIN="${PYTHON_BIN:-python3}"
KDEBUG_BIN="${KDEBUG_BIN:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        -module)   MODULE="$2";   shift 2 ;;
        -lib)      LIB="$2";      shift 2 ;;
        -keywords) KEYWORDS="$2"; shift 2 ;;
        -output)   OUTPUT="$2";   shift 2 ;;
        -ports)    PORTS="$2";    shift 2 ;;
        -filelist) FILELIST="$2"; shift 2 ;;
        -incdir)   INCDIR="$2";   shift 2 ;;
        -top)      TOP="$2";      shift 2 ;;
        --keyword-batch-size|-keyword-batch-size) KEYWORD_BATCH_SIZE="$2"; shift 2 ;;
        --keyword-continue-on-error|-keyword-continue-on-error) KEYWORD_CONTINUE_ON_ERROR=1; shift ;;
        --keyword-log-instances|-keyword-log-instances) KEYWORD_LOG_INSTANCES=1; shift ;;
        -const-source-fallback|--const-source-fallback) CONST_SOURCE_FALLBACK="$2"; shift 2 ;;
        -const-trace-depth|--const-trace-depth) CONST_TRACE_DEPTH="$2"; shift 2 ;;
        -assign-trace-depth|--assign-trace-depth) ASSIGN_TRACE_DEPTH="$2"; shift 2 ;;
        -assign-expr-trace-depth|--assign-expr-trace-depth) ASSIGN_EXPR_TRACE_DEPTH="$2"; shift 2 ;;
        -load-trace-node-limit|--load-trace-node-limit) LOAD_TRACE_NODE_LIMIT="$2"; shift 2 ;;
        -load-trace-edge-limit|--load-trace-edge-limit) LOAD_TRACE_EDGE_LIMIT="$2"; shift 2 ;;
        -load-trace-api-list-limit|--load-trace-api-list-limit) LOAD_TRACE_API_LIST_LIMIT="$2"; shift 2 ;;
        -verdi-timeout-sec|--verdi-timeout-sec) VERDI_TIMEOUT_SEC="$2"; shift 2 ;;
        -kdebug-bin|--kdebug-bin) KDEBUG_BIN="$2"; shift 2 ;;
        -trace-debug|--trace-debug) TRACE_DEBUG="$2"; shift 2 ;;
        -log-file|--log-file) LOG_FILE="$2"; shift 2 ;;
        *) echo "[WARN] unknown arg: $1" >&2; shift ;;
    esac
done

setup_log_file

if [ -z "$MODULE" ]; then
    echo "Usage: $0 -module <mod> -lib <kdb.elab++> -keywords <filter_module> [-output <out.csv>] [-ports <p1,p2,...>] [--keyword-batch-size <n>] [-const-source-fallback 0|1] [-const-trace-depth <N>] [-assign-trace-depth <N>] [-assign-expr-trace-depth <N>] [-load-trace-node-limit <N>] [-load-trace-edge-limit <N>] [-load-trace-api-list-limit <N>] [-verdi-timeout-sec <N>] [-trace-debug 0|1] [-log-file <run.log>]" >&2
    exit 1
fi
case "$CONST_SOURCE_FALLBACK" in
    0|1) ;;
    *) echo "[ERROR] -const-source-fallback must be 0 or 1, got: $CONST_SOURCE_FALLBACK" >&2; exit 1 ;;
esac
case "$CONST_TRACE_DEPTH" in
    ''|*[!0-9]*) echo "[ERROR] -const-trace-depth must be 0 or a positive integer, got: $CONST_TRACE_DEPTH" >&2; exit 1 ;;
esac
case "$ASSIGN_TRACE_DEPTH" in
    ''|*[!0-9]*) echo "[ERROR] -assign-trace-depth must be 0 or a positive integer, got: $ASSIGN_TRACE_DEPTH" >&2; exit 1 ;;
esac
case "$ASSIGN_EXPR_TRACE_DEPTH" in
    ''|*[!0-9]*) echo "[ERROR] -assign-expr-trace-depth must be 0 or a positive integer, got: $ASSIGN_EXPR_TRACE_DEPTH" >&2; exit 1 ;;
esac
case "$LOAD_TRACE_NODE_LIMIT" in
    ''|*[!0-9]*) echo "[ERROR] -load-trace-node-limit must be 0 or a positive integer, got: $LOAD_TRACE_NODE_LIMIT" >&2; exit 1 ;;
esac
case "$LOAD_TRACE_EDGE_LIMIT" in
    ''|*[!0-9]*) echo "[ERROR] -load-trace-edge-limit must be 0 or a positive integer, got: $LOAD_TRACE_EDGE_LIMIT" >&2; exit 1 ;;
esac
case "$LOAD_TRACE_API_LIST_LIMIT" in
    ''|*[!0-9]*) echo "[ERROR] -load-trace-api-list-limit must be 0 or a positive integer, got: $LOAD_TRACE_API_LIST_LIMIT" >&2; exit 1 ;;
esac
case "$VERDI_TIMEOUT_SEC" in
    ''|*[!0-9]*) echo "[ERROR] -verdi-timeout-sec must be 0 or a positive integer, got: $VERDI_TIMEOUT_SEC" >&2; exit 1 ;;
esac
case "$TRACE_DEBUG" in
    0|1) ;;
    *) echo "[ERROR] -trace-debug must be 0 or 1, got: $TRACE_DEBUG" >&2; exit 1 ;;
esac

if [ -n "$FILELIST" ] || [ -n "$TOP" ] || [ -n "$INCDIR" ]; then
    echo "[ERROR] KDB input is mandatory. Do not use -filelist, -top, or -incdir; use -lib <kdb.elab++>." >&2
    exit 1
fi

if [ -z "$LIB" ]; then
    echo "[ERROR] -lib <kdb.elab++> is required. Filelist import is not supported." >&2
    exit 1
fi
case "$LIB" in
    /*) ;;
    *) LIB="$PWD/$LIB" ;;
esac
if [ ! -e "$LIB" ]; then
    echo "[ERROR] KDB path does not exist: $LIB" >&2
    exit 1
fi
if [ -d "$LIB" ] && ! find "$LIB" -mindepth 1 -print -quit | grep -q .; then
    echo "[ERROR] KDB path is empty: $LIB" >&2
    exit 1
fi

if [ -z "$KEYWORDS" ]; then
    echo "[ERROR] -keywords parameter is required; pass one or more module names whose instances should own driver/load signals." >&2
    exit 1
fi

# Default output filename
if [ -z "$OUTPUT" ]; then
    OUTPUT="${MODULE}_filtered.csv"
fi
REQUESTED_OUTPUT="$OUTPUT"
case "$OUTPUT" in
    *.csv) OUTPUT_SUFFIX=".csv" ;;
    *) OUTPUT_SUFFIX="" ;;
esac
OUTPUT="$(bound_runtime_path "$OUTPUT" "$OUTPUT_SUFFIX" "$REQUESTED_OUTPUT")" || exit $?

# Full trace output file (in current directory)
FULL_TRACE="$(bound_runtime_path "${MODULE}_full.csv" "_full.csv" "$MODULE")" || exit $?
MODULE_TRACE="$(bound_runtime_path "${MODULE}_module_connections.csv" "_module_connections.csv" "$MODULE")" || exit $?
KEYWORDS_SAFE="$(printf '%s' "$KEYWORDS" | sed 's/[^A-Za-z0-9_.-][^A-Za-z0-9_.-]*/_/g; s/^[._]*//; s/[._]*$//')"
if [ -z "$KEYWORDS_SAFE" ]; then
    KEYWORDS_SAFE="filter_modules"
fi
INSTANCE_LIST="$(bound_runtime_path "${MODULE}_${KEYWORDS_SAFE}_instances.txt" "_instances.txt" "${MODULE}:${KEYWORDS}")" || exit $?
BOUNDARY_FILTERED="$(bound_runtime_path "${OUTPUT%.csv}_boundary.csv" "_boundary.csv" "${REQUESTED_OUTPUT}:boundary")" || exit $?
FULL_FILTERED="$(bound_runtime_path "${OUTPUT%.csv}_full_owner.csv" "_full_owner.csv" "${REQUESTED_OUTPUT}:full_owner")" || exit $?

log_step "script_dir=$SCRIPT_DIR"
log_step "target_module=$MODULE"
log_step "filter_modules=$KEYWORDS"
log_step "load_mode=lib lib=$LIB"
if [ -n "$PORTS" ]; then
    log_step "port_filter=$PORTS"
else
    log_step "port_filter=<all ports>"
fi
log_step "full_trace=$FULL_TRACE"
log_step "module_boundary_trace=$MODULE_TRACE"
log_step "filter_instance_list=$INSTANCE_LIST"
log_step "keyword_batch_size=$KEYWORD_BATCH_SIZE"
log_step "keyword_continue_on_error=$KEYWORD_CONTINUE_ON_ERROR"
log_step "keyword_log_instances=$KEYWORD_LOG_INSTANCES"
log_step "const_source_fallback=$CONST_SOURCE_FALLBACK"
log_step "const_trace_depth=$CONST_TRACE_DEPTH"
log_step "assign_trace_depth=$ASSIGN_TRACE_DEPTH"
log_step "assign_expr_trace_depth=$ASSIGN_EXPR_TRACE_DEPTH"
log_step "load_trace_node_limit=$LOAD_TRACE_NODE_LIMIT"
log_step "load_trace_edge_limit=$LOAD_TRACE_EDGE_LIMIT"
log_step "load_trace_api_list_limit=$LOAD_TRACE_API_LIST_LIMIT"
log_step "verdi_timeout_sec=$VERDI_TIMEOUT_SEC"
log_step "trace_debug=$TRACE_DEBUG"
log_step "python_bin=$PYTHON_BIN"
log_step "kdebug_bin=${KDEBUG_BIN:-<auto>}"
log_step "boundary_filtered=$BOUNDARY_FILTERED"
log_step "full_owner_filtered=$FULL_FILTERED"
log_step "final_output=$OUTPUT"

log_step "step 1/5: find instances of filter module"
FIND_CMD=("$PYTHON_BIN" "$SCRIPT_DIR/find_instances_batched.py"
    -lib "$LIB"
    -keywords "$KEYWORDS"
    -output "$INSTANCE_LIST"
    --batch-size "$KEYWORD_BATCH_SIZE")
if [ "$KEYWORD_CONTINUE_ON_ERROR" -eq 1 ]; then
    FIND_CMD+=(--continue-on-error)
fi
if [ "$KEYWORD_LOG_INSTANCES" -eq 1 ]; then
    FIND_CMD+=(--log-instances)
fi
if [ -n "$KDEBUG_BIN" ]; then
    FIND_CMD+=(--kdebug-bin "$KDEBUG_BIN")
fi

log_step "command: ${FIND_CMD[*]}"
"${FIND_CMD[@]}"

if [ ! -s "$INSTANCE_LIST" ]; then
    echo "[ERROR] no instances found for filter modules: $KEYWORDS" >&2
    rm -f -- "$INSTANCE_LIST"
    exit 1
fi

INSTANCE_COUNT=$(wc -l < "$INSTANCE_LIST")
log_step "found_filter_instances=$INSTANCE_COUNT"

# Build npi_trace.sh command. The keyword instance list is passed into the
# loader traversal as stop points, so a hit on a keyword input port is recorded
# but the trace does not keep drilling into that instance's internal logic.
TRACE_CMD=("$SCRIPT_DIR/npi_trace.sh"
    -module "$MODULE"
    -module-out "$MODULE_TRACE"
    -lib "$LIB"
    -const-source-fallback "$CONST_SOURCE_FALLBACK"
    -const-trace-depth "$CONST_TRACE_DEPTH"
    -assign-trace-depth "$ASSIGN_TRACE_DEPTH"
    -assign-expr-trace-depth "$ASSIGN_EXPR_TRACE_DEPTH"
    -load-trace-node-limit "$LOAD_TRACE_NODE_LIMIT"
    -load-trace-edge-limit "$LOAD_TRACE_EDGE_LIMIT"
    -load-trace-api-list-limit "$LOAD_TRACE_API_LIST_LIMIT"
    -load-stop-instance-file "$INSTANCE_LIST"
    -verdi-timeout-sec "$VERDI_TIMEOUT_SEC"
    -trace-debug "$TRACE_DEBUG")
if [ -n "$PORTS" ]; then
    TRACE_CMD+=(-ports "$PORTS")
fi
if [ -n "$KDEBUG_BIN" ]; then
    TRACE_CMD+=(--kdebug-bin "$KDEBUG_BIN")
fi

# Run trace
log_step "step 2/5: run kdebug trace for target module"
log_step "command: ${TRACE_CMD[*]} > $FULL_TRACE"
"${TRACE_CMD[@]}" > "$FULL_TRACE"

if [ ! -s "$FULL_TRACE" ]; then
    echo "[ERROR] Trace failed or produced no output" >&2
    rm -f -- "$FULL_TRACE"
    exit 1
fi

if [ ! -s "$MODULE_TRACE" ]; then
    echo "[ERROR] Module-boundary trace failed or produced no output" >&2
    exit 1
fi

TOTAL_LINES=$(wc -l < "$FULL_TRACE")
MODULE_LINES=$(wc -l < "$MODULE_TRACE")
log_step "trace_completed full_trace_lines=$TOTAL_LINES module_boundary_lines=$MODULE_LINES"

log_step "step 3/5: filter module-boundary rows by filter-module ownership"
log_step "command: $PYTHON_BIN $SCRIPT_DIR/filter_trace.py $MODULE_TRACE $BOUNDARY_FILTERED --instances $INSTANCE_LIST --normalize-signal-column"
"$PYTHON_BIN" "$SCRIPT_DIR/filter_trace.py" "$MODULE_TRACE" "$BOUNDARY_FILTERED" --instances "$INSTANCE_LIST" --normalize-signal-column

log_step "step 4/5: filter full-trace rows by filter-module ownership"
log_step "command: $PYTHON_BIN $SCRIPT_DIR/filter_trace.py $FULL_TRACE $FULL_FILTERED --instances $INSTANCE_LIST"
"$PYTHON_BIN" "$SCRIPT_DIR/filter_trace.py" "$FULL_TRACE" "$FULL_FILTERED" --instances "$INSTANCE_LIST"

log_step "step 5/5: merge filtered outputs and split by traced target instance when needed"
log_step "command: $PYTHON_BIN $SCRIPT_DIR/filter_trace.py - $OUTPUT --merge $BOUNDARY_FILTERED $FULL_FILTERED --split-by-trace-instance"
"$PYTHON_BIN" "$SCRIPT_DIR/filter_trace.py" - "$OUTPUT" --merge "$BOUNDARY_FILTERED" "$FULL_FILTERED" --split-by-trace-instance

FINAL_LINES=$(wc -l < "$OUTPUT")
log_step "done final_output=$OUTPUT final_lines=$FINAL_LINES"
log_step "full_trace=$FULL_TRACE"
log_step "module_boundary_trace=$MODULE_TRACE"
log_step "filter_instances=$INSTANCE_LIST"
log_step "boundary_filtered_output=$BOUNDARY_FILTERED"
log_step "full_trace_filtered_output=$FULL_FILTERED"
log_step "per_instance_pattern=${OUTPUT%.csv}__<inst_full_name>.csv"
