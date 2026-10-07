# §10 AMDGPU MC 层与 Code Object 深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，本仓库工作区实测（build-debug, gfx1100）。
> 引用格式 `文件:行号`；动态验证全部真实执行（见 §10.8）。
> 素材来源：子代理调研（引用已核实）+ 主会话代写组装。

---

## 10.1 这一层在做什么

MC 层是"MCInst → ELF code object"的最后一公里。NVPTX 在此戛然而止（AsmPrinter 直接打印 PTX 文本）；AMDGPU 则有完整的 MC 栈：编码器、ELF 流写器、HSA metadata、note 段、kernel descriptor——**机器码与元数据在 LLVM 内闭环成标准 ELF**，lld/objdump/mca 全部可组合。

## 10.2 MCTargetDesc 结构（wc -l 实测，23 文件共 7030 行）

| 文件 | 行数 | 职责 |
|---|---|---|
| AMDGPUInstPrinter.cpp | 1974 | MCInst → 汇编文本（VOP3/SDWA/DPP 修饰符语法） |
| AMDGPUTargetStreamer.cpp | 1275 | HSA/PAL metadata 发射 + e_flags/kernel descriptor |
| AMDGPUMCCodeEmitter.cpp | 790 | TableGen 位域编码 + fixup |
| AMDGPUMCExpr.cpp | 778 | 汇编期表达式（寄存器计数/SOPP 分支） |
| AMDGPUAsmBackend.cpp | 265 | relax/fixup 应用 |
| AMDGPUMCTargetDesc.cpp | 231 | **注册表（:205-231）** |
| R600InstPrinter/MCCodeEmitter/MCTargetDesc | 429 | r600 遗产 |
| AMDGPUELFObjectWriter.cpp | 101 | MCExpr→重定位类型映射 |
| AMDGPUMCKernelDescriptor.cpp | 99 | 64B kernel descriptor 位域 |
| AMDGPUELFStreamer.cpp | 38 | note 段切换 |

注意：**DelayedMCExpr 不在 MCTargetDesc**，在 `Utils/AMDGPUDelayedMCExpr.h`（35 行）。

外围：HSAMetadataStreamer.cpp 765（Target 顶层）、AsmParser/AMDGPUAsmParser.cpp **11029**、Utils/AMDGPUPALMetadata.cpp 1143、Utils/AMDGPUBaseInfo.cpp 3800。

**注册表结构**（AMDGPUMCTargetDesc.cpp:205-231）：R600+GCN+GCNLegacy 三 target 共享 MCAsmInfo/RegInfo/STI/InstPrinter/InstrAnalysis/AsmBackend/ELFStreamer；GCN 额外注册 AsmTargetStreamer（文本）+ ObjectTargetStreamer（ELF）+ NullTargetStreamer。`AMDGPUMCInstrAnalysis::updateState`（:176-192）维护 gfx12 的 VgprMSBs（1024 可寻址 VGPR 的高位追踪）。

## 10.3 HSAMetadataStreamer：msgpack 元数据管线

**版本常量**（llvm/Support/AMDGPUMetadata.h:34-51）：V3=[1,0] V4=[1,1] V5=[1,2] V6=[1,2]。类层级 V4→V5→V6（V3 类已删除，2023-10 `4428b01faa41`）。

- **begin()**(:560)：amdhsa.version/target/printf + kernels 数组
- **emitKernel**(:581)：仅 AMDGPU_KERNEL/SPIR_KERNEL 进数组
- **getHSAKernelProps**(:488)：.kernarg_segment_size/.group_segment_fixed_size/.private_segment_fixed_size/.uses_dynamic_stack(COV≥5)/.workgroup_processor_mode(COV≥5+WGP)/.wavefront_size/.sgpr_count/.vgpr_count/.agpr_count(MAI)/.max_num_workgroups_xyz/spill counts
- **reqd_work_group_size**：emitKernelAttrs V4(:255-279) 读 IR `reqd_work_group_size`→`.reqd_workgroup_size`；V5(:727) 加 `.uniform_work_group_size`；V6(:748) 加 `.cluster_dims`
- **V5 隐式参数完整布局**（emitHiddenKernelArgs :619-725）：hidden_block_count_xyz u32 → group_size/remainder u16 → 16B reserved → global_offset i64 → grid_dims → printf/hostcall/multigrid/heap/default_queue/completion_action/dynamic_lds → 68B reserved → private/shared_base（无 aperture regs 时）→ queue_ptr
- **DelayedMCExprs**：sgpr/vgpr_count 等先占位、emitTo(:555) 时 `resolveDelayedExpressions()` 回填——**支持依赖汇编期符号的寄存器计数**（2024-06 MCExpr 化改造的产物）

## 10.4 流入 ELF note 的路径

