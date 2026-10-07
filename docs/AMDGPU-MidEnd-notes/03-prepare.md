# §3 基础准备层:清场与静态化(M12 / M11 / M4 / M5)

> 数据基准:llvm-project main @ `3eda2aebadd4`(2026-09-28),build-debug 实跑。
> 方法:静态读码(`文件:行号`)+ 动态验证(`opt -passes=... -S` 差分)。
> 素材:`AMDGPU-MidEnd-notes/scratch/ch03/{m04,m05,m11,m12}_*.{ll,log}`。

---

## 章节定位

中端 IR 优化在"能开始优化之前",必须先把模块清成后端**能消化的形状**:

| Pass | 一句话 | 在 addIRPasses 中的顺序 |
|---|---|---|
| **M12** AMDGPURemoveIncompatibleFunctions | 删除当前 gfx 不支持的函数 | 第 1 个(AMDGPUTargetMachine.cpp:2367) |
| **M11** AMDGPUPrintfRuntimeBinding | printf → `__printf_alloc` + metadata | 第 2 个(:2375) |
| **M4** AMDGPUCtorDtorLowering | `llvm.global_ctors` → `amdgcn.device.init` kernel | 第 3 个(:2378) |
| **M5** AMDGPUExportKernelRuntimeHandles | enqueue runtime handle → external linkage | 第 5 个,**在 AlwaysInline 之后**(:2393) |

四个 pass 共用同一组设计动机:**把"运行时才知道的事"提前翻译成"链接器/驱动能看到的符号或 metadata"**。本章逐一证明。

---

## M12 AMDGPURemoveIncompatibleFunctionsPass

### 3.1.1 一句话定位
删除使用了**当前 GPU 不支持 feature** 的函数(把调用点替换为 `null`),让一份 IR 模块能安全地送进多种 gfx 后端,只保留各自能跑的函数。

### 3.1.2 运行位置

新 PM 挂点(`AMDGPUTargetMachine.cpp:2367-2371`):

```cpp
void AMDGPUCodeGenPassBuilder::addIRPasses(PassManagerWrapper &PMW) {
  if (RemoveIncompatibleFunctions && TM.getTargetTriple().isAMDGCN()) {
    flushFPMsToMPM(PMW);
    addModulePass(AMDGPURemoveIncompatibleFunctionsPass(TM), PMW);
  }
```

**关键约束**:必须是整个 `addIRPasses` 的**第一个 pass**(在 printf/ctor-dtor/AlwaysInline 之前),因为后续 pass 都假定模块里所有函数都是合法的。

**Gate**:`static cl::opt<bool> RemoveIncompatibleFunctions("amdgpu-enable-remove-incompatible-functions", ..., cl::init(true))`(:470-474),默认开启。注意此 flag 只控制**是否挂载** pass;若用 `opt -passes=amdgpu-remove-incompatible-functions` 手动调用,gate 不生效(实测验证,见 §3.1.4 陷阱)。

### 3.1.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPURemoveIncompatibleFunctions.cpp`(221 行)。

**主算法**(`run`,:41-55):

```cpp
for (Function &F : M) {
  if (checkFunction(F))
    FnsToDelete.push_back(&F);
}
for (Function *F : FnsToDelete) {
  F->replaceAllUsesWith(ConstantPointerNull::get(F->getType()));
  F->eraseFromParent();
}
```

两阶段:先收集后删除,避免迭代器失效。删除方式不是 `removeFromParent` 而是 `replaceAllUsesWith(null) + eraseFromParent` —— 调用点会变成 `call void null()`,**保留 CFG 完整性**,后续由攻击者很容易识别并消除。

**checkFunction**(:156-211)核心逻辑:

1. 跳过 declaration(:157-158)
2. 跳过 `generic` / `generic-hsa` GPU(:166-167)—— 测试用 triple,不挂检查
3. 通过 `getGPUInfo` 从 `GCNProcessors.td` 取该 GPU 的 `Implies` feature bitset
4. **递归展开**(`expandImpliedFeatures`,:121-129):GFX90A imply GFX9,GFX9 又 imply 一批子 feature
5. 对照 `FeaturesToCheck`(:100-119)的 19 个"嫌疑 feature"列表逐一检查
6. 特殊处理 `FeatureWavefrontSize32/64`(:199-209):gfx10/11/12 双模式支持,而 gfx9- 只能 wave64,要单独 gate

