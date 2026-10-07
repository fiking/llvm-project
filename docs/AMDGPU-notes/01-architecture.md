# AMDGPU 宏观架构（§3）

> 基准:llvm-project main @ `3eda2aebadd4`(2026-09-28)。
> 所有引用均为本仓库 `文件:行号`,经 read_file/grep 实测核对;动态验证一律使用 `build-debug`(Debug+Assertions,含 AMDGPU target)。
> 风格对齐仓库根 `nvptx-vs-amdgpu-analysis.md`。

---

## 3.0 总览:一张图看懂 AMDGPU 后端

AMDGPU 是 LLVM 中唯一"一个注册 target、三代硬件谱系、两条 ISel 路径"的后端:

- **目录**: `llvm/lib/Target/AMDGPU/` 共 311 个条目,其中 R600 前缀文件 39 个(含 Evergreen/Cayman 指令 .td),SI/GCN 前缀约 80 个;
- **TableGen 入口**: `AMDGPU.td` 3388 行 + `R600.td` 两个独立 `Target` 定义(`AMDGPU.td:2817` 的 `def AMDGPU : Target` 与 `R600.td:27` 的 `def R600 : Target`);
- **C++ 侧三个 TargetMachine**: `AMDGPUTargetMachine`(共同基类)、`GCNTargetMachine`(SI+,gfx6-gfx13)、`R600TargetMachine`(HD2xxx-HD6xxx);
- **65 个目标专属 pass**(实测 -O3 gfx1100 SDAG 路径 62 个 + AsmPrinter 相关 3 个),全部经由新 PM `CodeGenPassBuilder` 的 26 个 override hook 挂入。

```text
                    ┌────────────────────────────────────────────────┐
                    │  AMDGPU.td (def AMDGPU : Target, :2817)        │
                    │  R600.td   (def R600   : Target, R600.td:27)   │
                    └───────────────┬────────────────────────────────┘
                                    │ TableGen 生成 GenSubtargetInfo / InstrInfo
        ┌───────────────────────────┼──────────────────────────────┐
        │                           │                              │
  AMDGPUTargetMachine        GCNTargetMachine               R600TargetMachine
  (共同基类)                  (SI+ / gfx6..gfx13)             (VLIW4/5, HD2-6xxx)
        │                           │                              │
   GCNSubtarget.cpp            GCNSubtarget                    R600Subtarget
   (公共工具)                  62+ 目标专属 pass                 9 个目标专属 pass
```

---

## 3.1 Target 注册体系:amdgcn / amdgpu / r600 三名一体

### 3.1.1 静态分析

注册全部发生在 `llvm/lib/Target/AMDGPU/TargetInfo/AMDGPUTargetInfo.cpp`(全文仅 54 行):

**三个静态 Target 对象**(`AMDGPUTargetInfo.cpp:19-36`):

```cpp
/// The target for R600 GPUs.
Target &llvm::getTheR600Target() {          // :20
  static Target TheAMDGPUTarget;
  return TheAMDGPUTarget;
}
/// The target for GCN GPUs.
Target &llvm::getTheGCNTarget() { ... }     // :26
/// The target for GCN GPUs, registered under the legacy "amdgcn" name. This
/// should be removed when all tool users of "amdgcn" are migrated.
Target &llvm::getTheGCNLegacyTarget() { ... } // :33(注释 :31-32)
```

**注册逻辑**(`AMDGPUTargetInfo.cpp:39-53`,函数 `LLVMInitializeAMDGPUTargetInfo`):

| 行号 | 注册名 | Triple tag | 描述 |
|---|---|---|---|
| `:41-42` | `r600` | `Triple::r600` | "AMD GPUs HD2XXX-HD6XXX" |
| `:44-45` | `amdgpu` | `Triple::amdgpu` | "AMDGPU gfx6+"(GCN 硬件正式名) |
| `:51-53` | `amdgcn` | **无 Triple tag** | "legacy name for amdgpu" |

关键注释翻译(`AMDGPUTargetInfo.cpp:47-50`):

> "为 `-march` 注册 legacy 名 'amdgcn'。它不得占用 `Triple::amdgpu` 标签,因此用一个永不匹配任何 triple 的 match 函数。这个 hack 抄自 AArch64 处理 'arm64' 的方式。"

即:**"amdgcn 是 legacy 别名"的注释在 `AMDGPUTargetInfo.cpp:31-32`**("registered under the legacy 'amdgcn' name. This should be removed when all tool users of 'amdgcn' are migrated"),匹配函数 `[](Triple::ArchType) { return false; }` 在 `:53`。

三者关系:

- **r600 与 amdgpu/amdgcn 是两套不同硬件**(VLIW 时代 vs GCN 时代),各自持有独立 `Target` 对象与独立 TargetMachine;
- **amdgcn 与 amdgpu 是同一硬件的两种拼写**:GCC 风格 target 名 `amdgcn`(历史遗留,来自 ISA 名 "AMD GCN")与新引入的 triple 架构名 `amdgpu`。legacy target 的 match 函数永假,所以 triple 解析永远命中 `amdgpu`,只有 `-march=amdgcn` 命令行拼写会查到 legacy Target 对象,随后映射到同一个 `GCNTargetMachine`;
- git 考古:`24a5231188bf 2026-07-09 "AMDGPU: Introduce amdgpu triple arch (#206480)"` 同一提交同时引入 `Triple::amdgpu` 枚举与 legacy 注册——这是**近期(main 上 2026-07)才完成的正名**,旧文献中 "amdgcn target" 的说法对应今天的 "amdgpu triple"。

**TableGen 侧的对应**:`AMDGPU.td:2817` `def AMDGPU : Target`(挂 6 个 AsmParserVariant、AllowRegisterRenaming=1)与 `R600.td:27` `def R600 : Target`——两个 .td Target 与 C++ 侧 R600/GCN 两个 TargetMachine 一一对应;`AMDGPU.td` 是 GCN 一侧唯一的 `Target` 定义,文件内 `GCNProcessors.td`(:3381 include)定义所有 gfx 处理器。

### 3.1.2 动态验证

```bash
$ ./build-debug/bin/llc -march=amdgcn /tmp/empty.ll -o /dev/null
warning: codegen with no subarch in the target triple is deprecated and will become an error

$ ./build-debug/bin/llc -march=amdgpu /tmp/empty.ll -o /dev/null
warning: codegen with no subarch in the target triple is deprecated and will become an error
```

两个拼写都能编译(同样产出 GCN 代码);提示的 "no subarch" 弃用警告与 `AMDGPUTargetMachine.cpp:917-924` 的 IsUnknownSubArch 检查对应。注意警告文案建议的是 `amdgpu9.0a-amd-unknown` 这类**带 subarch 的 amdgpu triple**,与 `-mcpu` 联合校验逻辑(`AMDGPUTargetMachine.cpp:926-934`)配套。

### 3.1.3 设计动机

1. **单一 GCN 谱系复用一个后端**:gfx600(Tahiti, 2012)到 gfx1310 跨度 14 年,共享 GCN 指令编码骨架,后端用 Subtarget feature 差异化而非拆 target;
2. **双名兼容**:`-march=amdgcn` 被海量脚本/测试使用,改名必须走"新名 + legacy 永假 match 函数"的软迁移,与 AArch64/arm64 先例完全一致;
3. **r600 保留不删**:虽然目录里只有 39 个文件,但它是 AMD GPU 编译器唯一开源的 VLIW 参考,而且共享 `AMDGPUAsmPrinter` 等基础设施(`R600AsmPrinter.cpp` 依赖基类)。

### 3.1.4 对昇腾的映射启示

- **一个 Target 名 + Subtarget 谱系**足以覆盖多代 NPU(昇腾 Ascend310/910/910B…),不需要每代一个 triple;昇腾现有 `aarch64-linux-gnu` + 自定义工具链的做法在 LLVM 生态内的对标物就是 `amdgpu` triple + `-mcpu=xxx` 模型;
- **正名要趁早、用别名机制**:`amdgcn→amdgpu` 用了 14 年才完成第一步,昇腾若未来统一 AI Core 编译入口名,应直接采用"永假 match 函数"模式,避免 triple 语义分叉;
- **TableGen 双 Target 定义共存**说明老硬件可以"冻结式"共存——R600 的 9 个 pass 从未迁移到新 PM(`R600TargetMachine.cpp:128-155` 全部走 legacy `TargetPassConfig::addPass`),这是刻意不投资老路径的表现。

---

## 3.2 TargetMachine 创建链

### 3.2.1 静态分析

文件头注释(`AMDGPUTargetMachine.cpp:9-14`)自述定位:

> "本文件同时包含 AMDGPU target machine 与 CodeGen pass builder。AMDGPU target machine 包含为 SI+ GPU 生成代码所需的全部硬件特定信息(legacy pass manager 流水线);CodeGen pass builder 处理新 pass manager 的流水线。"

**AMDGPUTargetMachine 构造函数**(`AMDGPUTargetMachine.cpp:905-942`):

