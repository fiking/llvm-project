# HIP（Heterogeneous-compute Interface for Portability）深度分析

> 数据基准：llvm-project main @ `3eda2aebadd4`（2026-10-03），clang-24 @ build-debug 实测（-### 全链/宏互斥/-E 展开/offload-arch 行为）。
> 方法：静态分析（引用一律 `文件:行号`，4 个子代理+主会话实读核对）+ 动态验证（-### v1-v11 dump/宏导出 diff/头文件预处理展开/无 GPU 探测行为）。
> 十部曲定位：本卷是 HIP 全栈专卷——语言机器复用审计、Driver 工具链双路径、头文件镜像、官方文档、探测工具五层。
> 素材全文：`HIP-notes/00~04-*.md`（464 行）；scratch/ 存 11 组实测 dump。

---

## 目录

- §1 摘要与核心论点
- §2 语言机器复用审计
- §3 Driver 工具链双路径
- §4 头文件族镜像
- §5 官方兼容文档
- §6 offload-arch 探测工具
- §7 三层差异图与四路线光谱
- §8 昇腾映射
- §9 复现手册

---

## §1 摘要与核心论点

> **HIP 是"CUDA 的方言化重实现"：语言机器 100% 复用（一行蕴含式开关），差异全部外推到生态层（Driver/头文件/运行时/工具链产物）**。`LangOptions.cpp:218` 的 `Opts.CUDA = Lang==CUDA || Opts.HIP` 是整个设计的支点——HIP 通过**蕴含 CUDA** 获得整套 Sema/CodeGen，仅在 11 个分支点做特判（行为 6+符号名 1+纯注释 4）。生态层的差异则各自成章：Driver 双路径（HIPAMD ROCm 本体/HIPSPV SPIR-V 替身）、头文件 95.3% 镜像但落点策略不同（__ocml/__builtin 双路 vs __nv_ 全 libdevice）、运行时完全不在编译器里（hipMalloc 全树 1 处 doxygen 外链）。

**五个贯穿性实证**：
1. **蕴含式总开关**（:217-218）——零复用成本的机制根源；宏互斥实测：`-x hip` 下 `__CUDA__/__CUDACC__` 0 定义
2. **V6 决定性全链**：`lld -flavor gnu -m elf64_amdgpu --whole-archive` + `clang-offload-bundler -targets=host-x86_64-unknown-linux-gnu,hipv4-amdgcn-amd-amdhsa--gfx1100`——与源码逐字吻合；**dummy host 条目**是 bundle vs fatbin 的载体差异
3. **UseSPIRVBackend 默认 true**：hipSPV 已从外置 llvm-spirv 过渡到 in-tree SPIR-V 后端
4. **95.3% 镜像率**（244/256）+ cosf→__ocml vs sqrtf→__builtin 双路实测
5. **HIPSupport.md 不是 API 矩阵**：三色 role 定义了但 0 使用——真正的 CUDA2HIP 矩阵在 ROCm 仓库（git 考古 `795e934e15b7` 证明从未存在过）

---

## §2 语言机器复用审计（详见 01-reuse-audit.md）

- **总开关**：LangOptions.cpp:217-218 HIP⟹CUDA——Sema/CodeGen/Attr.td 全走 CUDA 路径
- **SemaCUDA 11 分支**：行为差异 6（CDP 不支持/device launch 硬错误/HIPManaged→CVT_Unified/HIPStdPar 放行/全局初始化错误）+ 符号名 1（__hipPushCallConfiguration）+ 纯注释 4
- **Attr.td 零 HIP 专属语法属性**（HIPManaged 唯一例外）；内建变量同一实现（__clang_gpu_builtin_vars.h 双宏守卫→gpuintrin.h）
- **CodeGen 13 差异点**：fatbin 命名（__HIP,__hip_fatbin/4096 对齐）/launch 符号/handle 形态（稳定 GlobalVariable）
- **昇腾映射**：ASCENDC⟹CUDA=true 仿写，平台语义必须自写仅三类（CDP/managed attr/launch 符号）

## §3 Driver 工具链双路径（详见 02-driver.md）

- **HIPAMD 四路分发**：TY_HIP_FATBIN→bundler / TY_LLVM_BC→llvm-link / isSPIRV→in-tree SPIR-V / 默认→lld（--whole-archive 可见性 workaround）
- **HIPSPV 替身链**：spirv64 triple→llvm-link→opt 插件→SPIR-V 后端；host 承接=chipStar over Level Zero/OpenCL；触发 `--offload=spirv64-unknown-chipstar`
- **RDC**：默认非 RDC；RDC embed -fembed-offload-object，设备链接藏 wrapper 内；与 CUDA 同构（CUDA 直出 TY_CUDA_FATBIN）
- **Driver.cpp 97 处 HIP 引用六类**：探测/TC 创建/Action 图/输入类型/链接门/wrapper 转发

## §4 头文件族镜像（详见 03-headers.md）

- **镜像统计**：HIP 256 vs CUDA 562（math+devfn 合并），交集 244=**95.3%**；CUDA 多出 318 个=__dadd_rd 系 IEEE 取整（ROCm 走 intrinsic）
- **落点策略**：__ocml_* 库调用+__builtin_* 直通 双路 vs CUDA __nv_* 全 libdevice.10.bc
- **宏名代际**：HIP 用 __CLANG_GPU_* 共享前缀（CUDA 头在迁移中）——共享层终态是 gpu 前缀统一
- **wrapper 短 3.4 倍**：SDK 兼容层由 ROCm 维护（hip_runtime_amd.h），clang 不做宏污染

## §5 官方兼容文档（详见 04-matrix-tools.md §5）

