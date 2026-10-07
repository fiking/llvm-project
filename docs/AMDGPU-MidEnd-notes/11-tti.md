# §11 TTI 驱动的通用优化利他化

> 数据基准:llvm-project main @ `3eda2aebadd4`(2026-09-28),build-debug 实跑。
> 方法:静态读码(`文件:行号`)+ 动态验证(`opt` 差异 / `-pass-remarks`)。
> 素材:`AMDGPU-MidEnd-notes/scratch/ch11/*`。

---

## 章节定位

前面 §3–§10 讲的都是 AMDGPU **专属 pass**。这一章换个视角:GPU 中端还有一大批**通用优化**(InstCombine、LoopUnroll、SLP/LoopVectorize、Inline、LICM),它们本身与目标无关,但**通过 TargetTransformInfo(TTI)接口**被 AMDGPU "驯化",产出 GPU 友好的代码。

TTI 是 LLVM 的**成本模型抽象**:通用优化在做决策时问 TTI"这条指令多少钱?""这个循环值得展开吗?""这个值是 uniform 的吗?",后端给出答案。AMDGPU 的 TTI 实现在 `llvm/lib/Target/AMDGPU/AMDGPUTargetTransformInfo.cpp`(1996 行)+ `AMDGPUTargetTransformInfo.h`(350 行),核心是 `GCNTTIImpl`。

**"利他化"的含义**:通用优化本来为 CPU 设计,AMDGPU 通过重写 TTI 钩子,让这些优化**反过来为 GPU 的目标服务**——
- 让 LoopUnroll 在私有/LDS 数组上更激进(展开后能用寄存器/LDS);
- 让 Inline 在传大 alloca 时更倾向于内联(避免 scratch 内存);
- 让 UniformityAnalysis 精确识别"哪些值天生 divergent"(workitem_id 等),驱动 §4–§10 的一大票 pass;
- 让向量化/寄存器估算符合 GPU 的 VGPR/SGPR 模型。

```
通用优化 (LoopUnroll/Inline/Vectorize/...)
        │  "这值多少钱?值得做吗?"
        ▼
GCNTTIImpl (1996 行)
        │  查 GCNSubtarget / 地址空间 / uniform 性
        ▼
  GPU 特化的成本答案 → 通用优化产出 GPU 友好代码
```

---

## 11.1 Unrolling:`getUnrollingPreferences`

### 11.1.1 机制

`AMDGPUTTIImpl::getUnrollingPreferences`(`AMDGPUTargetTransformInfo.cpp:114-…`)是 LoopUnroll 的"口味调节器":

```cpp
UP.Threshold = F.getFnAttributeAsParsedInteger("amdgpu-unroll-threshold", 300);
UP.PartialThreshold = ...("amdgpu-partial-unroll-threshold", 150);
UP.MaxCount = std::numeric_limits<unsigned>::max();
UP.Partial = true;
UP.BEInsns += 3;                    // 循环回边条件分支约 3 条 exec 操作
UP.UnrollVectorizedLoop = true;     // 已向量化的循环也展开
UP.Runtime = true;                  // 支持运行时 trip count 展开
```

**三个地址空间相关的阈值**(:38-51):
- `--amdgpu-unroll-threshold-private`(:38,默认 **2700**)——含私有(寄存器可放)数组访问的循环。
- `--amdgpu-unroll-threshold-local`(:43,默认 **1000**)——含 LDS 访问的循环。
- `--amdgpu-unroll-threshold-if`(:48,默认 **200**)——循环内有依赖本地 PHI 的 `if` 时给的额外奖励。

**核心逻辑**(:160-213):遍历循环内指令,若访问私有地址空间(alloca)或 LDS,把阈值提到对应的更高值——**因为展开后这些访问能被分配到寄存器/LDS,收益大**。"if 依赖本地 PHI"的奖励(:175-190)则鼓励展开以消除 divergent 分支。

**metadata 覆盖**(:143-157):循环可带 `!{!"amdgpu.loop.unroll.threshold", i32 N}` 直接指定阈值,优先级最高。

### 11.1.2 动态验证

素材:`scratch/ch11/unroll_in.ll`(带 `amdgpu.loop.unroll.threshold=100000` metadata)。

```bash
opt -passes='loop-unroll-full' -S unroll_in.ll | grep -c "store volatile"
```

