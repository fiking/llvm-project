# §6 Clang TargetInfo 的 NVPTX 实现

基准：LLVM main @ 3eda2aebadd4，clang-24（build-debug）。
动态验证命令均可用 `--target=nvptx64-nvidia-cuda --cuda-device-only -nocudainc -nocudalib` 复现。

---

## 1. NVPTXTargetInfo 类结构

### 静态分析

**双类还是单类？——单类双实例化。** 没有名为 NVPTXTargetInfo64 的类；32/64 位模式通过构造函数第三参区分（clang/lib/Basic/Targets/Targets.cpp:430-435）：

```cpp
case llvm::Triple::nvptx:  return std::make_unique<NVPTXTargetInfo>(Triple, Opts, /*TargetPointerWidth=*/32);
case llvm::Triple::nvptx64: return std::make_unique<NVPTXTargetInfo>(Triple, Opts, /*TargetPointerWidth=*/64);
```

类声明在 clang/lib/Basic/Targets/NVPTX.h:57-207，成员：`GPU`（OffloadArch）、`PTXVersion`（uint32_t）、`HostTarget`（unique_ptr<TargetInfo>，NVPTX.h:59-61）。

**构造函数**（NVPTX.cpp:38-165）关键序列：

| 行号 | 动作 |
|---|---|
| :42-43 | assert TargetPointerWidth ∈ {32,64} |
| :47-54 | PTXVersion 从 `Opts.FeaturesAsWritten` 解析 `+ptxNN`；默认 0 = "use the minimum for the SM target" |
| :56-57 | `TLSSupported=false; VLASupported=false` |
| :58-59 | `AddrSpaceMap=&NVPTXAddrSpaceMap; UseAddrSpaceMapMangling=true` |
| :61-62 | `__bf16` always load/store only（BFloat16Width=16） |
| :71-73 | NVPTXTargetParser.def 全部 GPU 名插入 ReadOnlyFeatures（注释：arch 只 gate builtins，后端从 `target-cpu` 取架构） |
| :75-77 | `HasFastHalfType=true; HasFloat16=true`（"PTX supports f16 as a fundamental type"）——注意**未设 HalfArgsAndReturns**，见 §5 |
| :79 | `DataLayoutString = Triple.computeDataLayout()` |
| :83-85 | HostTriple 非 NVPTX 时 `HostTarget = AllocateTarget(Opts.HostTriple)` |
| :88-108 | **无 host 分支**：LongWidth=PointerWidth=TargetPointerWidth；32 位 SizeType=UnsignedInt/IntPtrType=SignedInt，64 位 UnsignedLong/SignedLong；MaxAtomicInlineWidth=TPW |
| :110-153 | **有 host 分支**：拷贝约 30 项类型属性（PointerWidth/Int/Long/SizeType/PtrDiffType/WChar/… 及位域对齐策略）。MaxAtomicInlineWidth 的拷贝是"a bit of a lie"（:149-153 原注释）：为了让 `__GCC_ATOMIC_XXX_LOCK_FREE` host/device 一致，否则标准库类在两边定义不同 |
| :155-164 | 注释明确**故意不拷贝**：LargeArrayMinWidth/Align、SuitableAlign、LongDoubleWidth/Align（nvptx 的 long double==double，host 未必；TODO: nvcc 对 device long double 有警告，我们应跟进） |

其它覆写：`initFeatureMap`（NVPTX.h:74-85，GPU→`Features[OffloadArchToString(GPU)]`，PTXVersion≠0→`ptxN`）；`setABI` 只认 `"shortptr"`（NVPTX.cpp:167-173，重设 DataLayout）；`hasFeature` 只认 `ptx`/`nvptx`（:179-183）；`isAddressSpaceSupersetOf`（NVPTX.h:91-103，generic(0) 是 {0,1,3,4,5} 的超集，排除不存在的 AS 2）；`validateAsmConstraint` c/h/r/l/f/d/q（:112-127）；`isCLZForZeroUndef=false`（:72）；`hasBitIntType/hasBFloat16Type=true`（:203-204）；OpenCL 扩展开关 `setSupportedOpenCLOpts`（:151-173，含 cl_khr_fp64、atomics、generic AS）。

