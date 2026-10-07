# §4 CUDA 头文件族 10 个深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，clang-24 @ build-debug 实测（--cuda-device-only 绕坑路径）。
> 引用格式 `文件:行号`；实测素材 `Clang-NVPTX-notes/scratch/hdr-test/` + 主会话 asm 直通验证。
> 素材来源：子代理调研（引用已核实，含一个真实边界负结果）+ 主会话补验证代写。
> 防重复：nvptxintrin.h 三重门卫（NVPTX-notes）、hip_math 的 __FAST_OR_SLOW（Clang-AMDGPU-notes/03）。

---

## 4.1 __clang_cuda_runtime_wrapper.h（526 行）组织全景

**include 顺序**：:32 math_forward_declares（必须在 cmath 前）→ :41-45 预吃标准头 → :68 cuda.h（CUDA_VERSION 检查 :69-73）→ :82-84 host pass 伪 `__CUDA_ARCH__=9999` → **:86 builtin_vars** → :95-100 define 掉 SDK 的 `__DEVICE_FUNCTIONS_H__`/`__MATH_FUNCTIONS_H__` 等 4 个 guard → **:124 cuda_runtime.h（SDK 衔接点）** → :164 libdevice_declares → :169-172 device_functions+math（CUDA≥9000）→ :221-225 crt/math_functions.hpp → :376-407 texture → :491-493 **cmath+intrinsics+complex_builtins 三连收尾**。

