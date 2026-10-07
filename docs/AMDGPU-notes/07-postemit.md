# §9 素材：AMDGPU PostRA/PreEmit 阶段 14 个 Pass 深度分析

> 分析对象：LLVM main @ 3eda2aebadd4，`llvm/lib/Target/AMDGPU/`
> 重点精读：`SIInsertWaitcnts.cpp`（3775 行）、`GCNHazardRecognizer.cpp`（4361 行）
> 方法：静态分析（文件:行号均经 grep/read 核对）+ 动态验证（build-debug llc）
> 交叉参考：`llvm/docs/AMDGPUExecutionSynchronization.md`（注意：该文档位于 `llvm/docs/`，而非任务描述中的 `llvm/docs/AMDGPU/` 子目录）

---

## 9.0 总览：addPreEmitPass 流水线（14 个 pass）

管线定义：`AMDGPUTargetMachine.cpp:2779-2819`（`AMDGPUCodeGenPassBuilder::addPreEmitPass`）。

```
[GCNCreateVOPD]            (可选，EnableVOPD && O>=Less，gfx11+ wave32 双发射打包)
SIMemoryLegalizer          (原子/栅栏内存序合法化，插 buffer_wbinvl1 等)
[SIPostRA16BitMovFolding]  (O>None；v_mov_b16 成对合并)
SIInsertWaitcnts           (★ 核心：插 s_waitcnt 系列)
SIModeRegister             (MODE 寄存器双精度舍入模式 setreg 插入)
[SIInsertHardClauses]      (O>None；gfx10+ s_clause 硬子句标记)
SILateBranchLowering       (S_CBRANCH_SCCx/chain-call 展开等分支后期合法化)
[AMDGPUSetWavePriority]    (可选，O>=Less；s_setprio 提升波优先级)
[SIPreEmitPeephole]        (O>None；VCC 分支优化/去 execz 分支等)
PostRAHazardRecognizer     (★ 独立 hazard 识别 pass，见 §9.3)
AMDGPUWaitSGPRHazards      (gfx12 s_wait_alu：SALU/VALU 写 SGPR→读 hazard)
AMDGPULowerVGPREncoding    (gfx12.5 VGPR>255 的 S_SET_VGPR_MSB 模式切换)
[AMDGPUInsertDelayAlu]     (可选 O>=Less；gfx11+ s_delay_alu 延迟槽)
BranchRelaxation           (通用：分支目标超距时插蹦床块)
```
括号表示有条件运行；无括号为无条件（AMDGPUTargetMachine.cpp:2779-2818 逐行核对）。

**设计动机（整体）**：这些 pass 全部在寄存器分配之后、最终汇编打印之前运行，处理三类问题：
1. **正确性**：异步内存管线的数据依赖（waitcnt）、发射流水线 hazard（nop/wait_alu/depctr）、内存序（wbinvl1/栅栏）、分支距离。
2. **性能**：VOPD 双发射、hard clause、编码收缩、delay 提示。
3. **合法性**：VGPR 高位编码、模式寄存器、分支 late lowering。

**昇腾映射（总）**：该阶段是"指令调度之后、发射之前"的最后一公里，与昇腾 dav-m200 的发射约束检查/同步指令自动插入阶段对应；详见各节末尾的映射条目（均标注"待验证"）。

---

## 9.1 SIInsertWaitcnts.cpp 精读（3775 行）

### 9.1.1 多内存管线计数模型

计数器类型枚举 `AMDGPU::InstCounterType`（`AMDGPUWaitcntUtils.h:22-40`）：

| 计数器 | pre-gfx12 名称 | 追踪的硬件事件（WaitEventMaskForInstPreGFX12，SIInsertWaitcnts.cpp:250-268） |
|---|---|---|
| `LOAD_CNT` | vmcnt | VMEM_READ_ACCESS \| VMEM_SAMPLER_READ_ACCESS \| VMEM_BVH_READ_ACCESS \| VMEM_INV_ACCESS（:252-253）；无 VScnt 目标上还并入 VMEM_WRITE/SCRATCH_WRITE（:284-286） |
| `DS_CNT` | lgkmcnt | SMEM_ACCESS \| LDS_ACCESS \| GDS_ACCESS \| SQ_MESSAGE（:254-255） |
| `EXP_CNT` | expcnt | EXP_GPR_LOCK \| GDS_GPR_LOCK \| VMW_GPR_LOCK \| EXP_PARAM/POS/LDS_ACCESS（:256-258） |
| `STORE_CNT` | vscnt | VMEM_WRITE_ACCESS \| SCRATCH_WRITE_ACCESS（:259） |

gfx12+ 拆分更细（`WaitcntMaskForInstGFX12Plus`，:295-316）：LOAD/DS/EXP/STORE 之外新增 SAMPLE_CNT、BVH_CNT、KM_CNT（SMEM+SQ_MESSAGE+SCC_WRITE）、X_CNT（gfx12.5，SMEM_GROUP/VMEM_GROUP 地址翻译）、ASYNC_CNT/TENSOR_CNT（gfx12.5，LDS DMA 异步/tensor），以及 expert 模式专属 VA_VDST_RD/WR、VM_VSRC（:311-316）。每个计数器对应一条独立 S_WAIT_* 指令（`instrsForExtendedCounterTypes`，:117-122）。

**Scoreboard 数据结构**（`WaitcntBrackets`，:479-831）：核心思想是"分数括号"（score brackets）：
- `ScoreLBs[T]`/`ScoreUBs[T]`（:749-750）：计数器 T 的已确认完成下界 / 已发出上界。每个新事件把 UB+1（`updateByEvent` :892-913），`getOutstanding(T)=UB-LB`（:510-512）即未完成访问数。
- **按寄存器记分**：`DenseMap<VMEMID, VMEMInfo> VMem`（VGPR regunit + LDS DMA 槽位，:758-767、:807）、`DenseMap<MCRegUnit, SGPRInfo> SGPRs`（:808）、`SCCScore`（:811）。VMEMID 编码把 regunit 空间（[0,2^16)）与 LDS DMA ID 空间（[2^16,2^17)）拼在一个 u32 里（:74-102）。即"哪个寄存器上还挂着未完成的内存写/读"。
- `PendingEvents`（:751）：位掩码记录括号内混合了哪些事件类型——混类时硬件可能乱序减计数，必须退化为 `waitcnt 0`（`counterOutOfOrder` :1574-1611，注释 :474-478）。
- 特殊追踪：`LastFlat*`（flat 指令同时进 vmcnt 和 lgkmcnt 两套括号，:613-623）、`LastGDS`（GDS 原子在 lgkmcnt 里出乱序，:625-635）、`AsyncMarks`（@llvm.amdgcn.wait.asyncmark 采样点，:819-826，上限 16）。

