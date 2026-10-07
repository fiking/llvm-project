# §3 列表调度骨架 — MachineScheduler 核心抽象深度分析

任务：02-skeleton（Sched-notes）
日期：2026-09-30
基准：llvm-project main @ `3eda2aebadd4`
文件：`llvm/lib/CodeGen/MachineScheduler.cpp`（5,037 行，DEBUG_TYPE="machine-scheduler" :76）
　　　`llvm/lib/CodeGen/ScheduleDAGInstrs.cpp`（1,446 行，共用 DEBUG_TYPE :63）
　　　`llvm/include/llvm/CodeGen/MachineScheduler.h`（1,482 行）
　　　`llvm/include/llvm/CodeGen/ScheduleDAGInstrs.h`（413 行）

> 定位声明：本文分析**通用列表调度骨架本体**（ScheduleDAGMI / ScheduleDAGMILive / SchedBoundary / GenericScheduler）。AMDGPU 的 GCNSchedStrategy / SIMachineScheduler / 5-stage 定制在 AMDGPU-notes/06 已析，本文只在"先例引用"处点名，不展开。

---

## 3.0 总览：两层骨架 + 一个策略插件

```
MachineSchedulerLegacy / MachineSchedulerPass   (pass 层, :378 / :1451)
  └─ MachineSchedulerImpl::run()                 (:541) 创建 ScheduleDAGInstrs 实例
       └─ scheduleRegions()                      (:811) ← §3.1 region 驱动
            └─ Scheduler.enterRegion() / schedule() / exitRegion()
                 ├─ ScheduleDAGMI::schedule()       (:1057) ← PostRA/无压力版驱动
                 ├─ ScheduleDAGMILive::schedule()   (:1691) ← PreRA/带压力版驱动
                 │    主循环: pickNode → (移动 MI) → schedNode → updateQueues
                 └─ MachineSchedStrategy (策略插件, .h:246)
                      ├─ GenericScheduler      (PreRA 默认, :3657-)
                      ├─ PostGenericScheduler  (PostRA 默认, :4331-)
                      └─ ILPScheduler/InstructionShuffler (实验, :4668/:4766)
```

关键设计事实（先给出，逐节论证）：
- **指令不重建**：MISched 在原 MBB 内就地 splice 指令（`moveInstruction` :1024），**不复用 SelectionDAG 的 InstrEmitter**——InstrEmitter 属于 ScheduleDAGSDNodes（SelectionDAG pre-RA-sched）路径，MISched 全文件 0 处引用（已 grep 验证）。
- **双向队列**：每个 SchedBoundary 维护 Available/Pending 两级水位（.h:874-875），Top 与 Bot 各一个 boundary。
- **谓词链比较器**：候选选择不是打分排序，而是 `tryCandidate` 中一串短路谓词（:3965-4070），每个谓词用 `tryLess/tryGreater` 记录胜出理由（CandReason）。

---

## 3.1 ScheduleDAGMI 驱动循环

### 3.1.1 scheduleRegions：Region 循环（外层）

**静态**（MachineScheduler.cpp）：
- `MachineSchedulerBase::scheduleRegions(Scheduler, FixKillFlags)` **:811-898** 是 MachineScheduler 与 PostMachineScheduler 共用的总驱动。
- Region 切分由 `getSchedRegions()` **:768-808** 完成：从 MBB 尾部向前扫，`isSchedBoundary()` **:758** 判定边界——`MI->isCall() || TII->isSchedulingBoundary(...) || MI->isFakeUse()`。注意 region 收集本身是**自底向上**的（`:776` 从 `MBB->end()` 往前），收集完后若 `Scheduler.doMBBSchedRegionsTopDown()` 为真则 reverse（:806-807）——**Region 列表顺序与 Region 内部调度方向无关**。
- 每个 region 的回调序（:846-889）：
  ```
  Scheduler.enterRegion(MBB, I, RegionEnd, NumRegionInstrs)   // :853
  [空/单指令 region 跳过 → exitRegion() :857-861]
  DumpRegionHeader（LLVM_DEBUG, :863-876 → "Current Schedule Region" 行）
  Scheduler.schedule()                                        // :885 ← 真正调度
  Scheduler.exitRegion()                                      // :888
  ```
- 外层逐 MBB：`startBlock(:827) → regions → finishBlock(:890)`，最后 `finalizeSchedule()` :897（ScheduleDAGInstrs.h:347，默认空实现）。
- enterRegion 的三层覆写链：`ScheduleDAGInstrs::enterRegion`（ScheduleDAGInstrs.cpp:182-190，仅存迭代器）→ `ScheduleDAGMI::enterRegion`（:1002-1020，调 `SchedImpl->initPolicy` 并设置 dump 方向）→ `ScheduleDAGMILive::enterRegion`（:1455-1473，设置 `ShouldTrackPressure = SchedImpl->shouldTrackPressure()` **:1468**，`ShouldTrackLaneMasks` :1469，清 SUPressureDiffs）。
- `MachineSchedStrategy` 初始化契约（.h:244-245 注释）：`initPolicy → shouldTrackPressure → initialize(DAG) → registerRoots`。

### 3.1.2 schedule() 主循环：pickNode → move → schedNode → updateQueues（内层）

