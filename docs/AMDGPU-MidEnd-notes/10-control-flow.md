# §10 控制流与一致性层(F14 / F1 / F16)

> 数据基准:llvm-project main @ `3eda2aebadd4`(2026-09-28),build-debug 实跑。
> 方法:静态读码(`文件:行号`)+ 动态验证(`opt -passes` / `llc -stop-after` 差分)。
> 素材:`AMDGPU-MidEnd-notes/scratch/ch10/{f01,f01b,f14,f16}_*.ll`。

---

## 章节定位

GPU 的控制流与 CPU 根本不同:**一个 wavefront 只有一条 PC**,divergent 分支(不同 lane 走不同路径)要靠 **EXEC mask** 串行执行两个分支。这一层的三个 pass 协作完成"通用 CFG → GPU 可执行的 structurized 控制流"的转换:

| Pass | 一句话 | 角色 |
|---|---|---|
| **F14** AMDGPUUnifyDivergentExitNodes | 多个 divergent return 合并成一个 | StructurizeCFG 前置 |
| **F1** AMDGPUAnnotateUniformValues | 给 uniform 分支/load 打 metadata | 为后端标记 |
| **F16** SIAnnotateControlFlow | divergent 分支插入 `amdgcn_if`/`else`/`end_cf` | **核心**:CFG → EXEC mask 操作 |

**严格的运行顺序**(`AMDGPUTargetMachine.cpp:2496-2503`):
```
F14 UnifyDivergentExitNodes  (:2496)
   ↓ (中间夹 FixIrreducible / UnifyLoopExits / StructurizeCFG)
F1  AnnotateUniformValues    (:2501)
   ↓
F16 SIAnnotateControlFlow    (:2503)
   ↓
F11 RewriteUndefForPHI       (:2508)  ← §9 讲过,必须在 F16 后
```

**为什么这个顺序?** StructurizeCFG 要求单出口(F14 先把多 return 合一);F1 在 structurize 后标注 uniform(此时 CFG 已定型);F16 最后把标注过的 divergent 分支翻译成 EXEC mask intrinsic。三者是**流水线的三棒接力**。

---

## F14 AMDGPUUnifyDivergentExitNodesPass

### 10.1.1 一句话定位
把函数里**多个 divergent 的 return/unreachable** 合并成**唯一**的 `UnifiedReturnBlock`——因为 StructurizeCFG 处理不了"多出口区域"(文件头 :13-14 注释),必须先归一。

### 10.1.2 运行位置

`addIRPasses`(`:2496`),在 `StructurizeCFGPass`(`:2499`)之前三步:
```cpp
addFunctionPass(AMDGPUUnifyDivergentExitNodesPass(), PMW);   // :2496
addFunctionPass(FixIrreduciblePass(), PMW);
addFunctionPass(UnifyLoopExitsPass(), PMW);
addFunctionPass(StructurizeCFGPass(/*SkipUniformRegions=*/false), PMW);  // :2499
```

### 10.1.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUUnifyDivergentExitNodes.cpp`(374 行)。

它是通用 `UnifyFunctionExitNodes` 的 **GPU 变体**(文件头 :9-11):通用版保证"最多一个 ret 一个 unreachable",这个变体只保证"**最多一个 divergent 出口**"——uniform 的 return 不合并(它们走标量分支,不该被 structurize)。

关键判断 `isUniformlyReached`(:120):一个块如果只经 uniform 分支可达,就不参与合并。`unifyReturnBlockSet`(:139)收集所有 `ReturningBlocks`,若有多个 divergent 出口,建一个 `UnifiedReturnBlock`,所有原 return 改成 `br UnifiedReturnBlock`,返回值用 PHI 汇聚(:152)。

**特殊处理**(文件头 :17-18):一个分支去 return、一个去 unreachable 时,把 unreachable 替换成 return——否则 structurize 仍处理不了。

### 10.1.4 动态验证

