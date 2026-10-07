# LLVM GC 适配 Pass 分析文档

## 1. 架构总览

LLVM 的 GC 基础设施为运行时垃圾回收器提供编译器侧支持，核心职责是：**识别安全点（safepoint）、追踪 GC 指针位置、生成重定位信息**。不负责屏障插入或对象模型。

LLVM 支持两套互斥的 GC 适配机制：

| 机制 | 核心指令 | 适用策略 | 现代程度 |
|------|---------|---------|---------|
| **gc.root** | `llvm.gcroot` / `llvm.gcread` / `llvm.gcwrite` | Erlang, Ocaml, ShadowStack | 遗留 |
| **gc.statepoint** | `gc.statepoint` / `gc.relocate` / `gc.result` | Statepoint-example, CoreCLR | 现代，支持移动式 GC |

```
┌──────────────────────────────────────────────────────────────────────┐
│                        语言前端                                       │
│  函数标记 gc 属性 → GCStrategy 选择策略                               │
│  生成 GC intrinsics (gcroot 或 statepoint)                           │
├──────────────────────────────────────────────────────────────────────┤
│                     IR 变换层                                         │
│  gc.statepoint 路径:                                                  │
│    PlaceSafepoints → RewriteStatepointsForGC → SafepointIRVerifier  │
│  gc.root 路径:                                                        │
│    (前端自行插入 llvm.gcroot)                                         │
├──────────────────────────────────────────────────────────────────────┤
│                     代码生成层                                        │
│  gc.statepoint 路径:                                                  │
│    StatepointLowering → FixupStatepointCallerSaved                   │
│    → GCMachineCodeAnalysis → StackMapLiveness                        │
│  gc.root 路径:                                                        │
│    GCLowering → ShadowStackGCLowering → GCMachineCodeAnalysis        │
├──────────────────────────────────────────────────────────────────────┤
│                     汇编发射层                                        │
│  StackMaps::serializeToStackMapSection()  → .llvm_stackmaps 段       │
│  GCMetadataPrinter (Ocaml/Erlang)         → 自定义帧表格式           │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 2. GCStrategy 框架

### 2.1 GCStrategy 类

**头文件**：`llvm/include/llvm/IR/GCStrategy.h`
**源文件**：`llvm/lib/IR/GCStrategy.cpp`

```cpp
class GCStrategy {
  std::string Name;
  bool UseStatepoints = false;   // 使用 gc.statepoint 机制
  bool UseRS4GC = false;         // 需要 RewriteStatepointsForGC pass
  bool NeededSafePoints = false; // 需要推断安全点 (gc.root 专用)
  bool UsesMetadata = false;     // 需要后端发射元数据表 (gc.root 专用)

  virtual std::optional<bool> isGCManagedPointer(const Type *Ty) const;
};
```

**注册机制**：`GCRegistry = Registry<GCStrategy>`，通过静态初始化器注册：

```cpp
static GCRegistry::Add<CoreCLRGC> E("coreclr", "CoreCLR GC");
```

**查找**：`getGCStrategy(StringRef Name)` 遍历注册表。失败时调用 `linkAllBuiltinGCs()` 强制链接内置策略后重试。

### 2.2 内置策略

| 策略 | 注册名 | UseStatepoints | UseRS4GC | NeededSafePoints | UsesMetadata | isGCManagedPointer |
|------|--------|:-:|:-:|:-:|:-:|-----|
| ErlangGC | `"erlang"` | ✗ | ✗ | ✓ | ✓ | nullopt |
| OcamlGC | `"ocaml"` | ✗ | ✗ | ✓ | ✓ | nullopt |
| ShadowStackGC | `"shadow-stack"` | ✗ | ✗ | ✗ | ✗ | nullopt |
| StatepointGC | `"statepoint-example"` | ✓ | ✓ | ✗ | ✗ | addrspace(1)→true |
| CoreCLRGC | `"coreclr"` | ✓ | ✓ | ✗ | ✗ | addrspace(1)→true |

**关键区分**：

- **gc.root 策略**（Erlang/Ocaml/ShadowStack）：前端显式插入 `llvm.gcroot` 标记栈根，后端生成帧表
- **gc.statepoint 策略**（Statepoint/CoreCLR）：RS4GC pass 自动将所有调用点转换为安全点，运行时通过 StackMap 段定位 GC 指针

### 2.3 指针识别

Statepoint 策略使用**地址空间**区分 GC 管理指针：

```cpp
// CoreCLRGC / StatepointGC
std::optional<bool> isGCManagedPointer(const Type *Ty) const override {
  if (auto *PT = dyn_cast<PointerType>(Ty))
    return PT->getAddressSpace() == 1;  // addrspace(1) = GC 管理指针
  return std::nullopt;
}
```

前端将 GC 管理的指针标记为 `addrspace(1)*`，非 GC 指针使用默认地址空间 0。

---

## 3. Pass 流水线

### 3.1 gc.statepoint 路径（现代，推荐）

```
源 IR (函数带 gc="statepoint-example" 或 gc="coreclr")
    │
    ├── PlaceSafepointsPass          ← 入口 + 回边安全点轮询
    │     插入 gc.safepoint_poll 调用
    │     使调用点可解析
    │
    ├── RewriteStatepointsForGC      ← 核心变换 pass
    │     活跃性分析 → 基指针推断 → 重物化
    │     → 生成 gc.statepoint + gc.relocate + gc.result
    │     → 剥离无效属性/元数据
    │
    ├── [标准优化 pass]
    │
    ├── SafepointIRVerifier          ← 验证重定位正确性 (可选)
    │
    ├── SelectionDAG: StatepointLowering  ← 降级为 STATEPOINT MI
    │
    ├── FixupStatepointCallerSaved   ← Post-RA: 溢出被调用者保存寄存器
    │
    ├── GCEmptyBasicBlocks           ← 清理空块
    │
    ├── StackMapLivenessAnalysis     ← 计算 PATCHPOINT 活跃寄存器
    │
    └── StackMaps::serializeToStackMapSection()  ← 发射 .llvm_stackmaps 段
