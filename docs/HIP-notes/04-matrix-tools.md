# §5 HIPSupport 官方兼容文档解剖 + §6 offload-arch 编译期 GPU 探测工具

> 基准：llvm-project main @ `3eda2aebadd4`；clang-24 & offload-arch @ build-debug 实测（本机 macOS 无 GPU、无 ROCm）。
> 引用格式 `文件:行号`（文档用 `HIPSupport.md:行号`）。全部引用经 grep/read 实际核对。
> 前置：02-driver.md（§3.5 Driver.cpp 97 处 HIP 引用分类）、03-headers.md（HIP 头文件设备端实现机制）。

**本文核心修正（相对任务预设）**：
1. **HIPSupport.md 当前版不是 API 矩阵文档**——1,159 行中正文使用 `{none|part|good}` 三色标记 **0 次**（grep `\{(none|part|good)\}` 于 clang/docs 全目录：HIPSupport.md 命中 0，OpenMPSupport.md 命中 244）。三色 CSS/role 定义在 HIPSupport.md:1-16 但全文从未使用。CUDA→HIP API 覆盖率矩阵从未由本文件承载（git 考古见 §5.1.2）。
2. **hipMalloc 在 clang 全树仅 1 处踪迹**——HIPSupport.md:806 的 doxygen 外链（hipMallocManaged，stdpar 节）。编译器仓库不实现、不矩阵化 HIP 运行时 API；真正的 API 兼容矩阵在 ROCm/HIP 仓库（hipify 工具 + `docs/CUDA2HIP.md`），不在 LLVM。
3. **offload-arch 是 Driver fork+exec 的独立子进程工具，不是链接库**——Driver 侧 `llvm::sys::findProgramByName` + `executeProgram`（Driver.cpp:928-940），且可用 `--offload-arch-tool=` 替换为任意自定义工具（Driver.cpp:924-925；Options.td:1313-1318）。

---

## §5.1 HIPSupport.md 文档结构解剖（1,159 行）

### 5.1.1 章节组织全景

六大功能块（`HIPSupport.md:19` 起）：

| 功能块 | 章节 | 起始行 |
|---|---|---|
| ① 平台与工具链 | AMD GPU Support / Intel GPU Support / Example Usage / Path Setting for Dependencies | 25 / 33 / 47 / 91 |
| ② 语言层语义 | Predefined Macros / Syntax Difference with CUDA / Function Pointers / Virtual Function / Alias Attribute / Managed Variables / CTAD / Default Destructors | 138 / 312 / 323 / 336 / 373 / 407 / 465 / 515 |
| ③ ABI 与注册 | HIP Fat Binary Registration and Unregistration（App Developers 273 / Runtime Developers 291） | 208 |
| ④ 诊断 | Deferred Diagnostics（HD-Promoted Functions 550） | 534 |
| ⑤ C++ stdpar offload | Introduction 614 → Implementation-Driver 691 / Front-End 737 / Middle-End 760 / Forwarding Header 791 / Restrictions 826 / Current Support 871 / HIP Specific 894 / Open Questions 943 | 614-953 |
| ⑥ 编译器特性 | PGO for Device Code 955 / Source-Based Coverage 1074 / SPIR-V on HIPAMD 1124 | 955-1159 |

关键结构性事实（证据 → 分析）：
- **无任何版本对应表章节**：全文 grep `HIP 4|HIP 5|HIP 6|ROCm [4-7]|CUDA 1x` 零命中；"version" 仅出现在 fatbin wrapper 结构体字段（:249）与 CTAD 弃用说明（:508-510）。唯一硬版本约束是 stdpar HMM 模式要求 Linux 内核 ≥ 6.4（:885）。→ 版本矩阵职责归 ROCm 发行版文档（见 §5.2），本文件只讲"编译器侧语言/ABI 语义"。
- **语义差异按语言特性聚类，不按 API 逐条列**：函数指针跨 TU 需 `-fgpu-rdc`（:327-334）；虚函数按对象构造侧限定（:340-343）；`__managed__` 三条诊断规则（:412-455）。→ 文档形态反映实现形态：这些是 clang Sema 的规则，不是 runtime API 差异。
- **平台差异 = 独立厂商章节**（AMD :25 / Intel :33）+ note 块给 NVIDIA/CPU（:40-45），而非表格。

