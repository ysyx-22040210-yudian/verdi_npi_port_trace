# 当前 NPI trace 工具全面审计（2026-09-06）

## 结论

**仍然存在用户描述的同类漏洞。** 在当前工作区同哈希代码上，VM 已复现单 bit 输入同时被报告为 `Const:'b0`、`Const:'b1`；还复现了 loader 漏报、合法查询被静默忽略、常量位宽错误、十进制常量导致 Tcl 异常和参数列表传输上限。

这不是仅检查旧代码，也不是用过去 XiangShan 的 PASS 推断当前正确。本轮没有修改生产实现、没有提交或推送；只新增审计报告和隔离复现材料，保留此前所有未提交改动。

用户尚未提供出错项目的 KDB、完整日志和局部 RTL，因此本报告证明的是**当前工具确有这些缺陷**，不能断言用户每一个实际工程报错都由同一个原因导致。

## 审计对象与历史依据

- 主项目：`D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace`。
- 分支：`codex/trace-reliability-overhaul`。
- HEAD：`2662d77852cdf155d6e67a14f3a721d6c9dfed46`，加此前未提交的可靠性重构。HEAD 本身并不代表当前全部实现。
- 后端：直接 Verdi/NPI，**不是** kdebug；没有改动 `E:/xverif`。
- 本轮重新读取任务 **“分析 trace 驱动漏洞”** 的历次记录，并找到、读取截图对应的 **“ysyx NPI trace 工具长会话”** 中与 bit 精度、返标、常量、死循环和压测有关的记录。原截图临时文件已不可见，历史任务本身仍可读取。

历史链条：

| 阶段 | 历史修复方向 | 本轮审计发现的缺口 |
| --- | --- | --- |
| `97ebcc8` / `9bf4315` / `ef6eefd` | 常量投影、恢复 scalar-to-bus bit 起点、禁止显式 bit 查询回查整条总线 | 主要保护源码解析成功的路径；没有贯穿每一跳的位宽/方向/完整性契约 |
| `1947e92` / `e4c2ea9` | loader 限额、重复边去重、keyword/generated endpoint 停止 | 以名字中的 `Init`、`Combo` 等字符串猜测对象类型，会误识别合法 RTL 名字 |
| `622f04c` / `e51ff8c` | exact-bit API、KDB-only 回归、常量全路径证据 | KDB-only 显式位测试不能代表所有裸标量和表达式连接；有证据字符串不等于连接结论正确 |
| `07f4f96` / `2662d77` | 稀疏 subsystem inventory、XiangShan、超时/产物保护 | 解决了特定拓扑和失败路径，不等于所有端口都完成语义检查 |
| kdebug 阶段 | 大列表、08/09、错误隔离、交付 bundle | 切回直接 NPI 后必须逐入口核对；参数列表仍有环境变量限制，常量十进制路径仍有八进制错误 |
| 上一轮未提交重构 | source-first 位映射、统一 matcher、完成标志、较大 RTL 压测 | 本轮在 source-first 的提前成功、scalar 宽度 API 和部分结果汇总处发现新漏网路径 |

## NPI 文档核对

原文件：`D:/VMshare/CPU_CORE/ysyx/VC_APPS_NPI.pdf`，3568 页，2019 年版本。本轮按调用路径重点阅读相关章节，并渲染核对关键完整页面；不声称逐字阅读全部 3568 页。

