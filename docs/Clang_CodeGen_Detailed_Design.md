# Clang CodeGen(IR 生成)详细设计文档

> 基础设施系列第七篇,深入 `clang/lib/CodeGen/`(及 `clang/include/clang/CodeGen/`):
> 从 AST 到 LLVM IR 的翻译层。入口三件套(CodeGenAction/BackendConsumer/
> ModuleBuilder)、模块层(CodeGenModule 的延迟发射)、函数层(CodeGenFunction
> 与三层求值模型)、调用与 ABI、C++ 语义下沉、异常清理栈、各语言运行时
> (ObjC/OpenMP/CUDA/Blocks/协程)、调试信息与 PGO/覆盖率、后端管线装配。
> 所有类名、成员、行号均对照本仓库代码核实。

---

## 目录

1. [总览:clang 最大的库,翻译 + 装配双职责](#1-总览)
2. [入口层:CodeGenAction / BackendConsumer / ModuleBuilder](#2-入口层)
3. [模块层:CodeGenModule 与延迟发射](#3-模块层codegenmodule)
4. [类型与 ABI:CodeGenTypes / CGCXXABI / TargetCodeGenInfo](#4-类型与-abi)
5. [函数层:CodeGenFunction 生命周期与三层求值](#5-函数层codegenfunction)
6. [调用与内建:CGCall / CGBuiltin / CGAtomic](#6-调用与内建)
7. [C++ 语义下沉:声明、构造、虚表、new/delete、常量](#7-c-语义下沉)
8. [异常模型:EHScopeStack 与零开销表](#8-异常模型)
9. [语言运行时:ObjC / OpenMP / CUDA / Blocks / 协程](#9-语言运行时)
10. [观测性:调试信息 / PGO / 覆盖率 / 消毒器元数据](#10-观测性)
11. [后端装配:BackendUtil 与 PCH 容器](#11-后端装配)
12. [设计取舍与不变量](#12-设计取舍与不变量)
13. [速查表](#13-速查表)

---

## 1. 总览

Frontend 篇(第六篇)讲到 `-emit-obj` 的 ASTConsumer 是 BackendConsumer——
本篇从那里接着往下走:**Sema 产出的 AST 如何变成 LLVM IR,IR 又如何被送进
优化与后端管线**。整个答案都在 `clang/lib/CodeGen/`。

规模感:本目录 61 个 .cpp + 37 个 .h 共约 17.5 万行,是 clang 最大的库;
外加 `Targets/` 子目录 25 个架构文件约 1.24 万行,合计 18.7 万。最大的
几个文件:CGBuiltin.cpp(22078)、CGOpenMPRuntime.cpp(12266)、
CGStmtOpenMP.cpp(8219)、CGObjCMac.cpp(7884)、CodeGenModule.cpp(7795)、
CGExpr.cpp(6227)、CGDebugInfo.cpp(6153)、CGCall.cpp(6026)、
CGExprScalar.cpp(5847)、CodeGenFunction.h(5378)。

CMake 上汇成 `clangCodeGen`,链接 6 个 clang 库:clangAST、clangAnalysis、
clangBasic、clangFrontend、clangLex、clangSerialization;LLVM 侧则一口气
链了 Analysis/Coroutines/Coverage/IPO/LTO/ObjCARCOpts/Passes/Target 等
35 个组件(CMakeLists.txt:1-36)——这个不对称本身就是设计声明:**本目录
不只生成 IR,还负责装配整条优化与后端管线**。

公共接口面 `clang/include/clang/CodeGen/` 极窄,只有 9 个头:
BackendUtil.h(后端入口 + BackendAction 枚举)、CGFunctionInfo.h(调用约定
描述 + **ABIArgInfo**——放公共头是因为 Swift/LLDB 也要用)、
CodeGenABITypes.h(LLDB 查询 ABI 布局)、CodeGenAction.h(动作类)、
ConstantInitBuilder.h/ConstantInitFuture.h、ModuleBuilder.h(增量编译入口)、
ObjectFilePCHContainerOperations.h、SwiftCallingConv.h。

目录里的 README.txt(47 行)不是目录说明,而是一份"IRgen optimization
opportunities"备忘:窄整型比较可免 zext/sext、位域宽度 8 且对齐时可直载
整字节、未被取地址的形参/局部可免 alloca(被 -O0 -g 的调试信息依赖卡住)、
纯跳转基本块在 176.gcc:expr.ll 中占 12%+。

按职责分组:

| 组 | 代表文件 | 职责 |
|---|---|---|
| 入口 | CodeGenAction.cpp、BackendConsumer.h、ModuleBuilder.cpp、CodeGenABITypes.cpp | ASTConsumer 协议 → IR 生成 → 后端 |
| 模块层 | CodeGenModule.h/.cpp、CodeGenTypes、CodeGenTBAA、ConstantInitBuilder | 全局值、延迟发射、类型映射、mangling |
| 函数层 | CodeGenFunction.h/.cpp、CGStmt.cpp、CGExpr*.cpp、CGValue.h、CGBuilder.h、CGLoopInfo | 单函数翻译:语句/表达式双分发 |
| 调用/内建 | CGCall.h/.cpp、CGBuiltin.cpp、CGAtomic.cpp、CGNonTrivialStruct.cpp、SwiftCallingConv.cpp、CGPointerAuth | 调用约定、内建函数、原子操作 |
| C++ 语义 | CGDecl.cpp、CGDeclCXX.cpp、CGClass.cpp、CGVTables.cpp、CGVTT.cpp、CGCXX.cpp、CGExprCXX.cpp、CGExprConstant.cpp | 声明初始化、构造/析构、虚表、RTTI |
| 异常 | EHScopeStack.h、CGCleanup.h/.cpp、CGException.cpp | 清理栈、landingpad、personality |
| 语言运行时 | CGObjC*、CGOpenMPRuntime*、CGStmtOpenMP.cpp、CGCUDANV.cpp、CGOpenCLRuntime.cpp、CGHLSLRuntime.cpp、CGBlocks.cpp、CGCoroutine.cpp | 各语言的运行时约定 |
| 观测性 | CGDebugInfo.cpp、CodeGenPGO.cpp、CoverageMappingGen.cpp、MCDCState.h、SanitizerMetadata.cpp、MacroPPCallbacks.cpp | 调试信息、剖析、覆盖率 |
| 后端装配 | BackendUtil.cpp、LinkInModulesPass.cpp、ObjectFilePCHContainerOperations.cpp | PassBuilder 管线、bitcode 链接、PCH 容器 |
| 目标层 | TargetInfo.h/.cpp、ABIInfo.h、ABIInfoImpl.h、Address.h、Targets/ 25 文件 | 目标相关的一切 |

---

## 2. 入口层

### 2.1 CodeGenAction:六个动作,一个枚举

`CodeGenAction`(clang/include/clang/CodeGen/CodeGenAction.h:24)继承
ASTFrontendAction,成员:Act(BackendAction 编号)、TheModule、
LinkModules(`-mlink-builtin-bitcode` 装载的模块)、VMContext + OwnsVMContext
(:46-52),公有指针 `BackendConsumer *BEConsumer`(:88)。

六个子类**全部声明在同一个头文件**(:91-121),构造时各自映射到
BackendUtil.h:35-42 的 `BackendAction` 枚举(CodeGenAction.cpp:1232-1254):

| 动作类 | BackendAction | 对应命令行 |
|---|---|---|
| EmitAssemblyAction | Backend_EmitAssembly | -S |
| EmitBCAction | Backend_EmitBC | -emit-llvm -c |
| EmitLLVMAction | Backend_EmitLL | -emit-llvm |
| EmitLLVMOnlyAction | Backend_EmitNothing | (内存中,clang-repl 用) |
| EmitCodeGenOnlyAction | Backend_EmitMCNull | (跑 CodeGen 不输出) |
| EmitObjAction | Backend_EmitObj | -c / 默认 |

`CreateASTConsumer`(:998-1046)依次:GetOutputStream(按动作选扩展名)→
loadLinkModules(:918-946)→ `-fcoverage-mapping` 时向 Preprocessor 挂
CoverageSourceInfo 回调(:1012-1016)→ `new BackendConsumer`(:1018-1022)→
`-debug-info-macro` 时挂 MacroPPCallbacks(:1027-1033)→ `-gen-reduced-bmi`
时再包一层 MultiplexConsumer。

`ExecuteAction`(:1142-1228)分两条路:普通 C/C++ 输入直接委托
`ASTFrontendAction::ExecuteAction()`(ParseAST 驱动 consumer);**LLVM_IR
输入**(本目录支持 hasIRSupport)则自己 loadModule(:1048,处理 ThinLTO
索引与多模块 bitcode)、造一个"假" BackendConsumer、直接调 EmitBackendOutput。

`EndSourceFileAction`(:950-957)把模块从 consumer 偷到 TheModule,
供 `takeModule()`(:959)取走——EmitLLVMOnlyAction 的生存之道。

### 2.2 BackendConsumer:ASTConsumer 协议的翻译官

`BackendConsumer`(BackendConsumer.h:27)持有关键成员
`std::unique_ptr<CodeGenerator> Gen`(:51,由 `CreateLLVMCodeGen` 创建)、
irgen 计时器(:41-42)、LinkModules 副本(:53)、以及给后端诊断定位用的
ManglingFullSourceLocs(:63-64,mangled name → 源位置)。

正向链路(每个回调都转发给 Gen):

```text
BackendConsumer::HandleTopLevelDecl(CodeGenAction.cpp:187)
  → CodeGeneratorImpl::HandleTopLevelDecl(ModuleBuilder.cpp:181)
    → Builder->EmitTopLevelDecl(每个 Decl)     ← CodeGenModule.cpp:6872
HandleTagDeclDefinition / HandleVTable / CompleteTentativeDefinition
  / HandleInlineFunctionDefinition …(CodeGenAction.cpp:169-389,全转发)
```

收官在 `HandleTranslationUnit`(:266-362):

```text
Gen->HandleTranslationUnit → Builder->Release()        ← TU 定稿(§3.2)
安装 ClangDiagnosticHandler(:292)                      ← LLVM 诊断回译
setupLLVMOptimizationRemarks(:300)
[非 postopt] LinkInModules(:328)                       ← llvm::Linker
ClearASTBeforeBackend(:340)                            ← 插件还要 AST 时跳过
EmbedBitcode / EmitBackendOutput(:354-356)             ← §11
```

诊断回译:`ClangDiagnosticHandler`(CodeGenAction.cpp:65-91)把 LLVM
DiagnosticInfo 交给 `DiagnosticHandlerImpl`(:804-905),按 DK_ 种类分发给
InlineAsm/SrcMgr/StackSize/ResourceLimit/Unsupported/ OptimizationRemark/
MisExpect 等十余个 handler(声明于 BackendConsumer.h:127-161);优化 remark
的源位置由 `getBestLocationFromDebugLoc`(:579)从 debug loc 反查,
`getFunctionSourceLocation`(:621)兜底查 ManglingFullSourceLocs。

### 2.3 ModuleBuilder:增量编译的侧门

`CodeGenerator`(ModuleBuilder.h:52)是"CodeGen 的主公共接口",实现是
文件内私有的 `CodeGeneratorImpl`(ModuleBuilder.cpp:33),暴露
CGM()/GetModule()/ReleaseModule()/GetDeclForMangledName 等。它的独门绝技是
`StartModule`(:136-149):**HandleTranslationUnit 之后再造一个新 Module 并
把惰性发射状态搬过去**(`moveLazyEmissionStates`,CodeGenModule.cpp:7773)。

用户是 `clang::Interpreter`(IncrementalParser.cpp:152 用
EmitLLVMOnlyAction;:365-386 每个 PTU Release + StartModule 换一个模块)，
也就是 clang-repl / -fincremental-extensions。存在的理由(IncrementalParser.cpp
注释):clang CodeGen 假设单 Module,解释器只能每个部分翻译单元换一个。

### 2.4 CodeGenABITypes:给外部工具的 ABI 望远镜

CodeGenABITypes.cpp(129 行)把私有 CodeGenTypes/CGCXXABI 的布局查询
包装成公共 API,头文件注释明说是给 LLDB 用的:arrange* 家族、
convertTypeForMemory、getImplicitCXXConstructorArgs(内部造一个
suppressNewContext 的哑 CodeGenFunction!)、getNonTrivialCStruct* 六件套
(§6.4)、getPointerAuth* 等。头文件在 include/clang/CodeGen/CodeGenABITypes.h。

---

## 3. 模块层:CodeGenModule

`CodeGenModule`(CodeGenModule.h:280,继承 CodeGenTypeCache)是"一个
llvm::Module 的所有者 + 全局值发射机"。头文件 1875 行,值得按成员分组读:

### 3.1 它持有什么(CodeGenModule.h 行号)

```text
配置与上下文   Context :302 / LangOpts :303 / CodeGenOpts :307
              HeaderSearchOpts :305、PreprocessorOpts :306(仅调试信息用)
核心           TheModule(llvm::Module&) :309 / VMContext :313 / Diags :310
               Target :311 / ABI(CGCXXABI) :312 / TheTargetCodeGenInfo :318
协作者         Types(CodeGenTypes) :323 / VTables(CodeGenVTables,值成员) :326
               TBAA :316 / SanitizerMD :604 / CoverageMapping :608
语言运行时     ObjC/OpenCL/OpenMP/CUDA/HLSL Runtime :328-332(惰性创建)
剖析           PGOReader(IndexedInstrProfReader) :336 / PGOStats :337
```

注意:没有 TheDataLayout 成员(`getDataLayout()` 直接取自 TheModule);
没有 TheCXXABI(就叫 `ABI`);IRBuilder 归 CodeGenFunction,不归 CGM。

### 3.2 延迟发射:本目录最重要的机制

全局值不是"见到就发",大量实体**推迟到"确定被用"或"连接性定型"**:

| 状态 | 成员(CodeGenModule.h) | 含义 |
|---|---|---|
| 待用而未发 | DeferredDecls :349(mangled name → GlobalDecl) | 有定义但只在被引用时才发 |
| 已被引用 | DeferredDeclsToEmit :355 | Release 时逐个补发 |
| 增量模式记忆 | EmittedDeferredDecls :362 | -fincremental-extensions 跨 PTU 去重 |
| 虚表 | DeferredVTables :410 / OpportunisticVTables :413 | key function 规则(§7.3) |
| 保活 | LLVMUsed :418 / LLVMCompilerUsed :419 | llvm.used / llvm.compiler.used |
| 构造析构 | GlobalCtors :423 / GlobalDtors :427 | → llvm.global_ctors/dtors |
| 名字缓存 | MangledDeclNames :430 / Manglings :431 | mangling 只算一次 |

判定函数 `MustBeEmitted` / `MayBeEmittedEagerly`(cpp:3501/3518)是分界:
后者为 false 的典型是"连接性还可能变的定义"——如可能随后被显式实例化的
隐式模板实例(ModuleBuilder.cpp:214-222 的注释给出 typedef 内联成员例子)。

发射主链:

```text
EmitTopLevelDecl(h:1186, cpp:6872,Decl 大 switch)
 → EmitGlobal(cpp:3728:别名/IFunc/CPUDispatch 分流;前向声明惰性化)
 → EmitGlobalDefinition(cpp:4115)
     函数: ABI->emitCXXStructor(构析)或 EmitGlobalFunctionDefinition(cpp:5968)
           后者核心一行: CodeGenFunction(*this).GenerateCode(GD, Fn, FI)(:6000)
           虚函数再加 getVTables().EmitThunks(GD)(:4147)
     变量: EmitGlobalVarDefinition(cpp:5387)
```

**每个函数都现场造一个一次性 CodeGenFunction**——CGM/CGF 的两级状态
 division 是全目录的骨架。

`Release()`(cpp:845-1030)是 TU 定稿清单:EmitDeferred(cpp:3170,迭代到
不动点)→ 机会主义虚表 → 替换与多版本 → EmitCXXGlobalInitFunc 等
(§7.2)→ EmitCtorList 进 llvm.global_ctors/dtors(:895-896)→ 注解 →
PGO 模块旗标(:901-902)→ CoverageMapping->emit(:903)→ emitLLVMUsed
(cpp:2988,used 全局进 "llvm.metadata" 段)。调试信息 finalize 也在这
(cpp:1362)。

取用面:`GetOrCreateLLVMFunction`(私有,cpp:4565)/
`GetOrCreateLLVMGlobal`(公有,cpp:4902)、GetAddrOfFunction(cpp:4766)、
GetAddrOfGlobalVar(cpp:5172)、CreateRuntimeFunction(cpp:4849,运行时
libcalls 的正字法入口)、addUsedGlobal/addCompilerUsedGlobal(cpp:2941/:2947)。

### 3.3 常量构造与 TBAA

- **ConstantInitBuilder**(include/clang/CodeGen/ConstantInitBuilder.h:54,
  基类 ConstantInitBuilderBase):"给语言运行时造匿名常量全局"的便利层。
  核心技巧是 SelfReference(:55):先挂一个哑全局,聚合里对它的 GEP 记在案,
  finish 时统一补真。用户遍布 CGBlocks(块描述符)、CGVTables(VTT)、两个
  CXX ABI、ObjC 两个运行时、CUDA/OpenCL/OpenMP/PointerAuth、CGM 自身。
- **CodeGenTBAA**(CodeGenTBAA.h:116):TBAA 别名元数据的唯一来源。
  `TBAAAccessInfo`(h:41:Kind/BaseType/AccessType/Offset/Size)。开关是
  **CodeGenOptions** 而非 LangOptions(CodeGenOptions.def:236-239:
  RelaxedAliasing、PointerTBAA、StructPathTBAA、NewStructPathTBAA)——
  `!StructPathTBAA` 时 getAccessTagInfo 直接丢掉 base type(cpp:543)。
  CGM 构造时的启用条件(cpp:402-406):TSan,**或** 非 -fno-strict-aliasing
  且 O>0。消费端:LValue 携带 TBAAInfo(CGValue.h:238),
  DecorateInstructionWithTBAA(声明 CGM.h:854;消费点 CGExpr.cpp:2003/
  :2147 等)把 !tbaa 挂上 load/store。

---

## 4. 类型与 ABI

### 4.1 CodeGenTypes:AST 类型 → LLVM 类型

`CodeGenTypes`(CodeGenTypes.h:54)核心缓存 TypeCache(:87,
`DenseMap<const Type*, llvm::Type*>`)与 FunctionInfos(:74,
CGFunctionInfo 的 FoldingSet,保证同签名唯一)。

- `ConvertType`(h:117)与 `ConvertTypeForMem`(h:119)是两个入口——
  区别在**寄存器表示 vs 内存表示**(经典例子:_Bool 的寄存器表示是 i1,
  内存通常是 i8/i32);
- `arrange*` 家族(h:211-279:arrangeFreeFunctionCall :211、
  arrangeCXXMethodCall :257、arrangeObjCMessageSendSignature :234、
  arrangeBlockFunctionCall :244…)把 AST 函数类型变成 CGFunctionInfo(§6.1);
- 记录布局:`CGRecordLayout`(CGRecordLayout.h:122,FieldInfo/BitFields
  映射、NonVirtualBases 索引)+ `CGBitFieldInfo`(:65,头文件注释里有
  "位域降成字节数组"的示例)。真正做降层的是 **CGRecordLowering**
  (CGRecordLayoutBuilder.cpp:73)——注意类型名与文件名不一致;它处理
  vfptr/vbptr/基类/位域的排布,输出被 `CodeGenTypes::ComputeRecordLayout`
  (CGRecordLayoutBuilder.cpp:1087)消费。

### 4.2 CGCXXABI:C++ ABI 的抽象面

`CGCXXABI`(CGCXXABI.h:43)持有 MangleCtx(:48,mangling 的真身)。
关键虚函数(行号均在 CGCXXABI.h):分类返回值 classifyReturnType :147、
catch 入口 emitBeginCatch :266、RTTI getAddrOfRTTIDescriptor :272、构析
发射 emitCXXStructor :653 / EmitCXXConstructors :323 / EmitCXXDestructors
:381、构造隐参 getImplicitConstructorArgs :423、虚表族 emitVTableDefinitions
:450 / getAddrOfVTable :475 / getVirtualFunctionPointer :479 /
EmitVirtualDestructorCall :488、thunk 调整 performThisAdjustment :508 /
performReturnAdjustment :513 / EmitReturnFromThunk :517、守卫初始化
EmitGuardedInit :611、全局析构注册 registerGlobalDtor :620、TLS 的
EmitThreadLocalInitFuncs :635、this 指针 LoadVTablePtr :659。

两个实现:ItaniumCXXABI.cpp:46(5230 行,一切非 Windows)与
MicrosoftCXXABI.cpp:45(4521 行)。选择者是**静态自由函数**
createCXXABI(CodeGenModule.cpp:89-107,按 TargetCXXABI 分派),在 CGM
构造函数初始化列表被调用(:342)。易错点:没有名为 EmitConstructorCall
的虚函数——构造调用是 CodeGenFunction::EmitCXXConstructorCall
(CGClass.cpp:2120/:2195)。

### 4.3 TargetCodeGenInfo 与 Targets/

`TargetCodeGenInfo`(TargetInfo.h:47)持有一个 ABIInfo + SwiftABIInfo
(:48-55),虚函数面覆盖目标杂事(均 TargetInfo.h):setTargetAttributes :76、
emitTargetMetadata :81、checkFunctionCallABI :95(调用点 CGCall.cpp:5058)、
EH 相关(getSizeOfUnwindException :109、initDwarfEHRegSizeTable :132)、
内联汇编(adjustInlineAsmType :172)、ARC 标记
getARCRetainAutoreleasedReturnValueMarker :207、地址空间
(getGlobalVarAddressSpace :294、performAddrSpaceCast :311)、OpenCL 块
辅助 :342-354、CUDA 入口约定 :378 等。

`createTargetCodeGenInfo` 是 **CodeGenModule.cpp:110** 的静态函数(不是
TargetInfo.cpp!),按 `Triple.getArch()` switch(:115)调各
`createXTargetCodeGenInfo`——工厂函数在 `Targets/` 的 25 个文件里
(X86.cpp 最大,3459 行)。`ABIInfo` 基类(ABIInfo.h:47)的两个纯虚:
`computeInfo(CGFunctionInfo&)`(:71,参数分类的入口)与
`EmitVAArg`(:80);EmitMSVAArg :89、同质聚合判定 :93-97、多版本
appendAttributeMangling :118;子类 SwiftABIInfo :130 服务 swiftcall。

`Address`(Address.h:128)是"带元素类型的指针":PointerIntPair(非空位
:134)+ ElementType(:137,注释明言是为了让前端断言能抓低级错误)+
Alignment(:141)。这是 LLVM 移除指针元素类型后的前端补偿层。
`RawAddress`(:42)/`ConstantAddress`(:294)是两个变体。

---

## 5. 函数层:CodeGenFunction

`CodeGenFunction`(CodeGenFunction.h:256,继承 CodeGenTypeCache)的头文件
注释即军规:**一次只翻译一个函数**(StartFunction 里的 assert,
CodeGenFunction.cpp:759-760)。

### 5.1 关键成员(CodeGenFunction.h 行号)

```text
协作者      CGM :286 / Target :287 / ParentCGF :290(outlined funclet 指回父)
状态机      Builder(CGBuilderTy) :294 / LoopStack :293 / EHStack :652
            Bypasses(VarBypassDetector) :298 / PGO(CodeGenPGO,值成员) :1613
当前函数    CurFn :355 / CurFnInfo :353 / CurCodeDecl :352 / CurGD :399
返回约定    ReturnBlock :406 / ReturnValue :410 / ReturnValuePointer(sret) :414
            NRVOFlags :650 / RetExpr :418
插入锚点    AllocaInsertPt :429 / PostAllocaInsertPt :434(惰性)
EH 深度     PrologueCleanupDepth :403 / NormalCleanupDest :735 /
            ExceptionSlot :744 / EHSelectorSlot :748
求值辅助    OpaqueValueMapping :1427(GNU ?: 的不透明值绑定)
```

### 5.2 一个函数的一生

```text
GenerateCode(GD, Fn, FnInfo)(cpp:1422-1597)
 ├ BuildFunctionArgList(:1379,this 参数由 CGCXXABI::buildThisParam 补)
 ├ inline-builtin(".inline")克隆处理(:1433-1466)
 ├ [lifetime markers] Bypasses.Init(Body)(:1509)
 ├ StartFunction(...)(cpp:753:消毒器/XRay/PGO 属性 → 入口块 +
 │    AllocaInsertPt(:1096,entry 块 :1090)→ ReturnBlock(:1098)
 │    → ReturnValue(:1174)
 │    → EmitStartEHSpec(:1222)→ PrologueCleanupDepth(:1224)
 │    → EmitFunctionProlog(:1234,定义在 CGCall.cpp:2919))
 ├ PGO.assignRegionCounters(GD, CurFn)(:1527)
 ├ 函数体分发(:1528-1559):析构→EmitDestructorBody(:1528) / 构造→
 │    EmitConstructorBody / CUDA stub / lambda invoker / 缺省赋值 /
 │    其余→EmitFunctionBody(CompoundStmt 直通)
 └ FinishFunction(:365:弹清理到 PrologueCleanupDepth :423 →
      return 块 → epilog → EmitEndEHSpec)
```

### 5.3 语句分发:EmitStmt

`EmitStmt`(CGStmt.cpp:60)先把"简单语句"交给 EmitSimpleStmt(:105-116:
Null/Compound/Decl/Label/Attributed/Goto/Break/Continue/Case…),再大 switch
(:98):IfStmt→EmitIfStmt(:155)、循环节点各自入口(:156-158)、
ReturnStmt(:160)、SwitchStmt(:162)、asm(:163-164)、协程(:165-168)、
CapturedStmt(:171)、ObjC at-try 族(:176-195)、CXXTryStmt→EnterCXXTryStmt
(:198)、**全部 OMP 指令(:207+,实现落 CGStmtOpenMP.cpp)**。文件分工:
CGDecl.cpp 管 DeclStmt(EmitDecl :51)、CGClass.cpp 管构析与方法体、
CGException.cpp 管 try/catch、CGObjC.cpp 管 @synchronized/@autoreleasepool。

### 5.4 表达式:三层求值模型

任何表达式按 `getEvaluationKind`(CodeGenFunction.h:2593)分成三类,
`EmitAnyExpr`(CGExpr.cpp:225-240)是总调度:

```text
TEK_Scalar   → RValue::get(EmitScalarExpr(E))      CGExprScalar.cpp:5496
TEK_Complex  → RValue::getComplex(EmitComplexExpr) CGExprComplex.cpp:1481
TEK_Aggregate→ EmitAggExpr(E, aggSlot).asRValue()  CGExprAgg.cpp:2015
```

左值走 `EmitLValue`(CGExpr.cpp:1503 → EmitLValueHelper :1519 的大 switch:
DeclRef/Member/Subscript/串字面量/位域…)。值模型全在 CGValue.h:
`RValue`(:42,Scalar/Complex/Aggregate 三味 union)、`LValue`(:182,
Simple/VectorElt/BitField/ExtVectorElt/GlobalReg/MatrixElt 六种,
:183-190)、`AggValueSlot`(:504,标签枚举 IsAliased/IsDestructed/IsZeroed/
Overlap/… :563-568)。C++ 专有表达式(new/delete/dynamic_cast/成员指针)
在 CGExprCXX.cpp,常量求值在 CGExprConstant.cpp(§7.5)。

### 5.5 CGBuilder 与循环元数据

`CGBuilderTy`(CGBuilder.h:49)= `IRBuilder<ConstantFolder,
CGBuilderInserter>`;CGBuilderInserter(:29)的 InsertHelper 钩子转发到
`CodeGenFunction::InsertHelper`(CodeGenFunction.cpp:2669)——**全目录唯一
的指令装饰点,只做两件事**:`LoopStack.InsertHelper(I)`(给循环内指令挂
!llvm.loop/访问组)与消毒器作用域内 `I->setNoSanitizeMetadata()`。
CGBuilderTy 自己的增量是带对齐/Address 语义的 API(CreateStructGEP :218、
CreateMemCpy :362、CreateAtomicRMW :167…)。

`CGLoopInfo`:`LoopAttributes`(h:36,向量化/展开/pipeline/CodeAlign 全套
pragma 状态)→ `LoopInfo`(:90,含访问组 AccGroup)→ `LoopInfoStack`
(:204)。循环 push/pop 由 CGStmt.cpp 的循环发射器负责(如 WhileStmt
:1024/:1082),pragma 经 Attrs 数组进入;元数据名
"llvm.loop.parallel_accesses"/"llvm.access.group"(CGLoopInfo.cpp:440/:853)。

---

## 6. 调用与内建

### 6.1 CGCall:调用的装配线

- **CGFunctionInfo**(include/clang/CodeGen/CGFunctionInfo.h:551):trailing
  objects 存参数;位域标志(:560-609)覆盖调用约定/InstanceMethod/
  NoReturn/RegParm…;在 CodeGenTypes::FunctionInfos FoldingSet 里唯一化。
- **ABIArgInfo**(同头文件 :32,**公共头**):Kind 枚举 Direct / Extend /
  Indirect / IndirectAliased / Ignore / Expand / CoerceAndExpand / InAlloca。
- **CallArg**(CGCall.h:229,含 IsUsed 防 IR 重复发射)与 **CallArgList**
  (:274,含 ObjC writeback :278 与清理表 :290)。
- **CGCallee**(CGCall.h:63):SpecialKind = Invalid / Builtin /
  PseudoDestructor / **Virtual**(:64-70)。virtual 形态(:73-87)携带
  CallExpr + GlobalDecl + `this` 的 Address + 函数类型——vtable 槽查找
  因此能推迟到正确的时刻(§7.4);工厂 forVirtual :147。
- `CodeGenFunction::EmitCall`(CGCall.cpp:5011):sret 处理(:5040)→
  always_inline + target 特性检查(:5045)→
  `TargetCodeGenInfo::checkFunctionCallABI`(:5058)→ 参数装载(含
  inalloca 特例)。`EmitCallOrInvoke`(:4865)按 `getInvokeDest()` 决定
  call 还是 invoke(附带 funclet operand bundles)。
- **va_arg**:`EmitVAArg` 在 **CGCall.cpp:6018**(不在 CGExprScalar),一行
  转发 `CGM.getABIInfo().EmitVAArg(...)`(:6025)——每个目标自己的
  va_list 布局。

### 6.2 CGBuiltin:22078 行的巨无霸

入口 `EmitBuiltinExpr`(CGBuiltin.cpp:2541)。目标内建的转发链**全在
本文件内,与 Targets/ 无关**:`EmitTargetBuiltinExpr`(:6321,先看 aux
target 的内建 ID)→ `EmitTargetArchBuiltinExpr`(:6261,按 ArchType
switch)→ EmitX86BuiltinExpr(:14358)、EmitARMBuiltinExpr(:8590)、
EmitSystemZBuiltinExpr(:19332)等 CodeGenFunction 成员。Neon 类型辅助
GetNeonType(:6335)。

### 6.3 CGAtomic / CGNonTrivialStruct / Swift / PointerAuth

- **CGAtomic.cpp**:`AtomicInfo`(cpp:30,成员含 `UseLibcall` :39——
  大小/对齐超出原子指令可寻址范围时置真,退到 `__atomic_*` libcalls);
  `EmitAtomicOp`(:525)把 AtomicExpr 操作码映射成 atomicrmw/cmpxchg
  (CreateAtomicCmpXchg :388)。
- **CGNonTrivialStruct.cpp**:给"非平凡 C 结构"生成具名辅助函数,函数名
  由 `GenFuncNameBase`(:150)逐字段编码操作与易失性(_s 强引用/_w 弱引用/
  v 偏移)。公共出口是 CodeGenABITypes 的 getNonTrivialCStruct* 六件套;
  CGObjC 的属性合成逐成员拷贝也直接调用(cpp:3700/:3798)。
- **SwiftCallingConv.cpp**:swiftcall 的合法性判定(shouldPassIndirectly
  :647、isLegalVectorType :688/:695…),被各目标的 SwiftABIInfo 使用。
- **CGPointerAuth**(arm64e):`CGPointerAuthInfo`(CGPointerAuthInfo.h:24,
  位域 Key/模式/IsaPointer/AuthenticatesNull + Discriminator);schema 的
  "other discrimination" 降层在 getPointerAuthOtherDiscriminator
  (cpp:27,switch Discrimination::None/Type/Decl/Constant),CGM 访问器
  getPointerAuthInfoForPointeeType/ForType(cpp:143/:165);CGCallee 的
  Ordinary 形态就内嵌一个 CGPointerAuthInfo(CGCall.h:75)。

---

## 7. C++ 语义下沉

### 7.1 CGDecl:局部变量的一生

DeclStmt 由 CGStmt.cpp:107 → EmitDeclStmt(:1578)→ 每个 Decl 调
`EmitDecl`(CGDecl.cpp:51)。自动变量的三段式
`EmitAutoVarDecl`(:1348):

```text
EmitAutoVarAlloca(:1444)  alloca + [lifetime.start :1359-1375]
EmitAutoVarInit(:1882)    初始化(常量/聚合/可变长数组各路径)
EmitAutoVarCleanups       挂 EH 清理(非平凡析构/__block/TLS…)
```

- **lifetime 标记的门槛**:`ShouldEmitLifetimeMarkers`(h:2124)之外,
  还要 `!Bypasses.IsBypassed(&D)`(:1592)——goto/switch 跳过声明的变量
  不发 lifetime.start(PR28267 注释 :1579-1591)。VarBypassDetector 就是
  为这一行存在的(§5.1)。
- **-ftrivial-auto-var-init**:`emitZeroOrPatternForAutoVarInit`(:1774)
  按 LangOptions 的 Zero/Pattern 分派;pattern 常量来自自由函数
  `initializationPatternFor`(PatternInit.cpp:15:整型 0xAAAA…/32 位平台
  0xFFFF…,浮点取"负 NaN");填充修正 constWithPadding/replaceUndef
  (:1052/:1323)。没有 PatternInit 类。
- 静态与形参:EmitStaticVarDecl(:418)、EmitParmDecl(:2573)。
- 聚合初始化:**没有** SK_ConstantInitialization 之类的枚举(常见误记);
  CGExprAgg.cpp 是 `AggExprEmitter` StmtVisitor(:43),目标槽语义由
  AggValueSlot 标签表达(§5.4)。

### 7.2 CGDeclCXX:静态初始化与全局构造/析构

- **函数局部静态**:`EmitCXXGuardedInit`(:392)→ `ABI->EmitGuardedInit`。
  Itanium 版(ItaniumCXXABI.cpp:2603):`threadsafe` 判定(:2618-2620,
  LangOpts.ThreadsafeStatics),`__cxa_guard_acquire/release/abort` 三连
  (:2554-2583);MS 版(MicrosoftCXXABI.cpp:2614)没有 guard 变量,靠
  初始化标志 + COMDAT。
- **析构注册**:`EmitDeclDestroy`(:70)→ Itanium 走
  `emitGlobalDtorWithCXAAtExit`(ItaniumCXXABI.cpp:2821:`__cxa_atexit`,
  Darwin TLS 变量 `_tlv_atexit`、其余 `__cxa_thread_atexit`,均传
  `__dso_handle` :2845);`-fno-c++-static-destructors` 在 :77-78 早退;
  CXAAtExit=false 时退到普通 atexit(createAtExitStub :236)。
- **TU 级初始化**:`EmitCXXGlobalVarDeclInitFunc`(:528,初始化器经
  mangleDynamicInitializer :551 命名);无优先级时合并为
  **`_GLOBAL__sub_I_<文件名变形>`**(:935,前由 getTransformedFileName :810
  变形)再 AddGlobalCtor 进 llvm.global_ctors;`init_priority` 属性按
  `std::upper_bound` 分桶 → `_GLOBAL__I_<prio>`(:892,桶逻辑在
  EmitCXXGlobalInitFunc,CGDeclCXX.cpp:838——注意它以 CodeGenModule 成员
  的身份住在 CGDeclCXX.cpp,不在 CodeGenModule.cpp);C++20 命名模块导入
  则用 mangleModuleInitializer(:858)。

### 7.3 CGClass / CGVTables / CGVTT

- **构造**:`EmitConstructorBody`(:840):委托构造短路(:850)、函数 try
  块(:862)、RunCleanupsScope(:867)、`EmitCtorPrologue(Ctor, CtorType,
  Args)`(:877→:1272:虚基先行(:1286)→ 遍历 CD->init_begin()/end()
  (:1278)的成员/基类初始化)。
- **析构**:`EmitDestructorBody`(:1438)按变体分派:Dtor_Deleting →
  EnterDtorCleanups(:1468)后委托调用 complete 变体(:1471);Dtor_Base →
  EnterDtorCleanups(:1517)+ `InitializeVTablePointers`(:1528,带
  `llvm.launder.invariant.group`,受 StrictVTablePointers 且 O>0 门控)。
  `EnterDtorCleanups`(:1845)管 delete 调用与成员/基类/虚基的弹出顺序
  (虚基前向压栈,弹出即逆序 :1901)。**vtordisp 不在这里**——那是
  MicrosoftCXXABI.cpp 的事(:211/:1276/:2242)。
- **虚表**:`isVTableExternal`(CGVTables.cpp:1208)是 key function 规则
  的家(内联 key function / 模板实例化 → 本地;无 key function → 本地;
  未定义 key function → 外部);`getVTableLinkage`(CodeGenModule 成员,
  CGVTables.cpp:1078)在 O>0 时给外部虚表
  AvailableExternallyLinkage(:1113)。`GenerateClassData`
  (:1188)= debug info 补全 + 虚继承表 + `ABI->emitVTableDefinitions`。
  协变返回 thunk:CodeGenVTables::EmitThunks(:625)/maybeEmitThunk(:503)。
  构造虚表是**方法** GenerateConstructionVTable(:919),不是独立类。
- **CGVTT.cpp**:EmitVTTDefinition(:41)、GetAddrOfVTT(:117)。

### 7.4 CGExprCXX:new/delete、成员调用、RTTI

- **new/delete**:`EmitCXXNewExpr`(:1574,分配尺寸含 cookie:
  EmitCXXNewAllocSize :705,`!heapallocsite` 调试元数据 :1672)与
  `EmitCXXDeleteExpr`(:2082:空指针分支、销毁式 delete、数组逐个析构的
  GEP 环 :2118-2140)。分配器是 Sema 解析好的 `E->getOperatorNew()`,
  经正常 mangling 路径调用——没有硬编码的 `__Znwm` 字符串。cookie 尺寸
  `CalculateCookiePadding`(:692)问 ABI(GetArrayCookieSize)。
- **成员调用**:`EmitCXXMemberOrOperatorMemberCallExpr`(:215)在 :406
  构造 `CGCallee::forVirtual(CE, MD, This, Ty)`——虚调用信息在 CGCallee
  里待到 EmitCall 才展开成 vtable 槽载入。
- **RTTI**:`EmitCXXTypeidExpr`(:2182)与 `EmitDynamicCast`(:2233)都在
  CGExprCXX.cpp(不在 CGCXX.cpp!)。dynamic_cast:精确/最终目标走 vptr
  比较(:2310),一般情形 `ABI->emitDynamicCastCall` → Itanium 在
  emitDynamicCastCall(:1618)调 **`__dynamic_cast`**(:1652,fn 声明
  getItaniumDynamicCastFn :1488,带偏移提示与 -1/-2 歧义码);
  引用失败转 `__cxa_bad_cast`。typeid 的多态路径
  EmitTypeidFromVTable(:2146)。
- **lambda**:闭包字面量与捕获的发射机制在 CGBlocks.cpp(复用块字面量
  通路),CGExprCXX 只做表达式接线。
- **CGCXX.cpp 的真身**:只有 Apple Kext 虚调用辅助(:246/:283/:304)——
  文件名有误导性,dynamic_cast/typeid 并不在此。

### 7.5 常量求值:ConstantEmitter

`ConstantEmitter`(ConstantEmitter.h:23)管理"当前是否处于常量上下文"
(InConstantContext :41)与 finalize 时的占位替换。主 visitor
`ConstExprEmitter`(CGExprConstant.cpp:1036)。全局变量定义的常量路径:
`EmitGlobalVarDefinition` 里 `tryEmitForInitializer`(CodeGenModule.cpp:5465)
成功 → 静态初始化;**失败且是 C++ → 先置零 + NeedsGlobalCtor,退到
7.2 的动态初始化**(:5469-5475);C 模式直接 ErrorUnsupported。
`EmitNullConstant`(cpp:2611)负责"全零但类型正确"。

NRVO 决策在 `EmitReturnStmt`(CGStmt.cpp:1467 :1516-1531):
ElideConstructors 且 NRVOCandidate 命中 → 已就地构造,只补
`NRVOFlag` 的 store(:1529)。顺带纠一个常见误记:
`ConstantFoldsToSimpleInteger` 定义在 **CodeGenFunction.cpp:1681/:1702**
(消费点 EmitBranchOnBoolExpr,CodeGenFunction.cpp:1814)。

---

## 8. 异常模型

### 8.1 EHScopeStack:AST 级作用域栈

`EHScopeStack`(EHScopeStack.h:94)是清理与 catch 的栈模型,IR 层的
landingpad **惰性生成**。关键构件:

- `stable_iterator`(:101,偏移式,压栈后不失效);
- `Cleanup`(:141,虚 Emit(CGF, Flags);Flags 区分 normal/EH 边、
  是否需要 exit switch);
- `ConditionalCleanup`(:203):参数经 `DominatingValue<T>` 保存,使清理
  能在"原 SSA 值不支配的 EH 边"上恢复后重发——语句表达式的核心难题;
- pushCleanup(:285)/pushCatch(:337)/pushFilter(:343)。

CGCleanup.h 定义具体作用域:`EHCleanupScope`(:243,条件清理机制 =
ActiveFlag i1 alloca,:256/:381-394)、EHCatchScope(:158)、
EHFilterScope(:501)、EHTerminateScope(:543)。激活控制是
CodeGenFunction 的 `ActivateCleanupBlock`/`DeactivateCleanupBlock`
(CGCleanup.cpp:1263/:1275);RAII 家族:RunCleanupsScope(h:966)、
LexicalScope(:1026)、CleanupDeactivationScope(:671)。

### 8.2 landingpad、throw 与 personality

- `getInvokeDestImpl`(CGException.cpp:775):按当前栈状态缓存/新建
  landingpad 块,并给 CurFn 挂 personality(:802,`setPersonalityFn` 的
  入口);funclet 系(MSVC/wasm)改走 getEHDispatchBlock(:807)。
- `EmitLandingPad`(:825):`CreateLandingPad({i8*, i32})`(:851),异常
  指针与 selector 存入 exn.slot/ehselector.slot(:423/:431),按栈上
  catch/filter 项累积子句。
- **throw**:`EmitCXXThrowExpr`(:443)→ ObjC 指针交给 ObjC 运行时,
  否则 `ABI->emitThrow`(Itanium 实现 :1446)→ **`__cxa_throw`**
  (getThrowFn :1435;`__cxa_allocate_exception` :1427)。
- **personality 表**(CGException.cpp:97-130 的 EHPersonality 常量表):
  `__gxx_personality_v0`(GNU C++,默认)、`__CxxFrameHandler3`(MSVC C++)、
  `_except_handler3`(x86 SEH)/`__C_specific_handler`(其余 SEH)、
  `__gxx_wasm_personality_v0`、`__xlcxx_personality_v1`(AIX)、
  `__zos_cxx_personality_v2`、ObjC/ObjC++ 各自的
  `__objc_personality_v0`/`__gnustep_objcxx_personality_v0`。选择集中在
  `EHPersonality::get`(:237-261);`SimplifyPersonality`(:336)可把
  只用 C++ 特性的 ObjC++ 函数降级成 C++ personality。
- **noexcept**:`EHStack.pushTerminate`(:536);terminate 函数由
  `getTerminateFn`(:63)选择:`_ZSt9terminatev`/MSVC `__std_terminate`/
  ObjC++ `objc_terminate`/非 C++ `__terminate`(**没有**
  `__cxa_call_terminate` 这个符号)。
- **SEH**:EmitSEHTryStmt(:1662);__except 过滤器(:2080)与 __finally
  (:2097)都是**outlined 函数**(startOutlinedSEHHelper :2015 开新 CGF)。
- 顺带:`llvm.eh.typeid.for` 用于 catch 匹配(:1140);begin/end_catch
  经 ABI 的 emitBeginCatch(Itanium 发 __cxa_begin_catch/__cxa_end_catch)。

---

## 9. 语言运行时

### 9.1 Objective-C

`CGObjCRuntime`(CGObjCRuntime.h:65)抽象关键虚函数:GenerateMessageSend
(:167,纯虚)/ GenerateMessageSendSuper(:198)/ GetSelector(:129)/
GetClass(:272)/ EmitSynchronizedStmt(:284)/ EmitTryStmt(:286)。
`EmitObjCMessageExpr`(CGObjC.cpp:573)计算 receiver/参数后分派给运行时
(头注释:两个运行时只差查找机制与前两个实参)。

macOS/iOS 实现(CGObjCMac.cpp)是三层:`CGObjCCommonMac`(:771)→
`CGObjCMac`(:1216,旧 fragile ABI)/ `CGObjCNonFragileABIMac`(:1401,
现代)。最终发送函数按返回类型四选一:objc_msgSend / _stret / _fpret /
_fp2ret(EmitMessageSend :2131 → getSendFn2/getSendFn 选择 :2190-2191,
均加 non-lazy-bind)。
GNU 侧:CGObjCGNU(:94)+ GCC/GNUstep/GNUstep2 变体(CGObjCGNU.cpp)。

### 9.2 OpenMP(目录里最大的语言板块)

`CGOpenMPRuntime`(CGOpenMPRuntime.h:229)关键虚函数族:emitParallelCall
(:799)、emitSingleRegion(:847)、emitTaskCall(:1146)、
emitOutlinedFunctionCall(:1544)。**成员里有一个 `llvm::OpenMPIRBuilder`**
(:312)——前端直接复用 LLVM 侧的 OpenMP IR 构建器(如
`OMPBuilder.getOrCreateRuntimeFunction(M, OMPRTL___kmpc_fork_call)`,
CGOpenMPRuntime.cpp:1890)。

- parallel 的样子:`emitParallelCall`(cpp:1868)发
  `__kmpc_fork_call(loc, n, microtask, 捕获…)`;
- outlined 函数:`GenerateOpenMPCapturedStmtFunction`
  (CGStmtOpenMP.cpp:638,基于 CapturedStmt 机制);
- 指令分发:EmitStmt 的 OMP case 族(CGStmt.cpp:207+)全部落
  CGStmtOpenMP.cpp;
- **kmpc_* 符号表在 LLVM 侧**:omp::RuntimeFunction 枚举
  (llvm/include/llvm/Frontend/OpenMP/OMPConstants.h:45)由 OMPKinds.def 的
  `__OMP_RTL` 宏展开(**191 个条目**),clang 只消费 OMPRTL_* 别名;
- GPU offload:`CGOpenMPRuntimeGPU`(CGOpenMPRuntimeGPU.h:24)继承并重写
  emitParallelCall(:1747)等。

### 9.3 CUDA / OpenCL / HLSL

- **CUDA**:`CreateNVCUDARuntime`(CGCUDANV.cpp:1013)。设备全局注册流:
  `__cuda_register_globals`(:534)逐个发
  `__cudaRegisterFunction/__cudaRegisterVar`(:566-568);fatbin 嵌入段名
  macOS `__NV_CUDA,__fatbin`、其余 `.nvFatBinSegment`(:794,HIP 则
  `.hipFatBinSegment` :759);模块构造函数走
  `__cudaRegisterFatBinary`(:719,HIP 前缀变 `__hip`)。
  (**没有** `__cuda_register_kernel` 这种符号。)
- **OpenCL**:CGOpenCLRuntime(h:36)管 pipe 等 IR 类型与地址空间细节。
- **HLSL**:CGHLSLRuntime(h:69),入口 `finishCodeGen()`(:118)与
  `emitEntryFunction`(:122,入口包装与 dx.shader 全局);惰性创建于 CGM。

### 9.4 Blocks 与协程

- **Blocks**(CGBlocks.cpp):`CGBlockInfo`(CGBlocks.h:156)描述块布局;
  `EmitBlockLiteral`(cpp:767)造块字面量;__block 变量走 byref 结构
  (BlockByrefFlags h:38、BlockFieldFlag_t h:87-97:IS_OBJECT=0x03/
  IS_BLOCK=0x07/IS_BYREF=0x08/IS_WEAK=0x10/IS_ARC=0x40),复制/释放调
  `_Block_object_assign`(:1629/:1649)/`_Block_object_dispose`。
- **协程**(CGCoroutine.cpp):`CGCoroData`(:31,coro.id token、
  coro.frame、coro.free);"suspend 处 switch i8 跳 epilogue"的惯用法
  (注释 :209);coro.end/coro.delete 的收尾是 **EHScopeStack::Cleanup**
  (CallCoroEnd :570 / CallCoroDelete :596)——协程正确收尾天然长在
  清理栈里。入口 EmitCoroutineBody(:776)。

---

## 10. 观测性

### 10.1 CGDebugInfo(6153 行)

- **生命周期**:构造即 CreateCompileUnit(cpp:82-87);**CGM 构造时就
  eager 创建**(CodeGenModule.cpp:413,条件 :408-412:开调试信息或有
  coverage 文件)——不是惰性;finalize(:6006-6080,内部调
  DBuilder.finalize :6079)由 Release() 触发(cpp:1362)。
- **策略要点**:clang 只发 **llvm.dbg.declare**(DIBuilder::insertDeclare)
  与 dbg.label;唯一发 **dbg.value** 的地方是
  `-fdebug-info-for-profiling` 的伪变量(EmitPseudoVariable :5780,
  调用点 CGExprScalar.cpp:1962)。局部变量的单一咽喉是私有 EmitDeclare
  (:4746-4924),两个公开包装 EmitDeclareOfAutoVariable /
  EmitDeclareOfArgVariable(CGDecl.cpp:1680/:2749 调用)。
- **函数与位置**:emitFunctionStart(:4366,小写 e;StartFunction 调用
  CodeGenFunction.cpp:1116)、EmitLocation(:4593)、作用域栈
  LexicalBlockStack(h:144)+ RegionMap(h:145)。
- **类型**:getOrCreateType(:3676)→ CreateTypeNode(:3737)→ 一族
  CreateType 重载;缓存是 DenseMap<TypeCache>(h:92,按 QualType 指针);
  RetainedTypes(h:133)经 retainType 防止被优化掉。
- **模块级**:CreateCompileUnit(:524-671)把
  codegenoptions::DebugInfoKind(枚举在 llvm/include/llvm/Frontend/Debug/
  Options.h)映射到 DICompileUnit 的 emission kind(:613-631);DwarfVersion
  → 模块旗标 "Dwarf Version"(CodeGenModule.cpp:998);SplitDwarf 的
  skeleton CU 给 clang modules 用(getOrCreateModuleRef :2980,skeleton
  CU :3037);-gmodules 的声明归属 getParentModuleOrNull(:3702)。

### 10.2 CodeGenPGO 与覆盖率

`CodeGenPGO`(CodeGenPGO.h:29)是 **CodeGenFunction 的值成员**(h:1613),
per-function 状态:

- `assignRegionCounters`(cpp:1013)起手:setFuncName(:38,内部
  **createPGOFuncNameVar :47 只造 `__profn_` 名字变量**)→
  mapRegionCounters(:1064:MapRegionCounters RASTVisitor,
  struct 定义 :159,给函数体/标号/循环/if/逻辑右值分配计数器;
  PGOHash 每 AST 节点 6 位 MD5,NumBitsPerType=6 :83;MC/DC 状态收集,
  默认最大条件数 6,:1074-1085);
- 计数更新走 intrinsic:`emitCounterSetOrIncrement`(:1191)发
  llvm.intrprof_increment / _step / cover;MC/DC 有专属 intrinsics
  (instrprof_mcdc_parameters / tvbitmap_update,:1221-1270);
- **`__profc_`/`__profd_` 计数全局与 `__llvm_prf_*` 段不在前端落地**——
  由后端 `InstrProfilingLoweringPass` 完成(挂在 BackendUtil.cpp:1015);
- 使用侧:`-fprofile-instr-use` 时 CGM 持有 `llvm::IndexedInstrProfReader`
  (CodeGenModule.h:336,构造 :420-428;**没有** PGOProfileReader 类);
  loadRegionCounts(:1407)取记录,缺失/哈希不匹配计入 PGOStats;
  createProfileWeights(:1453-1500)把区域计数变分支权重;间接调用的
  value profiling 在 CGCall.cpp:5730。
- **覆盖率**分工:CodeGenPGO 管计数与映射编排
  (emitCounterRegionMapping :1126);CoverageMappingGen.cpp 管映射记录
  (CounterCoverageMappingBuilder :884,ConstStmtVisitor);模块级
  `CoverageMappingModuleGen`(h:105)的 addFunctionMappingRecord
  (cpp:2491)把每函数记录写成 `__covrec_*` 全局进 `__llvm_covfun` 段,
  emit()(:2525)写 TU 级 **`__llvm_coverage_mapping`** 进 `__llvm_covmap`
  段;skipped 区间由 CoverageSourceInfo(h:67,PPCallbacks+
  CommentHandler+EmptylineHandler)从预处理器收集。

### 10.3 SanitizerMetadata 与 MacroPPCallbacks

- `SanitizerMetadata`(SanitizerMetadata.h:32):只服务 ASan/HWASan/MemTag
  (:25-28);**不是**发 !sanitize 元数据节点,而是填
  `llvm::GlobalValue::SanitizerMetadata` 结构体(NoAddress/NoHWAddress/
  Memtag/IsDynBit,GlobalValue.h:317-353)并 GV->setSanitizerMetadata
  (cpp:75)——让 IR 变换(GlobalMerge 等)之后消毒器 pass 仍能识别。
  挂接点:GetAddrOfGlobalVar(CodeGenModule.cpp:5084)、
  EmitGlobalVarDefinition(:5644,IsDynInit=NeedsGlobalCtor)、串字面量
  (:6534);内部辅助全局经 disableSanitizerForGlobal 主动退出
  (CGExpr.cpp:3341 等)。
- MacroPPCallbacks(199 行):`-debug-info-macro` 时挂在 Preprocessor 上
  (CodeGenAction.cpp:1027-1033),把宏定义/取消转成 DW_MACINFO_define/
  undef——**它属于调试信息,与覆盖率无关**(覆盖率的 PP 钩子是
  CoverageSourceInfo)。

---

## 11. 后端装配

### 11.1 BackendUtil:双管线

`clang::EmitBackendOutput`(BackendUtil.h:44-50 声明,BackendUtil.cpp:1293
定义;第一个选项参数是 HeaderSearchOptions,TDesc 是 DataLayout 串):

```text
EmitBackendOutput
 ├ ThinLTO? → getModuleSummaryIndexForFile(:1308) → runThinLTOBackend
 │            (:1188,lto::Config + llvm::lto::thinBackend :1283)
 └ 否则 → EmitAssemblyHelper(ctor :209)
          ├ setCommandLineOpts(:525,LLVM cl 选项)
          ├ CreateTargetMachine(:549,TargetRegistry::lookupTarget
          │   → createTargetMachine :573)
          ├ 模块 DataLayout 取自 TM(:1173)
          ├ RunOptimizationPipeline(:775-1116,新 PM)
          └ RunCodegenPipeline(:1118-1159,仍 legacy PM,FIXME :1121)
最后:模块 DataLayout 与 clang TargetInfo 的串比对(:1343-1353)
```

RunOptimizationPipeline 的装配顺序:PGOOptions(-fprofile-generate/use/
sample,:780-846 → `TM->setPGOOption`)→ PipelineTuningOptions(:848-859)
→ `PassBuilder PB(TM, PTO, PGOOpt, &PIC)`(:876)→ 扩展点回调(assignment
tracking :881、ObjC ARC :957-974、KCFI :637-660、sanitizers/sancov :662+、
内存剖析 :1020-1026、**pass 插件** CodeGenOpts.PassPlugins :916-929)→
管线选择(:1028-1038:FatLTO/ThinLTOPreLink/LTOPreLink/PerModule 四种
build*DefaultPipeline,**没有** parsePassPipeline)→
`LinkBitcodePostopt` 时插 LinkInModulesPass(:1043)→ 输出 pass
(bitcode/print,:1053-1093)+ 前后 Verifier(:946/:1050)。

RunCodegenPipeline 还是旧 PM:AddEmitPasses(:578)加
TargetLibraryInfoWrapperPass、O>0 时的 ObjCARCContract(:594)与
`TM->addPassesToEmitFile`(:597)。另有两个嵌入式帮手:EmbedBitcode
(:1358,-fembed-bitcode)与 EmbedObject(:1368,.llvm.offloading 段)。

### 11.2 LinkInModulesPass 与 PCH 容器

- **LinkInModulesPass**(LinkInModulesPass.h:29):新 PM PassInfoMixin
  (头文件里"legacy PM"的注释已过时),唯一成员是 BackendConsumer*,
  run() 调 `BC->LinkInModules(&M)`(:29)——真正的链接在
  BackendConsumer::LinkInModules(CodeGenAction.cpp:230-264)里,用
  `llvm::Linker::linkModules`(:248-256,可选 internalize 回调)。触发:
  `-mlink-builtin-bitcode` 收集 + `-mlink-builtin-bitcode-postopt`
  延迟到优化后;不开 postopt 就在 HandleTranslationUnit 里提前链(:328)。
- **ObjectFilePCHContainerOperations**(396 行):`PCHContainerGenerator`
  (:42,匿名命名空间的 ASTConsumer)居然**借一个真的 CodeGenModule 来
  给 PCM 生成调试信息**(DebugTypeVisitor :61 遍历声明);序列化的 AST
  字节装进名为 `__clang_ast` 的全局(:306),分节名按格式:
  Mach-O `__CLANG,__clangast`(:312)/ COFF `clangast`(8 字符限制,:315)/
  ELF `__clangast`(:317);Wasm 走 "wasm.custom_sections" 命名元数据
  (:284-297)。最后仍调 EmitBackendOutput 出 .o。Reader 的 ExtractPCH
  (:361)用 llvm::object::ObjectFile 按段名找回来,非目标文件则当 raw
  AST 兜底(getFormats 返回 {"obj","raw"})。这就是 Frontend 篇里
  cc1_main 注册的那个 PCH 容器格式。

---

## 12. 设计取舍与不变量

1. **两级状态,CGF 用后即弃**。CGM 管跨函数(全局值、mangling、类型、
   运行时),CGF 管单函数;`EmitGlobalFunctionDefinition` 每函数现造一个
   CodeGenFunction(CodeGenModule.cpp:6000)。理解任何文件先问:它主要
   碰哪一级?
2. **延迟发射是默认而非优化**。连接性未定的实体(模板隐式实例化、内联
   key function 的虚表)等"被引用"或"Release"才定形;增量模式再用
   EmittedDeferredDecls 跨 PTU 记账。改 CGM 的发射顺序前先想清楚谁可能
   还在 DeferredDecls 里。
3. **指令装饰单点化**。循环元数据与消毒器豁免全部过
   CodeGenFunction::InsertHelper(cpp:2669)——IRBuilder 的自定义插入器
   是唯一的横切点,这样新指令种类不会漏挂元数据。
4. **ABI 三层 + 一处 switch**:ABIArgInfo(参数分类)→ ABIInfo(目标
   规则,computeInfo)→ TargetCodeGenInfo(目标杂项);CXX ABI 平行一套
   (CGCXXABI)。注意 CGBuiltin 的目标分发是**独立的 ArchType switch**
   (CGBuiltin.cpp:6261),与 Targets/ 无关——两条目标分发线并存是历史
   结果,读代码时别混。
5. **公共面极窄**。9 个公共头;ABIArgInfo/CGFunctionInfo 放公共头是因为
   Swift/LLDB 消费同一布局规则(CodeGenABITypes)。
6. **三层求值对应 LLVM 的"没有聚合值"**。scalar/complex/agg 的分派
   (EmitAnyExpr)贯穿所有表达式文件;AggValueSlot 的标签位把"可否别名/
   是否要析构/是否清零"等调用上下文随槽传递,避免二次分析。
7. **EH 是 AST 级模型 + 惰性 IR**。EHScopeStack 记住"逻辑上该做什么",
   landingpad/cleanup 只在控制流真的离开时生成;conditional cleanup 用
   活跃旗标 + DominatingValue 解决"值不支配 EH 边"。personality 选择
   收敛在 EHPersonality::get 一处。
8. **剖析走 intrinsic 而非直接全局**。前端只发 llvm.instrprof_* 与
   __profn_ 名字变量,计数全局由后端 pass 落地——LTO 下 instrumentation
   才能被统一优化/裁剪。
9. **诊断与位置双向翻译**。BackendConsumer 把后端 remark/诊断译回 clang
   诊断(getBestLocationFromDebugLoc + ManglingFullSourceLocs 兜底),
   PCH 容器反向把 PCM 的调试信息借 CGM 生成——同一套 CodeGen 两种宿主。
10. 不变量举例:CodeGenFunction 一次一函数(StartFunction assert);
    EmitLLVMOnlyAction 不写盘,靠 takeModule 交接;TBAA 只在
    (TSan 或 O>0 且未关严格别名)时存在;`__profc_` 全局永不由前端创建。

---

## 13. 速查表

**入口链**:

```text
-emit-obj → EmitObjAction(CodeGenAction.h:121)
 → BackendConsumer(CodeGenAction.cpp:1018)
 → ParseAST 逐 Decl → HandleTopLevelDecl(:187)
    → CodeGeneratorImpl(ModuleBuilder.cpp:181)
    → CodeGenModule::EmitTopLevelDecl(CodeGenModule.cpp:6872)
 → HandleTranslationUnit(:266)
    → Gen->Release(CodeGenModule.cpp:845)
    → EmitBackendOutput(BackendUtil.cpp:1293)
```

**文件 → 看点**:

| 想懂什么 | 看哪里 |
|---|---|
| 一个全局函数怎么变成 IR | CodeGenModule.cpp:5968 EmitGlobalFunctionDefinition → CGF::GenerateCode |
| 延迟发射/连接性判定 | CodeGenModule.h:345-381 注释 + cpp:3501/3518 |
| AST 类型怎么映射 LLVM 类型 | CodeGenTypes.h:117-123 + CGRecordLayoutBuilder.cpp:73 |
| 调用约定怎么定 | CGFunctionInfo.h:551 + ABIArgInfo(同文件 :32)+ ABIInfo.h:71 |
| 内建函数(含 NEON/X86 intrinsics) | CGBuiltin.cpp:2541 入口,:6261 架构 switch |
| 构造/析构/虚表 | CGClass.cpp:840/:1272/:1438 + CGVTables.cpp:1208 key function |
| throw/catch 的 IR 形态 | CGException.cpp:775/:825 + EHScopeStack.h |
| 局部静态的线程安全初始化 | ItaniumCXXABI.cpp:2603(__cxa_guard_*) |
| new/delete 与数组 cookie | CGExprCXX.cpp:1574/:2082 |
| 常量初始化何时退化为动态 | CodeGenModule.cpp:5465-5475 + ConstantEmitter.h:23 |
| 块(lambda 底座) | CGBlocks.cpp:767 EmitBlockLiteral |
| OpenMP outlined 函数 | CGStmtOpenMP.cpp:638 + CGOpenMPRuntime.cpp:1868 |
| -g 调试信息从哪冒出来 | CGDebugInfo.cpp:4366/:4593/:4746 |
| -fprofile-instr-generate 发了什么 | CodeGenPGO.cpp:1013/:1191(intrinsics) |
| 覆盖率映射记录格式 | CoverageMappingGen.cpp:2491/:2525 |
| 优化管线在哪拼起来 | BackendUtil.cpp:775 RunOptimizationPipeline |
| PCH 装进 .o 的段名 | ObjectFilePCHContainerOperations.cpp:306(global)+ :312-317(分节) |
| clang-repl 怎么换模块 | ModuleBuilder.cpp:136 StartModule |

**典型调用链**(普通函数体):

```text
CGF::GenerateCode → StartFunction(EmitFunctionProlog, CGCall.cpp:2919)
 → EmitFunctionBody → EmitStmt(CGStmt.cpp:60)
    → EmitIfStmt(:795)→ EmitBranchOnBoolExpr(CodeGenFunction.cpp:1814)
       → EmitScalarExpr(CGExprScalar.cpp:5496) → Builder.CreateICmp…
    → 涉及调用: EmitCalleeCall → EmitCall(CGCall.cpp:5011)
       → CGCallee(virtual? forVirtual 在 vtable 载槽)→ CreateCall/Invoke
    → 涉及清理: EHStack.pushCleanup → 离开作用域 PopCleanupBlocks
 → FinishFunction → 返回块汇合 → NRVOFlag store
```

**与兄弟目录的边界**:Frontend 决定**何时**调 CodeGen(BackendConsumer
是它手里的 ASTConsumer);Sema/AST 提供类型与语义裁定;clangEdit/Basic
提供基础设施;LLVM 侧提供 IR、PassBuilder、OpenMPIRBuilder、InstrProf
lowering——本目录是"AST 语义 → LLVM 约定"的词典编纂者,外加管线装配
员。目标相关的一切集中在 Targets/ 与 TargetInfo/ABIInfo/CGBuiltin 的
switch 里,C++ ABI 集中在 Itanium/Microsoft 两个实现里,语言运行时各自
一个 CG*Runtime——**这是读 17 万行代码的地图**。

| 姊妹篇 | 《Clang Frontend 详细设计文档》(BackendConsumer 的上游)/
《Clang 基础设施详细设计文档》(ASTContext/诊断)/
《Clang Lex 详细设计文档》(宏与预处理) |
|---|---|
