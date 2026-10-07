# Hexagon 架构编译器后端设计文档

## 1. 概述

Hexagon 是 Qualcomm 自研的 VLIW (Very Long Instruction Word) DSP 架构，广泛应用于 Snapdragon 芯片的信号处理、音频处理、图像处理和 AI 加速。LLVM Hexagon 后端位于 `llvm/lib/Target/Hexagon/`，包含约 114 个源文件。

### 架构特点
- **VLIW 设计**: 4 个并行执行槽 (SLOT0-3)
- **多线程**: 支持硬件多线程
- **HVX 向量扩展**: 64B/128B 向量处理单元
- **.new 值指令**: 包内数据前递优化
- **硬件循环**: 零开销循环指令
- **预测执行**: 4 个预测寄存器 (P0-P3)

---

## 2. 目录结构

```
llvm/lib/Target/Hexagon/
├── Hexagon.td                    # 顶层 TableGen 定义
├── HexagonTargetMachine.cpp/h    # 目标机器配置
├── HexagonSubtarget.cpp/h        # 子目标特性管理
├── HexagonInstrInfo.cpp/h        # 指令信息
├── HexagonRegisterInfo.cpp/h     # 寄存器信息
├── HexagonISelLowering.cpp/h     # DAG Lowering
├── HexagonISelDAGToDAG.cpp       # 指令选择器
├── HexagonFrameLowering.cpp/h    # 栈帧布局
├── HexagonVLIWPacketizer.cpp     # VLIW 包打包 (核心)
├── HexagonMachineScheduler.cpp   # 机器调度器
├── HexagonHazardRecognizer.cpp   # Hazard 检测
├── HexagonHardwareLoops.cpp      # 硬件循环优化
├── HexagonNewValueJump.cpp       # New-Value Jump
├── HexagonConstPropagation.cpp   # 常量传播
├── HexagonBitSimplify.cpp        # 位操作优化
├── HexagonVectorCombine.cpp      # HVX 向量优化
├── MCTargetDesc/                 # MC 层描述
│   ├── HexagonMCTargetDesc.cpp   # MC 目标描述
│   ├── HexagonMCCodeEmitter.cpp  # 指令编码
│   ├── HexagonMCShuffler.cpp     # 指令重排
│   └── HexagonAsmBackend.cpp     # 汇编后端
├── AsmParser/                    # 汇编解析器
├── Disassembler/                 # 反汇编器
└── TargetInfo/                   # 目标信息注册
```

---

## 3. 指令集定义 (TableGen)

### TD 文件层级
```
Hexagon.td (主入口)
  ├── HexagonDepArch.td         # 架构版本 (V5~V79)
  ├── HexagonRegisterInfo.td    # 寄存器定义
  ├── HexagonOperands.td        # 操作数定义
  ├── HexagonInstrFormats.td    # 指令格式基类
  ├── HexagonDepInstrFormats.td # 详细指令格式 (~1MB)
  ├── HexagonDepInstrInfo.td    # 指令定义 (~1.1MB)
  ├── HexagonSchedule.td        # 调度模型
  ├── HexagonCallingConv.td     # 调用约定
  ├── HexagonPatterns.td        # 选择模式 (~156KB)
  └── HexagonIntrinsics.td      # 内置函数
```

### 指令格式属性 (TSFlags)

| 字段 | 位宽 | 描述 |
|------|------|------|
| Type | 7 | 指令类型 (ALU32, LD, ST, J, CVI 等) |
| Solo | 1 | 是否为独立指令 (不可打包) |
| PredicateInfo | 3 | 预测执行相关 |
| NewValueOp | 2 | .new 值支持 |
| Extendable | 1 | 常量扩展支持 |
| addrMode | 3 | 地址模式类型 |
| MemAccessSize | 4 | 内存访问大小 |

### 地址模式类型
```cpp
enum AddrMode {
  NoAddrMode = 0,
  Absolute = 1,       // 绝对地址
  AbsoluteSet = 2,    // 绝对设置模式
  BaseImmOffset = 3,  // 间接 + 偏移
  BaseLongOffset = 4, // 长偏移
  BaseRegOffset = 5,  // 寄存器偏移
  PostInc = 6         // 后增量
};
```

---

## 4. 寄存器体系

### 寄存器类定义

| RegisterClass | 类型 | 寄存器 |
|--------------|------|--------|
| IntRegs | i32, f32 | R0-R31 |
| DoubleRegs | i64, f64 | D0-D15 (Dx = Rx:Rx+1) |
| PredRegs | i1 | P0-P3 |
| HvxVR | v512i1, v1024i1 | V0-V31 |
| HvxWR | 向量对 | W0-W15 |
| HvxQR | 向量预测 | Q0-Q3 |

