# §2 调度 DAG 构建（ScheduleDAGInstrs）深度分析

> 分析基线：LLVM main @ 3eda2aebadd4，AArch64 host。
> 文件缩写：`SDI.cpp` = llvm/lib/CodeGen/ScheduleDAGInstrs.cpp（1,446 行）；`SDI.h` = llvm/include/llvm/CodeGen/ScheduleDAGInstrs.h（413 行）；`SD.cpp` = llvm/lib/CodeGen/ScheduleDAG.cpp（764 行）；`SD.h` = llvm/include/llvm/CodeGen/ScheduleDAG.h（829 行）；`MS.cpp` = llvm/lib/CodeGen/MachineScheduler.cpp（5,037 行）；`MS.h` = llvm/include/llvm/CodeGen/MachineScheduler.h（1,482 行）。
> 所有 `文件:行号` 均经过实际 grep/read 核对。

---

## 2.1 Region 划分

### 2.1.1 静态分析

**ScheduleDAGInstrs 构造与 Region 状态**（SDI.h:110-148；SDI.cpp:110-121）
- 构造函数 `ScheduleDAGInstrs(MachineFunction &mf, const MachineLoopInfo *mli, bool RemoveKillFlags)`（SDI.h:259-261），基类 `ScheduleDAG(mf)`（SD.cpp:56-61）。构造时 `Topo(SUnits, &ExitSU)`（SDI.cpp:116）把拓扑排序器绑定到 ExitSU。
- Region 状态四元组：`BB / RegionBegin / RegionEnd / NumRegionInstrs`（SDI.h:139-148），其中 `RegionEnd` 是 **半开区间端点**（指向 boundary 指令本身，不属于 DAG 节点，见 MS.cpp:829-833 注释："The DAG does not include RegionEnd, but the region does"）。

**startBlock/endBlock 控制**（SDI.cpp:173-180）
- `startBlock(bb)` 仅 `BB = bb`；`finishBlock()` 仅 `BB = nullptr`（提示子类不要再引用旧块）。真正的 region 装载在 `enterRegion()`（SDI.cpp:182-190）：断言 `bb == BB`（startBlock 先行），然后设置三个迭代器字段。`exitRegion()` 空实现（SDI.cpp:192-194）。
- 关键设计：**enterRegion 只清状态不建图**。SDI.h:308-311 注释明说 "This does not actually create the DAG, only clears it. The scheduling driver may call BuildSchedGraph multiple times per scheduling region."——建图时机推迟到 `schedule()` 内（如 ScheduleDAGMILive::schedule() 调 buildDAGWithRegPressure，MS.cpp:1694）。

**Region 粒度：MBB 内的指令区间，不跨 MBB**
- 协议方（driver）：`MachineSchedulerBase::scheduleRegions(ScheduleDAGInstrs &Scheduler, bool FixKillFlags)`（MS.cpp:811-898）遍历所有 MBB（MS.cpp:817），对每个块调 `Scheduler.startBlock()`（MS.cpp:827）→ `getSchedRegions(&*MBB, MBBRegions, ...)`（MS.cpp:844）→ 逐 region 调 `Scheduler.enterRegion(&*MBB, I, RegionEnd, NumRegionInstrs)`（MS.cpp:853）→ `Scheduler.schedule()`（MS.cpp:885）→ `exitRegion()`（MS.cpp:888）→ 块末 `finishBlock()`（MS.cpp:890）。
- `getSchedRegions`（MS.cpp:768-808）：**自底向上**扫描 MBB，用 `isSchedBoundary` 切分。一个 MBB 可产出多个 region（`MBBRegionsVector = SmallVector<SchedRegion, 16>`，MS.cpp:766）；`SchedRegion{RegionBegin, RegionEnd, NumRegionInstrs}` 定义于 MS.h:226-238。若 `doMBBSchedRegionsTopDown()` 为真则 reverse 后自顶向下处理（MS.cpp:806-807）。
- **boundary 判定**（MS.cpp:758-764）：`MI->isCall() || TII->isSchedulingBoundary(*MI, MBB, *MF) || MI->isFakeUse()`。`TargetInstrInfo::isSchedulingBoundary`（TargetInstrInfo.cpp:1700-1722，声明 TargetInstrInfo.h:1810）：terminator/label（isPosition）、INLINEASM_BR、以及修改 SP 的指令（`modifiesRegister(TLI.getStackPointerRegisterToSaveRestore())`）。**terminator 永远是边界**——所以 region 不可能含 terminator（除非 `CanHandleTerminators`，SDI.h:126-130 说明需要子类自行负责正确性，构建时有断言 SDI.cpp:806-808）。
- 数量口径：`NumRegionInstrs` 只计非 debug/pseudo 指令，**bundle 计 1 条**（MS.cpp:793-797 注释 "we need a bundle to count as a single instruction"）。

