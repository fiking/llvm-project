# §4 AMDGPU IR 层 pass 群深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，本仓库工作区实测（build-debug, gfx1100）。
> 引用格式 `文件:行号`；实测命令均可复现。素材来源：子代理调研（已核实引用）+ 主会话动态验证。

---

## 4.1 总览：IR 层在 AMDGPU 流水线中的位置

AMDGPU 的 IR 层 pass 分两批注入：

1. **CodeGen 流水线内**：`AMDGPUPassConfig::addIRPasses`（legacy, `AMDGPUTargetMachine.cpp:1565-1668`）与 `AMDGPUCodeGenPassBuilder::addIRPasses`（新 PM, `:2366-2448`，内容镜像）——llc 路径
2. **EP callback（优化管线挂载点）**：`registerPassBuilderCallbacks`（`:1021-1200`，共 9 处注册）——opt/LTO 路径，**这是 NVPTX 完全没有的维度**（NVPTX 仅 2 个 EP：`NVPTXCodeGenPassBuilder.cpp:321-349` 的 PipelineStart NVVMReflect 系 + FullLinkTimeOptimizationLast KernelInfoPrinter）

**架构含义**：AMDGPU 把大量需要**模块级信息**的 lowering（LDS 全局规划、closed-world Attributor、printf 绑定、fat pointer 拆解）下沉到优化器 EP 里，在 LTO prelink/postlink 的正确时机触发；NVPTX 则依赖 generic 管线 + libdevice，目标专属 IR 处理极少。

### addIRPasses 骨架（:1565-1668 逐项）

| 序 | pass | 关键点 |
|---|---|---|
| 1 | AMDGPUAttributorFunction / AMDGPUUseNativeCalls | intrinsic→隐式参数推导 |
| 2 | **AMDGPUAlwaysInlinePass** | "Function calls are not supported"（:1593-1595），全员 alwaysinline |
| 3 | InlinerPass | 与上成对 |
| 4 | AMDGPULowerKernelAttributes | dispatch packet 偏移处理（源码 :36-62） |
| 5 | **AMDGPULowerModuleLDS** | 必须在 PromoteAlloca 之前（"so the latter can account for function uses"，:1612-1615） |
| 6 | AMDGPUPromoteAlloca | 见 §4.2 功能卡 |
| 7 | **AMDGPUAtomicOptimizer** | 必须在 AtomicExpand 之前（:1617-1624） |
| 8 | CanonicalizeAlgorithm / LoopSimplify / LICM 等通用 | |
| 9 | InferAddressSpaces ×2（Late/VectorizerEnd EP 也各挂一次） | generic→具体 AS 推断 |
| 10 | AMDGPULowerIntrinsics / AMDGPUPrintfRuntimeBinding | |

### addCodeGenPrepare（:1670-1700，仍属 IR 层）

`PreloadKernelArguments(:1673) → LowerKernelArguments(:1676) → 基类 CodeGenPrepare(:1678) → LoadStoreVectorizer(:1681) → LowerBufferFatPointers + LowerIntrinsics(:1691-1692) → LowerSwitch(:1699)`

LowerBufferFatPointers 的摆位理由（`:1683-1690` 注释）：必须在 address mode matching（CodeGenPrepare）之后以利用其优化、且在 switch lowering / CFG flattening 之前。

### EP callback 注册全景（:1021-1200）

| EP | 挂载内容 | 行号 |
|---|---|---|
| PipelineParsing | `amdgpu-attributor-cgscc` | :1026-1035 |
| ScalarOptimizerLateEP | InferAddressSpaces | :1037-1043 |
| VectorizerEndEP | InferAddressSpaces | :1045-1051 |
| PipelineEarlySimplificationEP | PrintfRuntimeBinding / HipStdPar(非RDC) / Internalize+GlobalDCE / EarlyInlineAll | :1053-1079（LTO prelink 跳过） |
| PeepholeEP | UseNativeCalls / SimplifyLibCalls / UniformIntrinsicCombine | :1081-1092 |
| CGSCCOptimizerLateEP | PromoteKernelArguments(O2+) / InferAddressSpaces / LowerKernelAttributes / **PromoteAllocaToVector** | :1094-1121（注释："inlining 后、SROA/unroll 前"） |
| OptimizerLastEP | AMDGPUAttributor（非 prelink） | :1124-1135 |
| **FullLinkTimeOptimizationLastEP** | EarlyCSE(MSSA)、HipStdPar(RDC)、**LowerExecSync/SwLowerLDS/LowerModuleLDS**（支持 `-lto-partitions`）、InferAddressSpaces(O2+)、Attributor(FullLTOPostLink+closed-world)、KernelInfoPrinter | :1137-1188 |
| RegClassFilterParsing | （非 IR，寄存器类过滤） | :1190-1199 |

