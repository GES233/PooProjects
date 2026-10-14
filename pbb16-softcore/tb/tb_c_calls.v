// Stage 7 C ABI: stack arguments, nested calls and recursion.
// vvp ... +image=path.hex +expected=002a
`timescale 1ns/1ps
module tb_c_calls;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg [7:0] mem [0:65535];
    wire [21:0] addr;
    wire [15:0] wdata, rdata;
    wire we, re, size, halted, far_access, mape;
    assign rdata = size ? {mem[addr[15:0] + 16'd1], mem[addr[15:0]]}
                       : {8'h00, mem[addr[15:0]]};

    pbb16 dut (
        .clk(clk), .rst_n(rst_n), .mem_addr(addr), .mem_wdata(wdata),
        .mem_rdata(rdata), .mem_we(we), .mem_re(re), .mem_size(size),
        .mem_far(far_access), .mape_o(mape), .irq(4'b0000), .halted(halted)
    );

    integer stack_pushes = 0;
    integer stack_reads = 0;
    reg [15:0] lowest_stack = 16'hEFFE;
    always @(posedge clk) begin
        if (rst_n && (we || re)) begin
            if (addr[21:16] !== 6'd0 || far_access !== 0 || mape !== 0)
                $fatal(1, "unexpected physical mapping at %h", addr);
            if (addr >= 22'h00E000) begin
                if (addr >= 22'h00F000 || dut.state !== 3'd6 ||
                    size !== 1'b1 || addr[0] !== 1'b0)
                    $fatal(1, "invalid stack access at %h", addr);
            end else if (we || dut.state == 3'd6) begin
                $fatal(1, "C program accessed outside its stack window at %h", addr);
            end
        end
        if (rst_n && we) begin
            mem[addr[15:0]] <= wdata[7:0];
            mem[addr[15:0] + 16'd1] <= wdata[15:8];
            if (dut.is_push === 1'b1 || dut.is_call === 1'b1)
                stack_pushes = stack_pushes + 1;
            if (addr[15:0] < lowest_stack) lowest_stack = addr[15:0];
        end
        if (rst_n && re && addr >= 22'h00E000 && dut.state == 3'd6)
            stack_reads = stack_reads + 1;
    end

    reg [8*1024-1:0] image_path;
    reg [15:0] expected;
    integer i, cycles, fd;
    initial begin
        if (!$value$plusargs("image=%s", image_path) ||
            !$value$plusargs("expected=%h", expected))
            $fatal(1, "requires +image=path.hex +expected=hhhh");
        fd = $fopen(image_path, "r");
        if (fd == 0) $fatal(1, "cannot open program image");
        $fclose(fd);
        for (i = 0; i < 65536; i = i + 1) mem[i] = 0;
        $readmemh(image_path, mem);
        repeat (3) @(negedge clk);
        rst_n = 1;
        cycles = 0;
        while (!halted && cycles < 100000) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        if (!halted) $fatal(1, "program timed out");
        if (dut.rf.regs[0] !== expected)
            $fatal(1, "R0=%h, expected %h", dut.rf.regs[0], expected);
        if (dut.rf.regs[6] !== 16'hEFFE || dut.pc !== 16'h0006)
            $fatal(1, "unbalanced stack or wrong return PC: SP=%h PC=%h", dut.rf.regs[6], dut.pc);
        if (dut.rf.regs[2] !== 0 || dut.rf.regs[5] !== 0)
            $fatal(1, "caller state not restored: R2=%h R5=%h", dut.rf.regs[2], dut.rf.regs[5]);
        if (mem[16'hEFFC] !== 8'h06 || mem[16'hEFFD] !== 0)
            $fatal(1, "main return address was corrupted");
        if (dut.cr_exl !== 0 || dut.cr_ie !== 0)
            $fatal(1, "unexpected exception/interrupt state");
        $display("== tb_c_calls: PASS (R0=%h SP=%h pushes=%0d reads=%0d low=%h cycles=%0d) ==",
                 dut.rf.regs[0], dut.rf.regs[6], stack_pushes, stack_reads,
                 lowest_stack, cycles);
        $finish;
    end
endmodule
