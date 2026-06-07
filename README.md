# Verdi NPI Port Trace

这是一个基于 Synopsys Verdi NPI L1 Tcl API 的 RTL 端口连接追踪和 Excel 反标工具。工具只读取已经 elaboration 完成的 VCS/Verdi KDB：

```text
simv.daidir/kdb.elab++
```

当前不支持 filelist 直接导入。`-filelist`、`-top`、`-incdir` 只作为历史兼容参数名保留，迁移到其他项目时应先用 VCS 带 `-kdb` 生成 KDB。

## 功能概览

- 查找一个或多个目标 `module` 的所有例化实例。
- 对目标 module 端口追踪 driver / loader。
- 用一个或多个 `keywords` module 的例化实例做过滤判断。
- 识别端口直接 tie 常数、多层父端口回溯后的常数，以及部分源码 fallback 能识别的父层 net 常数 tie。
- 支持 `assign B = A` 这类普通透传继续追踪。
- 支持 driver 方向的拼接表达式继续展开，例如 `assign A = {b0, b1}`。
- 支持 loader 方向的 fanout / slice / 拼接继续展开，例如 `assign B0 = A[10:0]`、`assign B = {C, A, D}`。
- 支持 `-ports A[7]` 这种单 bit 端口追踪。
- 支持 XLSX 反标、CSV 过滤、Raw Trace 三种命令行入口。
- 提供 Tkinter GUI，保留全部命令行能力。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `trace_gui.sh` | GUI 启动脚本，会自动选择带 `tkinter` 的 Python。 |
| `trace_gui.py` | Tkinter GUI 主程序，支持 XLSX 反标、CSV 过滤、Raw Trace、配置导入导出、结果查看。 |
| `trace_gui_demo_xlsx.json` | GUI 示例配置文件，可通过 `Load Config` 直接加载。 |
| `full_coverage_gui_xlsx.json` | 覆盖更多特性的 GUI XLSX 测试配置。 |
| `annotate_trace_xlsx.sh` | XLSX 反标命令行入口。 |
| `annotate_trace_xlsx.py` | XLSX 反标主实现，依赖 Python 3.8+ 和 `openpyxl`。 |
| `trace_and_filter.sh` | CSV trace + keywords 过滤入口。 |
| `npi_trace.sh` | 底层 NPI trace 包装脚本。 |
| `npi_port_trace.tcl` | 核心端口 trace NPI Tcl 脚本。 |
| `npi_find_instances.tcl` | 查找一个或多个 module 定义的所有例化实例。 |
| `find_instances_batched.py` | 分批查找 `-keywords` module 实例，降低大项目中单个 Verdi 进程资源峰值。 |
| `npi_find_module_params.tcl` | 采集目标 module 例化 parameter。 |
| `filter_trace.py` | CSV 过滤、合并、按实例拆分。 |
| `multi_module_trace_template.xlsx` | 多 module 测试模板。 |
| `all_features_trace_test.v` | 单一 RTL 场景覆盖多 module、多 keywords、parameter、常数、悬空、Reg endpoint、assign 透传/拼接/切片、单 bit 端口、loader fanout、子系统拆分。 |
| `all_features_modules.list` / `all_features_keywords.list` / `all_features_ports.list` | 全特性回归使用的 module、keywords、ports 列表文件。 |
| `all_features_gui_xlsx.json` | 全特性 GUI XLSX 模式配置，可用于 `trace_gui.py --build-command` 或 GUI 加载。 |
| `run_all_features_trace_test.sh` | 构建 KDB 并执行 GUI 命令生成、CSV 过滤、XLSX 反标、子系统拆分和结果断言的全特性回归。 |
| `run_full_coverage_trace_test.sh` | 覆盖常数、assign、单 bit、多 module、多 keywords、XLSX 反标的回归测试。 |
| `run_keyword_assign_driver_trace_test.sh` | 专门覆盖 `KeyMod u_key(.out(c)); assign b = c; u_child(.a(b));` 这种 input driver 经普通 assign 透传命中 keyword 输出的场景。 |
| `run_module_port_passthrough_trace_test.sh` | 专门覆盖非 keywords module port/pin 不停止，继续穿过普通端口透传后命中 keywords 的 driver/load 场景。 |
| `run_assign_passthrough_trace_test.sh` | 专门覆盖 `u_child(.a(b)); assign b = c;` 这类普通 assign 透传 driver 追踪。 |
| `run_assign_loader_slice_trace_test.sh` | 专门覆盖 loader 方向 `assign B=A[10:0]`、`assign C=A[20:11]` 这类切片 fanout 追踪。 |
| `WORKFLOW_GUIDE_FOR_LLMS.md` | 面向其他大模型的工具工作流程说明。 |
| `workflow_diagram.svg` | 工具流程图。 |

## 依赖

必须依赖：

| 依赖 | 说明 |
| --- | --- |
| Linux / VM shell | 主流程脚本是 `bash`。 |
| Verdi | 必须能运行 `verdi -batch -nologo -play ...`。 |
| VCS/Verdi KDB | 必须提供有效 `simv.daidir/kdb.elab++`。 |
| Python 3.8+ | XLSX / GUI 流程按 Python 3.8+ 维护。 |
| `openpyxl` | XLSX 反标和 GUI 查看 XLSX 需要。 |

GUI 额外依赖：

| 依赖 | 说明 |
| --- | --- |
| `tkinter` | GUI 窗口依赖，通常是系统包，不是 pip 包。 |
| 图形显示环境 | 需要 `$DISPLAY` 可用。无图形环境时仍可用命令行入口。 |

安装 Python 包：

```bash
python3 -m pip install openpyxl
```

RHEL/CentOS rh-python38 示例：

```bash
source /opt/rh/rh-python38/enable
yum install -y rh-python38-python-tkinter
```

Ubuntu/Debian 示例：

```bash
apt install -y python3-tk
```

常见 EDA 环境变量示例：

