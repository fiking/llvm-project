# §3 NVPTX IR 层 pass 群 + 血统学深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，本仓库工作区实测（build-debug, nvptx64, sm_90, O2）。
> 引用格式 `文件:行号`；实测素材 `NVPTX-notes/scratch/reflect_test.ll` + `pipe_log.txt`。
> 素材来源：子代理调研（引用已核实，血统学 git 考古到 commit 级）+ 主会话动态验证代写。
> 对照阅读：AMDGPU-notes/02-ir-layer.md。

**先修正三处锚点/误称**（子代理核实）：
1. NVPTXISelLowering.cpp:321-327 是 ComputePTXValueVTs 的 i8 处理，**不是** AS 定义；正确锚点 `include/llvm/Support/NVPTXAddrSpace.h:22-30`
2. GenericToNVVM 当前版本已无 nvvm.ld/st/ctlz 方言翻译（历史功能）；现在只做 AS0→AS1 全局克隆
3. AMDGPU-notes/02-ir-layer.md §4.1 不含四件套内容（血统证据在两 target 源码+git 史）

---

## 3.1 NVVMReflect：编译期架构协商

**DEBUG_TYPE** = `nvvm-reflect`（NVVMReflect.cpp:45）。三个入口：`__nvvm_reflect`(:47)、`__nvvm_reflect_ocl`(:48)、`llvm.nvvm.reflect` intrinsic（runOnModule :220-223）。

**求值链**：
```
构造: ReflectMap{"__CUDA_ARCH": SmVersion*10}(:68-69)
  → populateReflectMap 叠加模块旗标 nvvm-reflect-ftz → __CUDA_FTZ(:107-110)
  → 叠加 -nvvm-reflect-add name=<int>（最后写入者胜，:96-126）
handleReflectFunction(:132-187):
  断言 reflect 函数无函数体(:136) / 参数必须是常量 C 字符串(:154-169)
  / 查表默认 0(:172-174) / ConstantInt RAUW + eraseFromParent，连函数声明一起删(:185)
级联折叠 foldReflectCall(:189-213): ConstantFoldInstruction + ConstantFoldTerminator
  —— 死分支此时折叠，simplifycfg 收尾
```

**防御性双跑**：pipeline-start EP（NVPTXCodeGenPassBuilder.cpp:325-339）`if (Subtarget.hasTargetName())` 才加——注释"用户还没给目标架构时不想过早折叠"；addIRPasses 再跑一次（:178-183，"hopefully running it here does nothing...run it here too, in case whoever built our pass pipeline didn't add it"）。
**血统**：`29b5c18e466c`（2025-01-07，#121834）引入 hasTargetName 门控（修复 OpenMP/libc 无架构 IR 被错误折叠）；双跑防御 `65f31e567b71`（2026-08-17，#215712 NewPM codegen pipeline）。

**头注释 :12-15 已过时**：称 InstCombineCall 依赖可预测取值——现代挂钩实际在 TargetLibraryInfo.cpp:859-873（`T.isNVPTX()` 时 TLI 仅放行 `LibFunc_nvvm_reflect`+malloc/free）+ BuildLibCalls.cpp:1251-1256（加 doesNotAccessMemory/nothrow）。grep InstCombineCalls.cpp 现无 nvvm 引用。

**libdevice 协商**：libdevice.bc 内嵌 `__nvvm_reflect("__CUDA_ARCH")` 调用点（clang/lib/Headers/nvptxintrin.h:201 有真实样例）；clang 侧 CodeGenModule.cpp:1807 写入 `nvvm-reflect-ftz` 模块旗标。

### 动态验证（实测，reflect_test.ll）

