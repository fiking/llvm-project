# NVPTX 后端深度分析

> 数据基准：llvm-project main @ `3eda2aebadd4`（2026-09-29），本仓库工作区实测。
> 方法：静态分析（引用一律 `文件:行号`，全部经 grep/read 核对）+ 动态验证（build-debug clang/llc 实跑，含 -### 工具链、PTX 输出 diff、-print-after-all 流水线）。
> 姊妹篇：`nvptx-vs-amdgpu-analysis.md`（横向对比）、`AMDGPU_Deep_Analysis.md`（对偶深潜）。本文档是 NVPTX 单侧纵深——**"虚拟 ISA 后端"范式的完整解剖**。
> 素材全文：`NVPTX-notes/01..08-*.md`（约 900 行）；scratch/ 存全部实测产物。

---

## 目录

- §1 摘要与核心论点
- §2 宏观架构（版本矩阵/SMVersions/特性 gate）
- §3 IR 层（NVVMReflect/GenericToNVVM/血统学）
- §4+§6 RA 空实现与机器层（disabled 解析/5 幸存 pass/vreg 穿越）
- §5 指令选择（单路径 SDAG/方言翻译）
- §7 下游生态（ptxas/fatbinary/wrapper 链路）
- §8 AsmPrinter 与 DwarfDebug（文本即出口/WAR 三案例）
- §9 MC 层缺席 + PTX 硬件化演化
- §10 与 AMDGPU 逐层对偶表
- §11 昇腾启示录：CANN 的光谱位置与移动选项
- §12 复现手册

---

## §1 摘要与核心论点

AMDGPU 文档证明了"LLVM 内闭环是必要复杂度"；本文档证明其**对偶命题**：

> **"编译器只做一半"是严肃的架构选择**——RA/调度/hazard/编码外移闭源 ptxas，换来 1/8 代码量（3.7 万行 vs 29.9 万）、14 年 ISA 长尾的单点兼容（36 个 PTX 版本一个 foreach）、硬件细节不泄漏。但代价同样真实：**ptxas 黑盒化、WAR 散落源码（三案例）、文本接口不可组合（无 objdump/mca/lld）、且虚拟层本身正在硬件化**（§9 的 tcgen05 证据）。

三个贯穿全文的实证锚点：
1. **空 RA 是结构保证**：addOptimizedRegAlloc 整体替换基类（86 pass 实测流水线 RAGreedy 出现 0 次），%rd1/%r1 vreg 编号穿越全链路直达 PTX 文本
2. **ptxas WAR 化石层**：三案例（unreachable bug/.maxclusterrank 硬崩/half 无立即数语法）以"注释+版本门控+静默过滤"永久化——黑盒下游的 bug 无法上游修复
3. **虚拟 ISA 的硬件化**：TMEM 物理位域（512 col × 128 row、lane[31:16]+column[15:0]）进了 PTX 文档，LLVM 侧长出 298 处 tcgen05 代码——**"省掉的工程费换成 ISA 膨胀 + intrinsic 膨胀两笔新账"**

---

## §2 宏观架构

**详见 `NVPTX-notes/01-architecture.md`**

- **双名双宽**：nvptx/nvptx64 都活着（`.address_size 32/64` 实测），对照 AMDGPU 三名演化
- **384 行 TargetMachine**（AMDGPU 2858）：无函数级 subtarget 缓存、无 ISel 双路径、无全局调度开关
- **版本矩阵在 TargetParser.def**（非 .td）：每 SM 五元组 `(名,枚举,compute_名,sm 数值,首 CUDA,末 CUDA,family)`；PTX 版本映射实测 sm_52→4.1 / sm_90→7.8 / sm_120→8.7
- **双轴 gate**：一个特性 = PTX 版本 × SM 家族复合谓词（`PredAnd<[PTX93, PredOr<[SM90a, SM100f, SM110f]>]>`）——虚拟 ISA 特有的版本复杂度
- **SMVersions foreach 元编程**（NVPTX.td:86-100）管 14 年长尾 vs GCNProcessors 平铺管异质分叉——**元编程适合同质、平铺适合分叉**
- **静默 gate 实测**：cluster_dim@sm_90 输出 `.explicitcluster+.reqnctapercluster`，@sm_80 输出 0——**能力不足静默丢弃**（AMDGPU 是 assert），宽松契约的实证

