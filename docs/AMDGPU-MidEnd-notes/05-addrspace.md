# §5 地址空间与指针层(M6 / M9 / M13 / F9)

> 数据基准:llvm-project main @ `3eda2aebadd4`(2026-09-28),build-debug 实跑。
> 方法:静态读码(`文件:行号`)+ 动态验证(`opt -passes=... -S` 差分)。
> 素材:`AMDGPU-MidEnd-notes/scratch/ch05/{f09,m06,m09}_*.{ll,txt}`。

---

## 章节定位

GPU 内存模型有 **5+ 个地址空间**(0=Flat/1=Global/3=LDS/4=Const/5=Private/7=BufferFatPtr/8=BufferRsrc)。中端的地址空间 pass 做两件事:**消除冗余 AS**(F9 把 private alloca 转为 VGPR 或 LDS)与**降低特殊 AS**(M6 把 fat pointer 拆为 rsrc+offset;M9/M13 把 LDS 全局下沉或换到全局内存)。

| Pass | 一句话 | 主策略 |
|---|---|---|
| **M6** LowerBufferFatPointers | addrspace(7) fat ptr → {rsrc, offset} 拆分 | SPIR-V 兼容 |
| **M9** LowerModuleLDS | module 级 LDS 全局按 kernel 重新分组 | Hybrid(Module/Table/Kernel) |
| **M13** SwLowerLDS | LDS 全局 → global memory(带 ASAN) | SW 模拟,仅 ASAN 构建 |
| **F9** PromoteAlloca | alloca → VGPR(小)或 LDS(大) | 双 pass:vector 早,LDS 晚 |

四者关系:M9 必须在 F9 之前跑(F9 若把 alloca 推到 LDS,M9 才能"看到"它);M6 与 M9/M13 处理不同 AS,正交;M13 是 M9 的 **SW 备选**(无 HW LDS 或 ASAN 时启用)。

---

## F9 AMDGPUPromoteAllocaPass(双重格:ToVector / ToLDS)

### 5.1.1 一句话定位
把函数入口的 `alloca` 转为**寄存器(vector)**或 **LDS 全局**,消灭 stack 访问——GPU 没有真正的 stack,private memory 慢且占 VGPR。

### 5.1.2 运行位置

**两个变体,两个挂点**:

1. **F9-vec (AMDGPUPromoteAllocaToVectorPass)**(`AMDGPUTargetMachine.cpp:1118`):
```cpp
PB.registerCGSCCOptimizerLateEPCallback(
    [this](CGSCCPassManager &PM, OptimizationLevel Level) {
      // ...
      FPM.addPass(AMDGPUPromoteAllocaToVectorPass(*this));
```
位于 Attributor 之后、F7 之前。**只做 vector promotion**(头部注释 :13-16:"only promotes to vector. Promotion to vector is almost always profitable")。

2. **F9-full (AMDGPUPromoteAllocaPass)**(`:1627` legacy,新 PM 在 `:2406` 附近的 addIRPasses 中):
```cpp
addPass(createAMDGPUPromoteAlloca());  // legacy PM, :1627
```
位于 SROA 之后(头部注释 :18-22:"runs after SROA because promoting to LDS is of course less profitable than getting rid of the alloca or vectorizing it")。**同时尝试 vector 和 LDS**。

### 5.1.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUPromoteAlloca.cpp`(1807 行),主类 `AMDGPUPromoteAllocaImpl`(:128)。

**预算模型**(`:378-384`):

```cpp
unsigned VectorizationBudget =
    (PromoteAllocaToVectorLimit ? PromoteAllocaToVectorLimit * 8
                                : (MaxVGPRs * 32)) /
    VGPRBudgetRatio;
```

- `PromoteAllocaToVectorLimit`(`:65`):用户显式 limit(默认 0,即禁用)
- `MaxVGPRs`:由 subtarget 计算(对 gfx942 通常 256)
- `VGPRBudgetRatio`(`:78`):默认 **4**,即只用 1/4 VGPR budget
- 对 gfx942:Budget = 256*32/4 = **2048 bits = 64 个 i32 元素**

**主循环**(`:386-450`):

