# §3+§4 SelectionDAG 数据结构 + Legalize 三部曲深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，build-debug 实测（AArch64）。
> 引用格式 `文件:行号`；实测素材 /tmp/p8.ll（i8 promote）、/tmp/e128.ll（i128 expand/uaddo_carry）。
> 素材来源：子代理调研（引用已核实，含一处"任务书三态已重构"发现）+ 主会话补循环驱动与动态验证。

---

## 3.1 SDNode 表示：内存布局的紧凑设计

**SelectionDAGNodes.h**：
- `class SDNode : public FoldingSetNode, public ilist_node<SDNode>` :515；`int32_t NodeType` :518（**负值=机器 opcode**，isMachineOpcode :763，getMachineOpcode=~NodeType :773；isTargetOpcode :714）
- 子类数据压进 **16-bit 位域 union**（SDNodeBitfields 等 :538-632，static_assert(sizeof≤2) :640-645）；PersistentId :653、NodeId :661、OperandList/ValueList/UseList :664-671、NumOperands/NumValues（unsigned short）:674-675、IROrder :682、**CombinerWorklistIndex union** :690-697
- **操作数不在节点内**：createOperands（SelectionDAG.cpp:15075-15102）从 `ArrayRecycler<SDUse>` 按容量桶分配；子类 payload（ConstantSDNode::Value :1843、MemSDNode::MemoryVT/MemRefs :1434-1440）跟在节点后，由 **sizeof(LargestSDNode)**（:3434-3440，AlignedCharArrayUnion）定长的 RecyclingAllocator 池分配（SelectionDAG.h:276-281）——**节点定长 + 尾部变长 payload + 池化回收**
- getMaxNumOperands()=unsigned short 上限 :1047-1049

**NodeId 与拓扑序**：DAGTypeLegalizer **复用 SDNode::NodeId 作状态机**——ReadyToProcess=0 / NewNode=-1 / Unanalyzed=-2 / Processed=-3 / 1+=未处理操作数计数（LegalizeTypes.h:36-52）；计数递减到 0 才入 worklist（LegalizeTypes.cpp:393-422）——**一个 int 字段的双重生命**（普通节点=-1/合法化状态机）。

**CSE 机制**：SDNodeKey{Opcode, VTs 指针, Ops, Tail}（SelectionDAG.h:103-142）；AddNodeIDCustom（SelectionDAG.cpp:761-1002）按 opcode 加键数据（Constant :774、GlobalAddress :785、**LOAD/STORE 的 MemVT+SubclassData+AddrSpace+MMO flags** :847-862、机器节点只按 opcode+VT+操作数 :765-766）；doNotCSE（**glue 恒不 CSE**）:1067-1084；AddModifiedNodeToCSEMaps（命中 RAUW+递归合并，MMO metadata 不入键）:1357-1389。**GISel 对照**：等价 CSEMIRBuilder 的 FoldingSet 唯一化，但 SDAG 用"节点指针+ResNo"作操作数身份。

**chain/glue 类型系统**：EntryNode 产出 {MVT::Other, MVT::Glue}（:1453-54）；glue 恒不 CSE；getGluedNode=末操作数为 MVT::Glue :1100-1105；TokenFactor 合并链 :15104-15115。

## 3.2 LegalizeDAG 分派树（6,361 行）

**LegalizeOp**（:982-1416）判定顺序：
1. 先按 opcode 定查询哪个 VT（SETCC 族先查 getCondCodeAction(CC,OpVT) :1065-1093，Legal 才回退 opAction；**"说谎"的 op**：Legal→Expand :1108-1122 / Legal→Custom :1123-1134；默认 target opcode 走 getCustomOperationAction :1286-1291）
2. shift amount 预处理 :1298-1341
3. **动作 switch :1347-1396**：Legal→return；**Custom→TLI.LowerOperation(:1355) 失败则 fallthrough Expand**；Expand→ExpandNode 失败 fallthrough **LibCall**(:1390)；Promote→PromoteNode

**重要发现（任务书纠偏）**：现行 `LegalizeOp` 返回 **void**——"LegalizeResult 三态"已被重构掉，现为 `bool ExpandNode`（失败→LibCall）+ `SDValue LowerOperation`（空→Expand）组合承担三态语义。

**Expand 递归示例**：UBSANTRAP→替换 TRAP 后 `LegalizeOp(NewVal.getNode())` 递归 :1153-1163。**ExpandNode :3210-4720 巨型 switch**（SUB→NOT+ADD+1 :4066；UDIV→UDIVREM :4081；UMUL_LOHI 三级 fallback :4106-4142；BUILD_PAIR :4318；失败 "Cannot expand node" return false :4712-15）。

Load/Store 走 `SimpleFinishLegalizing=false` 专路 :1095-1107 → LegalizeLoadOps :669+（fp16 extload 整数化特例 :917-935）、LegalizeStoreOps :490-667（i24 拆双 store :564-619）。

## 3.3 LegalizeTypes 五文件矩阵

驱动 `DAGTypeLegalizer::run()`（LegalizeTypes.cpp:196-483）：**先扫结果再扫操作数**，每个非法值恰好映射进 **8 张表**之一（PromotedIntegers/ExpandedIntegers/SoftenedFloats/SoftPromotedHalfs/ExpandedFloats/ScalarizedVectors/SplitVectors/WidenedVectors，LegalizeTypes.h:97-129，TableId 双向 map :88-152）；PerformExpensiveChecks 的 bitmask **单射校验** :85-125。每类入口全由 TLI.getTypeAction(VT)（2-bit ValueTypeActions 表 :55-58）决定；结果/操作数两个方向的 XxxResult/XxxOperand 虚分派 :247-351。

