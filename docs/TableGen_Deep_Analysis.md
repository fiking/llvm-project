# TableGen 深度分析

> 源码基准：llvm-project HEAD `3eda2aebadd4`（main）。
> 工具基线：`build-debug/bin/`（LLVM 24.0.0git，Debug + Assertions）。
> 配套材料：`TableGen_Deep_Analysis_Plan.md`（研究方案）、`TableGen-notes/`（实验记录与原始数据）。
>
> 验证状态约定：**【实验】**＝在本机以基线工具运行并核对输出；**【静态】**＝仅阅读源码/构建脚本得出，未运行对应路径；**【未验】**＝明确未覆盖。行号随源码漂移，以符号名为主要锚点。

---

## 第 1 章 定位、驱动与构建引导

### 1.1 TableGen 是什么、不是什么

TableGen 是 LLVM 的"记录生成器"：读取 `.td` 描述文件，展开为具体的 **record** 集合，再由不同的 **emitter**（后端动作，形如 `-gen-instr-info`）把同一份记录投影成不同的 C++ 文本产物（`.inc` 文件、JSON、文档等）。

理解全局必须先分清**三个时刻**：

1. **TableGen 运行时**：`.td` → record → `.inc`。本文第 1–3 章。
2. **C++ 构建时**：`.inc` 被 `#include`、编译、链接。第 5、8、9、10 章的 GET_* 宏与 CMake 部分。
3. **编译器运行时**：算法读取生成表。第 6、7 章的消费点。

修改 `.td` 重新生成 `.inc`，只验证了第 1 层。若不把产物重新编入消费者并运行，不能宣称验证了新的选指、编码或调度行为。本文所有实验均明确标注所处层次。

第二个关键分界：**通用语言前端 vs 领域 schema**。

- 前端（`llvm/lib/TableGen/`）只知道类型、表达式、class/def/multiclass 这些语言概念，把任何 `.td` 展开成 record 集合（`RecordKeeper`）。
- `Instruction`、`RegisterClass`、`Attr`、`Pat` 这些"像内建"的概念**全部是 .td 里定义的普通 class**（schema），其语义由 C++ 侧代码通过字符串匹配获得。例如 `CodeGenTarget.cpp:81` 用 `Records.getAllDerivedDefinitions("Target")` 找目标记录，`CodeGenInstruction.cpp:87` 用 `Rec->isSubClassOf("RegisterOperand")` 判断操作数种类。前端对 "Instruction" 一无所知。

这意味着：同一份记录为什么能生成指令信息、寄存器信息、匹配表、编码器或文档——因为 emitter 是独立的消费者，各自读取自己关心的字段并忽略其余。**schema 即接口**：给 `.td` 加一个字段，只需同时修改读取它的 C++ 代码，前端不需要变。

### 1.2 工具家族与入口链路【静态】

仓库构建产生 6 个相关工具（本机 `build-debug/bin/`）：

| 工具 | 角色 |
|---|---|
| `llvm-tblgen` | LLVM 后端全部生成器（50+ emitter） |
| `llvm-min-tblgen` | 裁剪版，只够生成 `llvm/include` 公共头（自举用） |
| `clang-tblgen` | Clang 属性/诊断/内建函数等 |
| `mlir-tblgen` | MLIR ODS/DRR/接口等 |
| `tblgen-lsp-server` | .td 语言服务器 |
| `tblgen-to-irdl` | .td → IRDL 转换 |

三种主工具的入口走同一条通用驱动，但**动作注册机制各不相同**（这是三者的核心架构差异）：

```
main()                                    # llvm/utils/TableGen/llvm-tblgen.cpp:18（一行）
└─ tblgen_main()                          # llvm/utils/TableGen/Basic/TableGen.cpp:72
   └─ llvm::TableGenMain(argv0, MainFn)   # llvm/lib/TableGen/Main.cpp:140
      ├─ 读文件 → 全局 SrcMgr               # :150-159（支持 stdin）
      ├─ TGParser(SrcMgr, MacroNames, Records, …).ParseFile()   # :166-168
      ├─ if (ErrorsPrinted > 0) return 1   # :174（assert 等非致命错误在此汇总退出）
      ├─ TableGen::Emitter::ApplyCallback(Records, OutFiles, stem)  # :178-188 分发 emitter
      ├─ -d ⇒ createDependencyFile        # :194-197（总写 depfile，Ninja 视缺失为 dirty）
      └─ WriteOutput（--write-if-changed）  # :199-211（内容一致不覆盖；出错不 keep）
```

- **llvm-tblgen**：每个 emitter 在自己的 .cpp 顶层定义静态 `TableGen::Emitter::Opt` 对象，构造时向全局 `ManagedStatic<cl::opt<FnT>>` 注册一个字面量命令行选项（`llvm/include/llvm/TableGen/TableGenBackend.h:53`，`llvm/lib/TableGen/TableGenBackend.cpp:53-59`）。链接哪些 .cpp，就有哪些 `-gen-*`。内置动作（`print-records` 默认、`print-detailed-records`、`null-backend`、`dump-json`、`print-enums`、`print-sets`）集中在 `Basic/TableGen.cpp:58-70` 的静态数组。
- **clang-tblgen**：集中式。`clang/utils/TableGen/TableGen.cpp:25-131` 一个约 60 项的 `enum ActionType`，`:383 ClangTableGenMain` 一个巨型 switch 分发；`:708 main()` 把回调传给通用 `TableGenMain`。新增 emitter 必须改这个文件。
- **mlir-tblgen**：分布式。`mlir/lib/TableGen/GenInfo.cpp:17-22` 全局 `generatorRegistry` vector；每个 emitter .cpp 顶层 `static mlir::GenRegistration gen("gen-op-decls", …)` 静态注册。`MlirTblgenMain.cpp:139-164` 只有 `cl::opt<const GenInfo*>`。新增 emitter 不改主驱动，链接即生效。

回调签名有两种形态（`TableGenBackend.h:30-47` 的 `FnT`）：单文件 `void(const RecordKeeper&, raw_ostream&)`，或多文件 `TableGenOutputFiles(StringRef FilenamePrefix, const RecordKeeper&)`。`-gen-register-info` 用后者——一次运行拆出 Enums/Header/MCDesc/TargetDesc 四个文件（第 5 章 E04 实测：手工直跑时主输出只有 535 字节的宏分发骨架，实际内容在四个拆分文件里）。

库内嵌入式入口是 `llvm/lib/TableGen/Parser.cpp:17-43` 的 `TableGenParseFile(SourceMgr&, RecordKeeper&)`——供 MLIR 等在库内复用解析，**不是 CLI 的必经中间层**。

### 1.3 构建引导与宿主工具【静态】

`llvm/utils/TableGen/CMakeLists.txt`：

- `llvm-min-tblgen`（:19-24）只链接 `obj.LLVMTableGenBasic`，**不依赖** `TableGenCommon`。注释（:11-18）说明原因：TableGenCommon 自己需要用 min-tblgen 生成 ValueType 等定义——这是一个最小自举环。
- `llvm-tblgen`（:31-83）链接 Basic + Common + 全部 emitter，且 `DEPENDS intrinsics_gen`（该 target 本身由 min-tblgen 生成）。

交叉编译与加速场景下的宿主工具选择（`llvm/cmake/modules/TableGen.cmake`）：

- `LLVM_NATIVE_TOOL_DIR`（`llvm/CMakeLists.txt:858`）：指向预构建的原生工具目录。
- `LLVM_USE_HOST_TOOLS`（:1009-1012）：交叉编译、或 `LLVM_OPTIMIZED_TABLEGEN` +（断言开启/多配置/ sanitizer）时置 ON，经 `llvm/cmake/modules/CrossCompile.cmake` 起一个 Release 的 NATIVE 子构建，产出的宿主 tblgen 供主构建使用。`LLVM_OPTIMIZED_TABLEGEN` 的意义：调试构建编译器时仍让 tblgen 跑得快（它是纯构建期工具）。
- `CLANG_TABLEGEN_EXE`、`MLIR_TABLEGEN` 等变量以同样机制提升为 cache 变量（`clang/CMakeLists.txt:542-553`、`mlir/CMakeLists.txt:244-257`）。

`tablegen()` 函数（`TableGen.cmake:7`）的核心职责：组装 `-I` include 列表（:21-25）、在 Ninja+CMP0116 下传 `-d ${ofn}.d` 生成 depfile（:36-56，否则回退 `file(GLOB …)` 全量 .td 依赖）、非 VS 生成器下传 `--write-if-changed`（:89-96）、为 `-gen-register-info` 声明 4 个 `EXTRA_OUTPUTS`（:70-77），最后用 `add_custom_command` 产出 `${CMAKE_CURRENT_BINARY_DIR}/${ofn}`（:141-157）。`add_public_tablegen_target()`（:168-180）把某目录下全部生成物聚成一个 target，挂入 `LLVM_COMMON_DEPENDS`。

---

## 第 2 章 .td 语法、语言语义、展开顺序与作用域

本章先给可直接使用的语法说明（2.1–2.4），再给带实测结果的展开分析（2.5–2.6）。准确文法以 `llvm/docs/TableGen/ProgRef.md` 与解析器为准；此处按当前源码核对并做了代表性运行。

### 2.1 文件结构、词法与预处理

- **注释**：`//` 行注释；`/* … */` 块注释，支持嵌套。
- **标识符**：区分大小写；`NAME` 是隐式模板参数（class 与 multiclass 内均有效）；`$src` 形式的名字是 DAG 节点或参数标签；`code` 等保留字不能作普通标识符。
- **包含**：`include "Common.td"` 在词法层引入文件，末尾不写分号；搜索路径由 `-I` 控制。
- **分隔符**：字段声明与多数语句以 `;` 结束；record 空体可写 `;`，非空体 `{ … }`；模板实参用 `<…>`。
- **条件预处理**：`#define`、`#ifdef`、`#ifndef`、`#else`、`#endif`，行首起（可带前导空白）。**宏只表示"是否定义"，没有 C 式值替换，也没有函数宏**；命令行 `-DNAME` 等效于文件内 `#define NAME`。