**静态**：
- `ScheduleDAGMI::schedule()` **:1057-1129**（PostRA/简版）：
  ```
  buildSchedGraph(AA)                    :1062  ← DAG 构建（01-dag 范围）
  postProcessDAG()                       :1064  ← 依序 apply Mutations（:1132-1135）
  findRootsAndBiasEdges(TopRoots,BotRoots) :1067
  SchedImpl->initialize(this)            :1075
  initQueues(TopRoots, BotRoots)         :1078
  while (true):
    checkSchedLimit()                    :1082  ← misched-cutoff 截断
    "** ...picking next node" 日志       :1085  ← 主循环标志行
    SU = SchedImpl->pickNode(IsTopNode)  :1086
    if (!SU) break                       :1087
    [Top: 移到 CurrentTop 前]            :1092-1097
    [Bot: 移到 CurrentBottom 后]         :1098-1110
    SchedImpl->schedNode(SU, IsTopNode)  :1115  ← 先通知策略再更新队列（注释 :1111-1114 解释原因：让 ReadyCycle 先取到 CurrCycle）
    updateQueues(SU, IsTopNode)          :1117
  assert(CurrentTop == CurrentBottom)    :1119  ← "Nonempty unscheduled zone"
  placeDebugValues()                     :1121
  " Final schedule for " + dumpSchedule() :1123-1128
  ```
- `ScheduleDAGMILive::schedule()` **:1691-1749** 与之几乎同构，差异：`buildDAGWithRegPressure()` :1694（内部 RPTracker 压力扫描，:1752-1773）；指令移动封装为 `scheduleMI(SU, IsTopNode)` :1723；DFS 子树调度回调 `scheduleTree(SubtreeID)` :1725-1732。
- `updateQueues` **:1184-1192**：Top 方向调 `releaseSuccessors(SU)`，Bot 方向调 `releasePredecessors(SU)`，置 `SU->isScheduled = true`。
- 依赖释放语义（水位变化的根）：
  - `releaseSucc` **:922-945**：`--SuccSU->NumPredsLeft`；TopReadyCycle 传播 `max(SuccSU->TopReadyCycle, SU->TopReadyCycle + Latency)`（:939-940）；归零且非 ExitSU → `SchedImpl->releaseTopNode(SuccSU)` :944。
  - `releasePred` **:957-980**：镜像操作，BotReadyCycle 传播（:974-975），归零 → `releaseBottomNode` :979。
  - 即 **updateQueues 是"水位闸门"**：每发射一条指令，其反向邻居的计数器减一，归零者进入策略的 release 回调。

**指令发射 = 就地移动，非重建**：
- Top 发射：MI 移到 `CurrentTop` 之前并推进 CurrentTop（:1092-1097）；Bot 发射：MI 移到 `CurrentBottom` 之后（先看 priorII 是否就是 MI，是则只回退 CurrentBottom，否则 splice）。
- `moveInstruction` **:1024-1040**：`BB->splice(InsertPos, BB, MI)` + `LIS->handleMove()` 维护 LiveIntervals。**无 InstrEmitter**——SelectionDAG 的 `ScheduleDAGSDNodes` 才用 InstrEmitter 重建指令流；MISched 保持 MI 对象不动只换位置，这也是它能保留 LiveIntervals 的前提（文件头注释 :9-10 "preserves LiveIntervals so it can be invoked before register allocation"）。

**设计动机**：
- 驱动循环只做"不可变的机械部分"（DAG 生命周期、迭代器维护、依赖计数、Debug 值归位），一切"选谁"的决策全部推给 `MachineSchedStrategy`（.h:246-306 共 14 个虚函数，核心 4 个：`pickNode/schedNode/releaseTopNode/releaseBottomNode`）。schedule() 的注释（:1053-1056, :1685-1690）明说这是 "skeletal driver"——实验调度器只需实现策略接口。
- `scheduleMI` 内先 `schedNode` 后 `updateQueues` 的顺序（:1111-1115 注释）：schedNode 里 `SU->TopReadyCycle = max(..., Top.getCurrCycle())`（GenericScheduler :4287/:4302），若先 release，新释放节点会拿到过期 CurrCycle。

**昇腾映射（推理级，待验证）**：PyPTO 若复用 MISched 骨架，CCE 指令的"发射"同样应是 MIR 就地重排（保留伪指令/夹持信息），而不是重写指令流；`moveInstruction` 的 `LIS->handleMove` 对应 tile 级"数据移动账本"的增量更新点。

---

## 3.2 SchedBoundary：Top/Bottom 双向队列与水位机制

### 3.2.1 结构

**静态**（MachineScheduler.h:858-1090；cpp :2490-3247）：
- `class SchedBoundary`（.h:861），GenericScheduler 持有两个实例 `Top(TopQID,"TopQ") / Bot(BotQID,"BotQ")`（.h:1268-1269）。
- 每个边界两个队列（.h:874-875）：
  - `ReadyQueue Available`（ID=TopQID/BotQID，名字 "TopQ.A"/"BotQ.A"）
  - `ReadyQueue Pending`（ID=`ID << LogMaxQID`，名字 "TopQ.P"/"BotQ.P"，.h:972-975）