### 9.1.2 插入算法（追踪未完成访问 → 消费点前插最小等待）

数据流分三步（`insertWaitcntInBlock` :3080-3186 为骨架）：

1. **生产侧记账** `updateEventWaitcntAfter`（:2738 起，内部调 `updateByEvent` :892-1108）：每条访存/导出指令后，按事件类型确定计数器 T，UB+1，并把分数写到**目标寄存器**（load → vdst，store → data/addr 源，export → 源 VGPR——因 export 锁住源寄存器，:919-989）或 LDS DMA 虚拟槽（:1054-1097）。VALU 专用计数（VA_VDST 等）把分数挂在**读/写操作数**上（:1003-1021）。

2. **消费侧查询** `generateWaitcntInstBefore`（:2331-2634）：对每条指令的每个寄存器操作数查 scoreboard：
   - VGPR：`determineWaitForPhysReg(VA_VDST_WR/RD, VM_VSRC, LOAD_CNT, SAMPLE_CNT, BVH_CNT, EXP_CNT, DS_CNT)`（:2514-2548）；WAW（同是 VMEM 写且事件类型一致时硬件保序可跳过，`updateVMCntOnly`+`hasDifferentVGPRPendingEvents` :2523-2541）；SCC → KM_CNT（:2549-2550）；SGPR → SmemAccessCounter（lgkm/km，:2552-2553）。
   - `determineWaitForScore`（:1367 起）把寄存器分数换算成 waitcnt 数值：`Wait.add(T, min(Wait[T], UB - Score))`——即"再等 k 个该类事件，分数 ≤ 目标寄存器分数的那次访问就完成"。
   - 特殊强制点：返回/调用前全零等待（:2354-2367）；写 EXEC 前若挂起 export/GDS 锁则 expcnt(0)（:2400-2409）；`S_BARRIER` 在无 BackOffBarrier/auto-wait 特性的目标上全零等待（:2575-2577，与官方文档 §Barrier 一致，见 9.1.4）；`SI_ENDPGM` 前记录是否需 DEALLOC_VGPRS（:2368-2381）。

3. **化简与发射** `simplifyWaitcnt`（:1281 起，若 LB 已追上所需分数则该计数器无需等待）→ `generateWaitcnt`（:2636）→ `WaitcntGenerator::createNewWaitcnt`。生成器按 ISA 分两个实现（抽象动机注释 :149-154）：
   - **PreGFX12**（:1797-1888）：vm/exp/lgkm 合并编码进单条 `S_WAITCNT`（:1805-1806 注释、:1847-1849），vscnt 单独 `S_WAITCNT_VSCNT null, imm`（:1876-1878）。
   - **GFX12Plus**（:2210 起）：每个计数器一条独立 S_WAIT_*CNT。
   - 已存在的 waitcnt（MemoryLegalizer 插的 soft waitcnt 或前次迭代产物）被合并/改写/延迟删除（`applyPreexistingWaitcnt` PreGFX12 版 :1656-1795，含 DeferredErasures 循环携带依赖保护 :165-167/:1700-1704）。

**块间数据流**：`run()`（:3478-3605+）在 RPO 上迭代到不动点：每块的 `WaitcntBrackets` 从前驱 merge（`merge` :2868）而来，`BI.Dirty` 标记脏块重跑（:3565-3595）；非入口函数在开头插全零 wait 序列（:3511-3549）。循环回边导致括号收敛（等待插入后 LB 上移，使出块括号为空或固定）。

### 9.1.3 与官方文档对照

`llvm/docs/AMDGPUExecutionSynchronization.md`（541 行；注意实际路径在 `llvm/docs/` 而非 `llvm/docs/AMDGPU/`）主要覆盖**栅栏语义**，不是 waitcnt 算法文档：
- :262-266 给出无 BackOffBarrier 目标（GFX6-11）上 *arrive then wait* barrier 的标准序列：`s_waitcnt vmcnt(0) expcnt(0) lgkmcnt(0)` + `s_waitcnt_vscnt null, 0x0` + `s_barrier`；:268-273 说明"计数器在发 s_barrier 前必须为 0，waitcnt 可前移/删除"。
- 代码对应：`generateWaitcntInstBefore` 中 `S_BARRIER` 分支（SIInsertWaitcnts.cpp:2575-2577）`!ST.hasAutoWaitcntBeforeBarrier() && !ST.hasBackOffBarrier()` 时 `Wait = Wait.combined(getAllZeroWaitcnt(true))`——与文档 GFX6-11 序列逐字对应（含 VSCnt，`IncludeVSCnt=true`）。GFX12 split barrier（文档 :284-289）则对应 `tryClearSCCWriteEvent`（:1506-1522，S_BARRIER_WAIT 落地保证 SCC 写完成）与 `S_BARRIER_SIGNAL_ISFIRST_IMM` 追踪（:1103-1106）。
- 文档不含 vmcnt/lgkmcnt 计数模型本身（全文 vmcnt/lgkmcnt/expcnt/vscnt 各只出现 1 次，即 :262-264），计数语义的权威来源是 ISA 手册；LLVM 侧的"scoreboard 括号"模型是软件侧对硬件计数器的保守近似。

### 9.1.4 动态验证

`DEBUG_TYPE` = `"si-insert-waitcnts"`（SIInsertWaitcnts.cpp:45；llc 参数 `-debug-only=si-insert-waitcnts`）。

**验证 1**（scratch/waitcnt_test2.ll，gfx1100，`-debug-only=si-insert-waitcnts`）：volatile global_load 后紧跟 fmul。debug 日志逐条打印 `*** GenerateWaitcntInstBefore` / `New Instr`，在 `V_ADD_F32`（消费 load 结果 v1）前生成 `New Instr: S_WAITCNT .Vmcnt_0`；最终汇编：

