# 04-05 目标 schema 与 MSP430 多产物链（笔记）

## MSP430 的 CMake 生成动作（llvm/lib/Target/MSP430/CMakeLists.txt:5-14）

10 个动作：-gen-asm-matcher / -gen-asm-writer / -gen-callingconv / -gen-dag-isel /
-gen-disassembler / -gen-emitter / -gen-instr-info / -gen-register-info /
-gen-sd-node-info / -gen-subtarget。（E04 全部直跑成功，产物大小见 10 号笔记。）

## ADD16rr：一条指令的完整投影（E04 证据）

**定义链**（全部是 .td，无内建语义）：
1. llvm/include/llvm/Target/Target.td 定义 `class Instruction`（通用 schema）。
2. llvm/lib/Target/MSP430/MSP430InstrFormats.td:32
   `class MSP430Inst<dag outs, dag ins, int size, string asmstr> : Instruction`：
   `field bits<48> Inst;` + Namespace/OutOperandList/InOperandList/AsmString/Size。
3. :45 `class IForm<bits<4> opcode, DestMode ad, bit bw, SourceMode as, …>`：
   编码布局 `let Inst{15-12} = opcode; Inst{11-8} = rs; Inst{7} = ad.Value;
   Inst{6} = bw; Inst{5-4} = as.Value; Inst{3-0} = rd;`
4. :193 `class I16rr<…> : IForm16<opcode, DstReg, SrcReg, 2, …>`。
5. MSP430InstrInfo.td:447 `multiclass Arith<bits<4> opcode, string asmstring,
   SDPatternOperator node, bit commutes, list<Register> uses>` 定义
   `def 16rr : I16rr<opcode, (outs GR16:$rd), (ins GR16:$src2, GR16:$rs),
   !strconcat(asmstring, "\t$rs, $rd"),
   [(set GR16:$rd, (node GR16:$src2, GR16:$rs))]>;`（嵌套 let：Defs=[SR]、
   Constraints="$src2 = $rd"、isCommutable）。
6. :527 `defm ADD : Arith<0b0101, "add", add, 1, []>;` → 实例化名 `ADD` + `16rr`。

**生成物中的投影**（E04 产物）：
- 枚举：MSP430GenInstrInfo.inc `ADD16rr = 346, // MSP430InstrInfo.td:455`
- MCInstrDesc 行：`{ 346, 3, 1, 2, 0, 0, 1, MSP430OpInfoBase + 184, 0,
  0|(1<<Commutable)|(1<<ExtraSrcRegAllocReq)|(1<<ExtraDefRegAllocReq), 0x0ULL }`
- 编码基值（MSP430GenMCCodeEmitter.inc）：`UINT64_C(20480)` = 0x5000
  —— 即 IForm 中 `Inst{15-12} = 0b0101`，rs/rd 留作运行时填充。
- 反汇编（MSP430GenDisassemblerTables.inc，123KB）：固定 0x5000 位模式 + 解码。
- 汇编打印（MSP430GenAsmWriter.inc）：字符串表偏移 17550 → "add\t$rs, $rd" 模板。

**消费点**（静态）：
- llvm/lib/Target/MSP430/MCTargetDesc/MSP430MCTargetDesc.cpp:26-34
  `#define GET_INSTRINFO_MC_DESC / GET_SUBTARGETINFO_MC_DESC / GET_REGINFO_MC_DESC`
  分别 include 对应 .inc —— 同一 .inc 因宏不同产出不同段（第 5 章正文的宏分段机制）。
- MCTargetDesc/MSP430MCCodeEmitter.cpp:218 `#include "MSP430GenMCCodeEmitter.inc"`。
- MSP430InstrInfo.cpp:23 include GenInstrInfo.inc。

## GR16 寄存器链

- MSP430RegisterInfo.td:12 `class MSP430Reg<bits<4> num, string n, list<string> alt>
  : Register<n>`：`let HWEncoding{3-0} = num;` —— HWEncoding 是 schema 字段。
- :35-56 16 个 `MSP430RegWithSubregs`（R0..R15，各带 8 位子寄存器 R0B..R15B，
  `def subreg_8bit : SubRegIndex<8>`）。
- :81 `def GR16 : RegisterClass<"MSP430", [i16], 16, (add R12, R13, …, PC, SP, SR, CG)>;`
  —— ValueTypes=[i16]、对齐 16、成员顺序即分配优先级（add 保序）。

## NVPTX 对照（E07，静态）

llvm/lib/Target/NVPTX/CMakeLists.txt:5-10 只有 6 个动作：
asm-writer / dag-isel / instr-info / register-info / sd-node-info / subtarget。
**没有 -gen-emitter、-gen-disassembler、-gen-asm-matcher** —— NVPTX 输出 PTX 文本，
不做机器码编码/反汇编；这就是"生成职责边界"的直接证据。

## AMDGPU 对照（静态）

llvm/lib/Target/AMDGPU/CMakeLists.txt:5-39：20 个动作，比 MSP430 多
-gen-pseudo-lowering / -gen-register-bank / -gen-searchable-tables /
-gen-global-isel（:23，带 -gisel-extended-llt）/ 三组 -gen-global-isel-combiner
（PreLegalize/PostLegalize/RegBank，:24-28）。R600 子目标另有一套（:32-39）。
