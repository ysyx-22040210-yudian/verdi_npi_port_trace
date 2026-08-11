# 公共 kdebug 后端迁移说明

本文描述端口追踪工具从“业务脚本直接执行 Verdi/NPI Tcl”迁移到公共 kdebug JSON API 后的实际契约。它是迁移期说明；命令行、CSV 和 XLSX 用户接口继续保持兼容。

## 1. 执行边界

当前设计访问只允许经过 `kdebug_backend.py` 调用公共 CLI：

```text
npi_trace.sh / trace_and_filter.sh / annotate_trace_xlsx.py
  -> kdebug_backend.py
  -> kdebug --json -
  -> module.find_instances
  -> module.inspect or module.inspect_batch
  -> port.trace_batch
```

业务脚本不导入 kdebug 内部 Python/C++ 模块，也不 source `npi_port_trace.tcl`、`npi_find_instances.tcl` 或 `npi_find_module_params.tcl`。公共进程的退出码和 JSON envelope 都是协议的一部分。

## 2. 定位 kdebug

`kdebug_backend.py` 按以下顺序定位可执行文件：

1. 命令行 `--kdebug-bin` / shell 兼容参数 `--kdebug-bin` 或 `-kdebug-bin`。
2. 环境变量 `KDEBUG_BIN`。
3. 本工具目录下的内置 `tools/kdebug`。
4. `$KVERIF_HOME/tools/kdebug`。
5. `PATH` 中的 `kdebug`。

默认不需要安装 KVerif 或设置环境变量。仓库内置 bundle 的布局是：

```text
tools/kdebug
kdebug/kdebug
kdebug/help.txt
kdebug/BUNDLE_MANIFEST.json
kdebug/libexec/kdebug-engine
kdebug/libexec/tcl_engine/*
kdebug/schemas/v1/*
LICENSES/*
```

`kdebug_backend.py` 在执行前校验 manifest 格式、ELF 和 runtime 文件的 SHA-256/大小、schema 数量及三个入口的 POSIX 执行位。bundle 只要存在但不完整、哈希不匹配或不可执行，就返回 `KDEBUG_BUNDLE_INCOMPLETE`、`KDEBUG_BUNDLE_INVALID` 或 `KDEBUG_BUNDLE_NOT_EXECUTABLE`，不会回退到主机上的旧版本。显式配置的路径不可执行时返回 `KDEBUG_NOT_FOUND`，同样不会继续搜索。

`--kdebug-bin` 和 `KDEBUG_BIN` 保留为有意覆盖机制。例如开发者验证另一个构建时可运行：

```bash
KDEBUG_BIN=/home/host/kverif/tools/kdebug ./npi_trace.sh ...
```

随附 ELF 的边界是 Linux x86-64、glibc 2.14+、GLIBCXX 3.4.19+、CXXABI 1.3.2+。Raw Trace/CSV 入口及 engine 需要 Bash 和 Python 3.6+；XLSX/GUI 仍需要 Python 3.8+。ARM64、Alpine/musl、Windows 和 macOS 不能直接运行该 ELF。所有真实设计 action 仍要求目标机有 Verdi/NPI、有效许可证以及兼容的 KDB；bundle 只消除了额外安装 kdebug/KVerif 的要求。准确来源提交、Build ID、哈希和许可证见 `kdebug/BUNDLE_MANIFEST.json`。

## 3. 设计库路径透传

历史接口继续接受：

```text
/path/to/simv.daidir/kdb.elab++
```

公共 kdebug 的兼容字段 `target.daidir` 直接接收：

```text
/path/to/simv.daidir/kdb.elab++
```

适配器保留 `kdb.elab++` 的完整路径，使 kdebug 能以 `debImport -elab` 原生导入；直接传入 `simv.daidir` 时仍使用 `-dbdir`。为兼容旧调用，其他 `.daidir` 内部路径仍向上查找最近的 `.daidir`。路径不存在返回 `KDB_NOT_FOUND`；无法识别为 `.daidir` 或 `.elab++` 目录时返回 `INVALID_KDB_PATH`。本工具仍不接受 filelist 代替 elaborated KDB，也不会在 elab++ 失败后自动回退父目录。

## 4. 批处理策略

端口 trace 只调用：

```json
{
  "action": "port.trace_batch",
  "args": {
    "module": "MSHR",
    "ports": ["io_id[0]", "io_id[7]"],
    "stop_instances": ["top.u_stop"],
    "options": {
      "source_fallback": true,
      "include_full": true,
      "include_boundary": true
    }
  },
  "limits": {
    "max_parent_depth": 16,
    "max_assign_depth": 2,
    "max_expr_depth": 1,
    "max_nodes": 20000,
    "max_edges": 100000,
    "max_api_results": 20000,
    "max_rows": 20000
  }
}
```

目标 module 的全部实例和端口在一趟 kdebug/Verdi 设计动作中处理，一次生成 full 与 boundary 两个 surface。`port.trace_batch` 不可用、协议不匹配或 action 失败时，整次端口 trace 失败；适配器不会退回浅层 `trace.batch`、`trace.driver` 或 `trace.load`。parameter 采集仍优先使用 `module.inspect_batch`，只有这一条非端口路径允许回退到逐实例 `module.inspect`。

