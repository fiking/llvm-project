# §4 素材（子代理部分）：PreservedAnalyses 失效契约的周边生态

> 本文件是子代理采集的部分，与主会话 04-preserved-analyses-main.md 合并成文。
> 基准：main @ `3eda2aebadd4`（2026-09-30 核实）；行号均用 Read/grep 亲验；
> 动态验证一律用 `build-debug`（Debug+Assertions）下的 `opt`。

---

## 1. "自知失效"协议：AnalysisResultModel 与具体分析的 invalidate 实现

### 1.1 签约机制：detail::AnalysisResultModel（PassManagerInternal.h:230-259）

新 PM 让每个分析结果**自己决定**是否被失效——不是 AM 单方面按 PA 宣判。签约点在 `detail::AnalysisResultModel` 的构造函数里，它给类型擦除基类 `AnalysisResultConcept` 装上一个 lambda（PassManagerInternal.h:248-257）：

```cpp
this->Invalidate = [](AnalysisResultConceptT &Self, IRUnitT &IR,
                      const PreservedAnalyses &PA, InvalidatorT &Inv) {
  if constexpr (ResultHasInvalidateMethod<IRUnitT, ResultT>::Value) {   // :250
    ResultT &Result = static_cast<AnalysisResultModel &>(Self).Result;
    return Result.invalidate(IR, PA, Inv);   // 自知路径：转发给结果类型
  }
  auto PAC = PA.template getChecker<PassT>();                          // :254
  return !PAC.preserved() &&
         !PAC.template preservedSet<AllAnalysesOn<IRUnitT>>();         // :255-256
};
```

两条路二选一（编译期 if constexpr）：

1. **ResultT 自己定义了 `invalidate(IR, PA, Inv)`**——委托给它；SFINAE 探测在 `ResultHasInvalidateMethod`（PassManagerInternal.h:195-227，用 rank<2>/rank<1>/rank<0> 三档重载决议判定）；
2. **没定义**——退化为纯 PA 判定：`!preserved() && !preservedSet<AllAnalysesOn<IRUnitT>>()`，即"既没被点名保留、也不在 IRUnit 全保留集合里"就失效。注意这个默认路径**不看** `preservedWhenStateless()`——无状态豁免必须由 ResultT 自己写 invalidate 才能拿到（见 §1.3 GlobalsAA）。

类型擦除基类 `AnalysisResultConcept`（PassManagerInternal.h:152-191）只存两个函数指针 `Destroy`/`Invalidate`（:167-168），对外暴露 `bool invalidate(IR, PA, Inv)`（:188-190），返回 true = 结果确实失效。

### 1.2 三个代表性 invalidate 实现

**(a) DominatorTree——纯集合判定（llvm/lib/IR/Dominators.cpp:71-78）**

```cpp
bool DominatorTree::invalidate(Function &F, const PreservedAnalyses &PA,
                               FunctionAnalysisManager::Invalidator &) {
  auto PAC = PA.getChecker<DominatorTreeAnalysis>();
  return !(PAC.preserved() || PAC.preservedSet<AllAnalysesOn<Function>>() ||
           PAC.preservedSet<CFGAnalyses>());
}
```

判定逻辑是"三层任一保留即活"：显式 preserve、函数级全保留、或 **CFGAnalyses 集合保留**——domtree 只依赖 CFG，所以凡声明"不动 CFG"的 pass（`preserveSet<CFGAnalyses>()`）都自动保住 domtree。这就是"哪些改动毁 domtree"的判定答案：**任何不在 CFGAnalyses 集合里的改动**。`CFGAnalyses::SetKey` 定义在 llvm/lib/IR/PassManager.cpp:184。

**(b) MemorySSA——集合判定 + 递归依赖查询（llvm/lib/Analysis/MemorySSA.cpp:2376-2383）**

```cpp
bool MemorySSAAnalysis::Result::invalidate(
    Function &F, const PreservedAnalyses &PA,
    FunctionAnalysisManager::Invalidator &Inv) {
  auto PAC = PA.getChecker<MemorySSAAnalysis>();
  return !(PAC.preserved() || PAC.preservedSet<AllAnalysesOn<Function>>()) ||
         Inv.invalidate<AAManager>(F, PA) ||            // :2381 递归查 AA
         Inv.invalidate<DominatorTreeAnalysis>(F, PA); // :2382 递归查 DT
}
```

MemorySSA 的结果对象里持有 `AA` 与 `DT` 的指针（构造时从 AM 取得，MemorySSA.cpp:2370-2374），所以它自己的存活条件是"我被保留 **且** 我的两个依赖都还活着"。`Inv.invalidate<T>(IR, PA)` 会就地触发 T 的失效判定并缓存结果（见 §1.4）。

**(c) BlockFrequencyInfo——同为 CFGAnalyses 集合判定（llvm/lib/Analysis/BlockFrequencyInfo.cpp:175-182）**

```cpp
bool BlockFrequencyInfo::invalidate(Function &F, const PreservedAnalyses &PA,
                                    FunctionAnalysisManager::Invalidator &) {
  auto PAC = PA.getChecker<BlockFrequencyAnalysis>();
  return !(PAC.preserved() || PAC.preservedSet<AllAnalysesOn<Function>>() ||
           PAC.preservedSet<CFGAnalyses>());
}
```

