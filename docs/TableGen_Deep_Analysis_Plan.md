# TableGen 深度分析方案

> 编制日期：2026-10-03；源码基准：llvm-project HEAD 3eda2aebadd4。
> 文档性质：研究与写作方案。除第 10 节列出的准备检查外，实验矩阵均为待执行任务。
> 预期正文：TableGen_Deep_Analysis.md；原始证据与实验：TableGen-notes/。

## 1. 研究目标

围绕一条主线展开：

**.td 定义 → 参数替换与记录展开 → RecordKeeper → 领域语义解释 → 生成文件 → C++ 消费者。**

最终读者应能回答以下问题：

1. TableGen 的通用语言前端处理什么，目标描述或 ODS 的语义由谁解释？
2. 如何阅读和编写 .td：类型、字面量、表达式、声明、作用域和预处理的语法是什么；class、def、multiclass、defm、foreach、let 如何决定最终 record 的名字、类型和字段？
3. 同一份记录为什么能生成指令信息、寄存器信息、匹配表、编码器或文档等不同产物？
4. SelectionDAG 与 GlobalISel 如何消费模式；哪些模式能共享，哪些需要额外描述或手写代码？
5. 调度模型、指令编码和寄存器描述如何进入运行时库？声明模型与算法实现的边界在哪里？
6. llvm-tblgen、clang-tblgen、mlir-tblgen 共享哪些基础设施，各自怎样注册生成动作？
7. 构建系统如何管理 include 依赖、生成文件、多阶段引导和交叉编译时的宿主工具？
8. 若给现有项目增加一种描述或一个生成器，如何选择复用层、设计测试并限制维护成本？

完成标准是能解释并复现上述链条。文件数量、代码行数和生成体积作为辅助数据，不能单独证明工程投入或设计优劣。

## 2. 范围与研究层次

| 层次 | 核心对象 | 本次研究深度 |
|---|---|---|
| 工具驱动 | TableGenMain、三种 tblgen 入口、动作注册、输出管理 | 完整跟踪一次调用及分发 |
| .td 语法与语言前端 | 类型、字面量、表达式、全部主要语句、预处理；TGLexer、TGParser | 先给语法说明与示例，再以正例和负例解释作用域及展开 |
| 通用数据模型 | RecTy、Init、RecordVal、Record、RecordKeeper、Resolver | 跟踪类型、所有权、未设值与引用消解 |
| LLVM 领域模型 | CodeGenTarget、CodeGenInstruction、CodeGenRegisters、CodeGenDAGPatterns、CodeGenSchedModels | 解释通用记录如何获得目标相关语义 |
| LLVM 生成器 | 指令/寄存器/MC、SDAG/GISel、调度、intrinsic | 各选代表链条，追到消费端 |
| Clang 生成器 | 属性为主，诊断、内建函数、选项为扩展 | 属性链完整闭环，其余给职责地图 |
| MLIR 生成器 | ODS、操作声明/定义、DRR | 区分操作接口生成与重写规则生成 |
| 工程体系 | CMake/Ninja、诊断、lit、生成确定性、性能 | 提供可重复的验证方法 |

取样策略：

- **MSP430**：小目标，便于读完一条指令、寄存器及 MC 生成链。
- **AMDGPU**：研究复杂模式、GlobalISel 导入、调度模型与手写扩展。
- **NVPTX**：观察 PTX 文本接口下的生成职责，避免将寄存器描述直接等同于物理寄存器分配。
- **Clang NoInline 属性**：同一 record 的 AST 类、实现和语义检查投影。
- **MLIR arith.addi**：ODS 操作定义与 DRR canonicalization 的相邻但不同的链条。

不预设覆盖全部 emitter、全部 target 或全部 bang operator。每章先完成一个机制的完整证据链，再决定是否扩展样本。

## 3. 基线与工具选择

### 3.1 当前已检查的环境

| 项目 | 检查结果 | 使用方式 |
|---|---|---|
| 源码 HEAD | 3eda2aebadd4 | 后续实验记录完整提交号和工作区差异 |
| build-shared 三种 tblgen | LLVM 19.1.7 | 与当前源码有版本差异，不能直接据此解释当前生成器实现 |
| build-debug 三种 tblgen | LLVM 24.0.0git，Debug + Assertions | 本方案最小示例使用的现有工具 |
| build-debug 目标配置 | AMDGPU、NVPTX、AArch64 | 对运行时验证有约束；不妨碍宿主 tblgen 读取其他目标的 .td |
| 仓库标准构建目录 | build-shared，见 AGENTS.md | 若需要重新构建，遵循仓库约定；本方案没有重新配置或构建 |

版本字符串相同不能证明二进制来自同一提交。正式研究开始前保存二进制路径、版本、SHA256、相关 CMakeCache 项；需要严格源码对应时，重建所需工具并保存构建日志。

所有实验显式指定工具路径。不要依赖 PATH 中的系统 LLVM，也不要把旧生成文件与新生成器的输出混用。

### 3.2 每次实验记录的最小信息

- 实验编号、源码提交、相关已跟踪文件的工作区差异。
- 输入 .td 及其 include 依赖，所有 -I/-D、生成动作和其他参数。
- 工具路径、版本、校验和、构建类型、断言设置。
- 工作目录、完整命令、退出码、stdout、stderr、产物路径和 SHA256。
- 预期、实际结果、对应源码符号，以及能够支持的结论范围。

## 4. 总体结构图与边界