```bash
export VCS_HOME=/home/synopsys/vcs-mx/O-2018.09-SP2
export VERDI_HOME=/home/synopsys/verdi/Verdi_O-2018.09-SP2
export VCS_TARGET_ARCH=linux64
export PATH="$VCS_HOME/bin:$VERDI_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$VCS_HOME/linux64/lib:$VERDI_HOME/share/PLI/VCS/LINUX64:${LD_LIBRARY_PATH:-}"
export LM_LICENSE_FILE=27000@IC_EDA
export SNPSLMD_LICENSE_FILE=27000@IC_EDA
export VERDI_LICENSE_FILE=27000@IC_EDA
```

最小环境检查：

```bash
python3 -V
python3 -c "import openpyxl; print(openpyxl.__version__)"
python3 -c "import tkinter"
which bash
which verdi
ls build/simv.daidir/kdb.elab++
```

生成 KDB 示例：

```bash
vcs -full64 -sverilog -lca -kdb -top top -f rtl.f \
  -Mdir=build/csrc \
  -o build/simv \
  -l build/vcs_build.log
```

## 核心概念

`module` 填 module 定义名，不是实例名。

```verilog
ysyx_22050058_pht ysyx_22050058_pht_u0 (...);
```

命令和 GUI 中应填写：

```text
ysyx_22050058_pht
```

`keywords` 也是 module 定义名列表，不是普通字符串关键词。工具会先查找这些 module 的所有例化实例，再判断目标端口的方向相关 trace endpoint 是否属于这些实例。

方向判断规则：

| 目标端口方向 | 反标判断端点 |
| --- | --- |
| `input` | 看 driver |
| `output` | 看 loader |
| `inout` / unknown | driver 和 loader 都看 |

Excel 反标结果中：

- 有连接到 `keywords` module 实例时写 `yes`。
- 没有连接到 `keywords` module 实例时写 `no: <实际 driver/loader 信息>`。
- 常数 driver 会标成 `Const:<value>`。
- 悬空 / 未连接会标成 floating / unconnected 相关信息。
- 如果打开 `RegCombo as keyword`，方向相关 endpoint 是 `RegCombo` 时也写 `yes`。

## GUI 启动

```bash
cd /mnt/hgfs/VMshare/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace
chmod +x trace_gui.sh
./trace_gui.sh
```

`trace_gui.sh` 查找 Python 的顺序：

1. 环境变量 `PYTHON_BIN` 指定的 Python。
2. `/opt/rh/rh-python38/root/usr/bin/python3`。
3. `/usr/local/bin/python3`。
4. `python3`。
5. `python`。

强制指定 Python：

```bash
PYTHON_BIN=/path/to/python3 ./trace_gui.sh
```

GUI 只是命令行脚本的包装器。点击 `Run` 后，实际仍调用 `annotate_trace_xlsx.sh`、`trace_and_filter.sh` 或 `npi_trace.sh`。

## GUI 总体布局

GUI 界面文字为英文。顶部是麒麟芯片品牌区，中间是参数区，底部是命令预览和运行日志。

| GUI 区域 | 说明 |
| --- | --- |
| `KIRIN CHIP` logo | 顶部品牌标识，不影响任何运行参数。 |
| `Verdi NPI Port Trace` | 工具名称。 |
| `KDB Workflow` | 提示当前工具基于 KDB 工作流。 |
| `Common Parameters` | 三种模式共用参数区。 |
| `XLSX Annotate` | 反标 Excel 模式。 |
| `CSV Filter` | 生成 trace CSV 并按 keywords 过滤模式。 |
| `Raw Trace` | 只运行底层 NPI trace 的调试模式。 |
| `Command Preview` | 实时显示 GUI 当前参数会生成的命令。 |
| `Run Log` | 显示底层脚本日志、错误和退出码。 |

## GUI 公共参数

公共参数位于 `Common Parameters`，三种运行模式都会读取这些字段。

| GUI 项 | JSON 字段 | 命令参数 | 是否必填 | 详细说明 |
| --- | --- | --- | --- | --- |
| `KDB/elab++` | `lib` | `-lib` | 必填 | VCS/Verdi 生成的 KDB 目录，通常是 `simv.daidir/kdb.elab++`。工具必须读取 KDB，不能只给 filelist。路径可以是相对工具目录的相对路径，也可以是绝对路径。 |
| `KDB/elab++` 的 `Browse` | 无独立字段 | 无 | 可选 | 打开目录选择窗口，用于选择 `kdb.elab++` 目录。选择后写入 `lib`。 |
| `module` | `module` | `-module` | CSV / Raw 必填；XLSX 建议填写 | 目标 module 定义名列表。工具会对这些 module 的所有例化实例做端口 trace。可以填写多个 module，用逗号、空格、分号或换行分隔。XLSX 模式如果不填，会尝试从模板第一列读取 module 名。 |
| `module` 的 `Load List` | 写入 `module` | 无 | 可选 | 从 `.txt`、`.list`、`.f` 等文本文件读取 module 列表。支持注释和多种分隔符。 |
| `keywords` | `keywords` | `-keywords` | XLSX / CSV 必填；Raw 不使用 | 过滤 module 定义名列表。工具会找出这些 module 的所有实例，然后判断目标端口 driver / loader 是否来自这些实例。支持多个 keywords。 |
| `keywords` 的 `Load List` | 写入 `keywords` | 无 | 可选 | 从文本文件读取 keywords module 列表。适合大项目中 keywords 很多的情况。 |
| `ports` | `ports` | `-ports` | 可选 | 只检查这些端口。为空时检查目标 module 的全部端口。支持多个端口，也支持单 bit 写法，例如 `A[7]`。 |
| `ports` 的 `Load List` | 写入 `ports` | 无 | 可选 | 从文本文件读取端口列表。适合端口很多或要复用端口集合的场景。 |

list 文件读取规则：

- 支持 UTF-8 和 UTF-8 BOM。
- `#` 后面的内容视为注释。
- 支持每行一个，也支持逗号、空格、英文分号、中文逗号、中文分号分隔。

