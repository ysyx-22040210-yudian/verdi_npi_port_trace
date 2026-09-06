#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${VM_STRESS_PROFILE:-full}"
RESULT_ROOT="${VM_STRESS_OUT:-$SCRIPT_DIR/vm_stress_matrix_$(date +%Y%m%d_%H%M%S)}"

if [ $# -gt 0 ]; then
  PROFILE="$1"
fi
case "$PROFILE" in
  full|synthetic|xiangshan) ;;
  *) echo "Usage: $0 [full|synthetic|xiangshan]" >&2; exit 2 ;;
esac

[ ! -e "$RESULT_ROOT" ] || { echo "output already exists: $RESULT_ROOT" >&2; exit 1; }
mkdir -p "$RESULT_ROOT"
RESULT_ROOT="$(cd "$RESULT_ROOT" && pwd)"
cd "$SCRIPT_DIR"

export VCS_HOME="${VCS_HOME:-/home/synopsys/vcs/O-2018.09-SP2}"
export VERDI_HOME="${VERDI_HOME:-/home/synopsys/verdi/Verdi_O-2018.09-SP2}"
export VCS_TARGET_ARCH="${VCS_TARGET_ARCH:-linux64}"
export RH_PYTHON38_ROOT="${RH_PYTHON38_ROOT:-/opt/rh/rh-python38/root/usr}"
export PATH="$RH_PYTHON38_ROOT/local/bin:$RH_PYTHON38_ROOT/bin:$VCS_HOME/bin:$VERDI_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$RH_PYTHON38_ROOT/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-27000@IC_EDA}"
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@IC_EDA}"
export VERDI_LICENSE_FILE="${VERDI_LICENSE_FILE:-27000@IC_EDA}"
export PYTHON_BIN="${PYTHON_BIN:-/opt/rh/rh-python38/root/usr/bin/python3}"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

run_case() {
  local name="$1"
  shift
  local case_dir="$RESULT_ROOT/$name"
  mkdir -p "$case_dir"
  echo "[vm_stress] case=$name start"
  local start end
  start="$(date +%s)"
  if "$@" > >(tee "$case_dir/stdout.log") 2> >(tee "$case_dir/stderr.log" >&2); then
    end="$(date +%s)"
    printf '%s\n' "$((end - start))" > "$case_dir/elapsed_seconds.txt"
    printf '%s\n' "$name" > "$case_dir/PASS"
    echo "[vm_stress] case=$name PASS elapsed_seconds=$((end - start))"
  else
    local rc=$?
    end="$(date +%s)"
    printf '%s\n' "$rc" > "$case_dir/rc.txt"
    printf '%s\n' "$((end - start))" > "$case_dir/elapsed_seconds.txt"
    echo "[vm_stress] case=$name FAIL rc=$rc" >&2
    return "$rc"
  fi
}

copy_case_artifacts() {
  local case_name="$1"
  shift
  local artifact_dir="$RESULT_ROOT/$case_name/artifacts"
  mkdir -p "$artifact_dir"
  local pattern path copied=0
  for pattern in "$@"; do
    while IFS= read -r -d '' path; do
      cp -p -- "$path" "$artifact_dir/"
      copied=$((copied + 1))
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -name "$pattern" -print0)
  done
  printf '%s\n' "$copied" > "$RESULT_ROOT/$case_name/artifact_count.txt"
  [ "$copied" -gt 0 ] || {
    echo "[vm_stress] ERROR: case=$case_name produced no selected artifacts" >&2
    return 1
  }
  echo "[vm_stress] case=$case_name copied_artifacts=$copied"
}

cleanup_case_build() {
  local name="$1"
  local path="$SCRIPT_DIR/$name"
  case "$path" in
    "$SCRIPT_DIR/"*_trace_build) rm -rf -- "$path" ;;
    *) echo "[vm_stress] ERROR: refused cleanup outside expected build path: $path" >&2; return 1 ;;
  esac
}

echo "[vm_stress] profile=$PROFILE"
echo "[vm_stress] result_root=$RESULT_ROOT"
df -h / | tee "$RESULT_ROOT/disk_before.txt"
free -h | tee "$RESULT_ROOT/memory_before.txt"

if [ "$PROFILE" = "full" ] || [ "$PROFILE" = "synthetic" ]; then
  run_case unit_tests "$PYTHON_BIN" -m unittest discover -p 'test_*.py'
  run_case tool_all_features bash "$SCRIPT_DIR/run_tool_all_features_trace_test.sh"
  copy_case_artifacts tool_all_features \
    'tool_all_features_*.csv' 'tool_all_features_*.xlsx' 'tool_all_features_*.log' \
    'TAFTarget_*.csv' 'TAFAuxTarget_*.csv' 'TAFLeaf_*.csv'
  cleanup_case_build tool_all_features_trace_build
  run_case scopefix_pressure bash "$SCRIPT_DIR/run_scopefix_pressure_trace_test.sh"
  copy_case_artifacts scopefix_pressure \
    'scopefix_pressure_*.csv' 'scopefix_pressure_*.log' 'SFPProbe_*.csv'
  cleanup_case_build scopefix_pressure_trace_build
  run_case loader_pressure bash "$SCRIPT_DIR/run_loader_pressure_trace_test.sh"
  copy_case_artifacts loader_pressure \
    'loader_pressure_*.csv' 'loader_pressure_*.log' 'LPLoadTarget_*.csv'
  cleanup_case_build loader_pressure_trace_build
fi

if [ "$PROFILE" = "full" ] || [ "$PROFILE" = "xiangshan" ]; then
  XIANGSHAN_STRESS_OUT="$RESULT_ROOT/xiangshan" \
    run_case xiangshan bash "$SCRIPT_DIR/run_xiangshan_stress_matrix.sh"
fi

sleep 2
if ps -eo comm= | grep -E '^(verdi|Novas|Xvfb|npi_port_trace)$' > "$RESULT_ROOT/eda_processes_after.txt"; then
  cat "$RESULT_ROOT/eda_processes_after.txt" >&2
  echo "[vm_stress] ERROR: EDA processes remained after the matrix" >&2
  exit 1
fi

"$PYTHON_BIN" - "$RESULT_ROOT" "$PROFILE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
profile = sys.argv[2]
passes = sorted(path.parent.relative_to(root).as_posix() for path in root.rglob("PASS"))
files = []
for path in sorted(root.rglob("*")):
    if not path.is_file() or path.name == "summary.json":
        continue
    if path.suffix.lower() not in {".csv", ".xlsx", ".log", ".txt"} and path.name != "PASS":
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    files.append({"path": path.relative_to(root).as_posix(), "bytes": path.stat().st_size, "sha256": digest})
summary = {"status": "PASS", "profile": profile, "passes": passes, "artifacts": files}
(root / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print("[vm_stress] summary passes={} artifacts={}".format(len(passes), len(files)))
PY

df -h / | tee "$RESULT_ROOT/disk_after.txt"
echo "[vm_stress] SUCCESS result_root=$RESULT_ROOT"
