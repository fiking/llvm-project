# §5 HazardRecognizer 协议与三兄弟实现

> LLVM main @ 3eda2aebadd4。分析对象：`ScheduleHazardRecognizer` 协议本体与三个通用实现（Scoreboard / Multi / PostRA-pass）。
> 前置：§2 已析 MachineScheduler 的 SchedBoundary hazard 预过滤（本篇 §5.5 引用）；AMDGPU 独立 pass 极端形态见 AMDGPU-notes/07 §9.2-9.3。
> 铁律：所有 文件:行号 均经 grep/read 实核。

---

## 5.1 ScheduleHazardRecognizer 接口：完整协议

**文件**：`llvm/include/llvm/CodeGen/ScheduleHazardRecognizer.h`（129 行，下称 HR.h）

### 5.1.1 HazardType 三态（HR.h:39-43）

```cpp
enum HazardType {
  NoHazard,      // This instruction can be emitted at this cycle.
  Hazard,        // This instruction can't be emitted at this cycle.
  NoopHazard     // This instruction can't be emitted, and needs noops.
};
```

**语义辨析（任务书纠偏）**：任务书预期的 "NoHazardAtThisTime"（"现在不行但推进周期可以"）在当前 main **不存在**——全仓库 grep `NoHazardAtThisTime` 无命中。当前三态的语义分界是**"谁来修复"**：

| 值 | 含义 | 调度器反应（PostRASchedulerList.cpp:596-674 实证） |
|---|---|---|
| `NoHazard` | 本周期可发射 | 立即调度该节点 |
| `Hazard` | 本周期不能发射；**换别的指令**（"If some other instruction is available, issue it first"，HR.h:58-59） | 把该 SU 挂回 Available，当前 cycle 找其它候选；整 cycle 空转时 `AdvanceCycle()`（"Stall in cycle"，:666-668） |
| `NoopHazard` | 本周期不能发射且**换指令也救不了**；无互锁机器上硬性违约（"would break the program"，HR.h:60-61） | `HasNoopHazards` 置位（:615）；整 cycle 无指令可发时**必须 `emitNoop`**（:669-674）而非 stall——无流水线互锁的机器（如早期 MIPS）停等等于死循环 |

任务书设想的"现在不行但推进周期可以"语义，实际上是 **`Hazard` + `AdvanceCycle()` 循环**组合表达：`AdvanceCycle` 的契约就是"推进内部状态，使之前报 Hazard 的指令不再报"（HR.h:99-104："This should increment the internal state of the hazard recognizer so that previously 'Hazard' instructions will now not be hazards"）。三态是"回答什么"，`AdvanceCycle`/`RecedeCycle` 是"时间怎么走"——两者正交。

### 5.1.2 方法族全表（HR.h）

| 方法 | 行号 | 协议语义 |
|---|---|---|
| `MaxLookAhead` | :28-33 | 受保护成员，计分板状态深度；**=0 即"假识别器"**，客户端可绕过全部虚调用（`isEnabled()` :47）；注释明言 "Currently the PostRA scheduler ignores it"——PostRA 老调度器不利用该优化 |
| `atIssueLimit()` | :49-53 | 本周期是否已发满；FIXME 注释："remove this once MachineScheduler is the only client"——它是老客户端的遗留接口 |
| `getHazardType(SU, Stalls=0)` | :55-64 | 核心查询。`Stalls` 参数 = "假设 SU 将被调度到未来第 Stalls 个周期"的试探偏移（Scoreboard 用它在**不动状态**的情况下问"再等 N 个周期能否发射"，见 §5.2.3） |
| `Reset()` | :66-69 | 新调度区域开始时把 hazard 状态归零 |
| `EmitInstruction(SUnit*)` | :71-73 | 指令发射后推进 hazard 状态（记账） |
| `EmitInstruction(MachineInstr*)` | :75-77 | 非 SUnit 客户端（独立 pass）用的重载 |
| `PreEmitNoops(SUnit*/MI*)` | :79-92 | **发射前问"要垫几个 nop"**。注释 :82-83："This is only used during PostRA scheduling. EmitNoop is not called for these noops"——PostRA 调度器自己插 nop 时也不通知 EmitNoop |
| `ShouldPreferAnother(SU)` | :94-97 | NoHazard 但"换个更好"的弱信号（如 PPC 必须居组首的指令） |
| `AdvanceCycle()` | :99-104 | 自顶向下时间 +1（含 stall 与自然跨周期） |
| `RecedeCycle()` | :106-109 | 自底向上时间 -1（对称操作） |
| `EmitNoop()/EmitNoops(n)` | :111-124 | 流里真实插了 nop 后的通知；默认实现 = 按周期记账（转发 AdvanceCycle） |

