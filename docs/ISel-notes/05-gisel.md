# §7 GlobalISel 正交流水深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，build-debug 实测（AArch64, -global-isel）。
> 引用格式 `文件:行号`；实测素材 `ISel-notes/scratch/builder_test.ll`（G_ dump）、/tmp/p8.ll（legalizer 后 i8→i32）。
> 素材来源：子代理调研（引用已核实，两处任务前提修正）+ 主会话补动态验证代写。

**两处任务前提修正**（子代理证伪）：
1. LegalizerInfo per-opcode 不是 `std::array<LegalizeRule,NumActions>`——实为 `RulesForOpcode[LastOp-FirstOp+1]` 每项 SmallVector<LegalizeRule,2>
2. RegBankSelect 现役模式是 **Fast vs Greedy**（不存在"完全/全局迭代"模式），两模式均逐指令

---

## 7.1 IRTranslator（5,426 行，类名 IRTranslatorImpl :111）

- **分发**：translate() :4738，HANDLE_INST 宏生成 switch→translate##OPCODE（:4746-4753）；前置 **TLI->fallBackToDAGISel(Inst)** :4743——**指令级 fallback 出口在翻译入口**；**55 个 translateXXX**（grep 计数，对照 SDAG Builder 146 visit）
- **常量**：translate(Constant&,Reg) :4756——ConstantInt→G_CONSTANT（向量先退化标量 splat :4762-4766）；CAZ→buildSplatBuildVector :4786-4797；ConstantDataVector→逐元素 G_BUILD_VECTOR :4798-4807；ConstantExpr 递归同一宏 switch :4808-4816
- **alloca**：静态→getOrCreateFrameIndex+G_FRAME_INDEX :4032-4036；动态→G_DYN_STACKALLOC（G_MUL/G_ADD/G_AND 对齐链 :4043-4082）
- **PHI**：translatePHI :4445 先建无操作数 G_PHI 入 PendingPHIs；**finishPendingPhis :4600-4632 全函数翻译完回填**（use,MBB）对（MachinePreds 处理 IR 块→多 MBB）；:5329 调用——**G_MIR 保留 phi**（MIR SSA 有 phi 能力，与 SDAG 的"无 phi+CopyToReg 边界"根本差异）
- **向量**：insert/extract :4112/:4192（`<1 x Ty>`→copy；索引归一到 TLI->getVectorIdxWidth :4123）；shuffle :4269（scalable→splat 元素0 :4275；DstElts==1→extract :4295；一般→G_SHUFFLE_VECTOR+allocateShuffleMask :4336）
- **主流程** runOnMachineFunction :5110：独立 EntryBB 放参数/常量 :5197、RPOT 遍历 :5270、**CSE 默认开**（CSEMIRBuilder :5135-5147）
- **G_\* 集规模**：GenericOpcodes.td **283 个 `def G_`**；GenericInstruction 置 isPreISelOpcode=true（:19-24）

## 7.2 Legalizer：谓词化的核心

- 驱动 legalizeMachineFunction :179：**双 worklist**（Inst/Artifact :119-120）；**do-while 两阶段循环** :226-307——InstList 主 legalize→UnableToLegalize 的 artifact 进 RetryList :244-257→有新 artifact 才重试 :267-276→ArtifactCombiner 阶段 :278-306（未 combine 的降级回 InstList）
- isArtifact :101（TRUNC/ext/MERGE/UNMERGE/CONCAT/BUILD_VECTOR/EXTRACT；G_INSERT 是 AMDGPU hack 开关 :47-51）
- **谓词化**：`LegalityPredicate=std::function<bool(LegalityQuery&)>` :162；**组合器模板 all/any/predNot（变参）** :190-218；谓词工厂 typeIs/isScalar/elementTypeIs/immIs（LegalityPredicates.cpp :28/:78/:110/:253 全 lambda 工厂）——**可组合谓词 vs SDAG if-else 海的对照核心**
- LegalizeRule{Predicate,Action,Mutation} :400-423；RulesForOpcode 数组 :1428（每项 SmallVector<LegalizeRule,2>）；apply 按序首匹配（:194-212，附 mutationIsSane/hasNoSimpleLoops 调试断言）
- LegalizeActionStep{Action,TypeIdx,NewType} :144-160；**10+1 个 Action 枚举** :44-94；getAction(MI,MRI) 从 MCOperandInfo 泛型类型索引组装 query :347-376；多 opcode 共享 ruleset 别名 :1360-1374
- legalizeInstrStep（LegalizerHelper.cpp:122）：intrinsic 先 legalizeIntrinsic，再 switch 分派 10 动作

## 7.3 Combiner：规则外挂 + 观察者协议