注意 BFI 的真实依赖是 BPI 与 CI（calculate 签名在 BlockFrequencyInfo.cpp:184-186），但它的 invalidate **没有** `Inv.invalidate<BranchProbabilityAnalysis>` 递归——它把 CFGAnalyses 当作充分条件用。这与 DominatorTree 是同一风格："CFG 不变则我必不变"。

更多递归依赖实例（同一文件体系内，均亲验）：

| 分析 | 文件:行号 | 递归查询的依赖 |
|---|---|---|
| ScalarEvolution | llvm/lib/Analysis/ScalarEvolution.cpp:15132-15134 | AssumptionAnalysis, DominatorTreeAnalysis, LoopAnalysis |
| MemoryDependence | llvm/lib/Analysis/MemoryDependenceAnalysis.cpp:1798-1800 | AAManager, AssumptionAnalysis, DominatorTreeAnalysis |
| DependenceAnalysis | llvm/lib/Analysis/DependenceAnalysis.cpp:2646-2648 | AAManager, ScalarEvolutionAnalysis, LoopAnalysis |
| LoopAccessAnalysis | llvm/lib/Analysis/LoopAccessAnalysis.cpp:3396-3399 | AAManager, SCEV, Loop, DominatorTree |
| BasicAA | llvm/lib/Analysis/BasicAliasAnalysis.cpp:89-91 | AssumptionAnalysis, DominatorTree(可选), TargetLibraryAnalysis |
| FunctionAnalysisManagerLoopProxy | llvm/lib/Analysis/LoopAnalysisManager.cpp:53-59 | MemorySSA, AA, AC, DT, LI, SE（6 个） |
| CGSCCAnalysisManagerModuleProxy | llvm/lib/Analysis/CGSCCPassManager.cpp:603-604 | LazyCallGraphAnalysis, FAModuleProxy |
| OptimizationRemarkEmitter | llvm/lib/Analysis/OptimizationRemarkEmitter.cpp:58 | BlockFrequencyAnalysis（条件持有） |

### 1.3 GlobalsAA：`preservedWhenStateless` 的唯一现身（llvm/lib/Analysis/GlobalsModRef.cpp:825-831）

```cpp
bool GlobalsAAResult::invalidate(Module &, const PreservedAnalyses &PA,
                                 ModuleAnalysisManager::Invalidator &) {
  // Check whether the analysis has been explicitly invalidated. Otherwise,
  // it's stateless and remains preserved.
  auto PAC = PA.getChecker<GlobalsAA>();
  return !PAC.preservedWhenStateless();   // :830 只查"没被 abandon"
}
```

GlobalsAAResult 自称无状态（不缓存可失效的中间态？——它确实缓存了 per-global 的分析结果，但认为这些只依赖 GlobalValue 本身的生命周期，靠 DeletionCallbackHandle 自清理，GlobalsModRef.h:61-73），因此**普通 `PreservedAnalyses::none()` 杀不死它**，唯一的杀死方式是 `PA.abandon<GlobalsAA>()`。这就是 sanitizer 家族必须显式 abandon 的根因（见 §2.2）。

### 1.4 Invalidator：递归依赖查询机制（PassManager.h:318-394）

`AnalysisManager<IRUnitT,...>::Invalidator` 是 AM 定义在内层的类（声明 :318），文档注释（:311-317）说明设计动机：

> "当分析结果内嵌其它分析结果的句柄时，它既要在自己的信息不被保留时失效，也要在内嵌结果被失效时跟着失效。我们把 Invalidator 传给 invalidate()，让分析结果**按需即时定义依赖图**，避免显式建依赖图表示。"

核心是一个 memoize 的 DFS（PassManager.h:357-386 `invalidateImpl`）：

1. **查缓存**：`IsResultInvalidated`（SmallDenseMap<AnalysisKey*, bool, 8>，:362-364）里已有该 ID 就直接返回缓存的布尔值；
2. **查结果表**：`Results.find({ID, &IR})`（:367）——注意这里有个硬断言（:368-371）："Trying to invalidate a dependent result that isn't in the manager's cache is always an error, likely due to a stale result handle!"——**递归依赖查询只能指向已缓存的结果**；依赖一个从未计算过的分析会直接断言失败；
3. **递归判定并落缓存**：`IsResultInvalidated.insert({ID, Result.invalidate(IR, PA, *this)})`（:380-381），随后断言 Inserted（:383-384："likely indicates a dependency cycle!"）——**分析依赖环会在 Debug 构建下当场炸**。

两个入口（PassManager.h:335-352）：模板版 `Inv.invalidate<PassT>(IR, PA)` 走类型直取 `PassT::ID()`；类型擦除版 `Inv.invalidate(ID, IR, PA)` 收 AnalysisKey*，供 proxy 场景（如 §4.1 的 outer invalidation 列表）使用。

