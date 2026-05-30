# Verdi NPI Port Trace

这是一个基于 Synopsys Verdi NPI L1 Tcl API 的 RTL 端口连接追踪和反标工具。工具读取已经 elaboration 完成的 VCS/Verdi KDB，查找指定 `module` 的所有例化实例，追踪端口 driver/load，并输出 CSV 或反标到 XLSX。

当前工具只支持 KDB 输入：

```text
simv.daidir/kdb.elab++
```

不支持 filelist 导入。`-filelist`、`-top`、`-incdir` 只作为旧参数名保留，传入会报错。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `trace_gui.sh` | GUI 启动脚本，会自动选择带 `tkinter` 的 Python。 |
| `trace_gui.py` | Tkinter GUI 主程序，支持 XLSX 反标、CSV 过滤、Raw Trace、配置导入导出和结果查看。 |
| `trace_gui_demo_xlsx.json` | GUI 示例配置文件，可直接在 GUI 中 `Load Config` 测试。 |
| `annotate_trace_xlsx.sh` | XLSX 反标命令行入口。 |
| `annotate_trace_xlsx.py` | XLSX 反标实现，依赖 Python 3.8+ 和 `openpyxl`。 |
| `trace_and_filter.sh` | CSV trace + keywords 过滤入口。 |
| `npi_trace.sh` | 底层 NPI trace 包装脚本。 |
| `npi_port_trace.tcl` | 核心端口 trace NPI Tcl 脚本。 |
| `npi_find_instances.tcl` | 查找一个或多个 module 定义的所有例化实例。 |
| `find_instances_batched.py` | 分批查找 `-keywords` module 实例，降低大项目中单个 Verdi 进程资源峰值。 |
| `npi_find_module_params.tcl` | 采集目标 module 例化 parameter。 |
| `filter_trace.py` | CSV 过滤、合并、按实例拆分。 |
| `run_skidbuffer_param_test.sh` | 本目录内的 skidbuffer 回归测试脚本。 |
| `multi_module_trace_template.xlsx` | 多 module 测试模板，应保留在仓库中。 |

## 依赖

必须依赖：

| 依赖 | 说明 |
| --- | --- |
| Linux / VM shell | 主流程脚本是 `bash`。 |
| Verdi | 必须能运行 `verdi -batch -nologo -play ...`。 |
| VCS/Verdi KDB | 必须提供有效 `simv.daidir/kdb.elab++`。 |
| Python 3.8+ | Python 3.6 不支持当前 XLSX/GUI 流程。 |
| `openpyxl` | XLSX 反标和 GUI 查看 XLSX 需要。 |

安装 Python 包：

```bash
python3 -m pip install openpyxl
```

GUI 额外依赖：

| 依赖 | 说明 |
| --- | --- |
| `tkinter` | GUI 窗口依赖，通常是系统包，不是 pip 包。 |
| 图形显示环境 | 需要 `$DISPLAY` 可用。无图形环境时仍可使用命令行入口。 |

RHEL/CentOS rh-python38 示例：

```bash
source /opt/rh/rh-python38/enable
yum install -y rh-python38-python-tkinter
```

Ubuntu/Debian 示例：

```bash
apt install -y python3-tk
```

生成测试 KDB 时需要 `vcs`。VCS 编译需要带 `-kdb`：

```bash
vcs -full64 -sverilog -lca -kdb -top top -f rtl.f \
  -Mdir=build/csrc \
  -o build/simv \
  -l build/vcs_build.log
```

常见 EDA 环境：

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

`libreoffice/soffice` 不是工具运行依赖，只用于人工打开 `.xlsx` 文件。

## 核心概念

`-module` 填的是 **module 定义名**，不是实例名。

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

`-keywords` 是历史参数名，现在表示 **过滤 module 定义名列表**，不是文本关键字。工具会先查找这些 module 的所有例化实例，然后判断目标端口方向相关的 trace 端点是否属于这些实例。

方向判断规则：

| 目标端口方向 | 反标判断端点 |
| --- | --- |
| `input` | 看 driver |
| `output` | 看 loader |
| `inout` / unknown | driver 和 loader 都看 |

## GUI 启动

```bash
cd /mnt/hgfs/VMshare/CPU_CORE/ysyx/npc/csrc/verdi_npi_port_trace
chmod +x trace_gui.sh
./trace_gui.sh
```

`trace_gui.sh` 会自动查找能 `import tkinter` 的 Python，顺序如下：

1. 环境变量 `PYTHON_BIN` 指定的 Python。
2. `/opt/rh/rh-python38/root/usr/bin/python3`。
3. `/usr/local/bin/python3`。
4. `python3`。
5. `python`。

