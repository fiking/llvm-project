# §6 Kernel 参数层(M10 / F6 / F10)

> 数据基准:llvm-project main @ `3eda2aebadd4`(2026-09-28),build-debug 实跑。
> 方法:静态读码(`文件:行号`)+ 动态验证(`opt -passes=... -S` 差分)。
> 素材:`AMDGPU-MidEnd-notes/scratch/ch06/{f06,f10,m10}_*.{ll,txt}`。

---

## 章节定位

GPU kernel 参数有**三层形态**:
1. **IR 层**(函数签名,前端视角)——`define amdgpu_kernel void @k(i32 %a, ptr %p)`
2. **kernarg segment**(运行时 buffer,中间形态)——所有参数打包成一段 const memory
3. **SGPR preload**(物理寄存器,执行视角)——少量参数直接放 SGPR 加速

三个 pass 各管一层:

| Pass | 一句话 | 层 |
|---|---|---|
| **F10** PromoteKernelArguments | flat ptr 参数 → global AS 推断 | IR 层 → IR 层(AS 改写) |
| **M10** PreloadKernelArguments | 给参数加 `inreg` attribute,触发 preload | IR 层 → IR 层(标记) |
| **F6** LowerKernelArguments | 参数 → `kernarg.segment + offset` load | IR 层 → kernarg(显式 load) |

**执行顺序**(必须按此序):
```
F10 (AS 推断) → M10 (标记 inreg) → F6 (展开为 load)
```

理由:F10 修改参数类型(AS 转换),M10 在稳定 IR 上加 attribute,F6 把参数消费掉(替换 use),**任何参数改动必须在 F6 之前完成**。

---

## F10 AMDGPUPromoteKernelArgumentsPass

### 6.1.1 一句话定位
把 kernel 的 flat pointer 参数(`ptr` 即 `addrspace(0)`)**显式 addrspacecast 到 global**(addrspace(1))再 cast 回 flat,**让 InferAddressSpaces pass 看到 AS 转换点**,推断出"这个指针实际是 global",从而后续可以用 global-only 指令(如 `flat_load` → `global_load`)。

### 6.1.2 运行位置

**一处**(`AMDGPUTargetMachine.cpp:1104-1105`):

```cpp
if (Level > OptimizationLevel::O1 && EnablePromoteKernelArguments)
  FPM.addPass(AMDGPUPromoteKernelArgumentsPass());
```

Gate:
- **必须 O2+**(`Level > OptimizationLevel::O1`)
- `EnablePromoteKernelArguments`(`:597` `--amdgpu-promote-kernel-arguments`,默认 true)

**在 CGSCCOptimizerLateEP**,**正好在 InferAddressSpaces 之前**(:1106),设计的接力棒。

### 6.1.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUPromoteKernelArguments.cpp`(225 行),短小精悍。

**入口过滤**(`:159-183`):

```cpp
if (CC != CallingConv::AMDGPU_KERNEL || F.arg_empty())
  return false;

for (Argument &Arg : F.args()) {
  if (Arg.use_empty()) continue;

  PointerType *PT = dyn_cast<PointerType>(Arg.getType());
  if (!PT || (PT->getAddressSpace() != AMDGPUAS::FLAT_ADDRESS &&
              PT->getAddressSpace() != AMDGPUAS::GLOBAL_ADDRESS &&
              PT->getAddressSpace() != AMDGPUAS::CONSTANT_ADDRESS))
    continue;

  Ptrs.push_back(&Arg);
}
```

**关键**:只处理 AMDGPU_KERNEL + flat/global/constant AS 的指针参数。`addrspace(5)`(private)、`addrspace(3)`(LDS)指针不处理(它们有专用 backend 路径)。

**核心转换**(`promotePointer`,:94-134):

```cpp
if (PT->getAddressSpace() != AMDGPUAS::FLAT_ADDRESS)
  return Changed;  // 只处理 flat

IRBuilder<> B(LI ? &*std::next(...) : ArgCastInsertPt);

PointerType *NewPT = PointerType::get(PT->getContext(), AMDGPUAS::GLOBAL_ADDRESS);
Value *Cast =
    B.CreateAddrSpaceCast(Ptr, NewPT, Twine(Ptr->getName(), ".global"));
Value *CastBack =
    B.CreateAddrSpaceCast(Cast, PT, Twine(Ptr->getName(), ".flat"));
Ptr->replaceUsesWithIf(CastBack,
                       [Cast](Use &U) { return U.getUser() != Cast; });
```

