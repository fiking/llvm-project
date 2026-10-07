# 00 基线与工具

> 源码基准：llvm-project HEAD `3eda2aebadd4`（main，2026-10-03 前后）。
> 所有实验使用 `build-debug/bin/` 下的工具，Debug + Assertions，LLVM 24.0.0git。

## 工具清单

| 工具 | 路径 | 版本 |
|---|---|---|
| llvm-tblgen | build-debug/bin/llvm-tblgen | LLVM 24.0.0git, DEBUG build with assertions |
| llvm-min-tblgen | build-debug/bin/llvm-min-tblgen | 同上（裁剪版） |
| clang-tblgen | build-debug/bin/clang-tblgen | 同上 |
| mlir-tblgen | build-debug/bin/mlir-tblgen | 同上 |
| tblgen-lsp-server | build-debug/bin/tblgen-lsp-server | 语言服务器（附注） |
| tblgen-to-irdl | build-debug/bin/tblgen-to-irdl | .td → IRDL 转换（附注） |

注意：`build-shared/` 下另有 LLVM 19.1.7 的工具，与当前源码有版本差异，本研究不使用。

## build-debug 目标配置

`LLVM_TARGETS_TO_BUILD` 含 AMDGPU、NVPTX、AArch64（见 CMakeCache）。
这意味着：
- 宿主 tblgen 可以读取任何目标的 .td（解析与目标无关，只要 include 路径给全）。
- MSP430 的运行时实验（选指、编码执行）在此构建中不可用；本研究对 MSP430 做生成与静态追踪，运行时验证另行标注。
- AMDGPU/NVPTX 可以做完整生成；AMDGPU GlobalISel 生成实测可用（见 E05）。

## 实验记录约定

每个实验目录：`experiments/E??-*/input/`（输入）、`output/`（产物与 stderr）。
命令以绝对路径或仓库根相对路径记录，退出码与产物大小一并记录。

## 已完成实验索引

| 编号 | 内容 | 状态 |
|---|---|---|
| E01 | multiclass+foreach+defm+let 展开 | 完成，4 个 record 名称与字段全部符合断言 |
| E02 | 字段引用消解（let 覆盖后字段重消解、模板参数不重消解）+ assert 负例 | 完成，正例退出 0，负例退出 1 且诊断位置正确 |
| E04 | MSP430 九个 -gen-* 动作全部生成 | 完成（产物大小见实验目录） |
| E05 | AMDGPU GlobalISel 生成（-gisel-extended-llt -warn-on-skipped-patterns） | 完成，产物 105,394,333 字节，stderr 117,672 行含 10,120 条跳过警告（主因：lacks equivalent Instruction 8,017 条，非匿名谓词） |
| E07 | NVPTX CMake 动作清单（6 个，无 -gen-emitter/-gen-disassembler） | 完成（静态） |
| E08 | NVVM intrinsic 枚举生成 + Intrinsics.td 展开记录计数 | 完成（同范围统计）：全部 def 31,668；Intrinsic 实例 16,709；nvvm 前缀 2,797；NVVM 枚举 2,797（1:1；重载后缀不增枚举 ID） |
| E09 | Clang NoInline：def → 官方产物 Attrs.inc（实验输出名 AttrClasses.inc）→ CodeGenModule.cpp 手写消费点 | 完成（生成 + 静态追踪） |
| E10 | MLIR arith.addi：-gen-op-decls/-gen-op-defs/-gen-rewriters 三条生成链 | 完成（生成 + 静态追踪） |
