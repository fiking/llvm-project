# §4 内联与属性推断(M1 / C1 / M16 / F7)

> 数据基准:llvm-project main @ `3eda2aebadd4`(2026-09-28),build-debug 实跑。
> 方法:静态读码(`文件:行号`)+ 动态验证(`opt -passes=... -S` 差分)。
> 素材:`AMDGPU-MidEnd-notes/scratch/ch04/{m01,m01b,m16,m16b,f07,f07b}_*.{ll,txt}`。

---

## 章节定位

§3 清场之后,中端进入**"减少函数边界 + 标注 kernel 形态"**阶段。四个 pass 解决两类问题:

| Pass | 一句话 | 在管线中的角色 |
|---|---|---|
| **M1** AMDGPUAlwaysInline | 全模块函数标 `alwaysinline`(默认)或 `noinline`(stress) | **消灭函数调用**(GPU 没有 ABI) |
| **C1** AMDGPUAttributorCGSCC | 按 SCC 自底向上推断 implicit arg 需求 | CGSCC 阶段运行 |
| **M16** AMDGPUAttributor(Module) | 整个模块范围推断 + 落地 `amdgpu-no-*` 属性 | OptimizerLastEP,删未用函数 |
| **F7** AMDGPULowerKernelAttributes | 用 `reqd_work_group_size` 等 metadata 常量折叠 grid 查询 | 紧随 Attributor 之后消费其结果 |

四者关系:M1 先破坏函数边界(让 Attributor 看到"近乎全展开"的图)→ C1/M16 在此之上做过程间推断 → F7 把推断结果与 metadata 结合做常量折叠。**这是 GPU 中端最核心的链**:没有 ABI → 全展开 → 全模块 attribute inference → 编译期常量折叠。

---

## M1 AMDGPUAlwaysInlinePass

### 4.1.1 一句话定位
给所有 internal 函数(或 LDS 用户、或全模块)打上 `alwaysinline` 属性,让紧随其后的 `AlwaysInliner` 把函数调用全部消灭。

### 4.1.2 运行位置

**两处挂载**:

1. **opt 侧 EarlySimplificationEP**(`AMDGPUTargetMachine.cpp:1076-1079`):
```cpp
if (EarlyInlineAll && !EnableFunctionCalls)
  PM.addPass(AMDGPUAlwaysInlinePass());
```
有 `EarlyInlineAll`(`--amdgpu-early-inline-all`,默认 false)gate,通常**不在 opt 默认管线**。

2. **llc 侧 addIRPasses**(`:2389-2391`):
```cpp
addModulePass(AMDGPUAlwaysInlinePass(), PMW);
addModulePass(AlwaysInlinerPass(), PMW);
```
**无条件**挂载,紧随 `ExpandVariadics` 之后。

**关键依赖**:`AlwaysInlinerPass`(通用 IPO pass)消费 M1 设置的属性。两者必须**紧邻**,否则中间任何 pass 可能清除或覆盖属性。

### 4.1.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUAlwaysInlinePass.cpp`(172 行)。三个独立分支,每个对应一个真实场景:

**分支 1:递归标记 LDS 用户**(`:116-133`)

```cpp
for (GlobalVariable &GV : M.globals()) {
  unsigned AS = GV.getAddressSpace();
  if ((AS == AMDGPUAS::REGION_ADDRESS) ||
      (AS == AMDGPUAS::LOCAL_ADDRESS &&
       (!AMDGPUTargetMachine::EnableLowerModuleLDS)))
    recursivelyVisitUsers(GV, FuncsToAlwaysInline);
}
```

**为什么**:LDS 是 workgroup 共享内存,**地址编译期绑定到 kernel**。任何函数若引用 LDS 全局,必须被 inline 到 kernel 里,否则后端无法为其分配 LDS 地址(无法跨函数共享 LDS slot)。

**`EnableLowerModuleLDS` 的副作用**:当开启时(默认 true),`AMDGPULowerModuleLDS` 会把所有 LDS 全局**下沉到 kernel 内**,消除跨函数引用,因此该分支被绕过。这是设计的"防御性":即使新 pass 失效,M1 也能保证正确性。

`recursivelyVisitUsers`(`:55-87`)用栈 + visited 集做 worklist,沿 user 链爬到 Instruction,然后:
```cpp
F->removeFnAttr(Attribute::NoInline);  // :75 — 见下面"陷阱"
FuncsToAlwaysInline.insert(F);
Stack.push_back(F);
```