| 文档页 | 与本项目直接相关的约束 |
| --- | --- |
| 1664–1665 | connectivity 与 driver/load 不是同一个关系；方向决定连接语义。MUX 输入可以含 0、1，`npiNlCondAnnot` 描述条件，不能由此声称目标被两个无条件常量同时驱动 |
| 2802–2803 | `npi_mod_inst_get_port` 返回 structural `npiHandle` / `npiPort`，不是 netlist handle |
| 2857–2860 | `npi_nl_sig_handle_by_name` 可返回 slice 的 pseudo net；手册明确列出多维 slice、struct/union member、interface signal 的限制 |
| 2861、2866–2867 | bit-driver API 的结果是 `{src, driver_list}`；不跨 module，不穿 assign，跨层位映射必须由调用者继续维护 |
| 2930–2934 | 普通 netlist trace 的 `assignCell`、`passMod` 决定是否穿透 assign/module；返回静态来源，不能当作某个仿真时刻的激活 driver |
| 1923–1925 | VANL active trace 另外依赖值传播和对象类型；当前 CSV 追踪不是这一功能 |

因此，真实多驱动、MUX 条件来源和工具串位必须分开。当前默认合同是在组合逻辑处停止；即使以后允许穿透，也必须保留条件/运算节点，不能把操作数直接提升为目标的 unconditional tie。

## 本轮 VM 复现方法

- 使用 `/root/trace-overhaul-20260905-r8`，与本地生产代码哈希一致。
- VCS/Verdi：`O-2018.09-SP2`；在 Linux 原生目录建小型 KDB，未复制或重建 XiangShan。
- 最终复现目录：`/root/trace-audit-20260906`；前一版探针保留在 `/root/trace-audit-20260905`。
- RTL 不只编译，还运行 `simv` 断言，独立确认截断、packed/negative 位选择、符号/零扩展和 `8'd08/09` 的真实值。
- 有源码和 KDB-only 两组使用同一个 KDB；KDB-only 仅暂时隐藏本轮创建的 RTL，结束后恢复。
- stale-source 测试只暂改本轮 RTL 的一处常量，保持 KDB 不变，测试后逐字节恢复。
- 不把命令 rc=0 当作语义正确；失败 trace、原始日志和 expected/actual 均保留。

关键代码 SHA-256：

```text
npi_port_trace.tcl     96b6b4cc99a527e7e3e1d24e31d1b5c4afb74fecaa5aefcbcba42105d032711d
trace_support.tcl      90fc5980976ee301361f9af1c431e041ac854aeb75836a8416f5d942ae25fc84
npi_trace.sh           c3f58e8972aaf56fffcf115a272aebc30c10e151149b1b414e812cc716c1f65e
annotate_trace_xlsx.py e79d05b047997123bfc5e928e447a3100bf276d52bb2ab1d8434a8c76865ab77
trace_identity.py      db01a10f9d6ba12f592c30c7a0b2760d68eb3a00196b53d976f8f9fa9f754b31
```

## 已确认的缺陷

### F1 / P1：裸标量精度和保护仍依赖源码，能输出错误的 0/1 双常量

最小 RTL：

```systemverilog
module AuditScalar(input a);
  wire sink = a;
endmodule
module AuditTop;
  AuditScalar trunc_concat({1'b1, 1'b0});
endmodule
```

这是合法的端口宽度截断，VCS 会给宽度警告，但模拟断言确认 `trunc_concat.a === 1'b0`。正确 driver 只能是最低位 0。

实际结果：

| 模式 | driver CSV | 返回码 |
| --- | --- | --- |
| 源码可见 | `Const:'b0`、`Const:'b1`、`ERROR:CONST_DRIVER_CONFLICT:0,1` | 0 |
| 同一 KDB，源码隐藏 | `Const:'b0`、`Const:'b1`，没有冲突 marker | 0 |

根因组合：

1. [source_port_connection_driver_starts](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/npi_port_trace.tcl:2519) 只恢复具名 `.port(expr)`；位置式连接返回空。
2. [process_instance](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/npi_port_trace.tcl:6287) 仍遍历 broad high connection 的每个操作数，`trace_select` 对裸 `a` 为空，随后合并 0 和 1。
3. [get_handle_size](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/npi_port_trace.tcl:354) 对 structural `npiPort` 调用 netlist size API。VM 探针得到 `npi_get/npiSize = 1`，而当前使用的 `npi_nl_get/npiNlSize` 返回空；`::npi_L1::npi_nl_get` 也不存在。
4. [冲突检查](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/npi_port_trace.tcl:6755) 依赖 `base_port_width == 1` 或显式 `[bit]`。源码不存在后两条件均不成立。

