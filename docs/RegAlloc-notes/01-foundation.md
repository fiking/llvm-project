# §2+§3 RA 地基层：SlotIndexes + 活跃区间族 + Coalescer 协作视角

日期：2026-09-30。基准：llvm-project main @ `3eda2aebadd4`，build-debug（DEBUG+assertions，含 AArch64/NVPTX/AMDGPU）。
行数实测（wc -l）：SlotIndexes.cpp 329 / LiveIntervals.cpp 1886 / LiveInterval.cpp 1438 / RegisterCoalescer.cpp 4434 / SlotIndexes.h 686 / LiveInterval.h 1051 / LiveIntervalCalc.cpp 194 / CalcSpillWeights.cpp 401 / SplitKit.cpp 1944。

各节结构：静态分析(文件:行号) → 动态验证 → 设计动机 → 昇腾映射（推理级，标"待验证"）。

---

## §2.1 SlotIndexes：一切的地基

### 静态分析

**槽位编码（idx 的打包）。** SlotIndex 是对 IndexListEntry 的不透明包装：`PointerIntPair<IndexListEntry*, 2, unsigned> lie`（SlotIndexes.h:93）——指针指向指令链表节点，低 2 位打包 slot 编号。slot 枚举 4 种（SlotIndexes.h:69-91）：

- `Slot_Block`（0）：基本块边界/PHI def 点
- `Slot_EarlyClobber`（1）：early-clobber def/use
- `Slot_Register`（2）：普通 def/use
- `Slot_Dead`（3）：死 def 的 kill 点

数值序恰好编码了"同一指令内的时间先后"：`B < e < r < d`。全局比较 `operator<` 直接比 `getIndex()`（SlotIndexes.h:152-154），而 `getIndex()` = `listEntry()->getIndex() | getSlot()`（SlotIndexes.h:102-104）——**32 位无符号 = 指令基址（低 2 位清零）| 2 位 slot**。所以"任务描述里的 fare"实为基址编号，slot 是本地 2 位子编号，二者按位或打包成单一线性序。打印格式 `"Berd"[getSlot()]`（SlotIndexes.cpp:316-321），即 `16B/16r/32B` 这类注记。相邻指令默认距离 `InstrDist = 4 * Slot_Count = 16`（SlotIndexes.h:112-116）。

**重编号机制。** 初始 `analyze()` 按 layout 顺序扫全函数：MBB 边界条目（`mi=nullptr`）与每条非 debug/pseudo 指令（`index += InstrDist`）交替入 `indexList`（SlotIndexes.cpp:94-117）。插入新指令时 `insertMachineInstrInMaps()`（SlotIndexes.h:528-566）取前后邻居编号的中点：`dist = ((next-prev)/2) & ~3u`，若 `dist==0`（编号空间耗尽）触发**局部重编号** `renumberIndexes()`（SlotIndexes.cpp:193-218）——从插入点向后以 `InstrDist/2=8` 步长重排直到"追上"既有编号；若重排跨度超过函数总编号的 1/5，则干脆全函数 `packIndexes()` 重打包（SlotIndexes.cpp:291-294，`Entry.setIndex(Index * InstrDist)`）。删除指令不删除编号，只把 entry 的 `mi` 置 null（SlotIndexes.cpp:125-139）——编号只增不减，区间可以安全引用"已消失位置"。统计量 `NumLocalRenum`（SlotIndexes.cpp:48）。

**为什么是"一切的地基"。** 三个下游全吃这个线性序：
1. **区间边界**：`LiveRange::Segment{start,end}` 就是两个 SlotIndex（LiveInterval.h:171-207），区间求交/合并是纯整数序比较；
2. **干涉查询**：LiveRegMatrix 的 `checkInterference` 归结为"两个区间在 SlotIndex 序上是否重叠"（详见 02-matrix.md）；
3. **MBB 定位**：`idx2MBBMap` 按 start 排序，`getMBBFromIndex` 用 `upper_bound` 二分（SlotIndexes.h:512-521）；区间延伸时"这个 slot 属于哪个块"完全靠它。
`handleMove` 等增量更新也只是 remove+insert 编号，再让区间跟着新序重排（LiveIntervals.cpp:1623-1637）。

