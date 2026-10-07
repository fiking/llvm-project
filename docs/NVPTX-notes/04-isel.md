# §5 NVPTX 指令选择（单路径 SDAG）深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，本仓库工作区实测（build-debug, nvptx64, sm_90）。
> 引用格式 `文件:行号`；实测素材 `NVPTX-notes/scratch/shared_test.ll`、`br_test.ll`。
> 素材来源：子代理调研（引用已核实，三处任务假设被证伪并修正）+ 主会话动态验证代写。
> 对照阅读：AMDGPU-notes/04-isel.md（双路径）。

**先修正三处任务假设**（子代理源码证伪）：
1. NVPTX LowerCall **无 CCAssignFn/CCState**——没有 TableGen CC 机制，ABI 布局手工实现
2. **无 LowerBRCOND**——brcond 是纯 TableGen 模式，不在 C++
3. wmma 是 **.td multiclass 批量生成**，不是 C++ lowering 函数

---

## 5.1 Select 主入口（NVPTXISelDAGToDAG.cpp，2402 行）

`Select(SDNode*)` :235-331：isMachineOpcode 早退 :237-240 → 大 switch（LOAD/ATOMIC_LOAD/MLoad→tryLoad :243-248；STORE→tryStore :249-253；ATOMIC_FENCE→tryFence :254-257；LoadV2/V4/V8→tryLoadVector :271-276；INTRINSIC_W_CHAIN→tryIntrinsicChain :288-291；AND/SRA/SRL→tryBFE :296-302；CopyToReg/CopyFromReg i128 :303-316；ATOMIC_*_B128 :317-320）→ 兜底 SelectCode(N) :330（表驱动）。

**代表 Select\* 三个**：
- **tryLoad** :1354-1431：拒绝 indexed :1360；`getAddrSpace` :1364 → `canLowerToLDG` :927-933（hasLDG && Global && isInvariant → ld.global.nc 走 tryLDG :1525）；否则 `insertMemoryInstructionFence` :1370 产出 Ordering/Scope；**地址空间作为 i32 立即数操作数拼进机器节点** :1404-1414；pickOpcodeForVT(LD_i16/32/64) :1417-1418
- **tryStore** :1639-1701：镜像结构，selectPossiblyImm :1675 允许立即数直存
- **tryIntrinsicChain/Void** :440-495/:2316-2366：**~100 个 tcgen05 ld/st intrinsic 分发**（50-case intrinsic→opcode 表 :337-415 → SelectTcgen05Ld/St :417/:2287）
- tryFence :2142-2162：Thread scope 直接删节点 :2150-254；getFenceOp :935+ 按版本回退 membar
- selectADDR :1150-1154：accumulateOffset+selectBaseADDR → [reg+immOff] 对

**与 AMDGPU 的核心差异**：grep 证实 NVPTX 全文件 **0 处 isDivergent**；AMDGPUISelDAGToDAG.cpp 有 :88/:637/:749（BUILD_VECTOR 按 isDivergent 选 VGPR/SGPR 类）/:1060/:1105/:1157/:1617/:2049。**原因：PTX 是虚拟 ISA + vreg 透传（§4 空 RA 已证），无 bank 分类决策点——divergence 感知整体下放 ptxas**。

## 5.2 四个代表 lowering（NVPTXISelLowering.cpp，8143 行）

### LowerCall :1294-1697——param space 的重量级设计
参数**不进寄存器**——每参数建 `.param` 符号（"param"+I，:4089-4091）：DeclareScalarParam（≥32bit，:1325-1335）/ DeclareArrayParam（byval，:1337-1345）声明 + store 到 param 空间（MachinePointerInfo(DeviceParam) :1473-1475/1545-1547）；返回值经 "retval0" :1557 在 CALL 后 load 回 :1668-1670；vararg 用 size-0 数组后补 MorphNodeTo :1570-1577；间接调用记 prototype :1609-1612；ProxyReg 保 callseq_end :1686-1691；**IsTailCall 恒 false** :1695。

**ABI 布局的手工实现**（修正：无 CC 机制）：ComputePTXValueVTs :311-346 + VectorizePTXValueVTs :489 + promoteScalarIntegerPTX :401-414（PTX Interop Guide 3.3(A) <32bit 整数扩展 :1490-1495）。

### LowerLOAD/LowerSTORE :3854-3872/:4003-4013——前缀选择不在 Lowering
**地址空间→ld.前缀的选择在 selector 不在 Lowering**（tryLoad 的 CodeAddrSpace 立即数 :1406）。LowerLOAD 只管 i1（zextload i8+trunc :3839-3852）和 EXTLOAD→ZEXTLOAD :3863-3869；LowerSTORE 只管 i1（:4019-4032）和向量化（lowerSTOREVector :3910-4001，对齐不足回退标量化 :3933-3940）。前缀立即数→asm 后缀的映射在 MC 层 InstPrinter。

### BRCOND——纯 TableGen 模式（修正：无 C++ 函数）
NVPTXInstrInfo.td:2702：`def CBranch ... "@${negate}$a bra $target" [(brcond i1:$a, bb:$target)]`，B1 谓词寄存器类。BR_CC 全类型 Expand（:692-695）。**对照 AMDGPU** LowerBRCOND :8721/SelectBRCOND :2893 的 SCC/VCC+exec mask 分流——**PTX @p 是线程级谓词，SIMT 语义内建于 ISA，无需编码选择**。这是"虚拟 ISA 把语义复杂度藏进 ISA 定义"的教科书案例。

