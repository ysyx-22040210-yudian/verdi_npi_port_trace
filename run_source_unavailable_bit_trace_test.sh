#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="source_unavailable_bit_trace_build"
SOURCE_DIR="$BUILD_DIR/generated_src"
KDB_DIR="$BUILD_DIR/simv.daidir/kdb.elab++"

echo "[source_unavailable_bit] cwd=$PWD"
echo "[source_unavailable_bit] clean previous outputs"
rm -rf "$BUILD_DIR"
rm -f source_unavailable_bit_vcs.log source_unavailable_bit_trace.log
rm -f source_unavailable_bit_full.csv SourceUnavailableBitChild_module_connections.csv

echo "[source_unavailable_bit] copy RTL into disposable source directory"
mkdir -p "$SOURCE_DIR"
cp source_unavailable_bit_driver.v "$SOURCE_DIR/sub_driver_generated.v"
cp source_unavailable_bit_child.v "$SOURCE_DIR/sub_child_generated.v"
cp source_unavailable_bit_top.v "$SOURCE_DIR/sub_top_generated.v"
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

echo "[source_unavailable_bit] build KDB from copied RTL"
set +e
vcs -full64 -sverilog -lca -kdb -top SourceUnavailableBitTop \
  "$SOURCE_DIR/sub_driver_generated.v" \
  "$SOURCE_DIR/sub_child_generated.v" \
  "$SOURCE_DIR/sub_top_generated.v" \
  -Mdir="$BUILD_DIR/csrc" \
  -o "$BUILD_DIR/simv" \
  -l source_unavailable_bit_vcs.log
vcs_rc=$?
set -e
if [ ! -d "$KDB_DIR" ]; then
  echo "[source_unavailable_bit] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 100 source_unavailable_bit_vcs.log >&2 || true
  if [ "$vcs_rc" -eq 0 ]; then
    vcs_rc=1
  fi
  exit "$vcs_rc"
fi
echo "[source_unavailable_bit] KDB OK, vcs_rc=$vcs_rc"

echo "[source_unavailable_bit] remove all copied RTL before tracing"
rm -rf "$SOURCE_DIR"
if [ -e "$SOURCE_DIR" ]; then
  echo "[source_unavailable_bit] ERROR: disposable source directory still exists: $SOURCE_DIR" >&2
  exit 1
fi

echo "[source_unavailable_bit] trace selected bits from KDB only"
./npi_trace.sh \
  -module SourceUnavailableBitChild \
  -lib "$(pwd)/$KDB_DIR" \
  -ports 'A[7],A[6],B[0],B[1],C[7],C[6],D[0],D[1]' \
  -module-out SourceUnavailableBitChild_module_connections.csv \
  -const-source-fallback 0 \
  -const-trace-depth 8 \
  -assign-trace-depth 8 \
  -assign-expr-trace-depth 8 \
  -trace-debug 1 \
  -log-file source_unavailable_bit_trace.log \
  > source_unavailable_bit_full.csv

echo "[source_unavailable_bit] assert exact KDB-only bit drivers"
python3 - <<'PY'
import csv
import re
from pathlib import Path

rows = list(csv.DictReader(Path("source_unavailable_bit_full.csv").open()))


def drivers(port):
    return [
        row["signal_full_name"]
        for row in rows
        if row["port_name"] == port and row["role"] == "driver"
    ]


a7 = drivers("A[7]")
a6 = drivers("A[6]")
b0 = drivers("B[0]")
b1 = drivers("B[1]")

expected = {
    "A[7]": "SourceUnavailableBitTop.u_a7_driver.out",
    "A[6]": "SourceUnavailableBitTop.u_a6_driver.out",
    "B[0]": "SourceUnavailableBitTop.u_b0_driver.out",
    "B[1]": "SourceUnavailableBitTop.u_b1_driver.out",
}
actual = {"A[7]": a7, "A[6]": a6, "B[0]": b0, "B[1]": b1}