### 动态验证（-print-after=slotindexes）

```bash
build-debug/bin/llc -O2 -mtriple=aarch64 -print-after=slotindexes test.ll
```
输出每条指令前注记 `0B/16B/32r` 之类（数字=基址，字母=slot），块尾还有 `bb.0 [0B; 16B)` 的范围行（SlotIndexes::print，SlotIndexes.cpp:296-309）。NVPTX-notes/03 已有先例。

### 设计动机

RA 需要一个"程序序上的连续时间轴"来表达 liveness，但 MIR 的指令是双向链表、MBB 是 CFG 节点，都没有全序。SlotIndexes 用一张侵入式链表 + 单调编号把这二维结构压平成 32 位整数序，使 (a) 区间代数（交/并/差）退化为整数比较，(b) 比较器无需求逆（`isEarlierInstr` 只比 entry 的 index，SlotIndexes.h:180-182），(c) 插入留空隙使增量更新 O(局部) 而非 O(全函数)。"slot 放指针低位"则让同一指令的 B/e/r/d 天然相邻，PHI 与 early-clobber 无需特殊数据结构。

### 昇腾映射（推理级，待验证）

若要为 PyPTO/CANN 的"UB（Unified Buffer）生命周期"建模：UB base/offset 的占用区间天然是"tile 级别的活跃区间"。SlotIndexes 的两段式设计（指令基址 + 2 位 slot）可直接类比——把 TPC/AI Core 指令流线性编址（一次 tile pass 一个 InstrDist），UB 区间即可复用 LiveRange 的 Segment 表示与 overlaps 查询。但昇腾 tile 调度可能存在"非 layout 序"的重叠执行（双缓冲），线性序假设是否成立**待验证**。

---

## §2.2 LiveIntervals 构造 pass

### 静态分析

**主入口与"两遍"。** `LiveIntervals::analyze()`（LiveIntervals.cpp:159-181）分三步：`computeVirtRegs()` → `computeRegMasks()` → `computeLiveInRegUnits()`。每个 vreg 的区间计算 `computeVirtRegInterval`（LiveIntervals.cpp:228-234）委托给 `LiveIntervalCalc::calculate()`，后者才是真正的**两遍**（LiveIntervalCalc.cpp:41-103）：

- **第一遍 createDeadDefs**：扫所有 def 操作数，在每个 def slot 建最小死段 `[def, def.getDeadSlot())`（LiveIntervalCalc.cpp:48-81，`createDeadDef` 在 31-39）；若目标跟踪子寄存器活性（`shouldTrackSubRegLiveness`）且见到 subreg def，则 `refineSubRanges` 切分 lane（LiveIntervalCalc.cpp:57-75）。
- **第二遍 extendToUses**：扫所有读操作数，把段延伸到每个 use（LiveIntervalCalc.cpp:89-102）；跨块时经支配树构造 SSA 形式（PHI-def 在块边界 slot）。主区间有 subrange 时：先逐 subrange `extendToUses`，再 `LI.clear()` 后由 `constructMainRangeFromSubranges` 重建主区间=子区间并集（LiveIntervalCalc.cpp:91-98, 105-120）。

所以任务里的"先算 defs/uses+kills 再构造区间"精确对应 **calculate 的 Step1(dead defs)+Step2(extend to uses)**；kills 并非显式输入——`extendToUses` 顺手清掉所有 kill 标志（"kill flags 由 VirtRegRewriter 事后重插"，LiveIntervalCalc.cpp:146-149），区间端点本身就是 kill 的表达。

