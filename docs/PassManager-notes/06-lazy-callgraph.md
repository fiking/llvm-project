# LazyCallGraph:CGSCC 层的图基座(§6)

> 基准:llvm-project main @ `3eda2aebadd4`(2026-09-28)。
> 所有引用均为本仓库 `文件:行号`。`LazyCallGraph.h`(下称 LCG.h,1313 行)、`LazyCallGraph.cpp`(下称 LCG.cpp,2068 行)、`CGSCCPassManager.h`(下称 CGPCM.h,581 行)、`CGSCCPassManager.cpp`(下称 CGPCM.cpp,1196 行)。
> **来源说明**:本篇素材由主会话亲写(原代理因输出流反复截断于 2026-09-30 终止;其全部实测产物已在 `scratch/lcg-*`,主会话逐文件验收并自行核实行号后成文)。
> 分工边界:adaptor 的三层 worklist 主循环见 05-adaptors.md §5.3;PA 契约见 04。本篇专注图本身:双边模型、惰性构建、SCC 划分、mutation API、死删与 devirt 重跑。

---

## 6.0 为什么需要 LazyCallGraph

CGSCC 层管线要跑在 `LazyCallGraph::SCC` 这个 IRUnit 上(PM 的第五种 IRUnit,`IRUnitKindTraits` 特化在 LCG.h:1258-1260)。为什么不是普通 CallGraph:

1. **优化过程会改图**:内联删调用边、devirt 把间接调用变直接边、函数删除拆 SCC——图必须在 pass 运行期间可增量维护,不能每次重算;
2. **ref 边先于 call 辘被观察到**:函数指针 store 等引用在 call 边形成前就已存在,ref 图是 call 图的超集(LCG.h:118-125 类注释:"All call edges are inherently reference edges, and so the reference graph forms a superset of the formal call graph")。保守近似从 ref 图出发,call 边升级时再收窄——SCC 重算的触发因此有明确的单调方向;
3. **postorder 遍历语义**:被调用方先优化,内联时被内联函数已是最优形态(实测见 §6.5)。

## 6.1 双边模型与两层 SCC

`Edge`(LCG.h:128-176)是一个 tagged pointer(枚举 `Kind : bool { Ref = false, Call = true }`,:137),出边存在源 Node 里。**两层 SCC 结构**:

- **RefSCC**(LCG.h:540):ref 图上的 SCC。内部持 postorder 的 SCC 列表(`SmallVector<SCC*,4> SCCs`,:546)——**RefSCC 是全图的失效/重排单元**,call 边升级降级只影响 RefSCC 内部的 SCC 划分,不跨 RefSCC;
- **SCC**(call 图上的):真正跑 pass 的单元。`Node`(LCG.h:313)像 optional——`populate()` 前无边(LCG.h:309-311 注释),但**惰性构建的触发点是显式调 `populate()`**(LCG.h:362-367),`operator*`/`operator->`(:344-348)只取不建,不会自动触发 `populateSlow()`(LCG.cpp:70-127)——遍历者必须先 populate(buildGenericSCCs 的展开回调即如此)。

**惰性构建三级**:
1. `LazyCallGraphAnalysis::run`(LCG.h:1276-1284):只建 NodeMap + 入口边(external linkage 函数、alias、global initializer 引用,LCG.cpp:165-204)——注释自述 "This just builds the set of entry points. The rest is built lazily as it is walked"(LCG.h:1278-1279)。TLI 经 FAM 逐函数取(:1280-1283),`isKnownLibFunction`(LCG.cpp:144-149)判定后收进 LibFunctions 集合(:162-163);
2. `buildRefSCCs()`(LCG.cpp:1931-1969):从入口边 DFS,`buildGenericSCCs`(:1805)按 postorder 产出 RefSCC;**每个节点开始走边时才 `N.populate()`**(:1940-1942)。幂等守卫(:1932-1935:PostOrderRefSCCs 非空即返回);
3. RefSCC 内 `buildSCCs`(:1897)再切 call 边的 SCC。