预处理完全在词法层消化【静态】：`TGLexer` 内部维护 `DefinedMacros`（`TGLexer.h:275`）与条件栈 `PrepIncludeStack`（:294-327，外层是 include 栈帧、内层是该文件的 #ifdef 栈，因此禁止 #ifdef 跨文件不闭合）。`include` 由 `LexInclude`（`TGLexer.cpp:469-497`）处理：切换 buffer、记录进 `Dependencies`（depfile 的数据源）。Parser 看到的 token 流已经没有预处理痕迹。注意 `#` 在非行首是**拼接操作符**（见 2.4）。

```tablegen
#ifdef ENABLE_EXTRA
def Extra;
#else
def BasicOnly;
#endif
```

### 2.2 类型、字面量与未设值

| 类型或形式 | 示例 | 语义与约束 |
|---|---|---|
| `bit` | `bit Enabled = 1;` | 单个布尔位；`true`/`false` 可用 |
| `bits<n>` | `bits<8> Encoding = 0x2A;` | 定长位序列；可逐位或按位段读写 |
| `int` | `int Width = 32;` | 64 位整数；十进制、`0x`、`0b` 字面量 |
| `string` | `string Name = "add";` | 字符串；相邻字面量可连接 |
| `code` | `code Body = [{ return true; }];` | `string` 别名；`[{ … }]` 保留多行文本，前端**不执行**其中的 C++ |
| `list<T>` | `list<int> W = [32, 64];` | 同构列表；索引从 0 开始 |
| class 名作类型 | `OperandKind Src = Reg;` | `Reg` 必须是派生自 `OperandKind` 的 record |
| `dag` | `dag In = (ins Reg:$src);` | 操作符+参数；操作符须为 record；标签含义由消费者解释 |
| 未设值 `?` | `int X = ?;` | 字段未初始化。`UnsetInit` **不完整**（`isComplete()=false`）但仍是 **concrete**（`isConcrete()=true`），因此普通字段保留 `?` 可以正常实例化落地（实测：`class C { int V = ?; } def Good : C;` 退出码 0）。是否必须赋值由读取该字段的具体 emitter 决定 |

三类括号务必分清：`{1,0,1}` 是位序列字面量、`[1,0,1]` 是列表、`(op …)` 是 DAG——它们分属 `BitsInit`/`ListInit`/`DagInit` 三种值（第 3 章）。

### 2.3 主要语句与作用域

| 语句 | 形式 | 语义要点 |
|---|---|---|
| `class` | `class C<int V, string S = "x"> { int Value = V; }` | 抽象模板；参数有类型、可有默认值，必填参数须在可选参数之前 |
| 继承 | `def R : C<7>, Other;` / `C<V = 7>` | 多继承；位置实参须在前，命名实参在后，同一参数不可重复指定 |
| `def` | `def R : C<7>;` / `def R : C<7> { let Value = 8; }` | 创建具体 record；匿名 def 的名字（`anonymous.N`）不是稳定接口 |
| record 内 `let` | `let Value = 9;`、`let Encoding{3...0} = 5;` | 覆盖已有字段或位段；不能改模板参数（参数在实例化时已替换，见 2.5 实测） |
| 外层 `let` | `let Value = 9 in { def R : C<7>; }` | 对作用域内全部定义统一覆盖（覆盖的是字段名，不是模板参数） |
| `multiclass` | `multiclass M<int V> { def _a : C<V>; }` | 可复用的定义组；可继承其他 multiclass |
| `defm` | `defm P : M<7>;` | 展开 multiclass；**不创建名为 P 的容器 record**（实测 2.5）；defm 自身没有 body |
| `defvar` | `defvar N = !add(1, 2);` | 类型推导变量；同作用域不可重赋值；record 内的 defvar **不成为字段**（实测） |
| `foreach` | `foreach I = [0,1] in { def R#I : C<I>; }` | 展开语句；迭代变量每轮独立；也支持范围 `0...3` |
| `if` | `if !eq(N,3) then { def A; } else { def B; }` | 条件展开语句；内部被去糖为无迭代变量的 foreach【静态：TGParser.h:74-77】 |
| `defset` | `defset list<C> G = { def A : C<1>; }` | 定义并收集 record 到列表；表达式内匿名 record 不入集 |
| `deftype` | `deftype Index = int;` | 顶层类型别名；当前解析器拒绝给 record class 类型建别名 |
| `assert` | `assert !gt(N,0), "msg";` | 失败即诊断；求值时机依位置而定（实测 2.5 负例） |
| `dump` | `dump !repr(N);` | 调试输出（note 级） |

三项细节：

1. **`NAME` 与自动前缀**：`NAME` 同时存在于 class 和 multiclass 中，是隐式模板参数，**绑定到实例化后的 record 名**（不是定义它的 class 名）。实测【实验】：`class C { string N = NAME; } def D : C;` 的 `--print-records` 输出 `D.N = "D"`——class 内的 `NAME` 引用在实例化时解析为最终 def 名。multiclass 内的具名 def/defm 若名字不含 `NAME`，最终名 = defm 名 + 原名字，例如 `defm ADD : Arith<…>` 展开 multiclass 中的 `def 16rr` 得到 `ADD16rr`（MSP430 真实案例，见第 5 章）。实现：`TGParser.cpp:138 QualifiedNameOfImplicitName` 与 `:691` 把 `NAME` 绑定加入替换栈。官方语言参考（ProgRef）对 class 与 multiclass 两种情形都规定了此语义。
2. **`let append` / `let prepend`**：对 `list<T>` 用列表连接、对 `string`/`code` 用字符串连接、对 `dag` 用 DAG 连接；值为 `?` 时直接设为新值。实现：`LetMode{Replace,Append,Prepend}`（`TGParser.h:34`）与 `SetValue`（`TGParser.cpp:241-346`）。注意旧版本工具可能不支持，跨版本使用时需验证。
3. **语句位置限制**【静态：`ParseObject`，TGParser.cpp:4720-4758】：multiclass 内禁止 `class`/`defset`；foreach 内禁止 `class`/`multiclass`。嵌套规则不能凭直觉外推。

### 2.4 表达式、访问操作与 bang operator

普通算术**不是** `a + b`，而是 bang operator `!add(a, b)`。代表类别（完整清单见语言参考附录 A）：

| 类别 | 形式 | 说明 |
|---|---|---|
| 字段/位访问 | `R.Value`、`Encoding{0}`、`Encoding{7...4}` | 位段方向决定位序 |
| 列表索引/切片 | `V[0]`、`V[0,]`、`V[0...2]` | 前者得元素，后两者得列表；端点含于切片 |
| 拼接 `#` | `R#I`、`"add"#".w"`、`[1]#[2]` | record 名拼接取字面文本；值表达式右操作数有同样规则，迭代变量取其值 |
| 算术/比较/位运算 | `!add !sub !mul !eq !lt !and !shl …` | 返回新值，不求副作用 |
| 条件取值 | `!if(c,a,b)`、`!cond(c1:v1, true:v2)` | 表达式级条件（区别于语句级 if） |
| 类型与查询 | `!cast<int>(V)`、`!isa<C>(R)`、`!exists<C>("n")`、`!initialized(V)` | 转换/判定/名字查询/未设值检查 |
| 列表变换 | `!foreach(x,list,e)`、`!filter`、`!foldl`、`!listconcat` | 表达式级列表构造，不同于语句级 foreach |
| 字符串 | `!strconcat !subst !substr !repr` | `!repr` 给出值的文本表示 |
| DAG | `(op a:$x)`、`!dag`、`!getdagarg`、`!getdagop` | `ins`/`outs`/`set` 等算子的含义由 schema 定义，不在前端 |
| 匿名实例化 | `C<7>.Value` | 现场实例化并取字段 |

求值模型【静态 + 实测】：解析期**就会尝试折叠**——TGParser 在构造表达式节点时直接调用各节点的 `Fold()`（`Record.cpp:762/1208/1730`），因此未实例化的 class 中 `!add(1,2)` 已折叠为常量 `3`（实测：`class D { int V = !add(1,2); }` 的 `--print-records` 直接输出 `int V = 3`）。含未解析引用（模板参数、字段名）的表达式无法完全折叠，保留为节点；这些节点在参数替换、字段引用消解（`resolveReferences` 链）时被**继续**折叠。所以正确模型是：**解析时尽力折叠，消解时继续折叠**——不是"解析期不求值、之后统一求值"。下一节的实测展示了字段引用晚于模板参数消解的可观察后果。

### 2.5 带实测的展开分析【实验 E01/E02】

**E01：multiclass + foreach + defm + let 组合**（`TableGen-notes/experiments/E01-expand/`）：

```tablegen
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
```

`--print-records` 与 `--dump-json`（python 断言复核）结果：恰好 4 个 def——`ADD32_rr(Opcode=32)`、`ADD32_ri(33)`、`ADD64_rr(64)`、`ADD64_ri(65)`，且全部被外层 `let` 置为 `Predicated=1`。关键观察：

- class `Op` 只出现在 "Classes" 段，不产生 def；
- multiclass `ALU` 不产生任何 record；`defm ADD32` 也不产生名为 `ADD32` 的容器 record——最终只有叶子 def；
- `W` 是 foreach 迭代变量，`ADD#W` 在展开时按值拼进名字。

机制锚点【静态】：名字前缀来自 `TGParser.cpp:138 QualifiedNameOfImplicitName` + `:691`（defm 名绑进 `NAME` 替换）；foreach 展开在 `TGParser.cpp:468 resolve(const ForeachLoop&, …)`：迭代变量经 `MapResolver` 绑定后递归 resolve 子条目；外层 let 由 `ParseTopLevelLet`（:4447）压栈、`ApplyLetStack`（:3922）在 record 落地时统一 `SetValue`；最终落地走 `addDefOne`（:586-631）：最终 resolve → `checkConcrete` → `checkRecordAssertions` → `emitRecordDumps` → `Records.addDef`。

**E02：字段引用与模板参数的消解时机不同**（`experiments/E02-resolve/`）：

```tablegen
class Operation<int OpValue, string Text, int W = 32> {
  int Opcode = OpValue;
  bits<8> Encoding = OpValue;
  int Width = W;
  int FieldNext = !add(Width, 1);   // 引用字段
  int ParamNext = !add(W, 1);       // 引用模板参数
  …
}
def Basic : Operation<16, "add">;
let Width = 64 in
  def Wide : Operation<17, "add.w">;
def Named : Operation<Text = "sub", OpValue = 18> {
  let Encoding{3...0} = 5;
  defvar Label = !strconcat(AsmString, ".local");
  string Description = Label;
  assert !gt(Width, 0), "Width must be positive";
}
```

