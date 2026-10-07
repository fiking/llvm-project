# Clang-NVPTX 深度分析 — 基线存档（Task 0）

日期：2026-09-29
基准：llvm-project main @ `3eda2aebadd4`，clang-24 @ build-debug（nvptx64 支持）

## 可用编译路径（实测）

```bash
# 唯一可出 IR/PTX 的组合（绕三个坑）：
./build-debug/bin/clang-24 --target=nvptx64-nvidia-cuda -march=sm_70 \
  -nocudainc -nocudalib --cuda-device-only -S -emit-llvm -o out.ll x.cu
# ✅ nvvm-reflect-ftz module flag 可见：!0 = !{i32 4, !"nvvm-reflect-ftz", i32 0}

# 完整 offload 模式（-### 已验证，fatbinary 缺失会失败但命令行正确）：
./build-debug/bin/clang-24 -### --cuda-gpu-arch=sm_70 -c x.cu
```

## 三个坑（实测记录，复现手册素材）

1. **-mcpu= 被拒 / -march= 接受但不传播**：`--target=nvptx64-nvidia-cuda -march=sm_70` 编译通过，但 PTX 输出仍 `.target sm_52`（默认值）——sm_XX 需 --cuda-gpu-arch 或 -mcpu 走完整 offload 流程才传播
2. **nvptx_kernel 属性直用时 kernel 被丢弃**：`__attribute__((nvptx_kernel))` 直写 + -x cuda 或直连 target，kernel 不进输出（无 .entry）——CUDA 前端机（__global__ 宏链）必须激活
3. **无 CUDA toolkit**：完整路径报 "cannot find CUDA installation"；libdevice 报 "cannot find libdevice for sm_52"

## 关键文件

- SemaCUDA.cpp **1297 行**（host/device Sema 核心战场，IdentifyTarget :238-243 锚点已有）
- CGCUDANV.cpp 1544 行（host stub 生成，NVPTX-notes/06 已析 fatbin 部分）
- __clang_cuda_* 头文件族 **10 个**（runtime_wrapper/builtin_vars/cmath/math/device_functions/intrinsics/libdevice_declares/math_forward_declares/complex_builtins/texture_intrinsics）
- Targets/NVPTX.cpp 212 + .h 210；nvptxintrin.h 208（三重门卫已析）

## 子任务分工

| Notes | 章节 | 内容 |
|---|---|---|
| 01-sema.md | §2 | SemaCUDA 1297 行 |
| 02-codegen.md | §3+§5 | CGCUDANV 增量 + 执行模型属性 |
| 03-headers.md | §4 | CUDA 头文件族 10 个 |
| 04-targetinfo.md | §6 | Targets/NVPTX + __CUDA_ARCH__ |
| 05-ascend.md | §8 | AscendC 路线判定（Web） |
