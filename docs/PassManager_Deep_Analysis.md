# Pass 管理器深入分析

> 基准：llvm-project main @ `3eda2aebadd4`（2026-09-28 检出）；动态验证一律用本仓库 `build-debug`（Debug+Assertions）下的 `opt`/`llc`/`clang`。
> 姊妹篇：《AMDGPU_Deep_Analysis.md》纵向拆解一个 target；本文横向拆解承载所有 pass 的执行框架。
> 素材层：`PassManager-notes/00-12-*.md`（逐章原始素材、实测输出与自查表，全部 file:line 亲验）；本文是正文层，成文时逐条核对素材断言。想看实测原始输出的，去素材层。
>
> 三个上层问题：① 一条 `-passes="..."` 文本如何变成可执行对象图（解析→装配→校验）；② 分析结果的缓存与失效如何驱动 pass 重跑（PreservedAnalyses 契约——新 PM 的核心创新）；③ IR 层新 PM 与 CodeGen 层双 PM 并存的现实格局。

## 目录

1. 双 PM 并存格局
2. 核心抽象：没有虚函数的 pass 体系
3. AnalysisManager：惰性缓存与失效引擎
4. PreservedAnalyses 契约（技术重心）
5. 四 IRUnit 适配器
6. LazyCallGraph
7. PassBuilder：文本到对象图
8. EP 扩展点与插件
9. legacy PM
10. 插桩体系
11. AMDGPU 案例（连接姊妹篇）
12. 复现手册

---

## 1. 双 PM 并存格局

### 1.1 2026 年的真实分工

main 上两套 PM（legacy：`LegacyPassManager.cpp` 1808 行；new：`PassManager.h` + `CodeGenPassBuilder.h`）的分工**不是**"IR 用新、CodeGen 用旧"这么干净：

| 编译阶段 | 默认 PM | 依据 |
|---|---|---|
| opt 的 IR 管线（`-O#`/`-passes`） | **new PM** | `optdriver.cpp:463-464`；legacy 分支显式拒绝 `-O#`（:812-814） |
| clang `-c` 的 CodeGen | **target 决定，默认 legacy** | `RunCodeGen.cpp:103-110` 按 `TM.shouldDefaultToNewPM()` 分叉；基类默认 false（`TargetMachine.h:512`） |
| llc 的 CodeGen | **target 决定，默认 legacy** | `llcdriver.cpp:744-746` 同样咨询 `TM->shouldDefaultToNewPM()`——Lanai/MSP430 在 llc 下也默认新 PM；`-enable-new-pm`（`EnableNewPassManager`，:219-221，`cl::init(false)`）或 `-run-pass` 强制切新 PM（:743-752） |

分叉点是全仓库唯一一处：`llvm/lib/Passes/RunCodeGen.cpp:97-111`（**不在 clang 里**——`clang/lib/CodeGen/RunCodeGen.cpp` 不存在，clang 的 `BackendUtil.cpp:1194-1225` 只是调用方）。`-force-new-pm-codegen` 对应三态 `ForceNewPM`（:28-32，默认 UNSET），真正决定路径的是 `shouldDefaultToNewPM()`——**全仓库仅 Lanai（`LanaiTargetMachine.h:63`）与 MSP430（`MSP430TargetMachine.h:59`）override 为 true**。

一句话：**opt 已完成切换；clang/llc 的 CodeGen 处于"新 PM 接口已在 10 个 target 实现（NVPTX/Lanai/SPIRV/WebAssembly/MSP430/X86/AMDGPU（含 R600，`R600TargetMachine.h:41`）/RISCV/BPF——AMDGPU 主 GCN 与 R600 各算一家），但默认路径仍由 legacy 提供"的过渡态**。强制未迁移 target 走新 PM 会拿到基类的 `make_error("buildCodeGenPipeline is not overridden")`（`TargetMachine.h:501-508`，实测 AArch64 llc/clang 均复现）。

### 1.2 legacy 侧总装：addPassesToGenerateCode

`llvm/lib/CodeGen/CodeGenTargetMachineImpl.cpp:114-140` 是 legacy CodeGen 管线的总装函数：`TM.createPassConfig(PM)`（target 多态入口，AMDGPU 返回 GCNPassConfig）→ PassConfig 本身作为 ImmutablePass 入 PM（:124）→ TLI/RuntimeLib 注入（:129-131）→ `addISelPasses()`（:135，IR 段：addIRPasses→addCodeGenPrepare→addISelPrepare→addCoreISelPasses）→ `addMachinePasses()`（:137，机器段）→ `setInitialized()`（:138）——此后 PassConfig 不可变，任何 setter 触发 assert。

`addPassesToEmitFile`（:229-252）在此之后还有两个收尾动作：`willCompleteCodeGenPipeline()`（`TargetPassConfig.cpp:678-680`，即没给 `-stop-before/-stop-after`）时挂 AsmPrinter，否则挂 `createPrintMIRPass`（.mir 截断输出）；最后强制 `createFreeMachineFunctionPass()`（:250）回收 MachineFunction。**AsmPrinter 不入 PassConfig**——它由 target 创建、`addAsmPrinter`（:142-162）直接挂 PM。

### 1.3 TargetPassConfig vs CodeGenPassBuilder

两套 hook 逻辑等价、形态相反（完整对照表见素材 01 §1.5.1，28 行 × 12 维）：

- **legacy `TargetPassConfig`**：`addPass(AnalysisID)`（`TargetPassConfig.cpp:784-802`）经 `PassRegistry` 运行时创建——`getPassSubstitution`（target 替换表）→ `overridePass`（命令行覆盖）→ `Pass::createPass(FinalPtr.getID())`。替换/插入/禁用三件套：`substitutePass`（:211）/`insertPass`（:214，只在 `Impl->InsertedPasses` push 一条记录，消费点在 `addPass` 的 `:763-765` 循环）/`disablePass`（置空）。AMDGPU legacy 侧 10 处 insertPass 全在 `AMDGPUTargetMachine.cpp:1841-1887`（:1841-1872 位于 RA 段，:1857 为 DetectDeadLanes 后插 DCE；:1875-1887 位于 MachineScheduler 之后的调度/优化段）；
- **new PM `CodeGenPassBuilder`**：**虚函数分发，不是 CRTP**（2024-02 commit `91e9e3175268` 改的，头注释 :83-85 明说动机是二进制体积——"the target-independent pipeline is emitted once for the whole build instead of once per target"）。`PassManagerWrapper`（:60-69）聚合 MPM/FPM/MFPM 三层，`flushFPMsToMPM` 把 function/machine pass 打包成 adaptor。`insertPass<TargetPassT>(InsertedPassT)`（:383-392）走 AfterCallbacks、`disablePass`（:376-380）走 BeforeCallbacks——**类型在编译期绑定，替代 AnalysisID 运行时查询**。

一个关键差异：legacy 的 `substitutePass` 允许"只换流水线中某个 pass 其他不动"，new PM 没有 等价物——必须 override 整个 hook 或组合 insertPass/disablePass。迁移历史五节点（素材 01 §1.7）：2013 立项（`7caea41545fc`）→ 7 年空窗 → 2020 CodeGen new PM 元年（MachineFunctionPassManager `911565d1085d` + CodeGenPassBuilder `480936e741d5`）→ 2024 定型（虚函数化 + MachineFunctionAnalysis `6ea0c0a28343`）。

---

## 2. 核心抽象：没有虚函数的 pass 体系

### 2.1 三层类型设计

文件头注释（`llvm/include/llvm/IR/PassManager.h:27-33`）自述设计哲学是 **concept-based polymorphism**（引 Sean Parent "Inheritance Is The Base Class of Evil"）：pass 没有虚函数、没有公共基类。落地为三层：

```text
用户层(静态类型)              类型擦除层(手工 vtable)               存储层
class MyPass                detail::PassConcept                  std::vector<
  : RequiredPassInfoMixin     (PassManagerInternal.h:41-102)        unique_ptr<PassConcept>>
  <MyPass> {                  ├ Name / IsRequired (数据)            (PassManager.h:250)
    PreservedAnalyses         ├ Destroy / Run / PrintPipeline
    run(...) {};              └ (3 个函数指针, 非虚函数)
  }                                ▲ 被detail::PassModel包装(按值持有真实 pass)
```

`PassConcept` 只有 5 个成员（`PassManagerInternal.h:58-70`）：demangled 名、isRequired 布尔、三个函数指针。`PassModel` 构造时把指针绑到自己的静态函数（`:108-146`），`runImpl` 一行转发（`:125-129`）——**run 必须返回 PreservedAnalyses 的执法点就在这里**：返回 void 会因"void 转 PA"在 addPass 实例化时编译失败，而非运行时检查（当前 PM 头文件里仅有的 2 处 static_assert 都是 mixin 的 CRTP 检查）。

2026-07 的 commit `6d12cf1389fa`（"Drop vtable from PassConcept/PassModel"）把原来的虚函数改成手工函数指针，动机写在类注释（`PassManagerInternal.h:37-40`）：vtable 在 PIC 构建下需要重定位、分发多一次间接。同一手法也用在 `AnalysisResultConcept`（2 个函数指针）与 `AnalysisPassConcept` 上。

### 2.2 mixin 家族与 2026 年的两次重构

