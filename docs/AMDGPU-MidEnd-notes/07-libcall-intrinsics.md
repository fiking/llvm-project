# §7 LibCall 与 Intrinsic 层(F12 / F15 / F13 / M8)

> 数据基准:llvm-project main @ `3eda2aebadd4`(2026-09-28),build-debug 实跑。
> 方法:静态读码(`文件:行号`)+ 动态验证(`opt -passes=... -S` / `llc -stop-after` 差分)。
> 素材:`AMDGPU-MidEnd-notes/scratch/ch07/{f12,f13,f15,m08,m08b}_*.{ll,s}`。

---

## 章节定位

本章四个 pass 处理的是**"函数调用"到"机器可用形式"的最后一公里**:

| Pass | 对象 | 方向 |
|---|---|---|
| **F15** AMDGPUUseNativeCalls | libcall(`_Z3sinf` 等) | 换名为 `__nv_*`/native 版本(**opt-in**) |
| **F12** AMDGPUSimplifyLibCalls | libcall(OCML/OCL mangled) | 折叠成 LLVM intrinsic / 常量 / sincos 合并 |
| **F13** AMDGPUUniformIntrinsicCombine | `llvm.amdgcn.*` lane 操作 | uniform 时删除/降级,省 v_readlane |
| **M8** AMDGPULowerIntrinsics | barrier/buffer-load/monitor | 按 subtarget 语义降级与打 metadata |

**层次关系**:
```
libcall(_Z3sinf) ──F15──> native_sin        (换实现,激进)
       │──F12──> llvm.sin / 常量            (换 IR,保守)
llvm.amdgcn.readlane ──F13──> 源值           (删冗余,uniform 时)
llvm.amdgcn.s.barrier ──M8──> wave.barrier   (降硬件,单 wave 时)
```

**挂载拓扑**(两条管线都出现):
- **opt 侧**(`AMDGPUTargetMachine.cpp:1081-1092` PeepholeEP):F15 → F12 → F13,**F15 无条件挂**,F12/F13 各自由 `--amdgpu-simplify-libcall`(:502,默认 true)/ `--amdgpu-enable-uniform-intrinsic-combine`(:670,默认 true)gate。
- **llc 侧**(`CodeGenPassBuilder::addIRPasses`):F13 在 `:2383-2384` 再挂一次(legacy 版在 `:1586-1588`);M8 在 `:2476` `addModulePass(AMDGPULowerIntrinsicsPass(getTM()), PMW)`,**只存在于 llc 管线**。

> ⚠️ **工具陷阱**(实测):本机 `build-debug/bin/opt` 的 `--print-passes` **不列出**任何 `amdgpu-*` pass(它们通过 `registerPassBuilderCallbacks` 的 target hook 注册,见 `AMDGPUTargetMachine.cpp:1021-1025` 的 `GET_PASS_REGISTRY`),但 `-passes=amdgpu-simplifylib` 等名字**实际可用**。而 M8 即使用 `opt -passes=amdgpu-lower-intrinsics` 能跑,其 barrier 降级分支有 `TM.getOptLevel() > None` 的硬门槛(见 §7.4.3),**在 opt 里永远是 no-op**,必须改用 `llc -O2 -stop-after=amdgpu-lower-intrinsics` 验证。

---

## F15 AMDGPUUseNativeCallsPass

### 7.1.1 一句话定位
把 mangled 数学库调用(`_Z3sinf` = OpenCL `sin(float)`)**整个换成 `__nv_*`/native 版本**(更低精度、直接用硬件指令),是 `-ffast-math` 语义之外的**手动激进开关**,默认**完全 no-op**。

### 7.1.2 运行位置

PeepholeEP 第一个(`:1086`),**无 gate 条件直接挂**——但 pass 内部自带开关:

```cpp
// AMDGPULibCalls.cpp:2088-2094
PreservedAnalyses AMDGPUUseNativeCallsPass::run(...) {
  if (UseNative.empty())                    // 没传 --amdgpu-use-native 就退出
    return PreservedAnalyses::all();
  ...
}
```

