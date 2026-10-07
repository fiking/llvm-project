# 05 · Clang TargetInfo 层的 AMDGPU 实现（§6 素材）

版本锚点：LLVM main @ 3eda2aebadd4（clang-24.0.0git，build-debug/bin/clang-24 实测）。
所有 文件:行号 均在本工作区实际核对；动态输出均为真实命令回放（§6.6）。
标注「锚点」者来自 01/02 章已核实结论，未重查。

---

## 6.1 AMDGPUTargetInfo 类结构

### 静态分析
- clang/lib/Basic/Targets/AMDGPU.h:29 `class LLVM_LIBRARY_VISIBILITY AMDGPUTargetInfo final : public TargetInfo`
  —— 直接继承 TargetInfo 且 `final`。
- **当前树不存在 GCNTargetInfo / R600TargetInfo 子类**（通读 507 行头文件确认）。
  AllocateTarget 处 clang/lib/Basic/Targets/Targets.cpp:437-439 `case amdgpu: case r600:`
  共用同一个 `std::make_unique<AMDGPUTargetInfo>(...)`。amdgcn/r600 差异全部内联为
  `getTriple().isAMDGCN()`（AMDGPU.h:52 等）与 `isR600(TT)`（AMDGPU.h:78-80）运行时分支，
  遍布 :101-102（指针宽）、:272-291（CPU 名解析）。
- 子类考古：Targets/AMDGPU.h 的诞生 commit 为 ebba59268208
  "Break up Targets.cpp into a header/impl pair per target type[NFCI]"；
  clang/lib/Basic/Targets.cpp 历史中 "GCNTargetInfo" 字符串仅见于 88e2bb40921f
  （AMDGCN-flavored SPIRV，2024-06）。旧 monolithic Targets.cpp 中 GCN/R600 子类
  何时被合并为单 final 类，未能定位（git -S 全历史搜索超时）→ **待验证**。

### 构造函数逐项（AMDGPU.cpp:195-256）
| # | 动作 | 行号 |
|---|---|---|
| 1 | GPUKind 初始化：amdgcn 时 Opts.CPU 空→从 triple subarch 反解（getGPUKindFromSubArch），否则 parseArchAMDGCN；r600→parseArchR600 | :198-202 |
| 2 | resetDataLayout()（amdgcn/r600 两套 datalayout 由基类按 triple 选） | :203 |
| 3 | AddrSpaceMap=&AMDGPUAddrSpaceMap（表本体 AMDGPU.cpp:31-63，锚点）；UseAddrSpaceMapMangling=true | :205-206 |
| 4 | HasAMDGPUTypes=true（AMDGPU 专属类型/AS 语法门控） | :207 |
| 5 | bf16：仅 amdgcn，BFloat16Width/Align=16（hasBFloat16Type= isAMDGCN，AMDGPU.h:133） | :209-213 |
| 6 | HasFastHalfType=true; HasFloat16=true（TODO 注释自认对不支持 half 的目标不真实） | :215-218 |
| 7 | WavefrontSize = FEAT_SUPPORTS_WAVE32 ? 32 : 64 | :219-222 |
| 8 | 指针宽度：PointerWidth←getPointerWidthV(Default)（AMDGPU.h:100-110：r600=32；private/local 恒 32；其余 64）；64 位时 LongWidth=64、SizeType=UnsignedLong 等全套改写 | :224-233 |
| 9 | MaxAtomicPromoteWidth = MaxAtomicInlineWidth = 64 | :235 |
| 10 | CUMode = !FEAT_SUPPORTS_WGP | :236-237 |
| 11 | ReadOnlyFeatures 插入 8 项 target-ID 只读 feature（image-insts/gws/xnack-support/sramecc-support…，GPUKind≠GK_NONE 时） | :239-244 |
| 12 | HalfArgsAndReturns=true | :245 |
| 13 | Xnack/SramEcc 显式状态 → OffloadArchFeatures（字段 AMDGPU.h:44-50） | :247-255 |

- **DLL 属性：不存在**。AMDGPU.h 无任何 dllimport/dllexport 覆写（grep "DLL|dll" 零命中）——
  device 侧无动态链接语义（代码经 offload bundler 打包），宿主 DLL 语义归 x86 Aux target。
