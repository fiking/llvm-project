# §9 CodeGen 准备层(F3 / F5 / F11)

> 数据基准:llvm-project main @ `3eda2aebadd4`(2026-09-28),build-debug 实跑。
> 方法:静态读码(`文件:行号`)+ 动态验证(`opt`/`llc -stop-after` 差分)。
> 素材:`AMDGPU-MidEnd-notes/scratch/ch09/{f03,f03b,f05,f05b,f11}_*.{ll,s}`。

---

## 章节定位

中端管线的**最后一站**——指令选择(ISel)前的临门一脚。三个 pass 都在做"把通用 IR 整形成后端最容易吃掉的形态":

| Pass | 一句话 | 时机 |
|---|---|---|
| **F3** AMDGPUCodeGenPrepare | 整数除法展开、fdiv 降精度、mul24、load 加宽 | ISel 前较早(`:2421`) |
| **F5** AMDGPULateCodeGenPrepare | sub-dword load 加宽、非法向量跨 BB 寄存器打包 | ISel 紧前(`:2490`) |
| **F11** AMDGPURewriteUndefForPHI | structurized CFG 中 uniform PHI 的 undef 操作数改写 | StructurizeCFG/SIAnnotate 后(`:2508`) |

**共同特征**:都紧贴后端,直接为指令选择扫清障碍。它们不是通用优化(不为减少指令数),而是**目标特化的形状调整**——把 IR 翻译成"这台机器的 SelectionDAG 能高效匹配"的样子。

**运行位置**(全部在 llc 的 `addIRPasses` 尾部):
```
F3 AMDGPUCodeGenPrepare      (:2421)  <- 较早,后面还留 LICM hoist 除法不变量
... FlattenCFG / Sinking ...
F5 AMDGPULateCodeGenPrepare  (:2490)  <- 紧挨 ISel
F11 AMDGPURewriteUndefForPHI (:2508)  <- StructurizeCFG/SIAnnotateControlFlow 之后
```

---

## F3 AMDGPUCodeGenPreparePass

### 9.1.1 一句话定位
ISel 前的杂项整形:把 GPU 没有硬件指令的整数除法展开成 float 乘法序列,把 24-bit 范围乘法换成 `mul24` 内在函数,加宽窄 load,折 binop 进 select,拆大 PHI——一切为了让后端不用处理这些硬骨头。

### 9.1.2 运行位置

`addIRPasses`(`AMDGPUTargetMachine.cpp:2421`):
```cpp
// TODO: May want to move later or split into an early and late one.
addFunctionPass(AMDGPUCodeGenPreparePass(TM), PMW);
```
legacy 在 `:1643`。注意它**故意放在较靠前位置**——后面紧跟 LICM(`:1647-1648`),专门用来 hoist F3 展开除法时引入的循环不变量。

### 9.1.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUCodeGenPrepare.cpp`(2551 行,本章最重)。

`run()`(:294-314)反向遍历基本块,逐指令 `visit`。核心 visitor:

**① 整数除法展开(`visitBinaryOperator` :1449-1535)**

AMDGPU **没有整数除法硬件指令**。所有 `udiv`/`sdiv`/`urem`/`srem`(≤64 位)必须展开成"转 float → rcp(倒数)→ 乘回 → 修正"的软件序列:

```cpp
if ((Opc == URem || Opc == UDiv || Opc == SRem || Opc == SDiv) &&
    ScalarSize <= 64 && !DisableIDivExpand) {
  ...
  if (ScalarSize <= 32)
    NewDiv = expandDivRem32(Builder, I, Num, Den);   // 32-bit: 转 float
  else {
    NewDiv = shrinkDivRem64(Builder, I, Num, Den);   // 64-bit: 先试缩到 32/24
    if (!NewDiv) Div64ToExpand.push_back(&I);        // 缩不了就通用展开(带控制流)
  }
}
```

