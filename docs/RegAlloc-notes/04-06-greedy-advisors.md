# §6 Greedy 主流程 + spill 决策链 / §8 顾问层 2×2

日期：2026-09-30 ｜ 基准：llvm-project main @ `3eda2aebadd4`（build-debug llc 已验证 LLVM 24.0.0git, DEBUG+assertions）
所有 file:line 均为本会话 grep/read 实测核对。中文行文 + 英文术语。

---

## §6.0 全景：三层结构

```
RegAllocGreedy (3008行, -O2 默认)
 ├─ 主循环: enqueue(priority) → selectOrSplit → assign/unassign
 ├─ 决策点①: PriorityAdvisor   → vreg 入队顺序（顾问入口①）
 ├─ 决策点②: EvictionAdvisor   → 踢谁/让谁（顾问入口②）
 ├─ split 路径: SplitAnalysis + SplitEditor(SplitKit 1944行) + SpillPlacement
 └─ spill 兜底: InlineSpiller (1965行) 三选一 remat/折叠/直接spill
```

Greedy 不是图着色器——没有显式干涉图（§4 的 LiveRegMatrix 384 行用 LiveIntervalUnion 查询代之）。它是**贪心 + 分裂 + 逐出**的迭代系统：每个 vreg 按优先级出队，问一句"免费分配？踢人？分裂？还是 spill？"，四层瀑布逐级降级。

---

## §6.1 主流程：allocatePhysRegs 循环 + enqueue 排序

### 6.1.1 主循环（RegAllocBase.cpp:88-151）

```
seedLiveRegs()                        // RegAllocBase.cpp:75 — 所有 vreg 的 LI 入队
while (const LiveInterval *VirtReg = dequeue()) {   // :92
  MCRegister AvailablePhysReg = selectOrSplit(*VirtReg, SplitVRegs);  // :116
  if (AvailablePhysReg)
    Matrix->assign(*VirtReg, AvailablePhysReg);
  ...
}
for (Register SplitVirtReg : SplitVRegs)   // :151 — split/evict 产物重新入队
  enqueue(SplitVirtReg);
```

关键设计：`selectOrSplit` 的返回值不只是物理寄存器，还通过 **`NewVRegs` 出参**带回"分裂/逐出产生的新 vreg 列表"，主循环结束后统一 re-enqueue（RegAllocBase.cpp:151），形成**外层迭代**——split 产物是新的一轮分配候选。`enqueue`（RegAllocBase.cpp:199-214）对已分配（`VRM->hasPhys`）和寄存器类被过滤的 vreg 直接跳过。

### 6.1.2 enqueue 与优先级（RegAllocGreedy.cpp:418-437）

```cpp
void RAGreedy::enqueue(PQueue &CurQueue, const LiveInterval *LI) {
  const Register Reg = LI->reg();
  auto Stage = ExtraInfo->getOrInitStage(Reg);
  if (Stage == RS_New) { Stage = RS_Assign; ExtraInfo->setStage(Reg, Stage); }
  unsigned Ret = PriorityAdvisor->getPriority(*LI);      // ← 顾问入口①
  CurQueue.push(std::make_pair(Ret, ~Reg.id()));         // (priority, ~vreg号)
}
```

**这是顾问层在主流程中的第一个插桩点**：`PriorityAdvisor->getPriority()` 是虚调用，规则版/ML 版在此切换。堆序为大根堆，`~Reg.id()` 作 tie-breaker（vreg 号小者优先）。LiveInterval 收缩时（`LRE_WillShrinkVirtReg`，RegAllocGreedy.cpp:385-393）unassign 后**重新入队**；被 clone 时（`LRE_DidCloneVirtReg`，:395-411）新寄存器继承父 stage。

### 6.1.3 默认优先级公式（DefaultPriorityAdvisor::getPriority，RegAllocGreedy.cpp:439-509）

四条分支：
1. **RS_Split stage**（被 split 过、未分出去的）：`Prio = Size`，且**不置 bit31**——推迟到其它都分完（:445-448）
2. **局部区间**（RS_Assign 且 `LIS->intervalIsInOneMBB` 且非 ForceGlobal）：按**指令位置**排序（`LI.beginIndex().getApproxInstrDistance(...)`，:459-471）——单 MBB 内线性顺序分配，注释称"absence of global interference 时最优着色"
3. **全局/巨型区间**：`Prio = Size`（长→短），`GlobalBit=1`（:472-478）——长区间先分，分不出去早 split/spill，避免它挡别人
4. ForceGlobal 条件（:453-456）：`Size/InstrDist > 2 * 可分配寄存器数` 或 `RC.GlobalPriority`

**位布局**（:480-501，代码注释原文）：
```
31: RS_Assign 优先标志   30: 有 physreg hint   29/24: GlobalBit
28-24 或 25: AllocationPriority (regclass)   0-23: Size/距离
```
即一个 32 位整数打包了 stage/提示/寄存器类/大小四维信息——这是**手工特征工程**的极端形态，ML PriorityAdvisor（§8.4）就是把这 32 位换成 3 个特征 + 模型。

---

## §6.2 selectOrSplit 主循环：四层瀑布决策

### 6.2.1 完整瀑布（selectOrSplitImpl，RegAllocGreedy.cpp:2658-2758）