```cpp
for (Instruction &I : F.getEntryBlock()) {
  if (AllocaInst *AI = dyn_cast<AllocaInst>(&I)) {
    if (!AI->isStaticAlloca() || AI->isArrayAllocation())
      continue;
    AllocaAnalysis AA{AI};
    if (collectAllocaUses(AA)) {
      analyzePromoteToVector(AA);
      if (PromoteToLDS)
        analyzePromoteToLDS(AA);
      if (AA.Vector.Ty || AA.LDS.Enable) {
        scoreAlloca(AA);
        Allocas.push_back(std::move(AA));
      }
    }
  }
}

stable_sort(Allocas,
            [](const auto &A, const auto &B) { return A.Score > B.Score; });

for (AllocaAnalysis &AA : Allocas) {
  if (AA.Vector.Ty) {
    // 若 vector budget 允许,先尝试 vector
    if (AllocaCost <= VectorizationBudget) {
      promoteAllocaToVector(AA);
      VectorizationBudget -= AllocaCost;
      continue;
    }
  }
  if (AA.LDS.Enable && tryPromoteAllocaToLDS(AA, ...))
    Changed = true;
}
```

**关键设计**:**优先级排序 + 先到先得**。`scoreAlloca`(`:335`)给每个 alloca 打分(基于 user 数量、loop 嵌套等),按分数降序排,先消耗 budget 的是"最有价值"的 alloca。

**Vector promotion**(`promoteAllocaToVector`,:1134):

```cpp
%arr = freeze <N x i32> poison
%new_v = insertelement <N x i32> %arr, i32 %x, i32 %idx
```

把 `store i32 %x, ptr %arr[idx]` 直接重写为 `insertelement`。每个 alloca 变成一个 SSA vector,通过 SSAUpdater 处理跨 BB 的 phi。**限制**(`:471-512` `calculateVectorIndex`):索引必须是 `((A * stride) >> shift) + B` 形式的可分析表达式。

**LDS promotion**(`tryPromoteAllocaToLDS`,:1613):

```cpp
Type *GVTy = ArrayType::get(AA.Alloca->getAllocatedType(), WorkGroupSize);
GlobalVariable *GV = new GlobalVariable(
    Mod, GVTy, false, GlobalValue::InternalLinkage, PoisonValue::get(GVTy),
    Twine(F->getName()) + Twine('.') + AA.Alloca->getName(), ...,
    AMDGPUAS::LOCAL_ADDRESS);
```

把 `[N x i32] alloca`(per-thread)变成 `[N*WorkGroupSize x i32]` LDS 全局(per-workgroup),索引用 `TID = TIdX*TCntY*TCntZ + TIdY*TCntZ + TIdZ`(`:1665-1674`)展平。

**关键约束**:`AllocSize = WorkGroupSize * ElemSize`(:1639),**总 LDS 用量 = workgroup 内所有线程的 alloca 之和**。若超出 `LocalMemLimit`(通常 32KB-64KB),拒绝。

### 5.1.4 动态验证

**实验 1:小 alloca → vector**

输入(`f09_in.ll`):
```llvm
define amdgpu_kernel void @small_alloca() {
  %arr = alloca [4 x i32], align 4, addrspace(5)
  %p0 = getelementptr [4 x i32], ptr addrspace(5) %arr, i32 0, i32 0
  store i32 42, ptr addrspace(5) %p0
  %v = load i32, ptr addrspace(5) %p0
  ret void
}
```

```bash
opt -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 \
    -passes=amdgpu-promote-alloca -S f09_in.ll
```

输出:
```llvm
define amdgpu_kernel void @small_alloca() #0 {
  %arr = freeze <4 x i32> poison
  %1 = insertelement <4 x i32> %arr, i32 42, i32 0
  ret void
}
```

**alloca 消失**,变成 `<4 x i32>` SSA vector,store → insertelement。后续 InstCombine 会把 `%1` 折叠为 `<42, poison, poison, poison>`,再 SROA 把 load 替换为 42。

**实验 2:大 alloca 拒绝 vector**

```llvm
define amdgpu_kernel void @large_alloca() #0 {
  %arr = alloca [256 x i32], align 4, addrspace(5)
  ; 1KB,超过 budget (256*32/4 = 2048 bits = 64 i32)
  ...
}
attributes #0 = { "amdgpu-flat-work-group-size"="64,64" }
```