| mixin | 位置 | 提供 |
|---|---|---|
| `detail::InfoMixin` | PM.h:62-71 | `name()`——`__PRETTY_FUNCTION__` 编译期子串切片（`Support/TypeName.h:42-86`），**不是 RTTI**，注释自认"仅供调试，不可当稳定标识" |
| `detail::PassInfoMixin` | PM.h:81-89 | `printPipeline()`；**已不提供 isRequired** |
| `RequiredPassInfoMixin` | PM.h:102-110 | `isRequired(){return true;}`（VerifierPass、PM 自身） |
| `OptionalPassInfoMixin` | PM.h:113-116 | `isRequired(){return false;}`（绝大多数优化 pass） |
| `AnalysisInfoMixin` | PM.h:122-144 | `ID()` 返回 `&DerivedT::Key`——Key 必须由派生类持有，原因见 PM.h:133-138 的 FIXME（Windows DLL 构建下模板静态变量地址不唯一） |

2026-05 的 commit `11729f768a05`（#192120）引入 Required/Optional 二分并要求显式继承——"很容易忘记给必须全跑的 pass 加 isRequired()；长期目标是 PassInfoMixin 没有默认 isRequired"。该 TODO 已兑现：PassInfoMixin 移入了 `llvm::detail`，公开层只剩二选一。`isRequired()` 的最终消费者是插桩跳过链（§10）：required pass 永不被 opt-bisect/optnone 跳过。

### 2.3 类型即身份的代价

`Passes` 是 vector，`addPass` 只 push_back（PM.h:223-229）——**没有按类型去重**。同类型 pass 加两次就是两个堆对象、各跑一次（实测 `function(instcombine),function(instcombine)`：第 2 个实例看到第 1 个优化后的 IR，且 DT 缓存命中只算一次）。后果：`-debug-pass-manager` 无法区分同类型两次运行，只能靠指令数间接分辨；llc 新 PM 下 `RAGreedyPass` 出现 3 次（AMDGPU 三段式 RA，§11）。同类型嵌套 PM 会被 addPass 展平（PM.h:236-241，注释明言避免同型嵌套的失效复杂性）。

### 2.4 MachineFunction 层：模板红利

`MachineFunctionPassManager` 就是 `PassManager<MachineFunction>` 的 typedef（`MachinePassManager.h:225`）——容器、type erasure、addPass 全部复用。差异仅三处：① `run` 显式特化（`MachinePassManager.cpp:143-160`），与 IR 主循环几乎逐行相同（少 StackTraceEntry）；② 基线 PA 由 `getMachineFunctionPassPreservedAnalyses()`（`:162-169`）给出 = none + 全保 Module/Function 两层集合（机器 pass 不许改 IR，§4.6）；③ `FunctionAnalysisManagerMachineFunctionProxy` 是唯一手写 proxy，`invalidate` 硬编码 false（`:37-43`，"MachineFunction passes should not invalidate Function analyses"）。除这两点外**零代码复制**。

---

## 3. AnalysisManager：惰性缓存与失效引擎

### 3.1 三张表与"地址即身份"

`AnalysisManager<IRUnitT>`（PM.h:279-581）内部三张表（`:566-580`）：

| 表 | key → value | 职责 |
|---|---|---|
| `AnalysisPasses` | `AnalysisKey*` → 类型擦除的分析 pass | 注册表（registerPass 铺设） |
| `AnalysisResultLists` | `IRUnitT*` → `SmallVector<pair<Key*, unique_ptr<Result>>>` | 结果的 **owner**，按 IR 聚合、保插入序 |
| `AnalysisResults` | `pair<AnalysisKey*, IRUnitT*>` → 裸指针 | O(1) 查询索引 |

**身份 = 地址**：分析身份是派生类 `static AnalysisKey Key` 的地址（如 `Dominators.cpp:343`），IR 身份是对象地址（头注释 PM.h:278 "the address of the IR unit suffices as its identity"）。推论：IR 对象不可移动、地址不可复用——module pass 删函数必须 `FAM.clear(F)`，否则 proxy 兜底全清。

### 3.2 getResult：惰性构造的三个坑

`getResultImpl`（`PassManagerImpl.h:131-166`）：`try_emplace` 占位 → 未命中才 lookUpPass+run。三个坑都有代码注释背书：① 分析 run 可递归触发其它分析导致 rehash，所以入表后必须**重新 find**（`:159`）而非复用旧迭代器；② 取插桩器本身也走 getResult，特判自举避免无限递归（`:143`）；③ `getCachedResult` 同构但**绝不触发计算**（PM.h:449-468）。

### 3.3 invalidate：三层算法

`AnalysisManager::invalidate`（`PassManagerImpl.h:168-230`）：

1. **快通道**（`:172`）：PA 保留了 `AllAnalysesOn<IRUnitT>` 集合 → 整个调用空转；
2. **逐结果判定（二选一，非双层）**（`:183-206`）：`AnalysisResultModel` 构造时安装的 lambda（`PassManagerInternal.h:248-257` 的 if constexpr）——结果类型**有**自定义 `Result.invalidate(IR, PA, Inv)` 就**直接委托**（此时 PA checker 不参与判定，结果须自行解释 PA 与分析依赖）；**没有**才走默认的纯 PA 判定（`!preserved() && !preservedSet<AllAnalysesOn<IRUnitT>>()`）。Invalidator 允许结果递归查询依赖并记忆化（PM.h:357-386，DFS + 依赖环断言 + stale-handle 断言："likely due to a stale result handle!"）；
3. **物理清除**（`:209-229`）：WriteIdx/ReadIdx 双指针原地压缩（避免逐个 erase 的 O(n²)），摘除前触发 `runAnalysisInvalidated` 插桩回调（`-debug-pass-manager` 的 "Invalidating analysis:" 行即源于此）；链表空则连 IR 项一起摘——AM 内存随使用收缩。

### 3.4 跨层代理：Inner 与 Outer

- **Inner proxy**（外层持有内层 AM，PM.h:609-695）：本身是外层的一个普通"分析"，Result 是 RAII——析构未收到 invalidate 则 `InnerAM->clear()`。`FunctionAnalysisManagerModuleProxy::Result::invalidate` 的特化（`PassManager.cpp:52-115`）三段：proxy 不保 → FAM 全清；逐函数查 Outer 登记表兑现**延迟失效**（外层分析死了 → 依赖它的内层分析被 abandon，`:92-96`）；否则逐函数转发失效。
- **Outer proxy**（内层只读回查，PM.h:740-853）：只暴露 `getCachedResult`——function pass 不许触发 module 分析的计算，注释（:725-733）明说这是**为了未来并发**（先算后跑与先跑后算结果不同，调度顺序不能影响语义）。失效联动靠登记：`registerOuterAnalysisInvalidation<OuterT,InnerT>`（:795-807）。生产者实例：AAManager 聚合 module 级 GlobalsAA 时登记（`AliasAnalysis.h:998-1006`）。
- **"Module 层缓存了函数分析"是错觉**：Module 层缓存的是 FAM 这个管理者（经 proxy Result），函数分析结果在 FAM 自己的三张表里。两个 `function(...)` adaptor 拿到的是同一个 FAM（`PassManager.cpp:130-131`），所以缓存跨 adaptor 存活（实测验证）。

### 3.5 注册与触发分离

`registerModuleAnalyses/registerFunctionAnalyses`（`PassBuilder.cpp:732-769`）经 PassRegistry.def 宏把全部分析类型铺进 AM——**注册 ≠ 计算**。文本 `require<domtree>` 在哪个层次就展开成哪个 IRUnit 的 `RequireAnalysisPass`：`function(require<domtree>)` 生成 `RequireAnalysisPass<DominatorTreeAnalysis, Function>`（FUNCTION_ANALYSIS 宏段 `PassBuilder.cpp:2450-2464`——`require<NAME>` 认出后 `FPM.addPass(RequireAnalysisPass<..., Function>())`；`:1942-1950` 附近的同名宏只是 isFunctionPassName 的名称识别；domtree 本属 Function 层，顶层裸写 `require<domtree>` 经 §7.2 的自动包裹下沉到 function 层执行；实测 `-debug-pass-manager` 打印 `RequireAnalysisPass<llvm::DominatorTreeAnalysis, llvm::Function, ...>`），其 run 才调 `getResult` 触发惰性构造。这就是"惰性"的完整含义：registerPass 备好类型，getResult 是唯一触发点。