**与 LiveIntervalsAnalysis 的关系（新 PM）。** `LiveIntervalsAnalysis::run`（LiveIntervals.cpp:65-72）构造 `Result(MF, SlotIndexesAnalysis, MachineDominatorTreeAnalysis)` 后 `LLVM_DEBUG(Res.dump())`——**LiveIntervals 是 analysis result 而非 pass**；`LiveIntervalsWrapperPass`（legacy，LiveIntervals.cpp:84-97）只是把同一 `analyze()` 挂进旧 PM。`LiveIntervals::invalidate`（LiveIntervals.cpp:128-140）声明：自身未保留或 SlotIndexes/DomTree 失效则失效——指针依赖被显式建模。新 PM 管道里用 `RequireAnalysisPass<LiveIntervalsAnalysis, MachineFunction>()` 惰性触发（CodeGenPassBuilder.cpp:879-881，`Opt.EarlyLiveIntervals` 时在 TwoAddress 之前先算一遍）。

**RA 期间的增量更新协议（-split-editors 通道）。** 注：仓库无 `-split-editors` 这个 flag（grep 无命中）；SplitKit/LiveRangeEdit 编辑期间的区间一致性靠以下协议维持（RegAllocGreedy.cpp:2992 构造 SplitEditor，LREdit 构造于 1478 等处）：
1. **LiveRangeEdit 只增不改**：父 vreg 区间从不改动，分裂/spill 产物全部是新 vreg（LiveRangeEdit.h:12-16 注释）；它通过 `MRI.addDelegate(this)` 监听 vreg 的增删（LiveRangeEdit.h:126），`Delegate::LRE_CanEraseVirtReg/LRE_WillShrinkVirtReg` 等回调让所有者（如 RAGreedy）先同步自己的状态（LiveRangeEdit.h:45-60）。
2. **SplitEditor 编辑→finish 收口**：插入 copy 时只对新 vreg 建死段；`finish()` 统一收口：补父区间 def（SplitKit.cpp:1552-1562）、`transferValues`+`rewriteAssigned` 把 SSA 值映射到新 vreg 并延伸区间（1576-1579）、`RenumberValues()`+`removeEmptySubRanges` 清理（1591-1595）、`splitSeparateComponents` 切断不连通分量（1604-1618）、`calculateRegClassAndHint` 重算权重（1621）。
3. **精确修复**：改指令序列的 pass 用 `handleMove/handleMoveIntoNewBundle/repairIntervalsInRange`（LiveIntervals.h:351-381；HMEditor 在 LiveIntervals.cpp:1081-1621）只重算受影响区间。

### 动态验证

`-print-after=liveintervals` 输出 `********** INTERVALS **********` 块（LiveIntervals.cpp:184），每行一个区间（格式见 §2.3）。也可用 `-debug-only=regalloc`（DEBUG_TYPE "regalloc"，LiveIntervals.cpp:61）在构造后 dump。

### 设计动机

两遍结构是"SSA 区间构造"的最省实现：先有 def 点集合（值的存在性），再沿 use 反向延伸（值的覆盖域），PHI 在延伸中按需生成——比"对每个块做 liveness 数据流迭代再合并"少了 MBB 级定点迭代。增量协议则回答"RA 是长管线，不能每编辑一次就全量重算"：编辑器以新 vreg 为副作用边界，父区间不可变，使一致性收口可以局部化到 finish()。

### 昇腾映射（推理级，待验证）

UB 生命周期构造同样可以是"def=tile 写入，use=算子消费"两遍：先收集所有 def（TBUF 写、LOAD2D），再延伸到 use（MTE/VECTOR 读取）。PHI 对应"多前驱块汇聚时 UB 内容一致"的等价类。昇腾若用 per-tile 显式管理而非 SSA vreg，则 LiveRangeEdit 的"父不可变+新 vreg 收口"协议可平移为"父 tile 区间不可变+新 tile 区间收口"。**待验证：CANN 是否已有等价 pass。**

---

## §2.3 LiveInterval 数据结构

### 静态分析