强制指定 Python：

```bash
PYTHON_BIN=/path/to/python3 ./trace_gui.sh
```

GUI 只是命令行脚本的包装器。点击 `Run` 后仍然调用 `annotate_trace_xlsx.sh`、`trace_and_filter.sh` 或 `npi_trace.sh`。

## GUI 总体布局

GUI 顶部是品牌区和运行模式区，界面文字均为英文。

| GUI 项 | 含义 |
| --- | --- |
| `KIRIN CHIP` logo | 顶部品牌标识，不影响工具参数。logo 使用 Tkinter Canvas 自绘，不依赖外部图片。 |
| `Verdi NPI Port Trace` | 工具名称。 |
| `KDB Workflow` | 提示当前工具基于 KDB 工作流。 |
| `XLSX Annotate` tab | XLSX 反标模式。 |
| `CSV Filter` tab | CSV trace + keywords 过滤模式。 |
| `Raw Trace` tab | 只运行底层 NPI trace 的调试模式。 |

## GUI 公共参数区

公共参数区标题为 `Common Parameters`，三个运行模式都会使用这些参数。

| GUI 项 | 配置字段 | 必填场景 | 含义 |
| --- | --- | --- | --- |
| `KDB/elab++` | `lib` | 三种模式都必填 | VCS/Verdi 生成的 KDB 路径，通常是 `simv.daidir/kdb.elab++`。工具只支持 KDB，不支持 filelist。 |
| `KDB/elab++` 的 `Browse` | 无独立字段 | 可选 | 打开目录选择窗口，选择 `kdb.elab++` 目录。 |
| `module` | `module` | `CSV Filter`、`Raw Trace` 必填；`XLSX Annotate` 建议填写 | 目标 module 定义名列表，不是实例名。多个 module 可用逗号、空格、分号或换行分隔。XLSX 模式不填时会尝试从模板读取。 |
| `module` 的 `Load List` | 写入 `module` | 可选 | 从文本文件读取 module 列表。 |
| `keywords` | `keywords` | `XLSX Annotate`、`CSV Filter` 必填；`Raw Trace` 不使用 | 过滤 module 定义名列表。工具会查找这些 module 的实例，再判断端口 driver/load 是否来自这些实例。 |
| `keywords` 的 `Load List` | 写入 `keywords` | 可选 | 从文本文件读取 keywords module 列表。 |
| `ports` | `ports` | 可选 | 只检查这些端口。为空表示检查目标 module 的全部端口。多个端口可用逗号、空格、分号或换行分隔。 |
| `ports` 的 `Load List` | 写入 `ports` | 可选 | 从文本文件读取端口列表。 |

list 文件规则：

- 支持 UTF-8 或带 BOM 的 UTF-8。
- `#` 后面的内容视为注释。
- 支持每行一个。
- 支持空格、逗号、英文分号、中文逗号、中文分号分隔。

示例：

```text
# target modules
skidbuffer
SkidPeer

# ports
i_clk,i_reset,i_valid
o_ready o_valid
```

## GUI: XLSX Annotate

`XLSX Annotate` 页签调用底层命令：

```bash
./annotate_trace_xlsx.sh ...
```

