; REQUIRES: asserts
; RUN: llc < %s -mtriple=arm64-linux-gnu -mcpu=demo -pre-RA-sched=source -enable-misched -verify-misched -debug-only=machine-scheduler -o - 2>&1 > /dev/null | FileCheck %s
;
; The Cortex-A53 machine model will cause the FDIVvvv_42 to be raised to
; hide latency. Whereas normally there would only be a single FADDvvv_4s
; after it, this test checks to make sure there are more than one.
;
; CHECK: ********** MI Scheduling **********
; CHECK: neon4xfloat:BB#0
; CHECK: *** Final schedule for BB#0 ***
; CHECK: FDIVv4f32
; CHECK: FADDv4f32
; CHECK: FADDv4f32
; CHECK: ********** INTERVALS **********
define <4 x float> @neon4xfloat(<4 x float> %A, <4 x float> %B) {
        %tmp1 = fadd <4 x float> %A, %B;
        %tmp2 = fadd <4 x float> %A, %tmp1;
        %tmp3 = fadd <4 x float> %A, %tmp2;
        %tmp4 = fadd <4 x float> %A, %tmp3;
        %tmp5 = fadd <4 x float> %A, %tmp4;
        %tmp6 = fadd <4 x float> %A, %tmp5;
        %tmp7 = fadd <4 x float> %A, %tmp6;
        %tmp8 = fadd <4 x float> %A, %tmp7;
        %tmp9 = fdiv <4 x float> %A, %B;
        %tmp10 = fadd <4 x float> %tmp8, %tmp9;

        ret <4 x float> %tmp10
}

; Function Attrs: nounwind
declare void @llvm.memcpy.p0i8.p0i8.i64(i8* nocapture, i8* nocapture readonly, i64, i32, i1) #1

attributes #0 = { nounwind "less-precise-fpmad"="false" "no-frame-pointer-elim"="true" "no-frame-pointer-elim-non-leaf" "no-infs-fp-math"="false" "no-nans-fp-math"="false" "stack-protector-buffer-size"="8" "unsafe-fp-math"="false" "use-soft-float"="false" }
attributes #1 = { nounwind }
