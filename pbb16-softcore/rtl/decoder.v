`timescale 1ns/1ps
// decoder.v — PBB16 v2 纯组合译码器
// 覆盖规格第 3 节全部 48 条指令的译码；
// 访存/栈/CALL/RET/系统指令本期只译码，数据通路第二期再接。
// 保留位按规格 7.2 直接忽略（如 HLT 只判 opcode，不要求低 11 位全 1）。
`include "pbb16_defs.vh"

module decoder (
    input  wire [15:0] instr,

    // 主操作码与格式字段
    output wire [4:0]  opcode,   // op1+op2 = instr[15:11]
    output wire [2:0]  rd,       // instr[10:8]
    output wire [2:0]  rs,       // instr[7:5]
    output wire [2:0]  rb,       // instr[7:5]（M 型基址）
    output wire [2:0]  rgs,      // instr[10:8]（A/C 型）
    output wire [4:0]  fct5,     // instr[4:0]（R 型）
    output wire [3:0]  fct4,     // instr[3:0]（S 型）
    output wire [2:0]  fct3,     // instr[10:8]（Y 型）
    output wire [3:0]  shamt,    // instr[7:4]（S 型移位量）
    output wire [1:0]  flg,      // instr[10:9]（JCC 标志选择）
    output wire        cm,       // instr[8]（JCC 期望标志值）
    output wire [3:0]  cr4,      // instr[7:4]（C 型控制寄存器号）

    // 立即数（已扩展到 16 位）
    output wire [15:0] imm8_z,   // 零扩展 Imm8
    output wire [15:0] imm8_s,   // 符号扩展 Imm8
    output wire [15:0] imm5_s,   // 符号扩展 Imm5（M 型偏移）
    output wire [15:0] imm11_s,  // 符号扩展 Imm11（J/CALL 偏移）

    // 指令类别（每条指令一个信号）
    output wire is_nop,
    output wire is_hlt,
    output wire is_movi,
    output wire is_movui,
    output wire is_addi,
    output wire is_andi,
    output wire is_ori,
    output wire is_cmpi,
    output wire is_rtype,        // R 型整组（具体运算看 fct5）
    output wire is_stype,        // S 型整组（具体移位看 fct4）
    output wire is_lod_w,
    output wire is_str_w,
    output wire is_lod_b,
    output wire is_str_b,
    output wire is_push,
    output wire is_pop,
    output wire is_jr,
    output wire is_j,
    output wire is_jcc,
    output wire is_call,
    output wire is_ret,
    output wire is_mfc,
    output wire is_mtc,
    output wire is_trap,
    output wire is_eret
);

    assign opcode = instr[15:11];
    assign rd     = instr[10:8];
    assign rs     = instr[7:5];
    assign rb     = instr[7:5];
    assign rgs    = instr[10:8];
    assign fct5   = instr[4:0];
    assign fct4   = instr[3:0];
    assign fct3   = instr[10:8];
    assign shamt  = instr[7:4];
    assign flg    = instr[10:9];
    assign cm     = instr[8];
    assign cr4    = instr[7:4];

    assign imm8_z  = {8'h00, instr[7:0]};
    assign imm8_s  = {{8{instr[7]}}, instr[7:0]};
    assign imm5_s  = {{11{instr[4]}}, instr[4:0]};
    assign imm11_s = {{5{instr[10]}}, instr[10:0]};

    assign is_nop    = (opcode == `OP_NOP);
    assign is_hlt    = (opcode == `OP_HLT);
    assign is_movi   = (opcode == `OP_MOVI);
    assign is_movui  = (opcode == `OP_MOVUI);
    assign is_addi   = (opcode == 5'b11000);
    assign is_andi   = (opcode == 5'b11001);
    assign is_ori    = (opcode == 5'b11010);
    assign is_cmpi   = (opcode == 5'b11011);
    assign is_rtype  = (opcode == `OP_RTYPE);
    assign is_stype  = (opcode == `OP_STYPE);
    assign is_lod_w  = (opcode == `OP_LODW);
    assign is_str_w  = (opcode == `OP_STRW);
    assign is_lod_b  = (opcode == `OP_LODB);
    assign is_str_b  = (opcode == `OP_STRB);
    assign is_push   = (opcode == `OP_PUSH);
    assign is_pop    = (opcode == `OP_POP);
    assign is_jr     = (opcode == `OP_JR);
    assign is_j      = (opcode == `OP_J);
    assign is_jcc    = (opcode == `OP_JCC);
    assign is_call   = (opcode == `OP_CALL);
    assign is_ret    = (opcode == `OP_RET);
    assign is_mfc    = (opcode == `OP_MFC);
    assign is_mtc    = (opcode == `OP_MTC);
    assign is_trap   = (opcode == `OP_SYS) && (fct3 == 3'b000);
    assign is_eret   = (opcode == `OP_SYS) && (fct3 == 3'b001);

endmodule