**FeaturesToCheck 19 项**完整清单(:100-119):

```
FeatureGFX11Insts, FeatureGFX10Insts, FeatureGFX9Insts, FeatureGFX8Insts,
FeatureDPP, FeatureDPPWavefrontShifts, FeatureDPPBroadcasts,
Feature16BitInsts,
FeatureDot1Insts ~ FeatureDot8Insts,
FeatureExtendedImageInsts,
FeatureSMemRealTime, FeatureSMemTimeInst,
FeatureGWS
```

为何是这 19 个而不是全部 100+ 个 feature?——它们对应**指令集层面能让后端生不逢时的硬约束**(没有这条指令、decoder 不认识、甚至汇编器报错)。其它 feature(如 `FeatureFastFMAF`)是性能选项,即使误用也只慢不错。

**OptimizationRemark 输出**(`reportFunctionRemoved`,:131-144):

```cpp
return OptimizationRemark(DEBUG_TYPE, "AMDGPUIncompatibleFnRemoved", &F)
       << "removing function '" << F.getName() << "': +"
       << getFeatureName(ST, Feature)
       << " is not supported on the current target";
```

注意:这里没有传 debug loc,只在 remark 文本里嵌函数名。注释解释(:137-138):若没 debug info,`&F` 会打印 `<unknown>:0:0`,把函数名硬塞进文本是**唯一可靠定位方式**。

### 3.1.4 动态验证

**输入**(`scratch/ch03/m12_in.ll`):

```llvm
target triple = "amdgcn-amd-amdhsa"

define amdgpu_kernel void @caller() #0 {
  call void @uses_gfx9_feature()
  ret void
}

define void @uses_gfx9_feature() #1 {
  ret void
}

attributes #0 = { nounwind }
attributes #1 = { nounwind "target-features"="+gfx9-insts" }
```

**gfx803 目标**(不支持 gfx9-insts):

```bash
opt -mtriple=amdgcn-amd-amdhsa -mcpu=gfx803 \
    -passes=amdgpu-remove-incompatible-functions \
    -pass-remarks=amdgpu-remove-incompatible-functions \
    -S m12_in.ll
```

输出 remark:
```
remark: <unknown>:0:0: removing function 'uses_gfx9_feature':
        +gfx9-insts is not supported on the current target
```

输出 IR 关键片段:

```llvm
define amdgpu_kernel void @caller() #0 {
  call void null()      ; ← @uses_gfx9_feature 被替换
  ret void
}
; @uses_gfx9_feature 整个函数消失
```

**gfx942 对照**(支持 gfx9-insts):同输入,函数保留,无 remark。

**陷阱**(实测):`--amdgpu-enable-remove-incompatible-functions=false` **不影响** `opt -passes=...` 手动调用——因为它只是 `addIRPasses` 中的挂载条件,不进入 pass 内部。要禁用必须**不要挂**这个 pass。

### 3.1.5 设计动机

**为什么必须做**:`-fgpu-rdc`(Relocatable Device Code)模式下,同一模块可以包含面向多个 gfx 的函数(用 `__attribute__((target("gfx9-insts")))` 标记)。但后端 ISel 一次只跑一个 gfx —— 如果不先剔除不兼容的函数,后端会**在 ISel 阶段崩溃**(遇到不认识的 intrinsic)或**生成错误代码**(指令编码不存在)。

**为什么必须是第一个**:后续 printf/ctor-dtor/AlwaysInline 都可能读所有函数(ctor-dtor 会看 `@llvm.global_ctors` 里引用的函数;AlwaysInline 会展开调用图)。让 M12 先跑,等于先**清场**。

