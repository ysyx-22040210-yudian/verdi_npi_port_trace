# Verdi NPI Port Trace

这个目录是一组基于 Verdi NPI L1 Tcl API 的端口反查工具。工具读取已经
elaborate 完成的 VCS/Verdi KDB，查找指定 `module` 的所有例化实例，并追踪这些
实例端口的 driver/load，最后输出 CSV 或反标到 XLSX。

当前工具只支持 KDB 输入：

```text
simv.daidir/kdb.elab++
```

不支持 filelist 导入。`-filelist`、`-top`、`-incdir` 只作为旧参数名保留，传入会报错。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `annotate_trace_xlsx.sh` | XLSX 反标主入口。 |
| `annotate_trace_xlsx.py` | XLSX 反标实现，依赖 Python 3.8+ 和 `openpyxl`。 |
| `trace_and_filter.sh` | CSV 主入口：trace、查找 keywords 实例、过滤 driver/load、输出 CSV。 |
| `npi_trace.sh` | 底层 trace 包装脚本，设置 `NPI_*` 环境变量并调用 Verdi batch。 |
| `npi_port_trace.tcl` | 核心 NPI trace 脚本，导入 KDB、查找目标 module 实例、追踪端口。 |
| `npi_find_instances.tcl` | 查找一个或多个 module 定义的所有例化实例。 |
| `find_instances_batched.py` | 分批搜索 `-keywords` 实例，降低大项目中单个 Verdi 进程资源峰值。 |
| `npi_find_module_params.tcl` | 采集目标 module 例化 parameter。 |
| `filter_trace.py` | CSV 过滤、合并、按目标实例拆分。 |
| `run_skidbuffer_param_test.sh` | 本目录内的 skidbuffer 参数反标回归脚本。 |
| `multi_module_trace_template.xlsx` | 多 module 测试模板，应保留在仓库中。 |

## 环境要求

在 Linux/VM 中运行，确保 VCS、Verdi 和 Python 环境可用：

```bash
export VCS_HOME=/home/synopsys/vcs-mx/O-2018.09-SP2
export VERDI_HOME=/home/synopsys/verdi/Verdi_O-2018.09-SP2
export VCS_TARGET_ARCH=linux64
export PATH="$VCS_HOME/bin:$VERDI_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$VCS_HOME/linux64/lib:$VERDI_HOME/share/PLI/VCS/LINUX64:${LD_LIBRARY_PATH:-}"
export LM_LICENSE_FILE=27000@IC_EDA
export SNPSLMD_LICENSE_FILE=27000@IC_EDA
export VERDI_LICENSE_FILE=27000@IC_EDA

python3 -V
python3 -m pip show openpyxl
which vcs
which verdi
```

如果 VM 使用 rh-python38：

```bash
set +u
source /opt/rh/rh-python38/enable >/dev/null 2>&1 || true
set -u
```

XLSX 反标需要：

```bash
python3 -m pip install openpyxl
chmod +x annotate_trace_xlsx.sh trace_and_filter.sh npi_trace.sh run_skidbuffer_param_test.sh
```

VCS 生成 KDB 时需要带 `-kdb`：

```bash
vcs -full64 -sverilog -lca -kdb -top top -f rtl.f \
  -Mdir=build/csrc \
  -o build/simv \
  -l build/vcs_build.log
```

## 重要概念

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

`-keywords` 是历史参数名，现在表示 **过滤 module 定义名列表**，不是文本关键字。
工具会先查找这些 module 的所有例化实例，然后判断目标端口方向相关的 trace 端点
是否属于这些实例。

方向规则：

| 目标端口方向 | 反标判断端点 |
| --- | --- |
| `input` | 看 driver |
| `output` | 看 loader |
| `inout` / unknown | driver 和 loader 都看 |

## XLSX 反标

### 基本命令

```bash
cd /mnt/hgfs/VMshare/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace

./annotate_trace_xlsx.sh \
  -template trace_template.xlsx \
  -output annotated.xlsx \
  -lib build/simv.daidir/kdb.elab++ \
  -keywords KeyModA,KeyModB \
  -module TargetModA,TargetModB \
  -ports clk,rst,we,waddr,wdata \
  --stream
```

