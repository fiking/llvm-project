# LLVM 指令选择通用基础设施深度分析

> 数据基准：llvm-project main @ `3eda2aebadd4`（2026-09-30），build-debug 实测。
> 方法：静态分析（引用一律 `文件:行号`，子代理+主会话全部实读核对）+ 动态验证（isel-dump/ legalizedag / legalize-types / -stop-after=irtranslator / 双选择器管线 / 13 vs 14 指令对比）。
> 八部曲定位：横向对比 → AMDGPU 后端 → NVPTX 后端 → clang-AMDGPU → clang-NVPTX → RA 基础设施 → **本文档（ISel 基础设施——SDAG 87.7K vs GISel 8.9K 的本体）**。
> 素材全文：`ISel-notes/01..06-*.md`；scratch/ 存实测产物。

---

## 目录

- §1 摘要与核心论点
- §2 SelectionDAGBuilder（IR→DAG）
- §3 SDAG 数据结构（SDNode/CSE/chain-glue）
- §4 Legalize 三部曲（操作/类型/向量）
- §5 DAGCombiner（32.5K 行的规则世界）
- §6 SelectionDAGISel + FastISel 定位
- §7 GlobalISel 正交流水
- §9 与八部曲衔接
- §10 昇腾映射
- §11 复现手册

---

## §1 摘要与核心论点

> **指令选择的本质是"模式匹配 + 合法化 + 化简"三个正交问题的编织**。SelectionDAG 把三者编织进单一 DAG（五段 Combine×三段 Legalize 固定管线，target 钩子散布全程）；GlobalISel 拆成正交 pass（IRTranslator/Legalizer/Combiner/RegBankSelect/InstructionSelect）。**10 倍体量差（87.7K vs 8.9K）不是老代码臃肿，是"编织 vs 正交"的架构代价**——DAGCombiner 32,531 行（LLVM 单文件之最）就是编织复杂度的账单。

**五个贯穿性实证**：
1. **SDAG 无 phi**：vreg+CopyFrom/ToReg 是跨块 SSA 逃逸通道（五要素一次实测）；GISel 的 G_PHI 保留（MIR SSA 有 phi）——两条路线的最根本架构差异
2. **五段 Combine×三段 Legalize 固定管线**（CodeGenAndEmitDAG :941-1130）：BeforeLT→LT→AfterLT→LV→AfterLVO→LO→AfterLD→Select——不是循环是管线，终止性由结构保证
3. **146 visit vs 159 Helper 方法**：SDAG "一条规则一个函数"×32K vs GISel match/apply 拆分+td 声明式——规则组织的两代工程学
4. **AArch64 双选择器同管线**（实测）：-O2 默认 irtranslator(93)→instruction-select(104)→aarch64-isel(106)，3/3 函数 reset 回退 SDAG——**"默认跑 GISel+逐函数 fallback"是迁移 10 年的最新形态**
5. **SPIRV 是唯一 GISel-only target**（无沉没成本的生 target 才敢 only）——迁移可行性的自然实验

---

## §2 SelectionDAGBuilder（13,307 行）

**详见 `01-builder.md`**

- **单 switch 分发**（HANDLE_INST 宏，非虚表——ConstantExpr 兼容）；visitPHI=unreachable（PHI 不进 DAG）
- **边界协议三级回退**：NodeMap→getCopyFromRegs→getValueImpl；PHI 常量经 PendingExports、变量登记 PHINodesToUpdate 供 InstrEmitter 回填；**glue 穿线+TokenFactor 汇合**（单 reg 或有 glue 取末 CopyToReg，多 reg 无 glue 才 TF——防环注释）
- **callseq 语义**：两常量=对内/对外 frame，不可嵌套；NVPTX 追加 ProxyReg 防悬空、AMDGPU 合成 0,0 对保下游合法——两 target 的 call 链补偿对照
- StatepointLowering 独立文件占 Builder 总量 10%
- **任务前提修正**：getCaseResults 已不存在（现行 CaseCluster+splitWorkItem 平衡二叉树）；**-debug-only=isel-dump** 才是 DAG dump 通道（非 isel）

## §3 SDAG 数据结构

**详见 `02-legalize.md` §3.1**

