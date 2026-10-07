# 核心抽象:PassInfoMixin / PassManager / type erasure(§2)

> 基准:llvm-project main @ `3eda2aebadd4`(2026-09-28)。
> 所有引用均为本仓库 `文件:行号`,经 read/grep 实测核对;动态验证用 `build-debug`(Debug+Assertions,含 AArch64/AMDGPU target)。
> 行号锚点:`llvm/include/llvm/IR/PassManager.h`(下称 PM.h,986 行)、`llvm/include/llvm/IR/PassManagerInternal.h`(下称 PMInternal.h,351 行)、`llvm/include/llvm/IR/PassManagerImpl.h`(下称 PMImpl.h,233 行)、`llvm/include/llvm/CodeGen/MachinePassManager.h`(下称 MPM.h,233 行)。
> 风格对齐 `AMDGPU-notes/01-architecture.md`。

---

## 2.0 总览:新 PM 的三层类型设计

新 PassManager 的核心思想写在 PM.h 文件头注释(PM.h:27-33):**"concept-based polymorphism"**——引用 Sean Parent 的 "Value Semantics and Concept-based Polymorphism" 与 "Inheritance Is The Base Class of Evil" 两次演讲。落地的形态是三个层次:

```text
用户层(静态类型)                类型擦除层(手工 vtable)              存储层
─────────────────────────     ──────────────────────────────      ─────────────────────
class MyPass                  detail::PassConcept                 std::vector<
  : RequiredPassInfoMixin       (PMInternal.h:41-102)               unique_ptr<PassConcept,
  <MyPass> {                     ├ Name        (StringRef)           Deleter>>
  PreservedAnalyses run(...)     ├ IsRequired  (bool)               (PM.h:250,
};                               ├ Destroy     (void(*)(...))        Passes 成员)
                                 ├ Run         (PA(*)(...))
                                 └ PrintPipeline(void(*)(...))
                                          ▲
                                          │ 被包装
                                 detail::PassModel<IRUnitT, PassT,
                                   AM, ExtraArgTs...>
                                 (PMInternal.h:108-146)
                                 ├ PassT Pass;   ← 真实对象按值存储
                                 └ 静态函数填 3 个函数指针
```

一句话:**pass 没有虚函数、没有公共基类**;`PassConcept` 也不是虚基类,而是一个持有 3 个函数指针 + 2 个数据成员的 POD 风格对象(PMInternal.h:58-70 的构造函数),通过 `PassModel` 的静态成员函数把这些指针绑定到具体 `PassT`。这与 legacy PM(`llvm/Pass.h` 的 `Pass` 基类 + `getPassName()` 虚函数 + `PassRegistry` 字符串注册)完全相反。

---

## 2.1 Pass 基类家族:PassInfoMixin / RequiredPassInfoMixin / AnalysisInfoMixin

### 2.1.1 静态分析:四个 mixin 的分工

PM.h 头部的 mixin 家族(PM.h:61-144)在 2026 年经历过一次重构,当前形态是:

| 类 | 行号 | 命名空间 | 提供 | 不提供的 |
|---|---|---|---|---|
| `detail::InfoMixin<DerivedT>` | PM.h:62-71 | `llvm::detail` | `static StringRef name()`(demangle) | — |
| `detail::PassInfoMixin<DerivedT>` | PM.h:81-89 | `llvm::detail` | `printPipeline()` | `isRequired()`(已删除) |
| `RequiredPassInfoMixin<DerivedT>` | PM.h:102-110 | `llvm`(**公开**) | `static bool isRequired() { return true; }` + `shouldSkipOptimizationForOptBisect()` | — |
| `OptionalPassInfoMixin<DerivedT>` | PM.h:113-116 | `llvm`(**公开**) | `static bool isRequired() { return false; }` | — |
| `AnalysisInfoMixin<DerivedT>` | PM.h:122-144 | `llvm`(公开) | `static AnalysisKey *ID()`(返回 `&DerivedT::Key`) | `name()`(经 InfoMixin 继承) |

**关键事实**:`detail::PassInfoMixin` **不再提供 `isRequired()`**——`git log` 可见这由 `11729f768a05 2026-05-06 "[PassManager] Make passes inherit from RequiredPassInfoMixin/OptionalPassInfoMixin" (#192120)` 引入。提交消息原文:

> "It's very easy to forget to add `isRequired() { return true; }` for passes that must be run on all IR, rather than e.g. being skipped on optnone functions. This PR adds RequiredPassInfoMixin/OptionalPassInfoMixin which have `isRequired()`, and the long term vision is there to be no default `isRequired()` on PassInfoMixin."

当时的 TODO("move to a detail namespace once we've branched for LLVM 23")已经兑现——**当前 `PassInfoMixin` 已移入 `llvm::detail` 命名空间**(PM.h:81-89),而 `RequiredPassInfoMixin`/`OptionalPassInfoMixin` 留在 `llvm` 命名空间,强制所有 pass 显式二选一。