### 5.1.3 EmitInstruction 的调用形态 / "PreEmit 打头"协议

协议规定的**标准发射序列**（PostRASchedulerList.cpp:642-658 实证）：

```
NumPreNoops = PreEmitNoops(SU)      // ① 问垫几个 nop
for i < NumPreNoops: emitNoop()     // ② 逐个垫（emitNoop 内部调 EmitNoop，:535-540）
ScheduleNodeTopDown(SU)             // ③ 节点入序
HazardRec->EmitInstruction(SU)      // ④ 记账
if atIssueLimit(): AdvanceCycle()   // ⑤ 发射宽度满则跨周期
```

三种消费形态对比：
- **PostRASchedulerList（调度器）**：全协议五步走（上式，:644-658）。
- **PostRAHazardRecognizer pass（非调度器）**：极简三步——`PreEmitNoops(&MI)` → `EmitNoops(n)` → `insertNoops` 物理插桩 → `EmitInstruction(&MI)`（PostRAHazardRecognizer.cpp:104-117）；`getHazardType` **完全不调用**（此形态下重排不可行，只补 nop）。
- **MachineScheduler（SchedBoundary）**：只走 ③④——`checkHazard` 里查 `getHazardType`（MachineScheduler.cpp:2717-2722），发射后 `EmitInstruction`（:3085-3094）；**从不调 PreEmitNoops/EmitNoop**（MachineScheduler 的 nop 由 `emitTargetHazardOp` 等另行处理，若 target 需要）。

**设计动机**：PreEmitNoops 与 getHazardType 的分工 = "调度器尽力重排（Hazard 换指令 / NoopHazard 才垫 nop）" 与 "最终兜底强制垫 nop" 两个修复层。MISched 时代 PreEmit 协议退化到 PostRA 专属（HR.h:82 注释），因为 MachineScheduler 用 bumpCycle 空转代替了插 nop。

---

## 5.2 ScoreboardHazardRecognizer：计分板算法

**文件**：`llvm/lib/CodeGen/ScoreboardHazardRecognizer.cpp`（241 行）+ `include/llvm/CodeGen/ScoreboardHazardRecognizer.h`（129 行）

### 5.2.1 数据结构：两张循环位图（H:40-89）

**任务书概念纠偏**：任务书的 "IssueTime 数组（每个资源的下次可用时刻）" 是经典计分板表述；LLVM 实现是**时间片位图（time-sliced bitmap）**而非每资源时间戳：

```cpp
class Scoreboard {
  InstrStage::FuncUnits *Data;  // 每元素 = 一张 64bit FU 占用位图
  size_t Depth;                 // 周期窗口深度（2 的幂）
  size_t Head;                  // 当前周期指针
};
```

- `Scoreboard[c]` 返回"第 c 个未来周期里哪些 FU 被占用"的位图（H:61-67，`Data[(Head + idx) & (Depth-1)]` 循环寻址）。
- **两张表**（H:106-107）：`ReservedScoreboard`（独占占用）与 `RequiredScoreboard`（实际需求占用）。双表语义来自 Itinerary 的 ReservationKinds（见 §5.2.4）。
- `advance()`/`recede()`（H:79-85）只挪 `Head` 指针——**O(1) 推进**，新周期的占用位图清零逻辑在 `AdvanceCycle()` 里显式做（cpp:229-233：先把 `[0]` 清零再 advance）。

**与 IssueTime 的等价性**：位图 `Board[c] & (1<<fu)` 为 1 ⟺ "FU fu 在 c 周期后被占用" ⟺ 经典 IssueTime[fu] > now+c。位图形式的优势：一条 `IS->getUnits()` 是**多选一 FU 组合**（"ALU0 或 ALU1 皆可"），位图按周期做 `units & ~occupied` 一条与运算即可判定整组；IssueTime 数组则需逐 FU 查最小可用时刻。

### 5.2.2 构造：深度 = 所有 itinerary 深度的上取整 2 幂（cpp:30-77）

```cpp
unsigned ScoreboardDepth = 1;
if (ItinData && !ItinData->isEmpty()) {
  for (每个 itinerary class) {
    // 遍历 stage 累加 CurCycle += IS->getNextCycles()，取最大完成时刻 ItinDepth
    while (ItinDepth > ScoreboardDepth) {
      ScoreboardDepth *= 2;
      MaxLookAhead = ScoreboardDepth;   // 只有存在非零 stage 才置位（:57-61）
    }
  }
}
```