示例：

```text
# target modules
skidbuffer
SkidPeer

# ports
i_clk,i_reset,i_valid
o_ready o_valid
A[7]
```

## GUI 模式一：XLSX Annotate

`XLSX Annotate` 调用：

```bash
./annotate_trace_xlsx.sh ...
```

这个模式用于把 trace 结果反标到 Excel 模板中。一个目标 module 如果有多个例化实例，会在反标文件中按实例单独开行，并写入 module 名、实例名、parameter 和信号 trace 信息。

| GUI 项 | JSON 字段 | 命令参数 | 默认值 | 详细说明 |
| --- | --- | --- | --- | --- |
| `template` | `template` | `-template` | 空 | 输入 XLSX 模板。模板中通常按 module 和 ports 形成交叉表。若模板不存在且提供了 `module` 和 `ports`，脚本会创建最小模板。 |
| `template` 的 `Browse` | 无独立字段 | 无 | 无 | 打开文件选择窗口，选择输入模板。 |
| `output xlsx` | `xlsx_output` | `-output` | 空 | 反标输出 XLSX 路径。若 `subsystem level > 0`，实际输出会拆成 `输出名__subsys_<subsystem>.xlsx`。 |
| `output xlsx` 的 `Browse` | 无独立字段 | 无 | 无 | 打开保存文件窗口，选择输出 XLSX。 |
| `workdir` | `workdir` | `-workdir` | 空 | 中间文件目录。为空时使用当前工具目录。中间文件包括 `<module>_full.csv`、`<module>_module_connections.csv`、`module_parameters.csv`、`<keywords>_instances.txt` 等。 |
| `workdir` 的 `Browse` | 无独立字段 | 无 | 无 | 打开目录选择窗口，选择中间文件生成目录。 |
| `sheet` | `sheet` | `-sheet` | 空 | 指定读写的 worksheet 名。为空时使用模板第一个 worksheet。 |
| `subsystem level` | `subsystem_level` | `-subsystem-level` | `0` | 按目标实例路径的前 N 层拆分输出，一个子系统一个反标文件。`0` 表示不拆分。例如实例路径 `top.dut.subsys0.u_mod`，设置 `3` 时 subsystem key 是 `top.dut.subsys0`。 |
| `match cache size` | `match_cache_size` | `--match-cache-size` | `200000` | `--stream` 模式下，缓存“某个 trace endpoint 是否属于 keywords 实例”的判断结果。值越大重复判断越少，但运行内存占用越高；`0` 表示关闭缓存。 |
| `keyword batch size` | `keyword_batch_size` | `--keyword-batch-size` | `8` | 每个 Verdi 进程搜索多少个 keyword module。大项目 keywords 很多时建议设为 `1`、`2` 或 `4`，降低单个 Verdi 进程资源峰值。允许跑慢，但更稳。 |
| `const trace depth` | `const_trace_depth` | `-const-trace-depth` | `16` | 多层父 module port 回溯常数 tie 的最大深度。用于 `Child.a <- Parent0.p0 <- Parent1.p1 <- 1'b0` 这类场景。`0` 表示关闭递归回溯。 |
| `assign trace depth` | `assign_trace_depth` | `-assign-trace-depth` | `2` | 当 NPI trace 停在普通透传 net 时继续沿同方向追踪的最大深度，例如 driver 方向 `assign B = A`，loader 方向 `assign B0 = A[10:0]`、`assign B1 = A[20:11]`。这类单信号/切片连接不视为组合逻辑，`0` 表示关闭。 |
| `assign expr depth` | `assign_expr_trace_depth` | `-assign-expr-trace-depth` | `1` | 当 driver / loader 方向遇到允许展开的连续赋值表达式 endpoint 时继续展开的次数，例如 driver 方向 `assign A = {b0, b1}`，loader 方向 `assign B = {C, A, D}`。用于限制拼接表达式递归扩散，`0` 表示关闭。 |
| `trace debug` | `trace_debug` | `-trace-debug 0/1` | `false` | 打开后，NPI/source fallback 会打印更详细的递归、module port high-side、源码上下文、assign fanout 匹配和 skip 原因。用于定位 `a -> b -> c -> assign B/C -> keywords/RegCombo` 这类 trace 断点；大项目常规运行建议关闭。 |
| `stream` | `stream` | `--stream` | `true` | 启用流式聚合反标。Python 端边读 CSV 边聚合，配合匹配缓存降低大项目运行内存压力。大项目建议打开。 |
| `no params` | `no_params` | `--no-params` | `false` | 跳过 module parameter 采集。打开后 parameter 列通常显示 `PARAM_SKIPPED`，端口反标仍继续。若大项目 parameter 采集阶段不稳定，可先打开此项。 |
| `strict params` | `strict_params` | `--strict-params` | `false` | parameter 采集失败时是否直接中断整个 XLSX 反标。默认关闭，失败时记录 `PARAM_TRACE_FAILED` 并继续端口反标。 |
| `keep workdir` | `keep_workdir` | `--keep-workdir` | `false` | 兼容旧命令的开关。当前中间文件默认保留在 `workdir`，此项主要用于保持命令兼容。 |
| `RegCombo as keyword` | `regcombo_as_keyword` | `-regcombo-as-keyword 0/1` | `false` | 打开后，如果方向相关 trace endpoint 是 `RegCombo`，也按检测到 keywords 处理，反标 `yes`。适合把寄存器组合节点视为有效命中的项目约定。 |
| `const source fallback` | `const_source_fallback` | `-const-source-fallback 0/1` | `true` | 是否通过 KDB 记录的源码路径补充识别常数 tie，例如父层 `assign net = 1'b0`、声明赋值等。大项目源码很大时可关掉以减少文件读取。 |
| `keyword continue on error` | `keyword_continue_on_error` | `--keyword-continue-on-error` | `false` | 某个 keyword module 实例搜索失败时是否跳过并继续处理其他 keyword。默认关闭，避免静默漏标；大项目临时调试时可打开。 |
| `keyword log instances` | `keyword_log_instances` | `--keyword-log-instances` | `false` | 是否打印找到的每个 keyword 实例路径。大项目不建议打开，日志会非常大。 |

