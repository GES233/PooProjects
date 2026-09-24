// tb_count_loop.v — PBB16 v2 第一阶段系统级 testbench
// 行为级内存（64K 字节，小端），加载规格第 5 节计数循环程序，
// 检查：R1 最终 = 0x00FF、循环 255 次、CPU 进入 HALT、停机时 PC = 0x000A。
//
// 字节序说明：规格第 5 节按字书写机器码（如 `20 FF` = 字 0x20FF）；
// v2 内存固定小端，故字 0x20FF 在内存中为 mem[0]=0xFF, mem[1]=0x20。
`timescale 1ns/1ps

module tb_count_loop;

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
        .mem_rdata(mem_rdata), .irq(4'b0000), .halted(halted)
    );

    // 写 16 位字到内存（小端）
    task wr16(input [15:0] a, input [15:0] w);
        begin
            mem[a]          = w[7:0];
            mem[a + 16'd1]  = w[15:8];
        end
    endtask

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
        // 加载规格第 5 节计数循环程序
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        wr16(16'h0000, 16'h20FF);   // MOVI R0, 0xFF
        wr16(16'h0002, 16'h2201);   // MOVI R2, 1
        wr16(16'h0004, 16'h4140);   // loop: ADD R1, R2
        wr16(16'h0006, 16'hD9FF);   // CMPI R1, 0xFF
        wr16(16'h0008, 16'hAEFC);   // JCC Z=0, loop (offset=-4)
        wr16(16'h000A, 16'hFFFF);   // HLT

        iters  = 0;
        cycles = 0;
        errors = 0;

        // 复位
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        $display("== tb_count_loop: start ==");

        // 运行到停机或超时
        while (!halted && cycles < 100000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        @(posedge clk);

        $display("== tb_count_loop: finish, cycles=%0d, iterations=%0d ==", cycles, iters);

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

        if (errors == 0) $display("== tb_count_loop: PASS ==");
        else             $display("== tb_count_loop: FAIL (%0d errors) ==", errors);
        $finish;
    end

endmodule
