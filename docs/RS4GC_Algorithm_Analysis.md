# RewriteStatepointsForGC 算法原理深度分析

## 1. 问题定义

### 1.1 核心问题

移动式 GC（Copying/Compacting/Mark-Compact）可在安全点（safepoint）移动堆中对象。对象移动后，指向该对象的指针变为悬垂指针（dangling pointer）。编译器必须：

1. **识别安全点**：每个可能触发 GC 的调用点
2. **报告活跃指针**：告诉 GC 哪些指针正在使用
3. **映射重定位**：GC 移动对象后，将旧指针更新为新指针

**RS4GC 的任务**：在 IR 层面将这三步显式化——把普通 `call`/`invoke` 转换为 `gc.statepoint` + `gc.relocate` + `gc.result`，使 GC 重定位语义在 IR 中可见。

### 1.2 为什么不能简单处理

```
%obj = load %p                    ; %obj 指向 GC 对象
%field = getelementptr %obj, 8    ; %field 是内部指针
call @foo()                       ; 安全点：GC 可能移动 %obj
                                  ; 此时 %obj 和 %field 都悬垂！
%val = load %field                ; BUG：使用了悬垂指针
```

直觉上，安全点后需要用"重定位后的版本"替换所有 GC 指针。但以下问题使这远非平凡：

1. **哪些指针活跃？** 需要跨基本块的数据流分析
2. **内部指针的基是谁？** `%field` 的基是 `%obj`，GC 只理解基对象
3. **PHI/Select 下的基推断**：多路径汇聚时，基指针可能不同，需要插入"基 PHI"
4. **何时替换？** 一个原始定义在多个安全点被重定位，替换涉及复杂的 SSA 更新
5. **属性失效**：安全点"释放整个堆"，任何暗示引用稳定性的属性都非法

---

## 2. 算法总览

```
runOnFunction(F):
  ┌─ 预处理 ─────────────────────────────────────────┐
  │ 1. 移除不可达块                                    │
  │ 2. 收集需重写的调用点 + gc.get.pointer.* intrinsics│
  │ 3. 折叠单入口 PHI（LCSSA 清理）                    │
  │ 4. 移动 ICmp 到安全点后（减少寄存器压力）           │
  │ 5. 规范化 scalar-to-vector GEP                     │
  │ 6. 内联 gc.get.pointer.base/offset                 │
  └──────────────────────────────────────────────────┘
  insertParsePoints(F):  ← 核心
  stripNonValidData(M):  ← 后处理
```

---

## 3. insertParsePoints：核心算法

**源码位置**：`RewriteStatepointsForGC.cpp:2647-2873`

### 3.1 执行流程