实测（`--print-records`）：

| record | Opcode | Encoding | Width | FieldNext | ParamNext | Description |
|---|---|---|---|---|---|---|
| Basic | 16 | 0x10 | 32 | 33 | 33 | — |
| Wide | 17 | 0x11 | 64 | **65** | **33** | — |
| Named | 18 | **0x15** | 32 | 33 | 33 | "sub.local" |

三条结论，每条都有直接证据：

1. **字段引用在 let 覆盖之后消解**：`Wide` 的外层 `let Width = 64` 生效后，`FieldNext = !add(Width, 1)` 消解为 65。
2. **模板参数在实例化时即被替换**：`Wide` 的 `ParamNext = !add(W, 1)` 仍为 33——`W` 是参数，不受后续 let 影响（let 只能覆盖字段，不能改参数）。
3. **位段覆盖作用于实例化后的值**：`Named` 的 `let Encoding{3...0} = 5` 把 0x12 的低 4 位改成 0x5，得 0x15。record 内 `defvar Label` 确实**没有**成为字段，而引用它的 `Description` 得到值 `"sub.local"`。

**负例**（`wzero.td`，`W=0` 触发 class body 内 assert）实测退出码 1：

```
wzero.td:6:10: error: assertion failed: Width must be positive
wzero.td:8:5:  error: assertion failed in this record
```

诊断带精确行列。求值时机【静态】：`addDefOne`（`TGParser.cpp:609`）→ `Record::checkRecordAssertions`（`Record.cpp:3087`，用 `RecordResolver` + `setFinal(true)` 强制完全消解）→ `CheckAssert`（`Error.cpp:163`）。assert 失败是非致命的——计入 `ErrorsPrinted`，由 `Main.cpp:174` 统一以退出码 1 结束。

### 2.6 展开顺序总图

```
词法（含预处理、include 栈）            TGLexer
  → 语法分析 + 尽力折叠                   TGParser::Parse*（构造表达式节点时即调用 Fold）
  → 模板实参替换 / foreach 迭代变量绑定   resolve(ForeachLoop) + MapResolver
  → 字段引用消解（最终 record 上下文）    Record::resolveReferences（Record.cpp:2833）
     └─ 消解过程中继续折叠残留表达式      各 OpInit::Fold（沿 resolveReferences 链）
  → 落地检查                            checkConcrete / checkRecordAssertions
  → RecordKeeper（按名字字典序的 std::map）
```

注意：折叠不是独立的"求值阶段"，而是伴随解析与消解两个时刻反复进行——常量尽早折叠，依赖未解析引用的表达式留到引用可得时再折叠。

"何时是什么"的边界：**局部解析与展开是交错进行的**，不存在"ParseFile 之后再统一展开"的独立阶段。具体说：multiclass/foreach 的**体**在解析时先存为 `RecordsEntry` 待展开条目（`TGParser.h:56-88`），而该 multiclass/foreach 的**实例化点**（`defm`、外层 foreach 迭代）出现时，条目就地展开、`addDefOne` 产出具体 record，随后解析继续——同文件后面的语句可能已经引用刚展开的 def。因此 `ParseFile` 成功返回时，交给 emitter 的 RecordKeeper 里**所有 defs 都已完成展开与消解**（`Record::resolveReferences` 已在每个 def 落地时跑过）。

---

## 第 3 章 Record / Init 语义与数据管理

### 3.1 类型系统（RecTy）【静态】

`llvm/include/llvm/TableGen/Record.h:63` 的 `RecTy` 是类型基类，子类：`BitRecTy`（:115，单例）、`BitsRecTy`（:133，带位宽）、`IntRecTy`（:154）、`StringRecTy`（:172）、`ListRecTy`（:191，持元素类型）、`DagRecTy`（:215）、`RecordRecTy`（:234，FoldingSet 唯一化，持非冗余超类数组）。

赋值合法性由两个谓词判定：`typeIsConvertibleTo`（:99）与 `typeIsA`（:103）。实际入口在值一侧：`RecordVal::setValue`（`Record.cpp:2737`）先调 `V->getCastTo(getType())`，失败即报类型错误。**实测负例**（模板 int 参数传 string，方案第 10 节已验证退出码 1）就是在这一层被通用前端诊断的——不需要任何领域知识。

### 3.2 值系统（Init）【静态】

`Init`（`Record.h:288`）是所有值的基类，约 25 个子类。按角色分组：

- **叶子**：`UnsetInit`（:455，单例，`isComplete()=false`——`?` 的表示）、`BitInit`、`BitsInit`、`IntInit`、`StringInit`（区分 string/code 格式）、`AnonymousNameInit`（匿名 def 名，由 `RecordKeeper::getNewAnonymousName()` 递增产生）。
- **引用**：`VarInit`（变量引用）、`VarBitInit`（`x{3}`）、`FieldInit`（`X.y`，构造时经 `getFieldType` 推导类型）、`DefInit`（指向具体 Record）。
- **运算**：`UnOpInit`（CAST/HEAD/TAIL/SIZE/REPR/GETDAGOP/INITIALIZED…）、`BinOpInit`（ADD/…/STRCONCAT/CONCAT/EQ/…）、`TernOpInit`（SUBST/FOREACH/IF/DAG/RANGE…）、`CondOpInit`、`FoldOpInit`、`IsAOpInit`、`ExistsOpInit`、`VarDefInit`（`C<args>` 匿名实例化表达式，Fold 时真正实例化）。
- **结构**：`ListInit`、`DagInit`（TrailingObjects 存参数与标签）。

`resolveReferences(Resolver&)` 是核心虚函数：**不就地修改**，按名字映射生成新子树。Resolver 层级（`Record.h:2233-2350`）：`MapResolver`（显式映射，解析器的替换栈载体）、`RecordResolver`（从 Record 字段解析）、`ShadowResolver`（屏蔽名字）、`TrackUnresolvedResolver`/`HasReferenceResolver`（诊断）。

这里有三件**相互独立**的事，常被混为一谈，分开说：

1. **`isFinal()` 标志**（Resolver 基类）：控制"未消解引用是否报错"。`Record::resolveReferences`（`Record.cpp:2880`）对每个 def 的最终消解设 `setFinal(true)`；assert 检查同样用 final 模式（`Record.cpp:3089`，第 2 章负例的诊断由此产生）。final 模式下仍无法消解的引用会报错。
2. **`keepUnsetBits()`**：`RecordResolver` 返回 true，作用于 **BitsInit 的逐位消解**（`Record.cpp:542-543`）：某位消解结果是 `UnsetInit` 时**保留原位不动**（变量位如 `rs`/`rd` 的位引用就此留下），这是指令编码字段可以把未指定位带到后端的原因——它豁免的是"位被 unset 覆盖"，不是允许 `?` 落地（`?` 落地本来就合法，见 2.2/3.3）。
3. **完整性与 nonconcrete 检查**：`?`（`UnsetInit`）`isComplete()=false` 但 `isConcrete()=true`，因此普通字段保留 `?` 完全合法。真正被 `checkConcrete`（`TGParser.cpp:98`，def 实例化时调用）拒绝的是**非 concrete** 的初始化器（含无法消解的 VarInit 等）；`field` 声明（FK_NonconcreteOK）豁免的正是这一项——源码注释说明这是为既有 target 的 helper def 留的口子。

### 3.3 Record、RecordKeeper 与确定性【静态 + 实验 E12】

- `RecordVal`（`Record.h:1575`）：名字 + 类型 + 值 + `FieldKind{FK_Normal, FK_NonconcreteOK, FK_TemplateArg}`。注意普通字段（FK_Normal）就可以保留 `?`（`UnsetInit` 是 concrete 的，见 3.2）；`field` 声明（FK_NonconcreteOK）豁免的是 `checkConcrete` 对**非 concrete** 初始化器（如无法消解的引用）的检查，与 `?` 无关。
- `Record`（:1663）：`RecordKind{RK_Def, RK_AnonymousDef, RK_Class, RK_MultiClass}`；每个对象有唯一递增 ID（`getNewUID`，`Record.cpp:2813`）；拷贝构造分配新 ID（multiclass 展开靠拷贝构造）。
- `Record::resolveReferences`（`Record.cpp:2833-2882`）：先消解名字（变化则以新名重新注册），再逐字段 `setValue(V->resolveReferences(R))`，最后处理 assertions/dumps。
- `RecordKeeper`（`Record.h:2011`）：`RecordMap = std::map<std::string, unique_ptr<Record>>`——**按名字字典序**，故 `getClasses()`/`getDefs()` 遍历顺序稳定。`getAllDerivedDefinitions`（`Record.cpp:3153-3191`）对结果再 `llvm::sort(Defs, LessRecord())`（`compare_numeric` 自然字典序），并带 per-class 缓存。
- 唯一化：`detail::RecordKeeperImpl`（`Record.cpp:53-100`）集中所有 FoldingSet 池（Bits/List/UnOp/BinOp/TernOp/Dag/RecordRecTy/String/Var…）。所有 `Init::get(...)` 工厂先进池——**指针相等即值相等**，后端可用指针比较做快速判等，也控制了内存占用。

**确定性【实验 E12】**：对 MSP430.td 连续两次 `-gen-instr-info`，产物 SHA256 完全相同（`772cbc0f…`）。确定性来源有三：`std::map` 字典序、`LessRecord` 排序、以及（intrinsic 场景）record ID 作为排序 tie-breaker（`CodeGenIntrinsics.cpp:96-100`）。注意这只保证**同一工具同一输入**输出稳定；不同版本工具的生成物可能不同（版本锁定见第 10 章）。

### 3.4 可观察性：`--print-records` 与 `--dump-json`

- `--print-records`（`Record.cpp:3141 dumpRecords`）：按字典序输出 class 与 def，表达式以文本形式打印（E01/E02 使用）。
- `--dump-json`（`llvm/lib/TableGen/JSONBackend.cpp:118-180`）：每个 def 输出 `!name/!superclasses/!fields/!locs` + 各字段值；`DagInit` 序列化为 `{kind:"dag", operator, args}`；`!instanceof` 给出 class → 实例数组（E01 用它做断言）。
- `--print-detailed-records`（`DetailedRecordsBackend.cpp`）：额外有 defm 列表与分配统计。

