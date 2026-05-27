# Verdi NPI Port Trace

这个目录提供一组基于 Verdi NPI L1 Tcl API 的端口反查工具，用于在已经
elaborate 完成的 Verdi/VCS KDB 中，查找某个 `module` 的所有例化实例，并
追踪这些实例端口的 driver/load 连接关系。

工具当前只支持读取 VCS/Verdi 生成的 `kdb.elab++`。不再支持 filelist 模式。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `trace_and_filter.sh` | CSV 主流程：追踪目标 module 端口，查找过滤 module 实例，过滤 driver/load，并输出 CSV。 |
| `npi_trace.sh` | 底层 trace 包装脚本，设置 `NPI_*` 环境变量并调用 Verdi batch Tcl。 |
| `npi_port_trace.tcl` | 核心 NPI trace 脚本，导入 KDB、查找目标 module 实例、追踪端口 driver/load。 |
| `npi_find_instances.tcl` | 查找某个 module 定义对应的所有例化实例。 |
| `filter_trace.py` | 对 trace CSV 做实例归属过滤、合并和按实例拆分。 |
| `find_instances_batched.py` | 对 `-keywords` module 做分批实例搜索，降低大项目中 Verdi/NPI 单进程资源峰值。 |
| `annotate_trace_xlsx.sh` | XLSX 反标入口脚本。 |
| `annotate_trace_xlsx.py` | XLSX 反标实现，要求 Python 3.8+ 和 `openpyxl`。 |
| `npi_find_module_params.tcl` | 读取目标 module 的例化 parameter，并输出到 `module_parameters.csv`。 |
| `run_skidbuffer_param_test.sh` | 在当前工具目录中重建并验证 parameter 反标测试。 |
| `npi_port_trace.cpp` | 旧 C++ 版本，当前推荐使用 Tcl 流程。 |
| `Makefile` | 旧 C++ 版本的构建文件。 |

## 环境要求

在带 Synopsys VCS/Verdi 的 Linux 环境中运行：

```bash
echo "$VERDI_HOME"
which vcs
which verdi
python3 -V
```

XLSX 反标还需要：

```bash
python3 -m pip install openpyxl
chmod +x trace_and_filter.sh npi_trace.sh annotate_trace_xlsx.sh run_skidbuffer_param_test.sh
```

输入必须是 VCS/Verdi KDB：

```text
simv.daidir/kdb.elab++
```

VCS 编译时需要带 `-kdb`，例如：

```bash
vcs -full64 -sverilog -lca -kdb -top top -f rtl.f \
  -Mdir=build/csrc \
  -o build/simv \
  -l build/vcs_build.log
```

## 重要约定

`-module` 填的是 **module 定义名**，不是例化名。

例如 RTL 中有：

```verilog
ysyx_22050058_pht ysyx_22050058_pht_u0 (...);
```

命令应写：

```bash
-module ysyx_22050058_pht
```

不要写：

```bash
-module ysyx_22050058_pht_u0
```

脚本内部通过 `npi_find_inst_with_def_wildcard` 查找所有匹配 module 定义名的实例。

`-keywords` 是历史参数名，现在含义是 **过滤 module 定义名列表**。它不是普通
文本关键字列表，也不是 CSV 里的字符串匹配项。可以传一个 module，也可以传逗号
分隔的多个 module：

```bash
-keywords ysyx_22050058_gshare,ysyx_22050058_btb
```

工具会查找 `-keywords` 指定的所有 module 实例，并判断目标端口的 driver/load
是否连接到这些实例中的任意一个。

## 命令参数说明

### `trace_and_filter.sh`

CSV 过滤主入口，适合生成和排查原始 trace CSV。

