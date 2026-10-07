# Hexagon（高通 DSP）优化 Pass 设计文档

## 1. 架构概览

Hexagon 是高通的 VLIW DSP 架构，其 LLVM 后端包含 **35 个目标专用 pass**，是 LLVM 中最丰富的后端之一。这源于 Hexagon 架构的几个独特特征：

| 架构特征 | 对应优化需求 |
|----------|-------------|
| VLIW（超长指令字） | 指令打包（Packetizer）、依赖消解、.new 值推广 |
| 硬件循环（LOOP0/LOOP1） | 零开销循环生成、循环对齐 |
| 谓词执行 | 谓词寄存器转换、早期 if-conversion、MUX 展开 |
| HVX 向量单元 | 向量对齐、HVX 惯用法识别、向量循环复用 |
| 双寄存器（64-bit） | 双寄存器拆分、Copy-to-Combine |
| 绝对地址/后递增寻址 | 寻址模式优化、常量扩展 |

所有 Hexagon pass 源码位于 `llvm/lib/Target/Hexagon/`，无外部头文件（均在目录内部）。

---

## 2. Pass 流水线

流水线由 `HexagonPassConfig`（`HexagonTargetMachine.cpp:343`）配置，通过覆写 `TargetPassConfig` 的 6 个钩子方法控制 pass 插入时机。

### 2.1 流水线阶段总览

```
┌─────────────────────────────────────────────────────────────────────┐
│  IR 阶段 (addIRPasses)                                             │
│  ┌──────────────────┐ ┌───────────────┐ ┌───────────────────┐      │
│  │ VectorCombine    │ │ CommonGEP     │ │ GenExtract        │      │
│  │ (HVX 对齐+惯用法) │ │ (公共 GEP)    │ │ (shift+and→extract)│     │
│  └──────────────────┘ └───────────────┘ └───────────────────┘      │
├─────────────────────────────────────────────────────────────────────┤
│  指令选择阶段 (addInstSelector)                                     │
│  OptimizeSZextends → ISelDag → VExtract → GenPredicate            │
│  → LoopRescheduling → SplitDoubleRegs → BitSimplify → Peephole    │
│  → ConstPropagation → GenInsert → EarlyIfConversion               │
├─────────────────────────────────────────────────────────────────────┤
│  寄存器分配前 (addPreRegAlloc)                                      │
│  ConstExtenders ── [Coalescer] ── ExpandCondsets/CopyHoisting     │
│  ── [VirtRegRewriter] ── TfrCleanup                                │
│  → StoreWidening → GenMemAbsolute → HardwareLoops → Pipeliner     │
├─────────────────────────────────────────────────────────────────────┤
│  寄存器分配后 (addPostRegAlloc)                                     │
│  RDFOpt → CFGOptimizer → OptAddrMode                              │
├─────────────────────────────────────────────────────────────────────┤
│  发射前 (addPreEmitPass)                                           │
│  CopyToCombine → [IfConverter] → SplitConst32/64                  │
│  → NewValueJump → BranchRelaxation → FixupHwLoops → GenMux       │
│  → Packetizer → LoopAlign → VectorPrint → CFI                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 关键插入点

部分 pass 使用 `insertPass` 精确插入到通用 pass 的前后：

| Hexagon Pass | 相对位置 | 原因 |
|-------------|---------|------|
| `HexagonExpandCondsets` | RegisterCoalescer **之后** | 先展开 MUX，再由 Coalescer 合并区间 |
| `HexagonCopyHoisting` | RegisterCoalescer **之后** | 合并后 COPY 更少，提升更有效 |
| `HexagonTfrCleanup` | VirtRegRewriter **之后** | 重写后立即清理冗余传输 |

### 2.3 New Pass Manager 循环 Pass

```
LateLoopOptimizationsEP → HexagonLoopIdiomRecognition
LoopOptimizerEndEP       → HexagonVectorLoopCarriedReuse
```

两个循环 pass 通过 `HexagonPassRegistry.def` 注册，无优化级别过滤（所有级别均启用）。

---

## 3. 核心基础设施

### 3.1 BitTracker——位级符号数据流引擎

BitTracker 是 Hexagon 后端最重要的分析基础设施，被 `HexagonBitSimplify`、`HexagonGenInsert`、`HexagonLoopRescheduling` 三个 pass 共享。

**数据模型**

```
BitValue (4 元格):
  Top ── 未定义
  Zero ── 恒 0
  One  ── 恒 1
  Ref  ── 等于另一个位 (Reg + Pos)
  "Bottom" = 自引用 Ref（巧妙编码，无需第5种类型）

RegisterCell = SmallVector<BitValue, 32>  // 一个寄存器的所有位
CellMap     = map<RegNum, RegisterCell>   // 全局寄存器→位值映射
```

**算法流程**

```
初始化: 种子化入口块边和所有入口块定义的 use
         ┌─────────────────────────────┐
         │  工作列表循环 (直到不动点)    │
         │                             │
         │  EdgeQ: 处理 CFG 边          │
         │    标记边可执行              │
         │    若目标块未到达 → 处理所有指令│
         │    若目标块已到达 → 仅重处理 PHI│
         │    将新定义的 use 入队        │
         │                             │
         │  UseQ: 处理指令              │
         │    求值指令输出 cell          │
         │    若 cell 变化 → 入队其 use  │
         └─────────────────────────────┘