### 5.1.2 "API 覆盖率矩阵"的真相：从未存在（git 考古）

- 引入提交：`795e934e15b7 [HIP] Start document HIP support by clang`（Yaxun Liu, 2023-07-25）——原版 HIPSupport.rst 仅 **175 行**，内容为 Example Usage / Predefined Macros / Path Setting；**头部同样定义了三色 role（`.none/.part/.good`）但正文 0 次使用**（原版 grep 计数：三色标记 0）。
- 演化：2024-12 `fb83b9b663e0`（coverage）、2025 `397eecf82a8a`（PGO）、`#208310`（reST→Markdown 重写）、`#211542`（SPIR-V 节）逐步增至 1,159 行；`git log -S '{good}'` 显示删除 API 矩阵的提交**不存在**——因为从未加入过。
- 三色 role 是从 CUDA 时代的 compat 表格模板**复制残留**：真正在用的姊妹文档是 OpenMPSupport.md（244 处 `{good}/{part}/{none}`，对应 OpenMP directive/clause 支持矩阵）。
- **CUDA→HIP API 映射的官方真身**：ROCm/HIP 仓库 `docs/CUDA2HIP.md`（API 级支持/部分/不支持 + 名称映射表）+ `hipify-clang` 工具（机械验证映射）。LLVM 侧 clang 只管语言层，runtime API 层完全外置。这本身是重要架构结论：**兼容矩阵放在 runtime 仓库、与编译器解耦**。

### 5.1.3 语义差异清单（文档实际给出的）

| 差异项 | 内容 | 证据 |
|---|---|---|
| kernel launch 语法 | **文档未列差异**——clang CUDA/HIP 共用同一前端解析，`<<<>>>` 双方均支持；文档只指向 CompileCudaWithLLVM.html 的 dialect 差异并声明"同样适用于 HIP"（:314） | HIPSupport.md:312-314 |
| 纹理/图像对象 | 无专节；仅宏 `__HIP_NO_IMAGE_SUPPORT__`（值 1，目标机无 HIP image 函数支持时定义，:169-173）——设备能力探测交给宏，差异交给 runtime | HIPSupport.md:169-177 |
| managed memory | 三条诊断：禁动态初始化（:412-422）；取地址非常量表达式（:424-433）；不得用于 static/thread-local 初始化器（运行时未注册时地址为 null，:435-455）。机制：设备侧以 undefined global 符号发出，`__hipRegisterManagedVar` 注册，clang 把设备访问替换为指针 load（:457-463） | HIPSupport.md:407-463 |
| 函数指针 | 同 TU 内定义+使用：两模式皆可；跨 TU：仅 `-fgpu-rdc`（资源核算需全程序链接） | HIPSupport.md:327-334 |
| 虚函数 | 仅"设备构造的对象在设备代码调虚函数"或"host 构造对象在 host 调"两种组合合法 | HIPSupport.md:340-343 |
| fatbin 注册 ABI | `__hip_module_ctor`→`__hipRegisterFatBinary`→`__hip_register_globals`→atexit(`__hip_module_dtor`→`__hipUnregisterFatBinary`)；wrapper 结构体 `{magic,version,image,reserved}` 置于 `.hipFatBinSegment` 节，是 clang↔HIP runtime 内部 ABI | HIPSupport.md:229-267；CodeGen 实现锚点 CGCUDANV.cpp:694,838,1017 |
| HIP on NVIDIA 官方叙述 | "Clang **不直接**为 NVIDIA GPU/CPU 提供 HIP 支持"：NVIDIA 走 ROCm/HIP 项目的 **header-only 转译层**（HIP API→CUDA runtime API）然后用 **nvcc** 编译；CPU 走 HIP-CPU header-only runtime 执行未改动的 HIP 代码（:40-45） | HIPSupport.md:40-45 |

