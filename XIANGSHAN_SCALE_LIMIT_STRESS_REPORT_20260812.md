# XiangShan 扩展性限制审计与压测报告（2026-08-12）

## 2026-08-14 故障隔离补充压测

针对现场出现的
`can't use invalid octal number as operand of "-"`、`INSTANCE_TRACE_FAILED` 和
`module.inspect_batch ... MODULE_NOT_FOUND`，本轮补充修复并在同一份真实 XiangShan
`kdb.elab++` 上重跑。根因与处理如下：

- Tcl 曾把 HDL 位号文本中的前导零交给 `expr`，例如 `[08]`、`[09]` 会按八进制解释并
  抛错。现在 Python 适配器和 Tcl runtime 都把位号按十进制字符串规范化，且不依赖
  64 位整数范围。
- `module.inspect_batch` 现在逐项返回结果。单个实例不存在时输出该实例全路径和
  `MODULE_NOT_FOUND`，不会丢弃同批其他实例；如果进程级批量调用失败，主工具以二分
  方式定位坏项，默认每批 256 个实例。
- 单实例 port trace 抛错时会回滚该实例已写入的 rows、常量证据、seen-port 和截断状态，
  再写入带实例全路径的 `ERROR:INSTANCE_TRACE_FAILED`。只要有实例成功，成功结果继续
  发布并记录 warning；如果全部实例失败，则整体返回 `TRACE_FAILED`，不再伪装成
  `NO_SYSTEM_INSTANCE` 或成功结果。
- kdebug 的结构化错误 `details` 会穿过 Tcl、Python engine、UDS 和 C++ frontend，主工具
  日志有界打印 module、stats、requested ports、实例全路径和原始 Tcl 错误。

补充压测使用 kdebug 源提交
`b4a5c3a1b9f48c46fa8334c44d42626d58138dfe`，VM 干净构建目录为
`/root/xverif-b4a5c3a`，证据目录为
`/root/kdebug_b4a5c3a_xiangshan_20260814`：

| 用例 | 结果 |
| --- | --- |
| Dispatch `[08]/[09]` 与 `[8]/[9]` | 两次均 rc=0，输出逐字节等价；响应统一为 `[8]/[9]` |
| `module.find_instances MSHR` | 找到 32 个真实实例，rc=0 |
| 32 个 MSHR + 1 个不存在实例 inspect | 32 成功、1 个独立 `MODULE_NOT_FOUND`，rc=0 |
| 50000 个唯一 stop instance | 2,350,509 字节请求，32 个实例全部处理，0 error，rc=0 |
| MSHR 常量证据基线 | 64 条有效证据：`0=48`、`1=16`，0 个冲突，均有 `const_full_path` 与 `MSHRCtl.sv` 来源 |
| Python 3.6 / 3.8 对照 | shallow trace 输出完全一致，均处理 32 个实例 |

补充压测的 raw full/boundary 行数为 832/512，其中 128 行是明确的递归深度边界 marker；
排除 marker 后仍是历史语义基线 768/448。Windows 主工具整仓回归为 128 项通过、
32 项因 POSIX 条件跳过。主工具提交的干净 archive 在 VM 上用 Python 3.8 再跑为
128 项通过、14 项环境条件跳过；从 `/tmp` 和符号链接启动随包 launcher 的
`actions/schema` smoke 均通过。Python 3.6 对 `kdebug_backend.py` 与 engine 的
`py_compile`、launcher smoke 均通过，并用随包 ELF 对真实 XiangShan `elab++` 完成
shallow trace：48.41 秒、32 个实例、full/boundary 192/128、0 error。该响应与上游
Python 3.6/3.8 基线逐字节一致，SHA-256 为
`9dce1f0711069d6a5b2defea78f2237b9a26a40de8ceded9a7d67ee1fd6828e5`。

## 结论

本轮修复不是只删除报错中的一个 `4096`。端口 trace 主链路上的数量、命令行长度、
session transport、查找复杂度、CSV/XLSX 格式边界和全局输出预算均已审计：

