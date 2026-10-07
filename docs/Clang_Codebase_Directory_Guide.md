# Clang 代码目录介绍

> 本文基于本仓库实际 checkout 撰写,是《LLVM 代码目录介绍》的姊妹篇。
> 覆盖 `clang/` 子树的完整结构:编译流水线各阶段(lib/Lex → Parse → Sema →
> AST → CodeGen → Driver)、工具、测试与文档。

---

## 1. 顶层布局

```
clang/
├── include/clang/   # 公共头文件,与 lib/ 目录一一对应
├── lib/             # 编译器主体(本文重点)
├── tools/           # 可执行工具(driver、libclang、clang-format 等)
├── test/            # regression 测试(lit + FileCheck)
├── unittests/       # gtest 单元测试
├── docs/            # Sphinx 文档(InternalsManual.rst 等)
├── examples/        # 插件示例(analyzer plugin、clang-format plugin)
├── utils/           # 开发脚本(tablegen、appendcsv 等杂项)
├── runtime/         # 旧式 runtime 构建挂载点(已基本废弃)
├── bindings/        # Python/Go 绑定(测试性质)
└── www/             # 旧官网静态内容(仅历史保留)
```

include 与 lib 的对应规律同 LLVM:`include/clang/Sema/Sema.h` ↔
`lib/Sema/SemaExpr.cpp`。但 clang 有个额外关键点:**诊断信息、属性、
builtins 等由 TableGen 生成**:

- `include/clang/Basic/Builtins.def` → 生成 `Builtins.h` 中的 builtin 表
- `include/clang/Basic/Diagnostic*.td` → 诊断 ID 与文案
- `include/clang/Basic/Attr.td` + `AttrDocs.td` → 属性(`__attribute__`)定义
- `include/clang/AST/ASTNodes.td`、`include/clang/Basic/Stmt*.td` 等 → AST 节点基类声明(`DECL`/`STMT`/`EXPR` 宏展开体系)

---

## 2. 一条命令在 clang 内部的旅程

理解目录结构的最好方式是先看数据流。`clang -c hello.c -o hello.o` 内部:

```text
clang 驱动入口 (tools/driver)
  │  1. Driver:解析参数,决定 "-c" → Preprocess+Compile+BackendCompile
  │     选定 ToolChain(如 linux/x86_64 的一套外部命令),构造 Job
  │  2. 落到 cc1:clang -cc1(Frontend 的真正入口,CompilerInstance)
  │
  ├─ 3. Lex (lib/Lex):hello.c → Token 流,处理 #include/#define/pragma
  ├─ 4. Parse (lib/Parse):Token → "不完整"的 AST(动作只是建节点)
  ├─ 5. Sema (lib/Sema):边 parse 边做语义分析(类型检查、重载决议、
  │     隐式转换、模板实例化),AST 补全并挂上语义信息
  ├─ 6. ASTConsumer (lib/AST + lib/Frontend):AST 就绪后的各种消费者
  │     —— CodeGen、AST dumper、索引、重构、analyzer……
  ├─ 7. CodeGen (lib/CodeGen):AST → LLVM IR(Module 级 CodeGenAction)
  │     此后交给 LLVM 后端(opt 的活),产生 .o
  └─ (可选) 8. Rewrite/RewriteModern (lib/Rewrite):AST → 源码改写
```

其中 3-6 是 "frontend proper",由 `lib/Frontend` 的 `CompilerInstance`
按 `FrontendAction` 驱动;`lib/FrontendTool` 是把 action 接到可执行文件
的那层薄壳。后面各节按这条流水线展开。

**Driver vs cc1 双层**:命令行的 `clang` 先以 Driver 身份规划整个编译
(决定跑几个 Job、传什么参数给 as/ld、offload 任务怎么拆),再以 `-cc1`
子进程(或同进程重入)执行真正的编译。改命令行行为看 Driver,改编译
行为看 cc1。

---

## 2.1 Driver(lib/Driver)

负责"编译怎么组织",不管语言本身:

- `Driver.cpp` —— 主逻辑:解析参数 → 构建 Action 树(Phase/Action.cpp:
  InputType → PreprocessJobAction → CompileJobAction → …)→ 选 ToolChain →
  生成 Job(Job.cpp,如 `clang -cc1 …`、`ld.lld …`)→ 执行
