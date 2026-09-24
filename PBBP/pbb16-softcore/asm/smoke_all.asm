; smoke_all.asm — 覆盖 PBB16 v2 规格第 3 节全部指令的冒烟程序
; 仅验证汇编器能正确编码每条指令，不要求在本期硬件上运行
; （访存/栈/调用类数据通路尚未接线）。

        .org 0x0000

; ---- 3.1 空操作 / 停机 ----
        NOP

; ---- 3.2 立即数装载（I8） ----
        MOVI  R0, 0x12
        MOVUI R1, 0x34

; ---- 3.3 立即数运算（I8） ----
        ADDI R0, 1
        ADDI R0, -1          ; 负立即数
        ANDI R2, 0x0F
        ORI  R3, 255
        CMPI R0, 0xFF

; ---- 3.4 寄存器运算（R 型，fct5） ----
        ADD  R0, R1
        SUB  R0, R1
        ADC  R0, R1
        SBB  R0, R1
        MUL  R2, R3
        MLH  R2, R3
        DIV  R2, R3
        REM  R2, R3
        AND  R4, R5
        OR   R4, R5
        XOR  R4, R5
        NAND R4, R5
        NOR  R4, R5
        NOT  R6, R0
        MOV  R7, R0
        XCHG R0, R1
        CMP  R0, R1
        CMPU R0, R1
        SHL  R0, R1          ; 按 R[rs][3:0] 移位（R 型）
        SHR  R0, R1
        SAR  R0, R1
        ROL  R0, R1
        ROR  R0, R1

; ---- 3.5 立即数移位（S 型，fct4） ----
        SHL  R0, 3
        SHR  R1, 2
        SAR  R2, 1
        ROL  R3, 15
        ROR  R4, 0

; ---- 3.6 访存（M 型，基址 + Imm5） ----
        LOD.W R2, 4(R4)
        STR.W R2, -2(R4)     ; 负偏移
        LOD.B R2, 15(R4)
        STR.B R2, -16(R4)
        LOD.W R3, R5, 8      ; 三操作数形式

; ---- 3.7 栈 / 计算跳转（A 型） ----
        PUSH R0
        POP  R1
        JR   R5

; ---- 3.8 跳转 / 调用 ----
self:   J     self           ; 偏移 0
        J     fwd
fwd:    JCC   Z, 1, fwd      ; 通用形（偏移 0）
        JCC   V, 0, fwd
        JCC   S, 1, fwd
        JCC   C, 0, fwd
        JZ    fwd            ; 糖：8 个条件跳转别名
        JNZ   fwd
        JS    fwd
        JNS   fwd
        JC    fwd
        JNC   fwd
        JV    fwd
        JNV   fwd
        CALL  sub
        RET

; ---- 3.9 控制寄存器与系统 ----
        MFC  R0, CR8         ; Status（也接受名字：MFC R0, STATUS）
        MTC  R1, 9           ; Cause，纯数字形式
        TRAP
        ERET

; ---- 伪指令 ----
data:   .word 0x1234, -1     ; -> 34 12 FF FF
        .byte 0xAB, -1, 42   ; -> AB FF 2A

        HLT

sub:    RET                  ; CALL 目标（嵌套调用在硬件接通后可用）