- `ReadyQueue`（.h:569-614）是裸 vector + 位掩码：`push` 置 `SU->NodeQueueId |= ID`（:600-603），`remove` 用 swap-back（:605-611）。**不是优先队列**——排序决策完全在策略层扫描时现场比较（pickNodeFromQueue 线性扫）。
- 关键状态字段（.h:879-921）：`CheckPending`（脏标记）、`CurrCycle`、`CurrMOps`（本周期已发微码）、`MinReadyCycle`（最快可用周期）、`ExpectedLatency`/`DependentLatency`、`RetiredMOps`、`ExecutedResCounts[]`、`ZoneCritResIdx`、`IsResourceLimited`、`ReservedCycles[]`（按资源实例）与 `ReservedResourceSegments`（区间版，`enableIntervals()` 时启用，.h:927-928）。

### 3.2.2 水位机制：为什么有 Pending

**静态**：
- 入口 `releaseNode(SU, ReadyCycle, InPQueue, Idx)` **:2818-2863** 的三段判定：
  1. 依赖已满足（release 回调到达）→ 先查 hazard：非缓冲机器上 `ReadyCycle > CurrCycle` 即软 hazard（:2835-2841，日志 "hazard: SU(n) ReadyCycle = X is later than CurrCycle = Y on an unbuffered resource"）；否则 `checkHazard(SU)`（:2843）。
  2. `Available.size() >= ReadyListLimit`（misched-limit 默认 256，:249-250）→ 也当 hazard 塞进 Pending（:2845-2849）。
  3. 无 hazard → `Available.push(SU)`（:2852，日志 "Move SU(n) into Available Q"）；有 → `Pending.push(SU)`（:2862）。
- **PendingQ 的语义**："依赖计数已归零（数据流上就绪）但**当前 cycle/资源/队列容量不允许发射**的观察区"。它存在的原因：
  1. **语义清晰**：Available 里的节点对启发式可见（"an instruction that cannot issue appears as if it's not in the ReadyQueue"，:2833-2834 注释），启发式不会被 hazard 节点污染。
  2. **复杂度护栏**：ReadyListLimit 防"超大基本块二次方复杂度"（:247-248 注释）。
  3. **重试有界**：`MaxObservedStall`（ABI-breaking checks 下，.h:963-967）记录最大 stall，作为重试次数上界（pickOnlyChoice 里被注释掉的 assert :3178-3180 引用）。
- 出口 `releasePending()` **:3123-3149**：`CheckPending` 脏标记触发（bumpCycle :2895 / bumpNode HazardRec 分支 :3093 置位）；Available 空时重置 MinReadyCycle（:3125-3126）；逐个 Pending 节点再跑 releaseNode（:3142）。
- `pickOnlyChoice()` **:3164-3192**：先 releasePending，再把 Available 中新产生 hazard 的节点降级回 Pending（:3169-3176），然后 **`while (Available.empty()) bumpCycle(CurrCycle+1)`**（:3177-3184）——时间前进直到有节点可用；Available.size()==1 时直接返回（Only1 决策路径）。

### 3.2.3 Top 与 Bottom 各看什么

**静态证据（论证"Top=延迟视角 / Bot=压力视角"）**：
1. **延迟方向**：`getUnscheduledLatency(SU)` .h:1005-1007 —— `isTop() ? SU->getHeight() : SU->getDepth()`。Top 剩余量=该节点到出口的最长路（height），Bot 剩余量=该节点到入口的最长路（depth）。
2. **压力方向**：ScheduleDAGMILive::scheduleMI **:1886-1953**——Top 发射时 `TopRPTracker.advance()`（:1908）算"向下压力"；Bot 发射时 `BotRPTracker.recede(&LiveUses)`（:1945）并向 `updatePressureDiffs(LiveUses)` 反馈（:1951）。而 **SUPressureDiffs 的注释**（.h:441-443）："This array is updated for liveness during **bottom-up** scheduling. Top-down scheduling may proceed but has no affect on the pressure diffs"——压力差分账本本质上是 Bottom 方向的产物。
3. **策略不对称**：initPolicy **:3709-3711** "For generic targets, we default to **bottom-up**, because it's simpler and more compile-time optimizations have been implemented in that direction"（`RegionPolicy.OnlyBottomUp = true`）。Bot 是主方向，Top 是"收敛器"。
4. **候选缓存**：`TopCand/BotCand`（.h:1319-1322）缓存上一轮候选，pickNodeBidirectional :4124-4162 中只有 `Policy != 旧 Policy` 或已调度才重算——两个方向各自维护增量视角。
5. **双向收敛的语义**：pickNodeBidirectional :4102-4177 注释 "Schedule as far as possible in the direction of no choice... also provides the best heuristics for CriticalPSets"。当某方向 pickOnlyChoice 命中（无选择）就直接从该方向取；否则两方向各选一个候选，再 `tryCandidate(Cand=BotCand, TopCand, Zone=nullptr)`（:4167-4172，**跨边界比较走简化谓词集**，:3992-3997 注释 "We only compare a subset of features when comparing nodes between Top and Bottom boundary"）。
6. **ReadyCycle 双轨**：SUnit 同时带 `TopReadyCycle`（"Cycle relative to start when node is ready"）与 `BotReadyCycle`（"relative to end"，ScheduleDAG.h:286-287）；bumpNode 里 Top 方向维护 ExpectedLatency/DependentLatency 的角色对调（:3062-3063 `TopLatency = isTop() ? ExpectedLatency : DependentLatency`）。
7. **bumpNode 的分组约束方向**：mustEndGroup 在 Top 方向触发 bump、mustBeginGroup 在 Bot 方向触发（:3106-3107）——发射组边界在两个方向上是镜像的。