## §3 IR 层 + 血统学

**详见 `NVPTX-notes/02-ir-layer.md`**

- **NVVMReflect 编译期协商**：`__CUDA_ARCH`→SmVersion×10 查表 RAUW + 级联折叠；实测 sm_90 走 new 分支/sm_35 走 old——**一份 libdevice.bc 服务全 sm 代**；防御性双跑（pipeline-start EP + addIRPasses）；头注释过时（TLI 挂钩才是现代机制）
- **血统学重大发现**：强度削减四件套是 **AMDGPU 从 NVPTX 逐字抄走**（commit `f42c69206d6b` 2016-06-15，连拼写错误 "opportunites" 都抄）——GPU 通用 IR 优化起源于第一个跑通的虚拟 ISA 后端
- **LowerArgs 三策略**：只读可追迹→直接 param AS / grid-constant+cvta→generic / 兜底 local 拷贝（昂贵，默认 late）
- **GenericToNVVM 已瘦身**：当前只做 AS0→AS1 全局克隆（历史方言翻译已删）
- **LowerUnreachable = WAR 案例一**：ptxas 假 CFG 边 bug，commit 号写进源码，PTX 8.3 修复

## §4+§6 RA 空实现与机器层

**详见 `NVPTX-notes/03-ra-empty.md`**

- **空 RA 证据链**：新 PM 空 override（:115-116 "virtual registers are emitted directly"）+ legacy nullptr（:356-357）；addOptimizedRegAlloc **整体替换**基类——结构保证非清空
- **disabled 实为 11 个**（修正"10 个"旧说）：逐个失效模式全部溯源（MCP 硬断言/PEI 要 RegScavenger/PostRASched 要物理重命名/ShrinkWrap 与 FrameLowering assert 冲突…）
- **未禁用的意外收获**：BranchFolder/BlockPlacement/LiveDebugValues 照常跑（对 vreg 不敏感）
- **5 个幸存 pass**：ForwardParams/AddressFolder（shared 特意排除保 CSE）/ProxyRegErasure/**PrologEpilog（PEI 精简仿制版，"帧指针仅文本标记"成立）**/Peephole
- **vreg 穿越 MC 机制**：KindShift=27 高位打包 → InstPrinter 解包打印 %r/%rd/%rs/%p/%rq
- **86 pass 实测流水线**：RA 段 processimpdefs→…→coalescer→scheduler→stack-coloring→nvptx-prolog-epilog，RAGreedy 0 次

## §5 指令选择（单路径 SDAG）

**详见 `NVPTX-notes/04-isel.md`**

- **三处任务假设被源码证伪**（真发现）：无 CCAssignFn（param space ABI 手工实现）；BRCOND 纯 .td 模式（`"@${negate}$a bra $target"`，**SIMT 谓词语义内建 ISA**）；wmma 是 .td multiclass 批量生成
- **965 个 `case Intrinsic::`**：新特性 = 一个 multiclass（操作数 1:1）或一个 Select\* 函数（需编组，如 tcgen05 的 100-case 表）——**无 MC/RA/hazard 配套**
- **0 处 isDivergent**（AMDGPU 8 处）：divergence 感知整体下放 ptxas
- **无 GISel 的表面积论证**：透传 vreg 无 bank 约束 → RegBankSelect/Legalizer 零收益；对照 AMDGPU GISel 22,416 行动机全是 bank 合法性
- **NoItineraries**：无调度模型，MachineScheduler 只剩依赖序（减 mov）
- 实测：`ld.shared.b32 [%rd1+4]` AS→前缀链路、`@%p1 bra` 谓词分支

