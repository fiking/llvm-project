# §13 设计模式总结

> 数据基准:llvm-project main @ `3eda2aebadd4`(2026-09-28),build-debug 实跑。
> 方法:跨章节归纳(§3–§12 全部 pass 的共性)。
> 素材:`AMDGPU-MidEnd-notes/scratch/ch13/*`(验证表用)。

---

## 章节定位

前十一章(§3–§12)逐一解剖了 AMDGPU 中端的 **28 个 pass**(F 系列 Function pass + M 系列 Module pass + C1 CGSCC pass)。本章换个视角:**不再看单个 pass 做什么,而是看它们共同体现了哪些设计模式**。

GPU 中端与 CPU 中端的最大差异,不是"有哪些 pass",而是"为什么这样组织"——**SIMT 执行模型、5+ 地址空间、无 ABI、uniform/divergent 二元性、寄存器即生命**,这些硬件约束把通用 LLVM 中端"驯化"出了一套独特的形状。本章提炼出 **7 个设计模式**,每个模式都从具体 pass 的代码和实验中抽象而来,可作为昇腾 NPU 中端设计的对照清单。

---

## 13.1 全量索引:28 个 Pass 速查表

先给一张**按执行顺序排列**的总表(基于 `AMDGPUTargetMachine.cpp` 的 `addIRPasses` 挂点 :2360-2415 和 `addOptimLastPasses` :1040-1165):

| # | ID | Pass | 章节 | 一句话 | 挂点(AMDGPUTargetMachine.cpp) |
|---|---|---|---|---|---|
| 1 | M12 | RemoveIncompatibleFunctions | §3 | 删当前 gfx 不支持的函数 | :2367(第 1 个) |
| 2 | M11 | PrintfRuntimeBinding | §3 | printf → `__printf_alloc` | :2375 |
| 3 | M4 | CtorDtorLowering | §3 | `llvm.global_ctors` → init kernel | :2378 |
| 4 | M1 | AlwaysInline | §4 | 全模块标 `alwaysinline` | :2380-2384 |
| 5 | M5 | ExportKernelRuntimeHandles | §3 | enqueue handle → external | :2393(AlwaysInline 后) |
| 6 | M6 | LowerBufferFatPointers | §5 | addrspace(7) → {rsrc, offset} | :2400 |
| 7 | M9 | LowerModuleLDS | §5 | LDS 全局按 kernel 重分组 | :2402 |
| 8 | M13 | SwLowerLDS | §5 | LDS → global(ASAN) | :2404 |
| 9 | F2 | AtomicOptimizer | §8 | 原子操作 wave 级优化 | :1617-1623(gate 三重) |
| 10 | F9 | PromoteAlloca | §5 | alloca → VGPR/LDS | :2411(ToVector),:2468(ToLDS) |
| 11 | M16 | Attributor(Module) | §4 | 模块级 attribute 推断 | :2412-2416 |
| 12 | C1 | Attributor(CGSCC) | §4 | SCC 级 implicit arg 推断 | CGSCC 阶段 |
| 13 | F7 | LowerKernelAttributes | §4 | metadata 常量折叠 grid 查询 | :2420 |
| 14 | F3 | CodeGenPrepare | §9 | 整数除法展开、fdiv 降精度 | :2421 |
| 15 | F10 | PromoteKernelArguments | §6 | flat ptr → global AS | :2425 |
| 16 | M10 | PreloadKernelArguments | §6 | 参数加 `inreg` | :2428 |
| 17 | F6 | LowerKernelArguments | §6 | 参数 → kernarg.segment load | :2431 |
| 18 | M8 | LowerIntrinsics | §7 | barrier/buffer-load 降级 | :2396(`llc` 专属) |
| 19 | F12 | SimplifyLibCalls | §7 | OCML libcall → intrinsic | :2440 |
| 20 | F15 | UseNativeCalls | §7 | libcall → `__nv_*`(opt-in) | :2443 |
| 21 | F13 | UniformIntrinsicCombine | §7 | uniform lane 操作删除/降级 | :2446 |
| 22 | F5 | LateCodeGenPrepare | §9 | sub-dword load 加宽、向量打包 | :2490 |
| 23 | F14 | UnifyDivergentExitNodes | §10 | 多 divergent return 合并 | :2496 |
| 24 | F1 | AnnotateUniformValues | §10 | uniform 分支/load 打 metadata | :2500 |
| 25 | F16 | SIAnnotateControlFlow | §10 | divergent 分支插入 if/else/end_cf | :2503 |
| 26 | F11 | RewriteUndefForPHI | §9 | uniform PHI 的 undef 改写 | :2508 |
| 27 | M14 | HipStdParMathFixup | §12 | 数学 intrinsic → `__hipstdpar_*` | :1060/:1150(EnableHipStdPar) |
| 28 | M15 | HipStdParAcceleratorCodeSelection | §12 | 删非 kernel 可达函数 | :1061/:1151(同上) |
| 29 | M7 | LowerExecSync | §12 | named barrier ID 分配 | :1158/:2396 |

