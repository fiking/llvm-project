def DemoModel : SchedMachineModel {
  let MicroOpBufferSize = 0; // Explicitly set to zero since Demo is in-order.
  let IssueWidth = 3;        // 3 instructions are dispatched per cycle.
  let MinLatency = 1 ;       // OperandCycles are interpreted as MinLatency.
  let LoadLatency = 3;       // Optimistic load latency assuming bypass.
                             // This is overriden by OperandCycles if the
                             // Itineraries are queried instead.
  let MispredictPenalty = 7; // Assumes best-case based on ALU.
  let CompleteModel = 0;     // A few instructions still don't have SchedRW lists.
  let PostRAScheduler = 1;    // Enable PostRA scheduler pass.
}


def DemoUnitALU    : ProcResource<2> { let BufferSize = 0; } // Int ALU
def DemoUnitMACDiv : ProcResource<2> { let BufferSize = 0; } // Int Mul/MAC/Div
def DemoUnitLdSt   : ProcResource<1> { let BufferSize = 0; } // Load/Store
def DemoUnitFPALU  : ProcResource<1> { let BufferSize = 0; } // FP ALU/Mul/MAC
def DemoUnitFPDS   : ProcResource<1> { let BufferSize = 0; } // FP Div/Sqrt


let SchedModel = DemoModel in {

// Integer ALU
let Latency = 3 in {
def : WriteRes<WriteImm,   [DemoUnitALU]>;
def : WriteRes<WriteI,     [DemoUnitALU]>;
def : WriteRes<WriteISReg, [DemoUnitALU]>;
def : WriteRes<WriteIEReg, [DemoUnitALU]>;
def : WriteRes<WriteIS,    [DemoUnitALU]>;
def : WriteRes<WriteExtr,  [DemoUnitALU]>;
}

// Integer Mul/MAC/Div
let Latency = 3 in {
def : WriteRes<WriteIM32, [DemoUnitMACDiv]>;
def : WriteRes<WriteIM64, [DemoUnitMACDiv]>;
def : WriteRes<WriteID32, [DemoUnitMACDiv]>;
def : WriteRes<WriteID64, [DemoUnitMACDiv]>;
}

// Load
let Latency = 3 in {
def : WriteRes<WriteLD,    [DemoUnitLdSt]>;
def : WriteRes<WriteLDIdx, [DemoUnitLdSt]>;
def : WriteRes<WriteLDHi,  [DemoUnitLdSt]>;
}

// Vector Load
def : WriteRes<WriteVLD, [DemoUnitLdSt]> { let Latency = 3; }

// Pre/Post Indexing
def : WriteRes<WriteAdr, [DemoUnitLdSt]> { let Latency = 3; }

// Store
let Latency = 3 in {
def : WriteRes<WriteST,    [DemoUnitLdSt]>;
def : WriteRes<WriteSTP,   [DemoUnitLdSt]>;
def : WriteRes<WriteSTIdx, [DemoUnitLdSt]>;
def : WriteRes<WriteSTX,   [DemoUnitLdSt]>;
}

// Vector Store
def : WriteRes<WriteVST, [DemoUnitLdSt]> { let Latency = 3; }

// Branch
def : WriteRes<WriteBr,      [DemoUnitALU]>;
def : WriteRes<WriteBrReg,   [DemoUnitALU]>;
def : WriteRes<WriteSys,     [DemoUnitALU]>;
def : WriteRes<WriteBarrier, [DemoUnitALU]>;
def : WriteRes<WriteHint,    [DemoUnitALU]>;

// FP ALU, Mul
let Latency = 5 in {
def : WriteRes<WriteF,     [DemoUnitFPALU]>;
def : WriteRes<WriteFCmp,  [DemoUnitFPALU]>;
def : WriteRes<WriteFCvt,  [DemoUnitFPALU]>;
def : WriteRes<WriteFCopy, [DemoUnitFPALU]>;
def : WriteRes<WriteFImm,  [DemoUnitFPALU]>;
def : WriteRes<WriteV,     [DemoUnitFPALU]>;
def : WriteRes<WriteFMul,  [DemoUnitFPDS]>;
}

// FP Div, Sqrt
let Latency = 15 in {
def : WriteRes<WriteFDiv, [DemoUnitFPDS]>;
}

// No forwarding for these reads.
def : ReadAdvance<ReadExtrHi, 0>;
def : ReadAdvance<ReadAdrBase, 0>;
def : ReadAdvance<ReadVLD, 0>;
def : ReadAdvance<ReadI, 0>;
def : ReadAdvance<ReadISReg, 0>;
def : ReadAdvance<ReadIEReg, 0>;
def : ReadAdvance<ReadIM, 0>;
def : ReadAdvance<ReadIMA, 0>;
def : ReadAdvance<ReadID, 0>;

}