## GUI 模式二：CSV Filter

`CSV Filter` 调用：

```bash
./trace_and_filter.sh ...
```

这个模式先生成完整 trace CSV，再根据 `keywords` 实例过滤出相关端口记录。

| GUI 项 | JSON 字段 | 命令参数 | 默认值 | 详细说明 |
| --- | --- | --- | --- | --- |
| `output csv` | `csv_output` | `-output` | 空 | 最终过滤结果 CSV。为空时底层脚本使用默认输出名。 |
| `output csv` 的 `Browse` | 无独立字段 | 无 | 无 | 打开保存文件窗口，选择过滤结果 CSV 路径。 |
| `keyword batch size` | `keyword_batch_size` | `--keyword-batch-size` | `8` | 每个 Verdi 进程搜索多少个 keyword module。大项目建议调小，减少单次 Verdi 资源峰值。 |
| `const trace depth` | `const_trace_depth` | `-const-trace-depth` | `16` | 多层父 port 常数 tie 回溯深度。 |
| `assign trace depth` | `assign_trace_depth` | `-assign-trace-depth` | `2` | 普通透传/单信号切片 assign endpoint 的继续追踪深度，例如 `assign B=A`、`assign B0=A[10:0]`。 |
| `assign expr depth` | `assign_expr_trace_depth` | `-assign-expr-trace-depth` | `1` | driver/load 方向拼接表达式 endpoint 的继续展开次数，例如 `assign A={b0,b1}`、`assign B={C,A,D}`。 |
| `trace debug` | `trace_debug` | `-trace-debug 0/1` | `false` | 打开 NPI/source fallback 详细诊断日志。常规运行关闭，定位 trace 断点时打开。 |
| `const source fallback` | `const_source_fallback` | `-const-source-fallback 0/1` | `true` | 是否启用源码 fallback 补充识别常数 tie。 |
| `keyword continue on error` | `keyword_continue_on_error` | `--keyword-continue-on-error` | `false` | 单个 keyword 实例搜索失败时是否继续。 |
| `keyword log instances` | `keyword_log_instances` | `--keyword-log-instances` | `false` | 是否打印所有 keyword 实例路径。大项目建议关闭。 |

CSV 模式常见输出：

```text
<module>_full.csv
<module>_module_connections.csv
<keywords>_instances.txt
<output>_boundary.csv
<output>_full_owner.csv
<output>.csv
```

如果同一个目标 module 有多个实例，最终 CSV 还可能按实例拆分：

```text
<output>__<inst_full_name>.csv
```

## GUI 模式三：Raw Trace

`Raw Trace` 调用：

```bash
./npi_trace.sh ...
```

这个模式只运行底层 NPI trace，适合定位 trace 原始行为，不做 keywords 过滤，不做 XLSX 反标。

| GUI 项 | JSON 字段 | 命令参数 | 默认值 | 详细说明 |
| --- | --- | --- | --- | --- |
| `full trace csv` | `raw_full_output` | shell 重定向 `>` | 空 | 原始完整 trace CSV 输出路径。GUI 运行时会把 `npi_trace.sh` 的 stdout 写入这个文件。Raw 模式必填。 |
| `full trace csv` 的 `Browse` | 无独立字段 | 无 | 无 | 打开保存文件窗口，选择完整 trace CSV 文件。 |
| `module boundary csv` | `raw_module_output` | `-module-out` | 空 | module 边界 trace CSV。为空时底层脚本使用默认名 `<module>_module_connections.csv`。 |
| `module boundary csv` 的 `Browse` | 无独立字段 | 无 | 无 | 打开保存文件窗口，选择 module 边界 CSV 文件。 |
| `srcfile deprecated` | `srcfile` | `-srcfile` | 空 | 旧参数，当前一般不需要填写。端口方向和连接关系通过 NPI API 获取。 |
| `srcfile deprecated` 的 `Browse` | 无独立字段 | 无 | 无 | 打开文件选择窗口，用于兼容旧流程。 |
| `const trace depth` | `const_trace_depth` | `-const-trace-depth` | `16` | 多层父 port 常数 tie 回溯深度。 |
| `assign trace depth` | `assign_trace_depth` | `-assign-trace-depth` | `2` | 普通透传/单信号切片 assign endpoint 继续追踪深度。 |
| `assign expr depth` | `assign_expr_trace_depth` | `-assign-expr-trace-depth` | `1` | 拼接表达式 assign endpoint 继续展开次数。 |
| `trace debug` | `trace_debug` | `-trace-debug 0/1` | `false` | 打开 Raw Trace 的详细诊断日志，用于定位 module port 跨层、源码上下文和 assign fanout 是否成功。 |
| `const source fallback` | `const_source_fallback` | `-const-source-fallback 0/1` | `true` | 是否启用源码 fallback 补充识别常数 tie。 |

## GUI 全局按钮和窗口

| GUI 项 | 详细说明 |
| --- | --- |
| `Command Preview` | 根据当前 GUI 参数实时生成最终命令。必填项缺失时显示 `incomplete parameters: ...`。 |
| `Generate Command` | 手动刷新命令预览。正常情况下字段变化会自动刷新，此按钮用于确认当前命令。 |
| `Run` | 在工具目录中启动当前模式对应的底层脚本。GUI 会把自身 Python 通过 `PYTHON_BIN` 传给子脚本，避免误用没有依赖的 Python。 |
| `Stop` | 终止当前由 GUI 启动的子进程。没有任务运行时按钮禁用。 |
| `View Result` | 打开内置结果查看器。若主输出不存在，会尝试打开同名前缀的拆分输出，例如 `out__subsys_*.xlsx` 或 `out__<inst>.csv`。 |
| `Export Config` | 将当前 GUI 全部参数保存成 JSON 配置文件。 |
| `Load Config` | 从 JSON 配置文件恢复 GUI 参数。加载时会暂停逐项刷新，全部设置完成后统一刷新命令预览。 |
| `Run Log` | 显示底层脚本 stdout/stderr、运行状态和退出码。Raw Trace 模式下，完整 trace stdout 写入 `full trace csv`，界面日志主要显示 stderr 和状态。 |

