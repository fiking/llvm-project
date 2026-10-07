# §2 clang Driver 的 AMDGPU 路径深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，clang-24 @ build-debug 实测（amdgcn-amd-amdhsa, gfx1100）。
> 引用格式 `文件:行号`；实测素材 `Clang-AMDGPU-notes/scratch/driver_amdgcn.txt` + 主会话 -### 三组对比。
> 素材来源：子代理调研（引用已核实，含一处选项证伪）+ 主会话动态验证代写。
> 对照阅读：NVPTX-notes/06-downstream.md（CUDA 四阶段 -###）。

---

## 2.1 ROCMInstallation 探测链

**getInstallationPathCandidates()（AMDGPU.cpp:185-315，结果缓存 ROCmSearchDirs）**：

| 序 | 候选 | 严格性 | 行号 |
|---|---|---|---|
| 1 | `--rocm-path` | 非严格（不校验版本文件/device lib） | :203-206 |
| 2 | `ROCM_PATH` 环境变量 | 非严格 | :207-214 |
| 3 | clang 二进制目录回推（剥 bin/、bin/{host}、llvm/、aomp*、lib/） | **StrictChecking=true** | :217-250 |
| 4 | clang 真实路径（符号链接解析后） | | :252-258 |
| 5 | ClangRoot + ResourceDir | | :260-267 |
| 6 | SysRoot+/opt/rocm | | :269-270 |
| 7 | 最新 /opt/rocm-{release}（目录名版本号比较） | | :272-306 |
| 8 | /usr/local、/usr | | :308-311 |

**版本解析** parseHIPVersionFile（:161-183）：HIP_VERSION_MAJOR/MINOR/PATCH，候选 `share/hip/version`、`../share/hip/version`、`bin/.hipVersion`（detectHIPRuntime :494-499）；默认 3.5.0。

**触发点**：AMDGPUToolChain 构造 :743-745——仅当 `OS==AMDHSA && env!=LLVM && !-foffload-via-llvm`。RocmInstallation 是 Generic_GCC 继承的 `LazyDetector<RocmInstallationDetector>`（Gnu.h:359，LazyDetector.h:21-41 惰性实例化）。

**报错产生点** checkCommonBitcodeLibs（:1106-1128）`err_drv_no_rocm_device_lib` 三形态：:1110（完全找不到 <<0）/ :1114（缺特定 arch libdevice <<1）/ :1121-1123（缺 ABI 版本 bc，COV≥6 附加 "requires ROCm 6.3 or higher"）。原文 DiagnosticDriverKinds.td:71-75。HIP 路径独立报 :1243-1246。

## 2.2 device library 发现机制

**文件名扫描** scanLibDevicePath（:95-157）：.bc/.amdgcn.bc，映射 `ocml`→OCML、`ockl`→OCKL、`opencl`、`asanrtl`、`oclc_finite_only_on/off`、`oclc_unsafe_math_on/off`、`oclc_wavefrontsize64_on/off`、`oclc_abi_version_NNN`→ABIVersionMap、`oclc_isa_version_XXX`→LibDeviceMap["gfxXXX"]（:145-154）。

**搜索顺序** detectDeviceLibrary（:375-436）：`--rocm-device-lib-path`（取 .back() :379）→ `HIP_DEVICE_LIB_PATH`（:380-382）→ ResourceDir 下 amdgcn/bitcode（:419-424）→ 各 ROCm 候选+amdgcn/bitcode 旧布局（:428-435）。

**链接列表** getCommonBitcodeLibs（:1130-1167）：asanrtl(条件)→**ocml→ockl**(OpenMP 默认跳过)→oclc_unsafe_math→oclc_finite_only→oclc_wavefrontsize64→**libdevice**→oclc_abi_version。OpenCL 额外链 opencl.bc（:1290）。**ABI 版本 = COV×100**，COV≥5 必须（RocmInstallationDetector.h:18-37）；COV 默认 6（CommonArgs.cpp:2747-2753）。

**-nogpulib 精确语义**：`--no-offloadlib` 别名（Options.td:6633-6635，nocudalib 同别名 :6636）。三个作用点：①cc1 LangOpts NoGPULib marshalling（Options.td:6625-6628）；②addClangTargetOptions :984-986 提前返回（**砍掉全部 -mlink-builtin-bitcode**）；③getDeviceLibs :1196-1199 提前返回（**同时不再触发报错**——实测 -nogpulib 后 fake rocm-path 不报错）。

**死代码发现**：RocmInstallationDetector.h:123 的 NoBuiltinLibs 字段仅声明+2 处读取（:399/:405）、无赋值为 true 的代码——本 revision 残留死代码。

## 2.3 工具链集成

**双 Linker**（:751-756，源码自带 FIXME "Should not have 2 linker paths"）：
- amdgpu::Linker（:631-688）：默认 `ld.lld`（AMDGPU.h:116）；非 -r 时 `--no-undefined -shared`；LTO 或 `-plugin-opt=mcpu=<processor>`（:649-654，从 target id 剥离特性）；恒传 `-plugin-opt=-mattr=<target-id features>`（:660-667）
- AMDGCN::Linker（HIPAMD.cpp:194-210）按 JA 类型分派：TY_HIP_FATBIN→bundler；TY_LLVM_BC→llvm-link（CommonArgs.cpp:3430-3453）；SPIRV→link+translate；否则 constructLldCommand（HIPAMD.cpp:50-138）：`lld -flavor gnu -m elf64_amdgpu --no-undefined -shared -plugin-opt=-amdgpu-internalize-symbols`，**输入包 --whole-archive**（:114，device linker 看不到 host 侧符号依赖）

