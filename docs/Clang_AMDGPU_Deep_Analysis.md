# clang→AMDGPU 前端路径深度分析

> 数据基准：llvm-project main @ `3eda2aebadd4`（2026-09-29），clang-24 @ build-debug 实测。
> 方法：静态分析（引用一律 `文件:行号`，全部经 grep/read 核对）+ 动态验证（-### 工具链、-emit-llvm IR 形态、-dM -E 宏导出、双 mcpu diff）。
> 四部曲定位：`nvptx-vs-amdgpu-analysis.md`（横向对比）→ `AMDGPU_Deep_Analysis.md`（后端·内闭环）→ `NVPTX_Deep_Analysis.md`（后端·虚拟 ISA）→ **本文档（前端：语言如何落到 amdgcn）**。
> 素材全文：`Clang-AMDGPU-notes/01..06-*.md`（约 1200 行）；scratch/ 存实测产物。

---

## 目录

- §1 摘要与核心论点
- §2 Driver 层（ROCm 探测/device lib/工具链集成）
- §3 语言层（OpenCL vs HIP 双路径）
- §4 CodeGen 五大映射（AS/kernel CC/barrier/printf/atomic）
- §5 device library 生态（ocml/ockl/oclc/opencl）
- §6 TargetInfo（宏体系/CC 校验/半精度链）
- §7 intrinsic 头三层（generic/AMDGCN/builtin）
- §8 与 NVPTX 前端路径对偶表
- §9 昇腾映射
- §10 复现手册

---

## §1 摘要与核心论点

> **前端是范式的第一现场**：后端 65 pass 消费的每个决策（uniformity/AS/资源预算）都在 clang CodeGen 定型。但实测推翻了"前端深度介入"的预期——**clang 对 OpenCL 的介入薄得惊人**：AS 映射是唯一深度介入（表驱动直译），barrier/printf/atomic 全部是外部调用+库层实现，语义翻译主体在 ROCm 设备库而非编译器。

**五个贯穿性实证**：
1. **OpenCL 元数据五件套 + amdgpu_kernel CC + AS1** 在 -emit-llvm 一次可见（CodeGen 的全部产出）
2. **barrier 是外部调用**（`_Z7barrierj` C++ mangling）→ opencl.bc 的 wgbarrier.cl 实现 → `__builtin_amdgcn_s_barrier()`——三层接力
3. **printf 的 hostcall 协议在头文件 inline** 里（`__printf_alloc` + null 检查 + 打包）
4. **图形七种 CC 前端零产生**（clang/lib 零匹配）——Mesa 在 IR 层用
5. **正反对照**：`__gpu_sync_threads()` intrinsic 直通（后端可精确建模）vs OpenCL `barrier()` 库调用——builtin 与语言声明的分界决定后端建模能力

---

## §2 Driver 层

**详见 `01-driver.md`**（8 级 ROCm 探测链/getCommonBitcodeLibs 六家族/双 Linker/target id 解析）

- **8 级探测**：--rocm-path（非严格）→ ROCM_PATH → 二进制目录回推（严格）→ 符号链接真实路径 → ResourceDir → /opt/rocm → 最新 /opt/rocm-{release} → /usr
- **报错链**：checkCommonBitcodeLibs（:1106-1128）err_drv_no_rocm_device_lib 三形态；**-nogpulib 三作用点**（marshalling/砍 mlink/免报错——实测 fake rocm-path 加 -nogpulib 不再报错）
- **subarch 进 triple**（实测 gfx1100→`amdgpu11.00-amd-amdhsa`、gfx1100a→无 subarch）；**normalizeForBundler 强制 amdgcn- 前缀**（HIP runtime 解析器硬编码——正名的下游断点）
- **amdgpu::Linker 默认 ld.lld** + `-plugin-opt=-mattr=<target-id features>`；HIP 的 AMDGCN::Linker 走 bundler（-bundle-align=4096）vs NVPTX 专用 fatbinary 格式
- 死代码：NoBuiltinLibs 字段全树无赋值；**--no-gpu-args 本树不存在**（ROCm fork 特有）

## §3 语言层

