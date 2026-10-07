# Clang-AMDGPU 深度分析 — §5 设备库生态：ocml / ockl / oclc（+opencl / irif / asanrtl）

日期：2026-09-29。基准：llvm-project main @ `3eda2aebadd4`。
铁律遵守：本地 文件:行号 引用均经 grep/read 核对；Web 引用均实际抓取（GitHub API / raw，
ROCm/llvm-project amd-staging 分支）。**本节关键勘误**：任务假设"barrier 实现在 ockl"——
实际证据显示实现在 **opencl 库**（wgbarrier.cl），详见 §5.3。昇腾部分为推理级，已标"待验证"。

## 5.0 总览：链接清单里的六个家族

getCommonBitcodeLibs（clang/lib/Driver/ToolChains/AMDGPU.cpp:1130-1167）给出的完整链：

| 顺序 | 库 | 选择条件（AMDGPU.cpp） | Internalize | 角色 |
|---|---|---|---|---|
| 0 | asanrtl | GPUSan（ASan 开）:1147-1150 | **否**(:1149) | ASan 设备运行时 |
| 1 | ocml | 恒链 :1153 | 是 | 数学库 |
| 2 | ockl | 非 OpenMP（或 GPUSan+OpenMP）:1154-1157 | 是 | kernel 运行时服务 |
| 3 | oclc_unsafe_math on/off | UnsafeMathOpt‖FastRelaxedMath :1158 | 是 | 配置位 |
| 4 | oclc_finite_only on/off | FiniteOnly‖FastRelaxedMath :1159 | 是 | 配置位 |
| 5 | oclc_wavefrontsize64 on/off | Pref.Wave64 :1160 | 是 | 配置位 |
| 6 | oclc_isa_version_XXX | -mcpu=gfxXXX（经 LibDeviceMap）:1161 | 是 | per-arch 预编译 |
| 7 | oclc_abi_version_YYY | code object version（COV×100）:1162-1164 | 是 | ABI 契约 |
| 最前(仅 OpenCL) | opencl.bc | 源语言 OpenCL C（standalone 路径）:1289-1290 | 是 | 语言 builtin 实现 |

## 5.1 四库分工

### 证据一（driver 源码）：文件名即接口

scanLibDevicePath（AMDGPU.cpp:95-157）扫描 ROCm 安装的 amdgcn/bitcode 目录，按文件名装填：
- `ocml.amdgcn.bc`→OCML（:116）、`ockl.amdgcn.bc`→OCKL（:118）、`opencl.amdgcn.bc`→OpenCL（:120）、
  `asanrtl.amdgcn.bc`（:122-123）；
- `oclc_finite_only_off/on`（:124/:126）、`oclc_unsafe_math_on/off`（:128/:130）、
  `oclc_wavefrontsize64_on/off`（:132/:134）→ 各自的 ConditionalLibrary{On,Off}
  （clang/include/clang/Driver/RocmInstallationDetector.h:43-57）；
- `oclc_abi_version_XXX`→ABIVersionMap（:136-141）；`oclc_isa_version_XXX`→LibDeviceMap["gfx"+XXX]
  （:145-154；:143-144 注释仍写旧名"ocl_isa_version"——注释滞后的小佐证）。

头文件字段注释直白（RocmInstallationDetector.h:139-147）：OCML/OCKL 是
"Libraries that are always linked"，OpenCL "depending on the language"，三个 ConditionalLibrary
注释 **"Libraries swapped based on compile flags"**。

### 证据二（Web，amd-staging）：仓库结构与官方分工表

ROCm-Device-Libs 独立仓库已归档只读（README："This project is now located in the AMD Fork of
the LLVM Project, under the 'amd/device-libs' directory... default branch is amd-staging"）。
amd/device-libs 顶层目录（GitHub tree API 实取）：
`asanrtl cuda2gcn doc hip irif ockl ocml oclc opencl test utils`。

README 官方分工表：**oclc\*** = Open Compute library controls（无依赖）；**ocml** = Open Compute
Math library（依赖 oclc\*）；**ockl** = Open Compute Kernel library（依赖 oclc\*）；
**opencl** = OpenCL built-in library（依赖 ocml+ockl+oclc\*）；hip = HIP built-in library。

