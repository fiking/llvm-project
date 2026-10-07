# HIP 深度分析 — 基线存档（Task 0）

日期：2026-09-30
基准：llvm-project main @ `3eda2aebadd4`

## 文件清单（实测 wc -l）

### Driver 工具链（993 行）
| 文件 | 行数 | 角色 |
|---|---|---|
| HIPAMD.cpp | 219 | ROCm 本体路径（clang offload → lld 双阶段） |
| HIPSPV.cpp | 450 | SPIR-V 替身路径（llvm-spirv） |
| HIPUtility.cpp | 102 | 共用（bundler 调用） |
| HIPAMD.h / HIPSPV.h / HIPUtility.h | 71/119/32 | 声明 |

### 头文件族（2,687 行）
| 文件 | 行数 | CUDA 镜像 |
|---|---|---|
| __clang_hip_math.h | 1,405 | __clang_cuda_math（静态分发同构） |
| __clang_hip_cmath.h | 848 | __clang_cuda_cmath |
| __clang_hip_libdevice_declares.h | 238 | __clang_cuda_libdevice_declares（__ockl/__oclc vs __nv_） |
| __clang_hip_runtime_wrapper.h | 153 | __clang_cuda_runtime_wrapper |
| __clang_hip_stdlib.h | 43 | — |

### 文档与工具
| 文件 | 行数 |
|---|---|
| clang/docs/HIPSupport.md | 1,159（官方兼容矩阵） |
| clang/tools/offload-arch/AMDGPUArchByHIP.cpp | 444（HIP 离线探测） |

### 散布统计
- Driver.cpp 80 处 HIP 引用；SemaCUDA.cpp 14 处；HIPAMD::Linker::ConstructJob :194 起

## 子任务分工
| Notes | 章节 | 内容 |
|---|---|---|
| 01-reuse-audit.md | §2 | 语言机器复用审计 |
| 02-driver.md | §3 | 工具链双路径 |
| 03-headers.md | §4 | 头文件族镜像 |
| 04-matrix-tools.md | §5+§6 | 兼容矩阵+生态工具 |
