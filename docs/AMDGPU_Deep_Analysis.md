# AMDGPU 后端深度分析

> 数据基准：llvm-project main @ `3eda2aebadd4`（2026-09-28），本仓库工作区实测。
> 方法：静态分析（引用一律 `文件:行号`，全部经 grep/read 核对）+ 动态验证（build-debug llc/opt/llvm-mca/llvm-readelf 实跑）。
> 姊妹篇：`nvptx-vs-amdgpu-analysis.md`（横向对比）。本文档是纵向深潜——按数据流（IR→ELF）逐层拆解 AMDGPU 内部机理。
> 素材全文：`AMDGPU-notes/01..08-*.md`（约 2200 行，每章完整版）；scratch/ 存全部实测产物。

---

## 目录

- §1 摘要与阅读指南
- §2 宏观架构（target 注册/26 hook/三代演进/地址空间超载）
- §3 IR 层 pass 群（17 pass + 7 处 EP callback）
- §4 PreISel 结构化控制流（11 个 function pass 链 + LCSSA 考古）
- §5 指令选择双路径（SDAG vs GISel，事后修复 vs 前置保证）
- §6 寄存器分配三段式（SGPR→WWM→VGPR + occupancy 闭环）
- §7 机器调度（5-stage 多目标 + 分域计压 + Revert 回退链实测）
- §8 PostRA/PreEmit（addPreEmitPass 内 14 pass；waitcnt 记分板 + hazard 表驱动）
- §9 MC 层与 Code Object（msgpack 元数据 + COV 演进考古）
- §10 官方文档对照表
- §11 昇腾启示录（7 项迁移路径）
- §12 复现手册（全部命令）

---

## §1 摘要与阅读指南

**核心论点**：AMDGPU 是 LLVM 中"编译器内闭环"的极端形态。其 30.0 万行代码（`git ls-files llvm/lib/Target/AMDGPU | xargs wc -l` = 300,109）与目标专属 pass（AMDGPUPassRegistry.def 注册 78 条：MODULE 14+FUNCTION 15+MACHINE_FUNCTION 48+CGSCC 1）不是工程冗余，而是三重约束下的**必要复杂度**：

1. **物理 ISA**（LLVM 直出 ELF 机器码）→ 编码/hazard/内存一致性必须显式建模
2. **多发射资源管理**（SGPR/VGPR/AGPR 分域 + occupancy）→ RA 与调度必须耦合
3. **wave 编程模型**（exec mask + reconvergence 契约）→ 控制流必须结构化

本文档按数据流逐层证明：每层的 pass 群都对应一组可指认的硬件约束，删掉任何一个都会产生错误代码或显著性能损失。§11 将此映射到昇腾编译栈给出迁移路径。

**每章统一骨架**：做什么 → 静态分析 → 动态验证 → 设计动机 → 昇腾映射。

---

## §2 宏观架构

**详见 `AMDGPU-notes/01-architecture.md`（825 行）**