**结论（论证）**：Top 方向的天然量是 height/ExpectedLatency（"从这里到结束还有多远"→延迟视角）；Bot 方向的天然量是 depth + 压力差分账本（"从开始到这里积累了多少 live range"→压力视角）。**但这不是硬编码的二分**——双向模式（bidirectional）下两边都跑全部谓词，setPolicy（:3294-3346）按"区内临界资源 vs 区外临界资源"给两个方向分别设 ReduceResIdx/DemandResIdx/ReduceLatency。Top=延迟、Bot=压力是**默认权重与账本归属造成的主从格局**，不是类型系统强制。

### 3.2.4 bumpCycle / 资源推进

**静态**：`bumpCycle(NextCycle)` **:2866-2902**：
- 全序机器（MicroOpBufferSize==0）下 NextCycle 不早于 MinReadyCycle（:2867-2872）。
- `CurrMOps` 按 issue 宽度折算衰减（:2874-2875）；`DependentLatency` 随周期递减（:2878-2881）。
- HazardRec 使能时逐周期 `AdvanceCycle()`（Top）/`RecedeCycle()`（Bot）（:2883-2894）——**方向镜像**再次出现。
- 置 `CheckPending = true`（:2895）；重算 `IsResourceLimited = checkResourceLimit(LFactor, getCriticalCount(), getScheduledLatency(), true)`（:2896-2898）。
- 日志行："Cycle: N TopQ/BotQ"（:2900-2901）。
- `bumpNode(SU)` **:2957-3119**：三档 MicroOpBufferSize 语义（0=严格顺序断言、1=stall 到 ReadyCycle、默认=OOO 近似仅 unbuffered 资源 stall，:2970-2988）；`RetiredMOps += IncMOps`（:2989）；`Rem->RemIssueCount -=`（:2993-2995）；逐资源 `countResource`（:3011-3019）→ `ReservedCycles[InstanceIdx]` 更新（Top: `max(ReservedUntil, NextCycle+ReleaseAtCycle)` / Bot: `NextCycle`，:3051-3055；区间版 :3031-3045）；ExpectedLatency/DependentLatency 更新（:3061-3073）；必要处 bumpCycle（:3074-3076）；HazardRec `EmitInstruction(SU)`（:3085-3094，Bot 方向 SU->isCall 时先 Reset :3086-3090）；`CurrMOps` 溢出 issue width 时循环 bumpCycle（:3113-3117）。

**设计动机**：把"时间"建模为每边界独立的一维坐标（Top 从 0 向上、Bot 从 0 向下），资源冲突在各自坐标轴上用 ReservedCycles/区间表投影，两轴在调度结束时必须"合拢"（assert CurrentTop==CurrentBottom :1119/:1739）。这是列表调度"双向逼近中点"的经典实现。

**昇腾映射（待验证）**：昇腾若做 tile 级软件流水，双边界可类比"生产端（producer 视角，类似 Top：关心到消费还有多远）与消费端（consumer 视角，类似 Bot：关心缓冲占用/压力）"。见 §3.7。

---

## 3.3 资源跟踪：SchedRemainder、边界内计数与 HazardRec

### 3.3.1 SchedRemainder（区域剩余量）

**静态**（.h:616-641；cpp :2540-2560）：
- 字段：`CriticalPath`（区域关键路径）、`CyclicCritPath`、`RemIssueCount`（按 MicroOpFactor 缩放的剩余微码数）、`IsAcyclicLatencyLimited`、`RemainingCounts[]`（每类 ProcResource 的剩余量）。
- `SchedRemainder::init` **:2540-2560**：扫全部 SUnit 累加 `getNumMicroOps * getMicroOpFactor` 与每资源 `Factor * (ReleaseAtCycle - AcquireAtCycle)`。
- **两个 Top/Bot 边界共享同一个 SchedRemainder**（GenericScheduler::initialize :3667-3669：`Rem.init(...); Top.init(DAG,SchedModel,&Rem); Bot.init(DAG,SchedModel,&Rem)`）。剩余量是全局账，已调度量（ExecutedResCounts）是各边界的局部账——**bumpNode 里 countResource :2931-2932 做 `Rem->RemainingCounts[PIdx] -= Count`**，即"扣减发生在被调度侧的边界里，但账本全局"。
- `getOtherResourceCount` **:2791-2816**：`Rem->RemIssueCount + RetiredMOps*MicroOpFactor` 与 `getResourceCount(PIdx) + Rem->RemainingCounts[PIdx]` 取最大——"区外临界资源"（给 setPolicy 用）。日志 "TopQ/BotQ + Remain CritRes: ..." :2810-2814。

### 3.3.2 边界内资源计数