## GUI 结果查看器

点击 `View Result` 会打开 `Result Viewer`。

| GUI 项 | 详细说明 |
| --- | --- |
| `File` | 当前要查看的 CSV/XLSX/XLSM 文件路径，可以手动修改。 |
| `Browse` | 选择 CSV、XLSX 或 XLSM 文件。 |
| `Open` | 打开 `File` 输入框中的路径。 |
| `Sheet` | 仅 XLSX/XLSM 生效，用于切换 worksheet。CSV 没有 sheet，此项禁用。 |
| 表格表头 | 表头固定在表格上方。行数很多时，纵向向下滚动数据区仍能看到表头。 |
| 表格区域 | 按行列显示 CSV/XLSX 内容，带纵向和横向滚动条。横向滚动时表头和数据列同步移动。 |
| 表格单元格 | 长文本会自动换行并截断到若干行，避免信号名过长撑坏窗口。点击单元格会弹出完整内容窗口。 |
| `Cell Content` | 显示被点击单元格的完整文本，适合查看和复制长层次信号名。 |
| 状态栏 | 显示当前文件、行数、自动打开拆分输出的提示或错误信息。 |

## GUI 配置 JSON 字段

`Export Config` 保存的 JSON 包含以下字段。`Load Config` 加载时，未知字段会忽略。

| JSON 字段 | GUI 对应项 | 类型 | 默认值 | 详细说明 |
| --- | --- | --- | --- | --- |
| `version` | 无直接控件 | integer | `1` | 配置文件版本。 |
| `mode` | 运行模式 tab | string | `xlsx` | 可选 `xlsx`、`csv`、`raw`。决定点击 `Run` 时调用哪个底层脚本。 |
| `lib` | `KDB/elab++` | string | 空 | KDB 目录路径。 |
| `module` | `module` | string | 空 | 目标 module 定义名列表。 |
| `keywords` | `keywords` | string | 空 | 过滤 module 定义名列表。Raw 模式不使用。 |
| `ports` | `ports` | string | 空 | 端口列表，支持 `A[7]` 单 bit。为空时检查全部端口。 |
| `template` | `template` | string | 空 | XLSX 模板路径。仅 XLSX 模式使用。 |
| `xlsx_output` | `output xlsx` | string | 空 | XLSX 反标输出路径。仅 XLSX 模式使用。 |
| `sheet` | `sheet` | string | 空 | worksheet 名。仅 XLSX 模式使用。 |
| `workdir` | `workdir` | string | 空 | 中间文件目录。为空时使用工具当前目录。 |
| `subsystem_level` | `subsystem level` | string/integer | `0` | 按实例路径前 N 层拆分 XLSX 输出。 |
| `stream` | `stream` | boolean | `true` | XLSX 模式是否启用流式聚合。 |
| `no_params` | `no params` | boolean | `false` | 是否跳过 parameter 采集。 |
| `strict_params` | `strict params` | boolean | `false` | parameter 采集失败是否中断。 |
| `keep_workdir` | `keep workdir` | boolean | `false` | 兼容旧参数，当前中间文件默认保留。 |
| `regcombo_as_keyword` | `RegCombo as keyword` | boolean | `false` | RegCombo endpoint 是否视为命中 keywords。 |
| `match_cache_size` | `match cache size` | string/integer | `200000` | `--stream` 模式实例匹配缓存大小，`0` 关闭。 |
| `keyword_batch_size` | `keyword batch size` | string/integer | `8` | 每个 Verdi 进程处理的 keyword module 数。 |
| `keyword_continue_on_error` | `keyword continue on error` | boolean | `false` | keyword 搜索失败是否继续。 |
| `keyword_log_instances` | `keyword log instances` | boolean | `false` | 是否打印每个 keyword 实例路径。 |
| `const_source_fallback` | `const source fallback` | boolean | `true` | 是否启用源码 fallback 常数识别。 |
| `const_trace_depth` | `const trace depth` | string/integer | `16` | 多层父 port 常数回溯深度。 |
| `assign_trace_depth` | `assign trace depth` | string/integer | `2` | 普通透传/单信号切片 assign 继续追踪深度。 |
| `assign_expr_trace_depth` | `assign expr depth` | string/integer | `1` | 拼接表达式 assign endpoint 继续展开次数。 |
| `trace_debug` | `trace debug` | boolean | `false` | 是否打开 trace 详细诊断日志。打开后日志会包含 `DEBUG collect_load_rec_enter`、`DEBUG source_module_port_load_probe`、`DEBUG source_assign_load_probe`、`DEBUG source_assign_load_empty` 等信息。 |
| `csv_output` | `output csv` | string | 空 | CSV Filter 输出路径。仅 CSV 模式使用。 |
| `raw_full_output` | `full trace csv` | string | 空 | Raw Trace 完整 CSV 输出路径。仅 Raw 模式使用。 |
| `raw_module_output` | `module boundary csv` | string | 空 | Raw Trace module 边界 CSV 输出路径。仅 Raw 模式使用。 |
| `srcfile` | `srcfile deprecated` | string | 空 | 旧源码文件参数，一般不需要填写。 |

## GUI 示例配置

启动 GUI：

```bash
./trace_gui.sh
```

加载示例：

```text
Load Config -> trace_gui_demo_xlsx.json -> Generate Command -> Run
```

等价命令大致如下：

