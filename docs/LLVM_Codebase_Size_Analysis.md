# LLVM Monorepo 代码量分析

**基准**：main @ `3eda2aebadd4`（2026-09-28）· git ls-files 全量 tracked 文件 · `wc -l` 分批实测
**口径**（v2，unittest 纳入测试、二进制不计行）：代码行 = 排除 `*/test/`、`*/tests/`、`*/Inputs/`、`*/unittests/`、`*/unittest`、cross-project-tests，且剔除二进制文件（2,110 个、130 MB、按 wc 误计 42.5 万假行，按字节另列）后的行数；测试行 = 上述测试目录（含 unittests）内的行数。"指定扩展名源码"单列（cpp/h/c/hpp/td 等，不含 Python/汇编/无扩展名头文件）。
**方法**：`git ls-files -z` 全量 185,578 个 tracked 文件（含 9 个带空格路径），分批 `wc -l` 汇总、检查退出状态；wc 的 `total` 汇总行已剔除；带空格路径单独 `wc`。

---

## 1. 总量

| 口径 | 数值 |
|---|---|
| tracked 文件 | 185,578 |
| **代码行（非测试，剔二进制）** | **12,726,947** |
| 测试行（含 unittests 922,206） | 36,467,548 |
| 合计 | 49,194,495 |
| 二进制文件（不计行） | 2,110 个 / 130,369,312 字节 |
| 指定扩展名源码（cpp+h+c+hpp+td） | 10,699,760 |

**测试:代码 = 2.9 : 1**——LLVM monorepo 的测试体积（含单元测试）接近代码本的 3 倍，这是它作为基础设施软件的显著特征（对比：一般应用项目测试占比远低于此）。

### 1.1 语言的形态（代码行 / 测试行）

| 扩展名 | 代码 | 测试 | 说明 |
|---|---|---|---|
| .cpp | 6,540,591 | 4,289,383 | 主体；测试侧含 unittest |
| .h | 2,719,827 | 218,281 | 头文件几乎全在代码侧 |
| .td | 997,075 | 52,402 | TableGen 描述（见 §4） |
| .hpp | 201,894 | 66,933 | |
| .c | 241,268 | 3,034,794 | 代码侧小、测试侧大——libc/compiler-rt 的 C 测试 |
| .s | 54,848 | 3,753,961 | **汇编测试是测试体的绝对大头** |
| .ll | 1,875 | 17,063,458 | **IR 测试独占 1706 万行，占全部测试的 47%** |
| .mir | 0 | 2,081,258 | MIR 后端测试 |
| .mlir | 0 | 665,329 | |
| .f90 | 7,187 | 316,901 | flang 测试 |
| .wc | 0 | 2,181,263 | libc 数学 worst-case 输入数据（见 §10 注） |
| .py | 156,498 | 291,547 | lit/更新脚本/调试器测试 |
| .json | 429,170 | 16,911 | 代码侧 json 多为数据表 |
| .md | 364,823 | 1,556 | 文档 |

三个结构性观察：

1. **LLVM 的测试主体是 .ll/.s/.mir 三种"编译器中间产物"文件**（合计 2,289 万行，占测试 63%）——测试即 IR/汇编文本，这是编译器项目独有的测试形态；单元测试另有 2,532 个文件、853,843 行（.cpp 约 82.9 万行，llvm 侧 39.3 万）。
2. 代码侧最大单文件是 `libc/src/__support/ryu_long_double_constants.h`（120,478 行生成常量表）与 `X86ISelLowering.cpp`（65,606 行）——**"巨石"集中在 Target 的 ISelLowering 家族**（X86 65.6k / AArch64 36.5k / RISCV 30.3k / ARM 22.5k）。
3. `.h/.hpp` 的测试占比极低（7%）——头文件不独立测试，全靠消费方覆盖。

## 2. 模块排行（代码行 / 测试行）