`expandDivRem32`(:1203)→ `expandDivRemToFloat`(:1064)。实测 `udiv i32` 展开成:

```llvm
%1 = uitofp fast i32 %b to float                    ; 除数转 float
%2 = call fast float @llvm.amdgcn.rcp.f32(float %1) ; rcp 求倒数
%3 = fmul fast float %2, f0x4F7FFFFE                ; 乘 2^32 缩放回整数域
; ... 后续 mul/sub/修正(约 10 条指令)
```

**② mul24 替换(`replaceMulWithMul24` :368-429)**

GPU 有专用 **24-bit 整数乘法**(`v_mul_u32_u24`/`v_mul_i32_i24`),比完整 32-bit mul 快。当两个操作数的有效位都 ≤24 时替换:

```cpp
if (ST.hasMulU24() && (LHSBits = numBitsUnsigned(LHS, &I)) <= 24 &&
    (RHSBits = numBitsUnsigned(RHS, &I)) <= 24) {
  IsSigned = false;
} else if (ST.hasMulI24() && ... <= 24) {
  IsSigned = true;
}
...
Intrinsic::ID ID = IsSigned ? amdgcn_mul_i24 : amdgcn_mul_u24;
Value *Result = Builder.CreateIntrinsic(ID, {IntrinTy}, {LHS, RHS});
```

**关键陷阱**(:378):`if (UA.isUniformAtDef(&I)) return false;`——**uniform 的乘法不替换**。因为 uniform 值走标量路径(`s_mul_i32`),标量没有 mul24 版本,替换了反而更慢。所以我的第一个 reproducer(kernel 参数相乘,uniform)没触发,改成 `workitem.id`(divergent)才命中。

**③ load 加宽(`visitLoadInst` :1537)**:`--amdgpu-codegenprepare-widen-loads`(`:46-50`,**默认 false**)控制,把可证明安全的窄 load 加宽到 dword 对齐。

**④ fdiv 降精度(`visitFDiv` :909)**:把精确 `fdiv` 换成 `rcp` + 牛顿迭代近似,fast-math 下激进降精度。

### 9.1.4 动态验证

素材:`scratch/ch09/f03_in.ll`、`f03b_in.ll`。

```bash
llc -O2 -stop-after=amdgpu-codegenprepare f03_in.ll
```

| Kernel | 输入 | 输出(实测) |
|---|---|---|
| `k_udiv` | `udiv i32 %a, %b` | `uitofp` + `llvm.amdgcn.rcp.f32` + `fmul f0x4F7FFFFE`(2^32)+ 修正序列 |
| `k_sdiv` | `sdiv i32 %a, %b` | 同上但先取绝对值、最后补符号(`:41-51`) |
| `k_mul24`(uniform 参数) | `mul nuw nsw (and %a, 2^24-1), (and %b, 2^24-1)` | **不替换**(uniform 拦截,:378) |
| `k_mul24div`(`f03b`,workitem.id) | 同上但 divergent | `call i32 @llvm.amdgcn.mul.u24.i32(%lo1, %lo2)` |

`k_mul24div` 输出(实测 `f03b_out.ll`):
```llvm
%lo1 = and i32 %id, 16777215     ; 2^24-1,证明高 8 位为 0
%lo2 = and i32 %id, 255          ; 2^8-1
%m = call i32 @llvm.amdgcn.mul.u24.i32(i32 %lo1, i32 %lo2)
```

**`numBitsUnsigned`**(`:389`)通过 `and` 掩码推断有效位——`and %x, 0xFFFFFF` 证明结果 ≤24 位。这是**值域分析驱动的指令选择预演**。

### 9.1.5 设计动机

GPU 的 ISA 是"加法机":整数除法、fdiv、宽 mul 都要软件模拟。这些展开**必须在 IR 层做**——因为展开会引入大量新指令(rcp、fmul、修正分支),后端 SelectionDAG 做不了这种重量级重构。同时展开后还要靠通用优化(LICM、InstCombine)清理,所以放在 ISel 前但又不太晚的位置。

