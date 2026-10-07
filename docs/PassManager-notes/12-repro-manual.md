# §12 素材：复现手册（主会话实测汇编）

> 基准与构建：main @ `3eda2aebadd4`，`./build-debug.sh`（Debug+Assertions）。
> 全部命令于 2026-09-29/30 在本机实跑验证。scratch 产物在 `PassManager-notes/scratch/`。

## 0. 通用工具坑（务必先读）

1. **`-p 'default<O1>'` 必须引号包裹**——`<` 会被 shell 当重定向，报 "no such file or directory: O1"。
2. **clang 的双段观察需要两个不同开关**：
   - IR 优化段（新 PM）：`-mllvm --print-pipeline-passes`（注意：`-Xclang -print-pipeline-passes` 不识别）；**`-mllvm -print-changed=quiet` 在 clang 也可用**（实测输出 IR Dump 序列）
   - CodeGen 段（legacy）：`-mllvm --debug-pass=Executions`
   - clang 的新 PM 执行跟踪用 **`-Xclang -fdebug-pass-manager`**（实测可用，输出 "Running pass/analysis" 全景）；`-mllvm --debug-pass-manager` 对 clang 是**报未知选项错误**（不是静默无输出），勿混用
   - `-mllvm --print-pipeline-passes` 只打印管线结构后即返回，不是执行跟踪
   - clang 还有 `-ftime-trace`（driver 层选项，输出含 Frontend/RunPass 事件的 JSON）
3. **`--debug-pass` 合法值**：Disabled/Arguments/Structure/Executions/Details（大写开头；`structure` 小写报错）。
4. **`-print-changed=diff*` 系列在 macOS 坏**：LLVM 调系统 diff 传 GNU 专属 `--old-line-format=-%l`，BSD diff 报 unrecognized option。Linux/GNU diff 正常。quiet/cd 模式不受影响。
5. llc/clang 的 `-march=amdgcn` 已打 deprecation 警告，统一用 `-mtriple=amdgcn-amd-amdhsa`。
6. OpenCL 编译需 `-nogpulib`（本机无 ROCm）。

## 1. 观察新 PM 执行（opt）

```bash
# pass 序列 + 分析计算/失效全过程
./build-debug/bin/opt -p 'default<O1>' -debug-pass-manager -S in.ll -o /dev/null 2>&1 | grep -E "Running pass|Running analysis|Invalidating analysis" | head -50

# 只看哪些 pass 真正改变了 IR
./build-debug/bin/opt -p 'default<O1>' -print-changed=quiet -S in.ll -o /dev/null

# 文本 pipeline（与上面执行序列对照）
./build-debug/bin/opt -p 'default<O1>' -print-pipeline-passes -S in.ll -o /dev/null
```

## 2. PA 失效/重建实验（§4 核心实证）

```bash
# 实验:invalidate 击穿缓存 → 第二次 require 重建
./build-debug/bin/opt -p 'function(require<domtree>,invalidate<domtree>,require<domtree>)' \
    -debug-pass-manager -S inst-demo.ll -o /dev/null 2>&1 \
    | grep "DominatorTreeAnalysis"
# 输出:Running→Invalidating→Running→Invalidating(第二次来自 adaptor 收尾清理)

# 对照:无 invalidate → 缓存命中只算一次
./build-debug/bin/opt -p 'function(require<domtree>,require<domtree>)' \
    -debug-pass-manager -S inst-demo.ll -o /dev/null 2>&1 | grep -c "Running analysis: DominatorTreeAnalysis"
# 输出:1
```

## 3. 插桩三件套

```bash
# 计时(含硬件指令计数列)
./build-debug/bin/opt -p 'default<O1>' -time-passes -S in.ll -o /dev/null

# Chrome tracing JSON(浏览器 chrome://tracing 打开)
./build-debug/bin/opt -p 'default<O1>' -time-trace -time-trace-file=/tmp/trace.json -S in.ll -o /dev/null

# 二分定位:前 3 个 pass 跑,其余跳过
./build-debug/bin/opt -p 'default<O1>' -opt-bisect-limit=3 -S in.ll -o /dev/null
```

## 4. CodeGen 段（legacy）与 clang 全景