```

### 3.2 gc.root 路径（遗留）

```
源 IR (带 llvm.gcroot intrinsics)
    │
    ├── GCLoweringPass / LowerIntrinsics  ← 降低 gcread→load, gcwrite→store
    │
    ├── ShadowStackGCLowering (可选)       ← shadow-stack 策略专用
    │
    ├── [代码生成]
    │
    ├── GCMachineCodeAnalysis             ← 标记安全点、计算根偏移
    │
    └── OcamlGCPrinter / ErlangGCPrinter  ← 发射自定义帧表
```

### 3.3 Pass 注册

**TargetPassConfig 中的注册**：

```cpp
// addISelPrepare (选择前)
addPass(&GCLoweringID);             // 降低 gcroot/gcread/gcwrite
addPass(&ShadowStackGCLoweringID);  // shadow-stack 专用

// addPreEmitPass (RA 后)
addPass(&FixupStatepointCallerSavedID);  // 修正 statepoint 寄存器溢出

// 发射前
addGCPasses();  // → addPass(&GCMachineCodeAnalysisID)
addPass(&StackMapLivenessID);
if (GCEmptyBlocks) addPass(createGCEmptyBasicBlocksPass());
```

**PassRegistry.def 中的 New PM 注册**：

```
MODULE_PASS("rewrite-statepoints-for-gc", RewriteStatepointsForGC())
MODULE_PASS("shadow-stack-gc-lowering", ShadowStackGCLoweringPass())
FUNCTION_PASS("gc-lowering", GCLoweringPass())
FUNCTION_PASS("place-safepoints", PlaceSafepointsPass())
FUNCTION_PASS("strip-gc-relocates", StripGCRelocates())
```

---

## 4. 核心 Pass 详细设计

### 4.1 RewriteStatepointsForGC（RS4GC）

**类型**：ModulePass（New PM: `PassInfoMixin`）
**源文件**：`llvm/lib/Transforms/Scalar/RewriteStatepointsForGC.cpp`（3375 行）
**条件**：仅对 `UseRS4GC=true` 的 GC 策略生效

这是 GC 适配最核心的 pass。它将普通调用转换为显式的 GC 安全点，使得移动式 GC 能正确重定位指针。

#### 4.1.1 顶层流程

```
run(Module):
  对每个函数 F:
    if !shouldRewriteStatepointsIn(F) → skip
    runOnFunction(F):
      1. 移除不可达块
      2. 收集需要重写的调用点
      3. 折叠单入口 PHI (LCSSA 清理)
      4. 移动 ICmp 到安全点后 (减少寄存器压力)
      5. 规范化 scalar-to-vector GEP
      6. 内联 gc.get.pointer.base/offset
      7. insertParsePoints() ← 核心
  stripNonValidData(Module) ← 剥离无效属性
```

#### 4.1.2 insertParsePoints 核心算法

```
A. 规范化 invoke 后继
     若后继有多前驱 → 分裂边，保证 gc.relocate 可插入