| GUI 项 | 配置字段 | 是否必填 | 命令参数 | 含义 |
| --- | --- | --- | --- | --- |
| `template` | `template` | 是 | `-template` | XLSX 输入模板。模板不存在时，如果同时提供 `module` 和 `ports`，脚本会创建最小模板。 |
| `template` 的 `Browse` | 无独立字段 | 可选 | 无 | 打开文件选择窗口，选择输入模板。 |
| `output xlsx` | `xlsx_output` | 是 | `-output` | 反标输出文件。若 `subsystem level > 0`，实际输出会拆成 `输出名__subsys_<subsystem>.xlsx`。 |
| `output xlsx` 的 `Browse` | 无独立字段 | 可选 | 无 | 打开保存文件窗口，选择输出 XLSX 路径。 |
| `workdir` | `workdir` | 否 | `-workdir` | 中间 CSV、实例列表、parameter CSV 的生成目录。为空时使用当前工具目录。 |
| `workdir` 的 `Browse` | 无独立字段 | 可选 | 无 | 打开目录选择窗口，选择中间文件目录。 |
| `sheet` | `sheet` | 否 | `-sheet` | 指定读取/写入的 worksheet 名。为空时使用第一个 worksheet。 |
| `subsystem level` | `subsystem_level` | 否 | `-subsystem-level` | 按目标实例路径前 N 层拆分输出。`0` 表示不拆分。例如 `top.dut.subsys0.u_mod` 设置 `3` 时，subsystem key 是 `top.dut.subsys0`。 |
| `match cache size` | `match_cache_size` | 否 | `--match-cache-size` | `--stream` 模式下 signal 是否属于 keywords 实例的判断缓存大小。默认 `200000`，`0` 表示关闭缓存。 |
| `keyword batch size` | `keyword_batch_size` | 否 | `--keyword-batch-size` | 每个 Verdi 进程搜索多少个 keyword module。数字越小峰值运存越低，但运行更慢。大项目建议 `1`、`2` 或 `4`。 |
| `const trace depth` | `const_trace_depth` | 否 | `-const-trace-depth` | 多层父模块 port 回溯常数 tie 的最大深度。默认 `16`，`0` 关闭父 port 常数递归回溯。 |
| `stream` | `stream` | 否 | `--stream` | 启用流式读取 CSV 和实例匹配缓存，降低 Python 端运行期运存。大项目建议打开。 |
| `no params` | `no_params` | 否 | `--no-params` | 跳过 module parameter 采集。打开后 parameter 列通常显示 `PARAM_SKIPPED`，但端口反标继续运行。 |
| `strict params` | `strict_params` | 否 | `--strict-params` | parameter 采集失败时直接中断整个 XLSX 反标。默认关闭，失败时记录 `PARAM_TRACE_FAILED` 并继续端口反标。 |
| `keep workdir` | `keep_workdir` | 否 | `--keep-workdir` | 兼容参数。当前中间文件默认保留，此项主要用于保持旧命令兼容。 |
| `RegCombo as keyword` | `regcombo_as_keyword` | 否 | `-regcombo-as-keyword 0/1` | 打开后，如果方向相关 trace 端点是 `RegCombo`，也反标为 `yes`。 |
| `const source fallback` | `const_source_fallback` | 否 | `-const-source-fallback 0/1` | 是否读取 KDB 记录的源码路径，用源码解析补充识别父层 `assign net = 1'b0`、声明赋值等常数 tie。大项目可关闭以降低源码读取量。 |
| `keyword continue on error` | `keyword_continue_on_error` | 否 | `--keyword-continue-on-error` | 某个 keyword module 实例搜索失败时跳过并继续。默认关闭，避免静默漏标。 |
| `keyword log instances` | `keyword_log_instances` | 否 | `--keyword-log-instances` | 打印每个找到的 keyword 实例路径。大项目不建议打开，日志会非常大。 |

## GUI: CSV Filter

`CSV Filter` 页签调用底层命令：

```bash
./trace_and_filter.sh ...
```

| GUI 项 | 配置字段 | 是否必填 | 命令参数 | 含义 |
| --- | --- | --- | --- | --- |
| `output csv` | `csv_output` | 否 | `-output` | 最终过滤结果 CSV。为空时脚本使用默认名 `<module>_filtered.csv`。 |
| `output csv` 的 `Browse` | 无独立字段 | 可选 | 无 | 打开保存文件窗口，选择最终 CSV 路径。 |
| `keyword batch size` | `keyword_batch_size` | 否 | `--keyword-batch-size` | 每个 Verdi 进程搜索多少个 keyword module。大项目建议调小。 |
| `const trace depth` | `const_trace_depth` | 否 | `-const-trace-depth` | 多层父 port 常数 tie 回溯深度。 |
| `const source fallback` | `const_source_fallback` | 否 | `-const-source-fallback 0/1` | 是否启用源码 fallback 识别父层 net 常数 tie。 |
| `keyword continue on error` | `keyword_continue_on_error` | 否 | `--keyword-continue-on-error` | 单个 keyword 搜索失败时继续处理其他 keyword。 |
| `keyword log instances` | `keyword_log_instances` | 否 | `--keyword-log-instances` | 打印所有 keyword 实例路径。大项目不建议打开。 |

CSV 模式常见输出：

```text
<module>_full.csv
<module>_module_connections.csv
<module>_<keywords>_instances.txt
<output>_boundary.csv
<output>_full_owner.csv
<output>.csv
```

若同一个目标 module 有多个实例，最终 CSV 还可能按实例拆分：

```text
<output>__<inst_full_name>.csv
```

## GUI: Raw Trace

`Raw Trace` 页签调用底层命令：

```bash
./npi_trace.sh ...
```

