# AMDGPU 深度分析 — 基线存档（Task 0）

日期：2026-09-28
基准：llvm-project main @ `3eda2aebadd4`（[lldb][test] Disable TestEvents.py (#226486)）

## 构建配置

| 构建目录 | 类型 | Targets | 用途 |
|---|---|---|---|
| build-shared | Release | host only（无 AMDGPU） | 不可用于本分析 |
| build-debug | Debug + Assertions=ON | AMDGPU;NVPTX;AArch64 | **动态验证一律用它** |

## 冒烟验证（已通过）

```bash
cd ~/code/llvm-project
printf 'define i32 @f(i32 %%a, i32 %%b) { ret i32 %%a }\n' > /tmp/smoke.ll

# 1. 基本编译（0.13s，gfx1100）
./build-debug/bin/llc -march=amdgcn -mcpu=gfx1100 -filetype=null /dev/null
# ✅ 无 error（deprecation warning 可忽略）

# 2. -debug-only 通道
./build-debug/bin/llc -march=amdgcn -mcpu=gfx1100 -debug-only=isel -o /dev/null /tmp/smoke.ll
# ✅ 输出 SelectionDAG ISel 日志（"Initial selection DAG: %bb.0" 等）

# 3. -print-after 通道
./build-debug/bin/llc -march=amdgcn -mcpu=gfx1100 -print-after=amdgpu-isel -o /dev/null /tmp/smoke.ll
# ✅ 输出 MIR（bb.0 (%ir-block.0):）
```

## 关键事实

- 源码目录 `llvm/lib/Target/AMDGPU/` 共 311 个条目
- 大文件：SIISelLowering.cpp 21,639 / GCNHazardRecognizer.cpp 4,361 / SIInsertWaitcnts.cpp 3,775 / AMDGPUTargetMachine.cpp 2,858 / SIMachineScheduler.cpp 1,992 / SILowerControlFlow.cpp 941
- 官方文档 `llvm/docs/AMDGPU/` 11 份
- 测试 `llvm/test/CodeGen/AMDGPU/` 3,512 个 .ll
- MCA 自定义行为存在：`llvm/lib/Target/AMDGPU/MCA/AMDGPUCustomBehaviour.cpp`

## 子任务分工

| Notes 文件 | 章节 | 内容 |
|---|---|---|
| 01-architecture.md | §3 | 宏观架构 + 演进史 |
| 02-ir-layer.md | §4 | IR 层 17 pass 功能卡 |
| 03-structurize.md | §5 | PreISel 结构化链 |
| 04-isel.md | §6 | SDAG+GISel 双路径 |
| 05-regalloc.md | §7 | 三段式 RA |
| 06-sched.md | §8 | 机器调度精读 |
| 07-postemit.md | §9 | PreEmit 14 pass + waitcnt/hazard 精读 |
| 08-mc-obj.md | §10 | MC 层与 Code Object |