**MachineScheduler 侧的 Region 参数与 scheduleRegions 协议**
- 驱动入口：pre-RA `MachineSchedulerLegacy::runOnMachineFunction` → `createMachineScheduler()` → `scheduleRegions(*Scheduler, false)`（MS.cpp:563）；post-RA `PostMachineSchedulerImpl::run` → `createPostMachineScheduler()` → `scheduleRegions(*Scheduler, true)`（MS.cpp:608）。`FixKillFlags` 仅 post-RA 为真（MS.cpp:890-895，因 thumb2 size reduction 仍依赖 kill flags）。
- `doMBBSchedRegionsTopDown()` 虚函数链：SDI.h:300（默认 false）→ MS.h:272（ScheduleDAGMI 转发给 SchedImpl）→ MS.h:346-347。目前唯一覆写为 SystemZ（SystemZMachineScheduler.h:167 返回 true）。
- **跨 MBB 情形**：region 严格以 MBB 为界，不跨块。MS.cpp:838-841 警告 region 处理中插入指令会使迭代器失效，且"Instructions must not be added to other regions than the current one"。跨块调度需求由其他机制处理（如 ScheduleDAGMutation 在 DAG 层面加边，或 MachineLICM 等前置 pass），不在本 DAG 构建协议内。

### 2.1.2 动态验证
（见 §2.6.1：`-debug-only=misched` 的 "Current Schedule Region" 头，可观察到 region 边界/数量与 getSchedRegions 逻辑一致。）

### 2.1.3 设计动机
- **编译时间可控**：MBB 内再按 call/SP 修改等硬边界切分，把 DAG 尺寸压到可接受范围（Defs/Uses map 与内存别名 map 的查询都是接近线性/平方的，见 HugeRegion=500 的软限制，SDI.cpp:86-90）。
- **正确性兜底**：terminator、SP 修改、INLINEASM_BR 这些"动了就出错"的指令被天然排除在重排之外；region 间的相对顺序由 region 切分本身保证。
- **协议解耦**：`enterRegion`/`exitRegion`/`schedule()` 的虚函数三件套允许 AMDGPU 等后端在 region 级别重打 DAG（GCNSchedStrategy.cpp:1836 直接 `DAG.enterRegion(...)` 触发重调度）而不改 driver。

### 2.1.4 昇腾映射（推理级，待验证）
- PyPTO tile 级依赖图同样是"region 内闭包"：一个 tile group（MTE 搬运→计算→回写）应映射为一个 region，region 边界 = 同步指令（barrier/sync all）或 tile 边界。若 MTE 搬运作为独立"指令"进入 DAG，则 barrier 天然成为 region 边界（对应 isSchedBoundary 的 terminator 角色），**避免跨 tile 边界重排**。待验证：昇腾侧 tile IR 是否有等价的 boundary 指令语义。
- getSchedRegions 的"自底向上扫描"方向与 PyPTO 的 bottom-up 生成顺序可能相反，需确认对 region 切分无影响。

---

## 2.2 buildSchedGraph 依赖边分类

### 2.2.1 静态分析

**边分类总表**（SD.h:52-78 SDep 定义）
- `SDep::Kind`：`Data`（真依赖 RAW）、`Anti`（WAR）、`Output`（WAW）、`Order`（其余一切次序依赖）（SD.h:55-60）。
- `SDep::OrderKind`（Order 的子类，SD.h:71-78）：`Barrier`（未知调度屏障）、`MayAliasMem` / `MustAliasMem`（非 volatile load/store 可能/必然别名）、`Artificial`（强边但非真实依赖）、`Weak`（弱边，可被违反）、`Cluster`（聚簇弱边）。强弱分界注释：SD.h:62-70 "Strong OrderKinds must occur before Weak"。
- 判定谓词：`isNormalMemory()` = MayAliasMem|MustAliasMem（SD.h:169-172）、`isBarrier()`（SD.h:175-177）、`isWeak()`（SD.h:195-197）、`isArtificial()`（SD.h:201-203）。
- 边的去重合并：`SUnit::addPred`（SD.cpp:96 起，实现在 SD.cpp:96-176 区域）对 `overlaps()`（同 SU + 同 Reg/OrdKind，SD.h:495-507）的旧边只扩 latency 不加重复边。
- **注意**：MI 调度的"内存边"实际是 `SDep::Order + MayAliasMem`（addChainDependency，SDI.cpp:556-563），并非独立 Kind。"chain" 是 SDAG 侧的名字（MVT::Other，见 §2.5）；MI 侧内存边在 dump 里显示为 "Ord  Memory"（SD.cpp:SDep::dump，位于文件头部区）。