| 参数 | 必填 | 含义 |
| --- | --- | --- |
| `-module <module>` | 是 | 目标 module 定义名。工具会查找该 module 的所有例化实例，并追踪这些实例的端口。 |
| `-lib <kdb.elab++>` | 是 | VCS/Verdi 生成的 KDB 路径。可以传绝对路径，也可以传相对当前目录的路径。 |
| `-keywords <module[,module...]>` | 是 | 过滤 module 定义名列表。工具会保留 driver/load 属于这些 module 实例的记录。 |
| `-output <csv>` | 否 | 最终过滤 CSV 文件名。默认是 `<module>_filtered.csv`。 |
| `-ports <port[,port...]>` | 否 | 只追踪指定端口。端口名必须是 `-module` 指定 module 的端口名；不传则追踪所有端口。 |
| `--keyword-batch-size <N>` | 否 | 每个 Verdi 进程查找多少个 `-keywords` module。默认 `8`；`1` 最稳但最慢；`0` 表示一次查全部。 |
| `--keyword-continue-on-error` | 否 | 某个 keyword 在单 module 批次下仍失败时跳过它并继续。默认关闭，避免静默漏标。 |
| `--keyword-log-instances` | 否 | 打印每个找到的 keyword 实例路径。默认关闭，大项目建议保持关闭以减少日志 IO。 |
| `-filelist/-top/-incdir` | 禁用 | 兼容旧参数名，但当前工具强制使用 `-lib <kdb.elab++>`，传入这些参数会报错。 |

### `annotate_trace_xlsx.sh`

XLSX 反标主入口，适合直接生成反标表。

| 参数 | 必填 | 含义 |
| --- | --- | --- |
| `-template <xlsx>` | 是 | 输入模板。若文件不存在，并且同时传了 `-module` 和 `-ports`，工具会自动生成最小模板。 |
| `-output <xlsx>` | 是 | 输出反标文件。使用 `-subsystem-level` 时会自动拆成多个 `<output>__subsys_<subsystem>.xlsx`。输出表中同一个目标 module 的多个例化实例会各占一行。 |
| `-lib <kdb.elab++>` | 是 | VCS/Verdi 生成的 KDB 路径。必须是已经 elaborate 完成且非空的 KDB。 |
| `-keywords <module[,module...]>` | 是 | 过滤 module 定义名列表。端口方向相关的 trace 端点连接到这些实例中的任意一个时写 `yes`。`input` 看 driver，`output` 看 loader。 |
| `-module <module[,module...]>` | 否 | 目标 module 定义名列表。不传时从模板 A 列第 2 行开始读取。注意这里输入的是 module 定义名，输出时会展开成具体实例路径。 |
| `-ports <port[,port...]>` | 否 | 目标端口名列表。不传时从模板第 1 行 D 列开始读取；旧模板从 C 列开始也兼容。 |
| `-sheet <name>` | 否 | 指定工作表名。不传时使用第一个 worksheet。 |
| `-workdir <dir>` | 否 | 中间 CSV、实例列表、parameter CSV 的生成目录。默认是当前命令目录。 |
| `-subsystem-level <N>` | 否 | 按实例路径前 N 层拆分输出。例如 `top.dut.subsys.u_mod` 且 N=3 时，subsystem 是 `top.dut.subsys`。默认 `0`，不拆分。 |
| `--keep-workdir` | 否 | 兼容参数。当前中间文件默认保留，所以这个参数不改变行为。 |
| `--no-params` | 否 | 跳过 module parameter 采集，C 列写 `PARAM_SKIPPED`。大项目迁移时可先用它验证端口反标主流程。 |
| `--strict-params` | 否 | parameter 采集失败时直接中断。默认是非阻断，失败时 C 列写 `PARAM_TRACE_FAILED: ...`。 |
| `--stream` | 否 | 启用流式聚合反标和实例匹配缓存。大项目建议开启，降低 Python 运行期运存。 |
| `-regcombo-as-keyword 0\|1` | 否 | 默认 `0`。设为 `1` 时，如果方向相关的 driver/loader trace 端点是 `RegCombo` 节点，也按命中 `-keywords` 处理并反标 `yes`。`input` 只看 driver，`output` 只看 loader。 |
| `--match-cache-size <N>` | 否 | `--stream` 模式下缓存多少个 signal 归属判断结果。默认 `200000`；`0` 关闭缓存。 |
| `--keyword-batch-size <N>` | 否 | 每个 Verdi 进程查找多少个 `-keywords` module。默认 `8`；大项目崩溃时可降为 `4/2/1`。 |
| `--keyword-continue-on-error` | 否 | 某个 keyword 单独搜索仍失败时跳过并继续，同时生成 `*_instances_errors.log`。默认关闭。 |
| `--keyword-log-instances` | 否 | 打印每个找到的 keyword 实例路径。默认关闭。 |
| `-filelist/-top/-incdir` | 禁用 | 兼容旧参数名，但当前工具强制使用 `-lib <kdb.elab++>`，传入这些参数会报错。 |