```

**设计模式**：策略模式。核心 `BitTracker` 引擎是目标无关的，通过 `MachineEvaluator` 抽象接口由 `HexagonEvaluator` 实现 Hexagon 特定的指令求值逻辑。`HexagonEvaluator` 维护 `RegExtMap` 追踪函数参数的符号/零扩展信息。

### 3.2 RDF（Register Data Flow）图

RDF 是 LLVM 的通用寄存器数据流框架，被 `HexagonRDFOpt` 和 `HexagonOptAddrMode` 使用。

- **精确的到达定义分析**：通过 `DefStackMap` 追踪每个引用的 reaching def
- **Phi 节点处理**：`KeepDeadPhis` 选项保留死 Phi，使拷贝传播能正确添加新 use
- **Hexagon 扩展**：`interpretAsCopy` 识别 `A2_combinew`、`A2_addi(imm=0)` 等非显而易见的拷贝语义

### 3.3 HexagonTargetTransformInfo（TTI）

`HexagonTTIImpl` 提供向量化代价模型，影响通用 pass 的决策：

- 向量化宽度偏好（HVX 向量宽度）
- 循环展开因子
- 交错访问代价
- `HexagonPipelinerLoopInfo` 适配通用软件流水器

---

## 4. 优化 Pass 详细设计

### 4.1 HVX 向量优化组

#### 4.1.1 HexagonVectorCombine

**类型**：FunctionPass（IR 级别）
**源码**：`HexagonVectorCombine.cpp`
**条件**：`hexagon-vector-combine`（默认开）

**设计思路**：两个子引擎的组合：

```
HexagonVectorCombine
  ├── AlignVectors    ── 对齐向量访存
  └── HvxIdioms       ── HVX 惯用法识别
```

**AlignVectors 算法**：

1. **地址分组**（`createAddressGroups`）：沿支配树遍历，通过 `calculatePointerDifference` 将偏移差为常量的 load/store 分到同一组
2. **移动分组**（`createLoadGroups`/`createStoreGroups`）：将同组指令移到相邻位置，load 克隆依赖到插入点
3. **重对齐**（`realignGroup`）：
   - 构造 `ByteSpan`——字节级内存布局的抽象表示，与元素类型无关
   - 对 load：生成对齐 load + `valign` 移位 + `insertb`/`select` 还原原始值
   - 对 store：生成 `vlalign` + 掩码 + 谓词 store

**ByteSpan 设计**：领域特定抽象，将内存视为字节流，用 `Segment`（值+字节范围）和 `Block`（段+位置）描述。支持 `section()` 子范围提取、`shift()` 移位、`values()` 值收集。

**HvxIdioms 算法**：

1. 逆序扫描所有指令
2. 调用 `matchFxpMul` 检测 `(X * Y) >> N` 或 `((X * Y) + rounding) >> N` 定点乘法模式
3. 通过 `getNumSignificantBits` 确定符号性
4. 路由到对应生成器：Q15（`createMulQ15`）、Q31（`createMulQ31`）、16-bit、32-bit 多字乘法

**关键洞察**：对齐 load 采用**延迟放置**策略——在对齐 load 的最早用户附近插入，而非固定位置，以减少寄存器压力。

#### 4.1.2 HexagonLoopIdiomRecognition

**类型**：LoopPass（New PM: `HexagonLoopIdiomRecognitionPass`）
**源码**：`HexagonLoopIdiomRecognition.cpp` / `.h`
**注册点**：`LateLoopOptimizationsEP`

**设计思路**：识别 Hexagon 特定的循环模式，转换为 HVX intrinsic。

**核心识别器——多项式乘法**（`PolynomialMultiplyRecognize`）：

1. **预扫描**：对循环中的 `SelectInst` 用 `Simplifier` 简化
2. **右移转左移**：若检测到右移循环，通过 `convertShiftsToLeft` 将 lshr-by-1 循环转为左移
3. **完整扫描**：`scanSelect` 解析 select 为 `ParsedValues`（M, P, Q, R, X）
4. **代码生成**：发射 `hexagon_M4_pmpyw` intrinsic；逆多项式通过 `getInverseMxN`（扩展欧几里得算法求 GF(2)[x] 逆元）计算

**Simplifier——项重写引擎**：

```
Simplifier
  ├── Context: 深度克隆表达式树 + 规则引擎
  └── Rule: {名称, 重写函数}
      ├── sink-zext          ── zext 下沉到 select
      ├── xor/and→and/xor   ── 交换律规范化
      ├── sink-binop-into-select ── 二元操作下沉
      ├── fold-select-select    ── select 嵌套折叠
      ├── or-signbit→xor-signbit ── 符号位 or→xor
      ├── sink-lshr-into-binop  ── 逻辑右移下沉
      └── expose-bitop-const    ── 暴露位操作常量