```
selectOrSplit(VirtReg, NewVRegs)                    // :2331 入口（CO_Depth/CO_Interf 报错）
└─ selectOrSplitImpl(VirtReg, NewVRegs, FixedRegisters, RecolorStack)   // :2658
   ① CostPerUseLimit = ~0u;  Order = AllocationOrder::create(...)       // :2663-2666
   ② tryAssign()   → 找无干涉寄存器                              // :2667（→§6.2.2）
      └─ CSR 特例: tryAssignCSRFirstTime()                       // :2672-2679
   ③ NewVRegs 非空 → return（本轮已被 split）                    // :2683-2685
   ④ Stage != RS_Split → tryEvict()（踢低价值者）                 // :2694-2708（→§6.3）
   ⑤ Stage < RS_Split → setStage(RS_Split); "wait for second round";
      重新入队（等小区间都分完，干涉图更明朗再决策）               // :2712-2720
   ⑥ Stage < RS_Spill 且非空 → trySplit()                        // :2722-2728（→§6.4）
   ⑦ Stage >= RS_Done 或 !isSpillable → tryLastChanceRecoloring() // :2732-2735
   ⑧ 兜底: LiveRangeEdit LRE(...); spiller().spill(LRE, &Order);   // :2737-2757
      setStage(RS_Done); DebugVars->splitRegister(...)
```

第 ⑤ 层是 Greedy 区别于朴素贪心的关键：**first-seen 推迟**——注释（:2712-2714）"The first time we see a live range, don't try to split or spill. Wait until the second time, when all smaller ranges have been allocated. This gives a better picture of the interference to split around." 每个 vreg 至少经过两轮队列，分裂决策建立在近似完整的分配格局上。

### 6.2.2 tryAssign 与 LiveRegMatrix 查询协作（RegAllocGreedy.cpp:532-584)

```cpp
for (auto I = Order.begin(), E = Order.end(); I != E && !PhysReg; ++I)
  if (!Matrix->checkInterference(VirtReg, *I))    // ← §4 的矩阵查询
    if (I.isHint()) return *I;                    // hint 命中立即返回
    else PhysReg = *I;                            // 否则记住第一个可用
```

拿到可用 PhysReg 后还有两次优化（:549-583）：错过 hint 时先试 `canEvictHintInterference`（便宜地清掉 hint 寄存器上的干涉）再试 `trySplitAroundHintReg`（:1379，SplitThresholdForRegWithHint 阈值 :142），都不成才记入 `SetOfBrokenHints`（:570，结尾 tryHintsRecoloring :2646 有机会修复）；若 `RegCosts[PhysReg] > 0`（如 x86 的部分寄存器）则调 `tryEvict` 找更便宜的位置。

### 6.2.3 tryAssignCSRFirstTime：CSR 代价感知（RegAllocGreedy.cpp:2387-2419）

首次使用 callee-saved 寄存器 = prologue 要加 push/pop。规则：
- stage 已是 RS_Spill 且可 spill：`calcSpillCost(VirtReg) >= CSRCost` 则用 CSR，否则把 `CostPerUseLimit=1`（禁止后续 tryEvict 再碰 CSR），走 spill（:2390-2401）
- stage < RS_Split：先试 `calculateRegionSplitCost`（IgnoreCSR），找到低于 CSRCost 的分裂就预分裂（:2402-2417）

`calcSpillCost`（:2359-2379）= Σ(Reads+Writes)×BlockFrequency —— spill 代价的频率加权模型。`CSRCost` 由 `TRI->getCSRCost()` 与 `-csr-first-time-cost` 取 max，再按入口频率缩放（initializeCSRCost，:2426-2443）。

### 6.2.4 stage 状态机（RegAllocGreedy.cpp:319-326）

```
RS_New → RS_Assign → RS_Split → RS_Split2 → RS_Spill → RS_Done
```
StageName[] 数组即 `-debug-only=regalloc` 日志里每个决策头打印的内容（§6.6 动态验证可见）。

---

## §6.3 evict 路径：把低价值者踢出去（顾问入口②）

### 6.3.1 tryEvict → 顾问委派（RegAllocGreedy.cpp:718-731）

```cpp
MCRegister RAGreedy::tryEvict(...) {
  MCRegister BestPhys = EvictAdvisor->tryFindEvictionCandidate(
      VirtReg, Order, CostPerUseLimit, FixedRegisters);   // ← 顾问入口②
  if (BestPhys.isValid())
    evictInterference(VirtReg, BestPhys, NewVRegs);
  return BestPhys;
}
```

### 6.3.2 规则版判定链（DefaultEvictionAdvisor，RegAllocEvictionAdvisor.cpp:255-335）

`canEvictInterferenceBasedOnCost` 逐条检查 PhysReg 每个 regunit 的干涉 vreg：
- 干涉类型必须 ≤ `IK_VirtReg`（固定/裸物理寄存器干涉不可踢，:259-260）
- `FixedRegisters`（last-chance recoloring 圈定的）不可踢（:289-290）
- **`RS_Done` 的 spill 产物不可踢**——"Never evict spill products. They cannot split or spill."（:292-294）
- **Cascade 纪律**：同 cascade 或更新 cascade 拒绝（:298-300）；老 cascade 踢新 cascade 仅限 urgent（代价 ×10，:302-308）
- 代价累计：`Cost.MaxWeight = max(MaxWeight, Intf->weight())`；`Cost.BrokenHints += copyCost`（若踢掉满足 hint 的区间）（:309-315）
- `Cost >= MaxCost` 中止（:317-318）
- 逐条过 `shouldEvict` 策略（:322）
- 局部区间保护：`!MaxCost.isMax() && IsLocal && LIS->intervalIsInOneMBB(*Intf)` 且不能 canReassign → 拒绝（:327-330）

**shouldEvict 核心**（:218-233）：
```cpp
bool CanSplit = RA.getExtraInfo().getStage(B) < RS_Spill;
if (CanSplit && IsHint && !BreaksHint) return true;   // hint 优先，只要被踢者还能 split
if (A.weight() > B.weight()) return true;             // 权重比较
```

**NewWeight vs CostPerUseLimit 的关系**（tryFindEvictionCandidate，:337-373）：规则版没有直接叫 "NewWeight" 的量——对应物是 `BestCost.MaxWeight = VirtReg.weight()` 的初始化（:351-354，仅当 `CostPerUseLimit < ~0u` 即"找便宜寄存器"模式时）：被踢集合中最重者必须轻于申请者自身权重；完整模式（CostPerUseLimit == ~0u）则 `BestCost.setMax()` 无上限。`getOrderLimit`（:668-696）用 `RegClassInfo.getMinCost(RC) >= CostPerUseLimit` 剪枝整个类、`getLastCostChange` 截断同价长尾；`canAllocatePhysReg`（:698-712）拒绝 `RegCosts >= limit` 的寄存器和"limit==1 时的未用 CSR"。