**注**:表中的"挂点"指 `addIRPasses`(llc 管线)或 `addOptimLastPasses`(opt -O 管线尾部),同一 pass 可能多处挂载(如 F9 两次、M14/M15 两处)。

**速查口诀**:
- **清场**(1-5)→ **地址空间**(6-10)→ **属性与参数**(11-17)→ **intrinsic 降级**(18-21)→ **CodeGen 准备**(22-26)→ **HIP/LTO**(27-29)。
- F 系列(Function)22 个,M 系列(Module)6 个,C1(CGSCC)1 个——**Module pass 少而精**(都在边界协调),Function pass 是主力。

---

## 13.2 模式一:Gate 三重奏——Feature / OptLevel / Triple

**现象**:大量 pass 不是"无条件跑",而是被 **2-3 个条件** gate 住,且 gate 的位置多样(命令行 flag、subtarget feature、opt level、triple)。

**典型案例**:

| Pass | Gate 1 | Gate 2 | Gate 3 | 代码位置 |
|---|---|---|---|---|
| F2 AtomicOptimizer | `isAMDGCN` | `OptLevel >= Less` | `Strategy != None` | AMDGPUTargetMachine.cpp:1617-1623 |
| F13 UniformIntrinsicCombine | `isAMDGCN` | — | — | :2446 |
| M8 LowerIntrinsics | `TM.getOptLevel() > None` | — | — | AMDGPULowerIntrinsics.cpp:108 |
| M12 RemoveIncompatibleFunctions | `RemoveIncompatibleFunctions` flag | `isAMDGCN` | — | :2367-2371 |
| M14/M15 HipStdPar | `EnableHipStdPar` | — | — | :655-659 |
| F15 UseNativeCalls | `--amdgpu-use-native` | — | — | :2443 |

**设计动机**:
1. **Feature gate**(`isAMDGCN`):同一套 LLVM 代码服务多个 target,AMDGPU pass 不能误伤其他后端。
2. **OptLevel gate**(`> None` / `>= Less`):O0 要保留调试信息和原始结构,某些优化(如原子优化、intrinsic 降级)会改变语义,必须跳过。
3. **Strategy/Flag gate**(`Strategy != None`、`EnableHipStdPar`):实验性/可选功能,默认关闭,显式开启。

**昇腾启示**:NPU 中端同样需要三重 gate——
- **Triple gate**(`isAscendNPU`):防止误伤其他后端;
- **OptLevel gate**:O0 保留原始结构用于调试;
- **Feature gate**:不同 NPU 型号(Ascend 910/310/910B)的指令集差异,用 feature bitset 控制 pass 启用。

**验证方法**:用 `opt -passes=<pass-name> -mtriple=amdgcn-amd-amdhsa -mcpu=gfx900` 手动调用时,**Triple gate 不生效**(因为 pass 已注册),但 Feature/OptLevel gate 仍生效(§3.1.4 实测)。

---

## 13.3 模式二:地址空间五元组——消除、降低、分组、提升、标注

