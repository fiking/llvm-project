# NVPTX vs AMDGPU:LLVM 两大 GPU 后端实现差异分析

> 数据基准:llvm-project main @ `3eda2aebadd4`(2026-09-28),本仓库工作区实测。
> 所有行数均为 `wc -l` 原始计数(cpp+h+td),引用均带 `文件:行号`,可直接跳转核对。

---

## 1. 摘要

NVPTX 和 AMDGPU 是本文选取的两个面向 NVIDIA / AMD 现代 GPU 的 LLVM 后端,它们对"编译器职责边界"给出了两个截然相反的答案:

- **NVPTX 是虚拟 ISA 后端**:LLVM 只产出 PTX 文本,寄存器分配、面向 SASS 的最终指令调度、硬件 hazard、真实机器码(SASS)全部交给 NVIDIA 闭源的 ptxas(程序级异步同步协议如 cp.async.wait_group 由 LLVM 显式转译,见 §9)。
- **AMDGPU 是物理 ISA 后端**:LLVM 直达 ELF code object,SGPR/VGPR 寄存器宇宙、wave 模型、内存一致性、发射打包,每个硬件细节都在 LLVM 内显式建模。

一句话:**下游闭源编译器是"减法",LLVM 内闭环是"加法"**。两边约 8 倍的代码规模差距(3.7 万行 vs 29.9 万行)与此高度相关——职责边界决定了哪些工作必须在 LLVM 内实现,是规模差异的主要结构性来源;但不是唯一来源:AMDGPU 还包含 R600 遗产(约 1.35 万行)、SDAG/GISel 双指令选择路径(三大件约 2.24 万行)、graphics/矩阵核调度支持(IGroupLP 含 MFMA GEMM 策略、ExportClustering、WholeQuadMode 等)与 gfx600–gfx1310 十余代架构覆盖。"剔除这些成分后的核心差距"暂不给出数字——这些成分与职责边界驱动的代码相互交织(如 IGroupLP 同时服务 graphics 与 GEMM),需要不重叠的文件分类才能算清;可确认的是全目录约 8 倍的量级与方向。对任何自研加速器编译栈(包括昇腾)而言,这是第一位的架构决策,先于任何 pass 设计。

---

## 2. 规模总览

| 维度 | NVPTX | AMDGPU | 倍差 |
|---|---|---|---|
| 文件数(cpp+h+td) | 72 | 342 | 4.7x |
| 总行数 | 37,258 | 299,179 | 8.0x |
| TableGen(.td)行数 | 10,877 | 57,857 | 5.3x |
| 回归测试(.ll) | 582 | 3,512 | 6.0x |
| TargetMachine.cpp | 384 行 | 2,858 行 | 7.4x |
| ISelLowering.cpp | 8,143 行(NVPTX) | 21,639 行(SI) | 2.7x |
| 内建函数(.td def 行 / **展开后**) | 328 / **2797**(int_nvvm) | 670 / **1469**(int_amdgcn) | AMDGPU/NVPTX = 2.04x / 0.525x |
| 处理器覆盖 | sm_20 … sm_121(+f/a 家族变体) | gfx600 … gfx1310 + r600 遗产 | — |
| 注册的 target | nvptx / nvptx64 | amdgcn(注册名 amdgpu;amdgcn 为 legacy 别名)、r600 | — |

注意几个"不对称"的地方,后文逐一展开:

- `AMDGPUTargetMachine.cpp` 全文件有 143 次 `addPass(` 匹配,但这是 legacy 流水线与新 PM callback 的**混合计数**,不构成单一流水线长度;统一静态口径(§5.7)下目标专属 pass 类为 63 个(SDAG)/66 个(GISel),NVPTX 同口径 22(+2 个 EP 新增类型,其中 CopyByValArgs 默认关闭)。
- AMDGPU 有 AsmParser(11,029 行)、Disassembler(3,208 行)、MCCodeEmitter(790 行)、MCA 自定义行为;**NVPTX 这四样全部没有**,MC 层为 InstPrinter + MCAsmInfo + MCTargetDesc + TargetStreamer(`MCTargetDesc/CMakeLists.txt:1-5`)——后三类是目标描述基础设施,不算"缺件"。
- AMDGPU 有完整 GlobalISel 路径(22,416 行);NVPTX **零 GISel 文件**。

---

## 3. 根因:职责边界的两种切法

```
                 ┌─────────────────────────────────────────────┐
   NVPTX 模式    │ clang/opt → LLVM NVPTX 后端 → PTX 文本        │
                 │                ↓ (LLVM 边界到此为止)           │
                 │        ptxas (闭源) → SASS → fatbinary        │
                 └─────────────────────────────────────────────┘
                 ┌─────────────────────────────────────────────┐
   AMDGPU 模式   │ clang/opt → LLVM AMDGPU 后端 → ELF ET_REL      │
                 │      (RA/调度/hazard/编码 全在 LLVM 内)        │
                 │                ↓                              │
                 │ lld -shared (ELF/Arch/AMDGPU.cpp) → 可加载     │
                 │        code object (ET_DYN)                    │
                 └─────────────────────────────────────────────┘
```

这个切分点决定了两边每一层的形态:

| 职责 | NVPTX | AMDGPU |
|---|---|---|
| 寄存器分配 | **不做**(见 §6) | SGPR/VGPR 双域 + occupancy 感知 |
| 指令调度 | 只做 Pre-RA 弱调度 | Pre/Post-RA 全套定制调度器 |
| 指令级 hazard / 隐式异步依赖管理 | ptxas 负责(程序级同步协议 PTX 显式暴露,见 §9) | LLVM 内显式建模(见 §9) |
| 机器码编码 | LLVM 侧不存在(SASS 由 ptxas 生成) | MCCodeEmitter + ELF |
| 链接 | 外部 nvlink(clang 经 clang-nvlink-wrapper 编排) | lld 原生支持 |
| SASS 反汇编 | LLVM 不提供;由 NVIDIA 的 nvdisasm/cuobjdump 提供 | llvm-objdump 原生可用 |

两个维度要分开看:**接口抽象层级**(PTX 虚拟 ISA vs SASS/GCN 物理 ISA)与**实现是否开源**(ptxas/nvlink/nvdisasm 闭源 vs LLVM 全开源)。NVPTX 模式是"高层接口 + 闭源下游工具",AMDGPU 模式是"物理接口 + 开源全链路"——四个组合在理论上都存在,这两家各占一角。

NVPTX 源码里散落着大量对 ptxas 行为的 WAR(workaround),这本身就是职责外移的代价之一:

- `NVPTXTargetMachine.cpp:320` — `hasPTXASUnreachableBug()`,为规避 ptxas bug 专门加了一个 IR pass
- `NVPTXMCExpr.cpp:31` — "ptxas 无法表达半精度立即数,只能打印成 .b16 再加载"
- `NVPTXAsmPrinter.cpp:992` — ".maxclusterrank 指令在 SM_90 以下会导致 ptxas 硬崩,必须过滤"

---

## 4. 编译产物与工具链生态

**NVPTX:文本即接口。**

- 没有 ELF ObjectWriter/Streamer(全目录 grep 无命中),AsmPrinter(2,800 行)直接向 `raw_ostream` 打印 PTX 文本,`.reqntid/.maxntid/.minnctapersm` 等 kernel 元数据都是文本指令(`NVPTXAsmPrinter.cpp:973-987`)
- 32 位 target `nvptx` 仍在注册(`TargetInfo/NVPTXTargetInfo.cpp:25`)
- 产物链:LLVM 出 .ptx → 驱动调 ptxas 出 cubin → fatbinary 打包;clang 侧配了 `clang-linker-wrapper` 和 `clang-nvlink-wrapper`(29,965 字节)做 offload 链接
- 连 DWARF 都要为"PTX 文本里表达调试信息"做专门处理(`NVPTXDwarfDebug.cpp/.h` 两个文件)

**AMDGPU:ELF code object 即接口。**

- 完整 MC 栈:MCTargetDesc 13 个文件(ELFStreamer/ELFObjectWriter/FixupKinds/InstPrinter/MCExpr…)
- Code Object Version 显式建模(`AMDGPUTargetStreamer.h:68`,HSA metadata V3/V5)
- kernel 元数据走结构化 HSA msgpack:`reqd_work_group_size` 等被 `AMDGPUHSAMetadataStreamer.cpp:259` 流进 ELF note
- `lld/ELF/Arch/AMDGPU.cpp` 原生参与链接;`offload/`(liboffload、libomptarget)运行时与 code object 版本协同演进

**含义**(区分 LLVM 内部支持与整个 NVIDIA 工具生态):AMDGPU 的产物(ELF + 结构化 metadata)可由 **LLVM 原生工具链**直接消费——llvm-objdump 反汇编、lld 链接(llvm-mca 接收的是汇编文本,不能直接吃 ELF)、无需任何厂商工具;NVPTX 的 PTX/cubin 下游检查与反汇编**依赖 NVIDIA 的外部工具**(nvdisasm 反汇编 SASS、cuobjdump 检查 fatbin/cubin、ptxas -v 报资源占用)。诊断并非不可能——NVIDIA 工具链相当完整——差别在于:LLVM 侧无法插手或扩展这些环节(闭源、版本随 CUDA 发行),而 AMDGPU 的每一环都可替换、可组合、可在 LLVM 内统一演进。

---

## 5. CodeGen 流水线

**NVPTX**(`NVPTXCodeGenPassBuilder.cpp`,新旧 PM 双份维护,文件头注明"必须保持同步"):

- IR 层很厚:NVVMReflect(`__nvvm_reflect` 编译期求值,还在 pipeline-start EP 防御性跑两遍,`:325-339`)、GenericToNVVM、LowerArgs(byval 参数按使用方式三分支降级:只读直访 param AS / cast 直用 / local copy,`:300-348`)、SROA(PreserveCFG+AggregateToVector 特殊配置)、InferAddressSpaces、AtomicLower、直线代码强度削减四件套(SeparateConstOffsetFromGEP→SLSR→GVN→NaryReassociate,`:157-173`)、LoadStoreVectorizer
- 机器层目标专属 pass:除 ISel hook 中的指令选择器与 ReplaceImageHandles 外,另有 5 个目标 MIR pass(ForwardParams、AddressFolder、ProxyRegErasure、PrologEpilog、Peephole)——注意这是"目标专属"口径:基类的通用机器优化(EarlyMachineLICM、MachineCSE、MachineSinking、PeepholeOptimizer 等)未覆盖 hook 时照常运行,见 §5.1
- **不做物理寄存器分配,但 post-regalloc 阶段照常走**:disable 的 11 个 pass(`:103-107`:PrologEpilogInserter、MachineLateInstrsCleanup、MachineCopyPropagation、TailDuplicate、StackMapLiveness、PostRAMachineSinking、PostRAScheduler、FuncletLayout、PatchableFunction、ShrinkWrap、RemoveLoadsIntoFakeUses)全部是"假设物理寄存器已分配"的 pass——注释明说虚拟寄存器会一直活到输出,这些 pass 会炸;其余通用收尾(ExpandPostRAPseudos、LiveDebugValues 等)保留

**AMDGPU**(`AMDGPUTargetMachine.cpp`,143 个 addPass):

- IR 层同样厚:PromoteAlloca(→LDS)、AlwaysInline、Attributor、LibCalls 优化、AtomicOptimizer(DPP/迭代两种 scan 策略,`AMDGPU.h:175`)、LowerKernelArguments/Attributes、RewriteOutArguments、UnifyDivergentExitNodes…
- 机器层是重头:LowerControlFlow、LowerI1Copies、InsertWaitcnts、SIFoldOperands、SIShrinkInstructions、SIPeepholeSDWA、LoadStoreOptimizer、FormMemoryClauses、InsertHardClauses、WholeQuadMode、FixSGPRCopies/FixVGPRCopies…每个都对应一类硬件语义
- 一个细节:LCSSA 被条件化插入(`:1744-1749`、`:2510-2513`)——条件是"未强制 GISel,**或** abort≠1"。`-global-isel-abort` 的取值(`TargetPassConfig.cpp:191`):**0 = Disable the abort(关闭中止,允许回退 SDAG)**、1 = 失败即中止、**2 = DisableWithDiag(不中止、发诊断并回退)**。因此跳过 LCSSA 仅发生在"强制 GISel **且** abort=1(失败即中止,SDAG 永不运行)";abort=0/2 都保留回退可能,LCSSA 保留。这是双路径并存 + fallback 语义的直接痕迹

**对比结论**:两者 IR 层投入量级相当(虚拟 ISA 后端把优化尽量前移);目标 pass 数量差异主要集中在机器层。逐 pass 统计(§5.7 统一静态口径):目标专属 pass 类 22 vs 63,其中 IR 层 15 vs 23、MIR 层 7 vs 40——注意 pass 数量不能直接等同于代码投入(行数与单 pass 复杂度另计,§2/附录 C/D)。以下 5.1–5.7 逐阶段展开。

### 5.1 双轨制流水线:hook 清单对比

两个后端都同时维护 legacy(`TargetPassConfig`)和新 PM(`CodeGenPassBuilder`)两套流水线,NVPTX 文件头注释明说"两者必须保持同步,直到 legacy 路径被删除"(`NVPTXCodeGenPassBuilder.cpp:9-11`)。差异首先在 override 的 hook 数量——AMDGPU 新 PM builder 有 22 个 hook(`AMDGPUTargetMachine.cpp:2353-2858`),NVPTX 只有 13 个。

**关键区分:未覆盖 hook ≠ 不运行该阶段**。基类 `CodeGenPassBuilder.cpp` 在每个 hook 里都有默认的通用 pass 序列;目标不覆盖 hook 时,这些通用 pass 照常运行。NVPTX 没有覆盖的 hook,其阶段由基类默认序列执行:

| Hook | NVPTX | NVPTX 未覆盖时跑的基类默认 | AMDGPU |
|---|---|---|---|
| addIRPasses | ✓ | — | ✓ |
| addCodeGenPrepare | — | (默认为空/通用 CGP) | ✓ |
| addPreISel | — | (默认空) | ✓ |
| addInstSelector | ✓ | — | ✓(SDAG 路径) |
| addIRTranslator … addGlobalInstructionSelect | — | SDAG-only,无 GISel 阶段 | ✓(GISel 路径,7 个 hook) |
| addPreRewrite | — | (默认空) | ✓ |
| addMachineSSAOptimization | — | **EarlyTailDuplicate、OptimizePHIs、StackColoring、LocalStackSlotAllocation、DeadMachineInstructionElim、EarlyMachineLICM、MachineCSE、MachineSinking、PeepholeOptimizer**(`CodeGenPassBuilder.cpp:733-761`) | ✓ |
| addPreRegAlloc | ✓ | — | ✓ |
| addRegAssignAndRewrite{Fast,Optimized} | —(RA 本体为空,但 PHIElim/Coalescer/MachineScheduler 等由 NVPTX 自己的 addOptimizedRegAlloc 显式补齐,§5.5) | — | ✓ |
| addPostRegAlloc | ✓ | — | ✓ |
| addPreSched2 / addPostBBSections | — | ExpandPostRAPseudos 在其前由基类统一插入;PreSched2 默认空 | ✓ |
| addPreEmitPass | — | (默认空;但其后有基类的 LiveDebugValues/MachineSanitizerBinaryMetadata/BlockPlacement/XRay 等) | ✓ |
| addAsmPrinter{Begin,End} | ✓ | — | ✓ |

NVPTX 真正从流水线上**移除**的是构造函数里 disablePass 的那 11 个——原因不是"不需要优化",而是这些 pass 假设物理寄存器已分配,而 NVPTX 的虚拟寄存器会存活到输出(注释原文,`NVPTXCodeGenPassBuilder.cpp:98-107`):PrologEpilogInserter(功能由 NVPTXPrologEpilog 模拟)、MachineLateInstrsCleanup、MachineCopyPropagation、TailDuplicate(Pre-RA 版 EarlyTailDuplicate 仍在)、StackMapLiveness、PostRAMachineSinking、PostRAScheduler、FuncletLayout、PatchableFunction、ShrinkWrap、RemoveLoadsIntoFakeUses。此外 NVPTX 的 `targetSchedulesPostRAScheduling()` 为真,post-RA 调度整体不走基类路径。

