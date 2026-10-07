# Pass 管理器深入分析 §3:AnalysisManager

> 基准:llvm-project main @ `3eda2aebadd4`(2026-09-28)。
> 所有引用均为本仓库 `文件:行号`,经 read/grep 实测核对;动态验证使用 `build-debug`(Debug+Assertions)。
> 实验原始输出存于 `scratch/am/`。

---

## 3.0 总览:惰性求值 + 键控缓存 + 声明式失效

`AnalysisManager<IRUnitT>` 声明于 `llvm/include/llvm/IR/PassManager.h:279-581`,文件注释(:274-278)一句话概括:

> "一个分析容器,**惰性**地运行分析并缓存其结果。可以管理任何'以 IR 单元地址为身份'的 IR 单元的分析。"

三个子系统(下文逐节展开):

1. **缓存**(:283-306, :565-581):`AnalysisPasses`(注册表)+ `AnalysisResultLists`(IR→结果清单)+ `AnalysisResults`((Key,IR)→结果指针)三张表;
2. **失效**(:318-394 的 `Invalidator` 内嵌类 + `llvm/include/llvm/IR/PassManagerImpl.h:168-230` 的 `AnalysisManager::invalidate`):PreservedAnalyses 驱动的深度优先依赖失效;
3. **跨层代理**(`PassManager.h:609-853` 的 InnerAnalysisManagerProxy / OuterAnalysisManagerProxy):Module↔Function、Function↔Loop、Module↔CGSCC 之间的分析可达性与失效传播。

便捷别名:`ModuleAnalysisManager = AnalysisManager<Module>`(`PassManager.h:586`)、`FunctionAnalysisManager = AnalysisManager<Function>`(:591);另有 `CGSCCAnalysisManager = AnalysisManager<LazyCallGraph::SCC, LazyCallGraph &>`(`llvm/include/llvm/Analysis/CGSCCPassManager.h:123-124`,带 ExtraArg)、`LoopAnalysisManager`(`llvm/include/llvm/Analysis/LoopAnalysisManager.h:74`,typedef 为 `AnalysisManager<Loop, LoopStandardAnalysisResults &>`)、`MachineFunctionAnalysisManager = AnalysisManager<MachineFunction>`(`llvm/include/llvm/CodeGen/MachineFunctionAnalysisManager.h:20`)。

---

## 3.1 缓存结构:三张表的 key 类型与职责

### 3.1.1 静态分析

`PassManager.h` 私有区(:283-306 与 :565-581):

```cpp
// 结果列表:一个 IR 单元名下的全部缓存结果(保持插入序,支持任意删除)
using AnalysisResultListT =
    SmallVector<std::pair<AnalysisKey *, typename ResultConceptT::unique_ptr>, 8>; // :295-297

// IR 单元 → 结果列表
using AnalysisResultListMapT = DenseMap<IRUnitT *, AnalysisResultListT>;           // :300

// (分析 ID, IR 单元) → 结果指针(裸指针,指向列表里 unique_ptr 持有的对象)
using AnalysisResultMapT =
    DenseMap<std::pair<AnalysisKey *, IRUnitT *>, ResultConceptT *>;               // :305-306

// 分析类型 ID → 分析 pass 本体(类型擦除)
using AnalysisPassMapT =
    DenseMap<AnalysisKey *, typename PassConceptT::unique_ptr>;                    // :566-567

AnalysisPassMapT AnalysisPasses;              // :570  注册表
AnalysisResultListMapT AnalysisResultLists;   // :576  按 IR 聚合的结果存储(owning)
AnalysisResultMapT AnalysisResults;           // :580  查询索引(non-owning 指针)
```

设计要点:

- **双重 key**:`AnalysisResults` 的 key 是 `std::pair<AnalysisKey *, IRUnitT *>`(:305-306)——分析身份是静态变量地址(见 02 文档 §2.1;`AnalysisKey` 为 `alignas(8)` 空 struct,`llvm/include/llvm/IR/Analysis.h:29`),IR 身份是对象地址。头注释 :278 "the address of the IR unit suffices as its identity" 明确此约定,其推论是**IR 对象不可移动、不可析构后复用地址**,否则缓存即脏指针(这正是 §3.4 proxy 失效机制存在的理由);
- **双表冗余的动机**(:289-294 注释):`AnalysisResultLists` 提供"按 IR 单元线性删除全部结果"的能力(pass 删除函数时用 `clear(IR)`,:409-414),且是结果对象的 owner;`AnalysisResults` 提供 O(1) 查询。:292 注释要求"结果指针在追加与任意删除下保持有效",故结果对象堆分配、由 unique_ptr 持有;
- **注册与缓存分离**:`AnalysisPasses`(:570)只存"哪些分析类型可用"(由 `registerPass` :496-510 惰性构造);`AnalysisResults` 只存"已算出的结果"。查询未注册分析会断言(:437-438 与 :456-457,"This analysis pass was not registered prior to being queried")。