~~~mermaid
flowchart TD
    A[".td 输入、include、命令行参数"] --> B["工具入口与 TableGenMain"]
    B --> C["TGLexer / TGParser"]
    C --> D["参数替换、展开、类型处理与引用消解"]
    D --> E["RecordKeeper"]
    E --> F["LLVM 领域模型与 emitter"]
    E --> G["Clang emitter"]
    E --> H["MLIR TableGen 包装与生成器"]
    F --> I["描述表、匹配表、编码或解码代码"]
    G --> J["属性、诊断、内建函数等生成文件"]
    H --> K["操作、接口、验证与重写生成文件"]
    I --> L["编入 LLVM / MC / CodeGen"]
    J --> M["编入 Clang"]
    K --> N["编入 MLIR"]
~~~

图中的“领域模型”由具体 emitter 决定，不假定所有后端必经同一个类。

必须分清三个时刻：

1. **TableGen 运行时**：解析描述并生成文本或其他产物。
2. **C++ 构建时**：生成文件被 include、编译和链接。
3. **编译器或工具运行时**：算法读取生成表，或调用生成代码。

修改临时 .td 并生成新的 .inc，只验证第一层变化。若没有把产物重新编入消费者，就不能宣称已验证新的选指、编码或调度行为。

## 5. 建议正文目录与源码入口

源码位置采用“文件 + 符号”作为主要锚点；正式写作时再补经核对的行号。

### 第 1 章：定位、驱动与构建引导

**问题**

- TableGenMain 如何处理输入、include 路径、输出、依赖文件、计时与错误？
- CLI 路径和嵌入式 TableGenParseFile API 如何分别进入 TGParser？
- llvm-min-tblgen、Basic、Common、完整 llvm-tblgen 如何拆开构建依赖？
- 单文件和多文件 emitter 如何注册并返回产物？

**入口**

- [Main.cpp](llvm/lib/TableGen/Main.cpp)：TableGenMain、输出与依赖文件。
- [Parser.cpp](llvm/lib/TableGen/Parser.cpp)：TableGenParseFile；它不是 CLI 主流程必经的中间层。
- [TableGenBackend.h](llvm/include/llvm/TableGen/TableGenBackend.h)、[实现](llvm/lib/TableGen/TableGenBackend.cpp)：Opt、OptClass、MultiFileOptClass、ApplyCallback。
- [Basic/TableGen.cpp](llvm/utils/TableGen/Basic/TableGen.cpp)：tblgen_main 和通用动作。
- [工具构建规则](llvm/utils/TableGen/CMakeLists.txt)、[Basic 构建规则](llvm/utils/TableGen/Basic/CMakeLists.txt)、[Common 构建规则](llvm/utils/TableGen/Common/CMakeLists.txt)。

**产出**：入口调用图、生成动作注册表、构建依赖图；遇到注释与实现不一致时，通过调用方分支和实验确认返回值含义。

### 第 2 章：.td 语法、语言语义、展开顺序与作用域

本章必须包含可直接阅读的语法说明、示例及展开结果。下述内容作为正文的语法基础；准确文法以当前仓库的 [TableGen 语言参考](llvm/docs/TableGen/ProgRef.md) 和解析器为准。表中的 `C`、`R`、`T` 等表示示例名称，各行片段不一定能独立运行。

#### 2.1 文件结构、词法与预处理

- **注释**：`//` 表示行注释；`/* ... */` 表示块注释，支持嵌套。
- **标识符**：区分大小写；`NAME` 是隐式模板参数。`$src` 这类名字用于 DAG 节点或参数标签。`code` 等保留字不能用作普通标识符。
- **包含文件**：`include "Common.td"` 在词法阶段引入文件内容，指令末尾不写分号；搜索路径由工具参数 `-I` 等控制。
- **分隔符**：字段声明和 `defvar` 等语句以 `;` 结束；record 的空体可写为 `;`，非空体写为 `{ ... }`；模板参数使用 `<...>`。
- **条件预处理**：支持 `#define`、`#ifdef`、`#ifndef`、`#else`、`#endif`，指令从行首开始，可带前导空白。宏只表示是否定义，不提供 C/C++ 式的值替换或函数宏；`-DNAME` 可从命令行定义宏。

例如，下列预处理片段选择要解析的定义：

~~~tablegen
#ifdef ENABLE_EXTRA
def Extra;
#else
def BasicOnly;
#endif
~~~

#### 2.2 类型、字面量与未设值

| 类型或形式 | 写法示例 | 含义与约束 |
|---|---|---|
| `bit` | `bit Enabled = 1;` | 单个布尔位；`true` / `false` 可用于布尔值 |
| `bits<n>` | `bits<8> Encoding = 0x2A;` | 固定位数的位序列；可逐位或按位段读写 |
| `int` | `int Width = 32;` | 64 位整数；支持十进制、`0x` 十六进制和 `0b` 二进制字面量 |
| `string` | `string Name = "add";` | 字符串；相邻字符串字面量可连接 |
| `code` | `code Body = [{ return true; }];` | `string` 的别名；`[{ ... }]` 保留多行文本，TableGen 前端不执行其中的 C++ |
| `list<T>` | `list<int> Widths = [32, 64];` | 元素类型受约束的列表；索引从 0 开始 |
| class 名作为类型 | `OperandKind Src = Reg;` | `Reg` 必须是派生自 `OperandKind` 的 record；需先定义相关 class / record |
| `dag` | `dag Inputs = (ins Reg:$src);` | 操作符及参数组成的结构；操作符 `ins` 必须是 record，标签意义由消费者解释 |
| 未设值 `?` | `int Optional = ?;` | 字段未初始化；具体 record 也可能保留它，是否允许由使用该字段的生成器进一步约束 |

