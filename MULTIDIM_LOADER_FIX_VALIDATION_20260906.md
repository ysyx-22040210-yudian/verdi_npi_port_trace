# 多维 driver / loader 补齐与 VM 验证（2026-09-06）

本报告接续 `TRACE_FIX_VALIDATION_20260906.md`，针对其中明确保留的
`TRACE_INCOMPLETE:exact_load` 多维负载缺口。仍为直接 Verdi/NPI 后端，未切换 kdebug。
本轮在已有未提交修改之上增量修复，没有撤销之前修改，没有 Git 提交或推送。

## 本轮定位到的五个问题

1. **把 netlist 序号当成 RTL 下标。** 真实 VM 探针中，`a[0][1]` 的 1-bit handle
   名称是 `a[1:0]#[2]`。此前按字符串规范化会变成 `a[2]`，精确校验据此拒绝。
   NPI 的 actual-name API 则返回正确的 `a[0][1]`。因此上轮称为“旧 Verdi 不能追踪”
   过于笼统；当前库在该场景有正确逐位对象，缺的是工具的身份转换。
2. **名字解析快捷接口存在实际适用边界。** 文档 2860 页明确列出多维切片的限制。
   新实现不再只依赖该接口：可从 structural 声明取得 LSB 位偏移，再用 netlist 自己的
   `npiNlLeft/npiNlRight` 计算 native index，由 `npi_nl_handle_by_index` 取得精确对象。
   最后重新验证其 1-bit 宽度和完整实际名称；不能直接接受整个总线。
3. **unpacked 数组的 `npiSize` 是元素数。** 如 `input [3:0] a [1:0]`，本机 structural
   NPI 返回 2，而 netlist 总宽是 8。新增按真实数组元素递进的类型/位宽处理，避免把
   2 个元素误当成 2 bit，也避免递归 ElemTypespec 时重复累计 packed 维度。
4. **零负载返回记录存在 C bridge / Tcl 示例差异。** 本机桥接层返回 count=0 和 `{src}`，
   并不是两项的 `{src {}}`。严格校验首次将其拒绝；现仅兼容这种省略空 load list 的形式，
   不放松对 source 的精确身份、1-bit 宽度和非空返回数量的检查。
5. **多维常量连接的 native 端口名字可能仅保留外层范围。** `a[1:0][3:0]` 的 NL 名字可能
   是 `a[1:0]`。此前猜测 `a` 或完整 suffix 会错过 `'1` 与 `1'b1` 的 KDB 原始拼写。
   现从已校验 owner / 总宽的 NL 声明读取真实 native 名字，再查询其 high-connection literal；
   不通过当前源码猜测上下文填充语义。

## 实现与安全条件

- `npi_elaborated.tcl` 新增精确 bit 身份与声明索引路径，driver 和 loader 共用。
- 实际名称使用完整 name vector，不使用只返回拼接第一项的快捷名字掩盖多对象结果。
  仅在来源对象确实为 1 bit、完整 owner 一致、structural 对象存在且为 1 bit 时还原多维名字。
- bit-load 非空响应必须恰好对应查询 source bit；别的位、宽对象、异常返回值均保留显式诊断。
  正常的“没有负载”来自已经校验的精确 1-bit handle，API 返回 count=0、正确的 source bit。
  本机 C bridge 对无负载返回 `{src}`，而非参考 Tcl 的 `{src {}}`；兼容这种省略空 load list
  的写法，但仍拒绝没有 source 记录的响应。
- 跨层、连续 assign 和拼接继续使用已有的精确 handle 遍历。computed 节点仍为语义终点。
- `TRACE_INCOMPLETE` 机制没有被删除：真正的 API 错误、未覆盖的声明形状、预算耗尽仍必须暴露。
  本轮通过条件是实际 sink 集合正确且无诊断，不是简单不打印该字符串。
- `stress/driver_diagnostics.py` 已把原 packed 用例的预期从“显式未支持”升级为
  “driver 和精确 reduction loader 都成功”，不再接受旧行为。

文档依据为 `D:/VMshare/CPU_CORE/ysyx/VC_APPS_NPI.pdf`：391–394 页 indexed handle、
2857–2860 页名字解析边界、2881 / 2886–2887 页逐位 load/source 返回结构、
3151–3156 页 actual name 与完整 name vector。均与 VM 实际对象探针交叉检查。

## 测试设计

VM：`root@192.168.31.116`，Verdi/VCS `O-2018.09-SP2`。
代码和新增 RTL/KDB/结果位于 `/home/trace-multidim-20260906`，不在 VMware 共享目录构建。
XiangShan 使用原有 KDB，不复制、不重建，也不修改其 RTL。所有 EDA 场景串行运行。

### 九种声明形状矩阵

`stress/multidim_loaders.py` 覆盖：二维降序、二维升序、负索引/混合方向、三维、单元素维度、
unpacked + packed、unpacked + 两维 packed、两维 unpacked + packed、纯 unpacked 标量数组。

