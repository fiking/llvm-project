# RS4GC 活跃性分析详细分析

## 1. 活跃性分析在 RS4GC 中的角色

RS4GC 需要回答核心问题：**在每个安全点（safepoint），哪些 GC 指针是活跃的？**

只有活跃的 GC 指针才需要：
1. 报告给 GC 运行时（通过 `gc.statepoint` 的 `gc-live` 操作数包）
2. 生成 `gc.relocate` 获取重定位后的指针

遗漏活跃指针 → GC 不知道该对象正在使用 → 对象被错误回收。
多报活跃指针 → 不影响正确性，但增加运行时开销。

因此 RS4GC 采用**保守（sound but incomplete）**策略：宁可多报，不可遗漏。

---

## 2. 数据结构

```cpp
struct GCPtrLivenessData {
  MapVector<BasicBlock *, SetVector<Value *>> KillSet;   // 块内定义的 GC 指针
  MapVector<BasicBlock *, SetVector<Value *>> LiveSet;   // 块内向上暴露的使用（排除 kill）
  MapVector<BasicBlock *, SetVector<Value *>> LiveIn;    // 活跃入块
  MapVector<BasicBlock *, SetVector<Value *>> LiveOut;   // 活跃出块
};
```

四个集合的逻辑关系：

```
              ┌─────────────────────────────────┐
              │         BasicBlock B             │
              │                                  │
  LiveIn(B) ──┤  KillSet(B)  LiveSet(B)         ├── LiveOut(B)
              │                                  │
              └─────────────────────────────────┘
                    ↓               ↑
                  定义            使用
              (从活跃集中移除)   (加入活跃集)
```

---

## 3. GC 指针类型识别

活跃性分析只关心**GC 管理的指针类型**。三个层次的判断函数：

### 3.1 isGCPointerType

```cpp
static bool isGCPointerType(Type *T, GCStrategy *GC) {
  if (!isa<PointerType>(T))
    return false;
  return GC->isGCManagedPointer(T).value_or(true);  // 未知时保守为 true
}
```

**保守策略**：若 `isGCManagedPointer` 返回 `nullopt`（无法判断），则视为 GC 指针。宁可多报。

对于 Statepoint/CoreCLR 策略：`addrspace(1)*` → true，其他 → false。

### 3.2 isHandledGCPointerType

```cpp
static bool isHandledGCPointerType(Type *T, GCStrategy *GC) {
  if (isGCPointerType(T, GC))
    return true;
  if (auto VT = dyn_cast<VectorType>(T))
    if (isGCPointerType(VT->getElementType(), GC))
      return true;
  return false;
}
```

支持的类型：
- 标量 GC 指针：`ptr addrspace(1)`
- 向量 GC 指针：`<N x ptr addrspace(1)>`

### 3.3 isUnhandledGCPointerType

```cpp
static bool isUnhandledGCPointerType(Type *Ty, GCStrategy *GC) {
  return containsGCPtrType(Ty, GC) && !isHandledGCPointerType(Ty, GC);
}
```

检测到但无法处理的类型（如包含 GC 指针的结构体/数组）。遇到时触发 assert。

**设计决策**：不支持一级聚合（first-class aggregate）中的 GC 指针——这会大幅增加实现复杂度。

---

## 4. 常量排除策略

活跃性分析**排除所有常量**，这是两个独立原因的交汇：

### 4.1 语义原因

```cpp
// computeLiveInValues (块内扫描) 中:
if (isHandledGCPointerType(V->getType(), GC) && !isa<Constant>(V)) {
    LiveTmp.insert(V);
}
```

**原因 1：常量不会移动**