### 动态验证

`-cc1 -triple nvptx64-nvidia-cuda -fcuda-is-device -target-cpu sm_70`（HostTriple 缺省=自身 NVPTX → 走"无 host"分支，64 位布局生效）。完整 driver 模式下 device 编译时 driver 传 `-aux-triple nvptx64-nvidia-cuda`（=自身，实测 -###），NVPTX.cpp:84 `if (!HostTriple.isNVPTX())` 使 HostTarget 不创建。

### 设计动机

- **单类 + 指针宽度参数**：PTX 的 32/64 差异仅是 `.address_size` 与指针/long 布局，不值得类分裂（对比 AMDGPU 也是单类）。
- **HostTarget 委托**：CUDA 是单源双编译模型，device 端类型布局必须与 host ABI 匹配（决定 host/device 边界上的结构体传递），所以"能拷就拷"；MaxAtomicInlineWidth 的"谎言"是为了 libstdc++/libc++ 模板在两端实例化出同一套类定义。
- **PTXVersion 不默认**：让后端按 SM 目标自选最低 PTX 版本，特性字符串只作显式请求。

### 昇腾映射（推理级，待验证）

CCE 若同样采用"device 编译时借用 host 类型布局"的策略，对应物是 Ascend C 中 host 侧结构体布局与 kernel 侧的一致性约定；`__CCE_AICORE__` 体系（见 §7）不涉及类型布局拷贝，主要承担 arch 分支职能。

---

## 2. __CUDA_ARCH__ 的生成链

### 静态分析

**值的生产点——TargetInfo::getTargetDefines**（clang/lib/Basic/Targets/NVPTX.cpp:185-207）：

```cpp
Builder.defineMacro("__PTX__");      // :187 无条件
Builder.defineMacro("__NVPTX__");    // :188
if (!GPU.isNVPTX()) return;          // :191-192 GPU 未设置则无 arch 宏
if (Opts.CUDAIsDevice || Opts.OpenMPIsTargetDevice || !HostTarget) {  // :194
  unsigned ArchID = CudaArchToID(GPU);                 // :196
  Builder.defineMacro("__CUDA_ARCH__", Twine(ArchID)); // :197
  if (IsNVIDIAAcceleratedOffloadArch(GPU)) {           // :199 sm_90a 等
    Builder.defineMacro("__CUDA_ARCH_SPECIFIC__", Twine(ArchID));       // :200
    Builder.defineMacro("__CUDA_ARCH_FEAT_SM" + Twine(ArchID/10) + "_ALL", "1"); // :201-202
  }
  if (IsNVIDIAFamilySpecificOffloadArch(GPU))          // :204
    Builder.defineMacro("__CUDA_ARCH_FAMILY_SPECIFIC__", Twine(ArchID)); // :205
}
```

**sm_XX→数值映射**：`CudaArchToID(OffloadArch)` = `llvm::NVPTX::getSmVersion(Arch.nvptxKind())`（clang/lib/Basic/Cuda.cpp:133-136）。数值表源头 llvm/include/llvm/TargetParser/NVPTXTargetParser.def（:14-17 注释自述 `SM_ID - Numeric compute-capability id (sm_90 -> 900)`）：

- :42 `NVPTX_GPU("sm_70", SM_70, "compute_70", 700, CUDA_90, NEW, NONE)`
- :50 `NVPTX_GPU("sm_90", SM_90, "compute_90", 900, CUDA_118, NEW, NONE)`
- :51 `NVPTX_GPU("sm_90a", SM_90a, "compute_90a", 900, CUDA_120, NEW, ACCELERATED)`

即 **__CUDA_ARCH__ = SM_ID = sm 数值 × 10**（sm_70→700）。

**InitPreprocessor 的兜底定义**（clang/lib/Frontend/InitPreprocessor.cpp:1492-1497）：

```cpp
// CUDA device path compilaton
if (LangOpts.CUDAIsDevice && !LangOpts.HIP) {
  // The CUDA_ARCH value is set for the GPU target specified in the NVPTX
  // backend's target defines.
  Builder.defineMacro("__CUDA_ARCH__");   // 无值
}
```