**语义**(`:113-118` 的注释):

> "The promotion is valid because in the HSA offload model the host populates kernarg slots at dispatch time and can only supply global-aperture addresses. Any flat pointer reachable from a kernel argument can therefore be assumed to be in the global aperture."

HSA 模型下,host 端为 kernel 准备 kernarg 时,**只能**给 global 地址。**flat ptr 实际等价于 global ptr**——这是关键的 ABI 假设。

**递归处理**(`enqueueUsers`,:65-92):
对每个参数的 load user,**递归**下钻(GEP、AddrSpaceCast、BitCast),把所有"从该参数派生"的 load 都加入 `Ptrs` 队列,每个都执行 AS 转换。同时给 load 加 `!amdgpu.noclobber` metadata(`promoteLoad`,:136-142),提示后端"这个 load 在 kernel 内不会被写"。

**MemorySSA + AA 检查**(`:78-79`):
```cpp
if (LD->getPointerOperand()->stripInBoundsOffsets() == Ptr &&
    !AMDGPU::isClobberedInFunction(LD, MSSA, AA))
  Ptrs.push_back(LD);
```
确保只处理"在函数内未被写"的 load——若有写,则该 load 可能读到不同数据,不能简单 cast。

### 6.1.4 动态验证

**输入**(`f10_in.ll`):
```llvm
define amdgpu_kernel void @k(ptr %flat_ptr) {
  %v = load i32, ptr %flat_ptr
  ret void
}

define amdgpu_kernel void @k2(ptr addrspace(1) %glob_ptr) {
  %v = load i32, ptr addrspace(1) %glob_ptr
  ret void
}
```

```bash
opt -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 \
    -passes=amdgpu-promote-kernel-arguments -S f10_in.ll
```

输出:
```llvm
define amdgpu_kernel void @k(ptr %flat_ptr) #0 {
  %flat_ptr.global = addrspacecast ptr %flat_ptr to ptr addrspace(1)
  %flat_ptr.flat = addrspacecast ptr addrspace(1) %flat_ptr.global to ptr
  %v = load i32, ptr %flat_ptr.flat, align 4, !amdgpu.noclobber !0
  ret void
}

define amdgpu_kernel void @k2(ptr addrspace(1) %glob_ptr) #0 {
  %v = load i32, ptr addrspace(1) %glob_ptr, align 4, !amdgpu.noclobber !0
  ret void
}
```

观察:
- **`@k` 的 flat ptr**:被包了一层 `addrspacecast ptr → addrspace(1) → ptr`,中间步骤暴露 AS 转换
- **`@k2` 的 global ptr**:不动,但 load 也获得 `!amdgpu.noclobber` metadata(因为 F10 给所有简单 load 都加)
- **最终效果**:后续 InferAddressSpaces 看到 `%flat_ptr.flat` 是 `%flat_ptr.global` 的 cast,推断 `%flat_ptr` 实际是 global AS,把 `ptr` 改为 `ptr addrspace(1)`,中间 cast 消除

### 6.1.5 设计动机

**为什么不直接把参数类型改为 global**:
- IR 函数签名一旦确定,改类型会破坏 caller(尤其是跨 module LTO)
- addrspacecast 是**非破坏性**标记,允许 InferAddressSpaces 在**确认安全后**才改

**为什么要在 CGSCCOptimizerLateEP**:
- 此时 SCC 内所有函数已经过基本内联,指针的 user 图稳定
- 早于 InferAddressSpaces(:1106)——InferAddressSpaces 需要看到 cast 才能推断

**为什么需要 MemorySSA + AA**:
- 若 load 之前**有写**到同一指针,那 load 读到的可能是私有内存(不能 cast 到 global)
- `isClobberedInFunction` 用 MSSA 检查"在函数内是否有写",保证 cast 安全

### 6.1.6 昇腾启示

昇腾的"host 只给 global 地址"模型类似。**直接可迁移**:
- "参数 → addrspacecast 双向 → InferAS 推断"是通用 pattern
- **改进空间**:AMDGPU 用 `replaceUsesWithIf` 保留 cast 链供 InferAS 消费,昇腾可以直接在 Attributor 中做 AS 推断(更彻底)

---

## M10 AMDGPUPreloadKernelArgumentsPass

