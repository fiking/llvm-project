# 四 IRUnit 适配器:Module→CGSCC→Function→Loop(§5)

> 基准:llvm-project main @ `3eda2aebadd4`(2026-09-28)。
> 所有引用均为本仓库 `文件:行号`,经 read/grep 实测核对;动态验证用 `build-debug`。
> 行号锚点:`llvm/include/llvm/IR/PassManager.h`(下称 PM.h,986 行)、`llvm/lib/IR/PassManager.cpp`(下称 PM.cpp,186 行)、`llvm/include/llvm/Analysis/CGSCCPassManager.h`(下称 CGPCM.h,581 行)、`llvm/lib/Analysis/CGSCCPassManager.cpp`(下称 CGPCM.cpp,1196 行)、`llvm/include/llvm/Transforms/Scalar/LoopPassManager.h`(下称 LPM.h,480 行)、`llvm/lib/Transforms/Scalar/LoopPassManager.cpp`(下称 LPM.cpp,353 行)、`llvm/include/llvm/Analysis/LoopAnalysisManager.h`(下称 LAM.h)。
> 分工边界:adaptor 内 PA 的变换语义见 04-preserved-analyses.md;Inner/Outer proxy 的 invalidate 实现见 03-analysis-manager.md;主循环 `run()` 的 invalidate 算法见 02/04 两份笔记。本笔记只展开"adaptor 自身的结构性逻辑"。

---

## 5.0 适配器家族全景

新 PM 的 IRUnit 有五个层次:`Module` → `LazyCallGraph::SCC` → `Function` → `Loop` →(`MachineFunction` 经 MIR 单独存在,见 §5.7)。每两个相邻层之间有一个**手写 adaptor 类**,负责:

1. 从外层 AM 拿到内层 AM(经 `InnerAnalysisManagerProxy`);
2. 遍历内层 IRUnit 集合(模块里所有 function、SCC 里所有 node、function 里所有 loop);
3. 调用被包装的 `PassConcept` 的 `run()`;
4. 处理"被 pass 改了图"的更新(worklist、重跑、invalidate);
5. 把自己的 PA 聚合成"外层视角"的语义。

### 5.0.1 四大 adaptor 一览表

| adaptor | 包装 | 定义 | run() 入口 | 构造选项 | 模板参数 (PassConceptT) |
|---|---|---|---|---|---|
| `ModuleToFunctionPassAdaptor` | module → function | PM.h:878 | PM.cpp:128 | `EagerlyInvalidate` (PM.h:884-885, 895) | `PassConcept<Function, FAM>` (PM.h:881) |
| `ModuleToPostOrderCGSCCPassAdaptor` | module → SCC | CGPCM.h:315 | CGPCM.cpp:142 | 无 | `PassConcept<SCC, CGAM, LCG&, CGSCCUpdateResult&>` (CGPCM.h:318-320) |
| `CGSCCToFunctionPassAdaptor` | SCC → function | CGPCM.h:441 | CGPCM.cpp:514 | `EagerlyInvalidate` + `NoRerun` (CGPCM.h:447-449) | `PassConcept<Function, FAM>` (CGPCM.h:444) |
| `FunctionToLoopPassAdaptor` | function → loop | LPM.h:390 | LPM.cpp:193 | `UseMemorySSA` + `LoopNestMode` (LPM.h:397-401) | `PassConcept<Loop, LAM, LoopStandardAnalysisResults&, LPMUpdater&>` (LPM.h:393-395) |

配套工厂函数(`create*PassAdaptor`):

- `createModuleToFunctionPassAdaptor` (PM.h:900-908),`EagerlyInvalidate` 默认 false
- `createModuleToPostOrderCGSCCPassAdaptor` (CGPCM.h:355-362)
- `createCGSCCToFunctionPassAdaptor` (CGPCM.h:496-505),`EagerlyInvalidate`/`NoRerun` 默认均 false
- `createFunctionToLoopPassAdaptor` (LPM.h:430-464):重载两版,一版根据 pass 类型推导 loop/loop-nest 模式(`is_detected<HasRunOnLoopT>`),一版特化给 `LoopPassManager`

**关键差异**:`ModuleToFunctionPassAdaptor` 与 `CGSCCToFunctionPassAdaptor` 把同一个 `PassConcept<Function, FAM>` 作为成员——因为两端 function pass 的签名一致,只是触发上下文不同。其它两个 adaptor 的 `PassConcept` 携带额外的 ExtraArgs(`LazyCallGraph &`、`CGSCCUpdateResult &`、`LoopStandardAnalysisResults &`、`LPMUpdater &`),这正是 pass 在跨层调用时拿到的"图更新通道"。

### 5.0.2 类型擦除层的复用

四个 adaptor 都继承 `RequiredPassInfoMixin<>`(module→function 在 PM.h:879、module→cgscc 在 CGPCM.h:316、cgscc→function 在 CGPCM.h:442、function→loop 在 LPM.h:391),都通过 `PassConcept::unique_ptr` 存储被包装 pass。**adaptor 本身不是模板**——它的模板性被推到 `create*PassAdaptor` 工厂里(用 `PassModelT` 包装任意 PassT 然后类型擦除),所以 adaptor 类型对外只有一个,便于放进 PassRegistry。

唯一带状态字段的:

| adaptor | 状态字段 | 行号 |
|---|---|---|
| Module→Function | `Pass` + `EagerlyInvalidate` | PM.h:894-895 |
| Module→CGSCC | `Pass`(无选项) | CGPCM.h:350 |
| CGSCC→Function | `Pass` + `EagerlyInvalidate` + `NoRerun` | CGPCM.h:489-491 |
| Function→Loop | `Pass` + `LoopCanonicalizationFPM` + `UseMemorySSA` + `LoopNestMode` | LPM.h:415-420 |