| # | 模块 | 代码 | 测试 | 定位 |
|---|---|---|---|---|
| 1 | llvm | 4,883,930 | 24,370,378 | 核心库 + opt/llc 等工具 |
| 2 | clang | 2,276,044 | 5,556,753 | C/C++/ObjC 前端 |
| 3 | mlir | 1,051,361 | 794,443 | 多级 IR 基础设施 |
| 4 | lldb | 897,558 | 421,884 | 调试器 |
| 5 | clang-tools-extra | 682,160 | 243,604 | clangd/tidy 等 |
| 6 | libc | 465,904 | 2,346,357 | LLVM libc |
| 7 | libcxx | 445,355 | 1,159,686 | C++ 标准库 |
| 8 | polly | 451,305 | 105,898 | 多面体优化（含 isl 外部库） |
| 9 | flang | 397,861 | 440,416 | Fortran 前端 |
| 10 | compiler-rt | 299,857 | 376,054 | 运行时/ sanitizer |
| 11 | openmp | 154,310 | 49,694 | OpenMP 运行时 |
| 12 | third-party | 202,440 | 51,350 | vendored 依赖（boost-math 18.4 万为主） |
| 13 | lld | 119,968 | 234,422 | 链接器 |
| 14 | bolt | 113,763 | 135,483 | 二进制优化器 |
| 15 | flang-rt | 49,727 | 14,180 | flang 运行时 |
| 16 | offload | 46,659 | 49,338 | offloading 运行时 |
| — | 其余（utils/libunwind/libcxxabi/libclc/orc-rt/libsycl/.github 等） | ~250,000 | ~130,000 | |

**头部集中度**：llvm+clang 两模块占代码的 56%；前五（+mlir/lldb/clang-tools-extra）占 77%。运行时家族（libc/libcxx/libcxxabi/libunwind/compiler-rt/openmp/offload/flang-rt/orc-rt/libclc）合计 155.6 万行——与 mlir 体量相当，是容易被忽略的第二梯队。

### 2.1 编译器本体 vs 周边设施

按职责重新分桶（均为 v2 口径）：

| 桶 | 模块 | 代码行 | 占比 |
|---|---|---|---|
| 编译器本体（前端+中端+后端+链接+IR 基础设施） | llvm/clang/flang/lld/mlir | 8,729,164 | 69% |
| 运行时库 | libc/libcxx/libcxxabi/libunwind/compiler-rt/openmp/offload/flang-rt/orc-rt/libclc | 1,556,020 | 12% |
| 工具链周边 | lldb/clang-tools-extra/bolt | 1,693,481 | 13% |
| 研究/试验 + 依赖 + 杂项 | polly/third-party/utils/… | 748,282 | 6% |

（四桶合计与 §2 总量的差额为 .github/.ci/根文件等。）

## 3. llvm/ 内部结构（lib 360 万 + include 67 万）

| 子目录 | 行数 | 说明 |
|---|---|---|
| lib/Target | 1,972,817 | **25 个后端子目录 + 根文件 3,736，占 llvm/lib 的 55%** |
| lib/Transforms | 458,925 | 中端 pass |
| lib/CodeGen | 393,750 | 机器层通用（不含 Target） |
| lib/Support | 139,265 | 基础设施 |
| lib/Analysis | 111,576 | 分析 pass |
| lib/IR | 83,554 | IR 核心 |
| lib/DebugInfo | 66,233 | |
| lib/ExecutionEngine | 65,197 | JIT |
| lib/MC | 53,970 | |
| lib/Object | 27,431 | |
| 其余（Frontend 21,460/Bitcode 21,121/ProfileData/ObjectYAML/AsmParser/CAS/…） | 224,229 | |

### 3.1 Transforms 细分

| pass 族 | 行数 |
|---|---|
| Scalar | 101,689 |
| Vectorize | 99,237 |
| Utils | 77,170 |
| IPO | 65,767 |
| InstCombine | 57,019 |
| Instrumentation | 40,041 |
| Coroutines | 7,844 |
| ObjCARC | 5,677 |

Vectorize（SLP 36.6k + LV）几乎追平 Scalar——**向量化是这个仓库单笔最大的优化投入**。

### 3.2 CodeGen 细分（Top）

| 组件 | 行数 |
|---|---|
| SelectionDAG/ | 127,248 |
| GlobalISel/ | 42,211 |
| AsmPrinter/ | 30,783 |
| MachineScheduler.cpp | 5,037 |
| MachinePipeliner.cpp | 4,492 |
| RegisterCoalescer.cpp | 4,434 |
| MachineBlockPlacement.cpp | 3,933 |
| RegAllocGreedy.cpp | 3,008 |

