`timescale 1ns/1ps
// pbb16.v — PBB16 v3 软核顶层（全部 52 条指令，多周期无流水线）
// v3 新增（规格 3.6b / 第 8 节）：
//   - 远访存 FLOD/FSTR：寄存器对 {R[rbh][5:0], R[rbl]} + sext(Imm5) 拼 22 位物理地址，
//     绕过 banking 与 MMIO 直达物理 RAM；
//   - banking：CR4–CR7 = BANK0–BANK3，Status bit3 = MAPE（兼特权位），
//     MAPE=1 时取指与全部近访存按 {BANK[addr[15:14]], addr[13:0]} 重映射到 4MB，
//     MMIO 仅 MAPE=0 直通模式可达（bus 用 mape_o 门控译码）；
//   - 异常进入：MAPS←MAPE、MAPE←0（落内核态）；ERET：MAPE←MAPS。
// 内存接口为总线样式：mem_addr(22 位物理)/mem_wdata/mem_we/mem_re/mem_size
// （1=字,0=字节）/mem_far（1=远访存，绕过 MMIO），输入 mem_rdata；字节编址小端。
// 字节读数据约定高 8 位为 0（zext），字节写只写 mem_addr 处 1 字节。
// 控制寄存器（规格 4.2）：CR0=ZERO、CR4–CR7=BANK0–3、CR8=Status、CR9=Cause、
// CR11=EPC、CR15=PRID(0x0403)。
// 异常模型（规格 4.3）：EPC←PC、excode←码、EXL←1、MAPS←MAPE、MAPE←0、PC←0xFF00；
// ERET 恢复 PC/EXL/MAPE。
`include "pbb16_defs.vh"