### 6.3.3 evictInterference 执行 + Cascade 防环（RegAllocGreedy.cpp:617-656)

每轮 eviction 分配一个单调递增的 **Cascade 号**（`getOrAssignNewCascade`，:623），被踢者全部打上该号。断言（:647-651）禁止"cascade 号减小"的非法逐出（urgent 例外）。Cascade 本质是**时间戳仲裁**：A 踢 B 后，B 只能踢 cascade 更老的对象，DAG 化防止 A↔B 互踢死循环。被踢 vreg 收入 NewVRegs 回主循环重排队（:654）。

### 6.3.4 last-chance recoloring（tryLastChanceRecoloring，RegAllocGreedy.cpp:2295 附近 + mayRecolorAllInterferences :2048-2100+）

不可 spill 的 vreg（inline asm 约束等）最后的手段：递归尝试把干涉者改色。两个熔断：`LastChanceRecoloringMaxInterference`（:99，默认值在 cl::opt）与递归深度（CO_Depth/CO_Interf，selectOrSplit :2339-2353 转译为用户可见报错并提示 `-fexhaustive-register-search`）。

---

## §6.4 SplitKit 协议：区域分裂的数学

### 6.4.1 为什么分裂能代替 spill

一条横跨 N 个块的长区间在每个块都与不同对象干涉，但**单块内的干涉可能为零**。分裂把"全局不可分配"转化为"若干局部可分配 + 补集"。活跃域缩小后：
- 原区间的热区段分配到寄存器
- 冷区段（补集，complement）落到 stack——分裂本身不消除 spill，只是**把 spill 局部化到冷区间**，期望总代价（频率加权）更低

### 6.4.2 三层分裂瀑布（trySplit，RegAllocGreedy.cpp:1978-2013）

```cpp
if (getStage(VirtReg) >= RS_Spill) return;              // RS_Spill 以上不再 split
if (LIS->intervalIsInOneMBB(VirtReg)) {                 // 单 MBB：局部路线
  SA->analyze(&VirtReg);
  tryLocalSplit(...)      // :1747 — 单块内再切
    → tryInstructionSplit(...)  // :1594 — 逐指令切（最细）
} else {
  SA->analyze(&VirtReg);
  if (getStage < RS_Split2) tryRegionSplit(...)         // :1209 — 跨块区域分裂
  tryBlockSplit(...)       // :1472 — 退化为每块一区间
}
```

- **tryRegionSplit**：区域分裂主路径。`calculateRegionSplitCost`（:1319）对每个 GlobalSplitCandidate（每个候选物理寄存器一个）调 `growRegion`（:875）用 **SpillPlacement**（块级偏置传播，SplitConstraints :742 + ThroughConstraints :815）算出"哪些块给这个寄存器"的区域，比较 `SpillPlacer->calculateSpillCost` 决定 BestCand；`doRegionSplit`（:1337）执行。
- **tryBlockSplit**（:1472 注释）："Split a global live range around every block with uses. This creates a lot of local live ranges, that will be split by tryLocalSplit if they don't fit."——粗粒度兜底，产物回队列再走局部路线。
- **trySplitAroundHintReg**（:1379）：hint 寄存器专用的区域分裂，配合 `-split-threshold-for-reg-with-hint`（:142）。

### 6.4.3 SplitEditor 编辑协议（SplitKit.cpp）

SplitKit 是**指令级区间编辑器**，RAGreedy 通过开区间原语描述"新区间覆盖哪些槽位"：

```
openIntv()               // SplitKit.cpp:690 — 创建新区间
enterIntvBefore/After    // :708/:725 — 定义起点（插 copy）
useIntv(Start, End)      // :784 — 声明覆盖槽位段
leaveIntvAfter/Before/AtTop // :791/:822/:841 — 定义终点
overlapIntv              // :868 — 让两区间短暂共存（块边界交接）
```

`splitSingleBlock`（:1650-1663）即这些原语的最小组合：openIntv → enterIntvBefore(FirstInstr 与 LastSplitPoint 取 min) → useIntv → leaveIntv*。**splitSingleInterval 与 editRange 的差异**——代码里实际的名字是 `splitSingleBlock`（单块区间化，只处理一个 MBB 的 use 域）与 `splitLiveThroughBlock`/`splitRegInBlock`/`splitRegOutBlock`（:1676/:1778/:1871，处理 live-through/仅入口/仅出口三种块角色，由 `splitAroundRegion`（RegAllocGreedy.cpp:1070-1123+）按 BundleCand 分派）。两者差异：splitSingleBlock 不依赖全局候选（GlobalCand），服务于块级/补集分裂；后三者接受 `IntvIn/IntfIn/IntvOut/IntfOut` 参数，在块边界与全局区间交接并让开干涉位置（IntfIn/IntfOut 即干涉首尾点，copy 插在干涉之外）。

**finish() 收尾**（SplitKit.cpp:1545-1600）：把 parent 的每个 VNI 经 `defValue` 归入对应新区间（:1551-1562）→ 按 SpillMode（SM_Partition/SM_Size/SM_Speed，:1564-1573）决定 hoistCopies 行为 → `transferValues`（:1180，值映射+copy 插入）→ `rewriteAssigned`（:1361，重写指令操作数）→ `extendPHIKillRanges` → `deleteRematVictims` → 对每个新区间 `removeEmptySubRanges + RenumberValues`（:1591-1595）。

### 6.4.4 与 LiveIntervals 的增量更新协议（"-split-editors 模式"）