### `find_instances_batched.py`

专门用于大项目调试 `-keywords` 实例搜索。`annotate_trace_xlsx.sh` 和
`trace_and_filter.sh` 内部也会调用它。

| 参数 | 必填 | 含义 |
| --- | --- | --- |
| `-lib <kdb.elab++>` | 是 | VCS/Verdi KDB 路径。 |
| `-keywords <module[,module...]>` | 是 | 要查找实例的 module 定义名列表。 |
| `-output <txt>` | 是 | 合并后的实例列表输出文件，每行一个实例路径。 |
| `--batch-size <N>` | 否 | 每个 Verdi 进程查找多少个 module。默认 `8`；`1` 最稳；`0` 一次查全部。 |
| `--continue-on-error` | 否 | 单个 module 搜索仍失败时跳过并继续，同时写 `<output>_errors.log`。默认关闭。 |
| `--log-instances` | 否 | 让 Tcl 打印每个实例路径。默认关闭。 |
| `--keep-batch-files` | 否 | 保留每批的临时实例文件，便于调试。默认执行完后删除。 |

### `npi_trace.sh`

底层端口 trace 包装脚本，通常由上层入口调用。

| 参数 | 必填 | 含义 |
| --- | --- | --- |
| `-module <module>` | 是 | 目标 module 定义名。 |
| `-lib <kdb.elab++>` | 是 | VCS/Verdi KDB 路径。 |
| `-ports <port[,port...]>` | 否 | 限制只追踪指定端口。不传则追踪所有端口。 |
| `-module-out <csv>` | 否 | module 边界 trace CSV 输出路径。默认 `<module>_module_connections.csv`。 |
| `-srcfile <src.v>` | 否 | 旧参数，已废弃。端口方向现在从 NPI API 获取。 |
| `-filelist/-top/-incdir` | 禁用 | 兼容旧参数名，但当前工具强制使用 `-lib <kdb.elab++>`。 |

## CSV 过滤流程

示例：追踪 `ysyx_22050058_pht` 的端口，并保留 driver/load 属于
`ysyx_22050058_gshare` 或 `ysyx_22050058_btb` 实例的记录：

```bash
cd /mnt/hgfs/VMshare/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace

./trace_and_filter.sh \
  -module ysyx_22050058_pht \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords ysyx_22050058_gshare,ysyx_22050058_btb \
  --keyword-batch-size 4 \
  -output pht_from_gshare_or_btb.csv
```

输出文件：

```text
ysyx_22050058_pht_full.csv
ysyx_22050058_pht_module_connections.csv
ysyx_22050058_pht_ysyx_22050058_gshare_ysyx_22050058_btb_instances.txt
pht_from_gshare_or_btb_boundary.csv
pht_from_gshare_or_btb_full_owner.csv
pht_from_gshare_or_btb.csv
```

如果只追踪部分端口，使用 `-ports`：

```bash
./trace_and_filter.sh \
  -module ysyx_22050058_pht \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords ysyx_22050058_gshare \
  -ports clk,rst,we,waddr,wdata \
  -output pht_write_ports_from_gshare.csv
```

`-ports` 必须是 module 定义里的端口名，不是连接到端口上的 net 名。

## XLSX 反标

`annotate_trace_xlsx.sh` 用 NPI trace 结果填写 Excel 模板。

模板布局：

- 输入模板中，A 列第 2 行开始可以填写目标 module 定义名，对应 `-module`。
- 第 1 行 D 列开始：端口名，对应 `-ports`；旧模板从 C 列开始写端口也兼容。
- 输出反标文件中，A 列显示 `module`，B 列显示 `instance`，每个目标 module 的每个具体例化实例单独占一行。
- 输出反标文件中，C 列显示同一行实例的 elaborated parameter。
- B 列实例和第 1 行 port 的交叉单元格写入该实例该端口的 `yes/no/常数/悬空` trace 结果。

如果 `-template` 指定的文件不存在，并且命令中已经传入 `-module` 和 `-ports`，
脚本会在当前目录自动生成一个最小模板。

单 module 示例：

```bash
./annotate_trace_xlsx.sh \
  -template trace_template.xlsx \
  -output trace_annotated.xlsx \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords ysyx_22050058_gshare \
  -module ysyx_22050058_pht \
  -ports clk,rst,we,waddr,wdata
```

多 module 示例：

