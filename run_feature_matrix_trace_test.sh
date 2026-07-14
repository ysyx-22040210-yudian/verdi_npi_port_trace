#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

csv_from_list() {
  grep -v '^[[:space:]]*$' "$1" | grep -v '^[[:space:]]*#' | paste -sd, -
}

MODULES="$(csv_from_list feature_matrix_modules.list)"
KEYWORDS="$(csv_from_list feature_matrix_keywords.list)"
PORTS="$(csv_from_list feature_matrix_ports.list)"

echo "[feature_matrix] cwd=$PWD"
echo "[feature_matrix] modules=$MODULES"
echo "[feature_matrix] keywords=$KEYWORDS"
echo "[feature_matrix] ports=$PORTS"

echo "[feature_matrix] clean previous outputs"
rm -rf feature_matrix_trace_build
rm -f feature_matrix_trace_vcs.log
rm -f feature_matrix_trace_template.xlsx feature_matrix_gui_command.log feature_matrix_gui_xlsx.log
rm -f feature_matrix_raw_full.csv feature_matrix_raw_module.csv feature_matrix_raw.log
rm -f feature_matrix_filtered.csv feature_matrix_filtered_boundary.csv feature_matrix_filtered_full_owner.csv
rm -f feature_matrix_filter.log feature_matrix_annotate.log
rm -f feature_matrix_annotated.xlsx feature_matrix_annotated__subsys_*.xlsx
rm -f FMTarget_full.csv FMTarget_module_connections.csv FMAuxTarget_full.csv FMAuxTarget_module_connections.csv
rm -f FMLeaf_full.csv FMLeaf_module_connections.csv FMKeySink_full.csv FMKeySink_module_connections.csv
rm -f FMTarget_FMKeySrc_FMKeySink_instances.txt module_parameters.csv

echo "[feature_matrix] create xlsx template"
python3 - <<'PY'
from pathlib import Path
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