此处是**存在性兜底**（且显式排除 HIP）；注释自述"值由 NVPTX（Basic/Targets 意义上的 backend）的 target defines 提供"。实测最终宏值为 700（带值定义生效）。

**__CUDA_ARCH_LIST__——driver 层注入**（clang/lib/Driver/ToolChains/Clang.cpp:1078-1097）：收集本次编译全部 CUDA offload 架构（`C.getOffloadToolChains(OFK_Cuda)` → `D.getOffloadArchs` → `CudaArchToID`），`std::set<unsigned>` 去重排序后 `interleave ","` 拼成 `-D__CUDA_ARCH_LIST__=700,900` 传给 cc1。单 arch 时即 `-D__CUDA_ARCH_LIST__=700`。

**双通道关系（前端宏 vs 后端 reflect）**：

1. **前端宏 `__CUDA_ARCH__`**：作用于源码/头文件的预处理分支（`#if __CUDA_ARCH__ >= 350`）。libdevice 的 C++ 包装头（`__cuda_libdevice` 内联声明）与用户代码用它。
2. **后端 `__nvvm_reflect("__CUDA_ARCH")`**：libdevice 主体是**预编译 LLVM bitcode**，不经过 clang 预处理器，其内部 `__nvvm_reflect` 调用由 NVVMReflect pass 在后端常量折叠（该链详见 02-ir-layer.md，不重复）。

**为何必须两条**：(a) bitcode 无预处理阶段，宏通道对它无效；(b) host 编译（CUDAIsDevice=false）没有后端参与，reflect 通道不存在，且 NVPTX.cpp:194 的门控使 host pass 时 `__CUDA_ARCH__` 也不定义——两条通道各自覆盖"编译期源码"与"链接期 bitcode"两个世界。

### 动态验证（clang-24 实测）

**① 完整模式宏导出**（`--cuda-gpu-arch=sm_70 -dM -E`，449 个宏中相关项）：

```
#define __CUDA_ARCH__ 700
#define __CUDA_ARCH_LIST__ 700
#define __PTX__ 1
#define __NVPTX__ 1
```

`-cc1` 直通（`-fcuda-is-device -target-cpu sm_70`）得到 `__CUDA_ARCH__=700` 但**没有 `__CUDA_ARCH_LIST__`**——证明后者纯属 driver `-D` 注入。绕坑法：cc1 层用 `-target-cpu`。

**② sm_70 vs sm_90 宏 diff**：449 个宏中**仅 2 个**不同——`__CUDA_ARCH__` 700→900、`__CUDA_ARCH_LIST__` 700→900。其余（含 __PTX__/__NVPTX__/全部 builtin 宏）逐一相同。

**②b sm_90a 附加宏**（accelerated 架构）：

```
#define __CUDA_ARCH__ 900
#define __CUDA_ARCH_SPECIFIC__ 900
#define __CUDA_ARCH_FEAT_SM90_ALL 1
#define __CUDA_ARCH_FAMILY_SPECIFIC__ 900
```

### 设计动机

- 门控 `CUDAIsDevice || OpenMPIsTargetDevice || !HostTarget`（NVPTX.cpp:194）：OpenMP offload 到 NVPTX 也需要 arch 宏；`!HostTarget` 兜底裸 nvptx 编译。
- SPECIFIC/FAMILY_SPECIFIC 二级宏是 nvcc 的 `__CUDA_ARCH_SPECIFIC__`（如 90a/100f 等带后缀变体）与家族宏（如 90 系）的对齐实现，让加速变体特有 intrinsics 可被 `#ifdef` 区分。
- `__CUDA_ARCH_LIST__` 服务于头文件做"多 arch fatbin 全集"判断（nvcc 语义），clang 放在 driver 层是因为只有 driver 知道本轮全部 offload arch。

### 昇腾映射（推理级，待验证）

