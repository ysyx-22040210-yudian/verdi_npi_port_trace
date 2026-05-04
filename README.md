# Verdi NPI Port Trace

这个目录里的脚本用于基于 Verdi NPI 从已经 elaboration 的 KDB
(`kdb.elab++`) 中追踪某个 Verilog module 的端口 driver/load 关系。

当前推荐用法是只使用 Verdi/VCS 生成的 KDB：

```bash
./npi_trace.sh \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -module ysyx_22050058_pht \
  > pht_trace.csv
```

执行后会生成两个 CSV：

- 标准输出重定向得到的主 CSV，例如 `pht_trace.csv`
- 自动生成的 module 边界连接 CSV，例如 `ysyx_22050058_pht_module_connections.csv`

## 重要约定

`-module` 参数表示 **module 定义名**，不是 module 的实例名。

例如源码中：

```verilog
ysyx_22050058_pht ysyx_22050058_pht_u0 (
  ...
);
```

运行时应写：

```bash
-module ysyx_22050058_pht
```

不要写：

```bash
-module ysyx_22050058_pht_u0
```

脚本内部使用 `npi_find_inst_with_def_wildcard "" $target_mod hdlList`
按 module 定义名查找实例。如果一个 module 被例化多次，脚本会处理这个
module 的所有实例。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `npi_trace.sh` | 推荐入口脚本，设置环境变量并以 batch 方式启动 Verdi |
| `npi_port_trace.tcl` | 核心 Tcl 脚本，调用 Verdi NPI API 完成实例查找、端口获取、driver/load trace |
| `trace_and_filter.sh` | 在生成完整 trace 后按关键字过滤 |
| `filter_trace.py` | CSV 关键字过滤脚本 |
| `npi_port_trace.cpp` | 早期 C++ 版本，当前建议以 Tcl 版本为准 |
| `Makefile` | C++ 版本构建文件 |
| `README.md` | 本说明文档 |

## 环境要求

需要在有 Synopsys VCS/Verdi 环境的 Linux 环境中运行。

必须满足：

- `VERDI_HOME` 已正确设置
- `verdi` 命令可直接执行
- 已存在 VCS/Verdi 生成的 KDB：`simv.daidir/kdb.elab++`
- 当前脚本有执行权限

检查方式：

```bash
echo "$VERDI_HOME"
which verdi
ls -ld /tmp/npc_build/simv.daidir/kdb.elab++
```

如果 `npi_trace.sh` 没有执行权限：

```bash
chmod +x npi_trace.sh trace_and_filter.sh
```

## 生成 KDB

在本项目中，KDB 由 `npc/Makefile` 里的 VCS 参数生成：

```make
-lca -kdb
```

重新编译生成 KDB：

```bash
cd /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc
mkdir -p /tmp/npc_build
make -f Makefile all
```

生成完成后，确认 KDB 存在且非空：

```bash
ls -la /tmp/npc_build/simv.daidir/kdb.elab++
```

注意：之前遇到过目录存在但内容为空的情况。`npi_trace.sh` 只检查主 CSV
是否生成，不会自动判断 KDB 内容是否完整；如果出现 `[ERROR] no output generated`，
需要优先确认 KDB 是否由带 `-kdb` 的 VCS 编译重新生成。

## 基本用法

进入工具目录：

```bash
cd /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace
```

追踪单实例 module，例如 `ysyx_22050058_pht`：

```bash
./npi_trace.sh \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -module ysyx_22050058_pht \
  > pht_trace.csv
```

这个命令会生成：

```text
pht_trace.csv
ysyx_22050058_pht_module_connections.csv
```

追踪多实例 module，例如 `S013HD1P_X32Y2D128_BW`：

```bash
./npi_trace.sh \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -module S013HD1P_X32Y2D128_BW \
  > s013_trace.csv
```

这个命令会生成：

```text
s013_trace.csv
S013HD1P_X32Y2D128_BW_module_connections.csv
```

## 只追踪指定端口

用 `-ports` 传逗号分隔的端口名：

```bash
./npi_trace.sh \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -module ysyx_22050058_pht \
  -ports clk,rst,we,waddr,wdata \
  > pht_write_ports.csv
```

`-ports` 里的名字必须是 module 端口定义中的端口名，不是连接到端口的 net 名。

## 指定 module 连接 CSV 文件名

默认 module 连接 CSV 文件名是：

```text
<module>_module_connections.csv
```

可以用 `-module-out` 指定：

```bash
./npi_trace.sh \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -module ysyx_22050058_pht \
  -module-out pht_module_only.csv \
  > pht_trace.csv
```

## 两个 CSV 的区别

### 主 CSV

主 CSV 由标准输出产生，通常通过 `>` 重定向保存。

列格式：

