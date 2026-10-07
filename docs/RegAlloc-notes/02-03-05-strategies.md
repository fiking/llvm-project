# RA 策略层深度分析 — LiveRegMatrix / VirtRegMap / Fast / Basic / PBQP（§4+§5+§7 素材）

日期：2026-09-30
基准：llvm-project main @ `3eda2aebadd4`（build-debug llc 实测）
前置：00-baseline.md（文件行数基线）、AMDGPU-notes/05（三段式变体，勿混淆）、NVPTX-notes/03（空 RA 变体）
本文定位：**通用策略本体**——四个 allocator 与干涉表示如何协作，不含 target 变体展开。

---

## §4 干涉表示与映射基座

### 4.1 LiveRegMatrix（384 行）——"无显式干涉图"设计

**静态分析（llvm/lib/CodeGen/LiveRegMatrix.cpp / include/llvm/CodeGen/LiveRegMatrix.h）**

- 数据结构：`Matrix` 是 `LiveIntervalUnion::Array`，**每个 register unit 一个 LiveIntervalUnion**（LiveRegMatrix.h:50-52）："The matrix is represented as a LiveIntervalUnion per register unit"（LiveRegMatrix.h:16-19）。即矩阵的两个维度是 **SlotIndex（时间）× RegUnit（空间）**，行是已分配 vreg 的 LiveInterval 在该 unit 上的段并集。
- `init()`（LiveRegMatrix.cpp:62-75）：按 `TRI->getNumRegUnits()` 分配 Matrix 和 per-unit 缓存 `Queries`（:68-71），并 `invalidateVirtRegs()` 防陈旧查询（:73-74）。
- **三态查询 `checkInterference(VirtReg, PhysReg)`**（LiveRegMatrix.cpp:202-225），按代价升序：
  1. `IK_RegMask`（最快）：regmask 位向量测试——`checkRegMaskInterference`（:162-179）。注意其粒度**细于 regunit**：`Regmask interference is more fine grained than regunits. For example, a Win64 call can clobber %ymm8 yet preserve %xmm8`（:174-176）。缓存：`RegMaskVirtReg`/`RegMaskTag`/`RegMaskUsable`（头文件 :57-60），同一 vreg 的多 PhysReg 查询复用一个 BitVector。
  2. `IK_RegUnit`（固定干涉）：与 `LIS->getRegUnit(Unit)` 的固定范围 overlap（:181-193，用 `CoalescerPair` 处理 subreg 组合）。
  3. `IK_VirtReg`：真正的矩阵查询——对 PhysReg 的每个 unit `query(LR, Unit).checkInterference()`（:216-220）。`query()`（:195-200）把 `(UserTag, LR, Matrix[Unit])` 灌进 per-unit Query 缓存，`UserTag` 由 `invalidateVirtRegs()` ++（头文件 :82），供 `Query::init` 判 stale。
- **与显式图的核心取舍**：分配器是**迭代式**的——Greedy 每轮 unassign/assign、split 产生新 interval，图结构（邻接表）在这些变更下必须重构或维护双向指针；而矩阵只做 `unify(VirtReg, Range)` / `extract(VirtReg, Range)`（assign/unassign 内部，:119-124 / :137-148），是把 LiveInterval 段插入/移出 IntervalMap 的 O(log n) 操作。查询侧 `LiveIntervalUnion::Query` 缓存了上次扫描位置（"cached queries per register unit"，头文件 :54-55），同一 vreg 对多个 PhysReg 的连续查询可复用。RegAllocBase.h:30-37 的设计注释一锤定音："If virtual and physical register liveness is modeled using intervals, then on-the-fly interference checking is cheap. Furthermore, interferences can be lazily cached and reused."（lib/CodeGen/RegAllocBase.h:30-33）
- **assign/unassign 的双向维护**（LiveRegMatrix.cpp:113-152）：
  - `assign`：先 `VRM->assignVirt2Phys`（vreg→preg 方向），再 `foreachUnit` 对 PhysReg 的每个 unit `Matrix[Unit].unify(VirtReg, Range)`（unit→segments 方向）。assert 双保险：`!VRM->hasPhys` 防重复分配（:116）。
  - `unassign`：先读 `VRM->getPhys`，`VRM->clearVirt`，再 `Matrix[Unit].extract(VirtReg, Range)`。`ClearAllReferencingSegments` 模式（:144-147）用于 interval 已清空后清残留（split 场景）。
  - `foreachUnit`（:88-111）处理 **subreg lane**：若 VirtReg 有 SubRanges，用 `MCRegUnitMaskIterator` 只把 lane 匹配的 SubRange 段 unify 进对应 unit（:92-103）；无 SubRanges 则整段进所有 unit（:104-109）。