for port, endpoint in expected.items():
    values = actual[port]
    if endpoint not in values:
        raise SystemExit(f"{port} missing exact driver {endpoint}: {values}")
    sibling_prefixes = [
        sibling.rsplit(".", 1)[0] + "."
        for sibling in expected.values()
        if sibling != endpoint
    ]
    sibling_hits = [
        value
        for value in values
        if any(value.startswith(prefix) for prefix in sibling_prefixes)
    ]
    if sibling_hits:
        raise SystemExit(f"{port} leaked sibling-bit drivers {sibling_hits}: {values}")

CONST_BIT_RE = re.compile(r"^Const:(?:1'b([01xz])|'b([01xz])|'([01xz]))$", re.IGNORECASE)

for port, expected_bit in {
    "C[7]": "1",
    "C[6]": "0",
    "D[0]": "1",
    "D[1]": "0",
}.items():
    values = drivers(port)
    constants = [value for value in values if value.startswith("Const:")]
    parsed = []
    for value in constants:
        match = CONST_BIT_RE.fullmatch(value)
        if match is None:
            raise SystemExit(f"{port} contains a non-scalar constant: {values}")
        parsed.append(next(group.lower() for group in match.groups() if group is not None))
    if expected_bit not in parsed or any(bit != expected_bit for bit in parsed):
        raise SystemExit(f"{port} constant driver is not exactly Const:1'b{expected_bit}: {values}")

log_text = Path("source_unavailable_bit_trace.log").read_text(errors="replace")
evidence_lines = [
    line for line in log_text.splitlines()
    if "const_driver_source_detail " in line
]
for port, expected_bit in {
    "C[7]": "1",
    "C[6]": "0",
    "D[0]": "1",
    "D[1]": "0",
}.items():
    port_path = f"SourceUnavailableBitTop.u_child.{port}"
    value = f"Const:1'b{expected_bit}"
    matches = [
        line for line in evidence_lines
        if f"value={value}" in line
        and "role=driver" in line
        and f"port_path={port_path}" in line
        and "evidence_source=npi_trace" in line
        and "source_handle_kind=" in line
        and "source_handle_kind=<empty>" not in line
        and "source_handle_path=" in line
        and "source_handle_path=<empty>" not in line
        and "const_full_path=" in line
    ]
    if not matches:
        raise SystemExit(f"{port} missing KDB-only NPI constant evidence for {value}")
    full_paths = []
    for line in matches:
        match = re.search(r"const_full_path=(\{[^}]*\}|\S+)", line)
        if match is not None:
            full_paths.append(match.group(1).strip("{}"))
    if not any(path.startswith(f"{port_path}<-") and path.endswith(value) for path in full_paths):
        raise SystemExit(f"{port} missing full KDB target-to-constant path: {full_paths}")

if "bit_driver_source_restrict signal=" in log_text:
    raise SystemExit("trace unexpectedly used source-based bit restriction")
if "trace_port_bit" not in log_text:
    raise SystemExit("debug log missing selected-bit trace evidence")
for signal in [
    "SourceUnavailableBitTop.descending_bus[7]",
    "SourceUnavailableBitTop.descending_bus[6]",
    "SourceUnavailableBitTop.ascending_bus[0]",
    "SourceUnavailableBitTop.ascending_bus[1]",
    "SourceUnavailableBitTop.descending_literal[7]",
    "SourceUnavailableBitTop.descending_literal[6]",
    "SourceUnavailableBitTop.ascending_literal[0]",
    "SourceUnavailableBitTop.ascending_literal[1]",
]:
    token = f"bit_driver_npi_exact signal={signal} "
    if token not in log_text:
        raise SystemExit(f"debug log missing exact NPI bit trace evidence: {signal}")
for token in ["bit_driver_npi_fail_closed", "select_hdl_exact_unavailable"]:
    if token in log_text:
        raise SystemExit(f"exact NPI bit trace unexpectedly failed: {token}")

print("[source_unavailable_bit] assertions passed")
PY

echo "[source_unavailable_bit] SUCCESS"