Invalidator 的生命周期由 `AnalysisManager::invalidate` 创建（PassManagerImpl.h:177-178），作用域仅限单次 AM.invalidate 调用——DFS 缓存不跨调用共享。主循环里的配合点（PassManagerImpl.h:191-205）：AM 遍历结果链表时先查 `IsResultInvalidated`，已被 Invalidator 递归处理过的 ID 直接跳过（:192-194），保证整个失效过程是"每个结果恰好判定一次"的不动点。

---

## 2. abandon 的用户普查

### 2.1 总量与分布（2026-09-30 grep 实测）

全树（llvm/lib + llvm/include）共 **25 处 `.abandon<...>()` / `.abandon(...)` 调用点**，分布在 16 个文件：

- llvm/lib：**22 处 / 15 个文件**（grep -c 实测）；
- llvm/include：3 处——PassManager.h:960（InvalidateAnalysisPass）、Transforms/Utils/ExtraPassManager.h:71、:94（ExtraFunctionPassManager/ExtraLoopPassManager 吃完 marker 后扔掉）。

代表 10 处（文件:行号 + 一句话语义）：

| # | 文件:行号 | 目标分析 | 语义 |
|---|---|---|---|
| 1 | llvm/lib/Transforms/IPO/Inliner.cpp:652 | InlineAdvisorAnalysis | 整个内联会话结束后丢弃 advisor（下次会话重建） |
| 2 | llvm/lib/Analysis/MLInlineAdvisor.cpp:360-361 | FunctionPropertiesAnalysis, LoopAnalysis | 内联成功后**就地**废掉 caller 的特征分析，然后继续跑 |
| 3 | llvm/lib/Analysis/CGSCCPassManager.cpp:800 | （类型擦除 AnalysisKey*） | SCC 分裂后批量废掉持有旧 SCC 外层依赖的函数分析 |
| 4 | llvm/lib/CodeGen/LowerEmuTLS.cpp:70-72 | GlobalsAA, ModuleSummaryIndexAnalysis, StackSafetyGlobalAnalysis | TLS 改写动了全局变量语义，三个 module 分析必须死 |
| 5 | llvm/lib/Transforms/Instrumentation/MemorySanitizer.cpp:814 | GlobalsAA | 无状态分析的唯一杀死方式（见 §1.3） |
| 6 | llvm/lib/Transforms/Instrumentation/AddressSanitizer.cpp:1368 | GlobalsAA | 同上（HWASan :540、SanitizerCoverage :362、DataFlowSanitizer :3508 同型） |
| 7 | llvm/lib/Transforms/Scalar/InductiveRangeCheckElimination.cpp:928-929, :947-948 | CycleAnalysis, BlockFrequencyAnalysis | pass 内部改完 CFG 后**就地**定向失效，然后继续用 AM |
| 8 | llvm/lib/Transforms/IPO/MergeFunctions.cpp:1136-1137 | BranchProbabilityAnalysis, BlockFrequencyAnalysis | 合并函数后 profile 派生分析作废 |
| 9 | llvm/lib/Transforms/Scalar/CorrelatedValuePropagation.cpp:1465 | LazyValueAnalysis | 有缓存的按需分析，改完就丢 |
| 10 | llvm/lib/CodeGen/VirtRegMap.cpp:339 | LiveDebugVariablesAnalysis | RA 完成后 debug 变量分析失效 |
| 11 | llvm/include/llvm/IR/PassManager.h:960 | （模板 AnalysisT） | InvalidateAnalysisPass 本体 |
| 12 | llvm/lib/IR/PassManager.cpp:96 / CGSCCPassManager.cpp:637, :740 | （类型擦除） | outer proxy 的延迟失效清单兑现（见 §4.2） |

### 2.2 三种用法模式

**模式 A：返回值层——"全保留但点名废掉一个"（`PA = all(); PA.abandon<T>(); return PA;`）**

标准代表就是 `InvalidateAnalysisPass::run`（PassManager.h:958-962）：

```cpp
auto PA = PreservedAnalyses::all();
PA.abandon<AnalysisT>();   // :960
return PA;
```

Inliner.cpp:650-653、MemorySanitizer.cpp:810-815 都属此类。注意 MemorySanitizer 是 `none() + abandon<GlobalsAA>()`（:810-814），注释（:811-813）明说原因："GlobalsAA is considered stateless and does not get invalidated unless explicitly invalidated; PreservedAnalyses::none() is not enough."——这是 abandon 不可被 preserve 表达的唯一场景：**打穿 preservedWhenStateless 的免检通道**。

**模式 B：pass 内部就地失效——"先杀再续跑"（`PA = all(); PA.abandon<T>(); AM.invalidate(F, PA);`）**

代表：MLInlineAdvisor.cpp:359-362（内联后废 caller 特征）、InductiveRangeCheckElimination.cpp:927-931 与 :946-950（改完 CFG 立刻废 Cycle/BFI）。这种用法里 PA 根本不是 pass 的返回值，而是**给 AM.invalidate 的定向手术刀**——pass 主动履行"我改了什么"的契约，让后续 getResult 拿到新鲜结果。

**模式 C：proxy/基础设施的类型擦除 abandon（`PA.abandon(AnalysisKey*)`）**

