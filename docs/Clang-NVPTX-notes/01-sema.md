# §2 clang 的 CUDA host/device 双编译语言机器 —— SemaCUDA.cpp 深度分析

> LLVM main @ 3eda2aebadd4。clang/lib/Sema/SemaCUDA.cpp 实测 1297 行（wc -l）。
> 本文所有 文件:行号 引用均经本会程 grep/read 核对。动态验证章节标注"待执行"（子代理额度耗尽，命令配方已备好）。
> 防重复：CGCUDANV fatbin 嵌入见 NVPTX-notes/06-downstream.md（:820-1108）；HIP builtin 摩擦见 Clang-AMDGPU-notes/06-intrinsics.md。

## 0. 文件地图与核心数据结构

SemaCUDA 已从 Sema 拆分为独立类 `SemaCUDA : SemaBase`（SemaCUDA.h:45，构造 SemaCUDA.cpp:30），Sema 各阶段通过 `CUDA().` 调用。三个跨文件持久状态：

- `CurCUDATargetCtx`（SemaCUDA.h:138-142）：函数外代码的目标上下文，默认 `HostDevice`，仅被全局变量初始化 RAII 修改（见 §1.3）。
- `ForceHostDeviceDepth`（SemaCUDA.h:290-291，SemaCUDA.cpp:40-51）：`#pragma clang force_cuda_host_device_begin/end` 计数器（ParsePragma.cpp:369 注册，:4025-4051 处理）。
- `DeviceKnownEmittedFns` 反向调用图 + `LocsWithCUDACallDiags` 去重表（SemaCUDA.h:63-83），服务于延迟诊断（§3.4）。

## 1. IdentifyTarget 四态机制

### 1.1 静态分析

**两个重载**。解析期版本 `IdentifyTarget(const ParsedAttributesView&)`（SemaCUDA.cpp:146-183）直接扫 ParsedAttr：优先级 `InvalidTarget > Global > HostDevice > Device > Host`（:170-182）——`__global__` 与 `__host__ __device__` 组合时 Global 胜出。

语义期版本 `IdentifyTarget(const FunctionDecl*, bool IgnoreImplicitHDAttr=false)`（SemaCUDA.cpp:211-246）是全 clang 的唯一权威（头文件明令"Use this rather than examining the function's attributes yourself -- you will get it wrong"，SemaCUDA.h:110-114）。判定链：

1. `D == nullptr` → 返回 `CurCUDATargetCtx.Target`（:213-215）——函数外代码的兜底。
2. `CXXDeductionGuideDecl` → `HostDevice`（:220-221）：推导引导不参与 codegen，双侧放行。
3. `CUDAInvalidTargetAttr` → `InvalidTarget`（:223-224）：由特殊成员推断冲突注入（§3.2）。
4. `CUDAGlobalAttr` → `Global`（:226-227）。
5. `isConsteval()` → `HostDevice`（:229-230）：immediate function 必然编译期双侧可用。
6. Device+Host attr → `HostDevice`；仅 Device → `Device`；仅 Host → `Host`（:232-237）。
7. **:238-243（任务书锚点）**：`(D->isImplicit() || !D->isUserProvided()) && !IgnoreImplicitHDAttr` → `HostDevice`。原注释："Some implicit declarations (like intrinsic functions) are not marked. Set the most lenient target on them for maximal flexibility." —— **隐式声明/非用户提供函数（编译器合成成员、内建）直接按最宽松的双态处理**。注意：任务书所称"ImplicitHost 第四态"并不存在为独立枚举值——隐式声明折入 HostDevice；枚举实为五值（含 InvalidTarget，SemaCUDA.h:119-124 为变量侧、函数侧枚举在 Sema.h 引用）。无标注的普通函数落入 :245 的 `Host`。
8. `IgnoreImplicitHDAttr=true` 的用途：把隐式 H+D 折叠回显式视角，用于模板特化目标比对（SemaTemplate.cpp:9684-9685、:11013-11014）与 constexpr 冲突检测。

