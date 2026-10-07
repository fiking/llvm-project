# Pass 管理器深入分析 §8:EP 扩展点与 Pass 插件

> 基准:llvm-project main @ `3eda2aebadd4`(2026-09-28)。
> 所有引用均为本仓库 `文件:行号`,经 read/grep 实测核对;动态验证使用 `build-debug`(Debug+Assertions)。
> 实验产物存于 `scratch/plugin-/`。

---

## 8.0 总览:两种"往默认流水线里塞 pass"的方式

新 PM 给外部代码(target、前端、动态库)留了两类注入口:

1. **EP(Extension Point)回调**:`PassBuilder` 预置 15 种扩展点回调槽,每个槽是一个 `SmallVector<std::function<...>, 2>`;默认流水线构建到固定挂点时把该槽的回调依次跑一遍,回调往 PM 里 addPass。注册入口全在 `llvm/include/llvm/Passes/PassBuilder.h:418-570`,槽位存储在 `:812-849`。
2. **PassPlugin 动态库**:`llvm/include/llvm/Plugins/PassPlugin.h` 定义的 C ABI 入口 `llvmGetPassPluginInfo`,让外部 .so 在运行期拿到同一个 `PassBuilder &`,既能注册 pass 名(pipeline parsing callback)也能挂 EP——插件本身不是注入机制,它只是**在 EP/解析回调机制之上的动态分发器**。

opt 侧还有第三条路:`-passes-ep-*` 命令行选项(`llvm/tools/opt/NewPMDriver.cpp:101-180` 定义了 12 个选项:`-passes-ep-peephole`(:101)、`-passes-ep-late-loop-optimizations`(:106)、`-passes-ep-loop-optimizer-end`(:112)、`-passes-ep-scalar-optimizer-late`(:117)、`-passes-ep-cgscc-optimizer-late`(:122)、`-passes-ep-vectorizer-start`(:127)、`-passes-ep-vectorizer-end`(:132)、`-passes-ep-pipeline-start`(:137)、`-passes-ep-pipeline-early-simplification`(:142)、`-passes-ep-optimizer-early`(:147)、`-passes-ep-optimizer-last`(:152)、`-passes-ep-full-lto-early/last`(:157/:163)及 ThinLTO 两个(:169/:175)),`NewPMDriver.cpp:273` 起的 `registerEPCallbacks` 函数把每个非空选项文本绑定到对应 EP 槽——本质是往回调列表里 push 一个"用 PB 解析并执行这段文本"的 lambda。对调试"把我的 pass 插到 Peephole 点"这类需求免去了写 .so 的成本。

三者最终殊途同归到同一个数据结构:PassBuilder 对象里的回调向量。

一个实测揭示的时序陷阱:`registerEPCallbacks` 在 `NewPMDriver.cpp:489` 执行时,**插件回调尚未注册**(插件在 `:492-493` 才注册)——因此 `-passes-ep-peephole='print-fn-names'` 引用插件 pass 名时,`tryParsePipelineText` 阶段的校验失败,打印 "Could not parse -passes-ep-peephole pipeline: unknown function pass 'print-fn-names' in pipeline 'print-fn-names'... I'm going to ignore it." 并**静默忽略**该选项(scratch/pb-/exp16.log 头部);而插件通过自己注册的 Peephole EP 仍然织入了管线(同一日志后续 9 行 `[print-fn-names]` 输出全部来自插件自己的 EP 回调,而非被忽略的命令行选项)。结论:**`-passes-ep-*` 只能引用内置 pass 名,不能引用 `-load-pass-plugin` 带来的名字**——这是注册顺序(§8.3.2)的直接后果。

---

## 8.1 EP 全景表

### 8.1.1 15 种 EP 回调(注册函数)

`llvm/include/llvm/Passes/PassBuilder.h` 中全部 `register*EPCallback` 系列,共 **15 个**(逐一核对,每个函数体都是一句 `XxxEPCallbacks.push_back(C);`):

| # | 注册函数(行号) | 回调签名里的 PM | 触发时机(头文件注释原文归纳) |
|---|---|---|---|
| 1 | `registerPeepholeEPCallback`(:424-427) | FunctionPassManager | 每次 InstCombine 之后的窥孔位置;"perform peephole optimizations similar to the instruction combiner... inserted after each instance of the instruction combiner pass" |
| 2 | `registerLateLoopOptimizationsEPCallback`(:438-441) | LoopPassManager | 循环化简尾部、LoopDeletion 之前;"the last point in the loop optimization pipeline before loop deletion... the place to add passes that can remove loops" |
| 3 | `registerLoopOptimizerEndEPCallback`(:448-451) | LoopPassManager | 循环优化器最末尾;"adding loop passes to the end of the loop optimizer" |
| 4 | `registerScalarOptimizerLateEPCallback`(:458-461) | FunctionPassManager | 主优化之后、收尾化简之前;"after most of the main optimizations, but before the last cleanup-ish optimizations" |
| 5 | `registerCGSCCOptimizerLateEPCallback`(:469-472) | CGSCCPassManager | 主 CGSCC pass 之后、CG 内 function 化简之前 |
| 6 | `registerVectorizerStartEPCallback`(:480-483) | FunctionPassManager | 向量化器等高度目标相关优化之前 |
| 7 | `registerVectorizerEndEPCallback`(:491-494) | FunctionPassManager | 向量化器之后 |
| 8 | `registerPipelineStartEPCallback`(:501-504) | ModulePassManager | 整条管线最开头;"does not apply to 'backend' compiles (LTO and ThinLTO link-time pipelines)" |
| 9 | `registerPipelineEarlySimplificationEPCallback`(:510-514) | ModulePassManager(+Phase) | 输入 IR 基础化简之后 |
| 10 | `registerOptimizerEarlyEPCallback`(:520-524) | ModulePassManager(+Phase) | function 优化管线之前 |
| 11 | `registerOptimizerLastEPCallback`(:530-534) | ModulePassManager(+Phase) | function 优化管线最末尾 |
| 12 | `registerFullLinkTimeOptimizationEarlyEPCallback`(:540-543) | ModulePassManager | Full LTO 管线开头 |
| 13 | `registerFullLinkTimeOptimizationLastEPCallback`(:549-552) | ModulePassManager | Full LTO 管线末尾 |
| 14 | `registerThinLinkTimeOptimizationEarlyEPCallback`(:558-561) | ModulePassManager | ThinLTO 管线开头 |
| 15 | `registerThinLinkTimeOptimizationLastEPCallback`(:567-570) | ModulePassManager | ThinLTO 管线末尾 |

