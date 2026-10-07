# LLVM 寄存器分配通用基础设施深度分析

> 数据基准：llvm-project main @ `3eda2aebadd4`（2026-09-30），build-debug 实测（AArch64 host 压力用例）。
> 方法：静态分析（引用一律 `文件:行号`，三个子代理共 240+ 引用全部脚本核验+主会话抽查）+ 动态验证（四策略切换、3597 行决策日志、-time-passes 计时、copy 数 13→5 实证）。
> 七部曲定位：横向对比 → AMDGPU 后端 → NVPTX 后端 → clang-AMDGPU → clang-NVPTX → **本文档（RA 通用基础设施——前五部 target 视角的"本体"）**。
> 素材全文：`RegAlloc-notes/01..04-*.md`（996 行）+ scratch/（压力用例×3 + 决策日志×3 + MIR×5）。

---

## 目录

- §1 摘要与核心论点
- §2 地基：SlotIndexes（一切的地基）
- §3 地基：活跃区间族 + Coalescer 协作
- §4 干涉表示：LiveRegMatrix + VirtRegMap
- §5 策略层：Fast/Basic/PBQP（+RegAllocBase 驱动）
- §6 Greedy 主流程 + spill 决策链（重点）
- §8 顾问层 2×2（规则×ML）
- §10 与六部曲的衔接：变体在本体上的精确位置
- §11 昇腾映射：CANN/PyPTO 重写 RA 的"抄什么清单"
- §12 复现手册

---

## §1 摘要与核心论点

> **通用 RA 是"可插拔策略 + 不可插拔地基"的架构**。地基（SlotIndexes 线性编址/LiveInterval 族/LiveRegMatrix 无显式干涉图/VirtRegMap 决策-物化分离）对所有算法共享且**无 target 特异性**；策略层仅 4 个 allocator（Fast/Basic/Greedy/PBQP）+ 2×2 顾问（eviction/priority × 规则/ML）。**前五部曲的两个极端变体都建立在这套地基上**：AMDGPU 三段式 = Greedy×3 + 段间自定义变换；NVPTX 空 RA = 只跑地基铺垫（coalescer/scheduler 照常）。

**五个贯穿性实证**：
1. **"无显式干涉图"贯穿一切**：LiveRegMatrix 是 per-RegUnit 的时间×空间矩阵查询；连 PBQP 都只为建边扫描一遍解完即弃——增量查询便宜/图重构贵是 RA 迭代本质决定的
2. **四策略质量-时间全景**（实测）：-O0 spill fast:basic:greedy:pbqp = 65:22:20:18，耗时 16.5:45:222:710ms——**43 倍时间差买 3 倍 spill 差**
3. **Greedy 瀑布决策八层**（selectOrSplitImpl :2658-2758）：tryAssign→CSR→tryEvict→**second-round 推迟**→trySplit→last-chance recolor→spill 兜底；3597 行决策日志全链实证（含 evict Cascade 链式踢链 %89→%55→%50）
4. **决策点外挂模式**：规则与 ML 顾问共享合法性剪枝，ML 只换"挑选"（evict 21 特征/priority 3 特征）；无 ML runtime 时自动回退规则版
5. **spill 链三选一**：remat（def 可重算）> 折叠（use 恰为同栈槽访问）> 直接 spill；SplitKit 区域分裂是"缩小活跃域让干涉消失"的数学

---

## §2 SlotIndexes：一切的地基

**详见 `01-foundation.md`**

- **编码**：`PointerIntPair<IndexListEntry*, 2, unsigned>`——指针+2 位四槽（B/e/r/d），全局序 = entry 基址|slot，InstrDist=16（SlotIndexes.h:69-93）
- **重编号升级路径**：插入取中点 `(next-prev)/2 & ~3` → 局部重排（半步长 8 追赶）→ 超 1/5 函数跨度则全函数 packIndexes（SlotIndexes.cpp:191-218, 291-294）；删除只置 null 不回收
- **"地基"实据**：Segment 边界/LiveRegMatrix 查询/idx2MBBMap 二分（:512-521）全部退化为整数序比较

