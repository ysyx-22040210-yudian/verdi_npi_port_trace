# 单 bit driver 修复与 VM 验证（2026-09-06）

后续更新：本报告当时保留的固定尺寸多维 loader 缺口已继续修复；新的根因、实现和 VM
验证见 [MULTIDIM_LOADER_FIX_VALIDATION_20260906.md](MULTIDIM_LOADER_FIX_VALIDATION_20260906.md)。
以下保留当时快照的结果，不把旧版“显式未支持”当成当前实现状态。

## 修复目标与范围

继续使用 `codex/trace-reliability-overhaul` 分支上的直接 Verdi/NPI 后端，不切换到 kdebug，不覆盖此前未提交的修改。本轮没有 Git 提交或推送。

起点是 [TRACE_AUDIT_20260906.md](TRACE_AUDIT_20260906.md) 中已经在 VM 复现的失败，而不是根据旧压测 PASS 推断实现正确。用户实际出错项目尚未提供最小 RTL/KDB，因此验证证明的是本文列出的缺陷及场景，不承诺所有商业项目、所有 SystemVerilog 结构都已覆盖。

## 根因与实现

| 审计项 | 处理 |
| --- | --- |
| F1 单 bit 同时报告错误的 0/1 | `get_handle_size` 正确读取 structural `npiSize`。新增 `npi_elaborated.tcl`：用 `npiHighConn/npiLowConn` 保留完整 elaborated 表达式，先按 formal 声明映射到 RHS 位位置，再调用 exact-bit API。输入/输出不再合并 broad high-connection 操作数。 |
| F2 位置式 loader 漏报 | 源码中找到宽度/一个消费者不再代表完整。逐位 loader 增加 NPI bit-load 枚举，覆盖位置式、隐式及运算/过程消费者；禁止不精确的整总线补查。 |
| F3 查询静默丢失 | 支持负索引和多维选择语法；验证声明形状与范围；独立 trace 缺失/越界返回非零并保留日志诊断。Excel 多模块列并集显式记录 `*_absent_ports.csv`，保留不适用格的 `NO_TRACE`，不连带中止有效列。 |
| F4 截断/扩展返回整 literal | 按表达式宽度、signed 属性投影；投影失败不能返回整个 literal 冒充某一位。用 KDB netlist literal 名称区分旧 structural NPI 丢失拼写差异的 `'1` 和 `1'b1`。 |
| F5 `8'd08/09` 八进制异常 | 十进制数字先规范成十进制 token；加入大整数、08/09、signed/unsigned 扩展回归。 |
| F6 陈旧源码污染常量 | 新 input/output driver 路径只按 elaborated 连接与 bit API 推导。源码用于证据，不覆盖 KDB 值；同一 KDB 的 visible/hidden/stale 对照必须一致。 |
| F7 返标隐藏动态证据 | Const 行不再删除/阻止动态来源；已知 scalar 的常量冲突和上游 ERROR/INCOMPLETE 不能被 keyword 命中覆盖。 |
| F8 错误 owner/名字判断 | 普通 `Init/Combo/Always` 子串不再代表生成逻辑；`child.port` 不属于父实例直接节点；默认不把未知 top 重定位为当前祖先的旧缩短路径。 |
| F9 大参数请求与部分产物 | 参数模块列表改走 UTF-8 文件，清除旧环境请求并验证完成标志。CSV 过滤/合并原子发布，头部/行失败不覆盖原完整输出。 |
| F10 部分 packed 选择被误当 scalar | `a[0]` 可能仍是 2-bit 子向量。NPI 冲突检查改为实际 `query_offsets` 数量为 1 才执行；返标不从端口名猜宽度，而接收上游的权威冲突诊断。已知宽度的独立调用方仍可显式设 `scalar_query=True`。 |
| F11 旧 NPI 的 part-select 空名称 | 旧综合场景实测出现 16 项 `unnamed elaborated npiPartSelect expression`。读取文档 346–347 页，并用 VM 探针确认 `npiParent/npiLeftRange/npiRightRange` 完整可用；改由这些结构关系精确映射，不退回源码猜测。 |
| F12 精确 loader 在 assign/拼接 LHS 中提前停止 | VM 综合回归找到 `u_load_pass.i[0] -> o[0] -> u_sink_pass.in[0]` 漏报。通过 `npi_nl_pass_assign_cell` 获取精确对端，并核验输入 pin、输出 pin、目标 net 都保持 1-bit。对于 `{lhs_hi,lhs_lo}` 的匿名 pseudo net，保留 NPI handle 继续 bit-load，不能将带逗号的 netlist 拼写伪装成 RTL 路径。 |

