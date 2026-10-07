# §5 AMDGPU PreISel 结构化控制流链深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，本仓库工作区实测（build-debug, gfx1100）。
> 引用格式 `文件:行号`；标注"实测素材：scratch/xxx"的是子代理/主会话已跑过的实验输出。
> 素材来源：子代理调研（引用已核实）+ scratch 实测存档。

---

## 5.1 这一层在做什么

GCN 硬件分支语义与 LLVM IR 任意 CFG 之间的鸿沟，由 addPreISel 的 11 个 pass 填平：

```
FlattenCFG → Sinking → LateCodeGenPrepare          (OptLevel>None, :2487-2491)
→ UnifyDivergentExitNodes → FixIrreducible → UnifyLoopExits
→ StructurizeCFG                                    (:2496-2499)
→ AnnotateUniformValues → SIAnnotateControlFlow     (:2501-2503)
→ RewriteUndefForPHI                                (:2508)
→ (条件 LCSSA)                                      (:2510-2513)
→ PerfHintAnalysis                                  (:2515-2518, OptLevel>Less)
```

（`AMDGPUTargetMachine.cpp:2485-2519`，legacy 版已逐行核对；新 PM 版语义相同）

**核心命题的因果论证链**：

1. **GCN 分支只有两种形态**：uniform 分支走 `s_cbranch_scc*`（谓词在 SALU 的 SCC 位）；divergent 分支没有"分支"——只有 exec mask 的与/或/保存/恢复。`SILowerControlFlow.cpp:11-50` 头注释完整给出 `llvm.amdgcn.if` → `S_AND_SAVEEXEC_B64 + S_XOR_B64 + S_CBRANCH_EXECZ` 的展开。
2. **divergent 分支的 reconvergence 契约**：exec-mask 模式下，两个 divergent 路径的汇合点必须是一个**可被硬件识别的结构化点**（嵌套 if/else 的闭括号，或循环 header）。irreducible CFG（两个入口互相进入的循环）没有这样的点——硬件无法知道"何时所有 lane 都回来了"。
3. **ISel 的判定条件**（`AMDGPUISelDAGToDAG.cpp:2904`）：`UseSCCBr = isCBranchSCC(N) && isUniformBr(N)`——只有 uniform 分支才走 s_cbranch；divergent 一律 exec-mask 路径。**所以 ISel 之前，CFG 必须已被整形成"if/else + 循环"的嵌套树**。

### 顺序为什么不能换

| 顺序约束 | 原因 |
|---|---|
| UnifyDivergentExitNodes 在 FixIrreducible 前 | divergent 多出口块会形成"伪 irreducible"区域；先统一出口，FixIrreducible 才能正确识别真正的 irreducible 子图 |
| FixIrreducible 在 StructurizeCFG 前 | StructurizeCFG 的算法假设输入是可归约图（SCC→循环的直接映射）；irreducible 必须先重构为可归约 |
| UnifyLoopExits 在 StructurizeCFG 前 | 注释原文（:2493-2494）："Merge divergent exit nodes. **StructurizeCFG won't recognize the multi-exit regions formed by them**" |
| AnnotateUniformValues 在 SIAnnotateControlFlow 前 | 后者注入的 intrinsic 会引入新的控制流语义，标注必须在"干净"的 IR 上做 |
| RewriteUndefForPHI 在 SIAnnotateControlFlow 后 | 它的 Pattern A/B 重写依赖 SIA split 过的 loop header（`RewriteUndefForPHI.cpp:9-52` 头注释明确） |
| TODO 痕迹（:2505-2507） | 注释承认 RewriteUndefForPHI 理想位置是 StructurizeCFG 之后（省一次 divergence analysis），受限于 SIA 会改 CFG——**流水线顺序约束的活样本** |

---

## 5.2 逐 pass 功能卡

### StructurizeCFG（llvm/lib/Transforms/Scalar/StructurizeCFG.cpp，1497 行）

**注意：它在 Transforms/Scalar 而非 Target/AMDGPU 下**——通用 pass，AMDGPU 是主要（几乎唯一）消费者。

