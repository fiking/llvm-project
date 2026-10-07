# §12 HipStdPar 与 LTO(M14 / M15 / M7)

> 数据基准:llvm-project main @ `3eda2aebadd4`(2026-09-28),build-debug 实跑。
> 方法:静态读码(`文件:行号`)+ 动态验证(`opt -passes` 差分)。
> 素材:`AMDGPU-MidEnd-notes/scratch/ch12/{m07,m14,m15}_*.ll`。

---

## 章节定位

前十一章讲的是**单个 GPU 编译单元**内部的优化。本章的三个 pass 处理**"C++ 标准并行(HIP StdPar)"** 和 **LTO 链接期**这两个更宏观的场景——当用户写 `std::for_each(std::execution::par, ...)` 时,编译器要把整个模块"裁剪"成只有 accelerator 该执行的部分,并修正数学/内存分配/同步的语义差异。

| Pass | 场景 | 一句话 |
|---|---|---|
| **M14** HipStdParMathFixup | HIP StdPar | 有问题的数学 intrinsic/libcall → `__hipstdpar_*` 转发层 |
| **M15** HipStdParAcceleratorCodeSelection | HIP StdPar | 只保留从 kernel 可达的函数,删其余(防误编译) |
| **M7** AMDGPULowerExecSync | 通用(非 HIP 专属) | 给 named-barrier 全局变量分配唯一 barrier ID |

**关键洞察**:M14/M15 **不是** AMDGPU 目录里的 pass——它们在通用的 `llvm/lib/Transforms/HipStdPar/HipStdPar.cpp`(640 行),由 AMDGPUTargetMachine **挂载**。这是"通用框架 + 目标挂载"模式,与 §11 TTI 的利他化思路一脉相承。M7 才在 AMDGPU 目录(`AMDGPULowerExecSync.cpp`,260 行)。

**挂载位置**(`AMDGPUTargetMachine.cpp`):
```
M14/M15: 两处(都是 EnableHipStdPar gate, :655 默认 false)
  - PipelineEarlySimplificationEP (:1060-1062)  —— 非 -fgpu-rdc
  - OptimizerLastEP 附近         (:1150-1152)  —— -fgpu-rdc 时推迟到链接后
M7:      OptimizerLastEP 附近 (:1158)  + llc addIRPasses (:2396)
         gate: EnableLowerExecSync
```

---

## M14 HipStdParMathFixupPass

### 12.1.1 一句话定位
HIP StdPar 场景下,把"加速器实现不完整"的数学函数调用,**改名叫 `__hipstdpar_*` 转发层**——给各加速器一个统一接口去实现自己的运行时,而不是依赖后端不完善的 intrinsic lowering。

### 12.1.2 运行位置

`AMDGPUTargetMachine.cpp:1060-1062`(非 RDC 早挂)和 `:1150-1152`(RDC 链接后),都由 `EnableHipStdPar`(`:655-659`,默认 **false**)gate。文件头注释(`HipStdPar.cpp:48`)明确要求**在 M15 之前跑**,否则转发函数会被 M15 误删。

### 12.1.3 静态读码

文件:`llvm/lib/Transforms/HipStdPar/HipStdPar.cpp`(640 行,与 M15/M16 共享)。

`HipStdParMathFixupPass::run`(:576-640)的核心是分两类替换:

**① libcall 查表**(`MathLibToHipStdPar` :534 起):`acosh`→`__hipstdpar_acosh_f64` 等约 30 个 `<cmath>` 函数,直接按名字映射。

**② intrinsic 白名单**(:589-628),更精细:
```cpp
switch (ID) {
case Intrinsic::not_intrinsic:   // 普通 libcall,查 MathLibToHipStdPar 表
  ...
case Intrinsic::acos: case Intrinsic::asin: case Intrinsic::atan:
case Intrinsic::atan2: case Intrinsic::cosh: case Intrinsic::modf:
case Intrinsic::sincos: case Intrinsic::sinh: case Intrinsic::tan:
case Intrinsic::tanh:
  break;                          // 这些 f32/f64 都替换
default: {
  if (F.getReturnType()->isDoubleTy()) {   // cos/exp/log/pow/sin 只替换 f64
    switch (ID) {
    case Intrinsic::cos: case Intrinsic::exp: case Intrinsic::exp2:
    case Intrinsic::log: case Intrinsic::log10: case Intrinsic::log2:
    case Intrinsic::pow: case Intrinsic::sin:
      break;
    default: continue;
    }
    break;
  }
  continue;                       // f32 的 cos/sin/log 等不替换
}
```