driver 的模块跨层遍历使用工作队列和完整逐位身份去重，不消耗 assign 展开深度，也不依赖 Tcl 递归栈。单元测试覆盖 1,501 层模拟模块映射、`assign_depth=0`。

列并集仅将确定的端口缺失/选择越界记录为不适用，未知位宽、未解析声明和 NPI 异常仍为失败。独立 Raw/CSV 请求没有隐式的“忽略不存在端口”开关；旧综合测试原先把所有模块的列传给单一 `TAFTarget`，现明确区分该模块的 CSV 列与 XLSX 多模块列并集。

NPI 文档依据为 `D:/VMshare/CPU_CORE/ysyx/VC_APPS_NPI.pdf`：重点核对 structural port/连接、Typespec Range、literal value/signedness、bit-driver/load 的返回及跨层限制；相关页包括 55–56、322–331、1524–1525、2802–2803、2861–2867、2881 起及 2930–2934。不是逐字阅读全部 3,568 页。

## 常量证据示例

真实 XiangShan 的 MSHR 日志示例（省略重复字段）：

```text
method=elaborated_port_bit value=Const:1'b0
const_full_path=tb_top.sim.cpu.l_soc.core_with_l2.l2top.inner_l2cache.slices_0.mshrCtl.mshrs_0.io_id[0]<-Const:1'b0
source_file=/root/XiangShan-build/build/rtl/MSHRCtl.sv source_line=2116
source_scope=tb_top.sim.cpu.l_soc.core_with_l2.l2top.inner_l2cache.slices_0.mshrCtl
source_handle_kind=npiConstant formal_width=8 rhs_width=8 rhs_offset=0
connection_side=npiHighConn
```

`const_full_path` 是完整目标端口到常量/assign handle 的**证据链**，不是虚构一个可用 `npi_handle_by_name` 查询的常量实例。无源码时仍保留 KDB 中的文件路径和/或完整 NPI handle 路径。实际不存在独立命名 literal 实例时，不伪造该实例。

## 验证方法

- VM：`root@192.168.31.116`，代码部署在 `/root/trace-fix-20260906/tool`；最终大批输出在原生 `/home/trace-fix-20260906`。VCS/Verdi `O-2018.09-SP2`，Python 3.8。
- 复用现有 XiangShan KDB 和保留的复杂 mesh KDB，不复制/重新生成 XiangShan RTL/KDB。
- 新建参数化 RTL，以 VCS `simv` 中的断言作为独立值 oracle；trace 结果不参与生成预期。
- 具名、位置式、implicit、wildcard、generate、嵌套拼接、重复拼接、截断、signed/unsigned、08/09、填充 literal、MUX、按位逻辑、loader 漏报均有具体验证。
- 同一小型 KDB 分别保持源码可见、临时隐藏、故意改变源码常量；结束后恢复原字节。只修改本轮生成的 fixture。
- 真实多驱动的 0/1 必须保留并输出 `ERROR:CONST_DRIVER_CONFLICT`；合法截断的伪冲突必须消失。X/Z 不能被当作 0/1。
- VM 根分区余量约 0.5 GiB；后来核实 `/home` 独立分区余量约 31 GiB，将新的输出与 TMPDIR 放在该分区。没有移动/删除旧 KDB、RTL 或用户数据；真实 EDA 测试仍串行。

## 结果记录

最终生产快照（Windows/VM 逐文件 SHA-256 已比对）：