```asm
s_load_b128 s[0:3], s[4:5], 0x24
v_mov_b32_e32 v0, 0
s_waitcnt lgkmcnt(0)          ; ← 等 kernarg s_load 完成（SGPR 记分板：descriptor 寄存器 s[2:3] 上挂 lgkm 分数）
global_load_b32 v1, v0, s[2:3] glc dlc
s_waitcnt vmcnt(0)            ; ← 等 VMEM load 完成（VGPR v1 记分板：LOAD_CNT 分数 > LB）
v_add_f32_e32 v1, v1, v1      ; 消费点
global_store_b32 v0, v1, s[0:1]
s_endpgm
```

完整复现了 §9.1.2 的三步：lgkm 分数挂在 s_load 的 dst SGPR 上（updateByEvent :1001-1002），vmcnt 分数挂在 global_load 的 dst v1 上（:1032-1053），消费点前 determineWaitForPhysReg → S_WAITCNT（PreGFX12 编码 :1847-1849）。注意 lgkmcnt(0) 插在 load 之前而非 v_mov 之前——因 s[2:3] 在 load 处被消费，而非更早（括号合并导致它实际被放置在最后一个"无害"位置之前，即 load 前）。

### 9.1.5 设计动机

- VMEM（几百 cycle 延迟）/LDS/SMEM/export 是**多条异步流水线**，VALU 消费其结果必须显式等待；硬件计数器按类递减，编译器用 LB/UB 括号 + 按寄存器记分精确模拟"差几个事件"，从而**只插必要的等待**且尽量**合并**（单条 S_WAITCNT 同时编码三个计数域）。
- 按寄存器记分（而非全程序 UB/LB）是性能关键：远处无关的 VMEM 访问不会迫使本处等待。
- `counterOutOfOrder` 的"混类退化为 0"（:1572-1611）是保守正确性兜底。

### 9.1.6 昇腾映射（待验证）

- **算法映射**：昇腾 MTE（Memory Transfer Engine）的 `set_flag/wait_flag` 自动插入与 s_waitcnt 同构——都是"生产者打标记、消费者前插等待"。AMDGPU 的差异点是 (a) 计数器按事件类共享（一个 vmcnt 计数器服务所有 VMEM load，粒度是"第 k 个事件完成"），而 set_flag/wait_flag 是显式标记通道（flag id + 依赖号）；(b) AMDGPU 按寄存器记分可在不同 VGPR 上并行挂起多批访问，昇腾 flag 通道数量有限（MTE flag 数量、db 和 flag 组合）→ 昇腾侧等价物需要类似 scoreboard 的"每个 flag 通道未消费 set 数"括号模型。【待验证：dav-m200 MTE flag 通道数与硬件自动等待语义】
- **计数粒度映射**：vmcnt 的事件计数模型（等"倒数第 k 个"）在昇腾对应 load2out 的 data-dependency 编号；vscnt（store 完成）对应 store 的 flag 通知机制。【待验证】
- **合并策略**：PreGFX12 把三个等待域压进一条指令立即数，可借鉴到昇腾"单条 wait_flag 多通道"的打包（若 ISA 支持组合等待）。【待验证：dav-m200 wait_flag 是否支持一次等多 flag】

---

## 9.2 PostRAHazardRecognizer 独立成 pass 的注释

`AMDGPUTargetMachine.cpp:2802-2809` 原文（逐字核对）：

> The hazard recognizer that runs as part of the post-ra scheduler does not guarantee to be able handle all hazards correctly. This is because if there are multiple scheduling regions in a basic block, the regions are scheduled bottom up, so when we begin to schedule a region we don't know what instructions were emitted directly before it.
> Here we add a stand-alone hazard recognizer pass which can handle all cases.

**解释**：MachineScheduler 把一个 BB 切成多个调度区域（以边界指令分界），**自底向上**调度每个区域。开始调度一个区域时，它下方（发射序更早）相邻区域的最终指令序尚未确定，而多数 hazard 是"相邻 N 条/cycle 距离内"的局部约束 → 调度器内嵌的 `GCNHazardRecognizer`（`CreateTargetPostRAHazardRecognizer(II, DAG)`，SIInstrInfo.cpp:10419-10423）看不到跨区域边界前一条指令是什么。

因此独立 pass 用第二种构造 `CreateTargetPostRAHazardRecognizer(MF, MLI)`（SIInstrInfo.cpp:10425-10432），以 `OperatingMode::HazardRecognizerMode` 运行：此时 `getWaitStatesSince` 不再查调度器的 `EmittedInstrs` 窗口，而是**直接沿 MIR 逆向遍历真实指令流（可跨基本块，经 Visited 集合防环）**（GCNHazardRecognizer.cpp:963-1012、:1014-1022 分支），`PreEmitNoops`/`runOnInstruction`（:685-706）在最终指令序上逐条检查并物理插入 S_NOP / S_WAITCNT_DEPCTR 等修复。

顺带核对 `-O0`：该 pass 同时是 -O0 的 hazard 处理者（注释 :10425 "used at -O0 by the PostRAHazardRecognizer pass"）。

**动态验证**：见 §9.8.2（构造 vcmpx→permlane hazard 场景）。

**设计动机**：正确性兜底必须基于**最终指令序**而非调度中间态；独立 pass 在全部指令序定型后运行，天然看到跨区域边界。

**昇腾映射（待验证）**：dav-m200 的发射约束（如 cmpmask 类指令多 repeat 占用、相邻指令操作数 bank 冲突）若在调度器内检查，同样会遇到"调度区域边界相邻指令未知"问题 → 应有（或需要）一个 PreEmit 兜底检查 pass，在最终指令序上做表驱动约束检查与自动插 nop。【待验证：昇腾编译器是否已有此兜底层；cmpmask 多 repeat 限制的具体表项形式】

---

## 9.3 GCNHazardRecognizer.cpp 精读（4361 行）

### 9.3.1 总体结构：三模式 + 双查询引擎