任务书中的 "-split-editors 模式" 在源码中的实际机制是 **LiveRangeEdit 委托回调 + LiveIntervals::HMEditor**：
- `LiveRangeEdit`（llvm/include/llvm/CodeGen/LiveRangeEdit.h:42）实现 `MachineRegisterInfo::Delegate`，并自带 `Delegate` 接口：`LRE_WillEraseInstruction`（:52）、`LRE_CanEraseVirtReg`（:56）、`LRE_WillShrinkVirtReg`（:59）、`LRE_DidCloneVirtReg`（:63）
- RAGreedy 把自己注册为 delegate（RegAllocGreedy.cpp:370-411 三个 LRE_* 实现：erase 前 unassign、shrink 后 re-enqueue、clone 继承 stage）
- 指令插入/删除时 LiveIntervals 经 `HMEditor`（LiveIntervals.cpp:1081）+ `repairOldRegInRange`（:1677）做**增量区间修复**，而非全量重算——这是 split 后区间保持一致性的核心通道

### 6.4.5 shouldSplitSingleBlock 的判定（SplitKit.cpp:1630-1648）

多指令块必分；单指令块仅当（a）显式 SingleInstrs（proper subclass 需要寄存器类膨胀，见 splitAroundRegion :1079-1083 注释）或（b）live-through；copy 类指令不分（无寄存器类约束）；分裂产物端点不再分（`isOriginalEndpoint`，防递归）。

---

## §6.5 spill 决策链：InlineSpiller 三选一

### 6.5.1 Spiller 接口与实现史

Spiller.h（include/llvm/CodeGen/Spiller.h）定义极简接口：`spill(LRE, Order)` / `getSpilledRegs()` / `getReplacedRegs()` / `postOptimization()`。工厂唯一：`createInlineSpiller`（Spiller.h 尾部声明，InlineSpiller.cpp:241-260 实现）。**"spillInline vs spillRanges 多实现"已不存在**：git 考古（`git log -- llvm/lib/CodeGen/Spiller.cpp` 首条）commit `cdd9077f3aa1` "[RegAlloc] Kill off the trivial spiller - nobody is using it any more" 删除了最后一个竞品——历史上曾有三实现（trivial/inline/deferred-via-VirtRegMap），现在**只剩 InlineSpiller 一家**。Spiller.cpp 只余 anchor。

### 6.5.2 三选一瀑布（InlineSpiller::spill，InlineSpiller.cpp:1460-1486）

```cpp
void InlineSpiller::spill(LiveRangeEdit &edit, AllocationOrder *order) {
  Original = VRM.getOriginal(edit.getReg());    // 共享栈槽的家族根
  collectRegsToSpill();                         // :389 — 主 reg + snippet copies
  reMaterializeAll();                           // :834 — 选择① remat
  if (!RegsToSpill.empty())
    spillAll();                                 // :1411 — 选择②③ 折叠 + 直接 spill
  Edit->calculateRegClassAndHint(MF, VRAI);
}
```

**选择① rematerialization**（reMaterializeAll，:834-929）：对 RegsToSpill 每个 use 调 `reMaterializeFor`（:674）——若 def 是可重算指令（常量加载等），在 use 处重插 def 而非 reload。全部 remat 成功的 vreg 从 RegsToSpill 剔除进 `RegsReplaced`（:912-918），后续死 def 由 `Edit->eliminateDeadDefs` 清除（:904）。`RestrictStatepointRemat` 下的保守检查在 `canGuaranteeAssignmentAfterRemat`（:622-657）。**判定条件**：def 指令可安全重放（isTriviallyReMaterializable 族，经 VirtRegAuxInfo::isRematerializable——同 ML 特征 IsRemat 的来源）。
**选择② 折叠**（coalesceStackAccess，:936-963）：use 恰好是对同栈槽的 load/store（`TII.isLoadFromStackSlot/isStoreToStackSlot` 且 `FI == StackSlot`）→ 直接删指令，reload/store 计数对消（:954-960）。**判定条件**：指令形式与栈槽双匹配。
**选择③ 直接 spill**（spillAll，:1411-1458）：`VRM.assignVirt2StackSlot` 分配/复用栈槽（家族共享，:1413-1421）→ `StackInt->MergeSegmentsInAsValue` 把所有 spill 区间并成一条 stack 区间（:1423-1427）→ `spillAroundUses`（:1315）在每个 use 前插 reload、def 后插 store（insertReload :1247 / insertSpill :1277）→ 消死码 → 删 snippet copies → `Edit->eraseVirtReg`（:1456）。

辅助优化：`hoistSpillInsideBB`（:441+，把 spill 提到 def 后以消 x/y 干涉，注释 :422-439 有图示）与收尾的 `HoistSpillHelper::hoistAllSpills`（:1812，postOptimization :1489 触发，跨块提升合并 spill）。

---

## §6.6 动态验证①：-debug-only=regalloc 决策日志

见 §V（自构造 AArch64 双臂压力用例：187 次 selectOrSplit、12 次 evict+Cascade、9 次 second-round、9 次 InlineSpilling 全部实证）。

## §6.7 设计动机小结

1. **瀑布而非最优**：每层只在前层失败时启用，代价从 0（免费分配）单调升到 spill；两层"wait for second round"（§6.2.1⑤）用延迟决策换取干涉信息完整性。
2. **Cascade 时间戳**替代全局仲裁，O(1) 防环。
3. **split 优先于 spill**：split 保留热区寄存器驻留、只惩罚冷区，数学上等价于"最小化频率加权 spill 代价"的局部搜索。
4. **InlineSpiller 三选一**是"同一栈槽代价下的三档实现"：remat 零内存流量 > 折叠零指令 > 显式 reload/store。
5. **一切修改走 LiveRangeEdit**：spill/split/erase 的区间增量一致性由单一编辑器 + 委托回调保证，allocator 永不直接改区间。

---

## §8 顾问层 2×2 矩阵

