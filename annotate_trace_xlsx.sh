#!/bin/bash
# annotate_trace_xlsx.sh - Fill an XLSX trace template using NPI trace results.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
LOG_FILE=""

log_step() {
    echo "[annotate_trace_xlsx] $*" >&2
}

setup_log_file() {
    local arg
    local next_is_log=0
    for arg in "$@"; do
        if [ "$next_is_log" -eq 1 ]; then
            LOG_FILE="$arg"
            break
        fi
        case "$arg" in
            -log-file|--log-file) next_is_log=1 ;;
        esac
    done
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
    export ANNOTATE_TRACE_XLSX_LOG_TEE_ACTIVE=1
    log_step "log_file=$LOG_FILE"
}

setup_log_file "$@"

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
