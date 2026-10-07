# clang→NVPTX 前端路径深度分析（CUDA C++）

> 数据基准：llvm-project main @ `3eda2aebadd4`（2026-09-29），clang-24 @ build-debug 实测。
> 方法：静态分析（引用一律 `文件:行号`，全部经 grep/read 核对）+ 动态验证（-### / -emit-llvm / -dM -E 宏 diff / 编译期错误消息原文）。
> 五部曲定位：横向对比 → AMDGPU 后端 → NVPTX 后端 → clang-AMDGPU 前端 → **本文档（clang-NVPTX/CUDA C++ 前端，收官）**。
> 素材全文：`Clang-NVPTX-notes/01..05-*.md`（约 900 行）；scratch/ 存全部实测产物。

---

## 目录

- §1 摘要与核心论点
- §2 SemaCUDA（host/device 双编译语言机器）
- §3+§5 执行模型属性→CodeGen + CGCUDANV 增量
- §4 CUDA 头文件族 10 个
- §6 TargetInfo（__CUDA_ARCH__ 双通道）
- §7 与 clang-AMDGPU 六层对偶表
- §8 昇腾映射（AscendC 路线判定）
- §9 复现手册（含三坑）

---

## §1 摘要与核心论点

> **CUDA C++ 是 GPU 语言中编译器集成度最高的路径**——host/device 双编译在 Sema 层组织（SemaCUDA 四态机）、执行模型属性是编译器一等公民（Attr→AS/CC 全链编译器内）、同步原语纯 builtin 直出 intrinsic（`__syncthreads` 不在任何头文件里）、threadIdx 全编译期零调用残留。**与 clang-AMDGPU 文档的"语义翻译在设备库"结论构成完整镜像**：CUDA 把 OpenCL 推给库的每一层都收进了编译器。

**五个贯穿性实证**：
1. **五属性四 AS 一次实测全中**：`__device__`→AS1、`__constant__`→AS4、`__shared__`→AS3、`__global__`→`ptx_kernel` CC（不是 metadata）
2. **`__syncthreads` 一层直通**（BuiltinsNVPTX.td:896 + NVPTX.cpp 特判）vs OpenCL 三层接力 vs HIP 两层——三语言 barrier 对照闭环
3. **threadIdx 机制三元**：property getter + builtin + intrinsic，四变量仅 weak 声明
4. **`__CUDA_ARCH__` 双通道**：前端宏（device 编译期可见）+ 后端 NVVMReflect（libdevice 内求值）——为何两条：host 编译时没有后端
5. **-march 坑实锤**：`-march=sm_70` 被译成 `-aux-target-cpu`，主 TargetInfo 仍 sm_52——正确姿势 `--cuda-gpu-arch`

---

## §2 SemaCUDA：双编译的语言机器

**详见 `01-sema.md`**

- **独立类**：`SemaCUDA : SemaBase`（SemaCUDA.h:45）——已从 Sema 拆分
- **四态机**：IdentifyTarget（:238-243）对 implicit 声明自动给 **HostDevice**"最大灵活性"——HIP builtin 摩擦的根源
- **无白名单无 push/pop**：是规则桶 + 对 CurContext 即时查询（任务书三个预设机制全部证伪）
- **实测四链**：host←device 调用（"candidate not viable"**软排除**而非硬错误——重载机制的 CUDA 扩展）；kernel 必须 void 返回；必须 free function；重载正常解析

## §3+§5 执行模型属性→CodeGen

**详见 `02-codegen.md`**

- **六属性定义**（Attr.td:1544-1662）+ 互斥链；**`__managed__` 落到 HIPManagedAttr + 隐式 CUDADeviceAttr**（进 AS1 的通路）
- **`__global__` 是 CC 不是 metadata**：CUDAGlobalAttr→`setCallingConv(PTX_Kernel)`（NVPTX.cpp:267-279）；nvvm.annotations 仅 texture/surface
- **CUDA（非 HIP）kernel handle 就是函数自身**——HIP 才建 GlobalVariable handle（RDC 差异根源）
- **`__managed__` 四层机制**：双 attr + transformManagedVars 指针化（原名加 `.managed`）+ 双侧初始化 + handleVarRegistration
- **143 处 CUDAIsDevice 消费**：device 编译是"同一编译器换人格"