CCE 的 `__CCE_AICORE__`（数值按 Ascend 型号编码）+ `__CCE_AIVECTOR__` 等宏承担同位职能：编译期按芯片分支选择 tiling/intrinsics。关键对照点：(a) CCE 宏由编译驱动注入还是 TargetInfo 层 getTargetDefines 注入；(b) 昇腾的算子库（tilib 等）若是预编译形态则需要 NVVMReflect 式后端通道，若纯源码头文件则单宏通道足够。**待验证**。

---

## 3. AS 映射表的本家视角

### 静态分析

NVPTXAddrSpaceMap（clang/lib/Basic/Targets/NVPTX.h:27-45）：

```cpp
static constexpr LangASMap NVPTXAddrSpaceMap = {
    {LangAS::opencl_global, 1},        // PTX .global
    {LangAS::opencl_local, 3},         // PTX .shared  ← 注意
    {LangAS::opencl_constant, 4},      // PTX .const
    // FIXME: generic has to be added to the target
    {LangAS::opencl_generic, 0},
    {LangAS::opencl_global_device, 1},
    {LangAS::opencl_global_host, 1},
    {LangAS::cuda_device, 1},          // ← 与 opencl_global 同行同表
    {LangAS::cuda_constant, 4},        // ← 与 opencl_constant 同值
    {LangAS::cuda_shared, 3},          // ← 与 opencl_local 同值
    {LangAS::sycl_global, 1}, ...      // :38-44 sycl 系同理
};
```

**LangAS 统一命名空间的设计**：`LangAS` 枚举把所有语言方言的地址空间（opencl_*/cuda_*/sycl_*/hlsl_*）编入一个命名空间，每个 TargetInfo 用**一张** LangASMap 把它们整体映射到目标 AS 数值。效果：同一份 AST/CodeGen 逻辑（如 `CodeGenModule::GetGlobalVarAddressSpace`）面对 `__device`/`__global`/`global` 时查同一张表，不需要按语言分派。

**对照 AMDGPU 表**（clang/lib/Basic/Targets/AMDGPU.cpp:31-63）：

| LangAS | NVPTX | AMDGPU | 备注 |
|---|---|---|---|
| Default | （未列出，基类默认 0=generic） | FLAT(0)（:32 显式列出） | |
| opencl_global / cuda_device / sycl_global | 1 | GLOBAL(1) | 数值一致 |
| opencl_local / cuda_shared / sycl_local | 3 | LOCAL(3)（:34/:42/:46） | **数值同、语义标签不同**：PTX 的 3 是 `.shared`，AMDGPU 的 3 是 LOCAL（flat 之外的私有 scratch 另有 PRIVATE=5）；OpenCL local 在 PTX 落到 `.shared` |
| opencl_constant / cuda_constant | 4 | CONSTANT(4) | 一致 |
| opencl_private | （表中无此行，走 Default→0） | PRIVATE(5)（:36） | NVPTX 无 OpenCL private 专属映射 |
| hlsl_* / ptr32/64 / amdgpu_barrier | 无 | 有（:50-62） | AMDGPU 面向更多前端 |

配套：`UseAddrSpaceMapMangling=true` 两家相同（NVPTX.cpp:59 / AMDGPU.cpp:206），AS 参与 mangling。DWARF 侧 NVPTXDWARFAddrSpaceMap（NVPTX.h:49-55，取自 PTX Writers' Guide to Interoperability）：default/private=-1、global=5、local(cuda_shared)=8、constant=4——这是 DWARF 地址类别编码，不是 PTX AS。

`isAddressSpaceSupersetOf`（NVPTX.h:91-103）：A==B，或 A∈{Default, target-AS 0(generic)} 且 B 为 target AS 且 `0≤B≤5 && B≠2`——即 generic 是全部实际 PTX AS（0,1,3,4,5）的超集，对应 PTX 语义"generic 指针可指向一切"。

### 动态验证

（AS 数值→PTX 指令的下游验证见 03 与 02 笔记；本节属 Basic 层静态表，配合 02-ir-layer.md 的 addrspacecast 证据链阅读。）

### 设计动机