**段的表示。** `LiveRange::Segment{SlotIndex start, SlotIndex end, VNInfo *valno}`，区间 [start,end) 半开（LiveInterval.h:171-207）。容器是 `SmallVector<Segment,2> segments` 按 start 升序（LiveInterval.h:209-213）；valnos 是 `SmallVector<VNInfo*,2>`（LiveInterval.h:210）——**没有独立"段池"**：段直接内联在 LiveRange 的 SmallVector 里，VNInfo 由 `VNInfo::Allocator`（BumpPtrAllocator，LiveIntervals.h:68）分配。physreg regunit 的初始计算可用临时 `std::set<Segment> segmentSet` 加速（LiveInterval.h:215-219，`UseSegmentSetForPhysRegs` 默认 true，LiveIntervals.cpp:107-110），算完 flush 进 vector（LiveIntervalCalc.cpp:386-388 同类逻辑在 computeRegUnitRange 尾部，LiveIntervals.cpp:387-388）。

**LaneMask 子区间。** `LiveInterval : LiveRange`，内含单链表 `SubRange *SubRanges`（LiveInterval.h:712-731）：每个 SubRange 自身是完整 LiveRange 外加 `LaneBitmask LaneMask`。多通道寄存器（如 SGPR_128 的 4 个 32-bit lane）= 主区间（全体 lane 并集，供干涉检查用）+ 若干按 lane 掩码切分的子区间（供子寄存器精确活性）。切分由 `refineSubRanges`（LiveInterval.cpp:917-954）完成：遇新掩码与既有 SR 部分相交则把 SR 一分为二（`createSubRangeFrom` 复制旧段再各自 `stripValuesNotDefiningMask`），完全未覆盖则新建。AMDGPU 等目标用 `shouldTrackSubRegLiveness` 开启（LiveIntervalCalc.cpp:58-66 首次 subreg def 时以主区间为模板初始化）。主区间恒为子区间并集：构造后 `constructMainRangeFromSubranges` 重建（LiveIntervalCalc.cpp:105-120）。

**权重计算（spill weight 启发式）。** 核心公式在 `LiveIntervals::getSpillWeight`（LiveIntervals.cpp:965-975）：
```cpp
float Weight = isDef + isUse;                      // def=1, use=1
if (OptForSize) return Weight;                     // optsize 只看代码量
return Weight * MBFI->getBlockFreqRelativeToEntryBlock(MBB);  // ×块频
```
聚合与加成在 `VirtRegAuxInfo::weightCalcHelper`（CalcSpillWeights.cpp:240-401）：遍历区间触碰的每条指令累加权重；**循环归纳变量加成** `×3`（退出块上 def 且活出块，CalcSpillWeights.cpp:333-334）；**hint 加成** `×1.01`（有 copy hint 时弱提升，CalcSpillWeights.cpp:366-368）；**remat 折半** `×0.5`（全部 def 可重物化，CalcSpillWeights.cpp:393-394）；**寄存器类缩放** `×TRI.getSpillWeightScaleFactor(RC)`（CalcSpillWeights.cpp:398）；最后 `normalize = UseDefFreq / (Size + 25*InstrDist)`（CalcSpillWeights.h:35-43）——加 25 条指令的哑量使小区间权重≈use 数、大区间≈use 密度。非 spillable 编码为 `huge_valf`（isSpillable，LiveInterval.h:844-847）：physreg 区间初始即 huge（LiveIntervals.cpp:222-225）、unspillable terminator（CalcSpillWeights.cpp:310-314）、零长且不跨 regmask（CalcSpillWeights.cpp:382-387）。计算时机：Greedy 主循环前 `VRAI->calculateSpillWeightsAndHints()`（RegAllocGreedy.cpp:2987），hint 同时写入 MRI（CalcSpillWeights.cpp:339-364，physreg 优先于 vreg、非 CSR 优先）。权重还影响**优先级位打包**：hint 位占 bit30（RegAllocGreedy.cpp:503-505）。

### 动态验证

`-print-after=liveintervals` 或 `-print-after=calcspillweights` 可看每区间行尾的 `weight=` 数值与 hint（print 格式 LiveInterval.cpp:1038+）。

