# §8 AMDGPU 机器调度深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，本仓库工作区实测（build-debug, gfx1100, O3）。
> 引用格式 `文件:行号`；实测素材在 `AMDGPU-notes/scratch/`（sched_spill80.ll / sched_hp3.ll / sched_hp5.ll / sched1.log）。
> 素材来源：子代理调研（引用已核实）+ 主会话动态验证补齐。

---

## 8.1 这一层在做什么

AMDGPU 调度是**多阶段多目标**的：occupancy（吞吐）与 ILP（延迟隐藏）互相牵制，单次贪心调度无解。默认调度器 `GCNMaxOccupancyMachineScheduler` 用 **5 个 SchedStage 串联**逼近多目标；`GCNIterativeScheduler` 提供 4 种显式迭代策略；`GCNRegPressure` 用**分域计压**模型给所有决策供数。

## 8.2 调度器选择

`GCNTargetMachine::createMachineScheduler`（AMDGPUTargetMachine.cpp:1425-1453），按 fn attr `amdgpu-sched-strategy` / 命令行分发：`max-ilp` / `max-memory-clause` / `iterative-ilp` / `iterative-minreg` / `iterative-maxocc` / `coexec`，默认 `createGCNMaxOccupancyMachineScheduler`。`getSchedStrategy`（:620-629）。

**DEBUG_TYPE 注意**：SIMachineScheduler.cpp:21 / GCNRegPressure.cpp:25 / GCNIterativeScheduler.cpp:21 均为 **`machine-scheduler`**（没有 gcn-misched）。

## 8.3 Stage 体系：五段逼近多目标

八种 stage 定义在 GCNSchedStrategy.h:39-48；MaxOccupancy 链（cpp:775-786）：

```
OccInitialSchedule → RewriteMFMAForm → UnclusteredHighRPReschedule
→ ClusteredLowOccupancyReschedule → PreRARematerialize
```

- `schedule()` 仅记录 region（cpp:1058-1062，ScheduleSingleMIRegions=:1023），实际调度在 `finalizeSchedule→runSchedStages`（:1197-1269）——**调度是延迟到所有 region 可见后统一决策的**
- 压力反馈：`initCandidate`（cpp:282-425）VGPR>AGPR>SGPR 优先级（:358-363）、Excess/Critical 双阈值、TargetOccupancy 反推 CriticalLimit（:136-214）；`checkScheduling`（:1981-2053）按 WavesAfter/Before 决定回退（`modifyRegionSchedule`）；UnclusteredHighRP 用 ScheduleMetrics bubble 指标算 Profit（:2200-2237）；各 stage `shouldRevertScheduling`（:2169-2268）；PreRARemat 打分（MaxFreq/FreqDiff/RegionImpact，h:660-675）
- Memory-bound occupancy 降级许可（cpp:2014-2021 + `getMinAllowedOccupancy` SIMachineFunctionInfo.h:1214-1218）——§5 PerfHint 链的终点

### 动态验证（实测，gfx1100 O3）

**轻载（sched_hp3.ll，40 divergent loads → NumVgprs=42 < 93）**：
```
Starting occupancy is 16.
Starting scheduling stage: Max Occupancy Initial Schedule
Pressure after scheduling: VGPRs: 42 AGPRs: 0, SGPRs: 2, LVGPR WT: 41   ← 压力日志
Ending scheduling stage: Max Occupancy Initial Schedule
Starting scheduling stage: Unclustered High Register Pressure Reschedule   ← 直接跳过
Starting scheduling stage: Clustered Low Occupancy Reschedule              ← 直接跳过
Starting scheduling stage: Pre-RA Rematerialize
[PreRARemat] Analyzing @k: no objective to achieve, occupancy is maximal at 16
```

**重载（sched_hp5.ll，400 divergent loads → NumVgprs=192，ScratchSize 852）**：
```
Starting occupancy is 16.
... Max Occupancy Initial Schedule: Excess PSets: VGPR_32
    VGPRCriticalLimit = 93, VGPRExcessLimit = 189                    ← 双阈值可见
... Unclustered High RP Reschedule:
    VGPRCriticalLimit = 38 → Reverting scheduling for region 0       ← 实际回退！
    VGPRCriticalLimit = 62 → Reverting scheduling for region 1
    VGPRCriticalLimit = 62 → Reverting scheduling for region 2
... Clustered Low Occupancy Reschedule: VGPRCriticalLimit = 69, 仍 Excess
```
**多阶段回退链被完整实测捕捉**：初始调度超压 → UnclusteredHighRP 逐 region 回退 → ClusteredLowOcc 换目标再试。最终 NumVgprs=192 + spill，occupancy 跌到 ~5（192 VGPR / 512×wave32 → ~5 wave）。