**libfunction 的隐式 ref 边**:populateSlow 给每个已定义 libcall 函数合成 ref 边(LCG.cpp:121-125)——建模"LLVM 可能把任意代码变成库调用"(构造期注释 :158-161)。这就是实测里 6 个函数全部跑了 TLI 的原因(scratch/lcg-scc-traversal.txt:1-7):**LCG 构造本身就要问 TLI**,不是 pass 触发的。

## 6.2 CGSCCUpdateResult:pass 与 adaptor 的双向通道

`CGSCCUpdateResult`(CGPCM.h:233-307)是每个 CGSCC pass run 的第 4 个 ExtraArg。所有容器都是 adaptor 的局部变量、UR 持引用(pass 写 adaptor 读,05 §5.2.2):

| 字段 | 类型 | 语义 |
|---|---|---|
| `CWorklist` | `SmallPriorityWorklist<SCC*,1>&` | 新/变形 SCC 的重访队列,倒 postorder 入队(:246 注释) |
| `InvalidatedSCCs` | `SmallPtrSet<SCC*>&` | 已删 SCC 名单,worklist 命中即跳过(:252) |
| `UpdatedC` | `SCC*` | 当前 SCC 精化后的新形态,adaptor 内层 do-while 依据它重跑(:257-266 注释) |
| `CrossSCCPA` | `PreservedAnalyses` | 跨 SCC 保留集——"动了祖先 SCC 的 IR"的申报通道(:270-281 大段注释:主 PM 基础设施必须把 SCC 内全标 preserved 以免重复失效,跨 SCC 的真话只能记在这里) |
| `InlinedInternalEdges` | `SmallDenseSet<pair<Node*,SCC*>,4>&` | 内联历史 hack,防无限内联;头注释自称 "big layering issue"(:285-296 FIXME 原文) |
| `DeadFunctions` | `SmallVector<Function*,4>&` | 死函数延迟批删队列(:299-300) |
| `IndirectVHs` | WeakTrackingVH map | devirt 检测的弱句柄(:302-307) |

## 6.3 mutation API:新 PM 允许谁改图

LCG 的 mutation API 全在 RefSCC 上(:683-852):

- `switchInternalEdgeToCall`(:683):ref→call 升级,**可能合并 SCC**(成环);
- `switchInternalEdgeToRef`(:713):call→ref 降级,**可能分裂 SCC**(断环),返回新 SCC 区间;
- `switchOutgoingEdgeToCall/Ref`(:720/:726):跨 RefSCC 出边,只动边不改划分(RefSCC 是重排单元的原因);
- `insertTrivialRefEdge`(:852):插平凡 ref 边的窄通道——注释限定 "cannot violate the RefSCC structure";
- `insertEdge`(LazyCallGraph 层,:1030):拆 internal/outgoing 分派。

**但 pass 拿不到这些 API 的调用权**——key insight:mutation API 的调用者只有两个:① adaptor 的 `updateCGAndAnalysisManagerForFunctionPass`(CGPCM.cpp:881-1180,函数 pass 改完 IR 后由 adaptor 代扫 call/invoke 同步,05 §5.4.3);② 内联器等少数 CGSCC pass(它们拿到 `LazyCallGraph&` ExtraArg,自己更新)。普通函数 pass 只能通过 PA 撒谎/老实声明让 adaptor 兜底。

## 6.4 死删批处理

两段式(LCG.cpp:1496-1560):
1. `markDeadFunction(F)`(:1496-1518):前置条件 `hasZeroLiveUses()`(assert,:1500)且非 libfunction(:1504-1505);把出边全部降级为 ref(:1512-1515);
2. `removeDeadFunctions(DeadFs)`(:1519-1560):按 RefSCC 分组,清内部 spurious ref 边与出边,NodeMap 摘除。