- **OperatingMode**（GCNHazardRecognizer.h:53）：`PreRA` / `PostRA`（调度器内嵌，查 `EmittedInstrs` 滑动窗口，h:63；VALU 专用窗口 `EmittedVALUInstrs`，h:71-73，MaxVALULookAhead=18）和 `HazardRecognizerMode`（独立 pass，逆向遍历真实 MIR）。
- **check 族**（返回需要的 wait-state/nop 数，`getHazardType` :542-639 调度器入口；`PreEmitNoopsCommon` :725-772 PreEmit 入口）：按指令类别（SMRD/VMEM/VALU/DPP/DivFMas/RWLane/MAI/GetReg/SetReg/RFE/M0-reader/inline-asm）分发，全部 `std::max` 聚合——同类只取最坏。
- **fix 族**（`fixHazards` :1759-1787，仅 HazardRecognizerMode）：21 个 fixer，无法用 S_NOP 修复的 hazard（插 S_WAITCNT_DEPCTR / 重写指令 / 插蹦床）。
- **跨块逆向查询原语**：
  - `getWaitStatesSince(IsHazard, MBB, I, WaitStates, IsExpired, Visited)`（:963-1000）：从 MI 逆向走，命中 hazard 谓词返回当前 WaitStates；每条非 asm 指令累加 `getNumWaitStates`；`IsExpired` 谓词命中则返回 INT_MAX（hazard 窗口已过）。**递归进所有前驱**（:988-997），Visited 去重——本质是对 CFG 的一次受限 DFS。
  - `hasHazard<StateT>`（:877-960）：带自定义状态（如"见过几个 VALU/TRANS"）的泛型版本，用 DenseMap 状态去重，支持循环（状态哈希相等即剪枝）。fixVALUTransUseHazard 的 (VALUs, TRANS) 计数对即其状态机实例。

### 9.3.2 五类代表性 hazard 实现

**(1) 读改写类：SI SMRD 读 VALU 写的 SGPR（checkSMRDHazards，:1175-1221）**
- 条件：`ST.hasSMRDReadVALUDefHazard()`（仅 SI/GFX6）。
- 模式：VALU 写 SGPR（v_writelane 等把数据写回 SGPR）后 4 个 wait-state 内 SMRD 读该 SGPR。`SmrdSgprWaitStates=4`（:1186），对 SMRD 每个寄存器 use 查 `getWaitStatesSinceDef(Use, IsVALUDef, 4)`，差值即需补的 nop（:1196-1202）。
- 附加：SI 未成文行为——s_mov 写 descriptor 后 s_buffer_load 读需 4 nop（:1204-1217 注释自述"undocumented hardware behavior"）。
- 同类：VMEM 读 SGPR 5 wait-state（checkVMEMHazards :1223-1245）、DPP 读 VGPR 2 / 读 EXEC 5（checkDPPHazards :1247+）。

**(2) VMEM→SMEM/标量写类：fixVMEMtoScalarWriteHazards（:1831-1875）**
- 条件：`ST.hasVMEMtoScalarWriteHazard()`（gfx10+）。
- 模式：VMEM/DS 指令读 SGPR X，紧随的 SALU/SMRD 写 X → 旧值被提前转发给 VMEM。谓词 IsHazardFn：前序指令 isVMEM/isDS 且 use 了本指令的 def（:1844-1856）；IsExpiredFn：遇到任何 VALU 或 vm_vsrc 域清零的 wait 即失效（:1858-1864）。
- 修复：插 `S_WAITCNT_DEPCTR`（encodeFieldVmVsrc(0)）（:1871-1873）——不用 nop 而用依赖计数器等待。
- 镜像：fixSMEMtoVectorWriteHazards（:1877+，SMEM 读→VALU 写 v_readlane 的 sdst）。

**(3) Vcmpx→Permlane（读改写 EXEC 类，fixVcmpxPermlaneHazards，:1796-1829）**
- 条件：`ST.hasVcmpxPermlaneHazard()`（gfx10）。
- 模式：v_cmpx 写 EXEC 之后，permlane 读旧 EXEC（SRC 未锁存）导致源操作数错误。IsHazardFn = isVCmpXWritesExec（:1789-1794），IsExpired = 任何非 NOP 的 VALU（:1806-1811）。
- 修复很特别：插 `V_MOV_B32 v?, v?`（用 permlane 的 src0 自复制），注释 :1817-1819 "V_NOP will be discarded by SQ"——硬件会丢弃 V_NOP，必须用真实 VALU 指令隔开。

**(4) TRANS 图冲突：fixVALUTransUseHazard（:2336-2420）**
- 条件：`ST.hasVALUTransUseHazard()`（gfx11）。
- 模式：TRANS 单元指令（v_sqrt/v_exp 等走 transcendental 图）写 VGPR，随后 ≤5 条 VALU / ≤1 条 TRANS 内有指令读该 VGPR → 转发路径错误。状态 StateType{VALUs, TRANS}（:2364-2374），窗口 IntvMaxVALUs=5 / IntvMaxTRANS=1（:2361-2362），IsHazard 兼任过期判定（:2379-2401：VMEM/DS/EXP 或 va_vdst==0 的 DEPCTR 都会清窗口）。
- 修复：`S_WAITCNT_DEPCTR`（encodeFieldVaVdst(0)）（:2415-2417）。跨块安全性由 `hasHazard<StateT>` 状态去重保证。
- 同族：fixVALUTransCoexecutionHazards（:2422+，co-exec 模式 TRANS 占用冲突）。

**(5) 软子句（soft clause）读改写：checkSoftClauseHazards（:1115-1173 + checkSMRDHazards :1178）**
- 模式：XNACK 重启场景下，同一软子句（同类 SMEM/VMEM load 序列）内后一条 load 的源寄存器被前一条 load 的目标覆盖 → 重启后读到错值。`addClauseInst`（:1115）累积子句 defs/uses 位图，`ClauseDefs.anyCommon(ClauseUses)` 判交（:1172）；遇 store 直接破句（:1165-1166）。破句方式=插入 1 个 wait-state 的间隔。
- 注：gfx10 前软子句是硬件自动检测的；hard clause 见 §9.6。

其余十余类（全表见 h:187-267 声明）：WMMA/矩阵（checkMAIHazards 908/90A、fixWMMAHazards、fixWMMACoexecutionHazards——co-exec 槽位模型 checkWMMACoexecSlot :341+、hasWMMAToWMMA/VALURegOverlap :2657/:2675、循环外提升 tryHoistWMMAVnopsFromLoop :2737）、fixVcmpxExecWARHazard（:1967）、fixLdsBranchVmemWARHazard（:2036，分支前后 LDS 与 VMEM 的 WAR，需跨块且配合 waitcnt）、LDS_DIRECT（:2093/:2137）、VALU partial forwarding（:2177，v_mov_b4 高低位部分转发）、fixShift64HighRegBug、fixVALUMaskWriteHazard（:3925）、fixRequiredExportPriority（:4121，PS export 优先级协议）、GetReg/SetReg（:1293/:1306，s_getreg 读 s_setreg 写的同一 HW 寄存器 2 wait-state）、RFE、ReadM0 系列、fixScratchBaseForwardingHazard（:4252）、NSA-to-VMEM、FPAtomic→DenormMode 等。