B. 插入 deopt 使用持有者
     在每个调用后插入 __tmp_use() 保持 deopt 值活跃

C. 活跃性分析 (findLiveReferences)
     后向数据流: LiveIn(B) = (LiveSet(B) ∪ LiveOut(B)) \ KillSet(B)
                  LiveOut(B) = ∪ LiveIn(S), S ∈ succs(B)
     对每个调用点计算该点的活跃 GC 指针集合

D. 基指针推断 (findBasePointers)
     对每个活跃指针找其基指针 ← 最复杂的部分（见 4.1.3）

E. 插入基指针使用持有者
     基指针 PHI 插入可能引入新的活跃值 → 需要重算活跃性

F. 重算活跃性
     基指针 PHI 改变了 IR，需重新运行数据流

G. 移除常量基指针
     常量基指针不会移动，无需通知 GC

H. 移除临时使用持有者

I. 重物化优化
     识别可廉价重算的派生指针（GEP + cast 链）
     在安全点后重算而非通过 gc.relocate 传递 ← 减少安全点活跃集大小

J. 创建 statepoint
     对每个调用: 生成 gc.statepoint + gc.relocate + gc.result

K. 执行延迟替换

L. 通过 alloca 完成重定位
     为每个活跃值创建 alloca → 存储/加载 → mem2reg 提升
```

#### 4.1.3 基指针推断算法

这是 RS4GC 中最复杂的核心算法。对于每个活跃的派生指针（如 GEP 结果），需要找到其基指针，以便 GC 知道哪些对象是可达的。

**两层结构**：

**第 1 层：查找基定义值（Base Defining Value, BDV）**

递归函数 `findBaseDefiningValue(V)`:

| 指令类型 | BDV | isKnownBase | 原因 |
|---------|-----|:-:|------|
| Argument | 自身 | ✓ | 函数参数是基 |
| Constant | null | ✓ | 常量不移动 |
| LoadInst | 自身 | ✓ | 加载的指针视为基 |
| CallInst/InvokeInst | 自身 | ✓ | 假设返回基指针 |
| IntToPtrInst | 自身 | ✓ | 定义不明，视为基 |
| GEP | BDV(pointer_operand) | 继承 | GEP 的基 = 指针操作数的基 |
| CastInst(非 IntToPtr) | BDV(stripPointerCasts) | 继承 | 透视类型转换 |
| FreezeInst | BDV(operand) | 继承 | 传递性 |
| **PHINode** | 自身 | ✗ | **合并点，需推断** |
| **SelectInst** | 自身 | ✗ | **合并点，需推断** |
| ExtractElementInst | 自身 | ✗ | 向量提取=合并 |
| InsertElementInst | 自身 | ✗ | 向量插入=合并 |
| ShuffleVectorInst | 自身 | ✗ | 向量洗牌=合并 |

**第 2 层：格不动点算法**

```
BDVState 格:
       Unknown     (顶 — 初始状态)
      /  |  |  \
    b1  b2  b3  b4  (Base — 已知具体基值)
      \  |  |  /
       Conflict   (底 — 需要插入基 PHI)

meet 操作:
  Unknown ⊓ X     = X
  Base(b) ⊓ Base(b) = Base(b)
  Base(b1) ⊓ Base(b2) = Conflict  (b1≠b2)
  Base(b) ⊓ Conflict = Conflict
  Conflict ⊓ X    = Conflict
```

**算法步骤**：

```
Phase 1: 收集 BDV
  从初始 BDV 做 DFS，收集所有需要推断的 BDV

Phase 2: 剪枝平凡可解的 BDV
  若 BDV 所有操作数已解析为基 → BDV 自身为基，移出 States

Phase 3: 格不动点迭代
  对每个 BDV: 计算 meet(所有操作数的 BDVState)
  重复直到无变化

Phase 4: 插入基指令
  对每个 Conflict BDV:
    克隆原始指令 → 命名为 "*.base"
    添加 !is_base_value 元数据
    例如: phi a, b → phi_base a_base, b_base

Phase 5: 填充基指令操作数
  PHI: 每个入边填入原始入值对应的基
  Select: true/false 填入原始 true/false 的基
  ExtractElement: 向量操作数填入原始向量的基
  ...

Phase 6: 更新缓存
  Cache[BDV] = Base