AMDGPU 只 disable 5 个(StackMap/Funclet/PatchableFunction/GC×2,`:2360-2364`),反而**打开**两个全局开关:`Opt.MISchedPostRA = true`(启用 post-RA 调度)和 `RequiresCodeGenSCCOrder`(结构化 pass 要求 SCC 序遍历,`:2354-2355`)。

### 5.2 IR 层:同源的优化骨架,不同方言的 lowering

**共享骨架**(两边几乎逐字相同,同一血统):
- `addEarlyCSEOrGVNPass`:Aggressive 用 GVN(关 scalar PRE),否则 EarlyCSE——NVPTX `:135-141`,AMDGPU `:2830-2836`,连"GVN 能合并 add a,b / add b,a 而 EarlyCSE 不能"的注释都一字不差
- 直线强度削减四件套:SeparateConstOffsetFromGEP → SLSR → EarlyCSE/GVN → NaryReassociate → EarlyCSE
- ExpandVariadics、AtomicExpand、LoadStoreVectorizer、InferAddressSpaces

**NVPTX 独有(13 个)——"PTX 方言翻译"型**:NVVMReflect(防御性地在 pipeline-start EP 和 addIRPasses 各跑一遍,`:178-183`)、GenericToNVVM、AssignValidGlobalNames、MarkKernelPtrsGlobal、PromoteParamAlign、LowerArgs、LowerAlloca、AtomicLower、ImageOptimizer、TagInvariantLoads、IRPeephole、LowerUnreachable(ptxas bug WAR)、CtorDtorLowering(`:212` addModulePass)。特征:全部服务于"生成合法/更优的 PTX 文本"或模块级结构,不涉及资源决策。

**AMDGPU 独有(约 17 个)——"资源与语义决策"型**:PromoteAlloca(alloca→LDS/向量)、LowerModuleLDS/SwLowerLDS(LDS 全局规划)、LowerExecSync(跨 wave 同步)、PreloadKernelArguments/LowerKernelArguments、LowerBufferFatPointers(拆 160-bit fat pointer)、AtomicOptimizer、自定义 CodeGenPrepare、AlwaysInline+AlwaysInliner、ExportKernelRuntimeHandles、UniformIntrinsicCombine、ImageIntrinsicOptimizer、LowerIntrinsics、PrintfRuntimeBinding、RemoveIncompatibleFunctions、CtorDtorLowering、LowerSwitch。特征:大量 pass 做的是**存储层级/寄存器/发射资源的预分配决策**。

另一批 AMDGPU pass 挂在 opt 阶段的 EP callback 上(`:1030-1186`):Attributor CGSCC、PromoteAllocaToVector、PromoteKernelArguments、LowerKernelAttributes、SimplifyLibCalls、HipStdPar 系列等——LTO 场景下在链接期就完成。NVPTX 的 EP 有 pipeline-start 的 NVVMReflect(条件重跑)、IR 层的 NVVMIntrRange 与条件启用的 NVPTXCopyByValArgs(默认关闭)、full-LTO-last 的 KernelInfoPrinter。

### 5.3 PreISel:结构化控制流,AMDGPU 独有的生死线

NVPTX **没有 addPreISel hook**——ptxas 接受任意 CFG,LLVM 无需过问。

AMDGPU addPreISel 是 12 个静态调用点的链条(`:2485-2519`,含挂靠的通用 LowerSwitch):

```
FlattenCFG → Sinking → LateCodeGenPrepare
  → UnifyDivergentExitNodes → FixIrreducible → UnifyLoopExits
  → StructurizeCFG
  → AnnotateUniformValues → SIAnnotateControlFlow → RewriteUndefForPHI
  → (条件 LCSSA) → PerfHintAnalysis
```

原因:GCN 硬件其实有普通的条件分支与无条件分支——`S_BRANCH`、`S_CBRANCH_SCC0/SCC1`、`S_CBRANCH_VCCZ/VCCNZ`(`SOPInstructions.td:1586` 起)——任意 CFG 并非无法执行。结构化服务的是**当前后端对 divergent 控制流与 EXEC mask 的转换**:SILowerControlFlow 的实现模型是"谓词化执行 + 谓词栈"(SI_IF/SI_ELSE/SI_END_CF/SI_BREAK pseudo,文件头注释自述该模型),它只接受 if/else + break/continue 形状;irreducible CFG 和多出口区域套不进这个形状,所以必须先 UnifyDivergentExitNodes(StructurizeCFG 不识别多出口区域)、FixIrreducible,再 StructurizeCFG 整体变形。uniform 分支不走这套:AnnotateUniformValues 给分支打 `amdgpu.uniform` 元数据,ISel 的 isUniformBr 检查它(`AMDGPUISelDAGToDAG.cpp:922`),SelectBRCOND 据此选择 s_cbranch_scc 而非 exec mask 操作序列(`:2904`)。GISel 双路径的痕迹也在这:LCSSA 按回退可能性条件插入——仅"强制 GISel 且 abort=1(失败即中止)"时跳过;abort=0/2 都保留回退,LCSSA 保留(`:2510-2513`,选项语义见 §5)。

### 5.4 ISel 与 MachineSSAOptimization

NVPTX addInstSelector 共 4 个:`LowerAggrCopies → AllocaHoisting → NVPTXISelDag → ReplaceImageHandles`(`:249-255`)。

AMDGPU SDAG 路径 3 个:`AMDGPUISelDAGToDAG → SIFixSGPRCopies → SILowerI1Copies`(`:2541-2546`)。注意:AMDGPU 的 DAG selector 本身就是 uniformity 感知的——它显式要求 UniformityInfoAnalysis(`AMDGPUISelDAGToDAG.cpp:1001-1004` 注释:"generic dag isel 里可选,AMDGPU 必需"),并据此在标量/向量指令间选择:SelectUADDO_USUBO 按 `N->isDivergent()` 选 S_UADDO_PSEUDO 或 V_ADD_CO_U32_e64(`:1156/:1183`)、SelectBRCOND 对 uniform 分支走 SCC 分支(`:2904`)、isUniformLoad 判定 invariant load(`:4758`)。后两个 pass 解决的是另外两类问题:**SIFixSGPRCopies 在 coalescer 之前运行**——头注释(:59)说明 vsrc union 寄存器类的 PHI 会让后续 coalescer 在消除 COPY 时造出非法的 VGPR→SGPR copy,该 pass 提前把这些 PHI 的定义寄存器类约束成 vgpr,使 coalescer 无法执行那个消除,从而**预防**非法 copy 的产生;SILowerI1Copies 把 i1 值降为 lane mask(i1 在 GCN 不是一等寄存器类)——两者都不是对"selector 不感知 uniformity"的补偿。

AMDGPU GISel 路径 11 个 stage(`:2548-2586`):IRTranslator → PreLegalizerCombiner+Localizer → Legalizer → PostLegalizerCombiner+**DivergenceLowering** → RegBankSelect+RegBankLegalize → RegBankCombiner → InstructionSelect。GISel 的核心卖点:bank 合法性在选择前由 RegBankLegalize 保证,SDAG 路径里因 vsrc 并集类(vgpr∪sgpr)选择歧义而需要的事后 pass(SIFixSGPRCopies)在这条路径上不出现。

MachineSSAOptimization(ISel 后的 MIR 优化):两边都运行该阶段,差别只在目标专属增量——NVPTX **不覆盖**该 hook,继承基类全套(EarlyTailDuplicate/OptimizePHIs/StackColoring/EarlyMachineLICM/MachineCSE/MachineSinking/PeepholeOptimizer,`CodeGenPassBuilder.cpp:733-761`);AMDGPU 覆盖之,在 `Base::addMachineSSAOptimization` 之后追加 6 个目标 pass(`:2595-2611`):SIFoldOperands(GCN 指令操作数可内嵌立即数/内联常量,折叠即消除指令)→ GCNDPPCombine → SILoadStoreOptimizer → SIPeepholeSDWA+EarlyMachineLICM+MachineCSE+SIFoldOperands(回炉)→ DeadMachineInstructionElim → SIShrinkInstructions(VOP3 e64 → VOP1/2 e32 编码收缩)。**编码收缩类 pass 只对直出机器码的后端存在**——PTX 文本没有编码概念。

### 5.5 寄存器分配:空操作 vs 三段式

NVPTX 的 addOptimizedRegAlloc(`:281-305`)列了 8 个 pass,但全是"铺垫"(LiveVariables/Coalescer/MachineScheduler/StackSlotColoring),allocator 本体是空实现(`:116`)。铺垫仍有价值:coalescer/scheduler 能减少最终 PTX 里的 mov 数量,即使没有物理寄存器。

AMDGPU 的 addRegAssignAndRewriteOptimized(`:2706-2758`)是**三段式分配**:

| # | pass | 说明 |
|---|---|---|
| 1 | GCNPreRALongBranchReg | 估算分支可能超出相对分支编码范围(≈±128 KiB)时预留 SGPR 对(见附录 C.5) |
| 2 | **RAGreedy(只分 SGPR)** | 第一段 |
| 3 | VirtRegRewriter(false) | 提前提交 SGPR 分配(注释:物理寄存器 use list 被太多东西依赖,`:2725-2729`) |
| 4 | StackSlotColoring | 先合并 SGPR spill 槽,再降级 spill |
| 5 | **SILowerSGPRSpills** | SGPR 专属"PEI":spill 优先利用 VGPR lane(wave 内每 lane 一个 SGPR 槽),装不下时回退 spill 到内存 |
| 6-8 | SIPreAllocateWWMRegs → **RAGreedy(只分 WWM)** → SILowerWWMCopies | 第二段:whole-wave-mode 寄存器 |
| 9-10 | VirtRegRewriter + ReserveWWMRegs | 锁定 WWM |
| 11 | **RAGreedy(只分 VGPR)** | 第三段 |
| 12 | PreRewrite:GCNNSAReassign + RewriteAGPRCopyMFMA | NSA 操作数重排 / AGPR copy 修复 |
| 13-14 | VirtRegRewriter(true) → MarkLastScratchLoad | 最终提交 |

拆三段的原因:SGPR spill 优先装进 VGPR(wave 级 packing,一个 wave 的 SGPR 可藏进单个 VGPR 的各 lane),装不下时仍有 spill 到内存的回退(`SIFrameLowering.cpp:1769`:"已尽可能把 SGPR spill 分到 VGPR,剩余的将走内存,移回默认栈");WWM 寄存器要求"非活跃 lane 也写入"的语义,必须独立于普通 VGPR 分配。

**insertPass 楔入机制**:AMDGPU 在通用 pass 序列的固定缝隙里楔进目标 pass(new PM addOptimizedRegAlloc 内 8 处,`:2661-2697`),最有代表性的两处:
- PHIElimination → **SILowerControlFlow**:必须插在 phi 消除后、TwoAddress 前,否则 SI_ELSE 的 tied operand 处理会多出一份 copy(`:2666-2669` 原注释)
- MachineScheduler → **SIWholeQuadMode**:调度必须在 WQM 插入 exec 操纵屏障**之前**完成(`:2677-2679` 原注释)

NVPTX 无任何 insertPass——通用序列已够用。

### 5.6 PostRA 与 PreEmit:NVPTX 2 个目标调用点,AMDGPU 19 个(17 目标 + 2 通用)

NVPTX 不进行物理寄存器分配,但 post-regalloc 及之后的阶段照常走完——**PostRA 段目标调用点仅 2 个**:PrologEpilog、Peephole(addPostRegAlloc);另有 3 个在 PreRA(ForwardParams、AddressFolder、ProxyRegErasure,§5.5)。其余是继承的基类通用序列:RemoveRedundantDebugValues、ExpandPostRAPseudos、(O≠0 时)BlockPlacement/TailMachineLateOptimization 里未被 disable 的部分、LiveDebugValues、MachineSanitizerBinaryMetadata 等(`CodeGenPassBuilder.cpp:639-730`)。PrologEpilogInserter 本体被 disable,其职责由 NVPTXPrologEpilogPass 模拟(§5.1)。

AMDGPU:
- **PostRA 至 PreEmit 四个 hook 合计 19 个调用点:2+2+1+14**(addPostRegAlloc `:2760` / addPreSched2 `:2767` / addPostBBSections `:2773` / addPreEmit `:2779-2816`);其中 PreEmit 的 14 个含 12 个目标 pass 和 2 个通用 pass,因此目标专属共 17 个(此处 SIShrinkInstructions 的跨阶段重复不涉及——PreSched2 那次是第二次插入,该类已在 §5.4 计过)。NVPTX 同位置只有 2 个(§5.6 开头)。addPreEmitPass 逐个对应一类硬件语义:

| pass | 硬件语义 |
|---|---|
| GCNCreateVOPD | VALU 双发射槽打包 |
| SIMemoryLegalizer | 内存序指令落地(fence/atomic 修饰) |
| SIPostRA16BitMovFolding | 16-bit mov 折叠 |
| **SIInsertWaitcnts** | vmcnt/lgkmcnt 等待计数插入(内存一致性) |
| SIModeRegister | MODE 寄存器(IEEE/dx10clamp/denormal)状态机 |
| SIInsertHardClauses | 硬件子句边界 |
| SILateBranchLowering | 最终分支指令选择 |
| AMDGPUSetWavePriority | wave 优先级 |
| SIPreEmitPeephole | 发射前最后清扫 |
| **PostRAHazardRecognizer** | 独立 hazard pass(见下) |
| AMDGPUWaitSGPRHazards | SGPR 依赖等待插入 |
| AMDGPULowerVGPREncoding | VGPR 编码降位 |
| AMDGPUInsertDelayAlu | 延迟槽指令 |
| BranchRelaxation | 分支距离超限修复 |

PostRAHazardRecognizer 单独成 pass 的原因写在注释里(`:2801-2806`):post-RA scheduler 按调度区域自底向上工作,**跨区域相邻指令的 hazard 它看不到**,必须在发射前全局再查一遍。这段注释本身就是"为什么 hazard 检查不能只靠调度器"的教科书式答案。

### 5.7 计数汇总:统一静态口径

pass 数量高度依赖口径,单一数字会误导。**本文正文统一口径:新 PM 主 CodeGen builder 中直接 add 的目标专属 pass 类,全局去重(同一类多处插入只计一次,如 SIFoldOperands 在 MachineSSAOptimization 中两次插入、SIShrinkInstructions 跨 MachineSSAOptimization 与 PreSched2 两阶段),排除 EP callback 与 AsmPrinter**。按此口径:

| 项目 | NVPTX | AMDGPU(SDAG 路径) |
|---|---|---|
| 不同 pass 类 | **22** | **63** |
| IR 层(含 ISel hook 中的 IR pass,如 NVPTXLowerAggrCopies/AllocaHoisting) | 15 | 23 |
| MIR 层 | 7 | 40 |

补充口径:NVPTX 加入 EP 新增类型(NVVMIntrRange、NVPTXCopyByValArgs——后者默认关闭)后为 24 类;AMDGPU 纯 GISel 主路径为 66 类(与 SDAG 路径共享 IR 层,ISel 段替换为 GISel hook 链)。

其它数字的归属,避免误读:
- `AMDGPUTargetMachine.cpp` 全文件的 143 次 `addPass(` 匹配是**混合计数**(裸 addPass 112 + FPM./PM./MPM. 前缀 31),包含 legacy 流水线与 opt 阶段新 PM callback,不是任何单一流水线的长度
- 条件分支(按 subtarget/opt-level 门控的 GCNCreateVOPD、SIPeepholeSDWA 等)在"类"口径下照常计入,在"给定配置实际运行"口径下才需要排除
- 两边都继承的基类通用 pass(MachineSSAOptimization 全家、LiveDebugValues 等)一律不计——NVPTX 未覆盖 hook ≠ 不运行该阶段(§5.1)

