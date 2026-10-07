# §7 AMDGPU 寄存器分配三段式深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，本仓库工作区实测（build-debug, gfx1100, O3）。
> 引用格式 `文件:行号`；实测素材在 `AMDGPU-notes/scratch/`（sgpr_stress3.ll / sgpr_stress3_lim.s / ra_log.txt 12859 行 / pipe_log.txt）。
> 素材来源：子代理调研（引用已核实）+ 主会话代写组装。

---

## 7.1 这一层在做什么

NVPTX 的 RA 是空实现（虚拟寄存器名直接打印进 PTX）；AMDGPU 的 RA 是**三段式分 bank 分配**——SGPR、WWM、VGPR 各跑一遍 RAGreedy，中间穿插专用的 spill 降级与提交 pass。这不是"跑了三次 RA"的浪费，而是三类寄存器**语义不可混分**的必然：

| 段 | 寄存器域 | 语义约束 |
|---|---|---|
| 1 | SGPR（标量/uniform） | spill 目标不是栈而是 **VGPR lane**；必须先分配完，物理寄存器 use-list 才能被后续 pass 依赖 |
| 2 | WWM（whole-wave-mode） | "非活跃 lane 也写入"的寄存器，要求独立于普通 VGPR 分配；不允许 spill（分配失败直接 unreachable） |
| 3 | VGPR（向量/divergent） | 主战场，occupancy 的决定项 |

**完整序列**（`AMDGPUTargetMachine.cpp addRegAssignAndRewriteOptimized :2706-2758`）：

```
GCNPreRALongBranchReg(:2711)                    长分支寄存器预留
→ RAGreedy(onlyAllocateSGPRs, "sgpr")(:2714-2718)     ── 第一段
→ VirtRegRewriterPass(false)(:2724)             提交 SGPR 分配（注释 :2720-2723：
                                                 维护物理寄存器 use-list，验证器依赖；
                                                 仅 LiveIntervals 型分配器需要）
→ StackSlotColoring(:2729)                      先合并 SGPR spill 栈槽（注释 :2726-2728：
                                                 必须在 spill 自定义降级**之前**）
→ SILowerSGPRSpills(:2732)                      "Equivalent of PEI for SGPRs"(:2731)
→ SIPreAllocateWWMRegs(:2735)
→ RAGreedy(onlyAllocateWWMRegs, "wwm")(:2738-2742)    ── 第二段
→ SILowerWWMCopies(:2743) → VirtRegRewriter(false)(:2744)
→ AMDGPUReserveWWMRegs(:2745)                   锁定 WWM
→ RAGreedy(onlyAllocateVGPRs, "vgpr")(:2748-2751)     ── 第三段
→ addPreRewrite(:2753 = GCNNSAReassign + AMDGPURewriteAGPRCopyMFMA, :2589-2594)
→ VirtRegRewriter(true)(:2754) → AMDGPUMarkLastScratchLoad(:2756)
```

过滤谓词（决定"每段分什么"）：`onlyAllocateSGPRs(:222-227)`=isSGPRClass；`onlyAllocateVGPRs(:229-234)`=!isSGPRClass；`onlyAllocateWWMRegs(:236-244)`=!isSGPRClass && MFI 的 WWM_REG 旗标。`validateRegAllocOptions(:300-327)` 直接拒绝 Basic/PBQP——**AMDGPU 只支持 Greedy**。

---

## 7.2 insertPass 楔入机制：8 处缝隙的解剖

机制本身：`TargetPassConfig.h:213-214`——"Insert InsertedPassID pass after TargetPassID pass"，即在**通用 pass 流水线的固定缝隙**里楔入目标 pass（new PM `addOptimizedRegAlloc :2661-2697` 8 处 + fast RA 2 处 :2614-2620）：