- **做什么**：任意可归约 CFG → "if/else + loop" 嵌套树
- **主算法**（`run` :1395）：`orderNodes`（:501，SCC 拓扑排序，**保证内层 cycle 节点相邻**）→ `analyzeLoops`（:555）→ `createFlow/wireFlow`（:1164/:1235）→ `handleLoops`（:1201）→ `insertConditions` ×2 → `setPhiValues` → simplify → rebuildSSA
- **头注释** :230-275 给出目标形态的完整定义
- **Uniform region 逃生门**：`makeUniformRegion`（:1359）+ `structurizecfg.uniform` metadata（:1370）——纯 uniform 的区域跳过结构化（保留原始 CFG 给 s_cbranch 用）。**这是"结构化只为 divergent 服务"的直接证据**
- **实测**（scratch/struct_after.txt）：irreducible 用例被转换后出现 `Flow`/`Flow1` 新块 + `poison` 占位 phi，最终由 insertConditions 填充

### UnifyDivergentExitNodes（AMDGPUUnifyDivergentExitNodes.cpp，374 行）

- **做什么**：divergent 出口块统一到 UnifiedReturnBlock
- `isUniformlyReached`（:120-134）判定；`unifyReturnBlockSet`（:136-181）
- **诚实注释**（:246-248）：TODO 承认"连 uniform exit 也统一是 structurizer 的 workaround"——UDE 自认是 StructurizeCFG 的补丁而非独立价值
- `HasDivergentExitBlock` 判定（:249-251）
- **实测**（scratch/ude_after.txt）：UnifiedReturnBlock 收三个入边 phi 合一

### FixIrreducibleCFG（llvm/lib/Transforms/Utils/FixIrreducible.cpp，468 行）

- **做什么**：irreducible 循环 → 引入新 header N 重定向所有外部入边
- **头注释 :9-112 含完整 ASCII 图**（H↔B 双 header → 新 header N）；经 ControlFlowHub（:281）重定向
- **实测**（scratch/fixirr_before_after.txt）：出现 `irr.guard`/`Guard.B` 新块，PHI moved + poison

### UnifyLoopExits（llvm/lib/Transforms/Utils/UnifyLoopExits.cpp，320 行）

- 循环多出口 → 单一出口分发块；SSA 修复注释 :83-90；ControlFlowHub :167
- 与 UDE 的分工：UDE 管**函数级**出口，ULE 管**循环级**出口——两级出口都必须先归一，StructurizeCFG 才能认出规范的循环区域

### AMDGPUAnnotateUniformValues（151 行）

- **做什么**：给 value/terminator 打 `amdgpu.uniform` 标注（:38-41）；load 再加 `amdgpu.noclobber`（:62-83）
- **消费端全景**（标注的价值在下游）：
  - `AMDGPUISelDAGToDAG.cpp:922-927`：isUniformBr **同时查 amdgpu.uniform 和 structurizecfg.uniform**（两个 metadata 在这里合流）
  - `AMDGPUInstrInfo.cpp:29-53`：isUniformMMO（memory access 的 uniformity → SMEM 路径）
  - `AMDGPUInstructionSelector.cpp:3112`：GISel 路径同款消费
- **实测**（scratch/uniform_exit.s）：kernel 参数分支直接 `s_cmp_lt_i32 s2,6 + s_cbranch_scc1`，**零 exec 操作**；对照 scratch/simple_if.s：divergent if 走 `v_cmpx_ne_u32_e32`（直写 EXEC）+ `s_xor/s_and_not1_saveexec/s_or`

### SIAnnotateControlFlow（455 行）

- **做什么**：把结构化 CFG 的控制流语义注入 IR intrinsic，供 SILowerControlFlow（机器层）展开
- 五个 intrinsic（:56-60）：`amdgcn.if / else /endif / loop / if_break / end_cf`；IntMask 类型 wave32?i32:i64（:118-119）
- `openIf`（:178-191）注入 `llvm.amdgcn.if` 返回 `{i1, mask}`；`insertElse`（:194-208）；`handleLoop`（:254-293）= phi.broken + `amdgcn_if_break` + `amdgcn_loop`；`closeControlFlow`（:295-336）= `amdgcn_end_cf`，**循环 header 需 split 出 "endcf.split" 块**
- `run`（:341-382）：处理完栈必须为空，否则 `report_fatal_error("failed to annotate CFG")`——结构化不变量的运行时断言
- intrinsic 定义：`IntrinsicsAMDGPU.td:3990-4011`
- **实测**：scratch/si_ann.txt（IR 层 if/else/end.cf intrinsic + 条件反转）；scratch/irr_annotated.mir（机器层 if_break/loop/end.cf 完整注入后的 MIR）