**SDAG 127k vs GISel 42k**：两条指令选择路线并存，老路线代码量是新的 3 倍——与 GISel 尚未全面替代 SDAG 的现状一致（各 target 的迁移进度不一）。

## 4. TableGen：99.7 万行的"第二语言"

| 位置 | .td 行数（非测试） | 备注 |
|---|---|---|
| llvm/lib/Target | 632,663 | 573 文件 |
| mlir | 161,923 | 另有测试侧 17,879 |
| clang | 110,901 | 另有测试侧 1,590 |
| llvm（非 Target） | 70,695 | llvm 全量 .td 703,358 − Target 632,663 |
| flang | 11,176 | 25 文件 |
| lldb | 4,655 | 30 文件 |
| lld | 3,395 | 5 文件 |
| offload | 1,667 | 另有测试侧 444 |

（分项合计 995,408 + 散布在其他模块（libc/utils 等）的 .td ≈ 全仓非测试 .td 997,075。）

- Target 的 .td 占其总行数的 32%（63.3 万 / 197.3 万）——**后端有近三分之一是 TableGen 声明式描述**，真正的"指令语义"大半以 .td 存在。最大单文件 `HexagonDepInstrFlags.td` 家族过 4.2 万行。
- mlir 的 .td 占其代码的 15%（16.2 万 / 105.1 万）——Dialect 定义、Op 接口、Pass 声明都走 TableGen，是 mlir 的基本编程范式。
- clang 的 11.1 万行 .td：Attr.td（属性定义）、Diagnostic*.td、Builtins*.td。

## 5. 后端排行榜（lib/Target 25 个后端子目录，含各自 .td；Target 目录另有根文件 3,736 行）

| # | Target | 行数 | | # | Target | 行数 |
|---|---|---|---|---|---|---|
| 1 | AMDGPU | 300,109 | | 14 | DirectX | 20,459 |
| 2 | AArch64 | 283,276 | | 15 | VE | 19,998 |
| 3 | X86 | 271,388 | | 16 | M68k | 19,056 |
| 4 | Hexagon | 178,219 | | 17 | Sparc | 18,476 |
| 5 | ARM | 175,480 | | 18 | Xtensa | 18,464 |
| 6 | RISCV | 154,263 | | 19 | CSKY | 17,433 |
| 7 | PowerPC | 115,711 | | 20 | AVR | 16,764 |
| 8 | Mips | 83,119 | | 21 | BPF | 15,409 |
| 9 | SystemZ | 61,791 | | 22 | Lanai | 10,603 |
| 10 | SPIRV | 51,178 | | 23 | MSP430 | 8,393 |
| 11 | WebAssembly | 38,323 | | 24 | XCore | 8,307 |
| 12 | LoongArch | 38,021 | | 25 | ARC | 7,405 |
| 13 | NVPTX | 37,436 | | | **子目录合计** | **1,969,081** |
| | | | | | **+根文件/总计** | **3,736 / 1,972,817** |

- **三巨头**（AMDGPU/AArch64/X86）各 27-30 万行，合计 85.5 万，占全部后端的 43%。
- **AMDGPU 是全仓最大后端**（30.0 万），与 NVPTX（3.7 万）的 8 倍差已在 nvptx-vs-amdgpu-analysis.md §1 充分展开（职责边界：LLVM 内闭环 vs ptxas 下游分担；R600 遗产约 1.35 万行；GISel/SDAG 双路径约 2.24 万行）。
- **中间带**（Hexagon/ARM/RISCV/PowerPC 11-18 万）：DSP、嵌入式 32 位、开源 RISC 生态的活跃 target。
- **长尾**（MSP430/ARC/XCore <1 万）：极简 ISA 的自然规模。
- 面向 GPU/加速器的 target 共 4 个（AMDGPU/NVPTX/SPIRV/DirectX），合计 40.9 万行——**加速器后端已是 Target 目录的第二大族群**。（WebAssembly 38,323 行为通用 wasm 目标，不归入 GPU/加速器组。）

## 6. clang/ 内部结构（lib 约 145 万，v2 口径）

