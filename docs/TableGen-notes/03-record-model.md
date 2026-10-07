# 03 Record / Init 语义与数据管理（笔记，静态锚点）

## 类型系统（llvm/include/llvm/TableGen/Record.h）

RecTy 基类（:63-107）：`typeIsConvertibleTo`/`typeIsA` 两个谓词是赋值检查核心。
子类：BitRecTy(:115，单例)、BitsRecTy(:133，带 Size)、IntRecTy(:154)、
StringRecTy(:172)、ListRecTy(:191，持 ElementTy)、DagRecTy(:215)、
RecordRecTy(:234-278，FoldingSet 唯一化，持非冗余 superclass 数组)。
`resolveTypes(T1,T2)`(:282) 用于二元运算的类型合成。
转换入口：Init::getCastTo/convertInitializerTo（各子类实现）；
RecordVal::setValue（Record.cpp:2737）先 `getCastTo` 失败即报类型错误 ——
E02 负例（int 参数传 string）就在此层被诊断。

## Init 继承体系（Record.h:288 起）

关键子类与行号（括号内）：
UnsetInit(:455，单例，isComplete=false 但 isConcrete=true —— `?` 的表示；
**普通字段保留 `?` 可正常实例化落地**，实测 `class C { int V = ?; } def Good : C;`
退出码 0（/tmp/verify-unset.td）。是否必须赋值由读取字段的具体 emitter 决定）、
ArgumentInit(:493，模板实参)、BitInit(:558)、BitsInit(:591)、IntInit(:637)、
AnonymousNameInit(:668)、StringInit(:698，区分 string/code 格式)、ListInit(:751)、
UnOpInit(:839，CAST/HEAD/TAIL/SIZE/REPR/…)、BinOpInit(:891，ADD/…/CONCAT/EQ/…)、
TernOpInit(:967，SUBST/FOREACH/IF/DAG/RANGE/…)、CondOpInit(:1027)、
FoldOpInit(:1099)、IsAOpInit(:1138)、ExistsOpInit(:1174)、VarInit(:1248，变量引用)、
VarBitInit(:1285)、DefInit(:1322)、VarDefInit(:1353，匿名实例化表达式，
Fold 时 instantiate)、FieldInit(:1410，X.y)、DagInit(:1453)。

求值模型（**已修正**）：两阶段折叠，共用同一 Fold 实现。解析期构造表达式节点
（UnOpInit/BinOpInit/TernOpInit::get）时即内联尝试 Fold——纯常量表达式（如
`!add(1,2)`）在未实例化的 class 中已折成 3（实测 /tmp/verify-fold.td）；
含未绑定模板参数/字段引用的保留 AST，经 `resolveReferences(Resolver&)` 按名字
替换生成新子树后，各 OpInit::Fold（Record.cpp:762/1208/1730）继续折叠。
三件独立机制（**已修正**，原先混为一谈）：
1. `isFinal` 标志（Resolver 基类 :2233-2258）：控制未消解引用是否报错。
   每个 def 的最终消解走 `Record::resolveReferences`（Record.cpp:2880
   `setFinal(true)`）；assert 检查同样 final（Record.cpp:3089）。
2. `keepUnsetBits`（RecordResolver=true）：作用于 BitsInit 逐位消解
   （Record.cpp:542-543）——某位消解为 UnsetInit 时保留原位，编码字段的
   变量位（rs/rd 引用）由此留到后端。豁免的是"位被 unset 覆盖"，
   **不是**允许 `?` 落地（`?` 本来就合法）。
3. `checkConcrete`（TGParser.cpp:98，addDefOne :599 调用）：拒绝**非 concrete**
   初始化器（无法消解的引用等）；`field` 声明（FK_NonconcreteOK）豁免的
   正是这一项，与 `?` 无关（UnsetInit 是 concrete 的）。

## Resolver 层级（Record.h:2233-2350）

MapResolver（显式映射，TGParser 的 Subst 载体）、
RecordResolver（从 Record 字段解析，keepUnsetBits=true —— 见上，编码位保留
变量位引用的原因）、
ShadowResolver（屏蔽名字）、TrackUnresolvedResolver/HasReferenceResolver（诊断用）。

## Record / RecordKeeper

- RecordVal（Record.h:1575）：FieldKind{FK_Normal, FK_NonconcreteOK, FK_TemplateArg}。
  普通字段（FK_Normal）即可保留 `?`；FK_NonconcreteOK 豁免的是 checkConcrete
  的非 concrete 检查（见上），不是 `?` 落地。
- Record（:1663）：RK_Def/RK_AnonymousDef/RK_Class/RK_MultiClass；唯一递增 ID
  （getNewUID，Record.cpp:2813）；拷贝构造分配新 ID。
- resolveReferences（Record.cpp:2833-2882）：先名字（变化则重新注册），
  再逐字段 `Value.setValue(V->resolveReferences(R))`，最后 assertions/dumps。
- RecordKeeper（Record.h:2011）：`RecordMap = std::map<std::string,
  unique_ptr<Record>>`（字典序！），getClasses/getDefs 遍历顺序稳定；
  `getAllDerivedDefinitions`（Record.cpp:3153-3191）结果再经
  `llvm::sort(Defs, LessRecord())`（compare_numeric 字典序）—— 确定性来源。
  E12 已验证两次生成 SHA256 一致。
- 唯一化：RecordKeeperImpl（Record.cpp:53-100）集中所有 FoldingSet 池
  （Bits/List/UnOp/BinOp/TernOp/Dag/RecordType/String/Var/…）——
  指针相等即值相等，后端可放心用指针比较。

## 可观察性

- `--print-records`：RecordKeeper::dumpRecords（Record.cpp:3141），字典序。
- `--dump-json`（JSONBackend.cpp:118-180）：每 def 输出 !name/!superclasses/
  !fields/!locs + 各字段值；DagInit 序列化为 {kind:"dag", operator, args}；
  `!instanceof` 给出 class→实例数组（E01 用此做断言）。
- `--print-detailed-records`（DetailedRecordsBackend.cpp）：额外有 defm 列表、
  分配统计。
- 限制：JSON 只给序列化值；未消解引用、所有权、指针身份需读内部对象。

## SetTheory（SetTheory.h:65-141 / SetTheory.cpp）

把 DAG 表达式求值为有序 Record 集合：内置算子 add/sub/and/shl/trunc/sequence 等；
Expander 按 class 名注册（如 `addFieldExpander("Set","Elements")`）；
`expand` 结果 memo 化。典型用户：print-sets 动作；后端用于寄存器集合运算。
