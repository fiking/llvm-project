# 02 .td 语法、语言语义与展开（实验笔记）

## E01：multiclass + foreach + defm + let 的组合展开

输入 `experiments/E01-expand/input/expand.td`：

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

`--print-records` 结果（已用 `--dump-json` + python 断言复核）：

- 4 个 def：`ADD32_rr`(Opcode=32)、`ADD32_ri`(33)、`ADD64_rr`(64)、`ADD64_ri`(65)，
  全部 `Predicated = 1`。
- class `Op` 本身出现在 "Classes" 段，不产生 def。
- multiclass `ALU` 不产生任何名为 `ALU` 的 record；`defm ADD#W` 也不产生名为
  `ADD32`/`ADD64` 的容器 record。

机制要点（静态锚点）：
- `NAME` 语义（**已修正**）：`NAME` 在 class 与 multiclass 中都是隐式模板参数，
  **绑定到实例化后的 record 名**，不是定义它的 class 名。实测：
  `class C { string N = NAME; } def D : C;` → `D.N = "D"`。
- 名字生成：multiclass 内的 `def _rr` 未引用 `NAME`，最终名 = defm 名 + `_rr`，
  由 TGParser.cpp 的 `QualifiedNameOfImplicitName`(:138) 与
  `resolveArgumentsOfMultiClass` 中 `Substs.emplace_back(QualifiedNameOfImplicitName(MC), DefmName)`(:691) 完成。
- `foreach` 的展开在 TGParser.cpp `resolve(const ForeachLoop&, …)`(:468)：
  迭代变量通过 `MapResolver` 绑定后递归 `resolve(Entries, …)`。
- `if` 语句在 AST 层被去糖为无迭代变量的 `ForeachLoop`（TGParser.h:74-77 注释、
  ParseIf :4214-4281）。
- 外层 `let … in` 把 `LetRecord` 压入 `LetStack`（ParseTopLevelLet :4447），
  在 record 落地时由 `ApplyLetStack`(:3922) 统一 `SetValue`。

## E02：字段引用消解时机

输入 `experiments/E02-resolve/input/syntax.td`（见该目录）。结果（`--print-records`）：

| record | Opcode | Encoding | Width | FieldNext | ParamNext | Description |
|---|---|---|---|---|---|---|
| Basic | 16 | 0x10 | 32 | 33 | 33 | — |
| Wide  | 17 | 0x11 | 64 | **65** | **33** | — |
| Named | 18 | 0x15（位段覆盖后） | 32 | 33 | 33 | "sub.local" |

关键观察：
1. `Wide` 的外层 `let Width = 64` 生效后，依赖字段 `FieldNext = !add(Width, 1)`
   消解为 65 —— 字段引用（`Width`）在最终 record 中重新消解；
   而 `ParamNext = !add(W, 1)` 中的模板参数 `W` 保持实例化时的 32 —— 模板参数
   在类实例化时即被替换，不受后续 let 影响。
2. `let Encoding{3...0} = 5` 把 0x12 的低 4 位改成 0x5，得 0x15 —— 位段覆盖作用于
   已实例化的值。
3. record 内的 `defvar Label` 不成为字段；`Description` 引用了它的值 "sub.local"。

负例 `wzero.td`（W=0 触发 class body 内 assert）：

```
input/wzero.td:6:10: error: assertion failed: Width must be positive
input/wzero.td:8:5: error: assertion failed in this record
```

退出码 1。assert 的求值时机：addDefOne（TGParser.cpp:609）→
Record::checkRecordAssertions（Record.cpp:3087，RecordResolver + setFinal(true)）→
CheckAssert（Error.cpp:163）。非致命：累计进 ErrorsPrinted，Main.cpp:174 统一退出。

## 机制边界（静态）

- 预处理（include、#define/#ifdef/#else/#endif）完全在 TGLexer 层消化：
  PrepIncludeStack 管理 include 栈与条件栈（TGLexer.h:294-327）；
  宏只有"是否定义"，无值替换。Parser 看到的是干净的 token 流。
- bang operator 的折叠模型（**已修正**：原笔记"解析期只建 AST 不求值"不成立——
  实测 `/tmp/verify-fold.td`：`class D { int V = !add(1,2); } def G : D;`
  --print-records 在未实例化的 class D 中已打印 `int V = 3`）：
  ParseOperation → UnOpInit/BinOpInit/TernOpInit::get **构造时即尝试 Fold**
  （各 OpInit::get 内联调用 Fold，Record.cpp:762/1208/1730），能折的当场变常量；
  含未绑定模板参数/字段引用的折不了，保留 AST，在参数替换与
  resolveReferences(Resolver&) 消解时**继续折叠**。即：解析时尝试折叠，
  消解时继续折叠，两阶段共用同一 Fold 实现。
- `let append` / `let prepend`（LetMode 枚举，TGParser.h:34；SetValue :241-346）：
  对 list 用 LISTCONCAT，对 string/code 用 STRCONCAT，对 dag 用 CONCAT。
- 语句位置限制（ParseObject :4720-4758）：multiclass 内禁止 `class`/`defset`；
  foreach 内禁止 `class`/`multiclass`。
