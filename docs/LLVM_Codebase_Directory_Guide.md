# LLVM 代码目录介绍

> 本文基于本仓库实际 checkout 撰写,面向需要在 LLVM monorepo 里找代码、改代码的工程师。
> 覆盖两层内容:monorepo 顶层各子项目,以及核心 `llvm/` 子树的详细结构。

---

## 1. Monorepo 顶层布局

LLVM 采用 monorepo 模式,所有子项目在同一个 git 仓库里,通过 CMake 的
`LLVM_ENABLE_PROJECTS` 选择性构建。

```
llvm-project/
├── llvm/                # 核心:IR、优化、代码生成、工具链(本文重点)
├── clang/               # C/C++/ObjC 编译器前端
├── clang-tools-extra/   # clangd、clang-tidy、clang-format 等工具
├── flang/               # Fortran 前端
├── mlir/                # Multi-level IR 基础设施
├── lld/                 # 链接器(ELF/MachO/COFF/Wasm 四套后端)
├── lldb/                # 调试器
├── compiler-rt/         # 运行时:sanitizer、builtins、profile 等
├── libc/                # LLVM 自研 C 标准库
├── libclc/              # OpenCL runtime 库(带 IR)
├── libcxx/              # libc++ C++ 标准库
├── libcxxabi/           # C++ ABI(ITU)实现
├── libunwind/           # 栈回溯/unwind 库
├── llvm-libgcc/         # libgcc_s 兼容层(转发到 libunwind)
├── openmp/              # OpenMP runtime(含 offloading)
├── offload/             # GPU offloading runtime(libomptarget 拆分)
├── polly/               # 多面体优化(polly pass + ISL)
├── bolt/                # post-link 二进制优化器
├── pstl/                # 并行 STL(现归 Intel 维护,仅剩接口)
├── cross-project-tests/ # 跨子项目集成测试
├── runtimes/            # "runtimes" 构建模式:引导编译 libcxx 等的伞形 CMake
├── third-party/         # google benchmark 等第三方库
├── cmake/               # 各子项目共享的 CMake 模块
└── utils/               # bazel 等顶层辅助脚本
```

**本机工作区备注**:仓库根目录下的 `build-shared/` 是本机的构建目录,`build.sh`
是本地构建脚本;根目录下若干 `*_Analysis.md`、`test5.ll`、`out.ll` 等是本地
进行中的分析文档与测试产物,不属于上游结构。

各子项目关系一览:

```text
      clang ──────┐
       flang ─────┤  前端,产出 LLVM IR(bitcode)
       mlir ──────┘
                    ↓
                  llvm  ← opt(优化)/ llc(代码生成)/ 各类工具
                    ↓
     ┌── lld(链接)──→ 可执行文件 ──→ bolt(post-link 优化)
     ├── compiler-rt / libc / libcxx / openmp(运行时,链接进产物)
     └── lldb(调试,同时消费 LLVM 的 DWARF/反汇编能力)
```

---

## 2. `llvm/` 子树总览

```
llvm/
├── CMakeLists.txt   # 本子项目入口
├── include/llvm/    # 所有公开头文件,按模块分目录
├── lib/             # 对应实现,目录结构与 include 一一对应
├── tools/           # 可执行工具,一目录一工具
├── test/            # regression 测试(lit + FileCheck)
├── unittests/       # gtest 单元测试
├── docs/            # Sphinx 文档(LangRef.rst 是 IR 规范)
├── examples/        # 入门示例(Kaleidoscope 教程、JIT 示例等)
├── utils/           # 开发脚本(update_test_checks.py、vim 语法等)
├── bindings/        # OCaml 绑定
├── cmake/           # 本子项目的 cmake 模块
├── projects/        # 旧式外部项目挂载点(已基本废弃)
├── runtimes/        # runtimes 模式入口(指向顶层 ../runtimes)
└── benchmarks/      # micro-benchmark
```

### include / lib 双层结构