**衔接机制不是 include_next，而是"宏污染 + 直接 include SDK 头"**：
- 毒化 `__host__`（:197-198）、重定义 `__forceinline__` 加 `__device__`（:204-205）、nv_weak→weak（:119-120）
- 跳过 sm_30/32_intrinsics.h（:321-327 注释：SDK 用 inline volatile asm，**clang 要 builtin 让优化器推理**，__ldg 得 [addr+imm] 寻址）——builtin vs asm 的优化器推理差异的官方理由
- include_next 只用在 **cuda_wrappers/**（包 libstdc++/libc++ 头）：cuda_wrappers/cmath:27-30

**-nocudainc 砍的正是 -include 点**：Cuda.cpp:329-331；Options.td:6624 -nocudainc = no_offload_inc 别名（:6614-6618），Cuda.cpp:326-328 提前 return。cuda_wrappers 的 isystem 归 -nobuiltininc 管（独立）。

## 4.2 __clang_cuda_builtin_vars.h（121 行）：threadIdx 机制三元

**机制**：`__declspec(property(get=...))` 字段（:30-35 宏）+ always_inline device getter + clang builtin——**非 inline asm、非变量实体**。:104-109 四变量仅是 `extern const __device__ __attribute__((weak))` 声明；getter 被 inline 后消失。

| 变量 | builtin | intrinsic | PTX |
|---|---|---|---|
| threadIdx.x | `__nvvm_read_ptx_sreg_tid_x`（:53） | llvm.nvvm.read.ptx.sreg.tid.x | mov.u32 %r, %tid.x |
| blockIdx | ctaid（:66） | …ctaid.x | %ctaid.x |
| blockDim | ntid（:79） | …ntid.x | %ntid.x |
| gridDim | nctaid（:92） | …nctaid.x | %nctaid.x |

文件头注释（:23-28）直书 IR→PTX 全链。builtin→intrinsic **无 CodeGen 特判**（NVPTX.cpp 只特判 SM90 clusterid :1320-1341），走 CGBuiltin.cpp:6887-6890 通用映射；IntrinsicsNVVM.td:2757-2764 定义 sreg 族。:46-50 delete 构造/拷贝/operator&（nvcc 同构禁取地址）；:114 warpSize=32 常量（注释：无 %WARP_SZ builtin）。

**对照 AMDGPU**：get_global_id 是 opencl-c.h 声明→库调用；CUDA 是 property→builtin→intrinsic **全编译期零调用残留**。

**实测**（asm 直通版验证 %tid.x 链终点）：
```bash
$ clang-24 --cuda-device-only ... tid.cu（asm "mov.u32 %0, %%tid.x"）
PTX: mov.u32 %r1, %tid.x;    ✓ 特殊寄存器链终点实证
```

**负结果（真实边界）**：`-nocudainc` + 手动 include builtin_vars.h，报 `reference to __host__ function '__nvvm_read_ptx_sreg_tid_x' in __device__ function`（builtin_vars.h:53）——**SemaCUDA 对 implicit decl 的 HostDevice 豁免在 .cu 显式 getter 路径下失效**（IdentifyTarget :238-243 的 IgnoreImplicitHDAttr 交互，根因未定位，标注）——**builtin_vars.h 不可独立于 wrapper 使用**的实证。

## 4.3 cmath/math 映射表（三分层）

- **`__expf` vs `expf` 不是宏门控，是两族函数直绑**：__expf 在 device_functions.h:175→`__nv_fast_expf` 无条件；expf 在 math.h:113→`__nv_expf`。**第三档 `__FAST_OR_SLOW`**（math.h:53-58）只门控 5 个（sinf/cosf/logf/log2f/sincosf :87-89,181-183,186-188,301-303,310-312），由 `-fgpu-approx-transcendentals`→InitPreprocessor.cpp:1501-1502 定义 `__CLANG_GPU_APPROX_TRANSCENDENTALS__`——**与 HIP 的 __clang_hip_math.h 同构**
- `__fdividef`（device_functions.h:221-223）无条件 fast；fdividef（math.h:120-126）`#if __FAST_MATH__ && !__CUDA_PREC_DIV`；double 直接 `__a/__b`（:119）
- cbrt/hypot 无 fast 无门控（:76-77,143-144）；special：rint 用 __builtin_rint（:259-260，注释 `__nv_rint*` 有 bug）、sqrtf 用 __builtin_sqrtf（:318）、scalbln 手写饱和（:283-296）、labs/lrint LP64 分派（:153-157,189-199）
- cmath.h：全局命名空间定义+using 拉进 std（:20-33 设计注释）；60 个整型重载（:241-300）；:187-189 nexttoward 省略（libdevice 没有）

## 4.4 __syncthreads 直通链（AMDGPU 三层接力的正例）

**`__syncthreads()` 不在任何 clang 头文件里——纯编译器 builtin**：
- BuiltinsNVPTX.td:896 定义；NVPTX.cpp:1413-1416 特判直接 `CreateCall(Intrinsic::nvvm_barrier_cta_sync_aligned_all, i32 0)`；IntrinsicsNVVM.td:131-139 注释给出 barrier0→bar.cta.sync.aligned.all 映射
- `__syncthreads_and/_or/_count` 在 device_functions.h:524-526→`__nvvm_bar0_{and,popc,or}` builtin→NVPTX.cpp:1425+ 特判（red.and intrinsic+ICmpNE+ZExt）；__threadfence→`__nvvm_membar_{gl,cta,sys}`（:527-529）
- **铁证**：__clang_gpu_device_functions.h:285-288 注释 "CUDA lowers __syncthreads to an NVPTX builtin directly"，`#if !defined(__NVPTX__)` 才走 hermetic __gpu_sync_threads

**三语言 barrier 对照表**（本项目贯穿性结论的最终版）：

| 语言 | 链路 | 层数 |
|---|---|---|
| OpenCL | 声明→库调用→opencl.bc→builtin | **三层接力** |
| HIP | hermetic 宏→builtin_amdgcn_s_barrier+fence | 两层 |
| CUDA | builtin→intrinsic | **一层直通** |

**__shfl_\***：intrinsics.h:27-96 `__MAKE_SHUFFLES` 每族 8 重载，int/float 直调 `__nvvm_shfl_{idx,up,down,bfly}_{i32,f32}`（:88-96），64 位经 memcpy 拆 2×i32；width 编码 `((warpSize-width)<<8)|mask`；sync 变体（:173-182）→PTX60 门控 builtin。vote 族 :198-216→`__nvvm_vote_*_sync`；__activemask CUDA<9020 用 `__nvvm_vote_ballot(1)`。

## 4.5 libdevice_declares（468 行）

extern "C" + `__device__` 的 **~440 个 `__nv_` 纯声明**（字母序），含 __nv_fast_* 快速版（:131-137）；wrapper:162-163 注释：CUDA 9.1 起 SDK 不再提供声明。声明侧与 NVVMReflect 呼应：链接期由 libdevice.10.bc 解析（Cuda.cpp:233-242），bc 内 __nvvm_reflect 由 reflect pass 求值（NVPTX-notes 已覆盖）。

## 4.6 complex_builtins / texture_intrinsics（小节）

- complex：定义 __muldc3/__mulsc3/__divdc3/__divsc3（libgcc 契约），NVPTX 特判 _SCALBNd=__nv_scalbn（:29-33，FIXME）
- **texture：`__nv_tex_surf_handler` 重定义为宏→constexpr `__tex_op_hash`（:191-195）编译期字符串哈希选 __Tag<N> 模板特化**，模拟 NVCC 字符串重载 builtin；底层 sust/tex 走 **inline asm**（:764+）——**这一族是 asm 而非 builtin**（wrapper :321-327 的"要 builtin 不要 asm"原则的例外区）

## 4.7 昇腾映射（推理级，待验证）

CUDA 链 = property getter→builtin→intrinsic→%tid.x 特殊寄存器；AscendC 的 GetBlockIdx 若为编译器 builtin（CCE 内建）则 CUDA 同构，若为库函数则近 OpenCL 模式。

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| __clang_cuda_runtime_wrapper.h:32-493（多点） | 组织全景 |
| builtin_vars.h:23-35, 46-50, 53-114 | 机制三元 |
| device_functions.h:175, 221-223, 524-529 | 快速版/syncthreads 系 |
| math.h:53-58, 76-77, 113-126, 143-144, 153-199, 259-260, 283-296, 301-318 | 三层映射 |
| cmath.h:20-33, 187-189, 241-300 | std 拉入 |
| intrinsics.h:27-96, 173-216 | shfl/vote |
| libdevice_declares.h:131-137 等 | ~440 声明 |
| texture_intrinsics.h:191-195, 764+ | 编译期哈希 + asm |
| BuiltinsNVPTX.td:896 / NVPTX.cpp:1413-1425+ / IntrinsicsNVVM.td:131-139, 2757-2764 | builtin 直通链 |
| CGBuiltin.cpp:6887-6890 / Cuda.cpp:233-242, 318-331 | 通用映射/-include 点 |
| __clang_gpu_device_functions.h:285-288 | 铁证注释 |

实测素材：scratch/hdr-test/（tid/sync/shfl 三源）、主会话 tid.cu asm 直通（%tid.x 终点）。