| # | 缝隙 | 楔入的 pass | 原因 |
|---|---|---|---|
| ① | DetectDeadLanes → | DeadMachineInstrElim(:2662-2663) | RA 前清死代码 |
| ② | LiveVariables → | SIOptimizeVGPRLiveRange(:2669-2671) | VGPR 活跃域收敛 |
| ③ | **PHIElimination →** | **SILowerControlFlow(:2673-2676)** | 见下 |
| ④ | RenameIndependentSubregs → | GCNRewritePartialRegUses(:2678-2679) | 子寄存器重命名 |
| ⑤ | MachineScheduler → | GCNPreRAOptimizations(:2681-2682) | RA 前最后清扫 |
| ⑥ | **MachineScheduler →** | **SIWholeQuadMode(:2684-2686)** | 见下 |
| ⑦ | MachineScheduler → | SIOptimizeExecMaskingPreRA(:2688-2689) | exec mask 布尔化简 |
| ⑧ | MachineScheduler → | SIFormMemoryClauses(:2691-2694, O2+) | 内存子句 |

**两处教科书级注释**：

- **③ PHIElimination→SILowerControlFlow**（:2673-2676）：必须紧跟 phi 消除且在 TwoAddress 之前，否则 SI_ELSE 的 tied operand 处理会 "introduce a copy of the tied operand source after the else"——**多一份冗余 copy**。这是"目标 pass 的时序窗口由通用 pass 的数据依赖决定"的直接证据。
- **⑥ MachineScheduler→SIWholeQuadMode**（:2684-2686）："Allow the scheduler to run before SIWholeQuadMode inserts exec manipulation instructions that cause scheduling barriers"——WQM 会插 exec 翻转指令形成调度屏障，**指令重排窗口必须在屏障产生前用掉**。

**昇腾视角**：dav-m200 上"S 管线读 MTE2 的 UB 需 set_flag/wait_flag 同步"如果做成自动插入 pass，插入位置同样是这类"通用序列缝隙 + 数据依赖窗口"问题——AMDGPU 的 8 处楔入就是 8 个已解案例。

---

## 7.3 SIRegisterInfo：寄存器类宇宙与保留集

**类谓词**（SIRegisterInfo.h:248-303）：isSGPRClass/isVGPRClass/isAGPRClass/isVectorSuperClass/isVSSuperClass——全部基于 InstrInfo 的 TSFlags 位，不是 TableGen 的 string 匹配。

**getReservedRegs(:602-781)** 的保留项分层：
1. 特殊寄存器：MODE/EXEC/FLAT_SCR/M0/SRC_*/TBA/TMA/TTMP 对/SGPR_NULL64
2. SGPR 上限裁剪（:661-676，含 `-amdgpu-stress-sgpr` 测试钩子）
3. 框架寄存器：ScratchRSrc/SP/FP/BasePtr/ExecCopySGPR（:712-715）
4. VGPR/AGPR 上限（:717-750）+ PerLaneVGPRMask 补集（:758-768）
5. WWM 保留（:770-771）

**SGPR→VGPR spill 机制**（本章最精彩处）：
- 开关 `EnableSpillSGPRToVGPR`（:35-39，默认 true）
- `SGPRSpillBuilder`（:98-344）头注释（:76-97）给出完整路径：spill 到栈时 SGPR 先写 VGPR lane，再 buffer_store 到 scratch；期间需保存 exec（**s_not exec, exec 两次技巧**——先关掉全部 lane，让单 lane 写入不干扰别的 wave 成员）

---

## 7.4 SILowerSGPRSpills：SGPR 专属的 "PEI"

文件头自述（:9-16）："takes the place of PrologEpilogInserter for all SGPR spills… **must never create new SGPR virtual registers**"（一旦新建 SGPR vreg 就死循环回第一段）。

`run(:448-632)` 的两条路径：
- **CSR SGPR → 物理 VGPR lane**（:529-536，CFI 信息注释 :521-528）
- **普通 spill → 虚拟 VGPR lane + WWM_REG 旗标**（:556-594）——**降级成 WWM 寄存器交给第二段分配**！
- WWM 池 = 最高端 ≤10 个空闲 VGPR（`determineRegsForWWMAllocation :377-400`，cl::opt MaxNumVGPRsForWwmAllocation=10 :51-54；`assignWWMRegs :402-434` 算 PerLaneVGPRMask 补集）
- `allocateSGPRSpillToVGPRLane`（SIMachineFunctionInfo.cpp:441-483）：**每 wave 64 lane 打包**——64 个 SGPR 值塞进 1 个 VGPR；超 wave 大小回落栈

