# 09 MLIR ODS、格式与 DRR（笔记）

## 驱动结构

mlir-tblgen 用分布式注册：mlir/lib/TableGen/GenInfo.cpp:17-22 全局
`ManagedStatic<std::vector<GenInfo>> generatorRegistry`；每个 emitter .cpp 顶层
`static mlir::GenRegistration gen("gen-op-decls", …)` 静态注册。
mlir/lib/Tools/mlir-tblgen/MlirTblgenMain.cpp:139-164 只有 `cl::opt<const GenInfo*>`
+ `GenNameParser`，把回调转给通用 TableGenMain —— 新增 emitter 不改主驱动。
（Clang 是集中式 enum+switch；见 08 笔记。）

## ODS 包装层

mlir::tblgen::Operator（mlir/include/mlir/TableGen/Operator.h:85，
实现 mlir/lib/TableGen/Operator.cpp:41-61）：构造时从 Record 抽 opDialect，
按 `_` 切 def 名得方言前缀与 C++ 类名；`getOperationName()`(:63-69) 拼出
`"arith.addi"`；`assertInvariants`(:114-150) 检查 operand/result 命名冲突。

## arith.addi 三条生成链（E10，全部退出 0）

1. **ODS 定义**（mlir/include/mlir/Dialect/Arith/IR/ArithOps.td:271-308）：
   `def Arith_AddIOp : Arith_IntBinaryOpWithOverflowFlags<"addi",
   [Commutative, DeclareOpInterfaceMethods<InferIntDivisibilityOpInterface>]> { …
   let hasFolder = 1; let hasCanonicalizer = 1; }`
   基类链：Arith_Op(:33) → Arith_ArithOp(:42，+SameOperandsAndResultType)
   → Arith_BinaryOp(:52，基础格式 `"$lhs `,` $rhs attr-dict `:` type($result)"`)
   → Arith_IntBinaryOpWithOverflowFlags(:193，Arguments/Results/overflowFlags attr，
   **覆盖格式**)。addi **最终生效的格式**是 :203 的
   `[{ $lhs `,` $rhs (`overflow` `` $overflowFlags^)? attr-dict `:` type($result) }]`——
   比基类多一个可选 overflow 子句。注意 `type($result)` 的类型推导依赖
   SameOperandsAndResultType 等 ODS 约束，格式字符串本身不提供这些信息。

2. **-gen-op-decls → ArithOps.h.inc**（实验产物）：
   `class AddIOp`（:1620 起）+ `AddIOpGenericAdaptor`(:1677) +
   `AddIOpAdaptor`(:1719)；parse/print/verify/build 声明、因 hasFolder/
   hasCanonicalizer 产生的 `fold()`/`getCanonicalizationPatterns()` 声明。
   消费：mlir/include/mlir/Dialect/Arith/IR/Arith.h:27-28
   `#define GET_OP_CLASSES` + `#include "mlir/Dialect/Arith/IR/ArithOps.h.inc"`。

3. **-gen-op-defs → ArithOps.cpp.inc**（实验产物）：
   builders/verify/parse/print 实现（如 `AddIOp::setPropertiesFromAttr` :974）。
   消费：mlir/lib/Dialect/Arith/IR/ArithOps.cpp:3443-3444 同宏模式 include。
   **手写与生成的边界（已修正，原笔记"canonicalize 必须手写"不成立）**：
   - :433 `AddIOp::fold`（addi(x,0)→x 等）——**手写 C++**。`hasFolder=1`
     只生成 `fold()` 的**声明**，实现必须手写：这条路只消样板不消语义。
   - canonicalize 不同：`hasCanonicalizer=1` 同样只提供
     `getCanonicalizationPatterns()` 的声明，但**实现可以由 DRR 生成**——
     反例即 `AddIAddConstant`（见下条 -gen-rewriters 产物：
     ArithCanonicalization.inc:729 `struct AddIAddConstant : public
     ::mlir::RewritePattern`，:732 `matchAndRewrite` 由 DRR 生成）。
     准确边界：**DRR 生成匹配、构造和替换流程**；本例仍依赖**手写 helper
     与注册**——生成代码调用 `addIntegerAttrs`（产物 :780，ArithOps.cpp:56
     手写，经 `AddIntAttrs : NativeCodeCall` 注入）与 `mergeOverflowFlags`
     （产物 :787，ArithOps.cpp:88 手写）；:453 `getCanonicalizationPatterns`
     里手写 `patterns.add<AddIAddConstant, AddISubConstantRHS, …>(context);`
     注册。
   - :200 `#include "ArithCanonicalization.inc"`（匿名 namespace）引入生成规则。

4. **-gen-rewriters → ArithCanonicalization.inc**（实验产物）：
   源规则 mlir/lib/Dialect/Arith/IR/ArithCanonicalization.td:73-78
   `def AddIAddConstant : Pat<(Arith_AddIOp:$res (Arith_AddIOp $x,
   (ConstantLikeMatcher APIntAttr:$c0), $ovf1), (ConstantLikeMatcher APIntAttr:$c1), $ovf2),
   (Arith_AddIOp $x, (Arith_ConstantOp (AddIntAttrs $res, $c0, $c1)),
   (MergeOverflow $ovf1, $ovf2))>;`
   生成器 mlir/tools/mlir-tblgen/RewriterGen.cpp:2102 注册；PatternEmitter(:65)
   生成继承 `mlir::RewritePattern` 的 struct + `populateWithGenerated`(:2093)。
   `NativeCodeCall`（AddIntAttrs/MergeOverflow）允许嵌入任意 C++。

## assemblyFormat 生成

不是独立注册项：OpDefinitionsGen.cpp:1049 调 `generateOpFormat`（OpFormatGen.h:23）。
把格式串解析成 FormatElement 序列（OperationFormat，OpFormatGen.cpp:313），
为 parser/printer 各生成一遍 visitor 代码，写进 OpClass 方法体。

## DRR vs 机器选指 pattern（边界）

| | MLIR DRR | LLVM SDAG/GISel pattern |
|---|---|---|
| 匹配单位 | Operation*（开放类型系统） | SDNode/MachineInstr（固定 ValueType/LLT） |
| 产物 | C++ RewritePattern 子类 | 匹配表（字节码/C++ switch） |
| 时机 | pass 运行时（greedy driver） | 指令选择 |
| 任意代码 | NativeCodeCall | 手写 C++ 谓词/变换 |

## 构建规则

- mlir/include/mlir/Dialect/Arith/IR/CMakeLists.txt：`add_mlir_dialect(ArithOps arith)`
  → mlir_tablegen(-gen-op-decls/-gen-op-defs/-gen-typedef-*/-gen-dialect-*)。
- mlir/lib/Dialect/Arith/IR/CMakeLists.txt:9-11：
  `mlir_tablegen(ArithCanonicalization.inc -gen-rewriters)`。
- mlir/cmake/modules/AddMLIR.cmake:5-9 `mlir_tablegen()` = 通用 tablegen(MLIR …)
  的薄封装 + TABLEGEN_OUTPUT 累积；:147-156 `add_mlir_dialect`。
