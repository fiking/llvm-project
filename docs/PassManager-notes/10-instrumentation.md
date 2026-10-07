# Pass 插桩体系(PassInstrumentation)深入分析(§10)

> 基准:llvm-project main @ `3eda2aebadd4`(2026-09-28)。
> 所有引用均为本仓库 `文件:行号`,经 read_file/grep 实测核对;动态验证一律使用 `build-debug/bin/opt` 与 `build-debug/bin/clang`(Debug+Assertions)。
> 实测产物存于 `PassManager-notes/scratch/inst-*`。
> 风格对齐仓库根 `AMDGPU-notes/01-architecture.md`。

---

## 10.0 总览:两个类、一条注入链、三种消费方式

新 PM 的插桩体系由两个协作类构成,全部定义在 `llvm/include/llvm/IR/PassInstrumentation.h`(全文 364 行):

- **`PassInstrumentationCallbacks`**(`PassInstrumentation.h:67`)——回调注册表,持有 9 类回调 vector + 1 个 Class2PassName 映射表;
- **`PassInstrumentation`**(`PassInstrumentation.h:199`)——Pass Manager 侧的"咨询点"(entry points),持有指向 Callbacks 的裸指针,在 pass/analysis 执行的各个时机把控制权转交给注册的回调。

第三个角色是 **`PassInstrumentationAnalysis`**(`PassInstrumentation.h:339`)——一个伪 analysis,其作用是让 PassInstrumentation 对象能通过 AnalysisManager 的 `getResult` 机制被任何 PassManager 惰性获取(`PassInstrumentation.h:354-357` 的 `run` 直接返回 `PassInstrumentation(Callbacks)`)。

文件头注释(`PassInstrumentation.h:23-45`)自述了使用流程:

> "在 PassInstrumentationCallbacks 实例中注册回调(PassBuilder 提供 helper);在所有 PassManager 的 AnalysisManager 中注册 PassInstrumentationAnalysis(PassBuilder 在注册 analyses 时自动处理);Pass Manager 从 analysis manager 请求 PassInstrumentationAnalysis 并得到 PassInstrumentation 作为结果;Pass Manager 在适当时机调用 PassInstrumentation 入口点……某些插桩点(BeforePass)允许控制 pass 是否执行——回调返回 false 意味着 pass 将被跳过。"

```text
  ┌──────────────────────────────────────────────────────────┐
  │ 用户工具 (opt / clang)                                    │
  │   PassInstrumentationCallbacks PIC;  ← 唯一的回调注册表   │
  │   StandardInstrumentations SI(...);                       │
  │   SI.registerCallbacks(PIC, &MAM);   ← 注册 9+ 类回调     │
  │   PassBuilder PB(TM, PTO, PGO, &PIC);← 注册 Class2PassName│
  └──────────────┬───────────────────────────────────────────┘
                 │ PIC 指针存入 PassInstrumentationAnalysis
                 ▼
  ┌──────────────────────────────────────────────────────────┐
  │ AnalysisManager (MAM/FAM/CGAM/LAM)                        │
  │   registerPass([&]{ return PassInstrumentationAnalysis(   │
  │                          PIC); })                         │
  │     —— PassRegistry.def:37/315/377/770                    │
  └──────────────┬───────────────────────────────────────────┘
                 │ getResult<PassInstrumentationAnalysis>(IR)
                 ▼
  ┌──────────────────────────────────────────────────────────┐
  │ PassManager::run (PassManagerImpl.h:62-64)                │
  │   PassInstrumentation PI = getResult<...>(...);           │
  │   for (auto &Pass : Passes) {                             │
  │     if (!PI.runBeforePass(*Pass, IR)) continue;   ←:73    │
  │     PassPA = Pass->run(IR, AM, ...);              ←:76    │
  │     AM.invalidate(IR, PassPA);                    ←:80    │
  │     PI.runAfterPass(*Pass, IR, PassPA);           ←:84    │
  │   }                                                       │
  └──────────────┬───────────────────────────────────────────┘
                 │ 遍历 Callbacks 中的 vector,逐个调用
                 ▼
  ┌──────────────────────────────────────────────────────────┐
  │ StandardInstrumentations 各成员:PrintIR / PrintPass /    │
  │ TimePasses / TimeProfilingPasses / OptNone / OptPassGate  │
  │ / PrintChangedIR / PrintChangedDiff / Verify / ...        │
  └──────────────────────────────────────────────────────────┘
```

三种消费方式对应三条独立通道:

1. **观察通道**(只读):PrintIR / PrintPass / PrintChanged / TimePasses / TimeTrace / DroppedVarStats——注册 `BeforeNonSkippedPass` / `AfterPass` 等只读回调;
2. **控制通道**(可跳过 pass):OptNone(`optnone` 属性)与 OptPassGate(`-opt-bisect` / `-opt-disable`)——注册 `ShouldRunOptionalPassCallback`(返回 `bool`,任一返回 false 即跳过,`PassInstrumentation.h:230-234`);
3. **校验通道**(可中止编译):VerifyInstrumentation(`-verify-each`,发现坏 IR 直接 `report_fatal_error`,见 `StandardInstrumentations.cpp:1509/1524`)与 PreservedCFGCheckerInstrumentation(断言 CFG 未被谎报保留)。

---

## 10.1 PassInstrumentationCallbacks:回调清单与 Class2PassName

### 10.1.1 静态分析:9 类回调 + 1 张映射表

**回调类型别名**(`PassInstrumentation.h:79-87`)——注意只有第一类返回 `bool`:

| 类型别名 | 签名 | 行号 |
|---|---|---|
| `BeforePassFunc` | `bool(StringRef, IRUnitRef)` | `:79` |
| `BeforeSkippedPassFunc` | `void(StringRef, IRUnitRef)` | `:80` |
| `BeforeNonSkippedPassFunc` | `void(StringRef, IRUnitRef)` | `:81` |
| `AfterPassFunc` | `void(StringRef, IRUnitRef, const PreservedAnalyses &)` | `:82` |
| `AfterPassInvalidatedFunc` | `void(StringRef, const PreservedAnalyses &)` | `:83` |
| `BeforeAnalysisFunc` | `void(StringRef, IRUnitRef)` | `:84` |
| `AfterAnalysisFunc` | `void(StringRef, IRUnitRef)` | `:85` |
| `AnalysisInvalidatedFunc` | `void(StringRef, IRUnitRef)` | `:86` |
| `AnalysesClearedFunc` | `void(StringRef)` | `:87` |

**注册方法**(`PassInstrumentation.h:96-155`)与**存储 vector**(`:165-194`)一一对应:

| 注册方法(行号) | 存储成员(行号) | 触发点 |
|---|---|---|
| `registerShouldRunOptionalPassCallback` (`:97`) | `ShouldRunOptionalPassCallbacks` (`:167`) | `PassInstrumentation::runBeforePass`(`:232-233`),**仅对非 required pass** |
| `registerBeforeSkippedPassCallback` (`:102`) | `BeforeSkippedPassCallbacks` (`:170`) | `runBeforePass` 中 `ShouldRun==false` 分支(`:240-241`) |
| `registerBeforeNonSkippedPassCallback` (`:107`) | `BeforeNonSkippedPassCallbacks` (`:173`) | `runBeforePass` 中 `ShouldRun==true` 分支(`:237-238`) |
| `registerAfterPassCallback` (`:112`) | `AfterPassCallbacks` (`:176`) | `runAfterPass`(`:254-255`) |
| `registerAfterPassInvalidatedCallback` (`:120`) | `AfterPassInvalidatedCallbacks` (`:178`) | `runAfterPassInvalidated`(`:265-266`) |
| `registerBeforeAnalysisCallback` (`:129`) | `BeforeAnalysisCallbacks` (`:181`) | `runBeforeAnalysis`(`:274-275`) |
| `registerAfterAnalysisCallback` (`:134`) | `AfterAnalysisCallbacks` (`:184`) | `runAfterAnalysis`(`:283-284`) |
| `registerAnalysisInvalidatedCallback` (`:143`) | `AnalysisInvalidatedCallbacks` (`:187`) | `runAnalysisInvalidated`(`:293-294`) |
| `registerAnalysesClearedCallback` (`:148`) | `AnalysesClearedCallbacks` (`:190`) | `runAnalysesCleared`(`:301-302`) |
| `registerClassToPassNameCallback` (`:153`) | `ClassToPassNameCallbacks` (`:193`) | `getPassNameForClassName` 惰性触发(`PassInstrumentation.cpp:27-31`) |

**设计细节**:

1. **三个"前"回调的语义分层**(`PassInstrumentation.h:69-78` 注释):
   - `ShouldRunOptionalPass` 只作用于"optional"(非 `isRequired()`)pass,返回 `false` 表示跳过——这是**唯一带返回值的回调族**,`runBeforePass` 用 `ShouldRun &= C(...)` 折叠(`:232-233`),即"一票否决"语义;
   - `BeforeNonSkippedPass` 只在确定要运行时触发——因此 TimePasses/PrintChanged 等需要"配对 before/after"的插桩都注册它,而不是 `ShouldRunOptionalPass`(否则跳过的 pass 会留下未配对的栈帧);
   - `BeforeSkippedPass` 只在被跳过时触发——`-debug-pass-manager` 的 "Skipping pass" 日志即由此打印(`StandardInstrumentations.cpp:1144-1150`)。

2. **`ToFront` 参数**(`:112-117`, `:120-126`, `:134-140`):`AfterPass` / `AfterPassInvalidated` / `AfterAnalysis` 三个注册方法接受 `bool ToFront = false`,为 `true` 时用 `insert(begin())` 把回调插到 vector 头部。TimeProfilingPassesHandler 用它保证"计时的 after 回调最先执行、before 回调最后执行",从而不把其他插桩的耗时计入 pass 时间(见 §10.3.4)。

3. **`AfterPassInvalidatedFunc` 不携带 IRUnitRef**(`:83`,注释 `:71-78`):IR 已被 pass 摧毁(典型场景:loop/SCC pass 删掉了自己操作的 IR 单元),传指针不安全。注释承认"将来可能提供安全传递失效 IR 的方式"。PrintIRInstrumentation 为此维护了一个 `PassRunDescriptorStack`(`StandardInstrumentations.h:99-104`),在 before 阶段把模块指针与 IR 名字存起来,after-invalidated 阶段靠弹栈恢复上下文(`StandardInstrumentations.cpp:857-880`)。

### 10.1.2 Class2PassName:类名 → 管道名的惰性映射

Pass 在 PassManager 内部以**类名**(`PassT::name()`,即 `static StringRef name()`)标识,但用户熟悉的、`-print-pipeline-passes` 输出的、opt-bisect 日志里出现的是**管道名**(`"instcombine"` 而非 `"InstCombinePass"`)。映射表的运作:

- **存储**:`DenseMap<StringRef, std::string> ClassToPassName`(`PassInstrumentation.h:194`);
- **填充**:`addClassToPassName`(`PassInstrumentation.h:158`,实现于 `PassInstrumentation.cpp:19-23`);
- **惰性触发**:`getPassNameForClassName`(`PassInstrumentation.cpp:25-36`)——首次调用时先执行所有 `ClassToPassNameCallbacks` 并清空(`:27-31`),再查表;查不到返回空 `StringRef`;
- **注册者**:`PassBuilder` 构造函数(`PassBuilder.cpp:598-638`)注册**一个** lambda 回调,该 lambda 通过 `#include "PassRegistry.def"` 宏展开为对**全部** MODULE_PASS / FUNCTION_PASS / LOOP_PASS / CGSCC_PASS / ANALYSIS / MACHINE_FUNCTION_* 的 `PIC->addClassToPassName(...)` 调用——即整个注册表由 `PassRegistry.def` 与 `MachinePassRegistry.def` 两个文件机械生成;
- **消费点**:`OptPassGateInstrumentation::registerCallbacks`(`StandardInstrumentations.cpp:1116-1122`)——opt-bisect 收到的 `ClassName` 先经 `PIC.getPassNameForClassName(ClassName)` 转管道名,**转换失败才回退用类名**(`:1119-1120`)。实测 §10.8.5 的 BISECT 日志中 `simplifycfg`、`early-cse` 等确实是管道名,验证了这条路径。

`PassManagerImpl.h:44-47` 的崩溃栈打印(StackTraceEntry)也消费同一映射:打印 pipeline 时用 `MapClassName2PassName` lambda 把类名转回管道名。

### 10.1.3 设计动机

- **回调注册表与 PM 解耦**:PassInstrumentation 是**值语义**(只含一个裸指针,`PassInstrumentation.h:200` 注释明说"intended to be easily copyable"),每个 PassManager::run 调用现场从 AM 取一份拷贝(`PassManagerImpl.h:62-64`),没有任何全局状态;
- **跳过与观察分离**:观察回调(`BeforeNonSkipped`)不会意外否决 pass;控制回调(`ShouldRunOptionalPass`)集中在一条短路求值链里,语义清晰;
- **惰性 Class2PassName**:注册回调只在第一次查询时执行一次,避免 PassBuilder 构造时填充整张表(数百项)的成本在不用相关功能时白花。

---

## 10.2 PassInstrumentation 在 PassManager 内部的咨询点

### 10.2.1 PassManager::run 的完整调用序列

`PassManager<IRUnitT, AnalysisManagerT, ExtraArgTs...>::run` 的实现不在 `PassManager.h` 本体(声明在 `PassManager.h:220-221`),而在 **`llvm/include/llvm/IR/PassManagerImpl.h:27-98`**(显式实例化于 `PassManager.cpp:43-44`)。逐行标注:

```cpp
// PassManagerImpl.h:56-98 (节选,行号为文件内实际行号)
PreservedAnalyses PA = PreservedAnalyses::all();                 // :56
// :58-61 注释:通过 tuple 包装帮助从 ExtraArgs 中抽取 AM 的参数
PassInstrumentation PI =
    detail::getAnalysisResult<PassInstrumentationAnalysis>(
        AM, IR, std::tuple<ExtraArgTs...>(ExtraArgs...));        // :62-64

StackTraceEntry Entry(PI, IR);                                   // :66
for (auto &Pass : Passes) {                                      // :67
  Entry.setPass(&*Pass);                                         // :68

  // ① BeforePass 咨询:回调返回 false → continue 跳过
  if (!PI.runBeforePass<IRUnitT>(*Pass, IR))                     // :73
    continue;                                                    // :74

  PreservedAnalyses PassPA = Pass->run(IR, AM, ExtraArgs...);    // :76

  // ② pass 运行后立即失效分析(在 AfterPass 之前)
  AM.invalidate(IR, PassPA);                                     // :80

  // ③ AfterPass 回调
  PI.runAfterPass<IRUnitT>(*Pass, IR, PassPA);                   // :84

  PA.intersect(std::move(PassPA));                               // :88
}
PA.preserveSet<AllAnalysesOn<IRUnitT>>();                        // :95
return PA;                                                       // :97
```