这是找代码的第一规律:**头文件在 `include/llvm/<模块>/`,实现在 `lib/<模块>/`,
目录名完全对应**。例如 `llvm/include/llvm/IR/Function.h` 对应 `llvm/lib/IR/Function.cpp`。

另一个关键点:一部分头文件是 **TableGen 生成的**,不在这两个目录里,而在构建
目录中。最典型的:

- `llvm/include/llvm/IR/Intrinsics.td` → 构建目录生成 `include/llvm/IR/Intrinsics.h`、`IntrinsicsX86.h` 等
- `llvm/lib/Target/X86/X86.td` 等描述文件 → 生成 `X86GenInstrInfo.inc`、`X86GenRegisterInfo.inc` 等

这也解释了为什么改动一个 `.td` 文件会触发大量重编译——生成的 `.inc` 被整个
target 的源文件包含。

---

## 3. `llvm/lib/` 各模块详解

### 3.1 IR 层(`lib/IR`)

LLVM IR 的核心数据结构全在这里:

- `Module.cpp` / `Function.cpp` / `BasicBlock.cpp` / `Instruction.cpp` / `Constants.cpp` / `Value.cpp`
  —— IR 的核心类体系。`Value` 是一切可被 use 的东西的基类(use-def 链)
- `Verifier.cpp` —— IR 合法性检查(`opt -verify`、debug 构建下 pass 间自动跑)
- `IntrinsicInst.cpp` —— intrinsic 的 IR 层封装
- `DataLayout.cpp` —— 目标数据布局(类型大小、对齐、端序)
- `Type.cpp` / `DerivedTypes.cpp` —— 类型系统
- `Attributes.cpp` / `Metadata.cpp` —— 属性与元数据
- `AutoUpgrade.cpp` —— 旧 bitcode 里过时 intrinsic 的升级逻辑
- `SafepointIRVerifier.cpp` —— GC statepoint 相关的验证(与本仓库在做的 GC 工作相关)

配套模块:

| 目录 | 作用 |
|---|---|
| `lib/AsmParser` | `.ll` 文本 IR 的 parser(llvm-as 用) |
| `lib/Bitcode` | bitcode 读写(`.bc` 序列化) |
| `lib/IRReader` | 统一入口:自动识别 `.ll` / `.bc` |
| `lib/IRPrinter` | IR 打印逻辑(从 IR 拆出的较新模块) |

### 3.2 分析 pass(`lib/Analysis`)

优化与代码生成都要依赖的基础分析:

- `DominatorTree.cpp`(支配树,支配边界)、`PostDominators.cpp`
- `AliasAnalysis.cpp` + `MemorySSA.cpp`(别名与内存分析)
- `ScalarEvolution.cpp`(标量演化,循环分析核心)
- `LoopInfo.cpp` / `LoopPass.cpp`(循环信息)
- `CallGraph.cpp` / `ModuleSummaryAnalysis.cpp`(IPO 与 LTO)
- `TargetLibraryInfo.cpp`(libc 函数识别,`TLI`)
- `ValueTracking.cpp`(known bits、isKnownNonZero 等值性质查询,InstCombine 的弹药库)
- `ProfileData/`(库版本,配套工具 `llvm-profdata`)

### 3.3 优化 pass(`lib/Transforms`)

| 目录 | 内容 |
|---|---|
| `InstCombine` | 指令级代数化简,最常用也最大的单个 pass |
| `Scalar` | 标量优化:GVN、LICM、SROA、JumpThreading、LoopRotate 等几十个 |
| `IPO` | 跨函数:inliner、deadarg、globalopt、openmp 相关 |
| `Vectorize` | SLP、LoopVectorizer、VPlan |
| `Coroutines` | C++ 协程 lowering |
| `Instrumentation` | sanitizer 插桩、GC 策略插桩、bounds checking |
| `Utils` | 优化共用的工具(如 `Local.cpp` 的 DCE、`SimplifyIndVar.cpp`) |
| `ObjCARC` | Objective-C ARC 优化 |
| `AggressiveInstCombine` | 更激进(也更贵)的模式化简 |
| `HipStdPar` | HIP 标准并行算法 |

