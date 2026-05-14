# Verdi NPI Port Trace

This tool uses Verdi NPI L1 Tcl APIs to trace driver/load relationships for
ports of all instances of a Verilog/SystemVerilog module from an elaborated
Verdi/VCS KDB.

The main entry point is `trace_and_filter.sh`. It runs a full trace, generates a
module-boundary trace, finds instances of a filter module, filters CSV rows,
merges the results, and optionally splits output per traced instance.

## Files

| File | Purpose |
| --- | --- |
| `trace_and_filter.sh` | Main flow. Runs trace, finds filter-module instances, filters, merges, and splits CSV output. |
| `npi_trace.sh` | Lower-level trace wrapper. Sets `NPI_*` environment variables and runs Verdi batch Tcl. |
| `npi_port_trace.tcl` | Core NPI trace implementation. Imports KDB/filelist, finds target-module instances, traces port drivers/loads, and writes CSV files. |
| `npi_find_instances.tcl` | Finds all instances of a module definition for the filter flow. |
| `filter_trace.py` | Filters CSV rows by instance ownership, merges CSV files, and splits by traced instance. |
| `npi_port_trace.cpp` | Older C++ implementation. The Tcl flow is the current recommended path. |
| `Makefile` | Build file for the older C++ implementation. |

## Environment

Run on Linux with Synopsys Verdi/VCS available:

```bash
echo "$VERDI_HOME"
which verdi
ls -la /tmp/npc_build/simv.daidir/kdb.elab++
```

If needed:

```bash
chmod +x npi_trace.sh trace_and_filter.sh
```

The recommended input is a VCS/Verdi generated KDB:

```text
simv.daidir/kdb.elab++
```

The VCS build should include `-kdb`, for example:

```make
-lca -kdb
```

For this project:

```bash
cd /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc
mkdir -p /tmp/npc_build
make -f Makefile all
```

## Important Conventions

`-module` is a module definition name, not an instance name. For:

```verilog
ysyx_22050058_pht ysyx_22050058_pht_u0 (...);
```

use:

```bash
-module ysyx_22050058_pht
```

not:

```bash
-module ysyx_22050058_pht_u0
```

The scripts use `npi_find_inst_with_def_wildcard` to find all instances whose
definition name matches the requested module.

## Full Flow

Example: trace `ysyx_22050058_pht` ports, and keep rows whose driver/load
endpoint belongs to an instance of `ysyx_22050058_gshare`:

```bash
cd /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace

./trace_and_filter.sh \
  -module ysyx_22050058_pht \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords ysyx_22050058_gshare \
  -output pht_from_gshare.csv
```

Generated files:

```text
ysyx_22050058_pht_full.csv
ysyx_22050058_pht_module_connections.csv
ysyx_22050058_pht_ysyx_22050058_gshare_instances.txt
pht_from_gshare_boundary.csv
pht_from_gshare_full_owner.csv
pht_from_gshare.csv
```

`-keywords` is a legacy option name. In `trace_and_filter.sh`, it now means one
filter module definition name. It is not a comma-separated text keyword list.

The flow is:

1. Trace every instance of `-module`.
2. Find every instance whose definition name is `-keywords`.
3. Filter module-boundary rows whose driver/load endpoint belongs to those
   filter instances.
4. Filter full-trace rows whose driver/load endpoint is owned by those filter
   instances.
5. Merge boundary and full-owner filtered rows.

Rows containing `_ExprInst__` are excluded from filtered output. Child-instance
internals such as:

```text
ysyx_22050058_gshare_u0.ysyx_22050058_pht_u0.ysyx_22050058_pht(@1)/...
```

are also excluded, because they belong to a child instance rather than the
filter module instance boundary.

## Optional Port Filter

Use `-ports` with comma-separated module port names:

```bash
./trace_and_filter.sh \
  -module ysyx_22050058_pht \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords ysyx_22050058_gshare \
  -ports clk,rst,we,waddr,wdata \
  -output pht_write_ports_from_gshare.csv
```

`-ports` values must be port names from the module definition, not connected net
names.

## CSV Outputs

Full trace CSV columns:

```csv
inst_full_name,port_name,role,signal_full_name
```

The full trace uses module pass-through and can include Verdi internal nodes:

```text
Always0
SigOp7
Combo
RegCombo
ComboMemory
_ExprInst__
```

Module-boundary CSV columns:

```csv
inst_full_name,port_name,role,module_signal_full_name
```

The module-boundary trace uses `passMod=0` and keeps readable module-boundary
endpoints. It filters common internal nodes and is usually better for quickly
checking which upper-level net or sibling module is connected to a port.

Constant drivers are preserved and printed as `Const:<value>`, for example:

```csv
...,CEN,driver,Const:'b1
```

## Logging