```bash
./annotate_trace_xlsx.sh \
  -template multi_module_trace_template.xlsx \
  -output trace_gui_demo_annotated.xlsx \
  -lib skidbuffer_param_build/simv.daidir/kdb.elab++ \
  -keywords SkidPeer,skidbuffer \
  -module skidbuffer,SkidPeer \
  -ports i_clk,i_reset,i_valid,o_ready,i_data,o_valid,i_ready,o_data,clk,rst,src_valid,src_ready,src_data,dst_valid,dst_ready,dst_data \
  -subsystem-level 2 \
  --stream \
  --no-params \
  -regcombo-as-keyword 0 \
  -const-source-fallback 0 \
  -const-trace-depth 4 \
  -assign-trace-depth 2 \
  -assign-expr-trace-depth 1 \
  --match-cache-size 200000 \
  --keyword-batch-size 1
```

如果启用了 `-subsystem-level`，实际输出可能是：

```text
trace_gui_demo_annotated__subsys_top.subsys0.xlsx
trace_gui_demo_annotated__subsys_top.subsys1.xlsx
```

`View Result` 会优先查找主输出；如果主输出不存在，会自动尝试打开拆分输出。

## 命令行用法

GUI 不影响传统命令行入口，三类命令仍可直接运行。

### XLSX 反标

```bash
./annotate_trace_xlsx.sh \
  -template trace_template.xlsx \
  -output annotated.xlsx \
  -lib build/simv.daidir/kdb.elab++ \
  -keywords KeyModA,KeyModB \
  -module TargetModA,TargetModB \
  -ports clk,rst,we,waddr,wdata \
  -subsystem-level 2 \
  --stream \
  --keyword-batch-size 1 \
  -const-source-fallback 0 \
  -const-trace-depth 4 \
  -assign-trace-depth 2 \
  -assign-expr-trace-depth 1 \
  -trace-debug 0
```

### CSV 过滤

```bash
./trace_and_filter.sh \
  -module TargetMod \
  -lib build/simv.daidir/kdb.elab++ \
  -keywords KeyModA,KeyModB \
  -ports clk,rst,we,waddr,wdata \
  -output target_from_keywords.csv \
  --keyword-batch-size 4 \
  -const-source-fallback 0 \
  -const-trace-depth 4 \
  -assign-trace-depth 2 \
  -assign-expr-trace-depth 1 \
  -trace-debug 0
```

### Raw Trace

```bash
./npi_trace.sh \
  -module TargetMod \
  -lib build/simv.daidir/kdb.elab++ \
  -ports clk,rst \
  -module-out target_module_connections.csv \
  -const-source-fallback 0 \
  -const-trace-depth 4 \
  -assign-trace-depth 2 \
  -assign-expr-trace-depth 1 \
  -trace-debug 1 \
  > target_full.csv
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
export NPI_ASSIGN_TRACE_MAX_DEPTH=2
export NPI_ASSIGN_EXPR_TRACE_MAX_DEPTH=1
export NPI_TRACE_DEBUG=1

verdi -batch -nologo -play ./npi_port_trace.tcl 2>&1 | tee npi_port_trace_debug.log
```

### Loader trace 断点定位

如果 output 端口 loader 路径类似 `Child.a -> parent0.b -> parent1.c -> assign B=c[10:0], C=c[20:11] -> keywords/RegCombo`，先用 Raw Trace 打开详细日志：

```bash
./npi_trace.sh \
  -module Child \
  -lib build/simv.daidir/kdb.elab++ \
  -ports a \
  -module-out debug_child_module.csv \
  -const-source-fallback 1 \
  -const-trace-depth 8 \
  -assign-trace-depth 30 \
  -assign-expr-trace-depth 10 \
  -trace-debug 1 \
  > debug_child_full.csv \
  2> debug_child_trace.log
```

重点看这些日志：

```bash
grep -E "DEBUG collect_load_rec_enter|DEBUG collect_source_load_fanouts_enter|DEBUG source_module_port_load_probe|DEBUG source_module_port_load_empty|DEBUG source_assign_load_probe|DEBUG source_assign_load_match|DEBUG source_assign_load_candidate|DEBUG source_assign_load_empty|source_module_port_load|source_assign.*load_fanout|load_module_port_high_continue" debug_child_trace.log
```

判读规则：
- 没有 `load_module_port_high_continue from=...Child.a via=...parent0.b`：output port 没有跨到父层 high-side。
- 有 `parent0.b`，但没有 `source_module_port_load ... fanouts=...parent1.c`：父层到同级 `parent1.c` 的 module port load fallback 没找到。
- 有 `parent1.c`，但没有 `source_assign_direct_load_fanout signal=...c fanouts=...B,...C`：`c -> B/C` 的 assign fanout 没展开。看 `DEBUG source_assign_load_probe` 的 `srcfile/module/assign_count`，以及 `DEBUG source_assign_load_empty` 的 `match_count/candidate_count/rejected_count`。
- full CSV 有 `B/C/u_key/RegCombo`，但反标 no：trace 阶段已经成功，问题在 keywords 实例过滤或 Excel 汇总阶段。

### `trace-debug` 日志速查

打开 `-trace-debug 1` 后，工具会把 `a -> b -> c` 这类跨层追踪过程拆成多个日志点。定位问题时建议先确认日志是否按顺序出现：