### 5.1.4 文档中仅有的两张"矩阵"

1. **stdpar 处理器×内存模式矩阵**（:877-883）：GFX9 HMM=YES，GFX10.1/10.3/11/12 HMM=NO（RDNA 系无 HMM 硬件统一访存）、Interposition 全 YES。
2. **宏×取值**（:140-178）与 **路径优先级表**（:113-132）：`--hip-path` > `HIP_PATH` > `--rocm-path` > `ROCM_PATH` > 自动探测（:97-103）——Driver 实现 RocmInstallationDetector 对应此表。

**昇腾映射（待验证）**：CANN 若做 "CUDA API→AscendCL 兼容矩阵" 文档，HIPSupport.md 的教训是：**别把它放进编译器仓库**。HIPSupport 的结构（语言语义→ABI→诊断→工具链）与 OpenMPSupport.md 的三色 directive 矩阵是两个可抄模板：前者证明"编译器文档只写编译器语义"，后者证明"支持度矩阵用颜色 role + 表格可维护"。若 CANN 生态要"算子/API 级"矩阵，对应物是 ROCm 的 CUDA2HIP.md + hipify-clang（可执行验证的映射），npu 编译器（如毕昇/Ascend clang）仓库只需管语言层与 fatbin 类 ABI。

---

## §5.2 版本矩阵：LLVM 内嵌 HIP 与 ROCm 发行版 HIP 的关系

**证据**：
- clang 对 ROCm 安装的探测在 `RocmInstallationDetector`（AMDGPU.cpp）：候选路径含 `/opt/rocm`、`--rocm-path` 等多级搜索；**HIP 版本号从 ROCm 安装内 `.hipVersion` 文件解析**——`parseHIPVersionFile`（AMDGPU.cpp:161-179）读 `HIP_VERSION_MAJOR=`/`HIP_VERSION_MINOR=` 行组 `VersionTuple`，决定版本相关默认行为（如最低 ROCm 要求诊断 AMDGPU.cpp:1118-1124 提到 "COV6 … minimum ROCm version … 6.3"）。
- `DeviceLibABIVersion`（code object ABI 版本，COV4/5/6）独立于 HIP 版本，由设备库路径下 `oclc_abi_version_*` 文件名推断（AMDGPU.cpp:136-141, 1106-1126）。
- HIPSupport.md 全文无 HIP×CUDA×ROCm 对应表（§5.1.1）；clang 源码中 HIP 版本号唯一用途是 ROCm 安装检测，无 CUDA 版本对应逻辑（CUDA 版本检测在 Cuda.cpp 的 CudaInstallationDetector，解析 `version.{json,txt}`，属 CUDA 工具链，与 HIP 无关）。
- HIP 运行时本体（libamdhip64.so、hip_runtime 头）**不在 LLVM tree**：clang 通过 §5.1.4 的五级优先级在**磁盘上找**它；`--hip-path` 缺省时由 ROCm 目录结构推导（HIPSupport.md:124-127）。

**分析**：正确的关系图是——
```
LLVM/clang（本仓库）          ROCm 发行版（外部）
├─ HIP 语言/驱动/CodeGen  ←─依赖─ ROCm 安装树：hip 头 + 设备库(.amdgcn.bc) + lld
├─ offload-arch 探测       ←─dlopen─ libamdhip64.so（HIP 运行时，ROCm 出品）
└─ 不含任何 HIP API 实现      CUDA2HIP API 矩阵（docs/CUDA2HIP.md）也在 ROCm 仓库
```
"HIP 版本×CUDA 版本×ROCm 版本"对应表（如 HIP 6.x ↔ ROCm 6.x ↔ CUDA 11/12 头文件集）只存在于 **ROCm 发行版 release notes**，编译器只在"探测到的 ROCm 太旧"时报错。LLVM main 内嵌的是 **HIP 语言支持**（语法/ABI/fatbin 格式），版本耦合点仅有：① `.hipVersion` 解析（AMDGPU.cpp:161）② code object ABI 版本门槛（:1118-1124）③ SPIR-V 目标 `amdgcnspirv`（HIPSupport.md:1136-1153，"under active development"）。