- `port.trace_batch` 的 `ports` 与 `stop_instances` 均不再有 4096 项的人为上限。
- 大 ports、keywords 和 stop 集合通过 list/plan 文件传递，不再展开成超长 argv。
- C++ UDS client 完整循环发送请求；Python engine 以 64 KiB 分块接收。50000 ports、
  650136 字节的单请求已完整往返。
- Tcl port/stop 匹配和 Python keyword instance 过滤均使用哈希前缀索引。
- Python CSV 读取不再受默认 131072 字节字段上限约束。
- Excel 的 32767 字符单元格和 1048576 行、16384 列物理上限不能删除；工具会在
  写入前显式报错或写 `XLSX_CELL_LIMIT_REACHED:full_result_in_trace_csv`，完整证据保留
  在 trace CSV。
- 全局 `max_rows` 命中后 fail-closed，不发布部分 full/boundary CSV，也不覆盖已有结果。
- loader node/edge/API-list 预算继续保留，命中时必须发布 `TRACE_LIMIT_REACHED:*`。

真实 XiangShan KDB 证明 4097 和 5265 项请求均能越过旧限制并完整经过 JSON、UDS、
plan 和 Tcl 选择链路，没有 `INVALID_ARGUMENT`、参数过长或静默截断。需要区分的是：
4097 个真实复杂 Dispatch 端口的默认完整递归 trace 在 4:11:59 后超时，说明固定数量
限制已经解除，但单 action 的完整递归性能仍不足。本报告不把该超时写成成功。

## 版本与环境

| 项目 | 值 |
| --- | --- |
| 主工具分支 | `codex/kdebug-trace-backend` |
| 主工具实现提交 | `ce4e30905289f2a084ecafc733aa0400e1674cef` |
| kdebug 源仓 | `E:\xverif` |
| kdebug 源分支 | `codex/kdebug-trace-backend` |
| kdebug 实现提交 | `02973ef782bc9280c752f409f748c6edfd53aab6` |
| VM | `root@192.168.31.116` |
| VM 部署 | `/root/verdi_npi_port_trace_scalelimit_20260812` |
| VM 证据 | `/root/trace_scale_pressure_20260812` |
| XiangShan KDB | `/root/XiangShan-build/build/xverif_xiangshan/kdb/simv.daidir/kdb.elab++` |

部署来自实现提交的干净 archive。运行时没有指定 `--kdebug-bin`、`KDEBUG_BIN` 或
`KVERIF_HOME`，实际使用随包 `tools/kdebug`。Dispatch inventory 由真实
`module.inspect` 取得：一个目标实例有 5265 个端口，响应 `truncated=false`；最长端口
完整路径为 139 个字符。压测列表行数经 `wc -l` 复核为 4097/5265。

bundle 完整性：

- Linux x86-64 ELF SHA-256：
  `6dc9c2123a1b08de31b7f0fcfd5817703dc474505bbefe96e3f12b71f4231e43`
- ELF build ID：`652d0f4e6a35c7a84b02a772ad944e7ce8b845bd`
- engine SHA-256：
  `b8e21bc7af91cf2cbcd08a1c9844f96a468efd3548422fc05e6566f311e0b835`
- port trace Tcl SHA-256：
  `2d6d0e1402b6d3e4154d1b079d8f9981efcf7dd255958ab3dd3151efde6178c1`
- request schema SHA-256：
  `5a4b02a79888ee350e79012e92896cc01edc58b5bfcafd948d6eaaf3a3b08c59`
- 228 个 schema 的 tree SHA-256：
  `ff6558429ca88f9f31c9921c360a52c6324161ca66260cedc5424bed637061d6`

## 同类限制审计

