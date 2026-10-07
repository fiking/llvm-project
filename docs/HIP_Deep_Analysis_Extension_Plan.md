# HIP 深度分析：代码检视与扩展方案

> 日期：2026-10-03。
> 检视对象：[HIP_Deep_Analysis.md](HIP_Deep_Analysis.md)、[HIP-notes](HIP-notes/) 及其现有实验记录。
> 源码基准：`3eda2aebadd430199a1d588b6b22c966af5356d5`。
> 本次交付：现有结论的检视、扩展章节设计、源码与测试入口、实验及验收方案。完整 HIP 运行时和 GPU 执行研究属于后续工作。

## 1. 检视结论与扩展目标

现稿建立了 HIP 与 Clang CUDA 基础设施之间的联系，也找到了 Driver、头文件和架构探测的主要入口。但正文以结论摘要为主，尚缺少从源程序、AST、IR、设备镜像到运行时调用的连续证据；部分结论又超出了源码检索和 `-###` 所能证明的范围。

扩展应分两步：先修订可被源码反例否定的结论，再补全编译器到运行时接口之间的关键链条。建议以如下表述替换现稿的中心论点：

> HIP 复用 Clang 的 CUDA 语言基础设施，同时具有分布在语言默认值、语义检查、目标 ABI、代码生成、工具链和运行时接口中的专门处理。理解这种复用，需要沿具体程序追踪共享实现及分叉条件。

最终正文应回答：

1. HIP 属性、kernel launch、host/device 调用约束怎样进入 AST 和 Sema？
2. 一次 `kernel<<<...>>>(...)` 如何变成 host stub、参数传递和运行时调用？
3. AMDGPU kernel 的调用约定、地址空间、参数布局和元数据怎样形成？
4. 不同 RDC、编译阶段和 target 组合如何改变链接、打包及注册路径？
5. 头文件、设备 bitcode、宿主运行时分别提供哪些实现？
6. LLVM 仓库能验证到哪一层；哪些结论必须取得外部 SDK、运行时源码或 GPU 才能验证？

## 2. 优先修订清单

下列行号以本次基准为准；“P0”表示会改变文章核心论点或架构判断，“P1”表示需要收窄范围或补足证据。

### R1 · P0：撤下“语言机器 100% 复用”和封闭的分支数量

**原位置**：正文第 26、39–43、78、87 行；素材 `01-reuse-audit.md`。

`Opts.CUDA = Lang == Language::CUDA || Opts.HIP` 说明共享语言模式。它无法证明语义完全一致；两个文件内的 `HIP` 命中或人工归并数量也无法表示整个前端的差异数。

直接反例：

| 差异 | 代码依据 | 现有测试 |
|---|---|---|
| HIP/CUDA 默认浮点收缩策略不同 | [LangOptions.cpp](clang/lib/Basic/LangOptions.cpp)，217–227 行 | [fp-contract.cu](clang/test/CodeGenCUDA/fp-contract.cu) |
| HIP 设备侧零长度数组诊断 | [SemaDecl.cpp](clang/lib/Sema/SemaDecl.cpp)，9183–9192 行 | [zero-sized-device-array.hip](clang/test/SemaHIP/zero-sized-device-array.hip) |
| HIP builtin 的特定指针地址空间转换 | [SemaExpr.cpp](clang/lib/Sema/SemaExpr.cpp)，7101–7134 行 | [hip-builtin-lvalue-to-rvalue.hip](clang/test/SemaHIP/hip-builtin-lvalue-to-rvalue.hip) |
| HIP 设备初始化函数生成 kernel | [CGDeclCXX.cpp](clang/lib/CodeGen/CGDeclCXX.cpp)，818–824、979–985 行 | [device-init-fun.cu](clang/test/CodeGenCUDA/device-init-fun.cu) |

**修改建议**：将“11/13 处差异”降为有明确文件范围、检索方法和版本的局部索引；注释命中与执行分支分开。用“共享机制—分叉条件—可观察结果”表替代百分比。

### R2 · P0：删除“移植只需三类语义、≤14 分支”的预算推断

**原位置**：正文第 43、92 行；素材 `01-reuse-audit.md` 第 2.7 节。

目标适配还涉及：

- [Targets/AMDGPU.cpp](clang/lib/CodeGen/Targets/AMDGPU.cpp) 185–214 行的 kernel 参数分类，以及 HIP 指针参数到全局地址空间的转换。
- 同文件 348–394 行的 `__launch_bounds__` 解释与目标属性优先级。
- [CGExpr.cpp](clang/lib/CodeGen/CGExpr.cpp) 7301–7310 行的间接 kernel handle 到 stub 加载。
- [CGCUDANV.cpp](clang/lib/CodeGen/CGCUDANV.cpp) 581–604、694–728 行的 managed 变量改写与注册。