- **一表多语言**：CUDA/OpenCL/SYCL 共享同一物理 AS 布局，LangAS 统一命名空间让"语言语义→硬件 AS"的映射声明式化、单一事实源。
- `opencl_local→3(.shared)` 的选择：OpenCL local memory 语义（workgroup 级共享）正是 PTX `.shared`；AMDGPU 的 LOCAL 数值碰巧也是 3，是各自 ISA 的巧合而非设计对齐。
- NVPTX.h:31 的 FIXME 说明 generic 曾是痛点（早期 PTX 无 generic，2.x 引入后补 0 映射）。

### 昇腾映射（推理级，待验证）

CCE 的 `__gm/__dm/__local` 等存储限定符体系对应 LangAS 式"语言级 AS"层；若做 clang 式统一，等价物是一张 CCEASMap：语言限定符→昇腾目标 AS（GM/DM/LM 数值）。**待验证**：CCE 内部是否已有类似统一映射层，还是按关键字直接在后端 lower。

---

## 4. 调用约定校验

### 静态分析

**checkCallingConvention**（clang/lib/Basic/Targets/NVPTX.h:193-201）：

```cpp
// CUDA compilations support all of the host's calling conventions.
// TODO: We should warn if you apply a non-default CC to anything other
// than a host function.
if (HostTarget)
  return HostTarget->checkCallingConvention(CC);
return CC == CC_DeviceKernel ? CCCR_OK : CCCR_Warning;
```

- **有 HostTarget**：完全委托 host 的校验表（CUDA 源码里 host 函数的 CC 合法性由 host 架构说了算）。
- **无 HostTarget（device-only）**：白名单**只有 `CC_DeviceKernel`**。`CC_C` 不在白名单——因为默认 CC 不经过属性校验路径，只有显式 `__attribute__((cdecl))` 之类才走；对它们一律 CCCR_Warning。

CC_DeviceKernel 定义于 clang/include/clang/Basic/Specifiers.h:292（`CC_DeviceKernel, // __attribute__((device_kernel))`）。

**DeviceKernel 属性拼写表**（clang/include/clang/Basic/Attr.td:1671-1674）：

```
Clang<"device_kernel">, Clang<"nvptx_kernel">, Clang<"amdgpu_kernel">,
CustomKeyword<"__kernel">, CustomKeyword<"kernel">
```

Attr.td:1687-1695 提供 `isNVPTXSpelling()`（GNU_nvptx_kernel / CXX11_clang_nvptx_kernel / C23_clang_nvptx_kernel）。

**下游 CodeGen**：`NVPTXTargetCodeGenInfo::getDeviceKernelCallingConv()` 返回 `llvm::CallingConv::PTX_Kernel`（clang/lib/CodeGen/Targets/NVPTX.cpp:86-88），`setTargetAttributes` 在 :272 `F->setCallingConv(...)`。基类默认实现（clang/lib/CodeGen/TargetInfo.cpp:115-126）assert OpenCL 并返回 `CallingConv::C`——NVPTX 是少数覆写者。`__global__`（CUDAGlobal attr，Attr.td:1592-1597）走 CUDA 惯用链，nvptx_kernel/amdgpu_kernel 是**非 CUDA 语言直标 kernel** 的底层通道（OpenMP offload / 裸 C）。

**Sema 消费链**（clang/lib/Sema/SemaDeclAttr.cpp:5930-6004）：CUDA 时按函数 host/device 归属分别校验——HostTI 与 DeviceTI 的选取随 CUDAIsDevice 翻转（:5953-5954），`__host__ __device__` 两边都查（:5955-5958，host 先查且须 OK）。CCCR_Ignore → 降级为显式 CC_C（:5990-5996，Win64 __stdcall 先例）；CCCR_Warning → `warn_cconv_unsupported`（:6004，实测输出 `-Wignored-attributes`）。

### 动态验证（clang-24 实测）

