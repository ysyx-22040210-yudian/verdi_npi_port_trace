# RTL trace 可靠性与规模重构

状态：最终版串行/分项验证完成，以下列出的内容断言全部通过。并发中途退出的两次尝试单独保留，不计为通过，也未声称其唯一根因已定位。

## 范围与基线

- 工作分支：`codex/trace-reliability-overhaul`，基于直接 Verdi/NPI 分支 `codex/fix-exact-bit-driver-trace` 的 `2662d77852cdf155d6e67a14f3a721d6c9dfed46`。
- 保留了本轮开始前未提交的参数范围与压力矩阵修改；没有清空 Git 历史，没有恢复 kdebug，也没有修改 XiangShan RTL/KDB。
- 结合历史任务“分析 trace 驱动漏洞”中的逐位常量、全路径证据、`NO_SYSTEM_INSTENCE`、参数上限、长文件名、十进制 08/09、跨设备运行和旧压测反馈来选择本轮检查。
- VM 使用已有 SSH key；报告不包含密码。现有 Verdi/VCS 与 license 环境仍是运行依赖，不能把本项目理解成不需要商业 EDA 环境的独立解析器。
- 本轮修改保留在工作分支，未做 Git commit 或 GitHub push；最终 VM 部署与本地核心代码的哈希已比对。

## 实际发现并修复的问题

| 问题 | 失败证据与根因 | 修复约束 |
| --- | --- | --- |
| 逐位 trace 丢失/混入相邻常量 | 新生成 4 目标、68 组 oracle 最初全部失败；一行 ANSI 声明后的实例被误当端口列表，跨层 bit 编号也未按声明重映射 | 平衡括号/首分号解析声明，缓存端口方向；每层按声明范围、拼接位置映射选定位，成功后禁止用 broad high list 重做 |
| 真实 XiangShan 的错误常量 | 8 个 `MbistClockGateCell_234.CG.E` 把 `(mbist_req ? mbist_readen | mbist_writeen : E) & ~dft_ram_mcp_hold` 中 hold=0 当作整个 E=0 | 所有计算连接都是逻辑边界；三目检测覆盖任意嵌套并区分数字字面量中的 `?`；常量父端口链只能跟随唯一精确映射 |
| loader 位扩散 | `load_bus[18]` 本是未被 key sink 使用的中间位，却命中了低位和拼接 sink；旧 NPI broad 接口返回其他位后又被递归展开 | 有明确源码位映射的选定位不再扩宽到 whole-bus API；18 位负例、28 位禁止低位 sink、7 位精确低位 sink 都进入回归 |
| 拼接 loader 与端点限额被旧回退掩盖 | 关闭错误的宽总线回退后，严格 512 目标 oracle 检出了漏掉的拼接 sink；低 node budget 未覆盖已停止的 keyword 节点 | 具名连接改为平衡括号解析；递归计算嵌套/重复拼接的每个位置；停止端点同样计入独立节点预算且去重 |
| NPI 方向读取异常 | 旧实现尝试不存在的 `::npi_L1::npi_nl_get`，方向依赖源码 fallback | 按安装版本的真实 API 使用 structural `npi_get_str/npiDirection`、netlist `npi_nl_get_str/npiNlDirection`，并缓存 |
| 层次身份丢失 | 缩短路径后，不同子系统中的同名实例可能被共同 suffix 匹配 | 新 trace 保留全路径，CSV/XLSX 共享 matcher；旧短路径仅按 trace 行上下文恢复，不做任意 suffix 命中 |
| 错误被成功覆盖 | keyword 命中曾可能覆盖资源限额/冲突诊断；含逗号的错误字段又可能损坏 CSV | 诊断优先级高于 `yes`；scalar 0/1 冲突明确报错；CSV 正确引号转义 |
| rc=0 但输出不完整 | Tcl 异常退出与外层退出码不一定一致 | finder 与 tracer 必须同时有完成记录；检查全量/边界输出后再发布；过滤/合并失败传递非零码 |
| 大列表、长字段和文件名 | 历史环境变量/argv、Python CSV 128 KiB、Excel 单元格及 NAME_MAX 限制 | 端口/模块请求走临时文件；CSV 提高到平台可表示限制；输出文件名稳定哈希保留身份；超长 XLSX 证据分块保存，参数和结果均不静默截断 |
| 规模运行慢 | 8192 端口反复扫描，50,000 stop-set 线性查找 | 端口、high connections、具名连接和 source token 建索引，shape 解析缓存，stop-set 使用完整路径索引 |

`COMBO_EXPR` 的含义是“存在运算，连接追踪在此停止”，不是对表达式求值。即使逻辑可被优化成常量，也不会仅凭其一个常量操作数作出该结论。拼接中能独立确定位置的常量位仍保留常量结果。

## 验证方法