三个要点：
1. **`MaxLookAhead=0 ⟺ 禁用`**：空 itinerary（`ItinData->isEmpty()`，即 Itineraries==nullptr，MCInstrItineraries.h:127）或全零 stage → 不设 MaxLookAhead → `isEnabled()==false` → 客户端全部绕过（cpp:69-70 打印 "Disabled scoreboard hazard recognizer"）。
2. **2 幂深度**是为了 `& (Depth-1)` 取模（H:63-64 有 assert）。
3. **IssueWidth 取自 ItinData->SchedModel.IssueWidth**（cpp:72-73），服务于 `atIssueLimit()`（cpp:104-109）——发射宽度约束也归 hazard 识别器管（老调度器视角）。

### 5.2.3 查询：getHazardType(SU, Stalls)（cpp:111-169）

```
cycle = Stalls                          // 自底向上时为负（cpp:116-117 注释）
for (IS : SU 的 itinerary stages) {
  for (i in 0..IS->getCycles()) {
    StageCycle = cycle + i
    if (StageCycle >= Depth) break;     // 探到窗口外 = 不可能冲突（:138-143）
    freeUnits = IS->getUnits()
    switch (IS->getReservationKind()) {
      Required: freeUnits &= ~Reserved[..];  // Required 与两类都冲突（fallthrough）
      Reserved: freeUnits &= ~Required[..];  // Reserved 只与 Required 冲突
    }
    if (!freeUnits) return Hazard;      // :157-161，日志 "*** Hazard in cycle +N"
  }
  cycle += IS->getNextCycles();         // stage 间推进（含负数/重叠语义，见 §5.2.4）
}
```

**lookAhead 步进逻辑**：查询侧**不推进状态**——`Stalls` 参数是调用方给的试探偏移。真正的"试探循环"在**客户端**：SelectionDAG 的 ScheduleDAGRRList `ScheduleNodeSDNode`（ScheduleDAGRRList.cpp:669-681）是最佳示例：

```cpp
int Stalls = 0;
while (true) {
  HT = HazardRec->getHazardType(SU, -Stalls);   // 底向上，偏移取负
  if (HT == NoHazard) break;
  ++Stalls;
}
AdvanceToCycle(CurCycle + Stalls);               // 一次性推进到可用周期
```

即：**"推进周期可否解决"由客户端用 Stalls=0,1,2,... 重问实现**，识别器自身无状态推进。注意 MachineScheduler 的 SchedBoundary 调 `getHazardType(SU)` 时 Stalls 恒为默认 0（MachineScheduler.cpp:2718）——MISched 依赖 bumpCycle+releasePending 的外循环来等效实现"重问"。

### 5.2.4 记账：EmitInstruction（cpp:171-227）

与查询对称：选一个空闲 FU 位**置位**到对应表（Required 置 RequiredScoreboard，否则 ReservedScoreboard，cpp:215-218）。两处 FIXME（cpp:131-132、:189-190）值得记录：**"同 stage 多周期应锁定同一 FU，当前实现每周期独立挑位"**——即查询时 ALU0 在 c0 空闲、ALU1 在 c1 空闲也算"可用"，比真实硬件乐观。

**与 Itinerary 的关系**：InstrStage 的三字段（MCInstrItineraries.h:59-92）：
- `Cycles_`：本 stage 占几个周期；
- `Units_`：FU 位图（"任一满足即可"的选择集）；
- `NextCycles_`：距下一 stage 的周期数——**可为 0（同周期并行 stage）或小于 Cycles（stage 重叠）**（:40-49 的注释给出三种 stage 写法的语义）；负值语义 = Cycles（:89-91）。

ReservationKinds（:51-57）：`Required`（真占 FU，与两类都冲突）vs `Reserved`（只锁不允许别人 Required，但多个 Reserved 可叠同一 FU）——**用于建模域切换 stall、共享寄存器文件的 FU**（:56-57 原注释）。

**结论（回答任务书问题）**：**是——ScoreboardHazardRecognizer 就是 Itinerary 数据的通用执行器**。Itinerary（TableGen 的 `InstrItinData`）描述"每类指令占哪些 FU 几个周期"，本身是死数据；Scoreboard 把它实例化为运行时资源占用表，任何 target 只要写了 itinerary 就免费获得 FU 冲突检测（ARM pre-RA 正是直接 `new ScoreboardHazardRecognizer(II, DAG, "pre-RA-sched")`，ARMBaseInstrInfo.cpp:123-131）。反向地：Itinerary 空 → Scoreboard 自动禁用。**注意**：Itinerary 还有 OperandCycles/Forwardings（读端口/旁路网络数据，MCInstrItineraries.h:99-105、:167-198），这部分**不归 Scoreboard 管**——它们被 TargetInstrInfo::getOperandLatency / TargetSchedule 消费（TargetInstrInfo.cpp:1780、:1852；MachineSchedule.cpp 的 MachineSchedStrategy 用 TSched 补延迟），即 **Itinerary = 资源（stage→Scoreboard）+ 端口/旁路（OperandCycle→延迟计算）两套数据的合集**。