```

**设计洞察**：当多个不同基指针汇聚到同一 PHI 时（Conflict），需要创建"并行基指针追踪"指令。例如：

```
原始:    p = phi [gep(obj1, 8)], [gep(obj2, 16)]
推断:    p.base = phi [obj1], [obj2]   ← 自动插入的基 PHI
```

#### 4.1.4 活跃性分析

标准后向数据流：

```
数据结构:
  KillSet[BB]: BB 中定义的 GC 指针
  LiveSet[BB]:  BB 中使用的 GC 指针（排除 kill）
  LiveIn[BB] = (LiveSet(BB) ∪ LiveOut(BB)) \ KillSet(BB)
  LiveOut[BB] = ∪ { LiveIn(S) | S ∈ successors(BB) }

算法:
  1. 初始化每块的 KillSet/LiveSet
  2. 种子化: LiveOut 从后继 PHI 的 GC 指针入值
  3. 工作列表传播直到不动点

findLiveSetAtInst(Inst):
  从 LiveOut[BB] 出发，反向扫描到 Inst 位置
  结果 = 该点的活跃 GC 指针集合
```

#### 4.1.5 重物化优化

减少安全点活跃集大小，降低 gc.relocate 数量。

```
可重物化指令: 仅 GEP + noop Cast

代价模型:
  CastInst: TTI.getCastInstrCost(...)
  GEP:      TTI.getAddressComputationCost() + 2 × 非常量索引数
  阈值: spp-rematerialization-threshold = 6

两种策略:
  1. 在使用处重物化 (rematerializeLiveValuesAtUses)
     盈利条件: NumLiveStatepoints > NumUses
     克隆链到每个用户之前

  2. 在安全点后重物化 (rematerializeLiveValues)
     对 invoke: 双倍代价（正常+异常路径各需一份）
     从活跃集中移除该派生指针
     在 gc.relocate 的基指针上重建 GEP/cast 链
```

#### 4.1.6 Statepoint 创建

```
makeStatepointExplicitImpl:

1. 确定参数:
   StatepointID, NumPatchBytes ← 函数属性
   Flags: GCTransition / DeoptLiveIn
   CallArgs ← 原始调用参数
   DeoptArgs ← deopt 操作数包
   TransitionArgs ← gc_transition 操作数包
   GCArgs ← 活跃 GC 指针列表

2. 特殊降低:
   llvm.experimental.deoptimize → __llvm_deoptimize + unreachable
   原子 memcpy/memmove → 拆分为 (base, offset) 对

3. 创建 gc.statepoint:
   CallInst → Builder.CreateGCStatepointCall(...)
   InvokeInst → Builder.CreateGCStatepointInvoke(...)

4. 创建 gc.result (非 void 返回):
   Builder.CreateGCResult(Token, ReturnType)

5. 创建 gc.relocate:
   对每个活跃 GC 指针:
     Builder.CreateGCRelocate(Token, BaseIdx, LiveIdx)
   Invoke: 正常路径 + 异常路径各一组

6. 属性合法化:
   剥离 Memory/NoSync/NoFree 函数属性
   传递参数属性到 statepoint
```

#### 4.1.7 重定位通过 Alloca（relocationViaAlloca）

**为什么不直接 RAUW？** 一个原始值可能在多个安全点被重定位，使用点跨越多条路径，直接替换会产生复杂的 SSA 更新模式。Alloca + mem2reg 利用已有的成熟基础设施。

```
1. 为每个活跃值创建 alloca

2. 插入 store:
   原始定义后: store 原始值 → alloca
   每个 gc.relocate 后: store 重定位值 → alloca
   每个 rematerialized 值后: store 重物化值 → alloca

3. 替换所有 use 为 load:
   PHI 使用 → 在前驱块末尾插入 load
   其他使用 → 在用户前插入 load

4. mem2reg (PromoteMemToReg):
   消除所有 alloca/load/store
   生成干净的 SSA（含必要 PHI 节点）
```

#### 4.1.8 属性剥离

`gc.statepoint` 语义上"释放整个堆"，因此任何暗示引用稳定性或内存不变性的属性/元数据都无效：

| 剥离对象 | 原因 |
|---------|------|
| `dereferenceable` / `dereferenceable_or_null` | 对象可能被移动 |
| `readnone` / `readonly` / `writeonly` | 安全点可读/写/释放内存 |
| `noalias` | 安全点后指针可能指向同一对象 |
| `nofree` / `nosync` / `memory` | 安全点可释放/同步 |
| `invariant.start` | 堆内容不再不变 |
| `invariant.load` / `invariant.group` | 加载值可能变化 |
| TBAA 标签 | 转为可变形式，防止加载下沉过安全点 |

---

### 4.2 PlaceSafepointsPass

**类型**：FunctionPass（New PM: `PassInfoMixin`）
**源文件**：`llvm/lib/Transforms/Scalar/PlaceSafepoints.cpp`（693 行）

**职责**：插入安全点轮询。**不**处理重定位语义（那是 RS4GC 的工作）。

**算法**：

```
1. 入口安全点:
   在入口块中、首次可能增长栈的调用前
   插入 gc.safepoint_poll 调用 → 内联