### 6.2.1 一句话定位
给 kernel 参数(及 hidden 参数)打上 `inreg` attribute,告知后端**这些参数应该 preload 到 SGPR**,从而 kernel 启动时**零 load 开销**。

### 6.2.2 运行位置

**一处**(`AMDGPUTargetMachine.cpp:2453-2455`):

```cpp
if (EnablePreloadKernelArguments)
  addModulePass(AMDGPUPreloadKernelArgumentsPass(TM), PMW);
```

位于 addIRPasses **末尾**(`:2453`),在 LateCodeGenPrepare 之后、LowerKernelArguments 之前。

**Gate**:`EnableKernargPreload`(`:41` 源文件内,默认 true)。**但**:`KernargPreloadCount`(`:36`)默认 **0**,即**默认不 preload 任何显式参数**——只处理 hidden 参数或用户已标记 `inreg` 的。

### 6.2.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUPreloadKernelArguments.cpp`(365 行)。

**两段处理**:
1. **显式参数**(`markKernelArgsAsInreg`,:283-352):遍历参数,若满足条件,加 `inreg` attribute
2. **隐式参数**(`tryAllocHiddenArgPreloadSGPRs`,:186-263):若 kernel 通过 `amdgcn_implicitarg_ptr` 读 hidden 参数,且 SGPR 有富余,把 hidden 参数变成**显式 kernel 参数**(克隆函数,加参数,加 inreg attribute)

**显式参数循环**(`:301-330`):

```cpp
for (Argument &Arg : F.args()) {
  // 跳过不兼容 attribute
  if (Arg.hasByRefAttr() || Arg.hasNestAttr() ||
      Arg.hasAttribute("amdgpu-hidden-argument"))
    break;

  // 已达上限时,只对已标 inreg 的继续(防止重复运行)
  if (NumPreloadsRequested == 0 && !Arg.hasInRegAttr())
    break;

  // 跳过聚合类型(struct/array)
  if (Arg.getType()->isAggregateType())
    break;

  // 计算参数在 kernarg segment 的 offset
  Type *ArgTy = Arg.getType();
  Align ABITypeAlign = DL.getABITypeAlign(ArgTy);
  uint64_t AllocSize = DL.getTypeAllocSize(ArgTy);
  ExplicitArgOffset = alignTo(ExplicitArgOffset, ABITypeAlign) + AllocSize;

  // 检查是否超出可用 SGPR
  if (!PreloadInfo.canPreloadKernArgAtOffset(ExplicitArgOffset))
    break;

  Arg.addAttr(Attribute::InReg);
  NumPreloadedExplicitArgs++;
}
```

**`canPreloadKernArgAtOffset`**(`:181-183`):

```cpp
bool canPreloadKernArgAtOffset(uint64_t ExplicitArgOffset) {
  return ExplicitArgOffset <= NumFreeUserSGPRs * 4;
}
```

简单比较:`NumFreeUserSGPRs * 4`(每个 SGPR 4 字节)。**NumFreeUserSGPRs 由 `GCNUserSGPRUsageInfo` 计算**(`:177-178`),取决于 subtarget(gfx942 通常有 16 个 user SGPR,即可 preload 64 字节 = 16 个 i32)。

**隐式参数克隆**(`cloneFunctionWithPreloadImplicitArgs`,:128-167):

```cpp
FunctionType *NFT =
    FunctionType::get(FT->getReturnType(), FTypes, FT->isVarArg());
Function *NF =
    Function::Create(NFT, F.getLinkage(), F.getAddressSpace(), F.getName());

NF->copyAttributesFrom(&F);
NF->copyMetadata(&F, 0);

F.getParent()->getFunctionList().insert(F.getIterator(), NF);
NF->takeName(&F);
NF->splice(NF->begin(), &F);

// 把原参数 replaceAllUsesWith 到新参数
Function::arg_iterator NFArg = NF->arg_begin();
for (Argument &Arg : F.args()) {
  Arg.replaceAllUsesWith(&*NFArg);
  NFArg->takeName(&Arg);
  ++NFArg;
}

// 给新加的 hidden 参数标 inreg + amdgpu-hidden-argument
AttrBuilder AB(Ctx);
AB.addAttribute(Attribute::InReg);
AB.addAttribute("amdgpu-hidden-argument");
AttributeList AL = NF->getAttributes();
for (unsigned I = 0; I <= LastPreloadIndex; ++I) {
  AL = AL.addParamAttributes(Ctx, NFArg->getArgNo(), AB);
  NFArg++->setName(getHiddenArgName(HiddenArg(I)));
}
```