### 9.3.3 动态验证

**验证 2**（gfx1010，`llvm/test/CodeGen/AMDGPU/vcmpx-permlane-hazard.mir`，`llc -run-pass=post-RA-hazard-rec`）：

输入（节选，注意 **hazard 横跨两个基本块**）：
```mir
bb.0:
  $vgpr0 = V_MOV_B32_e32 0, implicit $exec
  V_CMPX_LE_F32_nosdst_e32 0, $vgpr0, implicit-def $exec, ...
  S_BRANCH %bb.1
bb.1:
  $vgpr1 = V_PERMLANE16_B32_e64 0, killed $vgpr1, ...   ; 读旧 EXEC → hazard
```
输出（post-RA-hazard-rec 之后）：
```mir
bb.1:
  ...
  $vgpr1 = V_MOV_B32_e32 killed $vgpr1, implicit $exec   ; ← fixVcmpxPermlaneHazards 插入的修复
  $vgpr1 = V_PERMLANE16_B32_e64 ...
```

三个要点均得到实证：(a) **跨基本块** hazard 被 `getWaitStatesSince` 的前驱递归（GCNHazardRecognizer.cpp:988-997）捕获——这正是"独立 pass 看得到、调度器看不到"的场景（§9.2）；(b) 修复物是 `V_MOV` 而非 `V_NOP`（:1817-1819 注释 "V_NOP will be discarded by SQ"）；(c) 测试自带的 `hazard_vcmpx_permlane16_v_nop` 变体（bb.1 中已有 V_NOP 隔开）输出同样插 V_MOV，印证 IsExpiredFn 只认**非 NOP 的 VALU**（:1806-1811）。

### 9.3.4 设计动机

- **为什么"表驱动"**：check/fix 均以谓词对 `(IsHazardFn, IsExpiredFn)` + 常量 wait-state 表达，window 由 `getNumWaitStates` 统一度量；新增 hazard = 加一个 check/fix 函数 + subtarget feature 位（`ST.hasXXXHazard()`），不改动框架。这与 LLVM TableGen 的 itinerary/调度模型互补——语义级约束（转发、EXEC 锁存）无法从 latency 表达。
- **为什么逆 CFG 遍历**：PreEmit 时指令序已定，但 hazard 跨度可越出单 BB（分支汇合），故 getWaitStatesSince 递归前驱且用谓词提前剪枝。

### 9.3.5 昇腾映射（待验证）

- **表驱动化映射**：GCN 的 (feature位, hazard谓词, 过期谓词, wait-state常量, 修复指令) 五元组 ⟷ dav-m200 发射约束表（如 cmpmask 类指令需占多个发射槽/repeat 周期、load 指令后某类 ALU 不能立即发射等）。建议结构：每条约束 = {触发指令谓词, 相邻指令谓词, 距离窗口, 修复手段(插 nop/重排/插等待)}，PostRA 兜底 pass 逆向扫描执行——与 GCNHazardRecognizer 的 `getWaitStatesSince(IsHazard, IsExpired)` 框架同构，可直接复用该骨架。【待验证：cmpmask 多 repeat 限制的确切硬件语义（发射槽占用 vs 结果延迟），及昇腾现有调度约束在哪个 pass 检查】
- WMMA co-exec 槽位模型（`dumpCoExecWindow` :133、`getCoExecMaskForMI` :303）可映射到昇腾向量/CUBE 单元与 ALU 共发槽位的占用表。【待验证】

---

## 9.4 SIModeRegister（MODE 寄存器状态机，488 行）

**静态分析**（SIModeRegister.cpp）：
- 文件头注释（:13-14）："only deals with the Double Precision Floating Point rounding mode setting, but is intended to be generic enough"。
- `Status = (Mask, Mode)` 二元组（:119-121 DefaultStatus）表示"MODE 寄存器中哪些位已知、值是什么"；默认 FP_ROUND_MODE_DP = ROUND_TO_NEAREST（:114-119）。
- 指令需求侧 `getInstructionMode`（:169-220）：`usesFPDPRounding`（双精度指令）、f16 插值（V_INTERP_*_F16 需要 RTZ，:179-184）、FPTRUNC_ROUND_*_PSEUDO 伪指令（降级为真实 cvt 并取立即数模式，:185-214）。
- 写侧 `insertSetreg`（:227-241）：按 Mask 的连续位段拆成若干 `S_SETREG_IMM32_B32`（HwregEncoding::encode(ID_MODE, Offset, Width)）。
- **三阶段不动点**：
  - Phase1（:262-358，注释 :243-261）：块内扫描，累计 Change（本块对 MODE 的修改）、Require（入口需求）、Exit；不兼容即记 InsertionPoint（块内插 setreg；入口需求延迟到 Phase3）。
  - Phase2（:360-419）：迭代传播——Pred = 所有前驱 Exit 的**交集**（Mask 只能减少，:370-374 注释），Exit = Pred.merge(Change)，变化则 successors 入队（worklist，:411-414）；自环块特殊处理（:383-385）。
  - Phase3（:424-435）：`!Pred.isCompatible(Require)` 时在 FirstInsertionPoint 前插 `Pred.delta(Require)` 的 setreg。
- strictfp 函数直接跳过（:450-458）：不得假设/修改默认舍入模式。
- 注：文件头所述 IEEE/dx10clamp/denormal 位实际**不在此 pass 管理**——dx10_clamp/denormal 由 SelectionDAG/ISel 阶段按 fn attribute 编进 VOP3 opsel/修饰符（见 SIInstructions t16/fake16 变体），MODE 的 FP_ROUND_MODE_DP 是唯一由该 pass 管理的域。此结论由 :165-168 注释（"currently only deals with ... double precision setting"）与 getInstructionMode 全文（:169-220 无 IEEE/dx10/denorm 分支）核实。

**动态验证**：见 §9.8.3（fptrunc round 动态指定 → 观察 s_setreg_b32 mode）。

**设计动机**：MODE 是**函数级全局可变状态**，而需求是指令级的；不做全局数据流就会每条 f64 指令前都插 setreg。三阶段向前数据流 + 交集合并把 setreg 数压到语义必需的次数（且保证入口需求由前驱出口满足时零开销）。