```bash
./annotate_trace_xlsx.sh \
  -template trace_template.xlsx \
  -output trace_annotated.xlsx \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords ysyx_22050058_gshare \
  -module ysyx_22050058_pht,ysyx_22050058_btb \
  -ports clk,rst,we,waddr,wdata
```

### 大项目流式优化入口

大项目、`-keywords` 很多、过滤实例很多时，建议显式打开流式优化入口，并把
`-keywords` 实例搜索拆成小批次：

```bash
./annotate_trace_xlsx.sh \
  -template trace_template.xlsx \
  -output trace_annotated.xlsx \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords filter_mod0,filter_mod1,filter_mod2 \
  -module target_mod0,target_mod1 \
  -ports clk,rst,we,waddr,wdata \
  -subsystem-level 3 \
  --keyword-batch-size 4 \
  --stream
```

这里有两类优化：

- **`-keywords` 分批实例搜索**：默认每批 8 个 `-keywords` module。每批使用一个
  独立 Verdi 进程，进程退出后释放 KDB/NPI 运行状态，避免一个 Verdi 进程长时间
  查很多 module 后崩溃。如果某批失败，工具会自动继续拆成更小批次，直到单个
  module。
- **默认关闭逐实例日志**：大项目实例很多时，打印每个实例路径会拖慢运行并放大
  日志。现在默认只打印统计信息；需要逐实例调试时再打开。
- **`--stream` 流式聚合反标**：Python 端不再把 `full.csv` 和
  `module_connections.csv` 全部读成 `TraceRow` 列表，而是边读 CSV 边聚合每个
  `(module, subsystem, instance, port)` 的最终 yes/no/常数/悬空结果。
- **实例匹配缓存**：把 `-keywords` 找到的实例路径预处理成 prefix 集合，并缓存
  signal 是否属于过滤实例的判断结果，避免每行 trace 都遍历所有过滤实例。

如果实例搜索仍然崩溃，把批次继续调小。最稳但最慢的是一次只查一个 keyword：

```bash
--keyword-batch-size 1
```

如果某个 keyword 在单 module 批次下仍然导致 Verdi/NPI 崩溃，默认会报错停止，
避免静默漏标。只想先跑完整体流程时，可以临时跳过失败 keyword，并查看生成的
`*_instances_errors.log`：

```bash
--keyword-continue-on-error
```

逐实例日志默认关闭；只有定位“为什么少了某个实例”时才建议打开：

```bash
--keyword-log-instances
```

默认 cache 上限是 200000 个不同 signal。可以按机器运存调整：

```bash
--match-cache-size 500000
```

设置为 0 可以关闭 signal 判断结果缓存，但仍保留 prefix 匹配和流式聚合：

```bash
--stream --match-cache-size 0
```

注意：`--stream` 优化的是 Python 反标阶段的运存和过滤耗时；Verdi/NPI 导入
`kdb.elab++` 本身仍会占用项目规模对应的运存。

parameter 采集默认是非阻断的：如果 Verdi/NPI 在采集 parameter 时失败，端口
yes/no 反标仍会继续生成，C 列会写 `PARAM_TRACE_FAILED: ...`。迁移到新项目时，
如果只想先验证端口连接反标，可以临时跳过 parameter：

```bash
./annotate_trace_xlsx.sh \
  -template trace_template.xlsx \
  -output trace_annotated.xlsx \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords ysyx_22050058_gshare \
  -module ysyx_22050058_pht \
  -ports clk,rst,we,waddr,wdata \
  --no-params
```

如果希望 parameter 采集失败时直接中断整个流程，使用严格模式：

```bash
--strict-params
```

## 反标单元格含义

交叉单元格的常见取值：

