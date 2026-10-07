# §8 原子操作层(F2 AMDGPUAtomicOptimizer + AtomicExpand 交互)

> 数据基准:llvm-project main @ `3eda2aebadd4`(2026-09-28),build-debug 实跑。
> 方法:静态读码(`文件:行号`)+ 动态验证(`llc -stop-after` 差分)。
> 素材:`AMDGPU-MidEnd-notes/scratch/ch08/{f02,f02b}_*.{ll,s}`。

---

## 章节定位

GPU 原子操作的**经典痛点**:一个 wavefront 里 64 个 lane 对**同一个地址**做 `atomic_add`,硬件要串行处理 64 次内存事务,争用严重。F2 的思路是**"先 wave 内归约,再单 lane 原子"**——把 64 次 atomic 变成 1 次。

这是中端唯一一个**在 IR 层引入新控制流**(`ComputeLoop`/`ComputeEnd` 基本块、`if (is_first_lane)`)的优化 pass,介于"纯 IR 优化"和"指令选择"之间。

```
64 个 lane 同时执行 atomicrmw add [p], %v
        │  F2: ballot + scan + 单 lane atomic
        ▼
ballot 出活跃 lane → wave 内 scan 求总和
  → 仅 lane 0 执行 atomicrmw add [p], %total
  → readfirstlane 广播结果,各 lane 加回自己的偏移
```

**与 AtomicExpand 的关系**:F2 **必须跑在 AtomicExpand 之前**(`AMDGPUTargetMachine.cpp:1621-1623` 注释明确写 `// Run atomic optimizer before Atomic Expand`)。F2 操作的是**高层的 `atomicrmw` IR 指令**,AtomicExpand 会把它 lowering 成 CAS 循环或目标 intrinsic——一旦 lowering,单 lane 优化的机会就没了。

---

## F2 AMDGPUAtomicOptimizerPass

### 8.1.1 一句话定位
对**指针 uniform(全 wave 同地址)、值可 divergent** 的 `atomicrmw`,改成"wave 内 scan/reduce 求总和 → 单 lane 执行 atomic → 广播结果",把 N 次原子内存事务压成 1 次。

### 8.1.2 运行位置

**两处**,都在 llc 管线(`AtomicExpandPass` 之前):

- **legacy**(`AMDGPUTargetMachine.cpp:1617-1623`):
```cpp
// Run atomic optimizer before Atomic Expand
if ((TM.getTargetTriple().isAMDGCN()) &&
    (TM.getOptLevel() >= CodeGenOptLevel::Less) &&    // ← O1+
    (AMDGPUAtomicOptimizerStrategy != ScanOptions::None)) {
  addPass(createAMDGPUAtomicOptimizerPass(AMDGPUAtomicOptimizerStrategy));
}
addPass(createAtomicExpandLegacyPass());
```
- **new PM**(`:2406-2411`):同样条件,`addFunctionPass(AtomicExpandPass(TM), PMW)` 紧随其后。

**三重 gate**:
1. `isAMDGCN()`(排除 R600)
2. **`TM.getOptLevel() >= Less`**(O0 完全不挂,实测验证)
3. `--amdgpu-atomic-optimizer-strategy`(`:525-530`)≠ `None`,默认 `Iterative`,可选 `DPP`

### 8.1.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUAtomicOptimizer.cpp`(1013 行)。

#### 收集阶段(`visitAtomicRMWInst`,:185-254)

过滤条件层层收窄:

```cpp
void AMDGPUAtomicOptimizerImpl::visitAtomicRMWInst(AtomicRMWInst &I) {
  if (I.getType()->isVectorTy() || I.isVolatile())   // vector/volatile 跳过
    return;
  switch (I.getPointerAddressSpace()) {               // 只认 global/LDS
  case AMDGPUAS::GLOBAL_ADDRESS:
  case AMDGPUAS::LOCAL_ADDRESS: break;
  default: return;
  }
  AtomicRMWInst::BinOp Op = I.getOperation();
  switch (Op) {  // 只认 13 种可交换+可结合的二元 op
  case Add/Sub/And/Or/Xor/Max/Min/UMax/UMin/FAdd/FSub/FMax/FMin: break;
  default: return;
  }
  // FP 操作只支持 f32/f64
  if (isFPOperation(Op) && !(f32 || f64)) return;

  // 关键:指针必须 uniform(全 wave 同地址)
  if (UA.isDivergentAtUse(I.getOperandUse(PtrIdx))) return;

  bool ValDivergent = UA.isDivergentAtUse(I.getOperandUse(ValIdx));
  if (ValDivergent) {
    if (ScanImpl == DPP && !ST.hasDPP()) return;   // DPP 策略要求硬件支持
    if (!isLegalCrossLaneType(Ty)) return;         // 只支持 i32/i64/f32/f64
  }
  ToReplace.push_back({&I, Op, ValIdx, ValDivergent, IsLDS});
}
```

**可优化判据核心**(:230):**指针 uniform**。只要全 wave 访问同一地址,就可以把 N 个 lane 的值先归约成 1 个,单 lane 做 atomic。值本身可以 divergent(每个 lane 贡献不同值),这正是 scan 要解决的。

`visitIntrinsicInst`(:256-353)是姊妹函数,处理 `llvm.amdgcn.{raw,struct}.buffer.atomic.*` 16 种 buffer atomic intrinsic,映射到同样的 13 种 BinOp。区别是 buffer atomic **永远不是 LDS**(`:352` 注释)。

#### 变换阶段(`optimizeAtomic`,:692-1002)

对每条收集到的指令:

**Step 1 — Pixel Shader 特殊处理**(:729-742):PS 有 helper lane(为求导存在的非活跃 lane),跨 lane 通信必须用 `amdgcn_ps_live` 检查包起来,避免 helper lane 参与。

**Step 2 — Ballot 算活跃 lane**(:755-773):
```cpp
// 全 wave 投票,得到活跃 lane 位掩码
CallInst *Ballot = B.CreateIntrinsicWithoutFolding(amdgcn_ballot, WaveTy, true);
// mbcnt: 数"我前面有几个活跃 lane",用于确定"谁是第一个"
Mbcnt = ...amdgcn_mbcnt_lo/hi(Ballot, 0);
```

**Step 3 — 分两条路径**(:795-836):

- **不需要结果 或 值 uniform**(`UseWaveReductionIntrinsic=true`):直接用 `llvm.amdgcn.wave.reduce.<op>` intrinsic(`getWaveReductionIntrinsic` :655 映射 Add→`wave.reduce.add` 等),一个 intrinsic 完成全 wave 归约。
- **需要结果 且 值 divergent**(`UseWaveReductionIntrinsic=false`):必须做**exclusive scan**(每个 lane 需要"我前面所有 lane 的和"作为自己的偏移):
  - **DPP 策略**(:804-826):`buildScan`(:447-…)生成一串 `amdgcn_update_dpp` 调用(ROW_SHR 移位累加),最后一 lane 的值就是总和,`readlane` 取出。
  - **Iterative 策略**(:827-832):`buildScanIteratively`(:86 声明)生成 `ComputeLoop`/`ComputeEnd` 两个新基本块,用 `readlane`/`writelane` 迭代累加。

**Step 4 — 单 lane 分支**(:841-903):
```cpp
// 只有"前面没有活跃 lane"的那个 lane(即第一个活跃 lane)进入
Value *Cond = B.CreateICmpEQ(Mbcnt, B.getInt32(0));
Instruction *SingleLaneTerm =
    SplitBlockAndInsertIfThen(Cond, &I, false, nullptr, &DTU, nullptr);
// 克隆原 atomic,值换成归约结果
Instruction *NewI = I.clone();
NewI->setOperand(ValIdx, NewV);   // NewV 是 wave 总和
```

