# 双 Pass Manager 并存格局(§1)

> 基准:llvm-project main @ `3eda2aebadd4`(2026-09-28)。
> 所有引用均为本仓库 `文件:行号`,经 read/grep 实测核对;动态验证一律使用 `build-debug`(Debug+Assertions,注册 target:AArch64 / AMDGPU / NVPTX)。
> 实测产物存 `PassManager-notes/scratch/`,前缀 `dualpm-`。

---

## 1.0 总览:两套 PM 在 2026 年的真实分工

LLVM 目前**同时**维护两套 Pass Manager(下称 PM):

- **legacy PM**:2001 年起家的"老 PM",类层次在 `llvm/include/llvm/IR/LegacyPassManagers.h`,实现在 `llvm/lib/IR/LegacyPassManager.cpp`(1808 行)。所有 `Pass` / `ModulePass` / `FunctionPass` / `MachineFunctionPass` 都是它的公民。
- **new PM(NPM)**:chandlerc 2013 年立项重写,核心模板在 `llvm/include/llvm/IR/PassManager.h`,CodeGen 侧由 `llvm/include/llvm/Passes/CodeGenPassBuilder.h` 与 `llvm/include/llvm/CodeGen/MachinePassManager.h` 组成。legacy 命名空间的引入提交是 `7caea41545fc`(2013-11-09,"Move the old pass manager infrastructure into a legacy namespace")。

main 分支上二者的分工**不是**"IR 用新 PM、CodeGen 用 legacy"这么干净:

| 编译阶段 | 默认 PM | 依据 |
|---|---|---|
| `opt` 的 IR 优化管线(`-O0..-O3`) | **new PM** | `llvm/tools/opt/optdriver.cpp:463-464` `UseNPM = !shouldForceLegacyPM() \|\| PassPipeline.getNumOccurrences() > 0`;`-O#` sugar 展开为 `default<O#>` 字符串(`optdriver.cpp:774-785`)后交 `runPassPipeline`(:801)。legacy 分支直接拒绝 `-O#`(`optdriver.cpp:812-814` 报错 "Cannot use -O# with legacy PM.") |
| `clang -c` 的 CodeGen 管线 | **target 决定,默认 legacy** | `llvm/lib/Passes/RunCodeGen.cpp:103-110` 按 `TM.shouldDefaultToNewPM()` 分叉;基类默认 `false`(`llvm/include/llvm/Target/TargetMachine.h:512`) |
| `llc` 的 CodeGen 管线 | **legacy** | `llvm/tools/llc/lib/llcdriver.cpp:219-220` `cl::opt<bool> EnableNewPassManager("enable-new-pm", ..., cl::init(false))`;分叉条件 `llcdriver.cpp:743-747` |

只有 **Lanai 与 MSP430** 两个 target override `shouldDefaultToNewPM()` 返回 `true`(分别在 `llvm/lib/Target/Lanai/LanaiTargetMachine.h:63` 与 `llvm/lib/Target/MSP430/MSP430TargetMachine.h:59`)。X86 / AArch64 / AMDGPU / NVPTX / RISCV / WebAssembly / BPF / SPIRV 的 clang/llc CodeGen 默认仍走 legacy。

一句话:**opt 已经完成切换;clang/llc 的 CodeGen 处于"新 PM 接口已在 10 个 target 实现,但默认路径仍由 legacy 提供"的过渡态**。

```text
   clang -c a.c  ──▶  clang::EmitAssemblyHelper::RunCodegenPipeline
                      (clang/lib/CodeGen/BackendUtil.cpp:1194-1225)
                                   │ 调用
                                   ▼
                  llvm::runCodeGenPipeline (llvm/lib/Passes/RunCodeGen.cpp:97)
                                   │
       ┌───────────────────────────┴───────────────────────────┐
       │ ForceNewPM==TRUE                                      │
       │  \|\| (TM.shouldDefaultToNewPM()                      │  (RunCodeGen.cpp:103-105)
       │       && ForceNewPM!=FALSE)                           │
       ▼                                                       ▼
runCodeGenPipelineNewPM                           runCodeGenPipelineLegacy
 (RunCodeGen.cpp:60)                               (RunCodeGen.cpp:35)
       │                                                       │
       ▼                                                       ▼
TM.buildCodeGenPipeline (虚函数)                TM.addPassesToEmitFile
 (TargetMachine.h:501-508)                       (CodeGenTargetMachineImpl.cpp:229)
       │                                                       │
       ▼                                                       ▼
target 专属 CodeGenPassBuilder        addPassesToGenerateCode → TargetPassConfig
 (如 AMDGPUCodeGenPassBuilder)         (CodeGenTargetMachineImpl.cpp:116-140)
```

---

## 1.1 clang `-c` 出 `.o` 的完整调用链

### 1.1.1 `EmitAssemblyHelper::RunCodegenPipeline`

`clang::EmitAssemblyHelper` 是 clang CodeGen 的内部辅助类,声明在 `clang/lib/CodeGen/BackendUtil.cpp:151` 起(匿名 namespace 内,构造函数 :219-225),其 `RunCodegenPipeline` 方法在 `BackendUtil.cpp:1194-1225`:

```cpp
void EmitAssemblyHelper::RunCodegenPipeline(
    BackendAction Action, std::unique_ptr<raw_pwrite_stream> &OS,
    std::unique_ptr<llvm::ToolOutputFile> &DwoOS) {
  if (!actionRequiresCodeGen(Action))                       // :1197
    return;
  CodeGenFileType CGFT = getCodeGenFileType(Action);        // :1202

  // 插件可能接管整个 CodeGen
  for (const std::unique_ptr<llvm::PassPlugin> &Plugin : CI.getPassPlugins()) {
    if (Plugin->invokePreCodeGenCallback(*TheModule, *TM, CGFT, *OS)) // :1207
      return;
  }
  ...
  TimeCodegenPasses([&]() {                                  // :1217
    Error CodeGenError = runCodeGenPipeline(                 // :1218
        *TM, *TheModule, *OS, DwoOS, CGFT, PrintPipelinePasses.has_value(),
        !CodeGenOpts.VerifyModule, /*DisableSimplifyLibCalls=*/false,
        CI.getVirtualFileSystemPtr());
    if (CodeGenError)
      Diags.Report(diag::err_fe_unable_to_interface_with_target); // :1223
  });
}
```