JSON 的边界：它**能**表达保留的引用——`VarInit` 序列化为 `{kind:"var", var:名字}`、`VarBitInit` 为 `{kind:"varbit", var, index}`（`JSONBackend.cpp:79-86`），无法结构化表达的表达式回落为 `{kind:"complex", printable:…}`（:111-114）。真正的限制是**指针身份、所有权、对象图关系**无法从 JSON 观察——这些只能在 C++ 内访问（或写自定义 emitter，见第 11 章）。

### 3.5 SetTheory【静态】

`llvm/lib/TableGen/SetTheory.cpp`（接口 `SetTheory.h:65-141`）把 DAG 表达式求值为**有序 record 集合**：内置算子 add/sub/and/shl/trunc/sequence 等；`Expander` 按 class 名注册（如 `addFieldExpander("Set", "Elements")`）；结果 memo 化。典型用途：后端把"某寄存器类的闭包"这类集合运算写进 .td，而非在 emitter 里硬编码。

---

## 第 4 章 从通用记录到 LLVM 目标描述

### 4.1 schema：语义的第一现场【静态】

`llvm/include/llvm/Target/Target.td` 定义了 LLVM 目标描述的全部 schema class（它们都是普通 TableGen class）：

- `class Instruction : InstructionEncoding`（:663）：`Namespace`、`OutOperandList`/`InOperandList`（dag）、`AsmString`、`Pattern`（`list<dag>`）、`Uses`/`Defs`（隐式 use/def）、`Size`、`AddedComplexity`、约 50 个语义位（`isReturn/isBranch/isCommutable/mayLoad/…`）、`Constraints`、`TSFlags`。注意 `bit mayLoad = ?; bit mayStore = ?;`（:719-720）**故意留未设值**——留给模式推断（4.4）。
- `class InstructionEncoding`（:600）：`Size`、`DecoderNamespace`、`Predicates`、`DecoderMethod`、`hasCompleteEncoding`——编码与解码的描述已从 Instruction 中分离，`EncodingByHwMode`（:653）允许按 HwMode 覆盖。
- `class Register`（:173）：`Namespace/AsmName/AltNames/SubRegs/SubRegIndices/DwarfNumbers/HWEncoding/isArtificial/…`。
- `class RegisterClass`（:292）：`RegTypes/Size/Alignment/CopyCost/MemberList/isAllocatable/AltOrders/AllocationPriority`。
- `class Operand<ValueType ty>`（:1100）：`PrintMethod/EncoderMethod/OperandType/MIOperandInfo/ParserMatchClass`。
- `class RegisterOperand<…>`（:1150）：`RegClass`、`OperandType="OPERAND_REGISTER"`。
- `class SubtargetFeature`（:544）：`Name/Value/Desc/Implies`。

### 4.2 领域包装层【静态】

Common 层（`llvm/utils/TableGen/Common/`）把 record 包装成带验证的领域对象：

- **CodeGenTarget**（`CodeGenTarget.cpp:79`）：取唯一的 `Target` record；`ReadInstructions`（:265）为每条 Instruction 建 `CodeGenInstruction`；`ComputeInstrsEnum`（:302-349）决定指令枚举序——**伪指令在前、同组内按名字字典序**（:335-344），枚举值即排序后索引。这就是为什么 `.inc` 里的枚举序 ≠ `.td` 定义序。
- **CodeGenInstruction**（`CodeGenInstruction.cpp`）：构造函数（:418-496）逐字段取值并验证——`outs`/`ins` 算子校验（:32-53）、`MIOperandInfo` 展开（一个逻辑操作数可对应多个 MI 操作数，:101-110）、操作数唯一命名（:130-138）、约束解析（`ParseConstraints` :395：tied 约束必须一 def 一 use，挂在编号大的操作数上）。`mayLoad/mayStore/hasSideEffects` 用 `getValueAsBitOrUnset`（:459-465）**保留三态**。
- **CodeGenRegBank**（`CodeGenRegisters.cpp:1222`）：展开 `RegisterTuples`（经 SetTheory expander，:1230）、计算子寄存器图与 **RegUnit**（叶子寄存器各一个 unit，:356-389）、组合 SubRegIndex 传递闭包（`computeComposites` :1509）、寄存器类推断（`inferCommonSubClass` :2486 等——自动合成缺失的交集类）、寄存器压力集。
- **CodeGenDAGPatterns**（`CodeGenDAGPatterns.cpp:3345`）：固定流水线 ParseNodeInfo → ParseNodeTransforms → ParseComplexPatterns → ParsePatternFragments(in) → ParseDefaultOperands → ParseInstructions → ParsePatternFragments(out) → ParsePatterns → GenerateVariants（交换律等变体）→ InferInstructionFlags → VerifyInstructionFlags。类型推断器 `TypeInfer`（头 :239）做约束传播（EnforceInteger/SmallerThan/SameSize…），合法类型取自 target 的 `LegalValueTypes`。
- **CodeGenSchedModels**（`CodeGenSchedule.cpp:182`，第 7 章）。
- **CodeGenIntrinsicTable**（`Basic/CodeGenIntrinsics.cpp:77`，第 7 章）。

### 4.3 样例：MSP430 的 schema 继承链【静态 + 实验 E04】

`Target.td` 的 `Instruction` → `MSP430InstrFormats.td:32` 的 `MSP430Inst`（加 `field bits<48> Inst;`、Namespace、Size）→ `:45 IForm`（定义双操作数格式的位布局 `Inst{15-12}=opcode; Inst{11-8}=rs; …`）→ `:193 I16rr` → `MSP430InstrInfo.td:447 multiclass Arith` 中的 `def 16rr` → `:527 defm ADD : Arith<0b0101, "add", add, 1, []>` 实例化为 **`ADD16rr`**。

`GR16` 链：`Target.td` 的 `RegisterClass` → `MSP430RegisterInfo.td:81`：`def GR16 : RegisterClass<"MSP430", [i16], 16, (add R12, R13, …, PC, SP, SR, CG)>;`。寄存器本体由 `:12 MSP430Reg`（`let HWEncoding{3-0} = num;`）与 `:21 MSP430RegWithSubregs`（16 位寄存器带 8 位子寄存器，`SubRegIndex` 在 :33 定义）给出。

### 4.4 三态标志：schema、推断与校验的协作范例

`mayLoad/mayStore/hasSideEffects` 的设计展示了字段生命周期的完整路径：schema 留 `?`（Target.td:719）→ 包装层保留未设态（CodeGenInstruction.cpp:459）→ 模式分析推断（`InferInstructionFlags`，CodeGenDAGPatterns.cpp:4239：pattern 里有 `load` 节点 ⇒ mayLoad）→ 显式声明与推断冲突时报错（`VerifyInstructionFlags` :4300）。这让"每条指令手写 flags"在大多数情况下不必要，又不失去显式控制的能力。

---

## 第 5 章 指令、寄存器与 MC 的多种生成物

### 5.1 一份记录、九个投影【实验 E04】

MSP430 的构建声明 10 个生成动作（`llvm/lib/Target/MSP430/CMakeLists.txt:5-14`）。对其全部直跑（退出码均 0），产物规模：

| 动作 | 产物 | 大小 | 内容 |
|---|---|---|---|
| -gen-instr-info | MSP430GenInstrInfo.inc | 250 KB | 指令枚举、MCInstrDesc 表、操作数信息、调度类索引 |
| -gen-register-info | MSP430GenRegisterInfo.inc | 535 B（骨架） | 宏分发；实际内容拆 4 文件（Enums/Header/MCDesc/TargetDesc） |
| -gen-asm-writer | …AsmWriter.inc | 38 KB | `printInstruction`/`getMnemonic` 实现 |
| -gen-emitter | …MCCodeEmitter.inc | 38 KB | `getBinaryCodeForInstr`：编码函数 |
| -gen-disassembler | …DisassemblerTables.inc | 123 KB | 定长解码表 |
| -gen-asm-matcher | …AsmMatcher.inc | 74 KB | 汇编解析匹配表 |
| -gen-subtarget | …SubtargetInfo.inc | 11 KB | Feature 位、MCSchedModel 表 |
| -gen-dag-isel | …DAGISel.inc | 329 KB | SDAG 匹配字节码 + SelectCode |
| -gen-callingconv | …CallingConv.inc | 3 KB | 调用约定判定函数 |
| -gen-sd-node-info | …SDNodeInfo.inc | （随构建） | SDNode 元数据 |

同一份 record 集合，每个 emitter 只读自己关心的字段。**产物文件存在 ≠ 语义正确**：验证必须追到消费点（5.3）。

### 5.2 GET_* 宏：一个 .inc、多处复用【静态 + 实验】

生成文件普遍按宏分段：消费方先 `#define GET_INSTRINFO_MC_DESC` 再 `#include` 同一个 `.inc`，只有对应段落生效。实测消费点（`MSP430MCTargetDesc.cpp:26-34`）：

```cpp
#define GET_INSTRINFO_MC_DESC
#define ENABLE_INSTR_PREDICATE_VERIFIER
#include "MSP430GenInstrInfo.inc"
#define GET_SUBTARGETINFO_MC_DESC
#include "MSP430GenSubtargetInfo.inc"
#define GET_REGINFO_MC_DESC
#include "MSP430GenRegisterInfo.inc"
```

InstrInfoEmitter 的段包括 `GET_INSTRINFO_ENUM`（枚举）、`GET_INSTRINFO_MC_DESC`（描述表，**内含** `InitMSP430MCInstrInfo` 函数——实测生成物中该函数位于 `#ifdef GET_INSTRINFO_MC_DESC` 块内）、`GET_INSTRINFO_CTOR_DTOR`（生成目标 `InstrInfo` 类的构造/析构，是另一段）、`GET_INSTRINFO_SCHED_ENUM` 等十余种（`InstrInfoEmitter.cpp:921` 起的 `run`）。`MSP430MCTargetDesc.cpp:36-40` 的 `createMSP430MCInstrInfo` 在定义了 `GET_INSTRINFO_MC_DESC` 的 include 之后调用 `InitMSP430MCInstrInfo`。MCInstrDesc 初始化器的字段布局（`InstrInfoEmitter.cpp:1310-1328`）：