### 3.1.2 getResult 的惰性构造路径

模板实现位于 `llvm/include/llvm/IR/PassManagerImpl.h`。调用链:

```text
AM.getResult<DominatorTreeAnalysis>(F)                     (PassManager.h:435-447)
  └─ assert(AnalysisPasses.count(PassT::ID()))             (PassManager.h:437)
  └─ getResultImpl(PassT::ID(), IR, ExtraArgs...)          (PassManager.h:440)
       └─ PassManagerImpl.h:131-166:
          auto [RI, Inserted] =
              AnalysisResults.try_emplace({ID, &IR}, nullptr);        // :134-135
          if (Inserted) {                                             // :139
            auto &P = this->lookUpPass(ID);                           // :140
            PassInstrumentation PI;                                   // :142
            if (ID != PassInstrumentationAnalysis::ID()) {            // :143
              PI = getResult<PassInstrumentationAnalysis>(IR, ...);   // :144 (递归!)
              PI.runBeforeAnalysis(P, IR);                            // :145
            }
            auto Result = P.run(IR, *this, ExtraArgs...);             // :150 (真正计算)
            ResultConceptT *ResultPtr = Result.get();                 // :151
            AnalysisResultListT &ResultList = AnalysisResultLists[&IR]; // :152
            ResultList.emplace_back(ID, std::move(Result));           // :153
            PI.runAfterAnalysis(P, IR);                               // :155
            RI = AnalysisResults.find({ID, &IR});                     // :159 (重新查找!)
            RI->second = ResultPtr;                                   // :162
          }
          return *RI->second;                                         // :165
```

三个易踩的坑,代码里都有对应注释:

1. **递归再入**(:148-149 注释 "running it can recursively cache another result and rehash the map"):分析 run 内部可再 `AM.getResult<其他分析>`(如 AAManager 聚合 BasicAA),导致 `AnalysisResults` rehash、迭代器失效,故 :159 必须**重新 find**,不能复用 :134 的 `RI`;
2. **PassInstrumentationAnalysis 自举**(:143):取 instrumentation 本身也走 getResult,会无限递归,故特判跳过;
3. **类型恢复在调用侧**:`getResult`(:442-446)把 `ResultConceptT` 向下 `static_cast` 为 `detail::AnalysisResultModel<IRUnitT, PassT, typename PassT::Result, Invalidator>` 再取 `.Result` 成员——擦除与恢复配对出现。`getCachedResult`(:454-468)同构但**不触发计算**(:451 注释 "never runs the analysis"),未命中返回 nullptr;其非类型版 `getCachedResultImpl`(:559-563)就是一次 `AnalysisResults.find({ID, &IR})`。

### 3.1.3 动态验证:缓存命中不重新计算

```bash
$ ./build-debug/bin/opt -passes='function(require<domtree>,require<domtree>)' \
    -debug-pass-manager scratch/core/test.ll -disable-output
# scratch/am/require-twice.txt(foo 函数节选):
Running pass: RequireAnalysisPass<llvm::DominatorTreeAnalysis, ...> on foo (3 instructions)
Running analysis: DominatorTreeAnalysis on foo        ← 第一次 require:计算
Running pass: RequireAnalysisPass<llvm::DominatorTreeAnalysis, ...> on foo (3 instructions)
                                                      ← 第二次 require:无 analysis 行,纯缓存命中
```

`RequireAnalysisPass::run`(`PassManager.h:931-937`)只做一次 `AM.template getResult<AnalysisT>(Arg, ...)` 并返回 `PreservedAnalyses::all()`——两次 require 之间没有任何失效,第二次直接命中 §3.1.2 的 `Inserted==false` 路径。

缓存跨 adaptor 存活:`function(require<domtree>),function(print<domtree>)` 两个独立 ModuleToFunctionPassAdaptor 共享同一个 FAM(经 `FunctionAnalysisManagerModuleProxy`,`llvm/lib/IR/PassManager.cpp:130-131`),print 阶段 DominatorTreeAnalysis 不再重算(`scratch/am/require-print2.txt`:foo/bar 各只有一次 "Running analysis: DominatorTreeAnalysis")。

---

## 3.2 invalidate:判定逻辑与依赖图

### 3.2.1 主流程:AnalysisManager::invalidate

`PassManagerImpl.h:168-230`:

```cpp
void AnalysisManager<IRUnitT, ExtraArgTs...>::invalidate(
    IRUnitT &IR, const PreservedAnalyses &PA) {
  if (PA.allAnalysesInSetPreserved<AllAnalysesOn<IRUnitT>>())   // :172
    return;                                                     // :173  快速路径

  SmallDenseMap<AnalysisKey *, bool, 8> IsResultInvalidated;    // :177
  Invalidator Inv(IsResultInvalidated, AnalysisResults);        // :178
  auto ResultsListI = AnalysisResultLists.find(&IR);            // :179
  if (ResultsListI == AnalysisResultLists.end())
    return;                                                     // :181
  for (auto &AnalysisResultPair : ResultsListI->second) {       // :183
    AnalysisKey *ID = AnalysisResultPair.first;                 // :188
    auto &Result = *AnalysisResultPair.second;                  // :189
    auto IMapI = IsResultInvalidated.find(ID);                  // :191
    if (IMapI != IsResultInvalidated.end())
      continue;                       // 已被依赖链处理过          // :194
    bool Inserted =
        IsResultInvalidated.insert({ID, Result.invalidate(IR, PA, Inv)}).second; // :201-202
    assert(Inserted && "... indicates a cycle!");               // :204-205
  }
  // 第二阶段:压缩列表 + 擦除索引                                // :209-229
  ...
}
```

判定逻辑分三层:

| 层 | 代码 | 语义 |
|---|---|---|
| L0 快速路径 | :172-173 | PA 保留了 `AllAnalysesOn<IRUnitT>` 集合(典型:pass 返回 `PreservedAnalyses::all()`)→ 整个调用空转,零开销 |
| L1 逐结果询问 | :183-206 | 对每个缓存结果调用其 `invalidate(IR, PA, Inv)`,返回值记入 `IsResultInvalidated`;结果可以反过来经 `Inv` 查询依赖 |
| L2 物理清除 | :209-229 | 标记为 invalid 的条目从 `AnalysisResultLists` 压缩移除、`AnalysisResults` 删除(:223);删除前触发 `runAnalysisInvalidated` 回调(:220-221)——`-debug-pass-manager` 的 "Invalidating analysis: ..." 行即源于此 |

### 3.2.2 默认判定:AnalysisResultModel 的 lambda

结果的 `invalidate` 函数指针在 `AnalysisResultModel` 构造时安装(`llvm/include/llvm/IR/PassManagerInternal.h:242-258`):

```cpp
this->Invalidate = [](AnalysisResultConceptT &Self, IRUnitT &IR,
                      const PreservedAnalyses &PA, InvalidatorT &Inv) {
  if constexpr (ResultHasInvalidateMethod<IRUnitT, ResultT>::Value) {   // :250
    ResultT &Result = static_cast<AnalysisResultModel &>(Self).Result;
    return Result.invalidate(IR, PA, Inv);                // 自定义判定   // :252
  }
  auto PAC = PA.template getChecker<PassT>();
  return !PAC.preserved() &&
         !PAC.template preservedSet<AllAnalysesOn<IRUnitT>>();          // :254-256
};
```

即:**结果类型若自带 `invalidate(IR, PA, Inv)` 方法则用之**(SFINAE 检测,`ResultHasInvalidateMethod`,:195-227);否则默认规则是"除非 PA 显式 preserve 了这个分析、或保留了整个 IR 单元的分析集,否则一律作废"。`getChecker` 机制见 `llvm/include/llvm/IR/Analysis.h:233-277`(`PreservedAnalysisChecker::preserved()` :250-253 的判定 = 未被 abandon 且 (all 集或显式 ID 在 PreservedIDs 中))。

### 3.2.3 Invalidator:运行期构造的依赖图

`Invalidator`(`PassManager.h:318-394`)是 AM 的内嵌类,只暴露给各结果的 `invalidate` 方法。核心在 `invalidateImpl`(:357-386):

1. **记忆化**(:362-364):同一分析在一次 invalidate 遍历中只问一次,结果缓存于 `IsResultInvalidated`;
2. **递归深入**(:381):`IsResultInvalidated.insert({ID, Result.invalidate(IR, PA, *this)})` ——把自己作为 `*this` 传下去,让被依赖结果的 invalidate 继续查询它的依赖,形成**深度优先遍历**;
3. **环检测**(:383-385):若 insert 失败说明已插入过,断言"dependency cycle"——**分析依赖必须是 DAG**;
4. 缓存一致性断言(:368-371):试图失效一个不在缓存中的依赖是硬错误("likely due to a stale result handle")。

典型用法是 AAManager 的聚合结果 `AAResults::invalidate`(`llvm/lib/Analysis/AliasAnalysis.cpp:80-98`):逐个 `Inv.invalidate(ID, F, PA)` 询问聚合进来的各 AA 分析(BasicAA/TypeBasedAA/GlobalsAA 经 `addAADependencyID` 记录),任一失效则整体失效——**这就是"AAManager 不需要显式 preserve"的实现机制**(类注释 `llvm/include/llvm/Analysis/AliasAnalysis.h:964-966`)。