**FullLinkTimeOptimizationLastEP 是重点**：LDS 规划（LowerModuleLDS/SwLowerLDS）、跨 wave 同步 lowering（LowerExecSync）都挂在这里——它们需要 closed-world（全模块可见）信息，只有 LTO postlink 才有。

---

## 4.2 重点 pass 功能卡

### PromoteAlloca（AMDGPUPromoteAlloca.cpp，1807 行）

- **DEBUG_TYPE**：`amdgpu-promote-alloca`（:49）
- **做什么**：把 `alloca` 提升为 VGPR 向量（首选）或 LDS 全局（回退）
- **决策结构**：`AMDGPUPromoteAllocaImpl::run`（:370-452）——每个 alloca 同时做 `analyzePromoteToVector` + `analyzePromoteToLDS`，评分排序后**先向量后 LDS 回退**（:406-444）

**向量化预算模型**：
- 预算 = `PromoteAllocaToVectorMaxRegs`（默认 **32** 个 32b 寄存器, cl::opt, :70-74）× 32 bit ÷ VGPRBudgetRatio（默认 **4**，即只用 1/4 VGPR 预算, :76-81）
- 元素上限 = MaxVectorRegs×32 ÷ 元素位宽（:963-964）
- 非入口函数封顶 32 个 caller-saved VGPR（:226-231，"会强制 spill 除非确定内联"）
- 评分 = 每 use 1 分 + 循环内 use ×4（LoopUserWeight, :84-87; scoreAlloca :335-351），按分排序贪心（:406-444）

**LDS 提升条件**：
- 仅 kernel/entry CC（:1395-1409，PS/GS 等图形 CC 不支持 item ID intrinsic 且 LDS 只有部分可用）
- 容量 = WorkGroupSize × alloca 大小，创建 `[WGS x Ty]` 的 addrspace(3) 全局，TID 线性索引替换（:1640-1682）
- `hasSufficientLocalMem` 含动态 LDS（extern unsized）禁用逻辑（:1559-1565）与 **occupancy 分档检查**（:1588-1600：提升后 LDS 用量不能把 wave 数降到分档以下）

**动态验证（实测，gfx1100）**：

```bash
# A. 向量化：8xi32 → <8 x i32>（freeze poison + insert/extract）
# /tmp/promote.ll = kernel 内 alloca [8 x i32] + 动态下标 load
$ ./build-debug/bin/llc -march=amdgcn -mcpu=gfx1100 -print-after=amdgpu-promote-alloca -o /dev/null /tmp/promote.ll
define amdgpu_kernel void @k(...) {
  %arr = freeze <8 x i32> poison
  %0 = insertelement <8 x i32> %arr, i32 42, i32 0
  %1 = extractelement <8 x i32> %0, i32 %i    # ✓ 向量提升成功

# B. 超限回退：40xi32（>32 元素上限）→ 向量化拒绝，LDS 也不启用
$ ./build-debug/bin/llc -march=amdgcn -mcpu=gfx1100 -debug-only=amdgpu-promote-alloca -o /dev/null /tmp/p40.ll
Analyzing:   %arr = alloca [40 x i32], align 4, addrspace(5)
  <40 x i32> has an unsupported number of elements   # 40 > 32×32/32

# C. LDS 路径（关向量）：per-thread [5xi32] → per-WGS LDS 全局
$ ./build-debug/bin/opt -S -mtriple=amdgpu11.00-unknown-unknown \
    -passes=amdgpu-promote-alloca -disable-promote-alloca-to-vector \
    llvm/test/CodeGen/AMDGPU/large-work-group-promote-alloca.ll
@promote_alloca_size_63.stack  = internal addrspace(3) global [63  x [5 x i32]] poison  # WGS=63
@promote_alloca_size_256.stack = internal addrspace(3) global [256 x [5 x i32]] poison  # WGS=256
@promote_alloca_size_1600.stack= internal addrspace(3) global [1024 x [5 x i32]] poison # WGS 截断！
@occupancy_6.stack             = internal addrspace(3) global [64 x [42 x i8]] poison   # 336B 卡 6-wave 档
```

验证 C 的精髓：size_1600 请求 WGS=1600 但被截到 1024（越界风险交给索引）；occupancy_6 的 42×8B=336B/thread 恰好卡在 occupancy 分档边界——**LDS 提升的"资源预算"语义被实测捕捉**。

