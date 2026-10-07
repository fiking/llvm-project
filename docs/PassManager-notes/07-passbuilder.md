# Pass 管理器深入分析 §7:PassBuilder 文本解析与默认流水线骨架

> 基准:llvm-project main @ `3eda2aebadd4`(2026-09-28)。
> 所有引用均为本仓库 `文件:行号`,经 read/grep 实测核对;动态验证使用 `build-debug`(Debug+Assertions)。
> 实验产物存于 `scratch/pb-/`。

---

## 7.0 总览:PassBuilder 的三副面孔

`PassBuilder` 是新 PM 的总装车间,一个类同时承担三件事:

1. **默认流水线构建**:C++ 函数族 `build*Pipeline()`(大部分在 `llvm/lib/Passes/PassBuilderPipelines.cpp`,2584 行)把 `default<O2>` 之类的抽象请求展开成几百个 pass 的 `ModulePassManager` 树;
2. **文本流水线解析**:`-passes='cgscc(function(instcombine<max-iterations=2>))'` 这种字符串到 pass 树的翻译,集中在 `llvm/lib/Passes/PassBuilder.cpp`(3032 行);
3. **注册表中枢**:`llvm/lib/Passes/PassRegistry.def`(863 行)以 X-macro 方式枚举全部可解析 pass 名,同一份 def 被 9 处 `#include` 重放成解析器、分析注册器、`--print-passes` 打印器与 instrumentation 的类名映射表(§7.3)。

三者的关系:**文本解析与 C++ 构建输出同构的 PM 树,注册表是两者的公共词表**。这也解释了为什么 `-print-pipeline-passes` 能 round-trip(§7.4)——打印器与解析器共享同一份"名字↔构造表达式"映射,而 `default<O2>` 本身在词表里就是一个"宏展开式"的可解析名字(§7.1.1 第三点)。

类的全貌(`llvm/include/llvm/Passes/PassBuilder.h`,1053 行):公有面大致分五段——构建函数族(buildPerModuleDefaultPipeline 等)、解析函数族(parsePassPipeline 五个重载,`:391` 区域注释给出 MIR 管线语法说明)、EP 注册函数族(`:418-570`,§8 详述)、analysis/pipeline 注册回调族(`:572-650`)、invoke 函数族(`:670-710`);私有面是 15 个 EP 回调槽与 5+ 组 parsing/analysis 回调槽的成员声明(`:812-879` 区域,每个都是 `SmallVector<std::function<...>, 2>`)。

---

## 7.1 PassBuilder 的构造与默认流水线层级

### 7.1.1 构造函数

`PassBuilder::PassBuilder` 在 `llvm/lib/Passes/PassBuilder.cpp:590-730`,五参数(`TM`、`PTO`、`PGOOpt`、`PIC`、`FS`),初始化列表之后做三件大事:

- **`:595-596` 目标定制钩子**:`if (TM) TM->registerPassBuilderCallbacks(*this);`——target 的第一轮注入(EP 回调 + 目标 pass 名注册),§8 详述;
- **`:597-639` 类名映射注册**:向 `PassInstrumentationCallbacks` 注册回调,用 `PassRegistry.def`(`:628`)+ `llvm/Passes/MachinePassRegistry.def`(`:637`)把每个 pass 的 C++ 类名映射到文本名,`-print-before/after` 与 `--print-passes` 都依赖这张表;
- **`:641-729` 五个 `registerPipelineParsingCallback`**:把 `default<O?>`、`lto<O?>` 等"整段流水线名"登记为 module/function/cgscc/loop 级回调——所以 `default<O1>` 在解析器眼里不是特判,而是一个普通的可解析 pass 名。

第三点值得展开。以 module 级为例(`:642-657`):

```cpp
registerPipelineParsingCallback(
    [this](StringRef Name, ModulePassManager &PM,
           ArrayRef<PassBuilder::PipelineElement>) {
#define MODULE_CALLBACK(NAME, INVOKE)                                          \
  if (PassBuilder::checkParametrizedPassName(Name, NAME)) {                    \
    auto L = PassBuilder::parsePassParameters(parseOptLevelParam, Name, NAME); \
    if (!L) {                                                                  \
      errs() << NAME ": " << toString(L.takeError()) << '\n';                  \
      return false;                                                            \
    }                                                                          \
    INVOKE(PM, L.get());                                                       \
    return true;                                                               \
  }
#include "PassRegistry.def"
      return false;
    });
```

`default<O>` 本身的注册也是同一机制:它是 `PassRegistry.def:264-269` 的一条 `MODULE_PASS_WITH_PARAMS("default", "", [&](OptimizationLevel L){ setupOptionsForPipelineAlias(PTO, L); return buildPerModuleDefaultPipeline(L); }, parseOptLevelParam, "O0;O1;O2;O3")`——即"整段默认流水线"在词表里就是一个带优化级别参数的 module pass,构造表达式直接调 build 函数;同段还有 `thinlto-pre-link`(`:270-275`)、`thinlto`(`:276-281`)、`lto-pre-link`(`:282-289` 起)等同构条目。所以 `default<O1>` 没有任何特判代码路径,走的是和普通带参 pass 完全相同的 `checkParametrizedPassName`→`parsePassParameters(parseOptLevelParam,...)`→`CREATE_PASS(L)` 流程(§7.2.4),只是 CREATE_PASS 返回的是整棵 PM 树。

`PassRegistry.def` 的 CALLBACK 段(`:833-863`)则登记另一组伪名——**EP 回调的伪 pass 名**:

| def 行号 | 伪名 | 效果 |
|---|---|---|
| `:834` | `pipeline-start-callbacks` | 调 `invokePipelineStartEPCallbacks` |
| `:839` | `pipeline-early-simplification-callbacks`(MODULE_LTO_CALLBACK 段) | 调 `invokePipelineEarlySimplificationEPCallbacks` |
| `:840` | `optimizer-early-callbacks` | 调 `invokeOptimizerEarlyEPCallbacks` |
| `:841` | `optimizer-last-callbacks` | 调 `invokeOptimizerLastEPCallbacks` |
| `:847-850` | `peephole-callbacks` / `scalar-optimizer-late-callbacks` / `vectorizer-start-callbacks` / `vectorizer-end-callbacks`(FUNCTION_CALLBACK 段) | 调对应 invoke |
| `:855` | `cgscc-optimizer-late-callbacks` | 调 `invokeCGSCCOptimizerLateEPCallbacks` |
| `:860-861` | `late-loop-optimizations-callbacks` / `loop-optimizer-end-callbacks`(LOOP_CALLBACK 段) | 调对应 invoke |

这些伪名必须带优化级别参数(宏里写死 `parseOptLevelParam`),实测 `-passes='function(peephole-callbacks)'` 报 `peephole-callbacks: invalid optimization level ''`(scratch/pb-/exp13.log),`-passes='function(peephole-callbacks<O1>)'` 才能跑(exp15.log)——配合加载了 Peephole EP 的插件,该命令把插件 pass 执行了一遍(输出 `[print-fn-names] function: foo/use`)。这条路径的意义:**手写文本管线时也能在任意位置"重放"EP 回调**,不必依赖默认管线的固定挂点。