两个结构性观察:

- **签名差异**:#9/#10/#11 三个回调带 `ThinOrFullLTOPhase` 参数(`:511-512`、`:521-522`、`:531-532`),其余不带——LTO 阶段感知的 EP 只有 module 级这三个,因为只有它们同时服务于 prelink/postlink 两种场景;对应槽位类型见 `:828-835` 与 `:846-849`。
- **槽位容量**:15 个槽清一色 `SmallVector<..., 2>`(`:812-849`),即设计上预期"每槽最多两三个注册者"(一个 target + 一个插件);超过 2 只是堆分配,无功能影响。

### 8.1.2 在默认 pipeline 中的插入点

invoke 系列函数定义集中在 `llvm/lib/Passes/PassBuilderPipelines.cpp:354-428`(`invokePeepholeEPCallbacks :354`、`invokeLateLoopOptimizationsEPCallbacks :359`、`invokeLoopOptimizerEndEPCallbacks :364`、`invokeScalarOptimizerLateEPCallbacks :369`、`invokeCGSCCOptimizerLateEPCallbacks :374`、`invokeVectorizerStartEPCallbacks :379`、`invokeVectorizerEndEPCallbacks :384`、`invokeOptimizerEarlyEPCallbacks :389`、`invokeOptimizerLastEPCallbacks :395`、`invokeFullLinkTimeOptimizationEarlyEPCallbacks :401`、`invokeFullLinkTimeOptimizationLastEPCallbacks :406`、`invokeThinLinkTimeOptimizationEarly/Last :411/:416`、`invokePipelineStartEPCallbacks :421`、`invokePipelineEarlySimplificationEPCallbacks :426`),每个都是 `for (auto &C : XxxEPCallbacks) C(PM, Level[, Phase]);` 的薄循环,声明在 `llvm/include/llvm/Passes/PassBuilder.h:670-710`(注释 :670-672 提醒"自定义管线应当调用这些函数,以执行 target 和其它客户端注册的回调"——即自写 build 函数时 invoke 是义务而非可选)。

默认流水线里的**调用点**(同一文件,均已 grep 核实):

| EP | 主调用点(PassBuilderPipelines.cpp) | 位置描述 |
|---|---|---|
| PipelineStart | `:1795`(buildPerModuleDefaultPipeline);`:1897`(buildFatLTODefaultPipeline);O0 的 `:2442` | 非 LTO 管线中 ModuleSimplification 之前 |
| PipelineEarlySimplification | `:1221`(buildModuleSimplificationPipeline);O0 的 `:2460` | EarlyFPM/IPSCCP 之间的全局清理之后 |
| CGSCCOptimizerLate | `:1043`(buildInlinerPipeline 内,注入 MainCGPipeline) | ModuleInlinerWrapperPass 的 CGSCC 段尾部、function 化简 adaptor 之前 |
| Peephole | buildFunctionSimplificationPipeline 内 `:681`/`:802`/`:838`;buildModuleSimplificationPipeline 的 GlobalCleanupPM 内 `:1243` | 每次 InstCombine 之后(一条 O2 管线出现 4 次) |
| LateLoopOptimizations | `:747`(buildFunctionSimplificationPipeline 的 LPM2 内) | LoopDeletion 之前 |
| LoopOptimizerEnd | `:762`(同 LPM2) | LPM2 最末尾 |
| ScalarOptimizerLate | `:830`(buildFunctionSimplificationPipeline 后段) | 主优化后、收尾 SimplifyCFG/InstCombine 之前 |
| VectorizerStart | `:1616`(buildModuleOptimizationPipeline 的 OptimizePM 内) | loop 预处理之后、addVectorPasses 之前 |
| VectorizerEnd | `:1653` | addVectorPasses 之后、LoopSink 之前 |
| OptimizerEarly | `:1569`(buildModuleOptimizationPipeline 内);ThinLTO prelink 转发点 `:1929-1930`;O0 `:2505` | function 优化管线之前 |
| OptimizerLast | `:1697`(buildModuleOptimizationPipeline 尾部);ThinLTO prelink 转发点 `:1931-1932`;O0 `:2528` | function 优化之后、GlobalDCE/ConstantMerge 之前 |
| FullLinkTimeOptimizationEarly | `:2043`(buildLTODefaultPipeline) | Full LTO 管线开头 |
| FullLinkTimeOptimizationLast | `:2070`(buildLTODefaultPipeline) | Full LTO 管线末尾、收尾 pass 之前 |
| ThinLinkTimeOptimizationEarly | `:1953`(buildThinLTODefaultPipeline) | ThinLTO 管线开头 |
| ThinLinkTimeOptimizationLast | `:2003`(无 ctx-prof 路径)/`:2019`(常规路径)(buildThinLTODefaultPipeline) | ThinLTO 管线末尾(两分支各一次) |

ThinLTO prelink 的 `:1926-1936` 有一段值得引用的注释:"Handle Optimizer{Early,Last}EPCallbacks added by clang on PreLink. Actual optimization is going to be done in PostLink stage, but clang can't add callbacks there in case of in-process ThinLTO called by linker."——**评审修正**:这里的语义是 prelink 构建器**显式调用** OptimizerEarly/Last EP,传入 phase=`ThinLTOPreLink`(源码 `:1929-1936` 两个 invoke 的参数)——回调收到的是 PreLink 相位标记(可据此空转或轻处理);**不存在"把回调转发到 postlink 执行"**——真正的优化在 postlink 构建器里以 phase=ThinLTOPostLink 再跑一轮 EP(那是另一次独立调用)。EP 槽位的 ThinOrFullLTOPhase 参数就是为这种相位区分设计的。

