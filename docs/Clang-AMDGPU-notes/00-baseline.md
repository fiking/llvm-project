# Clang-AMDGPU 深度分析 — 基线存档（Task 0）

日期：2026-09-29
基准：llvm-project main @ `3eda2aebadd4`，clang-24 @ build-debug（含 amdgcn/amdgpu target）

## 冒烟验证（已通过）

```bash
# 1. OpenCL C → gfx1100 汇编（-nogpulib 绕过缺失的 ROCm device library）
printf 'kernel void k(global int* p) { p[0] = 1; }\n' > /tmp/t2.cl
./build-debug/bin/clang-24 --target=amdgcn-amd-amdhsa -mcpu=gfx1100 -nogpulib -S -o /tmp/t2.s /tmp/t2.cl
# ✅ 输出 .amdgcn_target "amdgpu11.00-amd-amdhsa-unknown-gfx1100" + s_load_b64/v_mov
# 注：正名陷阱实测印证（amdgpu 新名，与 AMDGPU-notes/08-mc-obj.md §10.8 呼应）

# 2. OpenCL C → LLVM IR（CodeGen 全链可实测）
./build-debug/bin/clang-24 --target=amdgcn-amd-amdhsa -mcpu=gfx1100 -nogpulib -S -emit-llvm -o /tmp/t2.ll /tmp/t2.cl
# ✅ 关键 IR 形态：
#   define protected amdgpu_kernel void @k(ptr addrspace(1) ...) — kernel CC + AS1
#   !kernel_arg_addr_space !11 !kernel_arg_access_qual !12 ... — OpenCL 元数据五件套
#   datalayout: p1:64(GLOBAL) p3:32(LOCAL) p4:64(CONSTANT) p5:32(PRIVATE) p7:160(BUFFER_FAT)
#   ni:7:8:9 — fat pointer 非整数地址空间（衔接 AMDGPU-notes §4 LowerBufferFatPointers）

# 3. -### Driver 序列（存 scratch/driver_amdgcn.txt）
# cc1 -triple amdgpu11.00-amd-amdhsa（注意 subarch 进 triple）...

# 4. 无 ROCm（报错实测）："cannot find ROCm device library; provide its path
#    via --rocm-path or --rocm-device-lib-path, or pass -nogpulib"
```

## 关键事实

- Driver/ToolChains/AMDGPU.cpp 1406 行（主战场）+ AMDGPU.h 197 + HIPUtility.cpp 102
- Basic/Targets/AMDGPU.cpp 371 / .h 507
- Headers：__clang_hip_math.h 1405、gpuintrin.h 348、__clang_gpu_* 系 5+ 文件
- CGOpenCLRuntime.cpp 仅 159 行（"为何这么薄"是论题）
- HIP.cpp 已不存在（并入 AMDGPU.cpp/HIPUtility.cpp）
- OpenCL IR 元数据五件套实测：kernel_arg_addr_space/access_qual/type/base_type/type_qual

## 子任务分工

| Notes 文件 | 章节 | 内容 |
|---|---|---|
| 01-driver.md | §2 | Driver/ROCm 探测/工具链 |
| 02-codegen.md | §4 | 五大映射 |
| 03-languages.md | §3 | OpenCL vs HIP 双路径 |
| 04-devlib.md | §5 | ocml/ockl 生态 |
| 05-targetinfo.md | §6 | TargetInfo/AS 布局 |
| 06-intrinsics.md | §7 | 头文件三层 |
| 07-ascend.md | §9 | CCE 前端/tiling 入口（Web） |
