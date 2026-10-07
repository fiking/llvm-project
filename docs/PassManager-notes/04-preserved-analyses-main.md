# §4 素材（主会话精读部分）：PreservedAnalyses 与主循环

> 本文件是主会话亲自逐行精读的部分，与子代理采集的 04-preserved-analyses.md 合并成文。
> 基准：main @ 3eda2aebadd4，2026-09-30 核实。

## 1. PA 的真实结构：双集合代数（而非"三态"）

Analysis.h:112-327。内部只有两个集合（SmallPtrSet，:317/:326）：

```cpp
SmallPtrSet<void *, 2> PreservedIDs;        // :317 保留的 analysis/set ID
SmallPtrSet<AnalysisKey *, 2> NotPreservedAnalysisIDs;  // :326 显式不保留（abandon 名单）
```

- `all()` (:118-122) = 往 PreservedIDs 塞一个特殊 `&AllAnalysesKey`（:314，静态 AnalysisSetKey）
- `none()` (:115) = 空构造
- 全保留的判定 `areAllPreserved()` (:292-295)：**NotPreserved 为空 且 All 键在**——即 abandon 会击穿 all()

### 关键运算

| 操作 | 行号 | 语义 |
|---|---|---|
| `preserve(ID)` | :139-148 | 先从 NotPreserved 摘除，再插入 PreservedIDs（若已 all 则短路） |
| `preserveSet(ID)` | :157-162 | 集合级保留，不做 NotPreserved 摘除 |
| `abandon(ID)` | :183-187 | 从 PreservedIDs 移除 + 塞 NotPreservedAnalysisIDs——**单点否决权**（注释 :164-170："not preserved, even if it is nominally covered by some other set or was previously explicitly marked as preserved"） |
| `intersect(Arg)` | :193-208 | PA1 ∩ PA2：NotPreserved 取**并**、Preserved 取**交**（注释 :200-201 原文）；Arg 为 all 时短路返回；this 为 all 时退化为拷贝 Arg |
| `abandon` 只能针对单个 analysis | :169-170 | **不能 abandon 一个 set**（模板只收 AnalysisT::ID()） |

### 查询侧：PreservedAnalysisChecker

- `getChecker<AnalysisT>()` (:275-277) 构造时**快照 IsAbandoned** (:243-244)
- `preserved()` (:250-253) = `!IsAbandoned && (All || 显式 ID)`
- `preservedWhenStateless()` (:258) = 只查 `!IsAbandoned`——**无状态分析的免检通道**（分析结果不含可失效状态时，即便没显式 preserve 也算活）
- `preservedSet<T>()` (:263-267) = `!IsAbandoned && (All || SetID)`

**不变量**（:325 注释）：同一 ID 不会同时出现在两个集合——preserve(ID) 的第一步就是摘除。

## 2. 新 PM 主循环（PassManagerImpl.h:56-98，全文心脏）

```cpp
PreservedAnalyses PA = PreservedAnalyses::all();              // :56 聚合器初值 all
PassInstrumentation PI = getAnalysisResult<...>(AM, IR, ...); // :62 插桩从 AM 拿
for (auto &Pass : Passes) {                                   // :67
  if (!PI.runBeforePass<IRUnitT>(*Pass, IR)) continue;        // :73 插桩可跳过 pass！
  PreservedAnalyses PassPA = Pass->run(IR, AM, ExtraArgs...); // :76
  AM.invalidate(IR, PassPA);                                   // :80 逐 pass 立即失效
  PI.runAfterPass<IRUnitT>(*Pass, IR, PassPA);                // :84
  PA.intersect(std::move(PassPA));                            // :88 聚合 = 连续 intersect
}
PA.preserveSet<AllAnalysesOn<IRUnitT>>();                     // :95 收尾补集合级保留
return PA;
```

五个要点：
1. **逐 pass 立即失效**（:80）——不是等整个 PM 跑完再失效；下一个 pass 立刻看到干净的世界。这与 legacy 的"调度器统一失效"是本质差异。
2. **聚合语义 = 连续 intersect**（:88）——整个 PM 的 PA 是所有成员 PA 的交。最保守的成员决定整体（谁丢了什么，整体就丢什么）。
3. **收尾的 preserveSet 补偿**（:91-95 注释）——因为 :80 已经逐 pass 处理了失效，AM 里幸存的结果对该 IRUnit 天然有效，故聚合 PA 需要补 `AllAnalysesOn<IRUnitT>` 集合标记，避免上层 adaptor 重复逐一失效。
4. **插桩可否决 pass 执行**（:73）——opt-bisect/print-changed 的 skip 机制入口；被跳过的 pass 完全不跑，PA 也不 intersect。
5. **PassInstrumentation 本身是 analysis**（:62）——从 AM getResult 拿到，意味着插桩器也走缓存/失效协议（PassInstrumentationAnalysis，PassInstrumentation.h:339）。

## 3. InvalidateAnalysisPass：abandon 的标准用法（PassManager.h:948-962）

```cpp
PreservedAnalyses run(...) {
  auto PA = PreservedAnalyses::all();
  PA.abandon<AnalysisT>();     // :960 全保留但点名废掉一个
  return PA;
}
```

即文本管线里的 `invalidate<domtree>`。这就是 abandon 存在的理由：**精准打击单个分析而保留其余**——preserve/abandon 不对称组合的唯一表达。