**clang-offload-bundler**（HIPUtility.cpp:28,33-91）：`-type=o -bundle-align=4096`（HIPCodeObjectAlign=4096 :28）；dummy host 条目 `host-x86_64-unknown-linux-gnu`+/dev/null；COV≥4 用 `hipv4-` 前缀（:52-55）；**normalizeForBundler 强制 amdgcn- 前缀因 HIP runtime fatbin 解析器硬编码**（TargetID.cpp:212-224）。与 NVPTX 差异：**通用 bundler 的 4096 对齐打包 vs 专用 fatbinary 格式**。

**--hip-link**（Options.td:1488）vs **--offload-link**（Options.td:1104）：后者强制 LinkerWrapperJobAction→clang-linker-wrapper（Driver.cpp:3736-3740）；--hipstdpar 自动加 --hip-link（Driver.cpp:3440-3444）。

## 2.4 target id 解析

- `-march` legacy 别名→改写 -mcpu（TranslateArgs :771-778，仅 OFK_None）；`-mcpu=native`→执行 **amdgpu-arch 工具**（:780-796, :1081-1104；实测 build-debug/bin/amdgpu-arch 存在）
- **parseTargetID**（TargetID.cpp:121-142）：格式检查（`gfx908:sramecc+:xnack-`，特性唯一必带 +/-，:83-119）→ 规范名（getCanonicalArchName，AMDGPUTargetParser.cpp:588-595；接受 `amdgpu9.00` triple 拼写别名 :62-68）→ 特性合法性（xnack 仅当 FEAT_XNACK_ON_OFF_MODES :23-41）
- **gfx1100 与 gfx1100a 是 GPU 表中两个不同 GPUKind**（AMDGPUGPUTable，AMDGPUTargetDefEmitter.cpp:620 生成），同 subarch 家族经 isSubArchCompatible（:193-207）兼容
- target id 特性→合成 `-m{x,no-}xnack/-m{sramecc}`（:807-825）→ mattr 传 lld（:660-667）
- **subarch 进 triple**：setArchNameInTriple（Arch/AMDGPU.cpp:20-42，GK_NONE 时把 legacy amdgcn 规范化为 **amdgpu** :34-38）——scratch 里 `amdgpu11.00-amd-amdhsa` 的来源
- ASan 要求 xnack+（:1398-1405）

**选项证伪**：`--no-gpu-args` **本树不存在**（全 clang/ grep 零命中，疑 ROCm fork 特有）。

## 2.5 动态验证（实测）

**A. 三组 -### triple 对比**：
```
--target=amdgcn-amd-amdhsa（无 -mcpu）→ -triple amdgpu-amd-amdhsa        （无 subarch）
-mcpu=gfx1100                      → -triple amdgpu11.00-amd-amdhsa      （subarch 进 triple ✓）
-mcpu=gfx1100a                     → -triple amdgpu-amd-amdhsa            （'a' 变体不进 triple）
```

**B. fake rocm-path 报错路径**：`--rocm-path=/tmp/fake` → **err_drv_no_rocm_device_lib 原样复现**（非严格模式不报版本错，只在需要 device lib 时报）+ `-nogpulib` 后同命令**不再报错**（getDeviceLibs 提前返回的实证）。

**C. -nogpulib 展开**：-### 输出可见 `-nogpulib` → cc1 参数 `--no-offloadlib`（别名 marshalling 实证）；本机无 ROCm，mlink-builtin-bitcode 列表无法正测（OpenCL 会因缺 opencl.bc 报错而非添加参数——与 :1106 报错链一致）。

**D. HIP 双报错**：`--offload-arch=gfx1100` → 同时报 device library + **HIP runtime**（"cannot find HIP runtime; provide its path via --rocm-path, or pass -nogpuinc"）——device lib 与 runtime 头是两条独立探测链。

## 2.6 昇腾映射（推理级，待验证）

- CCE 探测链 `--cann-path`/`ASCEND_TOOLKIT_HOME`/默认 `/usr/local/Ascend/ascend-toolkit/latest` ≈ ROCmInstallation 的 --rocm-path→ROCM_PATH→/opt/rocm{,-release}（:203-214 vs :269-306）
- ccec→tcch→atc 中 atc 的运行时库解析 ≈ ocml/ockl/oclc bitcode 链接，但**昇腾走离线编译而非 bitcode 内链**——结构差异大于相似
- `gfx1100:xnack+` ≈ `ascend310p3` 的"处理器+SoC 版本"语义（target id 的 canonical 化对照）

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| AMDGPU.cpp:95-157, 161-183, 185-315, 375-436, 494-499, 631-688, 743-756, 771-825, 984-986, 1081-1128, 1130-1167, 1196-1246, 1290, 1361-1405 | 探测链/device lib/linker/target id |
| AMDGPU.h:116 / HIPUtility.cpp:28, 33-91 / HIPAMD.cpp:50-210 | 工具链集成 |
| TargetID.cpp:23-142, 212-224 / Arch/AMDGPU.cpp:20-42 / AMDGPUTargetParser.cpp:588-595 | target id 解析 |
| RocmInstallationDetector.h:18-37, 96-98, 123 / Gnu.h:359 / LazyDetector.h:21-41 | 惰性探测 |
| Options.td:1488, 6614-6636, 1104 / DiagnosticDriverKinds.td:71-75 / CommonArgs.cpp:2747-2753, 3430-3453 | 选项与报错 |
| AMDGPUTargetDefEmitter.cpp:620 | gfx1100 vs gfx1100a |

实测素材：scratch/driver_amdgcn.txt（基线）+ 主会话 A/B/C/D 四组（triple 对比/fake 报错/nogpulib 展开/HIP 双报错）。
