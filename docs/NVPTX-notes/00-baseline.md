# NVPTX 深度分析 — 基线存档（Task 0）

日期：2026-09-29
基准：llvm-project main @ `3eda2aebadd4`

## 构建配置

| 构建目录 | 类型 | NVPTX | 用途 |
|---|---|---|---|
| build-shared | Release | 无（host only） | 不可用 |
| build-debug | Debug + Assertions | ✅ nvptx/nvptx64 | **动态验证一律用它** |

## 冒烟验证（已通过）

```bash
cd ~/code/llvm-project
printf 'define i32 @f(i32 %%a, i32 %%b) { ret i32 %%a }\n' > /tmp/np.ll

# 1. PTX 生成（sm_90 → PTX 7.8）
./build-debug/bin/llc -march=nvptx64 -mcpu=sm_90 -o /tmp/np.ptx /tmp/np.ll
# ✅ 输出: .version 7.8 / .target sm_90 / .address_size 64 / .visible .func (.param .b32 ...)

# 2. -debug-only 通道
./build-debug/bin/llc -march=nvptx64 -mcpu=sm_90 -debug-only=isel -o /dev/null /tmp/np.ll
# ✅ "FastISel is disabled" + SelectionDAG ISel 日志可见
```

## NVPTX DEBUG_TYPE 速查（实测 grep，供子代理直接用）

| pass | DEBUG_TYPE |
|---|---|
| NVPTXAliasAnalysis | `NVPTX-aa` |
| NVPTXCtorDtorLowering | `nvptx-lower-ctor-dtor` |
| NVPTXIRPeephole | `nvptx-ir-peephole` |
| NVPTXISelDAGToDAG | `nvptx-isel` |
| NVPTXISelLowering | `nvptx-lower` |
| NVPTXLowerAggrCopies | `nvptx` |
| NVPTXLowerArgs | `nvptx-lower-args` |
| NVPTXPeephole | `nvptx-peephole` |
| NVPTXPrologEpilogPass | `nvptx-prolog-epilog` |
| NVPTXPromoteParamAlign | `nvptx-promote-param-align` |
| NVPTXRegisterInfo | `nvptx-reg-info` |
| NVPTXMCExpr | `nvptx-mcexpr` |
| NVVMReflect | 待查（grep NVVMReflect.cpp） |

## 规模基线（实测）

- 72 文件（cpp+h+td）共 37,258 行（AMDGPU 311 条目 29.9 万行的 1/8）
- 关键文件：AsmPrinter 2800 / ISelLowering 8143 / ISelDAGToDAG 2402 / TargetMachine **384** / DwarfDebug 296 / NVVMReflect 234 / NVPTX.td 148
- 测试：llvm/test/CodeGen/NVPTX/ 582 个 .ll
- **本地无 ptxas/nvcc**——下游实测（cubin/fatbinary）不可行，相关章节静态分析为主

## 已核实锚点（任务书预置，子代理免重查）

- 空 addTargetRegisterAllocator：NVPTXCodeGenPassBuilder.cpp:116
- disabled pass 清单（10 个）：NVPTXCodeGenPassBuilder.cpp:103-107
- NVVMReflect 双跑：NVPTXCodeGenPassBuilder.cpp:325-339（pipeline-start EP 防御）
- LowerArgs byval 注释：NVPTXCodeGenPassBuilder.cpp:61-82
- 强度削减四件套：NVPTXCodeGenPassBuilder.cpp:157-173
- ptxas WAR 三案例：NVPTXTargetMachine.cpp:320（hasPTXASUnreachableBug）/ NVPTXMCExpr.cpp:31（.b16）/ NVPTXAsmPrinter.cpp:992（.maxclusterrank）
- kernel 元数据文本指令：NVPTXAsmPrinter.cpp:973-987
- NVPTX 地址空间七类：NVPTXISelLowering.cpp:321-327

## 子任务分工

| Notes 文件 | 章节 | 内容 |
|---|---|---|
| 01-architecture.md | §2 | 宏观架构 + PTX/SM 版本矩阵 |
| 02-ir-layer.md | §3 | IR 层 pass 群 + 血统学 |
| 03-ra-empty.md | §4+§6 | RA 空 + disabled pass 解剖 + 机器层 5 pass |
| 04-isel.md | §5 | 单路径 SDAG + 方言翻译举证 |
| 05-asmprinter.md | §8 | AsmPrinter 即出口 + WAR 三案例 |
| 06-downstream.md | §7 | 下游生态（ptxas/fatbinary/reflect 镜像） |
| 07-mc-absence.md | §9 | MC 层缺席分析（小任务） |
| 08-ptx-evolution.md | §9+ | PTX ISA 硬件特性表达（小任务，Web 调研） |