`--keyword-batch-size` 仍是本工具对 keyword module 搜索 workload 的分组与二分重试边界，不等同于 `port.trace_batch` 的端口数组。

`args.stop_instances` 是同一趟 loader trace 的完整 cut-set，不能按数量截断，也不能拆成多次 trace 后合并，否则 stop-point 语义会改变。`args.stop_instances` 和 `args.ports` 都没有 4096 项的人为上限，并由一次 `port.trace_batch` 请求完整传递。engine 通过 TSV plan 把两个列表交给 Tcl；Tcl 分别建立 stop 层次前缀索引和 port 名集合，通过哈希查询避免大列表线性扫描。

CLI 提供 `-ports-file` / `--ports-file` 和 `-keywords-file` / `--keywords-file`，避免把大列表展开成单个 shell 参数后触发 Linux `MAX_ARG_STRLEN`。`npi_trace.sh` 支持 ports 文件；`trace_and_filter.sh`、`annotate_trace_xlsx.py` 同时支持 ports 和 keywords 文件。内联值与文件值会合并、按首次出现顺序去重；上层反标调用内部子进程时也使用 list 文件。

## 5. JSON 协议与 fail-closed

每次 action 都检查：

- kdebug 进程退出码必须为 0；
- stdout 必须是 JSON object；
- `api_version` 必须是 `kdebug.v1`；
- 顶层 `ok` 必须为 `true`；
- 返回的 `action` 必须与请求匹配；
- `module`、`requested_ports` 和 `selection_mode` 必须与请求匹配；
- full/boundary row、errors 和 constant evidence 必须符合结构化契约；
- `meta.truncated`、`summary.truncated` 和 `data.truncated` 必须被处理；
- `warnings[]` 必须进入诊断日志。

以下情况不会被解释成无 driver/load：

| 情况 | 兼容结果 |
| --- | --- |
| 请求端口在某个目标实例上不存在 | 记录 `PORT_NOT_FOUND`，该实例/端口不生成 row |
| 常量证据未验证、混有 net 或互相矛盾 | kdebug 抑制常量并发布 `TRACE_LIMIT_REACHED:constant_*` marker |
| 常量 row 缺少 effective evidence / `const_full_path` | 整个 action 失败，不发布新 CSV |
| 截断但结果中没有 `TRACE_LIMIT_REACHED:*` marker | 整个 action 失败，不发布新 CSV |
| 出现 `TRACE_LIMIT_REACHED:row_limit` | 返回 `KDEBUG_ROW_LIMIT_REACHED`，不发布部分 full/boundary CSV；增大 `max_rows` 或设为 `0` 后重跑 |
| row、error、evidence 或 envelope 不合法 | 整个 action 失败，不发布新 CSV |

只有完整 trace 确实没有 endpoint 时才生成 `NO_DRIVER` 或 `NO_LOAD`。CSV 通过同目录临时文件和原子替换发布；失败路径删除临时结果，避免旧文件或半截文件看起来像本次成功结果。

## 6. 常量证据

常量 endpoint 仍以兼容值写入 CSV，例如：

```text
Const:1'b0
Const:1'b1
```

同时在 stderr 或 `-log-file` 指定的日志中输出证据行：

```text
const_driver_source_detail ... \
  evidence_source=kdebug.port.trace_batch \
  const_full_path=top.u0.a<-Const:1'b1 \
  source_file=/path/to/rtl.sv source_line=123 raw_handle=...
```

`evidence_source` 标识公共 action 来源；`const_full_path` 必须与结构化 `provenance.path` 一致，给出用户请求的完整层次信号到归一化常量的路径。只有 `effective=true`、role 为 driver 且 provenance 无条件成立的证据才能支撑 CSV 常量 row。若 kdebug 提供源文件、行号或原始 handle，它们一并记录。

## 7. CSV 兼容契约

迁移不改变上层过滤和 XLSX 聚合所消费的 CSV 表头。

Full trace CSV：

```text
inst_full_name,port_name,port_dir,role,signal_full_name
```

Module boundary CSV：

```text
inst_full_name,port_name,port_dir,role,module_signal_full_name
```

Parameter CSV：

```text
module,inst_full_name,param_name,param_value,param_kind,param_info
```

`filter_trace.py`、`annotate_trace_xlsx.py` 和 GUI 仍读取这些稳定文件。后端 JSON 字段不直接泄露给 CSV/XLSX 消费方。

这些 Python CSV 消费端会把标准库默认 131072 字节字段上限提升到当前平台可接受的最大值。超长层次路径和聚合证据不再因为 Python 默认值而读取失败；这不改变 CSV 表头或字段内容。

`filter_trace.py` 预先建立 keyword instance 及其可见层次后缀的哈希集合，然后只检查每条 signal 的有限层次前缀，避免原来的 `rows x instances` 线性扫描。`TRACE_LIMIT_REACHED:*` 仍作为 fail-closed 证据保留。

