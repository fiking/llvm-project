# §2 SelectionDAGBuilder（IR→DAG）深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，build-debug 实测（AArch64, -debug-only=isel-dump）。
> 引用格式 `文件:行号`；实测素材 `ISel-notes/scratch/builder_test.ll`。
> 素材来源：子代理调研（引用已核实，两处任务前提修正）+ 主会话动态验证代写。

**两处修正**（子代理证伪任务前提）：
1. `getCaseResults` 在 main **已不存在**——现行 switch 展开是 CaseCluster + splitWorkItem/lowerWorkItem 工作列表 + SDAGSwitchLowering
2. `-debug-only=isel` **看不到** DAG dump——`ISEL_DUMP` 宏门控（SelectionDAGISel.cpp:192-196），debug type 是 **`"isel-dump"`**（:118，DEBUG_TYPE "-dump"）；dump 点 :965-968

---

## 2.1 visit() 大分发表

**入口** `visit(const Instruction&)`（SelectionDAGBuilder.cpp:1373-1419）：terminator 先调 HandlePHINodesInSuccessorBlocks（:1377-1379）→ `visit(I.getOpcode(), I)`(:1394) → 非 terminator 随后 CopyToExportRegsIfNeeded（:1396-1398，statepoint 除外）。

**分发是单个 switch（非虚表）**：:1425-1435，由 HANDLE_INST 宏 + `#include "llvm/IR/Instruction.def"` 生成 case→visit##OPCODE——注释明确不用 InstVisitor 因需兼容 ConstantExpr。**visitPHI = llvm_unreachable**（:1421-1423）——PHI 不进 DAG。

**代表性 visit**：

| visit | 行号 | DAG 产物 |
|---|---|---|
| visitBinary | :3738-3756 | flags 提取→`DAG.getNode(ISD::ADD等)`→setValue（header :592-622 的 visitAdd 系内联包装） |
| visitUncondBr | :2819-2836 | 非 fall-through 才发 ISD::BR，chain=getControlRoot |
| visitCondBr | :2838-2924 | FindMergedConditions(:2884) 把 and/or 条件链拆多分支，否则 CaseBlock→visitSwitchCase(:2923) |
| visitSwitch | :12955-13041 | Cluster 提取→sortAndRangeify(:12974)→peelDominantCaseCluster(:12979)→findJumpTables/findBitTestClusters(:12993-95)→工作列表 >3 cluster 走 splitWorkItem **平衡二叉树**(:13032-37) |
| visitAlloca | :4735-4785 | static alloca 在 FuncInfo.StaticAllocaMap 则直接 return（getValue 走 FrameIndex）；动态 alloca 发 ISD::DYNAMIC_STACKALLOC 双结果节点 |
| visitRet | :2215-2377 | CanLowerReturn=false 走 DemoteRegister CopyFromReg(:2242)+store；正常 getCopyToParts(:2306)→TLI.LowerReturn(:2368) |
| visitCall | :9826-10033 | inline asm/intrinsic/LibFunc 匹配（copysign→FCOPYSIGN :9867）分流，默认 LowerCallTo(:10032) |

## 2.2 SSA→DAG 边界协议（本章核心）

**三级回退**：`getValue`（:1799-1816）NodeMap → getCopyFromRegs（:1779-1796 查 FuncInfo.ValueMap）→ getValueImpl——**这就是边界协议的核心**。

- **RegsForValue::getCopyFromRegs**（:893-977）：逐 part `DAG.getCopyFromReg`（:919/:921 glue 变体），chain 取 P.getValue(1)（:925）；LiveOutInfo 已知位数→**AssertZext/AssertSext**（:933-967，跨块已知位恢复）；收尾 MERGE_VALUES(:976)
- **getCopyToRegs**（:979-1034）：逐 reg getCopyToReg（:1011/:1013），glue 穿线 `*Glue=Part.getValue(1)`(:1014)；**单 reg 或有 glue 时 chain 取最后一个 CopyToReg，多 reg 无 glue 才 TokenFactor**（:1020-1033，注释解释 glue+TF 会成环）
- **导出协议**：CopyToExportRegsIfNeeded（:2382-2393）→ CopyValueToVirtualRegister（:11884-11908，EntryNode 为 chain，PendingExports.push_back :11907）——terminator 前 getControlRoot 统一 TokenFactor
- **PHI 汇合**：HandlePHINodesInSuccessorBlocks（:12473-12547）——常量经 ConstantsOut→CopyValueToVirtualRegister（:12507-19），变量取 FuncInfo.ValueMap（:12521-23），登记 **FuncInfo.PHINodesToUpdate**(:12540) 供 InstrEmitter 填 Machine PHI
- **函数参数入口**：SelectionDAGISel::LowerArguments（**定义在 Builder 文件 :12101**——文件越界的有趣组织）：TLI LowerFormalArguments→getCopyFromParts(:12368)→setValue(:12396)；参数跨块使用则 InitializeRegForValue+导出（:12437-40）。入口先做 findArgumentCopyElisionCandidates 预扫描（:11933-12029）
- **动机**：DAG 以 BB 为区域**无 phi**，vreg+CopyFrom/ToReg 是跨块 SSA 逃逸通道；ComputeLiveOutVRegInfo（SelectionDAGISel.cpp:904-939）沿 CopyToReg 恢复跨块已知位

## 2.3 call 的 DAG 形态