- `yes`：该端口方向相关的 trace 端点连接到 `-keywords` module 的实例。`input` 端口只看 driver，`output` 端口只看 loader，`inout` 或方向未知时两边都看。
- `yes`：如果命令带 `-regcombo-as-keyword 1`，方向相关端点是 `RegCombo` 节点时也会写 `yes`。
- `no`：该端口方向相关的 trace 端点没有连接到任意 `-keywords` module 实例。
- `no; driver_actual=<signal>`：`input` 端口的 driver 不是 `-keywords` 实例，也不是常数/悬空，同时把实际 driver 写出。
- `no; loader_actual=<signal>`：`output` 端口的 loader 不是 `-keywords` 实例，也不是常数/悬空，同时把实际 loader 写出。
- `driver=Const:<value>` 或 `load=Const:<value>`：方向相关端点发现常数 tie。
- `driver=NO_DRIVER` 或 `load=NO_LOAD`：方向相关端点发现悬空。
- `no; NO_TRACE`：目标 module 中不存在该端口，或 NPI 未返回该端口 trace。
- `NO_MODULE`：当前 KDB 中找不到 `-module` 指定的 module 实例。
- `NO_SUBSYSTEM_INSTANCE`：按 subsystem 拆分时，该 subsystem 下没有这个 module 的实例。
- `PARAM_TRACE_FAILED: ...`：parameter 采集失败，但端口反标已继续完成。
- `PARAM_SKIPPED`：命令使用了 `--no-params`，跳过 parameter 采集。

## 例化 parameter 显示

反标文件 C 列显示的是 **module 实例的 elaborated parameter**，不是 module 定义
里的默认 parameter。

同一个 module 在同一个 subsystem 下可能例化多次，并且每个实例 parameter 可能
不同。工具会把这些实例展开成多行，每一行只显示当前实例自己的 parameter，例如：

```text
A2 = skidbuffer
B2 = top.subsys0.u_skid_a
C2 = OPT_LOWPOWER=1'd0, OPT_OUTREG=1'd1, DW=32'sd8
A3 = skidbuffer
B3 = top.subsys0.u_skid_b
C3 = OPT_LOWPOWER=1'd1, OPT_OUTREG=1'd0, DW=32'sd13
```

这样做是为了让同一个 module 的不同例化参数和端口 trace 结果一一对应。

大项目迁移时，如果 parameter 采集阶段在 `npi_find_module_params.tcl` 中失败，先用
`--no-params` 跑通主反标流程，再单独调试 parameter：

```bash
export NPI_LIB=/path/to/simv.daidir/kdb.elab++
export NPI_PARAM_MODULES=targetA,targetB
export NPI_PARAM_OUTFILE=module_parameters_debug.csv

verdi -batch -nologo -play ./npi_find_module_params.tcl \
  2>&1 | tee find_params_debug.log
```

## 按 subsystem 拆分反标文件

大项目中同一个目标 module 可能出现在多个子系统中。使用 `-subsystem-level <N>`
可以按实例路径的前 N 层拆分输出，一个 subsystem 一个 XLSX。

例如实例路径：

```text
top.dut.subsys0.u_core.u_mod
```

如果设置：

```bash
-subsystem-level 3
```

subsystem key 为：

```text
top.dut.subsys0
```

输出文件名会自动变成：

```text
trace_annotated__subsys_top.dut.subsys0.xlsx
trace_annotated__subsys_top.dut.subsys1.xlsx
```

## 已验证的 parameter 反标测试

