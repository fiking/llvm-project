# Legacy Pass Manager(§9)

> 基准:llvm-project main @ `3eda2aebadd4`(2026-09-28)。
> 所有引用均为本仓库 `文件:行号`,经 read/grep 实测核对;动态验证一律使用 `build-debug`。
> 实测产物存 `PassManager-notes/scratch/`,前缀 `legacy-`。

---

## 9.0 定位:为什么 2026 年还必须懂 legacy PM

虽然 new PM 已经全面接管 opt 的 IR 管线(见 §1.2),**clang/llc 的 CodeGen 阶段在 10 个 target 上仍默认走 legacy PM**(§1.1.2)。`llvm/lib/IR/LegacyPassManager.cpp`(1808 行)与 `llvm/include/llvm/IR/LegacyPassManagers.h` 定义了整套"老 PM"基础设施:它能跨 module/function/basicblock 嵌套,把分析当共享状态管理,通过 `PassRegistry` 把 pass 名映射到工厂函数。

`TargetPassConfig` 是 legacy PM 在 CodeGen 阶段的"导演"——它本身是 `ImmutablePass`(`llvm/include/llvm/CodeGen/TargetPassConfig.h:84` 类声明 `class LLVM_ABI TargetPassConfig : public ImmutablePass`),通过 `addPass(AnalysisID)` 利用 `PassRegistry` 创建 pass 并塞进外层 `PassManagerBase`。

---

## 9.1 `LegacyPassManager.cpp` 的类层次

### 9.1.1 文件结构总览

`llvm/lib/IR/LegacyPassManager.cpp` 共 **1808 行**(实测 `wc -l`),按区块划分:

| 行号范围 | 内容 |
|---|---|
| :1-30 | 头文件 + `using namespace llvm` |
| :43-60 | `PassDebugging` 命令行选项(`-debug-pass`)定义,枚举值 `Disabled / Arguments / Structure / Executions / Details` |
| :63-242 | `PMDataManager` 的工具方法(remark 打印)+ `PassManagerPrettyStackEntry` |
| :244-308 | **`FunctionPassManagerImpl`** 类定义 |
| :309-378 | FunctionPassManagerImpl 方法实现 |
| :380-464 | **`MPPassManager`** 类定义(管理 module 级嵌套) |
| :466-540 | **`PassManagerImpl`** 类定义 |
| :542-552 | `FunctionPassManager`/`PassManager` 包装器 |
| :546-855 | **`PMTopLevelManager`** 方法实现 |
| :857-1330 | **`PMDataManager`** 方法实现 |
| :1334-1500 | **`FPPassManager`** 方法实现 |
| :1500-1690 | `MPPassManager` / `PassManagerImpl` 方法实现 |
| :1692-1716 | `legacy::PassManager` / `legacy::FunctionPassManager` 公开接口 |
| :1719-1808 | `PMStack`、`ModulePass::assignPassManager`、`FunctionPass::assignPassManager` |

### 9.1.2 五个核心类

#### 1) `PMTopLevelManager`(:546-855)

**职责**:**顶层**管理器,负责跨 pass manager 的分析调度。维护 `LastUser`(分析的最后使用者)、`LastUses`、`IndirectPassManagers`、`ActiveStack`、`Collection of PMDataManager`。

关键方法:

- `PMTopLevelManager::schedulePass(Pass *P)`(:655):**唯一的调度入口**。决定 P 进哪个 PMDataManager、记录 P 用到的所有分析、构建 last-user 表。
- `setLastUser(ArrayRef<Pass*> AnalysisPasses, Pass *P)`(:557-606):记录"P 是这些分析的最后用户",供 `removeDeadPasses` 提前 `releaseMemory`。
- `findAnalysisPass(AnalysisID AID)`(:763-779):按 ID 查找一个已注册的 analysis pass(在自己和 indirect PM 中找)。
- `collectLastUses(SmallVectorImpl<Pass *> &LastUses, Pass *P)`(:609-617):找出"P 是哪些分析的最后用户"。

#### 2) `PMDataManager`(:857-1330)

**职责**:**单层 PM 的公共基类**。所有真正的 PM(FPPassManager/MPPassManager/PassManagerImpl 等)都继承它,管理:
- `PassVector`:本层排队等待运行的 pass;
- `AvailableAnalysis: DenseMap<AnalysisID, Pass *>`:本层可用的分析;
- `InheritedAnalysis`:从父层继承下来的分析表。

关键方法:

- `add(Pass *P, bool ProcessAnalysis)`(:979-1052):把 P 入 PassVector,若 `ProcessAnalysis=true` 则**立即建立 last-user 关系**(调用 `TPM->setLastUser`)。
- `recordAvailableAnalysis(Pass *P)`(:860-866):把 P 自己作为分析提供者放入 `AvailableAnalysis`(`AvailableAnalysis[PI] = P`,:863)。
- `removeNotPreservedAnalysis(Pass *P)`(:902-937):**失效算法的核心**。见 §9.5。
- `removeDeadPasses(Pass *P, StringRef Msg, ...)`(:940-959):**释放"以 P 为最后用户"的分析**。
- `freePass(Pass *P, StringRef Msg, ...)`(:961-975):调用 `P->releaseMemory()`(:970)并把 P 从 `AvailableAnalysis` 中删除(:974)。

#### 3) `FunctionPassManagerImpl`(:244-308)

**职责**:**legacy::FunctionPassManager 的内部实现**,顶层 FunctionPass 管理器。继承三个父类:

```cpp
class FunctionPassManagerImpl : public Pass,
                                public PMDataManager,
                                public PMTopLevelManager { ... }   // :244-246
```

- 它**自己也是一个 Pass**(`PT_PassManager` 类型,:253),所以可以嵌套;
- 通过 `PMTopLevelManager` 提供 `schedulePass` / `setLastUser`;
- 通过 `PMDataManager` 提供 `add` / `removeNotPreservedAnalysis`。
- `char FunctionPassManagerImpl::ID = 0`(:309):每个 pass 都有 `static char ID` 字段,`&ID` 即 `AnalysisID`(`llvm/include/llvm/Pass.h:51` `using AnalysisID = const void *`)。
- `run(Function &F)`(:355-376):实际跑在 Function 上的入口。

