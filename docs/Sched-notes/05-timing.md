# §6+§7 素材：三时点分工与专项调度器（LLVM main @ 3eda2aebadd4）

> 引用纪律：所有 文件:行号 均经 grep/read 核对（2026-09-30，build-debug llc 24.0.0git）。
> 前置：Pre-RA MISched 骨架见 02-skeleton，策略谱系见 03-policy §4.4，不重复。

## 三时点总览

| 时点 | 载体 | IR 形态 | 核心约束 | 挂载方式 |
|---|---|---|---|---|
| Source-level | ScheduleDAGSDNodes（SelectionDAG/） | SDNode（选择后 MI 尚未生成） | 数据链/拓扑 | ISel 末尾内联，非独立 pass |
| Pre-RA | MachineScheduler | MI + 虚拟 reg | 寄存器压力 + 延迟 | 独立 pass（addMachineSSA） |
| Post-RA | PostRASchedulerList / PostMachineScheduler | MI + 物理 reg | anti-dep + itinerary 冒险 | 独立 pass（"Second pass scheduler"） |

## 6.1 PostRASchedulerList（721 行，lib/CodeGen/PostRASchedulerList.cpp）

### 静态分析
- DEBUG_TYPE "post-RA-sched"（:46）；类 SchedulePostRATDList : ScheduleDAGInstrs（:116）。**自顶向下**列表调度（:9-12 头注释），与 Pre-RA MISched 的双向收敛（Converging）相对。
- 核心差异 vs Pre-RA MISched：
  1. **无寄存器压力概念**：required property NoVRegs（:108-110，物理 reg 已定）；跨 call 不再是调度边界顾虑——"post-ra we don't gain anything by scheduling across calls since we don't need to worry about register pressure"（:326-329）。
  2. **物理 reg anti-dep 破坏**：AntiDepBreak 成员（:131），构造时按 target 的 AntiDepBreakMode 三选一：ANTIDEP_ALL→Aggressive / ANTIDEP_CRITICAL→Critical / nullptr（:227-231）；anti-dep 破坏要求 tracksLiveness（:224-226 assert）。
  3. **冒险模型 = Itinerary**：CreateTargetPostRAHazardRecognizer(InstrItins, this)（:219-221），非 MISched 的 SchedModel/ProcResource。可插 noop（emitNoop :535-540，Sequence 里 nullptr 即 noop :538）、stall 计数 NumStalls/NumNoops（:48-50）——服务无互锁流水线。
  4. 可定制点收窄：仅 getPostRAMutations（:222；TargetSubtargetInfo.h:307-309）+ overridePostRASchedPolicy（TargetSubtargetInfo.h:278-279，注明压力选项在 post-RA 无效）。
- 驱动循环（列表调度的 post-RA 版）：
  - 外层：逐 MBB 逆序切 region（call/isSchedulingBoundary 为界，:321-342）；边界指令经 Observe() 喂给 AntiDepBreaker 维持活跃信息（:448-451）。
  - schedule()（:412-443）：buildSchedGraph → AntiDepBreak->BreakAntiDependencies（:416-419）→ 若 Broken≠0 则 **clearDAG+重建图**（:421-432，重命名改变依赖结构）→ postProcessDAG → ListScheduleTopDown。
  - ListScheduleTopDown（:544-687）：PendingQueue（深度未到 CurCycle）→ AvailableQueue（LatencyPriorityQueue，:119）；每 cycle 弹最高优先级节点，HazardRec->getHazardType 检查（:596-598），ShouldPreferAnother 延后非优选（:599-607），PreEmitNoops/atIssueLimit（:644-658）；无指令可发则 stall 或 noop（:659-678）。
  - EmitSchedule splice 回 BB + TII->insertNoop（:690-721）；fixupKills 修 kill 标记（:356）。
