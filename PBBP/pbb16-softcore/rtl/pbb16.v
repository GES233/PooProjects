`timescale 1ns/1ps
// pbb16.v — PBB16 v2 软核顶层（第一阶段：多周期，无流水线）
// 内存接口为总线样式：mem_addr/mem_wdata/mem_we/mem_re/mem_size（1=字,0=字节），
// 输入 mem_rdata；字节编址小端。本期外部接行为级内存模型，接口为将来 MMIO 留路。
`include "pbb16_defs.vh"

module pbb16 (
    input  wire        clk,
    input  wire        rst_n,

    // 内存总线
    output wire [15:0] mem_addr,
    output wire [15:0] mem_wdata,
    output wire        mem_we,
    output wire        mem_re,
    output wire        mem_size,   // 1 = 字（16 位），0 = 字节
    input  wire [15:0] mem_rdata,

    output wire        halted
);

    // ---- 架构寄存器 ----
    reg  [15:0] pc;        // 复位 0x0000
    reg  [15:0] ir;
    reg  [15:0] reg_a;     // DECODE 锁存的 R[rd]
    reg  [15:0] reg_b;     // DECODE 锁存的 R[rs]
    reg         fz, fs, fc, fv;   // 标志寄存器 Z/S/C/V

    // ---- 译码器 ----
    wire [4:0]  opcode;
    wire [2:0]  rd, rs, rb, rgs, fct3;
    wire [4:0]  fct5;
    wire [3:0]  fct4, shamt, cr4;
    wire [1:0]  flg;
    wire        cm;
    wire [15:0] imm8_z, imm8_s, imm5_s, imm11_s;
    wire is_nop, is_hlt, is_movi, is_movui;
    wire is_addi, is_andi, is_ori, is_cmpi;
    wire is_rtype, is_stype;
    wire is_lod_w, is_str_w, is_lod_b, is_str_b;
    wire is_push, is_pop, is_jr;
    wire is_j, is_jcc, is_call, is_ret;
    wire is_mfc, is_mtc, is_trap, is_eret;

    decoder dec (
        .instr(ir),
        .opcode(opcode), .rd(rd), .rs(rs), .rb(rb), .rgs(rgs),
        .fct5(fct5), .fct4(fct4), .fct3(fct3), .shamt(shamt),
        .flg(flg), .cm(cm), .cr4(cr4),
        .imm8_z(imm8_z), .imm8_s(imm8_s),
        .imm5_s(imm5_s), .imm11_s(imm11_s),
        .is_nop(is_nop), .is_hlt(is_hlt),
        .is_movi(is_movi), .is_movui(is_movui),
        .is_addi(is_addi), .is_andi(is_andi),
        .is_ori(is_ori), .is_cmpi(is_cmpi),
        .is_rtype(is_rtype), .is_stype(is_stype),
        .is_lod_w(is_lod_w), .is_str_w(is_str_w),
        .is_lod_b(is_lod_b), .is_str_b(is_str_b),
        .is_push(is_push), .is_pop(is_pop), .is_jr(is_jr),
        .is_j(is_j), .is_jcc(is_jcc),
        .is_call(is_call), .is_ret(is_ret),
        .is_mfc(is_mfc), .is_mtc(is_mtc),
        .is_trap(is_trap), .is_eret(is_eret)
    );

    // ---- 控制器 ----
    wire       ir_we, opab_we, reg_we, wb2_sel, flag_we, pc_we;
    wire [4:0] alu_op;
    wire [1:0] sel_b, pc_sel;
    wire [2:0] state;

    control ctrl (
        .clk(clk), .rst_n(rst_n),
        .is_nop(is_nop), .is_hlt(is_hlt),
        .is_movi(is_movi), .is_movui(is_movui),
        .is_addi(is_addi), .is_andi(is_andi),
        .is_ori(is_ori), .is_cmpi(is_cmpi),
        .is_rtype(is_rtype), .is_stype(is_stype),
        .is_j(is_j), .is_jcc(is_jcc),
        .fct5(fct5), .fct4(fct4), .flg(flg), .cm(cm),
        .flag_z(fz), .flag_s(fs), .flag_c(fc), .flag_v(fv),
        .ir_we(ir_we), .opab_we(opab_we),
        .alu_op(alu_op), .sel_b(sel_b),
        .reg_we(reg_we), .wb2_sel(wb2_sel), .flag_we(flag_we),
        .pc_sel(pc_sel), .pc_we(pc_we),
        .mem_re(mem_re), .mem_we(mem_we), .mem_size(mem_size),
        .halted(halted), .state(state)
    );

    // ---- 寄存器组 ----
    wire [15:0] alu_y;                              // ALU 结果（声明提前，写回数据选择用）
    wire [15:0] rf_rd1, rf_rd2;
    wire [2:0]  rf_waddr = wb2_sel ? rs : rd;      // XCHG 第二拍写 rs
    wire [15:0] rf_wdata = wb2_sel ? reg_a : alu_y;

    regfile rf (
        .clk(clk), .rst_n(rst_n),
        .raddr1(rd), .raddr2(rs),
        .rdata1(rf_rd1), .rdata2(rf_rd2),
        .we(reg_we), .waddr(rf_waddr), .wdata(rf_wdata)
    );

    // ---- ALU ----
    reg  [15:0] alu_b;
    always @(*) begin
        case (sel_b)
            `SELB_IMM8S: alu_b = imm8_s;
            `SELB_IMM8Z: alu_b = imm8_z;
            `SELB_SHAMT: alu_b = {12'h000, shamt};
            default:     alu_b = reg_b;
        endcase
    end

    wire        alu_z, alu_s, alu_c, alu_v;

    alu alu_i (
        .op(alu_op), .a(reg_a), .b(alu_b), .cin(fc),
        .y(alu_y), .z(alu_z), .s(alu_s), .c(alu_c), .v(alu_v)
    );

    // ---- 内存总线：本期只取指，地址恒为 PC ----
    assign mem_addr  = pc;
    assign mem_wdata = 16'h0000;   // 第二期接 STR/PUSH/CALL

    // ---- 时序逻辑 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc    <= 16'h0000;
            ir    <= 16'h0000;
            reg_a <= 16'h0000;
            reg_b <= 16'h0000;
            {fz, fs, fc, fv} <= 4'b0000;
        end else begin
            if (ir_we)   ir    <= mem_rdata;
            if (opab_we) begin
                reg_a <= rf_rd1;
                reg_b <= rf_rd2;
            end
            if (flag_we) {fz, fs, fc, fv} <= {alu_z, alu_s, alu_c, alu_v};
            if (pc_we) begin
                case (pc_sel)
                    `PC_J11: pc <= pc + imm11_s;   // 偏移相对本指令地址（规格 3.8）
                    `PC_J8:  pc <= pc + imm8_s;
                    default: pc <= pc + 16'd2;
                endcase
            end
        end
    end

endmodule
