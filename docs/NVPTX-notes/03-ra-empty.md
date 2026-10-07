# §4+§6 NVPTX RA 空实现 + disabled pass 解剖 + 机器层 pass 深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，本仓库工作区实测（build-debug, nvptx64, sm_90, O2）。
> 引用格式 `文件:行号`；实测素材 `NVPTX-notes/scratch/pipe_log.txt`（86 pass 完整流水线）+ `ra_test.ll`。
> 素材来源：子代理调研（引用已核实）+ 主会话动态验证代写。
> 对照阅读：AMDGPU-notes/05-regalloc.md（三段式 RA）。

---

## 4.1 空 RA 完整证据链

| 证据 | 位置 | 原文/内容 |
|---|---|---|
| 新 PM 空 override | NVPTXCodeGenPassBuilder.cpp:115-116 | 注释 "NVPTX has no register allocation; virtual registers are emitted directly" + 空 `addTargetRegisterAllocator(...) override {}` |
| legacy 空 override | NVPTXTargetMachine.cpp:356-357 | `createTargetRegisterAllocator(bool) { return nullptr; // No reg alloc }` |
| 默认实现位置 | lib/Passes/CodeGenPassBuilder.cpp:786-792 | Optimized→RAGreedy，否则 RegAllocFast（被 NVPTX 覆盖掉） |
| **绕过后门** | CodeGenPassBuilder.cpp:800-819 | `-regalloc=default` 时才走 addTargetRegisterAllocator(:818)；**`-regalloc-npm=greedy`(:803-815) 会绕过目标 override 强塞 RAGreedy** |

**NVPTX 版 addOptimizedRegAlloc（:281-305）整体替换基类版本**（基类 :852-916）——所以不仅 allocator 空，连 `addRegAssignAndRewriteOptimized`/`VirtRegRewriterPass` 都不进流水线。保留的铺垫 pass：ProcessImplicitDefs、UnreachableMachineBlockElim（:283-285 注释：LiveVariables 需纯 SSA、legacy 隐式拉入）、LiveVariables+MachineLoopInfo（analysis）、PHIElimination、TwoAddressInstruction、**RegisterCoalescer**、**MachineScheduler**、StackSlotColoring。:301-302 有 `FIXME: Needs physical registers // MachineLICMP` 被注释掉。

`addFastRegAlloc`（:275-279）= PHIElimination + TwoAddress，同样无 allocator。

## 4.2 disabled pass：实为 11 个（修正：任务书说 10，实际多一个）

`:103-107` 模板参数：**PrologEpilogInserter、MachineLateInstrsCleanup、MachineCopyPropagation、TailDuplicate、StackMapLiveness、PostRAMachineSinking、PostRAScheduler、FuncletLayout、PatchableFunction、ShrinkWrap、RemoveLoadsIntoFakeUses**（legacy 侧 NVPTXTargetMachine.cpp:248-258 同样 11 个）。

注释 :98-102 原文："not play well with virtual regs hanging around after register allocation (which in our case, is *all* registers)"。

**机制**：CodeGenPassBuilder.h:374-379 disablePass 挂 BeforeCallbacks 按 pass 名过滤——**构建期剔除**（-print-after-all 里不会出现，实测确认）。

### 逐个失效模式（全部读源码核实）

| pass | 失效原因 | 源码证据 |
|---|---|---|
| MachineCopyPropagation | 硬断言 RA 后运行 | MachineCopyPropagation.cpp:97-100 "should be run after register allocation!" |
| PrologEpilogInserter | 要求 RA 后 + RegScavenger | PEI 头注 :17-18、:217 RegScavenger、:239 usesPhysRegsForValues |
| PostRAScheduler | AntiDepBreaker 依赖物理寄存器重命名破 WAR；且 NVPTX 走 NoItineraries（NVPTX.td:79）→ SchedModel.PostRAScheduler 默认 false（TargetSubtargetInfo.cpp:63-66）——disablePass 是双保险 | :130-131 |
| ShrinkWrap | 与 FrameLowering 冲突 | NVPTXFrameLowering.cpp:35 assert "Shrink-wrapping not yet supported" |
| TailDuplicate | post-RA 分支跳过 vreg SSA 更新 | TailDuplicator.cpp:407-409 |
| MachineLateInstrsCleanup | 目标是"PEI 帧锚点"产物 | 头注释明说 |
| StackMapLiveness/PatchableFunction | 物理寄存器 live-out / 二进制 patching 概念，PTX 文本层不存在 | — |
| FuncletLayout | funclet-EH 专属（NVPTX 无 EH） | — |
| RemoveLoadsIntoFakeUses | FakeUses 物理寄存器语义 | — |