**昇腾映射（待验证）**：昇腾的浮点控制寄存器（如 round mode 控制）若为隐式全局状态，同构问题成立：需要 (Mask,Value) 格数据流 + 前驱交集合并 + 按需 setreg；昇腾向量指令多把 round mode 作为指令内立即数编码，若如此则无此 pass 必要性。【待验证：dav-m200 浮点舍入控制是指令内操作数还是全局寄存器】

---

## 9.5 AMDGPUSetWavePriority（233 行，可选 pass）

- 头注释（:13-17）：从函数开头到**最后一条 VMEM 指令**之间临时抬高波优先级（s_setprio），让年轻波也能发 VMEM，隐藏访存延迟。
- 实现要点：入口插 `s_setprio 2`（高优先级），扫描定位每个 BB 的最后 VMEM，在其后恢复 `s_setprio 0`；仅 O>=Less 且 EnableSetWavePriority（AMDGPUTargetMachine.cpp:2796-2797）。
- **昇腾映射**：昇腾若支持波/核优先级寄存器同理可做"访存密集段优先级抬升"；纯性能 pass，无正确性风险。【待验证：昇腾优先级机制】

## 9.6 SIInsertHardClauses（341 行）/ AMDGPUInsertDelayAlu（558 行）

**SIInsertHardClauses**（gfx10+，O>None，:2791-2792）：
- 头注释（:15-33）：gfx10 起硬件不再自动检测软子句，改用 `s_clause` 显式标记"硬子句"（同类型 load 连续序列，缓存一致性收益）；**调度器负责把相似访存排到一起，本 pass 只负责插 s_clause 标记**；与 XNACK 可重启组（SIFormMemoryClauses/GCNHazardRecognizer 管的）规则不同（s_nop 破坏可重启组但可出现在硬子句中间）。

**AMDGPUInsertDelayAlu**（gfx11+，EnableInsertDelayAlu，:2814-2816）：
- 目标：gfx11 VALU 结果延迟 4 cycle、TRANS 2 cycle、SALU 1 cycle（头注释 :19 "avoid stalls"）。`s_delay_alu` 是**提示性**指令：告诉硬件"下面第 skip 条指令前要等某类结果"，允许硬件早发射而非硬停。
- 状态模型 `DelayInfo`（:86-220）：每个 regunit 记 {VALUCycles 剩余周期, VALUNum 距今第几条 VALU, TRANSNum/TRANSNumVALU, SALUCycles}；VALU_MAX=5、TRANS 窗口、SALU_CYCLES_MAX 编码上限（:89-118）。`advance` 每条指令按发射周期数推进（:162-176）。
- 编码 `emitDelayAlu`（:276-345）：imm 低 4 位 = 第一等待槽（VALU 计数 / TRANS=4+n / SALU=8+n），高 8-10 位 = 第二等待槽 + skip 计数（:280-305）；**一条 s_delay_alu 两个槽，且能借上一条 s_delay_alu 的空槽 + skip 计数**（:313-337），S_SET_VGPR_MSB 会让 skip 计数不确定故禁用借槽（:318-323）。
- 块间 merge（:347-354：前驱 BlockState 取并）+ 两遍扫描（先 dry-run :607 再 emit :632，保证插入自身不破坏窗口计算）。
- `instructionWaitsForVALU`（:33-34）：遇 s_wait_alu 等全清 VALU 状态。

**动态验证**：见 §9.8.4（gfx1100 上 VALU 写后紧跟依赖读 → s_delay_alu valuen）。

**设计动机**：硬子句=用 1 条开销换成批 load 的 L1 标签/队列驻留；delay_alu=把"结构性 nop"降级为"可抢占提示"，NOP 是硬等待（占发射槽），s_delay_alu 让硬件在等待窗口内发不相关指令。

**昇腾映射（待验证）**：s_delay_alu ≙ 昇腾若有"软同步/依赖提示"类指令（仅 hint 不强制停），可同样做 regunit 级周期倒计数 + 双槽编码 + 借槽优化；若昇腾只有硬同步，则该优化退化为调度器内距离约束。【待验证】

## 9.7 SIShrinkInstructions（1146 行）与 SIPeepholeSDWA（1549 行）

**SIShrinkInstructions**（注意：挂载点不在 addPreEmitPass，而在 `addPreSched2`，AMDGPUTargetMachine.cpp:2767-2771，O>None）：
- 头注释（:12）："tries to use the 32-bit encoding"。VOP3（e64，8-16B）→ VOP1/VOP2（e32，4B）当且仅当：无字面量源（canShrink，SIInstrInfo）、sdst 为 VCC 或可置 NULL。
- 主循环 run()（:870-1128）：foldImmediates（:97，把 SGPR 立即数源折回）；VOPC/V_CNDMASK 先 setRegAllocationHint(VCC)（:1042-1055、:1067-1090——**RA 前跑一遍**给 RA 提示分 VCC，RA 后再跑一遍真正收缩）；commute 后再试（:1027-1038）；shrinkMadFma（:424，V_MAD/FMA → v_madak/v_madmk/fmaak 折立即数）；shrinkMIMG（:303，dmask 收缩）；shrinkScalarCompare（:247）；tryReplaceDeadSDST（:855，死 sdst → SGPR_NULL 保留收缩机会）。
- 动机：e32 是 VOP1/VOP2 原生编码，省编码长度=省 I$ 带宽与取指功耗；VCC hint 两段式是"RA 前给约束、RA 后收割"的经典配合。

**SIPeepholeSDWA**（SDWA = Sub-DWORD addressing；挂载在 addPreSched2 之前/SIPreAllocateWWM 之前的优化链，非 PreEmit——核对自 AMDGPUTargetMachine.cpp addMachineLateOptimizations/addPreSched2 区域）：
- 头注释（:17-29）示例：`V_LSHRREV(16) → V_ADD → V_LSHL(16)` 折叠成单条 `V_ADD_sdwa`（dst_sel:WORD_1, src0_sel:WORD_1）——移位进出对消失。
- 结构：SDWASrcOperand/SDWADstOperand/SDWADstPreserveOperand（:408/:573/:614）把 src/dst 的字节/半字选择建模为操作数属性，`canCombineSelections` 判兼容后 convertToSDWA 重写；`isConvertibleToSDWA`（:39/:1133）判候选。
- 动机：SDWA 在数据通路内做选择/掩码，消除显式 pack/unpack 指令序列。