| 子目录 | 行数 | 占比 |
|---|---|---|
| Sema | 340,278 | 21% |
| CodeGen | 214,840 | 13% |
| AST | 202,739 | 13% |
| Headers | 197,661 | 12% |
| StaticAnalyzer | 108,381 | 7% |
| CIR | 97,492 | 6% |
| Driver | 69,801 | 4% |
| Parse | 50,167 | 3% |
| Analysis | 44,191 | 3% |
| Serialization | 43,347 | 3% |
| Frontend | 40,690 | 3% |
| Format | 37,338 | 2% |
| Basic/Lex/Tooling/其余 | ~148,000 | 9% |

- **Sema 是最大单体**（34 万行，最大文件 SemaOpenMP.cpp 28.3k）——C++ 语义检查的复杂度远超解析；加上 AST 与 Headers，"语义/类型系统"一族占 clang 的近半。
- **CIR 9.7 万行**已进入第 6 位——Clang IR 路径从实验走向正编（对应 LangStandard.h 的 CIR 输入形态）。
- Driver 仅 7 万行即撑起整个工具链编排（GCC 兼容参数、offload、跨平台工具选择），与其在编译流程中的枢纽地位相比体量极小。

## 7. 其他要点模块

- **lld（12 万）**：ELF 52,628 / MachO 23,915 / COFF 22,019 / wasm 12,415——四平台链接核心合计约 11 万，"Common+Driver"仅 3 千余行。以 lld 之重（承担整个 AMDGPU device 链接）体量却只有 clang 的 1/19。
- **lldb（90 万）**：插件化结构，Plugins 36 万级别（各调试格式/架构支持）> Target 4.5 万 > Core 3.3 万 > API 3.1 万——把体量摊进格式适配层。
- **flang（40 万，lib 28.9 万）**：Fortran 前端+语义，与 clang（228 万）的比例约 1:6，反映 Fortran 语言面窄于 C/C++ 全家桶。
- **libc（47 万）**：测试 235 万（其中数学 worst-case 输入数据 .wc 218 万）——**测试:代码 = 5.0:1，全仓最高**，数学函数正确性验证的体量远超实现本身。
- **polly（45 万）**：其中 isl 外部库（lib/External）占大头——多面体优化的真正核心是 vendored 的 isl；另有 www 论文 PDF 6.3 万行（二进制，v2 口径已按字节另计、不计入行数）。

## 8. 超大文件 Top（非测试）

| 行数 | 文件 | 性质 |
|---|---|---|
| 120,478 | libc/.../ryu_long_double_constants.h | 生成常量表 |
| 65,606 | llvm/lib/Target/X86/X86ISelLowering.cpp | 手写巨石 |
| 52,760 | polly/lib/External/isl/.../typed_cpp.h | 生成绑定 |
| 42,410 | llvm/lib/Target/Hexagon/HexagonDepInstrInfo.td | 生成式 .td |
| 36,575 | llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp | 手写巨石 |
| 36,540 | llvm/lib/Target/AArch64/AArch64ISelLowering.cpp | 手写巨石 |
| 32,531 | llvm/lib/CodeGen/SelectionDAG/DAGCombiner.cpp | 手写巨石 |
| 30,295 | llvm/lib/Target/RISCV/RISCVISelLowering.cpp | 手写巨石 |
| 28,336 | clang/lib/Sema/SemaOpenMP.cpp | 手写巨石 |
| 23,312 | clang/lib/AST/ExprConstant.cpp | 手写巨石 |

**手写巨石集中在三处**：Target ISelLowering（目标语义 lowering）、SemaOpenMP（指令语义）、ExprConstant/DAGCombiner/SLP（语义求值/组合/向量化）——都是"case 式处理"天然膨胀的领域。前 15 大文件中 polly/isl 的生成头文件占 4 席。

## 9. 文档量

- llvm/docs：184,590 行（rst+md，471 文件）——相当于一个中型后端的体量。
- 全仓 .md 365k + 各模块 rst——文档是仓库的一等公民，与代码同库演进。

## 10. 每模块"测试密度"对比（v2 口径，测试含 unittests）

