# ISel 深度分析 — 基线存档（Task 0）

日期：2026-09-30
基准：llvm-project main @ `3eda2aebadd4`

## 文件行数（实测 wc -l）

### SelectionDAG 族（87,708 行）
| 文件 | 行数 | 职责 |
|---|---|---|
| DAGCombiner.cpp | 32,531 | LLVM 单文件之最——combine 规则 |
| SelectionDAG.cpp | 15,402 | DAG 数据结构/CSE/不变量 |
| TargetLowering.cpp | 14,431 | target 钩子基类/LegalizeAction 表 |
| SelectionDAGBuilder.cpp | 13,307 | IR→DAG 的 visit 分发 |
| LegalizeDAG.cpp | 6,361 | expand/promote/custom 分派 |
| SelectionDAGISel.cpp | 4,638 | matcher 表解释器+驱动 |
| LegalizeTypes.cpp | 1,038 | 类型软化/扩宽（+4 个兄弟文件） |

### GlobalISel 族（8,908+ 行，CombinerHelper 系另计）
| 文件 | 行数 | 职责 |
|---|---|---|
| IRTranslator.cpp | 5,426 | IR→G_MIR（占 61%） |
| RegBankSelect.cpp | 1,794 | bank 映射 |
| InstructionSelect.cpp | 440 | select 驱动 |
| Legalizer.cpp | 433 | 合法化驱动 |
| CSEMIRBuilder.cpp | 405 | G_MIR 的 CSE |
| Combiner.cpp | 352 | combiner 驱动 |
| GIMatchTableExecutor.cpp | — | 表执行器 |
| + LegalityPredicates/LegalizeMutations/CombinerHelper×5/Utils 系 | — | 谓词/规则/工具 |

## DEBUG_TYPE 速查（实测 grep）

| 通道 | DEBUG_TYPE |
|---|---|
| SDAG 构建/ISel 驱动 | `isel`（Builder/ISel/FastISel 共用） |
| DAG 结构 | `selectiondag` |
| DAG 合并 | `dagcombine` |
| 合法化（操作） | `legalizedag` |
| 合法化（类型） | `legalize-types`（5 文件共用） |
| 向量操作合法化 | `legalizevectorops` |
| GISel combiner | `gi-combiner`（7 文件共用） |
| GISel match 表 | `gi-match-table-executor` |
| GISel CSE | `cseinfo` |
| call lowering（GISel） | `call-lowering` |
| 指令发射 | `instr-emitter` |

## 子任务分工
| Notes | 章节 | 内容 |
|---|---|---|
| 01-builder.md | §2 | SelectionDAGBuilder 13.3K |
| 02-legalize.md | §3+§4 | DAG 结构 + Legalize 三部曲 |
| 03-combiner.md | §5 | DAGCombiner 32K |
| 04-select.md | §6 | SelectionDAGISel + FastISel |
| 05-gisel.md | §7 | GISel 正交流水 |
| 06-two-roads.md | §8 | 两路线对比/fallback/迁移现状 |