```bash
# sm_90：__CUDA_ARCH=900 ≥ 900 → new 分支保留、old 分支折叠删除
$ llc -march=nvptx64 -mcpu=sm_90 -print-after=nvvm-reflect reflect_test.ll
entry:
  br label %new          ← %c 已折叠为常量，直接跳 new
new:
  %a = add i32 %x, 100

# sm_35：__CUDA_ARCH=350 < 900 → old 分支
$ llc -march=nvptx64 -mcpu=sm_35 -print-after=nvvm-reflect reflect_test.ll
entry:
  br label %old          ← 反向折叠
```
**编译期架构协商双分支折叠实测捕捉**——这就是 libdevice 同一份 .bc 服务全 sm 代的机制。

## 3.2 GenericToNVVM（NVPTXGenericToNVVM.cpp，297 行）——历史包袱的瘦身

**当前 main 只做一件事**：AS0 全局变量克隆为 AS1(global) + 使用点改走 `addrspacecast global→generic`（:52-70 建 GVMap，:151-153 插 cast）；全局初始化器用 bitcast（**cvta 不能出现在初始化器**，:105-126）；常量聚合/ConstantExpr 重建为指令（:170-266）。

grep 证实当前文件已无 nvvm.ld/st/ctlz 方言翻译——任务书里的"generic 方言翻译"是历史功能。起源 commit `01f89f042801`（2013-05-20，Holewinski，"better handle idiomatic LLVM IR inputs"，动机：AS0 全局变量非法因为不能在 generic 空间声明变量）。

## 3.3 LowerArgs（NVPTXLowerArgs.cpp，479 行）：byval 参数三策略

文件头 :9-42：**param space 只读、仅 ld.param 可访问**。三策略：
1. 全使用可追迹且只读 → 直接改写为 param AS（pre-SM70 无 cvta.param 时有用）
2. grid-constant + 有 cvta.param → cast 回 generic 直接用
3. 兜底 local 拷贝

`ArgUseChecker`(:178-251, PtrUseVisitor)：存指针=逃逸、写所指内存/memset/memcpy 目的端=需拷贝。`copyByValParam`(:258-284)：alloca+memcpy，writeonly/readnone 跳过拷入(:274-276)。`rewriteKernelByValSignature`(:370-418)：签名改写为 `ptr addrspace(101)` + markArgNonWritable(:354-365)。幂等检查 :290-295。

**昂贵拷贝的摆位注释**（NVPTXCodeGenPassBuilder.cpp:61-82）："local copies are very expensive, and we create them very late...let them percolate through the optimizations...disabled by default" → `nvptx-early-byval-copy`（默认 false）→ NVPTXCopyByValArgsPass 挂 pipeline-start EP（:336-337），实现在 NVPTXLowerArgs.cpp:454-472。摆位："必须正确性、紧贴 AS 推断之前"（:194-195）。

## 3.4 强度削减四件套血统学（本章核心考古）

**当前 NVPTX**（:157-173）：SeparateConstOffsetFromGEP → **SpeculativeExecution**(:160，AMDGPU 无此项) → SLSR → EarlyCSE/GVN（Aggressive 用 GVN 且关 scalar PRE，:135-141）→ NaryReassociate → EarlyCSE。排序理由注释 :161-171。

**血统链（全部 git log/show 核实）**：
| pass | NVPTX 起源 | 备注 |
|---|---|---|
| SeparateConstOffsetFromGEP | `a108a65df271`（2014-05-01，Bendersky/Wu，D3462） | "currently only enabled for the NVPTX backend" |
| SLSR | `d7966ff3b948`（2015-02-03，Jingyue Wu） | 同 commit 即在 NVPTXTargetMachine 启用 |
| NaryReassociate | `8cb6b2a292ea`（2015-04-14，D8950）通用 pass | NVPTX 启用 `3daace5295fc`（2015-04-24），revert/resurrect `62af99b`/`72fca6c`，EarlyCSE 善后 `c2a014697a6a`（2015-05-28） |
| 聚合为 addStraightLineScalarOptimizationPasses | `f650441b0406`（2016-02-04，Wu） | "Disable performance optimizations when OptLevel==None" |