```
┌─────────────────────────────────────────────────────────────────────┐
│ Step A: 规范化 invoke 后继                                          │
│   若后继有多前驱 → SplitBlockPredecessors                           │
│   折叠单入口 PHI → 保证 gc.relocate 可插入块首                     │
├─────────────────────────────────────────────────────────────────────┤
│ Step B: 插入 deopt 使用持有者                                       │
│   在每个调用后插入 __tmp_use(deopt_GC_ptrs)                        │
│   → 保证 deopt 中的 GC 指针在活跃性分析中可见                       │
├─────────────────────────────────────────────────────────────────────┤
│ Step C: 活跃性分析 (findLiveReferences)                             │
│   标准后向数据流 → 每个调用点的活跃 GC 指针集合                     │
├─────────────────────────────────────────────────────────────────────┤
│ Step D: 基指针推断 (findBasePointers)                               │
│   对每个活跃指针找其基指针 ← 最复杂的部分                          │
│   deopt 中的 GC 指针视为自身的基（优化）                            │
├─────────────────────────────────────────────────────────────────────┤
│ Step E: 插入基指针使用持有者                                        │
│   基 PHI 插入引入新的活跃值 → 在安全点后插入 __tmp_use(bases)      │
├─────────────────────────────────────────────────────────────────────┤
│ Step F: 重算活跃性 (recomputeLiveInValues)                          │
│   基 PHI 改变了 IR → 重跑数据流                                    │
├─────────────────────────────────────────────────────────────────────┤
│ Step G: 移除常量基指针                                              │
│   常量基指针不会移动 → 从活跃集中删除                               │
├─────────────────────────────────────────────────────────────────────┤
│ Step H: 移除使用持有者                                              │
├─────────────────────────────────────────────────────────────────────┤
│ Step I: 重物化优化                                                  │
│   I-1: findRematerializationCandidates                            │
│   I-2: rematerializeLiveValuesAtUses  ← 在使用处重物化              │
│   I-3: rematerializeLiveValues         ← 在安全点后重物化           │
├─────────────────────────────────────────────────────────────────────┤
│ Step J: 创建 statepoint (makeStatepointExplicit)                   │
│   gc.statepoint + gc.relocate + gc.result                         │
├─────────────────────────────────────────────────────────────────────┤
│ Step K: 执行延迟替换 (DeferredReplacement::doReplacement)           │
├─────────────────────────────────────────────────────────────────────┤
│ Step L: relocationViaAlloca                                         │
│   通过 alloca + mem2reg 更新所有 GC 指针的使用                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. 活跃性分析

### 4.1 数据流方程

标准**后向数据流**，分析 GC 指针的活跃性：

```
KillSet(B):  B 中定义的 GC 指针值
LiveSet(B):  B 中使用的 GC 指针值（排除块内 kill）
LiveIn(B) = (LiveSet(B) ∪ LiveOut(B)) \ KillSet(B)
LiveOut(B) = ∪ { LiveIn(S) | S ∈ successors(B) }
```

### 4.2 关键实现细节

**常量排除**（`RewriteStatepointsForGC.cpp:3205-3216`）：

```cpp
if (isHandledGCPointerType(V->getType(), GC) && !isa<Constant>(V)) {
    LiveTmp.insert(V);
}
```

所有常量（包括全局地址、null、undef、常量表达式）不参与活跃性分析。原因：
1. 常量地址不会在运行时移动（如全局变量地址固定）
2. 优化器可能在不可达代码中插入任意 `inttoptr` 常量

**PHI 使用处理**：PHI 的操作数不计入 `LiveSet`（在 `LiveOut` 种子阶段处理）——通过 `computeLiveOutSeed` 扫描后继块的 PHI 入值。

**安全点处的活跃集**（`findLiveSetAtInst`）：

```
从 LiveOut[BB] 出发，从块末反向扫描到 Inst 位置
应用 kill/use 逻辑
移除 Inst 本身
结果 = 该点的活跃 GC 指针集合
```

### 4.3 为什么需要两次活跃性分析

**第一次**（Step C）：计算原始 IR 的活跃性
**第二次**（Step F）：基指针推断可能插入新的基 PHI 指令，这些指令成为新的定义和使用，改变了活跃集

```
示例:
loop:
  %p = phi ...                    ← 原始 PHI
  %gep = getelementptr %p, 8
  safepoint                       ← Step C: %gep 活跃
  br loop

基指针推断发现 %p 需要基 PHI:
loop:
  %p.base = phi ...               ← 新插入的基 PHI
  %p = phi ...
  %gep = getelementptr %p, 8
  safepoint                       ← Step F: %p.base 也活跃！
  br loop
```

---

## 5. 基指针推断——算法核心

### 5.1 问题定义

给定一个活跃的 GC 指针 `derived`，找到其**基指针** `base`：
- 基指针是 GC 对象的起始地址
- 派生指针可能是 GEP 偏移后的内部指针
- GC 理解基对象，通过基对象重定位后重新计算派生指针

### 5.2 两层算法结构

```
findBasePointer(I):
  Def = findBaseOrBDV(I)                    ← 第1层：找基定义值(BDV)
  if isKnownBase(Def) && type_matches(Def, I)
    return Def                               ← 已知基，直接返回
  runLatticeFixpoint(Def)                    ← 第2层：格不动点算法