```text
npi_port_trace.tcl      66b1d2a542207896adcb49f64065336900028a1d7a43ca86792d598cce720bd8
npi_elaborated.tcl      460dddf0dd289c80e2868be90df6367cbf4da5e361cb5263b41177c05564dee6
trace_support.tcl       90fc5980976ee301361f9af1c431e041ac854aeb75836a8416f5d942ae25fc84
npi_trace.sh            c3f58e8972aaf56fffcf115a272aebc30c10e151149b1b414e812cc716c1f65e
annotate_trace_xlsx.py  3bd656ccf684c23e35e61fd684ea637050b82a061d574a8f483d7fbefa2faea6
npi_find_module_params.tcl c0b83fd3dfda25be3a384aa719f27627a049b9753e4519ba0ebabff65dfcffc6
trace_identity.py       762975469e9e05016187cbe1c1667a786d9e62ae0b9155ac3406c62a193cd0ad
runtime_paths.py        5c72260d3080626d2f36326ef19b0c54f81b1d6ff197cfb5e89d05f90867d8af
```

已完成的最终快照验证：

| 场景 | 实测结果 |
| --- | --- |
| Windows unittest | 84 项：65 通过，19 个 POSIX/信号测试按平台跳过，1.643 s。 |
| VM unittest | 84/84 通过，19.405 s；包括 50,000 stop-set、1,501 层模块映射、长名称/大字段、进程回收及原子输出。 |
| 512 层次化 mesh | 512 目标、5,121 module 实例；8,704 组 driver/loader 精确预期全部通过，full + boundary 共 74,240 数据行，0 诊断；275.948 s，峰值 RSS 458,156 KiB。 |
| 256 lanes 三种源码状态 | visible/hidden/stale × scalar/wide/loader = 9 次 trace，33,792 项独立预期全部通过，无 ERROR/INCOMPLETE/LIMIT；trace 耗时合计 460.727 s。 |
| 常量日志全面核验 | 上述 9 次 trace 的 29,952 组 scalar 0/1 driver，逐组都有匹配目标/值的 `const_full_path`、非兜底来源方法及 KDB 文件或 handle 证据，缺失 0 组。 |
| 错误查询 | 缺失端口、越界均 rc=1，分别 5.194 / 2.982 s；失败 boundary 不发布。 |
| 负索引 / packed | 负索引 16 项正确；多维完整 bit 16 项 driver 正确，loader 显式未支持；2-bit 子向量 8 项允许合法 0/1 并存，不被返标成 scalar 冲突。 |
| 多模块列并集 | 56 个有效查询保留，168 条逐位不适用证据齐全且无重复；3.436 s。 |
| 参数传输 | 10,001 个模块名，320,008-byte 文件；8 个实际 ID 参数、`COMPLETE 10001 8 8`，无 E2BIG。 |
| 四态 / 真多驱动 | 真多驱动保留 0、1 和冲突 marker；合法单 bit 截断只保留 0；visible/hidden 各 16 项填充/有符号/X/Z 查询全部通过，包含 signed/unsigned net 的扩展，分别 3.178 / 3.177 s。 |
| 合法名字 / assign 链 | 64 lanes，4 层 `InitialPath/AlwaysController/u_ComboLogic/SigTapMonitor` 透传，512 项 driver/loader 预期通过；19.995 / 30.059 s。 |
| 旧综合功能完整重跑 | `run_tool_all_features_trace_test.sh` 最终整段 rc=0；Raw、CSV 过滤、keyword 匹配、parameter、两份 subsystem XLSX 全部内容断言通过，4 种目标模块的 full/boundary 均无错误或未完成标记。 |
| 8,192 路扇出 | 8,192 个真实 sink bit 集合精确相等；47.498 s，RSS 388,348 KiB。`node_limit=1` 负例 22.974 s，返标保留 incomplete，不用 keyword=yes 隐藏限额。 |
| 8,192 端口 | 8,192 个交替 0/1 driver 全部正确；327,680-byte 端口请求文件；8,192 端口常量 provenance 全覆盖；71.684 s，RSS 320,664 KiB。 |
| XiangShan MSHR | 32 实例 × 8 位 = 256 组，0=192、1=64；50,000 stop entries；每组 full/boundary 与 `MSHRCtl.sv` 预期相等，来源证据完整；34.47 s，RSS 1,374,880 KiB。 |
| XiangShan Uncache XLSX | 1 实例，9 条 driver、7 条 boundary；负向 keyword、RegCombo 及真实全路径保留，0 错误/未完成；80.12 s，RSS 1,385,484 KiB。 |
| XiangShan 子系统两模式 | MSHR 32 + LevelGateway 65；stream/nonstream 各 2 份 workbook、逐 cell 相同；每种 194 个有来源记录的不适用列格，0 个错误 `NO_*SYSTEM_INST*`；80.68 / 91.65 s。 |
| XiangShan watchdog | 1 s watchdog 正确 rc=124；partial_outputs=0、leftovers=0；不是把超时当作正常 trace 完成。 |
| XiangShan ClockGate | 279 实例 × 3 输入 = 837 项精确 driver 预期通过；38.506 s，RSS 1,380,320 KiB。 |

