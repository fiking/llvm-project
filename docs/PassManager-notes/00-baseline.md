# Pass 管理器深度分析 —— 基线勘察

> 基准：llvm-project main @ `3eda2aebadd4`（2026-09-28 检出，本仓库工作区）。
> 姊妹篇：`AMDGPU_Deep_Analysis.md`（target 纵向深潜）。本文档横向拆解承载所有 pass 的执行框架。
> 产出：`PassManager-notes/01..10-*.md` 素材（本目录）+ `PassManager_Deep_Analysis.md` 主文档。

## 1. 范围定位

回答三个上层问题：
1. 一条 `-passes="..."` 文本如何变成可执行对象图（解析→装配→校验）
2. 分析结果的缓存与失效如何驱动 pass 重跑（PreservedAnalyses 契约——新 PM 的核心创新）
3. IR 层新 PM 与 CodeGen 层双 PM 并存的现实格局

## 2. 核心文件清单（行数实测）

| 模块 | 文件 | 行数 | 角色 |
|---|---|---|---|
| 新 PM 核心 | llvm/include/llvm/IR/PassManager.h | 986 | PassManager/AnalysisManager 模板 |
| PA 契约 | llvm/include/llvm/IR/Analysis.h | 331 | PreservedAnalyses 双集合代数（:112-327） |
| 装配器 | llvm/lib/Passes/PassBuilder.cpp | 3032 | 文本解析+默认管线+EP |
| 注册表 | llvm/lib/Passes/PassRegistry.def | 863 | pass 名↔构造注册 |
| 适配层 | llvm/include/llvm/IR/PassManagerImpl.h | 233 | 四种 IRUnit 的 CRTP 适配 |
| | llvm/include/llvm/IR/PassManagerInternal.h | ~100 | AnalysisManager 模板细节 |
| CGSCC 图 | llvm/lib/Analysis/LazyCallGraph.cpp | 2068 | SCC 惰性展开 |
| CGSCC PM | llvm/include/llvm/Analysis/CGSCCPassManager.h | 581 | DevirtSCCRepeatedPass(:535) |
| Machine 层 | llvm/include/llvm/CodeGen/MachinePassManager.h | 233 | MachineFunction IRUnit |
| CodeGen 新 PM | llvm/include/llvm/Passes/CodeGenPassBuilder.h | ~400 | addISelPasses(:291)/insertPass(:384) |
| CodeGen legacy | llvm/lib/CodeGen/TargetPassConfig.cpp | 1615 | addISelPasses(:1097)/addMachinePasses(:1145)/insertPass 楔子(:765) |
| legacy 核心 | llvm/lib/IR/LegacyPassManager.cpp | 1808 | PMDataManager/PMTopLevelManager |
| 插桩协议 | llvm/include/llvm/IR/PassInstrumentation.h | 363 | callbacks(:67)/通知(:199) |
| 插桩实现 | llvm/lib/Passes/StandardInstrumentations.cpp | 2586 | print-changed/time-trace 等 |
| legacy pass 基类 | llvm/include/llvm/Pass.h | 350 | AnalysisID 整数注册 |

合计核心约 1.6 万行。

## 3. 已亲自核实的关键锚点

（行号均经 read 核对，2026-09-30）

