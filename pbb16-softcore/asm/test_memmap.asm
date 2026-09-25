; test_memmap.asm — PBB16 v3 内存映射系统测试（banking + 远访存）
; 覆盖：a) CR4-7 复位值 0/1/2/3        b) banking：BANK1=2 时逻辑 0x4000 → 物理 0x8000
;       c) FSTR.W/FLOD.W 远字往返（物理 0x100000，>64KB）
;       d) FSTR.B/FLOD.B 远字节 + banked 近访问别名一致
;       e) MAPE=1 时 MMIO 不可达（写 UART 槽不触发 TX，读回 RAM 别名值）
;       f) TRAP：进异常 MAPS←1/MAPE←0，ERET 恢复 MAPE=1
;       g) FLOD.W 奇物理地址 → excode=3
;
; 自检协议：每个子项通过则把对应位置进 R7（bit0..bit6），
; testbench 在停机后检查 R7 == 0x007F、物理内存单元、UART 未发一字节。
; 约定：程序主体 < 0x4000（窗口 0，BANK0 恒 0，映射态下取指仍落在低 64KB）；
; R4 全程保持 0x4000（窗口 1 基址）；R3/R5 兼作 handler 的旗标通道。
;
; 绝对地址约定（handler/TB 依赖，勿随意挪动 .org）：
;   0x0200 远访存未对齐 fault 指令   0x0220 恢复点   0xFF00 异常处理程序

        .org 0x0000

; ---------- a) CR4–CR7 复位值 = 0/1/2/3（直通） ----------
start:
        MFC   R0, BANK0
        CMPI  R0, 0
        JNZ   fail_a
        MFC   R1, BANK1
        CMPI  R1, 1
        JNZ   fail_a
        MFC   R2, BANK2
        CMPI  R2, 2
        JNZ   fail_a
        MFC   R3, BANK3
        CMPI  R3, 3
        JNZ   fail_a
        MOVI  R1, 0x01
        OR    R7, R1
fail_a:

; ---------- b) banking：BANK1=2 → 逻辑 0x4000 映射到物理 0x8000 ----------
        MOVUI R4, 0x40          ; R4 = 0x4000（全程保持）
        MOVUI R2, 0x11
        ORI   R2, 0x11          ; 0x1111
        STR.W R2, 0(R4)         ; MAPE=0 → 物理 0x4000
        MOVI  R1, 2
        MTC   R1, BANK1
        MFC   R0, STATUS
        ORI   R0, 8
        MTC   R0, STATUS        ; MAPE=1
        MOVUI R2, 0x22
        ORI   R2, 0x22          ; 0x2222
        STR.W R2, 0(R4)         ; → 物理 0x8000
        LOD.W R3, 0(R4)
        CMP   R3, R2
        JNZ   fail_b
        MFC   R0, STATUS
        ANDI  R0, 0xF7
        MTC   R0, STATUS        ; MAPE=0
        LOD.W R3, 0(R4)         ; 直通 → 物理 0x4000 的 0x1111
        MOVUI R1, 0x11
        ORI   R1, 0x11
        CMP   R3, R1
        JNZ   fail_b
        MOVI  R1, 0x02
        OR    R7, R1
fail_b:

; ---------- c) 远字往返：寄存器对 R1:R0 = 0x100000（>64KB） ----------
        MOVI  R0, 0
        MOVI  R1, 0x10          ; 对高位低 6 位 = 0x10
        MOVUI R2, 0x12
        ORI   R2, 0x34          ; 0x1234
        FSTR.W R2, 0(R0)
        FLOD.W R3, 0(R0)
        CMP   R3, R2
        JNZ   fail_c
        MOVI  R1, 0x04
        OR    R7, R1
fail_c:

; ---------- d) 远字节 + banked 近访问别名同一物理单元 ----------
        MOVI  R1, 0x10          ; c) 末尾 R1 已作他用，重建对高位
        MOVI  R2, 0x5A
        FSTR.B R2, 1(R0)        ; 物理 0x100001 = 0x5A
        MOVI  R1, 0x40
        MTC   R1, BANK1         ; 窗口 1 → 物理 0x100000
        MFC   R1, STATUS
        ORI   R1, 8
        MTC   R1, STATUS        ; MAPE=1
        LOD.B R3, 1(R4)         ; 逻辑 0x4001 → 物理 0x100001
        MFC   R1, STATUS
        ANDI  R1, 0xF7
        MTC   R1, STATUS        ; MAPE=0
        CMPI  R3, 0x5A
        JNZ   fail_d
        MOVI  R1, 0x08
        OR    R7, R1