- adjust()（AMDGPU.cpp:258-262）：基类 adjust 后按 LangOptions 重建 AtomicOpts。
- setAuxTarget（AMDGPU.cpp:341-371）：copyAuxTarget 后保留自己的 long double/float128
  表示（x86 80-bit 不被传染），并从 Aux 补 HasFloat128（连带 FIXME：设备码会误接受 __float128）。

### 动态验证
`-mcpu=gfx9999` → `error: invalid target ID 'gfx9999'; format is a processor name followed
by an optional colon-delimited list of features followed by an enable/disable sign
(e.g., 'gfx908:sramecc+:xnack-')`（校验链见 §6.5）。

### 设计动机
r600 已 EOL，为它维护平行类层次不划算；所有差异点都能在构造期由 triple+GPUKind 决定，
不需要虚分派——单 final 类 + 分支是最小维护成本解。

### 昇腾映射（推理，待验证）
CCE（bieng）非 clang TargetInfo 架构，类型宽度/原子宽度/半精度声明散落其前端；
同样无 DLL 概念（.o + 昇腾运行时加载）。

---

## 6.2 宏定义清单（getTargetDefines，AMDGPU.cpp:269-339）

| 宏 | 行号 | gfx1100 实测值 |
|---|---|---|
| __AMD__ / __AMDGPU__ | :271-272 | 1 / 1 |
| __AMDGCN__（r600 为 __R600__） | :274-277 | 1 |
| __HAS_FMAF__ / FP_FAST_FMAF / __HAS_LDEXPF__ / __HAS_FP64__ / FP_FAST_FMA / FP_FAST_FMA_HALF | :279-292（注释自标 deprecated） | FP_FAST_FMA_HALF 1（其余见注） |
| __AMDGCN_CUMODE__ | :294 | 0（WGP 模式） |
| __gfx1100__（型号宏；generic 名 '-'→'_'，如 gfx10-1-generic→gfx10_1_generic） | :301-309 | 1 |
| __GFX11__（家族宏，getArchFamilyNameAMDGCN().upper()） | :310-316 | 1 |
| __amdgcn_processor__ | :317-318 | "gfx1100" |
| __amdgcn_target_id__（getCanonicalTargetID + OffloadArchFeatures） | :319-324 | "gfx1100" |
| __amdgcn_feature_<f>__（仅显式 +/- 的 target-ID 特性，'-'→'_'） | :325-334 | gfx90a:sramecc+ → __amdgcn_feature_sramecc__ 1 |
| __AMDGCN_UNSAFE_FP_ATOMICS__（Opts.AtomicIgnoreDenormalMode） | :337-338 | -munsafe-fp-atomics 时 1 |

注：GK_NONE（dummy target）提前 return（:297-299），HIP host 例外（legacy 依赖）。
__HAS_FP64__/FP_FAST_FMA 按 :287-290 对 amdgcn 恒真，本次 grep 模式未覆盖，未单独回显
（r600 侧对照已证：cayman 无 __HAS_FP64__）。

### wave-size 宏：已不存在（关键结论）
- 任务假设的 `__WAVE_SIZE` 从未存在；真实宏 `__AMDGCN_WAVEFRONT_SIZE` /
  `__AMDGCN_WAVEFRONT_SIZE__` 也已于 2025-09 整体删除（本仓库全树 rg 零命中）。
- git 考古（已核）：
  - 36501b180a4f 加入 wavefront 宏（生成点即 getTargetDefines）；
  - ad96f25b9365（2023-06-30，D154207）补尾下划线成 `__AMDGCN_WAVEFRONT_SIZE__`，旧名暂留；
  - 02d3e6ac75e7（2025-09-15，#157463，SWDEV-522062）删除定义/测试/docs——commit message：
    改用 HIP 运行时 device 变量 `warpSize`（非 constexpr）或 host 侧 `hipGetDeviceProperties`；
    中途 78bf682cb903 revert、ea034477fd9b reapply（#164217）。2024-11 #112849/#115507 已预告弃用。