### 2.1.2 `name()` 的 demangle 实现:__PRETTY_FUNCTION__ 字符串切片

`detail::InfoMixin<DerivedT>::name()`(PM.h:64-70)实际只有 4 行:

```cpp
static StringRef name() {
  static_assert(std::is_base_of<InfoMixin, DerivedT>::value, ...);
  StringRef Name = getTypeName<DerivedT>();       // 见下
  Name.consume_front("llvm::");
  return Name;
}
```

`getTypeName<DerivedT>()` 位于 `llvm/include/llvm/Support/TypeName.h:42`——**不是 RTTI**,而是编译期从 `__PRETTY_FUNCTION__` 里切子串。GCC/Clang 下该宏展开为:

```cpp
inline LLVM_GET_TYPE_NAME_CONSTEXPR StringRef getTypeName() {
  LLVM_GET_TYPE_NAME_CONSTEXPR std::string_view Name = __PRETTY_FUNCTION__;
  LLVM_GET_TYPE_NAME_CONSTEXPR std::string_view Key = "DesiredTypeName = ";
  // 在 __PRETTY_FUNCTION__ 中找 "DesiredTypeName = " 之后的子串,剥掉尾部 ']'
  ...
}
```

(TypeName.h:42-86)。注释(TypeName.h:31-38)明说限制:

> "We provide a function which tries to compute the (demangled) name of a type statically. This routine may fail on some platforms or for particularly unusual types. Do not use it for anything other than logging and debugging aids. It isn't portable or dependendable in any real sense."

也就是说**类型名只是调试辅助,不能当稳定标识**。`PassInstrumentation` 拿它做 `-debug-pass-manager` 输出与 `MapClassName2PassName` 查表的 key(PMImpl.h:44-47,把 ClassName 经 `PI.getPassNameForClassName()` 转成注册名)。

### 2.1.3 RequiredPassInfoMixin 的消费端:opt-bisect 与 optnone

`RequiredPassInfoMixin::isRequired()` 返回 true 之后,`isRequired()` 的最终消费者是 `PassInstrumentation`(llvm/include/llvm/IR/PassInstrumentation.h:226-245):

```cpp
template <typename IRUnitT, typename PassT>
bool runBeforePass(const PassT &Pass, const IRUnitT &IR) const {
  ...
  bool ShouldRun = true;
  if (!isRequired(Pass)) {                                       // :231
    for (auto &C : Callbacks->ShouldRunOptionalPassCallbacks)
      ShouldRun &= C(Pass.name(), IR);                           // :232-233
  }
  ...
  return ShouldRun;
}
```

注释(PassInstrumentation.h:202-207)解释了为什么这里要做静态/动态分派:`PassT` 可能是原生 pass(从 adaptor 调用时)也可能是 type-erased `PassConcept`,前者编译期可见 `isRequired` 静态函数,后者读 `PassConcept::IsRequired` 数据成员(PMInternal.h:101)。

Required/Optional 的实际差异体现在两类跳过机制:

1. **`-opt-bisect-limit=N`**:`detail::shouldSkipOptimizationForOptBisect()`(PM.h:91 声明,`llvm/lib/IR/PassManager.cpp:22-37` 定义)——只有 `RequiredPassInfoMixin` 的子类在 mixin 里实现了 `shouldSkipOptimizationForOptBisect(IR)` 成员(PM.h:107-109),它调 `OptPassGate::shouldRunPass()`;Optional pass 经 `runBeforePass` 的 `isRequired(Pass)==false` 路径走 `ShouldRunOptionalPassCallbacks`。
2. **`optnone` 属性**:`OptNoneInstrumentation`(在 `llvm/lib/Passes/StandardInstrumentations.cpp`)注册 `ShouldRunOptionalPassCallbacks` 回调,只对非 required 的 function pass 生效。

实测对照(`InstCombinePass` 当前继承 `OptionalPassInfoMixin`,见 `llvm/include/llvm/Transforms/InstCombine/InstCombine.h:49`):

```bash
$ ./build-debug/bin/opt -passes='function(instcombine)' scratch/core/t2.ll -disable-output -opt-bisect-limit=0
# InstCombinePass 被跳过(bisect 编号超 0 即全跳)

$ ./build-debug/bin/opt -passes='function(instcombine),function(verify)' ... -opt-bisect-limit=0
# VerifierPass(RequiredPassInfoMixin)仍然运行
```

### 2.1.4 AnalysisInfoMixin:为什么 Key 必须由派生类持有