EP 回调**只登记不执行**:执行全部发生在上述 `build*Pipeline` 函数体内,因此 `-passes='default<O2>'` 时回调注入的 pass 会出现在 `-print-pipeline-passes` 输出里;而手写的 `-passes='cgscc(...)'` 不经过这些挂点,EP 回调自然不会触发(§7.6 exp9 的打印输出 `cgscc(function(instcombine<max-iterations=2;verify-fixpoint>)),verify` 中不含任何 target EP pass 可佐证)。

### 8.1.3 挂点在 O2 管线中的位置示意

把 §8.1.2 的表格画回 §7.1.2 的骨架(行号均为 `llvm/lib/Passes/PassBuilderPipelines.cpp`):

```text
buildPerModuleDefaultPipeline (:1765)
│  [PipelineStart :1795]  <──────── NVPTX NVVMReflect(:325-339)挂这里
├─ buildModuleSimplificationPipeline (:1123)
│   ├─ EarlyFPM 清理
│   │  [PipelineEarlySimplification :1221]  <── AMDGPU printf/internalize(:1053-1079)
│   ├─ IPSCCP/GlobalOpt
│   │  GlobalCleanupPM: ... instcombine [Peephole :1243] simplifycfg
│   ├─ AlwaysInliner
│   └─ buildInlinerPipeline (:973)
│       └─ CGSCC 段: Attributor/FunctionAttrs/ArgumentPromotion
│          [CGSCCOptimizerLate :1043]  <──── AMDGPU IAS/LowerKernelAttrs(:1094-1121)
│          CGSCCToFunction(buildFunctionSimplificationPipeline :630)
│          │   ├─ ... instcombine [Peephole :681] ...
│          │   ├─ LPM2: loop-idiom,indvars [LateLoopOptimizations :747]
│          │   │      <── AArch64 LoopIdiomVectorize(:633-637)
│          │   │      loop-deletion,loop-unroll-full [LoopOptimizerEnd :762]
│          │   ├─ sccp,bdce,instcombine [Peephole :802]
│          │   ├─ adce,memcpyopt,dse,coro-elide
│          │   │  [ScalarOptimizerLate :830]  <── AMDGPU InferAddressSpaces(:1037-1043)
│          │   └─ simplifycfg,instcombine [Peephole :838]
│          │         <── AMDGPU UseNativeCalls/SimplifyLibCalls(:1081-1092)
│          └─ PostOrderFunctionAttrs / devirt / CoroSplit
├─ buildModuleOptimizationPipeline (:1518)
│   [OptimizerEarly :1569]
│   └─ OptimizePM(function 级)
│       [VectorizerStart :1616]
│       loop 预处理 → addVectorPasses(:1651)
│       [VectorizerEnd :1653]  <── AMDGPU InferAddressSpaces(:1045-1051)
│       LoopSink ... TailCallElim ... SimplifyCFG
│   [OptimizerLast :1697]  <── AMDGPU AMDGPUAttributor(:1124-1135)
│   GlobalDCE/ConstantMerge/MergeFunctions
└─ (Full LTO 另走 buildLTODefaultPipeline :2037)
    [FullLTOEarly :2043] ... [FullLTOLast :2070]  <── AMDGPU/NVPTX KernelInfo、LDS lower
```

从分布看,**Peephole 是密度最高的挂点**(一条 O2 管线 4 次),其次是"Early/Late 成对"的 module 级挂点;loop 级两个挂点只存在于 `buildFunctionSimplificationPipeline` 的 LPM2 内,意味着想插 loop pass 只有这两个选择,没有"每个 loop pass 之后"的细粒度 EP。

---

## 8.2 Target 侧的 EP 用法

入口统一是虚函数 `TargetMachine::registerPassBuilderCallbacks(PassBuilder &)`,由 `PassBuilder` 构造函数在 `llvm/lib/Passes/PassBuilder.cpp:595-596` 无条件调用(前提是 `TM != nullptr`)。

### 8.2.1 AMDGPU:7 个 EP + 1 个解析回调 + 1 个 RegAlloc 过滤器解析回调

`llvm/lib/Target/AMDGPU/AMDGPUTargetMachine.cpp:1021-1200` 的 `AMDGPUTargetMachine::registerPassBuilderCallbacks` 是本仓库 EP 用法最全的样例:

| 行号 | 注册 | 用途(代码核实) |
|---|---|---|
| `:1023-1024` | `#define GET_PASS_REGISTRY "AMDGPUPassRegistry.def"` + include TargetPassRegistry.inc | 把 AMDGPU 的 169 行 def(`llvm/lib/Target/AMDGPU/AMDGPUPassRegistry.def`)展开成各级 pipeline parsing callback 与类名映射 |
| `:1026-1035` | `registerPipelineParsingCallback`(CGSCC 级) | 解析 `amdgpu-attributor-cgscc` 文本名,构造需 `GCNTargetMachine` 的 Attributor pass(`:1030-1031` 的 static_cast 说明它只对 GCN 谱系有意义) |
| `:1037-1043` | `registerScalarOptimizerLateEPCallback` | 主优化尾部加 `InferAddressSpacesPass`(O0 早退,`:1039-1040`) |
| `:1045-1051` | `registerVectorizerEndEPCallback` | 向量化后再加一遍 `InferAddressSpacesPass`——向量化可能产生新的 addrspace 推导机会 |
| `:1053-1079` | `registerPipelineEarlySimplificationEPCallback` | 非 LTOPreLink 且 amdgcn 时(`:1056`):EnableHipStdPar 下加 `HipStdParMathFixupPass`+`HipStdParAcceleratorCodeSelectionPass`(`:1060-1063`,注释 :1057-1059 说明非 `-fgpu-rdc` 时可早做 accelerator code selection),再加 `AMDGPUPrintfRuntimeBindingPass`(`:1065`);`InternalizeSymbols` 且非 PreLink 时加 `InternalizePass`+`GlobalDCEPass`(`:1072-1075`);`EarlyInlineAll && !EnableFunctionCalls` 时加 `AMDGPUAlwaysInlinePass`(`:1077-1078`) |
| `:1081-1092` | `registerPeepholeEPCallback` | 每次 InstCombine 后加 `AMDGPUUseNativeCallsPass`(`:1086`),以及开关控制的 `AMDGPUSimplifyLibCallsPass`(`:1087-1088`)/`AMDGPUUniformIntrinsicCombinePass`(`:1090-1091`) |
| `:1094-1121` | `registerCGSCCOptimizerLateEPCallback` | 组装一个 FPM:`AMDGPUPromoteKernelArgumentsPass`(O2+ 且开关开,`:1104-1105`)→`InferAddressSpacesPass`(`:1109`,注释 :1107-1108 说明要在 SROA 前)→`AMDGPULowerKernelAttributesPass`(`:1113`)→`AMDGPUPromoteAllocaToVectorPass`(`:1118`,注释 :1115-1117 说明要赶在 SROA 与 unroll 前消 alloca),包成 CGSCCToFunction adaptor(`:1120`)挂进 CGSCC 尾部 |
| `:1124-1135` | `registerOptimizerLastEPCallback` | 非 O0、非 PreLink 且开关开时,加整模块 `AMDGPUAttributorPass`(`:1131`,lambda 前的注释 `:1123` 自问"Why is AMDGPUAttributor not in CGSCC?") |
| `:1137-1188` | `registerFullLinkTimeOptimizationLastEPCallback` | Full LTO 收尾:EarlyCSE(memssa)(`:1141-1144`,注释 :1139-1140 说明 full-LTO 管线不像非 LTO 那样留给 codegen 清理)、HipStdPar 两 pass(`:1150-1153`)、三种 LDS lower(`:1157-1162`,注释 :1154-1156 说明为 `-lto-partitions` 提前 lower LDS)、O2+ 的 InferAddressSpaces(`:1163-1169`)、可选 Internalize(`:1171-1174`)、可选 Attributor(`:1175-1181`,支持 ClosedWorldAssumption)、KernelInfoPrinter(`:1183-1187`) |
| `:1190-1199` | `registerRegClassFilterParsingCallback` | 解析 `sgpr`/`vgpr`/`wwm` 寄存器类别过滤名(AMDGPU 专属,供 regalloc 过滤器文本语法用) |

"7 处 EP"的说法指 `:1037`、`:1045`、`:1053`、`:1081`、`:1094`、`:1124`、`:1137` 这七条 `register*EPCallback`,与任务给定区间 1021-1137 吻合(末尾 `:1137` 的 FullLinkTimeOptimizationLast 函数体延伸到 `:1188`,外加 `:1190` 的 RegClassFilter)。grep 计数(`grep -c "register.*EPCallback("` 对该文件)亦为 7。

AMDGPU 的 EP 分布揭示了 GPU 后端的三类 IR 层刚需:**地址空间推导**(挂 3 处:ScalarOptimizerLate/VectorizerEnd/CGSCCOptimizerLate 各一遍 InferAddressSpaces,因为每次大优化都可能暴露新的 addrspace 可推导点)、**kernel 属性与参数提升**(CGSCCOptimizerLate)、**printf/内联/internalize 等运行时 ABI 准备**(PipelineEarlySimplification 与 FullLTO Last)。

### 8.2.2 NVPTX:2 处

`llvm/lib/Target/NVPTX/NVPTXCodeGenPassBuilder.cpp:321-349`:

- `registerPipelineStartEPCallback`(`:325-339`):管线开头放 `NVVMReflectPass`(有 target 名时,`:329-330`,注释 :327-328 说明用户未指定目标架构时不折叠 nvvm.reflect)与 function 级 `NVVMIntrRangePass`+可选 `NVPTXCopyByValArgsPass`(`:332-338`,注释 :333-334 提到 IntrRange 曾引发数值不一致)——nvvm.reflect 的 SM 版本折叠必须赶在内联前,否则 reflect 调用点被内联展开后失去折叠时机;
- `registerFullLinkTimeOptimizationLastEPCallback`(`:342-347`,受 `!NoKernelInfoEndLTO` 保护):Full LTO 末尾打印 KernelInfo,与 AMDGPU `:1183-1187` 同款。

### 8.2.3 X86 与 AArch64:对照组

- **X86**:`llvm/lib/Target/X86/X86CodeGenPassBuilder.cpp:317-320` 的函数体**只有** `#define GET_PASS_REGISTRY "X86PassRegistry.def"` + `#include "llvm/Passes/TargetPassRegistry.inc"`——即 X86 只注册自己的 pass 名(`llvm/lib/Target/X86/X86PassRegistry.def`,81 行),**不挂任何 EP 回调**。
- **AArch64**:`llvm/lib/Target/AArch64/AArch64TargetMachine.cpp:629-643`,两处:`registerLateLoopOptimizationsEPCallback`(`:633-637`,非 O0 加 `LoopIdiomVectorizePass`——AArch64 的循环 idiom 向量化需要挂在 loop 优化尾部、LoopDeletion 之前)与仅 Windows triple 下的 `registerPipelineEarlySimplificationEPCallback`(`:638-642`,加 `LowerIFuncPass`)。

横向结论:EP 的负载与 target 的"IR 级特殊需求"成正比——GPU 后端(AMDGPU 7、NVPTX 2)需要在 IR 层做地址空间推导、kernel 属性、LDS lower、运行时绑定等,EP 密集;CPU 后端把更多定制放在 CodeGenPassBuilder 一侧(如 X86 的 89+ 机器 pass),IR 层 EP 用得很少甚至不用。

---

## 8.3 PassPlugin 体系

### 8.3.1 头文件与 ABI