- **一个注册 target、三代硬件谱系**：`def AMDGPU : Target`（AMDGPU.td:2817）+ `def R600 : Target`（AMDGPU/R600.td:27，无 R600/ 子目录）双 TableGen 入口；C++ 侧 AMDGPUTargetMachine（基类）→ GCNTargetMachine（gfx6-13）/R600TargetMachine（VLIW4/5 遗产）
- **行号口径**：本文 AMDGPUTargetMachine.cpp 的挂点行号均指**新 PM 路径**（AMDGPUCodeGenPassBuilder）；legacy GCNPassConfig 同构代码在同文件 ：1722-2100（偏移约 900 行），读者 grep 对照时注意区分
- **target 正名**：`amdgpu` triple 2026-07（commit `24a5231188bf`）引入，`amdgcn` 变 legacy 别名（AMDGPUTargetInfo.cpp:31-32 注释："should be removed when all tool users of amdgcn are migrated"）——但 MC 层未同步（§9 interop 陷阱）
- **函数级 subtarget 缓存**：GCNTargetMachine::getSubtargetImpl（:1350-1408）按 SubtargetKey（GPU+FS+xnack/sramecc/OOB）为每个函数缓存独立 subtarget
- **26 个 CodeGenPassBuilder hook**（:163-189），SDAG 与 GISel 路径互斥挂载
- **特性 gate 三种形态**：Generation 枚举（粗 gate）+ TableGen 布尔（MAIInsts/VOPDInsts）+ 数值（LDSBankCount/log2 wavefrontsize）；GCNProcessors.td 62 个 def + 18 个 alias，gfx600(:24) 到 gfx1310(:332)
- **地址空间超载**：枚举定义在 `llvm/include/llvm/Support/AMDGPUAddrSpace.h:28-105`（不在后端目录）——0-18 共 19 个 AS + 内部 AS 128（STREAMOUT_REGISTER）；**12 号空缺**、VGPR=13、BARRIER=15、CB0-15=8..23；`addrspacesMayAlias` 16×16 布尔矩阵（AMDGPU.h:691-722）让 LOCAL×GLOBAL 直接 NoAlias——"存储层级建模为互不别名 AS"免费复用 AA
- **三代演进时间线**（git 考古）：R600 合入（2012-12-11，`75aadc281382`）→ 改名 AMDGPU（2015-06-13，`45bb48ea197f`）→ RDNA wave32（gfx1010 2019-04-24，`cee607e4144e`）→ CDNA MFMA（gfx908 2019-07-09，`22b2c3d6511d`）→ VOPD（2022-06-23，`d1af09ad9617`）

**实测**：mfma intrinsic gfx90a 可选/gfx1100 报错；`+wavefrontsize32` gfx90a 在 AMDGPULegalizerInfo.cpp:800 崩 `assert(ST.hasMad64_32())`——**现象对但归因要准确**：这不是 wavefrontsize 互斥检查（那是 GCNSubtarget.cpp:207-215 的 DiagnosticInfoUnsupported 诊断，且此场景未触发），而是 gfx90a（CDNA2，原生 wave64）强开 wave32 后特性集解析连锁走偏、撞上不相关断言——LLVM 特性检查顺序脆弱性的活标本；gfx1100（RDNA3，原生 wave32）通过。

---

## §3 IR 层 pass 群（17 pass + 7 处 EP callback）

**详见 `AMDGPU-notes/02-ir-layer.md`**

- **双通道注入**：CodeGen addIRPasses（legacy :1565-1668 / 新 PM :2366-2448 镜像）+ **7 处 EP callback**（:1021-1137：ScalarOptimizerLate/VectorizerEnd/PipelineEarlySimplification/Peephole/CGSCCOptimizerLate/OptimizerLast/FullLinkTimeOptimizationLast）——NVPTX 仅 2 处 EP（在 NVPTXCodeGenPassBuilder.cpp:325/:342，非 TargetMachine 文件），架构含义：需要模块级信息的 lowering（LDS 规划/closed-world Attributor/printf 绑定）下沉到优化器 EP，在 LTO 正确时机触发
- **顺序约束四例**：LowerModuleLDS 必须先于 PromoteAlloca（:1612 注释 "Runs before PromoteAlloca so the latter can account for function uses"，LDS 调用点在 :1613-1615、PromoteAlloca 在 :1627——两者并不相邻，中间隔 AtomicOptimizer/AtomicExpand）；AtomicOptimizer→AtomicExpand（:1617-1624）；AlwaysInline+Inliner 成对（:1593-1595 "Function calls are not supported"）；LowerBufferFatPointers 挤在 CGP 和 LowerSwitch 之间（注释块 :1683-1690，调用 :1691，LowerSwitch :1699）
- **PromoteAlloca 双策略实测**：8xi32→`<8 x i32>` 向量提升（freeze+insert/extract）；40 elem 超预算（MaxVectorRegs=32, ratio=4）被拒；LDS 回退路径 `[WGS x Ty]` 全局 + **WGS=1600 截断到 1024、336B 卡 occupancy 分档**
- **LowerModuleLDS**：文件头 :9-177 是完整设计文档（AMDGPULowerModuleLDSPass.cpp；Module/Table/Kernel/Hybrid 四策略表 :62-65）；per-kernel 帧布局 {module.lds, pad, kernel instance, pad, dynamic}
- **管线化石**：RewriteOutArguments 只注册 initialize（INITIALIZE_PASS 在 RewriteOutArguments.cpp:110-113；TargetMachine 侧 initialize 调用在 AMDGPUTargetMachine.cpp:738）未接线——"退役未删"活样本