### 5.2.5 推进/回退（cpp:229-241）

`AdvanceCycle()`：IssueCount 清零 + 两表 `[0]` 清零 + `advance()`（Head 前移，最老的未来周期变成新的当前周期）。`RecedeCycle()` 对称（清最深的槽再 recede）。**自底向上复用同一套表**：注释（H:36-39）"Scoreboard always counts cycles in forward execution order. If used by a bottom-up scheduler, then the scoreboard cycles are the inverse of the scheduler's cycles"——所以 Stalls 传负数、recede 反向挪 Head。

---

## 5.3 MultiHazardRecognizer：组合器

**文件**：`llvm/lib/CodeGen/MultiHazardRecognizer.cpp`（92 行）+ `include/llvm/CodeGen/MultiHazardRecognizer.h`

**组合语义（任务书纠偏：无 "StickyConstraint"）**：全仓库无此符号。实际语义是**"或"组合**：

```cpp
HazardType MultiHazardRecognizer::getHazardType(SUnit *SU, int Stalls) {
  for (auto &R : Recognizers) {
    auto res = R->getHazardType(SU, Stalls);
    if (res != NoHazard)
      return res;                    // 任一子识别器报 hazard 即返回（短路，cpp:33-41）
  }
  return NoHazard;
}
```

- `atIssueLimit`：`any_of`（cpp:28-31）；`ShouldPreferAnother`：`any_of`（cpp:72-77）。
- `PreEmitNoops`：**`std::max`** 而非求和（cpp:58-70）——"垫 nop 数取各识别器需求的最大值"，因为一次垫够最深的，浅的约束自然同时满足（nop 是通用的周期推进器）。
- `MaxLookAhead = max(子识别器)`（AddHazardRecognizer，cpp:22-26）。
- 其余（Reset/EmitInstruction×2/AdvanceCycle/RecedeCycle/EmitNoop）纯广播（cpp:43-92）。

**使用场景（唯一消费者：ARM，ARMBaseInstrInfo.cpp:137-171）**：

- `CreateTargetMIHazardRecognizer`（MISched 路径，:137-156）：Cortex-M7 且 post-RA（`!DAG->hasVRegLiveness()` 判据，:146）→ 叠 `ARMBankConflictHazardRecognizer`（TCM bank 冲突，构造设 `MaxLookAhead=1`，ARMHazardRecognizer.cpp:165-174）+ 默认基类实现（Scoreboard）。注释 :150-151 "Not inserting ARMHazardRecognizerFPMLx because that would change legacy behavior"——组合器让"加一种约束"成为纯增量操作。
- `CreateTargetPostRAHazardRecognizer`（老 PostRA 路径，:159-171）：Thumb2/VFP2 → 叠 `ARMHazardRecognizerFPMLx`（VMLA 后 4 周期 stall，:164-165）+ 基类 Scoreboard。

**设计动机**：target 的发射约束天然**多来源**（Itinerary 通用资源 + 微架构特有事件如 bank 冲突/MLx stall）。组合器把"约束集合"从"识别器实现"里解耦：每个约束独立成类、独立测试，工厂函数按 subtarget 特性装配。**注意一个细节**：它不是纯"或"——getHazardType 短路返回**第一个**非 NoHazard 值，所以若子识别器 A 报 Hazard、B 报 NoopHazard，返回的是 Hazard（顺序敏感）。ARM 的装配顺序恰好把更强的微架构约束放在前面。

---

## 5.4 PostRAHazardRecognizer：独立 pass（非"薄壳"）

**文件**：`llvm/lib/CodeGen/PostRAHazardRecognizer.cpp`（120 行）

**任务书假设纠偏**：它**不是转发壳**，而是一个完整的 MachineFunctionPass（legacy :49-65 + NPM `PostRAHazardRecognizerPass` :78-88）。头注释（:9-25）写明定位：

> "This runs the hazard recognizer and emits noops when necessary. This gives targets a way to run the hazard recognizer **without running one of the schedulers**."

两大适用场景（头注释 :14-20）：
1. **-O0 也要正确处理 hazard 的 target**（-O0 不跑调度器，但无互锁机器插 nop 是正确性问题）；
2. **保证调度区域开头的 hazard 也被处理**——PostRA 调度器是 top-down 但**区域按 bottom-up 顺序访问**（PostRASchedulerList.cpp:547-550 注释自认 "we don't know the hazards at the start of a region. So assume no hazards"），跨区域边界的 hazard 它天然看不见。