- `ToolChain.cpp` —— 抽象基类,定义每个平台的工具链接口与默认 flag
- `ToolChains/` —— 平台实现:Linux、Darwin、MSVC、Gnu、CUDA/HIP、
  AArch64/ARM 跨编译变体、Fuchsia、Hurd 等 20+ 套
- `SanitizerArgs.cpp` / `XRayArgs.cpp` —— sanitizer/xray 参数归一化
- `Multilib.cpp` —— multilib 变体选择(如 ARM 的 -marm/-mthumb)
- `Types.cpp` —— 文件后缀 ↔ 类型判定(`.cpp` → TY_CXX)
- `OffloadBundler.cpp` —— 多目标(offload)任务打包的库部分
- `Options.td`(include/clang/Driver)—— 命令行选项定义(cl::opt 之前
  的统一描述)

相关文档:`docs/DriverInternals.rst`。

## 2.2 Lex(lib/Lex)

源码 → Token:

- `Lexer.cpp` —— 词法分析主循环,`PPDirectives.cpp`/`PPExpressions.cpp`/
  `PPMacroExpansion.cpp` 处理 directive 与宏展开
- `HeaderSearch.cpp` / `ModuleMap.cpp` —— 头文件查找路径、module map 解析
- `Preprocessor.cpp` —— 预处理器总控,协调以上
- `TokenLexer.cpp` —— 宏展开后的 token 流回放
- `Pragma.cpp` —— pragma 处理分发
- `PreprocessingRecord.cpp` —— 预处理动作的记录(供 libclang / index 用)

## 2.3 Parse(lib/Parse)

Token → AST,递归下降 parser,基本不做类型检查:

- `Parser.cpp` / `ParseAST.cpp` —— parser 主控;`ParseAST.cpp` 是
  Sema 消费动作的粘合处
- `ParseDecl.cpp` / `ParseDeclCXX.cpp` —— 声明(含 C++ 的类、模板声明)
- `ParseExpr.cpp` / `ParseExprCXX.cpp` —— 表达式
- `ParseStmt.cpp` / `ParseTemplate.cpp` / `ParseOpenMP.cpp` /
  `ParseOpenACC.cpp` / `ParseObjc.cpp` / `ParseHLSL.cpp` —— 语句、模板、
  语言扩展各自的 parser
- `ParseInit.cpp` —— 初始化列表(C++ 的 `{...}` 语法树构建)

## 2.4 Sema(lib/Sema)

语义分析,"边 parse 边检查",AST 在这里补全:

- `Sema.cpp` —— 总控(约 5000 行,持 `ASTContext`、`Preprocessor`)
- `SemaExpr.cpp` —— 表达式类型检查、重载决议入口
- `SemaOverload.cpp` —— 重载决议核心
- `SemaDecl.cpp` / `SemaDeclCXX.cpp` / `SemaDeclObjC.cpp` —— 声明语义
- `SemaTemplate.cpp` / `SemaTemplateDeduction.cpp` / `SemaTemplateInstantiate.cpp` —— 模板
- `SemaCodeComplete.cpp` —— 代码补全(IDE 集成的基础)
- `SemaOpenMP.cpp` / `SemaSYCL.cpp` / `SemaHLSL.cpp` —— 语言扩展
- `SemaLambda.cpp` / `SemaCoroutine.cpp` / `SemaCast.cpp` / `SemaExprCXX.cpp`
- `TreeTransform.h` —— 模板实例化时的 AST 克隆/变换框架

## 3. AST 层(lib/AST)

AST 是 clang 的核心资产,值得单列:

- **核心节点体系**:`Decl.cpp` 家族(变量/函数/类/namespace 声明)、
  `Stmt.cpp` / `Expr.cpp` 家族(语句与表达式)、`Type.cpp` / `TypePrinter.cpp`。
  节点类定义在 `include/clang/AST/Decl.h`、`Stmt.h`、`Expr.h`、`Type.h`,
  经 `ASTNodes.td` 生成 visitor 基类
- `ASTContext.cpp` —— AST 中央仓库(分配、类型表、ASTImporter 支撑)
- `ASTDumper.cpp` —— `-ast-dump` 的实现,读 AST 的最佳入口
- `Comment*.cpp` —— 文档注释解析(`///`),供 IDE hover 与文档生成
- `ASTImporter.cpp` —— 跨翻译单元导入 AST(structural equivalence 检查),
  用于静态分析 cross-TU 分析