**静态**：
- `ExecutedResCounts[]` + `MaxExecutedResCount`（.h:912-915）：`incExecutedResources` :2904-2908 在 countResource 内调用。
- `countResource` **:2920-2954**：更新临界资源 `ZoneCritResIdx`（:2936-2942，日志 "  *** Critical resource X: Nc"）；查 `getNextResourceCycle` 得 `NextAvailable`（:2945-2952，日志 "  Resource conflict: X[i] reserved until @N"）。
- `getNextResourceCycle` **:2634-2701**：在 PIdx 的所有实例里挑最早可用实例；资源组（isReservedGroup）先看指令是否用了子单元（:2650-2681）。`getNextResourceCycleByInstance` **:2609-2629**：区间模式走 `getFirstAvailableAtFromTop/Bottom`；标量模式 `ReservedCycles[InstanceIdx]`（Bot 方向还要 `max(CurrCycle, NextUnreserved + ReleaseAtCycle)` :2626-2627）。
- 资源区间表 `ResourceSegments`（.h:656-856）：闭开区间集合；Top 公式 `[C+AcquireAtCycle, C+ReleaseAtCycle)`，Bot 公式 `[C-ReleaseAtCycle+1, C-AcquireAtCycle+1)`（.h:701-755 大段 ASCII 图解）。`getFirstAvailableAt` 把新区间沿时间轴右移直到不与已记区间相交（.h:758-807）。
- `checkResourceLimit(LFactor, Count, Latency, AfterSchedNode)` **:2498-2505**：`Count - Latency*LFactor` 与 LFactor 比较——**"资源受限"判据是：临界资源占用超过延迟覆盖量的一个周期当量**。
- `dumpScheduledState` **:3225-3247**：每边界状态摘要（Retired/Executed/Critical/ExpectedLatency/Resource-or-Latency limited）。`dumpReservedCycles` :3199-3221（misched-dump-reserved-cycles 打开）。

### 3.3.3 HazardRec 在边界内的角色（内嵌使用）

**静态**：
- 每个边界**内嵌持有** `std::unique_ptr<ScheduleHazardRecognizer> HazardRec`（.h:877），在 GenericScheduler::initialize :3673-3679 由 `TII->CreateTargetMIHazardRecognizer(Itin, DAG)` 创建——**同一调度器有两个独立 HazardRec 实例（Top/Bot 各一）**。
- 使用点（全部在 SchedBoundary 成员内）：
  1. `checkHazard(SU)` **:2716-2722**：`HazardRec->getHazardType(SU)` != NoHazard → hazard（日志 "hazard: SU(n) reported by HazardRec"）。checkHazard 的**双模式**注释 :2703-2714：模式一 = ScheduleHazardRecognizer API（通用、支持 Scoreboard 复杂顺序保留表）；模式二 = 调度器自维护的简化计数器（CurrMOps/issue width :2724-2731、mustBegin/EndGroup :2733-2739、ReservedCycles :2741-2765）。
  2. `bumpCycle` **:2883-2894**：AdvanceCycle/RecedeCycle（方向镜像）。
  3. `bumpNode` **:3085-3094**：`HazardRec->EmitInstruction(SU)`；Bot 方向遇 call 先 `Reset()`（:3086-3090）。
- `reset()` :2511-2512 的注释：HazardRec 按 DAG 重建成本高，所以保留 placeholder 而非销毁（"keep invalid, placeholder HazardRecs"）。
- **骨架与 Hazard 协议的分层**：SchedBoundary 内嵌的是"MISched 版"HazardRecognizer（CreateTargetMIHazardRecognizer），与 PostRASchedulerList 使用的 CreateTargetHazardRecognizer 是两个工厂（§5 Hazard 协议详析，此处只定位内嵌角色）。

**设计动机**：资源跟踪三层分工——(a) SchedRemainder 管"全局还剩多少"（策略层视角），(b) 边界内 ExecutedResCounts/ReservedCycles 管"这边已经占了什么"（机制层账本），(c) HazardRec 管"目标想要但不属于资源模型的东西"（itinerary/自定义互锁）。(b) 与 (c) 共存于 checkHazard 的双模式，是因为 GenericScheduler 的资源模型（MCSchedModel）无法表达所有目标特定互锁。

**昇腾映射（待验证）**：昇腾若用 PTO 描述资源，RemainingCounts ↔ tile 流水线里"待占用 stage 数"，ReservedCycles ↔ "功能单元流水占用表"；双实例 HazardRec 对应"生产/消费两端各自的 hazard 判定器"。

---

## 3.4 决策序：谓词链与 tryCandidate 比较框架

> 术语对齐：任务书中的 "pickNodeChoice" 实际函数是 **`pickOnlyChoice`**（:3164）；"tryCandact" 实际是 **`tryCandidate`**（:3965）。"Less 类比较器" = `tryLess/tryGreater/tryLatency/tryPressure/tryBiasPhysRegs`（:3456-3519, :3805-3841, :3895-3915）。

### 3.4.1 pickNode 总入口与 pickOnlyChoice

**静态**：
- `GenericScheduler::pickNode` **:4180-4253**：区域排空判定（`DAG->top() == DAG->bottom()` :4181-4185）；三分支 OnlyTopDown / OnlyBottomUp / pickNodeBidirectional（:4187-4215）；选出后从两边界队列摘除（`SU->isTopReady() → Top.removeReady` :4233-4236，注释 :4218-4232 详述"巧合就绪"场景）；日志 "Scheduling SU(n) ..." :4238。
- `pickOnlyChoice`（见 §3.2.2）：先于一切启发式的**无选择快捷路径**——Available==1 直接返回（省掉全队列扫描+压力预算）；Available==0 时 bumpCycle 硬推进。
- `pickNodeBidirectional` **:4102-4177**：Bot 先 `pickOnlyChoice`（:4105），Top 后（:4110）——**Bot 优先于 Top 的无选择路径**；然后 setPolicy 双向（:4117-4122）；BotCand/TopCand 增量缓存复用（:4126-4162，`VerifyScheduling` 时全量重算并 assert 一致 :4133-4141）；最后跨边界对决 `tryCandidate(Cand, TopCand, nullptr)`（:4169）。