`llvm/include/llvm/Plugins/PassPlugin.h`(注意:在 `llvm/Plugins/` 目录,**不是** `llvm/Passes/`——本仓库实测 `llvm/include/llvm/Passes/PassPlugin.h` 不存在,网上旧教程里的 include 路径已过时):

- **版本协商**:`LLVM_PLUGIN_API_VERSION` 定义为 `2`(`:36`),注释(`:32-35`)说明"对 `PassPluginLibraryInfo` 做 ABI 破坏修改(回调增删或重排)时递增";
- **`PassPluginLibraryInfo`**(`:45-64`):`extern "C"` 结构体,五个字段——`APIVersion`(uint32_t,`:48`)、`PluginName`(`:50`)、`PluginVersion`(`:52`)、`RegisterPassBuilderCallbacks`(函数指针,`:56`,默认 nullptr)、`PreCodeGenCallback`(`:62-63`,返回 true 可整体接管 codegen 输出并阻止后续回调);
- **入口点**:`extern "C" LLVM_ABI_NOT_EXPORTED LLVM_ATTRIBUTE_WEAK ::llvm::PassPluginLibraryInfo llvmGetPassPluginInfo();`(`:136-138`),weak 符号使静态链接场景可缺省;头文件注释(`:122-135`)给出了最小实现样例;
- **C++ 包装类** `PassPlugin`(`:71-114`):`Load(Filename)` 静态方法(`:78`)、`registerPassBuilderCallbacks(PB)`(`:93-96`,判空调用)、`invokePreCodeGenCallback`(`:99-105`);持有 `sys::DynamicLibrary` 句柄(`:112`)。

### 8.3.2 加载机制

`llvm/lib/Plugins/PassPlugin.cpp:16-49` 的 `PassPlugin::Load`,四步:

1. `sys::DynamicLibrary::getPermanentLibrary` dlopen(`:18-23`)——"permanent" 即不 dlclose,插件生命周期同进程;
2. `Library.getAddressOfSymbol("llvmGetPassPluginInfo")` 找入口(`:29-30`),找不到则报 "Plugin entry point not found in '...'. Is this a legacy plugin?"(`:35-36`)——区分新 PM 插件与旧 `RegisterStandardPasses` 时代的 legacy 插件;
3. 调用入口拿 `PassPluginLibraryInfo`,检查 `APIVersion != LLVM_PLUGIN_API_VERSION` 报版本错,错误信息同时给出插件版本与支持版本(`:41-46`);
4. 返回 `PassPlugin` 值对象。

**opt 侧**:`llvm/tools/opt/optdriver.cpp:285` 定义 `-load-pass-plugin` 选项(`cl::list`);`:447-452` 给选项设回调,**命令行解析阶段**每次出现该选项立即 `PassPlugin::Load` 并存入 `PluginList`(加载失败直接 `reportFatalUsageError`);`optdriver.cpp:474-479` 区域拒绝与 legacy PM 混用("specified with legacy PM")。真正的注册发生在 `llvm/tools/opt/NewPMDriver.cpp:488-503`:

```text
:488      PassBuilder PB(TM, PTO, P, &PIC);      // target 回调在此构造内完成(PassBuilder.cpp:595-596)
:489      registerEPCallbacks(PB);               // opt 自己的 -passes-ep-* 文本管线(NewPMDriver.cpp:273)
:492-493  for (auto &PassPlugin : PassPlugins)
            PassPlugin.registerPassBuilderCallbacks(PB);   // 动态插件
:496-497  for (auto &PassCallback : PassBuilderCallbacks)
            PassCallback(PB);                  // API 传入的 C++ 回调
:500-503  #include "llvm/Support/Extension.def"  // 静态编译进来的扩展(见 §8.3.4)
```

即 opt 的注册顺序:**target(PB 构造内)→ opt 命令行 EP 文本 → 动态插件 → API 回调 → 静态扩展**。同一 EP 槽内回调按此顺序执行。

### 8.3.3 clang 侧:-fpass-plugin

处理路径分四段:

1. **Driver 转发**:`clang/lib/Driver/ToolChains/Clang.cpp:8197-8200`,把 `-fpass-plugin=x.so` 原样转发给 cc1(逐参数);
2. **加载**:`clang/lib/Frontend/CompilerInstance.cpp:1117-1124`(`CompilerInstance::LoadRequestedPlugins`):对 `CodeGenOpts.PassPlugins` 里每个路径调 `llvm::PassPlugin::Load`,成功存入 `PassPlugins` 成员,失败报 `err_fe_unable_to_load_plugin` 并附 dlopen 错误;
3. **注册时机**:`clang/lib/CodeGen/BackendUtil.cpp:898` 构造 `PassBuilder PB(TM.get(), PTO, PGOOpt, &PIC, FS)`——**此时 target 的 `registerPassBuilderCallbacks` 已在 PB 构造里跑完**(`llvm/lib/Passes/PassBuilder.cpp:595-596`);之后 clang 先注册自己的 assignment-tracking 回调(`BackendUtil.cpp:903-924` 区域,`registerPipelineStartEPCallback`),然后 `:954-961`:

   ```cpp
   // Register plugin callbacks with PB.
   for (const std::unique_ptr<PassPlugin> &Plugin : CI.getPassPlugins())
     Plugin->registerPassBuilderCallbacks(PB);          // :954-955
   for (const auto &PassCallback : CodeGenOpts.PassBuilderCallbacks)
     PassCallback(PB);                                  // :956-957
   #define HANDLE_EXTENSION(Ext) \
     get##Ext##PluginInfo().RegisterPassBuilderCallbacks(PB);
   #include "llvm/Support/Extension.def"                // :959-961
   ```

   **顺序确认:target 先(PB 构造内,`BackendUtil.cpp:898` 触发 `PassBuilder.cpp:595-596`),插件后(`BackendUtil.cpp:954-955`),再是 CodeGenOpts 回调与静态扩展**。同一 EP 槽内 target 回调先于插件回调执行。
4. **PreCodeGenCallback**:`BackendUtil.cpp:1206-1209`(`RunCodegenPipeline` 开头),在 codegen 管线前给插件一次整体接管输出的机会,返回 true 则跳过后续默认 codegen。