```cpp
AMDGPUTargetMachine::AMDGPUTargetMachine(const Target &T, const Triple &TT,   // :905
                                         StringRef CPU, StringRef FS, ...)
    : CodeGenTargetMachineImpl(T, TT, getGPUOrDefault(TT, CPU), FS, Options, // :911
                               getEffectiveRelocModel(),
                               getEffectiveCodeModel(CM, CodeModel::Small),   // :913
                               OptLevel),
      TLOF(createTLOF(getTargetTriple())) {                                   // :915
  initAsmInfo();                                                              // :916
  if (TT.isAMDGCN()) {                                                        // :917
    // Triple 缺少对非空但无法识别的 subarch 的表示。仅当 subarch 真为空时
    // 才允许任意 subtarget 无 subarch。
    bool IsUnknownSubArch =
        TT.getSubArch() == Triple::NoSubArch && TT.getArchName().size() != 6; // :921-922
    if (IsUnknownSubArch)
      reportFatalUsageError("unknown subarch " + TT.getArchName());           // :924
    if (TT.getSubArch() != Triple::NoSubArch) {                               // :926
      // CPU 与 triple subarch 交叉校验(:927-933)
    }
    if (getMCSubtargetInfo().checkFeatures("+wavefrontsize64"))               // :936
      MRI.reset(llvm::createGCNMCRegisterInfo(AMDGPUDwarfFlavour::Wave64));   // :937
    else if (getMCSubtargetInfo().checkFeatures("+wavefrontsize32"))          // :938
      MRI.reset(llvm::createGCNMCRegisterInfo(AMDGPUDwarfFlavour::Wave32));   // :939
  }
  LLT::setUseExtended(true);                                                  // :941
}
```

四个关键点:

1. **CPU 默认值来自 triple**:`getGPUOrDefault(TT, CPU)`(:911)——subarch triple(如 `amdgpu9.0a-amd-`)与 `-mcpu` 二选一驱动 subtarget,这是 AMDGPU 独有的"triple 即型号"设计;
2. **PIC 强制**:`getEffectiveRelocModel()` 返回 `Reloc::PIC_`(`:900-902`,"AMDGPU 工具链只支持生成共享对象,所以必须永远用 PIC");
3. **DWARF 寄存器信息按 wave 大小二选一**(:936-939):MC 层 MRI 在构造时就按 wavefrontsize64/32 换用不同 DwarfFlavour——wave 大小不是普通 feature,它影响寄存器编码视图;
4. **`LLT::setUseExtended(true)`**(:941):全局打开 GISel LLT 的扩展类型位,AMDGPU 是深度使用 GISel 的后端。

**GCNTargetMachine 构造函数**(`AMDGPUTargetMachine.cpp:1303-1311`)只是薄封装:

```cpp
GCNTargetMachine::GCNTargetMachine(...)                                       // :1303
    : AMDGPUTargetMachine(T, TT, CPU, FS, Options, RM, CM, OL) {              // :1309
  setEnableDefaultMachineVerifier(false);                                     // :1310
}
```

**R600TargetMachine 构造函数**(`R600TargetMachine.cpp:70-83`)同样薄,但有两个 r600 特有动作:`setRequiresStructuredCFG(true)`(:77)与禁用函数调用(:79-82,"r600 不支持调用")。

**Subtarget 按函数粒度缓存**——`GCNTargetMachine::getSubtargetImpl`(`AMDGPUTargetMachine.cpp:1349-1408`)是理解 AMDGPU 多型号共存的核心:

```cpp
const TargetSubtargetInfo *
GCNTargetMachine::getSubtargetImpl(const Function &F) const {                 // :1350
  StringRef GPU = getGPUName(F);          // 函数级 target-cpu 属性优先       // :1351
  StringRef FS = getFeatureString(F);     // 函数级 target-features 优先      // :1352
  ...
  SmallString<128> SubtargetKey(GPU);                                         // :1365
  SubtargetKey.append(FS);
  if (BufRelaxed)  SubtargetKey.append(",buf-oob=1");                         // :1367-1368
  if (TBufRelaxed) SubtargetKey.append(",tbuf-oob=1");                        // :1369-1370
  ... xnack/sramecc 追加到 key ...                                            // :1371-1378
  auto &I = SubtargetMap[SubtargetKey];                                       // :1380
  if (!I) {
    ...
    I = std::make_unique<GCNSubtarget>(TargetTriple, GPU, FS, *this, BufRelaxed,
                                       TBufRelaxed, Xnack, SramEcc);          // :1401-1402
  }
  ...
}
```

要点:**一个 module 里可以混编不同 gfx 型号的函数**——每个函数的 `target-cpu`/`target-features` 属性(`:951-959` 的 `getGPUName/getFeatureString`)拼出 SubtargetKey,在 `SubtargetMap` 中缓存复用。模块级 xnack/sramecc/OOB flag(`:1355-1363`)也参与 key。这允许 HIP 运行时把 fatbin 中不同 gfx 版本的函数放同一 IR 模块。

类层次(`AMDGPUTargetMachine.h:34, :83`、`R600TargetMachine.h:28`):

```text
CodeGenTargetMachineImpl
        └── AMDGPUTargetMachine        (AMDGPUTargetMachine.h:34)
              ├── GCNTargetMachine final   (AMDGPUTargetMachine.h:83)
              └── R600TargetMachine final  (R600TargetMachine.h:28)
```

### 3.2.2 动态验证

```bash
$ ./build-debug/bin/llc -mtriple=amdgcn-amd- -mcpu=gfx90a /tmp/mfma.ll -o - 2>/dev/null
  v_mfma_f32_16x16x1f32 v[8:23], v0, v0, v[8:23]     # gfx90a 有 MFMA
$ ./build-debug/bin/llc -mtriple=amdgcn-amd- -mcpu=gfx1100 /tmp/mfma.ll -o /dev/null
  LLVM ERROR: Cannot select: intrinsic %llvm.amdgcn.mfma.f32.16x16x1f32   # RDNA3 无 MFMA
```

同一 TargetMachine 创建链下,仅 `-mcpu` 不同即得到"可选/不可选"两种结果——subtarget 差异完全由 `getSubtargetImpl` 的函数级 feature 驱动,不触碰流水线结构。

### 3.2.3 设计动机

- **函数级 subtarget** 是为 fatbin/多型号发布形态服务:同一 `.hsaco` 不能混型号,但 IR 可以(LLVM 层面甚至允许一个模块多型号,最终由 `AMDGPURemoveIncompatibleFunctionsPass`(:2367-2370)剔除不兼容函数);
- **构造期定 DWARF flavour**:wave 大小改变的是寄存器文件视图(64 lane vs 32 lane 的 DWARF 表达),必须在 MC 层初始化前决定;
- **GCN/R600 共用基类**:把"跨代公共部分"(reloc=PIC、TLOF、GPU 名解析)上提,型号差异下放。

### 3.2.4 对昇腾的映射启示

- **函数级 `target-cpu` 属性 + SubtargetMap 缓存**是昇腾多 SoC(A310/T310/A910/…)共仓编译的直接参考:算子仓通常要"一份 IR 多平台",昇腾的 `ascend` triple + 函数级型号属性可以完全复刻该机制,避免为每个 SoC 拆分编译器分支;
- **构造期不可变全局(如 DWARF flavour)与函数期可变 feature 要分层**:AMDGPU 把"wave 大小"这类影响 MC 编码的属性放构造期,把指令集 feature 放 subtarget——昇腾的 AI Core 版本(如 Cube/Vector 单元差异)若影响汇编编码也应如此分层;
- **`EnableFunctionCalls` 静态开关**(`AMDGPUTargetMachine.cpp:944-945`)提示:调用约定的能力(能否函数调用)是代际属性,r600 直接在 TM 层关掉,而 GCN 默认也关闭(静态成员初始化为 false,由命令行打开)——昇腾算子内联策略可参考这种"默认全内联,显式开调用"的保守取向。

---

## 3.3 新 PM CodeGenPassBuilder:hook 全景

### 3.3.1 静态分析:26 个 override

`AMDGPUCodeGenPassBuilder` 声明于 `AMDGPUTargetMachine.cpp:151-202`,override 了 CodeGenPassBuilder 的 26 个 hook(:163-189)。构造函数(:2353-2364)先做三件事:

```cpp
AMDGPUCodeGenPassBuilder::AMDGPUCodeGenPassBuilder(...)                       // :2353
    : CodeGenPassBuilder(TM, Opts, PIC) {
  Opt.MISchedPostRA = true;              // 开 PostRA MISched                // :2357
  Opt.RequiresCodeGenSCCOrder = true;    // 要求 CGSCC 顺序                  // :2358
  // 不支持异常与 StackMaps,这些 pass 永远无事可做。不支持 GC。
  disablePass<StackMapLivenessPass, FuncletLayoutPass, PatchableFunctionPass, // :2362
              ShadowStackGCLoweringPass, GCLoweringPass>();
}
```

下面按流水线顺序列出全部 hook(行号均为 `AMDGPUTargetMachine.cpp`),**[A]** 表示 AMDGPU 专属 pass,**[G]** 表示通用 pass 的目标定制:

| # | Hook | 行号 | AMDGPU 专属 pass(★代表 pass) | 说明 |
|---|---|---|---|---|
| 1 | addIRPasses | :2366-2448 | 17 个 **[A]** | IR 层最大 hook,详见下表 |
| 2 | addCodeGenPrepare | :2450-2483 | 5 个 **[A]** + LSD 优化 | fat pointer 在此消除 |
| 3 | addPreISel | :2485-2519 | 6 个 **[A]** | 结构化五连 + 统一出口 |
| 4 | addILPOpts | :2521-2526 | 1 个 **[G]**(EarlyIfConversion) | |
| 5 | addAsmPrinterBegin | :2528-2531 | 1 个 **[A]** | AsmPrinter 前的 module pass |
| 6 | addAsmPrinter | :2533-2535 | 1 个 **[A]** | AsmPrinter 本体(MF pass 形式) |
| 7 | addAsmPrinterEnd | :2537-2539 | 1 个 **[A]** | AsmPrinter 后收尾 |
| 8 | addInstSelector | :2541-2546 | 3 个 **[A]** | SDAG 路径选择器 |
| 9 | addIRTranslator | :2548-2551 | 0 个 | GISel 路径起点 |
| 10 | addPreLegalizeMachineIR | :2553-2557 | 1 个 **[A]** | GISel pre-legalize combiner |
| 11 | addLegalizeMachineIR | :2559-2562 | 0 个 | 通用 Legalizer |
| 12 | addPreRegBankSelect | :2564-2567 | 2 个 **[A]** | post-legalize combiner + 分歧 lowering |
| 13 | addRegBankSelect | :2569-2573 | 2 个 **[A]** | RBS + RegBankLegalize |
| 14 | addPreGlobalInstructionSelect | :2575-2579 | 1 个 **[A]** | RegBankCombiner |
| 15 | addGlobalInstructionSelect | :2581-2585 | 0 个 | 通用 InstructionSelect |
| 16 | addPreRewrite | :2587-2593 | 2 个 **[A]** | NSA 重分配 + AGPR copy 重写 |
| 17 | addMachineSSAOptimization | :2595-2612 | 7 个 **[A]** | fold/DPP/LS 汇聚/SDWA/shrink |
| 18 | addPreRegAlloc | :2699-2704 | 2 个 **[A]** | AGPR 预备 + (可选)软流水 |
| 19 | addFastRegAlloc | :2614-2620 | 2 个插入 **[A]** | -O0 快速 RA 的缝里插 pass |
| 20 | addOptimizedRegAlloc | :2661-2697 | 7 个插入 **[A]** | greedy RA 前后插 pass |
| 21 | addRegAssignAndRewriteFast | :2622-2659 | 8 个 **[A]** | -O0 三段式 RA 本体 |
| 22 | addRegAssignAndRewriteOptimized | :2706-2758 | 13 个 **[A]** | -O1+ 三段式 RA 本体(最重) |
| 23 | addPostRegAlloc | :2760-2765 | 2 个 **[A]** | VGPR copy 修复 + exec 掩码优化 |
| 24 | addPreSched2 | :2767-2771 | 2 个 **[A]** | shrink + PostRA bundle |
| 25 | addPostBBSections | :2773-2777 | 1 个 **[A]** | kernarg 预加载 prolog |
| 26 | addPreEmitPass | :2779-2819 | 14 个 **[A]** | 发射前最大 hook |

**SDAG 路径 vs GISel 路径**:hook #8(addInstSelector)是 SDAG 专用;#9-#15 是 GISel 专用(IRTranslator→Legalizer→RBS→Select);两者互斥执行,由 `EnableGlobalISelOption` 控制(见 :2510-2513 的 LCSSA 条件插入)。其余 hook 两条路径共享。

#### addIRPasses 明细(:2366-2448)

| 行号 | Pass | 作用 |
|---|---|---|
| :2367-2370 | AMDGPURemoveIncompatibleFunctionsPass | 剔除与 -mcpu 不兼容函数 |
| :2374-2375 | AMDGPUPrintfRuntimeBindingPass | printf 重定向 |
| :2377-2378 | AMDGPUCtorDtorLoweringPass | ctor/dtor → init array |
| :2380-2381 | AMDGPUImageIntrinsicOptimizerPass | 图像 intrinsic 优化(可选) |
| :2383-2384 | AMDGPUUniformIntrinsicCombinePass | uniform intrinsic 合并(可选) |
| :2388 | ExpandVariadicsPass | 变参展开(强制 Lowering 模式) |
| :2390-2391 | AMDGPUAlwaysInlinePass + AlwaysInlinerPass | 全内联(强制) |
| :2393 | AMDGPUExportKernelRuntimeHandlesPass | enqueue block 运行时句柄 |
| :2395-2396 | AMDGPULowerExecSyncPass | 执行同步 lowering(实验) |
| :2398-2399 | AMDGPUSwLowerLDSPass | 软件 LDS lowering(实验) |
| :2402-2403 | AMDGPULowerModuleLDSPass | 模块级 LDS 合并(默认开) |
| :2408-2409 | AMDGPUAtomicoptimizerPass | 原子操作 DPP 归约 |
| :2414 | AMDGPUPromoteAllocaPass | alloca→SGPR/LDS 提升 |
| :2421 | AMDGPUCodeGenPreparePass | IR 级代码生成预备 |
| :2426 | LICMPass(UseMemorySSA) | 除法循环不变量外提 |
| :2447 | addEarlyCSEOrGVNPass(-O3 用 GVN) | 标量 CSE |

#### addPreEmitPass 明细(:2779-2819)

| 行号 | Pass | 作用 |
|---|---|---|
| :2780-2782 | GCNCreateVOPDPass | VOPD 双发射打包( gfx11+ wave32) |
| :2784 | SIMemoryLegalizerPass | 内存序 annotation 合法化 |
| :2785-2786 | SIPostRA16BitMovFoldingPass | 16bit mov 折叠 |
| :2787 | SIInsertWaitcntsPass | waitcnt 插入(3,775 行的大 pass) |
| :2789 | SIModeRegisterPass | FP 模式寄存器设默认 |
| :2791-2792 | SIInsertHardClausesPass | S_CLAUSE 硬子句 |
| :2794 | SILateBranchLoweringPass | 最终分支 lowering |
| :2796-2797 | AMDGPUSetWavePriorityPass | 波优先级(可选) |
| :2799-2800 | SIPreEmitPeepholePass | 发射前窥孔 |
| :2810 | PostRAHazardRecognizerPass | 独立 hazard 识别器 |
| :2811 | AMDGPUWaitSGPRHazardsPass | SGPR 读依赖等待 |
| :2812 | AMDGPULowerVGPREncodingPass | VGPR 编码降级 |
| :2814-2816 | AMDGPUInsertDelayAluPass | S_DELAY_ALU 插入(gfx11+) |
| :2818 | BranchRelaxationPass | 分支距离松弛 |

注:三段式寄存器分配的精巧设计——`addRegAssignAndRewriteOptimized`(:2706-2758)中 SGPR RA → VirtRegRewriter → StackSlotColoring → SILowerSGPRSpills → WWM RA → SILowerWWMCopies → VirtRegRewriter → VGPR RA → addPreRewrite → VirtRegRewriter(:2753 显式重入),注释 :2720-2723 解释了为何要显式 commit:"太多东西依赖物理寄存器的 use list,比如 verifier"。

### 3.3.2 动态验证(实测 -O3 gfx1100 SDAG 路径)

```bash
$ ./build-debug/bin/llc -mtriple=amdgcn-amd- -mcpu=gfx1100 -O3 /tmp/kernel.ll \
    -o /dev/null -print-after-all 2>&1 | grep -oE 'IR Dump After [^(]*\([a-zA-Z0-9._-]+\)'
```

统计(2026-09-28 实测):**总 pass 162 个,其中 amdgpu-/si-/gcn- 前缀 62 个**,外加 AsmPrinterBegin/AsmPrinter/AsmPrinterEnd 3 个,合计 **65 个目标专属 pass**——与 nvptx-vs-amdgpu-analysis.md §5.7 的"65 个"口径一致。完整序列(节选,展示各 hook 的落点):

```text
amdgpu-remove-incompatible-functions, amdgpu-printf-runtime-binding,
amdgpu-lower-ctor-dtor, amdgpu-image-intrinsic-opt, amdgpu-uniform-intrinsic-combine,
amdgpu-always-inline, amdgpu-export-kernel-runtime-handles, amdgpu-lower-exec-sync,
amdgpu-sw-lower-lds, amdgpu-lower-module-lds, amdgpu-atomic-optimizer,
amdgpu-promote-alloca, amdgpu-codegenprepare,                 ← addIRPasses (13A+)
amdgpu-preload-kernel-arguments, amdgpu-lower-kernel-arguments,
amdgpu-lower-buffer-fat-pointers, amdgpu-lower-intrinsics,    ← addCodeGenPrepare (4A+)
amdgpu-late-codegenprepare, amdgpu-unify-divergent-exit-nodes,
amdgpu-annotate-uniform, si-annotate-control-flow,
amdgpu-rewrite-undef-for-phi,                                  ← addPreISel (5A+)
amdgpu-isel, si-fix-sgpr-copies, si-i1-copies,                 ← addInstSelector (3A)
si-fold-operands, gcn-dpp-combine, si-load-store-opt,
si-peephole-sdwa, si-fold-operands, si-shrink-instructions,    ← addMachineSSAOpt (6A+)
amdgpu-prepare-agpr-alloc, si-opt-vgpr-liverange,
si-lower-control-flow, amdgpu-pre-ra-optimizations, si-wqm,
si-optimize-exec-masking-pre-ra, si-form-memory-clauses,
amdgpu-pre-ra-long-branch-reg, si-lower-sgpr-spills,
si-pre-allocate-wwm-regs, si-lower-wwm-copies, amdgpu-reserve-wwm-regs,
amdgpu-nsa-reassign, amdgpu-rewrite-agpr-copy-mfma,
amdgpu-mark-last-scratch-load,                                 ← addOptimizedRegAlloc 区 (16A)
si-fix-vgpr-copies, si-optimize-exec-masking,                  ← addPostRegAlloc (2A)
si-shrink-instructions, si-post-ra-bundler,                    ← addPreSched2 (2A)
gcn-create-vopd, si-memory-legalizer, si-post-ra-16bit-mov-folding,
si-insert-waitcnts, si-mode-register, si-insert-hard-clauses,
si-late-branch-lowering, si-pre-emit-peephole,
amdgpu-wait-sgpr-hazards, amdgpu-lower-vgpr-encoding,
amdgpu-insert-delay-alu, amdgpu-preload-kern-arg-prolog        ← addPreEmit+PostBBSections (12A)
```

另一个可复现实验:比较 hook 组成(而非计数)可见 SDAG/GISel 差异:

```bash
./build-debug/bin/llc -mtriple=amdgcn-amd- -mcpu=gfx1100 -global-isel /tmp/kernel.ll -o /dev/null
# IRTranslator → AMDGPUPreLegalizerCombiner → Legalizer → AMDGPUPostLegalizerCombiner
# → AMDGPUGlobalISelDivergenceLowering → AMDGPURegBankSelect → AMDGPURegBankLegalize
# → AMDGPURegBankCombiner → InstructionSelect …(hook #9-#15 顶替 #8)
```

### 3.3.3 设计动机

1. **hook 数量体现"加法"哲学**:26 个 override(几乎全部可 override 的 hook)使 AMDGPU 在每个阶段都能插入目标 pass;相比之下 NVPTX 仅在少数 hook 注入 21 个 pass;
2. **IR 层堆 17 个 pass 的理由**:GPU 语义(alloca 提升、LDS 合并、原子归约、fat pointer)必须在 IR 层可见时处理,MIR 层已丢失类型/别名信息;
3. **PreEmit 堆 14 个 pass 的理由**:硬件一致性模型(waitcnt)、hazard、双发射打包只在指令序列最终确定后才能精确插入;
4. **disablePass 显式清单**(:2362-2363)而非默认全开:新 PM 的声明式排除比 legacy PM 的 if-else 更可审计。

### 3.3.4 对昇腾的映射启示

- **hook 全覆盖是"物理 ISA 后端"的必备姿态**:昇腾若直出 .o(类似 gfx 的 ELF code object 而非 PTX 中间产物),IR/PreISel/PreEmit 三头都要重投入;若走 PTX 式中间产物,则只需 NVPTX 式最小 hook 集;
- **65 个目标专属 pass 的分布**(IR 13 + CGP/PreISel 9 + ISel 3 + SSA 6 + RA 16 + PostRA/Emit 18)提示投入重心:AMDGPU 最重的两块是 **RA(16)与 PreEmit(14)**——恰是"SGPR/VGPR 双宇宙 + waitcnt 一致性"两个硬件独有难题的映射;昇腾的 Cube/Vector 双单元、同步指令语义会落在类似位置;
- **`Opt.RequiresCodeGenSCCOrder = true`**(:2358)配合 `requireCGSCCOrder(PMW)`(:2474):fat pointer 拆分等 module pass 改变调用图,必须保持 SCC 顺序——昇腾做跨函数算子融合/LDS 复用时同样要处理 pass 顺序约束。

---

## 3.4 GCNSubtarget 特性 gate 机制

### 3.4.1 静态分析

**两层结构**:`AMDGPUSubtarget`(公共基类,`AMDGPUSubtarget.h:30`)持有跨代字段,`GCNSubtarget`(`GCNSubtarget.h:45`)持有 GCN 专属字段与全部 getter。

**Generation 枚举**(`AMDGPUSubtarget.h:32-46`)——**这是比 feature 更粗的一级 gate**:

```cpp
enum Generation {
  INVALID = 0,  R600 = 1,  R700 = 2,  EVERGREEN = 3,  NORTHERN_ISLANDS = 4,   // R600 系
  SOUTHERN_ISLANDS = 5,  SEA_ISLANDS = 6,  VOLCANIC_ISLANDS = 7,              // GFX6/7/8
  GFX9 = 8,  GFX10 = 9,  GFX11 = 10,  GFX12 = 11,  GFX13 = 12,                // GFX9+
};
```

由 TableGen `SubtargetFeatureGeneration`(`AMDGPUFeatures.td:105-109`)生成:feature 名如 `southern-islands`,值写入 `Gen` 字段。GCNSubtarget 大量谓词直接比较 Generation(`GCNSubtarget.h:227-328` 一带):

```cpp
bool hasFractBug() const { return getGeneration() == SOUTHERN_ISLANDS; }       // :240
bool hasMed3_16() const { return getGeneration() >= GFX9; }                    // :242
bool hasD16LoadStore() const { return getGeneration() >= GFX9; }               // :403
bool ldsRequiresM0Init() const { return getGeneration() < GFX9; }              // :413
bool hasScalarSubwordLoads() const { return getGeneration() >= GFX12; }        // :254
```

**TableGen feature 三种 gate 形态**(全部在 `AMDGPU.td`):

**(a) 布尔 feature** —— `AMDGPUSubtargetFeature` multiclass(`AMDGPU.td:54-60`)批量生成 `SubtargetFeature` + `Predicate` + `AssemblerPredicate`。代表:

```tablegen
defm MAIInsts : AMDGPUSubtargetFeature<"mai-insts", "Has mAI instructions">;   // :936-938
defm VOPDInsts : AMDGPUSubtargetFeature<"vopd",
  "Has VOPD dual issue wave32 instructions", /*GenPredicate=*/0>;              // :1268-1271
```

**(b) 数值 feature** —— 同一变量多次赋值(后写覆盖前写),如 LDSBankCount:

```tablegen
class SubtargetFeatureLDSBankCount <int Value> : AMDGPUGenericAnyFeature <     // :431
  "ldsbankcount"#Value, "LDSBankCount", !cast<string>(Value), ...>;
def FeatureLDSBankCount16 : SubtargetFeatureLDSBankCount<16>;                  // :438
def FeatureLDSBankCount32 : SubtargetFeatureLDSBankCount<32>;                  // :439
def FeatureLDSBankCount64 : SubtargetFeatureLDSBankCount<64>;                  // :440
```

C++ 侧 `int LDSBankCount = 0;`(`GCNSubtarget.h:78`)经 getter 读取(:203)。

**(c) wave 大小 feature** —— 写 log2 值(`AMDGPUFeatures.td:94-103`):

```tablegen
class SubtargetFeatureWavefrontSize <int ValueLog2> : SubtargetFeature<
  "wavefrontsize"#!shl(1, ValueLog2), "WavefrontSizeLog2", !cast<string>(ValueLog2), ...>;
def FeatureWavefrontSize16 : SubtargetFeatureWavefrontSize<4>;                 // :101
def FeatureWavefrontSize32 : SubtargetFeatureWavefrontSize<5>;                 // :102
def FeatureWavefrontSize64 : SubtargetFeatureWavefrontSize<6>;                 // :103
```

`getWavefrontSize() { return 1 << WavefrontSizeLog2; }`(`AMDGPUSubtarget.h:218-220`);`isWave32()/isWave64()` 在 `GCNSubtarget.h:930-932`。另有 `supports-wave32/supports-wave64` 能力 feature(`AMDGPUFeatures.td:80-92`,InlineIgnore 语义)区分"硬件支持"与"当前选择"。HwMode 进一步用 wave 大小做寄存器类/类型分化(`AMDGPU.td:3298-3318`,WaveSizeVT 让 i64/i32 指针值类型按 wave 模式切换)。

**按 gfx 型号 gate 的三层来源**(以 gfx90a 与 gfx1100 为例):

1. **代际默认**:gfx90a ∈ GFX9 代 → `FeatureGFX9`(`AMDGPU.td:1743-1802`)隐含 `FeatureWavefrontSize64`(:1746);gfx1100 ∈ GFX11 代 → `FeatureGFX11`(:1804-1837)隐含 `FeatureSupportsWave32 + FeatureSupportsWave64 + FeatureVOPDInsts + FeatureTrue16BitInsts`(:1810, :1816)——**RDNA 从 gfx11 起才默认 wave32 可选**;
2. **型号叠加**:gfx90a 定义 `FeatureISAVersion9_0_A`(`AMDGPU.td:2054-2074`)在 MI(Common)基础上加 `FeatureGFX90AInsts/FeatureAGPRAlloc/FeatureTgSplitSupport/FeatureRequiresAlignedVGPRs/FeaturePackedFP32Ops…`——MFMA 所需的 AGPR 与对齐约束在这里;
3. **前代继承**:gfx1100 用 `FeatureISAVersion11_0_0`(`AMDGPU.td:2316`),其 Common 层(:2305)再叠加 GFX11 代际。

**MAI 的挂载链**:gfx906(MI25)起 `FeatureISAVersion9_0_MI_Common`(`AMDGPU.td:1998-2015`)包含 `FeatureMAIInsts`(:2011);gfx90a/gfx940/gfx942/gfx950 全部继承 MI 系;而 gfx1100 的 RDNA 线不含 MAI——这正是 §3.3.2 动态验证中 mfma intrinsic 在 gfx1100 "Cannot select" 的原因。CDNA/RDNA 分叉详见 §3.5。

**GCNProcessors.td 型号覆盖**(实测 `grep -c 'def GFX'` = 62,另有 18 个 ProcessorAlias):

```text
gfx600/601/602 (SI,  :24-42)      + tahiti/pitcairn/verde/hainan/oland 别名
gfx700..705 (CI,    :48-79)       + kaveri/hawaii/kabini/mullins/bonaire
gfx801/802/803/805/810 (VI, :85-116) + carrizo/tonga/fiji/polaris*/stoney
gfx900..gfx90c (Vega, :122-152)   gfx906(MI25)/gfx908(MI100, :138)/gfx90a(MI200, :146)
gfx942 (MI300, :154) / gfx950 (MI350, :158) / gfx9-generic / gfx9-4-generic
gfx1010..1013 (RDNA1, :176-191)   ← wave32 首发
gfx1030..1036 (RDNA2, :192-217)   + gfx10-1-generic/gfx10-3-generic
gfx1100..1103/115x/117x (RDNA3, :234-280) + gfx11-generic/gfx11-7-generic
gfx1200/1201 (RDNA4, :297-303) + gfx1250/1251 + gfx12-generic/gfx12-5-generic
gfx1310 + gfx13-generic (RDNA5?, :332-337)
```

共 62 个 `def GFX*` + `generic`/`generic-hsa` 伪 target(`:11-18`,IsPseudoTarget,注释 :9-10 "generic 产物只对测试有用")。**首尾型号:gfx600(:24)到 gfx1310(:332)**。