### 3.4.2 setPolicy：谓词链的"前置策略"

**静态**：`GenericSchedulerBase::setPolicy` **:3294-3346** 每 pickNode 一次：
1. 算区外临界资源 `OtherZone->getOtherResourceCount(OtherCritIdx)`（:3302-3304）；
2. `shouldReduceLatency`（:3273-3290：`RemLatency + CurrCycle > Rem.CriticalPath` 或 CurrCycle 已超关键路径）→ `Policy.ReduceLatency = true`（:3319-3327，日志 " RemainingLatency X + Yc > CritPath Z"）；
3. 区内外同资源受限则不动（:3328-3330）；区内资源受限 → `Policy.ReduceResIdx = ZoneCritResIdx`（:3341-3342）；区外受限 → `Policy.DemandResIdx = OtherCritIdx`（:3344-3345）。
- `CandPolicy`（.h:1124-1139）只有三个字段：`ReduceLatency / ReduceResIdx / DemandResIdx`——**策略是谓词链的输入而非谓词本身**。

### 3.4.3 tryCandidate 谓词链（完整优先级序）

**静态**：`GenericScheduler::tryCandidate` **:3965-4070**，短路序（任一谓词分出胜负即 return）：

| 序 | 谓词 | 条件 | 理由枚举 | 行号 |
|---|------|------|---------|------|
| 0 | 初始化 | !Cand.isValid() | FirstValid | :3968-3972 |
| 1 | **物理寄存器偏置** tryBiasPhysRegs | 总是 | PhysReg | :3974-3976 |
| 2 | **压力超额** tryPressure(RPDelta.Excess) | isTrackingPressure | RegExcess | :3978-3983 |
| 3 | **临界压力** tryPressure(RPDelta.CriticalMax) | isTrackingPressure | RegCritical | :3985-3990 |
| — | **SameBoundary 分界**（Zone==nullptr 表示跨边界，跳过 4/6/8/9/10） | | | :3992-3997 |
| 4 | 环路延迟激进 | Rem.IsAcyclicLatencyLimited && !CurrMOps | tryLatency→TopDepth/BotHeight... | :3999-4004 |
| 5 | **stall 周期** getLatencyStallCycles | SameBoundary | Stall | :4006-4009 |
| 6 | **cluster 续接**（CandZoneCluster 匹配） | 总是 | Cluster | :4012-4027 |
| 7 | **弱边** getWeakLeft | SameBoundary | Weak | :4029-4035 |
| 8 | **区域最大压力** tryPressure(RPDelta.CurrentMax) | isTrackingPressure | RegMax | :4037-4042 |
| 9 | **资源削减/需求** ResDelta.CritResources / DemandedResources | SameBoundary | ResourceReduce / ResourceDemand | :4044-4053 |
| 10 | **延迟启发** tryLatency | ReduceLatency && !DisableLatencyHeuristic && !IsAcyclicLatencyLimited | TopDepth/TopPath/BotHeight/BotPath | :4055-4059 |
| 11 | **原始顺序** NodeNum | SameBoundary | NodeOrder | :4061-4066 |

- **注意任务书序 "hazard→资源→寄存器→heuristics" 与实际代码序的差异**：实际是 **PhysReg → 压力(Excess/Critical) → [stall/cluster/weak] → 压力(Max) → 资源 → 延迟 → 顺序**。hazard 不在 tryCandidate 里——**hazard 在更早的机制层**（releaseNode :2836-2843 与 pickOnlyChoice :3169-3176 已把 hazard 节点挡在 Available 之外/降级 Pending），谓词链看到的全是"当前可发射"节点。这是骨架的**双层过滤**设计：机制层管可行性（hazard/依赖/容量），策略层管优劣。
- `tryLatency` **:3488-3519** 方向化：Top 比 depth 小者（若超过 ScheduledLatency 才有意义 :3495-3499）+ height 大者（TopPathReduce :3501-3503）；Bot 镜像（height 小 + depth 大）。
- `tryPressure` **:3805-3841**：一方降一方升 → 降者胜；同边界同 PSet 比 UnitInc 小者；不同 PSet 比 `TRI->getRegPressureSetScore`（降方向时反转 :3838-3839）。

### 3.4.4 tryLess/tryGreater 比较器框架

**静态**：`tryLess` **:3456-3470** / `tryGreater` :3472-3486：
```cpp
bool tryLess(int TryVal, int CandVal, TryCand, Cand, Reason) {
  if (TryVal < CandVal) { TryCand.Reason = Reason; return true; }   // 挑战者胜
  if (TryVal > CandVal) { if (Cand.Reason > Reason) Cand.Reason = Reason; return true; }
  return false;  // 平局 → 链上下一个谓词
}
```
- **设计精妙处**：返回 true 表示"这一维度已分出胜负"（无论谁胜），调用方 return；平局才落空让下个谓词接管。而 `Cand.Reason > Reason` 的方向传播（挑战者更大但当前理由更低优先级时，**顺手把守擂者的 Reason 降级**）保证 trace 出的 Reason 总是"决定性最低的那一级"——便于调试与统计（:3349-3373 getReasonStr + traceCandidate :3375-3425 输出 "  Cand SU(n) REASON ..."）。
- `CandReason` 枚举**本身按优先级排列**（.h:1097-1117 注释 "pickNodeBidirectional depends on these listed by decreasing priority"）：NoCand < Only1 < PhysReg < RegExcess < RegCritical < Stall < Cluster < Weak < RegMax < ResourceReduce < ResourceDemand < BotHeightReduce < BotPathReduce < TopDepthReduce < TopPathReduce < NodeOrder < FirstValid。
- `pickNodeFromQueue` **:4077-4099**：线性扫 Available，每 SU 构造 TryCand → initCandidate（算 RPDelta）→ tryCandidate → setBest + traceCandidate。
- `initCandidate` **:3917-3952**：Top 用 `getMaxDownwardPressureDelta`，Bot 用 `getUpwardPressureDelta`（快路径，PressureDiff 缓存）或 VerifyScheduling 时 `getMaxUpwardPressureDelta`（慢路径全量，:3931-3945）。