### 3.2.4 PA::preserveSet 与分析的联合失效规则

`PreservedAnalyses`(`llvm/include/llvm/IR/Analysis.h:112-327`)内部两个集合:`PreservedIDs`(:317)与 `NotPreservedAnalysisIDs`(:326,abandon 集,"总是赢" :321-323)。失效判定的联合规则(以 `DominatorTree::invalidate`,`llvm/lib/IR/Dominators.cpp:71-78` 为样本):

```cpp
auto PAC = PA.getChecker<DominatorTreeAnalysis>();
return !(PAC.preserved() || PAC.preservedSet<AllAnalysesOn<Function>>() ||
         PAC.preservedSet<CFGAnalyses>());
```

三种"被保留"的途径:`(a)` 显式 `PA.preserve<DominatorTreeAnalysis>()`、`(b)` 全量集 `AllAnalysesOn<Function>`、`(c)` 抽象能力集 `CFGAnalyses`(`Analysis.h:73-79`,语义 = "只依赖 CFG 的分析族",定义注释 :63-72)。`InstCombinePass::run` 的 PA(`llvm/lib/Transforms/InstCombine/InstructionCombining.cpp:6286-6291`)正是 `preserveSet<CFGAnalyses>()`——所以 §3.2.5 实测中 instcombine 过后 domtree 存活。

`InvalidateAnalysisPass<AnalysisT>`(`PassManager.h:948-969`)的 run 反向演示 abandon:`PA = all(); PA.abandon<AnalysisT>();`(:959-961)——all 集中单点挖洞;`InvalidateAllAnalysesPass`(:975-982)直接返回 `none()`。

### 3.2.5 动态验证:三种 pass 对 domtree 缓存的影响

```bash
# (a) 缓存保留:instcombine 保留 CFGAnalyses → domtree 不重算
$ opt -passes='function(require<domtree>,instcombine,require<domtree>)' -debug-pass-manager ...
# scratch/am/require-instcombine.txt:DominatorTreeAnalysis 每函数只出现一次

# (b) 单点失效:invalidate<domtree> → 重建
$ opt -passes='function(require<domtree>,invalidate<domtree>,require<domtree>)' ...
# scratch/am/require-invalidate.txt:
Running analysis: DominatorTreeAnalysis on foo
Running pass: InvalidateAnalysisPass<llvm::DominatorTreeAnalysis> on foo
Invalidating analysis: DominatorTreeAnalysis on foo       ← L2 清除 + 回调
Running analysis: DominatorTreeAnalysis on foo            ← 重建

# (c) 全量失效:invalidate<all>(InvalidateAllAnalysesPass,PassRegistry.def:465 注册)
$ opt -passes='function(require<domtree>,invalidate<all>,require<domtree>)' ...
# scratch/am/require-invall.txt:同样观察到 Invalidating + 重建
```

---

## 3.3 跨层代理:InnerAnalysisManagerProxy 与 OuterAnalysisManagerProxy

### 3.3.1 InnerAnalysisManagerProxy(外层持有内层 AM)

定义:`PassManager.h:609-695`;typedef `FunctionAnalysisManagerModuleProxy = InnerAnalysisManagerProxy<FunctionAnalysisManager, Module>`(:697-699)。

**它本身是 Module 层的一个普通分析**:run 方法(:673-676)什么都不算,只把持有的内层 AM 指针包进 Result 返回——目的如注释 :668-672 所言:"在内层 AM 的缓存里插入我们的 proxy 结果对象,以便把失效**代理**到内层 AM"。

`Result` 是 move-only RAII(:614-663):析构时若从未收到 invalidate 则 `InnerAM->clear()`(:625-633);`invalidate` 方法(:657-659)对 `FunctionAnalysisManagerModuleProxy` 有显式特化实现(`llvm/lib/IR/PassManager.cpp:52-115`),逻辑三段:

1. **proxy 自身未保留**(:68-72):module pass 可能增删了 Function,FAM 里的 Function* key 可能悬垂 → `InnerAM->clear()` 全清,返回 true;
2. **延迟失效匹配**(:80-98):遍历 module 内每个函数,查该函数的 `ModuleAnalysisManagerFunctionProxy` 缓存(Outer 方向)里登记的 `OuterAnalysisInvalidationMap`——若某个 module 分析刚被失效(`Inv.invalidate(OuterAnalysisID, M, PA)`,:92),把它映射的内层分析 ID 从该函数的 PA 里 `abandon`(:96);
3. **逐函数失效**(:102-110):FunctionPA 被修改过就用修改版,否则若 PA 未保留 `AllAnalysesOn<Function>` 则对每个函数 `InnerAM->invalidate(F, PA)`。

