# VM 复杂 RTL 与 XiangShan 压测矩阵

`run_vm_stress_matrix.sh` 是 pre-kdebug 直接 Verdi/NPI 分支的统一压力入口。它不会重新生成
XiangShan RTL 或复制 KDB；真实大设计测试默认复用：

```text
/root/XiangShan-build/build/xverif_xiangshan/kdb/simv.daidir/kdb.elab++
```

## 场景

| 场景 | 主要覆盖 | 通过条件 |
| --- | --- | --- |
| `unit_tests` | 超时、原子发布、旧结果清理、subsystem 稀疏拓扑 | 全部 unittest 通过 |
| `tool_all_features` | 多层 module、精确 bit、常量、assign/concat/slice、三目、RegCombo、fanout、CSV/XLSX | 正向 endpoint 命中；相邻 bit/decoy 不泄漏；两份 subsystem XLSX 可读且无缺失实例占位 |
| `scopefix_pressure` | 深层 wrapper、跨 scope driver/loader、同名 decoy、两套 subsystem | 四个目标实例全部通过，noise/decoy 不进入过滤结果 |
| `loader_pressure` | 高 fanout loader、direct/alias/concat/LHS slice/parameter/generate/port 透传 | 八类目标 loader 全部命中；同名 decoy 不泄漏；大 node/edge/API 限额路径可完成 |
| `01_mshr_constants` | 32 个真实 MSHR、`io_id[0..7]` 精确常量、50,000 stop instances | 256 组各只有一个常量；0=192、1=64；逐组检查 `const_full_path` 与 `MSHRCtl.sv` 证据 |
| `02_uncache_xlsx` | 真实复杂 driver 链、keyword 搜索、parameter、stream XLSX；assign 深度 12 | 一个真实 Uncache 实例；反标为 `no` 并保留 `driver_actual` 和 RegCombo endpoint；不含错误/未完成标记 |
| `03_subsystem_*` | 32 个 MSHR + 65 个 LevelGateway + 279 个 ClockGate，stream/non-stream | 两种模式逐 cell 相同；每种仅两份 workbook；模块不跨 subsystem；无 `NO_*SYSTEM_INST*` 污染 |
| `04_timeout_cleanup` | 真实 Verdi watchdog 与事务性输出 | rc=124；不发布半截 CSV/XLSX；无 temp/session/EDA 进程残留 |

## 运行

VM 中加载 VCS/Verdi license 环境后执行：

```bash
cd /root/verdi-trace-pre-kdebug-stress
./run_vm_stress_matrix.sh full
```

只跑复杂合成 RTL：

```bash
./run_vm_stress_matrix.sh synthetic
```

只跑真实 XiangShan：

```bash
./run_vm_stress_matrix.sh xiangshan
```

可用环境变量覆盖 KDB、输出目录和单次 Verdi 超时：

```bash
XIANGSHAN_KDB=/path/to/kdb.elab++ \
VM_STRESS_OUT=/root/my_stress_result \
VERDI_TIMEOUT_SEC=600 \
./run_vm_stress_matrix.sh full
```

每个场景只有在内容断言通过后才写 `PASS`。合成 RTL 的 CSV/XLSX/日志会复制到对应场景的
`artifacts/`，临时 KDB 随后清理以节省 VM 磁盘。汇总文件 `summary.json` 保存产物路径、大小和
SHA-256；不能用仅有 rc=0 的日志代替 CSV/XLSX 内容校验。

## 重构后的新增检查

最新的单 bit driver 修复、同一 KDB 的 visible/hidden/stale 源码对照、四态/真实多驱动负例和错误查询检查见
[TRACE_FIX_VALIDATION_20260906.md](TRACE_FIX_VALIDATION_20260906.md)。复现入口包括
`stress/driver_semantics.py`、`stress/driver_four_state.py`、`stress/driver_diagnostics.py`。

`run_xiangshan_stress_matrix.sh` 保存当前核心 `tool_sha256.txt`。子系统对照同时核对各模块
`*_absent_ports.csv` 中的每一个不适用 selected bit，不能用未知 shape/NPI 错误冒充缺失列。

## 多维 loader 专项回归（2026-09-06）

以下专项入口需要单独运行；旧 `full` profile 不会自动包含这些新增用例。
VM 上先加载 VCS/Verdi/Python 环境，并把 `TMPDIR` 和结果放在有空间的原生文件系统中。
本轮使用 `/home/trace-multidim-20260906`，没有复制或重建 XiangShan KDB。