**设计动机**：分层谓词 vs 打分模型——源码注释 :3954-3958 明说："Heuristics are currently hierarchical. This may be more efficient than a graduated cost model because we don't need to evaluate all aspects of the model for each node in the queue. **But it's really done to make the heuristics easier to debug and statistically analyze**"。CandReason + traceCandidate + tracePick + STATISTIC 计数器（:78-177 NumXxxPreRA/PostRA 全套）构成可观测性闭环。

**昇腾映射（待验证）**：tile 调度若沿用此框架，谓词链可改造为 "bypass 占用 → stage 压力 → bank 冲突 → 数据局部性" 的层次；CandReason 枚举必须同步重排（枚举值序=优先级序是隐式契约）。

---

## 3.5 压力感知调度：RegionPressure 窗口与两个 hook

### 3.5.1 三 tracker 架构与压力窗口

**静态**：
- ScheduleDAGMILive 持有三个压力账本（.h:447-463）：`RegPressure/RPTracker`（全区域）、`TopPressure/TopRPTracker`、`BotPressure/BotRPTracker`。类型是 `IntervalPressure`（SlotIndex 界定，RegisterPressure.h:68-78）——**RegionPressure**（迭代器界定版，RegisterPressure.h:83-93）是 LIS 不可用时的降级类型，MISched 主路径用 IntervalPressure（"preferable to RegionPressure when LiveIntervals are available"，.h:64-67 注释）。
- `initRegPressure` **:1477-1552**：RPTracker 扫全区域 → closeRegion（:1489）；Top/Bot tracker 分别注入 LiveInRegs/LiveOutRegs（:1494-1495）后 `TopRPTracker.closeTop(); BotRPTracker.closeBottom();`（:1500-1501，注释：关一端才能调用 getMaxUpward/DownwardPressureDelta）；LiveThru 互传（:1503-1508）；`updatePressureDiffs(LiveOutRegs)`（:1512）。
- **窗口语义（从调度边界看 LPMax）**：TopRPTracker 的窗口 = [RegionBegin, CurrentTop)——已 Top 发射的指令序列，advance 时更新 `MaxSetPressure`；BotRPTracker 窗口 = [CurrentBottom, LiveRegionEnd)，recede 时更新。`RPTracker.getPressure().MaxSetPressure` 是**调度前的静态上界**；`RegionCriticalPSets`（:1531-1543）= 初始 MaxSetPressure 超过 limit 的 PSet 集合（日志 "PSetName Limit L Actual A" :1539-1540 与 "Excess PSets: ..." :1546-1549）。
- **压力预算的三个层次**（tryCandidate 用到的三个 RegPressureDelta 字段，RegisterPressure.h:262-277）：
  - `Excess`：超目标硬限的量（RegExcess 谓词，最高优先级压力项）
  - `CriticalMax`：RegionCriticalPSets 中某 set 的当前最大（RegCritical）
  - `CurrentMax`：全区域当前最大压力（RegMax）
- `updateScheduledPressure` **:1554-1579**：发射后用 tracker 的 MaxSetPressure 增量更新 RegionCriticalPSets 的 UnitInc（:1565-1568），接近 limit-2 时打日志（:1571-1576 " PSetName: N > / <= Limit (+ L livethru)"）。
- `updatePressureDiffs` **:1583-1656**：Bot 方向 recede 后，对刚变 live/dead 的 vreg 的**其他未调度使用者**修 PressureDiff（lane mask 版 :1590-1613 / 简化版 :1614-1654，日志 "  UpdateRegPressure: SU(n) %reg:lanelen ... to ..." :1608-1612）。

### 3.5.2 shouldTrackPressure / handlePressure 两个 hook

**静态**（术语对齐：任务书 "handlePressure" 在当前 main 源码中**不存在**——已 grep 全部四个文件 0 命中。实际存在的是 `shouldTrackPressure` + `shouldTrackLaneMasks` 两个 hook + 上述 update* 系列内部方法）：
- `MachineSchedStrategy::shouldTrackPressure()`（.h:260-262，"Check if pressure tracking is needed **before building the DAG** and initializing this strategy. Called after initPolicy"）——**时机在 DAG 构建前**，决定 buildDAGWithRegPressure 是否带 RPTracker 扫描（:1753-1758）。
- `shouldTrackLaneMasks()`（.h:264-267）：子寄存器 lane 追踪，需与 pressure 联用（assert :1471-1472）。
- GenericScheduler::initPolicy **:3694-3707** 的启用阈值："only track pressure when the number of schedulable instructions exceeds **half the allocatable integer register file**"（`NumRegionInstrs > NIntRegs/2`）——小编译时间护栏。
- 命令行：`misched-regpressure`（默认 true，:252-253）在 subtarget override 之后再强制关闭（:3718-3721）。
- PostGenericScheduler::shouldTrackPressure 直接 false（.h:1373-1374 注释 "PostRA scheduling does not track pressure"）。