```

**设计模式**：两阶段识别（预扫描+完整扫描）。Simplifier 本质上是一个迷你的 e-graph/项重写系统。

#### 4.1.3 HexagonVectorLoopCarriedReuse

**类型**：LoopPass（New PM: `HexagonVectorLoopCarriedReusePass`）
**源码**：`HexagonVectorLoopCarriedReuse.cpp` / `.h`
**注册点**：`LoopOptimizerEndEP`

**设计思路**：向量版的预测公共子表达式消除（Predictive Commoning）——将跨迭代冗余向量计算提到循环前。

**算法**：

1. **寻找循环携带依赖**（`findLoopCarriedDeps`）：沿 PHI 链构建 `DepChain`（PHI→PHI→...→backedge 值）
2. **寻找可复用值**（`findValueToReuse`）：
   - 对每个 PHI 用户 I 和 backedge 用户 BEUser，检查 `isEquivalentOperation`
   - 验证每个操作数都有等长 DepChain 连接
   - 处理可交换操作（包括 HVX intrinsic 白名单）
3. **复用值**（`reuseValue`）：
   - 在 preheader 克隆 `Inst2Replace` N 次
   - 创建 PHI 链传递结果
   - 替换原始使用

**不动点迭代**：每次复用可能暴露新机会（新 PHI 节点可参与后续 DepChain），循环直到无新变化。

#### 4.1.4 HexagonVExtract

**类型**：MachineFunctionPass
**源码**：`HexagonVExtract.cpp`
**条件**：`hexagon-opt-vextract`（默认开）

**优化**：当同一向量寄存器被多次 `V6_extractw` 时，替换为向量 store + 标量 load 序列，减少向量提取开销。

---

### 4.2 位操作优化组

#### 4.2.1 HexagonBitSimplify

**类型**：MachineFunctionPass
**源码**：`HexagonBitSimplify.cpp`
**条件**：`hexagon-bit`（默认开）

**设计思路**：以 BitTracker 为核心的**子 pass 流水线**，每个子 pass 沿支配树遍历，维护可用寄存器集合。

**子 pass 执行顺序**：

```
1. DCE                          ── 清理死代码
2. BitTracker                   ── 计算位级值
3. ConstGeneration   (TopDown)  ── 已知常量 → 立即数加载
4. RedundantInstrElim (TopDown) ── 已知位值相同 → COPY
5. BitTracker (重跑)            ── 更新分析
6. CopyGeneration    (TopDown)  ── 可用寄存器匹配 → COPY
7. CopyPropagation   (BottomUp) ── 传播 COPY 源到所有 use
8. DCE                          ── 清理
9. BitTracker (重跑)            ── 更新分析
10. BitSimplification (TopDown) ── 模式匹配简化
11. DCE + kill flags 清理
```

**支配树遍历模式**：

```
visitBlock(B, Transformation, AVs):
  if TopDown:   Changed |= T.processBlock(B, AVs)
  compute Defs of B, add to AVs → NewAVs
  for each dom-tree child: visitBlock(child, T, NewAVs)
  if BottomUp:  Changed |= T.processBlock(B, AVs)
```

这是**支配树作用域的可用性分析**：块内定义的寄存器对被支配块"可用"，子树处理完毕后自动移除。

**BitSimplification 的模式匹配**：

| 目标寄存器类型 | 模式 | 生成指令 |
|--------------|------|---------|
| DoubleReg | packhl 模式 | `S2_packhl` |
| DoubleReg | extract low | 简化 |
| IntReg | bitsplit 模式 | `A4_bitsplit` |
| IntReg | zxth/sxtb/extractu | 位域提取指令 |
| IntReg | halfword 组合 | `combine_ll/lh/hl/hh` |
| IntReg | and-imm/extractu | `S2_extractu` |
| PredReg | tstbit 追踪 | 折叠到位源 |

#### 4.2.2 HexagonGenInsert

**类型**：MachineFunctionPass
**源码**：`HexagonGenInsert.cpp`
**条件**：`hexagon-insert`（默认开）

**设计思路**：将位操作模式转换为 Hexagon `S2_insert`/`S2_insertp` 指令。这是一个**约束满足/优化问题**，分 5 阶段求解。

**算法**：

```
Phase 1: DCE

Phase 2: 收集 (collectInBlock)
  对每个定义 vreg 的指令:
    维护 OrderedRegisterList（按 CellOrd 排序的可用寄存器）
    对每个移位量 S:
      二分搜索可用列表找前缀匹配
      构建 LM: prefix_len → [(reg, shift)]
    对目标 vreg 找首位/末位不同位 [FD..LD]
    在 LM 中搜索可"修补" [FD..LD] 的 (SrcR, InsR, Width, Offset)
    记入 IFMap[VR]
  BFS 计算每个候选项的"可移除寄存器集"

Phase 3: 剪枝 (pruneCandidates)
  3a. 子集消除: 移除可移除集是被其他候选项子集的候选
  3b. 距离剪枝: 移除 SrcR/InsR 定义过远的候选（RPO 距离）
  3c. 寄存器拷贝: 移除 width=32, offset=0/32 的平凡候选

Phase 4: 选择 (selectCandidates)
  计算每个可移除寄存器的 use count
  按 IFOrdering 选最优候选（最少零 use-count 可移除寄存器 → 最低平均 use-count → 确定性决胜）
  仅接受源寄存器 UseC==0 的候选

Phase 5: 生成 (generateInserts)
  创建新 vreg，构建 S2_insert/S2_insertp 指令
  替换所有 use，擦除原始定义，DCE