- 宏与后端 feature 联动现状：WavefrontSize 成员（AMDGPU.h:36）仅剩两消费点——
  getGridValue 的 OpenMP grid 值 <32>/<64> 模板分发（AMDGPU.h:400-409）与
  handleTargetFeatures 的 `+wavefrontsize64`（AMDGPU.h:468-469）。宏层零暴露。
- wave 的现行源码出口：`__builtin_amdgcn_wave_size()`（BuiltinsAMDGPU.def→
  AMDGPU.cpp:68-79 .inc 表，锚点 :66-70；使用例证
  clang/test/CodeGenOpenCL/builtins-amdgcn-wave32.cl，在删宏 commit 中同步改写）。

### 动态验证（gfx1100 vs gfx90a wave64 全量 diff）
391 个宏仅 5 行不同：__AMDGCN_CUMODE__ 0→1、__GFX11__→__GFX9__、
__amdgcn_processor__/__amdgcn_target_id__ 字符串、__gfx1100__→__gfx90a__。
**无任何 wave 相关差异行**（grep -i wave 两份 dump 均空）——gfx90a 锁步 wave64、
gfx1100 默认 wave32 的硬件差异在宏体系完全不可见。另 -mwavefrontsize64 于 gfx1100
前后 dump 完全一致（NO-MACRO-CHANGE）。

### 设计动机
- 型号+家族双层宏：库/头文件按家族一次特化（__GFX9__ 覆盖 906/908/90a）。
- target-id/feature 宏：二进制与实际 GPU 的可诊断匹配（xnack/sramecc 配错会静默降级）。
- wave 宏之死：gfx10 起 wave32/64 运行时可切换，编译期定值宏诱导错误特化→交给运行时。
- __HAS_* 6 个是 R600 时代（~2013）遗产。

### 昇腾映射（推理，待验证）
CCE 以 __CCE_AICORE__ 为核心宏体系。AICore（标量+向量+Cube 顺序核）无 SIMT wavefront
概念——AMDGPU 靠删宏解决的"编译期/运行期不符"问题在昇腾无载体；最接近的量是向量单元
lane 宽（如 910 向量 128 lane），推测不作为预定义宏暴露，lane 级语义走 Vector API/mask。

---

## 6.3 CallingConv 前端约定

### 前提纠偏
hook 真名是 **checkCallingConvention**（不存在 getCallingConvSupported）。AMDGPU 覆写
AMDGPU.h:432-440：default→CCCR_Warning；**CC_C、CC_DeviceKernel→CCCR_OK**（仅此两项）。

### 静态分析
- 前端 CallingConv 枚举（clang/include/clang/Basic/Specifiers.h:279-315）**没有任何 AMDGPU
  条目**；唯一 GPU 语义项 CC_DeviceKernel（:292，`__attribute__((device_kernel))`，
  不支持可变参 :319-334）。七种图形 CC（AMDGPU_PS/VS/GS/HS/LS/ES/CS）在前端类型系统
  层面不存在（02-codegen.md §4.2 已证其仅由后端 intrinsic/glue 产生）。
- **因此 TargetInfo 层 CC 表的意义 = 纯 Sema 源码属性校验**，与 IR CC 生成无关：
  - SemaDeclAttr.cpp:5930-6010：__attribute__((…)) 逐 target 查询；CUDA/HIP host+device
    双侧检查（:5934-5958）；SYCL 设备/host 联合裁决（:5959-5981）；CCCR_Warning→
    warn_cconv_unsupported 并回落默认 CC（:6003-6010）。
  - SemaLambda.cpp:1677：lambda 转函数指针 CC 检查。
- IR 侧映射在 CodeGen：getDeviceKernelCallingConv→llvm::CallingConv::AMDGPU_KERNEL
  （clang/lib/CodeGen/Targets/AMDGPU.cpp:478-480，锚点 :477-479）；AMDGPUABIInfo::computeInfo
  对 AMDGPU_KERNEL 走 classifyKernelArgumentType（:115-133, :185）。OpenCL 默认
  flat-work-group-size "1,256"（:375-384 锚点）、cluster "0,0,0"（:449-452 锚点）同文件。