仅 3 处：PassManager.cpp:96、CGSCCPassManager.cpp:637、:740，以及同机制批量用法 CGSCCPassManager.cpp:795-800。这是 outer-analysis-proxy 的延迟失效兑现（详见 §4.2），因为外层分析 ID 在编译期未知，必须用类型擦除版。

### 2.3 关于"verify 失败后 abandon"的考察结论

任务预期的 `runWithPreservedAnalysis`/`VerificationDiagnostic` 模式在当前树里**不存在**（grep 全树无此符号，待验证是否为旧版 LLVM 的曾用名）。实际的"verify 失败"处理路径有两条，都不是 abandon：

1. **PreservedCFGCheckerInstrumentation**（StandardInstrumentations.cpp:1435-1488）：pass 跑完后对比 StructuralHash 与 CFG 图，发现"声明天改了但没失效分析"直接 `report_fatal_error`（:1454-1456 函数级"Function @X changed by Y without invalidating analyses"、:1484-1485 模块级、:1465-1471 CFG 级"does not invalidate CFG analyses but CFG changes detected"）。这是 PA 契约看门狗（由 `-verify-analysis-invalidation` 门控，仅 EXPENSIVE_CHECKS 构建默认开），不是恢复机制，也不验分析内容正确性；
2. 上述历史 bug（§3）的修复模式：**改 pass 的返回 PA**（更老实），而不是事后 abandon。

---

## 3. PA 相关的历史 bug 考古（git log 亲验）

| commit | 日期 | 一句话 |
|---|---|---|
| `fdb41805142d` | 2015-01-07 | "[PM] Fix a pretty nasty bug where the new pass manager would invalidate passes too many time."——新 PM 早期，pass 被重复失效多次 |
| `c213c67df804` | 2017-07-09 | "[PM] Fix a nasty bug ... failed to properly invalidation of analyses when merging SCCs"——SCC 合并时漏失效，inliner+domtree 直读脏树；修复要求**先失效再合并** |
| `923ff550b91e` | 2019-03-28 | "[NewPM] Fix a nasty bug with analysis invalidation"——CGSCC pass 可修改**当前 SCC 之外**的 IR（如 ArgumentPromotion 改写调用点），失效框架原本假设"无需跨层重复失效"，被迫引入 out-of-band preserved set 聚合跨 SCC 失效 |
| `aa6c305344e5` | 2020-10-09 | "[LowerMatrixIntrinsics][NewPM] Fix PreservedAnalyses result"——PreservedCFGCheckerInstrumentation 抓到 pass 声称保 CFG 实际没保；修复方式是按 legacy PM 的口径改 PA |
| `694ded37b9d7` | 2020-07-14 | "[OpenMPOpt] Fix preserved analyses return"——返回值声明错误 |
| `1ed53d44d8e9` | 2021-04-01 | "[LoopFlatten] Do not report CFG analyses as up-to-date"——LoopFlattenPass::run 从保留集中删掉 CFGAnalyses（D99700） |

形态归纳：早期 bug（2015-2019）集中在**基础设施自身**（adaptor/proxy 的失效传播）；2020 年之后的 bug 基本都是**单个 pass 的 PA 声明不诚实**（声称保 CFG 实际改了 CFG），靠 PreservedCFGCheckerInstrumentation（§6.3）在 CI 里逮出来。这佐证了 §2.3 的结论：错误修复方向是改声明，不是加恢复。

---

## 4. CGSCC/adaptor 层的 PA 变换

### 4.1 ModuleToFunctionPassAdaptor::run（llvm/lib/IR/PassManager.cpp:128-170）

完整逻辑（亲验）：

```cpp
PreservedAnalyses ModuleToFunctionPassAdaptor::run(Module &M,
                                                   ModuleAnalysisManager &AM) {
  FunctionAnalysisManager &FAM =
      AM.getResult<FunctionAnalysisManagerModuleProxy>(M).getManager();  // :130-131
  PassInstrumentation PI = AM.getResult<PassInstrumentationAnalysis>(M); // :135

  PreservedAnalyses PA = PreservedAnalyses::all();                       // :137
  for (Function &F : M) {
    if (F.isDeclaration()) continue;
    if (!PI.runBeforePass<Function>(*Pass, F)) continue;                 // :145
    PreservedAnalyses PassPA = Pass->run(F, FAM);                        // :148
    // 函数 pass 不可能失效其它函数的分析（契约），所以这里直接处理 FAM：
    FAM.invalidate(F, EagerlyInvalidate ? PreservedAnalyses::none()
                                        : PassPA);                       // :153
    PI.runAfterPass(*Pass, F, PassPA);                                   // :155
    PA.intersect(std::move(PassPA));                                     // :159
  }
  // 我们假设内层函数 pass 没有增删函数，所以 proxy 保留；
  // 且我们已经逐函数做完失效，所以对 Function 的分析全保留：
  PA.preserveSet<AllAnalysesOn<Function>>();                             // :167
  PA.preserve<FunctionAnalysisManagerModuleProxy>();                     // :168
  return PA;
}
```

三个关键 PA 变换：