**CurrentTarget 的维护（证伪任务书假设）**：没有"Sema 入口处 push/pop CUDA 目标栈"。`CurrentTarget()` 是即时查询：`IdentifyTarget(dyn_cast<FunctionDecl>(SemaRef.CurContext))`（SemaCUDA.h:152-155）。`CurContext` 由通用的 `Sema::ContextRAII` 维护（Sema.h:3545-3551 push 旧值/设新值/析构还原），解析进入函数体时 CurContext 即为该 FunctionDecl——CUDA 只是搭便车。CUDA 专属栈仅两处：CurCUDATargetCtx 单槽 RAII（§1.3）与 ForceHostDeviceDepth 计数器。

### 1.2 模板/lambda 特判

- **模板特化不重跑 maybeAddHostDeviceAttrs**：SemaDecl.cpp:10998-11005 注释明言特化的 constexpr-ness 可能与模板不同，"after maybeAddHostDeviceAttrs() is applied, may end up with different effective targets"，故特化改由 `inheritTargetAttrs`（SemaCUDA.cpp:1220-1226，`copyAttrIfPresent` 克隆 Global/Host/Device attr 并标 Inherited）从主模板继承，调用点 SemaTemplate.cpp:9867。
- **模板推导期目标比对**：`Sema::CheckFunctionTemplateSpecialization` 与显式实例化路径各有一处 `CUDATargetMismatch` 推导失败（SemaTemplate.cpp:9682-9691、:11010-11022，注释"Target attributes are part of the cuda function signature"）——C++ 推导不看目标属性，clang 在推导成功后补一刀目标校验。
- **lambda**：见 §5，默认隐式 H+D。

### 1.3 全局变量初始化上下文（CurCUDATargetCtx）

`CUDATargetContextRAII`（SemaCUDA.cpp:193-208）在 ParseDecl.cpp:2612 包住每个声明初始化器解析。规则：显式 `__device__`（且无显式 `__host__`）或 `__shared__`/`__constant__` 的全局变量 → Target=Device，否则 Host（:200-205）。下游效应：`IdentifyPreference` 对 `Caller==nullptr && CTCK_InitGlobalVar && Device` 的构造/析构调用直接返回 `CFP_HostDevice`（SemaCUDA.cpp:318-321），让平凡 ctor/dtor 在设备变量初始化中放行，非平凡的交给 checkAllowedInitializer（§4.3）。

### 1.4 设计动机

四态本质是**一份源码、两次编译（host pass + device pass）下的符号归属判定**。`CUDAIsDevice`（编译模式）与函数目标（语言属性）正交：HD 函数在两次编译中都存在，但每次只"属于"一侧——这正是 WrongSide/延迟诊断（§3.4）存在的根源。ImplicitDecl→HD（:238-243）是为了让 `<cstring>` 等内建/隐式函数无需改写头文件即可在 device 代码中使用。

### 1.5 昇腾映射（推理级，待验证）

AscendC 是纯设备侧 DSL（host 侧是普通 C++ 调 CANN runtime API），若属实则**根本不存在 IdentifyTarget 这一层的必要性**——每个 TU 单侧编译，无"同一符号双侧归属"问题。CUDA 机器存在的前提是"单源双编译"，AscendC 用"源码物理分侧（host cpp / device kernel cpp 分离）"消解了同一问题。待验证点：CCE 编译器是否复用 clang Sema 且关闭 LangOpts.CUDA（若是，本节全部机制对其是死代码路径）。

## 2. 重载解析的双侧规则

### 2.1 静态分析

**偏好表**（SemaCUDA.cpp:282-308 注释原表）：F=caller，T=callee，Ph/Pd=host/device 编译模式下的偏好，N=native、SS=same side、HD=host-device、WS=wrong side、--=never。关键行：`d→g`/`g→g` 允许（动态并行 CDP，:332-337 实现）；`h→g` native（:302，host 启动 kernel）；`hd→d` Ph=WS/Pd=SS（:305，模式相关）；`d→h`、`h→d`、`g→h` 均 never（:299/:301/:308）。

**偏好枚举**按 worst→best 数值排序（SemaCUDA.h:159-170）：`CFP_Never < CFP_WrongSide < CFP_HostDevice < CFP_SameSide < CFP_Native`。`IdentifyPreference`（SemaCUDA.cpp:310-389）按 (a)~(e) 顺序实现上表，其中：
- (d) HD caller 调模式匹配侧 → SameSide（:362-370）；不匹配 → WrongSide，注释明言"allowed at the sema level, but eventually rejected if they're ever codegened. TODO: Reject said calls earlier"（:372-376）。
- (e) 跨侧 → Never（:379-386）。
- HIPStdPar 特例：device 侧调 host 函数乐观放行为 HostDevice（:351-359，交后续 pass 裁决）。