### 特殊寄存器
- **R29 (SP)** - 栈指针
- **R30 (FP)** - 帧指针
- **R31 (LR)** - 链接寄存器
- **VTMP** - HVX 临时寄存器
- **C0-C31** - 控制寄存器
- **S0-S80** - 系统寄存器

### Callee-Saved 寄存器
```cpp
// V3+ 架构
static const MCPhysReg CalleeSavedRegsV3[] = {
  R16, R17, R18, R19, R20, R21, R22, R23,
  R24, R25, R26, R27, 0
};
```

---

## 5. 指令选择

### 选择流程 (`HexagonISelDAGToDAG.cpp`)
```cpp
void Select(SDNode *N) {
  // HVX 特殊处理
  if (HST->useHVXOps() && isHvxOp(N)) {
    SelectHvxExtractSubvector(N);
    SelectHvxShuffle(N);
    SelectHvxRor(N);
  }
  
  // 标准选择
  switch (N->getOpcode()) {
    case ISD::Constant:    return SelectConstant(N);
    case ISD::FrameIndex:  return SelectFrameIndex(N);
    case ISD::LOAD:        return SelectLoad(N);
    case ISD::STORE:       return SelectStore(N);
    // ...
  }
  SelectCode(N);  // TableGen 生成的模式匹配
}
```

### ComplexPattern 定义
```tablegen
def AddrFI: ComplexPattern<i32, 1, "SelectAddrFI", [frameindex]>;
def AddrGA: ComplexPattern<i32, 1, "SelectAddrGA", []>;
def AddrGP: ComplexPattern<i32, 1, "SelectAddrGP", []>;
def AnyImm: ComplexPattern<i32, 1, "SelectAnyImm", []>;
```

### 预处理优化
```cpp
void PreprocessISelDAG() {
  if (HST->useHVXOps())
    PreprocessHvxISelDAG();       // HVX 预处理
  ppSimplifyOrSelect0();          // OR + SELECT 优化
  ppAddrReorderAddShl();          // 地址重排序
  ppAddrRewriteAndSrl();          // AND + SRL 重写
  ppHoistZextI1();                // i1 扩展提升
  rebalanceAddressTrees();        // Huffman 地址树平衡
}
```

---

## 6. VLIW Packetization (核心优化)

### 设计原理
Hexagon 每个指令包最多包含 4 条指令，在不同 SLOT 并行执行。Packetizer 负责将独立指令打包成 VLIW 包。

### 功能单元 (SLOT)
```tablegen
def SLOT0: FuncUnit;  // ALU/Mem
def SLOT1: FuncUnit;  // ALU/Mem
def SLOT2: FuncUnit;  // ALU/Jump
def SLOT3: FuncUnit;  // ALU/Jump
def SLOT_ENDLOOP: FuncUnit;  // Endloop

// HVX 管道
def CVI_ST: FuncUnit;    // 存储
def CVI_XLANE: FuncUnit; // 执行通道
def CVI_SHIFT: FuncUnit; // 移位
def CVI_MPY0: FuncUnit;  // 乘法器 0
def CVI_MPY1: FuncUnit;  // 乘法器 1
def CVI_LD: FuncUnit;    // 加载
```

### 打包合法性检查
```cpp
bool isLegalToPacketizeTogether(SUnit *SUI, SUnit *SUJ) {
  MachineInstr &I = *SUI->getInstr();
  MachineInstr &J = *SUJ->getInstr();
  
  // 1. 共存检查
  if (cannotCoexist(I, J)) return false;
  
  // 2. 依赖分析
  hasDeadDependence(I, J);
  hasControlDependence(I, J);
  hasRegMaskDependence(I, J);
  hasDualStoreDependence(I, J);
  
  // 3. .new 值提升尝试
  for (SDep &Dep : SUJ->Succs) {
    if (DepType == SDep::Data) {
      canPromoteToDotCur(J, SUJ, DepReg);
      canPromoteToDotNew(I, SUJ, DepReg);
    }
  }
  
  // 4. 互补预测
  if (arePredicatesComplements(I, J))
    continue;  // 可并行执行
}
```

### .new 值指令提升
将数据依赖转换为包内前递：
```
// 原始序列:
r21 = memub(r22+r24<<#0)   // Load
p0 = cmp.eq(r21, #0)       // Compare
if (p0) jump:t .Ltarget    // Jump

// .new 优化后:
r21 = memub(r22+r24<<#0)
if (cmp.eq(r21.new, #0)) jump:t .Ltarget
```