```bash
# llc:CodeGen 段 pass 逐条执行(带缩进层级)
./build-debug/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O3 \
    --debug-pass=Executions -o /dev/null kernel.ll 2>&1 | grep "Executing Pass"

# llc:结构树
./build-debug/bin/llc -mtriple=amdgcn-amd-amdhsa --debug-pass=Structure -o /dev/null kernel.ll

# clang:两段对拍(IR 段新 PM pipeline 串 + CodeGen 段 legacy 序列)
./build-debug/bin/clang --target=amdgcn-amd-amdhsa -mcpu=gfx1100 -O3 -nogpulib \
    -mllvm --print-pipeline-passes -c demo.cl -o /dev/null
./build-debug/bin/clang --target=amdgcn-amd-amdhsa -mcpu=gfx1100 -O3 -nogpulib \
    -mllvm --debug-pass=Executions -c demo.cl -o demo.o 2>&1 | grep "Executing Pass"
```

## 5. MIR 层（连接姊妹篇）

```bash
# 单 pass 直跑 MIR(绕过整条 pipeline)
./build-debug/bin/llc -mtriple=amdgcn-amd- -mcpu=gfx1100 -run-pass=si-insert-waitcnts -o - in.mir

# -stop-after 在任意 pass 后截断
./build-debug/bin/llc -mtriple=amdgcn-amd-amdhsa -mcpu=gfx1100 -O3 -stop-after=instruction-select -o out.mir kernel.ll
```

## 6. §5§6 补充实验（adaptor 与 LCG）

```bash
# loop pass 执行序:内层先于外层(postorder)
./build-debug/bin/opt -p 'function(loop(no-op-loop))' adapt-nested-loops.ll \
    -disable-output -debug-pass-manager 2>&1 | grep NoOpLoopPass

# 连续两个 loop(...) 段:LoopSimplify/LCSSA 重跑但 DT/AA/SE 命中缓存
./build-debug/bin/opt -p 'function(loop(no-op-loop),loop(no-op-loop))' \
    adapt-nested-loops.ll -disable-output -debug-pass-manager

# SCC 划分(postorder:callees 在前)与新 PM 只访可达 SCC
./build-debug/bin/opt -p 'cgscc(no-op-cgscc)' lcg-mutual.ll \
    -disable-output -debug-pass-manager
./build-debug/bin/opt -p 'print-callgraph-sccs' lcg-mutual.ll -disable-output

# devirt 重跑正路径:internal constant global 才能被 instcombine 折叠
./build-debug/bin/opt -p 'cgscc(devirt<4>(function(instcombine)))' \
    lcg-devirt-internal.ll -disable-output -debug-pass-manager
# 观察:InstCombinePass on caller2 出现 2 次(第二轮=devirt 检测点火)
# 对照负路径:外部可见 global(lcg-devirt.ll)只跑 1 轮——instcombine 不敢折叠

# O2 下 SCC 精化整段重跑
./build-debug/bin/opt -p 'default<O2>' lcg-mutual.ll -disable-output \
    -debug-pass-manager 2>&1 | grep -E 'DevirtSCCRepeatedPass|InlinerPass'
```

## 7. 素材用例索引（全部实测落盘，项目完结态）

- `inst-demo.ll`：print-changed/time/bisect 通用输入
- `pa-rebuild.log` / `pa-cached.log`：§4 失效实验原始输出
- `inst-print-changed-quiet.log` / `inst-bisect.log` / `inst-time-passes.log` / `inst-time-trace.json`：三件套输出
- `dualpm-*` / `inst-*` / `pa-*` / `legacy-*`：§1§4§9§10 实测产物（本目录 scratch/）
- `adapt-*`：§5 产物——adapt-nested-loops.ll（嵌套循环用例）、adapt-loop-order.txt（postorder 序）、adapt-loop-two-adaptors.txt（缓存命中对照，验收时重跑补齐）
- `lcg-*`：§6 产物——lcg-mutual.ll（互调环用例）、lcg-scc-traversal.txt、lcg-callgraph-sccs.txt（legacy 全量对照）、lcg-o2-cgscc-passes.txt（SCC 精化重跑）、lcg-default-o2-pipeline.txt（O2 单行转储）、lcg-default-o2-cgscc-segment.txt、lcg-cgscc-function.txt、lcg-devirt.ll（负路径）、lcg-devirt-internal.ll + lcg-devirt.txt（正路径，InstCombine×2）
- `core/` / `am/`：§2§3 代理产物（**在顶层 `scratch/`**，非本目录——历史落点，未搬移）