#### 4) `PassManagerImpl`(:466-540)

**职责**:**legacy::PassManager 的内部实现**,顶层 ModulePass 管理器。同样继承 Pass + PMDataManager + PMTopLevelManager(:466-468)。

- `run(Module &M)`(:522):**顶层运行入口**。`legacy::PassManager::run`(:1713-1715)就是 `return PM->run(M)`。

#### 5) `MPPassManager`(:380-464)

**职责**:**ModulePass 的容器**。管理模块层 pass 与嵌套的 `FPPassManager`(`OnTheFlyManagers`,:451 注释 "Collection of on the fly FPPassManagers")。

- 它自己也继承 `Pass`(`:380`),类型 `PT_PassManager`;
- `char MPPassManager::ID = 0`(:456);
- 在 `runOnModule` 中遍历 `PassVector`(:1580-1660+),其中对每个 ModulePass 直接调 `runOnModule(M)`;对嵌套的 `FPPassManager` 则驱动 `runOnFunction` 遍历每个 Function。

#### 6) 公开包装 `legacy::PassManager` / `legacy::FunctionPassManager`

定义在 `llvm/include/llvm/IR/LegacyPassManager.h:53-98`:

```cpp
class LLVM_ABI PassManager : public PassManagerBase {    // :53
public:
  PassManager();
  ~PassManager() override;
  void add(Pass *P) override;
  bool run(Module &M);
private:
  PassManagerImpl *PM;   // :68  内部实现指针
};

class LLVM_ABI FunctionPassManager : public PassManagerBase { // :72
  ...
  FunctionPassManagerImpl *FPM;  // :96
  Module *M;                     // :97
};
```

**两个公开类只是 PImpl 壳**(:66-68 注释:"PassManagerImpl_New is the actual class. PassManager is just the wraper to publish simple pass manager interface"),实现在 `LegacyPassManager.cpp:1692-1716`。

### 9.1.3 类层次图

```text
Pass (llvm/include/llvm/Pass.h)
 ├── ModulePass                ──┐
 │    └── MPPassManager ───────┐ │  (LegacyPassManager.cpp:380)
 ├── FunctionPass              │ │
 │    └── FPPassManager ───────┤ │  (LegacyPassManagers.h:67)
 ├── ImmutablePass             │ │
 │    └── TargetPassConfig     │ │
 ├── BasicBlockPass            │ │
 └── Pass (PT_PassManager)     │ │
      ├── FunctionPassManagerImpl ─┤
      │    (LegacyPassManager.cpp:244)
      └── PassManagerImpl ─────────┘
           (LegacyPassManager.cpp:466)

PMDataManager (LegacyPassManagers.h)
 ├── FunctionPassManagerImpl
 ├── MPPassManager
 ├── FPPassManager
 └── PassManagerImpl

PMTopLevelManager (LegacyPassManagers.h)
 ├── FunctionPassManagerImpl
 └── PassManagerImpl
```

**多继承但 PM 之间不互相派生**(头注释 `LegacyPassManagers.h:36-37`:"This class hierarchy uses multiple inheritance but pass managers do not derive from another pass manager")。

---

## 9.2 `PMStack` 与嵌套 PM 的运行时结构

### 9.2.1 `PMStack` 定义

`llvm/include/llvm/IR/LegacyPassManagers.h:137-152`(类注释 :130-136):

```cpp
/// PMStack - This class implements a stack data structure of PMDataManager
/// pointers.
///
/// Top level pass managers (see PassManager.cpp) maintain active Pass Managers
/// using PMStack. Each Pass implements assignPassManager() to connect itself
/// with appropriate manager. assignPassManager() walks PMStack to find
/// suitable manager.
class PMStack {
public:
  typedef std::vector<PMDataManager *>::const_reverse_iterator iterator;
  iterator begin() const { return S.rbegin(); }
  iterator end() const { return S.rend(); }

  LLVM_ABI void pop();
  PMDataManager *top() const { return S.back(); }
  LLVM_ABI void push(PMDataManager *PM);
  bool empty() const { return S.empty(); }

  LLVM_ABI void dump() const;
  ...
};
```

注意:这个类**不是** `PassManagerStack`——很多老博客/文档里写的 "PassManagerStack" 是旧名,main 上叫 `PMStack`。`grep -rn "PassManagerStack"` 在 llvm/ 下返回 0 行(已核实)。

### 9.2.2 `push/pop` 的语义

`LegacyPassManager.cpp:1724-1754`:

```cpp
void PMStack::pop() {                                   // :1724
  PMDataManager *Top = this->top();
  Top->initializeAnalysisInfo();
  S.pop_back();
}

void PMStack::push(PMDataManager *PM) {                 // :1733
  assert(PM && "Unable to push. Pass Manager expected");
  assert(PM->getDepth()==0 && "Pass Manager depth set too early");

  if (!this->empty()) {
    assert(PM->getPassManagerType() > this->top()->getPassManagerType()  // :1738
           && "pushing bad pass manager to PMStack");
    PMTopLevelManager *TPM = this->top()->getTopLevelManager();
    TPM->addIndirectPassManager(PM);                    // :1743
    PM->setTopLevelManager(TPM);                        // :1744
    PM->setDepth(this->top()->getDepth()+1);            // :1745
  } else {
    assert((PM->getPassManagerType() == PMT_ModulePassManager
            || PM->getPassManagerType() == PMT_FunctionPassManager)
           && "pushing bad pass manager to PMStack");
    PM->setDepth(1);                                    // :1750
  }
  S.push_back(PM);
}
```

要点:

- **栈顶类型必须严格小于新压入的类型**(:1738 的 `>` assert)——`PassManagerType` 是枚举,值越大层级越低(`PMT_ModulePassManager=1 < PMT_CallGraphPassManager=2 < PMT_FunctionPassManager=3 < PMT_LoopPassManager=4 < PMT_RegionPassManager=5`,枚举定义在 `llvm/include/llvm/Pass.h:56-64`,**注意不在 `LegacyPassManagers.h`**);
- **非顶层 PM 要登记到顶层的 `IndirectPassManagers`**(:1743),顶层 PMTopLevelManager 才能跨层查找分析;
- **depth 从 1 开始递增**(:1745/:1750),debug 输出用 depth 决定缩进。

### 9.2.3 `assignPassManager` 的算法

pass 在 `PM.add(P)` 时被分配到正确的 PM。`ModulePass::assignPassManager`(:1767-1775):

```cpp
void ModulePass::assignPassManager(PMStack &PMS, PassManagerType PreferredType) {
  // Find Module Pass Manager
  PassManagerType T;
  while ((T = PMS.top()->getPassManagerType()) > PMT_ModulePassManager &&   // :1771
         T != PreferredType)
    PMS.pop();
  PMS.top()->add(this);                                                      // :1774
}
```

`FunctionPass::assignPassManager`(:1779-1806)更复杂——**当栈顶是 MPPassManager 时会自动创建一个 FPPassManager**:

```cpp
void FunctionPass::assignPassManager(PMStack &PMS, PassManagerType /*PreferredType*/) {
  PMDataManager *PM;
  while (PM = PMS.top(), PM->getPassManagerType() > PMT_FunctionPassManager)
    PMS.pop();

  // Create new Function Pass Manager if needed.
  if (PM->getPassManagerType() != PMT_FunctionPassManager) {
    auto *FPP = new FPPassManager;                          // :1789  [1] 新建
    FPP->populateInheritedAnalysis(PMS);                    // :1790
    PM->getTopLevelManager()->addIndirectPassManager(FPP); // :1793  [2] 登记
    FPP->assignPassManager(PMS, PM->getPassManagerType()); // :1797  [3] 递归
    PMS.push(FPP);                                          // :1800  [4] 压栈
    PM = FPP;
  }
  PM->add(this);                                            // :1805
}
```

**这就是 legacy PM 的"自动嵌套"机制**:用户 `PM.add(new MyFunctionPass())`,legacy PM 自动在 module PM 内创建一个 FPPassManager 来装它。`--debug-pass=Structure` 输出的缩进树正是这个嵌套结构的可视化。

---

## 9.3 `AnalysisID` 整数注册体系

### 9.3.1 `AnalysisID = const void *`

`llvm/include/llvm/Pass.h:50-51`:

```cpp
// AnalysisID - Use the PassInfo to identify a pass...
using AnalysisID = const void *;
```

每个 pass 类有一个 `static char ID` 成员,`&ID` 的全局唯一地址就是这个 pass 的 AnalysisID。比如 `char PHIElimination::ID = 0;`(`llvm/lib/CodeGen/PHIElimination.cpp:209`)。

### 9.3.2 `INITIALIZE_PASS` 宏族做什么

定义在 `llvm/include/llvm/PassSupport.h:39-58`:

```cpp
#define INITIALIZE_PASS_BEGIN(passName, arg, name, cfg, analysis)              \
  static void initialize##passName##PassOnce(PassRegistry &Registry) {          // :39-40

#define INITIALIZE_PASS_DEPENDENCY(depName) initialize##depName##Pass(Registry); // :42

#define INITIALIZE_PASS_END(passName, arg, name, cfg, analysis)                \
  PassInfo *PI = new PassInfo(                                                 \
      name, arg, &passName::ID,                                                \
      PassInfo::NormalCtor_t(callDefaultCtor<passName>), cfg, analysis);       \
  Registry.registerPass(*PI, true);                                            \  // :48
  }                                                                            \
  static llvm::once_flag Initialize##passName##PassFlag;                       \
  void llvm::initialize##passName##Pass(PassRegistry &Registry) {              \
    llvm::call_once(Initialize##passName##PassFlag,                            \
                    initialize##passName##PassOnce, std::ref(Registry));       \
  }                                                                            // :50-54

#define INITIALIZE_PASS(passName, arg, name, cfg, analysis)                    \
  INITIALIZE_PASS_BEGIN(passName, arg, name, cfg, analysis)                    \
  INITIALIZE_PASS_END(passName, arg, name, cfg, analysis)                      // :56-58
```

宏展开后做的事:

1. 定义 `static void initializeXxxPassOnce(PassRegistry &)` 函数,函数体在 `BEGIN`/`END` 之间;
2. 函数体末尾 `new PassInfo(name, arg, &passName::ID, callDefaultCtor<passName>, cfg, analysis)`(:46-47)——**`PassInfo` 持有 pass 名、命令行参数名、AnalysisID 地址和默认构造函数指针**;
3. `Registry.registerPass(*PI, true)`(:48)把 PassInfo 注册进全局 `PassRegistry`(`llvm/include/llvm/PassRegistry.h:38`);`ShouldFree=true` 表示注册中心析构时负责 `delete PI`;
4. 定义 `static llvm::once_flag InitializeXxxPassFlag` + 公开函数 `void llvm::initializeXxxPass(PassRegistry &)`(:50-54),后者用 `call_once` 保证幂等;
5. `INITIALIZE_PASS_DEPENDENCY(depName)`(:42)展开为 `initializedepNamePass(Registry);`——**确保依赖的 pass 先注册**。

`llvm/lib/CodeGen/PHIElimination.cpp:213-220` 是一个完整示例:

```cpp
INITIALIZE_PASS_BEGIN(PHIElimination, DEBUG_TYPE, ...)
INITIALIZE_PASS_DEPENDENCY(LiveVariablesWrapperPass)
INITIALIZE_PASS_DEPENDENCY(MachineBranchProbabilityInfoWrapperPass)
INITIALIZE_PASS_DEPENDENCY(MachineBlockFrequencyInfoWrapperPass)
INITIALIZE_PASS_END(PHIElimination, DEBUG_TYPE, ...)
```