**昇腾映射（待验证）**：编码收缩映射到昇腾"操作数复用/短格式指令选择"（如能选 16bit 立即数格式就不选长格式）；SDWA 类比昇腾向量指令的 sub-lane 选择（若有 stride/mask 操作数编码）。两者均为纯性能、无正确性风险。【待验证】

## 9.8 其余功能卡（简）

- **GCNCreateVOPD**（:2780-2782，gfx11 wave32）：头注释 :14-25——post-RA 调度器已把可配对 VALU 排邻，本 pass 检查最终物理寄存器约束（VOPD 两操作数的 src 必须满足编码限制），选不重叠对集，**先最大化对数、再最小化标量搬移**；VOPD3 不能编码 literal，若 pair 内非 inline 立即数同值则物化到一个空闲 SGPR（至多加一条 mov，不扩寄存器压力）。
- **SIMemoryLegalizer**（:2784）：AtomicOrdering → cache 控制指令。分代实现 SIGfx6/Gfx10/Gfx12CacheControl（:438/:500/:542 等类的 insertAcquire/insertRelease）：acquire → `s_waitcnt lgkmcnt(0)`+`buffer_wbinvl1_vol`（gfx6-9）/ GL0/GL1 invalidation（gfx10+）；release → `s_waitcnt vmcnt(0)`+`buffer_wbinvl1` 等；gfx12 用 S_WAIT_KMCNT + 更细粒度失效（:1982 注释 "Acquire sequences only need to wait on the previous atomic operation"）。头文件 DEBUG_TYPE="si-memory-legalizer"（:35）。与 waitcnt pass 的接口：legalizer 先插"soft" waitcnt，SIInsertWaitcnts 后续合并/替换（SIMemoryLegalizer.cpp:1357-1358、SIInsertWaitcnts.cpp 注释 :165-167 DeferredErasures 机制）。
- **SIPostRA16BitMovFolding**（:2785-2786，O>None）：RA 后把两条 `v_mov_b16`（lo/hi）合成一条 32-bit mov 或 SDWA 源选择（mergeSingleMovB16Pair :40）。RA 后做是因为要看物理寄存器是否相邻/同 32 位容器。
- **SILateBranchLowering**（:2794）：S_CBRANCH_SCC0/1 之外的 pseudo 展开（chain call :153-208 动态 VGPR 尾调用展开）；分支放最后是因为它生成多入口形态（对照 addPostBBSections 注释 :2774-2775 "avoid passes ... having to deal with the apparent multi-entry functions"）。
- **SIPreEmitPeephole**（:2799-2800，O>None）：optimizeVccBranch（:173，`s_cbranch_vccz` 前的 vcc 计算与 s_and 合并/化简）、removeExeczBranch（:501，exec 已知非零时删 `s_cbranch_execz`）、optimizeSetGPR（:357）、removeRedundantModeWrites（:540，与 SIModeRegister 衔接去重 setreg）、getBlockDestinations/mustRetainExeczBranch（:406/:463）。DEBUG_TYPE="si-pre-emit-peephole"（:31）。
- **AMDGPUWaitSGPRHazards**（:2811，gfx12）：头注释 :19 "Insert s_wait_alu instructions to mitigate SGPR read hazards on GFX12"。位集状态机：`SALUHazards<128>`（SGPR 上未提交的 SALU 写）+ VCCHazard {VALU,SALU}（:114-130）；SALU 写 SGPR 后，VALU 或 SALU 立即读该 SGPR 需 `s_wait_alu`（`WA_SALU`，:395-397）；VCC 特判（vcc 写后 s_cbranch 读，:331-334）。与 DelayAlu pass 同款两遍结构（dry-run :607 / emit :632）与块间 merge。
- **AMDGPULowerVGPREncoding**（:2812，gfx12.5）：头注释 :14-40——VGPR>255 时插 `S_SET_VGPR_MSB` 给 vdst/src0/src1/src2 提供地址高位（编码不变，v0 与 v256 编码同为 0x100 的设计）；约定非 fall-through 块入口 4 个 MSB 清零；**必须最后跑**（:40 "run very late ... no changes to VGPR operands after it"）——解释了它在管线中的位置（:2812，在 DelayAlu 之前、BranchRelaxation 之前）。
- **BranchRelaxation**（:2818，通用 CodeGen pass）：分支立即数偏移超出编码范围时把目标搬运/插入跳板块重写。放最后因为所有插指令的 pass 都可能把距离撑爆。

---

## 9.9 动态验证汇总

### 9.9.1 waitcnt：buffer_load → 立即消费（详见 §9.1.4）
gfx1100 `-debug-only=si-insert-waitcnts`：`s_waitcnt lgkmcnt(0)` / `s_waitcnt vmcnt(0)` 精确插入消费点前。

### 9.9.2 hazard：vcmpx → permlane（详见 §9.3.3）
`-run-pass=post-RA-hazard-rec` 跑 vcmpx-permlane-hazard.mir：跨基本块 hazard 被捕获，V_MOV（非 V_NOP）修复。

### 9.9.3 mode register：fptrunc 动态舍入
mode-register-fptrunc.mir 跑 `-run-pass=si-mode-register`：输出 `S_SETREG_IMM32_B32 1, 129/193/2177, implicit-def $mode`——FP_ROUND_MODE_DP 位段按 HwregEncoding 编码实测确认。

### 9.9.4 delay alu：gfx1100 依赖距离
gfx1100 乘加链输出 `s_delay_alu instid0(SALU_CYCLE_1) | instskip(NEXT) | instid1(SALU_CYCLE_1)`——**双槽 + 借槽编码实证**（一个 s_delay_alu 表达两条依赖）。

---

## 引用清单

