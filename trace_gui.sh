#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

find_python_with_tkinter() {
    local candidate
    for candidate in \
        "${PYTHON_BIN:-}" \
        "/opt/rh/rh-python38/root/usr/bin/python3" \
        "/usr/local/bin/python3" \
        "python3" \
        "python"
    do
        [ -n "$candidate" ] || continue
        if command -v "$candidate" >/dev/null 2>&1 &&
           "$candidate" -c 'import tkinter' >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

if ! PYTHON_BIN="$(find_python_with_tkinter)"; then
    echo "[trace_gui] ERROR: no Python with tkinter was found." >&2
    echo "[trace_gui] Try one of:" >&2
    echo "[trace_gui]   source /opt/rh/rh-python38/enable" >&2
    echo "[trace_gui]   yum install -y rh-python38-python-tkinter" >&2
    echo "[trace_gui] Or set PYTHON_BIN=/path/to/python3 with tkinter installed." >&2
    exit 1
fi

echo "[trace_gui] script_dir=$SCRIPT_DIR" >&2
echo "[trace_gui] python_bin=$PYTHON_BIN" >&2
export PYTHON_BIN
export PATH="$(dirname "$PYTHON_BIN"):$PATH"
exec "$PYTHON_BIN" "$SCRIPT_DIR/trace_gui.py" "$@"
