# 07 调度模型与 intrinsic 生成（笔记）

## 调度模型

**schema**（llvm/include/llvm/Target/TargetSchedule.td）：
- `class SchedMachineModel`(:76)：IssueWidth/MicroOpBufferSize/LoadLatency/
  MispredictPenalty/Itineraries/CompleteModel 等字段。
- WriteRes(:310)/SchedWriteRes(:318)、ReadAdvance(:347)/SchedReadAdvance(:355)、
  InstRW(:464)、SchedVariant（variant class）。

**解析与展开**（Common/CodeGenSchedule.cpp:182-250 流水线）：
collectProcModels(:515) → collectSchedRW(:580，检测 SchedVariant :568) →
collectSchedClasses(:829，InstRW 匹配 :897-916) → collectProcItins →
**inferSchedClasses（variant 展开）**：inferFromRW(:1682-1730) 先
expandRWSequence(:1694) 再循环 substituteVariants(:1717-1725) 直到不动点，
生成带谓词的过渡类。

**发射**（SubtargetEmitter.cpp）：emitSchedModel(:1593) →
genSchedClassTables → emitProcessorModels(:1621，生成 MCSchedModel 表)；
expandSchedPredicates(:1643) 把 FeatureSchedPredicate 变成
`STI.hasFeature(...)` 运行时代码。InstrInfoEmitter 用
`getSchedClassIdx`（CodeGenSchedule.cpp:928）把调度类索引写进每条 MCInstrDesc
（E04 的 ADD16rr 行中第 5 列）。

**运行时消费**（定位，未做行为验证）：
- llvm/lib/CodeGen/TargetSchedule.cpp:117 `resolveSchedClass`（variant 在此
  经 STI->resolveSchedClass 动态消解，:130）。
- llvm/lib/MCA/InstrBuilder.cpp:38/233 `SM.getSchedModel()` /
  `MCSchedModel::computeInstrLatency`；:537/563 `isVariant()` 检查。
**边界**：TableGen 产出的是模型数据；调度算法（list scheduler、MCA 模拟）
在手写 C++ 中。MSP430 没有任何 *Sched*.td —— 小目标可以不给调度模型。

## intrinsic（E08 实测 + 静态）

- schema：llvm/include/llvm/IR/Intrinsics.td `class Intrinsic`(:816)：
  LLVMName/TargetPrefix/RetTypes/ParamTypes/IntrProperties 等。
- 加载：Basic/CodeGenIntrinsics.cpp:77-114 CodeGenIntrinsicTable：
  getAllDerivedDefinitions("Intrinsic")，按 (TargetPrefix, Name, record ID)
  排序（:86-101 —— record ID 做 tie-breaker 保证可重复构建）。
- 发射：Basic/IntrinsicEmitter.cpp:99-149，-gen-intrinsic-enums 只出枚举；
  另有 IITInfo/属性表/名称表/重载表等十余种。

**E08 三口径对照**（为什么不能拿行数当数量）——同范围统计（dump-json
instanceof 计数，**已修正**，原先数字来自不同范围不可比）：
- `Intrinsics.td` 全展开后**全部 def**（--print-records）：**31,668**
- 其中 **Intrinsic 类的实例**：**16,709**
- 其中 **TargetPrefix="nvvm"** 的 Intrinsic：**2,797**
- 对应生成 **NVVM 枚举**（-gen-intrinsic-enums -intrinsic-prefix=nvvm）：**2,797**
  —— 与上一行精确相等，说明枚举 1:1 来自 nvvm 前缀的 Intrinsic record。
- .td 源文件行数与以上口径都不同：foreach/defm 在 record 层展开（如 NVVM 的
  `nvvm_applypriority_async_bulk_tensor_evict_priority_im2col_{3d,4d,5d}` 从
  同一条 def 展开，枚举注释里都指向 IntrinsicsNVVM.td:3541 同一行；归档
  NVVMEnums.inc:19-21）。注意 `…_im2col_3d` 与 `…_im2col_w_128_3d` 是
  **两条独立枚举**（:19 与 :25），来自同一 multiclass 的不同展开，**不是**
  类型重载关系。
  **重载类型后缀不会增加 intrinsic 枚举 ID**——正确示例是 `int_fabs`
  （Intrinsics.td:1254，`llvm_anyfloat_ty` + `LLVMMatchType<0>`）：
  `llvm.fabs.f32`/`llvm.fabs.f64` 共用同一枚举项 `fabs`（实测全量
  -gen-intrinsic-enums 输出中 fabs 只出现一次）；`LLVMMatchType` 的差异只
  体现在 mangled 名/IIT 签名表。
  → 结论：报 intrinsic 数量必须声明分母（源行 / 展开 record / Intrinsic 实例 /
  某前缀枚举）。