**三个关键观察**:

1. **PI 获取本身是走 analysis 缓存的**(`:62-64`):`detail::getAnalysisResult` 是 PassManager.h 里的 tuple 解包 helper(`PassManager.h:166-173`),目的是从 PassManager 的 ExtraArgTs 中只抽取 AnalysisManager 需要的参数子集。PassInstrumentationAnalysis 的 `invalidate` 永远返回 `false`(`PassInstrumentation.h:310-314`,注释 :305-309 "On attempt to invalidate just return false. There is nothing to become invalid here."),因此该结果**永不失效**,整个编译期缓存一次。

2. **`runBeforePass` 返回 false 时 `continue`**(`:73-74`):跳过的 pass 连 `AM.invalidate` 都不会触发——这正是 opt-bisect 能安全跳过的原因(被跳过的 pass 不会污染分析缓存状态)。

3. **`AM.invalidate` 在 `runAfterPass` 之前**(`:80` 先于 `:84`):意味着 AfterPass 回调里看到的分析缓存已经是失效后的状态;同时 `AM.invalidate` 内部会触发 `runAnalysisInvalidated` 回调(见 §10.2.3)。

**StackTraceEntry**(`:30-54`):一个 `PrettyStackTraceEntry` 子类,crash 时通过 `printPipeline` 打印"Running pass \"X\" on Y"——它消费 `PI.getPassNameForClassName`(`:45`)把类名转管道名。这就是崩溃日志里 pipeline 名的来源。

### 10.2.2 ModuleToFunctionPassAdaptor 的独立咨询点

适配器有自己的 PI 逻辑(`PassManager.cpp:128-170`),不复用 `PassManager::run`:

```cpp
PassInstrumentation PI = AM.getResult<PassInstrumentationAnalysis>(M);   // :135
...
for (Function &F : M) {                                                  // :138
  if (F.isDeclaration()) continue;                                       // :139-140
  if (!PI.runBeforePass<Function>(*Pass, F))                             // :145
    continue;                                                            // :146
  PreservedAnalyses PassPA = Pass->run(F, FAM);                          // :148
  FAM.invalidate(F, EagerlyInvalidate ? PreservedAnalyses::none()
                                      : PassPA);                         // :153
  PI.runAfterPass(*Pass, F, PassPA);                                     // :155
  PA.intersect(std::move(PassPA));                                       // :159
}
```

与 `PassManager::run` 的差别:函数声明直接跳过(`:139-140`,不进回调);`EagerlyInvalidate` 模式下用 `none()` 强制全失效(`:153`)。

### 10.2.3 AnalysisManager 的四个分析侧调用点

分析与 pass 对称,但调用点散落在 `PassManagerImpl.h` 的 `AnalysisManager` 模板方法里:

| 调用点 | 位置(行号) | 场景 |
|---|---|---|
| `PI.runBeforeAnalysis(P, IR)` | `PassManagerImpl.h:145` | `getResultImpl` 首次计算 analysis 前 |
| `PI.runAfterAnalysis(P, IR)` | `PassManagerImpl.h:155` | analysis 计算完成、结果入缓存后 |
| `PI->runAnalysisInvalidated(...)` | `PassManagerImpl.h:220-221` | `invalidate()` 中发现某结果被标记失效时 |
| `PI->runAnalysesCleared(Name)` | `PassManagerImpl.h:116-117` | `clear(IR, Name)` 显式清空某 IR 单元的所有缓存时 |

**细节**:

- **`runBeforeAnalysis` 的自举保护**(`PassManagerImpl.h:142-146`):`if (ID != PassInstrumentationAnalysis::ID())`——避免 PassInstrumentationAnalysis 自己去触发自己的 before/after 回调(否则无限递归);`PI` 默认构造(空 Callbacks)兜底,若请求的分析就是 PIA 本身则跳过两个回调。
- **缓存命中不触发回调**:`getResultImpl` 中回调只在 `Inserted == true`(即真去跑了 analysis)的分支里(`:139-163`),缓存命中直接返回,无 before/after 事件——TimePasses 的 analysis 计时因此只统计**首次计算**。
- **`runAnalysisInvalidated` 的获取方式是 `getCachedResult`**(`:220`):与 PM 主循环用 `getResult` 不同——这里不能触发"惰性计算",因为 PIA 此刻可能根本没被缓存过(虽然实际上 PM::run 已经缓存了它)。

### 10.2.4 needsToRunBeforePass / skip 决策链:opt-bisect 如何借 beforePass 实现跳过

完整决策链(从命令行到跳过动作):

```text
-opt-bisect-limit=2  (cl::opt 回调, OptBisect.cpp:31-49)
  → getOptBisector().setIntervals({{1, 2}})          ← 全局单例 OptBisect
     (OptBisect.cpp:26-29 的函数内 static)

LLVMContext::getOptPassGate() 返回该单例              ← OptPassGate 基类
  (OptBisect.h:26-43;LLVMContext 持有 shared_ptr)

OptPassGateInstrumentation::registerCallbacks        ← StandardInstrumentations.cpp:1110-1123
  if (!PassGate.isEnabled()) return;                 ← :1112-1114 未启用则零开销
  PIC.registerShouldRunOptionalPassCallback(...);    ← :1116

PassInstrumentation::runBeforePass                   ← PassInstrumentation.h:226-245
  if (!isRequired(Pass))                             ← :231
    for (C : ShouldRunOptionalPassCallbacks)
      ShouldRun &= C(Pass.name(), IR);               ← :232-233 一票否决

OptPassGateInstrumentation::shouldRun                ← StandardInstrumentations.cpp:1089-1108
  if (isIgnored(PassName)) return true;              ← :1090-1091 管理类 pass 永不跳过
  return Context.getOptPassGate().shouldRunPass(...)  ← :1093-1094

OptBisect::shouldRunPass                             ← OptBisect.cpp:96-115
  int CurBisectNum = ++LastBisectNum;                ← :100 单调递增计数
  ShouldRun = contains(BisectIntervals, CurBisectNum)← :105-107
            && !DisabledPasses.contains(PassName);   ← :110 -opt-disable 联合
  if (OptBisectVerbose) printPassMessage(...)        ← :112-113 "BISECT: ..." 日志
```

**`isRequired` 的静态判定**(`PassInstrumentation.h:202-210` 注释与 `PassManagerInternal.h:95-101`):模板方法 `PassInstrumentation::isRequired(const PassT&)` 直接调 `Pass.isRequired()`;对类型擦除后的 `PassConcept`,该值在构造 `PassModel` 时由 `PassT::isRequired()` 静态捕获(`PassManagerInternal.h:138-139`)。`RequiredPassInfoMixin::isRequired()` 返回 `true`(`PassManager.h:104`),`OptionalPassInfoMixin` 返回 `false`(`PassManager.h:115`)。**required pass 根本不进 `ShouldRunOptionalPassCallbacks`**(`PassInstrumentation.h:231` 的 if),因此 VerifierPass、PassManager 自身等永远不被 opt-bisect 或 optnone 跳过——这就是 `StandardInstrumentations.cpp:1146-1147` 那个 `assert(!isSpecialPass(...))`("Unexpectedly skipping special pass")存在的前提。