**为什么用 `replaceAllUsesWith(null)` 而不是直接删 call**:直接删 call 会让 CFG 不平衡(void 返回的 call 有 use;非 void 调用会产生 dead phi)。`call void null()` 让 IR 仍然合法,后续 `UnreachableBlockElim` / `GlobalDCE` 会自然清掉。

### 3.1.6 昇腾启示

昇腾 Ascend NPU 编译栈也面对同样问题:`__aicore__` 函数可能用 `set_feature_910b` 标记特定 NPU 的扩展指令。**直接可迁移**:在 mlir 编译 driver 入口处加一个 `AscendRemoveIncompatibleKernels`,在 lowering 到 llvm 之前先剔除。值得参考的细节:**FeaturesToCheck 是白名单而非全集**,避免误判。

---

## M11 AMDGPUPrintfRuntimeBindingPass

### 3.2.1 一句话定位
把 OpenCL/HIP 的 `printf(fmt, ...)` 翻译成"分配 buffer + 写 metadata + store 参数"三件套,把字符串**搬到 module metadata**(`!llvm.printf.fmts`),由后端 AsmPrinter 序列化到 ELF,运行时(clrsync/HIP runtime)根据 buffer 内容渲染。

### 3.2.2 运行位置

**两处挂载**(都有):

1. **opt 侧 EarlySimplificationEP**(`AMDGPUTargetMachine.cpp:1058-1066`):
```cpp
PB.registerPipelineEarlySimplificationEPCallback(
    [this](ModulePassManager &PM, OptimizationLevel Level,
           ThinOrFullLTOPhase Phase) {
      if (!isLTOPreLink(Phase) && getTargetTriple().isAMDGCN()) {
        // ...
        PM.addPass(AMDGPUPrintfRuntimeBindingPass());
      }
```
注意**没有 O0 gate** —— 任何 opt level 都跑(因为 printf 必须在优化前翻译,否则 InstCombine 可能合并字符串字面量)。

2. **llc 侧 addIRPasses**(`:2374-2376`):
```cpp
if (TM.getTargetTriple().isAMDGCN())
  addModulePass(AMDGPUPrintfRuntimeBindingPass(), PMW);
```

**实际管线顺序**(用 `opt -O2 --print-pipeline-passes` 实测,`scratch/ch03/m11_pipeline.txt`):
```
... openmp-opt, amdgpu-printf-runtime-binding, ipsccp, ...
function<...>(instcombine, amdgpu-usenative, amdgpu-simplifylib,
              amdgpu-uniform-intrinsic-combine, ...)
always-inline, ...
```

**位置理由**:必须在 `ipsccp` 之前(否则字符串常量会被传播丢失原文),必须在 `always-inline` 之前(否则 printf 调用会被内联到调用方,format string metadata 跟踪失效)。

### 3.2.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUPrintfRuntimeBinding.cpp`(470 行)。

**入口过滤**(`run`,:430-460):

```cpp
auto *PrintfFunction = M.getFunction("printf");
if (!PrintfFunction || !PrintfFunction->isDeclaration() ||
    M.getModuleFlag("openmp"))
  return false;

// Verify the signature ...
if (PrintfFunctionTy->getNumParams() != 1 || !PrintfFunctionTy->isVarArg() ||
    !PrintfFunctionTy->getReturnType()->isIntegerTy(32))
  return false;
Type *PrintfFormatArgTy = PrintfFunctionTy->getParamType(0);
if (!PrintfFormatArgTy->isPointerTy() ||
    !AMDGPU::isFlatGlobalAddrSpace(
        PrintfFormatArgTy->getPointerAddressSpace()))
  return false;
```

**关键早退**:
- `openmp` module flag 存在 → 跳过(OpenMP 用 libomptarget 自己的 printf)
- printf 必须是 declaration(不是定义,避免误改 user-defined printf)
- printf 第一个参数必须在 **flat 或 global** 地址空间(`isFlatGlobalAddrSpace`)

**核心算法**(`lowerPrintfForGpu`,:138-428):