- **ocml**：数学，对标 NVPTX libdevice。分工差异：CUDA 把全部设备函数塞一个
  libdevice.10.bc，AMD 拆"数学（ocml）/kernel 服务（ockl）"，语言薄壳（opencl/hip）再叠加。
- **ockl**：kernel 运行时服务。src/ 实取 32 个 .cl：workitem.cl（get_local_id 族）、
  hostcall.cl/hostcall_impl.cl（printf hostcall 协议——§2 printf 直透未解析符号的库侧对应物）、
  mtime.cl、mul24.cl、clz/ctz/popcount、wait.cl、wgred/wfredscan、wgscratch.ll（.ll 源！）、
  services.cl 等。**ockl/src 无 wgbarrier.cl——barrier 不在 ockl**。
- **oclc**：特性配置位（§5.2 专题），产物即 driver 侧的 on/off 对、isa_version、abi_version .bc。
  src/ 清单未逐一核取（额度所限），以 driver 端 .bc 名称为硬证据；README 指向 doc/OCML.md#controls。
- **"irdl"？实为 irif**：目录存在但**仅含 inc/**（无 src、不产 .bc），是库间共享的 IR 接口头文件，
  不参与链接清单（scanLibDevicePath 无 irif 分支）。具体接口内容未核读（待验证）。
- **opencl**：OpenCL 语言 builtin 的实现库，src/ 按规范章节分目录
  （async/common/geometric/image/integer/math/media/misc/pipes/relational/subgroup/vldst/workgroup）。
  **barrier 实现就在这里**（§5.3）。opencl.bc 仅 standalone OpenCL 路径链入（AMDGPU.cpp:1289-1290，
  HIP/OpenMP 分支提前 return）；clang driver 的 HIP 路径不链 hip.bc——HIP 头直接声明设备符号
  （__clang_hip_libdevice_declares.h，173 个 __device__ 声明，见 03-languages.md）落到 ocml/ockl。
  device-libs 的 hip/ 目录用途（hipRTC/comgr 流程）未核（待验证）。
- **asanrtl**：GPU ASan 运行时，唯一不内化的库（§5.4）。

### 对照与设计动机

四库拆分的本质是**按变化频率分层**：数学函数（高频迭代、纯计算）／kernel 服务（硬件绑定、
语言无关）／配置位（每个编译标志一对，可独立替换）／语言壳（每种语言一份，依赖前三者）。
依赖方向 opencl→{ocml,ockl,oclc} 单向无环，driver 链接顺序（ocml→ockl→oclc 配置→libdevice→abi）
即拓扑序。OpenMP 例外跳过 ockl（:1154-1157），因为 OpenMP 有自己的 libomptarget-amdgcn .bc
（同经 -mlink-builtin-bitcode 链入，CommonArgs.cpp:2882 附近）。

## 5.2 版本协商：oclc"多份预编译" vs NVVMReflect"一份+求值"

### oclc 机制（源码证据）

- 三个布尔配置位各一对 .bc，编译标志二选一：
  UnsafeMath = `-cl-unsafe-math-optimizations`‖`-funsafe-math-optimizations`‖FastRelaxedMath
  （:1158，标志采集 :79-86）；FiniteOnly 同构（:1159，:75-77）；
  Wave64 = isWave64（:1160；声明 AMDGPU.h:110，函数体未细核）。
  FastRelaxedMath（-cl-fast-relaxed-math/-ffast-math）同时拉起 unsafe_math 与 finite_only。
- **per-arch**：`oclc_isa_version_803.amdgcn.bc` 等，getLibDeviceFile("gfx803") 查
  LibDeviceMap（RocmInstallationDetector.h:259-263）在 :1161 链入——架构适配=链接时挑一份预编译片。
- **per-ABI**：`oclc_abi_version_500/600/...`，DeviceLibABIVersion = COV×100（h:18-27），
  COV≥5 必须（requiresLibrary() h:30；checkCommonBitcodeLibs AMDGPU.cpp:1117-1126，
  COV≥6 缺失时报需 ROCm 6.3，:1123-1124）。

### NVVMReflect 对照（引 NVPTX-notes/02-ir-layer.md §3.1）

libdevice.10.bc **一份服务全 sm 代**（Cuda.cpp:233-242 注释明言 "CUDA-9+ uses a single
libdevice file for every NVIDIA GPU variant"）；库体内嵌 `__nvvm_reflect("__CUDA_ARCH")`
调用点，NVVMReflect pass 查表→ConstantInt RAUW→级联折叠死分支（234 行实现、双跑防御、
hasTargetName 门控详见 NVPTX-notes）。

### 两种配置分发哲学

| 维度 | oclc 多份预编译 | NVVMReflect 一份+求值 |
|---|---|---|
| 产物形态 | N 份 .bc（3 布尔位=6 文件 + isa×架构数 + abi×COV 数） | 1 份 .bc |
| 求值时机 | 链接前（driver 选文件名） | 优化管线中（pass 折叠） |
| 自定义 pass | 无 | 有（NVVMReflect） |
| 组合爆炸 | 每维独立库，正交维度不叠乘（3 位 6 文件而非 8 份全组合） | 任意多配置零额外文件 |
| 一致性保障 | 扫描失败即 err_drv_no_rocm_device_lib（:1109-1116） | reflect 值由驱动/模块旗标注入 |

设计动机深层：AMDGPU 每次 HIP/OpenCL 编译都单架构 whole-program（-mcpu 必选），链接期选片
是自然且零成本时机；NVCC 历史上"一份 fatbin 多架构+运行时选择"，且 libdevice 随 CUDA Toolkit
独立分发，一份文件简化版本管理。**oclc 的关键技巧是按维度切库**：finite_only/unsafe_math/
wavefrontsize64 各自成对，维度间靠"链 A-on 或 A-off、B-on 或 B-off"组合，而非 2^N 全组合预编译。

## 5.3 barrier 完整故事：前端外部调用 → opencl.bc → __builtin_amdgcn_s_barrier

### 证据链（三段全部核实）

1. **前端发外部调用**（§2 已实测，Clang-AMDGPU-notes/02-codegen.md §4.3）：CodeGen 不产生
   intrinsic，发 `tail call void @_Z7barrierj(i32 2) #4`（convergent 外部 C++ mangled 调用）。
   声明源 opencl-c.h:12399（barrier）/12402-12403（work_group_barrier）。
2. **库侧实现**（Web 实取，amd/device-libs/opencl/src/workgroup/wgbarrier.cl）：
   ```c
   barrier(flags)                       → work_group_barrier(flags);
   work_group_barrier(flags)            → work_group_barrier(flags, memory_scope_work_group);
   work_group_barrier(flags, scope):
       if (flags) {
           atomic_work_item_fence(flags, /*G|L 双 fence? seq_cst : release*/, scope);
           __builtin_amdgcn_s_barrier();     // ← 就在这里
           atomic_work_item_fence(flags, /*G|L 双 fence? seq_cst : acquire*/, scope);
       } else {
           __builtin_amdgcn_s_barrier();
       }
   ```
3. **builtin → intrinsic**：__builtin_amdgcn_s_barrier（BuiltinsAMDGPU.td:152）=
   llvm.amdgcn.s.barrier（IntrinsicsAMDGPU.td:283-285，"Vanilla workgroup sync-barrier"，
   IntrNoMem+IntrHasSideEffects+IntrConvergent），后端直出 BARRIER 指令。

### 勘误与结论

- **任务假设"实现在 ockl"不成立**：wgbarrier.cl 在 opencl 库 workgroup/ 目录；ockl/src
  （32 文件实列）无 barrier。语义上合理：_Z7barrierj 是 OpenCL 语言 builtin（opencl-c.h 声明），
  实现归语言库 opencl.bc；ockl 只放语言无关 kernel 服务。
- "实现为 __builtin_amdgcn_s_barrier"**成立**（上源码直证）：库在 builtin 两侧手工编排
  release/acquire fence（双 fence 用 seq_cst），无 fence 时裸调。
- **为何前端不需要 barrier intrinsic**：convergent 语义前端已用调用属性表达（#4）；
  fence 编排、S_WAITCNT 交互等目标知识全部封装在库体+后端。前端零目标知识，语言函数只是
  "待库替换的普通调用"——这就是 §2 负结果定案的机制闭环。
- 未核项：HIP __syncthreads() 实现位置（hip 库 or clang 头）；libclc 路径下 barrier 实现
  （addOpenCLBuiltinsLib，CommonArgs.cpp:2908 起，仅 amdgcn--amdhsa 且 LLVM 环境或 -libclc-lib=
  时接管，AMDGPU.cpp:980-981）。

## 5.4 -mlink-builtin-bitcode：链接与内化的时机

### 机制（本地源码）

- 选项定义（Options.td:8145-8150）：`-mlink-builtin-bitcode` = "Link and **internalize**
  needed symbols from the given bitcode file **before performing optimizations**"；
  `-mlink-bitcode-file` = 只链不内化。driver 按 ShouldInternalize 二选一（AMDGPU.cpp:993-998，
  注释"Link device libraries for OpenCL, HIP, and OpenMP"）；BitCodeLibraryInfo 默认
  ShouldInternalize=true（ToolChain.h:135-139），asanrtl 显式 false（AMDGPU.cpp:1149）。
- **时机一（默认，pre-opt）**：CodeGenAction.cpp:295-297——AST 生成完模块后、emitBackendOutput
  前 LinkInModules(getModule()) → 库体随后进入**完整优化管线**（内联/折叠/属性传播）。
- **时机二（可选，post-opt）**：`-mlink-builtin-bitcode-postopt`（Options.td:8268-8273）→
  BackendUtil.cpp:1103-1107：优化管线后 LinkInModulesPass(BC) + AssignGUIDPass
  （LinkInModulesPass.cpp:21-29，pass 壳调 BC->LinkInModules）。
- **内化实现**（CodeGenAction.cpp:204-239）：Internalize 时 Linker::linkModules 带 callback
  `internalizeModule`——**除保留集 GVS 外全部 local 化**（:222-229）；同时 PropagateAttrs 把
  可合并默认属性（denormal-fp-math 等）**merge** 进库函数而非覆盖（:209-217；
  CGCall.cpp:2311-2319 注释"should not simply overwrite any existing attributes in the
  linked library"）。

### 对照 NVPTX

同一选项、同一机制：Cuda.cpp:939-940 把 libdevice.10.bc 同经 -mlink-builtin-bitcode 交 cc1。
差异不在选项而在库形态（一份全代 vs per-arch/per-config 多份）与库内协商原语
（reflect 调用点 vs on/off 选片）。libomptarget .bc 亦同选项（CommonArgs.cpp:2882）。

### 设计动机

设备代码是 whole-program 单链接单元：内化后（1）符号不导出不碰撞，多库同名免疫；
（2）优化器可自由内联/删除——barrier 的 fence 编排优化、数学函数 target-aware 展开都依赖
pre-opt 链接时机。asanrtl 例外不内化：其函数需保持外部可见性供 runtime/插桩引用。

## 5.5 昇腾映射与 PyPTO 启示（推理级，标注待验证）

### 设备库等价物（待验证）

- libascendcl 是 **host 侧**运行时（算子下发/内存管理），对标 ROCm host runtime（HIP/ROCR），
  **不是** ocml/ockl 的等价物。
- CCE 设备侧更可能走"**编译器内置函数直出**"路线（get_local_id/__syncthreads 类若为
  builtin/intrinsic 则无库层，对标 __builtin_amdgcn_\* 一侧而非 _Z7barrierj 一侧）。
  CCE 是否存在"外部调用+位码库链接"层：未验证。判定实验：查昇腾 OpenCL barrier 的实现位置
  （库 or intrinsic）——**待验证**。

### PyPTO tile 特性开关的三条可抄路线

1. **oclc 式（多份小 .bc + 链接期选片）**：适合少而正交的布尔开关；关键是**按维度切库**
   （每维 on/off 对，不预编译全组合）。零 IR pass 成本、driver 里配置显式可见（诊断友好）。
   PyPTO 已是 per-arch 编译流程，oclc_isa_version 式 per-arch 预编译天然契合——tile 硬件代次
   差异（m200/m300 tile 形状/寄存器布局）可直出 per-arch 片。
2. **NVVMReflect 式（一份 + 编译期求值 pass）**：适合配置维度多或"一份 IR 服务多代"；
   NVPTX-notes §3.1 已给 234 行实现与防御细节，可直接移植。
3. **混合（推荐评估）**：per-arch 用选片（isa_version 模式），arch 内功能开关用 reflect 求值
   ——避免 N_arch × 2^N_flag 文件爆炸。
- **内化时机教训**：tile 原语库必须 **pre-opt 链接**（默认路径），否则边界检查消除/常量折叠
  看不到库体，tile 原语性能等同不透明函数调用。

## 引用清单（全部经核对）

### 本地源码（llvm-project @ 3eda2aebadd4）
- clang/lib/Driver/ToolChains/AMDGPU.cpp：95-157(scanLibDevicePath；116/118/120/122/124-134/136-141/145-154 各映射), 75-86(标志采集), 993-998(-mlink-* 下发), 1106-1128(checkCommonBitcodeLibs；1117-1124 ABI), 1130-1167(getCommonBitcodeLibs；1140-1146 AddBCLib, 1147-1150 asanrtl 不内化, 1153-1164 链接序), 1169-1187, 1289-1290(opencl.bc)
- clang/include/clang/Driver/RocmInstallationDetector.h：18-34(DeviceLibABIVersion), 43-57(ConditionalLibrary), 139-147(字段注释), 221-263(getter 族)
- clang/include/clang/Driver/ToolChain.h：135-139(BitCodeLibraryInfo)
- clang/include/clang/Options/Options.td：8145-8150(mlink-builtin-bitcode/mlink-bitcode-file), 8268-8273(postopt)
- clang/lib/CodeGen/CodeGenAction.cpp：204-239(LinkInModules；222-229 内化回调), 295-297(默认 pre-opt 时机)
- clang/lib/CodeGen/BackendUtil.cpp：1103-1107(postopt 时机)
- clang/lib/CodeGen/LinkInModulesPass.cpp：19-29（全文已读）
- clang/lib/CodeGen/CGCall.cpp：2311-2319(可合并默认属性)
- clang/lib/Driver/ToolChains/Cuda.cpp：233-242(单份 libdevice 注释), 933-940(同选项下发)
- clang/lib/Driver/ToolChains/CommonArgs.cpp：2870-2960(libomptarget bc；2908 起 addOpenCLBuiltinsLib/libclc)
- clang/include/clang/Basic/BuiltinsAMDGPU.td：152
- llvm/include/llvm/IR/IntrinsicsAMDGPU.td：283-285(int_amdgcn_s_barrier)
- clang/lib/Headers/opencl-c.h：12399, 12402-12403
- 交叉引用：Clang-AMDGPU-notes/02-codegen.md §4.3（_Z7barrierj 实测）、03-languages.md（__clang_hip_libdevice_declares.h）、NVPTX-notes/02-ir-layer.md §3.1（NVVMReflect）

### Web（实取，amd-staging 分支）
- https://github.com/ROCm/ROCm-Device-Libs （已归档；README 指明迁往 ROCm/llvm-project amd/device-libs）
- https://github.com/ROCm/llvm-project/tree/amd-staging/amd/device-libs （目录树：asanrtl/cuda2gcn/hip/irif/ockl/ocml/oclc/opencl/doc/test/utils）
- https://raw.githubusercontent.com/ROCm/llvm-project/amd-staging/amd/device-libs/README.md （官方分工表与依赖关系）
- https://github.com/ROCm/llvm-project/tree/amd-staging/amd/device-libs/opencl/src/workgroup （wgbarrier.cl 所在；barrier 实现全文已读）
- https://github.com/ROCm/llvm-project/tree/amd-staging/amd/device-libs/ockl/src （32 文件清单）
- https://github.com/ROCm/llvm-project/tree/amd-staging/amd/device-libs/irif （仅 inc/，头文件库）