构造函数的代码片段(`BackendUtil.cpp:219-225`):

```cpp
EmitAssemblyHelper(CompilerInstance &CI, CodeGenOptions &CGOpts,
                   llvm::Module *M,
                   IntrusiveRefCntPtr<llvm::vfs::FileSystem> VFS)
    : CI(CI), Diags(CI.getDiagnostics()), CodeGenOpts(CGOpts),
      TargetOpts(CI.getTargetOpts()), LangOpts(CI.getLangOpts()),
      TheModule(M), VFS(std::move(VFS)),
      TargetTriple(TheModule->getTargetTriple()) {}
```

`runCodeGenPipeline` **不在 clang**,也不在 `clang/lib/CodeGen/RunCodeGen.cpp`(此文件不存在,系常见误解),而是定义在 **`llvm/lib/Passes/RunCodeGen.cpp`**,声明在 `llvm/include/llvm/Passes/RunCodeGen.h:19`。clang 只是调用 LLVM 的统一入口。`EmitAssemblyHelper::emitAssembly`(`BackendUtil.cpp:1241`)才是顶层驱动,`RunCodegenPipeline` 是被它在 `EmitBackendOutput` 流程末尾调用的子步骤。

### 1.1.2 双 PM 分叉点

`llvm/lib/Passes/RunCodeGen.cpp:97-111` 是**全仓库唯一一处**决定 clang CodeGen 用哪套 PM 的代码:

```cpp
Error llvm::runCodeGenPipeline(TargetMachine &TM, Module &M, ...) {
  if (ForceNewPM == cl::boolOrDefault::BOU_TRUE ||           // :103
      (TM.shouldDefaultToNewPM() &&                          // :104
       ForceNewPM != cl::boolOrDefault::BOU_FALSE)) {        // :105
    return runCodeGenPipelineNewPM(TM, M, OS, DwoOS, CGFT,   // :106
                                   DisableVerify, VFS);
  }
  return runCodeGenPipelineLegacy(TM, M, OS, DwoOS, CGFT,    // :109
                                  PrintPipelinePasses,
                                  DisableVerify, DisableSimplifyLibCalls);
}
```

`ForceNewPM` 是 `-force-new-pm-codegen` 命令行选项,定义在 `RunCodeGen.cpp:28-32`,类型 `cl::opt<cl::boolOrDefault>`,三态 `BOU_TRUE / BOU_FALSE / BOU_UNSET`,默认 `BOU_UNSET`。所以**默认情况下真正决定路径的是 `TM.shouldDefaultToNewPM()`**。

`TargetMachine::shouldDefaultToNewPM()` 基类实现在 `llvm/include/llvm/Target/TargetMachine.h:511-512`:

```cpp
/// Returns true if frontends should default to using the NewPM for this
/// specific target.
virtual bool shouldDefaultToNewPM() const { return false; }
```

仓库内 override 为 `true` 的 target 仅两家:

| target | 文件:行号 |
|---|---|
| Lanai | `llvm/lib/Target/Lanai/LanaiTargetMachine.h:63` |
| MSP430 | `llvm/lib/Target/MSP430/MSP430TargetMachine.h:59` |

### 1.1.3 legacy 分支(`runCodeGenPipelineLegacy`)

`RunCodeGen.cpp:35-58`:

```cpp
static Error runCodeGenPipelineLegacy(TargetMachine &TM, Module &M, ...) {
  legacy::PassManager CodeGenPasses;                                // :39
  CodeGenPasses.add(
      createTargetTransformInfoWrapperPass(TM.getTargetIRAnalysis())); // :40-41
  TargetLibraryInfoImpl TLII(TM.getTargetTriple(), TM.Options.VecLib); // :43
  if (DisableSimplifyLibCalls)
    TLII.disableAllFunctions();                                     // :45
  CodeGenPasses.add(new TargetLibraryInfoWrapperPass(TLII));        // :46

  const TargetOptions &Options = TM.Options;
  CodeGenPasses.add(
      new RuntimeLibraryInfoWrapper(Options.MCOptions.ABIName, Options.VecLib)); // :49-50

  if (TM.addPassesToEmitFile(CodeGenPasses, OS, DwoOS ? &DwoOS->os() : nullptr,
                             CGFT, DisableVerify))                  // :52-53
    return createStringError("Failed to construct CodeGen pipeline");
  CodeGenPasses.run(M);                                              // :55
  return Error::success();
}
```

三个要点:

1. **`legacy::PassManager` 是裸栈对象**——`CodeGenPasses` 在函数栈帧上构造,`run(M)` 后随函数返回析构。legacy PM 的"PM 即对象"风格在此可见;
2. **TTI/TLI 以 wrapper pass 形式注入**(而不是像新 PM 那样注册进 analysis manager):`createTargetTransformInfoWrapperPass`、`TargetLibraryInfoWrapperPass`、`RuntimeLibraryInfoWrapper` 都是 legacy `ImmutablePass`;
3. **真正的管线构造被委托给 `TM.addPassesToEmitFile`**——它进入 `CodeGenTargetMachineImpl::addPassesToEmitFile`(`llvm/lib/CodeGen/CodeGenTargetMachineImpl.cpp:229-252`),进而调用 `addPassesToGenerateCode`(:116,§1.4 详解)。

### 1.1.4 new PM 分支(`runCodeGenPipelineNewPM`)

`RunCodeGen.cpp:60-95`:

```cpp
static Error runCodeGenPipelineNewPM(TargetMachine &TM, Module &M, ...) {
  ModulePassManager MPM;                       // :65
  MachineFunctionAnalysisManager MFAM;         // :66  <- 第 5 个 AM
  LoopAnalysisManager LAM;                     // :67
  FunctionAnalysisManager FAM;                 // :68
  CGSCCAnalysisManager CGAM;                   // :69
  ModuleAnalysisManager MAM;                   // :70
  CGPassBuilderOption Opt = getCGPassBuilderOption();          // :71
  Opt.DisableVerify = DisableVerify;
  MachineModuleInfo MMI(&TM);                                    // :73
  PassInstrumentationCallbacks PIC;                              // :74
  PipelineTuningOptions PTOptions;                               // :75
  PassBuilder PB(TMPointer, PTOptions, std::nullopt, &PIC, VFS); // :77
  PB.registerModuleAnalyses(MAM);                                // :78
  PB.registerCGSCCAnalyses(CGAM);                                // :79
  PB.registerFunctionAnalyses(FAM);                              // :80
  PB.registerLoopAnalyses(LAM);                                  // :81
  PB.registerMachineFunctionAnalyses(MFAM);                      // :82
  PB.crossRegisterProxies(LAM, FAM, CGAM, MAM, &MFAM);           // :83

  MAM.registerPass([&] { return MachineModuleAnalysis(MMI); });  // :85

  Error BuildPipelineError =
      TM.buildCodeGenPipeline(MPM, MAM, OS, DwoOS ? &DwoOS->os() : nullptr,
                              CGFT, Opt, MMI.getContext(), &PIC); // :87-89
  if (BuildPipelineError)
    return BuildPipelineError;
  MPM.run(M, MAM);                                                // :93
  return Error::success();
}
```

与 legacy 分支的三个关键差异:

1. **5 个 AnalysisManager 并列**(:66-70):新增的第 5 个 `MachineFunctionAnalysisManager`(`llvm/include/llvm/CodeGen/MachineFunctionAnalysisManager.h:24`,实际是 `AnalysisManager<MachineFunction>` 的 typedef)是 MachineFunction 层的 AM,与 IR 的 FAM 平行;
2. **`crossRegisterProxies` 带 5 参**(:83):最后一个参数是可选的 MFAM 指针,这是 IR PM 的 4 AM 模型之外专为 CodeGen 开的扩展点;
3. **`TM.buildCodeGenPipeline` 是 target 侧 hook**(:88):基类默认实现 `return make_error<StringError>("buildCodeGenPipeline is not overridden", ...)`(`TargetMachine.h:501-508`)。**未 override 的 target 被强制走新 PM 时,运行期直接报 Error**(实测见 §1.8)。

---

## 1.2 opt 工具的双路径

### 1.2.1 默认已是 new PM

`llvm/tools/opt/optdriver.cpp:462-464`:

```cpp
// TODO: remove shouldForceLegacyPM().
const bool UseNPM =
    !shouldForceLegacyPM() || PassPipeline.getNumOccurrences() > 0;
```

`shouldForceLegacyPM()`(`optdriver.cpp:388-395`)只在用户用过时的 `opt -passname` 语法引用"必须 pin 在 legacy PM"的 pass(`shouldPinPassToLegacyPM`)时才返回 true。所以:

- **默认情况(用 `-passes=...` 或 `-O#`)**:UseNPM = true,走 `runPassPipeline`(`optdriver.cpp:801-808`),底层调用 `PassBuilder::parsePassPipeline`。
- **legacy 分支**:位于 `optdriver.cpp:812-870+`,显式拒绝 `-O#`(`:813-814`)、`-module-summary`(`:817-819`)、`-module-hash`(`:821-823`)、`-thinlto-bc`(`:825-827`)。

也就是说 opt 的 legacy 路径**只剩"按名逐个调用老 pass"的兼容壳**,不再承载常规优化管线。

### 1.2.2 `-O#` sugar 的展开

`optdriver.cpp:774-785` 把 `-O1/-O2/...` 翻译为文本管线再交给新 PM:

```cpp
if (OptLevelO0)  Pipeline = "default<O0>";    // :774
if (OptLevelO1)  Pipeline = "default<O1>";
if (OptLevelO2)  Pipeline = "default<O2>";
if (OptLevelO3)  Pipeline = "default<O3>";
if (OptLevelOs)  Pipeline = "default<Os>";
if (OptLevelOz)  Pipeline = "default<Oz>";
```

这也是 `opt -O2` 在 legacy 下报错的原因——`-O2` 不再展开成一串 `addPass`,而是被翻译为字符串送 `PassBuilder`。

### 1.2.3 `-debug-pass` 与 `-debug-pass-manager` 互斥

`optdriver.cpp:755-759` 明确互斥:

```cpp
if (UseNPM) {
  if (legacy::debugPassSpecified()) {
    errs() << "-debug-pass does not work with the new PM, either use "
              "-debug-pass-manager, or use the legacy PM\n";
    return 1;
  }
```

实测(§1.8)也印证:opt 用 `--debug-pass=Structure` 立即报错退出。

---

## 1.3 llc 的双路径

### 1.3.1 默认 legacy

`llc` 的 PM 选择在 `llvm/tools/llc/lib/llcdriver.cpp:739-752`:

```cpp
// Use the NewPM if the user specifies -passes (NewPM specific), specifically
// requests the NewPM with -enable-new-pm, or the target defaults to the
// NewPM, the user has not explicitly disabled the NewPM with
// -enable-new-pm=false, and the user has not specified -run-pass.
if (!PassPipeline.empty() ||                                       // :743
    (EnableNewPassManager.getNumOccurrences() > 0 && EnableNewPassManager) ||  // :744
    (Target->shouldDefaultToNewPM() &&                             // :745
     !(EnableNewPassManager.getNumOccurrences() && !EnableNewPassManager) &&   // :746
     getRunPassNames().empty())) {                                 // :747
  return compileModuleWithNewPM(                                   // :748
      argv[0], std::move(M), std::move(MIR), ...);
}

// Build up all of the passes that we want to do to the module.
legacy::PassManager PM;                                            // :755
PM.add(new TargetLibraryInfoWrapperPass(TLII));                    // :756
```

`EnableNewPassManager` 定义在 `llcdriver.cpp:219-220`:`cl::opt<bool> EnableNewPassManager("enable-new-pm", cl::desc("Enable the new pass manager"), cl::init(false))`。**默认 false**,叠加 `shouldDefaultToNewPM()` 也只有 Lanai/MSP430 会 true——所以**llc 在绝大多数 target 上默认走 legacy**。

`-run-pass` 是 `.mir` 单 pass 调试入口,一旦使用即强制 legacy(`llcdriver.cpp:791-814` 只能在 legacy 下用;新 PM 下用 `-passes` 替代,见 NewPMDriver.cpp:159-176)。