### wmma/mma——"新硬件=新 lowering"的真实形态
wmma 是 **TableGen 模式批量生成**：NVPTXIntrinsics.td :6075-6154 WMMA_LOAD/WMMA_STORE_D 类 + defset 四重 foreach（layout×stride×space×frag）+ Requires<Predicates> 门控；Lowering 侧仅 getTgtMemIntrinsic :4302+ 给 MMO。tcgen05（Blackwell）升级为 C++ SelectTcgen05Ld/St。全文件 **965 个 `case Intrinsic::`**。

**模式总结**：新特性 = 一个 .td multiclass（操作数 1:1 时）或一个 Select* 函数（需操作数编组时）——**没有 MC/RA/hazard 配套**（AMDGPU 每个新 feature 是几十个文件的工程）。

## 5.3 无 GISel 的表面积论证

NVPTX 目录无任何 GISel 文件（文件清单实证）。单一透传 vreg 空间 → **RegBankSelect 无可选方案、Legalizer 无编码合法性约束 → GISel 三大件零收益**；SDAG 8143 行全覆盖。对照 AMDGPU GISel 三大件 22,416 行（LegalizerInfo 8882/RegisterBankInfo 5823/InstructionSelector 7711）动机全是 SGPR/VGPR bank 合法性。

## 5.4 NoItineraries（NVPTX.td:77-78）

`class Proc<FeatureSM SM> : Processor<SM.Name, NoItineraries, [SM]>;` 实证——**无任何 SchedMachineModel**。对照 AMDGPU：SISchedule.td（624 行）:97-110 SISchedMachineModel（CompleteModel=1/IssueWidth=1/MispredictPenalty=20）+ 11 个速度模型 :112-122 + ProcResource；C++ 侧 GCNSchedStrategy 3394 行/SIMachineScheduler 1992 行/GCNIterativeScheduler/CoExec；AMDGPUTargetMachine.cpp :778-840 七种 createScheduler 工厂。**NVPTX 的 MachineScheduler 只剩依赖序（减 mov），时序/occupancy 全下放 ptxas**。

## 5.5 动态验证（实测，sm_90）

**shared/global 前缀选择**（scratch/shared_test.ll）：
```
ld.param.b64  %rd1, [k_param_0];      ← 参数从 .param 空间 load（LowerCall 设计的实证）
ld.shared.b32 %r1, [%rd1];
st.shared.b32 [%rd1+4], %r1;          ← [reg+immOff] 对（selectADDR :1150 实证）
ld.global.b32 %r2, [%rd2];
st.global.b32 [%rd2+4], %r3;
```
**AS3(shared)→ld.shared/AS1(global)→ld.global 前缀选择实测**——地址空间立即数→文本后缀的完整链路。

**@p 谓词分支**（scratch/br_test.ll）：
```
setp.lt.s32 %p1, %r2, 6;
@%p1 bra $L__BB0_2;
```
**谓词寄存器 B1 + @p 语法实测**——对照 AMDGPU 的 s_cmp+s_cbranch（uniform）/v_cmpx+exec（divergent）双路径，PTX 单一形态。

**ISel 匹配日志**（`-debug-only=isel`，DEBUG_TYPE "nvptx-isel" 无独立输出用通用 isel）：
```
Morphed node: t22: ch = CBranch t25, BasicBlock:ch<e>, TargetConstant:i1<0>, t10
Morphed node: t25: i1 = SETP_i32ri t8, TargetConstant:i32<6>, TargetConstant:i32<2>
```
SETP_i32ri + CBranch 的表驱动匹配过程可见。

## 5.6 昇腾映射（推理级，待验证）

1. **单层模式匹配的适用边界**：无资源约束的选择器 = switch+表驱动兜底即够；资源约束（bank/UB/TMEM 放置）出现时才需要第二层。**PyPTO 的 tile 算子选择若有资源约束（UB 512KB 预算），单层不够**——这正是 AMDGPU 需要 GISel 而 NVPTX 不需要的分界线
2. **"新特性=一个 multiclass"的轻量模式**：davinci 新指令若操作数 1:1 映射，.td multiclass 批量生成 + Requires 门控是最低工程成本路径（对照 §2 ISel 版本 gate）
3. **语义内建于 ISA 的代价转移**：PTX 把 SIMT 谓词做进 ISA 定义（@p），LLVM 侧零 divergence 感知；davinci 汇编若把同步/掩码做进指令语义（如带 repeat 的批量指令），框架层同样可以"零感知"——但代价是 ISA 文档成为唯一契约

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| NVPTXISelDAGToDAG.cpp:235-331, 237-240, 243-257, 271-276, 288-291, 296-302, 317-320, 330, 337-417, 927-933, 935+, 1150-1154, 1354-1431, 1404-1414, 1525, 1639-1701, 1675, 2142-2162, 2287, 2316-2366 | Select 全结构 |
| NVPTXISelLowering.cpp:311-346, 401-414, 489, 692-695, 1294-1697, 1325-1345, 1473-1475, 1490-1495, 1545-1547, 1557, 1570-1577, 1609-1612, 1668-1670, 1686-1691, 1695, 3839-3872, 3910-4001, 4003-4032, 4089-4091, 4302+ | 四代表 lowering |
| NVPTXInstrInfo.td:2702 | CBranch 模式 |
| NVPTXIntrinsics.td:6075-6154 | wmma multiclass |
| NVPTX.td:77-79 | NoItineraries |
| AMDGPU 侧引用（对照）: AMDGPUISelDAGToDAG.cpp:88,637,749,1060,1105,1157,1617,2049 / SISchedule.td:97-122 / AMDGPUTargetMachine.cpp:778-840 | — |

实测素材：scratch/shared_test.ll（AS→前缀链路）、br_test.ll（@p 谓词 + ISel 匹配日志）。