1. **收集格式串**(:157-162):`getConstantStringInfo(Op, FormatStr)`,非常量字符串打 diagnose 后跳过(:130-136)
2. **解析占位符**(`getConversionSpecifiers`,:83-113):只扫 `cdieEfFgGaAosuxXp` 17 个字符,处理 `%%` 转义(:103-106:偶数个 `%` 视为转义,奇数为占位)
3. **构造 size 描述符**(:169-225):格式 `<nargs>:<size1>:<size2>:...:<format-string>`
4. **4 字节对齐**(:184-202):任何 ArgSize % 4 != 0 的会:
   - FP 类型:`fpext` 到 float
   - `%x/%X/%u/%o`:`zext` 到 i32
   - 其它:`sext` 到 i32
5. **%f 特殊处理**(:203-213):常量 double → 转 float(因 GPU printf 默认 float);`fpext float → double` 的也回退为 float
6. **%s 字符串常量内联**(:214-219, :350-393):**字符串内容被按 4 字节 chunk 拆成整数 store 到 buffer**,而不是存指针。这是关键优化——GPU 上没有可靠的指针有效性,runtime 直接读 bytes
7. **生成调用序列**(:261-415):
   ```llvm
   %printf_alloc_fn = call ptr addrspace(1) @__printf_alloc(i32 <total_size>)
   %.not = icmp ne ptr addrspace(1) %printf_alloc_fn, null
   br i1 %.not, label %write, label %end
   write:
     store i32 <fmt_id>, ptr addrspace(1) %printf_alloc_fn
     ; ... store each arg at offset 4, 8, ...
   end:
     ; replace original printf with 0
   ```
8. **写 metadata**(:278-282):
   ```cpp
   std::string fmtstr = itostr(++UniqID) + ":" + Sizes.str();
   MDString *fmtStrArray = MDString::get(Ctx, fmtstr);
   MDNode *myMD = MDNode::get(Ctx, fmtStrArray);
   metaD->addOperand(myMD);
   ```
   `UniqID` 从 1 开始自增,与 buffer 中存的 `<fmt_id>` 一一对应。

**控制流插入**(:294-305):用 `SplitBlock + SplitBlockAndInsertIfThen` 把 store 序列放在 `printf_alloc != null` 的 hammock 块里。这是为 buffer 满时 `__printf_alloc` 返回 null 的容错。

### 3.2.4 动态验证

**输入**(`scratch/ch03/m11_in.ll`):

```llvm
@.str = private unnamed_addr addrspace(4) constant [13 x i8] c"hello %d %f\0A\00"

define amdgpu_kernel void @k(i32 %x, float %f) {
  %p = getelementptr [13 x i8], ptr addrspace(4) @.str, i64 0, i64 0
  %r = call i32 (ptr addrspace(4), ...) @printf(ptr addrspace(4) %p, i32 %x, float %f)
  ret void
}
```

**输出**(`m11_out.ll`,节选):

```llvm
!llvm.printf.fmts = !{!0}
!0 = !{!"1:2:4:4:hello %d %f\\n"}
; 解读: ID=1, nargs=2, sizes=[4,4], fmt="hello %d %f\n"
;       注意 ':' 是元数据分隔符, '\n' 用 \\n 转义

define amdgpu_kernel void @k(i32 %x, float %f) #0 {
  %p = getelementptr [13 x i8], ptr addrspace(4) @.str, i64 0, i64 0
  %printf_alloc_fn = call ptr addrspace(1) @__printf_alloc(i32 12)
  ; 12 = 4(首部 ID) + 4(i32) + 4(float),DWORD_ALIGN=4
  br label %.split

.split:
  %1 = icmp ne ptr addrspace(1) %printf_alloc_fn, null
  br i1 %1, label %2, label %3

2:
  store i32 1, ptr addrspace(1) %printf_alloc_fn          ; 写 fmt_id = 1
  %PrintBuffGep = getelementptr i8, ptr addrspace(1) %printf_alloc_fn, i32 4
  store i32 %x, ptr addrspace(1) %PrintBuffGep             ; 写第一个 arg
  %PrintBuffNextPtr = getelementptr i8, ptr addrspace(1) %PrintBuffGep, i32 4
  store float %f, ptr addrspace(1) %PrintBuffNextPtr       ; 写第二个 arg
  br label %3

3:
  ret void
}

declare ptr addrspace(1) @__printf_alloc(i32) #1
```