`parseOptLevelParam`(`:581-588`)只认 `O0/O1/O2/O3`——`Os`/`Oz` 在 `parseOptLevel`(`:566-579`)处直接 `reportFatalUsageError`,提示改用 `optsize`/`minsize` attribute(`:567-571`)。function/cgscc/loop 级的同名回调注册机制分别在 `:678-693`、`:696-711`、`:714-729`。

构造完这五层回调之后,PassBuilder 进入"就绪"状态:任何 `parsePassPipeline` 调用都先查注册表、再查回调链(§7.2.3),`build*` 调用则在固定点位 invoke EP 回调(§8.1.2)。

另一个构造期输入是 `PipelineTuningOptions`(PTO,`llvm/include/llvm/Passes/PassBuilder.h:41-115`):约 20 个字段(LoopInterleaving/LoopVectorization/SLPVectorization/LoopUnrolling/LoopInterchange/LoopFusion/ForgetAllSCEVInLoopUnroll/LicmMssaOptCap/LicmMssaNoAccForPromotionCap/CallGraphProfile/UnifiedLTO/MergeFunctions/InlinerThreshold/EagerlyInvalidateAnalyses 等),默认值由构造函数从全局 cl::opt 读取(`:42-45` 注释)。`buildFunctionSimplificationPipeline` 里 `PTO.LoopUnrolling`、`PTO.ForgetAllSCEVInLoopUnroll` 等字段直接决定 pass 开关参数;`setupOptionsForPipelineAlias`(`llvm/lib/Passes/PassBuilderPipelines.cpp:2078-2082`)在文本名 `default<O1>` 生效时按级别重设 LoopVectorization/SLPVectorization(O1 关、O2+ 开),是"文本管线与 C++ 管线参数对齐"的补丁点——从 `default<O1>` 文本路径进来时 PT O字段被强制覆写,与 `clang -O1` 走 C++ 路径时的行为对齐(PTO 字段覆写与命令行 `-passes` 的交互细节待验证:如用户显式设过 `-loop-vectorize`,覆写是否仍发生)。

### 7.1.2 默认流水线骨架调用图

所有 `build*` 函数都在 `llvm/lib/Passes/PassBuilderPipelines.cpp`。非 LTO 主线(`-O2` 无 LTO)的层级:

```text
buildPerModuleDefaultPipeline        (PassBuilderPipelines.cpp:1765)
├─ O0 分支: buildO0DefaultPipeline   (:2414;O0 分派在 :1767-1768)
├─ instructionCountersPass           (:1771)
├─ MemProfRemoveInfo/Annotation2Metadata/ForceFunctionAttrs (:1780-1786)
├─ invokePipelineStartEPCallbacks    (:1795)
├─ buildModuleSimplificationPipeline (:1123;调用点 :1796 区域)
│   ├─ SampleProfileProbePass(伪探针最先,最小化优化扰动)(:1135-1136)
│   ├─ EarlyFPM(前端输出清理:LowerExpect/SimplifyCFG/SROA/EarlyCSE)(:1172-1185)
│   ├─ SampleProfileLoaderPass(如 SamplePGO)(:1187-1203)
│   ├─ OpenMPOptPass                   (:1208)
│   ├─ invokePipelineEarlySimplificationEPCallbacks (:1221)
│   ├─ IPSCCP / CalledValuePropagation / GlobalOpt  (:1227-1235)
│   ├─ GlobalCleanupPM(mem2reg+instcombine+PeepholeEP+SimplifyCFG)(:1239-1247)
│   ├─ PGO/ctxprof 仪器化             (:1275-1324)
│   ├─ AlwaysInlinerPass              (:1326)
│   ├─ buildModuleInlinerPipeline(:1074,EnableModuleInliner 时;调用点 :1329)
│   │   └─ ModuleInlinerPass(:1100)
│   │       + buildFunctionSimplificationPipeline(:1108-1110)
│   └─ 或 buildInlinerPipeline(:973;调用点 :1331)
│       └─ ModuleInlinerWrapperPass
│           ├─ invokeCGSCCOptimizerLateEPCallbacks (:1043)
│           ├─ CGSCCToFunctionAdaptor(buildFunctionSimplificationPipeline)(:1047-1048)
│           └─ PostOrderFunctionAttrs / devirt 二轮 / CoroSplit(:1060-1070 区域)
├─ buildModuleOptimizationPipeline   (:1518;调用点 :1800 区域)
│   ├─ PartialInliner / EliminateAvailableExternally  (:1524-1537)
│   ├─ ReversePostOrderFunctionAttrs / RecomputeGlobalsAA (:1542/:1566-1567)
│   ├─ invokeOptimizerEarlyEPCallbacks   (:1569)
│   ├─ OptimizePM(function 级大循环)     (:1571)
│   │   ├─ DropUnnecessaryAssumes/LoopVersioningLICM/Float2Int/LowerConstantIntrinsics (:1576-1602)
│   │   ├─ invokeVectorizerStartEPCallbacks (:1616)
│   │   ├─ loop(loop-rotate,loop-deletion,loop-interchange)(:1618-1634)
│   │   ├─ LoopFuse/LoopDistribute/InjectTLIMappings (:1638-1649)
│   │   ├─ addVectorPasses(Level, OptimizePM, LTOPhase)(:1651;定义 :1351)
│   │   │   ├─ LoopVectorizePass           (:1354-1355)
│   │   │   ├─ InferAlignment/LoopLoadElim/InstCombine (:1362-1403)
│   │   │   ├─ SimplifyCFG(攻击性开关组)    (:1438-1445)
│   │   │   ├─ SLPVectorizerPass           (:1454-1459)
│   │   │   └─ VectorCombine/Unroll 等     (:1461 起)
│   │   ├─ invokeVectorizerEndEPCallbacks   (:1653)
│   │   └─ LoopSink/InstSimplify/DivRemPairs/ExpandMemCmp/TailCallElim/SimplifyCFG(:1659-1686)
│   ├─ invokeOptimizerLastEPCallbacks    (:1697)
│   └─ GlobalDCE/ConstantMerge/MergeFunctions/Devirt/LowerCommentString(:1713-1759)
└─ (LTO 分支)buildLTODefaultPipeline   (:2037)
    ├─ invokeFullLinkTimeOptimizationEarlyEPCallbacks(:2043)
    ├─ buildModuleSimplificationPipeline + buildModuleOptimizationPipeline
    └─ invokeFullLinkTimeOptimizationLastEPCallbacks (:2070)
```

**buildFunctionSimplificationPipeline**(`:630`)是每函数的核心化简序列:O1 有独立实现(`buildO1FunctionSimplificationPipeline`,声明于 `llvm/include/llvm/Passes/PassBuilder.h:767-769`;分派在 `:636-637`),O2/O3 共用主体,结构为:

- SROA→EarlyCSE(memssa)→SpeculativeExecution(仅分歧目标)→JumpThreading→CorrelatedValuePropagation→SimplifyCFG→InstCombine→AggressiveInstCombine→LibCallsShrinkWrap(`:646-679`);
- `invokePeepholeEPCallbacks`(`:681`)——target 窥孔 pass 的第一个挂点;
- TailCallElim→SimplifyCFG→Reassociate(`:688-696`);
- 双 LPM 结构:`LPM1`(LoopInstSimplify/LoopSimplifyCFG/LICM(不许投机)/LoopRotate/LICM(许投机)/SimpleLoopUnswitch,`:715-735`)与 `LPM2`(LoopIdiom/IndVarSimplify/`invokeLateLoopOptimizationsEPCallbacks` `:747`/LoopDeletion/LoopFullUnroll/`invokeLoopOptimizerEndEPCallbacks` `:762`);LPM1 用 MemorySSA、LPM2 不用(`:764-773`),注释 `:769-771` 说明原因——LPM2 的 LoopIdiomRecognize/IndVarSimplify/LoopDeletion/LoopFullUnroll 不保留 MemorySSA,而所有 loop pass 都必须保留它才能用 MSSA 适配器;
- 后半段(`:776-839` 区域):SCCP→BDCE→InstCombine→`invokePeepholeEPCallbacks`(:802)→JumpThreading→CorrelatedValuePropagation→ADCE→MemCpyOpt→DSE→CoroElide→`invokeScalarOptimizerLateEPCallbacks`(:830)→SimplifyCFG(sinkCommonInsts)→InstCombine→`invokePeepholeEPCallbacks`(:838)。

所以 Peephole EP 在一条 O2 管线里实际触发 3 次(不算 GlobalCleanupPM 里的第 4 次 `:1243`)——AMDGPU 的 `AMDGPUSimplifyLibCallsPass` 等挂这个点就是为了贴着每次 InstCombine 的输出做收尾。

**buildO0DefaultPipeline**(`:2414`)是最小骨架:instrumentation 计数(`:2421`)→伪探针/PGO(`:2427-2436`)→EntryExitInstrumenter(`:2439`)→`invokePipelineStartEPCallbacks`(`:2442`)→AddDiscriminators/SampleLoader(`:2444-2458`)→`invokePipelineEarlySimplificationEPCallbacks`(`:2460`)→AlwaysInliner(`:2466-2467`,注释 `:2462-2465` 说明 O0 唯一语义义务是 alwaysinline)→一串"空检查式"EP 兜底(CGSCCOptimizerLate `:2476-2481`、LateLoopOptimizations `:2482-2489`、LoopOptimizerEnd `:2490-2497`、ScalarOptimizerLate `:2498-2503`、VectorizerStart `:2507-2512`、VectorizerEnd `:2514-2518`,回调列表非空才建 PM 并包 adaptor)→`invokeOptimizerEarlyEPCallbacks`(`:2505`)→CoroWrapper(`:2521`)→`invokeOptimizerLastEPCallbacks`(`:2528`)→LowerCommentString(`:2534` 区域)。这套"空检查兜底"使 O0 下 target/插件注册的 EP 回调在形式上仍会被考虑——但多数回调(如 AMDGPU 的全部 EP)内部自带 `Level == O0` 早退,实际是否注入视回调实现而定(待验证:没有一个统一的"O0 跳过"约定,各回调自行判断)。

**buildInlinerPipeline**(`:973`)与 **buildModuleInlinerPipeline**(`:1074`)是两套内联器驱动:前者是传统 `ModuleInlinerWrapperPass` 包一段 CGSCC 管线(AttributorCGSCC/PostOrderFunctionAttrs/ArgumentPromotion/OpenMPOptCGSCC→CGSCCOptimizerLateEP→function 化简→二轮 function-attrs→CoroSplit);后者是较新的 `ModuleInlinerPass`(优先级序内联,`:1100`,inline deferral 被显式关闭,注释 `:1092-1098` 说明理由),后接 `buildFunctionSimplificationPipeline` 的 module-to-function adaptor。两者由 `EnableModuleInliner` 开关在 `:1328-1331` 二选一。

---

## 7.2 文本解析:两层管线 + 五级递归

### 7.2.1 词法层:parsePipelineText

`PassBuilder::parsePipelineText`(`llvm/lib/Passes/PassBuilder.cpp:2021-2076`)是整个 `-passes` 语法的唯一词法器。它只认识三个分隔符:`,`、`(`、`)`(`:2029`,`Text.find_first_of(",()")`),把字符串切成 `PipelineElement{Name, InnerPipeline}` 树。核心机制是一条**显式解析栈**:

```text
PipelineStack = { &ResultPipeline }            // :2025-2026
'(' → push &Pipeline.back().InnerPipeline      // :2042-2045
')' → 贪心连续消费 ')',pop 栈                  // :2048-2057
',' → 继续同层                                  // :2038-2040
栈被 pop 空后再遇 ')' → 括号不平衡,返回 nullopt(:2052-2054)
结束时栈深 >1 → 括号不平衡                    (:2069-2071)
')' 后必须跟 ',' 或字符串结束,否则 nullopt     (:2065-2066)
```

两个设计细节:

- **贪心消费连续右括号**(`:2049-2057`):`cgscc(function(instcombine))` 末尾的 `))` 在一次循环里连 pop 两层,避免产生空名元素(注释 `:2049-2050`);
- **词法层不认识 `<...>`**:参数尖括号原样留在 `Name` 里(因为 `<`、`>` 不在分隔符集合),交给下一层的 `checkParametrizedPassName`/`parsePassParameters` 处理(§7.2.4)。这也意味着 `simplifycfg<a;b>(...)` 这种既带参又带子的形式在词法层不会被拆坏——参数里的 `;`、`,` 都被尖括号"保护"了吗?**没有**:`,` 会照常被当成分隔符。实测各 pass 的参数语法都自觉避开 `,` 和 `()`,统一用 `;` 分隔(如 `simplifycfg<bonus-inst-threshold=1;no-forward-switch-cond>`),这是词法器单字符分隔符设计反推出来的参数语法约定(该约定未见显式文档,属从实现与 def 文件归纳,待验证是否存在反例)。

实测 `-passes='cgscc(function(instcombine'` 在词法层即失败,报 `invalid pipeline 'cgscc(function(instcombine'`(scratch/pb-/exp5.log),正是 `:2722-2726` 的兜底报错(parsePipelineText 返回 nullopt)。

### 7.2.2 五个顶层入口(五层递归的外壳)

`parsePassPipeline` 对五种 IR 单元各有一个重载(`llvm/lib/Passes/PassBuilder.cpp`):