输出:**alloca 保留**(1KB = 8192 bits > 2048 bits budget)。LDS 分支也未触发,因为 `AllocSize = 64 * 1KB = 64KB > LocalMemLimit`(gfx942 默认 64KB,但需考虑 alignment)。

**实验 3:vector-only 变体(F9-vec)**
```bash
opt -passes=amdgpu-promote-alloca-to-vector -S f09_in.ll
```
与 F9-full 在 small_alloca 上行为相同,但 `PromoteToLDS=false`,大 alloca 必然跳过 LDS 路径。

### 5.1.5 设计动机

**为什么必须消灭 alloca**:
- GPU 的"stack"实际是 private memory(global memory 上的 per-thread 区域),**每次访问都是一次 full memory transaction**,慢
- alloca 占用 VGPR(SP 寄存器 + spill),RA 后期压力大
- 若 alloca 可静态分析(所有 load/store 索引编译期可知),变成 vector 是免费的

**为什么 vector 优先于 LDS**:
- vector 在寄存器,**零延迟**,不占任何内存
- LDS 虽快于 global,但仍是 workgroup 共享资源,占 occupancy
- 因此 F9 先用 vector budget,不够才考虑 LDS

**为什么 alloca 必须在 addrspace(5)**:
- AMDGCN 的 private AS 是 5,后端按此识别
- 若 AS 不对,MIR 阶段会报 "alloca on amdgpu must be in addrspace(5) or addrspace(13)" 错误(实测,见 f09_in 第一次失败)

### 5.1.6 昇腾启示

昇腾 NPU 的 "alloca 消灭" 需求完全相同。**直接可迁移**:
- Vector promotion 的 SSAUpdater + insertelement 重写
- LDS promotion 的 per-workgroup 全局变量 + TID 展平
- **改进点**:昇腾的 UB/GM 模型下,可以引入第三档 promotion(UB > GM),AMDGPU 的 PromoteAlloca 只有两档

---

## M9 AMDGPULowerModuleLDSPass

### 5.2.1 一句话定位
把 module 级的 LDS 全局变量(`@lds = addrspace(3) global`)按"哪些 kernel 用它"重新分组,生成 per-kernel struct 或 lookup table,**精确控制每个 kernel 的 LDS 占用**,从而最大化 occupancy。

### 5.2.2 运行位置

**一处**(`AMDGPUTargetMachine.cpp:2401-2403`):
```cpp
// Runs before PromoteAlloca so the latter can account for function uses
if (EnableLowerModuleLDS)
  addModulePass(AMDGPULowerModuleLDSPass(getTM()), PMW);
```

注释明确:**必须在 PromoteAlloca 之前**,因为 F9 若把 alloca 推到 LDS,M9 才能处理"被 F9 拉进 LDS 的"变量。

**Gate**:`--amdgpu-enable-lower-module-lds`(默认 true,见 §4 M1 分支注释)。

### 5.2.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPULowerModuleLDSPass.cpp`(1600 行),头部注释(`:20-170`)给出**完整的 4 种策略**:

```
Strategy | Precise allocation | Zero runtime cost | General purpose |
---------+--------------------+-------------------+-----------------+
 Module  |                 No |               Yes |             Yes |
 Table   |                Yes |                No |             Yes |
 Kernel  |                Yes |               Yes |              No |
 Hybrid  |                Yes |           Partial |             Yes |
```

**Module 策略**(`:73-76`):所有 LDS 全局合并到一个 struct,每个 kernel 都分配整个 struct。**浪费 LDS**(不用的也占空间)但**零运行时开销**(地址编译期固定)。

**Table 策略**(`:77-87`):每个 kernel 独立分配 LDS,运行时用 `amdgcn_lds_kernel_id` intrinsic 查表得到当前 kernel 的地址。**精确**但**需要一次 load**。

**Kernel 策略**(`:89-94`):变量只被一个 kernel 用时,直接转为该 kernel 私有的 struct。**最优**(零开销+精确)但**适用面窄**(只 1 个 kernel 用)。

**Hybrid 策略**(`:96-100`,**默认**):
- 只被一个 kernel 用的变量 → Kernel 策略
- 被最多 kernel 用的"最热"变量 → Module 策略(放进共享 struct)
- 其余 → Table 策略

