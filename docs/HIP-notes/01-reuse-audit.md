# §2 HIP 语言机器复用审计

> 基准：llvm-project main @ `3eda2aebadd4`，clang-24 @ build-debug 实测。
> 引用格式 `文件:行号`；实测素材 `HIP-notes/scratch/t.hip`。
> 素材来源：子代理静态审计（引用已核实）+ 主会话补动态验证代写。

---

## 2.1 总开关：HIP ⟹ CUDA（决定性证据）

**LangOptions.cpp:217-218**：
```cpp
Opts.HIP = Lang == Language::HIP;
Opts.CUDA = Lang == Language::CUDA || Opts.HIP;   // HIP ⟹ CUDA=true
```
**HIP 通过蕴含 CUDA 获得整套语言机器——这就是零复用成本的机制根源**（不是偶然而是设计：Sema/CodeGen 全部走 CUDA 路径，只在 11 个分支点做 HIP 特判）。

## 2.2 SemaCUDA.cpp（1,297 行）11 个 HIP 分支点分类

grep 实测 16 行引用归并为 11 个分支：

| 类别 | 分支 | 行号 |
|---|---|---|
| **行为差异（6 处）** | HIP 不支持 device 侧 kernel call/CDP（含解释器分支） | :72-79 |
| | device kernel launch → 硬错误 err_cuda_device_kernel_launch_not_supported | :86-88 |
| | HIPManagedAttr → CVT_Unified 变量目标分类 | :250-251 |
| | HIPStdPar 乐观放行 device→host 调用 | :351-359 |
| | HIPStdPar 抑制引用捕获诊断 | :1139 |
| | managed 变量用于全局初始化 → 错误 | :803-808 |
| **符号名差异（1 处）** | getConfigureFuncName：`__hipPushCallConfiguration`/`hipConfigureCall` vs CUDA `__cuda*` | :1232-1234 |
| **纯注释（4 处）** | 文案 | :219/:707/:1029/:1104 |

## 2.3 LangOptions.def 开关族与传导

- `:226` CUDA、`:227` HIP、`:258` CUDAIsDevice、`:261` GPURelocatableDeviceCode、`:262/265/266` CUDA/HIP 共享三开关、`:263` GPUAllowDeviceInit（HIP-only）、`:264` GPUMaxThreadsPerBlock（HIP-only 默认 1024）、`:274` HIPUseNewLaunchAPI、`:276/277` HIPStdPar、`:246` NoGPULib
- 勘误：本树**无** OffloadingInputs LangOpt（仅 Driver.cpp 局部变量，Clang.cpp:5252）
- 传导：AMDGPU.cpp:926-928 device job 附加 `-fcuda-is-device -fno-threadsafe-statics`（**HIP 复用 CUDAIsDevice**）；Clang.cpp:7420-7430 IsHIP→-fhip-new-launch-api；AMDGPU.cpp:626 `-include __clang_hip_runtime_wrapper.h`
- FP 差异：LangOptions.cpp:219-220 HIP 默认 FPM_FastHonorPragmas vs CUDA FPM_Fast
- **宏互斥静态证据**：InitPreprocessor.cpp:590-592 `__CUDA__` 仅 CUDA&&!HIP；:597-628 `__HIP__` 族；:1493-1497 `__CUDA_ARCH__` 仅 CUDAIsDevice&&!HIP；`__CUDACC__` 非编译器预定义（仅 wrapper :37 内 #if defined(__CUDA__) 门控——HIP 下天然不可达）

## 2.4 CGCUDANV（1,544 行）HIP 分支清单（CodeGen 零专属的精确含义）

fatbin 命名（:903-934：`__HIP,__hip_fatbin`/4096 对齐/HIPFatMagic/外部符号+CUID vs CUDA `.nv_fatbin`/8 对齐）；launch 符号（:273-279/:341-345）；stream 后缀（:445-448 `_spt` vs `_ptsz`）；ctor 空模块早退（:848-853）；`__hip_gpubin_handle` 一次性注册 guard（:984-1010）；dtor guard（:1155-1165）；PGO 段（:1391-1393）；**HIP kernel handle 为稳定 GlobalVariable**（:1512-1530——Clang-NVPTX-notes/02 已析的 handle 差异）。