**口径 B——静态调用点**(addFunctionPass/addModulePass/addMachineFunctionPass/insertPass 调用计数,含重复):AMDGPU SDAG 路径新 PM builder 中目标 pass 插入 72 次/63 类,**9 个类重复出现,原因分四类**:①五个类因 RA 快速/优化两套路径各插一次(SILowerSGPRSpills/SIPreAllocateWWMRegs/SILowerWWMCopies/AMDGPUReserveWWMRegs/GCNPreRALongBranchReg);②SILowerControlFlow、SIWholeQuadMode 经 insertPass 楔入 addFastRegAlloc 与 addOptimizedRegAlloc 两个 hook(`AMDGPUTargetMachine.cpp:2615-2694`);③SIFoldOperands 在同一 MachineSSAOptimization 阶段内两处调用点;④SIShrinkInstructions 跨 MachineSSAOptimization 与 PreSched2 两阶段。NVPTX 主 builder 23 次/22 类,差额来自 NVPTXLowerAlloca 的**两个按 O0/O≠0 互斥的调用点**(`:150` O≠0 路径内 / `:206-207` O0 的 correct stack lowering 路径,同一编译只走其一)。静态计数与给定配置的实际执行次数是两回事(条件分支、PTX 版本门控等都会改变实际序列)。

**口径 C——给定配置下实际运行序列**:实际序列除 hook 覆盖外还受 PTX 版本门控、subtarget 特性、opt 级别等条件影响,不等于静态类清单;`clang -O2 --cuda-device-only` 下 NVPTX 跑主流水线的目标 pass 与继承的基类通用机器优化;AMDGPU 同级配置跑 63 类中的绝大多数(仅 VOPD/SDWA 等按 subtarget 门控)。

GISel 路径构成不同:SDAG 路径因 vsrc 并集类选择歧义所需的事后修复(SIFixSGPRCopies)被 RegBankLegalize 的前置 bank 合法性检查消化。

两个分布结论:
1. **NVPTX 的目标 pass 约 2/3 在 IR 层**(15/22),AMDGPU 约 1/3(23/63);MIR 层目标 pass 数 7 vs 40,约 6 倍差距
2. AMDGPU 的每个机器层 pass 都对应一条可指认的硬件语义(waitcnt/VOPD/NSA/WQM/SDWA/clause…);NVPTX 的目标 MIR pass 主要处理指令选择、参数访问(ForwardParams 改写为 param 空间直访)、地址折叠和帧相关转换(PrologEpilog/Peephole)——形态偏"IR→文本的整形",但参数访问改写并非纯文本替换

---

## 6. 指令选择与寄存器分配

**指令选择:**

- NVPTX:纯 SelectionDAG 单路径(`NVPTXISelDAGToDAG` + 8,143 行 ISelLowering),目录中不存在任何 Legalizer/InstructionSelector/RegisterBank 文件(已验证)
- AMDGPU:SDAG + GlobalISel 双路径,GISel 三大件合计 22,416 行:

| 文件 | 行数 |
|---|---|
| AMDGPULegalizerInfo.cpp | 8,882 |
| AMDGPUInstructionSelector.cpp | 7,711 |
| AMDGPURegisterBankInfo.cpp | 5,823 |

  外加 AMDGPUGISel.td、AMDGPUCombine.td(TableGen 化的 combiner)、RegBankLegalize 全家桶。`-global-isel` 打开时带 fallback 语义(LCSSA 的条件化就是证据)。

**寄存器分配:**

- NVPTX:`addTargetRegisterAllocator()` 是**空实现**(`NVPTXCodeGenPassBuilder.cpp:116`),虚拟寄存器名直接打印进 PTX,`%r1`、`%f2` 一路透传,数量上限交给 ptxas
- AMDGPU:寄存器即资源。SGPR(标量/Uniform)/VGPR(向量/Divergent)物理分区,`SIRegisterInfo.cpp` 4,641 行;寄存器压力是 occupancy(每 CU 同时驻留的 wave 数)的约束之一(与 workgroup 大小、LDS 占用并列,§8),occupancy 进而是调度目标函数的输入。还有 AGPR(矩阵核 MFMA 的累加寄存器)专用分配(`AMDGPUPrepareAGPRAlloc`、`AMDGPURewriteAGPRCopyMFMA`)和 WWM 寄存器预留(`AMDGPUReserveWWMRegs`)

---

## 7. 地址空间模型

两边都重度使用 LLVM 地址空间,但抽象层次不同。

**NVPTX**(`llvm/include/llvm/Support/NVPTXAddrSpace.h:21-31`,共 8 个编号):generic(0)/ global(1)/ shared(3)/ const(4)/ local(5)/ **tensor(6)** / shared_cluster(7)/ entry_param(101)。映射到 PTX 需要区分两个层次:**LLVM IR 地址空间**(指针可指向的存储空间,决定寻址语义及适用的指令后缀;shared_cluster 对应 `shared::cluster` 具名层级,entry_param 走 `.param` 空间)与 **MIR 指令修饰符**——NVPTX.h:329-334 明确 DeviceParam"不是真地址空间,不支持指针、只能以 param+offset 引用,仅作 MIR 指令修饰符使用,不应出现在 LLVM IR"。地址空间总体是**存储层级**的枚举,语义相对干净(AS6 tensor 服务 tcgen05 系列的 tensor memory),InferAddressSpaces 负责从 generic 推断回具体空间。

**AMDGPU**(`llvm/include/llvm/Support/AMDGPUAddrSpace.h:27-103`):地址空间被当成**通用命名维度**复用,除了存储层级(FLAT=0、GLOBAL=1、REGION=2、LOCAL=3、CONSTANT=4、PRIVATE=5),还包括:

- `BUFFER_FAT_POINTER=7 / BUFFER_RESOURCE=8 / BUFFER_STRIDED_POINTER=9`:三个 buffer 寻址形态,语义各不相同(AMDGPUUsage.rst:1264-1358):**AS8** 是 128-bit V# descriptor 的非积分指针表示(取代旧的 `<4 x i32>` 形态,可传给 buffer intrinsic、可与 i128 互转;GEP 不推荐且后端未实现);**AS7** 是"descriptor + 32-bit offset"的 160-bit 非积分指针(实验性,意图是让普通 load/store/atomic 直接建模 buffer 访问,align 分量式作用于 base 和 offset);**AS9** 再加一个 32-bit 结构化索引(192-bit,实验性)。三者都不是"非指针语义"——是指针语义的扩展形态;GEP/整数操作的支持各不相同:**AS7 的 GEP 已实现**,lowering 把资源描述符与偏移拆开、更新偏移(`AMDGPULowerBufferFatPointers.cpp:2141`,回归用例 lower-buffer-fat-pointers-pointer-ops.ll);**AS8 可与 i128 互转**,但其地址计算型 GEP 当前未实现(官方文档明确 GEP 不推荐);AS9 为实验性,支持范围以 AMDGPUUsage.rst:1342-1358 为准单独评估
- `VGPR=13`:**把 VGPR 文件建模成可寻址空间**(32-bit 地址是线程视角的字节偏移,load 4 字节 @12 即读 v3)。文档明确"**前端使用强烈不建议**"(AMDGPUUsage.rst:1373)——与普通寄存器分配交互导致微妙的生存期规则(如 alloca 提升出的 VGPR 内存在被调函数中不可见,解引用即 UB);它主要为后端内部用途服务(如 alloca 提升)。注释说明该值与 R600 图形路径的 CONSTANT_BUFFER_5 复用
- `BARRIER=15`:**把 GFX12 barrier ID 建模成地址**(经 synthetic apertures 实现):与其它 AS 的指针永不别名、不可解引用、只能被 intrinsic 消费
- CONSTANT_BUFFER_0..15 = 8..23,顺序不可动(支持 `CBIdx` 动态索引,`:77-82`)

这是一个值得注意的设计技巧,但要说得准确:**地址空间枚举被"超载"为通用资源命名后,AS 感知的通用分析基础设施(别名分析框架、InferAddressSpaces、AA 的 disjoint-AS 假设)成为可复用的底座**——前提是为每个超载空间补齐目标侧语义:别名规则(哪些空间互不冲突,如 BARRIER 的文档化承诺)、合法的 addrspacecast(AS8→AS7/9)、内存效果与 lowering(AS8 的 buffer intrinsic 路径)。VGPR 空间就是反例警示:复用不等于免费,它的生存期规则连文档都要用 UB 条款来约束前端。NVPTX 没有这种超载,因为 PTX 的 state space 就是纯存储语义。

---

## 8. 机器调度

- **NVPTX**:默认 MachineScheduler 走通用 Pre-RA 调度(`NVPTXCodeGenPassBuilder.cpp:297`),没有定制调度策略。理由同前:真调度在 ptxas。
- **AMDGPU**:调度是性能的核心战场,自成体系:

| 组件 | 行数 | 职责 |
|---|---|---|
| GCNMaxOccupancyMachineScheduler(GCNSchedStrategy) | — | **默认调度器**(选择链 `AMDGPUTargetMachine.cpp:1425-1456` 末端 fallthrough) |
| SIMachineScheduler | 1,992 | 备选:仅 `si-scheduler` feature 开启时用(`AMDGPU.td:1451`,默认关) |
| GCNRegPressure.cpp | 1,298 | SGPR/VGPR 分别计压的压力模型 |
| GCNIterativeScheduler.cpp | 645 | 迭代式多目标调度(minreg/maxocc/ILP 三种目标反复求解) |
| GCNILPSched / GCNMinRegStrategy | — | ILP/最小寄存器两种策略(经 amdgpu-sched-strategy 选择:max-ilp / max-memory-clause / iterative-ilp / iterative-minreg / iterative-maxocc / coexec) |
| AMDGPUIGroupLP / CoExecSchedStrategy | — | 指令组内 LP 约束、co-exec 调度 |

  外加发射级优化:VOPD 双发射打包(`GCNCreateVOPD`)、宏融合(`AMDGPUMacroFusion`)、NSA 操作数重排(`GCNNSAReassign`)、导出聚类(`AMDGPUExportClustering`)。

**为什么差距这么大**:GCN 有多条并行执行管线(VALU/SALU/VMEM/SMEM/LDS),且 occupancy 同时受 workgroup 大小、LDS、SGPR、VGPR 多重约束(`GCNSubtarget::computeOccupancy`,`GCNSubtarget.cpp:525-536` 取各约束最小值)——寄存器压力是其中之一,调度决策通过寄存器用量影响占用率。NVPTX 侧,LLVM 已做过 PHIElimination 等机器准备,但无物理发射约束与物理寄存器,真正的发射调度与压力权衡发生在 ptxas 内部;这不是"没有调度问题",而是该问题被划到了边界之外。

---

## 9. Divergence、Wave 模型与内存一致性

这是 AMDGPU 机器层复杂度的最大单一来源;NVPTX 在 IR/ISel 层同样处理 divergence 判定与并发语义(见本节末尾),但 wave 级机器状态(exec mask、SGPR/VGPR 分域)的 materialization 不发生在 LLVM 内。

**Wave 模型**:wave32/wave64 可配置(`GCNSubtarget.h:930`),exec mask 是真实的机器状态,于是有了整族 pass:

- `SILowerControlFlow` / `SILowerI1Copies`:把 IR 的分支/布尔降成 exec mask 操作
- `SIWholeQuadMode`:graphics 的 quad 模式状态机
- `SIPreAllocateWWMRegs` / `AMDGPUReserveWWMRegs` / `SILowerWWMCopies`:whole-wave-mode 寄存器的专用处理
- `AMDGPUAnnotateUniformValues`:Uniform 值的 IR 级静态标注(供 ISel 的 isUniformBr/isUniformLoad 等消费);`SIFixSGPRCopies`/`SIFixVGPRCopies` 则修复寄存器类合法性问题(vsrc 并集类经 coalescer 产生的非法 copy、向量 copy 的 exec implicit use)——标注与修复是两件事,勿混
- `AMDGPUAtomicOptimizer`:把 divergent atomic red 降成 DPP scan 或迭代 scan 两种策略
- `AMDGPUUnifyDivergentExitNodes`:divergent 出口统一

NVPTX 侧的分工是:LLVM 负责把并发语义正确地降到 PTX——TTI 提供 divergence 来源判定(`NVPTXTargetTransformInfo.cpp:46` 的 `isSourceOfDivergence`:threadIdx/laneid 读取、原子、generic/local 加载保守判定),ISel 把 AtomicOrdering/SyncScope 映射成 PTX 的 sem/scope 修饰(`NVPTXISelDAGToDAG.cpp:646-687`:getMemOrder/getAtomicScope,含 sm_60 前 system scope 的诊断降级);ptxas 再把这些语义指令落实到 NVIDIA 机器指令与硬件约束。每个线程一个虚拟寄存器,`@p` 谓词寄存器是机器层主要的分支状态表达。

**并发语义的三个正交维度**(两边都做,但层次和量级不同):

1. **内存一致性**(memory ordering):哪些写对哪些读可见、以什么顺序。NVPTX 在 ISel 中生成带 sem/scope 的 PTX 原子与 fence;AMDGPU 的 SIMemoryLegalizer + SIInsertWaitcnts(3,775 行)把内存序落到具体修饰并管理可见性
2. **异步操作完成等待**(completion tracking):异步发起的访存何时算完成、消费点前要不要等。**PTX 显式暴露程序级异步完成协议**——cp.async.commit_group / wait_group / wait_all 及 bulk 变体在 NVPTX 有完整的 intrinsic→指令选指规则(`NVPTXIntrinsics.td:497-516`);这些同步语义属于程序必须表达的契约,ptxas 不负责补齐缺失的程序级同步。AMDGPU 侧同样有显式机制:`int_amdgcn_asyncmark` / `int_amdgcn_wait_asyncmark`(`IntrinsicsAMDGPU.td:2928-2934`)暴露给程序标记与等待异步操作;差别在**隐式依赖的管理**——普通 VMEM/LDS 访问的完成对程序不可见,由编译器(SIInsertWaitcnts 按硬件计数器追踪未决访问、消费点前插入满足依赖的等待)自动插 s_waitcnt。一句话:两边都有显式异步原语,GCN 额外把隐式硬件依赖的等待自动化(LLVM 内),PTX 模式下这部分下沉到 ptxas
3. **指令级 hazard**(发射槽/流水线冲突):相邻指令的硬件互斥。GCNHazardRecognizer(4,361 行)表驱动检查十余类(读改写、VMEM→SMEM、VOPD 冲突);NVPTX 侧同样在 ptxas

即:维度 1 两边都在 LLVM 层实现(方式不同:语义修饰 vs 显式计数);维度 2 要区分两层——显式的程序级异步协议(PTX 直接暴露、LLVM 负责转译)与隐式的硬件完成依赖(GCN 交给 SIInsertWaitcnts,PTX 模式下沉到 ptxas);维度 3 AMDGPU 在 LLVM 内,PTX 模式下在 ptxas。§5 MIR 层 pass 差异(7 vs 40)的根源正在这里——不是"有没有内存模型",而是**抽象边界画在哪**。

---

## 10. 内建函数与处理器建模