```csv
inst_full_name,port_name,role,signal_full_name
```

字段含义：

| 字段 | 含义 |
| --- | --- |
| `inst_full_name` | 当前 module 实例的完整层级路径 |
| `port_name` | 当前处理的端口名 |
| `role` | `driver` 或 `load` |
| `signal_full_name` | NPI trace 到的信号、表达式、always 块、组合逻辑或存储节点 |

主 CSV 使用 `npi_nl_trace_driver/load` 的 module pass-through 模式，会尽量往
driver/load 源头或负载方向继续追踪。因此主 CSV 中出现下面这类名字是正常的：

```text
Always0
SigOp7
Combo
RegCombo
ComboMemory
_ExprInst__
```

它适合用来分析完整信号来源和负载路径。

### Module 边界连接 CSV

module 边界连接 CSV 由脚本自动生成。

列格式：

```csv
inst_full_name,port_name,role,module_signal_full_name
```

它使用 `passMod=0` 追踪 module 边界端点，并额外过滤综合内部节点。

过滤掉的典型内部节点包括：

```text
Always
Initial
Init
SigOp
Combo
RegCombo
ComboMemory
_ExprInst__
(@
/
```

因此这个 CSV 更适合看“端口 driver/load 有没有连到其他 module 或层级 net”。

例如 `ysyx_22050058_pht` 的 module 连接 CSV 中会看到：

```csv
...,clk,driver,ysyx_22050058_gshare_u0.clk
...,clk,driver,ysyx_22050058_gshare_u0.ysyx_22050058_pht_u0.clk
...,we,driver,ysyx_22050058_gshare_u0.gshare_wepht_i
...,wdata,driver,ysyx_22050058_gshare_u0.gshare_fixpht_i[1:0]
```

## 代码流程

`npi_trace.sh` 的工作：

1. 解析 `-lib`、`-module`、`-ports`、`-module-out` 等参数。
2. 创建临时主输出文件。
3. 导出环境变量：
   - `NPI_LIB`
   - `NPI_MODULE`
   - `NPI_PORTS`
   - `NPI_OUTFILE`
   - `NPI_MODULE_OUTFILE`
4. 运行：

```bash
verdi -batch -nologo -play "$TCL"
```

5. 如果临时主输出文件非空，把它打印到 stdout。

`npi_port_trace.tcl` 的工作：

1. 加载 Verdi NPI L1 Tcl API。
2. 使用 `debImport -elab $env(NPI_LIB)` 导入 KDB。
3. 使用 `npi_find_inst_with_def_wildcard` 按 module 定义名查找所有实例。
4. 对每个实例：
   - 获取 IO/port handle。
   - 通过 NPI 获取端口方向。
   - 获取 high-side 和 low-side 连接。
   - input 端口：driver 从 high-side 追，load 从 low-side 追。
   - output 端口：driver 从 low-side 追，load 从 high-side 追。
   - inout/unknown 端口：两侧都追。
5. 输出主 CSV。
6. 同时输出 module 边界连接 CSV。

## 验证方法

### 验证单实例 module

```bash
cd /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace

rm -f pht_trace.csv ysyx_22050058_pht_module_connections.csv

./npi_trace.sh \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -module ysyx_22050058_pht \
  > pht_trace.csv

wc -l pht_trace.csv ysyx_22050058_pht_module_connections.csv
```

已验证结果：

```text
31 pht_trace.csv
21 ysyx_22050058_pht_module_connections.csv
```

其中 `pht_trace.csv` 有 30 条数据，module 连接 CSV 有 20 条数据。

检查 module 连接 CSV 是否混入内部节点：

```bash
grep -F -n \
  -e '/' \
  -e '(@' \
  -e '_ExprInst__' \
  -e 'Always' \
  -e 'SigOp' \
  -e 'Combo' \
  -e 'RegCombo' \
  -e 'ComboMemory' \
  ysyx_22050058_pht_module_connections.csv
```

期望没有输出。

### 验证多实例 module

`S013HD1P_X32Y2D128_BW` 在当前工程中被例化 12 次，适合验证
`-module` 是否按 module 定义名处理所有实例。

运行：

```bash
cd /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace

rm -f s013_trace.csv S013HD1P_X32Y2D128_BW_module_connections.csv

./npi_trace.sh \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -module S013HD1P_X32Y2D128_BW \
  > s013_trace.csv

wc -l s013_trace.csv S013HD1P_X32Y2D128_BW_module_connections.csv
```

已验证结果：

```text
1185 s013_trace.csv
345 S013HD1P_X32Y2D128_BW_module_connections.csv
```

统计主 CSV 中的实例数：

```bash
cut -d, -f1 s013_trace.csv | tail -n +2 | sort -u | wc -l
```

