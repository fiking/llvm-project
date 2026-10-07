# Clang Driver 详细设计文档

> 本文是基础设施系列的 Driver 篇,深入 clang 的"编译组织层":命令行解析、
> 编译计划(Action 图)的构建、工具链抽象与作业调度执行。所有类名、调用链、
> 行号均对照本仓库代码逐一核实(以 `clang/lib/Driver/` 为主)。

---

## 目录

1. [定位:Driver 是什么、不是什么](#1-定位)
2. [总体架构:五阶段流水线](#2-总体架构)
3. [入口与命令行解析](#3-入口与命令行解析)
4. [Phase 与 Type:两个正交的枚举](#4-phase-与-type)
5. [Action 图:编译计划](#5-action-图)
6. [ToolChain 与 Tool:平台抽象](#6-toolchain-与-tool)
7. [Job 构建、调度与执行](#7-job-构建调度与执行)
8. [Offloading:CUDA/HIP 的多目标编译](#8-offloading)
9. [设计取舍与不变量](#9-设计取舍与不变量)
10. [速查表](#10-速查表)

---

## 1. 定位

Driver 不做任何语言处理。它的职责是:**把一次用户调用(`clang -O2 -c a.c
b.cpp -o out`)翻译成一串具体的进程调用(clang -cc1 ×2、llvm-mc 或集成
assembler、可选的 ar/ld),并驱动它们执行**。

设计目标(源自 GCC 兼容性需求):

- **命令行兼容 gcc**:同名 flag、相同语义(`-c`、`-o`、`-Wl,`、`-MD`、
  `-lstdc++` 透传给链接器)
- **跨平台**:同一 driver 服务 Linux/macOS/Windows/交叉编译/GPU offload,
  平台差异全部封装在 ToolChain 层
- **可当库用**:libclang-cpp 暴露 driver;`clang -cc1` 自身也是 driver 生成
  的"作业"之一——编译器在 driver 眼里只是工具链里又一个 Tool

## 2. 总体架构

```text
clang_main (tools/driver/driver.cpp:228)
  ├─ argv[1] 是工具名(-cc1 / -cc1as / …)? → ExecuteCC1Tool → cc1_main
  └─ 否则,Driver 的五阶段:
       ① BuildCompilation   (Driver.cpp:1204)
          解析参数(InputArgList)、config 文件、driver mode、
          推导 triple、创建 Compilation 对象
       ② handleArguments    (Driver.cpp:3975)
          按最后生效的选项改写参数(DerivedArgList)、确定输入文件
       ③ BuildActions       (Driver.cpp:4112)
          构建 Action DAG(编译计划)
       ④ BuildJobs          (Driver.cpp:4895)
          自顶向下遍历 Action 图,选出 Tool、调 ConstructJob,
         产出 Command 列表(JobList)
       ⑤ ExecuteCompilation (Driver.cpp:1913)
          逐个执行 Command,处理崩溃上报
```

核心对象关系:

```text
Driver ──(拥有)── Compilation
                     ├─ DerivedArgList(改写后的参数)
                     ├─ Action DAG(输入→…→Link 的计划)
                     ├─ JobList(Command 的有序列表)
                     └─ 重定向(Redirects,供测试捕获输出)
Driver ──(缓存)── ToolChain 实例(triple → ToolChain)
ToolChain ──(持有)── Tool 集合(Assembler / Linker / Clang / …)
```

一次典型的 `clang -c foo.c`:`BuildActions` 产出
`AssembleJobAction(CompileJobAction(PreprocessJobAction(InputAction)))`,
`BuildJobs` 选中 Clang 这个 Tool(`-fno-integrated-as` 时拆成 cc1 + 外部
as),`ConstructJob` 生成最终 `clang -cc1 …` 命令行并可能合并 phase
(`-fintegrated-cc1` 下 Preprocess/Compile/Backend/Assemble 一个进程完成)。

---

## 3. 入口与命令行解析

### 3.1 双重身份:driver 与 cc1

`clang` 二进制同时是 driver 和真正的编译器(`tools/driver/driver.cpp`):

- `clang -cc1 …`(以及 `-cc1as`、`-cc1gen-reproducer` 等):argv[1] 直接
  命中工具名,`ExecuteCC1Tool`(driver.cpp:198)分派,不进入 driver 流程
- 其余情况:完整 driver 流程,内部会**生成** `clang -cc1` 形式的 Command
  (见 §6.3),默认以子进程执行;`-fintegrated-cc1` 时在当前进程内重入
  (Command 里记下 cc1 标志直接回调 `cc1_main`)

这个设计让 driver ↔ 编译器边界即进程边界,`clang -###`(只打印不执行)与
`clang -v` 天然可观测。

### 3.2 选项系统:Options.td + lib/Option

- 选项声明集中在 `clang/include/clang/Driver/Options.td`,由 clang-tblgen
  生成 `Options.inc`(选项 ID 枚举 + 表)
- 运行时解析器是 **LLVM 的 `llvm::opt` 库**(`llvm/include/llvm/Option/`),
  GCC 风格分组短参(`-abc` = `-a -b -c`)、joined 参数(`-O2`)、
  `--name=value` / `-name value`、`/MD` 风格(clang-cl)都由它统一处理
- 解析产物 `InputArgList`(扁平的 `Arg*` 列表);改写后的 `DerivedArgList`
  保留每个 Arg 的 `getBaseArg()` 回链——诊断输出"选项来自哪条原始命令行"
  就靠它

关键机制:**`claim()`**。每个选项默认未认领;各阶段(BuildActions、
各 Tool 的 ConstructJob)认领自己处理过的选项。`Compilation` 析构前检查
"未认领且未知"的选项并告警——这是"选项到底有没有被用上"的唯一权威
机制,新增选项必须显式 claim 或转发,否则会误报 `argument unused`。

### 3.3 Driver mode 与 config 文件

`BuildCompilation` 的前置逻辑(Driver.cpp:1204 起):

1. **driver mode 推导**:`getDriverMode` 依据可执行文件名(clang++ /
   clang-cl / clang-cpp / flang …)或 `--driver-mode=` 参数设定,影响选项
   默认值、链接行为、语言默认
2. **config 文件搜索**(Driver.cpp:1157-1201,顺序固定):
   `<triple>-<mode>.cfg` → `<triple>-<mode 后缀>.cfg` → `<mode>.cfg` →
   `<triple>.cfg`;文件内容按命令行参数展开后与用户参数合并(config 在前,
   命令行覆盖)
3. **clang-cl 透传**:`/clang:` 前缀的参数按 gcc 风格重新解析后并入
   (Driver.cpp:1244-1263)
4. `-working-directory` 先于一切文件访问生效(改 VFS cwd)

### 3.4 Triple 与多架构

`computeTargetTriple` 综合 `-m32/-m64`、`-arch`(Darwin)、`--target`、
环境 `CC_TARGET_…` 得出默认 triple;`-arch a -arch b`(Darwin universal)
会触发 `BindArchAction` 分叉(§5.2),每个 arch 一套后续编译,最后
`lipo` 合并。

---

## 4. Phase 与 Type

两个小枚举撑起整个"计划"语义(`clang/include/clang/Driver/Phases.h`、
`clang/lib/Driver/Types.cpp`):

```cpp
// Phases.h —— 有序!比较大小即"流水线先后"
namespace phases {
  enum ID { Preprocess, Precompile, Compile, Backend, Assemble, Link, IfsMerge };
}
```

- **Phase 是有序的**:`types::getPreprocessedType` 之类的"下一步是什么"
  查询 + phase 大小比较,共同决定从输入类型到 `-c`/`-S`/`-E` 停止点之间
  要插入哪些 JobAction
- **Type(types::ID)**:文件类型(约 60 种:C、CXX、ObjC、LLVM_IR、
  Object、Archive、TBD…),由扩展名推断(`types::lookupTypeForExtension`),
  是 Action 的边上的"数据类型"。Type 还带属性:仅预处理产物、是否只能做
  输入等
- 停止点:`-E` → Preprocess、`-c` → Assemble 之后停、`-S` → Backend 之后
  停、`-emit-llvm` 引入 BackendJobAction 且输出 LLVM_IR 类型

---

## 5. Action 图

### 5.1 层级

`clang/include/clang/Driver/Action.h`。Action 是**纯计划节点**,不绑定
平台与具体命令:

```text
Action (Kind + OffloadKind + 输出 types::ID)
 ├─ InputAction            —— 命令行上的输入文件(叶节点)
 ├─ BindArchAction         —— Darwin 多架构绑定(-arch 分叉)
 ├─ OffloadAction          —— offload 边界(§8)
 └─ JobAction              —— "需要执行一次变换"的抽象
     ├─ PreprocessJobAction
     ├─ PrecompileJobAction(PCH / module 预编译)
     ├─ ExtractAPIJobAction
     ├─ AnalyzeJobAction / MigrateJobAction(静态分析 / ARC 迁移)
     ├─ CompileJobAction
     ├─ BackendJobAction
     ├─ AssembleJobAction
     ├─ IfsMergeJobAction(接口文件合并)
     ├─ LinkJobAction / StaticLibJobAction
     ├─ LipoJobAction / DsymutilJobAction
     ├─ VerifyJobAction(VerifyDebugInfo / VerifyPCH)
     ├─ OffloadBundling / Unbundling / Packager / LinkerWrapper JobAction
```

要点:

- 每个 JobAction 持有 0..N 个输入 Action(`ActionList`),输出一个
  `types::ID`——图是 DAG,共享子图是常态(同一 InputAction 被
  device/host 两条链引用)
- `OffloadKind`(Host / Device / …)与 `ActionClass` 正交,同一节点可
  被标记为 device 侧

### 5.2 BuildActions 主循环(Driver.cpp:4112)

每个输入文件走同一条装配线:

```text
InputAction(types::ID)
  → [BindArchAction × 每个 -arch]
  → 循环:当前 phase < 最终 phase 时,由 types 查询推出下一个 JobAction
     (Preprocess → Compile → Backend → Assemble)
  → 全部输入装配完后,若需链接:LinkJobAction(或 StaticLibJobAction)
  → Darwin:+LipoJobAction(universal)/ +DsymutilJobAction(-g)
```

循环内每步都有 OffloadingActionBuilder 的挂钩点(addHostDependence
ToDeviceActions / addDeviceDependencesToHostAction,Driver.cpp:4188 起),
CUDA/HIP 在这里织入 device 编译链(§8)。

### 5.3 handleArguments:改写而非覆盖(Driver.cpp:3975)

在 BuildActions 之前,`handleArguments` 把"驱动语义"的参数物化成
DerivedArgList:

- 输入文件收集(`-x` 语言切换作用于后续文件,顺序敏感)
- `-o` 与多输入的匹配规则(单输入才允许 `-o a.o` 之外的形态)
- 依赖文件选项(`-M*`、`-MF`)、`-fprofile-*` 等改写
- DiagnosticsEngine 级别的驱动诊断在此发出

---

## 6. ToolChain 与 Tool

### 6.1 ToolChain(`clang/include/clang/Driver/ToolChain.h:92`)

平台抽象的基类,**回答"在这个平台上,东西在哪、用什么、怎么配"**:

| 职责 | 代表接口 |
|---|---|
| 工具选择 | `getTool(Action::ActionClass)`(新);`SelectTool(JA)`(旧) |
| 路径查找 | `SearchPaths`、`GetProgramPath`、`GetLinkerPath`(含 `-fuse-ld=` 与 lld 探测) |
| 库选择 | `GetCXXStdlibType` / `GetRuntimeLibType`(libc++ vs libstdc++、libgcc vs compiler-rt) |
| flag 翻译 | `TranslateArgs`(driver 参数 → cc1 参数的平台部分)、`TranslateOpenMPTargetArgs` |
| triple 管理 | `getTriple()` / `getEffectiveTriple()`(RAII `RegisterEffectiveTriple` 惰性计算并缓存) |
| 运行时目录 | `getStdlibPath`、compiler-rt / OpenMP / CUDA 路径族 |

`Driver` 以 triple 为 key 缓存 ToolChain 实例(`getToolChain`,
Driver.cpp:1465 处的调用即走缓存),offload 场景一个 Compilation 可同时
持有 host 与多个 device 的 ToolChain。

### 6.2 ToolChains/ 目录的三大类

`clang/lib/Driver/ToolChains/`:

1. **按操作系统**:`Gnu`(Linux/GNU 系基类)、`Darwin`(macOS/iOS)、
   `MSVC` / `MinGW`、`FreeBSD` / `NetBSD` / `OpenBSD`、`Fuchsia` /
   `Haiku` / `Solaris` / `AIX` / `ZOS` / `Hurd` / `DragonFly`、
   `CrossWindows`、`BareMetal`
2. **按嵌入式/专有目标**:`Arch/`(arm/riscv/mips 等变体辅助)、`AVR`、
   `Hexagon`、`CSKY`、`MSP430`、`XCore`、`VEToolchain`、`RISCVToolchain`
3. **GPU / 加速器**:`Cuda`、`HIPAMD` / `HIPSPV`、`AMDGPU` /
   `AMDGPUOpenMP`、`SPIRV`、`WebAssembly`(以及 PS5PU、OHOS 等系统变体)

每个 ToolChain 子类持有并惰性构造一组 **Tool**(Assembler、Linker、
StaticLibTool 等),`CommonArgs.cpp` 收纳跨平台共享的 flag 组装函数
(`addLinkerCompressDebugSections`、`addOpenMPRuntime` 等)。

### 6.3 关键认知:Clang.cpp 是"工具"

`ToolChains/Clang.cpp` 里的 `Clang` 类**就是 Tool 子类**——它的
`ConstructJob` 负责把 driver 参数翻译成 `-cc1` 参数(数百个 `options::
OPT_xxx` 到 cc1 选项的映射、`-mllvm` 转发、调试选项、sanitizer flags)。
也就是说:**driver 眼里,编译器前端是工具链里的一个外部工具,cc1 命令行
的拼装逻辑与拼 ld 命令行同构**。`Flang.cpp` 同理。这保证了新语言前端
接入 driver 不需要改 driver 核心。

### 6.4 Tool(`clang/include/clang/Driver/Tool.h:32`)

```cpp
class Tool {
  virtual void ConstructJob(Compilation &C, const JobAction &JA,
                            const InputInfo &Output,
                            const InputInfoList &Inputs,
                            const llvm::opt::ArgList &TCArgs,
                            const char *LinkingOutput) const;
  virtual void ConstructJobMultipleOutputs(...);  // 多输出(PCH+对象)
};
```

`ConstructJob` 只产出 argv,不执行。Linker 类工具在这里处理
`-Wl,`/`-Xlinker,` 拆包、`-T` 脚本、rpath、`--sysroot`。

---

## 7. Job 构建、调度与执行

### 7.1 BuildJobs(Driver.cpp:4895)

自顶向下遍历 Action 图(DAG → 树形展开),对每个 JobAction:

1. 递归 `BuildJobsForAction`(Driver.cpp:5430)——**带 memoization**,
   同一 Action 只构造一次 Job,共享节点(如 host/device 共用的 PCH)不会
   重复编译;真正的构造在 `BuildJobsForActionNoCache`(Driver.cpp:5480)
2. 选 Tool:按 ToolChain + ActionClass 拿到具体 Tool
3. 决定输出:`-o` 指定、临时文件(`/tmp/…` 由 Compilation 统一登记
   生命周期)、多 arch 命名
4. `Tool::ConstructJob` 产出 `Command`

### 7.2 Command 与 JobList(`clang/include/clang/Driver/Job.h`)

```cpp
class Command {            // Job.h:106
  // 可执行文件 + argv + Action 来源 + 响应文件支持
};
class JobList {            // Job.h:262 — 拓扑序的 Command 容器
};
```

变体(装饰器模式):

- **FallbackCommand**:先跑 A,失败则跑 B(如 lld 失败回落系统 ld)
- **ForceSuccessCommand**:忽略退出码(内部命令失败仍继续的兼容场景)

**响应文件**:命令行超长(Windows 32K 限制)自动落 `.rsp`
(`Command::setResponseFile`),Linker 工具常用。

### 7.3 ExecuteCompilation(Driver.cpp:1913)

- 顺序执行 JobList(无内置并行;`-fintegrated-cc1` 的进程内 cc1 除外,
  它由 Command 直接回调,省进程开销)
- 收集失败的 Command 进 `FailingCommands`,连同 argv 一起返回;driver
  层据此打印 `note: diagnostic msg: ...`、写 crash reproduction
  (`-gen-reproducer` / `clang -cc1gen-reproducer`:收集输入、命令行、
  诊断到一个目录,一键复现)
- 输出重定向:`Compilation::Redirect`(测试与 API 用户用)
- `-###` 在这一层之前就短路:只打印 JobList 不执行;`-v` 打印 + 执行

---

## 8. Offloading

CUDA/HIP/OpenMP-target 的编译被建模为**一张图里的多条平行链**:

- `OffloadingActionBuilder`(BuildActions 各挂钩点)为每个 device 架构
  复制编译链:`Input → Compile(OffloadKind=Device) → Assemble →
  OffloadBundling`
- device 产物由 `OffloadBundlingJobAction` 打包(clang-offload-bundler /
  packager),作为**额外的输入**挂到 host 的 LinkJobAction 上——
  `LinkerWrapperJobAction` 决定最终由 clang-linker-wrapper 在链接期把
  device 对象注入 host 二进制(嵌入式 fatbin / __CLANG_OFFLOAD_BUNDLE__
  section)
- host 侧可见的特殊动作:`-foffload-device-only` 只留 device 链;
  OpenMP offload 走 `AMDGPUOpenMP`/`Clang` 组合,参数经
  `TranslateOpenMPTargetArgs` 派生
- 一个 Compilation 持多个 ToolChain(host gcc + device hipamd),BuildJobs
  对每条链用对应 ToolChain 的 Tool

这解释了 `clang -### -x hip a.cu` 输出里 host/device 多条 `-cc1` 与
bundler/linker-wrapper 命令的组织方式。

---

## 9. 设计取舍与不变量

1. **计划与执行分离**:Action(平台无关的计划)→ Job(具体命令)两层,
   `-###`/`-v` 的可观测性、tooling(libclang 的 `BuildCompilation` 复用)
   都建立在这层分离上。不要在 BuildActions 阶段做任何 ToolChain 相关决定
   之外的事,更不要在 Action 里塞 argv
2. **claim 纪律**:新增选项若被静默忽略,必须 `claim()`;否则既误报
   unused warning,也污染 `-###` 语义
3. **Action 图是 DAG,memoization 依赖它**:BuildJobsForAction 的缓存假设
   同一 Action 的 Job 可复用;副作用(写死文件名)会破坏这个假设
4. **Tool 是无状态的**:ConstructJob 是 const;所有状态在 Compilation/
   ToolChain/Args。新 Tool 不要持有每编译可变状态
5. **cc1 参数拼装集中在 Clang.cpp**:driver 不直接理解编译语义;新增
   编译选项的路径是 Options.td → Clang.cpp(映射到 cc1)→ CC1Options.td
   (cc1 侧接收),三处要同步
6. **平台判断分层**:先 ToolChain 子类差异(OS 级),再 Arch/ 辅助(ISA
   级),最后 cc1 内 Triple 判断(编译期语义)。不要在 BuildActions 里
   写平台 if
7. **子进程默认、进程内可选**:默认 cc1 走子进程(隔离崩溃、便于
   reproduce);`-fintegrated-cc1` 只是执行策略变化,JobList 不变
8. **崩溃可复现是一等公民**:FailingCommands + reproducer 机制要求
   Command 保留完整 argv 与输入文件路径,不要在执行前丢弃或改写

---

## 10. 速查表

| 需求 | 位置 |
|---|---|
| driver 主流程五阶段 | `clang/lib/Driver/Driver.cpp:1204`(BuildCompilation)、`:3975`(handleArguments)、`:4112`(BuildActions)、`:4895`(BuildJobs)、`:1913`(ExecuteCompilation) |
| 入口与 cc1 分发 | `clang/tools/driver/driver.cpp:228`(clang_main)、`:198`(ExecuteCC1Tool) |
| 选项声明 | `clang/include/clang/Driver/Options.td`(生成 Options.inc) |
| 选项解析库 | `llvm/include/llvm/Option/`(InputArgList / DerivedArgList / claim) |
| Phase / Type | `clang/include/clang/Driver/Phases.h`、`clang/lib/Driver/Types.cpp` |
| Action 全层级 | `clang/include/clang/Driver/Action.h` |
| offload 装配 | Driver.cpp 中 `OffloadingActionBuilder` 挂钩(BuildActions 内) |
| ToolChain 基类 | `clang/include/clang/Driver/ToolChain.h:92` |
| "编译器即工具" | `clang/lib/Driver/ToolChains/Clang.cpp`(cc1 命令行拼装) |
| Command / JobList / Fallback | `clang/include/clang/Driver/Job.h:106`、`:262` |
| 平台 ToolChain 清单 | `clang/lib/Driver/ToolChains/` |
| 崩溃复现 | Driver.cpp FailingCommands 处理 + `-gen-reproducer` |
| 官方设计文档 | `clang/docs/DriverInternals.rst` |
| 姊妹篇 | 《Clang 基础设施详细设计文档》(内存/位置/诊断/序列化) |
