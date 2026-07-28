# XiangShan Verdi NPI 压测报告（2026-07-29）

## 环境

- XiangShan：`/root/XiangShan-build`，`kunminghu-v3@5123974942833f8d63672f0c132ec9787e8a650a`
- KDB：`/root/XiangShan-build/build/xverif_xiangshan/kdb/simv.daidir/kdb.elab++`
- KDB 大小：194 MiB，source list 1949 行，构建记录为 `-kdb`、rc=0、0 error、0 warning
- VM：8 vCPU、15 GiB RAM；压测开始时根盘仅余约 2.8 GiB，最终快照余 1.7 GiB
- 工具 pre-fix：`07f4f9669dd22fd15b358184a5b76f6fb3a89337`
- 最终环境、XiangShan commit/dirty status、KDB 大小和无残留 EDA 进程的快照见
  `20260729_post_fix/vm_environment_final.log`

## Pre-fix 结果

| 场景 | 规模 | 耗时 | 峰值 RSS | 结果 |
| --- | ---: | ---: | ---: | --- |
| `Uncache` baseline | 1 instance，3 ports | 1:59.24 | 1,489,220 KiB | rc=0，full/boundary 17/8 行 |
| `ClockGate.E` 常量 | 279 instances | 1:33.47 | 1,466,020 KiB | 940 data rows，10 const groups，0 个 0/1 冲突 |
| 高实例 subsystem stream | `Queue1_BundleMap,LevelGateway,ClockGate` | 30:00 外层超时 | 遗留 Verdi 约 1.36 GiB | rc=124，未完成 |

`ClockGate.E` 中找到 18 条 `const_driver_source_detail` 日志。每条均包含
`evidence_source`、目标实例/端口和 `const_full_path`；直接常量和跨 8 层父端口的
常量链均有证据。

高实例场景暴露出真实超时漏洞：内部命令虽然是 `timeout 360s verdi ...`，但 Verdi
捕获并忽略 TERM 后，`timeout` 会继续等待。外层 30 分钟结束后仍有 Verdi/Novas/Xvfb
进程，且留下 439,828,480 字节 swap 文件、0 字节 full CSV 和 91,216 字节半截 boundary
CSV。手工终止精确 PID 后才释放资源。进程 RSS 和手工终止属于当时的终端现场观察；
半截 CSV、时间和返回码保留在 pre-fix artifact 中。

## 修复

- `npi_trace.sh` 使用后台 `timeout --kill-after=5s`、独立 SID 和可中断 wait；内部超时、
  外层终止或 Ctrl-C 都会扫描并清理整个 Verdi/Novas/Xvfb session。任意非零 Verdi rc
  都失败，不再发布半截 stdout CSV，并删除 temp/boundary/session 输出。
- keyword 实例搜索和 parameter 采集也受 `-verdi-timeout-sec` 约束；POSIX 下按进程组
  TERM，宽限后 KILL。
- 每轮删除固定命名的旧 keyword/parameter/full/boundary 中间文件，失败时删除本轮半截
  文件。
- subsystem 运行前删除旧 base 和旧 `__subsys_*.xlsx`；普通反标也删除旧 base。
- 无拓扑的失败 module 不再复制到每个 subsystem workbook。
- trace 超时、输出缺失和普通失败分别标记为 `TRACE_TIMEOUT`、
  `TRACE_OUTPUT_MISSING`、`TRACE_FAILED:rc=<code>`，不再误报为 `NO_MODULE`。
- GUI 在 `subsystem_level > 0` 时只打开当前输出前缀的 split workbook，不回退旧 base。
- GNU timeout 通过独立 sentinel 与 Verdi 自身的 `124/137` 区分；只有 watchdog 真正触发
  才报告 `TRACE_TIMEOUT`。Verdi 自身退出或 SIGKILL 仍按普通 trace failure 处理。
- XLSX、keyword merged instances 和 errors log 使用同目录临时文件加原子替换；任一
  subsystem workbook 写出失败会回滚本轮已发布的全部 split。

## Post-fix 结果

### 故障注入

最终代码对真实 Verdi 使用 `-verdi-timeout-sec 1`：1.17 秒返回 rc=124；stdout 为 0
字节，boundary、temp、session、timeout sentinel 均不存在，测试后 Verdi/Novas/Xvfb
进程数为 0。

