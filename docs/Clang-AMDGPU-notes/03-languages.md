# Clang-AMDGPU 深度分析 — §3 语言路径：OpenCL C vs HIP C++

日期：2026-09-29。基准：llvm-project main @ `3eda2aebadd4`，clang-24 @ build-debug。
铁律遵守：本文所有 文件:行号 引用均经 grep/read 核对；昇腾部分为推理级，已标“待验证”。

## 3.0 总览：两条路径的本质差异

- **OpenCL C 是“另一种语言”**：`LangOpts.OpenCL` 独立开关，有自己的 Sema（SemaOpenCL.cpp、OpenCLBuiltins.td 2354 行 → 生成 17264 行 OpenCLBuiltins.inc）和 18k 行声明头 opencl-c.h。但 CodeGen 侧极薄：lib/CodeGen 下 OpenCL 相关文件只有 CGOpenCLRuntime.cpp/.h 两个（159+102 行），**无任何 target 子类**。
- **HIP 是“同一种语言”**：`LangOpts.CUDA` + CUDAIsDevice 复用整套 CUDA C++ 前端（HIP.cpp 已不存在，见基线）。HIP 的“语言实现”= CUDA 前端机 + 一组头文件（`__clang_hip_*` 5 个 + `__clang_gpu_*` 4 个，共 3365 行）+ amdgcn 目标。
- 结论先行：**OpenCL 薄在 CodeGen、厚在 Sema/头文件；HIP 薄到零 CodeGen 专属文件，全部厚度在头文件与 Driver 组织**。两者最终汇合于同一 `amdgpu_kernel` CC 与同一设备库（ocml/ockl）。

## 3.1 OpenCL C 路径

### 3.1.1 静态分析：CGOpenCLRuntime 为何只有 159 行

论点验证：**成立，且比预期更彻底**。159 行逐段拆解（clang/lib/CodeGen/CGOpenCLRuntime.cpp）：

| 行号 | 内容 | 说明 |
|---|---|---|
| 28-31 | `EmitWorkGroupLocalVarDecl` | 仅转调 `CGF.EmitStaticVarDecl(..., InternalLinkage)`——program-scope 变量→internal 链接 |
| 33-44 | `convertOpenCLSpecificType` | **先问 target hook** `TargetCodeGenInfo::getOpenCLType`（:37），sampler 走 ：61，其余走指针 |
| 46-50 | `getPointerType` | 通用 `llvm::PointerType::get(Ctx, targetAS)`，AS 来自 `getOpenCLTypeAddrSpace` |
| 52-59 / 61-71 | `getPipeType` / `getSamplerType` | 同样 target-hook-first，回退为指针 |
| 73-91 | `getPipeElemSize/Align` | 管道隐参的 i32 常量 |
| 105-159 | Blocks（enqueued blocks） | CL2.0 device-side enqueue 的 glue（:101 引 OpenCL v2.0 s6.12.5 “块隐式 const”） |

薄的原因（四层分流）：
1. **类型**：OpenCL 专属 builtin 类型只有 image 系/pipe/sampler/event/queue 等少数几种，在 CodeGenTypes.cpp:494-506（`IMAGE_TYPE`/`EXT_OPAQUE_TYPE` .def 展开 + OCLSampler…OCLReserveID）统一转入 `convertOpenCLSpecificType`；Pipe 在 CodeGenTypes.cpp:773。默认翻译就是“正确 AS 的不透明指针”。
2. **函数**：OpenCL 内建函数**不是 clang builtin 指令**，而是 opencl-c.h 里的声明 + OpenCLBuiltins.td 的签名/版本表，CodeGen 发普通库调用（见 3.1.5 动态实证）。需要定制 lowering 的只有管道/enqueue/AS 转换一族，住在通用 CGBuiltin.cpp:6266-6665。
3. **元数据**：五件套生成不在本类，而在 **CodeGenModule::GenKernelArgMetadata**（CodeGenModule.cpp:2980，与 CUDA/HIP 共享调用链，见 3.1.2）。
4. **kernel 性**：OpenCL `__kernel` 与 CUDA `__global__` 在当前 clang 已统一为 `DeviceKernelAttr`/`CUDAGlobalAttr` 双入口，汇合于 `CodeGenFunction::EmitKernelMetadata`（CodeGenFunction.cpp:609-617，:611-612 双属性判断，:617 调 GenKernelArgMetadata）；amdgpu_kernel CC 由目标 ABI 设定（Targets/AMDGPU.cpp:598-601 `withCallingConv(CC_DeviceKernel)`）。