调用时序:pass push 进 `UR.DeadFunctions` → adaptor 在**整条模块的 RefSCC 遍历全部结束后**(CGPCM.cpp:349-351,位于外层 `while (!RCWorklist.empty())` 之外)统一 `CG.removeDeadFunctions` + `eraseFromParent`——不是每条 RefSCC 结束时。**中途不删的理由**:SCC 迭代器持有 Node 指针,批量删是唯一不破坏迭代的方式。`Node::isDead()`(LCG.h:336-340)的"Graph 指针置空"标记供中间态查询。

## 6.5 实测:SCC 划分与 postorder 遍历

用例 `scratch/lcg-mutual.ll`:`a→b→c→a` 互调成环,`main` 调 `a`,`d`/`e` 为孤立 internal。

- `print-callgraph-sccs`(legacy printer,全量打印):`SCC #1: c,b,a; #2: main; #3: e; #4: external node`(scratch/lcg-callgraph-sccs.txt)——postorder:环最底,callees 在前;
- 新 PM `cgscc(no-op-cgscc)` 只访问可达 SCC:`(a,b,c)` → `(main)`(scratch/lcg-scc-traversal.txt)——`d`/`e` 不在入口集合,LCG 根本不为其建 SCC(§6.1 三级构建的入口边规则);
- `cgscc(function(no-op-function))`(scratch/lcg-cgscc-function.txt):同一 (a,b,c) SCC 内 a/b/c 逐个过函数 pass,再轮 (main)——CGSCCToFunctionPassAdaptor 的 Nodes 快照遍历(05 §5.4);
- O2 实际管线(scratch/lcg-o2-cgscc-passes.txt):`DevirtSCCRepeatedPass → InlinerPass → PostOrderFunctionAttrsPass → ...` 先跑 (a,b,c),内联后 SCC 精化成 (c)、(a) 各自重跑整段——三层 worklist 的活体展示;
- O2 文本里 CGSCC 段:`cgscc(devirt<4>(inline,...,function<eager-inv;no-rerun>(...),function(require<should-not-run-function-passes>),...))`(scratch/lcg-default-o2-cgscc-segment.txt,从 :22 行起)。

## 6.6 DevirtSCCRepeatedPass:重跑检测器

定义 CGPCM.h:535-562(继承 `OptionalPassInfoMixin`——bisect 可跳过)。run()(CGPCM.cpp:367-505):

1. `ScanSCC` lambda(:388-410)统计每个函数的 direct/indirect 调用数,**间接调用挂 WeakTrackingVH**(:404);
2. 内层无限 for(:416):跑一遍被包装 pass → SCC 精化则交还外层(:440-441)→ **devirt 判定两级**:显式——任一弱句柄的间接调用变成了 direct(:446-456);启发式——"某函数 indirect 减且 direct 增"(:469-483,注释自嘲 "can be fooled by all manner of transformations such as DCE...but seems to work well in practice");
3. 命中 devirt 且未超 `MaxIterations` 就再跑一轮(:490-498);超限且 `AbortOnMaxDevirtIterationsReached` 直接 fatal(:491-492)。

`MaxDevirtIterations` 默认 4(`CallGraphSCCPass.cpp:47-48` cl::opt "max-devirt-iterations" ReallyHidden)——**legacy 的 cl::opt 被新 PM 复用**,两个 PM 读同一个旋钮。文本拼写 `devirt<N>(...)`,`parseDevirtPassName`(PassBuilder.cpp:813-820)。

实测两连(scratch/lcg-devirt.txt):