重点对比 `{1, 0, 1}` 位序列、`[1, 0, 1]` 列表与 `(op ...)` DAG；三种括号承载不同类型。类型转换规则、越界位段及不兼容赋值都应配负例。

#### 2.3 主要语句与作用域

| 语句 | 基本形式 | 必须说明的语义 |
|---|---|---|
| `class` | `class C<int V, string S = "x"> { int Value = V; }` | 定义可继承的抽象记录；模板参数有类型，可有默认值；必填参数在可选参数之前 |
| 继承与实参 | `def R : C<7>, Other;` 或 `def R : C<V = 7>;` | 可多继承；支持位置和命名实参，位置实参须先出现，同一参数不能重复指定 |
| `def` | `def R : C<7>;` 或 `def R : C<7> { let Value = 8; }` | 创建具体 record；省略名字可创建匿名 record，其最终名字不应作为稳定接口 |
| record 内 `let` | `let Value = 9;`、`let Encoding{3...0} = 5;` | 覆盖已有字段或位段；不用于修改模板参数 |
| 外层 `let` | `let Value = 9 in { def R : C<7>; }` | 为作用域内定义覆盖继承字段；需解释与 record 内局部覆盖的先后关系 |
| `multiclass` | `multiclass M<int V> { def _a : C<V>; def _b : C<!add(V, 1)>; }` | 保存一组可展开的定义；可继承其他 multiclass |
| `defm` | `defm P : M<7>;` | 展开 multiclass，此例创建 `P_a`、`P_b`；不创建一个名为 `P` 的容器 record；`defm` 自身没有 record body |
| `defvar` | `defvar N = !add(1, 2);` | 推导类型的变量，在同一作用域内不可重新赋值；record 内的 `defvar` 不成为字段 |
| `foreach` | `foreach I = [0, 1] in { def R#I : C<I>; }` | 重复展开语句；每轮局部变量独立，也可使用范围序列 |
| `if` | `if !eq(N, 3) then { def A; } else { def B; }` | 按条件选择展开的语句；区分返回值的 `!if(...)` 表达式 |
| `defset` | `defset list<C> Group = { def A : C<1>; def B : C<2>; }` | 定义 record，同时收集到列表；元素须符合 class 类型，表达式内创建的匿名 record 不收集到该列表 |
| `deftype` | `deftype Index = int;` | 当前仓库支持的顶层类型别名语法；可为 `int` 等类型或已有别名命名，当前解析器拒绝直接为 record class 类型建立别名 |
| `assert` | `assert !gt(N, 0), "N must be positive";` | 失败时产生诊断；求值时机取决于顶层、class、record 或 multiclass 等位置 |
| `dump` | `dump !repr(N);` | 调试输出到 stderr；结合实例化位置解释输出时机 |

语法说明还须包含三项细节：

1. **`NAME` 与命名**：在 multiclass 内，具名 `def` / `defm` 的名字若未引用 `NAME`，会自动加上该参数作为前缀；需用嵌套示例解释最终名称。
2. **`let append` / `let prepend`**：当前源码支持对 `list<T>`、`string` / `code`、`dag` 追加或前插，分别使用列表连接、字符串连接和 DAG 连接的语义；未设值 `?` 直接设为新值。该语法需记录工具版本支持情况，不能默认旧工具支持。`append`、`prepend` 仅在 `let` 后作为修饰词识别。
3. **语句位置**：顶层、record body、multiclass body 允许的语句集合需分别列出，并验证嵌套限制；不能把表中任意语句放入任意作用域。

#### 2.4 表达式、访问操作与 bang operator

| 类别 | 代表形式 | 说明 |
|---|---|---|
| 字段与位访问 | `R.Value`、`Encoding{0}`、`Encoding{7...4}` | 读取字段或位段；范围方向影响位排列 |
| 列表索引与切片 | `Values[0]`、`Values[0,]`、`Values[0...2]` | 第一种返回元素，后两种返回列表；范围端点包含在切片内 |
| 名称、字符串或列表拼接 | `R#I`、`"add" # ".w"`、`[1] # [2]` | record 名中的未定义标识符、全局 `defvar` / `defset` 名按字面文本拼接；普通值表达式的右操作数也有此规则，局部迭代变量则取其值 |
| 算术、比较与位运算 | `!add(A, B)`、`!eq(A, B)`、`!and(A, B)`、`!shl(A, 1)` | 普通算术使用 bang operator；不能把 C/C++ 的 `A + B`、`A == B` 直接当作同等表达式 |
| 条件取值 | `!if(Cond, A, B)`、`!cond(CondA: A, true: B)` | 返回值；`!cond` 使用条件与值配对的语法 |
| 类型与存在性 | `!cast<int>(V)`、`!isa<C>(R)`、`!exists<C>(Name)`、`!initialized(V)` | 区分类型转换、类型判断、名字查询和未设值检查，分别写清参数要求 |
| 列表变换 | `!foreach(X, Values, !add(X, 1))`、`!filter`、`!foldl`、`!listconcat` | `!foreach` 构造列表；语句形式的 `foreach` 展开语句，二者结果不同 |
| 字符串处理 | `!strconcat`、`!subst`、`!substr`、`!repr` | 解释参数顺序、结果类型及错误情况 |
| DAG 构造与访问 | `(op Arg:$name)`、`!dag`、`!getdagarg`、`!getdagop` | DAG 的结构与标签是语言能力；`ins`、`outs`、`set` 等具体 record 的含义由 schema 和生成器定义 |
| 匿名 record 表达式 | `C<7>.Value` | 实例化匿名 record，再访问字段；可用于组织计算 |