**现象**:GPU 的 5+ 个地址空间(0=Flat/1=Global/3=LDS/4=Const/5=Private/7=BufferFatPtr/8=BufferRsrc)不是"后端细节",而是**中端优化的核心战场**。28 个 pass 中,**至少 8 个**直接操作地址空间。

**五种操作模式**:

| 模式 | Pass | 操作 | 目的 |
|---|---|---|---|
| **消除** | F9 PromoteAlloca | private alloca → VGPR/LDS | 消灭 stack 访问 |
| **降低** | M6 LowerBufferFatPointers | addrspace(7) fat ptr → {rsrc, offset} | SPIR-V 兼容 |
| **分组** | M9 LowerModuleLDS | module 级 LDS 全局按 kernel 重分组 | 减少 LDS 冲突 |
| **提升** | F10 PromoteKernelArguments | flat ptr 参数 → global AS | 利用 const 缓存 |
| **标注** | M10 PreloadKernelArguments | 参数加 `inreg` attribute | 触发 SGPR preload |

**设计动机**:GPU 没有"统一内存"抽象——每个地址空间对应不同的物理路径(缓存、延迟、带宽),中端必须**在 ISel 之前**把地址空间"定下来",否则后端无法选择合适的 load/store 指令。

**昇腾启示**:NPU 的地址空间模型(如 GM/UB/L1/L0A/L0B/L0C)同样需要中端 pass 处理——
- **消除**:把 UB alloca 提升到寄存器;
- **分组**:按 cube/vector 单元分组 L1 buffer;
- **标注**:给 DMA 传输的参数加属性,触发 preload。

---

## 13.4 模式三:Uniform/Divergent 二元性——所有 pass 的地基

**现象**:§4–§10 的 **几乎所有 pass** 都依赖 `UniformityAnalysis`(由 `isSourceOfDivergence`/`isAlwaysUniform` TTI 钩子驱动),这是 AMDGPU 中端**最深的一条暗线**。

**依赖链**:
```
TTI::isSourceOfDivergence (:1205) + isAlwaysUniform (:1268)
        ↓
UniformityAnalysis(通用分析,被 target 特化)
        ↓
F1 AnnotateUniformValues(打 metadata)
F13 UniformIntrinsicCombine(删 uniform lane 操作)
F2 AtomicOptimizer(判 atomic 是否 uniform)
F3 CodeGenPrepare(mul24 需要 divergent 输入)
F16 SIAnnotateControlFlow(divergent 分支插入 EXEC mask)
F11 RewriteUndefForPHI(uniform PHI 改写)
... (§4–§10 的一大半 pass)
```

**关键数据**(`AMDGPUTargetTransformInfo.cpp:1205-1340`):
- `isSourceOfDivergence` 判定 **6 类 divergent 源**:VGPR 传的 kernel 参数、private/flat load、atomicrmw/cmpxchg、workitem_id_y/z、一般函数调用、private→flat addrspacecast。
- `isAlwaysUniform` 识别 **3 类 uniform pattern**:TID/wavefrontsize 商、AND 掩码、`amdgcn_if/else` 的 extractvalue{1}。

**设计动机**:SIMT 模型下,"值是否 uniform"决定了:
- 用标量寄存器(SGPR,全 wave 共享)还是向量寄存器(VGPR,每 lane 一份);
- 分支走标量路径(快)还是 EXEC mask 路径(慢);
- 能否做"依赖 uniform 前提"的优化(如 F13 删 readlane、F2 用 wave.reduce)。

这些判定无法纯从 IR 语法推出——必须知道**硬件语义**(VGPR 传参、原子串行、workitem_id 的含义),所以放在 TTI 里。

**昇腾启示**:NPU 的 SIMT 模型(如 Ascend 的 cube/vector 单元)同样需要 divergence 分析——
- **登记 divergent 源**:lane-id、私有内存 load、原子操作;
- **识别 uniform pattern**:block-id、对齐掩码、控制流 mask;
- **驱动下游 pass**:uniform 分支优化、寄存器分配、指令选择。

---

## 13.5 模式四:无 ABI 的全展开策略——从函数边界到模块属性