---

## §4 PreISel 结构化控制流

**详见 `AMDGPU-notes/03-structurize.md`**

- **因果链**：GCN 分支仅两种形态（uniform→s_cbranch_scc / divergent→exec mask 操作，AMDGPUISelDAGToDAG.cpp:2904 `UseSCCBr = isCBranchSCC && isUniformBr`；v_cmpx 直写 EXEC 的定义在 VOPCInstructions.td:416-453 `let Defs=[EXEC]`）→ reconvergence 需要结构化点 → irreducible CFG 不可执行 → **11 个 function pass + 1 个 module pass 链**（addPreISel :2485-2519；PerfHint :2517 为 module pass；legacy GCNPassConfig 同构在 :1722-1755）
- **顺序不可换**（注释背书）：UDE→FixIrreducible→ULE→StructurizeCFG——"StructurizeCFG won't recognize the multi-exit regions formed by them"（:2493-2494）
- **SIAnnotateControlFlow**：五个 amdgcn intrinsic 注入——amdgcn_if（:191）/amdgcn_else（:208）/amdgcn_if_break（:223）/amdgcn_loop（:290）/amdgcn_end_cf（:335）；处理完栈必须空否则 `report_fatal_error("failed to annotate CFG")`（:384）——结构化不变量的编译期断言
- **LCSSA 考古**：GISel 跳过 LCSSA 由 commit `3ad810ea9a97`（2025-03-12）引入，为 temporal divergence 铺路——"新路径甩掉老路径包袱"的直接证据
- **PerfHint 跨层流向**：IR 画像（AMDGPUPerfHintAnalysis.cpp:304/:311 写 amdgpu-memory-bound/amdgpu-wave-limiter 属性）→ fn attr → 基类构造读取（AMDGPUMachineFunctionInfo.cpp:52-56，非 SIMachineFunctionInfo.cpp）→ getMinAllowedOccupancy（SIMachineFunctionInfo.h:1214-1218）→ 调度器 occupancy 下限（7 处消费点）
- **实测对照**：uniform 分支 `s_cmp + s_cbranch_scc1` 零 exec 操作 vs divergent `v_cmpx` 直写 EXEC + saveexec/xor/or

---

## §5 指令选择双路径

**详见 `AMDGPU-notes/04-isel.md`**

- **修正误称**：SDAG selector 是 AMDGPUISelDAGToDAG.cpp（4816 行）；waterfall 在 AMDGPURegisterBankInfo::executeInWaterfallLoop（不在 LegalizerInfo）
- **GISel 流水线**：IRTranslator(:1796-1797)→Legalizer(:1808)→DivergenceLowering(:1815)→**RegBankSelect(:1819)+RegBankLegalize(:1820)**→InstructionSelect(:1829-1830)（legacy GCNPassConfig 同构路径在同文件 :1848-2060，行号偏移约 900）
- **核心论点——事后修复 vs 前置保证**：SDAG 的 SIFixSGPRCopies（选后扫非法 copy 转 VALU，信息已丢失只能保守）vs GISel 的 RegBankLegalize（选择前按 uniformity 主动 lower，信息完整）——**"约束不满足时前置 lower 优于事后修复"是 LLVM 自己的经验教训**
- **waterfall 精读**（RBI :773）：4 块拆分 + readfirstlane + VCC ICMP_EQ + ballot→s_and_saveexec→s_xor + SI_WATERFALL_LOOP 伪指令 + EXEC 保存/恢复
- **fallback 物质基础**：llvm/lib/CodeGen/ResetMachineFunctionPass.cpp:30-66（hasFailedISel→MF.reset() :59 重建）+ TargetPassConfig.cpp:1075-1085（失败后仍挂 SDAG selector，回退挂载点 :1084）
- **MIR diff 实测**：SDAG `V_FMA_F32_e64` vs GISel `V_FMAC_F32_e64`（收缩约定不同，isel_diff.txt:139/:161）；分支极性相反；GISel bank 注解 `%NN:vgpr_32` 直接可见；SMEM/VMEM 决策两路径一致