**AMDGPU 移植：`f42c69206d6b`（2016-06-15，Matt Arsenault）"AMDGPU: Run pointer optimization passes"——从 NVPTX 逐字复制两个函数**（diff 含相同注释及相同拼写错误 "opportunites"）。今日两侧仍近乎逐字相同（NVPTXCodeGenPassBuilder.cpp:157-173 vs AMDGPUTargetMachine.cpp:1548-1563；AMDGPU 多 LoopDataPrefetch@Aggressive、少 SpeculativeExecution）。

**血统学结论**：这组 GPU 指针优化是 NVPTX 先跑通（2014-2016）、AMDGPU 整体搬走（2016）的**单向传播**——"GPU 后端的通用 IR 优化起源于第一个吃螃蟹的虚拟 ISA 后端"。

## 3.5 InferAddressSpaces + AS 模型

**正确 AS 定义**：`include/llvm/Support/NVPTXAddrSpace.h:22-30`——GENERIC=0, GLOBAL=1, SHARED=3, CONST=4, LOCAL=5, TENSOR=6, SHARED_CLUSTER=7（七类）+ ENTRY_PARAM=101。

NVPTX 无自研推断 pass，用通用 InferAddressSpaces.cpp + TTI 钩子（NVPTXTargetTransformInfo.cpp）：
- collectFlatAddressOperands（:548-560）：isspacep 系 + prefetch_tensormap
- rewriteIntrinsicWithAddressSpace（:564-585）：isspacep 常量折叠
- **getAssumedAddrSpace（:638-660）**：alloca→LOCAL；kernel 非 byval 参数（CUDA 接口）→GLOBAL；非 kernel byval 参数→LOCAL（注释：ISel 后简单情形才升 param 空间）；否则 -1

管线（:143-155）：SROA→LowerAlloca→InferAddressSpaces（:151-152 TODO"考虑提前到 opt 期"）→AtomicLower。**AMDGPU 侧同 pass 挂 4+ 处，NVPTX 恰一次**——推断需求量差的直接体现。

## 3.6 其余 pass 功能卡（头注释均已读）

| pass | 核心 | 引用 |
|---|---|---|
| AssignValidGlobalNames | ptxas 比 MC 更严的符号字符；只改 local 链接 + extern shared | :11-45 |
| MarkKernelPtrsGlobal | byval 参数中读出的指针必为 global，插 ASC 对供推断；处理 inttoptr；仅 CUDA 驱动接口 | :9-17, :60-88；PassBuilder :196-199 |
| PromoteParamAlign | byval 显式 align；全直调本地函数 stackalign≥16 镜像到调用点；向已知偏移 byval load 传播 | :9-33, :87-105, :180+ |
| LowerAlloca | AS0→AS5+cast 回 generic；optnone 也强制跑；靠 InferAddressSpaces 事后折叠出 st.local | :9-24, :46-48 |
| AtomicLower | LOCAL AS 的 AtomicRMW 降为普通 load/store（线程私有） | :22-38 |
| ImageOptimizer | istypep(sampler/surface/texture) 依 PTX opaque 类型常量化 + 穷人 DCE | :9-50；:185-186 |
| TagInvariantLoads | global AS load 且底层对象为常量 GV / noalias 只读 kernel 参数 / grid-constant → 打 MD_invariant_load；getUnderlyingObjects 穿 phi | :9-58 |
| IRPeephole | contract 旗标下 FMUL+FADD/FSUB→llvm.fma 六模式，ISel 前最后一跑 | :9-27 |
| **LowerUnreachable** | **ptxas WAR 活样本**：ptxas 给无终结块造假 CFG 边→放大发散区→bar.sync 非法发散（Pascal-）；WAR=unreachable 前插 inline asm `exit;`（trap 已含则跳过）；门控 `hasPTXASUnreachableBug() = !hasFeature(PTX83)`（NVPTXSubtarget.h:191，**PTX 8.3 修复**）；PassBuilder :240-246 直接引用 bug commit `1ee4d880e8760256c606fe55b7af85a4f70d006`（2023-06-20，Besard）；`d832a1c744fd`（2024-10-10）加必要门控 | :9-65, :107-131 |