**与 legacy PM 的兼容**:legacy 路径**不走 PassInstrumentation**,而是各 pass 基类自己咨询同一个全局 gate:

- `FunctionPass::skipFunction`(`Pass.cpp:196-212`):先查 `OptPassGate`(`:197-204`),再查 `optnone`(`:206-210`);
- `LoopPass::skipOptnoneFunction`(`LoopPass.cpp:387-389`)、`RegionPass::skipOptnoneFunction`(`RegionPass.cpp:301-303`)同样模式;
- 共享对象:`OptBisect` 单例(`OptBisect.cpp:26-29`)由 `getGlobalPassGate()`(`OptBisect.cpp:117`)暴露,`LLVMContext::getOptPassGate` 桥接——因此**新旧 PM 的 `-opt-bisect-limit` 计数是同一个 `LastBisectNum`(`OptBisect.h:100`,mutable)**,混合流水线里编号连续。

**`OptBisect` 的状态**(`OptBisect.h:99-103`):`LastBisectNum`(mutable,`shouldRunPass` 是 const 但要自增)、`BisectIntervals`(`IntegerInclusiveIntervalUtils::IntervalList`)、`DisabledPasses`(`StringSet`)。命令行解析(`OptBisect.cpp:31-87`):`-opt-bisect-limit=N` 转成区间 `{1,N}`(`:40-42`),`0` 转 `{0,0}`(`:37-39`),`-1` 转 `{1,INT_MAX}`(`:34-36`);`-opt-bisect=1-10,20-30,45` 走 `IntegerInclusiveIntervalUtils::parseIntervals`(`:60-61`);`-opt-disable=pass1,pass2` 直接 `setDisabled`(`:82-87`)。

---

## 10.3 StandardInstrumentations:成员实现剖析

### 10.3.1 类结构与注册总线

`StandardInstrumentations`(`StandardInstrumentations.h:606-637`)聚合 **15 个成员插桩对象**(`:607-621`;评审修正:原写 14,漏了 DroppedVariableStatsIR DroppedStatsIR :621):

```cpp
PrintIRInstrumentation PrintIR;                    // :607  -print-before*/-print-after*
PrintPassInstrumentation PrintPass;                // :608  -debug-pass-manager
TimePassesHandler TimePasses;                      // :609  -time-passes
TimeProfilingPassesHandler TimeProfilingPasses;    // :610  -time-trace
OptNoneInstrumentation OptNone;                    // :611  optnone 属性跳过
OptPassGateInstrumentation OptPassGate;            // :612  -opt-bisect/-opt-disable
PreservedCFGCheckerInstrumentation PreservedCFGChecker; // :613 -verify-cfg-preserved
IRChangedPrinter PrintChangedIR;                   // :614  -print-changed=quiet(无值)
PseudoProbeVerifier PseudoProbeVerification;       // :615  pseudo probe 校验
InLineChangePrinter PrintChangedDiff;              // :616  -print-changed=diff*
DotCfgChangeReporter WebsiteChangeReporter;        // :617  -print-changed=dot-cfg*
PrintCrashIRInstrumentation PrintCrashIR;          // :618  -print-on-crash
IRChangedTester ChangeTester;                      // :619  -exec-on-ir-change
VerifyInstrumentation Verify;                      // :620  -verify-each
DroppedVariableStatsIR DroppedStatsIR;             // :621  -dropped-variable-stats
```

**`registerCallbacks`**(`StandardInstrumentations.cpp:2548-2574`)按固定顺序注册,其中两处顺序敏感:

1. **`Verify` 仅在 `VerifyEach` 为真时注册**(`:2557-2558`);
2. **`PreservedCFGChecker` 仅在 `MAM != nullptr` 时注册**(`:2563-2565`)——它需要向 MAM 注册 `PreservedCFGCheckerAnalysis`(见 :1318-1332)。**注意总闸**:其 `registerCallbacks` 第一行 `if (!VerifyAnalysisInvalidation) return;`(`:1391-1393`)——开关 `-verify-analysis-invalidation`(`:52-59`)仅 EXPENSIVE_CHECKS 构建默认 ON,普通 Debug 构建默认 OFF(本仓库 build-debug 的 `LLVM_ENABLE_EXPENSIVE_CHECKS:BOOL=OFF`,CMakeCache.txt:843),可显式开旗;覆盖面仅限 StructuralHash/CFG 快照的"变了没申报",不验分析内容正确性;
3. **`TimeProfilingPasses` 永远最后注册**(`:2573`),且其 after 回调全部 `ToFront=true`——注释(`:2567-2572`)明说:"TimeProfiling 的 Before 回调被追加到所有 Before 回调的末尾(通过最后调用 registerCallbacks);它的 After 回调被自己的 registerCallbacks 放到最前面。这是必要的,以保证其他回调的耗时不被计入(pass 的)计时。"

### 10.3.2 PrintPassOptions 与 PrintPassInstrumentation(-debug-pass-manager)

`PrintPassOptions`(`StandardInstrumentations.h:126-133`)三个布尔:`Verbose`(连 adaptor/PM 也打印)、`SkipAnalyses`(不打印分析事件)、`Indent`(按层级缩进)。

`PrintPassInstrumentation::registerCallbacks`(`StandardInstrumentations.cpp:1133-1207`)注册了**全部 9 类回调中的 6 类**(BeforeSkipped/BeforeNonSkipped/AfterPass/AfterPassInvalidated/BeforeAnalysis/AfterAnalysis/AnalysisInvalidated/AnalysesCleared——除 ShouldRunOptionalPass 外全包),是观察面最全的插桩:

- **缩进协议**:`BeforeNonSkippedPass` 打印 "Running pass: X on Y (N instructions)" 后 `Indent += 2`(`:1172`),`AfterPass`/`AfterPassInvalidated` 中 `Indent -= 2`(`:1180`,`:1187`);analysis 同理(`:1194`,`:1197`)。嵌套 PM/adaptor 因此呈现树形缩进(需 `-debug-pass-manager=verbose` 才打印 adaptor 本身,否则 `SpecialPasses={"PassManager","PassAdaptor"}` 被过滤,`:1138-1142`);
- **指令计数**:函数 pass 打印 `F->getInstructionCount()`(`:1158-1163`),SCC pass 打印节点数(`:1164-1170`)。

实测输出见 §10.8.6。

### 10.3.3 PrintChanged 家族与 PrintChangedDiff(diff 算法)

#### 10.3.3.1 ChangeReporter 模板基类:状态机

`ChangeReporter<IRUnitT>`(`StandardInstrumentations.h:214-263`)是"变更报告器"的抽象基类,核心是一个**栈式状态机**:

- `BeforeStack: std::vector<BeforeIR>`(`:257`)——每次 `saveIRBeforePass` 压栈(`StandardInstrumentations.cpp:400-420`),`handleIRAfterPass` 弹栈(`:422-452`);
- 虚函数 7 个(`:233-249`):`handleInitialIR` / `generateIRRepresentation` / `omitAfter` / `handleAfter` / `handleInvalidated` / `handleFiltered` / `handleIgnored`——子类只实现"拿到前后表示后做什么",框架负责调度。

过滤链(`isInteresting`,`StandardInstrumentations.cpp:385-391`):`isIgnored(PassID)`(管理类 pass 名单,`:348-355`)∨ `!isPassInPrintList(PassName)`(`-filter-passes`)→ 不 interesting;函数 IR 再叠加 `-filter-print-funcs` / `-filter-print-source-locs`(`shouldGenerateData`,`:741-758`)。

#### 10.3.3.2 IRChangedPrinter(quiet 模式):整串比较

`IRChangedPrinter`(`StandardInstrumentations.h:292-307`)的 IR 表示是 **`std::string`**——`generateIRRepresentation` 直接 `unwrapAndPrint` 整个 IR 单元到字符串(`StandardInstrumentations.cpp:531-536`)。比较就是字符串 `==`(`ChangeReporter::handleIRAfterPass` 的 `:444`)。

- **quiet vs verbose**:唯一差别在构造参数 `VerboseMode`——`StandardInstrumentations.cpp:2481`:`PrintChangedIR(PrintChanged == ChangePrinter::Verbose)`。verbose 模式多打印初始 IR(`handleInitialIR`,`:490-497`、"*** IR Dump At Start ***")、"no change" 提示(`omitAfter`,`:500-503`)、"filtered out"/"ignored"/"invalidated" 提示;quiet 模式这些全部静默,只在 `handleAfter` 时打印 "*** IR Dump After {PassID} on {Name} ***" + 完整 after IR(`:538-554`)。
- **注册条件**(`:525-529`):仅当 `PrintChanged == Verbose || Quiet`。

#### 10.3.3.3 InLineChangePrinter(diff 模式):按块结构化比较 + 外部 diff

`InLineChangePrinter`(`StandardInstrumentations.h:455-480`)的 IR 表示是 **`IRDataT<EmptyData>`**——一个结构化的"函数→基本块→块体字符串"两层有序映射:

```text
IRDataT<T>        = OrderedChangedData<FuncDataT<T>>   // 函数名 → FuncDataT
FuncDataT<T>      = OrderedChangedData<BlockDataT<T>>  // 块名 → BlockDataT + 入口块名
BlockDataT<T>     = { Label, Body(块打印字符串), Data } // StandardInstrumentations.h:337-366
```

**生成**:`IRComparer<T>::analyzeIR`(`StandardInstrumentations.cpp:714-739`)对 module/SCC 取模块里每个函数、对 Function/Loop 取所在函数、对 MachineFunction 直接处理;`generateFunctionData`(`:762-780`)逐块 `B.print(SS, ...)` 存字符串(无名块用序号 `:769`)。

**比较算法**(`OrderedChangedData<T>::report`,`StandardInstrumentations.cpp:607-677`)——这是一个**带顺序保持的集合差算法**,不是行级 diff:

- 输入是 before/after 两个"有序名→数据"映射;
- 以 **after 的顺序**为主序遍历(`:642-668`),遇到两边都有的项时,先在 before 序列里**快进并报告"被删除"的项**(`HandlePotentiallyRemovedData`,`:618-623`),再 flush 排队的"新增"项(`HandleNewData`,`:625-630`),然后报告这个公共项;
- 新增项先入 `NewDataQueue` 延迟报告(`:646-648`),保证"删除在前、新增就近插入"的可读顺序;
- 块体比较委托给 `HandlePair` 回调——`InLineChangePrinter::handleFunctionCompare`(`:1577-1596`)里,对每对块调用 **`doSystemDiff`**(`PrintPasses.cpp:382-420`)。

**`doSystemDiff` 的真相**(`PrintPasses.cpp:382-420`):LLVM **不做自己的行 diff**,而是把两个块体写进临时文件、调用外部 `diff` 可执行文件:

```cpp
("--old-line-format=" + OldLineFormat).toVector(OLF);      // PrintPasses.cpp:400
StringRef Args[] = {DiffBinary, "-w", "-d", OLF, NLF, ULF,
                    FileName[0], FileName[1]};             // :405-406
```

即依赖 **GNU diffutils** 的 `--old-line-format/--new-line-format/--unchanged-line-format` 选项,行格式串由调用方给:`Removed="-%l\n"`、`Added="+%l\n"`、`NoChange=" %l\n"`(彩色版加 ANSI 转义,`StandardInstrumentations.cpp:1590-1593`)。diff 程序可用 `-print-changed-diff-path` 指定(默认 `"diff"`,`PrintPasses.cpp:96-98`)。

**平台后果(实测确认)**:macOS 自带的 BSD diff **不支持** `--old-line-format`,`-print-changed=diff-quiet` 在本机的输出是每个变更点一段 `diff: unrecognized option '--old-line-format=-%l'` 错误(完整输出存于 `scratch/inst-print-changed-diff-quiet.txt`,190 行,几乎全是 diff 的 usage 文本)。这验证了注释(`PrintPasses.cpp:72-74`)的声明:"This reporter relies on the linux diff utility … For systems that do not have the necessary facilities, the error message will be shown in place of the expected output."

**`cd`/`cdiff` 模式**:`-print-changed=cdiff`/`cdiff-quiet` 映射到 `ChangePrinter::ColourDiffVerbose/ColourDiffQuiet`(`PrintPasses.cpp:84-87`),与 diff 共用 InLineChangePrinter,仅行格式串带 ANSI 颜色(`\033[31m` 红删除 / `\033[32m` 绿新增,`:1590-1593`)。(任务书中提到的 "cd" 拼写在当前 main 上不存在;实际枚举值是 `cdiff`/`cdiff-quiet`——**待验证**是否历史上曾有 `cd` 别名,本仓库当前代码无。)

**注册条件**(`StandardInstrumentations.cpp:1598-1604`):四种 diff 变体(DiffVerbose/DiffQuiet/ColourDiffVerbose/ColourDiffQuiet)共用一条注册;`DotCfg` 两种变体走 DotCfgChangeReporter(`:2459-2474`,生成 dot→pdf→passes.html 网站,`:2398-2456`)。

### 10.3.4 TimePassesHandler(-time-passes)与 TimeProfilingPassesHandler(-time-trace)

#### TimePassesHandler(`PassTimingInfo.h:55-…`,实现 `PassTimingInfo.cpp:168-323`)