target 差异全部走 `TargetCodeGenInfo::getOpenCLType` 虚钩子（TargetInfo.h:456 声明）：SPIR/SPIR-V 有完整实现（SPIR.cpp:648-674），**AMDGPUTargetCodeGenInfo 未覆写**（grep 无匹配）→ 裸 amdgcn OpenCL 下 image/sampler 回退为 opaque 指针（生产 OpenCL-on-AMD 走 SPIR-V 路径）。

### 3.1.2 元数据五件套生成点

- **主生成点**：CodeGenModule.cpp:2980 `GenKernelArgMetadata`；五条 `Fn->setMetadata` 在 :3108（addr_space）、:3110（access_qual）、:3112（type）、:3114（base_type）、:3116（type_qual）；`kernel_arg_name` 在其后，门控 `EmitOpenCLArgMetadata || HIPSaveKernelArgName`（**HIP 也复用此机制存 kernel 参数名**）。
- **AS 编码**：CodeGenModule.cpp:2953-2970 `ArgInfoAddressSpace`——**固定用 SPIR 2.0 规范 ID**（注释明言是为 clGetKernelArgInfo 在“无唯一 AS 映射的目标（所有单 AS CPU）”上可区分）：global=1, constant=2, local=3, generic=4（注释"Not in SPIR 2.0 specs"）, global_device=5, global_host=6, 默认 0=private。
- **调用链**：CodeGenFunction.cpp:617（正常 kernel）；CGDeclCXX.cpp:812、:973（device 侧全局变量初始化 kernel，FD/CGF 为 null 的形态）。
- **第二生成点（enqueued block kernel）**：Targets/AMDGPU.cpp:623 `AMDGPUTargetCodeGenInfo::createEnqueuedBlockKernel` 手工构造五件套（:693-698 同名 setMetadata；块字面量参数 type 名 `"__block_literal"`、AS=0，后续参数 AS=3 即 local）；kernel 为 InternalLinkage + `getDeviceKernelCallingConv()`（:667-668 一带）；runtime handle 结构 `{ptr addrspace(1) kernel_object, i32 private_segment_size, i32 group_segment_size}`（:609-618 `getAMDGPURuntimeHandleType`，注释指明给 rocm-device-libs 的 device enqueue 用）。
- **契约稳定性旁证**：CIR 侧独立重实现同一五件套（clang/lib/CIR/Lowering/DirectToLLVM/LowerToLLVMOpenCLMetadata.cpp:116-127）——这是跨前端的行为契约而非内部实现细节。

### 3.1.3 ImageTypes / Pipes / Blocks 的 codegen 差异

- **Images**（SPIR-V 路径）：SPIR.cpp:648 起的 `getOpenCLType` 把 `IMAGE_TYPE.def` 全系翻成 `TargetExtType "spirv.Image"`，整数参数编码维度/深度/数组/MSAA（SPIR.cpp:620-641：image2d→Dim=1、image3d→2、image1d_buffer→5；`_depth`→[1]=1、`_array`→[2]=1、`_msaa`→[3]=1）+ access qualifier（AQ_ro/wo/rw 由 .def 后缀给出）。sampler→`spirv.Sampler`、event→`spirv.Event`、clk_event→`spirv.DeviceEvent`、queue→`spirv.Queue`、reserve_id→`spirv.ReserveId`、Intel AVC→`spirv.Avc*INTEL`（SPIR.cpp:658-667）。**image 的 access qualifier 与类型不可分**（CodeGenModule.cpp 里专门有 `removeImageAccessQualifier` 把 `__read_only` 等从 type 名中剥出，:2941-2961 一带，注释解释是因 clang 类型黏合而 spec 要求单独查询）。
- **Pipes**：SPIR.cpp:649-651 `TargetExtType "spirv.Pipe"`，参数 `{!isReadOnly}`；amdgcn 直连则退化为指针（CGOpenCLRuntime.cpp:52-59）。管道**读写操作**在 CGBuiltin.cpp:6266+ 生成 `__read_pipe_2`/`__write_pipe_2` 运行时调用，元素 size/align 作为尾随 i32 隐参（:6272-6289）；reserve/commit/query 同构（:6313、:6354、:6390）。
- **Blocks**（CL2.0 独有）：CGBuiltin.cpp:6440+ 的 `enqueue_kernel` 走 `CGOpenCLRuntime::emitOpenCLEnqueuedBlock`（CGOpenCLRuntime.cpp:136-159）→ `createEnqueuedBlockKernel`：块字面量**按值**作为 kernel 第一参数（struct 类型非指针），kernel 内 alloca+store 后调 invoke 函数（Targets/AMDGPU.cpp:640-660 一带）；kernel query 函数族在 :6626-6665。