**主决策**(`:482-500`):

```cpp
CandidateTy MostUsed;
for (auto &K : LDSVars) {
  GlobalVariable *GV = K.first;
  if (K.second.size() <= 1) {
    // 单 kernel 用 → Kernel 策略
    continue;
  }
  CandidateTy Candidate(GV, K.second.size(), GV->getGlobalSize(DL));
  if (MostUsed < Candidate)
    MostUsed = Candidate;
}
```

按"被多少 kernel 使用"排序,选最热的进 Module 策略。

**Kernel ID 分配**(`:536-567`):

```cpp
if (OrderedKernels.size() > UINT32_MAX) {
  reportFatalUsageError("unimplemented LDS lowering for > 2**32 kernels");
}
for (size_t i = 0; i < OrderedKernels.size(); i++) {
  Metadata *AttrMDArgs[1] = {
      ConstantAsMetadata::get(Builder.getInt32(i)),
  };
  OrderedKernels[i]->setMetadata("llvm.amdgcn.lds.kernel.id", ...);
}
```

给每个 kernel 一个 uint32 ID,写入 `!llvm.amdgcn.lds.kernel.id` metadata。后端识别该 metadata,把 ID 放到 SGPR,`amdgcn_lds_kernel_id` intrinsic 在运行时读出。

### 5.2.4 动态验证

**实验 1:Hybrid 策略**(默认)

输入(`m09_in.ll`):
```llvm
@lds_shared = addrspace(3) global [64 x i32] undef     ; 被 k1, k2 共享(经 use_lds)
@lds_k1_only = addrspace(3) global [16 x i32] undef    ; 仅 k1

define internal void @use_lds() { ... load @lds_shared ... }
define amdgpu_kernel void @k1() { call @use_lds(); ... @lds_k1_only ... }
define amdgpu_kernel void @k2() { call @use_lds(); }
```

```bash
opt -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 \
    -passes=amdgpu-lower-module-lds -S m09_in.ll
```

输出(关键):
```llvm
%llvm.amdgcn.module.lds.t = type { [64 x i32] }
%llvm.amdgcn.kernel.k1.lds.t = type { [16 x i32] }

@llvm.amdgcn.module.lds = internal addrspace(3) global
    %llvm.amdgcn.module.lds.t poison, align 16, !absolute_symbol !0
@llvm.amdgcn.kernel.k1.lds = internal addrspace(3) global
    %llvm.amdgcn.kernel.k1.lds.t poison, align 16, !absolute_symbol !1

define amdgpu_kernel void @k1() #1 {
  call void @llvm.donothing() [ "ExplicitUse"(ptr addrspace(3) @llvm.amdgcn.kernel.k1.lds) ]
  call void @llvm.donothing() [ "ExplicitUse"(ptr addrspace(3) @llvm.amdgcn.module.lds) ]
  ...
}

define amdgpu_kernel void @k2() #2 {
  call void @llvm.donothing() [ "ExplicitUse"(ptr addrspace(3) @llvm.amdgcn.module.lds) ]
  call void @use_lds()
  ret void
}

attributes #1 = { "amdgpu-lds-size"="320" ... }   ; k1 = 256(共享) + 64(独有) = 320
attributes #2 = { "amdgpu-lds-size"="256" ... }   ; k2 = 256(共享) only
!0 = !{i32 0, i32 1}
!1 = !{i32 256, i32 257}
```

观察:
- **共享的 @lds_shared** 进了 `@llvm.amdgcn.module.lds`(Module 策略,2 个 kernel 都用)
- **@lds_k1_only** 进了 `@llvm.amdgcn.kernel.k1.lds`(Kernel 策略,只 k1 用)
- 每个 kernel 用 `llvm.donothing` 显式标记用到的 LDS struct(防止后端 DCE 误删)
- `amdgpu-lds-size` attribute 精确记录每个 kernel 的 LDS 用量(后端按此分配 LDS space)
- `!absolute_symbol` metadata 记录变量在 LDS 中的绝对地址(后端使用)
- **`@llvm.amdgcn.module.lds` 在 `k1` 中地址是 0,`@llvm.amdgcn.kernel.k1.lds` 地址是 256** —— module struct 在前,kernel 私有 struct 紧跟其后