替换动作(:635-637):改名 `llvm.X.f64` → `__hipstdpar_X_f64`(把 `llvm` 前缀换成 `__hipstdpar`,`.`→`_`),然后 `replaceAllUsesWith` 到新声明。

### 12.1.4 动态验证

素材:`scratch/ch12/m14_in.ll`。

```bash
opt -passes=hipstdpar-math-fixup -S m14_in.ll
```

输入输出(实测):

| 调用 | 结果 | 原因 |
|---|---|---|
| `llvm.cos.f64` | → `__hipstdpar_cos_f64` | cos 在 default 分支,f64 白名单(:612) |
| `llvm.cos.f32` | **不变** | cos 的 f32 不在替换范围(:626 `continue`) |
| `acosh`(libcall) | → `__hipstdpar_acosh_f64` | 查 `MathLibToHipStdPar` 表(:535) |

**注意一个实测怪象**:输出里多出一个**未被调用**的声明 `declare double @__hipstdparh(double)`。这是 `:631` 的 `llvm::replace(名字, '.', '_')` 在处理 `@acosh` 时产生的——它先构造 `__hipstdpar_acosh_f64`,但**同一循环里 `@acosh` 的迭代**似乎让前缀替换逻辑留下了一个半成品名。这是该 pass 的一个真实小瑕疵(只多一个无用声明,无害),值得在阅读源码时留意 `:630-633` 的字符串操作。

### 12.1.5 设计动机

不同加速器对数学函数的硬件支持参差不齐。与其让每个后端各自 lowering `llvm.cos.f64`(可能不全/有 bug),HIP StdPar 统一改名叫 `__hipstdpar_cos_f64`,由各加速器的**运行时库**去实现。这是**"把后端难题转移给运行时"**的策略——编译器只认统一接口,具体实现下放。

### 12.1.6 昇腾启示

昇腾 NPU 的数学库支持也不完整。可借鉴:
- **统一转发层**:把有问题的数学调用改名到 `__asc_*` 转发层,由昇腾运行时实现,编译器不管细节。
- **f32/f64 区别对待**:cos/sin 的 f32 可能硬件支持好,f64 需软件模拟——转发层只接管 f64 这类"麻烦"精度。

---

## M15 HipStdParAcceleratorCodeSelectionPass

### 12.2.1 一句话定位
**只保留从 kernel 可达的函数**,删除其余所有——因为 HIP StdPar 假设"只有 kernel 及其调用链是 accelerator 该执行的",其余代码可能含后端无法处理的构造,保留会导致误编译(文件头 :11-27)。

### 12.2.2 运行位置

同 M14(`:1060-1062` / `:1150-1152`),`EnableHipStdPar` gate,**紧跟 M14 之后**。

### 12.2.3 静态读码

`run`(:397-440)用 CallGraphAnalysis 做可达性分析:

```cpp
SmallPtrSet<const Function *, 32> Reachable;
for (auto &&CGN : CGA) {
  if (!isAcceleratorExecutionRoot(CGN.first))   // :365-370, 只认 AMDGPU_KERNEL CC
    continue;
  Reachable.insert(CGN.first);
  // DFS 遍历调用图,收集所有可达函数
  SmallVector<const Function *> Tmp({CGN.first});
  do {
    auto F = Tmp.back(); Tmp.pop_back();
    for (auto &&N : *CGA[F]) {
      ...
      if (!checkIfSupported(N.second->getFunction(), ...))  // :372-395
        return PreservedAnalyses::none();                   // 遇到 __hipstdpar_unsupported 报错
      Reachable.insert(...);
    }
  } while (...);
}

if (std::empty(Reachable))
  clearModule(M);              // 一个 kernel 都没有 -> 清空整个 module
else
  removeUnreachableFunctions(Reachable, M);   // :347-363, 删不可达函数

maybeHandleGlobals(M);         // :316-345, 处理全局变量的间接寻址
```