### Duplex 指令
两条小指令压缩为一条 duplex 指令，占用 2 字节而非 4 字节。

---

## 7. 调度策略

### VLIW 调度器
```cpp
class HexagonConvergingVLIWScheduler : public ConvergingVLIWScheduler {
  int SchedulingCost(ReadyQueue &Q, SUnit *SU) {
    int Cost = BaseCost;
    
    // .cur 加载优先调度
    if (QII.mayBeCurLoad(*SU->getInstr()))
      Cost += PriorityTwo;
    
    return Cost;
  }
};
```

### ScheduleDAGMutation
```cpp
struct UsrOverflowMutation;    // USR.OVF 处理
struct HVXMemLatencyMutation;  // HVX 内存延迟调整
struct CallMutation;           // 调用指令调度
struct BankConflictMutation;   // Bank 冲突处理
```

---

## 8. 子目标特性

### 架构版本
```tablegen
def ArchV5:  SubtargetFeature<"v5", ...>;
def ArchV55: SubtargetFeature<"v55", ...>;
def ArchV60: SubtargetFeature<"v60", ...>;
def ArchV62: SubtargetFeature<"v62", ...>;
def ArchV65: SubtargetFeature<"v65", ...>;
def ArchV66: SubtargetFeature<"v66", ...>;
def ArchV67: SubtargetFeature<"v67", ...>;
def ArchV68: SubtargetFeature<"v68", ...>;
def ArchV69: SubtargetFeature<"v69", ...>;
def ArchV71: SubtargetFeature<"v71", ...>;
def ArchV73: SubtargetFeature<"v73", ...>;
def ArchV75: SubtargetFeature<"v75", ...>;
def ArchV79: SubtargetFeature<"v79", ...>;
```

### HVX 扩展
```tablegen
def ExtensionHVX:      SubtargetFeature<"hvx", ...>;
def ExtensionHVXV60:   SubtargetFeature<"hvxv60", ...>;
def ExtensionHVXV62:   SubtargetFeature<"hvxv62", ...>;
// ... V65, V66, V67, V68, V69, V71, V73, V75, V79

def ExtensionHVX64B:   SubtargetFeature<"hvx-length64b", ...>;
def ExtensionHVX128B:  SubtargetFeature<"hvx-length128b", ...>;
def ExtensionHVXQFloat: SubtargetFeature<"hvx-qfloat", ...>;
def ExtensionHVXIEEEFP: SubtargetFeature<"hvx-ieee-fp", ...>;
```

### 其他特性
```tablegen
def FeatureCompound:   SubtargetFeature<"compound", ...>;  // 复合指令
def FeaturePackets:    SubtargetFeature<"packets", ...>;   // 指令包
def FeatureNVJ:        SubtargetFeature<"nvj", ...>;       // New-Value Jump
def FeatureNVS:        SubtargetFeature<"nvs", ...>;       // New-Value Store
def FeatureDuplex:     SubtargetFeature<"duplex", ...>;    // Duplex 指令
def FeatureSmallData:  SubtargetFeature<"small-data", ...>; // GP 相对寻址
def FeatureMemops:     SubtargetFeature<"memops", ...>;    // Memop 指令
def ExtensionAudio:    SubtargetFeature<"audio", ...>;
def ExtensionZReg:     SubtargetFeature<"zreg", ...>;
```

---

## 9. 调用约定

### 标量调用约定
```tablegen
def CC_Hexagon: CallingConv<[
  // 类型提升
  CCIfType<[i1,i8,i16], CCPromoteToType<i32>>,
  CCIfType<[f32], CCBitConvertToType<i32>>,
  CCIfType<[f64], CCBitConvertToType<i64>>,
  
  // 参数传递: R0-R5 (32位), D0-D2 (64位)
  CCIfType<[i32], CCAssignToReg<[R0,R1,R2,R3,R4,R5]>>,
  CCIfType<[i64], CCAssignToReg<[D0,D1,D2]>>,
  
  // 栈传递
  CCDelegateTo<CC_HexagonStack>
]>;

// 返回值: R0-R1 (32位), D0 (64位)
def RetCC_Hexagon: CallingConv<[
  CCIfType<[i32], CCAssignToReg<[R0,R1]>>,
  CCIfType<[i64], CCAssignToReg<[D0]>>,
]>;
```

### HVX 调用约定
```tablegen
def CC_Hexagon_HVX: CallingConv<[
  // 64B 模式: V0-V15 (单向量), W0-W7 (向量对)
  CCIfHvx64<
    CCIfType<[v16i32], CCAssignToReg<[V0,...,V15]>>,
    CCIfType<[v32i32], CCAssignToReg<[W0,...,W7]>>,
  >,
  
  // 128B 模式: V0-V15 (单向量), W0-W7 (向量对)
  CCIfHvx128<
    CCIfType<[v32i32], CCAssignToReg<[V0,...,V15]>>,
    CCIfType<[v64i32], CCAssignToReg<[W0,...,W7]>>,
  >,
]>;
```