| # | 文件:行号 | 内容 |
|---|---|---|
| 1 | AMDGPUTargetMachine.cpp:2779-2819 | addPreEmitPass 14 pass 管线 |
| 2 | AMDGPUTargetMachine.cpp:2802-2809 | PostRAHazardRecognizer 独立 pass 注释 |
| 3 | AMDGPUTargetMachine.cpp:2767-2771 | addPreSched2（SIShrinkInstructions 挂载点） |
| 4 | SIInsertWaitcnts.cpp:45 | DEBUG_TYPE "si-insert-waitcnts" |
| 5 | SIInsertWaitcnts.cpp:74-102 | VMEMID 编码（regunit+LDS DMA 槽） |
| 6 | SIInsertWaitcnts.cpp:117-122 | gfx12 计数器→S_WAIT_* 指令映射表 |
| 7 | SIInsertWaitcnts.cpp:149-154 | WaitcntGenerator 抽象动机（gfx12 变革） |
| 8 | SIInsertWaitcnts.cpp:250-268 | PreGFX12 事件→计数器掩码表 |
| 9 | SIInsertWaitcnts.cpp:284-286 | 无 VScnt 目标 LOAD_CNT 并入 store 事件 |
| 10 | SIInsertWaitcnts.cpp:295-316 | GFX12+ 事件→计数器掩码表 |
| 11 | SIInsertWaitcnts.cpp:479-831 | WaitcntBrackets 记分板数据结构 |
| 12 | SIInsertWaitcnts.cpp:474-478 | 混类事件乱序注释 |
| 13 | SIInsertWaitcnts.cpp:892-1108 | updateByEvent 生产侧记账 |
| 14 | SIInsertWaitcnts.cpp:1367+,1482-1497 | determineWaitForScore/determineWaitForPhysReg |
| 15 | SIInsertWaitcnts.cpp:1574-1611 | counterOutOfOrder |
| 16 | SIInsertWaitcnts.cpp:1656-1795 | applyPreexistingWaitcnt（PreGFX12） |
| 17 | SIInsertWaitcnts.cpp:1797-1893 | createNewWaitcnt（PreGFX12 合并编码） |
| 18 | SIInsertWaitcnts.cpp:2331-2634 | generateWaitcntInstBefore 消费侧查询 |
| 19 | SIInsertWaitcnts.cpp:2575-2577 | S_BARRIER 全零等待（对应文档） |
| 20 | SIInsertWaitcnts.cpp:3080-3186 | insertWaitcntInBlock 主循环 |
| 21 | SIInsertWaitcnts.cpp:3478-3595 | run() RPO 不动点 |
| 22 | AMDGPUWaitcntUtils.h:22-40 | InstCounterType 枚举 |
| 23 | AMDGPUWaitcntUtils.h:51-70,84-175 | HardwareLimits / Waitcnt 类 |
| 24 | GCNHazardRecognizer.h:36-73 | 类定义、OperatingMode、EmittedInstrs 窗口 |
| 25 | GCNHazardRecognizer.h:187-267 | check/fix 族声明全表 |
| 26 | GCNHazardRecognizer.cpp:542-639 | getHazardType 调度器入口 |
| 27 | GCNHazardRecognizer.cpp:725-772 | PreEmitNoopsCommon PreEmit 入口 |
| 28 | GCNHazardRecognizer.cpp:877-960 | hasHazard<StateT> 泛型跨块查询 |
| 29 | GCNHazardRecognizer.cpp:963-1012 | getWaitStatesSince 跨块逆向原语 |
| 30 | GCNHazardRecognizer.cpp:1115-1173 | checkSoftClauseHazards |
| 31 | GCNHazardRecognizer.cpp:1175-1221 | checkSMRDHazards（SI 读改写） |
| 32 | GCNHazardRecognizer.cpp:1223-1245 | checkVMEMHazards（VALU 写 SGPR 5 态） |
| 33 | GCNHazardRecognizer.cpp:1247+ | checkDPPHazards |
| 34 | GCNHazardRecognizer.cpp:1293-1316 | checkGetReg/SetRegHazards |
| 35 | GCNHazardRecognizer.cpp:1759-1787 | fixHazards 21 个 fixer 分发 |
| 36 | GCNHazardRecognizer.cpp:1796-1829 | fixVcmpxPermlaneHazards（V_MOV 修复） |
| 37 | GCNHazardRecognizer.cpp:1831-1875 | fixVMEMtoScalarWriteHazards（DEPCTR） |
| 38 | GCNHazardRecognizer.cpp:1877+ | fixSMEMtoVectorWriteHazards |
| 39 | GCNHazardRecognizer.cpp:2336-2420 | fixVALUTransUseHazard（TRANS 状态机） |
| 40 | GCNHazardRecognizer.cpp:341+,2657-2779 | WMMA co-exec 槽位/寄存器重叠/循环提升 |
| 41 | SIInstrInfo.cpp:10418-10446 | 三种 CreateTarget*HazardRecognizer 构造 |
| 42 | SIModeRegister.cpp:109-241 | Status 模型/insertSetreg/getInstructionMode |
| 43 | SIModeRegister.cpp:243-261,262-358 | Phase1 注释与实现 |
| 44 | SIModeRegister.cpp:360-419 | Phase2 前驱交集传播 |
| 45 | SIModeRegister.cpp:421-435 | Phase3 按需 setreg |
| 46 | SIModeRegister.cpp:450-458 | strictfp 跳过 |
| 47 | SIInsertHardClauses.cpp:15-33 | 硬子句头注释 |
| 48 | AMDGPUInsertDelayAlu.cpp:86-220 | DelayInfo 状态模型 |
| 49 | AMDGPUInsertDelayAlu.cpp:276-345 | emitDelayAlu 双槽编码+借槽 |
| 50 | AMDGPUInsertDelayAlu.cpp:347-354,607,632 | 块间 merge、两遍扫描 |
| 51 | SIShrinkInstructions.cpp:870-1128 | run() 主循环（VCC hint 两段式） |
| 52 | SIPeepholeSDWA.cpp:17-29 | SDWA 折叠示例头注释 |
| 53 | SIMemoryLegalizer.cpp:35,1357-1358,1982 | DEBUG_TYPE、与 waitcnt 的 soft 接口 |
| 54 | AMDGPUWaitSGPRHazards.cpp:19,114-130,395-397 | s_wait_alu 位集状态机 |
| 55 | AMDGPULowerVGPREncoding.cpp:14-40 | S_SET_VGPR_MSB 约定（必须最后跑） |
| 56 | GCNCreateVOPD.cpp:14-25 | VOPD 配对贪心头注释 |
| 57 | docs/AMDGPUExecutionSynchronization.md:204-282 | GFX6-11 s_barrier 序列（vmcnt/expcnt/lgkmcnt/vscnt 全零） |
| 58 | docs/AMDGPUExecutionSynchronization.md:268-273 | "计数器须为 0，waitcnt 可前移/删除" |
| 59 | docs/AMDGPUExecutionSynchronization.md:284-289 | GFX12 split barrier |