2. 回边安全点:
   使用 ScalarEvolution 识别循环回边
   跳过:
     可计数循环 (trip count < 2^spp-counted-loop-trip-width)
     包含无条件调用安全点的循环
   在回边插入 gc.safepoint_poll → 内联

3. 使调用点可解析:
   扫描内联后的代码
   标记需要 statepoint 包装的调用
```

**控制标志**：

| 标志 | 默认 | 作用 |
|------|------|------|
| `spp-no-entry` | false | 禁用入口安全点 |
| `spp-no-call` | false | 禁用调用安全点 |
| `spp-no-backedge` | false | 禁用回边安全点 |
| `spp-all-backedges` | false | 强制所有回边插入安全点 |
| `spp-split-backedge` | false | 分裂回边 vs 锁存块 |

---

### 4.3 SafepointIRVerifier

**类型**：FunctionPass
**源文件**：`llvm/lib/IR/SafepointIRVerifier.cpp`（909 行）

**职责**：验证 RS4GC 后没有使用未重定位的 GC 指针。

#### 4.3.1 三态模型

| 状态 | 含义 | 允许的使用 |
|------|------|-----------|
| **Relocated (R)** | 安全点后已正确重定位 | 任意使用 |
| **Unrelocated (U)** | 安全点前定义，未重定位 | 仅与同状态指针比较 |
| **Poisoned (P)** | 混合 R 和 U 派生（如 PHI 合并两者） | 仅与 null 派生指针比较 |

派生规则：`R+R=R, U+U=U, R+U=P, P+X=P, X+C=X`

#### 4.3.2 数据流分析

```
每块状态:
  AvailableIn:    入口处的已重定位值集合
  AvailableOut:   出口处的已重定位值集合
  Contribution:   本块新增的重定位定义
  Cleared:        本块含 gc.statepoint

迁移函数:
  gc.statepoint → 清空 Available 集合 (所有之前重定位的值变为未重定位)
  GC 指针定义   → 加入 Available 集合

交汇操作: AvailableIn = ∩(pred.AvailableOut)  ← 交集，非并集
  值必须在所有前驱路径上都被重定位才算"可用"

收敛: 集合只减不增（单调），保证终止
```

#### 4.3.3 特殊情况

**CodegenPrep 模式**（允许未重定位指针比较）：

```
a = ...
b = ...
(a', b') = safepoint(a, b)
c = cmp eq a, b     ← 合法! 两个操作数都是 U 状态
```

原因：`cmp eq a, b` 可以合法地提升到安全点之前（无副作用），CodeGenPrep 产生此模式。

**CFGDeadness**：用轻量级死代码分析避免对不可达路径的误报。

---

### 4.4 GCLoweringPass / LowerIntrinsics

**类型**：FunctionPass
**源文件**：`llvm/lib/CodeGen/GCRootLowering.cpp`（345 行）

**职责**：降低 gc.root 路径的 intrinsics。

| 原始 Intrinsic | 降低为 | 说明 |
|---------------|--------|------|
| `llvm.gcread` | `LoadInst` | 读屏障移除（当前无条件） |
| `llvm.gcwrite` | `StoreInst` | 写屏障移除（当前无条件） |
| `llvm.gcroot` | 保留 + 插入初始化 | 记录 alloca，在首个潜在安全点前存入 null |

**设计限制**：`llvm.gcread`/`llvm.gcwrite` 当前无条件降低为普通 load/store。若需实际屏障，需自定义 GCStrategy 子类覆盖此行为。

---

### 4.5 ShadowStackGCLowering

**类型**：FunctionPass（New PM: ModulePass）
**源文件**：`llvm/lib/CodeGen/ShadowStackGCLowering.cpp`（420 行）

**理论基础**：*"Accurate Garbage Collection in an Uncooperative Environment"* (Henderson, ISMM 2002)

**数据结构**：

```
FrameMap  { int32_t NumRoots, int32_t NumMeta, void* Meta[] }
StackEntry { StackEntry* Next, FrameMap* Map, void* Roots[] }
全局链表头: llvm_gc_root_chain
```

**算法**：

```
1. 收集所有 llvm.gcroot 标记的 alloca
2. 创建 FrameMap 常量 (描述根数量和元数据)
3. 创建具体的 StackEntry 类型 (头部 + 根槽位)
4. 函数入口:
   在栈上分配 shadow stack entry (gc_frame)
   替换每个 root alloca 为 GEP 到 shadow stack entry 的槽位
   将 entry 推入 llvm_gc_root_chain 链表
