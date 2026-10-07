# 04 从通用记录到 LLVM 目标描述（笔记）

## 关键证据：schema 不是内建

- `Instruction`、`RegisterClass`、`Operand`、`SubtargetFeature` 全部定义在
  llvm/include/llvm/Target/Target.td（:663/:292/:1100/:544），是普通 TableGen class。
- 语义来自 C++ 侧的字符串查询：
  - CodeGenTarget.cpp:81 `getAllDerivedDefinitions("Target")`
  - CodeGenInstruction.cpp:87 `Rec->isSubClassOf("RegisterOperand")`
- 推论：加 schema 字段 = 改 .td class + 改读取它的 C++；前端零改动。

## 包装层锚点

| 类 | 文件:符号 | 职责 |
|---|---|---|
| CodeGenTarget | Common/CodeGenTarget.cpp:79 构造；:265 ReadInstructions；:302 ComputeInstrsByEnum | 目标单例；指令枚举序=伪指令在前+名字序（:335-344） |
| CodeGenInstruction | Common/CodeGenInstruction.cpp:418 构造；:30-200 操作数列表；:395 ParseConstraints | outs/ins 校验、MIOperandInfo 展开、tied 约束 |
| CodeGenRegBank | Common/CodeGenRegisters.cpp:1222 构造；:356-389 RegUnit；:2486 inferCommonSubClass | tuple 展开、RegUnit、类推断 |
| CodeGenDAGPatterns | Common/CodeGenDAGPatterns.cpp:3345 流水线；h:239 TypeInfer | pattern 构造、类型推断、变体、flags 推断 |
| CodeGenSchedModels | Common/CodeGenSchedule.cpp:182 流水线 | 调度模型解析与 variant 展开 |
| CodeGenIntrinsicTable | Basic/CodeGenIntrinsics.cpp:77 | intrinsic 加载排序 |

## 三态 flags（mayLoad/mayStore/hasSideEffects）

Target.td:719-720 留 `?` → CodeGenInstruction.cpp:459-465 `getValueAsBitOrUnset`
保留 → CodeGenDAGPatterns.cpp:4239 InferInstructionFlags 从 pattern 推断 →
:4300 VerifyInstructionFlags 校验冲突。这是"声明 + 推断 + 校验"三段式范例。

## MSP430 继承链（E04 已验证生成）

Target.td Instruction
→ MSP430InstrFormats.td:32 MSP430Inst（+bits<48> Inst 字段）
→ :45 IForm（位布局 Inst{15-12}=opcode …）
→ :193 I16rr
→ MSP430InstrInfo.td:447 multiclass Arith 的 def 16rr
→ :527 defm ADD : Arith<0b0101,"add",add,1,[]> ⇒ **ADD16rr**

GR16：MSP430RegisterInfo.td:81 RegisterClass<"MSP430",[i16],16,(add R12,…)>

## InstructionEncoding 的分离

Target.td:600 InstructionEncoding（Size/DecoderNamespace/DecoderMethod/
hasCompleteDecoder）从 Instruction 独立出来；EncodingByHwMode(:653) 按 HwMode
覆盖。Common/InstructionEncoding.h:55 的包装被 CodeEmitterGen 与 DecoderEmitter
共享——编码与解码是同一描述的两个投影。