**Step 5 — 结果广播与回算**(:909-997):
- `readfirstlane` 把单 lane 的 atomic 结果广播到全 wave(:922-923)。
- 每个 lane 用自己的 `LaneOffset`(exclusive scan 结果 或 `Mbcnt * V`)加回广播值,得到"如果我独立执行 atomic 会拿到的旧值"(:971)。
- FP 操作有 NaN/符号修正(`:983` 注释:第一个活跃 lane 必须用 `BroadcastI` 本身,避免 `V * +0.0` 产生错误符号/NaN)。

### 8.1.4 动态验证

素材:`scratch/ch08/f02_in.ll`,4 个 kernel 覆盖各分支。

```bash
llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 -O2 \
    -stop-after=amdgpu-atomic-optimizer f02_in.ll -o f02_out.ll
```

| Kernel | 输入特征 | 输出(实测) |
|---|---|---|
| `k_add` | uniform ptr + divergent val + 用结果 | **Iterative**:ballot + `ComputeLoop`/`ComputeEnd` 控制流 + 单 lane atomic + `readfirstlane` 广播 |
| `k_noret` | 同上但**不用结果** | **wave.reduce 捷径**:一行 `call i32 @llvm.amdgcn.wave.reduce.add.i32(i32 %id, i32 1)` 完成归约,无控制流 |
| `k_divptr` | **divergent ptr**(GEP by lane id) | **原样保留**(`:230` 指针 uniform 检查拦截) |
| `k_vol` | volatile | **原样保留**(`:186` 拦截) |

`k_add` 变换后核心片段(实测 `f02_out.ll`):
```llvm
%1 = call i64 @llvm.amdgcn.ballot.i64(i1 true)      ; 活跃 lane 掩码
%5 = call i32 @llvm.amdgcn.mbcnt.lo(i32 %2, i32 0)  ; 我前面几个活跃
...
ComputeLoop:                                          ; 新增循环做 scan
  %Accumulator = phi i32 [ 0, %0 ], [ %18, %ComputeLoop ]
  ...
8:                                                    ; 单 lane 块
  %9 = atomicrmw add ptr addrspace(1) %p, i32 %18 monotonic  ; 只剩 1 次 atomic
10:
  %11 = phi i32 [ poison, %ComputeEnd ], [ %9, %8 ]
  %12 = call i32 @llvm.amdgcn.readfirstlane.i32(i32 %11)    ; 广播
  %13 = add i32 %12, %17                                    ; 加回自己的偏移
```

**策略对比**(实测):

| Flag | `k_add` 形态 |
|---|---|
| 默认(Iterative) | `ComputeLoop`/`ComputeEnd` 控制流 |
| `--amdgpu-atomic-optimizer-strategy=DPP` | 7 条 `llvm.amdgcn.update.dpp.i32` 链(`ROW_SHR0 \| 1/2/4/8` + `BCAST15`/`BCAST31`/`QUAD_PERM`),**无控制流**,`readlane` 取 lane 63 |
| `--amdgpu-atomic-optimizer-strategy=None` | pass 整体不挂,原样输出(0 个 ballot) |
| `-O0` | gate `OptLevel >= Less` 拦截,原样输出 |

**DPP 输出片段**(`f02_dpp.ll`):
```llvm
%8 = call i32 @llvm.amdgcn.update.dpp.i32(i32 0, i32 %7, i32 273, ...)  ; ROW_SHR0|1
%10 = call i32 @llvm.amdgcn.update.dpp.i32(i32 0, i32 %9, i32 274, ...) ; ROW_SHR0|2
%12 = call i32 @llvm.amdgcn.update.dpp.i32(i32 0, i32 %11, i32 276, ...); ROW_SHR0|4
%14 = call i32 @llvm.amdgcn.update.dpp.i32(i32 0, i32 %13, i32 280, ...); ROW_SHR0|8
%16 = call i32 @llvm.amdgcn.update.dpp.i32(i32 0, i32 %15, i32 322, ...); BCAST15
%18 = call i32 @llvm.amdgcn.update.dpp.i32(i32 0, i32 %17, i32 323, ...); BCAST31
%21 = call i32 @llvm.amdgcn.readlane.i32(i32 %19, i32 63)              ; 取最后 lane
```
7 条 DPP 指令完成 64-lane 归约,对比 Iterative 的循环,DPP 是**纯数据流**无分支。