实测要点（7 用例见素材 03 §3.7）：require 两次缓存命中；`invalidate<domtree>` 后重建；instcombine（保 CFGAnalyses）与 no-op（保 all）都不杀 domtree。**一个当初归因错误、已修正的现象**：`function(require<domtree>,invalidate<domtree>,require<domtree>)` 里 domtree 确实"算两次、失效两次"，但第二次失效**不是** VerifierPass 干的——两个 `VerifierPass::run` 都返回 `all()`（`Verifier.cpp:8427-8441`），且对照实验 `require→verify→require` 每函数只算一次 domtree（实测）。真实的机制链全在 adaptor 内部：① `invalidate<domtree>` 的 PA = `all()` + `abandon<domtree>`；② FPM 聚合 intersect 后 abandon 存活（主循环 `:80` 的 `AM.invalidate` 已处理过一次）；③ FPM 收尾 `PA.preserveSet<AllAnalysesOn<IRUnitT>>()`（`PassManagerImpl.h:95`）**不会摘除 abandon**（preserveSet 不做 NotPreserved 摘除，§4.1 不变量）；④ `ModuleToFunctionPassAdaptor` 拿到这个聚合 PA 后**立即对当前函数执行 `FAM.invalidate(F, EagerlyInvalidate ? none() : PassPA)`**（`PassManager.cpp:153`）——刚被第三个 require 重建的 domtree 再次被击穿，时机在**下一个函数开始之前**、模块级 Verifier 之前。第二次 "Invalidating analysis" 来自 adaptor 的这次逐函数失效，不是外层 Module PM 的收尾（收尾的 `preserveSet` 补偿 `:167` 反而是无害的）。这是 abandon 击穿集合保留（§4.1）在 adaptor 边界的再现。

---

## 4. PreservedAnalyses 契约（技术重心）

### 4.1 真实结构：双集合代数，不是"三态"

`llvm/include/llvm/IR/Analysis.h:112-327`。内部只有两个 SmallPtrSet：

```cpp
SmallPtrSet<void *, 2> PreservedIDs;                    // :317 保留的 analysis/set ID
SmallPtrSet<AnalysisKey *, 2> NotPreservedAnalysisIDs;  // :326 abandon 名单
```

- `all()` = 塞入特殊键 `&AllAnalysesKey`（`:314`，AnalysisSetKey）；`none()` = 空构造
- `areAllPreserved()`（`:292-295`）要求 **NotPreserved 为空且 All 键在**——abandon 击穿 all()
- `preserve(ID)`（`:139-148`）先从 NotPreserved 摘除再插入（不变量 :325：同一 ID 不在两集合共存）；`preserveSet`（`:157-162`）集合级保留不做摘除
- `abandon(ID)`（`:183-187`）= 从 PreservedIDs 移除 + 塞 NotPreserved——**单点否决权**，注释（:164-170）："not preserved, even if it is nominally covered by some other set"。注意 abandon 只能针对单个 analysis，不能针对 set
- `intersect`（`:193-229`）：保留下交集 + 不保留**并**集——PM 聚合语义的代数基础

查询侧 `PreservedAnalysisChecker`：`preserved()` = !IsAbandoned && (All || 显式)；`preservedSet<T>()` 同构；`preservedWhenStateless()`（`:258`）只查 !IsAbandoned——**无状态分析的免检通道**（§4.4）。

### 4.2 主循环三段论（PassManagerImpl.h:56-98，全文心脏）

```cpp
PreservedAnalyses PA = PreservedAnalyses::all();                // :56 聚合器初值
PassInstrumentation PI = ...getResult<PassInstrumentationAnalysis>(AM, IR);  // :62
for (auto &Pass : Passes) {
  if (!PI.runBeforePass<IRUnitT>(*Pass, IR)) continue;          // :73 插桩可否决执行
  PreservedAnalyses PassPA = Pass->run(IR, AM, ExtraArgs...);   // :76
  AM.invalidate(IR, PassPA);                                     // :80 逐 pass 立即失效
  PI.runAfterPass<IRUnitT>(*Pass, IR, PassPA);                  // :84
  PA.intersect(std::move(PassPA));                               // :88 聚合=连续 intersect
}
PA.preserveSet<AllAnalysesOn<IRUnitT>>();                       // :95 收尾补集合级保留
```

五个要点：① **逐 pass 立即失效**——下一个 pass 立刻看到干净世界（legacy 同样在 runOnXxx 返回后即处理失效——`LegacyPassManager.cpp:1457-1461` `verifyPreservedAnalysis`/`removeNotPreservedAnalysis`/`recordAvailableAnalysis`——真正差异不在时机而在粒度与模型，见 §9.4）；② **聚合 = 连续 intersect**——最保守成员决定整体；③ **收尾 preserveSet 补偿**——:80 已逐 pass 处理，AM 幸存结果天然有效，补集合标记避免上层重复失效——但注意这条补偿**通常**避免重复失效，**不能覆盖显式 abandon**：preserveSet 不做 NotPreserved 摘除（§4.1），聚合 PA 里存活的 abandon 会在上层用这份 PA 再次 invalidate 时继续击穿结果（§3.5 的第二次 domtree 失效即此形态——adaptor 拿着 FPM 聚合 PA 立即执行 `FAM.invalidate(F, PassPA)`，`PassManager.cpp:153`）；④ **插桩可否决 pass**——被跳过的 pass 连 invalidate 都不触发，零副作用；⑤ 插桩器本身是 analysis——走同一套缓存协议（其 invalidate 恒 false，`PassInstrumentation.h:310-314`，整个编译期缓存一次）。

### 4.3 结果自知协议

失效判定不是 AM 单方面宣判。`AnalysisResultModel` 构造时安装的 lambda（`PassManagerInternal.h:248-257`，见 §3.3 的二选一结构）：结果类型若自带 `invalidate(IR, PA, Inv)` 则委托，否则退化为纯 PA 判定（**默认路径不看 preservedWhenStateless**——豁免必须自己写 invalidate）。三个代表：

- **DominatorTree**（`Dominators.cpp:71-78`）：三层任一保留即活——显式 preserve / AllAnalysesOn\<Function\> / **CFGAnalyses**。凡声明"不动 CFG"的 pass 自动保住 domtree；
- **MemorySSA**（`MemorySSA.cpp:2376-2383`）：自己被保留 **且** `Inv.invalidate<AAManager>` 与 `Inv.invalidate<DominatorTreeAnalysis>` 都说依赖活着——结果内嵌依赖句柄时的递归判定；
- **preservedWhenStateless 家族**：`return !PAC.preservedWhenStateless()` 不是 GlobalsAA 的专利——AAResults（`AliasAnalysis.cpp:80-98`）、IR2Vec、DXILResource、LiveDebugVariables、RegisterUsageInfo 等十余处同款写法，凡自称无状态的分析都可走这条免检通道（`Analysis.h:258`）。GlobalsAA（`GlobalsModRef.cpp:825-831`，DeletionCallbackHandle 自清理）是其中最著名的例子：**none() 杀不死它，唯一杀死方式是 abandon**。

递归依赖的常见实例（均亲验）：SCEV 依赖 Assumption/DT/Loop；MemDep 依赖 AA/Assumption/DT；AAResults 逐个询问聚合进来的 AA（`AliasAnalysis.cpp:80-98`）——这就是"AAManager 不需要显式 preserve"的机制。

### 4.4 abandon 普查：25 处 / 17 文件，三种模式

- **模式 A 返回值层**（`all()` + `abandon<T>()`）：`InvalidateAnalysisPass`（PM.h:958-962，文本管线 `invalidate<x>` 的本体）；sanitizer 家族（MemorySanitizer.cpp:810-815、AddressSanitizer.cpp:1368 等）——MSan 注释原文："GlobalsAA is considered stateless and does not get invalidated unless explicitly invalidated; none() is not enough"；
- **模式 B pass 内就地手术**（abandon 后立即 `AM.invalidate` 继续跑）：IRCE 改完 CFG 定向废 Cycle/BFI（`InductiveRangeCheckElimination.cpp:928-931`）、MLInlineAdvisor 内联后废 caller 特征分析；
- **模式 C 类型擦除版**（proxy 基础设施专用，编译期不知外层 ID）：`PassManager.cpp:96`、`CGSCCPassManager.cpp:637/:740`——延迟失效的兑现点。

### 4.5 PA 撒谎的代价：看门狗（及其边界）

`PreservedCFGCheckerInstrumentation`（`StandardInstrumentations.cpp:1309-1488`）：pass 前存 StructuralHash/CFG 快照，after-pass 重算对比——**IR 变了但 PA 没失效 → `report_fatal_error`**（函数级 :1453-1456、CFG 级 :1465-1471 "does not invalidate CFG analyses but CFG changes detected"）。注册点在 `:2563-2565`（MAM 存在即调 `registerCallbacks`），但 `registerCallbacks` 第一行就是 `if (!VerifyAnalysisInvalidation) return;`（:1391-1393）。

**启用条件比"Debug 构建"苛刻**（这是常见的过度声明，包括本稿初版）：开关 `-verify-analysis-invalidation`（:52-59）**仅 `EXPENSIVE_CHECKS` 构建默认开**（`#ifdef` 三元 `cl::init`），普通 Debug 构建默认 OFF（本仓库 build-debug 的 `LLVM_ENABLE_EXPENSIVE_CHECKS:BOOL=OFF`，CMakeCache.txt:843 实证）——但可显式 `-verify-analysis-invalidation` 打开（Hidden 选项）。且它只覆盖**结构和 CFG 层面的保留承诺**：函数/模块 StructuralHash 与 CFG 快照的"变了没申报"，不验证任何具体分析结果的正确性——"声明保留 DT 但 DT 已错"这类谎言不在射程内。

准确表述：**启用该检查后（EXPENSIVE_CHECKS 构建或显式开旗），错误的结构/CFG 保留声明是硬错误；普通 Debug 构建默认不启用，静默脏读仍可能发生**。