- **与 TargetRegisterInfo 的交互**：矩阵本身不计算 allocatable 集合——它只按 unit 存段。PhysReg 可用性的过滤发生在分配器侧的 `RegisterClassInfo`（`getOrder()` 返回的 allocation order 已剔除 reserved；见 RegAllocFast.cpp:1907 `RegClassInfo.runOnMachineFunction(MF)`、RegAllocBasic.cpp:177 `AllocationOrder::create(..., RegClassInfo, Matrix)`）。矩阵只保证"已经 assign 进去的 vreg 不与后来者冲突"。`isPhysRegUsed`（LiveRegMatrix.cpp:154-160）遍历 PhysReg 的 units 判空。
- Debug 校验 `isValid()`（:302-372，NDEBUG 外）：正反向两个方向检查（Matrix 中每个 LI 指针必须存在于 LiveIntervals；VRM 里每个已分配 vreg 的首段必须出现在其 PhysReg 的某个 unit 的 union 里）。`postOptimization` 每次调（RegAllocBase.cpp:161）。
- 细节坑：两个**栈上 LR** 的重载 `checkInterference(Start, End, PhysReg)`（:227-255）和 `checkInterferenceLanes`（:257-290）**故意不缓存**查询——栈地址可能复用导致 Query 缓存 key 冲突，源码有大段注释+FIXME（:236-248）。

**设计动机**：RA 本质是"反复猜测-回滚"的过程（Greedy 的 evict 循环、Fast 无此概念、Basic 的 spill-then-retry）。干涉图方案的写路径（加/删边）与查询路径（邻接判重）都要维护图不变量；矩阵方案把"图"压缩成 per-unit 的时间轴并集，写=IntervalMap 插删、读=双游标扫描（LiveIntervalUnion 的 SegmentIter），两边都是对数级。且 regmask 这种"非对称干涉"（call clobber）在图模型里难以表达，在矩阵里只是查询时多一个位向量测试。**这个设计的代价**是：无法做图着色式的全局推理（无 cliques、无度数信息直接可用），这正是 PBQP 走了另一条路的原因（见 §5.3）。

### 4.2 VirtRegMap（799 行）——vreg→preg 主映射 + rewriter 基座

**静态分析（llvm/lib/CodeGen/VirtRegMap.cpp / include/llvm/CodeGen/VirtRegMap.h）**

- 四张表（VirtRegMap.h:41-60）：
  - `Virt2PhysMap`（IndexedMap<MCRegister>）：主映射。**注意：spilled vreg 也有条目**——"even spilled virtual registers (the register mapped to a spilled register is the temporary used to load it from the stack)"（:41-45）。这不是 bug：spill 后 InlineSpiller 会把 reload 点的临时占用也反映进 VRM，rewriter 需要知道"这个 vreg 在这条指令处被替换成哪个 preg"。
  - `Virt2StackSlotMap`：vreg→spill 槽（:48-52）。
  - `Virt2SplitMap`：vreg→其 split 来源（`setIsSplitFromReg`/`getPreSplitReg`/`getOriginal`，:139-158）——`getOriginal` 沿链回溯，幂等（:155-158）。
  - `Virt2ShapeMap`：X86 AMX 形状（:58-60，target 特例）。
- `assignVirt2Phys`（VirtRegMap.cpp:99-107）带两道 assert：虚拟/物理类型 + **不允许映射到 reserved physreg**（:104-105）。
- **关于任务书中的 "getVirt2PhysAssignment"**：当前 main **不存在**该函数（`grep -rn getVirt2PhysAssignment` 全库无命中；`git log -S` 亦无历史记录）——任务锚点有误，已核实。真实的消费路径是：
  - 分配器主循环 `RegAllocBase::allocatePhysRegs` → `Matrix->assign` → `VRM->assignVirt2Phys`（LiveRegMatrix.cpp:117）。
  - 反向查询消费方：`LiveRegMatrix::unassign` 读 `VRM->getPhys`（:132）；`VirtRegRewriter::rewrite` 对每个 vreg 操作数读 `VRM->getPhys(VirtReg)` 后改写（VirtRegMap.cpp:672）；`RABasic::LRE_CanEraseVirtReg`/`LRE_WillShrinkVirtReg` 用 `VRM->hasPhys` 判断是否 unassign+requeue（RegAllocBasic.cpp:64,78）。
- **subreg lane 的"替代"机制（substitution）**：VirtRegMap **没有**独立的 substitute 表——替代发生在 rewriter 阶段：`MO.setSubReg(0)` 前 `PhysReg = TRI->getSubReg(PhysReg, SubReg)`（VirtRegMap.cpp:747-749）。即 **VRM 永远存整寄存器号**，操作数级的 subreg→子物理寄存器换算推迟到 rewrite。这是刻意的：分配期间 subreg 语义由 LiveInterval 的 SubRanges/lanes 表达（矩阵的 foreachUnit 已按 lane 分流），只在最终改写时物化。`readsUndefSubreg`（:468-490）和 `liveOutUndefPhiLanesForUndefSubregDef`（:623-652）处理 undef lane 的边界情形。
- **VirtRegRewriter（pass 时机）**：头文件注释（:207-210）："The VirtRegRewriter is the last of the register allocator passes. It rewrites virtual registers to physical registers as specified in the VirtRegMap analysis." 具体动作序列（`VirtRegRewriter::run`，:343-376）：
  1. `LIS->addKillFlags(VRM)`——趁还有 vreg 补 kill 标志；
  2. `addMBBLiveIns()`——从 vreg 区间**重建 MBB live-in**（physreg 世界需要，:424-463；subrange 版 :378-420）；
  3. `rewrite()`——两重循环改写所有 vreg 操作数（:654-788），含 subreg→getSubReg、super-def/kill/dead 的隐式操作数补齐（:683-766）、`handleIdentityCopy` 删同义 COPY（:492-523）、`expandCopyBundle` 拆 copy bundle（:529-592）；
  4. `ClearVirtRegs=true` 时：`DebugVars->emitDebugValues`、`VRM->clearAllVirt()`、`MRI->clearVirtRegs()`（:362-373）——**vreg 世界终结**，MachineFunctionProperties setNoVRegs（头文件 :253-257）。
  - pass 属性：`ClearVirtRegs` 可参数化（`virt-reg-rewriter<no-clear-vregs>`，printPipeline :790-795）——AM