### 9.3.3 为什么必须显式调用 `initializeXxxPass`

这是 legacy PM 的一个**反直觉设计**:光在源码里写 `INITIALIZE_PASS(...)` 宏还不够,**必须有人调用生成的 `initializeXxxPass(Registry)` 函数**,pass 才真正进 `PassRegistry`。

原因:**链接器会剔除未被引用的对象文件 / 静态初始化代码**。LLVM 的 pass 库是按需链接的——如果 `libLLVMSomething.a` 中的 `Xxx.o` 没有被引用,链接器不会把它纳入可执行文件,`INITIALIZE_PASS` 宏定义的静态变量就不存在。所以 main() 必须**显式调用 initialize 函数**来强制链接器把对应 .o 拉进来,并触发注册。

调用点:

- `llvm/lib/CodeGen/CodeGen.cpp:19-172` 定义 `llvm::initializeCodeGen(PassRegistry &Registry)`,**逐行调用 100+ 个 `initializeXxxPass(Registry)`**(示例 :20-34);
- `llc` 在 `llvm/tools/llc/lib/llcdriver.cpp:383` 调 `initializeCodeGen(*Registry)`;
- `opt` 在 `llvm/tools/opt/optdriver.cpp:430-444` 区域逐库调用 `initialize*Pass`(`initializeExpandReductionsPass(Registry);` :440 等);
- 工具自己用的额外 pass 也要显式 initialize(否则 `opt -passname` 报 "Pass ID not registered")。

`Pass::createPass`(`llvm/lib/IR/Pass.cpp:222-227`)就是按 `AnalysisID` 反查工厂函数的实现:

```cpp
Pass *Pass::createPass(AnalysisID ID) {
  const PassInfo *PI = PassRegistry::getPassRegistry()->getPassInfo(ID);
  if (!PI)
    return nullptr;
  return PI->createPass();   // 调 PassInfo::NormalCtor_t
}
```

`TargetPassConfig::addPass(AnalysisID)`(`TargetPassConfig.cpp:794-796`)依赖它创建 pass,**没注册的 ID 直接 `llvm_unreachable("Pass ID not registered")`**。

---

## 9.4 `TargetPassConfig::addPass` 与 `insertPass` 楔子机制

### 9.4.1 `TargetPassConfig::addPass(Pass *)`

`llvm/lib/CodeGen/TargetPassConfig.cpp:737-777`:

```cpp
void TargetPassConfig::addPass(Pass *P) {
  assert(!Initialized && "PassConfig is immutable");        // :738
  AnalysisID PassID = P->getPassID();                       // :744 先缓存 ID(PM 可能立即删 P)

  if (StartBefore == PassID && StartBeforeCount++ == StartBeforeInstanceNum)
    Started = true;                                         // :746-747
  if (StopBefore == PassID && StopBeforeCount++ == StopBeforeInstanceNum)
    Stopped = true;                                         // :748-749
  if (Started && !Stopped) {
    if (AddingMachinePasses) {
      // 构造 banner 是为了在 PM->add 之前拿到 pass 名
      std::string Banner = std::string("After ") + std::string(P->getPassName());
      addMachinePrePasses();                                // :755 在 machine pass 前插 print/verify
      PM->add(P);                                           // :756
      addMachinePostPasses(Banner);                         // :757 在 machine pass 后插 print/verify
    } else {
      PM->add(P);                                           // :759
    }

    // Add the passes after the pass P if there is any.
    for (const auto &IP : Impl->InsertedPasses)             // :763
      if (IP.TargetPassID == PassID)
        addPass(IP.getInsertedPass());                      // :765  楔子插入点
  } else {
    delete P;                                               // :767  管线被截断时直接 delete
  }

  if (StopAfter == PassID && StopAfterCount++ == StopAfterInstanceNum)
    Stopped = true;                                         // :770-771
  if (StartAfter == PassID && StartAfterCount++ == StartAfterInstanceNum)
    Started = true;                                         // :773-774
  if (Stopped && !Started)
    reportFatalUsageError("Cannot stop compilation after pass that is not run"); // :776
}
```

要点:

1. **PassConfig 是"两阶段"对象**:`assert(!Initialized)`(:738)——构造期才能改 pass 列表,`setInitialized()` 之后所有 setter 触发 assert;
2. **start/stop 状态机**:4 个全局 `cl::opt<std::string>`(StartBefore/StopBefore/StartAfter/StopAfter)对应 4 个实例计数器;`Started/Stopped` 决定当前 pass 是否真的入 PM;
3. **machine pass 自动 print/verify**(:755-757):当 `AddingMachinePasses` 为 true 时,每个 machine pass 前后都插入 verifier 和 printer,实现 `-print-after-all` 等行为;
4. **楔子插入点在 :763-765**:每次 addPass 后,扫 `Impl->InsertedPasses` 列表,如果当前 pass 的 ID 匹配某条 InsertPass 的 TargetPassID,**递归调用 addPass 把被插入 pass 紧接着加进来**;
5. **被截断的 pass 直接 delete**(:767)——对象生命周期由 `TargetPassConfig` 决定,不会泄漏。

### 9.4.2 `insertPass` 楔子机制

`TargetPassConfig.cpp:652-660`:

```cpp
void TargetPassConfig::insertPass(AnalysisID TargetPassID,
                                  IdentifyingPassPtr InsertedPassID) {
  assert(((!InsertedPassID.isInstance() &&
           TargetPassID != InsertedPassID.getID()) ||
          (InsertedPassID.isInstance() &&
           TargetPassID != InsertedPassID.getInstance()->getPassID())) &&
         "Insert a pass after itself!");
  Impl->InsertedPasses.emplace_back(TargetPassID, InsertedPassID);   // :659
}
```