- 内建函数:IntrinsicsNVVM.td 有 328 个 `def int_nvvm` 源行,经 TableGen 元编程展开后为 **2797** 个 intrinsic;IntrinsicsAMDGPU.td 为 670 个 def 行 / **1469** 个展开(统计方法见附录 B)。AMDGPU 几乎每个硬件特性(dpp、perm、s_sendmsg、s_barrier、WMMA/MFMA 系列矩阵核)都有对应 intrinsic,这是"LLVM 内闭环"必然带来的表面积。**生成方式两边都是显式定义、multiclass 与 foreach 的混合**,只是常见组合维度不同:NVVM 侧重类型/ftz/nan/rnd 变体矩阵(:1637 的 min/max 家族);AMDGPU 同样有组合生成——image 采样变体 × 图像维度(`IntrinsicsAMDGPU.td:1348` 的 foreach dim)、MFMA 的 FP8/BF8 类型组合(:3664 的 multiclass foreach kind)。不做"谁逐个定义、谁矩阵展开"的二分
- 处理器建模:NVPTX.td 现在用 TableGen 元编程生成整条 sm 链 —— `SMVersions = [20,21,30,...,90,100,103,107,110,120,121]` 一行 foreach 生成全部基线(`NVPTX.td:86-100`),`SMFamilies` 生成家族变体(f/a),`sm_90a` 单列,`sm_101→sm_110` 用 ProcessorAlias 处理 PTX 版本改名(`:122-124`)。这套写法干净地管理了 14 年的 ISA 长尾,值得抄
- AMDGPU 的 GCNProcessors.td 覆盖 gfx600 到 gfx1310,但目录里还背着 **40 个 R600/Cayman 文件**(VLIW4/5 时代),r600 target 仍在 TargetInfo 注册,"amdgcn" 作为 legacy 别名保留(`TargetInfo/AMDGPUTargetInfo.cpp:31-51`,注释写明等迁移完删除)。AMDGPU 是三架构共存:r600 / GCN(SI+)/CDNA-RDNA 分叉

---

## 11. 对昇腾编译栈的启示

按重要性排序。**性质声明**:以下是基于源码阅读的迁移思路,不是已验证结论;每条都标注了借鉴对象(文件/机制)、需要补的前置事实(型号/版本/复现路径)与建议的验证方式。

1. **职责边界是第一决策**。昇腾 CANN 编译器(LLVM fork → davinci 指令)在"LLVM 只到中间层、机器层由闭源组件完成"这一点上与 PTX 模式同构。此前在 ST 测试中遇到的几类问题(UB 与 S/M 管线间同步、conv 输出 5D NZ 格式导致下游算子不可用、dav-m200 `set_cmpmask` 多 repeat 限制)是否源于这一边界划分,**尚属待验证的假设**——需要先确认:这些问题在 CANN 编译路径的哪一层产生(可通过导出 davinci 汇编/cce 中间结果逐层对比)、在哪个 CANN 版本/型号上引入、最小复现是什么。验证成立后,才谈得上"GCN 模式把这类问题变成编译器 pass 的显式职责"这一对比是否适用。
2. **SIInsertWaitcnts 作为"异步完成等待插入"的参考实现**。若要做 MTE 管线间 `set_flag/wait_flag` 的自动插入(替代手工同步),问题形态与 GCN 的计数器管理有相似之处(未决访问追踪 + 消费点前插入满足依赖的等待)。**"同构"是过强的说法**——GCN 的 waitcnt 是多个硬件计数器(vmcnt/lgkmcnt/expcnt 等,每计数器一条时间线)上的等待,且该 pass 并不保证最小等待:文件头注释(:16)明说"每硬件计数器一条时间线"的粒度在某些场景会保守生成更强的 s_waitcnt(如 SMEM 与 LDS 同时在飞时,即使只需等第 i 个 LDS,也会生成 lgkmcnt(0));MTE 的 flag 是显式事件对,硬件语义差异需要先梳理。建议的验证路径:取一个现有手工同步的算子(如 ST 用例),先手工推导"编译器需要哪些信息才能自动插入",再对照 SIInsertWaitcnts 的 counter-tracking 数据结构评估差距。3775 行实现是阅读起点,不是可直接套用的方案。
3. **GCNHazardRecognizer 作为"发射约束表驱动化"的参考**。dav-m200 上"多 repeat 的 cmpmask 只有第一条 vsel 生效"这类约束,在 GCN hazard recognizer 里有形态对应的实现(表 + 检查函数)。**前置条件**:该约束需要先有可复现的最小用例和硬件手册依据(是 ISA 文档化的行为还是勘误),再决定建模为 hazard 检查还是选指限制;ST 记录中的现象描述不足以直接立项。
4. **地址空间超载技巧**(§7):AMDGPUAS::VGPR=13、BARRIER=15 把非内存资源建模成地址空间,在**补齐目标语义(别名规则、合法 cast、内存效果、lowering)之后**可复用通用 AS 分析基础设施(别名分析框架、InferAddressSpaces)。注意两个约束:①复用不是免费的——VGPR 空间的生存期规则之复杂,连 LLVM 文档都"强烈不建议前端使用"(AMDGPUUsage.rst:1373);②buffer 寻址(AS7/8/9)是指针语义扩展而非"非指针",不可混称。若 PyPTO 的 IR 层想统一表达 UB/TMEM/GM 视图,先盘点每个空间要补的语义清单,再谈复用
5. **寄存器压力→occupancy 的建模**(GCNRegPressure 分域计压):对应昇腾侧 UB 512KB / TMEM / 寄存器文件的预算问题——tile 框架里的"一个 tile 放哪、放几个"本质上是同一个资源规划问题(寄存器压力是 occupancy 的约束之一,§8),可以借鉴其压力模型而非拍脑袋阈值。
6. **.td 元编程管理 ISA 长尾**(NVPTX.td 的 foreach + 家族变体 + alias):如果 davinci 系列型号继续裂变(m200/m300…),这比逐型号手写 feature 表可维护得多。
7. **双路径迁移策略**(SDAG 与 GISel 并存 + 按回退可能性条件化的 LCSSA):老后端现代化时不必大爆炸重写,AMDGPU 用一个 flag + fallback 语义完成了多年并行——昇腾若重写指令选择层,这是路线图模板。

---

## 12. clang 前端侧:同一枚硬币的另一面

后端分析(§1-§11)的"虚拟 ISA vs 物理 ISA"分野,在 clang 侧呈现出**方向相反的不对称**的迹象:后端 AMDGPU 比 NVPTX 大 8 倍,而前端侧 CUDA/NVPTX 的支持面(11 个 `__clang_cuda_*` 头 vs 7 个 `__clang_hip_*`、6 个 cuda_wrappers vs 1 个 hip_wrappers、Cuda.cpp+4 工具编排 vs lld 直链、nvlink-wrapper 838 行专属工具)明显更宽。**注意这只是迹象而非完整统计**:CUDA 与 HIP 共享大量代码(SemaCUDA 一份 1297 行同时服务两种语言,CGCUDANV 的注册代码生成一体两面),按"某厂商专属行数"做严格对照需要单独统计,本文未做。clang 对 GPU 的支持散布在六个层次,以下逐层对比(附录 E 为完整文件清单)。

### 12.1 驱动与工具链(Driver/ToolChains)

| | CUDA/NVPTX | HIP/AMDGPU |
|---|---|---|
| ToolChain 文件 | Cuda.cpp(1101)+ Cuda.h(191) | AMDGPU.cpp(1406)+ HIPAMD.cpp(219)+ HIPUtility.cpp(102)+ HIPSPV.cpp(450,SPIR-V 路径) |
| 职责 | 找 CUDA 安装、拼 ptxas/nvlink 命令行 | 找 ROCm 安装、直接生成 ELF(无需外部汇编器) |
| 外部依赖 | **ptxas + nvlink(NVIDIA 闭源汇编器/链接器,硬依赖)** | 设备最终链接器是开源 lld;外层按构建模式可能经通用 clang-linker-wrapper(HIP 路径亦创建 LinkerWrapperJobAction,`Driver.cpp:3738/4324`),无 AMDGPU 专属 wrapper;不依赖厂商闭源汇编器 |

这是 §3 职责边界在驱动层的直接投影:NVPTX 路线从 clang 开始就必须调外部工具;AMDGPU 路线 clang+lld 一体成型。

### 12.2 TargetInfo 与地址空间映射(Basic/Targets)

- `clang/lib/Basic/Targets/NVPTX.{h,cpp}`(210+212 行):AddrSpaceMap 把 LangAS 映射到 NVPTXAS 枚举;`isAddressSpaceSupersetOf` 实现 generic(AS0)与其子集关系(NVPTX.h:90-105)
- `clang/lib/Basic/Targets/AMDGPU.{h,cpp}`(507+371 行):AMDGPUAddrSpaceMap(AMDGPU.cpp:31-37)同样映射到 §7 的 AMDGPUAS;额外携带 GPUKind/WavefrontSize/CUMode 等 target feature 查询

两边都是"把语言层地址空间(opencl_global 等)翻译到后端枚举"的薄层,但 AMDGPU 侧多出 wave/cumode 等语义查询。

### 12.3 Sema:HIP 与 CUDA 共享 SemaCUDA 框架,语义有分支差异

- `SemaCUDA.cpp`(1297 行)是 **CUDA + HIP 共用的框架**:HIP 复用同一套 device/host 双侧语义推导(attribute 推导、隐式推导、模板特化选择),并通过 `LangOpts.HIP` 分支实现语义差异。例如 device 侧 kernel launch(`<<<>>>`):CUDA 走 device kernel call 路径(CodeGen 有对应支持,见 G.4),**HIP 直接拒绝**(`SemaCUDA.cpp:86` err_cuda_device_kernel_launch_not_supported)。共享框架≠语义相同
- 没有 SemaHIP.cpp——HIP 复用 SemaCUDA 框架,差异经 LangOpts.HIP 分支表达(见上);hip_runtime 头文件补 API 面
- OpenCL 走 SemaOpenCL.cpp(627 行),OpenMP target 走 SemaOpenMP.cpp(28336 行,含 GPU offload clause)

### 12.4 CodeGen:CGCUDANV 是 CUDA/HIP 一体两面的枢纽

`clang/lib/CodeGen/CGCUDANV.cpp`(1544 行)同时服务 CUDA 和 HIP(类名 CGNVCUDARuntime):
- CUDA 模式:emit `__cudaRegisterFatBinary` / module_ctor 调用
- HIP 模式:emit `__hipRegisterFatBinary` / `__hipRegisterVar`(CGCUDANV.cpp:772-838),RDC 与非 RDC 两种链接模式走不同注册路径
- **同一个文件是 NVIDIA fatbinary 与 AMDGPU code object 注册结构的共同出生地**——厂商锁定的 API 形态由 clang 负责生成

`Targets/AMDGPU.cpp`(791 行)的 AMDGPUTargetCodeGenInfo(AMDGPU.cpp:294-328)则承担硬件语义:
- getGlobalVarAddressSpace:目标钩子只是 CodeGenModule::GetGlobalVarAddressSpace(`CodeGenModule.cpp:6407-6445`)的**末端 fallback**——OpenCL/SYCL/CUDA device 各自的语言分支在前(CUDA device 全程不经此钩子:amdgpu_barrier/constant/shared/device 决策都在语言层),钩子开头 assert 也排除二者(`AMDGPU.cpp:513-515`)。实际到达钩子的 HIP device 全局变量默认 global AS 由 CodeGenModule 的语言专用分支处理,钩子负责的是其余地址空间无关语言的默认 AS 与常量初始化提升进 constant AS
- getSRetAddrSpace:sret 默认进私有 AS(5);例外:不可按寄存器传递的类型(canPassInRegisters 为假)用默认 AS 以匹配 this 指针约定(`:501-508`)
- getLLVMSyncScopeStr / setTargetAtomicMetadata:内存序 scope 字符串("agent"/"workgroup")与 atomic metadata
- createEnqueuedBlockKernel:OpenCL 2.0 device-side enqueue 的 kernel 克隆
- __launch_bounds__ → amdgpu_flat_work_group_size 属性翻译(AMDGPU.cpp:354-360)

`Targets/NVPTX.cpp`(374 行)只有一半的量,主要是 kernel 参数标注(readonly/param AS 等)。

### 12.5 内建函数:427 vs 850

- `BuiltinsNVPTX.td`(1379 行,427 个 Builtin 定义):`__nvvm_*` 系列镜像 NVVM intrinsic
- `BuiltinsAMDGPU.td`(1411 行,850 个):`__builtin_amdgcn_*` 镜像 int_amdgcn 系列,外加 BuiltinsAMDGPUDocs.td 文档表
- 两边都是"LLVM intrinsic 的 clang 入口"。数量上 NVPTX 的 427 与 AMDGPU 的 850 是 .td `Builtin<` 行数(BuiltinsAMDGPU.td 无 foreach,BuiltinsNVPTX.td 的 foreach 仅用于构造 feature 字符串而非生成多个定义,故此数即定义数);与后端展开后 intrinsics(2797:1469,附录 B)不可直接对比——一个 intrinsic 可有多个 builtin 入口,反之亦然

### 12.6 头文件与数学库

- CUDA:`__clang_cuda_*` 11 个头(cmath/device_functions/intrinsics/libdevice_declares/math/texture_intrinsics…),声明 libdevice 上百个 `__nv_*` 函数,链接期映射到 nvvm intrinsic 或 libdevice bitcode
- HIP:`__clang_hip_*` 7 个头 + amdgpuintrin.h + hipstdpar(hipstdpar/ 目录下 C++ 标准库并行算法的 GPU 实现)
- 公共:`__clang_gpu_*` 4 个头 + gpuintrin.h(2024 年统一出来的跨厂商抽象层),cuda_wrappers/hip_wrappers/openmp_wrappers/llvm_offload_wrappers 包装系 std headers
- libclc(仓库内 OpenCL 实现)支持 SPIR/SPIR-V/AMDGPU/NVPTX 四种目标

### 12.7 offload 工具链(仓库级)

| 工具 | 行数 | 作用 |
|---|---|---|
| clang-offload-bundler | 432 | fatbin 式多目标打包/解包 |
| clang-linker-wrapper | 1623 | offload 链接总入口:调 ptxas/nvlink/lld,含 offload 包装职责 |
| clang-nvlink-wrapper | 838 | **NVIDIA 专属**:把 PTX/用 LTO 的 bitcode 转 cubin(需调 ptxas) |
| offload-arch | — | 运行时探测 GPU 型号 |

(clang-offload-wrapper 在当前 main 已移除,其 IR 包装职责并入 clang-linker-wrapper 与 offload/ 库。)

没有 AMDGPU 专属的 wrapper 工具(对比 clang-nvlink-wrapper);但 AMDGCN/HIP 路径**可能使用通用的 clang-linker-wrapper**(HIP 构建亦创建 LinkerWrapperJobAction,`Driver.cpp:3738/4324`,该工具内置 AMDGCN fatbinary 组装 :934)。分层的准确说法:设备最终链接器是 lld(闭源汇编器为零);外层按构建模式(-foffload-via-llvm、offload 打包)可能经通用 wrapper。就 **LLVM 仓库内的编排范围**而言:NVPTX 的编译/链接各环都由 clang 调外部闭源工具完成,AMDGPU 的设备侧工具链都在仓库内;但 NVIDIA 生态整体并不缺工具(nvdisasm/cuobjdump/nsight),差别在于这些环节 LLVM 无法插手。

### 12.8 小结:前端的镜像不对称

后端 8 倍差距 vs 前端支持面更宽的迹象(§12 引言的限定:共享代码未做厂商归属统计),指向同一个结构性事实:PTX 模式把复杂性留在"方言生成 + 外部工具接口"(clang 的 CUDA 支持经过 15 年打磨,头文件/工具链/Sema 交互极深),GCN 模式把复杂性留在后端。**对生态的启示**(两个独立维度):抽象层级上,PTX 的高层接口让同一份文本可覆盖多代硬件(仍受驱动支持的 PTX 版本约束,F.4),代价是 SASS 级问题只能靠 NVIDIA 工具(nvdisasm/ptxas -v)诊断;开源性上,AMDGPU 全链路(LLVM 原生的 objdump/mca/lld)可组合可扩展,NVPTX 的下游环节闭源且随 CUDA 版本走。两者并不等价——"LLVM 不做 SASS 反汇编"是接口层级的必然,"闭源"是商业选择,AMDGPU 证明了另一条路的存在。

---

## 附录 A:关键文件索引