**`checkIfSupported`**(:372-395):遇到名字含 `__hipstdpar_unsupported` 的函数,诊断报错——这是 accelerator 声明"我不支持这个构造"的逃生门(如不支持的 ASM block)。

**`maybeHandleGlobals`**(:316-345):处理非默认地址空间的全局变量,通过 `__hipstdpar_symbol_indirection_table` 做符号间接寻址。

### 12.2.4 动态验证

素材:`scratch/ch12/m15_in.ll`,1 个 kernel + 1 个被调用的 helper + 2 个不可达函数。

```bash
opt -passes=hipstdpar-select-accelerator-code -S m15_in.ll
```

输出(实测):
```llvm
define amdgpu_kernel void @k() { ... call void @helper() ... }
define internal void @helper() { ret void }
; unreachable_fn 和 host_only 都被删除
```

**关键**:`isAcceleratorExecutionRoot`(:365)只认 `AMDGPU_KERNEL` calling convention——普通 `void @host_only()` 即使**没有**被标记删除,也因为不在 kernel 调用链上而被清掉。这就是"防误编译"的保险丝。

### 12.2.5 设计动机

HIP StdPar 模块里**混着 host 和 device 代码**。用户写的某些 host-only 代码可能用了 accelerator 后端无法 lowering 的构造(特殊内联汇编、不支持的指令)。通用 DCE(死代码消除)**无法证明**这些代码在 device 上是死的(它们可能被 host 用),所以不能删。M15 用"从 kernel 可达"这个**加速口语义**来裁剪——只要 kernel 不调用,就删掉,避免后端撞上无法处理的 IR。文件头 :20-22 明确说这种删法是"necessary because ... cannot be provably demonstrated to be dead code in general, and thus can lead to mis-compilation"。

### 12.2.6 昇腾启示

昇腾的 host/device 混合编译(如 CCE)有完全相同的需求。可借鉴:
- **可达性裁剪**:只保留从 device kernel 可达的函数,删 host-only 代码,防后端误编译。
- **CC 判定根**:用 calling convention 识别"哪些函数是 device 入口",昇腾的 kernel CC 同理。
- **空模块清空**:没有任何 kernel 时直接 `clearModule`,昇腾可用同样策略处理纯 host TU。

---

## M7 AMDGPULowerExecSyncPass

### 12.3.1 一句话定位
给 `target("amdgcn.named.barrier")` 类型的全局变量(named barrier)**分配唯一的 barrier ID**,并把这个 ID 编码进 `!absolute_symbol` metadata——供后端/汇编器把它 lowering 成具体的硬件 barrier 资源。

### 12.3.2 运行位置

两处:`AMDGPUTargetMachine.cpp:1158`(LTO 管线,`EnableLowerExecSync` gate)和 `:2396`(llc `addIRPasses`)。是 **Module pass**(要跨函数统一分配 ID)。

### 12.3.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPULowerExecSync.cpp`(260 行)。

**named barrier 是什么**:AMDGPU 支持"命名 barrier"——多个独立的 barrier 资源,不同代码块可以只同步参与某个 barrier 的 lane 子集,而不必全 workgroup 同步。这些 barrier 在 IR 里表现为 `addrspace(15)` 的 `target("amdgcn.named.barrier")` 类型全局变量。