| 模块 | 测试:代码 | 说明 |
|---|---|---|
| libc | 5.0 | 数学 worst-case 输入数据主导 |
| llvm | 5.0 | .ll/.s/.mir IR 级测试主导 |
| lld | 2.0 | 链接产物测试 |
| clang | 2.4 | |
| libcxx | 2.6 | 标准一致性测试 |
| flang | 1.1 | |
| mlir | 0.8 | 检查行驱动 |
| lldb | 0.5 | 大量依赖手工 API 测试 |
| polly | 0.2 | |
| clang-tools-extra | 0.4 | |
| openmp | 0.3 | 运行时项目测试普遍轻 |

**梯度清晰**：编译器核心（llvm/libc）> 前端/链接器 > 工具（mlir/lldb/clangd）> 运行时。

**注意：行数比不能直接换算用例数或维护成本**。lit 的 ShTest 按文件组织测试（`llvm/utils/lit/lit/formats/shtest.py:8`），一个 .ll 文件可含多条 RUN 与任意多 CHECK 断言——CHECK 是输出断言而非用例本身，用例成本还取决于输入构造与 RUN 命令编写。行数只反映"测试文本体量"，不能据此比较开发成本差距。另注：.wc（2,181,263 行）是 libc 数学的 worst-case 输入数据（转换脚本 `libc/utils/mathtools/wc_to_bin.py:10`），不是断言、更非全输入空间穷举。

## 11. 昇腾视角

1. **"后端占 llvm/lib 的 55%"是职责分界的直接后果**：通用层（Transforms 45.9 万 + CodeGen 39.4 万 = 85.3 万行）≈ 三大后端合计（85.5 万）。现有实现的规模参照：闭环型后端（对标 AMDGPU 形态）现役实现为 20-30 万行量级，虚拟 ISA 型（对标 NVPTX 形态）为 3-5 万行量级——这是"现有实现规模"的经验数据，不能直接当作昇腾开发预算使用（职责边界决定规模，见 nvptx-vs-amdgpu-analysis.md §1/§2）。
2. **TableGen 占后端 1/3** 意味着新后端的大部分"指令语义"工作是写 .td 而非 C++——昇腾已有 CANN 侧指令描述体系，若迁移到 LLVM 后端，描述资产的可转换性是首要评估项。
3. **测试形态选型**：llvm 的 .ll/.mir 文本测试 + FileCheck 的形态使测试可以以文本行积累。lit 按文件组织用例、CHECK 为输出断言——行数与用例数不是一回事，但"IR 文本 + CHECK"确实是单用例边际成本很低的形态。昇腾 ST 测试的 testcases/ 数据文件模式（读文件→比对）与 PyPTO 的 run_*+main() 模式在用例组织上不同，若构建编译器级回归体系，"IR 文本 + CHECK 指令"形态值得优先评估。
4. **Sema 34 万行的警示**：语言复杂度的大头在语义检查而非解析。昇腾 C（类 AscendC 扩展）若持续加语言特性，Sema 侧投入会线性膨胀——PyPTO 把 tiling 放在语言外的选择（见 Clang-NVPTX-notes 的 AscendC 光谱判定）在这个数字下更站得住。
5. **巨石文件规律**：ISelLowering 家族的 2-6.5 万行是各后端标配。昇腾后端若出现同量级巨石属正常形态，但应警惕 SemaOpenMP 式的"单文件穷举"——优先拆分机制（如 SIISelLowering 拆 SIInsertWaitcnts/SIFoldOperands 等独立 pass 的做法）。

---

## 附录 A：统计方法与复现（v2）