## §3 活跃区间族 + Coalescer 协作

**详见 `01-foundation.md`**

- **两遍构造**在 LiveIntervalCalc::calculate（:41-103）：createDeadDefs → extendToUses（kills 顺手清除，区间端点即 kill）
- **SubRange 单链表** + refineSubRanges 部分相交一分为二（LiveInterval.cpp:917-954）；主区间恒为子区间并集——AMDGPU LaneMask 压力模型的地基
- **权重全链**：`(def+use)×块频 → 循环×3 → hint×1.01 → remat×0.5 → /(Size+25×InstrDist)`（CalcSpillWeights.cpp:240-401）
- **增量更新协议**：LiveRangeEdit Delegate 回调（LRE_*×4）+ LiveIntervals::HMEditor（:1081）——"父区间不可变+新 vreg 副作用边界"+ SplitEditor::finish() 统一收口
- **实测**：coalescer 前后 copy 数 **13→5**（PHI 消除的 8 条 vreg↔vreg COPY 全部 join 消失）——join 判定边界的精确刻画

## §4 干涉表示与映射基座

**详见 `02-03-05-strategies.md` §4**

- **LiveRegMatrix = per-RegUnit 的 LiveIntervalUnion 数组**（时间×空间矩阵）；assign/unassign 双向维护（VRM+Matrix[Unit].unify/extract）；regmask 干涉粒度细于 regunit；取舍由 RegAllocBase.h:30-33 设计注释定调
- **缓存细节坑**：两个栈上 LR 的重载查询**故意不缓存**（栈地址复用致 Query 缓存 key 冲突，:236-248 注释+FIXME）
- **VirtRegMap 决策-物化分离**：VRM 永远存整寄存器号；subreg→子物理寄存器换算推迟到 rewrite（VirtRegMap.cpp:747-749 `TRI->getSubReg`）；分配期间 subreg 语义由 SubRanges/lanes 表达
- **锚点纠错**：`getVirt2PhysAssignment` 在 main 与 git 历史均不存在（grep+git log -S 双验证）

## §5 策略层：Fast / Basic / PBQP

**详见 `02-03-05-strategies.md` §5**

- **RegAllocFast**：块局部**逆序**线性扫描；RegUnitStates 4 态数组 + displacePhysReg 就地 reload（O(n) 来源）；mayLiveOut 有界扫描 Limit=8
- **RegAllocBasic = RegAllocBase 驱动 + first-fit**：与 Greedy 共享全部框架/Spiller/权重代码，256 行全是策略简化——"调试基线"角色
- **PBQP 考古**：cost vector（spill 选项 index 0，weight+10.0 下限；CSR +1.0 罚）；**干涉图构建本身借用线性扫描**（:296-380 自述注释）；**弃置四条证据链**——无 target 默认/NPM 只实现 fast+greedy（basic/pbqp 走 fatal）/AMDGPU 显式拒绝/clang 路径 2026-09（`a4f8918d699b`）才修复 pass 未注册
- **实测四策略表**（-O0，16 并发值 AArch64）：

| 策略 | spill | 耗时 | 判读 |
|---|---|---|---|
| fast | 65 | 16.5ms | spill 是 greedy 3.25 倍 |
| basic | 22 | 45.0ms | |
| greedy | 20 | 222.0ms | -O2 时反超 pbqp |
| pbqp | 18 | 709.7ms | 质量最优但占总编译 75% |

- **实测坑**：`-regalloc-npm=basic/pbqp` 在 llc（legacy PM 默认）下**静默忽略**落到 greedy

## §6 Greedy 主流程 + spill 决策链（重点）

**详见 `04-06-greedy-advisors.md` §6**

