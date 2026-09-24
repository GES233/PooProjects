`timescale 1ns/1ps
// control.v — PBB16 v2 多周期控制器（FSM）
// 状态：FETCH -> DECODE -> EXEC -> WB -> (XCHG 多一拍 WB2) -> FETCH
// HLT 进入 HALT 停机。本期只接第一阶段的指令数据通路，
// 访存/栈/CALL/RET/系统指令译码后在此视为 NOP 通过（第二期实现）。
`include "pbb16_defs.vh"

module control (
    input  wire       clk,
    input  wire       rst_n,

    // 译码器输入
    input  wire       is_nop,
    input  wire       is_hlt,
    input  wire       is_movi,
    input  wire       is_movui,
    input  wire       is_addi,
    input  wire       is_andi,
    input  wire       is_ori,
    input  wire       is_cmpi,
    input  wire       is_rtype,
    input  wire       is_stype,
    input  wire       is_j,
    input  wire       is_jcc,
    input  wire [4:0] fct5,
    input  wire [3:0] fct4,
    input  wire [1:0] flg,
    input  wire       cm,

    // 当前标志（JCC 判定用）
    input  wire       flag_z,
    input  wire       flag_s,
    input  wire       flag_c,
    input  wire       flag_v,

    // 控制信号输出
    output reg        ir_we,      // FETCH 时锁存 IR
    output reg        opab_we,    // DECODE 时锁存操作数 reg_a/reg_b
    output reg  [4:0] alu_op,
    output reg  [1:0] sel_b,      // ALU b 操作数来源
    output reg        reg_we,     // 寄存器写使能
    output reg        wb2_sel,    // 1 = XCHG 第二拍：写 rs <= reg_a
    output reg        flag_we,    // 标志寄存器写使能
    output reg  [1:0] pc_sel,     // PC 来源
    output reg        pc_we,      // PC 写使能
    output reg        mem_re,
    output reg        mem_we,
    output reg        mem_size,   // 1 = 字访问
    output reg        halted,
    output reg  [2:0] state       // 导出给顶层/TB 调试
);

    localparam ST_FETCH  = 3'd0;
    localparam ST_DECODE = 3'd1;
    localparam ST_EXEC   = 3'd2;
    localparam ST_WB     = 3'd3;
    localparam ST_WB2    = 3'd4;   // XCHG 第二次写回
    localparam ST_HALT   = 3'd5;

    // R 型细分
    wire is_xchg = is_rtype && (fct5 == `F_XCHG);
    wire is_cmp  = is_rtype && (fct5 == `F_CMP);
    wire is_cmpu = is_rtype && (fct5 == `F_CMPU);

    // JCC 条件判定：flag[flg] XNOR cm（规格 3.8）
    reg flag_sel;
    always @(*) begin
        case (flg)
            `FLG_Z: flag_sel = flag_z;
            `FLG_V: flag_sel = flag_v;
            `FLG_S: flag_sel = flag_s;
            default: flag_sel = flag_c;
        endcase
    end
    wire jcc_taken = (flag_sel == cm);

    // 状态转移
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_FETCH;
        end else begin
            case (state)
                ST_FETCH:  state <= ST_DECODE;
                ST_DECODE: state <= is_hlt ? ST_HALT : ST_EXEC;
                ST_EXEC:   state <= ST_WB;
                ST_WB:     state <= is_xchg ? ST_WB2 : ST_FETCH;
                ST_WB2:    state <= ST_FETCH;
                ST_HALT:   state <= ST_HALT;
                default:   state <= ST_FETCH;
            endcase
        end
    end

    // 控制信号（组合）
    always @(*) begin
        // 默认值
        ir_we   = 1'b0;
        opab_we = 1'b0;
        alu_op  = `ALU_ADD;
        sel_b   = `SELB_REG;
        reg_we  = 1'b0;
        wb2_sel = 1'b0;
        flag_we = 1'b0;
        pc_sel  = `PC_NEXT;
        pc_we   = 1'b0;
        mem_re  = 1'b0;
        mem_we  = 1'b0;
        mem_size = 1'b1;
        halted  = 1'b0;

        // ALU 操作与 b 操作数选择：与状态无关，仅由译码结果决定
        // （WB 拍沿用同一组信号采样，保证多周期内稳定）
        if (is_rtype) begin
            alu_op = is_xchg ? `ALU_MOV : fct5; // XCHG 第一拍当 MOV 用
            sel_b  = `SELB_REG;
        end else if (is_stype) begin
            alu_op = `ALU_SHL + {1'b0, fct4};   // fct4 0..4 -> SHL..ROR
            sel_b  = `SELB_SHAMT;
        end else if (is_addi) begin
            alu_op = `ALU_ADD;
            sel_b  = `SELB_IMM8S;
        end else if (is_andi) begin
            alu_op = `ALU_AND;
            sel_b  = `SELB_IMM8Z;
        end else if (is_ori) begin
            alu_op = `ALU_OR;
            sel_b  = `SELB_IMM8Z;
        end else if (is_cmpi) begin
            // 注意：规格 3.3 表写 CMPI 符号扩展，但第 5 节样例
            // （CMPI R1,0xFF 需在 R1=0x00FF 时退出循环）只有零扩展才成立。
            // 按样例语义取零扩展，详见设计报告。
            alu_op = `ALU_CMP;
            sel_b  = `SELB_IMM8Z;
        end else if (is_movi) begin
            alu_op = `ALU_PASSB;
            sel_b  = `SELB_IMM8Z;
        end else if (is_movui) begin
            alu_op = `ALU_MOVUI;
            sel_b  = `SELB_IMM8Z;
        end

        case (state)
            ST_FETCH: begin
                mem_re   = 1'b1;      // 取指：字访问，小端
                mem_size = 1'b1;
                ir_we    = 1'b1;
            end

            ST_DECODE: begin
                opab_we = 1'b1;       // 锁存 reg_a <= R[rd], reg_b <= R[rs]
            end

            ST_EXEC: begin
                // ALU 在本拍组合运算，WB 拍沿采样写回；
                // alu_op/sel_b 与状态无关（见下方译码），本拍无需动作
            end

            ST_WB: begin
                // 写回 + PC 更新
                if (is_rtype && !is_cmp && !is_cmpu) reg_we = 1'b1; // XCHG 此拍写 rd<=rs
                if (is_stype || is_movi || is_movui ||
                    is_addi || is_andi || is_ori)    reg_we = 1'b1;

                // 标志更新：R 型（除 XCHG）、S 型、立即数运算（含 CMPI）
                if ((is_rtype && !is_xchg) || is_stype ||
                    is_addi || is_andi || is_ori || is_cmpi)
                    flag_we = 1'b1;

                if (is_j) begin
                    pc_sel = `PC_J11;
                    pc_we  = 1'b1;
                end else if (is_jcc) begin
                    pc_sel = jcc_taken ? `PC_J8 : `PC_NEXT;
                    pc_we  = 1'b1;
                end else if (!is_xchg) begin
                    pc_sel = `PC_NEXT;
                    pc_we  = 1'b1;    // XCHG 的 PC 更新推迟到 WB2
                end
            end

            ST_WB2: begin             // XCHG 第二拍：写 rs <= reg_a
                reg_we  = 1'b1;
                wb2_sel = 1'b1;
                pc_sel  = `PC_NEXT;
                pc_we   = 1'b1;
            end

            ST_HALT: begin
                halted = 1'b1;
            end

            default: ;
        endcase
    end

endmodule