```

### 5.3 第1层：查找基定义值（findBaseDefiningValue）

递归函数，沿 def-use 链向上查找，直到遇到"定义基的值"或"阻断点"：

```
findBaseDefiningValue(V):
```

| 值类型 | 返回 | isKnownBase | 原理 |
|--------|------|:-----------:|------|
| `Argument` | V | ✓ | 函数参数是基（ABI 约定） |
| `Constant` | `ConstantPointerNull` | ✓ | 所有常量共享 null 基；常量不移动 |
| `IntToPtrInst` | V | ✓ | 语义不明，保守视为基 |
| `CastInst`(非 IntToPtr) | BDV(`stripPointerCasts(V)`) | 继承 | 透传类型转换 |
| `LoadInst` | V | ✓ | 加载的指针就是基 |
| `CallInst`/`InvokeInst` | V | ✓ | 假设函数返回基指针 |
| `ExtractValueInst` | V | ✓ | 字段加载 = 基 |
| `AtomicCmpXchgInst` | V | ✓ | 类似 load |
| `GEP` | BDV(`pointer_operand`) | 继承 | GEP 的基 = 指针操作数的基 |
| `FreezeInst` | BDV(`operand`) | 继承 | 传递性 |
| **`PHINode`** | V | ✗ | **合并点**：多路径汇聚，需推断 |
| **`SelectInst`** | V | ✗ | **合并点**：条件选择，需推断 |
| `ExtractElementInst` | V | ✗ | 向量→标量提取=合并 |
| `InsertElementInst` | V | ✗ | 向量插入=合并 |
| `ShuffleVectorInst` | V | ✗ | 向量洗牌=合并 |

**设计原理**：
- GEP/Cast/Freeze 是"透明"的：基指针关系沿操作数传递
- PHI/Select/Vector ops 是"不透明"的：需要推断基，因为不同路径可能有不同基

### 5.4 第2层：格不动点算法

#### 5.4.1 格定义

```
        Unknown           (顶 — 初始状态)
       /  |  |  \
     b1  b2  b3  b4       (Base — 已知具体基值 b)
       \  |  |  /
        Conflict          (底 — 多个不同基汇聚，需插入基指令)
```

**`BDVState`**（`RewriteStatepointsForGC.cpp:692-791`）：

```cpp
class BDVState {
  StatusTy Status;    // Unknown | Base | Conflict
  Value *BaseValue;   // 非 null 仅当 Status == Base
};
```

#### 5.4.2 meet 操作（`BDVState::meet`，行 727-755）

```cpp
void meet(const BDVState &Other) {
  if (isConflict())   return;                    // Conflict 是不动点
  if (isUnknown())   { *this = Other; return; }  // 取 Other
  if (Other.isUnknown())   return;               // 保持当前
  if (Other.isConflict())  { markConflict(); return; }
  // 都是 Base
  if (getBaseValue() != Other.getBaseValue())
    markConflict();                               // 不同基 → Conflict
  // 相同基 → 不变
}
```

meet 运算表：

| 当前 \ Other | Unknown | Base(b) | Conflict |
|:---:|:---:|:---:|:---:|
| **Unknown** | Unknown | Base(b) | Conflict |
| **Base(b1)** | Base(b1) | Base(b1) if b1==b2, else Conflict | Conflict |
| **Conflict** | Conflict | Conflict | Conflict |

**格性质**：单调递减——状态只能从 Unknown→Base→Conflict 方向变化，保证终止。

#### 5.4.3 算法步骤

**Phase 1: 收集 BDV**（行 884-909）

```
Worklist = [Def]
States = {Def: Unknown}

while Worklist 非空:
  Current = Worklist.pop()
  对 Current 的每个操作数 Op:
    Base = findBaseOrBDV(Op)
    if isKnownBase(Base) && type_matches(Base, Op):
      continue  // 已知基，不需推断
    if Base ∉ States:
      States[Base] = Unknown
      Worklist.push(Base)
```

DFS 遍历 def-use 图，收集所有需要推断基的 BDV。

**Phase 2: 剪枝平凡可解的 BDV**（行 924-954）

```
do:
  ToRemove = []
  for BDV in States:
    if BDV 的每个操作数 Op:
      Op 的基要么是 BDV 自身（PHI 自环）
      要么 Op 的基不在 States 中（已解析为基）
    then: ToRemove.push(BDV)
  for V in ToRemove:
    States.erase(V)
    Cache[V] = V  // V 自身就是基
while !ToRemove.empty()

if Def ∉ States: return Def  // 已证明是基
```

**优化**：若 BDV 的所有输入都来自自身或已知的基，则 BDV 自身也是基。避免不必要的格迭代。

**Phase 3: 格不动点迭代**（行 1008-1051）

```
Progress = true
while Progress:
  Progress = false
  for (BDV, OldState) in States:
    NewState = Unknown
    for Op in BDV.operands:
      OpBDV = findBaseOrBDV(Op)
      OpState = States[OpBDV] if OpBDV in States else Base(OpBDV)
      NewState.meet(OpState)
    if MarkConflict(BDV, NewState.BaseValue):
      NewState = Conflict  // 向量/标量类型不匹配强制 Conflict
    if NewState != OldState:
      States[BDV] = NewState
      Progress = true