```cpp
{ Opcode, NumOperands, DefOperandCount, Size, SchedClassIdx,
  NumImplicitUses, NumImplicitDefs, OpInfoOffset, ImplicitListOffset,
  Flags, TSFlags }   // Flags 逐位：|(1ULL<<MCID::Commutable) 等；TSFlags 在最后
```

RegisterInfoEmitter 的输出结构（`RegisterInfoEmitter.cpp:2066 run`）：寄存器枚举、RegClass 枚举、SubRegIndex 枚举；MCDesc 段对子/超寄存器列表做**差分编码**（`SequenceToOffsetTable`，:981-1031）；RegUnit 压力表（:235）；`getSubReg`/`getSuperReg`/`composeSubRegIndices` 等查询函数的表驱动实现（:436-858）。

### 5.3 ADD16rr：一条记录的完整投影【实验 E04 + 静态】

源 record 的关键字段（第 4.3 节的继承链展开后）：

```
ADD16rr: Namespace="MSP430", Size=2, AsmString="add\t$rs, $rd",
  OutOperandList=(outs GR16:$rd), InOperandList=(ins GR16:$src2, GR16:$rs),
  Pattern=[(set GR16:$rd, (add GR16:$src2, GR16:$rs))],
  Defs=[SR], Constraints="$src2 = $rd", isCommutable=1,
  Inst{15-12}=0b0101, Inst{11-8}=rs, Inst{7}=0(DstReg), Inst{6}=0(bw=16位),
  Inst{5-4}=0(SrcReg), Inst{3-0}=rd, DecoderNamespace="Alpha"
```

各生成物中的投影（E04 产物中实测定位）：

| 产物 | 投影内容 |
|---|---|
| InstrInfo.inc 枚举 | `ADD16rr = 346, // MSP430InstrInfo.td:455`（枚举序来自 4.2 的排序） |
| InstrInfo.inc MCInstrDesc | `{ 346, 3, 1, 2, …, 0\|(1<<Commutable)\|(1<<ExtraSrcRegAllocReq)\|(1<<ExtraDefRegAllocReq), 0x0 }` |
| MCCodeEmitter.inc | 基值 `UINT64_C(20480)` = **0x5000** —— 正是 `Inst{15-12}=0b0101`，rs/rd 为变量位 |
| AsmWriter.inc | 字符串表偏移 → "add" + 操作数打印命令 |
| DAGISel.inc | pattern `(set GR16:$rd, (add …))` 的匹配字节码；交换变体来自源 SDNode 的 SDNPCommutative（`add` 节点自带），与指令 isCommutable→`MCID::Commutable` 是两条独立机制（见 6.1） |
| Disassembler.inc | DecoderNamespace "Alpha" 的解码表项 |

编码函数的手写边界【静态】：CodeEmitterGen 扫描 `Inst` 的 `BitsInit`，变量位（`rs`/`rd`）生成 `Value |= (op & 0xF) << shift;`（`CodeEmitterGen.cpp:218-227`）；若 Operand 声明了 `EncoderMethod`，生成对**手写函数**的调用（:169-175）——MSP430 的 `getCCOpValue`（`MSP430MCCodeEmitter.cpp:195-211`）就是这样的手写钩子，消费点在该文件 :218 `#include "MSP430GenMCCodeEmitter.inc"`。同理 AsmString 的 `$rs` 打印对应 AsmWriterEmitter 生成的打印命令序列。**生成编码函数 ≠ 完整汇编器**：fixup 处理、特殊操作数转换仍是手写。

### 5.4 NVPTX 与 AMDGPU：生成职责的边界对照【静态】

三目标的 CMake 动作数对比直接说明"职责边界由输出物决定"：

| 目标 | 动作数 | 缺少的动作 | 原因 |
|---|---|---|---|
| MSP430 | 10 | — | 完整二进制目标 |
| NVPTX | 6 | emitter、disassembler、asm-matcher、callingconv | 输出 **PTX 文本**（`NVPTXAsmPrinter`），不编机器码、不需要反汇编/汇编匹配 |
| AMDGPU | 20 | — | 额外需要 pseudo-lowering、**register-bank**（GISel）、searchable-tables、**global-isel** + 3 组 combiner |

NVPTX 的教训值得强调：不要看到 `Register`/`RegisterClass` 描述就推断存在物理寄存器分配——NVPTX 的"寄存器"是虚拟 PTX 寄存器，其描述服务于指令选择与打印，不进入硬件编码。

---

## 第 6 章 SelectionDAG 与 GlobalISel 模式生成

### 6.1 SDAG：从 Pattern 字段到匹配字节码【静态】

`Instruction` 的 `Pattern` 字段（`list<dag>`）经 CodeGenDAGPatterns 流水线（4.2）成为 `PatternToMatch` 集合，随后 DAGISel 发射器三阶段处理（`DAGISelEmitter.cpp:192-215`）：

1. **排序** `stable_sort(Patterns, PatternSortingPredicate)`：先比 complexity（`getPatternComplexity`），再比结果模式大小，最后按源 record UID 保证稳定（:100-148）。
2. **构造** `ConvertPatternToMatcherList`（`DAGISelMatcherGen.cpp:1066`）：把每条 pattern 翻译成 matcher 操作序列（MatchOpcode/CheckType/RecordNode/Emit_Instruction…）。
3. **优化** `OptimizeMatcher`（`DAGISelMatcherOpt.cpp:664`）：`ContractNodes` 合并相邻操作 + `FactorNodes` 提取公共子序列。
4. **发射** `EmitMatcherTable`（`DAGISelMatcherEmitter.cpp`）：生成压缩字节码表 + `SelectCode(SDNode *N)` 入口，运行时由 `SelectionDAGISel::SelectCodeCommon` 解释执行。

E04 的 MSP430GenDAGISel.inc（329 KB）就是这条链的产物。**交换变体的来源是 pattern 中源 SDNode 的属性，不是指令字段**：`GenerateVariants`（`CodeGenDAGPatterns.cpp:4887`）在 `GenerateVariantsOf`（:4782）中检查 `NodeInfo.hasProperty(SDNPCommutative)`（:4858，也含 intrinsic 情形）——`add` 这类 SDNode 自带可交换属性，因此 `(add $a, $b)` 的 pattern 自动派生 `(add $b, $a)` 变体。这是 **pattern 层**的行为；与之独立，指令的 `isCommutable=1` 字段流向**机器指令层**的 `MCID::Commutable` 标志（见 5.3 MCInstrDesc 行），供后端的机器级优化（如两地址指令的交换）使用。两者作用于不同阶段、互不依赖，勿混为一谈。

### 6.2 GlobalISel：导入、拒绝与诊断【实验 E05 + 静态】

GlobalISelEmitter **不重写一套模式语言**，而是尝试把 SDAG 的 `PatternToMatch` 逐条导入为 `RuleMatcher`（`GlobalISelEmitter.cpp:2160 runOnPattern`）：检查根节点必须是平凡 operator（:2182）、导入谓词（:2171）、递归导入子匹配器（`createAndImportSelDAGMatcher` :795）、生成指令渲染器（:1519 起）。无法导入时返回 `failedImport`，主循环按开关分流（:2525-2537）：

```cpp
if (auto Err = MatcherOrErr.takeError()) {
  if (WarnOnSkippedPatterns)
    PrintWarning(Pat.getSrcRecord()->getLoc(), "Skipped pattern: " + …);
  else
    consumeError(std::move(Err));    // 静默跳过
  ++NumPatternImportsSkipped;
}
```

**E05 实测**（AMDGPU，命令为 CMake 所用的 `-gen-global-isel -gisel-extended-llt -warn-on-skipped-patterns AMDGPUGISel.td`）：

- 产物 AMDGPUGenGlobalISel.inc = **105,394,333 字节（≈105 MB）**；
- stderr **117,672 行**，其中 `warning: Skipped pattern` 共 **10,120 条**（其余为 `Included from` 位置链）。对 10,120 条按原因归类（取括号前的主干文本统计，**合计恰为 10,120**）：

  | 拒绝原因 | 条数 |
  |---|---|
  | Pattern operator lacks an equivalent Instruction | 8,017 |
  | unsupported type for Src operand（源操作数类型不支持） | 1,815 |
  | EXTRACT_SUBREG child could not be coerced to a register class | 75 |
  | Src pattern child has predicate | 44 |
  | Pattern defines a physical register | 42 |
  | SDNodeXForm has no GISel equivalent（as_i16imm 40 / as_i64imm 15 / IMMBitSelConst 6 / bitcast_fpimm_to_i16 2） | 63 |
  | Src pattern root isn't a trivial operator | 24 |
  | SelectionDAG ComplexPattern | 22 |
  | Could not infer register class for result | 14 |
  | Src pattern child has unsupported predicate | 4 |

  可见**头号原因是"缺少等价 Instruction"（8,017 条，约 79%）**——它发生在**源模式匹配器的导入阶段**：`createAndImportSelDAGMatcher`（`GlobalISelEmitter.cpp:814-817`）对 pattern 根/子节点调 `findNodeEquiv` 查 GINodeEquiv 映射，查不到就 `failedImport`，即**源 SDNode 没有声明对应的 GINodeEquiv，无法建立 GMIR opcode 匹配**——不是"目标指令缺少渲染器"（后者是另一阶段的事）。其次是类型不支持（1,815 条）。"根不是平凡 operator" 仅 24 条，"带匿名谓词"更不是主要拒绝条件——谓词相关（child has predicate / unsupported predicate）合计不足 50 条，且匿名命名本身不是拒绝理由。

这是"能写进 .td ≠ 能被 GISel 导入"的直接证据，且说明拒绝呈明显的长尾分布。LLVM 的回归测试 `llvm/test/TableGen/GlobalISelEmitter/SkippedPatterns.td` 精确覆盖两类拒绝（complex suboperand 重复绑定、饱和宽度不匹配）以及 `GISelShouldIgnore=1` 的静默路径。