### 3.1.4 -cl-std 版本门控（CL1.2 / 2.0 / 3.0）

- **Driver**：`-cl-std=` 透传 cc1（Clang.cpp:3934）。
- **双层门控**：
  - 头文件层：opencl-c.h:12401 `#if defined(__OPENCL_CPP_VERSION__) || (__OPENCL_C_VERSION__ >= CL_VERSION_2_0)` 包住 `work_group_barrier` 声明（:12402-12403）；`barrier`（:12399）无条件声明。
  - Builtin 表层：OpenCLBuiltins.td:942-946——`barrier`（:943）无条件；`work_group_barrier` 双签名 `let MinVersion = CL20 in`（:944-946）。**CL3.0 的“核心回退到 1.2 + 可选特性扩展化”模型**由同表的 `FunctionExtension` 机制承担（:50-51 定义；例 ：936-938 `FuncExtOpenCLCGenericAddressSpace` 门控 generic-AS vload），即 MinVersion 管“版本内核心”，Extension 管 `__opencl_c_*` 风格可选特性。
- **Sema 散点检查**：如 SemaExpr.cpp:14187、:16595 的 `OpenCLVersion < 120` 比较。
- **CodeGen 侧消费**：CodeGenModule.cpp:1855、:2063 用 `getOpenCLCompatibleVersion()`。
- 表规模：OpenCLBuiltins.td 2354 行 → build-debug/tools/clang/lib/Sema/OpenCLBuiltins.inc 17264 行（`barrier`=1444 号、`work_group_barrier`=1445 号 builtin）。

### 3.1.5 动态验证（build-debug/bin/clang-24，gfx1100）

```bash
# 用例：kernel void k(global int* p) { barrier(CLK_GLOBAL_MEM_FENCE); work_group_barrier(...); }
# 默认 std（CL1.2）：
#   error: use of undeclared identifier 'work_group_barrier'   ← 版本门控实证
# -cl-std=CL2.0：编译通过，IR：
#   define protected amdgpu_kernel void @k(ptr addrspace(1) ...) ... 五件套元数据
#   tail call void @_Z7barrierj(i32 noundef 2)                  ← 库调用而非指令！
#   tail call void @_Z18work_group_barrierj12memory_scope(i32 noundef 2, i32 noundef 2)
#   declare hidden void @_Z7barrierj(i32 noundef) ... { convergent nounwind ... }
```

**关键发现**：OpenCL 同步原语 `barrier` 在 clang 侧**不 lower 成任何指令**，是 Itanium 名修饰的外部设备库调用，由 rocm-device-libs 在链接期解析（`-nogpulib` 下只剩 declare）。这直接支撑“OpenCL 薄层”论：内建函数=声明+库调用，clang 只保证 `convergent` 等正确属性。

### 3.1.6 设计动机

元数据五件套服务的是**运行时反射 API（clGetKernelArgInfo）**而非代码生成——所以它以字符串/MDNode 形式挂在函数上、AS 用 SPIR 规范 ID 与目标解耦。OpenCL 把“语言语义”压进 Sema 表与声明头，让 CodeGen 保持通用 C 水平，代价是内建函数离 ISA 一层库调用。

