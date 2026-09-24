; test_bus_uart.asm — PBB16 v2 第三阶段系统测试（总线 + MMIO UART）
; 覆盖：a) STR.B 写 TXDATA 输出 "PBB16 OK\n"  b) RX 轮询读 'A','B'
;       c) RX 接收中断（excode=1，handler 读 RXDATA 后 ERET）
;       d) MMIO 空洞读 0/写忽略  e) MMIO 字访问奇地址 → excode=3
;
; 自检协议：通过位置 R7 bit0..bit4，TB 停机后检查 R7==0x001F、R6==0xFFFE
; 及 UART tx_log 内容。R3 是 handler -> 主程序旗标。
;
; 绝对地址约定（handler/TB 依赖）：
;   0x0102 MMIO 未对齐 fault 指令   0x0180 RX 中断设置   0x01C0 中断等待循环
;   0x0300 字符串表                 0xFF00 异常处理程序
; UART 寄存器（基址 0xF000）：RXDATA=+0 TXDATA=+2 STATUS=+4 CONTROL=+6

        .org 0x0000

; ---------- a) TX：STR.B 逐字节写 "PBB16 OK\n" ----------
start:
        MOVUI R4, 0xF0          ; R4 = 0xF000（UART 基址，全程序保持）
        MOVUI R5, 0x03          ; R5 = 0x0300（字符串表）
        MOVI  R1, 9             ; 9 字节
tx_loop:
        LOD.B R2, 0(R5)
        STR.B R2, 2(R4)         ; TXDATA（字节写）
        ADDI  R5, 1
        ADDI  R1, -1
        JNZ   tx_loop
        ORI   R7, 0x01          ; bit0（内容由 TB 对 tx_log 验证）

; ---------- b) RX 轮询：预置输入 'A','B' ----------
rx_poll1:
        LOD.W R1, 4(R4)         ; STATUS
        ANDI  R1, 1             ; rx_ready?
        JZ    rx_poll1
        LOD.B R2, 0(R4)         ; RXDATA → 'A'，读后清
        CMPI  R2, 0x41
        JNZ   fail_b
rx_poll2:
        LOD.W R1, 4(R4)
        ANDI  R1, 1
        JZ    rx_poll2
        LOD.B R2, 0(R4)         ; → 'B'
        CMPI  R2, 0x42
        JNZ   fail_b
        LOD.W R1, 4(R4)         ; 两字节读完，rx_ready 应清 0
        ANDI  R1, 1
        JNZ   fail_b
        ORI   R7, 0x02          ; bit1
fail_b:

; ---------- d) MMIO 空洞（0xF080）：读 0、写忽略 ----------
        MOVUI R5, 0xF0
        ORI   R5, 0x80          ; R5 = 0xF080
        LOD.W R1, 0(R5)
        CMPI  R1, 0
        JNZ   fail_d
        MOVI  R2, 0x55
        STR.W R2, 0(R5)         ; 写忽略
        LOD.W R1, 0(R5)
        CMPI  R1, 0
        JNZ   fail_d
        ORI   R7, 0x08          ; bit3
fail_d:

; ---------- e) MMIO 字访问奇地址 → excode=3 ----------
        J     misalign_test
after_misalign:
        CMPI  R3, 1             ; handler 确认 excode/EPC 后应置 1
        JNZ   fail_e
        ORI   R7, 0x10          ; bit4
fail_e:

; ---------- c) RX 接收中断 ----------
        J     irq_test
after_irq:
        CMPI  R3, 1             ; handler 读到 'X' 后应置 1
        JNZ   fail_c
        ORI   R7, 0x04          ; bit2
fail_c:
        HLT

; ---------- e) 未对齐测试体（fault 指令固定在 0x0102） ----------
        .org 0x0100
misalign_test:
        MOVUI R5, 0xF0          ; 0x0100: R5 = 0xF000
        LOD.W R1, 1(R5)         ; 0x0102: EA=0xF001 奇 → excode=3；
                                ; handler 修 R5+=1 后 ERET 重试 → EA=0xF002 对齐
        J     after_misalign

; ---------- c) 中断测试体 ----------
        .org 0x0180
irq_test:
        MOVI  R3, 0             ; 清旗标
        MOVI  R2, 1
        STR.W R2, 6(R4)         ; CONTROL.ie = 1
        MOVI  R1, 0x02          ; CPU Status：IE=1, IM=0000（放行 irq0）
        MTC   R1, STATUS

        .org 0x01C0
irq_wait:
        CMPI  R3, 1             ; 0x01C0 TB 在此窗口注入字节 'X'
        JNZ   irq_wait          ; 0x01C2
        J     after_irq

; ---------- 字符串表（a 用，9 字节 "PBB16 OK\n"） ----------
        .org 0x0300
msg:    .byte 0x50, 0x42, 0x42, 0x31, 0x36, 0x20, 0x4F, 0x4B, 0x0A

; ---------- 异常处理程序（单一入口 0xFF00） ----------
        .org 0xFF00
exc_handler:
        MFC   R0, CAUSE
        ANDI  R0, 0x07          ; excode
        CMPI  R0, 3
        JZ    h_align
        CMPI  R0, 1
        JZ    h_irq
        ERET                    ; 其他：直接返回

h_align:                        ; 未对齐：核对 EPC=0x0102 后修基址重试
        MFC   R2, EPC
        MOVUI R1, 0x01
        ORI   R1, 0x02          ; R1 = 0x0102
        CMP   R2, R1
        JZ    h_align_ok
        MOVI  R3, 0
        J     h_align_fix
h_align_ok:
        MOVI  R3, 1
h_align_fix:
        ADDI  R5, 1             ; R5 = 0xF001 → 重试 EA=0xF002 对齐
        ERET

h_irq:                          ; RX 中断：读 RXDATA 核对 'X'，关 ie 后返回
        LOD.B R2, 0(R4)         ; 读后 rx_ready 清 0，中断线随之撤除
        CMPI  R2, 0x58
        JNZ   h_irq_bad
        MOVI  R3, 1
        J     h_irq_ret
h_irq_bad:
        MOVI  R3, 0
h_irq_ret:
        MOVI  R2, 0
        STR.W R2, 6(R4)         ; CONTROL.ie = 0 防重入
        ERET