```

**关键数据结构**：

- `RegisterCellLexCompare`：按位值字典序比较寄存器 cell，使二分搜索高效
- `CellMapShadow`：缓存 BitTracker cell 查找，避免重复 `std::map` 访问
- `IFRecord(SrcR, InsR, Width, Offset)`：表示一个候选 insert 指令

**设计洞察**：利用 `OrderedRegisterList` 的排序特性，当前缀长度增长时搜索范围自然缩小，使前缀匹配的复杂度从 O(N²) 降为接近 O(N log N)。

#### 4.2.3 HexagonGenExtract

**类型**：FunctionPass（IR 级别）
**源码**：`HexagonGenExtract.cpp`
**条件**：`hexagon-extract`（默认开）

**优化**：将 `(x >> C1) & C2` 模式替换为 Hexagon `S2_extractu` 指令。

#### 4.2.4 HexagonLoopRescheduling

**类型**：MachineFunctionPass
**源码**：`HexagonBitSimplify.cpp`（与 BitSimplify 同文件）
**条件**：`hexagon-loop-resched`（默认开）

**设计思路**：旋转循环以暴露位简化机会。

**算法**：

1. 运行 BitTracker
2. 寻找循环候选：2 前驱（一为回边）+ 2 后继（一为出口）
3. 收集 PHI 中 preheader 输入仅用于位混洗（shift/insert/combine/logical）指令的链
4. 将混洗指令组从循环末尾移到循环开头，创建新 PHI
5. 使 BitSimplify 能将混折折叠到 store/compute

---

### 4.3 谓词化优化组

#### 4.3.1 HexagonGenPredicate

**类型**：MachineFunctionPass
**源码**：`HexagonGenPredicate.cpp`
**条件**：`hexagon-gen-pred`（默认开）

**设计思路**：将通用寄存器上的谓词值运算转换为原生谓词寄存器操作。

**算法**：

```
1. 收集: 扫描 C2_tfrpr/COPY(p→g) 记录谓词 GPR 到 PredGPRs
2. 查找用户: 对每个谓词 GPR 找可转换用户到 PUsers
3. 迭代转换 (直到不动点):
   对 PUsers 中每条指令:
     检查所有寄存器操作数在 PredGPRs 中
     查找谓词形式操作码 (A2_and→C2_and, A2_or→C2_or, ...)
     特殊: C2_cmpeqi ..., 0 → C2_not
     创建谓词寄存器，构建谓词形式指令
     COPY(p→g) 供剩余 GPR 用户
     新 GPR 加入 PredGPRs → 链式转换
4. 消除谓词间冗余 COPY
```

**设计模式**：工作列表驱动的迭代转换。`G2P` 映射充当记忆化缓存。迭代循环处理链式依赖（如 `and(or(P1,P2), P3)` 中间 `or` 结果也在 GPR 中）。

#### 4.3.2 HexagonEarlyIfConversion

**类型**：MachineFunctionPass
**源码**：`HexagonEarlyIfConv.cpp`
**条件**：`hexagon-eif`（默认开）

**设计思路**：在 SSA 形式（寄存器分配前）执行 if-conversion，生成谓词 store 和推测执行指令。

**FlowPattern 检测**：

```
Diamond:           Triangle:
  SplitB             SplitB
  /    \             |    \
TrueB  FalseB      TrueB  |
  \    /             |    /
  JoinB             JoinB
```

**算法**：

1. 从外到内遍历循环，对每个块调用 `matchFlowPattern`
2. 检测 diamond/triangle 模式（条件分支 + 单前驱/单后继边块）
3. **验证**（`isValid`）：无 EH 标签、所有指令可谓词化或可推测、无谓词寄存器 PHI 使用
4. **收益分析**（`isProfitable`）：
   - 跳过极端分支概率
   - 指令数（含 packet 空间）低于 `SizeLimit`（默认 6）
   - 谓词寄存器压力 ≤ 4
5. **转换**（`convert`）：
   - 推测指令 splice 到 SplitB
   - 谓词化 store（`getCondStoreOpcode`）
   - PHI → MUX（`C2_mux`/`PS_pselect`/`PS_vselect`/`PS_wselect` 按寄存器类选择）
6. **简化 CFG**：移除空块，合并单链块

#### 4.3.3 HexagonExpandCondsets

**类型**：MachineFunctionPass
**源码**：`HexagonExpandCondsets.cpp`
**条件**：`hexagon-expand-condsets`（默认开）
**插入点**：RegisterCoalescer 之后

**设计思路**：三阶段 pass，将 MUX 指令展开为谓词代码。

**三阶段算法**：

```
Phase 1: 合并 (coalesceSegments)
  对每个 MUX: 尝试将目标寄存器与某个源寄存器合并
  条件: 活跃区间不相交 + 至少一个为块内区间
  避免: 源由可谓词指令定义（会阻碍后续谓词化）

Phase 2: 拆分 (split)
  C2_mux → A2_tfrt + A2_tfrf (条件传输对)
  特殊: 两源相同 → COPY
  不重算活跃区间（保留 kill flags 供谓词化使用）

Phase 3: 谓词化 (predicateInBlock)
  对每个 A2_tfrt/A2_tfrf:
    找到源寄存器的到达定义（跳过相反条件的谓词指令）
    尝试"上移"（传输上移到定义处，谓词化定义）
    或"下移"（定义下移到传输处，谓词化定义）
    检查无冲突（寄存器重定义、内存别名）
    成功: 创建谓词版本，重命名寄存器，移除原始定义和传输
```

**关键设计**：`ReferenceMap` 使用 `Exec_Then`/`Exec_Else` 标志建模条件执行，在检查指令移动合法性时忽略相反条件下的指令。

#### 4.3.4 HexagonGenMux

**类型**：MachineFunctionPass
**源码**：`HexagonGenMux.cpp`
**条件**：`hexagon-mux`（默认开）
**时机**：发射前（ExpandCondsets 的逆操作）

**优化**：谓词化失败后，将条件传输对（`A2_tfrt` + `A2_tfrf`）折叠回 `C2_mux` 指令。

---

### 4.4 硬件循环优化组

#### 4.4.1 HexagonHardwareLoops

**类型**：MachineFunctionPass
**源码**：`HexagonHardwareLoops.cpp`
**条件**：`disable-hexagon-hwloops`（默认关=启用 pass）

**设计思路**：将可计数循环转换为 LOOP0/LOOP1 硬件循环指令，实现零开销循环。

**双硬件循环资源**：

- **LOOP0**：内层循环使用
- **LOOP1**：外层循环使用
- 自底向上递归分配：若内层已用 LOOP0，则外层用 LOOP1

**算法**：

```
对每个最外层循环:
  递归处理嵌套循环（内层优先）
  选择硬件循环类型 (L0 或 L1)
  检查无效指令（调用、修改 LC/SA 的指令）
  fixupInductionVariable:     ── 修正归纳变量
    确保 "PHI → bump → compare" 数据流
    必要时调整比较立即数和指令顺序
  确保存在 preheader（不存在则创建）
  getLoopTripCount:            ── 计算循环次数
    从归纳变量初始值和比较终值计算
    处理各种比较类型 (LT/LE/GT/GE/EQ/NE, signed/unsigned)
    立即数: ceil((end-start)/bump)
    寄存器: 插入减法+调整+移位（仅支持 2 的幂 bump）
  生成 J2_loop0i/r + ENDLOOP0
  移除死归纳和比较指令