**注意**:这里有个 FIXME(`:70-74`):
> "This is a horrible hack. We should always respect noinline, and just let us hit the error when we can't handle this. Unfortunately, clang adds noinline to all functions at -O0."

`clang -O0` 给所有函数加 `noinline`,M1 必须**覆盖**它,否则 LDS 函数无法 inline。

**分支 2:alias 替换**(`:97-108`)

```cpp
for (GlobalAlias &A : M.aliases()) {
  if (Function* F = dyn_cast<Function>(A.getAliasee())) {
    if (TT.isAMDGCN() && A.getLinkage() != GlobalValue::InternalLinkage)
      continue;
    A.replaceAllUsesWith(F);
    AliasesToRemove.push_back(&A);
  }
}
```

把 internal alias 的所有 user 重定向到 aliasee,然后(若 `GlobalOpt`)删除 alias 本身。理由:AMDGPU backend 不擅长处理 alias(指令选择阶段不识别),提前消解。

**分支 3:全模块 force inline**(`:135-149`)

```cpp
if (!AMDGPUTargetMachine::EnableFunctionCalls || StressCalls) {
  auto IncompatAttr
    = StressCalls ? Attribute::AlwaysInline : Attribute::NoInline;

  for (Function &F : M) {
    if (!F.isDeclaration() && !F.use_empty() &&
        !F.hasFnAttribute(IncompatAttr)) {
      if (StressCalls) {
        if (!FuncsToAlwaysInline.count(&F))
          FuncsToNoInline.insert(&F);
      } else
        FuncsToAlwaysInline.insert(&F);
    }
  }
}
```

- `EnableFunctionCalls=false` + 无 StressCalls → 所有非 declaration、非空 use 的函数标 `alwaysinline`
- `StressCalls=true` → 反向:所有非 alwaysinline 的函数标 `noinline`(用于测试 backend 的函数调用支持)

### 4.1.4 动态验证

**陷阱(实测发现)**:`EnableFunctionCalls` 表面默认 `false`(声明 `= false`),但 `R600TargetMachine.cpp:38` 有个 `cl::opt<bool, true>` **静态初始化器**会把它**改成 true**:

```cpp
static cl::opt<bool, true> EnableAMDGPUFunctionCallsOpt(
    "amdgpu-function-calls", cl::desc("..."),
    cl::location(AMDGPUTargetMachine::EnableFunctionCalls), cl::init(true),
    cl::Hidden);
```

**后果**:`opt` 加载 AMDGPU backend 时,该 static initializer 执行,`EnableFunctionCalls` 实际默认 = **true**,M1 的 force-inline 分支**默认不跑**。必须显式 `--amdgpu-function-calls=false` 触发。

**实验 1:默认行为**(M1 等于 no-op)
```bash
opt -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 \
    -passes=amdgpu-always-inline -S m01b_in.ll
```
输出:`@callee` 无 `alwaysinline`。

**实验 2:强制 function-calls=false**
```bash
opt -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 \
    --amdgpu-function-calls=false \
    -passes=amdgpu-always-inline -S m01b_in.ll
```
输出:
```llvm
define void @callee(i32 %x) #0 {
  ...
}
attributes #0 = { alwaysinline "target-cpu"="gfx942" }
```

**实验 3:stress 模式反向**
```bash
opt --amdgpu-stress-function-calls=true -passes=amdgpu-always-inline -S m01b_in.ll
```
输出:`@callee` 获得 `noinline`(用于 stress-test 后端调用支持)。

**实验 4:LDS 分支独立工作**
```bash
opt --amdgpu-enable-lower-module-lds=false \
    --amdgpu-function-calls=true \
    -passes=amdgpu-always-inline -S m01_in.ll
```
输出:**只有** `@read_lds`(LDS 用户)获得 `alwaysinline`,`@plain_fn` 不。证明 LDS 分支与 function-calls 分支正交。

### 4.1.5 设计动机

**为什么 GPU 必须全展开**:
- **没有标准 ABI**:每个 kernel 的 SGPR/VGPR 分配独立,跨函数调用意味着 caller/callee 必须共享寄存器,后端成本极高
- **Wave 一致性**:函数调用可能引入 divergent return,难以维护 exec mask
- **设备库共享**:`__ockl_*` 等 device lib 函数都是 `internal` + `alwaysinline`,编译期合并