```

**关键**：`MarkConflict` 检查类型兼容性。即使 BDV 的所有操作数有相同基，若基的类型（向量 vs 标量）与 BDV 不匹配，仍需 Conflict → 插入并行基指令。

**Phase 4: 为 Conflict 插入基指令**（行 1076-1118）

```
for (BDV, State) in States:
  if !State.isConflict(): continue

  BaseInst = BDV->clone()
  BaseInst->insertBefore(BDV)
  BaseInst->setName(BDV->getName() + ".base")
  BaseInst->setMetadata("is_base_value", MDNode::get(...))

  States[BDV] = Conflict(BaseInst)
  setKnownBase(BaseInst, true)
```

**核心思想**：为每个 Conflict BDV 创建**并行指令**，跟踪基指针的流动：

```
原始:                          推断后:
  %p = phi [gep(obj1,8)],      %p.base = phi [obj1], [obj2]  ← 新插入
       [gep(obj2,16)]          %p = phi [gep(obj1,8)],
                                    [gep(obj2,16)]
```

基 PHI 的入值在 Phase 5 填充。

**Phase 5: 填充基指令操作数**（行 1154-1247）

```
for (BDV, State) in States:
  if !State.isConflict(): continue
  BaseInst = State.getBaseValue()

  switch BDV 类型:
    PHINode:
      for 每个入边 (InVal, InBB):
        BasePHI->setIncomingValue(i, getBaseForInput(InVal, InBB->getTerminator()))
        // 同一 InBB 的多个入值使用缓存的基（避免重复 BitCast）

    SelectInst:
      BaseSI->setTrueValue(getBaseForInput(SI.getTrueValue(), BaseSI))
      BaseSI->setFalseValue(getBaseForInput(SI.getFalseValue(), BaseSI))

    ExtractElementInst:
      BaseEE->setOperand(0, getBaseForInput(EE.getVectorOperand(), BaseEE))

    InsertElementInst:
      BaseIE->setOperand(0, getBaseForInput(IE.getOperand(0), BaseIE))  // vector
      BaseIE->setOperand(1, getBaseForInput(IE.getOperand(1), BaseIE))  // scalar

    ShuffleVectorInst:
      BaseSV->setOperand(0, getBaseForInput(SV.getOperand(0), BaseSV))
      if !SV.isZeroEltSplat():
        BaseSV->setOperand(1, getBaseForInput(SV.getOperand(1), BaseSV))
      else:
        BaseSV->setOperand(1, PoisonValue)  // 广播模式，第二操作数无关
```

**`getBaseForInput`**（行 1132-1149）：

```cpp
auto getBaseForInput = [&](Value *Input, Instruction *InsertPt) {
  Value *BDV = findBaseOrBDV(Input);
  Value *Base;
  if (!States.count(BDV))
    Base = BDV;              // BDV 已是基
  else
    Base = States[BDV].getBaseValue();  // 使用推断出的基
  if (Base->getType() != Input->getType() && InsertPt)
    Base = new BitCastInst(Base, Input->getType(), InsertPt);
  return Base;
};
```

**Phase 6: 更新缓存**（行 1259-1284）

```
for (BDV, State) in States:
  Cache[BDV] = State.getBaseValue()
return Cache[Def]
```

### 5.5 完整示例

```llvm
; 原始 IR
entry:
  %obj1 = load %p1
  %obj2 = load %p2
  br loop

loop:
  %p = phi [%obj1, %entry], [%p_next, %loop]
  %field = gep %p, 8
  call @foo()  ; 安全点
  %p_next = gep %p, 16
  br loop