- **为什么存在**：GCN 无栈（无 push/pop），`alloca` 默认走 scratch memory（GLOBAL 段的低效路径）；VGPR 向量或 LDS 才是符合硬件资源模型的位置
- **昇腾映射**：PyPTO 的 tile 布局决策（UB vs TMEM vs GM）在问题结构上同构——都是"逻辑栈对象 → 物理资源"的预分配决策，且都有 occupancy 类预算（UB 512KB 上限）

### LowerModuleLDS（AMDGPULowerModuleLDSPass.cpp，1600 行）

- **做什么**：模块内多个 kernel 共享的 LDS 全局统一规划布局
- **设计文档就在文件头**：`:9-177` 是完整的设计说明——**Module/Table/Kernel/Hybrid 四策略**权衡表（:60-65），hybrid 为默认（分区逻辑 :577-651）
- per-kernel 帧布局：`{module.lds, pad, kernel instance, pad, dynamic}`（:1178-1187）
- 与后端协同：`"amdgpu-lds-size"` fnattr + `MD_absolute_symbol`（:134-139）
- object-linking 新路径：`runOnModuleLinkTime`（:911-1056，`R_AMDGPU_ABS32_LO` 重定位 + `amdgpu.lds.uses` metadata）
- **为什么存在**：LDS 是 workgroup 级物理资源，多个 use 函数/kernel 的别名与布局必须模块级统筹（这就是它必须排在 PromoteAlloca 之前的原因——后者要精确估算可用 LDS）
- **昇腾映射**：UB（Unified Buffer）的跨算子复用/对齐规划是同构问题；PyPTO 若做 UB 全局规划器，hybrid 分区策略（模块级共享区 + kernel 专属区 + 动态区）可直接参考

### LowerKernelArguments（AMDGPULowerKernelArguments.cpp，423 行）

- kernarg_segment_ptr intrinsic + 逐参 GEP 化；sub-dword 参数 alignDown + i32 load + LShr（:289-300）；v3→v4 load + shuffle（:308-312）；byref→GEP+cast（:254-263）；noalias 参数重建 alias.scope/noalias metadata（:72-202）
- **为什么存在**：GCN kernel 参数不在寄存器而在 kernarg segment（显存），必须显式 GEP 寻址加载
- **昇腾映射**：昇腾 kernel 参数走 GM descriptor，PyPTO 的参数绑定层同构

### PreloadKernelArguments（365 行）

- 只加 `inreg` 标记（:326）——SGPR 实际预载在 ISel 阶段完成；偏移 ≤ NumFreeUserSGPRs×4 才可载（:181-183）；hidden args 表（:92-97）；需要时克隆函数追加 hidden 参数（:128-167）
- **昇腾映射**：对应"kernel 参数直接进标量寄存器"的优化，昇腾侧是 scalar pipe 直读

### LowerBufferFatPointers（AMDGPULowerBufferFatPointers.cpp，2913 行）

- **头注释即算法文档**（:1-218）：AS7 = 160bit（128 rsrc + 32 off），三阶段：p7↔i160 适配 → ValueMapper 类型重映射 → SplitPtrStructs 拆 rsrc/off
- PHI 资源单根分析避免 waterfall（:143-174）；无 160-bit 原子（:66-67）
- **为什么存在**：buffer resource（V# 描述符）是 GCN 的硬件寻址模式，front-end 暴露为 fat pointer 后必须在 ISel 前拆成结构化字段
- **昇腾映射**：昇腾的 GM 描述符/bias 表寻址同构；PyPTO 的 DescriptorPtr 若要暴露给 Python 层，fat pointer 的"三阶段拆解"是参考

### AtomicOptimizer（AMDGPUAtomicOptimizer.cpp，1013 行）

- **默认策略 Iterative**（:528）；指针发散即放弃（:230-232）
- `!ValDivergent || !NeedResult` → wave_reduce intrinsic 路径（:778, :795-799）
- Iterative = cttz + readlane/writelane 循环（:560-619）；DPP 策略需 hasDPP + 32/64bit（:240-246）且 active-lanes ≤5 门槛（:703-710）；PS 需 ps_live 包裹（:729-742）
- **为什么存在**：divergent atomic 每线程一次访存是灾难；warp 级合并（DPP scan 或迭代选 lane）把 N 次原子操作折叠
- **昇腾映射**：昇腾无 warp-level atomic 原语，但"发散访存合并"思想对 PyPTO 的 gather/scatter 优化适用

### AlwaysInline（AMDGPUAlwaysInlinePass.cpp，172 行）

- `!EnableFunctionCalls` 时全员 alwaysinline（:135-149）；强制剥 noinline 的"hack"注释（:70-75）；LDS 用户强制 inline（:116-133）
- **为什么存在**：GCN 早期无函数调用硬件支持（无栈、无返回地址寄存器），一切调用必须展平
- **昇腾映射**：昇腾 AICore 同样无通用调用约定——PyPTO 算子融合策略本质是显式版的 AlwaysInline