### RewriteUndefForPHI（192 行）

- **做什么**：结构化引入的 `phi [undef, ...]` 在 SILowerControlFlow 后会变成 exec-mask 操作数（undef 语义在 mask 传播中不安全），提前重写为具体值
- Pattern A/B 完整定义在头注释 :9-52；**明确只能跑在 SIAnnotateControlFlow 之后**（依赖其 split loop header）
- **实测**（scratch/undef_phi.ll + all.txt:965 索引）：`%phi = phi [%n.load, %entry], [undef, %then]` 被消解，store 直接用 `%n.load`——Pattern B 重写成功

### PerfHintAnalysis（492 行）

- **做什么**：函数级性能画像 → fn attribute → **跨层流向调度器**
- 阈值（:37-52）：MemBound 50% / LimitWave 50% / IAWeight 1000；`visit`（:215-283）、`isMemBound`（:318-325）、`needLimitWave`（:327-330）、写 attr（:301-312）
- **完整消费链**（这是"IR 层信息穿透到机器层调度"的范本）：
  ```
  PerfHint 写 "amdgpu-memory-bound" fn attr
    → AMDGPUMachineFunctionInfo.cpp:54-56 读入
    → SIMachineFunctionInfo.h:1213-1218 getMinAllowedOccupancy()（memoryBound 则 min(occ,4)）
    → 消费者：GCNSchedStrategy.cpp:157,1026 / GCNIterativeScheduler.cpp:507,602
             / SIFormMemoryClauses.cpp:211 / AMDGPUAsmPrinter.cpp:1071（打印 WaveLimiterHint）
  ```

### FlattenCFG / Sinking / LateCodeGenPrepare（:2487-2491）

OptLevel>None 才跑的三个前处理：条件折叠简化、下沉、AMDGPU 版 CGP（处理非 kernel 函数的地址空间修复）。all.txt 实测索引：flattencfg 在 :762。

---

## 5.3 LCSSA 条件化之谜（考古结论）

**现状**（:2510-2513）：LCSSA 只在 SDAG 路径插入，GISel 路径跳过。

**git 考古**（已完成）：
- 引入 commit：**`3ad810ea9a97`** "[AMDGPU/GlobalISel] Disable LCSSA pass (#124297)"（Petar Avramovic，2025-03-12）
- 原注释："**SDAG requires LCSSA, GlobalISel does not.** Disable LCSSA for -global-isel with -new-reg-bank-select and without any of the fallback options"
- 动机：为 amdgpu divergence lowering 的 **temporal divergence** 做准备——LCSSA phi 会破坏 SGPR/i1 跨 cycle 的使用模式
- 后续 `192ef559fbfe`（NewRegBankSelect 默认开启）删掉 `!NewRegBankSelect` 条件；`bf18f6f43052`/`eb7ce80944ee`/`6b183f4cfdb4` 为纯重构

**含义**：LCSSA 是 SDAG ISel 的历史包袱（DAG 化要求 def-dom-use 的严格形态），GISel 的 IR-based 选择器不需要。**这是"双路径并存"策略的可见收益：新路径甩掉了老路径的兼容性约束。**

---

## 5.4 与 NVPTX 的对照

`NVPTXTargetMachine.cpp` 无 addPreISel；`NVPTXCodeGenPassBuilder.cpp:175-216` 的 addIRPasses 全列表零结构化 pass。ptxas 接受任意 CFG（PTX 是虚拟 ISA，reconvergence 是 ptxas/硬件的事）。

**这一层 11 个 pass（约 4,000+ 行目标代码 + 2,285 行通用 StructurizeCFG/FixIrreducible/UnifyLoopExits）纯粹是"物理 ISA 后端"的代价**。NVPTX 把同样的复杂度外包给了 ptxas 的内部实现。

---

## 5.5 昇腾映射（推理级，标注待验证）

⚠️ davinci ISA 细节未在本会话核查（基于 CCE/PyPTO 经验推理）：