**未被禁用的幸存者**（§6 亮点）：**BranchFolder、MachineBlockPlacement、LiveDebugValues、ExpandPostRAPseudos 仍在跑**（CodeGenPassBuilder.cpp:925-938, 657, 706）——它们恰好对 vreg 不敏感。

## 6.1 ISel 后 5 个幸存的目标 pass 功能卡

（addPreRegAlloc :257-263 / addPostRegAlloc :265-273，顺序注释 :268-270：Peephole 必须在 PrologEpilog 后）

| pass | 做什么 | 核心代码 |
|---|---|---|
| ForwardParams | "simple" ld.param vs "move param" 两模式 | NVPTXForwardParams.cpp:9-39 头注 + traverseMoveUse :55-82 |
| AddressFolder | MOV_B*_sym 折叠回访存地址操作数；**shared 特意排除保 CSE** | NVPTXAddressFolder.cpp:9-28, 63-65 |
| ProxyRegErasure | 保 callseq_end 的伪寄存器批量 RAUW | :31-72 |
| NVPTXPrologEpilog | **PEI 精简仿制版**：offset 计算+FI 消除+prologue | "NOTE: We do not have a call stack":189 / "No scavenger":193 / "No stack protector":221；帧寄存器=保留伪寄存器 VRFrame/VRFrameLocal/VRDepot（NVPTXRegisterInfo.cpp:40-51），eliminateFrameIndex :53-80 按 alloca addrspace(5) 分流到 %SPL；**emitEpilogue 为空**（NVPTXFrameLowering.cpp:90-91） |
| Peephole | LEA+cvta_to_local → VRFrameLocal 直接寻址 + 死 cvta 清理 | :47-109, :130-137 |

**"帧指针仅文本标记"命题成立**：%SP/%SPL/%depot 是 PTX 特殊命名寄存器，非硬件帧指针——prologue 只是文本上的 local 声明与地址计算约定。

## 6.2 MC 层状态：InstPrinter 是唯一 MC 消费者

`NVPTXMCTargetDesc.cpp:76-100` 仅注册：AsmInfo/InstrInfo/RegInfo/SubtargetInfo/**MCInstPrinter(:92)**/两个 TargetStreamer——**无 AsmParser/Disassembler/CodeEmitter/AsmBackend/ObjectWriter**。`grep -rln "AsmParser|Disassembler" lib/Target/NVPTX/` 零命中（对照组 AMDGPU 有 AsmParser/、Disassembler/ 目录）。

**虚拟寄存器穿越 MC 的机制**（%r1/%f2 直现 PTX 的根源）：
```
NVPTXAsmPrinter::encodeVirtualRegister（NVPTXAsmPrinter.cpp:668-687）
  把 vreg 编号+类别打包进 MCRegister 高位（NVPTXBaseInfo.h:32-49，KindShift=27）
NVPTXInstPrinter::printRegName（:39-55）
  解包打印 %r/%rd/%rs/%p/%rq 前缀
```
注：%f 是旧文档前缀，当前代码 B32→%r、B64→%rd、B128→%rq。

## 6.3 动态验证（实测，sm_90 O2）

**完整流水线**（scratch/pipe_log.txt，86 个 pass dump）：
- IR 层实测序列（含 NVVMReflect 实跑痕迹："Replace occurrences of __nvvm_reflect() calls with 0/1"）→ 强度削减四件套实测（separate-const-offset-from-gep → slsr → early-cse → nary-reassociate → early-cse）
- **RA 段实测序列**：`processimpdefs → unreachable-mbb-elimination → livevars → phi-node-elimination → twoaddressinstruction → register-coalescer → machine-scheduler → stack-slot-coloring → nvptx-prolog-epilog`
- **RAGreedy/VirtRegRewriter 出现 0 次**——"空 RA"是真空跑而非跳过，证明整体替换而非清空