- `ExprConstant.cpp` —— 常量表达式求值器(`constexpr` 语义的落地,
  数千行,同时被 CodeGen 调用求常量)
- `RecordLayout.cpp` —— struct/class 布局计算(对齐、位域、虚基类),
  需与 Itanium/MS ABI 配合
- `Mangle.cpp` + `ItaniumMangle.cpp` / `MicrosoftMangle.cpp` —— name mangling
- `QualType` / `Expr` use-def:`ParentMap.cpp`(parent 链)、`StmtIterator.cpp`
- `ODRHash.cpp` —— ODR 检查的哈希(modules 违例诊断)

配套目录:

| 目录 | 作用 |
|---|---|
| `lib/ASTMatchers` | AST 结构匹配 DSL(`cxxRecordDecl(hasName("Foo"))`),clang-tidy 与重构工具的地基 |
| `lib/AST` | AST 节点与操作(本节) |
| `lib/CrossTU` | cross-TU 分析的辅助 |
| `lib/Edit` | 源码编辑原语(提交到偏移修正),rewrite 系工具用 |
| `lib/Rewrite` | AST → 改写源码,Macros 重写等 |

## 4. CodeGen(lib/CodeGen)

AST → LLVM IR。目录内文件多以 `CG` 前缀,按语言特性分文件:

- `CodeGenModule.cpp` / `CodeGenFunction.cpp` —— 两个总控:模块级(全局
  变量、函数原型、attribute 落 IR)与函数体级(basic block、局部变量)
- `CGExpr.cpp` / `CGStmt.cpp` / `CGCall.cpp` —— 表达式/语句/调用
- `CGBuiltin.cpp` —— **builtin → intrinsic/指令** 的对照实现(加 builtin
  必改这里;前一节讨论的 `__builtin_popcount` → `llvm.ctpop` 就在这)
- `CGCXX.cpp` / `CGCXXABI.cpp` / `CGClass.cpp` / `CGVTables.cpp` —— C++
  ABI:构造/析构、vtable、thunk、返回值调整
- `CGObjC.cpp` + `CGObjCMac.cpp` / `CGObjCGNU.cpp` —— Objective-C runtime
- `CGOpenMP.cpp` / `CGOpenMPRuntime*.cpp` —— OpenMP
- `CGCoroutine.cpp` / `CGBlocks.cpp` / `CGException.cpp` / `CGAtomic.cpp`
- `CGDebugInfo.cpp` —— DWARF 调试信息生成
- `TargetInfo.cpp` —— 各 target 的 ABI 布局(大小端、类型大小,基于
  `CodeGenTarget`,反哺 LLVM `DataLayout`)
- `ABIInfo.h` / `ABIInfoImpl.h` —— 调用约定的中间层
- `BackendUtil.cpp` —— 接到 LLVM 后端的胶水(codegen options、LTO、
  embed-bitcode、sanitize 的 IR pass 列表都在这组装)
- `Sanitizer*.cpp`、`CodeGenAction.cpp`(在 lib/Frontend)
- 目标专属:`CGCUDANV.cpp`(NVIDIA GPU)、`CodeGenFunction.h` 的 `Emit*` 家族

阅读提示:`CGBuilder.h` 是对 `IRBuilder` 的薄封装,所有 `Emit*` 都经由它
落 IR;`Address.h` 定义带对齐的指针值,是 CodeGen 里"指针"的标准表示。

## 5. 前端公共设施与消费者

### lib/Frontend —— cc1 的骨架

- `CompilerInstance.cpp` —— 编译器实例总控(持有 manager 群、驱动一个
  action 走完流水线)
- `CompilerInvocation.cpp` —— `-cc1` 选项 → FrontendOptions/LangOptions/
  CodeGenOptions 等的映射,巨型选项映射文件
- `FrontendAction.cpp` / `FrontendActions.cpp` —— action 体系
  (`-emit-llvm`、`-ast-dump`、`-fsyntax-only` 每个都是一个 action)
- `TextDiagnosticPrinter.cpp` / `SerializedDiagnosticPrinter.cpp` / 
  `SARIFDiagnostic*.cpp` —— 诊断输出格式