| GUI 项 | 配置字段 | 是否必填 | 命令参数 | 含义 |
| --- | --- | --- | --- | --- |
| `full trace csv` | `raw_full_output` | 是 | shell 重定向 `>` | 原始完整 trace CSV 输出路径。GUI 运行时会把 `npi_trace.sh` 的 stdout 写入这个文件。 |
| `full trace csv` 的 `Browse` | 无独立字段 | 可选 | 无 | 打开保存文件窗口，选择完整 trace CSV 文件。 |
| `module boundary csv` | `raw_module_output` | 否 | `-module-out` | module 边界 trace CSV。为空时底层脚本使用默认名 `<module>_module_connections.csv`。 |
| `module boundary csv` 的 `Browse` | 无独立字段 | 可选 | 无 | 打开保存文件窗口，选择 module 边界 CSV 文件。 |
| `srcfile deprecated` | `srcfile` | 否 | `-srcfile` | 旧参数，已废弃。当前端口方向通过 NPI API 获取，一般不用填写。 |
| `srcfile deprecated` 的 `Browse` | 无独立字段 | 可选 | 无 | 打开文件选择窗口，选择旧版源码文件参数。 |
| `const trace depth` | `const_trace_depth` | 否 | `-const-trace-depth` | 多层父 port 常数 tie 回溯深度。 |
| `const source fallback` | `const_source_fallback` | 否 | `-const-source-fallback 0/1` | 是否启用源码 fallback 识别常数 tie。 |

## GUI 命令、按钮和日志

| GUI 项 | 含义 |
| --- | --- |
| `Command Preview` | 根据当前参数实时生成最终命令。必要参数缺失时显示 `incomplete parameters: ...`。 |
| `Generate Command` | 手动刷新命令预览。 |
| `Run` | 在工具目录中启动当前模式对应的底层脚本。GUI 会把自身 Python 通过 `PYTHON_BIN` 传给子脚本，避免误用 Python 3.6。 |
| `Stop` | 终止当前由 GUI 启动的子进程。没有任务运行时按钮禁用。 |
| `View Result` | 打开内置结果查看器。若主输出不存在，会尝试打开同名前缀的拆分输出，例如 `out__subsys_*.xlsx` 或 `out__<inst>.csv`。 |
| `Export Config` | 将当前 GUI 参数保存为 JSON 文件。 |
| `Load Config` | 从 JSON 文件恢复 GUI 参数。加载时会暂停逐项刷新，全部设置完成后统一刷新命令预览。 |
| `Run Log` | 显示底层脚本 stdout/stderr。Raw Trace 模式下，完整 trace stdout 写入 `full trace csv`，界面日志主要显示 stderr 和运行状态。 |

## GUI 结果查看器

点击 `View Result` 后打开 `Result Viewer` 窗口。

| GUI 项 | 含义 |
| --- | --- |
| `File` | 当前要查看的 CSV/XLSX 文件路径，可手动修改。 |
| `Browse` | 选择 CSV、XLSX 或 XLSM 文件。 |
| `Open` | 打开 `File` 输入框中的路径。 |
| `Sheet` | 仅 XLSX/XLSM 生效，用于切换 worksheet。CSV 没有 sheet，此项禁用。 |
| 表格区域 | 按行列显示 CSV/XLSX 内容，带横向和纵向滚动条。 |
| 表格单元格 | 长内容会自动换行并截断到若干行，避免一行过长。点击单元格会弹出完整内容窗口。 |
| `Cell Content` | 显示被点击单元格的完整文本，适合查看和复制长信号名。 |
| 状态栏 | 显示当前文件、行数或错误信息。 |

## GUI 配置 JSON 字段

`Export Config` 保存的 JSON 包含以下字段。`trace_gui_demo_xlsx.json` 是可直接加载的示例。