```

**Step 1: findBaseDefiningValue(%field)**
- %field 是 GEP → BDV = findBaseDefiningValue(%p)
- %p 是 PHI → BDV = %p (自身，isKnownBase=false)
- 返回 %p

**Step 2: 收集 BDV**
- %p 的操作数: %obj1 (已知基) 和 %p_next
- findBaseDefiningValue(%p_next) → GEP → BDV = findBaseDefiningValue(%p) → %p
- %p 已在 States 中，不需重复
- States = {%p: Unknown}

**Step 3: 剪枝**
- %p 的操作数 %obj1 是已知基，%p_next 的基是 %p（自环）→ 似乎可剪枝？
- 但 %p 的两个输入基不同（%obj1 vs %p 自身）→ 不能剪枝
- 实际上：%p_next 的基是 %p（自环），而 %obj1 的基是 %obj1 本身
- PHI 的操作数基不同 → 需要推断

**Step 4: 格迭代**
- %p 的操作数: %obj1 (Base=%obj1) 和 %p (自环，在 States 中 = Unknown)
- 第一次: NewState = Base(%obj1) meet Unknown = Base(%obj1)
- 但 %p 的入值 %p_next 的基是 %p 本身（自环），%p 现在是 Base(%obj1)
- 第二次: NewState = Base(%obj1) meet Base(%obj1) = Base(%obj1) ✓

**结果**: %p 的基是 %obj1，无需插入基 PHI。

**更复杂的 Conflict 示例**：

```llvm
entry:
  %obj1 = load %p1
  %obj2 = load %p2
  %cond = ...
  br %cond, %bb1, %bb2

bb1:
  br %merge

bb2:
  br %merge

merge:
  %p = phi [%obj1, %bb1], [%obj2, %bb2]   ; 两个不同基！
  %field = gep %p, 8
  call @foo()  ; 安全点
```

**Step 4**: %p 的操作数基: %obj1 和 %obj2 → Base(%obj1) meet Base(%obj2) = **Conflict**

**Step 5: 插入基 PHI**:

```llvm
merge:
  %p.base = phi [%obj1, %bb1], [%obj2, %bb2]  ; 新插入！
  %p = phi [%obj1, %bb1], [%obj2, %bb2]
  %field = gep %p, 8
  call @foo()  ; 安全点: %p.base 和 %p 都必须活跃
```

GC 重定位 %obj1→%obj1' 和 %obj2→%obj2' 后，`%p.base` 也被重定位，其值自动正确。

---

## 6. 重物化优化

### 6.1 动机

活跃集越大，`gc.relocate` 越多，运行时开销越大。许多派生指针是 GEP/cast 的简单链，可以在安全点后廉价重算，无需通过 `gc.relocate` 传递。

### 6.2 可重物化链

`findRematerializableChainToBasePointer`（行 2264-2285）：

```
从 derived 向 base 递归回溯:
  GEP:       加入链，继续回溯 pointer operand
  no-op Cast: 加入链，继续回溯 operand
  其他:      停止，返回当前值作为链根
```

**仅 GEP 和 no-op Cast 可重物化**——因为它们不引入新指针依赖。

### 6.3 代价模型

`chainToBasePointerCost`（行 2289-2321）：

| 指令 | 代价 |
|------|------|
| no-op Cast | `TTI.getCastInstrCost(...)` |
| GEP | `TTI.getAddressComputationCost()` + 2 × 非常量索引数 |

阈值: `spp-rematerialization-threshold = 6`

### 6.4 两种策略

**策略 1：在使用处重物化**（`rematerializeLiveValuesAtUses`，行 2413-2527）

```
盈利条件: NumLiveStatepoints > NumUses
  （跨过的安全点数 > 使用数 → 重物化比重定位更便宜）
或: NumLiveStatepoints == NumUses && Cost == 0
  （代价为零时，缩短活跃范围总是好的）

动作: 在每个用户前克隆链，替换使用
```

**策略 2：在安全点后重物化**（`rematerializeLiveValues`，行 2533-2597）

```
对每个安全点的每个活跃值:
  if 是候选 && Cost < threshold:
    Invoke: Cost × 2（正常+异常路径各需一份）
    从活跃集中移除该值
    在安全点后克隆链:
      链根替换为 PointerToBase[LiveValue]（重定位后的基指针）
    记录到 Info.RematerializedValues
```

**`rematerializeChain` 实现**（行 1367-1417）：

```
逆序遍历链（top-most 先）:
  Clone = Instr->clone()
  Clone->insertBefore(InsertBefore)
  if 不是链中第一条:
    Clone->replaceUsesOfWith(LastValue, LastClonedValue)
  if 是第一条:
    Clone->replaceUsesOfWith(RootOfChain, AlternateLiveBase)
    // AlternateLiveBase = 重定位后的基指针
```

### 6.5 完整示例

```llvm
; 重物化前:
  %obj = load %p
  %field = gep %obj, 8      ; 派生指针
  call @foo()                ; 安全点
  %val = load %field         ; 使用

