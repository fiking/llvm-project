# §3+§5 CUDA 执行模型属性→CodeGen 映射 + CGCUDANV 增量深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，clang-24 @ build-debug 实测（--cuda-device-only 绕坑路径）。
> 引用格式 `文件:行号`；实测素材 `Clang-NVPTX-notes/scratch/attrs.cu`。
> 素材来源：子代理调研（引用已核实）+ 主会话动态验证代写。
> 防重复：CGCUDANV 的 fatbin/ctor/MD5 部分见 NVPTX-notes/06-downstream.md §7.1。

---

## 5.1 执行模型属性定义（Attr.td）

| 属性 | 定义 | Subject | 互斥 |
|---|---|---|---|
| CUDAConstant | Attr.td:1546-1551 | Var | :1662 |
| CUDADevice | :1558-1563 | Function+Var | :1598（与 Global） |
| CUDAGlobal | :1592-1597 | Function | :1598, :1607 |
| CUDAHost | :1600-1606 | —（SimpleHandler=1） | :1607 |
| CUDAShared | :1656-1661 | Var | :1662 |
| HIPManaged | :1616-1621 | Var（LangOpts=[HIP]） | :1662 |

注释 :1544-1545：CUDA 属性无 `[[]]` 拼写。**`__managed__` 在 CUDA 模式同样落到 HIPManagedAttr**：SemaDeclAttr.cpp:5491-5504 handleManagedAttr 同时附加 HIPManagedAttr + **隐式 CUDADeviceAttr**（这是它进 AS1 的通路）。

## 5.2 属性→AS 映射（§5 核心）

**CodeGenModule::GetGlobalVarAddressSpace**（CodeGenModule.cpp:6407-6446），CUDA 分支 :6423-6438：

| 属性 | LangAS | NVPTXAddrSpaceMap（NVPTX.h:27-45） | IR AS |
|---|---|---|---|
| __device__（默认） | cuda_device | **1**（GLOBAL） | addrspace(1) |
| __shared__ | cuda_shared | **3**（SHARED） | addrspace(3) |
| __constant__ | cuda_constant | **4**（CONST） | addrspace(4) |
| const 限定自动 | cuda_constant（:6434） | 4 | — |
| managed（隐式 device） | cuda_device（:6437） | 1 | — |

NVPTX 表与 AMDGPU 表（Clang-AMDGPU-notes/02 §4.1）**共享 opencl_global→1/local→3/constant→4 行**——两个 target 的 LangAS 命名空间统一设计；DWARF 表 :49-55。

**`__global__` 入口判定：不是 nvvm.metadata kernel，而是 CC**——NVPTX.cpp:267-279 setTargetAttributes：CUDAGlobalAttr→NoInline(:270) + `setCallingConv(PTX_Kernel)`(:272，来自 :86-88 getDeviceKernelCallingConv)；CGCall.cpp:99-100 CC_Device→钩子。nvvm.annotations（NVPTX.cpp:286-301）仅用于 surface/texture(:249-252)。`__grid_constant__`→参数 attr(:274-278)；`__launch_bounds__`→MaxNTID/MinCTASm/MaxClusterRank(:329-369)。

## 5.3 CGCUDANV 增量（stub/externalize）

- **替身机制**：CodeGenModule.cpp:5907-5911 host 侧 CUDAGlobal→getKernelHandle；**CUDA（非 HIP）handle 就是函数自身**（CGCUDANV.cpp:1523-1527），仅 HIP 建 GlobalVariable handle(:1529-1543)；stub 名加 `__device_stub__` 前缀（CodeGenModule.cpp:2548-2550）
- emitDeviceStub（CGCUDANV.cpp:331-346）+ CUDA 9.0+ emitDeviceStubBodyNew（:418-426 起，cudaLaunchKernel）；getDeviceSideName(:298-329)
- **RDC 外部化**：ASTContext::mayExternalize（ASTContext.cpp:15509-15525）/shouldExternalize（:15527-15531，条件=HIPManaged‖CUDAGlobal‖ODRUsedByHost）；getDeviceSideName :319-327 附加 postfix；internalizeDeviceSideVar（CGCUDANV.cpp:1181-1204）：非 RDC 时 host 侧 device/constant/shared 影子→InternalLinkage
- **`__managed__` 设备侧变换**：transformManagedVars（CGCUDANV.cpp:1259-1290）——变量改为 cuda_device AS 的"指向变量的指针"、原名加 `.managed`、externallyInitialized；host 侧不 Undef 化（CodeGenModule.cpp:6618-6622 排除 HIPManaged，"双侧初始化"）；注册走 handleVarRegistration(:1206-1227)

