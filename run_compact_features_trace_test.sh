#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

csv_from_list() {
  grep -v '^[[:space:]]*$' "$1" | grep -v '^[[:space:]]*#' | paste -sd, -
}

MODULES="$(csv_from_list compact_features_modules.list)"
KEYWORDS="$(csv_from_list compact_features_keywords.list)"
PORTS="$(csv_from_list compact_features_ports.list)"

echo "[compact_features] cwd=$PWD"
echo "[compact_features] modules=$MODULES"
echo "[compact_features] keywords=$KEYWORDS"
echo "[compact_features] ports=$PORTS"

echo "[compact_features] verify one module per RTL file"
python3 - <<'PY'
from pathlib import Path
bad = []
for path in sorted(Path(".").glob("compact_features_*.v")):
    count = sum(1 for line in path.read_text().splitlines() if line.strip().startswith("module "))
    if count != 1:
        bad.append((path.name, count))
if bad:
    raise SystemExit(f"one-module-per-file check failed: {bad}")
print("[compact_features] one-module-per-file check passed")
PY

echo "[compact_features] clean previous outputs for this test only"
rm -rf compact_features_trace_build
rm -f compact_features_trace_vcs.log compact_features_trace_template.xlsx
rm -f compact_features_filtered.csv compact_features_filtered_boundary.csv compact_features_filtered_full_owner.csv
rm -f compact_features_filtered__*.csv compact_features_filter.log
rm -f compact_features_raw_full.csv compact_features_raw_module.csv compact_features_raw.log
rm -f compact_features_annotated.xlsx compact_features_annotated__subsys_*.xlsx compact_features_annotate.log
rm -f CFTarget_full.csv CFTarget_module_connections.csv CFAuxTarget_full.csv CFAuxTarget_module_connections.csv
rm -f CFTarget_CFKeySrc_CFKeySink_instances.txt CFAuxTarget_CFKeySrc_CFKeySink_instances.txt

echo "[compact_features] create xlsx template"
python3 - <<'PY'
from pathlib import Path
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

modules = [x.strip() for x in Path("compact_features_modules.list").read_text().splitlines() if x.strip()]
ports = [x.strip() for x in Path("compact_features_ports.list").read_text().splitlines() if x.strip()]
wb = Workbook()
ws = wb.active
ws.title = "Trace"
headers = ["module", "instance", "parameters"] + ports
ws.append(headers)
for module in modules:
    ws.append([module])
thin = Side(style="thin", color="B7C7D9")
for row in ws.iter_rows(min_row=1, max_row=ws.max_row, max_col=ws.max_column):
    for cell in row:
        cell.alignment = Alignment(wrap_text=True, vertical="top")
        cell.border = Border(left=thin, right=thin, top=thin, bottom=thin)
        if cell.row == 1:
            cell.font = Font(bold=True)
            cell.fill = PatternFill("solid", fgColor="D9EAF7")
for idx, header in enumerate(headers, 1):
    ws.column_dimensions[get_column_letter(idx)].width = min(max(len(str(header)) + 4, 14), 42)
ws.freeze_panes = "A2"
wb.save("compact_features_trace_template.xlsx")
PY

echo "[compact_features] build KDB"
mkdir -p compact_features_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top CFTop -f compact_features_trace_test.f \
  -Mdir=compact_features_trace_build/csrc \
  -o compact_features_trace_build/simv \
  -l compact_features_trace_vcs.log