### 9.1.6 昇腾启示

昇腾 NPU 同样无整数除法硬件。可借鉴:
- **除法→rcp+乘法序列**:昇腾的浮点倒数指令可复用相同的展开框架(`expandDivRemToFloat` 的结构与目标无关)。
- **mul24 的 uniform 陷阱**:uniform 值走标量路径时,激进替换反而慢——昇腾做"小位宽乘法"优化时也要先查 uniformity。
- **值域分析(`numBitsUnsigned`)驱动**:用 `and` 掩码推断有效位宽,昇腾可复用这套逻辑做定点化/窄位宽指令选择。

---

## F5 AMDGPULateCodeGenPreparePass

### 9.2.1 一句话定位
ISel **紧前**的两件事:(1) sub-dword(8/16-bit)常量地址 load 加宽到 dword;(2) **非法向量类型跨基本块**时,先打包成合法类型的 bitcast(省寄存器),用后拆回。

### 9.2.2 运行位置

`addIRPasses`(`:2486-2490`),在 `FlattenCFG`/`Sinking` 之后:
```cpp
if (TM.getOptLevel() > CodeGenOptLevel::None) {
  addFunctionPass(FlattenCFGPass(), PMW);
  addFunctionPass(SinkingPass(), PMW);
  addFunctionPass(AMDGPULateCodeGenPreparePass(getTM()), PMW);   // :2490
}
```
有 **O1+ gate**(`TM.getOptLevel() > None`)。

### 9.2.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPULateCodeGenPrepare.cpp`(620 行),两个独立优化:

**① load 加宽(`visitLoadInst` :508,`canWidenScalarExtLoad` :484)**

由 `--amdgpu-late-codegenprepare-widen-constant-loads`(`:38-42`,默认 true)控制。只针对**常量地址空间**(addrspace(4))的 sub-dword load。有 subtarget gate(:226-230):

```cpp
bool HasScalarSubwordLoads = ST.hasScalarSubwordLoads();
for (...) {
  Changed |= !HasScalarSubwordLoads && visit(I);   // 硬件本身支持窄 load 就不加宽
  Changed |= LRO.optimizeLiveType(&I, DeadInsts);
}
```

**② LiveRegOptimizer(非法向量打包,:81-480+)**

问题背景(:215-221 注释):SelectionDAG 遇到**非法向量类型**(如 `v3i32`——GPU 寄存器是 4 的倍数)跨基本块时,会把每个 scalar 拆到独立寄存器,`CopyToReg`/`CopyFromReg` 浪费。解法:跨 BB 前把 `v3i32` bitcast 成 `v4i32`(合法),用后拆回。

- `calculateConvertType`(:238):算目标合法类型(`v3i32` → `v4i32`)。
- `convertToOptType`(:256):bitsize 匹配就 `bitcast`;不匹配先 `shufflevector` 扩充再 bitcast。
- `optimizeLiveType`(:324):收集跨 BB 的非法向量 PHI/def,统一 coercion。

### 9.2.4 动态验证

```bash
llc -O2 -stop-after=amdgpu-late-codegenprepare f05b_in.ll
```

`f05b_in.ll` 的 `v3i32` PHI 跨 BB,输出(实测 `f05b_out.ll`):
```llvm
%largephi.extractslice0 = extractelement <3 x i32> %v, i64 0   ; 拆成 scalar
%largephi.extractslice2 = extractelement <3 x i32> %v, i64 1
%largephi.extractslice4 = extractelement <3 x i32> %v, i64 2
...
%2 = phi i32 [ %largephi.extractslice0, %entry ], [ 1, %then ] ; 每个 scalar 独立 PHI
%3 = phi i32 [ %largephi.extractslice2, %entry ], [ 2, %then ]
%4 = phi i32 [ %largephi.extractslice4, %entry ], [ 3, %then ]
%largephi.insertslice0 = insertelement <3 x i32> poison, i32 %2, i64 0  ; 重新组装
```