**现象**:GPU 没有 ABI(应用二进制接口),函数调用的参数如果不是寄存器放得下,就得进 scratch(global 内存的私有区),每次访问都是内存往返。所以中端的策略是:**宁可内联爆寄存器,也不进 scratch**。

**链条**(§4):
1. **M1 AMDGPUAlwaysInline**:全模块标 `alwaysinline`,消灭函数调用;
2. **M16/C1 AMDGPUAttributor**:在全展开的图上做模块级/CGSCC 级 attribute 推断;
3. **F7 AMDGPULowerKernelAttributes**:用推断结果常量折叠 grid 查询;
4. **TTI::adjustInliningThreshold**(:1753):传大 alloca 时主动提高阈值,**强制内联**。

**动态验证**(§11.2.2):callee 接收 2KB private 数组,TTI 判定"不内联就得进 scratch,代价惨重",把 inline 阈值拉到 **69712**(天文数字),强制内联。

**设计动机**:GPU 的"调用栈"是奢侈品——没有硬件 call/return 指令,函数调用得靠软件模拟(jump + save/restore),参数传递得靠 scratch 内存。所以中端必须**在函数边界上激进**:宁可牺牲寄存器,也要消灭调用。

**昇腾启示**:NPU 的函数调用同样昂贵(无硬件 call 指令,参数走 UB/GM),中端应复刻:
- **全展开策略**:默认 alwaysinline,消灭函数边界;
- **模块级推断**:在全展开的图上做过程间分析;
- **alloca 惩罚**:传大数组时强制内联(避免 UB 内存往返)。

---

## 13.6 模式五:Module Pass 的稀缺性——边界协调的 6 个特例

**现象**:28 个 pass 中,**只有 6 个 Module pass**(M1/M4/M5/M6/M9/M11/M12/M13/M14/M15/M16/M7),其余都是 Function pass。这 6 个 Module pass 处理的**都是"跨函数协调"问题**。

**六个 Module Pass 的职责**:

| Pass | 跨函数协调点 | 为什么不能是 Function pass |
|---|---|---|
| M1 AlwaysInline | 全模块标属性 | 要看到所有函数 |
| M12 RemoveIncompatibleFunctions | 删除不兼容函数 | 要遍历全模块 |
| M4 CtorDtorLowering | 全局 ctor/dtor → init kernel | 要处理 `llvm.global_ctors` |
| M6 LowerBufferFatPointers | fat ptr 拆分 | 要保证一致性(同一 ptr 在所有函数中同样拆) |
| M9 LowerModuleLDS | LDS 全局重分组 | 要按 kernel 分组(跨函数) |
| M16 Attributor(Module) | 模块级 attribute 推断 | 要全模块可见性 |
| M7 LowerExecSync | named barrier ID 分配 | 要保证同一 barrier 在所有 kernel 中同 ID |
| M14/M15 HipStdPar | 删非 kernel 可达函数 | 要做模块级可达性分析 |

**设计动机**:GPU 的"模块"概念比 CPU 更强——一个 module 对应一个 GPU kernel 集合,它们共享 LDS、named barrier、常量缓存等资源。Module pass 的稀缺性反映了:**大多数优化可以在单函数内做,只有少数资源协调需要全局视野**。

**昇腾启示**:NPU 的 Module pass 应该同样稀缺——只在以下场景使用:
- **资源分配**(L1/UB buffer、named barrier);
- **跨 kernel 一致性**(同一 ptr 的 AS 转换);
- **模块级裁剪**(删 host-only 代码)。

---

## 13.7 模式六:TTI 利他化——通用优化的 GPU 驯化

**现象**:§11 专门讲了 TTI(TargetTransformInfo)如何让**通用优化**(LoopUnroll、Inline、Vectorize)产出 GPU 友好的代码。这是"暗线"——不出现在 AMDGPU 目录里,却同样深刻地塑造了最终代码。

**关键钩子**:

| TTI 钩子 | 影响的通用优化 | GPU 特化点 |
|---|---|---|
| `getUnrollingPreferences`(:114) | LoopUnroll | 私有/LDS 数组激进展开,if-PHI 奖励 |
| `adjustInliningThreshold`(:1753) | Inline | 大 alloca 传参强制内联(避免 scratch) |
| `isSourceOfDivergence`(:1205) | UniformityAnalysis(全局) | workitem_id/private load/atomic 等 divergent 源 |
| `getNumberOfRegisters`(:301) | 向量化/展开 | **谎报 4**,防 VGPR 爆 |
| `getLoadStoreVecRegBitWidth`(:376) | 向量化 | global 512bit,private 受限 |
| `preferSLPInstCountCheck`(:346) | SLPVectorize | gfx940/950 关闭(寄存器压力) |

**设计动机**:通用优化本来为 CPU 设计,直接用在 GPU 上会"水土不服"——
- CPU 的"越宽越好"直觉在 GPU 上是错的(VGPR 是最紧俏资源);
- CPU 的"函数调用廉价"直觉在 GPU 上是错的(scratch 内存往返);
- CPU 的"所有值平等"直觉在 GPU 上是错的(uniform/divergent 差异巨大)。

TTI 是**"成本模型抽象"**:通用优化在做决策时问 TTI"这条指令多少钱?""这个循环值得展开吗?",后端给出答案。AMDGPU 通过重写 TTI 钩子,让通用优化**反过来为 GPU 的目标服务**。

**昇腾启示**:NPU 的 TTI 应重点复刻:
1. **divergence 源表**(`isSourceOfDivergence`)——所有 uniform 优化的地基;
2. **寄存器保守策略**(`getNumberOfRegisters` 谎报)——NPU 的寄存器同样宝贵;
3. **scratch 厌恶的 inline 阈值**(`adjustInliningThreshold`)——NPU 的 UB/GM 访问同样昂贵。

---

## 13.8 模式七:Metadata 与 Attribute 的物化——从分析到落地

**现象**:多个 pass 的"输出"不是 IR 变换,而是**metadata 或 attribute**——把分析结果"物化"到 IR 上,供后端/下游 pass 消费。

**典型案例**:

| Pass | 物化形式 | 内容 | 消费者 |
|---|---|---|---|
| F1 AnnotateUniformValues | metadata | `!amdgpu.uniform` + `!amdgpu.noclobber` | 后端 load/store 优化 |
| F7 LowerKernelAttributes | attribute | `amdgpu-no-*`(no-implicitarg 等) | 后端寄存器分配 |
| M10 PreloadKernelArguments | attribute | `inreg` | 后端 SGPR preload |
| M7 LowerExecSync | metadata | `!absolute_symbol !{i32 ID, i32 ID+1}` | 后端 barrier 资源分配 |
| M11 PrintfRuntimeBinding | metadata | printf format string | 运行时 printf 实现 |
| F14 UnifyDivergentExitNodes | metadata | `!amdgpu.uniform` on branch | F16 SIAnnotateControlFlow |

**设计动机**:GPU 中端的很多分析(如 uniformity、attribute 推断)结果**无法直接变成 IR 变换**——它们需要后端在 ISel/寄存器分配时才能消费。所以中端把这些结果**物化成 metadata/attribute**,作为"留言"传给后端。

**昇腾启示**:NPU 中端同样需要 metadata/attribute 物化机制——
- **uniform 标注**:给 uniform 分支/load 打 metadata,供后端优化;
- **资源分配 ID**:named barrier/event 的 ID 编码成 metadata;
- **kernel 属性**:`asc-no-*` attribute 驱动后端寄存器分配。

---

## 13.9 七模式总览:一张图看 AMDGPU 中端设计