**Module 层缓存 Function 分析的真相**:Module 层并不直接缓存 Function 分析——它缓存的是 FAM 这个**管理者**(经 proxy Result),Function 分析结果存在 FAM 自己的三张表里。跨 adaptor 复用(§3.1.3 的 require-print2 实验)正是因为两次 `function(...)` 适配器经 `AM.getResult<FunctionAnalysisManagerModuleProxy>(M).getManager()`(`PassManager.cpp:130-131`)拿到**同一个** FAM。

CGSCC 层同构:`CGSCCAnalysisManagerModuleProxy`(`CGSCCPassManager.h:168`)、`FunctionAnalysisManagerCGSCCProxy`(:408 一带);Loop 层:`LoopAnalysisManagerFunctionProxy`(`LoopAnalysisManager.h:78-79`)。

### 3.3.2 OuterAnalysisManagerProxy(内层只读回查外层)

定义:`PassManager.h:740-853`;typedef `ModuleAnalysisManagerFunctionProxy = OuterAnalysisManagerProxy<ModuleAnalysisManager, Function>`(:851-853)。头注释(:723-739)规定两条纪律:

- **只暴露 const 接口**(:723-724):function pass 不能触发 module 分析的计算,只能 `getCachedResult`(:752-759)——注释 :725-733 以 GlobalsAA 为例解释:先算后跑与先跑后算都"合法但不同",允许 function pass 触发外层计算会导致结果依赖调度顺序,**为了未来并发必须禁止**;
- **本层不做失效**(:736-739):外层分析的失效由"各层 pass manager 的递归返回路径"处理,function pass 运行期间 module 分析可能陈旧(stale)。

失效联动靠**登记机制**:`Result::registerOuterAnalysisInvalidation<OuterT, InnerT>`(:795-807)把"外层分析 OuterT 失效时,应连带失效本函数的 InnerT"记录进 `OuterAnalysisInvalidationMap`(:821-822);当外层 AM 失效发生时,`Result::invalidate`(:770-791)遍历登记表逐项 `Inv.invalidate(InnerID, ...)`。生产者案例:`AAManager` 聚合 module 级 `GlobalsAA` 时(`llvm/include/llvm/Analysis/AliasAnalysis.h:998-1006` 的 `getModuleAAResultImpl`)先 `MAMProxy.getCachedResult<GlobalsAA>`,再登记 `registerOuterAnalysisInvalidation<GlobalsAA, AAManager>()`——GlobalsAA 一旦失效,所有函数的 AAManager 结果由 §3.3.1 的延迟失效机制(:86-98)连带清除。

### 3.3.3 其他 AM 变体

- **MachineFunction 层**:`MachineFunctionAnalysisManagerModuleProxy`/`...FunctionProxy` 是 `InnerAnalysisManagerProxy` 的特化 invalidate(`llvm/lib/CodeGen/MachinePassManager.cpp:46-109`);`FunctionAnalysisManagerMachineFunctionProxy` 是**手写类**(`llvm/include/llvm/CodeGen/MachinePassManager.h:129-189`),其 invalidate 恒 false(`MachinePassManager.cpp:37-43`,"MachineFunction passes should not invalidate Function analyses");
- **CachingOnDiskAnalysisManager:不存在**。grep 全仓库无此符号(待验证项的核实结果:当前 main 没有该设施;分析结果持久化由 `AnalysisCache`/`ThinLTO` 侧的独立机制承担,不在 PassManager 框架内)。

---

## 3.4 结果传播:PA 跨 IRUnit 时丢失了什么

PassManager::run 主循环(`llvm/include/llvm/IR/PassManagerImpl.h:67-97`)对每个 pass 的 PA 做 `PA.intersect(std::move(PassPA))`(:88)并在收尾 `PA.preserveSet<AllAnalysesOn<IRUnitT>>()`(:95)。**`AllAnalysesOn<IRUnitT>` 集合标记只覆盖本层**——一个 function pass 序列结束后,PM 向 module 层汇报的 PA 里,"所有 function 分析被保留"这句话对 module 分析毫无法言力;反过来,function 层根本没有机会表达"我保留了哪个 module 分析"(除了 MF 层的特殊规定 `getMachineFunctionPassPreservedAnalyses()`,`llvm/lib/CodeGen/MachinePassManager.cpp:162-169`,无条件保留全部 IR 分析)。

跨层细节丢失的具体场景与对策:

| 场景 | 丢失的机制 | 对策(必须显式 preserve) |
|---|---|---|
| function pass 改了 CFG 但更新了自己的 DomTree | `PA.preserve<DominatorTreeAnalysis>()` 只对当前函数的缓存有效;**module 分析默认全部失效**(因为 intersect 后的 PA 不含 AllAnalysesOn<Module>) | 无——这正是设计:module 分析保守失效 |
| ModuleToFunctionPassAdaptor 收尾 | adaptor 显式补 `PA.preserveSet<AllAnalysesOn<Function>>()` + `PA.preserve<FunctionAnalysisManagerModuleProxy>()`(`llvm/lib/IR/PassManager.cpp:167-168`),因为失效已在循环内逐函数完成 | 框架代做;pass 作者无需操心 |
| function pass 依赖 module 分析(GlobalsAA) | function pass 无法 invalidate 它,也无法新算——只能拿到**可能陈旧**的缓存(PassManager.h:736-739 注释明确认可 stale) | module pass 侧通过 Outer 登记(§3.3.2)保证最终一致性 |
| module pass 删除 Function | FAM 里以 Function* 为 key 的缓存全部悬垂 | module pass **必须** `FAM.clear(F, ...)` 或放弃 proxy(`PassManager.cpp:60-67` 注释;否则 §3.3.1 第 1 段全清兜底) |

经验法则:**凡是跨层的保留信息,必须经由 proxy 的 invalidate 特化手工搬运**;PA 对象本身只在同一 IRUnit 层内有完整语义。

---

## 3.5 分析的注册与 require<> 触发链

### 3.5.1 注册:PassBuilder 的宏展开

`llvm/lib/Passes/PassBuilder.cpp`:

```cpp
void PassBuilder::registerModuleAnalyses(ModuleAnalysisManager &MAM) {   // :732
#define MODULE_ANALYSIS(NAME, CREATE_PASS)                               // :733
  MAM.registerPass([&] { return CREATE_PASS; });
#include "PassRegistry.def"                                               // :735
  for (auto &C : ModuleAnalysisRegistrationCallbacks) C(MAM);             // :737-738
}

void PassBuilder::registerFunctionAnalyses(FunctionAnalysisManager &FAM) { // :750
  FAM.registerPass([&] { return buildDefaultAAPipeline(); });             // :754 (AA 特殊:先注册)
#define FUNCTION_ANALYSIS(NAME, CREATE_PASS)                              // :756-764
  if constexpr (std::is_constructible_v<decltype(CREATE_PASS),
                                        const TargetMachine &>) {
    if (TM) FAM.registerPass([&] { return CREATE_PASS; });   // 依赖 TM 的分析仅在
  } else {                                                    // 有 TM 时注册
    FAM.registerPass([&] { return CREATE_PASS; });
  }
#include "PassRegistry.def"                                               // :765
  ...
}
```

- `MAM.registerPass` 的实际效果是 `AnalysisPasses[PassT::ID()] = PassModelT::create(...)`(`PassManager.h:496-510`),**重复注册静默返回 false**(:503-505);
- 分析清单与文本名在 `llvm/lib/Passes/PassRegistry.def`,如 `FUNCTION_ANALYSIS("domtree", DominatorTreeAnalysis())`(:365)、`FUNCTION_ANALYSIS("postdomtree", PostDominatorTreeAnalysis())`(:379)。

### 3.5.2 require<> 的解析

同一文件的解析宏(`PassBuilder.cpp:2150-2161`,module 层;function 层 :2450-2462 同构):

```cpp
#define MODULE_ANALYSIS(NAME, CREATE_PASS)                                // :2150
  if (Name == "require<" NAME ">") {                                      // :2151
    MPM.addPass(
        RequireAnalysisPass<
            std::remove_reference_t<decltype(CREATE_PASS)>, Module>());   // :2153-2154
    return Error::success();
  }
  if (Name == "invalidate<" NAME ">") {                                   // :2157
    MPM.addPass(InvalidateAnalysisPass<...>());                           // :2158
    ...
  }
```

链条:`-passes='require<domtree>'` 文本 → 在 PassRegistry.def 全表上字符串精确匹配(:2151)→ 生成 `RequireAnalysisPass` 实例,模板参数**取决于所在层次**:`function(require<domtree>)` 生成 `RequireAnalysisPass<DominatorTreeAnalysis, Function>`(FUNCTION_ANALYSIS 宏段 :1942-1949;评审修正:本稿原写 ", Module>"——domtree 是 function 分析,module 层裸写 require<domtree> 会被自动包裹下探到 function 层,见下段)→ 运行时其 `run`(`PassManager.h:931-937`)调 `AM.getResult<DominatorTreeAnalysis>(...)` → 命中 §3.1.2 的惰性构造或缓存。**分析不需要"可执行地注册到 pipeline",registerPass 只是备好类型,getResult 才是真正的触发点**——这就是"惰性"的含义。

另注意:在 module pipeline 顶层写 `require<domtree>` 会按 function 分析处理——`opt -passes='require<domtree>,function(print<domtree>)'` 实测(`scratch/am/require-print.txt`)显示 require 被 ModuleToFunctionPassAdaptor 包进 function 层执行(顶层 FUNCTION_ANALYSIS 名经 `parsePassName` 的兜底规则自动适配;行为见输出 "Running pass: RequireAnalysisPass<...> on foo")。