- 对每个形状测试所有完整 bit、整个数组、部分子向量、适用时的多维 part-select。
- 内部具名与位置式消费者、跨层 pass 模块、拼接重排或数组逐 bit assign、parent-scope 消费者。
- packed 场景的 high-side 输入和输出均使用子向量拼接，另覆盖内部重排后跨模块传播。
- 精确核对 full 和 boundary 的最终 sink 集合，不允许相邻 bit 或其他实例混入。
- 同时核对 driver 最终刺激位索引和输出返标 keyword 的命中/不命中。
- VCS 先跑 walking-one 仿真断言，预期来自独立的连接规格，不由 trace 结果生成。
- 同一 KDB 的源码可见、隐藏、故意修改连接三种状态必须保持同样正确的结果，结束后恢复原源码。

### 底层 fallback 与规模测试

- `stress/probe_multidim_mapping.tcl` 强制名字解析入口返回空，验证真实 KDB 上的声明索引 fallback。
- `stress/multidim_fanout.py` 使用不同声明方向/起始索引的三维输出与父级总线，检查大规模 sink 精确集合、
  未使用 bit 的 `NO_LOAD`、stream/nonstream XLSX 正反向匹配及长证据不丢失。
- `stress/multidim_constants.py` 对 `'1`、`'0`、`1'b1`、`1'sb1`、`'x`、`'z` 和混合位型逐位检查；
  同时核对精确 reduction loader 位号和 KDB 常量证据（全路径、源文件/行、RHS offset、formal width）。

## 最终结果

以下为结果 JSON / 内容断言实际通过的记录，而非仅根据 shell 退出码判断。

| 场景 | 实测结果 |
| --- | --- |
| Windows 单元测试 | 89 项：70 通过、19 项 POSIX 平台测试跳过；1.865 秒 |
| VM 单元测试 | 89 / 89 通过，无跳过；19.624 秒 |
| 最终九形状矩阵 `matrix_final` | 27 / 27 场景、4,440 项检查通过；共 56,232 条 full 数据行；trace 累计 439.693 秒 |
| 强制 indexed fallback `probe/forced_mapping_final.log` | 162 个真实 input/output bit 全通过；名字快捷接口被强制禁用 |
| 多维常量 `constants_final_r3` | visible/hidden 各 56 组；共 112 组值、精确 loader、全路径来源证据通过；trace 累计 5.997 秒 |
| 最终快照直接扇出 `fanout8192_final_depth0` | 8,192 个负载 / 8,195 个 module 实例、40,962 项检查通过；trace 43.465 秒；stream / nonstream XLSX 分别 41.954 / 41.998 秒；无负载位为 `NO_LOAD`，全部 8,192 sink 全路径在 nonstream 证据中保留 |
| 原有 driver 回归 `semantics_final` | 9 / 9 场景、1,056 项查询检查通过；936 组常量的完整来源证据全部通过；trace 累计 36.499 秒 |
| 错误与参数 `diagnostics_final_r2` | 缺失/越界按预期 rc=1 且不发布半成品；16 项负索引、16 项多维 driver/load 和 8 项子向量正确；56 有效 / 168 不适用查询独立保留；10,001 模块参数请求成功 |
| 四态和真实冲突 `four_state_final` | visible/hidden 各 16 项四态/符号扩展查询通过；真正的 0/1 多驱动仍保留 `ERROR:CONST_DRIVER_CONFLICT:0,1`，拼接截断只返回 0 |
| XiangShan `xiangshan_final` | 5 / 5 检查通过；MSHR 32 实例、256 组常量（0=192 / 1=64）、50,000 stop instances 和每组来源证据正确；Uncache 完整 driver 链正确；MSHR / LevelGateway 两种 subsystem XLSX 逐 cell 相同；预期超时 rc=124，无半成品/进程残留 |
| XiangShan `clockgate_final` | 279 实例、837 项 driver 查询与独立 RTL 预期一致；37.319 秒，峰值 RSS 1,368,636 KiB |
| 全功能 `all_features_final_r2` | 从 KDB 构建开始完整重跑，Raw Trace / CSV 过滤 / XLSX 与全部内容断言通过；117.26 秒，峰值 RSS 222,308 KiB；两份返标 workbook 为 `6×37` / `5×37` |

XiangShan 场景的原始 `/usr/bin/time -v` 数据：

| 场景 | 时间 | 峰值 RSS（KiB） |
| --- | --- | --- |
| MSHR 常量 / 大 stop-set | 36.18 秒 | 1,355,348 |
| Uncache XLSX | 80.73 秒 | 1,373,636 |
| subsystem stream | 82.79 秒 | 1,349,176 |
| subsystem nonstream | 79.36 秒 | 1,349,200 |
| 预期 watchdog 超时 | 1.18 秒 | 10,564 |

subsystem 对照为 MSHR=32、LevelGateway=65，每种模式两份 workbook，共 194 个预期的
`NO_TRACE` 单元格（不同模块的端口列并集），不含 `NO_SYSTEM_INSTENCE` 等错误占位。
watchdog 场景故意设置一秒超时，其 rc=124 / Qt client killed 日志是负例预期，不是未处理失败。

