; count_loop.asm — PBB16 v2 计数循环（docs/PBB16_v2_ISA.md 第 5 节样例）
; 期望机器码（字序列）：20FF 2201 4140 D9FF AEFC FFFF
; R1 从 0 累加到 0xFF 后停机，HLT 停在 0x000A。

        .org 0x0000

        MOVI R0, 0xFF      ; R0 = 0x00FF（本程序未直接使用，与规格样例保持一致）
        MOVI R2, 1         ; R2 = 1（步长）
loop:   ADD  R1, R2        ; R1 += R2
        CMPI R1, 0xFF      ; R1 == 0xFF ?（零扩展比较）
        JNZ  loop          ; Z==0 则跳回 loop（JCC Z, 0, loop 的糖）
        HLT