注意 **`FunctionToLoopPassAdaptor` 内嵌一个 `FunctionPassManager LoopCanonicalizationFPM`**——这是其它三个 adaptor 没有的独特结构,详见 §5.3。

---

## 5.1 ModuleToFunctionPassAdaptor

### 5.1.1 run() 结构(PM.cpp:128-170)

```cpp
PreservedAnalyses ModuleToFunctionPassAdaptor::run(Module &M,
                                                   ModuleAnalysisManager &AM) {
  FunctionAnalysisManager &FAM =
      AM.getResult<FunctionAnalysisManagerModuleProxy>(M).getManager();   // :130-131
  PassInstrumentation PI = AM.getResult<PassInstrumentationAnalysis>(M);  // :135
  PreservedAnalyses PA = PreservedAnalyses::all();
  for (Function &F : M) {
    if (F.isDeclaration()) continue;                                       // :139-140
    if (!PI.runBeforePass<Function>(*Pass, F)) continue;                   // :145
    PreservedAnalyses PassPA = Pass->run(F, FAM);                          // :148
    FAM.invalidate(F, EagerlyInvalidate ? PreservedAnalyses::none() : PassPA);  // :153
    PI.runAfterPass(*Pass, F, PassPA);                                     // :155
    PA.intersect(std::move(PassPA));                                       // :159
  }
  PA.preserveSet<AllAnalysesOn<Function>>();                               // :167
  PA.preserve<FunctionAnalysisManagerModuleProxy>();                       // :168
  return PA;
}
```

要点:

1. **FAM 经 proxy 获得**(:130-131),不直接拥有。这就是 03 笔记里 `InnerAnalysisManagerProxy<FAM, Module>` 的运行时。
2. **`isDeclaration()` 跳过**(:139):declaration 没有 body,不能跑 function pass。
3. **EagerlyInvalidate 分支**(:153):如果构造时指定,这里直接 `PreservedAnalyses::none()`,即不管 PassPA 是什么都强制失效当前函数的所有缓存。这是 `-passes='function<eager-inv>(...)'` 的语义,在 O2 pipeline 中被默认开启(`function<eager-inv>(...)`,见 scratch/lcg-default-o2-pipeline.txt 第 1 行单行转储中多处出现)。
4. **每个 function 后立即 invalidate FAM**(:153),但 module 层 PA 只是 `intersect`(:159)——真正的 module 层失效要等 adaptor 返回,由外层 PM 主循环驱动(PMImpl.h:67-89,见 04 笔记)。
5. **adaptor 自己 retain `AllAnalysesOn<Function>` 和 FAM proxy**(:167-168):因为它已经手动 invalidate 过 FAM 了,外层 PM 不应再做一次。这是"adaptor 自己处理内层失效"的契约。

### 5.1.2 独占访问契约

PM.h:861-877 的类注释明文规定 function pass 在 adaptor 内的契约:

> "Function passes run within this adaptor can rely on having exclusive access to the function they are run over. **They should not read or modify any other functions!** Other threads or systems may be manipulating other functions in the module..."

并附 FIXME(:865-866, :872-873)承认部分现存 pass 违反此约定。这是新 PM 把 function 级并行留给未来的关键设计——但目前(PM.cpp:138)`for (Function &F : M)` 仍是顺序遍历。

---

## 5.2 ModuleToPostOrderCGSCCPassAdaptor

这是**最复杂的一个 adaptor**(CGPCM.cpp:142-365,约 220 行),因为它要处理 LazyCallGraph 在 pass 运行时被反复改写的情况。

### 5.2.1 三层 worklist 嵌套结构

```
ModuleToPostOrderCGSCCPassAdaptor::run            (CGPCM.cpp:142)
  ├── LazyCallGraph &CG = AM.getResult<LazyCallGraphAnalysis>(M)   (:149)
  ├── CG.buildRefSCCs()                                             (:182)
  ├── for (RefSCC &RC : CG.postorder_ref_sccs())  ← 外层惰性迭代   (:183-184)
  │     RCWorklist.insert(&RC)
  │     do {
  │       RC = RCWorklist.pop_back_val()
  │       for (SCC &C : reverse(*RC)) CWorklist.insert(&C)         (:216-217)
  │       do {
  │         C = CWorklist.pop_back_val()
  │         ...
  │         do {
  │           PassPA = Pass->run(*C, CGAM, CG, UR)                  (:281)
  │           if (UR.UpdatedC) ... C = UR.UpdatedC                  (:284)
  │           ... invalidate / CrossSCCPA ...
  │         } while (UR.UpdatedC)  ← 内层:当前 SCC 被精化则重跑   (:339)
  │       } while (!CWorklist.empty())                              (:340)
  │     } while (!RCWorklist.empty())                               (:346)
```

三层循环各自的职责:

| 循环 | 行号 | 退出条件 | 重排机制 |
|---|---|---|---|
| 最外:RefSCC 遍历 | :183-184, :200 | `RCWorklist.empty()` | RefSCC 可能分裂出新 RefSCC,插回 worklist |
| 中:SCC 遍历 | :219, :340 | `CWorklist.empty()` | SCC 被分裂/合并时,新 SCC 经 `UR.CWorklist` 插回 |
| 最内:SCC 精化 | :267, :339 | `UR.UpdatedC == nullptr` | pass 改了图后,UpdatedC 指向新形态,立即重跑同一 pass |

### 5.2.2 CGSCCUpdateResult 的初始化与字段填充

UR 在 :169-175 构造:

```cpp
CGSCCUpdateResult UR = {CWorklist,
                        InvalidSCCSet,                  // :162 空 set
                        nullptr,                        // UpdatedC
                        PreservedAnalyses::all(),       // CrossSCCPA
                        InlinedInternalEdges,
                        DeadFunctions,
                        {}};                            // IndirectVHs
```