The runnable shell, Python, and Tcl files print step logs to `stderr`:

- `trace_and_filter.sh`: prints the five main stages.
- `npi_trace.sh`: prints trace parameters, output files, and line counts.
- `npi_port_trace.tcl`: prints design import, found target instances, port
  connections, and trace result counts.
- `npi_find_instances.tcl`: prints design import and matched filter instances.
- `filter_trace.py`: prints input/output files, headers, filter counts, merge
  counts, and split results.

Because logs go to `stderr`, CSV output remains clean:

```bash
./npi_trace.sh \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -module ysyx_22050058_pht \
  > pht_trace.csv \
  2> pht_trace_debug.log
```

For the full flow, save both normal messages and debug logs:

```bash
./trace_and_filter.sh \
  -module ysyx_22050058_pht \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords ysyx_22050058_gshare \
  -output pht_from_gshare.csv \
  2>&1 | tee trace_debug.log
```

## Direct Tcl Debug

The Tcl scripts read configuration from `NPI_*` environment variables. This is
useful when moving the tool to another machine and debugging Verdi/NPI directly,
without the shell wrappers.

Run `npi_port_trace.tcl` directly:

```bash
cd /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace

export NPI_LIB=/tmp/npc_build/simv.daidir/kdb.elab++
export NPI_MODULE=ysyx_22050058_pht
export NPI_PORTS=
export NPI_OUTFILE=pht_direct_full.csv
export NPI_MODULE_OUTFILE=pht_direct_module_connections.csv

verdi -batch -nologo -play ./npi_port_trace.tcl 2>&1 | tee pht_direct_tcl_debug.log
```

Check the outputs:

```bash
wc -l pht_direct_full.csv pht_direct_module_connections.csv
head -n 20 pht_direct_full.csv
head -n 20 pht_direct_module_connections.csv
```

Run `npi_find_instances.tcl` directly:

```bash
cd /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace

export NPI_LIB=/tmp/npc_build/simv.daidir/kdb.elab++
export NPI_FILTER_MODULE=ysyx_22050058_gshare
export NPI_INSTANCE_OUTFILE=gshare_instances_direct.txt

verdi -batch -nologo -play ./npi_find_instances.tcl 2>&1 | tee find_gshare_direct_debug.log
```

Check the instance list:

```bash
cat gshare_instances_direct.txt
```

When using KDB mode, `NPI_TOP` is not required because the elaborated top is
already stored in `kdb.elab++`. `NPI_TOP` is only needed in filelist mode:

```bash
export NPI_LIB=
export NPI_FILELIST=/path/to/filelist.f
export NPI_TOP=tb_top
export NPI_INCDIR=/path/to/include
```

## Per-Instance Split

If `-module` has multiple instances, `trace_and_filter.sh` also writes one CSV
per traced instance:

```text
<output_basename>__<inst_full_name>.csv
```

Example:

```bash
./trace_and_filter.sh \
  -module S013HD1P_X32Y2D128_BW \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords S013HD1P_X32Y2D128_BW \
  -output s013_from_self.csv
```

If 12 SRAM instances are found, 12 per-instance CSV files are generated.

## Validation Examples

Constant driver:

```bash
./npi_trace.sh \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -module S013HD1P_X32Y2D128_BW \
  -ports CEN \
  -module-out s013_cen_module.csv \
  > s013_cen.csv

grep -n 'Const:' s013_cen.csv
grep -n 'Const:' s013_cen_module.csv
```

Same-parent module connection:

```bash
./trace_and_filter.sh \
  -module ysyx_22050058_gshare \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords ysyx_22050058_btb \
  -output gshare_from_btb.csv
```

Expected rows include:

```csv
gshare_btbop_i,driver,...ysyx_22050058_btb_u0.btb_op_o[2:0]
gshare_btbhit_i,driver,...ysyx_22050058_btb_u0.btb_hit1_o
gshare_btbhit_i,driver,...ysyx_22050058_btb_u0.btb_hit2_o
```

## Cleanup

Generated files can be removed with:

```bash
rm -f *.csv *.err *.out *_instances.txt *_debug.log trace_debug*.log
rm -rf novas.conf novas.rc verdiLog __pycache__
```

Do not remove these tool files:

```text
filter_trace.py
Makefile
npi_find_instances.tcl
npi_port_trace.cpp
npi_port_trace.tcl
npi_trace.sh
README.md
trace_and_filter.sh
```

## Notes

- The recommended path is `-lib <kdb.elab++>`.
- `-filelist/-top` is still supported but is not the primary verified path for
  this project.
- CSV output is a textual representation of NPI trace results, not a canonical
  netlist database.
- Verdi internal node names may vary across versions.
- For complex expression port connections, inspect both the full trace and the
  module-boundary CSV.
