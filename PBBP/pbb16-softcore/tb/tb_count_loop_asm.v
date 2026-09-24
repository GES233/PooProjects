// tb_count_loop_asm.v — 加载汇编器输出的系统级 testbench
// 与 tb_count_loop.v 相同的计数循环，但程序改为
// $readmemh("asm/count_loop.hex", mem) 加载（asm/count_loop.asm 的汇编结果）。
// 检查：R1 = 0x00FF、循环 255 次、CPU 进入 HALT、停机 PC = 0x000A。
//
// 注意：vvp 的工作目录须为 pbb16-softcore/，相对路径 asm/count_loop.hex 才能找到。
`timescale 1ns/1ps

module tb_count_loop_asm;

    reg clk = 1'b0;
    reg rst_n;
    always #5 clk = ~clk;

    // ---- 行为级内存：64K 字节，小端 ----
    reg [7:0] mem [0:65535];

    wire [15:0] mem_addr, mem_wdata, mem_rdata;
    wire        mem_we, mem_re, mem_size, halted;

    assign mem_rdata = mem_size ? {mem[mem_addr + 16'd1], mem[mem_addr]}
                                : {8'h00, mem[mem_addr]};

    always @(posedge clk) begin
        if (mem_we) begin
            mem[mem_addr] <= mem_wdata[7:0];
            if (mem_size) mem[mem_addr + 16'd1] <= mem_wdata[15:8];
        end
    end

    pbb16 dut (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_we(mem_we), .mem_re(mem_re), .mem_size(mem_size),
        .mem_rdata(mem_rdata), .halted(halted)
    );

    integer i;
    integer iters;   // ADD 写回次数（= 循环次数）
    integer cycles;
    integer errors;

    // 计数循环次数：ADD R1,R2 到达 WB 拍即算一次迭代
    always @(posedge clk) begin
        if (rst_n && dut.state == 3'd3 && dut.ir == 16'h4140)
            iters = iters + 1;
    end

    // 每条指令写回时打印关键状态
    always @(posedge clk) begin
        if (rst_n && dut.state == 3'd3)
            $display("  WB: pc=%h ir=%h R0=%h R1=%h R2=%h Z=%b",
                     dut.pc, dut.ir, dut.rf.regs[0], dut.rf.regs[1],
                     dut.rf.regs[2], dut.fz);
    end

    initial begin
        // 先清零，再用汇编器输出覆盖（readmemh 未覆盖处保持 0 = NOP）
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        $readmemh("asm/count_loop.hex", mem);

        iters  = 0;
        cycles = 0;
        errors = 0;

        // 复位
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        $display("== tb_count_loop_asm: start ==");

        // 运行到停机或超时
        while (!halted && cycles < 100000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        @(posedge clk);

        $display("== tb_count_loop_asm: finish, cycles=%0d, iterations=%0d ==", cycles, iters);

        // 检查 1：进入停机状态
        if (halted) $display("  [OK] CPU halted");
        else begin $display("  [FAIL] CPU not halted (timeout)"); errors = errors + 1; end

        // 检查 2：R1 = 0x00FF
        if (dut.rf.regs[1] === 16'h00FF) $display("  [OK] R1 = %h", dut.rf.regs[1]);
        else begin $display("  [FAIL] R1 = %h (expect 00FF)", dut.rf.regs[1]); errors = errors + 1; end

        // 检查 3：循环 255 次
        if (iters == 255) $display("  [OK] iterations = %0d", iters);
        else begin $display("  [FAIL] iterations = %0d (expect 255)", iters); errors = errors + 1; end

        // 检查 4：停机时 PC = 0x000A（HLT 指令地址，HLT 不推进 PC）
        if (dut.pc === 16'h000A) $display("  [OK] PC = %h at halt", dut.pc);
        else begin $display("  [FAIL] PC = %h at halt (expect 000A)", dut.pc); errors = errors + 1; end

        // 检查 5：R6(SP) 保持复位值 0xFFFE
        if (dut.rf.regs[6] === 16'hFFFE) $display("  [OK] R6(SP) = %h", dut.rf.regs[6]);
        else begin $display("  [FAIL] R6(SP) = %h (expect FFFE)", dut.rf.regs[6]); errors = errors + 1; end

        if (errors == 0) $display("== tb_count_loop_asm: PASS ==");
        else             $display("== tb_count_loop_asm: FAIL (%0d errors) ==", errors);
        $finish;
    end

endmodule
