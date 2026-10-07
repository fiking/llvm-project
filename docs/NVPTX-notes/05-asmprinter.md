# §8 NVPTX AsmPrinter（"文本即接口"出口层）与 DwarfDebug 深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，本仓库工作区实测（build-debug, nvptx64, sm_90）。
> 引用格式 `文件:行号`；实测素材 `NVPTX-notes/scratch/`（dbg.ptx/half.ptx/bf16.ptx/mcr.ll/cluster5.ll）。
> 素材来源：子代理调研+动态验证（引用与输出均已核实）+ 主会话代写组装。
> 对照阅读：AMDGPU-notes/08-mc-obj.md（msgpack note 通道）。

---

## 8.1 AsmPrinter 2800 行结构解剖

**头注释自白**（:108-113）：ptx 语法与常规 .s 差异太大，无法用 MCAsmStreamer 接口，只能手工输出；"更好的做法是克隆一个 MCPTXAsmStreamer"——**文本即接口的根因**。类在匿名 namespace（:125），内嵌 AggBuffer 聚合常量缓冲（:127-212）。

**三块职责**：
| 块 | 行区间 | 内容 |
|---|---|---|
| ① 指令打印管线 | :582-970 | emitInstruction :582（先 verifyInstructionPredicates 再 lowerToMCInst）；lowerOperand :597-642；encodeVirtualRegister :668（vreg 高位打包，见 03-ra-empty.md） |
| ② 函数/kernel 元数据 | :971-1351 | emitKernelFunctionDirectives :971、emitDeclaration* :1062-1081、emitDeclarations :1159、**emitGlobals :1252 全局 SCC 依赖序**（ptxas 要求符号先声明 :1261-1265）、emitHeader :1337 |
| ③ 常量/操作数/inline asm | :2123-2760 | printFPConstant :2123（只认 f32/f64）、printOperand :2593、emitInlineAsm :2706 |

**override 清单**（对照基类 AsmPrinter.h）：emitStartOfAsmFile(:226)、emitBasicBlockStart(:227，追加 .pragma nounroll)、emitFunctionEntryLabel(:228)、emitFunctionBodyStart/End(:229/230)、emitImplicitDef(:231，仅打注释)、emitInstruction(:233)、PrintAsmOperand/MemoryOperand(:279/282)、emitGlobalAlias(:248)、emitInlineAsm(:289)、doInitialization/Finalization(:295/296)、**createDwarfDebug(:299，返回 NVPTXDwarfDebug)**、runOnMachineFunction(:358，基类跑完后手写 `}`)。新 PM 三包装 pass :2774-2800。

## 8.2 kernel 元数据 = 文本指令（:971-1037）

| 指令 | 行号 | 语义 |
|---|---|---|
| .reqntid | :977-979 | 未指定维度补 1，全未指定不发（注释 :973-975） |
| .maxntid | :982-984 | |
| .minnctapersm | :986-987 | |
| .maxnreg | :989-990 | |
| .explicitcluster | :1004 | SM90 gate 内 |
| .reqnctapercluster | :1011-1012 | |
| .blocksareclusters | :1031 | 缺 reqntid/cluster_dim 或 PTX<9.0 则 diagnose（:1022-1029） |
| .maxclusterrank | :1034-1035 | |

属性链：NVVMProperties.cpp:246-296（getReqNTID 等；**maxclusterrank 与 cluster_dim 互斥** :274）；getOverallMaxNTID :258-266 引 PTX ISA 11.4.2 语义注释。

**动态验证**（实测）：
- annotations.ll@sm_90 → `.reqntid 11, 22, 33` / `.maxntid 10, 20, 30` / `.minnctapersm 42` ✓
- cluster5.ll(cluster_dim=2,1,1)@sm_90 → `.explicitcluster`+`.reqnctapercluster 2, 1, 1` ✓；@sm_80 → **静默丢弃** ✓
- blocksareclusters-kernel-attr.ll@sm_90 → 实测触发 "requires PTX version >= 9.0" 错误路径 ✓（**唯一报错的 gate**，其余静默）

**对照 AMDGPU**（08-mc-obj.md §10.3-10.4）：同语义 reqd_work_group_size 走 msgpack 进 NT_AMDGPU_METADATA=32 ELF note（MetadataVerifier 可校验、版本化、消费者=loader）；NVPTX 是 grep 可读文本、消费者=ptxas、能力不足**静默降级**——**宽松契约 vs 结构化契约**。

## 8.3 ptxas WAR 三案例（完整版）

**案例一 LowerUnreachable**（详见 02-ir-layer.md §3.6）：NVPTXSubtarget.h:184-191 完整注释（CUDA 12.3 前不识别 trap 终结块→幻影 CFG 边→bar.sync 非法发散），`return !hasFeature(NVPTX::PTX83)`；门控 NVPTXTargetMachine.cpp:320-327。

**案例二 .maxclusterrank 过滤**：:992-996 注释原文 ".maxclusterrank directive requires SM_90 or higher... **it causes a hard ptxas crash**"，`STI->hasFeature(NVPTX::SM90)` gate :997。ptxas 在 SM_90 以下目标遇到该指令**直接硬崩（非报错）**，LLVM 选择发射前过滤。实测：mcr.ll(maxclusterrank=2)@sm_90 → `.maxclusterrank 2` ✓，@sm_80 → 0 条 ✓。

