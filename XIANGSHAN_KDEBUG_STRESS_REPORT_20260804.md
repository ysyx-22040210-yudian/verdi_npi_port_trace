# XiangShan kdebug 后端迁移压测报告（2026-08-04）

## 结论

端口追踪工具的设计访问已从业务脚本直接调用 Verdi/NPI Tcl，迁移为只通过公共
`kdebug` JSON action 访问 KDB。端口主路径只调用 `port.trace_batch`，不会在 action
缺失、协议异常或截断时回退到浅层 `trace.driver`/`trace.load`。

在真实 XiangShan KDB 上，原问题“同一精确 bit 同时被 `1'b0` 和 `1'b1` 驱动”未再
出现。64 个 MSHR instance/bit 常量组均只有一个确定值，并且每个发布到 CSV 的常量
driver 都有 `port_path`、`const_full_path`、`provenance.path` 和真实 RTL 源文件证据。
常量与真实 net 混合时按 fail-closed 处理，不发布伪常量。

之前大片 `NP_SYSTEM_INSTENCE`、`NO_SYSTEM_INSTENCE`、`NO_SUBSYSTEM_INSTANCE`
及历史拼写 marker 在最终 subsystem 产物中均为 0。跨 module 端口并集产生的
`NO_TRACE` 共 194 个，这是目标 module 本身没有该端口，不是 subsystem 实例缺失。

## 环境

- VM：`root@192.168.31.116`，8 vCPU、15 GiB RAM
- XiangShan：`/root/XiangShan-build`，`kunminghu-v3@5123974942833f8d63672f0c132ec9787e8a650a`
- KDB：`/root/XiangShan-build/build/xverif_xiangshan/kdb/simv.daidir`，约 904 MiB
- 工具分支：`codex/kdebug-trace-backend`
- kdebug 分支：`codex/kdebug-trace-backend`
- VM 证据：`/root/port-trace-kdebug-codex/vm_stress_kdebug_final_20260804`
- Windows 镜像：`E:\XIANGSHAN_CPU\verdi_trace_stress\20260804_kdebug_final`

XiangShan 工作树包含已有生成文件和本地改动；本次没有修改 XiangShan RTL。压测只读取
现有 KDB。

## 迁移内容

- kdebug 新增公共 `port.trace_batch`，一次 KDB 导入生成 full/boundary 两个 surface。
- `module.inspect_batch` 用于批量 parameter/instance inventory，减少重复 Verdi 启动。
- 迁移旧 trace 深度、节点、边、API list、row budget、stop-instance 和 source fallback
  参数，不改变上层 CSV 表头和 XLSX 消费契约。
- 精确 bit 先验证位宽和 handle；越界 bit 返回 `PORT_NOT_FOUND`，不生成伪
  `NO_DRIVER` 或常量 row。
- 常量 row 必须由 `effective=true` 的完整证据支撑。证据不足、0/1 冲突或与真实 net
  混合时抑制常量并报告结构化错误。
- `max_rows` 对 full/boundary 独立生效；超限时在预算内保留
  `TRACE_LIMIT_REACHED:row_limit` marker。
- full/boundary CSV 双文件事务式发布，第二个发布失败会回滚第一个。
- shell、Python、C++ 三层均保留清理宽限，并用精确 run token 清理 double-fork、
  新 session 的 Verdi/Novas/Xvfb 后代。

## 真实 KDB 结果

### MSHR 精确 bit 与常量证据

请求 `MSHR.io_id[0]` 和 `MSHR.io_id[7]`，共 32 个 MSHR 实例。

| 指标 | 第 1 轮 | 第 2 轮 |
| --- | ---: | ---: |
| full data rows | 768 | 768 |
| boundary data rows | 448 | 448 |
| 常量 driver 组 | 64 | 64 |
| 有效常量证据 | 64 | 64 |
| 耗时 | 42.91 s | 41.90 s |
| 峰值 RSS | 837,604 KiB | 836,508 KiB |

值分布严格符合 `mshrs_N` 的索引：`io_id[0]` 为 16 个 0、16 个 1；`io_id[7]`
为 32 个 0。两轮排序后摘要完全相同：

- full：`ed5a845eae973266e0019ccbff20eae3add488fc9cee177ce6f6b5c42d39eae6`
- boundary：`3e86183be63acb32567c1032ef7f5d9810deb9ce947a8efa4655c1b705db71b1`

日志证据示例：

```text
port_path=tb_top.sim.cpu.l_soc.core_with_l2.l2top.inner_l2cache.slices_0.mshrCtl.mshrs_0.io_id[0]
const_full_path=tb_top.sim.cpu.l_soc.core_with_l2.l2top.inner_l2cache.slices_0.mshrCtl.mshrs_0.io_id[0]<-Const:1'b0
source_file=/root/XiangShan-build/build/rtl/MSHRCtl.sv
evidence_source=kdebug.port.trace_batch
```