## 2.5 语法亲缘性证明

- **Attr.td 无 HIP 专属语法属性**：全部 CUDA 属性 LangOpts=[CUDA]（CUDAGlobal :1592/CUDADevice :1558/CUDAShared :1660/CUDAConstant :1546/CUDAHost :1600）——因 HIP⟹CUDA，**HIP 原样复用 `__global__/__device__/__shared__`**；唯一 HIP 专属 attr 是 HIPManaged :1616-1621（LangOpts=[HIP]，与 CUDAConstant/CUDAShared 互斥 :1662）
- **内建变量同一实现**：`__clang_gpu_builtin_vars.h` 以 `#if defined(__HIP__) || defined(__CUDA__)` 统一守卫，threadIdx/blockIdx 经 `__GPU_COORD_BUILTIN` 映射 gpuintrin.h 的 `__gpu_thread_id_x()`——同一头文件同一语法，仅底层 intrinsic 各后端提供

## 2.6 动态验证（主会话实测）

```bash
# ① -x hip 缺 wrapper 报 unknown type name '__global__'（与 CUDA -nocudainc 同款坑）
$ clang-24 -x hip --cuda-device-only -nogpuinc -nogpulib --offload-arch=gfx1100 t.hip
error: unknown type name '__global__'        # -nogpuinc 砍掉 -include wrapper

# ② 无 ROCm 时报错指引（正确 flag 是 -nogpuinc 非 -nogpulib）
$ ... -nogpulib（不带 -nogpuinc）
error: cannot find HIP runtime; provide its path via '--rocm-path', or pass '-nogpuinc'

# ③ 宏互斥实证
$ -dM -E -x hip ... | grep -cE "__CUDA__|__CUDACC__"
0                                            # HIP 下 __CUDA__/__CUDACC__ 零定义（互斥证实）
# 对照：-x cuda 侧 __CUDA__=1 存在

# ④ -include wrapper 可走通到 amdgcn target（失败于 cmath 找不到——无 SDK 环境，链路本身通）
fatal error: 'cmath' file not found ... compiling for amdgpu11.00-amd-amdhsa
```

## 2.7 昇腾映射（推理级，待验证）

**AscendC 若加 CUDA 语法前端**：仿 LangOptions.cpp:218 做 `ASCENDC ⟹ CUDA=true`，Sema 复用率应达 HIP 级（≤14 处分支）。**平台语义必须自写的只有三类**：
1. device 侧 kernel call 支持与否（:72-88 类，取决于昇腾有无动态并行）
2. managed/统一内存属性（自造 XxxManagedAttr，仿 HIPManaged 四层机制）
3. launch 配置运行时符号名（:1232 类）

纯注释 4 处零成本；HIPStdPar 可跳过。

---

## 引用清单

| 引用 | 内容 |
|---|---|
| LangOptions.cpp:217-220 | 总开关+FP 差异 |
| SemaCUDA.cpp:72-88, 219, 250-251, 351-359, 707, 803-808, 1029, 1104, 1139, 1232-1234 | 11 分支 |
| LangOptions.def:226-277 | 开关族 |
| AMDGPU.cpp:626, 926-928 / Clang.cpp:5252, 7420-7430, 8383-8386 / CompilerInvocation.cpp:638-644 | 传导 |
| InitPreprocessor.cpp:590-628, 1493-1497 | 宏互斥 |
| CGCUDANV.cpp:256-260, 273-279, 341-345, 445-454, 520-522, 848-853, 903-934, 984-1010, 1155-1165, 1296-1297, 1391-1393, 1512-1530 | CodeGen 分支 |
| Attr.td:1546-1662 / __clang_gpu_builtin_vars.h / gpuintrin.h | 亲缘性 |

实测素材：scratch/t.hip（宏互斥 0 命中/同款 wrapper 坑）。