; 重物化后:
  %obj = load %p
  call @foo()                ; 安全点
  %obj' = gc.relocate(token, 0, 0)  ; 重定位基指针
  %field' = gep %obj', 8     ; 重物化！而非 gc.relocate
  %val = load %field'
```

---

## 7. Statepoint 创建

### 7.1 makeStatepointExplicitImpl

**源码位置**：行 1641-1927

```
1. 确定参数:
   StatepointID    ← 函数属性 "statepoint-id"（默认 0xABCDEF00）
   NumPatchBytes   ← 函数属性 "statepoint-num-patch-bytes"
   Flags           ← GCTransition | DeoptLiveIn
   CallArgs        ← 原始调用参数
   DeoptArgs       ← "deopt" 操作数包
   TransitionArgs  ← "gc-transition" 操作数包
   GCArgs          ← 活跃 GC 指针列表（含基指针）

2. 特殊降低:
   a) llvm.experimental.deoptimize
      → 替换为 __llvm_deoptimize(void, ...args...) + unreachable
      → DeferredReplacement::createDeoptimizeReplacement

   b) 原子 memcpy/memmove
      → 替换为 __llvm_memcpy_element_unordered_atomic_safepoint_N
      → 参数重组:
         (dest_derived, src_derived, len, elem_size)
         → (dest_base, dest_offset, src_base, src_offset, len, elem_size)
      → GetBaseAndOffset: 基指针 + ptrtoInt(sub) 得到偏移

3. 创建 gc.statepoint:
   CallInst  → Builder.CreateGCStatepointCall(...)
   InvokeInst → Builder.CreateGCStatepointInvoke(...)
   继承: calling convention, tail call kind
   属性: legalizeCallAttributes → 剥离 Memory/NoSync/NoFree，传递参数属性

4. 创建 gc.result (非 void, 非 deoptimize):
   Builder.CreateGCResult(Token, ReturnType)
   传递原始调用的返回属性
   → DeferredReplacement::createRAUW(OldCall, GCResult)
   // 不能立即 RAUW：OldCall 可能在其他安全点的活跃集中

5. 创建 gc.relocate:
   CreateGCRelocates(LiveVariables, BasePtrs, Token, Builder)
   对每个活跃值:
     gc.relocate(Token, BaseIdx, LiveIdx)
     // 索引是 GCArgs 向量中的位置
     // 类型规范化: 统一为 i8 addrspace(N)* 以避免 mangling 问题
     // 后续 BitCast 恢复原始类型
     // 标记 CallingConv::Cold → 提示寄存器分配器

   Invoke: 额外在 unwind 路径创建一组 gc.relocate
           (绑定到 landing pad token)
```

### 7.2 操作数布局

```
gc.statepoint:
  操作数: ID, NumPatchBytes, Callee, NumCallArgs, Flags,
          CallArgs...,
          [gc_transition bundle args],
          [deopt bundle args],
          [gc_live bundle args: 所有活跃 GC 指针]

gc.relocate(statepoint_token, BaseIdx, DerivedIdx):
  BaseIdx/DerivedIdx 是 gc_live 参数列表中的索引
  同一基指针的多个派生指针共享同一个 BaseIdx

gc.result(statepoint_token):
  提取原始调用的返回值
```

### 7.3 DeferredReplacement

```cpp
class DeferredReplacement {
  AssertingVH<Instruction> Old;
  AssertingVH<Instruction> New;
  bool IsDeoptimize;

  void doReplacement() {
    if (NewI) OldI->replaceAllUsesWith(NewI);
    if (IsDeoptimize) {
      // 替换 return 为 unreachable
      new UnreachableInst(RI->getContext(), RI->getIterator());
      RI->eraseFromParent();
    }
    OldI->eraseFromParent();
  }
};
```

**为什么延迟替换？** 原始调用 `Old` 可能出现在其他安全点的活跃集中（作为活跃 GC 指针）。立即 RAUW 会使这些指针失效。所有安全点处理完毕后才统一替换。

---

## 8. relocationViaAlloca

### 8.1 问题

创建 `gc.relocate` 后，需要将所有对**原始 GC 指针**的使用更新为**重定位后的指针**。但一个原始定义可能在多个安全点被重定位，使用点跨越多条路径：

```
%obj = load %p
call @foo()            ; safepoint1 → %obj.relocated1
%v1 = use %obj         ; 应使用 %obj.relocated1
call @bar()            ; safepoint2 → %obj.relocated2
%v2 = use %obj         ; 应使用 %obj.relocated2
```

直接 RAUW 无法表达"在不同位置使用不同重定位版本"。

### 8.2 解决方案：alloca + mem2reg

**核心思想**：为每个活跃 GC 指针创建一个 alloca 作为"最新值容器"，在不同点存储不同版本，最后用 mem2reg 提升回 SSA。

```
Step 1: 创建 alloca
  对每个活跃 GC 指针 V:
    alloca V.type → AllocaMap[V]

  对每个重物化值的原始值:
    alloca V.type → AllocaMap[OriginalValue]

