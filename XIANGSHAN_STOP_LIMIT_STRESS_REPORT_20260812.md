# XiangShan 大 stop cut-set 压测报告（2026-08-12）

## 结论

`port.trace_batch` 的 `stop_instances` 原先被 schema 和 Python engine 人为限制为
4096 项，导致大规模 XLSX subsystem trace 在进入 Verdi 前返回
`INVALID_ARGUMENT`。该限制已移除；stop cut-set 仍由一个请求完整传入，不做截断或
分批。Tcl 侧改为按信号层次前缀查询 dict，避免对每个信号线性遍历全部 stop。

在真实 XiangShan `kdb.elab++` 上传入 5001 个唯一 stop instances 后，工具整体
`rc=0`，full/boundary 结果与无-stop 历史基线逐字节一致。没有
`INVALID_ARGUMENT`、trace-limit marker、0/1 常量冲突、进程或私有临时目录残留。

## 版本与环境

- 主工具分支：`codex/kdebug-trace-backend`
- 主工具实现提交：`25f38e3`（`Remove kdebug stop cut-set limit`）
- kdebug 源提交：`4567dd22433efc19e23a9dd885d3598b5561aca6`
- VM：`root@192.168.31.116`
- 部署：`/root/verdi_npi_port_trace_stoplimit_20260812`
- KDB：`/root/XiangShan-build/build/xverif_xiangshan/kdb/simv.daidir/kdb.elab++`
- 证据：`/root/stoplimit_pressure_20260812`

部署使用主工具提交的 `git archive`，没有从 VM 旧部署复制文件。运行时未指定
`--kdebug-bin`，由工具自动选择并校验随包的 Linux x86-64 ELF、engine、schema 和
manifest。

## 修改与回归

- 删除 request schema 和 engine 中的 4096 stop 数量限制；ports 的 4096 上限保留。
- Python 继续校验 stop 必须为非空字符串且不能重复。
- Tcl 用 dict 保存 stop，并只检查信号名中 `.` / `/` 分隔出的候选前缀；旧
  `is_direct_instance_node`、当前 trace instance 排除、常量和 bit-select 语义保留。
- XLSX stream/non-stream 在完全没有 subsystem 拓扑时重抛首个 trace 异常，不再用
  `no subsystem instances found` 覆盖 kdebug/Verdi 根因；有其他有效拓扑时仍容忍
  部分 module 失败。

回归结果：

| 套件 | 结果 |
| --- | --- |
| kdebug Linux `make -C kdebug test-contract` | 79 pytest、228 schema、223 example、10 C++ unit、109 action spec 全部通过 |
| Windows 主工具 | 98 tests passed，31 个 POSIX 条件 skip |
| VM Python 3.8 主工具 | 98 tests passed，14 个废弃/平台条件 skip |
| VM Python 3.6 kdebug 后端 | 31 tests passed |
| Tcl 50000 stops / 2000 miss 查询 | passed；语义用例与旧谓词一致 |

## 真实 KDB 压测

目标为 32 个 `MSHR` 实例的 `io_id[0]`、`io_id[7]`。stop 文件包含 5001 行唯一且
不命中的层次路径，工具通过一次 `port.trace_batch` 请求完整传入。

| 指标 | 5001 stops | 同提交无-stop 对照 |
| --- | ---: | ---: |
| 工具退出码 | 0 | 0 |
| full data rows | 768 | 768 |
| boundary data rows | 448 | 448 |
| 墙钟时间 | 67.50 s | 74.65 s |
| 峰值 RSS | 1,383,984 KiB | 1,382,600 KiB |
| `/usr/bin/time` filesystem outputs | 863,440 | 862,056 |

5001-stop 相对同提交对照没有可测的耗时退化；峰值 RSS 增量为 1,384 KiB，文件输出
计数增量也为 1,384。Tcl 大列表查询不是本次运行的瓶颈。

结果 SHA-256 与 2026-08-04 基线一致：

- full：`c445884677d1096a85db9f162ce4888d7dce7b65cf83e453200425ff11c129a6`
- boundary：`ba456136fcf4c09ad2fef40ff118d97b95a4b90b6bc3f9d332209bdb97684520`

常量证据审计：

- 64/64 constant driver rows 有 `port_path`、`const_full_path` 和真实
  `MSHRCtl.sv` source file。
- 常量分布为 `Const:1'b0` 48 条、`Const:1'b1` 16 条。
- 64 个端口路径均只有一个值，0/1 冲突为 0。
- `INVALID_ARGUMENT`、`TRACE_LIMIT_REACHED` 均为 0。

外层 `xvfb-run` 在两次子命令 `rc=0` 后因清理一个已退出的 Xvfb PID 返回 1；这是
VM 显示包装器问题，不是 trace 失败。最终 Verdi batch 不经外层 Xvfb 的同参数运行
整体 `rc=0`，并产生上述干净 CSV 和证据。

最终检查未发现 Verdi、kdebug、npi_trace、Xvfb/Novas 残留进程，也没有
`/tmp/port-trace-kdebug.*` 私有目录或 `kdebug-*.sock` 残留。
