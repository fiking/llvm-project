# §4 HIP 头文件族与 CUDA 头镜像解剖

> 基准：llvm-project main @ `3eda2aebadd4`，clang-24 @ build-debug 实测（-E 展开）。
> 引用格式 `文件:行号`；实测素材 HIP-notes/scratch/（t.pp/t2.pp/t_rtc.pp 等）。
> 素材来源：子代理调研（API 超时死亡，transcript 164 行素材回收——镜像统计/分布计数/-E 展开均已完成）+ 主会话代写组装。

---

## 4.1 __clang_hip_math.h（1,405 行）函数分布与镜像率

**实测统计**（transcript 回收）：
- CUDA 侧合并 math+device_functions：**562** 个唯一函数名（math 179 + devfn 383）
- HIP hip_math 唯一函数：**256** 个
- **交集：244/256 = 95.3% 镜像率**（HIP 侧 12 个独有：__HIP_DEFINE_EXTENDED 域函数等）
- CUDA 侧多出的 318 个（__dadd_rd 系 IEEE 取整运算、__nv_ 前缀内部函数）在 HIP 侧**不存在**——ROCm 的 IEEE 取整走 intrinsic，无 libdevice 中间层

分布结构：hip_math 的 256 函数按目标分类（__ockl_ 条目 grep 计数 169 个落 __ocml/__ockl 调用）+ 少量 __builtin 直通 + OVERLOAD 泛型（`__HIP_OVERLOAD2(double, fmax)` :507-508 式三类型泛化）。

**宏名代际差异**：CUDA 用 `__CLANG_CUDA_APPROX_TRANSCENDENTALS__`（math.h:51-54 门控），HIP 侧已统一到 `__CLANG_GPU_APPROX_TRANSCENDENTALS__`（新代共享层命名——CUDA 头也在迁移，:54 处 `#if defined(__CLANG_GPU_...)`）。

## 4.2 libdevice_declares（238 行）命名空间

- HIP：`__ocml_*`（数学）/`__ockl_*`（runtime 工具）双前缀——**ocml 是数学库、ockl 是 kernel library** 的分工（衔接 Clang-AMDGPU-notes/04 六家族：ocml+ockl+oclc 三态）
- CUDA：`__nv_*` 单前缀（libdevice.10.bc 单体）
- 组织差异：HIP 按类别分节（数学/取整/比较），CUDA 按模块顺序罗列

## 4.3 cmath（848 行）镜像率

- HIP cmath 唯一函数 25 个（DEF_FUN 宏系 :225-226 `__DEF_FUN2(float, fmax)`）+ OVERLOAD 泛型（copysign/fdim/fmax/fmin/hypot/max/min/nearbyint/nextafter/remainder/rint/round/scalbn 十余族×3 类型）
- CUDA 侧同族存在（`__clang_cuda_cmath.h`）——**OVERLOAD 泛型机制两侧同构**（`max(5.0f, 6.0)` 跨类型解析的注释 :463 两侧都有）

## 4.4 runtime_wrapper（153 行）为何比 CUDA 短 3.4 倍

- CUDA wrapper 526 行要做**宏污染**（毒化 __host__/重定义 __forceinline__/跳过 SDK inline asm——Clang-NVPTX-notes/03 已析）
- HIP wrapper 只做 include 链：`hip/amd_detail/hip_runtime_amd.h`（**外部 ROCm 头**）+ device 侧 `__clang_hip_libdevice_declares.h`/`__clang_hip_math.h` 等——**SDK 兼容层由 ROCm 自己维护**（hip_runtime_amd.h），clang 不碰
- `AMDGPU.cpp:531` AddHIPIncludeArgs 注入 `--hip-path` 搜索（:613 err_drv_no_hip_runtime 实测触发过）；`:626` CC1Args `-include __clang_hip_runtime_wrapper.h`

## 4.5 stdlib（43 行）

malloc/free 的 device 侧：`__hip_size_t` + weak inline `malloc` → `__ockl_dm_alloc`（:14 式）——transcript 实测 -E 展开确认无 ROCm 下走 weak 定义分支。

## 4.6 动态验证（-E 实测，transcript 回收）

```
# 手动 include 绕 wrapper，预处理展开 hip_math：
$ clang-24 -E -x hip -nogpuinc ... -include __clang_hip_math.h t.hip
float cosf(float __x) { return __ocml_cos_f32(__x); }     ← 落 __ocml
float sqrtf(float __x) { return __builtin_sqrtf(__x); }   ← 高频直通 builtin（:689）
# __CLANG_GPU_APPROX_TRANSCENDENTALS__ 门控实测可见（math.h:41-44）
```
**两条落点路径实证**：`__ocml_*` 库调用（transcendental）与 `__builtin_*` 直通（sqrtf 等 CPU 可精确实现的）——与 CUDA 侧 `__nv_*` 全走 libdevice 的策略差异。

坑：`-nogpuinc` 在纯 -E 模式报 unknown argument（该 flag 是 Driver 级；-E 直跑须绕过）。

## 4.7 昇腾映射（推理级，待验证）

**PyPTO "CUDA 数学函数兼容层"选型**（两条路线对照）：
1. **HIP 模式（推荐）**："同名函数→目标 runtime 直调"（__ocml/__builtin 双路）——省掉中间 bitcode 层，符号在头文件即闭合；PyPTO tile 数学可直调 CANN device lib 或直出 intrinsic
2. CUDA 模式："声明（__nv_）+链接期 libdevice.10.bc"——需要闭源 bc 的分发/版本管理，但 vendor 可独立更新数学库
3. HIP 的 `__CLANG_GPU_*` 共享宏代际（CUDA 头也在迁移）说明：**双 target 共享层的终态是 gpu 前缀统一**——PyPTO 若多后端，数学层头文件应一开始就用平台无关前缀

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| __clang_hip_math.h:43-75, 225-226, 449-450, 507-508, 689, 1316-1319 | 分发/OVERLOAD/builtin |
| __clang_hip_libdevice_declares.h | __ocml/__ockl 双前缀 |
| __clang_cuda_math.h:51-54, 226-227, 307 | CUDA 对照/宏代际 |
| __clang_cuda_device_functions.h:443 | __nv_isnanf |
| AMDGPU.cpp:531, 613, 626 | wrapper 注入 |
| 实测统计：562 vs 256/交集 244/95.3% 镜像率 | transcript 回收 |
| -E 展开：t.pp/t2.pp/t_rtc.pp（cosf→__ocml/sqrtf→__builtin） | scratch |