**案例三 half 立即数**：NVPTXMCExpr.cpp:31-37 注释 "ptxas does not have a way to specify half-precision floats. Instead we have to print and load fp16 constants as .b16"——**PTX 无 f16 立即数语法**（无 0h 前缀），half/bf16 均打 `0x`+4 hex（f32=0f/8位 :43-47，f64=0d/16位 :48-52）；lowerOperand :618-638 是入口；getPTXFundamentalTypeStr :1809-1813 "fp16 and bf16 are stored as .b16 for compatibility with pre-sm_53"。
实测：half.ll → `mov.b16 %rs2, 0x3C00; add.rn.f16 %rs3, %rs1, %rs2` ✓；bf16.ll → `mov.b16 %rs2, 0x3F80; add.rn.bf16` ✓；**附加发现**：sm_52 走 cvt.f32.f16 软件路径。

**三案例共性**：ptxas 的缺陷/约束以**源码注释+版本门控+静默过滤**的形式永久化在 LLVM 里——黑盒下游的 bug 无法上游修复，只能 WAR，且 WAR 本身成为技术债（LowerUnreachable 还要等 PTX 8.3 才能删）。

## 8.4 DwarfDebug 296 行：文本里的 DWARF

**构造器 :39-49 四开关+锁 DWARF v2**：inline strings（无 .debug_str）、无 ranges、sections-as-references、无 accel table——**全因 PTX 无 ELF section**。

**编码技巧**：
- MC 层 NVPTXTargetStreamer::changeSection（:87-103）把 DWARF section 切换改写成 `.section\t.debug_xxx` + `{...}` **花括号伪段**，字节用 `.b8` 直打
- .file 缓冲到最外层再输出（:43-45, :97；AsmPrinter doFinalization :1375-1376）
- 尾部补空 `.debug_macinfo{}` :1371-1372

**enhanced lineinfo**（:55-61，PTX72+LineTablesOnly；:63-105 大注释）：连续多条 `.loc` 携带 `function_name $L__info_stringN, inlined_at f l c` 操作数（PTX ISA 7.2 扩展，对标 Two-Level Line Tables）；worklist 回溯 inlined_at 链 :106-191，去重集 EmittedInlinedAtLocs。

**cuda-gdb 适配**：shouldAttachCompileUnitRanges/shouldResetBaseAddress :198-211（PTX 不能做 label 减法→零 base、无 low_pc）；DW_AT_address_class :257-281（NVPTXAS::DWARF_ADDR_* 映射 :213-230）；DW_AT_LLVM_language_dialect :283-296。emitInitialRawDwarfLocDirective :393-414（PR51079）；inline asm 逐行 .loc（isPTXInstruction :2651 启发式：首字符字母或 `_'）:2742-2754。

**动态验证**（scratch/dbg.ll，FullDebug，sm_90）：
```
.target sm_90, debug                    ← debug 后缀
函数体内: .loc 1 3 5 // dbg.c:3:5
.file 1 "/tmp/dbg.c"                    ← 在函数后（缓冲到最外层）
.section .debug_abbrev { .b8 1 ... }    ← 花括号伪段 + 逐字节
.b64 $L__func_begin0 // DW_AT_low_pc    ← 段内 label 引用
.debug_info 里 DWARF version=2          ← 锁 v2 实证
```

**对照 AMDGPU**：ELF 真 .debug_* section，lldb/gdb 直接消费；NVPTX 靠 ptxas 二次打包进 cubin——调试信息也要过一遍黑盒。

## 8.5 头部与可见性

- 头部（emitHeader :1337-1351 → NVPTXTargetStreamer.cpp:160-185）：banner / .version（:168 `PTXVersion/10 . %10`）/ .target（+`, texmode_independent` NVCL / +`, debug` hasFullDebugInfo :1322-1335）/ .address_size（DataLayout 指针宽）。版本矩阵实测引 01-architecture.md（4.1/7.8/8.7；32/64）
- 可见性（emitLinkageDirective :1381-1411 注释表格）：extern decl→.extern、extern def→.visible、其余非 internal→.weak、applying→fatal。`.entry` vs `.func`（:896-901 / :1069-1072）；`.noreturn` :911-912。实测：`.visible .func (.param .b32 func_retval0) f(`、`.visible .entry k()`

## 8.6 昇腾映射（推理级，待验证）

davinci 若用文本伪指令承载 tiling 参数则与 .reqntid 同构（编译器文本出口+后端工具二次消费）；但 **CANN 主流是 tiling 独立 .bin/.json + host api 通道，更接近 AMDGPU 的"结构化元数据旁路"一端**——即 CANN 在元数据哲学上其实选了 GCN 模式，但闭源实现使其失去了"可校验可组合"的开放红利。

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| NVPTXAsmPrinter.cpp:108-125, 127-212, 582-642, 668, 896-912, 971-1037, 1062-1081, 1159, 1252-1265, 1322-1335, 1337-1351, 1371-1376, 1381-1411, 1809-1813, 2123, 2593, 2651, 2706, 2742-2754, 2774-2800 | 全结构 |
| NVPTXMCExpr.cpp:31-52, 618-638 | half 立即数 |
| NVPTXDwarfDebug.cpp:39-105, 106-191, 198-296, 393-414 | DWARF 技巧 |
| NVPTXTargetStreamer.cpp:87-103, 160-185 | 伪段/头部 |
| NVVMProperties.cpp:246-296 | 属性链 |
| NVPTXSubtarget.h:184-191 / NVPTXTargetMachine.cpp:320-327 | 案例一 |
| AsmPrinter.h（基类）:226-299 | override 对照 |

实测素材：scratch/dbg.ptx（.loc/.file/伪段/DWARF v2）、half.ptx/bf16.ptx（.b16 立即数）、mcr.ll（maxclusterrank gate）、cluster5.ll（cluster gate，引 01-architecture.md）。
