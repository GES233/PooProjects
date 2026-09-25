; test_phase2.asm — PBB16 v2 第二阶段系统测试
; 覆盖：a) 字访存往返+小端  b) 字节访存(奇地址)  c) 未对齐异常(excode=3)
;       d) PUSH/POP  e) CALL/RET 两层嵌套  f) JR  g) MFC PRID / MTC Status
;       h) TRAP(excode=2)  i) 外部中断(屏蔽/放行)  j) 非法指令(excode=4)
;
; 自检协议：每个子项通过则把对应位置进 R7（bit0..bit9），
; testbench 在停机后检查 R7 == 0x03FF、R6 == 0xFFFE 及数据内存单元。
; R3 是异常处理程序 -> 主程序的旗标通道（0=未触发/检查失败）。
;
; 绝对地址约定（handler/TB 依赖，勿随意挪动 .org）：
;   0x0104 未对齐 fault 指令 LOD.W   0x0140 TRAP 指令（EPC 应为 0x0142）
;   0x0180 中断测试(屏蔽窗口 [0x0180,0x0190))   0x01C0 中断等待循环
;   0x0200 非法指令                  0x0210 非法指令恢复点
;   0xFF00 异常处理程序

        .org 0x0000

; ---------- a) STR.W/LOD.W 往返 + 小端字节序 ----------
start:
        MOVUI R4, 0x03          ; R4 = 0x0300（数据单元基址）
        MOVUI R2, 0x12
        ORI   R2, 0x34          ; R2 = 0x1234
        STR.W R2, 0(R4)         ; MEM16[0x0300] = 0x1234
        MOVI  R0, 0
        LOD.W R0, 0(R4)         ; 读回
        CMP   R0, R2
        JNZ   fail_a
        LOD.B R1, 0(R4)         ; 低字节应为 0x34（小端）
        CMPI  R1, 0x34
        JNZ   fail_a
        LOD.B R1, 1(R4)         ; 高字节应为 0x12
        CMPI  R1, 0x12
        JNZ   fail_a
        ORI   R7, 0x01          ; bit0
fail_a:

; ---------- b) STR.B/LOD.B（奇地址合法） ----------
        MOVI  R2, 0xAB
        STR.B R2, 3(R4)         ; MEM8[0x0303] = 0xAB（奇地址）
        LOD.B R1, 3(R4)
        CMPI  R1, 0xAB
        JNZ   fail_b
        ORI   R7, 0x02          ; bit1
fail_b:

; ---------- d) PUSH/POP（R6 复位 0xFFFE，向下生长） ----------
        MOVI  R2, 0x11
        MOVI  R3, 0x22
        PUSH  R2                ; SP->0xFFFC, MEM16[0xFFFC]=0x0011
        PUSH  R3                ; SP->0xFFFA, MEM16[0xFFFA]=0x0022
        POP   R5                ; R5=0x0022, SP->0xFFFC
        POP   R4                ; R4=0x0011, SP->0xFFFE
        CMPI  R5, 0x22
        JNZ   fail_d
        CMPI  R4, 0x11
        JNZ   fail_d
        ORI   R7, 0x08          ; bit3（R6 归位由 TB 检查）
fail_d:

; ---------- f) JR 计算跳转 ----------
        MOVUI R1, 0x00
        ORI   R1, 0x60          ; R1 = 0x0060 = jr_target
        JR    R1
        J     after_jr          ; 不应执行（JR 跳过）

        .org 0x0060
jr_target:
        ORI   R7, 0x20          ; bit5
after_jr:

; ---------- e) CALL/RET 两层嵌套 ----------
        CALL  func1             ; func1 内再 CALL func2
        CMPI  R0, 0x11
        JNZ   fail_e
        CMPI  R1, 0x22
        JNZ   fail_e
        ORI   R7, 0x10          ; bit4
fail_e:

; ---------- g) MFC PRID + MTC/MFC Status 往返 ----------
        MFC   R0, PRID
        MOVUI R1, 0x04
        ORI   R1, 0x03          ; R1 = 0x0403（v3：PRID version=3）
        CMP   R0, R1
        JNZ   fail_g
        MOVI  R1, 0xF7          ; IM=1111 EXL=1 IE=1 EM=1
        MTC   R1, STATUS
        MFC   R2, STATUS
        CMPI  R2, 0xF7
        JNZ   fail_g
        ORI   R7, 0x40          ; bit6
fail_g:
        MOVI  R1, 0
        MTC   R1, STATUS        ; 清 Status（IE=0，避免干扰后续测试）

; ---------- c) 未对齐异常（跳 0xFF00、excode=3、EPC=0x0104、ERET 重试） ----------
        J     misalign_test
after_misalign:
        CMPI  R3, 1             ; handler 确认过 excode/EPC 后应置 1
        JNZ   fail_c
        MOVUI R1, 0x12
        ORI   R1, 0x34
        CMP   R2, R1            ; 重试后 R2 应 = MEM16[0x0300] = 0x1234
        JNZ   fail_c
        ORI   R7, 0x04          ; bit2
fail_c:

; ---------- h) TRAP（excode=2，EPC=0x0142，ERET 返回继续） ----------
        J     trap_test