**昇腾映射（待验证）**：CANN 版本与 npu 编译器版本的耦合应仿此结构——编译器仓库解析 CANN 安装内某版本文件（类比 `.hipVersion`）、按目录结构找 AscendCL 头与设备库；"torch_npu×CANN×驱动"对应表放 CANN release notes 而非编译器文档。可验证锚点：CANN 安装树是否存在等价 `version.info` 及编译器（毕昇）是否解析它。

---

## §6.1 offload-arch 整体架构：一个二进制，五路后端

**证据**（clang/tools/offload-arch/，目录全 6 文件）：
- CMakeLists.txt:3-8：单一工具链接 5 个源文件；`add_clang_symlink(amdgpu-arch offload-arch)` + `add_clang_symlink(nvptx-arch offload-arch)` 两个 legacy 符号链接（build-debug/bin/ 实测确认 `amdgpu-arch -> offload-arch`）。
- OffloadArch.cpp:20-33：`--only={all,amdgpu,nvptx,intel}` 选项；:59-62 `VendorTable` 把三厂商映射到 `printAMD/printNVIDIA/printIntel`；:76-79 若 argv[0] 以 `amdgpu-arch`/`nvptx-arch` 开头自动限定对应厂商（legacy 兼容）；:81-87 逐厂商调用，`Result &= Func()` **按位与聚合退出码**。
- OffloadArch.cpp:47-54 `printAMD`（Linux）：**先 KFD 后 HIP**——`printGPUsByKFD()` 成功（返回 0）即短路；失败 fallback 到 `printGPUsByHIP()`。

三路 AMD/NVIDIA 探测后端对照：

| 维度 | AMDGPUArchByKFD.cpp | AMDGPUArchByHIP.cpp | NVPTXArch.cpp |
|---|---|---|---|
| 探测接口 | Linux sysfs：`/sys/devices/virtual/kfd/kfd/topology/nodes`（:26-27） | dlopen `libamdhip64.so`（Linux；Windows 找最新 `amdhip64_<n>.dll`，:184-221） | dlopen `libcuda.so.1`（:44） |
| 是否需要 ROCm | 否（内核驱动即可） | 是（HIP runtime） | 否（NVIDIA 驱动自带） |
| API 调用 | 无 API，读节点文件 GFXVersion/ASICRevision 拼 gfx 名（:32-49） | `hipGetDeviceCount` + 版本化 `hipGetDeviceProperties{R0600,R0000,}`（:55-62, 298-343） | `cuInit`/`cuDeviceGetCount`/`cuDeviceGet`/`cuDeviceGetAttribute`（:38-42, 62-66） |
| 输出 | `gfx<ver>[-strict]`（gfx1250-strict 特例 :44-49） | `Prop.gcnArchName`（:378） | `sm_<major><minor>`（:115） |
| 无 GPU 行为 | sysfs 不存在→return 1（:63-65） | **加载库失败→stderr 诊断+return 1**（:276-281）；`hipGetDeviceCount` 失败→return 1（:348-355） | **`cuInit` 返回 CUDA_ERROR_NO_DEVICE→return 0**（静默成功，:90-92）；库缺失→return 1（:87） |