modules = [
    line.strip()
    for line in Path("feature_matrix_modules.list").read_text().splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
ports = [
    line.strip()
    for line in Path("feature_matrix_ports.list").read_text().splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
wb = Workbook()
ws = wb.active
ws.title = "Trace"
headers = ["module", "instance", "parameters"] + ports
ws.append(headers)
for module in modules:
    ws.append([module])

header_fill = PatternFill("solid", fgColor="D9EAF7")
body_fill = PatternFill("solid", fgColor="FFFFFF")
thin = Side(style="thin", color="B7C7D9")
border = Border(left=thin, right=thin, top=thin, bottom=thin)
for row in ws.iter_rows(min_row=1, max_row=ws.max_row, max_col=ws.max_column):
    for cell in row:
        cell.border = border
        cell.alignment = Alignment(wrap_text=True, vertical="top")
        cell.fill = header_fill if cell.row == 1 else body_fill
        if cell.row == 1:
            cell.font = Font(bold=True)
for col_idx, header in enumerate(headers, start=1):
    ws.column_dimensions[get_column_letter(col_idx)].width = min(max(len(str(header)) + 4, 14), 42)
ws.freeze_panes = "A2"
wb.save("feature_matrix_trace_template.xlsx")
print("[feature_matrix] template=feature_matrix_trace_template.xlsx")
PY

echo "[feature_matrix] verify GUI command builder"
python3 trace_gui.py --build-command feature_matrix_gui_xlsx.json | tee feature_matrix_gui_command.log
grep -q "annotate_trace_xlsx.sh" feature_matrix_gui_command.log
grep -q "FMTarget,FMAuxTarget,FMLeaf" feature_matrix_gui_command.log
grep -q "FMKeySrc,FMKeySink" feature_matrix_gui_command.log
grep -q "drv_precise_bus\\[7\\]" feature_matrix_gui_command.log
grep -q -- "-regcombo-as-keyword 1" feature_matrix_gui_command.log
grep -q -- "-trace-debug 0" feature_matrix_gui_command.log
grep -q -- "-log-file feature_matrix_gui_xlsx.log" feature_matrix_gui_command.log

echo "[feature_matrix] build KDB"
mkdir -p feature_matrix_trace_build
set +e
vcs -full64 -sverilog -lca -kdb -top FeatureMatrixTop -f feature_matrix_trace_test.f \
  -Mdir=feature_matrix_trace_build/csrc \
  -o feature_matrix_trace_build/simv \
  -l feature_matrix_trace_vcs.log
vcs_rc=$?
set -e
if [ ! -d feature_matrix_trace_build/simv.daidir/kdb.elab++ ]; then
  echo "[feature_matrix] ERROR: KDB missing, vcs_rc=$vcs_rc" >&2
  tail -n 80 feature_matrix_trace_vcs.log >&2 || true
  exit "$vcs_rc"
fi
echo "[feature_matrix] KDB OK, vcs_rc=$vcs_rc"

echo "[feature_matrix] run Raw Trace with debug"
./npi_trace.sh \
  -module FMTarget \
  -lib "$(pwd)/feature_matrix_trace_build/simv.daidir/kdb.elab++" \
  -ports drv_cross_concat,load_plain \
  -module-out feature_matrix_raw_module.csv \
  -const-source-fallback 1 \
  -const-trace-depth 10 \
  -assign-trace-depth 18 \
  -assign-expr-trace-depth 12 \
  -trace-debug 1 \
  -log-file feature_matrix_raw.log \
  > feature_matrix_raw_full.csv

echo "[feature_matrix] run CSV filter"
./trace_and_filter.sh \
  -module FMTarget \
  -lib "$(pwd)/feature_matrix_trace_build/simv.daidir/kdb.elab++" \
  -keywords "$KEYWORDS" \
  -ports "$PORTS" \
  -output feature_matrix_filtered.csv \
  --keyword-batch-size 1 \
  --keyword-log-instances \
  -const-source-fallback 1 \
  -const-trace-depth 10 \
  -assign-trace-depth 18 \
  -assign-expr-trace-depth 12 \
  -trace-debug 0 \
  -log-file feature_matrix_filter.log

echo "[feature_matrix] run XLSX annotation"
./annotate_trace_xlsx.sh \
  -template feature_matrix_trace_template.xlsx \
  -output feature_matrix_annotated.xlsx \
  -lib feature_matrix_trace_build/simv.daidir/kdb.elab++ \
  -keywords "$KEYWORDS" \
  -module "$MODULES" \
  -ports "$PORTS" \
  -subsystem-level 2 \
  --stream \
  -regcombo-as-keyword 1 \
  -const-source-fallback 1 \
  -const-trace-depth 10 \
  -assign-trace-depth 18 \
  -assign-expr-trace-depth 12 \
  -trace-debug 0 \
  --match-cache-size 200000 \
  --keyword-batch-size 1 \
  --keyword-log-instances \
  -log-file feature_matrix_annotate.log

echo "[feature_matrix] assert results"
python3 - <<'PY'
import csv
from pathlib import Path
from openpyxl import load_workbook

filtered = Path("feature_matrix_filtered.csv").read_text()
for token in [
    "drv_precise_bus[7],input,driver",
    "drv_recursive[2],input,driver",
    "drv_plain,input,driver",
    "drv_assign_chain,input,driver",
    "drv_cross_concat,input,driver",
    "drv_module_port,input,driver",
    "load_bus[7],output,load",
    "load_bus[15],output,load",
    "load_plain,output,load",
    "load_module_port,output,load",
    "load_sibling_bus,output,load",
    "load_leaf_bus,output,load",
]:
    if token not in filtered:
        raise SystemExit(f"filtered CSV missing expected keyword path: {token}")

for token in [
    "drv_precise_bus[6],input",
    "drv_precise_bus[8],input",
    "drv_const_direct,input",
    "drv_const_parent,input",
    "drv_const_source,input",
    "drv_noise,input",
    "drv_float,input",
    "load_unconnected,output",
]:
    if token in filtered:
        raise SystemExit(f"filtered CSV unexpectedly matched keyword path: {token}")

rows = list(csv.DictReader(Path("FMTarget_full.csv").open()))

def port_role(port, role):
    return [r for r in rows if r["port_name"] == port and r["role"] == role]

def require_any(port, role, tokens):
    got = [r["signal_full_name"] for r in port_role(port, role)]
    for token in tokens:
        if any(token in sig for sig in got):
            return
    raise SystemExit(f"{port} {role} missing any of {tokens}; got={got[:20]}")

def reject_any(port, role, tokens):
    got = [r["signal_full_name"] for r in port_role(port, role)]
    for token in tokens:
        if any(token in sig for sig in got):
            raise SystemExit(f"{port} {role} polluted by {token}; got={got[:20]}")

require_any("drv_precise_bus[7]", "driver", ["u_key_precise.out[0]", "precise_c"])
reject_any("drv_precise_bus[7]", "driver", ["precise_b[", "precise_d[", "Const:7'b0101010", "Const:3'b101"])
require_any("drv_precise_bus[6]", "driver", ["precise_b[6]", "Const:7'b0101010"])
reject_any("drv_precise_bus[6]", "driver", ["u_key_precise", "precise_c"])
require_any("drv_precise_bus[8]", "driver", ["precise_d[0]", "Const:3'b101"])
reject_any("drv_precise_bus[8]", "driver", ["u_key_precise", "precise_c"])
require_any("drv_assign_chain", "driver", ["u_parent_key.u_key_nested.out", "assign_chain_c"])
require_any("drv_cross_concat", "driver", ["u_global_deep_provider.u_key_deep_h.out[2]", "cross_c[2]"])
reject_any("drv_cross_concat", "driver", ["lane_f_const", "lane_g_const", "lane_k_const"])
require_any("drv_module_port", "driver", ["u_driver_pass.o", "u_kw_module.out"])
for port in ["drv_const_direct", "drv_const_parent", "drv_const_source"]:
    require_any(port, "driver", ["Const:"])
require_any("drv_reg_endpoint", "driver", ["RegCombo", "u_reg_source.out"])
require_any("drv_float", "driver", ["drv_float"])

for port, tokens in {
    "load_sibling_bus": ["u_sib_p1.u_sink_lo.in", "u_sib_p1.u_sink_hi.in", "u_sib_p1.u_sink_alias.in"],
    "load_leaf_bus": ["u_leaf_load.leaf_in", "u_leaf_load.u_sink_direct.in"],
    "load_unconnected": ["load_unconnected"],
}.items():
    for token in tokens:
        require_any(port, "load", [token])

leaf_rows = list(csv.DictReader(Path("FMLeaf_full.csv").open()))
leaf_loads = [
    r["signal_full_name"]
    for r in leaf_rows
    if r["port_name"] == "leaf_in" and r["role"] == "load"
]
for token in [
    "u_sink_direct.in",
    "u_sink_alias.in",
    "u_sink_concat.in",
    "u_sink_lhs_hi.in",
    "u_sink_lhs_lo.in",
    "u_sink_param.in",
    "u_sink_port.in",
    "u_sink_gen2.in",
]:
    if not any(token in sig for sig in leaf_loads):
        raise SystemExit(f"FMLeaf leaf_in load trace missing {token}: {leaf_loads[:30]}")

for path in [
    Path("feature_matrix_filtered__FeatureMatrixTop.subsys0.u_shell1.u_shell0.u_target.csv"),
    Path("feature_matrix_filtered__FeatureMatrixTop.subsys1.u_shell1.u_shell0.u_target.csv"),
]:
    if not path.exists():
        raise SystemExit(f"missing per-instance split CSV: {path}")

books = sorted(Path(".").glob("feature_matrix_annotated__subsys_*.xlsx"))
if len(books) != 2:
    raise SystemExit(f"expected two subsystem workbooks, got {len(books)}: {books}")

checked_target = 0
checked_aux = 0
checked_leaf = 0
for book in books:
    wb = load_workbook(book, data_only=False)
    ws = wb.active
    headers = [cell.value for cell in ws[1]]
    for values in ws.iter_rows(min_row=2, values_only=True):
        data = dict(zip(headers, values))
        module = data.get("module")
        if module == "FMTarget":
            checked_target += 1
            for port in [
                "drv_precise_bus[7]",
                "drv_recursive[2]",
                "drv_plain",
                "drv_assign_chain",
                "drv_cross_concat",
                "drv_module_port",
                "load_bus[7]",
                "load_bus[15]",
                "load_plain",
                "load_module_port",
                "load_sibling_bus",
                "load_leaf_bus",
            ]:
                if not str(data.get(port, "")).startswith("yes"):
                    raise SystemExit(f"{book}: {data.get('instance')} {port} not yes: {data.get(port)}")
            for port in ["drv_precise_bus[6]", "drv_precise_bus[8]"]:
                cell = str(data.get(port, ""))
                if not cell.startswith("no") or "Const:" not in cell:
                    raise SystemExit(f"{book}: {port} should be no with const actual: {cell}")
            for port in ["drv_const_direct", "drv_const_parent", "drv_const_source"]:
                cell = str(data.get(port, ""))
                if not cell.startswith("no") or "Const:" not in cell:
                    raise SystemExit(f"{book}: {port} missing no Const result: {cell}")
            if "driver_actual=" not in str(data.get("drv_noise", "")):
                raise SystemExit(f"{book}: drv_noise missing actual driver: {data.get('drv_noise')}")
            if "driver_actual=" not in str(data.get("drv_float", "")):
                raise SystemExit(f"{book}: drv_float missing actual driver: {data.get('drv_float')}")
            if "loader_actual=" not in str(data.get("load_unconnected", "")):
                raise SystemExit(f"{book}: load_unconnected missing actual loader: {data.get('load_unconnected')}")
            params = str(data.get("parameters", ""))
            if "ID=" not in params or "DW=32'sd16" not in params or "TAG=" not in params:
                raise SystemExit(f"{book}: FMTarget parameters missing: {params}")
        elif module == "FMAuxTarget":
            checked_aux += 1
            if not str(data.get("aux_in", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_in not yes: {data.get('aux_in')}")
            if "NO_DRIVER" not in str(data.get("aux_float", "")):
                raise SystemExit(f"{book}: aux_float missing NO_DRIVER: {data.get('aux_float')}")
            if not str(data.get("aux_out", "")).startswith("yes"):
                raise SystemExit(f"{book}: aux_out not yes: {data.get('aux_out')}")
            if "NO_LOAD" not in str(data.get("aux_unused_out", "")):
                raise SystemExit(f"{book}: aux_unused_out missing NO_LOAD: {data.get('aux_unused_out')}")
            if "MODE=" not in str(data.get("parameters", "")):
                raise SystemExit(f"{book}: FMAuxTarget parameters missing: {data.get('parameters')}")
        elif module == "FMLeaf":
            checked_leaf += 1
            inst_name = str(data.get("instance", ""))
            if "u_leaf_direct" in inst_name:
                if not str(data.get("leaf_in", "")).startswith("yes"):
                    raise SystemExit(f"{book}: direct leaf_in not yes: {data.get('leaf_in')}")
            else:
                if "driver_actual=" not in str(data.get("leaf_in", "")):
                    raise SystemExit(f"{book}: load leaf_in missing actual driver: {data.get('leaf_in')}")
            if not str(data.get("leaf_out", "")).startswith("yes"):
                raise SystemExit(f"{book}: leaf_out not yes: {data.get('leaf_out')}")
            if "LEAF_ID=" not in str(data.get("parameters", "")):
                raise SystemExit(f"{book}: FMLeaf parameters missing: {data.get('parameters')}")
if checked_target != 2 or checked_aux != 2 or checked_leaf != 4:
    raise SystemExit(
        f"unexpected checked rows: target={checked_target} aux={checked_aux} leaf={checked_leaf}"
    )

for log_name in ["feature_matrix_raw.log"]:
    text = Path(log_name).read_text(errors="replace")
    required_paths = {
        "driver continuation": [
            "source_assign_direct_driver_source",
            "driver_module_port_high_continue",
            "bit_driver_npi_exact",
        ],
        "load continuation": [
            "source_assign_direct_load_fanout",
            "load_module_port_high_continue",
        ],
    }
    for label, markers in required_paths.items():
        if not any(marker in text for marker in markers):
            raise SystemExit(f"{log_name} missing {label} evidence; expected one of {markers}")

print("[feature_matrix] assertions passed")
PY

echo "[feature_matrix] SUCCESS"