**修改建议**：移植讨论改为适配清单，覆盖执行模型、地址空间、参数 ABI、内存模型、属性、初始化、启动及注册。每项都需目标平台资料和原型支撑。昇腾/PyPTO/CANN 作为可选扩展，不用 HIP 文件内分支数预测其成本。

### R3 · P0：修正数学库与“头文件即可闭合”的判断

**原位置**：正文第 26、55、95 行；素材 `03-headers.md`。

- [__clang_cuda_math.h](clang/lib/Headers/__clang_cuda_math.h) 318 行的 `sqrtf` 也调用 `__builtin_sqrtf`；“CUDA 全走 `__nv_*`”有直接反例。
- [AMDGPU.cpp](clang/lib/Driver/ToolChains/AMDGPU.cpp) 1153–1164 行选择 OCML、OCKL 和配置相关设备库；993–998 行发出 `-mlink-builtin-bitcode`。
- HIP 头文件中对 `__ocml_*` 的调用仍需取得实现；`-E` 展开出函数体不证明链接闭合。

**修改建议**：按函数和配置描述 builtin、设备库和手写实现的组合；删除“无 bitcode 分发负担”的推荐理由。使用 [hip-device-libs.hip](clang/test/Driver/hip-device-libs.hip) 和 [数学头测试](clang/test/Headers/__clang_hip_math.hip) 分别验证库选择与 IR 落点。

### R4 · P0：把“全链实测”分解为可核验的验证等级

**原位置**：正文开头、§1、§3、§9；素材 `02-driver.md`。

现有 [v1-nordc.txt](HIP-notes/scratch/v1-nordc.txt) 第 6–7 行包含 `cannot find HIP runtime`；[v10-chipstar.txt](HIP-notes/scratch/v10-chipstar.txt) 第 6–7 行也包含依赖错误。[v6-devonly-nordc.txt](HIP-notes/scratch/v6-devonly-nordc.txt) 的 cc1 参数含 `-D __global__=`，抹除了该样例的 kernel 属性。

这些日志可以说明 Driver 在给定参数下规划了哪些动作，但不能证明设备链接、产物打包或 kernel 执行成功。原复现手册还用管道过滤输出，并在头文件实验中丢弃 stderr，无法完整保留失败状态。

**修改建议**：记录原命令的退出码、完整 stderr、输入和产物；每项结论注明“源码追踪、命令规划、实际编译、链接/打包、GPU 运行”中的具体等级。第 7 节提供本次补做的可复现检查。

### R5 · P1：收窄 95.3% 的统计含义，纠正缺失函数示例

**原位置**：正文第 54 行；素材 `03-headers.md` 第 1 节。

即使暂时接受 244、256、562 三个数，`244/256` 也只是所抽取 HIP 名称在 CUDA 集合中的重合比例；反方向是 `244/562≈43.4%`。两者都不衡量完整 SDK API 覆盖、重载签名或语义兼容，原始抽取脚本和配置仍需补齐。

此外，[__clang_hip_math.h](clang/lib/Headers/__clang_hip_math.h) 1135–1155 行在 `OCML_BASIC_ROUNDED_OPERATIONS` 条件下定义了 `__dadd_rd/rn/ru/rz` 并调用 OCML；[对应测试](clang/test/Headers/__clang_hip_math_ocml_rounded_ops.hip) 检查这些落点。“这些取整函数在 HIP 中缺失、全走 intrinsic”的举例不成立。

**修改建议**：重建按配置区分的名称与签名集合，公开抽取方法；数量复算完成前标为历史记录，停止使用“镜像率”解释兼容性。

### R6 · P1：拆开 HIPAMD、HIPSPV 与构建能力

**原位置**：正文第 31、48 行；素材 `02-driver.md` 第 3.1–3.2 节。

[HIPAMD.cpp](clang/lib/Driver/ToolChains/HIPAMD.cpp) 145–189 行中 `amdgcnspirv` 路径的选项默认值，不能直接推广为整个 HIPSPV 工具链的默认行为。

[HIPSPV.cpp](clang/lib/Driver/ToolChains/HIPSPV.cpp) 100–112、153–192 行对 chipStar、构建是否支持 SPIR-V 后端及相关选项作区分；非 chipStar 分支仍使用外部 `llvm-spirv`。本机 `clang --print-targets` 未列 SPIR-V，规划出该动作不能证明本机可以执行它。

chipStar 路径中的 HipSpvPasses 插件处理也有可用性条件：同文件 66–68 行在找不到插件时跳过该步骤。扩展正文须区分 HIPAMD 的 SPIR-V 后端选项与 HIPSPV 的 `-f(no-)integrated-objemitter`，并标出可选插件。

**修改建议**：以“三元组/架构 × 工具链类 × 后端开关 × 已构建工具”建立矩阵，分别研究 `gfx*`、`amdgcnspirv`、`spirv64-unknown-chipstar` 与其他 HIPSPV triple。

### R7 · P1：区分封装格式、对象节和两条打包入口

**原位置**：正文第 30、42、79、97 行；素材 `02-driver.md`。

