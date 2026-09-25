// 异常标志回归：用真实指令设置/破坏标志，检查返回后的分支与 ADC。
// mode: 0=定点 IRQ，1=TRAP，2=未对齐重试，3=非法指令修补重试，4=handler 内 TRAP。
`timescale 1ns/1ps
`include "pbb16_defs.vh"

module tb_exception_flags;
    reg clk = 0;
    reg rst_n = 0;
    reg [3:0] irq = 0;
    always #5 clk = ~clk;

    reg [7:0] mem [0:65535];
    wire [21:0] addr;
    wire [15:0] wdata, rdata;
    wire we, re, size, halted;
    assign rdata = size ? {mem[addr[15:0] + 16'd1], mem[addr[15:0]]}
                       : {8'h00, mem[addr[15:0]]};
    always @(posedge clk) begin
        if (we) begin
            mem[addr[15:0]] <= wdata[7:0];
            if (size) mem[addr[15:0] + 16'd1] <= wdata[15:8];
        end
    end
    pbb16 dut (
        .clk(clk), .rst_n(rst_n), .mem_addr(addr), .mem_wdata(wdata),
        .mem_rdata(rdata), .mem_we(we), .mem_re(re), .mem_size(size),
        .mem_far(), .mape_o(), .irq(irq), .halted(halted)
    );

    localparam [15:0] TRAP = {`OP_SYS, 3'b000, 8'h00};
    localparam [15:0] ERET = {`OP_SYS, 3'b001, 8'h00};
    localparam [15:0] HLT = {`OP_HLT, 11'd0};
    integer errors = 0;
    integer tests = 0;
    integer mode, pattern;
    reg [15:0] a, b;
    reg [3:0] flags;

    task put(input [15:0] pc, input [15:0] instr);
        begin
            mem[pc] = instr[7:0];
            mem[pc + 16'd1] = instr[15:8];
        end
    endtask

    // 每条 JCC 正确才跳过 HLT；分支不修改标志，最后用 ADC 验证恢复的 C。
    task checks(input [15:0] pc, input [3:0] expected);
        begin
            put(pc,       {`OP_JCC, `FLG_Z, expected[3], 8'd4});
            put(pc + 2,   HLT);
            put(pc + 4,   {`OP_JCC, `FLG_S, expected[2], 8'd4});
            put(pc + 6,   HLT);
            put(pc + 8,   {`OP_JCC, `FLG_C, expected[1], 8'd4});
            put(pc + 10,  HLT);
            put(pc + 12,  {`OP_JCC, `FLG_V, expected[0], 8'd4});
            put(pc + 14,  HLT);
            put(pc + 16,  {`OP_RTYPE, 3'd2, 3'd2, `F_ADC}); // R2 = 0 + 0 + C
            put(pc + 18,  {`OP_MOVI, 3'd7, 8'hA5});
            put(pc + 20,  HLT);
        end
    endtask

    task run_case(input integer kind, input [15:0] lhs, rhs,
                  input [4:0] op, input [3:0] expected);
        integer i, cycles, entries;
        reg injected, returned;
        reg [15:0] resume_pc, check_pc;
        reg [3:0] restored;
        begin
            @(negedge clk);
            rst_n = 0;
            irq = 0;
            for (i = 0; i < 65536; i = i + 1) mem[i] = 0;
            put('h00, {`OP_MOVUI, 3'd0, lhs[15:8]});
            put('h02, {5'b11010, 3'd0, lhs[7:0]}); // ORI R0, lo
            put('h04, {`OP_MOVUI, 3'd1, rhs[15:8]});
            put('h06, {5'b11010, 3'd1, rhs[7:0]});
            put('h08, {`OP_MOVI, 3'd4, 8'd1}); // 未对齐基址
            put('h0A, {`OP_MOVI, 3'd5, 8'd2});
            put('h0C, {`OP_MTC, 3'd5, `CR_STATUS, 4'd0}); // IE=1
            put('h0E, 16'd0);
            put('h10, {`OP_RTYPE, 3'd0, 3'd1, op});
            check_pc = (kind == 0) ? 16'h0012 : 16'h0014;
            resume_pc = (kind == 1) ? 16'h0014 : 16'h0012;
            restored = expected;
            checks(check_pc, expected);
            case (kind)
                1, 4: put('h12, TRAP);
                2: put('h12, {`OP_LODW, 3'd3, 3'd4, 5'd0});
                3: put('h12, 16'h3800); // 未分配 opcode
                default: ;
            endcase
            put('hFF00, {`OP_RTYPE, 3'd5, 3'd5, `F_XOR}); // handler: ZSCV=1000
            put('hFF02, {`OP_MOVI, 3'd4, 8'd0}); // 修正未对齐基址
            put('hFF04, ERET);
            if (kind == 3) begin
                put('hFF02, {`OP_MOVI, 3'd4, 8'h12});
                put('hFF04, {`OP_STRW, 3'd2, 3'd4, 5'd0}); // 将故障指令改为 NOP
                put('hFF06, ERET);
            end
            if (kind == 4) begin
                // 第一层标志为 1010；第二层在 EXL=1 时保存不同的 0101。
                put('hFF00, {5'b11000, 3'd5, 8'd1}); // ADDI R5, 1
                put('hFF02, {5'b11011, 3'd5, 8'd3}); // CMPI R5, 3
                put('hFF04, {`OP_JCC, `FLG_Z, 1'b0, 8'h2C});
                put('hFF06, {`OP_MOVUI, 3'd0, 8'h7F});
                put('hFF08, {5'b11010, 3'd0, 8'hFF});
                put('hFF0A, {`OP_MOVI, 3'd1, 8'd1});
                put('hFF0C, {`OP_RTYPE, 3'd0, 3'd1, `F_ADD});
                put('hFF0E, TRAP);
                put('hFF30, {`OP_RTYPE, 3'd5, 3'd5, `F_XOR});
                put('hFF32, ERET);
                check_pc = 16'hFF10;
                resume_pc = check_pc;
                restored = 4'b0101;
                checks(check_pc, restored);
            end
            repeat (2) @(negedge clk);
            rst_n = 1;
            injected = 0;
            returned = 0;
            entries = 0;
            cycles = 0;
            while (!halted && cycles < 1000) begin
                @(negedge clk);
                cycles = cycles + 1;
                irq = 0;
                if (kind == 0 && !injected && dut.state == 0 && dut.pc == 'h12) begin
                    irq = 1; // 在运算写回后、紧邻的 JCC 取指前注入
                    injected = 1;
                end
                if (dut.state == 7) entries = entries + 1;
                if (entries == ((kind == 4) ? 2 : 1) &&
                    dut.state == 0 && dut.pc == resume_pc && !returned) begin
                    returned = 1;
                    if ({dut.fz, dut.fs, dut.fc, dut.fv} !== restored ||
                        dut.cr_epc !== resume_pc || dut.cr_exl !== 1'b0) begin
                        $display("[FAIL] mode=%0d return flags=%b expected=%b EPC=%h EXL=%b",
                                 kind, {dut.fz, dut.fs, dut.fc, dut.fv}, restored,
                                 dut.cr_epc, dut.cr_exl);
                        errors = errors + 1;
                    end
                end
            end
            tests = tests + 1;
            if (!halted || !returned || entries != ((kind == 4) ? 2 : 1) ||
                dut.cr_excode !== ((kind == 4) ? 3'd2 : (kind + 1)) ||
                dut.pc !== check_pc + 16'd20 || dut.rf.regs[7] !== 16'h00A5 ||
                dut.rf.regs[2] !== {15'd0, restored[1]}) begin
                $display("[FAIL] mode=%0d flags=%b PC=%h R2=%h entries=%0d returned=%b",
                         kind, restored, dut.pc, dut.rf.regs[2], entries, returned);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        for (mode = 0; mode < 4; mode = mode + 1) begin
            for (pattern = 0; pattern < 4; pattern = pattern + 1) begin
                case (pattern)
                    0: begin a = 'hFFFF; b = 1; flags = 4'b1010; end
                    1: begin a = 'h7FFF; b = 1; flags = 4'b0101; end
                    2: begin a = 1; b = 1; flags = 4'b0000; end
                    3: begin a = 'h8000; b = 0; flags = 4'b0100; end
                endcase
                run_case(mode, a, b, `F_ADD, flags);
            end
        end
        run_case(0, 16'd42, 16'd42, `F_CMP, 4'b1010); // CMP -> IRQ -> JCC
        run_case(4, 16'hFFFF, 16'd1, `F_ADD, 4'b1010);
        if (errors != 0) $fatal(1, "tb_exception_flags: FAIL (%0d errors)", errors);
        $display("== tb_exception_flags: PASS (%0d cases) ==", tests);
        $finish;
    end
endmodule