VM 整仓 unittest 为 39/39 通过（18.326 秒）。故障注入覆盖 launcher 忽略 TERM、
leader 正常或非零退出但 child 存活、外层 timeout 先终止 wrapper、Verdi 自身
`exit 124`、SIGKILL 137、stdout 写 `/dev/full`、XLSX 保存中途失败和 subsystem split
回滚。Verdi 自身 124/137 均未误标为 timeout，失败后没有 boundary、temp 或 sentinel
残留。

### 精确 bit 常量

`MSHR.io_id[0]`、`MSHR.io_id[7]`：

- 32 个真实 MSHR 实例，64 个 instance/bit 常量组
- full/boundary 769/449 行（含表头）
- 64 条 `const_driver_source_detail`
- 每条均有 `evidence_source=source_port_connection` 和完整 `const_full_path`
- 同一 instance/bit 出现多个互斥常量的组数：0
- 耗时 2:06.20，峰值 RSS 1,372,208 KiB，rc=0

### Subsystem stream/non-stream

输入模块为 `MSHR,LevelGateway`，keyword 为 `ClockGate`，端口为
`io_id[0],io_id[7],io_interrupt,io_plic_valid`，`subsystem_level=7`。

| 指标 | stream | non-stream |
| --- | ---: | ---: |
| 耗时 | 2:53.74 | 2:41.86 |
| 峰值 RSS | 1,364,444 KiB | 1,364,356 KiB |
| split XLSX | 66 | 66 |
| 可打开 XLSX | 66 | 66 |
| `NO_SUBSYSTEM_INSTANCE` 及历史拼写 | 0 | 0 |
| `NO_MODULE` | 0 | 0 |
| `TRACE_LIMIT_REACHED` | 0 | 0 |
| `NO_TRACE` | 194 | 194 |

66 个 workbook 中，1 个只含 32 个 MSHR 实例，65 个各只含一个 LevelGateway 实例；
不存在跨 subsystem 的空 module 行。194 个 `NO_TRACE` 来自跨 module 的端口并集，例如
LevelGateway 没有 `io_id`，不是 subsystem 实例缺失。

stream 与 non-stream 的文件名集合完全相同，66/66 个 workbook 逐 cell 相同；两条路径
生成的 MSHR/LevelGateway full CSV 的 SHA-256 也分别相同。预置的旧 `result.xlsx` 和
`result__subsys_STALE.xlsx` 均在运行前被删除。

最终 sentinel wrapper 的正常路径再次读取真实 KDB：`Uncache` 单端口 trace 在 40.61
秒内 rc=0，峰值 RSS 1,419,852 KiB，full/boundary 为 7/4 行。最终 keyword runner
在 26.27 秒内找到 279 个 ClockGate 实例，峰值 RSS 1,319,848 KiB，并保持预置的 0600
结果权限；两次运行后 Novas 进程数均为 0，且没有 temp/session/sentinel/batch 文件，预置的旧
keyword output 和 errors log 均被删除。

最终端到端反标 smoke 启用 keyword 搜索、parameter 采集、真实 trace、stream 聚合和
XLSX 原子发布：1:24.90、峰值 RSS 1,419,480 KiB、rc=0。结果 workbook 可重新打开，
包含真实 Uncache 实例和 trace 摘要，并保持预置的 0640 权限。parameter/full/boundary
CSV 均完整，运行后无临时原子文件或 EDA 进程残留。

## 结论

原来的 exact-bit 常量 0/1 混报在真实 XiangShan 的 64 个 MSHR bit 组中未复现；常量
证据路径满足要求。压测确实暴露了超时失效、半截产物和 GUI 误开旧 workbook 三类漏洞，
本轮已修复并完成最终代码上的真实 KDB 回归。特别是大片
`NO_SYSTEM_INSTENCE`/`NO_SUBSYSTEM_INSTANCE` 不再由无拓扑 module 被复制到所有
subsystem 引起；最终 66+66 个 split 中相关 marker 计数为 0。

`subsystem_level` 仍需按期望的层次选择：本测试用 level 7 有意把 65 个 LevelGateway
拆成 65 个文件；生产使用若希望按 PLIC 聚合，应降低 level，避免不必要的文件数放大。

## 证据目录

- Pre-fix：`E:\XIANGSHAN_CPU\verdi_trace_stress\20260729_pre_fix`
- Post-fix：`E:\XIANGSHAN_CPU\verdi_trace_stress\20260729_post_fix`
- 最终 VM 回归：`vm_unittest_final_mode_collision.log`
- 最终 timeout/success：`final_wrapper_timeout_sentinel`、`final_wrapper_success_sentinel`
- 最终 keyword CLI：`final_keyword_mode_release`
- 最终端到端反标：`final_annotate_release`