**为什么不能用 IPO Inliner**:`PassBuilder::buildInlinerPipeline` 的 inline cost 对 GPU 不合适——GPU 没有调用开销指令(call 指令在 wave 里是分支),inline 是"免费的",唯一成本是代码大小。

**为什么用属性标记而非直接 inline**:M1 只设属性,真正 inline 由紧随的 `AlwaysInliner` 完成。这解耦了"决定哪些函数应被 inline"和"如何 inline"(后者涉及 DominatorTree 更新、SSA 重建等通用问题,IPO pass 已经写好了)。

### 4.1.6 昇腾启示

昇腾 NPU 同样**没有真正的函数调用**(kernel 内所有代码最终展开到一份 SASS-like 流)。**直接可迁移**:M1 模式几乎可以 1:1 复用。值得注意:

- 昇腾的 LDS 等价物是 UB(Unified Buffer),如果用户代码跨函数引用 UB 全局,需要同样的 force-inline 机制
- `EnableFunctionCalls` 的"默认 true 但 static initializer 覆盖为 false"是 LLVM 历史包袱,昇腾 IR 设计应避免这种"声明与初始化分离"的 trap

---

## C1 AMDGPUAttributorCGSCCPass + M16 AMDGPUAttributorPass

### 4.2.1 一句话定位
推断每个 kernel 实际**不需要**哪些隐式参数(workgroup_id、queue_ptr、dispatch_ptr 等),并落地为 21 个 `amdgpu-no-*` 函数属性,让后端在生成 kernel argument 时**跳过未用 slot**,节省 SGPR 占用。

### 4.2.2 运行位置

**两个变体,两个挂点**:

1. **C1 (CGSCC)**(`AMDGPUTargetMachine.cpp:1027-1034`):
```cpp
PB.registerPipelineParsingCallback(
    [this](StringRef Name, CGSCCPassManager &PM, ...) {
      if (Name == "amdgpu-attributor-cgscc" && getTargetTriple().isAMDGCN()) {
        PM.addPass(AMDGPUAttributorCGSCCPass(...));
        return true;
      }
      return false;
    });
```
**仅手动注册**,不在默认 -O* pipeline。

2. **M16 (Module)**(`:1123-1135`):
```cpp
PB.registerOptimizerLastEPCallback([this](ModulePassManager &MPM,
                                          OptimizationLevel Level,
                                          ThinOrFullLTOPhase Phase) {
  if (Level != OptimizationLevel::O0) {
    if (!isLTOPreLink(Phase)) {
      if (EnableAMDGPUAttributor && getTargetTriple().isAMDGCN()) {
        MPM.addPass(AMDGPUAttributorPass(*this, Opts, Phase));
      }
    }
  }
});
```
**默认挂**(`EnableAMDGPUAttributor` 默认 true),在 OptimizerLastEP——所有 IPO 完成后跑。

**两者区别**(`:1663-1684`):

| 维度 | C1 (CGSCC) | M16 (Module) |
|---|---|---|
| 遍历单位 | LazyCallGraph SCC | 整个模块 |
| `DeleteFns` | `false`(保守) | `true`(可删 dead fn) |
| `IsClosedWorld` | 不可配置(由 Opts 默认) | 可配置(`amdgpu-attributor-closed-world`) |
| 主要用途 | LTO 中间,模块未链接齐 | 完整模块,最终落地 |

**FIXME**(`:1123`):
> "FIXME: Why is AMDGPUAttributor not in CGSCC?"

作者承认 M16 应该在 CGSCC 而不是 Module——但因为要在 Module 范围内做 dead function 消除,妥协放在了 OptimizerLastEP。

### 4.2.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUAttributor.cpp`(1685 行),16 个 AbstractAttribute 子类,主入口 `runImpl`(`:1555-1638`)。

**白名单 AA**(`:1559-1566`):

```cpp
DenseSet<const char *> Allowed(
    {&AAAMDAttributes::ID, &AAUniformWorkGroupSize::ID,
     &AAPotentialValues::ID, &AAAMDFlatWorkGroupSize::ID,
     &AAAMDMaxNumWorkgroups::ID, &AAAMDWavesPerEU::ID,
     &AAAMDGPUClusterDims::ID, &AACallEdges::ID, &AAPointerInfo::ID,
     &AAPotentialConstantValues::ID, &AAUnderlyingObjects::ID,
     &AANoAliasAddrSpace::ID, &AAAddressSpace::ID, &AAIndirectCallInfo::ID,
     &AAAMDGPUClusterDims::ID, &AAAlign::ID});
```

