# 08 Clang 的 schema 与生成代码（笔记）

## 驱动结构（与 llvm/mlir 的对比点）

clang-tblgen 用集中式分发：clang/utils/TableGen/TableGen.cpp:25-131 `enum ActionType`
（约 60 个 `-gen-clang-*`），:383 `ClangTableGenMain` 一个巨型 switch；
:708 `main()` 把 `&ClangTableGenMain` 传给通用 `TableGenMain`。
（MLIR 相反：分布式 GenRegistration 静态注册；llvm-tblgen 居中：cl::opt 字面量选项。）

## NoInline 链条（E09，生成已验证）

1. **Record**：clang/include/clang/Basic/Attr.td:2437-2450
   `def NoInline : DeclOrStmtAttr { let Spellings = [CustomKeyword<"__noinline__">,
   GCC<"noinline">, CXX11<"clang","noinline">, C23<…>, Declspec<"noinline">];
   let Subjects = SubjectList<[Function, Stmt], WarnDiag, "functions and statements">;
   let SimpleHandler = 1; }`；:2452 `def : MutualExclusions<[AlwaysInline, NoInline]>;`
2. **schema**：Attr class 定义于 Attr.td:697-783（Spellings/Subjects/Args/SimpleHandler/
   HasCustomParsing/LangOpts/Documentation 等）；DeclOrStmtAttr 在 :809。
3. **生成**（实验 E09，clang-tblgen 退出 0）：
   - `-gen-clang-attr-classes` → **官方构建产物名是 Attrs.inc**（ClangAttrEmitter
     的注册名/输出名；本实验 `-o` 指定的 AttrClasses.inc 只是实验输出文件名）。
     内容：`class CLANG_ABI NoInlineAttr : public DeclOrStmtAttr`
     （生成物第 9723 行起，含 CreateImplicit/Create 工厂）
   - `-gen-clang-attr-impl` → AttrImpl.inc（getSpelling/clone/printPretty 的巨型
     switch —— ClangAttrEmitter.cpp:3438 注释明确"switch 代替虚函数，更小更快"）
   - `-gen-clang-attr-parsed-attr-impl` → AttrParsedAttrImpl.inc：每属性一个
     `ParsedAttrInfo<Name>` constexpr 构造 + `AttrInfoMap[]` 表
     （ClangAttrEmitter.cpp:5092-5140 生成代码；`HasCustomParsing` 等 bit
     在此烘焙为描述对象的编译期常量。**`SimpleHandler` 不进描述对象**——
     它在 :4938-4940 `GenerateHandleDeclAttribute` 里决定是否额外生成
     `handleDeclAttribute()` 方法，见下）
4. **消费点**（静态定位）：
   - clang/include/clang/AST/Attr.h:408 `#include "clang/AST/Attrs.inc"`
   - clang/lib/AST/AttrImpl.cpp:500 `#include "clang/AST/AttrImpl.inc"`
   - clang/lib/Sema/ParsedAttr.cpp:101 include AttrParsedAttrImpl.inc；
     **`ParsedAttrInfo::get`(:105-132) 只做一件事**：用
     `AttrInfoMap[A.getParsedKind()]` 查表返回**描述对象引用**——名字解析、
     Subjects（可否贴在该 Decl 上）检查等语义动作由**后续**在描述对象上的
     调用（`diagAppertainsToDecl` 等）执行，`get` 本身不做校验。
     `SimpleHandler=1` 控制的是**是否为该属性生成标准处理函数**
     （handleDeclAttribute 等样板），不是"是否参与表"。
   - **手写语义桥**：clang/lib/CodeGen/CodeGenModule.cpp:3236-3239
     `else if (D->hasAttr<NoInlineAttr>() && !F->hasFnAttribute(llvm::Attribute::AlwaysInline))
        B.addAttribute(llvm::Attribute::NoInline);`
     —— AST 属性 → LLVM IR 属性的翻译不是生成的，是逐属性手写。
     另见 :3233（NakedAttr 隐含 noinline）。

## 构建规则

- clang/include/clang/AST/CMakeLists.txt:1-19：`clang_tablegen(Attrs.inc
  -gen-clang-attr-classes …)` 等 5 条。
- clang/include/clang/Sema/CMakeLists.txt:1-25：AttrParsedAttrImpl.inc 等。
- clang/cmake/modules/AddClang.cmake:4-31 `clang_tablegen()` 包装通用 `tablegen(CLANG …)`。

## 其他生成器职责地图（静态）

| 领域 | 输入 | emitter | 主要产物 |
|---|---|---|---|
| 诊断 | clang/include/clang/Basic/Diagnostic*.td | ClangDiagnosticsEmitter.cpp | Diagnostic*Kinds.inc、DiagnosticGroups.inc |
| 内建函数 | Builtins.td + 各 target Builtins*.td | ClangBuiltinsEmitter.cpp | Builtins*.inc |
| 命令行选项 | **clang/include/clang/Options/Options.td** | **llvm 侧** OptionParserEmitter.cpp（-gen-opt-parser-defs） | Options.inc → **clang/lib/Options/DriverOptions.cpp:17/20** |
| AST 节点 | StmtNodes.td 等 | ClangASTNodesEmitter.cpp / ClangTypeNodesEmitter.cpp | StmtNodes.inc 等 |
| **属性 PCH 序列化** | Attr.td | **ClangAttrEmitter.cpp**（-gen-clang-attr-pch-read/-write） | **AttrPCHRead.inc / AttrPCHWrite.inc** |
| AST 属性 PCH（另一条链） | AST 属性 schema | ClangASTPropertiesEmitter.cpp | AbstractBasicReader/Writer.inc |
| SIMD 内建 | arm_neon.td 等 | NeonEmitter/SveEmitter/MveEmitter/RISCVVEmitter | arm_neon.inc 等 |

**PCH 两条链别混淆**（**已修正**）：属性的 PCH 序列化读写由
**ClangAttrEmitter** 生成 `AttrPCHRead.inc`/`AttrPCHWrite.inc`（消费点在
clang/lib/Serialization/ASTReader.cpp / ASTWriter.cpp 附近，读写的是属性位）；
`ClangASTPropertiesEmitter` 的 `AbstractBasicReader/Writer.inc` 属于另一条
**AST property** 链（读写 Type/Decl 等节点的抽象属性），不是属性 PCH。
**Options 路径修正**：输入是 `clang/include/clang/Options/Options.td`；
`Options.inc` 由 **llvm-tblgen** 的 OptionParserEmitter
（-gen-opt-parser-defs）生成，不走 clang-tblgen——消费在
`clang/lib/Options/DriverOptions.cpp:17/20`（`#include "clang/Options/Options.inc"`）。
（注：不存在 `clang/lib/Driver/DriverOptions.cpp`。）
**Builtins 路径**：`Builtins*.inc` 由 clang-tblgen 的 ClangBuiltinsEmitter 生成，
消费点在 `clang/lib/Basic/Builtins.cpp:36/42`（include 点）及 CodeGen 的
CGBuiltin。

选项用 llvm-tblgen 而非 clang-tblgen —— clang 的 tblgen 生态是"自家 + 共享"混合。