```bash
# 全量文件清单（-z 保完整路径，仓库有 9 个含空格路径）
git ls-files -z > /tmp/allfiles.z

python3 - <<'EOF'
import subprocess, collections
files = open('/tmp/allfiles.z','rb').read().decode().split('\0')
files = [f for f in files if f]

def is_test(f):
    return (any(s in f for s in ('/test/','/tests/','/Inputs/','/unittests/','/unittest'))
            or f.startswith(('cross-project-tests','test/')))

def is_binary(f):  # 按扩展名或 NUL 字节探测；二进制按字节计、不计行
    if f.rsplit('.',1)[-1].lower() in ('pdf','png','jpg','gif','ico','zip','gz','woff','ttf',...):
        return True
    return b'\0' in open(f,'rb').read(8192)

code, test = collections.defaultdict(int), collections.defaultdict(int)
for i in range(0, len(files), 3000):          # 分批防 ARG_MAX
    batch = files[i:i+3000]
    clean  = [f for f in batch if ' ' not in f]   # 无空格路径批处理
    space  = [f for f in batch if ' ' in f]       # 含空格路径单独 wc
    out = {}
    if clean:
        r = subprocess.run(['wc','-l','--']+clean, capture_output=True, text=True)
        assert r.returncode == 0, r.stderr[:200]  # 检查 wc 失败状态
        for line in r.stdout.splitlines():
            p = line.rsplit(' ', 1)               # 从右侧切分，容忍路径含空格
            if len(p) == 2 and p[1] != 'total' and p[0].lstrip('-').isdigit():
                out[p[1]] = int(p[0])
    for f in space:
        r = subprocess.run(['wc','-l','--',f], capture_output=True, text=True)
        p = r.stdout.rsplit(' ', 1)
        if len(p) == 2 and p[0].isdigit(): out[f] = int(p[0])
    for f in batch:
        n = out.get(f)
        if n is None: continue
        if is_binary(f): continue                 # 二进制不计行（按字节另计）
        top = f.split('/')[0]
        # v2 关键修复：遍历 code|test 全部键，test-only 模块（cross-project-tests）不再漏计
        (test if is_test(f) else code)[top] += n
for m in sorted(set(code)|set(test), key=lambda x:-(code[x]+test[x])):
    print(f"{m:<20}{code[m]:>12,}{test[m]:>13,}")
EOF
```

**已知的口径坑**（v1→v2 全部踩过）：
1. wc 的 `total` 汇总行会被当作名为 "total" 的文件计入——v1 曾因此混入 4,962 万假行，必须过滤 `p[1] != 'total'`。
2. `read().split()` 按空白拆路径——仓库有 9 个含空格路径（clang 侧 2 个测试文件等），v1 漏/错计 34,303 行；必须 `git ls-files -z` + 从行尾 `rsplit` 解析。
3. 只遍历非测试桶会漏掉 test-only 模块——cross-project-tests（34,298 行）v1 完全丢失；遍历范围必须是 `code.keys() | test.keys()`。
4. `/unittests/` 不识别会把 2,528 个文件、853,843 行单元测试计入代码（v1 硬伤）；注意还有单数 `/unittest` 形态。
5. 二进制文件的换行字节不是代码——polly/www 论文 PDF 按行误计 20,098 行等，全仓二进制误计 42.5 万假行；按字节另列、不进 LOC。
6. `.wc` 扩展名是 libc 数学 worst-case 输入数据（`libc/utils/mathtools/wc_to_bin.py:10`），不是 wc 工具输出、也不是断言。
7. `git ls-files` 不含 build 目录与未跟踪文件（build-debug/build-shared 及 untracked 均不在统计内）。

## 附录 B：与前序文档数字的一致性

| 数字 | 本文 | 前序文档 | 一致性 |
|---|---|---|---|
| AMDGPU 后端 | 300,109 | nvptx-vs-amdgpu §1：29.9 万 | ✓ 同一目录范围；930 行差额为 AMDGPU 侧 .def/CMakeLists.txt 等根级文件在两文中的归类差异 |
| NVPTX 后端 | 37,436 | nvptx-vs-amdgpu §1：3.7 万 | ✓ |
| TableGen .td（AMDGPU） | 57,857 / 300,109 ≈ 19.3% | nvptx-vs-amdgpu：5.8 万行 .td | ✓ 行数一致；注意 AMDGPU 的 .td 占比（19.3%）低于全 Target 均值（32%），因 AMDGPU 的 .cpp 体量（hazard/waitcnt/调度等机器层 pass）摊薄了 .td 份额 |
| SelectionDAG | 127,248 | — | 新数字 |
| GISel | lib/CodeGen/GlobalISel 全目录 42,211（不含 llvm/utils/TableGen 的生成器） | nvptx-vs-amdgpu：AMDGPU GISel 三大件 22,416 | 口径不同：42,211 是通用框架目录（IRTranslator/Legalizer/RegBankSelect 框架 + utils）；22,416 是 AMDGPU 侧三件（AMDGPULegalizerInfo/AMDGPUInstructionSelector/AMDGPURegisterBankInfo 目标实现），非同一对象 |

——完——
