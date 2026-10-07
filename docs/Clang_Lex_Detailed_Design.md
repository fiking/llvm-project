# Clang Lex(预处理器)详细设计文档

> 基础设施系列第五篇,深入 `clang/lib/Lex/`:Lexer 状态机、Preprocessor
> 协程式调度、宏展开(对象式/函数式/可变参数/__VA_OPT__)、#include 解析
> 与 HeaderSearch、条件编译栈、PPCallbacks 观察者、模块子集。所有类名、
> 成员、调用链均对照本仓库代码核实。

---

## 目录

1. [总览:三组件与一条不变式](#1-总览)
2. [Lexer:手写状态机](#2-lexer)
3. [Preprocessor:调度核心与三态 lexer 栈](#3-preprocessor)
4. [Token 回溯与缓存](#4-token-回溯与缓存)
5. [Directive 处理(PPDirectives)](#5-directive-处理)
6. [宏:定义、参数与展开](#6-宏)
7. [#include 与 HeaderSearch](#7-include-与-headersearch)
8. [条件编译与 #line](#8-条件编译与-line)
9. [PPCallbacks 与 PreprocessingRecord](#9-ppcallbacks)
10. [模块相关(ModuleMap / dependency scanning)](#10-模块相关)
11. [设计取舍与不变量](#11-设计取舍与不变量)
12. [速查表](#12-速查表)

---

## 1. 总览

Lex 层由三个协作组件构成,产出 Token 流供 Parse 消费:

```text
源文件 buffer
   │
   ▼
Lexer ──── 纯状态机:字符 → Token(不认识任何 directive)
   ▲                     │
   │                     │ "#"-开头的 token 交回
Preprocessor ── 总控与调度:
   │  · 持有 CurLexer / CurTokenLexer(宏回放),单选一(不变式)
   │  · directive 分发(PPDirectives.cpp)
   │  · 宏表(IdentifierInfo → MacroInfo)与展开(PPMacroExpansion.cpp)
   │  · 条件编译栈、include 栈(IncludeMacroStack)
   │  · PPCallbacks 观察者
   ▼
Token 流(经 CachingLexer 缓存 / Backtrack 回退)→ Parser
```

**核心不变式(Preprocessor.h:752, 770 注释原文)**:`CurLexer` 与
`CurTokenLexer` **恰好一个非空**(或都空,如纯宏展开嵌套边缘情况);
`CurLexerCallback` 枚举(CLK_Lexer / CLK_TokenLexer / CLK_CachingLexer,
Preprocessor.h:3026-3032)记录当前"下一个 token 从哪来",Lex 的主入口
`Preprocessor::Lex` 就是按它分派。这是理解整个 Lex 层的钥匙:**预处理器
本质是一个"当前 token 源"的栈机,include 和宏展开都是压栈/退栈**。

其余支撑组件:

| 组件 | 文件 | 职责 |
|---|---|---|
| MacroInfo / MacroArgs | MacroInfo.h | 宏定义与实参缓存 |
| TokenLexer | TokenLexer.h/.cpp | 宏体 token 序列的"回放器" |
| HeaderSearch / HeaderMap | HeaderSearch.h/.cpp, HeaderMap.cpp | include 搜索路径与 hmap |
| ModuleMap | ModuleMap.cpp | module map 语法解析与 module 结构 |
| ScratchBuffer | ScratchBuffer.cpp | 构造 _Pragma 等虚拟 token 的临时缓冲 |
| PreprocessingRecord | PreprocessingRecord.h/.cpp | PP 动作历史(供 libclang/索引) |
| PPCallbacks | PPCallbacks.h | 观察者接口 |
| PPCaching / TokenConcatenation 等辅助 | PP*.cpp | 诊断、token 粘连检查 |

---

## 2. Lexer

`clang/include/clang/Lex/Lexer.h` + `clang/lib/Lex/Lexer.cpp`。手写
扫描器,**每次调用 Lex() 产出恰好一个 Token**,不缓冲整个文件。

### 2.1 输入与锚点

- 构造时绑定 `MemoryBuffer`(经 FileManager/VFS 读入)+ 起始
  SourceLocation。Lexer 直接持有 `BufferStart/BufferEnd` 指针,字符位置
  与 SourceLocation 是一一映射(`getLocForStartOfFile` 换算)
- **不拥有 buffer 生命周期**,只持指针——生命周期归 SourceManager

### 2.2 状态标志(Lexer.h:109 附近)

| 标志 | 语义 |
|---|---|
| `LexingFromFileStart` | 从文件头开始(main file 专属初始化) |
| `Is_PragmaLexer` | `_Pragma` 展开产物:行首/末语义特殊 |
| `LexingRawMode` | 原始模式:`#if 0` 跳过区、predefines buffer 等场景,directive 不解释,整块吞掉 |
| `PreprocessorOptions` 相关 | 禁注释/保留注释等由 PP 透传 |

`EnterRawMode()` / `ResetRawMode()`(带断言,Lexer.h:237-255)成对使用;
典型场景:条件编译的 skipped 区间进入 raw 模式,只追踪嵌套 `#if/#endif`。

### 2.3 扫描循环要点

`Lex()` → `LexTokenInternal()`(手写 switch,按首字符分发):

- 标识符/关键字:`LexIdentifier`,查 `IdentifierTable`(interning 见
  基础设施篇 §3),keyword 与否在表里就有答案
- 数字/字符串/字符:`LiteralSupport.cpp` 处理(进制、UDL 后缀、
  字符串拼接发生在 PP 层,单 lexer 只出一个 token)
- 注释:`//` 直接跳;`/* */` 换行计数(诊断需要正确行列);注释里的
  `// \` 续行、doxygen 标记都是普通文本
- 换行与空格:产出的 Token 带 flags(`LeadingSpace`/`StartOfLine`),
  宏展开后的重拼(粘贴空格)依赖这两个 bit——这是 C 标准里
  "字符串化保留空格"语义的基石
- `#` 在行首(StartOfLine 且前无 token):PP 命中 `HandleDirective`
  (PPDirectives.cpp:1199)
- Unicode:`UnicodeCharSets.h` + UCN/UTF 处理,标识符按
  C11/C++11 扩展字符集

### 2.4 与 token 产出的契约

- Token 的 `Length` 是**字节长度**;`PtrData` 指向 `StringMapEntry`
  (identifier)或字面量数据
- Lexer 不做任何语义判断:关键字识别交给 IdentifierTable,宏展开交给
  PP——`#define int float` 在 lexer 眼里与普通 define 无异

---

## 3. Preprocessor:调度核心

`clang/include/clang/Lex/Preprocessor.h:137` + PPDirectives.cpp /
PPMacroExpansion.cpp 等(按功能拆分的 .cpp)。

### 3.1 三态当前源(CurLexerCallback)

```cpp
// Preprocessor.h:3026 起
static bool CLK_Lexer(Preprocessor &P, Token &Result);        // 真文件
static bool CLK_TokenLexer(Preprocessor &P, Token &Result);   // 宏回放
static bool CLK_CachingLexer(Preprocessor &P, Token &Result); // 缓存回放
```

`Lex()` 的简化逻辑:循环按 `CurLexerCallback` 取 token;若取到
"直接来自文件且是 identifier 且有宏",走展开路径(§6);否则按
PP 层修饰(保留注释、诊断)后返回。**这个间接层让"下一个 token 来自
文件还是宏回放还是缓存"对上层完全透明**。

### 3.2 include/宏 栈:IncludeMacroStack

进入 include 或宏展开时,当前 (CurLexerCallback, CurLexer,
CurTokenLexer, CurDirLookup…) 整体压入 `IncludeMacroStack`
(Preprocessor.h:2472-2481);对应动作结束退栈恢复。栈深即嵌套深度,
诊断里的 "in file included from …" 链即沿此栈回溯(SourceManager 的
expansion 信息与之配合)。

`EnterSourceFile`(Preprocessor.h:1662)是 include 入口的统一入口:
建 Lexer、发 FileChanged 回调、重置条件栈状态。

### 3.3 PP 的全局资源

- **宏表**:`IdentifierInfo → MacroInfo*` 映射,挂在每个
  IdentifierInfo 上(`hasMacroDefinition`);builtin 宏(`__LINE__`、
  `__FILE__`、`__COUNTER__`…)用 `isBuiltinMacro`(MacroInfo.h:217)
  标记,展开走特设路径而非 token 回放
- **条件栈**:`std::vector<PPConditionalDirectiveRecord>` 式的
  分层记录(见 PPConditionalDirectiveRecord.cpp),#if/#elif/#else/#endif
  的真假与"已见过真分支"状态
- **predefines buffer**:编译器内置宏(`__clang_major__` 等)以一段
  虚拟源码(`<built-in>`)形式在 main file 前 EnterSourceFile,
  InitPreprocessor.cpp(lib/Frontend)生成其内容
- **计数器/Pragma 处理**:Pragma.cpp 分发到各 `Handle*Pragma`
  (与 Sema/Diag 交互的 pragma 由 PP 转发)

---

## 4. Token 回溯与缓存

Parser 常需要"看而不吃"超出 LL(1) 的 token;PP 层的 **Backtrack 机制**
(Preprocessor.h:1158-1725 一带的注释写得很细)解决跨层前瞻:

```cpp
EnableBacktrackAtThisPos();   // 开始缓存后续 token
  … Lex() 若干次 …
CommitBacktrackedTokens();    // 情况 A:确认消耗,缓存转为已消费
Backtrack();                  // 情况 B:回退到标记点,重放缓存
```

- 缓存实现为 `CachedTokens` 向量 + `BacktrackPositions` 栈;嵌套
  backtrack 允许,严格 FILO 配对
- 回退期间 `CurLexerCallback == CLK_CachingLexer`——即 §3.1 的第三态:
  从缓存回放 token,绕开真实 lexer 与宏展开(缓存里已是成品)
- **注意**:缓存里的 token 若包含未完成展开的宏,回放语义与首次一致,
  因为展开在进入缓存前已完成;`Lex` 发出的 PPCallbacks 在回放时不会
  重发——依赖回调的工具(libclang)要知道这一细节

这是 clang PP 区别于教科书实现的关键点:**PP 不产 lookahead 流,而把
"重读"实现为缓存回放**,Parser 因此可以安全地做任意深度前瞻(代价是
内存与"必须配对"的纪律)。

---

## 5. Directive 处理

`clang/lib/Lex/PPDirectives.cpp`——所有 `#xxx` 的入口是
`HandleDirective`(PPDirectives.cpp:1199),按 directive 名 switch:

| Directive | Handler(PPDirectives.cpp) | 备注 |
|---|---|---|
| `#include` / `#include_next` / `#import` / `#include_macros` / MS `#import` | HandleIncludeDirective(:2045) 等 | §7 |
| `#define` / `#undef` | HandleDefineDirective(:3145) / HandleUndefDirective(:3294) | §6 |
| `#if` / `#ifdef` | HandleIfDirective(:3427) / HandleIfdefDirective(:3349) | §8 |
| `#endif` / `#else` / `#elif` | HandleEndifDirective(:3479) 等 | |
| `#line` | HandleLineDirective(:1475) | 改 PresumedLoc(LineTableInfo) |
| `#error` / `#warning` | HandleUserDiagnosticDirective(:1713) | |
| `#pragma` | Pragma.cpp 分发 | `#pragma once`、`push/pop_macro` 等 |
| `#ident` / `#sccs` | HandleIdentSCCSDirective(:1720) | |
| `#assert` / `#unassert` | Handle… | GNU 扩展 |
| `#public` / `#private`(modules) | HandleMacroPublicDirective(:1770) / Private(:1797) | module 内宏可见性 |
| 未知 | HandleDigitDirective(:1637) 等 + 警告 | |

要点:

- **skipped 区间**:条件为假的分支进入 Lexer raw 模式(§2.2)快速跳过,
  仅追踪嵌套 `#if/#endif` 计数;`HandleSkippedDirectiveWhileUsingPCH`
  (:1174)处理 PCH 场景的特殊记账
- **`__has_include` / `__has_feature` 等**:在 PPExpressions 的常量求值
  里特判,`__has_include` 走一遍真实 HeaderSearch 查找(可产生文件系统
  副作用,与依赖扫描的交互见 §10)
- **宏名即 IdentifierInfo**:directive 首 token 查 IdentifierTable
  命中 keyword(directive 关键字也是 interned 的)

---

## 6. 宏

### 6.1 宏定义(MacroInfo)

`clang/include/clang/Lex/MacroInfo.h:39`。`#define` 时由
HandleDefineDirective 解析参数表与替换体,存成 **token 数组**
(不是字符串!):

```cpp
class MacroInfo {
  // 替换体 token 序列 + 参数列表 + 位标志:
  // IsFunctionlike / IsVariadic / IsBuiltinMacro / IsUsedForHeaderGuard…
};
```

- 定义位置(declaration 的 SourceLocation)与"定义处所见内容"都保存在
  MacroInfo 上,`-dM` 输出、宏重定义告警靠它
- **同一标识符的多次定义**:直接替换 MacroInfo,但若语义不等价
  (token 序列不同)发宏重定义警告(`-Wmacro-redefined`)
- `#undef` 只清 IdentifierInfo 上的标志;MacroInfo 对象进 PP 的回收
  (对象计数审计在 ~Preprocessor)

### 6.2 函数式宏:参数收集与展开

`clang/lib/Lex/PPMacroExpansion.cpp` + `MacroArgs` + `TokenLexer`:

```text
调用点:F(a, b)
  1. PP 收集实参:按括号深度/逗号层级切分(MacroArgs::ParseMacroArgs),
     不平衡括号/空实参按标准处理;实参 token 先按"完全未展开"保存
     (调用点语义)——这是 C 标准宏展开"参数在使用处展开"的关键
  2. TokenLexer 回放宏体 token:
     - 形参 x 的 token → 替换为实参
       · 普通使用处:实参**先完全展开**再代入(rescan 前的 argument
         pre-expansion)
       · #x 或 x ## y 处:代入**未展开**的原 token(字符串化/粘贴必须
         用原文)
     - #x → LexStringify(MacroArgs::getStringifiedArgument):
       参数 token 按原文(保留空白 flags)拼成字符串字面量
     - a ## b → TokenConcatenation::CreateString:两 token 粘贴成新
       token,需要重新 Lex 验证合法性(拼接结果非法 token → 诊断)
     - __VA_ARGS__ / 命名可变参数(GNU `args...`)按 IsVariadic 分支
     - __VA_OPT__(…) : VAOptDefinitionContext 追踪括号配对,
       空实参时整块省略(C++2a / C23)
  3. 回放结束后 TokenLexer 退栈,rescan:PP 继续对产物 token 做宏展开
     判断(递归终止靠"蓝迹"——见下)
```

**自引用终止(蓝迹/blue paint)**:宏展开产物中,同名宏的 token 被标记
`Token::DisableExpand`(在 TokenLexer 回放时打上);rescan 遇到它不再
展开——`#define f(x) f(x)` 无限递归由此终止。这是 C 标准的自引用规则
的工程实现,处理错误会直接导致标准违规或栈溢出。

### 6.3 builtin 宏

`__LINE__`/`__FILE__`/`__DATE__` 等无宏体,`isBuiltinMacro` 标记
(MacroInfo.h:217),PPMacroExpansion 按名特设生成 token(即时取
PresumedLoc);`__COUNTER__` 由 PP 维护单调计数。`__has_include`
返回 `1/0` 字面量。

### 6.4 预定义宏流

见 §3.3 的 predefines buffer;`-dD -dM`(PrintPreprocessedOutput.cpp,
lib/Frontend)分别输出"带 #define 行的 PP 结果"和"仅宏定义"。

---

## 7. #include 与 HeaderSearch

### 7.1 include 解析流程

`HandleIncludeDirective`(PPDirectives.cpp:2045)→ `LookupFile`:

1. **宏展开文件名**:`<...>` 与 `"..."` 两种形态;`"..."` 先查当前文件
   目录(可配 `-iquote` 语义),失败回落 angle 规则
2. **HeaderSearch 搜索**(HeaderSearch.cpp):按 `SearchDirs` 顺序
   (DirectoryLookup:Normal/Angle/Quote/System/ExternC…类别),逐目录
   stat 查找;`HeaderMap`(HeaderMap.cpp)按 hmap 二进制格式映射;
   framework 布局(Darwin)有专门路径
3. **命中缓存**:`HeaderFileInfo`(是否 multiple-include guard、是否
   已包含、controlling macro)挂在 FileEntry 上;**`#pragma once` 与
   guard 优化**(`__INCLUDE_GUARD` 检测:头两行 `#ifndef X` / `#define X`
   即识别)让重复 include 变成 O(1) no-op
4. **未命中**:`_IncludeNext`(HandleIncludeNextDirective,2695)按当前
   文件在搜索序列中的位置从下一目录继续
5. 命中后 EnterSourceFile(压栈,§3.2),发 `FileChanged` 回调

### 7.2 HeaderSearch 的表

- `SearchDirs`(SearchDirIterator 族遍历,HeaderSearch.h:188 起):
  由 InitHeaderSearch.cpp(lib/Frontend)按命令行 `-I/-isystem/-iquote/
  -idirafter` 与 ToolChain 默认构造,**顺序即语义**(quote→angle→
  system→after;C 路径与 C++ 路径分开记录以支持 ExternC 语义)
- 每个 HeaderSearch 有 `HeaderMap` 支持与 framework 索引;
  `ModuleMap` 决定 include 是否落进某个 module(§10)
- **stat 缓存**:FileManager 层缓存目录项,大工程的 include 解析开销
  主要在这里,clangd 的 PCH/模块缓存与之配合

### 7.3 include 嵌套上限

`-fmax-include-depth`(默认 200):IncludeMacroStack 深度超限报
fatal,防御递归 include。

---

## 8. 条件编译与 #line

### 8.1 条件栈

PP 维护每文件的 `#if` 栈(进入文件压空栈,退出弹掉,防跨文件泄漏):

- 每个 entry:`WasTrue`(本层是否已取过真分支)/ `FoundTrue` /
  `IsSkipping` 等状态;`#elif` 在 WasTrue 后直接跳过
- **PPExpressions.cpp**:`#if` 的常量求值。操作数要求"经过宏展开后是
  整型常量表达式";`defined(X)`/`defined X` 特判;`__has_include(...)
  ` / `__has_include_next` / `__has_feature` / `__has_attribute` /
  `__has_builtin` / `__has_warning`、`__has_cpp_attribute` 全在这层展开
  为常量——**这些对依赖扫描与模块都有影响**(它们决定文件是否被实际
  include)
- skipped 区间:raw 模式 lexer(§2.2)+ 嵌套计数,不展开宏、不查
  __has_include

### 8.2 #line 与 GNU line marker

HandleLineDirective(:1475):把当前文件位置"呈现"改写(SourceManager
的 LineTableInfo),影响 **PresumedLoc**(诊断显示、`__LINE__`/`__FILE__`
取值),不影响真实 spelling 位置与 FileID 语义——与基础设施篇 §2.1 的
三层位置语义呼应:`#line` 只动 presumed 层。

`# 1 "file" flag`(gcc 风格 line marker,预处理输出里大量出现)同机制,
flag 位指示入栈/出栈,供预处理输出的下游再消费。

---

## 9. PPCallbacks 与 PreprocessingRecord

### 9.1 观察者(PPCallbacks.h:36)

PP 在关键节点回调(`PPChainedCallbacks` 支持链式):

| 回调 | 时机 |
|---|---|
| `FileChanged`(PPCallbacks.h:49) | include 进出/文件结束 |
| `InclusionDirective`(:168) | 任何 include 指令(无论是否命中、是否被条件屏蔽) |
| `MacroExpands`(:339) / MacroDefined / MacroUndefined | 宏生命周期 |
| SourceRangeSkipped / If / Endif | 条件编译 |
| PragmaDirective / PragmaOpenMPExtension… | pragma |

消费方:模块构建(ASTWriter 记录宏依赖)、`-Wmacro-redefined` 类诊断的
上下文、clangd(引用/跳转)、**clang-scan-deps 等依赖分析工具**。**工具不改编译行为,只观察**——想改行为要用
`PreprocessorOptions` 或 VFS,不要 hack 回调。

### 9.2 PreprocessingRecord(PreprocessingRecord.h:308)

**它本身是 PPCallbacks 子类**(:308):把 PP 动作物化成
`PreprocessedEntity`(MacroDefinition / MacroExpansion / InclusionDirective
实体)存进可查询的记录,libclang 的宏浏览 / index 数据来源。实体在
ASTContext 里分配(与 AST 同 arena,序列化友好)。

---

## 10. 模块相关

- **ModuleMap.cpp**:解析 `module.modulemap`(framework/umbrella/
  explicit/textual header 声明),构建 Module 层级;include 命中某个
  module 的 header 时,PP 触发模块加载(ASTReader,见基础设施篇 §7),
  **而不是**逐 include 物理文件——`CurLexerSubmodule`
  (Preprocessor.h:779/1302)追踪当前文件所属 submodule
- **宏与模块**:`#define` 归属构建模块;`#pragma clang module` 与
  `HandleMacroPublic/Private`(PPDirectives.cpp:1770/1797)控制宏跨模块
  可见性
- **依赖扫描**:`clang-scan-deps` 走 PPCallbacks 的 InclusionDirective
  + 简化 PP(不开宏展开的全部副作用),模块模式下扫描 module map
  依赖图;`DependencyDirectivesScanner.cpp` 是其专用最小 token 化
  (只为找 include 边界,不做完整 PP)——工具复用 Lex 层但不走完整
  Preprocessor 的例子

---

## 11. 设计取舍与不变量

1. **CurLexer/CurTokenLexer 互斥**(Preprocessor.h:752/770):任何改动
   后必须恢复该不变式;`recomputeCurLexerKind`(:1937)是修复入口
2. **Lexer 无语义**:directive/宏/条件全在 PP 层;给 Lexer 加"认得
   #define"之类的逻辑会破坏 raw 模式与依赖扫描复用
3. **Backtrack 必须严格配对**:EnableBacktrackAtThisPos 后必须
   Commit 或 Backtrack 之一;泄漏会让后续 token 永远来自缓存(注释
   原文:"DO NOT forget",Preprocessor.h:1721)
4. **宏展开在 token 层,不是文本层**:一切"字符串化/粘贴"都操作
   token 及其 flags(LeadingSpace 等);丢 flags = 标准违规。Token 的
   `DisableExpand` 蓝迹机制决定自引用终止,不可绕过
5. **IncludeMacroStack 与 SourceManager 的 expansion 链必须一致**:
   诊断的 include 栈回溯同时依赖两者;只改一方必出幽灵诊断
6. **guard/`#pragma once` 判定是缓存优化**:语义上重复 include 本就
   合法;HeaderFileInfo 的缓存失效要与 #undef / modules 更新对齐
7. **predefines 是虚拟文件**:内置宏的 SourceLocation 指向
   `<built-in>`;诊断过滤(isInSystemHeader 类判断)要记得它
8. **PPCallbacks 只观察**:行为改变走 PreprocessorOptions / VFS;
   且回放缓存时不重发回调(§4),工具端计数要防重
9. **raw 模式的边界**:`#if 0` 区间不查 `__has_include`;依赖扫描器
   因此能安全跳过,但改条件求值逻辑时不要顺手在 raw 区间加副作用

---

## 12. 速查表

| 需求 | 位置 |
|---|---|
| PP 主类与三态 lexer | `clang/include/clang/Lex/Preprocessor.h:137`(状态字段 :752-799)、回调 :3026-3032 |
| include/宏栈 | Preprocessor.h:2472(PushIncludeMacroStack)、EnterSourceFile :1662 |
| directive 分发表 | `clang/lib/Lex/PPDirectives.cpp:1199`(HandleDirective)及各 Handle* |
| 条件求值 | `clang/lib/Lex/PPExpressions.cpp` |
| 宏展开核心 | `clang/lib/Lex/PPMacroExpansion.cpp` + `MacroArgs` + `TokenLexer.cpp` |
| 蓝迹/自引用终止 | TokenLexer 回放时打 DisableExpand(见 Token.h flags) |
| `__VA_OPT__` | TokenLexer.h 的 VAOptDefinitionContext |
| 字符串化/粘贴 | MacroArgs::getStringifiedArgument、TokenConcatenation.cpp |
| include 搜索 | `clang/lib/Lex/HeaderSearch.cpp`(LookupFile)、搜索序构建在 lib/Frontend/InitHeaderSearch.cpp |
| hmap | `clang/lib/Lex/HeaderMap.cpp` |
| `#pragma once`/guard | HeaderFileInfo(HeaderSearch.h)+ PP 的 guard 识别 |
| 回溯缓存 | Preprocessor.h:1158(BacktrackPositions)、:1721(配对纪律注释) |
| 观察者接口 | `clang/include/clang/Lex/PPCallbacks.h:36`(链式 :470) |
| PP 历史记录 | `clang/include/clang/Lex/PreprocessingRecord.h:308` |
| module map | `clang/lib/Lex/ModuleMap.cpp` |
| 依赖扫描专用 token 化 | `clang/lib/Lex/DependencyDirectivesScanner.cpp` |
| 预处理输出(-dM/-dD/-E) | `clang/lib/Frontend/PrintPreprocessedOutput.cpp` |
| 姊妹篇 | 《Clang 基础设施详细设计文档》§3(Token/IdentifierTable) |
