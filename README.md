# Verdi NPI Port Trace

这个目录提供一组基于 Verdi NPI 的端口连接追踪工具，用来在已经 elaboration 的设计中查询某个 Verilog/SystemVerilog `module` 的所有实例，并输出每个端口的 driver/load 关系。

当前主入口是 `trace_and_filter.sh`。它会自动完成完整 trace、module 边界 trace、过滤 module 实例查找、CSV 过滤、合并以及按被 trace 实例拆分输出。

```bash
./trace_and_filter.sh \
  -module ysyx_22050058_id \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords ysyx_22050058_regfile \
  -output id_regfile_filtered.csv
```

执行后通常会得到完整 trace、module 边界 trace、过滤结果和中间实例列表：

- `ysyx_22050058_id_full.csv`
- `ysyx_22050058_id_module_connections.csv`
- `ysyx_22050058_id_ysyx_22050058_regfile_instances.txt`
- `id_regfile_filtered_boundary.csv`
- `id_regfile_filtered_full_owner.csv`
- `id_regfile_filtered.csv`

## 适用场景

这个工具适合在 NPC/YSYX 工程里排查 RTL 端口连接问题，例如：

- 某个子模块端口的 driver 来自哪里。
- 某个 output 端口最终 load 到哪些信号或模块。
- 一个 module 被实例化多次时，每个实例的端口连接是否一致。
- 从完整 trace 中筛选出由某类子模块实例拥有的 driver/load 记录。

## 重要约定

`-module` 参数填写的是 **module 定义名**，不是实例名。

例如 RTL 中有：

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

脚本内部通过 `npi_find_inst_with_def_wildcard "" $target_mod hdlList` 按 module 定义名查找实例。如果同一个 module 在设计中被实例化多次，脚本会处理所有匹配实例。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `trace_and_filter.sh` | 主入口脚本。执行 trace，查找过滤 module 实例，过滤、合并并按 trace 实例拆分 CSV。 |
| `npi_trace.sh` | 底层 trace 脚本。设置环境变量并以 `verdi -batch` 方式运行 Tcl trace。 |
| `npi_port_trace.tcl` | 当前主实现。导入 KDB/filelist，查找目标 module 的实例，追踪端口 driver/load，并生成 CSV。 |
| `filter_trace.py` | CSV 过滤、合并和按 trace 实例拆分的辅助脚本。 |
| `npi_find_instances.tcl` | 查找某个 module 定义对应的所有实例路径，供过滤流程使用。 |
| `npi_port_trace.cpp` | 早期 C++ 版本，可通过 Makefile 构建；当前项目调试以 Tcl 版本为准。 |
| `Makefile` | C++ 版本构建文件。 |

## 环境要求

需要在带 Synopsys VCS/Verdi 的 Linux 环境中运行。至少需要：

- `VERDI_HOME` 已设置。
- `verdi` 命令在 `PATH` 中可直接执行。
- 存在 VCS/Verdi 生成的 elaboration 数据库，例如 `/tmp/npc_build/simv.daidir/kdb.elab++`。
- 脚本有执行权限。
- 使用过滤功能时需要 `python3`。

检查环境：

```bash
echo "$VERDI_HOME"
which verdi
ls -la /tmp/npc_build/simv.daidir/kdb.elab++
```

如果脚本没有执行权限：

```bash
chmod +x npi_trace.sh trace_and_filter.sh
```

## 生成 KDB

本工程推荐基于 VCS/Verdi 生成的 KDB 运行：

```text
simv.daidir/kdb.elab++
```

编译参数中需要包含：

```make
-lca -kdb
```

在 NPC 工程根目录重新编译：

```bash
cd /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc
mkdir -p /tmp/npc_build
make -f Makefile all
```

生成后确认 KDB 目录存在且非空：

```bash
ls -la /tmp/npc_build/simv.daidir/kdb.elab++
```

如果出现 `[ERROR] no output generated`，优先确认 KDB 是用当前 RTL、当前 top，并带 `-kdb` 重新生成的。仅有空目录并不能保证 NPI 可以导入设计。

## 基本用法

进入工具目录：

```bash
cd /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace
```

主流程：追踪一个 module 的端口，并筛选 driver/load 信号属于另一个 module 实例的记录。

```bash
./trace_and_filter.sh \
  -module ysyx_22050058_id \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords ysyx_22050058_regfile \
  -output id_regfile_filtered.csv
```

参数含义：