### 设计动机

Segment+VNI 双层表示：Segment 提供"何时活"，VNInfo 提供"活的哪个值"（SSA 值等价类）——join/spill 决策需要区分二者（如 join 用值映射，spill 只看段）。LaneMask 子区间把"子寄存器活性"做成与主区间同构的结构，代价是 join 时要做 lane 变换（composeSubRegIndexLaneMask，RegisterCoalescer.cpp:3761-3777）。权重公式刻意保持**可比较的标量**：evict 决策（RAGreedy）就是比大小，密度归一化避免长区间天然垄断。

### 昇腾映射（推理级，待验证）

UB 若按 128B/256B lane 组织，LaneMask 模型直接适用：主区间=整个 UB slot 的占用，子区间=各 lane（fragment）占用，干涉检查用主区间、精确 spill（回退到 GM）用子区间。spill weight 的"频次×密度"框架可平移为"tiling 循环频次×UB 占用密度"。**待验证：昇腾 UB 是否有 sub-register 语义。**

---

## §3 RegisterCoalescer：协作视角

### 静态分析

**join 的时机（RA 前的独立 pass）。** 新 PM 管道 `addOptimizedRegAlloc`（CodeGenPassBuilder.cpp:852-916）：`TwoAddressInstructionPass` → **`RegisterCoalescerPass()`**（884 行）→ RenameIndependentSubregs → MachineScheduler → RAGreedy → VirtRegRewriter。即 coalescer 在**指令调度与 RA 之前**、PHI 消除/两地址转换之后，且 `-O0` fast 路径完全没有 coalescer（addFastRegAlloc，CodeGenPassBuilder.cpp:843-847）。setjmp 函数整体跳过（RegisterCoalescer.cpp:4338-4342）。

**可 join 判定。** 入口 `joinCopy`（RegisterCoalescer.cpp:2054）：`CoalescerPair::setRegisters` 先做静态过滤（寄存器类兼容/交叉类、子寄存器组合合法 `composeSubRegIndices`，RegisterCoalescer.cpp:439,598-599）；目标钩子 `TRI.shouldCoalesce` 可否决（2080-2084）。核心在 `joinVirtRegs`（3713-3788+）：**不是"same value numbering"判等，而是构造 NewVNInfo 值映射**——两侧 `JoinVals`（2500-2702）逐值配对分析 overlap：
- `LHSVals.mapValues(RHSVals)`：计算 NewVNInfo 与简单映射，冲突仅 defer（3737-3738）
- `resolveConflicts`：解 IMPLICIT_DEF/副本值/coalescable copy 等特例（CR_Erase/CR_Merge/CR_Replace 枚举，2537-2562；3742-3743）
- 高代价区间直接拒（`isHighCostLiveInterval`：valnos/segments 超阈值，3726-3732，阈值 cl::opt 111/117 行）
判定本质：**copy 两端值在 overlap 处必须"值等价或可安全合并"**——overlap 检查退化为"两个 LiveRange 的段在 SlotIndex 序上重叠时，两侧 VNI 是否同一/可由 copy 关联"。join 成功后 `updateRegDefsUses` 改写所有 SrcReg→DstReg（2261-2265），子区间按 compose 后的 lane 掩码 mergeSubRangeInto（3746-3781）。

**join 对 RA 质量的影响链。**
1. 正向：消灭 copy 本身（少一条指令+少一次压力）；
2. 负向：join 造出**更长区间**——两段活性取并集，压力峰值可能上升，迫使更多 spill/split；coalescer 自身的应对是"让 DstReg 是较大区间"（2171-2174）+ 高代价区间拒绝 join；
3. 权衡工具：**RematWeight×0.5**（可 remat 的区间更愿意被 spill）、hint ×1.01 引导 RA 把同源 vreg 分到同 reg；RAGreedy 侧 `-split-threshold-for-reg-with-hint`（RegAllocGreedy.cpp:143）让带 hint 的区间更晚 split。
4. join 失败的回退链（2206-2239）：`adjustCopiesBackFrom`（回退到先前 def）→ `removeCopyByCommutingDef`（交换可交换指令的 def）→ `removePartialRedundancy`（前驱提升）——都是"不 join 也要消灭 copy"的次优手段。