DGPU 用它做"分段 RA 后不立即清 vreg"的多轮 rewriter 编排（-sgpr/-vgpr 分配后 rewrite 一轮、最后统一 clear；见 AMDGPU-notes/05 的三段式）。
- 溢出物化侧：`createSpillSlot`（:109-122）按 RC 的 spill size/align 找 MFI 栈对象；`assignVirt2StackSlot` 两变体（:142-158）。
- 统计：`NumSpillSlots`/`NumIdCopies`（:53-54）。

**设计动机**：VRM 是"**决策与物化分离**"的枢纽——所有 allocator（含 PBQP）只写决策（vreg→preg / vreg→slot），物化（指令改写、隐式操作数、live-in 重建、debug 值跟踪）统一交给 rewriter。这使 spill 插入（InlineSpiller 在分配期间插入 spill/reload 指令、改 interval）与寄存器替换（rewriter 最后一次性扫描）解耦。rewriter 放在最后还因为：spill 代码本身也产生 vreg 占用（临时寄存器），必须等所有分配轮次结束再统一物化。

---

## §5 策略层三 allocator（Fast / Basic / PBQP）+ 共享基座

### 5.0 共享驱动：RegAllocBase（258 行）

**静态分析（llvm/lib/CodeGen/RegAllocBase.cpp + lib/CodeGen/RegAllocBase.h）**

- 设计宣言（RegAllocBase.h:19-37）：两条原则——"(1) If virtual and physical register liveness is modeled using intervals, then on-the-fly interference checking is cheap... (2) Register allocation complexity, and generated code performance is determined by the effectiveness of live range splitting rather than optimal coloring."
- 主循环 `allocatePhysRegs()`（RegAllocBase.cpp:88-155）：
  ```
  seedLiveRegs()（全部 vreg 入队 :75-84）
  while ((VirtReg = dequeue())):            // 子类定义优先级
    Matrix->invalidateVirtRegs()             // :104 —— 关键：每轮作废缓存
    PhysReg = selectOrSplit(VirtReg, SplitVRegs)  // 子类核心策略
    if (PhysReg == ~0u) getErrorAssignment + cleanupFailedVReg  // inline asm 溢出
    else if (PhysReg) Matrix->assign(...)
    for (Reg : SplitVRegs) enqueue(...)       // split 产物回炉
  ```
  `invalidateVirtRegs()` 每轮必调（:104）——split/spill 会改 interval，缓存的查询结果全部作废，**这是"增量查询便宜"成立的前提**（缓存只在一轮 selectOrSplit 内有效）。
- 子类契约（头文件 :91-101）：`enqueueImpl/dequeue`（排序策略）+ `selectOrSplit`（分配策略）+ `spiller()`。RABasic/RAGreedy 继承此驱动；**RegAllocFast 与 PBQP 不继承**（Fast 是块局部无 interval 基座；PBQP 是全局求解，见 §5.3）。
- 失败处理 `cleanupFailedVReg`（:170-197）：直接 `MRI->replaceRegWith` 物化，绕过矩阵——"This avoids trying to manage illegal overlapping assignments in LiveRegMatrix"（:192-194）。

### 5.1 RegAllocFast（1971 行）——块序线性扫描（-O0 默认）

**静态分析（llvm/lib/CodeGen/RegAllocFast.cpp）**