- Builder 侧 LowerCallTo（:9333-9454）：canTailCall(:9347)、swifterror vreg 替换（:9362-69）、sret 禁 tail（:9375）、cfguardtarget/kcfi/convergencectrl bundle 装配 → 打包 **CallLoweringInfo CLI**（:9415-9425）→ lowerInvokable(:9435)
- **CallLoweringInfo**（TargetLowering.h:4991-5110）：Chain/RetTy/RetSExt/IsVarArg/IsTailCall/CallConv/Callee/Args/Outs/OutVals/Ins/CFIType/PAI 全字段 + builder 链式 setter；setCallee（:5086-5110）从 CallBase 读属性
- **lowerInvokable**（:9271-9310）：先 flush pending（call 可能不返回 :9276-78）→ TLI.LowerCallTo(CLI)（:9284）→ **null chain 即 tail call**（HasTailCall=true + PendingExports.clear() :9291-98）
- **callseq token 语义**（ISDOpcodes.h:1296-1309）：首操作数 chain，其余 target 定义，两常量=对内/对外 call frame，**不可嵌套**。target 消费源：NVPTX getCALLSEQ_START（NVPTXISelLowering.cpp:1320）+ glue 序列化参数声明（:1322-31）+ CALLSEQ_END 后**追加 ProxyReg 防悬空**（:1683-92，后续 NVPTXProxyRegErasure 擦除）；AMDGPU 不支持的 call 也合成 0,0 的 CALLSEQ 对保证下游合法（AMDGPUISelLowering.cpp:1414-15）+ addTokenForArgument（:1353-82）把原 chain 混入 TokenFactor"帮 legalize 找到 CALLSEQ_BEGIN"

## 2.4 FunctionLoweringInfo（预扫描状态）

独立文件（593 行）。Builder 消费：MBB 映射、ValueMap(vreg)、StaticAllocaMap、CanLowerReturn/DemoteRegister、PHINodesToUpdate、BPI、PreferredExtendType、isExportedInst、CreateRegs。
**调用链**：SelectionDAGISel.cpp:1653 SelectAllBasicBlocks → :1676/1693 LowerArguments → :878-902 SelectBasicBlock 逐指令 `SDB->visit`(:889) → CodeGenAndEmitDAG(:901)。

## 2.5 StatepointLowering（GC 专用分支）

独立文件 StatepointLowering.cpp（1,377 行）+ .h(126)≈ Builder 总量 **10%**。隔离手段：StatepointLoweringState 成员（.h:173-175）、visit() 对 GCStatepointInst 跳过通用导出（:1396-97）、startNewStatepoint（StatepointLowering.cpp:90）每点重置。

## 2.6 动态验证（实测，-debug-only=isel-dump）

builder_test.ll（call+phi+alloca 循环）的 Initial DAG：

```
t2: i32,ch = CopyFromReg t0, Register:i32 %2        ← 函数参数入口
t3: ch = CopyToReg t0, Register:i32 %5, Constant:i32<0>  ← PHI 常量导出（%5=phi vreg）
t5: ch,glue = callseq_start t0, ...                 ← call 序列开
t9: ch,glue = CopyToReg t5, Register:i32 $w0, t3    ← 参数装寄存器（glue 穿线）
t13: ch,glue = callseq_end t12, ..., t12:1          ← 序列闭（glue 链）
t14: i32,ch,glue = CopyFromReg t13, Register:i32 $w0, t13:1  ← 返回值（glue 消费）
t23: ch = TokenFactor t18, t14:1                    ← 多 chain 汇合
```
**边界协议五要素一次全实证**：CopyFromReg（参数/返回）、CopyToReg（PHI 导出/参数装载）、callseq_start/end+glue 穿线、TokenFactor 汇合。

## 2.7 昇腾映射（推理级，待验证）

1. **visit 分发表模板**：PyPTO tile IR→tile DAG 的构造器应复制"单个 switch + HANDLE 宏"模式（避免虚表——ConstantExpr 兼容性理由在 tile 层同样成立）
2. **SSA 边界协议**：tile DAG 若以"循环迭代/stage"为区域（无跨区域 phi），CopyFrom/ToReg 式的 vreg 通道+AssertZext 已知位恢复是现成方案
3. **CallLoweringInfo 打包**：tile 图的"编排节点"（copy/compute）参数打包可仿 CLI 的 builder 链式 setter
4. **FLI 预扫描**：tile IR 的静态信息（tile shape/循环归纳变量）预扫描成 FuncInfo 式状态——避免 visit 期间重复计算

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| SelectionDAGBuilder.cpp:115, 1373-1435, 1779-1816, 2215-2377, 2382-2393, 2819-2924, 3738-3756, 4735-4785, 893-1034, 9271-9454, 9826-10033, 11884-11908, 11933-12029, 12101-12440, 12473-12547, 12955-13041 | visit/边界/call |
| SelectionDAGBuilder.h:173-182, 500-517, 592-622 | 成员/包装 |
| SelectionDAGISel.cpp:117-118, 192-196, 904-939, 965-968, 1653-1693 | isel-dump/驱动 |
| TargetLowering.h:4991-5110 | CallLoweringInfo |
| ISDOpcodes.h:1296-1309 | callseq 语义 |
| StatepointLowering.cpp:90 / .h:126, 173-175 | GC 隔离 |
| NVPTXISelLowering.cpp:1320-1331, 1683-1692 / AMDGPUISelLowering.cpp:1353-1415 | target 消费 |

实测素材：scratch/builder_test.ll（边界协议五要素 dump）。