- **节点定长+尾部变长 payload+池化回收**（sizeof(LargestSDNode) 定长池+ArrayRecycler 容量桶+子类 16-bit 位域 union）
- **NodeId 双重生命**：普通节点=-1/合法化状态机计数器——零内存开销复用
- **CSE**：SDNodeKey 按 opcode 加键（LOAD/STORE 含 MemVT+AddrSpace+MMO flags）；**glue 恒不 CSE**
- chain（MVT::Other）/glue 类型系统；TokenFactor 合并链

## §4 Legalize 三部曲

**详见 `02-legalize.md` §3.2-3.5**

- **LegalizeOp 动作链**：Legal→return；**Custom 失败 fallthrough Expand**；Expand 失败 fallthrough LibCall——永不死循环的兜底瀑布
- **LegalizeTypes 8 张表单射**（每个非法值恰好进一张：Promoted/Expanded/Softened/SoftPromotedHalfs/ExpandedFloats/Scalarized/Split/Widened）；先扫结果再扫操作数
- **TargetLowering 三张表**：OpActions[VT][Op]/LoadExtActions（uint16 打包 4×4bit）/CondCodeActions（uint32 打包 8×4bit）
- **任务前提修正**：LegalizeResult 三态已重构掉（void+bool+空 SDValue 组合）
- 实测：i8 逐节点 promote、i128→uaddo_carry 链+custom legalization

## §5 DAGCombiner（32,531 行）

**详见 `03-04-combiner-select.md`**

- **Run() 三旗标与五段管线精确对接**（LegalDAG/LegalOperations/LegalTypes 由 Level 派生）；拓扑排序可选（target 可选更快模式）
- **146 个 visitXXX**（量化）；PerformDAGCombine **仅 1 处调用**——target 介入 Combiner 的单一窄通道
- TargetLoweringOpt 事务打包 (DAG, LegalTypes, LegalOperations)
- **为什么 32K**：146 visit × 200+ 行（每 visit 多规则×模式条件链）+别名分析基础设施——规则数量线性膨胀而非算法复杂度

## §6 SelectionDAGISel + FastISel

**详见 `03-04-combiner-select.md`**

- MorphNodeTo 协议（节点原位变形保 id/位置；ChainNode==NodeToMatch 自替换特例）
- SelectCodeCommon 表解释器 vs target 自定义 Select 双通道
- **FastISel 定位**：-O0 第一代答案（GPU 弃用——"FastISel is disabled" 先例）；被 GISel 取代中（AArch64 -O0 已是纯 GISel——§8 实测 md5 相等）

## §7 GlobalISel 正交流水

**详见 `05-gisel.md`**

- **IRTranslator**：55 个 translateXXX（vs SDAG 146 visit——G_* 集 283 个更正交）；**G_PHI 保留**；CSE 默认开；指令级 fallback 出口在翻译入口（TLI->fallBackToDAGISel）
- **Legalizer 谓词化**：std::function 谓词+all/any/predNot 变参组合器+lambda 工厂——**可组合可测试 vs SDAG if-else 海**；双 worklist（Inst/Artifact）两阶段循环
- **Combiner**：观察者协议 4 事件（erasing/created/changing/changed）vs SDAG RAUW 无痕替换；GICombineRule 声明式 (match)+(apply) td 化
- **RegBankSelect**：Fast vs Greedy（任务前提修正：无"完全模式"）；MappingCost 三分量；InsertPoint 惰性物化
- 实测：G_FRAME_INDEX/G_BRCOND/G_PHI dump、i8→i32 legalizer 瞬时完成

---

## §9 与八部曲衔接：变体在本体上的精确位置

| 变体 | 在通用框架中的位置 | 引用 |
|---|---|---|
| AMDGPU 双路径 | SDAG（SIISelLowering 6,460 行 hook 三张表）+ GISel 三大件 24,176 行（bank 约束强需求）+ RegBankLegalize 前置保证 + LCSSA 条件化（无 fallback 时才禁） | AMDGPU-notes/03/04 |
| NVPTX 单路径 | SDAG-only（ISelLowering 8,143 行）+ 零 GISel（vreg 透传无 bank 约束——表面积论证）+ tcgen05 的 100-case 自定义 Select | NVPTX-notes/04 |
| AArch64 迁移前沿 | GISel-first+逐函数 fallback（O>0 非 optnone 回退）——两条路线的真实混跑 | §8（two-roads.md） |

