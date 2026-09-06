#!/bin/bash
# npi_trace.sh — run npi_port_trace.tcl via verdi -batch, output port driver/load CSV
#
# Usage:
#   ./npi_trace.sh -module <target_module> -lib <kdb.elab++> [-ports <port1,port2,...>]
#                  [-module-out <module_connections.csv>]
#                  [-const-source-fallback 0|1] [-const-trace-depth <N>]
#                  [-assign-trace-depth <N>] [-assign-expr-trace-depth <N>]
#                  [-load-trace-node-limit <N>] [-load-trace-edge-limit <N>]
#                  [-load-trace-api-list-limit <N>]
#                  [-load-stop-instance-file <instances.txt>]
#                  [-verdi-timeout-sec <N>]
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
VERDI_TIMEOUT_SEC="${NPI_VERDI_TIMEOUT_SEC:-0}"
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
        -verdi-timeout-sec|--verdi-timeout-sec) VERDI_TIMEOUT_SEC="$2"; shift 2 ;;
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
    echo "Usage: $0 -module <mod> -lib <kdb.elab++> [-srcfile <src.v>] [-ports <p1,p2,...>] [-module-out <csv>] [-const-source-fallback 0|1] [-const-trace-depth <N>] [-assign-trace-depth <N>] [-assign-expr-trace-depth <N>] [-load-trace-node-limit <N>] [-load-trace-edge-limit <N>] [-load-trace-api-list-limit <N>] [-verdi-timeout-sec <N>] [-trace-debug 0|1] [-log-file <run.log>]" >&2
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
case "$LOAD_TRACE_NODE_LIMIT" in
    ''|*[!0-9]*) echo "[ERROR] -load-trace-node-limit must be 0 or a positive integer, got: $LOAD_TRACE_NODE_LIMIT" >&2; exit 1 ;;
esac
case "$LOAD_TRACE_EDGE_LIMIT" in
    ''|*[!0-9]*) echo "[ERROR] -load-trace-edge-limit must be 0 or a positive integer, got: $LOAD_TRACE_EDGE_LIMIT" >&2; exit 1 ;;
esac
case "$LOAD_TRACE_API_LIST_LIMIT" in
    ''|*[!0-9]*) echo "[ERROR] -load-trace-api-list-limit must be 0 or a positive integer, got: $LOAD_TRACE_API_LIST_LIMIT" >&2; exit 1 ;;
esac
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

TMPOUT="$(mktemp "$PWD/npi_trace_out.XXXXXX.csv")"
STATUS_FILE="${TMPOUT}.status"
PORTS_TEMP="${TMPOUT}.ports"
VERDI_SESSION_FILE="$(mktemp "$PWD/npi_trace_session.XXXXXX")"
VERDI_TIMEOUT_SENTINEL="$(mktemp "$PWD/npi_trace_timeout.XXXXXX")"
VERDI_RUNNER_PID=""
if [ -z "$MODULE_OUT" ]; then
    MODULE_OUT="${MODULE}_module_connections.csv"
fi
MODULE_OUT="$("${PYTHON_BIN:-python3}" "$SCRIPT_DIR/runtime_paths.py" --path "$MODULE_OUT" --suffix .csv)" || exit 1
mkdir -p "$(dirname "$MODULE_OUT")"
TMPMODULEOUT="$(mktemp "$(dirname "$MODULE_OUT")/.trace_boundary.XXXXXX.csv")" || exit 1

cleanup_failed_trace() {
    rm -f "$TMPOUT" "$TMPMODULEOUT" "$MODULE_OUT" "$STATUS_FILE" "$PORTS_TEMP" "$VERDI_SESSION_FILE" "$VERDI_TIMEOUT_SENTINEL"
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
    if [ -n "$VERDI_RUNNER_PID" ]; then
        kill -KILL "$VERDI_RUNNER_PID" 2>/dev/null || true
        wait "$VERDI_RUNNER_PID" 2>/dev/null || true
    fi
    if [ "$exit_rc" -ne 0 ]; then
        cleanup_failed_trace
    else
        rm -f "$VERDI_SESSION_FILE" "$VERDI_TIMEOUT_SENTINEL"
    fi
    exit "$exit_rc"
}

trap cleanup_verdi_session_on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

log_step "script_dir=$SCRIPT_DIR"
log_step "tcl=$TCL"
log_step "module=$MODULE"
log_step "load_mode=lib lib=$LIB"
if [ -n "$PORTS_FILE" ]; then
    log_step "port_filter_file=$PORTS_FILE"
elif [ -n "$PORTS" ]; then
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
log_step "load_trace_node_limit=$LOAD_TRACE_NODE_LIMIT"
log_step "load_trace_edge_limit=$LOAD_TRACE_EDGE_LIMIT"
log_step "load_trace_api_list_limit=$LOAD_TRACE_API_LIST_LIMIT"
if [ -n "$LOAD_STOP_INSTANCE_FILE" ]; then
    log_step "load_stop_instance_file=$LOAD_STOP_INSTANCE_FILE"
else
    log_step "load_stop_instance_file=<none>"
fi
log_step "verdi_timeout_sec=$VERDI_TIMEOUT_SEC"
log_step "trace_debug=$TRACE_DEBUG"

# Never leave a previous or partially-written module result looking current.
rm -f "$MODULE_OUT"