证据：`scalar.json`、`scalar_kdb_only.json`、`scalar.log`、`api_probe.log`、`oracle.stdout`。

同类表达式问题也复现：源码隐藏时 `.a(sel ? 1'b1 : 1'b0)` 输出 `sel + Const0 + Const1`；`.a(sel & 1'b1)` 输出 `sel + Const1`。这既不符合当前组合逻辑停止合同，也不能证明 a 是 tie1。

### F2 / P1：source-first 提前宣告完整，遗漏真实 loader

RTL 中同一 `emit[0]` 同时连接：

```systemverilog
AuditScalar load_named(.a(emit[0]));
AuditScalar load_pos(emit[0]);
```

查询 `AuditProducer.q[0]`：

- 源码可见：只返回 `AuditTop.emit[0]`、`AuditTop.load_named.a[0]`，遗漏 `load_pos.a`。
- 同一 KDB、源码隐藏：可以返回两个 sink。
- 两次 rc 均为 0，没有 incomplete。

[load_trace_should_run_hdl_fallback](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/npi_port_trace.tcl:5135) 仅根据源码中存在信号宽度就认为 fallback 可以关闭；[collect_loads_by_name_rec](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/npi_port_trace.tcl:5910) 随即返回。具名连接 parser 并不能证明位置式、implicit、generate、procedural 等消费者均已枚举。

同一 fixture 中 `wire sink = ^a` 的逐 bit loader，在有源码时退回自身端口；KDB-only 却能找到 Combo 输入。这也是“有源码反而少报”的直接对照。

证据：`producer.json`、`producer_kdb_only.json`、`vector.json`、`vector_kdb_only.json`。

### F3 / P1：合法但未支持的位选择、缺失端口被当成成功

| 查询 | 实际 RTL | 当前结果 |
| --- | --- | --- |
| `a[0][1],a[1][1]` | `input [1:0][1:0] a` | full/boundary 只有表头，rc=0 |
| `a[-4],a[-1]` | `input [-1:-4] a` | full/boundary 只有表头，rc=0 |
| `a,missing_port` | 模块只有 a | 只处理 a，missing_port 无独立错误，rc=0 |

[split_port_filter_spec](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/npi_port_trace.tcl:32) 只接受一层非负数选择；否则把整串当端口名。遍历时跳过不匹配的全部端口，而 [COMPLETE](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/npi_port_trace.tcl:6899) 只核对处理实例数，不核对请求端口完成数。

即使 NPI 本身不支持某种语法，工具也必须明确报 `UNSUPPORTED_SELECT` / `PORT_NOT_FOUND`，而不是让返标层猜成 `NO_TRACE`。

证据：`packed.json/.log`、`negative.json/.log`、`missing_port.json/.log`；模拟断言证明相关 RTL 位选择有效。

### F4 / P1：bit 投影失败仍退回完整 literal，扩展位结果错误

```systemverilog
module AuditWide(input [7:0] a); ... endmodule
AuditWide signed_ext(.a(2'sb10));
AuditWide unsigned_ext(.a(2'b10));
```

模拟断言确认 `signed_ext.a[7] = 1`、`unsigned_ext.a[7] = 0`。当前查询 `a[7]` 却分别返回 `Const:2'sb10`、`Const:2'b10`，没有标记无法投影。

具名的 1-bit `.a({1'b1,1'b0})` 也返回完整 `Const:{1'b1,1'b0}`，而不是 0。

[expr_item_source_signal_for_bit](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/npi_port_trace.tcl:3226) 在 projection 失败时返回整个 const；调用方又把非空返回当成精确成功。缺少 formal/actual width、signedness 和扩展规则，不能用“投影失败返回原值”兜底。

