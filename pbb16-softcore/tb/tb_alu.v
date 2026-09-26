// tb_alu.v — PBB16 v2 ALU 单元测试
// 每个运算至少一组用例：ADD/SUB/ADC/SBB（进位borrow链）、MUL/MLH（高lo16）、
// DIV/REM（含div0规则与有符号语义）、逻辑运算、CMP/CMPU（只置标志）、移位/循环移位。
`timescale 1ns/1ps
`include "pbb16_defs.vh"

module tb_alu;

    reg  [4:0]  op;
    reg  [15:0] a, b;
    reg         cin;
    wire [15:0] y;
    wire        z, s, c, v;

    alu dut (.op(op), .a(a), .b(b), .cin(cin), .y(y), .z(z), .s(s), .c(c), .v(v));

    integer errors = 0;
    integer tests  = 0;

    // 检查一组结果与标志
    task check(
        input [255:0] name,
        input [15:0] ey,
        input ez, es, ec, ev
    );
        begin
            #1;
            tests = tests + 1;
            if (y === ey && z === ez && s === es && c === ec && v === ev)
                $display("  [OK] %0s: y=%h z=%b s=%b c=%b v=%b", name, y, z, s, c, v);
            else begin
                $display("  [FAIL] %0s: got y=%h z=%b s=%b c=%b v=%b, expect y=%h z=%b s=%b c=%b v=%b",
                         name, y, z, s, c, v, ey, ez, es, ec, ev);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("== tb_alu: start ==");

        // ---- ADD ----
        op=`ALU_ADD; cin=0;
        a=16'h0001; b=16'h0001; check("ADD 1+1",        16'h0002, 0,0,0,0);
        a=16'hFFFF; b=16'h0001; check("ADD FFFF+1 C",   16'h0000, 1,0,1,0);
        a=16'h7FFF; b=16'h7FFF; check("ADD ovf V",     16'hFFFE, 0,1,0,1);
        a=16'h8000; b=16'h8000; check("ADD neg+neg C+V",  16'h0000, 1,0,1,1);

        // ---- SUB ----
        op=`ALU_SUB;
        a=16'h0005; b=16'h0003; check("SUB 5-3",        16'h0002, 0,0,1,0);
        a=16'h0003; b=16'h0005; check("SUB 3-5 borrow",   16'hFFFE, 0,1,0,0);
        a=16'h8000; b=16'h0001; check("SUB ovf V",     16'h7FFF, 0,0,1,1);
        a=16'h1234; b=16'h1234; check("SUB equal Z",     16'h0000, 1,0,1,0);

        // ---- ADC（进位链） ----
        op=`ALU_ADC;
        a=16'hFFFF; b=16'h0000; cin=1; check("ADC FFFF+0+Cin", 16'h0000, 1,0,1,0);
        a=16'h00FF; b=16'hFF00; cin=1; check("ADC 00FF+FF00+Cin", 16'h0000, 1,0,1,0);
        a=16'h0001; b=16'h0001; cin=0; check("ADC no-carry",      16'h0002, 0,0,0,0);

        // ---- SBB（borrow链） ----
        op=`ALU_SBB;
        a=16'h0000; b=16'h0000; cin=1; check("SBB 0-0-Cin borrow", 16'hFFFF, 0,1,0,0);
        a=16'h0005; b=16'h0003; cin=1; check("SBB 5-3-Cin",      16'h0001, 0,0,1,0);
        a=16'h0000; b=16'h0001; cin=0; check("SBB 0-1",          16'hFFFF, 0,1,0,0);

        // ---- MUL / MLH ----
        op=`ALU_MUL; cin=0;
        a=16'h00FF; b=16'h00FF; check("MUL lo16", 16'hFE01, 0,1,0,0);
        a=16'h0000; b=16'h1234; check("MUL zero",   16'h0000, 1,0,0,0);
        op=`ALU_MLH;
        a=16'hFFFF; b=16'hFFFF; check("MLH hi16", 16'hFFFE, 0,1,0,0);
        a=16'h00FF; b=16'h00FF; check("MLH hi-zero", 16'h0000, 1,0,0,0);

        // ---- DIV / REM（含div0规则：DIV->0xFFFF, REM->被除数） ----
        op=`ALU_DIV;
        a=16'd100; b=16'd7;  check("DIV 100/7",    16'd14,    0,0,0,0);
        a=16'd100; b=16'd0;  check("DIV div0",     16'hFFFF,  0,1,0,0);
        op=`ALU_REM;
        a=16'd100; b=16'd7;  check("REM 100%7",    16'd2,     0,0,0,0);
        a=16'd100; b=16'd0;  check("REM div0",     16'd100,   0,0,0,0);

        // ---- DIV / REM 有符号语义（v3 明确：向零取整，余数符号同被除数） ----
        op=`ALU_DIV;
        a=-16'sd20; b=16'sd3;    check("DIV -20/3",      -16'sd6,   0,1,0,0);
        a=16'd20;   b=-16'sd3;   check("DIV 20/-3",      -16'sd6,   0,1,0,0);
        a=-16'sd20; b=-16'sd3;   check("DIV -20/-3",     16'd6,     0,0,0,0);
        a=16'h8000; b=16'hFFFF;  check("DIV -32768/-1",  16'h8000,  0,1,0,0);
        op=`ALU_REM;
        a=-16'sd20; b=16'sd3;    check("REM -20%3",      -16'sd2,   0,1,0,0);
        a=16'd20;   b=-16'sd3;   check("REM 20%-3",      16'd2,     0,0,0,0);
        a=-16'sd20; b=-16'sd3;   check("REM -20%-3",     -16'sd2,   0,1,0,0);
        a=16'h8000; b=16'hFFFF;  check("REM -32768%-1",  16'h0000,  1,0,0,0);

        // ---- 逻辑运算 ----
        op=`ALU_AND;  a=16'hF0F0; b=16'h0FF0; check("AND",  16'h00F0, 0,0,0,0);
        op=`ALU_OR;   a=16'hF0F0; b=16'h0FF0; check("OR",   16'hFFF0, 0,1,0,0);
        op=`ALU_XOR;  a=16'hF0F0; b=16'h0FF0; check("XOR",  16'hFF00, 0,1,0,0);
        op=`ALU_NAND; a=16'hF0F0; b=16'h0FF0; check("NAND", 16'hFF0F, 0,1,0,0);
        op=`ALU_NOR;  a=16'hF0F0; b=16'h0FF0; check("NOR",  16'h000F, 0,0,0,0);
        op=`ALU_NOT;  a=16'h0000; b=16'hF0F0; check("NOT",  16'h0F0F, 0,0,0,0);
        op=`ALU_MOV;  a=16'hDEAD; b=16'h00BE; check("MOV",  16'h00BE, 0,0,0,0);

        // ---- CMP / CMPU（仅置标志，y 为 a-b 但不写回——由控制层保证） ----
        op=`ALU_CMP;
        a=16'h0005; b=16'h0003; check("CMP 5>3",     16'h0002, 0,0,1,0);
        a=16'hFFFF; b=16'h0001; check("CMP -1<1",    16'hFFFE, 0,1,1,0);
        a=16'h7FFF; b=16'hFFFF; check("CMP ovf V",  16'h8000, 0,1,0,1);
        op=`ALU_CMPU;
        a=16'hFFFF; b=16'h0001; check("CMPU big-V=0", 16'hFFFE, 0,1,1,0);
        a=16'h0001; b=16'hFFFF; check("CMPU small-borrow",16'h0002, 0,0,0,0);

        // ---- 移位（b = 移位量） ----
        op=`ALU_SHL;
        a=16'h0001; b=16'd4;  check("SHL 1<<4",     16'h0010, 0,0,0,0);
        a=16'h8001; b=16'd1;  check("SHL shift-out C",   16'h0002, 0,0,1,0);
        a=16'h1234; b=16'd0;  check("SHL shift-by-0",  16'h1234, 0,0,0,0);
        op=`ALU_SHR;
        a=16'h8000; b=16'd1;  check("SHR logical-shr", 16'h4000, 0,0,0,0);
        a=16'h0003; b=16'd1;  check("SHR shift-out C",   16'h0001, 0,0,1,0);
        op=`ALU_SAR;
        a=16'h8000; b=16'd1;  check("SAR arith-shr", 16'hC000, 0,1,0,0);
        a=16'hF003; b=16'd1;  check("SAR shift-out C",   16'hF801, 0,1,1,0);
        op=`ALU_ROL;
        a=16'h8001; b=16'd1;  check("ROL rotl", 16'h0003, 0,0,1,0);
        a=16'h1234; b=16'd8;  check("ROL 8bit",     16'h3412, 0,0,0,0);
        op=`ALU_ROR;
        a=16'h0003; b=16'd1;  check("ROR rotr", 16'h8001, 0,1,1,0);
        a=16'h1234; b=16'd8;  check("ROR 8bit",     16'h3412, 0,0,0,0);

        // ---- 内部扩展 ----
        op=`ALU_PASSB; a=16'h0000; b=16'h00FF; check("PASSB(MOVI)",  16'h00FF, 0,0,0,0);
        op=`ALU_MOVUI; a=16'h0000; b=16'h00AB; check("MOVUI",        16'hAB00, 0,1,0,0);

        $display("== tb_alu: %0d tests, %0d errors ==", tests, errors);
        if (errors == 0) $display("== tb_alu: PASS ==");
        else             $display("== tb_alu: FAIL ==");
        $finish;
    end

endmodule