**实测教训**（写进文档供复现）：构造 VGPR 高压必须用 **divergent 基址**（tid 索引）——uniform load 走 SMEM（s_load_b256）不占 VGPR；同址 load 会被 CSE 合并。sched_spill80.ll（uniform 40 loads）实测 NumVgprs=2 正是反例证据。

## 8.4 GCNRegPressure：分域计压

（h:32-195）：4 域 SGPR/VGPR/AGPR/AVGPR + tuple 权重（Value 数组 2×TOTAL_KINDS :181-185）；`getOccupancy=min(SGPR occ, VGPR occ)`（:98-103）；统一寄存器堆 `getUnifiedVGPRNum`（:74-82）；`inc` lane-mask 计压（cpp:52-96）。

`less` 四级比较（cpp:148-246）：**occupancy → spill → tuple → raw**。spill 级含 SGPR→VGPR 换算（`divideCeil(SGPR, WaveSize)`，cpp:100-145）——SGPR spill 到 VGPR lane 后占用要折算进 VGPR 压力（与 §7 SILowerSGPRSpills 呼应）。

GCNRPTarget 三种目标构造（h:223-240）；GCNDownward/UpwardRPTracker（cpp:526-896）。

**与通用 RegPressure 的本质差异**：通用模型只有 PSet（压力集合）计数；GCN 版把"占用率"作为一等公民（getOccupancy 直接换算），且 spill 折算把两个域耦合进比较序。

## 8.5 GCNIterativeScheduler：显式迭代

（645 行）四策略（h:33-38）：`tryMaximizeOccupancy`（:461-501，按压力降序对 region 试 minreg 解）；`scheduleLegacyMaxOccupancy`（:503-561，两遍调度"performance magic" :532-534，未达 TgtOcc 回退 BestSchedule/restoreOrder）；`scheduleMinReg`（:566-593）；`scheduleILP`（:598-645，makeGCNILPScheduler + 失败回退）。`sortRegionsByPressure` 用 `less`（:446-450）；`scheduleRegion` 三重 RP 校验 assert（:435-442）。

**为什么贪心无解**（§8.1 命题的论证）：region A 用 minreg 解省下的寄存器只有分配给 region B 才能提升总 occupancy——这是**跨 region 的全局分配问题**，任何单 region 贪心都只能局部最优。迭代调度器按压力降序逐 region 尝试（:461-501），本质是对全局问题做序列化近似。

## 8.6 发射级优化族

| 优化 | 文件:行号 | 机制 |
|---|---|---|
| GCNCreateVOPD | GCNVOPDUtils.cpp:339-397 | VALU 双发射配对：CanBeVOPD 槽位、无 RAW 依赖、仅 NEG 修饰、literal 总预算≤2、VGPR bank 约束、VOPD3/gfx12 AllowSameVGPR；materializeLiteral 用空闲 SGPR S_MOV_B32（takeFreeSGPR:77-96 避 VCC） |
| AMDGPUMacroFusion | 68 行，:29-50 | V_ADDC/V_SUBB/V_CNDMASK 与 VCC 定义聚簇促 VOP2 缩码 |
| GCNNSAReassign | :146-163, :165-240 | post-RA：CheckNSA + scavengeRegs 将 NSA 地址寄存器重排为连续物理 VGPR |
| AMDGPUExportClustering | :38-80, :107-137 | DAG mutation：POS export 前置 + Barrier/Cluster 边 |

## 8.7 CoExec 与 IGroupLP（gfx950+ 新机制）

- `AMDGPUCoExecSchedStrategy.h` HardwareUnitInfo（:66-146，ProducesCoexecWindow/BufferSize 模型 **LDS 过订阅**）+ CandidateHeuristics（tryMemoryPipeline/tryCriticalResource[Dependency]，:214-313）；仅 gfx950/gfx1250+（AMDGPUTargetMachine.cpp:632, 1446-1450）
- `AMDGPUIGroupLP.h:20-49` SchedulingPhase/SchedGroupMask（VALU/SALU/MFMA/VMEM/DS/TRANS/LDSDMA 位掩码，映射 SCHED_GROUP_BARRIER/IGLP_OPT）；exact vs greedy solver（cpp:18-60）；stage 间 mutation 切换（GCNSchedStrategy.cpp:1428, 1878-1887；GCNIterativeScheduler.cpp:122-140）
- **昇腾视角**：IGroupLP 的"SCHED_GROUP_BARRIER 指令组约束"与 dav-m200 的指令组同步语义同构——昇腾若做指令组级调度约束，这是现成的建模方式

