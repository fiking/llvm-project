# §2 NVPTX 宏观架构深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，本仓库工作区实测（build-debug, nvptx64）。
> 引用格式 `文件:行号`；实测素材 `/tmp/np.ll`、`/tmp/cluster4.ll`。
> 素材来源：子代理调研（30 次调用后 API 超时死亡，transcript 素材已回收）+ 主会话补验证代写。
> 对照阅读：nvptx-vs-amdgpu-analysis.md §2/§5.1/§10（已覆盖部分引用不重复）。

---

## 2.1 target 注册：双名双宽

- **nvptx / nvptx64** 双注册（32/64 位地址空间），TargetInfo 注册点 `NVPTXTargetInfo.cpp`（对照 AMDGPU 三名 amdgcn/amdgpu/r600——历史分层不同：NVPTX 从未换过名，AMDGPU 经历 r600→amdgcn→amdgpu 演化）
- 实测：`-march=nvptx` 输出 `.address_size 32`，`-march=nvptx64` 输出 `.address_size 64`——**32 位 target 仍在维护**（AMDGPU 的 r600 是遗产，NVPTX 的 nvptx32 是活的低配选项）

## 2.2 384 行 TargetMachine 的极简主义（对照 AMDGPU 2858 行）

- **没做什么**：无函数级 subtarget 缓存（AMDGPU 的 SubtargetKey 机制不存在——NVPTX 一个模块一个 subtarget 就够）；无 ISel 双路径配置（无 GISel）；无 MISchedPostRA/RequiresCodeGenSCCOrder 全局开关
- **新旧 PM 双份维护**：NVPTXTargetMachine.cpp（legacy，含 `createTargetRegisterAllocator(){return nullptr;}` :356-357）+ NVPTXCodeGenPassBuilder.cpp（358 行，新 PM）；同步注释见 §4+§6 素材（03-ra-empty.md）
- 行数对比实锤：AMDGPUTargetMachine.cpp 2858 vs NVPTXTargetMachine.cpp 384 + NVPTXCodeGenPassBuilder.cpp 358 = **742 行做 AMDGPU 一个文件的事还不到 1/4**

## 2.3 PTX ISA × SM 版本矩阵

**数据源不在 .td 而在 TargetParser**：`llvm/lib/TargetParser/NVPTXTargetParser.def`——每 SM 一行五元组：

```
NVPTX_GPU("sm_32", SM_32_, "compute_32", 320, CUDA_70,  CUDA_102, NONE)
NVPTX_GPU("sm_35", SM_35,  "compute_35", 350, CUDA_70,  CUDA_118, NONE)
NVPTX_GPU("sm_80", SM_80,  "compute_80", 800, CUDA_110, NEW,      NONE)
NVPTX_GPU("sm_88", SM_88,  "compute_88", 880, CUDA_130, NEW,      NONE)
...
```
字段：`(名字, 枚举, compute_ 名, sm 数值, 最早 CUDA 版, 最晚 CUDA 版, family)`。注意 `SM_32_` 尾下划线——**躲 AIX sys/mac.h 宏冲突**（:32 注释）。

**PTX 版本映射实测**（.version 头部生成）：
| -mcpu | .version | 说明 |
|---|---|---|
| sm_52 | 4.1 | Maxwell |
| sm_90 | 7.8 | Hopper |
| sm_120 | 8.7 | 最新代 |

**驱动协商的本质**：.target sm_90 声明最低硬件；.version 是"这份 PTX 用到的语法版本"——ptxas 拿两者做兼容检查，JIT 路径下驱动还能往高 sm 编译（forward compat 是 PTX 文本接口独有的红利，ELF 二进制没有）。

**PTX/SM 复合谓词**（NVPTXInstrInfo.td，transcript 核实）：
```
def hasCpAsyncBulkRelaxedSupport : PredAnd<[PTX93, PredOr<[SM90a, SM100f, SM110f]>]>;  (:218)
def hasCpAsyncBulkOOBSupport : PredAnd<[PTX92, SM90]>;                                 (:221)
```
**双轴 gate**：一个特性 = PTX 版本 × SM 家族的笛卡尔积子集——"指令存在性"由 ISA 文本版本和硬件代共同决定，这正是虚拟 ISA 的版本复杂度形态（AMDGPU 只有 gfx 代单轴）。

## 2.4 SMVersions 元编程 vs GCNProcessors 平铺

（深化 nvptx-vs-amdgpu §10 已有描述）

