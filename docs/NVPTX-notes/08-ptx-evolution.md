# §9+ PTX ISA 硬件化演化——"虚拟层保稳定的代价=细节泄漏到下游"

> 基准：llvm-project main @ `3eda2aebadd4`（源码侧）+ PTX ISA 9.4 官方文档（docs.nvidia.com/cuda/parallel-thread-execution，全文已抓取核对）。
> 素材来源：子代理调研（源码行号+PTX changelog 原文均已核实）+ 主会话代写。
> 本文档论证 NVPTX 项目的关键命题：**外移给 ptxas 的复杂度没有消失，而是长在了 PTX ISA 本身——虚拟 ISA 正在"硬件化"**。

---

## 9.1 五个新指令族的证据链

### ① reconvergence 契约（PTX 8.x）
- PTX 文档 9.5 节原文："the optimizing code generator automatically determines points of re-convergence"——**reconvergence 决策在 ptxas**（§4"零结构化"的代价去向实锤）
- `.sync.aligned` 已成新指令强制契约：setmaxnreg 文档明确 "mandatory .sync / .aligned qualifier"
- LLVM 侧暴露：`isConvergent` 标记（NVPTXIntrinsics.td 20+ 处 `let isConvergent = true`）+ CALL 的 `_conv` 变体（NVPTXInstrInfo.td:2058-2081 foreach is_convergent）；**无独立 divergence 分析**（0 处 isDivergent，04-isel.md 已证）
- **判定：硬件细节**（对齐契约是 warp 调度器行为）

### ② cluster/DSMEM（sm_90，PTX 7.8）
- v7.8 changelog：mapa / getctarank / barrier.cluster / .shared::cluster
- LLVM 侧：NVPTXIntrinsics.td:169-187（barrier_cluster 系）、:6558-6589（mapa/getctarank defm）
- **判定：硬件细节**（分布式共享内存的物理拓扑）

### ③ TMA / cp.async.bulk（sm_90+，PTX 8.0/8.1/8.3）
- changelog 逐条：8.0 bulk ops、8.1 st.async/red.async、8.3 tensormap.replace
- LLVM 侧：CP_ASYNC_BULK_* multiclass 系（NVPTXIntrinsics.td:511-1312，**74 处引用、G2S/S2G/PREFETCH/TENSOR×dim×mode×override 多重 foreach**）
- **判定：硬件细节**（TMA 引擎的描述符/tensor map 语义）

### ④ tcgen05（Blackwell，PTX 8.6）——最重证据
- v8.6 changelog 完整清单：alloc/dealloc/relinquish_alloc_permit/ld/st/wait/cp/shift/mma/mma.sp/mma.ws/mma.ws.sp/fence/commit
- **TMEM 物理规格**（PTX 文档原文）："sm_100a 上 **512 columns × 128 rows、cell 32-bit、地址为 lane[31:16]+column[15:0]**"——**寄存器文件的物理位域布局进了 ISA 文档**
- LLVM 侧膨胀：NVPTXIntrinsics.td **143 处 tcgen05**（alloc :6630-6668、ld/st foreach :6842-6857、mma 七重 foreach :7272-7591）；NVPTXISelDAGToDAG.cpp getTcgen05Ld/StOpcode 各 37 case；NVPTXISelLowering.cpp **266 处 `case Intrinsic::nvvm_tcgen05`**（约 298 处 tcgen05 引用）
- **判定：纯硬件细节**（TMEM 位域/重排模式/ws 变体全是硬件微架构契约）

### ⑤ warp specialization：setmaxnreg
- 文档全文摘录：寄存器池语义、24-256 范围、**warpgroup 全体执行要求**
- LLVM 侧：NVPTXIntrinsics.td:6596-6606（2 个 intrinsic）、NVPTXInstrInfo.td:257 `hasSetMaxNRegSupport : PredOr<[SM90a, SM100f, SM110f, SM120f]>`
- **判定：硬件细节**（寄存器文件分区动态化）

## 9.2 核心论证：从虚拟层到准 ISA 的光谱

```
纯虚拟（2007-）                          纯硬件（2024+）
@p 谓词 ── ld.global ── bar.sync ── barrier.cluster ── cp.async.bulk ── tcgen05
   │                                              │                    │
线程级抽象，                 拓扑/引擎契约          TMEM 位域、
ptxas 全自由编排             开始进 ISA 文档        mma 七重变体
```