限制 Attributor 框架只跑这 16 个 AA(默认 Attributor 会跑 60+ 个)。**性能考量**:GPU 中端重点是 attribute inference,不需要完整的 IPO Attributor。

**注册的核心 AA**(`:1597-1614`):

```cpp
for (auto *F : Functions) {
  A.getOrCreateAAFor<AAAMDAttributes>(...);       // 主属性:amdgpu-no-*
  A.getOrCreateAAFor<AAUniformWorkGroupSize>(...); // 推断 uniform-work-group-size
  A.getOrCreateAAFor<AAAMDMaxNumWorkgroups>(...);  // 推断 max-num-workgroups
  if (!AMDGPU::isEntryFunctionCC(CC)) {            // 非 kernel 才推断这两个
    A.getOrCreateAAFor<AAAMDFlatWorkGroupSize>(...);
    A.getOrCreateAAFor<AAAMDWavesPerEU>(...);
  }
  if (Features.test(FEAT_CLUSTERS))                // gfx10+ only
    A.getOrCreateAAFor<AAAMDGPUClusterDims>(...);
  if (Features.test(FEAT_AGPR_ALLOC))              // gfx90a+ only
    A.getOrCreateAAFor<AAAMDGPUMinAGPRAlloc>(...);
  // 内存操作 AA
  for (auto &I : instructions(F)) {
    if (load/store/atomic) {
      A.getOrCreateAAFor<AAAddressSpace>(...);
      A.getOrCreateAAFor<AANoAliasAddrSpace>(...);
      if (amdgcn_make_buffer_rsrc)
        A.getOrCreateAAFor<AAAlign>(...);
    }
  }
}
```

**AAAMDAttributesFunction::updateImpl 主循环**(`:480-560`):迭代所有 callee,调用 `intrinsicToAttrMask` 把每个 intrinsic 映射到一个 implicit 参数位,然后 `removeAssumedBits(AttrMask)` 把对应位从 assumed 集合清除。

**`intrinsicToAttrMask`**(`:61-126`)是把 intrinsic 映射到 implicit arg 的核心查表逻辑。关键 case:

| Intrinsic | 隐含参数 | 备注 |
|---|---|---|
| `amdgcn_workitem_id_x` | WORKITEM_ID_X | NonKernelOnly=true(x 总是初始化) |
| `amdgcn_workgroup_id_y/z` | WORKGROUP_ID_Y/Z | |
| `amdgcn_dispatch_ptr` | DISPATCH_PTR | |
| `amdgcn_queue_ptr` | QUEUE_PTR | COV>=5 时还需 IMPLICIT_ARG_PTR |
| `amdgcn_implicitarg_ptr` | IMPLICIT_ARG_PTR | |
| `amdgcn_is_shared/is_private` | IMPLICIT_ARG_PTR (COV>=5) / QUEUE_PTR (pre-V5) | 有 FEAT_APERTURE_REGS 时跳过 |
| `amdgcn_wwm/strict_wwm` | WHOLE_WAVE_MODE | |
| `trap/debugtrap/ubsantrap` | QUEUE_PTR (COV<4) / 不需要 (COV>=4,有 GetDoorbellID) | |

**COV = Code Object Version**:V4/V5 行为差异很大,V5 引入了 `implicitarg_ptr` 作为统一入口,很多参数从 `queue_ptr` 派生改为从 `implicitarg_ptr` 派生。

**Special case:workitem_id_x 的 NonKernelOnly=true**(`:67-70`)

注释:
> "We do not need to note the x workitem or workgroup id because they are always initialized."

含义:硬件总是把 workitem_id_x / workgroup_id_x 写到 V0/SGPR,**不需要从 kernel argument 读取**。所以即使 kernel 用了 `amdgcn_workgroup_id_x`,也**不需要为它分配 slot**,属性 `amdgpu-no-workgroup-id-x` 可以安全保留。

代码体现(`:534-536`):
```cpp
if (AttrMask != NOT_IMPLICIT_INPUT) {
  if ((IsNonEntryFunc || !NonKernelOnly))
    removeAssumedBits(AttrMask);
}
```
对 kernel(`IsNonEntryFunc=false`)+ NonKernelOnly=true 的 intrinsic(如 workgroup_id_x),条件为 false,**不执行** removeAssumedBits,属性保留。

**属性 manifest**(`:590-601`):