## §10 昇腾映射

**详见 `06-two-roads.md` §8.6 + 各章昇腾节**，汇总：

1. **CCE 路线判定**（待验证）：LLVM fork 大概率 SDAG-only（验证法：grep GlobalISel/IRTranslator 符号）
2. **PyPTO tile 选择的正交化借鉴**（GISel 思想、单路线实现）：
   - 谓词表（LegalityPredicate 组合器）替代 custom hook 散布——tile 合法化规则可组合可测试
   - GICombineRule 声明式 (match)+(apply)——tile 优化规则的规模控制出路（对照 146 visit 教训）
   - 观察者协议 4 事件——tile 增量分析挂观察者而非全量重算
   - 8 张表单射建模——tile 的 shape/dtype/layout 合法化分类学
3. **fallback 机器的前提检验**：PyPTO 无成熟老路线做安全网、无函数级风险异质——**单路线+谓词表更务实**
4. **SDAG 的 SSA 边界协议**：tile DAG 若以 stage 为区域，CopyFrom/ToReg 式 vreg 通道+已知位恢复（AssertZext）是现成方案

## §11 复现手册

```bash
cd ~/code/llvm-project   # main @ 3eda2aebadd4
LLC=build-debug/bin/llc

# DAG dump（注意是 isel-dump 不是 isel！）
$LLC -mtriple=aarch64 -O1 -debug-only=isel-dump -o /dev/null ISel-notes/scratch/builder_test.ll | grep -E "CopyFromReg|callseq|TokenFactor"

# Legalize 实测
printf 'define i8 @f(i8 %a, i8 %b) { %r = add i8 %a, %b ret i8 %r }' > /tmp/p8.ll
$LLC -mtriple=aarch64 -O1 -debug-only=legalize-types -o /dev/null /tmp/p8.ll 2>&1 | grep Promot
$LLC -mtriple=aarch64 -O1 -debug-only=legalizedag -o /dev/null /tmp/e128.ll 2>&1 | grep -E "uaddo|custom"

# Combiner
$LLC -mtriple=aarch64 -O1 -debug-only=dagcombine -o /dev/null <用例> 2>&1 | head

# GISel 流水
$LLC -mtriple=aarch64 -global-isel -stop-after=irtranslator -o - ISel-notes/scratch/builder_test.ll | grep G_
$LLC -mtriple=aarch64 -global-isel -stop-after=legalizer -o - /tmp/p8.ll | grep G_ADD

# 双选择器管线（§8 头条）
$LLC -mtriple=aarch64 -O2 -debug-pass=Structure -o /dev/null <用例> 2>&1 | grep -E "irtranslator|instruction-select|aarch64-isel"
$LLC -mtriple=aarch64 -O2 -stats -o /dev/null ISel-notes/scratch/two_roads.ll 2>&1 | grep reset-machine-function
```

---

## 附录：章节-素材对照与执行注记

| 章 | 素材 | 产出方式 |
|---|---|---|
| §2 | 01-builder.md | 子代理调研（2 前提修正）+主会话验证代写 |
| §3+§4 | 02-legalize.md | 子代理调研（1 前提修正）+主会话补循环驱动与实测 |
| §5+§6 | 03-04-combiner-select.md | 子代理 API 超时死亡→transcript 素材回收+主会话补骨架代写 |
| §7 | 05-gisel.md | 子代理调研（2 前提修正）+主会话补 InstructionSelect 与实测 |
| §8 | 06-two-roads.md | 子代理调研（头条发现）+主会话代写 |

执行注记：1 主会话 + 5 子代理（1 次 API 超时死亡靠 transcript 回收、4 次额度耗尽由主会话代写）。任务前提证伪修正 **7 处**（getCaseResults/LegalizeResult 三态/LegalizerInfo 表结构/RegBankSelect 模式名/isel-dump 通道/AArch64 默认开/-O0 已纯 GISel）——"每章都有任务书预设在源码里不存在"成为本项目最稳定的规律。动态验证全实跑（DAG dump/三 legalize 日志/G_ 前缀 dump/双选择器管线/13 vs 14 指令/3 reset 统计）。
