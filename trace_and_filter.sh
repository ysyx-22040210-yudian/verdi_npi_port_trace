#!/bin/bash
# trace_and_filter.sh - Run NPI trace and filter rows by driver/load owner module
#
# Usage:
#   ./trace_and_filter.sh -module <target_module> -lib <kdb.elab++> \
#                         -keywords <filter_module> \
#                         [-output <output.csv>] [-ports <port1,port2,...>]
#
# Example:
#   ./trace_and_filter.sh -module ysyx_22050058_id \
#                         -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
#                         -keywords ysyx_22050058_regfile \
#                         -output id_filtered.csv

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIND_INST_TCL="$SCRIPT_DIR/npi_find_instances.tcl"

MODULE=""
LIB=""
KEYWORDS=""
OUTPUT=""
PORTS=""
FILELIST=""
INCDIR=""
TOP=""

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
        *) echo "[WARN] unknown arg: $1" >&2; shift ;;
    esac
done

if [ -z "$MODULE" ]; then
    echo "Usage: $0 -module <mod> -lib <kdb.elab++> -keywords <filter_module> [-output <out.csv>] [-ports <p1,p2,...>]" >&2
    exit 1
fi

if [ -z "$LIB" ] && { [ -z "$FILELIST" ] || [ -z "$TOP" ]; }; then
    echo "[ERROR] Either -lib or both -filelist and -top must be provided." >&2
    exit 1
fi

if [ -z "$KEYWORDS" ]; then
    echo "[ERROR] -keywords parameter is required; pass the module name whose instances should own driver/load signals." >&2
    exit 1
fi

if [[ "$KEYWORDS" == *","* ]]; then
    echo "[ERROR] -keywords now expects one module name, not a comma-separated keyword list." >&2
    exit 1
fi

# Default output filename
if [ -z "$OUTPUT" ]; then
    OUTPUT="${MODULE}_filtered.csv"
fi

# Full trace output file (in current directory)
FULL_TRACE="${MODULE}_full.csv"
MODULE_TRACE="${MODULE}_module_connections.csv"
INSTANCE_LIST="${MODULE}_${KEYWORDS}_instances.txt"
BOUNDARY_FILTERED="${OUTPUT%.csv}_boundary.csv"
FULL_FILTERED="${OUTPUT%.csv}_full_owner.csv"

echo "Running NPI trace for module: $MODULE"

# Build npi_trace.sh command
TRACE_CMD="$SCRIPT_DIR/npi_trace.sh -module $MODULE -module-out $MODULE_TRACE"
if [ -n "$LIB" ]; then
    TRACE_CMD="$TRACE_CMD -lib $LIB"
fi
if [ -n "$FILELIST" ]; then
    TRACE_CMD="$TRACE_CMD -filelist $FILELIST"
fi
if [ -n "$TOP" ]; then
    TRACE_CMD="$TRACE_CMD -top $TOP"
fi
if [ -n "$INCDIR" ]; then
    TRACE_CMD="$TRACE_CMD -incdir $INCDIR"
fi
if [ -n "$PORTS" ]; then
    TRACE_CMD="$TRACE_CMD -ports $PORTS"
fi

# Run trace
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
echo "Trace completed: $TOTAL_LINES lines (including header)"
echo "Full trace saved to: $FULL_TRACE"
echo "Module-boundary trace saved to: $MODULE_TRACE ($MODULE_LINES lines including header)"

echo "Finding instances of module: $KEYWORDS"
export NPI_FILELIST="$FILELIST"
export NPI_TOP="$TOP"
export NPI_INCDIR="$INCDIR"
export NPI_LIB="$LIB"
export NPI_FILTER_MODULE="$KEYWORDS"
export NPI_INSTANCE_OUTFILE="$INSTANCE_LIST"

verdi -batch -nologo -play "$FIND_INST_TCL" >/dev/null 2>&1

if [ ! -s "$INSTANCE_LIST" ]; then
    echo "[ERROR] no instances found for filter module: $KEYWORDS" >&2
    rm -f "$INSTANCE_LIST"
    exit 1
fi

INSTANCE_COUNT=$(wc -l < "$INSTANCE_LIST")
echo "Found $INSTANCE_COUNT filter instances"
echo "Filtering module-boundary rows whose driver/load signal belongs to module instances: $KEYWORDS"
python3 "$SCRIPT_DIR/filter_trace.py" "$MODULE_TRACE" "$BOUNDARY_FILTERED" --instances "$INSTANCE_LIST" --normalize-signal-column

echo "Filtering full-trace rows whose driver/load signal belongs to module instances: $KEYWORDS"
python3 "$SCRIPT_DIR/filter_trace.py" "$FULL_TRACE" "$FULL_FILTERED" --instances "$INSTANCE_LIST"

echo "Merging boundary and full-trace filtered rows"
python3 "$SCRIPT_DIR/filter_trace.py" - "$OUTPUT" --merge "$BOUNDARY_FILTERED" "$FULL_FILTERED" --split-by-trace-instance

echo ""
echo "Full trace: $FULL_TRACE"
echo "Module-boundary trace: $MODULE_TRACE"
echo "Filter instances: $INSTANCE_LIST"
echo "Boundary filtered output: $BOUNDARY_FILTERED"
echo "Full-trace filtered output: $FULL_FILTERED"
echo "Filtered output: $OUTPUT"
echo "If multiple instances of $MODULE are present, per-instance CSV files are written as:"
echo "  ${OUTPUT%.csv}__<inst_full_name>.csv"
