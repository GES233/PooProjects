; test_timer.asm — PBB16 v3 定时器（槽 1，基址 0xF010）系统测试
; 覆盖：a) 轮询：到期置位、读后清零   b) 中断 ×2：excode=1 且 Cause.IP bit5=1、
;          handler 读 STATUS 清挂起后 ERET   c) enable=0 后不再到期
; 自检：每项通过置 R7 对应位（bit0..bit2），testbench 停机后检查 R7 == 0x0007。
; 约定：R4 = 定时器基址 0xF010（全程保持，handler 也用）；R5 = 中断次数计数；
; handler 只动 R0/R5。异常 handler 在 0xFF00。

        .org 0x0000
start:
        MOVUI R4, 0xF0
        ORI   R4, 0x10          ; R4 = 0xF010

; ---------- a) 轮询：PERIOD=40，等 pending 置位、读后清零 ----------
        MOVI  R0, 40
        STR.W R0, 0(R4)         ; PERIOD = 40 clk
        MOVI  R0, 1
        STR.W R0, 2(R4)         ; enable=1, ie=0
poll_a:
        LOD.W R1, 4(R4)         ; 读 STATUS（同时弹出 pending）
        ANDI  R1, 1
        JZ    poll_a
        LOD.W R1, 4(R4)         ; 刚弹出，立刻再读应为 0
        CMPI  R1, 0
        JNZ   fail_a
        MOVI  R0, 0
        STR.W R0, 2(R4)         ; 停表
        MOVI  R1, 0x01
        OR    R7, R1
fail_a:

; ---------- b) 中断：放行 irq1，等 handler 计满 2 次 ----------
        MOVI  R5, 0
        MOVI  R0, 40
        STR.W R0, 0(R4)         ; PERIOD = 40
        MOVI  R0, 0xD2          ; IM=1101（仅放行 irq1）、IE=1
        MTC   R0, STATUS
        MOVI  R0, 3
        STR.W R0, 2(R4)         ; enable=1, ie=1
wait2:
        CMPI  R5, 2
        JNZ   wait2
        MOVI  R0, 0
        STR.W R0, 2(R4)         ; 停表
        MTC   R0, STATUS        ; 关中断
        MOVI  R1, 0x02
        OR    R7, R1

; ---------- c) 禁用后不再到期 ----------
        LOD.W R1, 4(R4)         ; 清可能残留的 pending
        MOVI  R0, 30
dly:
        ADDI  R0, -1
        JNZ   dly               ; 空转 ~300 clk（远超 PERIOD）
        LOD.W R1, 4(R4)
        CMPI  R1, 0             ; 禁用期间不应再置位
        JNZ   fail_c
        MOVI  R1, 0x04
        OR    R7, R1
fail_c:
        HLT

; ---------- 异常处理程序（单一入口 0xFF00） ----------
        .org 0xFF00
tm_handler:
        MFC   R0, CAUSE
        ANDI  R0, 0x07
        CMPI  R0, 1             ; excode=1（外部中断）
        JNZ   tm_bad
        MFC   R0, CAUSE
        ANDI  R0, 0x20          ; Cause.IP[1]（irq1）应挂起
        JZ    tm_bad
        ADDI  R5, 1
        LOD.W R0, 4(R4)         ; 读 STATUS 清 pending（否则 ERET 后立刻再进）
        ERET
tm_bad:
        HLT                     ; 异常来源不对：停机即 FAIL
