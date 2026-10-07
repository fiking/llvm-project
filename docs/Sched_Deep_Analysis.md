# LLVM 指令调度通用基础设施深度分析

> 数据基准：llvm-project main @ `3eda2aebadd4`（2026-09-30），build-debug 实测。
> 方法：静态分析（引用一律 `文件:行号`，6 个子代理+主会话全部实读核对）+ 动态验证（misched 全家日志/边类型全谱/Top-Bot 交替序列/pipeliner SUnit dump/双 PostRA 形态互证）。
> 九部曲定位：横向对比 → AMDGPU 后端 → NVPTX 后端 → clang-AMDGPU → clang-NVPTX → RA → ISel → **本文档（Sched 通用基础设施——九部曲收官）**。
> 素材全文：`Sched-notes/00~05-*.md`（1,269 行）；scratch/ 存实测产物。

---

## 目录

- §1 摘要与核心论点
- §2 调度 DAG 构建（Region/边分类/SUnit）
- §3 列表调度骨架（SchedBoundary/水位/决策序）
- §4 策略插件与 Mutation
- §5 HazardRecognizer 协议
- §6 三时点分工
- §7 专项调度器
- §8 与九部曲衔接
- §9 昇腾映射
- §10 复现手册

---

## §1 摘要与核心论点

> **通用调度是"Region 化 DAG 构建 + 骨架固定策略全插拔的列表调度 + 三时点分工"**。Region 绝不跨 MBB（call/terminator 再切细）；列表调度骨架（SchedBoundary 双向队列+资源计数+hazard 预过滤）不可替换，策略（GenericScheduler 权重/MachineModel 表/Mutation 图突变）全可插拔；三个时点各司其职：**SDAG 内联**（ISel 末尾顺带，MISched target 退化为 SourceOrder）→ **Pre-RA MISched**（虚拟 reg+压力感知，双向队列）→ **PostRA**（物理 reg+hazard 驱动，两形态：老 List 调度器与新 MISched-PostRA 由 target substitutePass 二选一）。

**三个中间层三种插件风格**（九部曲横向结论）：RA="策略可换地基固定"；ISel="两路线+fallback"；Sched="**骨架固定+策略全插拔+五级定制谱系**"（substitutePass → createMachineScheduler → 换 Strategy → addMutation → overrideSchedPolicy）。

**五个贯穿性实证**：
1. **无 InstrEmitter**（grep 0 命中）：MISched 只重排不重建 MI（moveInstruction 就地 splice :1024）——保 LiveIntervals 的前提
2. **边类型全谱一次实测**：Data/Ord-Memory/Ord-Barrier/ExitSU-Artificial/Anti(post-RA)/Cluster(mutation 后)；**load-load 无边**（跨对象靠 mutation 聚簇）
3. **Top=延迟/Bot=压力主从格局**：PressureDiffs 仅 bottom-up 维护（.h:441-443）、默认 OnlyBottomUp=true（:3711）；1,142 行日志实证交替序列与延迟翻转（`RemainingLatency 10+2c > CritPath 11` → Top 胜出）
4. **Mutation 结构性安全**：仅在每区域发射前 postProcessDAG 运行一次（:1132-1135）——发射时已消费完，"已发射不可变"无需运行时检查
5. **AArch64 不跑老 PostRA 调度器**（:594-595 substitutePass 换成 PostMachineScheduler）——anti-dep breaking 在 AArch64 根本不发生

---

## §2 调度 DAG 构建

**详见 `01-dag.md`**

- **Region = MBB 内指令区间**，绝不跨 MBB；getSchedRegions 自底向上扫描、isSchedBoundary（isCall/terminator/INLINEASM_BR/SP 修改）切分；协议 scheduleRegions→startBlock→(enterRegion→schedule→exitRegion)*
- **边判定序**：寄存器边（先 defs 后 uses）→ ExitSU Artificial → isGlobalMemoryObject 屏障链（volatile/原子/call 进 BarrierChain 全序）→ FP 异常 → 内存边（MayAliasMem）
- SUnit 与 MI 一对一（bundle 算一个）；Depth/Height 预计算；**SDAG 源级与 MI 调度共用 SUnit/SDep**，不共用图构建

## §3 列表调度骨架

**详见 `02-skeleton.md`**