| 主题 | NVPTX | AMDGPU |
|---|---|---|
| 流水线 | NVPTXCodeGenPassBuilder.cpp(358 行,全文可读) | AMDGPUTargetMachine.cpp(2,858 行) |
| ISel | NVPTXISelDAGToDAG / NVPTXISelLowering | SIISelDAGToDAG / SIISelLowering + GISel 三大件 |
| AsmPrinter | NVPTXAsmPrinter.cpp(直接打文本) | AMDGPUAsmPrinter.cpp(走 MCInst→ELF) |
| 元数据 | .reqntid 文本指令(AsmPrinter:973) | AMDGPUHSAMetadataStreamer.cpp |
| 地址空间 | NVPTXAddrSpace.h(Support 头,§7) | llvm/include/llvm/Support/AMDGPUAddrSpace.h |
| 调度 | 无定制 | SIMachineScheduler / GCNRegPressure / GCNIterativeScheduler |
| 一致性 | ISel 生成带 sem/scope 的 PTX 原子与 fence(§9 维度 1) | SIMemoryLegalizer + SIInsertWaitcnts(3,775)/ GCNHazardRecognizer(4,361) |
| 处理器表 | NVPTX.td(foreach 生成) | GCNProcessors.td + R600Processors.td |
| 调试信息 | NVPTXDwarfDebug(文本 .loc/.file) | 通用 ELF DWARF |

## 附录 B:测量方法

- 行数:`find … \( -name '*.cpp' -o -name '*.h' -o -name '*.td' \) | xargs cat | wc -l`
- 测试数:`find llvm/test/CodeGen/{NVPTX,AMDGPU} -name '*.ll' | wc -l`
- **intrinsic 数量(两个口径)**:
  - .td def 行数:`grep -c "def int_nvvm" llvm/include/llvm/IR/IntrinsicsNVVM.td` → 328;`grep -c "def int_amdgcn" llvm/include/llvm/IR/IntrinsicsAMDGPU.td` → 670。这只是定义模板的源码行——TableGen 的嵌套 foreach(如 IntrinsicsNVVM.td:1637 的 min/max 家族,operation×variant×nan×ftz×5 种浮点类型)会让一行 def 生成数十个记录,该口径**严重低估** NVVM 实际数量
  - 展开后(真实 intrinsic 数):用与构建系统相同的命令生成 enum 头再计数:
    ```bash
    cmake -G Ninja -S llvm -B /tmp/tblgen-build -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD="" && ninja -C /tmp/tblgen-build llvm-tblgen
    for P in nvvm amdgcn; do
      /tmp/tblgen-build/bin/llvm-tblgen -I llvm/include -gen-intrinsic-enums \
        -intrinsic-prefix=$P llvm/include/llvm/IR/Intrinsics.td -o /tmp/Intrinsics_$P.h
      grep -cE "^\s+($P)_[a-zA-Z0-9_]+( = [0-9]+)?," /tmp/Intrinsics_$P.h
    done   # nvvm=2797, amdgcn=1469
    ```
  - 结论提醒:展开后 NVVM(2797)反超 AMDGCN(1469),与 def 行口径(328:670)方向相反;引用 intrinsic 数量时必须注明口径
- 处理器列表:NVPTX.td `SMVersions`/`SMFamilies`;GCNProcessors.td 字符串字面量
- pass 计数(§5.7 统一静态口径):新 PM 主 CodeGen builder 中直接 add 的目标专属 pass 类,全局去重、排除 EP/AsmPrinter。**复现脚本必须同时抓四种调用形态**——`addFunctionPass/addModulePass/addMachineFunctionPass(...)` 之外,还有 `insertPass<XxxID>(YyyPass())`(楔在 addFastRegAlloc/addOptimizedRegAlloc 等通用 hook 内,`AMDGPUTargetMachine.cpp:2615-2694`,贡献 SILowerControlFlow/SIWholeQuadMode 等 7 个类)。只抓三种 add…Pass 会漏掉 insertPass 的类,数不出 63。`grep -c "addPass(" AMDGPUTargetMachine.cpp` 的 143 是 legacy+新 PM callback 混合计数,勿当流水线长度引用
- 均在本仓库工作区(main @ 3eda2aebadd4)执行,可复现

---

## 附录 C:AMDGPU 全部 CodeGen pass 目录

按流水线阶段分组,同阶段内按执行顺序。描述摘译自各 pass 源文件头注释(标注※的为注释缺失、由代码语义归纳;行数为源文件行数)。这 63 个 pass 类就是 §5.7 表中 AMDGPU SDAG 列的展开(AsmPrinter 相关类与模块级/LTO/EP 形态——C.9——不计入主口径),便于逐个对照源码。

### C.1 IR 层(addIRPasses + addCodeGenPrepare,17 个)

| Pass | 行数 | 作用(摘译自头注释) |
|---|---|---|
| AMDGPURemoveIncompatibleFunctions | 221 | 把使用了与当前 GPU 不兼容特性的函数整体替换为 null 并删除 |
| AMDGPUPrintfRuntimeBinding | 470 | 把 printf 绑定到 kernel 参数指针,运行时再挂到 buffer 上 |
| AMDGPUCtorDtorLowering | 185 | 把全局 ctor/dtor 合并成单个带 metadata 的 init/fini kernel |
| AMDGPUImageIntrinsicOptimizer | 336 | 合并多个 2dmsaa/2darraymsaa 的 image_load 为单条 image_msaa_load |
| AMDGPUUniformIntrinsicCombine | 202 | 参数 uniform 时简化特定 intrinsic 调用 |
| AMDGPUAlwaysInlinePass | 172 | 内部函数标 always_inline;外部函数克隆一份强制内联 |
| AMDGPUExportKernelRuntimeHandles | 110 | lower "enqueued blocks"(device-side enqueue 的 runtime handle 导出) |
| AMDGPULowerExecSync | 260 | lower 全局 named barrier(target-ext-type 全局变量)的地址分配与同步 ID |
| AMDGPUSwLowerLDS | 1403 | 把 kernel/非 kernel 函数的 LDS 使用改写为动态分配的全局内存 |
| AMDGPULowerModuleLDS | 1600 | 消除非 kernel 函数的 LDS 使用(LDS 是 per-kernel 连续分配的) |
| AMDGPUAtomicOptimizer | 1013 | divergent atomic 用单 lane 执行降低争用(DPP/迭代两种 scan 策略) |
| AMDGPUPromoteAlloca | 1807 | alloca 提升:先做使用合法性分析(collectAllocaUses,存在不可提升的访问形态则放弃),可行则按资源预算选去向——提升为向量受寄存器预算约束(getMaxVGPRs 按 LDS 占用与 occupancy 推导、VectorizationBudget 摊算),转 LDS 受容量约束(hasSufficientLocalMem 按"当前 LDS 占用 ≤ 该 occupancy 档位上限"判定) |
| AMDGPUCodeGenPrepare | 2551 | ISel 前 IR 优化杂项(如 1ulp 除法展开支持 denormal) |
| AMDGPUPreloadKernelArguments | 365 | kernel 参数预载入 user_data SGPR(容量受空闲 user SGPR 数限制) |
| AMDGPULowerKernelArguments | 423 | kernel 参数访问改写为 kernarg 基指针 + 偏移的 load |
| AMDGPULowerBufferFatPointers | 2913 | 拆解 160-bit buffer fat pointer(AS7)为其组成分量 |
| AMDGPULowerIntrinsics | 271 | misc intrinsic lowering(如 memory intrinsics → 循环/库调用) |
| (LowerSwitch,通用 pass,AMDGPU 挂靠) | — | switch → 分支链,给 StructurizeCFG 铺路 |

### C.2 PreISel 结构化(addPreISel,6 类目标 pass——PerfHintAnalysis 已含在内)

| Pass | 行数 | 作用 |
|---|---|---|
| AMDGPULateCodeGenPrepare | 620 | ISel 前最后一刻的 IR 优化杂项 |
| AMDGPUUnifyDivergentExitNodes | 374 | 合并 divergent 多出口——StructurizeCFG 不识别多出口区域 |
| AMDGPUAnnotateUniformValues | 151 | 给 IR 值加 amdgpu.uniform 元数据,供 ISel 区分 uniform/ddivergent |
| SIAnnotateControlFlow | 455 | 用硬件 intrinsic 标注控制流(if/break 的硬件形态) |
| AMDGPURewriteUndefForPHI | 192 | 修 StructurizeCFG 产生的 undef PHI |
| AMDGPUPerfHintAnalysis | 492 | 次级分析:标记 memory-bound 函数与可能受益于限波的 kernel(头注释:\brief Analyzes if a function potentially memory bound…) |
| (FixIrreducible / UnifyLoopExits / StructurizeCFG,通用) | — | CFG 规范化三件套 |

### C.3 ISel(SDAG 路径 addInstSelector,3 个)

| Pass | 行数 | 作用 |
|---|---|---|
| AMDGPUISelDAGToDAG | 4816 | 主指令选择器(SDAG) |
| SIFixSGPRCopies | 1235 | 在 coalescer 之前约束 vsrc union 类 PHI 的定义寄存器类为 vgpr,预防 coalescer 消 COPY 时造出非法 VGPR→SGPR copy(:59 头注释) |
| SILowerI1Copies | 934 | i1(vreg_1)降为 lane mask(32/64-bit SGPR),处理 phi 合并 |

### C.4 MachineSSAOptimization(5 类目标 pass、6 次目标插入——SIFoldOperands 在该阶段有两处调用点)

| Pass | 行数 | 作用 |
|---|---|---|
| SIFoldOperands | 3201 | GCN 指令操作数可内嵌立即数/内联常量/字面量,折叠即消除指令 |
| GCNDPPCombine | 888 | 把 mov + dpp 模式合并成单条 dpp 指令 |
| SILoadStoreOptimizer | 2937 | 融合邻近偏移的 DS/VMEM 指令(DS→DS、smrd x2 等) |
| SIPeepholeSDWA | 1549 | SDWA(子字寄存器寻址)peephole 模式应用 |
| SIShrinkInstructions | 1146 | 尽量用 32-bit 编码(VOP3 e64 → VOP1/2 e32) |
| (DeadMachineInstructionElim,通用) | — | 死机器指令消除 |

### C.5 寄存器分配段(addPreRegAlloc/addRegAssignAndRewrite/insertPass,16 个)

| Pass | 行数 | 作用 |
|---|---|---|
| GCNPreRALongBranchReg | 156 | RA 前按每指令 8 字节估算分支距离,估算可能超出相对分支编码范围(simm16×4 字节 ≈ ±128 KiB,`SIInstrInfo.cpp:3091-3098`;阈值可由 amdgpu-long-branch-factor 调)时预留一对 SGPR |
| GCNPreRAOptimizations | 346 | 把拆开的寄存器 tuple 初始化合并为单条 pseudo |
| SIOptimizeVGPRLiveRange | 783 | divergent if-else/waterfall 循环里砍 VGPR 活跃范围 |
| SILowerControlFlow | 941 | 控制流 pseudo → 真实机器指令(SI_ELSE/SI_BREAK 等) |
| SIWholeQuadMode | 1863 | 像素着色器 whole-quad-mode / 通用 whole-wavefront 模式切换 |
| SIOptimizeExecMaskingPreRA | 500 | exec mask peephole,RA 前做以降寄存器压力 |
| SIFormMemoryClauses | 435 | XNACK 开启时延长 SMEM/VMEM 指针寄存器活跃范围成 clause |
| AMDGPUPrepareAGPRAlloc | 120 | 为 MFMA 的 AGPR 分配做准备 |
| MachinePipeliner(通用) | — | 软件流水 |
| AMDGPURewritePartialRegUses | 475 | RenameIndependentSubregs 留下的半用 super-register 收缩 |
| RAGreedy ×3 段 | — | SGPR 段 / WWM 段 / VGPR 段(§5.5) |
| SILowerSGPRSpills | 644 | SGPR 专属 PEI:spill 优先用 VGPR lane,余者回退内存,含 CSR 处理 |
| SIPreAllocateWWMRegs | 282 | WWM 寄存器预分配 |
| SILowerWWMCopies | 172 | WWM_COPY pseudo 降级 |
| AMDGPUReserveWWMRegs | 130 | WWM 分配完的寄存器加保留标记 |
| AMDGPURewriteAGPRCopyMFMA | 778 | 用 VGPR 的 MFMA 改写为 AGPR 版本 |
| GCNNSAReassign | 393 | GFX10+ NSA image 指令寄存器从非连续重排为连续 |
| AMDGPUMarkLastScratchLoad | 164 | 标记最后一个 scratch load(供优先级 pass 用) |

### C.6 PostRA / PreSched2 / PostBBSections(5 次插入,其中 4 个为此前小节未计的新类)

| Pass | 行数 | 作用 |
|---|---|---|
| SIFixVGPRCopies | 89 | 给向量寄存器 copy 加 exec implicit use |
| SIOptimizeExecMasking | 943 | exec mask 布尔运算化简(s_and_b64 链等) |
| SIPostRABundler | 252 | 把相邻 load/store 打 bundle,防 post-RA 调度拆散 |
| AMDGPUPreloadKernArgProlog | 211 | kernarg 预载的 prolog 兼容层(编译期开、运行时关的场景) |
| (SIShrinkInstructions 第二遍,同 C.4) | — | RA 后再收一轮编码 |

### C.7 PreEmit(12 个)

| Pass | 行数 | 作用 |
|---|---|---|
| GCNCreateVOPD | 376 | 相邻 VALU 指令打包成 VOPD 双发射(依赖 post-RA 调度把它们排到一起) |
| SIMemoryLegalizer | 2639 | 内存模型落地:原子/fence 的 scope、semantics 修饰选择 |
| SIPostRA16BitMovFolding | 363 | 16-bit mov 折叠 |
| SIInsertWaitcnts | 3775 | 插 s_waitcnt:按硬件计数器(vmcnt/lgkmcnt 等)追踪异步内存访问,消费点前插入满足依赖的等待(部分场景保守生成更强等待,:16) |
| SIModeRegister | 488 | MODE 寄存器(IEEE/dx10clamp/FP 舍入)状态机 |
| SIInsertHardClauses | 341 | 插 s_clause 形成硬子句 |
| SILateBranchLowering | 335 | early-terminate pseudo 等 final 分支形态选择 |
| AMDGPUSetWavePriority | 233 | 最后一条 VMEM 前临时抬 wave 优先级让年轻 wave 发射 |
| SIPreEmitPeephole | 954 | 发射前最后清扫 |
PostRAHazardRecognizer(通用壳,GCNHazardRecognizer 实现) | 4361 | 发射前全局 hazard 复查(§5.6 注释) |
| AMDGPUWaitSGPRHazards | 670 | GFX12 SGPR 读依赖插 s_wait_alu |
| AMDGPULowerVGPREncoding | 690 | gfx1250 上 >256 号 VGPR 插 S_SET_VGPR_MSB 切寻址模式 |
| AMDGPUInsertDelayAlu | 558 | GFX11+ 插 s_delay_alu 避免流水线停顿 |
| BranchRelaxation(通用) | — | 分支距离超限修复 |

### C.8 调度器侧组件(非 pass 形态,挂在通用调度器上)

| 组件 | 行数 | 作用 |
|---|---|---|
| GCNSchedStrategy(MaxOccupancy,默认)/ SIMachineScheduler(备选) | 3394+1992 | 默认走 GCNMaxOccupancy(`AMDGPUTargetMachine.cpp:1425-1456`);SI scheduler 仅 si-scheduler feature 开启时用 |
| GCNRegPressure | 1298 | SGPR/VGPR 分域计压模型 |
| GCNIterativeScheduler | 645 | 迭代式多目标调度 |
| GCNILPSched / GCNMinRegStrategy | 360+277 | ILP / 最小寄存器策略 |
| AMDGPUIGroupLP | 2834 | 指令组内依赖约束调度(graphics IGroup) |
| AMDGPUCoExecSchedStrategy | 1369 | co-execution 调度策略 |
| AMDGPUMacroFusion | 68 | 背靠背指令配对融合 |
| AMDGPUBarrierLatency | 203 | barrier 边加延迟(fence 语义) |
| AMDGPUHazardLatency | 76 | hazard 相关边调延迟 |
| AMDGPUExportClustering | 144 | shader export 聚类 |
| GCNVOPDUtils | 608 | VOPD 配对资格检查 |
| AMDGPUNextUseAnalysis | 2610 | next-use 距离分析(供调度) |