### 3.1.7 昇腾映射（推理，待验证）

昇腾若走“OpenCL 方言”路线，对应物应为：Sema 表门控（版本/扩展）+ 声明头 + 库调用 + 反射元数据。判据：**当语义可表达为“声明+库+少量类型翻译”时薄层成本极低**（159 行级别）。

## 3.2 HIP C++ 路径

### 3.2.1 静态分析：wrapper 架构与双编译组织

**传统 ROCm 路径**（`__clang_hip_runtime_wrapper.h`，153 行）：
- 自述“由编译器直接 -include，用户不应包含”（:10-14）。
- **整个 HIP 执行模型词汇表 = 6 个属性宏**（:21-26）：`__host__→__attribute__((host))`、`__device__`、`__global__`、`__shared__`、`__constant__`、`__managed__`；加 `__cluster_dims__`/`__no_cluster__`（:28-29）。
- **device malloc 三级策略**（:47-90）：HIP≥4.5 → `__ockl_dm_alloc/__ockl_dm_dealloc`（走 OCKL）；ASAN 时改 `__asan_malloc_impl` 并传 `__builtin_return_address(0)` 作 PC（:50-62）；旧版 `__HIP_ENABLE_DEVICE_MALLOC__` → `__hip_malloc`；否则 `__builtin_trap()` 存根。全部 `weak inline`。
- **include 顺序即语义**（:96-108）：`__clang_cuda_math_forward_declares.h` 必须在 `<cmath>` 之前——注释（:97-101）解释：否则 `<cmath>` 的 constexpr 函数会被隐式 `__host__ __device__`，先声明 `__device__` 版才能重载（仅系统头允许）。这是 HIP 复用 CUDA 头的直接证据。
- 收尾拉入 `__clang_hip_libdevice_declares.h`/`__clang_hip_math.h`/`__clang_hip_stdlib.h`（:129-131）与 `__clang_hip_cmath.h`（848 行）+ `__clang_cuda_complex_builtins.h` + `<algorithm>/<complex>/<new>`（:133-141）。
- **hipRTC 分支**（:110-127, :144-151）：无标准头，`typedef __SIZE_TYPE__ size_t` + push/pop 宏（NULL/uint32_t/…）保证 API 声明可写。
- **挂载点**：Driver 在 `RocmInstallationDetector::AddHIPIncludeArgs` 注入 `-include __clang_hip_runtime_wrapper.h`（ToolChains/AMDGPU.cpp:625-626），条件 `VersionMajorMinor > 3.5 && !-nohipwrapperinc`（:533）；无 ROCm 时 `err_drv_no_hip_runtime`（:619-622）。
- **host stub / device real**：双编译由 Driver 的 offload 组织（device cc1 triple=amdgcn-amd-amdhsa，host cc1 本机）；wrapper 头 host/device 两侧都被 include，`__device__` 函数在 host pass 被解析但由 CUDA 前端机制跳过 emit（与 NVPTX-notes §2 的 CUDA 双编译同构，此处不重复展开；kernel 的 host stub/注册属 CGCUDANV，本节未核对，引 NVPTX-notes）。

**Hermetic GPUOffload 路径**（新）：
- `__clang_gpu_runtime_wrapper.h`（28 行，自称 "Hermetic HIP/CUDA bootstrap"，方言中立）：`#if defined(__HIP__) || defined(__CUDA__)`（:16）下仅定义那 6 个属性宏（:18-25）。
- `hip_wrappers/hip/hip_runtime.h`（"Hermetic HIP runtime shadow"）：先含 gpu wrapper，再 `include_next <hip/hip_runtime.h>`（有真实 ROCm 头则叠加），然后拉入 `__clang_gpu_builtin_vars.h`/`__clang_gpu_device_functions.h`/`__clang_gpu_intrinsics.h`。
- **激活条件**：triple environment == `llvm::Triple::LLVM`（AMDGPUToolChain::AddHIPIncludeArgs，AMDGPU.cpp:1324-1331，:1330 拼 `ResourceDir/include/hip_wrappers`）；同 triple 判断还见 ：744、:990、:1198。传统路径在 `-foffload-via-llvm` 下直接 early-return（:535-537），即两模型互斥。