如果 `-template` 文件不存在，并且命令中同时提供了 `-module` 和 `-ports`，工具会
自动生成一个最小模板。

输出表结构：

| 列 | 含义 |
| --- | --- |
| A 列 | module 定义名 |
| B 列 | 具体例化实例路径 |
| C 列 | 该实例的 elaborated parameter |
| D 列及之后 | 每个端口的反标结果 |

同一个 module 如果有多个例化实例，每个实例单独占一行。

### 反标结果含义

| 结果 | 含义 |
| --- | --- |
| `yes` | 方向相关端点连接到 `-keywords` 对应 module 的实例。 |
| `no` | 未连接到 `-keywords` 实例。 |
| `no; driver_actual=...` | input 的 driver 不是 keywords，也不是常数/悬空，同时列出实际 driver。 |
| `no; loader_actual=...` | output 的 loader 不是 keywords，也不是常数/悬空，同时列出实际 loader。 |
| `no; driver=Const:<value>` | input 的 driver 是固定常数。 |
| `no; driver=NO_DRIVER` | input 没有检测到 driver。 |
| `no; load=NO_LOAD` | output 没有检测到 loader。 |
| `PARAM_SKIPPED` | 使用 `--no-params` 跳过 parameter 采集。 |
| `PARAM_TRACE_FAILED: ...` | parameter 采集失败，但端口反标继续执行。 |
| `NO_SUBSYSTEM_INSTANCE` | 按 subsystem 拆分时，该 subsystem 下没有对应目标 module 实例。 |

### XLSX 参数

| 参数 | 必填 | 含义 |
| --- | --- | --- |
| `-template <xlsx>` | 是 | 输入模板。不存在时可结合 `-module` 和 `-ports` 自动生成。 |
| `-output <xlsx>` | 是 | 输出反标文件。使用 `-subsystem-level` 时会拆成多个 subsystem 文件。 |
| `-lib <kdb.elab++>` | 是 | VCS/Verdi KDB 路径。 |
| `-keywords <module[,module...]>` | 是 | 过滤 module 定义名列表，可传多个。 |
| `-module <module[,module...]>` | 否 | 目标 module 定义名列表；不传时从模板 A 列读取。 |
| `-ports <port[,port...]>` | 否 | 目标端口名列表；不传时从模板第 1 行端口列读取。 |
| `-sheet <name>` | 否 | 指定 worksheet，不传时使用第一个工作表。 |
| `-workdir <dir>` | 否 | 中间 CSV、实例列表、parameter CSV 目录；默认当前命令目录。 |
| `-subsystem-level <N>` | 否 | 按实例路径前 N 层拆分输出；默认 `0` 不拆分。 |
| `--stream` | 否 | 启用流式聚合和实例匹配缓存，大项目建议开启。 |
| `--match-cache-size <N>` | 否 | `--stream` 模式下 signal 归属判断缓存大小；默认 `200000`，`0` 关闭。 |
| `--keyword-batch-size <N>` | 否 | 每个 Verdi 进程搜索多少个 keyword module；默认 `8`，大项目可降为 `4/2/1`。 |
| `--keyword-continue-on-error` | 否 | 单个 keyword 搜索失败时跳过并继续；默认关闭，避免静默漏标。 |
| `--keyword-log-instances` | 否 | 打印每个 keyword 实例路径；默认关闭，大项目不建议打开。 |
| `--no-params` | 否 | 跳过 module parameter 采集。 |
| `--strict-params` | 否 | parameter 采集失败时直接中断。 |
| `-regcombo-as-keyword 0\|1` | 否 | 默认 `0`。设为 `1` 时，方向相关端点是 `RegCombo` 也反标 `yes`。 |
| `-const-source-fallback 0\|1` | 否 | 默认 `1`。控制是否读取 KDB 记录的源码路径，用源码解析补充识别父层 net tie。 |
| `-const-trace-depth <N>` | 否 | 默认 `16`。父模块 port 常数递归回溯最大层数；`0` 关闭递归回溯。 |
| `--keep-workdir` | 否 | 兼容参数；当前中间文件默认保留。 |
| `-filelist/-top/-incdir` | 禁用 | 当前强制使用 `-lib <kdb.elab++>`。 |