| 参数 | 含义 |
| --- | --- |
| `-module` | 被 trace 的目标 module 定义名。脚本会处理这个 module 的所有实例。 |
| `-lib` | VCS/Verdi 生成的 `kdb.elab++` 路径。 |
| `-keywords` | 过滤 module 定义名。脚本会查找该 module 的所有实例，并保留 driver/load 属于这些实例的记录。 |
| `-output` | 最终合并后的过滤结果 CSV。 |

这个命令会生成：

```text
ysyx_22050058_id_full.csv
ysyx_22050058_id_module_connections.csv
ysyx_22050058_id_ysyx_22050058_regfile_instances.txt
id_regfile_filtered_boundary.csv
id_regfile_filtered_full_owner.csv
id_regfile_filtered.csv
```

如果 `ysyx_22050058_id` 在当前设计中被实例化多次，最终输出还会按 `inst_full_name` 额外拆分：

```text
id_regfile_filtered__<inst_full_name>.csv
```

注意：`-keywords` 当前参数名保留为历史名称，但实际含义是 **单个 module 定义名**，不是逗号分隔关键字列表。

## 只追踪指定端口

使用 `-ports` 传入逗号分隔的端口名：

```bash
./trace_and_filter.sh \
  -module ysyx_22050058_id \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -keywords ysyx_22050058_regfile \
  -ports clk,rst,we,waddr,wdata \
  -output id_regfile_write_ports.csv
```

`-ports` 中的名字必须是 module 端口定义里的端口名，不是连接到端口上的 net 名。

## 底层 trace 调试

`trace_and_filter.sh` 内部会调用 `npi_trace.sh`，并固定生成：

```text
<module>_module_connections.csv
```

通常不需要直接调用 `npi_trace.sh`。如果只想看原始 trace，或需要调试 NPI 返回结果，可以直接运行底层脚本：

```bash
./npi_trace.sh \
  -lib /tmp/npc_build/simv.daidir/kdb.elab++ \
  -module ysyx_22050058_pht \
  > pht_trace.csv
```

这会输出主 CSV 到 stdout，并生成默认边界连接 CSV：

```text
ysyx_22050058_pht_module_connections.csv
```

直接调用底层脚本时，也可以通过 `-module-out` 指定边界连接 CSV 文件名。

## 两类 CSV 的区别

主 CSV 来自标准输出，列格式为：

```csv
inst_full_name,port_name,role,signal_full_name
```

| 字段 | 含义 |
| --- | --- |
| `inst_full_name` | 当前被追踪 module 实例的完整层次路径。 |
| `port_name` | 当前端口名。 |
| `role` | `driver` 或 `load`。 |
| `signal_full_name` | NPI trace 返回的信号、表达式、always 块、组合逻辑或存储节点。 |

主 CSV 使用 `passMod=1`，会尽量穿过 module 边界继续追踪真实 driver/load。因此看到下面这类节点是正常的：

```text
Always0
SigOp7
Combo
RegCombo
ComboMemory
_ExprInst__
```

module 边界连接 CSV 的列格式为：

```csv
inst_full_name,port_name,role,module_signal_full_name
```

它使用 `passMod=0`，trace 会停在 module 边界附近，并额外过滤内部综合节点。因此它更适合快速查看端口连接到了哪些上层 net 或其他 module 端口。

## 端口方向与 trace 规则

脚本通过 NPI API 获取端口方向。处理规则如下：

| 端口方向 | driver 从哪侧追踪 | load 从哪侧追踪 |
| --- | --- | --- |
| `input` | high-side，父层连接侧 | low-side，子模块内部侧 |
| `output` | low-side，子模块内部侧 | high-side，父层连接侧 |
| `inout` 或未知 | high-side 和 low-side 都追踪 | high-side 和 low-side 都追踪 |

主 CSV 和边界 CSV 都会去重。主 CSV 还会尽量过滤掉指向当前实例自身端口的重复记录。

## 手动过滤已有 CSV

通常使用 `trace_and_filter.sh` 即可。若已经有 trace CSV 和实例列表，也可以直接调用 Python 脚本处理：

```bash
python3 filter_trace.py \
  ysyx_22050058_id_module_connections.csv \
  id_regfile_boundary.csv \
  --instances ysyx_22050058_id_ysyx_22050058_regfile_instances.txt \
  --normalize-signal-column
```

保留的旧关键字过滤模式仍可直接调用：

```bash
python3 filter_trace.py \
  pht_trace.csv \
  pht_internal_nodes.csv \
  --keywords ComboMemory RegCombo _ExprInst__
```