- 普通二进制 bundle 使用 `__CLANG_OFFLOAD_BUNDLE__`；`CCOB` 表示压缩封装。参见 [OffloadBundler.cpp](clang/lib/Driver/OffloadBundler.cpp) 69–70、1238–1255 行，以及 [OffloadBundle.h](llvm/include/llvm/Object/OffloadBundle.h) 35–49 行。
- [OffloadBinary.h](llvm/include/llvm/Object/OffloadBinary.h) 89 行定义的中间 offload 容器另有 magic，不能与最终 HIP bundle 混用。
- [CGCUDANV.cpp](clang/lib/CodeGen/CGCUDANV.cpp) 903–932 行区分 Mach-O 的 `__HIP,__hip_fatbin`、ELF 的 `.hip_fatbin`、嵌入 blob 和外部符号。该处 4096 对齐属于有嵌入 blob 的分支。
- host+device 非 RDC 也会经 `llvm-offload-binary → clang-linker-wrapper --emit-fatbin-only`；见 [Driver.cpp](clang/lib/Driver/Driver.cpp) 4303–4326 行及 [hip-toolchain-no-rdc.hip](clang/test/Driver/hip-toolchain-no-rdc.hip) 66–80 行。
- device-only 的 [HIPUtility.cpp](clang/lib/Driver/ToolChains/HIPUtility.cpp) 路径，与 [ClangLinkerWrapper.cpp](clang/tools/clang-linker-wrapper/ClangLinkerWrapper.cpp) 路径在 host 条目、bundle ID 构造等处存在差异，不能用 V6 替代全部 HIP 打包行为。

**修改建议**：新增产物生命周期表，每行记录生产者、格式、节名、消费者、适用模式和可观察命令。

### R8 · P1：补足 wrapper 与版本契约

**原位置**：正文第 57、62 行；素材 `03-headers.md`、`04-matrix-tools.md`。

[__clang_hip_runtime_wrapper.h](clang/lib/Headers/__clang_hip_runtime_wrapper.h) 包含属性宏、设备 malloc/free、版本分支、RTC 兼容和标准库包装，不能归纳为“只做 include”；其中也没有素材所称的 `hip_runtime_amd.h` include。

版本影响不止两处：

- [AMDGPU.cpp](clang/lib/Driver/ToolChains/AMDGPU.cpp) 533–534 行按 HIP 版本控制传统 wrapper 注入。
- [runtime wrapper](clang/lib/Headers/__clang_hip_runtime_wrapper.h) 47 行起按 HIP 4.5 等条件选择设备内存分配接口。
- [AMDGPU.cpp](clang/lib/Driver/ToolChains/AMDGPU.cpp) 1117–1124 行的 COV6 分支首先检查 ABI 设备库是否存在；其中的 ROCm 版本诊断不能代表全部兼容性判定。
- [hip_wrappers/hip/hip_runtime.h](clang/lib/Headers/hip_wrappers/hip/hip_runtime.h) 还有共享 GPU bootstrap 与可选外部头路径，应与传统 ROCm 路径分别分析。

**修改建议**：补“编译器内置头—SDK 头—设备库—宿主 runtime—code object—驱动”的版本与依赖矩阵。

### R9 · P1：把架构探测改为状态机分析

**原位置**：正文第 67 行；素材 `04-matrix-tools.md` 第 6 节。

“无 GPU”“加载动态库失败”“运行时查询失败”“成功但没有输出”是不同状态：

- [AMDGPUArchByHIP.cpp](clang/tools/offload-arch/AMDGPUArchByHIP.cpp) 276–280 行的库加载失败，与 347–354 行的设备数查询失败，诊断策略不同；成功且 Count=0 时可返回 0。
- [OffloadArch.cpp](clang/tools/offload-arch/OffloadArch.cpp) 81–87 行组合多个厂商的返回值。
- [Driver.cpp](clang/lib/Driver/Driver.cpp) 942–951 行区分子进程非零退出与成功空输出；后者才对应 `No GPU detected in the system`。

**修改建议**：保留“本机该次观察”的日志，删除跨平台推广；复用 [amdgpu-hip-system-arch.c](clang/test/Driver/amdgpu-hip-system-arch.c) 构建模拟探测器测试。

## 3. 扩展后的研究主线

~~~mermaid
flowchart TD
    A["HIP 源程序与配置"] --> D["Driver：host / device 动作"]
    D --> H["host AST / IR：stub、handle、注册信息"]
    D --> V["device AST / IR：ABI、地址空间、属性"]
    L["内置头、SDK 头、设备库"] --> V
    V --> B["目标优化、代码生成、设备链接"]
    B --> I["设备镜像"]
    V --> P["RDC / 中间 offload 容器"]
    P --> B
    I --> F["bundle / 压缩封装 / host 嵌入"]
    H --> O["宿主对象与可执行文件"]
    F --> O
    O --> R["外部 HIP runtime：注册、加载、启动"]
    R --> G["设备执行与结果验证"]