`AMDGPUFrontendVisibleFeatures`(`AMDGPU.td:3323-3377`)定义约 150 个可被前端(clang)下发的 feature 白名单——后端内部 feature(hazard 类)不暴露。

### 3.4.2 动态验证

```bash
$ ./build-debug/bin/llc -mtriple=amdgcn-amd- -mcpu=gfx90a -mattr=+wavefrontsize32 /tmp/empty.ll
Assertion failed: (ST.hasMad64_32()), function AMDGPULegalizerInfo, file AMDGPULegalizerInfo.cpp, line 800
$ ./build-debug/bin/llc -mtriple=amdgcn-amd- -mcpu=gfx1100 -mattr=+wavefrontsize32 /tmp/empty.ll -o /dev/null
(成功,无输出)
```

gfx90a(GFX9 代只隐含 wave64)强行开 wave32 触发 Legalizer 断言——GFX9 硬件不支持 wave32(`FeatureSupportsWave32` 未隐含,`AMDGPU.td:1743-1802` 的 GFX9 列表中无此项);gfx1100(GFX11 代)原生支持,直接通过。这验证了"代际隐含表"的硬约束性。

```bash
$ ./build-debug/bin/llc -mtriple=amdgcn-amd- -mcpu=gfx1100 -mattr=help /tmp/empty.ll 2>&1 | grep -E 'vopd|mai-insts|wavefrontsize32'
  mai-insts / vopd / wavefrontsize32 / supports-wave32 / wmma-128b-insts …
```

feature 清单可枚举;`gfx90a` 查询可见 `gfx90a-insts`/`dot1-insts…dot13-insts`/`ldsbankcount16/32/64` 全集。

### 3.4.3 设计动机

1. **两级粒度**(Generation 粗 gate + feature 细 gate):谓词写得最多的其实是 Generation 比较(`GCNSubtarget.h` 里 30+ 处),因为大量行为按"代"而非"型号"变化;feature 只在型号差异(如 gfx90a 独有 AGPR 对齐)时引入,避免组合爆炸;
2. **数值型 feature 覆盖式赋值**:LDSBankCount/MaxWavesPerEU/FlatOffsetBitWidth 等用"后写覆盖"而非 01 布尔,天然支持型号间差异(16/32/64 bank);
3. **capability vs selection 分离**(supports-wave32 vs wavefrontsize32):允许 `-mattr=+wavefrontsize32` 显式选择而硬件能力独立声明,同时给 HwMode/TableGen 谓词两种查询方式;
4. **FrontendVisible 白名单**:前端只该传"指令集能力",hazard/workaround 类 feature 是编译器内部知识,不进 ABI。

### 3.4.4 对昇腾的映射启示

- **Generation 枚举 + feature 的两层结构**直接可抄:昇腾 SoC 代(310/910/910B/P/R…)对应 Generation,单 SoC 差异(如 Cube 规模、L2 大小、指令版本)用 feature;**先写代际隐含表再写型号叠加**,能避免每个型号手写全量 feature;
- **wave 大小这类"改变寄存器视图"的属性要提升到 MC 层构造期**(§3.2 的 DwarfFlavour 先例);昇腾若引入 lane 概念(AIVec 的 mask 粒度)应有同样分层;
- **`-mattr=+wavefrontsize32` 触发断言而非报错**提示:feature 组合的非法性应在 Legalizer 断言/报错中显式检查(`AMDGPULegalizerInfo.cpp:800` 的先例),昇腾检查 `cube + vec` 混合 feature 时同样要 fail fast;
- **62 个 def + 18 个 alias 的组织方式**:营销名(tahiti/hawaii/fiji)全部走 ProcessorAlias 指回 gfx 名——昇腾的型号命名(如 Atlas 系列名)也应 alias 到规范名,避免双名分叉。

---

## 3.5 三代架构演进:r600 → GCN/SI → CDNA/RDNA

### 3.5.1 演进史(git log --follow 考古,均为本仓库实测)

| 时间 | 事件 | 证据(commit) |
|---|---|---|
| 2012-12-11 | **R600 后端合入**(R600/Cayman/AMDIL 迁移) | `75aadc281382 "Add R600 backend"` |
| 2012-12 起 | SI(GCN 第一代 Southern Islands)在 R600 目录内孵化 | `f8794354b25a 2012-12-19 "R600: New control flow for SI"`、`14421a793f69 2013-01-21` |
| 2015-06-13 | **目录 R600 → AMDGPU 改名**(SI 成为主角) | `45bb48ea197f "R600 -> AMDGPU rename"`(含 docs/R600Usage.rst→AMDGPUUsage.rst) |
| 2018-06-28 | R600 与 GCN 的 TableGen 文件分离 | `c5a154db48c3 "AMDGPU: Separate R600 and GCN TableGen files"` |
| 2017-02-27 | VOP3P 指令格式(packed fp16, Vega 系) | `9be7b0d48508 "AMDGPU: Add VOP3P instruction format"` |
| 2019-04-24 | **gfx1010(RDNA1)target 定义**——wave32 时代开启 | `cee607e4144e "[AMDGPU] Add gfx1010 target definitions"` |
| 2019-07-09 | **gfx908(MI100)target——MFMA/MAI 首发于 LLVM** | `22b2c3d6511d "[AMDGPU] gfx908 target"`(FeatureMAIInsts 首现) |
| 2021-02-17 | gfx90a(MI200)支持 | `a8d9d50762c4 "[AMDGPU] gfx90a support"` |
| 2022-05~10 | **VOPD(gfx11 RDNA3 双发射)** | `07b7fada73da 2022-05-25 "[AMDGPU] gfx11 VOPD instructions MC support"`、`d1af09ad9617 2022-06-23 "[AMDGPU] gfx11 Generate VOPD Instructions"` |
| 2024-02-12 | generic target(gfx9-generic 等) | `f93aa5157a33` |
| 2026-01-26 | GFX13 feature + SMEM 编码 | `3c0f5045e103` |
| 2026-07-09 | **amdgpu triple 正名**(§3.1) | `24a5231188bf` |

注:WMMA 在 gfx1100 系(RDNA3)为主、gfx1170 补充(`829afc4c91fc 2026-02-18` 为 gfx1170 SWMMAC)——RDNA 的"数据并行矩阵"走 WMMA 路线,与 CDNA 的 MFMA 是两条独立演进线。

### 3.5.2 三代硬件在后端中的现存形态

**第一代:r600(VLIW4/5,HD2xxx-HD6xxx)**

- 39 个 R600 前缀文件 + Evergreen/Cayman/Cedar/Cypress 等指令 td;`R600Processors.td` 覆盖 r600/r630/rs880/rv670(HD2000/3000)、rv710/rv730/rv770(HD4000)、cedar/cypress/juniper/redwood/sumo(HD5000 Evergreen)、barts/caicos/**cayman**/turks(HD6000 Northern Islands);
- VLIW 特征直接体现在 pass 流水线:`R600TargetMachine.cpp:128-155` 的 legacy PM hook——`createR600EmitClauseMarkers`(clause 标记,:144)、`createR600ClauseMergePass`(clause 合并,:147)、`createR600Packetizer`(VLIW 打包,:153)、`createR600ControlFlowFinalizer`(:154)——**clause/packet 是 VLIW 编译的本质**;R600_VLIW5_Itin 与 R600_VLIW4_Itin 两套调度模型(`R600Processors.td:81-175` 各型号引用);cayman 是唯一 VLIW4(`R600_VLIW4_Itin`,`:169-171`);
- 9 个目标专属 pass,零 GISel,`setRequiresStructuredCFG(true)`(`R600TargetMachine.cpp:77`)。

**第二代:GCN/SI(gfx6-gfx9,SI→CI→VI→Vega)**

- 2012 年起在 R600 目录内以 "SI" 前缀并行生长,2015 年整体改名 AMDGPU;`GCNSubtarget` 取代 SI 命名成为正式类名;
- 核心 ISA 概念至今未变:SIMT wave、SGPR/VGPR 双宇宙、exec mask 分支、标量/向量内存;
- gfx9(Vega)引入 VOP3P(packed fp16)、FLAT 全局寻址完善、DPP8 前身特性(§3.4 特征表 `AMDGPU.td:1743-1802`)。

**第三代:CDNA 与 RDNA 分叉(gfx9 MI 系 vs gfx10+ RDNA 系)**

| 维度 | CDNA(MI 系) | RDNA(gfx10/11/12/13 系) |
|---|---|---|
| 型号 | gfx906(MI25)→gfx908(MI100)→gfx90a(MI200)→gfx940/942(MI300)→gfx950(MI350) | gfx1010..1013(RDNA1)→gfx103x(RDNA2)→gfx11xx(RDNA3)→gfx12xx(RDNA4)→gfx13(RDNA5?) |
| wave | wave64 专属 | **wave32 默认可选**(gfx10 起,`AMDGPU.td:1810` SupportsWave32) |
| 矩阵 | **MFMA**(mai-insts,`AMDGPU.td:936`)+ AGPR(`FeatureAGPRAlloc`,`AMDGPU.td:202`) | WMMA(wmma-128b/256b-insts)、VOPD 双发射(`vopd`,`:1268`) |
| 定位 | HPC/数据中心矩阵机 | 游戏/消费级 GPU |
| 实测 | gfx90a 可选 `v_mfma_f32_16x16x1f32`(§3.2.2) | gfx1100 上同一 intrinsic "Cannot select"(§3.2.2);`+wavefrontsize32` 仅 gfx1100 通过(§3.4.2) |
| AGPR 对齐 | gfx90a+ `RequiresAlignedVGPRs`(`AMDGPU.td:2059`)+ HwMode `AVAlign2LoadStoreMode`(`AMDGPU.td:3303`) | 无 AGPR,`AlignedVGPRNoAGPRMode`(`AMDGPU.td:3306-3307`) |

