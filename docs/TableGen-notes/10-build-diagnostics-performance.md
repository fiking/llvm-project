# 10 构建、诊断、测试与性能（笔记）

源码锚点见正文第 10 章；此处只记实验数据。

## E12 确定性与计时（build-debug，LLVM 24.0.0git）

- `-gen-instr-info` 对 MSP430.td 连续两次运行：`run1.inc` 与 `run2.inc` SHA256 均为
  `772cbc0f…490180`，逐字节一致。
- `--null-backend --time-phases`（MSP430.td，Debug 构建）：
  - `Parse, build records` 1.4752 s（wall，100%）
  - `Backend overall` 与 `Write output` 在计时分辨率内为 0
  - 结论口径（**已修正**）：`--null-backend` **主动跳过所有生成器**（Main.cpp
    中 null backend 解析后直接返回，不构造 emitter），因此这条计时只是
    **前端基线**——证明"MSP430 这种小输入解析不慢"，**不能**推出真实生成任务中
    前端也占 ~100%。要判断真实生成任务的耗时占比，应对具体 `-gen-*` 动作计时
    再与基线相减。不外推到其他目标或 Release。

## E04 生成物规模（MSP430，字节数）

| 动作 | 大小 |
|---|---|
| -gen-instr-info | 249,852 |
| -gen-register-info | 535（仅宏分发骨架，实际内容拆分到 *Enums/Header/MCDesc/TargetDesc.inc） |
| -gen-asm-writer | 37,970 |
| -gen-emitter | 37,675 |
| -gen-disassembler | 123,326 |
| -gen-asm-matcher | 73,630 |
| -gen-subtarget | 11,295 |
| -gen-dag-isel | 328,656 |
| -gen-callingconv | 3,034 |

注意：手工 -gen-register-info 直跑产物 535B 是因为 RegisterInfoEmitter 使用
`TableGenOutputFiles` 多文件输出（Main.cpp 写附加文件）；CMake 的 tablegen() 会声明
这四个 EXTRA_OUTPUTS（TableGen.cmake:70-77）。直接运行时在输出同目录产生
`MSP430_gen-register-info{Enums,Header,MCDesc,TargetDesc}.inc`。

## E05 AMDGPU GlobalISel（Debug 构建）

- 命令：`llvm-tblgen -gen-global-isel -gisel-extended-llt -warn-on-skipped-patterns AMDGPUGISel.td`
- 产物：AMDGPUGenGlobalISel.inc = 105,394,333 字节（≈105 MB）
- stderr：117,672 行，其中 `Skipped pattern` 警告 10,120 条（**已按归档日志
  重新统计，下列合计恰为 10,120**）。
  分布前几位：
  "Pattern operator lacks an equivalent Instruction" **8,017**（≈79%，主因）；
  "unsupported type for Src operand" 1,815；EXTRACT_SUBREG 类 75；
  "Src pattern child has predicate" 44；"Pattern defines a physical register" 42；
  SDNodeXForm 类 **63**（as_i16imm 40 / as_i64imm 15 / IMMBitSelConst 6 /
  bitcast_fpimm_to_i16 2）；"Src pattern root isn't a trivial operator" 仅 24；
  ComplexPattern 22；"Could not infer register class" 14；"unsupported predicate" 4。
  → 主因是 **pattern 算子缺少等价 Instruction**，发生在**源模式匹配器导入
  阶段**：GlobalISelEmitter.cpp:814-817 对源 SDNode 查 GINodeEquiv 映射
  （findNodeEquiv），查不到即 failedImport，无法建立 GMIR opcode 匹配——
  **不是**目标指令缺少渲染器，也**不是**匿名谓词；
  "root isn't trivial operator (Has a predicate (anonymous_21308)…)"
  （SOPInstructions.td:302 例）只占 24 条，且匿名命名本身
  不是拒绝条件——它是谓词附着于根节点的表象。详见 06 笔记与正文第 6 章。

## E08 intrinsic 三口径（Intrinsics.td，同范围统计，**已修正**）

- 展开后**全部 def**（--print-records 计数 `^def `）：31,668
- 其中 **Intrinsic 类实例**：16,709
- 其中 **TargetPrefix="nvvm"** 的 Intrinsic：2,797
- 对应 **NVVM 枚举**（-gen-intrinsic-enums -intrinsic-prefix=nvvm）：**2,797**（与上行 1:1）
- 重载类型后缀不增加枚举 ID：LLVMMatchType 变体共享同一 record/枚举项，
  只在 mangled 名/IIT 签名表区分。
- 结论：`.td` 源行、展开 record 数、生成枚举数是三个不同分母，不可混用。

## 构建集成要点（静态核对，E11 的运行时验证未做）

- `tablegen()`（llvm/cmake/modules/TableGen.cmake:7）：Ninja+CMP0116 时传 `-d ${ofn}.d`
  depfile（:36-56）；否则回退 `file(GLOB …)` 全 .td 依赖。
- `--write-if-changed` 由 CMake 在非 VS 生成器下传入（:89-96），实现于 Main.cpp:118-138
  （内容一致则不覆盖，错误时不 keep）。
- `-gen-register-info` 的 4 个 EXTRA_OUTPUTS 在 TableGen.cmake:70-77 声明。
- 宿主工具选择：LLVM_NATIVE_TOOL_DIR（llvm/CMakeLists.txt:858）、
  LLVM_USE_HOST_TOOLS（:1009-1012）触发 CrossCompile.cmake 的 NATIVE 子构建（Release）。
- llvm-min-tblgen 只含构建 llvm/include 所需后端，不依赖 TableGenCommon
  （llvm/utils/TableGen/CMakeLists.txt:11-24）；llvm-tblgen 全量后端见同文件 :31-83。