1. **cross-IRUnit 聚合**：内层 FPM 返回的 PassPA 是对 Function 的声明，adaptor 直接 `PA.intersect` 进对 Module 的聚合 PA（:159）——**Function 层的丢失会传染成 Module 层的丢失**。这是跨层 PA 的唯一汇合点，所以"FPM 里丢了 domtree"会导致外层 MAM 里"Module 上凡是依赖函数信息的分析"被波及（通过 proxy，见 §4.2）。
2. **EagerlyInvalidate 分支**（:153）：开了就对每个函数立刻 `FAM.invalidate(F, none())`——跑完即清，函数分析的内存不攒着。适用场景：巨型 module、内层 pass 链尾不再需要跨函数共享分析结果。声明在 PassManager.h:883-885（默认 false），文本管线拼写 `function<eager-inv>(...)`（printPipeline，PassManager.cpp:118-126）。
3. **收尾补集合**（:167-168）：补 `AllAnalysesOn<Function>` + proxy 保留标记。理由写在注释（:162-166）里：函数分析的失效已经在循环体内逐函数做过，AM 里幸存的 FAM 结果天然有效，所以聚合 PA 必须声明"函数分析全保留"，否则外层 MAM 会再失一遍（双重失效=浪费）。这与 PassManagerImpl.h 主循环收尾的 preserveSet（:95）是同构补偿。

### 4.2 proxy 的延迟失效兑现：abandon 的类型擦除用法

`FunctionAnalysisManagerModuleProxy::Result::invalidate`（PassManager.cpp:52-115）是 cross-IRUnit 失效的总阀门：

1. **全保留快道**：`PA.areAllPreserved()` → false（:57-58）；
2. **proxy 自己不保 → 清空 FAM**（:68-72）：`InnerAM->clear()`，函数粒度的缓存连锅端；
3. **逐函数检查 outer invalidations**（:80-111）：对每个函数查 `ModuleAnalysisManagerFunctionProxy`（outer proxy），它记录着"这个函数里的某些分析曾查询过外层 module 分析的哪些结果"——若那个外层分析这次被废了（`Inv.invalidate(OuterAnalysisID, M, PA)`，:92），就把依赖它的内层分析 ID 逐个 `FunctionPA->abandon(InnerAnalysisID)`（:96），再用这把定制的 PA 手术刀 `InnerAM->invalidate(F, *FunctionPA)`（:103）。

注释（PassManager.cpp:83-85）点破这是"deferred invalidation"——函数分析对外层的依赖在查询时登记（registerOuterAnalysisInvalidation），在失效事件发生时兑现。CGSCC 层的同构实现在 CGSCCPassManager.cpp:622-652（SCC 粒度）与 :723-744（Function 粒度，:740 是 abandon 点）。

### 4.3 CGSCCToFunctionPassAdaptor 的特殊性（CGSCCPassManager.cpp:514-584）

与 ModuleToFunction 的骨架相同（逐函数 run → FAM.invalidate → intersect），但多了**调用图实时维护**段（:561-570）：

```cpp
auto PAC = PA.getChecker<LazyCallGraphAnalysis>();
if (!PAC.preserved() && !PAC.preservedSet<AllAnalysesOn<Module>>()) {   // :564-565
  CurrentC = &updateCGAndAnalysisManagerForFunctionPass(CG, *CurrentC, *N,
                                                        AM, UR, FAM); // :566-567
  ...
}
```

含义：**只要聚合 PA 没保住 LazyCallGraphAnalysis**，每个函数 pass 跑完都要立刻走一遍 CG 更新——可能把当前 SCC 拆小（删边）、并触发 §1.4 表格里那些新 SCC 的函数分析清理（updateNewSCCFunctionAnalyses，CGSCCPassManager.cpp:776-806，其 abandon 在 :800）。收尾三连（:577-581）：

```cpp
PA.preserveSet<AllAnalysesOn<Function>>();      // :577
PA.preserve<FunctionAnalysisManagerCGSCCProxy>();// :578
PA.preserve<LazyCallGraphAnalysis>();           // :581 我们一路上已经维护过 CG 了
```

最后一个 preserve 是 CGSCC adaptor 独有的承诺："调用图分析在 pass 运行期间被我们增量维护了，所以它算保留"。**NoRerun 优化**（:541-542）也在这里：查 `ShouldNotRunFunctionPassesAnalysis` 缓存，命中就跳过——这是 SCC 反复访问时的短路机制。

---

## 5. AMDGPU 侧的 PA 风格

### 5.1 IR pass 的 PA 返回值实测（8 个代表）