**它包了什么**：`TII->CreateTargetPostRAHazardRecognizer(MF, MLI)`（:92-93）——注意这是 **四参 (MF, MLI) 重载**，与调度器用的 (InstrItineraryData, ScheduleDAG) 重载**不是同一个虚函数**（TargetInstrInfo.h:1838-1844，默认返回 nullptr = "target 没实现就整 pass 空转"）。全仓库只有 AMDGPU 实现了这个重载（SIInstrInfo.cpp:10427-10432，`new GCNHazardRecognizer(MF, HazardRecognizerMode, MLI)`）。**运行协议**（run :90-120）：

```cpp
for (每个 MBB) {                    // 注意：不调 Reset()（:102-103 注释）
  for (每条 MI) {
    n = HazardRec->PreEmitNoops(&MI);
    HazardRec->EmitNoops(n);        // 状态推进
    TII->insertNoops(MBB, I, n);    // 物理 MIR 插桩
    HazardRec->EmitInstruction(&MI);
    if (atIssueLimit()) AdvanceCycle();
  }
}
```

关键设计点：**跨基本块不 Reset**（:102-103）——"to make sure we are handling noop hazards at the start of basic blocks"，即把函数全量指令流当成一条连续管线来追踪。这与调度器每个区域 Reset（PostRASchedulerList.cpp:405、:551）形成鲜明对照。正是这个差别让 GCNHazardRecognizer 在此形态下能做跨区域/跨基本块的 `getWaitStatesSince` 逆向 MIR 遍历（AMDGPU-notes/07 §9.2 已析，GCNHazardRecognizer.cpp:963-1022）。

**PostRA 调度器（PostRASchedulerList）如何消费识别器**：构造时经 **(II, DAG) 重载** 创建（PostRASchedulerList.cpp:219-221）并 new/delete 裸持有（:234-237）；每区域 `startBlock` 时 `HazardRec->Reset()`（:405）、`ListScheduleTopDown` 开头再 Reset（:551）；主循环完整实现 §5.1.3 的五步协议（:593-678），含 NoopHazard 兜底 `emitNoop`（:669-674）与 `ShouldPreferAnother` 的"NotPreferredSUnit 缓存重试"逻辑（:599-633）。

---

## 5.5 三种挂载形态对照与演进逻辑

| 维度 | ① Pre-RA 内嵌（MISched/SchedBoundary） | ② PostRA 调度器内嵌（PostRASchedulerList） | ③ 独立 pass（PostRAHazardRecognizer） |
|---|---|---|---|
| 工厂入口 | `CreateTargetMIHazardRecognizer(II, DAG)`（MS.cpp:3676-3679，Top/Bot 各一） | `CreateTargetPostRAHazardRecognizer(II, DAG)`（PRASL.cpp:219-221） | `CreateTargetPostRAHazardRecognizer(MF, MLI)`（PHR.cpp:92-93） |
| 默认实现 | Scoreboard（TII.cpp:1738-1741，debug 名 "machine-scheduler"） | Scoreboard（TII.cpp:1744-1748，"post-RA-sched"） | nullptr（TII.h:1840-1844，不实现则 pass 空转） |
| 调用的协议子集 | getHazardType(仅 Stalls=0) + EmitInstruction + Advance/RecedeCycle（bumpCycle 内，MS.cpp:2883-2894）+ Reset（call 处理 MS.cpp:3085-3089） | 全五步 + ShouldPreferAnother | PreEmitNoops + EmitNoops + EmitInstruction（**无 getHazardType**） |
| 重排能力 | 有（hazard 节点降级 Pending，02-skeleton §已析） | 有（Available 队列重找） | **无**（指令序已定型，只插 nop） |
| 状态生命周期 | 每区域新 DAG 重建（MS.cpp:2507-2512 注释"重建昂贵所以保留占位符"）；call 处 Reset | 每 MBB/区域 Reset | **函数级不 Reset**（跨 MBB 连续追踪） |
| 修复产物 | 重排 + bumpCycle 空转 | 重排 + Sequence 里的 nullptr（真 nop） | insertNoops 物理 MIR |

**演进逻辑**（从设计动机推演）：
- **①②（内嵌）**：hazard 约束参与**重排决策**——识别器回答"这条这周期能不能发"，调度器用指令交换/空转消化，性能优先。
- **②→③ 的动机**：内嵌形态的两个盲区——(a) -O0 不跑调度器，但无互锁 target 的 nop 是**正确性**问题；(b) 区域边界的"上一条已发射指令"在内嵌视角下不可见（区域 bottom-up 访问序）。③ 把识别器从调度决策中剥离，在**最终指令序**上做兜底正确性检查（这正是 AMDGPU 走到极端的形态：GCNHazardRecognizer 4361 行表驱动、跨 BB 逆向遍历，见 AMDGPU-notes/07 §9.2-9.3）。
- **① 与 ②/③ 的工厂分裂**：`CreateTargetMIHazardRecognizer` 是 MISched 时代新增入口（MISched 需要 VRegLiveness 感知的判据，如 AMDGPU `!DAG->hasVRegLiveness()` 区分 pre/post-RA，SIInstrInfo.cpp:10437-10446；ARM 同款判据 ARMBaseInstrInfo.cpp:146）；老的 `CreateTargetHazardRecognizer(STI, DAG)` 现在只剩 ARM/PPC 的 pre-RA 老路径在用（ARMBaseInstrInfo.cpp:123-132 返回 Scoreboard、PPCInstrInfo.cpp:105-117 只在 440/A2/E500mc/E5500 上返回 Scoreboard），并受 `-disable-sched-hazard` 开关控制（TargetInstrInfo.cpp:43-46、:1725-1727）。