- `PreservedAnalyses`：Analysis.h:112；`none()` :115、`all()` :118-122（插入 `&AllAnalysesKey` 进 PreservedIDs）、`allInSet<>()` :125、`preserve(ID)` :139-148（先清 NotPreserved 再插入）、`preserveSet` :151-162、`abandon(ID)` :183-187（**从 PreservedIDs 移除并塞 NotPreservedAnalysisIDs——单点压过集合**，注释 :164-170 "not preserved, even if it is nominally covered by some other set"）、`intersect` :193-208/:214-229（保留下交集+不保留并集，注释 :200-201）
- `PreservedAnalysisChecker`：Analysis.h:233-268；`preserved()` :250-253（!IsAbandoned && (All || 显式)）、`preservedWhenStateless()` :258（**无状态分析免检通道**）、`preservedSet<>()` :263-267
- 内部表示：**双集合** SmallPtrSet（PreservedIDs :317 / NotPreservedAnalysisIDs :326），AllAnalysesKey 是特殊 AnalysisSetKey :314；不变量 :325 "a given ID should never occur both here and in PreservedIDs"
- `areAllPreserved()` :292-295：要求 NotPreserved 为空且 All 键在
- PassManager 模板：PassManager.h:192；AnalysisManager :279
- PassBuilder 文本解析五层：PassBuilder.cpp:2720(Module)/:2771(CGSCC)/:2794(Function)/:2816(Loop)/:2830(MachineFunction)
- TargetPassConfig：addPass :737、insertPass 消费点 :765（`IP.getInsertedPass()`）、addISelPasses :1097、addMachinePasses :1145
- CodeGenPassBuilder.h：PassManagerWrapper 三个 addPass 重载 :123(FPM)/:136(MPM)/:148(MFPM)、addISelPasses 声明 :291、addMachinePasses :299、insertPass :384-389
- AMDGPU 新 PM：AMDGPUTargetMachine.cpp:151（class AMDGPUCodeGenPassBuilder）、:2353（构造）、:2366(addIRPasses)、:2450(addCodeGenPrepare)、:2485(addPreISel)、:2521(addILPOpts)、:2528-2537(addAsmPrinter 三兄弟)
- MachinePassManager.h:185（AnalysisKey）、:222（extern template PassManager<MachineFunction>）
- PassInstrumentationCallbacks :67、PassInstrumentation :199、PassInstrumentationAnalysis :339

## 4. 前置实测结论（沿用自姊妹篇会话，2026-09-29/30）

- clang 路径实测：IR 优化段走新 PM（`-mllvm --print-pipeline-passes` 输出 TargetPassBuilder 装配串），CodeGen 段默认仍 legacy 装配（`--debug-pass=Executions` 的 Pass Arguments 是 legacy 格式）——两开关对拍证实
- 工具坑（已踩实，写进 §12 手册）：
  - clang 里 `-mllvm -debug-pass-manager`（单横线）被 LLVM 选项解析拒收，需 `--debug-pass-manager`（双横线），且该选项未链接进 clang 二进制（对 clang 无输出）
  - IR 段要 `-mllvm --print-pipeline-passes`；CodeGen 段要 `-mllvm --debug-pass=Executions`
  - llc `--debug-pass=Executions` 有效（stderr 输出带时间戳与缩进层级），`--debug-pass=structure` 不是合法值（合法值：Disabled/Arguments/Structure/Executions/Details——注意 help 里是大写 Structure）
  - OpenCL 编译需 `-nogpulib`（无 ROCm 时）
  - llc/clang 全部 `-march=amdgcn` 命令现已打 deprecation 警告，统一 `-mtriple=amdgcn-amd-amdhsa`
- 实测 pass 序列（gfx1100 -O3）：llc legacy 139 个 transformation pass；clang IR 段新 PM ~120 个（AMDGPU 专属 8）+ CodeGen 段 139 个（与 llc 一致）
- AMDGPU 专属 EP：7 处（AMDGPUTargetMachine.cpp:1021-1137，已核实）；NVPTX 2 处（NVPTXCodeGenPassBuilder.cpp:325/:342）

## 4.5 主会话插桩与 PA 实测（2026-09-30，产物在 scratch/）