**详见 `03-languages.md`**（205 行完整分析）

- **OpenCL 是"另一种语言"**：厚在 Sema（SemaOpenCL + OpenCLBuiltins.td 2354 行→17,264 行 .inc + opencl-c.h 18k 行），CodeGen 极薄（159 行仅类型翻译/管道 glue）
- **HIP 是"同一种语言"**：**零专属 CodeGen 文件**——CUDA 前端机 + 6 个属性宏 + 头文件（3,365 行）；-fgpu-rdc 的链接范式切换（InternalLinkage 换 IPO vs WeakODR）有源码注释直证
- **hip_math 分发是预处理器宏**（`__FAST_OR_SLOW`）非 constexpr if；三层：builtin_amdgcn（内联 ISA）/`__ocml_*`（库）/通用 builtin；**不存在 __clang_gpu_math**——共享层是 __clang_gpu_device_functions.h（HIP/CUDA 双开）
- **结论**：OpenCL 贴内存模型，HIP 贴指令层（CUDA 兼容包袱有注释证据："for compatibility with CUDA"）

## §4 CodeGen 五大映射

**详见 `02-codegen.md`**

| 映射 | 前端介入深度 | 实测证据 |
|---|---|---|
| AS 限定符 | **深**（表驱动直译） | AMDGPUAddrSpaceMap（Targets/AMDGPU.cpp:31-63）含 amdgpu_barrier→BARRIER=15 的前端来源；getNullPointer 用 generic null+addrspacecast |
| kernel CC | 中（一行判断链） | Attr.td→ParseDecl→SemaDeclAttr→CGCall→AMDGPU_KERNEL(=91)；**图形 CC 零产生**（Mesa IR 层生态） |
| barrier | **零**（外部调用） | `tail call void @_Z7barrierj(i32)` #4——库接力 |
| printf | **零+头文件层** | `@__printf_alloc(8)`+null 检查+打包（opencl-c.h inline 的 hostcall 协议） |
| atomic | 零（枚举 i32 透传） | `@_Z22atomic_work_item_fencej...(4,3,2)` |

**附加**：OpenCL kernel stub 机制（`__clang_ocl_kern_imp_` 前缀+AlwaysInline，实测 IR 可见）；printf_buffer=72/hostcall=80 的 implicit arg 偏移。

## §5 device library 生态

**详见 `04-devlib.md`**（233 行，Web+源码双重核实）

- **六家族链接清单**：asanrtl（ASan）→ocml（数学）→ockl（kernel 运行时，OpenMP 跳过）→oclc 配置位×5→libdevice→oclc_abi_version；OpenCL 专属 opencl.bc
- **两处勘误**：barrier 实现在 **opencl 库**（wgbarrier.cl，Web 实取全文）而非 ockl；第五库是 **irif**（仅头文件）非 "irdl"
- **barrier 完整故事**：前端外部调用 → opencl.bc wgbarrier.cl → `__builtin_amdgcn_s_barrier()`（源码直证）——**解释了前端为何不需要 intrinsic**
- **两种配置哲学**：oclc"多份预编译 .bc 链接时选一"（finite_only_on/off × isa_version_XXX × abi_version 组合爆炸用文件管理）vs NVVMReflect"一份 .bc 编译期求值"——PyPTO tile 特性开关的选型参照

## §6 TargetInfo

**详见 `05-targetinfo.md`**（329 行完整成稿）

- **单类无双类**：AMDGPUTargetInfo final（AMDGPU.h:29）内联 isAMDGCN() 分支——GCNTargetInfo/R600TargetInfo 子类已不存在；DLL 属性完全没有
- **wave 宏已死**：`__AMDGCN_WAVEFRONT_SIZE` 2025-09 被整体删除（考古链全核）；gfx1100 vs gfx90a 全量 391 宏 diff 仅 5 行，**wave64 vs wave32 零宏足迹**——wave 尺寸对前端完全透明（正确的抽象层次）
- **CC 校验纯 Sema**：checkCallingConvention（AMDGPU.h:432-440）只放行 CC_C/CC_DeviceKernel；前端 CallingConv 枚举无图形 CC 条目
- **半精度三开**：HasFloat16/HasFastHalfType/HalfArgsAndReturns；printf half 走 HIP-only 链（AMDGPUEmitPrintf.cpp:362-366 FPExt→double）