素材:`scratch/ch10/f14_in.ll`,三个 divergent return。

```bash
opt -passes='amdgpu-unify-divergent-exit-nodes' -S f14_in.ll
```

输入有三个 `ret void`(ret1/ret2/bb3),输出(实测):
```llvm
entry:
  br i1 %c1, label %UnifiedReturnBlock, label %bb2
bb2:
  br i1 %c2, label %UnifiedReturnBlock, label %UnifiedReturnBlock
UnifiedReturnBlock:          ; 三个 return 合成一个
  ret void
```

三个出口被捏成一个 `UnifiedReturnBlock`,CFG 变成 StructurizeCFG 能处理的单出口形态。

### 10.1.5 设计动机

StructurizeCFG 的算法前提:**每个区域单入口单出口**。GPU 的 divergent 控制流必须 structurize(否则无法生成 EXEC mask 代码),所以多 return 是硬障碍。F14 是"为了让 StructurizeCFG 能跑"的**纯前置整理**,自身不产生性能收益。

### 10.1.6 昇腾启示

昇腾的 warp 控制流同样需要 structurize。可借鉴:
- **多出口归一**:昇腾 kernel 的多个 return 在进入控制流 lowering 前,也必须合并成单出口。
- **区分 uniform/divergent return**:uniform return 不合并(走标量快速路径),这个区分昇腾也应保留。

---

## F1 AMDGPUAnnotateUniformValuesPass

### 10.2.1 一句话定位
给**已证 uniform** 的分支打 `!amdgpu.uniform` metadata,给 uniform 且未被 clobber 的 global load 打 `!amdgpu.noclobber` metadata——**不改代码,只打标签**,供后端指令选择时识别"这个可以用标量路径/可以缓存"。

### 10.2.2 运行位置

`addIRPasses`(`:2501`),在 StructurizeCFG(:2499)**之后**、SIAnnotateControlFlow(:2503)之前。

### 10.2.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUAnnotateUniformValues.cpp`(151 行,轻量)。两个 visitor:

**① 分支(`visitCondBrInst` :62-65)**:
```cpp
void AMDGPUAnnotateUniformValues::visitCondBrInst(CondBrInst &I) {
  if (UA->isUniformTerminator(&I))
    setUniformMetadata(&I);   // :38-41,打 !amdgpu.uniform
}
```

**② load(`visitLoadInst` :67-83)**:
```cpp
void AMDGPUAnnotateUniformValues::visitLoadInst(LoadInst &I) {
  Value *Ptr = I.getPointerOperand();
  if (UA->isDivergentAtDef(Ptr))
    return;
  if (Instruction *PtrI = dyn_cast<Instruction>(Ptr))
    setUniformMetadata(PtrI);              // 指针本身 uniform -> 标记

  if (!isEntryFunc) return;                 // 只管入口函数(kernel)
  bool GlobalLoad = AS == GLOBAL_ADDRESS;
  if (GlobalLoad && !AMDGPU::isClobberedInFunction(&I, MSSA, AA))
    setNoClobberMetadata(&I);              // :43-46,打 !amdgpu.noclobber
}
```

**`isClobberedInFunction`**(:81)用 MemorySSA + AliasAnalysis 判断"这个 load 在函数内没有被任何 store 改写"——只有入口函数(kernel)的 live-in load 才能保证,所以 `:78` 有 `isEntryFunc` 拦截。

### 10.2.4 动态验证

```bash
opt -passes='amdgpu-annotate-uniform' -S f01_in.ll
```

`f01_in.ll`(workgroup_id 分支,uniform):
```llvm
br i1 %cond, label %then, label %merge, !amdgpu.uniform !0   ; <- 分支标记
```

`f01b_in.ll`(global uniform load,无 clobber):
```llvm
%u = load i32, ptr addrspace(1) %p, align 4, !amdgpu.noclobber !0  ; <- load 标记
br i1 %c, ..., !amdgpu.uniform !0
```

