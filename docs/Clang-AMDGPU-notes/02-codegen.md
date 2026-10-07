# §4 clang CodeGen 的 AMDGPU 五大映射（AST→IR）深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，clang-24 @ build-debug 实测（amdgcn-amd-amdhsa, gfx1100, -nogpulib, -cl-std=CL2.0）。
> 引用格式 `文件:行号`；实测素材 `Clang-AMDGPU-notes/scratch/sync.cl`/`sync2.cl`。
> 素材来源：子代理调研（引用已核实，含两个推翻任务假设的负结果）+ 主会话动态验证代写。
> 衔接：后端消费者视角见 AMDGPU-notes/02-ir-layer.md；本文件是前端生产者视角。

---

## 4.1 映射一：AS 限定符（完成度最高）

**完整映射表**（`clang/lib/Basic/Targets/AMDGPU.cpp:31-63` `AMDGPUAddrSpaceMap`）：

| LangAS | 目标 AS | 行号 |
|---|---|---|
| Default | FLAT | :32 |
| opencl_global | GLOBAL | :33 |
| opencl_local | LOCAL | :34 |
| opencl_constant | CONSTANT | :35 |
| opencl_private | PRIVATE | :36 |
| opencl_generic | FLAT | :37 |
| cuda_device | GLOBAL | :40 |
| cuda_constant | CONSTANT | :41 |
| cuda_shared | LOCAL | :42 |
| **amdgpu_barrier** | **BARRIER** | **:63** |

注意 `amdgpu_barrier`——**BARRIER=15 的前端来源就是这张表**（AMDGPU-notes §2 地址空间超载的源头在此）。hlsl_private→PRIVATE 带 `FIXME(pr/122103)`。

**链路**：LangAS 声明 `AMDGPU.h:33` → `ASTContext.cpp:13995-13996` getTargetAddressSpace（`ASTContext.h:3379`）→ CodeGenModule 使用点 585/594/5422/5593/6058。

**getNullPointer**（`Targets/AMDGPU.cpp:483-497`）：private/local 空指针以 **generic null + addrspacecast** 发出（LLVM 假设 null==0 的约束）——非零地址空间空指针的通用解法。

## 4.2 映射二：kernel CC（完整链 + 重要负结果）

**完整生成链**：
```
Attr.td:1670-1700 DeviceKernel 拼写（__kernel/kernel/amdgpu_kernel/nvptx_kernel/device_kernel）
→ ParseDecl.cpp:1071,4070
→ SemaDeclAttr.cpp:5919-5923（CC_DeviceKernel）
→ CGCall.cpp:293-294 → CGCall.cpp:62,98-100 ClangCallConvToLLVMCallConv
→ Targets/AMDGPU.cpp:477-479 AMDGPU_KERNEL（=91，CallingConv.h:200）
```

**负结果（三方 grep 验证）**：clang 前端**不产生**任何 AMDGPU_CS/PS/VS/GS/HS/LS/ES——`clang/lib/` 零匹配。数值：VS=87(:188) GS=88(:191) PS=89(:194) CS=90(:197) KERNEL=91(:200) HS=93(:206) LS=95(:213) ES=96(:218) CS_Chain=104(:245)。**图形 CC 由 Mesa/AMDPAL 外部栈在 IR 层使用**（`llvm/docs/AMDGPUUsage.rst:2847+` amdgpu-cc 表）——clang 只服务计算路径，图形是 IR 级生态。

**附加发现**：
- OpenCL kernel stub 机制：`CodeGenModule.cpp:4857`（deferred emit stub）、`:2552`（`__clang_ocl_kern_imp_` 前缀——实测 IR 中可见此前缀）、`:7198`（stub 加 AlwaysInline）
- 全局 ctor/dtor 包装也设 AMDGPU_KERNEL（`CGDeclCXX.cpp:822,983`）
- 默认 flat-work-group-size "1,256"（`Targets/AMDGPU.cpp:346,375-384`）；cluster 默认 "0,0,0"（:449-452）

## 4.3 映射三：barrier——负结果定案（实测确认）

**子代理疑点 → 实测定案**：CodeGen **不产生** `llvm.amdgcn.s.barrier`。发出的是**带 convergent 属性的外部调用**：

```bash
$ clang-24 --target=amdgcn-amd-amdhsa -cl-std=CL2.0 -emit-llvm sync2.cl
tail call void @_Z18work_group_barrierj(i32 noundef 1) #4     ← 外部 C++ mangling 调用！
```

- 声明源：`opencl-c.h:12399` barrier / `:12402-12403` work_group_barrier（CL2.0+）；`OpenCLBuiltins.td:943` `Builtin<"barrier",[Void,MemFenceFlags],Attr.Convergent>`
- **向 s_barrier 的转换不在前端也不在后端**——发生在**设备库（ockl）链接后**或由 ROCm 运行时头内联定义（-nogpulib 时汇编输出只剩未解析符号 `_Z18work_group_barrierj@rel32`）
- **设计含义**：OpenCL 的同步语义是"语言层声明 + 库层实现"，与 CUDA（__syncthreads 是编译器 builtin）相反——**clang 对 OpenCL 的介入比想象更薄**
- `__builtin_amdgcn_s_sleep` 系内建链：`BuiltinsAMDGPU.def` + `Targets/AMDGPU.cpp:66-70` inc 表（子代理线索，未展开）

## 4.4 映射四：printf——前端薄到只有声明

**核心发现**：printf 是**普通 C 变参声明**（`opencl-c-base.h:621-631`，format attr），**非 builtin 无 CodeGen 特判**（grep 验证）→ 前端只发外部调用 `@printf(ptr addrspace(4),...)`。