- NVPTX.td `SMVersions = [20,21,30,...,90,100,103,107,110,120,121]` 一行 foreach 生成全部基线（:86-100）；`SMFamilies` 生成 f/a 家族变体；sm_90a 单列；sm_101→sm_110 用 ProcessorAlias 处理 PTX 版本改名（:122-124）
- 对照 GCNProcessors.td 62 个 def + 18 个 alias 平铺
- **风格差异的根源**：NVPTX 的 sm 链是**纯数值递进**（同构可 foreach）；GCN 链有架构分叉（gfx90a 的 MAI、gfx1100 的 VOPD——feature 集合异质，平铺更显式）。**元编程适合同质长尾，平铺适合异质分叉**——昇腾 davinci 型号裂变（m200/m300 若 feature 同构）适合 foreach 模式

## 2.5 特性 gate 机制

- `NVPTXSubtarget.h` 的 feature 位 + `hasTargetName()`（:202，§3 NVVMReflect 门控用）+ `getTargetName()`（:205，`.target` 头部来源）
- **实测 SM90 cluster gate**（AsmPrinter.cpp:997-1015 源码路径 + 双 mcpu 实证）：
```bash
# /tmp/cluster4.ll = ptx_kernel + "nvvm.cluster_dim"="2,1,1"
$ llc -mcpu=sm_90  → 输出 ".explicitcluster\n.reqnctapercluster 2, 1, 1"  ✓
$ llc -mcpu=sm_80  → 输出 0 行（gate 生效，无 cluster 指令）             ✓
```
属性链：`NVVMAttributes.h:23` `"nvvm.cluster_dim"` fn attr → `NVVMProperties.cpp:254` getClusterDim → AsmPrinter `STI->hasFeature(NVPTX::SM90)` 才发射。**feature gate 的三层结构：fn attr（用户意图）→ 属性解析（统一入口）→ subtarget feature（硬件能力）——能力不足时静默丢弃，不报错**（这与 AMDGPU 的 assert 模式相反，ptxas 模式的"宽松契约"体现）。

## 2.6 ISel 层的版本 gate（transcript 素材）

NVPTXISelLowering.cpp（transcript 核实行号）：
```
:990  if (!STI.hasFeature(NVPTX::SM80) || !STI.hasFeature(NVPTX::PTX71))
        setOperationAction(ISD::BF16_TO_FP, MVT::f32, Expand);
:993  if (!STI.hasFeature(NVPTX::SM90))
        for (MVT VT : {bf16, f32, f64}) setOperationAction(ISD::FP_EXTEND..., Expand);
```
**旧硬件上新类型 Expand 成软件序列**——虚拟 ISA 后端的"新特性"就是在 ISelLowering 加一行 gate + 新 PTX 指令的 pattern，不需要全套 MC/RA/hazard 配套（AMDGPU 每个新 feature 都是几十个文件的工程）。

## 2.7 昇腾映射（推理级，待验证）

1. **闭源后端吃 LLVM IR 的接口面**：CANN（LLVM fork→davinci）与 NVPTX→ptxas 同构——LLVM 侧薄、下游黑盒。接口面的最小集：target triple + subtarget feature + 版本头（CANN 的 `__CCE_AICORE__` 系列对应 `__CUDA_ARCH` 协商）。**差异**：NVIDIA 开放了 PTX ISA 文档（黑盒有公开契约），CANN 连中间表示都不公开——比 NVPTX 模式更封闭
2. **双轴 gate 的借鉴**：`PTX 版本 × SM 代` 复合谓词对应昇腾 `CCE 版本 × AICore 代`——若 davinci 指令集随 CANN 版本演进（如 m200 新指令需特定 CCE），双轴 PredAnd 是现成建模
3. **静默 gate vs assert gate**：NVPTX 能力不足静默丢弃（用户困惑"为何没生成"），AMDGPU 断言炸（用户立刻知道）。PyPTO 对 tile 资源不足的选择：**建议 assert 模式**（tile 放不下就报错，别静默回退到慢路径）

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| llvm/lib/TargetParser/NVPTXTargetParser.def:32-48+ | SM 五元组矩阵 |
| NVPTX.td:86-100, 122-124 | SMVersions foreach + ProcessorAlias |
| NVPTXInstrInfo.td:218-221 | PTX/SM 复合谓词 |
| NVPTXSubtarget.h:191, 200-205 | feature 位 + hasTargetName/getTargetName |
| NVPTXISelLowering.cpp:990-995 | ISel 版本 gate |
| NVPTXAsmPrinter.cpp:997-1015 | SM90 cluster 发射 |
| NVVMProperties.h:48 / NVVMProperties.cpp:254-255, 274-279 | cluster 属性解析 |
| include/llvm/Support/NVVMAttributes.h:23-25 | fn attr 常量 |
| NVPTXTargetMachine.cpp:356-357 | legacy 空 allocator |

实测素材：/tmp/np.ll（三 mcpu 版本头 diff：4.1/7.8/8.7）、/tmp/cluster4.ll（sm_90 vs sm_80 cluster gate）、nvptx32/nvptx64 address_size 对照。