- **isCLZForZeroUndef：AMDGPU 未覆写**，继承 TargetInfo.h:1048 默认 true（CLZ(0)=undef）。
  对照 NVPTX.h:72 覆写 false（CUDA 语义 CLZ(0)=32）。消费点：CGBuiltin.cpp:3493/3530
  （__builtin_clz/ctz poison-zero 决策）、CIR 侧 CIRGenBuiltin.cpp:95/1495/1626。

### 动态验证
`__attribute__((vectorcall)) void f(int);` 于 amdgcn →
`warning: 'vectorcall' calling convention is not supported for this target
[-Wignored-attributes]`（CCCR_Warning 路径命中，回落默认 CC）。

### 设计动机
"哪些源码级 CC 拼写合法"的白名单，把源码诊断（Sema）与 IR CC 生成（CodeGen）解耦；
图形 CC 属图形驱动 ABI（PAL/Vulkan），C/C++ 源码永不拼写，前端自然无条目。

### 昇腾映射（推理，待验证）
CCE 核函数（__global__）ABI 由 aic/aiv 核类型+启动参数结构决定，无多 CC 属性表；
昇腾无图形管线，图形 CC 无对应物；x86 系属性的报错级别（警告 vs 错误）待验证。

---

## 6.4 半精度支持链

### 声明侧（TargetInfo）
HasFloat16=true、HasFastHalfType=true（AMDGPU.cpp:217-218）、HalfArgsAndReturns=true
（:245；字段 TargetInfo.h:240，默认 false TargetInfo.cpp:75，hook TargetInfo.h:708）。
消费链（全部已核）：
1. Sema 形参/返回值：SemaType.cpp:2614-2620（half 返回值错误，除非 NativeHalfArgsAndReturns
   或 allowHalfArgsAndReturns()）、:2732-2733、:5076-5077、:5338-5339。
2. half 字面量：LiteralSupport.cpp:1087。
3. __FLT16_* 宏：InitPreprocessor.cpp:1254-1255。
4. 过精度：Type.cpp:1781-1788——HasFastHalfType=true 使 half 不被 excess precision
   提升到 float（GCN3+ 全速率原生 f16）。
5. CodeGen 对账：CodeGenModule.cpp:511-513。

### OpenCL / HIP 可用性差异
- OpenCL：setSupportedOpenCLOpts（AMDGPU.h:293-347）中 `cl_khr_fp16=true` **仅在
  IsAMDGCN 分支**（:315-316）；r600 无。cl_khr_fp64/__opencl_c_fp64=hasFP64()=isAMDGCN
  （:304-305 + :52）；依赖闭包 TargetInfo.cpp:679-688。
- HIP：HasFloat16/HalfArgsAndReturns 不分 triple 无条件为真（r600 无原生 f16 是 :215-217
  TODO 自认的谎言，但 r600 无 HIP 生态，代价为零）。

### FP_CONTRACT 纠偏
`#pragma STDC FP_CONTRACT` 是通用前端设施（ParsePragma.cpp:100-104），**不是 TargetInfo
hook**。TargetInfo 层相关的只有 FP_FAST_FMA/FMAF/FMA_HALF 三宏（AMDGPU.cpp:283-292，
glibc <math.h> 约定）；CodeGen 侧另有非 IEEE 模式挂 `amdgpu-ieee=false`
（clang/lib/CodeGen/Targets/AMDGPU.cpp:472-473）。

### printf 的 half
- 分发：CGBuiltin.cpp:6700-6712——BIprintf 且 isAMDGCN()（或 AMD-flavored SPIRV）且
  **LangOpts.HIP** → EmitAMDGPUDevicePrintfCallExpr。OpenCL printf 走内置库常规调用。
- CGGPUBuiltin.cpp:158-192：非标量可变参 ErrorUnsupported（:174-178）；
  AMDGPUPrintfKindVal==Buffered 选模式（:187-188）→ llvm::emitAMDGPUPrintfCall（:189）。
- **提升点**：llvm/lib/Transforms/Utils/AMDGPUEmitPrintf.cpp:352-369 processNonStringArg——
  `isFloatingPointTy() && allocSize<8 → CreateFPExt(Arg, DoubleTy)`（:362-366）。
  **half/bf16 printf 参数先 FPExt 到 double 再入缓冲区**，host 侧按 double 解码。
  buffered 路径已逐行核对；非 buffered（hostcall）路径同理（未逐行核，待验证）。