**load 加宽**(`f05_in.ll` 的 v2i16):实测 kernarg 的 i16 load 被加宽成 `load i32` + `trunc` + `shufflevector` 重组(`f05_out.ll:11-19`)。

### 9.2.5 设计动机

这是**寄存器分配的前置优化**。GPU 的 VGPR 是最宝贵资源,非法向量类型跨 BB 会被 SelectionDAG 拆成一堆独立寄存器,加剧寄存器压力。F5 在 ISel 前把它们"打包"成合法类型,让后端用紧凑的 CopyToReg 传递。

### 9.2.6 昇腾启示

昇腾的向量寄存器同样有合法/非法类型之分。可借鉴:
- **跨 BB 向量打包**:昇腾的非法向量(如非 2 的幂宽度)跨基本块时,同样可以先 coercion 到合法类型。
- **sub-dword load 加宽**:昇腾的 LDS/global 窄 load 若硬件不支持,可在 ISel 前统一加宽。

---

## F11 AMDGPURewriteUndefForPHIPass

### 9.3.1 一句话定位
**只在 StructurizeCFG + SIAnnotateControlFlow 之后**运行:对 uniform 的 PHI,如果某个 incoming 是 `undef`/`poison` 且其余是**唯一**的 defined 值,把整个 PHI 替换成那个 defined 值——让后端给这个 PHI 分配标量寄存器时不会被 undef 分支污染。

### 9.3.2 运行位置

`addIRPasses` 尾部(`:2508`),**位置有硬约束**(文件头注释 :9-11):
> This pass only works on IR that has gone through StructurizedCFG pass, and this pass has some additional limitation that make it can only run after SIAnnotateControlFlow.

`addIRPasses` 注释(`:2504-2507`):
```cpp
// Merge divergent exit nodes. StructurizeCFG won't recognize the multi-exit
// regions formed by them.
// TODO: Move this right after structurizeCFG to avoid extra divergence analysis.
addFunctionPass(AMDGPURewriteUndefForPHIPass(), PMW);
```

### 9.3.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPURewriteUndefForPHI.cpp`(192 行,最小)。核心 `rewritePHIs`(:99-167):

```cpp
for (PHINode &PHI : BB.phis()) {
  if (UA.isDivergentAtDef(&PHI))   // 只处理 uniform PHI
    continue;

  // 收集:唯一 defined incoming + 所有 undef incoming
  for (每个 incoming) {
    if (undef/poison) { Undefs.push_back(BB); continue; }
    if (!UniqueDefinedIncoming) { UniqueDefinedIncoming = V; DominateBB = BB; }
    else if (V == UniqueDefinedIncoming) { /* 更新 DominateBB */ }
    else { UniqueDefinedIncoming = nullptr; break; }   // 有 2 个不同 defined 值就放弃
  }

  // 条件:有唯一 defined 值 + 有 undef + defined 块的 terminator 是 divergent
  if (!UniqueDefinedIncoming || Undefs.empty() ||
      UA.isUniformTerminator(DominateBB->getTerminator()))
    continue;

  // DominateBB 必须 dominate PHI 块 + 所有 undef 前驱
  if (DT->dominates(DominateBB, &BB) && all_of(Undefs, dominates(DominateBB, _))) {
    PHI.replaceAllUsesWith(UniqueDefinedIncoming);   // 整个 PHI 删掉
    ToBeDeleted.push_back(&PHI);
  }
}
```

**两种 pattern**(文件头 :21-43):