完整 bang operator 清单引用 [语言参考附录 A](llvm/docs/TableGen/ProgRef.md#appendix-a-bang-operators)。正文按上表类别选取代表算子，说明签名、求值条件、类型限制和失败示例。

#### 2.5 带注释的最小语法示例

以下输入不依赖 LLVM 目标 schema，可单独保存为 `syntax.td`：

~~~tablegen
class Operation<int OpValue, string Text, int W = 32> {
  int Opcode = OpValue;
  bits<8> Encoding = OpValue;
  string AsmString = Text;
  bit Predicated = 0;
  int Width = W;
  int FieldNext = !add(Width, 1); // 依赖字段 Width
  int ParamNext = !add(W, 1);    // 依赖模板参数 W
  list<int> Widths = [W, 64];
  code Predicate = [{ return true; }];
}

def Basic : Operation<16, "add">;

let Width = 64 in
  def Wide : Operation<17, "add.w">;

def Named : Operation<Text = "sub", OpValue = 18> {
  let Encoding{3...0} = 5;       // 0x12 的低四位改为 0x5，结果是 0x15
  defvar Label = !strconcat(AsmString, ".local");
  string Description = Label;   // Description 是字段，Label 不是字段
  assert !gt(Width, 0), "Width must be positive";
}
~~~

预期观察：

| record | Opcode | Encoding（十六进制） | Width | FieldNext | ParamNext |
|---|---|---|---|---|---|
| Basic | 16 | 0x10 | 32 | 33 | 33 |
| Wide | 17 | 0x11 | 64 | 65 | 33 |
| Named | 18 | 0x15 | 32 | 33 | 33 |

`Wide` 中的字段引用在 `let` 覆盖之后消解，所以 `FieldNext` 为 65；模板参数 `W` 仍取默认值 32，所以 `ParamNext` 为 33。`Named.Description` 为 `"sub.local"`，最终 record 中不应出现 `Label` 字段。

负例：将 `Named` 的实参改为 `Operation<Text = "sub", OpValue = 18, W = 0>`，其 body 中的 `assert` 应报告 `Width must be positive`。正例及这个负例均已使用现有 build-debug 工具验证；其余语法类别的系统验证属于 E02-S。

复现命令：`./build-debug/bin/llvm-tblgen --print-records /path/to/syntax.td`，其中输入路径替换为实际保存位置；还可用 `--dump-json` 检查字段。位序列按位输出时，需要按位序解释成表中的十六进制数。

`multiclass`、`defm`、`foreach`、`NAME` 和外层 `let` 的组合示例见第 7.1 节：`ALU` 保存两个定义，循环分别传入 32 和 64，`defm ADD#W` 最终生成 `ADD32_rr`、`ADD32_ri`、`ADD64_rr`、`ADD64_ri` 四个 record。正文应逐步展示这些名称和字段如何形成。

#### 2.6 深入分析与验收

**问题**

- include 与词法预处理发生在哪里；错误位置如何保留？
- class 继承、模板参数、NAME、multiclass/defm、foreach、let 如何相互作用？
- 什么阶段仍是待展开条目，什么阶段已经生成具体 record？
- 字段引用、!add/!cast/!foreach 等运算何时求值；? 与类型错误有何区别？
- 本版本的 let append/prepend 等机制是否改变列表字段的组合方式？

**入口**

- [语言参考](llvm/docs/TableGen/ProgRef.md)。
- [TGLexer.cpp](llvm/lib/TableGen/TGLexer.cpp)。
- [TGParser.h](llvm/lib/TableGen/TGParser.h)、[TGParser.cpp](llvm/lib/TableGen/TGParser.cpp)：RecordsEntry、MultiClass、ForeachLoop、ParseDefm、ParseForeach、resolve、addDefOne。

**产出**：完整语法分类表、允许语句位置表、逐步展开示例及常见错误说明；每类示例同时给源码输入、最终 record、结果解释和一个失败变体。语法专题的必选覆盖项为第 2.1–2.4 节列出的类别；版本新增语法须标明静态核对与实际执行状态。

### 第 3 章：Record / Init 语义与数据管理

**问题**

- RecTy、RecordVal、Init、Record、RecordKeeper 分别表示什么？
- 类型转换、变量引用、字段引用、未设值、Resolver 如何协作？
- 记录、表达式节点、名字及集合由谁持有，生命周期和唯一化策略是什么？
- 前端允许交给 emitter 的记录是否仍可能含 ?；领域必填字段由谁检查？
- getAllDerivedDefinitions 等查询如何支撑 emitter；遍历顺序是否影响生成确定性？

**入口**

- [Record.h](llvm/include/llvm/TableGen/Record.h)、[Record.cpp](llvm/lib/TableGen/Record.cpp)。
- [JSONBackend.cpp](llvm/lib/TableGen/JSONBackend.cpp)、[DetailedRecordsBackend.cpp](llvm/lib/TableGen/DetailedRecordsBackend.cpp)。
- [SetTheory.cpp](llvm/lib/TableGen/SetTheory.cpp)。

**产出**：对象关系图、参数消解轨迹、未设值与后端约束对照；说明 JSON 可观察哪些信息、哪些信息需要跟踪内部对象。

### 第 4 章：从通用记录到 LLVM 目标描述

**问题**

- Instruction、RegisterClass、Operand、SubtargetFeature 等是通用语言内建，还是 .td schema？
- CodeGenTarget、CodeGenInstruction、CodeGenRegisters 如何验证并包装记录？
- 一个字段被哪些 emitter 读取，哪些字段直接保存为 C++ 代码片段？

**入口**

- [Target.td](llvm/include/llvm/Target/Target.td)。
- [CodeGenTarget.cpp](llvm/utils/TableGen/Common/CodeGenTarget.cpp)。
- [CodeGenInstruction.cpp](llvm/utils/TableGen/Common/CodeGenInstruction.cpp)。
- [CodeGenRegisters.cpp](llvm/utils/TableGen/Common/CodeGenRegisters.cpp)。
- [MSP430 指令描述](llvm/lib/Target/MSP430/MSP430InstrInfo.td)、[寄存器描述](llvm/lib/Target/MSP430/MSP430RegisterInfo.td)。

**产出**：选择 ADD16rr、GR16 等小样本，制作“schema 字段 → 领域对象 → 使用字段的生成器”矩阵。

### 第 5 章：指令、寄存器与 MC 的多种生成物

**问题**

- InstrInfo、RegisterInfo、AsmWriter、CodeEmitter、Disassembler 分别输出什么？
- GET_* 宏如何使同一个 .inc 在不同位置生成声明、枚举或实现？
- 编码位、操作数编码、fixup、汇编匹配和反汇编的手写边界在哪里？

**入口**

- llvm/utils/TableGen 下的 InstrInfoEmitter.cpp、RegisterInfoEmitter.cpp、AsmWriterEmitter.cpp、AsmMatcherEmitter.cpp、CodeEmitterGen.cpp、DisassemblerEmitter.cpp。
- [MSP430 生成规则](llvm/lib/Target/MSP430/CMakeLists.txt)。
- [MC 描述消费点](llvm/lib/Target/MSP430/MCTargetDesc/MSP430MCTargetDesc.cpp)、[编码器消费点](llvm/lib/Target/MSP430/MCTargetDesc/MSP430MCCodeEmitter.cpp)。
- [NVPTX 生成规则](llvm/lib/Target/NVPTX/CMakeLists.txt)，作为生成职责的边界对照。

**产出**：同一 record 的多个输出投影；两组单变量修改及产物差分。不得把生成编码函数等同于完整汇编器。

### 第 6 章：SelectionDAG 与 GlobalISel 模式生成

**问题**

- CodeGenDAGPatterns 怎样处理模式、类型约束、谓词与匹配顺序？
- SDAG matcher 如何构造、优化、压缩，再交给 SelectCode 消费？
- GlobalISel 如何导入已有 patterns；哪些规则被拒绝、忽略或需要自定义实现？
- GlobalISel selector 与 combiner 生成器有哪些共用基础设施和不同职责？

**入口**

- [CodeGenDAGPatterns.cpp](llvm/utils/TableGen/Common/CodeGenDAGPatterns.cpp)。
- DAGISelEmitter.cpp、DAGISelMatcherGen.cpp、DAGISelMatcherOpt.cpp、DAGISelMatcherEmitter.cpp，均位于 llvm/utils/TableGen/。
- [GlobalISelEmitter.cpp](llvm/utils/TableGen/GlobalISelEmitter.cpp)、[GlobalISelCombinerEmitter.cpp](llvm/utils/TableGen/GlobalISelCombinerEmitter.cpp)、llvm/utils/TableGen/Common/GlobalISel/。
- [AMDGPU 生成规则](llvm/lib/Target/AMDGPU/CMakeLists.txt)、[选择器](llvm/lib/Target/AMDGPU/AMDGPUInstructionSelector.cpp)。

**产出**：一条支持规则的生成与执行入口、一条无法导入规则的诊断、手写 matcher/谓词/renderer 的职责表。

特别记录：AMDGPU 常规生成输入为 AMDGPU.td；GlobalISel 使用 AMDGPUGISel.td 和 -gisel-extended-llt，以 CMake 中的具体动作组合为准。

### 第 7 章：调度模型与 intrinsic 生成

**调度问题**：Latency、资源占用、ReadAdvance、InstRW、variant class 如何进入 MCSchedModel，再被 TargetSchedModel 或 MCA 查询？

**intrinsic 问题**：模板源码、展开 record、生成枚举/属性表与 C++ 调用入口分别是什么；为什么 def 源码行数不能代表 intrinsic 数量？

**入口**

- [TargetSchedule.td](llvm/include/llvm/Target/TargetSchedule.td)、[CodeGenSchedule.cpp](llvm/utils/TableGen/Common/CodeGenSchedule.cpp)、[SubtargetEmitter.cpp](llvm/utils/TableGen/SubtargetEmitter.cpp)。
- [TargetSchedule.cpp](llvm/lib/CodeGen/TargetSchedule.cpp)、[MCA InstrBuilder.cpp](llvm/lib/MCA/InstrBuilder.cpp)。
- [IntrinsicEmitter.cpp](llvm/utils/TableGen/Basic/IntrinsicEmitter.cpp)、[CodeGenIntrinsics.cpp](llvm/utils/TableGen/Basic/CodeGenIntrinsics.cpp)、[Intrinsics.td](llvm/include/llvm/IR/Intrinsics.td)。

**产出**：字段到运行时查询的映射、一个调度负例、NVVM/AMDGPU intrinsic 数量的三口径对照。调度表提供模型数据，调度算法的决策逻辑需另找消费者解释。

### 第 8 章：Clang 的 schema 与生成代码

**主线**：NoInline 属性的拼写、Subjects、参数等记录如何变成 AST 类、实现及 parsed-attribute 检查；属性语义与 IR 属性设置还经过哪些手写代码？

**入口**

- [Clang 工具入口](clang/utils/TableGen/TableGen.cpp)：ActionType、ClangTableGenMain。
- [Attr.td](clang/include/clang/Basic/Attr.td)、[ClangAttrEmitter.cpp](clang/utils/TableGen/ClangAttrEmitter.cpp)。
- [AST 生成规则](clang/include/clang/AST/CMakeLists.txt)、[Sema 生成规则](clang/include/clang/Sema/CMakeLists.txt)。
- [Attr.h](clang/include/clang/AST/Attr.h)、[AttrImpl.cpp](clang/lib/AST/AttrImpl.cpp)、[ParsedAttr.cpp](clang/lib/Sema/ParsedAttr.cpp)、[CodeGenModule.cpp](clang/lib/CodeGen/CodeGenModule.cpp)。

**产出**：NoInline 的多产物链与 AST/LLVM IR 示例；诊断、内建函数、选项只先列生成动作和消费入口，扩展研究时再逐项闭环。

### 第 9 章：MLIR ODS、格式与 DRR

**问题**

- ODS 中的 operands/results/traits/interfaces 如何变成操作类和验证代码？
- declarative assembly format 的生成器怎样处理格式语义？
- hasFolder、hasCanonicalizer 生成了哪些声明，哪些实现仍需提供？
- DRR 怎样生成 RewritePattern；它与 LLVM 机器选指 pattern 有何不同？

**入口**

- [MlirTblgenMain.cpp](mlir/lib/Tools/mlir-tblgen/MlirTblgenMain.cpp)、[GenInfo.cpp](mlir/lib/TableGen/GenInfo.cpp)。
- [Operator.cpp](mlir/lib/TableGen/Operator.cpp)、[OpDefinitionsGen.cpp](mlir/tools/mlir-tblgen/OpDefinitionsGen.cpp)、[OpFormatGen.cpp](mlir/tools/mlir-tblgen/OpFormatGen.cpp)、[RewriterGen.cpp](mlir/tools/mlir-tblgen/RewriterGen.cpp)。
- [ArithOps.td](mlir/include/mlir/Dialect/Arith/IR/ArithOps.td)、[ArithCanonicalization.td](mlir/lib/Dialect/Arith/IR/ArithCanonicalization.td)、[ArithOps.cpp](mlir/lib/Dialect/Arith/IR/ArithOps.cpp)。
- [AddMLIR.cmake](mlir/cmake/modules/AddMLIR.cmake)。

**产出**：arith.addi 的声明/定义/注册链、AddIAddConstant 的 DRR 生成链；若运行 canonicalize，还需确认是否存在其他规则或 folding 路径可产生相同结果。

### 第 10 章：构建、诊断、测试与性能

**入口**

- [TableGen.cmake](llvm/cmake/modules/TableGen.cmake)：tablegen、add_public_tablegen_target、add_tablegen、宿主工具选择。
- [Error.cpp](llvm/lib/TableGen/Error.cpp)、[TGTimer.cpp](llvm/lib/TableGen/TGTimer.cpp)。
- llvm/test/TableGen/、llvm/unittests/TableGen/、Clang 属性生成测试及 MLIR tblgen 测试。

**研究项目**

1. include 变更如何进入 depfile，Ninja 如何决定重新生成和重新编译。
2. --write-if-changed 如何影响输出时间戳；多文件输出如何声明和追踪。
3. 类型错误、继承冲突、不可导入 pattern、非法调度描述分别在哪里被诊断。
4. 同一输入重复生成是否一致；记录顺序、命名、路径、版本和选项是否影响输出。
5. 使用 --null-backend 与 --time-phases 分离前端和 emitter 时间；分别记录冷/热运行、输入规模、展开 record 数和输出大小。

只对实际测量的输入给性能结论。Debug 与 Release 分开报告，不将一个目标的生成耗时外推到全部后端。

### 第 11 章：设计判断与自研编译栈适用性

建立决策表：数据表、验证代码、匹配规则、调度模型分别适合哪些描述方式；哪些状态化算法或复杂语义需要手写实现。

可选扩展：如需讨论昇腾/PyPTO/CANN，先确认输入描述格式、目标版本、构建链、消费者接口、可迁移字段与验证用例。迁移建议必须由一个小原型支撑；不根据 .td 行数比例推导工期、人员或后端代码量预算。该扩展不作为 TableGen 核心研究的完成门槛。

## 6. 实验矩阵与验收

| 编号 | 实验 | 输入与关键动作 | 验收证据 |
|---|---|---|---|
| E00 | 固定基线 | 三个工具的版本、SHA256、--help 与构建配置 | 能唯一标识工具和参数，不混用旧版本 |
| E01 | 记录展开 | 最小 multiclass + foreach + defm + let；print-records/dump-json | record 名称、数量和字段值符合预期；解释形成顺序 |
| E02 | 引用消解与错误 | 外层 let 改字段及依赖字段；? 对照错误类型 | 正例、未设值和错误类型有明确且不同的结果 |
| E02-S | .td 语法覆盖 | 第 2 章的类型、表达式、语句位置、预处理及版本新增语法 | 语法分类表逐项关联正例/负例；第 2.5 节字段结果与预期一致；记录工具支持范围 |
| E03 | 最小 emitter | 参考 TableGenBackendSkeleton；选择已有宿主注册点实现小型报告器 | 生成字段清单；缺失字段有诊断；若新增 C++，执行针对性构建与测试 |
| E04 | 一份目标记录、多种产物 | MSP430：instr-info/register-info/emitter/asm-writer/disassembler | 两种单变量变化对应到具体输出和 C++ 消费点 |
| E05 | SDAG/GISel 的共享与限制 | MSP430 简单 pattern；AMDGPU 双输入；SkippedPatterns.td | 一条支持规则和一条跳过规则，不以生成成功代替运行时正确 |
| E06 | 调度模型 | ResolveSchedClass.td；修改 Latency/资源/predicate；duplicate-instrw 负例 | 表项与 resolve 代码差分；定位 TargetSchedModel/MCA 查询 |
| E07 | NVPTX 职责对照 | NVPTX CMake 动作清单及选定 record | 列出实际生成物、消费点及未提供的机器码环节 |
| E08 | intrinsic 元编程 | NVVM/AMDGPU；展开记录与 -gen-intrinsic-enums | 分开报告模板源行、展开定义、生成枚举；说明分母 |
| E09 | Clang 属性 | NoInline；生成 class/impl/parsed-attr，观察 AST 和 IR | 追到手写语义与 IR 属性设置；提供错误适用对象的负例 |
| E10 | MLIR ODS/DRR | arith.addi、AddIAddConstant；op-decls/op-defs/rewriters | 操作注册、生成验证、手写实现和 rewrite 入口分别定位 |
| E11 | 构建依赖 | 临时小工程或样本副本；修改包含文件、比较 depfile/时间戳 | 重建范围与依赖声明一致；不改主工作区输入做实验 |
| E12 | 确定性与性能 | 固定参数重复生成；null-backend/time-phases | 保留原始数据，区分输出稳定性与跨版本语义兼容 |

E03 若新增 C++ emitter，须重建宿主工具；E04/E06 若验证运行时行为变化，须把生成物编入消费者。这些工作安排在基础分析之后。现有 build-debug 没有启用 MSP430；MSP430 的生成与源码追踪可直接进行，运行时实验须另行准备对应构建。

## 7. 可直接运行的起步命令

从仓库根目录执行；输出放入新建临时目录，不覆盖仓库源码或构建产物。

### 7.1 通用语言展开

~~~bash
TABLEGEN_WORK=$(mktemp -d /tmp/tablegen-study.XXXXXX)
TABLEGEN_BIN="$PWD/build-debug/bin/llvm-tblgen"

cat > "$TABLEGEN_WORK/expand.td" <<'TD'
class Op<int OpcodeValue, string AsmText> {
  int Opcode = OpcodeValue;
  string AsmString = AsmText;
  bit Predicated = 0;
}
multiclass ALU<int Base> {
  def _rr : Op<Base, "add.rr">;
  def _ri : Op<!add(Base, 1), "add.ri">;
}
foreach W = [32, 64] in {
  let Predicated = 1 in {
    defm ADD#W : ALU<W>;
  }
}
TD

"$TABLEGEN_BIN" --print-records "$TABLEGEN_WORK/expand.td" \
  -o "$TABLEGEN_WORK/expand.records"
"$TABLEGEN_BIN" --dump-json "$TABLEGEN_WORK/expand.td" \
  -o "$TABLEGEN_WORK/expand.json"

python3 - "$TABLEGEN_WORK/expand.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
expected = {"ADD32_rr": 32, "ADD32_ri": 33,
            "ADD64_rr": 64, "ADD64_ri": 65}
assert set(data["!instanceof"]["Op"]) == set(expected)
for name, opcode in expected.items():
    assert data[name]["Opcode"] == opcode
    assert data[name]["Predicated"] == 1
print("E01: four records and field values verified")
PY
~~~

后续在样本副本中改变 Base、let 或循环列表，每次只改一个因素。语法参数展开造成的名称变化和字段变化分别记录。

### 7.2 三条生成链的入口

沿用上一小节的 TABLEGEN_WORK，以下三个命令已做生成烟测：

~~~bash
./build-debug/bin/llvm-tblgen \
  -I llvm/include -I llvm/lib/Target/MSP430 \
  -gen-instr-info llvm/lib/Target/MSP430/MSP430.td \
  -o "$TABLEGEN_WORK/MSP430GenInstrInfo.inc"

./build-debug/bin/clang-tblgen \
  -I clang/include -I llvm/include \
  -gen-clang-attr-classes clang/include/clang/Basic/Attr.td \
  -o "$TABLEGEN_WORK/Attrs.inc"

./build-debug/bin/mlir-tblgen \
  -I mlir/include -I llvm/include \
  -gen-op-decls mlir/include/mlir/Dialect/Arith/IR/ArithOps.td \
  -o "$TABLEGEN_WORK/ArithOps.h.inc"
~~~

生成成功只说明对应工具能接受该输入和动作；后续实验还需检查产物内容和消费路径。

### 7.3 AMDGPU GlobalISel 待执行命令

选项与输入依据当前 CMake 核对，尚未在本方案编制中运行此完整生成：

~~~bash
./build-debug/bin/llvm-tblgen \
  -I llvm/include -I llvm/lib/Target/AMDGPU \
  -gen-global-isel -gisel-extended-llt -warn-on-skipped-patterns \
  llvm/lib/Target/AMDGPU/AMDGPUGISel.td \
  -o "$TABLEGEN_WORK/AMDGPUGenGlobalISel.inc"
~~~

保存 stderr 中的导入诊断。负例优先复用 llvm/test/TableGen/GlobalISelEmitter/SkippedPatterns.td 的 RUN 行，不自行假设复杂命令参数。

## 8. 推进顺序与并行安排

| 阶段 | 工作 | 前置条件 | 完成门槛 |
|---|---|---|---|
| P0 | 基线、输出目录、证据模板、E00/E01/E02 | 无 | 工具和源码关系写清；能解释一个完整展开样本 |
| P1 | 第 1–3 章：.td 语法、语言、数据模型、入口/注册；E02-S | P0 | 语法覆盖清单完整；调用图与源码一致；正例和负例均可复现 |
| P2-A | 第 4–7 章：LLVM 领域与目标生成 | P1 | 至少完成 MSP430、AMDGPU、NVPTX 三种取样职责 |
| P2-B | 第 8–9 章：Clang、MLIR | P1 | 各完成一条 schema 到消费端的链 |
| P2-C | 第 10 章：构建、诊断、确定性 | P1 | 完成依赖实验与一组可复现测量 |
| P3 | 交叉核对、解释边界；可选迁移原型评估 | 三条 P2 分支 | 同名概念、统计分母和生成/运行时边界一致 |
| P4 | 正文成稿与独立复核 | P3 | 第 9 节交付标准全部满足 |

P2 三条分支可以并行；公共术语、输入基线和工具版本由 P1 固定。某个运行时实验缺少对应工具时，记录具体缺口，保留已完成的生成与静态追踪结果，不将其标为运行时验证通过。

## 9. 交付物与质量标准

### 9.1 建议文件组织

~~~text
TableGen_Deep_Analysis_Plan.md        本方案
TableGen_Deep_Analysis.md             最终正文，后续研究完成后编写
TableGen-notes/
  00-baseline.md
  01-driver-bootstrap.md
  02-td-syntax-and-expansion.md
  03-record-model.md
  04-target-schema.md
  05-instruction-register-mc.md
  06-patterns-dag-gisel.md
  07-schedule-intrinsics.md
  08-clang.md
  09-mlir.md
  10-build-diagnostics-performance.md
  11-design-decisions.md
  12-repro-manual.md
  experiments/E00-.../
    input/                          原始输入及变体
    command.txt                     精确命令和工作目录
    result.json                     工具、退出码、校验和、状态
    stdout.txt / stderr.txt
    output/                         生成物或差分
~~~

以上为后续交付结构，本次只创建方案文档。

### 9.2 正文与证据验收标准

1. 按章节主题提供完整链条：语言与数据模型章节覆盖输入到 record；生成器专题覆盖输入字段 → 展开结果 → emitter 使用点 → 生成片段 → 消费入口；工程章节覆盖命令、依赖与产物。
2. 主要行为结论同时有源码依据与实验结果；只读源码得到的结论明确标记为静态分析。
3. 正例之外至少记录一个限制或负例，说明由哪个层次诊断或处理。
4. 区分“工具已生成”“C++ 已编入”“运行时已验证”三种状态。
5. 不以输出文件存在替代语义检查，不以多个输出相似推断消费行为相同。
6. 事实、基于源码的推断、待验证假设分开陈述；修订正文时同步更新素材和复现说明。
7. 统计如需加入，区分 .td 源行、展开 record 数、生成文件体积、工具耗时和运行时指标；给出脚本与适用范围。
8. 复现脚本保留完整路径并检查失败状态；异常文件和缺少的工具必须被报告，不能静默跳过。
9. .td 语法说明覆盖词法与预处理、类型、声明、作用域、表达式及 DAG；每项有语法形式和语义说明，区分通用语法与 LLVM/Clang/MLIR schema。

### 9.3 重点防止的误读

- .td 不仅用于描述指令；不同工具和 emitter 定义不同领域语义。
- class 名或字段名像“指令”“操作”不意味着它是语言内建概念。
- 模式能写进 .td，不保证能被某个 selector 导入，也不保证覆盖所有输入类型。
- 生成器输出 C++ 不意味着所有验证、语义或优化算法都由描述自动完成。
- 生成的寄存器表不等于运行了寄存器分配；调度表不等于调度算法。
- MLIR 的 ODS/DRR 不等同于 LLVM SelectionDAG/GlobalISel 的机器选指。
- 同一命令输出稳定，不保证不同工具版本的生成结果或运行语义不变。
- .td 行数占比不能直接推导描述工作量、运行时性能或新后端预算。

## 10. 本次编制已完成的检查

| 检查 | 状态 | 可支持的结论 |
|---|---|---|
| 源码入口、CMake 和主要消费者路径 | 已核对 | 本方案阅读入口存在；三种工具的注册机制需分别研究 |
| 两个构建目录的 tblgen 版本 | 已验证 | build-shared 为 19.1.7；build-debug 为 24.0.0git |
| 第 7.1 节展开示例 | 已验证 | 四个目标 record 的名字、Opcode 和 Predicated 值符合断言 |
| 第 2.5 节 .td 语法示例及 W = 0 变体 | 已验证，分别退出 0 和 1 | 三个 record 的字段、位段覆盖及局部变量行为符合预期；Named 中的 assert 能诊断无效宽度 |
| .td 主要语法类别与版本新增语法 | 已按本地语言参考和相关解析器核对；E02-S 全覆盖待执行 | 区分通用语法与 schema；未将全部语法写成已通过运行验证 |
| 模板 int 参数传 string 的负例 | 已验证，退出码 1 | 通用前端报告类型不兼容；不能据此推断所有领域约束均由前端检查 |
| MSP430 指令信息生成 | 已验证，退出码 0 | 当前输入和生成动作可运行 |
| Clang 属性类生成 | 已验证，退出码 0 | 当前 Attr.td 和生成动作可运行 |
| MLIR Arith 操作声明生成 | 已验证，退出码 0 | 当前 ODS 输入和生成动作可运行 |
| 全部 emitter 分析、运行时差分、性能与迁移研究 | 待执行 | 本方案未宣称已完成这些研究 |

原始准备产物位于本机临时目录，只用于检查方案示例。正式执行 P0 时，应将命令、输入和结果按第 9 节结构归档，再用于最终分析正文。