### 1.3.2 new PM 侧:`compileModuleWithNewPM`

`llvm/tools/llc/lib/NewPMDriver.cpp:92-97` 定义入口,核心步骤:

```cpp
MachineFunctionAnalysisManager MFAM;   // NewPMDriver.cpp:130
LoopAnalysisManager LAM;               // :131
FunctionAnalysisManager FAM;           // :132
CGSCCAnalysisManager CGAM;             // :133
ModuleAnalysisManager MAM;             // :134
...
PassBuilder PB(Target.get(), PipelineTuningOptions(), std::nullopt, &PIC); // :145
PB.registerModuleAnalyses(MAM);        // :148
PB.registerCGSCCAnalyses(CGAM);
PB.registerFunctionAnalyses(FAM);
PB.registerLoopAnalyses(LAM);
PB.registerMachineFunctionAnalyses(MFAM);   // :152
PB.crossRegisterProxies(LAM, FAM, CGAM, MAM, &MFAM); // :153
...
ExitOnErr(Target->buildCodeGenPipeline(MPM, MAM, *OS, DwoOS ? &DwoOS->os() : nullptr,
                                       FileType, Opt, MMI.getContext(), &PIC)); // :179
```

与 clang 的 `runCodeGenPipelineNewPM` 几乎逐行对应——**两个工具都通过 `TargetMachine::buildCodeGenPipeline` 委托给 target 的 CodeGenPassBuilder**。

---

## 1.4 `addPassesToGenerateCode` 逐行拆解

`llvm/lib/CodeGen/CodeGenTargetMachineImpl.cpp:114-140` 是 legacy 侧 CodeGen 管线的**总装函数**:

```cpp
/// addPassesToX helper drives creation and initialization of TargetPassConfig.
static TargetPassConfig *
addPassesToGenerateCode(CodeGenTargetMachineImpl &TM, PassManagerBase &PM,  // :116
                        bool DisableVerify,
                        MachineModuleInfoWrapperPass &MMIWP) {
  // Targets may override createPassConfig to provide a target-specific
  // subclass.
  TargetPassConfig *PassConfig = TM.createPassConfig(PM);                   // :121
  // Set PassConfig options provided by TargetMachine.
  PassConfig->setDisableVerify(DisableVerify);                              // :123
  PM.add(PassConfig);                                                       // :124
  PM.add(&MMIWP);                                                           // :125

  const TargetOptions &Options = TM.Options;
  TargetLibraryInfoImpl TLII(TM.getTargetTriple(), Options.VecLib);
  PM.add(new TargetLibraryInfoWrapperPass(TLII));                           // :129
  PM.add(
      new RuntimeLibraryInfoWrapper(Options.MCOptions.ABIName, Options.VecLib)); // :130-131

  invokeGlobalTargetPassConfigCallbacks(TM, PM, PassConfig);                // :133

  if (PassConfig->addISelPasses())                                          // :135
    return nullptr;
  PassConfig->addMachinePasses();                                           // :137
  PassConfig->setInitialized();                                             // :138
  return PassConfig;
}
```

逐行解释:

| 行号 | 动作 | 备注 |
|---|---|---|
| :116 | 函数签名 | `TM` 是 target 的 `CodeGenTargetMachineImpl` 引用;`PM` 是 legacy `PassManagerBase &`(抽象基类,见 `llvm/include/llvm/IR/LegacyPassManager.h:40-50`);`MMIWP` 是外层传入或内部 new 的 `MachineModuleInfoWrapperPass` |
| :121 | `TM.createPassConfig(PM)` | target 多态入口。基类实现 `return new TargetPassConfig(*this, PM)`(`TargetPassConfig.cpp:666-669`),target 如 AMDGPU override 为 `new GCNPassConfig / R600PassConfig / AMDGPUPassConfig` |
| :123 | `setDisableVerify(DisableVerify)` | 把 `--disable-verify` 透传给 PassConfig,影响 `addPass` 时是否插入 verifier |
| :124 | `PM.add(PassConfig)` | **PassConfig 本身也是一个 ImmutablePass**(`TargetPassConfig : public ImmutablePass`,见 `TargetPassConfig.h`),要先入 PM 让别的 pass 能 `getAnalysis<TargetPassConfig>()` 拿到 |
| :125 | `PM.add(&MMIWP)` | MachineModuleInfo 的 wrapper 入 PM。注意**裸指针所有权**:此时 `MMIWP` 已被调用方 `addPassesToEmitFile` 拥有(:234-235 `if (!MMIWP) MMIWP = new MachineModuleInfoWrapperPass(this);`),add 之后由 PM 接管 |
| :129-131 | TLI/RuntimeLib 入 PM | 这两个是 CodeGen 阶段**必需的分析**,即使 opt 阶段已注入过同名 pass,CodeGen 阶段在独立 PM 中需要重新注入 |
| :133 | `invokeGlobalTargetPassConfigCallbacks` | 全局回调钩子,允许通过 `TargetPassConfig::registerGlobalTargetPassConfigCallback` 注入额外 pass(主要用于 sanitizer 或外部工具) |
| :135 | `PassConfig->addISelPasses()` | **构建 ISel 及其之前的 IR pass**。返回 true 表示 error。内部调 `addIRPasses → addCodeGenPrepare → addISelPrepare → addCoreISelPasses` |
| :137 | `PassConfig->addMachinePasses()` | **构建 MachineFunction 层的 pass**(regalloc、调度、PEI、AsmPrinter 前的所有 machine pass) |
| :138 | `setInitialized()` | 设置 `Initialized = true`,此后任何 `setOpt / substitutePass / insertPass` 都触发 assert `"PassConfig is immutable"`(`TargetPassConfig.cpp:707-710` 的 `setOpt` 即有此断言)。**这是 PassConfig 的两阶段生命周期分界线** |

上层调用栈:

- `CodeGenTargetMachineImpl::addPassesToEmitFile`(`CodeGenTargetMachineImpl.cpp:229-252`)→ `addPassesToGenerateCode(*this, PM, DisableVerify, *MMIWP)`(:237);
- `CodeGenTargetMachineImpl::addPassesToEmitMC`(`CodeGenTargetMachineImpl.cpp:259-273`)→ 同上(:266),为 MCJIT 使用。