### 3.2.2 类型系统：vector_type / half2 无专属 codegen

- `half2` 就是 `typedef _Float16 __2f16 __attribute__((ext_vector_type(2)))`（`__clang_hip_libdevice_declares.h:214-215`，另有 `__2i16`）→ 走通用 ext_vector_type 机制 → `<2 x half>`。
- `hip::vector_type` 模板在 ROCm 的 `hip/hip_vector_types.h`，**不在 clang 树内**（grep clang/lib/Headers 无定义）。即 HIP 类型层 0 行专属 CodeGen，全部复用 Clang 通用向量/OpenCL 风格属性。

### 3.2.3 `__device__`/`__host__` 宏的语义

- 宏层面只是 6 个 attribute（3.2.1）；语义重量在 CUDA 前端机：模板/系统头的隐式 `__host__ __device__`（wrapper :97-101 的顺序 hack 即为其后果）、host/device 重载解析。CodeGen 侧消费点：`ASTContext::mayExternalize/shouldExternalize`（ASTContext.cpp:15509-15523 / :15527-15531）——内部链接变量带显式 `__device__`/`__constant__` 或 `HIPManagedAttr`、匿名命名空间 kernel 等“需外部化”判定，直接服务 -fgpu-rdc（见 3.2.4）。

### 3.2.4 -fgpu-rdc 的 codegen 差异

- **名字不可缓存**：`getMangledName` 在 CUDA device 编译且 `mayExternalize` 时绕过 mangling 缓存——因 static device 变量的 mangled 名取决于被 host 还是 device 引用（CodeGenModule.cpp:2682-2687）。
- **链接范式切换**：`!GPURelocatableDeviceCode` 时 device 端 strong-ODR 模板实体 InternalLinkage（kernel 除外），“单 TU 限制换取激进 IPO”；RDC 下回正常 WeakODR（CodeGenModule.cpp:6973-6981，注释明言）。Driver 侧 `-fgpu-rdc` 透传见 Clang.cpp:7433（上下文未细核）。
- **LTO 联动**：amdgcn + offloadDeviceOnly + 无 rdc + 无 `-foffload-lto` → `LTOK_None`（AMDGPU.cpp:1344-1355）。

### 3.2.5 动态验证（HIP 探测——被阻塞，按预案记录）

```bash
$ clang-24 --target=amdgcn-amd-amdhsa -x hip -mcpu=gfx1100 -nogpulib -S -emit-llvm /tmp/hello.hip
clang-24: error: cannot find HIP runtime; provide its path via '--rocm-path',
or pass '-nogpuinc' to build without HIP runtime
```

本机无 /opt/rocm，hip 头缺失 → HIP 动态验证**未完成**，本节以静态分析为主。遗留实验（后续可用）：`-nogpuinc` + 手动 `-include __clang_hip_runtime_wrapper.h`（该头在 ResourceDir，属 builtin 头），可绕过 ROCm 探测测 `__expf`→`__builtin_amdgcn_exp2f` 的实际 IR。

### 3.2.6 设计动机 / 昇腾映射

HIP 的选择是“零前端增量”：借 CUDA 双编译机换 CUDA 生态兼容，语言厚度全部转移到头文件与 Driver。代价是 CUDA 包袱（见 3.4）。昇腾映射（待验证）：AscendC 若为纯“C++ + 领域类型/属性 + 头文件”即此模式；若涉及 tiling 进类型系统，则超出该模式能表达的范畴。

## 3.3 `__clang_hip_math.h` 1405 行精读