- 启用条件：enablePostRAScheduler()（:270-278）= cl 覆盖 `-post-RA-scheduler`，否则 `ST.enablePostRAScheduler() && OptLevel >= ST.getOptLevelToEnablePostRAScheduler()`。基类实现查询 SchedModel 的 **PostRAScheduler 位**（TargetSubtargetInfo.cpp:64-66；默认 opt 门槛 Default，TargetSubtargetInfo.h:323-325）。
- Pass 挂载：TargetPassConfig.cpp:1218-1227——OptLevel≠None 且 target 未自管（targetSchedulesPostRAScheduling）时，`-misched-postra` 选 PostMachineSchedulerID，否则 PostRASchedulerID（"Second pass scheduler"，位于 ExpandPostRAPseudos/addPreSched2 之后、BlockPlacement 之前）。
- Target 现状（grep lib/Target）：override enablePostRAScheduler 的有 AArch64（AArch64Subtarget.h:161，feature use-postra-scheduler，AArch64Features.td:764-765；cortex-a53/a510/thunderx2/a64fx 等 .td 均 PostRAScheduler=1，如 AArch64SchedA53.td:23 附近、A510:24）、ARM（ARMSubtarget.h:445）、Mips（MipsSubtarget.h:234）、RISCV（RISCVSubtarget.h:162）、Hexagon（:324 直接 true）、PPC（PPCSubtarget.cpp:163 强制 true 覆盖 .td）。
- **关键分流（本节最重要结论）**：AArch64PassConfig 构造函数在 OptLevel≠None 时 `substitutePass(&PostRASchedulerID, &PostMachineSchedulerID)`（AArch64TargetMachine.cpp:594-595）——AArch64 的 post-RA 槽位实际运行的是 MISched 的 post-RA 变体（enablePostRAMachineScheduler = enableMachineScheduler && enablePostRAScheduler，TargetSubtargetInfo.cpp:68-70），legacy 列表调度器+AntiDepBreaker 路线在 AArch64 上不执行。

### 动态验证（AArch64）
- 命令：`./build-debug/bin/llc -O2 -debug-only=post-RA-sched -mtriple=aarch64 -mcpu=cortex-a53 scratch/antidep.ll -o /dev/null`（-O3/loop.ll 同）：**输出为空，exit 0**（双次确认）。
- 解读：与 :594-595 的 pass 替换完全一致——AArch64 上 "post-RA-sched" 调试通道静默，post-RA 调度日志在 `-debug-only=machine-scheduler` 下。**如实记录：本 build 未含 X86/PPC target（llc --version 仅 aarch64/amdgpu/nvptx 系），anti-dep break 日志（"Breaking anti-dependence edge on..."，CriticalAntiDepBreaker.cpp:647-650）无法在本机复现，需 X86/PPC build。**

### 设计动机
RA 之后的重排不受压力牵制，可纯粹按延迟/冒险优化；代价是物理寄存器重定义产生的 WAR（anti）依赖成为最大束缚（见 6.2），且 kill 标记/ABI 寄存器不可乱动，因此动作收敛为：破 anti-dep → 冒险识别驱动的小范围重排。

### 昇腾映射（推理级，待验证）
PyPTO 若在 UB（UnifiedBuffer）绑定之后还有指令级重排 pass，即 post-RA 类比位：此时 slot 已定，tile 间缓冲复用产生的 WAR 依赖是重排的主要束缚；若无"换 slot"机制（AntiDepBreaker 类比），post-绑定重排的收益天然受限。

## 6.2 AntiDepBreaker：post-RA 重命名消除 anti-dep