- **主循环**：pickNode→moveInstruction 就地 splice→schedNode→updateQueues
- **水位机制**：PendingQ="依赖归零但 hazard/容量(ReadyListLimit=256)不允许的观察区"（releaseNode :2818-2863）；Available 空则 bumpCycle 硬推进
- **双层过滤**：hazard 机制层预过滤（不在谓词链内）+ tryCandidate 策略层 15 级瀑布（Only1>PhysReg>RegExcess>RegCritical>Stall>Cluster>Weak>RegMax>Resource>Latency>NodeOrder）
- 压力感知：shouldTrackPressure（enterRegion 时 DAG 构建前）+ RegionPressure 窗口

## §4 策略插件与 Mutation

**详见 `03-policy.md`**

- **GenericScheduler 默认策略覆盖多数 target 的原因**：全部权重从 MachineModel 经 TargetSchedModel 派生（表驱动）+ 区域策略延迟/资源受限自动切换 + target 零代码
- **TargetSchedModel**：ResourceLCM=lcm(IssueWidth,NumUnits) 归一化——跨资源可比较的关键
- **Mutation 协议**：ScheduleDAGMutation 单虚函数 apply；addMutation 注册（h:361-364）；AMDGPU 挂 7 个（LoadCluster/StoreCluster/IGroupLP/MacroFusion/ExportClustering/BarrierLatency/HazardLatency——TM.cpp:783-796）；MacroFusion=Cluster 弱边+双向 Artificial 绑定边+latency→0
- 勘误：无 createTargetSchedDAG hook（真名 createMachineScheduler，TargetMachine.h:167-187）；MachineTraceMetrics 不被调度器消费（:1785-1789 注释自述）

## §5 HazardRecognizer 协议

**详见 `04-hazard.md`**

- **三态真义**：NoHazard/Hazard/NoopHazard——分界是"**谁来修复**"（换指令 vs 垫 nop）；任务书设想的 NoHazardAtThisTime 不存在（"推进周期可以"=Hazard+AdvanceCycle+Stalls 重问循环）
- **Scoreboard=Itinerary 的通用执行器**（时间片循环位图，双表 Required/Reserved）；MaxLookAhead=0 即禁用（AArch64 实证）
- **Multi=短路或组合**（顺序敏感，PreEmitNoops 取 max）；唯一消费者 ARM
- **PostRAHazardRecognizer 是完整独立 pass**（四参工厂全仓库仅 AMDGPU 实现；跨基本块不 Reset；只走三步协议）
- **四类消费点**：MISched SchedBoundary（只 Stalls=0）/老 PostRA（全五步）/独立 pass/SDAG-VLIW

## §6 三时点分工

**详见 `05-timing.md`**

| 时点 | 调度器 | 寄存器 | 压力感知 | 形态 |
|---|---|---|---|---|
| SDAG 内联 | ScheduleDAGSDNodes | 无（DAG） | 无 | ISel 末尾 Scheduler->Run（:1157-1177）；MISched target 走 SourceOrder 退化（:311-314） |
| Pre-RA | MachineScheduler | 虚拟 | 有（双向队列+PressureDiffs） | 独立 pass |
| PostRA | 老 PostRASchedulerList vs 新 PostMachineScheduler | 物理 | 无（NoVRegs :108-110，":326-329 注释——post-ra 不担心跨 call 压力"） | target substitutePass 二选一 |

## §7 专项调度器

**详见 `05-timing.md` §4-5**

- **ModuloSchedule（软件流水/SMS）**：MII 约束求解（ResMII/DepMII）；AArch64 需显式 `-aarch64-enable-pipeliner`（默认 false :217-220）——pipeliner 日志 SUnit dump 实测可见
- **VLIWMachineScheduler**：打包发射（Hexagon DFAPacketizer）；**WindowScheduler**：pipeliner 族窗口重排
- DEBUG_TYPE 归属：ModuloSchedule/WindowScheduler 共用 "pipeliner"——同族证据

---

## §8 与九部曲衔接：变体在本体上的位置

| 变体 | 位置 | 引用 |
|---|---|---|
| AMDGPU 5-stage/GCNSchedStrategy | 换 Strategy+addMutation×7+SIScheduleDAGMI（五级谱系全用到）；GCNHazardRecognizer=独立 pass 极端形态 | AMDGPU-notes/06/07 |
| NVPTX NoItineraries | 无 MachineModel 资源表→调度只剩依赖序；disabled PostRAScheduler 双保险 | NVPTX-notes/03/04 |
| AArch64 | PostRA 槽 substitutePass 换新形态；Scoreboard 禁用（无 Itinerary） | 04-hazard/05-timing 附录 |

## §9 昇腾映射（汇总，推理级标"待验证"）