**架构要点**：① KFD 路径**故意不尊重 `ROCR_VISIBLE_DEVICES`**（AMDGPUArchByKFD.cpp:10-11 注释）——编译期探测要看到物理全部 GPU，与运行时可见性分离。② 退出码语义不统一是**设计而非缺陷**：Driver.cpp:948-953 判定"stdout 为空"才算无 GPU，非零退出码触发 `err_drv_undetermined_gpu_arch`；NVPTX 静默 0 + 空输出与 HIP 报错 1 + 空输出在 Driver 侧殊途同归。③ Intel 路径 LevelZeroArch.cpp dlopen `libze_loader.so`（本机实测输出 "Unable to load library 'libze_loader.so'"）。

### 6.1.2 AMDGPUArchByHIP.cpp 调用链（444 行核心流程）

`printGPUsByHIP()`（:257）六步：
1. `findNewestHIPDLL()`（:191-221）：Linux 恒 `libamdhip64.so`；Windows 枚举 `amdhip64_*.dll` 取版本号最大者（:161-181 compareVersions，`stable_sort` 保证同版本时共置 build 目录优先，:213-214）。
2. `DynamicLibrary::getPermanentLibrary` dlopen（:273-275）；失败即 verbose 诊断 + **return 1**（:276-281）。
3. `DYNAMIC_INIT_HIP(hipGetDeviceCount)` 硬依赖（:286-305，符号缺失 return 1）；软依赖：`hipGetErrorString`、`hipRuntimeGetVersion`（成功则打印 Major.Minor.Patch，编码 `M*10000000+m*100000+p`，:324-334）、三个版本化 properties 符号（:336-342）。
4. `hipGetDeviceCount(&DeviceCount)` 失败→错误串+return 1（:347-355）。
5. 每设备按 `HipApi` 选项降级链取属性：**Auto = R0600→R0000→unversioned**（:417-419），可用 `--hip-api-version={auto,r0600,r0000,unversioned}` 强制（:75-83）。三种 struct 是**手工偏移的镜像布局**：R0600 `padding[1160]+gcnArchName[256]`（:38-42），R0000 `padding[396]+gcnArchName[256]`（:45-49）——不 include HIP 头、不链接 HIP 库，纯 ABI 偏移对齐，避免工具对 ROCm 版本的编译期依赖。
6. 成功则 `llvm::outs() << ArchName`（:440），驱动按行解析。

**无 GPU 本机实测**（build-debug/bin/offload-arch @ `3eda2aebadd4`，macOS 无 ROCm）：
```
$ offload-arch --verbose        # 或 --only=amdgpu --verbose
Failed to load libamdhip64.so: dlopen(libamdhip64.so ... no such file ...)
Failed to 'dlopen' libcuda.so.1
Unable to load library 'libze_loader.so': ...
Using default HIP runtime: libamdhip64.so
exit=1
$ offload-arch                  # 静默版：无任何输出
exit=1
$ offload-arch --version
offload-arch version 24.0.0git (... 3eda2aebadd430199a1d588b6b22c966af5356d5)
exit=0
```
（注：verbose 拼写是 `--verbose` 不是 `-v`；三行失败串证明 all 模式下三个厂商后端都试过。）

---

## §6.2 存在意义：编译期探测 vs 运行时探测，Driver 侧调用闭环

**`--offload-arch=native` 的完整调用链**（全部行号已核对）：

1. 选项定义：`Options.td:1278-1283` `offload_arch_EQ`——HelpText 明言 "If 'native' is used the compiler will detect locally installed architectures"；HIP 特性 target ID 语法 `gfx908:xnack+:sramecc-`。`Options.td:1313-1318`：`offload_arch_tool_EQ`（可换探测工具），`amdgpu-arch-tool=`/`nvptx-arch-tool=` 是其历史别名。
2. **两处独立消费 native**：
   - 工具链推断：`inferOffloadToolchains`（Driver.cpp:968-987）——`Arch == "native"` 时调 `getSystemOffloadArchs(C, Kind)`（:975），再校验 HIP 只许 AMDGPU/amdgcnspirv、CUDA 只许 NVPTX（:1002-1011）。
   - 架构集合：`Driver::getOffloadArchs`（Driver.cpp:3963-4088）——`native` → `TC.getSystemGPUArchs(Args)`（:3983-3990）；空缺时 HIP 默认 `OffloadArch::HIPDefault()`、SPIR-V 走 `getGeneric()`（:4035-4038）。