```
                 规则基线                            ML 推理/训练
Priority   DefaultPriorityAdvisor            MLPriorityAdvisor / DevelopmentMode
(入队顺序)  RegAllocGreedy.cpp:439-509        MLRegAllocPriorityAdvisor.cpp:100-414
Eviction   DefaultEvictionAdvisor            MLEvictAdvisor / DevelopmentModeEvictAdvisor
(踢谁)      RegAllocEvictionAdvisor.cpp:218-373  MLRegAllocEvictAdvisor.cpp:302-983
```

共同骨架：两个抽象基类 `RegAllocEvictionAdvisor` / `RegAllocPriorityAdvisor`（include/llvm/CodeGen/RegAllocEvictionAdvisor.h，310 行）定义虚接口 + 共享工具（canReassign / getOrderLimit / canAllocatePhysReg / isUnusedCalleeSavedReg——**类成员定义在 RegAllocGreedy.cpp:590-712**，规则与 ML 共用：ML 只替换"挑选"这一步，合法性剪枝完全继承）。这正是"决策点外挂"的接口边界。

### §8.1 RegAllocEvictionAdvisor（373 行，规则基线）

见 §6.3.2-6.3.3。补充：构造（:178-188）从 `TRI->getRegisterCosts(MF)` 取每寄存器代价表；`EnableLocalReassignment`（:43-46）+ target hook `enableRALocalReassignment` 控制局部重分配。模式开关 `-regalloc-enable-advisor`（:30-41）三值 default/release/development。`EvictInterferenceCutoff=10`（:49-55）为编译时熔断。

### §8.2 MLRegAllocEvictAdvisor（1089 行）：推理 wrapper

**开关与加载路径**：
- `-regalloc-enable-advisor=release` → `ReleaseModeEvictionAdvisorProvider`（:401）→ 加载 AOT/tflite 模型；`development` → `DevelopmentModeEvictAdvisorProvider`（:493，需 `LLVM_HAVE_TFLITE`，:986）
- 模型选择 `-regalloc-mlgo-model`（SelectedMLGORegAllocModel :68）；训练配置 `-regalloc-training-log`（:123）与 `-regalloc-model`（ModelUnderTraining :127，dev 模式下加载在训模型+记录 extra outputs）；交互模式 `InteractiveChannelBaseName`（:104，配合 python 训练循环，测试 interactive-mode.ll）
- Release/Development 语义（dev-rel-equivalence.ll 验证二者决策等价）：Release 走 `ModelUnderTrainingRunner` 之外的纯推理 `MLModelRunner`；Development 包一层日志（`Logger`，MLLoggerBase）且**无模型时回退 DefaultAdvisor**（DevelopmentModePriorityAdvisor::getPriority 的 `isa<ModelUnderTrainingRunner>` 分支，MLRegAllocPriorityAdvisor.cpp:371-375——evict 版同构）

**决策协议**（MLEvictAdvisor::tryFindEvictionCandidate，:727-838）：
1. 沿 AllocationOrder 迭代，每个物理寄存器经 `loadInterferenceFeatures`（:650-725）做与规则版**完全相同的合法性检查**（IK_VirtReg / FixedRegisters / RS_Done / cascade / urgent / local），通过者提取特征填入对应列；不可用列 mask=0
2. `MustFindEviction`（:741-742）：申请者不可 spill 且无成本限制时必须选出（否则违规）
3. 特征归一化：每特征除以本次决策中该列最大值（:798-808）；`progress = queueSize/InitialQSize`（:809-810）
4. `Runner->evaluate<int64_t>()` 返回 `index_to_evict`（DecisionSpec :251-253），契约保证落在 mask==1 的列
5. `MaxEvictionCount`（:112）防"对抗性模型反复互踢烧编译时间"（:700-707 注释原文），`onEviction` 计数
6. **模型可选"不踢"**：`CandidatePos == CandidateVirtRegPos`（:818-822）时返回 NoRegister——申请者自己让位（等效接受后续 split/spill），规则版没有这个出口

**特征向量**（RA_EVICT_FEATURES_LIST，:201-245；聚合逻辑 extractFeatures :892-983，单区间组件 getLIFeatureComponents :841-888）：每特征是 `{1, NumberOfInterferences}` 的列向量（AllocationOrder 顺序，最后一列是申请者自身）。21 个特征分四类：
- **合法性/上下文**：mask、is_free、is_hint、is_local、nr_urgent、nr_broken_hints、max_stage/min_stage（分裂代数）、progress（队列消耗比例）
- **区间静态特征**：liverange_size（槽位跨度）、nr_defs_and_uses、nr_rematerializable
- **频率加权动态特征**：weighed_reads/writes/read_writes_by_max（R/W/RW 按 BlockFrequencyRelativeToEntryBlock 累计，:868-873）、weighed_indvars_by_max（循环出口写 =归纳变量更新模式，:875-880）、hint_weights_by_max（copy hint 指令频率）、start/end/hottest_bb_freq_by_max
- **综合**：use_def_density（= 手工启发式算出的 max weight，:923——新旧两套打分的桥接特征）

即 ML 特征 = **把规则版 EvictionCost（MaxWeight+BrokenHints 二元组）分解为 21 维细粒度信号**，其中频率加权读写/归纳变量模式是规则版根本看不到的维度。

### §8.3 RegAllocPriorityAdvisor（219 行）与 ML 版（421 行）

规则版 DefaultPriorityAdvisor 见 §6.1.3（RegAllocGreedy.cpp:439-509）；另有 DummyPriorityAdvisor（:511-515，`~vregIndex`，测试/调试用，对应 `-regalloc-enable-priority-advisor=dummy`）。开关 `-regalloc-enable-priority-advisor`（RegAllocPriorityAdvisor.cpp:23-36）四值 default/release/development/dummy。