另:`BackendUtil.cpp:1345-1346` 把已加载插件记录到 `BackendConf.LoadedPassPlugins`(供 reproducible build / 配置转储)。

### 8.3.4 静态扩展:Extension.def

`#include "llvm/Support/Extension.def"` 是"编译期插件"机制:文件**不在源码树**,由 CMake 生成(`llvm/cmake/modules/AddLLVM.cmake:1396-1404`,把 `LLVM_STATIC_EXTENSIONS` 列表逐行写成 `HANDLE_EXTENSION(<name>)`)到 `${LLVM_BINARY_DIR}/include/llvm/Support/Extension.def`。消费端(opt `:500-503`、BackendUtil `:959-961`、`llvm/lib/Extensions/Extensions.cpp:17-26`、`llvm/lib/LTO/LTOBackend.cpp:199-205`)用 `HANDLE_EXTENSION` 宏声明并调用每个静态扩展的 `get<Name>PluginInfo()`——接口与动态插件完全一致(`llvm/lib/Extensions/Extensions.cpp:13-15` 的宏展开可见),区别只在链接方式。本仓库 build-debug 的生成文件内容为空(无静态扩展),即默认构建不走这条路。

### 8.3.5 LTO 后端路径:lld/thin-LTO 里的插件

LTO backend(`llvm/lib/LTO/LTOBackend.cpp`)有独立的插件装载点,与 clang 前端路径并行:

- `RegisterPassPlugins`(`LTOBackend.cpp:202-219`):先跑静态扩展(`:203-206` 的 Extension.def 段),再对 `Conf.PassPluginFilenames` 逐个 `PassPlugin::Load` 并注册(`:209-214`),最后注册 `Conf.LoadedPassPlugins`(已加载对象,`:217-218`);
- 调用点在 `:299`:`PassBuilder PB(TM, Conf.PTO, PGOOpt, &PIC)` 构造(`:297`,target 回调已注入)之后立即 `RegisterPassPlugins(Conf, PB)`;
- `Config` 侧两个字段:`llvm/include/llvm/LTO/Config.h:56-59`(`LoadedPassPlugins` 注释说明"currently used by distributed thin-lto";`PassPluginFilenames` 为文件名列表);
- **lld 接线**:ELF 与 MachO 后端各自把 `-load-pass-plugin`/`--lto-pass-plugin` 类选项转发进 Config——`lld/ELF/LTO.cpp:137` 与 `lld/MachO/LTO.cpp:47` 都是 `c.PassPluginFilenames.push_back(...)`。

至此插件的三条装载路径齐了:**opt**(`optdriver.cpp:447-452` + `NewPMDriver.cpp:492-493`)、**clang 前端**(`CompilerInstance.cpp:1117-1124` + `BackendUtil.cpp:954-955`)、**LTO backend**(`LTOBackend.cpp:202-219`,由 lld 驱动)。三条路径共享同一个 `PassPlugin::Load` 与 `registerPassBuilderCallbacks(PB)` 接口,区别只在谁持有加载后的 `PassPlugin` 对象(opt 用局部 `PluginList`,clang 挂 `CompilerInstance::PassPlugins` 成员,LTO 走 `Config` 的两种形态)。

### 8.3.6 PreCodeGenCallback:插件的第二条 ABI 腿

`PassPluginLibraryInfo::PreCodeGenCallback`(`llvm/include/llvm/Plugins/PassPlugin.h:58-63`)是独立于 PassBuilder 回调的第二入口:签名 `(Module &, TargetMachine &, CodeGenFileType, raw_pwrite_stream &) -> bool`,返回 true 表示"插件自己完成了 codegen,默认 codegen 管线与后续插件回调全部跳过"。调用点:

- clang:`BackendUtil.cpp:1206-1209`(`RunCodegenPipeline` 开头,逐插件尝试,任一返回 true 即 return);
- opt 无对应机制(opt 本身不跑 codegen 默认管线,`-passes` 手写 `default<O2>` 不含 codegen)。

- clang:`BackendUtil.cpp:1206-1209`(`RunCodegenPipeline` 开头,逐插件尝试,任一返回 true 即 return);
- **llc**:`llvm/tools/llc/lib/llcdriver.cpp:717-725`(codegen 前逐插件尝试,返回 true 时 `Out->keep()` 后直接返回;llc 的 `-load-pass-plugin` 选项定义在同文件 `:216`,加载回调 `:398`)。更正一处易错点:opt 不调用此回调(opt 的 pipeline 不含 codegen),llc 与 clang 是仅有的两个调用方(已 grep 全 tools/ 与 lib/LTO 核实)。

这条腿给"完全替换后端"型插件(如自定义目标输出、加密模块写出)留了活路,而不必伪造一个 CodeGenPassBuilder。

### 8.3.7 机器层对照:CodeGenPassBuilder 的 EP 机制

IR 层的 15 个 EP 之外,机器层(MIR)有一套同构但独立的机制,由 `CodeGenPassBuilder`(`llvm/include/llvm/Passes/CodeGenPassBuilder.h`)承载:target 的 `buildCodeGenPipeline` 虚函数(如 `NVPTXCodeGenPassBuilder.cpp:351-358`、`X86CodeGenPassBuilder.cpp:322-329`)创建 target 专属的 CodeGenPassBuilder 子类,由其 `buildPipeline` 把机器 pass 填进 `MachineFunctionPassManager`。这套机制**不经过 PassBuilder 的 EP 槽**——机器层的"扩展点"是 CodeGenPassBuilder 里的虚函数 hook(target 子类 override),与 IR 层"回调向量"风格不同。对插件而言,`RegisterPassBuilderCallbacks` 拿到的 `PassBuilder &` 也能注册 `MachineFunctionPassManager` 级的 pipeline parsing callback(声明见 `llvm/include/llvm/Passes/PassBuilder.h:628-632`),让 `-passes='function(machine-function(my-mf-pass))'` 可解析;但往 codegen 默认管线织入机器 pass 没有公开 EP——这是 IR 层 EP 与机器层 hook 的不对称点(待验证:是否有插件通过 `registerPipelineParsingCallback` + codegen 文本管线达成等价效果)。