## §7 intrinsic 头三层

**详见 `06-intrinsics.md`**

```
① gpuintrin.h（348 行，generic：OpenMP/HIP/CUDA/OpenCL 共享 __gpu_*）
② amdgpuintrin.h（164 行，AMDGCN 实现：__gpu_lane_id=mbcnt_hi 等 14 项映射）
③ 裸 __builtin_amdgcn_*（BuiltinsAMDGPU.td 851 def，已 TableGen 化）
```
- **双向绑定**：后端 `ClangBuiltin<"__builtin_amdgcn_X">` 一行 → TableGen 生成查表 → 前端 getIntrinsicForClangBuiltin 直查——**新增原语 = 前后端各一行 td**
- **数量不对称**：后端 600 int_amdgcn vs 前端 851 builtin（多对一合成）
- **实测**：immarg 生效、重载实例化（readfirstlane）、宏体系（__amdgcn_processor__="gfx906"）、HIP 直连 builtin 的 SemaCUDA 摩擦负结果

---

## §8 与 NVPTX 前端路径对偶表

| 层 | clang-AMDGPU（本文档） | clang-NVPTX（NVPTX-notes 对照） |
|---|---|---|
| Driver 探测 | ROCmInstallation 8 级链 + device lib 扫描 | CUDAInstallation（报错更宽松，libdevice 单文件） |
| device lib | 六家族 .bc 内链（-mlink-builtin-bitcode 多文件） | 单一 libdevice.10.bc（一份服务全代） |
| 配置分发 | **多份预编译 .bc**（oclc_on/off × isa × abi） | **一份 + NVVMReflect 编译期求值** |
| 数学库 | ocml（__ocml_* 库调用） | libdevice（__nv_ 库调用 + reflect） |
| 语言 | OpenCL（Sema 厚/CodeGen 薄）+ HIP（零 CodeGen 专属） | CUDA C++（nvcc 兼容机 + nvptxintrin.h 三重门卫） |
| 同步原语 | OpenCL barrier=库调用；__gpu_sync_threads=intrinsic 直通 | __syncthreads=编译器 builtin |
| intrinsic 层 | 三层（generic/amdgpuintrin/裸 builtin，TableGen 化） | 三重门卫头（__NVPTX__ 隔离） |
| 正名进度 | amdgcn→amdgpu 进行中（bundler 仍强制 amdgcn- 前缀） | 无此问题（nvptx 从未改名） |

## §9 昇腾映射

（综合三份文档的昇腾素材 + 本文档新证据，推理级标注"待验证"）

1. **CCE 的探测链类比**：`ASCEND_TOOLKIT_HOME`/默认 `/usr/local/Ascend/ascend-toolkit/latest` ≈ ROCmInstallation 8 级链——但**昇腾设备库走离线编译而非 bitcode 内链**（结构差异大于相似）
2. **"语义翻译主体在设备库"的启示**：AMDGPU 的 barrier/printf/atomic 全在库层（opencl.bc/ocml），编译器只管 AS/CC 映射——**CCE 若同构，则用户看到的"语言"其实是"编译器+隐形库"的复合体**，PyPTO 替代层可以只在库层做（不必动前端）
3. **builtin vs 库调用的分界是后端建模能力**：intrinsic 直通（s_barrier）让后端精确建模同步交互（Waitcnts 联动）；库调用则后端只见外部调用——**PyPTO tile 原语应做成"intrinsic 级"（编译器一等公民）而非库函数**，否则后端无法优化
4. **双向绑定模式**（§7）：pto-isa 加新 tile 指令 → Python 绑定一行 + C++ td 一行 → TableGen 生成查表——**新增原语的工程成本最小化模板**
5. **tiling 参数的前端入口**：AMDGPU 的 kernel 属性（flat-work-group-size/cluster）走 fn attr（前端可设置）；CANN 选了独立 .json 通道（NVPTX-notes §8.6 已析）——**PyPTO 的 tiling 若要参与编译期优化（而非运行时配置），必须走前端 attr 路线**
6. **wave 宏删除的抽象教训**（§6）：wave64/32 对前端零暴露是正确设计——PyPTO 的 m200/m300 差异（repeat 行为/UB 尺寸）同样不应泄漏到 Python 层，应止步于 tile 语义

