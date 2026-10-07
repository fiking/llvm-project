# §5+§6 DAGCombiner + SelectionDAGISel + FastISel 定位深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，build-debug。
> 引用格式 `文件:行号`。
> 素材来源：子代理调研（API 超时死亡，transcript 素材回收：visitAND/GatherAllAliases/FastISel 开关等 62 次活动记录）+ 主会话补骨架核实与代写。

---

## 5.1 DAGCombiner 驱动循环（32,531 行的骨架）

**Run(CombineLevel AtLevel)**（DAGCombiner.cpp:1845）：
- **三个合法化旗标由 Level 派生**：LegalDAG = Level>=AfterLegalizeDAG、LegalOperations = Level>=AfterLegalizeVectorOps、LegalTypes = Level>=AfterLegalizeTypes（:1847-1850）——**与五段 Combine 管线（02-legalize.md §3.5）的精确对接**
- **拓扑排序可选**：UseTopologicalSorting（cl::opt 或 TLI.useTopologicalSorting——target 可选更快模式）；开启则 DAG.AssignTopologicalOrder()+**逆序**入表（拓扑序保证 combine 结果不重复处理），否则正序
- 全节点入 worklist（AddNodes/PruningList 机制：只有 use_empty 的节点进 Pruning 候选）
- `combine(SDNode*)`（:2157）是单节点入口——大 switch 分发到 visitXXX

## 5.2 "一条规则一个函数"组织（量化）

- **146 个 `SDValue DAGCombiner::visitXXX`**（grep -c 实测）——每条 IR/ISD 指令类一个 visit，规则内 if 条件链+return DAG.getXXX
- 代表规则（子代理 transcript 素材+核实）：
  - **visitAND**（:7861 起）：MatchRotatePosNeg/MatchRotate（:672/:680）——and+shift 的旋转模式识别
  - **GatherAllAliases**（:701 声明/:21922 调用/:32235 定义——跨三千行的组织）：load/store 别名分析（invariant memory 与 store 不别名判定）
- **PerformDAGCombine 钩子仅 1 处调用点**（grep 实测）——target 介入 Combiner 是单一入口的窄通道（vs Legalize 的三张表+custom 钩子面）
- **TargetLoweringOpt 事务**（:1490/:1509）：TLO 打包 (DAG, LegalTypes, LegalOperations)——combine 的合法性检查与 level 联动（:866 isOperationLegalOrCustom、:890 LegalTypes 门控）

**为什么 32K**：146 visit × 平均 200+ 行（每 visit 内多条规则 × 模式条件链）+ 别名分析等基础设施——**规则数量的线性膨胀**而非算法复杂度。

## 5.3 SelectionDAGISel（4,638 行）：matcher 表解释器

- **MorphNodeTo 协议**（:2778 起 isMorphNodeTo 参数、:2799-2800 ChainNode==NodeToMatch 自替换特例、:2904 空节点替换注释）——节点原位变形（保 id/保位置），glue/chain 重新接线
- SelectCodeCommon 是 TableGen matcher 表的解释器：表由 .td pattern 生成（OPC_SwitchOpcode/OPC_CheckPatternPredicate/OPC_MorphNodeTo 操作码序列），**表驱动 vs target 自定义 Select 的双通道**（AMDGPU/NVPTX 案例见各自 notes）
- DoInstructionSelection 拓扑驱动（从 DAG 根向下）；CodeGenAndEmitDAG 与 InstrEmitter 交接（MachineInstr 生成 + PHINodesToUpdate 回填——衔接 01-builder §2.2 的边界协议）

## 5.4 FastISel 定位（不深潜）

- **-O0 快速路径**：O0WantsFastISel（TargetPassConfig.cpp:178 EnableFastISelOption）；简化 Builder+简化 Select（按 IR 指令直出，跳过 DAG）
- **GPU target 弃用**：NVPTX "FastISel is disabled" 日志先例（NVPTX-notes/00 冒烟实测）；AMDGPU 同（getEnableFastISel 未覆写→默认关）
- **与 GISel 的关系**：长期被 GISel 取代计划（-global-isel 的 -O0 路径）——FastISel 是"SDAG 太慢"的第一代答案，GISel 是第二代

## 5.5 动态验证建议（供复现）

```bash
# combine 前后 DAG diff（-debug-only=dagcombine 打开 combine 日志）
./build-debug/bin/llc -mtriple=aarch64 -O1 -debug-only=dagcombine -o /dev/null <用例>.ll
# Morphed 序列（-debug-only=isel-dump 或 isel）
./build-debug/bin/llc -mtriple=aarch64 -O1 -debug-only=isel-dump -o /dev/null <用例>.ll | grep Morphed
```

## 5.6 昇腾映射（推理级，待验证）

**PyPTO tile 规则系统的规模控制教训**：
1. **146 visit 的"规则爆炸"警示**：tile 优化规则若按"一条规则一个函数"组织，重蹈 32K 覆辙——**GISel 的 td 化规则**（AMDGPUCombine.td 已析）是出路：规则声明式化+自动生成执行器
2. **Level 旗标联动**：tile combiner 的合法化阶段感知（LegalTypes/LegalOperations 对应 tile 的 shape/layout 合法化）——三个 bool 的轻量状态
3. **PerformDAGCombine 单一窄通道**：target 介入点越窄，通用层越可维护——PyPTO 的 tile 特化规则应有同样的集中入口

---

## 引用清单

| 引用 | 内容 |
|---|---|
| DAGCombiner.cpp:87, 172-173, 1845-1875, 672-680, 701, 866, 890, 1490-1509, 2157, 7861+, 21922, 32235 | 驱动/规则/钩子 |
| SelectionDAGISel.cpp:117, 2778-2904 | MorphNodeTo |
| TargetPassConfig.cpp:178 | FastISel 开关 |
| 量化：146 visit（grep -c）/PerformDAGCombine 1 处（grep -cn） | 主会话实测 |