两个 metadata 都实测命中。

### 10.2.5 设计动机

后端(SelectionDAG)看不到 UniformityAnalysis/MemorySSA 的结果——这些 FunctionPass 分析在 ISel 时就销毁了。F1 把分析结论**物化成 metadata**,让后端能查"这个分支是 uniform 的(用 s_branch 而非 v_branch)""这个 load 不会被改(可进 constant cache)"。这是**分析结果跨阶段传递的桥**。

### 10.2.6 昇腾启示

昇腾同样需要在 ISel 时知道 uniform/noclobber 信息。可借鉴:
- **metadata 作为分析载体**:昇腾的 uniform 分析结果也应物化成 metadata,供后端指令选择查询。
- **MemorySSA 驱动 noclobber**:只读 global load 进常量缓存,昇腾的只读 buffer 优化同理。

---

## F16 SIAnnotateControlFlowPass

### 10.3.1 一句话定位
**核心 pass**:把 structurized CFG 里的 **divergent 分支**翻译成 AMDGPU 硬件的 EXEC mask 操作——`llvm.amdgcn.if`(开分支)、`llvm.amdgcn.else`(开 else)、`llvm.amdgcn.end_cf`(汇合)、`llvm.amdgcn.loop`/`if_break`(循环),后端再把这些 lowering 成 `s_and_saveexec`/`s_mov` 等真实指令。

### 10.3.2 运行位置

`addIRPasses`(`:2503`),在 F1 之后、F11 之前。

### 10.3.3 静态读码

文件:`llvm/lib/Target/AMDGPU/SIAnnotateControlFlow.cpp`(455 行)。

`run()`(:343-385)用**深度优先遍历 + 栈**模拟控制流嵌套:

```cpp
for (df_iterator<BasicBlock*> I = df_begin(entry); I != E; ++I) {
  BasicBlock *BB = *I;
  CondBrInst *Term = dyn_cast<CondBrInst>(BB->getTerminator());
  if (!Term) { if (isTopOfStack(BB)) closeControlFlow(BB); continue; }

  if (I.nodeVisited(Term->getSuccessor(1))) {          // 回边 -> 循环
    if (DT->dominates(Term->getSuccessor(1), BB))
      handleLoop(Term);
    continue;
  }
  if (isTopOfStack(BB)) {
    PHINode *Phi = ...;
    if (Phi && isElse(Phi) && !hasKill(BB)) {
      insertElse(Term);                                 // else 分支
      continue;
    }
    closeControlFlow(BB);
  }
  openIf(Term);                                         // 普通 if
}
```

**三个核心插入**:

**① openIf**(:186-198):divergent 条件分支 → `amdgcn_if`:
```cpp
Value *IfCall = IRB.CreateCall(getDecl(If, amdgcn_if, IntMask), {Cond});
Value *Cond = extractvalue(IfCall, 0);   // 新条件(哪些 lane 进 then)
Value *Mask = extractvalue(IfCall, 1);   // 保存的旧 EXEC mask
Term->setCondition(Cond);
push(Term->getSuccessor(1), Mask);       // 把旧 mask 压栈,else 时用
```

**② insertElse**(:201-214):else 分支 → `amdgcn_else`,从栈弹出之前保存的 mask。

**③ closeControlFlow**(:299-336):汇合点 → `amdgcn_end_cf`,恢复 EXEC。

**isUniform 拦截**(:130-132):
```cpp
bool SIAnnotateControlFlow::isUniform(CondBrInst *T) {
  return UA->isUniformTerminator(T) || T->hasMetadata("structurizecfg.uniform");
}
```
uniform 分支**不插**任何 intrinsic——它们不需要 EXEC mask(全 wave 同向),走普通标量分支。

### 10.3.4 动态验证

素材:`scratch/ch10/f16_in.ll`,divergent + uniform 两个 kernel。

```bash
llc -O2 -stop-after=si-annotate-control-flow f16_in.ll
```

