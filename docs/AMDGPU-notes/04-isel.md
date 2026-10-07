# §6 AMDGPU 指令选择双路径深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，本仓库工作区实测（build-debug, gfx1100, O3）。
> 引用格式 `文件:行号`；实测素材 `AMDGPU-notes/scratch/isel_diff.txt` + `sdag.mir`/`gisel.mir`。
> 素材来源：子代理调研（引用已核实）+ 主会话动态验证。

**先修正两个常见误称**（本仓库实测确认）：
- SDAG selector 真名是 **AMDGPUISelDAGToDAG.cpp**（4816 行），`SIISelDAGToDAG.cpp` 不存在
- GISel 的 **waterfall 不在 LegalizerInfo**，而在 `AMDGPURegisterBankInfo::executeInWaterfallLoop`；SDAG 侧对应物在 `SIInstrInfo::generateWaterFallLoop`

---

## 6.1 双路径总览

```
SDAG（默认）：  IR → SelectionDAG → (自定义 Select + TD 表驱动) → MIR（物理寄存器+bank 约束事后修复）
GISel（-global-isel）：IR → G_MIR 通用指令 → Legalizer → DivergenceLowering
                      → RegBankSelect → RegBankLegalize → InstructionSelect → MIR（bank 前置合法）
```

GISel 流水线挂点（AMDGPUTargetMachine.cpp）：addIRTranslator(:1796, +PreLegalizerCombiner+Localizer :1803) → Legalizer(:1808) → addPreRegBankSelect(:1812, PostLegalizeCombiner :1814 + **DivergenceLowering :1815**——头注释 :13-18 确认"divergent i1 phi→lane mask phi，算法同 SDAG SILowerI1Copies") → **RegBankSelect :1819 + RegBankLegalize :1820** → RegBankCombiner(:1826) → InstructionSelect(:1830)。

## 6.2 SDAG 路径

**Select 主入口**（AMDGPUISelDAGToDAG.cpp:680）：isMachineOpcode 早退(:681)；LOAD/STORE/Atomic→glueCopyToM0LDSInit+SelectCode(:688-692)；大 switch 自定义 Select*（FMA_W_CHAIN :721、BUILD_VECTOR :742-752 **按 `N->isDivergent()` 选 VGPR/SGPR 类**、BFE :853、BRCOND :856）；兜底 SelectCode(N) :899。

表驱动机制（通用层）：SelectionDAGISel.cpp:1281 DoInstructionSelection（拓扑序从根反向遍历）、:3351 SelectCodeCommon（matcher 表解释器）。

**代表 lowering**（SIISelLowering.cpp 21639 行）：
- **LowerCall :4330**：chain-CC 特殊参数、CCState+CCAssignFnForCall :4459、passSpecialInputs :4465、逐 ArgLoc promote :4525
- **LowerBRCOND :8721**：CF intrinsic 识别，uniform 直接返回 :8752（与 §5 的 SIAnnotateControlFlow 注入衔接）
- **LowerLOAD :13593**：<32bit 加宽 i32 extload :13601；**uniform MMO→SGPR 路径判定 :13658**（SMEM 选择的决策点，§8 实测的"uniform load 走 SMEM"源头）
- **FMA 决策**：isFMAFasterThanFMulAndFAdd :7549（f32 mad/fma/denormal 三态）+ getFusedOpcode :17342（FMAD vs FMA 契约决策）

**SelectBRCOND :2893 精读**（§5 的下游衔接点）：`UseSCCBr = isCBranchSCC && isUniformBr`(:2904)；ballot 模式合并(:2906-2933)；非 V_CMP 来源插 `S_AND_B64 EXEC`(:2944-2969，注释点名 SIFixSGPRCopies 兜底)；末尾 CopyToReg SCC/VCC + S_CBRANCH_*( :2969-2973)。

## 6.3 GISel 三大件

**LegalizerInfo**（8882 行）：legalizeCustom :2328 大分发表；legalizeLoad :3480（CONSTANT_ADDRESS_32BIT→addrspacecast :3492；pow2 加宽+trunc/extract）。