**buildSchedGraph 主流程**（SDI.cpp:706-986）——判定顺序（对每条 MI，自底向上遍历）：
1. `initSUnits()`（SDI.cpp:577-621）为 region 内每条非 debug/pseudo MI 建 SUnit（一对一），NodeNum 按原始指令序递增（"MachineScheduler relies on initSUnits numbering the nodes by their order in the original instruction list"，SDI.cpp:575-576）。
2. `addSchedBarrierDeps()`（SDI.cpp:767 调用；实现 SDI.cpp:196-239）：为 ExitSU 预登记 region 出口的寄存器使用（见下）。
3. 逐条 MI（自底向上，SDI.cpp:771-975）：
   a. **寄存器依赖先行**：两遍操作数扫描——先 defs 后 uses（SDI.cpp:810-843，注释 "make sure that defs are processed before any uses"，因 call 等指令显式 use 在前隐式 def 在后）。物理寄存器走 `addPhysRegDeps`，虚寄存器走 `addVRegDefDeps`/`addVRegUseDeps`。
   b. **ExitSU 人工边**（SDI.cpp:845-855）：若 `SU->NumSuccs == 0 && SU->Latency > 1 && (HasVRegDef || MI.mayLoad())` 则加 `Artificial` 边到 ExitSU，latency = SU->Latency - 1——建模 live-out 延迟（vreg def 在 region 内无 use、或 prefetch 场景），防止长延迟 def 被压到最后。
   c. **屏障链**：`TII->isGlobalMemoryObject(&MI)`（SDI.cpp:863；定义 TargetInstrInfo.cpp:2232-2235：`isCall() || hasUnmodeledSideEffects() || (hasOrderedMemoryRef() && !isDereferenceableInvariantLoad())`）→ 该 SU 成为新 `BarrierChain`（SDI.cpp:866-878），对 Stores/Loads/FPExceptions 三张 map 里所有已有 SU 加 Barrier 边并清空 map。`hasOrderedMemoryRef`（MachineInstr.cpp:1615-1632）覆盖 volatile/atomic（`!MMO->isUnordered()`）。
   d. **FP 异常**（SDI.cpp:883-896）：`mayRaiseFPException()` 的指令不得跨全局屏障移动，但不与普通 load/store 互连。
   e. **内存依赖**（SDI.cpp:898-974）：非 store 且非"可变 load"则跳过（SDI.cpp:899-901：`!MI.mayStore() && !(MI.mayLoad() && !MI.isDereferenceableInvariantLoad())`）。已有 BarrierChain 时先加 Barrier 边（SDI.cpp:905-907）。`MemOpsProcessed >= HugeRegion(500)` 时强制本 SU 成为 barrier 并清 map（SDI.cpp:910-920，编译时间换精度）。然后 `getUnderlyingObjectsForInstr`（SDI.cpp:127-171）收集底层对象（volatile/atomic MMO 被跳过并返回 not-identified，SDI.cpp:135-138）：
      - **未知对象 store**：依赖此前**所有** store+load（`addChainDependencies(SU, Stores)` + `(SU, Loads)`），并映射到 UnknownValue（SDI.cpp:930-936）。
      - **已知对象 store**：对每个对象 V 精确依赖同 V 的 store/load（SDI.cpp:940-944），另对 UnknownValue 的 load/store 补边（SDI.cpp:952-953）。
      - **未知对象 load**：依赖所有 store（SDI.cpp:956-961）。
      - **已知对象 load**：只依赖同 V 的 store（SDI.cpp:963-972）——**load-load 无依赖**。
      - 边的实际生成经 `addChainDependency`（SDI.cpp:556-563）：`if (SUa->getInstr()->mayAlias(getAAForDep(), *SUb->getInstr(), UseTBAA))` 才加 `SDep(SUa, SDep::MayAliasMem)`。mayAlias 实现（MachineInstr.cpp:1558-1610）：call 保守 true；双方都不 store 则 false；target `areMemAccessesTriviallyDisjoint` 优先；MMO 对两两检查（`MemOperandsHaveAlias`）。
   - **latency 规则**：内存 chain 边 latency=0，唯 store→load 用 `TrueMemOrderLatency=1`（Loads map 构造参数，SDI.cpp:739；Value2SUsMap::TrueMemOrderLatency，SDI.cpp:629-632、672-674）。Barrier 边同样 store→load 为 1（addPredBarrier，SD.h:412-418）。

**优先级/顺序总结**：寄存器边（Data/Anti/Output）→ ExitSU Artificial → BarrierChain → FP 异常 → 内存边。同一对 SU 间多类边会被 addPred 的 overlaps 逻辑合并（同 Kind 才合并；Data/Anti/Output 间不合并，可并存）。

**Anti（WAR）/Output（WAW）判定**
- 物理寄存器：`addPhysRegDeps`（SDI.cpp:299-380）。use 侧：对 Defs map 中每个旧 def 加 `SDep::Anti`（latency 0，SDI.cpp:309-336，"we use a latency of 0 because for a multi-issue target we want to allow the defining instruction to issue in the same cycle"）；def 侧对旧 def 加 `SDep::Output`（`computeOutputLatency`，SDI.cpp:326-330）；`isDead()` 的双边可豁免（SDI.cpp:324-325）。def 处理完还会清空该 regunit 的旧 Uses/Defs（SDI.cpp:350-355）——**自底向上遍历时"旧"= 程序序在后**，故 Anti 边方向是 use→def（后写者依赖先写者），即程序序反方向。

> 术语对照（避免混淆）：本文件把任务书中的 "chain（内存/volatile/原子）" 对应到 MI 调度的 `Order/MayAliasMem`（内存）与 `Order/Barrier`（volatile/原子/调用——经 isGlobalMemoryObject→addPredBarrier）。任务书的 "order（屏障/barrier）" 对应 `Order/Barrier`。