| 行号 | 签名 | 特有逻辑 |
|---|---|---|
| `:2720` | `parsePassPipeline(ModulePassManager &, StringRef)` | **自动包裹**:首元素不是 module pass 名时,按 cgscc/function/loop/loopnest/machine-function 的顺序探测(`:2732-2749`),把整条管线自动包成 `cgscc(...)` 或 `function(...)` 或 `function(loop(...))`;全部不命中则交给 `TopLevelPipelineParsingCallbacks`(`:2751-2753`),再失败报 `unknown pass name '{}'`(`:2755-2761`) |
| `:2771` | `parsePassPipeline(CGSCCPassManager &, StringRef)` | 首元素必须是 cgscc pass 名(`:2780-2785`),不自动包裹 |
| `:2794` | `parsePassPipeline(FunctionPassManager &, StringRef)` | 首元素必须是 function pass 名(`:2803-2808`) |
| `:2816` | `parsePassPipeline(LoopPassManager &, StringRef)` | 无首元素检查,直接交给 `parseLoopPassPipeline`(参数名误写成 `CGPM`,`:2816`/`:2824`,属历史遗留小笔误) |
| `:2830` | `parsePassPipeline(MachineFunctionPassManager &, StringRef)` | 注释(`llvm/include/llvm/Passes/PassBuilder.h:389-390`)明说"目前不能处理嵌套" |

自动包裹是 `-passes=instcombine` 能直接跑的原因:首名 `instcombine` 是 function pass,`:2736-2738` 把整管线改写成 `function(instcombine)`,再走 module 级解析。注释 `:2728-2729`("If the first name isn't at the module layer, wrap the pipeline up automatically")是该行为唯一文档。

层级下探靠每层 `parse*Pass` 里的显式名字匹配+递归:

- `parseModulePass`(`:2084`)认识:`module(...)`(`:2091-2097`,嵌套 MPM)、`coro-cond(...)`(`:2098-2104`,包 `CoroConditionalWrapper`)、`cgscc(...)`(`:2105-2110`,递归后包 `createModuleToPostOrderCGSCCPassAdaptor`)、`function[<eager-inv;no-rerun>](...)`(`:2112-2123`,递归后包 `createModuleToFunctionPassAdaptor`;函数名解析器 `parseFunctionPipelineName` 在 `:791-811`,只接受 `eager-inv`/`no-rerun` 两个参数,且 module 层拒绝 `no-rerun`——`:2113-2116` 报 "cannot have a no-rerun module to function adaptor")。
- `parseCGSCCPass`(`:2240`)认识:`cgscc(...)` 自嵌套(`:2247-2253`)、`function(...)`(`:2255-2262`,包 `createCGSCCToFunctionPassAdaptor`)、`devirt<N>(...)`(`:2264-2270`,解析器 `parseDevirtPassName` 在 `:813-820`,生成 `createDevirtSCCRepeatedPass` 重复执行内层管线至多 N 次)。
- `parseFunctionPass`(`:2373`)认识:`function(...)` 自嵌套(`:2380-2386`)、`loop(...)`/`loop-mssa(...)`(`:2388-2397`,后者置 `UseMemorySSA=true` 传给 `createFunctionToLoopPassAdaptor`)、`machine-function(...)`(`:2398-2403`,包 `createFunctionToMachineFunctionPassAdaptor`)。
- `parseLoopPass`(`:2503`)只认识 `loop(...)` 自嵌套(`:2510-2516`)。
- `parseMachinePass`(`:2570`)只认识 `machine-function(...)` 自嵌套(`:2575-2580`);其它嵌套一律 `invalid pipeline`(`:2582`)。

每层递归之后是同一段公共骨架 `parse*PassPipeline`(`parseModulePassPipeline :2708`、`parseCGSCCPassPipeline :2675`、`parseFunctionPassPipeline :2666`、`parseLoopPassPipeline :2657`、`parseMachinePassPipeline :2648`):一个 for 循环把每个 `PipelineElement` 交给对应 `parse*Pass`,任一失败即向上传播 `Error`。五个骨架函数是"同构的薄壳",真正的层级语义全在 `parse*Pass` 的嵌套分支里——这就是为什么任务说"五层递归的公共骨架":五套 `parse*PassPipeline` + `parse*Pass` 形状完全一致,差别只在认识哪些管理器名、包哪种 adaptor。

### 7.2.3 名字归属判定:isXxxPassName

`parsePassPipeline(ModulePassManager&)` 的自动包裹依赖一组 `isXxxPassName`(`:1879` module、`:1907` cgscc、`:1934` function、`:1957` machine-function、`:1980` loopnest、`:1998` loop)。以 `isFunctionPassName` 为例(`:1934-1954`):先特判 `function`/`loop`/`loop-mssa`/`machine-function` 四个管理器名(`:1937-1940`),再用 `PassRegistry.def` 重放 `FUNCTION_PASS`/`FUNCTION_PASS_WITH_PARAMS`/`FUNCTION_ANALYSIS`(后者认 `require<name>`/`invalidate<name>`,`:1948-1950`),最后问 `FunctionPipelineParsingCallbacks`(`callbacksAcceptPassName`,`:1868-1876`,用一个 dummy PM 试跑回调——回调对 dummy PM 产生的副作用被丢弃)。

`licm`/`lnicm` 有特例:`isLoopPassName`/`isLoopNestPassName` 里它们使 `UseMemorySSA=true`(`:2002-2004`、`:1984-1987`),于是自动包裹升级为 `function(loop-mssa(licm))`(`:2741-2746`)——licm 是少数默认开 MemorySSA 的 loop pass,这个特判保证 `-passes=licm` 拿到的分析环境和默认管线一致。

### 7.2.4 参数语法 `<param;param>`

带参 pass 的判定与解析是两步:

1. `PassBuilder::checkParametrizedPassName`(`llvm/include/llvm/Passes/PassBuilder.h:712-719`):strip 掉 pass 名前缀后,要求剩余部分要么为空(全部用默认参数),要么形如 `<...>`;
2. `PassBuilder::parsePassParameters`(`llvm/include/llvm/Passes/PassBuilder.h:736-756`):把 `<>` 内的字符串原样交给 def 里登记的 PARSER lambda(返回 `Expected<ParametersT>`),解析失败直接以 `StringError` 向上抛(`:752-755` 的 assert 限定参数解析器只能返回 StringError)。

参数分隔符约定为 `;`。`parseSinglePassOption`(`llvm/lib/Passes/PassBuilder.cpp:822-839`)是单布尔参数的通用解析器(`<foo>`/`<no-foo>` 风格的反向形式由各 pass 自己的解析器处理)。多参数 pass 如 `loop-unroll<O1>`(优化级别参数,复用 `parseOptLevelParam`)、`instcombine<max-iterations=2;verify-fixpoint>`(结构化参数包 `InstCombineOptions`)。

实测错误诊断质量很好:`opt -passes='function(instcombine<bad-param>)'` 报 `invalid InstCombine pass parameter 'bad-param'`(scratch/pb-/exp4.log),错误信息由 InstCombine 自己的参数解析器产生,经 `parsePassParameters` 透传到 opt 的 `reportFatalUsageError`。注意诊断里没有指出"在哪一层管线失败"——层级信息只体现在 `unknown function pass`/`unknown module pass` 这类前缀上(§7.6)。

### 7.2.5 特殊语法:`require<>`、`invalidate<>` 与 AA 管线

除了普通 pass 与带参 pass,文本语法还有两类"分析操作符",它们不在 def 里单列条目,而是由 `*_ANALYSIS` 宏展开时合成名字:

- `require<analysis-name>`:往 PM 里塞一个 `RequireAnalysisPass<AnalysisT, IRUnitT>`,强制缓存该分析结果。module 级在 `parseModulePass` 的 `MODULE_ANALYSIS` 宏展开(`:2150-2156`)、function 级在 `:2450-2464`、cgscc 级在 `:2297-2304`、loop 级在 `:2548-2555`、machine 级在 `:2605-2611`。典型用途:在 module-to-function adaptor 边界前 `require<globals-aa>` 把 module 分析钉进缓存,防止 adaptor 失效化把它冲掉(`-print-pipeline-passes` 输出的 `require<globals-aa>,function(invalidate<aa>),require<profile-summary>` 段就是这个用法);
- `invalidate<analysis-name>`:塞一个 `InvalidateAnalysisPass`,强制丢弃缓存(宏展开位置同上,如 module 级 `:2157-2161`)。

AA 管线走独立通道:`parseAAPipeline`(`:2844-2862`)把逗号分隔的 AA 名逐个交给 `parseAAPassName`(`:2627-2646`,用 `MODULE_ALIAS_ANALYSIS`/`FUNCTION_ALIAS_ANALYSIS` 宏重放注册进 `AAManager`),`default` 特判直接换 `buildDefaultAAPipeline`(`:2847-2850`)。opt 的 `-aa-pipeline=basic-aa` 实测跑通(scratch/pb-/exp11.log)。AA 的解析**不经过** `parsePipelineText`——它只是逗号分隔名单,无嵌套。

### 7.2.6 适配器:文本括号到运行期 PM 树的映射

文本里的每层括号最终都变成一个"嵌套 PM + 适配器"组合,适配器选择是 parse*Pass 嵌套分支的核心语义:

| 文本形式 | 构造(文件:行号) | 适配器 |
|---|---|---|
| `cgscc(...)` 在 module 层 | `llvm/lib/Passes/PassBuilder.cpp:2105-2110` | `createModuleToPostOrderCGSCCPassAdaptor` |
| `function(...)` 在 module 层 | `:2112-2123` | `createModuleToFunctionPassAdaptor`(可带 `eager-inv`;`no-rerun` 被拒,`:2113-2116`) |
| `function(...)` 在 cgscc 层 | `:2255-2262` | `createCGSCCToFunctionPassAdaptor`(可带两个参数) |
| `loop(...)` / `loop-mssa(...)` 在 function 层 | `:2388-2397` | `createFunctionToLoopPassAdaptor`(后者 `UseMemorySSA=true`) |
| `machine-function(...)` 在 function 层 | `:2398-2403` | `createFunctionToMachineFunctionPassAdaptor` |
| `devirt<N>(...)` 在 cgscc 层 | `:2264-2270` | `createDevirtSCCRepeatedPass`(重复执行内层管线直到不动点或 N 次) |
| `cgscc(...)`/`function(...)`/`loop(...)`/`module(...)`/`machine-function(...)` 自嵌套 | `:2247-2253`/`:2380-2386`/`:2510-2516`/`:2091-2097`/`:2575-2580` | 无适配器,直接嵌套同名 PM |
| `coro-cond(...)` 在 module 层 | `:2098-2104` | `CoroConditionalWrapper`(协程条件执行包装) |

`parseFunctionPipelineName`(`:791-811`)解析的 `eager-inv`/`no-rerun` 参数控制适配器的失效策略:`eager-inv` 让 adaptor 运行后主动失效更多分析(配合 PTO.EagerlyInvalidateAnalyses 降峰值内存),`no-rerun` 标记"第二次跑到同一个函数时跳过"。`-print-pipeline-passes` 输出中的 `function<eager-inv>(...)`、`function<eager-inv;no-rerun>(...)` 就是这两个开关的打印形态(§7.6 exp3-pipeline.log 可见大量实例)。

**打印器与解析器的适配器对应关系**:PM 树里凡是"有名字的 PM 适配器"(module-to-cgscc、module/cgscc-to-function、function-to-loop、function-to-machine-function)打印时输出对应括号名;裸嵌套同名 PM(如 `module(...)` 里的嵌套 MPM)没有打印名,被拍平——这就是 exp10 里 `module(cgscc(...))` 打印成 `cgscc(...)` 的原因(§7.6)。

### 7.2.7 分析管理器的注册与交叉代理

文本解析只负责"变换 pass";分析(`AnalysisManager` 里注册的东西)的注册走另外四条独立通道,构造函数不碰它们,由宿主在构建管线前显式调用:

- `registerModuleAnalyses`(`llvm/lib/Passes/PassBuilder.cpp:732-739`):`MODULE_ANALYSIS` 宏重放 + `ModuleAnalysisRegistrationCallbacks` 回调;
- `registerCGSCCAnalyses`(`:741-748`):`CGSCC_ANALYSIS` 重放 + 回调;
- `registerFunctionAnalyses`(`:750-769`):先注册默认 AA 管线(`:754`,`buildDefaultAAPipeline`),再 `FUNCTION_ANALYSIS` 重放——`:756-764` 的 `if constexpr (std::is_constructible_v<..., const TargetMachine &>)` 检查让"需要 TM 构造的分析"(如 TTI)只在 `TM != nullptr` 时注册,这是 opt 无 `-mtriple` 时行为差异的来源之一;
- `registerLoopAnalyses`(`:782-789`):`LOOP_ANALYSIS` 重放 + 回调;
- `registerMachineFunctionAnalyses`(`:771-779`):`MachinePassRegistry.def` 的 `MACHINE_FUNCTION_ANALYSIS` 重放 + 回调。

四个 AM 之间靠 `crossRegisterProxies`(`:2684-2706`)打通:MAM 注册 `FunctionAnalysisManagerModuleProxy`/`CGSCCAnalysisManagerModuleProxy`(`:2689-2690`),FAM 注册 `ModuleAnalysisManagerFunctionProxy`/`CGSCCAnalysisManagerFunctionProxy`/`LoopAnalysisManagerFunctionProxy`(`:2692-2694`),LAM 注册 `FunctionAnalysisManagerLoopProxy`(`:2695`),有 MFAM 时再补三条 machine 相关 proxy(`:2696-2705`)。宿主侧的调用顺序(clang 实例,`clang/lib/CodeGen/BackendUtil.cpp:963-971` 区域):先注册 TLI,再 registerModuleAnalyses/CGSCC/Function/Loop,最后 crossRegisterProxies——**proxy 必须在所有 AM 都注册完各自分析之后才能交叉注册**,否则 proxy 查询时会找不到对端 AM 的分析。

`parseAAPipeline`(`:2844-2862`)与 AA 的关系:`buildDefaultAAPipeline`(`:2547` 起)产出 `AAManager`,它本身是一个 function 分析(`AAManager` 作为 `AnalysisInfoMixin` 注册进 FAM);文本 `-aa-pipeline` 只是替换这个默认 AA 集合,不改变 AM 结构。

---

## 7.3 PassRegistry.def:一张 863 行的词表