**SelectionDAG 层的第四个消费点**（补充，任务书未列）：SelectionDAG 调度（pre-RA，SDNode 层）同样持有识别器：ScheduleDAGRRList.cpp 的 bottom-up `BUHasStall`（:2447-2453，getHazardType(SU,0)）与 `ScheduleNodeSDNode` 的 Stalls 递增试探循环（:669-681，本篇 §5.2.3 已引）——这是 `Stalls` 参数真正被用满的地方。加上 VLIW 的 VLIWMachineScheduler.cpp:359，协议的消费者共四类。

---

## 5.6 动态验证

### 验证 1：AArch64 -O3 PostRA 调度日志

构造用例（`scratch/hazard1.ll`，int64 加减乘除混合制造依赖链）：

```
build-debug/bin/llc -O3 -debug-only=post-RA-sched -mtriple=aarch64 -o /dev/null scratch/hazard1.ll
```

观察点（见 §5.6 实录）：`*** Examining Available`（PRASL.cpp:588）、`*** Scheduling [cycle]`（:521）、`*** Finished cycle`（:661）。AArch64 无 Itinerary（走 MISched 模型），`post-RA-sched` 的 Scoreboard 处于 disabled 分支——这本身验证了 §5.2.2 的 MaxLookAhead=0 禁用路径。AArch64 默认走 MachineScheduler 而非老 PostRA 调度器（需 `-enable-post-misched=false` 类开关或老 target 才走 ②）。

### 验证 2：MISched hazard 预过滤行

已有先例（02-skeleton §动态验证实录，此处引用不重跑）：

```
hazard: SU(14) ReadyCycle = 1 is later than CurrCycle = 0 on an unbuffered resource
```

该行来自 SchedBoundary::checkHazard 的软路径（ReadyCycle 比较，非 HazardRec 路径）；HazardRec 路径的日志模板为 `"hazard: SU(n) reported by HazardRec"`（MS.cpp:2719-2720）。AArch64 上 Itinerary 为空 → Scoreboard disabled → 不会出现后者。可在 ARM（有 Itinerary 的 target）上观察到 `Using scoreboard hazard recognizer: Depth = N`（ScoreboardHazardRecognizer.cpp:74-75）与 `*** Hazard in cycle +N`（:158）。

（两条验证的完整命令与输出见本节末尾"动态验证实录"补充。）

---

## 5.7 昇腾映射（推理级，均待验证）

**背景**：dav-m200 的 cmpmask 约束（装载后仅首条 vsel 有效）是一个**单次消耗型资源约束**：某指令（cmpmask 装载类）产出 cmpmask 后，第一条消费它的 vsel 有效，之后失效（需重新装载）。AMDGPU-notes/07 §9.4 曾把 GCN 的 (feature位, 谓词, 过期谓词, wait-states, 修复) 五元组映射到昇腾发射约束表；本节从 **Scoreboard 视角**补一个"资源化"方案。

### 5.7.1 Scoreboard 式建模

若把 cmpmask 建成计分板资源：

- **FU 位分配**：给"cmpmask 槽"分配 1 个 FU 位（`FuncUnits` 64bit 里留一位，如 bit 63）。装载指令的 Itinerary stage 写成 `{Cycles=N, Units=CMASK_SLOT, Kind=Required}`。
- **IssueTime 语义对应**：位图版 IssueTime 即 `Board[c] & CMASK_SLOT`——装载后 N 周期内该位为 1。
- **"仅首条有效"的难点**：Scoreboard 是**纯时间资源模型**（占用随周期自动释放），没有"消耗次数"概念。装载→首条 vsel 有效本质是**一次性令牌**而非时间窗。两种变通：
  - (a) **建模为时间窗 + vsel 消耗**：装载 stage = Required 占 CMASK_SLOT N 周期；vsel 的 stage = `Reserved` 类占用 CMASK_SLOT（Reserved 只与 Required 冲突）——但 Scoreboard 没有指令发射后"提前释放别人 Required 位"的钩子（EmitInstruction 只置位不清位，cpp:215-218），纯 Itinerary 建模表达不了"消耗"。
  - (b) **自定义子识别器 + MultiHazardRecognizer 组合**：写一个 `CmpMaskHazardRecognizer`（仿 `ARMHazardRecognizerFPMLx` 的 LastMI/FpMLxStalls 模式，ARMHazardRecognizer.cpp:41-99）：`EmitInstruction` 记录 LastCmpMaskLoad；`getHazardType` 判断"当前是 vsel 且引用的 cmpmask 已被消费"；`AdvanceCycle` 若干周期后过期。然后与 Scoreboard 一起塞进 `MultiHazardRecognizer`（§5.3 的"或"组合）。