## 4. RequireAnalysisPass（PassManager.h:919-944）

`require<analysis>`（:933 getResult + 返回 all()）——只触发计算不失效任何东西。注意 :936 返回的是 `all()`：require 之后整个世界照旧。

## 5. adaptor 的 stale 语义（PassManager.h:878-908）

- `ModuleToFunctionPassAdaptor::run` 的声明在 :888（实现在 PassManagerImpl.h）
- **EagerlyInvalidate 参数**（:883-885，默认 false）：控制内层 FPM 跑完后是否立刻清理该函数的缓存
- :875-877 注释（关键技术契约）："Module analyses are not invalidated while the function passes are running, so they may be stale. Function analyses will not be stale."——**外层分析在内层 pass 运行期间可能变脏，这是跨层缓存的固有险区**；PassBuilder 的默认 pipeline 会在 FPM 序列后放 `invalidate-all` 类 pass 清场（待子代理素材核实具体位置）

## 6. AnalysisManager 侧（PassManager.h:279 起 + PassManagerImpl.h）

- `getResultImpl` (:130-149+)：`(ID, &IR)` 二元组缓存 try_emplace，未命中才 lookUpPass+run；**跑分析本身也会递归触发其它分析的缓存**（:148-149 注释 "running it can recursively cache another result and rehash the map"——所以先 emplace 占位再填）
- `invalidate(IR, PA)`（声明 PassManager.h:516，实现 PassManagerImpl.h:169-230）——**失效的完整算法**：
  1. :172 快速通道：`allAnalysesInSetPreserved<AllAnalysesOn<IRUnitT>>()` 直接过（注意用的是 allAnalysesInSetPreserved 而非 areAllPreserved——set 级即可，且要求 NotPreserved 为空）
  2. :183-206 遍历该 IR 的结果链表，对每个结果调 `Result.invalidate(IR, PA, Inv)`——**二选一（非双层，评审修正）**：结果类型有自定义 `Result.invalidate` 就直接委托（PA checker 不参与判定，结果须自行解释 PA 与分析依赖）；没有才走默认的纯 PA 判定（`!preserved() && !preservedSet<AllAnalysesOn<IRUnitT>>()`，见 `PassManagerInternal.h:248-257` 的 if constexpr）。有自定义 invalidate 的结果（如 MemorySSA/AliasAnalysis）自己在方法内部决定哪些改动会毁它，Invalidator 允许它递归查询依赖并记录
  3. :191-194 Invalidator 已处理过的 ID 跳过（依赖闭包不重复展开）；:198-200 注释提醒 Result.invalidate 可能**插入新条目使迭代器失效**——不能预插
  4. :204-205 断言环检测："Should never have already inserted this ID, likely indicates a cycle!"
  5. :209-226 **原地压缩清除**（WriteIdx/ReadIdx 双指针，避免 erase 逐个 O(n²)）；被清的先通知插桩 `runAnalysisInvalidated`（:220-221）再从索引摘除
  6. :228-229 链表空则连 IR 项一起摘——AM 的内存随使用收缩
- `verifyNotInvalidated`（:470-478）：调试模式断言缓存结果在 PA=none 下不可失效——测试缓存一致性的钩子
- `clearAnalysis`（:523-535）与 `clear`（PassManagerImpl.h:113-128）：无条件清理 vs 协议清理

## 7. 与 legacy 的失效模型对比（待子代理素材补全 legacy 侧行号）

| 维度 | 新 PM (PA) | legacy (AvailableAnalysis) |
|---|---|---|
| 粒度 | 单 analysis ID 精准 | last-modifier-wins 粗粒度 |
| 方向 | pass 主动声明保留集（白名单思维） | 分析按需重算，无显式契约 |
| 否决 | abandon 单点否决 | 无对应 |
| 时序 | 逐 pass 立即失效 | PMDataManager 层统一处理 |
| 错误恢复 | verify 失败可 abandon | — |

## 8. 成文要点（写给主文档 §4 的骨架）

1. 先破"三态"误解：双集合 + All 键 + abandon 名单，六种常用构造方式
2. 主循环 11 行是全文心脏：逐 pass 失效 + intersect 聚合 + preserveSet 收尾三段论
3. abandon 的单点否决权与 InvalidateAnalysisPass 的不对称组合
4. preservedWhenStateless：无状态分析的豁免（为什么 stateless 分析可以不管 PA）
5. 跨层风险：adaptor 注释直言的 stale 语义 + EagerlyInvalidate
6. 案例：MachineFunction 层**同样返回 PA 且主循环同构**（MachinePassManager.cpp:143-160，与 PassManagerImpl.h:56-98 逐行对应）——**修正一个常见误解：机器层并非"不参与 PA 协议"**。真正的差异在三点：① 基线 `getMachineFunctionPassPreservedAnalyses()`（MachinePassManager.cpp:162-169）= none + 全保 IR 两层集合；② `FunctionAnalysisManagerMachineFunctionProxy::invalidate` **硬编码返回 false**（:37-43，注释明言"MachineFunction passes should not invalidate Function analyses"——机器层单向不回污 IR 分析）；③ AMDGPU 机器 pass 的 PA 实践见 04-preserved-analyses.md 第 5 节（SIInsertWaitcnts.cpp:3461-3476 为代表）
