# §9 NVPTX MC 层整体缺席的后果——"文本即边界"的工具学、生态学与经济学

> 基准：llvm-project main @ `3eda2aebadd4`。本文件为**静态源码分析**（所有文件:行号 引用均经 grep/read 实际核对）；
> 动态行为引用 NVPTX-notes/06-downstream.md 与 AMDGPU-notes/08-mc-obj.md 的既有实测。
> 本机 build 仅 host target（AGENTS.md：`LLVM_TARGETS_TO_BUILD="host"`），故本轮无法实跑 nvptx/amdgpu 工具，未做新动态验证。
> 与 03-ra-empty.md §6.2 互补：彼处回答"MC 层有什么"，本节回答"缺什么、缺的代价是多少、为什么不补"。

---

## 9.1 工具学后果清单：逐项 grep 证实

**注册面事实**（结构性根源，先于任何工具讨论）：
- `NVPTXMCTargetDesc.cpp:76-100`：仅注册 MCAsmInfo(:80)/MCInstrInfo(:83)/MCRegInfo(:86)/MCSubtargetInfo(:89)/**MCInstPrinter(:92)** + Asm/Null 两个 TargetStreamer——无 AsmParser、无 Disassembler、无 CodeEmitter、无 AsmBackend、无 ObjectWriter、无 MCInstrAnalysis。
- `NVPTX/CMakeLists.txt:5-10`：tablegen 仅 6 项（asm-writer/dag-isel/instr-info/register-info/sd-node-info/subtarget），**无 -gen-asm-matcher / -gen-disassembler / -gen-emitter**；`:81-82` 仅 `add_subdirectory(MCTargetDesc)` + `TargetInfo`。对照 `AMDGPU/CMakeLists.txt:5,9,14`（GenAsmMatcher/GenDisassemblerTables/GenMCCodeEmitter 三项俱全）与 `:227-228`（AsmParser/、Disassembler/ 子目录）。
- MCTargetDesc 全部 9 文件共 1423 行（InstPrinter 644 + TargetStreamer 237 + MCTargetDesc 100 + MCAsmInfo 62 + 头文件），对照 AMDGPU 23 文件 7030 行（08-mc-obj.md §10.2）。

### 9.1.1 后果逐项表

| 工具/能力 | 证据（本轮 grep 实测） | 后果定性 |
|---|---|---|
| **llvm-objdump -d** | `tools/llvm-objdump` 源码 nvptx 命中 **0 个文件**；`selectPrettyPrinter` switch（llvm-objdump.cpp:1090-1110）有 hexagon/**amdgpu(:1096-1097)**/bpf/arm/aarch64/riscv 各 case、无 nvptx。AMDGPU 在 llvm-objdump.cpp 有 23 处特化（:1096-1097 AMDGCNPrettyPrinter、:1725-1727 "currently only used on AMDGPU" 的 MCSymbolizer、:2115 amdgpu 标签特判） | 反汇编路径要求 `createMCDisassembler` 非空，为空则 llvm-objdump.cpp:1171-1173 直接报 **"no disassembler for target"**。NVPTX 上无任何可反汇编的 LLVM 产物；cubin 的 SASS 反汇编归 nvdisasm（LLVM 全库无 SASS 反汇编器，NVPTX 目录内 "SASS" 仅出现在注释，如 NVPTXISelLowering.h:56） |
| **汇编器（.s→obj）** | `tools/llvm-mc` nvptx 命中 **0 文件**；llvm-mc.cpp:357-359 依赖 `createMCAsmParser`/`createMCTargetAsmParser`（TargetRegistry.h:488-492 为可选注册，NVPTX 未挂） | `llvm-mc -triple=nvptx64` 不可用。**PTX 的"汇编"只能由外部 ptxas 完成**——clang driver 明文自述：Cuda.cpp:756 "NVPTX toolchain. Our assembler is ptxas, and our linker is nvlink"、:895 "Our assembler is ptxas, and our 'linker' is fatbinary"；`NVPTX::Assembler::ConstructJob`（Cuda.cpp:398-524）即 ptxas 命令行组装（细节见 06-downstream.md §7.1） |
| **llc -filetype=obj** | `CodeGenTargetMachineImpl.cpp:198-209`：ObjectFile 分支先 `createMCCodeEmitter` 再 `createMCAsmBackend`，任一为空即报错退出——:203 "createMCCodeEmitter failed"、:208 "createMCAsmBackend failed"（TargetRegistry.h:480/:525-526 此二者是可选函数指针，NVPTX 皆 null） | **LLVM 无法为 NVPTX 产出任何 .o**。产物边界 = 文本 .ptx，二进制化（cubin）被让渡给界外工具 ptxas |
| **llvm-mca** | `tools/llvm-mca` nvptx 命中 **0 文件**（且全库无 AMDGPU 特判——mca 本体完全 target 无关，可用性完全由 target 注册面决定）。双重死因：(a) 输入 .s 需 MCAsmParser 解析（llvm-mca.cpp:477-498 的 region 解析路径）；(b) llvm-mca.cpp:438-448 要求 `hasInstrSchedModel()`，否则报 "unable to find instruction-level scheduling information"，且 :444-447 附注 even itineraries are unsupported | NVPTX.td:79 `class Proc<FeatureSM SM> : Processor<SM.Name, NoItineraries, [SM]>`——**全系 SM_* 均 NoItineraries**。即使补上 AsmParser，mca 仍死在无调度模型。而 PTX 是虚拟 ISA，真实延迟由 ptxas 调度后的 SASS 决定，PTX 级模型写了也没有消费者（对照 AMDGPU：SISchedule.td 624 行 + GCNProcessors.td 345 行每代 ProcessorModel，GCNProcessors.td:24 起 gfx600 挂 SIFullSpeedModel） |
| **llvm-readelf/readobj** | 有趣的**读侧例外**：EM_CUDA=190（ELF.h:291）、EF_CUDA_* 全套 e_flags（ELF.h:941-995，含 EF_CUDA_SM20=0x14…SM121=0x79、TEXMODE/64BIT_ADDRESS/VIRTUAL_SM）；ELFDumper.cpp:1661-1720 解码表（sm_20…sm_110 字符串）、:3779/:7678 两处使用点；ELFObjectFile.cpp:411 EM_CUDA 分支、:440-450 能把 e_flags 翻译成 sm_XX 架构名；llvm-gpu-loader.cpp:222 可执行 CUDA ELF。来源 commit `8c262ed2e3a2` "[NVPTX] Add ELF flags for Nvidia cubin files (#75624)"（git log -S 实查） | readobj **能读** cubin 的 ELF 头与 e_flags（sm 版本、texmode、64bit），因为那是通用 lib/Object 层；但仅此而已——无重定位定义（ELFRelocs/ 目录 23 个 .def **无 CUDA.def**；对照 AMDGPU.def:5-6 起 R_AMDGPU_NONE/R_AMDGPU_ABS32_LO…共 16 行 ELF_RELOC 宏命中、扣哨兵 2 行≈14 个重定位类型）、无反汇编。**"能读不能写"**——这正是 06-downstream.md:49 反证链的结论：读侧支持有、链接侧没有 |
| **lld** | `lld/ELF` + `lld/Common` nvptx 命中 **0 文件**；Driver.cpp:178 有 `"elf64_amdgpu"` 仿真、无任何 nvptx 仿真；`lld/test/ELF/` 有 amdgpu-abi-version.s / amdgpu-elf-flags-err.s 等一排测试、**0 个 cuda 测试** | NVPTX 链接 = nvlink（外部）+ clang-nvlink-wrapper（clang/tools/clang-nvlink-wrapper/ClangNvlinkWrapper.cpp，838 行，driver 在 Cuda.cpp:688 调用；头注释 :11-14 自认"补 nvlink 缺 LTO/归档之短，NVIDIA 改进或移植 ld.lld 后可删"的**临时物**，LTO 产物由 wrapper 自己调 ptxas，见 06-downstream.md §7.1）。链接器是工具链里唯一无法用"读侧例外"糊弄的组件——重定位语义不存在，lld 无法接手 |