证据：`extension.json`、`scalar.json`、`oracle.stdout`。

### F5 / P1：08/09 的八进制漏洞并未覆盖常量路径

有效 RTL `AuditDecimal dec08(.a(8'd08));`、`dec09(.a(8'd09));` 编译/模拟成功。查询 `a[3]` 实测：

```text
TclPlay: can't use invalid octal number as operand of ">>"
[ERROR] TRACE_INCOMPLETE: Verdi exited without a trace completion record
decimal_trace rc=1
```

[const_bit_from_based_literal](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/npi_port_trace.tcl:570) 直接对字符串 `08` / `09` 做 `expr` 位移。此前修复的 decimal index helper 没有覆盖这里。单个实例异常中断整个模块批次，没有保留其他实例的完成结果。

完成标志本次成功拦截了半成品，这是已有保护有效的部分；但原始异常仍需要修复，不能将该异常解释成模块不存在。

证据：`decimal_audit.sv`、`decimal_compile.stdout`、`decimal_oracle.stdout`、`decimal_trace.log`、`extra_results.json`。

### F6 / P1：源码和 KDB 不一致时能制造错误常量证据

固定已建好的 KDB，暂把本轮源文件中的 `bus = 2'b10` 改成 `2'b01`，不重新 elaboration。KDB 中 `pos0.a` 仍然只有 0、`pos1.a` 仍然只有 1，但 trace 二者都输出 0/1 双常量。

不是用户 RTL 真实多驱动，而是新源码的常量推断与旧 KDB 结果合并。[源码 constant map](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/npi_port_trace.tcl:741) 和 NPI driver 没有共同的构建版本/源码一致性标识。日志中的 `source_file` 和 `const_full_path` 都可以存在，但不能证明它属于当前 KDB。

证据：`extra_results.json` 的 `stale_source`、`stale_source.log`。`source_restored=true`；最终源文件 SHA-256 为 `09b8231e77a4176a21db692ff1c5c474630e44e417d9881a7dee26527d0c99ef`。

### F7 / P1：返标层仍可把异常驱动集合显示成普通常量结果

用本轮 VM 的真实 CSV 行直接调用当前 `PortSummary`，不是手工伪造 trace，得到：

```text
trunc_concat.a : no; driver=Const:'b0; driver=Const:'b1
direct_mux.a   : no; driver=Const:'b0; driver=Const:'b1
expr_and.a     : no; driver=Const:'b1
```

[observe_row](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/annotate_trace_xlsx.py:236) 只从末尾 `[数字]` 猜单 bit，没有裸 scalar 的宽度；同时 [observe](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/annotate_trace_xlsx.py:196) 一旦看到 Const 就隐藏同方向 actual endpoint。于是 `sel & 1` 的动态来源 sel 被隐藏，剩下容易误读成 tie1 的结果。

已有显式 `ERROR:` / `TRACE_LIMIT_REACHED:` 优先级保护有效；问题是上游未生成诊断时，下游也缺少 width、path kind、completeness 元数据来识别错误。历史“命中 yes 就隐藏 Const”的做法只改变展示，不能作为正确性修复。

证据：`audit_python.py`、`python_probe_results.json`。本轮直接验证了返标汇总函数，没有声称又做了一轮实际 XLSX 视觉验收。

### F8 / P1–P2：用路径字符串猜 ownership / object kind，仍可误匹配或提前停止

当前真实 helper 的确定性结果：

| 输入 | 当前结果 | 问题 |
| --- | --- | --- |
| keyword=`Top.key`，signal=`Top.key.child.out` | belongs=true | 将子实例端口视作父实例直属节点；未区分实际 owner |
| keyword=`Top.wrap.Other.key`，trace instance=`Top.wrap.branch.target`，完整 signal=`Other.key.out` | belongs=true | 未知 other top 被当作旧短路径重新拼接，跨 top 误命中 |
| `Top.u_InitMonitor.out` | boundary=false、generated=true | 普通实例名字中的 `Init` 被当作 generated cell |
| `Top.u_ComboLogic.out` | boundary=false | 普通名字中的 `Combo` 误触发 |