`UseNative` 是 `cl::list<std::string>`(`:36-39`),逗号分隔的函数名列表,或 `all`。

### 7.1.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPULibCalls.cpp`(2107 行,与 F12 **共享**)。

核心判断 `useNative`(`:511-536`):

```cpp
bool AMDGPULibCalls::useNative(CallInst *aCI) {
  Function *Callee = aCI->getCalledFunction();
  if (!Callee || aCI->isNoBuiltin())
    return false;

  FuncInfo FInfo;
  if (!parseFunctionName(Callee->getName(), FInfo) || !FInfo.isMangled() ||
      FInfo.getPrefix() != AMDGPULibFunc::NOPFX ||     // 只处理无前缀(libm/ocml)
      getArgType(FInfo) == AMDGPULibFunc::F64 ||       // 不处理 double
      !HasNative(FInfo.getId()) ||                     // 查 native 白名单表
      !(AllNative || useNativeFunc(FInfo.getName())))  // 没开 all 且不在列表
    return false;
  ...
  FInfo.setPrefix(AMDGPULibFunc::NATIVE);              // 换成 __nv_ 前缀
  FunctionCallee F = getFunction(aCI->getModule(), FInfo);
  aCI->setCalledFunction(F);                           // 原地改 callee
  return true;
}
```

**关键点**:
1. **只换名,不换 IR 结构**——`setCalledFunction` 原地改,调用点参数不变。
2. **F64 永不换**(:519)——double 精度路径保守。
3. **sincos 特判**(`:524-525` → `sincosUseNative` :475-509):如果 `sin` 和 `cos` 都在 native 列表,拆成两个独立调用(`splitsin`/`splitcos`),把"合并的 sincos"打回两个 native 调用——因为 native 版本没有 sincos 融合价值。

### 7.1.4 动态验证

素材:`scratch/ch07/f15_in.ll`,两个 fast 调用 `_Z3sinf`/`_Z3cosf`。

```bash
# 无 flag:完全不动
opt -passes=amdgpu-usenative -S f15_in.ll
#   → 输出与输入相同(F15 内部 UseNative.empty() 直接返回)

# --amdgpu-use-native=all + --amdgpu-prelink:
opt -passes=amdgpu-usenative --amdgpu-use-native=all --amdgpu-prelink -S f15_in.ll
#   %s = call fast float @_Z10native_sinf(float %x)
#   %c = call fast float @_Z10native_cosf(float %x)
#   declare float @_Z10native_sinf(float)   <- 新声明被插入
```

**注意**:必须加 `--amdgpu-prelink`(`EnablePreLink`,:31-34),否则 `getFunction` 找不到已链接的 native 定义就放弃(prelink 模式允许**现场声明**新函数,postlink 模式要求定义已在 module 里)。这是 F15 与 F12 共享的 gate。

### 7.1.5 设计动机

数学库有两套实现:**OCML**(精确,慢,大量指令)和 **native**(近似,几条硬件指令)。LLVM 默认走精确路径,把"换实现"的决定权留给用户显式 flag,因为精度损失不可自动推断。`--amdgpu-use-native` 就是给愿意牺牲精度的 HPC 场景的手动逃生门。

### 7.1.6 昇腾启示

Ascend NPU 同样有两套数学库(`libdevice` 精确版 vs `native_` 前缀近似版)。可借鉴:
- **显式 opt-in 而非隐式 fast-math**:把激进优化做成独立 flag,不和 `fast` 捆绑,降低误伤。
- **prelink/postlink 双模**:链接前允许现场声明,链接后要求定义存在——对应昇腾的"编译期链接 device lib"与"运行时已链接 fatbin"两阶段。

---

## F12 AMDGPUSimplifyLibCallsPass

### 7.2.1 一句话定位
把可识别的 libcall(OCML/OCL mangled 名)**就地折叠**:常量查表、换成等价 LLVM intrinsic、pow/rootn 特例展开、sincos 融合——**不动调用结构,只在 IR 层降复杂度**。