观察:
- printf call **整个被替换**(原 `%r` 是 dead 的,`replaceAllUsesWith(0)` 后由后续 DCE 清除)
- buffer 在 `addrspace(1)`(global),runtime 端用 host-visible 指针读
- **没有保留对 `@.str` 的运行时引用** —— 字符串已被搬到 metadata,`@.str` 会在后续 GlobalDCE 中被删除

### 3.2.5 设计动机

**为什么必须在 IR 层做**:
1. **metadata 是 IR 唯一概念** —— DAG/Machine 没有 NamedMDNode
2. **格式串必须在编译期静态化**,否则 GPU runtime 无法离线解析
3. **`__printf_alloc` 是后端 intrinsic**,前端必须发射出对该符号的引用

**为什么不直接把字符串存进 global buffer**:`@.str` 的内容放在 `.rodata`,但 GPU runtime 读 printf buffer 时是 host 端,不能假定 device 内存可访问。把格式串搬到 ELF metadata(`msgpack` section),runtime 通过 host ELF 解析就能拿到原文,无需 map device memory。

**为什么用 ID 而非字符串哈希**:哈希可能冲突;ID 是 module-local 自增,加上 host 端 ELF 解析,保证唯一性。

### 3.2.6 昇腾启示

昇腾 Ascend 也有 `printf` 需求(虽然生产代码少用)。**可借鉴点**:
- "字符串 → metadata + buffer store ID"模式完全可平移
- 4 字节对齐 + DWORD 打包对 NPU 寄存器宽度同样适用
- `%s` 的字符串常量内联(避免 device 内存解引用)是关键设计,昇腾的 host-device 内存模型同样需要

---

## M4 AMDGPUCtorDtorLoweringPass

### 3.3.1 一句话定位
把 LLVM 通用的 `@llvm.global_ctors` / `@llvm.global_dtors` 翻译为两个**weak_odr amdgpu_kernel** 函数 `amdgcn.device.init` 和 `amdgcn.device.fini`,让 GPU runtime 能像调用普通 kernel 一样执行全局构造/析构。

### 3.3.2 运行位置

**仅一处**(`AMDGPUTargetMachine.cpp:2377-2379`):
```cpp
if (LowerCtorDtor)
  addModulePass(AMDGPUCtorDtorLoweringPass(), PMW);
```

Gate:`LowerCtorDtor`(`cl::opt`,默认 true)。
**位于 printf 之后**(:2375),合理——ctor/dtor 函数体可能含 printf,先翻译完再处理 ctor 表。

### 3.3.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUCtorDtorLowering.cpp`(185 行)。

**入口**(`lowerCtorsAndDtors`,:155-160):

```cpp
Modified |= createInitOrFiniKernel(M, "llvm.global_ctors", /*IsCtor=*/true);
Modified |= createInitOrFiniKernel(M, "llvm.global_dtors", /*IsCtor=*/false);
```

**生成函数签名**(`createInitOrFiniKernelFunction`,:30-47):

```cpp
Function *InitOrFiniKernel = Function::createWithDefaultAttr(
    FunctionType::get(Type::getVoidTy(M.getContext()), false),
    GlobalValue::WeakODRLinkage, 0, InitOrFiniKernelName, &M);
InitOrFiniKernel->setCallingConv(CallingConv::AMDGPU_KERNEL);
InitOrFiniKernel->addFnAttr("amdgpu-flat-work-group-size", "1,1");
if (IsCtor)
  InitOrFiniKernel->addFnAttr("device-init");
else
  InitOrFiniKernel->addFnAttr("device-fini");
```

