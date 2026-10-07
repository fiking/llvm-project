# §7 NVPTX 下游生态（ptxas/fatbinary/wrapper/reflect 镜像）深度分析

> 基准：llvm-project main @ `3eda2aebadd4`，本仓库工作区实测（build-debug/clang-24, sm_70）。
> 引用格式 `文件:行号`；实测素材 `NVPTX-notes/scratch/minimal.cu`（-### 完整工具链序列）。
> 素材来源：子代理调研（引用已核实）+ 主会话 -### 实测代写。
> 环境注：本地无 ptxas/nvcc/fatbinary（-### 只打印不执行，无 toolkit 也能出命令行——实测已证）。

---

## 7.1 ptxas→cubin→fatbinary 完整链路

**工具链调用序列**（clang -### 实测，minimal.cu，sm_70）：
```
① clang-24 -cc1 -triple nvptx64-nvidia-cuda -fcuda-is-device
   -target-cpu sm_70 -D__CUDA_ARCH_LIST__=700
   -o minimal-sm_70-a0626e.s -x cuda minimal.cu        ← LLVM 出 PTX 文本
② ptxas -m64 -O0 --gpu-name sm_70
   --output-file minimal-sm_70-2fd116.o
   minimal-sm_70-a0626e.s                               ← ptxas 出 cubin
③ fatbinary --cuda -64 --create minimal-cb93ac.fatbin
   --image3=kind=elf,sm=70,file=minimal-sm_70-2fd116.o  ← 打包（仅 elf！）
④ clang-24 -cc1 -triple arm64-apple-macosx（host）
   -foffload-include-binary minimal-cb93ac.fatbin
   -o minimal.o -x cuda minimal.cu                      ← host 嵌入 fatbin
```

**Driver 源码链**：
- ptxas 调用 `Cuda.cpp:398-524`（NVPTX::Assembler）：`-O` 映射表 :444-473（**无 -O 时传 -O0，因 ptxas 默认 -O3**）、debug 三级 :379-396、`-Xcuda_ptxas` 透传 :493-494、relocatable 判定 :496-509（OpenMP 默认 true / CUDA 仅 `-fgpu-rdc`）→ ptxas `-c`
- fatbinary 调用 `Cuda.cpp:545-591`：`--image3=kind={ptx|elf},sm=...,file=` :573-579
- **JIT fallback 开关：shouldIncludePTX :526-540 默认 false**——默认 fatbin 只装 cubin，PTX 仅 `--cuda-include-ptx=all|arch` 时加入（Options.td:1403-1408）。**实测印证：-### 输出仅 `kind=elf`，无 kind=ptx**
- Driver 图构建 `Driver.cpp:4286-4295`：非 RDC → `LinkJobAction(TY_CUDA_FATBIN)` 直接出 fatbin 不链接；`:4251-4255` 注释明说 LLVM offload 路径**丢 PTX**（"clang-nvlink-wrapper does not accept PTX as input"）
- -nocudainc/-nocudalib 真身：`Options.td:6624/6636`——分别是 `--no-offload-inc`/`--no-offloadlib` 别名；前者砍 `__clang_cuda_runtime_wrapper.h` -include（Cuda.cpp:304-331），后者砍 `-mlink-builtin-bitcode libdevice.10.bc`（Cuda.cpp:922-940）

**host 嵌入**（`Clang.cpp:8337-8352` + `CGCUDANV.cpp:820-1108`）：`.nv_fatbin`(align 8) / `.nvFatBinSegment` wrapper（"cuobjdump looks for fatbins here" :944）；`CudaFatMagic=0x466243b1`（:40，device-stub.cu:143 十进制 1180844977 互证）；ctor 链 `__cudaRegisterFatBinary→__cuda_register_globals→__cudaRegisterFatBinaryEnd`（:1034-1056）；RDC 走 MD5 ModuleID + `__cudaRegisterLinkedBinary%ModuleID%`（:1060-1089）；dtor atexit（:1092-1098，CUDA 9.2 double-free 注释）。

## 7.2 双 wrapper 分工

**clang-nvlink-wrapper**（838 行，头注释 :11-14 自述"补 nvlink 缺 LTO/归档之短，NVIDIA 改进或移植 ld.lld 后可删"——**自认临时物**）：
- `hasFatBinary` :158-169：host ELF 且 arch≠nvptx → 原样透传（**device 符号解析 vs fatbin 透传的分流点**）
- 归档 lazy 抽取 :594-605；LTO :344-436（Triple 硬编码 nvptx64、CGFileType=Assembly→PTX），**LTO 产物由 wrapper 自己调 ptxas**（runPTXAs :331-386）
- nvlink 要求输入必须 .cubin 后缀故临时拷贝（:712-721）
- 驱动侧入口 `Cuda.cpp:593-690`（转发 `--plugin-opt=-mattr=` :659-664）

**clang-linker-wrapper**（1623 行）：host 链接命令整体替换（`Clang.cpp:9731+`，`--linker-path=` 携带原命令）；NVPTX 设备链接经 generic::clang → `clang --offload-link --target=nvptx64...`（:605-618, :485-528）回落 nvlink-wrapper；NVPTX 跳过 `--no-undefined`(:528-529)；打包用 NVIDIA fatbinary 但 **kind=elf only**（nvptx::fatbinary :391-422，**对比 AMDGPU 走 clang-offload-bundler -bundle-align=4096**）；嵌入复用 `llvm/lib/Frontend/Offloading/OffloadWrapper.cpp`（createFatbinDesc :275-310，与 CGCUDANV 同 magic/同 section 的 IR 级镜像）。