**实测**（scratch/sgpr_stress3.ll：48 个 uniform 值跨分支存活的压力用例；教训：global load 是 divergent 进 VGPR，必须用 workgroup.id + 常量构造 uniform 值）：

```bash
$ ./build-debug/bin/llc -march=amdgcn -mcpu=gfx1100 -O3 sgpr_stress3.ll
# 基线：TotalNumSgprs 53、零 spill、Occupancy 16
$ ./build-debug/bin/llc -march=amdgcn -mcpu=gfx1100 -O3 -amdgpu-stress-sgpr=32 sgpr_stress3.ll
# 压力：TotalNumSgprs 34、50× v_writelane_b32 + 66× v_readlane_b32、ScratchSize: 0
# → SGPR spill 全走 VGPR lane，一个字节都没落栈
```

`-debug-only=regalloc`（ra_log.txt 12859 行）实测到 **3 次 "GREEDY REGISTER ALLOCATION"**（日志行 816/10250/11556）：#1 区间全 `%N:sreg_32`；#2 是 `%429:vgpr_32 IMPLICIT_DEF` + SI_SPILL_S32_TO_VGPR tied-def（WWM 段）；#3 是剩余 vgpr_32。RAGreedy 的 "cannot spill all interferences. static = 1.5" 决策日志也可见。**三段式不再是源码里的 addPass 序列，而是日志里的三次完整分配过程。**

`-print-after-all`（pipe_log.txt）实测顺序与源码 :2706-2758 一一对应：`phi-node-elimination → si-lower-control-flow → twoaddressinstruction → rewrite-partial-reg-uses → machine-scheduler → si-wqm → greedy → virtregrewriter → stack-slot-coloring → si-lower-sgpr-spills → si-pre-allocate-wwm-regs → greedy → si-lower-wwm-copies → virtregrewriter → amdgpu-reserve-wwm-regs → greedy → amdgpu-rewrite-agpr-copy-mfma → virtregrewriter → stack-slot-coloring`。

---

## 7.5 occupancy 反馈环：寄存器用量的闭式反函数

**正函数**（硬件视角）：`computeOccupancy`（GCNSubtarget.cpp:525-535）= min(MaxOcc, SGPROcc, VGPROcc)。
**闭式反函数**（编译器视角）：AMDGPUBaseInfo.cpp:1380-188——`W = clamp(TotalSGPRs / (alignTo(SGPRs, Granule) + TrapReserve), 1, MaxWaves)`——给定目标 wave 数反推 SGPR 预算，**无需迭代搜索**。

**消费链**（GCNSchedStrategy.cpp）：
```
GCNSchedStrategy::initialize(:136-185)
  TargetOccupancy = MFI.getOccupancy()(:156-157)
  SGPR/VGPRCriticalLimit = ST.getMaxNumSGPRs/VGPRs(TargetOccupancy)(:158-182)
多阶段迭代（GCNMaxOccupancySchedStrategy :775-787）：
  OccInitialSchedule → RewriteMFMAForm → UnclusteredHighRPReschedule
    (:1417-1448, TempTargetOccupancy=Initial+1)
  → ClusteredLowOccupancyReschedule(:1450-1467)
  → PreRARematerialize(:1776-1799, AchievedOcc=min over regions)
```
`GCNRegPressure::getOccupancy`（GCNRegPressure.h:98-103）是每区域 reg 用量→occupancy 的桥（§8 详述）。

**这是一个闭环**：RA 估压 → 调度器定 TargetOccupancy → RA 按预算分配 → 实际占用回填 MFI → 下一轮调度阶段用新 occupancy 重排。**"寄存器压力 = occupancy = 吞吐"的因果链在源码里是显式的。**

---

## 7.6 AGPR 与 WWM 两个特殊族

**AGPR/MFMA**（矩阵核累加寄存器）：
- `AMDGPUPrepareAGPRAlloc.cpp`（120 行，头注 :9-14）：inline imm 物化改写为 AV_*（VGPR+AGPR 联合类）伪指令——"register allocator does not know to replace instructions to relax constraints"，**RA 之前把约束放松成可分配形态**。挂 addPreRegAlloc(:2699-2704)
- `AMDGPURewriteAGPRCopyMFMA.cpp`（778 行，头注 :9-14）：VGPR 形式 MFMA 若 AGPR 化可消 cross-bank copy 且避免 spill 则改写；位于 VGPR greedy 之后、最终 rewriter 之前（addPreRewrite :2589-2594），**调度器还有对应的 RewriteMFMAFormStage**（GCNSchedStrategy.cpp:1038-1039）