- **两组 TimerGroup**:`PassTG`(组名 "pass",描述 "Pass execution timing report")与 `AnalysisTG`("analysis" / "Analysis execution timing report"),静态常量定义于 `PassTimingInfo.h:87-91`——这就是输出里两张表的分组来源(实测 §10.8.3);
- **双栈防重入**:`PassActiveTimerStack` / `AnalysisActiveTimerStack`(`PassTimingInfo.h:73-76`)。`startPassTimer`(`PassTimingInfo.cpp:246-259`)先**暂停**栈顶 timer 再压新 timer——pass 内部递归触发其他 pass(如 RequireAnalysisPass)时不重复计时;`stopPassTimer`(`:261-275`)弹出后**恢复**前一个 timer。analysis 栈同理(`:277-303`);
- **PerRun 模式**(`-time-passes-per-run`,`PassTimingInfo.cpp:44-47`):默认按 PassID 聚合一个 Timer(`:170-175`);PerRun 时每次调用新建 Timer 并编号 `#N`(`:179-188`);
- **注册 5 类回调**(`:305-323`):BeforeNonSkippedPass/AfterPass/AfterPassInvalidated/BeforeAnalysis/AfterAnalysis;`shouldIgnorePass`(`:240-244`)过滤 PassManager/PassAdaptor/AnalysisManagerProxy/ModuleInlinerWrapperPass/DevirtSCCRepeatedPass;
- **打印**:`print()`(`:201-214`)把两个 TimerGroup 各打一张表到 `CreateInfoOutputFile()`;
- **与 legacy PM 的关系**:`PassTimingInfo.cpp:50-153` 保留了 legacy 专用的 `PassTimingInfo` 类(`getPassTimer(Pass *)` 接口,`:148-153`),两套实现完全分离——新 PM 的 TimePassesHandler 不复用它。

#### TimeProfilingPassesHandler(`StandardInstrumentations.h:494-507`,实现 `StandardInstrumentations.cpp:1606-1632`)

- **门控**(`:1610-1611`):`if (!getTimeTraceProfilerInstance()) return;`——只有 `-time-trace` 已初始化 TimeProfiler 单例(`TimeProfiler.cpp:57-60` 的 `LLVM_THREAD_LOCAL TimeTraceProfiler *`)才注册回调,否则零开销;
- **回调极简**:`runBeforePass` → `timeTraceProfilerBegin(PassID, getIRName(IR))`(`:1628-1630`);`runAfterPass` → `timeTraceProfilerEnd()`(`:1632`);
- **注册 5 类回调**(`:1612-1625`),与 TimePasses 相同的五个点,但 **after 三个回调全部 `ToFront=true`**(参数见 `:1614-1625` 的尾参 `true`)——配合"最后注册"保证 `timeTraceProfilerEnd` 在其他 after 回调之前执行、不计入它们的开销(§10.3.1 注释);
- **analysis 也计时**(`:1622-1625`):begin/end 用同一对函数,事件名就是 analysis 类名——这就是 time-trace JSON 里 `TargetIRAnalysis` 等事件的来源。

**与 TimeProfiler 的集成**(`llvm/include/llvm/Support/TimeProfiler.h:110-201`):

- `timeTraceProfilerInitialize(Granularity, ProcName)`(`:119`)由工具驱动调用——opt 在 `optdriver.cpp:242-305` 的 `TimeTracerRAII`(`:297-…`)中:`-time-trace` 开 `-time-trace-granularity`(默认微秒级过滤)初始化,析构时 `timeTraceProfilerWrite(TimeTraceFile, OutputFilename)`(`:305`);
- clang 用 `-ftime-trace[=file]`(前端选项,实测 §10.8.7 生成 `inst-clang-timetrace.json`,含 `Frontend`/`RunPass`/各 pass 事件);
- 事件格式是 **Chrome Trace Event Format**:完整事件(`ph:"X"`,带 ts/dur)+ 进程/线程元事件(`ph:"M"`)+ **总计事件**(`name:"Total <X>"`,args 带 `count`/`avg ms`,实测 JSON 尾部,见 §10.8.4);
- 过滤:`TimeTraceGranularity` 微秒以下的事件不写入(`TimeProfiler.cpp:188-189`)。

### 10.3.5 VerifyInstrumentation(-verify-each)与 PrintCrashIRInstrumentation

**VerifyInstrumentation**(`StandardInstrumentations.h:482-489`,实现 `:1492-1549`):

- 只注册 `AfterPassCallback`(`:1494`);
- 跳过管理类 pass 与 VerifierPass 自身(`:1496`);
- 按 IR 单元类型分派:Function → `verifyFunction`(`:1508`);Loop → 取其父函数再 verify(`:1500-1501`);Module/SCC → `verifyModule`(`:1523`);MachineFunction → `MachineVerifierPass` 或 `verifyMachineFunction`(`:1529-1546`);
- 失败即 `report_fatal_error("Broken function found after pass \"X\"…")`(`:1509-1511`)——**直接终止编译**,这使 `-verify-each` 成为定位"哪个 pass 搞坏 IR"的二分工具;
- 仅在 `StandardInstrumentations` 构造时 `VerifyEach=true` 才注册(`:2557-2558`),该值由 opt 的 `VK == VerifierKind::EachPass`(`NewPMDriver.cpp:463-464`)或 clang 的 `CodeGenOpts.VerifyEach`(`BackendUtil.cpp:893-896`)传入。

**PrintCrashIRInstrumentation**(`StandardInstrumentations.h:586-602`,实现 `:2490-2546`):`-print-on-crash` / `-print-on-crash-path`(`:105-113`)启用;`registerBeforeNonSkippedPassCallback` 把每个 pass 运行前的 IR 存进 `SavedIR` 字符串(`:2533-2545`);`sys::AddSignalHandler(SignalHandler, nullptr)`(`:2530`)注册信号处理器,crash 时 `reportCrashIR()`(`:2493-2503`)把最后一次保存的 IR 打到 stderr 或文件。

---

## 10.4 -print-changed 过滤家族:枚举与实现位置

枚举 `ChangePrinter`(`PrintPasses.h:21-31`,共 9 个值含 `None`)与命令行映射(`PrintPasses.cpp:75-93`):

| 命令行值 | 枚举 | 实现类 | 注册条件(行号) | 输出 |
|---|---|---|---|---|
| (无值) | `Verbose` | IRChangedPrinter | `:526-527` | 完整 after IR + 初始 IR + no-change/filtered 提示 |
| `quiet` | `Quiet` | IRChangedPrinter | `:526-527` | 仅变更时的完整 after IR |
| `diff` | `DiffVerbose` | InLineChangePrinter | `:1599` | patch 式 +/- 行 + verbose 提示 |
| `diff-quiet` | `DiffQuiet` | InLineChangePrinter | `:1600` | 仅 patch 式 +/- 行 |
| `cdiff` | `ColourDiffVerbose` | InLineChangePrinter | `:1601` | 同 diff + ANSI 颜色 |
| `cdiff-quiet` | `ColourDiffQuiet` | InLineChangePrinter | `:1602` | 同 diff-quiet + ANSI 颜色 |
| `dot-cfg` | `DotCfgVerbose` | DotCfgChangeReporter | `:2461-2462` | CFG 网页(dot→pdf+passes.html) |
| `dot-cfg-quiet` | `DotCfgQuiet` | DotCfgChangeReporter | `:2461-2462` | 同上但 quiet |

配套过滤选项(全部 `PrintPasses.cpp`):`-filter-passes`(`:114-118`)、`-filter-print-funcs`(`:120-125`)、`-filter-print-source-locs`(`:127-129`)、`-print-module-scope`(`:100-104`)、`-print-before-changed`(`StandardInstrumentations.cpp:64-67`,额外打 before IR)、`-print-changed-diff-path`(`PrintPasses.cpp:96-98`)。