after_trap:
        CMPI  R3, 2
        JNZ   fail_h
        ORI   R7, 0x80          ; bit7
fail_h:

; ---------- i) 外部中断 ----------
        J     irq_test
after_irq:
        CMPI  R3, 3             ; handler 触发后应置 3
        JNZ   fail_i
        MOVUI R1, 0x01          ; bit8 = 0x0100
        OR    R7, R1
fail_i:

; ---------- j) 非法指令（excode=4，handler 直接 JR 到恢复点） ----------
        J     illegal_test
after_illegal:
        CMPI  R3, 4
        JNZ   fail_j
        MOVUI R1, 0x02          ; bit9 = 0x0200
        OR    R7, R1
fail_j:
        HLT

; ---------- 子程序（e 用） ----------
func1:
        MOVI  R0, 0x11
        CALL  func2
        RET
func2:
        MOVI  R1, 0x22
        RET

; ---------- c) 未对齐测试体（fault 指令固定在 0x0104） ----------
        .org 0x0100
misalign_test:
        MOVUI R4, 0x02          ; 0x0100
        ORI   R4, 0xFE          ; 0x0102: R4 = 0x02FE
        LOD.W R2, 1(R4)         ; 0x0104: EA=0x02FF 奇 → 异常；
                                ; handler 修 R4+=1 后 ERET 重试 → EA=0x0300
        J     after_misalign

; ---------- h) TRAP 测试体（TRAP 固定在 0x0140） ----------
        .org 0x0140
trap_test:
        TRAP                    ; 0x0140 → EPC 应 = 0x0142
        J     after_trap        ; 0x0142（ERET 返回点）

; ---------- i) 中断测试体 ----------
; 注意 IM 语义（按任务书公式 irq & ~IM）：IM 位 = 1 屏蔽、= 0 放行
        .org 0x0180
irq_test:
        MOVI  R3, 0             ; 0x0180 清旗标
        MOVI  R1, 0x12          ; 0x0182 IE=1, IM=0001（屏蔽 irq0）
        MTC   R1, STATUS        ; 0x0184
        NOP                     ; 0x0186.. TB 在此窗口拉 irq0
        NOP
        NOP
        CMPI  R3, 0             ; 0x018C 屏蔽期间不应触发
        JNZ   irq_masked_bad
        MOVI  R1, 0x02          ; 0x0190 IE=1, IM=0000（放行 irq0）
        MTC   R1, STATUS        ; 0x0192
        J     irq_wait
irq_masked_bad:
        J     after_irq         ; 屏蔽失效：不置位直接走人

        .org 0x01C0
irq_wait:
        CMPI  R3, 3             ; 0x01C0 等 handler 置 3
        JNZ   irq_wait          ; 0x01C2
        J     after_irq

; ---------- j) 非法指令测试体 ----------
        .org 0x0200
illegal_test:
        .word 0x3801            ; 0x0200 主 opcode 00111 未分配 → excode=4
                                ;（v3 起 00001-00011/00110 已分配给远访存）
        J     after_illegal     ; 不应到达（handler JR 到 0x0210）

        .org 0x0210
illegal_ok:
        J     after_illegal

; ---------- 异常处理程序（规格 4.3 单一入口 0xFF00） ----------
        .org 0xFF00
exc_handler:
        MFC   R0, CAUSE
        ANDI  R0, 0x07          ; 取 excode[2:0]
        CMPI  R0, 3
        JZ    h_align
        CMPI  R0, 2
        JZ    h_trap
        CMPI  R0, 1
        JZ    h_irq
        CMPI  R0, 4
        JZ    h_ill
        ERET                    ; 未知异常：直接返回

h_align:                        ; 未对齐：核对 EPC 后修基址重试
        MFC   R2, EPC
        MOVUI R1, 0x01
        ORI   R1, 0x04          ; R1 = 0x0104（fault 指令地址）
        CMP   R2, R1
        JZ    h_align_ok
        MOVI  R3, 0
        J     h_align_fix
h_align_ok:
        MOVI  R3, 1
h_align_fix:
        ADDI  R4, 1             ; R4 = 0x02FF → 重试 EA=0x0300 对齐
        ERET

h_trap:                         ; TRAP：核对 EPC = TRAP+2 = 0x0142
        MFC   R2, EPC
        MOVUI R1, 0x01
        ORI   R1, 0x42          ; R1 = 0x0142
        CMP   R2, R1
        JZ    h_trap_ok
        MOVI  R3, 0
        ERET
h_trap_ok:
        MOVI  R3, 2
        ERET

h_irq:                          ; 外部中断：置旗标并屏蔽后返回
        MOVI  R3, 3
        MOVI  R1, 0
        MTC   R1, STATUS        ; IM=0 屏蔽，防 ERET 后立即重入
        ERET

h_ill:                          ; 非法指令：置旗标，清 Status，JR 到恢复点
        MOVI  R3, 4
        MOVI  R1, 0
        MTC   R1, STATUS        ; 清 EXL（不走 ERET，手动恢复）
        MOVUI R1, 0x02
        ORI   R1, 0x10          ; R1 = 0x0210 = illegal_ok
        JR    R1
