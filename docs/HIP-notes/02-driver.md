# §3 HIP Driver 工具链双路径深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，clang-24 @ build-debug 实测（全部 -### 级，素材 scratch/v1-v11 dump）。
> 引用格式 `文件:行号`。
> 素材来源：子代理调研+实测（引用已核实，3 处任务前提修正）+ 主会话代写组装。

**三处任务前提修正**：① Options.td 已迁至 `clang/include/clang/Options/`；② Cuda.h→OffloadArch.h/.cpp；③ hipDeviceTable 本树不存在（等价物是 `__hip_register_globals` + `offloading::wrapHIPBinary` ClangLinkerWrapper.cpp:793-796）。

---

## 3.1 HIPAMD::Linker::ConstructJob 四路分发（:194-210）

| 输入 | 路径 | 实现 |
|---|---|---|
| TY_HIP_FATBIN | constructHIPFatbinCommand | HIPUtility.cpp:33-91（bundler 打包） |
| TY_LLVM_BC | llvm-link | CommonArgs.cpp:3430-3453 |
| isSPIRV() | constructLinkAndEmitSpirvCommand | HIPAMD.cpp:145-189：llvm-link 后默认走 **in-tree SPIR-V 后端**（clang -cc1 -triple=spirv64-amd-amdhsa -emit-obj，UseSPIRVBackend 默认 true :155-157），否则 llvm-spirv --spirv-max-version=1.6 --spirv-ext=+all |
| 默认 | constructLldCommand | HIPAMD.cpp:50-138：`lld -flavor gnu -m elf64_amdpu --no-undefined -shared -plugin-opt=-amdgpu-internalize-symbols` + **--whole-archive**（:104-114 注释：host/device 分进程链接导致可见性丢失的 workaround）+ -Xoffload-linker→-plugin-opt= 转译（:116-126） |

**产物**：bundler 打包 `*.hipfb`，`-type=o -bundle-align=4096`（HIPCodeObjectAlign HIPUtility.cpp:28），dummy host 条目 `host-x86_64-unknown-linux-gnu`（:47），COV≥4 用 hipv4 offload kind（:52-55）。

**与 CUDA 载体差异**（对照 NVPTX-notes/06 §7.1）：NVIDIA 用自家 `fatbinary --image3=kind=elf`（kind=elf only 丢 PTX）；HIP 用 **clang-offload-bundler**（CCOB 魔数/可压缩/多 triple ID）。host 嵌入 `.hip_fatbin`（CGCUDANV.cpp:906-908，align 4096 :917），ctor 链 `__hipRegisterFatBinary→__hip_register_globals`（:834-842），handle 存 `__hip_gpubin_handle`（:993-1001）。

## 3.2 HIPSPV 替身链（450 行）

链路：cc1（`-triple spirv64-*`、-Wspir-compat、`-vectorize-loops/-slp=false` workaround :272-277）→ llvm-link（:86-96）→ 可选 `opt -load-pass-plugin libLLVMHipSpvPasses.so -passes=hip-post-link-passes`（:60-78）→ chipStar OS 用 in-tree SPIR-V 后端（:153-181，+SPV_INTEL_function_pointers 等受限扩展）或外置 llvm-spirv（:114-141）；非 chipStar 用 llvm-spirv `--spirv-max-version=1.1 --spirv-ext=+all`（:189-192）。

triple 转换：OffloadArchToTriple（OffloadArch.cpp:111-115）AMDGCNSPIRV→spirv64-amd-amdhsa；Driver.cpp:4035-4038 SPIRV 默认 arch=Generic；:6121-6123 OFK_HIP+spirv64→HIPSPVToolChain；:6223-6226 AMDHSA+spirv64→SPIRVAMDToolChain；:6300-6301 OS=ChipStar→HIPSPVToolChain。

**脱离 ROCm 的承接**：host 侧由 **chipStar runtime over Level Zero/OpenCL**（HIPSupport.md:35-38 官方表述）。

## 3.3 RDC 语义

- 默认非 RDC（Driver.cpp:4100-4102；Clang.cpp:5236-5238——SYCL 默认 RDC、CUDA/HIP 默认否）
- 非 RDC device-only：per-action LinkJobAction(TY_Image)（:4240）→ 再包 LinkJobAction(TY_HIP_FATBIN)（:4295-4302）；host+device：OffloadPackager→LinkerWrapper（:4303-4326）
- RDC：embed 用 `-fembed-offload-object`（Clang.cpp:8347-8350）vs 非 RDC `-foffload-include-binary`（:8343-8346）；**设备链接藏在 wrapper 内**
- 与 CUDA 同构：:4286-4295 CUDA 非 RDC 直出 TY_CUDA_FATBIN；:4249-4257 仅 CUDA 在 DDep 保留 PTX

## 3.4 --hip-device-lib-path 与六家族衔接