```

**Comparison::Kind 位掩码设计**：

```
Kind = EQ|NE|L|G|U 的位掩码组合
LEs = L|EQ,  LTu = L|U, ...
swap(): 交换 L↔G
negate(): 交换 EQ↔NE, L↔G
```

**设计洞察**：归纳变量的"bump vs compare"顺序问题是最常见的陷阱。如果比较用的是 bump 前的值，需要调整比较立即数并确保指令顺序正确。

#### 4.4.2 HexagonFixupHwLoops

**类型**：MachineFunctionPass
**源码**：`HexagonFixupHwLoops.cpp`

**优化**：修正 LOOPn 指令中循环起始地址距离过远的问题，需要插入常量扩展器。

#### 4.4.3 HexagonLoopAlign

**类型**：MachineFunctionPass
**源码**：`HexagonLoopAlign.cpp`

**优化**：为小型单基本块循环设置 32 字节对齐，提升硬件循环性能。

---

### 4.5 VLIW 打包组

#### 4.5.1 HexagonPacketizer

**类型**：MachineFunctionPass（**必须 pass**，所有优化级别均运行）
**源码**：`HexagonVLIWPacketizer.cpp` / `.h`

**设计思路**：VLIW 打包是 Hexagon 最核心的 pass——将最多 4 条指令打包到一个 instruction packet 中，受 DFA 资源约束和依赖关系限制。

**算法**：

```
对每个调度区域:
  对每条指令 SUI:
    若 isSoloInstruction → 独占一个 packet
    若 shouldAddToPacket → 检查停顿避免

    对 packet 中每条已有指令 SUJ:
      isLegalToPacketizeTogether 检查:
        ├── cannotCoexist          ── 快速对称不兼容检查
        ├── hasDeadDependence      ── 同一死寄存器定义
        ├── hasControlDependence   ── 双控制流指令
        ├── hasRegMaskDependence   ── call 覆盖定义寄存器
        ├── hasDualStoreDependence ── 双 store slot 约束
        ├── .new 值跳转粘合       ── NVJ packet 约束
        └── 对每条依赖边:
             数据依赖 → 尝试 .cur/.new 推广
             互补谓词 → arePredicatesComplements
             顺序依赖 → 内存序检查
             反依赖   → 一般允许（call 除外）
             输出依赖 → 禁止同包

    isLegalToPruneDependencies:
      推广失败则回滚 (.new→.old, 撤销偏移修改)
      尝试 updateOffset 折叠 add 到 load/store 偏移

    addToPacket: 预留 DFA 资源，处理常量扩展器
  endPacket: 完成打包，设置 NoShuf 标志
```

**.new/.cur 推广机制**：

```
canPromoteToDotNew:
  检查指令可 .new 化（谓词或新值 store）
  验证资源可用
  新值 store 约束: 无双寄存器馈入、同谓词寄存器、
                   无后递增地址、packet 内无其他 store

canPromoteToDotCur:
  类似，针对 HVX .cur load 推广
```

**停顿避免**：

```
calcStall: 计算当前指令与前 packet 指令间的延迟
producesStall: 若停顿 > 当前 packet 已有最差停顿 → 拒绝入包
```

**设计模式**：

- **DFA 资源检查**：`ResourceTracker` 验证每条指令的机器资源可用性
- **依赖修剪与推广**：不直接拒绝有依赖的指令，而是尝试通过 .new/.cur 推广、偏移更新、互补谓词消解依赖
- **回滚机制**：`isLegalToPruneDependencies` 在推广失败时撤销所有推测性修改
- **前向调度**：追踪前一 packet 的停顿，避免制造流水线气泡

#### 4.5.2 HexagonNewValueJump

**类型**：MachineFunctionPass
**源码**：`HexagonNewValueJump.cpp`
**时机**：发射前（post-RA）

**优化**：将 compare + jump 序列折叠为 .new 值跳转指令（`J4_cmp*new`），利用同 packet 内的比较结果。

**算法**：

```
对每个基本块自底向上扫描:
  1. 找到谓词跳转 (J2_jumpt/J2_jumpf)
  2. 找到定义 predReg 的比较指令
     验证: 立即数范围、中间无 predReg/操作数的 def/use
  3. 找到定义 cmpReg 的馈入指令 (feeder)
     验证: 非谓词化、非 KILL/IMPLICIT_DEF、定义单 IntReg
  4. 生成 NVJ:
     若第二操作数被 newify → 交换比较操作数并调整操作码
     移动 feeder 和 compare 到 jump 前
     构建 J4_* 指令，擦除原始 compare 和 jump