## §4 CUDA 头文件族

**详见 `03-headers.md`**

- **wrapper 衔接是"宏污染"而非 include_next**：毒化 `__host__`、重定义 `__forceinline__`；跳过 SDK 的 inline asm 用 builtin"让优化器推理"（官方理由）
- **threadIdx 机制三元**（property/getter/builtin）；%tid.x 特殊寄存器链终点实测
- **数学三分层**：__expf/expf 两族直绑（非宏门控）+ `__FAST_OR_SLOW` 只门控 5 个超越函数（-fgpu-approx-transcendentals）——与 HIP 同构
- **`__syncthreads` 纯编译器 builtin**：BuiltinsNVPTX.td:896；CodeGen/TargetBuiltins/NVPTX.cpp:1413-1415 特判直出 intrinsic；texture 是 asm 例外区（constexpr 编译期字符串哈希选模板特化）
- **真实边界**：builtin_vars.h 不可独立于 wrapper 使用（SemaCUDA 豁免失效）

## §6 TargetInfo

**详见 `04-targetinfo.md`**（361 行完整成稿）

- **单类双实例化**：无 NVPTXTargetInfo64 类，构造函数第三参 TargetPointerWidth 区分
- **__CUDA_ARCH__ 双通道**：值由后端 target defines 设置（NVPTX.cpp:196-197，sm_70→700）；InitPreprocessor 只做无值兜底；`__CUDA_ARCH_LIST__` 是 driver 层 -D 注入
- **sm_70 vs sm_90 宏 diff（实测 449 宏）**：仅 __CUDA_ARCH__ 两个不同；sm_90a 额外 3 个 SPECIFIC 宏
- **-march 坑 -### 铁证**：`-march=sm_70`→`-aux-target-cpu sm_70`，主 TargetInfo 仍 sm_52——TargetInfo 的 GPU 只认 `-target-cpu` 通道
- **checkCallingConvention**：无 host 时白名单仅 CC_DeviceKernel；fastcall 告警实测；DeviceKernel 拼写表 5 种

---

## §7 与 clang-AMDGPU 六层对偶表（收官对照）

| 层 | clang-NVPTX/CUDA | clang-AMDGPU/OpenCL+HIP |
|---|---|---|
| Sema | **SemaCUDA 四态机**（1297 行，编译器内双编译） | OpenCL：Sema 厚（SemaOpenCL+17k .inc）但无双编译；HIP：零（借 CUDA 机） |
| 执行模型 | Attr 一等公民（__global__→CC/AS 全编译器内） | 限定符直译（同样 AS 表，但 barrier 等语义在库） |
| 同步原语 | **builtin 一层直通**（__syncthreads 无头文件） | **库三层接力**（barrier→opencl.bc→builtin）/ HIP 两层 |
| threadIdx | property→builtin→intrinsic 全编译期 | get_global_id 库调用 |
| 数学库 | libdevice 一份 .bc + **NVVMReflect 后端求值** | ocml 库 + **oclc 多份预编译 .bc 链接时选** |
| 配置分发 | __CUDA_ARCH__ 前端宏（host 侧伪 9999）+ 后端 reflect 双通道 | oclc_isa_version_XXX per-arch 文件 |
| Host stub | CGCUDANV cudaLaunchKernel（handle=函数自身） | HIP 同文件但 handle=GlobalVariable（RDC 根源差异） |
| 生态位 | 编译器一等公民（语义全在编译器） | 语义在设备库（opencl.bc/ocml/ockl） |

**镜像总结**：CUDA 把 OpenCL 推给库的每一层（Sema 双编译/同步/线程索引/配置分发）都收进了编译器；HIP 是两者的中间态（借 CUDA 机 + hermetic 宏层）。