**LDS 变体**(`f02b_in.ll`,`addrspace(3)`):同样被优化,`atomicrmw add ptr addrspace(3) @lds` 保留在单 lane 块中,`IsLDS` 标志只影响 DPP 策略的 `amdgpu.expected.active.lanes` metadata 阈值检查(`:703-710`,阈值 5)。

**最终 asm**(`f02.s`):`k_add` 只剩 1 条 `global_atomic_add ... sc0 sc1`(对比未优化会是每 lane 1 条),验证收益。

### 8.1.5 设计动机

**内存争用是 GPU 原子的头号杀手**。64 个 lane 同时 hit 同一 cache line,硬件要序列化,吞吐降到 1/64。F2 把"每 lane 一次 atomic"变成"wave 内 ALU 归约(DPP/循环)+ 单 lane atomic",原子操作数从 N 降到 1。

**为什么放中端而非后端?** 因为它要**引入控制流**(Iterative 的循环、单 lane 分支)和**调用 UniformityAnalysis**——这些是 IR 层的能力,后端 MachineIR 阶段做控制流重构代价高得多。注释 `:1-21` 明确把两种策略的取舍写在文件头。

**为什么必须在 AtomicExpand 前?** AtomicExpand 会把 `atomicrmw` lowering 成 `cmpxchg` 循环(对不原生支持的操作)或目标 intrinsic。一旦 lowering,`atomicrmw add` 的"原子加"语义被拆成 load/cas/store 序列,F2 再也认不出这是可归约的原子。

### 8.1.6 昇腾启示

昇腾 NPU 的原子操作同样面临多 lane 争用。可借鉴:
- **指针 uniform 是优化的前提**:昇腾的 uniformity 分析同样可用于识别"全 warp 同地址"的 atomic,做 warp 内归约。
- **双策略(DPP vs Iterative)**:DPP 是"shuffle 指令链"零控制流,Iterative 是"循环 + readlane"。昇腾若有 warp shuffle 指令,对应 DPP 策略;否则用迭代。
- **`wave.reduce` 捷径**:当**不需要每个 lane 的旧值**时(如纯累加计数器),直接用硬件 wave reduction 指令最省。昇腾的 `reduce` 类指令可复用此模式。
- **与 atomic lowering 的顺序**:F2-before-AtomicExpand 的教训是——**语义越高层,优化空间越大**。昇腾应在自己的 atomic lowering(如到 `atomic_add` 指令)之前插入等价优化。

---

## 与前后章节的关系

- **§7 F13 UniformIntrinsicCombine** 也依赖 UniformityAnalysis,但只做**删除冗余**;F2 则**主动引入** ballot/scan/readfirstlane 这些 lane 操作 intrinsic。两者一个"消"一个"造",但都建立在对 uniform/divergent 的精确理解上。
- **§9 F3 AMDGPUCodeGenPrepare** 会在 F2 之后进一步处理 atomic 的寻址模式(如把 `atomicrmw` 的指针运算折叠进指令)。
- **§10 F1 AMDGPUAnnotateUniformValues** 是 F2 的上游——F1 标注的 uniform 信息(通过 `!amdgpu.uniform` metadata 等)会影响 UniformityAnalysis 的精度,间接影响 F2 的可优化判据。
- F2 引入的 `llvm.amdgcn.ballot`/`readlane`/`update_dpp` intrinsic 会在后端指令选择阶段映射到 `v_ballot`/`v_readlane`/DPP 指令(见 NVPTX/AMDGPU backend 章节)。