`addPassesToEmitFile` 在 `addPassesToGenerateCode` 之后还做两件事(:241-250):

```cpp
if (TargetPassConfig::willCompleteCodeGenPipeline()) {           // :241
  if (addAsmPrinter(PM, Out, DwoOut, FileType, ...)) return true; // :242
} else {
  if (FileType != CodeGenFileType::Null)
    PM.add(createPrintMIRPass(Out));                              // :247
}
PM.add(createFreeMachineFunctionPass());                          // :250
```

**AsmPrinter 不入 PassConfig**——它是 ModulePass,由 target 自己创建(`getTarget().createAsmPrinter(*this, std::move(MCStreamer))`,`CodeGenTargetMachineImpl.cpp:154-156`),并由 `addAsmPrinter`(:142-162)挂上 PM。`FreeMachineFunctionPass` 在 :250 强制最后插入,确保 `MachineFunction` 析构回收内存。

---

## 1.5 `TargetPassConfig` vs `CodeGenPassBuilder` 接口对照

两者**逻辑上等价但形态完全不同**:`TargetPassConfig` 用**虚函数 hook**(`virtual void addIRPasses();`),`CodeGenPassBuilder` 当前(main,2024-02 之后)也是**虚函数**(注释 :83-85 明确写 "Dispatch is virtual rather than templated on the derived builder"),但加了**模板辅助函数**(`addModulePass/addFunctionPass/addMachineFunctionPass`)做类型分发。

### 1.5.1 关键 hook 对照表

| 阶段 | legacy TargetPassConfig | new PM CodeGenPassBuilder |
|---|---|---|
| 类声明 | `llvm/include/llvm/CodeGen/TargetPassConfig.h:84` | `llvm/include/llvm/Passes/CodeGenPassBuilder.h:86` |
| 构造 | `TargetPassConfig(TargetMachine &TM, PassManagerBase &PM)`(:150) | `CodeGenPassBuilder(TargetMachine &TM, const CGPassBuilderOption &Opts, PassInstrumentationCallbacks *PIC)`(:88-89) |
| 顶层入口 | `bool addISelPasses()`(:244)+ `virtual void addMachinePasses()`(:300) | `Error buildPipeline(ModulePassManager&, ModuleAnalysisManager&, raw_pwrite_stream&, ...)`(:94-96) |
| IR 层 hook | `virtual void addIRPasses()`(:248) | `virtual void addIRPasses(PassManagerWrapper &PMW)`(:306) |
| CodeGenPrepare | `virtual void addCodeGenPrepare()`(:255) | `virtual void addCodeGenPrepare(PassManagerWrapper &PMW)`(:310) |
| PreISel | `virtual void addISelPrepare()`(:259) | `virtual void addISelPrepare(PassManagerWrapper &PMW)`(:314) |
| SDAG 指令选择 | (走 `addCoreISelPasses` 内部,target 通过 `createTargetRegisterAllocator` 等替换) | `virtual Error addInstSelector(PassManagerWrapper &PMW)`(:194) |
| GISel 阶段 | 拆为 `addIRTranslator/addLegalizeMachineIR/addRegBankSelect/addGlobalInstructionSelect` 等(基类非虚,target 通过 substitutePass 定制) | 全套显式虚函数:`addIRTranslator`(:257)/`addLegalizeMachineIR`(:265)/`addRegBankSelect`(:274)/`addGlobalInstructionSelect`(:284) |
| Pre/Post RA | `virtual void addPreRegAlloc()`、`addPostRegAlloc()`(在 TargetPassConfig.h 中) | `virtual void addPreRegAlloc(PMW)`(:209)/`addPostRegAlloc(PMW)`(:231) |
| Machine pass | `virtual void addMachinePasses()`(:300) | `virtual Error addMachinePasses(PassManagerWrapper &PMW)`(:299) |
| AsmPrinter 阶段 | `virtual void addAsmPrinter()` 不存在—— AsmPrinter 由 `CodeGenTargetMachineImpl::addAsmPrinter` 统一处理 | `virtual void addAsmPrinterBegin(PMW)`(:349)/`addAsmPrinter(PMW)`(:351)/`addAsmPrinterEnd(PMW)`(:353) 三段 |
| Pass 注册粒度 | 通过 `addPass(Pass*)` 逐个 add;TargetPassConfig 的 `addPass(AnalysisID)`(:784)支持 substitution/override | 通过模板 `addModulePass<PassT>()`/`addFunctionPass<PassT>()`/`addMachineFunctionPass<PassT>()`(:117/:127/:140)用类型分发 |
| 替换 pass | `substitutePass(AnalysisID StandardID, IdentifyingPassPtr TargetID)`(:211) | 不存在等价——target 直接 override hook 来替换 |
| 插入 pass | `insertPass(AnalysisID TargetPassID, IdentifyingPassPtr InsertedPassID)`(:214),运行时在 `addPass` 中查 `Impl->InsertedPasses`(`TargetPassConfig.cpp:763-765`) | `template <typename TargetPassT, typename InsertedPassT> void insertPass(InsertedPassT &&Pass)`(:383-392),通过 `AfterCallbacks` 在 addMachineFunctionPass 末尾触发(:148-151) |
| 禁用 pass | `disablePass(AnalysisID PassID)`(:220-222),通过 `substitutePass(PassID, IdentifyingPassPtr())` 置空 | `template <typename... PassTs> void disablePass()`(:376-380),通过 `BeforeCallbacks` 在 add 前过滤(:121/:134/:146 的 `runBeforeAdding`) |

### 1.5.2 类型分发的本质差异

**legacy** 用 `AnalysisID`(`const void *`,`llvm/include/llvm/Pass.h:51`)在**运行时**定位 pass:

```cpp
// TargetPassConfig.cpp:784-802
AnalysisID TargetPassConfig::addPass(AnalysisID PassID) {
  IdentifyingPassPtr TargetID = getPassSubstitution(PassID);   // :785 查替换表
  IdentifyingPassPtr FinalPtr = overridePass(PassID, TargetID); // :786 查命令行 override
  if (!FinalPtr.isValid()) return nullptr;
  Pass *P;
  if (FinalPtr.isInstance()) P = FinalPtr.getInstance();
  else {
    P = Pass::createPass(FinalPtr.getID());                    // :794 通过 PassRegistry 创建
    if (!P) llvm_unreachable("Pass ID not registered");
  }
  AnalysisID FinalID = P->getPassID();
  addPass(P);                                                   // :799
  return FinalID;
}
```

`Pass::createPass` 依赖 `PassRegistry`,这就要求所有 legacy pass 必须通过 `INITIALIZE_PASS` 系列宏注册到 `PassRegistry`(详见 §9.3)。

**new PM** 用**类型 + 模板**在编译期确定 pass:

```cpp
// CodeGenPassBuilder.h:139-151
template <typename PassT>
void addMachineFunctionPass(PassT &&Pass, PassManagerWrapper &PMW,
                            bool Force = false, StringRef Name = PassT::name()) {
  static_assert(is_detected<is_machine_function_pass_t, PassT>::value &&
                "Only machine function passes are supported.");
  if (!Force && !runBeforeAdding(Name))   // :146 检查 BeforeCallbacks(disablePass 钩子)
    return;
  PMW.MFPM.addPass(std::forward<PassT>(Pass));  // :148
  for (auto &C : AfterCallbacks) C(Name, PMW.MFPM); // :149-151 insertPass 钩子
}
```

差异:

- **替换粒度**:legacy 可以"替换流水线中某个 pass 而 target 不动其他"(`substitutePass`),new PM 必须 override 整个 hook 或用 `insertPass/disablePass` 组合;
- **pass 标识**:legacy 用 `AnalysisID` 运行时查询,new PM 用 `PassT::name()`(静态字符串)在编译期绑定;
- **依赖**:legacy 可以 `getAnalysis<LiveVariables>()` 在 `getAnalysisUsage` 中声明依赖,new PM 通过 `MachineFunctionAnalysisManager.getResult<LiveVariablesAnalysis>(MF)` 显式取。

### 1.5.3 `PassManagerWrapper` 的设计

new PM 用 `PassManagerWrapper`(`CodeGenPassBuilder.h:60-69`)**同时持有 MPM/FPM/MFPM 三个 PM**,内部通过 `flushFPMsToMPM`(:153)把 function/machine pass 打包成 adaptor 后塞进 module PM:

```cpp
class PassManagerWrapper {
private:
  PassManagerWrapper(ModulePassManager &ModulePM) : MPM(ModulePM) {};
  ModulePassManager &MPM;
  FunctionPassManager FPM;
  MachineFunctionPassManager MFPM;   // :66
  friend class CodeGenPassBuilder;
};
```

这种"wrapper 聚合 3 层 PM"的写法是 2024-02 commit `91e9e3175268`("Rewrite pass manager nesting")引入的,**取代了早期用模板参数 `DerivedT` 做 CRTP 分发**的设计——这也是为什么头注释 :83-85 现在强调"Dispatch is virtual rather than templated"。

---

## 1.6 `willCompleteCodeGenPipeline` 的语义

定义在 `llvm/lib/CodeGen/TargetPassConfig.cpp:678-680`:

```cpp
bool TargetPassConfig::willCompleteCodeGenPipeline() {
  return StopBeforeOpt.empty() && StopAfterOpt.empty();
}
```

即:**当用户没有指定 `-stop-before=<pass>` 或 `-stop-after=<pass>` 时,CodeGen pipeline 会跑完(直到 AsmPrinter)**。返回 false 时表示管线被人为截断——此时 `addPassesToEmitFile` 就不再加 AsmPrinter,而是加 `PrintMIRPass`(见 §1.4 的 :241-247),把 .mir 打到输出。

配套的 `hasLimitedCodeGenPipeline()`(:682-685):

```cpp
bool TargetPassConfig::hasLimitedCodeGenPipeline() {
  return !StartBeforeOpt.empty() || !StartAfterOpt.empty() ||
         !willCompleteCodeGenPipeline();
}
```

只要 4 个 start/stop 选项任一非空,就算"limited pipeline"。llc 的 `-run-pass` 路径利用这一点拒绝不完整的管线(`llcdriver.cpp:800-807`);`NewPMDriver.cpp:99-104` 也用同样判断禁止 `-passes` 与 start/stop 同时用。

**实际意义**:`willCompleteCodeGenPipeline` 是"是否产出最终 .s/.o"的分水岭。`false` 时产物是 `.mir` 中间文件,`true` 时产物是汇编/目标文件。

---

## 1.7 迁移历史考古

| commit | 日期 | 意义 |
|---|---|---|
| `7caea41545fc` | 2013-11-09 | 把老 PM 整体改名到 `legacy::` 命名空间并加 `Legacy` 前缀文件——new PM 正式立项的标志 |
| `911565d1085d` | 2020-08-07 | `[NewPM][CodeGen] Introduce machine pass and machine pass manager`——`MachineFunctionPassManager` / `MachineFunctionPass` 概念首次引入 |
| `480936e741d5` | 2020-12-29 | `Reland "[NewPM][CodeGen] Introduce CodeGenPassBuilder to help build codegen pipeline" (again)`——CodeGenPassBuilder 落地(前两次 revert) |
| `91e9e3175268` | 2024-02-22 | `[NewPM/CodeGen] Rewrite pass manager nesting (#81068)`——引入 `PassManagerWrapper` 聚合三层 PM,**把 CodeGenPassBuilder 从 CRTP 模板改为虚函数分发** |
| `6ea0c0a28343` | 2024-04-30 | `[NewPM][CodeGen] Add MachineFunctionAnalysis (#88610)`——`MachineFunctionAnalysis` 落地,`MachineFunction` 可通过 MFAM 查询 |

关键节点解读:

1. **2013 → 2020,7 年空窗**:new PM 立项后 7 年内只覆盖 IR,CodeGen 一直是 legacy 自留地。原因是 MachineFunction 生命周期与 Function 解耦(必须显式 `releaseMemory`),new PM 的分析缓存模型需要重新设计;
2. **2020 是 CodeGen new PM 元年**:`MachineFunctionPassManager`(:2020-08)+ `CodeGenPassBuilder`(:2020-12)在 4 个月内落地;
3. **2024 是设计定型年**:`91e9e3175268` 把 CodeGenPassBuilder 从"CRTP 模板派生"改为"虚函数 + PassManagerWrapper",**降低二进制体积**(注释 :83-85 "Dispatch is virtual rather than templated on the derived builder so that the target-independent pipeline is emitted once for the whole build instead of once per target");`6ea0c0a28343` 补齐 MachineFunctionAnalysis,让 machine pass 也能查询 `MachineFunction` 级分析;
4. **10 个 target 已迁移 `buildCodeGenPipeline`**:NVPTX、Lanai、SPIRV、WebAssembly、MSP430、X86、AMDGPU(GCN+R600)、RISCV、BPF(每个 target 都有自己的 `XxxCodeGenPassBuilder.cpp`)。AArch64、ARM、Hexagon、PowerPC、SystemZ 等仍未迁移。

---

## 1.8 实测

环境:`build-debug`(AArch64 host,Darwin arm64),注册 target 见 `./build-debug/bin/llc --version`:aarch64 / aarch64_32 / aarch64_be / amdgcn / amdgpu / arm64 / arm64_32 / nvptx / nvptx64 / r600。

### 1.8.1 `opt -passes=default<O2>` 是否还能跑

```bash
$ ./build-debug/bin/opt -passes='default<O2>' -disable-output PassManager-notes/scratch/dualpm-hello.ll
# 静默成功,exit 0
```

✅ **能跑,这是 opt 的标准用法**。日志(`PassManager-notes/scratch/dualpm-opt-o2-newpm.log`,前 8 行):

```
Running pass: MemProfRemoveInfo on [module]
Running pass: Annotation2MetadataPass on [module]
Running pass: ForceFunctionAttrsPass on [module]
Running pass: InferFunctionAttrsPass on [module]
Running analysis: InnerAnalysisManagerProxy<FunctionAnalysisManager, Module> on [module]
Running pass: CoroEarlyPass on [module]
Running pass: EntryExitInstrumenterPass on add (2 instructions)
Running pass: LowerExpectIntrinsicPass on add (2 instructions)
```

`opt -O2` 等价(`optdriver.cpp:774-785` 把 `-O2` 展开为 `default<O2>`)。

反向:`opt --debug-pass=Structure -O2 ...` 报错 `-debug-pass does not work with the new PM, either use -debug-pass-manager, or use the legacy PM`(`optdriver.cpp:755-759` 的守卫,日志存 `scratch/legacy-opt-structure.log`)。

### 1.8.2 `llc -debug-pass-manager` 是否有输出

**AArch64(默认 legacy)**:

```bash
$ ./build-debug/bin/llc -debug-pass-manager PassManager-notes/scratch/dualpm-hello.ll -o /dev/null
# exit 0,0 行输出
```

❌ **没有输出**——`-debug-pass-manager` 是 new PM 的 instrumentation,legacy PM 走 `--debug-pass`。日志存 `scratch/dualpm-llc-debugpm.log`(0 字节)。

**AArch64 强制 new PM**(`-enable-new-pm=1`):

```bash
$ ./build-debug/bin/llc -enable-new-pm=1 -debug-pass-manager PassManager-notes/scratch/dualpm-hello.ll -o /dev/null
buildCodeGenPipeline is not overridden
# exit 1
```

✅ **报错**:`TargetMachine.h:501-508` 的默认实现返回 error。证实 AArch64 在 main 上**尚未迁移到 new PM CodeGen**。

**NVPTX 强制 new PM**(已迁移 target):

```bash
$ ./build-debug/bin/llc -march=nvptx64 -enable-new-pm=1 -debug-pass-manager PassManager-notes/scratch/dualpm-hello.ll -o /dev/null
# exit 0,138 行输出,前 5 行:
Running pass: RequireAnalysisPass<llvm::MachineModuleAnalysis, llvm::Module, ...> on [module]
Running analysis: MachineModuleAnalysis on [module]
Running pass: RequireAnalysisPass<llvm::ProfileSummaryAnalysis, llvm::Module, ...> on [module]
Running analysis: ProfileSummaryAnalysis on [module]
Running pass: RequireAnalysisPass<llvm::CollectorMetadataAnalysis, llvm::Module, ...> on [module]
```

✅ **有输出**。日志存 `scratch/dualpm-llc-nvptx-newpm.log`(138 行)。

**AMDGPU 强制 new PM**:

```bash
$ ./build-debug/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1030 -enable-new-pm=1 -debug-pass-manager PassManager-notes/scratch/dualpm-hello.ll -o /dev/null
# exit 0,263 行输出
```

✅ AMDGPU 也已迁移。日志存 `scratch/dualpm-llc-amdgpu-newpm.log`。

**AMDGPU 默认(不带 `-enable-new-pm`)**:

```bash
$ ./build-debug/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1030 PassManager-notes/scratch/dualpm-hello.ll -o /dev/null
warning: codegen with no subarch in the target triple is deprecated ...
# exit 0(走 legacy,因为 AMDGPU 没 override shouldDefaultToNewPM)
```

### 1.8.3 clang `-c` 走 legacy 的证据

```bash
$ ./build-debug/bin/clang -c PassManager-notes/scratch/dualpm-test.c -o PassManager-notes/scratch/dualpm-test.o \
    -mllvm --debug-pass=Structure
# 输出 Pass Arguments + 树形结构,含 "Target Pass Configuration" 与 "Machine Module Information"
```

✅ `--debug-pass=Structure` 生效,确认**默认走 legacy**。日志存 `scratch/dualpm-clang-aarch64.log`。

强制 new PM(`-mllvm -force-new-pm-codegen`):

```bash
$ ./build-debug/bin/clang -c PassManager-notes/scratch/dualpm-test.c -o /dev/null -mllvm -force-new-pm-codegen
error: unable to interface with target machine
Program aborted due to an unhandled Error:
buildCodeGenPipeline is not overridden
```