- Options.td:1523-1527：`--rocm-device-lib-path=` 别名 `--hip-device-lib-path=`（:1525）、`--hip-device-lib=`（:1526）
- AMDGPU.cpp getDeviceLibs :1190-1264：`--hip-device-lib` 手工覆盖（:1219-1241）否则 getCommonDeviceLibNames（:1249）→ getCommonBitcodeLibs（:1130-1167）= **ocml+ockl+oclc 三态+wave64+libdevice+oclc_abi**（衔接 Clang-AMDGPU-notes/04 六家族）
- `--hip-link`（Options.td:1488-1489）：Driver.cpp:1081 探测、:3440-3444 hipstdpar 隐含、:3445-3450 放行 -emit-llvm 链接；`-nogpulib`→`--no-offloadlib`（AMDGPU.cpp:1196-1199）

## 3.5 Driver.cpp 97 行 HIP 引用分类

①探测/TC 创建（:1076-1082 IsHIP 三源；:6090-6098/:6121-6123/:6223-6226/:6300-6301 三处 TC 分派）②Action 图（:3612-3619 HIPRDCDeviceOnlyFatBin；:3713-3720 -S bundling；:4224-4241 IsHIPSPV 例外门；:4295-4334 fatbin/wrapper 分叉）③输入类型（:3321-3323 hipstdpar→TY_HIP）④链接门（:3440-3450）⑤wrapper 转发（Clang.cpp:9895-9964/:10026-10041/:9795-9799 SuppressHIPNoRDCVerbose 防 CMake 误解析）⑥arch（:935-936/:1002/:1047-1049/:4035-4038）。

## 3.6 动态验证（-### 实测，scratch/v1-v11）

**V6（决定性）device-only 非 RDC 全链**：
```
cc1 -emit-obj
→ lld -flavor gnu -m elf64_amdgpu --no-undefined -shared
    -plugin-opt=-amdgpu-internalize-symbols -plugin-opt=mcpu=gfx1100
    --whole-archive -o *.out *.o --no-whole-archive     ← 与 HIPAMD.cpp:56-62 逐字吻合
→ clang-offload-bundler -type=o -bundle-align=4096
    -targets=host-x86_64-unknown-linux-gnu,hipv4-amdgcn-amd-amdhsa--gfx1100
    -input=/dev/null ...
```
**V2 RDC**：设备 cc1 `-fgpu-rdc -flto=full` → host `-fembed-offload-object` → clang-linker-wrapper（lld 隐藏于 wrapper）；**V5 重入仿真**：`ld.lld --no-undefined -shared -plugin-opt=mcpu=gfx1100`（amdgpu::Linker，AMDGPU.cpp:631-665）。
**V3/V9/V10 hipSPV 触发**：`--offload-arch=amdgcnspirv`（→SPIRVAMDToolChain）或 `--offload=spirv64-unknown-unknown`/`-chipstar`（→HIPSPVToolChain）；实测报 `--hip-path must be specified…unless -nogpuinc`（HIPSPV.cpp:339）证明 AddHIPIncludeArgs 生效。
V8 多 arch：per-arch cc1+lld 对+单 bundler 逗号连 targets；注意输出含 `"(in-process)"`——新驱动进程内执行。

## 3.7 昇腾映射（推理级，待验证）

1. **PyPTO"CUDA 源→tile IR"驱动**：HIPAMD 双阶段是模板——per-TU `-emit-llvm-bc -flto=full` 可重定位 IR + lld 链接期 LTO 终 codegen；bundler 多 target-ID 产物（triple+arch+kind，4096 对齐）对应多昇腾芯片 fat 产物
2. **hipSPV ↔ pto-isa CPU 模拟器**：generic spirv64+Generic arch+编译期禁向量化、特化推迟到运行时（Level Zero/OpenCL JIT）≈ tile IR 先在 CPU 模拟器跑、后端就绪后再特化；**`amdgcnspirv` 伪 target**（虚拟 arch 编译、运行时 finalize）直接对应"为模拟器编译 IR vs 为 davinci 编译 ISA"

---

## 引用清单

| 引用 | 内容 |
|---|---|
| HIPAMD.cpp:50-210 / HIPUtility.cpp:28-91 | 四路分发/bundler |
| HIPSPV.cpp:60-339 | 替身链 |
| OffloadArch.cpp:111-115 / Options.td:1488-1527 | arch/flag |
| AMDGPU.cpp:631-665, 751-756, 1130-1264 | lld/设备库 |
| Driver.cpp:935-6301（97 处分类）/ Clang.cpp:5236-8350, 9795-10041 | Action 图/传导 |
| CGCUDANV.cpp:834-1001 | 嵌入链 |
| ClangLinkerWrapper.cpp:793-796 | wrapHIPBinary |
| 实测：scratch/v1-v11 dump | 全链/RDC/hipSPV/多 arch |