- 驱动 combineMachineInstrs :252：**外层定点迭代**（MaxIterations）:273-333；worklist post_order×reverse 填充（弹出=RPOT 序）:294-304；tryCombineAll 为生成入口 :312
- **WorkListMaintainer** :52：GISelChangeObserver 子类，模板化 ObserverLevel（Basic/DCE/SinglePass :83）；appliedCombine 延迟 DCE+用户回填 :149-186
- **观察者协议**（GISelChangeObserver.h）：4 事件 erasing/created/changing/changed（:36-50）+ changingAllUsesOfReg；GISelObserverWrapper 同时是 MachineFunction::Delegate（MF_HandleInsertion→createdInstr :106-108）——**可观测编辑 vs SDAG RAUW**：SDAG 的节点替换对外的唯一痕迹是 use list 更新，GISel 把每次编辑事件化
- **规则外挂**：AArch64Combine.td `GICombineRule<(defs root:$root, matchinfo)>,(match…C++谓词…),(apply…C++…)>`（:14-18 icmp_redundant_trunc 范例；wip_match_opcode 逃生口 :24；GIDefMatchData :21）；GICombiner 聚合命名规则含 all_combines :79-97；生成器 utils/TableGen/GlobalISelCombinerEmitter.cpp
- **CombinerHelper.cpp 8,707 行：159 bool 方法（133 match + 57 apply）**——对照 SDAG 146 visit 的规则密度
- CSEMIRBuilder :178 buildInstr：先常量折叠（G_ICMP :185、整数 binop 列表 :201-241）再 FoldingSet 查表（MBB 局部 CSE :110-111）；**命中但不支配则 splice** :51-57

## 7.4 RegBankSelect：Fast vs Greedy

- 模式：`regbankselect-fast`/`regbankselect-greedy` cl::opt :65-70——**均逐指令**，全局性仅体现在 RPOT 保证先定义后使用（:1312-1314）
- assignInstr :1255：G_ASSERT_* 直接取源 bank :1261-1276；Fast→仅 getInstrMapping 默认映射（:1282-1288，cost 只判可行性）；Greedy→getInstrPossibleMappings+findBestMapping :1289-1296
- **MappingCost** :430-492：Local/NonLocal/LocalFreq 三分量（非局部预乘频率避免饱和 :425-429）；ImpossibleCost=全 UINT64_MAX :1648
- **InsertPoint 惰性物化**（可拆边/块）:96-196；RepairingPlacement Reassign/Insert/Impossible（applyMapping :1220-1238）；RBI->applyMapping :1250 为 target 重写钩子

## 7.5 InstructionSelect + GIMatchTableExecutor（子代理未及，主会话补骨架）

- InstructionSelect.cpp 440 行：select 段驱动（selectAll/指纹缓存 constrained 简化）；selectImpl 调用 target 的 InstructionSelector（表执行）
- GIMatchTableExecutor（cpp 96 + h 799）：GISel 版 matcher 表执行器——**与 SDAG SelectCodeCommon 的结构对照**：同为 TableGen 生成表解释执行，但表格式面向 MIR（操作数/bank 谓词）而非 DAG 节点；selectImpl 失败→setFailedISel→fallback 链（NVPTX-notes/04 §6.5 已析）

## 7.6 动态验证（实测）

**-stop-after=irtranslator**（builder_test.ll，AArch64 -global-isel）：
```
%3:_(i32) = G_CONSTANT i32 0
%2:_(p0) = G_FRAME_INDEX %stack.0.buf        ← alloca→G_FRAME_INDEX
G_STORE %0(i32), %2(p0) :: (store (i32)...)
%4:_(i1) = G_ICMP intpred(sgt), %1, %3
G_BRCOND %4(i1), %bb.2 / G_BR %bb.4
%5:_(i32) = G_PHI %8, %bb.3, %3, %bb.2       ← G_PHI 保留（vs SDAG 无 phi）
```
**-stop-after=legalizer**（p8.ll，i8 算术）：`%8:_(i32) = G_ADD %2, %3`——**i8 已提升为 i32**（G_ADD 直接合法类型）。

## 7.7 昇腾映射（推理级，待验证）

**PyPTO tile 选择借鉴 GISel 正交化**：
1. **谓词表 vs custom hook**：tile 合法化规则用 LegalityPredicate 式组合器（all/any/elementTypeIs）而非 SDAG 式散布 if-else——规则可组合可测试可枚举
2. **GICombineRule 声明式规则**：(match C++谓词)+(apply C++) 的 td 化——tile 优化规则声明式化是规模控制出路（对照 §5.6 的 146 visit 教训）
3. **观察者协议**：tile DAG/MIR 编辑的事件化（erasing/created/changed）——增量分析（如 tile 活跃区间）可挂观察者而非全量重算
4. **两阶段 worklist（Inst/Artifact）**：tile 的"派生值"（如 splat 后的 tile）可用 artifact 机制延迟处理

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| IRTranslator.cpp:111, 4032-4082, 4112-4336, 4445, 4600-4632, 4738-4816, 5110-5329 | translate 全链 |
| GenericOpcodes.td:19-24, 118, 169, 1592, 1772 | 283 G_* |
| Legalizer.cpp:47-51, 101-307 | 双 worklist 驱动 |
| LegalizerInfo.h:44-160, 162-218, 400-423, 1428 / LegalizerInfo.cpp:194-212, 347-376, 1360-1374 | 谓词化 |
| LegalityPredicates.cpp:28-253 / LegalizeMutations.cpp:17-119 | 工厂 |
| Combiner.cpp:52-186, 252-333 / GISelChangeObserver.h:36-108 | 观察者 |
| CombinerHelper.cpp（159 方法） | 规则密度 |
| AArch64Combine.td:14-97 / GlobalISelCombinerEmitter.cpp | 规则外挂 |
| CSEMIRBuilder.cpp:51-241 | CSE |
| RegBankSelect.cpp:65-70, 96-196, 430-492, 1053, 1220-1314, 1648 | Fast/Greedy |

实测素材：scratch/builder_test.ll（G_ 前缀 dump：G_PHI/G_FRAME_INDEX/G_BRCOND）、/tmp/p8.ll（i8→i32 legalizer 实证）。