### 7.2.2 运行位置

PeepholeEP 第二个(`:1087-1088`),由 `--amdgpu-simplify-libcall`(`:502-506`,默认 true)gate,**O1+** 生效。

### 7.2.3 静态读码

文件同上 `AMDGPULibCalls.cpp`,入口 `AMDGPUSimplifyLibCallsPass::run`(`:2063-2086`),遍历所有 `CallInst` 交给 `fold(CI)`(`:601`)。

`fold` 主分发(`:601-790`):

```cpp
bool AMDGPULibCalls::fold(CallInst *CI) {
  Function *Callee = CI->getCalledFunction();
  if (!Callee || Callee->isIntrinsic() || CI->isNoBuiltin())
    return false;                          // intrinsic 不处理

  FuncInfo FInfo;
  if (!parseFunctionName(Callee->getName(), FInfo))
    return false;                          // 认不出 mangled 名就放弃
  ...
  if (TDOFold(CI, FInfo))                  // 1. 常量查表(acos(0)=pi/2 等)
    return true;
  ...
  switch (FInfo.getId()) {
  case EI_EXP:   return tryReplaceLibcallWithSimpleIntrinsic(B, CI, Intrinsic::exp, ...);
  case EI_SQRT:  return tryReplaceLibcallWithSimpleIntrinsic(B, CI, Intrinsic::sqrt, true, true, false);
  case EI_POW / EI_POWR / EI_POWN:  return fold_pow(...) / expandFastPow(...);
  case EI_SIN / EI_COS:             return fold_sincos(...);   // 融合成 sincos
  ...
  }
}
```

**三条路径**:

1. **TDOFold(表驱动常量折叠)**(`:848-887`):~30 张 `TableEntry` 静态表(`tbl_acos` :199 起),`{input, result}` 对,调用参数是常量且命中表就换成 `ConstantFP`。实测 `acos(0.0)` → `f0x3FF921FB54442D18`(= π/2)。

2. **Intrinsic 替换**(`tryReplaceLibcallWithSimpleIntrinsic` :130-134):`_Z3expf` → `llvm.exp.f32`, `_Z4sqrtf` → `llvm.sqrt.f32`。前提是 fast-math 允许(`FMF.approxFunc()` 或明确白名单)。实测见下。

3. **sincos 融合**(`fold_sincos` :1721-1810+):同一基本块里 `sin(x)` 和 `cos(x)` 同时出现,合并成一个 `sincos(x, &cos_result)` 调用,省一次三角函数求值。`sin`/`cos` 的 fast-math 标志取**交集**(`FMF &= OtherOp->getFastMathFlags()`,:1802)。

### 7.2.4 动态验证

素材:`scratch/ch07/f12_in.ll`。

```bash
opt -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 -passes=amdgpu-simplifylib -S f12_in.ll
```

输入:
```llvm
%e = call fast float @_Z3expf(float %x)    ; fast 标志
%s = call float @_Z4sqrtf(float %x)        ; 无 fast
%a = call double @_Z4acosd(double 0.0)     ; 常量
```

输出(实测 `f12_out.ll`):
```llvm
%e = call fast float @llvm.exp.f32(float %x)    ; ← fast 触发 intrinsic 替换
%s = call float @llvm.sqrt.f32(float %x)        ; ← sqrt 是安全白名单(:777-779)
; acos 调用整个消失,store 直接写常量:
store volatile double f0x3FF921FB54442D18, ...  ; ← TDOFold 查表命中
```

**陷阱**:fast-math 的门是**逐函数**的——`EI_EXP` 要求 `FMF.approxFunc()`(`:641-642`),而 `EI_SQRT`/`EI_FABS` 等是无条件白名单(`AllowMinSizeF32=true, AllowF64=true`)。不要以为所有函数都靠 fast 触发。

### 7.2.5 设计动机