### C.9 模块级与 LTO(EP callback / 独立入口,非主流水线;8 个实际 pass 类 + 3 个辅助组件)

**实际 pass 类**(可被加入流水线的 pass):

| Pass | 行数 | 作用 |
|---|---|---|
| AMDGPUAttributorPass(Module 形态)+ AMDGPUAttributorCGSCCPass | 1685 | Attributor 框架推导 AMDGPU 属性(flat-work-group-size 等);两种形态分别是 Module 与 CGSCC(类定义 AMDGPU.h:437 起) |
| AMDGPUSimplifyLibCallsPass | 2107(与下行共享 AMDGPULibCalls.cpp) | 简化库调用(EP 形态) |
| AMDGPUUseNativeCallsPass | (同上文件) | 将选定数学库调用改写为 native_* 变体调用(改前缀、查函数、setCalledFunction,`AMDGPULibCalls.cpp:527`——仍是库函数调用),供后续优化和指令选择处理 |
| AMDGPUPromoteAllocaToVector | — | alloca → 向量(EP callback 形态) |
| AMDGPUPromoteKernelArguments | 225 | kernel 的 generic 指针参数提升为 global AS |
| AMDGPULowerKernelAttributes | 522 | 用 reqd_work_group_size 元数据消除 dispatch packet load |
| AMDGPUSplitModule | 1592 | FullLTO --lto-partitions 并行 codegen 的模块切分 |

**辅助实现组件**(非 pass,被上述 pass 或通用设施调用):

| 组件 | 行数 | 性质 |
|---|---|---|
| AMDGPUInstCombineIntrinsic | 2526 | InstCombine 的 AMDGPU intrinsic 钩子(TTI 实现文件) |
| AMDGPUCombinerHelper | 574 | GISel combiner 的 AMDGPU 辅助类(64-bit 编码判定等) |
| AMDGPUAsanInstrumentation | 369 | AMDGPUSwLowerLDS 使用的 ASan 插桩辅助函数(`AMDGPUSwLowerLDS.cpp:1325-1334` 调用),提供 redzone 计算、待插桩内存操作筛选及地址检查插桩;非独立 pass |

### C.10 R600 遗产(r600 target 专属,主流水线之外)

R600ClauseMerge(133)、R600EmitClauseMarkers(210)、R600ControlFlowFinalizer(919)、R600ExpandSpecialInstrs(343)、R600OpenCLImageTypeLowering(708)、R600OptimizeVectorRegisters(558)、R600Packetizer(395)等 7 个 pass + R600AsmPrinter/MCInstLower。全部服务于 VLIW4/5 时代的子句发射与打包,与 GCN 无关。

---

## 附录 D:NVPTX 全部 CodeGen pass 目录

与附录 C 对称。NVPTX 目标专属 pass 类:主 CodeGen 流水线 22 个(§5.7 统一静态口径,含 CtorDtorLowering),加 EP 新增类型(NVVMIntrRange、条件启用的 NVPTXCopyByValArgs)共 24 类;另 NVVMReflect/KernelInfoPrinter 走 EP callback,加 AsmPrinter 等非 pass 组件。行数实测;描述摘译自源码头注释;标注※的头注释缺失,由代码语义归纳。

### D.1 IR 层(addIRPasses 主流水线 13 个 + EP 新增类型 2 个,其中 CopyByValArgs 默认关闭)

(下表 13 个为 addIRPasses 直接添加的;NVVMIntrRange 在 pipeline-start EP callback 内**无条件加入**,NVPTXCopyByValArgs 走同一 callback 但受 `-nvptx-early-byval-copy` 开关控制、**默认关闭**)

| Pass | 行数 | 作用(摘译自头注释) |
|---|---|---|
| NVVMReflect | 234 | 把 `__nvvm_reflect("foo")` / llvm.nvvm.reflect 替换为整数(值来自模块 metadata);pipeline-start EP 再防御性跑一遍 |
| NVPTXImageOptimizer | 135 | 图像访问代码 IR 优化:access qualifier 已知时消掉 istypep intrinsic 等 |
| NVPTXAssignValidGlobalNames | 90 | 清洗全局变量名中 PTX 不合法的符号(ptxas 比 MC 更严) |
| NVPTXGenericToNVVM | 297 | 按 constant 限定符把 generic 全局变量转 .global/.const 访问 |
| NVPTXMarkKernelPtrsGlobal | 124 | byval 参数里载入的指针必在 global AS,插 addrspacecast 对使其显式化,供 AS 推断传播(仅 CUDA 接口) |
| NVPTXPromoteParamAlign | 316 | 提升 .param 空间参数/返回值对齐(封顶 PTX 最大值),使 load/store 可向量化 |
| NVPTXLowerArgs | 479 | kernel byval 参数改写为 param AS 指针并按使用方式三分支降级:只读(无逃逸/无条件分支)→param AS 直访跳过复制;grid_constant 或 cvta 只读→addrspacecast 直用;其余→local copy(`NVPTXLowerArgs.cpp:300-348`) |
| NVPTXLowerAlloca | 127 | generic alloca → local AS alloca + addrspacecast 回 generic |
| NVPTXAtomicLower | 71 | local memory 原子操作降为普通 load/store |
| NVPTXCtorDtorLowering | 258 | 全局 ctor/dtor 合并成单个带 metadata 的 init/fini kernel(与 AMDGPU 同构) |
| NVPTXTagInvariantLoads | 114 | 给常量全局变量/param 空间等来源的 load 打 invariant 标签(O>0) |
| NVPTXIRPeephole | 167 | ISel 前最后一刻的 IR peephole(FMA 折叠等)(O>0) |
| NVPTXLowerUnreachable | 176 | PTX 无 unreachable 指令;在特定 unreachable 前插入 `exit;` inline asm,保持 LLVM IR CFG 不变(`NVPTXLowerUnreachable.cpp:114`;仅 ptxas bug 变体) |
| (SROA/InferAddressSpaces/AtomicExpand/LoadStoreVectorizer/ExpandVariadics,通用,AMDGPU 同款) | — | — |
| NVVMIntrRange(EP) | 181 | 给返回值范围有限的 NVVM intrinsic 调用加 range 属性 |
| NVPTXCopyByValArgs(EP,默认关) | — | byval 参数提前复制(§5 注释块讨论过动机) |

### D.2 ISel 前置(addInstSelector 前半,2 个)

| Pass | 行数 | 作用 |
|---|---|---|
| NVPTXLowerAggrCopies | 199 | 大小很大或非常量的聚合 copy/memset/memcpy 降成循环 |
| NVPTXAllocaHoisting | 80 | 非入口块 alloca 提升到入口块 |

### D.3 ISel 与机器层(addInstSelector 后半 + addPreRegAlloc + addPostRegAlloc,7 个)

| Pass | 行数 | 作用 |
|---|---|---|
| NVPTXISelDAGToDAG | 2402 | 主指令选择器(SDAG) |
| NVPTXReplaceImageHandles | 1860 | Fermi 无 image handle,机器码层面替换为具体符号(要求先全内联) |
| NVPTXForwardParams | 177 | 设备函数参数的两种访问方式之一:.param 直访(simple case)或压栈;选定后前递 |
| NVPTXAddressFolder | 133 | 跨基本块携带的符号地址,把通用 mov 折叠回访存指令的地址操作数 |
| NVPTXProxyRegErasure | 114 | 擦除 ProxyReg pseudo(选指阶段用于保 callseq_end 不被死代码消除) |
| NVPTXPrologEpilogPass | 300 | 通用 PEI 的裁剪复刻,处理虚拟寄存器(头注释自述"大多是 PrologEpilogInserter.cpp 的拷贝") |
| NVPTXPeephole | 179 | mov %SPL,%depot / cvta.local 序列的 peephole(VRFrame→VRFrameLocal 替换) |

### D.4 EP callback 注册点(两个 EP 的 pass 及加入条件)

以下列出 pipeline-start 与 full-LTO-last 两个 EP 注册的 pass 及加入条件:

| Pass | 行数 | 加入条件 |
|---|---|---|
| NVVMReflectPass | 234 | 仅当 `Subtarget.hasTargetName()`(用户已提供目标架构;否则不提前折叠 nvvm.reflect) |
| NVVMIntrRangePass | 181 | callback 内无条件加入 |
| NVPTXCopyByValArgsPass | — | 仅当 `-nvptx-early-byval-copy` 选项开启(默认关) |
| KernelInfoPrinter | — | full-LTO-last;仅当未设 `-mllvm -no-kernel-info-end-lto`(`NoKernelInfoEndLTO` 为假,`TargetMachine.cpp:31`——选项无 nvptx- 前缀)时注册 |

注:NVVMReflect 在 addIRPasses 主流水线中无条件出现(D.1),EP 侧的条件重跑不增加去重类数(§5.7 的 22+2)。

### D.5 非 pass 组件(对比 AMDGPU 的 C.8)

| 组件 | 行数 | 作用 |
|---|---|---|
| NVPTXAsmPrinter | 2800 | 打印 PTX 文本:指令打印 + .reqntid/.maxntid 等元数据指令 + DWARF 文本形式 |
| NVPTXISelLowering | 8143 | SelectionDAG lowering(地址空间语义、类型合法化、所有 NVVM intrinsic 的 DAG 降级) |
| NVPTXAliasAnalysis | 148 | NVPTX 地址空间感知的别名分析 |
| NVPTXFrameLowering | 109 | 帧处理:emit mov %SPL,%depot 等 |
| NVPTXISelDAGToDAG + MCTargetDesc/NVPTXInstPrinter | 2402+~760 | 指令选择 + MC 层打印(MC 层无编码器/解析器/反汇编;组件清单见 §2) |
| (无调度器组件) | 0 | 默认 MachineScheduler,无任何定制 |

### D.6 对比要点

1. **规模**:22 个主 CodeGen pass 类(+2 个 EP 新增类型,其中 CopyByValArgs 默认关闭)vs AMDGPU 63 个(SDAG)/66(GISel);最大单文件 NVPTXISelLowering 8143 行(AMDGPU 为 SIISelLowering 21639)——单一 SDAG lowering 巨石是虚拟 ISA 后端的典型形态,机器层没有出口,全部重量压在 lowering 上
2. **头注释风格**:NVPTX 主流水线 pass 里仅 1 个(NVPTXCtorDtorLowering)用 /// 风格头注释,其余为 // 风格或缺失(※NVPTXAtomicLower 一句话注释即全文);AMDGPU 侧 79/80 都有 /// 块。文档化习惯差异明显
3. **最"深"的两个机器层文件**:NVPTXReplaceImageHandles 1860 行(Fermi 时代 image handle 不支持,在机器层做符号替换)和 NVPTXPrologEpilogPass 300 行(复刻通用 PEI 去掉物理寄存器部分)——两个都是历史包袱的产物,而非架构必然
4. **无 C.8 对应物**:NVPTX 完全没有调度器侧组件、hazard recognizer、waitcnt 类 pass——这些全部是"直出机器码"才有的负担
5. **名字上的镜像(部分)**:两边 IR 层 pass 名有形态相近者,但**任务并不一一对应同构**:CtorDtorLowering 两边同名同构;LowerArgs ↔ LowerKernelArguments(都是参数改写);其余只是名字相近、职责各异——PromoteParamAlign 做 .param 对齐优化,PreloadKernelArguments 做参数预载 user_data SGPR;LowerAlloca 是 AS 改写,PromoteAlloca 是寄存器/LDS 提升;AtomicLower 消除私有内存原子操作,AtomicOptimizer 做 wave 内聚合优化;ImageOptimizer 消除类型检查,ImageIntrinsicOptimizer 优化 image intrinsic 序列——同一个问题域,不同切分,不宜按名字配对阅读

---

## 附录 E:clang 侧 GPU 支持文件清单

行数实测(main @ 3eda2aebadd4)。

### E.1 Driver/ToolChains

| 文件 | 行数 | 说明 |
|---|---|---|
| clang/lib/Driver/ToolChains/Cuda.cpp | 1101 | CUDA 工具链:ptxas/nvlink/fatbinary 命令行组装 |
| clang/lib/Driver/ToolChains/Cuda.h | 191 | |
| clang/lib/Driver/ToolChains/AMDGPU.cpp | 1406 | AMDGPU/HIP 工具链:lld 直链、--rocm-path 探测 |
| clang/lib/Driver/ToolChains/HIPAMD.cpp | 219 | HIP on AMD:device linking 流程 |
| clang/lib/Driver/ToolChains/HIPSPV.cpp | 450 | HIP on Intel(SPIR-V 出口) |
| clang/lib/Driver/ToolChains/HIPUtility.cpp | 102 | HIP 通用(如 bitcode 提取) |

### E.2 Basic/Targets

| 文件 | 行数 | 说明 |
|---|---|---|
| clang/lib/Basic/Targets/NVPTX.h | 210 | LangAS→NVPTXAS 映射、generic 超集关系 |
| clang/lib/Basic/Targets/NVPTX.cpp | 212 | |
| clang/lib/Basic/Targets/AMDGPU.h | 507 | LangAS→AMDGPUAS 映射、GPUKind/WavefrontSize 查询 |
| clang/lib/Basic/Targets/AMDGPU.cpp | 371 | |

### E.3 Sema

| 文件 | 行数 | 说明 |
|---|---|---|
| clang/lib/Sema/SemaCUDA.cpp | 1297 | CUDA+HIP 共用的双侧语义推导(HIP 寄生) |
| clang/lib/Sema/SemaOpenCL.cpp | 627 | OpenCL 语义(blocks/pipes/地址空间诊断) |

### E.4 CodeGen

| 文件 | 行数 | 说明 |
|---|---|---|
| clang/lib/CodeGen/CGCUDANV.cpp | 1544 | CUDA/HIP 注册代码生成(fatbin/hip 注册,一体两面) |
| clang/lib/CodeGen/CGGPUBuiltin.cpp | 192 | 跨 GPU builtin(threadIdx/blockIdx/laneid) |
| clang/lib/CodeGen/Targets/NVPTX.cpp | 374 | NVPTXTargetCodeGenInfo(kernel 标注) |
| clang/lib/CodeGen/Targets/AMDGPU.cpp | 791 | AMDGPUTargetCodeGenInfo(sret AS、syncscope、launch_bounds→属性) |

### E.5 内建定义

| 文件 | 行数 | builtin 数 | 说明 |
|---|---|---|---|
| clang/include/clang/Basic/BuiltinsNVPTX.td | 1379 | 427 | __nvvm_* 镜像 |
| clang/include/clang/Basic/BuiltinsAMDGPU.td | 1411 | 850 | __builtin_amdgcn_* 镜像 + Docs 表 |

### E.6 头文件(声明层)

CUDA 系 11 个 `__clang_cuda_*`、HIP 系 7 个 `__clang_hip_*`、公共 `__clang_gpu_*` 4 个 + amdgpuintrin.h + gpuintrin.h,以及 cuda_wrappers/hip_wrappers/openmp_wrappers/llvm_offload_wrappers 四套标准库包装目录;libclc(OpenCL runtime 库)目标含 SPIR/SPIR-V/AMDGPU/NVPTX。

### E.7 offload 工具

| 工具 | 行数 |
|---|---|
| clang-offload-bundler | 432 |
| clang-linker-wrapper | 1623 |
| clang-nvlink-wrapper | 838 |

(clang-offload-wrapper 已从 main 移除。)

---

## 附录 F:clang NVPTX 深入分析