| 场景 | 输入 | 结果 |
|---|---|---|
| device-only（无 HostTarget） | `__attribute__((fastcall)) void f(void){}` | `warning: 'fastcall' calling convention is not supported for this target [-Wignored-attributes]`（NVPTX.h:200 CCCR_Warning 路径） |
| `-cc1 -aux-triple i386-unknown-linux-gnu` | 同上 | **clean**——i386 HostTarget 的表放行 CC_X86FastCall（X86TargetInfo 表 clang/lib/Basic/Targets/X86.h:380-401），证明委托链真实生效 |
| `-cc1 -aux-triple x86_64-unknown-linux-gnu` | 同上 | 仍告警——X86_64TargetInfo 有独立重写（X86.h:753，行号经 grep 确认存在；内容未逐行核读，实测行为为不放行 fastcall） |
| `__attribute__((nvptx_kernel)) void k(int*)` | device-only | RC=0 clean，CodeGen 走 PTX_Kernel |
| `__attribute__((device_kernel))` | 同上 | RC=0 clean |
| `__attribute__((kernel))`（CustomKeyword spelling） | 同上 | `warning: unknown attribute 'kernel' ignored`——该 spelling 仅 OpenCL 语境可用 |

### 设计动机

- 委托 host 是 CUDA 单源模型的必然：同一份头里的 `__host__ void f()` 在 device 编译 pass 里也要过 Sema，其 CC 合法性必须按 host 规则判定。
- 无 host 时只放 kernel CC：device 侧唯一"非 C"的入口形态是 kernel 入口；PTX 的 param 空间 ABI 由后端处理，前端不设第二套规则。
- TODO 注释（NVPTX.h:196-197）承认现状粗糙：对 device 函数施加 host CC 只该警告而非静默放行。

### 昇腾映射（推理级，待验证）

CCE kernel 入口（`__aicore__`/`extern "C"` + 特定 pragma）对应"唯一放行的 device 入口 CC"；昇腾 host/device 混合语义弱于 CUDA（host 侧是通用编译），故不太需要 HostTarget 式委托。**待验证**：CCE 是否存在 CC 白名单校验点。

---

## 5. 半精度状态

### 静态分析

NVPTX（clang/lib/Basic/Targets/NVPTX.cpp:75-77）：

```cpp
// PTX supports f16 as a fundamental type.
HasFastHalfType = true;
HasFloat16 = true;
```

**HalfArgsAndReturns 未设置** → 沿用 TargetInfo 默认 false（声明 clang/include/clang/Basic/TargetInfo.h:240；取值接口 `allowHalfArgsAndReturns()` TargetInfo.h:708）。

对照 AMDGPU（clang/lib/Basic/Targets/AMDGPU.cpp:215-218 + :245）：

```cpp
HasFastHalfType = true;   // :217
HasFloat16 = true;        // :218
...
HalfArgsAndReturns = true; // :245
```

即 **AMDGPU 三开、NVPTX 两开**（缺 HalfArgsAndReturns）。AArch64 同为三开（AArch64.cpp:150-152）。后果：NVPTX 上 `_Float16/__fp16` 是合法存储/运算类型，但**半精度按值传参/返回不采用原生 half ABI**（走提升路径）。另：`__bf16` 为 load/store only（NVPTX.cpp:61-62），`hasBFloat16Type()=true`（NVPTX.h:204）。

### 动态验证

`_Float16 h = 1.0f16f; __fp16 g = h;`（device-only，sm_52 默认）→ RC=0 clean，`HasFloat16=true` 生效。（半精度传参 ABI 的负向差异未单独实测，标注为静态结论。）

### 设计动机

PTX 从 2.x 起有原生 f16 算术，但**函数参数按 half 直传**并非 PTX ABI 惯例（device 函数经 inlining 消失，param 空间按字宽对齐），所以 HalfArgsAndReturns 留空；AMDGPU 的 kernel 参数布局原生支持 16 位槽位故三开。

### 昇腾映射（推理级，待验证）

昇腾 AICore 的 fp16 是一等公民（算力主型），对应"HasFloat16/HasFastHalfType 全开"；CCE 中 half 传参走矢量/tensor 语义而非标量 ABI，与 NVPTX 的"类型可用但传参不原生"策略类似。**待验证**：CCE 的 `half` 参数是否直接进 kernel param 表。

---

## 6. 动态验证汇总（-march 坑的 TargetInfo 层根源）

### 实验矩阵（clang-24 @ 3eda2aebadd4，build-debug）