---

## 8.4 PassInstrumentationCallbacks 与 EP 的联动

`PassInstrumentationCallbacks`(PIC)是另一条贯穿线:PassBuilder 构造时把 PIC 存进成员(`llvm/lib/Passes/PassBuilder.cpp:593-594` 初始化列表),并向它注册类名映射回调(`:597-639`);EP 回调注入的 pass 一旦进入 PM,就和普通 pass 一样受 instrumentation 管辖——`-print-before`、`-time-passes`、debugify 都看得到它们。clang 侧 PIC 的构造在 `BackendUtil.cpp:893-897`(StandardInstrumentations 注册后立刻建 PB),opt 侧在 `NewPMDriver.cpp:488` 前。这解释了 §8.4.5 实测里插件 pass 的打印名能被 `-print-pipeline-passes` 正确输出的原因:类名映射在 PB 构造时已就位。

顺序链(clang 完整版):**StandardInstrumentations→PIC(`BackendUtil.cpp:893-897`)→ PassBuilder 构造(target 回调,`:898`)→ clang 自身 EP(assignment tracking 等,`:903-924`)→ 插件(`:954-955`)→ CodeGenOpts 回调(`:956-957`)→ 静态扩展(`:959-961`)→ TLI/各 AM 注册(`:963-971` 区域)→ MPM 构建**。

---

## 8.5 实测:最小 pass 插件(scratch/plugin-/)

### 8.5.1 插件源码与编译

`scratch/plugin-/PrintFnNames2.cpp`:一个 `PrintFnNamesPass`(`llvm::detail::PassInfoMixin` 子类,`isRequired()=true`,`run` 里 `errs()` 打印函数名),`llvmGetPassPluginInfo` 里同时注册:

- pipeline parsing callback:文本名 `print-fn-names` → 加入 FPM;
- `registerPeepholeEPCallback`:默认管线的每个窥孔点都插入该 pass。

编译命令(macOS,系统 clang++,对 build-debug 头文件):

```bash
CXX=$(xcrun -f clang++); SDK=$(xcrun --show-sdk-path)
"$CXX" -std=c++17 -fPIC -shared -isysroot "$SDK" -g -O0 \
  -I<repo>/llvm/include -I<repo>/build-debug/include \
  -undefined dynamic_lookup \
  PrintFnNames2.cpp -o PrintFnNames2.so
```

踩坑记录(scratch/plugin-/build.log、build2.log):

- **必须用 build-debug 的 `include/`**:build-shared 是旧构建,其生成头(`IntrinsicEnums.inc` 等)与当前源码树不匹配,混入即类型错误(实测 20+ 个 error);
- **macOS 必须 `-isysroot`**,否则找不到 `<type_traits>`;
- **`-undefined dynamic_lookup`** 让插件不链接任何 LLVM 库,符号(如 `llvm::errs`)在 `dlopen` 时由宿主 opt/clang 解析——这是 LLVM pass 插件的标准做法;
- `PassInfoMixin` 在 `llvm::detail` 命名空间;裸写 `PassInfoMixin` 会报 "no template named"(早期版本已修正为 `llvm::detail::PassInfoMixin`),且新 PM 要求 pass 提供 `static bool isRequired()`,否则模板约束报错(`PassManagerInternal.h` 的检查);
- `-load-pass-plugin` 路径解析按 dlopen 规则,**必须写 `./PrintFnNames.so`** 这类显式相对路径,裸文件名会在 dyld cache 查找中失败(实测错误信息列出一串尝试路径,见 build.log 同目录的早前运行记录)。

### 8.5.2 运行结果

**opt 动态加载**(scratch/plugin-/run.log):

```bash
$ build-debug/bin/opt -load-pass-plugin=./PrintFnNames.so \
    -passes='function(print-fn-names)' -disable-output ../pb-/input.ll
[print-fn-names] function: foo
[print-fn-names] function: use
```

exit=0。负面对照:不带 `-load-pass-plugin` 时同名命令报 `unknown function pass 'print-fn-names'`(noplug.log)——证明名字确实来自插件注册的 parsing callback。

**clang -fpass-plugin + EP 注入**(scratch/plugin-/clang-run2.log):

```bash
$ build-debug/bin/clang -O1 -isysroot $SDK -fpass-plugin=./PrintFnNames2.so \
    tiny.c -S -emit-llvm -o tiny.ll
[print-fn-names] function: sq
[print-fn-names] function: main
[print-fn-names] function: sq
... 共 8 行
```

8 行输出对应 O1 管线中 4 个 Peephole 挂点(§8.1.2:`:681`/`:802`/`:838` 在 function 化简,`:1243` 在 GlobalCleanupPM)× 2 个函数(sq、main)——`print-fn-names` 经由 `registerPeepholeEPCallback` 被自动织入默认管线,无需在命令行点名。这直接验证了 §8.3.3 的注册顺序与 §8.1.2 的挂点位置。

另:早期版本插件(只注册 parsing callback、不注册 EP,scratch/plugin-/PrintFnNames.cpp/.so)在 clang `-O1` 下零输出(clang-run.log,grep 计数 0),因为 `default<O1>` 管线里没有 `print-fn-names` 这个名字——**EP 注入与名字注册是两种独立能力**:前者让 pass 进默认管线,后者让 pass 可被文本管线点名,插件通常两者都注册。

### 8.5.3 结论

- `llvmGetPassPluginInfo` ABI 版本 2 的插件在 build-debug 的 opt 与 clang 上均工作;
- 编译插件不需要链接 LLVM 库(macOS `-undefined dynamic_lookup`),但**必须与宿主二进制同一份头文件/构建配置**——这是 `LLVM_PLUGIN_API_VERSION=2` 显式协商之外的隐性 ABI 约束(待验证:跨 LLVM commit 混用的实际崩溃面,理论上 `PassBuilder` 布局、`std::function` ABI、StringRef 布局任一变化都会炸);
- 插件注册发生在默认管线构建**之前**,因此注入的 pass 会被 `-print-pipeline-passes` 打印、被 `-print-before/after=<类名>` 匹配(经 PB 构造期注册的类名映射,§8.4)。