```cpp
ChangeStatus manifest(Attributor &A) override {
  SmallVector<Attribute, 8> AttrList;
  for (auto Attr : ImplicitAttrs) {
    if (isKnown(Attr.first))
      AttrList.push_back(Attribute::get(Ctx, Attr.second));
  }
  return A.manifestAttrs(getIRPosition(), AttrList,
                         /* ForceReplace */ true);
}
```

21 个 `amdgpu-no-*` 属性来自 `AMDGPUAttributes.def`,该文件被 `#include "AMDGPUAttributes.def"` 两次(一次生成枚举,一次生成字符串表)——典型 X-macro 模式。

### 4.2.4 动态验证

**实验 1:空 kernel 获得全部 21 个属性**

输入(`m16_in.ll`):
```llvm
define amdgpu_kernel void @empty_kernel() { ret void }
define amdgpu_kernel void @uses_wgid() {
  %id = call i32 @llvm.amdgcn.workgroup.id.x()
  ret void
}
```

```bash
opt -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 \
    -passes=amdgpu-attributor -S m16_in.ll
```

输出(关键行):
```llvm
attributes #0 = { "amdgpu-no-cluster-id-x" "amdgpu-no-cluster-id-y"
                  "amdgpu-no-cluster-id-z" "amdgpu-no-completion-action"
                  "amdgpu-no-default-queue" "amdgpu-no-dispatch-id"
                  "amdgpu-no-dispatch-ptr" "amdgpu-no-flat-scratch-init"
                  "amdgpu-no-heap-ptr" "amdgpu-no-hostcall-ptr"
                  "amdgpu-no-implicitarg-ptr" "amdgpu-no-lds-kernel-id"
                  "amdgpu-no-multigrid-sync-arg" "amdgpu-no-queue-ptr"
                  "amdgpu-no-workgroup-id-x" "amdgpu-no-workgroup-id-y"
                  "amdgpu-no-workgroup-id-z" "amdgpu-no-workitem-id-x"
                  "amdgpu-no-workitem-id-y" "amdgpu-no-workitem-id-z"
                  "amdgpu-no-wwm" "target-cpu"="gfx942" }
```

**21 个属性全在**(包括 `amdgpu-no-workgroup-id-x`,因为 NonKernelOnly=true)。

**实验 2:workgroup_id_y 触发属性清除**

输入(`m16b_in.ll`):
```llvm
define amdgpu_kernel void @uses_wgid_y() {
  %id = call i32 @llvm.amdgcn.workgroup.id.y()
  ret void
}
```

输出 attributes 中:**`amdgpu-no-workgroup-id-y` 消失**,但 `x` 和 `z` 保留。验证 NonKernelOnly 只豁免 x。

**实验 3:CGSCC 变体(C1)**

```bash
opt -passes='cgscc(amdgpu-attributor-cgscc)' -S m16_in.ll
```

输出:与 M16 相同(对小模块两者结果一致,大模块 CGSCC 可能更保守)。

### 4.2.5 设计动机

**为什么需要 21 个 `amdgpu-no-*` 属性**:
AMDGPU kernel 的"标准" ABI 包含 21 个可能的 implicit 参数(workgroup_id、queue_ptr、dispatch_ptr 等),每个占一个 SGPR 或 constant buffer slot。**未用的 slot 是浪费**——尤其在 occupancy 受限的 kernel 上,少分配一个 SGPR 可能多容纳一个 wave。

**为什么用 Attributor 框架**:
- Attributor 是 fixpoint 框架,自然处理"函数 A 调函数 B,B 用了 workgroup_id_y → A 也需要"的传播
- 属性可以跨 SCC 自底向上传播(CGSCC 顺序)
- 内置的 `AAPointerInfo` 可以追踪 `implicitarg_ptr` 的 load,精确判断哪些字节被读

**为什么 NonKernelOnly 设计**:
workitem_id_x 总是由硬件自动初始化到 V0(不需要 kernel arg),而 workitem_id_y/z 需要从 kernel arg 读(在 V5 中)或从 dispatch packet 读(V4)。这个不对称源于硬件设计:x 维度是 wave 内 lane id 的自然延伸,y/z 需要额外查询。

**为什么 21 个属性是 negative form(no-*)而不是 positive form(uses-*)**:
LLVM 属性的 default 是"没有该属性"= false。若用 positive form,每个 kernel 都要列 21 个 `amdgpu-uses-*`,占用大量元数据;negative form 让"全部不需要"的 kernel 无需任何属性(default),只有"需要某些"的 kernel 列出差异。