**ExitSU/EntrySU 边界节点**（SD.h:592-593；SDI.cpp 构造 116）
- `EntrySU`/`ExitSU` 是 `ScheduleDAG` 的直接成员（SD.h:592-593），`NodeNum == BoundaryID(~0u)`（SD.h:252、368，isBoundaryNode 断言提醒任何按 NodeNum 索引的数据结构都要先排掉边界节点）。
- **给 ExitSU 加边的全部条件**（自底向上构建中，"加边"= 让 ExitSU 成为 succ，即 ExitSU->addPred(来自某 SU 的 Dep)）：
  1. addSchedBarrierDeps：ExitMI 的 physreg use / vreg use（SDI.cpp:203-224）或（无 ExitMI 或非 call/barrier 时）后继块 livein 的所有 regunit（SDI.cpp:226-238）——这些先登记进 Uses map，随后上方 def 在 addPhysRegDataDeps（SDI.cpp:243-294）中发现这些 use 并加 Data 边。
  2. 2.a 中 `NumSuccs==0 && Latency>1 && (HasVRegDef||mayLoad)` 的 Artificial 边（SDI.cpp:851-855）。
  3. 内存边：ExitSU 不是 MI，不参与 Stores/Loads map，**不加内存边**；但 addSchedBarrierDeps 若 ExitMI 有 memoperands（如 region 结尾恰是 volatile load 作为下一条 boundary）……实际上 ExitMI 是 RegionEnd 指向的 boundary 指令（SDI.cpp:197-201），仅取其寄存器 use，不取内存——内存依赖由 region 切分保证（boundary 不被重排）。
- **EntrySU**：MI 调度构建期**不加任何边**（SDI.cpp 中无 EntrySU 加边代码；grep 确认 MS.cpp:978/1159/1173 只在调度阶段把 EntrySU 当哨兵用：`releaseSuccessors(&EntrySU)`）。EntrySU 恒为根。
- `SUnit::addPredBarrier`（SD.h:412-418）：`SDep(SU, SDep::Barrier)`，latency = (SU store && this load) ? 1 : 0。

### 2.2.2 动态验证
（见 §2.6.2：load/store/volatile 的边类型 dump。）

### 2.2.3 设计动机
- **边分类即语义分层**：Data/Anti/Output 是寄存器级真/假依赖，Order 是"次序类"依赖。强 Order（Barrier/Mem/Artificial）必须遵守，弱 Order（Weak/Cluster）仅启发式。这种分层让 GenericScheduler 能对假依赖做特殊处理（如 removePred 后插入 copy）。
- **内存建模的三档精度**：对象已知（精确 map 查询）> 对象未知但 MMO 完整（UnknownValue 桶）> isGlobalMemoryObject（全序 Barrier）。编译时间由 HugeRegion=500 兜底（超过则降级为 barrier 链，SDI.cpp:910-920）。
- **volatile/原子走 Barrier 而非 MayAliasMem**：因为 getUnderlyingObjectsForInstr 跳过 volatile/atomic MMO（SDI.cpp:135-138），它们落入 isGlobalMemoryObject 的 hasOrderedMemoryRef 分支，成为 BarrierChain——**全序而非成对约束**，这是保守但正确的选择（单条 volatile 与其他内存访问的相对序必须保持）。
- **load-load 无边**：纯读之间无依赖是调度自由度的最大来源之一，也是 load clustering 等 mutation 的作用空间。
- **Anti latency=0**：允许 def 与 use 同 cycle 发射（多发射目标），只约束程序序。

### 2.2.4 昇腾映射（推理级，待验证）
PyPTO tile 依赖图（MTE 搬运→计算→搬运）的边分类对应（推理）：
- **data**：tile 生产者→消费者的寄存器/UB 传递（如 MTE load 写 UB → Vector 计算读 UB），对应 `Data` 边，latency 来自搬运/计算流水延迟。
- **chain（内存类）**：两条 MTE 搬运若目标 GM 地址可能重叠（或 tag 冲突），对应 `MayAliasMem`；out-of-order MTE 引擎的重排自由度来自"不同地址搬运会真正并发"。
- **order/barrier**：昇腾侧 `sync`/`barrier`（如 MTE 与 Vector 间的双事件同步）对应 `Barrier` 边——不建模具体地址、只保序。PyPTO 生成端常用双事件依赖（event wait/set），若在 DAG 中表达为 SU 间 Order/Barrier，与 LLVM 的 barrier chain 同构。
- **待验证**：PyPTO tile 图是否显式区分假依赖（Anti/Output）；昇腾硬约束（如 vector 内 element 依赖、MTE 参数描述符的串行更新）是否需要 Anti 类边。

---

## 3 素材衔接说明（PhysReg 追踪与压力联动）

（详细展开见 §2.3/§2.4；本节先给索引。）

- **物理寄存器追踪**：`RegUnit2SUnitsMap Defs/Uses`（SDI.h:163-164，SparseMultiSet，universe=TRI->getNumRegs()，SDI.cpp:756-757）。regunit 粒度（MCRegUnit，如 X86 的 low8/high8）而非整寄存器，处理部分重定义。
- **压力联动**：`buildSchedGraph(AA, RPTracker, PDiffs, LIS, TrackLaneMasks)`（SDI.h:324-328，SDI.cpp:706-710）。RPTracker 非空时在访问每条 MI 的同时 `RegOpers.collect` + `RPTracker->recede(RegOpers)`（SDI.cpp:790-804）——**DAG 构建器顺带算压力**，SDI.h:321-323 注释明说 "The DAG builder is an efficient place to do it because it already visits operands"。`PressureDiffs::addInstruction(SU->NodeNum, RegOpers, MRI)`（SDI.cpp:797-798；RegisterPressure.h:219-245）把每 SU 的压力增量记到 NodeNum 索引的数组。
- **接口**：ScheduleDAGInstrs **本身没有** `getPressure` 类接口；压力查询接口在 `ScheduleDAGMILive`（MS.h:495-499 `getPressureDiff(const SUnit*)`、MS.h:484-487 `getTopRPTracker()/getBotRPTracker()`、MS.h:492 `getRegPressure()`）。三 tracker 架构（RPTracker 全区域 + Top/Bot 两半区）由 `buildDAGWithRegPressure`（MS.cpp:1752-1779）和 `initRegPressure`（MS.cpp:1477-1560）建立。
- **AMDGPU 关系**：AMDGPU 不用通用 RegPressureTracker 的 PSet 数值做决策，而是 `GCNRegPressure`（VGPR/SGPR/AGPR 分域计压，详见 AMDGPU-notes/06 §8.4）。挂钩点：`GCNScheduleDAGMILive : ScheduleDAGMILive`（GCNSchedStrategy.h:272）复用 ScheduleDAGMILive 的 DAG 构建与 enterRegion 协议（GCNSchedStrategy.cpp:1836 直接调 `DAG.enterRegion`），但用 `GCNRPTracker::LiveRegSet`（GCNRegPressure.h:319-371）自管压力；`SIScheduleDAGMI`（SIMachineScheduler.h:422）暴露 `getEntrySU()/getExitSU()` 供 SIScheduler 变体调度使用。**分工**：DAG 本体（SUnit/边/region 协议）共用，压力模型与调度策略 target 化。