---

## §6 寄存器分配三段式

**详见 `AMDGPU-notes/05-regalloc.md`**

- **三段序列**（:2706-2758，新 PM）：RAGreedy(SGPR)→VirtRegRewriter→StackSlotColoring→SILowerSGPRSpills→SIPreAllocateWWMRegs→RAGreedy(WWM)→SILowerWWMCopies→VirtRegRewriter→AMDGPUReserveWWMRegs("锁定")→RAGreedy(VGPR)→PreRewrite→VirtRegRewriter——**段间有实质变换**（SGPR spill 物化成 VGPR lane、WWM 预分配与锁定、WWM copy 降级），非简单三次
- **insertPass 8 处楔入**（:2661-2697）：教科书级注释两处——PHIElimination→SILowerControlFlow（:2673-2676，否则 tied operand 多一份 copy）；MachineScheduler→SIWholeQuadMode（:2684-2686，WQM 屏障前用掉重排窗口）
- **SGPR spill 64-lane 打包**（SIMachineFunctionInfo.cpp:441-483 `allocateSGPRSpillToVGPRLane`：按 VGPR lane 逐槽分配，LaneIndex=NumSpillLanes%WaveSize，MAX_LANES=64）：64 个 SGPR 值塞 1 个 VGPR；**实测 `-amdgpu-stress-sgpr=32`：50×v_writelane + ScratchSize: 0**——spill 全走 VGPR lane 不落栈
- **occupancy 闭式反函数**（Utils/AMDGPUBaseInfo.cpp:1380-1388 `getOccupancyWithNumSGPRs`）：目标 wave 数直接反推 SGPR 预算，调度免迭代
- **实测三段**：`-debug-only=regalloc` 日志 3 次 "GREEDY REGISTER ALLOCATION"（行 816/10250/11556）与源码一一对应
- **段间不变量**："must never create new SGPR vregs"（SILowerSGPRSpills.cpp:9-16）靠注释约定——解释了这段代码注释密度异常高

---

## §7 机器调度

**详见 `AMDGPU-notes/06-sched.md`**

- **5-stage 多目标**（GCNSchedStrategy.cpp:775-786 GCNMaxOccupancySchedStrategy 构造，stage 压入 :778-783；枚举定义 GCNSchedStrategy.h:39-49）：OccInitial→RewriteMFMAForm→UnclusteredHighRP→ClusteredLowOcc→PreRARemat；`schedule()` 只记录 region（:1058-1062），实际调度延迟到 finalizeSchedule（:1197-1212 调 runSchedStages :1213-1269）——跨 region 信息可见
- **分域计压**（GCNRegPressure.h:32-195）：4 域 SGPR/VGPR/AGPR/AVGPR；`less` 四级比较 occupancy→spill→tuple→raw（spill 级含 SGPR→VGPR 换算 divideCeil(SGPR,WaveSize)）
- **迭代调度**（GCNIterativeScheduler，645 行）：四策略；跨 region 的寄存器再分配是全局问题，单 region 贪心只能局部最优——sortRegionsByPressure 按压力降序排序（:446-450）+ tryMaximizeOccupancy 尝试各 region 提 occupancy（:461-501）近似全局解
- **实测回退链**（400 divergent loads，VGPR=192>93）：Initial Schedule Excess→UnclusteredHighRP **逐 region Reverting**→ClusteredLowOcc 换目标（VGPRCriticalLimit 93→38→62→69 动态变化）——多阶段"试解→回退"完整捕捉
- **实测教训**：uniform load 走 SMEM 不占 VGPR、同址 load 被 CSE——构造 VGPR 压力必须 divergent 基址
- **发射级优化族**：VOPD 双发射配对（GCNVOPDUtils.cpp:339-397 tryMatchVOPDPair，literal 预算≤2 在 :301-307、bank 约束在 :325-327）、MacroFusion、NSA 重排、ExportClustering
- **IGroupLP**（gfx950+）：SCHED_GROUP_BARRIER 位掩码指令组约束——与 dav-m200 指令组同步语义同构