### 静态分析
- 接口（include/llvm/CodeGen/AntiDepBreaker.h）："works in conjunction with the post-RA scheduler to rename registers to break register anti-dependencies (WAR hazards)"（:29-31）；StartBlock/BreakAntiDependencies/Observe/FinishBlock 四阶段（:39-55）+ DBG_VALUE 重命名跟随 UpdateDbgValue(s)（:59-90）；工厂 createAggressive/createCritical（:93-99）。
- **为什么 post-RA 需要**：pre-RA 虚拟寄存器接近 SSA，anti-dep 稀少；RA 把多个不重叠生命期压进同一物理寄存器后，"def 覆盖旧 def 的读者"大量出现，构成纯调度序伪依赖。重命名到空闲物理寄存器 = 把 RA 丢失的自由度局部买回来。破完后整个 DAG 重建（PostRASchedulerList.cpp:421-432）。
- CriticalAntiDepBreaker（lib/CodeGen/CriticalAntiDepBreaker.cpp，701 行，DEBUG_TYPE "post-RA-sched" :39）：
  - StartBlock（:50-94）：KillIndices/DefIndices 初始化；后继 live-in 与 callee-saved 打上 -1 哨兵（:71,:89，"不可改名"）。
  - CriticalPathStep（:140-157）：沿**最大深度前驱边**回溯关键路径，latency 并列时**优先 anti 边**（:150-151）。
  - BreakAntiDependencies（:437-695）：找关键路径底端 Max（:453-460）→ 自底向上扫指令 → **只破关键路径上的 anti 边**（:544-547 注释：寄存器有限，留给重要的边）→ 排除项：非 allocatable/KeepRegs/与其它真依赖并存（:562-585）、call/hasExtraDefRegAllocReq/predicated（:604-607）、指令自身 use 了 AntiDepReg（:618-621）→ findSuitableFreeRegister 候选检查（:396-435：排除 AntiDepReg/LastNewReg/被 RegRefs 破坏/活跃冲突/Forbid 重叠）→ RegRefs setReg 全量改名 + DBG 跟随（:654-666）→ 双向 Kill/DefIndices 状态搬运（:671-683）。
  - 防振荡：LastNewReg 记录"上次替身"，避免连环替换把 anti-dep 原地转手（:480-521，含 A/B/C 反例注释）。
- AggressiveAntiDepBreaker.cpp（:9-12 头注释）："attempts to break **all** anti-dependencies within a block"。
- Target 用户（grep）：X86 = ANTIDEP_CRITICAL（X86Subtarget.h:443-445）+ X86 的 getPostRAMutations（:440-441）；PPC = ANTIDEP_ALL + CriticalPathRCs=G8RC/GPRC（PPCSubtarget.cpp:165-173）；Hexagon = ANTIDEP_ALL（HexagonSubtarget.h:321）。其余全部默认 ANTIDEP_NONE（TargetSubtargetInfo.h:296）。
- CLI 强制：`-break-anti-dependencies=none|critical|all`（PostRASchedulerList.cpp:59-63, :288-294）。

### 动态验证
本 build 无 X86/PPC/Hexagon target，未复现改名日志；CriticalAntiDepBreaker.cpp:647-650 的 "Breaking anti-dependence edge on %x with N references using %y!" 为对应输出格式（静态确认）。**待 X86 build 补验。**

### 设计动机
寄存器是稀缺资源：Critical 版把改名额度只花在关键路径（投资回报），Aggressive 版（PPC/Hexagon，静态多发射/VLIW 机型）全量破除换取打包自由度——与 target 的发射宽度正相关。

### 昇腾映射（推理级，待验证）
若 PyPTO 的 UB/slot 分配器复用了"不重叠生命期合并到同一 slot"，则 tile 流水线中的 WAR 依赖同样可由"slot 重命名"消除；对标量关键路径（如 MTE→Cube 依赖链）优先，即 Critical 策略类比。

## 6.3 Source-level（SDAG）调度：ISel 内联的顺带调度

### 静态分析
- 载体：lib/CodeGen/SelectionDAG/ScheduleDAGSDNodes.cpp（DEBUG_TYPE "pre-RA-sched" :38；ScheduleDAGSDNodes::Run→Schedule，:55-64；BuildSchedUnits/AddSchedEdges/BuildSchedGraph :324/:441/:536；EmitSchedule :848）。注意与任务锚点差异：**"pre-RA-sched" 的 DEBUG_TYPE 实际在 ScheduleDAGSDNodes.cpp:38**（ScheduleDAG.cpp 为通用 SUnit 基础设施，未含该 DEBUG_TYPE）。
- 执行点：ISel 主循环内，选完后立刻调度——SelectionDAGISel.cpp:1157-1163（"Schedule machine code" → `Scheduler->Run(CurDAG, FuncInfo->MBB)`）→ :1177 `Scheduler->EmitSchedule(InsertPt)`。**不是独立 MachineFunction pass，是逐 BB 内联步骤**。
- 调度器选择：`-pre-RA-sched=<name>` cl 注册表（ISHeuristic，SelectionDAGISel.cpp:217-222；default 项 :224-226）。createDefaultScheduler 决策树（:301-328）：
  1. target 的 getDAGScheduler hook 优先（:307-309）；
  2. `OptLevel==None || (enableMachineScheduler() && enableMachineSchedDefaultSched()) || Sched::Source` → **createSourceListDAGScheduler（源序）**（:311-314）；
  3. RegPressure→BURR（:315-316）；Hybrid（:317-318）；**VLIW→createVLIWDAGScheduler**（:319-320，ScheduleDAGVLIW.cpp）；Fast（:321-322）；Linearize（:323-324）；ILP→createILPListDAGScheduler（:325-327）。