- **@p 谓词**（老，纯虚拟）：SIMT 语义内建 ISA，ptxas 自由压成 warp 级 SASS（04-isel.md §5.2）
- **tcgen05**（新，贴硬件）：TMEM 512×128 位域、lane/column 寻址、七重 foreach 的 mma 变体——**LLVM 侧被迫长出 298 处 tcgen05 处理代码**
- **版谓词双轴膨胀**：NVPTX.td:27 PTXVersions 列表（**32→94 共 36 版**）；NVPTXInstrInfo.td tcgen05 系复合谓词（:179 hasTcgen05InstSupport、:196 LdRed=PTX88×SM103f/110f、:218 CpAsyncBulkRelaxed=PTX93×SM90a/100f/110f）

**结论**：PTX 没有保住"稳定虚拟层"——硬件竞争压力下，每代新特性（DSMEM/TMA/TMEM/warp-spec）都以"指令+物理规格"的形式直接进 ISA。**"虚拟 ISA 模式省掉的工程费没有消失，而是换成了"ISA 文档膨胀 + LLVM 侧 intrinsic 膨胀"两笔新账**。

## 9.3 对照 AMDGPU 的同等演化

- gfx90a：AMDGPU.td:499 GFX90AInsts、VOP3PInstructions.td VOPProfileSMFMAC 系 :967-1029（MFMA）
- gfx950：GCNProcessors.td:158、AMDGPUCoExecInfo.h / AMDGPUCoExecSchedStrategy.cpp、CoExecMask enum :45、VOP3PInstructions.td CoExecVariant 字段 :1927-2082

**分化形态**：AMDGPU 的同等演化是"**真实 ISA 长时序细节**"（调度模型/CoExec hazard——因为 RA 和调度在 LLVM 内）；PTX 的是"**虚拟 ISA 长资源契约**"（TMEM 位域/setmaxnreg——因为资源管理在 ptxas 内）。**两侧都在长硬件细节，长在哪由职责边界决定**。

## 9.4 昇腾映射（推理级，待验证）

1. **davinci 汇编的硬件化**（待验证）：m200 的 repeat/cmpmask 细节是否已进汇编层（`set_cmpmask` 的"多 repeat 仅首条生效"若是汇编器契约而非文档脚注，则 davinci 已在 tcgen05 的路上）
2. **对 pto-isa 的直接启示**：tile 层现在偏"纯虚拟"（类似 2007 的 PTX）。**选项 A**：保持虚拟，让 pto-isa 后端消化硬件细节——代价是重演 NVPTX 的 298 处 intrinsic 膨胀；**选项 B**：提前吸收硬件细节（UB 512KB/TMEM 布局进 tile 语义）——代价是 ISA 不稳定。**PTX 的教训是"虚拟层保稳定"在硬件竞争下不可持续**，PyPTO 若预期 m200/m300 快速迭代，选项 B 更诚实
3. **"细节泄漏到下游"的量化观测**：本项目可复用本章方法（.td 引用计数 + 版本谓词数量）作为"ISA 硬件化程度"的度量——pto-isa 每代新增指令中"带物理规格"的占比，是该 tile 抽象健康度的指标

---

## 引用清单

| 来源 | 内容 |
|---|---|
| PTX ISA 9.4（docs.nvidia.com/cuda/parallel-thread-execution/）§9.5 | reconvergence 在 ptxas |
| PTX v7.8/8.0/8.1/8.3/8.6 changelog | cluster/TMA/tcgen05 指令清单 |
| PTX 文档 TMEM 规格 | 512 columns × 128 rows、lane[31:16]+column[15:0] |
| PTX 文档 setmaxnreg | 24-256、warpgroup 全体、mandatory .sync/.aligned |
| NVPTXIntrinsics.td:169-187, 511-1312, 6558-6606, 6630-6668, 6842-6857, 7272-7591 | 五族 intrinsic |
| NVPTXInstrInfo.td:179, 196, 218, 257, 2058-2081 | 版谓词/isConvergent |
| NVPTXISelLowering.cpp（266 处 tcgen05）/ NVPTXISelDAGToDAG.cpp（各 37 case） | LLVM 侧膨胀 |
| NVPTX.td:27 | PTXVersions 36 版 |
| AMDGPU.td:499 / VOP3PInstructions.td:967-1029, 1927-2082 / GCNProcessors.td:158 / AMDGPUCoExecInfo.h:45 | AMDGPU 对照 |