历史 bug 的两阶段形态（git 考古）：2015-2019 集中在**基础设施自身**（adaptor/proxy 失效传播，如 c213c67df804 SCC 合并漏失效）；2020 后基本都是**单个 pass 的 PA 谎报**（aa6c305344e5 LowerMatrixIntrinsics、1ed53d44d8e9 LoopFlatten），靠看门狗在 CI（EXPENSIVE_CHECKS 配置）逮出。修复方向一律是改声明更老实，**不存在 verify-then-abandon 恢复模式**（全树 grep 无此机制）。

### 4.6 跨层与机器层

- **adaptor 的 PA 变换**（`PassManager.cpp:128-170`）：内层 PassPA 直接 intersect 进 Module 层聚合——**Function 层丢失传染成 Module 层丢失**；`EagerlyInvalidate` 分支（:153）对每函数立刻 `none()` 清场（文本拼写 `function<eager-inv>`）；收尾补 `preserveSet<AllAnalysesOn<Function>>` + proxy 保留（:167-168，与主循环 :95 同构补偿）；
- **CGSCC adaptor 独有承诺**（`CGSCCPassManager.cpp:514-584`）：只要聚合 PA 没保住 LazyCallGraphAnalysis，每个函数 pass 跑完都要走一遍调用图增量更新（可能拆小当前 SCC 并清理新 SCC 的函数分析，:776-806）；收尾三连里 `preserve<LazyCallGraphAnalysis>`（:581）="调用图我们一路维护过了"；
- **MachineFunction 层同构返回 PA**——纠正"机器 pass 不参与 PA 协议"的误解：主循环逐行对应（`MachinePassManager.cpp:143-160`）。真正差异是单向闸门：基线 PA 全保 IR 两层（:162-169），FAM→MF proxy invalidate 恒 false（:37-43）——机器层不回污 IR 分析，IR 分析也不因 MIR 变化失效。

---

## 5. 四 IRUnit 适配器

新 PM 的 IRUnit 五层：Module → LazyCallGraph::SCC → Function → Loop（MachineFunction 走 MIR 单独通道，§5.7）。相邻层之间是一个**手写 adaptor 类**：拿内层 AM（经 proxy）→ 遍历内层 IRUnit → 调被包装 PassConcept 的 run() → 处理"pass 改了图"的更新（worklist/重跑/invalidate）→ 把 PA 聚合成外层视角。

### 5.1 四大 adaptor 一览

| adaptor | 包装 | run() 入口 | 构造选项 |
|---|---|---|---|
| `ModuleToFunctionPassAdaptor` | module → function | `PassManager.cpp:128` | `EagerlyInvalidate` |
| `ModuleToPostOrderCGSCCPassAdaptor` | module → SCC | `CGSCCPassManager.cpp:142` | 无 |
| `CGSCCToFunctionPassAdaptor` | SCC → function | `CGSCCPassManager.cpp:514` | `EagerlyInvalidate` + `NoRerun` |
| `FunctionToLoopPassAdaptor` | function → loop | `LoopPassManager.cpp:193` | `UseMemorySSA` + `LoopNestMode` |

（定义位置：PM.h:878 / CGSCCPassManager.h:315/:441 / LoopPassManager.h:390。）两个 function 端 adaptor 复用同一个 `PassConcept<Function, FAM>`——触发上下文不同、签名相同。另两个的 PassConcept 携带 ExtraArgs（`LazyCallGraph&`、`CGSCCUpdateResult&`、`LoopStandardAnalysisResults&`、`LPMUpdater&`）——**跨层 pass 拿到的"图更新通道"就藏在 ExtraArgs 里**。adaptor 本身不是模板（模板性推给 `create*PassAdaptor` 工厂），所以能进 PassRegistry；都继承 RequiredPassInfoMixin（PM.h:879 等——容器永不 opt-bisect 跳过）。

### 5.2 ModuleToFunctionPassAdaptor：基准形态

run()（`PassManager.cpp:128-170`）逐函数：`isDeclaration` 跳过（:139）→ runBeforePass 可否决 → `Pass->run(F, FAM)` → **`FAM.invalidate(F, EagerlyInvalidate ? none() : PassPA)`**（:153，逐函数立即失效，不等整轮结束）→ runAfterPass → `PA.intersect`（:159）。收尾补 `preserveSet<AllAnalysesOn<Function>>` + FAM proxy（:167-168）——与主循环 ：95 同构的"我已处理完内层失效"补偿。

**独占访问契约**（PM.h:861-877 类注释）：function pass 对自己的函数有独占权，"**should not read or modify any other functions!**"——且注释附两处 FIXME 承认现存 pass 有违反。这是给未来函数级并行留的门，但 `for (Function &F : M)`（:138）目前仍是顺序遍历。

`function<eager-inv>` 即 EagerlyInvalidate 的文本拼写，O2 默认管线大量使用（`require<globals-aa>` 后紧跟 `function(invalidate<aa>)` 也是同思路——主动清缓存防脏读）。

### 5.3 ModuleToPostOrderCGSCCPassAdaptor：最复杂的一个

约 220 行（`CGSCCPassManager.cpp:142-365`），因为它要处理 LazyCallGraph 被 pass 反复改写的情况。**三层 worklist 嵌套**：

| 循环 | 退出条件 | 重排机制 |
|---|---|---|
| 最外：RefSCC | RCWorklist 空 | RefSCC 分裂出的新 RefSCC 插回 |
| 中：SCC | CWorklist 空 | SCC 拆分/合并的新 SCC 经 `UR.CWorklist` 插回 |
| 最内：SCC 精化 | `UR.UpdatedC == nullptr` | pass 改图后 UpdatedC 指向新形态，**立即重跑同一 pass** |

`CGSCCUpdateResult UR`（:169-175）是 pass 与 adaptor 的双向通道。成员分两类（CGSCCPassManager.h:247-303）：**四个引用成员**（CWorklist :247 / InvalidatedSCCs :255 / InlinedInternalEdges :289 / DeadFunctions :293）指向 adaptor 的局部变量——pass 写（`UR.DeadFunctions.push_back(...)`），adaptor 在循环边界读；**三个自有值成员**（UpdatedC 指针 :265 / CrossSCCPA 对象 :280 / IndirectVHs 容器 :303）由 UR 自身持有。三个独有机制：

1. **CrossSCCPA**（:251-265 注释）：SCC pass 声明"我动到了祖先 SCC 的 IR"的通道——adaptor 切换 SCC 时用它对下一个 SCC 做 `CGAM.invalidate`。普通 IRUnit PM 没有这种通道，只有"图可被 pass 改写"的 CGSCC 层需要；
2. **函数死删批处理**（:349-351）：pass 只 push 进 `UR.DeadFunctions`，adaptor 在**整条模块的 RefSCC 遍历全部结束后**（`while (!RCWorklist.empty())` 外层循环之外）统一 `removeDeadFunctions` + `eraseFromParent`——不是每条 RefSCC 结束时；批删避免迭代中途破坏迭代器；
3. **postorder 语义**：被调用方先优化（实测 `a→b→c→a` 三节点 SCC 与 `(main)` 的遍历序，scratch/lcg-scc-traversal.txt）。

### 5.4 CGSCCToFunctionPassAdaptor：SCC 可变防御

run()（`CGSCCPassManager.cpp:514-584`）与 5.2 的核心差异：① **`CurrentC` 会漂移**——函数 pass 跑完若 PA 没保住 LazyCallGraphAnalysis（:564-565），调 `updateCGAndAnalysisManagerForFunctionPass`（:881-1180，约 300 行：扫描 call/invoke 比对 Edge，识别保留/提升/降级/新增四种情况，处理 SCC 分裂与合并）；② **跨 SCC 跳跃防御**：`if (CG.lookupSCC(*N) != CurrentC) continue;`（:536）——node 已被移去别的 SCC 就跳过，等那边访问；③ **NoRerun**（:541-542）：FAM 缓存有 `ShouldNotRunFunctionPassesAnalysis` 就跳过——防"函数因 SCC 重写被多访"时重复跑昂贵管线。

这是**新 PM 唯一允许 function pass"间接"改 call graph 的通道**——function pass 手里没有 LCG 的 mutation API，但 PA 会被 adaptor 检测，代为同步。O2 里文本拼写为 `function<eager-inv;no-rerun>(...)`（printPipeline 在 CGSCCPassManager.h:470-486）——SCC 重写时立刻丢缓存 + 重访不重跑，两个选项都开。

### 5.5 FunctionToLoopPassAdaptor：唯一自带内嵌 FPM

四个中唯一**内嵌 `FunctionPassManager LoopCanonicalizationFPM`** 的（LoopPassManager.h:415-420）：

