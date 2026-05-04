#!/bin/bash
# trace_and_filter.sh - Run NPI trace and filter results by keywords
#
# Usage:
#   ./trace_and_filter.sh -module <target_module> -lib <kdb.elab++> \
#                         -keywords <keyword1,keyword2,...> \
#                         [-output <output.csv>] [-ports <port1,port2,...>]
#
# Example:
#   ./trace_and_filter.sh -module ysyx_22050058_id \
#                         -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
#                         -keywords "Memory,RegCombo" \
#                         -output id_filtered.csv

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
    echo "Usage: $0 -module <mod> -lib <kdb.elab++> -keywords <kw1,kw2,...> [-output <out.csv>] [-ports <p1,p2,...>]" >&2
    exit 1
fi

if [ -z "$LIB" ] && { [ -z "$FILELIST" ] || [ -z "$TOP" ]; }; then
    echo "[ERROR] Either -lib or both -filelist and -top must be provided." >&2
    exit 1
fi

if [ -z "$KEYWORDS" ]; then
    echo "[ERROR] -keywords parameter is required (comma-separated list)" >&2
    exit 1
fi

# Default output filename
if [ -z "$OUTPUT" ]; then
    OUTPUT="${MODULE}_filtered.csv"
fi

# Full trace output file (in current directory)
FULL_TRACE="${MODULE}_full.csv"

echo "Running NPI trace for module: $MODULE"

# Build npi_trace.sh command
TRACE_CMD="$SCRIPT_DIR/npi_trace.sh -module $MODULE"
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

TOTAL_LINES=$(wc -l < "$FULL_TRACE")
echo "Trace completed: $TOTAL_LINES lines (including header)"
echo "Full trace saved to: $FULL_TRACE"

# Convert comma-separated keywords to space-separated for Python
IFS=',' read -ra KW_ARRAY <<< "$KEYWORDS"

echo "Filtering by keywords: ${KW_ARRAY[*]}"

# Run Python filter
python3 "$SCRIPT_DIR/filter_trace.py" "$FULL_TRACE" "$OUTPUT" "${KW_ARRAY[@]}"

echo ""
echo "Full trace: $FULL_TRACE"
echo "Filtered output: $OUTPUT"