> We assume that things which are constant (from LLVM's definition) do not move
> at runtime. For example, the address of a global variable is fixed, even
> though its contents may not be.

- `@global` 的地址在编译期固定，GC 不会移动全局变量本身
- `null` / `undef` / `poison` 无需重定位
- 常量表达式（如 `bitcast i64 0 to ptr`）地址固定

**原因 2：优化器可能注入任意常量**

> Optimization passes are free to locally exploit facts without respect to
> global reachability. This can create sections of code which are dynamically
> unreachable and contain just about anything.

```llvm
; 优化器在不可达代码中可能插入:
  %dead = inttoptr i64 42 to ptr addrspace(1)
```

这种 `inttoptr` 常量不是语言前端的 GC 对象，不应参与活跃性分析。

### 4.2 在 findBaseDefiningValue 中的协同

常量在基指针推断中有特殊处理：

```cpp
if (isa<Constant>(I)) {
    auto *CPN = ConstantPointerNull::get(cast<PointerType>(I->getType()));
    Cache[I] = CPN;
    return CPN;   // 所有常量共享 null 基
}
```

所有常量共享 `ConstantPointerNull` 作为基。这意味着：
- 常量之间不会产生 Conflict（因为基相同）
- `phi (const1, const2)` 的基是 null → 不会触发基 PHI 插入

### 4.3 活跃集过滤中的二次排除

在 `insertParsePoints` 的 Step G 中：

```cpp
for (auto &Info : Records) {
    Info.LiveSet.remove_if([&](Value *LiveV) {
        return isa<Constant>(PointerToBase[LiveV]);
    });
}
```

即使活跃性分析本身排除了常量，**基指针推断后的基可能是常量**（如 GEP 全局变量的偏移）。这些也必须从活跃集中移除，因为：
1. 常量基不会移动，不需要报告给 GC
2. `relocationViaAlloca` 代码假设基在活跃集中——常量基不在其中

---

## 5. 块内活跃性计算（computeLiveInValues 块级）

### 5.1 算法

```cpp
static void computeLiveInValues(
    BasicBlock::reverse_iterator Begin,   // 从块末开始
    BasicBlock::reverse_iterator End,     // 扫描到某个位置
    SetVector<Value *> &LiveTmp,          // 输入: LiveOut(BB)，输出: 扫描位置的活跃集
    GCStrategy *GC)
{
  for (auto &I : make_range(Begin, End)) {
    // KILL: 此指令定义的 GC 指针从活跃集中移除
    LiveTmp.remove(&I);

    // PHI 的使用不在此时处理——由 LiveOut seed 负责
    if (isa<PHINode>(I))
      continue;

    // USE: 此指令使用的 GC 指针加入活跃集
    for (Value *V : I.operands()) {
      if (isHandledGCPointerType(V->getType(), GC) && !isa<Constant>(V)) {
        LiveTmp.insert(V);
      }
    }
  }
}
```

### 5.2 执行语义

**反向扫描**从块末到指定位置，模拟数据流：

```
假设块 B:
  %a = load %p           ; def %a
  %b = gep %a, 8          ; def %b, use %a
  %c = load %b            ; def %c, use %b
  call @foo()             ; 安全点
  %d = load %a            ; use %a

反向扫描从 call @foo() 到块首:
  Step 1: 扫描 %d = load %a → use %a → LiveTmp = {%a}
  Step 2: 扫描 %c = load %b → kill %c, use %b → LiveTmp = {%a, %b}
  Step 3: 扫描 %b = gep %a, 8 → kill %b, use %a → LiveTmp = {%a}  (%a 已在，无变化)
  Step 4: 扫描 %a = load %p → kill %a → LiveTmp = {}

结果: call @foo() 处无 GC 指针活跃（因为 %a 被 kill，%b 也被 kill）
```

### 5.3 PHI 使用不在此处理

```cpp
if (isa<PHINode>(I))
    continue;
```

**原因**：PHI 的操作数属于前驱块，不属于当前块。若在此处将 PHI 入值加入 LiveSet，会导致前驱块不必要地持有这些值。

PHI 的贡献通过 `computeLiveOutSeed` 处理（见第 6 节）。

---

## 6. LiveOut 种子化（computeLiveOutSeed）

### 6.1 算法

```cpp
static void computeLiveOutSeed(BasicBlock *BB, SetVector<Value *> &LiveTmp,
                                GCStrategy *GC) {
  for (BasicBlock *Succ : successors(BB)) {
    for (auto &I : *Succ) {
      PHINode *PN = dyn_cast<PHINode>(&I);
      if (!PN) break;  // PHI 必须在块首，遇到非 PHI 即停

      Value *V = PN->getIncomingValueForBlock(BB);
      if (isHandledGCPointerType(V->getType(), GC) && !isa<Constant>(V))
        LiveTmp.insert(V);
    }
  }
}
```

### 6.2 PHI 活跃性的正确传播

```
  BB:
    %obj = load %p
    br %merge

  merge:
    %phi = phi [%obj, %BB], [%other, %otherBB]
```

`%obj` 在 BB 中是否活跃出？取决于 `%phi` 是否使用了 `%obj`（对于 BB 来说）。

`computeLiveOutSeed` 扫描后继块的 PHI，取出 BB 对应的入值 `%obj`，加入 BB 的 LiveOut。

**这替代了传统活跃性分析中 PHI 的隐式 use/def 语义**：
- PHI 的入值：视为前驱块的 use
- PHI 本身：视为当前块的 def

---

## 7. KillSet 计算

```cpp
static SetVector<Value *> computeKillSet(BasicBlock *BB, GCStrategy *GC) {
  SetVector<Value *> KillSet;
  for (Instruction &I : *BB)
    if (isHandledGCPointerType(I.getType(), GC))
      KillSet.insert(&I);
  return KillSet;
}
```

**KillSet = 块内所有产生 GC 指针类型结果的指令**。

注意：KillSet 是**指令级别**的 kill，即指令的**定义**。这不考虑指令本身是否也使用了该值——那是 LiveSet 的职责。

**关键不变量**：`KillSet ∩ LiveSet = ∅`（kill 的值不应出现在 use 集中）：

```cpp
for (Value *Kill : Data.KillSet[&BB])
    assert(!Data.LiveSet[&BB].count(Kill) && "live set contains kill");
```

---

## 8. 全函数活跃性传播（computeLiveInValues 函数级）

### 8.1 数据流方程

```
LiveIn(B) = (LiveSet(B) ∪ LiveOut(B)) \ KillSet(B)
LiveOut(B) = ∪ { LiveIn(S) | S ∈ successors(B) }
```

注意 LiveOut 用的是**并集**（∪）——与 SafepointIRVerifier 的**交集**不同。这是因为：
- RS4GC 的活跃性是**may-alias 风格**：一个值只要在某条后继路径上活跃，就视为活跃出
- SafepointIRVerifier 的可用性是**must-alias 风格**：一个值必须在所有路径上都被重定位才算可用

### 8.2 初始化阶段

```cpp
for (BasicBlock &BB : F) {
    // 1. 计算每块的 KillSet
    Data.KillSet[&BB] = computeKillSet(&BB, GC);

    // 2. 计算每块的 LiveSet（仅块内 use，不含 PHI use）
    Data.LiveSet[&BB].clear();
    computeLiveInValues(BB.rbegin(), BB.rend(), Data.LiveSet[&BB], GC);

    // 3. 初始 LiveOut = 后继 PHI 中来自本块的入值
    Data.LiveOut[&BB] = SetVector<Value *>();
    computeLiveOutSeed(&BB, Data.LiveOut[&BB], GC);

    // 4. 计算 LiveIn = (LiveSet ∪ LiveOut) \ KillSet
    Data.LiveIn[&BB] = Data.LiveSet[&BB];
    Data.LiveIn[&BB].set_union(Data.LiveOut[&BB]);
    Data.LiveIn[&BB].set_subtract(Data.KillSet[&BB]);

    // 5. 若有活跃入值，前驱块需要传播
    if (!Data.LiveIn[&BB].empty())
        Worklist.insert(pred_begin(&BB), pred_end(&BB));
}
```

**LiveSet 计算的微妙之处**：

`computeLiveInValues(BB.rbegin(), BB.rend(), Data.LiveSet[&BB], GC)` 中，`LiveTmp` 初始为空。反向扫描整块后，`LiveSet[BB]` 包含的是**从块首向上暴露使用的值**（upward exposed uses）——即那些在块内被使用、但在使用点之前没有被块内指令定义的值。

### 8.3 传播循环

```cpp
while (!Worklist.empty()) {
    BasicBlock *BB = Worklist.pop_back_val();

    // 计算新的 LiveOut = ∪ LiveIn(Succ)
    SetVector<Value *> LiveOut = Data.LiveOut[BB];
    const auto OldLiveOutSize = LiveOut.size();
    for (BasicBlock *Succ : successors(BB)) {
        LiveOut.set_union(Data.LiveIn[Succ]);
    }

    // 若 LiveOut 未变化 → LiveIn 也不变 → 跳过
    if (OldLiveOutSize == LiveOut.size())
        continue;
    Data.LiveOut[BB] = LiveOut;

    // 重算 LiveIn = (LiveSet ∪ LiveOut) \ KillSet
    SetVector<Value *> LiveTmp = LiveOut;
    LiveTmp.set_union(Data.LiveSet[BB]);
    LiveTmp.set_subtract(Data.KillSet[BB]);

    const SetVector<Value *> &OldLiveIn = Data.LiveIn[BB];
    if (OldLiveIn.size() != LiveTmp.size()) {
        Data.LiveIn[BB] = LiveTmp;
        Worklist.insert(pred_begin(BB), pred_end(BB));
    }
}
```

### 8.4 收敛性分析

**为什么 `OldLiveOutSize == LiveOut.size()` 检查正确？**

`LiveOut` 只做 `set_union`（并集），所以集合**单调递增**。若大小不变，则集合内容也不变（没有新元素被加入）。

**为什么 `OldLiveIn.size() != LiveTmp.size()` 检查充分？**

`LiveIn` 也单调递增（因为 `LiveOut` 单调递增，`LiveSet` 和 `KillSet` 不变）。大小不变意味着内容不变。

**终止保证**：活跃集大小有上界（函数中所有 GC 指针值的数量），单调递增 → 必然终止。

### 8.5 精确性：使用 `size()` 做等价判断

```cpp
if (OldLiveOutSize == LiveOut.size()) continue;
```

这个优化依赖 `SetVector` 的性质：`set_union` 不删除元素，只添加。若大小不变，则没有添加任何元素，集合不变。

但注意：**这不检查内容等价**。理论上，`set_union` 可能添加一个新元素同时删除一个旧元素（如果 `SetVector` 允许覆盖的话）。但 `SetVector` 是基于 `DenseSet` + `SmallVector` 的，`set_union` 只追加不存在的元素，因此 `size()` 变化 ⟺ 集合变化。

---

## 9. 指令级活跃集查询（findLiveSetAtInst）

### 9.1 算法

```cpp
static void findLiveSetAtInst(Instruction *Inst, GCPtrLivenessData &Data,
                               StatepointLiveSetTy &Out, GCStrategy *GC) {
    BasicBlock *BB = Inst->getParent();

    // 1. 从 LiveOut[BB] 的副本开始（注意：必须拷贝！）
    SetVector<Value *> LiveOut = Data.LiveOut[BB];

    // 2. 从块末反向扫描到 Inst 位置
    computeLiveInValues(
        BB->rbegin(),
        ++Inst->getIterator().getReverse(),  // 扫描到 Inst 之前
        LiveOut, GC);

    // 3. 移除 Inst 自身（它不是"活跃过"安全点的值）
    LiveOut.remove(Inst);

    Out.insert(LiveOut.begin(), LiveOut.end());
}
```

### 9.2 关键设计决策

**为什么从 `LiveOut[BB]` 开始而非 `LiveIn[BB]`？**

因为我们需要的是**在 Inst 位置**的活跃集，而非块入口的活跃集。`LiveOut[BB]` 包含所有可能从后继传播回来的活跃值。从 `LiveOut` 反向扫描到 Inst 位置，沿途应用 kill/use，得到精确的指令级活跃集。

**为什么必须拷贝 `LiveOut`？**

```cpp
SetVector<Value *> LiveOut = Data.LiveOut[BB];  // 拷贝！
```

`computeLiveInValues` 会修改传入的 `LiveTmp`（kill 和 use 操作）。若不拷贝，会破坏全局数据。

**为什么移除 Inst 自身？**

```cpp
LiveOut.remove(Inst);
```

Inst 是安全点调用本身。其调用结果（如果有）在 Inst 之后才可用，不应视为"活跃过安全点"的值。其参数虽然在 Inst 中被使用，但在 `computeLiveInValues` 的反向扫描中已经处理（Inst 之前的 kill/use 不包含 Inst 本身的效果）。

### 9.3 反向扫描范围

```cpp
BB->rbegin(), ++Inst->getIterator().getReverse()
```

`++Inst->getIterator().getReverse()` 使迭代器跳过 Inst 本身，从 Inst 的前一条指令开始扫描。

等价于：从块末扫描到 Inst 之前（不含 Inst）。

---

## 10. 两次活跃性分析的必要性

### 10.1 第一次：findLiveReferences

```cpp
findLiveReferences(F, DT, ToUpdate, Records, GC.get());
```

计算原始 IR 的活跃性，确定每个安全点的初始活跃集。

### 10.2 中间：基指针推断

基指针推断可能**插入新的基 PHI 指令**：

```llvm
; 原始:
loop:
  %p = phi [%obj1, %entry], [%field, %loop]
  %field = gep %p, 8
  call @foo()  ; 安全点
  br loop

; 基指针推断后:
loop:
  %p.base = phi [%obj1, %entry], [%obj, %loop]   ← 新插入！
  %p = phi [%obj1, %entry], [%field, %loop]
  %field = gep %p, 8
  call @foo()  ; 安全点：现在 %p.base 也必须活跃！
  br loop
```

### 10.3 第二次：recomputeLiveInValues

```cpp
recomputeLiveInValues(F, DT, ToUpdate, Records, PointerToBase, GC.get());
```

**为什么必须重算？**

1. 基 PHI 是**新的定义**：出现在 KillSet 中
2. 基 PHI 是**新的使用**：其操作数引用了其他值
3. 基指针需要作为 `gc.relocate` 的参数 → 必须在安全点活跃

**为什么不能增量更新？**

代码中有 TODO 注释：

```cpp
// TODO-PERF: reuse the original liveness, then simply run the dataflow
// again. The old values are still live and will help it stabilize quickly.
```

当前实现完全重算。理论上可以复用第一次的结果作为初始种子，使传播更快收敛。

### 10.4 使用持有者（Use Holder）桥接两次分析

在第一次和第二次之间，插入临时 `__tmp_use` 调用：

```cpp
// 在每个安全点后插入持有者，保持基指针活跃
for (size_t i = 0; i < Records.size(); i++) {
    SmallVector<Value *, 128> Bases;
    for (auto *Derived : Info.LiveSet)
        Bases.push_back(PointerToBase[Derived]);
    insertUseHolderAfter(ToUpdate[i], Bases, Holders);
}
```

**为什么需要持有者？**

基 PHI 插入后，基指针可能在安全点处没有显式的使用。例如：

```
%p.base = phi ...        ; 定义 %p.base
call @foo()              ; 安全点：此时 %p.base 没有显式使用！
%p = phi ...             ; 但 %p.base 是 %p 的基，必须在安全点活跃
```

持有者 `__tmp_use(%p.base)` 在安全点后创建一个显式使用，确保第二次活跃性分析能发现 `%p.base` 是活跃的。

**持有者在第二次分析完成后移除**：

```cpp
for (CallInst *CI : Holders)
    CI->eraseFromParent();
```

### 10.5 recomputeLiveInValues 的特殊处理

```cpp
static void recomputeLiveInValues(
    GCPtrLivenessData &RevisedLivenessData,
    CallBase *Call,
    PartiallyConstructedSafepointRecord &Info,
    PointerToBaseTy &PointerToBase,
    GCStrategy *GC) {
    StatepointLiveSetTy Updated;
    findLiveSetAtInst(Call, RevisedLivenessData, Updated, GC);

    // 新发现的基指针：假设自身为基
    for (auto *V : Updated)
        PointerToBase.insert({ V, V });

    Info.LiveSet = Updated;
}
```

新加入活跃集的值（如基 PHI）暂时设为自身为基（`PointerToBase[V] = V`）。这是安全的，因为基 PHI 本身就是基指针。

---

## 11. 活跃集的后处理

### 11.1 移除常量基指针

```cpp
for (auto &Info : Records) {
    Info.LiveSet.remove_if([&](Value *LiveV) {
        return isa<Constant>(PointerToBase[LiveV]);
    });
}
```

**为什么此时才移除？**

在活跃性分析和基指针推断之间，常量值的活跃性不影响分析正确性。但 `relocationViaAlloca` 代码假设活跃值的基也在活跃集中——常量基不在活跃集中（常量不参与活跃性分析），因此常量基的派生指针也不能留在活跃集中。

### 11.2 重物化后的活跃集缩减

```cpp
// rematerializeLiveValuesAtUses 后:
for (auto *Cand : LiveValuesToBeDeleted) {
    R.LiveSet.remove(Cand);  // 从活跃集中移除已重物化的值
}

// rematerializeLiveValues 后:
for (auto *LiveValue : LiveValuesToBeDeleted) {
    Info.LiveSet.remove(LiveValue);  // 从活跃集中移除已重物化的值
}
```

重物化的值不再需要 `gc.relocate`，因此从活跃集中移除。这直接影响 `gc.statepoint` 的 `gc-live` 操作数包大小。

---

## 12. 完整示例：跨块活跃性传播

```llvm
define void @test(ptr addrspace(1) %arg) gc "statepoint-example" {
entry:
  %obj = load ptr addrspace(1), ptr %arg
  br %loop

loop:
  %p = phi ptr addrspace(1) [%obj, %entry], [%p.next, %loop]
  %field = getelementptr ptr addrspace(1), ptr addrspace(1) %p, i32 1
  call void @foo()                    ; 安全点 1
  %val = load i32, ptr addrspace(1) %field
  call void @bar()                    ; 安全点 2
  %p.next = getelementptr ptr addrspace(1), ptr addrspace(1) %p, i32 2
  br %loop
}
```

### 初始化

**KillSet:**
```
entry:  {%obj}
loop:   {%p, %field, %val, %p.next}
```

**LiveSet（块内向上暴露的使用，排除 kill）:**
```
entry:  {}          ; %obj 是定义（kill），无其他使用
loop:   {%p}        ; %field 使用 %p 但 %p 是 PHI（跳过），
                     ; %val 使用 %field 但 %field 被 kill，
                     ; %p.next 使用 %p 但 %p 是 PHI
                     ; 实际：反向扫描到 %p（PHI，跳过）后，
                     ; %field = gep %p → kill %field, use %p → %p 在 LiveSet
                     ; 但 %p 是 PHI 定义 → 在 kill 中也被移除
                     ; 修正：LiveSet[loop] = {} （所有 GC 指针使用要么被 kill 要么是 PHI）
```

**LiveOut（从后继 PHI 初始化）:**
```
entry:  {%obj}      ; loop 的 PHI 入值 %obj 来自 entry
loop:   {%p}        ; loop 的 PHI 入值 %p.next 来自 loop 自身
```

**LiveIn = (LiveSet ∪ LiveOut) \ KillSet:**
```
entry:  ({%obj} ∪ {}) \ {%obj} = {}
loop:   ({} ∪ {%p}) \ {%p, %field, %val, %p.next}
       = {%p} \ {%p, %field, %val, %p.next} = {}
```

**但等——这不对！** `%obj` 和 `%p` 应该在安全点处活跃。

问题在于：`LiveSet` 计算时，PHI 使用被跳过了。让我重新分析：

### 正确的初始化

**LiveSet[entry]:**

反向扫描 entry 块（只有 `%obj = load` 和 `br`）：
- `br %loop` → 非指令，不产生 use
- `%obj = load %arg` → kill %obj，use %arg → 但 %arg 是参数，不在 KillSet 中 → LiveSet = {%arg}

实际上 `%arg` 也是 GC 指针类型。所以：

```
LiveSet[entry] = {%arg}
KillSet[entry] = {%obj}
LiveOut[entry] = {%obj}   (从 loop 的 PHI)
LiveIn[entry] = ({%arg} ∪ {%obj}) \ {%obj} = {%arg}
```

```
LiveSet[loop] = {}         (所有 GC ptr 使用要么被 kill 要么是 PHI 操作数)
KillSet[loop] = {%p, %field, %val, %p.next}
LiveOut[loop] = {%p}       (从 loop 自身的 PHI)
LiveIn[loop] = ({} ∪ {%p}) \ {%p, %field, %val, %p.next} = {}
```

### 传播

工作列表：entry 的 LiveIn 非空 → pred(entry) 无前驱，不加。
loop 的 LiveIn 为空 → 不加前驱。

但 LiveOut[entry] = {%obj}，LiveIn[loop] = {}。这表明 `%obj` 不活跃入 loop？不对！

**问题出在 LiveSet[loop] 的计算**。让我更仔细地看：

反向扫描 loop 块：
1. `%p.next = gep %p, 2` → kill %p.next，use %p → %p 在 LiveTmp
2. `call @bar()` → 无 GC 指针操作数
3. `%val = load %field` → kill %val，use %field → %field 在 LiveTmp
4. `call @foo()` → 无 GC 指针操作数
5. `%field = gep %p, 1` → kill %field，use %p → %p 已在 LiveTmp
6. `%p = phi ...` → PHI，跳过

LiveTmp = {%p, %field} → 但 %field 被 kill，%p 是 PHI 定义...

等等，反向扫描时：
- 先 kill（LiveTmp.remove），后 use（LiveTmp.insert）
- 步骤 3: kill %val → 移除 %val；use %field → 加入 %field
- 步骤 5: kill %field → 移除 %field；use %p → 加入 %p

所以 LiveSet[loop] = {%p}（最终只剩 %p）

但 %p 是 PHI 定义，也在 KillSet 中。所以：

```
LiveSet[loop] = {%p}
KillSet[loop] = {%p, %field, %val, %p.next}
LiveOut[loop] = {%p}
LiveIn[loop] = ({%p} ∪ {%p}) \ {%p, %field, %val, %p.next} = {}
```

这仍然不对。问题是 `%p` 被 kill 了（PHI 定义 %p），所以即使 LiveSet 和 LiveOut 都有 %p，LiveIn 也为空。

**但这是正确的！** `%p` 在 loop 块内被定义（PHI），所以它不活跃入 loop 块——它是 loop 块的局部定义。活跃入 loop 的是 `%obj`（来自 entry 的 PHI 入值）。

但 `%obj` 不在 LiveIn[loop] 中！因为 PHI 的使用不在 LiveSet 中处理。

**这是正确的数据流方程行为**：`%obj` 活跃出 entry → 活跃入 loop 的 PHI → 但 PHI 把 `%obj` 转为 `%p` → `%p` 是 loop 的局部值 → `%obj` 不需要活跃入 loop 块的"非 PHI"指令。

**然而，`%obj` 确实需要在安全点处活跃！** 因为 `%p` 的值可能来自 `%obj`，而 `%p` 在安全点处被使用。

**答案**：`%p` 本身才是需要在安全点处活跃的值。让我们重新看 `findLiveSetAtInst`：

### 安全点 1 处的活跃集

```
findLiveSetAtInst(call @foo()):
  LiveOut[loop] = {%p}
  反向扫描从块末到 call @foo() 之前:
    %val = load %field → kill %val, use %field → LiveTmp = {%p, %field}
    [call @bar() 无 GC 操作数]
    → 扫描到 call @foo() 前停止

  LiveTmp = {%p, %field}
  移除 Inst (call @foo() 自身) → 无变化
  结果: {%p, %field}
```

**正确！** `%p` 和 `%field` 在安全点 1 处活跃。

### 安全点 2 处的活跃集

```
findLiveSetAtInst(call @bar()):
  LiveOut[loop] = {%p}
  反向扫描从块末到 call @bar() 之前:
    %p.next = gep %p, 2 → kill %p.next, use %p → LiveTmp = {%p}

  LiveTmp = {%p}
  移除 Inst → 无变化
  结果: {%p}
```

**正确！** `%p` 在安全点 2 处活跃（%field 在安全点 2 后不再使用）。

---

## 13. SSA 正确性验证

```cpp
static void checkBasicSSA(DominatorTree &DT, SetVector<Value *> &Live,
                           Instruction *TI, bool TermOkay = false) {
    for (Value *V : Live) {
        if (auto *I = dyn_cast<Instruction>(V)) {
            if (TermOkay && TI == I) continue;
            assert(DT.dominates(I, TI) &&
                   "basic SSA liveness expectation violated");
        }
    }
}
```

**不变量**：活跃集中的每个指令定义必须支配查询点。

**原因**：在 SSA 中，一个值的定义必须支配其所有使用。若活跃集中有值不支配安全点，则活跃性分析有 bug（遗漏了某个 kill）。

**特殊处理 TermOkay**：`LiveOut` 可以包含块终结指令自身（LLVM 的支配关系定义中，指令不支配自身）。对于 `LiveOut` 检查，允许终结指令在活跃集中。

**何时触发**：仅 `#ifndef NDEBUG` 条件编译，在传播收敛后对每块检查。

---

## 14. 与 SafepointIRVerifier 的活跃性分析对比

| 方面 | RS4GC 活跃性分析 | SafepointIRVerifier |
|------|-----------------|---------------------|
| **方向** | 后向（use → def） | 前向（def → use） |
| **语义** | may-live（并集） | must-available（交集） |
| **查询** | "哪些值可能在此点活跃？" | "哪些值在此点确定已重定位？" |
| **LiveOut 交汇** | ∪ (并集) | ∩ (交集) |
| **迁移方向** | kill/use 逆向传播 | safe点清空 + 新定义正向传播 |
| **目的** | 确定需要报告给 GC 的指针 | 验证没有使用未重定位指针 |
| **单调性** | 集合单调递增 | 集合单调递减 |
| **保守方向** | 宁可多报活跃 | 宁可多报违规 |

---

## 15. 性能特征

### 15.1 复杂度

| 操作 | 复杂度 |
|------|--------|
| 初始化（每块 KillSet + LiveSet） | O(B × I) |
| LiveOut 种子化 | O(B × P) |
| 传播循环 | O(B × N) 最坏，通常快得多 |
| findLiveSetAtInst | O(I) |

B = 基本块数，I = 每块指令数，P = 每块 PHI 数，N = GC 指针值总数

### 15.2 性能瓶颈

1. **SetVector 操作**：每次 `set_union`/`set_subtract` 是 O(N)，非位向量
2. **全量拷贝**：`findLiveSetAtInst` 拷贝整个 `LiveOut[BB]`
3. **两次全量分析**：基 PHI 插入后完全重算

### 15.3 TODO 优化

```cpp
// TODO: Consider using bitvectors for liveness, the set of potentially
// interesting values should be small and easy to pre-compute.
```

使用位向量替代 `SetVector<Value *>`：
1. 预计算所有 GC 指针值 → 分配索引
2. 用 bitvector 表示活跃集
3. `set_union` = OR, `set_subtract` = AND NOT → O(N/64) 字操作

---

## 16. 调试支持

### 16.1 打印选项

```cpp
static cl::opt<bool> PrintLiveSet("spp-print-liveset", cl::Hidden);
static cl::opt<bool> PrintLiveSetSize("spp-print-liveset-size", cl::Hidden);
```

- `spp-print-liveset`：打印每个安全点的完整活跃集
- `spp-print-liveset-size`：打印每个安全点的活跃集大小

### 16.2 ClobberNonLive

```cpp
#ifdef EXPENSIVE_CHECKS
static bool ClobberNonLive = true;
#else
static bool ClobberNonLive = false;
#endif
```

在 `relocationViaAlloca` 中，对**未重定位**的 alloca 存入 null/poison。这将使用-after-relocation bug 转为 SEGV（段错误），比静默使用悬垂指针更容易调试。

仅 `EXPENSIVE_CHECKS` 模式默认启用，因为对大量安全点的函数极其耗时。