1. **构造时强制注入 LoopSimplify + LCSSA**（:402-403）——任何 `loop(...)`/`loop-mssa(...)` 管线跑用户 pass 前先跑这两个 canonicalization pass。这是头注释（LPM.h:14-27）五条不变量的第 1、2 条（"loops are where possible simplified"、"always LCSSA"）；
2. **LoopStandardAnalysisResults 七项强制注入**（LoopPassManager.cpp:220-227）：AA/AC/DT/LI/SE/TLI/TTI（+可选 MSSA）一次 braced-init 拉齐——**loop pass 不再自己 require，直接经第 3 参数 `AR` 拿**。loop pass 经 `AM` 取的是 LAM 缓存的 loop analysis，经 `AR` 取的是 function 级分析引用，两个 AM 不混；
3. **主循环**（:270-322）：worklist pop → Updater 重置 → run → **MSSA 契约的入口检查**：`LAR.MSSA && !PassPA.getChecker<MemorySSAAnalysis>().preserved()` 直接 `reportFatalUsageError`（:296-298）。注意其边界：这是**拒绝"未声明保留 MemorySSA"的 pass**，即强制你老实申报；**它不验证 MSSA 内容本身**。具体一致性有独立入口：未定义 NDEBUG 且 `LAR.MSSA && VerifyMemorySSA` 成立时，逐 pass 调 `LAR.MSSA->verifyMemorySSA()`（`LoopPassManager.cpp:300-309`）——`VerifyMemorySSA` 默认仅 EXPENSIVE_CHECKS 构建为 true（`MemorySSA.cpp:81-90`），否则需显式 `-verify-memoryssa`。LCSSA 则是 Debug 断言（:255-267 注册 before-pass 回调逐 pass 验证 `isRecursivelyLCSSAForm`——这个方向是真实重验，与 MSSA 的声明检查不同）；
4. **postorder 执行序**（实测 scratch/adapt-loop-order.txt）：`inner1 → inner2 → outer`——内层先于外层，机制是 `appendReversedLoopsToWorklist`（LoopUtils.cpp:2045-2086）preorder DFS 反转进 LIFO worklist；
5. **缓存红利实测**（scratch/adapt-loop-two-adaptors.txt）：两个连续 `loop(...)` 段，第 2 段重跑 LoopSimplify/LCSSA（它们不互相保留）**但 DT/AA/SE/AC 全命中缓存**——LAR 的设计红利：loop 管线内 function 级分析稳定，直接复用。

### 5.6 LPMUpdater：loop nest 更新通道

第 4 个 ExtraArg（LPM.h:218-350）。三个接口对应三种结构变化：`markLoopAsDeleted`（LAM 立即清该 loop 缓存 + SkipCurrentLoop）、`addChildLoops`（**CurrentL 重新入 worklist 保证子先于父**）+ `addSiblingLoops`、`revisitCurrentLoop`。loop-nest 模式下另有 `LoopNestPtr` 惰性重建（LPM.cpp:100-106：仅 `isLoopNestChanged()` 或前一个 pass 的 PA 没保 LoopNestAnalysis 时重建）。parent-loop 跟踪只在 `LLVM_ENABLE_ABI_BREAKING_CHECKS` 下有意义（release 下 setParentLoop 为空，ParentL 只喂 assert）——**纯 debug 正确性装置，不影响 release 行为**。

### 5.7 MachineFunction 层为何没有通用 adaptor

只有 `FunctionToMachineFunctionPassAdaptor` 一个手写 adaptor（MachinePassManager.h:191，run 在 MachinePassManager.cpp:111-134）。两个原因：IR 层 module pass 进 MIR 必须经 function，这一个 adaptor 已够；MIR 没有跨 function 的 SCC/loop 结构（SelectionDAG 在每个 function 内部独立）。与 §2.4 的三个手写 proxy 配套——**MachineFunction 层选"少量手写 proxy + 一个手写 adaptor"，放弃模板普遍性，换 invalidate 语义的精细控制**。

---

## 6. LazyCallGraph

CGSCC 层的 IRUnit 是 `LazyCallGraph::SCC`（PM 第五种 IRUnit，`IRUnitKindTraits` 特化 LCG.h:1258-1260）。为什么不用普通 CallGraph：① 优化过程会改图（内联删边、devirt 升级边、函数删除拆 SCC），图必须可增量维护；② **ref 边先于 call 边被观察到**——函数指针引用在调用边形成前就存在，ref 图是 call 图超集（LCG.h:118-125 类注释原文），保守近似从 ref 图出发、call 边升级时再收窄；③ postorder 遍历让被调用方先优化，内联进来的已是最优形态。

### 6.1 双边模型与惰性构建三级

`Edge`（LCG.h:128-176）是 tagged pointer（`Kind : bool { Ref=false, Call=true }`）。两层结构：**RefSCC**（:540）是 ref 图 SCC、全图重排单元（内部持 postorder 的 SCC 列表）；**SCC**（call 图上）是真正跑 pass 的单元。Node 像 optional——但**惰性构建的触发点是显式 `populate()`**（LCG.h:362-367：`if (Edges) return *Edges; return populateSlow();`），`operator*`/`operator->`（:344-348）只取不建——"首次解引用自动建边"是错的，边未建时解引用是未定义行为（assert）。遍历者必须先调 populate（`buildGenericSCCs` 的展开回调 :1940-1942 就是这么做的）。

惰性三级：① `LazyCallGraphAnalysis::run`（LCG.h:1276-1284）只建 NodeMap + 入口边（external linkage 函数/alias/global initializer 引用），TLI 经 FAM 逐函数取——**LCG 构造本身就要问 TLI**（libfunction 判定，LCG.cpp:144-163），这就是实测里 `cgscc(no-op-cgscc)` 先打出一排 TLI 的原因；② `buildRefSCCs()`（LCG.cpp:1931-1969，幂等守卫）从入口 DFS，每节点开始走边时才 populate；③ RefSCC 内 `buildSCCs`（:1897）再切 call 边 SCC。libfunction 另有隐式 ref 边合成（populateSlow 内 LCG.cpp:121-125）——建模"LLVM 可能把任意代码变成库调用"。

### 6.2 CGSCCUpdateResult：pass 与 adaptor 的双向通道

每个 CGSCC pass 的第 4 个 ExtraArg（CGPCM.h:233-307）。七字段分两类（§5.3 同款修正）：**引用成员**指向 adaptor 局部变量（pass 写 adaptor 读）——CWorklist（变形 SCC 重访队列）/ InvalidatedSCCs（已删名单）/ InlinedInternalEdges（内联历史 hack，头注释自称 "big layering issue"）/ DeadFunctions（延迟批删队列）；**自有值成员**——UpdatedC（当前 SCC 精化后的新形态，adaptor 内层 do-while 依据它重跳）/ CrossSCCPA（跨 SCC 保留集——"动了祖先 SCC 的 IR"的申报通道；头注释 :270-281 解释为什么必须 out-of-band：主 PM 基础设施必须把 SCC 内全标 preserved 以免 unnest 时重复失效）/ IndirectVHs（devirt 检测弱句柄）。

### 6.3 mutation API：新 PM 允许谁改图

LCG 的 mutation API 全在 RefSCC 上（LCG.h:683-852）：`switchInternalEdgeToCall`（ref→call，可能**合并** SCC）/ `switchInternalEdgeToRef`（call→ref，可能**分裂** SCC）/ `switchOutgoingEdgeTo*`（跨 RefSCC 出边，不动划分）/ `insertTrivialRefEdge`（窄通道，不得违反 RefSCC 结构）。**调用者只有两个**：adaptor 的 `updateCGAndAnalysisManagerForFunctionPass`（函数 pass 改完 IR 由 adaptor 代扫同步，§5.4）和内联器等少数拿到 `LazyCallGraph&` 的 CGSCC pass。普通函数 pass 无权直接改图——只能靠 PA 声明让 adaptor 兜底。

### 6.4 死删批处理与 devirt 重跑

**死删两段式**：`markDeadFunction`（LCG.cpp:1496-1518，前置 `hasZeroLiveUses` + 非 libfunction，出边全降级 ref）→ adaptor 在**整条模块 RefSCC 遍历结束后**统一 `removeDeadFunctions`（:1519-1560 按 RefSCC 分组批删）+ `eraseFromParent`（CGPCM.cpp:349-351，位于外层 `while (!RCWorklist.empty())` 之外）。中途不删是唯一不破坏 SCC 迭代器的方式。

**DevirtSCCRepeatedPass**（CGPCM.h:535-562，OptionalPassInfoMixin——bisect 可跳过；run 在 CGPCM.cpp:367-505）：`ScanSCC` 给每个间接调用挂 WeakTrackingVH；跑一轮被包装 pass 后两级检测——显式（任一弱句柄的间接调用变 direct，:446-456）+ 启发式（某函数 indirect 减且 direct 增，:469-483，注释自嘲 "can be fooled...but seems to work well in practice"）。命中即重跑，上限 `MaxDevirtIterations` 默认 4（`CallGraphSCCPass.cpp:47-48`——**legacy 的 cl::opt 被新 PM 复用**）。文本拼写 `devirt<4>(...)`（parseDevirtPassName，PassBuilder.cpp:813-820），O2 里包着整个内联+函数属性段。

**实测两连**（scratch/lcg-devirt.txt）：外部可见 global 的名义用例是**负路径**——instcombine 不敢折叠 `load @fp`，只跑一轮；把 global 改 `internal constant`（用例 lcg-devirt-internal.ll）后 instcombine 折叠成直接调用，`InstCombinePass on caller2` 出现 **2 次**——第二轮就是弱句柄检测点火的活体证据。SCC 精化的整段重跑活体在 scratch/lcg-o2-cgscc-passes.txt：(a,b,c) 内联后精化为 (c)、(a)，各自重跑整段 CGSCC pass。