`llvm/lib/Passes/PassRegistry.def` 是"pass 名 → 构造表达式"的唯一真源。本仓库实测条目数(方法:`grep -cE "^\s*<MACRO>\(" PassRegistry.def`):

| 宏 | 条数 | 宏 | 条数 |
|---|---|---|---|
| `MODULE_PASS` | 118 | `MODULE_PASS_WITH_PARAMS` | 19 |
| `CGSCC_PASS` | 8 | `CGSCC_PASS_WITH_PARAMS` | 3 |
| `FUNCTION_PASS` | 168 | `FUNCTION_PASS_WITH_PARAMS` | 29 |
| `LOOP_PASS` | 24 | `LOOP_PASS_WITH_PARAMS` | 4 |
| `LOOPNEST_PASS` | 4 | `MODULE_ANALYSIS` | 23 |
| `CGSCC_ANALYSIS` | 3 | `FUNCTION_ANALYSIS` | 37 |
| `LOOP_ANALYSIS` | 5 | `MODULE_ALIAS_ANALYSIS` | 1 |
| `FUNCTION_ALIAS_ANALYSIS` | 5 | | |

合计 pass 条目 354、analysis 条目 68、alias analysis 条目 6,加 `MODULE_CALLBACK` 等流水线别名宏(def 文件后部,如 `default<O>`/`lto<O>` 系列)。

**MACHINE 系列不在此文件**:`PassRegistry.def` 中 `MACHINE_FUNCTION_*` 计数为 0。机器 pass 的词表是独立的 `llvm/include/llvm/Passes/MachinePassRegistry.def`(268 行),实测 `MACHINE_FUNCTION_PASS` 89 条、`MACHINE_FUNCTION_PASS_WITH_PARAMS` 7 条、`MACHINE_FUNCTION_ANALYSIS` 28 条。消费点分别是 `parseMachinePass` 里的 `#include "llvm/Passes/MachinePassRegistry.def"`(`llvm/lib/Passes/PassBuilder.cpp:2617`)、`isMachineFunctionPassName`(`:1974`)、`registerMachineFunctionAnalyses`(`:771-779`,include 在 `:776`)与构造函数的类名映射段(`:630-637`)。

**一个 pass 名的完整路径**(以 `instcombine` 为例):

1. 词表条目:`llvm/lib/Passes/PassRegistry.def:626-629`,`FUNCTION_PASS_WITH_PARAMS("instcombine", "InstCombinePass", [](InstCombineOptions Opts) { return InstCombinePass(Opts); }, parseInstCombineOptions, "max-iterations=1;no-verify-fixpoint")`——五元组:文本名、类名(供类名映射)、构造 lambda、参数解析器、参数文档串;
2. 解析器:`parseFunctionPass` 的宏展开(`llvm/lib/Passes/PassBuilder.cpp:2430-2449`)——`checkParametrizedPassName` 命中后 `parsePassParameters(parseInstCombineOptions, ...)` 得到参数包,`CREATE_PASS(Params.get())` 构造 pass;`:2435-2445` 的 `if constexpr` 还检查该 pass 是否需要 TargetMachine 构造,若需要而 `TM==nullptr` 则报 `pass '{0}' requires TargetMachine`;
3. 顶层归属:`isFunctionPassName` 的同名宏重放(`:1942-1951`)让它能被自动包裹识别;
4. 分析注册:`registerFunctionAnalyses`(`:750-769`)用 `FUNCTION_ANALYSIS` 宏重放注册 FAM 默认分析(`:765` 是该处 `#include`),其中 `:756-764` 同样用 `if constexpr` 区分"需要 TM 构造的分析"(有 TM 才注册)与普通分析;
5. 类名映射:构造函数 `:597-639` 的宏重放把 `"instcombine"` 绑定到 `InstCombinePass` 类名,供 `-print-before=instcombine` 这类 instrumentation 过滤;
6. `--print-passes`:`printPassNames`(`:2894` 起)再次重放同一张 def 打印全部名字,带参 pass 以 `name<params-doc>` 形式列出(`printPassNameListWithParams`,`:2880-2892`)。

这就是"改一个 pass 名只需动一处"的 X-macro 设计:词表一处、消费端九处(5 个 is*PassName、5 个 parse*Pass、4 个 register*Analyses、1 个类名映射、1 个 printPassNames,另有 parseAAPassName 用 ALIAS_ANALYSIS 段 `:2627-2646`)。

**目标侧扩展**用同构机制:target 自己的 `<Target>PassRegistry.def`(如 `llvm/lib/Target/AMDGPU/AMDGPUPassRegistry.def`,169 行)经由 `llvm/include/llvm/Passes/TargetPassRegistry.inc`(头注释 :8-13 给出用法)展开成一串 `PB.registerPipelineParsingCallback` lambda(该 .inc 对每种 PM 类型生成一段,见 `TargetPassRegistry.inc:107` 起的 module 级、`:120` 区域起的 function 级等),由 `AMDGPUTargetMachine::registerPassBuilderCallbacks` 内的 `#define GET_PASS_REGISTRY "AMDGPUPassRegistry.def"` + `#include "llvm/Passes/TargetPassRegistry.inc"`(`AMDGPUTargetMachine.cpp:1023-1024`)引入。inc 文件还生成类名映射注册(`TargetPassRegistry.inc:24-77` 的 `ADD_CLASS_PASS_TO_PASS_NAME` 段),保证 `-print-before=amdgpu-xxx` 可用。

---

## 7.4 -print-pipeline-passes 与文本/C++ 一致性

实现位于三处协作:

1. **选项定义**:`llvm/lib/Passes/PassBuilder.cpp:425-433`,`llvm::PrintPipelinePasses`(`cl::opt<std::optional<PrintPipelinePassesFormat>>`),支持 `=text`(默认)与 `=tree` 两种格式;
2. **格式化器**:`printFormattedPipelinePasses`(`:453-481`),tree 模式只是对文本串按 `(`、`)`、`,` 加换行缩进的字符串变换(`:459-478`),不重建 PM 树;
3. **打印时机**:文本本身来自 pass 打印回调(`PIC` 的类名映射,§7.1.1)在 pipeline 构建完成后的回写——opt 侧驱动在 `llvm/tools/opt/NewPMDriver.cpp:185-187` 的选项注释(`-print-pipeline-passes` "can be used to create a pipeline")点明了它的定位:**打印结果就是可重新喂给 `-passes` 的文本**。

一致性保证:**文本流水线解析与 C++ 构建走同一份 pass 构造表达式(PassRegistry.def),`-print-pipeline-passes` 则把 C++ 构建的树回写成同一语法**——理论上文本与 C++ 表示可以 round-trip。实测(build-debug,scratch/pb-/):