**dav-m200 约束挂载层判定**（详见 03-policy §4.7 判据表 + 04-hazard §昇腾节）：
1. **cmpmask"仅装载后首条 vsel 有效"**：一次性令牌语义——纯 Scoreboard 时间窗表达不了（EmitInstruction 只置位不清位）；方案是**自定义子识别器+MultiHazardRecognizer 组合**（仿 ARM FPMLx 的 LastMI/Stalls 模式）→ HazardRecognizer 层
2. **性能性 repeat 配对聚簇** → Mutation 层（MacroFusion 式 Artificial 绑定边）
3. **结构化资源占用冲突** → MachineModel（BufferSize=0 预留表）

**PyPTO tile 流水线借鉴**：
- 双端调度：生产端≈Top（延迟/getUnscheduledLatency 看 height）/消费端≈Bot（压力/PressureDiffs 账本）
- 只重排不重建（moveInstruction 就地 splice）——tile 调度若同路线，UB 活跃信息无需重建
- 边分类：UB 数据流=Data；跨通道互斥=Ord 类比（UB 地址可静态判定可升级 must-alias）；set_cmpmask/barrier=BarrierChain；live-out=ExitSU Artificial
- 延迟翻转机制（RemainingLatency+CurrCycle>CritPath 切 ReduceLatency）可仿"搬运远、计算近"自动权衡
- 三时点对应：tile 级编排≈Source-level / UB 分配前≈Pre-RA 类比（推理）

## §10 复现手册

```bash
cd ~/code/llvm-project   # main @ 3eda2aebadd4
LLC=build-debug/bin/llc

# DAG 构建与边类型（注意：是 machine-scheduler 不是 misched！）
$LLC -mtriple=aarch64 -O2 -debug-only=machine-scheduler -o /dev/null Sched-notes/scratch/ls_barrier.ll 2>&1 | grep -E "Data Latency|Ord Latency|ExitSU"
# Region 切分
$LLC -mtriple=aarch64 -O2 -debug-only=machine-scheduler -o /dev/null Sched-notes/scratch/regions.ll 2>&1 | grep -iE "region|ScheduleDAGMILive"
# Top/Bot 交替与水位（1,142 行完整日志）
$LLC -mtriple=aarch64 -O2 -debug-only=machine-scheduler -misched-prera-direction=bidirectional -o /dev/null Sched-notes/scratch/tb.ll
# 策略与 ONLY1 最高优先级
$LLC -mtriple=aarch64 -O2 -debug-only=machine-scheduler -o /dev/null Sched-notes/scratch/t1.ll 2>&1 | grep "Pick"
# Hazard 预过滤 + Scoreboard 禁用
$LLC -mtriple=aarch64 -O2 -debug-only=machine-scheduler -o /dev/null Sched-notes/scratch/hazard1.ll 2>&1 | grep -iE "hazard|scoreboard"
# 老 PostRA（AArch64 空输出——被 substitutePass 换掉，此为预期）
$LLC -mtriple=aarch64 -O3 -debug-only=post-RA-sched -o /dev/null scratch/antidep.ll
# 软件流水（需显式开启）
$LLC -O3 -mtriple=aarch64 -aarch64-enable-pipeliner -debug-only=pipeliner -o /dev/null scratch/loop.ll 2>&1 | head
# -misched= 可用策略名
$LLC -mtriple=aarch64 -O2 -misched=... --help-hidden 2>&1 | grep -A2 misched
```

---

## 附录：章节-素材对照与执行注记

| 章 | 素材 | 产出方式 |
|---|---|---|
| §2 | 01-dag.md（262 行） | 子代理主体+主会话补验证/映射/清单三节 |
| §3 | 02-skeleton.md（346 行） | 子代理 33.5KB 主体+主会话补 §3.6/3.7/清单+占位清理 |
| §4 | 03-policy.md | 子代理调研+主会话补 ONLY1 实测代写 |
| §5 | 04-hazard.md（356 行） | 子代理 30KB 主体+主会话补动态验证附录 |
| §6+§7 | 05-timing.md（176 行） | 子代理成稿 python 提取+主会话补 pipeliner 实测 |

执行注记：1 主会话 + 6 子代理；任务假设证伪 **10 处**（NoHazardAtThisTime/StickyConstraint/PostRAHazard 薄壳/createTargetSchedDAG/handlePressure/pickNodeChoice/TargetSchedModel.h/debug-only=misched 通道/AArch64 老 PostRA 运行/loop.ll 落点）；三处子代理路径坑（scratch 落仓库根/相对路径跑 llc）已补跑修正。