### 6.5 postorder 实测

`a→b→c→a` 用例（lcg-mutual.ll）：legacy `print-callgraph-sccs` 全量打印 4 个 SCC（含 external node）；新 PM `cgscc(...)` 只访问入口可达的 (a,b,c)→(main)——孤立 internal 函数 `d`/`e` 根本不建 SCC（入口边规则，§6.1）。**legacy printer 与新 PM 遍历集不同**是排查时的常见困惑源。

---

## 7. PassBuilder：文本到对象图

### 7.1 三副面孔

`PassBuilder`（声明 `PassBuilder.h` 1053 行、实现 `PassBuilder.cpp` 3032 行 + `PassBuilderPipelines.cpp` 2584 行）一个类干三件事：**默认流水线构建**（build\* 函数族）、**文本解析**（`-passes='...'`）、**注册表中枢**（PassRegistry.def）。三者共享同一份词表——文本解析与 C++ 构建输出同构的 PM 树，这是 `-print-pipeline-passes` 能 round-trip 的机制根源。

词表 `llvm/lib/Passes/PassRegistry.def`（863 行，X-macro）：pass 条目 377（MODULE 118+19 带参 / FUNCTION 168+29 / CGSCC 8+3 / LOOP 24+4 / LOOPNEST 4）+ analysis 66（MODULE 22 / FUNCTION 36 / CGSCC 3 / LOOP 5）+ alias 6，机器 pass 不在此——独立词表 `llvm/include/llvm/Passes/MachinePassRegistry.def`（268 行，89+7+28 条）。一个 pass 名（如 `instcombine`，:626-630 五元组：文本名/类名/构造 lambda/参数解析器/参数文档串）在 `PassBuilder.cpp` 内被 35 处 `#include` 重放（另 CodeGenPassBuilder.cpp 1 处），展开成：5 个 isXxxPassName（归属判定）、5 个 parse\*Pass、4 个 register\*Analyses、类名映射、printPassNames。**改一个 pass 名只动一处**。target 侧同构扩展：`AMDGPUPassRegistry.def`（169 行）经 `TargetPassRegistry.inc` 展开，由 `registerPassBuilderCallbacks` 引入（`AMDGPUTargetMachine.cpp:1023-1024`）。

### 7.2 文本解析：词法 + 五级递归 + 自动包裹

- **词法层** `parsePipelineText`（`PassBuilder.cpp:2021-2076`）只认 `,()`三个分隔符，显式解析栈切出 PipelineElement 树；贪心消费连续 `)`；**不认识 `<...>`**——参数尖括号原样留在名字里（副作用：参数内不能有 `,`/`()`，故各 pass 参数语法自觉用 `;` 分隔）；
- **五级递归**：parsePassPipeline 五个重载（:2720 Module / :2771 CGSCC / :2794 Function / :2816 Loop / :2830 MachineFunction）。层级下探靠各层 parse\*Pass 认识管理器名并包 adaptor：module 层认识 `cgscc(...)`/`function[<eager-inv>](...)`；CGSCC 层认识 `function(...)`/`devirt<N>(...)`；function 层认识 `loop(...)`/`loop-mssa(...)`/`machine-function(...)`；
- **自动包裹**（module 层独有，:2728-2749）：`-passes=instcombine` 能直接跑的原因——首名不是 module pass 时按 cgscc→function→loop→loopnest→machine-function 顺序探测，整条管线自动包成 `function(instcombine)`。`licm` 有特判：自动升级为 `function(loop-mssa(licm))`（:2741-2746），保证拿到的分析环境与默认管线一致。

### 7.3 默认流水线骨架与 round-trip

`buildPerModuleDefaultPipeline`（`PassBuilderPipelines.cpp:1765`）的层级：PipelineStart EP（:1795）→ `buildModuleSimplificationPipeline`（:1123，EarlyFPM/IPSCCP/GlobalCleanupPM/内联器二选一）→ `buildModuleOptimizationPipeline`（:1518，OptimizePM 大循环 + 向量化 + OptimizerLast EP）→ GlobalDCE/ConstantMerge 收尾。**Peephole EP 在一条 O2 管线触发 4 次**（:681/:802/:838/:1243）——AMDGPU 的 SimplifyLibCalls 挂这个点就是为了贴着每次 InstCombine 的输出做收尾。O0 走独立最小骨架（:2414，唯一语义义务是 alwaysinline），EP 挂点做空检查兜底。

**round-trip 实测**：`-print-pipeline-passes` 输出原样喂回 `-passes` 能再跑通，二次打印与首次 diff 为空；打印器是**规范化器**——只写 `max-iterations=2` 会补全默认参数 `verify-fixpoint`。但**文本不能冻结完整配置**（存在直接反例）：默认流水线构造 `LoopUnrollPass` 时传入 `OnlyWhenForced`/`ForgetSCEV`（`PassBuilderPipelines.cpp:1375-1377`，源自 PTO——clang 的 `-fno-unroll-loops` 就翻转这项，`BackendUtil.cpp:868`），而其打印器（`LoopUnrollPass.cpp:1819-1841`）不输出这两个配置、解析器（`PassBuilder.cpp:908-948`）也无对应拼写——实测 clang 加/不加 `-fno-unroll-loops` 打印文本逐字相同（都是 `loop-unroll<O2>`），回喂后配置回退默认。所以文本能固定的是**可打印的 pass 顺序和部分选项**；完整复现还需保存工具版本、target、流水线构建选项（PTO 等）及其他命令行参数。`module(...)` 外壳在打印期被拍平（嵌套 MPM 无打印名）。

---

## 8. EP 扩展点与插件

### 8.1 15 种 EP 与注册顺序

15 个 `register*EPCallback`（`PassBuilder.h:418-570`，槽位 SmallVector\<function,2\> :812-849）：Peephole/LateLoopOptimizations/LoopOptimizerEnd/ScalarOptimizerLate/CGSCCOptimizerLate/VectorizerStart/VectorizerEnd/PipelineStart/PipelineEarlySimplification/OptimizerEarly/OptimizerLast/FullLinkTimeOptimizationEarly/Last/ThinLinkTimeOptimizationEarly/Last。其中只有 OptimizerEarly/Last/PipelineEarlySimplification 带 `ThinOrFullLTOPhase` 参数（:511/:521/:531）。invoke 函数集中在 `PassBuilderPipelines.cpp:354-428`（薄循环），**回调只登记不执行**——执行全部在 build\* 函数体的固定挂点。自写 build 函数时调 invoke 是义务（注释 :670-672）。

注入顺序（clang 完整链）：StandardInstrumentations→PIC（`BackendUtil.cpp:893-897`）→ **PassBuilder 构造（target 回调最先，`PassBuilder.cpp:595-596`）** → clang 自身 EP（:903-924）→ 插件（:954-955）→ CodeGenOpts 回调 → 静态扩展（:959-961）。同一 EP 槽内 target 先于插件，想抢在 target 之前无公开途径。

### 8.2 Target 横评：EP 密度 ∝ IR 层特殊需求

| Target | EP 数 | 代表 |
|---|---|---|
| AMDGPU | **7**（`AMDGPUTargetMachine.cpp:1037/:1045/:1053/:1081/:1094/:1124/:1137`） | InferAddressSpaces 挂 3 处（每次大优化都可能暴露新 addrspace 推导点）；CGSCCOptimizerLate 组装 kernel 参数提升链；FullLTO Last 做 LDS lower |
| NVPTX | 2（`NVPTXCodeGenPassBuilder.cpp:325/:342`） | NVVMReflect 必须赶在内联前折叠 SM 版本 |
| AArch64 | 2（`AArch64TargetMachine.cpp:633/:639`） | LoopIdiomVectorize；Windows-only LowerIFunc |
| X86 | **0**（`X86CodeGenPassBuilder.cpp:317-320`，只有 registry include） | CPU 后端定制全在 CodeGenPassBuilder 侧 |

ThinLTO prelink 的 EP 语义与字面直觉相反（`PassBuilderPipelines.cpp:1929-1936`）：**prelink 构建器显式调用 OptimizerEarly/Last EP，但传入的 phase 参数是 `ThinLTOPreLink`**——注释明说 "Actual optimization is going to be done in PostLink stage, but clang can't add callbacks there in case of in-process ThinLTO called by linker"。即这里的 invoke **不把 clang 的回调"转发"到 postlink**（回调收到的是 PreLink 相位标记，可据此调整行为或空转）；真正的优化在 postlink 构建器里再跑一轮 EP（phase=ThinLTOPostLink）。EP 槽位的 ThinOrFullLTOPhase 参数（§8.1）就是为这种相位区分设计的。

### 8.3 PassPlugin 动态库

入口 `llvmGetPassPluginInfo`，头文件在 **`llvm/include/llvm/Plugins/PassPlugin.h`**（不在 llvm/Passes/——旧教程路径已过时）。API v2 的 `PassPluginLibraryInfo` 有**两个**可选回调：`RegisterPassBuilderCallbacks`（注册 EP/解析回调，拿到同一个 PassBuilder&——插件**不是独立注入机制**，只是 PassBuilder 注册入口之上的动态分发器）与 **`PreCodeGenCallback`**（:54-60，:58-60 注释原文）——后者把整个默认后端接过来：回调自行写输出文件到 OS 并**返回 true 跳过默认管线与后续插件**。这是插件唯一能"接管代码生成"的通道，与 pass 注册正交。`PassPlugin::Load` 四步（`llvm/lib/Plugins/PassPlugin.cpp:16-49`）：dlopen（permanent 不 dlclose）→ 找入口符号（区分新 PM 插件与 legacy RegisterStandardPasses 时代）→ 版本检查 → 返回。