## CSV 过滤

```bash
./trace_and_filter.sh \
  -module TargetMod \
  -lib build/simv.daidir/kdb.elab++ \
  -keywords KeyModA,KeyModB \
  -ports clk,rst,we,waddr,wdata \
  -output target_from_keywords.csv \
  --keyword-batch-size 4 \
  -const-source-fallback 0 \
  -const-trace-depth 4
```

### CSV 参数

| 参数 | 必填 | 含义 |
| --- | --- | --- |
| `-module <module>` | 是 | 目标 module 定义名。 |
| `-lib <kdb.elab++>` | 是 | VCS/Verdi KDB 路径。 |
| `-keywords <module[,module...]>` | 是 | 过滤 module 定义名列表。 |
| `-output <csv>` | 否 | 最终过滤 CSV；默认 `<module>_filtered.csv`。 |
| `-ports <port[,port...]>` | 否 | 只追踪指定端口；不传则追踪所有端口。 |
| `--keyword-batch-size <N>` | 否 | 每个 Verdi 进程搜索多少个 keyword module。 |
| `--keyword-continue-on-error` | 否 | 单个 keyword 搜索失败时跳过并继续。 |
| `--keyword-log-instances` | 否 | 打印每个 keyword 实例路径。 |
| `-const-source-fallback 0\|1` | 否 | 默认 `1`，关闭后不做源码 fallback。 |
| `-const-trace-depth <N>` | 否 | 默认 `16`，`0` 关闭父 port 递归回溯。 |
| `-filelist/-top/-incdir` | 禁用 | 当前强制使用 KDB。 |

## 底层 trace

`npi_trace.sh` 通常由上层脚本调用，也可以单独调试：

```bash
./npi_trace.sh \
  -module TargetMod \
  -lib build/simv.daidir/kdb.elab++ \
  -ports clk,rst \
  -module-out target_module_connections.csv \
  -const-source-fallback 0 \
  -const-trace-depth 4 \
  > target_full.csv
```

参数：

| 参数 | 必填 | 含义 |
| --- | --- | --- |
| `-module <module>` | 是 | 目标 module 定义名。 |
| `-lib <kdb.elab++>` | 是 | VCS/Verdi KDB 路径。 |
| `-ports <port[,port...]>` | 否 | 只追踪指定端口。 |
| `-module-out <csv>` | 否 | module 边界 trace CSV。 |
| `-srcfile <src.v>` | 否 | 旧参数，已废弃。 |
| `-const-source-fallback 0\|1` | 否 | 默认 `1`。 |
| `-const-trace-depth <N>` | 否 | 默认 `16`。 |
| `-filelist/-top/-incdir` | 禁用 | 当前强制使用 KDB。 |

## 常数 driver 检测

常数 driver 在 CSV/XLSX 中显示为：

```text
Const:<value>
```

已支持三类常数检测：

1. 端口直接连接 literal：

```verilog
u_child(.a(1'b0));
```

2. 端口连接父层 net，父层 net 由源码 tie 到常数：

```verilog
wire tie0;
assign tie0 = 1'b0;
u_child(.a(tie0));
```

```verilog
wire tie1 = 1'b1;
u_child(.a(tie1));
```

这类依赖 `-const-source-fallback 1`。

3. 多层父模块 port 透传后在更上层 tie 常数：

```text
Child.a <- Parent0.p0 <- Parent1.p1 <- 1'b0
```

这类依赖 NPI high-side connection 递归，不依赖源码 fallback。递归深度由
`-const-trace-depth <N>` 控制，默认 16 层。

超大项目建议先这样跑：

```bash
-const-source-fallback 0 -const-trace-depth 4
```

如果需要识别父层 `assign net = 1'b0` 这种 tie，再打开：

```bash
-const-source-fallback 1
```