---

## 2.3 PhysReg 追踪与压力联动

### 2.3.1 静态分析

**物理寄存器使用的追踪数据结构**
- `RegUnit2SUnitsMap Defs/Uses`（SDI.h:163-164）：`SparseMultiSet<PhysRegSUOper, MCRegUnit, MCRegUnitToIndex, uint16_t>`（SDI.h:93-94）。`PhysRegSUOper{SUnit *SU; int OpIdx; MCRegUnit RegUnit}`（SDI.h:77-88），OpIdx=-1 表示非数据依赖 use（fake operand / liveout）。universe 设为 `TRI->getNumRegs()`（SDI.cpp:756-757），构建结束 clear（SDI.cpp:980-981）。
- **regunit 粒度而非整寄存器**：`TRI->regunits(Reg)` 遍历（SDI.cpp:219、256、316、343 等），正确处理 X86 AX/AL/AH 这类重叠子寄存器：只有共享 regunit 才产生依赖。
- 常量寄存器豁免：`MRI.isConstantPhysReg(Reg)` 直接 return（SDI.cpp:303-305）。
- call 的 Defs 防爆炸：dead def 的 regunit 若 DefList 尾部全是 call，则只留一个（SDI.cpp:357-374，避免 quadratic）。

**vreg 追踪**：`CurrentVRegDefs`（VReg2SUnitMultiMap）/`CurrentVRegUses`（VReg2SUnitOperIdxMultiMap）（SDI.h:169-171，SDI.cpp:759-763），支持 lane mask 细分（`TrackLaneMasks`，SDI.cpp:416-440）——子寄存器只写部分 lane 时不误加跨 lane 依赖。

**RegPressure 在 DAG 构建时如何预估**
- `buildSchedGraph(AA, RPTracker, PDiffs, LIS, TrackLaneMasks)`（SDI.h:320-328；SDI.cpp:706-710）。RPTracker/PDiffs 均可选；非空时在遍历每条 MI 时顺带做（SDI.cpp:790-804）：
  1. `RegOpers.collect(MI, *TRI, MRI, TrackLaneMasks, false)` 收集该指令读写集；
  2. `PDiffs->addInstruction(SU->NodeNum, RegOpers, MRI)`（RegisterPressure.h:243-245）记录该 SU 的压力增量（PressureDiffs 按 NodeNum 索引，`PDiffs->init(SUnits.size())` 在 SDI.cpp:727-728）；
  3. `RPTracker->recede(RegOpers)`（自底向上 recede 与 DAG 遍历同向！这是把压力计算缝进 DAG 构建的关键——遍历方向天然一致）。
- 设计动机（SDI.h:321-323 原文）："The DAG builder is an efficient place to do it because it already visits operands."
- **接口归属**：ScheduleDAGInstrs 无 getPressure；查询接口全在 `ScheduleDAGMILive`：`getPressureDiff(const SUnit*)`（MS.h:495-499，直接 `SUPressureDiffs[SU->NodeNum]`）、`getTopRPTracker()/getBotRPTracker()`（MS.h:482-487）、`getRegPressure()`（MS.h:492）。
- **三 tracker 架构**（MS.h:447-463 + MS.cpp:1752-1779 buildDAGWithRegPressure）：`RPTracker`（整个 region，init 于 LiveRegionEnd 向上 recede）→ `initRegPressure()`（MS.cpp:1477-1560）从 RPTracker 的 LiveIn/LiveOut 派生 `TopRPTracker`/`BotRPTracker`（分别 init 于 RegionBegin/LiveRegionEnd），并算 `RegionCriticalPSets`（超过 limit 的 PSet 集合，MS.cpp:1535-1545）。调度期间 `scheduleMI` 用 `getPressureDiff` 增量更新。

