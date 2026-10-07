# Sched 深度分析 — 基线存档（Task 0）

日期：2026-09-30
基准：llvm-project main @ `3eda2aebadd4`

## 文件行数（实测 wc -l）

### 通用调度核心
| 文件 | 行数 | DEBUG_TYPE |
|---|---|---|
| MachineScheduler.cpp | 5,037 | machine-scheduler |
| ScheduleDAGInstrs.cpp | 1,446 | machine-scheduler（共用） |
| ScheduleDAG.cpp | 764 | pre-RA-sched（SDAG 源级调度） |
| MachineTraceMetrics.cpp | 1,387 | machine-trace-metrics（消费者视角引用） |
| TargetSchedule.cpp | — | （TSI 查询层） |

### PostRA 与 Hazard
| 文件 | 行数 | DEBUG_TYPE |
|---|---|---|
| PostRASchedulerList.cpp | 721 | post-RA-sched |
| ScoreboardHazardRecognizer.cpp | — | （变量 DebugType） |
| MultiHazardRecognizer.cpp | — | — |
| PostRAHazardRecognizer.cpp | — | post-RA-hazard-rec |

### 专项调度器
| 文件 | 行数 | DEBUG_TYPE |
|---|---|---|
| ModuloSchedule.cpp | — | **pipeliner**（软件流水） |
| VLIWMachineScheduler.cpp | — | machine-scheduler（共用） |
| WindowScheduler.cpp | — | **pipeliner**（共用） |

注意：ModuloSchedule/WindowScheduler 共用 "pipeliner"——同属软件流水族。

## 子任务分工
| Notes | 章节 | 内容 |
|---|---|---|
| 01-dag.md | §2 | Region 与 DAG 构建 |
| 02-skeleton.md | §3 | 列表调度骨架 |
| 03-policy.md | §4 | 策略插件 + Mutation |
| 04-hazard.md | §5 | Hazard 协议 |
| 05-timing.md | §6+§7 | 三时点 + 专项 |