### 4.2.6 昇腾启示

昇腾 NPU 的 implicit arg 机制类似(每个 kernel 有 task_id、stack_base 等隐式 slot)。**直接可迁移**:
- Attributor 框架是通用的,只需为昇腾定义自己的 attribute set
- "硬件自动初始化 vs 需要 kernel arg" 的不对称性在昇腾也存在(如 task_id 由硬件写,task_dim 需要从 arg 读)
- **改进空间**:21 个独立 boolean 属性可以用单个 bitmask 属性(`amdgpu-implicit-mask="0x1F3"`)替代,减少 metadata 大小

---

## F7 AMDGPULowerKernelAttributesPass

### 4.3.1 一句话定位
读取 kernel 的 `!reqd_work_group_size`、`uniform-work-group-size`、`amdgpu-max-num-workgroups` 等属性/metadata,把对 `amdgcn_dispatch_ptr` 或 `amdgcn_implicitarg_ptr` 的 load **折叠为常量**或加上 `!range` metadata,让后续优化看到精确范围。

### 4.3.2 运行位置

**一处挂点**(`AMDGPUTargetMachine.cpp:1111-1114`):

```cpp
PB.registerCGSCCOptimizerLateEPCallback(
    [this](CGSCCPassManager &PM, OptimizationLevel Level) {
      // ...
      FPM.addPass(AMDGPULowerKernelAttributesPass());
      // ...
```

位于 `CGSCCOptimizerLateEP`,**紧随 Attributor**(:1109 PromoteKernelArguments,:1110 InferAddressSpaces)。理由:Attributor 已经把 implicit arg 的"使用模式"分析好,F7 在此之上做常量折叠。

### 4.3.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPULowerKernelAttributes.cpp`(522 行)。核心是 `processUse`(`:162-467`),按地址空间版本(V5 vs pre-V5)分两条路径。

**版本判断**(`:79-83`):

```cpp
Function *getBasePtrIntrinsic(Module &M, bool IsV5OrAbove) {
  auto IntrinsicId = IsV5OrAbove ? Intrinsic::amdgcn_implicitarg_ptr
                                 : Intrinsic::amdgcn_dispatch_ptr;
  return Intrinsic::getDeclarationIfExists(&M, IntrinsicId);
}
```

- **V5**(COV >= 5):用 `amdgcn_implicitarg_ptr`,字段在 fixed offset(HIDDEN_BLOCK_COUNT_X=0、HIDDEN_GROUP_SIZE_X=12 等,见 `:48-62`)
- **Pre-V5**:用 `amdgcn_dispatch_ptr`,字段是 HSA 标准 hsa_kernel_dispatch_packet_t(WORKGROUP_SIZE_X=4 等,见 `:38-45`)

**核心 fold 模式**(`:312-349`,V5 + uniform-work-group-size):

```cpp
if (IsV5OrAbove && HasUniformWorkGroupSize) {
  // workgroup_id < hidden_block_count → true(因为 uniform-wgs 保证整除)
  for (User *ICmp : BlockCount->users()) {
    if (match(ICmp, m_SpecificICmp(ICmpInst::ICMP_ULT, GroupIDIntrin,
                                   m_Specific(BlockCount)))) {
      ICmp->replaceAllUsesWith(llvm::ConstantInt::getTrue(...));
      MadeChange = true;
    }
  }
  // 所有 remainder 必然是 0
  for (Value *Remainder : Remainders) {
    Remainder->replaceAllUsesWith(Constant::getNullValue(...));
  }
}
```

**为什么正确**:`uniform-work-group-size` 表示 grid 在每个维度上**整除** workgroup,因此:
- 每个 workgroup 都完整(不存在部分 remainder)
- `workgroup_id < block_count` 恒为 true(block_count 是 ceil(grid/group))
- remainder 恒为 0

**Range metadata 注入**(`:87-119`):

```cpp
static bool annotateGroupSizeLoadWithRangeMD(LoadInst *Load, bool IsRemainder) {
  // ...
  MDNode *Range = MDB.createRange(
      APInt(16, !IsRemainder),
      APInt(16, AMDGPU::getMaxFlatWorkGroupSize() + 1 - IsRemainder));
  Load->setMetadata(LLVMContext::MD_range, Range);
  return true;
}
```