### ClockGate 全端口

对 279 个 `ClockGate` 实例追踪全部 `CK/E/Q/TE` 端口：

- full/boundary：6679/2749 data rows
- full-only endpoint：3930；boundary-only endpoint：0
- 有效常量：2，均有完整证据
- 发现 8 组“常量 + 真实 net”混合 driver，全部报告
  `CONSTANT_DRIVER_AMBIGUOUS` 并抑制常量
- row-limit marker：0
- 耗时 4:21.88，峰值 RSS 1,281,012 KiB，rc=0

### 资源与错误边界

| 场景 | 结果 | 耗时 | 峰值 RSS |
| --- | --- | ---: | ---: |
| `max_rows=10` | full/boundary 各 10 行，各 1 个 row-limit marker，rc=0 | 29.28 s | 943,196 KiB |
| `io_id[999]` | 32 个 `PORT_NOT_FOUND`；两张 CSV 仅表头 | 9.90 s | 804,732 KiB |
| MSHR parameters | 32/32 `INSTANCE_INVENTORY`，rc=0 | 13.49 s | 794,188 KiB |
| trace 1 s timeout | rc=124；无 CSV、进程、token、tmp 残留 | 4.30 s | 142,708 KiB |
| parameter 1 s timeout | rc=124；无 parameter、进程、token 残留 | 4.20 s | 98,476 KiB |

最终现场复核为 0 个工具进程、0 个 `NPI_KDEBUG_RUN_TOKEN` 进程和 0 个
`/tmp/port-trace-kdebug.*` 私有目录。

## XLSX 端到端

输入模块为 `MSHR,LevelGateway`，keyword 为 `ClockGate`，端口并集为
`io_id[0],io_id[7],io_interrupt,io_plic_valid`，`subsystem_level=7`。

| 指标 | stream | non-stream |
| --- | ---: | ---: |
| 耗时 | 1:36.55 | 1:39.46 |
| 峰值 RSS | 854,668 KiB | 854,620 KiB |
| split XLSX | 66 | 66 |

两种模式生成的文件名集合摘要相同；四份 MSHR/LevelGateway full/boundary CSV 的
SHA-256 分别相同。最终 Uncache 非 split workbook 用时 31.71 秒、峰值 RSS
950,624 KiB，parameter/full/boundary CSV 完整。

最终使用 `@oai/artifact-tool` 对 132 个 split workbook 和 1 个 Uncache workbook
执行独立 QA：

- 133/133 workbook 成功导入，133/133 sheet 成功渲染；PNG 为
  55,919 到 294,751 字节，无空白渲染。
- 公式错误扫描为 0。
- 66/66 对 stream/non-stream workbook 的 values、formulas、computedStyle 完全相同。
- 每种模式各有 194 个 `NO_TRACE`；按 pair 去重后仍为 194。
- `TRACE_LIMIT_REACHED`、`NO_SYSTEM_INSTANCE`、`NO_SYSTEM_INSTENCE`、
  `NO_SUBSYSTEM_INSTANCE`、`NO_SUBSYSTEM_INSTENCE`、`NP_SYSTEM_INSTENCE` 均为 0。
- Uncache `A2:D2` 可读；D2 含 5 个不同的真实 `driver_actual`，没有退化为旧的单
  driver 文本。

## 回归

- 主工具 Windows：59 tests，35 passed、24 个 POSIX 条件 skip；rc=0。
- 主工具 VM Python 3.8：59 tests，45 passed、14 个已废弃 legacy fault-injection skip；rc=0。
- 主工具 VM Python 3.6 focused：20/20 passed，覆盖 kdebug 协议、CSV 事务和
  double-fork/run-token 清理。
- kdebug VM 干净构建 `make test-contract`：13 infra tests、228 schemas、223 examples、
  10 个 C++ unit executables、109 runtime action specs、55 contract tests 全部通过；
  action coverage `109/108`、`missing=0`，rc=0。
- 两个仓库 `git diff --check` 均通过。

VM 系统默认 Python 3.6 的整仓 discover 还会受到仓库既有 Python 3.7+
`from __future__ import annotations` 和缺少 `openpyxl` 的限制；本次迁移相关的 20 项
focused 测试在 3.6 已全部通过，完整套件以配置好的 Python 3.8 环境为准。

## 证据目录

- `mshr1/`、`mshr2/`：两轮精确 bit、常量值和证据路径
- `clockgate_all/`：279 实例全端口与 ambiguity suppression
- `row_limit/`、`invalid_bit/`：预算和非法 bit 边界
- `params/`：批量 parameter inventory
- `timeout_trace/`、`timeout_params/`：超时、退出码和清理
- `subsystem_stream/`、`subsystem_nonstream/`：66 + 66 个 split workbook
- `final_xlsx/`：Uncache 最终非 split workbook