§12.4 只给了 NVPTX 侧 374 行的概貌;实际上 clang NVPTX 支持有四个深水区,每个都值得单独剖析。以下全部基于源码逐行阅读(main @ 3eda2aebadd4)。

### F.1 NVPTXABIInfo:为 byval 而生的调用约定

`clang/lib/CodeGen/Targets/NVPTX.cpp:29-240`。这是 clang 中最独特的 ABI 实现之一:

- **聚合类型一律 byval 间接传**(`classifyArgumentType`,:183-203):`getNaturalAlignIndirect(Ty, AllocaAS, /*byval*/ true)`——这是后端 NVPTXLowerArgs 三分支决策的输入(§5.2;注意不是"必须复制":只读路径显式跳过复制,见下)。对比 AMDGPU:kernel 参数走 kernarg 显式 load(AMDGPUCallLowering),不走 byval
- **CUDA texture/surface 类型直接按 i64 传**(:192-199):`cuda::texture/surface` 在 device 侧退化为 64-bit 对象句柄,是 CUDA 图形互操作在 ABI 层的特例
- **OpenMP target device 的类型降级**(`classifyReturnType`,:166-169):不支持类型(fp128/超宽 BitInt)coerce 成 ≤64-bit 整数数组,这是 OpenMP NVPTX fallback 通道
- **VAArg 走 void* 风格**(:234-240):变长参数在 PTX 里没有硬件支持,用通用 void* 方案模拟

调用约定由 `computeInfo` 统一处理:非 C 约定强制尊重用户指定;kernel 函数的 CallingConv 在 `setTargetAttributes` 设为 `PTX_Kernel`(:86-88、:272)。

### F.2 kernel 标注:源码属性 → LLVM IR 标注 → PTX directive 的转换链

clang 侧的 kernel 标注(`clang/lib/CodeGen/Targets/NVPTX.cpp:263-284`)走的是**调用约定 + 参数属性 + 函数属性**三条 IR 通道,而不是元数据:

| 源码标注 | LLVM IR 标注(由 clang 写入) | PTX directive(由 AsmPrinter 打印,`:976-1035`) |
|---|---|---|
| `__global__` | 调用约定 `PTX_Kernel`(`:272`,setCallingConv)+ NoInline | (kernel 入口本身) |
| `__grid_constant__` 参数 | 参数属性 `"nvvm.grid_constant"`(`:274-278`;测试可见 `ptr byval(i32) "nvvm.grid_constant" %arg` 形态) | 非独立 directive:NVPTXLowerArgs/NVPTXTagInvariantLoads 等 IR pass 据此选择参数 lowering(免复制、invariant 标注) |
| `__launch_bounds__(max)` | 函数属性 `nvvm.maxntid`(handleCUDALaunchBoundsAttr `:329-369`) | `.maxntid` |
| `__launch_bounds__(…,min)` | 函数属性 `nvvm.minctasm` | `.minnctapersm` |
| `__launch_bounds__(…,…,maxBlocks)` | 函数属性 `nvvm.maxclusterrank` | `.maxclusterrank`(SM_90+ 才输出,否则 ptxas 硬崩,`:992-994`) |

后端还支持一个 clang 当前未提供源码属性入口的映射:LLVM IR 函数属性 `nvvm.maxnreg` → `.maxnreg`(`NVPTXAsmPrinter.cpp:990`,读取端 `NVVMProperties.cpp:290` getMaxNReg)。它属于"NVPTX 后端支持的 LLVM IR 属性"而非"clang 写入的标注";当前无前端命令行入口,只能由 IR 生成器直接写属性。

后端的读取端是 NVVMProperties.cpp:`getMaxNTID/getReqNTID/getClusterDim` 全部经 `getFnAttrParsedVector(F, NVVMAttr::…)`(`:246-254`)解析函数属性,AsmPrinter 据此打印 directive。**边界必须分清**:这条链的每一跳都在 LLVM 内闭合——clang 写 IR 标注,LLVM 后端读 IR 标注,AsmPrinter 输出 PTX 指令;ptxas 读到的是 PTX 文本里的 directive,它从不接触 LLVM IR 的属性或元数据。§4 说"文本即接口"指的正是这一层:接口是 PTX 指令,不是 IR 元数据。

真正的 named metadata `nvvm.annotations` 通道(`addNVVMMetadata`,`Targets/NVPTX.cpp:286-301`)是**另一条且更老的路径**,只承载 texture/surface/sampler/managed/rdoimage 这类 CUDA 图形对象标注:

```
!nvvm.annotations = !{!0}
!0 = !{ptr @tex, !"texture", i32 1}
```

它的消费者同样是 **LLVM 自己**——NVVMProperties.cpp:97 的 cacheAnnotationFromMD(getPTXOpaqueType 判定 texture/surface/sampler 类型、isManaged 判定 managed 变量,选指与 AsmPrinter 据此选 `.texref/.surfref/.samplerref` 声明)。源码里的 TODO(NVVMProperties.cpp:53)明说这些 legacy metadata 名字"应替换为正式的 function/parameter attributes"——即新代码的方向恰恰是从 metadata 迁往属性。

另有一个 LLVM 层的专用 intrinsic:`nvvm.texsurf.handle.internal`(`:107-110`),texture/surface 句柄的运行时提取,同样在选指时展开,不出 LLVM。

**与 AMDGPU 的可比口径**:两边可比的是"同一语义在各自产物接口上的形态"。AMDGPU 的 workgroup 大小等经 `amdgpu-flat-work-group-size` 函数属性 → HSAMetadataStreamer 流进 ELF 的 HSA msgpack note;NVPTX 的经 NVVM 函数属性 → AsmPrinter 打成 PTX 文本 directive。**属性是共同的 IR 载体,分岔只在最后一跳**:一边是结构化二进制(ELF note),一边是文本指令(PTX directive)。而 IR 层的 named metadata(nvvm.annotations)在 AMDGPU 侧没有对应物,因为图形对象语义在 AMDGPU 走 image intrinsic 的参数类型系统,不需要旁路标注。

### F.3 NVPTXTargetInfo:host 类型属性复制与边界对齐

`clang/lib/Basic/Targets/NVPTX.cpp:81-165` 的机制:**device TargetInfo 在构造函数中逐项复制选定的 host 类型属性**(LongWidth、PointerWidth、MaxAtomicInlineWidth 等),没有走 setAuxTarget+copyAuxTarget 路径。复制范围有明确的**排除清单**(:150-160 注释):LargeArrayMinWidth/LargeArrayAlign、SuitableAlign(跨边界不可见,且 host 有更宽向量类型时本就应不同)、LongDoubleWidth/LongDoubleAlign(device 的 long double == double,host 未必)——"全量镜像"不成立,是**选定属性的逐项复制 + 显式例外**。

```cpp
llvm::Triple HostTriple(Opts.HostTriple);
if (!HostTriple.isNVPTX())
  HostTarget = AllocateTarget(llvm::Triple(Opts.HostTriple), Opts);
...
PointerWidth = HostTarget->getPointerWidth(LangAS::Default);  // :111
BoolWidth   = HostTarget->getBoolWidth();                     // :113
SizeType    = HostTarget->getSizeType();                      // :132
...
MaxAtomicInlineWidth = HostTarget->getMaxAtomicInlineWidth(); // :153
```

动机(原注释 :149-152):`__GCC_ATOMIC_XXX_LOCK_FREE` 宏必须在 host/device 完全一致,否则 std:: classes 在两侧定义分叉,单一 TU 无法同时编译。复制清单有意排除 LargeArrayMinWidth/LongDoubleWidth 等跨边界不可见的属性(:155-164)。

**为什么 NVPTX 逐项复制得这么细**:CUDA 程序的常态是同一份 C++ 代码 host/device 双编译(TU 级共享类型),`__GCC_ATOMIC_XXX_LOCK_FREE` 宏必须两侧完全一致(:149-152 原注释),否则 std:: classes 定义分叉。复制清单有意排除 LargeArrayMinWidth/LongDoubleWidth 等跨边界不可见的属性(:155-164)。AMDGPU 侧走 setAuxTarget+copyAuxTarget(`AMDGPU.cpp:341-353`)复制可传递布局,再恢复自己的 LongDouble/Float128 格式(x87 80-bit 不被支持)——**"有无 host 复制"不是两家的差异点;差异在复制的具体范围与例外处理方式**(NVPTX 逐项白名单式,AMDGPU 通用复制+覆盖)。

### F.4 NVPTXToolChain / CudaToolChain:外部工具编排层

`clang/lib/Driver/ToolChains/Cuda.cpp`(1101 行)四个 Tool 子类构成完整的 NVIDIA 工具链:

| Tool | 行号 | 组装的命令 |
|---|---|---|
| NVPTX::Assembler | :398-543 | **ptxas**:`-m64 -O{0-3} --gpu-name <arch> --output-file -c [-g --dont-merge-basicblocks --return-at-end \| -lineinfo]` + `-Xcuda-ptxas` 透传 |
| NVPTX::FatBinary | :545-591 | **fatbinary**:`--create -64 --image3=kind={ptx\|elf},sm=<n>,file=<f>` |
| NVPTX::Linker | :593-691 | **clang-nvlink-wrapper**(注意:不是 nvlink 本体!):`-arch --ptxas-path= --cuda-path= --plugin-opt=-mattr=<features> [-L…]` |
| (host 侧)CudaToolChain | :899+ | 组织 device 编译动作,注入 `__CUDA_ARCH_LIST__` 宏(Clang.cpp:1095) |

关键设计细节:

1. **-O 映射**(:447-476):clang -O4/-Ofast→ptxas -O3,-Os/-Oz→-O2,无 -O→**-O0**(ptxas 默认 -O3,必须显式压回);调试信息开启时完全忽略 -O 并加 `--dont-merge-basicblocks --return-at-end`(ptxas 不接受 -g + 优化并存)
2. **CUDA 版本→PTX 版本映射表**(:704-759):34 行 CASE_CUDA_VERSION 宏表,CUDA 13.4→+ptx94 … CUDA 7.5→+ptx43;表存在的原因:新 CUDA 引入的新指令需要更高 PTX level 才能在 NVPTX 后端启用——**版本对齐是 PTX 模式的永久税**
3. **Relocatable(RDC)语义三态**(:494-509):OpenMP 默认可重定位、CUDA 由 -fgpu-rdc 控制、直接编译 nvptx 目标时强制可重定位
4. **-march=native 探测**:执行外部 `nvptx-arch` 工具(:870-897),多 GPU 时告警取第一个
5. **PTX 嵌入决策**(`shouldIncludePTX`,:526-543):`--cuda-include-ptx=` 控制是否把 PTX 文本一并打进 fatbin。注意这不是"前向兼容任意老驱动":驱动必须支持该 PTX 版本,新 PTX 在旧驱动上存在运行限制(NVIDIA 文档明确);嵌入的收益是同一 fatbin 覆盖"驱动支持的硬件范围"内未预编译的架构——**这正是 §4 "文本即接口"的产物二进制形态**

NVPTXToolChain::TranslateArgs(:778-814)还实现了 offload 默认 arch 注入(CudaDefault())与 generic 清除。

### F.5 CGCUDANV::makeModuleCtorFunction:fatbin 注册的 IR 生成

`clang/lib/CodeGen/CGCUDANV.cpp:843-1127`(makeModuleCtorFunction)在 host IR 里手工织出注册序列(文件头注释 :828-841):

```c
// CUDA:
void __cuda_module_ctor() {
    Handle = __cudaRegisterFatBinary(GpuBinaryBlob);
    __cuda_register_globals(Handle);
}
// HIP(实际生成的控制流,以 CGCUDANV.cpp:1026-1030 实现为准——源文件 :836-842 的文档注释把
// register_globals 画进了 if 内,与实现不符):
void __hip_module_ctor() {
    if (__hip_gpubin_handle == 0)
        __hip_gpubin_handle = __hipRegisterFatBinary(GpuBinaryBlob);  // 仅首次注册 fatbin
    __hip_register_globals(__hip_gpubin_handle);  // 每个模块 ctor 都执行,在条件之外
}
```

细节:
- fatbin 不是链接进来的,而是 **clang 在 CodeGen 阶段把整个 GPU 二进制文件读进内存,作为字节常量嵌进 host IR**(:869-880,VFS 读 OffloadBinaryToEmbedFile;传统 CUDA 构建路径)——该路径下一个 .cu 编译的最终 IR 里躺着完整的 device image
- HIP 的注册带 null 检查幂等保护,CUDA 不带(ctor 语义差异)
- 注册路径不止由 RDC 决定,还受 `-foffload-via-llvm` 与 NVCC ABI 兼容模式影响(`:257`、`:321`、`:342`、`:422` 各处按 OffloadViaLLVM 分叉):RDC 与非 RDC 走不同的注册形态(`createOffloadingEntries` :1295 vs `makeRegisterGlobalsFn` :637),offload entry 与传统 fatbin 注册是两条线
- fatbin 字节嵌入(CodeGen 读 OffloadBinaryToEmbedFile 进 IR)**仅限传统 CUDA 构建路径**;`-foffload-via-llvm` 走 offloading entries,不嵌入
- kernel 启动 stub:老版 `emitDeviceStubBodyLegacy`(:547)用 `cudaSetupArgument`/`cudaLaunch` 逐参数拷贝;新版 `emitDeviceStubBodyNew`(:420)用 `cudaLaunchKernel` 全参数一次过——**两代 CUDA runtime API 的活化石**
- `transformManagedVars`(:1259):managed 变量替换成运行时指针间接访问

### F.6 小结:clang NVPTX 的三重身份

1. **方言生成器**:ABI(byval/tex 句柄)+ kernel 标注三通道(调用约定/参数属性/函数属性,F.2)+ libdevice 头文件声明(§12.6)
2. **外部工具编排器**:ptxas/fatbinary/nvlink-wrapper 的命令行组装 + CUDA↔PTX 版本对齐表 + O 级别翻译
3. **host/device 桥**:TargetInfo 镜像类型系统 + fatbin 字节嵌入 + 注册代码 IR 织入

对照 AMDGPU:同样的三重身份都存在,但第 2 重(工具编排)退化成"调 lld",第 1 重更厚(sret AS/syncscope/launch_bounds 翻译),第 3 重结构相同(hipRegisterFatBinary 与 cudaRegisterFatBinary 同源)。**PTX 模式的"虚拟 ISA 税"在 clang 层的体现就是:每一代 CUDA/PTX/SM 版本演进,这张表(CUDA→PTX 映射、sm 列表、ptxas flag 差异)都要同步维护。**

### F.7 文件索引

| 文件 | 行数 | 角色 |
|---|---|---|
| clang/lib/CodeGen/Targets/NVPTX.cpp | 374 | ABI + kernel 标注转换链(F.2) |
| clang/lib/Basic/Targets/NVPTX.{h,cpp} | 210+212 | host 镜像类型系统、__CUDA_ARCH__ 宏 |
| clang/lib/Driver/ToolChains/Cuda.{h,cpp} | 191+1101 | NVPTXToolChain/CudaToolChain + 4 个 Tool |
| clang/lib/CodeGen/CGCUDANV.cpp | 1544 | CUDA/HIP 注册 IR 织入(fatbin 嵌入、两代 launch API) |
| clang/include/clang/Basic/BuiltinsNVPTX.td | 1379 | 427 个 __nvvm_* builtin |
| clang/lib/Headers/__clang_cuda_*.h | 11 个 | libdevice 声明 + math/cmath 覆写 |
| clang/tools/clang-nvlink-wrapper | 838 | LTO bitcode→cubin(内部调 ptxas) |

---

## 附录 G:clang AMDGPU 深入分析

与附录 F 对称。clang AMDGPU 支持的重心不在"编排外部工具"而在"把硬件资源模型(寄存器预算、地址空间、内存 scope、occupancy)前置到 IR 生成"。以下全部基于源码逐行阅读(main @ 3eda2aebadd4)。

### G.1 AMDGPUABIInfo:寄存器预算感知的三路分类