**与 AMDGPU GCNRegPressure 的关系**
- 通用路径的计压单位是 PSet（RegPressureSet），AMDGPU 认为不精确（PSet 数值是加权分数），自建 `GCNRegPressure`（VGPR/SGPR/AGPR 分域整数计数）+ `GCNRPTracker/GCNUpwardRPTracker`（GCNRegPressure.h:319-371）。
- 但 AMDGPU 仍走 ScheduleDAGMILive 的 DAG 构建：`GCNScheduleDAGMILive`（GCNSchedStrategy.h:272）继承 ScheduleDAGMILive，`buildDAGWithRegPressure`（MS.cpp:1752）里 ShouldTrackPressure 由 SchedImpl 决定——GCN 侧用 GCNSchedStrategy 系（GCNSchedStrategy.h:187 GCNMaxOccupancySchedStrategy）。register live-in/out 用 `RegionPressureMap`（GCNSchedStrategy.h:242-269）基于 GCNRPTracker::LiveRegSet 自管（见 AMDGPU-notes/06 §8.4，不展开）。
- **关系总结**：DAG 结构（SUnit/SDep/region）100% 共用；压力数值计算 target 通用层给 PSet 近似、AMDGPU 替换为分域模型；增量更新接口（PressureDiffs::addInstruction）是通用层的，AMDGPU 在调度决策点用自己的 tracker 重算（GCNSchedStrategy.cpp:267 GCNRegPressure NewPressure 局部重算模式）。

### 2.3.2 动态验证
（§2.6.1 dump 中 `GenericScheduler RegionPolicy: ShouldTrackPressure=0`——AArch64 默认策略不追踪压力；压测可见于开 `-misched-postra` 或 AMDGPU 目标。此处未单独跑，标注为可选。）

### 2.3.3 设计动机
- **一次遍历两用**：DAG 构建本就要逐操作数扫描（找寄存器依赖），压力计算恰好需要同样的读写集——合并遍历省一半编译时间。
- **增量而非全量**：PressureDiffs 只存每个 SU 的 delta，调度时 O(1) 查询当前压力变化，避免每步重扫。
- **regunit 而非寄存器**：重叠子寄存器（X86）必须建模到 regunit 级才能既不漏依赖也不过度保守。

### 2.3.4 昇腾映射（推理级，待验证）
- 昇腾寄存器分组（UB/Vector 寄存器文件）压力可比照 PressureDiffs 增量模型：PyPTO tile 调度若要做 UB 容量感知（tile 太多爆 UB），应在依赖图构建时顺带收集每个 tile 的 UB 需求增量（对应 RegOpers.collect），调度决策点查 delta。GCNRegPressure 的"分域计压"思路直接适用：UB/寄存器/NZCC 多个域分别计数。待验证：PyPTO 是否已有等价物。

---

## 2.4 SUnit 结构

### 2.4.1 静态分析

**SUnit 与 MachineInstr 的关系：region 内非 debug 指令 1:1，bundle 计 1**
- `initSUnits()`（SDI.cpp:577-621）：遍历 `[RegionBegin, RegionEnd)`，跳过 `isDebugOrPseudoInstr()`，每条 `newSUnit(&MI)`。`newSUnit`（SDI.h:396-404）`SUnits.emplace_back(MI, SUnits.size())`——NodeNum = 指令序号。
- **bundle**：MBB::iterator 是 `MachineInstrBundleIterator`（MachineBasicBlock.h:341），operator++ 跳过 bundle 内部指令（MachineInstrBundleIterator.h:98-99 注释 "walk top level MIs only"）——**bundle 头（或捆绑指令）作为整体只得到一个 SUnit**。getNumRegionInstrs 同样 bundle 计 1（MS.cpp:793-797）。例外：`MI.isPseudoProbe()` 在 initSUnits 跳过但 buildSchedGraph 主循环也跳过（SDI.cpp:584/784-785）。
- debug 指令（DBG_VALUE/DBG_PHI）不建 SU，记入 DbgValues 待调度后重插（SDI.cpp:779-781、247-253）。
- 双向映射：`DenseMap<MachineInstr*, SUnit*> MISUnitMap`（SDI.h:152，SDI.cpp:587）+ `SU->getInstr()`（union Node/Instr，SD.h:254-257、398-404，isNode/isInst tag bit 区分）。

**SUnit 字段全景**（SD.h:250-492）
- 拓扑：`Preds/Succs`（SmallVector<SDep,4>，SD.h:270-271）；计数器 `NumPreds/NumSuccs`（**只数 Data 边**，SD.h:280-281）、`NumPredsLeft/NumSuccsLeft`（调度推进计数，非 weak）、`WeakPredsLeft/WeakSuccsLeft`（SD.h:282-285）。
- 时序：`Latency`（initSUnits 里 `SchedModel.computeInstrLatency`，SDI.cpp:593）、`TopReadyCycle/BotReadyCycle`（SD.h:286-287）。
- 标志位族（SD.h:296-311）：isCall/isCommutable/hasPhysRegUses/hasPhysRegDefs/isUnbuffered/hasReservedResource 等，多数由 initSUnits/依赖分析填充（isCall/isCommutable 在 SDI.cpp:589-590；hasReservedResource/isUnbuffered 由 BufferSize 0/1 判定，SDI.cpp:595-619）。
- 边界节点：`NodeNum == BoundaryID(~0u)`，`isBoundaryNode()`（SD.h:252、361-368）。

**SDep 边结构**（SD.h:52-238，详见 §2.2）：PointerIntPair<SUnit*,2,Kind> + Contents union（Reg 或 OrdKind）+ Latency。**SDep 是"半边"**：addPred 同时维护两端的 Preds/Succs 向量（SD.cpp:96-176 addPred 实现，removePred SD.cpp:178-216），NumPreds/NumSuccs 记账只对 Data kind。