| 实验 | 命令核心 | 结果 |
|---|---|---|
| PA 重建 | `opt -p 'function(require<domtree>,invalidate<domtree>,require<domtree>)' -debug-pass-manager` | Running: DominatorTreeAnalysis ×2 + Invalidating ×2——**invalidate 精准击穿缓存，第二次 require 重建**；第二次 Invalidating 来自 adaptor 收尾清理（PassManagerImpl.h:95 preserveSet 的实证） |
| PA 缓存对照 | 同上但去掉 invalidate | Running ×1——缓存命中 |
| print-changed | `-p 'default<O1>' -print-changed=quiet` | 可用，只打印有 IR 变化的 pass |
| **diff 模式坑** | `-print-changed=diff-quiet` | **macOS 上坏**：LLVM 调系统 diff 传 GNU 专属 `--old-line-format=-%l`，BSD diff 报 unrecognized option——复现手册必须标注（Linux/GNU diff 正常） |
| time-passes | `-time-passes` | 可用，Instr 列含硬件指令计数 |
| opt-bisect | `-opt-bisect-limit=3` | 可用，"BISECT: running/NOT running pass (N)" 序列清晰 |
| time-trace | `-time-trace -time-trace-file=` | 可用，125 trace events 的 Chrome tracing JSON |

注意：`-p 'default<O1>'` 必须引号包裹（`<` 会被 shell 当重定向）。

## 5. 章节规划与素材对照

| 章 | 素材 | 产出方式 | 状态 |
|---|---|---|---|
| §1 双 PM 并存格局 | 01-dual-pm.md | 子代理采集 | **完成**(678 行;抽查 5/5 中:RunCodeGen.cpp:97-111 分叉/TargetMachine.h:512 默认 false/Lanai:63+MSP430:59 仅此两家 override/CodeGenPassBuilder 虚分发(修正主会话旧认知:非 CRTP)/PMStack) |
| §2 PassInfoMixin 核心抽象 | 02-core-abstractions.md | 子代理采集 | **完成**(487 行;抽查 3/3;重要发现:RequiredPassInfoMixin 2026-05 新增/PassConcept 手工 vtable 化 2026-07) |
| §3 AnalysisManager | 03-analysis-manager.md | 子代理采集 | **完成**(395 行;抽查 Windows DLL FIXME/AAManager 聚合 ✓) |
| §4 PA 失效契约（重心） | 04-preserved-analyses.md + 04-preserved-analyses-main.md | 子代理采集+主会话精读(已完成) | **完成**(421+~130 行;抽查 4/4 中;纠正主会话"MF pass 不返回 PA"误解) |
| §5 四 IRUnit 适配 | 05-adaptors.md | 子代理采集 | **完成**(584 行;抽查 6/6 中:PM.cpp:128-170/CGPCM.cpp:169-175 UR 构造/LPM.cpp:193-227+LAR 八字段/LPM.h:398-404 强制注入/LoopAnalysisManager.h:52-61/adapt-loop-two-adaptors 实测复现逐字吻合;验收修正 3 处引用:printPipeline 在 CGSCCPassManager.h:470-486 非 .cpp、O2 转储是单行文件、空文件 adapt-loop-two-adaptors.txt 已重跑补齐 25 行) |
| §6 LazyCallGraph | 06-lazy-callgraph.md | 代理实测+主会话亲写 | **完成**(代理因输出流反复截断于 09-30 终止,实测产物全在 scratch/lcg-*;主会话亲验全部行号后成文 16 断言自查表;补做 devirt 正路径实验:internal constant global 下 InstCombinePass×2 实证重跑,负路径——外部可见 global 不折叠——同样实测) |
| §7 PassBuilder 解析 | 07-passbuilder.md | 子代理采集 | **完成**(245 行;抽查 6/6 中;round-trip 实测 diff 为空;纠正任务书 opt-pass-pipeline-printer.ll 不存在) |
| §8 EP 与插件 | 08-ep-plugins.md | 子代理采集 | **完成**(245 行;抽查 6/6 中;最小插件 opt+clang 双实测;纠正 PassPlugin.h 路径) |
| §9 legacy PM | 09-legacy-pm.md | 子代理采集 | **完成**(754 行;抽查含 PMStack 类名/五核心类行号;AMDGPU legacy insertPass 8 处) |
| §10 插桩体系 | 10-instrumentation.md | 子代理采集 | **完成**(556 行,已抽查:8 值表✓ doSystemDiff✓ 路径需修正为 llvm/lib/IR/PrintPasses.cpp) |
| §11 AMDGPU 案例（连接姊妹篇） | 复用姊妹篇数据 | 主会话成文 | 已有数据 |
| §12 复现手册 | 12-repro-manual.md + scratch/ | 主会话成文 | 初稿完成,待子代理产物补充 |