### 动态验证（OpenCL）
`--target=amdgcn-amd-amdhsa -mcpu=gfx1100 -cl-std=CL3.0 -x cl -dM -E` →
`cl_khr_fp16 1`、`cl_khr_subgroups 1`、`__opencl_c_generic_address_space 1`、
`__opencl_subgroup_builtins 1` + 全套 __FLT16_*（MANT_DIG 11、MAX 6.5504e+4F16、
DENORM_MIN 5.9604644775390625e-8F16 …）。

### 设计动机
GCN3+ half 是全速率一等公民→声明链全开，让数学库写真 f16 内核；printf 的 FPExt→double
是经典妥协：设备端只打包标量，浮点格式解释全部推迟到 host。

### 昇腾映射（推理，待验证）
昇腾 fp16 是算力主力 dtype，CCE 应同样放行 half 形参/返回值；设备 printf 同样需提升
精度（目标 float vs double 待验证）；Cube 单元的 fp16 语义由 matmul 高阶 API 而非语言
内建类型承载，与 AMDGPU「语言级 half + 任意表达式」路线不同。

---

## 6.5 amdgcn vs amdgpu 双名与 -mcpu 落地

### 结论：无分流
- Triple 枚举只剩 `Triple::amdgpu` 与 `Triple::r600`：llvm/include/llvm/TargetParser/Triple.h:992
  `isAMDGCN() { return getArch() == Triple::amdgpu; }`（:994 isAMDGPU= isAMDGCN||r600）。
- "amdgcn" 是输入别名：Triple.cpp:636-638 `.StartsWith("amdgpu",amdgpu)`/
  `.Case("amdgcn",amdgpu)`；:483 `.Case("amdgcn", amdgpu) // Legacy name`。
- 反向：Triple.cpp:298-302 `case amdgpu: return "amdgcn"; // Intrinsics use amdgcn prefix`
  ——**Triple 层正名 amdgpu，语义层（llvm.amdgcn.* 前缀、__AMDGCN__、__amdgcn_processor__）
  保留 amdgcn**。与后端正名考古（01-architecture.md：24a5231188bf；cc1 测试改名
  3b6e754c0a04 "(14)"）互为表里：改名只动 triple/enum 域。
- Driver 规范化：clang/lib/Driver/ToolChains/Arch/AMDGPU.cpp:20-42 setArchNameInTriple——
  amdgcnspirv→spirv64（:27-30）；:34-38 "Normalize legacy amdgcn triples to amdgpu"；
  :40-41 把 -mcpu 的 GPUKind 写成 triple subarch。Darwin.cpp:69 `.Cases({"amdgpu","amdgcn"},amdgpu)`；
  -Xarch_amdgcn 全 subarch 接受（ToolChain.cpp:2164）。

### 动态验证
`--target=amdgcn-amd-amdhsa` 与 `--target=amdgpu-amd-amdhsa`（同 -mcpu=gfx1100）：
-### 产生的 cc1 命令行完全一致，均为 `"-triple" "amdgpu11.00-amd-amdhsa"`；
-dM 全量宏 diff 为空（IDENTICAL）。-march=gfx1100 等价可用。
（注：-ccc-print-host-triple 已不被本 clang-24 接受，改用 -###。）

### -mcpu 在 TargetInfo 的落地
- 构造期：Opts.CPU→parseArchAMDGCN（AMDGPU.cpp:198-202）；triple subarch→GPUKind。
- isValidCPUName（AMDGPU.h:271-278）：amdgcn→`isCPUValidForSubArch(subarch, Name) &&
  !isPseudoTarget(Name)`；r600→parseArchR600!=GK_NONE。
- setCPU（AMDGPU.h:282-291）：解析入 GPUKind 成员，同款校验。
- fillValidCPUList（AMDGPU.cpp:187-193）→fillValidArchListAMDGCN。
- initFeatureMap（AMDGPU.cpp:163-185）：基类吃 +/- feature（TargetInfo.cpp:590-602）→
  fillAMDGPUFeatureMap（TargetParser 共享），诊断分类 INVALID_FEATURE_COMBINATION（:176-178）/
  UNSUPPORTED_TARGET_FEATURE（:179-181）。