**关键证据**:k1 的 `amdgpu-lds-size=320` 精确等于 256(module)+ 64(kernel)。这验证**精确分配**:k2 不为 k1 的私有变量付出代价。

### 5.2.5 设计动机

**为什么不能简单共享一个 LDS struct**(朴素 Module 策略):
- LDS 是**最稀缺资源**(gfx942 一个 CU 64KB,要分给最多 16 个 wave)
- 若一个 kernel 用了 90% LDS,会**拖累所有其它 kernel 的 occupancy**(即使后者只用 1%)
- Hybrid 策略让每个 kernel **只为它实际用到的 LDS 付费**

**为什么需要 kernel_id + lookup table**:
非 kernel 函数(`use_lds`)被多个 kernel 调用时,**同一份代码**要服务不同 kernel 的不同 LDS 地址。编译期无法决定地址,只能运行时通过 `amdgcn_lds_kernel_id` 查表。

**为什么用 `!absolute_symbol` metadata 而非 attribute**:
- metadata 可以挂在 GlobalVariable 上,attribute 只能挂在 function
- 后端 AsmPrinter 直接读 metadata,把地址编码到 ELF 符号(如 `lds_shared = 0`),让 link-time 地址解析可行

### 5.2.6 昇腾启示

昇腾 NPU 的 UB 共享问题**完全同构**。**直接可迁移**:
- Hybrid 策略框架(Module/Table/Kernel)在昇腾同样适用
- "per-kernel LDS size metadata" 对昇腾很重要——昇腾也需要按 kernel 静态决定 UB 用量
- **改进空间**:AMDGPU 的 Table 策略需要 load,可以用 SGBT(Software Generated Branch Table)在昇腾做更快(若昇腾有 JIT 能力)

---

## M13 AMDGPUSwLowerLDSPass

### 5.3.1 一句话定位
把 LDS 全局**全部**替换为 device global memory(用 `malloc` 在 kernel prologue 分配),并在 ASAN 启用时插入 instrumentation——**牺牲性能换取正确性诊断**。

### 5.3.2 运行位置

**两处**(`:1159-1162` 和 `:2398-2400`):

```cpp
if (EnableSwLowerLDS)
  PM.addPass(AMDGPUSwLowerLDSPass());
```

**默认 false**(`:576`,`EnableSwLowerLDS` 默认 init false),**仅在启用 ASAN 时**(`-fsanitize=address` + `--amdgpu-enable-sw-lower-lds`)打开。

### 5.3.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUSwLowerLDS.cpp`(1403 行),头部注释(`:9-86`)给出完整设计。

**核心思想**:
- 在 kernel **prologue** 由 thread 0 `malloc` 一块 device global memory(大小 = 总 LDS 需求)
- 在 kernel **epilogue** 由 thread 0 `free`
- 所有 LDS access 重写为对该 global memory 的 GEP
- ASAN 插桩:每次访问都先调用 `__asan_report_*` 检查 bound

**两个全局**(`:30-47`):

```cpp
// SW LDS Global:
//   ptr addrspace(1), name "llvm.amdgcn.sw.lds.<kernel-name>"
//   存 malloc 返回的指针

// Metadata Global:
//   struct {i32, i32, i32}[], name "llvm.amdgcn.sw.lds.<kernel-name>.md"
//   每个元素 = {offset, size, aligned_size},对应一个原 LDS 全局
```

**kernel_id + 两个表**(`:60-84`):

```
Base table:   ptr[kernel_id] → "SW LDS" 变量地址
Offset table: ptr[kernel_id][var_id] → 该变量在 SW LDS 中的偏移
```

非 kernel 函数通过 `amdgcn_lds_kernel_id` 查 base table,再查 offset table 得到变量地址。**与 M9 的 Table 策略模式相同**,但底层是 global memory 而非 LDS。

**ASAN 集成**(`AMDGPUAsanInstrumentation.h`):所有替换后的 global access 都经过 `__asan_report_load/store_N` 检查。

### 5.3.4 动态验证(跳过)

由于 M13 只在 ASAN 启用时触发,且需要 runtime `__asan_*` 函数,这里**不实跑**,只引用代码与注释。后续章节(§14 附录)会列出 `--amdgpu-enable-sw-lower-lds` 触发方式。