- `InitPreprocessor.cpp` / `InitHeaderSearch.cpp`(在 lib/Lex)—— 预定义
  宏与初始头文件搜索路径(改 builtin 宏如 `__GNUC__` 在这里)
- `ModuleDependencyCollector.cpp`、`DependencyFile.cpp` —— 依赖文件与
  模块依赖收集(`-MD` / `-MM` 的实现)

### lib/FrontendTool

- `ExecuteCompilerInvocation.cpp` —— 从 invocation 分发到具体 action,
  `clang -cc1` 主函数的逻辑所在(tools/driver 的 `cc1_main` 调它)

### 消费 AST 的工具库

| 目录 | 作用 |
|---|---|
| `lib/Analysis` | 流分析(CFG 构建、alive analysis、format string 检查、BodyFarm) |
| `lib/Index` + `lib/IndexSerialization` | 符号索引(Xref、补全数据),clangd 的地基层 |
| `lib/ExtractAPI` | 从头文件提取 API 摘要,生成 .json API 信息 |
| `lib/InstallAPI` | TBD/TAPI 文件生成 |
| `lib/Interpreter` | Clang Repl(`clang-repl`,增量式 C++) |
| `lib/Tooling` | 工具框架:`runToolOnCode`、refactoring、`clang::tooling::RefactoringTool`,所有 AST 工具的底座 |
| `lib/Testing` | 上述库的测试辅助 |
| `lib/StaticAnalyzer` | 静态分析器核心(5 个子目录:Core、Checkers、Frontend、Config、Manager) |
| `lib/APINotes` | Swift 用的 APINotes(`.apinotes` 文件解析) |
| `lib/ARCMigrate` | ObjC ARC 迁移工具(arcmt) |
| `lib/Serialization` | AST 的序列化(PCH / modules 的 .pcm 文件读写) |
| `lib/Format` | clang-format 核心(支撑 clang-format 工具与 IDE) |
| `lib/Basic` | 基础设施:SourceManager、诊断 ID 体系、TargetInfo、LangOptions、版本号 |
| `lib/Support` | clang 侧的 Support(路径处理、坠机恢复等),内部再依赖 llvm/Support |

## 6. tools/ 速查

| 工具 | 作用 |
|---|---|
| `driver` | clang 可执行文件本体(Driver + cc1 入口都在这,`clang_main`) |
| `libclang` | C API 库(IDE 集成用,Xcode/indexer 场景) |
| `clang-format` | 代码格式化(lib/Format 的前端) |
| `clang-refactor` / `clang-rename` | 重构与改名(AST 重写) |
| `clang-check` | 语法检查/AST dump 的命令行封装 |
| `clang-scan-deps` | 模块依赖扫描(构建系统集成的关键工具) |
| `clang-repl` | 交互式 C++ 解释器(基于 lib/Interpreter) |
| `diagtool` | 诊断信息查询(改诊断文案时的好帮手) |
| `clang-offload-bundler` / `clang-offload-packager` / `clang-linker-wrapper` / `clang-nvlink-wrapper` | GPU offload 工具族 |
| `amdgpu-arch` / `nvptx-arch` | 探测 GPU 架构 |
| `c-index-test` / `clang-import-test` / `arcmt-test` / `apinotes-test` | 库的测试驱动 |
| `scan-build` / `scan-build-py` / `scan-view` | 静态分析的外围脚本 |
| `diag-build` | 从构建日志聚合诊断 |
| `clang-fuzzer` | fuzzing 驱动 |
| `include-mapping` | 从 cppreference 抓取并生成 std 符号↔头文件映射表(`gen_std.py`,产物供 `IncludeFixer`/clangd 补 include 用) |
| `clang-shlib` | 把 clang 库合成一个 so(C_API_ONLY) |
| `clang-apply-fixes`(在 clang-tools-extra)| 诊断 fixit 批量应用 |

## 7. test/ 与 docs/

### test/

lit 驱动,目录与 lib 对应:`test/CodeGen/` 对应 CodeGen(再按语言分
`CodeGenCXX/`、`CodeGenObjC/`、`CodeGenHLSL/` 等)、`test/Sema/`(Sema 的
诊断测试,数量最多的目录之一)、`test/Driver/`、`test/Parser/`、
`test/Lexer/`、`test/AST/`、`test/Frontend/`、`test/Modules/`、`test/OpenMP/`
等等。

