# §8 SDAG vs GISel：共存机制与迁移现状

> 基准：llvm-project main @ `3eda2aebadd4`，build-debug 实测。
> 素材来源：子代理调研（引用与动态输出均已核实）+ 主会话代写组装。
> 前置引用：ResetMachineFunctionPass（RegAlloc-notes/04-06）、-global-isel-abort 三态（NVPTX-notes/04 §6.5）、LCSSA 条件化（AMDGPU-notes/03 §5.3）。

---

## 8.1 头条发现（动态实证，修正任务前提）

**AArch64 在所有优化级别默认都跑 GISel 流水线，但 O>0 的非 optnone 函数逐函数 fallback 到 SDAG**：
- `-O2` 默认 `-debug-pass=Structure`：`-irtranslator(93) → -instruction-select(104) → -aarch64-isel(106)` **双选择器同管线**
- `-stats`：`3 reset-machine-function - Number of functions reset`（3/3 回退）；`-pass-remarks-missed='gisel.*'` → `unable to lower function`（IRTranslator.cpp:5125）
- 机制：AArch64TargetMachine.cpp:401-414 默认 `setGlobalISel(true)+setGlobalISelAbort(Disable)`；AArch64CallLowering.cpp:650-663 `IsGlobalISelPreferred = 显式flag || O≤0 || optnone`
- `-O0` 默认输出 md5 == 显式 -global-isel（纯 GISel，**FastISel 已被替换**）；`-aarch64-enable-global-isel-at-O=-1` → 0 reset 纯 SDAG

## 8.2 fallback 机制（函数级粒度）

- TargetPassConfig.cpp:1075-1083：Reset pass 在 Selector==GISel 时插入；`Selector != GlobalISel || !isGlobalISelAbortEnabled()` 时 addInstSelector——**SDAG 字面上是管线内的回退消费者**
- ResetMachineFunctionPass.cpp:30-66（引用 RegAlloc-notes）：per-function 粒度实测（"Resetting: f0/g/vec" 逐函数）；**clearVirtRegTypesOnReturn scope_exit 无论成败都清 LLT 元数据**——GISel 类型永不泄漏给 SDAG
- InstructionSelect.cpp:~321 DebugCounter 强制回退钩子（测试用）
- **官方设计论证**（docs/GlobalISel/index.md:100-110）：明确放弃"无 fallback"的两条理由（需模拟 IRTranslator；鲁棒性+渐进改进）

## 8.3 target 覆盖现状（grep @ 3eda2aebadd4）

| 状态 | target | 证据 |
|---|---|---|
| **GISel-only** | **SPIRV** | SPIRVTargetMachine.cpp:91 setGlobalISel(true)+setFastISel(false)+setO0WantsFastISel(false)——**唯一无 fallback 的 target** |
| 默认开（GISel-first+回退） | AArch64 | §8.1 |
| 有管线默认关（-global-isel 显式） | X86/ARM/RISCV/PPC/WASM/M68k/BPF | X86TargetMachine.cpp:470-490（abort 模式需自补 X86GlobalBaseReg :488——SDAG 正常发射它的共存补偿）、ARM :480-497、RISCV :523-555 |
| 零 GISel | NVPTX | NVPTX-notes/04 §5.3 已证（vreg 透传无 bank 约束） |

**GISel target 行数分布**：AMDGPU 24,176（含 CallLowering 1,760）/ AArch64 18,613 / RISCV 5,956 / X86 4,391 / WASM 1,699 / PPC 1,381 / M68k 497 / BPF 178——**GPU 最大需求**（bank 约束），SPIRV 是新生 target 无沉没成本所以敢 only。

官方文档无 supported/experimental 表；index.md:77 "先替换 AArch64 的 FastISel，下一步替换 optimized ISel 的 SDAG"；顶部 "work in progress"。

## 8.4 迁移 10 年未竟的架构原因（核心论证）

git 首commit `105cf2b179e0`（2016-01-20），距今 **~10.5 年**；3,012 GISel commits vs 15,311 SDAG。

| 因素 | 证据 |
|---|---|
| **SDAG 沉没成本** | 通用 87,708 行 + ISelLowering：X86 **65,606**/AArch64 36,540/NVPTX 8,143/AMDGPU 6,460——重写=数个 target 各数万行 |
| **bank 价值不均** | AMDGPU 24K GISel 全为 SGPR/VGPR vs NVPTX 零收益——表面积论证成立时 GISel 才值 |
| **质量差距** | DAGCombiner 32,531/146 visit vs CombinerHelper 8,707/159 方法；实测 two_roads.ll O2：SDAG 13 指令 vs GISel 14（fmov 残留——常数乘未同构折叠） |
| **编译时间** | 官方仅 "fast pipeline 在 FastISel 1.5x 内，目标 1.1/1.2x"（index.md:89-93），**无 SDAG 对比基准**；微测两者 ~0.10s（debug build 不可作证据，如实标注） |
| **渐进轨迹** | 2018-01-02 O0 默认（854d10d10bf5）→ 2026-01-29 optnone 用 GISel（ad1a45b903b8 #174746）→ 2026-02-23 at-O=-1 修复（53648f571a0e #182250）——**按函数类别 creeping，正是 fallback 设计所 enabling** |

## 8.5 共存的设计启示

- **MF.reset()=新路线可廉价失败**——渐进迁移的工程学基础
- **路线条件化 IR pass 必须假设对方仍会跑**：AMDGPU LCSSA 仅在无回退可能（abort 开）时才对 GISel 禁用（AMDGPUTargetMachine.cpp:1746-1750/2510-2513，commit 3ad810ea9a97）
- **钩子签名鸿沟**：LowerOperation 命令式 switch vs LegalizerInfo 声明式表+TableGen match table（Porting.md 四大类）——**移植=重写非翻译**
- O2 回退触发链标注：remark 出自 IRTranslator.cpp:5125、门控 AArch64CallLowering.cpp:650-663，两点间调用链未完全追完（诚实标注）

## 8.6 昇腾映射（推理级，待验证）

1. **CCE 路线判定**：LLVM fork 大概率 SDAG-only——验证法：grep CANN 二进制/源码的 GlobalISel/IRTranslator 符号（待验证）
2. **PyPTO 的选择**：小规模下"**单路线+声明式谓词表**"比"双路线+fallback"务实——fallback 机器的前提是①存在成熟老路线做安全网②函数级风险异质（不同函数适合不同路线）；PyPTO tile 层两者皆无，应走 GISel 的正交化设计思想（谓词表/观察者/声明式规则）但单路线实现

---

## 引用清单

| 引用 | 内容 |
|---|---|
| AArch64TargetMachine.cpp:401-414 / AArch64CallLowering.cpp:650-663 | 默认开+O 门控 |
| SPIRVTargetMachine.cpp:91 | GISel-only |
| X86TargetMachine.cpp:470-490 / ARM :480-497 / RISCV :523-555 | 默认关 |
| TargetPassConfig.cpp:1075-1083 / InstructionSelect.cpp:~321 | fallback 插入 |
| docs/GlobalISel/index.md:77-110 | 官方叙述 |
| IRTranslator.cpp:5125 | O2 回退 remark 源 |
| git: 105cf2b179e0 / 854d10d10bf5 / ad1a45b903b8 / 53648f571a0e | 迁移轨迹 |
| 实测：two_roads.ll（13 vs 14 指令/3 reset/双选择器管线/md5 相等） | scratch/ |

（AMDGPU GISel 行数口径差 22,416 vs 24,176：文件集不同，后者含 CallLowering 1,760——已在引用中注明。）