- 策略名辨析（回应任务问题）：**SDAG 版注册集是 default/source/burr/hybrid/ilp/fast/vliw/linearize（ScheduleDAGRRList.cpp:69-90 工厂 :3113-3165；SchedulerRegistry.h:62-104），没有 "ilpmax/ilpmin"**——后者是 MI 层 `-misched=` 注册表（见 03-policy §4.4），勿混。
- 谁还在真用：getSchedulingPreference 的 target override 仅剩 **ARM**（ARMISelLowering.cpp:1566-1594：浮点/向量→ILP；operand cycle>2→ILP；否则 RegPressure）与 **PPC**（PPCISelLowering.h:306）。其余 target 走 TargetLowering 默认 Source；且**凡是启用 MISched 的 target**（enableMachineSchedDefaultSched）在 O1+ 都被 :311-314 钳到源序——即现代主流 target 的 SDAG 调度退化为"按源序发射"，真正调度让位给 pre-RA MISched pass。
- 唯一认真用 SDAG 调度的形态：VLIW（Hexagon 系）的 ScheduleDAGVLIW + 老 target 的 BURR/Hybrid（ARM 32 位路径仍在用）。

### 动态验证
`-debug-only=pre-RA-sched` 需 target 真选 SDAG 调度器才有实质日志；AArch64（MISched target）下为源序发射。未在本轮执行（预算），非阻塞——静态证据链已闭合（SelectionDAGISel.cpp:311-314）。

### 设计动机
ISel 产出 MI 的顺序天然由 SDAG 拓扑决定；若 MISched pass 稍后会整体重排，ISel 内再做激进调度是重复劳动且可能干扰 pattern matching（表匹配倾向源序）。三时点演进结论：**SDAG 调度从"主调度点"降级为"占位/源序发射"，仅在无 MISched 或 VLIW target 上保留实权。**

### 昇腾映射（推理级，待验证）
PyPTO tile 级（lowering 时的算子编排）= Source-level 类比：发生在"指令还未最终成形"的阶段，顺序由图拓扑/源序决定，压力信息缺席；若下游有独立的 UB 级重排，tile 级也应退化为源序以避免双重调度。

## 6.4 ModuloSchedule：软件流水（Swing Modulo Scheduling）