| 审计点 | 旧风险 | 当前契约 |
| --- | --- | --- |
| `args.ports` | 超过 4096 项被 schema/engine 拒绝 | 无固定数量上限；仍校验格式和重复项 |
| `args.stop_instances` | 超过 4096 项被拒绝 | 无固定数量上限；完整 cut-set 保持在同一 action |
| shell 参数 | 单参数触发 Linux `MAX_ARG_STRLEN` | `-ports-file`、`-keywords-file`、`-load-stop-instance-file` |
| engine 到 Tcl | 大数组经环境变量/字符串复制 | 使用私有 TSV plan 文件，结束后清理 |
| UDS request | 单次 `write` 可能 short-write；逐字节读取慢 | 循环发送；64 KiB 分块接收；默认 session timeout 对齐为 120 秒 |
| Tcl port/stop 查询 | 每个信号线性扫描所有列表项 | dict/set 与有限层次前缀查询 |
| keyword 过滤 | `rows x instances` 线性扫描 | instance/suffix 前缀哈希索引 |
| 派生文件名 | 超长 module/keyword 名触发文件名过长 | 按 UTF-8 字节限制保留可读前缀并附稳定哈希 |
| CSV 单字段 | Python 默认 131072 字节 | 提升到当前平台可接受最大值 |
| XLSX 单元格 | 超过 32767 字符被 Excel/openpyxl 截断 | 合法截断并附 marker，完整证据留在 CSV |
| XLSX 行列 | 工作表物理上限 | 最多 1048575 个数据行、从第 4 列起最多 16381 个 ports；超出提前报错 |
| 全局 trace rows | 后续端口可能未执行却被解释成 `NO_TRACE` | 命中返回 `KDEBUG_ROW_LIMIT_REACHED`，成对 CSV 均不发布 |
| loader nodes/edges/API list | 无界 fanout/递归可失控 | 保留可配置预算并发布原因 marker |
| inventory rows | 超大公共 API 响应占用过量内存 | 保留每次 1000000 行预算；公共响应若 truncated 则适配器拒绝发布 |
| KOUT 文本 | 数组只预览 20 项 | 显式打印剩余项数并提示 `--json`；JSON 数据保持完整 |

“没有固定数量上限”不等于无限资源。格式校验、超时、loader 图预算、全局行预算和
XLSX 文件格式限制仍然有效；区别是这些边界不能静默制造 `NO_TRACE` 或部分成功。

## 回归结果

| 套件 | 结果 |
| --- | --- |
| kdebug clean VM `test-contract` | 13 项 infrastructure、228 schema、223 example、10 C++ unit、109 action spec、71 contract 全部通过 |
| kdebug 50k UDS | 50000 ports、650136 字节 JSON 请求完整往返；默认 timeout 日志为 120000 ms |
| 主工具 Windows | `Ran 112 tests`，`OK (skipped=31)`；compileall、`git diff --check` 通过 |
| 主工具 VM Python 3.8 | `Ran 112 tests in 5.924s`，`OK (skipped=14)` |
| 后端 VM Python 3.6 | `Ran 31 tests in 3.734s`，`OK` |
| bundle/plan 定向回归 | manifest 与 50000 ports/stop plan 2/2 通过 |
| keyword filter 微基准 | 50000 instances 的固定及生成语义对照通过，本地运行约 0.16 秒 |

Windows 只覆盖 Python、schema 和可移植单元测试；真实 Verdi/NPI 结论均来自上述 VM。

## 真实 KDB 压测

### 请求容量与真实工作量

| 用例 | 请求内容 | rc | full/boundary 数据行 | 墙钟 | 峰值 RSS | 结论 |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 4097 request | 1 个真实端口 + 4096 个不匹配项 | 0 | 23 / 8 | 1:16.98 | 1790496 KiB | 4097 项完整通过，未截断 |
| 5265 request | 1 个真实端口 + 5264 个不匹配项 | 0 | 23 / 8 | 1:14.05 | 1795212 KiB | 5265 项完整通过，未截断 |
| 100 real shallow | 100 个真实 Dispatch 端口，关闭 source/parent/assign 扩展 | 0 | 1680 / 223 | 14:33.98 | 1808764 KiB | 真实端口 trace 完成 |
| 4097 real full | 4097 个真实 Dispatch 端口，默认完整语义 | 124 | 未发布 | 4:11:59 | 2486932 KiB | `TCL_NPI_TIMEOUT`，性能未达标 |

4097/5265 request 文件分别为 159750/205302 字节；日志中的
`trace_done ... ports=4097` 与 `ports=5265` 证明请求没有被 schema、transport 或 Tcl
入口截断。不匹配项逐项返回非致命 `PORT_NOT_FOUND`，因此该用例验证的是请求容量，
不是用少量真实端口冒充 5265 个真实端口的完整性能通过。