**Depth/Height 的"预计算"——惰性 + 脏标记**
- `Depth`/`Height` 私有（SD.h:292-293），`getDepth()/getHeight()`（SD.h:426-438）在 `!isDepthCurrent` 时才触发 `ComputeDepth()/ComputeHeight()`（SD.cpp:264-310：迭代后序 DFS，Depth = max(PredSU->Depth + PredDep.Latency)，Height 对偶）。
- 脏传播：`addPred/removePred` 尾部 `this->setDepthDirty(); N->setHeightDirty()`（SD.cpp:175-176、214-215）；`setDepthDirty`（SD.cpp:218-230）沿 Succs 向下传染，setHeightDirty 沿 Preds 向上传染。**即构建完 DAG 后首个 getDepth() 触发一次 O(V+E) 计算，此后边变动只局部失效**。
- 使用点：调度器 pickNode 时用 Height/Depth 做关键路径优先；`biasCriticalPath()`（SD.h:481-483）把关键路径前驱排到 Preds 首位加速释放。
- MI dump 里的 Depth/Height 字段（§2.6 实证：SU(9) Depth=10/Height=0 即临界路径终点）来自 findRootsAndBiasEdges → initQueues 前的 getDepth/getHeight 链。

### 2.4.2 动态验证
（§2.6.1 已含：dump 每个 SU 带 `# preds left / # succs left / # rdefs left / Latency / Depth / Height`，可见 Data-only 计数与惰性 Depth/Height 输出。）

### 2.4.3 设计动机
- **1:1 映射的简单性**：MI 调度不做 SDAG 那种 glued-node 合并（除 bundle 外），SUnit 的 OrigNode/isCloned 主要为 SDAG 调度保留（SD.h:260-261 注释 "(SD scheduling only)"）。bundle 是 VLIW 语义的天然单位。
- **惰性 Depth/Height**：DAG 会被 mutation（load clustering 等）反复改边，全量重算代价高；脏标记把代价摊还到实际查询。
- **NumPreds 只数 Data**：调度 ready 判定（isTopReady = NumPredsLeft==0，SD.h:474-476）需要"真依赖"全部就绪；Order 边不影响就绪计数？——注意实际实现中所有非 weak 边都减 NumPredsLeft（addPred 的记账分支 SD.cpp:144-170），NumPreds 字段本身只对 Data 自增，但 NumPredsLeft 对所有非 weak 边自增。这个不对称是刻意的：计数器语义是"未调度的强前驱数"。

### 2.4.4 昇腾映射（推理级，待验证）
- PyPTO 的 tile 节点 ≈ SUnit：一个 tile（一段 MTE 描述符序列或一组 Vector 指令）作为原子调度单位，对应"bundle 计 1"的粒度选择——昇腾 VEC 指令序列若绑定同一 tile id，应整体 1 个 SU。
- Depth/Height 惰性计算对应 tile 图的关键路径（MTE 延迟 vs 计算延迟的 max 路径），PyPTO 做双缓冲/多缓冲重叠决策时等价于 Height 引导的 bottom-up 调度。待验证：PyPTO 图是否静态算好关键路径。

---

## 2.5 与 SDAG 调度的共用（ScheduleDAG.cpp 的角色）

### 2.5.1 静态分析

**764 行的 ScheduleDAG.cpp 是什么**：MI 调度（SelectionDAG→MI 之前）与 SDAG ISel 源级调度（SelectionDAGISel 内）的**公共基类实现**。
- `ScheduleDAG`（SD.h:584-653）抽象基类：持有 `TM/TII/TRI/MF/MRI/SUnits/EntrySU/ExitSU`（SD.h:586-593），虚接口 dump/dumpNode/getGraphNodeLabel/getDAGName（SD.h:628-636）。
- SD.cpp 实现的共享机制：`SUnit::addPred/removePred`（边记账与合并去重）、`setDepth/HeightDirty` + `ComputeDepth/ComputeHeight`（SD.cpp:218-310）、`biasCriticalPath`、`SchedulingPriorityQueue` 基类（SD.h:526-582，ReadyQueue 的抽象）、`ScheduleDAG::clearDAG`（SD.cpp:64-68，每 region 重建时 EntrySU/ExitSU 重置为空 SUnit）。
- `DEBUG_TYPE "pre-RA-sched"`（SD.cpp:38）是历史名字——该编译单元同时服务 SDAG 源级调度（ScheduleDAGSDNodes 等用户），`-debug-only=pre-RA-sched` 在 SDAG 调度路径（llc -pre-RA-sched）输出。