### 9.1.2 后果的合成图景

LLVM 生态对 NVPTX 的可用面收敛为：**生成文本（llc/clang → .ptx）、读 ELF 头（readobj 对 cubin）、跨界包装（nvlink-wrapper/fatbinary）**。任何"指令级"工具能力（反汇编、汇编、编码检查、静态性能分析、链接）在 LLVM 内部为零，全部外溢到 NVIDIA 工具（ptxas/nvdisasm/cuobjdump/nvlink）。而且这外溢是**单向依赖**：本机无 ptxas 时 clang 仍能 `-###` 打印命令行但链路断在界外（06-downstream.md §7 环境注）。

**设计动机**：MC 层的存在意义 = **LLVM 拥有产物二进制格式的定义权**。NVPTX 的 LLVM 产物是文本，二进制产物（cubin=SASS ELF）的编码、重定位、段语义归 ptxas/NVIDIA。所以"MC 四件缺席"不是欠账，而是**边界声明**：NVPTX.td:60-79 的注释甚至明写"There is deliberately no numeric encoding of an architecture…a number would only invite the ordered comparisons it cannot answer"——连架构身份都刻意保持符号化而非数值化，与 AMDGPU 每代 GFX 都有 e_flags 数值编码（ELF.h:321 EM_AMDGPU=224 + EF_AMDGPU 机器位）形成同一件事在两端的镜像。