**RegisterBankInfo**（5823 行）——**本路径的灵魂**：
- 头注释 :20-60：waterfall 定义、s1-means-VCC、constant bus 限制及"VALU 源全部映射 VGPR"策略
- getInstrAlternativeMappings :468：G_AND s1 的 SCC vs VCC 双映射、G_LOAD 的 SS/VV、G_BRCOND SGPR/VCC——**一条指令多套 bank 方案交给 RegBankSelect 选**
- isScalarLoadLegal :442：uniform MMO+对齐+invariant（与 SDAG LowerLOAD :13658 同一决策的 GISel 版）
- getInstrMappingForLoad :3768：PtrBank==SGPR && flat/global→SMRD 判定
- getInstrMapping :3859 注释："Fast 模式必须返回合法映射，SGPR 需求的 operand 暂时接受 divergent VGPR，由 applyMappingImpl 处理"
- **executeInWaterfallLoop :773**（waterfall 精读）：4 块拆分、buildReadFirstLane、VCC ICMP_EQ+AND、ballot→s_and_saveexec→s_xor、SI_WATERFALL_LOOP 伪指令、保存/恢复 EXEC；collectWaterfallOperands :972

**InstructionSelector**（7711 行）：select() :4523（isPreISelOpcode 分发：G_AND/OR/XOR→selectBITOP3→selectImpl→selectG_AND_OR_XOR 三级 :4533-4538；i1 extend 绕过 selectImpl 的 workaround 注释 :4605-4613）；selectCOPY :126（VCC dst 非 VCC src→掩码+V_CMP_NE 或常量 S_MOV）；selectCOPY_SCC_VCC :222（S_CMP_LG 设 SCC）；selectCOPY_VCC_SCC :249（常量 1→COPY EXEC、否则 S_CSELECT，注释"RegBankLegalize ensures high bits are 0" :274）；selectG_BRCOND :3163（非 VCC→S_CBRANCH_SCC1，注释 :3172-3176 "SDAG 在 select 时查 IR uniformity，GISel 应 push 到 RegBankSelect"——**架构债务的自觉**）；selectBITOP3 :4405（V_BITOP3，constant bus 限制下 SGPR→VGPR copy :4444-4455）。

## 6.4 事后修复 vs 前置保证（本章核心论点）

| | SDAG：SIFixSGPRCopies | GISel：RegBankLegalize |
|---|---|---|
| 时机 | ISel 之后（addInstSelector 后） | InstructionSelect 之前（:1820） |
| 机制 | worklist 扫描非法 VGPR→SGPR copy → moveToVALU 转置（SIFixSGPRCopies.cpp 头注 :13-58：coalescer 经 PHI 制造非法 copy；moveToVALU 调用 :949/:1111；SIInstrInfo::moveToVALU :8173） | 按 uniformity 信息**主动 lower** 无法 inst-select 的 bank 组合（AMDGPURegBankLegalize.cpp 头注 :13-20：vgpr S64 G_AND→S32、消除 sgpr S1） |
| 本质 | 兜底补丁（信息已丢失，只能保守转 VALU） | 约束求解（信息完整时前置决策） |

**演进方向本身是 LLVM 的经验教训**：约束不满足时前置 lower 优于事后修复——SDAG 路径的 SIFixSGPRCopies/SDAG 版 waterfall（generateWaterFallLoop :7569，保存 SCC :7596）都是"选择时不看 uniformity"的代价。

## 6.5 Fallback 机制

- TargetPassConfig.cpp:191-198：`-global-isel-abort` 0/1/2 三态
- :1073-1083：GISel 失败后仍加 SDAG selector 的条件逻辑
- ResetMachineFunctionPass.cpp:30-66：hasFailedISel→MF.reset() 重建（fallback 的物质基础）
- InstructionSelect.cpp:232/326：失败路径 setFailedISel
- LCSSA 在 -global-isel 无 fallback 时禁用（AMDGPUTargetMachine.cpp:1744-1750，呼应 §5.3 考古）