---

## 10. 代码生成 Pass 流程

### Pass 配置 (`HexagonTargetMachine.cpp`)
```cpp
// IR Passes
addIRPasses():
  - InstSimplify
  - DeadCodeElimination
  - AtomicExpand
  - CFGSimplification
  - LoopDataPrefetch (可选)
  - HexagonVectorCombine (可选)
  - HexagonCommonGEP (可选)
  - HexagonGenExtract (可选)

// 指令选择
addInstSelector():
  - HexagonOptimizeSZextends
  - HexagonISelDag
  - HexagonVExtract (可选)
  - HexagonGenPredicate (可选)
  - HexagonLoopRescheduling (可选)
  - HexagonSplitDoubleRegs
  - HexagonBitSimplify
  - HexagonPeephole
  - HexagonConstPropagation
  - HexagonGenInsert (可选)
  - HexagonEarlyIfConversion (可选)

// 寄存器分配前
addPreRegAlloc():
  - HexagonConstExtenders (可选)
  - HexagonExpandCondsets
  - HexagonCopyHoisting
  - HexagonStoreWidening
  - HexagonLoadWidening
  - HexagonHardwareLoops
  - MachinePipeliner (软件流水线)

// 发射前
addPreEmitPass():
  - HexagonNewValueJump
  - HexagonBranchRelaxation
  - HexagonFixupHwLoops
  - HexagonGenMux (可选)
  - HexagonPacketizer (必须!)
  - HexagonLoopAlign
  - HexagonCallFrameInformation
```

---

## 11. 关键优化 Pass

### 硬件循环 (HexagonHardwareLoops.cpp)
将可计数循环转换为零开销循环：
```cpp
// 转换前:
for (int i = 0; i < N; i++) { body; }

// 转换后:
loop0(.Lbody, N)
.Lbody:
  body
  endloop0
```

条件：
- 可计数循环（有归纳变量）
- 循环已规范化
- 循环内无函数调用

### New-Value Jump (HexagonNewValueJump.cpp)
合并比较 + 跳转为一条指令：
```
r0 = add(r1, r2)
p0 = cmp.eq(r0, #0)
if (p0.new) jump:t .Ltarget
// ->
if (cmp.eq(r0.new, #0)) jump:t .Ltarget
```

### 常量传播 (HexagonConstPropagation.cpp)
基于格子的机器级常量传播：
```cpp
class LatticeCell {
  enum { Normal, Top, Bottom };
  union {
    uint32_t Properties;          // 属性位
    const Constant *Value;        // 单值
    const Constant *Values[4];    // 多值
  };
};
```

### Bit Simplify (HexagonBitSimplify.cpp ~110KB)
- 移位/掩码简化
- 位操作合并
- 常量折叠

### Vector Combine (HexagonVectorCombine.cpp ~112KB)
HVX 向量优化：
- 向量操作合并
- 向量指令序列优化

### 其他重要 Pass

| Pass | 大小 | 功能 |
|------|------|------|
| HexagonConstExtenders | 72KB | 常量扩展优化 |
| HexagonOptAddrMode | 44KB | 地址模式优化 |
| HexagonCopyToCombine | 32KB | COPY 合并 |
| HexagonExpandCondsets | 50KB | MUX 展开 |
| HexagonGenInsert | 52KB | Insert 指令生成 |
| HexagonLoopIdiomRecognition | 81KB | 循环模式识别 |

---

## 12. 设计要点总结

### 核心创新
1. **VLIW Packetization**: 复杂的依赖分析和 .new/.cur 提升
2. **HVX 向量扩展**: 64B/128B 模式，向量预测寄存器
3. **硬件循环**: 零开销循环指令
4. **预测执行**: 4 个预测寄存器支持条件执行
5. **Duplex 指令**: 指令压缩优化

### 编译器挑战
1. 包内指令并行性最大化
2. 依赖检测与 .new 提升
3. HVX 向量调度
4. 多架构版本支持 (V5-V79)
5. 软件流水线与硬件循环协同

### Target Triple
```
hexagon-unknown-linux-gnu
hexagon-unknown-elf
```

### 编译示例
```bash
clang -target hexagon-unknown-linux-gnu -mhvx -mhvx-length64B test.c
llc -march=hexagon -mattr=+hvxv73,+hvx-length64B test.ll
```