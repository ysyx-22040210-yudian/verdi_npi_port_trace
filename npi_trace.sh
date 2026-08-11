#!/bin/bash
# npi_trace.sh — run the public kdebug port.trace_batch backend and output port CSV
#
# Usage:
#   ./npi_trace.sh -module <target_module> -lib <kdb.elab++> [-ports <port1,port2,...>]
#                  [-module-out <module_connections.csv>] [-ports-file <ports.txt>]
#                  [-const-source-fallback 0|1] [-const-trace-depth <N>]
#                  [-assign-trace-depth <N>] [-assign-expr-trace-depth <N>]
#                  [-load-trace-node-limit <N>] [-load-trace-edge-limit <N>]
#                  [-load-trace-api-list-limit <N>]
#                  [-load-stop-instance-file <instances.txt>]
#                  [-trace-max-rows <N>]
#                  [-verdi-timeout-sec <N>]
#                  [-trace-debug 0|1] [-log-file <run.log>]
#
# Note: -srcfile is an optional source-fallback hint. Port direction comes from the KDB.
#   ./npi_trace.sh -module ... > result.csv


SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$SCRIPT_DIR/kdebug_backend.py"

log_step() {
    echo "[npi_trace] $*" >&2
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

FILELIST=""
INCDIR=""
TOP=""
MODULE=""
SRCFILE=""
PORTS=""
PORTS_FILE=""
LIB=""
MODULE_OUT=""
CONST_SOURCE_FALLBACK="${NPI_CONST_SOURCE_FALLBACK:-1}"
CONST_TRACE_DEPTH="${NPI_CONST_TRACE_MAX_DEPTH:-16}"
ASSIGN_TRACE_DEPTH="${NPI_ASSIGN_TRACE_MAX_DEPTH:-2}"
ASSIGN_EXPR_TRACE_DEPTH="${NPI_ASSIGN_EXPR_TRACE_MAX_DEPTH:-1}"
LOAD_TRACE_NODE_LIMIT="${NPI_LOAD_TRACE_NODE_LIMIT:-20000}"
LOAD_TRACE_EDGE_LIMIT="${NPI_LOAD_TRACE_EDGE_LIMIT:-100000}"
LOAD_TRACE_API_LIST_LIMIT="${NPI_LOAD_TRACE_API_LIST_LIMIT:-20000}"
LOAD_STOP_INSTANCE_FILE="${NPI_LOAD_STOP_INSTANCE_FILE:-}"
TRACE_MAX_ROWS="${NPI_TRACE_MAX_ROWS:-20000}"
VERDI_TIMEOUT_SEC="${NPI_VERDI_TIMEOUT_SEC:-0}"
KDEBUG_TIMEOUT_CLEANUP_GRACE_SEC="${NPI_KDEBUG_TIMEOUT_CLEANUP_GRACE_SEC:-10}"
TRACE_DEBUG="${NPI_TRACE_DEBUG:-0}"
LOG_FILE=""
KDEBUG_BIN="${KDEBUG_BIN:-}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

while [ $# -gt 0 ]; do
    case "$1" in
        -filelist) FILELIST="$2"; shift 2 ;;
        -incdir)   INCDIR="$2";   shift 2 ;;
        -top)      TOP="$2";      shift 2 ;;
        -module)   MODULE="$2";   shift 2 ;;
        -srcfile)  SRCFILE="$2";  shift 2 ;;
        -ports)    PORTS="$2";    shift 2 ;;
        -ports-file|--ports-file) PORTS_FILE="$2"; shift 2 ;;
        -lib)      LIB="$2";      shift 2 ;;
        -module-out) MODULE_OUT="$2"; shift 2 ;;
        -const-source-fallback|--const-source-fallback) CONST_SOURCE_FALLBACK="$2"; shift 2 ;;
        -const-trace-depth|--const-trace-depth) CONST_TRACE_DEPTH="$2"; shift 2 ;;
        -assign-trace-depth|--assign-trace-depth) ASSIGN_TRACE_DEPTH="$2"; shift 2 ;;
        -assign-expr-trace-depth|--assign-expr-trace-depth) ASSIGN_EXPR_TRACE_DEPTH="$2"; shift 2 ;;
        -load-trace-node-limit|--load-trace-node-limit) LOAD_TRACE_NODE_LIMIT="$2"; shift 2 ;;
        -load-trace-edge-limit|--load-trace-edge-limit) LOAD_TRACE_EDGE_LIMIT="$2"; shift 2 ;;
        -load-trace-api-list-limit|--load-trace-api-list-limit) LOAD_TRACE_API_LIST_LIMIT="$2"; shift 2 ;;
        -load-stop-instance-file|--load-stop-instance-file) LOAD_STOP_INSTANCE_FILE="$2"; shift 2 ;;
        -trace-max-rows|--trace-max-rows|-max-rows|--max-rows) TRACE_MAX_ROWS="$2"; shift 2 ;;
        -verdi-timeout-sec|--verdi-timeout-sec) VERDI_TIMEOUT_SEC="$2"; shift 2 ;;
        -kdebug-bin|--kdebug-bin) KDEBUG_BIN="$2"; shift 2 ;;
        -trace-debug|--trace-debug) TRACE_DEBUG="$2"; shift 2 ;;
        -log-file|--log-file) LOG_FILE="$2"; shift 2 ;;
        *) echo "[WARN] unknown arg: $1" >&2; shift ;;
    esac