位置：[trace_identity.py](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/trace_identity.py:18)、[legacy rebasing](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/trace_identity.py:65)、[对象类型猜测](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/npi_port_trace.tcl:4540)。

这些是对当前纯函数的确定性复现；本轮未声称已在真实 XiangShan 找到这些名字并完成端到端污染复现。建议 owner/type 来自 NPI handle，而旧格式兼容必须带明确 format/version 标识，不能依据陌生 top 名猜测。

### F9 / P2：参数收集入口仍有大环境变量限制

实例 finder 和 port 请求已改用文件，不代表所有模块列表都改完。[find_module_parameters](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/annotate_trace_xlsx.py:1191) 仍设置：

```python
env["NPI_PARAM_MODULES"] = ",".join(modules)
```

本轮在 VM 调用该真实入口：10,000 个模块名、278,889 bytes，Verdi 尚未启动就返回：

```text
PARAM_TRACE_FAILED: [Errno 7] Argument list too long: 'verdi'
```

该错误有被报告，不是静默成功；但历史“模块请求走文件”的概括不适用于这个入口。更大 stop-set 的 PASS 与此无关。

证据：`audit_extra.py`、`extra_results.json`。

## 其他静态风险（不计为已完成 VM 复现）

1. **API 失败和预算用尽并不总是成为结构化诊断。** 多处 `catch` 只写 debug/log 后返回空；driver 的 assign/expr 深度用尽会直接保留中间端点。loader node/edge 限额有 marker，但同样的保证未覆盖所有 driver/深度路径。需要区分自然叶节点、用户语义停止、资源截断、API 失败。
2. **请求完成标志粒度过粗。** 有 COMPLETE 只能证明实例循环走到末尾，不能证明所有 ports、每个方向、所有 API 都成功；F3 是其已复现后果。
3. **源码 parser 不是完整 elaborator。** preprocessor/generate 区域的忽略策略能减少错误常量，但不能保证其下所有有效驱动/消费者都被补回；interface、struct、动态选择、escaped identifiers 需要独立受支持/不支持状态。
4. **最终过滤 CSV 的写入不全是事务性的。** `filter_trace.py` 的过滤/合并直接以 `w` 打开目的文件，后续解析失败可留下部分文件；wrapper 虽传播非零码，但这与“旧结果保持不变”不是同一保证。并发同输出目录也没有完整隔离合同。
5. **多份旧入口仍在工作区。** `npc/csrc/npi_trace.sh` 会调用同目录旧 `npi_port_trace.tcl`（SHA-256 `a3404797d6dc74db465f2e102d815ff27ca11d805b0e6a51efc934dde425e17b`），其中仍是整条 connected net 的 trace。还有 zip 解包副本。不能据此断言其他设备实际跑了旧版，但必须用启动路径、hash、backend/version 排除。
6. **并发 EDA 稳定性尚未闭环。** 上一轮保留了两次 Verdi 并发中途退出，不能被串行 PASS 抹掉。本轮结束 VM 根分区只有约 731 MiB，故没有再跑并行大型 XiangShan import。

## 为什么过去压测通过仍会漏掉

- 大规模复制同一种具名连接结构，主要增加规模，不会自动覆盖位置式连接、合法负下标、源码不一致、常量文本 08/09、formal/actual 宽度扩展。
- 历史 source-backed 回归有明确源码恢复路径；KDB-only 回归主要验证显式 `[bit]`，没有覆盖这次的裸 scalar + computed / truncation 路径。
- 上一轮 source-first 的提前返回旨在防止 broad NPI 混入 sibling bit，但“识别了宽度”不等于“所有语法消费者都已解析”。
- [scale_suite.py](D:/VMshare/CPU_CORE/ysyx/_remote_verdi_npi_port_trace/stress/scale_suite.py:138) 的常量组核对常量集合，未拒绝所有额外非常量终点；非 const 分支只比较特定命名 pattern 的 keyword sink，仍不是所有 endpoint 的完整语义检查。
- 本轮重新跑当前 Windows 全量单元测试仍是 **69 项，50 通过、19 条 POSIX 条件跳过**；`git diff --check` 通过。它们与本报告的 VM 失败同时成立，说明必须补覆盖，而不是把既有 PASS 解释成通用正确性保证。