生成 RTL 的 oracle 在执行 trace **之前**由位置换、范围和实例身份计算，绝不从旧 trace 复制预期。检查目标包括：完整实例集合、端口集合、精确 bit 和端点集合、错误常量缺失、负例 sink 不命中，以及 full/boundary 两种输出。

真实 XiangShan 不重新生成、不复制大型 KDB：

```text
/root/XiangShan-build/build/xverif_xiangshan/kdb/simv.daidir/kdb.elab++
/root/XiangShan-build/build/rtl
```

MSHR 的 8-bit 常量预期独立读取 `MSHRCtl.sv` 的 `.io_id(8'hN)`；ClockGate 预期独立解析父模块的 `.TE/.E/.CK` 连接，要求各组可无歧义解析，否则测试本身失败。

## 最终验证结果

最终实现部署：`/root/trace-overhaul-20260905-r8`。代码 SHA-256 与 Windows 工作区一致：

```text
npi_port_trace.tcl     96b6b4cc99a527e7e3e1d24e31d1b5c4afb74fecaa5aefcbcba42105d032711d
trace_support.tcl      90fc5980976ee301361f9af1c431e041ac854aeb75836a8416f5d942ae25fc84
annotate_trace_xlsx.py e79d05b047997123bfc5e928e447a3100bf276d52bb2ab1d8434a8c76865ab77
```

| 场景 | 内容校验结果 | 实测时间 / 峰值 RSS |
| --- | --- | --- |
| VM 单元测试 | 69/69 通过，含 50,000 模块请求、2 MiB CSV 字段、长文件名与进程回收 | 18.450 s |
| Windows 单元测试 | 50 通过、19 个仅 POSIX 场景跳过 | 1.720 s |
| 复杂表达式 | 64 实例 × 16 端口/位 = 1,024 组通过；computed operand 常量不得泄漏 | 18.837 s / 225,804 KiB |
| 8,192 路扇出 | 一个输出选定位的 8,192 个真实 sink bit 集合精确相等 | 38.870 s / 382,604 KiB |
| 限额扇出 | `node_limit=1` 必须产生 `TRACE_LIMIT_REACHED`，反标仍为 `incomplete` | 24.986 s / 346,956 KiB |
| 8,192 端口 | 8,192 个交替 0/1 常量正确；327,680-byte 请求文件；8,192 个端口都有完整源码证据 | 120.329 s / 316,448 KiB |
| MSHR + 50,000 stop entries | 32 实例 × 8 位 = 256 组，0=192、1=64；全部匹配 `MSHRCtl.sv` 预期 | 43.930 s / 1,384,200 KiB |
| Uncache 实际 XLSX | 1 实例、3 driver、1 boundary；负向 keyword、RegCombo 与真实全路径保留 | 106.250 s / 1,413,716 KiB |
| 子系统 stream / nonstream | MSHR 32、LevelGateway 65、ClockGate inventory 279；两种模式各 2 份 workbook，逐 cell 相同；无错误 `NO_*SYSTEM_INST*` | 114.340 / 110.300 s；峰值 1,370,492 KiB |
| 真实 watchdog | 1 s 超时触发 rc=124；full 未发布、boundary 不存在、无本任务临时文件残留 | 含回收 5.520 s / 10,120 KiB |
| 全功能 / scopefix / loader 旧回归 | 三项最终版全部通过，保留正向 sink、未使用位和跨 scope 负例 | 见各自日志 |
| 512 目标 / 5,121 module 实例 | 8,704 组逐位 oracle 全部通过；full 81,920 行、boundary 73,216 行（不含表头） | 260.502 s / 430,136 KiB |
| ClockGate 279 × 3 输入 | 最终版 837 组精确 driver 检查全部通过，原来 8 个表达式误报均消失 | 41.183 s / 1,399,636 KiB |

XLSX 由 openpyxl 和独立 Artifact Tool 两个读取器检查，代表性 Uncache/MSHR 实际渲染可读、未出现公式错误。渲染检查促使结果列加宽和换行；96,018 字符证据经过保存、重新加载后可由 `TraceEvidence` 逐块完整恢复。

最终主要产物：

```text
/root/trace-scale-io-final-20260905-r8/summary.json
/root/trace-expression-final-20260905-r8/validation.json
/root/xiangshan-final-20260905-r8/summary.json
/root/trace-scale-final-20260905/mesh_512/trace_r8_serial.validation.json
/root/xiangshan-clockgate-final-20260905-r8-serial/validation.json
/root/trace-overhaul-20260905-r8/{units,all_features,scopefix,loader}.log
```

## 已保留的失败和中间证据