- **瀑布八层**（selectOrSplitImpl，RegAllocGreedy.cpp:2658-2758）：tryAssign → CSR 特例 → tryEvict → **"wait for second round"**（首见推迟，等小区间分完获得更完整干涉图）→ trySplit → last-chance recoloring → spiller().spill 兜底
- **InlineSpiller 三选一**：remat > 折叠（use 恰为同栈槽 load/store）> 直接 spill（家族共享栈槽+spillAroundUses）；MaxEvictionCount/MustFindEviction/NaN 饱和三重护栏
- **SplitKit 区域分裂**：函数名实为 splitSingleBlock 与 splitLiveThroughBlock/splitRegInBlock/splitRegOutBlock（按块角色三分派）——任务书的 splitSingleInterval/editRange 不存在（纠偏）
- **Spiller 多实现已终结**：commit `cdd9077f3aa1` 删除 trivial spiller，现仅 InlineSpiller 一家
- **实测**（36 值双臂压力用例，3597 行日志）：evict Cascade 链式踢链（%89→%55→%50 权重降序）、second-round 推迟、一个 vreg 走完 split→remat 拒绝→folded STRWui→reload 全链路

## §8 顾问层 2×2

**详见 `04-06-greedy-advisors.md` §8**

```
                规则基线                  ML 版
eviction   RegAllocEvictionAdvisor   MLRegAllocEvictAdvisor
（踢谁）    （373 行启发式）           （1089 行推理 wrapper，21 特征）
priority   RegAllocPriorityAdvisor   MLRegAllocPriorityAdvisor
（先分谁）                            （仅 3 特征）
```
- **共享合法性剪枝**（canReassign/getOrderLimit 等，定义在 RegAllocGreedy.cpp:590-712）——**ML 只换"挑选"不换约束**
- **ML 特征**：evict 21 个（列向量/AllocationOrder 位置/频率加权读写/归纳变量模式/progress）；priority 仅 3 个；**ML 有"不踢"出口**（CandidateVirtRegPos）而规则版没有
- **护栏实证**：无 ML runtime 时 release/development 模式报 `could not be created` 后**自动回退规则版**；`-regalloc-training-log` 在无 TFLite 构建下 option 未注册

---

## §10 与六部曲的衔接：变体在本体上的精确位置

| 变体 | 在通用框架中的位置 | 引用 |
|---|---|---|
| **AMDGPU 三段式** | Greedy×3（onlyAllocateSGPRs/WWM/VGPRs 过滤谓词）+ 段间自定义变换（SILowerSGPRSpills 物化 VGPR lane/WWM 锁定）；insertPass 楔入地基缝隙 | AMDGPU-notes/05 |
| **NVPTX 空 RA** | 只跑地基铺垫（LiveVariables/PHIElim/TwoAddress/Coalescer/MachineScheduler/StackSlotColoring）——addOptimizedRegAlloc 整体替换，allocator 与 rewriter 均不进流水线 | NVPTX-notes/03 |
| 通用默认 | CodeGenPassBuilder.cpp:786-792（Optimized→Greedy 否则 Fast）；-regalloc-npm=greedy 绕过 target override | §5 |

**两个变体的自由度来源**：① allocator 可替换（addTargetRegisterAllocator/整体替换 addOptimizedRegAlloc）② 地基可单独复用（NVPTX 只用铺垫不分配）。**AMDGPU 没有写第四个 allocator，而是三次调用 Greedy+过滤谓词**——这是"复用策略层、自定义段间"的范本。

## §11 昇腾映射：CANN/PyPTO 重写 RA 的"抄什么清单"

**详见各章昇腾节（全部推理级标"待验证"）**，汇总为三级清单：

### 全抄（无 target 特异性，直接搬）
1. **SlotIndexes 线性编址**：tile 时间轴（schedule index）的线性编址——一切区间运算的地基
2. **LiveInterval 段表示 + SubRange**：tile 生命周期（生产→消费）建模；SubRange 对应 tile 的行/列分块生命周期
3. **LiveRegMatrix"查矩阵不建图"**：迭代式 tile 分配（先粗分再调优）天然适合增量查询
4. **VirtRegMap 决策-物化分离**：tile→buffer 决策表 + 生成时 rewrite 阶段（不边分配边改 IR）
5. **瀑布决策序**：tryAssign→evict→split→spill 的优先序（能不 spill 就 split）