## 建议修复顺序（本轮未实施）

1. **先统一每一跳的查询状态。** 保存真实对象类型、实例 owner、decl range、selected bits、formal/actual 映射、signedness、path kind 和 `complete/unsupported/error/truncated`；禁止用“返回列表非空”作为精确成功。
2. **修 structural/netlist API 域及常量解释器。** 正确取得 scalar 宽度；decimal 字符串统一显式十进制；实现截断、符号/零扩展；无法证明单 bit 时不能返回整个 literal。
3. **用 elaborated 连接关系主导跨层。** 保留 bit API 的 src-to-driver 映射；具名、位置式、implicit/wildcard 不应改变连接含义。源码只能在能证明一致和完整时作为精确来源。
4. **单独修复 completeness 与返标。** 每个请求 port 必须有结果/错误；一个未完成方向不能被 yes 覆盖；常量操作数不等于 tie，保留动态证据而不是隐藏。
5. **再修身份与交付入口。** NPI owner/type 替代名字猜测；所有大请求走文件，包括参数；记录 backend、hash 和构建身份；跨设备先核对实际运行文件。
6. **回归以结构多样性为先，再扩规模。** 将本轮每个失败做成不可放宽的预期集，同时覆盖 inout/tri-state、真实多驱动、generate/preprocess、interface/struct、负下标、宽度扩展、版本/源文件不一致和 API 故障注入。随后在磁盘充足、隔离输出目录下再跑 XiangShan 全量和并发门禁。

## 证据与复现入口

本地证据目录：[trace-audit-artifacts/20260906](D:/VMshare/CPU_CORE/ysyx/trace-audit-artifacts/20260906)。不含密码、不复制商业 EDA 二进制或大型 KDB。

- [综合 VM 结果](D:/VMshare/CPU_CORE/ysyx/trace-audit-artifacts/20260906/results.json)
- [源码一致性 / 参数限制 / decimal 结果](D:/VMshare/CPU_CORE/ysyx/trace-audit-artifacts/20260906/extra_results.json)
- [返标与路径 helper 结果](D:/VMshare/CPU_CORE/ysyx/trace-audit-artifacts/20260906/python_probe_results.json)
- [RTL 与模拟断言](D:/VMshare/CPU_CORE/ysyx/trace-audit-artifacts/20260906/driver_audit.sv)
- [VM harness](D:/VMshare/CPU_CORE/ysyx/trace-audit-artifacts/20260906/run_audit.py)
- [额外故障探针](D:/VMshare/CPU_CORE/ysyx/trace-audit-artifacts/20260906/audit_extra.py)
- [structural / netlist API 探针日志](D:/VMshare/CPU_CORE/ysyx/trace-audit-artifacts/20260906/api_probe.log)

在已加载 VCS/Verdi/license/Python 3.8 环境的 VM 中，可用上述脚本在独立目录重现。`run_audit.py` 的 TOOL 当前固定为本轮已核验的 `/root/trace-overhaul-20260905-r8`；复现其他版本时应显式改为被测快照并重新记录 hash。脚本打印 rc 不等于所有语义检查 PASS，本报告列出的 expected/actual 和 RTL oracle 才是审计结论。

本轮结束检查没有 Verdi/Novas/Xvfb/simv 残留；两个隔离探针目录合计约 6.5 MiB，保留供后续修复回归。生产核心 hash 与开始时一致。