**但实测发现第二层**：现代 clang（-cl-std=CL2.0 实测）在**头文件层**做了 `__printf_alloc` 变换：
```
%printf_alloc_fn = tail call ptr addrspace(1) @__printf_alloc(i32 8)
%.not = icmp eq ptr addrspace(1) %printf_alloc_fn, null       ← null 检查
store i32 1, ptr addrspace(1) %printf_alloc_fn               ← control string id
%PrintBuffGep = getelementptr i8, ..., i64 4                  ← 参数打包
```
这是 opencl-c.h 内 inline 包装（`__clang_ocl_kern_imp_` stub 内可见）做的 hostcall buffer 协议——**头文件承担了"设备函数库"的职责**。

**后端衔接**：`AMDGPUPrintfRuntimeBinding.cpp:1-17,36,70,133`（buffer 路径 pass）+ `AMDGPU.h:551` 工厂；`amdhsa_abi.h:23-24` printf_buffer/hostcall_buffer（opencl_global）偏移断言 :55-73（**printf_buffer=72、hostcall=80**——implicit arg 表的精确偏移）。双路径的 `-cl-std`/flag 判定条件未钉死（待查）。

## 4.5 映射五：atomic/atomic_work_item_fence（实测）

```bash
$ clang-24 -cl-std=CL2.0 -emit-llvm sync2.cl
tail call void @_Z22atomic_work_item_fencej12memory_order12memory_scope(
    i32 noundef 4,    ← CLK_IMAGE_MEM_FENCE
    i32 noundef 3,    ← memory_order_release
    i32 noundef 2)    ← memory_scope_device
```
- 与 barrier 同构：**外部调用 + C++ mangling**，非 intrinsic
- **scope/order 枚举作为普通 i32 透传**——到 atomicrmw/IR metadata 的转换同样在库层
- 声明：`opencl-c.h:13280-13281`

## 4.6 动态验证汇总

| 用例 | IR 输出（实测） | 结论 |
|---|---|---|
| kernel 声明 | `define protected amdgpu_kernel void @k(ptr addrspace(1)...)` + 元数据五件套 + `__clang_ocl_kern_imp_` stub（AlwaysInline） | CC+AS 映射实锤 |
| barrier（CL1.2） | `tail call void @_Z7barrierj(i32 2) #4` | 外部调用非 intrinsic |
| work_group_barrier（CL2.0） | `tail call void @_Z18work_group_barrierj(i32 1) #4` | 同上 |
| printf | `@__printf_alloc(8)` + null 检查 + control string id + GEP 打包 | **头文件层 hostcall 协议** |
| atomic_work_item_fence | `@_Z22atomic_work_item_fencej12memory_order12memory_scope(4,3,2)` | 枚举 i32 透传 |
| -nogpulib 汇编 | `_Z18work_group_barrierj@rel32` 未解析符号 + `.Lk.num_named_barrier` | 库缺失直透证据 |

## 4.7 五大映射的统一结论

**clang 前端对 OpenCL 的介入比预期薄得多**：
1. AS 映射是**唯一深度介入**（表驱动直译）
2. kernel CC 一行判断链
3. barrier/printf/atomic 全部是**外部调用 + 库层实现**（printf 的 hostcall 协议甚至在头文件 inline 里）
4. "语言语义 → 硬件语义"的翻译主体在 **ROCm 设备库（ockl）**，不在编译器——**这是与 NVPTX/CUDA 路径的根本差异**（CUDA 的 __syncthreads 是编译器 builtin）

## 4.8 昇腾映射（推理级，待验证）

1. 昇腾 OpenCL 的 barrier/scope 若同样走库层（libascendcl 设备侧？待验证），则 CCE 的"薄前端"程度与 clang-OpenCL 同级
2. **"编译器 builtin vs 语言声明+库实现"的分界**是重要参照：PyPTO 的 tile 原语（__syncthreads 类）若做成编译器 builtin（SDAG pattern 直出指令），性能与诊断都优于库调用路径——AMDGPU 的 s_barrier intrinsic 之所以能在后端精确建模（Waitcnts 交互），正因为它是 intrinsic 而非外部调用
3. printf 的"头文件协议"模式：PyPTO 的调试输出若走 hostcall buffer 类协议，`__printf_alloc` 的 null-check+打包是现成模板

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| Targets/AMDGPU.cpp:31-63, 66-70, 346, 375-384, 449-452, 477-479, 483-497 | AS 表/CC/null |
| AMDGPU.h:33 / ASTContext.cpp:13995-13996 / ASTContext.h:3379 | LangAS 链 |
| CodeGenModule.cpp:585-6058（多点）, 2552, 4857, 7198 | stub 机制 |
| Attr.td:1670-1700 / ParseDecl.cpp:1071,4070 / SemaDeclAttr.cpp:5919-5923 / CGCall.cpp:62,98-100,293-294 | CC 生成链 |
| CallingConv.h:188-245 | CC 数值 |
| opencl-c.h:12399-12403, 13280-13281 / opencl-c-base.h:621-631 | 语言声明 |
| OpenCLBuiltins.td:943 | barrier builtin 定义 |
| CGDeclCXX.cpp:822,983 | ctor/dtor CC |
| AMDGPUPrintfRuntimeBinding.cpp:1-133 / AMDGPU.h:551 / amdhsa_abi.h:23-73 | printf 后端衔接 |
| llvm/docs/AMDGPUUsage.rst:2847+ | 图形 CC 外部生态 |

实测素材：scratch/sync.cl（CL1.2 barrier+printf）、sync2.cl（CL2.0 全量：work_group_barrier/atomic_fence/printf hostcall 协议）。