## 6.6 动态验证（实测，gfx1100 O3）

测试用例 /tmp/isel_test.ll（load + fmuladd + brcond，divergent tid 索引）：

```bash
$ llc -stop-after=instruction-select → sdag.mir; llc -global-isel -stop-after=... → gisel.mir
$ diff → 193 行差异（scratch/isel_diff.txt）
```

**关键差异**（两路径真实输出对照）：

| 项 | SDAG | GISel |
|---|---|---|
| 寄存器形态 | 物理寄存器（renamable $vgpr0） | 带 bank 的 vreg（%38:vgpr_32）——RegBankSelect 的痕迹 |
| FMA 收缩 | `V_FMA_F32_e64` | `V_FMAC_F32_e64`（**收缩约定不同**：GISel 默认 contract） |
| 分支极性 | `S_CMP_LT + S_CBRANCH_SCC0` | `S_CMP_LE + S_CBRANCH_SCC1`（条件翻转方向相反） |
| load | GLOBAL_LOAD_DWORD_SADDR（同） | GLOBAL_LOAD_DWORD_SADDR（同——SMEM/VMEM 决策两路径一致） |

GISel MIR 的 `%NN:vgpr_32`/`%NN:sgpr_32` 注解即 bank 分配结果——`-debug-only=reg-bank-select`（DEBUG_TYPE 在 RegBankSelect.cpp:55）在 llc 下无独立输出，bank 证据以 MIR 注解为准。

## 6.7 昇腾映射（推理级，待验证）

1. **两层选择架构**：模式匹配层（TD 表驱动+自定义 Select/selectImpl）+ 资源约束层（isDivergent/isScalarLoadLegal/bank 映射）——PyPTO tile 算子选择若做"算子匹配 + 资源约束（UB/TMEM 放得下吗）"两层，这是现成分层
2. **前置 lower 优于事后修复**（§6.4 核心教训）：PyPTO 若发现"选完了才知道放不下"类问题，解法是把资源约束 push 到选择之前（RegBankLegalize 模式），不是选完再改（SIFixSGPRCopies 模式）
3. **waterfall 的通用性**：标量单元要求 uniform 输入而输入发散时的"逐 lane 重试 + exec mask 收敛"模式，任何标量/向量双单元架构（含 davinci 的 S/V 管线）都可能需要
4. **Fallback 的工程价值**：MF.reset() 重建的"失败可回退"设计让新路径可以渐进替换——昇腾若重写指令选择层，"新路径失败回退老路径"（§3 的双路径并存战略）是风险控制模板

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| AMDGPUISelDAGToDAG.cpp:680-899, 721-752, 853-856 | SDAG Select |
| AMDGPUISelDAGToDAG.cpp:2893-2973 | SelectBRCOND |
| SIISelLowering.cpp:4330-4525, 7549, 8721-8752, 13593-13658, 17342 | 代表 lowering |
| SelectionDAGISel.cpp:1281, 3351 | 表驱动通用层 |
| AMDGPULegalizerInfo.cpp:2328, 3480-3492 | Legalizer |
| AMDGPURegisterBankInfo.cpp:20-60, 442, 468, 773, 972, 3768, 3859 | bank 映射 + waterfall |
| AMDGPUInstructionSelector.cpp:126, 222, 249-274, 3163-3176, 4405-4455, 4523-4613 | select 主体 |
| SIFixSGPRCopies.cpp:13-58, 949, 1111 / SIInstrInfo.cpp:7569-7596, 8173 | 事后修复 |
| AMDGPURegBankLegalize.cpp:13-20 | 前置保证 |
| AMDGPUTargetMachine.cpp:1744-1750, 1796-1830 | GISel pipeline 挂点 |
| TargetPassConfig.cpp:191-198, 1073-1083 / ResetMachineFunctionPass.cpp:30-66 | fallback |
| RegBankSelect.cpp:55 | DEBUG_TYPE |

实测素材：scratch/isel_diff.txt（193 行 MIR diff）、sdag.mir / gisel.mir（两路径完整输出）。