| Pass | 文件:行号 | 返回 PA |
|---|---|---|
| AMDGPUPromoteAllocaPass | AMDGPUPromoteAlloca.cpp:250-261 | 未变 all()；变了 `none() + preserveSet<CFGAnalyses>()` |
| AMDGPUPromoteAllocaToVectorPass | AMDGPUPromoteAlloca.cpp:263-274 | 同上 |
| AMDGPULowerModuleLDSPass | AMDGPULowerModuleLDSPass.cpp:1596-1599 | 三元式：`changed ? none() : all()` |
| AMDGPUAlwaysInlinePass | AMDGPUAlwaysInlinePass.cpp:168-171 | `Changed ? none() : all()` |
| AMDGPUAtomicOptimizerPass | AMDGPUAtomicOptimizer.cpp:135-152 | `none() + preserve<DominatorTreeAnalysis>()`（用 DomTreeUpdater 维护了 DT，:139-140） |
| AMDGPUCodeGenPreparePass | AMDGPUCodeGenPrepare.cpp:2280-2295 | 未变 all()；变了 `none()`，若没动控制流再补 `preserveSet<CFGAnalyses>()`（:2292-2293） |
| AMDGPUAnnotateUniformValues | AMDGPUAnnotateUniformValues.cpp:95-101 | 未变 all()；变了 `none() + preserveSet<CFGAnalyses>()`，注释（:99）自嘲"TODO: Should preserve nearly everything" |
| AMDGPULowerKernelAttributes | AMDGPULowerKernelAttributes.cpp:510-521 | `none().preserveSet<CFGAnalyses>()` |

风格归纳：

1. **"未变 all / 变了 none" 的保守基底**是主流（CtorDtorLowering.cpp:171-174、AMDGPULibCalls.cpp:2063-2065 等一大批都是这个三元式）；
2. **保 CFGAnalyses 集合**是精细化的第一档（PromoteAlloca、AnnotateUniform、LowerKernelAttributes、CodeGenPrepare）——改动只加指令不动块结构时用；
3. **点名保具体分析**只有维护过该分析的 pass 敢用（AtomicOptimizer 用 DomTreeUpdater 增量维护了 DT，才 preserve<DominatorTreeAnalysis>，AMDGPUAtomicOptimizer.cpp:139-140, :150）；
4. **Attributor 系**（AMDGPUAttributor.cpp:1641-1658 Module 版、:1661-1684 CGSCC 版）同样是 `none/all` 二元。

### 5.2 MachineFunction pass 的 PA 机制（纠正任务预设）

当前树里 machine function pass **也返回 PA**——`PassManager<MachineFunction>::run`（llvm/lib/CodeGen/MachinePassManager.cpp:143-160）与 IR 主循环同构（逐 pass invalidate + intersect + 收尾 preserveSet<AllAnalysesOn<MachineFunction>>，:158）。真正的机制差异有三点：

1. **基线 PA 由 `getMachineFunctionPassPreservedAnalyses()` 给出**（MachinePassManager.cpp:162-169）：`none() + preserveSet<AllAnalysesOn<Module>>() + preserveSet<AllAnalysesOn<Function>>()`——注释（:164-165）："Machine function passes are not allowed to modify the LLVM representation, therefore we should preserve all IR analyses"。即 **MIR 层对 IR 层的失效契约是"天生全保"**，machine pass 只需申报自己对 machine 分析的影响。AMDGPU 的 machine pass 普遍以它为基底再叠加，如 SIInsertWaitcntsPass（SIInsertWaitcnts.cpp:3461-3476）：
   ```cpp
   if (!SIInsertWaitcnts(MLI, PDT, AA, MF).run())
     return PreservedAnalyses::all();
   return getMachineFunctionPassPreservedAnalyses()
       .preserveSet<CFGAnalyses>()
       .preserve<AAManager>();              // :3473-3475
   ```
   同型还有 AMDGPUInsertDelayAlu.cpp:547-548、AMDGPULowerVGPREncoding.cpp:687-689、AMDGPUPreLegalizerCombiner.cpp:327-329、AMDGPUGlobalISelDivergenceLowering.cpp:361-363。
2. **文件头设计注释**（MachinePassManager.h:10-18）说明：codegen 流水线只有 machine function 一层容器，"no proxy classes to handle cross-IR-unit invalidation"——跨层靠 `FunctionToMachineFunctionPassAdaptor`（MachinePassManager.cpp:111-134）单向进入，MFAM 的结果生命周期独立于 FAM。
3. **`FunctionAnalysisManagerMachineFunctionProxy::Result::invalidate` 直接返回 false**（MachinePassManager.cpp:37-43）——"MachineFunction passes should not invalidate Function analyses."（:40 注释），机器层**单向不可回污** IR 层分析，这也是 §5.1 基线 PA 全保 IR 的镜像。

另：legacy 的 `MachineFunctionPass`（include/llvm/CodeGen/MachineFunctionPass.h:31-79）走 `getAnalysisUsage`/`AU.setPreservesCFG()` 老契约（:49-55 注释），runOnMachineFunction 返回 bool（:47），与新 PM 的 PA 体系并存于 AMDGPU（R600 全家 + 部分 SI pass 的 Legacy 变体）。

---

## 6. PA 的打印与调试

### 6.1 PreservedAnalyses 没有 print/dump

亲验：llvm/include/llvm/IR/Analysis.h:112-327 的 PreservedAnalyses 类**没有任何 print/dump/operator<<**（grep 全树 "PreservedAnalyses::print"、"operator<<(raw_ostream, ...PreservedAnalyses" 均无命中）。PA 是**纯内部判据**，不面向用户序列化；想观察它只能通过插桩的间接信号（§6.2、§6.3）。这与 legacy PM 的 `AU.print()` 形成对比。

### 6.2 -debug-pass-manager 的失效文本（StandardInstrumentations.cpp:1190-1206）