- **lookahead 对应设计**：若约束是"装载后第 1 个周期必须消费否则浪费"，`MaxLookAhead=1`（同 ARMBankConflictHazardRecognizer 的设值方式，ARMHazardRecognizer.cpp:173）；若还存在"装载结果 X 周期后才可见"，则是经典的 `Stalls` 试探（客户端循环重问，§5.2.3）。

### 5.7.2 放哪个挂载点

- **性能优化**（尽量让首条 vsel 紧贴装载）→ 形态①（MISched 内嵌，`CreateTargetMIHazardRecognizer` 返回组合器），hazard 参与 Available/Pending 预过滤，调度器自动把别的指令挪开/凑近。
- **正确性兜底**（若硬件语义是"第二条 vsel 用旧 cmpmask 会产生错误结果而非仅性能损失"）→ 必须加形态③（独立 pass，(MF,MLI) 工厂重载），在最终指令序上逆向检查并插 nop/重装载——这正是 AMDGPU 的选择路径。
- **判定依据**：错误 cmpmask 是静默错误还是可恢复 stall，决定走 ① 还是 ①+③。GCN 的经验（AMDGPU-notes/07 §9.2）：跨区域边界只有 ③ 看得见，调度器内嵌永远只是尽力而为。

**待验证清单**：(1) cmpmask "仅首条有效"的确切硬件语义（发射槽占用 vs 数据失效 vs 异常）；(2) 昇腾现有调度约束在哪个 pass 检查；(3) 昇腾 target 是否已有 Itinerary/资源模型基础设施（决定 Scoreboard 方案是复用还是新建）。

---

## 引用清单（全部实核）