本地证据目录：`D:/VMshare/CPU_CORE/ysyx/trace-fix-artifacts/20260906/release`。关键结果：
[VM 单元测试](../trace-fix-artifacts/20260906/release/units_final_frozen.log)、
[诊断/参数/packed 对照](../trace-fix-artifacts/20260906/release/diagnostics/summary.json)、
[四态与真实多驱动](../trace-fix-artifacts/20260906/release/four_state/summary.json)。
512 mesh 的[语义校验](../trace-fix-artifacts/20260906/release/mesh_512/trace_release.validation.json)和
[耗时/RSS](../trace-fix-artifacts/20260906/release/mesh_512/trace_release.metrics.json)另附，快照哈希记录在同目录。
256 lanes 的[全部场景](../trace-fix-artifacts/20260906/release/semantic_256/summary.json)与
[29,952 组常量证据完整性](../trace-fix-artifacts/20260906/release/semantic_256/constant_evidence.validation.json)亦已保存。
另见 [signed net 与四态扩展](../trace-fix-artifacts/20260906/release/four_state_extended/summary.json)、
[合法名字跨层验证](../trace-fix-artifacts/20260906/release/alias_names/summary.json)。
大列表/扇出见 [8,192 规模汇总](../trace-fix-artifacts/20260906/release/io_8192/summary.json)，
旧综合完整脚本见 [最终 stdout](../trace-fix-artifacts/20260906/release/legacy/all_features_final.stdout)。
最终 XiangShan 的 [5 项/89 产物清单](../trace-fix-artifacts/20260906/release/xiangshan_final/summary.json)、
[核心快照](../trace-fix-artifacts/20260906/release/xiangshan_final/tool_sha256.txt)、
[MSHR 日志](../trace-fix-artifacts/20260906/release/xiangshan_final/01_mshr_constants/trace.log)、
[Uncache 返标](../trace-fix-artifacts/20260906/release/xiangshan_final/02_uncache_xlsx/result.xlsx)、
[ClockGate 校验](../trace-fix-artifacts/20260906/release/clockgate/validation.json)均已保存到本地。

本表只报告列出的已执行场景。所有规模测试的核心代码均对应上述最终快照；中间失败迭代不合并进通过率。耗时/RSS 是本 VM 的实测结果，不是跨硬件性能保证。

已保留的中间过程（不冒充最终全部通过）：