- 文件头设计声明（:9-18）："A block-local register allocator. No virtual register stays in a register across a block boundary. A value live across one gets a stack slot: spilled after its def and reloaded above its uses in each block... There is no dataflow liveness analysis, only a bounded scan of def and use lists, and no live range splitting, interference graph or coalescer, only a copy hint plus removal of COPYs that end up identity or dead. **Each block is walked backwards**: a use is the first reference reached and acquires a register, a def is the last and releases one."
- **为什么块序（block-local）**：见上——不做数据流活跃性分析，用 `mayLiveOut/mayLiveIn` 的**有界扫描**（`Limit = 8` 次 def/use 迭代，:567,596）+ `MayLiveAcrossBlocks` BitVector 缓存（:237,539）近似。超限即保守判"跨块"→spill。跨块值的代价：def 后 spill、每个使用块 reload（`reloadAtBegin`，:711-747）。这保证单块复杂度与"指令数 × 寄存器数"成线性关系，无全局数据结构需维护。
- **"立即 spill 不留干涉"与 O(n) 的来源**：核心是 `RegUnitStates`（`std::vector<unsigned>` 按 MCRegUnit 索引，:258）——每个 unit 的状态只有 4 态（`regFree`/`regPreAssigned`/`regLiveIn`/vreg 编号，:241-255）。分配/释放是 O(units(PhysReg)) 数组写（`setPhysRegState` :471-474）。发生冲突时 `displacePhysReg`（:774-803）：**就地 reload 占用者到它自己的栈槽**（`reload(ReloadBefore, VirtReg, LRI->PhysReg)` :786——注意 reload 插在 MI **之后**，因为倒序遍历中"之后"= 程序序更晚，占用者的下个使用点能重新 load），然后释放。**没有"先记下来待会处理"的延迟队列**——被驱逐者立即物化成内存往返，干涉当场消解，不产生后续连锁。这把整个函数的分配化约为单遍逆序扫描：每条指令 O(ops × units) 状态更新 + 冲突时 O(1) 次栈往返，无迭代不动点。
- **倒序遍历（backwards walk）**：`allocateBasicBlock`（:1837-1896）中 `for (MachineInstr &MI : reverse(MBB))`（:1851）。动机：**use 先于 def 被遇到**（倒序），所以 use 立即获得寄存器（"a use is the first reference reached and acquires a register"），def 到达时寄存器即将释放（"a def is the last and releases one"）。正序则相反：def 先占坑，未来 use 未知，无法做"最后一次使用即释放"的精简。
- **physreg 优先级与提示**：`allocVirtReg`（:943-1025）四层：
  1. 显式 hint（Hint0，来自 COPY 目的端等，:954-968）；
  2. `traceCopies`（Hint1）——沿 COPY 链最多 3 跳找可 coalesce 的 physreg（`traceCopyChain` ChainLengthLimit=3，:904-920；`traceCopies` DefLimit=3，:925-940）；
  3. 遍历 AllocationOrder 找 `calcSpillCost==0` 的（:991-1004）；
  4. 否则取 `calcSpillCost` 最小者（含 hint 减免 `spillPrefBonus=20`，:1006-1012）并 displace。
  - `calcSpillCost`（:832-849）：`regPreAssigned`（保留寄存器/物理操作数/live-out）→ `spillImpossible`；vreg 且已有栈槽或 LiveOut（sure spill）→ `spillClean=50`；否则 `spillDirty=100`。**保留寄存器避让**由此实现：reserved 不进入 RegClassInfo 的 allocation order（`MRI->freezeReservedRegs()` :1906 先行冻结），物理操作数走 `regPreAssigned` 状态在指令内占据。
- **质量损失机制**：无 split、无 evict。溢出后连锁：跨块值被 spill→reload 链每块重复；`mayLiveOut` 的 Limit=8 有界扫描在 def/use 多于 8 处时**保守判跨块**（:566-574），把本可块内的值也发配到栈上。调试值处理（`handleDebugValue`/DanglingDbgValues，:1773-1813）补 -O0 场景的调试体验。
- 错误路径 `getErrorAssignment`（:1250-1292）：inline asm 造成的 class 耗尽→诊断+继续（`FailedRegAlloc` 属性，:1256-1258）。
- NPM 版 `RegAllocFastPass::printPipeline`（:1947-1964）：支持 `filter=` 与 `no-clear-vregs` 参数（AMDGPU 分段 RA 用）。

### 5.2 RegAllocBasic（256 行）——Greedy 的退化基线

**静态分析（llvm/lib/CodeGen/RegAllocBasic.cpp）**

- **与 Greedy 共享的部分**：RegAllocBase 驱动（enqueue/dequeue 的优先队列实现、allocatePhysRegs 主循环、postOptimization）+ InlineSpiller（`createInlineSpiller`，:237-238）+ VirtRegAuxInfo 权重计算（:232-235）。256 行里没有一行分配算法框架——全部是 selectOrSplit 和 LiveRangeEdit 回调的简化实现。
- **selectOrSplit 简化版**（:170-218）：注释自述复杂度（:164-169）："selectOrSplit can only be called once per live virtual register. We then do a single interference test for each register the correct class until we find an available register. So, the number of interference tests in the worst case is |vregs| * |machineregs|. And since the number of interference tests is minimal, **there is no value in caching them** outside the scope of selectOrSplit()."
  1. 遍历 AllocationOrder 找 `IK_Free` → 立即返回（"first fit"）；
  2. 收集 `IK_VirtReg` 候选，`spillInterferences`（:121-156）：若 PhysReg 上所有干涉者 spill 权重都低于当前 VirtReg（`!Intf->isSpillable() || Intf->weight() > VirtReg.weight()` → 放弃，:132-133），则 unassign 它们并 spill，腾出寄存器；
  3. 都不行 → spill 自己。