- `opt -passes='default<O1>,function(mem2reg)' -print-pipeline-passes` 打出 2 千余字符的完整文本管线(exp3-pipeline.log),其中可见 `default<O1>` 已被展开为 `memprof-remove-attributes,annotation2metadata,forceattrs,inferattrs,coro-early,...` 长串,而手写尾部的 `function(mem2reg)` 原样保留在末尾;
- 把打出的文本原样喂回 `-passes=...` 能再跑通(exit=0,exp3-rt2.log),再打印与第一次**完全一致**(diff 为空,唯一差异来自第一次打印时 opt 自动在末尾追加的 `verify`,第二次它同样被追加)——round-trip 稳定;
- tree 模式实测:`-passes='cgscc(function(instcombine<max-iterations=2>))' -print-pipeline-passes=tree` 输出(exp8-tree.log):

  ```text
  cgscc
    function
      instcombine<max-iterations=2;verify-fixpoint>
  verify
  ```

  可见参数被**规范化**(默认参数 `verify-fixpoint` 被显式补全,输入只写了 `max-iterations=2`)——打印器是"规范化器"而非"回显器"。同理 text 模式(exp9-text.log)输出 `cgscc(function(instcombine<max-iterations=2;verify-fixpoint>)),verify`。

回归测试:`llvm/test/Other/pipeline-callbacks-string-api.ll`(:1-13 的 RUN 行用 `-print-pipeline-passes` 检查回调注入的 pipeline 打印结果)。**注意:仓库中不存在名为 `opt-pass-pipeline-printer.ll` 的测试文件**(已实测核实),不要按旧文档找它。

round-trip 的工程意义:`-print-pipeline-passes` 的输出可以直接冻结成"黄金管线",用于复现某个 LLVM 版本的确切 pass 序列(绕过未来版本默认管线变动),或作为差分调试的起点。参数规范化(默认值显式化)进一步保证了冻结文本对默认参数变化免疫。

---

## 7.5 PassBuilder 的 target 定制钩子(与 §8 呼应)

`PassBuilder` 构造函数 `llvm/lib/Passes/PassBuilder.cpp:595-596` 在拿到 `TM` 时第一时间调用 `TM->registerPassBuilderCallbacks(*this)`。虚函数入口声明在 `llvm/include/llvm/Target/TargetMachine.h`(各 target override,如 `llvm/lib/Target/X86/X86TargetMachine.h:72` 的声明)。各 target 实现横评:

| Target | 文件:行号 | EP 回调数 | 其它 |
|---|---|---|---|
| AMDGPU | `llvm/lib/Target/AMDGPU/AMDGPUTargetMachine.cpp:1021` | **7**(ScalarOptimizerLate :1037、VectorizerEnd :1045、PipelineEarlySimplification :1053、Peephole :1081、CGSCCOptimizerLate :1094、OptimizerLast :1124、FullLinkTimeOptimizationLast :1137) | +1 个 CGSCC 层 pipeline parsing callback(`amdgpu-attributor-cgscc`,`:1026-1035`)、+1 个 RegClassFilter 解析回调(`:1190-1199`) |
| NVPTX | `llvm/lib/Target/NVPTX/NVPTXCodeGenPassBuilder.cpp:321` | **2**(PipelineStart :325、FullLinkTimeOptimizationLast :342) | NVVMReflect 挂 PipelineStart(`:325-339`) |
| X86 | `llvm/lib/Target/X86/X86CodeGenPassBuilder.cpp:317` | **0** | 整个函数体只有 `#define GET_PASS_REGISTRY` + `#include TargetPassRegistry.inc`(`:318-319`),即 X86 只注册 pass 名、不挂任何 EP |
| AArch64 | `llvm/lib/Target/AArch64/AArch64TargetMachine.cpp:629` | **2**(LateLoopOptimizations :633、PipelineEarlySimplification :639,后者仅 Windows 下注册 LowerIFuncPass) | |

从 PassBuilder 视角看,这段注入发生在**任何 pipeline 构建之前**(构造期),所以 target 的 EP 回调会被 `buildPerModuleDefaultPipeline`/`buildO0DefaultPipeline` 等在固定挂点无条件 invoke——PassBuilder 本身不知道"谁"注册了回调,只在固定点位 `for (auto &C : XxxEPCallbacks) C(...)`(invoke 系列函数集中在 `llvm/lib/Passes/PassBuilderPipelines.cpp:354-428`)。回调槽的存储是 15 个 `SmallVector<std::function<...>, 2>` 成员(`llvm/include/llvm/Passes/PassBuilder.h:812-849`),注册函数只做 `push_back`(如 `:424-427`)。

由于 target 回调是构造期注入,而插件/API 回调是构造后注入(§8.3.3),同一 EP 槽里的回调执行顺序天然是"target 先于插件"——想抢在 target 之前注入是没有公开途径的,只能通过完全绕过默认管线(手写 `-passes` 或自建 `build*` 等价物)实现。

从"PassBuilder 如何被覆写"的视角再归纳一层:PassBuilder 给 target 留的覆写面其实有四种,粒度从粗到细——

1. **整段管线覆写**:target 不参与(默认管线形状是 target 无关的),但宿主可以完全不调 `build*DefaultPipeline` 而改用文本管线或自建 build 函数;
2. **EP 织入**:上表 4 个 target 的主用法,不动管线骨架,在 15 个固定点位追加 pass;
3. **词表扩展**:`GET_PASS_REGISTRY` 宏 + `TargetPassRegistry.inc`(AMDGPU :1023-1024 的用法),把 target pass 名注入文本语法,使 `opt -passes='amdgpu-lower-module-lds'` 可解析;
4. **分析注册回调**:`registerAnalysisRegistrationCallback` 系列(`PassBuilder.h:582-601`),让 target 往五个 AM 里塞自己的分析;另有 `registerParseAACallback`(`PassBuilder.h:574-577`,槽位 `:882-884`)把自定义 AA 名接入 `-aa-pipeline` 文本解析(经 `parseAAPassName` 的回调兜底,`PassBuilder.cpp:2642-2645`)——当前 main 上无任何 in-tree target 使用它(grep `llvm/lib/Target/` 无命中),属预留通道。

四种手段全部通过同一个 `PassBuilder &` 参数传递,调用时机都是 PB 构造期——这是新 PM 对 target 定制的统一收口。

---

## 7.6 实测记录(scratch/pb-/)

环境:`build-debug/bin/opt`(Debug+Assertions,Darwin arm64)。输入 `scratch/pb-/input.ll`(两个函数,foo 调 bar、use 调 foo)。所有退出码为实测。