## §7 下游生态

**详见 `NVPTX-notes/06-downstream.md`**

- **四阶段链路实测**（clang -###）：cc1-nvptx64（出 PTX）→ ptxas（cubin）→ fatbinary `--image3=kind=elf`（**仅 elf 无 ptx——JIT fallback 默认关**）→ cc1-host `-foffload-include-binary`
- **shouldIncludePTX 默认 false**：fatbin 默认只装 cubin，`--cuda-include-ptx` 才加 PTX
- **LLVM offload 路径丢 PTX**（Driver 注释自认："nvlink-wrapper does not accept PTX"）——**中间表示的消费者生态比中间表示本身更重要**
- **lld 缺席反证链**：EM_CUDA=190 读侧存在、链接侧零支持——SASS 重定位语义未公开 → nvlink 垄断
- **NVVMReflect host 镜像否定性结论**：grep 零 host 引用，三重门卫隔离
- **nvlink-wrapper 自认临时物**（"NVIDIA 改进或移植 ld.lld 后可删"）

## §8 AsmPrinter 与 DwarfDebug

**详见 `NVPTX-notes/05-asmprinter.md`**

- **头注释自白**："ptx 语法差异太大无法用 MCAsmStreamer，只能手工输出"——文本即接口的根因
- **三块职责**：指令打印(:582-970)/元数据发射(:971-1351，含全局 SCC 依赖序)/常量与 inline asm(:2123-2760)
- **kernel 元数据 = 文本指令**：.reqntid/.maxntid/.explicitcluster 等 8 项——对照 AMDGPU msgpack note：**宽松契约（grep 可读、静默降级）vs 结构化契约（Verifier 可校验、版本化）**
- **WAR 案例二三**：.maxclusterrank 让 ptxas **硬崩**（SM_90 以下）→ 发射前过滤；half/bf16 无立即数语法 → `mov.b16 0x3C00` 位模式打印
- **DwarfDebug 花括号伪段**：`.debug_abbrev { .b8 1 ... }` 逐字节直打 + DWARF 锁 v2 + .file 缓冲到最外层——**调试信息也要过 ptxas 黑盒**

## §9 MC 层缺席 + PTX 硬件化

**详见 `NVPTX-notes/07-mc-absence.md` + `08-ptx-evolution.md`**

- **工具学后果**：无 objdump/汇编器/mca/readelf/lld（逐项 grep 证实：CMakeLists 无 -gen-asm-matcher/-gen-disassembler/-gen-emitter）——**闭源模式下工具生态=NVIDIA 全家桶（cuobjdump/nvdisasm），开源模式=LLVM 全家桶**
- **MCInst 半途角色**：AsmPrinter 内部换轨容器（复用基类框架的权衡），非出口
- **补全 MC 的经济学**：缺的不是代码是**规格**（SASS 编码/重定位未公开）——AMDGPU 2 万行买全生态，NVPTX 同价只能买文本往返
- **PTX 硬件化五族证据**：reconvergence 契约/cluster-DSMEM/TMA/tcgen05/setmaxnreg——**TMEM 物理位域进 ISA 文档，LLVM 侧 298 处 tcgen05 膨胀**；PTX 36 版、版谓词双轴
- **结论**："虚拟层保稳定"在硬件竞争下不可持续；两侧（NVPTX/AMDGPU）都在长硬件细节，**长在哪由职责边界决定**（资源契约 vs 时序细节）

---

## §10 与 AMDGPU 逐层对偶表

（交叉引用两份 Deep_Analysis，此处只列骨架）

