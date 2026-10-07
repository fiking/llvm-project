# §8 AscendC/CCE 路线判定（推理级，待验证）

> 证据来源声明：本章 Web 检索失败（hiascend 文档 URL 404、gitee API 无果、子代理 API 超时死亡）。
> 内容基于：① 本项目四部曲积累的对照框架（CUDA/OpenCL 两条路线已完整论证）；② 用户环境已知事实（PyPTO/pto-isa/ST 测试/CANN）；③ AscendC 公开常识。**全部结论标注"待验证"**，验证途径见 §8.7。

---

## 8.1 语言形态（待验证）

AscendC 表面是**纯 C++ 类库**（TPipe/TQue/TBuf/TDataCopy），kernel 入口形如 `extern "C" __global__ void kernel_name(...)`——`__global__` 是 CCE 提供的宏（对照 CUDA 的属性）。GetBlockIdx/TPipe 等在头文件中实现（ascendc 头文件族），但底层依赖 **CCE 特有扩展**：
- `__gm/__ub` 地址空间限定符（clang 扩展属性，映射到 davinci 段）
- 复制/同步指令的 CCE intrinsic（__builtin 系或 inline csr/汇编封装）

**判定**：外观是库（OpenCL 式），内核是编译器扩展（CUDA 式）——**混合体**。

## 8.2 host/device 结构（待验证）

AscendC 的 tiling 函数（GET_TILING_DATA 宏生成）与 kernel 同文件，但**双编译在构建系统层组织**（CMake/编译脚本分两次调用，不同 include 路径）——不是 CUDA 的 Sema 层四态机（IdentifyTarget/CurrentTarget 在编译器内）。**没有等价的 SemaCUDA**：host/device 错误（如 kernel 里调 host 函数）靠链接期或运行期发现，不是编译期 Sema 错误。

**对照**：CUDA 的"编译器换人格"（143 处 CUDAIsDevice 消费）vs AscendC 的"构建系统换编译目标"。

## 8.3 同步原语（待验证）

AscendC 的 SyncAll→`set_flag/wait_flag` 指令序列（用户 ST 测试经验：S 管线读 MTE2 的 UB 无同步保障是已知坑——正是手工插入这些原语的代价）；pipe 同步（TPipe 的 Wait/Commit）是**头文件内联封装**最终到 CCE intrinsic 或汇编。

**判定**：形态近 OpenCL（库封装），但同步指令本身是 CCE intrinsic（编译器认识）——比 OpenCL 的"外部调用直到设备库"好，但比 CUDA 的"builtin 直出 intrinsic"弱（**无 Sema 层建模**，用户侧契约兜底，与 NVPTX_Deep_Analysis §11 的 CANN 光谱结论一致）。

## 8.4 tiling 参数入口（此前推理，部分验证）

tiling 走**独立通道**：tiling 函数生成 .json/结构体 + host API（SetTilingData）传递，**不进语言/编译器**（非 fn attr 非模板参数）——对照：
- CUDA `__launch_bounds__`→fn attr→后端 MaxNTID 消费（编译期优化）
- AMDGPU flat-work-group-size→fn attr→后端 occupancy 消费（编译期优化）
- **AscendC tiling→运行时数据→驱动/硬件消费（编译期不可见）**

**代价**：编译器无法用 tiling 做预算优化（对照 AMDGPU-notes §6 occupancy 闭式反函数的编译期威力）。这是 NVPTX_Deep_Analysis §11"外移职责无回流通道"的又一实例——tiling 信息在编译器视野外。

## 8.5 CCE 前端（待验证）

CCE 是 clang fork（昇腾基于 LLVM/clang 扩展：`__gm` 类地址空间属性、昇腾 intrinsic 表、可能定制的 CodeGen）——与本项目分析的 clang-NVPTX 同构度高于 clang-AMDGPU（都是"闭源后端 + LLVM 前端"）。**用户的 pto-isa/CCE 生态里，LLVM 前端层的行为可以从 clang-NVPTX 文档直接类推**（如 Attr→AS 映射模式、builtin 双向绑定模式）。

## 8.6 路线判定（光谱定位）

```
OpenCL 库接力 ←————————————————————————→ CUDA 编译器一等公民
   │                    ▲                          │
   │              AscendC（此处）                    │
   │        类库外观 + 扩展内核 + 构建系统双编译        │
   │        tiling 编译期不可见 + 同步用户侧契约        │
```

**AscendC 位于光谱中部偏左**：比 OpenCL 好（同步原语是 intrinsic、地址空间是编译器属性），比 CUDA 弱（无 Sema 层双编译、tiling 编译期不可见、无 builtin 直通链）。

## 8.7 对 PyPTO/pto-isa 的启示

1. **tile 原语暴露走 CUDA 路**：PyPTO 直接生成指令（绕过 C 编译器），tile 原语应是"一等公民"（指令操作数直通），不是库函数——后端（pto-isa 模拟器/NPU）可精确建模
2. **tiling 走语言内**：tile 形状作为 tile 指令操作数（编译期可见），不走 AscendC 的独立通道——否则重蹈"编译器无法做预算优化"的覆辙
3. **不需要 SemaCUDA**：PyPTO 无 host/device 双编译问题（纯设备 DSL）——可省去光谱最右端的最重部件
4. **验证途径**（待验证项的核实路径）：gitee.com/ascend/cann-compiler（开源部分）查 CCE 的 builtin 表；hiascend.com 的 AscendC API 文档查 GetBlockIdx 实现；用户本机 CANN 安装目录 ascendc 头文件直接 grep

---

## 引用清单

本章无 Web 实证（检索失败），证据为推理级：
- Clang-AMDGPU-notes/02-codegen.md §4.3（OpenCL 三层接力）、Clang-NVPTX-notes/03-headers.md §4.4（CUDA 一层直通）——对照框架
- NVPTX_Deep_Analysis.md §11（CANN 光谱分析）——此前推理
- AMDGPU_Deep_Analysis.md §6（occupancy 编译期威力）——tiling 通道对照
- 用户环境事实（memory：ST 测试 set_flag/wait_flag 经验、pto-isa 上下文）
- 待验证：gitee.com/ascend/cann-compiler、hiascend.com AscendC 文档、本地 CANN 安装目录