- **服务对象**：`#if !defined(__HIP__) && !defined(__OPENMP_AMDGCN__)` 即 error（:12-14）——HIP 与 OpenMP-offload-amdgcn 共用。
- **静态分发机制 = 预处理器，不是 constexpr if**：
  - `__DEVICE__` 宏（:30-34）：HIP 形态 `static __device__ inline __attribute__((always_inline))`；OpenMP 形态 `static inline always_inline nothrow`。
  - **`__FAST_OR_SLOW(fast, slow)`**（:43-48）：由 `__CLANG_GPU_APPROX_TRANSCENDENTALS__` 选择（注释 ：39-42：clang 在 `-ffast-math` 或 `-fgpu-approx-transcendentals` 时定义）。例：`cosf → __FAST_OR_SLOW(__cosf, __ocml_cos_f32)`（:365）。
  - `OCML_BASIC_ROUNDED_OPERATIONS` #if（如 ：176-190）：舍入运算族在 `__ocml_add_rtn_f32` 等与普通运算符间二选一。
  - 逃生口 `__CLANG_GPU_DISABLE_MATH_WRAPPERS`（:16-18，注释：让标准 libcalls 活到链接期而非被急切替换）。
- **“inline PTX vs libdevice”的 AMDGCN 对应物**：没有 PTX，对应 **`__builtin_amdgcn_*`（内联 ISA）vs `__ocml_*`（设备库调用）**。三层典型：
  1. CUDA 风格 intrinsic → 直接 builtin：`__expf → __builtin_amdgcn_exp2f(log2e*x)`（:165-169）、`__frsqrt_rn → __builtin_amdgcn_rsqf`（:260）、`__fsqrt_rn`(fast) → `__ocml_native_sqrt_f32`（:272）。
  2. CUDA intrinsic → ocml：`__cosf → __ocml_native_cos_f32`（:161）、`__sinf`/`sincosf` native（:306-311）。
  3. C 标准名 → 恒 ocml 精确版：`acosf→__ocml_acos_f32`（:335）等全表；double 段同构（`__fma_rn → __ocml_fma_rte_f64` / `__builtin_fma`，:1250-1275 一带）。
  - `__ocml_*` 共 173 个 `__device__` extern 声明集中在 `__clang_hip_libdevice_declares.h`（238 行），带 `const/pure` 属性标注；指针参数用 `__PRIVATE_AS = __attribute__((opencl_private))`（hip_math.h:36-38）——**HIP 数学头反向借用 OpenCL 的 AS 属性**来给 libdevice 指针参数定 AS。
- **与 CUDA 的共享层**：**不存在 `__clang_gpu_math`**（grep 无）。共享是三种形态：(a) 本头经 `__DEVICE__` 同时服务 HIP/OpenMP；(b) HIP wrapper 直接复用 CUDA 的 `__clang_cuda_math_forward_declares.h`/`__clang_cuda_complex_builtins.h`（wrapper :102/:137）；(c) hermetic 层 `__clang_gpu_device_functions.h`（358 行，:16 `__HIP__||__CUDA__` 双开）把 CUDA 位运算 intrinsic 映射到**通用 builtin**：`__popc→__builtin_popcountg`（:21-23）、`__clz→__builtin_clzg(x,32)`（:29-32）、`__ffs→__builtin_ctzg+1`（:38-44）。
- **命名空间组织**：**完全没有 namespace**（grep 计数 0），全部全局 C 风格。C++ 的 `min/max` 是全局命名空间模板+重载（:1286-1310，`min(float,float)→__builtin_fminf`），host 侧 min/max 由 `__HIP_NO_HOST_MIN_MAX_IN_GLOBAL_NAMESPACE__`/`__HIP_DEFINE_EXTENDED_HOST_MIN_MAX__`（默认 0）/`__HIP_DEFINE_MIXED_HOST_MIN_MAX__`（默认 0，注释明言 "for compatibility with CUDA" 才开）三宏控制（:1312-1395）——CUDA 兼容包袱的直接文本证据。C 模式另有 C11 `_Generic` 的 isfinite/isinf/isnan/signbit（:1278-1284）与 pre-C++11 static_assert 模拟（:62-85）、strtod 尾数解析辅助（:87-154）。

## 3.4 两语言对照表：同一硬件、两种语法糖