**quiet 与 verbose 的统一实现机制**:`TextChangeReporter::VerboseMode` 字段(`StandardInstrumentations.h:262`)在每个"旁支"事件(初始 IR、no-change、filtered、ignored、invalidated)的入口处检查(`:405-407`,`:430-431`,`:436-437`,`:445-446`,`:462-463`)——quiet 不是"少打印",而是**同一套代码路径下跳过非变更事件**。

---

## 10.5 -time-passes 与 -time-trace 输出结构

### 10.5.1 -time-passes(实测:scratch/inst-time-passes.txt,138 行)

输出**两张表**,顺序为 Analysis 在前、Pass 在后(`PassTimingInfo.cpp:212-213` 先打 PassTG 再打 AnalysisTG——**注意**:代码先 `PassTG.print` 后 `AnalysisTG.print`,但实测文件里 Analysis 表在前,因为 `print()` 由 static 析构/`reportAndResetTimings` 触发顺序决定;此处实现细节 **待验证** 触发点。表头格式):

```text
===-------------------------------------------------------------------------===
                        Analysis execution timing report
===-------------------------------------------------------------------------===
  Total Execution Time: 0.0006 seconds (0.0007 wall clock)

   ---User Time---   --System Time--   --User+System--   ---Wall Time---  ---Instr---  --- Name ---
   0.0000 (  5.8%)   0.0000 ( 32.3%)   0.0000 (  8.9%)   0.0002 ( 27.8%)     240924  BlockFrequencyAnalysis
   ...
===-------------------------------------------------------------------------===
                          Pass execution timing report
===-------------------------------------------------------------------------===
  Total Execution Time: 0.0092 seconds (0.0259 wall clock)
   ---User Time---   --System Time--   --User+System--   ---Wall Time---  ---Instr---  --- Name ---
   0.0004 (  7.0%)   0.0018 ( 53.1%)   0.0022 ( 24.0%)   0.0115 ( 44.2%)   12736224  SLPVectorizerPass
   ...
```

每张表按 Wall Time 降序,列含 User/System/User+System/Wall/指令数(`---Instr---` 列是 Timer 的 instruction 计数,Darwin 上由 `ptrace` 替代品提供)。

### 10.5.2 -time-trace(实测:scratch/inst-time-trace.json,19 KB,161 事件)

Chrome Trace Event JSON,顶层 `{"traceEvents":[...], "beginningOfTime":<微秒时间戳>}`。事件三类:

```json
{"pid":86160,"tid":259,"ts":2005,"ph":"X","dur":532,"name":"Verifier"}
{"pid":86160,"tid":259,"ts":4795,"ph":"X","dur":525,"name":"EarlyCSEPass","args":{"detail":"caller"}}
{"cat":"","pid":86160,"tid":259,"ts":0,"ph":"M","name":"process_name","args":{"name":"opt"}}
```

- **`ph:"X"`** = Complete Event,`ts` 起始微秒、`dur` 时长微秒、`args.detail` 是 IR 单元名(函数名或 `[module]`)——对应 `timeTraceProfilerBegin(PassID, getIRName(IR))`(`StandardInstrumentations.cpp:1629`)的两个参数;
- **`ph:"M"`** = Metadata 事件(进程名/线程名);
- **`name:"Total <X>"`** 汇总事件(实测尾部):`{"name":"Total InstCombinePass","args":{"count":3,"avg ms":0}}`——按名字聚合调用次数与平均毫秒。

嵌套结构天然反映 PM 层级:`ModuleToFunctionPassAdaptor` 事件的 ts/dur 包住内部 `PassManager<Function>` 再包住 `EarlyCSEPass`(实测 6153/7489 一带)。

---

## 10.6 opt-bisect 实测与设计总结

实测 `scratch/inst-opt-bisect2.txt`(121 行):`-opt-bisect-limit=2` 时,

```text
BISECT: running pass (1) memprof-remove-attributes on [module]
BISECT: running pass (2) annotation2metadata on [module]
BISECT: NOT running pass (3) forceattrs on [module]
BISECT: NOT running pass (4) inferattrs on [module]
BISECT: NOT running pass (5) lower-expect on foo
...
BISECT: NOT running pass (121) rel-lookup-table-converter on [module]
```

三个可验证结论:

1. **编号连续跨 IR 单元类型**(:module 与 function 混编同一计数器,`OptBisect.cpp:100` 的全局 `LastBisectNum`);
2. **打印的是管道名**(simplifycfg/early-cse),验证 `getPassNameForClassName` 转换链(§10.1.2);
3. **`on <IRName>`** 段来自 `getIRName(IR)`(`StandardInstrumentations.cpp:1094` → `OptBisect.cpp:113` 的 `printPassMessage` 打印 `TargetDesc`)。

`-opt-bisect-print-ir-path`(`StandardInstrumentations.cpp:115-117` + `OptPassGateInstrumentation::shouldRun` 的 `:1095-1106`):第一次有 pass 被跳过时把当前模块 IR dump 到指定文件——用于"跳过点快照"。

**legacy PM 兼容**:§10.2.4 已述——同一全局 `OptBisect` 单例,legacy 各 pass 基类自调 `shouldRunPass`,编号与新 PM 共享。

---

## 10.7 PassBuilder 与工具侧注册路径

**两条入口路径**(行号已核实):

- **opt**(`llvm/tools/opt/NewPMDriver.cpp`):
  - `:459` `PassInstrumentationCallbacks PIC;`
  - `:460-462` 配置 `PrintPassOpts`(Verbose/SkipAnalyses 按 DebugPM 等级);
  - `:463-464` `StandardInstrumentations SI(M.getContext(), DebugPM != None, VK == VerifierKind::EachPass, PrintPassOpts);`
  - `:465` `SI.registerCallbacks(PIC, &MAM);`
  - `:466-479` Debugify 系列(可选,`-debugify-each` / `-verify-debuginfo-preserve`);
  - `:488` `PassBuilder PB(TM, PTO, P, &PIC);` —— **PIC 在这里交给 PassBuilder**。

- **clang**(`clang/lib/CodeGen/BackendUtil.cpp`):
  - `:889` `PassInstrumentationCallbacks PIC;`
  - `:890-892` `PrintPassOpts.Indent/SkipAnalyses = DebugPassStructure`(即 `-fdebug-pass-structure`);
  - `:893-896` `StandardInstrumentations SI(TheModule->getContext(), CodeGenOpts.DebugPassManager || DebugPassStructure, CodeGenOpts.VerifyEach, PrintPassOpts);`
  - `:897` `SI.registerCallbacks(PIC, &MAM);`
  - `:898` `PassBuilder PB(TM.get(), PTO, PGOOpt, &PIC, CI.getVirtualFileSystemPtr());`

**PassBuilder 构造函数**(`PassBuilder.cpp:590-639`):`:598` `PIC->registerClassToPassNameCallback(...)`,lambda 体内用 `PassRegistry.def` 宏展开为全量 `addClassToPassName` 调用(`:602-637`,含 MachinePassRegistry.def,`:630-637`)。

**PassInstrumentationAnalysis 的注册**:`PassRegistry.def:37`(`MODULE_ANALYSIS("pass-instrumentation", PassInstrumentationAnalysis(PIC))`)、`:315`(CGSCC)、`:377`(FUNCTION)、`:770`(LOOP)——由 `registerModuleAnalyses`(`PassBuilder.cpp:732-739`)等四个方法宏展开注册到各 AM;工具侧在 buildDefaultPipeline 前调用(`NewPMDriver.cpp` 后续 `PB.registerModuleAnalyses(MAM)` 等)。`PIC` 是 PassBuilder 成员(`PassBuilder.cpp:594` 初始化),因此 lambda 捕获的正是用户传入的那个 PIC。