字段分两类(评审修正:原写"每个字段的所有权都在 adaptor 一侧"不确):**引用成员**——`CWorklist`/`InvalidSCCSet`/`InlinedInternalEdges`/`DeadFunctions` 指向 adaptor 的局部变量;**自有值成员**——`UpdatedC` 指针、`CrossSCCPA` 对象、`IndirectVHs` 容器由 UR 自身持有(CGPCM.h:247-303)。pass 拿到 UR 后可以**写**(`UR.UpdatedC = ...`、`UR.CWorklist.insert(...)`、`UR.DeadFunctions.push_back(...)`),adaptor 在每层循环边界读取并据此调整迭代。

字段语义详见 06-lazy-callgraph.md §6.4。

### 5.2.3 CrossSCCPA:跨 SCC 的失效通道

CGPCM.cpp:251-265 的注释解释:`CrossSCCPA` 是"跨 SCC 视角的保留集",被 SCC pass 用于声明"我虽然只跑在 SCC C 上,但我可能动到了祖先 SCC 里的 IR"。adaptor 在切换到新 SCC 时(:265)用它做一次 `CGAM.invalidate(*C, UR.CrossSCCPA)`,把"上一个 SCC 留下的痕迹"传给下一个要跑的 SCC。这是新 PM 在 CGSCC 层支持"修改祖先"的关键——普通 IRUnit PM 没有这种通道,只有 CGSCC 的"图可被 pass 改写"特性才需要。

### 5.2.4 函数死删的批处理

pass 不直接 erase function,而是把 `Function*` push 进 `UR.DeadFunctions`(CGPCM.h:293),adaptor 在整条模块的 RefSCC 遍历全部结束后(:349-351,外层 while 循环之外——评审修正:非每条 RefSCC 结束时)统一:

```cpp
CG.removeDeadFunctions(DeadFunctions);
for (Function *DeadF : DeadFunctions)
  DeadF->eraseFromParent();
```

这种"批量死删"避免在 SCC 迭代中途破坏迭代器——`LazyCallGraph::Node` 里 `isDead()`(LCG.h:336-340)的标记就是给这种"延迟删除"用的。

### 5.2.5 实测:SCC 划分与 postorder 遍历

测试用例 `PassManager-notes/scratch/lcg-mutual.ll`:`a→b→c→a` 形成 3 节点 SCC,`main` 调 `a`,`d` 通过函数指针 store 引用 `e`。

```bash
$ ./build-debug/bin/opt -p 'cgscc(no-op-cgscc)' scratch/lcg-mutual.ll \
      -disable-output -debug-pass-manager
```

输出(scratch/lcg-scc-traversal.txt):

```text
Running analysis: LazyCallGraphAnalysis on [module]
Running analysis: TargetLibraryAnalysis on a
Running analysis: TargetLibraryAnalysis on b
Running analysis: TargetLibraryAnalysis on c
Running analysis: TargetLibraryAnalysis on main
Running analysis: TargetLibraryAnalysis on d
Running analysis: TargetLibraryAnalysis on e
Running analysis: FunctionAnalysisManagerCGSCCProxy on (a, b, c)
Running pass: NoOpCGSCCPass on (a, b, c) (3 nodes)     ← 三函数在同一 SCC
Running analysis: FunctionAnalysisManagerCGSCCProxy on (main)
Running pass: NoOpCGSCCPass on (main) (1 node)         ← main 单独成 SCC
Running pass: VerifierPass on [module]
```

观察:

1. **TLI 是按 function 惰性地按需构建的**——只在 `Node::populateSlow()` 需要时算。6 个函数全跑了 TLI,因为 `LazyCallGraph` 构造时( LCG.cpp:152-203)就遍历了 module 所有 function 把它们塞进 NodeMap。
2. **(a,b,c) 是一个 SCC**,`(main)` 是另一个。`d`/`e` 没有出现在任何 SCC 的 debug 输出里,因为它们不被任何入口可达:`d` 是 internal 且没人调,`e` 仅被 `@fp` 全局引用,但 `@fp` 的 initializer 引的是 `target`(我们的 lcg-devirt.ll)而不是这里。在本用例中 `e` 是 internal 且没人 ref,所以它根本不在 entry 集合,`LazyCallGraph` 不会为它建 SCC。这与 `print-callgraph-sccs` 输出吻合(scratch/lcg-callgraph-sccs.txt):`SCC #1: c, b, a; SCC #2: main; SCC #3: e; SCC #4: external node`——`print-callgraph-sccs` 是 legacy PM 的 printer,它把所有 node 都打印,而新 PM 的 `cgscc(...)` pipeline 只走 postorder_ref_sccs。
3. **SCC 顺序**:`(a,b,c)` 先于 `(main)`。这是 postorder(底向上):被调用方先优化。

---

## 5.3 FunctionToLoopPassAdaptor:独特性与深度

四个 adaptor 中唯一**自带内嵌 FunctionPassManager** 的。

### 5.3.1 构造时强制注入 LoopSimplify + LCSSA(LPM.h:397-404)

```cpp
explicit FunctionToLoopPassAdaptor(PassConceptT::unique_ptr Pass,
                                   bool UseMemorySSA = false,
                                   bool LoopNestMode = false)
    : Pass(std::move(Pass)), UseMemorySSA(UseMemorySSA),
      LoopNestMode(LoopNestMode) {
  LoopCanonicalizationFPM.addPass(LoopSimplifyPass());   // :402
  LoopCanonicalizationFPM.addPass(LCSSAPass());          // :403
}
```

