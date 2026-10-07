# §4 调度策略插件与 Mutation 机制深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，build-debug 实测（AArch64 -O2, -debug-only=machine-scheduler）。
> 引用格式 `文件:行号`；实测素材 `Sched-notes/scratch/t1.ll`。
> 素材来源：子代理调研（引用已核实，两处任务假设证伪）+ 主会话补动态验证与代写。

**两处任务假设证伪**：
1. 头文件是 `TargetSchedule.h`（类 TargetSchedModel）——`TargetSchedModel.h` 不存在
2. 本树无 `createTargetSchedDAG` hook——实际入口是 `TargetMachine::createMachineScheduler/createPostMachineScheduler`（TargetMachine.h:167-187，返回 nullptr 用默认）；SPIRV 也无此 hook（VLIW 实例是 Hexagon/R600）

---

## 4.1 GenericScheduler（默认策略）

- 声明：MachineScheduler.h:1095（GenericSchedulerBase）/ :1265（GenericScheduler）
- **CandReason 枚举即优先级序**（:1099-1117）：Only1 > PhysReg > RegExcess > RegCritical > Stall > Cluster > Weak > RegMax > ResourceReduce > ResourceDemand > BotHeightReduce/BotPathReduce/TopDepthReduce/TopPathReduce > NodeOrder
- initialize()（cpp:3657-3685）：Rem.init + Top/Bot.init + **HazardRecognizer 挂载** TII->CreateTargetMIHazardRecognizer（:3676-79）
- initPolicy()（:3688-3736）：压力跟踪启发式 NumRegionInstrs > NIntRegs/2（:3699-3707）；**默认 OnlyBottomUp=true**（:3711，注释"bottom-up…simpler and more compile-time optimizations"）；subtarget overrideSchedPolicy（:3715）
- setPolicy（:3294-3346）：区域内外资源/延迟比较 → ReduceLatency（RemLatency+CurrCycle > Rem.CriticalPath）/ ReduceResIdx=ZoneCritResIdx / DemandResIdx=OtherCritIdx
- tryCandidate（:3965-4070）：完整启发式瀑布；跨边界比较（SameBoundary=nullptr）只比较子集（:3997）
- pickNodeBidirectional（:4102-4177）：Bot/TopCand 缓存+策略失效重选；pickNode（:4180-4253）三模式分派
- SchedRemainder（h:617-641）消费 getNumMicroOps×MicroOpFactor 与 WriteProcRes×ResourceFactor；SchedBoundary（h:861-1090）持有 HazardRec（h:877）、ReservedCycles/ResourceSegments（h:656-856 区间表）
- checkHazard（cpp:2716 起）：HazardRec+IssueWidth+BeginGroup/EndGroup+预留资源冲突
- **默认策略覆盖多数 target 的原因**：全部权重从 MachineModel 经 TargetSchedModel 派生（表驱动），区域策略延迟/资源受限自动切换，target 零代码（overrideSchedPolicy 仅调参）

## 4.2 TargetSchedModel 查询层

- init（TargetSchedule.cpp:43-66）：**ResourceLCM=lcm(IssueWidth, 各 NumUnits)**，MicroOpFactor/ResourceFactors 归一化——**跨资源可比较的关键**
- MicroOp→ProcResource 映射消费点：SchedRemainder::init（MS.cpp:2547-2555）、bumpNode（:2998）、SchedCandidate::initResourceDelta（:3254-3269）
- readAdvance/latency：computeOperandLatency（TS.cpp:169-234），`Latency - getReadAdvanceCycles(...)`（:214-217）；capLatency 负值→1000（:110）
- TSI hooks：resolveSchedClass（TargetSubtargetInfo.h:176，variant 类运行时解析）；getWriteProcResBegin/End、getWriteLatencyEntry、getReadAdvanceCycles（MCSubtargetInfo.h:242-259，表查找）；isZeroIdiom/isDependencyBreaking（TSI.h:~190，MachineScheduler 核心不用）

## 4.3 Mutation 机制（本章核心）

- 协议：`ScheduleDAGMutation.h` 单虚函数 `apply(ScheduleDAGInstrs*)`；注册接口 **ScheduleDAGMI::addMutation**（h:361-364，按添加顺序、DAG 构建后、策略初始化前执行）
- **回调时序**（schedule 驱动，cpp:1057-1129 / Live 版 :1691-1749）：buildSchedGraph → **postProcessDAG（:1132-1135 逐个 apply）** → findRootsAndBiasEdges → SchedImpl->initialize → initQueues → pick/schedNode 循环。**Mutation 仅在每区域发射前运行一次——协议不支持发射中突变**，"已发射不可变"约束由结构保证（发射时 Mutations 已消费完）
- **AMDGPU 挂载**（AMDGPUTargetMachine.cpp）：gcn-max-occupancy 工厂 :783-796 依次 addMutation(LoadCluster/StoreCluster/IGroupLP-Initial/MacroFusion/ExportClustering/BarrierLatency/HazardLatency)；PostRA :1462-1475 含 IGroupLP-PostRA + VOPDPairing
- **MacroFusion**（CodeGen/MacroFusion.cpp）：fuseInstructionPair 加 Cluster 弱边+**双向 Artificial 绑定边**（防他人插入中间）+latency→0；AMDGPU 谓词（AMDGPUMacroFusion.cpp:25-52：V_ADDC/V_SUBB/V_CNDMASK 聚簇 VCC 供 VOP2 缩编码）
- **IGroupLP**（AMDGPUIGroupLP.cpp:2447/2706-2742）：识别 SCHED_BARRIER/SCHED_GROUP_BARRIER/IGLP_OPT 内建，PipelineSolver 求解后 addEdge(Artificial)（:2501）
- 通用工厂默认注册 CopyConstrain（h:1431-1442；cpp:2298/2466）