`AnalysisInfoMixin<DerivedT>::ID()`(PM.h:139-143)只返回 `&DerivedT::Key`——**Key 本身由派生类以 `static AnalysisKey Key;` 成员形式提供**。PM.h:133-138 的 FIXME 注释解释了为什么不能由 mixin 统一提供:

> "FIXME: The only reason the mixin type itself can't declare the Key value is that some compilers cannot correctly unique a templated static variable so it has the same addresses in each instantiation. The only currently known platform with this limitation is Windows DLL builds, specifically building each part of LLVM as a DLL. If we ever remove that build configuration, this mixin can provide the static key as well."

由此引出 §3 的核心机制"地址即身份"(详见 03-analysis-manager.md §3.2)。

---

## 2.2 PassManager<IRUnitT>:容器、addPass、type erasure

### 2.2.1 模板签名与成员结构

PM.h:189-251:

```cpp
template <typename IRUnitT,
          typename AnalysisManagerT = AnalysisManager<IRUnitT>,
          typename... ExtraArgTs>
class PassManager : public RequiredPassInfoMixin<                   // PM.h:192-193
                        PassManager<IRUnitT, AnalysisManagerT, ExtraArgTs...>> {
  ...
protected:
  using PassConceptT = detail::PassConcept<IRUnitT, AnalysisManagerT, ExtraArgTs...>;  // :247-248
  std::vector<typename PassConceptT::unique_ptr> Passes;            // :250
};
```

只有**一个数据成员** `Passes`。PM 自身也是 pass(继承 `RequiredPassInfoMixin`,因此可以嵌套进另一个 PM),这对应注释 PM.h:177-188"pass manager is itself a valid pass over that unit of IR"。

`extern template` 显式实例化声明在 PM.h:260(`PassManager<Module>`)与 PM.h:269(`PassManager<Function>`),定义在 `llvm/lib/IR/PassManager.cpp:43-44`;`PassManager<MachineFunction>` 单独在 MPM.h:222 声明、`llvm/lib/CodeGen/MachinePassManager.cpp:28` 实例化。这套 extern template 机制使模板主体只在 3 个 .cpp 中实例化一次,控制编译时间——这也是为什么 `PassManager` 的 move 构造/赋值是手写而不是 `= default`(PM.h:198-207 的 FIXME 注释:"using = default triggers linker errors due to the explicit instantiations below")。

### 2.2.2 addPass 的 type erasure:Concept/Model 手工 vtable

`addPass`(PM.h:223-229)三行核心:

```cpp
template <typename PassT>
LLVM_ATTRIBUTE_MINSIZE std::enable_if_t<!std::is_same_v<PassT, PassManager>>
addPass(PassT &&Pass) {
  using PassModelT = detail::PassModel<IRUnitT, PassT, AnalysisManagerT, ExtraArgTs...>;
  Passes.push_back(PassModelT::create(std::move(Pass)));            // :228
}
```

`detail::PassModel`(PMInternal.h:108-146)是 type erasure 的"model"层。它继承 `PassConcept` 并在构造时把 3 个函数指针绑死到自己的静态成员函数:

```cpp
explicit PassModel(PassT &&Pass)
    : PassConceptT(PassT::name(), PassT::isRequired(),
                   destroyImpl, runImpl, printPipelineImpl),        // :138-139
      Pass(std::move(Pass)) {}                                       // 按值存储 pass

static PreservedAnalyses runImpl(PassConceptT &Self, IRUnitT &IR,
                                 AnalysisManagerT &AM, ExtraArgTs... ExtraArgs) {
  return getPass(Self).run(IR, AM, ExtraArgs...);                   // :125-129
}
```

`PassConcept` 的 5 个成员(PMInternal.h:59-64):

```cpp
StringRef Name;                 // :59   demangled 名,构造时从 PassT::name() 拷
bool IsRequired;                // :60   构造时从 PassT::isRequired() 拷
DestroyTy Destroy;              // :62   void(*)(PassConcept&)
RunTy Run;                      // :63   PA(*)(PassConcept&, IRUnitT&, AM&, ExtraArgTs...)
PrintPipelineTy PrintPipeline;  // :64   void(*)(PassConcept&, raw_ostream&, ...)
```

**这就是 2026 年的重要变化**:`6d12cf1389fa 2026-07-14 "Reapply \"[IR][NFC] Drop vtable from PassConcept/PassModel\" (#208168)" (#209414)` 把原来的虚函数(`virtual PreservedAnalyses run(...)=0`)改成了手工函数指针。类注释(PMInternal.h:37-40)解释了动机:

> "Template for the abstract base class used to dispatch over pass objects. **This doesn't use virtual functions to avoid vtables, which cost a fair amount of storage that needs to be relocated in PIC builds and add an extra indirection on dispatch.**"