---

## §8 PostRA/PreEmit（addPreEmitPass 内 14 pass；跨 addPreSched2→addPreEmit 全段 17）

**详见 `AMDGPU-notes/07-postemit.md`（364 行，子代理自写）**

- **SIInsertWaitcnts 精读**（3775 行）：WaitcntBrackets 记分板（LB/UB 括号 + VMem/SGPRs/SCC 三张 DenseMap 按寄存器记分，:479-831）；生产侧 updateByEvent（:892-1108）→ 消费侧 generateWaitcntInstBefore（:2331-2634）→ 三域合并编码单条 S_WAITCNT（:1797-1888 createNewWaitcnt，VScnt 独立指令）；RPO 块间不动点 merge（run() :3478 起，BlockInfos :3560，merge 主体 :3612-3624，do-while 闭合 :3634）
- **PostRAHazardRecognizer 独立成 pass 的原因**（:2802-2809）：post-RA 调度器按区域自底向上，**跨区域相邻指令的 hazard 它看不到**——发射前全局再查
- **GCNHazardRecognizer 精读**（4361 行）：三模式（PreRA/PostRA/HazardRecognizerMode）+ 双查询引擎（EmittedInstrs 窗口 vs 跨块逆向 getWaitStatesSince :963-1041）；5 类代表：SMRD 读改写（checkSMRDHazards :1175）、VMEM→标量写 DEPCTR（fixVMEMtoScalarWriteHazards :1831）、Vcmpx→Permlane 修复（fixVcmpxPermlaneHazards :1796）、TRANS 图状态机（fixVALUTransUseHazard :2336，StateType :2369-2415）、软子句（breaksSMEM/VMEMSoftClause+checkSoftClauseHazards :1119-1170）
- **SIModeRegister**：MODE 寄存器三阶段数据流（processBlockPhase1/2/3，:262-435）——**只跟踪 FP_ROUND_MODE_DP（DP round mode）**，IEEE/dx10clamp/denormal 比特定义在 SIDefines.h:802-803 但本 pass 未使用；实测（constrained.fptrunc round.downward）`S_SETREG_IMM32_B32 1, 129/193/2177, implicit-def $mode` 是 round-mode 编码
- **AMDGPUInsertDelayAlu**（gfx11+）：DelayInfo 双槽+借槽编码；实测 `s_delay_alu instid0(SALU_CYCLE_1)|instskip(NEXT)|instid1(SALU_CYCLE_1)`——一条指令表达两条依赖
- **SIShrinkInstructions 挂点修正**：实际在 addPreSched2（:2767-2771）而非 PreEmit
- **官方文档对照**：AMDGPUExecutionSynchronization.md（541 行，在 llvm/docs/ 下非 AMDGPU/ 子目录）只讲栅栏语义（GFX6-11 barrier 序列 :262-266；与代码对应点：字面 `s_waitcnt vmcnt(0) expcnt(0) lgkmcnt(0)` 逐字同串处在 SIInsertWaitcnts.cpp:50 的 cl::opt desc，同语义实现在 :2575-2577），**不含计数模型**——后者只存在于源码

---

## §9 MC 层与 Code Object

**详见 `AMDGPU-notes/08-mc-obj.md`**