done

setup_log_file

if [ -z "$MODULE" ]; then
    echo "Usage: $0 -module <mod> -lib <kdb.elab++> [-srcfile <src.v>] [-ports <p1,p2,...>] [-ports-file <ports.txt>] [-module-out <csv>] [-const-source-fallback 0|1] [-const-trace-depth <N>] [-assign-trace-depth <N>] [-assign-expr-trace-depth <N>] [-load-trace-node-limit <N>] [-load-trace-edge-limit <N>] [-load-trace-api-list-limit <N>] [-load-stop-instance-file <instances.txt>] [-trace-max-rows <N>] [-verdi-timeout-sec <N>] [-trace-debug 0|1] [-log-file <run.log>]" >&2
    echo "  -srcfile is optional and is passed to kdebug as the source-fallback hint." >&2
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
case "$LOAD_TRACE_NODE_LIMIT" in
    ''|*[!0-9]*) echo "[ERROR] -load-trace-node-limit must be 0 or a positive integer, got: $LOAD_TRACE_NODE_LIMIT" >&2; exit 1 ;;
esac
case "$LOAD_TRACE_EDGE_LIMIT" in
    ''|*[!0-9]*) echo "[ERROR] -load-trace-edge-limit must be 0 or a positive integer, got: $LOAD_TRACE_EDGE_LIMIT" >&2; exit 1 ;;
esac
case "$LOAD_TRACE_API_LIST_LIMIT" in
    ''|*[!0-9]*) echo "[ERROR] -load-trace-api-list-limit must be 0 or a positive integer, got: $LOAD_TRACE_API_LIST_LIMIT" >&2; exit 1 ;;
esac
case "$TRACE_MAX_ROWS" in
    ''|*[!0-9]*) echo "[ERROR] -trace-max-rows must be 0 or a positive integer, got: $TRACE_MAX_ROWS" >&2; exit 1 ;;
esac
if [ -n "$SRCFILE" ] && [ ! -f "$SRCFILE" ]; then
    echo "[ERROR] -srcfile does not exist: $SRCFILE" >&2
    exit 1