DebugPassInstrumentation 注册的三个回调给出观察 PA 效果的全部文本：

- "Running analysis: X on Y"（:1192，before-analysis 回调）；
- **"Invalidating analysis: X on Y"（:1198-1202，analysis-invalidated 回调）**——AM 真正删除缓存结果时触发（源头在 PassManagerImpl.h:220-221 的 `PI->runAnalysisInvalidated`）；
- "Clearing all analysis results for: Y"（:1203-1205，analyses-cleared 回调）。

### 6.3 PA 契约的看门狗：PreservedCFGCheckerInstrumentation（StandardInstrumentations.cpp:1309-1488）

注册点（StandardInstrumentations.cpp:2563-2565）：只要 MAM 存在就调 `PreservedCFGChecker.registerCallbacks(PIC, *MAM)`——**但 registerCallbacks 第一行有总闸**：`if (!VerifyAnalysisInvalidation) return;`（:1391-1393）。开关 `-verify-analysis-invalidation`（:52-59）仅 **EXPENSIVE_CHECKS 构建默认 ON**（`#ifdef` 选择 `cl::init(true/false)`），普通 Debug 构建默认 OFF、可显式开旗。本仓库 build-debug 的 `LLVM_ENABLE_EXPENSIVE_CHECKS:BOOL=OFF`（CMakeCache.txt:843）。覆盖面也有限：只验函数/模块 StructuralHash 与 CFG 快照的"变了没申报"，**不验证任何具体分析结果的内容正确性**。机制：

- **PreservedFunctionHashAnalysis**（:1336-1351）：pass 前对 Function 做 StructuralHash 存进 FAM（:1409, :1417）；after-pass 回调里重算对比，**变了但没失效分析**→ `report_fatal_error("Function @X changed by Y without invalidating analyses")`（:1453-1456）；module 级同型（:1483-1486）；
- **PreservedCFGCheckerAnalysis**（:1326-1334）：pass 前存 CFG 图（CFG 类在 :1209-1223，含可选的 BB 生命周期跟踪 BBGuard）；after-pass 对比图不等且 PA 声称保 CFGAnalyses → "Error: X does not invalidate CFG analyses but CFG changes detected in function @Y"（:1465-1471）+ `report_fatal_error`；
- **这两个 checker 分析自身也参与失效协议**：`CFG::invalidate`（:1370 起）按 PA 决定快照是否作废——**声称全保留的 pass 会被用旧快照对比**，这正是抓 §3 中 LoopFlatten/LowerMatrixIntrinsics 类 bug 的机制。

即：**启用 `-verify-analysis-invalidation` 后（EXPENSIVE_CHECKS 构建默认启用；普通 Debug 构建默认关闭），错误的结构/CFG 保留声明的代价是 opt 直接 fatal error**，不是静默脏读——但普通 Debug 构建不开旗时仍可能静默脏读，且该检查不覆盖"声明保留了某分析、实际内容已坏"的反向谎言。§2.3 的结论（无 verify-then-abandon 模式）由此得到解释——契约违背被设计为开发期（CI 用 EXPENSIVE_CHECKS 配置）硬错误。

### 6.4 -print-changed 的 PA 相关标记

ChangeReporter 的文本标记（StandardInstrumentations.cpp）：

- `*** IR Pass {0} invalidated ***`（:507，TextChangeReporter::handleInvalidated）——**只在 VerboseMode 打**（:462-463 `if (VerboseMode) handleInvalidated(PassID)`），触发时机是 after-pass-invalidated 回调（IR 单元本身没了，:479-482 注册），例如函数被删时它上面的 FPM 结果失效；
- `*** IR Dump After {0} on {1} omitted because no change ***`（:501）——verbose 模式专属；
- quiet 模式（`-print-changed=quiet`）**不输出任何 invalidated/ignored 标记**，只在真有 IR 变化时打 `*** IR Dump After {0} on {1} ***`（实测 §7.3）；
- PrintIRInstrumentation（-print-after 系列）另有 `; *** IR Dump After {0} on {1} (invalidated) ***`（:985-986）——pass 后 IR 已失效时的 banner。

---

## 7. 动态验证（build-debug/bin/opt 实测，2026-09-30）

### 7.1 require/invalidate/require：domtree 重建计数

输入 scratch/pa-test.ll（一个带分支的平凡函数）。命令：

```bash
opt -passes='function(require<domtree>,invalidate<domtree>,require<domtree>)' \
    -disable-output scratch/pa-test.ll -debug-pass-manager 2>&1
```

结果（完整输出存 scratch/pa-debug-trace.txt）：

```text
Running analysis: InnerAnalysisManagerProxy<FunctionAnalysisManager, Module> on [module]
Running pass: RequireAnalysisPass<...DominatorTreeAnalysis...> on f (4 instructions)
Running analysis: DominatorTreeAnalysis on f                     ← 第 1 次构建
Running pass: InvalidateAnalysisPass<...DominatorTreeAnalysis> on f (4 instructions)
Invalidating analysis: DominatorTreeAnalysis on f                ← abandon 生效
Running pass: RequireAnalysisPass<...> on f (4 instructions)
Running analysis: DominatorTreeAnalysis on f                     ← 第 2 次构建（重建）
Invalidating analysis: DominatorTreeAnalysis on f                ← FPM 收尾清场
Running pass: VerifierPass on [module]
Running analysis: VerifierAnalysis on [module]
```