5. 每个函数出口:
   将 entry 从链表弹出 (EscapeEnumerator 处理所有出口)
```

**适用场景**：不协作的目标平台（无法在运行时注册栈帧信息时），通过全局链表让 GC 遍历所有线程的栈根。

---

### 4.6 FixupStatepointCallerSaved

**类型**：MachineFunctionPass
**源文件**：`llvm/lib/CodeGen/FixupStatepointCallerSaved.cpp`（629 行）
**时机**：Post-RA

**问题**：STATEPOINT 指令的 deopt/GC 操作数可能使用 caller-saved 寄存器，但调用本身会覆盖这些寄存器。

**算法**：

```
1. 找到所有 STATEPOINT MI
2. 对每个 statepoint:
   识别 meta 操作数中的 caller-saved 寄存器
   拷贝传播: 若寄存器是 COPY 结果，改为溢出源寄存器
   溢出到栈槽: 在 statepoint 前插入 spill
   重写操作数: 寄存器 → IndirectMemRefOp(frame_index + offset)
   在 statepoint 后插入 reload (正常路径 + 异常路径)
3. 对 invoke statepoint:
   确保同一 landing pad 的多个 statepoint 使用一致的槽分配
```

---

### 4.7 GCMachineCodeAnalysis

**类型**：MachineFunctionPass
**源文件**：`llvm/lib/CodeGen/GCRootLowering.cpp`（同文件）
**时机**：发射前

**职责**（gc.root 路径专用）：

```
1. 扫描 call 指令 (非 tail/sibling) → 标记为安全点
2. 在安全点插入 GC_LABEL 标记
3. 计算每个根的具体栈偏移
4. 记录帧大小 (动态栈帧为 UINT64_MAX)
5. 填充 GCFunctionInfo 元数据
```

---

### 4.8 辅助 Pass

| Pass | 类型 | 源文件 | 功能 |
|------|------|--------|------|
| `StackMapLiveness` | MachineFunctionPass | `StackMapLivenessAnalysis.cpp` | 计算 PATCHPOINT 指令的 live-out 寄存器掩码 |
| `GCEmptyBasicBlocks` | MachineFunctionPass | `GCEmptyBasicBlocks.cpp` | 移除安全点插入产生的空基本块 |
| `StripGCRelocates` | FunctionPass | `StripGCRelocates.cpp` | 移除 gc.relocate（调试用，产生不正确 IR） |

---

## 5. Statepoint IR 层

### 5.1 Intrinsics

| Intrinsic | 签名 | 说明 |
|-----------|------|------|
| `gc.statepoint` | `[token](i64 ID, i32 NumPatchBytes, ptr Callee, i32 NumCallArgs, i32 Flags, ...)` | 包装调用为安全点 |
| `gc.result` | `[any](token)` | 提取调用返回值 |
| `gc.relocate` | `[any](token, i32 BaseIdx, i32 DerivedIdx)` | 获取重定位后的指针 |
| `gc.get.pointer.base` | `[ptr](ptr)` | 获取内部指针的基指针 |
| `gc.get.pointer.offset` | `[i64](ptr)` | 获取指针相对于基的偏移 |

### 5.2 操作数包

| Bundle | 枚举值 | 说明 |
|--------|--------|------|
| `"deopt"` | OB_deopt = 0 | 去优化参数 |
| `"gc-transition"` | OB_gc_transition = 2 | GC 状态转换参数 |
| `"gc-live"` | OB_gc_live = 5 | 活跃 GC 指针列表 |

### 5.3 IR 类层次

```
CallBase
  └── GCStatepointInst        ← gc.statepoint (非 IntrinsicInst, 因为可 invoke)

IntrinsicInst
  └── GCProjectionInst        ← 抽象基类
       ├── GCRelocateInst     ← gc.relocate
       └── GCResultInst       ← gc.result