3. `getSystemOffloadArchs`（Driver.cpp:921-962，static）：
   - 程序名 = `--offload-arch-tool=` 值或缺省 `offload-arch`（:924-925）；
   - `findProgramByName(Program, {Driver.Dir})`（:928-929，**优先在 clang 自身 bin 目录找**）；
   - 非 `-foffload-via-llvm` 时按 Kind 传 `--only=amdgpu`（HIP）或 `--only=nvptx`（CUDA）（:931-939）；
   - `executeProgram` 捕获 stdout（:940）；失败/空输出 → `err_drv_undetermined_gpu_arch`（"No GPU detected in the system"）（:942-953）；执行失败 → `err_drv_command_failure`（:959）。
   - 另一条并行的 ToolChain 层路径：`AMDGPUToolChain::getSystemGPUArchs`（AMDGPU.cpp:1082-1104）默认调 **`amdgpu-arch`**（legacy 名，:1088），空输出→"No AMD GPU detected in the system" error；Cuda.cpp:871 NVPTXToolChain 同构。基类 `ToolChain::getSystemGPUArchs` 缺省返回空（ToolChain.cpp:1901-1904，ToolChain.h:842-844）。
4. OpenMP 无 `-march` 时也隐式探测（Driver.cpp:4047-4057）。

**为什么必须是独立子进程**（分析）：
- **加载隔离**：offload-arch 把 `libamdhip64.so`/`libcuda.so.1` dlopen 进**自己的进程**再退出。若 Driver（clang 本体）直接 dlopen，用户系统上残缺/有 bug 的 GPU runtime 会把整个编译器搞崩（本机实测三连 dlopen 失败——若发生在 clang 进程内即崩溃风险）。
- **动态符号解析**：源码只用 `getAddressOfSymbol` 按名取函数（AMDGPUArchByHIP.cpp:288, 311），没有任何 HIP 头文件依赖，与任意 ROCm 版本二进制兼容。
- **可替换性**：`--offload-arch-tool=` 允许发行版/用户插自己的探测器——为异构后端（如 NPU）保留扩展点，这正是昇腾可插入的位置。
- **编译期 vs 运行时探测的分界**：编译期只需要架构名（gfx906/sm_90）来选 target-cpu/设备库/CodeObject ABI；一切运行时能力（显存、流、上下文）由 HIP runtime 在用户进程里自己做。offload-arch 是这条分界线上唯一的桥。

**昇腾映射（待验证）**：CANN 已有 `npu-smi info`（查询 NPU 型号/规格）与 `npu-arch` 类环境探测，但缺一个**编译器可 fork 的、每行输出一个规范化架构名、无 NPU 时空输出+非零退出**的小工具来对应 `--offload-arch=native` 的 Ascend 版。可验证锚点：毕昇/Ascend clang 是否有等价 `-x npu --offload-arch=native` 语义、其 Driver 是否允许 `--offload-arch-tool=` 式替换；CANN 的 `ATB/aclrtGetDevice` 探测属运行时层，不能替代编译期探测。

---

## §6.3 动态验证记录（build-debug @ 3eda2aebadd4，macOS 无 GPU/ROCm）