`EmitHSAMetadata`（TargetStreamer.cpp:1076-1098）：
```
MetadataVerifier(Strict).verify → writeToBlob（msgpack 二进制）
→ EmitNote("AMDGPU", desc-expr, NT_AMDGPU_METADATA=32)
```
- EmitNote(:823) 切 `.note`（SHT_NOTE，HSA 时 SHF_ALLOC）
- `finish()`(:804)：设 e_flags + ELFABI 版本（getELFABIVersion，BaseInfo.cpp:239：V4/V5/V6→ELFABIVERSION_AMDGPU_HSA_V4/5/6），再发 PAL note
- **e_flags 的四态编码**：V3(:913) mach+xnack/sramecc 二态；V4(:929) 四态（unsupported/any/off/on）；V6(:969) V4+generic CPU 版本位
- `EmitAmdhsaKernelDescriptor`(:1129)：生成 `name` + `name.kd`（STT_OBJECT, 64B）；kernel 符号强制 **STV_PROTECTED**；kernel_code_entry_byte_offset = S_REL64（FIXME 注释：名义 REL64 实际 R_AMDGPU_ABS64）
- note 常量：AMDGPUPTNote.h（NoteNameV3="AMDGPU"）；NT_AMDGPU_METADATA=32 @ ELF.h:2005

## 10.5 Code Object 版本演进考古（git log 实测日期）

| 日期 | Commit | 事件 |
|---|---|---|
| 2017-03-22 | `7498cd61fb79` | 创建 MetadataStreamer（COV2 YAML） |
| 2019-03-13 | `ed0b9af9973e` | **HSA 元数据切 msgpack**（同日 `4ced8de17c5f` MsgPackDocument 类） |
| 2019-03-20 | `e7bd52f86e04` | PAL msgpack |
| 2020-12-17 | `daf39e3f2dba` | 默认 COV3 |
| 2021-03-24 | `f4ace6373747` | **COV4/TargetID** |
| 2022-01-31 | `1194b9cdda30` | COV5 隐式参数入元数据 |
| 2023-10-16 | `4428b01faa41` | **删 COV3** |
| 2024-02-05 | `500846d2f542` | **COV6** |
| 2024-06 | `3d1705d00c5f` | MCExpr-ify（DelayedMCExpr 诞生） |

**演进规律**：YAML→msgpack（体积+自描述）、元数据逐步吸收运行时约定（隐式参数）、旧版本保留 ~2 年再删——**格式版本的生命周期管理范本**。

## 10.6 AsmParser 为何 11029 行

- ParseDirective 分发（:7187）：HSA 路径 `.amdhsa_kernel/.amdhsa_code_object_version/.amdgpu_metadata`；非 HSA `.amd_kernel_code_t/.amdgpu_hsa_kernel/.amd_amdgpu_isa`；公共 `.amdgcn_target/.amdgpu_lds/.amdgpu_info/.amdgpu_pal_metadata`
- `.amdhsa_kernel`（:6205）：**~40 个 `.amdhsa_*` 子指令逐位填 MCKernelDescriptor**（PARSE_BITS_ENTRY 宏），ImpliedUserSGPRCount 追踪
- 体积来源：GCN 全语法（neg/abs 修饰、VOP3/SDWA/DPP、寄存器范围、每代寄存器合法性 subtargetHasRegister :7230）+ kernel 元数据指令 + MCExpr 算术
- **动机**：汇编→code object 独立于 clang 的路径（ROCm 生态 .s 互操作、objdump 反汇编可精确回汇编）——对比 NVPTX：PTX 文本即接口，无 AsmParser 需求

## 10.7 MCCodeEmitter、Fixup 与重定位

- `encodeInstruction`（:401）：TableGen APInt 编码 + VOP3P/MAI op_sel_hi 隐式置 1 + GFX10+ MIMG NSA 附加字节 + 尾随 32 位立即数（255/254 sentinel）
- **仅 1 个 target fixup**：`fixup_si_sopp_br`（FixupKinds.h:21，SOPP 16 位 PCrel，getSOPPBrEncoding :498）——其余全靠 TableGen FK_Data_* 通用 fixup
- 重定位映射（ELFObjectWriter.cpp:41-100）：S_GOTPCREL→R_AMDGPU_GOTPCREL、S_REL64/S_ABS64、FK_Data_4/8→ABS32/REL32/64、sopp_br→R_AMDGPU_REL16、SCRATCH_RSRC_DWORD0/1 特判 ABS32_LO

## 10.8 动态验证（全部真实输出）

**llc → ELF**：
```
$ llc -march=amdgcn -mcpu=gfx1100 -filetype=obj -o /tmp/x.o test.ll
# ELF64 EM_AMDGPU, OS/ABI=AMDGPU-HSA, ABI Version 4（COV6 默认）, Flags 0x41 gfx1100
# .note(ALLOC) NT_AMDGPU_METADATA desc=0x603B
# hexdump 见 msgpack: 83 ae "amdhsa.kernels" 91 8f a5 ".args" ...
# YAML 展开: args = out/in/n + 22 项 hidden args（与 V5 布局逐一对应）
#          kernarg_segment_size 280, sgpr_count 6, vgpr_count 2,
#          workgroup_processor_mode 1, version [1,2]
$ llvm-readelf: .rela.rodata 含 R_AMDGPU_REL64 test_kernel+0x10（kd entry offset）
# 符号表: test_kernel FUNC PROTECTED（源码强制）+ test_kernel.kd OBJECT 64B
$ llvm-objdump -d: v_dual_mov_b32::v_dual_and_b32（gfx11 dual-issue）正确反汇编
#          s_endpgm 后 s_code_end(0xbf9f0000) 填 3×128B cache line（EmitCodeEnd :1104）
```