| 概念 | OpenCL C | HIP C++ | clang 侧落点 |
|---|---|---|---|
| 全局内存 AS | `__global`，进类型系统（LangAS::opencl_global→IR AS1，datalayout p1:64） | 无类型级 AS，裸指针=flat/generic | OpenCL 贴内存模型；HIP 靠 flat 寻址+后端推断 |
| 常量/局部 | `__constant`/`__local`（AS4/AS3） | `__constant__`/`__shared__` **变量属性**，非类型 AS | 同一 LangAS/属性两套皮肤 |
| kernel | `__kernel void`（DeviceKernelAttr） | `__global__ void`（CUDAGlobalAttr） | 汇合 CodeGenFunction.cpp:609-617 → `amdgpu_kernel` CC |
| workgroup 同步 | `barrier(CLK_GLOBAL_MEM_FENCE)` → **库调用 `_Z7barrierj`**（动态实证） | `__syncthreads()` → hermetic 层 `__gpu_sync_threads` → **内联** `__builtin_amdgcn_s_barrier` + `__builtin_amdgcn_fence(seq_cst,"workgroup")`（amdgpuintrin.h:120-124） | 讽刺点：薄层 OpenCL 反而隔一层库 |
| lane 同步 | `sub_group_barrier`（OpenCLBuiltins.td:1737-1739） | `__gpu_sync_lane` → `__builtin_amdgcn_wave_barrier`（amdgpuintrin.h:126-128） | |
| 数学 | `mix`/`fmin` 等：声明即库调用 | `min(float,float)→__builtin_fminf`（hip_math.h:1296-1307）、`__expf→__builtin_amdgcn_exp2f`（:165-169） | HIP intrinsic 层直译 ISA |
| 版本门控 | `-cl-std` + MinVersion/Extension 双机制 | CUDA 宏 + `HIP_VERSION_MAJOR*100+MINOR >= 405`（wrapper :47） | 同为预处理门控 |
| 专属类型 | image/sampler/pipe→TargetExtType(SPIR-V)/opaque ptr | half2=ext_vector_type(_Float16)（libdevice_declares:214） | 都复用通用机制，0 专属 CodeGen |
| 数学头组织 | opencl-c.h 声明（≈18k 行） | `__clang_hip_math.h` **定义**（1405 行 inline 实现） | OpenCL“声明+库”；HIP“宏分发+三层实现” |

**哪条更贴硬件？分层答案**：内存模型层面 OpenCL 更贴（AS 类型化直达 datalayout）；指令层面 HIP 的 intrinsic 路径更贴（builtin_amdgcn_* 直选指令），OpenCL 内建反而是库调用。**HIP 的 CUDA 兼容包袱**证据：全局命名空间 min/max 三宏开关（“for compatibility with CUDA”）、复用 `__clang_cuda_*` 头、`__syncthreads`/`__popc` 等 CUDA 名词全保留。两路径底层共享：BuiltinsAMDGPU.td（:152 `__builtin_amdgcn_s_barrier` 等）+ ocml/ockl 设备库——**语言差异在到达 LLVM IR 前已基本消解**。

## 3.5 动态验证汇总

| 项 | 结果 |
|---|---|
| OpenCL barrier 默认 std | ❌ `work_group_barrier` 未声明（CL1.2 门控实证） |
| OpenCL -cl-std=CL2.0 | ✅ `barrier`+`work_group_barrier` 均编译；IR 为库调用 `_Z7barrierj`/`_Z18work_group_barrierj12memory_scope`（convergent，hidden declare） |
| OpenCL kernel IR | ✅ `define protected amdgpu_kernel void @k(ptr addrspace(1)…)` + 五件套元数据（基线复认） |
| HIP 最小用例 | ❌ 阻塞：`cannot find HIP runtime; … --rocm-path … or -nogpuinc`（无 /opt/rocm）→ 转静态，遗留 `-nogpuinc + 手动 -include` 实验 |

## 3.6 昇腾映射（推理级，待验证）