---

## 3.6 典型分析的 Key 定义实例

### 3.6.1 DominatorTreeAnalysis:教科书形态

`llvm/include/llvm/IR/Dominators.h:240-251`:

```cpp
class DominatorTreeAnalysis : public AnalysisInfoMixin<DominatorTreeAnalysis> { // :241
  friend AnalysisInfoMixin<DominatorTreeAnalysis>;                              // :242
  LLVM_ABI static AnalysisKey Key;                                              // :243
public:
  using Result = DominatorTree;                                                 // :247
  LLVM_ABI DominatorTree run(Function &F, FunctionAnalysisManager &);           // :250
};
```

Key 的定义在 `llvm/lib/IR/Dominators.cpp:343`:`AnalysisKey DominatorTreeAnalysis::Key;` —— 一个全零初始化、永不读写的静态变量,**地址即全部语义**。注意**不存在独立的 "DominatorTreeAnalysis.h"**(任务书提到的文件名待修正:定义在 `Dominators.h`,实现与 Key 在 `Dominators.cpp:336-343`)。

三件套契约(:241-250):继承 `AnalysisInfoMixin<自己>`(CRTP)+ 私有 `static AnalysisKey Key`(friend 授权 mixin 取地址)+ `using Result` + `run(IRUnitT&, AM&)`。`Result` 类型本身带自定义 `invalidate`(`Dominators.h:133` 声明,`Dominators.cpp:71-78` 实现),走 §3.2.2 的 if-constexpr 自定义分支。

### 3.6.2 AAManager:聚合型分析与 PipelineTuningOptions 的关系

`llvm/include/llvm/Analysis/AliasAnalysis.h:967-1010`:`AAManager : public AnalysisInfoMixin<AAManager>`(:967),`Result = AAResults`(:969),Key 声明 :984-985(`friend` + `static AnalysisKey Key`)。特殊在**注册的是聚合器**:`registerFunctionAnalysis<BasicAA>()`(:972-974)等把"取数回调"存入 `ResultGetters`(:987-989);`AAManager::run`(`llvm/lib/Analysis/AliasAnalysis.cpp:892`)执行所有回调填充 AAResults。聚合 module 分析走 §3.3.2 的 Outer proxy + 失效登记(:998-1006)。

与 `PipelineTuningOptions`(PTO,`llvm/include/llvm/Passes/PassBuilder.h:41-45`)的关系:**PTO 不直接碰 AAManager 的 Key**;它通过 `PassBuilder::buildDefaultAAPipeline`(`llvm/lib/Passes/PassBuilderPipelines.cpp:2547-2579`)影响聚合内容——BasicAA 恒注册(:2560),`ScopedNoAliasAA`/`TypeBasedAA` 随后(:2564-2565),GlobalsAA 受 `EnableGlobalAnalyses` 开关(:2571-2572)控制,目标 AA 经 `TM->registerDefaultAliasAnalyses`(:2576)挂载。PTO 里的布尔/枚举字段(如同文件定义的一串优化开关)决定的是 **pipeline 里放哪些 pass**,而分析的注册清单由 `registerFunctionAnalyses`(`PassBuilder.cpp:750-769`)无条件铺全——**"注册"与"入列"分离**再次体现惰性哲学(registerPass 注释 `PassManager.h:491-495`:"你应该注册所有可能用到的分析,让本类惰性运行它们")。

---

## 3.7 实测汇总:require / invalidate / 缓存复用

全部用例基于 `scratch/core/test.ll`(foo/bar 各 3 条指令),命令与原始输出在 `scratch/am/`:

| 用例 | 文件 | 观察到的行为 |
|---|---|---|
| `function(require<domtree>,require<domtree>)` | require-twice.txt | DominatorTreeAnalysis 每函数只算一次;第二次 require 零 analysis 行 |
| `function(require<domtree>,invalidate<domtree>,require<domtree>)` | require-invalidate.txt | Invalidating analysis → 重建;且 adaptor 逐函数失效(`PassManager.cpp:153`)时 domtree 再次被 invalidate(聚合 PA 携带 abandon,FPM 收尾 preserveSet 不摘除) |
| `function(require<domtree>,invalidate<all>,require<domtree>)` | require-invall.txt | 与单点失效等价的表现(全清后重建) |
| `function(require<domtree>,instcombine,require<domtree>)` | require-instcombine.txt | instcombine 保留 CFGAnalyses,domtree 存活不重算 |
| `function(require<domtree>,no-op-function,require<domtree>)` | require-noop.txt | NoOpFunctionPass 返回 all,domtree 存活 |
| `require<domtree>,function(print<domtree>)` | require-print.txt | 顶层 require 经适配器下沉到 function 层执行 |
| `function(require<domtree>),function(print<domtree>)` | require-print2.txt | 两个独立 adaptor 共享 FAM,print 不重算(跨 adaptor 缓存复用) |