配套的 `lib/Passes` 里有 `PassBuilder.cpp` —— 新 Pass Manager 的优化 pipeline
构建(`-O2` 到底跑哪些 pass 就定义在这),以及 `PassPlugin.cpp`(pass 动态插件)。

### 3.4 代码生成(`lib/CodeGen`)

后端的**公共部分**,与具体 target 无关的算法:

- SelectionDAG:`SelectionDAGISel.cpp`、`SelectionDAG.cpp`、`Legalize*`、`DAGCombiner.cpp`(老式指令选择)
- GlobalISel:`GlobalISel/` 子目录(GISel,较新框架:`IRTranslator`、`Legalizer`、`Localizer`、`Combiner`、`InstructionSelect`)
- 寄存器分配:`RegAllocGreedy.cpp`、`RegAllocFast.cpp`、`LiveIntervals.cpp`、`VirtRegMap.cpp`
- 调度:`MachineScheduler.cpp`、`ScheduleDAGInstrs.cpp`
- `MachineInstr` / `MachineFunction` / `MachineBasicBlock` —— MIR 三件套
- `PrologEpilogInserter.cpp`、`StackSlotColoring.cpp` 等帧管理
- `IfConversion.cpp`、`BranchFolding.cpp`、`TailDuplication.cpp` 等 CFG 优化
- `AsmPrinter/` —— 从 MachineFunction 到 MC 层的桥(DWARF 生成也在这)
- `PBQP/`、`SanitizerCoverage.cpp`、`MachineOutliner.cpp`、`SafeStack.cpp`…

`lib/CodeGenTypes` 与 `lib/CodeGenData` 是较新的模块:前者做 codegen 类型
分派相关,后者是 `.cgd` 代码生成数据(profile 驱动的 codegen)。

### 3.5 各后端(`lib/Target`)

一个 target 一个目录,本 checkout 包含 28 个:AArch64、AMDGPU、ARM、BPF、
Hexagon、LoongArch、Mips、PowerPC、RISCV、SPIRV、SystemZ、VE、WebAssembly、
X86、Xtensa 等。

单个 target 内部的典型布局(以 X86 为例):

```
lib/Target/X86/
├── X86.td / X86Instr*.td / X86RegisterInfo.td   # TableGen 描述:指令、寄存器、调度
├── X86InstrInfo.cpp        # 指令语义与变换(后端最大的一块)
├── X86ISelLowering.cpp     # SelectionDAG lowering/合法化(与目标相关)
├── X86ISelDAGToDAG.cpp     # 模式匹配式指令选择
├── GISel/                  # GlobalISel 路线
├── MCTargetDesc/           # 汇编编码、reloc、object writer
├── AsmParser/  Disassembler/
├── X86FrameLowering.cpp / X86RegisterInfo.cpp / X86Subtarget.cpp
└── X86TargetMachine.cpp    # 目标机关:组装各组件、定义 pipeline
```

**找后端代码的规律**:IR 层概念在前端/优化里怎么叫,到 target 里就变成
`<Target><概念>.cpp`:`FrameLowering`、`RegisterInfo`、`Subtarget`、`InstrInfo`、
`ISelLowering`,每个 target 都有这五件套。

### 3.6 MC 层(`lib/MC`)

汇编与机器码层,`CodeGen` 的下游、object 文件的上游:

- `MCInst` / `MCExpr` / `MCOperand` —— 汇编级指令表示
- `MCStreamer` 家族:`MCObjectStreamer` → `MCELFStreamer` / `MCMachOStreamer` / `MCCOFFStreamer`
- `MCCodeEmitter` / `MCAsmBackend` —— 编码与 fixup
- `MCDisassembler` / `MCInstPrinter` —— 反汇编与打印(llvm-objdump 的基础)
- `MCParser`(llvm-mc 的汇编 parser)、`MCSubtargetInfo`

### 3.7 二进制与对象文件