最小插件实测（素材 08 §8.5）：注册 Peephole EP 后，clang -O1 下 pass 输出 8 行 = 4 个 Peephole 挂点 × 2 函数——EP 自动织入默认管线的直接证据。负面对照：只注册名字不注册 EP 则 default\<O1\> 里零输出——**名字注册与 EP 注入是两种独立能力**。macOS 编译坑：必须 build-debug 的 include（旧构建生成头不匹配）、`-isysroot`、`-undefined dynamic_lookup`（不链 LLVM 库，符号由宿主解析）；`-load-pass-plugin` 必须显式相对路径 `./xxx.so`。opt 还有第四条路：`-passes-ep-*` 命令行选项把文本管线绑到 EP 槽（`NewPMDriver.cpp:273`），免写 .so。

---

## 9. legacy PM

### 9.1 为什么 2026 年还必须懂它

clang/llc 的 CodeGen 在绝大多数 target 上仍默认走 legacy（§1.1），AMDGPU 亦然。核心文件 `llvm/lib/IR/LegacyPassManager.cpp`（1808 行）+ `llvm/include/llvm/IR/LegacyPassManagers.h`。理解它的失效模型是理解"新 PM 到底新在哪"的参照系。

### 9.2 五个核心类与自动嵌套

| 类 | 位置 | 职责 |
|---|---|---|
| `PMTopLevelManager` | `LegacyPassManager.cpp:546-855` | 跨层调度：`schedulePass`（:655 唯一调度入口）、last-user 表 |
| `PMDataManager` | `:857-1330` | 单层基类：PassVector、`AvailableAnalysis`（DenseMap\<AnalysisID, Pass*\>）、失效算法 |
| `MPPassManager` | `:380-464` | ModulePass 容器，持 OnTheFlyManagers |
| `FunctionPassManagerImpl` | `:244-308` | legacy::FunctionPassManager 的实现（多继承 Pass+PMDataManager+PMTopLevelManager） |
| `PassManagerImpl` | `:466-540` | legacy::PassManager 的实现 |

公开的 `legacy::PassManager`/`FunctionPassManager` 只是 PImpl 壳（`LegacyPassManager.h:53-98`）。**自动嵌套机制**：pass 经 `assignPassManager` 找归属 PM——`FunctionPass::assignPassManager`（`LegacyPassManager.cpp:1779-1806`）发现栈顶是 MPPassManager 时**自动 new 一个 FPPassManager**、登记到顶层、递归压 `PMStack`。`--debug-pass=Structure` 输出的缩进树就是这套嵌套的可视化（实测 AArch64 266 行、NVPTX 183 行，见素材 09 §9.7）。`PMStack::push` 有栈序断言（:1738）：层类型必须严格递增（枚举在 `Pass.h:56-64`，不在 LegacyPassManagers.h）。

### 9.3 AnalysisID 与 INITIALIZE_PASS

legacy 的身份系统：`using AnalysisID = const void *`（`Pass.h:51`），每个 pass 类的 `static char ID` 的地址即身份。`INITIALIZE_PASS` 宏族（`PassSupport.h:39-58`）生成 `PassInfo`（持名/参数名/ID 地址/默认构造函数指针）并 `Registry.registerPass`。**反直觉设计**：宏本身不够，必须有人显式调用 `initializeXxxPass(Registry)`——链接器会剔除未引用的 .o，`llvm/lib/CodeGen/CodeGen.cpp:19-172` 的 `initializeCodeGen` 就是逐个调用 100+ 个 initialize 的强制链接点。`Pass::createPass`（`Pass.cpp:222-227`）按 ID 反查工厂创建；TargetPassConfig::addPass(AnalysisID) 依赖它，**没注册直接 llvm_unreachable**。

### 9.4 失效模型对照

legacy 的失效在 pass 运行后由 PM 调 `removeNotPreservedAnalysis`（`LegacyPassManager.cpp:902-937`）：凡不在 `getAnalysisUsage` 声明的 PreservedSet 里就**整个从 AvailableAnalysis 删掉**（还查父层 InheritedAnalysis）；ImmutablePass 永不删（:925）。内存释放走独立机制：`setLastUser`/`collectLastUses`/`removeDeadPasses` 找"最后用户"提前 `releaseMemory`（:940-975）。

| 维度 | legacy | new PM |
|---|---|---|
| 声明方 | `getAnalysisUsage(AU)` 调 `AU.addPreserved<X>()` | run() 返回 PA，`PA.preserve<X>()` |
| 粒度 | analysis 整删，ImmutablePass 豁免 | 类型化集合代数 + abandon 单点否决 |
| 时序 | PM 统一处理（runOnXxx 返回后） | 逐 pass 立即失效（PassManagerImpl.h:80） |
| 跨层 | InheritedAnalysis 链表 | proxy 双向（Inner 转发失效 / Outer 登记延迟失效） |
| 隐式覆盖 | "last modifier wins"（`AvailableAnalysis[PI]=P` 覆盖） | 无——重复注册返回 false、保留先注册者 |
| 释放 | last-user 机制提前 releaseMemory | invalidate 自动（原地压缩清除） |

**"last modifier wins"是 legacy 的隐式语义**：`recordAvailableAnalysis`（`LegacyPassManager.cpp:860-864`）无条件 `AvailableAnalysis[PI] = P`——后跑的同 ID pass 静默顶掉先跑的。但注意其准确边界：该赋值只**更新后续分析查询所用的实例映射**，不替换已加入流水线的 pass——`PMDataManager::add` 在 recordAvailableAnalysis 之后仍执行 `PassVector.push_back(P)`（:979-1048，push 在 :1047），先前的 transformation 不会因此被移除。Codegen 段真正的 pass 替换机制是 `TargetPassConfig::substitutePass`（`TargetPassConfig.cpp:712-715`，按 AnalysisID 查替换表 `Impl->TargetPasses`）——target 顶掉通用 pass 走这条路，不是靠 last-modifier 副作用。new PM 的 `registerPass`（PM.h:497-509）语义是**重复注册返回 false，保留第一次注册的实例，不调用后续 factory**（`if (PassPtr) return false;`）——不是断言，是温和的先到先得。另外 legacy 的覆盖按 AnalysisID 逐槽位生效，**替换默认 AA 并不能靠 `addPass(new MyAA())` 一般性地实现**——AA 体系有专门的聚合/扩展入口（`AAResultsWrapperPass` 是聚合器，`ExternalAAWrapperPass`（`AliasAnalysis.cpp:779-786`）+ RunEarly/CB 回调是 target 注入自定义 AA 的正规通道，`AAResults::addAAResult` 逐个聚合，`AliasAnalysis.cpp:818-835`）。

### 9.5 为何 CodeGen 至今未全量切换

commit 考古 + 现状四因（素材 09 §9.6）：① target 覆盖率——写 buildCodeGenPipeline 的 10 家里只有 Lanai/MSP430 真正切换默认；② AArch64/ARM/Hexagon/PowerPC/SystemZ 还没写 builder；③ MachineFunction 生命周期与 Function 解耦（必须显式 releaseMemory，见 `911565d1085d` 提交信息），与新 PM"分析结果自动失效"模型不完全兼容；④ TargetPassConfig 的 substitute/insert/override 组合已积累 15 年 target 定制，迁移需逐 target 重写注册逻辑。

---

## 10. 插桩体系

### 10.1 两个类、一条注入链

`PassInstrumentationCallbacks`（回调注册表，`PassInstrumentation.h:67`）+ `PassInstrumentation`（PM 侧咨询点，:199，值语义、只含一个裸指针）+ `PassInstrumentationAnalysis`（伪分析，:339——让 PI 能经 AM 的 getResult 被任何 PM 惰性获取）。注入链：工具（opt 的 `NewPMDriver.cpp:459-488`、clang 的 `BackendUtil.cpp:889-898`）建 PIC → `SI.registerCallbacks(PIC, &MAM)` → PassBuilder 构造时注册 Class2PassName lambda（`PassBuilder.cpp:598-638`，PassRegistry.def 宏展开）。

**9 类回调**（:79-87）中只有 `ShouldRunOptionalPass` 返回 bool——`runBeforePass` 用 `ShouldRun &= C(...)` 折叠（一票否决，:232-233），且**只作用于非 required pass**。三个"前"回调语义分层：ShouldRunOptionalPass（决策）/ BeforeNonSkippedPass（确定要跑，TimePasses/print-changed 等"需配对"的插桩注册它）/ BeforeSkippedPass（被跳过时，"Skipping pass" 日志）。

### 10.2 咨询点布局

