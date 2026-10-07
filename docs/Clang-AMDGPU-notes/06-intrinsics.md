# §7 clang intrinsic 头文件三层结构深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，clang-24 @ build-debug 实测（-nogpulib 必须）。
> 引用格式 `文件:行号`；实测素材 `Clang-AMDGPU-notes/scratch/intr/`（sleep.cl/rfl.cl/gpu.hip 等）。
> 素材来源：子代理调研（引用与动态输出均已核实，两处任务假设被证伪修正）+ 主会话代写。

**先修正两处任务假设**（子代理证伪）：
1. **无 `amdgcn.h`**——实际文件是 `clang/lib/Headers/amdgpuintrin.h`（164 行）
2. **`BuiltinsAMDGPU.def` 不存在**——已 TableGen 化为 `Basic/BuiltinsAMDGPU.td`（1411 行，851 个 def）+ BuiltinsAMDGPUDocs.td（891 行）；`Targets/AMDGPU.cpp:66-75` include 生成的 .inc
3. `__is_cpp_global` 全仓不存在——泛化机制是**头文件级静态分发**（非内部判定）

---

## 7.1 三层结构（修正后）

```
① generic GPU 层：gpuintrin.h（348 行）
   __gpu_* 接口，OpenMP/HIP/CUDA/OpenCL 共享（头注释 :9-13 自述）
   :21 __HIP__||__CUDA__ → _DEFAULT_FN_ATTRS=device
   :35-43 目标分发：__NVPTX__→nvptxintrin.h / __AMDGPU__→amdgpuintrin.h / __SPIRV__→spirvintrin.h
② AMDGCN 专属层：amdgpuintrin.h（164 行）
   :12-14 无 __AMDGPU__ 则 #error；:16-18 禁止直连
③ 裸 builtin 层：__builtin_amdgcn_* 直接使用
```

HIP 真实入口链：`hip_wrappers/hip/hip_runtime.h:23-25` → `__clang_gpu_intrinsics.h:12-15`（`__HIP__||__CUDA__` 门卫 + include gpuintrin.h）→ 提供 **CUDA 兼容层** `__shfl*/__syncwarp/__ballot_sync/__reduce_*_sync`（:44-203）。

## 7.2 gpuintrin.h 精读（generic 层）

- 接口集：`__gpu_thread_id/num_blocks/block_id`（switch 三维 :56-109）、`__gpu_first_lane_id`（:112 用 `__builtin_ffsll`）、`__gpu_read_first_lane_*`/`__gpu_shuffle_idx_*`（:124-176，`__builtin_bit_cast` 类型穿透）、**`__DO_LANE_OPS` 宏**（:184-221，log2 步 shuffle scan：add/and/or/xor/min/max/minnum/maxnum × u32/u64/f32/f64）
- amdgpuintrin.h 映射表（AMDGCN 实现）：

| generic | AMDGCN 实现 | 行号 |
|---|---|---|
| __gpu_lane_id | mbcnt_hi(lo(~0,0)) | :97-99 |
| __gpu_lane_mask | read_exec | :102-104 |
| __gpu_ballot | lane_mask & ballot_w64 | :113-118（注释：匹配 nvptx 语义） |
| __gpu_sync_threads | s_barrier + fence(SC,"workgroup") | :121-124 |
| __gpu_shuffle_idx_u32 | ds_bpermute(lane<<2,x) | :132-137 |
| __gpu_thread_suspend | s_sleep(2) | :157-159 |

AS 别名 AS(1/3/4/5)（:24-28）。**分发不是函数内判定而是头文件级**（nvptxintrin.h 各自包装）。

## 7.3 builtin→intrinsic 映射机制（双向绑定）

- **通用通路**：`CGBuiltin.cpp:6884-6899` `getIntrinsicForClangBuiltin("amdgcn", Name)` 查表——表由 TableGen 生成（`Intrinsics.cpp:839-841`；生成器 `TableGen/Basic/IntrinsicEmitter.cpp:1140-1178`，按 TargetPrefix 分组去公共前缀）
- **反向声明**：`IntrinsicsAMDGPU.td` 中 `ClangBuiltin<"__builtin_amdgcn_X">`（class 在 Intrinsics.td:850）。例：s_barrier td:284、wave_barrier:351、s_waitcnt:393、s_sleep:2247（ImmArg）、endpgm:2695
- **重载 intrinsic 例外**（无 ClangBuiltin 绑定）：走 `CodeGen/TargetBuiltins/AMDGPU.cpp` `EmitAMDGPUBuiltinExpr`（:559+）——ballot_w32/w64（:790-794，`getIntrinsic(amdgcn_ballot, {ResultType})`）、readfirstlane（:693-695）、wave_reduce 族 26 个 case（:564-595）、EmitAMDGCNBallotForExec（:283-303，read_exec 用 ballot(true)+移位实现）
- BuiltinsAMDGPU.td 样例：s_waitcnt:149 / s_barrier:152 / wave_barrier:154 / s_sleep:207（均 _Constant int）/ ballot_w32:344（feature wavefrontsize32）/ permlane16:469（gfx10，2 个 _Constant bool）/ read_exec:574 / endpgm:578 / wave_reduce:594-599 / gfx12 s_barrier_signal 族 :759-765
- **数量不对称**：后端 `^def int_amdgcn` **600 个**（td 631 def/4383 行）vs 前端 851 builtin def——非 1:1（多对一合成，如 w32/w64→重载 ballot）