- 最初 mesh 68 组失败及修复前后结果：`/root/trace-scale-smoke-20260905/mesh_4`。
- ClockGate 8 个真实误判：`/root/xiangshan-clockgate-overhaul-20260905-r3/validation.json` 与 `trace.log`。另有较早 43 项差异，其中 35 项来自当时 OR 边界 oracle 与旧合同不一致，**不把这 35 项算作独立真实 bug**。
- loader 18/28 位的失败：`/root/trace-overhaul-20260905-r4/scopefix_pressure_probe.csv` 与压缩日志 `scopefix_pressure_trace.log.gz`。
- 早期 medium suite 的 wide 阶段因明显重复扫描过慢而人工中止，记录为失败/中止，**没有计入通过率**。后续 8192 端口独立重跑通过。
- r4 的 512 目标位映射检查：8704 组通过，982.251 s，537208 KiB RSS；本轮最终核心又作了 loader 修复，因此又在最终 r8 代码上重跑了全部 512 目标，不混用旧测试冒充最终结果。
- r7 的 512 目标检查检出了 1,024 个漏掉的拼接 sink，修复后 smoke 68/68 已通过；原 oracle 未放宽。r7 的限额负例也被明确记为失败，直到修复停止端点计数。
- r8 并发压测的 mesh 与 ClockGate 在 `2026-09-05 23:34:26 +0800` 中途退出，外层 rc=0，但没有完成记录；wrapper 正确改报 `TRACE_INCOMPLETE` / rc=1，full stdout=0 bytes、boundary 不存在。这两次不是通过。VM 根分区剩余空间很低，Verdi 自身会创建数百 MiB swap；尚无足够证据把退出唯一归因于磁盘或某一代码错误，因此保留原日志并在不改变实现的情况下串行复测。
- 子系统检查已取消历史“必须有 320/192 行”的脆弱 golden count，改为完整实例/查询集合、无错误诊断、每个 MSHR 位的独立 RTL 常量预期及 stream/nonstream 逐 cell 相等。不能为了维持旧行数重新引入错误 broad trace 行。

## 复现

在原生 Linux 目录部署当前源代码并加载 VCS/Verdi、license、Python 3.8+（含 openpyxl）环境后运行。不要在同一个输出目录同时运行两个回归。

```bash
python3 -m unittest discover -p 'test_*.py'
bash run_tool_all_features_trace_test.sh
bash run_scopefix_pressure_trace_test.sh
bash run_loader_pressure_trace_test.sh

python3 stress/scale_suite.py --out /root/my-trace-scale \
  --tiles 4 64 512 --fanout 8192 --wide-ports 8192 --timeout 1800
python3 stress/expression_boundaries.py --out /root/my-trace-expressions --instances 64

XIANGSHAN_STRESS_OUT=/root/my-xs-trace bash run_xiangshan_stress_matrix.sh
python3 stress/xiangshan_clockgate.py --out /root/my-xs-clockgate \
  --instances /root/my-xs-trace/02_uncache_xlsx/work/ClockGate_instances.txt
```

`scale_suite.py` 成功后默认清理自己生成的合成 KDB，保留 RTL、oracle、完整 CSV、日志、命令、耗时、RSS 和验证 JSON。需保留 KDB 时加 `--keep-kdb`，之后可以用 `stress/recheck_case.py` 验证新代码而不覆盖旧证据。不会清理或复制用户的 XiangShan KDB。

在存在其他 EDA 作业时可设置 `VM_STRESS_ALLOW_CONCURRENT_EDA=1`；此模式保留 VM 进程清单，但不把其他作业的进程误判成本任务泄漏。每个超时测试仍验证自己的进程组和临时文件。

## 适用边界与未声称的保证

- 这些结果证明的是明确列出的结构和当前 KDB/Verdi 版本；不是形式化验证，也不能保证任意 SystemVerilog、任意 CPU 或所有 Verdi 版本均正确。
- 任意 interface/modport、union/struct、动态 part-select、所有转义层次语法、加密/缺失 RTL 的全部路径不在本轮完整端到端覆盖承诺中。源码 fallback 不是完整的 SV elaborator；源文件必须与 KDB 一致。
- 物理文件系统单组件长度、Excel 行列/单元格容量、机器内存和 EDA API 自身限制不能被“取消”。本轮解决了已验证的数据传输、生成文件名和长单元格证据问题，保留显式资源/超时配置。
- large list 与 caching 的配置上限不等价于结果截断：缓存满时仍继续匹配；显式 traversal budget 命中会保留 `TRACE_LIMIT_REACHED` 并反标 `incomplete`。
- VM 测试复用已有真实设计且多个测试可并行，耗时/RSS 是本次实测，不是隔离环境性能基准。
- 当前 VM 根分区余量不足 1 GiB。最终 mesh 与 ClockGate 的串行重跑均通过，但不把它等同于并发稳定性已经证明；在补足磁盘空间并独立定位那两次退出前，建议真实大 KDB 按顺序运行。