关键属性:
- `WeakODRLinkage` —— 多 module LTO 时保留一份
- `AMDGPU_KERNEL` calling convention —— 直接作为 kernel 入口
- `amdgpu-flat-work-group-size = "1,1"` —— **强制 workgroup 大小为 1**,避免 ctor 内的 divergent 控制流问题
- `device-init` / `device-fini` 字符串属性 —— runtime 通过属性识别这两个特殊 kernel

**循环体生成**(`createInitOrFiniCalls`,:72-134)——手写 IR 等价于:

```c
void call_init_array_callbacks() {
  for (auto p = __init_array_start; p != __init_array_end; ++p)
    (*p)();
}
void call_fini_array_callbacks() {
  // 析构逆序
  for (auto p = __fini_array_end - 1; p >= __fini_array_start; --p)
    (*p)();
}
```

细节:
- `__init_array_start/end` 是 external global(`:82-101`),由链接器(通常 `lld` + linker script)提供
- Ctor 用 `icmp ne` + `+1` 步进(:118, :126-127);Dtor 用 `icmp uge` + `-1` 步进
- 用 `while.entry` / `while.end` BB 命名而非 `for.*`,更贴近 C 语义
- `appendToUsed(M, {InitOrFiniKernel})`(:151):把生成的 kernel 加入 `llvm.used`,防止被 GlobalDCE 误删

### 3.3.4 动态验证

**输入**(`scratch/ch03/m04_in.ll`):

```llvm
@llvm.global_ctors = appending global [1 x { i32, ptr, ptr }] [{ i32, ptr, ptr } { i32 65535, ptr @my_ctor, ptr null }]
@llvm.global_dtors = appending global [1 x { i32, ptr, ptr }] [{ i32, ptr, ptr } { i32 65535, ptr @my_dtor, ptr null }]

define internal void @my_ctor() { ret void }
define internal void @my_dtor() { ret void }
```

**输出**(完整,`m04_out.ll`):

```llvm
@__init_array_start = external addrspace(1) constant [0 x ptr addrspace(1)]
@__init_array_end   = external addrspace(1) constant [0 x ptr addrspace(1)]
@__fini_array_start = external addrspace(1) constant [0 x ptr addrspace(1)]
@__fini_array_end   = external addrspace(1) constant [0 x ptr addrspace(1)]
@llvm.used = appending addrspace(1) global [2 x ptr]
             [ptr @amdgcn.device.init, ptr @amdgcn.device.fini],
             section "llvm.metadata"

define weak_odr amdgpu_kernel void @amdgcn.device.init() #1 {
entry:
  %0 = icmp ne ptr addrspace(1) @__init_array_start, @__init_array_end
  br i1 %0, label %while.entry, label %while.end

while.entry:
  %ptr = phi ptr addrspace(1) [ @__init_array_start, %entry ],
                              [ %next, %while.entry ]
  %callback = load ptr, ptr addrspace(1) %ptr, align 8
  call void %callback()
  %next = getelementptr ptr addrspace(1), ptr addrspace(1) %ptr, i64 1
  %end = icmp eq ptr addrspace(1) %next, @__init_array_end
  br i1 %end, label %while.end, label %while.entry

while.end:
  ret void
}

define weak_odr amdgpu_kernel void @amdgcn.device.fini() #2 {
entry:
  ; dtor 用 uge + -1 步进,逆序遍历
  %0 = icmp uge ptr addrspace(1)
       getelementptr inbounds (ptr addrspace(1), ptr addrspace(1) @__fini_array_end, i64 -1),
       @__fini_array_start
  br i1 %0, label %while.entry, label %while.end
  ; ...
}

attributes #1 = { "amdgpu-flat-work-group-size"="1,1" "device-init" }
attributes #2 = { "amdgpu-flat-work-group-size"="1,1" "device-fini" }
```

**观察**:
- `amdgpu_kernel` calling conv 直接暴露给 runtime
- `@llvm.used` 防止后续 pass 删除 init/fini kernel
- 链接器符号 `__init_array_start` 等被声明为 **0 长度数组**(常见 trick:`[0 x ptr]`,只取地址不取内容)

### 3.3.5 设计动机