- **昇腾双语言对照结构**（待验证）：OpenCL 方言 ≈ 本节 OpenCL 路径（薄语言+库+反射元数据）；AscendC/Kernel DSL ≈ HIP 路径的变体——同以 C++ 为载体，但方向相反：HIP 是“借 CUDA 语法、藏硬件细节（flat 指针）”，AscendC 是“造领域类型、暴露硬件结构（Local/Global Tensor、显式 tiling）”——后者更接近 OpenCL“AS 进类型系统”哲学的强化版。
- **clang 证据给出的选型判据**：语义可分解为 (a) 类型→现有 IR 类型、(b) 函数→库调用/通用 builtin、(c) 门控→宏 时，薄层（159 行级）够用；需要跨 host/device 双编译、隐式属性传播、模板双端实例化时，必须复用整套前端语义机（CUDA/HIP 模式）。昇腾 tiling 若只到“属性+头文件”深度可走薄层；若要进类型系统（编译期形状检查），则超出 HIP 模式而需 OpenCL 式的 Sema 级支持——这是两条 clang 路径对昇腾最有参考价值的分界线。

## 引用清单（全部经核对）

- clang/lib/CodeGen/CGOpenCLRuntime.cpp（159 行）：28-31, 33-44(37), 46-50, 52-59, 61-71, 73-91, 93-98, 101-115, 119-130, 136-159
- clang/lib/CodeGen/CodeGenModule.cpp：2941-2961(removeImageAccessQualifier), 2953-2970(ArgInfoAddressSpace), 2980(GenKernelArgMetadata), 3108-3120(setMetadata×6), 1855/2063(getOpenCLCompatibleVersion), 2682-2687, 6973-6981
- clang/lib/CodeGen/CodeGenFunction.cpp：609-622(EmitKernelMetadata)
- clang/lib/CodeGen/CGDeclCXX.cpp：812, 973
- clang/lib/CodeGen/CodeGenTypes.cpp：494-506(506), 773
- clang/lib/CodeGen/CGBuiltin.cpp：6266-6290, 6313, 6354, 6390, 6414, 6440-6665
- clang/lib/CodeGen/Targets/AMDGPU.cpp：598-601, 609-618, 623-698(693-698)
- clang/lib/CodeGen/Targets/SPIR.cpp：620-641, 648-674
- clang/lib/CodeGen/TargetInfo.h：456(getOpenCLType 钩子)
- clang/lib/CIR/Lowering/DirectToLLVM/LowerToLLVMOpenCLMetadata.cpp：116-127
- clang/lib/Sema/OpenCLBuiltins.td（2354 行）：50-51, 318, 936-938, 942-946, 1737-1739, 1900, 2290-2295
- build-debug/tools/clang/lib/Sema/OpenCLBuiltins.inc（17264 行）：barrier=1444 / work_group_barrier=1445
- clang/lib/Sema/SemaExpr.cpp：14187, 16595；clang/lib/Driver/ToolChains/Clang.cpp：3934(-cl-std), 7433(-fgpu-rdc, 上下文未细核)
- clang/lib/Headers/opencl-c.h：12399-12403；opencl-c-base.h：296
- clang/lib/Headers/__clang_hip_runtime_wrapper.h（153 行）：10-14, 21-29, 47-90, 96-141, 144-151
- clang/lib/Headers/__clang_gpu_runtime_wrapper.h（28 行）：16-25
- clang/lib/Headers/hip_wrappers/hip/hip_runtime.h（全文已读，19 行）
- clang/lib/Headers/__clang_hip_math.h（1405 行）：12-14, 16-18, 30-48, 50-85, 87-154, 161, 165-190, 260, 272, 306-311, 335, 365, 1250-1275, 1278-1284, 1286-1395, 1397-1404
- clang/lib/Headers/__clang_hip_libdevice_declares.h（238 行，173 个 __device__ 声明）：214-215
- clang/lib/Headers/__clang_gpu_device_functions.h（358 行）：16-44
- clang/lib/Headers/gpuintrin.h（348 行）：49；amdgpuintrin.h：112-128
- clang/lib/Driver/ToolChains/AMDGPU.cpp：533, 535-537, 619-626, 744, 990, 1198, 1324-1331(1330), 1344-1355
- clang/lib/AST/ASTContext.cpp：13187, 15509-15531
- clang/include/clang/Basic/BuiltinsAMDGPU.td：152
- 动态验证产物：/tmp/barr.cl、/tmp/barr.ll、/tmp/barr2.ll、/tmp/hello.hip（scratch 级，未入 notes）

---