| 目录 | 作用 |
|---|---|
| `lib/Object` | 统一的对象文件读取:`object::ObjectFile`(ELF/MachO/COFF/archive) |
| `lib/BinaryFormat` | 各格式常量定义(ELF.h、MachO.h…) |
| `lib/ObjCopy` | llvm-objcopy 的库部分 |
| `lib/ObjectYAML` + `lib/TextAPI` | YAML/JSON 形式的对象文件与 TAPI |

### 3.8 基础设施(`lib/Support`)

全 LLVM 的公共库,其中 `include/llvm/ADT/` 是最重要的子集:自定义数据结构
`SmallVector`、`DenseMap`、`StringRef`、`APInt`、`GraphTraits` 等。LLVM 代码
里几乎每个文件都间接依赖它。其余还有 `SourceMgr`、`CommandLine`(cl::opt)、
`Error`(llvm::Error/Expected)、`Debug`、`FileSystem`、`MemoryBuffer`、
`WithColor` 等。

### 3.9 其他库速览

| 目录 | 作用 |
|---|---|
| `lib/Linker` | IR 级模块链接(llvm-link) |
| `lib/LTO` | LTO 库(llvm-lto/thin LTO 后端) |
| `lib/ExecutionEngine` | JIT:MCJIT、ORCv2(`llvm-jitlink`、lli) |
| `lib/TableGen` | TableGen 语言本身的实现 |
| `lib/Demangle` | Itanium/MSVC/Rust/DLang 名字还原 |
| `lib/DebugInfo` | DWARF/CodeView/PDB 解析(llvm-dwarfdump、lldb 共用) |
| `lib/ProfileData` | coverage / PGO profile 读取 |
| `lib/Remarks` | pass remark 序列化(yaml/bitstream) |
| `lib/Frontend` | OpenMP/OpenACC/offloading 的 IR 生成辅助 |
| `lib/SandboxIR` | 实验性沙箱 IR(增量式构建优化 pass 用) |
| `lib/Option` | 命令行选项表(clang driver 用) |
| `lib/FileCheck` | FileCheck 的库化实现 |
| `lib/WindowsDriver` / `lib/WindowsManifest` / `lib/DWP` / `lib/XRay` / `lib/MCA` / `lib/ObjCopy` | 各工具的支撑库 |

---

## 4. `llvm/tools/` 常用工具速查

一目录一工具,源码即 `main.cpp` + 逻辑。最常用的:

**编译流水线类**
- `opt` —— 在 IR 上跑优化 pass(开发 pass 的主战场,`-passes=...`)
- `llc` —— IR → 汇编/目标文件(开发后端的主战场)
- `llvm-as` / `llvm-dis` —— `.ll` ⇄ `.bc` 互转
- `llvm-link` / `llvm-extract` / `llvm-split` —— IR 链接、抽取、切分
- `llvm-lto` / `llvm-lto2` —— LTO 测试

**查看与调试类**
- `llvm-objdump` / `llvm-readobj` / `llvm-nm` / `llvm-size` / `llvm-strings`
- `llvm-dwarfdump` / `llvm-pdbutil` / `llvm-symbolizer` / `llvm-cxxfilt`
- `llvm-bcanalyzer` —— 查看 bitcode 结构
- `llvm-diff` —— IR diff

**测试辅助与缩减类**
- `bugpoint` / `llvm-reduce` —— 自动缩减测试用例(报 bug 必备)
- `FileCheck`(以库形式在 `lib/FileCheck`)、`verify-uselistorder`
- `llvm-stress` —— 随机生成 IR

**分析与性能类**
- `llvm-mc` —— 汇编/反汇编单测工具
- `llvm-mca` —— 静态调度性能分析
- `llvm-exegesis` —— 实测指令延迟/吞吐
- `llvm-cov` / `llvm-profdata` / `llvm-profgen` —— 覆盖率与 profile
- `llvm-opt-report` / `llvm-remarkutil` —— 优化报告

**JIT**:`lli`、`llvm-jitlink`;**档案**:`llvm-ar`、`llvm-ranlib`、`llvm-lib`;
**其他**:`dsymutil`、`llvm-cfi-verify`、`llvm-driver`(把所有工具合成一个多
调用二进制)、各类 fuzzer。