收尾再次检查：所有 Shell 语法、Python 编译通过；Windows 89 项单元测试再次通过
（70 通过 / 19 POSIX 跳过，1.847 秒）；多维/driver/四态源码均恢复原文本，没有 `.hidden`
遗留；当前 VM 没有 EDA 进程、临时 session 或临时 trace CSV 遗留，`TMPDIR` 为空。

### 最终核心实现快照

Windows 与 VM 的核心代码哈希一致；以下是工作树快照，不冒充新的 Git commit。

| 文件 | SHA-256 |
| --- | --- |
| `npi_elaborated.tcl` | `b81eca54044ccb843951f73c2fad897ab82e6aa0e595f63f63931f2ea40f3cff` |
| `npi_port_trace.tcl` | `f625806bedd3d670640bf4f6e56b2197c1b5a5a15b2ff0f15a0b34e14e6aa591` |
| `trace_support.tcl` | `90fc5980976ee301361f9af1c431e041ac854aeb75836a8416f5d942ae25fc84` |
| `annotate_trace_xlsx.py` | `3bd656ccf684c23e35e61fd684ea637050b82a061d574a8f483d7fbefa2faea6` |

### 本轮中间失败记录

- `arrays1` 的元素数/bit 数混淆、首次强制 fallback 的未初始化 scope，均是真实实现缺口，已修复。
- `fanout64` / `fanout64_r2` 的零负载返回校验失败推动了 `{src}` 的严格兼容；不计为通过。
- `constants_final` 捕获多维端口 `'1` / `1'b1` 的 native 端口名缺口；以修复后的
  `constants_final_r3`（含新增 provenance 与精确 loader 断言）为最终依据。
- `arrays2` 以及 `fanout64_r3` 后段分别为测试器预期/默认 worksheet 名字问题；修正后重跑，
  没有把之前的失败当成通过。`diagnostics_final` 则硬编码了旧 KDB 的 `/XorRedu.a`；
  新 KDB 使用 `/Combo.I0`。校验器现只接受这两个已验证拼写，仍严格检查 owner、唯一性和位号；
  重跑目录为 `diagnostics_final_r2`。
- `all_features_final` 完成 CSV/XLSX 后，旧断言只接受 `/Combo.`，却在新 KDB 得到
  `TAFSubsystem(@1)/Always15#SigOp15:109-109/And.OL_ternary_stop_net`。对照第 109 行 RTL，
  这是同一条三目赋值的计算终点，未误追到 keyword 或常量。测试器增加此精确 generated
  output 拼写，并加强为两个目标实例分别检查、XLSX 必须保留对应 CSV 终点；没有修改生产实现。
  首次失败的 CSV/XLSX/RTL/测试器保存在 `all_features_first_failure.tgz`，完整流程随后重新执行。
- 已完成的 depth=12 大规模测试 `fanout8192_final`：8,192 负载 / 8,195 module 实例、
  40,962 项检查、stream/nonstream XLSX 全通过，trace / stream / nonstream 分别为
  279.983 / 43.777 / 293.788 秒。它的 `npi_elaborated.tcl` 哈希为
  `17b1043a6bbb44fe7a2d8a675a4105982ac4ef26adbe33ffc9715c2e508efd7e`，早于最后的多维 literal
  名称补丁；loader 实现未再改变，但不能说它使用了最终文件快照。

depth=0 与 depth=12 的时间差不能当作同参数性能优化：前者停止在 assign 边界，后者继续展开。
最终九形状矩阵仍使用 assign depth=12 / expression depth=4 验证跨层与重排传播。

### 可复现入口与产物

完整运行方式见 [VM_STRESS_MATRIX.md](VM_STRESS_MATRIX.md) 的“多维 loader 专项回归”。
VM 结果根目录为 `/home/trace-multidim-20260906`；所有表中目录均相对于该根目录。
源码可见性测试结束时恢复原文件；原有 `/root/trace-fix-20260906` 快照保持不变。
按照 `xiangshan-runbook` 的原生文件系统和复用 KDB 要求部署，避免在共享目录构建或额外复制大型设计。
本地对应产物根目录为 `D:/VMshare/CPU_CORE/ysyx/trace-fix-artifacts/20260906/multidim`。
`completed_multidim_artifacts.tgz` 已复制并校验 SHA-256 为
`fd2c59561b6f0243e36e20575cf3c67afad45d5036c089e96de39e921a916759`，包含 434 个归档条目；
未包含任何 `build` / KDB 目录。
真实 XiangShan、ClockGate、全功能回归及本轮测试用工具快照另存为
`integration_artifacts.tgz`，校验值见同目录的 `integration_artifacts.tgz.sha256`。

## 适用边界

此修复补齐的是已知固定尺寸、多维索引的 driver/loader 路径，而不是宣称任何 SystemVerilog
构造都已穷尽验证。动态数组/动态索引、queue、任意 interface/modport、struct/union、加密 RTL、
所有 inout/三态网络和其他 Verdi 版本仍需要对应 oracle。无法建立精确关系时保留诊断，不能用
本报告的通过结果替未测试结构背书。