---

## 8.6 设计观察

1. **EP 是"点位固定、内容开放"的注入模型**:15 个挂点的位置由默认管线作者钦定(写死在 build 函数里),外部只能在挂点上追加内容,不能移动挂点。这与 legacy PM 的"pass 自行声明 scheduling 关系"相反——新 PM 把管线拓扑的所有权收归中央,换取了 `-print-pipeline-passes` 可冻结、可 diff 的确定性。
2. **回调向量 + push_back 的极简实现**:注册函数全是单行 push_back(`PassBuilder.h:424-570`),invoke 函数全是单行 for 循环(`PassBuilderPipelines.cpp:354-428`),EP 机制本身不到 100 行代码。复杂度全部外包给回调内部(如 AMDGPU 的 60 行 FullLTO 回调,`AMDGPUTargetMachine.cpp:1137-1188`)——机制简单、策略分散,是 LLVM 基础设施的典型分层。
3. **插件 ABI 的双层版本观**:显式的 `LLVM_PLUGIN_API_VERSION=2`(`PassPlugin.h:36`)只保护 `PassPluginLibraryInfo` 结构体本身;真正的 ABI 风险在 C++ 层(PassBuilder/StringRef/std::function 布局),官方立场是"插件与宿主同版本同配置重编"(本仓库未见更强保证,§8.5.3 标待验证)。
4. **三条装载路径、一个接口**:opt/clang/LTO 各自持有插件对象,但都汇到 `registerPassBuilderCallbacks(PB)`——插件作者面向一个接口编程,无需感知宿主(§8.3.5)。`PreCodeGenCallback` 是唯一的例外出口,且只有 clang 与 llc 调用(§8.3.6)。
5. **时序即语义**:target(clang `:898`/opt `:488` 构造内)→ 宿主自身 EP → 插件 → API 回调 → 静态扩展,这个顺序在所有宿主中一致(§8.3.2/§8.3.3/§8.3.5),使得"插件覆盖 target 行为"成为不可能(只能追加),而"命令行覆盖插件"在 opt 里因 `-passes-ep-*` 先于插件注册反而**不成立**(§8.0 的时序陷阱)——顺序设计里没有给"后来者居上"留口子。
6. **target 对照实验的启示**:X86 零 EP、AArch64 两个、NVPTX 两个、AMDGPU 七个(§8.2),说明 EP 不是后端的必需品而是"IR 层特殊需求"的出口;后端选型时,IR 层定制需求少的 target 可以完全无视 EP 机制,需求多的(地址空间、kernel ABI、运行时绑定)则集中堆在少数几个点位(Peephole/PipelineEarlySimplification/FullLTOLast 是 AMDGPU 的重载区)。

---

## 自查表

- [x] 15 种 EP 注册函数在 `llvm/include/llvm/Passes/PassBuilder.h:418-570` 逐一列出并核对行号;槽位存储 `:812-849` 核实
- [x] invoke 定义集中在 `llvm/lib/Passes/PassBuilderPipelines.cpp:354-428`,主调用点行号全部 grep 核实(Peephole :681/:802/:838/:1243、CGSCCOptimizerLate :1043、PipelineEarlySimplification :1221、OptimizerEarly :1569、VectorizerStart :1616、VectorizerEnd :1653、OptimizerLast :1697、PipelineStart :1795/:1897、ThinLTO :1953/:2003/:2019、FullLTO :2043/:2070、O0 各点 :2442/:2460/:2505/:2528、ThinLTO prelink 转发 :1929-1932)
- [x] AMDGPU 7 处 EP(`AMDGPUTargetMachine.cpp:1037/:1045/:1053/:1081/:1094/:1124/:1137`)逐一 read 核实;grep 计数=7;外加 parsing callback :1026 与 RegClassFilter :1190
- [x] NVPTX 2 处(`NVPTXCodeGenPassBuilder.cpp:325/:342`)read 核实
- [x] X86 0 处(函数体仅 registry include,`X86CodeGenPassBuilder.cpp:317-320`)read 核实
- [x] AArch64 2 处(`AArch64TargetMachine.cpp:633/:639`)read 核实
- [x] PassPlugin.h 实际路径为 `llvm/include/llvm/Plugins/PassPlugin.h`(任务给的 `llvm/Passes/PassPlugin.h` 不存在,已注明);API version=2(:36)核实
- [x] PassPlugin::Load 实现 `llvm/lib/Plugins/PassPlugin.cpp:16-49` read 核实(4 步:dlopen/找符号/版本检查/返回)
- [x] clang 注册顺序:PIC :893-897 → PB 构造 :898(内含 target 回调,`PassBuilder.cpp:595-596`)→ clang 自身 EP → 插件 :954-955 → PassBuilderCallbacks :956-957 → 静态扩展 :959-961,顺序已核实
- [x] opt 注册顺序 `NewPMDriver.cpp:488-503` 核实;`-load-pass-plugin` 选项 `optdriver.cpp:285`、加载回调 :447-452 核实
- [x] Extension.def 为 CMake 生成文件(`AddLLVM.cmake:1396-1404`),本仓库 build-debug 生成内容为空,已核实
- [x] 最小插件编译+opt+clang 三处实测通过,日志留存于 scratch/plugin-/;负面对照(无插件报 unknown pass、无 EP 注册则默认管线零输出)均已实测
- [!] ThinLTO prelink 的 OptimizerEarly/Last 调用点(:1929-1936)以 phase=ThinLTOPreLink 显式触发——非"转发到 postlink"(评审修正);postlink 另以 ThinLTOPostLink 相位独立跑一轮
- [ ] 插件跨 LLVM commit 的 ABI 稳定性仅作推断,标"待验证"