```

**Post-RA 约束**：寄存器分配后运行，因为 feeder 和 compare 之间的 spill 会阻止 NVJ 形成。

---

### 4.6 寄存器优化组

#### 4.6.1 HexagonSplitDoubleRegs

**类型**：MachineFunctionPass
**源码**：`HexagonSplitDouble.cpp`
**条件**：`disable-hsdr`（默认关=启用 pass）

**优化**：将 64 位双寄存器的使用拆分为 32 位子寄存器对，当子寄存器单独使用更优时。

#### 4.6.2 HexagonCopyHoisting

**类型**：MachineFunctionPass
**源码**：`HexagonCopyHoisting.cpp`
**条件**：`hexagon-copy-hoist`（默认开）
**插入点**：RegisterCoalescer 之后

**优化**：将所有后继块共有的 COPY 指令提升到公共前驱块末尾。

#### 4.6.3 HexagonRDFOpt

**类型**：MachineFunctionPass
**源码**：`HexagonRDFOpt.cpp`
**条件**：`rdf-opt`（默认开）

**设计思路**：基于 RDF 图的拷贝传播 + 死代码消除。

**算法**：

```
1. 构建 RDF 图 (KeepDeadPhis, 可选 OmitReserved)
2. 拷贝传播 (HexagonCP):
   interpretAsCopy 扩展:
     A2_combinew → Dst:hi=Src1, Dst:lo=Src2
     A2_addi(imm=0) → Dst=Src
     A2_tfr → Dst=Src
   基于 RDF 等价映射全局传播
3. 死代码消除 (HexagonDCE):
   识别部分死指令（post-increment load/store 中地址定义死但数据定义活）
   L2_loadri_pi → L2_loadri_io (偏移设 0)
   S2_storeri_pi → S2_storeri_io
   V6_vL32b_pi → V6_vL32b_ai
4. 若有变化，重建活跃信息
```

#### 4.6.4 HexagonTfrCleanup

**类型**：MachineFunctionPass
**源码**：`HexagonTfrCleanup.cpp`
**条件**：`hexagon-tfr-cleanup`（默认开）
**插入点**：VirtRegRewriter 之后

**优化**：消除源在同一块内被设为立即数的寄存器拷贝（折叠立即数）。

---

### 4.7 访存优化组

#### 4.7.1 HexagonStoreWidening

**类型**：MachineFunctionPass
**源码**：`HexagonStoreWidening.cpp`
**条件**：`disable-store-widen`（默认关=启用 pass）

**优化**：将相邻窄 store 合并为宽 store，减少 store queue 压力和 packet 数。

#### 4.7.2 HexagonOptAddrMode

**类型**：MachineFunctionPass
**源码**：`HexagonOptAddrMode.cpp`
**条件**：`disable-hexagon-amodeopt`（默认关=启用 pass）

**设计思路**：利用 RDF 图的到达定义分析优化寻址模式。

**算法**：

```
对每个块:
  对 A2_addi (非 const-extended):
    找到 add 结果的所有 load/store use
    计算新偏移 = add.imm + load/store.offset
    用 RDF reaching-def 验证 add 和 use 间无其他 base 定义
    替换: base←add.input, offset+=add.imm
    若所有 use 已更新 → 删除 add

  对 A2_tfrsi (全局地址):
    获取所有真实 use（RDF def→use 链，解析 PHI）
    验证每个 use 恰好一个 reaching def
    转换寻址模式:
      BaseRegOffset → rr_ur (绝对+寄存器偏移)
      BaseImmOffset → io_abs (绝对寻址)
      addasl → ur (移位寄存器+绝对)
    计算代码大小影响，不超过 CodeGrowthLimit
    转换每个 use
    若所有 use 已转换 → 删除 tfrsi
```

**设计模式**：代价模型 + 代码增长限制。`changeAddrMode_*` 辅助函数封装 Hexagon 寻址模式之间的转换逻辑。

#### 4.7.3 HexagonGenMemAbsolute

**类型**：MachineFunctionPass
**源码**：`HexagonGenMemAbsolute.cpp`
**条件**：`hexagon-mem-abs`（默认开）

**优化**：当偏移为 0 的索引 load/store 的基址寄存器有多次使用时，转换为绝对地址 set load/store 指令。

---

### 4.8 常量优化组

#### 4.8.1 HexagonConstPropagation

**类型**：MachineFunctionPass
**源码**`HexagonConstPropagation.cpp`
**条件**：`disable-hcp`（默认关=启用 pass）

**优化**：机器级常量传播，追踪 zero/nonzero/finite 属性，后接 `UnreachableMachineBlockElim`。

#### 4.8.2 HexagonConstExtenders

**类型**：MachineFunctionPass
**源码**：`HexagonConstExtenders.cpp`
**条件**：`hexagon-cext`（默认开）
**时机**：寄存器分配前

**优化**：优化常量扩展器（Hexagon 32 位指令中嵌入的大常量需要扩展前缀）。

#### 4.8.3 HexagonOptimizeSZextends

**类型**：FunctionPass（IR 级别）
**源码**：`HexagonOptimizeSZextends.cpp`

**优化**：移除函数参数上冗余的符号/零扩展——Hexagon ABI 保证参数已被适当扩展。

#### 4.8.4 HexagonSplitConst32AndConst64

**类型**：MachineFunctionPass
**源码**：`HexagonSplitConst32AndConst64.cpp`
**时机**：始终运行

**优化**：在 -G0（无小数据段）模式下，将 CONST32/CONST64 伪指令拆分为 LO/HI 指令对。

---

### 4.9 CFG 优化组

#### 4.9.1 HexagonCFGOptimizer

**类型**：MachineFunctionPass
**源码**：`HexagonCFGOptimizer.cpp`
**条件**：`disable-hexagon-cfgopt`（默认关=启用 pass）

**优化**：翻转条件分支以消除不必要的跳转块；简化 CFG 模式。

#### 4.9.2 HexagonCommonGEP

**类型**：FunctionPass（IR 级别）
**源码**：`HexagonCommonGEP.cpp`
**条件**：`hexagon-commgep`（默认开）

**优化**：函数范围内公共 GEP（GetElementPtr）指令的消除。

---

### 4.10 辅助/发射 Pass

| Pass | 类型 | 条件 | 功能 |
|------|------|------|------|
| `HexagonPeephole` | MachineFunctionPass | !NoOpt | 消除冗余 SXTW+subreg copy；优化冗余谓词取反 |
| `HexagonCopyToCombine` | MachineFunctionPass | 始终 | 双 COPY → A2_combinew |
| `HexagonBranchRelaxation` | MachineFunctionPass | 始终 | 长跳转放松 |
| `HexagonVectorPrint` | MachineFunctionPass | `enable-hexagon-vector-print` | 插入向量寄存器打印伪指令（仅模拟器） |
| `HexagonCallFrameInformation` | MachineFunctionPass | 始终 | 添加 CFI 指令 |

---

## 5. Pass 间依赖与交互

### 5.1 数据流依赖图

```
BitTracker ──────────→ HexagonBitSimplify
    │                     ├── ConstGeneration
    │                     ├── RedundantInstrElim
    │                     ├── CopyGeneration
    │                     └── BitSimplification
    │
    └─────────────────→ HexagonGenInsert
    │
    └─────────────────→ HexagonLoopRescheduling