`Running analysis: DominatorTreeAnalysis` 出现 **2 次**（grep -c 实测）——invalidate 确实杀掉了缓存，第二个 require 触发重建。

对照组 `-passes='function(require<domtree>,require<domtree>)'`：**1 次**——require 返回 all()（PassManager.h:936），不失效任何东西，第二个 require 直接命中缓存。

附带观察：第一次 "Invalidating analysis" 由 InvalidateAnalysisPass 的 abandon 触发（PassManager.h:960 → AM.invalidate 走 PassManagerImpl.h:220-221 通知插桩）；**第二次 "Invalidating" 是 FPM 跑完后 adaptor 或外层 VerifierPass 的 PA 传播清掉残留**——require 虽返回 all()，但整个 function adaptor 收尾时 AM 对该函数的缓存按外层（module 层 VerifierPass 返回的 PA）处理，domtree 不属于 module 层保留集，故被清。这印证了 §4.1 的 cross-IRUnit 传染逻辑。

### 7.2 -print-changed=quiet 的 PA 标记观察

```bash
opt -passes='function(instcombine)' -disable-output scratch/pa-test2.ll -print-changed=quiet
```

输出仅 `*** IR Dump After InstCombinePass on g ***`——quiet 模式只在真变化时打 banner，**不打任何 invalidated/ignored 标记**（与 §6.4 源码判定一致：handleInvalidated 被 `if (VerboseMode)` 门控，StandardInstrumentations.cpp:462-463）。

对照 `-print-changed`（verbose）在 `function(invalidate<domtree>)` 上的输出含 `*** IR Pass InvalidateAnalysisPass<llvm::DominatorTreeAnalysis> on f ignored ***`（invalidate 不改 IR，被识别为 ignored），仍无 "invalidated" 字样——因为函数本身没被删。**"*** IR Pass {0} invalidated ***" 只在 IR 单元消亡路径出现**（StandardInstrumentations.cpp:507），日常 PA 调试要靠 §6.2 的 "Invalidating analysis:" 行。

---

## 8. 自查表

| 断言 | 出处 | 核实方式 |
|---|---|---|
| AnalysisResultModel 双路径 lambda | PassManagerInternal.h:248-257 | Read |
| ResultHasInvalidateMethod SFINAE | PassManagerInternal.h:195-227 | Read |
| AnalysisResultConcept 函数指针 | PassManagerInternal.h:152-191 | Read |
| DominatorTree::invalidate | llvm/lib/IR/Dominators.cpp:71-78 | Read |
| MemorySSA invalidate 递归 | llvm/lib/Analysis/MemorySSA.cpp:2376-2383 | Read |
| BFI invalidate | llvm/lib/Analysis/BlockFrequencyInfo.cpp:175-182 | Read |
| GlobalsAA preservedWhenStateless | llvm/lib/Analysis/GlobalsModRef.cpp:825-831 | Read |
| Invalidator 类与 DFS | PassManager.h:318-394 | Read |
| AM::invalidate 主算法 | PassManagerImpl.h:168-230 | Read |
| abandon 计数 22+3 | grep -c 实测 | Bash |
| 10+ 代表 abandon 行号 | 各文件 | grep |
| MSan abandon 注释 | MemorySanitizer.cpp:810-815 | Read |
| 4 个历史 bug commit | git log -1 --format=%B | Bash |
| ModuleToFunctionPassAdaptor::run | llvm/lib/IR/PassManager.cpp:128-170 | Read |
| FAModuleProxy invalidate | llvm/lib/IR/PassManager.cpp:52-115 | Read |
| CGSCCToFunctionPassAdaptor::run | CGSCCPassManager.cpp:514-584 | Read |
| updateNewSCCFunctionAnalyses | CGSCCPassManager.cpp:776-806 | Read |
| 8 个 AMDGPU pass PA | 各文件:行号见表 | Read+grep |
| getMachineFunctionPassPreservedAnalyses | MachinePassManager.cpp:162-169 | Read |
| FAMachineFunctionProxy invalidate=false | MachinePassManager.cpp:37-43 | Read |
| PA 无 print/dump | grep 全树无命中 | Bash |
| debug-pass-manager 三回调 | StandardInstrumentations.cpp:1190-1206 | Read |
| PreservedCFGChecker 机制 | StandardInstrumentations.cpp:1309-1488 | Read |
| 注册点 if (MAM) | StandardInstrumentations.cpp:2565-2566 | Read |
| handleInvalidated Verbose 门控 | StandardInstrumentations.cpp:455-465, :506-508 | Read |
| "(invalidated)" banner | StandardInstrumentations.cpp:985-986 | Read |
| require/invalidate 2:1 计数 | opt 实测 | Bash |
| print-changed=quiet 行为 | opt 实测 | Bash |
| runWithPreservedAnalysis 不存在 | grep 全树无命中 | Bash（待验证：或为旧版符号） |