**llvm-mc 汇编路径**（手写 .s：.amdgcn_target + .amdhsa_code_object_version 5 + .amdhsa_kernel 块）→ 成功生成 y.o（ABI Version 3=COV5、生成 .kd 符号+REL64）。**关键证明：无 `.amdgpu_metadata` 指令则无 .note 段**——kd 来自 `.amdhsa_kernel`，运行时元数据来自 `.amdgpu_metadata` YAML。

**interop 陷阱**（实测踩坑，值得记录）：
1. llc 自印的 `.amdgcn_target "amdgpu-amd-amdhsa-unknown-gfx1100"` 被 llvm-mc 拒绝（"malformed target id"）——**回汇编需改写为 `amdgcn-amd-amdhsa--gfx1100`**（amdgpu 新名 vs amdgcn 的 MC 层未同步，呼应 §3 的 `24a5231188bf` 正名遗留）
2. `.amdgpu_metadata` 的 YAML 体**禁 tab 缩进**（msgpack YAML 解析器限制）

## 10.9 PAL metadata：图形管线的平行宇宙

- readFromIR(:54)：`amdgpu.pal.metadata.msgpack`（新）vs `amdgpu.pal.metadata`（旧 reg=值对）；toBlob(:864) 双格式
- 模型：Registers/HwStages/ShaderFunctions/Compute+GraphicsRegisters（PAL≥3.0）
- **关键差异**：`setRsrc1` OR 进 SPI_SHADER_PGM_RSRC1——**wave 调度实际用 rsrc1 寄存器值分配 VGPR/SGPR，msgpack 计数仅 advisory**；HSA 路径则走 kd+amdhsa 元数据
- 分野本质：PAL/DX12/Vulkan 图形管线无 kernel descriptor 概念，运行时直接消费寄存器值

## 10.10 设计动机总结

1. **msgpack 自描述 + 版本字段 + Verifier**：元数据格式三件套，消费者（运行时/loader）可校验可降级
2. **kernel descriptor 与元数据分离**：kd 是硬件消费的 64B 位域，元数据是 loader 消费的注释——两层解耦使图形（PAL）和计算（HSA）各取所需
3. **仅 1 个 target fixup** 的克制：能复用通用 FK_Data_* 就不造 target fixup——与 NVPTX AsmPrinter 3800 行的"文本即接口"形成工程哲学对照

## 10.11 昇腾映射（推理级，待验证）

1. **CANN .o 的 kernel 元数据**（tiling 参数/硬件版本）未见公开对应物（待验证）。AMDGPU 的 msgpack 方案 vs PAL 寄存器键值方案给出了两个极端：**自描述可演进** vs **贴近硬件零转换**——昇腾 .o 若要对标，取决于消费者是 loader（选 msgpack）还是驱动直读（选寄存器式）
2. **COV 版本生命周期**（保留 2 年再删、ABI version 字段同步 e_flags）是昇腾 CCE 版本碎片管理的现成模板
3. **64B kernel descriptor + STV_PROTECTED 符号**：防止跨 .o 误绑定的符号语义，PyPTO 编译产物若有 kernel 入口符号可借鉴
4. **DelayedMCExpr**（汇编期才能确定的寄存器计数回填）：昇腾编译产物的 tiling/寄存器预算若依赖汇编期符号，同构问题有现成解

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| AMDGPUMCTargetDesc.cpp:176-192, 205-231 | 注册表 + VgprMSBs |
| llvm/Support/AMDGPUMetadata.h:34-51 | COV 版本常量 |
| AMDGPUHSAMetadataStreamer.cpp:255-279, 488, 555, 560, 581, 619-725, 727, 748 | metadata 流水 |
| AMDGPUTargetStreamer.cpp:58, 804, 823, 913, 929, 969, 1076-1098, 1104, 1129 | note/e_flags/kd 发射 |
| AMDGPUBaseInfo.cpp:239 | ELFABI 版本 |
| AMDGPUFixupKinds.h:21 / AMDGPUMCCodeEmitter.cpp:401, 498 | fixup 与编码 |
| AMDGPUELFObjectWriter.cpp:41-100 | 重定位映射 |
| AMDGPUAsmParser.cpp:6205, 7187, 7230 | 指令解析 |
| Utils/AMDGPUPALMetadata.cpp:54, 864 | PAL |
| ELF.h:2005 | NT_AMDGPU_METADATA |
| git: 7498cd61fb79 / ed0b9af9973e / f4ace6373747 / 1194b9cdda30 / 4428b01faa41 / 500846d2f542 / 3d1705d00c5f | 版本考古 |

实测命令索引：llc -filetype=obj + llvm-readelf（msgpack note/REL64/PROTECTED 符号）；llvm-mc 汇编路径（.amdhsa_code_object_version 5）；objdump 反汇编（dual-issue/s_code_end padding）。