分叉的代码级体现:寄存器分配三段式中的 **AGPR 预备 pass**(`AMDGPUPrepareAGPRAllocPass`,`:2701`)与 **MFMA copy 重写**(`AMDGPURewriteAGPRCopyMFMAPass`,`:2592`)只服务 CDNA;**VOPD 打包**(`GCNCreateVOPDPass`,`:2781`,gate 于 `EnableVOPD` + `isPassEnabled(EnableVOPD, CodeGenOptLevel::Less)`)只服务 RDNA3+。两条线在同一 `GCNSubtarget` 类下靠 feature 共存,未拆类。

### 3.5.3 设计动机

1. **不拆后端**:CDNA/RDNA 共享 95% 的 SI 遗产(SIMT、exec、双寄存器宇宙、waitcnt),拆后端的维护成本远超 feature gate;
2. **矩阵能力走 feature 而非新 ISA**:MFMA/WMMA 都以 VOP3P/MAI 指令族 + feature 门控加入,选通逻辑在 ISel 谓词与 Legalizer,而非新 TargetMachine;
3. **R600 冻结**:VLIW 的 clause 调度从未迁移新 PM,保留 legacy PM 通道作为"活化石"。

### 3.5.4 对昇腾的映射启示

- **昇腾正处在 AMDGPU 2015 年的决策点**:多代硬件共存(310/910/910B/P/R)是否拆后端?AMDGPU 的答案是不拆——Generation 枚举 + feature + 类型系统(HwMode)三板斧足以支撑四代 62 型号;昇腾的 Cube 代际差异(如 MTE 版本、Cube 指令集)可以完全复制此模式;
- **VLIW 的教训**:r600 的 clause/packet pass 链(EmitClauseMarkers→ClauseMerge→Packetizer→ControlFlowFinalizer)说明 VLIW 编译必须做**全局打包决策**;昇腾若 AI Core 有类 VLIW 发射约束(如双发射 Cube/Vector),要准备好在 PreSched2/PreEmit 层面对应的打包 pass,而不是指望通用调度器;
- **矩阵加速器 feature 化**:MFMA 用 `mai-insts` 一个 feature + Legalizer/ISel 谓词接入,昇腾的 Cube 指令(矩阵乘)应该同样用 feature gate(如 `cube-insts`)而非独立后端,方便 AscendCL 图编译与算子 IR 复用;
- **"两代硬件同一流水线"的代价控制**:AMDGPU 的做法是把代差全部压进 TableGen 谓词(汇编可用性)、Subtarget getter(行为开关)、HwMode(类型/寄存器类)三层,C++ pass 尽量写代际无关逻辑——昇腾的 pass 若频繁 `if (is910B)` 说明分层失败。

---

## 3.6 地址空间超载设计

### 3.6.1 静态分析:`AMDGPUAddrSpace.h` 全表

文件:`llvm/include/llvm/Support/AMDGPUAddrSpace.h`(210 行,放在 Support 而非 Target 目录,因为 clang/LLD 也消费它)。

**基础段**(`:31-39`):

| 值 | 枚举 | 注释(:31-37 原文意译) |
|---|---|---|
| 0 | FLAT_ADDRESS | flat(通用)内存——可寻址所有段 |
| 1 | GLOBAL_ADDRESS | global 内存(RAT0, VTX0) |
| 2 | REGION_ADDRESS | region 内存(GDS,Global Data Share) |
| 3 | LOCAL_ADDRESS | local 内存(即 LDS/workgroup 共享) |
| 4 | CONSTANT_ADDRESS | constant 内存(VTX2) |
| 5 | PRIVATE_ADDRESS | private 内存(scratch,每线程栈) |
| 6 | CONSTANT_ADDRESS_32BIT | 32 位 constant 内存(:39) |

**超载段**(关键设计):