```

### 5.4 StatepointDirectives

从函数属性解析的控制信息：

```cpp
struct StatepointDirectives {
  uint64_t StatepointID = 0xABCDEF00;     // 默认 ID
  uint32_t NumPatchBytes = 0;             // 可修补字节数
  // 属性名: "statepoint-id", "statepoint-num-patch-bytes"
};
```

Deopt bundle 的 statepoint ID: `0xABCDEF0F`

---

## 6. CodeGen 层

### 6.1 StatepointLowering

**源文件**：`llvm/lib/CodeGen/SelectionDAG/StatepointLowering.cpp`（1322 行）

将 IR 级 `gc.statepoint` 降级为 SelectionDAG `STATEPOINT` 节点。

```
LowerAsSTATEPOINT():
  1. 收集调用目标、参数、GC 指针、deopt 参数
  2. 为 GC 指针和 deopt 值分配溢出槽 (StatepointLoweringState 管理槽池)
  3. 构建 STATEPOINT SDNode:
     <id, num-patch-bytes, num-call-args, call-target,
      call-args..., 
      ConstantOp, calling-conv,
      ConstantOp, flags,
      ConstantOp, num-deopt-args, deopt-args...,
      ConstantOp, num-gc-ptrs, gc-ptrs...,
      ConstantOp, num-gc-allocas, gc-allocas...,
      ConstantOp, num-gc-map-entries, [base/derived pairs]>
  4. gc.relocate → 从 STATEPOINT 的 tied def 获取重定位值
  5. gc.result   → 从 STATEPOINT 的返回值获取
```

### 6.2 StackMaps 序列化

**源文件**：`llvm/lib/CodeGen/StackMaps.cpp`（754 行）

```
recordStatepoint(MI):
  解析 STATEPOINT MI 操作数
  记录 Location 列表 (Register/Direct/Indirect/Constant)
  记录 base/derived 指针对
  附加到 CallsiteInfo

serializeToStackMapSection():
  发射 .llvm_stackmaps 段 (二进制格式 Version 3):
  Header → NumFunctions → NumConstants → NumRecords
  → FunctionInfo[] → Constants[] → CallsiteRecord[]