- **"Greedy 的退化"精确对比**：Basic 的 spillInterferences 是**一次性**的（spill 完就完，无 requeue 冲突连锁处理）；Greedy 的同名能力升级为 evict chain + region splitting + hint-based reassign（3008 行 vs 256 行的差异全在这）。Basic **没有 split**——`selectOrSplit` 返回的 SplitVRegs 只由 spiller 产生（InlineSpiller 的 spill 会做轻量 split，LiveRangeEdit 生成新 vreg），策略层不主动分裂。没有二次尝试：被 spill 者不会像 Greedy 那样以新 interval 重新入队后享受 evict 决策。
- **存在的意义**：RegAllocBasic.cpp:161-162 注释直说："This is a minimal implementation of register assignment and splitting that spills whenever we run out of registers." 它是 (a) LiveIntervalUnion 框架的最小可工作样例（教学/基线）；(b) Greedy 退化时定位性能问题的对照组；(c) ML advisor 的对照组（test/CodeGen/MLRegAlloc 测试常配 basic）。
- **NPM 现状（重要考古事实）**：`-regalloc-npm=basic/pbqp` 会**静默落入 Greedy**（实验证据见 §6.4）——`CodeGenPassBuilder.cpp`（lib/Passes/）`addRegAllocPass` 的 switch 只处理 Fast/Greedy，其余 `reportFatalUsageError("register allocator not supported yet")`（lib/Passes/CodeGenPassBuilder.cpp:800-819）。但 llc 默认 legacy PM（tools/llc/lib/llcdriver.cpp:743-753 的选择逻辑：无 -passes 时走 legacy），legacy 的 `-regalloc=basic` 经 MachinePassRegistry（TargetPassConfig.cpp:1120-1127）仍可达。**这本身就是"basic/pbqp 近乎弃置"的直接证据**：新 PM 移植时未给 basic/pbqp 建平替 pass。
- AMDGPU 干脆显式拒绝：`checkRegAllocSupported`——"Only Fast and Greedy are supported; Basic and PBQP are not"（lib/Target/AMDGPU/AMDGPUTargetMachine.cpp:289-299），报错文案 "unsupported register allocator 'basic'/'pbqp'"（:295）。AMDGPU 2026-02 提交 a03f82d7e582 引入该检查。

### 5.3 RegAllocPBQP（961 行）——图着色考古层

**静态分析（llvm/lib/CodeGen/RegAllocPBQP.cpp + include/llvm/CodeGen/RegAllocPBQP.h + include/llvm/CodeGen/PBQP/ReductionRules.h）**

- **图着色形式化**：RA 问题映射为 PBQP（Partitioned Boolean Quadratic Programming）：
  - **节点** = vreg（`initializeGraph`，RegAllocPBQP.cpp:592-690）；**选项集** = [spill] ++ allowed preg（allowed 集合经三重过滤：reserved 剔除、regmask overlap 剔除、fixed regunit overlap 剔除，:626-650）。
  - **cost vector**（节点成本）：`NodeCosts` 长度 = |allowed|+1，index 0 = spill 选项。spill 成本 = interval weight + MinSpillCost=10.0 下限（SpillCosts constraint，:182-203）；callee-saved 加 1.0 罚（:680-682，理由注释 :678-679 "using then force spilling and restoring... in the prologue/epilogue"）。
  - **依赖边（矩阵）**：干涉边 `M[i+1][j+1] = infinity`（若 allowed_i 与 allowed_j overlap，`TRI.regsOverlap`，:404-415）——硬约束进矩阵、软偏好也进矩阵：**coalescing**（`PBQPCoalescing` 默认 **false**，:97-100）在矩阵对角格减 benefit（`addVirtRegCoalesce` :494-509）。**这是矩阵式"软硬约束统一"的漂亮表达**：图着色只能表达"不能同色"，PBQP 的 cost matrix 可同时编码"同色更优"（负 cost）与"禁止同色"（inf）。
  - **求解（RF 简约）**：`PBQP::RegAlloc::solve(G)`（:877）→ `RegAllocSolverImpl::solve()`（RegAllocPBQP.h:292-298）：`setup(); S = backpropagate(G, reduce());`。`reduce()` 反复应用 **R1（度 1 节点：cost 向量沿边 min 聚合进邻居，ReductionRules.h:30-73）与 R2（度 2 节点：两条边合成新边，Delta 矩阵，:74-131）** 直到只剩 RN（度 ≥3 的"黑箱"），对黑箱用启发式（solver 里的 heuristic 独立求解），再 backpropagate 反推各节点选择。这正是 Hames & Scholz 2006（文件头 :20-22 引用）的 RF(Reduction-Foldback) 求解框架。
  - **干涉图构建本身借用线性扫描**（:296-380）："The following is loosely based on the linear scan algorithm introduced in 'Linear Scan Register Allocation' by Pooteto and Sarkar. This version isn't linear, because the size of the active set isn't bound by the number of registers, but rather the size of the largest clique in the graph."（:297-301）——按 start 排序扫描、active 集合按 end 排序退休，active 中两两加边。**讽刺的细节**：连 PBQP 都不建"显式干涉图"存下来——它只为建边扫描一遍，解完即弃。