## 5.4 -fcuda-is-device 传导链

- 定义：Options.td:9199-9201（CC1Option + `MarshallingInfoFlag<LangOpts<"CUDAIsDevice">>`，自动进 CompilerInvocation）
- Driver 注入点：Cuda.cpp:916（`{"-fcuda-is-device","-fno-threadsafe-statics"}`）、AMDGPU.cpp:928、HIPSPV.cpp:273、Clang.cpp:8421（OpenMP 经 LLVM offload）
- **消费点普查：143 处引用**，CodeGen 占大头——CodeGenModule.cpp×24、CGDeclCXX.cpp:541（禁全局 init）、CGExpr.cpp:6745（host 动态影子）、CGCall.cpp:2443、CGDebugInfo.cpp:6376、InitPreprocessor.cpp:613/1493、CompilerInvocation.cpp:5170（device 时 HostTriple=AuxTriple）；LangOptions.h:821-824 isTargetDevice()

## 5.5 --cuda-device-only / --cuda-host-only

Options.td:1416-1418 别名→offload_device_only/offload_host_only(:1300-1303)；Driver.cpp:1696-1705 设 Offload=OffloadHost/OffloadDevice。OffloadAction 图裁剪细节（BuildUniversalModes/handleDeviceOffloadAction）未及核对（标注）。

## 5.6 动态验证（实测，--cuda-device-only）

scratch/attrs.cu（`__device__/__constant__/__shared__` + kernel）的 IR 输出：

```llvm
@gvar = dso_local addrspace(1) externally_initialized global i32 1      ← __device__→AS1 ✓
@cvar = dso_local addrspace(4) externally_initialized constant i32 2    ← __constant__→AS4 ✓
@_ZZ1kPiE4sarr = internal addrspace(3) global [8 x i32] undef           ← __shared__ 局部→AS3 internal ✓
define dso_local ptx_kernel void @_Z1kPi(ptr noundef %sv)               ← __global__→ptx_kernel CC ✓
```
**五属性四 AS 一次实测全中**——与 §5.2 映射表逐项吻合。附加观察：访问全部经 `addrspacecast to ptr`（generic 视角 load/store，与 AMDGPU 默认 FLAT 同构——InferAddressSpaces 的下游优化空间）。

## 5.7 设计动机总结

1. **CUDA 属性是"编译器一等公民"**：Attr.td 定义→Sema 校验→CodeGen AS/CC 映射→NVPTX 后端消费，全链在编译器内（对照 OpenCL 的限定符也是同构直译，但语义原语 barrier 等走库）
2. **`__managed__` 的复杂性**：HIPManagedAttr 复用 + 隐式 device + transformManagedVars 指针化 + 双侧初始化——单一属性背后四层机制
3. **143 处 CUDAIsDevice 消费**：device 编译是"同一编译器换人格"（大量行为分支），不是独立编译器

## 5.8 昇腾映射（推理级，待验证）

AscendC 的 __gm/__ub 若有类似 Attr→AS 映射则同构（待验证）；`__launch_bounds__`→MaxNTID/MinCTASm 链对 PyPTO 的 tile 形状参数化（若做成函数属性，后端可消费为预算约束）是现成模式。

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| Attr.td:1544-1662 | 六属性定义与互斥 |
| SemaDeclAttr.cpp:5491-5504 | managed 双 attr |
| CodeGenModule.cpp:2548-2550, 5907-5911, 6407-6446, 6618-6622, 6229-6231 | AS 分配/stub/managed |
| NVPTX.h:27-55 / NVPTX.cpp:86-88, 249-279, 286-301, 329-369 | AS 表/setTargetAttributes |
| CGCall.cpp:99-100 | CC 钩子 |
| CGCUDANV.cpp:298-346, 418-426, 1181-1290, 1523-1543 | stub/externalize/managed |
| ASTContext.cpp:15509-15531 | mayExternalize |
| Options.td:1300-1303, 1416-1418, 9199-9201 | 选项 |
| Cuda.cpp:916 / AMDGPU.cpp:928 / Clang.cpp:8421 | 注入点 |
| Driver.cpp:1696-1705 | device-only |

实测素材：scratch/attrs.cu（五属性四 AS 全实测）。
