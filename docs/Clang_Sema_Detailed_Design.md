# Clang Sema(语义分析)详细设计文档

> 基础设施系列第八篇,深入 `clang/lib/Sema/`(及 `clang/include/clang/Sema/`):
> clang 的"大脑"。Parser 每认出一个语法构件就调用 Sema 的 ActOn*/Build* 入口,
> Sema 查名、查类型、查重载、查访问权限,构建并校验 AST,最终交给 ASTConsumer
> (CodeGen 或 AST 打印)。本篇覆盖:Sema/25 个子 Sema 的类结构、Scope 与声明
> 匹配、Declarator→QualType 的类型构建、名字查找与 typo 纠错、表达式与
> Usual Arithmetic Conversions、初始化序列(InitializationSequence)、
> 重载解析(OverloadCandidateSet/ICS)、模板(推导/实例化/TreeTransform)、
> C++ 语义(CXXScopeSpec/Lambda/协程/概念)、ObjC、属性体系、诊断与
> CodeCompletion、各语言/目标子类。所有类名、成员、行号均对照本仓库代码
> (llvmorg-19.1.7,commit cd708029e0b2)核实。

---

## 目录

1. [总览](#1-总览)
2. [类结构:Sema、SemaBase 与 25 个子 Sema](#2-类结构semasemabase-与-25-个子-sema)
3. [Parser→Sema:驱动模型与 TU 生命周期](#3-parsersema驱动模型与-tu-生命周期)
4. [作用域与名字查找](#4-作用域与名字查找)
5. [声明层:SemaDecl 与声明匹配](#5-声明层semadecl-与声明匹配)
6. [C++ 声明:SemaDeclCXX 与隐式成员](#6-c-声明semadeclcxx-与隐式成员)
7. [类型构建:SemaType 与 Declarator→QualType](#7-类型构建sematype-与-declaratorqualtype)
8. [初始化:SemaInit 与 InitializationSequence](#8-初始化semainit-与-initializationsequence)
9. [表达式层:SemaExpr 与 Usual Arithmetic Conversions](#9-表达式层semaexpr-与-usual-arithmetic-conversions)
10. [C++ 表达式:new/delete/成员访问/求值上下文](#10-c-表达式newdelete成员访问求值上下文)
11. [Cast:SemaCast 与 CastOperation 状态机](#11-castsemacast-与-castoperation-状态机)
12. [重载解析:SemaOverload 与 ICS 层级](#12-重载解析semaoverload-与-ics-层级)
13. [模板:声明、推导与实例化](#13-模板声明推导与实例化)
14. [TreeTransform:CRTP 变换框架与 9 个子类](#14-treetransformcrtp-变换框架与-9-个子类)
15. [概念与 requires 表达式](#15-概念与-requires-表达式)
16. [Lambda 与协程](#16-lambda-与协程)
17. [ObjC:SemaObjC 三文件](#17-objcsemaobjc-三文件)
18. [属性体系:ParsedAttr 与 SemaDeclAttr](#18-属性体系parsedattr-与-semadeclattr)
19. [诊断、typo 纠错与 CodeCompletion](#19-诊断typo-纠错与-codecompletion)
20. [语句层与分析警告](#20-语句层与分析警告)
21. [语言与目标子 Sema 类](#21-语言与目标子-sema-类)
22. [外部 Sema 源与模块](#22-外部-sema-源与模块)
23. [设计取舍与不变量](#23-设计取舍与不变量)
24. [速查表](#24-速查表)

---

## 1. 总览

Frontend 篇(第六篇)讲到 `ParseAST(Sema&)` 是编译主循环,CodeGen 篇
(第七篇)讲了 AST 的下游——本篇补上中间那块最大的拼图:**Sema 本身**。
Parser 是"认字的手",Sema 是"理解的脑":每一个 ActOn* 回调都在语法树
与语义世界之间搬砖。

规模感:`lib/Sema/` 是全 clang 最大的库,**77 个 .cpp + 5 个私有 .h
(TreeTransform.h/CheckExprLifetime.h/CoroutineStmtBuilder.h/
TypeLocBuilder.h/UsedDeclVisitor.h)共 287,081 行**;公共接口面
`include/clang/Sema/` 63 个头共 35,784 行,其中 Sema.h 一个文件
**15,117 行**。最大的几个文件:SemaOpenMP.cpp(23845)、SemaExpr.cpp
(20915)、SemaDecl.cpp(20308)、SemaDeclCXX.cpp(19089)、
TreeTransform.h(16515)、SemaOverload.cpp(16309)、SemaChecking.cpp
(14689)。

CMake 汇成 `clangSema`,链接 7 个 clang 库:clangAPINotes、clangAST、
clangAnalysis、clangBasic、clangEdit、clangLex、clangSupport
(CMakeLists.txt);另有三个 DEPENDS:ClangOpenCLBuiltinsImpl(由
OpenCLBuiltins.td 经 TableGen 生成内建函数表)、omp_gen、
ClangDriverOptions。注意 **clangSema 不链接 clangParse**——依赖方向是
Parse→Sema,Sema 对 Parser 一无所知(它只认 Token 数组与 DeclSpec)。

Sema.h 文件头自带一份 32 节的 Table of Contents(Sema.h:538-570),
每节对应一个 .cpp 的分工——这是官方给出的阅读地图:

| 节 | 文件 | 节 | 文件 |
|---|---|---|---|
| 1 | Sema.cpp | 17 | SemaLambda.cpp |
| 2 | SemaAccess.cpp | 18 | SemaLookup.cpp |
| 3 | SemaAttr.cpp | 19 | SemaModule.cpp |
| 4 | SemaAvailability.cpp | 20 | SemaOverload.cpp |
| 5 | SemaCast.cpp | 21 | SemaStmt.cpp |
| 6 | SemaChecking.cpp | 22 | SemaStmtAsm.cpp |
| 7 | SemaCoroutine.cpp | 23 | SemaStmtAttr.cpp |
| 8 | SemaCXXScopeSpec.cpp | 24 | SemaTemplate.cpp |
| 9 | SemaDecl.cpp | 25 | SemaTemplateDeduction.cpp |
| 10 | SemaDeclAttr.cpp | 26 | SemaTemplateDeductionGuide.cpp |
| 11 | SemaDeclCXX.cpp | 27 | SemaTemplateInstantiate.cpp |
| 12 | SemaExceptionSpec.cpp | 28 | SemaTemplateInstantiateDecl.cpp |
| 13 | SemaExpr.cpp | 29 | SemaTemplateVariadic.cpp |
| 14 | SemaExprCXX.cpp | 30 | SemaConcept.cpp |
| 15 | SemaExprMember.cpp | 31 | SemaType.cpp |
| 16 | SemaInit.cpp | 32 | SemaFixItUtils.cpp |

(32 节之外还有约 45 个不在 TOC 里的文件:OpenMP/ObjC/CUDA/HLSL/
CodeComplete/各目标架构——它们走的是"子 Sema 类"路线,见第 2 章。)

按职责分组:

| 组 | 代表文件 | 职责 |
|---|---|---|
| 骨架 | Sema.cpp、SemaBase.cpp、SemaInternal.h | TU 生命周期、隐式转换执行、诊断构建器 |
| 声明 | SemaDecl、SemaDeclCXX、SemaDeclAttr、SemaType、SemaModule、SemaAccess | 声明/类型/属性/模块/访问控制 |
| 名字 | SemaLookup、SemaCXXScopeSpec、SemaFixItUtils | 查找、嵌套名说明符、typo 纠错 |
| 初始化 | SemaInit、CheckExprLifetime | InitializationSequence、悬垂诊断 |
| 表达式 | SemaExpr、SemaExprCXX、SemaExprMember、SemaExprObjC、SemaCast | 算术转换、操作数检查、cast |
| 重载 | SemaOverload、Overload.h | ICS、候选集、裁决 |
| 模板 | SemaTemplate 族 6 个、TreeTransform.h | 参数、推导、实例化、变换 |
| 语句 | SemaStmt、SemaStmtAsm、SemaStmtAttr | 语句、inline asm、语句属性 |
| C++ 专题 | SemaLambda、SemaCoroutine、SemaConcept、SemaExceptionSpec | 闭包、协程、概念、异常规范 |
| 检查 | SemaChecking、AnalysisBasedWarnings、JumpDiagnostics | 内建/格式串/libc、流分析、goto |
| 语言/目标 | SemaObjC 族 3、SemaOpenMP、SemaCUDA、SemaHLSL、SemaARM…SemaWasm | 各语言与架构的专属语义 |
| 服务 | SemaCodeComplete、SemaPseudoObject、SemaAvailability、SemaAPINotes、SemaSwift、SemaBoundsSafety | 补全、伪对象、可用性、注记 |

---

## 2. 类结构:Sema、SemaBase 与 25 个子 Sema

### 2.1 SemaBase:共同的根

`class SemaBase`(SemaBase.h:36,实现仅 90 行)是 Sema 与全部子模块
的共同基类:

- 持有 `Sema &SemaRef`(SemaBase.cpp:7 是唯一构造),子模块借此回指
  大脑;
- 提供转发访问器 `getASTContext()`/`getDiagnostics()`/`getLangOpts()`;
- 嵌套 `ImmediateDiagBuilder`:继承 DiagnosticBuilder,构造时
  `(DiagnosticBuilder &DB, Sema &SemaRef, unsigned DiagID)`,析构时若
  诊断未发出则补上模板实例化栈("in instantiation of ... required
  from here")——**这就是所有 Sema 诊断都带实例化上下文的机制**。

### 2.2 Sema:final 的 God-object

`class Sema final : public SemaBase`(Sema.h:535)。构造签名
(Sema.h:579-581):

```cpp
Sema(Preprocessor &pp, ASTContext &ctxt, ASTConsumer &consumer,
     TranslationUnitKind TUKind = TU_Complete,
     CodeCompleteConsumer *CompletionConsumer = nullptr);
```

构造函数体(Sema.cpp:214-301):初始化 25 个子模块指针区(:224-249)、
压入第一个表达式求值上下文(:287-289)、向 Preprocessor 注册
`sema::SemaPPCallbacks`(:294-298,-Wpragma-pack 等用它)。析构
(Sema.cpp:521-556)负责清理延迟诊断池与模板实例化栈。`virtual void
anchor()` 的注释自述:非多态基类,加 vtable 只是为了省 debug info。

`void Initialize()`(Sema.h:584 声明,定义 Sema.cpp:312-519)在
Parser 构造完之后、解析任何东西之前调用:向 TUScope 注入预定义声明——
`__int128_t`/`__uint128_t`(:334-339,经 PushOnScopeChains)、
`__NSConstantString`(:370)、`__builtin_va_list`(:516)等,再按语言
开关注入 SEL/Class/Protocol(ObjC)、vector 类型(OpenCL/AltiVec)等。

### 2.3 25 个子 Sema:模块化的演进方向

Sema.h:1294-1318 依次声明 25 个 `std::unique_ptr<SemaX>`(AMDGPUPtr、
ARMPtr、AVRPtr、BPFPtr、CodeCompletionPtr、CUDAPtr、HLSLPtr、
HexagonPtr、LoongArchPtr、M68kPtr、MIPSPtr、MSP430Ptr、NVPTXtr、
ObjCPtr、OpenACCPtr、OpenCLPtr、OpenMPPtr、PPCPtr、PseudoObjectPtr、
RISCVPtr、SYCLPtr、SwiftPtr、SystemZPtr、WasmPtr、X86Ptr),配套的
访问器(:1144-1259)如 `SemaARM &ARM()`(:1144)、`SemaOpenMP
&OpenMP()`(:1219)、`SemaX86 &X86()`(:1259)全部**惰性创建**
(首次调用时 new)。子类全部 `: public SemaBase`,自己再持一份
SemaRef。调用形态统一是 `SemaObjC &ObjC = SemaObjC::get(*this);`
或直接 `OpenMP().ActOnOpenMPDeclareVariant(...)`。

这套"Sema 子对象"结构是 19.x 的演进方向:ObjC 是第一个整体迁出的
大块(全部函数签名从 `Sema::` 变成 `SemaObjC::`),OpenMP/CUDA/
HLSL/CodeCompletion/各目标架构随后。**读代码时的判别法:在 Sema.h
里找不到的 ActOn*,去对应 SemaX.h 里找。**

---

## 3. Parser→Sema:驱动模型与 TU 生命周期

### 3.1 谁持有谁

- Parser 持有 `Sema &Actions`(include/clang/Parse/Parser.h:90),
  构造 `Parser(Preprocessor &PP, Sema &Actions, bool
  SkipFunctionBodies)`(:492);
- CompilerInstance::createSema(lib/Frontend/CompilerInstance.cpp:745)
  构造 Sema 并交给 ParseAST;
- `void clang::ParseAST(Sema &S, bool PrintStats, bool
  SkipFunctionBodies)`(lib/Parse/ParseAST.cpp:115)是主循环;另一个
  PP+Consumer 重载(:100)在内部自建 Sema;
- Sema 持回 `ASTConsumer &Consumer` 与可选 `CodeCompleteConsumer`;
  语句级产出走 `Consumer.HandleTopLevelDecl`,TU 结束走
  `HandleTranslationUnit`。

Parser 对 Sema 的调用约定是 **ActOn*/Build* 两层**:ActOn* 接解析器
的数据结构(Token、Declarator、ParsedAttr、CXXScopeSpec),做立即的
诊断与包装;Build* 接半成品语义对象,做真正的构造。同文件内的规则:
**ActOn* 薄、Build* 厚**。

### 3.2 TU 三边界

- `Sema::ActOnStartOfTranslationUnit()`(Sema.cpp:1093):极短,
  C++20 Header Unit 时调 HandleStartOfHeaderUnit(:1096);
- `Sema::ActOnEndOfTranslationUnitFragment(TUFragmentKind)`
  (Sema.cpp:1099):合并延迟的实例化并 PerformPendingInstantiations
  (:1145),发出模块片段期间的延迟诊断;
- `Sema::ActOnEndOfTranslationUnit()`(Sema.cpp:1164):完整收尾清单
  ——合并 tentative definitions、ProcessPendingDeclAttributeDelayed、
  委托构造环检测(CheckDelegatingCtorCycles)、TU 级
  AnalysisBasedWarnings::IssueWarnings(:1510 一带)、
  Consumer.HandleTranslationUnit。

函数体的微生命周期(最常用的路径):

```text
ActOnFunctionDeclarator(SemaDecl.cpp:9665)      // 声明或定义的第一步
 → ActOnStartOfFunctionDef(:15198 Declarator 版 / :15411 Decl* 版)
    压求值上下文(consteval → ImmediateFunctionContext)
 → … 一系列 ActOnStmt/ActOnExpr …
 → ActOnFinishFunctionBody(:15714 薄包装 / :15787 真身)
    coroutine 判定 → DiagnoseUnguardedAvailabilityViolations(:16115)
    → DiagnoseInvalidJumps(:16134)→ CheckDestructor(:16138)
    → AnalysisBasedWarnings(每个函数体一次)
```

### 3.3 跳转诊断为什么在这里

`goto` 越过变量初始化的检查(JumpDiagnostics.cpp,入口
`Sema::DiagnoseInvalidJumps`:1033)由 ActOnFinishFunctionBody
(SemaDecl.cpp:16134)调用:`class JumpScopeChecker`(:38)两阶段——
BuildScopeInformation 构造每个 goto/label 所在的词法作用域与
"需要初始化的变量"集合,VerifyJumps(:665)/VerifyIndirectJumps 逐边
检查。这是 Sema 里少有的"先收集全函数、再统一判定"的分析,因为
跳转合法性本质是全图性质。

---

## 4. 作用域与名字查找

### 4.1 Scope 家族

`class Scope`(include/clang/Sema/Scope.h:41)是 Parser 与 Sema 共享
的词法作用域栈结点:链式父指针 + 32 个 ScopeFlags 位标志(FnScope
0x01 起,到 FriendScope 0x40000000)。Parser 进出 `{}`/函数/类时
Enter/Exit,Sema 只读。**CurScope 成员放在 Sema 里**(
`Scope *CurScope`,Sema.h:1290,注释 "The parser maintains this state
here")——又一个"Parser 驱动、Sema 记账"的例子。

### 4.2 LookupResult:查找的统一货币

`class LookupResult`(include/clang/Sema/Lookup.h:48 起)封装一次
查找的结果与歧义状态:

- `LookupResultKind`:NotFound / NotFoundInCurrentInstantiation /
  Found / FoundOverloaded / FoundUnresolvedValue / Ambiguous;
- `AmbiguityKind`(Lookup.h:76):AmbiguousBaseSubobjectTypes、
  AmbiguousBaseSubobjects、AmbiguousReference、
  AmbiguousReferenceToPlaceholderVariable、AmbiguousTagHiding;
- `resolveKind()`(Lookup.h:521)在 addDecl 后收敛状态;
- 模块场景有 `setShadowed/isShadowed`(:510-514)——"找到了但被
  隐藏"是模块时代的第三种状态。

`Sema::LookupNameKind`(Sema.h:8995 起)共 16 种(LookupOrdinaryName、
LookupTagName、LookupLabel、LookupMemberName、LookupOperatorName、
LookupDestructorName、LookupNestedNameSpecifierName、
LookupNamespaceName、LookupUsingDeclName、
LookupRedeclarationWithLinkage、LookupLocalFriendName、
LookupObjCProtocolName、LookupObjCImplicitSelfParam、
LookupOMPReductionName、LookupOMPMapperName、LookupAnyName);
`RedeclarationKind`(include/clang/Sema/Redeclaration.h:18)三分
NotForRedeclaration/ForVisibleRedeclaration/ForExternalRedeclaration,
LookupResult 由两个布尔组合出三者(Lookup.h:291-294)。

### 4.3 三条查找入口

- `Sema::LookupParsedName`(SemaLookup.cpp:2676):解析器统一入口。
  有 ObjectType(成员访问)→ computeDeclContext;有限定 SS →
  LookupQualifiedName;`__super` → LookupInSuper(:2728);否则退化
  为 LookupName(:2718);
- `Sema::LookupName`(:2175):非限定查找。**C 走 IdentifierResolver
  纯词法链**(:2192-2215),C++ 走 UnqualUsingDirectiveSet(using-
  directive 提升到公共祖先命名空间再查)。LookupBuiltin 兜底
  (:2276);
- `Sema::LookupQualifiedName`(:2392 主实现 / :2666 包装):限定查找,
  遍历基类与 using-shadow(约 13 个查找循环阶段),TU 顶层兜底
  LookupBuiltin(:1131)。

`Sema::LookupBuiltin`(:917)是内建函数的按需造声明工厂:
MakeIntegerSeq/TypePackElement(:930-937)、OpenCL 表驱动内建
(:939-945,条件 `OpenCL && DeclareOpenCLBuiltins`,即
-fdeclare-opencl-builtins)、RISCV IntrinsicManager(:947-956)、
普通 BuiltinID 走 `LazilyCreateBuiltin`。

ADL:`Sema::ArgumentDependentLookup`(SemaLookup.cpp:3778)先
FindAssociatedClassesAndNamespaces,再遍历关联命名空间;显式实例化
上下文与导出模块可见性规则在 :3807-3847;name hiding 用 shadow map
RAII(ShadowContext/addShadowedDecl,约 :3908-3960)。

shadowing 诊断:`Sema::CheckShadow(NamedDecl*, NamedDecl*,
LookupResult&)`(SemaDecl.cpp:8175)决定 -Wshadow 家族选哪个具体
警告;接入点散布:typedef(:6711)、变量(:8031)、函数参数(:15588)、
块变量(SemaExpr.cpp:16070)、GNU local label 遮蔽(LookupOrCreateLabel
SemaLookup.cpp:4362)、模板
参数(-Wstrict-primary-template-shadow,SemaDecl.cpp:6351)。

---

## 5. 声明层:SemaDecl 与声明匹配

### 5.1 声明的两条主链

**有 declarator 的声明**(`int f(int);`):

```text
Parser::ParseDeclarationOrFunctionDefinition
 → Sema::ActOnFunctionDeclarator(SemaDecl.cpp:9665)
    吸收缩写函数模板参数、adjustMemberFunctionCC
 → (声明)CheckFunctionDeclaration(:11793)
 → (定义)ActOnStartOfFunctionDef(:15198)→ ActOnFinishFunctionBody(:15787)
```

**无 declarator 的声明**(`struct foo;`、friend 类型、匿名结构):
`Sema::ParsedFreeStandingDeclSpec` 两重载(SemaDecl.cpp:4776 薄包装
/ :4998 主实现),tag 定义走 ActOnTagStartDefinition(:17984)/
ActOnTagFinishDefinition(:18049)。

**C++ 类成员区开始**:`Sema::ActOnStartCXXMemberDeclarations`
(**SemaDecl.cpp:18007**,不在 SemaDeclCXX.cpp!)——注入
injected-class-name(:18031-18045)。

### 5.2 创建分派:CreateNewFunctionDecl

`static FunctionDecl *CreateNewFunctionDecl`(SemaDecl.cpp:9131,
由 :9713 调用)是"该 new 哪个 Decl 子类"的唯一裁决点:C 路径直接
`FunctionDecl::Create`(:9182);C++ 按 DeclarationName 种类分派——
构造 `CXXConstructorDecl::Create`(:9196)、析构 `CXXDestructorDecl::
Create`(:9210)、转换函数 `CXXConversionDecl::Create`(:9242)、推导
指引 `CXXDeductionGuideDecl::Create`(:9261)、成员方法
`CXXMethodDecl::Create`(:9278)。**AST 层的类层级在这里显形**。

### 5.3 重声明合并

- `Sema::MergeFunctionDecl`(SemaDecl.cpp:3535):UsingShadowDecl
  展开、内建函数不可重声明(canBuiltinBeRedeclared)、static/extern
  冲突、类型不匹配诊断(诊断 ID 由 getNoteDiagForInvalidRedeclaration
  给出,:3583 使用);
- `Sema::MergeVarDecl`(:4459)+ MergeVarDeclTypes(:4343);
- `Sema::MergeTypedefNameDecl`(:2467);
- `Sema::mergeDeclAttributes`(:3077):合并时搬运属性(被 :2574/
  4271/4314/4520 调用);
- 模块下"是否与隐藏旧声明链接"的判断是
  `Sema::shouldLinkPossiblyHiddenDecl`(Sema.h:9568/9581 两重载),
  使用于 MergeVarDecl 开头(:4464)与 CheckFunctionDeclaration
  (:11819)。

### 5.4 CheckFunctionDeclaration 检查清单

`Sema::CheckFunctionDeclaration`(SemaDecl.cpp:11793)是函数声明
合法性的集中检查点,依次:①overload vs redeclaration 判断
(:11810-11835);②extern "C" 隐形冲突(:11838);③multiversion
(static bool CheckMultiVersionFunction :11677,调用 :11864);④PPC
MMA 返回类型(:11864);⑤C++14 占位返回类型置 dependent(:11882);
⑥C++11 constexpr 成员隐式 const(:11902);⑦MergeFunctionDecl
(:11945);⑧C++ 专项:CheckConstructor(:12030)、析构名字(:12044)、
推导指引(:12066)、AddOverriddenMethods(:12080)、转换函数
(:12097)、重载操作符(:12103)、字面量操作符(:12110)、默认实参
(:12117);⑨C++17 前异常规范进签名的 ABI 警告(:12140);⑩CUDA
checkTargetOverload(:12143);⑪AArch64 SME SM/ZA/ZT0(:12158-12216)。
之后 `Sema::CheckMain`(:12213)单独管 main 的 static/inline/
constexpr/_Noreturn。

### 5.5 PushOnScopeChains

`Sema::PushOnScopeChains`(SemaDecl.cpp:1495)是"声明挂到哪里"的
统一出口:上穿 transparent scope;AddToContext 时
`CurContext->addDecl`;C++ 中 out-of-line 的非函数局部声明不入
scope;函数模板特化不入 scope;UsingEnumDecl 特例。**Scope 栈与
DeclContext 树是两张不同的图,这个函数是双写的交汇点。**

---

## 6. C++ 声明:SemaDeclCXX 与隐式成员

### 6.1 CheckCompletedCXXClass:类完成时的总闸

`Sema::CheckCompletedCXXClass`(SemaDeclCXX.cpp:6831)在 `};` 时
运行,清单包括:抽象类使用(:6837)、非聚合无用户构造器时
const/reference 成员未初始化警告(:6844)、成员名与类同名(:6871)、
virtual 方法 + 非虚 public 析构 -Wnon-virtual-dtor(:6894)、
abstract+final(:6903)、trivial_abi(:6928)、**defaulted 成员的
triviality判定**(CompleteMemberFunction lambda :6997,内部
SpecialMemberIsTrivial)、constexpr virtual defaulted 立即
DefineDefaultedFunction(:7066)、CheckCompletedMemberFunction
(:6950)、override 控制缺失/DiagnoseHiddenVirtualMethods(:10316,
接入 :7100)、secondary 比较运算符延后(:6978)、
canPassInRegisters(:7152)、MarkVTableUsed(:18437,接入 :7173)。

### 6.2 隐式成员的声明

`Sema::AddImplicitlyDeclaredMembersToClass`(:10503)按需调用:
DeclareImplicitDefaultConstructor(:13826)、DeclareImplicitDestructor
(:14116)、DeclareImplicitCopyAssignment(:14744)、
DeclareImplicitMoveAssignment(:15101)、DeclareImplicitCopyConstructor
(:15491)、DeclareImplicitMoveConstructor(:15642)、
DeclareImplicitEqualityComparison(:9026,`<=>` 时代的合成 ==)。
`= default`/`= delete` 的入口:SetDeclDeleted(:17920)、
SetDeclDefaulted(:17973)、合法性检查 CheckExplicitlyDefaultedFunction
(:7535)→ CheckExplicitlyDefaultedSpecialMember(:7550)。

构造函数初始化:`Sema::SetCtorInitializers`(:5220)——委托构造
(DelegatingCtorDecls.push_back :5213)的环检测推迟到 TU 末
(CheckDelegatingCtorCycles :18701);继承构造经 using 声明
(BuildUsingDeclaration :12708 → CheckInheritingConstructorUsingDecl
:13034,辅助类 InheritedConstructorInfo :7227)。

friend:ActOnFriendTypeDecl(:17503)、ActOnFriendFunctionDecl
(:17607)。特殊成员查找:`Sema::LookupSpecialMember`(**SemaLookup.cpp:3292**,由 SemaDeclCXX.cpp:7204 的
lookupCallFromSpecialMember 包装)。

种类专属检查:CheckConstructor(:10808)、CheckConstructorDeclarator
(:10748)、CheckDestructor(:10840)、CheckDestructorDeclarator
(:10889)、CheckConversionDeclarator(:11005)、
CheckOverloadedOperatorDeclaration(:16276)、
CheckLiteralOperatorDeclaration(:16500)、CheckConstexprFunctionDefinition
(:1786)、CheckExplicitObjectMemberFunction(:11231/:11240,C++23
deducing this)。

---

## 7. 类型构建:SemaType 与 Declarator→QualType

### 7.1 从 DeclSpec 到 QualType 的三步

Parser 产出的类型描述是 **DeclSpec 家族**(include/clang/Sema/
DeclSpec.h:DeclSpec :247 存储说明符 + 基类型、Declarator :1900 存
名字与 DeclaratorChunk 链、CXXScopeSpec :74 存 `A::B::` 前缀)。
Sema::GetTypeForDeclarator(SemaType.cpp:5645)三步转换:

1. TypeProcessingState 构造(错误恢复的回滚点);
2. `static QualType GetDeclSpecTypeForDeclarator`(:3072):按
   UnqualifiedIdKind 分派(构造/析构名 → VoidTy:3090;推导引用 →
   DependentTy:3100;转换函数取返回类型:3105);**auto/decltype
   的位置合法性检查就在这里**(:3137-3345:getContainedDeducedType()
   按 DeclaratorContext 给 err_auto_not_allowed 的 22 个编号);
3. `static TypeSourceInfo *GetFullTypeForDeclarator`(:4209):沿
   DeclaratorChunk **从内向外**构建指针/数组/函数类型;processTypeAttrs
   分三遍注入类型属性(TAL_DeclSpec :5345、TAL_DeclChunk :5358、
   TAL_DeclName :5537,本体 :8495)。

**注意:真正的 auto 推导不在这里**——GetDeclSpecTypeForDeclarator
只做"允许不允许"的诊断,推导在 SemaTemplateDeduction.cpp 的
`Sema::DeduceAutoType`(:5045)与 `Sema::DeduceReturnType`(:5289)。
类型构建与类型推导是两个文件、两个时机(声明处 vs 定义处)。

其他构建器:BuildArrayType(:2027,VLA/FAM/元素合法性)、
BuildFunctionType(:2605,内部 CheckFunctionReturnType :2502 检查
返回类型、void 参数、half 参数、Wasm table 参数、ExtParameterInfos)、
BuildMemberPointerType(:2670)、BuildAtomicType(:9785,_Atomic 的
一长串禁止项)、BuildAddressSpaceAttr(:6424/:6447)。
`Sema::RequireCompleteType`(:8885/:9229)是全编译器"类型必须完整"
检查的总入口。type trait(__is_trivial 等)的构造在 SemaExprCXX.cpp
(BuildTypeTrait :5921/ActOnTypeTrait :5952)。

### 7.2 嵌套名说明符

`A::B::` 前缀的构建在 SemaCXXScopeSpec.cpp:
`Sema::BuildCXXNestedNameSpecifier`(:408)查名并构造
NestedNameSpecifier(失败可 typo 纠正);配套 ActOnCXXGlobalScopeSpecifier
(:280)、ActOnSuperScopeSpecifier(:286)、
RequireCompleteDeclContext(:193)。CXXScopeSpec 是 Parser 与 Sema
之间传递"限定前缀"的标准信封。

---

## 8. 初始化:SemaInit 与 InitializationSequence

### 8.1 两段式:分析(InitializeFrom)与执行(Perform)

`class InitializationSequence`(include/clang/Sema/Initialization.h:802)
把"如何初始化 X"编成一个步骤程序,存进 `SmallVector<Step, 4>
Steps`(:992)。StepKind 约 42 种(Initialization.h:821 起,SK_ 前缀),
覆盖:解重载函数地址、派生到基的 PRValue/XValue/LValue 三种、
BindReference/BindReferenceToTemporary、UserConversion、
QualificationConversion、ListInitialization/UnwrapInitList/RewrapInitList、
ConstructorInitialization、ZeroInitialization、CAssignment、StringInit、
ObjCObjectConversion、ArrayLoop/Index/Init、GNUArrayInit、
PassByIndirectCopyRestore、StdInitializerList、OCLSamplerInit、
ParenthesizedListInit 等;失败原因 FailureKind(FK_)约 60 种(:996 起)。

**分析**:`InitializationSequence::InitializeFrom`(SemaInit.cpp:6280)
——先消 placeholder(:6290)、依赖型短路(:6308)、braced-init-list
走 TryListInitialization(:6336),否则依次尝试引用初始化/构造/用户
转换。Try 家族(全 static):TryListInitialization(:4167/:4669)、
TryConstructorInitialization(:4341)、TryReferenceInitializationCore
(:4548/:5109)、TryValueInitialization(:4559/:5442)、
TryReferenceListInitialization(:4566)、TryReferenceInitialization
(:5071)、TryStringLiteralInitialization(:5433)、
TryDefaultInitialization(:5520)、TryOrBuildParenListInitialization
(:5558,C++20 圆括号聚合初始化)、TryUserDefinedConversion(:5814)。

**执行**:`InitializationSequence::Perform`(:7482)——`ExprResult
CurInit((Expr *)nullptr)`(:7615)为当前初始化器,循环 switch 执行
Steps(全文件 `case SK_` 152 处);失败先 Diagnose(:7487);constexpr
变量缺常量初始化的 fixit(:7491)。

列表初始化的逐元素检查由 `class InitListChecker`(:308,构造 :1015)
完成:CheckImplicitInitList/CheckExplicitInitList/CheckSubElementType/
CheckScalarType/CheckReferenceType/CheckVectorType/CheckStructUnionTypes/
CheckArrayType/CheckDesignatedInitializer/FillInEmptyInitializations/
CheckFlexibleArrayInit/HandleEmbed(约 :196-507)。

### 8.2 清理副作用与悬垂诊断

- `Sema::CreateMaterializeTemporaryExpr`(:7425):临时量物化
  (TODO 注释:与 MaybeBindToTemporary 两处生成 ExprWithCleanups 待统一);
- SK_BindReferenceToTemporary 把临时量扩展到自动存储期时
  `Cleanup.setExprNeedsCleanups(true)`(:7794-7797);
- **悬垂引用/指针的 -Wdangling 家族在 CheckExprLifetime.cpp**
  (lib/Sema/ 下,2024-06 从 SemaInit.cpp 搬出,#96758):入口
  `clang::sema::checkExprLifetime` 两重载(:1303 InitializedEntity /
  :1314 AssignedEntity),核心 checkExprLifetimeImpl(static :989);
  枚举 LifetimeKind(:19):LK_Persistent/LK_FullExpression/LK_Extended/
  LK_MemInitializer/LK_Assignment;调用点:checkInitializerLifetime
  (SemaInit.cpp:7299)、赋值(SemaExpr.cpp:13654)、运算符重载形参
  (SemaOverload.cpp:14704);GSL lifetimebound 注解经
  handleGslAnnotatedTypes(:329)。

---

## 9. 表达式层:SemaExpr 与 Usual Arithmetic Conversions

### 9.1 ActOn/Build 双层

二元操作符是最典型的样本:

```text
ActOnBinOp(SemaExpr.cpp:15061)            // token → BinaryOperatorKind
 → DiagnoseBinOpPrecedence(static :15027) // -Wlogical-op-parentheses
 → BuildBinOp(:15124)                      // 真分派
    CorrectDelayedTyposInBinOp 后按操作数三分:
    ① pseudo-object → CheckPlaceholderExpr(:20706)链
    ② C++ 重载(占位符或类/枚举操作数)→ BuildOverloadedBinOp(static :15088)
       → CreateOverloadedBinOp(SemaOverload.cpp:14426)
    ③ 否则 CreateBuiltinBinOp(:14589)
```

一元同样:ActOnUnaryOp(:15600)→ BuildUnaryOp(:15556)。调用:
ActOnCallExpr(:6369)→ BuildCallExpr(:6407)(CheckArgsForPlaceholders、
伪析构、重载解析、CheckFunctionCall/checkFortifiedBuiltinMemoryFunction/
CheckBuiltinFunctionCall 分派,:6947-6956)。下标:ActOnArraySubscriptExpr
(:4800)。条件:ActOnConditionalOp(:8703)。字符串字面量:
ActOnStringLiteral(:2030)——StringLiteralParser(Lex 层)拼接相邻串,
非 UDL 直接 StringLiteral::Create(:2102),有 ud-suffix 则转
`Sema::BuildLiteralOperatorCall`(**定义在 SemaOverload.cpp:15938**)。

### 9.2 内建操作数检查族

`CreateBuiltinBinOp` 按操作符转给 Check*Operands 家族(全返回
QualType):CheckConditionalOperands(:8329)、CheckMultiplyDivideOperands
(:10487)、CheckRemainderOperands(:10526)、CheckAdditionOperands
(:10844)、CheckSubtractionOperands(:10967)、CheckShiftOperands
(:11409,配 DiagnoseBadShiftValues static :11122)、CheckCompareOperands
(:12039)、CheckBitwiseOperands(:12928 inline)、CheckLogicalOperands
(:12992 inline)、CheckAssignmentOperands(:13539)、
CheckAddressOfOperand(:13980)、CheckIndirectionOperand(static :14255)。
无效操作数统一报 `Sema::InvalidOperands`(:9760)。

### 9.3 Usual Arithmetic Conversions

`Sema::UsualArithmeticConversions`(:1539)签名带**第 4 参数
`ArithConvKind ACK`**(Sema.h:7402):ACK_Arithmetic/ACK_BitwiseOp/
ACK_Comparison/ACK_Conditional/ACK_CompAssign——同一个转换算法,
按运算类别启用不同诊断(比较运算不做整型提升的警告、C++20 无枚举
提升诊断 checkEnumArithmeticConversions :1474)。实现分派到 static
helper:handleComplexConversion(:1144)、handleFloatConversion(:1199)、
handleIntegerConversion(:1292)。一元侧:UsualUnaryConversions(:779)、
DefaultLvalueConversion(:635)、DefaultFunctionArrayConversion(:511)。

隐式转换的统一执行器是 `Sema::ImpCastExprToType`——**定义在
Sema.cpp:694**(不在 SemaExpr.cpp):按 CastKind 包 ImplicitCastExpr。
常量求值不在 Sema:lib/AST/ExprConstant.cpp 负责,Sema 的接入点是
`Sema::VerifyIntegerConstantExpression`(:16880/:16898/:16929 三重载,
内部 EvaluateAsRValue(..., /*isConstantContext*/ true))。

### 9.4 ODR-use 与引用标记

`Sema::MarkDeclarationsReferencedInExpr`(:19909)委托
`class EvaluatedExprMarker : public UsedDeclVisitor<EvaluatedExprMarker>`
(:19863)遍历表达式标记被引用的声明(触发隐式函数体实例化、
内联变量定义);`Sema::MarkFunctionReferenced`(:17851)是函数版的
入口,重载解析选中候选后调用。表达式求值上下文的语义见第 10 章。

---

## 10. C++ 表达式:new/delete/成员访问/求值上下文

### 10.1 new/delete

`Sema::ActOnCXXNew`(SemaExprCXX.cpp:1908)从 Declarator 拆出数组
大小后转 `BuildCXXNew`(:2030):分配函数查找
`Sema::FindAllocationFunctions`(:2696,resolveAllocationOverload
static :2554)、CheckAllocatedType(:2516)、初始化序列、CXXNewExpr::
Create(:2509)。全局 new/delete 声明注入:DeclareGlobalNewDelete
(:3009)/DeclareGlobalAllocationFunction(:3140)。delete:
ActOnCXXDelete(:3623)配 FindDeallocationFunction(:3290)、
CheckVirtualDtorCall(:3977)、new/delete 不匹配分析
AnalyzeDeleteExprMismatch(:3585,MismatchingNewDeleteDetector 类
:3481-3563)。

### 10.2 typeid 与 this

ActOnCXXTypeid(:647)查找 std::type_info(缓存 CXXTypeInfoDecl),
BuildCXXTypeId 两重载(:543 type-id 形式/:570 表达式形式)。this:
ActOnCXXThis(:1408)/BuildCXXThisExpr(:1447)/CheckCXXThisCapture
(:1296)。

### 10.3 成员访问

主入口 `Sema::ActOnMemberAccessExpr`(**SemaExprMember.cpp:1749**,
`.`/`->`):经 static `LookupMemberExpr`(:779 声明/:1287 定义)→
`LookupMemberExprInRecord`(static :704,在记录内查成员名,含
typo 纠错与重试机制 RetryExpr :1046)→ `BuildFieldReferenceExpr`
(:1824,计算 value kind)或 BuildMemberExpr;隐式成员(无对象前缀)
走 BuildImplicitMemberExpr(:1906)。**依赖类型的 operator-> 链**
在 SemaExprCXX.cpp:ActOnStartCXXMemberReference(:7838,含
ArrowDepth 上限诊断)。

### 10.4 表达式求值上下文

8 种 ExpressionEvaluationContext(Unevaluated →
PotentiallyEvaluatedIfUsed)由 Parser 侧 RAII 驱动进出:
`Sema::PushExpressionEvaluationContext`(**SemaExpr.cpp:17171 与
:17200 两个重载**——`void` 与函数名之间有换行,grep 时注意;
PopExpressionEvaluationContext :17592),记录栈
`ExprEvalContexts`。Record 字段(Sema.h:6287-6436)含
ExprCleanupObjects、SavedMaybeODRUseExprs、InLifetimeExtensionContract
等;`isPotentiallyEvaluated()`(Sema.h:6403)三种上下文为 true。
**unevaluated 上下文里不标 ODR-use、不做实例化**——这是
sizeof/decltype/noexcept/delecltype 不触发模板实例化的机制根源。
RAII 封装 `EnterExpressionEvaluationContext`(独立头
include/clang/Sema/EnterExpressionEvaluationContext.h:19)。
TransformToPE(SemaExpr.cpp:17106,TreeTransform 子类)负责把
unevaluated 中构建的表达式在转为 potentially evaluated 时重新标记。

### 10.5 全表达式收尾

`Sema::ActOnFinishFullExpr`(SemaExprCXX.cpp:9056):每个完整表达式
结束时做临时对象绑定(MaybeBindToTemporary :7491)、ODR 标记、
MaybeODRUseExprs 的落盘。`Sema::IgnoredValueConversions`(:8429)
处理丢弃值上下文的额外转换(如 cast-to-void 仍保留 volatile 读)。

---

## 11. Cast:SemaCast 与 CastOperation 状态机

### 11.1 两条入口

- **C 风格 cast**:ActOnCastExpr(SemaExpr.cpp:7663,含 AltiVec/
  OpenCL vector literal 特判)→ `Sema::BuildCStyleCastExpr`
  (**SemaCast.cpp:3341**);
- **五种命名 cast**(static/dynamic/reinterpret/const/addrspace):
  **没有每个 cast 一个 ActOn**——Parser::ParseCXXCasts()
  (lib/Parse/ParseExprCXX.cpp:1645)统一调
  `Sema::ActOnCXXNamedCast`(SemaCast.cpp:274)→
  `Sema::BuildCXXNamedCast`(:297);functional cast T(x) 走
  `Sema::BuildCXXFunctionalCastExpr`(:3367);列表初始化 T{x} 不进
  SemaCast,走 SemaInit(:3369 assert)。

### 11.2 CastOperation

`struct CastOperation`(SemaCast.cpp:60,匿名命名空间)是中心状态机:
持 DestType/ResultType/Kind/ValueKind/PlaceholderKind/CXXCastPath,
8 个 Check 方法(:102-109):CheckConstCast/CheckReinterpretCast/
CheckStaticCast/CheckDynamicCast/CheckCXXCStyleCast/CheckCStyleCast/
CheckBuiltinBitCast/CheckAddrspaceCast(+CheckNoDeref :182)。
static 尝试器 TryStaticCast(声明 :257/定义 :1316)、TryConstCast
(声明 :262)返回 TryCastResult 枚举(:36):TC_NotApplicable/
TC_Success/TC_Extension/TC_Failed——**"试多种 cast 取第一个成功"**
的回退链就是靠这个三态返回值串起来的。`CastOperation::complete`
(:344 一带)最终创建 CXXStaticCastExpr/CXXDynamicCastExpr 等节点。

产出的 CastKind 枚举(include/clang/AST/OperationKinds.h:20)由
OperationKinds.def 的 `CAST_OPERATION(Name)` 宏生成,**共 67 个
CK_**(grep 实体行 67;容易数错成 71,多出的 4 行是宏保护行)。

---

## 12. 重载解析:SemaOverload 与 ICS 层级

### 12.1 候选收集

`class OverloadCandidateSet`(include/clang/Sema/Overload.h:1008)持
`SmallVector<OverloadCandidate, 16> Candidates`(:1105)与
`llvm::BumpPtrAllocator SlabAllocator`(:1110,为 ICS 数组做 slab
分配,slabAllocate :1131)。CandidateSetKind(:1010)五种:
CSK_Normal/CSK_Operator/CSK_InitByUserDefinedConversion/
CSK_InitByConstructor/CSK_AddressOfOverloadSet。

收集家族(SemaOverload.cpp):AddOverloadCandidate(:6795,非模板)、
AddFunctionCandidates(:7291,UnresolvedSet 批量)、AddMethodCandidate
(:7359/:7386)、AddMethodTemplateCandidate(:7571)、
AddTemplateOverloadCandidate(:7643)、AddConversionCandidate(:7838)、
AddTemplateConversionCandidate(:8040)、AddSurrogateCandidate(:8091)、
AddNonMemberOperatorCandidates(:8216)、AddMemberOperatorCandidates
(:8256)、AddBuiltinCandidate(:8304,单内建)、
**AddBuiltinOperatorCandidates(:9759,内建算子候选总收集**——经
CollectVRQualifiers(static :8683,只收 volatile/restrict)决定是否
掺入内建候选)、AddArgumentDependentLookupCandidates(:9957)。调用
点的收集总入口 AddOverloadedCallCandidates(:13489/:13543)。

### 12.2 ICS:隐式转换序列

`class ImplicitConversionSequence`(Overload.h:567)的 Kind 枚举
**6 值**:StandardConversion/**StaticObjectArgumentConversion**(静态
成员函数的合成对象实参,[over.best.ics.general]p8,最易漏记)/
UserDefinedConversion/AmbiguousConversion/EllipsisConversion/
BadConversion;内部 union{Standard, UserDefined, Ambiguous, Bad}。
`class StandardConversionSequence`(:292)三段式:
First(标准转换)/Before+After(用户定义转换前后)…标准转换本身由
ImplicitConversionKind 枚举(ICK_*,约 40 种)描述;排序用
ImplicitConversionRank(:215):Exact/Promotion/Conversion。比较结果
`CompareKind`(:785)三值:Better=-1/Indistinguishable=0/Worse=1
——**不是 bool**,因为"不可区分"是裁决 tie-breaker 的输入。

构造器(static):IsStandardConversion(:2078)、
IsUserDefinedConversion(:3724)、TryImplicitConversion(:1690 static
/:1745 成员)、TryUserDefinedConversion(:1587)、
TryObjectArgumentInitialization(:5655)、TryReferenceInit(:5029)、
TryCopyInitialization(:5294)、TryListConversion(:5303)。

比较器族(全 static,返回 CompareKind):
CompareImplicitConversionSequences(:4052)、
CompareStandardConversionSequences(:4290)、
compareStandardConversionSubsets(:4189)、CompareQualificationConversions
(:4533)、CompareDerivedToBaseConversions(:4602)、
compareConversionFunctions(:3982,lambda 转换函数特判)、
isBetterReferenceBindingKind(:4234)。

### 12.3 裁决

`OverloadCandidateSet::BestViableFunction`(SemaOverload.cpp:10676):
先一遍筛 viable,再逐对比较。`struct OverloadCandidate`(Overload.h:872)
的 Best 字段语义是"ambiguity kernel"——最小非空集合使其内部互不劣于
外部。自由函数 `clang::isBetterOverloadCandidate`(:10232)实现
C++ [over.match.best]:先 CUDA host/device 偏好,再 ICS 逐参比较、
enable_if 部分排序、约束比较、tie-breaker(模板/非模板、特化程度、
C++20 反写候选 CRK_Reversed)。失败恢复:
BuildRecoveryCallExpr(static :13713);FixIt 挽救:
OverloadCandidate::TryToFixBadConversion 用 SemaFixItUtils 的
ConversionFixItGenerator(SemaFixItUtils.h:32,tryToFixConversion
cpp:50)生成 `*`/`&`/`(T)` 插入建议。

运算符重载的总构造:CreateOverloadedUnaryOp(:14169)、
CreateOverloadedBinOp(:14426)、CreateOverloadedArraySubscriptExpr
(:15020)、BuildOverloadedCallExpr(:14033)。

用户定义转换的执行:`Sema::PerformImplicitConversion`(SemaExprCXX.cpp:4199
总入口/:4312)按 ICS 三类分派,static BuildCXXCastArgument(:4136)
构造转换函数调用。

---

## 13. 模板:声明、推导与实例化

### 13.1 声明层(SemaTemplate.cpp)

- 模板参数:ActOnTypeParameter(:992,配 BuildTypeConstraint :1102/
  AttachTypeConstraint :1186)、ActOnNonTypeTemplateParameter(:1444)、
  ActOnTemplateTemplateParameter(:1574)、ActOnTemplateParameterList
  (:1741);CheckTemplateParameterList(:2274)按 TemplateParamListContext
  (Sema.h:11278,TPC_ClassTemplate 等 8 种)区分上下文规则;
- 模板名:LookupTemplateName(:379)、ActOnTemplateName(:4484);
- 实参:CheckTemplateArgument 三重载(:4987 通用/:5891 类型实参/
  :6493 非类型求值)、CheckTemplateArgumentList(:5276)、
  CheckTemplateIdType(:3284)、ActOnTemplateIdType(:3553);
- 类模板:CheckClassTemplate(:1794);显式特化
  ActOnClassTemplateSpecialization(:8066)、成员特化
  CheckMemberSpecialization(:9054)、函数模板特化
  CheckFunctionTemplateSpecialization(:8793);
- 显式实例化:ActOnExplicitInstantiation(:9402/:9697/:9811);
- 模板声明的作用域合法性:CheckTemplateDeclScope(:7774)(没有
  "CheckTemplateDeclarator" 这个函数);ActOnTemplateDeclarator
  (:8436)只是 HandleDeclarator 薄包装;
- 概念定义:ActOnConceptDefinition(:8455 一带)。

### 13.2 推导层(SemaTemplateDeduction.cpp)

Sema 成员入口按用途分:

| 入口 | 行号 | 用途 |
|---|---|---|
| Sema::DeduceTemplateArguments | :2661 | 参数列表 P/A(转发 static) |
| 同上 | :4362 | **函数模板 + 调用实参(重载解析主入口)** |
| 同上 | :4623 | 函数地址/签名匹配 [temp.deduct.funcaddr] |
| 同上 | :4750 | 转换函数模板 [temp.deduct.conv] |
| 同上 | :4882 | 显式实参、无推导对象 [temp.arg.explicit] |
| 同上 | :3347/:3353 | 类/变量模板偏特化(→ static :3298) |

返回 `TemplateDeductionResult`(枚举在 **Sema.h:387**,不在
TemplateDeduction.h——那里只有前置声明):Success/Invalid/
InstantiationDepth/Incomplete/Inconsistent/SubstitutionFailure/
DeducedMismatch/TooManyArguments/TooFewArguments/ConstraintsNotSatisfied/
AlreadyDiagnosed 等 23 值。`class TemplateDeductionInfo`
(TemplateDeduction.h:43)携带 deduced 参数表与 SFINAE 诊断
(addSFINAEDiagnostic :151/takeSFINAEDiagnostic :108)。

**SFINAE 的实现开关是 `class Sema::SFINAETrap`(Sema.h:12080)**:
RAII 保存/恢复 NumSFINAEErrors、InNonInstantiationSFINAEContext、
AccessCheckingSFINAE;推导期间 hasErrorOccurred() 为真即静默失败,
不污染主诊断流。auto 推导也住在这层:DeduceAutoType(:5045)、
DeduceReturnType(:5289)。

### 13.3 实例化层

两个引擎、一条队列:

- **声明层引擎**:`class TemplateDeclInstantiator : public
  DeclVisitor<TemplateDeclInstantiator, Decl*>`(声明 Template.h:558,
  实现散布 SemaTemplateInstantiateDecl.cpp,71 个 VisitXXXDecl,首个
  VisitTranslationUnitDecl :941)——**基于 DeclVisitor(动态分派)而非
  TreeTransform**;
- **表达式/类型层引擎**:`class TemplateInstantiator : public
  TreeTransform<TemplateInstantiator>`(SemaTemplateInstantiate.cpp:1337,
  匿名命名空间)——CRTP 静态分派,持 TemplateArgs/Loc/Entity,
  TransformTemplateTypeParmType 等 override 完成实参替换;参数包展开
  逻辑在 :1385-1405(ArgumentPackSubstitutionIndex 与
  CheckParameterPacksForExpansion 协作);

类实例化:InstantiateClass(SemaTemplateInstantiate.cpp:3412)、
InstantiateClassTemplateSpecialization(:3957,选偏特化)、
InstantiateClassMembers(:3979);函数体:InstantiateFunctionDefinition
(SemaTemplateInstantiateDecl.cpp:4880)。

**延迟实例化队列**(Sema.h:13496-13515):`PendingImplicitInstantiation
= pair<ValueDecl*, SourceLocation>`,三个队列——PendingInstantiations
(std::deque,TU 末统一消费)、LateParsedInstantiations(等延迟解析的
模板体)、局部类成员专用队列(必须原局部作用域)。
`Sema::PerformPendingInstantiations(bool LocalOnly)`
(**SemaTemplateInstantiateDecl.cpp:6382**)消费队列,由
Sema.cpp:1145(片段末)与 :1201(TU 末)调用;PCH 场景先换入
delayedPCHInstantiations(:6417/:6465)。**协程 range-for 是例外**:
立即实例化(SemaStmt.cpp:2369 注释 "immediately and not later during
template instantiation")。

**当前实例化点**:`struct Sema::InstantiatingTemplate`(Sema.h:12839)
是 RAII(9 个构造重载 :12843-12911),内部把 `CodeSynthesisContext`
(Sema.h:12654,SynthesisKind 15 种)压入 CodeSynthesisContexts 栈——
诊断的 "in instantiation of" 栈、实例化深度限制
(CheckInstantiationDepth,SemaTemplateInstantiate.cpp:878,默认 1024)
都读这个栈。局部实例化作用域 `class sema::LocalInstantiationScope`
(**Template.h:365**,嵌套 class;Sema.h:151 只有前置声明)记录
局部声明到实例的映射;`class sema::MultiLevelTemplateArgumentList`
(Template.h:76)支持外层类/内层函数模板的多层实参。

参数包:展开点计算 CheckParameterPacksForExpansion
(SemaTemplateVariadic.cpp:693);收集器
CollectUnexpandedParameterPacksVisitor(:30,RecursiveASTVisitor);
门面 collectUnexpandedParameterPacks 6 重载(:533-562);入口
ActOnPackExpansion 3 重载(:575/:614/:668);诊断
DiagnoseUnexpandedParameterPacks(:303)。

---

## 14. TreeTransform:CRTP 变换框架与 9 个子类

`template<typename Derived> class TreeTransform`(lib/Sema/
TreeTransform.h:109)是头文件级框架(16,515 行):头注释(:55-100)
自述为 "semantic tree transformation"——**CRTP 静态多态**的
"transform + rebuild" 两段式:TransformXXX(约 440 个)递归变换子
节点,**仅当有变化**才调 RebuildXXX(约 247 个)用 Sema 重建节点;
子类可只覆盖 RebuildXXX(克隆场景用更廉价的重建)。持 `Sema &
SemaRef`(:135)。

全库子类**精确 9 个**(grep ": public TreeTransform<"):

| 子类 | 位置 | 用途 |
|---|---|---|
| TemplateInstantiator | SemaTemplateInstantiate.cpp:1337 | 模板实例化(最重要) |
| TransformTypos | SemaExprCXX.cpp:8703 | 拼写纠正重试 |
| TransformToPE | SemaExpr.cpp:17106 | unevaluated→potentially evaluated 重标记 |
| AdjustConstraintDepth | SemaConcept.cpp:917 | 原子约束缓存 |
| CurrentInstantiationRebuilder | SemaTemplate.cpp:10645 | 当前实例化重建 |
| ConstraintRefersToContainingTemplateChecker | SemaTemplate.cpp:1647 | 约束引用检查 |
| ExtractTypeForDeductionGuide | SemaTemplateDeductionGuide.cpp:61 | 推导指引类型抽取 |
| CaptureVars | SemaOpenMP.cpp:5365 | OpenMP 捕获 |
| TransformExprToCaptures | SemaOpenMP.cpp:17809 | OpenMP 捕获 |

**16,515 行是框架本体,不是实例化专用代码**——这正是它能同时服务
实例化、typo 纠错、约束检查、OpenMP 捕获的原因。

---

## 15. 概念与 requires 表达式

**入口分工容易记错**:

- **requires 表达式的三段式 ActOn\* 在 SemaExprCXX.cpp**:
  ActOnStartRequiresExpr(:9386,建 RequiresExprBodyDecl + 局部参数
  作用域)→ ActOnFinishRequiresExpr(:9415)→ ActOnRequiresExpr
  (:9421,Create + DiagnoseUnexpandedParameterPackInRequiresExpr);
- **SemaConcept.cpp 只管约束求值/比较/诊断**。

概念检查:`Sema::CheckConstraintSatisfaction` 三重载(SemaConcept.cpp:618
NamedDecl+约束列表+多级实参,带 Satisfaction 缓存/:687 单表达式/
Sema.h 内联版);递归求值 calculateConstraintSatisfaction 4 重载
(:183/:189/:254/:326,合取/析取/fold 展开);
CheckConstraintExpression(:92,[temp.constr.atomic] 合法性);
CheckFunctionConstraints(:836)、
CheckInstantiatedFunctionTemplateConstraints(:1096)、
EnsureTemplateArgumentListConstraints(:1069)、IsAtLeastAsConstrained
(:1751)、DiagnoseUnsatisfiedConstraint(:1384,带 fix-it 的"约束
不满足"树状打印)。

数据结构:`struct NormalizedConstraint`(include/clang/Sema/
SemaConcept.h:105)把约束正规化为合取/析取树(AtomicConstraint/
FoldExpandedConstraint/Compound 的 PointerUnion),makeCNF/makeDNF
(:92/:98);`class ConstraintSatisfaction` 在 **include/clang/AST/
ASTConcept.h:35**(FoldingSet 缓存,避免重复求值);概念 ID 表达式
的构造在 SemaTemplate.cpp:CheckConceptTemplateId(:4341,
ConceptSpecializationExpr::Create :4385)。

---

## 16. Lambda 与协程

### 16.1 Lambda(SemaLambda.cpp)

流程链:ActOnLambdaExpressionAfterIntroducer(:1059,创建闭包类 via
createLambdaClosureType :248)→ ActOnLambdaClosureQualifiers(:1334)
→ ActOnStartOfLambdaDefinition(:1388)→ … → ActOnLambdaExpr(:1946)
→ `Sema::BuildLambdaExpr`(:2067,收集 LSI->Captures →
Captures/CaptureInits;Class->setCaptures :2200;ActOnFields +
CheckCompletedCXXClass 收尾 :2220-2224;LambdaExpr::Create :2229)。

**捕获分析核心不在 SemaLambda.cpp**:`Sema::tryCaptureVariable` 两
重载在 **SemaExpr.cpp:18685**(工作版)/:18984(简版);
NeedToCaptureVariable(:18995);CheckCXXThisCapture 在 SemaExprCXX.cpp
(:1296);TryCaptureKind 枚举(Sema.h:6597):TryCapture_Implicit/
ExplicitByVal/ExplicitByRef。运行期记录 `class sema::Capture`
(ScopeInfo.h:559:Cap_ByCopy/Cap_ByRef/Cap_Block/Cap_VLA + 
CapturedVar/Loc/EllipsisLoc/CaptureType),容器
`class LambdaScopeInfo final`(ScopeInfo.h:861,继承 FunctionScopeInfo
:104)——**FunctionScopeInfo 家族是"函数体内语义状态"的统一载体**
(也承载返回类型推导、协程状态)。闭包类编号:
getCurrentMangleNumberContext(:281)。

### 16.2 协程(SemaCoroutine.cpp + CoroutineStmtBuilder.h)

`Sema::ActOnCoroutineBodyStart`(:687):进入 PotentiallyEvaluated
上下文 + checkCoroutineContext(static :582,经 isValidCoroutineContext
:184)→ 初/终 suspend 只建一次。触发点:co_await/co_yield/co_return
的 ActOn* 入口(:790/:912/:970),**外加 range-for 的协程化**
(SemaStmt.cpp:2371)。promise 类型查找 lookupPromiseType(static :54,
在 std 查 coroutine_traits<R,...>::promise_type);函数体完成期
CheckCompletedCoroutineBody(:1091,由 SemaDecl.cpp:15801 的
ActOnFinishFunctionBody 调用)。`class CoroutineStmtBuilder : public
CoroutineBodyStmt::CtorArgs`(CoroutineStmtBuilder.h:24)一次性组装
CoroutineBodyStmt 的全部隐式成员(promise、initial/final suspend、
return_object、on_exception、Gro 声明等;makePromiseStmt :1195、
makeInitialAndFinalSuspend :1207、makeReturnOnAllocFailure :1238…)。

---

## 17. ObjC:SemaObjC 三文件

ObjC 已整体迁到 `class SemaObjC : public SemaBase`(SemaObjC.h:50,
**所有函数签名是 SemaObjC:: 不再是 Sema::**),按头文件注释分三个
实现文件:

- **SemaDeclObjC.cpp(5685 行)——声明**:类接口链
  ActOnStartClassInterface(:974,@interface)/
  ActOnStartProtocolInterface(:1216)/ActOnStartCategoryInterface
  (:1814);实现链 ActOnStartCategoryImplementation(:1913)/
  ActOnStartClassImplementation(:1981,@implementation,接口名 typo
  纠错)/ActOnFinishObjCImplementation(:2117);ActOnAtEnd(:3983,
  方法重复/类型冲突检查、方法注入全局池);ActOnForwardClassDeclaration
  (:3060)/ActOnForwardProtocolDeclaration(:1786)/
  ActOnCompatibilityAlias(:1142);成员 ActOnIvar(:5573)、方法
  ActOnMethodDeclaration(:4728,related result type 判定 :4764)、
  ActOnStartOfObjCMethodDef(:369,压 self/_cmd 入 scope、ARC retain
  家族禁用)——**方法体结束复用 Sema::ActOnFinishFunctionBody**;
- **SemaObjC.cpp(2408 行)——表达式/语句**:@try/@catch/@finally/
  @throw/@synchronized/@autoreleasepool(ActOnObjCAtTryStmt :222、
  ActOnObjCAtThrowStmt :269、ActOnObjCAtSynchronizedStmt :324、
  ActOnObjCAutoreleasePoolStmt :333)、快速枚举
  ActOnObjCForCollectionStmt(:35)、容器上下文进出
  (ActOnObjCContainerStartDefinition :1275 等)、instancetype
  (ActOnObjCInstanceType :744)、CFString 字面量检查
  CheckObjCString(:1217);
- **SemaObjCProperty.cpp(2800 行)——@property**:ActOnProperty
  (:174)、HandlePropertyInClassExtension(:404)、
  ActOnPropertyImplDecl(:1062,@synthesize/@dynamic)、
  ProcessPropertyDecl(:2356,合成 getter/setter 声明)、
  CheckObjCPropertyAttributes(:2619,PropertyAttribute 语义检查:
  readonly/readwrite 互斥、weak/copy/retain 类型要求、getter=/setter=
  命名)。

消息表达式(SemaExprObjC.cpp,5248 行):类消息
ActOnClassMessage(:2766)/BuildClassMessage(:2618)/
BuildClassMessageImplicit(:2442);实例消息 ActOnInstanceMessage
(:3423)/BuildInstanceMessage(:2843)/BuildInstanceMessageImplicit
(:2787)——**没有 ActOnMessageExpr 这个名字**。

---

## 18. 属性体系:ParsedAttr 与 SemaDeclAttr

### 18.1 信息表与公共检查

属性的信息源是 **Attr.td**(include/clang/Basic/Attr.td)→ TableGen
→ AttrParsedAttrImpl.inc;运行期代表 `class ParsedAttr`
(include/clang/Sema/ParsedAttr.h)+ ParsedAttrInfo/AttributeCommonInfo
(Basic 层)。**AppertainTo(属性挂在什么上)等公共检查不在
SemaDeclAttr.cpp**:ParsedAttr.h:536-537 声明 diagnoseAppertainsTo,
实现 ParsedAttr.cpp:162-167;统一调用点是 **SemaAttr.cpp:1407 的
checkCommonAttributeFeatures 模板函数**(依次 diagnoseLangOpts →
diagnoseAppertainsTo → diagnoseMutualExclusion → CheckAttrTarget →
参数个数;:1454/:1458 是 Decl/Stmt 公开包装)。

### 18.2 ProcessDeclAttribute:分发核心

`static void ProcessDeclAttribute(...)`(SemaDeclAttr.cpp:6254)流程:
①无效/忽略早退(:6257-6258);②[[]] 属性按 IncludeCXX11Attributes
过滤(:6262);③未知属性 warn_unknown_attribute_ignored(:6274);
④MustDelayAttributeArguments(:6221)→ handleAttrWithDelayedArgs
(:6293,延迟到模板实例化后);⑤checkCommonAttributeFeatures
(:6289);⑥**巨型 switch `AL.getKind()`,case ParsedAttr::AT_ 共
296 个**;default 分支先试 `AL.getInfo().handleDeclAttribute`
(表生成钩子),再按 type-attr"滑动到 DeclSpec"的 legacy 行为
(AT_Regparm/AT_VectorSize/AT_NoDeref)处理。

**handleXxxAttr 家族 139 个 static 定义**(handleAvailabilityAttr
:2244、handleGuardedByAttr :446、handleAllocSizeAttr :562、
handleDiagnoseIfAttr :847、handleCountedByAttrField :5852…),另有
`handleSimpleAttribute<T>` 模板大量复用——**139 个 handler 对 296
个 case,差额就是模板复用、目标子类 handler 与多 case 共用**。
上层入口:ProcessDeclAttributeList(:7106)、
ProcessDeclAttributeDelayed(:7179)、ProcessDeclAttributes(:7330)。
Pragma 属性在 SemaAttr.cpp:ActOnPragmaPack(:335)、
ActOnPragmaVisibility(:1249)、ActOnPragmaUnused(:836)。

---

## 19. 诊断、typo 纠错与 CodeCompletion

### 19.1 诊断

Sema 的诊断 ID 全部在 **Basic/DiagnosticSemaKinds.td**(
`let Component = "Sema"`),生成 diag:: 枚举(DIAG_SIZE_SEMA =
4500);Sema/SemaDiagnostic.h 是空壳转发头。发诊断的三条路:
①`SemaRef.Diag(loc, diag::...)` 直接发;②SemaBase 的
ImmediateDiagBuilder(自动带实例化栈);③**DelayedDiagnostic**
(include/clang/Sema/DelayedDiagnostic.h:128)——仅 3 种 DDKind
(Availability/Access/ForbiddenType),在"暂时不能确定合不合法"的
上下文(如延迟解析的函数体)里先缓存,统一补发点
`Sema::PopParsingDeclaration`(SemaDeclAttr.cpp:7451)。

### 19.2 typo 纠错

`Sema::CorrectTypo`(SemaLookup.cpp:5261):先问 ExternalSource,
makeTypoCorrectionConsumer,编辑距离 ≤ 名长 1/3 的启发式(:5297);
`Sema::diagnoseTypo`(小写 d,两重载 :5520/:5673)负责出诊断
("did you mean...?")。**延迟纠错引擎在 SemaExprCXX.cpp**:
`class TransformTypos : public TreeTransform<TransformTypos>`(:8703)
——对"先用着、错了解析完再改"的表达式,解析完后重放整个表达式
构造,在每个名字查找点尝试纠正;`Sema::CorrectDelayedTyposInExpr`
(:9025)是门面。成员访问路径的纠错在 LookupMemberExprInRecord
(SemaExprMember.cpp:704)内联进行。

### 19.3 CodeCompletion

`class SemaCodeCompletion : public SemaBase`(SemaCodeCompletion.h:37,
持 CodeCompleteConsumer*),访问器 `Sema::CodeCompletion()`
(Sema.h:1159)。**触发模型是 Parser 侧拉式**:Parser 在
tok::code_completion 处调 `Actions.CodeCompletion().CodeCompleteXXX`,
共 **101 处**散布 lib/Parse/ 10 个文件;词法层(宏名/预处理指令补全)
另有约 24 处经 `CodeCompletionHandler` 接口(include/clang/Lex/
CodeCompletionHandler.h:25)——宏补全直接遍历 PP.macro_begin/end()
(AddMacroResults SemaCodeComplete.cpp:4195,遍历在 :4202-4203)。入口方法约 60 个
(CodeCompleteOrdinaryName :4416、CodeCompleteMemberReferenceExpr、
CodeCompleteLambdaIntroducer、CodeCompleteObjCInstanceMessage…);
核心构件 ResultBuilder(收集过滤);消费端 `class
CodeCompleteConsumer`(CodeCompleteConsumer.h:1019,非 abstract 基类,
含 OverloadCandidate 与 PrintingCodeCompleteConsumer);上下文枚举
CCC_*(同文件 :186,39 个不同值)。**补全不走 PPCallbacks**;真
PP 回调是 sema::SemaPPCallbacks(Sema.cpp:159 注册,-Wpragma-pack 用)。

---

## 20. 语句层与分析警告

### 20.1 语句族(SemaStmt.cpp)

ActOnNullStmt(:74)、ActOnDeclStmt(:79)、ActOnCompoundStmt(:415)、
ActOnLabelStmt(:572)、ActOnIfStmt(:908)、ActOnStartOfSwitchStmt
(:1121)、ActOnCaseStmt(:516)/ActOnDefaultStmt(:552)、ActOnWhileStmt
(:1719)、ActOnDoStmt(:1740)、ActOnForStmt(:2164)、ActOnGotoStmt
(:3126)、ActOnContinueStmt(:3181)、ActOnBreakStmt(:3208)、
ActOnReturnStmt(:3736)。条件检查:CheckBooleanCondition(SemaExpr.cpp
:20122)/CheckConditionVariable(SemaExprCXX.cpp:4033)。
**warn_unused_result 在本文件**(:216-298,丢弃值表达式检查)。

inline asm:`Sema::ActOnGCCAsmStmt`(SemaStmtAsm.cpp:243,约束串
解析、操作数匹配、NumLabels)、ActOnMSAsmStmt(:932)。语句属性
(SemaStmtAttr.cpp):ProcessStmtAttributes(:685)分发 14 个 handler
(fallthrough、suppress、loop hint、musttail、likely/unlikely、
code_align…)。

### 20.2 SemaChecking.cpp:调用点检查的聚合层

- **格式串**(-Wformat):CheckFormatArguments 两重载(:6044/:6058)
  ← checkCall(:3151,遍历 FormatAttr)← CheckFunctionCall(:3358)
  ← BuildCallExpr(SemaExpr.cpp:6947)。处理器类 CheckFormatHandler
  (:6144,继承 analyze_format_string::FormatStringHandler,AST 层
  FormatString.h:716)、CheckPrintfHandler(:6602)、CheckScanfHandler
  (:7636);格式串实际解析在 **lib/AST/**(PrintfFormatString.cpp/
  ScanfFormatString.cpp)——Sema 只做"对号入座"与诊断;
- **内建函数**:`Sema::CheckBuiltinFunctionCall`(:2060,巨型 switch
  按 Triple 分发到各目标子 Sema,见第 21 章)。**注意命名:没有
  "SemaBuiltin*" 前缀家族**(全文件 0 命中),实际是
  `Sema::BuiltinXXX`(24 个成员:BuiltinVAStart :4661、
  BuiltinConstantArg :5304、BuiltinAssumeAligned :5180…)+ static
  `BuiltinXXX`(15 个:BuiltinAddressof :270、BuiltinCpu :1952…);
- **libc 函数**(由 CheckFunctionCall :3419-3431 按
  FDecl->getMemoryFunctionKind() 分派):CheckMemaccessArguments
  (:8629,memcpy 目的地大小)、CheckStrlcpycatArguments(:8855)、
  CheckFreeArguments(:9098,free 非堆指针)、
  checkFortifiedBuiltinMemoryFunction(:1138,_FORTIFY_SOURCE);
- **隐式转换告警**:CheckImplicitConversion(:10734,-Wconversion
  家族的截断/符号核心)、CheckFloatComparison(:9175)、
  DiagnoseAlwaysNonNullPointer(:11514);
- **-Wtautological**:CheckTautologicalComparison(static :9947)。

### 20.3 AnalysisBasedWarnings:函数体级流分析

`class clang::sema::AnalysisBasedWarnings`(include/clang/Sema/
AnalysisBasedWarnings.h:32)在 ActOnFinishFunctionBody 后跑:入口
`IssueWarnings` 两重载(lib/Sema/AnalysisBasedWarnings.cpp:2508 TU 级/
:2556 单函数级)。内部 Policy(4 个位域开关)控制清单:CFG 构建、
CheckFallThroughForBody(:665,-Wreturn)、CheckUnreachable(:125)、
线程安全分析(ThreadSafetyReporter :1796)、consumed 分析、
checkCalledOnceParameters(:2750 调用,本体在 **include/clang/
Analysis/Analyses/CalledOnceCheck.h:120**)、diagnoseRepeatedUseOfWeak
(:1373)、checkRecursiveFunction(:282)、checkThrowInNonThrowingFunc
(:385)、**未初始化变量**(runUninitializedVariablesAnalysis 调用点
:2728,实现在 lib/Analysis/Analyses/UninitializedValues,报告器
UninitValsDiagReporter :1549)、**unsafe-buffer-usage**(-Wunsafe-
buffer-usage,经 clang::checkUnsafeBufferUsage,实现在 lib/Analysis/
UnsafeBufferUsage.cpp:3033)。**跳转诊断(JumpDiagnostics.cpp)虽是
流分析性质,却在 ActOnFinishFunctionBody 里更早独立调用**
(SemaDecl.cpp:16134),不归这个类管。

---

## 21. 语言与目标子 Sema 类

### 21.1 语言扩展类

- **SemaCUDA**(SemaCUDA.h:35,1082 行):三级目标推断
  IdentifyTarget(ParsedAttributesView :71/FunctionDecl :136/VarDecl
  :164);maybeAddHostDeviceAttrs(:740,隐式 host+device);
  checkTargetOverload(:1005);DiagIfDeviceCode(:819)/DiagIfHostCode
  (:851,**延迟诊断**——device 代码里的 host 调用先记下,TU 末若
  真是 device 编译才报);getConfigureFuncName(:1070,<<<>>> 配置
  函数名)。**AMDGPU 不在 SemaCUDA 里**(grep 零命中),是独立的
  SemaAMDGPU;
- **SemaHLSL**(SemaHLSL.h:30):cbuffer/tbuffer(ActOnStartBuffer
  :32/ActOnFinishBuffer :82)、CheckEntryPoint(:214,shader stage
  与 numthreads 互斥)、DiagnoseAvailabilityViolations(:884);另配
  **HLSLExternalSemaSource**(include/clang/Sema/HLSLExternalSemaSource.h:23,
  : ExternalSemaSource):InitializeSema(:390)注入 hlsl 命名空间的
  内建类型(defineHLSLTypesWithForwardDeclarations :497);
- **SemaSYCL**(SemaSYCL.h:27):DiagIfDeviceCode(:26,按 emission
  状态选 Immediate/Deferred)、deepTypeCheckForDevice(:47,device
  代码非法类型的深检查)、handleKernelAttr(:162);
- **SemaOpenMP**(SemaOpenMP.h:47,SemaOpenMP.cpp 23845 行,全目录
  最大文件):指令/子句的 ActOn* 家族 + 两个 TreeTransform 子类
  (CaptureVars/TransformExprToCaptures,第 14 章);
- **SemaPseudoObject**(SemaPseudoObject.h:26):把 ObjC 属性引用
  与 MS 属性这类"伪对象"展开为 PseudoObjectExpr(语法形 + 语义形
  序列):checkRValue(:1450)/checkIncDec(:1475)/checkAssignment
  (:1505)/recreateSyntacticForm(:1561);
- **SemaOpenACC/SemaSwift/SemaOpenCL/SemaBoundsSafety/SemaAPINotes/
  SemaAvailability**:小而专——SemaBoundsSafety.cpp(193 行)只有
  CheckCountedByAttrOnField(:51,-fbounds-safety 的 counted_by 检查);
  SemaAPINotes 的 ProcessAPINotes(:788)把 API notes 二进制注记翻译
  成 Clang 属性(nullability/retain count/可用性);SemaAvailability
  的 DiagnoseAvailabilityOfDecl(:1043)/
  DiagnoseUnguardedAvailabilityViolations(:1012,@available 上下文
  流分析)。

### 21.2 目标子类:统一经 Triple 分发

15 个架构子类,统一入口 `Sema::CheckBuiltinFunctionCall`
(SemaChecking.cpp:2060)按 llvm::Triple switch 分发(aarch64→ARM()
:1882、bpf→BPF()、hexagon→Hexagon()、mips→MIPS()、systemz、x86
:1895-1896、ppc、amdgcn→AMDGPU() :1903、riscv→RISCV() :1905、
loongarch :1908、wasm :1913、nvptx :1917…):

| 子类 | 行数 | 代表函数 |
|---|---|---|
| SemaARM | 1340 | CheckARMBuiltinFunctionCall :985、CheckSMEBuiltinFunctionCall :659、ParseSVEImmChecks :406 |
| SemaRISCV | 1491 | CheckBuiltinFunctionCall :559、CheckLMUL :509、checkRVVTypeSupport :1374 |
| SemaX86 | 972 | CheckBuiltinFunctionCall :479、handleAnyInterruptAttr :880 |
| SemaWasm | 341 | CheckWebAssemblyBuiltinFunctionCall :219 |
| SemaLoongArch | 515 | CheckLoongArchBuiltinFunctionCall :22 |
| SemaPPC | 439 | CheckPPCBuiltinFunctionCall :92、CheckPPCMMAType :256 |
| SemaAMDGPU | 311 | CheckAMDGCNBuiltinFunctionCall :25、handleAMDGPUFlatWorkGroupSizeAttr :160 |
| SemaHexagon | 290 | CheckHexagonBuiltinArgument :24 |
| SemaMIPS | 300 | CheckMipsBuiltinFunctionCall :24 |
| SemaBPF | 194 | CheckBPFBuiltinFunctionCall :111、handlePreserveAccessIndexAttr :187 |
| SemaSystemZ | 94 | CheckSystemZBuiltinFunctionCall :24 |
| SemaMSP430 | 78 | handleInterruptAttr :25 |
| SemaM68k | 56 | handleInterruptAttr :23 |
| SemaAVR | 49 | handleInterruptAttr :23/handleSignalAttr :36 |
| SemaNVPTX | 35 | CheckNVPTXBuiltinFunctionCall :21 |

共性:大目标以 `CheckXBuiltinFunctionCall/CheckXBuiltinArgument`(常量
参数范围、立即数合法性、SVE/RVV 的 type-range 检查)为主;小目标
只剩 interrupt 属性 handler。OpenCL 走**表驱动**:
OpenCLBuiltins.td(1894 行,`def : Builtin<...>` 文本 399 处,大量
重载由 multiclass 在 TableGen 展开期生成)→ ClangOpenCLBuiltinEmitter
→ OpenCLBuiltins.inc → SemaLookup.cpp:55 include;查找命中时
InsertOCLBuiltinDeclarationsFromTable(SemaLookup.cpp:817)按版本掩码
与扩展宏过滤后逐签名构造 FunctionDecl 注入——**OpenCL 内建函数没有
手写的 .def 表,是查表造声明**。

---

## 22. 外部 Sema 源与模块

### 22.1 ExternalSemaSource

`class ExternalSemaSource : public ExternalASTSource`
(include/clang/Sema/ExternalSemaSource.h:50,约 24 个虚函数):
**PCH/模块文件加载器的回调面**——LookupUnqualified、ReadDeclsToCheck
forDeferredDiags、CorrectTypo 协作等。`MultiplexExternalSemaSource`
(MultiplexExternalSemaSource.h:38)聚合多个源(PCH + 显式模块可
叠加);HLSLExternalSemaSource(第 21 章)是"无文件、纯合成声明"
的特例。CompilerInstance 在 PCH 场景把 ASTReader(它实现
ExternalSemaSource)经 Sema::addExternalSource(Sema.cpp:596-608)
挂进 Sema。

### 22.2 模块(SemaModule.cpp)

C++20 Modules 与 clang modules 的双轨 API:

- C++20:ActOnGlobalModuleFragmentDecl(:163,`module;` 前片段)、
  ActOnModuleDecl(:259,分区名归一/编译模式互斥/每文件一次)、
  ActOnPrivateModuleFragmentDecl(:512,`module;:`)、ActOnModuleImport
  (:574/:640,含自导入诊断与 loadModule);
- clang modules 隐式:ActOnAnnotModuleBegin(:761)/
  ActOnAnnotModuleEnd(:785)(进出 ModuleScopes 并设置声明所有权);
- export:ActOnStartExportDecl(:844)/ActOnFinishExportDecl(:993);
- 全局片段进出:PushGlobalModuleFragment(:1026)/Pop(:1045)/
  PushImplicitGlobalModuleFragment(:1052)/Pop(:1068)。

---

## 23. 设计取舍与不变量

通读 28.7 万行后能提炼出的结构性规律:

1. **ActOn 薄、Build 厚**:ActOn* 只做 Token→枚举的翻译与立即诊断,
   Build* 接受半成品做真构造——这样 Sema 内部复用(BuildXxx)与
   Parser 回调(ActOnXxx)共享同一条构造路径;
2. **Sema 对 Parser 单向依赖**:Sema 不 include Parse,Parser 持
   Actions 引用;数据交换全靠 DeclSpec/ParsedAttr/CXXScopeSpec 这类
   "解析器形态"的信封类型,进 Sema 后立即翻译成 AST 形态;
3. **Scope 栈与 DeclContext 树双轨**:词法可见性(Scope)与语义
   归属(DeclContext)是两张图,PushOnScopeChains(SemaDecl.cpp:1495)
   是唯一双写点——理解"声明挂在哪"必须同时看两张图;
4. **查名永远经 LookupResult**:16 种 LookupNameKind + 6 种结果状态
   + 模块时代的 shadowed 态,所有查名入口(LookupName/
   LookupQualifiedName/LookupParsedName/ADL)产出统一货币;
5. **初始化是"先编程后执行"**:InitializeFrom 产出 Steps 程序,
   Perform 解释执行——诊断(为什么失败)与代码生成(怎么初始化)
   共享同一个步骤序列,失败信息在分析期就已完备;
6. **重载解析是纯函数式收集+裁决**:Add* 收集、BestViableFunction
   裁决、ICS 是六值三比较的可判定代数;slab 分配器保证一次候选集
   的 ICS 内存零碎片、整体释放;
7. **SFINAE 靠错误计数器,不靠异常**:`SFINAETrap`(Sema.h:12080)
   保存/恢复 NumSFINAEErrors——推导失败静默退出,不污染主诊断流;
   这是"替换失败不是错误"在实现层的全部;
8. **实例化 = 声明层 DeclVisitor + 表达式层 TreeTransform 双引擎**:
   TemplateDeclInstantiator(动态分派,71 个 Visit)管声明,
   TemplateInstantiator(CRTP 静态分派)管体;延迟队列(三种)保证
   实例化时机不破坏"先声明后使用";
9. **TreeTransform 是引擎不是功能**:9 个子类各取所需(实例化只
   覆盖 Transform*,克隆只覆盖 Rebuild*),16,515 行是共享框架——
   这就是为什么 typo 纠错(TransformTypos)能"重放整个表达式构造";
10. **目标与语言差异全部外置到子 Sema**:CheckBuiltinFunctionCall
    按 Triple 分发、25 个子类惰性创建、ObjC 整体迁出——Sema 主体
    只保留语言无关的骨架,"加一个目标 = 加一个 SemaX.cpp + 一个
    unique_ptr + 一个访问器";
11. **诊断三通道**:直接 Diag、ImmediateDiagBuilder(带实例化栈)、
    DelayedDiagnostic(3 种,PopParsingDeclaration 补发)——延迟
    通道让"先斩后奏"的解析顺序不产生误报;
12. **流分析是事后一层**:AnalysisBasedWarnings 在函数体完成后跑
    CFG 级检查(-Wreturn/-Wthread-safety/-Wuninitialized…),
    JumpDiagnostics 单独更早——语义检查(声明期)与流分析(完成期)
    是两个明确分层的批次。

---

## 24. 速查表

**想懂什么 → 看哪里**:

| 问题 | 位置 |
|---|---|
| Sema 怎么被构造出来 | CompilerInstance.cpp:745 createSema;Sema 构造 Sema.cpp:214;Initialize :312 |
| 预定义类型从哪来 | Sema.cpp:334-519(__int128_t :334、__builtin_va_list :516) |
| TU 结束做什么 | Sema.cpp:1164 ActOnEndOfTranslationUnit 清单 |
| 函数声明全流程 | ActOnFunctionDeclarator(SemaDecl.cpp:9665)→ CheckFunctionDeclaration(:11793)→ ActOnFinishFunctionBody(:15787) |
| 该 new 哪个 FunctionDecl 子类 | CreateNewFunctionDecl(SemaDecl.cpp:9131) |
| 重声明怎么合并 | MergeFunctionDecl :3535/MergeVarDecl :4459/MergeTypedefNameDecl :2467 |
| 类完成时检查什么 | CheckCompletedCXXClass(SemaDeclCXX.cpp:6831) |
| 隐式构造/析构怎么声明 | AddImplicitlyDeclaredMembersToClass(SemaDeclCXX.cpp:10503) |
| Declarator→QualType | GetTypeForDeclarator(SemaType.cpp:5645)三步 |
| auto 在哪推导 | DeduceAutoType(SemaTemplateDeduction.cpp:5045,不在 SemaType) |
| `T x = init;` 怎么处理 | InitializationSequence:InitializeFrom(SemaInit.cpp:6280)→ Perform(:7482) |
| 列表初始化逐元素检查 | InitListChecker(SemaInit.cpp:308) |
| -Wdangling 在哪 | checkExprLifetime(CheckExprLifetime.cpp:1303,lib/Sema 下) |
| 二元操作符分派 | BuildBinOp(SemaExpr.cpp:15124)三分派 |
| 算术转换 | UsualArithmeticConversions(SemaExpr.cpp:1539,带 ACK) |
| sizeof 为什么不实例化 | 求值上下文:Push(SemaExpr.cpp:17171)/Pop(:17592) |
| C 风格 cast | ActOnCastExpr(SemaExpr.cpp:7663)→ BuildCStyleCastExpr(SemaCast.cpp:3341) |
| static_cast 等命名 cast | ActOnCXXNamedCast(SemaCast.cpp:274)→ BuildCXXNamedCast(:297) |
| CastKind 有几种 | 67 个 CK_(OperationKinds.h:20/OperationKinds.def) |
| 重载候选怎么收 | Add*Candidate 家族(SemaOverload.cpp:6795 起) |
| 谁是最佳候选 | BestViableFunction(:10676)+ isBetterOverloadCandidate(:10232) |
| ICS 是什么结构 | Overload.h:567(6 值 Kind) |
| SFINAE 怎么实现 | SFINAETrap(Sema.h:12080)错误计数器 |
| 模板推导入口 | DeduceTemplateArguments(SemaTemplateDeduction.cpp:4362 调用版) |
| 实例化何时发生 | PendingInstantiations 队列(Sema.h:13500)+ PerformPendingInstantiations(SemaTemplateInstantiateDecl.cpp:6382) |
| TreeTransform 谁在用 | 9 个子类(见第 14 章表) |
| requires 表达式入口 | ActOnRequiresExpr(SemaExprCXX.cpp:9421,不在 SemaConcept) |
| 约束怎么求值 | calculateConstraintSatisfaction(SemaConcept.cpp:183 起) |
| lambda 捕获分析 | tryCaptureVariable(SemaExpr.cpp:18685,不在 SemaLambda) |
| 协程 promise 查找 | lookupPromiseType(SemaCoroutine.cpp:54) |
| ObjC @interface | ActOnStartClassInterface(SemaDeclObjC.cpp:974,SemaObjC 类) |
| ObjC 消息表达式 | ActOnClassMessage/ActOnInstanceMessage(SemaExprObjC.cpp:2766/:3423) |
| 属性怎么分发 | ProcessDeclAttribute(SemaDeclAttr.cpp:6254,296 case) |
| 属性公共检查 | checkCommonAttributeFeatures(SemaAttr.cpp:1410) |
| typo 纠错 | CorrectTypo(SemaLookup.cpp:5261)+ TransformTypos(SemaExprCXX.cpp:8703) |
| 代码补全怎么触发 | Parser 101 处 CodeCompletion().CodeCompleteXXX + Lex 24 处 CodeCompletionHandler |
| -Wformat 在哪 | CheckFormatArguments(SemaChecking.cpp:6044)→ CheckPrintfHandler(:6602) |
| 内建函数检查 | CheckBuiltinFunctionCall(SemaChecking.cpp:2060,按 Triple 分发) |
| -Wreturn/-Wuninitialized | AnalysisBasedWarnings.cpp:665/:2728(调用) |
| goto 越过初始化 | DiagnoseInvalidJumps(JumpDiagnostics.cpp:1033) |
| PCH 怎么回调 Sema | ExternalSemaSource(ExternalSemaSource.h:50)+ addExternalSource(Sema.cpp:596) |
| C++20 module 声明 | ActOnModuleDecl(SemaModule.cpp:259) |
| OpenCL 内建哪来的 | OpenCLBuiltins.td → inc → InsertOCLBuiltinDeclarationsFromTable(SemaLookup.cpp:817) |

**典型调用链**(普通函数定义 `int f(int x) { return x*2; }`):

```text
Parser::ParseFunctionDefinition
 → Sema::ActOnFunctionDeclarator(SemaDecl.cpp:9665)
    → CreateNewFunctionDecl(:9131)→ FunctionDecl::Create(AST)
    → CheckFunctionDeclaration(:11793)→ MergeFunctionDecl(:3535)
    → PushOnScopeChains(:1495,双写 Scope 与 DeclContext)
 → ActOnStartOfFunctionDef(:15198→:15411,压求值上下文)
 → Parser 逐 token:
    ActOnIdExpression(SemaExpr.cpp:2650)→ LookupParsedName(SemaLookup.cpp:2676)
      → LookupName(:2175)→ BuildDeclarationNameExpr(:3163)
    ActOnBinOp(:15061)→ BuildBinOp(:15124)→ CreateBuiltinBinOp(:14589)
      → UsualArithmeticConversions(:1539)→ ImpCastExprToType(Sema.cpp:694)
    ActOnReturnStmt(SemaStmt.cpp:3736)→ PerformCopyInitialization(SemaInit.cpp:9616)
      → InitializationSequence:InitializeFrom(:6280)→ Perform(:7482)
 → ActOnFinishFunctionBody(:15787)
    → DiagnoseInvalidJumps(:16134)→ AnalysisBasedWarnings::IssueWarnings(:2556)
 → Consumer.HandleTopLevelDecl →(CodeGen 篇的开始)
```

**与兄弟目录的边界**:Parse 提供 Token 与结构回调(ActOn* 的调用方);
AST 提供 Decl/Expr/Type 节点与 ASTContext(Sema 是这些节点唯一的
生产流水线);Basic 提供诊断 ID/属性表/TargetInfo;Lex 提供
Preprocessor 与宏(Sema 经 SemaPPCallbacks 观测);Analysis 提供流
分析算法实现(CFG/未初始化/线程安全——Sema 只出报告器);
Edit/Rewrite 提供错误恢复的源码改写——本目录是**语义的唯一定义者**:
一切"这合法吗/这该绑定到谁/这该转换成什么"的最终裁定都在这里,
CodeGen 只是执行裁定。目标与语言差异全部外置到 25 个子 Sema——
**这是读 28.7 万行代码的地图**。

| 姊妹篇 | 《Clang Frontend 详细设计文档》(ParseAST 与 CompilerInstance 的上游)/
《Clang CodeGen 详细设计文档》(AST 的下游)/
《Clang 基础设施详细设计文档》(ASTContext/诊断)/
《Clang Lex 详细设计文档》(宏与预处理)/
《Clang Driver 详细设计文档》(cc1 之上) |
|---|---|