期望结果：

```text
12
```

统计 module 连接 CSV 中的实例数：

```bash
cut -d, -f1 S013HD1P_X32Y2D128_BW_module_connections.csv | tail -n +2 | sort -u | wc -l
```

期望结果：

```text
12
```

检查 module 连接 CSV 是否混入内部节点：

```bash
grep -F -n \
  -e '/' \
  -e '(@' \
  -e '_ExprInst__' \
  -e 'Always' \
  -e 'SigOp' \
  -e 'Combo' \
  -e 'RegCombo' \
  -e 'ComboMemory' \
  S013HD1P_X32Y2D128_BW_module_connections.csv
```

期望没有输出。

## 关键字过滤

如果需要从主 CSV 中筛选含特定关键字的行：

```bash
./trace_and_filter.sh \
  -module ysyx_22050058_pht \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords 'ComboMemory,RegCombo,_ExprInst__' \
  -output pht_internal_nodes.csv
```

这个脚本会生成：

```text
ysyx_22050058_pht_full.csv
pht_internal_nodes.csv
ysyx_22050058_pht_module_connections.csv
```

也可以直接过滤已有 CSV：

```bash
python3 filter_trace.py \
  pht_trace.csv \
  pht_internal_nodes.csv \
  ComboMemory RegCombo _ExprInst__
```

## 常见问题

### `[ERROR] VERDI_HOME is not set.`

说明没有加载 Verdi 环境。需要先 source 对应 EDA 环境脚本，或者手动设置：

```bash
export VERDI_HOME=/path/to/verdi
export PATH="$VERDI_HOME/bin:$PATH"
```

### `[ERROR] no output generated`

常见原因：

1. KDB 目录不存在或为空。
2. KDB 不是由当前 RTL 编译生成。
3. 编译 VCS 时没有加 `-kdb`。
4. `-module` 写成了实例名，而不是 module 定义名。
5. module 在当前 top 下没有被例化。

排查：

```bash
ls -la /tmp/npc_build/simv.daidir/kdb.elab++
grep -R "module <module_name>" /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc/vsrc
grep -R "<module_name> " /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc/vsrc
```

### `-module` 应该填什么？

填 `module` 声明里的名字。

例如：

```verilog
module ysyx_22050058_pht (...);
```

就填：

```bash
-module ysyx_22050058_pht
```

### 为什么主 CSV 里有 `Always/Combo/RegCombo`？

这是正常现象。主 CSV 是完整 trace，会穿过 module 边界和内部表达式，继续寻找真实
driver/load 端点。

如果只想看 module 边界连接，使用自动生成的：

```text
<module>_module_connections.csv
```

### 为什么 module 连接 CSV 有同一个端口的 driver 和 load？

NPI 在 `passMod=0` 模式下会把 module 端口本身也作为边界端点返回。例如：

```csv
...,clk,driver,parent.clk
...,clk,driver,parent.inst.CLK
...,clk,load,parent.inst.CLK
```

这表示 trace 在 module 端口边界停止。分析连接关系时，以 `inst_full_name`
和 `module_signal_full_name` 的层级关系判断端口连接方向。

### 为什么某些表达式连接只显示 module 端口，不显示表达式内部？

例如：

```verilog
.raddr1(hashgshare_pc1_i[2+:`ysyx_22050058_BHRLEN] ^ phtbhr)
```

表达式会在 KDB 中变成 `_ExprInst__` 或 `SigOp/Combo` 节点。主 CSV 会保留这些节点；
module 连接 CSV 会过滤它们，只保留 module 边界可读对象。

## 清理生成文件

清理 Verdi 运行临时文件：

```bash
rm -rf novas.conf novas.rc verdiLog
```

清理某次验证输出：

```bash
rm -f \
  pht_trace.csv \
  ysyx_22050058_pht_module_connections.csv \
  s013_trace.csv \
  S013HD1P_X32Y2D128_BW_module_connections.csv
```

不要删除下面这些工具文件：

```text
filter_trace.py
Makefile
npi_port_trace.cpp
npi_port_trace.tcl
npi_trace.sh
README.md
trace_and_filter.sh
```

## 已知限制

- 当前推荐路径是 `-lib <kdb.elab++>`。虽然脚本仍保留 `-filelist/-top`
  参数，但本项目调试和验证以 KDB 为准。
- CSV 不是严格语义化 netlist 数据库，只是 trace API 返回结果的文本化输出。
- module 连接 CSV 使用名称规则过滤内部综合节点；如果未来 Verdi 版本输出格式变化，
  可能需要同步调整 `is_module_boundary_signal`。
- 对复杂表达式端口，主 CSV 更完整，module 连接 CSV 更适合看边界，不适合反推出表达式内部逻辑。