---

## 5. 文档与测试

### `llvm/docs/`

Sphinx 构建(`-DLLVM_ENABLE_SOPHISTICATED_BUILDS` 后 `ninja docs-llvm-html`)。
必读:

- `LangRef.rst` —— **LLVM IR 规范**,IR 语义的唯一权威来源
- `CodeGenerator.rst` —— 后端总览
- `WritingAnLLVMPass.rst` / `NewPMLangRef.rst` —— 写 pass(新 PM)
- `TableGen/*.rst` + `TableGenFundamentals.rst` —— TableGen
- `TestingGuide.rst`、`BugpointRedesign.md`、`Debugging.rst`
- `GettingStarted.rst` / `AdvancedBuilds.rst` / `CMake.rst` —— 构建系统

### `llvm/test/`

lit 驱动的 regression 测试,目录结构与 lib 高度对应:

```
test/
├── Transforms/     # 对应 lib/Transforms:InstCombine/、Scalar/、Vectorize/…
├── CodeGen/        # 对应 lib/CodeGen 与各 target:CodeGen/X86/…
├── Analysis/  Feature/  Other/  DebugInfo/  Assembler/  Linker/  Bitcode/…
```

单个测试是 `.ll` / `.mir` / `.c` 文件,带 `RUN:` 与 `CHECK:` 行:

```llvm
; RUN: opt -passes=instcombine -S < %s | FileCheck %s
```

更新 CHECK 行用 `llvm/utils/update_test_checks.py`(详见 `TestingGuide.rst`)。
跑法:`build-shared/bin/llvm-lit <file-or-dir>`,或 `ninja check-llvm` 全量。

### `llvm/unittests/`

gtest 单元测试,`ninja check-llvm-unit`,适合测库内部不便用 IR 表达的逻辑。

---

## 6. 按任务找代码速查表

| 想做的事 | 去哪 |
|---|---|
| 加/改一个 intrinsic | `llvm/include/llvm/IR/Intrinsics.td`(target 专用在 `Intrinsics<X>.td`) |
| 写一个优化 pass | `lib/Transforms/<合适子目录>/`,注册在 `lib/Passes/PassRegistry.def` + `PassBuilder.cpp` |
| 查一个已有优化 | `grep -r "PASS_NAME" lib/Transforms/` 或从 `PassRegistry.def` 入手 |
| 改指令选择 | 老框架:`Target/<T>/<T>ISelLowering.cpp`、`.td` 里的 pattern;新框架:`Target/<T>/GISel/` |
| 改寄存器分配 | `lib/CodeGen/RegAlloc*.cpp` |
| 查某 IR 指令语义 | `docs/LangRef.rst` + `lib/IR/<Instruction>.cpp` |
| 查 pass pipeline 定义 | `lib/Passes/PassBuilder.cpp` |
| 加新后端指令 | `Target/<T>/<T>Instr*.td` + `InstrInfo.cpp` |
| 查 verifier 报错来源 | `lib/IR/Verifier.cpp` |
| 弄明白一个 bug 最小用例 | `tools/bugpoint/` / `tools/llvm-reduce/` |

## 7. 建议阅读路径

1. `docs/GettingStarted.rst` 跑通构建,`examples/Kaleidoscope/` 过一遍前端→IR→JIT 全流程
2. `include/llvm/IR/` 核心类:`Value` → `User/Instruction` → `BasicBlock` → `Function` → `Module`,配合 `docs/LangRef.rst`
3. `lib/Analysis/ValueTracking.cpp` 或 `lib/Transforms/InstCombine/` 挑一个小 pass 通读,理解 use-def 遍历与新 PM 写法
4. 后端方向:`docs/CodeGenerator.rst` → `lib/CodeGen/SelectionDAGISel.cpp` 主循环 → 挑一个简单 target(如 RISCV)的 `.td` 与 `ISelLowering.cpp`
5. 测试习惯:改任何东西前先在对应 `test/` 目录找现有用例,改完用 `update_test_checks.py` 刷 CHECK