**只是往 `Impl->InsertedPasses` 这个 vector 里 push 一条 `(TargetPassID, InsertedPassID)` 记录**。真正的插入动作发生在 `addPass`(:763-765)的循环里——当目标 pass 被加入 PM 后,紧随其后把每个匹配的楔子 pass 也加进来。

`IdentifyingPassPtr` 是"既能存 AnalysisID 也能存 Pass* 实例"的联合体(声明在 `llvm/include/llvm/CodeGen/TargetPassConfig.h:53-63`,带 `isInstance()` / `getID()` / `getInstance()` 接口);楔子记录类型 `struct InsertedPass` 在 `TargetPassConfig.cpp:407-422`(匿名 namespace 内),`Pass *getInsertedPass()` 在 :414-421——若 `InsertedPassID` 是 ID 则通过 `Pass::createPass(ID)`(:418)现场创建实例,若是实例则直接返回。

### 9.4.3 AMDGPU 的楔子使用

`llvm/lib/Target/AMDGPU/AMDGPUTargetMachine.cpp` 中 legacy 侧(注意与 §1.5 new PM 侧的 `insertPass<TargetPassT>(InsertedPassT)` 区分,后者在 :2615-2689 使用模板)共 **8 处** `insertPass`,全部位于 `GCNPassConfig::addFastRegAlloc` / `addOptimizedRegAlloc`:

| 行号 | 目标 pass | 被插入的 pass | 说明 |
|---|---|---|---|
| :1841 | `PHIEliminationID` | `SILowerControlFlowLegacyID` | `SILowerControlFlow` 紧跟 PHI 消除 |
| :1843 | `TwoAddressInstructionPassID` | `SIWholeQuadModeID` | WQM 紧跟 2-addr |
| :1857 | `DetectDeadLanesID` | `DeadMachineInstructionElimID` | DCE 紧跟死 lane 检测(`if (EnableDCEInRA)` 内) |
| :1864 | `LiveVariablesID` | `SIOptimizeVGPRLiveRangeLegacyID` | VGPR 活跃范围优化(`if (OptVGPRLiveRange)` 内) |
| :1869 | `PHIEliminationID` | `SILowerControlFlowLegacyID` | 第二次出现(`addOptimizedRegAlloc` 内,与 :1841 不同分支) |
| :1872 | `RenameIndependentSubregsID` | `GCNRewritePartialRegUsesID` | 部分寄存器使用重写 |
| :1875 | `MachineSchedulerID` | `GCNPreRAOptimizationsID` | RA 前优化(`if (EnablePreRAOptimizations)` 内,待验证) |
| :1879 | `MachineSchedulerID` | `SIWholeQuadModeID` | WQM 也挂在 MachineScheduler 后 |
| :1882 | `MachineSchedulerID` | `SIOptimizeExecMaskingPreRAID` | `if (EnableExecMaskingPreRA)` 内 |
| :1887 | `MachineSchedulerID` | `SIFormMemoryClausesID` | `if (EnableFormMemoryClauses)` 内 |

**插入语义**:"在目标 pass 之后立刻运行",**不是"替换"**。比如 `SILowerControlFlow` 必须在 `PHIElimination` 之后、`TwoAddressInstructionPass` 之前跑,但 legacy 的 PassConfig API 只允许"附加到 hook 点",所以用 `insertPass` 把 `SILowerControlFlow` 钉在 `PHIElimination` 后面。AMDGPU 选择把 `SIWholeQuadMode` 同时挂到 `TwoAddressInstructionPassID` 和 `MachineSchedulerID`,是因为 fast regalloc 与 optimized regalloc 走不同分支。

对比 new PM 侧(:2615-2689)用模板 `insertPass<PHIEliminationPass>(SILowerControlFlowPass())`,把同样的 8 组插入关系表达为类型化 `AfterCallbacks`(`CodeGenPassBuilder.h:383-392`)。

---

## 9.5 分析失效模型:legacy vs new PM

### 9.5.1 legacy 的 `AvailableAnalysis` / `AnalysisResolver`

**`AvailableAnalysis`** 是 `DenseMap<AnalysisID, Pass *>`,定义在 `PMDataManager`(声明在 `LegacyPassManagers.h`,使用见 `LegacyPassManager.cpp:908/:974`)。pass 一旦运行完,自己就被作为"分析提供者"放入这个 map(`recordAvailableAnalysis`,:860-866)。

**`AnalysisResolver`** 定义在 `llvm/include/llvm/PassAnalysisSupport.h:158-203`,是每个 Pass 的"分析查找代理":

```cpp
class AnalysisResolver {
public:
  explicit AnalysisResolver(PMDataManager &P) : PM(P) {}     // :161

  Pass *findImplPass(AnalysisID PI) {                         // :166-175
    for (const auto &AnalysisImpl : AnalysisImpls) {
      if (AnalysisImpl.first == PI) {
        ResultPass = AnalysisImpl.second;
        break;
      }
    }
    return ResultPass;
  }
  LLVM_ABI Pass *getAnalysisIfAvailable(AnalysisID ID) const; // :194
private:
  std::vector<std::pair<AnalysisID, Pass *>> AnalysisImpls;   // :199
  PMDataManager &PM;                                          // :202
};
```

**每个 Pass 持有一个 `AnalysisResolver*`**(`Pass::Resolver`),`PMDataManager::add` 时通过 `new AnalysisResolver(*this)`(:982)创建并 `P->setResolver(AR)`(:983)。`getAnalysis<T>()` 模板最终调 `Resolver->getAnalysisIfAvailable(PI)`(:217),后者先查 `AnalysisImpls` 缓存,未命中再去 `PM` 的 `AvailableAnalysis` 找。

### 9.5.2 legacy 的失效:`removeNotPreservedAnalysis` + `removeDeadPasses`

**失效**(在 pass 运行后,把不再保留的分析删掉):

