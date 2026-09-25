// tb_fpu.v — PBB16 v3 FPU16 MMIO 加速器（槽 3）系统级 testbench
// 结构：内核 pbb16 + 总线 bus + 64KB 行为级 RAM + FPU（设备槽 3）。
// 程序由 asm/test_fpu.asm 汇编生成（$readmemh 加载），覆盖：
//   a) FADD  b) FSUB  c) FMUL  d) FDIV  e) FCMP  f) I2F/F2I
//   g) x/0 → +Inf + DZ   h) Inf+(-Inf) → qNaN + NV
// 自检：程序把通过位置进 R7 bit0..bit7，TB 停机后逐项打印。
// 注意 vvp 工作目录须为 pbb16-softcore/。
`timescale 1ns/1ps

module tb_fpu;

    reg clk = 1'b0;
    reg rst_n;
    always #5 clk = ~clk;

    // ---- 内核 <-> 总线 ----
    wire [21:0] mem_addr;
    wire [15:0] mem_wdata, mem_rdata;
    wire        mem_we, mem_re, mem_size, mem_far, mape;
    wire        halted;

    pbb16 core (
        .clk(clk), .rst_n(rst_n),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_we(mem_we), .mem_re(mem_re), .mem_size(mem_size),
        .mem_far(mem_far), .mape_o(mape),
        .mem_rdata(mem_rdata), .irq(4'b0000), .halted(halted)
    );

    // ---- 总线 ----
    wire [21:0] ram_addr;
    wire [15:0] ram_wdata, ram_rdata;
    wire        ram_we, ram_re, ram_size;
    wire [7:0]  dev_sel;
    wire [3:0]  dev_addr;
    wire [15:0] dev_wdata, fpu_rdata;
    wire        dev_we, dev_re, dev_size;

    bus bus_i (
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_we(mem_we), .mem_re(mem_re), .mem_size(mem_size),
        .mem_far(mem_far), .mape(mape),
        .mem_rdata(mem_rdata),
        .ram_addr(ram_addr), .ram_wdata(ram_wdata),
        .ram_we(ram_we), .ram_re(ram_re), .ram_size(ram_size),
        .ram_rdata(ram_rdata),
        .dev_sel(dev_sel), .dev_addr(dev_addr),
        .dev_wdata(dev_wdata), .dev_we(dev_we), .dev_re(dev_re),
        .dev_size(dev_size),
        .dev0_rdata(16'h0000), .dev1_rdata(16'h0000),
        .dev2_rdata(16'h0000), .dev3_rdata(fpu_rdata),
        .dev4_rdata(16'h0000), .dev5_rdata(16'h0000),
        .dev6_rdata(16'h0000), .dev7_rdata(16'h0000)
    );

    // ---- 行为级 RAM：64K 字节，小端（直通态，取低 16 位索引） ----
    reg [7:0] mem [0:65535];

    assign ram_rdata = ram_size ? {mem[ram_addr[15:0] + 16'd1], mem[ram_addr[15:0]]}
                                : {8'h00, mem[ram_addr[15:0]]};
    always @(posedge clk) begin
        if (ram_we) begin
            mem[ram_addr[15:0]] <= ram_wdata[7:0];
            if (ram_size) mem[ram_addr[15:0] + 16'd1] <= ram_wdata[15:8];
        end
    end

    // ---- FPU16 加速器（槽 3） ----
    fpu fpu0 (
        .clk(clk), .rst_n(rst_n),
        .sel(dev_sel[3]), .addr(dev_addr),
        .wdata(dev_wdata), .we(dev_we), .re(dev_re), .size(dev_size),
        .rdata(fpu_rdata), .irq()
    );

    integer i;
    integer cycles;
    integer errors;

    task check_bit(input integer bitno, input [8*56-1:0] name);
        begin
            if (core.rf.regs[7][bitno])
                $display("  [OK] %0s", name);
            else begin
                $display("  [FAIL] %0s (R7 bit%0d = 0)", name, bitno);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        $readmemh("asm/test_fpu.hex", mem);

        cycles = 0;
        errors = 0;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        $display("== tb_fpu: start ==");

        while (!halted && cycles < 50000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        @(posedge clk);

        $display("");
        $display("== tb_fpu: finish, cycles=%0d, R7=%h ==", cycles, core.rf.regs[7]);

        check_bit(0, "a) FADD 1.5 + 2.25 = 3.75");
        check_bit(1, "b) FSUB 3.75 - 2.25 = 1.5");
        check_bit(2, "c) FMUL 3.0 * 0.5 = 1.5");
        check_bit(3, "d) FDIV 3.75 / 1.5 = 2.5");
        check_bit(4, "e) FCMP less/equal");
        check_bit(5, "f) I2F/F2I roundtrip 42");
        check_bit(6, "g) FDIV 1.0/0.0 = +Inf, DZ flag");
        check_bit(7, "h) FADD Inf+(-Inf) = qNaN, NV flag");

        if (halted) $display("  [OK] CPU halted");
        else begin $display("  [FAIL] CPU not halted (timeout)"); errors = errors + 1; end

        if (core.rf.regs[6] === 16'hFFFE) $display("  [OK] R6(SP) = %h", core.rf.regs[6]);
        else begin $display("  [FAIL] R6(SP) = %h (expect FFFE)", core.rf.regs[6]); errors = errors + 1; end

        if (errors == 0) $display("== tb_fpu: PASS ==");
        else             $display("== tb_fpu: FAIL (%0d errors) ==", errors);
        $finish;
    end

endmodule