---

## 10.8 实测矩阵(2026-09-30,macOS arm64,build-debug)

输入统一为 `scratch/inst-input.ll`(3 函数:foo/bar/caller)。

| # | 命令 | 产物文件 | 结果 |
|---|---|---|---|
| 1 | `opt -passes='default<O2>' -print-changed=quiet` | `inst-print-changed-quiet.txt` | 85 行;首条 `*** IR Dump After SimplifyCFGPass on bar ***` + 完整 after IR;无初始 IR、无 no-change 行——quiet 语义成立 |
| 2 | `opt -passes='default<O2>' -print-changed=diff-quiet` | `inst-print-changed-diff-quiet.txt` | 190 行,**几乎全是 `diff: unrecognized option '--old-line-format=-%l'` 错误**——macOS BSD diff 不支持 GNU 行格式选项,验证 `doSystemDiff` 的外部 diff 依赖(`PrintPasses.cpp:400-406`) |
| 3 | `opt -passes='default<O2>' -time-passes` | `inst-time-passes.txt` | 138 行;Analysis 表(35 项,BlockFrequencyAnalysis 居首)+ Pass 表(SLPVectorizerPass 44.2% wall 居首);列含 User/System/U+S/Wall/Instr |
| 4 | `opt -passes='default<O2>' -time-trace -time-trace-file=...` | `inst-time-trace.json` | 19 KB,161 事件;`ph:"X"` 事件带 `args.detail`(IR 单元名);尾部有 `Total <name>` 聚合(count/avg ms)与 `ph:"M"` 元事件;顶层含 `beginningOfTime` |
| 5 | `opt -passes='default<O2>' -opt-bisect-limit=2` | `inst-opt-bisect2.txt` | 121 行 BISECT 日志;pass (1)(2) running、(3)-(121) NOT running;打印管道名;编号跨 module/function 连续 |
| 6 | `clang -O2 -mllvm -print-changed=quiet -c x.c` | `inst-clang-print-changed.txt` | 354 行,**可用**;首条 `*** IR Dump After InferFunctionAttrsPass on [module] ***`——验证 BackendUtil.cpp:893-897 注册路径对 `-mllvm` 生效 |
| 7 | `opt -passes='default<O2>' -verify-each` | `inst-verify-each.txt` | 0 行输出,exit 0——正常 pass 下静默;Verify 回调仅在 IR 损坏时 fatal |
| 8 | `clang -O2 -ftime-trace=...json -c x.c` | `inst-clang-timetrace.json` | 165 事件,含 `Frontend`/`RunPass`/`CodeGenPasses`/各 pass 与 `Total *Analysis` 聚合事件——clang 前端与新 PM 事件共一个 JSON |
| 9 | `opt -passes='default<O2>' -debug-pass-manager` | `inst-debug-pm.txt` | 500 行;`Running pass: SROAPass on foo (4 instructions)` / `Running analysis: DominatorTreeAnalysis on foo` / `Invalidating analysis: ...` 全三类事件——PrintPassInstrumentation 的全回调注册证据 |

---

## 10.9 自查表

| 断言 | 证据(文件:行号) | 状态 |
|---|---|---|
| PassInstrumentationCallbacks 类定义在 PassInstrumentation.h:67 | `llvm/include/llvm/IR/PassInstrumentation.h:67` | 已核实 |
| PassInstrumentation 类定义在 :199 | 同文件 `:199` | 已核实 |
| 9 类回调 typedef 于 :79-87 | 同文件 `:79-87` | 已核实 |
| runBeforePass 的 skip 逻辑(一票否决+两分支) | 同文件 `:226-245` | 已核实 |
| AfterPassInvalidated 不带 IRUnit | 同文件 `:83`、注释 `:71-78` | 已核实 |
| ClassToPassName 惰性触发 | `llvm/lib/IR/PassInstrumentation.cpp:25-36` | 已核实 |
| PassManager::run 的 PI 调用点 | `llvm/include/llvm/IR/PassManagerImpl.h:62-64/73/80/84` | 已核实 |
| ModuleToFunctionPassAdaptor 独立调用点 | `llvm/lib/IR/PassManager.cpp:135/145/153/155` | 已核实 |
| Analysis 四个调用点 | `PassManagerImpl.h:145/155/220-221/116-117` | 已核实 |
| PIA 自举保护(ID != PIA::ID) | `PassManagerImpl.h:142-146` | 已核实 |
| PassInstrumentationAnalysis::invalidate 恒 false | `PassInstrumentation.h:310-314` | 已核实 |
| OptBisect 单例/计数/区间/DisabledPasses | `llvm/lib/IR/OptBisect.cpp:26-29/96-115`、`include/llvm/IR/OptBisect.h:99-103` | 已核实 |
| legacy skipFunction 共用 gate | `llvm/lib/IR/Pass.cpp:196-212`、`llvm/lib/Analysis/LoopPass.cpp:387-389` | 已核实 |
| StandardInstrumentations 14 成员 | `llvm/include/llvm/Passes/StandardInstrumentations.h:607-621` | 已核实 |
| registerCallbacks 顺序与 TimeProfiling 尾部注册注释 | `llvm/lib/Passes/StandardInstrumentations.cpp:2548-2574` | 已核实 |
| print-changed 8 值映射 | `llvm/lib/IR/PrintPasses.cpp:75-93` | 已核实("cd" 拼写不存在,实际为 cdiff/cdiff-quiet;历史别名**待验证**) |
| doSystemDiff 用 GNU diff --*-line-format | `PrintPasses.cpp:382-420` | 已核实 + macOS 实测复现失败(#2) |
| InLineChangePrinter 结构化比较 report() | `StandardInstrumentations.cpp:607-677` | 已核实 |
| TimePasses 双 TimerGroup/双栈 | `llvm/lib/IR/PassTimingInfo.cpp:168-323`、`include/llvm/IR/PassTimingInfo.h:62-91` | 已核实 |
| TimeProfilingPasses 的 ToFront 注册 | `StandardInstrumentations.cpp:1612-1625` | 已核实 |
| time-trace JSON 含 ph:X/ph:M/Total 事件 | `llvm/lib/Support/TimeProfiler.cpp:129-…` + 实测 #4/#8 | 已核实 |
| opt 注册路径 | `llvm/tools/opt/NewPMDriver.cpp:459-488` | 已核实 |
| clang 注册路径 | `clang/lib/CodeGen/BackendUtil.cpp:889-898` | 已核实 + 实测 #6 |
| PassBuilder 注册 Class2PassName lambda | `llvm/lib/Passes/PassBuilder.cpp:598-638` | 已核实 |
| PassInstrumentationAnalysis 四处注册 | `llvm/lib/Passes/PassRegistry.def:37/315/377/770` | 已核实 |
| -time-passes 输出两表顺序(Analysis 在前) | 实测 #3;代码 `PassTimingInfo.cpp:212-213` 先 PassTG 后 AnalysisTG,顺序差异机制**待验证**(疑与 static 析构/打印触发时机有关) | 部分待验证 |
