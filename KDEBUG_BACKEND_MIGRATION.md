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
3. `$KVERIF_HOME/tools/kdebug`。
4. 本工具目录下的 `tools/kdebug`。
5. `PATH` 中的 `kdebug`。

推荐在 VM 和 CI 中固定版本：

```bash
export KDEBUG_BIN=/home/host/kverif/tools/kdebug
"$KDEBUG_BIN" --json actions
```

显式配置的路径不可执行时返回 `KDEBUG_NOT_FOUND`，不会继续搜索并意外使用另一个版本。

## 3. KDB 路径规范化

历史接口继续接受：

```text
/path/to/simv.daidir/kdb.elab++
```

公共 kdebug 的 `target.daidir` 必须是：

```text
/path/to/simv.daidir
```

适配器会把 `kdb.elab++` 归一到父目录，也接受直接传入 `simv.daidir`，或从其内部路径向上查找最近的 `.daidir`。路径不存在返回 `KDB_NOT_FOUND`；无法归一到 `.daidir` 返回 `INVALID_KDB_PATH`。本工具仍不接受 filelist 代替 elaborated KDB。

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

1. `KDEBUG_BIN` 指向预期版本，`--json actions` 包含所需 action。
2. `kdb.elab++` 和 `simv.daidir` 两种 `-lib` 写法归一到相同 target。
3. `port.trace_batch` 一次返回 full/boundary surface；缺失端口记录 `PORT_NOT_FOUND` 且不生成伪 `NO_DRIVER`。
4. 精确 bit 常量不会同时发布 `1'b0` 和 `1'b1`，日志包含 `evidence_source` 和 `const_full_path`。
5. kdebug 非零退出、非法 JSON、`ok=false`、truncated 和 timeout 均不发布半截 CSV。
6. full、boundary、parameter CSV 表头及 XLSX 消费流程与迁移前兼容。