### 看需求（部分借鉴）
6. **Fast 线性扫描**：JIT/动态 shape 场景编译时间敏感时的选项（判定式：tile 不跨阶段存活+峰值<buffer 容量+编译时间敏感 → Fast 够用）
7. **Greedy 分裂**：tile 生命周期切分（热区驻留 L1 冷区落 DDR）——收益取决于 Ascend buffer 的换入换出语义（待验证）
8. **权重公式**：`(def+use)×块频→循环×3→/(Size+常数)` 的归一化——tile 权重可类比（读写次数×循环深度/大小）

### 加分项（可选）
9. **顾问外挂模式**：规则基线+可替换 ML（不重写 allocator 只换决策函数）——PyPTO 若积累足够调度轨迹后可引入
10. **PBQP 教训**：仅当 tile 分配问题真的"不规则"（bank 互斥+亲和复用交织）且规模可控时才值得全局求解

### 明确不抄
11. **PBQP 本体**（43 倍编译时间买 3 倍质量，LLVM 自己都弃置）
12. **四策略并存**（Fast+Greedy 两档即可覆盖 JIT/AOT 场景）

## §12 复现手册

```bash
cd ~/code/llvm-project   # main @ 3eda2aebadd4
LLC=build-debug/bin/llc
S=RegAlloc-notes/scratch

# 四策略对比（§5；注意 -regalloc-npm 在 llc 下静默忽略，用 legacy -regalloc=）
for ra in fast basic greedy pbqp; do
  echo "== $ra:"; $LLC -mtriple=aarch64 -regalloc=$ra -O0 -o - $S/stress_aarch64.ll 2>/dev/null | grep -cE "str|ldr" | head -1
done

# 编译时间（50 函数放大版）
$LLC -mtriple=aarch64 -regalloc=greedy -O0 -time-passes -o /dev/null $S/stress_big.ll 2>&1 | grep -i "greedy\|fast"

# Greedy 决策日志（§6；3597 行样例在 scratch/ra_debug*.log）
$LLC -mtriple=aarch64 -regalloc=greedy -O2 -debug-only=regalloc -o /dev/null $S/ra_stress36.ll 2>&1 | grep -E "selectOrSplit|evict|split|reload" | head -20

# coalescer 实证（§3；copy 13→5）
$LLC -mtriple=aarch64 -O2 -print-before=register-coalescer -print-after=register-coalescer -o /dev/null <PHI 用例> 2>&1 | grep -c COPY

# slotindexes 槽位注记（§2；0B/16B 格式）
$LLC -mtriple=aarch64 -O2 -print-after=slotindexes -o /dev/null $S/stress_aarch64.ll 2>&1 | grep -E "^[0-9]+B" | head -5

# advisor 开关（§8；无 ML runtime 时自动回退规则版）
$LLC -mtriple=aarch64 -regalloc=greedy -regalloc-enable-advisor=release -O2 -o /dev/null $S/stress_aarch64.ll 2>&1 | grep -i advisor
```

---

## 附录：章节-素材对照与执行注记

| 章 | 素材 | 行数 | 产出方式 |
|---|---|---|---|
| §2+§3 | 01-foundation.md | 179 | 子代理一次成盘（含实测回填） |
| §4+§5+§7 | 02-03-05-strategies.md | 247 | 子代理成盘+主会话数据回填 |
| §6+§8 | 04-06-greedy-advisors.md | 503 | 子代理成盘（91 引用脚本核验+1 处自纠） |
| §9 变体层 | 并入 §10（引用前五部曲） | — | 主会话 |

执行注记：1 主会话 + 3 子代理（3/3 全部成功写盘——六部曲以来首次零代写，防额度耗尽纪律成熟）。任务书纠偏 5 处（-split-editors 不存在/splitSingleInterval 不存在/Spiller 多实现已终结/getVirt2PhysAssignment 不存在/-regalloc-npm 静默忽略）。动态验证全实跑（四策略表/43 倍时间差/3597 行决策日志/copy 13→5/advisor 回退护栏）。