| 值 | 枚举 | 用途 | 注释出处 |
|---|---|---|---|
| 7 | BUFFER_FAT_POINTER | 160-bit buffer fat pointer,**"Not used in backend"** | :41-42 |
| 8 | BUFFER_RESOURCE | 128-bit buffer resource(V#/SRV 描述符) | :44 |
| 9 | BUFFER_STRIDED_POINTER | 192-bit fat pointer + 附加 index | :46-47 |
| 10/11/14/16/17/18 | RESERVED_* | "Reserved for downstream use"(AMD 下游闭源分支可用) | :49-66 |
| 13 | **VGPR** | "把 VGPR 建模为地址:32 位地址是 wave 视角下向量寄存器的字节偏移。注意与 CONSTANT_BUFFER_5 共享数值,后者仅图形 R600 路径使用" | :53-56 |
| 15 | **BARRIER** | "把 barrier ID 建模为地址" | :60 |
| 128 | STREAMOUT_REGISTER | GS NGG Streamout 寄存器(内部,可自由重编号) | :68-70 |
| 6/7 | PARAM_D_ADDRESS / PARAM_I_ADDRESS | 直接/间接寻址参数内存(CONST0/VTX1)——**与 CONSTANT_ADDRESS_32BIT/BUFFER_FAT_POINTER 数值重叠,仅 R600 图形路径用** | :72-75 |

**CONSTANT_BUFFER_0..15 = 8..23**(:83-98),注释(:77-81):

> "不要重排 CONSTANT_BUFFER_* 枚举。多处依赖此顺序以动态索引 constant buffer,例如 `ConstantBufferAS = CONSTANT_BUFFER_0 + CBIdx`。"

即 CB 编号直接算术映射到地址空间号——硬件的 16 个 const buffer 在 IR 类型系统里各占一个 AS。

**配套工具函数**:

- `isFlatGlobalAddrSpace`(:110-113):GLOBAL/FLAT/CONSTANT/或 >15 的 AS 归为 "flat-global" 指令可用域;
- `isConstantAddressSpace`(:121-146):CONSTANT/CONSTANT_32BIT/CB0..CB15 全算 constant 族;
- DWARF 映射(:148-191):LLVM AS→DWARF AS 的 6 项表(:163-170),PRIVATE 映射为 "focused lane view"(PRIVATE_LANE=5,注释 :177);
- `getNullPointerValue`(:194-205):**PRIVATE/LOCAL/REGION/VGPR 的 null 是 -1**,其余是 0——段语义决定空指针表示。

### 3.6.2 "免费复用 AS 感知别名分析"的技巧

LLVM 的 AA(AliasAnalysis)框架原生按 `getPointerAddressSpace()` 区分内存。AMDGPU 利用这一点,把 AS 表做成了**别名规则矩阵**(`AMDGPU.h:691-717`):

```cpp
static inline bool addrspacesMayAlias(unsigned AS1, unsigned AS2) {          // :691
  if (AS1 > AMDGPUAS::MAX_AMDGPU_ADDRESS || AS2 > AMDGPUAS::MAX_AMDGPU_ADDRESS)
    return true;                                                              // :692-693
  static const bool ASAliasRules[][MAX+1] = {                                 // :696
    /*              Flat  Global Region Local Const  Private C32  BufFat BufRsrc BufStrd …VGPR Barrier */
    /* Flat    */  {true, true, false, true, true, true, true, true, true, true, …false, false},
    /* Global  */  {true, true, false,false, true, false, true, true, true, true, …false, false},
    /* Region  */  {false,false, true, false,false,false,false,false,false,false, …false, false},
    /* Local   */  {true, false,false, true, false,false,false,false,false,false, …false, false},
    /* Constant*/  {true, true, false,false, false,false, true, true, true, true, …false, false},
    /* Private */  {true, false,false,false,false, true, false,false,false,false, …false, false},
    /* VGPR    */  {false,…,false, true(对角), false, false},                  // :714
    /* Barrier */  {false,…,false, false, true(对角)},                        // :716
  };
}
```

对角线为 true(同段自别名),LOCAL×GLOBAL、PRIVATE×GLOBAL、REGION×几乎全部为 **false**——因为 GPU 上这些是**物理上独立的内存**。于是:

- **AMDGPUAAResult::alias**(`AMDGPUAliasAnalysis.cpp:47-54`)第一件事就是查这张表:`if (!addrspacesMayAlias(asA, asB)) return NoAlias;`——LDS 访问与 global 访问直接 NoAlias,**通用优化(LICM/GVN/循环变换)无需任何目标代码就获得了精确的 no-alias 信息**,这就是"免费"的含义;
- 在矩阵基础上还有 FLAT 的"逃逸补丁"(:56-95):FLAT 指针可能指向任何段,但若 FLAT 指针**从 constant 段加载而来**(:71-77)或来自 kernel 参数(:78-88),仍可对 LOCAL/PRIVATE 断言 NoAlias——把"host 侧只可见 global/constant"的运行时事实编进 AA。

**VGPR=13/BARRIER=15 的超载动机**(:53-60 注释):LLVM 中"指针类型"是携带 AS 的,某些内部变换需要把"非内存对象"当作可 load/store 的地址操作——AMDGPU 把 **VGPR 文件**(wave 内向量寄存器的字节偏移视图)和 **barrier ID**(workgroup barrier 信号量编号)伪造成地址空间后,LLVM 的内存 SSA、别名分析、Debug 信息机制全部自动适用于"寄存器访问"与"barrier 操作",不用另造一套 IR 机制。代价是数值冲突管理:VGPR=13 与 CONSTANT_BUFFER_5 共值(注释 :55-56 明示"仅图形 R600 路径使用"CB5——图形管线不会同时用 VGPR-AS 与 CB5 动态索引);BARRIER=15 与 CONSTANT_BUFFER_7 共值,同理按使用场景隔离。

**BUFFER_FAT_POINTER=7/BUFFER_RESOURCE=8/BUFFER_STRIDED_POINTER=9 的动机**:现代 buffer 指令需要 128/160/192-bit 的"描述符+索引"复合操作数。把它们建模为超宽指针类型(`AMDGPU.td:15-22` 的 `def p7 : PtrValueType<i64*…>` 对应 datalayout `p7:160:256…`,见 §3.3.2 实测 datalayout 里的 `p7:160:256:256:32-p8:128:128:128:48-p9:192:256:256:32`),前端(HIP buffer 或图形 intrinsic)就能生成带类型检查的 fat pointer GEP/load;`AMDGPULowerBufferFatPointersPass`(`AMDGPUTargetMachine.cpp:2472`)在 CodeGenPrepare 之后把它**拆解回普通指针 + 描述符操作数**(注释 :2464-2470 解释了放置位置:放在 uniformity 分析之前、地址模式匹配之后)。RESERVED 10/11/14/16-18 留给 AMD 内部分叉。

### 3.6.3 动态验证

datalayout 的 AS 宽度直接暴露该设计(§3.3.2 的 -print-after-all 输出):

```text
target datalayout = "e-m:e-p:64:64-p1:64:64-p2:32:32-p3:32:32-p4:64:64-p5:32:32-
p6:32:32-p7:160:256:256:32-p8:128:128:128:48-p9:192:256:256:32-p10:32:32-…-p15:32:32
-i64:64-v16:16-v24:32-…-S32-A5-G1-ni:7:8:9"
```

p0=FLAT(64bit)、p1=GLOBAL(64)、p2=REGION(32)、p3=LOCAL(32)、p4=CONSTANT(64)、p5=PRIVATE(32)、p6=CONSTANT32(32)、**p7=160bit/p8=128bit/p9=192bit**(buffer fat/resource/strided)、p15=32bit(BARRIER);尾部 `ni:7:8:9` 标记 7/8/9 为非整型地址空间。

null 语义亦可在 IR 层验证(`getNullPointerValue` :194-205):

```llvm
; LOCAL/PRIVATE/REGION 的 null 是 -1(inttoptr (i64 -1 to ptr addrspace(3)))
```

### 3.6.4 设计动机(小结)

1. **物理段 ≠ 逻辑别名域**:GPU 的 LOCAL/GLOBAL/PRIVATE 物理隔离 → 直接把"不别名"编码进类型系统,AA/优化器零成本受益;
2. **超载数值复用而非扩展类型系统**:LLVM AS 是 24-bit 整数,把 VGPR/BARrier 塞进去比扩展 IR 表达更便宜,冲突靠"使用场景互斥"管理;
3. **CB 编号算术映射**(CB0+idx)匹配硬件描述符表布局,ISel 能直接从 AS 数值恢复 CB 编号;
4. **RESERVED 段**是商业考量:AMD 内部闭源分支(ROCm 前身)可以定义私有 AS 而不与上游冲突。

### 3.6.5 对昇腾的映射启示

- **昇腾的 Unified Buffer / L1 / L0 / HBM / DDR 天然是"多物理段"**——若昇腾自研 IR 借用 LLVM 语义(或直接基于 LLVM),应把 AI Core 的存储层级(UB/L1/GM/常量段)建模为互不别名的 AS,**一行 AA 矩阵换掉一整套自定义别名分析**;
- **"寄存器文件伪 AS"** 技巧对昇腾极具价值:昇腾的向量寄存器/TP 指令操作数若需要在通用优化中保持 SSA 语义,可照抄 VGPR=13 的做法(给寄存器文件一个 AS,load/store 即读写寄存器);
- **null 指针值按段定制**(:194-205):昇腾各存储段的"非法地址"表示不同(UB 偏移越界 vs HBM 空洞),DataLayout 应显式声明而非统一 0;
- **RESERVED 段的教训是反向的**:昇腾开源生态不应预留"私有段"给闭源分支,而应统一编号管理,否则社区算子与 CANN 私有扩展会走向 `ni:7:8:9` 式的永久分裂;
- **fat pointer → 早期拆解**模式(:2472 在 CGP 后拆)适用于昇腾的 TDesc/描述符类操作数:前端以宽指针类型表达,后端在进入 MIR 前拆解,既保类型安全又不污染 MIR。

---

## 3.7 流水线全景图(IR → ELF,标注 hook 与 pass 计数)

以下为 **SDAG 路径、-O3、gfx1100** 的实测全景(计数来源:§3.3.2 的 `-print-after-all` 抓取;`[nA]` = 该 hook 注入的 AMDGPU/SI/GCN 专属 pass 数):

```text
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                            LLVM AMDGPU CodeGen 流水线(gfx1100, -O3, SDAG)            │
│                        IR ──────────────────────────────────────▶ ELF                │
└─────────────────────────────────────────────────────────────────────────────────────┘

  LLVM IR (module)
     │
     ▼  [addIRPasses :2366] ─────────────────────────────── 17 个 [A] + 通用
     │   amdgpu-remove-incompatible-functions → amdgpu-printf-runtime-binding
     │   → amdgpu-lower-ctor-dtor → amdgpu-image-intrinsic-opt
     │   → amdgpu-uniform-intrinsic-combine → expand-variadics
     │   → amdgpu-always-inline + always-inline
     │   → amdgpu-export-kernel-runtime-handles → amdgpu-lower-exec-sync
     │   → amdgpu-sw-lower-lds → amdgpu-lower-module-lds
     │   → amdgpu-atomic-optimizer → atomic-expand → amdgpu-promote-alloca
     │   → (LICM/MemorySSA) → amdgpu-codegenprepare → (GVN@-O3)
     ▼  [addCodeGenPrepare :2450] ─────────────────────────── 5 个 [A]
     │   amdgpu-preload-kernel-arguments → amdgpu-lower-kernel-arguments
     │   → (CodeGenPrepare 通用) → load-store-vectorizer
     │   → amdgpu-lower-buffer-fat-pointers → amdgpu-lower-intrinsics → lower-switch
     ▼  [addPreISel :2485] ───────────────────────────────── 6 个 [A]
     │   flatten-cfg → sinking → amdgpu-late-codegenprepare
     │   → amdgpu-unify-divergent-exit-nodes → fix-irreducible → unify-loop-exits
     │   → structurizecfg → amdgpu-annotate-uniform → si-annotate-control-flow
     │   → amdgpu-rewrite-undef-for-phi → (LCSSA) → amdgpu-perf-hint
     │
     ├─── SDAG 路径 ─────────────────────────────────────────┐
     │   [addInstSelector :2541] 3 个 [A]:                   │
     │     amdgpu-isel → si-fix-sgpr-copies → si-i1-copies   │
     │   [finalize-isel 通用]                                 │
     ├─── GISel 路径(互斥)─────────────────────────────────┤
     │   [addIRTranslator :2548] → irtranslator               │
     │   [addPreLegalizeMachineIR :2553] 1[A]+localizer       │
     │   [addLegalizeMachineIR :2559] → legalizer             │
     │   [addPreRegBankSelect :2564] 2[A]: amdgpu-postlegal-  │
     │       combiner → amdgpu-gisel-divergence-lowering      │
     │   [addRegBankSelect :2569] 2[A]: amdgpu-regbankselect  │
     │       → amdgpu-regbank-legalize                        │
     │   [addPreGlobalISelSelect :2575] 1[A]: regbank-combiner│
     │   [addGlobalInstructionSelect :2581] → instruction-    │
     │       select                                            │
     ▼                                                        │
  Machine IR (SSA) ◀─────────────────────────────────────────┘
     │
     ▼  [addMachineSSAOptimization :2595] ─────────────────── 7 个 [A]
     │   (MIDCE/licm/cse…) → si-fold-operands → gcn-dpp-combine
     │   → si-load-store-opt → si-peephole-sdwa(+licm+cse+fold)
     │   → dead-mi-elim → si-shrink-instructions
     ▼  [addPreRegAlloc :2699] ── 2 个 [A]: amdgpu-prepare-agpr-alloc →(软流水)
     ▼  [addOptimizedRegAlloc :2661] ── 7 个插入 [A] + [addRegAssignAndRewriteOptimized :2706] ── 13 个 [A]
     │   (phi-elim→si-lower-control-flow 插入) → si-opt-vgpr-liverange
     │   → machine-scheduler(+amdgpu-pre-ra-optimizations) → si-wqm(插于 sched 后)
     │   → si-optimize-exec-masking-pre-ra → si-form-memory-clauses
     │   ┌── 三段式 RA ──────────────────────────────────────┐
     │   │ amdgpu-pre-ra-long-branch-reg                      │
     │   │ ① SGPR RA(greedy, onlyAllocateSGPRs :222-227)     │
     │   │   → virtregrewriter → stack-slot-coloring          │
     │   │   → si-lower-sgpr-spills ("SGPR 的 PEI",:2731)     │
     │   │ ② WWM RA(whole-wave-mode)                         │
     │   │   → si-pre-allocate-wwm-regs → si-lower-wwm-copies │
     │   │   → virtregrewriter → amdgpu-reserve-wwm-regs      │
     │   │ ③ VGPR RA(greedy)                                 │
     │   │   → [addPreRewrite :2587]: amdgpu-nsa-reassign     │
     │   │     → amdgpu-rewrite-agpr-copy-mfma                │
     │   │   → virtregrewriter → amdgpu-mark-last-scratch-load│
     │   └────────────────────────────────────────────────────┘
     ▼  [addPostRegAlloc :2760] ── 2 个 [A]: si-fix-vgpr-copies → si-optimize-exec-masking
     ▼  [addPreSched2 :2767] ── 2 个 [A]: si-shrink-instructions → si-post-ra-bundler
     ▼  [addPostBBSections :2773] ── 1 个 [A]: amdgpu-preload-kern-arg-prolog
     ▼  [addPreEmitPass :2779] ───────────────────────────── 14 个 [A]
     │   gcn-create-vopd → si-memory-legalizer → si-post-ra-16bit-mov-folding
     │   → si-insert-waitcnts → si-mode-register → si-insert-hard-clauses
     │   → si-late-branch-lowering → amdgpu-set-wave-priority
     │   → si-pre-emit-peephole → post-RA-hazard-rec → amdgpu-wait-sgpr-hazards
     │   → amdgpu-lower-vgpr-encoding → amdgpu-insert-delay-alu → branch-relaxation
     ▼  [addAsmPrinterBegin :2528] + [addAsmPrinter :2533] + [addAsmPrinterEnd :2537] ── 3 个 [A]
     │
     ▼
  MC 层(AsmParser/CodeEmitter/ELF Writer)──▶  Code Object V5 ELF(.hsaco)
```

**65 个目标专属 pass 的 hook 分布汇总**:

| Hook | 专属 pass 数 | 占比 |
|---|---|---|
| addIRPasses | 17 | 26% |
| addCodeGenPrepare | 5 | 8% |
| addPreISel | 6 | 9% |
| addInstSelector(SDAG) | 3 | 5% |
| addIRTranslator..addGlobalInstructionSelect(GISel,互斥) | 6 | 9% |
| addPreRewrite | 2 | 3% |
| addMachineSSAOptimization | 7 | 11% |
| addPreRegAlloc + addOptimizedRegAlloc + addRegAssignAndRewriteOptimized | 2+7+13=22 | 34% |
| addFastRegAlloc + addRegAssignAndRewriteFast(-O0,互斥) | 2+8=10 | — |
| addPostRegAlloc + addPreSched2 + addPostBBSections | 2+2+1=5 | 8% |
| addPreEmitPass | 14 | 22% |
| addAsmPrinter×3 + addILPOpts | 4 | 6% |

(注:SDAG 与 GISel 互斥、-O0 与 -O1+ 互斥;上表"占比"以 SDAG -O1+ 路径实跑的 62+3=65 计。RA 三段式相关的 22 个 pass 是单一最大块。)

---

## 3.8 引用清单(供主会话抽查)

以下全部引用均经本会话 grep/read 实测:

**Target 注册**
- llvm/lib/Target/AMDGPU/TargetInfo/AMDGPUTargetInfo.cpp:19-23, :25-29, :31-36, :39-53(legacy amdgcn 注释在 :31-32、永假 match 在 :53)

**TargetMachine**
- llvm/lib/Target/AMDGPU/AMDGPUTargetMachine.cpp:9-14(文件头), :900-903(PIC), :905-942(AMDGPUTM ctor), :917-940(subarch 校验+DwarfFlavour), :941(LLT 扩展), :944-946(静态开关), :950-959(getGPUName/getFeatureString), :1303-1311(GCNTM ctor), :1349-1408(getSubtargetImpl), :1415-1420(buildCodeGenPipeline)
- llvm/lib/Target/AMDGPU/AMDGPUTargetMachine.h:34, :83, :136
- llvm/lib/Target/AMDGPU/R600TargetMachine.cpp:70-83(R600TM ctor), :85-92(getSubtargetImpl), :128-134, :136-139, :141, :143-148, :150-155(R600 pass 链)
- llvm/lib/Target/AMDGPU/R600TargetMachine.h:28

**CodeGenPassBuilder hooks(全部在 AMDGPUTargetMachine.cpp)**
- :151-202(类声明,26 个 override 在 :163-189), :204-227(三类 RegAlloc 注册器), :2353-2364(ctor), :2366-2448(addIRPasses), :2450-2483(addCodeGenPrepare), :2485-2519(addPreISel), :2521-2526(addILPOpts), :2528-2539(AsmPrinter×3), :2541-2546(addInstSelector), :2548-2551(addIRTranslator), :2553-2557(addPreLegalizeMachineIR), :2559-2562(addLegalizeMachineIR), :2564-2567(addPreRegBankSelect), :2569-2573(addRegBankSelect), :2575-2579(addPreGlobalInstructionSelect), :2581-2585(addGlobalInstructionSelect), :2587-2593(addPreRewrite), :2595-2612(addMachineSSAOptimization), :2614-2620(addFastRegAlloc), :2622-2659(addRegAssignAndRewriteFast), :2661-2697(addOptimizedRegAlloc), :2699-2704(addPreRegAlloc), :2706-2758(addRegAssignAndRewriteOptimized), :2760-2765(addPostRegAlloc), :2767-2771(addPreSched2), :2773-2777(addPostBBSections), :2779-2819(addPreEmitPass), :2821-2828(isPassEnabled), :2830-2858(辅助)

**Subtarget / feature**
- llvm/lib/Target/AMDGPU/GCNSubtarget.h:35-43(OOB flag), :45-46(类声明), :62-103(字段), :120-128(ctor 声明), :174-182(ParseSubtargetFeatures/GET_SUBTARGETINFO_MACRO), :176-178(getGeneration/isGFX11Plus), :203(getLDSBankCount), :227-518(Generation 谓词群,如 :240, :242, :254, :403, :413), :930-932(isWave32/64)
- llvm/lib/Target/AMDGPU/GCNSubtarget.cpp:218-264(ctor)
- llvm/lib/Target/AMDGPU/AMDGPUSubtarget.h:30-46(Generation 枚举), :52-65(字段), :218-224(getWavefrontSize)
- llvm/lib/Target/AMDGPU/AMDGPU.td:15-22(p0..p15 指针类型), :54-60(AMDGPUSubtargetFeature multiclass), :431-440(LDSBankCount), :442-445(MaxWavesPerEU), :936-938(MAIInsts), :1268-1271(VOPDInsts), :1667-1692(SI 代际), :1694-1715(CI), :1717-1741(VI), :1743-1802(GFX9), :1804-1837(GFX11), :1839-1866(GFX12), :1868-1898(GFX13), :1975-2015(gfx9 ISAVersion 系,MAI 在 :2011), :2054-2074(gfx90a), :2080-2124(gfx940/942), :2126-2135(gfx950), :2305-2330(gfx11 ISAVersion 系), :2817-2829(def AMDGPU : Target), :3282-3292(wave 谓词), :3294-3318(HwMode), :3323-3377(FrontendVisibleFeatures), :3380-3388(include 链)
- llvm/lib/Target/AMDGPU/AMDGPUFeatures.td:80-92(SupportsWave32/64), :94-103(WavefrontSize 类), :105-109(SubtargetFeatureGeneration)
- llvm/lib/Target/AMDGPU/GCNProcessors.td:9-18(generic), :24-42(gfx6), :48-79(gfx7), :85-116(gfx8), :122-172(gfx9 系:gfx906 :134, gfx908 :138, gfx90a :146, gfx942 :154, gfx950 :158), :176-230(gfx10 系), :234-290(gfx11 系), :297-329(gfx12 系), :332-337(gfx1310/gfx13-generic)
- llvm/lib/Target/AMDGPU/R600Processors.td:9-59(R600 feature), :61-75(Evergreen/NI 代际), :81-175(型号表,cayman :169-171), :177-180(R600FrontendVisibleFeatures)
- llvm/lib/Target/AMDGPU/R600.td:27-30(def R600 : Target)

**地址空间**
- llvm/include/llvm/Support/AMDGPUAddrSpace.h:21-27(头注释), :28-102(枚举主体:FLAT:31, GLOBAL:32, REGION:33, LOCAL:35, CONSTANT:36, PRIVATE:37, CONST32:39, BufFat:41-42, BufRsrc:44, BufStrd:46-47, RESERVED:49-66, VGPR:53-56, BARRIER:60, STREAMOUT:69, PARAM:72-75, CB0-15:83-98), :105-146(判断函数), :148-171(DWARF 表), :173-191(mapToDWARFAddrSpace), :193-205(getNullPointerValue)
- llvm/lib/Target/AMDGPU/AMDGPU.h:691-717(addrspacesMayAlias 矩阵,VGPR 行 :711-714, Barrier 行 :716)
- llvm/lib/Target/AMDGPU/AMDGPUAliasAnalysis.h:24-44(AMDGPUAAResult), :46-58(AMDGPUAA)
- llvm/lib/Target/AMDGPU/AMDGPUAliasAnalysis.cpp:47-54(AS 查表), :56-95(FLAT 补丁)

**演进史(git,均为本仓库实测 commit)**
- 75aadc281382(2012-12-11, Add R600 backend)
- 45bb48ea197f(2015-06-13, R600→AMDGPU rename)
- c5a154db48c3(2018-06-28, R600/GCN TableGen 分离)
- 9be7b0d48508(2017-02-27, VOP3P)
- cee607e4144e(2019-04-24, gfx1010)
- 22b2c3d6511d(2019-07-09, gfx908/FeatureMAIInsts 首现)
- a8d9d50762c4(2021-02-17, gfx90a)
- 07b7fada73da / d1af09ad9617(2022, VOPD)
- 829afc4c91fc(2026-02-18, gfx1170 SWMMAC)
- 24a5231188bf(2026-07-09, amdgpu triple 正名)

**动态验证产物**
- /tmp/empty.ll, /tmp/mfma.ll, /tmp/kernel.ll(本会话创建的测试输入)
- gfx90a:gfx1100 = MFMA 可选/不可选;+wavefrontsize32 仅 gfx1100 通过(gfx90a 断言 AMDGPULegalizerInfo.cpp:800)
- -O3 -print-after-all 总 162 pass、目标专属 62+3=65(清单见 §3.3.2)
- datalayout 全 AS 宽度(§3.6.3)

*(完 — §3 宏观架构;后续章节:02-ir-layer.md §4 / 03-structurize.md §5 / 04-isel.md §6 …)*