## 大项目建议

大项目中 `-keywords` 很多、RTL 规模很大时，建议：

```bash
./annotate_trace_xlsx.sh \
  -template trace_template.xlsx \
  -output annotated.xlsx \
  -lib build/simv.daidir/kdb.elab++ \
  -keywords KeyModA,KeyModB,KeyModC \
  -module TargetModA,TargetModB \
  -ports clk,rst,we,waddr,wdata \
  --stream \
  --keyword-batch-size 1 \
  -const-source-fallback 0 \
  -const-trace-depth 4
```

说明：

- `--stream`：Python 端边读 CSV 边聚合，降低运行期运存。
- `--keyword-batch-size 1`：每次只让 Verdi 搜索一个 keyword module，最稳但最慢。
- `-const-source-fallback 0`：避免读取和解析大源码文件。
- `-const-trace-depth 4`：限制父 port 回溯深度，避免无谓 NPI 查询。
- 默认关闭 `--keyword-log-instances`，减少大项目日志 IO。

## 按 subsystem 拆分 XLSX

如果同一个目标 module 分布在多个子系统，可以用 `-subsystem-level <N>` 按实例路径
前 N 层拆分输出，一个 subsystem 一个 XLSX。

例如实例路径：

```text
top.dut.subsys0.u_core.u_mod
```

设置：

```bash
-subsystem-level 3
```

subsystem key 为：

```text
top.dut.subsys0
```

输出文件名类似：

```text
annotated__subsys_top.dut.subsys0.xlsx
annotated__subsys_top.dut.subsys1.xlsx
```

## 直接 Tcl 调试

端口 trace：

```bash
export NPI_LIB=/path/to/simv.daidir/kdb.elab++
export NPI_MODULE=TargetMod
export NPI_PORTS=clk,rst,we
export NPI_OUTFILE=target_full.csv
export NPI_MODULE_OUTFILE=target_module_connections.csv
export NPI_CONST_SOURCE_FALLBACK=0
export NPI_CONST_TRACE_MAX_DEPTH=4

verdi -batch -nologo -play ./npi_port_trace.tcl 2>&1 | tee npi_port_trace_debug.log
```

查找 keywords 实例：

```bash
export NPI_LIB=/path/to/simv.daidir/kdb.elab++
export NPI_FILTER_MODULES=KeyModA,KeyModB
export NPI_INSTANCE_OUTFILE=keyword_instances.txt
export NPI_FIND_LOG_INSTANCES=0

verdi -batch -nologo -play ./npi_find_instances.tcl 2>&1 | tee npi_find_instances_debug.log
```

采集 parameter：

```bash
export NPI_LIB=/path/to/simv.daidir/kdb.elab++
export NPI_PARAM_MODULES=TargetModA,TargetModB
export NPI_PARAM_OUTFILE=module_parameters.csv

verdi -batch -nologo -play ./npi_find_module_params.tcl 2>&1 | tee npi_find_params_debug.log
```

## VM 回归测试命令

在 VM 的工具目录运行，生成文件都留在当前目录：