即:在 PIC 构建下,每个含虚函数的对象都要带一个 vtable 指针,而 vtable 本身需要在加载时重定位;Pass 数量大时这是纯粹的浪费。手工函数指针把同样的信息放进对象体内(3 个指针 ≈ 24 字节 vs vtable 指针 8 字节,但少了 .data.rel.ro 段的 vtable 与重定位条目),还允许 `Destroy/Run/PrintPipeline` 三个函数在编译期内联到 `PassModel::runImpl/...` 的静态函数里,调用方经 `Run(*this, ...)` 间接调用即可。

**Note**:这一变化同样发生在 `AnalysisResultConcept`(PMInternal.h:152-191,只有 Destroy+Invalidate 两个函数指针)和 `AnalysisPassConcept`(PMInternal.h:265-305)上——三处共享同一套 type erasure 手法。

### 2.2.3 addPass 的同类型 PM 合并

`addPass` 对 `PassT == PassManager` 有第二个重载(PM.h:236-241):

```cpp
template <typename PassT>
LLVM_ATTRIBUTE_MINSIZE std::enable_if_t<std::is_same_v<PassT, PassManager>>
addPass(PassT &&Pass) {
  for (auto &P : Pass.Passes)
    Passes.push_back(std::move(P));                                 // 把内层 PM 的 pass 平铺进来
}
```

注释(PM.h:231-235)解释了:**同类型嵌套 PM 会被展平**,因为"we don't have use cases rely on executing nested pass managers"且"reduce implementation complexity and avoid potential invalidation issues that may happen with nested pass managers of the same type"。换句话说,`MPM.addPass(ModulePassManager{...})` 不会产生层级结构,只是把后者的 `Passes` 移动过来。`std::enable_if_t` 两个重载用 `is_same_v<PassT, PassManager>` 区分(PM.h:224 与 :237)。

### 2.2.4 run() 的签名:当前没有 static_assert

任务预设的"`run()` 里 static_assert 对 run 签名的检查"在**当前 main 上不存在**——搜遍 PM.h、PMInternal.h、PMImpl.h 全部 static_assert,只有两处:

- PM.h:65(`InfoMixin` 的 CRTP 派生检查);
- PM.h:140(`AnalysisInfoMixin` 的 CRTP 派生检查)。

run 签名的"检查"实际由**函数指针类型不匹配触发编译错误**完成:`PassModel::runImpl` 的返回类型是 `PreservedAnalyses`,函数体 `return getPass(Self).run(IR, AM, ExtraArgs...);` 若 `PassT::run` 返回 `void`,这一行的"void 转 PreservedAnalyses"会在**实例化 PassModel 时**(即 `addPass` 被调用时)由编译器拒绝——不是显式 static_assert,而是隐式类型错误。

历史对照:早期(2017-2020)`PassManager::run` 里曾有 `static_assert` 检查返回类型必须严格是 `PreservedAnalyses`,后来随 `PassConcept` 的引入移到 `PassModel::runImpl` 的返回类型约束上。**标记"待验证"**:具体哪一次 commit 移除该 static_assert 未在本轮调研。

### 2.2.5 run() 主循环与 invalidate 钩子

`PassManager<IRUnitT,...>::run` 在 PMImpl.h:27-98,与主会话精读一致,此处只列出与身份/类型相关的关键点:

1. **StackTraceEntry**(PMImpl.h:30-54):崩溃时打印 `Running pass "<PassName>" on <IRUnitName>`;`PassName` 从 `Pass->printPipeline(OS, MapClassName2PassName)` 拿——即 type erasure 后仍保留打印能力。
2. **PassInstrumentation 本身也是个 analysis**(PMImpl.h:62-64):`getResult<PassInstrumentationAnalysis>(IR, ExtraArgs...)`,通过 AM 的缓存取回。
3. **主循环**(PMImpl.h:67-89):`runBeforePass` → `Pass->run` → `AM.invalidate(IR, PassPA)` → `runAfterPass` → `PA.intersect(std::move(PassPA))`。每个 pass 的 PA 立即驱动 AM 的 invalidate,然后并入 PM 聚合的 PA。
4. **退出前 preserve 全集**(PMImpl.h:95):`PA.preserveSet<AllAnalysesOn<IRUnitT>>()`——PM 返回的 PA 表示"我管理的所有 pass 已各自 invalidate 过,剩下的都是好的"。

---

## 2.3 类型即身份:同类型 pass 两次加入 pipeline

### 2.3.1 机制:Passes 是 vector,不去重

`Passes` 是 `std::vector<unique_ptr<PassConcept>>`(PM.h:250),`addPass` 只做 `push_back`(PM.h:228)——**没有任何"按类型去重"的逻辑**。新 PM 的"身份"是**对象身份**(对象地址 + 对象内 Name),不是类型身份。两个 `InstCombinePass` 实例是两个独立的堆对象,`Passes` 里是两个独立条目,`run()` 循环顺序执行。