## §10 复现手册

```bash
cd ~/code/llvm-project   # main @ 3eda2aebadd4
CL=build-debug/bin/clang-24

# 冒烟 + IR 形态（CodeGen 五映射一次可见）
printf 'kernel void k(global int* p) { p[0] = 1; }\n' > /tmp/t.cl
$CL --target=amdgcn-amd-amdhsa -mcpu=gfx1100 -nogpulib -S -emit-llvm -o - /tmp/t.cl

# §2 Driver：triple 对比 / fake rocm / HIP 双报错
$CL -### --target=amdgcn-amd-amdhsa -mcpu=gfx1100 -nogpulib -c /tmp/t.cl 2>&1 | grep -oE '"-triple" "[^"]*"'
$CL -### --target=amdgcn-amd-amdhsa -mcpu=gfx1100 --rocm-path=/tmp/fake -c /tmp/t.cl 2>&1 | grep error
printf '__global__ void k() {}\n' > /tmp/h.hip
$CL -### --target=x86_64-apple-darwin --offload-arch=gfx1100 -c /tmp/h.hip 2>&1 | grep error

# §4 五映射：barrier/printf/atomic 外部调用实证
$CL --target=amdgcn-amd-amdhsa -mcpu=gfx1100 -nogpulib -cl-std=CL2.0 -S -emit-llvm -o - Clang-AMDGPU-notes/scratch/sync2.cl | grep -E "call.*barrier|printf_alloc|atomic_work"

# §5 barrier 库接力（-nogpulib 下汇编只剩未解析符号）
$CL --target=amdgcn-amd-amdhsa -mcpu=gfx1100 -nogpulib -cl-std=CL2.0 -S -o - Clang-AMDGPU-notes/scratch/sync2.cl | grep work_group_barrier

# §6 宏体系 + wave 零足迹
$CL --target=amdgcn-amd-amdhsa -mcpu=gfx1100 -nogpulib -dM -E -x cl /tmp/t.cl 2>/dev/null | grep -c WAVE   # 0
$CL --target=amdgcn-amd-amdhsa -mcpu=gfx1100 -nogpulib -dM -E -x cl /tmp/t.cl 2>/dev/null | grep __AMDGCN__

# §7 intrinsic 直通 vs 库调用对照
$CL --target=amdgcn-amd-amdhsa -mcpu=gfx1100 -nogpulib -S -emit-llvm -o - Clang-AMDGPU-notes/scratch/intr/sleep.cl | grep "llvm.amdgcn"
```

---

## 附录：章节-素材对照与执行注记

| 章 | 素材 | 行数 | 产出方式 |
|---|---|---|---|
| §2 | 01-driver.md | — | 子代理调研+主会话 4 组验证代写 |
| §3 | 03-languages.md | 205 | 子代理完整成稿提取 |
| §4 | 02-codegen.md | — | 子代理调研（负结果）+主会话验证代写 |
| §5 | 04-devlib.md | 233 | 子代理成稿提取（Web+源码双核） |
| §6 | 05-targetinfo.md | 329 | 子代理成稿提取 |
| §7 | 06-intrinsics.md | — | 子代理调研（三证伪）+主会话代写 |

执行注记：1 主会话 + 6 子代理实例。子代理 6/6 均因额度耗尽未写盘（任务书本身含大量核查点，"调研与写作分离"再次成为稳定模式——summary 全文提取 3 次、主会话代写 3 次）。所有引用经实际核对；动态验证全实跑（-###×5 组、-emit-llvm×8 用例、-dM -E 宏导出、391 宏 diff）。三处任务假设被证伪修正（amdgcn.h→amdgpuintrin.h、BuiltinsAMDGPU.def→.td、__is_cpp_global 不存在）+ 两处库勘误（barrier 在 opencl 库、irif 非 irdl）。