**动态日志锚点**（先记，§3.6 验证）：
- 初始：`RPTracker.dump()`（:1491）、"Top Pressure: ..."/"Bottom Pressure: ..."（:1521-1524）——dumpRegSetPressure 格式。
- 每次发射：Top 侧 "Top Pressure: ..."（:1910-1911）/ Bot 侧 "Bottom Pressure: ..."（:1947-1948）。
- 候选评估："  Try  SU(n) PSetName:Inc"（initCandidate :3948-3951，仅 Excess 有效时）。
- 决策："  Cand SU(n) REASON PSetName:Inc ..."（traceCandidate :3410-3413）。
- "Pick Top/Bot Cand SU(n) REASON [pre-RA]"（tracePick :3525-3528）。

**设计动机**：压力感知要回答的问题是"重排会不会把寄存器分配搞炸"。三 tracker 把"静态区域上界"（RPTracker，一次算清）与"动态两端视角"（Top/Bot tracker，增量维护）分开，谓词链只在 initCandidate 时做一次 delta 查询（getUpwardPressureDelta 用 PressureDiff 缓存做 O(uses) 查询而非全量重扫）。Excess/CriticalMax/CurrentMax 三档对应"硬限溢出/临界集增长/最大值增长"三种语义严重度。

**昇腾映射（待验证）**：昇腾 tile 流水线的"缓冲水位"可类比三 tracker：全局规划上界（RPTracker）+ 生产端/消费端各自增量账本（Top/Bot RPTracker）；PressureDiff 缓存 ↔ "每 tile 对缓冲的净贡献"预计算表。

---

## 3.6 动态验证

（已由主会话补齐为文末 §3.6/§3.7/引用清单）

---

## 3.7 昇腾映射：PyPTO tile 流水线"双端调度"vs Top/Bottom

（已并入文末引用清单）

---

## 引用清单

（正文各节行号已核实；汇总版见文末"引用清单（供抽查）"节）

---

## §3.6 动态验证汇总（实测，素材 scratch/tb.ll + tb.log 1,142 行）

命令：`llc -mtriple=aarch64 -O2 -debug-only=machine-scheduler -misched-prera-direction=bidirectional`（Cortex-A510，含 pre-RA+post-RA 两段）。

### Top/Bot 交替序列（bidirectional 模式）
`Bot(12) → Top(0-5, 全 PHYS-REG/ONLY1) → Bot(14 FIRST → 11 → 13 → 10 → 9 ORDER → 8 → 7 → 6)`——`Pick Top/Bot Cand SU(n) REASON [pre-RA]` 行完整，双向确实交替决策。

### 各类日志行实测（骨架机制的日志指纹）
```
Queue BotQ.P: 14 / BotQ.A: 12      ← PendingQ/AvailableQ 水位（ReadyListLimit=256 观察区）
hazard: SU(14) ReadyCycle = 1 is later than CurrCycle = 0 on an unbuffered resource   ← hazard 预过滤
Cycle: 2 TopQ.A                     ← bumpCycle 硬推进
*** Critical resource CortexA510UnitLdSt: 1c    ← 临界资源识别
Top/BotQ.A @Nc Retired: ... - Resource/Latency limited   ← 区域受限状态
Top Pressure: GPR32=6               ← 压力跟踪
UpdateRegPressure: SU(12) ... to GPR32 1
Latency limited both directions
TopQ.A RemainingLatency 10 + 2c > CritPath 11   ← 延迟翻转时刻：Top 以 TOP-PATH 胜出
```
**Final schedule 可见 bottom-up 效果**：SU(13) ADDWrr 被抬到两条 STRWui 之前。

## §3.7 昇腾映射汇总（推理级，待验证）

PyPTO tile 流水线的"双端调度"对应关系（各节已埋映射，汇总）：
1. **生产端 ≈ Top 视角**：延迟主导（getUnscheduledLatency Top 看 height）——MTE 搬运尽早启动
2. **消费端 ≈ Bot 视角**：压力主导（PressureDiffs 仅 bottom-up 维护）——计算等待数据齐
3. **无 InstrEmitter 的启示**：MISched 只重排不重建 MI（moveInstruction 就地 splice）——**保 LiveIntervals 的前提**；PyPTO tile 调度若走同样"只重排"路线，寄存器/UB 活跃信息无需重建
4. **双层过滤**（hazard 机制层预过滤 + 谓词链策略层排序）：tile 的 MTE 互斥可放机制层，性能偏好放策略层
5. **延迟翻转机制**（RemainingLatency + CurrCycle > CritPath 切换 ReduceLatency）：tile 流水线的"搬运远、计算近"自动权衡可仿

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| MachineScheduler.cpp:76, 1024, 1057, 1691, 2818-2863, 2931, 3177, 3711 | 驱动/水位/推进/OnlyBottomUp |
| MachineScheduler.h:441-443, 1005 | PressureDiffs/unscheduledLatency |
| 实测：scratch/tb.log（1,142 行） | 交替序列/日志指纹/延迟翻转 |