**未禁用 pass 实测确认**：branch-folder、block-placement、livedebugvalues、postrapseudos、fentry-insert、xray-instrumentation、machine-sanmd、stack-frame-layout 全部在流水线中出现——子代理预判 100% 验证。

**虚拟寄存器直现 PTX**（scratch/ra_test.ll → PTX 输出）：
```
ld.param.b64 %rd1, [f_param_0];
ld.param.b32 %r1,  [f_param_1];
mul.wide.s32 %rd2, %r1, 4;
add.s64      %rd3, %rd1, %rd2;
ld.b32       %r2,  [%rd3];
```
**%rd1/%r1 就是 MIR 里的 %0:b64/%1:b32 原样编号**——vreg 编号穿越 AsmPrinter→MCInst→InstPrinter 全链路直达文本。

## 6.4 设计动机总结

1. **"LLVM 侧做一半"的精确边界**：RA/disabled 11 pass 的职责全部在 ptxas；保留的铺垫（coalescer/scheduler）是因为它们影响 **PTX 文本质量**（mov 数量、指令顺序=ptxas 的输入启发式）
2. **整体替换 vs 逐个 disable**：addOptimizedRegAlloc 整体替换让"空"成为结构保证（不依赖 disable 列表完整）；11 个 disable 是对**通用流水线里 PEI 后强制 pass** 的防御
3. **未禁用的 4+ 个 pass**：BranchFolder/BlockPlacement 对 vreg 不敏感所以能跑——**通用 pass 的"RA 无关子集"是意外收获**，不是设计

## 6.5 昇腾映射（推理级，待验证）

1. **透传模式对 CANN 的启示**：若 CANN 后端（LLVM fork→davinci）也是"虚拟寄存器透传到下游汇编器"，则用户可见 dump 是"未分配"状态——RA 质量完全不可见、不可调（AMDGPU 模式下用户可以用 -debug-only=regalloc 看到/干预）。验证方法：查 CANN 是否 disable PEI/PostRA 系 pass（同构指纹）
2. **"帧指针仅文本标记"**：davinci 汇编若也有伪帧约定，等价于把 ABI 复杂度藏在文本层而非硬件层——PyPTO 生成 davinci 汇编时的 UB 基址约定与此同构
3. **%-前缀命名即契约**：PTX 的 %r/%rd/%p 前缀是"类型在名字里"的弱类型文本约定；pto-isa 的 tile 命名（UB offset/TMEM）若走文本层可参考（编码信息放名字而非位域）

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| NVPTXCodeGenPassBuilder.cpp:98-116, 248-258, 257-279, 281-305, 301-302 | 空 RA + disabled + 铺垫 |
| NVPTXTargetMachine.cpp:356-357 | legacy 空 allocator |
| lib/Passes/CodeGenPassBuilder.cpp:786-792, 800-819, 852-916, 925-938, 657, 706 | 基类机制 + 未禁用 pass |
| CodeGenPassBuilder.h:374-379 | disablePass 机制 |
| MachineCopyPropagation.cpp:97-100 / TailDuplicator.cpp:407-409 / TargetSubtargetInfo.cpp:63-66 / NVPTXFrameLowering.cpp:35, 90-91 | 逐 pass 失效证据 |
| NVPTXForwardParams.cpp:9-39, 55-82 / NVPTXAddressFolder.cpp:9-28, 63-65 | 幸存 pass |
| NVPTXRegisterInfo.cpp:40-51, 53-80 | 帧伪寄存器 |
| NVPTXAsmPrinter.cpp:668-687 / NVPTXBaseInfo.h:32-49 / NVPTXInstPrinter.cpp:39-55 | vreg 穿越 MC |
| NVPTXMCTargetDesc.cpp:76-100 | MC 注册表（无四件） |
| NVPTX.td:79 | NoItineraries |

实测素材：scratch/pipe_log.txt（86 pass 完整序列）、ra_test.ll（%rd1/%r1 直现 PTX 实证）。