| # | 命令要点 | 关键结果 |
|---|---|---|
| 1 | `--cuda-device-only --cuda-gpu-arch=sm_70 -dM -E` | `__CUDA_ARCH__=700`、`__CUDA_ARCH_LIST__=700`、`__PTX__`、`__NVPTX__`（共 449 宏） |
| 1b | `-cc1 -fcuda-is-device -target-cpu sm_70 -dM` | `__CUDA_ARCH__=700`；**无** `__CUDA_ARCH_LIST__`（driver -D 专属） |
| 2 | `--cuda-gpu-arch=sm_90` 同上 | 与 sm_70 的宏全集 diff **仅 2 项**：`__CUDA_ARCH__`/`__CUDA_ARCH_LIST__` 700↔900 |
| 2b | `--cuda-gpu-arch=sm_90a` | 额外 `__CUDA_ARCH_SPECIFIC__=900`、`__CUDA_ARCH_FEAT_SM90_ALL=1`、`__CUDA_ARCH_FAMILY_SPECIFIC__=900` |
| 3a | `-march=sm_70`（driver） | `__CUDA_ARCH__=520`、`__CUDA_ARCH_LIST__=520`（= 默认 sm_52！） |
| 3b | `-march=sm_90`（driver） | **与 3a 完全相同**——-march 被整体无视 |
| 3c | `-march=sm_70 -###` | 铁证：cc1 参数含 `"-aux-target-cpu" "sm_70"` 但 `"-target-cpu" "sm_52"`、`"-D__CUDA_ARCH_LIST__=520"`；ptxas `--gpu-name sm_52` |

### -march 不传播的 TargetInfo 层根源

值链拆解：

1. `__CUDA_ARCH__` 的值 = `CudaArchToID(GPU)`（NVPTX.cpp:196-197），`GPU` 成员**只**由 `setCPU`（NVPTX.h:146-149）赋值；
2. `setCPU` 的输入是 cc1 的 **`-target-cpu`**；
3. `-march=sm_70` 被 driver 翻译为 **`-aux-target-cpu`**（实测 -###），设置的是 **aux** TargetInfo 的 CPU；而 device-only 时 aux-triple 就是 nvptx64 自身（实测 `-aux-triple nvptx64-nvidia-cuda`），NVPTX.cpp:84 `if (!HostTriple.isNVPTX())` 使 HostTarget 根本不创建——aux CPU 设置**无处落地**；
4. 主 TargetInfo 的 `-target-cpu` 仍是 CUDA 工具链默认 sm_52 → `GPU=sm_52` → `__CUDA_ARCH__=520`。

即：**-march 在主 TargetInfo 的 setCPU/getTargetDefines 路径上完全不可见**。正确通道是 `--cuda-gpu-arch=sm_70`（driver 同时生成 `-target-cpu sm_70` 与 `-D__CUDA_ARCH_LIST__=700`，实测对照 1/3a）。

---

## 7. 昇腾映射总表（推理级，均待验证）

| CUDA/Clang 机制 | 昇腾 CCE 疑似对应 | 对照要点 |
|---|---|---|
| `__CUDA_ARCH__=sm*10`（TargetInfo getTargetDefines，NVPTX.cpp:196-197） | `__CCE_AICORE__`（数值按芯片型号编码）+ `__CCE_AIVECTOR__` 等 | 注入层级待验证：编译驱动 -D 还是编译器内建 defines；是否区分 arch-specific/family-specific 两级（对照 sm_90a 的 SPECIFIC/FAMILY 宏先例） |
| `__CUDA_ARCH_LIST__`（driver 汇总 -D） | 未知 | 多芯片联合编译场景昇腾是否存在等价"全集宏" |
| libdevice 后端 reflect 通道 | tilib/cce intrinsic 库 | 若为预编译形态需要 reflect 等价物；纯源码则单宏通道足够 |
| LangASMap 统一 AS 命名空间 | `__gm/__dm/__local` 限定符体系 | 是否有"语言 AS→目标 AS"声明式单表 |
| checkCallingConvention 白名单（仅 CC_DeviceKernel） | kernel 入口标记（`__aicore__`/pragma） | 是否有前端 CC 校验点 |
| HostTarget 类型布局委托 | host/device 结构体布局一致性 | 昇腾单设备模型下需求弱化 |