- **迭代外环**（:852-880）：求解 → `mapPBQPToRegAlloc`（:718-755）若有 spill 选项被选 → spillVReg → 新 interval → 下一轮。`VRM.clearAllVirt()` 每轮清空重来（:731）。
- **target 挂钩**：`Subtarget.getCustomPBQPConstraints()`（:850）——AArch64 有 `A57ChainingConstraint`（Cortex-A57 FP/SIMD 双发射链，balanceFPOps() 时启用，AArch64Subtarget.cpp:581-584；实现 AArch64PBQPRegAlloc.cpp，CMake 链接 lib/Target/AArch64/CMakeLists.txt:81）。
- **git 考古（谁在用）**：
  - 241 个 commit 触及 RegAllocPBQP.cpp；2024 年后几乎全是 NPM 移植/NFC/formatting（`git log --pretty` 实测列表）。最近的"功能性"提交：
    - `a4f8918d699b` 2026-09-02 "Initialize PBQP Pass for Clang"（#217954）——修复 PBQP 在 clang 里不可用（initializePasses 漏了）。**这佐证"近乎弃置"**：4 年没人发现 pass 没注册也能活着。
    - `a03f82d7e582` 2026-02-04 AMDGPU 显式拒绝 basic/pbqp（#178889）。
  - **默认配置 grep**：全 target 源码 grep `pbqp|PBQP` 只命中 AArch64（自定义约束，非默认 allocator）与 AMDGPU（拒绝检查）。**没有任何 target 把 PBQP 设为默认**。legacy `-regalloc=pbqp` 是唯一入口（llc 实测可用，§6）。
  - 学术出处（文件头 :16-27）：Hames & Scholz 2006 JMLC、Scholz & Eckstein 2002 LCTES——"Nearly optimal register allocation with PBQP"。
- **为何近乎弃置（证据链）**：
  1. **编译时间**：干涉边构建 O(活跃区间 × clique) + 矩阵池化（IMatrixCache :307）+ R1/R2 简约的矩阵运算，每轮 spill 后全量重建图（外环 `while (!PBQPAllocComplete)` :855）。对比 Greedy 的增量矩阵查询（§4.1），PBQP 是"批量求解"哲学。
  2. **工程复杂度**：solver 状态与图修改挂钩（handleAddEdge/handleDisconnectEdge 的 metadata promote，RegAllocPBQP.h:305-330）；矩阵内存 = Σ(|allowed_i|+1)×(|allowed_j|+1)，虽有 CostAllocator 池化去重（相同 allowed 集合对共享矩阵，IMatrixCache），AMDGPU 这类寄存器文件巨大的 target 直接不可行。
  3. **收益存疑**：Hames & Scholz 论文场景是**不规则架构**（LCTES'02 标题即 "Register allocation for irregular architectures"）——寄存器类别交叠复杂、寄存器少。主流 target（AArch64/X86 31/16 个通用寄存器 + 规则类别）上，Greedy 的 split+evict 启发式已把质量做到"够好"，PBQP 的理论最优性（RF 简约后仍有启发式黑箱）无法兑现为实测收益。
  4. **生态断供**：NPM 移植没带上它（§5.2 的 addRegAllocPass 证据）；clang 路径 2026-09 才修（a4f8918d699b）。
- **PBQP 的 AArch64 专用约束文件**：AArch64PBQPRegAlloc.cpp（A57ChainingConstraint，优化 A57 的 FP/SIMD 指令链式调度）——这是"PBQP 扩展点"唯一存活的 target 代码。

### 5.4 策略选择机制（谁在什么时候选谁）

- legacy PM（llc 默认路径）：`TargetPassConfig::addRegAssignAndRewriteOptimized`（TargetPassConfig.cpp:1456+）→ `createRegAllocPass(Optimized)`（:1427-1440）→ `-regalloc=` 显式指定（MachinePassRegistry，:1120-1127）> target override（`createTargetRegisterAllocator` :1414-1421，Optimized→Greedy，else Fast）。
- NPM（clang / -passes 路径）：`CodeGenPassBuilder::addRegAllocPass`（lib/Passes/CodeGenPassBuilder.cpp:798-819）——`-regalloc-npm=` 只有 fast/greedy 实现，basic/pbqp **fatal**；default 走 `addTargetRegisterAllocator`（:786-792，Optimized→RAGreedyPass，else RegAllocFastPass）。
- **-O0 选 Fast 的理由**（设计动机）：编译速度线性 + 无需 LiveIntervals/Coalescer 等重分析（Fast 的 `getAnalysisUsage` 只要 setPreservesCFG，RegAllocFast.cpp:426-429；对比 Basic/Greedy 需要 SlotIndexes+LiveIntervals+Coalescer+MachineScheduler+LiveStacks+DomTree+LoopInfo+MBFI+PSI 一大串，RegAllocBasic.cpp:45-59）。**实测编译时间对比见 §6.3**。

---

## §6 动态验证（build-debug llc，AArch64 host）

### 6.1 压力用例

同 AMDGPU sgpr_stress3 精神（远超寄存器数的并发活值），构造 AArch64 版：16 个并发 i32 活值 + 每个多次使用 + 跨 if 块（制造跨块与 call 压力），迫使三个策略都溢出。用例文件：`scratch/stress_aarch64.ll`（本文同目录）。

```llvm
; 16 个并发值，a0..a15 各用 3 次，跨 3 个基本块（2 个 call 制造 regmask 压力）
```

### 6.2 四策略对比表（-O0；spill = 相对 sp 的 STR+LDR 数；实测）

| 策略 | spill | STR/LDR | GPR 数 | 指令数 | -O2 spill |
|---|---|---|---|---|---|
| fast | 65 | 28/37 | 20 | 116 | 20 |
| basic | 22 | 5/17 | 27 | 88 | 19 |
| greedy | 20 | 6/14 | 29 | 89 | 10 |
| pbqp | 18 | 5/13 | 28 | 85 | 12 |

解读：-O0 下 fast 的 spill 是 greedy 的 3.25 倍（无分裂无 evict 的连锁代价）；pbqp 质量最优但见 6.3 的时间代价；-O2 时 greedy 反超 pbqp。