**WWM 族**：
- `SIPreAllocateWWMRegs.cpp(:103-127)`：LiveRegMatrix 直配，**失败即 llvm_unreachable**——WWM 表达式寄存器不允许 spill；`rewriteRegs(:129-178)` 后 reserveWWMRegister + freezeReservedRegs
- `AMDGPUReserveWWMRegs.cpp(:85-105)`：扫描 SI_SPILL_S32_TO_VGPR/SI_RESTORE 保留其 VGPR

---

## 7.7 设计动机总结

1. **三段不是三次**：每段之间有实质变换（SGPR spill 物化成 VGPR lane、WWM 锁定），后段依赖前段的物理状态
2. **spill 降级是 pass 不是策略**：SGPR spill 到 VGPR lane 的"64 lane 打包"是独立的 lowering（SILowerSGPRSpills），RA 本体（RAGreedy）对它无感知——**关注点分离的教科书案例**
3. **闭式反函数的工程价值**：occupancy↔SGPR 预算的互逆公式让调度目标免于迭代搜索
4. **"must never create new SGPR vregs" 的不变量**：段间契约靠约定维持（注释声明），没有编译期强制——这解释了为什么这段代码的注释密度异常高

## 7.8 昇腾映射（推理级，待验证）

1. **分 bank 分配**：昇腾 Scalar/Vector 双 bank 天然对应 SGPR/VGPR 分段；PyPTO 若做寄存器层，"先标量后向量 + 标量 spill 进向量 lane"是现成模式（昇腾标量寄存器文件小，压力场景更常见）
2. **WWM 无对应物**：whole-wave-mode 是 SIMT 特有；昇腾 tile 语义下"非活跃 lane 写入"不存在
3. **AGPR ≈ Cube 单元累加寄存器**（未公开验证）：矩阵核独立累加器的分配问题同构
4. **occupancy 反馈环**：昇腾 UB 512KB / TMEM / 寄存器三资源预算若要联动调度，闭式反函数（预算↔吞吐）+ 多阶段迭代（先估后调）的架构可直接平移——比拍阈值科学
5. **insertPass 楔入模式**：PyPTO 若做 pass 化的 tile 流水线，"通用序列缝隙 + 数据依赖窗口"的 8 个案例是现成参考

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| AMDGPUTargetMachine.cpp:222-244, 300-327, 2589-2594, 2614-2620, 2661-2697, 2699-2704, 2706-2758 | 三段式 + insertPass 全序列 |
| TargetPassConfig.h:213-214 | insertPass 机制 |
| SIRegisterInfo.h:248-303 | 类谓词 |
| SIRegisterInfo.cpp:35-39, 76-97, 98-344, 602-781 | 保留集 + SGPR→VGPR spill |
| SILowerSGPRSpills.cpp:9-16, 377-434, 448-632 | SGPR PEI |
| SIMachineFunctionInfo.cpp:441-483 | 64-lane 打包 |
| GCNSubtarget.cpp:483-535 | computeOccupancy |
| AMDGPUBaseInfo.cpp:1380-1388 | 闭式反函数 |
| GCNSchedStrategy.cpp:136-185, 775-787, 1038-1039, 1417-1467, 1776-1799 | occupancy 消费链 |
| GCNRegPressure.h:98-103 | 每区域 occupancy 桥 |
| AMDGPUPrepareAGPRAlloc.cpp:9-14 / AMDGPURewriteAGPRCopyMFMA.cpp:9-14 | AGPR 族 |
| SIPreAllocateWWMRegs.cpp:103-178 / AMDGPUReserveWWMRegs.cpp:85-105 | WWM 族 |

实测素材：scratch/sgpr_stress3.ll（SGPR 压力用例）、sgpr_stress3_lim.s（stress-sgpr=32：50 writelane + ScratchSize 0）、ra_log.txt（3 次 GREEDY 日志）、pipe_log.txt（全流水线顺序验证）。