**两个子树**（继承关系实测 grep）：
- `ScheduleDAGInstrs : ScheduleDAG`（SDI.h:110）→ ScheduleDAGMI → ScheduleDAGMILive（MS.h:412/427）→ target 子类（GCNScheduleDAGMILive 等）。
- `ScheduleDAGSDNodes : ScheduleDAG`（lib/CodeGen/SelectionDAG/ScheduleDAGSDNodes.h:46，头文件私有于 SelectionDAG 目录）→ ScheduleDAGFast / ScheduleDAGRRList（ScheduleDAGFast.cpp:64 等）。SDAG 侧 BuildSchedGraph（ScheduleDAGSDNodes.cpp:536）从 SelectionDAG 的 SDNode 建 SUnit：**passive node（Constant/Register 等）不分 SUnit，Glue 捆绑节点合一个 SUnit**（ScheduleDAGSDNodes.h:42-45 注释）。边来自 SDNode 操作数：`isChain = OpVT == MVT::Other` 时造 `SDep(OpSU, SDep::Barrier)`（**SDAG 的 chain 边 = MI 调度的 Barrier Order 边**，ScheduleDAGSDNodes.cpp:516-518 附近实测），否则 Data 边 + computeOperandLatency。
- **共用什么**：SUnit/SDep 数据结构、addPred/removePred 记账、Depth/Height 惰性计算、SchedulingPriorityQueue/ReadyQueue 骨架、EntrySU/ExitSU 边界节点概念。**不共用**：DAG 构建（buildSchedGraph vs BuildSchedGraph 是两套）、region 协议（SDAG 无 region 概念，按 SelectionDAG 全图调度）、寄存器压力（SDAG 侧无 RPTracker）。
- TaskDAG 之外：SelectionDAGISel 的调度器（默认 ScheduleDAGRRList / ScheduleDAGFast，指令选择时发射顺序）与 MIScheduler（MachineScheduler pass，MI 层重排）是**先后两个阶段**，都消费 SUnit 抽象但图来源不同。

### 2.5.2 动态验证
（共用抽象的直接证据：SD.cpp:96-176 的 SUnit::addPred 同时被 SDI.cpp 与 ScheduleDAGSDNodes.cpp 调用（链接层面同一符号）；`-debug-only=pre-RA-sched` 与 `-debug-only=machine-scheduler` 是不同 DEBUG_TYPE 的并列输出通道——本任务 2.6 实测后者有效、前者在本测试无输出。）

### 2.5.3 设计动机
- SUnit/SDep 是 LLVM 调度的**通用货币**：两种调度（源级 SDAG、MI 级）语义不同但"节点+带类型边+latency"骨架相同，抽到 ScheduleDAG 基类避免双份维护。
- 边类型枚举的设计（Data/Anti/Output/Order + OrderKind 子分）为两者服务：SDAG chain → Barrier；SDAG glue → 同一 SUnit（不是边）。

### 2.5.4 昇腾映射（推理级，待验证）
- 若 PyPTO 想复用 LLVM 调度基础设施做 tile 重排，应学 ScheduleDAGSDNodes 的路线：继承 ScheduleDAG 复用 SUnit/SDep/addPred，自写 buildSchedGraph（tile 语义的边生成），而不是 fork MachineScheduler。风险：SUnit 的 MachineInstr 联合字段假设 MI 世界观——更彻底的做法是像 SDAG 那样用 SDNode 槽位放自定义节点。待验证：PyPTO tile 中间表示离 MachineInstr 有多远。

---

## §2.6 动态验证汇总（实测，build-debug AArch64）

测试素材：scratch/ls_barrier.ll（load/store/volatile/barrier 混合）、scratch/regions.ll（call 切 region）。

### Region 切分实证
含 call 的 MBB 被 BL + ADJCALLSTACKDOWN 切成多个 region，**自底向上处理**（底部 region 先打印）——getSchedRegions 自底向上扫描（MS.cpp:758-864）。

### 边类型全谱实证（-debug-only=machine-scheduler）
```
Data Latency=2 Reg=%10                          ← 真依赖（寄存器）
Ord Latency=0 Memory                            ← MayAliasMem（同对象 store→load）
Ord Latency=1 Barrier                           ← store→volatile load（TrueMemOrderLatency=1）
ExitSU: Ord Latency=1 Artificial                ← live-out 建模
Anti Latency=0 / Out Latency=1                  ← post-RA 才出现（WAR）
Cluster（弱边）                                  ← mutation 后才加（load 聚簇）
```
**load-load 无边**：不同对象 load 间无任何内存边——**同对象才有 Memory 边，跨对象仅靠 mutation 聚簇**。

### 坑点
- **`-debug-only=misched` 无输出**——正确 flag 是 `-debug-only=machine-scheduler`（"misched" 只是 cl 选项前缀）
- ExitSU 也有 dump（带 Data 边）；EntrySU 在 MI 调度构建期不加边

## §2.7 昇腾映射汇总（推理级，待验证）

PyPTO tile 依赖图（MTE 搬运→计算→搬运）的边分类对应：
1. **UB 数据流（搬运→计算）= Data 边**（真依赖+latency 按搬运距离）
2. **跨 UB 通道互斥 = Ord/Memory 边的类比**（若同 UB 地址可 alias 则 Memory 边——tile 框架 UB 地址可静态判定，可升级为更精确的 must-alias 边）
3. **set_cmpmask/barrier = Barrier 链**（全序约束，进 BarrierChain 集合）
4. ExitSU Artificial 边 = tile live-out 建模
5. **多 repeat（一指令多发射槽）不产生额外边**——资源约束走 SchedBoundary 资源计数，非依赖边

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| MachineScheduler.cpp:758-864 | getSchedRegions/scheduleRegions 协议 |
| ScheduleDAGInstrs.cpp:63, 173-194, 706-986 | DEBUG_TYPE/Region 边界/边分类判定序 |
| ScheduleDAG.h:55-78 | SDep 类型定义 |
| ScheduleDAG.cpp:38 | pre-RA-sched（SDAG 源级） |
| 实测：ls_barrier.ll/regions.ll | 边类型全谱/region 切分 |