~~~

这是研究对象关系图；具体执行顺序必须按非 RDC/RDC、device-only/host+device 和目标平台分别绘制。运行时节点需要外部证据，不能只凭编译器发出了函数调用就认定其行为已经验证。

## 4. 扩展章节及代码入口

### X1 · P0：语言、语义约束与源码范围审计

**扩展现有 §2**，按“语法/属性—host/device 语义—模板与延迟诊断—目标特例”组织。

- 从 [Attr.td](clang/include/clang/Basic/Attr.td)、[LangOptions.cpp](clang/lib/Basic/LangOptions.cpp)、[InitPreprocessor.cpp](clang/lib/Frontend/InitPreprocessor.cpp) 说明属性和宏的来源。
- 在 [SemaCUDA.cpp](clang/lib/Sema/SemaCUDA.cpp) 中追踪调用约束、kernel launch、managed 分类和延迟诊断，并纳入 R1 中的分散实现。
- 覆盖 `__host__`、`__device__`、`__global__`、`__shared__`、`__constant__`、`__managed__`、`__launch_bounds__`；区分头文件宏与 Clang 属性。
- 用 [kernel-call.cu](clang/test/CodeGenCUDA/kernel-call.cu)、[zero-sized-device-array.hip](clang/test/SemaHIP/zero-sized-device-array.hip) 和 [fp-contract.cu](clang/test/CodeGenCUDA/fp-contract.cu) 设计对照。

**产出**：属性与宏来源表、语义差异矩阵、带调用链的诊断例子。文件检索结果只能作为导航索引。

### X2 · P0：一次 kernel 启动的编译器侧链条

新增完整案例，分别追踪直接 launch 与通过 kernel handle 的间接 launch。

- [SemaCUDA.cpp](clang/lib/Sema/SemaCUDA.cpp)：执行配置表达式和配置函数选择。
- [CGCUDARuntime.cpp](clang/lib/CodeGen/CGCUDARuntime.cpp)、[CGCUDANV.cpp](clang/lib/CodeGen/CGCUDANV.cpp)：stub、参数、旧 launch API 和新 launch API。
- [CGExpr.cpp](clang/lib/CodeGen/CGExpr.cpp)：间接调用对 HIP handle 的处理。
- 测试入口：[kernel-call.cu](clang/test/CodeGenCUDA/kernel-call.cu)、[kernel-stub-name.cu](clang/test/CodeGenCUDA/kernel-stub-name.cu)、[hip-launch-api.hip](clang/test/Driver/hip-launch-api.hip)。

**研究项**：配置 push/pop、参数地址数组或旧参数设置接口、stream 模式、stub 与 kernel 标识、注册前后关系。

**产出**：一份源码、host AST/IR、device IR 和逐步注解；新旧 API 分开记录。编译器生成的调用顺序与 runtime 实际执行顺序分别验收。

### X3 · P0：设备 ABI、地址空间与执行模型

- 核心入口：[Targets/AMDGPU.cpp](clang/lib/CodeGen/Targets/AMDGPU.cpp)、[Basic/Targets/AMDGPU.cpp](clang/lib/Basic/Targets/AMDGPU.cpp)、[CodeGenFunction.cpp](clang/lib/CodeGen/CodeGenFunction.cpp)。
- 比较 scalar、pointer、vector、aggregate、非平凡 C++ 对象参数；区分 kernel 与普通 device function 的 calling convention。
- 覆盖 global/private/local/constant 地址空间、shared/LDS、barrier、atomic scope/order 和 wave 相关约束；每个主题选择一个最小例子。
- AMDGPU 与 `spirv64-amd-amdhsa` 的 ABI 关系使用 [amdgcnspirv-uses-amdgpu-abi.cpp](clang/test/CodeGenHIP/amdgcnspirv-uses-amdgpu-abi.cpp) 核查，不能只按 triple 名称推断。
- 其他测试：[amdgpu-kernel-arg-pointer-type.cu](clang/test/CodeGenCUDA/amdgpu-kernel-arg-pointer-type.cu)、[amdgpu-kernel-attrs.cu](clang/test/CodeGenCUDA/amdgpu-kernel-attrs.cu)、[incorrect-atomic-scope.hip](clang/test/SemaHIP/incorrect-atomic-scope.hip)、[shared-variable-too-large.hip](clang/test/SemaHIP/shared-variable-too-large.hip)。

**产出**：参数 ABI 表、地址空间映射、属性到 IR/metadata 的映射及负例。硬件内存一致性结论需要另做设备验证。

### X4 · P0：Driver 路径、RDC 与跨翻译单元链接

将现有 §3 拆成动作规划与实际链接两个专题。