| 层 | NVPTX（本文档） | AMDGPU（对偶文档） |
|---|---|---|
| TargetMachine | 384 行，无 subtarget 缓存 | 2858 行，函数级 SubtargetKey 缓存 |
| 版本管理 | PTX×SM 双轴谓词、36 PTX 版 | gfx 单轴、Generation+三形态 |
| IR 层 | 12 pass + 2 EP（NVVMReflect 协商） | 17 pass + 9 EP（LDS 规划等模块级） |
| 结构化 | **零 pass**（reconvergence 在 ptxas，PTX 文档 9.5 原文） | 11 pass 链（exec mask 契约） |
| ISel | 单 SDAG、0 isDivergent、965 intrinsic case | SDAG+GISel 双路径、bank 合法性 22,416 行 |
| RA | 空（整体替换+11 disabled） | 三段式 SGPR→WWM→VGPR |
| 调度 | NoItineraries，依赖序仅 | 5-stage 多目标+分域计压+Revert 链 |
| 一致性/hazard | ptxas 内（WAR 三案例为证） | waitcnt 记分板+HazardRecognizer 表驱动 |
| 出口 | AsmPrinter 文本（DwarfDebug 伪段） | MC→ELF（msgpack note+kd+REL64） |
| 链接 | nvlink 垄断（SASS 重定位未公开） | lld 原生 |
| 新特性成本 | 一个 multiclass/Select* 函数 | 几十个文件（MC/RA/hazard 配套） |
| 工具生态 | cuobjdump/nvdisasm 全家桶 | LLVM 全家桶 |

---

## §11 昇腾启示录：CANN 的光谱位置与移动选项

**光谱定义**：

```
全外移 ←—————————————————————————→ 全内环
NVPTX→ptxas          CANN(现状)              AMDGPU→ELF
（LLVM 薄+生态闭）   （LLVM fork+自家黑盒）   （LLVM 厚+生态开）
```

**CANN 的精确位置**：闭源后端吃 LLVM IR——**外移到了"自己家的 ptxas"**。得到了 NVPTX 模式的"LLVM 侧薄"，但没得到其"ptxas 有公开 PTX 契约"（CANN 连中间表示都不公开，比 NVPTX 更左）；用户遇到的 NZ 格式全挂、UB 同步缺失、cmpmask 多 repeat 限制，本质是**外移的职责没有回流通道**（AMDGPU 用 65 pass 回流，CANN 用框架/用户侧契约兜底）。

**PyPTO 的位置**：tile 级抽象在 pto-isa 有自己的"内环"（CPU 模拟器/NPU 测试）——**PyPTO 事实上在做 AMDGPU 模式的 tile 级重演**（对照 §9 的启示：提前吸收硬件细节更诚实）。

**三个移动选项**（CANN 若要往光谱中部移动）：

| 选项 | 内容 | 代价 | 收益 |
|---|---|---|---|
| A. 开放 objdump 级工具 | davinci .o 的反汇编/只读工具（对标 cuobjdump 的开放版） | 低（工具已有，开放接口即可） | 用户可诊断（对标"PTX 文本可读"的红利）；ST 测试的"ReadFile 假阳性"类问题有了排查手段 |
| B. 开放 hazard/资源表 | 发射约束（cmpmask 多 repeat 等）+ UB/TMEM 预算表文档化 | 中（暴露微架构细节） | 框架/用户侧可以表驱动避坑（对标 GCNHazardRecognizer 的表）；PyPTO 可直接消费 |
| C. 开放同步插入 API | set_flag/wait_flag 的自动插入接口或规则（对标 SIInsertWaitcnts） | 高（涉核心调度） | "S 管线读 MTE2 UB 无同步保障"类坑从用户侧消失 |

**排序建议**：A（诊断刚需）→ B（PyPTO 直接受益）→ C（长期）。每一步都是"把外移的职责开一个回流通道"，不需要推翻闭源架构。

---

## §12 复现手册