**为什么克隆而非修改**:函数签名(FunctionType)在 LLVM IR 是 immutable,改参数必须克隆函数。

**9 个 hidden 参数**(`:92-97`):
```cpp
{0, 4, "_hidden_block_count_x"}, {4, 4, "_hidden_block_count_y"},
{8, 4, "_hidden_block_count_z"}, {12, 2, "_hidden_group_size_x"},
{14, 2, "_hidden_group_size_y"}, {16, 2, "_hidden_group_size_z"},
{18, 2, "_hidden_remainder_x"},  {20, 2, "_hidden_remainder_y"},
{22, 2, "_hidden_remainder_z"}
```

正好对应 HSA ABI 的 implicit arg layout(与 §4 F7 的 ImplicitArgOffsets 枚举一致)。

### 6.2.4 动态验证

**实验 1:默认行为**(KernargPreloadCount=0)

```bash
opt -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 \
    -passes=amdgpu-preload-kernel-arguments -S m10_in.ll
```

输出:**无变化**。因为 `KernargPreloadCount=0` 且没有参数已标 inreg,循环立即 break。

**实验 2:--amdgpu-kernarg-preload-count=2**

```bash
opt --amdgpu-kernarg-preload-count=2 \
    -passes=amdgpu-preload-kernel-arguments -S m10_in.ll
```

输出:
```llvm
define amdgpu_kernel void @k(i32 inreg %a, i32 inreg %b, i32 %c) #0 {
```

**前 2 个参数获得 `inreg`,第 3 个没有**——精确按 count 分配。

**实验 3:hidden arg preload(未实测)**

需要构造一个使用 `amdgcn_implicitarg_ptr` 并 load hidden arg 的 kernel。代码路径会**克隆函数**、把 hidden 参数加为显式参数。这个功能依赖 caller(runtime)配合,本章节不做完整演示。

### 6.2.5 设计动机

**为什么 preload 到 SGPR**:
- SGPR 是 wave-uniform 寄存器,**所有线程共享**,加载只需 1 个时钟
- 若参数走 kernarg segment(GDDR),需要一次 `s_load_dword`,**~600 cycles 延迟**
- 对"小而频繁"的参数(如 workgroup_id),preload 是关键优化

**为什么默认 KernargPreloadCount=0**:
- 默认 preload 会**占用** user SGPR,减少 RA 可用空间,可能降低 occupancy
- 让用户根据 kernel 特征显式开启,而非默认开启

**为什么 break 而非 continue**(`:306-316`):
- 参数有顺序(ABI 决定),第 N 个参数不能 preload 不代表第 N+1 个不能
- 但 **inreg 参数必须在签名中连续**(caller 按顺序 push SGPR),所以 break 保证连续性

### 6.2.6 昇腾启示

昇腾 NPU 的 "task info preload" 概念类似。**直接可迁移**:
- "按数量 preload + 用 attribute 标记" 模式通用
- **改进空间**:AMDGPU 的 NumFreeUserSGPRs 是保守估计,可以用 RA 后静态分析精确确定

---

## F6 AMDGPULowerKernelArgumentsPass

### 6.3.1 一句话定位
把 kernel 参数的所有 use **替换**为从 `amdgcn_kernarg_segment_ptr` 派生的 `load`,让参数从"抽象的 IR Argument"变成"显式的内存读取"——这是**离 codegen 最近的一步**,后端只需识别 load 即可生成 `s_load_dword` 指令。

### 6.3.2 运行位置

**一处**(`AMDGPUTargetMachine.cpp:2456-2457`):

```cpp
if (EnableLowerKernelArguments)
  addFunctionPass(AMDGPULowerKernelArgumentsPass(TM), PMW);
```

位于 addIRPasses **末尾**(M10 之后,`:2453`)。

**Gate**:`EnableLowerKernelArguments`(`:508`,默认 true)。

### 6.3.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPULowerKernelArguments.cpp`(423 行)。

**入口**(`:204-223`):