关键函数：SoftenFloatResult 分派表（LegalizeFloatTypes.cpp:51-190；**BITCAST→BitConvertToInteger :248** 即 f32→i32 位模式；ConstantFP→APInt :280-302；FADD→ADD_F32..F128 libcall :385-392）；SplitVectorResult（CustomLowerNode 钩子 :1382）；WidenVectorResult（CustomWidenLowerNode :5258；unrollExpandedOp 防 undef 元素 libcall :5263-5281）；PromoteIntegerResult（Custom 钩子优先 :46-50；SimpleIntBinOp 容忍高位垃圾 :1450-57）。

## 3.4 TargetLowering 表体系

- **LegalizeAction 五态**：TargetLowering.h:222-228（Legal/Promote/Expand/LibCall/Custom）；LegalizeTypeAction 十态 :232-249
- `OpActions[VT.SimpleTy][Op]` 二维：getOperationAction :1330-1337 / setOperationAction :2760-2762
- `LoadExtActions[ValI][MemI]`：**uint16 打包 4 ExtType×4bit**，setLoadExtAction :2777-2795
- `CondCodeActions[CC][VT.SimpleTy>>3]`：**uint32 打包 8 MVT×4bit**，setCondCodeAction :2884-2896（Shift=4*(SimpleTy&7)）
- 未核实（标注）：三数组成员声明行、TargetLowering.cpp 初始化函数

## 3.5 Legalize↔Combine 循环驱动（主会话补核实，CodeGenAndEmitDAG :941）

实测核实的**固定交替序列**（SelectionDAGISel.cpp:955-1130）：
```
Combine(BeforeLegalizeTypes)          ← pre-type-legalize 合并
→ LegalizeTypes()                     ← 类型合法化
→ Combine(AfterLegalizeTypes)         ← post-type 合并
→ LegalizeVectors()                   ← 向量 op 合法化
→ Combine(AfterLegalizeVectorOps)
→ LegalizeOps()（LegalizeDAG）        ← 操作合法化
→ Combine(AfterLegalizeDAG)           ← post-legalize 合并
→ SelectCode                          ← 选择
```
**五段 Combine 与三段 Legalize 交替**——每段合法化后立刻 recombine（新产生的模式机会），类型→向量→操作三层由内向外。这不是循环而是**固定管线**（无回边），终止性由结构保证。

## 3.6 动态验证（实测）

**i8 promote**（-debug-only=legalize-types）：
```
Promote integer result: t5: i8 = truncate t2
Promote integer result: t7: i8 = add t5, t6      ← add i8 在 i32 target 上逐节点提升
Promote integer operand: t8: i32 = any_extend t7
```
**i128 expand**（-debug-only=legalizedag）：
```
Legalizing: t22: i64,i32 = uaddo_carry t4, t8, t21:1   ← i128 add 已 expand 成进位链
Trying custom legalization                              ← AArch64 的 custom 钩子介入
```
f16 soften 未触发（+fp16 下合法；soft-float target 需另构造，标注）。

## 3.7 昇腾映射（推理级，待验证）

1. **tile 的"合法化"矩阵**：tile 大小超 UB 时 SplitVector 对应（大 tile 拆小）；dtype 不支持时 SoftenFloat 对应（bf16→fp32 仿真链）；**8 张表的"每个非法值恰好进一张"单射设计**是 tile 合法化的建模模板
2. **NodeId 双重生命**：tile DAG 节点的状态机复用（普通/合法化/工作表索引）——零内存开销的编译器技巧
3. **五段 Combine 固定管线**：PyPTO tile 优化若分层（shape 合法化→布局合法化→模式合并），每层后 recombine 的交替结构可复制
4. **"Custom 失败 fallthrough Expand"**：tile 的自定义 lowering 应有同样的兜底链（custom→expand→libcall）——永不死循环

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| SelectionDAGNodes.h:515-696, 714-773, 1047-1049, 1434-1440, 1843 | SDNode 布局 |
| SelectionDAG.h:103-142, 276-281 | CSE 键/池 |
| SelectionDAG.cpp:761-1084, 1016-1034, 1100-1105, 1357-1389, 1453-1454, 3434-3440, 15075-15102, 15104-15115 | CSE/池/glue |
| LegalizeDAG.cpp:59, 490-935, 982-1416, 3210-4720, 5432-5496 | 分派树/Expand/Promote |
| LegalizeTypes.h:36-152 / LegalizeTypes.cpp:85-483 | 状态机/8 表 |
| LegalizeFloatTypes.cpp:51-392 / LegalizeVectorTypes.cpp:1378+ / LegalizeIntegerTypes.cpp:46-1457 | 三类矩阵 |
| TargetLowering.h:222-249, 1330-1337, 1531-1562, 1733-1738, 2760-2795, 2884-2896 | 表体系 |
| SelectionDAGISel.cpp:941, 955-1130（五段 Combine） | 循环驱动（主会话核实） |

实测素材：/tmp/p8.ll（i8 逐节点 promote 日志）、/tmp/e128.ll（uaddo_carry + custom legalization）。