- **MCTargetDesc 23 文件 7030 行**：InstPrinter 1974/TargetStreamer 1275/MCCodeEmitter 790/…；注册表 :195-231（AMDGPUMCTargetDesc.cpp，LLVMInitializeAMDGPUTargetMC；R600+GCN+GCNLegacy 三 target 共享基础设施）
- **HSA metadata 管线**：MetadataVerifier(Strict).verify→msgpack writeToBlob→EmitNote(NT_AMDGPU_METADATA=32)（MCTargetDesc/AMDGPUTargetStreamer.cpp:1076-1100）；V5+ 隐式参数（kernarg）布局：HiddenArgs[] 偏移表在 AMDGPUPreloadKernelArguments.cpp:95-97（0-22 字节 9 项：_hidden_block_count_xyz/group_size_xyz/remainder_xyz），隐式指针族 PreloadedValue 枚举在 AMDGPUArgumentUsageInfo.h:106（IMPLICIT_ARG_PTR=16）
- **COV 演进考古**：2017 YAML→2019-03 msgpack（`ed0b9af9973e`）→2021 COV4/TargetID→2024 COV6；每版本保留约 2 年再删——格式生命周期范本
- **AsmParser 11029 行的存在理由**：汇编→code object 独立于 clang 的路径（ROCm .s interop）；`.amdhsa_kernel` ~40 个子指令逐位填 64B kernel descriptor
- **V5+ 隐式参数**：见上条 HSA metadata——kernarg 段隐藏参数由 HiddenArgs[] 显式表驱动（AMDGPUPreloadKernelArguments.cpp:95-97），加载链 IsV5OrAbove 分叉在 AMDGPULowerKernelAttributes.cpp:79-80/:473-475（amdgcn_implicitarg_ptr vs queue_ptr 基址）
- **仅 1 个 target fixup** 的克制：fixup_si_sopp_br；其余复用通用 FK_Data_*+MCExpr specifier
- **实测**：msgpack note 二进制（`83 ae "amdhsa.kernels"`）、kd 符号 REL64+STV_PROTECTED、llvm-mc 汇编路径成功；**interop 陷阱**：llc 自印的 `amdgpu-` target id 被 llvm-mc 拒绝（须 `amdgcn-amd-amdhsa--gfx1100`）——正名遗留的下游断裂
- **PAL vs HSA 分野**：PAL wave 调度实际用 rsrc1 寄存器值（msgpack 计数仅 advisory）——图形/计算两消费模式的元数据哲学差异

---

## §10 官方文档对照表

| 文档 | 覆盖 | 缺口（本文档补充） |
|---|---|---|
| AMDGPUUsage.rst | triple/feature 入门 | 函数级 subtarget 缓存机制 |
| AMDGPU/DeveloperGuideline.rst | 后端开发者守则 | 26 hook 逐个的 pass 计数 |
| AMDGPUMemoryModel.md | 内存模型语义 | 与 waitcnt 记分板的映射（执行在 SIMemoryLegalizer，本文未展开） |
| AMDGPUExecutionSynchronization.md | barrier/栅栏语义（GFX6-11） | **计数模型只在源码**（§8） |
| AMDGPUInstructionSyntax/ModifierSyntax/OperandSyntax/Notation | 汇编语法 | AsmParser 内部结构 |
| AMDGPUAsyncOperations/DMAOperations | async 操作 | — |
| AMDGPUDwarfExtensions | 异构调试 | — |

（注：本仓工作区另有一份未跟踪的 `llvm/docs/AMDGPU-Design.rst` 系自制综述，非上游文档，不列入对照。）

**结论**：官方文档覆盖"用户可见契约"（语法/语义/ABI），编译器内部机理（记分板算法/调度 stage/三段式 RA）零文档——本文档全部来自源码+实测。

---

## §11 昇腾启示录（7 项迁移路径）

每项格式：**AMDGPU 机制 → 昇腾对应物 → 迁移步骤**。（推理级标注"待验证"处需 ascend-kernel-docs 佐证）

### 11.1 waitcnt 记分板 → MTE set_flag/wait_flag 自动插入
**机制**：WaitcntBrackets 按寄存器记分 + 消费点前插最小等待（§8）。
**对应物**：昇腾 MTE1/2/3 与 S/V 管线间的 set_flag/wait_flag（目前手工插入，S 管线读 MTE2 的 UB 无同步保障是已知坑）。
**迁移步骤**：① 把"管线 ID×事件类型"做成计数器枚举（对应 InstCounterType）② 按数据寄存器（UB offset/TMEM addr）记分 ③ 消费指令前生成 wait ④ RPO 不动点处理跨块。3775 行的 SIInsertWaitcnts 是第一参考实现。