`@k`(divergent,workitem.id)输出(实测):
```llvm
%0 = call { i1, i64 } @llvm.amdgcn.if.i64(i1 %cond)     ; 开 if,返回{新条件,旧mask}
%1 = extractvalue { i1, i64 } %0, 0
%2 = extractvalue { i1, i64 } %0, 1
br i1 %1, label %else, label %Flow                       ; 注意:then/else 被 structurize 重排
...
%3 = call { i1, i64 } @llvm.amdgcn.else.i64.i64(i64 %2)  ; else 分支
...
call void @llvm.amdgcn.end.cf.i64(i64 %5)                ; 汇合,恢复 EXEC
```

`@k_uniform`(workgroup.id,uniform):
```llvm
br i1 %cond, label %then, label %merge, !amdgpu.uniform !0  ; 只有 F1 的 metadata
; 无任何 amdgcn_if/else —— uniform 分支被 isUniform 拦截(:187)
```

**对比一目了然**:divergent 分支被 F16 包上 EXEC mask intrinsic,uniform 分支只留 F1 打的 `!amdgpu.uniform` 标签。

### 10.3.5 设计动机

GPU 执行 divergent 分支的硬件机制:**EXEC mask 寄存器**记录哪些 lane 活跃。divergent if 的执行是:
1. `s_and_saveexec`:保存当前 EXEC,计算"进 then 的 lane"作为新 EXEC。
2. then 分支只有活跃 lane 执行。
3. else:`s_andn2` 算出"没进 then 的 lane",切换 EXEC。
4. 汇合:恢复保存的 EXEC。

F16 把这些硬件操作**抽象成 intrinsic**(`amdgcn_if`/`else`/`end_cf`),让中端 IR 保持 CFG 形态,后端再 lowering 成具体的 `s_and_saveexec_b64` 等指令。栈结构(`StackVector`,:39)正是为了处理**嵌套**的 if/loop。

### 10.3.6 昇腾启示

昇腾的 warp divergent 控制流完全同构(EXEC mask / 活跃 lane 栈)。可借鉴:
- **CFG → mask intrinsic 的抽象层**:昇腾也应把 divergent 分支翻译成 `if`/`else`/`endif` 类 intrinsic,而非直接生成硬件指令,保持 IR 可优化。
- **栈模拟嵌套**:嵌套 if/loop 的 EXEC mask 保存/恢复,用编译期栈追踪,昇腾可复用。
- **uniform 分支短路**:全 warp 同向的分支不碰 EXEC,这是重要优化(避免无谓的 mask 操作),昇腾同样需要。

---

## 本章小结

| Pass | 输入 | 输出 | 关键判据 |
|---|---|---|---|
| F14 UnifyDivergentExitNodes | 多 divergent return | 单 `UnifiedReturnBlock` | `isUniformlyReached`(uniform return 不合) |
| F1 AnnotateUniformValues | uniform 分支/load | `!amdgpu.uniform`/`!amdgpu.noclobber` | `isUniformTerminator` / `isClobberedInFunction` |
| F16 SIAnnotateControlFlow | structurized divergent 分支 | `amdgcn_if`/`else`/`end_cf`/`loop` | `isUniform` 拦截 uniform 分支 |

**三棒接力**:F14 归一出口 → (StructurizeCFG)→ F1 打标签 → F16 插 EXEC mask。这是 GPU 中端最"硬核"的一段——把通用控制流翻译成 GPU 的 SIMT 执行模型。过了这一关,divergent 分支就已经"半只脚"踏进硬件了。

**与前后章节**:F14/F16 依赖 §4 建立的 UniformityAnalysis;F16 插入的 `amdgcn_if` 等 intrinsic 由后端 `SILowerControlFlow` lowering 成真实指令;F1 的 `!amdgpu.noclobber` 与 §6 F6 LowerKernelArguments 注入的 metadata 同源。