XLSX 不是完整证据的无损载体：Excel 单元格有 32767 字符硬上限。反标聚合文本超过该值时会显式截成合法长度，在单元格末尾写入 `XLSX_CELL_LIMIT_REACHED:full_result_in_trace_csv`，并记录 `xlsx_cell_truncated` 日志；完整逐行证据仍位于对应 trace CSV，不能用被截断的 XLSX 单元格替代 CSV 审计。

## 8. 参数映射

以下旧参数名仍由 shell/GUI 接受，以免已有命令立即失效：

- `-const-source-fallback`
- `-const-trace-depth`
- `-assign-trace-depth`
- `-assign-expr-trace-depth`
- `-load-trace-node-limit`
- `-load-trace-edge-limit`
- `-load-trace-api-list-limit`
- `-load-stop-instance-file`
- `-ports-file`
- `-keywords-file`
- `-srcfile`
- `-trace-max-rows`

映射关系为：`const/assign/assign-expr` depth 对应 `max_parent_depth/max_assign_depth/max_expr_depth`，三个 loader limit 对应 `max_nodes/max_edges/max_api_results`，`-trace-max-rows` 对应 `max_rows`，ports 文件合并进 `args.ports`，stop-instance 文件解析为 `args.stop_instances`，keywords 文件用于 `module.find_instances` workload，`-srcfile` 对应 `args.source`。`NPI_TRACE_MAX_ROWS` 默认值为 `20000`，值 `0` 表示不启用全局行预算；其他参数继续读取原有 `NPI_*` 环境变量。

## 9. 扩展性边界

本轮审计没有把所有预算改成无限。删除的是会拒绝合法大设计的固定数量上限；防止递归、fanout 或单次 API 返回失控的资源预算继续保留，并必须给出可观察结果。

| 边界 | 当前契约 |
| --- | --- |
| ports / stop 数量 | 无 4096 项人为上限；单次 action 完整处理，通过 list/plan 文件规避参数长度问题 |
| loader nodes | 默认 `20000`；命中时保留 `TRACE_LIMIT_REACHED:node_limit_*` |
| loader edges | 默认 `100000`；命中时保留 `TRACE_LIMIT_REACHED:edge_limit_*` |
| 单次 loader API list | 默认 `20000`；命中时保留 `TRACE_LIMIT_REACHED:api_list_limit_*` |
| 全局 trace rows | 默认 `20000`；命中时 fail-closed，不发布部分 CSV；`0` 表示不启用 |
| `module.find_instances` / `module.inspect*` rows | 继续使用每次调用 1000000 行的公共 API 资源预算，不把它误当成 ports/stop 数量限制 |
| parent/assign/expression depth | 继续显式配置；不能仅因 depth 计数到 0 就声称截断，只有证明仍有下一跳时才可产生 limit 结论 |
| CSV 单字段 | 提升到平台可接受最大值，不再沿用 Python 默认 131072 字节 |
| XLSX 单元格 | Excel 32767 字符硬上限保留；显式 marker 指向完整 trace CSV |

## 10. 最小验收项

迁移版本至少应验证：

1. 从干净 clone、任意工作目录并清空 `KDEBUG_BIN/KVERIF_HOME/PYTHONPATH` 后，内置 `tools/kdebug --json actions` 和 `schema` 可运行，manifest 哈希、schema tree 和执行位检查通过。
2. 内置 engine 能完成 `session.open` / `session.close`，daemon 不依赖 `kdebug_engine.py` 偶然具有执行位。
3. `kdb.elab++` 原样进入 `target.daidir` 并走 `debImport -elab`；`simv.daidir` 走 `-dbdir`，两者查询结果等价。
4. `port.trace_batch` 一次返回 full/boundary surface；缺失端口记录 `PORT_NOT_FOUND` 且不生成伪 `NO_DRIVER`。
5. 精确 bit 常量不会同时发布 `1'b0` 和 `1'b1`，日志包含 `evidence_source` 和 `const_full_path`。
6. kdebug 非零退出、非法 JSON、`ok=false`、truncated 和 timeout 均不发布半截 CSV。
7. full、boundary、parameter CSV 表头及 XLSX 消费流程与迁移前兼容。
8. 5000 个以上 stop instances 和 ports 分别仍由一次请求完整传入，且 XLSX 全部 module trace 失败时保留首个 kdebug/Verdi 错误。
9. ports/keywords 文件可承载超过单参数长度的集合；50000 个 keyword instances 的过滤走哈希前缀索引，并与旧归属谓词保持语义一致。
10. `row_limit` 命中返回 `KDEBUG_ROW_LIMIT_REACHED`，已有正式 CSV 不被部分结果覆盖；`max_rows=0` 可运行不受该行预算限制的对照。
11. 超过 131072 字节的 CSV 字段可读取；超过 32767 字符的 XLSX 聚合单元格含显式 marker，完整结果可在 trace CSV 中复核。