### 静态分析
- pass：lib/CodeGen/MachinePipeliner.cpp（4492 行，DEBUG_TYPE "pipeliner" :101）。入口 runMachinePipeliner（:431-455）四道门：`-enable-pipeliner`（默认 true，:117）、OptimizeForSize 跳过（:439-441）、target enableMachinePipeliner（:443）、**useDFAforSMS 时必须有非空 Itinerary**（:448-451）。MachinePipelinerImpl::run 逐顶层循环 scheduleLoop（:423-429）→ swingModuloScheduler（:781-806）：SwingSchedulerDAG 构造 → enterRegion（header，止于首个 terminator，:800）→ schedule()。
- II 计算主链（SwingSchedulerDAG::schedule，:872-…）：buildSchedGraph → addLoopCarriedDependences（:874，实现 :1365）→ findCircuits 找环（:889）→ **ResMII**（calculateResMII :2026-2030，委托 ResourceManager/DFA 资源下界）→ **RecMII**（calculateRecMII :2038-2056：每个环 `ii = ceil(delay/distance)`，取最大；约束不等式 delay(c) − II·distance(c) ≤ 0 见 :2032-2037 注释）→ **setMII = max(ResMII, RecMII)**（:852-859；SwpForceII/`llvm.loop.pipeline.initiationinterval` pragma 可强设）→ MAX_II = MII + 搜索范围（:861-868，`-pipeliner-ii-search-range` :180）→ schedulePipeline 从 MII 逐个 II 上探（头注释 :16），失败则 NumFailNoSchedule（:972-981）；numStages==0 或超 `-pipeliner-max-stages` 放弃（:985-1000）。
- 通用展开器：lib/CodeGen/ModuloSchedule.cpp（2875 行，DEBUG_TYPE "pipeliner" :23）。ModuloScheduleExpander::expand（:72-104）：先算每个 def 的最大 stage 差 RegToStageDiff → generatePipelinedLoop（:106+）：新建 KernelBB、按 stage 的 VRMap/VRMapPhi 寄存器改名（:113-124）、generateProlog（:197）/generateEpilog（:257）/generatePhis（:623）/addBranches（:869）；computeDelta 处理跨迭代访存（:935）。
- 展开器三选一（MachinePipeliner.cpp:1035-1057）：PeelingModuloScheduleExpander（实验 `-pipeliner-experimental-cg`） / ModuloScheduleExpanderMVE（ARM MVE 谓词化展开，:1048-1052）/ 默认 ModuloScheduleExpander。
- Target 用户与挂载：
  - enableMachinePipeliner override：PPC（PPCSubtarget.h:231）、ARM（ARMSubtarget.h:441）、RISCV（RISCVSubtarget.h:401）、AArch64（AArch64Subtarget.h:164；实现 `return getSchedModel().hasInstrSchedModel()`，AArch64Subtarget.cpp:651-653）。
  - 挂载点各自 addPreRegAlloc：**AArch64**（AArch64TargetMachine.cpp:878-879）但被 `aarch64-enable-pipeliner` 钳制，**默认 false**（:217-220）；**ARM** 仅 OptLevel::Aggressive（ARMTargetMachine.cpp:500-503）。
  - useDFAforSMS：默认 true（TargetSubtargetInfo.h:317-319，DFA+Itinerary 路线）；PPC/AMDGPU/ARM/RISCV/AArch64 均返回 false（PPCSubtarget.cpp:160、GCNSubtarget.h:1064、ARMSubtarget.cpp:507、RISCVSubtarget.h:403、AArch64Subtarget.h:165）改走 SchedModel 资源。Hexagon 走默认 DFA 路线（其 DFA packetizer 见 §6.5）。

### 动态验证（如实记录）
- 本 build llc 注册 target 仅 aarch64/amdgpu/nvptx 系（llc --version 实测），**ARM32 与 Hexagon 不可测**；AArch64 pipeliner 默认关闭，需 `-aarch64-enable-pipeliner` 显式开启。
- 已备用例 `scratch/loop.ll`（单 BB 乘加循环）；命令：`./build-debug/bin/llc -O3 -mtriple=aarch64 -aarch64-enable-pipeliner -debug-only=pipeliner scratch/loop.ll`。**本轮因迭代预算未及执行，预期日志锚点："MII = X MAX_II = Y (rec=…, res=…)"（MachinePipeliner.cpp:905-906）。待补跑。**

### 设计动机
循环级 ILP 的天花板：列表调度只能在循环体内排序，SMS 让**迭代间重叠**（prologue/kernel/epilogue 三段式，kernel 以 II 为节拍），II 下界=资源(ResMII)与环依赖(RecMII)之最大者，是教科书约束求解的最小实现。expander 与求解器解耦（ModuloSchedule 作为纯数据对象），使 ARM MVE 谓词化、peeling 等不同下游共存。