```bash
# 每个 --out 必须为尚不存在的新目录；从工具目录执行。
python3 stress/multidim_loaders.py --out /home/my_multidim_matrix --lanes 4
python3 stress/multidim_constants.py --out /home/my_multidim_constants
python3 stress/multidim_fanout.py --out /home/my_multidim_fanout --fanout 8192 --depth 12 --xlsx

# 强制让名字快捷接口返回空，单独验证 native index fallback。
AUDIT_KDB=/home/my_multidim_matrix/build/simv.daidir/kdb.elab++ \
verdi -batch -nologo -play stress/probe_multidim_mapping.tcl > /home/my_multidim_mapping.log 2>&1
grep -F 'FALLBACK_MAPPING_PASS checked=162' /home/my_multidim_mapping.log
```

| 专项 | 覆盖与断言 |
| --- | --- |
| `multidim_loaders.py` | 九种 packed / unpacked 形状 × visible/hidden/stale 三种源码状态；4 lanes 共 1,049 module 实例；4,440 项精确 driver 位号、sink 集合、full/boundary 与返标正负匹配检查 |
| `multidim_constants.py` | 七种常量 × 八个 scalar bit × visible/hidden；112 组值、精确 reduction loader 和全路径/源文件/行号/RHS offset 证据检查 |
| `probe_multidim_mapping.tcl` | 在真实 KDB 禁用名字快捷接口，162 个 input/output bit 必须通过 indexed fallback 和精确 source 校验；必须检查 PASS 标记，不能只看 Verdi 退出码 |
| `multidim_fanout.py` | 8,192 个负载 / 8,195 个设计 module 实例；40,962 项 sink 集合检查；whole/subvector/scalar/无负载 bit；stream/nonstream XLSX 与长证据页 |

`--depth 0` 是单独的直接扇出 profile，用于验证不展开 assign 时的正确性，不替代默认 depth=12
的跨层传播覆盖。脚本先运行独立的 VCS walking-one / literal 仿真 oracle，再验证 trace。
矩阵结束后恢复原源码；原始 RTL、日志、CSV/XLSX、验证 JSON 与快照哈希保留在结果目录。
详细根因、最终实测数据和边界见 [MULTIDIM_LOADER_FIX_VALIDATION_20260906.md](MULTIDIM_LOADER_FIX_VALIDATION_20260906.md)。

上一阶段独立 oracle 抓到了嵌套表达式常量误判、位范围映射及 loader 位扩散，历史记录见
[TRACE_RELIABILITY_OVERHAUL_20260905.md](TRACE_RELIABILITY_OVERHAUL_20260905.md)，包含
512 目标/5,121 设计 module 实例、8,192 端口、8,192 路扇出和真实 ClockGate 的当时验证。
旧报告中的“通过”只代表当时的断言范围，不能替代当前严格检查。

## 重构前 VM 实测记录（2026-09-05，历史）

测试机为 `root@192.168.31.116`，真实设计复用既有 XiangShan KDB，没有重新生成 RTL 或复制
大型 KDB。结果目录：

```text
/root/xiangshan_pre_kdebug_stress_20260905_r4
/root/vm_synthetic_pre_kdebug_stress_20260905_final_r2
```

真实 XiangShan 的 5 个检查全部通过：

| 检查 | 实测结果 | 时间 / 峰值 RSS |
| --- | --- | --- |
| MSHR 常量 | 32 instances、64 groups；`1'b0=48`、`1'b1=16`；64 条全路径证据 | 1:41 / 1,394,812 KiB |
| Uncache XLSX | 1 instance、3 个 driver endpoint、1 条 boundary | 1:22 / 1,413,336 KiB |
| subsystem non-stream | MSHR=32、LevelGateway=65、ClockGate inventory=279 | 1:32 / 1,364,248 KiB |
| subsystem stream | 与 non-stream 逐单元格一致；两种模式各只生成 2 个 workbook | 1:28 / 1,364,236 KiB |
| watchdog cleanup | 预期 rc=124；半成品=0、残留进程/会话=0 | 1.16 s / 1,720 KiB |

subsystem 输出的精确数据行数为：MSHR full/boundary=`320/192`，LevelGateway
full/boundary=`455/65`；两种模式共包含 194 个预期的 `NO_TRACE` 单元格，未出现
`NO_SYSTEM_INSTENCE`、`NO_SUBSYSTEM_INSTANCE` 或模块跨 subsystem 污染。

复杂合成 RTL 的 4 个检查也全部通过：39 个 unittest 用时 18 秒，`tool_all_features` 用时
709 秒，`scopefix_pressure` 用时 96 秒，`loader_pressure` 用时 36 秒。它们覆盖精确 bit、
常量、assign/concat/slice、参数化端口、generate、跨层 wrapper、三目停止点、RegCombo、
高 fanout、同名 decoy、CSV/XLSX 及两套 subsystem 返标。

另用两个独立 XLSX 读取器检查并渲染了代表性输出：Uncache `2x4`、MSHR `33x7`、
LevelGateway `66x7`、合成全特性 `6x37`；均可完整读取，无公式单元格或损坏文件。