执行注记：§4 的 Analysis.h 主体（331 行）+ PassManagerImpl.h 主循环（:56-98）+ invalidate 算法（:169-230）+ adaptor stale 语义已由主会话逐行精读完毕，落盘 `04-preserved-analyses-main.md`（核心发现：双集合代数而非"三态"；abandon 单点否决；主循环 11 行三段论；invalidate 的双重判定+原地压缩）。

**成文进度（2026-10-01，最终）**：主文档 `PassManager_Deep_Analysis.md` 12/12 章全部并入（477 行正文），133 处 file:line / 54 文件经 `check-citations.py` 机械自查全部通过（脚本存 notes/）。素材层 10 份全部验收（每份 2-6 条断言抽查，全部命中；§6 为主会话亲写，16 断言全实测）。**项目完结。**

事故记录：§5§6 代理（a9d5a35a1e541fe6c）多次陷入"回复截断→重写→再截断"循环（stream watchdog 600s 无恢复），累计 3 次催办未果后于 09-30 终止——其 05 素材与全部实测产物已完整交付，仅 06 文档未写。§6 由主会话基于其产物亲验亲写。§7§8 代理（a191a746c5bb4c9e8）同样 stall，但 07/08 两份素材及实测在其停止前已完整落盘（394/354 行，均超原 245 行的扩写版），主文档 §7§8 早已并入验收。

外部评审修正（2026-10-01，第一轮）：§4.5"Debug 构建下 PA 撒谎是硬错误"范围过大——看门狗由 `-verify-analysis-invalidation` 门控（StandardInstrumentations.cpp:52-59 `#ifdef EXPENSIVE_CHECKS` 才默认 ON；本仓库 build-debug 为 OFF，CMakeCache.txt:843），且只覆盖 StructuralHash/CFG 的"变了没申报"，不验分析内容正确性。§5.5 的 MSSA fatal 检查同理只是拒绝"未声明保留"，不抓"声明保留但实际破坏"。两处主文档 + 素材层 04/10 共 5 处已全部改写并标注边界。

外部评审修正（2026-10-01，第二轮，8 主 + 4 次，全部核实成立）：① §3.3 失效判定是"有自定义 invalidate 即委托 / 无则默认 PA checker"二选一，非双层（PassManagerInternal.h:248-257 重写）；② §4.2 legacy 也在 pass 返回后即失效（LegacyPassManager.cpp:1457-1461），"逐 pass 失效"非新旧本质区别（改为引 §9.4 粒度对照）；③ §3.5 `require<domtree>` 是 `RequireAnalysisPass<DTA, Function>` 非 Module（实测 -debug-pass-manager 打印证实）；VerifierPass 返回 all()（Verifier.cpp:8427-8441）——第二次失效真因是 FPM 聚合 PA 携带 abandon<domtree> 击穿 adaptor 收尾 preserveSet（§4.1 代数的活体案例，已改写并补 require→verify→require 对照实验：domtree 只算一次）；④ §9.4 registerPass 重复注册返回 false 保留先注册者（PM.h:497-509）非断言；legacy AA 替换例子不成立——AA 有 AAResultsWrapperPass 聚合 + ExternalAAWrapperPass 注入通道（AliasAnalysis.cpp:779-835）；⑤ LCG：populate() 显式触发、operator*/-> 不自动建边（LCG.h:344-367）；DeadFunctions 是整模块遍历结束后批删非每 RefSCC（CGPCM.cpp:349-351 在外层 while 之外）；CGSCCUpdateResult 是 4 引用成员+3 自有值成员（CGPCM.h:247-303）非"全部引用"；⑥ ThinLTO prelink EP 是显式调用且 phase=ThinLTOPreLink（PassBuilderPipelines.cpp:1929-1936），不存在"转发到 postlink"；⑦ 插件 API v2 另有 PreCodeGenCallback（PassPlugin.h:54-60）可接管整个后端；⑧ clang 新 PM 跟踪用 `-Xclang -fdebug-pass-manager`（实测可用，BackendUtil.cpp:893），`-mllvm --debug-pass-manager` 是报错非静默；--print-pipeline-passes 是结构转储非执行跟踪。次要：10 target 漏 R600（R600TargetMachine.h:41）；preservedWhenStateless 非 GlobalsAA 专利（AAResults 等 10+ 处，已改为家族表述）；插桩成员 15 个含 DroppedStatsIR；三段式 RA 序为 SGPR→WWM→VGPR（实测 log 行 174/194/203）。修正后 146 引用/57 文件自查通过。