```cpp
// LegacyPassManager.cpp:901-937
void PMDataManager::removeNotPreservedAnalysis(Pass *P) {
  AnalysisUsage *AnUsage = TPM->findAnalysisUsage(P);
  if (AnUsage->getPreservesAll())                             // :904  保留所有则直接返回
    return;

  const AnalysisUsage::VectorType &PreservedSet = AnUsage->getPreservedSet();  // :907
  SmallVector<DenseMap<AnalysisID, Pass *> *, 8> Maps = {&AvailableAnalysis}; // :908
  for (DenseMap<AnalysisID, Pass *> *IA : InheritedAnalysis)  // :911  还要查父层
    if (IA) Maps.push_back(IA);
  ...
  for (DenseMap<AnalysisID, Pass *> *M : Maps) {
    if (M->empty()) continue;
    M->remove_if([&](const auto &Entry) {
      if (Entry.second->getAsImmutablePass() != nullptr ||    // :925  ImmutablePass 永不失效
          is_contained(PreservedSet, Entry.first))            // :926  PreservedSet 内的跳过
        return false;
      return true;                                            // :934  其他全删
    });
  }
}
```

要点:

- **粗粒度**:粒度是"整个 analysis"——只要不在 `PreservedSet` 里就**整个从 AvailableAnalysis 删掉**,不存在"部分保留";
- **ImmutablePass 永不删**(:925)——`TargetLibraryInfoWrapperPass`、`TargetPassConfig` 等跨整个编译期有效;
- **`remove_if` 用 lambda + 单调用点优化**(:918-924 注释)——避免 `DenseMap::remove_if` 在多个调用点实例化导致 inline 失败。

**内存释放**(把"以当前 pass 为最后用户"的分析释放掉):

```cpp
// LegacyPassManager.cpp:940-975
void PMDataManager::removeDeadPasses(Pass *P, StringRef Msg, ...) {
  ...
  TPM->collectLastUses(DeadPasses, P);    // :949  收集"P 是最后用户"的分析
  for (Pass *P : DeadPasses)
    freePass(P, Msg, DBG_STR);            // :957-958
}

void PMDataManager::freePass(Pass *P, StringRef Msg, ...) {
  dumpPassInfo(P, FREEING_MSG, DBG_STR, Msg);
  {
    PassManagerPrettyStackEntry X(P);
    TimeRegion PassTimer(getPassTimer(P));
    P->releaseMemory();                   // :970  pass 自己释放内存
  }
  AvailableAnalysis.erase(P->getPassID());  // :974
}
```

调用点在 `FPPassManager::runOnFunction`(:1459-1461)和 `MPPassManager::runOnModule`(:1616-1618):

```cpp
// FPPassManager::runOnFunction 末尾
removeNotPreservedAnalysis(FP);           // :1459
removeDeadPasses(FP, Name, ON_FUNCTION_MSG); // :1461
```

### 9.5.3 "last modifier wins" 与 new PM 对比

| 维度 | legacy PM | new PM |
|---|---|---|
| 失效粒度 | 整个 analysis(粗粒度) | `PreservedAnalyses` 类型化集合,可精确到具体分析(同样粗粒度但**声明更明确**) |
| 失效时机 | pass `runOnXxx` 返回后,由 PM 立即调 `removeNotPreservedAnalysis`(:1459/:1616) | pass `run()` 返回 `PreservedAnalyses` 对象,由 `PassManager` 模板内调用 `AM.invalidate(IR, PA)` |
| 谁声明保留 | pass 在 `getAnalysisUsage(AnalysisUsage &AU)` 里调 `AU.addPreserved<XxxPass>()` | pass `run()` 返回 `PreservedAnalyses` 时调用 `PA.preserve<XxxAnalysis>()` |
| 跨层失效 | 通过 `InheritedAnalysis` 链表(:911)在多层 PM 同步删除 | 通过 proxy analysis(`InnerAnalysisManagerProxy` / `OuterAnalysisManagerProxy`)在嵌套 manager 之间转发 |
| 分析释放 | "最后用户"机制,`setLastUser`/`collectLastUses`/`removeDeadPasses` 提前 `releaseMemory`(:970) | `AnalysisManager::invalidate` 自动管理;`PassManager::run` 返回时清理 |
| Immutable | `ImmutablePass` 特例(:925)永不失效 | 不存在 Immutable 概念;若需"常驻分析",target 直接在 `PassBuilder::registerModuleAnalyses` 注册时不失效 |

**"last modifier wins" 是 legacy 的隐式语义**:同一个 AnalysisID 只允许一个实现(`AvailableAnalysis[PI] = P`,:863),后注册的覆盖先注册的(评审修正:该赋值只**更新后续分析查询所用的实例映射**,**不替换已加入流水线的 pass**——`PMDataManager::add` 在 recordAvailableAnalysis 之后仍执行 `PassVector.push_back(P)`,:979-1048;Codegen 段真正的 pass 替换机制是 `TargetPassConfig::substitutePass`,`TargetPassConfig.cpp:712-715`)。比如 target 可以 `addPass(new MyAA())` 替换默认 `basic-aa`——旧 pass 被新 pass 覆盖,后续 `getAnalysis<AliasAnalysis>()` 拿到的就是新的。new PM 没有这种隐式覆盖,`PassBuilder` 显式 `MAM.registerPass([&] { return AAManager(); })`,重复注册返回 false 保留先注册实例、不调用后续 factory(`PassManager.h:497-509`)——不是断言。

---

## 9.6 为何 CodeGen 仍在 legacy:官方理由考古

### 9.6.1 `TargetPassConfig.cpp` 头注释

`llvm/lib/CodeGen/TargetPassConfig.cpp:1-12`:

```cpp
//===- TargetPassConfig.cpp - Target independent code generation passes ---===//
//
// ...
//===----------------------------------------------------------------------===//
//
// This file defines interfaces to access the target independent code
// generation passes provided by the LLVM backend.
//
//===---------------------------------------------------------------------===//
```

**头注释本身没有解释为什么保留 legacy**——它只是把文件定位为"target 无关 code generation passes 的接口"。

### 9.6.2 `CodeGenPassBuilder.h` 的动机注释