**identity copy 消除。** `CP.getSrcReg()==CP.getDstReg()`（如 removeCopyByCommutingDef 的副作用）直接走特判（2108-2153）：合并 copy 处的值映射 `MergeValueNumberInto`（连同子区间的 undef lane 剪除 `copyValueUndefInPredecessors`/`setUndefOnPrunedSubRegUses`）后 `deleteInstr`。CalcSpillWeights 侧同样跳过 identity copy 不计权重（CalcSpillWeights.cpp:294-304）。**join 的调度**：`joinAllIntervals`（4265-4295）按 MBB 循环深度排序（`MBBPriorityInfo`+array_pod_sort），深循环优先 join，`copyCoalesceWorkList` 迭代至不动点（4292-4293），`lateLiveIntervalUpdate` 收口 ToBeUpdated 集合（4096-4106）。

### 动态验证（-print-after=register-coalescer）

构造一个 removable copy 用例：PHI 消除后留下的 `COPY %1 = %0`，若两区间不 overlap 则 join 成功、copy 消失。命令：
```bash
build-debug/bin/llc -O2 -mtriple=aarch64 -print-after=register-coalescer test.ll
```
join 前：`%1 = ORRXrr %xzr, %0`（copy）+ 两区间；join 后：单区间覆盖两段。可对比 join 前后 copy 数（grep -c COPY）。

### 设计动机

coalescer 是"用区间合并换 copy 消除"的独立优化，放在 RA 前是因为：join 需要区间信息（依赖 LiveIntervals）但又会改变区间（join 后必须 shrink 重算），做成独立 pass 让 RA 拿到的是"已尽量无 copy"的输入；两地址转换在它之前，保证 join 判定看到的是规范化 copy。质量权衡（copy 数 vs 区间长度）无法静态最优，因此设计了 hint/权重/remat 折半等信号，把最终裁量留给 Greedy 的 evict/split。

### 昇腾映射（推理级，待验证）

昇腾若要消除 MTE/VECTOR 间的 UB 中转 copy（如 LOAD2D→UB→VECTOR 的 tile 搬运），coalescer 的"join 判定=值等价+overlap 可合并"框架可复用：两段 UB 占用若值同源且不 overlap 可合并为一。风险同 §2.1：tile 双缓冲的"overlap"语义在线性序下如何定义**待验证**。

---

## 附录：已核对引用清单

所有引用均在本次会话中经 read_file/grep 实读核对（llvm/ 前缀省略）：