fail_d:

; ---------- e) MAPE=1 时 MMIO 不可达 ----------
        MFC   R1, STATUS
        ORI   R1, 8
        MTC   R1, STATUS        ; MAPE=1（BANK3=3，0xF002 → 物理 0xF002 RAM）
        MOVUI R5, 0xF0
        ORI   R5, 0x02          ; UART TXDATA
        MOVI  R2, 0x58          ; 'X'
        STR.B R2, 0(R5)         ; 若 MMIO 可达会发一字节（TB 检查 tx_count=0）
        MOVUI R5, 0xF0
        ORI   R5, 0x04          ; UART STATUS
        MOVI  R2, 0
        STR.B R2, 0(R5)
        LOD.B R3, 0(R5)         ; MMIO 可达则读回 0x02（tx_ready），RAM 别名则 0
        MFC   R1, STATUS
        ANDI  R1, 0xF7
        MTC   R1, STATUS        ; MAPE=0
        CMPI  R3, 0
        JNZ   fail_e
        MOVI  R1, 0x10
        OR    R7, R1
fail_e:

; ---------- f) TRAP：MAPS/MAPE 影子保存与恢复 ----------
        MOVI  R5, 0             ; handler 旗标清零
        MFC   R1, STATUS
        ORI   R1, 8
        MTC   R1, STATUS        ; MAPE=1（BANK1=0x40 仍指 0x100000）
        MOVUI R2, 0x66
        ORI   R2, 0x66          ; 0x6666
        STR.W R2, 0(R4)         ; 物理 0x100000 = 0x6666
        TRAP                    ; 硬件：MAPS←1, MAPE←0, PC←0xFF00
        LOD.W R3, 0(R4)         ; ERET 后 MAPE 应已恢复 → 仍读物理 0x100000
        CMP   R3, R2
        JNZ   fail_f
        CMPI  R5, 1             ; handler 确认过 MAPS=1 且自身 MAPE=0
        JNZ   fail_f
        MFC   R1, STATUS
        ANDI  R1, 0xF7
        MTC   R1, STATUS        ; MAPE=0
        MOVI  R1, 0x20
        OR    R7, R1
fail_f:

; ---------- g) 远字访存奇物理地址 → excode=3 ----------
        MOVI  R3, 0
        J     align_test
after_align:
        CMPI  R3, 3
        JNZ   fail_g
        MOVI  R1, 0x40
        OR    R7, R1
fail_g:
        HLT

; ---------- g) 测试体 ----------
        .org 0x0200
align_test:
        MOVI  R0, 0
        MOVI  R1, 0x10          ; 对 R1:R0 = 0x100000
        FLOD.W R3, 1(R0)        ; 物理 0x100001 奇地址 → excode=3，不访存
        J     after_align       ; 不应到达（handler JR 到 0x0220）

        .org 0x0220
align_ok:
        J     after_align

; ---------- 异常处理程序（单一入口 0xFF00，直通态运行） ----------
        .org 0xFF00
exc_handler:
        MFC   R0, CAUSE
        ANDI  R0, 0x07
        CMPI  R0, 2
        JZ    h_trap
        CMPI  R0, 3
        JZ    h_align
        HLT                     ; 未预期的异常：停机即 FAIL

h_trap:                         ; f)：确认 MAPS=1、excode=2、handler 内 MAPE=0
        MFC   R0, CAUSE
        ANDI  R0, 0x0B
        CMPI  R0, 0x0A          ; MAPS(bit3)=1 且 excode=2
        JNZ   h_trap_done
        MFC   R1, STATUS
        ANDI  R1, 8
        JNZ   h_trap_done       ; MAPE 应为 0
        MOVI  R5, 1
h_trap_done:
        ERET                    ; MAPE ← MAPS = 1

h_align:                        ; g)：置旗标，清 Status，JR 到恢复点
        MOVI  R3, 3
        MOVI  R1, 0
        MTC   R1, STATUS        ; 清 EXL（不走 ERET，手动恢复）
        MOVUI R1, 0x02
        ORI   R1, 0x20          ; R1 = 0x0220 = align_ok
        JR    R1