设备端数学库(OCML)函数调用有 prolog/epilog 开销,且是**黑盒**(优化器看不到函数体)。把能静态确定的折叠掉、能映射到 LLVM intrinsic 的换掉,后续 InstCombine/后端才能继续优化。**这是把"库调用"变成"一等 IR 公民"的关键一步**。

### 7.2.6 昇腾启示

昇腾的 `libdevice` 调用同样是黑盒。可借鉴:
- **mangled 名识别表**:`AMDGPULibFunc::parse` 的 Itanium mangling 解析可直接复用模式,昇腾的 `__asc_*` 命名也可建表。
- **常量查表(TDOFold)**:对 `sin(pi/2)` 这类 HPC 常见常量,提前折叠避免运行时调用。
- **sincos 融合**:三角函数对在同一 BB 出现时融合,昇腾也可做对应 intrinsic 合并。

---

## F13 AMDGPUUniformIntrinsicCombinePass

### 7.3.1 一句话定位
利用 UniformityAnalysis 的结果,**删除/降级冗余的 lane 操作 intrinsic**:参数已证 uniform 时 `readlane`/`permlane64` 直接换成源值(读 uniform 值不需要 lane 操作),`ballot(uniform_cond)==0` 折叠成 `!cond`,`wave_shuffle` 按 uniform 性降级成 `readlane`。

### 7.3.2 运行位置

**两处**:
- **opt 侧** PeepholeEP 第三个(`:1090-1091`),`--amdgpu-enable-uniform-intrinsic-combine`(`:670`,默认 true)gate,O1+。
- **llc 侧** `addIRPasses`(`:2383-2384`)再挂一次——**设计上有意跑两遍**:opt 阶段清掉明显的,llc 阶段在 backend  lowering 后再清一次新增的。

### 7.3.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPUUniformIntrinsicCombine.cpp`(202 行,短小)。

核心是 `optimizeUniformIntrinsic`(`:53-137`)的 switch:

```cpp
case Intrinsic::amdgcn_readlane:
  if (isDivergentUseWithNew(II.getOperandUse(0), UI, Tracker))
    return false;
  II.replaceAllUsesWith(Src);    // uniform 的 readlane 就是源值本身
  II.eraseFromParent();
  return true;

case Intrinsic::amdgcn_ballot: {
  // (icmp eq ballot, 0) -> xor cond, 1
  // (icmp ne ballot, 0) -> cond
  for (User *U : II.users())
    if (ICmpInst 命中 && 操作数 uniform)
      替换为 not/原值
}

case Intrinsic::amdgcn_wave_shuffle:
  if (value uniform)  替换为 value;       // 整个 wave 同一值,shuffle 无意义
  else if (index uniform) 降级为 readlane; // 从固定 lane 读
```

**注意**:`readfirstlane` **故意不简化**(`:56-58` 注释),因为前端用它强制把值拷贝到 SGPR,防止后端生成意外的 waterfall loop——这是**性能语义**,不是正确性语义。

### 7.3.4 动态验证

素材:`scratch/ch07/f13_in.ll`(5 个 kernel,覆盖各分支)。

```bash
opt -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 -passes=amdgpu-uniform-intrinsic-combine -S f13_in.ll
```

| Kernel | 输入 | 输出(实测) |
|---|---|---|
| `k_uniform` | `readlane(workgroup_id_x, 0)` | **整个 readlane 删除**,直接 store `%id` |
| `k_divergent` | `readlane(workitem_id_x, 0)` | **保留**(workitem_id 是 divergent) |
| `k_ballot` | `ballot(uniform_c)==0` | `xor i1 %c, true`,ballot 调用残留但 icmp 被替换 |
| `k_ws` | `wave_shuffle(workgroup_id_x, 1)` | **替换为 `%id`**(value uniform) |
| `k_ws2` | `wave_shuffle(workitem_id_x, 1)` | **降级为 `readlane(%id, 1)`**(index uniform) |