Step 2: 在重定位点插入 store
  对每个 gc.relocate Reloc:
    store Reloc → AllocaMap[Reloc.getDerivedPtr()]
    // 在 gc.relocate 的下一条指令前

  对每个重物化值 Remat:
    store Remat → AllocaMap[OriginalValue]

  调试模式 (EXPENSIVE_CHECKS):
    对未重定位的 alloca 存入 null/poison
    → 将使用-after-relocation bug 转为 SEGV

Step 3: 在使用点插入 load
  对 AllocaMap 中每个 (Def, Alloca):
    收集 Def 的所有使用
    对每个使用 Use:
      if Use 是 PHI:
        在前驱块末尾: Load = load Alloca
        PHI.setIncomingValue(i, Load)
      else:
        在 Use 前: Load = load Alloca
        Use.replaceUsesOfWith(Def, Load)

Step 4: 存储初始定义
  if Def 是 Argument:
    store Def → Alloca  (在 alloca 后)
  if Def 是 InvokeInst:
    store Def → Alloca  (在正常目标块首)
  else (普通指令):
    store Def → Alloca  (在定义后)

Step 5: mem2reg (PromoteMemToReg)
  将所有 alloca/load/store 提升为 SSA
  自动插入必要的 PHI 节点
```

### 8.3 为什么 mem2reg 有效

mem2reg 是 LLVM 的标准优化，将简单的 load/store 模式提升为 SSA：

```
; 提升前:
  %a = alloca ptr
  store %obj, %a
  call @foo()
  store %obj.reloc, %a
  %v1 = load %a       ; → %obj.reloc

; 提升后:
  %obj.reloc1 = gc.relocate(...)
  ; %v1 直接使用 %obj.reloc1
```

mem2reg 正确处理：
- 多个 store 点（多个安全点重定位）
- PHI 节点（路径合并时选择正确的重定位版本）
- 支配关系（确保 SSA 形式正确）

### 8.4 完整数据流示例

```llvm
; 原始 IR:
  %obj = load %p
  call @foo()
  %val = load %obj

; Step 1: 创建 alloca
  %alloca = alloca ptr

; Step 2-4: 插入 store/load
  %obj = load %p
  store %obj, %alloca                    ; 初始定义
  %token = gc.statepoint(...)
  %obj.reloc = gc.relocate(%token, 0, 0)
  store %obj.reloc, %alloca              ; 重定位后存储
  %tmp = load %alloca                    ; 使用前加载
  %val = load %tmp

; Step 5: mem2reg 后:
  %obj = load %p
  %token = gc.statepoint(...)
  %obj.reloc = gc.relocate(%token, 0, 0)
  %val = load %obj.reloc                 ; 直接使用重定位值
```

---

## 9. 属性剥离

### 9.1 原理

`gc.statepoint` 语义上"释放整个堆"——因为 GC 可以移动或释放任何堆对象。因此，任何暗示以下性质的属性/元数据都不再有效：

- **引用稳定性**：`dereferenceable`, `dereferenceable_or_null`
- **内存不变性**：`readonly`, `readnone`, `writeonly`, `invariant.start`, `invariant.load`
- **指针不别名**：`noalias`
- **无副作用**：`nofree`, `nosync`, `Memory`

### 9.2 两阶段剥离

**`stripNonValidAttributesFromPrototype`**（行 2890-2913）：函数声明/定义
- Intrinsic：重置为 `Intrinsic.td` 定义的属性
- 非Intrinsic：从指针参数和返回值移除无效属性；移除 Memory/NoSync/NoFree 函数属性

**`stripNonValidDataFromBody`**（行 2946-2992）：函数体
- `invariant.start` → 替换为 poison 并删除
- TBAA 标签 → 转为可变形式（`createMutableTBAAAccessTag`）
- Load/Store 元数据 → 仅保留 `tbaa, range, alias_scope, nontemporal, nonnull, align, type`
  移除 `dereferenceable, noalias, invariant.load, invariant.group`
- 调用点属性 → 同函数声明处理

### 9.3 为什么 TBAA 需要转为可变

不可变 TBAA 允许优化器将 load 下沉过 call。但安全点可能改变堆内容，load 不能下沉过 `gc.statepoint`。将 TBAA 转为可变形式阻止此优化。

---

## 10. 预处理优化

### 10.1 移动 ICmp 到安全点后

**源码位置**：行 3114-3130

```
; 移动前:
  %cmp = icmp eq %obj, null
  call @foo()          ; 安全点
  br %cmp, ...