### 2.3.2 实测:同类型 pass 双份的 debug-pass-manager 输出

用例(`scratch/core/t2.ll`,4 条指令的 add 链):

```bash
$ ./build-debug/bin/opt -passes='function(instcombine),function(instcombine)' \
      scratch/core/t2.ll -disable-output -debug-pass-manager 2>&1
```

完整输出存于 `scratch/core/dup2.txt`,节选:

```text
Running pass: InstCombinePass on g (4 instructions)     ← 第 1 个实例
Running analysis: DominatorTreeAnalysis on g            ← 第 1 次 DT
... (其它分析)
Running pass: InstCombinePass on g (2 instructions)     ← 第 2 个实例
Running pass: VerifierPass on [module]
```

观察:

1. **两个实例都跑了**,且第 2 个实例看到 "2 instructions"(第 1 个实例已把 4 条 add 优化到 2 条)——证明第二个实例的 IR 是新鲜的。
2. **第 2 个实例没重算 DT**:`grep -c "Running analysis: DominatorTreeAnalysis" dup2.txt` = 1。原因在第 1 个实例把函数从 4 条改到 2 条时,返回的 PA **保留**了 DT(instcombine 内部使用 DT 且增量更新),所以 `AM.invalidate` 没把它杀掉;第 2 个实例直接命中缓存。
3. **两个实例的输出名完全相同**("InstCombinePass"):这就是"类型即身份"的代价——**`-debug-pass-manager` 无法区分同一类型的两次运行**。要区分只能靠序号(行号)或前后 context。

对照组(输入 IR 已最优,`scratch/core/t.ll`):

```text
Running pass: InstCombinePass on f (3 instructions)     ← 第 1 个,返回 PA=all(没改)
... 没有 Invalidating
Running pass: InstCombinePass on f (3 instructions)     ← 第 2 个,3 instructions 不变
```

(存于 `scratch/core/dup-instcombine.txt`)。PA=all 时不触发任何 invalidate,所以 DT 只跑 1 次。

### 2.3.3 设计后果

- **类型不是实例 ID**:同一类型可多次加入,每次一个独立堆对象。print<...> 的 demangle 名无法区分实例,`MapClassName2PassName` 也只会把同一个 ClassName 映射到同一个注册名。
- **debug 输出的"重名"**:多次运行同类型 pass 在 `-debug-pass-manager` 里看起来一样,只能依靠 `on <IRUnit> (N instructions)` 的指令数间接分辨是否生效。
- **adaptor 的"类型多重身份"**:`ModuleToFunctionPassAdaptor` 只有一个类型,但内部可以装不同 function pass——它的 `printPipeline`(PM.h:889-891)打印成 `function(...)` 包裹内层名字,所以 debug 输出仍能区分。

---

## 2.4 MachineFunction 层:复用与差异

### 2.4.1 MachineFunctionPassManager 就是 PassManager<MachineFunction>

MPM.h:225:

```cpp
using MachineFunctionPassManager = PassManager<MachineFunction>;
```

**不是新类**——直接 typedef 到 IR PassManager 模板。成员结构(`Passes` 容器、Concept/Model type erasure、addPass)**全部复用**。差异只在 `run()` 的特化:

```cpp
// MPM.h:219-222
template <>
LLVM_ABI PreservedAnalyses PassManager<MachineFunction>::run(
    MachineFunction &, AnalysisManager<MachineFunction> &);
extern template class PassManager<MachineFunction>;
```

显式特化定义在 `llvm/lib/CodeGen/MachinePassManager.cpp:143-160`,与通用模板(PMImpl.h:27-98)的主体几乎逐行一致,但少了 `StackTraceEntry`(crash 时打印哪个 pass 在跑)——因为 MachineFunction 不像 Function/Module 有 `printIRUnitNameForStackTrace` 的特化。

### 2.4.2 MachineFunctionPass 的"不返回 PA"是历史

任务提到的"MachineFunctionPass 的 run 签名不返回 PA"对应**新 PM 引入 MachineFunction 支持的早期阶段**(约 2019-2023)。当前 main 上:

- **legacy `MachineFunctionPass`**(`llvm/include/llvm/CodeGen/MachineFunctionPass.h:31`)继承 legacy `FunctionPass`,签名 `virtual bool runOnMachineFunction(MachineFunction &MF) = 0;`(:47)——返回 bool,**与新 PM 无关**;
- **新 PM 的 machine function pass** 是普通类,`run(MachineFunction &MF, MachineFunctionAnalysisManager &AM)` 返回 **`PreservedAnalyses`**,与 IR pass 完全一致。

抽样验证(全部在新 PM 头文件):