vcs_rc=$?
set -e
if [ ! -d compact_features_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[compact_features] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 100 compact_features_trace_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[compact_features] KDB OK, vcs_rc=$vcs_rc"

echo "[compact_features] run focused raw trace for ternary stop evidence"
./npi_trace.sh \
  -module CFTarget \
  -lib "$(pwd)/compact_features_trace_build/simv.daidir/kdb.elab++" \
  -ports drv_ternary_stop,drv_bits[1],drv_bits[2],load_bus[2],load_port \
  -module-out compact_features_raw_module.csv \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 10 \
  -assign-expr-trace-depth 4 \
  -trace-debug 0 \
  -log-file compact_features_raw.log \
  > compact_features_raw_full.csv

echo "[compact_features] run CSV filter"
./trace_and_filter.sh \
  -module CFTarget \
  -lib "$(pwd)/compact_features_trace_build/simv.daidir/kdb.elab++" \
  -keywords "$KEYWORDS" \
  -ports "$PORTS" \
  -output compact_features_filtered.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 10 \
  -assign-expr-trace-depth 4 \
  -trace-debug 0 \
  -log-file compact_features_filter.log

echo "[compact_features] run XLSX annotation"
./annotate_trace_xlsx.sh \
  -template compact_features_trace_template.xlsx \
  -output compact_features_annotated.xlsx \
  -lib compact_features_trace_build/simv.daidir/kdb.elab++ \
  -keywords "$KEYWORDS" \
  -module "$MODULES" \
  -ports "$PORTS" \
  -subsystem-level 2 \
  --stream \
  -regcombo-as-keyword 1 \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 10 \
  -assign-expr-trace-depth 4 \
  -trace-debug 0 \
  --match-cache-size 100000 \
  --keyword-batch-size 1 \
  -log-file compact_features_annotate.log

echo "[compact_features] assert CSV and XLSX results"
python3 - <<'PY'
import csv
from pathlib import Path
from openpyxl import load_workbook

full_rows = list(csv.DictReader(Path("CFTarget_full.csv").open()))
filtered_rows = list(csv.DictReader(Path("compact_features_filtered.csv").open()))

def signals(port, role):
    return [r["signal_full_name"] for r in full_rows if r["port_name"] == port and r["role"] == role]

def has_full(port, role, token):
    return any(token in sig for sig in signals(port, role))

def has_filtered(port, role, token):
    return any(r["port_name"] == port and r["role"] == role and token in r["signal_full_name"] for r in filtered_rows)

def require_full(port, role, token):
    if not has_full(port, role, token):
        raise SystemExit(f"missing full {port} {role} {token}: {signals(port, role)[:80]}")

def reject_full(port, role, token):
    if has_full(port, role, token):
        raise SystemExit(f"unexpected full {port} {role} {token}: {signals(port, role)[:80]}")

def require_filtered(port, role, token):
    if not has_filtered(port, role, token):
        got = [r["signal_full_name"] for r in filtered_rows if r["port_name"] == port and r["role"] == role]
        raise SystemExit(f"missing filtered {port} {role} {token}: {got[:80]}")

def reject_filtered(port, role):
    got = [r["signal_full_name"] for r in filtered_rows if r["port_name"] == port and r["role"] == role]
    if got:
        raise SystemExit(f"unexpected filtered rows {port} {role}: {got[:80]}")

require_full("drv_bits[0]", "driver", "u_key_bits.out")
require_filtered("drv_bits[0]", "driver", "u_key_bits.out")
require_full("drv_bits[1]", "driver", "Const:1'b0")
reject_full("drv_bits[1]", "driver", "u_key_bits.out")
reject_filtered("drv_bits[1]", "driver")
require_full("drv_bits[2]", "driver", "u_key_bits.out")
require_filtered("drv_bits[2]", "driver", "u_key_bits.out")
require_full("drv_chain", "driver", "u_key_chain.out")
require_filtered("drv_chain", "driver", "u_key_chain.out")
require_full("drv_port", "driver", "u_key_port.out")
require_filtered("drv_port", "driver", "u_key_port.out")

require_full("drv_ternary_stop", "driver", "Combo")
reject_full("drv_ternary_stop", "driver", "u_key_ternary_cond")
reject_full("drv_ternary_stop", "driver", "u_ternary_noise")
reject_full("drv_ternary_stop", "driver", "Const:1'b1")
reject_filtered("drv_ternary_stop", "driver")

require_full("drv_const", "driver", "Const:")
reject_filtered("drv_const", "driver")
require_full("drv_reg", "driver", "u_reg_source")
reject_filtered("drv_reg", "driver")
require_full("drv_float", "driver", "drv_float")
reject_filtered("drv_float", "driver")
require_full("drv_noise", "driver", "u_noise")
reject_filtered("drv_noise", "driver")

require_full("load_bus[2]", "load", "u_sink_low.in")
require_filtered("load_bus[2]", "load", "u_sink_low.in")
require_full("load_bus[6]", "load", "u_sink_high.in")
require_filtered("load_bus[6]", "load", "u_sink_high.in")
require_full("load_bus[6]", "load", "u_sink_concat.in")
require_filtered("load_bus[6]", "load", "u_sink_concat.in")
require_full("load_port", "load", "u_sink_port.in")
require_filtered("load_port", "load", "u_sink_port.in")
require_full("load_reg", "load", "u_sink_reg.in")
require_filtered("load_reg", "load", "u_sink_reg.in")
require_full("load_no", "load", "u_nonkey_load.i")
reject_filtered("load_no", "load")

books = sorted(Path(".").glob("compact_features_annotated__subsys_*.xlsx"))
if len(books) != 2:
    raise SystemExit(f"expected two subsystem workbooks, got {books}")

target_rows = 0
aux_rows = 0
for book in books:
    wb = load_workbook(book, data_only=False)
    ws = wb.active
    headers = [c.value for c in ws[1]]
    for values in ws.iter_rows(min_row=2, values_only=True):
        row = dict(zip(headers, values))
        if row.get("module") == "CFTarget":
            target_rows += 1
            for port in ["drv_bits[0]", "drv_bits[2]", "drv_chain", "drv_port", "load_bus[2]", "load_bus[6]", "load_port", "load_reg"]:
                if not str(row.get(port, "")).startswith("yes"):
                    raise SystemExit(f"{book}: {port} not yes: {row.get(port)}")
            for port in ["drv_bits[1]", "drv_const"]:
                cell = str(row.get(port, ""))
                if not cell.startswith("no") or "Const:" not in cell:
                    raise SystemExit(f"{book}: {port} missing no Const detail: {cell}")
            ternary = str(row.get("drv_ternary_stop", ""))
            if not ternary.startswith("no") or "driver_actual=" not in ternary:
                raise SystemExit(f"{book}: drv_ternary_stop missing no actual detail: {ternary}")
            if "u_key_ternary_cond" in ternary or "u_ternary_noise" in ternary or "Const:1'b1" in ternary:
                raise SystemExit(f"{book}: drv_ternary_stop incorrectly chased operands: {ternary}")
            if "driver_actual=" not in str(row.get("drv_float", "")):
                raise SystemExit(f"{book}: drv_float missing actual floating shell driver: {row.get('drv_float')}")
            if "driver_actual=" not in str(row.get("drv_reg", "")):
                raise SystemExit(f"{book}: drv_reg missing actual reg driver: {row.get('drv_reg')}")
            if "loader_actual=" not in str(row.get("load_no", "")):
                raise SystemExit(f"{book}: load_no missing actual loader: {row.get('load_no')}")
            params = str(row.get("parameters", ""))
            if "ID=" not in params or "DW=32'sd8" not in params:
                raise SystemExit(f"{book}: target parameters missing: {params}")
        elif row.get("module") == "CFAuxTarget":
            aux_rows += 1
            if not str(row.get("aux_in", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_in not yes: {row.get('aux_in')}")
            if not str(row.get("aux_out", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_out not yes: {row.get('aux_out')}")
            if "NO_DRIVER" not in str(row.get("aux_float", "")):
                raise SystemExit(f"{book}: aux_float missing NO_DRIVER: {row.get('aux_float')}")
            if "NO_LOAD" not in str(row.get("aux_unused", "")):
                raise SystemExit(f"{book}: aux_unused missing NO_LOAD: {row.get('aux_unused')}")
            if "MODE=" not in str(row.get("parameters", "")):
                raise SystemExit(f"{book}: aux parameters missing: {row.get('parameters')}")

if target_rows != 2 or aux_rows != 2:
    raise SystemExit(f"unexpected xlsx row counts target={target_rows} aux={aux_rows}")

for path in [
    Path("compact_features_filtered__CFTop.subsys0.u_shell1.u_shell0.u_target.csv"),
    Path("compact_features_filtered__CFTop.subsys1.u_shell1.u_shell0.u_target.csv"),
]:
    if not path.exists():
        raise SystemExit(f"missing split CSV {path}")

print("[compact_features] assertions passed")
PY

echo "[compact_features] SUCCESS"