| 实验 | 命令 | 结果 | 日志 |
|---|---|---|---|
| 嵌套+参数 | `-passes='cgscc(function(instcombine<max-iterations=2>))'` | exit=0,正常跑通 | exp1.log |
| 带参错误 | `-passes='function(instcombine<bad-param>)'` | exit=1,`invalid InstCombine pass parameter 'bad-param'` | exp4.log |
| 未知 function pass | `-passes='function(bogus-pass)'` | exit=1,`unknown function pass 'bogus-pass'`(对应 `llvm/lib/Passes/PassBuilder.cpp:2498-2500` 的报错) | exp2.log |
| 顶层未知名 | `-passes='bogus-pass'` | exit=1,`unknown pass name 'bogus-pass'`(`:2755-2761`,自动包裹全部探测失败后报) | exp6.log |
| 括号不平衡 | `-passes='cgscc(function(instcombine'` | exit=1,`invalid pipeline '...'`(`:2722-2726` 词法层兜底) | exp5.log |
| 组合管线 | `-passes='default<O1>,function(mem2reg)'` | exit=0;`-print-pipeline-passes` 展开为全量文本 | exp3.log / exp3-pipeline.log |
| round-trip | 将 exp3-pipeline.log 内容原样喂回 `-passes` | exit=0,二次打印与首次完全一致 | exp3-rt2.log / exp3-pipeline2.log |
| tree 格式 | 上述嵌套串 + `-print-pipeline-passes=tree` | 输出 4 行缩进树,参数被规范化补全 `verify-fixpoint` | exp8-tree.log |
| text 格式 | 同上 + `-print-pipeline-passes` | 输出单行文本,尾部自动补 `verify` | exp9-text.log |
| 未知 machine pass | `-passes='function(machine-function(noop-machine-function-pass))'` | exit=1,`unknown machine pass 'noop-machine-function-pass'`(`:2622-2624`) | exp12.log |
| `-aa-pipeline` | `-passes='default<O2>' -aa-pipeline='basic-aa'` | exit=0(AA 管线解析器 `parseAAPipeline` 在 `:2844-2862`,`default` 特判在 `:2847-2850`) | exp11.log |
| 自嵌套 | `-passes='module(cgscc(function(instcombine)))'` | exit=0,打印为 `cgscc(function(instcombine<max-iterations=1;verify-fixpoint>)),verify`——`module(...)` 外壳在打印时被拍平(嵌套 MPM 无打印名) | exp10.log |
| EP 伪名无参数 | `-passes='function(peephole-callbacks)'` | exit=1,`peephole-callbacks: invalid optimization level ''`——CALLBACK 伪名强制要求 `<O?>` 参数 | exp13.log |
| EP 伪名带参数 | `-load-pass-plugin=<PrintFnNames2.so> -passes='function(peephole-callbacks<O1>)'` | exit=0,输出 `[print-fn-names] function: foo/use`——插件注册的 Peephole 回调被该伪名触发 | exp15.log |

诊断质量观察:错误信息全部精确到"哪一级 PM 的哪个名字",带参 pass 的参数错误由 pass 自己的解析器产生(`invalid InstCombine pass parameter 'bad-param'`),与层级错误(`unknown function pass`)形成可区分的两级诊断;词法错误(括号不平衡)则统一报 `invalid pipeline '<原文>'`,不含位置信息——这是 parsePipelineText 只返回 nullopt 不带错误明细的设计后果(`:2052-2071` 的失败路径全部只返回 nullopt)。

`module(...)` 外壳被拍平(exp10)说明:打印器只对"有名字的 PM 适配器"(cgscc/function/loop/machine-function)输出层级,`module(...)` 只是解析期的显式分组,运行期与打印期都不留痕迹。

---

## 7.7 设计观察

1. **词法与语义严格分层**:parsePipelineText 只认三个字符、产出纯数据树,五个 parse*Pass 才把树译成 PM——这保证"括号是否平衡"与"pass 是否存在"是两类独立错误,诊断分别落在 `:2722-2726` 与各 parse*Pass 的兜底(§7.6)。代价是词法错误没有位置信息(nullopt 不带明细),这是用 45 行手写解析器换掉递归下降的取舍。
2. **X-macro 词表是唯一的扩展协调点**:新 pass 要在文本管线可见,只需在 def 里加一行;要支持参数,选 `*_WITH_PARAMS` 并给解析器与参数文档串。九个消费点(§7.3)自动同步——这也是 target 侧 `<Target>PassRegistry.def` + `TargetPassRegistry.inc` 直接复刻同一模式的原因:模式已被证明可扩展,复制比抽象更安全。
3. **自动包裹是可用性的关键**:`-passes=instcombine` 能跑,靠 `:2732-2749` 的四级探测;而探测的实现又复用了解析器本身(`callbacksAcceptPassName` 用 dummy PM 试跑回调,`:1868-1876`)——"能不能解析"与"解析出什么"共享同一段代码,避免了双份判定逻辑漂移。
4. **EP 伪名(CALLBACK 段)把 EP 机制反哺进文本语法**:`peephole-callbacks<O1>` 这类名字让纯文本管线也能消费 EP 回调(§7.1.1),配合 opt 的 `-passes-ep-*` 选项(§8.0),target/插件注入点与文本管线三个世界在语法层打通。
5. **`default<O>` 不是关键字而是词表条目**(`PassRegistry.def:264-269`):默认管线的"特殊地位"完全来自其构造表达式调的是 build 函数而非单个 pass——这解释了为什么 `-passes='default<O1>,function(mem2reg)'` 能无缝拼接(exp3),在解析器眼里 default 与 mem2reg 只是两个相邻的 module 级元素。

---

## 自查表

- [x] PassBuilder.cpp 行数 3032 已核实(`wc -l`);PassBuilderPipelines.cpp 2584 行、PassBuilder.h 1053 行同法核实
- [x] PassRegistry.def 行数 863 已核实;各宏计数用 `grep -cE "^\s*<MACRO>\("` 逐一统计
- [x] MACHINE 系列在 `llvm/include/llvm/Passes/MachinePassRegistry.def` 而非 PassRegistry.def,已核实(89+7+28)
- [x] parsePassPipeline 五重载行号 :2720/:2771/:2794/:2816/:2830 逐一 read 核实
- [x] parsePipelineText 栈机制(:2021-2076)read 核实;贪心 pop、括号后必须跟逗号等细节均出自该函数源码
- [x] buildPerModuleDefaultPipeline :1765、buildO0DefaultPipeline :2414、buildModuleSimplificationPipeline :1123、buildModuleOptimizationPipeline :1518、buildInlinerPipeline :973、buildModuleInlinerPipeline :1074、buildFunctionSimplificationPipeline :630 均 grep+read 核实
- [x] 构造函数三段逻辑(:590-730)read 核实;MODULE_CALLBACK 机制 :642-657 read 核实
- [x] `-print-pipeline-passes` 选项定义 :425-433、格式化 :453-481 核实;round-trip 稳定性为实测(diff 为空)
- [x] "文本与 C++ pipeline 等价"限定为"同一份 def 词表 + 打印器回写"的机制性陈述,不做更强的语义等价断言
- [x] 错误串实验全部实跑并留存日志;instcombine 词表条目位置 :626-629 read 核实
- [!] `llvm/test/Other/opt-pass-pipeline-printer.ll` **不存在**(任务描述中的猜测文件名),实际相关测试是 `llvm/test/Other/pipeline-callbacks-string-api.ll`
- [!] `parsePassPipeline(LoopPassManager &CGPM, ...)` 参数名笔误已在文中注明(:2816)
- [ ] 参数语法中"`,`/`()` 不能出现在 `<...>` 内"是从词法器设计的归纳,未做穷举验证,标"待验证"
- [ ] O0 下 EP 兜底"仍执行回调"的实际效果受回调内部 `Level==O0` 早退影响,标"待验证"