**同签名 host/device 双版本选谁**：三条通道——
1. **IsOverload 双侧签名**：`IsOverloadOrOverrideImpl` 在 `ConsiderCudaAttrs=true` 时，同签名不同目标 ⇒ 判为重载（允许共存），析构函数除外（SemaOverload.cpp:1662-1668）；虚函数 constexpr 覆盖特例（:1670-1678）。
2. **取地址/重载集消歧**：`EraseUnwantedMatches`（SemaCUDA.cpp:409-431）用 `llvm::max_element` 找最高 CFP，erase 全部低优先级候选；调用点 SemaOverload.cpp:14118（`EliminateSuboptimalCudaMatches`）。效果：device 编译时同签名 {host, device} 双版本只剩 device 版。
3. **checkTargetOverload**（SemaCUDA.cpp:1162-1206，调用点 SemaDecl.cpp:12807，门 `!Redeclaration && LangOpts.CUDA` :12798）：**HD 或 Global 不允许与同签名其他目标函数重载**（:1177-1194，`err_cuda_ovl_target`，DiagnosticSemaKinds.td:9836）——理由在注释："HD/global functions 'exist' in some sense on both the host and device, so should have the same implementation on both sides"。host/device 互相重载仅告警 `warn_offload_incompatible_redeclare`（nvcc-compat 组，DefaultIgnore，:1196-1203）——NVCC 把它当重声明，clang 是超集。

**__global__ 只能 host 调**：表行 `h→g`=N、`g→g`/`d→g`=CDP。device 侧启动 kernel 需 RDC（`-fgpu-rdc`），否则 `err_cuda_device_kernel_launch_require_rdc`（SemaCUDA.cpp:1063-1072）；HIP 直接 `err_cuda_device_kernel_launch_not_supported`（:86-88）。

**device 调 host 的报错链**：`MarkFunctionReferenced`（SemaExpr.cpp:19263）与取地址诊断路径（SemaExpr.cpp:319）→ `CheckCall`（SemaCUDA.cpp:1018-1102）：unevaluated/常量求值上下文放行（:1022-1025）；推导引导放行（:1030-1031）；按 `getEmissionStatus(Caller)` 决定 `K_ImmediateWithCallStack` 还是 `K_Deferred`（:1041-1061）；`LocsWithCUDACallDiags` 去重（:1085-1090，注释解释为何必须哈希表去重）；最终 `err_ref_bad_target << IdentifyTarget(Callee) << 0 << Callee << IdentifyTarget(Caller)`（:1092-1095）+ `note_previous_decl`（:1096-1099）。重载候选侧的失败注记 `note_ovl_candidate_bad_target` 在 `DiagnoseBadTarget`（SemaOverload.cpp:12746-12760，:13004 调用），并能反向触发 `inferTargetForImplicitSpecialMember` 补诊（:12765 以下）。

### 2.2 动态验证（待执行——命令已按 00-baseline.md 坑位配置）

---

## 动态验证补录（主会话实测，--cuda-device-only 绕坑路径）

```bash
# V1: host 函数被 device 调用（Sema 排除链）
$ clang-24 --target=nvptx64-nvidia-cuda -march=sm_70 -nocudainc -nocudalib --cuda-device-only -S -o /dev/null err1.cu
error: no matching function for call to 'hostfn'
note: candidate function not viable: call to __host__ function from __device__ function
# ——host 候选在 device 侧被"标记为不可行"而非硬错误（重载机制的 CUDA 扩展）

# V2: __global__ 返回 int
error: kernel function type 'int ()' must have void return type

# V3: 重载正常解析（device 侧多候选按常规规则）
IR: %call = call noundef i32 @_Z1fi(i32 noundef 1)   ← 选 int 版本

# V4: __global__ 成员函数
error: kernel function 'm' must be a free function or static member function
```

四条 Sema 校验链全部实测命中；错误消息原文可直接用于文档引用。