实测:8 次迭代的循环**完全展开**(8 个 store,无循环),无论是否带 metadata(小循环本身就会展开)。metadata 的作用在**大循环**上体现——给一个刚好卡在默认阈值边缘的循环加 metadata 就能强制展开。

### 11.1.3 设计动机

GPU 的循环展开比 CPU 更激进,因为:
1. **寄存器/LDS 充裕**(相对缓存),展开后内存访问变寄存器操作,收益直接。
2. **无分支预测失败惩罚**(SIMT 不缺这种惩罚),展开的代价低。
3. **divergent 分支很贵**(EXEC mask 操作),"if 依赖本地 PHI"奖励(:175)专门鼓励展开消分支。

---

## 11.2 Inlining:寄存器压力与 alloca 惩罚

### 11.2.1 机制

GPU inlining 的核心矛盾:**不内联就得把 private 数组放 scratch 内存**(慢),内联了又可能撑爆寄存器。AMDGPU 用三个钩子精细调节:

**① `areInlineCompatible`**(:1633):除了常规检查,额外要求 **SIModeRegisterDefaults 兼容**(:1646-1649)——两个函数的寄存器模式(dx10_clamp 等)必须一致才能内联。还有 `InlineMaxBB`(:76,默认 1100)的编译时间保护:合并后 BB 数超限就拒绝。

**② `adjustInliningThreshold`**(:1753):传大 alloca 时**主动提高阈值**鼓励内联。

```cpp
unsigned Threshold = adjustInliningThresholdUsingCallee(CB, TLI, this);
unsigned AllocaSize = getCallArgsTotalAllocaSize(CB, DL);
if (AllocaSize > 0)
  Threshold += ArgAllocaCost;      // :63-64, 默认 4000
```

`getCallArgsTotalAllocaSize`(:1726)算出"如果不内联,会有多少字节掉进 scratch"。`adjustInliningThresholdUsingCallee`(:1673)还考虑寄存器压力:超过 **26 SGPR / 32 VGPR**(:1674-1675)就按栈传参成本惩罚。

**③ `getCallerAllocaCost`**(:1764):超过 `ArgAllocaCutoff`(:70-71,默认 256 字节)的 alloca 计入成本,与阈值奖励对冲(`:1783` 注释明确写了成本与奖励相消的设计)。

### 11.2.2 动态验证

素材:`scratch/ch11/inline_in.ll`(callee 接收 2KB private 数组)。

```bash
opt -passes='cgscc(inline)' -pass-remarks=inline -S inline_in.ll
```

实测 remark:
```
remark: 'callee' inlined into 'k' with (cost=-165020, threshold=69712)
```

**threshold=69712** 是个天文数字——正是 `ArgAllocaCost`(4000)被 `getInliningThresholdMultiplier` 放大后的结果。2KB alloca 远超 256 字节 cutoff,TTI 判定"不内联就得进 scratch,代价惨重",于是把阈值拉到天上去,**强制内联**。这是 TTI 利他化的教科书案例:通用 inliner 本不知道"private 数组传参 = scratch 内存",是 AMDGPU TTI 告诉它的。

### 11.2.3 设计动机

GPU 没有"调用栈"的廉价抽象——函数调用的参数如果不是寄存器放得下,就得进 scratch(global 内存的私有区),每次访问都是内存往返。所以"传大数组给函数"在 GPU 上是**性能悬崖**,TTI 必须把 inliner 往"宁可内联爆寄存器,也不进 scratch"的方向推。

---

## 11.3 Divergence 分析:`isSourceOfDivergence` / `isAlwaysUniform`

### 11.3.1 机制

这是**整个 AMDGPU 中端的地基**。§4–§10 的 UniformityAnalysis 最终都落到这两个 TTI 钩子上——它们回答"哪些值天生 divergent/uniform"。

`isSourceOfDivergence`(:1205-1266)的判定规则:

| 值类型 | divergent? | 理由 |
|---|---|---|
| VGPR 传的 kernel 参数(`!isArgPassedInSGPR`,:1207) | **是** | 每 lane 不同 |
| private/flat 地址空间 load(:1211-1217) | **是** | 同地址不同 lane 可能读到不同值(栈) |
| `atomicrmw`/`cmpxchg`(:1224) | **是** | 串行执行,后到的 lane 读到前一个的结果 |
| `workitem_id_y/z`(:1232-1238) | **看工作组形状** | 若维度大小为 1 则 uniform |
| 一般函数调用/invoke(:1248-1254) | **是** | 保守假设 |
| private→flat 的 addrspacecast(:1259-1263) | **看 subtarget** | globally addressable scratch 时 divergent |

`isAlwaysUniform`(:1268-1340)是反向判定,几个精巧的 pattern:
- **TID/wavefrontsize 商**(:1305-1311):`workitem_id_x >> log2(wavesize)` 在 X 维度不跨 wave 重置时 uniform。
- **AND 掩码**(:1314-1319):`workitem_id_x & mask`,mask 低位全 0 且 ≥wavesize 时 uniform。
- **`amdgcn_if`/`else` 的 extractvalue{1}**(:1329-1334):F16(§10)插入的 EXEC mask 提取,uniform。

### 11.3.2 动态验证

素材:`scratch/ch11/diverge_in.ll`。

```bash
opt -passes='print<uniformity>' -disable-output diverge_in.ll
```

实测输出:
```
UniformityInfo for function 'k':
  DIVERGENT:   %pl = load i32, ptr addrspace(5) %arr    ; private load
  DIVERGENT:   store volatile i32 %pl, ...              ; 用了 divergent 值
```

而 `%gl = load i32, ptr addrspace(1) %g`(global、uniform 指针)和 `br i1 %c1`(基于 `%gl`)**不在 DIVERGENT 列表**——即被判定 uniform。这正是 `isSourceOfDivergence` 的规则:private load 是 divergent 源,global uniform 指针 load 不是。

### 11.3.3 设计动机

GPU 的 SIMT 模型下,"值是否 uniform(全 wave 相同)"决定了:
- 用标量寄存器(SGPR,全 wave 共享)还是向量寄存器(VGPR,每 lane 一份);
- 分支走标量路径(快)还是 EXEC mask 路径(慢);
- 能否做 §7 F13、§8 F2 那些"依赖 uniform 前提"的优化。

这些判定无法纯从 IR 语法推出——必须知道**硬件语义**(VGPR 传参、原子串行、workitem_id 的含义),所以放在 TTI 里。

---

## 11.4 向量化与寄存器模型

### 11.4.1 机制

GPU 的"向量"与 CPU 的 SIMD 向量完全不同——**每个 lane 已经是向量的一个元素**,IR 层的"向量"是 per-lane 的寄存器打包。TTI 的几个钩子反映这个模型:

**`getNumberOfRegisters`**(:301-311):返回**固定值 4**。
```cpp
// This is really the number of registers to fill when vectorizing /
// interleaving loops, so we lie to avoid trying to use all registers.
return 4;
```
注释直白:"我们撒谎了"。因为 VGPR 不是 CPU 那种"N 个向量寄存器"模型,返回真实值会让向量化器过度使用寄存器,所以硬编码 4 来**保守限制**。

**`getRegisterBitWidth`**(:313-326):scalar 32 bit;向量宽度看 subtarget——有 packed FP64/U64 就 128,有 packed FP32 就 64,否则 32。

**`getLoadStoreVecRegBitWidth`**(:376-392):global/constant 地址空间 **512 bit**,private 是 `8 * MaxPrivateElementSize`,其他默认 128。这告诉向量化器"这条内存路径一次能搬多宽"。

**`getLoadVectorFactor`/`getStoreVectorFactor`**(:355-374):超过 128 bit 时压回——`if (VecRegBitWidth > 128) return 128 / LoadSize`,防止过宽向量撑爆寄存器。

**`preferSLPInstCountCheck`**(:346-353):gfx940/gfx950 上**返回 false**——因为 2 元素向量树会让 `v_mov_b32` 变 `v_mov_b64`,增加寄存器压力反而更慢(注释 :347-352 详细解释了回归原因)。

### 11.4.2 设计动机

CPU 向量化的目标是"用满 SIMD 寄存器宽度";GPU 的目标是**"别让 per-lane 寄存器爆掉"**。VGPR 是最紧俏资源(直接决定 occupancy——能同时驻留多少 wave),所以 TTI 的向量化钩子处处"踩刹车":
- 谎报寄存器数为 4(:310);
- load/store 超 128 bit 就压回(:360, :371);
- 对寄存器压力敏感的 gfx940/950 关掉 SLP 的 inst-count 启发式(:346)。