GISel 的类型系统与 SDAG 不同（LLT vs EVT），AMDGPU 的 `-gisel-extended-llt` 打开扩展低层类型支持。消费点（`AMDGPUInstructionSelector.cpp:36-50`）：同一 `.inc` 被 include 三次，分别注入 `GET_GLOBALISEL_IMPL`（匹配表）、`GET_GLOBALISEL_PREDICATES_INIT`、`GET_GLOBALISEL_TEMPORARIES_INIT`。匹配表运行时由 `llvm/lib/CodeGen/GlobalISel/InstructionSelector.cpp` 的解释器消费。

### 6.3 Combiner 与共享基础设施【静态】

`GlobalISelCombinerEmitter.cpp`（-gen-global-isel-combiner）解析 `GICombineRule` record（`:147`），经类型检查（`CombineRuleOperandTypeChecker` :194）后复用 `RuleMatcher`/`InstructionMatcher` 与同样的 match table 发射器——共享代码在 `llvm/utils/TableGen/Common/GlobalISel/`（MatchTable、Patterns、CXXPredicates、CodeExpander、CombinerUtils）。AMDGPU 声明了三组 combiner（PreLegalize/PostLegalize/RegBank，`CMakeLists.txt:24-28`）。

### 6.4 共享与手写边界（判断）

- **可共享**：根为平凡 operator、无复杂谓词的算术/位运算 pattern，SDAG 与 GISel 可消费同一 `Pattern` 字段。
- **GISel 需要额外描述**：RegisterBank（-gen-register-bank）、扩展 LLT；带 `ComplexPattern`、自定义谓词、多结果的模式通常需要手写 `InstructionSelector::select*` 补充（AMDGPUInstructionSelector.cpp 中大量手写函数即此）。
- **永远不要假设**：pattern 写进 .td ≠ 被任何 selector 导入；导入成功 ≠ 运行时选择正确（需 codegen 测试验证）。

---

## 第 7 章 调度模型与 intrinsic 生成

### 7.1 调度模型：声明数据，而非算法【静态】

**schema**（`llvm/include/llvm/Target/TargetSchedule.td`）：`SchedMachineModel`（:76：IssueWidth/MicroOpBufferSize/LoadLatency/MispredictPenalty/Itineraries/CompleteModel…）、`SchedWriteRes`(:318)/`SchedReadAdvance`(:355)（每条指令的写资源与读提前）、`InstRW`(:464，用指令列表批量改写 RW)、`SchedVariant`（按谓词选择不同 RW 的变体）。

**解析与展开**（`Common/CodeGenSchedule.cpp:182-250`）：collectProcModels → collectSchedRW → collectSchedClasses（含 InstRW 与指令的匹配 :897-916）→ **inferSchedClasses（variant 展开核心，`inferFromRW` :1682-1730）**：先展开 WriteSequence/ReadSequence，再循环 `substituteVariants` 至不动点，生成带谓词的过渡调度类。

**发射**（`SubtargetEmitter.cpp:1593 emitSchedModel`）：生成每处理器的 `MCSchedModel` 表与调度类表；谓词经 `expandSchedPredicates`（:1643）变成运行时代码 `STI.hasFeature(…)`。每条指令的 `MCInstrDesc.SchedClassIdx` 由 `getSchedClassIdx`（`CodeGenSchedule.cpp:928`）写入（第 5 章 ADD16rr 行的第 5 列即此）。

**运行时消费点**（定位，行为未验证）：

- `llvm/lib/CodeGen/TargetSchedule.cpp:117 resolveSchedClass`——variant 类在此经 `STI->resolveSchedClass` 动态消解（:130）。
- `llvm/lib/MCA/InstrBuilder.cpp:38/233`——llvm-mca 用 `getSchedModel()` 与 `computeInstrLatency` 做模拟；:537/563 检查 `isVariant()`。

**边界必须说清**：TableGen 产出的是**模型数据**（延迟、资源占用、端口压力），调度算法（机器调度器、MCA 模拟器）全部是手写 C++。"目标有调度表"与"调度器做了好决策"是两回事。反例：MSP430 没有任何 `*Sched*.td`——小目标完全不给模型也是合法选择。

### 7.2 intrinsic：三种计数口径【实验 E08 + 静态】

schema（`llvm/include/llvm/IR/Intrinsics.td:816` `class Intrinsic`）：`LLVMName/TargetPrefix/RetTypes/ParamTypes/IntrProperties/…`。加载（`Basic/CodeGenIntrinsics.cpp:77-114`）：取全部派生 def，按 `(TargetPrefix, Name, record ID)` 排序（record ID 做 tie-breaker 保证可重复构建）。发射（`Basic/IntrinsicEmitter.cpp:99-149`）：-gen-intrinsic-enums 只出枚举，另有 IITInfo/属性表/名称表/重载表/默认属性表等十余种产物。

**E08 实测**（同范围对照，为什么不能拿 .td 行数当 intrinsic 数量）。对 `llvm/include/llvm/IR/Intrinsics.td` 做 `--dump-json`，按 `!instanceof` 精确统计（同一份展开后的 record 集合内比较）：

| 口径 | 数值 |
|---|---|
| 全部 def 总数（含非 Intrinsic 的辅助 record） | **31,668** |
| 其中 `Intrinsic` 类的实例数 | **16,709** |
| 其中 `TargetPrefix = "nvvm"` 的 Intrinsic record | **2,797** |
| `-gen-intrinsic-enums -intrinsic-prefix=nvvm` 实际生成的枚举项 | **2,797** |

两点修正性说明：

1. **同一目标范围内，Intrinsic record 与枚举一一对应（2,797 = 2,797）**——每条 NVVM Intrinsic record 恰好对应一个枚举 ID。真正让"行数失真"的是 foreach/defm：NVVM 的 `nvvm_applypriority_async_bulk_tensor_evict_priority_im2col_{3d,4d,5d}` 三个枚举都指向 `IntrinsicsNVVM.td:3541` **同一行 def**（归档产物 `TableGen-notes/experiments/E08-intrinsic/output/NVVMEnums.inc:19-21`）——一行源经 multiclass/foreach 展开成多个 record，各得一个枚举。注意 `…_im2col_3d` 与 `…_im2col_w_128_3d` 是**两条独立枚举**（归档文件 :19 与 :25），来自同一 multiclass 的不同 foreach 展开，**不是**类型重载关系。
2. **重载类型后缀不增加枚举 ID**（**已修正示例**）：典型例是 `int_fabs`（`Intrinsics.td:1254`，`DefaultAttrsIntrinsic<[llvm_anyfloat_ty], [LLVMMatchType<0>]>`）——`llvm.fabs.f32`、`llvm.fabs.f64` 等重载形态共用**同一个**枚举项 `fabs`（实测 `-gen-intrinsic-enums` 全量输出中 fabs 只出现一次）；`LLVMMatchType` 产生的差异只体现在 mangled 名与 IIT 签名表上。

因此报告 intrinsic 数量必须声明分母：源文件**行数**、展开后 **record 数**、生成**枚举数**是三个不同的数（31,668 / 16,709 / 2,797 分属不同口径），不可混用或互相推算。

---

## 第 8 章 Clang 的 schema 与生成代码

### 8.1 NoInline：一条属性的完整投影【实验 E09 + 静态】

**Record**（`clang/include/clang/Basic/Attr.td:2437-2450`）：

```tablegen
def NoInline : DeclOrStmtAttr {
  let Spellings = [CustomKeyword<"__noinline__">, GCC<"noinline">,
                   CXX11<"clang", "noinline">, C23<"clang", "noinline">,
                   CXX11<"msvc", "noinline">, C23<"msvc", "noinline">,
                   Declspec<"noinline">];
  let Accessors = [Accessor<"isStmtNoInline", […]>];
  let Documentation = [NoInlineDocs];
  let Subjects = SubjectList<[Function, Stmt], WarnDiag, "functions and statements">;
  let SimpleHandler = 1;
}
def : MutualExclusions<[AlwaysInline, NoInline]>;   // :2452
```

schema（`Attr.td:697-783` 的 `class Attr`）定义了 Spellings/Subjects/Args/SimpleHandler/HasCustomParsing/LangOpts/Documentation 等字段——它们是 Clang 侧的领域接口。

**生成**（E09 实测，clang-tblgen 两动作均退出 0）：

| 动作 | 产物 | 内容 |
|---|---|---|
| -gen-clang-attr-classes | AttrClasses.inc | `class CLANG_ABI NoInlineAttr : public DeclOrStmtAttr` + Create/CreateImplicit 工厂（产物 :9723 起） |
| -gen-clang-attr-impl | AttrImpl.inc | `getSpelling()/clone()/printPretty()` 的**巨型 switch**——`ClangAttrEmitter.cpp:3438` 注释明确：switch 代替虚函数，更小更快 |
| -gen-clang-attr-parsed-attr-impl | AttrParsedAttrImpl.inc | 每属性一个 `ParsedInfo<Name>` + `AttrInfoMap[]` 表；`HasCustomParsing` 等属性烘焙为描述对象的 constexpr 字段（生成代码 :5092-5140）。注意 `SimpleHandler` **不进描述对象**——它控制的是**是否为该属性生成标准的 `handleDeclAttribute()` 处理函数**（见下文消费链第 3 条） |

**消费链**（静态定位）：

1. `clang/include/clang/AST/Attr.h:408` → `#include "clang/AST/Attrs.inc"`（正式消费文件名；上文 `AttrClasses.inc` 是 E09 实验的输出命名）。
2. `clang/lib/AST/AttrImpl.cpp:500` → `#include "clang/AST/AttrImpl.inc"`（方法实现）。
3. `clang/lib/Sema/ParsedAttr.cpp:101` → include AttrParsedAttrImpl.inc；`ParsedAttrInfo::get`（:105-132）以 `AttrInfoMap[A.getParsedKind()]` **查出该属性的 `ParsedAttrInfo` 描述对象**。真正的 Subjects 适用对象检查由**后续调用**（如 `diagnoseAppertainsTo`/`handleDeclAttribute`）在该描述对象上执行；`SimpleHandler=1` 则控制为 NoInline 这类无参属性生成简单的 `handle…` 处理函数。
4. **手写语义桥**：`clang/lib/CodeGen/CodeGenModule.cpp:3236-3239`——`D->hasAttr<NoInlineAttr>()` 且非 always_inline 时 `B.addAttribute(llvm::Attribute::NoInline)`。