### RewriteOutArguments（448 行）——**管线化石**

**重要发现**：当前 main 中该 pass 只注册了 initialize（AMDGPUTargetMachine.cpp:738）但**未插入任何管线**，仅能经 `opt -amdgpu-rewrite-out-arguments` 使用（测试 `rewrite-out-arguments.ll` 用 opt 驱动）。MaxNumRetRegs=16（:70-74）。这是"功能保留但退役"的活样本——LLVM 后端 pass 也有化石层。

### AMDGPUAttributor（1685 行）

- intrinsic→implicit-arg mask 映射表（:60-126）；closed-world 选项（:1177-1180）；CGSCC/Module 双形态
- **为什么存在**：kernel 的隐式参数（workgroup ID 等）按需最小化，ABI 级优化

### PromoteKernelArguments / LowerKernelAttributes / 其他

- PromoteKernelArguments（:1-16 头注释）：flat→global 提升，经 InferAddressSpaces 收尾（:113-131）
- LowerKernelAttributes：dispatch packet 偏移（:36-62）
- SimplifyLibCalls/UseNativeCalls 在 AMDGPULibCalls.cpp（:2063/:2088）——GPU 数学库的内联替换
- PrintfRuntimeBinding（470 行）：hostcall buffer 绑定
- SwLowerLDS（1403 行）/ LowerExecSync（260 行）：挂 LTO last EP（见 §4.1 表），本次未深读，留 §5/§9 补充

---

## 4.3 管线化石与顺序约束（本层的设计教训）

1. **LowerModuleLDS → PromoteAlloca**（:1612-1615）：资源估算依赖前序的模块级规划
2. **AtomicOptimizer → AtomicExpand**（:1617-1624）：目标版优化必须抢在通用展开前
3. **AlwaysInline + Inliner 成对**（:1593-1595）：硬件无调用支持是一切的前提
4. **LowerBufferFatPointers 挤在 CodeGenPrepare 和 LowerSwitch 之间**（:1683-1690）：注释明说"利用 address mode matching 的产出、避开 switch lowering 的 CFG 扰动"
5. **RewriteOutArguments 化石化**：功能存在但未接线——LLVM 流水线也有"退役未删"的层

**对 NVPTX 的架构含义**（引用已核实）：NVPTXTargetMachine.cpp 全文 384 行、零 EP callback 注册；AMDGPU 同口径 2858 行 + 9 处 EP。**IR 层的厚度差不是代码风格，是"LLVM 内闭环"的直接后果**——需要在编译期决策的资源问题（LDS 布局/寄存器预算/参数装载）在 PTX 模式下全部推给了 ptxas。

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| AMDGPUTargetMachine.cpp:1565-1668 | legacy addIRPasses |
| AMDGPUTargetMachine.cpp:2366-2448 | 新 PM addIRPasses |
| AMDGPUTargetMachine.cpp:1670-1700 | addCodeGenPrepare 序列 |
| AMDGPUTargetMachine.cpp:1683-1690 | LowerBufferFatPointers 摆位注释 |
| AMDGPUTargetMachine.cpp:1021-1200 | registerPassBuilderCallbacks 9 处 |
| AMDGPUTargetMachine.cpp:738 | RewriteOutArguments initialize（化石证据） |
| AMDGPUPromoteAlloca.cpp:49/70-87/226-231/280-340/335-351/370-452/963-964/1395-1409/1559-1600/1640-1682 | PromoteAlloca 全链 |
| AMDGPULowerModuleLDSPass.cpp:9-177/60-65/577-651/911-1056/1178-1187/134-139 | LowerModuleLDS |
| AMDGPULowerKernelArguments.cpp:72-202/254-263/289-312 | kernel 参数 lowering |
| AMDGPULowerBufferFatPointers.cpp:1-218/66-67/143-174 | fat pointer 三阶段 |
| AMDGPUAtomicoptimizer.cpp:230-246/528/560-619/703-742/778-799 | 原子优化双策略 |
| AMDGPUAlwaysInlinePass.cpp:70-75/116-149 | 全员 inline |
| NVPTXTargetMachine.cpp（384 行全文）/ NVPTXCodeGenPassBuilder.cpp:321-349 | 对照 |

实测命令索引：`/tmp/promote.ll`（向量化）、`/tmp/p40.ll`（超限回退 debug）、官方测试 `large-work-group-promote-alloca.ll`（LDS 路径 + occupancy 分档）。
