# 06 SelectionDAG 与 GlobalISel 模式生成（笔记）

## SDAG 流水线（静态锚点）

- 前端领域模型：Common/CodeGenDAGPatterns.cpp:3345 固定流水线
  ParseNodeInfo → ParseNodeTransforms → ParseComplexPatterns →
  ParsePatternFragments(in) → ParseDefaultOperands → ParseInstructions →
  ParsePatternFragments(out) → ParsePatterns → GenerateVariants →
  InferInstructionFlags → VerifyInstructionFlags。
- 类型推断：struct TypeInfer（CodeGenDAGPatterns.h:239），Enforce* 系列约束传播
  （cpp :394-763），合法类型来自 target 的 LegalValueTypes（:852）。
- mayLoad/mayStore/hasSideEffects 三态设计：Target.td:719-720 故意留 `?`；
  CodeGenInstruction.cpp:459-465 `getValueAsBitOrUnset` 保留未设态；
  InferInstructionFlags(:4239) 从 pattern 推断；VerifyInstructionFlags(:4300) 校验冲突。
- 发射三阶段（DAGISelEmitter.cpp:192-215）：
  `stable_sort(Patterns, PatternSortingPredicate)`（complexity 降序→大小→UID 稳定序）
  → `ConvertPatternToMatcherList`（DAGISelMatcherGen.cpp:1066）
  → `OptimizeMatcher`（DAGISelMatcherOpt.cpp:664：ContractNodes+FactorNodes）
  → `EmitMatcherTable`（DAGISelMatcherEmitter.cpp，生成 SelectCode 函数 +
  字节码表，运行时由 SelectionDAGISel::SelectCodeCommon 解释）。
- **交换变体的来源（已修正，原先误归因于指令字段）**：GenerateVariants
  （CodeGenDAGPatterns.cpp:4887）检查的是 pattern 树中**源 SDNode** 的
  NodeInfo 属性 `SDNPCommutative`（:4858），不是指令的 `isCommutable` 字段。
  两条机制互相独立：`add` 这个 SDNode 带 SDNPCommutative → pattern 层产生
  交换操作数变体；指令的 `isCommutable=1`（来自 Arith multiclass 的
  commutes 参数，见 05 笔记）→ 走另一条路生成机器指令层的
  `MCID::Commutable` flag（E04 ADD16rr MCInstrDesc 中的 `1<<Commutable`）。
  二者效果正交：一个影响 pattern 匹配覆盖面，一个影响机器层两地址指令的
  交换合法化。

## GlobalISel 导入（E05 实验 + 静态锚点）

- GlobalISelEmitter.cpp:316 类继承 GlobalISelCombinerEmitter 共用的
  MatchTable 基础设施（Common/GlobalISel/：MatchTable、Patterns、CXXPredicates、
  CodeExpander、CombinerUtils）。
- 单条导入 runOnPattern(:2160)：根必须是平凡 operator(:2182-2187) 否则
  `failedImport`；谓词 importRulePredicates(:2171)；
  createAndImportSelDAGMatcher(:795)；Dst 是 regclass 叶子时生成
  COPY+ConstrainOperandToRegClassAction(:2221-2251)。
- 主循环(:2481-2608)：getGISelShouldIgnore 静默跳过(:2515)；失败时
  `-warn-on-skipped-patterns` 触发 PrintWarning "Skipped pattern: …"(:2530-2532)，
  否则 consumeError 静默(:2534)；计数 NumPatternImportsSkipped(:2536)。
- 排序按 complexity score(:2577-2591)，buildMatchTable 输出
  GET_GLOBALISEL_IMPL / PREDICATES / TEMPORARIES 段。

**E05 实测**（**已按归档日志重新统计，合计恰为 10,120**）：AMDGPUGISel.td → 105 MB .inc，
stderr 共 117,672 行，其中 `Skipped pattern` 警告 10,120 条。原因分布：

| 拒绝原因（stderr 首行模式） | 条数 |
|---|---|
| Pattern operator lacks an equivalent Instruction | 8,017 |
| unsupported type for Src operand | 1,815 |
| EXTRACT_SUBREG child could not be coerced to a register class | 75 |
| Src pattern child has predicate | 44 |
| Pattern defines a physical register | 42 |
| SDNodeXForm has no GISel equivalent（as_i16imm 40 / as_i64imm 15 / IMMBitSelConst 6 / bitcast_fpimm_to_i16 2） | 63 |
| Src pattern root isn't a trivial operator | 24 |
| SelectionDAG ComplexPattern | 22 |
| Could not infer register class for result | 14 |
| Src pattern child has unsupported predicate | 4 |

主要拒绝原因是 **pattern 算子缺少等价 Instruction**（8,017/10,120 ≈ 79%）——
发生在**源模式匹配器导入阶段**：`createAndImportSelDAGMatcher`
（GlobalISelEmitter.cpp:814-817）对源 SDNode 调 `findNodeEquiv` 查
GINodeEquiv 映射，查不到即 `failedImport`，无法建立 GMIR opcode 匹配——
**不是**目标指令缺少渲染器。原笔记"绝大多数因匿名谓词被拒绝"不成立：
带谓词的根（`Src pattern root isn't a trivial operator
(Has a predicate (anonymous_21308)…)`，SOPInstructions.td:302 例）只有 24 条，
且**匿名命名本身不是拒绝条件**——它是谓词附着于根节点导致根不平凡的表象。
这仍说明"能写进 .td ≠ 能被 GISel 导入"，但拒绝的主力是 GINodeEquiv
覆盖缺口，不是谓词。

- 测试锚点：llvm/test/TableGen/GlobalISelEmitter/SkippedPatterns.td
  两个 RUN 行：无 -DIGNORE 期望两条具体 warning；-DIGNORE（GISelShouldIgnore=1）
  期望静默。

## 消费点

- AMDGPUInstructionSelector.cpp:36-50：`#define GET_GLOBALISEL_IMPL`（构造时注入
  match table）+ PREDICATES_INIT + TEMPORARIES_INIT 三次 include 同一 .inc。
- MSP430 走 SDAG：MSP430GenDAGISel.inc（E04，328KB）由 MSP430ISelDAGToDAG 消费。

## 共享与限制（判断）

- 能共享：纯算术/位运算、无复杂谓词、根为平凡 operator 的 pattern ——
  两份后端都能消费同一份 `Pattern` 字段。
- 需要额外描述：GISel 需要 RegisterBank 信息（-gen-register-bank）、
  类型系统不同（LLT vs EVT，AMDGPU 用 -gisel-extended-llt）；
  带 ComplexPattern/自定义谓词的常需手写 InstructionSelector 补充
  （AMDGPUInstructionSelector.cpp 中大量手写 select* 方法即此）。
- 被拒绝的（E05 实测主因）：pattern 算子缺少等价 Instruction（79%）；
  其次是源操作数类型不支持。根非平凡 operator（含谓词附着）、complex
  suboperand 重复绑定等只占零头（SkippedPatterns.td 覆盖的是这两类小头）。