module pbb16 (
    input  wire        clk,
    input  wire        rst_n,

    // 内存总线（22 位物理地址）
    output wire [21:0] mem_addr,
    output wire [15:0] mem_wdata,
    output wire        mem_we,
    output wire        mem_re,
    output wire        mem_size,   // 1 = 字（16 位），0 = 字节
    output wire        mem_far,    // 1 = 远访存（绕过 MMIO 译码）
    output wire        mape_o,     // Status.MAPE，供总线门控 MMIO
    input  wire [15:0] mem_rdata,

    // 外部中断（规格 4.2 Cause.IP 对应 4 路）
    input  wire [3:0]  irq,

    output wire        halted
);

    // ---- 架构寄存器 ----
    reg  [15:0] pc;        // 复位 0x0000
    reg  [15:0] ir;
    reg  [15:0] reg_a;     // DECODE 锁存的 R[rd/rgs]
    reg  [15:0] reg_b;     // DECODE 锁存的 R[rs/rb]（栈/调用类为 R6）
    reg  [15:0] reg_c;     // DECODE 锁存的远地址对高位 R[{rb[2:1],1'b1}]
    reg  [15:0] mdr;       // MEM 拍锁存的内存读数据
    reg         fz, fs, fc, fv;   // 标志寄存器 Z/S/C/V

    // ---- 控制寄存器（规格 4.2） ----
    reg  [7:0]  cr_bank0, cr_bank1, cr_bank2, cr_bank3;  // CR4–CR7 BANK0–3
    reg  [3:0]  cr_im;     // CR8 Status: IM[7:4]
    reg         cr_mape;   //            MAPE[3]（映射使能，兼特权位）
    reg         cr_exl;    //            EXL[2]
    reg         cr_ie;     //            IE[1]
    reg         cr_em;     //            EM[0]（纯存储位，无硬件行为）
    reg  [3:0]  cr_ip;     // CR9 Cause: IP[7:4]
    reg         cr_maps;   //            MAPS[3]（MAPE 影子位）
    reg  [2:0]  cr_excode; //           excode[2:0]
    reg  [15:0] cr_epc;    // CR11 EPC

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
    wire is_flod_w, is_fstr_w, is_flod_b, is_fstr_b;
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
        .is_flod_w(is_flod_w), .is_fstr_w(is_fstr_w),
        .is_flod_b(is_flod_b), .is_fstr_b(is_fstr_b),
        .is_push(is_push), .is_pop(is_pop), .is_jr(is_jr),
        .is_j(is_j), .is_jcc(is_jcc),
        .is_call(is_call), .is_ret(is_ret),
        .is_mfc(is_mfc), .is_mtc(is_mtc),
        .is_trap(is_trap), .is_eret(is_eret)
    );

    wire is_far = is_flod_w || is_fstr_w || is_flod_b || is_fstr_b;

    // ---- 远访存物理地址：{R[rbh][5:0], R[rbl]} + sext22(Imm5)，取低 22 位 ----
    wire [21:0] far_addr = {reg_c[5:0], reg_b}
                         + {{17{imm5_s[4]}}, imm5_s[4:0]};

    // ---- 数据通路异常条件 ----
    // 字访问奇地址：近访存 M 型/PUSH/CALL 看 ALU 有效地址；POP/RET 看旧栈顶；
    // 远字访存看 far_addr（alu_y 在下方 ALU 一节声明，提前到此便于阅读）
    wire [15:0] alu_y;
    reg  [15:0] cr_rdata;   // 组合逻辑，见下方"控制寄存器读"一节
    wire misalign = ((is_lod_w || is_str_w || is_push || is_call) && alu_y[0])
                 || ((is_pop || is_ret) && reg_b[0])
                 || ((is_flod_w || is_fstr_w) && far_addr[0]);

    // ---- 控制器 ----
    wire       ir_we, opab_we, reg_we, flag_we, pc_we;
    wire [4:0] alu_op;
    wire [2:0] sel_b, pc_sel;
    wire       sel_a, mem_addr_sel, mdr_we, cr_we, exl_clr;
    wire [1:0] rf_waddr_sel, rf_wdata_sel;
    wire       exc_we, exc_epc_sel;
    wire [2:0] exc_code;
    wire [2:0] state;

    control ctrl (
        .clk(clk), .rst_n(rst_n),
        .opcode(opcode),
        .is_nop(is_nop), .is_hlt(is_hlt),
        .is_movi(is_movi), .is_movui(is_movui),
        .is_addi(is_addi), .is_andi(is_andi),
        .is_ori(is_ori), .is_cmpi(is_cmpi),
        .is_rtype(is_rtype), .is_stype(is_stype),
        .is_lod_w(is_lod_w), .is_str_w(is_str_w),
        .is_lod_b(is_lod_b), .is_str_b(is_str_b),
        .is_flod_w(is_flod_w), .is_fstr_w(is_fstr_w),
        .is_flod_b(is_flod_b), .is_fstr_b(is_fstr_b),
        .is_push(is_push), .is_pop(is_pop), .is_jr(is_jr),
        .is_j(is_j), .is_jcc(is_jcc),
        .is_call(is_call), .is_ret(is_ret),
        .is_mfc(is_mfc), .is_mtc(is_mtc),
        .is_trap(is_trap), .is_eret(is_eret),
        .fct5(fct5), .fct4(fct4), .flg(flg), .cm(cm),
        .flag_z(fz), .flag_s(fs), .flag_c(fc), .flag_v(fv),
        .misalign(misalign), .irq(irq),
        .cr_im(cr_im), .cr_exl(cr_exl), .cr_ie(cr_ie),
        .ir_we(ir_we), .opab_we(opab_we),
        .alu_op(alu_op), .sel_b(sel_b), .sel_a(sel_a),
        .reg_we(reg_we),
        .rf_waddr_sel(rf_waddr_sel), .rf_wdata_sel(rf_wdata_sel),
        .flag_we(flag_we), .pc_sel(pc_sel), .pc_we(pc_we),
        .mem_re(mem_re), .mem_we(mem_we), .mem_size(mem_size),
        .mem_addr_sel(mem_addr_sel), .mdr_we(mdr_we),
        .cr_we(cr_we), .exl_clr(exl_clr),
        .exc_we(exc_we), .exc_code(exc_code), .exc_epc_sel(exc_epc_sel),
        .halted(halted), .state(state)
    );

    // ---- 寄存器组 ----
    // 读口 2 地址复用：栈/调用/返回类隐含读 R6(SP)
    // 读口 3：远访存地址对的高位寄存器 R[{rb[2:1],1'b1}]（rb 的 bit0 忽略）
    wire [2:0]  rf_raddr2 = (is_push || is_pop || is_call || is_ret) ? 3'd6 : rs;
    wire [15:0] rf_rd1, rf_rd2, rf_rd3;

    reg  [2:0]  rf_waddr;
    reg  [15:0] rf_wdata;
    always @(*) begin
        case (rf_waddr_sel)
            `WADDR_RS: rf_waddr = rs;
            `WADDR_R6: rf_waddr = 3'd6;
            default:   rf_waddr = rd;
        endcase
        case (rf_wdata_sel)
            `WDATA_REGA: rf_wdata = reg_a;
            `WDATA_MDR:  rf_wdata = mdr;
            `WDATA_CR:   rf_wdata = cr_rdata;
            default:     rf_wdata = alu_y;
        endcase
    end

    regfile rf (
        .clk(clk), .rst_n(rst_n),
        .raddr1(rd), .raddr2(rf_raddr2),
        .rdata1(rf_rd1), .rdata2(rf_rd2),
        .we(reg_we), .waddr(rf_waddr), .wdata(rf_wdata),
        .raddr3({rb[2:1], 1'b1}), .rdata3(rf_rd3)
    );

    // ---- ALU ----
    wire [15:0] alu_a = sel_a ? reg_b : reg_a;
    reg  [15:0] alu_b;
    always @(*) begin
        case (sel_b)
            `SELB_IMM8S: alu_b = imm8_s;
            `SELB_IMM8Z: alu_b = imm8_z;
            `SELB_SHAMT: alu_b = {12'h000, shamt};
            `SELB_IMM5S: alu_b = imm5_s;
            `SELB_TWO:   alu_b = 16'd2;
            default:     alu_b = reg_b;
        endcase
    end

    wire        alu_z, alu_s, alu_c, alu_v;

    alu alu_i (
        .op(alu_op), .a(alu_a), .b(alu_b), .cin(fc),
        .y(alu_y), .z(alu_z), .s(alu_s), .c(alu_c), .v(alu_v)
    );

    // ---- 控制寄存器读（MFC，未分配读 0；规格 4.2） ----
    always @(*) begin
        case (cr4)
            4'd0:    cr_rdata = 16'h0000;                        // ZERO
            4'd4:    cr_rdata = {8'h00, cr_bank0};               // BANK0
            4'd5:    cr_rdata = {8'h00, cr_bank1};               // BANK1
            4'd6:    cr_rdata = {8'h00, cr_bank2};               // BANK2
            4'd7:    cr_rdata = {8'h00, cr_bank3};               // BANK3
            4'd8:    cr_rdata = {8'h00, cr_im, cr_mape,
                                 cr_exl, cr_ie, cr_em};          // Status
            4'd9:    cr_rdata = {8'h00, cr_ip, cr_maps,
                                 cr_excode};                     // Cause
            4'd11:   cr_rdata = cr_epc;                          // EPC
            4'd15:   cr_rdata = `PRID_VAL;                       // PRID
            default: cr_rdata = 16'h0000;
        endcase
    end

    // ---- 内存总线（22 位物理地址） ----
    // FETCH 拍逻辑地址 = PC；MEM 拍 = 有效地址（POP/RET 为旧栈顶 reg_b）；
    // 其余拍 mem_re/mem_we 均为 0，地址无效（给 PC 只是定值，无总线事务）。
    // 近访问经 banking 翻译（MAPE=0 时直通）；远访存直接用 far_addr。
    wire [15:0] la = (state == 3'd6) ?
                     (mem_addr_sel == `MADDR_SP ? reg_b : alu_y) : pc;
    wire [7:0]  bank_sel = (la[15:14] == 2'd0) ? cr_bank0 :
                           (la[15:14] == 2'd1) ? cr_bank1 :
                           (la[15:14] == 2'd2) ? cr_bank2 : cr_bank3;
    wire [21:0] near_phys = cr_mape ? {bank_sel, la[13:0]}
                                    : {6'b000000, la};

    assign mem_addr  = (state == 3'd6 && is_far) ? far_addr : near_phys;
    assign mem_far   = is_far && (state == 3'd6);
    assign mape_o    = cr_mape;

    // 写数据：CALL 压返回地址 PC+2，其余压/存 R[rgs]/R[rd]
    assign mem_wdata = is_call ? (pc + 16'd2) : reg_a;

    // ---- 时序逻辑 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc    <= 16'h0000;
            ir    <= 16'h0000;
            reg_a <= 16'h0000;
            reg_b <= 16'h0000;
            reg_c <= 16'h0000;
            mdr   <= 16'h0000;
            {fz, fs, fc, fv} <= 4'b0000;
            cr_bank0  <= 8'd0;          // 复位值 = 窗口号（直通）
            cr_bank1  <= 8'd1;
            cr_bank2  <= 8'd2;
            cr_bank3  <= 8'd3;
            cr_im     <= 4'b0000;
            cr_mape   <= 1'b0;
            cr_exl    <= 1'b0;
            cr_ie     <= 1'b0;
            cr_em     <= 1'b0;
            cr_ip     <= 4'b0000;
            cr_maps   <= 1'b0;
            cr_excode <= 3'd0;
            cr_epc    <= 16'h0000;
        end else begin
            if (ir_we)   ir    <= mem_rdata;
            if (opab_we) begin
                reg_a <= rf_rd1;
                reg_b <= rf_rd2;
                reg_c <= rf_rd3;
            end
            if (mdr_we)  mdr   <= mem_rdata;
            if (flag_we) {fz, fs, fc, fv} <= {alu_z, alu_s, alu_c, alu_v};

            // 异常进入（规格 4.3）：EPC、Cause、EXL、MAPE 落影子位并清 0、PC 向量
            if (exc_we) begin
                cr_epc    <= exc_epc_sel ? (pc + 16'd2) : pc;
                cr_excode <= exc_code;
                cr_ip     <= irq;
                cr_exl    <= 1'b1;
                cr_maps   <= cr_mape;
                cr_mape   <= 1'b0;
            end
            // ERET：EXL <- 0，MAPE 从影子位恢复
            if (exl_clr) begin
                cr_exl  <= 1'b0;
                cr_mape <= cr_maps;
            end

            // MTC：CR4–CR7(BANK0–3) 写低 8 位；CR8(Status) 写 IM/MAPE/EXL/IE/EM；
            // 其余写忽略（规格 4.2）
            if (cr_we && (cr4 >= `CR_BANK0) && (cr4 <= `CR_BANK3)) begin
                case (cr4)
                    `CR_BANK0: cr_bank0 <= reg_a[7:0];
                    `CR_BANK1: cr_bank1 <= reg_a[7:0];
                    `CR_BANK2: cr_bank2 <= reg_a[7:0];
                    default:   cr_bank3 <= reg_a[7:0];
                endcase
            end
            if (cr_we && (cr4 == `CR_STATUS)) begin
                cr_im   <= reg_a[7:4];
                cr_mape <= reg_a[3];
                cr_exl  <= reg_a[2];
                cr_ie   <= reg_a[1];
                cr_em   <= reg_a[0];
            end

            if (pc_we) begin
                case (pc_sel)
                    `PC_J11: pc <= pc + imm11_s;   // 偏移相对本指令地址（规格 3.8）
                    `PC_J8:  pc <= pc + imm8_s;
                    `PC_REG: pc <= reg_a;          // JR
                    `PC_MDR: pc <= mdr;            // RET
                    `PC_EPC: pc <= cr_epc;         // ERET
                    `PC_VEC: pc <= 16'hFF00;       // 异常入口
                    default: pc <= pc + 16'd2;
                endcase
            end
        end
    end

endmodule