```
┌─────────────────────────────────────────────────────────────────┐
│                     AMDGPU 中端 28 Pass                          │
│                                                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ 模式1: Gate  │  │ 模式2: AS    │  │ 模式3:       │           │
│  │ 三重奏       │  │ 五元组       │  │ Uniform/     │           │
│  │              │  │              │  │ Divergent    │           │
│  │ Feature/     │  │ 消除/降低/   │  │ 二元性       │           │
│  │ OptLevel/    │  │ 分组/提升/   │  │              │           │
│  │ Triple       │  │ 标注         │  │ TTI 钩子     │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│                                                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ 模式4: 无 ABI│  │ 模式5:       │  │ 模式6:       │           │
│  │ 全展开       │  │ Module Pass  │  │ TTI 利他化   │           │
│  │              │  │ 稀缺性       │  │              │           │
│  │ AlwaysInline │  │              │  │ 通用优化     │           │
│  │ + Attributor │  │ 6 个边界协调 │  │ 的 GPU 驯化  │           │
│  │ + 阈值提升   │  │              │  │              │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│                                                                   │
│  ┌────────────────────────────────────────────────────────┐     │
│  │ 模式7: Metadata/Attribute 物化                          │     │
│  │                                                         │     │
│  │ 分析结果 → metadata/attribute → 后端消费                │     │
│  └────────────────────────────────────────────────────────┘     │
│                                                                   │
│  执行顺序:清场(1-5) → 地址空间(6-10) → 属性与参数(11-17)     │
│           → intrinsic 降级(18-21) → CodeGen 准备(22-26)      │
│           → HIP/LTO(27-29)                                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## 13.10 对昇腾 NPU 中端的迁移清单

基于以上 7 个模式,昇腾 NPU 中端设计可直接对照的清单:

### 必做(核心地基)
1. **divergence 分析**(模式3):登记 NPU 的 divergent 源(lane-id、UB load、原子操作),识别 uniform pattern(block-id、对齐掩码)。
2. **TTI 利他化**(模式6):实现 NPU 的 TTI 钩子,让通用优化产出 NPU 友好代码(寄存器保守、UB 厌恶、uniform 感知)。
3. **地址空间处理**(模式2):消除 UB alloca(提升到寄存器)、分组 L1 buffer、标注 DMA 参数。

### 应做(性能关键)
4. **全展开策略**(模式4):默认 alwaysinline,alloca 传参强制内联(避免 UB 内存往返)。
5. **Gate 三重奏**(模式1):Triple gate(`isAscendNPU`)+ OptLevel gate + Feature gate(910/310/910B 差异)。
6. **Metadata 物化**(模式7):uniform 标注、资源 ID 编码、kernel 属性(`asc-no-*`)。

### 可做(锦上添花)
7. **Module Pass 稀缺性**(模式5):只在资源分配、跨 kernel 一致性、模块级裁剪时用 Module pass。

---

## 本章小结

28 个 pass 不是孤立的——它们共同体现了 **7 个设计模式**,这些模式的根源是 GPU 的硬件约束:

| 模式 | 硬件约束 | 体现 pass |
|---|---|---|
| Gate 三重奏 | 多型号 GPU、调试需求 | F2/F13/M8/M12/M14/M15/F15 |
| 地址空间五元组 | 5+ 地址空间的物理差异 | F9/M6/M9/F10/M10 |
| Uniform/Divergent | SIMT 执行模型 | F1/F13/F2/F3/F16/F11 + TTI |
| 无 ABI 全展开 | 无硬件 call 指令、scratch 昂贵 | M1/M16/C1/F7 + TTI::adjustInliningThreshold |
| Module Pass 稀缺 | 大多数优化可在单函数内做 | M1/M12/M4/M6/M9/M16/M7/M14/M15 |
| TTI 利他化 | 通用优化需 GPU 特化 | GCNTTIImpl(:114/:1205/:1753/:301) |
| Metadata 物化 | 分析结果需后端消费 | F1/F7/M10/M7/M11/F14 |

**核心洞察**:GPU 中端不是"CPU 中端 + 一些 GPU pass",而是**从硬件约束出发重新组织的中端**。理解这 7 个模式,就理解了为什么 AMDGPU 中端长这样——**每一个设计决策都能追溯到 SIMT、地址空间、无 ABI、寄存器压力这些硬件事实**。

**对昇腾的总建议**:不要"抄 pass",要"抄模式"——先理清昇腾 NPU 的硬件约束(SIMT?地址空间?ABI?寄存器?),再对照这 7 个模式,设计昇腾自己的中端组织方式。