### 6.3 编译时间对比（50 函数用例，-time-passes 的 pass 本身耗时；实测）

**Fast 16.5ms / Basic 45.0ms / Greedy 222.0ms / PBQP 709.7ms**（PBQP 占总编译时长 75.1%）
wall time：-O0 fast 270.5ms vs greedy 587.0ms——Greedy 在 -O0 额外拉起 LiveIntervals(13.5ms)+Coalescer(5.0ms)+SlotIndexes(1.4ms) 依赖链（fast 全免）。

### 6.4 MIR dump 注意事项（实测）

四 pass 名实证：regallocfast/regallocbasic/greedy/regallocpbqp（-print-after-all 可见）。**坑**：`-regalloc-npm=basic/pbqp` 在 llc（默认 legacy PM）下**静默忽略**（该选项仅 NewPMDriver 消费），落到默认 greedy 而非报错——实验须用 legacy `-regalloc=` 或核对 pass 名。

---

## §7 昇腾映射（推理级，全部"待验证"）

> PyPTO tile 分配 = "把计算 tile（数据块）映射到片上 buffer/L1/tile 寄存器"的资源分配问题，形态上与 RA 同构：tile ↔ vreg，物理 buffer 单元 ↔ physreg，tile 生存期（生产指令→消费指令）↔ live interval，buffer 容量约束 ↔ regclass。以下为推理级映射，均**待验证**。

- **[待验证] 四策略对 tile 分配的启示**：
  1. **Fast 的"块局部 + 立即物化"**：若 tile 调度的单位是 tile-level 的"阶段"（phase/stage，类比 MBB），则 Fast 模式 = "tile 不跨阶段存活，跨阶段的 tile 强制经 DDR/L2 中转"。这正是很多手写 Ascend pipeline 的朴素策略。其 O(阶段×buffer) 复杂度对 JIT 生成 kernel（动态 shape 场景）是**编译时间最优**的。代价同构：中转流量 = spill 流量。
  2. **Basic 的"first-fit + 权重驱逐"**：tile 生存期若能静态排序（生产顺序），Basic 模式 = 按 weight（使用频度/在关键路径上）排序后 first-fit，冲突时驱逐低权重者去 DDR。适合 tile 数中等、冲突不频繁的规则计算（MatMul 主循环）。
  3. **Greedy 的 split/evict**：tile 生命周期分裂 = 把一个 tile 的"驻留"切成多段，只在热区（compute 密集段）驻留 L1，冷段落 DDR。PyPTO 若做 tile 生命周期切分（producer-consumer 链上的复用窗口），对应 live range splitting 的思想。**待验证**：Ascend buffer 是否有"同一 tile 换入换出同一槽位"的硬件一致性语义（对应 spill slot 的唯一性）。
  4. **PBQP 的全局求解**：tile→buffer 若存在复杂互斥（UB/UB-pos 固定 bank、多 buffer 类别交叠），PBQP 的 cost matrix 可统一表达"bank 互斥（inf）+ 亲和复用（负 cost）"。但借鉴 §5.3 的教训：**仅当分配问题真的"不规则"且求解规模可控时才值得**，否则 Greedy 式启发式性价比更高。
- **[待验证] LiveRegMatrix 思想的移植**：tile 分配若也是迭代式（先粗分配、再局部调优），"查矩阵"优于"建图"——把 (时间槽, buffer 单元) 做成二维占用表，增量查询 O(log)。PyPTO 的 tile 时间轴若已有 SlotIndexes 类似的线性编址（tiling planner 的 schedule index），可直接复用该设计。
- **[待验证] VRM 的"决策/物化分离"**：PyPTO tile 分配的输出应是"tile→buffer 决策表 + 生成时的 rewrite 阶段"，而非边分配边改 IR。当前 PyPTO 若在 pass 里直接改 schedule，可借鉴 VRM 模式获得更清晰的分层。
- **[待验证] Fast 是否够用**：判定式——若 (a) tile 生存期大多不跨阶段、(b) 并发 tile 峰值 < buffer 容量、(c) 编译时间敏感（JIT），则 Fast 式线性扫描够用；否则需要 split。GPU 编译器实践（LLVM AMDGPU 的 greedy + tiling）表明 tile-heavy 负载的 split 收益显著，**但 Ascend 的 buffer 结构（UB 容量、bank 冲突规则）决定 split 粒度**，需实测。

---

## 引用清单（全部实际核对）