- handleTargetFeatures（AMDGPU.h:461-484）：`+wavefrontsize64`→WavefrontSize（:468-469）、
  ±cumode→CUMode（:470-473）、`+image-insts`→HasImage（:474-475，hasHIPImageSupport :493）、
  HasFullBFloat16=true（:463）、Target-ID 特性记入 OffloadArchFeatures（:476-482）。
- 实测：`-mcpu=gfx90a:sramecc+`→`__amdgcn_feature_sramecc__ 1`、
  `__amdgcn_target_id__ "gfx90a:sramecc+"`；`-mcpu=gfx9999`→invalid target ID 错误；
  r600-unknown-linux-gnu -mcpu=cayman→`__AMD__ 1`、`__HAS_FMAF__ 1`、`__R600__ 1`（无 fp64）。

### 设计动机
amdgcn 在生态铺得太广，正名只能「新名归一、旧名永远接受」；subarch 编码进 triple 让
cc1 无需额外参数即可完整重建目标（bundler/缓存 key 要求 triple 自含）。

### 昇腾映射（推理，待验证）
CCE 用 --soc-version/--ai-core 直接传值，无 triple 字符串体系；SoC 型号是否有编译期宏
待查；无 target-ID 式特性开关，硬件配置差异走运行时 API。

---

## 6.6 动态验证记录（真实输出）

环境：build-debug/bin/clang-24（clang version 24.0.0git @3eda2aebadd4）。
1. gfx1100 全量宏（-dM -E | sort）：391 行；关键行见 §6.2 表；无任何 wave 宏。
2. gfx1100 vs gfx90a：全量 diff 仅 5 行（CUMODE/GFX 家族/processor/target-id/型号）。
3. amdgpu vs amdgcn triple：宏 dump 完全一致；cc1 triple 均 amdgpu11.00-amd-amdhsa。
4. -mcpu=gfx9999：invalid target ID 错误（格式提示含 gfx908:sramecc+:xnack- 示例）。
5. -mcpu=gfx90a:sramecc+：__amdgcn_feature_sramecc__ 1、target_id "gfx90a:sramecc+"。
6. -munsafe-fp-atomics：__AMDGCN_UNSAFE_FP_ATOMICS__ 1。
7. -mwavefrontsize64：宏 dump 无变化。
8. r600/cayman：__AMD__、__HAS_FMAF__、__R600__，无 __HAS_FP64__。
9. OpenCL CL3.0：cl_khr_fp16/cl_khr_subgroups/__opencl_c_generic_address_space=1 + __FLT16_*。
10. vectorcall 属性：warning not supported for this target（-Wignored-attributes）。
（中间产物：scratch/defs_gfx1100.txt、defs_gfx90a.txt、defs_amdgpu_triple.txt、defs_w64.txt）

---

## 6.7 昇腾映射总表（推理级，全部待验证）

| AMDGPU TargetInfo 概念 | 位置 | 昇腾 CCE 对应（待验证） |
|---|---|---|
| __AMDGCN__/__AMDGPU__/__AMD__ | AMDGPU.cpp:271-277 | __CCE_AICORE__ 系预定义宏 |
| __gfx1100__ + __GFX11__ 双层 | :301-316 | SoC 型号宏（910/310P 系）待查；倾向运行时查询 |
| __amdgcn_target_id__/feature 宏 | :319-334 | 无对应物（无 xnack/sramecc 式开关） |
| __AMDGCN_WAVEFRONT_SIZE（已删） | 36501b180a4f→02d3e6ac75e7 | 无对应物：顺序核无 wavefront |
| WavefrontSize→getGridValue | AMDGPU.h:36,400-409 | 无对应物：块调度由运行时决定 |
| checkCallingConvention 白名单 | AMDGPU.h:432-440 | 无多 CC 表；ABI 由 aic/aiv 核类型决定 |
| CC_DeviceKernel→AMDGPU_KERNEL | Specifiers.h:292 + CodeGen/AMDGPU.cpp:478-480 | __global__ 直连 AICore 启动 ABI |
| isCLZForZeroUndef=true（默认继承） | TargetInfo.h:1048 | CLZ 零值语义与 poison 约定待查 |
| HasFloat16/HalfArgsAndReturns | AMDGPU.cpp:217-218,245 | fp16 主力 dtype，应全放行，声明点待查 |
| cl_khr_fp16 仅 amdgcn | AMDGPU.h:315-316 | CCE 方言 fp16 声明待查 |
| printf half→FPExt double | AMDGPUEmitPrintf.cpp:362-366 | 需同样提升（目标精度待验证） |
| amdgcn 别名→amdgpu 归一 | Triple.cpp:636-638 + Arch/AMDGPU.cpp:34-38 | 无 triple 体系；--soc-version 直接传值 |
| setCPU/isValidCPUName | AMDGPU.h:271-291 | --soc-version 值域校验行为待验证 |

