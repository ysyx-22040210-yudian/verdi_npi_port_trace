#!/bin/bash
# npi_trace.sh — run npi_port_trace.tcl via verdi -batch, output port driver/load CSV
#
# Usage:
#   ./npi_trace.sh -module <target_module> -lib <kdb.elab++> [-ports <port1,port2,...>]
#   ./npi_trace.sh -module <target_module> -filelist <filelist.f> -top <top_module> \
#                  [-incdir <include_dir>] [-ports <port1,port2,...>]
#                  [-module-out <module_connections.csv>]
#
# Note: -srcfile parameter is now optional (deprecated). Port direction is obtained via NPI API.
#   ./npi_trace.sh -module ... > result.csv


SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TCL="$SCRIPT_DIR/npi_port_trace.tcl"

log_step() {
    echo "[npi_trace] $*" >&2
}

if [ -z "$VERDI_HOME" ]; then
    echo "[ERROR] VERDI_HOME is not set." >&2
    exit 1
fi

FILELIST=""
INCDIR=""
TOP=""
MODULE=""
SRCFILE=""
PORTS=""
LIB=""
MODULE_OUT=""

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
        *) echo "[WARN] unknown arg: $1" >&2; shift ;;
    esac
done

if [ -z "$MODULE" ]; then
    echo "Usage: $0 -module <mod> [-srcfile <src.v>] [-lib <work.lib++>] [-filelist <f> -top <top>] [-incdir <dir>] [-ports <p1,p2,...>] [-module-out <csv>]" >&2
    echo "  -lib and (-filelist + -top) are mutually exclusive ways to load the design." >&2
    echo "  -srcfile is optional (deprecated, port direction is now obtained via NPI API)." >&2
    echo "  -module-out writes driver/load entries that stop at module boundaries." >&2
    exit 1
fi
if [ -z "$LIB" ] && { [ -z "$FILELIST" ] || [ -z "$TOP" ]; }; then
    echo "[ERROR] Either -lib <work.lib++> or both -filelist and -top must be provided." >&2
    exit 1
fi

TMPOUT="$(mktemp /tmp/npi_trace_out.XXXXXX.csv)"
if [ -z "$MODULE_OUT" ]; then
    MODULE_OUT="${MODULE}_module_connections.csv"
fi

log_step "script_dir=$SCRIPT_DIR"
log_step "tcl=$TCL"
log_step "module=$MODULE"
if [ -n "$LIB" ]; then
    log_step "load_mode=lib lib=$LIB"
else
    log_step "load_mode=filelist filelist=$FILELIST top=$TOP incdir=$INCDIR"
fi
if [ -n "$PORTS" ]; then
    log_step "port_filter=$PORTS"
else
    log_step "port_filter=<all ports>"
fi
log_step "temp_full_trace=$TMPOUT"
log_step "module_boundary_trace=$MODULE_OUT"

export NPI_FILELIST="$FILELIST"
export NPI_TOP="$TOP"
export NPI_MODULE="$MODULE"
export NPI_SRCFILE="$SRCFILE"
export NPI_INCDIR="$INCDIR"
export NPI_PORTS="$PORTS"
export NPI_LIB="$LIB"
export NPI_OUTFILE="$TMPOUT"
export NPI_MODULE_OUTFILE="$MODULE_OUT"

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