一个反直觉点(require-invalidate.txt 末两行):**require 重建后 domtree 又失效了一次**——第二次失效不是 VerifierPass 干的(两个 `VerifierPass::run` 都返回 `all()`,`Verifier.cpp:8427-8441`;对照实验 require→verify→require 每函数只算一次 domtree)。真实机制(评审修正):`invalidate<domtree>` 的 PA = all() + abandon\<domtree\>,FPM 聚合 intersect 后 abandon 存活;FPM 收尾 `preserveSet<AllAnalysesOn<Function>>`(`PassManagerImpl.h:95`)不摘除 abandon;adaptor 立即执行 `FAM.invalidate(F, PassPA)`(`PassManager.cpp:153`)击穿刚重建的结果,时机在下一个函数开始之前。这说明即便只读 pass,上游聚合携带的 abandon 仍可决定缓存命运;`PreservedAnalyses::all()` 不是默认,是承诺。

---

## 3.8 自查表

| # | 断言 | 证据 | 状态 |
|---|---|---|---|
| 1 | AM 三表:AnalysisPasses/AnalysisResultLists/AnalysisResults | PassManager.h:570/576/580 | 已核实 |
| 2 | AnalysisResultMapT key 为 pair\<AnalysisKey*, IRUnitT*\> | PassManager.h:305-306 | 已核实 |
| 3 | getResultImpl 惰性构造 + rehash 后重新 find | PassManagerImpl.h:134-165 | 已核实 |
| 4 | getCachedResult 不触发计算 | PassManager.h:449-468 | 已核实 |
| 5 | invalidate 快速路径 AllAnalysesOn\<IRUnitT\> | PassManagerImpl.h:172-173 | 已核实 |
| 6 | 默认失效判定 lambda(无自定义 invalidate 时) | PassManagerInternal.h:248-257 | 已核实 |
| 7 | Invalidator 记忆化 + DFS + 环断言 | PassManager.h:357-386 | 已核实 |
| 8 | DominatorTree::invalidate 三级判定(自身/AllOn/CFGAnalyses) | Dominators.cpp:71-78 | 已核实 |
| 9 | AAResults::invalidate 经 Inv 询问聚合依赖 | AliasAnalysis.cpp:80-98 | 已核实 |
| 10 | InnerAnalysisManagerProxy::Result RAII,析构 clear | PassManager.h:614-663 | 已核实 |
| 11 | FAMModuleProxy::Result::invalidate 三段逻辑 | PassManager.cpp:52-115 | 已核实 |
| 12 | OuterAnalysisManagerProxy 只读 + getCachedResult 断言可失效性 | PassManager.h:752-759,verifyNotInvalidated :470-478 | 已核实 |
| 13 | registerOuterAnalysisInvalidation 登记机制 | PassManager.h:795-807;AAManager 用例 AliasAnalysis.h:998-1006 | 已核实 |
| 14 | CachingOnDiskAnalysisManager 不存在 | grep 全仓库无符号 | 已核实(任务书预想的设施在当前 main 不存在) |
| 15 | PA.intersect 只在本层聚合;跨层靠 proxy 手工搬运 | PassManagerImpl.h:88,:95;§3.4 表格 | 已核实 |
| 16 | ModuleToFunctionPassAdaptor 收尾补 preserveSet+preserve proxy | PassManager.cpp:167-168 | 已核实 |
| 17 | MODULE/FUNCTION_ANALYSIS 宏注册到 AM;registerPass 重复静默 false | PassBuilder.cpp:732-769;PassManager.h:496-510 | 已核实 |
| 18 | require\<x\> 文本解析生成 RequireAnalysisPass | PassBuilder.cpp:2150-2161(module),:2450-2462(function) | 已核实 |
| 19 | DominatorTreeAnalysis 三件套 + Key 定义在 Dominators.cpp:343 | Dominators.h:240-251;Dominators.cpp:343 | 已核实(任务书"DominatorTreeAnalysis.h"文件名待修正) |
| 20 | buildDefaultAAPipeline 聚合顺序与 GlobalsAA 开关 | PassBuilderPipelines.cpp:2547-2579 | 已核实 |
| 21 | 两次 require 间插 invalidate 会重建 domtree | scratch/am/require-invalidate.txt / require-invall.txt | 已核实(实测) |
| 22 | instcombine(CFGAnalyses)与 no-op(all)都保住 domtree | scratch/am/require-instcombine.txt / require-noop.txt | 已核实(实测) |
| 23 | 跨 adaptor 共享 FAM 缓存 | scratch/am/require-print2.txt;PassManager.cpp:130-131 | 已核实(实测) |