| # | 验证 | 命令 | 结果 | 结论 |
|---|---|---|---|---|
| V1 | offload-arch 无 GPU 行为 | `offload-arch`（及 `--only=amdgpu`、`--verbose`、`nvptx-arch`） | 全部 exit=1；静默版 stdout 空；verbose 版打印三条 dlopen 失败 + "Using default HIP runtime: libamdhip64.so" | 与源码路径吻合：HIP 路 return 1（AMDGPUArchByHIP.cpp:276-281）且无输出——Driver 侧判"空 stdout"报 No GPU（Driver.cpp:948-953）。legacy symlink nvptx-arch→offload-arch 生效（CMakeLists.txt:8） |
| V2 | hipMalloc 编译器零踪迹 | ripgrep `hipMalloc` 全 clang/ | 仅 HIPSupport.md:806 一处 doxygen 外链（hipMallocManaged，stdpar 节的 malloc 语义讨论） | 证明"HIP 运行时不在编译器里"：clang 实现的是 fatbin 注册 ABI（CGCUDANV.cpp:694/838/1017 的 `__hipRegister*` 内部符号），内存分配等 API 全在 ROCm 仓库的 libamdhip64.so；API 级兼容矩阵（CUDA2HIP.md）也随 runtime 而非编译器发布 |
| V3（附带） | 版本一致性 | `offload-arch --version` | `24.0.0git … 3eda2aebadd430199a1d588b6b22c966af5356d5` | 二进制与源树同源；`-v` 不识别（拼写是 `--verbose`） |

---

## 引用清单（全部经实际 grep/read 核对）

**主文档**：clang/docs/HIPSupport.md（1,159 行）:1-16（三色 role 定义未用）, :19-45（平台支持+NV/CPU note）, :79-89（amdgpu-arch/native 提及）, :97-136（路径优先级）, :169-177（`__HIP_NO_IMAGE_SUPPORT__`）, :208-310（fatbin 注册 ABI）, :312-321（与 CUDA 语法差异）, :327-343（函数指针/虚函数）, :407-463（managed variables）, :465-513（CTAD）, :534-613（Deferred Diagnostics）, :614-953（stdpar，:877-885 矩阵+内核 6.4）, :955-1159（PGO/coverage/SPIR-V :1124-1159）
**offload-arch 工具**（clang/tools/offload-arch/）：OffloadArch.cpp:20-33, 47-62, 76-87；AMDGPUArchByHIP.cpp:37-49（struct 镜像布局）, 55-83（符号/选项）, 161-221（DLL 搜索）, 257-444（主流程, 调用点 :273/:305/:347/:419/:440）；AMDGPUArchByKFD.cpp:9-11（不尊重 ROCR_VISIBLE_DEVICES）, 26-49, 63-65；NVPTXArch.cpp:26-44, 80-118（:90-92 无设备静默 0）；LevelZeroArch.cpp（libze_loader）；CMakeLists.txt:3-10（五源文件+双 symlink）
**Driver 侧**：clang/lib/Driver/Driver.cpp:921-962（getSystemOffloadArchs）, 968-1012（inferOffloadArchs/native 消费）, 3963-4088（getOffloadArchs, native :3983, 默认 :4035, OpenMP :4047）；ToolChain.cpp:1901-1904；ToolChains/AMDGPU.cpp:161-179（.hipVersion 解析）, 1082-1104（amdgpu-arch 调用）, 1106-1126（ABI 版本门槛 "6.3"）；ToolChains/Cuda.cpp:871
**选项**：clang/include/clang/Options/Options.td:1278-1287（offload-arch/no-offload-arch）, 1313-1318（offload-arch-tool 及别名）, 1409-1417（cuda-gpu-arch 别名族）, 1497-1513（hipstdpar 族）
**CodeGen 交叉**：clang/lib/CodeGen/CGCUDANV.cpp:694, 838, 1017（`__hipRegisterManagedVar`/`__hipRegisterFatBinary`）
**git 考古**：`795e934e15b7`（2023-07-25 引入, 175 行原版, 三色 role 亦未用）；`git log -S '{good}'` 无 API 矩阵增删提交
**统计方法**：三色标记 grep `\{(none|part|good)\}`：HIPSupport.md=0，OpenMPSupport.md=244；`hipMalloc` 全 clang 树=1（HIPSupport.md:806）