**任何 loop(...) 或 loop-mssa(...) pipeline 在跑用户 pass 前,都会先跑一遍 LoopSimplifyPass + LCSSAPass**。这是 LPM.h 头注释(LPM.h:14-27)所列 5 条不变量里的第 1、2 条:"Loops are, where possible, in simplified form" 和 "Loops are *always* in LCSSA form"。

### 5.3.2 run() 的两阶段结构(LPM.cpp:193-341)

```cpp
PreservedAnalyses FunctionToLoopPassAdaptor::run(Function &F,
                                                 FunctionAnalysisManager &AM) {
  // Stage 0: 提前 bail
  if (AM.getResult<LoopAnalysis>(F).empty()) return PA;            // :198-199

  // Stage 1: canonicalization(在 function 层跑 mini-PM)
  PassInstrumentation PI = AM.getResult<PassInstrumentationAnalysis>(F);
  if (PI.runBeforePass<Function>(LoopCanonicalizationFPM, F)) {    // :209
    PA = LoopCanonicalizationFPM.run(F, AM);                       // :210
    PI.runAfterPass<Function>(LoopCanonicalizationFPM, F, PA);     // :211
  }

  // Stage 2: 收集 LoopStandardAnalysisResults(强制注入的 7 项 + 1 可选)
  LoopInfo &LI = AM.getResult<LoopAnalysis>(F);                                  // :215
  MemorySSA *MSSA =
      UseMemorySSA ? (&AM.getResult<MemorySSAAnalysis>(F).getMSSA()) : nullptr; // :218-219
  LoopStandardAnalysisResults LAR = {AM.getResult<AAManager>(F),                // :220
                                     AM.getResult<AssumptionAnalysis>(F),       // :221
                                     AM.getResult<DominatorTreeAnalysis>(F),    // :222
                                     AM.getResult<LoopAnalysis>(F),             // :223
                                     AM.getResult<ScalarEvolutionAnalysis>(F),  // :224
                                     AM.getResult<TargetLibraryAnalysis>(F),    // :225
                                     AM.getResult<TargetIRAnalysis>(F),         // :226
                                     MSSA};                                     // :227

  // Stage 3: 拿到 LAM 并构造 worklist + LPMUpdater
  auto &LAMFP = AM.getResult<LoopAnalysisManagerFunctionProxy>(F);              // :234
  if (UseMemorySSA) LAMFP.markMSSAUsed();                                       // :235-236
  LoopAnalysisManager &LAM = LAMFP.getManager();                                // :237

  SmallPriorityWorklist<Loop *, 4> Worklist;                                    // :240
  LPMUpdater Updater(Worklist, LAM, LoopNestMode);                              // :244

  if (!LoopNestMode) {
    appendLoopsToWorklist(LI, Worklist);                                        // :249
  } else {
    for (Loop *L : LI) Worklist.insert(L);                                      // :251-252
  }

  // Stage 4: 主循环
  do {
    Loop *L = Worklist.pop_back_val();                                          // :270
    Updater.CurrentL = L;                                                       // :275
    Updater.SkipCurrentLoop = false;                                            // :276
    ...
    if (!PI.runBeforePass<Loop>(*Pass, *L)) continue;                          // :285
    PreservedAnalyses PassPA = Pass->run(*L, LAM, LAR, Updater);                // :288

    if (LAR.MSSA && !PassPA.getChecker<MemorySSAAnalysis>().preserved())
      reportFatalUsageError("Loop pass manager using MemorySSA contains a pass "
                            "that does not preserve MemorySSA");                // :296-298

    if (!Updater.skipCurrentLoop())
      LAM.invalidate(*L, PassPA);                                               // :317
    PA.intersect(std::move(PassPA));                                            // :321
  } while (!Worklist.empty());                                                  // :322

  // Stage 5: 保留集
  PA.preserveSet<AllAnalysesOn<Loop>>();                                        // :332
  PA.preserve<LoopAnalysisManagerFunctionProxy>();                              // :333
  PA.preserve<DominatorTreeAnalysis>();                                         // :335
  PA.preserve<LoopAnalysis>();                                                  // :336
  PA.preserve<ScalarEvolutionAnalysis>();                                       // :337
  if (UseMemorySSA) PA.preserve<MemorySSAAnalysis>();                           // :338-339
  return PA;
}
```

### 5.3.3 LoopStandardAnalysisResults:七项强制注入

`LoopStandardAnalysisResults` 定义在 `llvm/include/llvm/Analysis/LoopAnalysisManager.h:52-61`:

```cpp
struct LoopStandardAnalysisResults {
  AAResults &AA;
  AssumptionCache &AC;
  DominatorTree &DT;
  LoopInfo &LI;
  ScalarEvolution &SE;
  TargetLibraryInfo &TLI;
  TargetTransformInfo &TTI;
  MemorySSA *MSSA;            // 仅 UseMemorySSA=true 时非空
};
```

**7 项(AA、AC、DT、LI、SE、TLI、TTI)+ 1 可选(MSSA)**,这正是 LPM.h:14-27 头注释所列"loop pass 可以免费使用的分析集"。adaptor 在 LPM.cpp:220-227 用 braced-init-list 一次性把 FAM 的 7 个 `getResult<>` 拉齐——**每个 loop pass 不再自己 require 这些,直接经 `AR` 参数拿**。

Pass 的签名:`run(Loop &L, LoopAnalysisManager &AM, LoopStandardAnalysisResults &AR, LPMUpdater &U)`(LPM.h:60-63 的 `HasRunOnLoopT` detector 揭示)。**Loop pass 通过 `AM` 取的是自己专属的 loop analysis(在 LAM 缓存),通过 `AR` 取的是 function 级分析的引用**——两个 AM 不混。

### 5.3.4 SSA/LCSSA 的"构造与还原"