## 4.4 换整个调度器（五级定制谱系）

- **MachineScheduler.h:9-70 头注释载明五级**：substitutePass → createMachineScheduler → 换 Strategy → addMutation → overrideSchedPolicy
- 选择顺序（cpp:534-546）：`-misched=` CLI（MachineSchedOpt :465）→ TM hook → createSchedLive 默认
- 实例：AMDGPU SIScheduleDAGMI（SIMachineScheduler.h:422，override schedule()，Registry "si" TM.cpp:851）；Hexagon VLIW（HexagonTargetMachine.cpp:185-195/356-358）；R600（R600TargetMachine.cpp:106）
- **两级对比**：换 Strategy 保留队列/压力/mutation 基建（GCNMaxOccupancySchedStrategy 即 GenericScheduler 子类）；换整个 DAG 适用于列表调度模型本身不适用时（打包、块调度、迭代式）

## 4.5 MachineTraceMetrics（消费者视角，一行引用）

**GenericScheduler 不消费它**——MachineScheduler.cpp:1785-1789 注释明言"could use…MachineTraceMetrics instead. However, MachineTraceMetrics is not currently available for use in the scheduler"。其消费者是 ILP 优化 pass（EarlyIfConversion/MachineCombiner 等，TargetPassConfig.h:367-372）。

## 4.6 动态验证（实测）

AArch64 -O2（t1.ll）默认策略日志：
```
ScheduleDAGMILive::schedule starting
GenericScheduler RegionPolicy: ShouldTrackPressure=0 OnlyTopDown=0 OnlyBottomUp=0
** ScheduleDAGMILive::schedule picking next node
Pick Bot Cand SU(4) ONLY1      [pre-RA]    ← Only1 最高优先级实证
```
`-misched=` 可用名（Registry）：default/converge/ilpmax/ilpmin/shuffler + si/gcn-max-occupancy/gcn-max-ilp/gcn-max-memory-clause/gcn-iterative-*/hexagon。

## 4.7 昇腾映射（推理级，待验证）——三层挂载判据

| 约束类型 | 挂载层 | 理由 |
|---|---|---|
| 偏好性聚簇（如 repeat 配对、MacroFusion 式） | **Mutation** | 图级重构+Artificial 绑定边防插入；发射前一次性运行 |
| 发射期正确性互锁（如 cmpmask 只在装载后首条有效） | **HazardRecognizer** | 发射检查时点正确；Pre-RA 内嵌/PostRA 独立 pass 两形态 |
| 可枚举但不规则的时序模式 | **表驱动**（GCNHazardRecognizer 式 4,361 行） | 规则密度高+条件复杂时表优于代码 |
| 规则占用冲突（结构化资源） | **MachineModel**（BufferSize=0 走 getNextResourceCycle 预留表） | 声明式+TargetSchedModel 自动消费 |

**dav-m200 判定**：cmpmask"仅装载后第一条 vsel 有效"是发射期正确性约束 → **HazardRecognizer 层**（表驱动实现）；多 repeat 不可用若属结构限制 → MachineModel BufferSize；若想聚簇 repeat 配对提升性能（非正确性）→ Mutation。

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| MachineScheduler.h:9-70, 361-364, 617-641, 656-856, 861-1090, 1095-1117, 1265, 1431-1442 | 谱系/Mutation/SchedBoundary/策略 |
| MachineScheduler.cpp:465, 534-546, 1057-1135, 1691-1749, 1785-1789, 2298, 2466, 2540-2559, 2716, 2920-3120, 3254-3346, 3657-3736, 3965-4253 | 驱动/策略/资源 |
| TargetSchedule.cpp:43-66, 110, 169-234 | TSI 查询 |
| TargetSubtargetInfo.h:176 / MCSubtargetInfo.h:242-259 | TSI hooks |
| AMDGPUTargetMachine.cpp:783-796, 1462-1475 / AMDGPUMacroFusion.cpp:25-52 / AMDGPUIGroupLP.cpp:2447-2501, 2706-2742 | 挂载实例（引用） |
| TargetMachine.h:167-187 | createMachineScheduler |

实测素材：scratch/t1.ll（ONLY1 最高优先级/RegionPolicy 日志）。