**为什么不能直接用 `@llvm.global_ctors`**:GPU 没有"程序启动"概念,只有"kernel launch"。Ctor 必须由**某个 kernel** 触发执行。翻译为 kernel 是最自然的方式。

**为什么 `amdgpu-flat-work-group-size=1,1`**:
- ctor 通常含**全局副作用**(写 device global),若用 wave32/64 并发执行会触发 race
- 强制 1x1 让 runtime 只发一个 thread,行为可预测

**为什么 `WeakODRLinkage` 而非 `Internal`**:多 TU RDC 模式下,每个 module 都可能生成这个 kernel;WeakODR 让链接器只保留一份,ODR 保证语义一致。

**为什么 priority 字段被忽略**:`@llvm.global_ctors` 是 `{i32 priority, ptr, ptr}`,但本 pass 完全不读 priority(:142-143 只检查数组非空)。链接器脚本负责把 `__init_array` 按 priority 排好序。

### 3.3.6 昇腾启示

昇腾 NPU 也面对"全局对象初始化"问题。**可直接照搬**:
- 生成 `ascend.device.init` / `ascend.device.fini` kernel
- 强制 workgroup=1 是普遍必需的
- 链接器脚本配合:昇腾需要在 `*.ld` 里加 `__ascend_init_array_start/end` section

---

## M5 AMDGPUExportKernelRuntimeHandlesPass

### 3.4.1 一句话定位
找到 `.amdgpu.kernel.runtime.handle` section 里的全局变量(OpenCL enqueue 用),把它们的 linkage 从 `internal` 改为 `external`,并给关联的 kernel 加 `protected` visibility,让 host runtime 能**通过符号名访问 device 端数据结构**。

### 3.4.2 运行位置

**仅一处**(`AMDGPUTargetMachine.cpp:2392-2393`):
```cpp
addModulePass(AMDGPUExportKernelRuntimeHandlesPass(), PMW);
```

**位于 AlwaysInline 之后**(:2389-2391 之间),理由:AlwaysInline 可能合并 kernel 体,`!associated` metadata 必须在最终形态下处理。

### 3.4.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUExportKernelRuntimeHandles.cpp`(110 行)。

**核心逻辑**(`exportKernelRuntimeHandles`,:60-95):

```cpp
const StringLiteral HandleSectionName(".amdgpu.kernel.runtime.handle");

for (GlobalVariable &GV : M.globals()) {
  if (GV.getSection() == HandleSectionName) {
    GV.setLinkage(GlobalValue::ExternalLinkage);
    GV.setDSOLocal(false);
    Changed = true;
  }
}

if (!Changed)
  return false;

for (Function &F : M) {
  if (F.getCallingConv() != CallingConv::AMDGPU_KERNEL)
    continue;

  const MDNode *Associated = F.getMetadata(LLVMContext::MD_associated);
  if (!Associated)
    continue;

  auto *VM = cast<ValueAsMetadata>(Associated->getOperand(0));
  auto *Handle = dyn_cast<GlobalObject>(VM->getValue());
  if (Handle && Handle->getSection() == HandleSectionName) {
    F.setLinkage(GlobalValue::ExternalLinkage);
    F.setVisibility(GlobalValue::ProtectedVisibility);
  }
}
```

两阶段:
1. **处理全局变量**:section 名匹配 → external linkage + 非 dso_local
2. **处理关联 kernel**:遍历所有 `AMDGPU_KERNEL` 函数,如果 `!associated` metadata 指向该 handle → external + protected

**`!associated` metadata 的语义**:LLVM 通用 metadata,表示"该函数的生存周期与那个全局变量绑定"。AMDGPU 用它把 kernel 与 runtime handle 关联,使 linker 不会单独 dead-strip 其中一个。

**为何 Protected visibility 而非 Default**:Protected 让符号对外可见,但**不能被 interpose**(其它 .so 不能覆盖它),避免 host runtime 意外绑定错对象。

### 3.4.4 动态验证

**输入**(`scratch/ch03/m05_in.ll`):