FunctionToLoopPassAdaptor 只做"构造"(stage 1 的 LoopSimplify+LCSSA),**不做"还原"**——离开 loop(...) 后,LCSSA 形式可能被破坏,但 PM 不主动退出 LCSSA。LCSSA 的"还原"由后续 function pass 按需触发(例如某些 pass 内部要 rewrite SSA 时自行 form LCSSA)。LPM.cpp:296-298 的 fatal 检查只覆盖 MemorySSA——**LAR 七项的"必须保持有效"是契约级的,不是运行时检查**(在 NDEBUG 下,LPM.cpp:300-310 还有 DT/LI/SE/MSSA 的 verify 调用,在 Debug 构建下生效)。

NDEBUG 区块 LPM.cpp:255-267 还注册了一个 before-pass 回调,**在每个 loop pass 运行前验证 `L->isRecursivelyLCSSAForm(LAR.DT, LI)`**——即 LCSSA 的"持续满足"由 instrumentation 在 Debug 构建下检查,违反就 assert。

### 5.3.5 updateSSA 的角色

`updateSSA` 本身**不在 FunctionToLoopPassAdaptor 里**——adaptor 不主动更新 SSA。改名:LoopSimplifyPass 会调 `formDedicatedExitBlocks` 等(LPM.h:46-48 列的 `LCSSA.h`/`LoopSimplify.h`);如果 loop pass 自己改 SSA(比如 LoopUnroll),它必须返回正确的 PA,让 FAM 知道哪些分析(尤其 DominatorTree 和 ScalarEvolution)需要 invalidate。

`LAR.SE`(ScalarEvolution)是 loop pass 的重度依赖——LPM.cpp:336 显示 adaptor 显式 preserve SE,意味着"如果某个 loop pass 不 preserve SE,SE 会被该 loop pass 之后的 invalidate 处理,而不是 adaptor 兜底"。

### 5.3.6 实测:双层嵌套循环的执行顺序与缓存命中

测试用例 `scratch/adapt-nested-loops.ll`:外层 `outer.header` 含两个并列内层循环 `inner1.header` 和 `inner2.header`。

```bash
$ ./build-debug/bin/opt -p 'function(loop(no-op-loop))' \
      scratch/adapt-nested-loops.ll -disable-output -debug-pass-manager
```

输出(scratch/adapt-loop-order.txt,节选):

```text
Running analysis: LoopAnalysis on nested
Running pass: LoopSimplifyPass on nested (26 instructions)
Running analysis: DominatorTreeAnalysis on nested
Running analysis: AssumptionAnalysis on nested
Running analysis: TargetIRAnalysis on nested
Running pass: LCSSAPass on nested (28 instructions)            ← 26→28,LCSSA 加了 phi
Running analysis: AAManager on nested
Running analysis: TargetLibraryAnalysis on nested
Running analysis: BasicAA on nested
Running analysis: ScopedNoAliasAA on nested
Running analysis: TypeBasedAA on nested
Running analysis: OuterAnalysisManagerProxy<ModuleAnalysisManager, Function> on nested
Running analysis: ScalarEvolutionAnalysis on nested
Running analysis: InnerAnalysisManagerProxy<LoopAnalysisManager, Function> on nested
Running pass: NoOpLoopPass on loop %inner1.header in function nested  ← 最内层先
Running pass: NoOpLoopPass on loop %inner2.header in function nested  ← 并列内层次之
Running pass: NoOpLoopPass on loop %outer.header in function nested   ← 外层最后
```

观察:

1. **执行顺序**:`inner1 → inner2 → outer`——内层先于外层(postorder),同层按声明顺序。这与 LPM.h:23-27 头注释"all inner loops are processed before passes run over outer loops"一致。
2. **顺序的机制**:`appendLoopsToWorklist`(`llvm/lib/Transforms/Utils/LoopUtils.cpp:2083-2086`)调 `appendReversedLoopsToWorklist`(:2045-2067),后者用 preorder DFS 把 outer→inner1→inner2 反转成 inner1→inner2→outer 进 worklist;然后 worklist 是 `SmallPriorityWorklist` 的 LIFO,pop_back_val 顺序正好是内层先。
3. **LCSSA 的副作用**:LCSSAPass 把指令数从 26 改为 28(为每个跨 loop 的 use 插入 phi),然后才进 loop pipeline——证实 §5.3.1 的强制注入。

**缓存命中的实测**(scratch/adapt-loop-two-adaptors.txt):跑 `function(loop(no-op-loop),loop(no-op-loop))`:

```text
[第 1 个 loop(...) 段]
Running analysis: LoopAnalysis on nested
Running pass: LoopSimplifyPass on nested (26 instructions)
... 7 项分析全部跑一次 ...
Running pass: LCSSAPass on nested (28 instructions)
...
Running pass: NoOpLoopPass on loop %inner1.header ...
Running pass: NoOpLoopPass on loop %inner2.header ...
Running pass: NoOpLoopPass on loop %outer.header ...
[第 2 个 loop(...) 段]
Running pass: LoopSimplifyPass on nested (29 instructions)     ← 重跑(第 1 个 LCSSA 的 PA 没保留它)
Running pass: LCSSAPass on nested (29 instructions)            ← 重跑
Running pass: NoOpLoopPass on loop %inner1.header ...          ← 但 DT/AA/SE/AC 都没重算!
Running pass: NoOpLoopPass on loop %inner2.header ...
Running pass: NoOpLoopPass on loop %outer.header ...
```

**关键发现**:第 2 个 loop(...) 仍跑了 LoopSimplify+LCSSA(因为它们的 PA 不互相保留),但 **DT/AA/SE/AC/TLI/TTI 全部命中缓存**——这正是 LoopStandardAnalysisResults 的设计红利:在 loop pipeline 内,function 级分析是稳定的,adaptor 直接复用。