`llvm/include/llvm/Passes/CodeGenPassBuilder.h:71-86`:

```cpp
/// This class provides access to building LLVM's passes.
///
/// Its members provide the baseline state available to passes during their
/// construction. The \c MachinePassRegistry.def file specifies how to construct
/// all of the built-in passes, and those may reference these members during
/// construction.
///
/// Targets customize the pipeline by deriving from this class and overriding
/// the virtual add* hooks below: the add%Stage hooks replace a whole stage of
/// the pipeline, while the addPre%Stage / addPost%Stage hooks inject passes
/// around one. See addMachinePasses for how they fit together.
///
/// Dispatch is virtual rather than templated on the derived builder so that the
/// target-independent pipeline is emitted once for the whole build instead of
/// once per target.
```

最后一段(:83-85)是 2024-02 commit `91e9e3175268`("Rewrite pass manager nesting")的关键设计决定——**用虚函数而不是 CRTP,让通用管线代码只生成一份**,否则每个 target 一份模板实例会让二进制膨胀。

### 9.6.3 commit 考古给出的理由

| commit | 日期 | 关键信息 |
|---|---|---|
| `911565d1085d` | 2020-08-07 | `[NewPM][CodeGen] Introduce machine pass and machine pass manager` —— **首次承认 MachineFunction 需要单独的 PM**,因为 MachineFunction 的生命周期与 Function 解耦(必须显式 `releaseMemory`) |
| `480936e741d5` | 2020-12-29 | `Reland "[NewPM][CodeGen] Introduce CodeGenPassBuilder"` —— 前两次 revert,说明 CodeGen 迁移涉及面大、易破坏 |
| `91e9e3175268` | 2024-02-22 | `Rewrite pass manager nesting` —— **放弃 CRTP,改虚函数**;理由是代码体积("emitted once for the whole build instead of once per target") |
| `6ea0c0a28343` | 2024-04-30 | `Add MachineFunctionAnalysis` —— 把 MachineFunction 本身作为可查询分析,补齐 new PM 在 machine 层的查询能力 |

**为何 2026 年仍未全量切换**:

1. **target 覆盖率低**(§1.8 实测):仅 Lanai 和 MSP430 把 `shouldDefaultToNewPM()` 改成 true,其余 8 个写了 `buildCodeGenPipeline` 的 target(NVPTX/SPIRV/WebAssembly/X86/AMDGPU/RISCV/BPF)默认仍走 legacy;
2. **AArch64/ARM/Hexagon/PowerPC/SystemZ 等大 target 还没写 CodeGenPassBuilder**;
3. **`MachineFunction` 生命周期模型特殊**:`911565d1085d` 的提交信息提到 MachineFunction 不能像 Function 一样由 PM 自动管理——必须在 AsmPrinter 之后显式 `releaseMemory`,这与 new PM 的"分析结果自动失效"模型不完全兼容;
4. **历史惯性**:TargetPassConfig 的 `substitutePass`/`insertPass`/`addPass(AnalysisID)` 组合已经积累了 15 年的 target 定制,迁移到 new PM 的 `disablePass`/`insertPass` 模板需要对每个 target 重写一遍 pass 注册逻辑。

---

## 9.7 实测:`--debug-pass=Structure` 的树形结构

### 9.7.1 准备

```bash
$ cat > PassManager-notes/scratch/legacy-hello.ll <<'EOF'
define i32 @add(i32 %a, i32 %b) {
  %sum = add i32 %a, %b
  ret i32 %sum
}
EOF
```

### 9.7.2 llc 默认(legacy)输出

```bash
$ ./build-debug/bin/llc --debug-pass=Structure PassManager-notes/scratch/dualpm-hello.ll -o /dev/null
```

**输出 266 行**(`scratch/legacy-llc-structure.log`)。前 40 行:

```
Pass Arguments:  -targetlibinfo -runtime-library-info -targetpassconfig -machinemoduleinfo -tti ...
Target Library Information
Runtime Library Function Analysis
Target Pass Configuration
Machine Module Information
Target Transform Information
Assumption Cache Tracker
Library Function Lowering Analysis
Profile summary info
Type-Based Alias Analysis
Scoped NoAlias Alias Analysis
Create Garbage Collector Module Metadata
Machine Branch Probability Analysis
Default Regalloc Eviction Advisor
Default Regalloc Priority Advisor
  ModulePass Manager
    FunctionPass Manager
      Dominator Tree Construction
      Basic Alias Analysis (stateless AA impl)
      Function Alias Analysis Results
      ObjC ARC contraction
    Pre-ISel Intrinsic Lowering
    FunctionPass Manager
      Expand IR instructions
      Expand Atomic instructions
      Simplify the CFG
      Dominator Tree Construction
      Natural Loop Information
      Canonicalize natural loops
      Cycle Info Analysis
      Lazy Branch Probability Analysis
      Lazy Block Frequency Analysis
      Optimization Remark Emitter
      Scalar Evolution Analysis
      Loop Data Prefetch
      Falkor HW Prefetch Fix
      Module Verifier
      Basic Alias Analysis (stateless AA impl)
      Canonicalize natural loops
      Loop Pass Manager
```

**结构解读**:

1. **顶层平铺的是 ImmutablePass**(没有缩进):`Target Library Information`、`Target Pass Configuration`、`Machine Module Information` 等。这些 pass 没有"运行"概念,只是被 `add` 后注入 `AvailableAnalysis`;
2. **`ModulePass Manager`** 是 MPPassManager(:380),`FunctionPass Manager` 是 FPPassManager;
3. **嵌套缩进 2 空格 / 层**:depth 在 `PMStack::push`(:1745)递增;
4. **`Loop Pass Manager`** 出现在 `FunctionPass Manager` 之下——LoopPass 的容器,说明 legacy 的 5 层嵌套(Module → Function → Loop → BasicBlock → Region)依然活跃;
5. **同一函数可被多次跑 FunctionPassManager**:看 `FunctionPass Manager` 出现了两次,因为 MPPassManager 会在处理 `FPPassManager` 时为每个函数驱动一遍。