❌ AArch64 clang 强制 new PM 直接 abort(exit 134)。日志存 `scratch/dualpm-clang-force-newpm.log`。这与 §1.1.2 的源码分析完全一致:`force-new-pm-codegen` 对应 `ForceNewPM=BOU_TRUE`,绕开了 `shouldDefaultToNewPM()` 检查,但 AArch64 的 `buildCodeGenPipeline` 仍是基类默认 error。

### 1.8.4 实测结论汇总

| 命令 | 默认 PM | 强制 new PM |
|---|---|---|
| `opt -O2` / `opt -passes=default<O2>` | new PM(legacy 已拒 `-O#`) | n/a |
| `opt -debug-pass=Structure` | 报错(守卫 `optdriver.cpp:755-759`) | n/a |
| `llc`(AArch64) | legacy | 报错 `buildCodeGenPipeline is not overridden` |
| `llc`(NVPTX/AMDGPU) | legacy | ✅ 走 `NVPTXCodeGenPassBuilder` / `AMDGPUCodeGenPassBuilder` |
| `llc`(Lanai/MSP430) | **new PM**(唯二默认切换的 target) | n/a |
| `clang -c`(AArch64/AMDGPU) | legacy | abort(AArch64)/ 走新 PM(AMDGPU,待验证) |

---

## 1.9 本篇断言自查表

| 断言 | 文件:行号 | 核实方式 |
|---|---|---|
| `EmitAssemblyHelper::RunCodegenPipeline` 位置 | `clang/lib/CodeGen/BackendUtil.cpp:1194` | grep + read |
| `runCodeGenPipeline` 调用行 | `BackendUtil.cpp:1218` | read |
| `runCodeGenPipeline` 定义文件 | `llvm/lib/Passes/RunCodeGen.cpp:97-111` | grep + read |
| `runCodeGenPipelineLegacy` / `NewPM` 定义 | `RunCodeGen.cpp:35` / `:60` | read |
| `ForceNewPM` 三态选项 | `RunCodeGen.cpp:28-32` | read |
| 分叉条件 `shouldDefaultToNewPM` | `RunCodeGen.cpp:103-105` | read |
| `shouldDefaultToNewPM` 默认 false | `llvm/include/llvm/Target/TargetMachine.h:512` | grep + read |
| 仅 Lanai/MSP430 override | `LanaiTargetMachine.h:63`,`MSP430TargetMachine.h:59` | grep(全仓库 `shouldDefaultToNewPM`) |
| `buildCodeGenPipeline` 基类报 error | `TargetMachine.h:501-508` | read |
| opt `UseNPM` 决定 | `optdriver.cpp:463-464` | read |
| `shouldForceLegacyPM` 定义 | `optdriver.cpp:388-395` | read |
| opt `-O#` 展开 `default<O#>` | `optdriver.cpp:774-785` | read |
| opt legacy 拒绝 `-O#` | `optdriver.cpp:812-814` | read |
| opt `-debug-pass` 与 NPM 互斥 | `optdriver.cpp:755-759` | read + 实测 |
| llc `EnableNewPassManager` 默认 false | `llcdriver.cpp:219-220` | grep + read |
| llc 分叉条件 | `llcdriver.cpp:743-747` | read |
| llc new PM 入口 | `llvm/tools/llc/lib/NewPMDriver.cpp:92` | grep |
| `addPassesToGenerateCode` 位置 | `CodeGenTargetMachineImpl.cpp:116-140` | read |
| `addPassesToEmitFile` 调用 addPassesToGenerateCode | `CodeGenTargetMachineImpl.cpp:237` | read |
| `willCompleteCodeGenPipeline` 定义 | `TargetPassConfig.cpp:678-680` | read |
| `hasLimitedCodeGenPipeline` 定义 | `TargetPassConfig.cpp:682-685` | read |
| `TargetPassConfig::addPass(Pass*)` 实现 | `TargetPassConfig.cpp:737-777` | read |
| `insertPass` legacy 实现 | `TargetPassConfig.cpp:652-660` | read |
| `CodeGenPassBuilder` 类声明 | `llvm/include/llvm/Passes/CodeGenPassBuilder.h:86` | grep |
| `CodeGenPassBuilder` "virtual not templated" 注释 | `CodeGenPassBuilder.h:83-85` | read |
| `PassManagerWrapper` 定义 | `CodeGenPassBuilder.h:60-69` | read |
| new PM `insertPass` 模板 | `CodeGenPassBuilder.h:383-392` | read |
| `MachineFunctionPassManager` 是 typedef | `llvm/include/llvm/CodeGen/MachinePassManager.h:225` | read |
| `MachineFunctionAnalysisManager` 是 typedef | `llvm/include/llvm/CodeGen/MachineFunctionAnalysisManager.h:24` | read |
| milestone commits(5 个) | §1.7 表 | `git log -1 --format="%h %ad %s"` 逐个核实 |
| 实测:opt `-passes=default<O2>` 跑通 | scratch/dualpm-opt-o2-newpm.log | 亲自跑,exit 0 |
| 实测:llc AArch64 `-debug-pass-manager` 无输出 | scratch/dualpm-llc-debugpm.log(0 字节) | 亲自跑 |
| 实测:llc AArch64 `-enable-new-pm=1` 报错 | 终端输出 "buildCodeGenPipeline is not overridden" | 亲自跑,exit 1 |
| 实测:llc NVPTX new PM 138 行输出 | scratch/dualpm-llc-nvptx-newpm.log | 亲自跑 |
| 实测:llc AMDGPU new PM 263 行输出 | scratch/dualpm-llc-amdgpu-newpm.log | 亲自跑 |
| 实测:clang AArch64 `--debug-pass=Structure` 输出 legacy 结构 | scratch/dualpm-clang-aarch64.log | 亲自跑 |
| 实测:clang `-force-new-pm-codegen` abort | scratch/dualpm-clang-force-newpm.log | 亲自跑,exit 134 |
| 已迁移 `buildCodeGenPipeline` 的 target 数 | `grep -rln buildCodeGenPipeline llvm/lib/Target/` → 20 个文件 / 10 个 target(NVPTX/Lanai/SPIRV/WebAssembly/MSP430/X86/AMDGPU(2)/RISCV/BPF) | grep |
