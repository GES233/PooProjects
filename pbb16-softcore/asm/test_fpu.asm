; test_fpu.asm — PBB16 v3 FPU16 MMIO 加速器（槽 3，基址 0xF030）系统测试
; 覆盖：a) FADD 1.5+2.25=3.75      b) FSUB 3.75-2.25=1.5
;       c) FMUL 3.0*0.5=1.5        d) FDIV 3.75/1.5=2.5
;       e) FCMP 小于/等于           f) I2F/F2I：42 往返
;       g) FDIV 1.0/0.0=+Inf 且 DZ  h) FADD Inf+(-Inf)=qNaN 且 NV
; 自检：每项通过置 R7 对应位（bit0..bit7），testbench 停机后检查 R7 == 0x00FF。
; 调用协议：R0=OPA、R1=OPB、R2=CMD，CALL fpu_op → R1=RES、R3=STATUS；
; R4 = FPU 基址 0xF030，全程保持。

        .org 0x0000
start:
        MOVUI R4, 0xF0
        ORI   R4, 0x30          ; R4 = 0xF030

; ---------- a) FADD 1.5 + 2.25 = 3.75 ----------
        MOVUI R0, 0x3E          ; 1.5  = 0x3E00
        MOVUI R1, 0x40
        ORI   R1, 0x80          ; 2.25 = 0x4080
        MOVI  R2, 0
        CALL  fpu_op
        MOVUI R2, 0x43
        ORI   R2, 0x80          ; 3.75 = 0x4380
        CMP   R1, R2
        JNZ   fail_a
        MOVI  R1, 0x01
        OR    R7, R1
fail_a:

; ---------- b) FSUB 3.75 - 2.25 = 1.5 ----------
        MOVUI R0, 0x43
        ORI   R0, 0x80          ; 3.75 = 0x4380
        MOVUI R1, 0x40
        ORI   R1, 0x80          ; 2.25 = 0x4080
        MOVI  R2, 1
        CALL  fpu_op
        MOVUI R2, 0x3E          ; 1.5
        CMP   R1, R2
        JNZ   fail_b
        MOVI  R1, 0x02
        OR    R7, R1
fail_b:

; ---------- c) FMUL 3.0 * 0.5 = 1.5 ----------
        MOVUI R0, 0x42          ; 3.0 = 0x4200
        MOVUI R1, 0x38          ; 0.5 = 0x3800
        MOVI  R2, 2
        CALL  fpu_op
        MOVUI R2, 0x3E          ; 1.5
        CMP   R1, R2
        JNZ   fail_c
        MOVI  R1, 0x04
        OR    R7, R1
fail_c:

; ---------- d) FDIV 3.75 / 1.5 = 2.5 ----------
        MOVUI R0, 0x43
        ORI   R0, 0x80          ; 3.75 = 0x4380
        MOVUI R1, 0x3E          ; 1.5
        MOVI  R2, 3
        CALL  fpu_op
        MOVUI R2, 0x41          ; 2.5 = 0x4100
        CMP   R1, R2
        JNZ   fail_d
        MOVI  R1, 0x08
        OR    R7, R1
fail_d:

; ---------- e) FCMP：-1.0 < 1.0 → 0xFFFF；1.5 == 1.5 → 0 ----------
        MOVUI R0, 0xBC          ; -1.0 = 0xBC00
        MOVUI R1, 0x3C          ;  1.0 = 0x3C00
        MOVI  R2, 4
        CALL  fpu_op
        MOVUI R2, 0xFF
        ORI   R2, 0xFF
        CMP   R1, R2
        JNZ   fail_e
        MOVUI R0, 0x3E          ; 1.5
        MOVUI R1, 0x3E
        MOVI  R2, 4
        CALL  fpu_op
        CMPI  R1, 0
        JNZ   fail_e
        MOVI  R1, 0x10
        OR    R7, R1
fail_e:

; ---------- f) I2F 42 → 0x5140；F2I 回来 → 42 ----------
        MOVI  R0, 42
        MOVI  R2, 5
        CALL  fpu_op
        MOVUI R2, 0x51
        ORI   R2, 0x40          ; 42.0 = 0x5140
        CMP   R1, R2
        JNZ   fail_f
        MOVUI R0, 0x51
        ORI   R0, 0x40
        MOVI  R2, 6
        CALL  fpu_op
        CMPI  R1, 42
        JNZ   fail_f
        MOVI  R1, 0x20
        OR    R7, R1
fail_f:

; ---------- g) FDIV 1.0 / 0.0 → +Inf(0x7C00)，DZ 置位 ----------
        MOVUI R0, 0x3C          ; 1.0
        MOVI  R1, 0
        MOVI  R2, 3
        CALL  fpu_op
        MOVUI R2, 0x7C
        CMP   R1, R2
        JNZ   fail_g
        ANDI  R3, 2             ; STATUS bit1 = DZ
        CMPI  R3, 2
        JNZ   fail_g
        MOVI  R1, 0x40
        OR    R7, R1
fail_g:

; ---------- h) FADD Inf + (-Inf) → qNaN(0x7E00)，NV 置位 ----------
        MOVUI R0, 0x7C          ; +Inf
        MOVUI R1, 0xFC          ; -Inf
        MOVI  R2, 0
        CALL  fpu_op
        MOVUI R2, 0x7E
        CMP   R1, R2
        JNZ   fail_h
        ANDI  R3, 4             ; STATUS bit2 = NV
        CMPI  R3, 4
        JNZ   fail_h
        MOVI  R1, 0x80
        OR    R7, R1
fail_h:
        HLT

; ---------- 库：R0=OPA、R1=OPB、R2=CMD → R1=RES、R3=STATUS ----------
fpu_op:
        STR.W R0, 0(R4)         ; OPA
        STR.W R1, 2(R4)         ; OPB
        STR.W R2, 4(R4)         ; CMD（写即触发，瞬时完成）
        LOD.W R1, 8(R4)         ; RES
        LOD.W R3, 6(R4)         ; STATUS
        RET