---

## 引用清单

### 静态（均已 grep/read 核对）

- clang/lib/Basic/Targets/NVPTX.h：:27-45（NVPTXAddrSpaceMap）、:49-55（DWARF 表）、:57-207（类）、:59-61（成员）、:74-85（initFeatureMap）、:91-103（isAddressSpaceSupersetOf）、:112-127（asm 约束）、:134-136（va_list）、:138-149（CPU 校验/setCPU）、:151-173（OpenCL opts）、:146-149（setCPU）、:185-191（DWARF AS）、:193-201（checkCallingConvention）、:203-206（BitInt/BF16/getGPU）
- clang/lib/Basic/Targets/NVPTX.cpp：:38-165（构造函数）、:47-54（PTXVersion）、:56-62、:71-73（ReadOnlyFeatures）、:75-77（half）、:79（DataLayout）、:83-85（HostTarget 创建）、:88-108（无 host 分支）、:110-164（属性拷贝+注释）、:167-173（setABI）、:179-183（hasFeature）、:185-207（getTargetDefines）
- clang/lib/Basic/Targets/Targets.cpp：:430-435（单类双实例化）
- clang/lib/Basic/Cuda.cpp：:133-136（CudaArchToID）、:138-139（IsNVIDIAAcceleratedOffloadArch）
- llvm/include/llvm/TargetParser/NVPTXTargetParser.def：:14-17（SM_ID 语义注释）、:42（sm_70）、:50-51（sm_90/sm_90a）
- clang/lib/Frontend/InitPreprocessor.cpp：:1492-1497（CUDAIsDevice 兜底定义）
- clang/lib/Frontend/CompilerInvocation.cpp：:5167-5172（HostTriple←AuxTriple，CUDA）、:5179-5180（OpenMP）、:5183-5187（SYCL）
- clang/lib/Driver/ToolChains/Clang.cpp：:1078-1097（__CUDA_ARCH_LIST__ 注入）
- clang/lib/Basic/Targets/AMDGPU.cpp：:31-63（AMDGPUAddrSpaceMap）、:215-218、:245（half 三开）
- clang/lib/Basic/Targets/X86.h：:380-401（X86TargetInfo CC 表）、:673（MCU 重写）、:753（X86_64TargetInfo 重写，行号确认存在）、:910-931（WindowsX86_64 表）
- clang/include/clang/Basic/TargetInfo.h：:240、:708（HalfArgsAndReturns）、:1770-1787（CCCR 枚举 + 默认 CC_C-only）
- clang/include/clang/Basic/Specifiers.h：:292（CC_DeviceKernel）
- clang/include/clang/Basic/Attr.td：:495（TargetNVPTX）、:1558-1563（CUDADevice）、:1592-1598（CUDAGlobal）、:1671-1695（DeviceKernel 拼写表 + isNVPTXSpelling）
- clang/include/clang/Basic/AttrDocs.td：:589-592（DeviceKernel 文档标题）
- clang/lib/Sema/SemaDeclAttr.cpp：:5930-6004（CUDA host/device CC 双查 + CCCR_Ignore→CC_C）
- clang/lib/CodeGen/TargetInfo.cpp：:115-126（默认 getDeviceKernelCallingConv）
- clang/lib/CodeGen/Targets/NVPTX.cpp：:86-88（PTX_Kernel）、:272（setCallingConv）
- clang/test/CodeGen/nvptx_attributes.c：:14（nvptx_kernel 用例）

### 动态（clang-24 @ 3eda2aebadd4, build-debug）

- 宏导出/对照/陷阱：§6 实验矩阵 1、1b、2、2b、3a-3c（scratch/ 下 m70.txt、m90.txt、m70_cc1.txt、march70/90.txt、t.cu 可复查）
- checkCallingConvention：§4 实测表（cc.cu、dk.cu、kern.cu）
- 半精度：half.cu clean
