# Clang Frontend(前端编排层)详细设计文档

> 基础设施系列第六篇,深入 `clang/lib/Frontend/`(及 `clang/include/clang/Frontend/`):
> CompilerInvocation 的选项装配、CompilerInstance 的对象中枢、FrontendAction
> 状态机、cc1 主循环、动作族谱、诊断输出子系统、依赖收集、ASTUnit /
> PrecompiledPreamble 工具侧门、Rewrite 子目录。所有类名、成员、行号均对照
> 本仓库代码核实。

---

## 目录

1. [总览:Frontend 是"编排层"而非"实现层"](#1-总览)
2. [命令行 → 配置:CompilerInvocation](#2-compilerinvocation)
3. [对象中枢:CompilerInstance](#3-compilerinstance)
4. [动作抽象:FrontendAction 状态机](#4-frontendaction-状态机)
5. [一次编译的完整时序](#5-一次编译的完整时序)
6. [内置动作清单(FrontendActions.cpp)](#6-内置动作清单)
7. [诊断输出子系统](#7-诊断输出子系统)
8. [依赖收集与预处理初始化(InitPreprocessor / Utils)](#8-依赖收集与预处理初始化)
9. [工具侧门:ASTUnit 与 PrecompiledPreamble](#9-工具侧门)
10. [Rewrite 子目录](#10-rewrite-子目录)
11. [设计取舍与不变量](#11-设计取舍与不变量)
12. [速查表](#12-速查表)

---

## 1. 总览

Frontend 目录回答的问题是:**Driver 已经把参数翻译成 cc1 命令行,接下来
谁把 Lex/Parse/Sema/CodeGen 这些散件组装起来跑一遍?** 答案就是本目录的
三大件:

```text
clang -cc1 命令行
   │
   ▼
CompilerInvocation ── 把 argv 解析成 13 组选项对象(§2)
   │
   ▼
CompilerInstance ─── 持有并按需创建全部编译对象(§3)
   │  ExecuteAction():对每个输入文件跑一遍 FrontendAction
   ▼
FrontendAction ───── 一个动作 = 一种"对翻译单元做什么"(§4)
   │  BeginSourceFile → Execute → EndSourceFile 状态机
   ▼
   ├─ ASTFrontendAction        → ParseAST(Sema)(经典编译)
   ├─ PreprocessorFrontendAction → 只跑 Lex(-E、dump tokens)
   ├─ PluginASTAction          → 插件动作
   └─ WrapperFrontendAction    → 包装/拦截既有动作
```

规模感:`clang/lib/Frontend/` 共 32 个 .cpp、约 2.46 万行(不含 Rewrite
子目录),其中最大的四个文件是 CompilerInvocation.cpp(5126 行)、
ASTUnit.cpp(2740 行)、CompilerInstance.cpp(2365 行)、InitPreprocessor.cpp
(1620 行)。CMake 上它汇成 `clangFrontend` 库,直接链接恰好这 9 个库:
`clangAPINotes/clangAST/clangBasic/clangDriver/clangEdit/clangLex/clangParse/
clangSema/clangSerialization`(CMakeLists.txt:51-59;传递闭包也只再加
clangAnalysis/clangSupport 两个)——**注意没有一个链接是"Frontend 自己的
算法"**:本目录的价值在于把各库的能力按动作编排起来。

按职责分组:

| 组 | 文件 | 职责 |
|---|---|---|
| 配置 | CompilerInvocation.cpp、FrontendOptions.cpp、CreateInvocationFromCommandLine.cpp | argv ↔ 选项对象双向映射;扩展名 → InputKind |
| 中枢 | CompilerInstance.cpp | 持有/创建 PP、ASTContext、Sema、ASTReader… |
| 动作 | FrontendAction.cpp、FrontendActions.cpp、ASTConsumers.cpp、ASTMerge.cpp、MultiplexConsumer.cpp、InterfaceStubFunctionsConsumer.cpp | 动作抽象 + 具体动作 |
| 诊断输出 | TextDiagnostic*.cpp、DiagnosticRenderer.cpp、SARIFDiagnostic*.cpp、SerializedDiagnostic*.cpp、LogDiagnosticPrinter.cpp、ChainedDiagnosticConsumer.cpp、VerifyDiagnosticConsumer.cpp | 诊断的渲染/序列化/校验 |
| 依赖 | DependencyFile.cpp、DependencyGraph.cpp、ModuleDependencyCollector.cpp、HeaderIncludeGen.cpp | -MD/-MM/-H/-showIncludes |
| 预处理装配 | InitPreprocessor.cpp、PrintPreprocessedOutput.cpp、ChainedIncludesSource.cpp | 预定义宏、-E 输出 |
| 工具侧门 | ASTUnit.cpp、PrecompiledPreamble.cpp、LayoutOverrideSource.cpp | libclang/clangd 的复用单元 |
| 其它 | TestModuleFileExtension.cpp、Rewrite/ | 模块扩展测试、源码改写 |

---

## 2. CompilerInvocation

`CompilerInvocation`(CompilerInvocation.h:211)是"一次编译的全部配置"的
值对象。它的全部内容装在基类 `CompilerInvocationBase`(CompilerInvocation.h:74)
的 **13 组选项对象**里,全部共享所有权——11 组是 `shared_ptr`,唯
DiagnosticOpts(`IntrusiveRefCntPtr`)与 AnalyzerOpts(其别名
`AnalyzerOptionsRef`)用侵入式引用计数:

| 成员 | 类型 | 管什么 |
|---|---|---|
| LangOpts | shared_ptr\<LangOptions\> | 语言方言:C++ 标准、ObjC、OpenCL… |
| TargetOpts | shared_ptr\<TargetOptions\> | triple、CPU、ABI |
| DiagnosticOpts | IntrusiveRefCntPtr\<DiagnosticOptions\> | 诊断显示(-fno-caret-diagnostics…) |
| HSOpts | shared_ptr\<HeaderSearchOptions\> | include 路径、sysroot、模块缓存 |
| PPOpts | shared_ptr\<PreprocessorOptions\> | -D/-U、-include、remap |
| AnalyzerOpts | AnalyzerOptionsRef | 静态分析器 |
| MigratorOpts | shared_ptr\<MigratorOptions\> | 迁移器 |
| APINotesOpts | shared_ptr\<APINotesOptions\> | API notes(Swift 互操作) |
| CodeGenOpts | shared_ptr\<CodeGenOptions\> | IRgen 与后端 |
| FSOpts | shared_ptr\<FileSystemOptions\> | 文件系统行为 |
| FrontendOpts | shared_ptr\<FrontendOptions\> | 前端自身(动作、输入输出) |
| DependencyOutputOpts | shared_ptr\<DependencyOutputOptions\> | 依赖文件格式 |
| PreprocessorOutputOpts | shared_ptr\<PreprocessorOutputOptions\> | -E 输出格式 |

**用共享指针而非值成员是有意的**:注释(CompilerInvocation.h:70-73)
说明这服务于"客户端想在 CompilerInvocation 销毁后仍保住个别选项对象"的
场景——典型就是 ASTUnit 把 LangOpts(即 Invocation 的那把 shared_ptr)
存进自己的同名成员(ASTUnit.cpp:1212),跨多次 Reparse 复用。

### 2.1 双向映射

CompilerInvocation 的核心能力是 **argv ↔ 选项对象** 两个方向:

- **正向** `CreateFromArgs`(CompilerInvocation.h:293,实现于
  CompilerInvocation.cpp:4895):把不含 `-cc1` 的参数数组解析进 `Res`。失败时
  尽力恢复、继续解析剩余参数(返回 false 但 Res 处于可访问状态)。内部再
  细分为静态成员 `ParseLangArgs`(:346)/`ParseCodeGenArgs`(:352)与自由
  函数 `ParseDiagnosticArgs`(声明于 :66、实现 CompilerInvocation.cpp:2517)。
  这个 5126 行的文件之所以巨大,主要就是这两个方向的逐选项翻译。
- **反向** `generateCC1CommandLine`(CompilerInvocation.h:161/176):从选项
  对象重新生成规范的 cc1 参数序列。调用方负责补上可执行文件路径和 `-cc1`。

双向性带来两处自检机制:

- `CreateFromArgs` **内部**就做 round-trip:解析 → 再生成 → 比对,由
  `-round-trip-args` / `-no-round-trip-args` 开关,断言构建(未定义
  NDEBUG)下默认开(CompilerInvocation.cpp:786-807)。clang 测试套件同时
  传 `-Rround-trip-cc1-args`(cc1_main.cpp:235)让 remark 可见
  (round-trip-cc1-args.c),防止选项翻译不对称地丢信息;
- 独立的 `checkCC1RoundTrip`(CompilerInvocation.h:328)对现成 argv 做同样
  的"解析 → 再生成 → 比对",树内调用方是 clang-scan-deps
  (ClangScanDeps.cpp:417)。

### 2.2 CowCompilerInvocation

`CowCompilerInvocation`(CompilerInvocation.h:360)是拷贝时只做
`shallow_copy_assign`(共享选项对象指针)的变体;需要写入时通过
`getMutLangOpts()` 等入口按需深拷贝。`CompilerInvocation` 的拷贝构造则走
`deep_copy_assign`(CompilerInvocation.h:214-217)。树内用户是
Tooling/DependencyScanning 的 ModuleDepCollector:显式模块依赖扫描要为
上千个模块各持一份"从基准 invocation 微调而来"的副本,浅拷贝是性能前提。

### 2.3 FrontendOptions:动作与输入

FrontendOptions.h 定义了三件事:

1. **`frontend::ActionKind`**(FrontendOptions.h:37-152):约 40 种动作
   枚举,`-emit-obj`、`-emit-llvm`、`-emit-assembly`、`-E`、
   `-fsyntax-only`、`-emit-pch`、`-emit-module`、`-ast-dump`、
   `-verify-pch`、`-fixit`、`-rewrite-objc`、`-extract-api`……
   `ProgramAction` 字段(FrontendOptions.h:517)默认 `ParseSyntaxOnly`。
2. **`InputKind`**(FrontendOptions.h:157):语言(Language)+ 格式
   (Source/ModuleMap/Precompiled)+ 是否预处理过 + header-unit 种类 +
   `IsHeader`(:185)共五个位段,全部压缩在位域里。
3. **`FrontendInputFile`**(FrontendOptions.h:232):文件路径或
   MemoryBufferRef + InputKind,可来自 stdin("-")。

另有大量开关位域(RelocatablePCH、SkipFunctionBodies、BuildingImplicitModule、
UseTemporary…)与插件相关列表(`Plugins`、`AddPluginActions`、`PluginArgs`)。
对应的 FrontendOptions.cpp 本体只有 39 行、一个函数:
`getInputKindForExtension`(FrontendOptions.h:617)用 StringSwitch 把文件
扩展名(.c/.cpp/.m/.mm/.cu/.ll/.ast…)映射成 InputKind,调用方是
CompilerInvocation.cpp:3096(装配 Inputs 时)与 CGDebugInfo(按扩展名
猜语言)。

### 2.4 createInvocation:工具的"迷你 driver"

`Utils.h:236` 的 `createInvocation`(实现在 CreateInvocationFromCommandLine.cpp,
109 行)给 libclang/clangd 这类工具用:输入普通 clang 风格命令行,**模拟**
driver 的动作选择、系统探测、cc1 参数推导,直接产出 CompilerInvocation,
省去真跑一遍 driver 进程。注释(Utils.h:217-227)明确承认这是有损模拟——
一次 driver 运行可能产生多个编译(CUDA offload、多架构),这里只挑"合理
的一个"。`CreateInvocationOptions`(Utils.h:195-215)提供 VFS 注入、错误
恢复、cc1 参数导出等旋钮。

---

## 3. CompilerInstance

`CompilerInstance`(CompilerInstance.h:79)继承 `ModuleLoader`,头文件注释
(CompilerInstance.h:61-78)把它的话说得很直白,两个用途:

1. **管理跑一遍编译所需的全部对象**——预处理器、目标信息、AST 上下文……;
2. **提供构造/操纵这些公共对象的工具函数**。

并且刻意做成"简化但不锁定":工具函数尽量提供**两种形态**——短形态复用
CompilerInstance 自己的对象,长形态由调用者显式传入对象。这个姿态是给
libclang 这类宿主留的活口。

### 3.1 它持有什么

成员(CompilerInstance.h:80-203)按所有权类型分三档:

```text
IntrusiveRefCntPtr(侵入式引用计数)        shared_ptr              unique_ptr
─────────────────────────────────────  ─────────────────────  ──────────────────
DiagnosticsEngine   :84                 Invocation       :81   Consumer      :111
Target / AuxTarget  :87,90              PP               :102   CompletionConsumer :114
FileMgr             :93                 ModuleDepCollector:129  TheSema       :117
SourceMgr           :96                 ThePCHContainerOperations :132
ModuleCache(InMemoryModuleCache) :99    FailedModules(shared set) :152
Context(ASTContext) :105
TheASTReader(ASTReader) :126
```

此外还有:定时器组(:120-123)、依赖收集器列表 `DependencyCollectors`
(:134)、已构建模块表 `BuiltModules`(:156)、输出文件列表 `OutputFiles`
(:200,配合临时文件原子替换)、可选的 `OutputStream`(:203)。

几个值得注意的设计:

- **`FailedModulesSet` 用 `shared_ptr` 跨实例共享**(:144-152):隐式模块
  构建会递归地 spawn 新 CompilerInstance,一个模块在任何实例里构建失败,
  其它实例立即放弃,避免重复报错。
- **`resetAndLeak*` 家族 + `llvm::BuryPointer`**(:455-457 等):配合
  `-disable-free` 在退出时故意"泄漏"对象跳过析构,加速进程退出。
- **PCH 容器抽象**:`ThePCHContainerOperations`(:132)按
  `HeaderSearchOpts.ModuleFormat` 选择 writer/reader(:586-610),默认注册
  raw 直通格式,cc1_main.cpp:219-220 额外注册了对象文件包装格式
  (`ObjectFilePCHContainerWriter/Reader`,把 PCM 装进 .o)。

### 3.2 ExecuteAction:主循环

`CompilerInstance::ExecuteAction`(CompilerInstance.cpp:1010)是 cc1 的
心脏,骨架只有一屏:

```cpp
if (!Act.PrepareToExecute(*this)) return false;   // :1027
if (!createTarget()) return false;                // :1030
...
for (const FrontendInputFile &FIF : getFrontendOpts().Inputs) {  // :1054
  if (hasSourceManager() && !Act.isModelParsingAction())
    getSourceManager().clearIDTables();           // 复用 SourceManager 必须清表
  if (Act.BeginSourceFile(*this, FIF)) {          // 逐文件初始化(§5)
    if (llvm::Error Err = Act.Execute())          // 跑动作
      consumeError(std::move(Err));
    Act.EndSourceFile();                          // 逐文件收尾
  }
}
printDiagnosticStats();                           // "N warnings and M errors generated."
return !getDiagnostics().getClient()->getNumErrors();   // :1093
```

要点:

- **多输入**:cc1 可一次处理多个输入文件(如 -emit-ast 批量),每个走完整
  的 Begin/Execute/End 循环;
- **返回值即"是否有 error"**——warning 不算失败;
- `ExecuteAction` 前的杂务:RewriteObjC 需要改 Target 的 ObjC bool 表示
  (:1033-1035)、`-ftime-report` 建前端计时器(:1043-1044,字段名仍叫
  TimePasses)、统计开关、toc-data 变量排序等。

`LoadRequestedPlugins`(:1126)用
`llvm::sys::DynamicLibrary::LoadLibraryPermanently` 加载 `-load` 的动态库
——插件通过静态注册对象把 `PluginASTAction` 塞进
`FrontendPluginRegistry`(FrontendPluginRegistry.h:22,即
`llvm::Registry<PluginASTAction>`)。

### 3.3 惰性 create* 家族

CompilerInstance 不在构造时建任何重对象,全部走 `createXxx()` 按需创建并
替换现有者(供 FrontendAction 或宿主调用):

| 方法 | 位置 | 做什么 |
|---|---|---|
| createDiagnostics | CompilerInstance.h:683 | 建 DiagnosticsEngine + TextDiagnosticPrinter(或自定义 client) |
| createFileManager | :713 | FileManager(可注入 VFS) |
| createSourceManager | :717 | SourceManager |
| createTarget | CompilerInstance.cpp:107 | TargetInfo/AuxTarget:`TargetInfo::CreateTargetInfo`(Targets.cpp:763)按 triple 走 `AllocateTarget` 的 `switch (Triple.getArch())`(Targets.cpp:112)直接 new 具体架构子类 |
| createPreprocessor | :445 | 见 §3.4 |
| createASTContext | :550 | `new ASTContext(LangOpts, SourceMgr, IdentifierTable, SelectorTable, BuiltinInfo, TUKind)` + InitBuiltinTypes——**ASTContext 的零件全部从 Preprocessor 拿**,这是 PP 与 AST 共享 Identifier 表的具体形态 |
| createSema | :745 | Sema(挂 ExternalSemaSource、ASTConsumer 引用) |
| createASTReader | :1707 | ASTReader(PCM 反序列化器) |
| createPCHExternalASTSource | CompilerInstance.h:733 | 加载 -include-pch 指定的 PCH |
| createCodeCompletionConsumer | :755 | 截断输入源文件到补全点 |
| createDefaultOutputFile / createOutputFile | :779/788 | 输出流(临时文件+原子改名,信号时清理) |

### 3.4 createPreprocessor:一个方法装下半个装配线

CompilerInstance.cpp:445-538 值得通读,它展示 PP 是如何被"喂大"的:

```text
new HeaderSearch(HSOpts, SourceMgr, Diags, LangOpts, &Target)     :452
new Preprocessor(PPOpts, Diags, LangOpts, SourceMgr, HeaderInfo,
                 *this /*ModuleLoader*/, TUKind)                  :455
Target.adjust(Diags, LangOpts)      // 目标修正语言选项(如 wchar_t 大小) :460
PP->Initialize(Target, AuxTarget)   // 传 TargetInfo(指针比较的陷阱见 Lex 篇) :461
[DetailedRecord] PP->createPreprocessingRecord()                  :463
InitializeFileRemapping(...)        // -frewrite-map 等           :467
InitializePreprocessor(*PP, ...)    // 预定义宏/内置宏,见 §8.2    :471
ApplyHeaderSearchOptions(...)       // 展开搜索路径为目录列表      :482
[Modules] setModuleCachePath(getSpecificModuleCachePath(hash))    :487-492
依赖收集三件套:DependencyFileGenerator / DependencyGraphGen /
              ModuleDependencyCollector(:494-516)
HeaderIncludeGen(-H、/showIncludes)                              :521-537
```

注意 `*this` 作为 ModuleLoader 传入 PP——**include 一个模块时,回调最终落
到 `CompilerInstance::loadModule`(CompilerInstance.cpp:2017)**,包括"找不到
就现场编译"的隐式模块逻辑(`findOrCompileModuleAndReadAST`,
CompilerInstance.h:864)。这就是 CompilerInstance 继承 ModuleLoader 的原因:
它是模块加载的宿主。

---

## 4. FrontendAction 状态机

FrontendAction.h:36 的 `FrontendAction` 是模板方法模式的教科书实现:
基类管流程(BeginSourceFile/Execute 是公有非虚入口,EndSourceFile 是公有
**虚**入口——WrapperFrontendAction 会重写它以拦截收尾),子类只填虚钩子:

| 钩子(FrontendAction.h) | 调用时机 | 默认行为 |
|---|---|---|
| `PrepareToExecuteAction` :55 | ExecuteAction 之前,可改配置 | return true |
| `CreateASTConsumer` :70 | BeginSourceFile 中段(纯虚) | — |
| `BeginInvocation` :79 | BeginSourceFile 最前,可改 Invocation | return true |
| `BeginSourceFileAction` :85 | 文件级初始化 | return true |
| `ExecuteAction` :94 | 主工作(纯虚) | — |
| `EndSourceFileAction` :100 | 文件级收尾 | 空 |
| `shouldEraseOutputFiles` :108 | 收尾时决定删不删输出 | 有 error 则删(:1161) |

能力协商虚函数( answering "这个动作能用什么输入"):`usesPreprocessorOnly`
(:185,纯虚)、`hasPCHSupport`/`hasASTFileSupport`/`hasIRSupport`/
`hasCodeCompletionSupport`(:191-200)、`isModelParsingAction`(:179)。

### 4.1 四个子类骨架

- **`ASTFrontendAction`**(:243):最常用。`ExecuteAction` 的实现
  (FrontendAction.cpp:1169-1194)就是三步——按需建 code completion
  consumer、`CI.createSema(...)`、**`ParseAST(Sema, ShowStats,
  SkipFunctionBodies)`**(FrontendAction.cpp:1192)。Parse→Sema→ASTConsumer
  的流水线由此接通。
- **`PreprocessorFrontendAction`**(:288):`usesPreprocessorOnly() == true`,
  不建 ASTContext。`-E`、`-dump-tokens`、Rewrite 宏展开都落在这支。
  其 `CreateASTConsumer` 直接 `llvm_unreachable`(:1199-1202)。
- **`PluginASTAction`**(:257):插件动作基类,增加 `ParseArgs`(解析
  `-plugin-arg-` 参数)与 `ActionType`(:272-280)——ReplaceAction(顶替
  主动作)/ AddBeforeMainAction / AddAfterMainAction / Cmdline 前后缀(仅当
  命令行点名 `-add-plugin` 时生效)。
- **`WrapperFrontendAction`**(:305):持有 `WrappedAction`,把**所有**虚
  方法转发给它(:1204-1251)。用于在既有动作外圈注入逻辑,例如 ARCMigrate
  的迁移、FixItRecompile(-fixit 后接着编译)。

### 4.2 插件如何变成 MultiplexConsumer

`CreateWrappedASTConsumer`(FrontendAction.cpp:163-241)是插件机制的汇合点:

1. 先取子类的 `CreateASTConsumer` 作为主 consumer;
2. 校验 `-add-plugin` 名字都能在 FrontendPluginRegistry 里找到(:170-185);
3. **代码补全运行时直接跳过插件**(:191-193,避免污染补全结果);
4. 遍历注册表,按 ActionType 分到 Consumers(主前)/ AfterConsumers(主后),
   逐个 `ParseArgs` + `CreateASTConsumer`(:197-227);
5. 主 consumer 入列,若存在"主后"插件则置
   `CodeGenOpts.ClearASTBeforeBackend = false`(:235)——因为主动作(代码
   生成)本来会在进后端前清空 ASTContext 腾内存,但后面的插件还需要它;
6. 返回 `MultiplexConsumer`(所有回调广播到每个成员)。

`MultiplexConsumer`(MultiplexConsumer.h:51)继承 `SemaConsumer`,把
ASTConsumer 的 20 来个回调(HandleTopLevelDecl、HandleTranslationUnit…)
逐一转发;连 `GetASTMutationListener` / `GetASTDeserializationListener` 也
合成 Multiplex 版本,保证 PCH/PCM 事件不丢。

---

## 5. 一次编译的完整时序

把 §3-§4 串起来。以 `clang -cc1 -emit-obj foo.c` 为例:

```text
cc1_main(cc1_main.cpp:211)
 ├─ new CompilerInstance;注册 ObjectFile PCH 容器(:219-220)
 ├─ TextDiagnosticBuffer 兜住建 DiagnosticsEngine 之前的参数错误(:230-232)
 ├─ CompilerInvocation::CreateFromArgs(:239)
 ├─ GetResourcesPath 推导资源目录(编译器自带头文件所在,:259-263)
 ├─ Clang->createDiagnostics();DiagsBuffer->FlushDiagnostics(:266-275)
 └─ ExecuteCompilerInvocation(FrontendTool/ExecuteCompilerInvocation.cpp:206)
     ├─ -help / -version early return
     ├─ Clang->LoadRequestedPlugins()(:225,须在 -mllvm 之前——插件可注册
     │   LLVM 选项,代码注释 :230 明言)
     ├─ -mllvm / 静态分析帮助(各 early return)
     └─ CreateFrontendBaseAction(声明 :39-40,ProgramAction switch :45)
         switch (ProgramAction) { case EmitObj:
             return std::make_unique<EmitObjAction>(); ... }        // ~40 项
       → CreateFrontendAction()再包一层 ARCMT/ObjC-migrator 包装
       → Clang->ExecuteAction(*Act)
          ├─ createTarget()
          └─ 对每个输入:
             Act.BeginSourceFile(CI, Input)   ← 本节主角
             Act.Execute()
             Act.EndSourceFile()
```

### 5.1 BeginSourceFile:八条岔路的初始化

FrontendAction.cpp:586-1069,长但结构清晰。开头用
`llvm::make_scope_exit` 登记 `FailureCleanup`(:600-608)——任何一条 return
false 都会清 ASTConsumer、擦输出文件、复位输入,保证调用方不必调
EndSourceFile(成功路径末尾 `release()`,:1067)。之后按输入类型分流:

1. **AST 回放**(:615-681):`usesPreprocessorOnly` 且输入是 AST 文件——
   用 ASTUnit 重放当初的构建(继承 HeaderSearch/Lang/PP 选项,预载全部
   模块),用于 `-E` 一个 .ast 这类场景。
2. **AST 文件输入**(Precompiled 格式,:685-730):`ASTUnit::LoadFromASTFile
   (LoadEverything)` 后,**把 ASTUnit 的 FileManager/SourceManager/PP/
   ASTContext 换进 CI**(:709-715)。注释说得明白:AST 文件自带这些对象,
   CI 的对应物不应初始化、处理完还得还回去(见 §5.2)。
3. **常规源文件**:依次
   - 建 FileManager/SourceManager(不存在时,:733-745;SARIF 模式顺手套
     SarifDocumentWriter);
   - `-fmodules-embed-file` 标记 transient(:749-756);
   - **LLVM_IR 输入直接绕过**其余初始化(:759-780,只允许 hasIRSupport
     的动作);
   - `-include-pch` 给的是目录则扫描挑一个可用 PCH(:784-815,
     `ASTReader::isAcceptableASTFile` 严格匹配);
   - `CI.createPreprocessor(TUKind)`(:820);
   - 通知诊断 client `BeginSourceFile`(:823,TextDiagnostic 由此知道
     LangOptions 以决定打印细节);
   - **C++20 header unit**(:827-883):按 user/system/abs 三种查找方式把
     头文件名落成绝对路径,模块名默认取文件路径;
   - **module map 输入**(:887-919):`loadModuleMapForModuleBuild` 解析
     module map(:446-487),`prepareToBuildModule` 挖出 Module 定义并检查
     可构建性(:489-557),然后 `getInputBufferForModule` **合成一个
     `<module-includes>` 缓冲区**——把 module 描述转成一串 #include 当作
     主文件(:560-584),后续流程与普通源码无异。这是 Clang 模块构建
     复用常规流水线的关键技巧;
   - `BeginSourceFileAction` 钩子(:922);
   - 加载 `-fmodule-map-file`、模块实现单元的 map(:926-942);
   - **建 ASTContext + Consumer**(非 PP-only,:946-1016):
     `CI.createASTContext()` → `CreateWrappedASTConsumer`(插件汇入,
     §4.2)→ 挂 ASTMutationListener → 处理 ChainedIncludes(:966-973,
     旧式链式 PCH,主要供测试)或 PCH/模块:`createPCHExternalASTSource`
     + `createASTReader`(:974-1011);
   - **builtin 初始化**(:1018-1031):无外部 AST 源时
     `PP.getBuiltinInfo().initializeBuiltins(IdentifierTable, LangOpts)`。
     有模块时刻意提前建 ASTReader(:1002-1010 注释),让所有声明都知道
     自己可能被外部源扩展;
   - `-fmodule-file` 逐个 `loadModuleFile`(:1034-1042);
   - 布局覆盖(LayoutOverrideSource,:1046-1052)与 HLSL 的
     ExternalSemaSource(:1055-1065)。

### 5.2 Execute 与 EndSourceFile

`Execute`(FrontendAction.cpp:1071)套上前端计时器后调 `ExecuteAction()`,
随后处理**全局模块索引重建**(:1082-1095,`shouldBuildGlobalModuleIndex`
且无模块构建失败时 `GlobalModuleIndex::writeIndex`)。

`EndSourceFile`(:1100-1159)是镜像收尾:诊断 client 与 PP 的
EndSourceFile → `EndSourceFileAction` 钩子 → **析构顺序**:
先 Sema(它引用着 consumer)再 ASTContext 再 consumer(:1113-1125;
`-disable-free` 时全部换成泄漏)。`-print-stats` 打印统计
(:1127-1134)。`clearOutputFiles(shouldEraseOutputFiles())` 决定输出文件
去留(:1138)。**若当前文件是 AST**(对象归 ASTUnit 所有),把 CI 里的
PP/SourceMgr/FileManager 置空"还回去"(:1143-1154)。最后复位 CurrentInput
与 CompilingModule 状态。

---

## 6. 内置动作清单

FrontendActions.cpp(1214 行)+ ExecuteCompilerInvocation.cpp:44 的 switch
共同构成动作目录。按基类分组:

| 动作 | 基类 | 命令行 | 一句话 |
|---|---|---|---|
| SyntaxOnlyAction | ASTFrontendAction | -fsyntax-only | 空 consumer,只查语法(:320-326) |
| EmitObj/LLVM/BC/Assembly/CodeGenOnly/LLVMOnly | ASTFrontendAction(clang/CodeGen/CodeGenAction.h) | -emit-obj/-emit-llvm/… | CodeGenAction 家族,生成 LLVM IR 并可选跑后端 |
| GeneratePCHAction | ASTFrontendAction | -emit-pch | 见 §6.1 |
| GenerateModuleFromModuleMapAction | GenerateModuleAction | -emit-module | 隐式/显式模块构建(:232) |
| GenerateModuleInterfaceAction | GenerateModuleAction | -emit-module-interface | C++20 命名模块接口(:265) |
| GenerateReducedModuleInterfaceAction | GenerateModuleInterfaceAction | -emit-reduced-module-interface | 精简 BMI(:297,基类是接口动作再包一层) |
| GenerateHeaderUnitAction | GenerateModuleAction | -emit-header-unit | C++20 header unit(:305) |
| VerifyPCHAction | ASTFrontendAction | -verify-pch | 读 PCH 并校验(:334-339) |
| DumpModuleInfoAction | ASTFrontendAction | -module-file-info | 打印 PCM 元数据(:812 起) |
| ASTDump/Print/DeclList/ViewAction | ASTFrontendAction | -ast-dump/-ast-print/… | 打印 AST,consumer 来自 ASTConsumers.cpp |
| InitOnlyAction | FrontendAction | -init-only | 只做初始化(:62-69;重写 usesPreprocessorOnly=false 走 AST 路径) |
| ReadPCHAndPreprocessAction | FrontendAction | — | PCH 回放 + 预处理(:71;用户是 DependencyScanningWorker) |
| ExtractAPIAction(clang/ExtractAPI) | ASTFrontendAction | -extract-api | 生成符号图 |
| FixItAction / FixItRecompile(Rewrite/Frontend) | AST / Wrapper | -fixit | 应用 FixIt 重写源码 |
| DumpRawTokens/DumpTokensAction | PreprocessorFrontendAction | -dump-raw-tokens/-dump-tokens | 逐 token 打印(:976-1004) |
| PreprocessOnlyAction | 同上 | -Eonly | 只跑 PP(:1006;注意 -E 映射到 PrintPreprocessedInput) |
| PrintPreprocessedAction | 同上 | -E | DoPrintPreprocessedInput(调用处 :1084) |
| PrintPreambleAction | FrontendAction | -print-preamble | 只打印文件头(:1088;usesPreprocessorOnly=true) |
| RewriteMacros/Test/IncludesAction(Rewrite/) | 同上 | -rewrite-macros 等 | §10 |
| DumpCompilerOptionsAction | FrontendAction | -compiler-options-dump | :1123;usesPreprocessorOnly=true |
| TemplightDumpAction | ASTFrontendAction | -templight-dump | 模板实例化轨迹(:578) |
| HTMLPrintAction(Rewrite/) | ASTFrontendAction | -emit-html | 源码高亮 HTML |
| MigrateSourceAction(ARCMigrate) | ASTFrontendAction | -migrate | ObjC ARC 迁移(ARCMTActions.h:35) |
| GenerateInterfaceStubsAction | ASTFrontendAction | -emit-interface-stubs | .ifs 符号清单(switch :75-76) |
| ento::AnalysisAction | — | -analyze | 静态分析器入口(switch :125) |
| PluginAction | — | -plugin | 显式点名插件动作(switch :83-101) |
| PrintDependencyDirectivesSourceMinimizerAction | PreprocessorFrontendAction | -print-dependency-directives-minimized-source | 依赖指令最小化源码(switch :130-131) |
| RewriteObjCAction(Rewrite/) | PreprocessorFrontendAction | -rewrite-objc | ObjC→C 翻译(switch :114,须 CLANG_ENABLE_OBJC_REWRITER) |

注:除上表外,`CreateFrontendAction`(非 Base 版)还会在主动作外再包一层
包装动作:FixItRecompile、WrappingExtractAPIAction、ASTMergeAction、以及
ARCMT 的 MigrateAction/ObjCMigrateAction(这两个是 ARCMT 选项包装,与
-migrate 的 MigrateSourceAction 不同)。

### 6.1 GeneratePCHAction:Multiplex 的第一个用户

`GeneratePCHAction::CreateASTConsumer`(FrontendActions.cpp:123-150)返回
**两个 consumer 的 Multiplex**:

1. `PCHGenerator`(来自 clangSerialization):监听 AST 事件,把翻译单元
   序列化进共享的 `PCHBuffer`;
2. `PCHContainerWriter::CreatePCHContainerGenerator(...)`:把 PCHBuffer 的
   字节装进容器格式(raw 裸流,或 cc1 注册的 ObjectFile 包装)并写盘。

PCH 容器抽象(clang/Serialization/PCHContainerOperations.h:27-115:
PCHBuffer :27、Writer :36、Reader :55、Raw 直通对 :66、注册表 :87)
让"PCH 是裸文件还是藏在 .o 里"变成可插拔策略;`PCHBuffer{Signature,
Data, IsComplete}` 是两段之间的传递载体。`shouldEraseOutputFiles` 被改写
(:176-180):`AllowPCHWithCompilerErrors` 时即使有错也保留 PCH。
`BeginSourceFileAction` 置 `LangOpts.CompilingPCH = true`(:182-186),
消费者是 PPDirectives(构建 PCH 时 include/import 的处理分支,:2457/:2460/:2671)
与 ASTWriter(子模块 ID 分配，:2870)——CodeGen 完全不读它。

`GenerateModuleAction`(:187-230)是同一配方加模块参数;隐式模块构建时
PCHGenerator 还会带内存缓存(`ShouldCacheASTInMemory`),供 InMemoryModuleCache
跨 CompilerInstance 复用。

### 6.2 ASTConsumers.cpp 与 ASTMerge

ASTConsumers.cpp(216 行)提供几个轻量 consumer 工厂:
`CreateASTDumper`、`CreateASTPrinter`、`CreateASTDeclNodeLister`(:178)、
`CreateASTViewer`(graphviz)。ASTMerge.cpp(114 行)实现 `-ast-merge`:
把多个 AST 文件的声明合并进当前上下文——由 ASTMergeAction::ExecuteAction
(:33-81)驱动 **ASTImporter**(纯 AST 层，ASTImporterSharedState;Sema 不
参与)逐声明 Import(:68)。
InterfaceStubFunctionsConsumer(341 行)服务于 `-emit-interface-stubs`
(.ifs 符号清单)。

---

## 7. 诊断输出子系统

Frontend 目录里近三分之一的文件在做"诊断怎么出去"。层次:

```text
DiagnosticsEngine(clang/Basic,产生诊断)
   │ DiagnosticConsumer(接口:HandleDiagnostic/BeginSourceFile/EndSourceFile)
   ├─ TextDiagnosticPrinter(TextDiagnosticPrinter.h:27)── stderr 人类可读
   ├─ SARIFDiagnosticPrinter(SARIFDiagnosticPrinter.h:30)── SARIF JSON
   ├─ SerializedDiagnosticPrinter ── .dia 二进制(serialize 供工具链消费)
   ├─ LogDiagnosticPrinter ── 平面日志(-diagnostic-log-file)
   ├─ TextDiagnosticBuffer ── 纯缓存(cc1_main 参数阶段;VerifyDiagnosticConsumer 也持有一个)
   ├─ VerifyDiagnosticConsumer ── 包装前一个 client 做 -verify
   └─ ChainedDiagnosticConsumer(13 行)── 双 client 广播
        │
        ▼ 渲染细节(TextDiagnostic.cpp,1547 行)
   DiagnosticRenderer(:47)→ TextDiagnostic(:35)
        源码摘录、^~~~~ 定位、FixIt 提示、宏展开笔记、模板实例化回溯、
        "In file included from ..." 的 include 栈
```

设计要点:

- **Printer 与 Renderer 分离**:`DiagnosticConsumer` 的实现(TextDiagnosticPrinter)
  只管"何时/往哪输出",逐条诊断的**版式**全部下沉到 `DiagnosticRenderer`
  家族(DiagnosticRenderer.cpp,632 行)。这样 SARIF/SERIALIZED 各自的
  renderer 都能复用 note/子诊断的组织逻辑。
- **TextDiagnosticBuffer**(74 行):把诊断攒在内存。cc1_main 用它在
  DiagnosticsEngine 就绪前缓冲参数错误(:230-232),`FlushDiagnostics`
  一次性倒给真正的 client(:275);VerifyDiagnosticConsumer 内部也持有一个
  (:115)缓冲"过早出现"的诊断。
- **VerifyDiagnosticConsumer**(1181 行,-verify):测试设施的核心。它同时
  继承 `DiagnosticConsumer` 与 `CommentHandler`(VerifyDiagnosticConsumer.h:38)——**以注释处理器
  身份拦截源码注释**,解析 `// expected-error {{...}}` / `expected-warning`
  / `expected-remark` / `expected-no-diagnostics` 标记,与实收诊断比对,
  多了少了都报错。`Directive` 抽象(:43 起)支持计数区间(Min/Max)、
  正则/字面量匹配、跨行匹配。
- **SerializedDiagnosticPrinter/Reader** 成对:写 .dia、读 .dia(给
  fixit 工具、构建系统用)。格式常量在 SerializedDiagnostics.h
  (BLOCK_META/BLOCK_DIAG 两种块、RECORD_VERSION/DIAG/SOURCE_RANGE/DIAG_FLAG/
  CATEGORY/FILENAME/FIXIT 七种记录、稳定的 Level 枚举、版本号 2);
  SerializedDiagnosticReader.h(:60)是访问者模式基类——9 个 visit* 钩子
  (visitDiagnosticRecord/visitFixitRecord…)默认空实现,树内用户是
  libclang 的 CXLoadedDiagnostic(把 .dia 读回成 CXDiagnostic)。

---

## 8. 依赖收集与预处理初始化

### 8.1 DependencyCollector 家族(Utils.h:59-186)

接口:`attachToPreprocessor`(挂 PPCallbacks 收 include)+ `attachToASTReader`
(收模块 import),`sawDependency` 过滤(默认丢弃 \<built-in\> 与系统头)、
`maybeAddDependency` 去重入列:

| 类 | 输出 |
|---|---|
| DependencyFileGenerator(DependencyFile.cpp,418 行) | Make/NMake 格式 .d(-MD/-MMD/-MF) |
| ModuleDependencyCollector(ModuleDependencyCollector.cpp,183 行) | 把模块依赖**拷贝**进目录 + 生成 YAML VFS 映射,支持模块显式构建的"依赖打包" |
| AttachDependencyGraphGen(DependencyGraph.cpp) | dot 依赖图(-dependency-dot) |
| AttachHeaderIncludeGen(HeaderIncludeGen.cpp,321 行) | -H 缩进输出、/showIncludes(MSVC 风格)、JSON 格式 |

挂接点在 createPreprocessor(§3.4)。DependencyOutputOptions
(DependencyOutputOptions.h:34)控制格式细节;`ExtraDepKind`(:25-30,
含 EDK_ModuleFile/EDK_SanitizeBlocklist/EDK_ProfileList/EDK_DepFileEntry)
允许把模块文件、sanitize blocklist、profile list、-fdepfile-entry 条目
额外塞进依赖表。

### 8.2 InitPreprocessor.cpp:预定义宏的全部真相

`InitializePreprocessor`(Utils.h:50 声明,InitPreprocessor.cpp:1526 实现,
1620 行)做三件事:构造预定义 buffer(`__clang_major__` 等,InitializePredefinedMacros
:851,`__clang_major__` 在 :861)、应用 `-D/-U`(经 `DefineBuiltinMacro`,
定义 :41、调用 :1587)与 `-imacros/-include`(AddImplicitIncludeMacros /
AddImplicitInclude,:1600-1612)、写入 builtin 宏与目标特性宏。Lex 篇讲过的
`PP 起手读 <predefines> 虚拟文件`,源头就在这里。目标相关部分在
CUDA/OpenMP offload/SYCL 设备编译时对 aux target 先跑、主 target 后跑
(:1546-1553)。

`DoPrintPreprocessedInput`(Utils.h:56,实现在 PrintPreprocessedOutput.cpp:1077,
全文件 1161 行)实现 `-E`:逐 token 重排输出、行标记(`# 1 "foo.c"`)、
保留注释/宏展开控制。

配套小件:CommandLineSourceLoc.h 的 `ParsedSourceLocation` /
`ParsedSourceRange`(`file:line:col[-line:col]` 字符串 ↔ 结构体,
"-" 归一化为 `<stdin>`,还带 `llvm::cl::parser` 特化)——用户是
`-code-completion-at`(解析于 CompilerInvocation.cpp:2968,存进
FrontendOpts.CodeCompletionAt,消费于 CompilerInstance.cpp:710)与
clang-refactor 的选区参数。FrontendDiagnostic.h 则是转发壳,真正的
`err_fe_*`/`err_module_*` 诊断 ID 定义已迁至
clang/Basic/DiagnosticFrontend.h。

`createChainedIncludesSource`(Utils.h:191,ChainedIncludesSource.cpp):把
`-chain-include` 的头逐个编译成**内存中的链式 PCH**并串成
ExternalSemaSource(:30)。基本只有测试在用,但它是"CompilerInstance 嵌套
构建"的极好样本:每个头一个完整 CI,再链起来。

---

## 9. 工具侧门

### 9.1 ASTUnit:libclang 的编译单元封装

`ASTUnit`(ASTUnit.h:89)的头注释是 "Utility class for loading a ASTContext
from an AST file",实际早已超出:它是 **libclang/clangd 持有"一个翻译
单元"的标准容器**,自带全套对象(PP、Ctx、Sema、Reader、HeaderInfo、
存储的诊断)。与 CompilerInstance 的区别:**面向复用**——

- `LoadFromASTFile`(:695):从 .ast 读回整个单元(WhatToLoad 可只要 PP);
  BeginSourceFile 的"AST 输入"路径(§5.1 第 2 岔)正是借道于此;
- `LoadFromCompilerInvocation`(:723/:784):按 invocation 编译当前文件,
  可指定"解析 N 次后预编译 preamble";
- `Reparse`(:866):**用新内容重编,复用 preamble PCH**,只重解析 preamble
  之后的部分——编辑器每次敲键都全量重编是承受不起的,这是 libclang 的
  性能支柱;
- 诊断历史:StandaloneDiagnostic(结构体 :98)/ PreambleDiagnostics(:187)
  / StoredDiagnostic(:191)/ FailedParseDiagnostics(:195)分桶保存,跨
  Reparse 存活;
- `TopLevelDecls` + `FileDecls`(FIXME 注释 :166-172,声明 :173/:181):
  只为 Index 库做的缓存 hack,避免为找顶层声明反序列化整个 PCH。

`TrivialModuleLoader`(成员 :144,类定义在 Lex/ModuleLoader.h:166)——
ASTUnit 场景不加载模块,用空实现满足 Preprocessor 构造签名。

### 9.2 PrecompiledPreamble:preamble 的生命周期

`PrecompiledPreamble`(PrecompiledPreamble.h:51)把"preamble = 主文件中
第一个非预处理指令之前的头部"物化成可复用 PCH:

- `ComputePreambleBounds`(:42):跑 lexer 算 preamble 边界(行数上限);
- `Build(...)`:为某 invocation 构建 preamble(内存或临时文件存储,PCHStorage);
- `CanReuse` + `AddImplicitPreamble`:下次 Reparse 时若头文件与选项未变
  (PreambleFileHash),把 preamble 作为隐式 PCH 注入,跳过头部解析。

clangd 的"打开文件秒出诊断"就建立在这上面。`BuildPreambleError`
(:242)枚举 + error_category 走 `std::error_code` 通道。

### 9.3 LayoutOverrideSource

LayoutOverrideSource(262 行):读 `-fdump-record-layouts` 产出的文件,
作为 ExternalASTSource **覆盖记录布局**——测试不同 ABI 布局的利器,
挂接点在 BeginSourceFile(:1046-1052)。同类的
TestModuleFileExtension(137 行)供 PCM 扩展机制的自测。

---

## 10. Rewrite 子目录

`clang/lib/Frontend/Rewrite/`(8 个 .cpp)实现**源码改写**类动作。结构上
有个容易踩的坑:**全部 6 个 Action 类都定义在 FrontendActions.cpp**
(FixItAction:48、HTMLPrintAction:41、RewriteObjCAction:163、
RewriteMacrosAction:186、RewriteTestAction:195、RewriteIncludesAction:271),
其余文件只提供工人函数:

| 文件 | 工人函数/类 | 说明 |
|---|---|---|
| FixItRewriter.cpp | FixItRewriter(类在 .h:62) | 把诊断的 FixItHint 应用回源文件;本身是 DiagnosticConsumer,HandleDiagnostic(:129)提交改写,并**显式转发** note_fixit_applied/failed/unfixed_error(:180-196;Diag() :199 临时把自己从 client 链摘下直通下游)——逐条报告而非吞掉 |
| RewriteObjC.cpp | CreateObjCRewriter | ObjC→C 翻译器(上古遗物,-rewrite-objc) |
| RewriteModernObjC.cpp | 同上(现代版) | ARC 时代的重写器 |
| RewriteMacros.cpp | RewriteMacrosInInput | 宏全部展开后回写 |
| RewriteTest.cpp | DoRewriteTest | 测试场 |
| InclusionRewriter.cpp | RewriteIncludesInInput | include 全展开(-E 的"改写"变体) |
| HTMLPrint.cpp | CreateHTMLPrinter | 高亮 HTML 输出 |

共性:都是 PreprocessorFrontendAction 或 ASTFrontendAction + 一个改写
consumer。底座 Rewriter(编辑缓冲 + 偏移重写)在 **clang/Rewrite/Core/**
(Rewriter.h:32);clangEdit(EditedSource/Commit)只有 FixItRewriter 用。

---

## 11. 设计取舍与不变量

1. **编排层不藏算法**。Frontend 目录没有一行"如何展开宏"或"如何类型检查"
   ——那些在 Lex/Sema。它的复杂度是**接线复杂度**:八种输入形态(§5.1)、
   四类动作基类、插件包装、PCH/模块注入。读代码时把"哪条岔路"放在心里,
   长函数立刻可读。
2. **所有权三档制**(§3.1)不是随意的:引用计数指针给"多宿主共享"的对象
   (SourceManager 要被诊断/AST/工具同用);shared_ptr 给 invocation 的
   选项组(ASTUnit 跨 Reparse 保活);unique_ptr 给每文件独占的(Sema、
   consumer)。改一个成员的类型前先想清楚谁比谁活得久。
3. **FrontendAction 是模板方法而非函数指针表**:因为初始化顺序本身
   (consumer 要在 ASTContext 后、ASTReader 要在 builtin 前)是固定骨架,
   子类只允许在固定缝合点注入行为。
4. **失败清理靠 scope_exit 单点**(BeginSourceFile:600):八条岔路任何
   一条 return false,清理路径完全一致——不写这个,AST 文件输入这类
   "对象要还给 ASTUnit"的路径必然漏。
5. **能力协商前置**:`usesPreprocessorOnly`/`hasASTFileSupport` 等纯查询
   在 BeginSourceFile 早期就把不合法的组合挡掉(:686-688 的 assert、
   :759-764 的 IR 检查),而不是等到 ExecuteAction 里崩。
6. **双向选项映射 + round-trip 自测**(§2.1):CompilerInvocation 的
   parse/generate 是手写的两份真相,round-trip 检查把不对称在 CI 里就
   揪出来。
7. **不变量举例**:
   - ExecuteAction 返回 ⟺ 诊断 client 无 error(warning 不算);
   - BeginSourceFile 返回 true ⟹ 调用方必须配对调用 EndSourceFile;
   - 输入为 AST 文件期间,CI 的 PP/SourceMgr/FileManager 归 ASTUnit
     所有,EndSourceFile 必须还回去再清空;
   - 隐式模块构建的 PCM 路径由 `getSpecificModuleCachePath(ModuleHash)`
     (CompilerInstance.cpp:540,ModuleCachePath 拼 ModuleHash)唯一化,
     相同配置的模块命中同一 PCM。

---

## 12. 速查表

**入口链**(命令行 → 动作):

```text
clang -cc1 … → cc1_main(cc1_main.cpp:211)
  → CompilerInvocation::CreateFromArgs(:239)
  → ExecuteCompilerInvocation(FrontendTool/…:206)
  → CreateFrontendBaseAction(声明 :39-40,ProgramAction switch :45)
  → CompilerInstance::ExecuteAction(CompilerInstance.cpp:1010)
  → FrontendAction::{BeginSourceFile,Execute,EndSourceFile}
```

**文件 → 看点**:

| 想懂什么 | 看哪里 |
|---|---|
| 一个选项怎么被解析/再生成 | CompilerInvocation.cpp 对应 ParseXxxArgs/GenerateXxxArgs |
| PP 是怎么装配的 | CompilerInstance.cpp:445 createPreprocessor |
| 模块 map 如何变成可编译输入 | FrontendAction.cpp:887-919 + getInputBufferForModule:560 |
| PCH 怎么写出来 | FrontendActions.cpp:123 GeneratePCHAction + PCHContainerOperations.h |
| 插件怎么挂进主流程 | FrontendAction.cpp:163 CreateWrappedASTConsumer |
| -verify 怎么实现 | VerifyDiagnosticConsumer.h/.cpp(CommentHandler 拦注释) |
| .d 文件怎么生成 | Utils.h:63 DependencyCollector + DependencyFile.cpp |
| libclang 为什么快 | ASTUnit.h(Reparse)+ PrecompiledPreamble.h |
| -E 的输出排版 | PrintPreprocessedOutput.cpp DoPrintPreprocessedInput |

**典型调用链**(常规编译):

```text
CompilerInstance::ExecuteAction
 └ FrontendAction::BeginSourceFile
    ├ createPreprocessor → InitializePreprocessor(预定义宏)
    ├ createASTContext(ASTContext(PP 的五件套))
    ├ CreateWrappedASTConsumer → EmitObjAction::CreateASTConsumer
    │   → CodeGenAction(clang/CodeGen)→ BackendConsumer
    └ initializeBuiltins
 └ ASTFrontendAction::ExecuteAction
    └ ParseAST(Sema) → Parser 逐 Decl → ASTConsumer::HandleTopLevelDecl
        → BackendConsumer::HandleTopLevelDecl → EmitTopLevelDecl(CodeGen)
 └ FrontendAction::EndSourceFile
    └ Consumer->HandleTranslationUnit → 优化管线 → 后端 → .o
```

**与兄弟目录的边界**:Driver 管"用户命令 → 多个 cc1 进程",Frontend 管
"单个 cc1 进程内的一切";Lex/Parse/Sema/CodeGen 是被编排的工人;
Serialization 提供 PCHGenerator/ASTReader,Frontend 决定**何时**挂它们。
Rewrite/Core(Rewriter 本体)与 clangEdit(EditedSource)是 Rewrite 子
目录的两层底座，各自独立于 Frontend 目录存在。
