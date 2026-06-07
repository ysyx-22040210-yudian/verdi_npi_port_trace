#!/bin/bash
# trace_and_filter.sh - Run NPI trace and filter rows by driver/load owner module
#
# Usage:
#   ./trace_and_filter.sh -module <target_module> -lib <kdb.elab++> \
#                         -keywords <filter_module[,filter_module...]> \
#                         [-output <output.csv>] [-ports <port1,port2,...>] \
#                         [--keyword-batch-size <n>] \
#                         [-const-source-fallback 0|1] [-const-trace-depth <N>] \
#                         [-assign-trace-depth <N>] [-assign-expr-trace-depth <N>]
#                         [-trace-debug 0|1]
#
# Example:
#   ./trace_and_filter.sh -module ysyx_22050058_id \
#                         -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
#                         -keywords ysyx_22050058_regfile \
#                         -output id_filtered.csv

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIND_INST_TCL="$SCRIPT_DIR/npi_find_instances.tcl"

log_step() {
    echo "[trace_and_filter] $*" >&2
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
TRACE_DEBUG="${NPI_TRACE_DEBUG:-0}"

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
        -trace-debug|--trace-debug) TRACE_DEBUG="$2"; shift 2 ;;
        *) echo "[WARN] unknown arg: $1" >&2; shift ;;
    esac
done

if [ -z "$MODULE" ]; then
    echo "Usage: $0 -module <mod> -lib <kdb.elab++> -keywords <filter_module> [-output <out.csv>] [-ports <p1,p2,...>] [--keyword-batch-size <n>] [-const-source-fallback 0|1] [-const-trace-depth <N>] [-assign-trace-depth <N>] [-assign-expr-trace-depth <N>] [-trace-debug 0|1]" >&2
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

# Full trace output file (in current directory)
FULL_TRACE="${MODULE}_full.csv"
MODULE_TRACE="${MODULE}_module_connections.csv"
KEYWORDS_SAFE="$(printf '%s' "$KEYWORDS" | sed 's/[^A-Za-z0-9_.-][^A-Za-z0-9_.-]*/_/g; s/^[._]*//; s/[._]*$//')"
if [ -z "$KEYWORDS_SAFE" ]; then
    KEYWORDS_SAFE="filter_modules"
fi
INSTANCE_LIST="${MODULE}_${KEYWORDS_SAFE}_instances.txt"
BOUNDARY_FILTERED="${OUTPUT%.csv}_boundary.csv"
FULL_FILTERED="${OUTPUT%.csv}_full_owner.csv"

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
log_step "trace_debug=$TRACE_DEBUG"
log_step "boundary_filtered=$BOUNDARY_FILTERED"
log_step "full_owner_filtered=$FULL_FILTERED"
log_step "final_output=$OUTPUT"

# Build npi_trace.sh command
TRACE_CMD="$SCRIPT_DIR/npi_trace.sh -module $MODULE -module-out $MODULE_TRACE"
TRACE_CMD="$TRACE_CMD -lib $LIB"
TRACE_CMD="$TRACE_CMD -const-source-fallback $CONST_SOURCE_FALLBACK -const-trace-depth $CONST_TRACE_DEPTH"
TRACE_CMD="$TRACE_CMD -assign-trace-depth $ASSIGN_TRACE_DEPTH"
TRACE_CMD="$TRACE_CMD -assign-expr-trace-depth $ASSIGN_EXPR_TRACE_DEPTH"
TRACE_CMD="$TRACE_CMD -trace-debug $TRACE_DEBUG"
if [ -n "$PORTS" ]; then
    TRACE_CMD="$TRACE_CMD -ports $PORTS"
fi

# Run trace
log_step "step 1/5: run NPI trace for target module"
log_step "command: $TRACE_CMD > $FULL_TRACE"
$TRACE_CMD > "$FULL_TRACE"

if [ ! -s "$FULL_TRACE" ]; then
    echo "[ERROR] Trace failed or produced no output" >&2
    rm -f "$FULL_TRACE"
    exit 1
fi

if [ ! -s "$MODULE_TRACE" ]; then
    echo "[ERROR] Module-boundary trace failed or produced no output" >&2
    exit 1
fi

TOTAL_LINES=$(wc -l < "$FULL_TRACE")
MODULE_LINES=$(wc -l < "$MODULE_TRACE")
log_step "trace_completed full_trace_lines=$TOTAL_LINES module_boundary_lines=$MODULE_LINES"

log_step "step 2/5: find instances of filter module"
FIND_CMD=(python3 "$SCRIPT_DIR/find_instances_batched.py"
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

log_step "command: ${FIND_CMD[*]}"
"${FIND_CMD[@]}"

if [ ! -s "$INSTANCE_LIST" ]; then
    echo "[ERROR] no instances found for filter modules: $KEYWORDS" >&2
    rm -f "$INSTANCE_LIST"
    exit 1
fi

INSTANCE_COUNT=$(wc -l < "$INSTANCE_LIST")
log_step "found_filter_instances=$INSTANCE_COUNT"
log_step "step 3/5: filter module-boundary rows by filter-module ownership"
log_step "command: python3 $SCRIPT_DIR/filter_trace.py $MODULE_TRACE $BOUNDARY_FILTERED --instances $INSTANCE_LIST --normalize-signal-column"
python3 "$SCRIPT_DIR/filter_trace.py" "$MODULE_TRACE" "$BOUNDARY_FILTERED" --instances "$INSTANCE_LIST" --normalize-signal-column

log_step "step 4/5: filter full-trace rows by filter-module ownership"
log_step "command: python3 $SCRIPT_DIR/filter_trace.py $FULL_TRACE $FULL_FILTERED --instances $INSTANCE_LIST"
python3 "$SCRIPT_DIR/filter_trace.py" "$FULL_TRACE" "$FULL_FILTERED" --instances "$INSTANCE_LIST"

log_step "step 5/5: merge filtered outputs and split by traced target instance when needed"
log_step "command: python3 $SCRIPT_DIR/filter_trace.py - $OUTPUT --merge $BOUNDARY_FILTERED $FULL_FILTERED --split-by-trace-instance"
python3 "$SCRIPT_DIR/filter_trace.py" - "$OUTPUT" --merge "$BOUNDARY_FILTERED" "$FULL_FILTERED" --split-by-trace-instance

FINAL_LINES=$(wc -l < "$OUTPUT")
log_step "done final_output=$OUTPUT final_lines=$FINAL_LINES"
log_step "full_trace=$FULL_TRACE"
log_step "module_boundary_trace=$MODULE_TRACE"
log_step "filter_instances=$INSTANCE_LIST"
log_step "boundary_filtered_output=$BOUNDARY_FILTERED"
log_step "full_trace_filtered_output=$FULL_FILTERED"
log_step "per_instance_pattern=${OUTPUT%.csv}__<inst_full_name>.csv"