测试 RTL 使用开源项目 [ZipCPU wb2axip skidbuffer](https://github.com/ZipCPU/wb2axip)
中的 `skidbuffer.v`，并在本地 wrapper 里构造两个 subsystem，每个 subsystem
下有不同 parameter 的 `skidbuffer` 和 `SkidPeer` 实例。

测试必须在工具目录中运行，所有生成文件都留在当前目录：

```bash
cd /mnt/hgfs/VMshare/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace
```

一键测试：

```bash
chmod +x run_skidbuffer_param_test.sh
./run_skidbuffer_param_test.sh 2>&1 | tee run_skidbuffer_param_test.log
```

成功标志：

```text
[run_skidbuffer_param_test] SUCCESS
```

这个脚本会重建 KDB、运行反标，并检查 XLSX 的 A/B/C 列是否分别包含 module、instance 和 parameter。

### SSH 全量回归

在 VM 上做全量回归时，可以从宿主机直接通过 SSH 运行。非交互 SSH 不会自动加载
EDA 环境，因此命令里显式 `source /home/ICer/.bashrc`：

```bash
ssh ICer@192.168.31.223 'bash -s' <<'EOF'
set -eo pipefail
source /home/ICer/.bashrc
set -u
cd /mnt/hgfs/VMshare/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace

{
  echo "[vm-full-test] cwd=$(pwd)"
  echo "[vm-full-test] python=$(python3 --version 2>&1)"
  echo "[vm-full-test] vcs=$(command -v vcs || true)"
  echo "[vm-full-test] verdi=$(command -v verdi || true)"

  chmod +x ./run_skidbuffer_param_test.sh ./annotate_trace_xlsx.sh

  echo "[vm-full-test] STEP 1: parameter annotation smoke test"
  ./run_skidbuffer_param_test.sh

  echo "[vm-full-test] STEP 2: multi module + multi keywords"
  ./annotate_trace_xlsx.sh \
    -template multi_kw_trace_template.xlsx \
    -output multi_kw_annotated.xlsx \
    -lib "$(pwd)/skidbuffer_param_build/simv.daidir/kdb.elab++" \
    -keywords SkidPeer,skidbuffer \
    -module skidbuffer,SkidPeer \
    -ports i_clk,i_reset,i_valid,o_ready,i_data,o_valid,i_ready,o_data,clk,rst,src_valid,src_ready,src_data,dst_valid,dst_ready,dst_data \
    -subsystem-level 2 \
    --keyword-batch-size 1 \
    --stream \
    2>&1 | tee multi_kw_annotate.log

  echo "[vm-full-test] STEP 3: --stream --no-params fallback"
  ./annotate_trace_xlsx.sh \
    -template no_params_trace_template.xlsx \
    -output no_params_annotated.xlsx \
    -lib "$(pwd)/skidbuffer_param_build/simv.daidir/kdb.elab++" \
    -keywords SkidPeer \
    -module skidbuffer \
    -ports i_clk,i_reset,i_valid,o_ready,i_data,o_valid,i_ready,o_data \
    -subsystem-level 2 \
    --no-params \
    --keyword-batch-size 1 \
    --stream \
    2>&1 | tee no_params.log

  echo "[vm-full-test] SUCCESS"
} 2>&1 | tee vm_full_regression.log
exit ${PIPESTATUS[0]}
EOF
```

这套回归覆盖三类路径：

- `run_skidbuffer_param_test.sh`：重建 KDB，并检查 A/B/C 列能显示 module、instance 和 elaborated parameter。
- `-module skidbuffer,SkidPeer` 和 `-keywords SkidPeer,skidbuffer`：验证多目标 module 和多过滤 module。
- `--keyword-batch-size 1`：验证 `-keywords` 分批实例搜索入口。
- `--stream`：验证流式聚合反标和实例匹配缓存入口。
- `--no-params`：验证 parameter 采集跳过时仍能完成端口 yes/no 反标，并在 C 列写 `PARAM_SKIPPED`。

### 手动测试：单 module

```bash
cd /mnt/hgfs/VMshare/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace

rm -rf skidbuffer_param_build
rm -f skidbuffer_param_rtl.f skidbuffer_param_vcs_build.log
rm -f skidbuffer_trace_template.xlsx skidbuffer_annotated*.xlsx
rm -f module_parameters.csv skidbuffer_full.csv skidbuffer_module_connections.csv SkidPeer_instances.txt

cat > skidbuffer_param_rtl.f <<'EOF'
/mnt/hgfs/VMshare/CPU_CORE/ysyx/skidbuffer_param_kdb_test/skidbuffer.v
/mnt/hgfs/VMshare/CPU_CORE/ysyx/skidbuffer_param_kdb_test/top_skidbuffer_subsystems.v
EOF

mkdir -p skidbuffer_param_build

vcs -full64 -sverilog -lca -kdb -top top -f skidbuffer_param_rtl.f \
  -Mdir=skidbuffer_param_build/csrc \
  -o skidbuffer_param_build/simv \
  -l skidbuffer_param_vcs_build.log || true

./annotate_trace_xlsx.sh \
  -template skidbuffer_trace_template.xlsx \
  -output skidbuffer_annotated.xlsx \
  -lib "$(pwd)/skidbuffer_param_build/simv.daidir/kdb.elab++" \
  -keywords SkidPeer \
  -module skidbuffer \
  -ports i_clk,i_reset,i_valid,o_ready,i_data,o_valid,i_ready,o_data \
  -subsystem-level 2 \
  2>&1 | tee skidbuffer_annotate_params.log
```

预期输出：

```text
skidbuffer_annotated__subsys_top.subsys0.xlsx
skidbuffer_annotated__subsys_top.subsys1.xlsx
module_parameters.csv
skidbuffer_full.csv
skidbuffer_module_connections.csv
SkidPeer_instances.txt
```

### 手动测试：多 module

先确保上一步已经生成：

```text
skidbuffer_param_build/simv.daidir/kdb.elab++
```

然后运行：

仓库中已包含 `multi_module_trace_template.xlsx`，测试时直接复用它，不要删除。

```bash
cd /mnt/hgfs/VMshare/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace

test -f multi_module_trace_template.xlsx
rm -f multi_module_annotated*.xlsx multi_module_annotate_params.log
rm -f module_parameters.csv skidbuffer_full.csv skidbuffer_module_connections.csv
rm -f SkidPeer_full.csv SkidPeer_module_connections.csv SkidPeer_instances.txt

./annotate_trace_xlsx.sh \
  -template multi_module_trace_template.xlsx \
  -output multi_module_annotated.xlsx \
  -lib "$(pwd)/skidbuffer_param_build/simv.daidir/kdb.elab++" \
  -keywords SkidPeer,skidbuffer \
  -module skidbuffer,SkidPeer \
  -ports i_clk,i_reset,i_valid,o_ready,i_data,o_valid,i_ready,o_data,clk,rst,src_valid,src_ready,src_data,dst_valid,dst_ready,dst_data \
  -subsystem-level 2 \
  2>&1 | tee multi_module_annotate_params.log
```

预期输出：

```text
multi_module_annotated__subsys_top.subsys0.xlsx
multi_module_annotated__subsys_top.subsys1.xlsx
module_parameters.csv
skidbuffer_full.csv
SkidPeer_full.csv
```

已在 VM 上验证，反标文件中：

```text
A1 = module
B1 = instance
C1 = parameters
A2 = skidbuffer
B2 = top.subsys0.u_skid_a
A3 = skidbuffer
B3 = top.subsys0.u_skid_b
A4 = SkidPeer
B4 = top.subsys0.u_peer_a
A5 = SkidPeer
B5 = top.subsys0.u_peer_b
```

每行 C 列是该实例自己的 parameter，例如：

```text
C2 = OPT_LOWPOWER=1'd0, OPT_OUTREG=1'd1, DW=32'sd8
C4 = DW=32'sd8, ID=32'sd9
```

这个测试同时验证了：

- `-module skidbuffer,SkidPeer` 支持多个目标 module。
- `-keywords SkidPeer,skidbuffer` 支持多个过滤 module。
- 同一个目标 module 的多个例化实例会在 XLSX 中分成多行。
- 任意一个过滤 module 的实例连接到目标端口时，交叉单元格都会写 `yes`。

## 直接 Tcl 调试

这些 Tcl 脚本都通过环境变量读取参数，便于单独调试。

直接运行端口 trace：

```bash
cd /mnt/hgfs/VMshare/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace

export NPI_LIB=/tmp/npc_build/simv.daidir/kdb.elab++
export NPI_MODULE=ysyx_22050058_pht
export NPI_PORTS=clk,rst,we,waddr,wdata
export NPI_OUTFILE=pht_direct_full.csv
export NPI_MODULE_OUTFILE=pht_direct_module_connections.csv

verdi -batch -nologo -play ./npi_port_trace.tcl 2>&1 | tee pht_direct_tcl_debug.log
```

直接查找过滤 module 实例：

```bash
export NPI_LIB=/tmp/npc_build/simv.daidir/kdb.elab++
export NPI_FILTER_MODULES=ysyx_22050058_gshare,ysyx_22050058_btb
export NPI_INSTANCE_OUTFILE=gshare_instances_direct.txt
export NPI_FIND_LOG_INSTANCES=0

verdi -batch -nologo -play ./npi_find_instances.tcl 2>&1 | tee find_gshare_direct_debug.log
```

大项目建议优先用分批 Python 入口调试，它会在 Verdi 崩溃时自动拆小批次：

```bash
python3 ./find_instances_batched.py \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords ysyx_22050058_gshare,ysyx_22050058_btb \
  -output gshare_instances_direct.txt \
  --batch-size 1 \
  2>&1 | tee find_gshare_batched_debug.log
```

直接导出 module 实例 parameter：

```bash
export NPI_LIB=/tmp/npc_build/simv.daidir/kdb.elab++
export NPI_PARAM_MODULES=ysyx_22050058_pht,ysyx_22050058_btb
export NPI_PARAM_OUTFILE=module_parameters_direct.csv

verdi -batch -nologo -play ./npi_find_module_params.tcl 2>&1 | tee find_params_direct_debug.log
```

## CSV 文件说明

完整 trace CSV：

```csv
inst_full_name,port_name,role,signal_full_name
```

module 边界 trace CSV：

```csv
inst_full_name,port_name,role,module_signal_full_name
```

当前 CSV 会额外包含 `port_dir` 列，实际格式为：

```csv
inst_full_name,port_name,port_dir,role,signal_full_name
inst_full_name,port_name,port_dir,role,module_signal_full_name
```

完整 trace 会穿过 module 边界，可能出现 Verdi 内部节点，例如：

```text
Always0
SigOp7
Combo
RegCombo
ComboMemory
_ExprInst__
```

边界 trace 使用 `passMod=0`，更适合查看端口边界直接连接到了哪个上层 net 或
同级 module 端口。

常数 driver 会保留为：

```text
Const:<value>
```

例如：

```csv
...,CEN,driver,Const:'b1
```

## 生成文件位置

默认情况下，所有生成文件和中间文件都写在当前命令目录。

XLSX 流程常见生成文件：

```text
<module>_full.csv
<module>_module_connections.csv
<keywords>_instances.txt
module_parameters.csv
<output>__subsys_<subsystem>.xlsx
```

如果显式传入 `-workdir <dir>`，只有中间 CSV 和实例列表写入该目录；`-output`
仍按用户传入路径生成。

## 常见问题

### `ERROR: KDB not found`

说明 `-lib` 指向的 `kdb.elab++` 不存在。先用 VCS 带 `-kdb` 重新编译。

### `ERROR: KDB path is empty`

说明路径存在但目录为空，不是有效 KDB。需要重新生成 KDB。

### Verdi 打印 `Please import design first!`

通常是 KDB 无效、为空，或者 `debImport -elab` 没有真正导入设计。当前脚本已经
增加了 KDB 存在性和空目录检查。

### VCS 在共享目录中报 `ln ... Operation not supported`

VMware 共享目录可能不支持符号链接，VCS 链接 simv 阶段会失败。但如果日志中已经
出现：

```text
Verdi KDB elaboration done and the database successfully generated
```

并且 `kdb.elab++` 非空，则 NPI 反标可以继续使用这个 KDB。测试脚本已经处理了
这种情况。

### 为什么同一个 module 会显示多行？

因为输出表按具体例化实例反标。同一个 module 在同一个 subsystem 下可以有多个
实例，并且每个实例的 parameter 和端口 trace 都可能不同，所以工具会为每个实例
单独开一行，B 列和端口列都只对应这一行的实例。

### 为什么多 module 测试里没有 `SkidPeer`？

请确认打开的是：

```text
multi_module_annotated__subsys_top.subsys0.xlsx
multi_module_annotated__subsys_top.subsys1.xlsx
```

不是单 module 测试生成的：

```text
skidbuffer_annotated__subsys_top.subsys0.xlsx
skidbuffer_annotated__subsys_top.subsys1.xlsx
```

后者只包含 `skidbuffer`。

## 清理生成文件

清理当前目录中的测试产物：

```bash
rm -rf verdiLog skidbuffer_param_build __pycache__
rm -f novas.conf novas.rc
rm -f *_full.csv *_module_connections.csv *_instances.txt *_instances_errors.log module_parameters.csv
rm -f *_annotated*.xlsx *_trace_template.xlsx *_annotate*.log *_debug.log *_instances.log *_trace_and_filter.log
rm -f skidbuffer_param_rtl.f skidbuffer_param_vcs_build.log run_skidbuffer_param_test.log
rm -f vm_full_regression.log vm_stream_regression.log vm_keyword_batch_regression.log
```

不要删除这些工具文件：

```text
annotate_trace_xlsx.py
annotate_trace_xlsx.sh
filter_trace.py
find_instances_batched.py
npi_find_instances.tcl
npi_find_module_params.tcl
npi_port_trace.tcl
npi_trace.sh
trace_and_filter.sh
run_skidbuffer_param_test.sh
README.md
```

## 已知限制

- 只支持 `-lib <kdb.elab++>`，不支持 filelist 导入。
- CSV 是 NPI trace API 的文本化结果，不是规范化 netlist 数据库。
- Verdi 内部节点命名可能随版本变化。
- 复杂表达式连接建议同时查看完整 trace 和 module 边界 trace。