这是**"利他化"的反面教材**——不是让通用优化更激进,而是**更保守**,因为 CPU 的"越宽越好"直觉在 GPU 上是错的。

---

## 11.5 指令成本模型

`getArithmeticInstrCost`(:577)、`getCFInstrCost`(:997)、`getCastInstrCost`(:1037)、`getVectorInstrCost`(:1098)等,为 InstCombine/SimplifyCFG/Vectorize 提供逐指令成本。

**关键 GPU 特性**(:577 起的算术成本):
- **64-bit 操作**:`get64BitInstrCost`(:1823)按 subtarget 的 `hasFullRate64Ops`/`hasHalfRate64Ops`/quarter rate 返回不同成本——64-bit ALU 在很多 GCN 上是半速甚至四分之一速。
- **i64 AND/OR/XOR**(:612-616):"typically split into 2 VALU instructions",成本 ×2。
- **类型合法化**:`getTypeLegalizationCost`(:1828-1841),超过 256 bit(8 dword)的类型惩罚加重(:1834-1839)。

这些成本数字驱动 InstCombine 决定"这个变换值不值",SimplifyCFG 决定"分支展开 vs 保留"。

---

## 11.6 缓存与预取

- `getCacheLineSize`(:1844):有 vmem/smem prefetch 指令时返回数据 cache line 大小,否则 0。
- `getPrefetchDistance`(:1850):`hasPrefetch()` 时返回 128。
- `shouldPrefetchAddressSpace`(:1854):只对 flat/global 地址空间预取。

这些钩子让通用的数据预取 pass(loop-data-prefetch)在 GPU 上只对合适的地址空间、合适的距离发预取指令。

---

## 本章小结

| TTI 钩子 | 影响的通用优化 | GPU 特化点 |
|---|---|---|
| `getUnrollingPreferences`(:114) | LoopUnroll | 私有/LDS 数组激进展开,if-PHI 奖励,metadata 覆盖 |
| `adjustInliningThreshold`(:1753) | Inline | 大 alloca 传参强制内联(避免 scratch) |
| `areInlineCompatible`(:1633) | Inline | SIMode 寄存器兼容 + InlineMaxBB 编译时间保护 |
| `isSourceOfDivergence`(:1205) | UniformityAnalysis(全局) | workitem_id/private load/atomic 等 divergent 源 |
| `isAlwaysUniform`(:1268) | UniformityAnalysis | TID/wavesize 商、AND 掩码、if/else mask |
| `getNumberOfRegisters`(:301) | 向量化/展开 | **谎报 4**,防 VGPR 爆 |
| `getLoadStoreVecRegBitWidth`(:376) | 向量化 | global 512bit,private 受限 |
| `preferSLPInstCountCheck`(:346) | SLPVectorize | gfx940/950 关闭(寄存器压力) |
| `getArithmeticInstrCost`(:577) | InstCombine 等 | 64-bit 速率、i64 逻辑 ×2 |

**核心洞察**:TTI 是 AMDGPU 中端的**"隐形指挥官"**。§3–§10 的专属 pass 是"明线",TTI 驱动的通用优化是"暗线"——它们不出现在 AMDGPU 目录里,却同样深刻地塑造了最终代码。理解 GPU 中端,**必须把这两条线合起来看**:专属 pass 做"只有 GPU 需要的变换"(EXEC mask、kernel 参数),TTI 让"通用变换长出 GPU 的形状"(寄存器保守、uniform 感知、scratch 厌恶)。

**对昇腾的总迁移建议**:昇腾的 TTI(若基于 LLVM)应重点复刻:
1. **divergence 源表**(`isSourceOfDivergence`)——这是所有 uniform 优化的地基,把昇腾的 lane-id、私有内存、原子操作登记为 divergent 源。
2. **寄存器保守策略**(`getNumberOfRegisters` 谎报)——NPU 的寄存器同样宝贵,别让 CPU 直觉的向量化器用爆。
3. **scratch 厌恶的 inline 阈值**(`adjustInliningThreshold`)——NPU 的私有内存访问同样昂贵,大 alloca 传参要强制内联。
