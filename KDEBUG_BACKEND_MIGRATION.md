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
- `-srcfile`
- `-trace-max-rows`

映射关系为：`const/assign/assign-expr` depth 对应 `max_parent_depth/max_assign_depth/max_expr_depth`，三个 loader limit 对应 `max_nodes/max_edges/max_api_results`，`-trace-max-rows` 对应 `max_rows`，stop-instance 文件解析为 `args.stop_instances`，`-srcfile` 对应 `args.source`。`NPI_TRACE_MAX_ROWS` 是新增的环境变量，默认值为 `20000`；其他参数继续读取原有 `NPI_*` 环境变量。

## 9. 最小验收项

迁移版本至少应验证：

1. 从干净 clone、任意工作目录并清空 `KDEBUG_BIN/KVERIF_HOME/PYTHONPATH` 后，内置 `tools/kdebug --json actions` 和 `schema` 可运行，manifest 哈希、schema tree 和执行位检查通过。
2. 内置 engine 能完成 `session.open` / `session.close`，daemon 不依赖 `kdebug_engine.py` 偶然具有执行位。
3. `kdb.elab++` 原样进入 `target.daidir` 并走 `debImport -elab`；`simv.daidir` 走 `-dbdir`，两者查询结果等价。
4. `port.trace_batch` 一次返回 full/boundary surface；缺失端口记录 `PORT_NOT_FOUND` 且不生成伪 `NO_DRIVER`。
5. 精确 bit 常量不会同时发布 `1'b0` 和 `1'b1`，日志包含 `evidence_source` 和 `const_full_path`。
6. kdebug 非零退出、非法 JSON、`ok=false`、truncated 和 timeout 均不发布半截 CSV。
7. full、boundary、parameter CSV 表头及 XLSX 消费流程与迁移前兼容。