| 日志关键字 | 说明 | 如果缺失通常说明 |
| --- | --- | --- |
| `DEBUG collect_load_rec_enter signal=...` | loader 递归进入某个信号。 | 没有继续递归到该信号，可能已经被 visited、深度耗尽，或 NPI 没返回这个端点。 |
| `DEBUG collect_source_load_fanouts_enter signal=...` | 开始对 loader 方向做源码 fallback fanout 搜索。 | `-assign-trace-depth` / `-assign-expr-trace-depth` 为 0，或信号上下文无法解析。 |
| `DEBUG source_context signal=... resolved_src=... module=...` | 从 KDB 端点解析到源码文件和当前 module 上下文。 | KDB 没记录可访问源码路径，或源码路径在当前机器不存在。 |
| `DEBUG module_port_high_probe role=load/driver ... high_count=...` | 尝试从 module port/pin 穿到父层 high-side connection。 | 当前端点不是可穿透的 module port/pin，或 NPI 没返回 port handle。 |
| `load_module_port_high_continue from=... via=...` | loader 方向已经从子层端口跨到父层连接信号。 | output 端口没有成功跨层，后续同级 input / assign fanout 不会被看到。 |
| `driver_module_port_high_continue from=... via=...` | driver 方向已经从子层端口跨到父层连接信号。 | input 端口没有成功跨层，后续父层 tie / assign / keyword source 不会被看到。 |
| `source_module_port_load signal=... fanouts=...` | 源码 fallback 找到同一层或父层中由该信号连接到的 input/inout port。 | 可能没有同级 module port 连接，也可能源码上下文不对。 |
| `source_module_port_driver signal=... drivers=...` | 源码 fallback 找到同一层或父层中驱动该信号的 output/inout port。 | 可能没有同级 module port 驱动，也可能源码上下文不对。 |
| `source_assign_direct_driver_source signal=... drivers=...` | driver 方向命中普通透传 assign，例如 `assign b = c`。 | `assign B=A` 这类普通透传没有被源码 fallback 展开。 |
| `source_assign_driver_source signal=... drivers=...` | driver 方向命中可展开表达式，例如 `assign A={b0,b1}`。 | 拼接表达式没有展开，检查 `-assign-expr-trace-depth`。 |
| `source_assign_direct_load_fanout signal=... fanouts=...` | loader 方向命中普通 fanout / slice，例如 `assign B=A[10:0]`。 | `A -> B/C` fanout 没展开，重点看 `DEBUG source_assign_load_empty`。 |
| `source_assign_load_fanout signal=... fanouts=...` | loader 方向命中可展开表达式，例如 `assign B={C,A,D}`。 | 拼接 fanout 没展开，检查 `-assign-expr-trace-depth`。 |
| `DEBUG source_assign_load_empty ... match_count=... candidate_count=... rejected_count=...` | 源码里找不到可继续追踪的 loader assign，或候选被拒绝。 | `match_count=0` 多半是源码上下文/信号名不匹配；`rejected_count>0` 看前面的 `source_assign_load_skip` 原因。 |

driver 方向排查 `KeyMod u_key(.out(c)); assign b = c; u_child(.a(b));` 时，重点搜索：

```bash
grep -E "driver_module_port_high_continue|source_module_port_driver|source_assign_direct_driver_source|source_assign_driver_source|driver_assign_continue|DEBUG source_context" debug_child_trace.log
```

loader 方向排查 `output A -> sibling input c -> assign B/C -> keywords` 时，重点搜索：

```bash
grep -E "load_module_port_high_continue|source_module_port_load|source_assign_direct_load_fanout|source_assign_load_fanout|load_assign_continue|DEBUG source_assign_load" debug_child_trace.log
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

## 大项目建议

大项目中 `-keywords` 很多、RTL 规模很大时，优先使用低峰值配置：

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
  -const-trace-depth 4 \
  -assign-trace-depth 2 \
  -assign-expr-trace-depth 1
```

建议：

- `--stream` 打开，减少 Python 端运行内存压力。
- `--keyword-batch-size 1` 最稳，但会更慢；确认稳定后可调到 `2` 或 `4`。
- `--keyword-log-instances` 默认关闭，避免日志 IO 过大。
- `-const-source-fallback 0` 可避免读取和解析大量源码文件。
- `-const-trace-depth 4` 先小深度验证流程，再按需要增大。
- `-assign-trace-depth 2` 和 `-assign-expr-trace-depth 1` 先保守开启，避免复杂 assign 网络无限扩散。
- 若 parameter 采集阶段不稳定，可先开 `--no-params` 确认端口反标流程。

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

这类依赖：

```bash
-const-source-fallback 1
```

3. 多层父 module port 透传后在更上层 tie 常数：

```text
Child.a <- Parent0.p0 <- Parent1.p1 <- 1'b0
```

这类依赖 NPI high-side connection 递归，深度由 `-const-trace-depth <N>` 控制。

## assign 继续追踪

普通透传：

```verilog
assign B = A;
```

如果 NPI trace 停在 `B`，工具会按 `-assign-trace-depth <N>` 继续沿同方向追踪。普通 `assign B = A` 被视为信号连接，不视为组合逻辑或时序逻辑，因此 driver 方向会继续从 `B` 追到 `A`。即使 `-assign-expr-trace-depth 0`，这种普通透传仍然由 `-assign-trace-depth` 控制。

module port/pin 也按结构连接处理：如果该端口属于 `-keywords` 对应实例，过滤阶段会直接命中 `yes`；如果不是 keywords 实例，trace 会继续跨过端口 high-side 连接向后追，直到遇到组合逻辑、时序逻辑、常数、悬空或达到 `-assign-trace-depth` 限制。

典型场景：

```verilog
u_child(.a(b));
assign b = c;
```

追 `u_child.a` 的 driver 时，工具会先看到父层连接信号 `b`，然后继续追到 `c`，不会停在 `b`。

driver 方向拼接：

```verilog
assign A = {b0, b1};
```

如果 NPI 把该连续赋值表达式作为 driver endpoint，工具会继续追 `b0`、`b1`。如果后续又遇到同类表达式，会按 `-assign-expr-trace-depth <N>` 控制继续展开次数。

loader 方向 fanout / slice / 拼接：

```verilog
assign B = {C, A, D};
assign B0 = A[10:0];
assign B1 = A[20:11];
```

如果目标 output 高层连接信号是 `A`，工具会继续追 `B`、`B0`、`B1`，直到遇到 keywords 实例、常数、RegCombo 或其他真实 endpoint。其中 `assign B0 = A[10:0]`、`assign B1 = A[20:11]` 是单信号切片连接，受 `-assign-trace-depth` 控制；`assign B = {C, A, D}` 是拼接表达式，受 `-assign-expr-trace-depth` 控制。

工具不会把任意组合逻辑都当成连线穿透。例如：

```verilog
assign Y = A ^ B;
```

追 `A` 的 loader 时不会因为源码 fallback 穿过这个 XOR 到 `Y`，避免把真实组合逻辑误判成 keywords 连接。