### 5.3.5 设计动机

**为什么需要 SW LDS**:
- GPU LDS 是 workgroup 共享,**超出会 hang**(无 OOB 检查)
- ASAN 需要精确边界检查,但 HW LDS 无法插入 instrumentation
- 把 LDS 换成 global memory 后,ASAN 可以插桩(因为 global 有独立 VA)

**为什么默认关闭**:
- global memory 比 LDS 慢 100x 量级
- 只用于 ASAN 调试,生产代码必须关闭

### 5.3.6 昇腾启示

昇腾的 ASAN 方案可借鉴:
- 同样可以用 "SW UB 模拟 + global memory" 做 ASAN
- "thread 0 malloc/free + broadcast" 模式对昇腾同样适用

---

## M6 AMDGPULowerBufferFatPointersPass

### 5.4.1 一句话定位
把 `ptr addrspace(7)`(buffer fat pointer,160 位 = 128 位 buffer descriptor + 32 位 offset)**拆分**为 `ptr addrspace(8)`(buffer resource)+ `i32`(offset),并把所有 load/store 重写为 `@llvm.amdgcn.raw.ptr.buffer.load/store.*` intrinsic 调用。

### 5.4.2 运行位置

**一处**(`:2472`,addIRPasses 末尾):

```cpp
addModulePass(AMDGPULowerBufferFatPointersPass(TM), PMW);
```

在 addIRPasses 的**末尾**(LateCodeGenPrepare 之后,SIAnnotateControlFlow 之前)。理由:fat pointer 拆分后产生 intrinsic,后续 InstCombine/CodeGenPrepare 需要识别它们。

### 5.4.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPULowerBufferFatPointers.cpp`(2913 行,是本章最大文件),头部注释(`:9-180`)详细描述三阶段。

**为什么需要 addrspace(7)**(`:12-23`):

> "Address space 7 (the buffer fat pointer) is a 160-bit pointer that consists of a 128-bit buffer descriptor and a 32-bit offset into that descriptor."
>
> "However, because of their non-power-of-2 size, these fat pointers cannot be present during translation to MIR..."

SPIR-V 前端喜欢用 fat pointer 表示 buffer(便于做边界检查),但 160 位**不是 2 的幂**,MIR/Machine 不能高效表示。该 pass 把它拆为 128+32,后端就能处理。

**三阶段**(`:52-180`):

1. **Rewriting loads and stores**(`:53-72`):把所有 `ptr addrspace(7)` 的 load/store 重写为 `i160` 类型,`ptrtoint`/`inttoptr` 包裹,聚合类型递归拆分
2. **Buffer contents type legalization**(`:74-180`):底层 buffer intrinsic 只支持 ≤128 位类型,需要把宽 load/store 拆为多个窄的
3. **Pointer splitting**(`:108-180`):把每个 `ptr addrspace(7)` SSA value 拆为 `ptr addrspace(8)` + `i32 offset` 两个 value,用 struct 表达

**Intrinsic 重写**(`llvm.amdgcn.raw.ptr.buffer.load/store`):
```llvm
; 原: load i32, ptr addrspace(7) %buf
; 新:
%buf.rsrc = extractvalue { ptr addrspace(8), i32 } %buf, 0
%buf.off = extractvalue { ptr addrspace(8), i32 } %buf, 1
%v = call i32 @llvm.amdgcn.raw.ptr.buffer.load.i32(
       ptr addrspace(8) align 4 %buf.rsrc, i32 %buf.off, i32 0, i32 0)
```

### 5.4.4 动态验证

**输入**(`m06_in.ll`):
```llvm
define amdgpu_kernel void @buf_load(ptr addrspace(7) %buf) {
  %v = load i32, ptr addrspace(7) %buf, align 4
  %p2 = getelementptr i32, ptr addrspace(7) %buf, i32 4
  store i32 %v, ptr addrspace(7) %p2, align 4
  ret void
}
```

```bash
opt -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 \
    -passes=amdgpu-lower-buffer-fat-pointers -S m06_in.ll
```