### 昇腾映射（推理级，待验证）
PyPTO tile 流水线的 double-buffering ≈ stage count=2 的模调度：II 下界的两个分量可直接对标——ResMII ↔ MTE/Cube 吞吐瓶颈，RecMII ↔ tile 间循环携带依赖链（如上一 tile 尾部结果喂下一 tile 头部）。若 PyPTO 的流水深度选择是手工拍定而非从 max(Res,Rec) 推导，则缺失的正是 calculateResMII/calculateRecMII 这一对下界求解。

## 6.5 VLIWMachineScheduler + WindowScheduler

### 静态分析
- **VLIWMachineScheduler**（lib/CodeGen/VLIWMachineScheduler.cpp，1003 行；DEBUG_TYPE "machine-scheduler" :41 与 MISched 共用——MI 层通用注册表的一员，非 -pre-RA-sched 族）。
  - VLIWResourceModel（:64-76）**包装 DFAPacketizer**（`ResourcesModel = createPacketizer(STI)` :67，虚函数 createPacketizer :192-193；`canReserveResources` 判入包 :115、reserveResources :144+、Packet 容量 = SchedModel issueWidth :73；无 DFA 实现直接 assert :69-71）。
  - 打包语义：hasDependence（:86-100，延迟>0 的后继边阻止同包）+ isResourceAvailable（:107+）共同决定"能否进当前 VLIW 包"。
  - 调度主循环（VLIWMachineScheduler::schedule :200-267）：buildDAGWithRegPressure（**pre-RA，压力仍被追踪**）→ initQueues → pickNode 循环（SchedImpl=ConvergingVLIWScheduler，:243-255）→ placeDebugValues。ConvergingVLIWScheduler::initialize（:269-299）：Top/Bot 双向各配 HazardRec（CreateTargetMIHazardRecognizer :283-284）+ 各自 ResourceModel（:288-289）；HighPressureSets 由 MaxSetPressure > 0.75×limit 判定（:60-62 阈值，:291-298）——**压力感知的 VLIW 打包**：高压时收敛打包宽度。
  - 与 DFAPacketizer 的关系（Hexagon 独家用户）：HexagonTargetMachine.cpp:185-193 createVLIWMachineSched 构造 VLIWMachineScheduler + HexagonConvergingVLIWScheduler + 四个 Hexagon mutation（UsrOverflow/HVXMemLatency/Call/CopyConstrain），注册为 MachineSchedRegistry **"hexagon"**（:195-197，即 -misched=hexagon，见 03-policy §4.4 谱系）。DFA 本体由 tablegen 生成（Hexagon/CMakeLists.txt:9 `-gen-dfa-packetizer`；HexagonInstrInfo.cpp:70 引 HexagonGenDFAPacketizer.inc，:2008-2011 CreateTargetScheduleState→createDFAPacketizer）。另有 post-RA 的 HexagonVLIWPacketizer pass（HexagonVLIWPacketizer.h:12）与 HexagonHazardRecognizer（:23,:51 包 DFAPacketizer）。
- **WindowScheduler**（lib/CodeGen/WindowScheduler.cpp，709 行；DEBUG_TYPE "pipeliner" :52——**与 SMS 共用调试通道，属软件流水族**）。
  - 算法语义（头注释 :9-35）：在循环的某个位置把 MBB **折叠（fold）**，对折叠后的 MI 做列表调度，遍历多个折叠位置取最优——是模调度的**小范围/低风险替代**。核心结构 **TripleMBB**：原 MBB 复制三份以便折叠与建依赖（:17-19）；phi 无法进窗，单独 schedulePhi（:23-25,:144）；定位 **pre-RA** 使用，post-RA target 需重写 analyseII/schedulePhi/expand（:27-31）。
  - 主流程 run（:112-163）：initialize（:174-240：target enableWindowScheduler 默认 true，TargetSubtargetInfo.h:235；需 LiveIntervals；不支持 loop-carried phi/物理寄存器 def/调度边界指令）→ 对每个搜索位置（window-search-num=6 :64-68、window-search-ratio=40% :70-75）做 enterRegion+schedule+analyseII（:126-148）→ isScheduleValid（best II 需比 base II 好 window-diff-limit=2 以上，:89-94）→ expand() 展开 prologue/kernel/epilogue（:159-160，复用 ModuloScheduleExpander 基建）。列表调度本体借 target 的机器调度器（createMachineScheduler → TM->createMachineScheduler，:165-172）。
  - 与 SMS 的关系（MachinePipeliner.cpp）：`-window-sched=off/on/force`（:219-226，默认 **WS_On**）；useWindowScheduler = Force 或 (On && **SMS 未改动此循环**)（:837-850）——**窗口调度是 SMS 的兜底**，SMS 成功则不再跑；pragma II 设定时禁用（:842-846）。