**MLPriorityAdvisor**（MLRegAllocPriorityAdvisor.cpp）特征仅 3 个（getPriorityImpl，:346-355）：
```cpp
*Runner->getTensor<int64_t>(0) = Size;      // 区间大小
*Runner->getTensor<int64_t>(1) = Stage;     // RS_* stage
*Runner->getTensor<float>(2)  = weight;     // spill 权重
return Runner->evaluate<float>();           // → convertAdviceToPriority
```
输出经 `convertAdviceToPriority`（:337-344）饱和转换（NaN assert + clamp 到 [0, UINT_MAX]）。

**为什么顺序重要（为什么值得 ML 化）**：贪心分配是不可逆序列决策——先分谁决定了后面所有人面对的干涉格局。规则版用"长区间优先 + 局部区间按指令序 + hint 提升"的静态启发式，但最优顺序依赖程序形态（例如先分一条中等长度但干涉密集的区间，可能让两条长区间都不用 spill）。这本质上是一个 **sequencing 问题**，与 evict 的"每步选谁"正交，所以拆成两个独立顾问。ML 版把 32 位打包位图还原为 3 个原始特征交给模型学排序。

### §8.4 训练流水线：MLRegAlloc 测试目录的 corpus 工具链

llvm/test/CodeGen/MLRegAlloc/ 的 RUN 行揭示了完整工具链（dev-mode-logging.ll:5-25 实测）：
```
① 训练日志生成（生产编译即收集器）:
   llc -regalloc=greedy -regalloc-enable-advisor=development \
       -regalloc-training-log=<log>  input.ll
   → 开发模式 advisor 在每次决策点记录 (特征张量, 决策, reward) 到 protobuf 日志
② 日志解读:  llvm/lib/Analysis/models/log_reader.py <log>
③ 测试模型生成: gen-regalloc-eviction-test-model.py → saved-model-to-tflite.py
④ 交互式训练: InteractiveChannelBaseName + Inputs/interactive_main.py（外部 python RL 循环
   经 pipe 与 llc 内的 advisor 交互——in-compiler training loop）
⑤ 等价性守护: dev-rel-equivalence.ll 验证 development 与 release 模式输出一致
```
奖励信号来自 `RegAllocScoring` pass（MLRegAllocEvictAdvisor.cpp:141-168, 1043-1061）：按函数统计 spill/eviction代价算 reward。dev-mode-logging.ll 的 CHECK 序言展示了日志格式（`context: <fn>` / `observation: N` / `mask:` / `index_to_evict` / `reward: 38.90`——ML 与 NOML 两种参考日志 reward 对比即训练目标）。**"在生产编译中收集轨迹"**= 对任意 .ll/.bc 开 `-regalloc-training-log` 跑 llc/clang，无需改编译器。

### §8.5 顾问层 2×2 总表

| | Priority（顺序） | Eviction（逐出） |
|---|---|---|
| 决策粒度 | 每 vreg 入队时 1 次 | 每次分配失败后每候选寄存器 1 次 |
| 规则版核心 | 32 位位图（size+stage+hint+class） | EvictionCost(MaxWeight, BrokenHints) + cascade |
| ML 特征 | 3 个（Size/Stage/weight） | 21 个（列向量/AllocationOrder 位置） |
| 模型输出 | float→unsigned 优先级 | index_to_evict（含"不踢"出口） |
| 共享骨架 | RegAllocPriorityAdvisor 基类 | canReassign/getOrderLimit/canAllocatePhysReg 等合法性剪枝共用 |
| 开关 | -regalloc-enable-priority-advisor | -regalloc-enable-advisor |

---

## §V 动态验证

### V.0 测试用例（scratch/stress_aarch64_3.ll，自构造 AArch64 版 sgpr_stress 配方）

36 个 i32 参数 → 36 个 `%vN = add` → **双臂分支**（arm-a 加法树 / arm-b 乘法树，不同运算防折叠合并）→ phi 汇合。设计动机：单块版本被调度器交错排列完全消解（1294 行日志零压力）；**跨双臂活跃的 36 值无法调度消除**——两臂都必须在 entry 的全部 def 存活时消费它们。AMDGPU-notes/05 的"双臂分支消费所有值"配方移植。

```bash
build-debug/bin/llc -mtriple=aarch64-linux-gnu -debug-only=regalloc \
  RegAlloc-notes/scratch/stress_aarch64_3.ll -o /dev/null 2> ra_debug3.log
```

### V.1 -debug-only=regalloc 决策日志（ra_debug3.log，3597 行，全部断言有源码出处）

| 日志证据 | 计数 | 源码出处（本会话核对） |
|---|---|---|
| `selectOrSplit GPR32:%N ...` | 187 | RegAllocBase.cpp:109 |
| `RS_Assign/RS_Spill Cascade N` stage 头 | 31 | RegAllocGreedy.cpp:2688（StageName[] :319-326） |
| `evicting $wN interference: Cascade N` | 12 | RegAllocGreedy.cpp:625-626 |
| `should evict: %N ...` | 28 | RegAllocEvictionAdvisor.cpp:229 |
| `wait for second round` | 9 | RegAllocGreedy.cpp:2717（瀑布第⑤层） |
| `Inline spilling ...` | 9 | InlineSpiller.cpp:1470-1473 |
| `queuing new interval:` | 多处 | RegAllocBase.cpp:148 |
| `no positive bundles` | 多处 | RegAllocGreedy.cpp:1275（区域分裂候选评估） |
| `Analyze counted N instrs in M blocks` | 多处 | SplitKit.cpp:192（SplitAnalysis::analyzeUses） |

**瀑布逐层实证**（日志原文摘录，ra_debug3.log）：