```

### 6.3 GCMetadataPrinter

| 打印器 | 策略 | 输出格式 |
|--------|------|---------|
| `OcamlGCMetadataPrinter` | ocaml | `caml${module}__frametable`: {返回地址, 帧大小, 活跃偏移[]} |
| `ErlangGCPrinter` | erlang | `.note.gc` 段: {PointCount, SafePointAddr[], StackFrameSize, LiveOffsets[]} |

---

## 7. 屏障支持现状

LLVM GC 基础设施对读写屏障的支持**极其有限**：

| 方面 | 现状 | 说明 |
|------|------|------|
| 读屏障 (`llvm.gcread`) | **无条件降低为 load** | 无内置策略实现实际屏障 |
| 写屏障 (`llvm.gcwrite`) | **无条件降低为 store** | 无内置策略实现实际屏障 |
| Card table | ✗ 无支持 | 需运行时自行实现 |
| Remembered set | ✗ 无支持 | 分代写屏障需运行时实现 |
| 引用计数 | ✗ 无支持 | 需前端插入 inc/dec |
| 对象模型适配 | ✗ 无支持 | 无内置标记/布局支持 |

**这是有意为之**：LLVM GC 基础设施聚焦于**安全点识别和指针重定位**，屏障和对象模型由运行时或自定义 GCStrategy 插件负责。

---

## 8. 适配指南

### 8.1 为新语言运行时适配 GC

**步骤 1：选择 GC 机制**

| 运行时特征 | 推荐机制 |
|-----------|---------|
| 移动式 GC（复制/标记-整理） | gc.statepoint |
| 非移动式 GC（标记-清除） | gc.root 或 gc.statepoint |
| 需要精确栈扫描 | gc.statepoint |
| 不协作目标平台 | ShadowStack |

**步骤 2：实现 GCStrategy 子类**

```cpp
// 示例：自定义策略
struct MyGC : public GCStrategy {
  MyGC() {
    UseStatepoints = true;
    UseRS4GC = true;
  }
  std::optional<bool> isGCManagedPointer(const Type *Ty) const override {
    if (auto *PT = dyn_cast<PointerType>(Ty))
      return PT->getAddressSpace() == 1;
    return std::nullopt;
  }
};
static GCRegistry::Add<MyGC> X("my-gc", "My Custom GC");
```

**步骤 3：前端约定**

- 函数标记 `gc "my-gc"` 属性
- GC 管理指针使用 `addrspace(1)*`
- 非管理指针使用默认地址空间
- 调用 `gc.safepoint_poll` 函数（RS4GC 自动处理）

**步骤 4：运行时约定**

- 解析 `.llvm_stackmaps` 段获取安全点信息
- 在安全点遍历 base/derived 指针对进行重定位
- 读写屏障由运行时自行实现

### 8.2 关键配置选项

| 选项 | 默认 | 说明 |
|------|------|------|
| `spp-rematerialization-threshold` | 6 | 重物化代价阈值 |
| `spp-counted-loop-trip-width` | 32 | 可计数循环跳过阈值（位） |
| `stackmap-version` | 3 | StackMap 二进制格式版本 |
| `enable-patchpoint-liveness` | true | 启用 PATCHPOINT 活跃性分析 |
| `gc-empty-basic-blocks` | false | 启用空基本块清理 |
| `AllowStatepointWithNoDeoptInfo` | false | 允许无 deopt 信息的 statepoint |

---

## 9. 文件索引

### 头文件

| 文件 | 核心内容 |
|------|---------|
| `llvm/include/llvm/IR/GCStrategy.h` | GCStrategy 类、GCRegistry |
| `llvm/include/llvm/IR/BuiltinGCs.h` | linkAllBuiltinGCs() |
| `llvm/include/llvm/IR/Statepoint.h` | GCStatepointInst、StatepointFlags |
| `llvm/include/llvm/IR/IntrinsicInst.h` | GCRelocateInst、GCResultInst |
| `llvm/include/llvm/IR/SafepointIRVerifier.h` | SafepointIRVerifier |
| `llvm/include/llvm/CodeGen/GCMetadata.h` | GCFunctionInfo、GCStrategyMap |
| `llvm/include/llvm/CodeGen/GCMetadataPrinter.h` | GCMetadataPrinter 基类 |
| `llvm/include/llvm/CodeGen/StackMaps.h` | StackMaps、StatepointOpers |
| `llvm/include/llvm/CodeGen/ShadowStackGCLowering.h` | ShadowStackGCLoweringPass |
| `llvm/include/llvm/Transforms/Scalar/RewriteStatepointsForGC.h` | RS4GC |
| `llvm/include/llvm/Transforms/Scalar/PlaceSafepoints.h` | PlaceSafepointsPass |

### 源文件

| 文件 | 行数(约) | 核心内容 |
|------|:-:|---------|
| `llvm/lib/Transforms/Scalar/RewriteStatepointsForGC.cpp` | 3375 | RS4GC 核心算法 |
| `llvm/lib/Transforms/Scalar/PlaceSafepoints.cpp` | 693 | 安全点放置 |
| `llvm/lib/IR/SafepointIRVerifier.cpp` | 909 | 重定位正确性验证 |
| `llvm/lib/CodeGen/SelectionDAG/StatepointLowering.cpp` | 1322 | SelectionDAG 降级 |
| `llvm/lib/CodeGen/FixupStatepointCallerSaved.cpp` | 629 | Post-RA 寄存器溢出修正 |
| `llvm/lib/CodeGen/GCRootLowering.cpp` | 345 | gc.root 降低 + 机器码分析 |
| `llvm/lib/CodeGen/ShadowStackGCLowering.cpp` | 420 | Shadow stack 实现 |
| `llvm/lib/CodeGen/StackMaps.cpp` | 754 | StackMap 序列化 |
| `llvm/lib/CodeGen/StackMapLivenessAnalysis.cpp` | 170 | 活跃性分析 |
| `llvm/lib/CodeGen/GCEmptyBasicBlocks.cpp` | 100 | 空块清理 |
| `llvm/lib/IR/GCStrategy.cpp` | 50 | 策略查找 |
| `llvm/lib/IR/BuiltinGCs.cpp` | 132 | 5 个内置策略 |
| `llvm/lib/CodeGen/GCMetadata.cpp` | - | 元数据管理 |
| `llvm/lib/CodeGen/AsmPrinter/OcamlGCPrinter.cpp` | 182 | Ocaml 帧表 |
| `llvm/lib/CodeGen/AsmPrinter/ErlangGCPrinter.cpp` | 117 | Erlang 帧表 |
| `llvm/lib/Transforms/Utils/StripGCRelocates.cpp` | 66 | 调试工具 |
| `llvm/docs/Statepoints.rst` | 811 | GC Safepoints 文档 |
| `llvm/docs/GarbageCollection.rst` | - | GC with LLVM 文档 |