| Pass | 头文件 | run 签名 |
|---|---|---|
| MachineVerifierPass | llvm/include/llvm/CodeGen/MachineVerifier.h:23 | `PreservedAnalyses run(MachineFunction &, MachineFunctionAnalysisManager &)` |
| FuncletLayoutPass | llvm/include/llvm/CodeGen/FuncletLayout.h:18 | 同上 |
| TwoAddressInstructionPass | llvm/include/llvm/CodeGen/TwoAddressInstructionPass.h:19 | 同上 |
| LiveDebugVariablesPass | llvm/include/llvm/CodeGen/LiveDebugVariables.h:118 | 同上 |
| SelectionDAGISelPass | llvm/include/llvm/CodeGen/SelectionDAGISel.h:593 | 同上 |

也就是说**当前的"MachineFunctionPass"在新 PM 下与 IR pass 完全同构**。历史上的"返回 void"阶段可以追溯到 commit `91e9e3175268 "[NewPM/CodeGen] Rewrite pass manager nesting (#81068)"` 之前——该提交重写了 codegen 的嵌套结构,把 machine function pass 从"不返回 PA、不能 invalidate"迁移到与 IR pass 统一的语义。**待验证**:具体哪一次提交把签名从 `void run(...)` 改为 `PreservedAnalyses run(...)`(可能与 #81068 同期)。

### 2.4.3 MachineFunctionAnalysisManager 的 Key(:185 一带)

MPM.h:104-121 定义了两个 MFAM 的"内层 proxy"类型别名:

```cpp
using MachineFunctionAnalysisManagerModuleProxy =
    InnerAnalysisManagerProxy<MachineFunctionAnalysisManager, Module>;         // :104-105

using MachineFunctionAnalysisManagerFunctionProxy =
    InnerAnalysisManagerProxy<MachineFunctionAnalysisManager, Function>;       // :113-114
```

它们的 `static AnalysisKey Key` **不是手写声明**,而是来自 `InnerAnalysisManagerProxy` 模板自己的静态成员(PM.h:682 `static AnalysisKey Key;`,定义在 PM.h:693-695,带 `LLVM_ATTRIBUTE_VISIBILITY_DEFAULT`——注释 :687-692 解释了为什么不能用 `LLVM_ABI`:MSVC C2720 不允许在类外给成员函数加 storage-class)。这与 `DominatorTreeAnalysis::Key` 的"手写 static + LLVM_ABI"(`llvm/include/llvm/IR/Dominators.h:243`)形成对比——**模板类的 Key 让编译器自动生成,手写类的 Key 必须手动导出**。

MPM.h:185 还有第三个 proxy:

```cpp
class FunctionAnalysisManagerMachineFunctionProxy
    : public AnalysisInfoMixin<FunctionAnalysisManagerMachineFunctionProxy> {  // :129-130
  ...
  LLVM_ABI static AnalysisKey Key;                                             // :185
  ...
};
```

这是**手写类**,不是模板别名——因为 FAM→MF 的方向需要一个自定义的 `invalidate`(MachineFunction 层不能反过来 invalidate Function 分析),`llvm/lib/CodeGen/MachinePassManager.cpp:37-43` 把它写成"return false; MachineFunction passes should not invalidate Function analyses. TODO: verify that PA doesn't invalidate Function analyses."。这个手写类的 Key 在 `MachinePassManager.cpp:24` 定义(`AnalysisKey FunctionAnalysisManagerMachineFunctionProxy::Key;`)。

### 2.4.4 extern template 的作用

MPM.h:123-127 的 `extern template class LLVM_TEMPLATE_ABI OuterAnalysisManagerProxy<ModuleAnalysisManager, MachineFunction>` 与 :111-112 的 `extern template class InnerAnalysisManagerProxy<MachineFunctionAnalysisManager, Module>` 把"模板实例化"的责任集中到 `llvm/lib/CodeGen/MachinePassManager.cpp:26-35`:

```cpp
template class LLVM_EXPORT_TEMPLATE AnalysisManager<MachineFunction>;                       // :27
template class PassManager<MachineFunction>;                                                // :28
template class LLVM_EXPORT_TEMPLATE InnerAnalysisManagerProxy<MachineFunctionAnalysisManager, Module>;      // :29-30
template class LLVM_EXPORT_TEMPLATE InnerAnalysisManagerProxy<MachineFunctionAnalysisManager, Function>;    // :31-32
template class LLVM_EXPORT_TEMPLATE OuterAnalysisManagerProxy<ModuleAnalysisManager, MachineFunction>;      // :33-34
```

作用:

1. **编译时间**:模板代码只在 MachinePassManager.cpp 中实例化一次,其它 codegen .cpp 链接这个实例,避免每个 TU 重复实例化。
2. **Windows DLL 正确性**:`LLVM_EXPORT_TEMPLATE`/`LLVM_TEMPLATE_ABI` 宏保证跨 DLL 边界的符号可见性与 static 成员唯一性(否则 MFAM 的静态 `Key` 会在不同 DLL 中各有一份,地址不同,身份系统崩溃——参见 §3.2)。
3. **`PassManager<MachineFunction>::run` 的特化配合**:extern template 在 MPM.h:222 声明,防止编译器在 include 了 MPM.h 的 TU 里隐式实例化 `PassManager<MachineFunction>`(那样会用通用模板实现,覆盖显式特化)。

### 2.4.5 共享 vs 重写一览

| 组件 | MachineFunction 层 | 来源 |
|---|---|---|
| `Passes` 容器、`addPass`、`isEmpty` | 完全复用 | PM.h:189-251 |
| `PassConcept`/`PassModel` type erasure | 完全复用 | PMInternal.h:41-146 |
| `PassManager::run` 主循环 | **显式特化**(几乎相同,少 StackTraceEntry) | MPM.h:219-221 + MachinePassManager.cpp:143-160 |
| `AnalysisManager<MachineFunction>` | typedef + extern template | MachineFunctionAnalysisManager.h(整个文件 26 行) |
| Module→MF proxy | typedef 到 `InnerAnalysisManagerProxy<MFAM, Module>` | MPM.h:104-105 |
| Function→MF proxy | typedef 到 `InnerAnalysisManagerProxy<MFAM, Function>` | MPM.h:113-114 |
| MF→Module proxy | typedef 到 `OuterAnalysisManagerProxy<MAM, MachineFunction>` | MPM.h:123-127 |
| MF→Function proxy | **手写类**(invalidate 永远 return false) | MPM.h:129-189 |
| Function→MF adaptor | `FunctionToMachineFunctionPassAdaptor` | MPM.h:191-208,run 在 MachinePassManager.cpp:111-134 |

**核心观察**:除 run 显式特化和一个手写 proxy 外,**MachineFunction 层零代码复制**——这正是把 IR PassManager 设计成 `IRUnitT` 模板的红利。

### 2.4.6 getMachineFunctionPassPreservedAnalyses:MF 不动 IR 的硬约束

MachinePassManager.cpp:162-169:

```cpp
PreservedAnalyses llvm::getMachineFunctionPassPreservedAnalyses() {
  PreservedAnalyses PA;
  // Machine function passes are not allowed to modify the LLVM
  // representation, therefore we should preserve all IR analyses.
  PA.template preserveSet<AllAnalysesOn<Module>>();
  PA.template preserveSet<AllAnalysesOn<Function>>();
  return PA;
}
```

machine function pass 不允许改 LLVM IR(这是 legacy `MachineFunctionPass` 类注释 `MachineFunctionPass.h:9-14` 的延续:"MachineFunctionPass's are not allowed to modify the LLVM representation"),所以 PM 层强制每个 machine function pass 的 PA 至少保留全部 module/function 分析。这是**新 PM 把 IR 与 MIR 分开 invalidation 的关键**——MIR 变化不会触发 FAM/MAM 的 invalidate。

---

## 2.5 实测:opt vs llc 的 pass 身份表示差异

### 2.5.1 测试方法

同一逻辑输入(`scratch/core/t2.ll`,4 条 add 指令),分别在:

- **opt 新 PM**:`-debug-pass-manager`;
- **llc legacy PM**:`--debug-pass=Executions`(llc 默认);
- **llc 新 PM**:`--enable-new-pm --debug-pass-manager`(只 AMDGPU 实现了 `buildCodeGenPipeline`,AArch64 报 "buildCodeGenPipeline is not overridden")。

数据文件:

- `scratch/core/dup-instcombine.txt` / `dup2.txt`(opt 新 PM,§2.3)
- `scratch/core/llc-executions.txt`(llc legacy,AArch64,734 行)
- `scratch/core/llc-newpm.txt`(llc 新 PM,AMDGPU gfx1100,167 个 pass)

### 2.5.2 输出对比

**opt 新 PM**(`dup2.txt`):

```text
Running pass: InstCombinePass on g (4 instructions)
Running analysis: DominatorTreeAnalysis on g
Running pass: RequireAnalysisPass<llvm::DominatorTreeAnalysis, llvm::Function, llvm::AnalysisManager<Function>> on g (4 instructions)
```

**llc 新 PM**(`llc-newpm.txt`,AMDGPU):

```text
Running pass: RAGreedyPass on g
Running pass: VirtRegRewriterPass on g
Running pass: RAGreedyPass on g          ← 同类型 pass 第 2 次
Running pass: VirtRegRewriterPass on g
Running pass: RAGreedyPass on g          ← 同类型 pass 第 3 次
Running pass: VirtRegRewriterPass on g
Running pass: PostMachineSchedulerPass on g
```

**llc legacy PM**(`llc-executions.txt`,AArch64):

```text
[2026-09-30 14:12:48.699951000] 0x13a905aa0     Executing Pass 'Greedy Register Allocator' on Function 'g'...
[2026-09-30 14:12:48.701007000] 0x13a905aa0     Executing Pass 'Virtual Register Rewriter' on Function 'g'...
[2026-09-30 14:12:48.706014000] 0x13a905aa0     Executing Pass 'PostRA Machine Instruction Scheduler' on Function 'g'...
```

### 2.5.3 三种身份格式的本质

| 维度 | 新 PM(`-debug-pass-manager`) | legacy PM(`--debug-pass=Executions`) |
|---|---|---|
| 名字来源 | `PassT::name()` → `getTypeName<PassT>()` → `__PRETTY_FUNCTION__` 切片 | `Pass::getPassName()`(虚函数,默认从 `PassInfo` 注册表的 `getPassName()`) |
| 形式 | demangled C++ 类型名(`RAGreedyPass`、`InstCombinePass`) | 注册表可读字符串(`'Greedy Register Allocator'`) |
| 实例区分 | 不区分(同类型同名字) | 不区分(同一 pass ID 同名字) |
| 模板参数 | 可见(如 `RequireAnalysisPass<llvm::DominatorTreeAnalysis, ...>`) | 不可见(legacy 无模板) |
| 时间戳 | 无 | 有(`[YYYY-MM-DD HH:MM:SS.usec]`) |
| 线程 ID | 无 | 有(`0x13a905aa0` 一列) |
| Freeing 事件 | 无 | 有(每个 pass 析构时打印 `Freeing Pass ...`) |

**观察**:新 PM 的 `RAGreedyPass` 在 llc-newpm.txt 出现 3 次(对应 SGPR/VIRT/WWM 三段式寄存器分配,见 AMDGPU-notes/01-architecture.md §3.3.2),`VirtRegRewriterPass` 也 3 次——**类型名重复出现是新 PM 的常态**,同一段流水线中多次实例化同一类型的现象直接暴露在日志里。legacy PM 的 `'Greedy Register Allocator'` 在 llc-executions.txt 只出现 1 次,因为 legacy 的 RA 走不同结构(legacy greedy 是单个 pass,一次性做完,不分三段)。

---

## 2.6 自查表

| # | 断言 | 证据 | 状态 |
|---|---|---|---|
| 1 | `RequiredPassInfoMixin`/`OptionalPassInfoMixin` 2026-05 引入,`PassInfoMixin` 移入 detail | PM.h:81-116 + git 11729f768a05 | 已核实 |
| 2 | `name()` 基于 `__PRETTY_FUNCTION__` 切片,不是 RTTI | PM.h:64-70 + TypeName.h:42-86 | 已核实 |
| 3 | `PassConcept` 无 vtable,用 3 个函数指针 | PMInternal.h:37-101 + git 6d12cf1389fa | 已核实 |
| 4 | `Passes` 是 `vector<unique_ptr<PassConcept>>`,addPass 不去重 | PM.h:223-250 | 已核实 |
| 5 | 当前 run() 无 static_assert 检查返回类型 | grep 全 PM.h/PMInternal.h/PMImpl.h | 已核实(仅 2 处 static_assert,均在 mixin CRTP 检查) |
| 6 | 同类型 pass 可多次加入,`-debug-pass-manager` 显示同名 | scratch/core/dup2.txt | 已实测 |
| 7 | `MachineFunctionPassManager = PassManager<MachineFunction>` 直接 typedef | MPM.h:225 | 已核实 |
| 8 | `PassManager<MachineFunction>::run` 显式特化,无 StackTraceEntry | MPM.h:219-221 + MachinePassManager.cpp:143-160 | 已核实 |
| 9 | MFAM 的 proxy Key 经模板静态成员自动生成(MSVC 注释 PM.h:687-692) | PM.h:682,693-695;MPM.h:104-127 | 已核实 |
| 10 | `FunctionAnalysisManagerMachineFunctionProxy` 是手写类,Key 在 :185 | MPM.h:129-189 + MachinePassManager.cpp:24 | 已核实 |
| 11 | 新 PM machine function pass 返回 `PreservedAnalyses` | 抽验 MachineVerifier.h:23 等 5 个头文件 | 已核实 |
| 12 | legacy `--debug-pass=Executions` 输出注册字符串,新 PM 输出 demangled 类型名 | scratch/core/llc-executions.txt vs llc-newpm.txt | 已实测 |
| 13 | run 返回 void 会触发编译错误而非运行时错误 | PMInternal.h:125-129 隐式类型检查 | 已核实(机制) |
| 14 | 新 PM run 返回 void → PA 隐式转换的具体 commit 移除点 | git 历史 | **待验证** |
| 15 | MachineFunction pass 历史上"返回 void"的确切时间点 | git 历史 | **待验证** |