| JSON 字段 | GUI 对应项 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- | --- |
| `version` | 无直接控件 | integer | `1` | 配置文件版本号。 |
| `mode` | 运行模式 tab | string | `xlsx` | `xlsx`、`csv` 或 `raw`。 |
| `lib` | `KDB/elab++` | string | 空 | KDB 路径。 |
| `module` | `module` | string | 空 | 目标 module 定义名列表。 |
| `keywords` | `keywords` | string | 空 | 过滤 module 定义名列表。 |
| `ports` | `ports` | string | 空 | 端口列表。 |
| `template` | `template` | string | 空 | XLSX 模板路径。 |
| `xlsx_output` | `output xlsx` | string | 空 | XLSX 反标输出路径。 |
| `sheet` | `sheet` | string | 空 | worksheet 名。 |
| `workdir` | `workdir` | string | 空 | 中间文件目录。 |
| `subsystem_level` | `subsystem level` | string/integer | `0` | 按实例路径前 N 层拆分 XLSX 输出。 |
| `stream` | `stream` | boolean | `true` | XLSX 模式是否启用流式聚合。 |
| `no_params` | `no params` | boolean | `false` | 是否跳过 parameter 采集。 |
| `strict_params` | `strict params` | boolean | `false` | parameter 采集失败是否中断。 |
| `keep_workdir` | `keep workdir` | boolean | `false` | 兼容旧参数，中间文件当前默认保留。 |
| `regcombo_as_keyword` | `RegCombo as keyword` | boolean | `false` | 是否把 `RegCombo` 端点视为 keywords 命中。 |
| `match_cache_size` | `match cache size` | string/integer | `200000` | stream 模式实例匹配缓存大小。 |
| `keyword_batch_size` | `keyword batch size` | string/integer | `8` | 每个 Verdi 进程搜索多少个 keyword module。 |
| `keyword_continue_on_error` | `keyword continue on error` | boolean | `false` | keyword 搜索失败是否继续。 |
| `keyword_log_instances` | `keyword log instances` | boolean | `false` | 是否打印每个 keyword 实例路径。 |
| `const_source_fallback` | `const source fallback` | boolean | `true` | 是否启用源码 fallback 识别常数 tie。 |
| `const_trace_depth` | `const trace depth` | string/integer | `16` | 父 port 常数递归回溯深度。 |
| `csv_output` | `output csv` | string | 空 | CSV Filter 输出路径。 |
| `raw_full_output` | `full trace csv` | string | 空 | Raw Trace 完整 CSV 输出路径。 |
| `raw_module_output` | `module boundary csv` | string | 空 | Raw Trace 边界 CSV 输出路径。 |
| `srcfile` | `srcfile deprecated` | string | 空 | 旧源码参数，一般不用。 |

## GUI 示例配置

加载示例配置：

```bash
./trace_gui.sh
```

然后在 GUI 中点击：

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
  -const-trace-depth 4
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
  -const-trace-depth 4
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
  -const-trace-depth 4
```

说明：

- `--stream`：Python 端边读 CSV 边聚合，降低运行期运存。
- `--keyword-batch-size 1`：每次只让 Verdi 搜索一个 keyword module，最稳但最慢。
- `-const-source-fallback 0`：避免读取和解析大源码文件。
- `-const-trace-depth 4`：限制父 port 回溯深度，避免过多 NPI 查询。
- 默认关闭 `--keyword-log-instances`，减少大项目日志 IO。

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

3. 多层父模块 port 透传后在更上层 tie 常数：

```text
Child.a <- Parent0.p0 <- Parent1.p1 <- 1'b0
```

这类依赖 NPI high-side connection 递归，深度由 `-const-trace-depth <N>` 控制。

## Loader Assign Fanout 检测

有些设计中，目标 output 端口 high-side 连接到父层信号 `A`，再由连续赋值切片分发：

```verilog
assign B = A[10:0];
assign C = A[20:11];
```

如果 `B` 或 `C` 连接到 `-keywords` module 的实例端口，工具会用 NPI 的 assign fanout 追踪补充 loader 端点，不依赖源码 fallback。

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

bash -n annotate_trace_xlsx.sh trace_and_filter.sh npi_trace.sh trace_gui.sh
python3 -m py_compile annotate_trace_xlsx.py filter_trace.py find_instances_batched.py trace_gui.py

./annotate_trace_xlsx.sh \
  -template multi_module_trace_template.xlsx \
  -output vm_multi_kw_module_annotated.xlsx \
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
  2>&1 | tee vm_multi_kw_module_annotate.log
```

检查输出：

```bash
ls vm_multi_kw_module_annotated__subsys_*.xlsx
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

### GUI 启动提示 `No module named tkinter`

当前 Python 没有安装 `tkinter`。安装系统包，或用 `PYTHON_BIN=/path/to/python3 ./trace_gui.sh` 指定带 tkinter 的 Python。

### GUI 能不能不用？

可以。GUI 只是包装器，传统命令行入口 `annotate_trace_xlsx.sh`、`trace_and_filter.sh`、`npi_trace.sh` 仍然可直接使用。

### 为什么主 CSV 中有 `Always/Combo/RegCombo/_ExprInst__`

这是 Verdi NPI trace 的内部节点。完整 trace 会穿过 module 边界，可能返回过程块、表达式实例、组合逻辑节点或存储节点。需要看端口边界连接时，优先看 `*_module_connections.csv`。

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