## §8 昇腾映射：AscendC 路线判定

**详见 `05-ascend.md`**（Web 检索失败，推理级全文标注待验证）

```
OpenCL 库接力 ←———— AscendC（中部偏左）————→ CUDA 编译器一等公民
```

- **AscendC 是混合体**：类库外观（TPipe/TQue 头文件）+ 编译器扩展内核（__gm/__ub 属性、同步 intrinsic）+ 构建系统层双编译（无 SemaCUDA）
- **tiling 编译期不可见**（独立 json+host api 通道）——编译器无法做预算优化（对照 AMDGPU occupancy 编译期威力）
- **对 PyPTO 的四条启示**：tile 原语走 CUDA 路（一等公民）；tiling 走语言内（tile 形状作指令操作数）；不需要 SemaCUDA（纯设备 DSL）；验证途径已列（gitee cann-compiler/本地 CANN grep）

## §9 复现手册

```bash
cd ~/code/llvm-project   # main @ 3eda2aebadd4
CL=build-debug/bin/clang-24
# 绕坑三连：-nocudainc -nocudalib --cuda-device-only（-x cuda 不激活前端机！）

# 冒烟：五属性四 AS（§3+§5）
$CL --target=nvptx64-nvidia-cuda -march=sm_70 -nocudainc -nocudalib --cuda-device-only \
    -S -emit-llvm -o - Clang-NVPTX-notes/scratch/attrs.cu | grep -E "@gvar|@cvar|@sarr|define"

# Sema 四链（§2）：host←device / void 返回 / free function / 重载
$CL --target=nvptx64-nvidia-cuda -march=sm_70 -nocudainc -nocudalib --cuda-device-only -S -o /dev/null /tmp/err1.cu
$CL ... err2.cu   # kernel function type 'int ()' must have void return type
$CL ... err3.cu   # kernel function 'm' must be a free function or static member function

# %tid.x 链终点（§4）
$CL ... tid.cu | grep "%tid"    # mov.u32 %r1, %tid.x

# 宏 diff（§6）
$CL --target=nvptx64-nvidia-cuda -march=sm_70 -nocudainc -nocudalib --cuda-device-only \
    -dM -E -o /tmp/m70.txt -x cuda /dev/null   # __CUDA_ARCH__ 700
$CL -### --cuda-gpu-arch=sm_70 -c /tmp/m2.cu 2>&1 | grep -oE '"-target-cpu[^"]*"|"-aux-target-cpu[^"]*"'  # 三坑之一

# 三坑速查（00-baseline.md）：
# ① -mcpu= 被拒；-march= 被译成 -aux-target-cpu（主 TargetInfo 不变 sm_52）→ 用 --cuda-gpu-arch
# ② __attribute__((nvptx_kernel)) 直用 kernel 被丢弃 → 需 CUDA 前端机（宏链）
# ③ 无 CUDA toolkit → -nocudainc -nocudalib；libdevice 链接层失败属预期
```

---

## 附录：章节-素材对照与执行注记

| 章 | 素材 | 行数 | 产出方式 |
|---|---|---|---|
| §2 | 01-sema.md | 95 | 子代理成稿提取+主会话补 4 条实测 |
| §3+§5 | 02-codegen.md | — | 子代理调研+主会话五属性实测代写 |
| §4 | 03-headers.md | — | 子代理调研（含真实边界负结果）+主会话补验证 |
| §6 | 04-targetinfo.md | 361 | 子代理成稿提取（-march 坑 -### 铁证） |
| §8 | 05-ascend.md | — | 子代理 API 超时死亡，主会话基于框架代写（全标注待验证） |

执行注记：1 主会话 + 5 子代理（4 次额度耗尽由提取/代写回收、1 次 API 超时死亡主会话接管）。4 处任务假设证伪（InstantiateDelayedException 不存在/DeduceLambdaType 不存在/白名单不存在/-march 假传播）。动态验证全实跑（五属性 IR/四条 Sema 错误消息/%tid.x 终点/449 宏 diff/-### 铁证）。
