// C ABI: crt0 -> CALL main -> R0 result -> HLT at 0x0006.
// vvp ... +image=path.hex +expected=002a +pushes=2 +depth=2 [+localbytes=4]
// Counts/depth/localbytes are independent expectations supplied by the test,
// not derived from the assembly. localbytes is the frame size main's prologue
// reserves with ADDI SP, -N; locals live in [0xEFFC-N, 0xEFFA] and are the
// only non-stack-engine accesses allowed at or above 0xE000.
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
    integer reads = 0;
    integer stack_words = 0;
    integer max_depth = 0;
    integer expected_pushes = 0;
    integer expected_depth = 0;
    integer expected_local_bytes = 0;
    reg [15:0] stack_top = 16'hEFFE;
    always @(posedge clk) begin
        if (rst_n && (we || re)) begin
            if (addr[21:16] !== 6'd0 || far_access !== 0 || mape !== 0)
                $fatal(1, "unexpected physical mapping at %h", addr);
            if (addr >= 22'h00F000)
                $fatal(1, "unexpected MMIO/vector access at %h", addr);
            if (addr >= 22'h00E000) begin
                if (dut.state !== 3'd6 || size !== 1'b1 || addr[0] !== 1'b0)
                    $fatal(1, "invalid stack access at %h", addr);
            end else if (we || dut.state == 3'd6)
                $fatal(1, "unexpected code/data access at %h", addr);
        end
        if (rst_n && we) begin
            if (dut.is_push === 1'b1 || dut.is_call === 1'b1) begin
                if (writes == 0) begin
                    if (dut.is_call !== 1'b1 || addr !== 22'h00EFFC || wdata !== 16'h0006)
                        $fatal(1, "incorrect CALL return address");
                    /* Expression pushes start below the locals area that the
                     * prologue carves out (invisible here: ADDI is not a
                     * memory access), so adjust the LIFO base once. */
                    stack_top = 16'hEFFC - expected_local_bytes[15:0];
                end else begin
                    if (dut.is_push !== 1'b1 || addr !== {6'd0, stack_top - 16'd2})
                        $fatal(1, "non-LIFO stack write at %h (top=%h)", addr, stack_top);
                    if (stack_words < 1 || addr >= 22'h00EFFC - expected_local_bytes)
                        $fatal(1, "expected expression PUSH below CALL return address and locals");
                    stack_top = stack_top - 16'd2;
                end
                stack_words = stack_words + 1;
                if (stack_words - 1 > max_depth) max_depth = stack_words - 1;
                mem[addr[15:0]] <= wdata[7:0];
                mem[addr[15:0] + 16'd1] <= wdata[15:8];
                writes = writes + 1;
            end else begin
                /* Local-variable STR.W: word-aligned, inside the frame
                 * window, and not part of the LIFO accounting. */
                if (expected_local_bytes < 2 || size !== 1'b1 || addr[0] !== 1'b0 ||
                    addr < 22'h00EFFC - expected_local_bytes || addr > 22'h00EFFA)
                    $fatal(1, "store outside the locals window at %h", addr);
                mem[addr[15:0]] <= wdata[7:0];
                mem[addr[15:0] + 16'd1] <= wdata[15:8];
            end
        end
        if (rst_n && re && addr >= 22'h00E000) begin
            if (dut.is_pop === 1'b1 || dut.is_ret === 1'b1) begin
                if (stack_words < 1)
                    $fatal(1, "stack underflow on read at %h", addr);
                if (stack_words == 1) begin
                    /* The epilogue's MOV SP, LOCALS is invisible to this
                     * monitor, so the RET slot is checked absolutely and the
                     * LIFO base is realigned to just above the CALL slot. */
                    if (dut.is_ret !== 1'b1 || addr !== 22'h00EFFC || rdata !== 16'h0006)
                        $fatal(1, "RET must read the original CALL return address");
                    stack_top = 16'hEFFC;
                end else begin
                    if (dut.is_pop !== 1'b1 || addr !== {6'd0, stack_top})
                        $fatal(1, "non-LIFO stack read at %h (top=%h)", addr, stack_top);
                end
                stack_top = stack_top + 16'd2;
                stack_words = stack_words - 1;
                reads = reads + 1;
            end else begin
                /* Local-variable LOD.W, same window as stores. */
                if (expected_local_bytes < 2 || size !== 1'b1 || addr[0] !== 1'b0 ||
                    addr < 22'h00EFFC - expected_local_bytes || addr > 22'h00EFFA)
                    $fatal(1, "load outside the locals window at %h", addr);
            end
        end
    end

    reg [8*1024-1:0] image_path;
    reg [15:0] expected;
    integer i, cycles, fd;
    initial begin
        if (!$value$plusargs("image=%s", image_path) ||
            !$value$plusargs("expected=%h", expected))
            $fatal(1, "requires +image=path.hex +expected=hhhh");
        if ($value$plusargs("pushes=%d", expected_pushes)) begin end
        if ($value$plusargs("depth=%d", expected_depth)) begin end
        if ($value$plusargs("localbytes=%d", expected_local_bytes)) begin end
        fd = $fopen(image_path, "r");
        if (fd == 0) $fatal(1, "cannot open program image");
        $fclose(fd);
        for (i = 0; i < 65536; i = i + 1) mem[i] = 0;
        $readmemh(image_path, mem);
        repeat (3) @(negedge clk);
        rst_n = 1;
        cycles = 0;
        while (!halted && cycles < 20000) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        if (!halted) $fatal(1, "program timed out");
        if (dut.rf.regs[0] !== expected)
            $fatal(1, "R0=%h, expected %h", dut.rf.regs[0], expected);
        if (dut.rf.regs[6] !== 16'hEFFE || dut.pc !== 16'h0006)
            $fatal(1, "unbalanced stack or wrong return PC: SP=%h PC=%h", dut.rf.regs[6], dut.pc);
        if (writes != expected_pushes + 1 || reads != writes || stack_words != 0 ||
            stack_top !== 16'hEFFE || max_depth != expected_depth)
            $fatal(1, "stack mismatch writes=%0d reads=%0d depth=%0d (expected pushes=%0d depth=%0d)",
                   writes, reads, max_depth, expected_pushes, expected_depth);
        if (mem[16'hEFFC] !== 8'h06 || mem[16'hEFFD] !== 0)
            $fatal(1, "CALL return address / little-endian stack mismatch");
        if (dut.cr_exl !== 0 || dut.cr_ie !== 0)
            $fatal(1, "unexpected exception/interrupt state");
        for (i = 1; i < 8; i = i + 1)
            if (i != 6 && i != 7 && (i != 1 || expected_pushes == 0) && dut.rf.regs[i] !== 0)
                $fatal(1, "unexpectedly clobbered R%0d", i);
        if (dut.rf.regs[7] !== ((expected_local_bytes > 0) ? 16'hEFFC : 16'h0000))
            $fatal(1, "unexpected R7 (locals pointer) %h", dut.rf.regs[7]);
        $display("== tb_c_return: PASS (R0=%h SP=%h PC=%h pushes=%0d depth=%0d cycles=%0d) ==",
                 dut.rf.regs[0], dut.rf.regs[6], dut.pc, writes - 1, max_depth, cycles);
        $finish;
    end
endmodule