```cpp
CallingConv::ID CC = F.getCallingConv();
if (CC != CallingConv::AMDGPU_KERNEL || F.arg_empty())
  return false;

const GCNSubtarget &ST = TM.getSubtarget<GCNSubtarget>(F);
const uint64_t BaseOffset = ST.getExplicitKernelArgOffset();
const uint64_t TotalKernArgSize = ST.getKernArgSegmentSize(F, MaxAlign);
if (TotalKernArgSize == 0)
  return false;

CallInst *KernArgSegment = Builder.CreateIntrinsicWithoutFolding(
    Intrinsic::amdgcn_kernarg_segment_ptr, {}, nullptr,
    F.getName() + ".kernarg.segment");
KernArgSegment->addRetAttr(Attribute::NonNull);
KernArgSegment->addRetAttr(
    Attribute::getWithDereferenceableBytes(Ctx, TotalKernArgSize));
```

**关键**:
- 只处理 AMDGPU_KERNEL
- `BaseOffset` 和 `TotalKernArgSize` 由 subtarget 计算
- 创建 `amdgcn_kernarg_segment_ptr` intrinsic,作为所有 load 的 base
- 该 intrinsic 返回 `ptr addrspace(4)`(constant AS,因为 kernarg 只读)

**参数循环**(`:236-385`),对每个参数:

```cpp
uint64_t EltOffset = alignTo(ExplicitArgOffset, ABITypeAlign) + BaseOffset;
ExplicitArgOffset = alignTo(ExplicitArgOffset, ABITypeAlign) + AllocSize;

// Skip inreg 参数(preload 的不需要 load)
if (Arg.use_empty() || Arg.hasInRegAttr())
  continue;

// byref 参数:load 已经显式,只需重写指针
if (IsByRef) {
  Value *ArgOffsetPtr = Builder.CreateConstInBoundsGEP1_64(...);
  Value *CastOffsetPtr = Builder.CreateAddrSpaceCast(ArgOffsetPtr, Arg.getType());
  Arg.replaceAllUsesWith(CastOffsetPtr);
  continue;
}

// 普通参数:load + 各种 metadata
LoadInst *Load = Builder.CreateAlignedLoad(AdjustedArgTy, ArgPtr, AdjustedAlign);
Load->setMetadata(LLVMContext::MD_invariant_load, MDNode::get(Ctx, {}));
```

**特殊路径**:

1. **Skip inreg**(`:249`):已 preload 的参数跳过,直接用 Argument(已是 SGPR)
2. **byref 参数**(`:253-263`):只重写指针,不产生新 load(因为 byref 已经是显式 load)
3. **DoShiftOpt**(`:289-306`):**小参数**(i8/i16)合并到 dword 边界,减少 load 数量
4. **V3 hack**(`:308-312`):3 元素向量改为 4 元素 vector load,避免 SelectionDAG 拆分问题

**Metadata 注入**(`:314-365`):
- `!invariant.load`(:316):kernarg 是 const
- `!noundef`(:321):若参数有 noundef attribute
- `!range`(:323-328):若参数有 range attribute
- `!nofpclass`(:330-336):若参数有 nofpclass
- `!nonnull`(:339-340):若参数是 pointer 且 nonnull
- `!dereferenceable`/`!dereferenceable_or_null`(:342-358):若参数有对应 attribute
- `!align`(:360-365):若参数有 align attribute

**Alias Scope**(`addAliasScopeMetadata`,:72-202):

为每个 `noalias` 参数创建独立的 `alias.scope` domain,把所有访问该参数的指令打上 metadata。**这让 AA 知道"这两个 noalias 参数的 load 不会互相 alias"**,后端可以做更激进的指令调度。

### 6.3.4 动态验证

**输入**(`f06_in.ll`):
```llvm
define amdgpu_kernel void @k(i32 %a, ptr addrspace(1) %p, float %f) {
  %v0 = add i32 %a, 1
  %v1 = load float, ptr addrspace(1) %p
  %v2 = fadd float %f, %v1
  ret void
}
```

```bash
opt -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 \
    -passes=amdgpu-lower-kernel-arguments -S f06_in.ll
```