```bash
cd ~/code/llvm-project   # main @ 3eda2aebadd4
BD=build-debug           # Debug+Assertions, targets 含 nvptx64

# 冒烟 + 版本矩阵
printf 'define i32 @f(i32 %a, i32 %b) { ret i32 %a }\n' > /tmp/np.ll
$BD/bin/llc -march=nvptx64 -mcpu=sm_90 -o - /tmp/np.ll          # .version 7.8
$BD/bin/llc -march=nvptx64 -mcpu=sm_52 -o - /tmp/np.ll | head -5 # 4.1
$BD/bin/llc -march=nvptx -mcpu=sm_90 -o - /tmp/np.ll | grep address_size  # 32

# §2 cluster gate（nvvm.cluster_dim 属性）
$BD/bin/llc -march=nvptx64 -mcpu=sm_90 -o - NVPTX-notes/scratch/cluster5.ll | grep cluster
$BD/bin/llc -march=nvptx64 -mcpu=sm_80 -o - NVPTX-notes/scratch/cluster5.ll | grep -c cluster  # 0

# §3 NVVMReflect 双分支折叠
$BD/bin/llc -march=nvptx64 -mcpu=sm_90 -print-after=nvvm-reflect -o - NVPTX-notes/scratch/reflect_test.ll | grep "br label"
$BD/bin/llc -march=nvptx64 -mcpu=sm_35 -print-after=nvvm-reflect -o - NVPTX-notes/scratch/reflect_test.ll | grep "br label"

# §4+§6 空 RA 流水线（86 pass）
$BD/bin/llc -march=nvptx64 -mcpu=sm_90 -O2 -print-after-all -o /dev/null NVPTX-notes/scratch/ra_test.ll 2>&1 | grep "Dump After" > /tmp/pipe.txt
grep -c -i "greedy" /tmp/pipe.txt   # 0

# §5 AS→前缀 + @p 谓词
$BD/bin/llc -march=nvptx64 -mcpu=sm_90 -o - NVPTX-notes/scratch/shared_test.ll | grep -E "ld\.|st\."
$BD/bin/llc -march=nvptx64 -mcpu=sm_90 -o - NVPTX-notes/scratch/br_test.ll | grep -E "@%p|setp"

# §7 工具链四阶段（无 CUDA toolkit 也能打印）
$BD/bin/clang -### --cuda-gpu-arch=sm_70 -c NVPTX-notes/scratch/minimal.cu 2>&1 | grep -E '^\s*"' | head -8

# §8 half 立即数 + DWARF 伪段
$BD/bin/llc -march=nvptx64 -mcpu=sm_90 -o - NVPTX-notes/scratch/half.ptx 2>/dev/null || cat NVPTX-notes/scratch/half.ptx
cat NVPTX-notes/scratch/dbg.ptx | grep -A2 "debug_abbrev"
```

全部 scratch 实验素材：`NVPTX-notes/scratch/`。

---

## 附录：章节-素材对照与执行注记

| 章 | 素材 | 行数 | 产出方式 |
|---|---|---|---|
| §2 | 01-architecture.md | — | 子代理调研（API 超时，transcript 回收）+主会话补验证代写 |
| §3 | 02-ir-layer.md | — | 子代理调研+主会话验证代写 |
| §4+§6 | 03-ra-empty.md | — | 子代理调研+主会话流水线实测代写 |
| §5 | 04-isel.md | — | 子代理调研（三证伪）+主会话验证代写 |
| §7 | 06-downstream.md | — | 子代理调研+主会话 -### 实测代写 |
| §8 | 05-asmprinter.md | — | 子代理调研+验证，主会话代写 |
| §9 | 07-mc-absence.md + 08-ptx-evolution.md | — | 子代理成稿提取 / 调研+主会话代写 |

执行注记：1 主会话 + 9 子代理实例（1 次 API 超时死亡靠 transcript 素材回收，6 次额度耗尽由主会话代写/提取——"调研与写作分离"成为本项目稳定模式）。所有 `文件:行号` 经实际核对；动态验证全部实跑（含 -### 工具链、86-pass 流水线、双 mcpu 版本矩阵、NVVMReflect 双分支、cluster gate、-### 四阶段）。