改 clang 的惯用套路:

```bash
# Sema 测试:检查诊断文案与位置
; RUN: %clang_cc1 -fsyntax-only -verify %s
; expected-error{{cannot initialize a variable of type 'int' with...}}

# CodeGen 测试:检查生成的 IR
; RUN: %clang_cc1 -triple x86_64-unknown-unknown -emit-llvm %s -o - | FileCheck %s
```

更新 CHECK 行:`llvm/utils/update_cc_test_checks.py`(详细见 llvm/docs/TestingGuide.rst)。

### docs/

- `InternalsManual.rst` —— **clang 内部手册**,了解目录划分思想的第一手材料
- `IntroductionToTheClangAST.rst` —— AST 入门(配 `-ast-dump` 一起看)
- `DriverInternals.rst` —— Driver 设计文档
- `ExternalClangExamples.rst` —— 现成的 AST 工具样例索引
- `ClangPlugins.rst` —— 写插件,`examples/` 下有可跑样例
- `ClangTransformerTutorial.rst` —— Transformer 重构库教程
- `SAFER.rst`、`DataFlowAnalysisIntro.md` —— 分析器
- `ClangFormatStyleOptions.rst` —— 格式化选项全表

## 8. 按任务找代码速查表

| 想做的事 | 去哪 |
|---|---|
| 加/改一个 builtin | `include/clang/Basic/Builtins.def` + `lib/CodeGen/CGBuiltin.cpp`(有时还要 `lib/Sema/SemaChecking.cpp`) |
| 加/改一条诊断 | `include/clang/Basic/DiagnosticSemaKinds.td` 等 + 对应 `lib/Sema/*.cpp`;文案用 `diagtool` 查 |
| 加/改 `__attribute__` | `include/clang/Basic/Attr.td` + `lib/Sema/SemaDeclAttr.cpp` + `lib/CodeGen/` 落 IR 处 |
| 改命令行行为 | `include/clang/Driver/Options.td` + `lib/Driver/*.cpp`;cc1 选项另在 `clang/include/clang/Frontend/CC1Options.td` |
| 查类型检查/隐式转换逻辑 | `lib/Sema/SemaExpr.cpp` / `SemaCast.cpp` |
| 查重载决议 | `lib/Sema/SemaOverload.cpp` |
| 查模板实例化 | `lib/Sema/SemaTemplateInstantiate.cpp` + `lib/AST/TreeTransform.h` |
| 查 vtable/虚函数怎么生成 | `lib/CodeGen/CGVTables.cpp` + `CGCXXABI.cpp` |
| 查 name mangling | `lib/AST/ItaniumMangle.cpp` / `MicrosoftMangle.cpp` |
| 查 struct 布局 | `lib/AST/RecordLayout.cpp` + `lib/CodeGen/TargetInfo.cpp` |
| 查 constexpr 求值 | `lib/AST/ExprConstant.cpp` |
| 查 pragma 处理 | `lib/Lex/Pragma.cpp` + `lib/Parse/ParsePragma.cpp` |
| 写 AST 工具/插件 | `lib/Tooling` + `docs/ClangPlugins.rst` + `examples/` |
| 查 PCH/modules 存取 | `lib/Serialization/ASTReader.cpp` / `ASTWriter.cpp` |
| 查 `-ast-dump` 输出来源 | `lib/AST/ASTDumper.cpp` |

## 9. 建议阅读路径

1. `docs/InternalsManual.rst` 通读一遍(官方的"目录说明书")
2. 跑 `-ast-dump` 看几个真实函数的 AST,对照 `docs/IntroductionToTheClangAST.rst`
3. Lex → Parse 一条简单语句的旅程:在 `lib/Lex/Lexer.cpp` 的 `Lex` 断点,
   `lib/Parse/ParseExpr.cpp` 跟一遍
4. Sema:挑一个常见诊断(如隐式转换警告)从 `.td` 出发,`grep` 到 Sema 触发点
5. CodeGen:跟一个 `return a + b;` 从 `CodeGenFunction::EmitStmt` 走到 IR,
   理解 `CGBuilder`/`Address` 的作用
6. 之后按兴趣分流:后端衔接看 `BackendUtil.cpp` + `TargetInfo.cpp`;
   工具链看 `lib/Tooling` + `clangd`(在 clang-tools-extra)