### 动态验证
未执行（预算；两器均需 target 配合：VLIW 需 Hexagon，WindowScheduler 日志走 -debug-only=pipeliner 且默认仅 SMS 失败的循环触发）。待补：AArch64 `-aarch64-enable-pipeliner -debug-only=pipeliner` 下观察 "Window scheduling" 相关行。

### 设计动机
- VLIW 打包：静态发射的机器必须由编译器保证每条指令槽合法，DFAPacketizer 把"指令组合合法性"编译成自动机，调度器只管查询——打包正确性与调度启发式解耦。
- 窗口调度：SMS 的 prologue/epilogue 代码膨胀与寄存器代价在某些循环上得不偿失；折叠式重排以更低风险拿到迭代间重叠，作为廉价兜底。

### 昇腾映射（推理级，待验证）
- CCE 向量指令/multiple-MTE 并发发射若需编译器静态打包，DFAPacketizer 的"组合合法性自动机"模式（tablegen 生成）可直接平移为 NPU 发射槽自动机。
- WindowScheduler 的"折叠+搜索多个位置、只在明确获益(≥diff-limit)才改写"是 PyPTO tile 重排 pass 的稳妥性模板：小窗口、可回退、收益门槛。

## 7. 三时点分工综述（§6 素材）

1. **演进方向**：调度重心从 Source-level（ISel 内联）→ Pre-RA MISched（现代默认主战场）逐点后移；Post-RA 被两类 target 分化——乱序机器（AArch64 :594-595 替换为 PostMachineScheduler）信任硬件消歧，静态发射/无互锁机器（X86 的 post-RA-sched、Hexagon、PPC）保留 legacy 列表调度 + AntiDepBreaker + itinerary 冒险。
2. **信息完备性递减**：SDAG 有最纯的依赖图但无资源/压力；Pre-RA 有压力无物理冲突；Post-RA 有最真实的风险模型但自由度被 RA 吃掉——AntiDepBreaker 是"买回自由度"的补丁。
3. **专项调度器都是循环/打包域**：SMS/Window（-debug-only=pipeliner 族）作用于单 BB 循环，VLIW 打包作用于 issue packet，均不是通用 DAG 调度的替代而是叠加。

## 引用清单（全部实核）

