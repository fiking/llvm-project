# 11 设计判断（笔记）

正文第 11 章的论据来源汇总：

- "schema 即接口"：CodeGenTarget.cpp:81 / CodeGenInstruction.cpp:87 的字符串匹配
  （`getAllDerivedDefinitions("Target")` / `isSubClassOf("RegisterOperand")`）。
- 手写边界的三个具体实例：
  1. Clang NoInline → IR 属性（CodeGenModule.cpp:3236-3239，手写 else-if）。
  2. MLIR AddIOp::fold（ArithOps.cpp:433，手写）vs hasFolder=1 只生声明。
  3. 调度：表是生成的，TargetSchedule.cpp:117 resolveSchedClass 是手写的。
- 重复即生成的反证：ClangAttrEmitter.cpp:3438 注释（switch 代替虚函数）。
- 新 emitter 起步骨架：llvm/lib/TableGen/TableGenBackendSkeleton.cpp（E03 未做，
  正文已注明）。
- GISel 拒绝率：E05 实测 117,672 行 skipped 警告（AMDGPU 全量）——
  "手写 selector 补充"是常态工作方式，不是例外。
- 迁移三口径警告：E08（31,668 def / 2,797 枚举 / 源行数互不相等）。