| 轴 | 必须区分的取值 |
|---|---|
| 目标路径 | HIPAMD gfx、HIPAMD amdgcnspirv、HIPSPV chipStar、其他 HIPSPV |
| 编译模式 | host-only、device-only、host+device |
| 链接模式 | 非 RDC、RDC；存在区别时再加入 full/thin LTO |
| 停止阶段 | 预处理、语义检查、IR、对象、最终链接 |
| 输入结构 | 单 TU、两 TU、静态归档、多 arch |

不要求穷举全笛卡尔积：先覆盖各分支，再为跨 TU device 调用和归档提取建立两组完整实验。

**入口**：[Driver.cpp](clang/lib/Driver/Driver.cpp)、[Clang.cpp](clang/lib/Driver/ToolChains/Clang.cpp)、[HIPAMD.cpp](clang/lib/Driver/ToolChains/HIPAMD.cpp)、[HIPSPV.cpp](clang/lib/Driver/ToolChains/HIPSPV.cpp)、[ClangLinkerWrapper.cpp](clang/tools/clang-linker-wrapper/ClangLinkerWrapper.cpp)。

**测试**：[hip-phases.hip](clang/test/Driver/hip-phases.hip)、[hip-toolchain-no-rdc.hip](clang/test/Driver/hip-toolchain-no-rdc.hip)、[hip-toolchain-rdc.hip](clang/test/Driver/hip-toolchain-rdc.hip)、[hipspv-toolchain.hip](clang/test/Driver/hipspv-toolchain.hip)、[hipspv-no-spirv-backend.hip](clang/test/Driver/hipspv-no-spirv-backend.hip)。

**产出**：按模式分开的动作图、实际命令、跨 TU 符号解析和失败例子；明确 `-###` 看不到 wrapper 内实际执行结果。

### X5 · P0：二进制产物与注册/注销 ABI

将现有 fatbin 摘要扩展为以下对象的生命周期表：

| 对象 | 需要解释的内容 |
|---|---|
| Device LLVM IR / bitcode | target、arch、offload kind、链接方式 |
| 中间 OffloadBinary | 元数据、输入镜像、生产工具与提取入口 |
| 设备 code object / SPIR-V | target ID、ABI、kernel 符号及元数据 |
| HIP bundle 与压缩外封装 | magic、目录项、偏移、对齐、压缩开关 |
| 宿主对象中的节/entries | ELF/Mach-O/COFF 差异、CUID、嵌入或外部符号 |
| 注册与注销代码 | ctor/dtor、fatbin handle、kernel/global/managed 注册及去重 |

**入口**：[OffloadBinary.h](llvm/include/llvm/Object/OffloadBinary.h)、[OffloadBundler.cpp](clang/lib/Driver/OffloadBundler.cpp)、[HIPUtility.cpp](clang/lib/Driver/ToolChains/HIPUtility.cpp)、[OffloadWrapper.cpp](llvm/lib/Frontend/Offloading/OffloadWrapper.cpp)、[CGCUDANV.cpp](clang/lib/CodeGen/CGCUDANV.cpp)。

**测试**：[device-stub.cu](clang/test/CodeGenCUDA/device-stub.cu)、[device-stub-macho.cu](clang/test/CodeGenCUDA/device-stub-macho.cu)、[managed-var.cu](clang/test/CodeGenCUDA/managed-var.cu)。

实际打包与解包优先复用 [linker-wrapper-hip-no-rdc.c](clang/test/OffloadTools/clang-linker-wrapper/linker-wrapper-hip-no-rdc.c)；压缩封装参考 [bundler zstd.c](clang/test/OffloadTools/clang-offload-bundler/zstd.c)。前者要求 AMDGPU target 和可用 lld，应先检查测试的 `REQUIRES`，再执行其真实链接步骤。

**产出**：至少一组实际打包、列目录、解包、哈希比对，以及 host IR/对象节核对。使用假镜像的注册测试应标明只能证明生成代码的结构。

### X6 · P0：头文件、数学库与版本依赖

扩展现有 §4–§5，分别绘制传统 ROCm wrapper 与共享 GPU/hermetic 路径的 include 图。

- 追踪 `cosf`、`sqrtf`、`__dadd_rd`：调用点 → 条件宏 → wrapper → IR builtin/外部调用 → 设备库链接 → 优化后 IR。
- 选项包括 fast-math、近似超越函数、正确舍入配置；数值误差和性能属于有实际运行环境后的独立实验。
- 纳入设备 malloc/free、ASan、RTC 分支和标准库包装。
- 重算名称/签名集合时，保存文件范围、预处理宏、host/device 模式、重载去重策略及脚本。

**入口**：[HIP math](clang/lib/Headers/__clang_hip_math.h)、[CUDA math](clang/lib/Headers/__clang_cuda_math.h)、[HIP runtime wrapper](clang/lib/Headers/__clang_hip_runtime_wrapper.h)、[共享 HIP wrapper](clang/lib/Headers/hip_wrappers/hip/hip_runtime.h)、[AMDGPU.cpp](clang/lib/Driver/ToolChains/AMDGPU.cpp)。