| # | 文件:行号 | 内容 |
|---|---|---|
| 1 | ScheduleHazardRecognizer.h:39-43 | HazardType 三态定义 |
| 2 | ScheduleHazardRecognizer.h:28-33 | MaxLookAhead=0 即假识别器（PostRA 忽略） |
| 3 | ScheduleHazardRecognizer.h:55-64 | getHazardType 协议 + 三态行为注释 |
| 4 | ScheduleHazardRecognizer.h:79-92 | PreEmitNoops 双重载 + "仅 PostRA 调度使用"注释 |
| 5 | ScheduleHazardRecognizer.h:94-97 | ShouldPreferAnother |
| 6 | ScheduleHazardRecognizer.h:99-109 | AdvanceCycle/RecedeCycle 契约 |
| 7 | ScheduleHazardRecognizer.h:111-124 | EmitNoop(s) 默认转发 AdvanceCycle |
| 8 | ScoreboardHazardRecognizer.h:40-89 | Scoreboard 循环位图类（Head/Depth/advance/recede） |
| 9 | ScoreboardHazardRecognizer.h:36-39 | "bottom-up 时计分板周期与调度器周期相反"注释 |
| 10 | ScoreboardHazardRecognizer.cpp:30-77 | 构造：深度=itinerary 最大深度的 2 幂；MaxLookAhead=0 禁用路径 |
| 11 | ScoreboardHazardRecognizer.cpp:111-169 | getHazardType：Required/Reserved 双表冲突规则；Stalls 试探 |
| 12 | ScoreboardHazardRecognizer.cpp:131-132, 189-190 | "FIXME 应锁定同一 FU"两处 |
| 13 | ScoreboardHazardRecognizer.cpp:171-227 | EmitInstruction 记账（单 FU 位归约置位） |
| 14 | ScoreboardHazardRecognizer.cpp:229-241 | AdvanceCycle/RecedeCycle 实现 |
| 15 | MCInstrItineraries.h:40-92 | InstrStage 三字段 + ReservationKinds 语义注释 |
| 16 | MCInstrItineraries.h:99-105, 167-198 | OperandCycles/Forwardings（读端口/旁路，非 Scoreboard 消费） |
| 17 | MCInstrItineraries.h:126-127 | isEmpty 判据 |
| 18 | MultiHazardRecognizer.cpp:22-26 | AddHazardRecognizer（MaxLookAhead 取 max） |
| 19 | MultiHazardRecognizer.cpp:33-41 | getHazardType 短路"或"组合 |
| 20 | MultiHazardRecognizer.cpp:58-70 | PreEmitNoops 取 max（非求和） |
| 21 | ARMBaseInstrInfo.cpp:121-171 | ARM 三工厂：pre-RA Scoreboard / MI 组合器 / PostRA 组合器 |
| 22 | ARMHazardRecognizer.cpp:41-99 | ARMHazardRecognizerFPMLx（LastMI+Stalls 计数模式） |
| 23 | ARMHazardRecognizer.cpp:165-268 | ARMBankConflictHazardRecognizer（MaxLookAhead=1） |
| 24 | PostRAHazardRecognizer.cpp:9-25 | 独立 pass 定位头注释（-O0/跨区域两场景） |
| 25 | PostRAHazardRecognizer.cpp:40 | DEBUG_TYPE "post-RA-hazard-rec" |
| 26 | PostRAHazardRecognizer.cpp:90-120 | run：不 Reset 跨 MBB 连续追踪 + PreEmitNoops 协议 |
| 27 | TargetInstrInfo.h:1820-1844 | 四工厂方法声明（(MF,MLI) 重载默认 nullptr） |
| 28 | TargetInstrInfo.cpp:1725-1748 | 默认实现：MI→Scoreboard("machine-scheduler")、PostRA→Scoreboard("post-RA-sched") |
| 29 | TargetInstrInfo.cpp:43-46 | -disable-sched-hazard 开关 |
| 30 | PostRASchedulerList.cpp:219-237 | SchedulePostRATDList 构造/析构持有识别器 |
| 31 | PostRASchedulerList.cpp:405, 551 | startBlock/ListScheduleTopDown 的 Reset |
| 32 | PostRASchedulerList.cpp:544-678 | 主循环全五步协议 + NoopHazard 兜底 + ShouldPreferAnother |
| 33 | MachineScheduler.cpp:2703-2722 | checkHazard 双模式注释 + "reported by HazardRec" 日志 |
| 34 | MachineScheduler.cpp:2883-2894 | bumpCycle 内 Advance/RecedeCycle 广播 |
| 35 | MachineScheduler.cpp:3085-3094 | EmitInstruction + call 时 Reset |
| 36 | MachineScheduler.cpp:2507-2512 | SchedBoundary::reset 保留占位符 |
| 37 | MachineScheduler.cpp:3676-3679, 4343-4346 | GenericScheduler/PostGenericScheduler 挂 MI 工厂（§4 已析） |
| 38 | ScheduleDAGRRList.cpp:669-681 | Stalls 递增试探循环（SelectionDAG 消费点） |
| 39 | ScheduleDAGRRList.cpp:2447-2453 | BUHasStall（bottom-up getHazardType(SU,0)） |
| 40 | VLIWMachineScheduler.cpp:359 | VLIW 消费点 |
| 41 | SIInstrInfo.cpp:10417-10446 | AMDGPU 三工厂（(II,DAG)/(MF,MLI)/MI 无 VRegLiveness 判据） |
| 42 | PPCInstrInfo.cpp:105-140 | PPC 工厂（PWR7/8→DispatchGroupSB、其余→970/Scoreboard） |
| 43 | PPCHazardRecognizers.cpp:142-176 | PPCDispatchGroupSB：NoopHazard/PreEmitNoops 实例 |
| 44 | HexagonInstrInfo.cpp:1900-1905 | Hexagon DFA hazard recognizer 工厂 |
| 45 | AMDGPU-notes/07-postemit.md §9.2-9.3 | GCNHazardRecognizer 独立 pass 极端形态（跨 BB 逆向遍历） |
| 46 | Sched-notes/02-skeleton.md §动态验证 | "hazard: SU(14) ReadyCycle..." 预过滤日志先例 |

（跨篇引用：§2 SchedBoundary 预过滤机制；§4 GenericScheduler 挂载点；AMDGPU-notes/07 §9 GCN 表驱动。）

---

## 附录：动态验证实录（主会话补录）

1. **AArch64 -debug-only=machine-scheduler**：`Disabled scoreboard hazard recognizer` ×2/区域（Top/Bot 各一）+ `hazard: SU(8) ReadyCycle = 1 is later than CurrCycle = 0 on an unbuffered resource` 预过滤行；`reported by HazardRec` 0 命中——与"AArch64 无 Itinerary→Scoreboard 禁用"一致。
2. **意外发现（未见于任何 notes）**：AArch64 上 `-debug-only=post-RA-sched` 空输出的根因——AArch64TargetMachine.cpp:595 `substitutePass(&PostRASchedulerID, &PostMachineSchedulerID)`，**老 PostRA 调度器在 AArch64 根本不运行**（被 MISched 的 PostRA 形态替换）。触发老调度器路径需换 ARM/PPC target。