```llvm
@__handle_foo = internal global ptr null, section ".amdgpu.kernel.runtime.handle"

define internal amdgpu_kernel void @foo() !associated !0 {
  ret void
}
!0 = !{ptr @__handle_foo}
```

**输出**(`m05_out.ll`):

```llvm
@__handle_foo = global ptr null, section ".amdgpu.kernel.runtime.handle"
                  ; ↑ internal 关键字没了 → external linkage

define protected amdgpu_kernel void @foo() #0 !associated !0 {
                ; ↑ internal → external + protected
  ret void
}
```

完全匹配源码预期。

### 3.4.5 设计动机

**场景**:OpenCL `clEnqueueNDRangeKernel` 需要 host 端能拿到 kernel 的"句柄"来 query 信息(寄存器数、group size 等)。句柄本身在 device 端是数据(`ptr` global),但必须 host 能 symbolize 访问。

**为什么用 section 而非命名约定**:section 是 ELF 层概念,`lld` 会保留;若用 `__handle_*` 命名约定,`GlobalDCE` 可能误删。

**为何不要默认 internal 就够**:内部 linkage 的符号会被链接器 strip;external 才能进 symtab。

**TODO 注释**(:17-20):
```
TODO: This could be replaced with a new linkage type or global object
metadata that produces an external symbol in the final object, but allows
rename on IR linking. Alternatively if we can rely on
GlobalValue::getGlobalIdentifier we can just make these external symbols
to begin with.
```

作者承认这是个 hack——理想方案是发明一种"对运行时可见但对链接器内部"的新 linkage 类型。

### 3.4.6 昇腾启示

昇腾的 `__aicore__` kernel 也有 host-device 句柄绑定问题。**直接可迁移**,但建议绕过这个"section + external + protected" hack,在昇腾 IR 中定义专用 attribute(如 `ascend.host_visible`),让 metadata 而非 linkage 承担语义。

---

## §3 章末总结

| Pass | 输入形态 | 输出形态 | 后端消费点 |
|---|---|---|---|
| M12 | 含跨 gfx 的混合模块 | 当前 gfx 能跑的子集(null call 占位) | 防止 ISel 崩溃 |
| M11 | printf call + rodata 字符串 | `__printf_alloc` + store 序列 + metadata | AsmPrinter 序列化 `!llvm.printf.fmts` 到 ELF |
| M4 | `@llvm.global_ctors/dtors` | `amdgcn.device.init/fini` kernel | runtime 当 kernel launch |
| M5 | internal handle + internal kernel | external handle + protected kernel | host runtime 符号访问 |

**共性**:这四个 pass 都是**协议翻译器**——把"LLVM 通用 IR 表达力"翻译成"AMDGPU runtime/链接器/驱动能理解的具体形式"。它们不做性能优化,而是**正确性准备**。

**与后续中端 pass 的接口**:M12 清场之后,后续 attributor/inline 等才能安全假设模块内函数都是合法的;M11 把 printf 变成 store,后续 InstCombine/GVN 可以正常优化 store 序列;M4 生成的新 kernel 会进入正常的 kernel 处理管线(LowerKernelArguments/PromoteAlloca 等);M5 把 kernel 标记 external 后,Attributor 必须**保留**这些函数不被 internalize。

**已验证假设**:
1. ✅ M12 的 feature check 真实(同一 IR,gfx803 vs gfx942 行为不同)
2. ✅ M11 字符串确实被搬到 metadata,`@.str` 不再被引用
3. ✅ M4 的 `amdgpu-flat-work-group-size="1,1"` 是强制的
4. ✅ M5 的 `!associated` 处理正确(internal → protected)

**遗留问题**(后续章节会用到):
- M12 的 `FeaturesToCheck` 19 项是否在每次新 gfx 发布时手工同步?(看代码 history)
- M11 的 `%s` 字符串常量内联对**非常量字符串**直接跳过(返回 `???`)—— HIP printf 运行时的容错如何?
- M4 的 priority 字段被忽略,若用户依赖 priority,谁来排序?(答案:链接器脚本)
- M5 的 TODO 何时被实现?(查 LLVM issue tracker)
