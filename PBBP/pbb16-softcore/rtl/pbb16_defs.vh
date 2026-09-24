// pbb16_defs.vh — PBB16 v2 常量定义（对照 docs/PBB16_v2_ISA.md 第 3 节）
// 主操作码 = op1[15:13] + op2[12:11]，共 5 位

// ---- 主操作码（instr[15:11]） ----
`define OP_NOP    5'b00000   // NOP
`define OP_MOVI   5'b00100   // MOVI  R[rd] = zext(Imm8)
`define OP_MOVUI  5'b00101   // MOVUI R[rd] = Imm8 << 8
`define OP_RTYPE  5'b01000   // R 型寄存器运算（fct5）
`define OP_STYPE  5'b01001   // S 型立即数移位（fct4）
`define OP_LODW   5'b01100   // LOD.W
`define OP_STRW   5'b01101   // STR.W
`define OP_LODB   5'b01110   // LOD.B
`define OP_STRB   5'b01111   // STR.B
`define OP_PUSH   5'b10000   // PUSH
`define OP_POP    5'b10001   // POP
`define OP_JR     5'b10010   // JR
`define OP_J      5'b10100   // J    PC += sext(Imm11)
`define OP_JCC    5'b10101   // JCC  条件跳转
`define OP_CALL   5'b10110   // CALL
`define OP_RET    5'b10111   // RET
`define OP_MFC    5'b11100   // MFC
`define OP_MTC    5'b11101   // MTC
`define OP_SYS    5'b11110   // TRAP/ERET（fct3 区分）
`define OP_HLT    5'b11111   // HLT

// ---- R 型 fct5（instr[4:0]） ----
`define F_ADD     5'b00000
`define F_SUB     5'b00001
`define F_ADC     5'b00010
`define F_SBB     5'b00011
`define F_MUL     5'b00100
`define F_MLH     5'b00101
`define F_DIV     5'b00110
`define F_REM     5'b00111
`define F_AND     5'b01000
`define F_OR      5'b01001
`define F_XOR     5'b01010
`define F_NAND    5'b01011
`define F_NOR     5'b01100
`define F_NOT     5'b01101
`define F_MOV     5'b10000
`define F_XCHG    5'b10001
`define F_CMP     5'b10010
`define F_CMPU    5'b10011
`define F_SHL     5'b10100
`define F_SHR     5'b10101
`define F_SAR     5'b10110
`define F_ROL     5'b10111
`define F_ROR     5'b11000

// ---- S 型 fct4（instr[3:0]） ----
`define FS_SHL    4'b0000
`define FS_SHR    4'b0001
`define FS_SAR    4'b0010
`define FS_ROL    4'b0011
`define FS_ROR    4'b0100

// ---- ALU 内部操作码（与 R 型 fct5 对齐，保留编码用作内部扩展） ----
`define ALU_ADD   5'b00000
`define ALU_SUB   5'b00001
`define ALU_ADC   5'b00010
`define ALU_SBB   5'b00011
`define ALU_MUL   5'b00100
`define ALU_MLH   5'b00101
`define ALU_DIV   5'b00110
`define ALU_REM   5'b00111
`define ALU_AND   5'b01000
`define ALU_OR    5'b01001
`define ALU_XOR   5'b01010
`define ALU_NAND  5'b01011
`define ALU_NOR   5'b01100
`define ALU_NOT   5'b01101
`define ALU_MOV   5'b10000
`define ALU_CMP   5'b10010
`define ALU_CMPU  5'b10011
`define ALU_SHL   5'b10100
`define ALU_SHR   5'b10101
`define ALU_SAR   5'b10110
`define ALU_ROL   5'b10111
`define ALU_ROR   5'b11000
`define ALU_PASSB 5'b11001   // 内部：直通 b（MOVI 用）
`define ALU_MOVUI 5'b11010   // 内部：{b[7:0], 8'h00}（MOVUI 用）

// ---- JCC 标志选择（instr[10:9]） ----
`define FLG_C     2'b00
`define FLG_S     2'b01
`define FLG_V     2'b10
`define FLG_Z     2'b11

// ---- ALU b 操作数选择 ----
`define SELB_REG  2'b00      // 寄存器 rs
`define SELB_IMM8S 2'b01     // sext(Imm8)
`define SELB_IMM8Z 2'b10     // zext(Imm8)
`define SELB_SHAMT 2'b11     // zext(shamt4)

// ---- PC 选择 ----
`define PC_NEXT   2'b00      // PC + 2
`define PC_J11    2'b01      // PC + sext(Imm11)
`define PC_J8     2'b10      // PC + sext(Imm8)