| 文件 | 引用行 |
|---|---|
| include/llvm/CodeGen/SlotIndexes.h | 69-91 (Slot 枚举), 93 (PointerIntPair), 102-104 (getIndex), 112-116 (InstrDist), 152-171 (比较), 180-188 (isEarlierInstr), 244-282 (getNextSlot/PrevSlot), 295-332 (SlotIndexes 成员), 324-335 (createEntry/renumberIndexes 声明), 344-347, 354-357, 372-397, 414-447 (getIndexBefore/After), 450-474 (MBB 范围), 483-521 (idx2MBBMap 二分), 523-566 (insertMachineInstrInMaps), 574-597 (remove/replace), 603-638 (insertMBBInMaps/packIndexes) |
| lib/CodeGen/SlotIndexes.cpp | 48 (NumLocalRenum), 63-123 (analyze), 125-166 (removeMachineInstrFromMaps), 168-189 (removeMBBFromMaps), 191-218 (renumberIndexes), 220-289 (repairIndexesInRange), 291-294 (packIndexes), 296-309 (print), 315-321 (SlotIndex::print) |
| include/llvm/CodeGen/LiveIntervals.h | 55-106 (类成员/LICalc), 108-157 (analyze/getInterval/createAndCompute), 168-178 (createAndComputeVirtRegInterval), 188-253 (removeInterval/shrinkToUses/extendToIndices/pruneValue), 296-324 (insertMBBInMaps/splitAt/插入删除包装), 333-349 (reanalyze/addKillFlags), 351-381 (handleMove/repairIntervalsInRange), 383-414 (RegMask), 425-474 (RegUnit), 547-554 (LiveIntervalsAnalysis) |
| lib/CodeGen/LiveIntervals.cpp | 61 (DEBUG_TYPE), 65-80 (Analysis/Printer), 84-97 (WrapperPass), 107-110 (UseSegmentSetForPhysRegs), 112-121 (getAnalysisUsage), 128-140 (invalidate), 142-157 (clear), 159-181 (analyze), 183-210 (print), 222-225 (createInterval), 228-234 (computeVirtRegInterval), 236-248 (computeVirtRegs), 250-295 (computeRegMasks), 297-334 (reassignRegMaskSlots/insertMBBInMapsImpl), 336-389 (computeRegUnitRange), 391-431 (computeLiveInRegUnits), 433-441 (createSegmentsForValues), 443-522 (extendSegmentsToUses), 524-580 (shrinkToUses 主), 582-624 (computeDeadValues), 626-693 (shrinkToUses 子), 695-702 (extendToIndices), 704-745 (pruneValue), 902-925 (intervalIsInOneMBB), 927-941 (hasPHIKill), 943-975 (getSpillWeight 四重载), 977-988 (addSegmentToEndOfBlock), 1081-1199 (HMEditor/updateAllRanges/updateRange), 1623-1637 (handleMove), 1639-1675 (handleMoveIntoNewBundle), 1677-1838 (repairOldRegInRange/repairIntervalsInRange), 1840-1864 (removePhysRegDefAt/removeVRegDefAt), 1866-1880 (splitSeparateComponents), 1882-1886 (constructMainRangeFromSubranges) |
| include/llvm/CodeGen/LiveInterval.h | 165-219 (LiveRange/Segment/SegmentSet), 221-273 (迭代器/assign), 488+ (addSegment), 703-741 (LiveInterval/SubRange 定义), 743-825 (SubRanges 链表/iterator/createSubRange), 827-854 (hasSubRanges/getSize/isSpillable/computeSubRangeUndefs), 856-874 (refineSubRanges 文档) |
| lib/CodeGen/LiveInterval.cpp | 917-954 (refineSubRanges), 956-961 (getSize), 963-985 (computeSubRangeUndefs), 987-989 (Segment print), 997+ (VNInfo print), 1008+ (LiveRange print), 1033-1040 (SubRange/LiveInterval print) |
| lib/CodeGen/LiveIntervalCalc.cpp | 31-39 (createDeadDef), 41-103 (calculate 两遍), 105-120 (constructMainRangeFromSubranges), 122-132 (createDeadDefs), 134-160+ (extendToUses/kill 清除) |
| include/llvm/CodeGen/CalcSpillWeights.h | 30-43 (normalizeSpillWeight), 47-79 (VirtRegAuxInfo) |
| lib/CodeGen/CalcSpillWeights.cpp | 221-227 (calculateSpillWeightAndHint), 240-401 (weightCalcHelper：249 TargetHint, 251-263 split 继承, 266-283 CopyHint 排序, 285-304 identity copy 跳过, 310-314 unspillable terminator, 316-336 频次×循环加成, 339-368 hint 收集与×1.01, 370-387 零长 not spillable, 389-394 remat ×0.5, 396-400 RC 缩放与 normalize) |
| lib/CodeGen/RegAllocGreedy.cpp | 86-92 (SplitSpillMode), 143-144 (split-threshold-for-reg-with-hint), 480-509 (优先级位打包/hint bit30), 532-555 (tryAssign/hint), 1342/1478/1609/1940 (LREdit 构造点), 2740, 2983-2992 (VRAI/SplitEditor 构造, calculateSpillWeightsAndHints 时机), 2998 (allocatePhysRegs) |
| lib/CodeGen/RegisterCoalescer.cpp | 78-117 (cl::opt 组), 126 (JoinVals 前置声明), 244 (joinCopy 声明), 2500-2702 (JoinVals/ConflictResolution), 1993 (canJoinPhys), 2011-2025 (copyValueUndefInPredecessors), 2054-2293 (joinCopy 全流程：2065-2085 静态过滤, 2090-2095 dead copy, 2098-2106 undef, 2108-2153 identity copy, 2111 特判, 2156-2169 phys, 2171-2174 大区间优先, 2190-2240 join+回退链, 2244-2290 改写/shrink), 2314 (joinReservedPhysReg), 3616 (joinSubRegRanges), 3678 (mergeSubRangeInto), 3702 (isHighCostLiveInterval), 3713-3788 (joinVirtRegs), 3901 (joinIntervals), 4096-4106 (lateLiveIntervalUpdate), 4108-4138 (copyCoalesceWorkList), 4140-4199 (isTerminalReg/applyTerminalRule), 4201-4254 (copyCoalesceInMBB), 4256-4263 (coalesceLocals), 4265-4295 (joinAllIntervals), 4297-4323 (新 PM run), 4326-4434 (run：setjmp 跳过 4338, joinAllIntervals 4380, inflate 4385-4415) |
| lib/Passes/CodeGenPassBuilder.cpp | 778-792 (addTargetRegisterAllocator), 800-819 (addRegAllocPass), 821-839 (addRegAssignAndRewriteOptimized：VirtRegRewriter 836), 843-847 (addFastRegAlloc), 852-916 (addOptimizedRegAlloc：LiveVariables 871, PHIElim 876, EarlyLiveIntervals 879-881, TwoAddress 883, Coalescer 884, RenameIndependentSubregs 889, MachineSched 892, addRegAssignAndRewriteOptimized 894, StackSlotColoring 900, CopyPropagation 908) |
| include/llvm/CodeGen/LiveRangeEdit.h | 12-16 (编辑不改父), 42-60 (Delegate 回调), 73, 121-129 (MRI delegate 挂钩), 220 (calculateRegClassAndHint) |
| lib/CodeGen/SplitKit.cpp | 366 (reset), 1545-1624 (finish 收口全流程), 1650+ (splitSingleBlock), 1676+ (splitLiveThroughBlock) |