**测试**：[hip-header.hip](clang/test/Headers/hip-header.hip)、[OCML rounded ops](clang/test/Headers/__clang_hip_math_ocml_rounded_ops.hip)、[hip-device-libs.hip](clang/test/Driver/hip-device-libs.hip)、[hip-device-libs-llvm-env.hip](clang/test/Driver/hip-device-libs-llvm-env.hip)、[hip-version.hip](clang/test/Driver/hip-version.hip)。

**产出**：函数实现归属表、版本与依赖矩阵、可重算统计。常规 ROCm 路径与 LLVM environment 的设备库策略分别报告。

### X7 · P1：HIP IR 如何进入 AMDGPU 优化与代码生成

补足现稿从 Clang 直接跳到“设备产物”的中间阶段，选择三条与 HIP 输入直接相关的链：kernel 参数、LDS/shared、printf/设备库调用。

**入口**：[AMDGPUTargetMachine.cpp](llvm/lib/Target/AMDGPU/AMDGPUTargetMachine.cpp)、[AMDGPULowerKernelArguments.cpp](llvm/lib/Target/AMDGPU/AMDGPULowerKernelArguments.cpp)、[AMDGPULowerModuleLDSPass.cpp](llvm/lib/Target/AMDGPU/AMDGPULowerModuleLDSPass.cpp)、[AMDGPUPrintfRuntimeBinding.cpp](llvm/lib/Target/AMDGPU/AMDGPUPrintfRuntimeBinding.cpp)。

**实验**：保存 Clang 初始 IR、选定 pass 前后 IR、目标汇编/对象；按实际编译命令采集 pass 日志。区分 clang 编译阶段、LTO 阶段及 LLVM codegen 阶段，避免仅凭 pass 注册位置断言执行顺序。

**产出**：三条有限范围的转换链，并链接现有 AMDGPU 分析。完整寄存器分配/调度等通用后端机制通过引用复用，不在 HIP 专卷重复展开。

### X8 · P1：运行时接口、HIPStdPar 与外部组件边界

将“runtime 不在编译器里”展开为可查证的职责划分。

- **编译器侧必选**：追踪生成的注册/启动接口、malloc/free 和库依赖；解释 host runtime 实现与编译器生成胶水代码的区别。
- **HIPStdPar 必选**：现稿已使用它作为 Sema 差异，应解释语义放宽后的处理。入口为 [HipStdPar.cpp](llvm/lib/Transforms/HipStdPar/HipStdPar.cpp) 的代码筛选、数学修正、分配替换，以及 [BackendUtil.cpp](clang/lib/CodeGen/BackendUtil.cpp) 和 [AMDGPUTargetMachine.cpp](llvm/lib/Target/AMDGPU/AMDGPUTargetMachine.cpp) 的流水线接入。参考 [CodeGenHipStdPar](clang/test/CodeGenHipStdPar/) 和 [Transforms/HipStdPar](llvm/test/Transforms/HipStdPar/) 测试。
- **外部环境阶段**：取得确定版本的 HIP SDK/runtime 源码，追踪 `hipMalloc`、kernel 注册、模块加载、stream/event、launch 与错误传播；记录实际 GPU、驱动和 code object 条件。
- **可选专题**：hipRTC、hipcc/CMake 集成、HIPIFY 转换、不同 runtime 的 API 兼容。工具转换成功与程序语义/性能兼容分开验证。