export NPI_MODULE="$MODULE"
export NPI_SRCFILE="$SRCFILE"
if [ -n "$PORTS_FILE" ]; then
    [ -f "$PORTS_FILE" ] || { echo "[ERROR] ports file does not exist: $PORTS_FILE" >&2; exit 1; }
    case "$PORTS_FILE" in /*) ;; *) PORTS_FILE="$PWD/$PORTS_FILE" ;; esac
else
    printf '%s\n' "$PORTS" > "$PORTS_TEMP"
    PORTS_FILE="$PORTS_TEMP"
fi
export NPI_PORTS=""
export NPI_PORTS_FILE="$PORTS_FILE"
export NPI_LIB="$LIB"
export NPI_OUTFILE="$TMPOUT"
export NPI_MODULE_OUTFILE="$TMPMODULEOUT"
export NPI_STATUS_FILE="$STATUS_FILE"
export NPI_CONST_SOURCE_FALLBACK="$CONST_SOURCE_FALLBACK"
export NPI_CONST_TRACE_MAX_DEPTH="$CONST_TRACE_DEPTH"
export NPI_ASSIGN_TRACE_MAX_DEPTH="$ASSIGN_TRACE_DEPTH"
export NPI_ASSIGN_EXPR_TRACE_MAX_DEPTH="$ASSIGN_EXPR_TRACE_DEPTH"
export NPI_LOAD_TRACE_NODE_LIMIT="$LOAD_TRACE_NODE_LIMIT"
export NPI_LOAD_TRACE_EDGE_LIMIT="$LOAD_TRACE_EDGE_LIMIT"
export NPI_LOAD_TRACE_API_LIST_LIMIT="$LOAD_TRACE_API_LIST_LIMIT"
export NPI_LOAD_STOP_INSTANCE_FILE="$LOAD_STOP_INSTANCE_FILE"
export NPI_TRACE_DEBUG="$TRACE_DEBUG"

log_step "running Verdi batch trace"
if [ "$VERDI_TIMEOUT_SEC" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    if ! command -v setsid >/dev/null 2>&1; then
        echo "[ERROR] setsid command is required when -verdi-timeout-sec is greater than 0" >&2
        cleanup_failed_trace
        exit 1
    fi
    log_step "command: timeout --signal=USR1 --kill-after=5s ${VERDI_TIMEOUT_SEC}s <Verdi session wrapper>"
    timeout --signal=USR1 --kill-after=5s "${VERDI_TIMEOUT_SEC}s" \
        bash -c 'run_verdi_timeout_wrapper "$@"' \
        npi-timeout-wrapper "$VERDI_TIMEOUT_SENTINEL" "$VERDI_SESSION_FILE" \
        verdi -batch -nologo -play "$TCL" 1>&2 &
    VERDI_RUNNER_PID=$!
    wait "$VERDI_RUNNER_PID"
    verdi_observed_rc=$?
    VERDI_RUNNER_PID=""
elif [ "$VERDI_TIMEOUT_SEC" -gt 0 ]; then
    echo "[ERROR] timeout command is required when -verdi-timeout-sec is greater than 0" >&2
    cleanup_failed_trace
    exit 1
else
    log_step "command: verdi -batch -nologo -play $TCL"
    verdi -batch -nologo -play "$TCL" 1>&2
    verdi_observed_rc=$?
fi

timeout_triggered=0
if [ -s "$VERDI_TIMEOUT_SENTINEL" ]; then
    timeout_triggered=1
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
rm -f "$VERDI_SESSION_FILE" "$VERDI_TIMEOUT_SENTINEL"

verdi_failure_rc="$verdi_observed_rc"
if [ "$session_cleanup_rc" -ne 0 ] && [ "$verdi_failure_rc" -eq 0 ]; then
    verdi_failure_rc="$session_cleanup_rc"
fi

verdi_rc="$verdi_failure_rc"
if [ "$timeout_triggered" -eq 1 ]; then
    verdi_rc=124
elif [ "$verdi_failure_rc" -eq 124 ] || [ "$verdi_failure_rc" -eq 137 ]; then
    verdi_rc=125
fi
log_step "verdi_exit_code=$verdi_rc observed_exit_code=$verdi_failure_rc timeout_triggered=$timeout_triggered"
if [ "$verdi_rc" -ne 0 ]; then
    if [ "$timeout_triggered" -eq 1 ]; then
        echo "[ERROR] Verdi trace timed out after ${VERDI_TIMEOUT_SEC}s (rc=$verdi_rc)" >&2
    else
        echo "[ERROR] Verdi trace failed with exit code $verdi_failure_rc (reported_rc=$verdi_rc)" >&2
    fi
    cleanup_failed_trace
    exit "$verdi_rc"
fi

completion=""
if [ -s "$STATUS_FILE" ]; then read -r completion completed_instances < "$STATUS_FILE"; fi
if [ "$completion" != "COMPLETE" ]; then
    echo "[ERROR] TRACE_INCOMPLETE: Verdi exited without a trace completion record" >&2
    cleanup_failed_trace
    exit 1
fi
if [ ! -s "$TMPOUT" ] || [ ! -s "$TMPMODULEOUT" ]; then
    echo "[ERROR] no output generated" >&2
    cleanup_failed_trace
    exit 1
fi

mv -f "$TMPMODULEOUT" "$MODULE_OUT" || { cleanup_failed_trace; exit 1; }
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
rm -f "$TMPOUT" "$STATUS_FILE" "$PORTS_TEMP"
log_step "removed temp_full_trace=$TMPOUT"