① **evict + Cascade 链式反应**（顾问入口②的完整闭环）：
```
selectOrSplit GPR32common:%89 ... weight:1.808318e-03
RS_Assign Cascade 0
should evict: %55 [272r,1632r:0) ... weight:1.136364e-03     ← shouldEvict 的 A.weight()>B.weight()
evicting $w11 interference: Cascade 1                          ← evictInterference :625
unassigning %55 from $w11: W11                                 ← Matrix->unassign
assigning %89 to $w11: W11 ...
queuing new interval: %55 ...                                  ← 被踢者回队列
Enqueuing %55
selectOrSplit GPR32common:%55 ...                              ← 被踢者二轮决策
RS_Assign Cascade 1                                            ← cascade 号已被打上
evicting $w8 interference: Cascade 1                           ← 踢更老 cascade 的 %50
```
注意 `%89(weight 1.81e-3) → 踢 %55(1.14e-3) → 踢 %50(1.00e-3)` 的权重降序链——A.weight() > B.weight() 的动态演示；每个被踢者立即重新入队再决策（外层迭代实证）。

② **"wait for second round"**（瀑布第⑤层）：
```
selectOrSplit GPR32common:%50 [192r,1792r:0) 0@192r  weight:1.000000e-03
RS_Assign Cascade 1
wait for second round
queuing new interval: %50 ...   → Enqueuing %50（下一轮再战）
```

③ **spill 三选一完整演示**（InlineSpiller 全路径，一个 vreg 依次经历三关）：
```
selectOrSplit GPR32:%198 [680r,1904r:0)[2544B,2560r:0) ... weight:1.230207e-03
hints: $w8 $w8
RS_Spill Cascade 0                                              ← 瀑布已到第⑧层
Inline spilling GPR32:%198 ... From original %39                ← 家族根 %39（栈槽共享）
	skipping remat of def %198:gpr32 = lr-split COPY %199       ← 选择① remat：def 是 COPY，拒绝（InlineSpiller.cpp:682）
	cannot remat for 2560e	%111:gpr32 = MADDWrrr ...           ← remat 对每个 use 尝试失败（:760/:786）
Merged spilled regs: SS#0 [680r,1904r:0)[2544B,2560r:0) ...     ← spillAll :1427，家族栈槽 SS#0
spillAroundUses %198
	folded:   680r	STRWui %199:gpr32, %stack.0, 0 ...          ← 选择② 折叠（LiveRangeEdit.cpp:159）
	reload:   2552r	%200:gpr32 = LDRWui %stack.0, 0 ...        ← 选择③ reload（InlineSpiller.cpp:1258 标签）
	rewrite: 2560r	%111:gpr32 = MADDWrrr killed %200 ...       ← use 重写（:1401）
```
`%198` 是 `%39` 的 split 产物（`lr-split COPY` 是 SplitEditor 插的区间交接 copy，MIRPrinter.cpp:908 打印标记）——split→仍失败→spill 的全链路在一个 vreg 上闭环。汇编侧证据：`str [sp`×5、`ldr [sp`×40（含参数溢出）。

④ **split 路径的 SplitEditor 内部日志**（transferValues/rewriteAssigned）：
```
  blit [2544B,2560r:0): [2544B;2560r)=0(%198)(recalc)          ← SplitKit.cpp:1184（值直传，无需 copy）
  rewr %bb.0 128r:1  %199:gpr32 = COPY $w0                    ← SplitKit.cpp:1394（rewriteAssigned）
  rewr %bb.0 680B:1  %198:gpr32 = lr-split COPY %199
queuing new interval: %198 / %199                              ← split 产物双双回队列
```

### V.2 -regalloc-enable-advisor 开关对比（无 ML runtime 行为）

build-debug 为 DEBUG 构建，CMakeCache `LLVM_HAVE_TFLITE:BOOL=`（空）——**无 TFLite/AOT runtime**。实测（llc 退出码 0，stderr 各一行）：

| 命令 | 行为 |
|---|---|
| `-regalloc-enable-advisor=default` | 静默走规则版（DefaultEvictionAdvisor） |
| `-regalloc-enable-advisor=release` | `error: Requested regalloc eviction advisor analysis could not be created. Using default` → **回退规则版** |
| `-regalloc-enable-advisor=development` | 同上 → 回退规则版 |
| `-regalloc-enable-priority-advisor=release/development` | `error: Requested regalloc priority advisor analysis could not be created. Using default` → 回退 |

与 llvm/test/CodeGen/MLRegAlloc/default-eviction-advisor.ll 的 RUN 行预期一致（该测试 `not llc ... -regalloc-enable-advisor=development` 断言报错）。**结论：开关打开而模型缺失时，分析创建失败→自动降级规则版并报错提示，allocator 永不因此崩溃**——护栏设计的实证。dev 模式日志（-regalloc-training-log）在本构建同样因 option 未注册而不可用（`Unknown command line argument`——该 cl::opt 定义在 `#ifdef LLVM_HAVE_TFLITE` 块内，MLRegAllocEvictAdvisor.cpp:123），训练轨迹收集需要 TFLite 构建的编译器。

---

## §A 昇腾映射（推理级，待验证）

**PyPTO tile 分配的"决策点外挂"模式**：LLVM 顾问层的架构启示——

1. **不重写 allocator，只换决策函数**：RAGreedy 的 3008 行主循环、SplitKit、InlineSpiller 对顾问完全无感知；顾问只出现在两个虚调用点（getPriority :432 / tryFindEvictionCandidate :726）。合法性剪枝（cascade/RS_Done/FixedRegisters 检查）在基类共享，模型**只做挑选不做合法性**——坏模型最坏输出也是合法但次优的分配，不会破坏 allocator 不变量。PyPTO 的 tile→buffer 分配若外挂"tile 摆放/tile 逐出/复用优先级"决策点，应同样把资源占用合法性留在基线算法里。
2. **规则的护栏价值**：`MaxEvictionCount`（防对抗模型死循环）、`MustFindEviction`（不可 spill 时强制给出答案）、NaN assert + 饱和转换（PriorityAdvisor）都是"ML 输出不可信"的防御工事——昇腾侧同样需要为 tile 决策模型设置调用次数熔断与必须成功的强约束路径。
3. **训练数据免费收集**：`-regalloc-training-log` 挂在生产编译器上，每次正常编译产出一条决策轨迹（特征+决策+reward）。PyPTO 若在 tile 分配器中埋同样的日志点，CANN 业务编译即可积累 corpus，无需专用训练环境。
4. **两个正交决策点的启示**：顺序（谁先分）与逐出（踢谁）分开建模，各自可独立 ML 化、独立回退。tile 分配的"tile 排序"与"冲突逐出"同样是两个可分离插桩点。
（以上为架构级推理，未在昇腾环境验证，标"待验证"。）