fi
if [ -n "$LOAD_STOP_INSTANCE_FILE" ]; then
    case "$LOAD_STOP_INSTANCE_FILE" in
        /*) ;;
        *) LOAD_STOP_INSTANCE_FILE="$PWD/$LOAD_STOP_INSTANCE_FILE" ;;
    esac
    if [ ! -f "$LOAD_STOP_INSTANCE_FILE" ]; then
        echo "[ERROR] -load-stop-instance-file does not exist: $LOAD_STOP_INSTANCE_FILE" >&2
        exit 1
    fi
fi
if [ -n "$PORTS_FILE" ]; then
    case "$PORTS_FILE" in
        /*) ;;
        *) PORTS_FILE="$PWD/$PORTS_FILE" ;;
    esac
    if [ ! -f "$PORTS_FILE" ]; then
        echo "[ERROR] -ports-file does not exist: $PORTS_FILE" >&2
        exit 1
    fi
fi
case "$VERDI_TIMEOUT_SEC" in
    ''|*[!0-9]*) echo "[ERROR] -verdi-timeout-sec must be 0 or a positive integer, got: $VERDI_TIMEOUT_SEC" >&2; exit 1 ;;
esac
case "$KDEBUG_TIMEOUT_CLEANUP_GRACE_SEC" in
    ''|*[!0-9]*) echo "[ERROR] NPI_KDEBUG_TIMEOUT_CLEANUP_GRACE_SEC must be 0 or a positive integer, got: $KDEBUG_TIMEOUT_CLEANUP_GRACE_SEC" >&2; exit 1 ;;
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

if [ -z "$MODULE_OUT" ]; then
    MODULE_OUT="${MODULE}_module_connections.csv"
fi
REQUESTED_MODULE_OUT="$MODULE_OUT"
case "$MODULE_OUT" in
    *.csv) MODULE_OUT_SUFFIX=".csv" ;;
    *) MODULE_OUT_SUFFIX="" ;;
esac
MODULE_OUT="$(bound_runtime_path "$MODULE_OUT" "$MODULE_OUT_SUFFIX" "$REQUESTED_MODULE_OUT")" || exit $?

TMPOUT="$(mktemp "$PWD/npi_trace_out.XXXXXX.csv")"
VERDI_SESSION_FILE="$(mktemp "$PWD/npi_trace_session.XXXXXX")"
VERDI_TIMEOUT_SENTINEL="$(mktemp "$PWD/npi_trace_timeout.XXXXXX")"
KDEBUG_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/port-trace-kdebug.XXXXXX")"
if [ -z "$KDEBUG_TMPDIR" ] || [ ! -d "$KDEBUG_TMPDIR" ]; then
    echo "[ERROR] could not create a private kdebug temp directory" >&2
    rm -f -- "$TMPOUT" "$VERDI_SESSION_FILE" "$VERDI_TIMEOUT_SENTINEL"
    exit 1
fi
export TMPDIR="$KDEBUG_TMPDIR"
NPI_KDEBUG_RUN_TOKEN="port-trace:${KDEBUG_TMPDIR}:$$"
export NPI_KDEBUG_RUN_TOKEN
VERDI_RUNNER_PID=""

cleanup_kdebug_tmpdir() {
    if [ -z "$KDEBUG_TMPDIR" ] || [ ! -d "$KDEBUG_TMPDIR" ]; then
        return
    fi
    case "$(basename -- "$KDEBUG_TMPDIR")" in
        port-trace-kdebug.*) rm -rf -- "$KDEBUG_TMPDIR" ;;
        *) echo "[ERROR] refusing to remove unexpected kdebug temp path: $KDEBUG_TMPDIR" >&2 ;;
    esac
}

run_token_live_pids() {
    "$PYTHON_BIN" - "$NPI_KDEBUG_RUN_TOKEN" "$$" "${BASHPID:-$$}" <<'PY'
from __future__ import print_function

import os
import sys

if not sys.platform.startswith("linux") or not os.path.isdir("/proc"):
    raise SystemExit(0)

marker = ("NPI_KDEBUG_RUN_TOKEN=" + sys.argv[1]).encode("utf-8")
excluded = {os.getpid(), os.getppid()}
for value in sys.argv[2:]:
    try:
        excluded.add(int(value))
    except ValueError:
        pass

for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    pid = int(entry)
    if pid in excluded:
        continue
    try:
        with open(os.path.join("/proc", entry, "environ"), "rb") as handle:
            environment = handle.read()
        with open(os.path.join("/proc", entry, "stat"), "r") as handle:
            process_stat = handle.read()
    except (IOError, OSError):
        continue
    if marker not in environment.split(b"\0"):
        continue
    state_fields = process_stat.rsplit(")", 1)
    if len(state_fields) == 2 and state_fields[1].lstrip().startswith("Z"):
        continue
    print(pid)
PY
}

signal_kdebug_run_token() {
    local signal_name="$1"
    local pid
    while read -r pid; do
        if [ -n "$pid" ]; then
            kill "-$signal_name" "$pid" 2>/dev/null || true
        fi
    done < <(run_token_live_pids)
}

cleanup_kdebug_run_token() {
    local term_grace="${1:-2}"
    local remaining
    local deadline
    local attempt

    remaining="$(run_token_live_pids)"
    if [ -z "$remaining" ]; then
        return 0
    fi

    log_step "cleaning kdebug run token signal=TERM"
    signal_kdebug_run_token TERM
    deadline=$((SECONDS + term_grace))
    while [ "$SECONDS" -lt "$deadline" ]; do
        remaining="$(run_token_live_pids)"
        if [ -z "$remaining" ]; then
            return 0
        fi
        sleep 0.1
    done

    remaining="$(run_token_live_pids | tr '\n' ',')"
    log_step "cleaning kdebug run token signal=KILL remaining_pids=${remaining%,}"
    attempt=0
    while [ "$attempt" -lt 20 ]; do
        signal_kdebug_run_token KILL
        sleep 0.1
        remaining="$(run_token_live_pids)"
        if [ -z "$remaining" ]; then
            return 0
        fi
        attempt=$((attempt + 1))
    done

    echo "[ERROR] could not kill all processes for this kdebug run" >&2
    return 1
}

cleanup_failed_trace() {
    rm -f -- "$TMPOUT" "$MODULE_OUT" "$VERDI_SESSION_FILE" "$VERDI_TIMEOUT_SENTINEL"
    cleanup_kdebug_tmpdir
}

run_verdi_timeout_wrapper() {
    local timeout_sentinel="$1"
    local session_file="$2"
    local child_pid
    local child_rc
    shift 2

    trap 'printf "%s\n" "GNU_TIMEOUT" > "$timeout_sentinel"; exit 191' USR1
    setsid sh -c 'session_file=$1; shift; printf "%s\n" "$$" > "$session_file"; exec "$@"' \
        npi-verdi-session "$session_file" "$@" &
    child_pid=$!
    wait "$child_pid"
    child_rc=$?
    trap - USR1
    return "$child_rc"
}
export -f run_verdi_timeout_wrapper

session_live_pids() {
    ps -e -o pid= -o sid= -o stat= | awk -v sid="$1" '$2 == sid && $3 !~ /^Z/ { print $1 }'
}

signal_verdi_session() {
    local session_id="$1"
    local signal_name="$2"
    local pid
    while read -r pid; do
        if [ -n "$pid" ]; then
            kill "-$signal_name" "$pid" 2>/dev/null || true
        fi
    done < <(session_live_pids "$session_id")
}

cleanup_verdi_session() {
    local session_id="$1"
    local term_grace="${2:-5}"
    local remaining
    local deadline
    local attempt

    case "$session_id" in
        ''|*[!0-9]*)
            echo "[ERROR] invalid Verdi session id: $session_id" >&2
            return 1
            ;;
    esac

    remaining="$(session_live_pids "$session_id")"
    if [ -z "$remaining" ]; then
        return 0
    fi

    log_step "cleaning Verdi session sid=$session_id signal=TERM"
    signal_verdi_session "$session_id" TERM
    deadline=$((SECONDS + term_grace))
    while [ "$SECONDS" -lt "$deadline" ]; do
        remaining="$(session_live_pids "$session_id")"
        if [ -z "$remaining" ]; then
            return 0
        fi
        sleep 0.1
    done

    remaining="$(session_live_pids "$session_id" | tr '\n' ',')"
    log_step "cleaning Verdi session sid=$session_id signal=KILL remaining_pids=${remaining%,}"
    attempt=0
    while [ "$attempt" -lt 20 ]; do
        signal_verdi_session "$session_id" KILL
        sleep 0.1
        remaining="$(session_live_pids "$session_id")"
        if [ -z "$remaining" ]; then
            return 0
        fi
        attempt=$((attempt + 1))
    done

    echo "[ERROR] could not kill all processes in Verdi session $session_id" >&2
    return 1
}

cleanup_verdi_session_on_exit() {
    local exit_rc=$?
    local session_id

    trap - EXIT HUP INT TERM
    if [ -n "$VERDI_RUNNER_PID" ] && kill -0 "$VERDI_RUNNER_PID" 2>/dev/null; then
        kill -TERM "$VERDI_RUNNER_PID" 2>/dev/null || true
    fi
    if [ -s "$VERDI_SESSION_FILE" ]; then
        read -r session_id < "$VERDI_SESSION_FILE"
        log_step "exit cleanup for Verdi session sid=$session_id"
        cleanup_verdi_session "$session_id" 0 || true
    fi
    cleanup_kdebug_run_token 0 || true
    if [ -n "$VERDI_RUNNER_PID" ]; then
        kill -KILL "$VERDI_RUNNER_PID" 2>/dev/null || true
        wait "$VERDI_RUNNER_PID" 2>/dev/null || true
    fi
    if [ "$exit_rc" -ne 0 ]; then
        cleanup_failed_trace
    else
        rm -f -- "$VERDI_SESSION_FILE" "$VERDI_TIMEOUT_SENTINEL"
        cleanup_kdebug_tmpdir
    fi
    exit "$exit_rc"
}

trap cleanup_verdi_session_on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

log_step "script_dir=$SCRIPT_DIR"
log_step "backend=$BACKEND"
log_step "module=$MODULE"
log_step "load_mode=lib lib=$LIB"
if [ -n "$PORTS" ]; then
    log_step "port_filter=$PORTS"
fi
if [ -n "$PORTS_FILE" ]; then
    log_step "port_filter_file=$PORTS_FILE"
fi
if [ -z "$PORTS" ] && [ -z "$PORTS_FILE" ]; then
    log_step "port_filter=<all ports>"
fi
log_step "temp_full_trace=$TMPOUT"
log_step "kdebug_tmpdir=$KDEBUG_TMPDIR"
log_step "module_boundary_trace=$MODULE_OUT"
log_step "const_source_fallback=$CONST_SOURCE_FALLBACK"
log_step "const_trace_depth=$CONST_TRACE_DEPTH"
log_step "assign_trace_depth=$ASSIGN_TRACE_DEPTH"
log_step "assign_expr_trace_depth=$ASSIGN_EXPR_TRACE_DEPTH"
log_step "load_trace_node_limit=$LOAD_TRACE_NODE_LIMIT"
log_step "load_trace_edge_limit=$LOAD_TRACE_EDGE_LIMIT"
log_step "load_trace_api_list_limit=$LOAD_TRACE_API_LIST_LIMIT"
log_step "trace_max_rows=$TRACE_MAX_ROWS"
if [ -n "$LOAD_STOP_INSTANCE_FILE" ]; then
    log_step "load_stop_instance_file=$LOAD_STOP_INSTANCE_FILE"
else
    log_step "load_stop_instance_file=<none>"
fi
log_step "verdi_timeout_sec=$VERDI_TIMEOUT_SEC"
log_step "kdebug_timeout_cleanup_grace_sec=$KDEBUG_TIMEOUT_CLEANUP_GRACE_SEC"
log_step "trace_debug=$TRACE_DEBUG"
if [ -n "$SRCFILE" ]; then
    log_step "source_file=$SRCFILE"
else
    log_step "source_file=<none>"
fi
if [ -n "$KDEBUG_BIN" ]; then
    log_step "kdebug_bin=$KDEBUG_BIN"
else
    log_step "kdebug_bin=<auto>"
fi
log_step "python_bin=$PYTHON_BIN"

# Never leave a previous or partially-written module result looking current.
rm -f -- "$MODULE_OUT"

BACKEND_CMD=("$PYTHON_BIN" "$BACKEND" trace
    --module "$MODULE"
    --lib "$LIB"
    --full-out "$TMPOUT"
    "--module-out=$MODULE_OUT"
    --source-fallback "$CONST_SOURCE_FALLBACK"
    --max-parent-depth "$CONST_TRACE_DEPTH"
    --max-assign-depth "$ASSIGN_TRACE_DEPTH"
    --max-expr-depth "$ASSIGN_EXPR_TRACE_DEPTH"
    --max-nodes "$LOAD_TRACE_NODE_LIMIT"
    --max-edges "$LOAD_TRACE_EDGE_LIMIT"
    --max-api-results "$LOAD_TRACE_API_LIST_LIMIT"
    --max-rows "$TRACE_MAX_ROWS"
    --trace-debug "$TRACE_DEBUG")
if [ -n "$PORTS" ]; then
    BACKEND_CMD+=(--ports "$PORTS")
fi
if [ -n "$PORTS_FILE" ]; then
    BACKEND_CMD+=(--ports-file "$PORTS_FILE")
fi
if [ -n "$SRCFILE" ]; then
    BACKEND_CMD+=(--source "$SRCFILE")
fi
if [ -n "$LOAD_STOP_INSTANCE_FILE" ]; then
    BACKEND_CMD+=(--stop-instance-file "$LOAD_STOP_INSTANCE_FILE")
fi
if [ -n "$KDEBUG_BIN" ]; then
    BACKEND_CMD+=(--kdebug-bin "$KDEBUG_BIN")
fi
if [ "$VERDI_TIMEOUT_SEC" -gt 0 ]; then
    BACKEND_CMD+=(--timeout-sec "$VERDI_TIMEOUT_SEC")
fi

log_step "running kdebug JSON trace backend"
if [ "$VERDI_TIMEOUT_SEC" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    if ! command -v setsid >/dev/null 2>&1; then
        echo "[ERROR] setsid command is required when -verdi-timeout-sec is greater than 0" >&2
        cleanup_failed_trace
        exit 1
    fi
    OUTER_TIMEOUT_SEC=$((VERDI_TIMEOUT_SEC + KDEBUG_TIMEOUT_CLEANUP_GRACE_SEC))
    log_step "command: timeout --signal=USR1 --kill-after=5s ${OUTER_TIMEOUT_SEC}s <kdebug backend session wrapper>"
    timeout --signal=USR1 --kill-after=5s "${OUTER_TIMEOUT_SEC}s" \
        bash -c 'run_verdi_timeout_wrapper "$@"' \
        npi-timeout-wrapper "$VERDI_TIMEOUT_SENTINEL" "$VERDI_SESSION_FILE" \
        "${BACKEND_CMD[@]}" 1>&2 &
    VERDI_RUNNER_PID=$!
    wait "$VERDI_RUNNER_PID"
    verdi_observed_rc=$?
    VERDI_RUNNER_PID=""
elif [ "$VERDI_TIMEOUT_SEC" -gt 0 ]; then
    echo "[ERROR] timeout command is required when -verdi-timeout-sec is greater than 0" >&2
    cleanup_failed_trace
    exit 1
else
    log_step "command: $PYTHON_BIN $BACKEND trace --module $MODULE --lib $LIB ..."
    "${BACKEND_CMD[@]}" 1>&2 &
    VERDI_RUNNER_PID=$!
    wait "$VERDI_RUNNER_PID"
    verdi_observed_rc=$?
    VERDI_RUNNER_PID=""
fi

timeout_triggered=0
if [ -s "$VERDI_TIMEOUT_SENTINEL" ]; then
    timeout_triggered=1
fi
backend_timeout_triggered=0
if [ "$verdi_observed_rc" -eq 124 ]; then
    backend_timeout_triggered=1
fi

session_cleanup_rc=0
if [ "$VERDI_TIMEOUT_SEC" -gt 0 ]; then
    if [ ! -s "$VERDI_SESSION_FILE" ]; then
        echo "[ERROR] Verdi session id was not recorded" >&2
        session_cleanup_rc=1
    else
        read -r verdi_session_id < "$VERDI_SESSION_FILE"
        cleanup_verdi_session "$verdi_session_id" || session_cleanup_rc=$?
    fi
fi
token_cleanup_rc=0
cleanup_kdebug_run_token "$KDEBUG_TIMEOUT_CLEANUP_GRACE_SEC" || token_cleanup_rc=$?
rm -f -- "$VERDI_SESSION_FILE" "$VERDI_TIMEOUT_SENTINEL"

verdi_failure_rc="$verdi_observed_rc"
if [ "$session_cleanup_rc" -ne 0 ] && [ "$verdi_failure_rc" -eq 0 ]; then
    verdi_failure_rc="$session_cleanup_rc"
fi
if [ "$token_cleanup_rc" -ne 0 ] && [ "$verdi_failure_rc" -eq 0 ]; then
    verdi_failure_rc="$token_cleanup_rc"
fi

verdi_rc="$verdi_failure_rc"
if [ "$timeout_triggered" -eq 1 ] || [ "$backend_timeout_triggered" -eq 1 ]; then
    verdi_rc=124
elif [ "$verdi_failure_rc" -eq 124 ] || [ "$verdi_failure_rc" -eq 137 ]; then
    verdi_rc=125
fi
log_step "verdi_exit_code=$verdi_rc observed_exit_code=$verdi_failure_rc timeout_triggered=$timeout_triggered backend_timeout_triggered=$backend_timeout_triggered"
if [ "$verdi_rc" -ne 0 ]; then
    if [ "$timeout_triggered" -eq 1 ] || [ "$backend_timeout_triggered" -eq 1 ]; then
        echo "[ERROR] Verdi trace timed out after ${VERDI_TIMEOUT_SEC}s (rc=$verdi_rc)" >&2
    else
        echo "[ERROR] Verdi trace failed with exit code $verdi_failure_rc (reported_rc=$verdi_rc)" >&2
    fi
    cleanup_failed_trace
    exit "$verdi_rc"
fi

if [ ! -s "$TMPOUT" ]; then
    echo "[ERROR] no output generated" >&2
    cleanup_failed_trace
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
cat_rc=$?
if [ "$cat_rc" -ne 0 ]; then
    echo "[ERROR] failed to write full trace CSV to stdout (rc=$cat_rc)" >&2
    cleanup_failed_trace
    exit "$cat_rc"
fi
rm -f -- "$TMPOUT"
log_step "removed temp_full_trace=$TMPOUT"