; 移动后:
  call @foo()          ; 安全点
  %cmp = icmp eq %obj, null    ; 比较移到安全点后
  br %cmp, ...
```

**原理**：若 ICmp 在安全点前执行，则需要同时持有 %obj 的前/后重定位版本（比较用旧的，后续用新的）。移动后，只需持有重定位版本。

**限制**：仅处理单使用 ICmp + 条件分支。

### 10.2 规范化 scalar-to-vector GEP

**源码位置**：行 3132-3157

```
; GEP 的指针操作数是标量，索引是向量:
  %gep = getelementptr scalar_ptr, <vector_index>

; 规范化为全向量 GEP:
  %splat = vector_splat(scalar_ptr)
  %gep = getelementptr %splat, <vector_index>
```

**原因**：基指针推断代码不能正确处理标量指针+向量索引的 GEP。通过 splat 使指针操作数变为向量，统一处理。

---

## 11. 算法复杂度与性能考量

### 11.1 各阶段复杂度

| 阶段 | 复杂度 | 备注 |
|------|--------|------|
| 活跃性分析 | O(N×B²) | N=GC指针数, B=基本块数，工作列表传播 |
| 基指针推断 (每个指针) | O(V×I) | V=BDV数, I=每次meet迭代 |
| 基指针推断 (全函数) | O(P×V×I) | P=活跃指针数 |
| 重物化 | O(P×C) | C=链长度（≤10） |
| Statepoint 创建 | O(P×S) | S=安全点数 |
| relocationViaAlloca | O(P×U) | U=每指针使用数 |
| mem2reg | O(A×D) | A=alloca数, D=支配树深度 |

### 11.2 性能优化

1. **基指针缓存**（`DefiningValueMapTy`）：跨调用点共享推断结果
2. **deopt 指针优化**：deopt 中的 GC 指针视为自身基，跳过推断
3. **常量排除**：常量不参与活跃性分析和基指针推断
4. **剪枝阶段**：在格迭代前移除平凡可解的 BDV
5. **延迟替换**：避免迭代器失效和悬挂指针

### 11.3 已知限制

1. **不支持 gc.root 交互**：`findBaseDefiningValue` 中 `llvm_unreachable`
2. **不支持重复 RS4GC**：遇到 `gc.relocate` 会 `llvm_unreachable`
3. **向量处理不完善**：scalar-to-vector GEP 需要 workaround
4. **格迭代无工作列表**：TODO 注释指出可用工作列表加速

---

## 12. 关键数据结构汇总

| 结构 | 定义位置 | 用途 |
|------|---------|------|
| `GCPtrLivenessData` | 行 168 | 四组映射：KillSet/LiveSet/LiveIn/LiveOut |
| `DefiningValueMapTy` | 行 195 | 双重缓存：BDV关系 + 基指针关系 |
| `IsKnownBaseMapTy` | 行 196 | 值是否已知为基指针 |
| `PointerToBaseTy` | 行 197 | 活跃指针 → 基指针映射 |
| `BDVState` | 行 692 | 格元素：Unknown/Base(b)/Conflict |
| `PartiallyConstructedSafepointRecord` | 行 202 | 每个安全点的中间状态 |
| `RematerizlizationCandidateRecord` | 行 220 | 重物化候选：链 + 根 + 代价 |
| `DeferredReplacement` | 行 1561 | 延迟 RAUW/删除操作 |
| `StatepointDirectives` | Statepoint.h | 函数属性中的 statepoint 控制信息 |
