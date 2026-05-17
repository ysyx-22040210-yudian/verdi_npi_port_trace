#!/bin/bash
# annotate_trace_xlsx.sh - Fill an XLSX trace template using NPI trace results.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

log_step() {
    echo "[annotate_trace_xlsx] $*" >&2
}

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "[ERROR] $PYTHON_BIN is required" >&2
    exit 1
fi

PYTHON_VERSION="$("$PYTHON_BIN" - <<'PY'
import sys
print(".".join(str(x) for x in sys.version_info[:3]))
raise SystemExit(0 if sys.version_info >= (3, 8) else 1)
PY
)"
if [ $? -ne 0 ]; then
    echo "[ERROR] Python 3.8 or newer is required, got $PYTHON_VERSION" >&2
    exit 1
fi

log_step "script_dir=$SCRIPT_DIR"
log_step "python_bin=$(command -v "$PYTHON_BIN")"
log_step "python_version=$PYTHON_VERSION"
log_step "command: $PYTHON_BIN $SCRIPT_DIR/annotate_trace_xlsx.py $*"
"$PYTHON_BIN" "$SCRIPT_DIR/annotate_trace_xlsx.py" "$@"