- **PM 主循环**（PassManagerImpl.h:62-98）：顺序是 run → **invalidate** → runAfterPass——AfterPass 回调看到的缓存已是失效后状态；被跳过的 pass 零副作用（连 invalidate 都不触发，opt-bisect 因此安全）；
- **adaptor 有独立咨询点**（`PassManager.cpp:128-170`），不复用 PM::run；
- **分析侧 4 点**（PassManagerImpl.h:145/155/220-221/116-117）：before/after/invalidated/cleared——**缓存命中不触发回调**，TimePasses 只统计首次计算；取 PIA 自身有自举特判防无限递归；
- **Class2PassName**：类名（`InstCombinePass`）↔ 管道名（`instcombine`）的惰性映射表，首次查询时由 PassBuilder 的 lambda 一次性填充。opt-bisect 日志与崩溃栈打印的都是管道名。

### 10.3 opt-bisect 决策链（控制通道代表）

`-opt-bisect-limit=N` → 全局单例 OptBisect 的区间 `{1,N}`（`OptBisect.cpp:31-49`）→ `OptPassGateInstrumentation` 注册 ShouldRunOptionalPass 回调（`StandardInstrumentations.cpp:1116-1122`）→ `runBeforePass` 一票否决 → `OptBisect::shouldRunPass`（`OptBisect.cpp:96-115`）单调递增计数并查区间。三个特性：编号跨 IR 单元类型连续（module/function 混编同一计数器）；**与 legacy PM 共享同一个单例**（legacy 各 pass 基类自调 `skipFunction`，`Pass.cpp:196-212`），混合流水线编号不断裂；required pass 根本不进决策链。

### 10.4 StandardInstrumentations：15 个成员、三条通道

15 个成员插桩对象（`StandardInstrumentations.h:606-637`）：PrintIR/PrintPass/TimePasses/TimeProfilingPasses/OptNone/OptPassGate/PreservedCFGChecker/PrintChangedIR/PseudoProbeVerifier/PrintChangedDiff/DotCfgChangeReporter/PrintCrashIR/ChangeTester/Verify/**DroppedStatsIR**（DroppedVariableStatsIR，dropped-variable-stats）。注册顺序（`StandardInstrumentations.cpp:2548-2574`）两处敏感：TimeProfilingPasses 永远最后注册且 after 回调全部 ToFront——保证其它插桩的耗时不计入 pass 计时。

### 10.4.1 三条消费通道

**观察**（print-changed/time-trace/time-passes）、**控制**（opt-bisect/optnone/opt-disable）、**校验**（-verify-each 坏 IR 直接 fatal——定位"哪个 pass 搞坏 IR"的二分工具；PreservedCFGChecker 见 §4.5）。

### 10.5 print-changed 家族与平台坑

8 个值（`llvm/lib/IR/PrintPasses.cpp:75-93`）：quiet/diff/diff-quiet/cdiff/cdiff-quiet/dot-cfg/dot-cfg-quiet（+无值 verbose）。quiet 不是"少打印"而是同一代码路径跳过非变更事件（VerboseMode 字段门控）。**diff 系列调外部 GNU diff**（`doSystemDiff`，`PrintPasses.cpp:382-420`，传 `--old-line-format` 等 GNU 专属选项）——macOS 的 BSD diff 拒收，输出全是 "unrecognized option"（本机实测踩实）；Linux 正常。time-trace 输出 Chrome Trace JSON（`ph:"X"` 事件嵌套天然反映 PM 层级，尾部 Total 聚合）；clang 的 `-ftime-trace` 让前端事件与 pass 事件共一个 JSON。

---

## 11. AMDGPU 案例（连接姊妹篇）

> 本章数据与方法与《AMDGPU_Deep_Analysis.md》共用一套实测基线（gfx1100 -O3）；姊妹篇从 target 视角看这些 pass 在流水线里的位置，本章从 PM 视角看它们的 PA 契约。素材：`AMDGPU-notes/01-architecture.md`（三段式 RA、EP 分布）。

### 11.1 IR pass 的 PA 风格光谱

8 个代表 pass（详见素材 04 §5.1）呈现四档：

| 档 | 代表 | PA |
|---|---|---|
| 保守基底 | LowerModuleLDS（`AMDGPULowerModuleLDSPass.cpp:1596-1599` 新 PM 的 run；legacy 本体 `AMDGPULowerModuleLDSLegacy` 与工厂 `createAMDGPULowerModuleLDSLegacyPass` 在**同一文件** `:1579-1594`——不存在姊妹文件 AMDGPULowerModuleLDS.cpp）、AlwaysInline（:168-171） | `changed ? none() : all()` 三元式 |
| 保 CFG 集合 | PromoteAlloca（:250-261）、AnnotateUniformValues（:95-101，注释自嘲 "TODO: Should preserve nearly everything"） | `none() + preserveSet<CFGAnalyses>()` |
| 点名保分析 | AtomicOptimizer（:135-152） | `none() + preserve<DominatorTreeAnalysis>()`——只有用 DomTreeUpdater 增量维护过 DT 的 pass 才敢写 |
| Attributor 系 | AMDGPUAttributor（:1641-1684） | none/all 二元 |

### 11.2 MachineFunction pass 的标准写法

以 SIInsertWaitcnts（`SIInsertWaitcnts.cpp:3461-3476`）为代表：未变 all()；变了以 `getMachineFunctionPassPreservedAnalyses()` 为基底叠 `.preserveSet<CFGAnalyses>().preserve<AAManager>()`。同型还有 InsertDelayAlu/LowerVGPREncoding/PreLegalizerCombiner 等——**基线（全保 IR）+ 增量申报（machine 分析）** 是机器 pass 的统一模式。RAGreedyPass 在 gfx1100 新 PM 流水线出现 3 次（**SGPR→WWM→VGPR** 三段式 RA，姊妹篇 §6：RAGreedy(SGPR)→…→SIPreAllocateWWMRegs→RAGreedy(WWM)→…→AMDGPUReserveWWMRegs→RAGreedy(VGPR)，实测 dualpm-llc-amdgpu-newpm.log 行 174/194/203），是"类型即身份、同型多实例合法"（§2.3）的量产实例。

---

## 12. 复现手册

完整版（含全部实测命令与 scratch 产物索引）在 `PassManager-notes/12-repro-manual.md`；素材层 scratch 产物在 `PassManager-notes/scratch/`（§1§7§8§5§6 的实测输出，前缀 dualpm-/pb-/plugin-/adapt-/lcg-），§2§3 的产物在顶层 `scratch/core/`、`scratch/am/`。核心命令与坑：

```bash
# 新 PM 全景：pass 序列 + 分析计算/失效（opt;clang 用 -Xclang -fdebug-pass-manager,见下）
./build-debug/bin/opt -p 'default<O1>' -debug-pass-manager -S in.ll -o /dev/null
# 只看真正改变了 IR 的 pass
./build-debug/bin/opt -p 'default<O1>' -print-changed=quiet -S in.ll -o /dev/null

# §4 核心实证：invalidate 击穿缓存 → 第二次 require 重建
./build-debug/bin/opt -p 'function(require<domtree>,invalidate<domtree>,require<domtree>)' \
    -debug-pass-manager -S in.ll -o /dev/null 2>&1 | grep DominatorTreeAnalysis
# 对照（去掉 invalidate）：Running analysis 只出现 1 次（缓存命中）

# 插桩三件套
opt -p 'default<O1>' -time-passes ...        # 计时两表（含 Instr 列）
opt -p 'default<O1>' -time-trace -time-trace-file=/tmp/t.json ...   # Chrome tracing
opt -p 'default<O1>' -opt-bisect-limit=3 ... # 二分定位

# clang 的新 PM 执行跟踪（修正:不是 opt 专属）
./build-debug/bin/clang -O1 -Xclang -fdebug-pass-manager -S -emit-llvm demo.c -o /dev/null
# 该选项经 BackendUtil.cpp:893 的 StandardInstrumentations 输出 "Running pass/analysis" 全景
# 注意区分:--print-pipeline-passes 只打印管线结构后即返回,不是执行跟踪

# CodeGen 段（legacy）与 clang 两段对拍
llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O3 --debug-pass=Executions -o /dev/null kernel.ll
clang --target=amdgcn-amd-amdhsa -mcpu=gfx1100 -O3 -nogpulib -mllvm --print-pipeline-passes -c demo.cl
clang --target=amdgcn-amd-amdhsa -mcpu=gfx1100 -O3 -nogpulib -mllvm --debug-pass=Executions -c demo.cl
```

工具坑（全部实测踩实）：① `-p 'default<O1>'` 必须引号（`<` 会被 shell 当重定向）；② clang 双段观察要两个开关——IR 段 `-Xclang -fdebug-pass-manager`（新 PM 执行跟踪；`-mllvm --debug-pass-manager` 是**报未知选项错误**，不是静默无输出，勿混用）或 `-mllvm --print-pipeline-passes`（仅结构转储）、CodeGen 段 `-mllvm --debug-pass=Executions`；`-mllvm -print-changed=quiet` 在 clang 可用；③ `--debug-pass` 合法值大写开头（Structure 非 structure）；④ `-print-changed=diff*` 在 macOS 坏（§10.5）；⑤ `-march=amdgcn` 已 deprecation，统一 `-mtriple=amdgcn-amd-amdhsa`；⑥ 无 ROCm 时 OpenCL 加 `-nogpulib`。

---