- **HIPSupport.md 1,159 行实为语言语义/ABI/诊断文档**——三色 API 矩阵 role 定义但 0 使用；真正 API 矩阵在 ROCm 仓库 CUDA2HIP.md+hipify-clang
- **版本耦合仅两点**：.hipVersion 解析（AMDGPU.cpp:161-179）+ COV6 需 ROCm≥6.3

## §6 offload-arch 探测工具（详见 04-matrix-tools.md §6）

- **完整调用链**：Options.td:1313 可替换工具→Driver.cpp:921-962 fork+exec 子进程→OffloadArch.cpp 三厂商 VendorTable→AMD 双路径（KFD sysfs 优先/HIP dlopen fallback）→手工 ABI 偏移镜像 struct（R0600/R0000 避免 ROCm 编译期依赖）
- **无 GPU 实测**：exit=1 静默；--verbose 打三条 dlopen 失败链（libamdhip64/libcuda/libze_loader）
- hipMalloc 全 clang 树 1 处（doxygen 外链）——**运行时不在编译器里**的实证

---

## §7 三层差异图与四路线光谱

### 三层差异图

| 层 | CUDA | HIP | 复用率 |
|---|---|---|---|
| 语言机器（Sema/CodeGen/Attr） | 本体 | 蕴含式复用+11 分支 | **~100%** |
| Driver/工具链（ToolChain/Action/产物） | fatbinary（自家格式） | bundler bundle（CCOB 魔数）+lld | 图结构同构，Tool 全换 |
| 生态（头文件/运行时/数学库） | libdevice.10.bc+NVVMReflect | __ocml/__ockl+oclc 求值 | 95.3% 镜像但落点策略不同 |

### 四路线光谱（CUDA↔OpenCL 轴的最终版）

```
OpenCL（库接力）── AscendC（中部偏左）── HIP（方言复用）── CUDA（编译器一等公民）
                        Clang-AMDGPU §8 判定        本卷修正：HIP 独立成点——
                                                    语言零差异+生态全差异
```

## §8 昇腾映射（汇总，推理级标"待验证"）

1. **PyPTO "CUDA 兼容层"判定**：若存在应是 **HIP 式**（ASCENDC⟹CUDA 蕴含开关+Sema 三类自写+生态层重定义），而非完整 CUDA 克隆——工作量估算：语言层 ≤14 分支，大头在生态层
2. **amdgcnspirv 伪 target ↔ pto-isa 双目标**：虚拟 arch 编译（generic spirv64+禁向量化+运行时特化）vs davinci ISA——"为 CPU 模拟器编译 IR"的现成范式
3. **API 矩阵放 runtime 仓库**（CUDA2HIP 模式）而非编译器仓库——CANN 若做 CUDA API→AscendCL 映射应学此分工
4. **数学层选型**：HIP 模式（同名→runtime 直调，__builtin 直通）vs CUDA 模式（声明+链接期 bc）——**推荐 HIP 模式**（头文件即闭合，无 bc 分发负担）；多后端则用平台无关前缀（__CLANG_GPU_* 代际教训）
5. **架构探测小工具**：CANN 需补一个编译器可 fork 的探测工具（对应 offload-arch），`--offload-arch-tool=` 是现成扩展点
6. **bundler 多 target-ID 产物**（triple+arch+kind，4096 对齐）对应多昇腾芯片 fat 产物

## §9 复现手册

```bash
cd ~/code/llvm-project   # main @ 3eda2aebadd4
CC=build-debug/bin/clang-24

# 宏互斥（§2）
printf '__global__ void k() {}\n' > HIP-notes/scratch/t.hip
$CC -x hip --cuda-device-only -nogpuinc -nogpulib --offload-arch=gfx1100 -dM -E -o - HIP-notes/scratch/t.hip | grep -cE "__CUDA__|__CUDACC__"   # 0
# 坑：-nogpuinc 报 unknown type name '__global__'（同 CUDA -nocudainc）；缺 -nogpuinc 报 rocm-path 指引

# 全链 dump（§3——11 组 scratch/v1-v11）
$CC -### -x hip --cuda-device-only -nogpuinc -nogpulib --offload-arch=gfx1100 HIP-notes/scratch/t.hip 2>&1 | grep -E "lld|bundler"
# RDC：-fgpu-rdc；hipSPV：--offload=spirv64-unknown-chipstar

# 头文件落点（§4）
$CC -E -x hip --offload-arch=gfx1100 -include __clang_hip_math.h -o - <(echo 'float f(float x){return cosf(x);}') 2>/dev/null | grep __ocml

# offload-arch 无 GPU 行为（§6）
build-debug/bin/offload-arch --verbose; echo $?   # 三条 dlopen 失败链 + exit 1
```

---

## 附录：执行注记

| 章 | 素材 | 产出方式 |
|---|---|---|
| §2 | 01-reuse-audit.md | 子代理静态审计+主会话补 4 条动态验证 |
| §3 | 02-driver.md | 子代理完整素材+11 组实测，主会话代写组装 |
| §4 | 03-headers.md | 子代理 #60203 卡死→transcript 164 行素材回收+主会话代写 |
| §5+§6 | 04-matrix-tools.md | 子代理一次写盘（21.8KB） |

**项目曲折**：首日四路全灭于网关 FD 耗尽（Errno 24）——用户手动重启网关恢复，全部重派。任务前提证伪修正 **8 处**（hipDeviceTable 不存在/HIPSupport 非 API 矩阵/Options.td 新路径/OffloadArch 拆分/宏互斥/__CUDACC__ 非预定义/UseSPIRVBackend 默认开/-nogpuinc vs -nogpulib）。
