# RegAlloc 深度分析 — 基线存档（Task 0）

日期：2026-09-29
基准：llvm-project main @ `3eda2aebadd4`

## 文件行数（实测 wc -l）

### 地基层
| 文件 | 行数 | 职责 |
|---|---|---|
| SlotIndexes.cpp | 329 | 指令→槽位线性编址 |
| LiveIntervals.cpp | 1886 | 活跃区间构造 pass |
| LiveInterval.cpp | 1438 | 区间/子区间/LaneMask 数据结构 |
| LiveRegMatrix.cpp | 384 | 无显式干涉图（查矩阵） |
| VirtRegMap.cpp | 799 | vreg→preg + 替代物映射 |
| RegisterCoalescer.cpp | 4434 | 最大文件（协作视角，不全量精读） |

### 策略层（4 allocator）
| 文件 | 行数 | 策略 |
|---|---|---|
| RegAllocFast.cpp | 1971 | 线性扫描（-O0） |
| RegAllocBasic.cpp | 256 | Greedy 退化版 |
| RegAllocGreedy.cpp | 3008 | 贪心+分裂（-O2 默认） |
| RegAllocPBQP.cpp | 961 | 图着色研究残余 |

### spill 链
| 文件 | 行数 |
|---|---|
| InlineSpiller.cpp | 1965 |
| SplitKit.cpp | 1944 |
| Spiller.cpp | （接口） |

### 顾问层（2×2）
| 文件 | 行数 |
|---|---|
| RegAllocEvictionAdvisor.cpp | 373（规则） |
| MLRegAllocEvictAdvisor.cpp | 1089（ML） |
| RegAllocPriorityAdvisor.cpp | （规则） |
| MLRegAllocPriorityAdvisor.cpp | （ML） |

## 测试基线
- llvm/test/CodeGen/MLRegAlloc/ 存在（ML 顾问测试+训练工具）
- llvm/test/CodeGen/Generic/ 有 regalloc 相关

## 动态验证通道（AMDGPU 项目已验证可用的）
- -debug-only=regalloc（GREEDY 日志，ra_log 先例）
- -print-after=slotindexes / -print-after=greedy / -print-after=virtregrewriter
- -regalloc=fast/basic/greedy/pbqp 四策略切换
- aarch64 host .ll 可用（build-debug 含 AArch64）

## 子任务分工
| Notes | 章节 | 内容 |
|---|---|---|
| 01-foundation.md | §2+§3 | SlotIndexes + 活跃区间族 |
| 02-matrix.md | §4 | LiveRegMatrix + VirtRegMap |
| 03-fast.md | §5 | RegAllocFast 线性扫描 |
| 04-greedy.md | §6 | Greedy 主流程 + spill 链 |
| 05-basic-pbqp.md | §7 | Basic + PBQP 考古 |
| 06-advisors.md | §8 | 顾问层 2×2 |
| 07-variants.md | §9 | 变体层 + target hook 清单 |