- 最初 `semantic_8` / `semantic_8_r2` 找到了 `'1` 被错误零扩展，随后 `semantic_8_r3` 的 9 项全部通过。
- 第一版 `semantic_256`：256 lanes，9 项，33,792 个独立 driver/loader 预期全部通过；所有 CSV 没有 ERROR/INCOMPLETE/LIMIT marker。
- 第一版 512 mesh：512 目标 / 5,121 module 实例、8,704 组预期通过，271.768 s，峰值 RSS 454,768 KiB。
- 第一版 XiangShan ClockGate：279 实例、837 组通过，45.085 s，峰值 RSS 1,379,384 KiB。
- 第一版 XiangShan MSHR：32 实例、256 位、50,000 stop entries，0=192、1=64，通过。
- 第一版 XiangShan Uncache XLSX 实测发现新入口错误扣减跨模块深度，出现 `TRACE_INCOMPLETE:driver_depth`；这一版矩阵**失败**，保留在 `xiangshan_matrix`。修复后改成迭代工作队列，并重新跑最终核心压测。
- `xiangshan_matrix_final` 的 trace 已完成且没有深度错误，但旧 validator 在 `assign-depth=0` 下仍要求穿过 assign 到 RegCombo，矩阵判失败。独立阅读 `NewCSR.sv:15714–15715` 确认实际停在连续赋值节点符合配置；随后将完整寄存器链场景显式设为深度 12，而不放宽 RegCombo 内容断言。`xiangshan_matrix_release` 的 5 项已通过。
- `all_features_release` 在正确拒绝未知查询后发现 part-select 的空名称兼容缺口；保留原始失败日志和 `partselect_probe.log`，不将该次 rc=1 计作通过。
- `all_features_release2` 的精确 driver 通过，但旧断言仍要求保留被 NPI 折叠的 `precise_c` 中间别名和源码生成的 `COMBO_EXPR:ternary` 标签；经 RTL/终点核对，改为精确 keyword bit 与计算节点语义校验，保留全部相邻 bit、常量负例检查。其后内容断言真实发现 scalar assign loader 漏报。`all_features_release3` 又暴露匿名 LHS concat handle 被转成无效名字；这两版都不计作通过，探针日志分别为 `load_assign_probe.log` / `load_concat_probe.log`。
- 错误查询/参数测试：缺失、越界均 rc=1；负索引 16 项正确；packed driver 16 项正确，packed loader 显式未支持；10,001 模块、320,008-byte 参数列表无 E2BIG，8 个 ID 参数完整返回。
- `four_state_final`：真实 0/1 多驱动保留，截断只返回 0；visible/hidden 各 12 个四态/扩展查询通过。

## 复现入口

在已配置 EDA/license/Python 3.8 的 VM 原生目录运行，输出目录必须是新的：

```bash
python3 -m unittest discover -p 'test_*.py'
python3 stress/driver_semantics.py --out /root/my-driver-semantics --lanes 256
python3 stress/verify_constant_evidence.py --case /root/my-driver-semantics
python3 stress/driver_diagnostics.py --out /root/my-driver-diagnostics \
  --kdb /root/my-driver-semantics/build/simv.daidir/kdb.elab++ --lanes 256
python3 stress/driver_four_state.py --out /root/my-driver-four-state
python3 stress/driver_alias_names.py --out /root/my-driver-aliases --lanes 64
python3 stress/scale_suite.py --out /root/my-mesh --tiles 512 --fanout 0 --wide-ports 0
python3 stress/scale_suite.py --out /root/my-io-scale --tiles --fanout 8192 --wide-ports 8192
XIANGSHAN_STRESS_OUT=/root/my-xs-matrix bash run_xiangshan_stress_matrix.sh
```

## 仍需明确的边界

- O-2018 netlist API 对多维 selected loader 的限制仍在：已经能从 structural KDB 正确得到对应 driver，但 loader 输出 `TRACE_INCOMPLETE:exact_load`，不能称为“所有方向都成功”。
- 本轮没有证明任意 interface/modport、struct/union、动态 part-select、加密 RTL、任意转义名字、所有 inout/三态网络和所有 Verdi 版本均完全支持。无法映射的 driver 给出显式错误，不改为整个 literal 或整个总线。
- 极端表达式嵌套当前有 128 层显式错误保护，不是静默截断；模块跨层则已不依赖这项表达式递归深度。该边界不等于所有递归/资源限制都已消除。
- loader 的部分连续赋值补充仍使用源码解析；本轮压力覆盖已列结构，不把该 parser 当作完整 SV elaborator，也不宣称所有源码失配下的 loader 拓扑均安全。
- whole-vector 同时出现 0/1 不等于 scalar 冲突；真实多驱动/MUX 静态操作数/错误串位必须区分。当前语义是在计算节点停止，不做仿真时刻的 active-driver 分析。
- 物理文件系统、Excel、内存/磁盘和 EDA 本身的限制不能取消。此次修复的是可避免的软件传输、位映射、完整性和错误汇总问题。
- 未进行并发大 KDB 稳定性背书；低磁盘条件下只报告串行实测结果。
