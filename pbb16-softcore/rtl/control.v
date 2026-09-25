`timescale 1ns/1ps
// control.v — PBB16 v2 多周期控制器（FSM），第二阶段：全部 48 条指令
// 状态：FETCH -> DECODE -> EXEC -> (MEM) -> WB -> (WB2) -> FETCH
//   WB2   ：XCHG / POP 需要第二次寄存器写
//   EXC   ：异常入口气泡拍（异常寄存器与 PC 在进入 EXC 的沿上已锁存）
//   HALT  ：HLT 停机
// 异常（规格 4.3，全部在指令边界精确发生）：
//   FETCH 拍采样外部中断（IE=1 且 EXL=0 且 irq 未被 IM 屏蔽）→ excode=1，EPC=下条指令
//   DECODE 拍：非法指令（未分配主 opcode）→ excode=4，EPC=本指令
//              TRAP → excode=2，EPC=本指令+2（EPC 软件只读，指自身会死循环）
//   EXEC   拍：字访问奇地址 → excode=3，EPC=本指令（不执行访存，ERET 可重试）
`include "pbb16_defs.vh"

module control (
    input  wire       clk,
    input  wire       rst_n,

    // 译码器输入
    input  wire [4:0] opcode,
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
    input  wire       is_lod_w,
    input  wire       is_str_w,
    input  wire       is_lod_b,
    input  wire       is_str_b,
    input  wire       is_push,
    input  wire       is_pop,
    input  wire       is_jr,
    input  wire       is_j,
    input  wire       is_jcc,
    input  wire       is_call,
    input  wire       is_ret,
    input  wire       is_mfc,
    input  wire       is_mtc,
    input  wire       is_trap,
    input  wire       is_eret,
    input  wire [4:0] fct5,
    input  wire [3:0] fct4,
    input  wire [1:0] flg,
    input  wire       cm,

    // 当前标志（JCC 判定用）
    input  wire       flag_z,
    input  wire       flag_s,
    input  wire       flag_c,
    input  wire       flag_v,

    // 数据通路异常条件（顶层组合算出）
    input  wire       misalign,   // 字访问有效地址为奇（EXEC 拍有效）
    input  wire [3:0] irq,        // 外部中断线
    input  wire [3:0] cr_im,      // Status.IM
    input  wire       cr_exl,     // Status.EXL
    input  wire       cr_ie,      // Status.IE

    // 控制信号输出
    output reg        ir_we,      // FETCH 时锁存 IR
    output reg        opab_we,    // DECODE 时锁存操作数 reg_a/reg_b
    output reg  [4:0] alu_op,
    output reg  [2:0] sel_b,      // ALU b 操作数来源
    output reg        sel_a,      // ALU a 操作数来源
    output reg        reg_we,     // 寄存器写使能
    output reg  [1:0] rf_waddr_sel,
    output reg  [1:0] rf_wdata_sel,
    output reg        flag_we,    // 标志寄存器写使能
    output reg  [2:0] pc_sel,     // PC 来源
    output reg        pc_we,      // PC 写使能
    output reg        mem_re,
    output reg        mem_we,
    output reg        mem_size,   // 1 = 字访问
    output reg        mem_addr_sel,
    output reg        mdr_we,     // MEM 拍锁存读数据
    output reg        cr_we,      // MTC 写 Status（仅 CR8 可写，顶层再判）
    output reg        exl_clr,    // ERET 清 EXL
    output reg        exc_we,     // 异常进入：锁存 EPC/Cause、EXL 置位、PC 指向 0xFF00
    output reg  [2:0] exc_code,
    output reg        exc_epc_sel,// 0 = EPC←PC（本指令），1 = EPC←PC+2
    output reg        halted,
    output reg  [2:0] state       // 导出给顶层/TB 调试
);

    localparam ST_FETCH  = 3'd0;
    localparam ST_DECODE = 3'd1;
    localparam ST_EXEC   = 3'd2;
    localparam ST_WB     = 3'd3;
    localparam ST_WB2    = 3'd4;   // XCHG/POP 第二次写回
    localparam ST_HALT   = 3'd5;
    localparam ST_MEM    = 3'd6;
    localparam ST_EXC    = 3'd7;

    // R 型细分
    wire is_xchg = is_rtype && (fct5 == `F_XCHG);
    wire is_cmp  = is_rtype && (fct5 == `F_CMP);
    wire is_cmpu = is_rtype && (fct5 == `F_CMPU);

    // 访存类细分
    wire is_load  = is_lod_w || is_lod_b || is_pop || is_ret;
    wire is_store = is_str_w || is_str_b || is_push || is_call;
    wire is_mmem  = is_lod_w || is_lod_b || is_str_w || is_str_b;

    // 非法指令：未分配的主 opcode（规格 7.2：已分配指令的保留位不查）
    wire is_illegal = (opcode == 5'b00001) || (opcode == 5'b00010)
                    || (opcode == 5'b00011) || (opcode == 5'b00110)
                    || (opcode == 5'b00111) || (opcode == 5'b10011);

    // 外部中断挂起（指令边界 = FETCH 拍采样）
    wire irq_pending = cr_ie && !cr_exl && ((irq & ~cr_im) != 4'b0000);

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
                ST_FETCH:  state <= irq_pending ? ST_EXC : ST_DECODE;
                ST_DECODE: begin
                    if (is_hlt)                    state <= ST_HALT;
                    else if (is_illegal || is_trap) state <= ST_EXC;
                    else                            state <= ST_EXEC;
                end
                ST_EXEC: begin
                    if (misalign)                        state <= ST_EXC;
                    else if (is_load || is_store)        state <= ST_MEM;
                    else                                 state <= ST_WB;
                end
                ST_MEM:    state <= ST_WB;
                ST_WB:     state <= (is_xchg || is_pop) ? ST_WB2 : ST_FETCH;
                ST_WB2:    state <= ST_FETCH;
                ST_EXC:    state <= ST_FETCH;
                ST_HALT:   state <= ST_HALT;
                default:   state <= ST_FETCH;
            endcase
        end
    end

    // 控制信号（组合）
    always @(*) begin
        // 默认值
        ir_we        = 1'b0;
        opab_we      = 1'b0;
        alu_op       = `ALU_ADD;
        sel_b        = `SELB_REG;
        sel_a        = `SELA_RD;
        reg_we       = 1'b0;
        rf_waddr_sel = `WADDR_RD;
        rf_wdata_sel = `WDATA_ALU;
        flag_we      = 1'b0;
        pc_sel       = `PC_NEXT;
        pc_we        = 1'b0;
        mem_re       = 1'b0;
        mem_we       = 1'b0;
        mem_size     = 1'b1;
        mem_addr_sel = `MADDR_ALU;
        mdr_we       = 1'b0;
        cr_we        = 1'b0;
        exl_clr      = 1'b0;
        exc_we       = 1'b0;
        exc_code     = 3'd0;
        exc_epc_sel  = 1'b0;
        halted       = 1'b0;

        // ALU 操作与操作数选择：与状态无关，仅由译码结果决定
        // （WB/MEM 拍沿用同一组信号，保证多周期内稳定）
        if (is_rtype) begin
            alu_op = is_xchg ? `ALU_MOV : fct5; // XCHG 第一拍当 MOV 用
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
            alu_op = `ALU_CMP;                  // 零扩展（规格 3.3 注）
            sel_b  = `SELB_IMM8Z;
        end else if (is_movi) begin
            alu_op = `ALU_PASSB;
            sel_b  = `SELB_IMM8Z;
        end else if (is_movui) begin
            alu_op = `ALU_MOVUI;
            sel_b  = `SELB_IMM8Z;
        end else if (is_mmem) begin
            alu_op = `ALU_ADD;                  // 有效地址 = R[rb] + sext(Imm5)
            sel_a  = `SELA_RB;
            sel_b  = `SELB_IMM5S;
        end else if (is_push || is_call) begin
            alu_op = `ALU_SUB;                  // SP - 2
            sel_a  = `SELA_RB;
            sel_b  = `SELB_TWO;
        end else if (is_pop || is_ret) begin
            alu_op = `ALU_ADD;                  // SP + 2
            sel_a  = `SELA_RB;
            sel_b  = `SELB_TWO;
        end

        case (state)
            ST_FETCH: begin
                if (irq_pending) begin
                    // 指令边界采样到中断：放弃本次取指，进异常
                    exc_we      = 1'b1;
                    exc_code    = `EXC_INT;
                    exc_epc_sel = 1'b0;         // EPC = PC（尚未取指，即下条指令）
                    pc_sel      = `PC_VEC;
                    pc_we       = 1'b1;
                end else begin
                    mem_re   = 1'b1;            // 取指：字访问，小端
                    mem_size = 1'b1;
                    ir_we    = 1'b1;
                end
            end

            ST_DECODE: begin
                opab_we = 1'b1;                 // 锁存 reg_a <= R[rd/rgs], reg_b <= R[rs/rb]/R6
                if (is_illegal) begin
                    exc_we      = 1'b1;
                    exc_code    = `EXC_ILL;
                    exc_epc_sel = 1'b0;         // EPC = 本指令
                    pc_sel      = `PC_VEC;
                    pc_we       = 1'b1;
                end else if (is_trap) begin
                    exc_we      = 1'b1;
                    exc_code    = `EXC_TRAP;
                    exc_epc_sel = 1'b1;         // EPC = 本指令 + 2（跳语义）
                    pc_sel      = `PC_VEC;
                    pc_we       = 1'b1;
                end
            end

            ST_EXEC: begin
                if (misalign) begin
                    // 字访问奇地址：不执行访存，进异常（EPC = 本指令，ERET 可重试）
                    exc_we      = 1'b1;
                    exc_code    = `EXC_ALIGN;
                    exc_epc_sel = 1'b0;
                    pc_sel      = `PC_VEC;
                    pc_we       = 1'b1;
                end
            end

            ST_MEM: begin
                mem_addr_sel = (is_pop || is_ret) ? `MADDR_SP : `MADDR_ALU;
                mem_size     = !(is_lod_b || is_str_b); // 仅字节访存为 0
                if (is_load) begin
                    mem_re = 1'b1;
                    mdr_we = 1'b1;              // 拍沿锁存读数据
                end else begin
                    mem_we = 1'b1;
                end
            end

            ST_WB: begin
                // ---- 寄存器写回 ----
                if (is_rtype && !is_cmp && !is_cmpu) begin
                    reg_we = 1'b1;              // 含 XCHG 第一拍：rd <= R[rs]
                end
                if (is_stype || is_movi || is_movui ||
                    is_addi || is_andi || is_ori) begin
                    reg_we = 1'b1;
                end
                if (is_lod_w || is_lod_b) begin
                    reg_we       = 1'b1;
                    rf_wdata_sel = `WDATA_MDR;
                end
                if (is_pop) begin
                    reg_we       = 1'b1;        // 第一拍：rgs <= mdr
                    rf_wdata_sel = `WDATA_MDR;
                end
                if (is_push || is_call || is_ret) begin
                    reg_we       = 1'b1;        // SP <= SP±2
                    rf_waddr_sel = `WADDR_R6;
                end
                if (is_mfc) begin
                    reg_we       = 1'b1;
                    rf_wdata_sel = `WDATA_CR;
                end

                // ---- 标志更新：R 型（除 XCHG）、S 型、立即数运算 ----
                if ((is_rtype && !is_xchg) || is_stype ||
                    is_addi || is_andi || is_ori || is_cmpi)
                    flag_we = 1'b1;

                // ---- MTC ----
                if (is_mtc) cr_we = 1'b1;

                // ---- PC 更新 ----
                if (is_j || is_call) begin
                    pc_sel = `PC_J11;
                    pc_we  = 1'b1;
                end else if (is_jcc) begin
                    pc_sel = jcc_taken ? `PC_J8 : `PC_NEXT;
                    pc_we  = 1'b1;
                end else if (is_jr) begin
                    pc_sel = `PC_REG;
                    pc_we  = 1'b1;
                end else if (is_ret) begin
                    pc_sel = `PC_MDR;
                    pc_we  = 1'b1;
                end else if (is_eret) begin
                    pc_sel  = `PC_EPC;
                    pc_we   = 1'b1;
                    exl_clr = 1'b1;
                end else if (!is_xchg && !is_pop) begin
                    pc_sel = `PC_NEXT;
                    pc_we  = 1'b1;              // XCHG/POP 的 PC 更新推迟到 WB2
                end
            end

            ST_WB2: begin
                reg_we = 1'b1;
                if (is_pop) begin               // POP 第二拍：SP <= SP+2
                    rf_waddr_sel = `WADDR_R6;
                    rf_wdata_sel = `WDATA_ALU;
                end else begin                  // XCHG 第二拍：rs <= reg_a
                    rf_waddr_sel = `WADDR_RS;
                    rf_wdata_sel = `WDATA_REGA;
                end
                pc_sel = `PC_NEXT;
                pc_we  = 1'b1;
            end

            ST_EXC: begin
                // 气泡拍：异常寄存器与 PC 在进入本状态的沿上已锁存
            end

            ST_HALT: begin
                halted = 1'b1;
            end

            default: ;
        endcase
    end

endmodule