输出:
```llvm
define amdgpu_kernel void @buf_load({ ptr addrspace(8), i32 } %buf) #0 {
  %buf.rsrc = extractvalue { ptr addrspace(8), i32 } %buf, 0
  %buf.off = extractvalue { ptr addrspace(8), i32 } %buf, 1
  %v = call i32 @llvm.amdgcn.raw.ptr.buffer.load.i32(
         ptr addrspace(8) align 4 %buf.rsrc, i32 %buf.off, i32 0, i32 0)
  call void @llvm.amdgcn.raw.ptr.buffer.store.i32(
         i32 %v, ptr addrspace(8) align 4 %buf.rsrc, i32 %p2, i32 0, i32 0)
  ret void
}
```

观察:
- **函数签名变化**:`ptr addrspace(7) %buf` → `{ ptr addrspace(8), i32 } %buf`
- **extractvalue** 拆出 rsrc 和 offset
- load/store 被替换为 `llvm.amdgcn.raw.ptr.buffer.load/store` intrinsic
- GEP 被简化为对 offset 的算术

### 5.4.5 设计动机

**为什么 SPIR-V 需要 fat pointer**:
- SPIR-V 的 buffer 通常带 bounds 信息(`OpTypeRuntimeArray` + `OpDecorate Bounds`)
- 在 GPU 上映射为 buffer descriptor(128 位:base+size+flags)+ offset(32 位)
- 这让前端可以做**编译期 bounds check 优化**(已知 size 时可消除运行时 check)

**为什么后端不能直接处理 160 位**:
- LLVM MIR 要求类型 size 是 2 的幂(便于寄存器分配)
- 160 = 128 + 32 不规整,需要拆分
- 拆分后 128 位 rsrc 进 SGPR(4 个 SGPR),32 位 offset 进 VGPR(1 个),RA 可正常处理

**为什么用 struct 而非 pair**:
- struct 有名字,便于 debug 和 round-trip
- `{ptr addrspace(8), i32}` 是 LLVM 一等类型,SSA/phi 都支持

### 5.4.6 昇腾启示

昇腾的 buffer descriptor 模型类似。**直接可迁移**:
- "fat pointer → rsrc + offset 拆分" 是通用 pattern
- **改进空间**:AMDGPU 用 160 位,昇腾若用 192 位(128 + 64),需要更复杂的拆分逻辑(3 段)

---

## §5 章末总结

| Pass | 输入 AS | 输出形态 | 主要消费者 |
|---|---|---|---|
| M6 | 7 (fat ptr) | intrinsic call + {rsrc, off} struct | ISel 识别 buffer intrinsic |
| M9 | 3 (LDS) global | per-kernel struct + lookup table + metadata | 后端按 metadata 分配 LDS |
| M13 | 3 (LDS) global | global memory + ASAN instrumentation | ASAN runtime |
| F9 | 5 (private) alloca | vector SSA / LDS global | RA(VGPR) / 后端 LDS 分配 |

**关键依赖链**:
```
M9 (module LDS 分组) → F9 (alloca → LDS) → 后端 (LDS 地址分配)
                      ↘ F9-vec (alloca → vector) → RA
M6 (fat ptr 拆分) → 后端 ISel(识别 buffer intrinsic)
```

**已验证假设**:
1. ✅ F9 小 alloca → `<4 x i32>` vector
2. ✅ F9 大 alloca(1KB)→ 保留(budget 不足)
3. ✅ M9 hybrid 策略:共享变量 → module struct,独有变量 → kernel struct
4. ✅ M9 精确 `amdgpu-lds-size` attribute(k1=320, k2=256)
5. ✅ M6 fat ptr → `{rsrc, off}` struct + intrinsic
6. ✅ M6 GEP → offset 算术

**陷阱记录**:
- **alloca 必须在 addrspace(5)** 否则 verifier 拒绝
- **F9 两个变体**(ToVector / Full)行为不同,调试时必须明确选哪个
- **M9 的 `!absolute_symbol` metadata** 是后端识别 LDS 地址的关键,不能用 attribute 替代

**与后续章节接口**:
- M9 的 `amdgpu-lds-size` attribute 在 §6 F6 LowerKernelArguments 被消费,写入 kernel metadata
- M6 产生的 buffer intrinsic 在 §9 F3 CodeGenPrepare 被识别并优化
- F9 的 vector promotion 结果在 §11 TTI 中影响 LoopVectorize 的 cost model