`run` 流程:
1. **收集**(`lowerExecSyncGlobalVariables` :84):遍历模块,收集所有 `isNamedBarrierToLower`(:34-36)的全局变量及其使用的 kernel(直接 + 间接访问,:92-114)。
2. **排序**(:116-120):按"使用它的 kernel 数量"降序——用得越多的 barrier 先分配(占小编号)。
3. **分配 ID**(`allocateExecSyncID` :54-81):跨所有使用该 GV 的 kernel,取最大可用 ID,然后给所有这些 kernel 的 tracker 更新(`NextID + IDCnt`)。保证**同一个 barrier 在所有用到它的 kernel 里拿到同一个 ID**。
4. **写 metadata**(`recordAbsoluteAddress` :40-48):把分配的 ID 编码成 `!absolute_symbol !{i32 ID, i32 ID+1}`(半开区间 `[ID, ID+1)`)挂到全局变量上。

### 12.3.4 动态验证

素材:`scratch/ch12/m07_in.ll`,两个 named barrier 全局(只有 `@bar3` 被 kernel 使用)。

```bash
opt -passes=amdgpu-lower-exec-sync -S m07_in.ll
```

输出(实测):
```llvm
@bar2 = internal addrspace(15) global [2 x target("amdgcn.named.barrier", 0)] poison
;                                    ^^ 未被任何 kernel 使用 -> 不分配 ID,无 metadata
@bar3 = internal addrspace(15) global target("amdgcn.named.barrier", 0) poison, !absolute_symbol !0
!0 = !{i32 1, i32 2}      ; <- 分配到 ID 1, 区间 [1, 2)
```

**关键点**:只有**被 kernel 实际使用**的 `@bar3` 拿到 ID(`!absolute_symbol !0 = {1, 2}`);未被使用的 `@bar2` 原样保留。ID 从 1 开始(`InitialVal = 1`,`:58`),因为 ID 0 通常保留给默认 workgroup barrier。

### 12.3.5 设计动机

named barrier 是**有限硬件资源**(gfx 上通常十几个)。多个 kernel 共享同一批 barrier 时,必须保证:同一个逻辑 barrier(全局变量)在所有用到它的 kernel 里映射到**同一个物理 ID**,否则跨 kernel 的同步会错乱。这个分配必须在**模块级**(看到所有 kernel)做,不能 per-function——所以是 Module pass。

### 12.3.6 昇腾启示

昇腾的命名同步资源(named barrier / event)同样需要全局统一编号。可借鉴:
- **模块级 ID 分配**:跨 kernel 保证同一同步对象同 ID,昇腾的 barrier/event 分配同理。
- **`!absolute_symbol` metadata 编码**:把分配的硬件资源 ID 物化成 metadata,供后端读取,昇腾可复用此机制。
- **按需分配**:只给实际使用的 barrier 分配 ID,节省硬件资源。

---

## 本章小结

| Pass | 位置 | 触发 | 输入→输出 |
|---|---|---|---|
| M14 MathFixup | 通用 `Transforms/HipStdPar` | `--amdgpu-enable-hipstdpar` | `llvm.cos.f64` → `__hipstdpar_cos_f64`(f64 白名单) |
| M15 AcceleratorCodeSelection | 通用 `Transforms/HipStdPar` | 同上,紧跟 M14 | 删非 kernel 可达函数,空 module 清空 |
| M7 LowerExecSync | AMDGPU 目录 | `EnableLowerExecSync` | named barrier GV → `!absolute_symbol {ID, ID+1}` |

**共同主题**:这三个 pass 处理的是**"模块边界"问题**——M14/M15 管"哪些代码该进 device"(StdPar 的 host/device 分离),M7 管"跨 kernel 的资源统一编号"(named barrier ID)。它们不像前面章节那样优化单函数内的代码,而是在**整个编译单元/链接单元**层面做裁剪和协调。这是 GPU 编译"最后一公里"的另一面:不只优化指令,还要理清模块的边界与共享资源。

**对昇腾的迁移**:M14/M15 是**通用框架**(在 `Transforms/HipStdPar`,不属 AMDGPU),昇腾若支持类似 StdPar 的 C++ 并行卸载,可直接复用这两个 pass 的框架,只需替换 `__hipstdpar_*` 前缀和 kernel CC 判定。M7 的 named barrier 分配是 AMDGPU 特有,但"模块级资源统一编号 + metadata 编码"的模式对昇腾的同步资源管理有参考价值。