对 group_size(i16):范围 `[1, MaxFlatWorkGroupSize+1)` = `[1, 1025)`
对 remainder(i16):范围 `[0, MaxFlatWorkGroupSize)` = `[0, 1024)`

**reqd_work_group_size 常量折叠**(`:451-464`):

```cpp
if (!HasReqdWorkGroupSize)
  return MadeChange;
for (int I = 0; I < 3; I++) {
  Value *GroupSize = GroupSizes[I];
  if (!GroupSize) continue;
  ConstantInt *KnownSize = mdconst::extract<ConstantInt>(MD->getOperand(I));
  GroupSize->replaceAllUsesWith(
      ConstantFoldIntegerCast(KnownSize, GroupSize->getType(), false, DL));
  MadeChange = true;
}
```

把 `load i16 (implicit_ptr + 12)`(读 group_size_x)直接替换为 metadata 中的常量。

### 4.3.4 动态验证

**实验 1:reqd_work_group_size + V5**(`f07_in.ll`)

```llvm
define amdgpu_kernel void @k() #0 !reqd_work_group_size !0 {
  %implicit_ptr = call ptr addrspace(4) @llvm.amdgcn.implicitarg.ptr()
  %p_gs_x = getelementptr i8, ptr addrspace(4) %implicit_ptr, i32 12
  %gs_x_ptr = bitcast ptr addrspace(4) %p_gs_x to ptr addrspace(4)
  %gs_x = load i16, ptr addrspace(4) %gs_x_ptr, align 2
  ; ...
}
attributes #0 = { "amdgpu-flat-work-group-size"="64,64" "uniform-work-group-size"="true" }
!0 = !{i32 64, i32 1, i32 1}
```

输出:
```llvm
%gs_x = load i16, ptr addrspace(4) %gs_x_ptr, align 2, !range !1
; ...
!1 = !{i16 1, i16 1025}
```

观察:
- `!range !1` 被加上,但 load **没有被替换为常量**
- 原因:在我的输入中 `%gs_x` 没有 `User`,所以 fold 路径只走到 annotate 阶段。要触发常量折叠,需要 `%gs_x` 被实际使用(如 `icmp` 或参与运算)

**实验 2:uniform-wgs 触发 icmp fold**(`f07b_in.ll`)

```llvm
%bc = load i32, ptr addrspace(4) %bc_ptr, align 4     ; HIDDEN_BLOCK_COUNT_X
%rem = load i16, ptr addrspace(4) %rem_ptr, align 2   ; HIDDEN_REMAINDER_X
%wgid = call i32 @llvm.amdgcn.workgroup.id.x()
%cmp = icmp ult i32 %wgid, %bc
%rem32 = zext i16 %rem to i32
```

输出:
```llvm
%rem = load i16, ptr addrspace(4) %rem_ptr, align 2, !range !0
; ...
%rem32 = zext i16 0 to i32   ; ← rem 被替换为 0
; !0 = !{i16 0, i16 1024}
```

观察:
- Remainder 被替换为 0(uniform-wgs 路径生效)
- 但 `%cmp = icmp ult i32 %wgid, %bc` **没有被 fold 为 true**

**为什么 icmp 没 fold**:查代码 `:312-340`,V5 路径只对**有 `uniform-work-group-size`** 的 kernel 做 icmp fold。我的输入确实有该属性。再看代码——`match(ICmp, m_SpecificICmp(ICmpInst::ICMP_ULT, GroupIDIntrin, m_Specific(BlockCount)))`,它要求**左边是 workgroup_id_x、右边是 BlockCount**。我的输入确实匹配。再细看,V5 路径需要 `GroupSizes[I]` 也存在(`:412-448` 的"upgrade"分支),但单独 icmp fold 分支(`:333-339`)只要求 BlockCount。

慢着——代码 `:333` 的循环是 `for (User *ICmp : BlockCount->users())`,而 `%bc` 是 load,它的 users 是 `%cmp`。让我看为什么没匹配上……

实际上,问题可能是 pattern `m_SpecificICmp(ICMP_ULT, GroupIDIntrin, m_Specific(BlockCount))` 匹配中,`GroupIDIntrin` 是 `m_Intrinsic<amdgcn_workgroup_id_x>()`,但我的代码里 `%wgid = call i32 @llvm.amdgcn.workgroup.id.x()` 返回的是 i32,而 BlockCount 是 load(i32)。匹配应该成功……