第 4 步是关键认知：**AST 属性 → LLVM IR 属性的翻译不是生成的，是逐属性手写的**。TableGen 消掉的是声明、遍历、解析分发、文档这些机械工作；"noinline 在 IR 上是什么意思"这类语义决策仍在手写代码里（同文件还有 NakedAttr 隐含 noinline 等规则，:3233）。负例设计：`Subjects=[Function, Stmt]` 限定 noinline 只适用于函数与语句，越界使用会经 `ParsedAttrInfo` 的适用对象检查诊断——适用对象检查是生成的，语义互斥（MutualExclusions）与 IR 投影是两层不同机制。

### 8.2 其他 Clang 生成器职责地图【静态】

| 领域 | 输入 | emitter | 产物/消费 |
|---|---|---|---|
| 诊断 | `clang/Basic/Diagnostic*.td` | ClangDiagnosticsEmitter.cpp | Diagnostic*Kinds.inc、DiagnosticGroups.inc → lib/Basic/Diagnostic.cpp |
| 内建函数 | `Builtins.td` + 各 target `Builtins*.td` | ClangBuiltinsEmitter.cpp | Builtins*.inc → `clang/lib/Basic/Builtins.cpp:36/42`（include 点）、lib/CodeGen/CGBuiltin.cpp |
| 命令行选项 | `clang/include/clang/Options/Options.td` | **llvm 侧** OptionParserEmitter（-gen-opt-parser-defs） | Options.inc → `clang/lib/Options/DriverOptions.cpp:17/20`（include 点）——注意走 llvm-tblgen 而非 clang-tblgen |
| AST 节点 | StmtNodes.td 等 | ClangASTNodesEmitter/ClangTypeNodesEmitter | StmtNodes.inc 等 |
| 属性 PCH 序列化 | `Attr.td` | ClangAttrEmitter.cpp | AttrPCHRead.inc / AttrPCHWrite.inc |
| AST 属性（property）序列化 | AST 节点属性 | ClangASTPropertiesEmitter | AbstractBasicReader/Writer.inc——与属性 PCH 是**另一条**链 |
| SIMD 内建 | arm_neon.td 等 | Neon/Sve/Mve/RISCVVEmitter | arm_neon.inc 等 |

构建规则样例：`clang/include/clang/AST/CMakeLists.txt:1-19`（`clang_tablegen(Attrs.inc -gen-clang-attr-classes …)`）、`clang/include/clang/Sema/CMakeLists.txt:1-25`；`clang_tablegen()`（`clang/cmake/modules/AddClang.cmake:4-31`）是通用 `tablegen(CLANG …)` 的封装。

---

## 第 9 章 MLIR ODS、格式与 DRR

### 9.1 ODS：操作声明如何变成 C++ 类【实验 E10 + 静态】

ODS 的包装层是 `mlir::tblgen::Operator`（`mlir/lib/TableGen/Operator.cpp:41-61`）：构造时从 record 抽取 `opDialect` 字段、按 `_` 切分 def 名得方言前缀与 C++ 类名；`getOperationName()`（:63-69）拼出 `"arith.addi"`；`assertInvariants`（:114-150）检查 operand/result 命名冲突等不变量——**领域验证在包装层，不在通用前端**。

**arith.addi 的定义**（`mlir/include/mlir/Dialect/Arith/IR/ArithOps.td:271-308`）：

```tablegen
def Arith_AddIOp : Arith_IntBinaryOpWithOverflowFlags<"addi",
    [Commutative, DeclareOpInterfaceMethods<InferIntDivisibilityOpInterface>]> {
  let summary = "integer addition operation";
  …
  let hasFolder = 1;
  let hasCanonicalizer = 1;
}
```

基类链（同文件）：`Arith_Op`（:33，注入 `Op<Arith_Dialect, mnemonic, …>` 与公共 traits）→ `Arith_ArithOp`（:42，+SameOperandsAndResultType）→ `Arith_BinaryOp`（:52，基础格式）→ `Arith_IntBinaryOpWithOverflowFlags`（:193，声明 Arguments `(ins …:$lhs, …:$rhs, DefaultValuedAttr<…>:$overflowFlags)` 与 Results，并**覆盖格式**）。addi **最终生效的格式**是派生类的版本（:203）：

```tablegen
let assemblyFormat = [{ $lhs `,` $rhs (`overflow` `` $overflowFlags^)?
                        attr-dict `:` type($result) }];
```

即比 `Arith_BinaryOp` 的 `"$lhs `,` $rhs attr-dict `:` type($result)"`（:54）多一个可选的 `overflow` 子句（`^` 表示该变量参与字面量锚定）。

**生成与消费**（E10 三动作均退出 0）：

| 动作 | 产物 | 消费点 |
|---|---|---|
| -gen-op-decls | ArithOps.h.inc：`class AddIOp`、Adaptor、builders、`parse/print/verify` 声明，以及因 hasFolder/hasCanonicalizer 产生的 `fold()`/`getCanonicalizationPatterns()` **声明** | `Arith.h:27-28` `#define GET_OP_CLASSES` + include |
| -gen-op-defs | ArithOps.cpp.inc：builders/parse/print/verify **实现** | `ArithOps.cpp:3443-3444` 同宏模式 include |
| -gen-rewriters | ArithCanonicalization.inc：DRR 规则生成的 RewritePattern 子类 | `ArithOps.cpp:200` 匿名 namespace include |

**手写部分仍在，但两条路径要分开说**（ArithOps.cpp）：

- **fold**：`AddIOp::fold`（`:433`，addi(x,0)→x 等）是手写 C++。`hasFolder=1` 只生成**声明**，实现必须手写——`hasFolder` 这条路确实"只消样板，不消语义"。
- **canonicalize**：`hasCanonicalizer=1` 同样只提供声明（生成 `getCanonicalizationPatterns` 的类内声明），实现则由 DRR 生成——本例的 `AddIAddConstant`：`matchAndRewrite` 的**匹配、构造、替换流程**由 DRR 从 `ArithCanonicalization.td:73-78` 的 `Pat` 规则生成（`ArithCanonicalization.inc:729 struct AddIAddConstant : public ::mlir::RewritePattern`，`:732 matchAndRewrite`），经 `-gen-rewriters` 产出后 include 进 `ArithOps.cpp:200` 的匿名 namespace。但本例并非零手写：生成代码里调用了两个**手写 helper**——`addIntegerAttrs`（`ArithOps.cpp:56`，经 `AddIntAttrs : NativeCodeCall` 注入，产物 :780）与 `mergeOverflowFlags`（`ArithOps.cpp:88`，产物 :787）；另外 `:453 getCanonicalizationPatterns` 的**注册**（`patterns.add<AddIAddConstant, …>(context)`）也是手写。

所以准确的表述是：DRR 生成**匹配、构造和替换的流程骨架**；本例仍依赖**手写 helper（NativeCodeCall 注入的语义函数）与手写注册**。ODS/DRR 消除的不只是样板——模式化重写的主流程可以整体生成；手写的边界在 fold 这类任意 C++ 语义、NativeCodeCall 承载的辅助计算、以及最终的注册与接线。

### 9.2 assemblyFormat 生成【静态】

`assemblyFormat` 字符串由 `mlir/tools/mlir-tblgen/OpFormatGen.cpp` 处理（不是独立注册项；`OpDefinitionsGen.cpp:1049` 调 **`generateOpFormat`**，实现于 `OpFormatGen.cpp:4727`）：解析成 `FormatElement` 序列（字面量、变量、directive、可选组），为 parser 和 printer 各生成一遍 visitor 代码，直接写入 OpClass 的 `parse`/`print` 方法体。

但要划清能力边界：**格式字符串只描述语法形态，不提供类型推导所需的全部信息**。operand 类型推导依赖 ODS 侧的约束——addi 的 `type($result)` 之所以能解析出结果类型，是因为基类链挂了 `SameOperandsAndResultType`（`Arith_ArithOp`，:42）这类 trait/约束，格式解析遇到 `type($result)` 时按"与已知操作数类型一致"的规则消解；没有这类约束的 op，格式里就得显式写出每个操作数的 `type($x)`。即"一行格式产出类型推导完备的解析器"是格式与 traits **协同**的结果，不是格式字符串单方面的能力。

### 9.3 DRR：声明式重写【实验 E10 + 静态】

源规则（`mlir/lib/Dialect/Arith/IR/ArithCanonicalization.td:73-78`）：

```tablegen
// addi(addi(x, c0), c1) -> addi(x, c0 + c1)
def AddIAddConstant :
    Pat<(Arith_AddIOp:$res
          (Arith_AddIOp $x, (ConstantLikeMatcher APIntAttr:$c0), $ovf1),
          (ConstantLikeMatcher APIntAttr:$c1), $ovf2),
        (Arith_AddIOp $x, (Arith_ConstantOp (AddIntAttrs $res, $c0, $c1)),
            (MergeOverflow $ovf1, $ovf2))>;
```

`RewriterGen.cpp`（注册于 :2102）为每条 `Pat` 生成继承 `mlir::RewritePattern` 的 struct（匹配逻辑递归展开嵌套 op 与属性检查）+ `populateWithGenerated(RewritePatternSet&)` 便捷入口（:2093）。`NativeCodeCall`（AddIntAttrs/MergeOverflow）允许在模式里嵌入任意 C++ 表达式。

**DRR 与机器选指 pattern 的区别**（防混淆）：

| | MLIR DRR | LLVM SDAG/GISel pattern |
|---|---|---|
| 匹配单位 | `Operation*`（开放类型系统） | SDNode/MachineInstr（固定 ValueType/LLT） |
| 产物 | C++ RewritePattern 子类 | 匹配字节码/C++ 表 |
| 运行时机 | pass 运行时（greedy driver 等） | 指令选择 |
| 逃逸口 | `NativeCodeCall` | 手写谓词/ComplexPattern |
| 共享性 | MLIR 自有生态 | 与 GISel 部分共享（第 6 章） |

两者形似（都是 DAG→DAG）但**不共享实现与语义**——这是阅读两套代码时最常见的误配。

---

## 第 10 章 构建、诊断、测试与性能

### 10.1 构建依赖与增量【静态；运行时验证未做】

