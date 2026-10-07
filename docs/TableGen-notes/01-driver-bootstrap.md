# 01 定位、驱动与构建引导（笔记）

## 入口链路（静态锚点，LLVM 24.0.0git）

```
llvm/utils/TableGen/llvm-tblgen.cpp:18   main()
  └─ llvm/utils/TableGen/Basic/TableGen.cpp:72  tblgen_main()
       └─ llvm/lib/TableGen/Main.cpp:140        TableGenMain(argv0, MainFn=nullptr)
            ├─ Main.cpp:150-168  读文件→SrcMgr→TGParser(SrcMgr, MacroNames, Records, …)→ParseFile()
            ├─ Main.cpp:174      ErrorsPrinted>0 ⇒ 退出码 1
            ├─ Main.cpp:178-188  TableGen::Emitter::ApplyCallback(Records, OutFiles, stem)
            ├─ Main.cpp:194-197  -d ⇒ createDependencyFile（总是写，Ninja 视缺失为 dirty）
            └─ Main.cpp:199-211  WriteOutput（--write-if-changed 比对；多文件 AdditionalFiles）
```

## 动作注册机制

- `TableGen::Emitter::Opt`（include/llvm/TableGen/TableGenBackend.h:53）构造时向全局
  `ManagedStatic<cl::opt<FnT>>` 注册字面量选项（TableGenBackend.cpp:53-59）。
- 内置动作在 Basic/TableGen.cpp:58-70 的静态数组：
  `print-records`（默认）、`print-detailed-records`、`null-backend`、`dump-json`、
  `print-enums`、`print-sets`。
- 其余 emitter（EmitInstrInfo、EmitRegisterInfo、…）各自在 llvm/utils/TableGen/*.cpp
  顶层以静态 `Opt`/`OptClass` 对象注册 —— 链接哪些 .cpp 就有哪些 `-gen-*`。
- `FnT` 双形态（TableGenBackend.h:30-47）：单文件 `void(RK, raw_ostream&)` 或
  多文件 `TableGenOutputFiles(StringRef, RK)`；`-gen-register-info` 用后者拆出
  Enums/Header/MCDesc/TargetDesc 四个文件（实验 E04 已验证 535B 骨架 + 拆分文件）。

## llvm-tblgen vs llvm-min-tblgen（llvm/utils/TableGen/CMakeLists.txt）

- llvm-min-tblgen（:19-24）：只链接 `obj.LLVMTableGenBasic`，不含 TableGenCommon。
  原因（注释 :11-18）：TableGenCommon 自己需要用 min-tblgen 生成 ValueType 等 —— 自举。
- llvm-tblgen（:31-83）：Basic + Common + 50+ emitter 源文件；
  `DEPENDS intrinsics_gen`（该 target 本身由 min-tblgen 生成）。
- 两文件 main 完全相同（llvm-tblgen.cpp:18 / llvm-min-tblgen.cpp:18）。

## 嵌入式入口

`llvm/lib/TableGen/Parser.cpp:17-43` 的 `TableGenParseFile(SourceMgr&, RecordKeeper&)`
供库内使用（如 MLIR 侧）；它不是 CLI 必经路径 —— CLI 由 Main.cpp 直接构造 TGParser。

## 三时刻边界（本研究全程遵守）

1. TableGen 运行时：解析 .td → 生成 .inc（E01/E02/E04/E05/E08/E09/E10 均在此层验证）。
2. C++ 构建时：.inc 被 include 编译（E09/E10 只做到 include 点的静态定位）。
3. 编译器运行时：算法读表（本研究只定位查询点符号，未做运行时行为验证）。