## 8.8 PerfHint→调度完整链（衔接 §5）

```
PerfHintAnalysis 写 fn attr（AMDGPUPerfHintAnalysis.cpp:282-315）
→ AMDGPUMachineFunctionInfo.cpp:52-55 读入 MFI
→ getMinAllowedOccupancy（SIMachineFunctionInfo.h:1214-1218，memory-bound 允许降到 4 waves）
→ GCNSchedStrategy::initialize:156-157（TargetOccupancy）+ RelaxedOcc（cpp:69-73，默认关）
→ checkScheduling:2014-2021（回退判定时用 MinAllowed 而非硬上限）
```

## 8.9 设计动机总结

1. **stage 化是对多目标问题无解析解的工程妥协**：5 个 stage 各有明确目标（初始估计/MFMA 形态修正/高压重试/低占用重排/remat），每个 stage 失败即回退（Revert 实测可见）
2. **压力模型是一切决策的地基**：initCandidate 的优先序、checkScheduling 的回退、iterative 的排序全依赖 GCNRegPressure 的四级比较
3. **调度延迟决策**（finalizeSchedule 统一跑）让跨 region 信息可见——这是与通用 MISched 最大的结构差异

## 8.10 昇腾映射（推理级，待验证）

1. **分域计压 → UB/TMEM/寄存器三资源预算**：GCN 的 4 域模型 + occupancy 换算，直接对应 PyPTO 的"UB 512KB 上限下 tile 怎么放"问题——less 的四级比较（occupancy→spill→tuple→raw）是可以平移的比较序设计
2. **多 stage 回退 → tile 布局搜索**：UnclusteredHighRP 的"试解→度量→Profit 判定→Revert"循环，对应 PyPTO 的 tile 布局试探（放不下就换布局）——bubble 指标（:2200-2237）是现成的"试探质量"度量
3. **IGroupLP 位掩码 → dav-m200 指令组同步**：SCHED_GROUP_BARRIER 的建模可直接借鉴
4. **闭式反函数**（§7.5）+ 迭代调度（§8.5）组合：昇腾资源预算↔吞吐的联动可复用"闭式估计 + 迭代细化"的两层架构

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| AMDGPUTargetMachine.cpp:620-629, 632, 1425-1453, 1446-1450 | 调度器选择 |
| SIMachineScheduler.cpp:21 / GCNRegPressure.cpp:25 / GCNIterativeScheduler.cpp:21 | DEBUG_TYPE |
| GCNSchedStrategy.h:39-48, 660-675 | stage 枚举 / remat 打分 |
| GCNSchedStrategy.cpp:69-73, 136-214, 282-425, 358-363, 775-786, 1023, 1058-1062, 1197-1269, 1428, 1878-1887, 1981-2053, 2014-2021, 2169-2268, 2200-2237 | stage 机制全链 |
| GCNRegPressure.h:32-195, 74-82, 98-103, 181-185, 223-240 | 分域计压 |
| GCNRegPressure.cpp:25, 52-96, 100-145, 148-246, 526-896 | less 四级比较 |
| GCNIterativeScheduler.h:33-38 / .cpp:122-140, 435-450, 461-501, 503-561, 566-593, 598-645 | 迭代调度 |
| GCNVOPDUtils.cpp:77-96, 339-397 | VOPD 配对 |
| AMDGPUCoExecSchedStrategy.h:66-146, 214-313 | CoExec |
| AMDGPUIGroupLP.h:20-49 / .cpp:18-60 | IGroupLP |
| SIMachineFunctionInfo.h:1214-1218 / AMDGPUMachineFunctionInfo.cpp:52-55 / AMDGPUPerfHintAnalysis.cpp:282-315 | PerfHint 链 |

实测素材：scratch/sched_hp3.ll（轻载：压力日志+stage 跳过）、sched_hp5.ll（重载：Excess→Revert 回退链+ScratchSize 852）、sched_spill80.ll（反例：uniform load 走 SMEM 不占 VGPR）。llvm-mca 交叉验证：`./build-debug/bin/llvm-mca -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -all-stats`（注意必须带 -mtriple，否则默认 host triple 报错）。