---

## 5.4 CGSCCToFunctionPassAdaptor

### 5.4.1 run() 结构(CGPCM.cpp:514-584)

```cpp
PreservedAnalyses CGSCCToFunctionPassAdaptor::run(LazyCallGraph::SCC &C,
                                                  CGSCCAnalysisManager &AM,
                                                  LazyCallGraph &CG,
                                                  CGSCCUpdateResult &UR) {
  FunctionAnalysisManager &FAM =
      AM.getResult<FunctionAnalysisManagerCGSCCProxy>(C, CG).getManager();   // :519-520
  SmallVector<LazyCallGraph::Node *, 4> Nodes(llvm::make_pointer_range(C)); // :522
  LazyCallGraph::SCC *CurrentC = &C;                                          // :527

  for (LazyCallGraph::Node *N : Nodes) {                                     // :532
    if (CG.lookupSCC(*N) != CurrentC) continue;                              // :536-537
    Function &F = N->getFunction();

    if (NoRerun && FAM.getCachedResult<ShouldNotRunFunctionPassesAnalysis>(F))
      continue;                                                              // :541-542

    PassInstrumentation PI = FAM.getResult<PassInstrumentationAnalysis>(F);
    if (!PI.runBeforePass<Function>(*Pass, F)) continue;

    PreservedAnalyses PassPA = Pass->run(F, FAM);                            // :548
    FAM.invalidate(F, EagerlyInvalidate ? PreservedAnalyses::none() : PassPA); // :553
    PI.runAfterPass<Function>(*Pass, F, PassPA);
    PA.intersect(std::move(PassPA));

    auto PAC = PA.getChecker<LazyCallGraphAnalysis>();
    if (!PAC.preserved() && !PAC.preservedSet<AllAnalysesOn<Module>>()) {    // :564-565
      CurrentC = &updateCGAndAnalysisManagerForFunctionPass(CG, *CurrentC, *N,
                                                            AM, UR, FAM);    // :566-567
    }
  }

  PA.preserveSet<AllAnalysesOn<Function>>();                                 // :577
  PA.preserve<FunctionAnalysisManagerCGSCCProxy>();                          // :578
  PA.preserve<LazyCallGraphAnalysis>();                                      // :581
  return PA;
}
```

### 5.4.2 与 ModuleToFunctionPassAdaptor 的核心差异

1. **SCC 可变**:`CurrentC` 指针会被 `updateCGAndAnalysisManagerForFunctionPass` 改写(:566-567)。Function pass 跑了之后,如果它改了 call graph(比如把 direct call 改成 indirect,或反过来),这个函数可能跳到别的 SCC;`CurrentC` 跟随更新。
2. **跨 SCC 跳跃的防御**:`if (CG.lookupSCC(*N) != CurrentC) continue;`(:536)——某个 node 在迭代中可能已被移到另一个 SCC(由前面的 pass 触发的 split/merge),此时跳过它,因为它会在那个新 SCC 被访问时处理。
3. **NoRerun 机制**(:541-542):如果 FAM 里已有 `ShouldNotRunFunctionPassesAnalysis` 的缓存,说明这个函数已经被 CGSCC 处理过且自那以后没被改动——直接跳过。这是为了应对"一个 function 因 SCC 重写被多次访问"的场景,避免重复跑昂贵的 function simplification pipeline。

### 5.4.3 updateCGAndAnalysisManagerForFunctionPass 的角色(CGPCM.cpp:881-1180)

约 300 行的辅助函数,负责在 function pass 改完 IR 后**同步** LazyCallGraph:

- 扫描函数体的 `call`/`invoke` 指令,与现有 Edge 比对,识别"保留/提升(ref→call)/降级(call→ref)/新增"四种情况(:908-938);
- 调用对应的 `LazyCallGraph::RefSCC::switchInternalEdgeToRef` / `switchInternalEdgeToCall` / `switchOutgoingEdgeToRef` / `switchOutgoingEdgeToCall` / `insertTrivialRefEdge`;
- 处理 SCC 分裂(`incorporateNewSCCRange`,:818-879):当把 call 边降级为 ref 边打破环时,原 SCC 分裂成多个新 SCC,把它们 push 进 `UR.CWorklist`,并返回包含当前节点 N 的那个新 SCC;
- 处理 SCC 合并(`switchInternalEdgeToCall` 的 MergeCB 回调,:1104-1123):ref→call 升级可能形成环,把多个 SCC 合并成一个,被合并的 SCC 加进 `UR.InvalidatedSCCs`。

这个函数是**新 PM 唯一允许 function pass"间接"修改 call graph 的通道**——function pass 不能直接调 LazyCallGraph 的 mutation API(它手里没有),但它的 PA 会被 CGSCCToFunctionPassAdaptor 检测(:564),如果 LazyCallGraphAnalysis 没保留,就由 adaptor 代为同步。

### 5.4.4 EagerlyInvalidate 与 NoRerun 在 pipeline 文本中的体现

CGSCCPassManager.h:470-486 的 `printPipeline`(头文件内联实现):

```cpp
OS << "function";
if (EagerlyInvalidate || NoRerun) {
  OS << "<";
  if (EagerlyInvalidate) OS << "eager-inv";
  if (EagerlyInvalidate && NoRerun) OS << ";";
  if (NoRerun) OS << "no-rerun";
  OS << ">";
}
```

O2 输出(scratch/lcg-default-o2-pipeline.txt 第 1 行,单行转储)实际是:

```
function<eager-inv;no-rerun>(sroa<modify-cfg>,early-cse<memssa>,...)
```

——即 default O2 在 CGSCC 内的 function 段**两个选项都开**:EagerlyInvalidate 在 SCC 重写时立刻丢缓存,NoRerun 防止 SCC 重访时重复跑。