`k_ballot` 的 ballot 调用本身没删(因为它还有别的 use),但 `icmp eq %ballot, 0` 被换成了 `xor i1 %c, true`——**从"全 wave 投票再比较"变成"本地取反"**,省一条 ballot 指令。

### 7.3.5 设计动机

GPU 上 lane 操作(`v_readlane_b32`、`v_ballot`)是**跨 lane 通信**,比 ALU 贵。当 UniformityAnalysis 已经证明值是 uniform(全 wave 相同),这些操作就是纯浪费。文件头注释(`:10-18`)明确警告:此 pass 可能让某些指令从"静态 uniform"变成"不再静态 uniform",但**动态 uniform 性不变**,正确性由下游 convergent 指令的 isel 兜底(自动插 `v_readfirstlane`)。

### 7.3.6 昇腾启示

昇腾的 warp 级原语(`shfl`、`vote`)同样有 uniform 优化空间。可借鉴:
- **依赖 UniformityAnalysis 而非启发式**:精确分析比模式匹配可靠。
- **readfirstlane 保留**:把"强制拷贝到标量寄存器"的语义留给前端控制,后端不擅自动它——昇腾的 `mov_to_scalar` 类指令同理。

---

## M8 AMDGPULowerIntrinsicsPass

### 7.4.1 一句话定位
按 **subtarget 能力**降级/改写 AMDGPU intrinsic:单 wave 工作组的 `s_barrier` 降为 `wave_barrier`(省硬件 barrier),`s_cluster_barrier` 展开成 signal+wait 序列(无对应硬件指令),`ptr_s_buffer_load` 打 `!invariant.load` metadata,`s_monitor_sleep` 按硬件限制 clamp。

### 7.4.2 运行位置

**只挂在 llc 管线**:`CodeGenPassBuilder::addIRPasses`(`:2476`):
```cpp
addModulePass(AMDGPULowerIntrinsicsPass(getTM()), PMW);
```
在 `AMDGPULowerBufferFatPointersPass`(:2472)之后、`LowerSwitch` 之前。**opt 管线不挂**。

### 7.4.3 静态读码

文件:`llvm/lib/Target/AMDGPU/AMDGPULowerIntrinsics.cpp`(271 行)。

入口按 intrinsic ID 分发(`run`,:67-93)。核心 `visitBarrier`(:98-213):

```cpp
bool AMDGPULowerIntrinsicsImpl::visitBarrier(IntrinsicInst &I) {
  const GCNSubtarget &ST = TM.getSubtarget<GCNSubtarget>(*I.getFunction());
  bool IsSingleWaveWG = false;

  if (TM.getOptLevel() > CodeGenOptLevel::None) {   // ← O0 时直接跳过!
    unsigned WGMaxSize = ST.getFlatWorkGroupSizes(*I.getFunction()).second;
    IsSingleWaveWG = WGMaxSize <= ST.getWavefrontSize();  // 工作组 <= 1 个 wave
  }
  ...
  if (IsWorkgroupScope && IsSingleWaveWG) {
    // s_barrier -> wave_barrier(单 wave 时 workgroup barrier 就是 wave barrier)
    B.CreateIntrinsicWithoutFolding(..., Intrinsic::amdgcn_wave_barrier, {});
    I.eraseFromParent();
    return true;
  }
  ...
}
```

**关键陷阱**(:108):`TM.getOptLevel() > CodeGenOptLevel::None` 是硬门槛。`opt` 工具的 TM 默认 OptLevel 是 `None`,所以 **`opt -passes=amdgpu-lower-intrinsics` 对 barrier 分支永远是 no-op**——必须用 `llc -O1+` 验证(实测确认,见下)。

**三类降级**:

1. **单 wave 降级**(:181):`WGMaxSize <= WavefrontSize`(如 `amdgpu-flat-work-group-size="1,32"` 且 wave=32)时,workgroup barrier 等价于 wave barrier,后者不需要 LDS barrier 资源。
2. **cluster barrier 展开**(:115-141):`s_cluster_barrier` 无硬件指令,展开成"先 workgroup barrier(或单 wave 时 wave barrier)+ 单 wave 发 cluster signal + wait"。
3. **split barrier**(:160 附近):subtarget 支持 split barrier(`ST.hasSplitBarriers()`)时,`s_barrier` 拆成 `s_barrier_signal` + `s_barrier_wait`,允许中间插入独立指令。