- **include 追踪**：`-d ${ofn}.d` 生成 make 风格 depfile（`Main.cpp:90-116 createDependencyFile`；**总是写**，因为 Ninja 视缺失 depfile 为 dirty）。Ninja + CMP0116 下由 `TableGen.cmake:36-56` 接入 `DEPFILE`；旧 CMake 回退到 `file(GLOB …)` 全量 .td 依赖（保守但正确性更弱）。
- **时间戳**：`--write-if-changed`（CMake 默认传，`TableGen.cmake:89-96`；实现 `Main.cpp:118-138`）——内容不变不覆盖，避免下游全量重编。出错时（ErrorsPrinted>0）不 `keep()`，不污染输出。
- **多文件输出**：`TableGenOutputFiles.AdditionalFiles`（`Main.cpp:202-211`）配合 CMake 的 `EXTRA_OUTPUTS` 声明（`-gen-register-info` 的 4 个文件，`TableGen.cmake:70-77`）。

### 10.2 诊断设施【静态 + 实验 E02/E05】

- 位置与计数：`llvm/lib/TableGen/Error.cpp`——全局 `SrcMgr` + `ErrorsPrinted`；`PrintMessage`（:27-41）把多 location 的后续位置自动降级为 "instantiated from multiclass" note（multiclass 实例化栈的展示机制）。
- 退出码：解析失败或 `ErrorsPrinted>0` 时退出码 1（`Main.cpp:168-175`）——E02 负例实测符合。
- assert：`CheckAssert`（`Error.cpp:163-178`）非致命累计；E02 实测诊断带精确行列。
- 警告：`-warn-on-skipped-patterns`（GISel，E05 实测 11.7 万行）、`--no-warn-on-unused-template-args`（E02 负例中可见 unused template argument 警告）。

### 10.3 测试设施【静态】

- `llvm/test/TableGen/`（381 个文件）：lit 测试，直接跑 `llvm-tblgen` + FileCheck；134 个文件用 `not llvm-tblgen` 验证错误路径（如 `assert.td` 校验诊断行列号）；JSON 用 `-dump-json | %python JSON-check.py` 校验结构；GISel 用 `-gen-global-isel` + 专用 Common 头。
- `llvm/unittests/TableGen/`：gtest（AutomataTest、CodeExpanderTest、ParserEntryPointTest）。
- `clang/test/TableGen/`、`mlir/test/mlir-tblgen/`：同模式，各用自己的 tblgen 二进制与 `-D` 分支多次运行。

测试的共同模式值得学习：**正例验证输出结构，负例验证诊断位置**，两方向都有 FileCheck 断言——本文 E02 实验与此同构。

### 10.4 确定性与性能【实验 E12】

- **确定性**：同一输入两次 `-gen-instr-info`，SHA256 完全一致（机制见 3.3：std::map 字典序 + LessRecord 排序 + record ID tie-breaker）。注意这只覆盖"同工具同输入"；跨版本一致性没有保证。
- **计时**（`--null-backend --time-phases`，MSP430.td，Debug 构建）：`Parse, build records` = 1.475 s（占 100%），后端与写盘在计时分辨率内为 0。**对本输入与构建的结论**：前端解析是绝对主体。注意口径：`--null-backend` **主动跳过所有生成器**（Main.cpp 中 null backend 在解析后直接返回，不构造任何 emitter），因此这条计时只能作**前端基线**——它证明"对 MSP430 这种小输入，解析不慢"，但**不能**据此推断真实生成任务中前端占比同样接近 100%。要判断真实生成任务的耗时占比，应对具体 `-gen-*` 动作计时（如 `-gen-instr-info`、AMDGPU 的 `-gen-global-isel`）再与基线相减。不外推到其他目标（AMDGPU 的 emitter 规模完全不同，见 E05 的 105 MB 产物）或 Release 构建。
- 内存与速度的工程手段（静态）：Init 全局唯一化（3.3）、`getAllDerivedDefinitions` per-class 缓存（Record.cpp:3153）、`LLVM_OPTIMIZED_TABLEGEN` 让 tblgen 在调试构建中保持 Release（1.3）。

---

## 第 11 章 设计判断与自研编译栈适用性

### 11.1 什么适合用 TableGen 描述

按本文证据，TableGen 在以下四类场景投入产出比最高：

| 场景 | 证据 | 收益 |
|---|---|---|
| **结构化数据表** | MCInstrDesc/MCRegisterInfo/MCSchedModel（第 5、7 章） | 消除手写表 + 免费获得枚举、查询函数、一致性检查 |
| **机械样板代码** | Clang Attr 的类声明/遍历/解析分发（第 8 章）；MLIR op 的 builders/parse/print/verify（第 9 章） | 几百个实体共享一套生成逻辑 |
| **声明式匹配** | SDAG/GISel pattern、DRR（第 6、9 章） | 模式即数据：可排序、可优化、可统计覆盖率 |
| **模型参数** | 调度模型的延迟/资源（第 7 章） | 硬件数据与算法解耦 |

### 11.2 什么必须手写

- **语义决策**：Clang 属性 → IR 属性的翻译（CodeGenModule.cpp:3236）；MLIR 的 fold 实现（ArithOps.cpp:433）与 DRR 规则引用的手写 helper（`addIntegerAttrs`/`mergeOverflowFlags`）——canonicalize 的匹配/构造/替换流程本身可以由 DRR 生成（9.1），不属于"必须手写"。
- **状态化算法**：调度器、寄存器分配、指令选择驱动——TableGen 只供数据。
- **复杂编码/解码边角**：EncoderMethod/DecoderMethod 手写钩子（第 5 章）。
- **匹配能力边界**：GISel 无法导入的 pattern（第 6 章 E05 的 11.7 万行警告是常态而非异常）。

经验法则：**重复 ×3 以上且结构稳定的东西交给 TableGen；含判断树、状态机、权衡逻辑的东西留在 C++**。判断依据是"出错时希望诊断落在哪一层"——schema 错误能在 tblgen 阶段暴露（类型检查、assert、VerifyInstructionFlags），比 C++ 编译错误或运行时错误便宜得多。

### 11.3 给现有项目增加描述或生成器的路径

1. **只加数据**（最常见）：在现有 schema 下写 def/multiclass。成本最低，无 C++ 改动。
2. **加 schema 字段**：改 `.td` 的 class + 读取该字段的包装层与 emitter。前端零改动——第 4 章说明过 schema 即接口。
3. **加 emitter**：llvm 侧写新 .cpp + 静态 `TableGen::Emitter::Opt`（参考 `TableGenBackendSkeleton.cpp`）；clang 侧改集中式 switch；mlir 侧写 `GenRegistration`。**建议先写"报告器"而非"生成器"**——一个只打印字段清单的 emitter 就能验证 schema 理解，再逐步加生成逻辑。
4. **测试先行**：仿照 `llvm/test/TableGen/` 模式，正例查输出结构、负例查诊断行列；生成物消费端另配 codegen/编译测试。

### 11.4 迁移到自研编译栈的适用性（谨慎外推）

对昇腾/PyPTO/CANN 这类栈的迁移评估，本文提供的是**方法而非结论**：

- 可迁移的：schema 设计模式（Instruction/Register/调度三件套）、emitter 分层（Common 包装 + 多投影）、GET_* 宏复用机制、确定性工程（唯一化 + 排序）。
- 必须先确认的：输入描述格式与目标版本的对应关系、构建链集成点、消费者接口（表结构是否稳定）。
- 禁止的推导：用 `.td` 行数比例估算工期或人力（第 7 章三口径实验证明行数与展开规模可以差一个数量级）；用"生成成功"代替"运行时正确"（E05 的警告规模说明导入率需要实测）。
- 任何迁移建议应以一个小原型（一条指令从 .td 到可执行编码的完整链）为支撑再谈规模。

---

## 附录 A 实验索引

| 编号 | 内容 | 状态 | 证据位置 |
|---|---|---|---|
| E01 | multiclass+foreach+defm+let 展开 | ✅ 4 record 全验证 | TableGen-notes/experiments/E01-expand/ |
| E02 | 字段/参数消解时机 + assert 负例 | ✅ 正例退 0 负例退 1 | TableGen-notes/experiments/E02-resolve/ |
| E04 | MSP430 9 动作生成 | ✅ 全退 0，含 ADD16rr 全投影 | TableGen-notes/experiments/E04-msp430/ |
| E05 | AMDGPU GlobalISel | ✅ 105MB 产物 + 11.7 万行警告 | TableGen-notes/experiments/E05-gisel/ |
| E07 | NVPTX 动作边界 | ✅ 静态（6 动作，无 emitter） | 正文 5.4 |
| E08 | intrinsic 三口径 | ✅ 31668 def / 2797 枚举 | TableGen-notes/experiments/E08-intrinsic/ |
| E09 | Clang NoInline 链 | ✅ 生成 + 消费点定位 | TableGen-notes/experiments/E09-clang/ |
| E10 | MLIR arith.addi 三链 | ✅ 生成 + 消费点定位 | TableGen-notes/experiments/E10-mlir/ |
| E12 | 确定性与计时 | ✅ SHA256 一致 + 阶段计时 | TableGen-notes/experiments/E12-determinism/ |

未完成（方案保留项）：E03（自定义 emitter 原型）、E06（调度差分运行时验证）、E11（构建依赖运行时实验）。这些需要重建宿主工具或改动构建树，按方案安排在后续阶段；本文相应结论均已标注【静态】。

## 附录 B 防误读清单

- `.td` 不只描述指令：Clang 属性、MLIR op、诊断、选项共用同一前端（第 8、9 章）。
- `Instruction`/`Attr`/`Op` 都是 schema 不是内建（第 1.1、4.1 节）。
- pattern 写进 .td ≠ 被 selector 导入（第 6.2 节，E05 实测）。
- 生成 C++ ≠ 语义自动完成：fold、IR 投影、调度决策都手写（第 7.1、8.1、9.1 节）。
- 寄存器描述 ≠ 寄存器分配（NVPTX 反例，第 5.4 节）。
- DRR ≠ 机器选指（第 9.3 节对照表）。
- 输出稳定 ≠ 跨版本兼容（第 10.4 节）。
- 行数 ≠ 工作量 ≠ 运行时性能（第 7.2 节三口径）。