**昇腾映射**：davinci .o 若为闭源 ELF，LLVM 社区最多复刻 #75624 式的"读侧一个 commit"（EM/EF 解码），永远到不了写侧——这是闭源 ISA 的结构性天花板，与工程意愿无关。

---

## 9.2 对照 AMDGPU：ELF 闭环与两条生态曲线的分化

**AMDGPU 侧事实**（引用 AMDGPU-notes/08-mc-obj.md 实测，gfx1100/build-debug）：
- llc -filetype=obj → 标准 ELF（EM_AMDGPU=224，ELF.h:321；note 段 msgpack 元数据、.kd kernel descriptor 符号、REL64 重定位）；
- `llvm-objdump -d` 正确反汇编 gfx11 dual-issue（v_dual_mov_b32::v_dual_and_b32）与 s_code_end padding（08-mc-obj.md §10.8）；
- `llvm-mc` 手写 .s（.amdgcn_target + .amdhsa_kernel 块）→ 成功生成 .o，**往返闭环可验证**（§10.8，含两个 interop 陷阱实录）；
- lld 可链：Driver.cpp:178 elf64_amdgpu 仿真 + amdgpu-*.s 测试族。

**分化曲线**：
- AMDGPU：MCTargetDesc 23 文件 7030 行（InstPrinter 1974、TargetStreamer 1275、CodeEmitter 790、MCExpr 778…，08-mc-obj.md §10.2）+ AsmParser 11029 + Disassembler 3208 + BaseInfo 3800 ≈ **2 万行量级**，买到 N 个工具的**组合性**（composability）：每注册一个 MC 组件，objdump/mc/mca/lld/readobj 同时受益，因为输入输出是同一套 LLVM 定义的 ELF ABI。
- NVPTX：MCTargetDesc 9 文件 1423 行（InstPrinter 644 + 指令表 TargetStreamer 237 + 注册表 100 + MCAsmInfo 62），只买到**单向文本出口**；任何新特性只能进入 PTX 文本，工具组合性 = 0。
- 工具投入的对冲逻辑不同：AMD 的 2 万行有 ROCm 全开源战略兜底（驱动/runtime/编译器/工具一条龙都要开源替代品，ELF ABI 有 AMDGPU-Usage 文档背书）；NVIDIA 的 ptxas 既是护城河也是**稳定承诺**——PTX 作为虚拟 ISA 靠 ptxas JIT 保持前向兼容，SASS 编码可逐代重定义而不破坏生态（NVPTX-notes/08-ptx-evolution.md 主题）。

**设计动机**：两条曲线不是"努力程度"差异而是**商业模式差异**在工具链上的投影（详见 §9.5）。AMDGPU 的 MC 层是"开源 ISA → 开源 ABI → 开源工具链"的必要环节；NVPTX 的 MC 空缺是"闭源二进制层"的忠实反映。

**昇腾映射**：昇腾若走 CANN 全家桶路线，其曲线形状 = NVPTX（文本/私有 IR 边界外全靠自家工具）；若某天公开 davinci ISA + ELF ABI，才可能滑向 AMDGPU 曲线。**工具生态不是投入问题，是模式问题。**

---

## 9.3 MCInst 的"半途角色"：AsmPrinter 的内部换轨容器

**链路（全部行号实核）**：