## filelist 模式

除 `-lib <kdb.elab++>` 外，主入口也保留 filelist 导入方式：

```bash
./trace_and_filter.sh \
  -module ysyx_22050058_id \
  -filelist filelist.f \
  -top ysyx_22050058 \
  -incdir ../../vsrc/include \
  -keywords ysyx_22050058_regfile \
  -output id_regfile_filtered.csv
```

当前项目推荐优先使用 `-lib` 方式，因为调试和验证主要基于 VCS 生成的 KDB。

## C++ 版本

`npi_port_trace.cpp` 是早期 C++ 实现，构建方式：

```bash
make
```

要求 `VERDI_HOME` 已设置。构建后会生成：

```text
npi_port_trace
npi_port_trace.sh
```

当前 README 的主要用法以 Tcl 版本为准。除非需要对比 NPI C API 行为，一般不需要使用 C++ 版本。

## 常见问题

### `[ERROR] VERDI_HOME is not set.`

说明尚未加载 Verdi 环境。需要先 source 对应 EDA 环境脚本，或手动设置：

```bash
export VERDI_HOME=/path/to/verdi
export PATH="$VERDI_HOME/bin:$PATH"
```

### `[ERROR] no output generated`

常见原因：

1. KDB 路径不存在或目录为空。
2. KDB 不是由当前 RTL 生成。
3. VCS 编译时没有加 `-kdb`。
4. `-module` 写成了实例名，而不是 module 定义名。
5. 目标 module 在当前 top 下没有被实例化。
6. Verdi batch 导入失败，但 `npi_trace.sh` 默认屏蔽了 `verdi` 的 stdout/stderr。

排查：

```bash
ls -la /tmp/npc_build/simv.daidir/kdb.elab++
grep -R "module <module_name>" /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc/vsrc
grep -R "<module_name> " /mnt/hgfs/VMshare-2/CPU_CORE/ysyx/npc/vsrc
```

必要时可临时修改 `npi_trace.sh` 中的 Verdi 调用，去掉重定向以查看详细错误：

```bash
verdi -batch -nologo -play "$TCL"
```

### 主 CSV 里为什么有 `Always/Combo/RegCombo/_ExprInst__`？

这是正常现象。主 CSV 会穿过 module 边界和内部表达式继续追踪 driver/load，NPI 会把过程块、表达式实例、组合逻辑节点等作为 trace 结果返回。

如果只想看端口边界连接，优先查看：

```text
<module>_module_connections.csv
```

### 为什么边界 CSV 中同一端口既有 driver 又有 load？

在 `passMod=0` 模式下，NPI 可能把 module 端口本身也作为边界端点返回。这表示 trace 停在 module 边界。分析时应结合 `inst_full_name`、`port_name` 和 `module_signal_full_name` 的层次关系判断连接方向。

### 表达式连接为什么在边界 CSV 中看不到内部表达式？

例如：

```verilog
.raddr1(hashgshare_pc1_i[2+:`ysyx_22050058_BHRLEN] ^ phtbhr)
```

这类表达式在 KDB 中可能变成 `_ExprInst__`、`SigOp` 或 `Combo` 节点。主 CSV 会保留这些 trace 节点；边界 CSV 会过滤这类内部节点，只保留更适合查看 module 边界的信号。

## 清理生成文件

清理 Verdi 运行临时文件：

```bash
rm -rf novas.conf novas.rc verdiLog
```

清理常见 trace 输出：

```bash
rm -f \
  *_full.csv \
  *_module_connections.csv \
  *_filtered.csv \
  *_filtered_boundary.csv \
  *_filtered_full_owner.csv \
  *_instances.txt
```

不要删除这些工具文件：

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

## 已知限制

- 当前推荐路径是 `-lib <kdb.elab++>`。`-filelist/-top` 仍保留，但不是本工程优先验证路径。
- CSV 是 NPI trace API 返回结果的文本化输出，不是严格语义化的 netlist 数据库。
- module 边界 CSV 依赖名称规则过滤内部节点。如果未来 Verdi 版本改变节点命名，可能需要同步调整 `is_module_boundary_signal`。
- 复杂表达式端口连接建议同时看主 CSV 和边界 CSV。主 CSV 更完整，边界 CSV 更适合看层次连接。
- `npi_trace.sh` 默认把 Verdi batch 输出重定向到 `/dev/null`。调试导入失败时需要临时打开 Verdi 输出。