| 主题 | 文件:行号 | 核对方式 |
|---|---|---|
| 矩阵 = per-unit LiveIntervalUnion | llvm/include/llvm/CodeGen/LiveRegMatrix.h:50-52 | read_file |
| IK 三态枚举 | LiveRegMatrix.h:84-102 | read_file |
| regmask 粒度细于 regunit | LiveRegMatrix.cpp:174-176 | read_file |
| regmask 缓存 | LiveRegMatrix.cpp:162-179; LiveRegMatrix.h:57-60 | read_file |
| checkInterference 三步 | LiveRegMatrix.cpp:202-225 | read_file |
| assign/unassign 双向维护 | LiveRegMatrix.cpp:113-152 | read_file |
| foreachUnit subreg lane 分流 | LiveRegMatrix.cpp:88-111 | readFile |
| 栈 LR 不缓存的原因 | LiveRegMatrix.cpp:236-248 | read_file |
| isValid 双向校验 | LiveRegMatrix.cpp:302-372 | read_file |
| "on-the-fly interference checking is cheap" | lib/CodeGen/RegAllocBase.h:30-33 | read_file |
| VRM 四表 | include/llvm/CodeGen/VirtRegMap.h:41-60 | read_file |
| spilled vreg 也有 phys 映射 | VirtRegMap.h:41-45 | read_file |
| assignVirt2Phys reserved 拒绝 | VirtRegMap.cpp:99-107 | read_file |
| getVirt2PhysAssignment 不存在 | 全库 grep + git log -S 空 | terminal grep/git |
| subreg 替代 = rewriter 的 getSubReg | VirtRegMap.cpp:747-749 | read_file |
| rewriter 动作序列 | VirtRegMap.cpp:343-376 | read_file |
| rewriter "last of the RA passes" | VirtRegMap.h:207-210 | read_file |
| addMBBLiveIns 从 vreg 重建 | VirtRegMap.cpp:424-463 | read_file |
| handleIdentityCopy / expandCopyBundle | VirtRegMap.cpp:492-592 | read_file |
| no-clear-vregs 参数化 | VirtRegMap.cpp:790-795; VirtRegMap.h:241-258 | read_file |
| allocatePhysRegs 主循环 | lib/CodeGen/RegAllocBase.cpp:88-155 | read_file |
| invalidateVirtRegs 每轮必调 | RegAllocBase.cpp:104 | read_file |
| cleanupFailedVReg 绕过矩阵 | RegAllocBase.cpp:170-197 | read_file |
| Fast 块局部设计声明 | RegAllocFast.cpp:9-18 | read_file |
| RegUnitStates 四态 | RegAllocFast.cpp:241-258 | read_file |
| mayLiveOut/mayLiveIn Limit=8 | RegAllocFast.cpp:566-606 | read_file |
| displacePhysReg 就地 reload | RegAllocFast.cpp:774-803 | read_file |
| calcSpillCost 三档 | RegAllocFast.cpp:832-849 | read_file |
| allocVirtReg 四层优先级 | RegAllocFast.cpp:943-1025 | read_file |
| traceCopies 3 跳 | RegAllocFast.cpp:904-940 | read_file |
| 倒序遍历 | RegAllocFast.cpp:1851 | read_file |
| reloadAtBegin | RegAllocFast.cpp:711-747 | read_file |
| Fast 无重分析依赖 | RegAllocFast.cpp:426-429 | read_file |
| Basic "minimal implementation" | RegAllocBasic.cpp:161-169 | read_file |
| Basic selectOrSplit | RegAllocBasic.cpp:170-218 | read_file |
| Basic spillInterferences 权重门槛 | RegAllocBasic.cpp:121-156 | read_file |
| NPM addRegAllocPass 只支持 fast/greedy | lib/Passes/CodeGenPassBuilder.cpp:800-819 | read_file |
| NPM addTargetRegisterAllocator | lib/Passes/CodeGenPassBuilder.cpp:786-792 | read_file |
| llc 默认 legacy PM | tools/llc/lib/llcdriver.cpp:743-753 | read_file |
| legacy -regalloc= 注册 | lib/CodeGen/TargetPassConfig.cpp:1120-1127 | read_file |
| PBQP 文件头论文引用 | RegAllocPBQP.cpp:16-27 | read_file |
| PBQP spill 成本 MinSpillCost | RegAllocPBQP.cpp:182-203 | read_file |
| PBQP 干涉边 regsOverlap→inf | RegAllocPBQP.cpp:404-424 | read_file |
| PBQP coalescing 默认关 | RegAllocPBQP.cpp:97-100 | read_file |
| PBQP 干涉图借用线性扫描构建 | RegAllocPBQP.cpp:296-380（quote :297-301） | read_file |
| PBQP CSR +1.0 罚 | RegAllocPBQP.cpp:678-682 | read_file |
| PBQP 外环 spill→重求解 | RegAllocPBQP.cpp:855-880 | read_file |
| R1/R2 简约实现 | include/llvm/CodeGen/PBQP/ReductionRules.h:30-131 | read_file |
| RegAllocSolverImpl::solve | include/llvm/CodeGen/RegAllocPBQP.h:292-298 | read_file |
| A57ChainingConstraint | lib/Target/AArch64/AArch64Subtarget.cpp:581-584 | grep -B2 -A5 |
| AMDGPU 拒绝 basic/pbqp | lib/Target/AMDGPU/AMDGPUTargetMachine.cpp:289-299 | sed 实读 |
| AMDGPU 拒绝提交 | git a03f82d7e582 2026-02-04 (#178889) | git log -S |
| PBQP clang 初始化修复 | git a4f8918d699b 2026-09-02 (#217954) | git show --stat |
| RegAllocType 枚举 | include/llvm/Target/CGPassBuilderOption.h:31-43 | grep |
| 四 allocator llc 可切换 | build-debug llc 实测 | terminal |
| -regalloc-npm=basic/pbqp 静默落 greedy | build-debug llc 实测 -print-after-all | terminal |