1. **davinci 无 wave 级 exec-mask reconvergence 契约**：CCE 的控制流是标量单元驱动的顺序模型（if/else/for），vector 内部 lane 无独立路径概念——所以 CCE **不需要** StructurizeCFG 族。这不是"CCE 更先进"，而是编程模型不同（SIMT vs 标量驱动的 vector）。
2. **但 uniform/divergent 判定有对应物**：昇腾侧"scalar 寄存器可用的条件"≈ AMDGPU 的 uniform 判定（`isUniformBr` → s_cbranch ≈ 标量单元分支 vs 向量 predication）。PyPTO 若暴露 per-lane 掩码操作（如 TopK 的 mask），编译/框架层需要同样的静态 uniformity 分析。
3. **PerfHint 的跨层流向是可直接借鉴的架构**："IR 层画像 → fn attr → MachineFunctionInfo → 调度器 occupancy 下限"——PyPTO 的 tile 级 profile（访存密度/计算密度）若要影响调度决策，这条管道是现成模板（无需发明新的跨层机制）。
4. **结构化不变量的断言模式**：SIA 的 `report_fatal_error("failed to annotate CFG")` 是"结构不变量在编译期强制检查"的范本——PyPTO 的 tile 依赖图（MTE2→S 管线读 UB）也可以做编译期不变量断言，把"运行时才炸的同步 bug"前移成编译错误。

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| AMDGPUTargetMachine.cpp:2485-2519 | addPreISel 全链 + 顺序注释 |
| AMDGPUTargetMachine.cpp:2493-2494, 2505-2507 | 关键注释原文 |
| SILowerControlFlow.cpp:11-50 | exec mask 展开头注释 |
| AMDGPUISelDAGToDAG.cpp:2904, 922-927 | UseSCCBr / isUniformBr 消费 |
| StructurizeCFG.cpp:230-275, 501, 555, 1164, 1201, 1235, 1359, 1370, 1395 | 主算法 |
| AMDGPUUnifyDivergentExitNodes.cpp:13-19, 120-181, 230-251 | UDE |
| FixIrreducible.cpp:9-112, 281 | irreducible 重构 |
| UnifyLoopExits.cpp:9-16, 83-90, 167 | ULE |
| AMDGPUAnnotateUniformValues.cpp:38-83 | uniform 标注 |
| AMDGPUInstrInfo.cpp:29-53 / AMDGPUInstructionSelector.cpp:3112 | 下游消费 |
| SIAnnotateControlFlow.cpp:56-60, 118-119, 178-208, 254-293, 295-336, 341-382 | intrinsic 注入 |
| IntrinsicsAMDGPU.td:3990-4011 | intrinsic 定义 |
| RewriteUndefForPHI.cpp:9-52 | Pattern A/B |
| PerfHintAnalysis.cpp:37-52, 215-283, 301-330 | PerfHint |
| AMDGPUMachineFunctionInfo.cpp:54-56 / SIMachineFunctionInfo.h:1213-1218 | attr 流入 |
| GCNSchedStrategy.cpp:157,1026 / GCNIterativeScheduler.cpp:507,602 / SIFormMemoryClauses.cpp:211 / AMDGPUAsmPrinter.cpp:1071 | 调度消费 |
| git: 3ad810ea9a97 / 192ef559fbfe / bf18f6f43052 / eb7ce80944ee / 6b183f4cfdb4 | LCSSA 考古 |
| NVPTXTargetMachine.cpp / NVPTXCodeGenPassBuilder.cpp:175-216 | 对照 |

实测素材索引（scratch/）：irreducible.ll → irr_struct.mir（结构化后）/ irr_annotated.mir（SIA 注入后）/ irreducible.s（最终 asm：单 header 循环 + s_and_saveexec）；fixirr_before_after.txt；struct_after.txt；ude_after.txt；si_ann.txt；uniform_exit.s vs simple_if.s（uniform/divergent 分支对照）；undef_phi.ll（RewriteUndefForPHI）；all.txt（全流水线 IR dump：flattencfg:762 / ude:825 / fix-irreducible:846 / unify-loop-exits:867 / structurizecfg:888 / annotate-uniform:919 / si-annotate:940 / rewrite-undef:965 / lcssa:1013）。