LowerUnreachable 是三案例 WAR 里证据链最完整的：**bug commit 号写进源码注释 + 版本门控 + 修复版本号**——ptxas 黑盒缺陷在 LLVM 侧的"化石层"。

## 3.7 动态验证汇总

- NVVMReflect：见 §3.1（sm_90/sm_35 双分支折叠实测）
- 完整 IR 层序列：scratch/pipe_log.txt 实测 23 个 IR dump（nvvm-reflect → assign-valid-global-names → generic-to-nvvm → mark-kernel-ptrs-global → promote-param-align → lower-args → sroa → lower-alloca → infer-address-spaces → atomic-lower → separate-const-offset-from-gep → speculative-execution → slsr → early-cse → nary-reassociate → early-cse → atomic-expand → lower-ctor-dtor → … → load-store-vectorizer → tag-invariant-loads → ir-peephole → lower-unreachable）

## 3.8 昇腾映射（推理级，待验证）

1. **NVVMReflect ↔ CCE 编译期环境协商**：`__CUDA_ARCH` 的"一份 IR 服务全代硬件"模式，昇腾侧等价物是 `__CCE_AICORE__`/`ASCEND_VERSION` 类宏（待验证是否有 reflect 函数级机制）。若 PyPTO 要做"一份 tile 代码适配 m200/m300"，NVVMReflect 的查表+RAUW+级联折叠是现成实现（234 行就能抄）
2. **byval 三策略 ↔ 参数空间决策**：昇腾 kernel 参数走 GM descriptor，"只读可追迹→直接用 / 逃逸→拷贝"的三策略与 PyPTO 参数绑定层同构
3. **血统学教训**：通用 GPU IR 优化会从"第一个跑通的后端"单向扩散——PyPTO 若在某类 tile 优化上先跑通，同样可能被后来者整体搬走；先发优势在于"验证过的模式"

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| NVVMReflect.cpp:12-15, 45-48, 68-69, 96-126, 107-110, 132-187, 189-213, 220-223 | 求值机制 |
| NVPTXCodeGenPassBuilder.cpp:61-82, 135-141, 143-155, 157-173, 178-183, 185-186, 194-199, 240-246, 325-339, 336-337 | 管线挂点 |
| TargetLibraryInfo.cpp:859-873 / BuildLibCalls.cpp:1251-1256 | TLI 挂钩（头注释过时的修正） |
| clang/lib/Headers/nvptxintrin.h:201 / clang CodeGenModule.cpp:1807 | libdevice 协商 |
| NVPTXGenericToNVVM.cpp:52-70, 105-126, 151-153, 170-266 | AS0→AS1 |
| NVPTXLowerArgs.cpp:9-42, 178-251, 258-284, 290-295, 354-365, 370-418, 454-472 | byval 三策略 |
| NVPTXAddrSpace.h:22-30 | AS 七类（正确锚点） |
| NVPTXTargetTransformInfo.cpp:548-585, 638-660 | 推断钩子 |
| 各 pass 文件（见 §3.6 表） | 功能卡 |
| NVPTXSubtarget.h:191 | hasPTXASUnreachableBug |
| git: 01f89f042801 / a108a65df271 / d7966ff3b948 / 8cb6b2a292ea / 3daace5295fc / c2a014697a6a / f650441b0406 / **f42c69206d6b** / 29b5c18e466c / 65f31e567b71 / 1ee4d880e876... / d832a1c744fd | 血统考古 |

实测素材：scratch/reflect_test.ll（NVVMReflect 双分支折叠）、pipe_log.txt（23 个 IR dump 序列）。