```bash
cd /mnt/hgfs/VMshare/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace

set +u
source /opt/rh/rh-python38/enable >/dev/null 2>&1 || true
set -u

export VCS_HOME=/home/synopsys/vcs-mx/O-2018.09-SP2
export VERDI_HOME=/home/synopsys/verdi/Verdi_O-2018.09-SP2
export VCS_TARGET_ARCH=linux64
export PATH="$VCS_HOME/bin:$VERDI_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$VCS_HOME/linux64/lib:$VERDI_HOME/share/PLI/VCS/LINUX64:${LD_LIBRARY_PATH:-}"
export LM_LICENSE_FILE=27000@IC_EDA
export SNPSLMD_LICENSE_FILE=27000@IC_EDA
export VERDI_LICENSE_FILE=27000@IC_EDA

bash -n annotate_trace_xlsx.sh trace_and_filter.sh npi_trace.sh
python3 -m py_compile annotate_trace_xlsx.py

./npi_trace.sh \
  -module skidbuffer \
  -lib "$(pwd)/skidbuffer_param_build/simv.daidir/kdb.elab++" \
  -ports i_clk \
  -module-out vm_const_switch_module.csv \
  -const-source-fallback 0 \
  -const-trace-depth 4 \
  > vm_const_switch_full.csv \
  2> vm_const_switch.log

./trace_and_filter.sh \
  -module skidbuffer \
  -lib "$(pwd)/skidbuffer_param_build/simv.daidir/kdb.elab++" \
  -keywords SkidPeer \
  -ports i_clk \
  -output vm_const_switch_filter.csv \
  --keyword-batch-size 1 \
  -const-source-fallback 0 \
  -const-trace-depth 3 \
  2>&1 | tee vm_const_switch_filter.log

./annotate_trace_xlsx.sh \
  -template vm_const_switch_template.xlsx \
  -output vm_const_switch_annotated.xlsx \
  -lib "$(pwd)/skidbuffer_param_build/simv.daidir/kdb.elab++" \
  -keywords SkidPeer,skidbuffer \
  -module skidbuffer,SkidPeer \
  -ports i_clk,i_reset,i_valid,o_ready,i_data,o_valid,i_ready,o_data,clk,rst,src_valid,src_ready,src_data,dst_valid,dst_ready,dst_data \
  -subsystem-level 2 \
  --stream \
  --no-params \
  --keyword-batch-size 1 \
  -const-source-fallback 0 \
  -const-trace-depth 4 \
  2>&1 | tee vm_const_switch_annotate.log
```

检查点：

```bash
grep -F "const_source_fallback=0" vm_const_switch.log
grep -F "const_trace_max_depth=4" vm_const_switch.log
test -s vm_const_switch_full.csv
test -s vm_const_switch_filter.csv
ls vm_const_switch_annotated__subsys_*.xlsx
```

## 生成文件

常见中间文件：

```text
<module>_full.csv
<module>_module_connections.csv
<keywords>_instances.txt
module_parameters.csv
<output>__subsys_<subsystem>.xlsx
```

默认情况下，中间文件写在当前命令目录。`-workdir <dir>` 只改变中间 CSV、实例列表
和 parameter CSV 的目录，不改变 `-output` 指定的输出路径。

## 清理测试产物

保留 KDB 时的轻量清理：

```bash
rm -rf __pycache__ verdiLog
rm -f novas.conf novas.rc
rm -f vm_const_switch*.csv vm_const_switch*.log vm_const_switch*.xlsx vm_const_switch_template.xlsx
rm -f *_debug.log *_trace_and_filter.log *_instances_errors.log
```

不要删除这些文件：

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
multi_module_trace_template.xlsx
README.md
```

## 常见问题

### `ERROR: KDB not found`

`-lib` 指向的 `kdb.elab++` 不存在。用 VCS 带 `-kdb` 重新编译。

### `ERROR: KDB path is empty`

目录存在但不是有效 KDB，通常是编译没有真正生成 KDB。

### Verdi 打印 `Please import design first!`

通常是 KDB 无效、为空，或者 KDB 与当前设计不匹配。

### 为什么主 CSV 中有 `Always/Combo/RegCombo/_ExprInst__`

这是 Verdi NPI trace 的内部节点。完整 trace 会穿过 module 边界，可能返回过程块、
表达式实例、组合逻辑节点或存储节点。需要看端口边界连接时，优先看
`*_module_connections.csv`。

### 为什么常数没有检测出来

先判断是哪种 tie：

- `.a(1'b0)`：NPI 通常能直接识别。
- 多层父 port 透传到 `.p(1'b0)`：需要 `-const-trace-depth` 足够大。
- `.a(parent_net)` 且 `assign parent_net = 1'b0`：需要 `-const-source-fallback 1`，并且 KDB 记录的源码路径在当前机器上可访问。

### 大项目跑得慢怎么办

先用：

```bash
--stream --keyword-batch-size 1 -const-source-fallback 0 -const-trace-depth 4
```

如果这样能稳定跑完，再逐步打开源码 fallback 或增大回溯深度。