`clang/lib/CodeGen/Targets/AMDGPU.cpp:26-292`。与 NVPTX 的 byval 哲学正相反,按三种调用形态分别分类:

**1. Kernel 参数(:185-215)——绝不用 byval**。头注释(:183-184):"kernel 的所有参数实际经过一个特殊 buffer 传递,byval 没有意义"——即后端的 kernarg buffer(§5.2 AMDGPULowerKernelArguments 的消费对象)。聚合类型改用 `getIndirectAliased(constant AS)`;**HIP 指针参数被显式 coerce 成 global AS**(`coerceKernelArgumentType`,:37-44、:195-199)。与 NVPTXMarkKernelPtrsGlobal 的关系:两者都利用"kernel 指针必在 global AS"这一假设,但**转换对象与覆盖范围不同**——AMDGPU 的 coerce 只处理顶层标量指针(含提前展开的单字段结构体),源码 FIXME(:201-203)明说未转换 byref 结构体内部的指针;NVPTXMarkKernelPtrsGlobal(`NVPTXMarkKernelPtrsGlobal.cpp:9-13`)专门处理**从 byval 参数加载出的指针**,并覆盖整数加载后 inttoptr 的情况。不能据此认为 AMDGPU 用一次类型转换替代了整个 NVPTX pass。

**2. 函数参数(:217-292)——参数直传的估算阈值**。`MaxNumRegsForArgsRet = 16`(:28),`numRegsForType` 递归估算结构体展开后的 32-bit 寄存器数(:84-113)。决策链:先排除 ABI 特例(非平凡 C++ record 走 indirect、空类型忽略、单字段结构体提前展开直传、flexible array 回退默认,:231-250)→ 排除后,≤64-bit 聚合**不因剩余预算不足而转为间接传参**,按大小打包(≤16bit→i16,≤32→i32,≤64→2×i32,:252-267),但会扣减 NumRegsLeft(最低扣至零),影响**后续较大聚合**的分类 → 较大聚合检查剩余预算,充足则直传(:269-274)→ 不足则 indirect-aliased 私有 AS(:279-281)。**注意口径**:16 是参数 ABI 分类里"值传递 vs 间接传递"的估算阈值,不是函数的 SGPR/VGPR 总预算(那由后端 RA 与 occupancy 模型管理,量级远大于 16)。前端在 ABI 层感知寄存器占用这一点与 NVPTX 的"无限抽象"形成对照,但幅度是"估算直传上限",非资源总预算。

**3. 返回值(:144-181)——同样的打包 + 预算逻辑**。

三-vector 特例:`getOptimalVectorMemoryType`(:59-68)允许 3×32=96-bit 向量保持原样(GCN 有合法 96-bit 指令),其余交给默认逻辑。

### G.2 属性翻译:occupancy 控制面板

`setFunctionDeclAttributes`(:342-453)是 AMDGPU 硬件资源模型的前端总开关,一张表翻译九类源码级标注:

| 源码标注 | LLVM 函数属性 | 硬件语义 |
|---|---|---|
| `__launch_bounds__(max)` | `amdgpu-flat-work-group-size="1,max"` | 限 workgroup 大小 |
| `__launch_bounds__(max,min)` 第二参数 | `amdgpu-waves-per-eu=min`(**HIP 重新诠释**:不是 CUDA 的 minBlocks!,:389-394) | 限 occupancy |
| `amdgpu_flat_work_group_size(a,b)` | 同名属性(:737-766 handleAMDGPUFlatWorkGroupSizeAttr) | |
| `__attribute__((amdgpu_waves_per_eu))` | `amdgpu-waves-per-eu`(:768-786) | |
| `amdgpu_num_sgpr` / `amdgpu_num_vgpr` | `amdgpu-num-sgpr/num-vgpr`(:397-409) | **请求限制寄存器使用量**(实际数量可能按硬件分配粒度取整);**已弃用**,官方建议改用 amdgpu_waves_per_eu(AttrDocs.td:3681) |
| `amdgpu_max_num_work_groups(x,y,z)` | `amdgpu-max-num-workgroups`(:411-432) | dispatch 各维 workgroup 数量上界,供优化使用(AttrDocs.td:3714) |
| `__cluster_dims__(x,y,z)` / `__no_cluster__` | `amdgpu-cluster-dims`(:434-452) | thread block cluster(单位是 workgroup/thread block,AttrDocs.td:8021);两属性互斥 |
| (OpenCL 默认) | flat-work-group-size 上限 256;HIP 默认走 --gpu-max-threads-per-block(:375-385) | **连默认值都是资源决策** |
| `-mno-amdgpu-ieee`(+要求同时放宽 NaN,如 `-ffast-math`/`-menable-no-nans`,否则报错 `err_drv_amdgpu_ieee_without_no_honor_nans`,CompilerInvocation.cpp:2325-2328) | `amdgpu-ieee=false`(:472-473) | MODE 寄存器 |

对比 NVPTX 的 handleCUDALaunchBoundsAttr(F.2):那边只翻译三个 PTX 文本指令参数;这边每个属性都对应 occupancy 的一个硬件旋钮。另有 `requiresAMDGPUProtectedVisibility`(:328-340)把 hidden kernel/设备变量改 protected+DSOLocal(链接器优化)。

### G.3 内存模型的 IR 前置

三个钩子直接喂给后端 SIMemoryLegalizer / SIInsertWaitcnts(§C.7):

1. **getLLVMSyncScopeStr**(:534-549):SyncScope→IR syncscope 字符串,且 OpenCL 语义分叉——非 SC 操作默认按地址空间隔离 scope(`IsOneAs`,:538-542)
2. **setTargetAtomicMetadata**(:551-588):①flat 指针原子 + 线程私有内存 UB 语义 → `noalias_addrspace` range metadata 排除私有 AS(:562-571);②MMRA 注解(:573,MemoryModelRelaxationAnnotations,gfx90a+);③`amdgpu.no.fine.grained.memory` / `no.remote.memory` metadata(:580-583)——告诉后端可以省掉不必要的 scope fence;④denormal-ignore
3. **getNullPointer**(:487-498):私有/local AS 的 null 非 0 时,生成 generic null + addrspacecast(与 NVPTX 同款技巧,但条件驱动不同:这边按 getTargetNullPointerValue 判断)

另:getSRetAddrSpace(:501-508)不可拷贝类型 sret 用默认 AS 对齐 this 指针约定;getGlobalVarAddressSpace(:511-532)常量初始化的全局提升进 constant AS(4)。

### G.4 OpenCL 2.0 device-side enqueue 的 IR 克隆

`createEnqueuedBlockKernel`(:626-735)是 clang 里最奇特的 CodeGen 之一:为每个被 enqueue 的 block **手工织出一个新 kernel**:
- block literal 按值直传为第一个参数(:640-646),kernel 内 alloca 复制后转指针调 invoke(:680-690)
- 手写全套 OpenCL kernel_arg_* 元数据(:693-700,addr_space/access_qual/type/base_type/type_qual/name)
- 生成 runtime handle 结构 `{ptr kernel_object, i32 private_segment_size, i32 group_segment_size}`(:604-616)放 `.amdgpu.kernel.runtime.handle` 段(:730),MD_associated 关联(:728)
- kernel 本身 InternalLinkage——运行时只碰 kernel descriptor 不碰符号(:664-667)

后端对应物是 AMDGPUExportKernelRuntimeHandles(附录 C.1)——前后端在这里接力。CUDA 动态并行(CDP)**同样进 clang**:`CGCUDARuntime::EmitCUDADeviceKernelCallExpr`(`clang/lib/CodeGen/CGCUDARuntime.cpp:63-125`)在 device 侧生成 `<<<>>>` 调用的完整序列——参数 buffer 获取(emitGetParamBuf)、逐参数填充(copyInto)、config 非空守卫的条件执行、替换参数后发出 `cudaLaunchDevice` 调用(回归测试 clang/test/CodeGenCUDA/device-kernel-call.cu)。两边机制差异:CDP 是**显式的库调用风格**(程序经 cudaLaunchDevice 启动 kernel,运行时库承担调度);OpenCL enqueued block 是**语言级 block 字面量**,clang 需要手工织出 kernel 包装。

### G.5 工具链:ROCm 探测与 lld 直链

`clang/lib/Driver/ToolChains/AMDGPU.cpp`(1406 行)的结构与 Cuda.cpp 完全不同:

- **RocmInstallationDetector**(:95-524):scanLibDevicePath(设备 bitcode 库清单)、parseHIPVersionFile(读 HIP_VERSION 文件)、detectDeviceLibrary、detectHIPRuntime——约 430 行全部是"知道 ROCm 装在哪"的知识
- **amdgpu::Linker::ConstructJob**(:631-689):直接组装 **lld** 命令:`--no-undefined -shared -plugin-opt=mcpu=<gfx> -plugin-opt=-mattr=<features>`。此路径无 wrapper、无外部汇编器、无外部 fatbinary 工具(外层 clang-linker-wrapper 的使用见 §12.7 说明)
- **getAMDGPUTargetFeatures**(:690-722):wavefrontsize64、precise-memory、xnack/sramecc 开关
- **Target ID 解析**(:1042-1080):`gfx90a:sramecc+:xnack-` 这种带 feature 后缀的 target-id 语法解析与校验——比 NVPTX 的纯 sm_NN 复杂一档
- **getDeviceLibs**(:1190-1300):按 target-id 选 ROCm 设备库 bitcode(ockl/ocml 等)参与链接——两边设备数学库都是 bitcode LTO 形态;差别在下游:CUDA 的 libdevice 经 `-mlink-builtin-bitcode` 链接进设备 IR(`Cuda.cpp:933`),随 NVPTX 优化与 lowering 走到 PTX 再交给 ptxas,ROCm bitcode 链接后直达 llvm-link/lld、全程不出 LLVM

HIP 侧(HIPAMD.cpp 219 行 + HIPUtility.cpp 102 行):
- AMDGCN::Linker 按输出类型**互斥分支**选择(HIPAMD.cpp:199-210):TY_HIP_FATBIN→clang-offload-bundler 打 fatbin;TY_LLVM_BC→llvm-link 合并 bitcode;SPIRV target→constructLinkAndEmitSpirvCommand(:145-193);默认(amdhsa)→constructLldCommand 由 lld 出 code object。不是串行三步,而是一步四选一
- **HIP fatbin = clang-offload-bundler**(`constructHIPFatbinCommand`,HIPUtility.cpp:33-93):`-bundle-align -targets=host-x86_64-...,hipv4-amdgcn-amd-amdhsa--gfx90a`,甚至要塞一个 dummy host 条目(注释自嘲 "ToDo: Remove the dummy host binary entry")。**CUDA fatbin 用 NVIDIA fatbinary 工具,HIP fatbin 用 LLVM 自己的 bundler——§12.7 结论在 fatbin 环节的又一体现**

### G.6 AMDGPUTargetInfo:GPUKind 驱动 + AuxTarget 复制

`clang/lib/Basic/Targets/AMDGPU.{h,cpp}`(507+371 行):
- 特性查询走 `llvm::AMDGPU::getFeatureBitset(GPUKind)`(:57-72 of AMDGPU.h)——**复用 llvm/TargetParser 的处理器表**,clang 不维护自己的特性清单
- 宏:`__AMDGCN_CUMODE__`、`FP_FAST_FMAF`(按 GPUKind 条件)、规范化 gfx 名宏(连 gfx10-1-generic → gfx10_1_generic 的改名都处理)
- **host 类型对齐:setAuxTarget + copyAuxTarget**(`AMDGPU.cpp:341-353`)复制可传递的 host 类型布局,再恢复设备特例(保留自己的 LongDouble/Float128 格式)。与 NVPTX 的区别不在"有无复制",而在**具体复制范围与例外处理**:NVPTX 构造时逐项复制选定属性并显式排除若干项(F.3);AMDGPU 走通用 copyAuxTarget 再覆盖设备特例

### G.7 与附录 F 的镜像对照表

| 维度 | clang NVPTX | clang AMDGPU |
|---|---|---|
| kernel 参数 ABI | 聚合一律 byval;后端 LowerArgs 按使用方式三分支:只读→param AS 直访(跳过复制)、grid_constant/有 cvta 的只读→addrspacecast 直用、其余→local copy | 绝不 byval,直传进 kernarg buffer |
| kernel 指针 AS 显式化 | NVPTXMarkKernelPtrsGlobal(独立 pass;处理 byval 加载出的指针及 inttoptr) | ABI 分类内联 coerce(:195-199;仅顶层标量指针,结构体内部指针有 FIXME 未做);范围不同,非等价替代 |
| 寄存器 | 无限抽象(无感知) | 参数 ABI 分类带 16 寄存器估算阈值(小聚合不受限但仍扣减预算;非函数寄存器总预算) |
| launch_bounds | 3 个 PTX 指令参数 | 前两参数映射 flat-work-group-size / minimum waves-per-eu(HIP 重新诠释),第三参数当前忽略;显式 AMDGPU 属性优先(AttrDocs.td:3661;"9 类属性"是 G.2 全表范围) |
| kernel 标注 IR 载体 | 调用约定 + NVVM 函数/参数属性(→ PTX directive / IR pass 消费) | 调用约定(AMDGPU_KERNEL,:478)+ 函数/参数属性,部分语言路径另有 kernel metadata(→ ELF HSA note);对比见 F.2 |
| 内存模型 | ISel 映射 sem/scope(clang 侧 getLLVMSyncScopeStr 见 F.2);完成等待交 ptxas | syncscope 字符串 + atomic metadata 3 类 |
| null 指针 | local AS cast 技巧 | 非 0 null 值驱动的同款技巧 |
| 类型系统 | 构造时逐项复制选定的 host 属性+显式例外(F.3) | setAuxTarget+copyAuxTarget 复制可传递布局,再恢复设备特例(G.6);特性查询 GPUKind 驱动 |
| 设备库 | libdevice bitcode → 链接进设备 IR(-mlink-builtin-bitcode)→ LLVM 优化+NVPTX lowering → PTX → ptxas | ROCm bitcode → 链接进设备 IR → llvm-link/lld(全程 LLVM 内) |
| fatbin | NVIDIA fatbinary 工具 | clang-offload-bundler |
| 链接 | clang-nvlink-wrapper(838 行,专属)包装 | 设备链接器为 lld;外层可能经通用 clang-linker-wrapper(无 AMDGPU 专属 wrapper) |
| 版本税 | CUDA↔PTX 34 行映射表 | target-id feature 语法(xnack/sramecc) |
| 动态并行 | EmitCUDADeviceKernelCallExpr 生成参数 buffer+cudaLaunchDevice 调用(CGCUDARuntime.cpp:63) | createEnqueuedBlockKernel 织出 block→kernel 包装 + runtime handle(**OpenCL 2.0 路径**;HIP device 侧 launch 在 Sema 即拒绝,§12.3) |

### G.8 文件索引

| 文件 | 行数 | 角色 |
|---|---|---|
| clang/lib/CodeGen/Targets/AMDGPU.cpp | 791 | 三路 ABI + occupancy 属性翻译 + 内存模型 + enqueue 克隆 |
| clang/lib/Basic/Targets/AMDGPU.{h,cpp} | 507+371 | GPUKind 特性查询、宏 |
| clang/lib/Driver/ToolChains/AMDGPU.cpp | 1406 | ROCm 探测 + lld 直链 + target-id 解析 + 设备库选择 |
| clang/lib/Driver/ToolChains/HIPAMD.cpp | 219 | HIP 设备链接:按输出类型互斥分支选 bundler/llvm-link/SPIR-V/lld(G.5) |
| clang/lib/Driver/ToolChains/HIPUtility.cpp | 102 | HIP fatbin(clang-offload-bundler) |
| clang/include/clang/Basic/BuiltinsAMDGPU.td | 1411 | 850 个 __builtin_amdgcn_* |
| clang/lib/Headers/__clang_hip_*.h + amdgpuintrin.h | 7+1 | ocml 声明、math 覆写 |