核心推断：AMDGPU 宏体系服务三件事——家族特化、二进制/GPU 匹配校验、（曾经的）执行
配置特化；昇腾因无 SIMT wave、无 target-ID 特性开关，只剩「型号区分」一项且倾向运行时
查询，CCE 宏面预计显著小于 AMDGPU。

---

## 引用清单

源码（本工作区实测行号）：
- clang/lib/Basic/Targets/AMDGPU.h: 29, 31-50, 52-76, 78-92, 100-131, 133, 154-255, 264-269,
  271-291, 293-347(296-321), 349-398, 400-430, 432-440, 445-453, 457-501
- clang/lib/Basic/Targets/AMDGPU.cpp: 31-63(锚), 68-80(锚 66-70), 82-161, 163-193, 195-267,
  269-339, 341-371
- clang/lib/Basic/Targets/Targets.cpp: 437-439
- clang/lib/Basic/TargetInfo.cpp: 75, 590-602, 648-654, 679-688
- clang/include/clang/Basic/TargetInfo.h: 240, 708, 1048
- clang/include/clang/Basic/Specifiers.h: 279-315(292), 319-334
- clang/lib/Sema/SemaDeclAttr.cpp: 5930-6010；SemaLambda.cpp: 1677；SemaType.cpp: 2614-2620,
  2732-2733, 5076-5077, 5338-5339
- clang/lib/Lex/LiteralSupport.cpp: 1087；clang/lib/Frontend/InitPreprocessor.cpp: 1254-1255
- clang/lib/AST/Type.cpp: 1781-1788
- clang/lib/Parse/ParsePragma.cpp: 100-104
- clang/lib/CodeGen/CGBuiltin.cpp: 6700-6712；CGGPUBuiltin.cpp: 106-192；CodeGenModule.cpp: 511-513
- clang/lib/CodeGen/Targets/AMDGPU.cpp: 115-133, 185, 294, 472-473, 478-480(锚 477-479),
  483-497(锚 getNullPointer), 375-384/449-452(锚 flat-work-group-size/cluster)
- llvm/lib/Transforms/Utils/AMDGPUEmitPrintf.cpp: 352-369(362-366), 425
- llvm/include/llvm/TargetParser/Triple.h: 992, 994
- llvm/lib/TargetParser/Triple.cpp: 298-302, 483, 636-638
- clang/lib/Driver/ToolChains/Arch/AMDGPU.cpp: 20-42；Darwin.cpp: 69；ToolChain.cpp: 2164；
  CommonArgs.cpp: 728, 868

git 提交（本仓库核实）：ebba59268208（Targets.cpp 拆分）；36501b180a4f（wave 宏加入）；
ad96f25b9365（D154207 改名）；02d3e6ac75e7 / ea034477fd9b / 78bf682cb903（删除/reapply/revert）；
3b6e754c0a04（cc1 测试 amdgcn→amdgpu）；24a5231188bf（正名，引自 01-architecture.md 锚点）。

待验证项：GCN/R600 子类合并 commit；GCN TargetID.cpp 错误 diag 行号；非 buffered printf
half 提升路径；§6.7 全部昇腾条目。