RDF Graph ───────────→ HexagonRDFOpt
    │                     ├── CopyPropagation
    │                     └── DeadCodeElimination
    │
    └──────────────────→ HexagonOptAddrMode

LiveIntervals ───────→ HexagonExpandCondsets
                         ├── Coalesce
                         ├── Split
                         └── Predicate
```

### 5.2 关键交互链

**谓词化链**：

```
EarlyIfConversion (生成 MUX)
  → ExpandCondsets (MUX → tfrt+tfrf → 谓词化原始指令)
  → [RA]
  → GenMux (谓词化失败的 tfrt+tfrf → C2_mux)
  → Packetizer (MUX 同包优化)
```

**.new 值链**：

```
HardwareLoops (生成 LOOPn)
  → FixupHwLoops (修正距离)
  → NewValueJump (compare+jump → .new 值跳转)
  → Packetizer (.new 推广、依赖消解)
```

**位优化链**：

```
GenExtract (IR: shift+and → extractu)
  → [ISel]
  → BitSimplify (Machine: 常量生成 + 冗余消除 + 位简化)
  → GenInsert (Machine: 位操作 → insert 指令)
  → GenPredicate (算术 → 谓词操作)
```

### 5.3 为什么某些 Pass 需要多次运行 BitTracker

`HexagonBitSimplify` 内部运行 BitTracker 最多 3 次：

1. 初始运行——建立基线
2. `RedundantInstrElim` 后重跑——替换指令改变了寄存器值
3. `CopyGeneration` + `CopyPropagation` + DCE 后重跑——供 `BitSimplification` 使用最新信息

---

## 6. 控制标志

所有标志均为 `cl::opt`，默认隐藏（`cl::Hidden`），不影响 `-O0` 以上的默认行为。

### 6.1 全局开关

| 标志 | 默认 | 作用 |
|------|------|------|
| `hexagon-noopt` | false | 强制 `CodeGenOptLevel::None`，禁用所有后端优化 |

### 6.2 逐 pass 控制

| 标志 | 默认 | 控制 Pass |
|------|------|-----------|
| `hexagon-vector-combine` | true | HexagonVectorCombine |
| `hexagon-commgep` | true | HexagonCommonGEP |
| `hexagon-extract` | true | HexagonGenExtract |
| `hexagon-opt-vextract` | true | HexagonVExtract |
| `hexagon-gen-pred` | true | HexagonGenPredicate |
| `hexagon-loop-resched` | true | HexagonLoopRescheduling |
| `disable-hsdr` | false | HexagonSplitDoubleRegs |
| `hexagon-bit` | true | HexagonBitSimplify |
| `disable-hcp` | false | HexagonConstPropagation |
| `hexagon-insert` | true | HexagonGenInsert |
| `hexagon-eif` | true | HexagonEarlyIfConversion |
| `hexagon-cext` | true | HexagonConstExtenders |
| `hexagon-expand-condsets` | true | HexagonExpandCondsets |
| `hexagon-copy-hoist` | true | HexagonCopyHoisting |
| `hexagon-tfr-cleanup` | true | HexagonTfrCleanup |
| `disable-store-widen` | false | HexagonStoreWidening |
| `hexagon-mem-abs` | true | HexagonGenMemAbsolute |
| `disable-hexagon-hwloops` | false | HexagonHardwareLoops |
| `rdf-opt` | true | HexagonRDFOpt |
| `disable-hexagon-cfgopt` | false | HexagonCFGOptimizer |
| `disable-hexagon-amodeopt` | false | HexagonOptAddrMode |
| `hexagon-mux` | true | HexagonGenMux |
| `enable-hexagon-vector-print` | false | HexagonVectorPrint |
| `hexagon-loop-prefetch` | false | LoopDataPrefetchPass |
| `hexagon-initial-cfg-cleanup` | true | 初始 CFG 简化 |
| `hexagon-instsimplify` | true | InstSimplifyLegacyPass |

### 6.3 资源限制

| 标志 | 默认 | 作用 |
|------|------|------|
| `rdf-bb-limit` | 1000 | RDF 优化的函数基本块上限 |

---

## 7. 设计模式总结

### 7.1 跨 pass 复用的模式

| 模式 | 使用 Pass | 说明 |
|------|----------|------|
| **支配树作用域遍历** | BitSimplify, GenInsert, EarlyIfConv | 沿支配树维护可用性集合，子树处理完自动清理 |
| **工作列表不动点迭代** | BitTracker, GenPredicate, VectorLoopCarriedReuse | 修改可能暴露新机会，迭代直到收敛 |
| **策略模式 + 目标特定求值器** | BitTracker+HexagonEvaluator, RDF+interpretAsCopy | 通用框架 + 目标 hook |
| **多阶段流水线** | BitSimplify(11子pass), ExpandCondsets(3阶段) | 每阶段为下阶段创造机会 |
| **延迟删除** | OptAddrMode, RDFOpt | 统一收集待删指令，避免迭代器失效 |
| **代价模型 + 增长限制** | OptAddrMode, EarlyIfConv | 优化不应增加代码大小 |

### 7.2 Hexagon 独有的设计决策

1. **内建 DCE**：几乎所有 pass 都自带死代码消除，因为通用 DCE 不保留 lifetime marker 且时机不对
2. **MUX 展开→谓词化→MUX 折叠**：`ExpandCondsets` 和 `GenMux` 是逆操作，但中间的谓词化机会使这对组合有价值
3. **位级符号分析**：`BitTracker` 的 `Ref` 语义（一位等于另一位）比传统常量传播更适合 Hexagon 的位操作指令集
4. **.new/.cur 推广作为依赖消解手段**：Packetizer 不只是打包，还通过推广指令到 .new 形式来消解数据依赖
5. **Post-RA 优化**：`NewValueJump`、`RDFOpt`、`OptAddrMode` 在寄存器分配后运行，利用物理寄存器信息做更精确的优化

---

## 8. 文件索引

| 文件 | Pass 类 | 行数（约） |
|------|---------|-----------|
| `HexagonTargetMachine.cpp` | HexagonPassConfig（流水线配置） | 510 |
| `HexagonPassRegistry.def` | New PM 注册 | - |
| `BitTracker.cpp/.h` | 位级符号分析引擎 | 1500+ |
| `HexagonBitTracker.cpp/.h` | Hexagon 求值器 | 400+ |
| `HexagonBitSimplify.cpp` | HexagonBitSimplify + HexagonLoopRescheduling | 2800+ |
| `HexagonGenInsert.cpp` | HexagonGenInsert | 2200+ |
| `HexagonGenPredicate.cpp` | HexagonGenPredicate | 500+ |
| `HexagonEarlyIfConv.cpp` | HexagonEarlyIfConversion | 600+ |
| `HexagonExpandCondsets.cpp` | HexagonExpandCondsets | 1200+ |
| `HexagonHardwareLoops.cpp` | HexagonHardwareLoops | 1500+ |
| `HexagonVLIWPacketizer.cpp/.h` | HexagonPacketizerList | 2500+ |
| `HexagonVectorCombine.cpp` | HexagonVectorCombine (AlignVectors + HvxIdioms) | 2200+ |
| `HexagonLoopIdiomRecognition.cpp/.h` | HexagonLoopIdiomRecognize | 2500+ |
| `HexagonVectorLoopCarriedReuse.cpp/.h` | HexagonVectorLoopCarriedReuse | 700+ |
| `HexagonNewValueJump.cpp` | HexagonNewValueJump | 600+ |
| `HexagonOptAddrMode.cpp` | HexagonOptAddrMode | 900+ |
| `HexagonRDFOpt.cpp` | HexagonRDFOpt | 300+ |
| `HexagonOptimizeSZextends.cpp` | HexagonOptimizeSZextends | 100+ |
| `HexagonVExtract.cpp` | HexagonVExtract | 200+ |
| `HexagonCommonGEP.cpp` | HexagonCommonGEP | 400+ |
| `HexagonGenExtract.cpp` | HexagonGenExtract | 200+ |
| `HexagonSplitDouble.cpp` | HexagonSplitDoubleRegs | 600+ |
| `HexagonPeephole.cpp` | HexagonPeephole | 200+ |
| `HexagonConstPropagation.cpp` | HexagonConstPropagation | 400+ |
| `HexagonConstExtenders.cpp` | HexagonConstExtenders | 800+ |
| `HexagonCopyHoisting.cpp` | HexagonCopyHoisting | 200+ |
| `HexagonTfrCleanup.cpp` | HexagonTfrCleanup | 200+ |
| `HexagonStoreWidening.cpp` | HexagonStoreWidening | 300+ |
| `HexagonGenMemAbsolute.cpp` | HexagonGenMemAbsolute | 200+ |
| `HexagonCFGOptimizer.cpp` | HexagonCFGOptimizer | 200+ |
| `HexagonCopyToCombine.cpp` | HexagonCopyToCombine | 200+ |
| `HexagonSplitConst32AndConst64.cpp` | HexagonSplitConst32AndConst64 | 100+ |
| `HexagonGenMux.cpp` | HexagonGenMux | 200+ |
| `HexagonBranchRelaxation.cpp` | HexagonBranchRelaxation | 300+ |
| `HexagonFixupHwLoops.cpp` | HexagonFixupHwLoops | 200+ |
| `HexagonLoopAlign.cpp` | HexagonLoopAlign | 100+ |
| `HexagonVectorPrint.cpp` | HexagonVectorPrint | 100+ |
