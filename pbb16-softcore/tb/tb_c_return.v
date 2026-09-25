// C stage 1 ABI: crt0 -> CALL main -> return value in R0 -> HLT at 0x0006.
// vvp ... +image=path.hex +expected=002a
`timescale 1ns/1ps
module tb_c_return;
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

    integer writes = 0;
    always @(posedge clk) begin
        if (rst_n && (we || re)) begin
            if (addr[21:16] !== 6'd0 || far_access !== 0 || mape !== 0)
                $fatal(1, "unexpected physical mapping at %h", addr);
            if (addr >= 22'h00F000)
                $fatal(1, "unexpected MMIO/vector access at %h", addr);
        end
        if (rst_n && we) begin
            // Only CALL's 16-bit return address should touch memory in stage 1.
            if (addr !== 22'h00EFFC || size !== 1'b1 || wdata !== 16'h0006)
                $fatal(1, "unexpected stack write addr=%h size=%b data=%h", addr, size, wdata);
            mem[addr[15:0]] <= wdata[7:0];
            mem[addr[15:0] + 16'd1] <= wdata[15:8];
            writes = writes + 1;
        end
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
        while (!halted && cycles < 200) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        if (!halted) $fatal(1, "program timed out");
        if (dut.rf.regs[0] !== expected)
            $fatal(1, "R0=%h, expected %h", dut.rf.regs[0], expected);
        if (dut.rf.regs[6] !== 16'hEFFE || dut.pc !== 16'h0006)
            $fatal(1, "unbalanced stack or wrong return PC: SP=%h PC=%h", dut.rf.regs[6], dut.pc);
        if (writes != 1 || mem[16'hEFFC] !== 8'h06 || mem[16'hEFFD] !== 0)
            $fatal(1, "CALL return address / little-endian stack mismatch");
        if (dut.cr_exl !== 0 || dut.cr_ie !== 0)
            $fatal(1, "unexpected exception/interrupt state");
        for (i = 1; i < 8; i = i + 1)
            if (i != 6 && dut.rf.regs[i] !== 0)
                $fatal(1, "stage 1 unexpectedly clobbered R%0d", i);
        $display("== tb_c_return: PASS (R0=%h SP=%h PC=%h cycles=%0d) ==",
                 dut.rf.regs[0], dut.rf.regs[6], dut.pc, cycles);
        $finish;
    end
endmodule