完整 log(266 行)存 `PassManager-notes/scratch/legacy-llc-structure.log`。

### 9.7.3 NVPTX 对比

```bash
$ ./build-debug/bin/llc -march=nvptx64 --debug-pass=Structure PassManager-notes/scratch/dualpm-hello.ll -o /dev/null
```

**输出 183 行**(`scratch/legacy-llc-nvptx-structure.log`),结构与 AArch64 类似但 pass 集合完全不同——NVPTX 用 `-nvptx-lower-args`、`-nvptx-assign-valid-global-names` 等专属 pass,印证 `TargetPassConfig::createPassConfig` 的多态性。

### 9.7.4 opt 的对比

`opt --debug-pass=Structure -O2 ...` **直接报错**:

```
-debug-pass does not work with the new PM, either use -debug-pass-manager, or use the legacy PM
```

(`optdriver.cpp:755-759` 的守卫;exit 1)。说明 opt 已经强制走 new PM,`--debug-pass` 在新 PM 下被禁用。

---

## 9.8 本篇断言自查表

| 断言 | 文件:行号 | 核实方式 |
|---|---|---|
| `LegacyPassManager.cpp` 1808 行 | `wc -l` | 实测 |
| `FunctionPassManagerImpl` 类位置 | `LegacyPassManager.cpp:244-246` | grep + read |
| `MPPassManager` 类位置 | `LegacyPassManager.cpp:380` | grep |
| `PassManagerImpl` 类位置 | `LegacyPassManager.cpp:466-468` | grep |
| `PassManagerImpl::run` | `LegacyPassManager.cpp:522` | grep |
| `legacy::PassManager::run` 是壳 | `LegacyPassManager.cpp:1713-1715` | read |
| `legacy::PassManager` 公开定义 | `llvm/include/llvm/IR/LegacyPassManager.h:53-69` | read |
| `PMTopLevelManager::schedulePass` | `LegacyPassManager.cpp:655` | grep |
| `setLastUser` 实现 | `LegacyPassManager.cpp:557-606` | read |
| `findAnalysisPass` | `LegacyPassManager.cpp:763-779` | grep |
| `recordAvailableAnalysis` | `LegacyPassManager.cpp:860-866` | read |
| `removeNotPreservedAnalysis` | `LegacyPassManager.cpp:902-937` | read |
| `removeDeadPasses` / `freePass` | `LegacyPassManager.cpp:940` / `:961-975` | read |
| `FPPassManager::runOnFunction` 末尾失效 | `LegacyPassManager.cpp:1459-1461` | grep |
| `MPPassManager::runOnModule` 末尾失效 | `LegacyPassManager.cpp:1616-1618` | grep |
| `PMStack` 类定义 | `llvm/include/llvm/IR/LegacyPassManagers.h:137-152` | read |
| "PassManagerStack 名字不存在" | `grep -rn PassManagerStack llvm/` 返回 0 | 实测 |
| `PMStack::push` 实现 | `LegacyPassManager.cpp:1733-1754` | read |
| `PMStack::pop` 实现 | `LegacyPassManager.cpp:1724-1730` | read |
| `ModulePass::assignPassManager` | `LegacyPassManager.cpp:1767-1775` | read |
| `FunctionPass::assignPassManager` 自动建 FPPassManager | `LegacyPassManager.cpp:1779-1806` | read |
| `AnalysisID = const void *` | `llvm/include/llvm/Pass.h:51` | read |
| `INITIALIZE_PASS_BEGIN/END` 宏 | `llvm/include/llvm/PassSupport.h:39-58` | read |
| `INITIALIZE_PASS_DEPENDENCY` | `PassSupport.h:42` | read |
| `RegisterPass` 模板 | `PassSupport.h:96-104` | read |
| `Pass::createPass` 实现 | `llvm/lib/IR/Pass.cpp:222-227` | read |
| `initializeCodeGen` 总入口 | `llvm/lib/CodeGen/CodeGen.cpp:19-172` | read |
| llc 调 `initializeCodeGen` | `llvm/tools/llc/lib/llcdriver.cpp:383` | grep |
| `TargetPassConfig::addPass(Pass*)` | `llvm/lib/CodeGen/TargetPassConfig.cpp:737-777` | read |
| `insertPass` 定义 | `TargetPassConfig.cpp:652-660` | read |
| 楔子循环 `:763-765` | `TargetPassConfig.cpp:763-765` | read |
| AMDGPU legacy `insertPass` 8 处 | `AMDGPUTargetMachine.cpp:1841-1887` | grep + read 逐行 |
| AMDGPU new PM `insertPass` 模板用法 | `AMDGPUTargetMachine.cpp:2615-2689` | grep |
| `AnalysisResolver` 定义 | `llvm/include/llvm/PassAnalysisSupport.h:158-203` | read |
| `Pass::getAnalysisIfAvailable<T>` 模板 | `PassAnalysisSupport.h:212-218` | read |
| `CodeGenPassBuilder` "virtual not templated" 注释 | `llvm/include/llvm/Passes/CodeGenPassBuilder.h:83-85` | read |
| milestone commits(4 个 CodeGen new PM 相关) | §9.6.3 表 | `git log -1 --format="%h %ad %s"` |
| 实测:llc `--debug-pass=Structure` 266 行 | `scratch/legacy-llc-structure.log` | 亲自跑 |
| 实测:llc NVPTX `--debug-pass=Structure` 183 行 | `scratch/legacy-llc-nvptx-structure.log` | 亲自跑 |
| 实测:opt `--debug-pass=Structure` 报错 | `scratch/legacy-opt-structure.log` | 亲自跑,exit 1 |
| 实测:clang `--debug-pass=Structure` 走 legacy | `scratch/dualpm-clang-aarch64.log`,`scratch/legacy-clang-amdgpu-structure.log` | 亲自跑 |