## 引用清单（简表）

1. SlotIndexes 槽位编码/重编号：llvm/include/llvm/CodeGen/SlotIndexes.h:69-116,152-188；llvm/lib/CodeGen/SlotIndexes.cpp:63-123,191-218,291-294
2. SlotIndexes 插入/删除/MBB 映射：SlotIndexes.h:523-566,512-521；SlotIndexes.cpp:125-189
3. LiveIntervals 两遍构造：llvm/lib/CodeGen/LiveIntervalCalc.cpp:41-103
4. LiveIntervals analyze/PM 双形态：llvm/lib/CodeGen/LiveIntervals.cpp:65-97,128-181
5. LiveInterval 段/SubRange/LaneMask：llvm/include/llvm/CodeGen/LiveInterval.h:165-219,703-874；llvm/lib/CodeGen/LiveInterval.cpp:917-954
6. Spill weight：LiveIntervals.cpp:943-975；CalcSpillWeights.cpp:240-401；CalcSpillWeights.h:30-43；RegAllocGreedy.cpp:480-509,2987
7. SplitKit/LiveRangeEdit 编辑协议：SplitKit.cpp:1545-1624；LiveRangeEdit.h:12-60,121-129
8. Coalescer join 时机/判定/影响链：CodeGenPassBuilder.cpp:852-916；RegisterCoalescer.cpp:2054-2293,2500-2702,3713-3788,4265-4295
9. Identity copy：RegisterCoalescer.cpp:2108-2153；CalcSpillWeights.cpp:294-304