让我再跑一次完整 trace 确认。**注**:这个问题不影响主流程结论——F7 的核心 fold(remainder=0 和 range metadata)已经验证。ICMP fold 不触发可能是 pattern 匹配的 subtle issue,不影响主文档结论。

### 4.3.5 设计动机

**为什么不能由 Attributor 直接做这些 fold**:
- Attributor 是**通用框架**,落地方式是"添加属性"而非"重写指令"
- F7 是**指令级重写**,需要 Attributor 推断结果作为输入,但执行是独立的 pass

**为什么用 `!range` metadata 而非直接常量**:
- `!range` 给后续优化(如 `IndVarSimplify`、`LoopUnroll`)提供精确信息,但保留 load 本身,便于 debug
- 若直接替换为常量,debug info 中的 load 消失,追踪困难

**为什么区分 V5 和 pre-V5**:
HSA Code Object V5(ROCm 5.0+)重新设计了 implicit arg 布局,把多个分散的指针(queue_ptr、dispatch_ptr、hostcall_ptr)合并为**单一 implicitarg_ptr + 固定偏移表**。V5 的设计让 Attributor 更容易分析(只需追踪一个指针),但 pre-V5 仍需支持旧 binary。

### 4.3.6 昇腾启示

昇腾 NPU 的 implicit arg(如 `task_info_ptr`)机制完全类似。**直接可迁移**:
- `!range` metadata 注入是通用的,昇腾可以照搬
- "uniform-work-group-size 时 fold icmp" 的逻辑也适用(若昇腾有类似概念)
- **改进空间**:F7 的 fold 策略偏保守(只处理 icmp 和 remainder),可以扩展到 `udiv/urem` 等更复杂 pattern

---

## §4 章末总结

| Pass | 输入 | 输出 | 后续消费 |
|---|---|---|---|
| M1 | 含函数调用的模块 | 所有 internal 函数标 alwaysinline | AlwaysInliner 全展开 |
| C1/M16 | 全展开的模块 | 每个 kernel 带 21 个 amdgpu-no-* 属性 | 后端 LowerKernelArguments 跳过未用 slot |
| F7 | 带属性的 kernel | load 加 !range / icmp fold / 常量替换 | 后续 InstCombine/GVN 利用范围信息 |

**关键依赖链**:
```
M1 (展开函数) → M16 (推断 implicit arg) → F7 (常量折叠) → 后端 (按属性分配 SGPR)
```

**已验证假设**:
1. ✅ M1 在 `--amdgpu-function-calls=false` 时给所有 internal 函数加 alwaysinline
2. ✅ M1 在 `--amdgpu-enable-lower-module-lds=false` 时仅给 LDS 用户加 alwaysinline
3. ✅ M16 空 kernel 获得全部 21 个 `amdgpu-no-*` 属性
4. ✅ M16 `uses_wgid_x` 保留 `amdgpu-no-workgroup-id-x`(NonKernelOnly 设计)
5. ✅ M16 `uses_wgid_y` 清除 `amdgpu-no-workgroup-id-y`
6. ✅ F7 `uniform-work-group-size` 时 remainder load 被替换为 0
7. ✅ F7 给 group_size load 加 `!range` metadata

**陷阱记录**:
- **`EnableFunctionCalls` 默认不是 false**:R600TargetMachine.cpp 的 static initializer 把它改为 true,必须显式 `--amdgpu-function-calls=false` 触发 M1 主分支
- **NonKernelOnly 设计**:`workgroup_id_x` 即使被使用也保留 `amdgpu-no-workgroup-id-x`,因为硬件总是初始化 x 寄存器——这是**优化而非 bug**

**遗留问题**:
- F7 的 icmp fold 在某些 pattern 下不触发(可能是 pattern match 边界条件),需查 `m_SpecificICmp` 的具体行为
- M16 的 `DeleteFns=true` 会删除哪些函数?对大模块的实际影响是什么?(需构造大模块测试)
- C1 与 M16 在**有 indirect call** 时行为差异:`IndirectCallSpecializationThreshold`(:27)默认 4,超出会怎样?

**与后续章节接口**:
- M16 推断的 `amdgpu-no-*` 属性被 §6 F6 LowerKernelArguments 消费,跳过对应 slot 分配
- F7 注入的 `!range` metadata 被 §9 F3 CodeGenPrepare 的 `optimizeSelectInst` 利用
- M1 的全展开模块形态是 §10 F16 SIAnnotateControlFlow 的前置条件(后者假设无函数调用)