- llvm/lib/CodeGen/PostRASchedulerList.cpp — :46, :48-50, :56-63, :108-110, :116, :119, :125, :131, :219-231, :270-278, :280-360, :326-329, :412-443, :448-451, :535-540, :544-687, :690-721
- llvm/lib/CodeGen/CriticalAntiDepBreaker.cpp — :39, :50-94, :140-157, :396-435, :437-695（:453-460, :480-521, :544-547, :604-621, :647-683）
- llvm/lib/CodeGen/AggressiveAntiDepBreaker.cpp — :9-12
- llvm/include/llvm/CodeGen/AntiDepBreaker.h — :29-31, :39-55, :59-90, :93-99
- llvm/include/llvm/CodeGen/TargetSubtargetInfo.h — :235, :251, :278-279, :296, :301-303, :307-315, :317-319, :323-325
- llvm/lib/CodeGen/TargetSubtargetInfo.cpp — :64-70
- llvm/lib/CodeGen/TargetPassConfig.cpp — :220-228, :1188, :1210, :1218-1227
- llvm/lib/CodeGen/SelectionDAG/SelectionDAGISel.cpp — :217-226, :301-328, :1157-1177, :2230-2232
- llvm/lib/CodeGen/SelectionDAG/ScheduleDAGSDNodes.cpp — :38, :55-64, :324, :441, :536, :848
- llvm/lib/CodeGen/SelectionDAG/ScheduleDAGRRList.cpp — :69-90, :3113-3165
- llvm/include/llvm/CodeGen/SchedulerRegistry.h — :62-104
- llvm/lib/CodeGen/MachinePipeliner.cpp — :16, :101, :117, :126, :180, :219-226, :231, :423-455, :781-806, :820-850, :852-868, :872-1000, :1035-1057, :1365, :2026-2056
- llvm/lib/CodeGen/ModuloSchedule.cpp — :23, :30-33, :72-104, :106-125, :197, :257, :623, :869, :935
- llvm/lib/CodeGen/VLIWMachineScheduler.cpp — :41, :60-62, :64-76, :86-100, :107-144, :192-193, :200-267, :269-304
- llvm/lib/CodeGen/WindowScheduler.cpp — :9-35, :52, :64-102, :104-172, :174-240
- llvm/lib/Target/AArch64/AArch64TargetMachine.cpp — :217-220, :594-595, :862-879
- llvm/lib/Target/AArch64/AArch64Subtarget.h — :161-165；AArch64Subtarget.cpp — :651-653
- llvm/lib/Target/AArch64/AArch64Features.td — :764-765；AArch64Processors.td — :24-264（多处 FeaturePostRAScheduler）；AArch64SchedA53.td:23、A510.td:24、ThunderX2T99.td:25、A64FX.td:20、A320.td:22、Oryon.td:23、C1Nano.td:29
- llvm/lib/Target/ARM/ARMISelLowering.cpp — :1566-1594；ARMTargetMachine.cpp — :500-515
- llvm/lib/Target/ARM/ARMSubtarget.cpp — :507；ARMSubtarget.h — :441-442, :445
- llvm/lib/Target/PowerPC/PPCSubtarget.cpp — :160-173；PPCSubtarget.h — :231-237；PPCISelLowering.h — :306
- llvm/lib/Target/X86/X86Subtarget.h — :440-445
- llvm/lib/Target/Hexagon/HexagonSubtarget.h — :321, :324；HexagonTargetMachine.cpp — :185-197；HexagonInstrInfo.cpp — :70, :2008-2011；HexagonVLIWPacketizer.h — :12；HexagonHazardRecognizer.h — :23, :51；CMakeLists.txt — :9
- llvm/lib/Target/RISCV/RISCVSubtarget.h — :162, :401, :403
- llvm/lib/Target/AMDGPU/GCNSubtarget.h — :1064
- llvm/lib/Target/Mips/MipsSubtarget.h — :234-235
- 交叉引用：Sched-notes/02-skeleton（Pre-RA MISched 骨架）、03-policy §4.4（-misched= 注册表与五级定制谱系）、NVPTX-notes/03（PostRAScheduler 双保险禁用）、AMDGPU-notes/06（5-stage）
- 动态环境：build-debug llc 24.0.0git（DEBUG+assertions），registered targets = aarch64/aarch64_32/aarch64_be/amdgpu/arm64/arm64_32/nvptx/nvptx64/r600；用例 scratch/antidep.ll、scratch/loop.ll
---

## 附录：动态验证补录（主会话实测）

1. **pipeliner 实测成功**（子代理因相对路径失败，主会话补跑）：`llc -O3 -mtriple=aarch64 -aarch64-enable-pipeliner -debug-only=pipeliner scratch/loop.ll` → SMS 的 SUnit dump 可见（`SU(0): PHI / # succs left: 4 / Height: 6`）——AArch64 软件流水需显式 `-aarch64-enable-pipeliner`（默认 false，AArch64TargetMachine.cpp:217-220）。
2. **antidep.ll 复证**：`-debug-only=post-RA-sched` AArch64 空输出（exit 0）——再次确认 :594-595 substitutePass 换掉老调度器（与 04-hazard 附录互证）。
3. 子代理两处坑：测试用例写到了 `~/code/llvm-project/scratch/`（仓库根，非 Sched-notes/scratch/）+ 相对路径跑 llc 失败——已由主会话补跑修正。