---

## 引用清单（全部本会话实测核对）

| 锚点 | 内容 |
|---|---|
| RegAllocGreedy.cpp:319-326 | StageName[] 六阶段 |
| RegAllocGreedy.cpp:370-411 | LRE_CanErase/WillShrink/DidClone 委托实现 |
| RegAllocGreedy.cpp:418-437 | enqueue + PriorityAdvisor 入口① |
| RegAllocGreedy.cpp:439-509 | DefaultPriorityAdvisor::getPriority（位图公式） |
| RegAllocGreedy.cpp:511-515 | DummyPriorityAdvisor |
| RegAllocGreedy.cpp:532-584 | tryAssign（hint/代价路径） |
| RegAllocGreedy.cpp:617-656 | evictInterference + Cascade 防环 |
| RegAllocGreedy.cpp:718-731 | tryEvict → 顾问入口② |
| RegAllocGreedy.cpp:1058-1123 | splitAroundRegion（块角色分派） |
| RegAllocGreedy.cpp:1209/1337/1379/1472/1594/1747 | tryRegionSplit/doRegionSplit/trySplitAroundHintReg/tryBlockSplit/tryInstructionSplit/tryLocalSplit |
| RegAllocGreedy.cpp:1978-2013 | trySplit 三层瀑布 |
| RegAllocGreedy.cpp:2048-2100 | mayRecolorAllInterferences |
| RegAllocGreedy.cpp:2331-2355 | selectOrSplit + CO_Depth/CO_Interf |
| RegAllocGreedy.cpp:2359-2419 | calcSpillCost / tryAssignCSRFirstTime |
| RegAllocGreedy.cpp:2658-2758 | selectOrSplitImpl 八步瀑布 |
| RegAllocBase.cpp:75/88-151/199-214 | 主循环 + enqueue |
| RegAllocEvictionAdvisor.cpp:30-55 | 开关 + EvictInterferenceCutoff |
| RegAllocEvictionAdvisor.cpp:197-233 | isUrgentEviction / shouldEvict |
| RegAllocEvictionAdvisor.cpp:255-335 | canEvictInterferenceBasedOnCost |
| RegAllocEvictionAdvisor.cpp:337-373 | tryFindEvictionCandidate（MaxWeight 初始化） |
| RegAllocGreedy.cpp:590-712 | 顾问基类共享工具 canReassign/getOrderLimit/canAllocatePhysReg/isUnusedCalleeSavedReg（类成员定义处） |
| MLRegAllocEvictAdvisor.cpp:201-262 | RA_EVICT_FEATURES_LIST 21 特征 + DecisionSpec |
| MLRegAllocEvictAdvisor.cpp:650-725 | loadInterferenceFeatures（合法性复用） |
| MLRegAllocEvictAdvisor.cpp:727-838 | tryFindEvictionCandidate（归一化/MustFind/不踢出口） |
| MLRegAllocEvictAdvisor.cpp:841-983 | getLIFeatureComponents / extractFeatures |
| RegAllocPriorityAdvisor.cpp:23-36 | -regalloc-enable-priority-advisor 四值 |
| MLRegAllocPriorityAdvisor.cpp:337-359 | convertAdviceToPriority / getPriorityImpl（3 特征） |
| MLRegAllocPriorityAdvisor.cpp:368-407 | DevelopmentMode 日志回退 |
| InlineSpiller.cpp:389-416 | collectRegsToSpill |
| InlineSpiller.cpp:622-657 | canGuaranteeAssignmentAfterRemat |
| InlineSpiller.cpp:834-929 | reMaterializeAll（选择①） |
| InlineSpiller.cpp:936-963 | coalesceStackAccess（选择②） |
| InlineSpiller.cpp:1247/1277/1315 | insertReload/insertSpill/spillAroundUses（选择③） |
| InlineSpiller.cpp:1411-1486 | spillAll / spill 三选一瀑布 |
| InlineSpiller.cpp:1812 | hoistAllSpills |
| SplitKit.cpp:690-868 | openIntv/enterIntv/useIntv/leaveIntv/overlapIntv 原语 |
| SplitKit.cpp:1545-1600 | finish（SpillMode/transferValues/rewriteAssigned） |
| SplitKit.cpp:1630-1663 | shouldSplitSingleBlock / splitSingleBlock |
| SplitKit.cpp:1676/1778/1871 | splitLiveThroughBlock/splitRegInBlock/splitRegOutBlock |
| LiveRangeEdit.h:42-73/121-129 | Delegate 协议（LRE_* 四回调） |
| LiveIntervals.cpp:1081/1677 | HMEditor / repairOldRegInRange |
| Spiller.h（全文 68 行） | Spiller 接口 + createInlineSpiller |
| commit cdd9077f3aa1 | Kill off the trivial spiller（多实现终结） |
| MLRegAlloc/dev-mode-logging.ll:5-25 | 训练工具链 RUN 行 |
| MLRegAlloc/Inputs/ | input.ll / two-large-fcts.ll / interactive_main.py / 参考日志 |

未决项（待验证标记）：
- §V 动态验证两条（本文件 §V 占位）
- Spiller.cpp 剩余内容未逐行读（仅确认 anchor 迁移至 InlineSpiller.cpp:237-239）
- AMDGPU sgpr_stress3.ll 复用性未复查（AMDGPU-notes/05 已有 ra_log.txt 先例）