两个容量用例输出逐字节一致：

- full SHA-256：`01bd05100de1df2ec540634f184beb4a3291f83ff85e1d9c58eb532c7ae59d34`
- boundary SHA-256：`c262871111f9616c4ec979c15948f33de0ff8face59e072ac8dbe2bef6d866ca`

4097 real full 用例由后端 action timeout 终止。`full.csv` 保持 0 字节，boundary 正式文件
未发布；运行结束后没有 Verdi/kdebug/Xvfb、socket 或私有临时目录残留。因此超时没有
被包装成成功，也没有把半截结果交给反标流程。

### Row-limit 事务性

直接调用 `kdebug_backend.py trace`，对 MSHR `io_id[0]` 设置 `max_rows=1`，预先在
full/boundary 文件写入不同 sentinel：

- rc：1
- 错误：`KDEBUG_ROW_LIMIT_REACHED`
- 墙钟：57.13 秒
- 峰值 RSS：1383948 KiB
- full 仍为 `sentinel-full`
- boundary 仍为 `sentinel-boundary`

该用例直接覆盖适配器的成对原子发布。`npi_trace.sh` 会在启动前按其 CLI 契约清理旧
boundary 文件，因此不能用 wrapper 的预清理行为替代此事务测试。

### MSHR bit 与常量证据基线

默认完整语义重跑 32 个 MSHR 实例的 `io_id[0],io_id[7]`：

| 指标 | 结果 |
| --- | ---: |
| rc | 0 |
| full / boundary 数据行 | 768 / 448 |
| 墙钟 | 1:26.17 |
| 峰值 RSS | 1392688 KiB |
| full SHA-256 | `c445884677d1096a85db9f162ce4888d7dce7b65cf83e453200425ff11c129a6` |
| boundary SHA-256 | `ba456136fcf4c09ad2fef40ff118d97b95a4b90b6bc3f9d332209bdb97684520` |

结果与历史基线逐字节一致。64 条 constant driver 中 `Const:1'b0` 为 48 条、
`Const:1'b1` 为 16 条；64 个端口路径均只有一个值，0/1 冲突为 0。64/64 日志均包含：

- `evidence_source=kdebug.port.trace_batch`
- 从目标端口到常量值的 `const_full_path`
- 真实 source file `/root/XiangShan-build/build/rtl/MSHRCtl.sv`

示例：

```text
const_full_path=tb_top.sim.cpu.l_soc.core_with_l2.l2top.inner_l2cache.slices_0.mshrCtl.mshrs_0.io_id[0]<-Const:1'b0
```

## 残余风险

1. 4097 个真实复杂端口的默认完整递归 trace 在单 action 内耗时不可接受。后续需要
   persistent kdebug/Verdi session、分块执行和最终成对原子聚合；分块不能改变完整
   stop cut-set，也不能让部分块被发布为成功。
2. parent/assign/expression depth 是必要资源预算，但当前若恰在中间 endpoint 耗尽，
   部分路径可能静默停止。不能简单在 `depth==0` 时统一打 marker，因为自然叶和显式
   关闭扩展会误报；在未实现“先证明仍有下一跳”前，深度边界附近的结果不能宣称完整。
3. 大量 keyword definitions 虽已避免 argv 和过滤乘积退化，仍可能触发多次 Verdi action
   启动；这属于启动开销，不是列表数量截断。
4. direct-session 显式 timeout 与 engine cleanup 仍存在小的边界竞态；主工具当前使用
   adhoc `--json -` 路径并额外保留 cleanup grace，不走该竞态路径。

## 最终环境检查

2026-08-12 08:56 +0800 重新启动 VM 后只读复核：部署目录、证据目录和 XiangShan KDB
均存在；未发现 Verdi、kdebug、npi_trace、Xvfb/Novas 残留进程，也未发现
`/tmp/port-trace-kdebug.*`、`kdebug-*.sock` 或 contract 临时构建目录。根文件系统可用
4328251392 字节（约 4.1 GiB）。
