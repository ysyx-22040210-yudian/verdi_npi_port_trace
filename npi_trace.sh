#!/bin/bash
# npi_trace.sh — run npi_port_trace.tcl via verdi -batch, output port driver/load CSV
#
# Usage:
#   ./npi_trace.sh -module <target_module> -lib <kdb.elab++> [-ports <port1,port2,...>]
#                  [-module-out <module_connections.csv>]
#                  [-const-source-fallback 0|1] [-const-trace-depth <N>]
#                  [-assign-trace-depth <N>] [-assign-expr-trace-depth <N>]
#                  [-trace-debug 0|1] [-log-file <run.log>]
#
# Note: -srcfile parameter is now optional (deprecated). Port direction is obtained via NPI API.
#   ./npi_trace.sh -module ... > result.csv


SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TCL="$SCRIPT_DIR/npi_port_trace.tcl"

log_step() {
    echo "[npi_trace] $*" >&2
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

FILELIST=""
INCDIR=""
TOP=""
MODULE=""
SRCFILE=""
PORTS=""
LIB=""
MODULE_OUT=""
CONST_SOURCE_FALLBACK="${NPI_CONST_SOURCE_FALLBACK:-1}"
CONST_TRACE_DEPTH="${NPI_CONST_TRACE_MAX_DEPTH:-16}"
ASSIGN_TRACE_DEPTH="${NPI_ASSIGN_TRACE_MAX_DEPTH:-2}"
ASSIGN_EXPR_TRACE_DEPTH="${NPI_ASSIGN_EXPR_TRACE_MAX_DEPTH:-1}"
TRACE_DEBUG="${NPI_TRACE_DEBUG:-0}"
LOG_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -filelist) FILELIST="$2"; shift 2 ;;
        -incdir)   INCDIR="$2";   shift 2 ;;
        -top)      TOP="$2";      shift 2 ;;
        -module)   MODULE="$2";   shift 2 ;;
        -srcfile)  SRCFILE="$2";  shift 2 ;;
        -ports)    PORTS="$2";    shift 2 ;;
        -lib)      LIB="$2";      shift 2 ;;
        -module-out) MODULE_OUT="$2"; shift 2 ;;
        -const-source-fallback|--const-source-fallback) CONST_SOURCE_FALLBACK="$2"; shift 2 ;;
        -const-trace-depth|--const-trace-depth) CONST_TRACE_DEPTH="$2"; shift 2 ;;
        -assign-trace-depth|--assign-trace-depth) ASSIGN_TRACE_DEPTH="$2"; shift 2 ;;
        -assign-expr-trace-depth|--assign-expr-trace-depth) ASSIGN_EXPR_TRACE_DEPTH="$2"; shift 2 ;;
        -trace-debug|--trace-debug) TRACE_DEBUG="$2"; shift 2 ;;
        -log-file|--log-file) LOG_FILE="$2"; shift 2 ;;
        *) echo "[WARN] unknown arg: $1" >&2; shift ;;
    esac
done

setup_log_file

if [ -z "$VERDI_HOME" ]; then
    echo "[ERROR] VERDI_HOME is not set." >&2
    exit 1
fi

if [ -z "$MODULE" ]; then
    echo "Usage: $0 -module <mod> -lib <kdb.elab++> [-srcfile <src.v>] [-ports <p1,p2,...>] [-module-out <csv>] [-const-source-fallback 0|1] [-const-trace-depth <N>] [-assign-trace-depth <N>] [-assign-expr-trace-depth <N>] [-trace-debug 0|1] [-log-file <run.log>]" >&2
    echo "  -srcfile is optional (deprecated, port direction is now obtained via NPI API)." >&2
    echo "  -module-out writes driver/load entries that stop at module boundaries." >&2
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

TMPOUT="$(mktemp "$PWD/npi_trace_out.XXXXXX.csv")"
if [ -z "$MODULE_OUT" ]; then
    MODULE_OUT="${MODULE}_module_connections.csv"
fi

log_step "script_dir=$SCRIPT_DIR"
log_step "tcl=$TCL"
log_step "module=$MODULE"
log_step "load_mode=lib lib=$LIB"
if [ -n "$PORTS" ]; then
    log_step "port_filter=$PORTS"
else
    log_step "port_filter=<all ports>"
fi
log_step "temp_full_trace=$TMPOUT"
log_step "module_boundary_trace=$MODULE_OUT"
log_step "const_source_fallback=$CONST_SOURCE_FALLBACK"
log_step "const_trace_depth=$CONST_TRACE_DEPTH"
log_step "assign_trace_depth=$ASSIGN_TRACE_DEPTH"
log_step "assign_expr_trace_depth=$ASSIGN_EXPR_TRACE_DEPTH"
log_step "trace_debug=$TRACE_DEBUG"

export NPI_MODULE="$MODULE"
export NPI_SRCFILE="$SRCFILE"
export NPI_PORTS="$PORTS"
export NPI_LIB="$LIB"
export NPI_OUTFILE="$TMPOUT"
export NPI_MODULE_OUTFILE="$MODULE_OUT"
export NPI_CONST_SOURCE_FALLBACK="$CONST_SOURCE_FALLBACK"
export NPI_CONST_TRACE_MAX_DEPTH="$CONST_TRACE_DEPTH"
export NPI_ASSIGN_TRACE_MAX_DEPTH="$ASSIGN_TRACE_DEPTH"
export NPI_ASSIGN_EXPR_TRACE_MAX_DEPTH="$ASSIGN_EXPR_TRACE_DEPTH"
export NPI_TRACE_DEBUG="$TRACE_DEBUG"

log_step "running Verdi batch trace"
verdi -batch -nologo -play "$TCL" 1>&2

if [ ! -s "$TMPOUT" ]; then
    echo "[ERROR] no output generated" >&2
    rm -f "$TMPOUT"
    exit 1
fi

FULL_LINES=$(wc -l < "$TMPOUT")
if [ -s "$MODULE_OUT" ]; then
    MODULE_LINES=$(wc -l < "$MODULE_OUT")
else
    MODULE_LINES=0
fi
log_step "trace_done full_trace_lines=$FULL_LINES module_boundary_lines=$MODULE_LINES"
log_step "writing full trace CSV to stdout"
cat "$TMPOUT"
rm -f "$TMPOUT"
log_step "removed temp_full_trace=$TMPOUT"
