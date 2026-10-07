# Clang 基础设施详细设计文档

> 本文是《Clang 代码目录介绍》的深水区续篇,深入 clang 的**基础设施层**
> (lib/Basic + 相关底层设施):源码位置与 SourceManager、Token 与
> IdentifierTable、诊断体系、AST 内存模型与 ASTContext、TableGen 代码生成
> 体系、以及序列化(PCH/modules)。所有位布局、数据结构与文件路径均对照
> 本仓库实际代码逐一核实。

---

## 目录

1. [设计总览:一个编译器进程里有什么](#1-设计总览)
2. [SourceLocation 与 SourceManager](#2-sourcelocation-与-sourcemanager)
3. [Token 与 IdentifierTable](#3-token-与-identifiertable)
4. [诊断体系](#4-诊断体系)
5. [AST 内存模型与 ASTContext](#5-ast-内存模型与-astcontext)
6. [TableGen 基础设施](#6-tablegen-基础设施)
7. [序列化:ASTReader / ASTWriter](#7-序列化)
8. [跨层约束与不变量](#8-跨层约束与不变量)

---

## 1. 设计总览

clang 把"一个编译器进程"建模为一组长寿对象协作:

```text
CompilerInstance (lib/Frontend)
 ├─ FileManager ──────── 文件系统抽象:缓存 stat,FileEntry / DirectoryEntry
 │    └─ VirtualFileSystem(VFS)── 真实 FS 之上的 overlay(重定向、模块缓存、
 │         remote compilation、macOS frameworks 映射全靠它)
 ├─ SourceManager ────── 所有 SourceLocation 的解释器(§2)
 ├─ DiagnosticsEngine ── 诊断收发(§4)
 ├─ Preprocessor ─────── Lex 层总控,拥有 IdentifierTable / SelectorTable(§3)
 │    ├─ HeaderSearch ── include 搜索路径
 │    └─ ModuleMap ───── module map 解析
 ├─ ASTContext ───────── AST 的堆 + 全局表(§5)
 │    └─ 隐式持有 Types / IdentifierTable(共享)…
 └─ Sema / CodeGen / 各 ASTConsumer(流水线下游)
```

几个贯穿全文的设计决策:

- **全局偏移编码**:SourceLocation、DeclID、Type* 等所有"位置/身份"都尽量
  压缩成 32 位整数,牺牲解码信息换取海量对象下的内存与缓存友好
- **无引用计数、无写屏障的 arena**:AST 节点一旦建好默认不可变,模板实例化
  例外(延迟补全),这决定了 Sema 与 tools 的所有遍历模式
- **多层位置视图**:spelling / expansion / presumed 三种位置语义由 SourceManager
  统一仲裁,AST 节点只存一个 32 位 SourceLocation
- **TableGen 驱动的元数据**:诊断、属性、builtin、AST 节点声明全部 .td 描述,
  单一事实来源,生成 C++ 接口与文档

---

## 2. SourceLocation 与 SourceManager

### 2.1 SourceLocation:32 位全局偏移

定义在 `clang/include/clang/Basic/SourceLocation.h`。核心思想:**把整个翻译
单元中所有源码缓冲区(含宏展开产生的虚拟缓冲区)首尾相接,拼成一个虚拟地址
空间,SourceLocation 就是这个空间里的偏移量**。

```cpp
class SourceLocation {
  UIntTy ID = 0;                                // 32 位
  enum : UIntTy { MacroIDBit = 1ULL << 31 };    // 最高位:1 = 宏位置
  bool isFileID() const  { return (ID & MacroIDBit) == 0; }
  bool isMacroID() const { return (ID & MacroIDBit) != 0; }
};
```

位布局:

```text
 31        30 ...                     0
┌───┬────────────────────────────────────┐
│ M │       offset(31 bits)              │
└───┴────────────────────────────────────┘
M=0:文件位置,offset 是"本模块缓冲区块"内的偏移
M=1:宏位置,offset 是"宏块"内的偏移
```

关键细节(注释原文写得很清楚):

- **两个增长方向**:本模块缓冲区从 offset 0 向上增长;加载的 module(PCH)
  缓冲区从 `0x7FFFFFFF` 向下增长。两个方向相遇即耗尽
- `operator<` 只在**同一 FileID 内**有意义;跨 FileID 比较必须用
  `SourceManager::isBeforeInTranslationUnit()`
- `getLocWithOffset()` 直接做整数加法,不跨界
- 序列化用 `getRawEncoding()` / `getFromRawEncoding()`;ptr 编码用于
  PointerUnion 之类的场景
- DenseMapInfo 也有特化(`DenseMapInfo<clang::SourceLocation>`),
  empty key = `~0`,tombstone = `~0 - 1`

配套小类:

| 类 | 作用 |
|---|---|
| `FileID` | 32 位(int),>0 本模块,<0 加载的 module,0 invalid。SourceManager 内部表的索引 |
| `SourceRange` | 两个 SourceLocation,AST 节点实际存的形态 |
| `CharSourceRange` | +1 bit IsTokenRange:token range(终点是"最后一个 token 的起点",需量词长)与 char range(终点是字符)两种语义 |
| `PresumedLoc` | 解开的"呈现位置":受 `#line`/GNU line marker 影响的文件名+行列 |
| `FullSourceLoc` | SourceLocation + SourceManager*,方便 API 传参;提供 `isBeforeInTranslationUnitThan` 等 |

### 2.2 SourceManager:SLocEntry 表

实现在 `clang/lib/Basic/SourceManager.cpp`,头文件
`clang/include/clang/Basic/SourceManager.h`。SourceManager 维护两类 SLocEntry:

- **File SLocEntry**:一个 MemoryBuffer(实际文件或预处理的虚拟文件,
  如 `_Pragma`、模块构建的临时缓冲)
- **Expansion SLocEntry**:一次宏展开(或 `_Pragma`/注记)——记录
  `ExpansionLocStart/End`(调用点范围)与 `SpellingLoc`(被展开内容的书写处)

每个 SLocEntry 占据全局地址空间的一段 `[Start, Start+Length)`,SourceManager
用有序数组 + 二分查找把任意 SourceLocation 定位到 SLocEntry,再进一步分解出
FileID + 文件内偏移。宏展开则形成 SLocEntry 链:expansion loc → (再跳)
→ spelling loc,`getImmediateExpansionLoc()` 走一步、`getExpansionLoc()`
走到头、`getFileLoc()` 等价于走到头的文件位置。

`getPresumedLoc()`:在 file loc 基础上叠加 `#line` 改写(LineTableInfo),
返回 PresumedLoc——这是最终给用户看的 "file:line:col"。

**为什么这么设计**:AST 节点(每个 Expr/Stmt 至少一个)大量出现,位置必须
只占 4 字节且可拷贝比较;把全部复杂度推给 SourceManager 的运行期查询。代价是
任何"这个位置在哪个文件"都要查表(有缓存),以及全局空间耗尽处理
(`DiagID::err_...` 返回并 fatal)。

---

## 3. Token 与 IdentifierTable

### 3.1 Token

`clang/include/clang/Lex/Token.h`。Lexer 产出、Parser 消费的原子单位:

```cpp
class Token {
  tok::TokenKind Kind;        // 枚举,TableGen 生成(TokenKinds.def)
  unsigned Flags;             // LeadingSpace / StartOfLine / NeedsCleaning…
  unsigned Length;
  void *PtrData;              // 双关:identifier 时指向 StringMapEntry,
                              // literal 时指向字面量数据
  SourceLocation Loc;         // 32 位(§2.1)
};
```

- `tok::TokenKind` 来自 `clang/include/clang/Basic/TokenKinds.def`,经
  TableGen 生成 `TokenKinds.h`;`is()`/`isNot()`/`isOneOf()` 是 parser 里
  最常见的调用
- 字面量的实际文本在 `LiteralSupport.cpp` 处理(数字进制、字符串拼接、
  前后缀切分)
- Token 的 `PtrData` 在 identifier 情况下直接携带 `IdentifierInfo` 查表
  结果(见 §3.2),parser 拿到 token 即 O(1) 拿到语义信息

### 3.2 IdentifierTable

`clang/include/clang/Basic/IdentifierTable.h`。标识符唯一化(interning):

```cpp
class IdentifierTable {
  using HashTableTy = llvm::StringMap<IdentifierInfo *, llvm::BumpPtrAllocator>;
  HashTableTy HashTable;
};
```

- `IdentifierInfo`:identifier 的全局句柄。保存是否为 keyword(`getTokenID`),
  builtin ID(`getBuiltinID`,来自 Builtins.def 生成的表),是否 builtin
  macro(`__LINE__` 等),以及各种语言扩展标志位
- 关键性质:**同一个拼写的标识符全编译器只有一个 IdentifierInfo***,
  AST 里的 `DeclarationName`、Preprocessor 的宏表、Sema 的 lookup 表都以
  它(或其哈希)为 key,比较退化为指针比较
- `SelectorTable`:ObjC selector 的同类设施,Selector 同样是指针级唯一
  (`Selector` 内部持 IdentifierInfo 指针对),表驱动地避免重复
- 底层是 `llvm::StringMap`(开链哈希 + arena 分配),`AddIdentifier` 之外
  还负责 keyword 的语言条件装载(`AddKeywords`,受 LangOptions 影响,
  如 C++ 的 `class` 在 C 模式下只是普通 identifier)

---

## 2.2 IdentifierInfo 与宏表的关系

Preprocessor 的宏表(`llvm::DenseMap<IdentifierInfo*, MacroInfo*>`)挂在
IdentifierTable 之上:IdentifierInfo 记录"有没有宏、是否 builtin macro",
宏体(MacroInfo)由 Preprocessor 在首次定义时创建。展开时 PPMacroExpansion
沿 IdentifierInfo → MacroInfo → TokenLexer 回放 token 流。

---

## 4. 诊断体系

### 4.1 分层

```text
DiagnosticIDs (Basic/DiagnosticIDs.h)
  ↑ 持有;诊断 ID 空间、默认严重度、映射规则
DiagnosticsEngine (Basic/Diagnostic.h)
  ↑ 组装;RAII DiagnosticBuilder;Werror 映射;Suppression;计数
DiagnosticConsumer (抽象基类)
  ├─ TextDiagnosticPrinter        — stderr 彩色文本
  ├─ SerializedDiagnosticPrinter  — .dia 文件(给 clang-scan-deps / tools)
  ├─ SARIFDiagnosticPrinter       — SARIF JSON(IDE/CI)
  ├─ ChainedDiagnosticConsumer    — 多路分发
  ├─ IgnoringDiagConsumer         — 吞掉所有(clangd 用)
  ├─ ForwardingDiagnosticConsumer
  └─ clangd/工具侧自定义 consumer(如收集 fixits)
```

### 4.2 DiagnosticIDs:由 TableGen 生成

每个诊断是 `include/clang/Basic/Diagnostic*.td`(CommonKinds、DriverKinds、
FrontendKinds、SemaKinds、ASTKinds、LexKinds、SerializationKinds、RefactorKinds)
里的一条记录:

```tablegen
def err_ovl_no_viable_member_function_in_call : Error<
  "no viable member function for %diff{$|... $}1,2">,
  DefaultFatal;
```

TableGen 生成:

- 诊断 ID 枚举(`diag::enum id` 按 .td 顺序编号)——新增/删除 .td 记录会
  改变后续所有 ID,序列化敏感场景要知道这点
- 格式化串表 + 参数个数/类型元信息(%0-%N,%select/%plural/%diff 修饰符)
- 默认严重度(Error/Warning/DefaultFatal…)与所属组件

### 4.3 DiagnosticsEngine 的使用面

Sema/CodeGen 里最常见形态:

```cpp
Diag(Loc, diag::err_typecheck_convert_incompatible)
    << lhsType << rhsType << hintExpr
    << SourceRange(opLoc)
    << FixItHint::CreateReplacement(...);
```

- `Diag()` 返回 **DiagnosticBuilder**(临时对象,RAII):`<<` 塞参数,
  析构时把组装好的 `DiagnosticInfo` 派发给 consumer
- `<<` 按参数类型特化:整型填 %N、QualType 自动加引号与 apostrophing、
  DeclarationName/NamedDecl* 打印为声明、SourceRange 标记高亮区、
  FixItHint 附加替换
- `SourceLocation` 为 invalid 时诊断照发,但打印时无位置
- 严重度调整:`-Werror=foo`、`#pragma clang diagnostic ignored` 由
  DiagnosticsEngine 的映射层处理(Sema 维护 pragma stack,见
  `Sema::ActOnPragmaClangDiagnostic`)
- `-verify`(test/Sema 里的 `expected-error@...`)由独立 pass
  `VerifyDiagnosticsClient` 在 TU 末尾比对

### 4.4 设计取舍

- **ID 集中**:诊断 ID 全在 .td,文案与元数据一处维护,`diagtool` 可查
- **延迟组装**:参数到 builder 析构才格式化,热路径上未启用的 warning
  几乎零成本(`diags.EnableAllWarnings` 门控)
- **消费端可插拔**:同一引擎对接终端、.dia、SARIF、IDE(clangd 自定义
  consumer 拿 fixits),工具复用编译器诊断而不重写
- **Error 计数与恢复**:DiagnosticsEngine 统计 error 数,超过
  `error-limit` fatal;Sema 的错误恢复策略(类型变 int、造 recovery expr)
  与这层解耦

---

## 5. AST 内存模型与 ASTContext

### 5.1 Arena 分配

ASTContext(`clang/include/clang/AST/ASTContext.h`, `clang/lib/AST/ASTContext.cpp`)
内嵌一个大 arena:

- 所有 Decl/Stmt/Expr 节点 `operator new(size, Ctx, …)` 重载到 context 的
  BumpPtrAllocator,**单个节点无单独 delete**;ASTContext 销毁时整块回收
- 不做 GC、不做引用计数。配合"节点建好即只读"的纪律,工具端(clangd)的
  并发读 AST 因此安全
- 少数节点支持 `DesTy` 反序列化与延迟构造(`Decl::isCompleteDecl`),PCH
  场景按需物化(§7)
- **ASTImporter**(`lib/AST/ASTImporter.cpp`)是跨 context 导入节点的方式:
  做 structural equivalence 判定后逐节点复制,静态分析 cross-TU 用

### 5.2 类型系统:指针即 ID

`clang/include/clang/AST/Type.h`。类型被唯一化(canonical types),指针比较
即类型相等:

- ASTContext 持有 `Type *` 的表(`Types`);`getCanonicalType()` 返回唯一
  代表,`QualType`(指针 + qualifiers 位打包)是全编译器的类型句柄
- Type 节点本身不可变;typedef/sugar 链(ElaboratedType 等)在 canonical
  链外,查询语义要沿 sugar 走到 canonical
- `splitQualType` / `Desugar` 系列是常见操作

### 5.3 ASTContext 持有的全局表

ASTContext 是名副其实的"中央仓库":

| 表 | 内容 |
|---|---|
| Types | canonical type 唯一化表 |
| Deduced templates、ExtQuals | 模板推导结果、扩展限定符 |
| PredefinedExpr / StringLiteral 表 | 唯一化的编译期实体 |
| ObjC selectors / protocols 等 | ObjC 语义实体 |
| PrintingPolicy | AST 打印策略(供 -ast-print / diagnostics) |
| 附属:Stmt/Expr 的 ID(序列化时全局 DeclID 见 §7) |
| TargetInfo / PrintingPolicy / LangOptions | 目标与语言选项(决定布局与打印) |
| VTableContext / MangleContext | C++ ABI 侧(CodeGen 借用) |
| comments::CommandTraits | 文档注释命令表 |
| InterpState(ExprConstant) | 常量求值器的状态(context 挂接) |

### 5.4 Decl 与 DeclContext

`clang/include/clang/AST/DeclBase.h`:

- Decl 是单继承 + 闭合的类层级(TableGen `DeclNodes.td` 生成 visitor),
  基类尾部有 `DeclContextBitfields` 位域,子类共用
- **DeclContext** 是二级能力:TagDecl、FunctionDecl 等可同时是 Decl 又是
  DeclContext(多重继承),内部用 `DeclContextLookupResult` 提供声明查找
- 每个 Decl 有全局唯一 `DeclID`(ASTContext 与 ASTReader 协作分配,本模块
  从 1 递增,PCH 合并时重映射),序列化的 key;`getGlobalID()`
- **Primary context / semantic DeclContext**:模板/特化的语义归属(
  `getPrimaryContext`),lookup 结果需要沿这条线聚合
- DeclarationName:名字的 interned 表示(IdentifierInfo + kind(
  constructor/destructor/operator/selector)),`DeclarationNameTable`
  (ASTContext 持有)唯一化

### 5.5 生命周期与线程模型

- 一个 CompilerInstance 一套 SourceManager/ASTContext;**clangd 场景**:
  每个 TU 一个 context,读路径无锁(不变量:AST immutable)
- PCH:ASTReader 覆盖 ASTContext 的分配钩子,序列化 ID 空间与运行时 ID
  空间统一
- Undo/Sema 误建节点:arena 不回收,错误恢复丢弃引用即可(内存换简单)

---

## 6. TableGen 基础设施

clang 的元数据层。`.td` 是事实来源,`clang-tblgen`(llvm/lib/TableGen 的
前后端,构建产物在 build-shared/bin)生成 C++:

| .td 源 | 生成物 | 用途 |
|---|---|---|
| `Basic/Builtins.def` | `Builtins.h` 系(builtin ID 枚举 + 签名表) | Lex 标记 builtin、Sema 检查、CodeGen 映射 |
| `Basic/Diagnostic*.td` | `DiagnosticIDs.cpp/h` | 诊断 ID、文案、参数模式(§4) |
| `Basic/Attr.td` + `AttrDocs.td` | `Attr*.inc`(AttrImpl.inc、Attrs.inc…) | `__attribute__` 体系:属性名、参数形态、Sema/CodeGen 挂点 |
| `Basic/TokenKinds.def` | `TokenKinds.h` | token 类别枚举与名字 |
| `AST/DeclNodes.td` / `StmtNodes.td`(ASTNodes.td) | `DeclNodes.inc` / `StmtNodes.inc` | AST 节点类的 visitor 基类、classof 链、dumper 挂点 |
| `Basic/OpenCLBuiltins.td` | OpenCL 内建函数表 | OpenCL 支持 |
| `Basic/OpenMPKinds.def`、`Basic/Cuda*.def` | 各类 kind 枚举 | OpenMP/CUDA 子句 |
| `lib/AST/Comment*.td`(如 CommandList.td) | 注释命令表 | 文档注释 |
| `Driver/Options.td` | `Options.inc` | driver 选项表(cl::opt 之上的声明式描述) |

要点:

- **单一事实来源**:.td 改一处,枚举、匹配、文档、序列化 ID 同步变。
  Attr.td 最复杂——它同时生成 Sema 侧接口与 AST 侧表示(`Attr` 类层)
- **生成物不进源码树**:在 build-shared/ 下,由 include 表引用(`#include
  "clang/AST/StmtNodes.inc"`),改动 .td 触发依赖它的所有 TU 重编
- **生成器的实现**:在 `clang/utils/TableGen/`(clang-tblgen 的后端集合:
  ClangAttrEmitter、ClangDiagnosticsEmitter、ClangBuiltinsEmitter 等);
  通用 TableGen 语言本身在 `llvm/lib/TableGen`
- `Builtins.def` 的条目同时服务 Sema(检查调用合法性)与 CodeGen
  (`CGBuiltin.cpp` 按 ID 分派),是"builtin→intrinsic 链路"的头端(见
  《Clang 代码目录介绍》§4)

---

## 7. 序列化:ASTReader / ASTWriter

`clang/lib/Serialization/`。PCH 与 modules 共用同一套位流格式(bitstream,
复用 LLVM Bitstream 库):

```text
ASTWriter(写)                        ASTReader(读)
  ModuleFile 布局:
  ├─ CONTROL_BLOCK        ── 元信息(版本、target、语言选项、模块名)
  ├─ INPUT_FILES_BLOCK    ── 输入文件表(FileID 空间来源)
  #line 文件偏移
  ├─ SOURCE_MANAGER_BLOCK ── SLocEntry 序列化(FileID→模块内局部 ID 映射)
  ├─ PREPROCESSOR_BLOCK   ── 宏、pragma…
  ├─ (STMT 记录内联于 DECL 上下文,由 ASTReaderStmt/ASTWriterStmt 处理)
  ├─ DECLS_BLOCK          ── 按 DeclID 顺序的声明记录(ASTWriterDecl.cpp)
  ├─ TYPES_BLOCK?         ── (类型经 interning,不单独成块;随声明内联)
  └─ IDENT_TABLE / SEARCHTABLE 等
```

(块名以代码为准,以上是结构示意;核心源文件 ASTReaderDecl.cpp /
ASTWriterDecl.cpp / ASTReaderStmt.cpp / ASTWriterStmt.cpp 按节点类别组织。)

核心机制:

- **ID 重映射**:每个模块文件有自己的局部 ID 空间(DeclID、IdentID、
  MacroID、SLocEntry 偏移),ASTReader 加载时建立 local→global 映射表,
  与本模块从 offset 高端向下分配的 SourceLocation 空间对齐(§2.1)
- **惰性加载**:声明记录读入后不立即物化 AST 节点,只登记 ID;真正被引用
  时才 `GetDecl` 物化(Decl::FromASTFile 标记),ASTContext 的 new 钩子
  由 reader 接管
- **更新记录(update records)**:模块外对本模块实体的修改(特化、隐式
  方法实例化)作为 update 追加,而非重写模块
- **modules 的模块图**:ModuleGraph 决定加载顺序与显式/隐式导入;
  `-fmodules-cache-path` 的 .pcm 缓存命中判定靠 CONTROL_BLOCK 里的选项
  哈希
- **ODR 检查**:跨模块 structural equivalence + ODRHash(§5.3)在加载时
  校验,违例报 modules ODR 诊断

### 与 SourceManager 的协同

ASTReader 本身就是一个"SLocEntry 提供者":加载模块时把模块的 SLocEntry
表按 §2.1 的下行空间注册进 SourceManager,SourceLocation 的 32 位编码因此
天然支持"PCH 位置"与"本 TU 位置"共存。这也是为什么 FileID 的 int 编码
`<0` 表示来自加载的模块。

### PCH vs Modules 的区别

- PCH(-emit-pch / -include-pch):单一前缀文件,只是序列化层的直接应用
- Modules(-fmodules):在 PCH 之上加 module map 语义、模块图、隐式导入、
  缓存管理(HeaderSearch + ModuleMap + ASTReader 协作)

---

## 8. 跨层约束与不变量

基础设施层的几条纪律,改动前值得默诵:

1. **SourceLocation 只 32 位**:不要给它加字段;跨 FileID 排序必须走
   `isBeforeInTranslationUnit`。全局空间是 2^31,巨型 TU(含宏展开)可能
   耗尽,相关 fatal 诊断存在
2. **AST 节点建好即只读**(除明确的延迟补全点,如模板实例化):一切
   "改 AST"的需求都该走重建/TreeTransform,而非原地改
3. **IdentifierInfo/Type/DeclarationName 指针即身份**:比较用指针,不要
   按字符串比较;interning 依赖唯一化表,不要绕过 ASTContext/IdentifierTable
   自己 new Type
4. **诊断走 .td**:新增诊断必须在 `Diagnostic*.td` 加记录,不要手写字符串
   ID;`diag::` 枚举顺序即 .td 顺序,影响 .dia 序列化兼容
5. **TableGen 改动会放大重编译**:.td → .inc/.h 被广泛 include,一个小改
   动可能触发数千 TU 重编,review 与 CI 时要有预期
6. **序列化兼容**:改 Decl/Stmt 字段必同步 ASTWriterDecl/ASTReaderDecl 与
   版本号(llvm::VersionTuple);改动后跑 check-clang-modules 与
   check-clang-interoperability
7. **错误恢复不释放内存**:Sema 造 recovery 节点直接丢弃即可,不要试图
   delete arena 中的节点
8. **VFS 之上无直连文件 IO**:基础设施之外的一切(clangd、modules 缓存、
   头文件搜索)必须经 FileManager/VFS,真实路径语义(仅用于诊断显示)
   与虚拟路径语义要区分
9. **PresumedLoc 只在展示层用**:逻辑判断(如 isInSystemHeader)用
   FileLoc/ExpansionLoc;`#line` 只影响 PresumedLoc,不影响任何语义判断
10. **诊断文案多语言意识**:format string 里 %select 选项数变化会破坏
    翻译表;修改文案尽量保持参数个数不变

---

## 附:快速定位

| 需求 | 文件 |
|---|---|
| SourceLocation 位布局 | `clang/include/clang/Basic/SourceLocation.h:88`(类注释含设计说明) |
| SLocEntry 双向分配 | `clang/lib/Basic/SourceManager.cpp`(SLocEntry 相关函数) |
| Identifier 唯一化 | `clang/include/clang/Basic/IdentifierTable.h:655` |
| 诊断 ID 定义 | `clang/include/clang/Basic/Diagnostic*.td` |
| DiagnosticBuilder RAII | `clang/include/clang/Basic/Diagnostic.h:1271` |
| AST arena | `clang/include/clang/AST/ASTContext.h:186` 起 + `ASTContext.cpp` |
| Decl/DeclContext 双角色 | `clang/include/clang/AST/DeclBase.h:1435`(DeclContext) |
| 生成器后端集合 | `clang/utils/TableGen/` |
| PCH 模块文件布局 | `clang/lib/Serialization/ASTWriter.cpp` 头部注释 |
| 本文档姊妹篇 | 《Clang 代码目录介绍》(Clang_Codebase_Directory_Guide.md) |