## 单 bit 端口 trace

`-ports` 支持输入某个端口的单 bit：

```bash
-ports A[7]
```

用于下面这种场景：

```verilog
assign A[10:0] = {D[2:0], C, B[6:0]};
```

如果只检查 `A[7]`，工具会按 bit 对应关系只继续追 `C`，不会把 `D[2:0]` 和 `B[6:0]` 全部混入该 bit 的结果。

## VM 回归测试命令

在 VM 工具目录运行，生成文件都留在当前目录：

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

bash -n annotate_trace_xlsx.sh trace_and_filter.sh npi_trace.sh trace_gui.sh
python3 -m py_compile annotate_trace_xlsx.py filter_trace.py find_instances_batched.py trace_gui.py

bash run_all_features_trace_test.sh
bash run_keyword_assign_driver_trace_test.sh
bash run_module_port_passthrough_trace_test.sh
bash run_assign_loader_slice_trace_test.sh
bash run_assign_passthrough_trace_test.sh
bash run_full_coverage_trace_test.sh
```

也可以只测试 GUI 命令生成：

```bash
./trace_gui.sh --build-command full_coverage_gui_xlsx.json
```

## 生成文件与清理

常见中间文件：

```text
<module>_full.csv
<module>_module_connections.csv
<keywords>_instances.txt
module_parameters.csv
<output>__subsys_<subsystem>.xlsx
```

轻量清理，保留 KDB：

```bash
rm -rf __pycache__ verdiLog
rm -f novas.conf novas.rc
rm -f *_debug.log *_trace_and_filter.log *_instances_errors.log
rm -f vm_*.csv vm_*.log vm_*.xlsx
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
trace_gui.py
trace_gui.sh
trace_gui_demo_xlsx.json
full_coverage_gui_xlsx.json
all_features_trace_test.v
all_features_trace_test.f
all_features_trace_template.xlsx
all_features_modules.list
all_features_keywords.list
all_features_ports.list
all_features_gui_xlsx.json
run_all_features_trace_test.sh
keyword_assign_driver_trace_test.v
keyword_assign_driver_trace_test.f
run_keyword_assign_driver_trace_test.sh
module_port_passthrough_trace_test.v
module_port_passthrough_trace_test.f
run_module_port_passthrough_trace_test.sh
assign_passthrough_trace_test.v
assign_passthrough_trace_test.f
assign_loader_slice_trace_test.v
assign_loader_slice_trace_test.f
run_assign_loader_slice_trace_test.sh
run_assign_passthrough_trace_test.sh
run_full_coverage_trace_test.sh
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

### GUI 启动提示 `No module named tkinter`

当前 Python 没有安装 `tkinter`。安装系统包，或用：

```bash
PYTHON_BIN=/path/to/python3 ./trace_gui.sh
```

指定带 `tkinter` 的 Python。

### GUI 能不能不用？

可以。GUI 只是包装器，传统命令行入口 `annotate_trace_xlsx.sh`、`trace_and_filter.sh`、`npi_trace.sh` 仍然可以直接使用。

### 为什么主 CSV 中有 `Always/Combo/RegCombo/_ExprInst__`

这是 Verdi NPI trace 的内部节点。完整 trace 可能穿过 module 边界，返回过程块、表达式实例、组合逻辑节点或存储节点。需要看端口边界连接时，优先看 `*_module_connections.csv`。

### 为什么常数没有检测出来

先判断是哪种 tie：

- `.a(1'b0)`：NPI 通常能直接识别。
- 多层父 port 透传到 `.p(1'b0)`：需要 `-const-trace-depth` 足够大。
- `.a(parent_net)` 且 `assign parent_net = 1'b0`：需要 `-const-source-fallback 1`，并且 KDB 记录的源码路径在当前机器可访问。

### 怎么确认源码 fallback 是否成功

看运行日志中的 `source_*` 标记。只要出现下面这类日志，就说明工具已经读取 KDB 记录的 RTL 源码路径，并用源码 fallback 补充了 NPI trace：

```text
source_assign_direct_driver_source signal=... source=... drivers=...
source_assign_driver_source signal=... source=... drivers=...
source_assign_direct_load_fanout signal=... source=... fanouts=...
source_assign_load_fanout signal=... source=... fanouts=...
source_module_port_driver signal=... source=... drivers=...
const_driver_from_parent_signal signal=... source=... value=Const:...
```

快速查看命令：

```bash
grep -nE "source_|const_driver_from_parent_signal|module_port_high_continue" <run.log>
```

判断规则：

- `source=...` 是 fallback 实际读取到的 RTL 源码文件。
- `drivers=...` / `fanouts=...` 是源码解析补出来并继续追踪的信号。
- 如果这些信号继续出现在 `*_full.csv`、`*_module_connections.csv` 或最终过滤 CSV 中，就说明 fallback 结果已经参与本次判断。

可以用开关对比确认：

```bash
# 关闭 assign / fanout / module port 继续展开
./trace_and_filter.sh ... -assign-trace-depth 0 -assign-expr-trace-depth 0

# 打开 assign / fanout / module port 继续展开
./trace_and_filter.sh ... -assign-trace-depth 4 -assign-expr-trace-depth 1
```

如果打开后多出通过 `assign`、slice、拼接或非 keywords module port/pin 继续追到的 endpoint，并且日志中有 `source_*` 或 `module_port_high_continue`，就可以确认源码 fallback / 结构连接继续追踪生效。

常数源码 fallback 单独看：

```bash
-const-source-fallback 1
```

成功时通常会出现：

```text
const_driver_from_parent_signal signal=... source=... value=Const:...
```

### 大项目跑得慢怎么办

先用：

```bash
--stream --keyword-batch-size 1 -const-source-fallback 0 -const-trace-depth 4 -assign-trace-depth 2 -assign-expr-trace-depth 1
```

如果这样能稳定跑完，再逐步打开源码 fallback 或增大回溯深度。