---

## 5.5 LPMUpdater:loop nest 的更新通道

定义在 LPM.h:218-350,作为 `Pass->run(*L, LAM, LAR, Updater)` 的第 4 个参数传给每个 loop pass。

### 5.5.1 数据成员(LPM.h:325-349)

| 成员 | 类型 | 含义 |
|---|---|---|
| `Worklist` | `SmallPriorityWorklist<Loop *, 4> &` | FunctionToLoopPassAdaptor 的 worklist 引用(LPM.cpp:240) |
| `LAM` | `LoopAnalysisManager &` | 当前 LAM,用于 `markLoopAsDeleted` 时清缓存(LPM.h:239) |
| `CurrentL` | `Loop *` | 当前正在跑的 loop,由 adaptor 主循环在 LPM.cpp:275 重置 |
| `SkipCurrentLoop` | `bool` | 当前 loop 是否被删除/重排,后续 pass 应跳过 |
| `LoopNestMode` | `const bool` | loop 模式还是 loop-nest 模式(由 adaptor 构造传入) |
| `LoopNestChanged` | `bool` | loop-nest pass 标记 nest 是否变化(影响 LoopNestPtr 重建) |
| `ParentL` | `Loop *` (仅 debug) | 当前 loop 的父,用于 assert(LPM.h:339-343) |

### 5.5.2 三个更新接口

**`markLoopAsDeleted(Loop &L, StringRef Name)`**(LPM.h:238-245):
```cpp
void markLoopAsDeleted(Loop &L, llvm::StringRef Name) {
  LAM.clear(L, Name);
  assert((&L == CurrentL || CurrentL->contains(&L)) && ...);
  if (&L == CurrentL)
    SkipCurrentLoop = true;
}
```
pass 删除一个 loop 时调用,LAM 立即清该 loop 的缓存;如果删的是当前 loop,标记 SkipCurrentLoop,adaptor 主循环会在 `PI.runAfterPassInvalidated` 而不是 `runAfterPass` 路径处理(LPM.cpp:291-294)。

**`addChildLoops(ArrayRef<Loop *>)`**(LPM.h:259-278):
```cpp
void addChildLoops(ArrayRef<Loop *> NewChildLoops) {
  assert(!LoopNestMode && "Child loops should not be pushed in loop-nest mode.");
  Worklist.insert(CurrentL);          // 当前 loop 重新入 worklist,等子 loop 跑完后再回访
  for (Loop *NewL : NewChildLoops)
    assert(NewL->getParentLoop() == CurrentL && ...);
  appendLoopsToWorklist(NewChildLoops, Worklist);
  SkipCurrentLoop = true;
}
```
pass 给当前 loop 添加子 loop(比如 unswitch 产生新内层)。`CurrentL` 重新入 worklist 保证 postorder 语义:**子先于父**——子等父处理完后,父会被再访一次。

**`addSiblingLoops(ArrayRef<Loop *>)`**(LPM.h:286-300):
类似 addChildLoops,但 `NewSibLoops` 是当前 loop 的兄弟(共享 ParentL),不需要 revisit CurrentL,因为兄弟不会影响当前 loop 的内容。

**`revisitCurrentLoop()`**(LPM.h:307-313):
当前 loop 内容大改、需要从头再跑整条 pipeline。等价于 `SkipCurrentLoop = true; Worklist.insert(CurrentL);`。

### 5.5.3 LoopNest 与 LoopNestChanged

`LoopNest`(`llvm/include/llvm/Analysis/LoopNestAnalysis.h:29`)是 loop-nest pass 的"输入视图",包含从某个 outermost loop 开始的整棵嵌套树。`PassManager<Loop, ...>::runWithLoopNestPasses`(LPM.cpp:62-140)维护一个 `std::unique_ptr<LoopNest> LoopNestPtr`(:80)和 `IsLoopNestPtrValid` 标志(:81),**只在遇到 loop-nest pass 且 LoopNestPtr 失效时重建**(:100-106)。

`LoopNestPtr` 失效的触发条件:`U.isLoopNestChanged()` 返回 true,或前面某个 pass 的 PA 没保留 `LoopNestAnalysis`(LPM.cpp:132 `IsLoopNestPtrValid &= PassPA->getChecker<LoopNestAnalysis>().preserved();`)。

`markLoopNestChanged(bool)`(LPM.h:321-323)是 loop-nest pass 主动通知 updater 的接口——只在 loop-nest pass 改了嵌套结构时使用。

### 5.5.4 parent-loop 变化的通知

LPM.cpp:137 和 :181 各有一行:

```cpp
U.setParentLoop((IsLoopNestPass[I] ? *OuterMostLoop : L).getParentLoop());  // :137
U.setParentLoop(L.getParentLoop());                                          // :181
```

`setParentLoop`(LPM.h:247-251)**只在 `LLVM_ENABLE_ABI_BREAKING_CHECKS` 下赋值 ParentL**,release 下是空函数。ParentL 仅用于 `addSiblingLoops`(:289)和 `addChildLoops`(:266)里的 assert(确保新 loop 的父亲与 updater 记录一致)。换言之,**parent-loop 跟踪只为 debug 正确性,不影响 release 行为**。

---

## 5.6 DevirtSCCRepeatedPass 的位置

见 06-lazy-callgraph.md §6.6,本节只列其 adaptor 属性:

- 类定义 CGPCM.h:535-562,继承 `OptionalPassInfoMixin`(注意不是 Required!CGPCM.h:536)——这让它在 `-opt-bisect-limit` 下可被跳过;
- 构造 `DevirtSCCRepeatedPass(PassConceptT::unique_ptr Pass, int MaxIterations)`(CGPCM.h:542-544);
- `MaxDevirtIterations` 默认值 4,定义在 `llvm/lib/Analysis/CallGraphSCCPass.cpp:47-48`(legacy PM 的 cl::opt,被新 PM 复用);
- pipeline 文本名 `devirt<N>(...)`,由 `parseDevirtPassName`(`llvm/lib/Passes/PassBuilder.cpp:813-820`)解析,`createDevirtSCCRepeatedPass` 在 CGPCM.h:566-574;
- default O2 的 `cgscc(devirt<4>(inline,function-attrs,...))`(见 scratch/lcg-default-o2-pipeline.txt 第 1 行单行转储)。

---

## 5.7 MachineFunction 层为何没有通用 adaptor

**只有 `FunctionToMachineFunctionPassAdaptor` 一个手写 adaptor**(MPM.h:191,run 在 `llvm/lib/CodeGen/MachinePassManager.cpp:111-134`)。MachineFunction 之上没有"Module→MachineFunction"通用 adaptor——LLVM IR 层的 module pass 要进入 MIR 层必须经过 function,所以 `FunctionToMachineFunctionPassAdaptor` 已足够。

更根本的原因:**MIR 没有"跨 function 的 SCC/loop 等结构"**——MIR 的 SCC 概念在 SelectionDAG 和 MachineFunction 内部(每个 function 独立的 DAG),不需要跨 function 的 traversal adaptor。MachineFunction 的"内层"是 MachineBasicBlock,但 PM 不为它提供通用 adaptor,因为 CodeGen 各 pass 通常需要 function 级上下文(regalloc、scheduling)。

这与 02 笔记 §2.4 中提到的"三个手写 proxy"(FAM↔MFAM 手写 invalidate,MFM.h:129-189)是配套设计:**MachineFunction 层选择"少量手写 proxy + 一个手写 adaptor",放弃模板的普遍性,换取对 invalidate 语义的精细控制**。

---

## 5.8 自查表

| # | 断言 | 证据 | 状态 |
|---|---|---|---|
| 1 | 四大 adaptor 的 run() 分别在 PM.cpp:128、CGPCM.cpp:142、CGPCM.cpp:514、LPM.cpp:193 | 已 read 四文件 | 已核实 |
| 2 | ModuleToFunctionPassAdaptor 的 PassConcept 是 `PassConcept<Function, FAM>` | PM.h:881 | 已核实 |
| 3 | ModuleToFunctionPassAdaptor 构造仅收 `EagerlyInvalidate` | PM.h:883-885, 895 | 已核实 |
| 4 | ModuleToFunctionPassAdaptor 顺序遍历 function,不调 isDeclaration 的 F | PM.cpp:138-140 | 已核实 |
| 5 | ModuleToPostOrderCGSCCPassAdaptor 用三层 worklist(RCWorklist/CWorklist/UpdatedC) | CGPCM.cpp:157-340 | 已核实 |
| 6 | UR 在 CGPCM.cpp:169-175 构造,4 引用成员指向 adaptor 局部变量,3 值成员(UpdatedC/CrossSCCPA/IndirectVHs)自持有 | CGPCM.cpp:157-175; CGPCM.h:247-303 | 已核实(评审修正) |
| 7 | CGSCC 内的死函数批处理在 RefSCC 走完后统一 eraseFromParent | CGPCM.cpp:349-351 | 已核实 |
| 8 | CGSCCToFunctionPassAdaptor 的 EagerlyInvalidate/NoRerun 都默认 false | CGPCM.h:447-449, 499-500 | 已核实 |
| 9 | CGSCCToFunctionPassAdaptor 在 PA 不保留 LazyCallGraphAnalysis 时调 updateCGAndAnalysisManagerForFunctionPass | CGPCM.cpp:564-567 | 已核实 |
| 10 | FunctionToLoopPassAdaptor 构造时强制注入 LoopSimplify+LCSSA | LPM.h:402-403 | 已核实 |
| 11 | LoopStandardAnalysisResults 含 AA/AC/DT/LI/SE/TLI/TTI/MSSA 共 8 字段 | LoopAnalysisManager.h:52-61 | 已核实 |
| 12 | LAR 在 LPM.cpp:220-227 通过 7 个 AM.getResult<>() 一次性构造 | LPM.cpp:220-227 | 已核实 |
| 13 | LoopNestMode 用 HasRunOnLoopT detector 自动推导 | LPM.h:60-63, 108-122, 433-448 | 已核实 |
| 14 | Loop pass 顺序:内层先于外层(postorder) | scratch/adapt-loop-order.txt:16-18 | 已实测 |
| 15 | 两个连续 loop(...) 中 DT/AA/SE 命中缓存,LoopSimplify/LCSSA 重跑 | scratch/adapt-loop-two-adaptors.txt | 已实测 |
| 16 | LPMUpdater 的 markLoopAsDeleted/addChildLoops/addSiblingLoops/revisitCurrentLoop 接口 | LPM.h:238-313 | 已核实 |
| 17 | LoopNestPtr 仅在 LoopNestChanged 或 PA 不保留 LoopNestAnalysis 时重建 | LPM.cpp:100-106, 132 | 已核实 |
| 18 | MachineFunction 层只有 FunctionToMachineFunctionPassAdaptor,无更通用 adaptor | MPM.h:191 | 已核实 |
| 19 | MaxDevirtIterations 默认 4,定义在 CallGraphSCCPass.cpp:47-48 | CallGraphSCCPass.cpp:47 | 已核实 |
| 20 | printPipeline 把 EagerlyInvalidate/NoRerun 打成 `<eager-inv;no-rerun>` | CGSCCPassManager.h:470-486 | 已核实(验收时修正:原误标 .cpp,实为头文件内联) |