- **Pattern A**:`phi [undef, %if], [%uniform, %then]`,undef 块 dominate defined 块。后端分配标量寄存器,只要任何线程走 `%then` 就拿到 `%uniform`,undef 分支自然正确——**不用改**。
- **Pattern B**:`phi [%uniform, %if], [undef, %then]`,defined 块 dominate undef 块。**必须改**——否则 `%then` 分支会覆写标量寄存器,把 `%uniform` 冲掉。F11 把整个 PHI 换成 `%uniform`,保证寄存器 liveness 正确。

### 9.3.4 动态验证

素材:`scratch/ch09/f11_in.ll`(Pattern B,`amdgpu_ps` 像素着色器)。

```llvm
define amdgpu_ps float @basic(float inreg %c, i32 %x) {
entry:
  %cc = icmp slt i32 %x, 0          ; %x divergent → 分支 divergent
  br i1 %cc, label %if, label %end
if:
  br label %end
end:
  %c2 = phi float [ poison, %if ], [ %c, %entry ]  ; %c 是 inreg → uniform
  ret float %c2
}
```

```bash
opt -passes=amdgpu-rewrite-undef-for-phi -S f11_in.ll
```

输出(实测):
```llvm
end:
  ret float %c    ; PHI 整个消失,直接用 %c
```

**为什么需要 `amdgpu_ps`?** 分支必须 divergent(像素着色器的 `%x` 是 per-pixel 的),否则 `UA.isUniformTerminator`(:146)拦截。我第一次用 `amdgpu_kernel` + `workitem.id` 时,虽然分支 divergent,但 PHI 因 `%x` 依赖被判定 divergent(`:104` 拦截)——必须用 **`inreg` 强制 uniform** 的 `%c` 作为 PHI 值,分支条件用 divergent 的 `%x`。

### 9.3.5 设计动机

GPU 的 structurized CFG(structurize 后的 if/loop)里,divergent 分支的汇合点 PHI 有特殊的寄存器分配语义:uniform PHI 分配**标量寄存器**(全 wave 共享一个值),divergent PHI 分配**向量寄存器**(每 lane 一个值)。undef 分支如果不处理,后端可能给"应该是标量"的 PHI 错误分配向量寄存器,或者标量寄存器被 undef 分支覆写。F11 通过**消除 undef**,让"唯一 defined 值"直接成为 PHI 的语义,后端寄存器分配就安全了。

### 9.3.6 昇腾启示

昇腾的 structurized 控制流(如 `if`/`else` 的 warp 收敛)有完全同构的问题。可借鉴:
- **undef/poison 是寄存器分配的大敌**:昇腾在处理"warp 分支汇合点"的 SSA 值时,undef 操作数必须显式改写,否则标量/向量寄存器分配会出错。
- **依赖 UniformityAnalysis + DominatorTree**:这是 GPU 特有的分析组合,昇腾也有对应设施,可直接复用此 pass 的算法骨架。

---

## 本章小结

| Pass | 核心动作 | 关键 gate | 输入形态 → 输出形态 |
|---|---|---|---|
| F3 CodeGenPrepare | 除法展开 / mul24 / fdiv 降精度 | `UseMul24Intrin` / `DisableIDivExpand` 等,uniform 乘法不替 mul24 | `udiv` → `rcp`+`fmul` 序列 |
| F5 LateCodeGenPrepare | sub-dword load 加宽 / 非法向量打包 | O1+,`hasScalarSubwordLoads` 反向 gate | `v3i32` PHI → 拆 scalar PHI + 重组 |
| F11 RewriteUndefForPHI | uniform PHI 的 undef → 唯一 defined 值 | StructurizeCFG/SIAnnotate 后,PHI 必须 uniform | `phi [poison, A], [%c, B]` → 直接用 `%c` |

**共同主题**:这三个 pass 都是**"为指令选择铺路"**——不追求减少 IR 指令数,而是消除后端处理不了/处理不好的形态(无硬件指令的除法、非法向量、undef 寄存器污染)。它们是中端与后端的**最后接缝**,过了这一关,IR 就交给 SelectionDAG/GlobalISel 了。