### 11.2 GCNHazardRecognizer 表驱动 → dav-m200 发射约束表
**机制**：getWaitStatesSince 逆向查询 + hasHazard<StateT> 泛型检查（§8）。
**对应物**：dav-m200 "set_cmpmask 仅装载后第一条 vsel 有效（多 repeat 不可用）"这类发射约束目前靠 ST 测试兜底。
**迁移步骤**：① 把约束写成 (前驱指令类, 后继指令类, 距离阈值, 修复动作) 四元组表 ② 逆向扫描查询 ③ 修复动作限定 NOP 插入/指令替换两类。

### 11.3 地址空间超载 → UB/TMEM/GM 统一视图
**机制**：非内存资源（VGPR=13/BARRIER=15）建模成 AS + addrspacesMayAlias 矩阵（§2）。
**对应物**：PyPTO 的 UB/TMEM/GM 视图统一表达。
**迁移步骤**：① 分配互不冲突的 AS 编号 ② 填 alias 矩阵（UB×GM NoAlias 等）③ AS 感知的 AA/推断免费获得。

### 11.4 GCNRegPressure 分域计压 → UB 512KB/TMEM/寄存器预算
**机制**：4 域模型 + occupancy 闭式反函数 + less 四级比较（§6/§7）。
**对应物**："一个 tile 放哪、放几个"的 occupancy 规划（目前拍阈值）。
**迁移步骤**：① 三资源各自计压 ② 预算↔吞吐闭式互推 ③ 比较序 (吞吐→溢出→打包→原始) ④ 多 stage 试解+回退。

### 11.5 三段式 RA + insertPass 楔入 → 标量/向量双 bank 分配
**机制**：分 bank 分配 + bank 间专用 spill 降级 pass + 通用序列缝隙楔入（§6）。
**对应物**：昇腾 Scalar/Vector 双 bank；标量 spill 进向量 lane 模式。
**迁移步骤**：① 先标量后向量两段 ② 标量 spill 降级成独立 pass ③ 段间不变量显式文档化（AMDGPU 用注释，建议改断言）。

### 11.6 SDAG+GISel 双路径 → 指令选择层重写路线图
**机制**：MF.reset() 可回退 + 条件 LCSSA + fallback 三态（§5）。
**对应物**：PyPTO tile 算子选择若从"模式匹配"升级到"模式匹配+资源约束"两层。
**迁移步骤**：① 新路径失败可回退老路径（reset 机制）② 约束前置（RegBankLegalize 模式）优于事后修复（SIFixSGPRCopies 模式）③ 老路径包袱（LCSSA 类）新路径直接甩。

### 11.7 COV 版本生命周期 + msgpack 元数据 → 编译产物版本管理
**机制**：版本字段+Verifier+保留 2 年再删（§9）。
**对应物**：CCE 版本碎片（m200/m300…）的产物兼容管理。
**迁移步骤**：① 产物带版本字段 ② 消费端 Verifier 校验+降级 ③ 旧版本明确退役时间表。

---

## §12 复现手册

> 前置说明：① 仓库 main @ `3eda2aebadd4`，构建 `./build-debug.sh`（Debug+Assertions，targets=AMDGPU;NVPTX;AArch64）；② 2026-07 起 `-march=amdgcn` 不带 subarch 会打 deprecation 警告（"codegen with no subarch in the target triple is deprecated"）——统一改用 `-mtriple=amdgcn-amd-amdhsa` 消除；③ 所有输入文件都在 `AMDGPU-notes/scratch/`（57 个），占位符已全部落实为实名。