### 7.4.4 动态验证

素材:`scratch/ch07/m08_in.ll`,两个 kernel(`k_small` 工作组 ≤32,`k_big` ≤1024)。

```bash
# opt 侧(实测):s_barrier 原样保留,pass 是 no-op
opt -passes=amdgpu-lower-intrinsics -S m08_in.ll   # 无变化!

# llc -O2(stop-after):
llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx942 -O2 \
    -stop-after=amdgpu-lower-intrinsics m08_in.ll -o m08_out.ll
```

`m08_out.ll`(实测):
```llvm
define amdgpu_kernel void @k_small() {
  call void @llvm.amdgcn.wave.barrier()   ; ← 降级成功
}
define amdgpu_kernel void @k_big() {
  call void @llvm.amdgcn.s.barrier()      ; ← 大工作组保留
}
```

`llc -O0` 下两者都保持 `s_barrier`(验证 opt-level gate)。

最终 asm(`m08.s`):`k_small` 里只有注释 `; wave barrier`(wave barrier 在 gfx942 上常零开销,甚至不发指令),`k_big` 生成真实 `s_barrier` 指令。

**`ptr_s_buffer_load`**(`m08b_in.ll`,实测):调用被加上 `!invariant.load !0` metadata(`%p = call ... , !invariant.load !0`),提示后端 buffer descriptor 是只读的,可进 scalar cache。

### 7.4.5 设计动机

barrier 是 GPU 上最贵的同步原语之一。当编译期能证明"整个工作组就是一个 wave"时,workgroup barrier 和 wave barrier 语义等价,但前者要占用 LDS barrier 资源、后者走 wave 内同步(便宜得多)。这是**利用工作组大小静态信息做硬件指令选择**的典型例子。cluster barrier 则是"软件模拟新硬件特性"——老硬件没有这条指令,就用已有的 signal/wait 原语拼出来。

### 7.4.6 昇腾启示

昇腾的 barrier 体系(`barrier_all`、`barrier_arrive/wait` 分离)与 split barrier 思想同构。可借鉴:
- **按工作组大小降级同步原语**:昇腾若已知 block 大小 ≤ 单 warp,可用更便宜的同步。
- **metadata 标记只读 buffer**:`!invariant.load` 对应昇腾的 L1 buffer const 标记,帮助 cache 分配。
- **硬门槛 opt-level**:把"依赖优化级别"的语义降级放在 llc 而非 opt,避免 `opt` 用户误以为会生效——这是文档/工具链设计的一致性问题。

---

## 本章小结

| Pass | 输入 | 输出 | 关键 gate | 挂载点 |
|---|---|---|---|---|
| F15 UseNativeCalls | `_Z3sinf` | `__nv_sinf` | `--amdgpu-use-native` 非空 | PeepholeEP(无条件) |
| F12 SimplifyLibCalls | libcall | intrinsic/常量/sincos | `--amdgpu-simplify-libcall`(默认 on) | PeepholeEP |
| F13 UniformIntrinsicCombine | lane intrinsic | 删除/降级 | `--amdgpu-enable-uniform-intrinsic-combine`(默认 on) | PeepholeEP + llc `:2383` |
| M8 LowerIntrinsics | barrier/buffer intrinsic | 降级/metadata | **llc only**,OptLevel>None | llc `:2476` |

**共同主题**:这四个 pass 都在做**"把高层抽象调用映射到当前硬件最便宜的形式"**——库函数→intrinsic→硬件指令,每一步都依赖目标特定知识(mangled 名表、uniformity 分析、subtarget feature)。它们是中端与后端的**接缝层**:F12/F13 还保留着 IR 的通用性,M8 已经开始做硬件指令选择的预演。