## 7.4 wave 原语全链（衔接后端）

- `int_amdgcn_s_barrier` → `SOPInstructions.td:1653` 直接选 S_BARRIER；wave_barrier → `SIInstructions.td:531`；s_waitcnt → `SOPInstructions.td:1696`（timm）
- **正例 vs §4 反例**：OpenCL `barrier()` 是外部调用（02-codegen.md §4.3）；而 `__gpu_sync_threads()` **内联展开为 `call void @llvm.amdgcn.s.barrier()` + `fence syncscope("workgroup") seq_cst`**（官方测试 clang/test/Headers/gpuintrin.c:449-454 FileCheck 验证）；`__gpu_sync_lane` → `llvm.amdgcn.wave.barrier()`（:457-464）；`__gpu_lane_mask` -O0 下实为 `ballot.i64(i1 true)`（:375-379）
- 后端衔接引用：AMDGPU-notes/03-structurize.md（SILowerControlFlow.cpp:11-50 exec mask 头注释）

## 7.5 动态验证（实测）

| 用例 | IR 输出 | 结论 |
|---|---|---|
| sleep.cl（OpenCL） | `tail call void @llvm.amdgcn.s.sleep(i32 2)` / `@llvm.amdgcn.s.waitcnt(i32 0)` / `@llvm.amdgcn.ballot.i64(...)`；declare 带 **immarg** | ImmArg 生效 ✓ |
| rfl.cl | `declare i32 @llvm.amdgcn.readfirstlane.i32(i32)` | 重载实例化 ✓ |
| -dM -E（OpenCL） | `__AMDGCN__ 1 / __AMDGPU__ 1 / __AMD__ 1 / __AMDGCN_CUMODE__ 1` | 宏体系 |
| -dM -E（HIP） | 追加 `__HIP__ / __HIP_DEVICE_COMPILE__ / __HIP_MEMORY_SCOPE_WAVEFRONT=2 / __amdgcn_processor__="gfx906"` | HIP 特有宏 |
| **负结果（有价值）** | HIP -nogpuinc 下直连 builtin（`__attribute__((device))` 函数内）报 "reference to __host__ function"——SemaCUDA::IdentifyTarget（:238-243）本应对隐式 builtin 声明给 HostDevice 待遇，实测仍拒 | 真实 HIP 编译靠 `__clang_gpu_intrinsics.h:24` 的 `__GPU_DEVICE__=(device,always_inline)` C++ 包装层规避；此摩擦点机制未深挖（标注） |
| OpenMP -fopenmp | frontend 崩溃（signal） | 未深究，标注 |

## 7.6 昇腾映射（推理级，待验证）

三层结构对 PyPTO 的启示：
1. **Python DSL 语义接口层 ≈ `__gpu_*`**（可移植：m200/m300 通用语义）
2. **目标实现层 ≈ amdgpuintrin.h**（按目标宏静态分发到具体原语）
3. **直通原语层 ≈ ClangBuiltin 双向绑定**——**新增原语 = 前后端各一行 td 绑定**，TableGen 自动生成查表（pto-isa 加新 tile 指令时，Python 绑定的生成机制可完全照抄这个双向绑定模式）

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| gpuintrin.h:9-13, 21, 35-43, 56-221 | generic 层 |
| amdgpuintrin.h:12-28, 97-159 | AMDGCN 层 |
| __clang_gpu_intrinsics.h:12-15, 24, 44-203 | HIP 入口链 |
| hip_wrappers/hip/hip_runtime.h:23-25 | wrapper |
| CGBuiltin.cpp:6884-6899 / Intrinsics.cpp:839-841 / IntrinsicEmitter.cpp:1140-1178 | 查表通路 |
| Intrinsics.td:850 / IntrinsicsAMDGPU.td:284, 351, 393, 2247, 2695 | ClangBuiltin 反向声明 |
| CodeGen/TargetBuiltins/AMDGPU.cpp:283-303, 559-795 | 重载例外 |
| BuiltinsAMDGPU.td:149-759（851 def） | 前端定义 |
| SOPInstructions.td:1653, 1696 / SIInstructions.td:531 | 后端 ISel 直选 |
| clang/test/Headers/gpuintrin.c:375-464 | 官方验证 |
| Targets/AMDGPU.cpp:66-75 / SemaCUDA IdentifyTarget :238-243 | inc 表 / 负结果 |