```bash
cd ~/code/llvm-project
BD=build-debug

# 冒烟
echo 'define i32 @f(i32 %a, i32 %b) { ret i32 %a }' > /tmp/smoke.ll
$BD/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -debug-only=isel -o /dev/null /tmp/smoke.ll

# §3 PromoteAlloca 向量化/LDS 回退（用上游测试文件；注意不同 -mtriple 会改变默认
# flat-work-group-size，进而改变 LDS 提升决策——63/1600 档的提升与否随之变化）
$BD/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -print-after=amdgpu-promote-alloca -o /dev/null \
    llvm/test/CodeGen/AMDGPU/large-work-group-promote-alloca.ll 2>&1 | grep "IR Dump After"
$BD/bin/opt -S -mtriple=amdgcn-amd-amdhsa -passes=amdgpu-promote-alloca -disable-promote-alloca-to-vector \
    llvm/test/CodeGen/AMDGPU/large-work-group-promote-alloca.ll

# §5 ISel 双路径 diff（scratch/isel_test.ll：workitem.id + fmuladd + 分支）
$BD/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O3 -stop-after=instruction-select -o /tmp/sdag.mir AMDGPU-notes/scratch/isel_test.ll
$BD/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O3 -global-isel -stop-after=instruction-select -o /tmp/gisel.mir AMDGPU-notes/scratch/isel_test.ll
diff /tmp/sdag.mir /tmp/gisel.mir | grep -E "V_FMA|V_FMAC|vgpr_32" | head

# §6 RA 三段
$BD/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O3 -amdgpu-stress-sgpr=32 -filetype=asm -o - AMDGPU-notes/scratch/sgpr_stress3.ll 2>/dev/null | grep -cE "v_writelane|v_readlane"   # =116
$BD/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O3 -amdgpu-stress-sgpr=32 -filetype=asm -o - AMDGPU-notes/scratch/sgpr_stress3.ll 2>/dev/null | grep -c "v_writelane"                  # =50
$BD/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O3 -debug-only=regalloc -o /dev/null AMDGPU-notes/scratch/sgpr_stress3.ll 2>&1 | grep -c "GREEDY REGISTER ALLOCATION"               # =3

# §7 调度回退链（注意必须 divergent 基址）
$BD/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O3 -debug-only=machine-scheduler -o /dev/null AMDGPU-notes/scratch/sched_hp5.ll 2>&1 | grep -E "Revert|stage:"

# §8 waitcnt/hazard（waitcnt_test.ll 含 buffer→fmul→store；hazard_out.mir 含 vcmpx/permlane）
$BD/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -debug-only=si-insert-waitcnts -o /dev/null AMDGPU-notes/scratch/waitcnt_test.ll
$BD/bin/llc -mtriple=amdgcn-amd- -mcpu=gfx1100 -run-pass=post-RA-hazard-rec -o - AMDGPU-notes/scratch/hazard_out.mir

# §9 MC/ELF
$BD/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -filetype=obj -o /tmp/x.o AMDGPU-notes/scratch/waitcnt_test.ll && $BD/bin/llvm-readelf -a /tmp/x.o | head -50
# llvm-mca：llc 用 amdgcn-amd-amdhsa 生成的 .s 带 .amdgcn_target，llvm-mca 直接可跑
$BD/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -filetype=asm -o /tmp/k.s AMDGPU-notes/scratch/waitcnt_test.ll
$BD/bin/llvm-mca -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -all-stats /tmp/k.s | head -10
```

全部 scratch 实验素材：`AMDGPU-notes/scratch/`（57 个文件，含所有实测 .ll/.mir/.log/.s）。

---

## 附录：章节-素材对照

| 章 | 素材文件 | 行数 | 产出方式 |
|---|---|---|---|
| 基线 | 00-baseline.md | 51 | 主会话 |
| §2 | 01-architecture.md | 825 | 子代理（一次成盘） |
| §3 | 02-ir-layer.md | 197 | 子代理调研+主会话验证代写 |
| §4 | 03-structurize.md | 174 | 子代理调研+主会话代写 |
| §5 | 04-isel.md | 115 | 子代理调研+主会话验证代写 |
| §6 | 05-regalloc.md | 178 | 子代理调研+主会话代写 |
| §7 | 06-sched.md | 133 | 子代理调研+主会话补实验代写 |
| §8 | 07-postemit.md | 369 | 子代理自写+主会话补 patch |
| §9 | 08-mc-obj.md | 148 | 子代理调研+主会话代写 |

（素材合计 2190 行。）

执行注记：本项目由 1 个主会话 + 11 个子代理实例完成（含 3 次因网关重启/卡死的重派）。素材层的 `文件:行号` 引用经实际 grep/read 核对；正文层引用曾于 2026-09-29 复审（4 路并行核查 62 条断言 + §12 全命令实跑），修正 6 处实质错误与 19 处行号/文件名漂移，详见修订说明。动态验证命令全部实跑，输出可在 scratch/ 复核。