输出:
```llvm
define amdgpu_kernel void @k(i32 %a, ptr addrspace(1) %p, float %f) #0 {
  %k.kernarg.segment = call nonnull align 16 dereferenceable(280)
                       ptr addrspace(4) @llvm.amdgcn.kernarg.segment.ptr()
  %a.kernarg.offset = getelementptr inbounds i8, ptr addrspace(4) %k.kernarg.segment, i64 0
  %a.load = load i32, ptr addrspace(4) %a.kernarg.offset, align 16, !invariant.load !0
  %p.kernarg.offset = getelementptr inbounds i8, ptr addrspace(4) %k.kernarg.segment, i64 8
  %p.load = load ptr addrspace(1), ptr addrspace(4) %p.kernarg.offset, align 8, !invariant.load !0
  %f.kernarg.offset = getelementptr inbounds i8, ptr addrspace(4) %k.kernarg.segment, i64 16
  %f.load = load float, ptr addrspace(4) %f.kernarg.offset, align 16, !invariant.load !0
  %v0 = add i32 %a.load, 1
  %v1 = load float, ptr addrspace(1) %p.load, align 4
  %v2 = fadd float %f.load, %v1
  ret void
}
```

观察:
- **kernarg.segment.ptr** 作为 base,`dereferenceable(280)`(总大小 280 字节)
- **offset 0/8/16** 对应 a/p/f 三个参数(i32=4B 对齐到 8、ptr=8B、float=4B 对齐到 16)
- 所有 load 带 `!invariant.load`(kernarg 是 const)
- 原参数 `%a` 的所有 use 被替换为 `%a.load`,**Argument 本身变成 dead**

### 6.3.5 设计动机

**为什么必须显式化**:
- IR Argument 是抽象的,后端无法直接映射到机器指令
- 显式 load 让后端看到"这是一个 const 内存读",可以匹配 `s_load_dword` 等指令
- `!invariant.load` metadata 让 LICM 把 load 提升到循环外

**为什么用 intrinsic 而非 global variable**:
- `amdgcn_kernarg_segment_ptr` 在 ISel 时映射到 SGPR(具体哪个 SGPR 由 ABI 决定)
- 若用 global variable,需要额外 relocation,不够直接

**为什么 `!invariant.load` 而非 `!noundef`**:
- `invariant.load` 表示"同一地址的多次 load 返回相同值"(kernarg 在 kernel 生命周期内不变)
- `noundef` 表示"load 不是 undef/poison"(虽然也对,但 invariant 更强)

### 6.3.6 昇腾启示

昇腾的 kernel 参数机制(task_info buffer)完全类似。**直接可迁移**:
- "kernarg base + offset load" 是通用 pattern
- `!invariant.load` + `!dereferenceable(N)` 的 metadata 注入对昇腾同样关键
- **改进空间**:AMDGPU 的 DoShiftOpt/V3 hack 是**应对 SelectionDAG 限制**的 workaround,昇腾若用 GlobalISel 可能不需要

---

## §6 章末总结

| Pass | 输入 | 输出 | 主要消费者 |
|---|---|---|---|
| F10 | flat ptr kernel arg | 双向 addrspacecast 标记 | InferAddressSpaces |
| M10 | 普通参数 | +inreg attribute | RA 分配 SGPR |
| F6 | 普通参数 | kernarg.segment + load + metadata | ISel 生成 s_load_dword |

**关键依赖链**:
```
F10 (AS 推断准备) → InferAddressSpaces (AS 改写)
                                        ↓
M10 (preload 标记) → F6 (展开为 load) → 后端 (s_load / s_wait)
```

**已验证假设**:
1. ✅ F10 flat ptr 参数被插入 `addrspacecast ptr → addrspace(1) → ptr`
2. ✅ F10 global ptr 参数不变,但 load 加 `!amdgpu.noclobber`
3. ✅ M10 默认(KernargPreloadCount=0)不改 IR
4. ✅ M10 `--amdgpu-kernarg-preload-count=2` 给前 2 个参数加 inreg
5. ✅ F6 把所有参数转为 kernarg.segment load,带 `!invariant.load`
6. ✅ F6 参数 offset 按 ABI 对齐(0/8/16)

**陷阱记录**:
- **M10 默认 no-op**:必须显式 `--amdgpu-kernarg-preload-count=N` 才 preload
- **F6 必须在 M10 之后**:否则 inreg 参数被 F6 展开为 load,preload 失效
- **F10 必须在 InferAddressSpaces 之前**:否则 AS 推断看不到 cast 链

**与后续章节接口**:
- F6 注入的 `!invariant.load` metadata 在 §9 F3 CodeGenPrepare 被识别用于 LICM
- F10 的 addrspacecast 在 §11 TTI 中影响 InferAddressSpaces 的 cost
- M10 的 inreg 标记被后端 RA 直接消费,跳过 load 生成