外部背景只作为边界说明：AMD 官方将 HIP 描述为 runtime API 与 kernel language，并区分 HIPIFY 转换工具和编译器入口；后续须固定采用的发行版。[HIP 官方移植指南](https://rocm.docs.amd.com/projects/HIP/en/latest/how-to/hip_porting_guide.html)

chipStar 的项目入口说明了其 HIP/CUDA 到 SPIR-V、再接 OpenCL/Level Zero 的目标；这不构成它与任意其他平台模拟器等价的证据。[chipStar 项目](https://github.com/CHIP-SPV/chipStar)

**产出**：组件所有权表和接口契约；将“编译器已生成调用”与“runtime 已接收并成功执行”作为两个验收项。

### X9 · P1：架构探测、诊断与复现工程

扩展现有 §6、§9。

- 探测器矩阵：成功单架构、多架构、重复架构、成功空输出、非法输出、非零退出、stderr 和不可执行路径。
- 分别检查 KFD、HIP、CUDA、Level Zero 的调用与返回协议；共享整体结果不能代替单路径状态。
- 参考 [amdgpu-hip-system-arch.c](clang/test/Driver/amdgpu-hip-system-arch.c)、[hip-invalid-target-id.hip](clang/test/Driver/hip-invalid-target-id.hip)、[hip-offload-arch.hip](clang/test/Driver/hip-offload-arch.hip)。
- 诊断日志保留原始 stderr 和退出码；查找错误后再提取摘要。

**产出**：失败状态机、最小模拟探测器、错误到源码分支的映射。

### X10 · P2：调试、可观测性与平台适配评估

**调试与性能工具**：用 [debug-info-language-hip.hip](clang/test/CodeGenHIP/debug-info-language-hip.hip)、[offload-pgo-sections.hip](clang/test/CodeGenHIP/offload-pgo-sections.hip)、[profile-coverage-mapping.hip](clang/test/CodeGenHIP/profile-coverage-mapping.hip) 说明编译器侧 debug info、PGO/coverage 产物；有运行环境后再验证采集和回用。

**可选平台适配**：将原 §7–§8 的单轴“路线光谱”改为能力矩阵：语言属性、执行模型、地址空间、同步/原子、kernel ABI、镜像格式、注册/加载、库实现、设备探测。逐项填写“可复用、需改写、待确认”，并提供原型证据；不预判 CANN 缺少某个工具，也不作分支数或行数预算。

## 5. 实验矩阵与资源需求

等级定义：**S**＝源码/测试静态核对；**D**＝Driver 命令规划；**C**＝实际前端/IR/代码生成；**L**＝实际链接、打包及产物检查；**R**＝运行时与 GPU 结果。各等级证据独立标注。

| 编号 | 实验 | 资源与范围 | 验收 |
|---|---|---|---|
| H00 | 基线与证据归档 | 仓库、现有工具 | 提交、相关修改、工具版本/哈希、target 列表、输入和完整命令 |
| H01 | 属性/宏/语义差异 | 无 SDK 的属性写法或测试替身头；C | host/device 宏、AST、零长数组/调用约束/浮点默认值对照 |
| H02 | kernel launch 与 handle | 现有 CodeGenCUDA 测例；C | 直接/间接启动、新旧 API、stream 变体的 IR 和检查结果 |
| H03 | 参数 ABI 与内存模型 | Clang/AMDGPU IR；C，硬件语义另需 R | 指针和聚合参数、地址空间、launch bounds、shared/atomic 正负例 |
| H04 | 模式/工具链矩阵 | Driver 与模拟 SDK；D | HIPAMD/HIPSPV、RDC、阶段、多 arch 的分支图；错误与规划分开 |
| H05 | 两 TU 与静态归档 | 可用设备 linker/目标工具；L | device 符号跨 TU 解析、非 RDC 限制、归档提取与预期失败 |
| H06 | 格式/注册 ABI | bundler、wrapper、对象检查工具；C/L | 普通/压缩封装、解包一致性、host 节/entries、ctor/dtor |
| H07 | 数学/设备库依赖 | 替身头可做 C；实际设备库用于 L | cosf/sqrtf/舍入函数的 IR、未解析符号及链接后的实现 |
| H08 | wrapper/API 集合 | 固定头文件和宏配置；S/C | 宏/include 图、malloc/RTC 分支、双向名称与签名集合 |
| H09 | AMDGPU 转换链 | clang/opt/llc 对应 target；C | 参数、LDS、printf 三组 pass 前后 IR 和产物 |
| H10 | HIPStdPar | 仓库回归样本；C，运行另需 SDK | relaxed Sema、代码筛选、数学修正、分配替换及阶段条件 |
| H11 | 探测与失败状态 | 模拟探测器；D/C | 成功输出/空输出/失败/非法架构分别命中预期诊断 |
| H12 | runtime 生命周期 | 固定 SDK/runtime、可用 GPU；R | 分配、传输、注册、启动、同步、结果与错误路径可复现 |
| H13 | 调试/性能与迁移原型 | 按专题增加工具/硬件；可选 | 记录实测条件；性能、兼容和适配结论均有对应指标 |

本方案没有执行整张实验矩阵。当前完成状态见第 7 节；缺少 GPU 只限制 R 级结论，不阻止 S/D/C 级研究。

## 6. 执行顺序与交付标准

### 6.1 顺序

1. **先修订 R1–R4**：更换核心论点、移除无依据的工作量推断、校正设备库边界、为现有日志标注验证等级。
2. **完成 H00 与最小案例**：固定工具、输入及文件组织；以实际 device IR 为起点。
3. **三条可并行分支**：X1–X3 语言/ABI；X4–X5 Driver/产物；X6/X9 头文件/依赖/诊断。
4. **补 X7–X8**：接入优化流水线和 runtime 接口，完成核心编译器侧正文。
5. **独立复核**：逐项检查源码条件、输入参数、产物和结论范围；回写原素材，避免正文与 notes 保留相反结论。
6. **有外部环境后执行 H12**；X10/H13 按实际需求展开。若仍称为“全栈专卷”，须完成运行时证据，或在标题/摘要明确其当前覆盖范围。

### 6.2 建议新增材料

~~~text
HIP_Deep_Analysis_Extension_Plan.md        本次方案
HIP-notes/
  extension-review-20261003/
    run_checks.py                        本次可复现检查
    results/manifest.json                命令、退出码、工具/产物哈希
    results/kernel.hip / kernel.ll       实际设备 IR 样例
    results/*.stdout / *.stderr          完整输出
  05-language-semantics.md                后续：语言与分散差异
  06-kernel-launch-abi.md                 后续：launch/handle
  07-device-abi-memory.md                 后续：参数/地址空间
  08-rdc-linking-artifacts.md             后续：链接/打包/注册
  09-device-libraries-and-pipeline.md     后续：头文件到后端
  10-runtime-and-hipstdpar.md             后续：外部接口与专门模式
  11-diagnostics-and-reproduction.md     后续：错误与复现
  12-portability-evaluation.md            可选：平台适配
~~~

现有 00–04 素材继续作为入口索引；历史失败输出保留并标注状态。本次仅新增方案和检查证据，正文修订按本节顺序开展。

### 6.3 质量门槛

- 每个机制至少提供“输入/参数 → 源码符号 → 可观察产物或诊断”，跨阶段章节还须给出生产者与消费者。
- 有分支条件的结论写出 target、host/device、RDC、版本和相关开关。
- 每个主要专题至少一个正例和一个限制/负例；复用已有测试优先。
- 所有“已验证”必须指出等级、命令、退出码和检查项；测试未执行与环境不支持分别记录。
- 模拟 SDK、替身头、假镜像只用于对应结构性检查，不能替代 SDK 或 runtime 兼容验证。
- `-###` 的成功不能升级为 L/R 级证据；源码中注册 pass 不能代替实际流水线日志。
- API 统计、性能结果和跨平台建议必须注明分母、配置和适用范围。
- 将工具故障、代理协作经历等执行过程移到工作记录，正文保留技术假设、修订理由和可复现实验。

## 7. 本次已完成的核查与复现方法

### 7.1 环境

| 项目 | 本次观察 |
|---|---|
| 源码提交 | `3eda2aebadd430199a1d588b6b22c966af5356d5` |
| 编译器 | `build-debug/bin/clang-24`，24.0.0git，版本输出包含上述提交 |
| 构建类型 | Debug、Assertions 开启 |
| 已构建 target | AMDGPU、NVPTX、AArch64；本机输出没有 SPIR-V |
| SDK/GPU 范围 | 本次样例使用 `-nogpuinc -nogpulib` 和直接属性，不依赖 ROCm SDK；没有执行 GPU 程序 |
| 构建行为 | 使用已有工具；仓库约定的新构建目录仍为 build-shared，本次未重新配置或构建 |

编译器版本中的提交号与当前 HEAD 一致，并保存了二进制 SHA256。正式研究仍需记录相关源码工作区差异及所有参与链接工具、外部库的版本，不能只记录 clang 版本。

### 7.2 本次检查结果

| 检查 | 实际状态 | 可以支持的结论 |
|---|---|---|
| 原文/素材与源码对照 | 已完成本方案列出的关键路径核对 | R1–R9 的修订依据及扩展入口 |
| HIP device 宏 | 预处理退出 0 | 该无 SDK 配置下有 `__HIP__`、`__HIP_DEVICE_COMPILE__`，无 `__CUDA__`、`__CUDACC__` |
| 最小 kernel 的设备 IR | 编译退出 0 | 实际产生 `amdgpu_kernel`，指针参数为 `ptr addrspace(1)` |
| host+device 非 RDC 规划 | `-###` 退出 0 | 观察到 offload-binary、wrapper `--emit-fatbin-only` 和 host 二进制嵌入动作 |
| host+device RDC 规划 | `-###` 退出 0 | 观察到 offload-object 嵌入及最终 linker-wrapper 动作 |
| device-only 非 RDC 规划 | `-###` 退出 0 | 观察到 cc1 → lld → bundler 的规划 |
| 实际设备链接、bundle、runtime/GPU | 本次未执行 | 不作成功或兼容性结论 |

代码使用真实 kernel 属性：

~~~cpp
extern "C" __attribute__((global))
void add_one(int *out, int value) { out[0] = value + 1; }
~~~

已生成的 IR 入口为：

~~~llvm
define protected amdgpu_kernel void @add_one(
    ptr addrspace(1) noundef %out.coerce, i32 noundef %value)
~~~

它验证了本例从 HIP 前端到设备 IR 的生成，并不验证 host launch 或设备计算结果。

### 7.3 复现

在仓库根目录执行：

~~~bash
python3 HIP-notes/extension-review-20261003/run_checks.py
~~~

脚本保存原始 stdout/stderr、每条命令的参数与退出码、输入/编译器/产物 SHA256，并检查 HIP 宏及 kernel IR。三个 Driver 规划命令使用独立输出名，检查不会把规划误记为已生成二进制。

查看 [manifest.json](HIP-notes/extension-review-20261003/results/manifest.json) 和 [kernel.ll](HIP-notes/extension-review-20261003/results/kernel.ll)。后续新增实验沿用该证据格式，另增实际链接、文件格式、runtime 和数值检查项。
