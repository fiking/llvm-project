# 12 复现手册

工具基线：`build-debug/bin/`（LLVM 24.0.0git，Debug + Assertions）。
从仓库根目录执行；实验输入均已归档在对应目录。

## E01 展开
```bash
TB=build-debug/bin/llvm-tblgen
$TB --print-records TableGen-notes/experiments/E01-expand/input/expand.td \
  -o /tmp/expand.records
$TB --dump-json TableGen-notes/experiments/E01-expand/input/expand.td \
  -o /tmp/expand.json
# 断言（见 00-baseline.md 的 python 片段）：4 个 record，Opcode 与 Predicated 全符合
```

## E02 消解时机与负例
```bash
$TB --print-records TableGen-notes/experiments/E02-resolve/input/syntax.td
# 观察：Wide.FieldNext=65 / ParamNext=33；Named.Encoding=0x15；Description="sub.local"
$TB --print-records TableGen-notes/experiments/E02-resolve/input/wzero.td   # 退出码 1
# 期望诊断：error: assertion failed: Width must be positive（带行列）
```

## E04 MSP430 九动作
```bash
for act in gen-instr-info gen-register-info gen-asm-writer gen-emitter \
           gen-disassembler gen-asm-matcher gen-subtarget gen-dag-isel gen-callingconv; do
  build-debug/bin/llvm-tblgen -I llvm/include -I llvm/lib/Target/MSP430 \
    -$act llvm/lib/Target/MSP430/MSP430.td -o /tmp/MSP430_$act.inc
done
# 注意 -gen-register-info 会在输出同目录拆出 *{Enums,Header,MCDesc,TargetDesc}.inc
```

## E05 AMDGPU GlobalISel（大输出，注意磁盘）
```bash
build-debug/bin/llvm-tblgen -I llvm/include -I llvm/lib/Target/AMDGPU \
  -gen-global-isel -gisel-extended-llt -warn-on-skipped-patterns \
  llvm/lib/Target/AMDGPU/AMDGPUGISel.td -o /tmp/AMDGPUGenGlobalISel.inc \
  2> /tmp/gisel.stderr
# 预期：产物 ≈105 MB；stderr ≈11.7 万行 Skipped pattern 警告；耗时分钟级（Debug）
```

## E08 intrinsic
```bash
build-debug/bin/llvm-tblgen -I llvm/include \
  -gen-intrinsic-enums -intrinsic-prefix=nvvm \
  llvm/include/llvm/IR/Intrinsics.td -o /tmp/NVVMEnums.inc
build-debug/bin/llvm-tblgen -I llvm/include --print-records \
  llvm/include/llvm/IR/Intrinsics.td -o /tmp/intrinsics.records
grep -c '^def ' /tmp/intrinsics.records   # 31,668
```

## E09 Clang NoInline
```bash
CTB=build-debug/bin/clang-tblgen
$CTB -I clang/include -I llvm/include -gen-clang-attr-classes \
  clang/include/clang/Basic/Attr.td -o /tmp/AttrClasses.inc
grep -n "class CLANG_ABI NoInlineAttr" /tmp/AttrClasses.inc
```

## E10 MLIR arith
```bash
MTB=build-debug/bin/mlir-tblgen
$MTB -I mlir/include -I llvm/include -gen-op-decls \
  mlir/include/mlir/Dialect/Arith/IR/ArithOps.td -o /tmp/ArithOps.h.inc
$MTB -I mlir/include -I llvm/include -gen-op-defs \
  mlir/include/mlir/Dialect/Arith/IR/ArithOps.td -o /tmp/ArithOps.cpp.inc
$MTB -I mlir/include -I llvm/include -gen-rewriters \
  mlir/lib/Dialect/Arith/IR/ArithCanonicalization.td -o /tmp/ArithCanon.inc
```

## E12 确定性与计时
```bash
for i in 1 2; do
  build-debug/bin/llvm-tblgen -I llvm/include -I llvm/lib/Target/MSP430 \
    -gen-instr-info llvm/lib/Target/MSP430/MSP430.td -o /tmp/run$i.inc
done
shasum -a 256 /tmp/run1.inc /tmp/run2.inc   # 应相同
build-debug/bin/llvm-tblgen --time-phases --null-backend \
  -I llvm/include -I llvm/lib/Target/MSP430 llvm/lib/Target/MSP430/MSP430.td -o /dev/null
```