## 7.3 lld 无 PTX：架构性缺席（已证实）

- `ls lld/ELF/Arch/` = 18 文件**无 NVPTX**；`grep -rn nvptx lld/` 零命中
- **反证链**：EM_CUDA=190 存在于 LLVM object 层（ELF.h:291、ELFObjectFile.h:1432、llvm-gpu-loader.cpp:222 可执行 CUDA ELF）——**读侧支持有、链接侧没有**；PTX 无二进制重定位模型（lld/ELF/Arch/*.cpp 全部围绕 relocation 接口），**SASS 重定位语义 NVIDIA 未公开 → nvlink 垄断**

## 7.4 NVVMReflect host 镜像：否定性结论

- `grep -rln NVVMReflect llvm/lib/` → **仅 NVPTX 六个文件**，LTO/Linker/host 路径零引用——**不存在 host 端求值镜像**
- nvptxintrin.h 三重门卫：`#ifndef __NVPTX__ #error`(:15-17)、`__GPUINTRIN_H` 门(:19-21)、`omp declare target device_type(nohost)` + `variant match(arch(nvptx64))`(:24-25)——`__gpu_thread_suspend` 里的 `__nvvm_reflect("__CUDA_ARCH")`(:201) **根本到不了 host 编译**
- CodeGenModule.cpp:1802-1810 的 `nvvm-reflect-ftz` 旗标被 `CUDAIsDevice && isNVPTX()` 双门控；TLI 挂钩（TargetLibraryInfo.cpp:859-873）同样 `T.isNVPTX()` 门控

**libdevice 版本协商全景**：CUDA 9+ 单一 `libdevice.10.bc` 服务全 sm（Cuda.cpp:238-248，NVPTXTargetParser.def 循环 SM_ID≥300）；pre-9 多文件"peculiar"映射 :249-292；SDK 版本→`+ptx` 特性表 :707-747（NEW→+ptx86）。**一份 .bc 多代服务的机制 = `-mlink-builtin-bitcode` 内化 + 后端 NVVMReflect 按 SmVersion 折叠**（02-ir-layer §3.1 已实测双分支，直接引用）。

## 7.5 昇腾映射（推理级，待验证）

1. **链路对应**：CANN 的 tee 算子编译（LLVM→davinci .o）→ atc 图编译（.o→om）≈ PTX→cubin→fatbin 链，但**昇腾多一层"图编译"**（atc 做 tiling/调度决策，NVIDIA 链没有图级编译器）——职责切分不同
2. **fatbinary 双版本（PTX+SASS）↔ 多 chip 二进制**：`--cuda-include-ptx` 的 JIT fallback 让同一 fatbin 前向兼容未来 GPU；昇腾 om 按 chip 形态打多份二进制是**后向兼容**（每形态一份），**没有等价的"中间表示前向兼容"**——若 CANN 开放 davinci 中间表示（类 PTX），可获得同样的前向兼容红利，但代价是文档化并冻结该表示
3. **"丢 PTX"决策的教训**：LLVM offload 路径连自己的 PTX 都丢（nvlink-wrapper 不收 PTX）——**中间表示的消费者生态比中间表示本身更重要**；PyPTO 的 pto-isa 若只有 CPU 模拟器一个消费者，等价于"有 PTX 无 ptxas 生态"

---

## 引用清单（供抽查）

| 引用 | 内容 |
|---|---|
| clang/lib/Driver/ToolChains/Cuda.cpp:238-292, 304-331, 379-396, 398-524, 444-473, 493-509, 526-591, 593-690, 707-747, 922-940 | ptxas/fatbinary/nvlink 驱动 |
| clang/lib/Driver/Driver.cpp:4251-4255, 4286-4295 | 图构建与丢 PTX 注释 |
| clang/lib/Driver/Options.td:6624, 6636, 1403-1408, 1857 | 选项真身 |
| clang/lib/CodeGen/CGCUDANV.cpp:40, 820-1108, 944, 1034-1098 | host 嵌入 |
| clang/lib/Driver/ToolChains/Clang.cpp:8337-8352, 9731+ | 嵌入/链接替换 |
| clang/tools/clang-linker-wrapper：:391-422, 485-529, 605-618 | linker-wrapper |
| clang/tools/clang-nvlink-wrapper：:11-14, 158-169, 331-436, 594-605, 712-721 | nvlink-wrapper |
| lld/ELF/Arch/（18 文件无 NVPTX）/ ELF.h:291 / ELFObjectFile.h:1432 / llvm-gpu-loader.cpp:222 | lld 缺席反证 |
| llvm/lib/Frontend/Offloading/OffloadWrapper.cpp:275-310 | IR 级嵌入镜像 |
| clang/lib/Headers/nvptxintrin.h:15-25, 201 / clang CodeGenModule.cpp:1802-1810 / TargetLibraryInfo.cpp:859-873 | reflect host 门卫 |

实测素材：scratch/minimal.cu（-### 四阶段完整命令行：cc1-nvptx64 → ptxas → fatbinary --image3=kind=elf → cc1-host -foffload-include-binary）。
