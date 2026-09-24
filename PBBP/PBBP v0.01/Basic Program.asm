0x00        Code:   NOP                 ;****Basic Program****                             Data:0x00
0x01             LOD:MOVI $1, 0x01      ;0000 0001 => $1                                        0x21
0x02                ;(Immed)                                                                    0x01
0x03                 LOD $3, LODADDR    ;[1111 1111 (Addr)=> Data] => $3                        0x33
0x04                ;(Addr)                                                                     0xff
0x05                 MOV $1, $2         ;$1 => $2                                               0x16
0x06             ADD:ADD $1, $2         ;$1 + $2 => $2                                          0x66
0x07                BNE $2, $3, ADD     ;if [$3(Data) != $2(Data)] then jmp (jmp addr)          0x8e
0x08               ;(Addr)                                                                      0x05
0x09                MOV $2, $0          ;\    =>                                                0x18
0X0a                MOV $1, $2          ; |-$1  $2                                              0x16
0x0b                MOV $0, $1          ;/    <=                                                0x11
0x0c                MOVI $0, 0x00       ;0000 0000 => $0                                        0x20
0x0d               ;(Immed)                                                                     0x00
0x0e              SUB:SUB $1, $2        ;$1 - $2 => $1                                          0xa6
0x0f                BNE $2, $3, SUB     ;if [$1(Data) != $3(Data)] then jmp (jmp addr)          0x8a
0x10               ;(Addr)                                                                      0x0f
0x11                STR $2, STRADDR     ;$2(Data) => [1111 1110(Addr)]                          0x42
0x12               ;(Addr)                                                                      0xfe
0x13                HLT                 ;Halt                                                   0xff

0xfe              STRADDR:(Data)                                                                0x00
0xff              LODADDR:(Data)                                                                0xff