- 用例 lcg-devirt.ll(`@fp` 外部可见 global 存 `@target`,间接调用):instcombine 包装下 **caller 只跑一轮**——外部可见 global 的 load 不敢折叠(改 `@fp` 是 ABI 可见行为),O2 全管线同样不消掉(对照实测 `-p 'default<O2>'` 输出仍是 indirect call)。"devirt" 名义用例实际验证的是**负路径**;
- 关键修正是把 global 改 `internal constant`(用例落盘 `scratch/lcg-devirt-internal.ll`):`@gp = internal constant ptr @callee` + caller 间接调用——instcombine 第一轮把 `load @gp` 折成 `call @callee`(实测输出 IR 已是直接调用),**`InstCombinePass on caller2` 出现 2 次**(lcg-devirt.txt 尾部):第二轮就是 CGPCM.cpp:446-456 弱句柄检测 + :469-483 启发式(indirect 1→0、direct 0→1)点火的活体证据。

复现:`opt -p 'cgscc(devirt<4>(function(instcombine)))' <ll> -disable-output -debug-pass-manager`。

## 6.7 与姊妹篇的连接

AMDGPU 的 CGSCCOptimizerLate EP(AMDGPUTargetMachine.cpp:1081)注入的 kernel 参数提升链跑在 LCG 之上——SCC 精化重跑对 kernel promotion 的意义:提升产生的新 direct 边会触发 devirt 检测的启发式(§6.6 第 2 级),PostOrderFunctionAttrs 重跑一遍吃掉新发现的函数属性。

## 6.8 自查表

| # | 断言 | 证据 | 状态 |
|---|---|---|---|
| 1 | Edge 是 tagged pointer,Kind 枚举 Ref=false/Call=true | LCG.h:128-137 | 已核实 |
| 2 | ref 图是 call 图超集(类注释原文) | LCG.h:118-125 | 已核实 |
| 3 | Node 惰性 populate:显式 populate() 触发 populateSlow,operator*/-> 不自动建边 | LCG.h:309-311, :344-367; LCG.cpp:70 | 已核实(评审修正:原写"首次解引用触发"有误) |
| 4 | LazyCallGraphAnalysis::run 只建入口边,TLI 经 FAM 逐函数取 | LCG.h:1276-1284 | 已核实 |
| 5 | libfunction 合成隐式 ref 边 | LCG.cpp:121-125, :158-163 | 已核实 |
| 6 | buildRefSCCs 幂等守卫 + 每节点 populate 后 DFS | LCG.cpp:1931-1969 | 已核实 |
| 7 | CGSCCUpdateResult 七字段及各自注释语义 | CGPCM.h:233-307 | 已核实 |
| 8 | mutation API 全在 RefSCC 上,switchInternalEdgeToCall/Ref :683/:713 | LCG.h:683-852 | 已核实 |
| 9 | markDeadFunction 前置 hasZeroLiveUses + 非 libfunction | LCG.cpp:1496-1518 | 已核实 |
| 10 | removeDeadFunctions 按 RefSCC 分组批删,调用点在整模块遍历结束后 | LCG.cpp:1519-1560; CGPCM.cpp:349-351 | 已核实(评审修正:原写"每条 RefSCC 结束时"有误) |
| 11 | 新 PM cgscc 只访问入口可达 SCC;d/e 不建 SCC | scratch/lcg-scc-traversal.txt vs lcg-callgraph-sccs.txt | 已实测 |
| 12 | O2 下 SCC 精化后整段 pass 重跑((a,b,c)→(c)/(a)) | scratch/lcg-o2-cgscc-passes.txt | 已实测 |
| 13 | DevirtSCCRepeatedPass 两级检测(弱句柄显式 + direct/indirect 计数启发式) | CGPCM.cpp:446-456, :469-483 | 已核实 |
| 14 | MaxDevirtIterations 默认 4,legacy cl::opt 被新 PM 复用 | CallGraphSCCPass.cpp:47-48 | 已核实 |
| 15 | devirt<N> 文本名由 parseDevirtPassName 解析 | PassBuilder.cpp:813-820 | 已核实 |
| 16 | internal constant global + instcombine 触发第二轮重跑(InstCombinePass ×2) | scratch/lcg-devirt.txt | 已实测 |