外部评审修正（2026-10-01，第三轮，4 主 + 2 引用 + 素材层 3 处，全部核实成立）：① §3.5 第二次 domtree 失效位置——不在"外层 Module PM"，全链在 adaptor 内部：FPM 收尾 preserveSet（PassManagerImpl.h:95）不摘除 abandon → ModuleToFunctionPassAdaptor 立即执行 `FAM.invalidate(F, PassPA)`（PassManager.cpp:153）击穿刚重建的结果，时机在下一个函数开始之前；§4.2 要点③同步补"集合保留通常避免重复失效但不能覆盖显式 abandon"；② §5.5 MSSA 内容校验有独立入口——未定义 NDEBUG 且 `LAR.MSSA && VerifyMemorySSA` 时逐 pass 调 `verifyMemorySSA()`（LoopPassManager.cpp:300-309；VerifyMemorySSA 默认仅 EXPENSIVE_CHECKS 为 true，MemorySSA.cpp:81-90，可显式 -verify-memoryssa）——删除原"靠 §4.5 CI 看门狗"的错误归因（与看门狗只覆盖结构/CFG 的边界矛盾）；③ §9.4 "同 ID transformation pass 互替"不成立——`AvailableAnalysis[PI]=P` 只更新查询映射，PMDataManager::add 仍执行 `PassVector.push_back(P)`（LegacyPassManager.cpp:979-1048，push 在 :1047）不移除已入流水线 pass；Codegen 真正的替换机制是 TargetPassConfig::substitutePass（TargetPassConfig.cpp:712-715）；④ §7.3 "对默认参数变化免疫"过强——反例：默认流水线构造 LoopUnrollPass 传入 OnlyWhenForced/ForgetSCEV（PassBuilderPipelines.cpp:1375-1377，源自 PTO，clang -fno-unroll-loops 经 BackendUtil.cpp:868 翻转），打印器（LoopUnrollPass.cpp:1819-1841）不输出、解析器（PassBuilder.cpp:908-948）无此拼写——实测 clang ±-fno-unroll-loops 打印文本逐字相同（loop-unroll<O2>），已改写为"文本可固定可打印的 pass 顺序和部分选项；完整复现仍需保存工具版本、target、流水线构建选项及命令行参数"。引用修正：§3.5 RequireAnalysisPass 构造点 :1942-1949 → PassBuilder.cpp:2450-2464（:1942 附近是 isFunctionPassName 的名称识别），并补"domtree 属 Function 层、顶层裸写经自动包裹下沉"；§11.1 姊妹文件 AMDGPULowerModuleLDS.cpp 不存在——legacy 类 AMDGPULowerModuleLDSLegacy 与工厂 createAMDGPULowerModuleLDSLegacyPass 均在 AMDGPULowerModuleLDSPass.cpp:1579-1594 同一文件。素材层同步：03-analysis-manager.md（:358 表格行 + :365 Verifier 归因段落，改为 adaptor :153 机制）、04-preserved-analyses-main.md:88（双重判定→二选一）、09-legacy-pm.md:550（断言→返回 false；补查询映射边界与 substitutePass 指引）。别名表补 LoopUnrollPass.cpp。修正后 154 引用/58 文件自查通过。
